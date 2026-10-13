# SESSION RECORDER (SessionRecorder autoload, added by the Session Replay plugin)
#
# Records a whole play session, from the moment the main scene starts until the
# game quits: the state of every node, every physics frame, plus your input.
# Nothing is re-simulated on playback; replay scenes just act it out again (see
# replay_player.gd), so what you see is exactly what happened, in multiplayer
# too (the other players' ships are recorded like everything else).
#
# What is recorded, per physics frame, only when it changes:
#   - every scene or node added or removed (an "entity": a scene instance, or a
#     node created by code), and where it was added
#   - for each node inside those entities: 3D/2D transform, visibility,
#     modulate, text (labels, buttons), range values (progress bars), which
#     camera is current, particles emitting, UI layout (position, size,
#     minimum size, grid columns, scroll), textures, sprite frames and
#     AnimationPlayer animations (see node_state.gd)
#   - textures made by code (no file in the project), once each, as PNG
#   - input: keys held, mouse buttons and motion, gamepad buttons and sticks
# Every KEYFRAME_EVERY frames a full snapshot is written, so playback can jump
# anywhere instantly.
#
# File: user://recordings/session_<date>.sreplay, a sequence of store_var()
# records: a header, then frames and keyframes, then an end record.
# The sound (everything the game played, as heard) goes next to it as
# session_<date>.wav, written when the game quits.
#
# Command line option (after "--"): --no-record to skip recording this run.
extends Node

const FORMAT_VERSION := 2
const EXTENSION := "sreplay"
const RECORDINGS_DIR := "user://recordings"
const KEYFRAME_EVERY := 120
## Time per frame spent re-checking nodes' other properties ("p" in
## node_state.gd) in the background, in microseconds.
const PROP_CHECK_BUDGET_USEC := 600
## Nodes that haven't changed for IDLE_AFTER frames are checked every
## IDLE_EVERY frames instead of every frame (most of a level stands still),
## until they change again.
const IDLE_AFTER := 30
const IDLE_EVERY := 4

const NodeState := preload("res://addons/session_replay/node_state.gd")
const DrawCapture := preload("res://addons/session_replay/draw_capture.gd")
# Whether to record and how many sessions to keep (set from the Session Replays tab).
const Library := preload("res://addons/session_replay/session_library.gd")

var file_path: String = ""
var recording: bool = false

var _args: Dictionary = {}
var _file: FileAccess
var _frame: int = 0
var _start_usec: int = 0
# Every recorded node, for the background check of its other properties:
# [entity id, NodeState.Tracked], and where the check is.
var _prop_queue: Array = []
var _prop_index := 0
# What scripts draw themselves (see draw_capture.gd).
var _draw_capture: Node
var _next_entity_id: int = 1

# Entities alive right now: entity id -> Entity.
var _entities: Dictionary = {}
# Instance id of each entity's root node -> entity id.
var _entity_of_root: Dictionary = {}
# Roots added this frame. They are set up at the end of the frame, once their
# own _ready() code has run.
var _pending_roots: Array[Node] = []
# Default values of each scene's nodes, read once from an unused instance.
var _scene_defaults: Dictionary = {}

# The frame being built.
var _spawns: Array = []
var _despawns: Array = []
# Nodes of a recorded scene removed this frame: [entity id, path, node].
var _removed_members: Array = []
# Instance id of each node of a recorded scene (not its root) -> [entity id,
# path]. Looked up when one is removed: by then the engine has cleared its
# owner, so it can't be found from that.
var _member_of: Dictionary = {}

var _input := InputState.new()
# Records everything the Master bus plays while recording.
var _audio: AudioEffectRecord
# The UI element that has keyboard / gamepad focus: [entity id, path], or [].
var _focus: Array = []


class Entity:
	var id: int
	var root: Node
	var info: Dictionary         # what playback needs to rebuild it
	var tracked: Array = []      # a NodeState.Tracked per recorded node
	var removed: Dictionary = {} # paths of its scene's nodes that were removed
	var members: Array[int] = [] # instance ids of its scene's nodes


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Capture after everything else has moved this frame.
	process_physics_priority = 1000
	_args = _parse_args()
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	get_window().window_input.connect(_on_window_input)


func _exit_tree() -> void:
	if recording and _file:
		_file.store_var({"end": _frame})
		_file.close()
		_file = null
	_save_audio()


func _start_audio() -> void:
	_audio = AudioEffectRecord.new()
	_audio.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(0, _audio)
	_audio.set_recording_active(true)


func _save_audio() -> void:
	if _audio == null:
		return
	var wav := _audio.get_recording()
	_audio.set_recording_active(false)
	for i in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, i) == _audio:
			AudioServer.remove_bus_effect(0, i)
			break
	_audio = null
	if wav:
		wav.save_to_wav(ProjectSettings.globalize_path(file_path.get_basename() + ".wav"))


# Recording starts the first time the game's main scene is running, so running
# a single scene (F6), a replay scene or the test runner isn't recorded.
func _process(_delta: float) -> void:
	if recording or _args.has("no-record") or not OS.is_debug_build() \
			or not Library.record_enabled():
		set_process(false)
		return
	var scene := get_tree().current_scene
	if scene and scene.scene_file_path == main_scene_path():
		set_process(false)
		_start_recording(scene)


func _start_recording(main_scene: Node) -> void:
	DirAccess.make_dir_recursive_absolute(RECORDINGS_DIR)
	# Room for this one: the oldest sessions go, saved replays included.
	Library.prune(Library.max_recordings() - 1)
	file_path = "%s/session_%s.%s" % [RECORDINGS_DIR, Time.get_datetime_string_from_system().replace(":", "-"), EXTENSION]
	_file = FileAccess.open(file_path, FileAccess.WRITE)
	if _file == null:
		push_warning("SessionRecorder: can't write %s" % file_path)
		return
	recording = true
	_start_usec = Time.get_ticks_usec()
	_draw_capture = DrawCapture.new(PackedStringArray(ProjectSettings.get_setting(
		"session_replay/keep_scripts_from", ["res://addons/"])))
	_draw_capture.name = "DrawCapture"
	add_child(_draw_capture)
	_file.store_var({
		"header": true,
		"version": FORMAT_VERSION,
		"ticks": Engine.physics_ticks_per_second,
		"window": get_viewport().get_visible_rect().size,
		"main_scene": main_scene_path(),
		"date": Time.get_datetime_string_from_system(),
		"godot": Engine.get_version_info()["string"],
	})
	# The main scene, and any node its code already added that isn't part of
	# its scene file (e.g. the first level, added by the scene controller).
	_start_audio()
	_pending_roots.append(main_scene)
	for node in main_scene.find_children("*", "", true, false):
		if not _is_ignored(node) and _member_entity_root(node) == null:
			_pending_roots.append(node)
	print("SessionRecorder: recording to ", ProjectSettings.globalize_path(file_path))


func _physics_process(_delta: float) -> void:
	if not recording:
		return
	for root in _pending_roots:
		if is_instance_valid(root) and root.is_inside_tree():
			_add_entity(root)
	_pending_roots.clear()

	var removals := _take_removed_members()

	var values := {}
	for entity: Entity in _entities.values():
		var changed := {}
		for t: NodeState.Tracked in entity.tracked:
			# Nodes only "p" looks at are checked in _check_props.
			if t.kinds == 0 and not t.check_props:
				continue
			if t.idle > IDLE_AFTER and not t.check_props and (_frame + t.get_instance_id()) % IDLE_EVERY != 0:
				continue
			if not is_instance_valid(t.node) or not t.node.is_inside_tree():
				continue
			var delta = t.capture()
			if delta != null:
				changed[t.path] = delta
		if not changed.is_empty():
			values[entity.id] = changed
	_check_props(values)

	# Focus first, so this frame's keyframe already has it.
	var focus := _focus_ref()
	var record := {}
	if focus != _focus:
		_focus = focus
		record["fo"] = focus
	# What scripts drew themselves, before the keyframe so it has it.
	var drawn: Dictionary = _draw_capture.capture()
	if _frame % KEYFRAME_EVERY == 0:
		record["key"] = _keyframe()
	if not _spawns.is_empty():
		record["sp"] = _spawns
	if not _despawns.is_empty():
		record["dp"] = _despawns
	if not removals.is_empty():
		record["rm"] = removals
	if not values.is_empty():
		record["v"] = values
	if not drawn.is_empty():
		record["dc"] = drawn
	# Textures made by code that this frame (or its keyframe) used first.
	var textures := NodeState.Tracked.take_new_textures()
	if not textures.is_empty():
		record["tex"] = textures
	var input_delta := _input.take_changes()
	if not input_delta.is_empty():
		record["in"] = input_delta
	# When this frame happened, in ms since recording started: playback keeps
	# to it, so the picture stays with the sound even if the game hitched.
	record["ms"] = (Time.get_ticks_usec() - _start_usec) / 1000
	record["f"] = _frame
	_file.store_var(record)
	if _frame % 60 == 0:
		_file.flush()
	_spawns = []
	_despawns = []
	_frame += 1


# Re-checks the other properties of a few nodes (as many as fit in
# PROP_CHECK_BUDGET_USEC), going round all of them, so changes made by code
# after a node appeared are recorded too (a bit later than they happened).
func _check_props(values: Dictionary) -> void:
	var start := Time.get_ticks_usec()
	var checked := 0
	while not _prop_queue.is_empty() and checked < _prop_queue.size() 			and Time.get_ticks_usec() - start < PROP_CHECK_BUDGET_USEC:
		if _prop_index >= _prop_queue.size():
			_prop_index = 0
		var entry: Array = _prop_queue[_prop_index]
		var id: int = entry[0]
		var t: NodeState.Tracked = entry[1]
		if not _entities.has(id) or not is_instance_valid(t.node):
			_prop_queue[_prop_index] = _prop_queue[-1]
			_prop_queue.pop_back()
			continue
		_prop_index += 1
		checked += 1
		if t.props.is_empty() or not t.node.is_inside_tree():
			continue
		var delta = t.capture_props()
		if delta == null:
			continue
		t.changed_ever = true
		if not values.has(id):
			values[id] = {}
		if not values[id].has(t.path):
			values[id][t.path] = {}
		values[id][t.path]["p"] = delta


# Everything needed to rebuild the whole scene as it is after this frame.
func _keyframe() -> Dictionary:
	var alive := []
	var values := {}
	var removed := {}
	var ids := _entities.keys()
	ids.sort()
	for id in ids:
		var entity: Entity = _entities[id]
		alive.append(entity.info)
		var state := {}
		for t in entity.tracked:
			if is_instance_valid(t.node) and t.node.is_inside_tree() and t.changed_ever:
				state[t.path] = t.full()
		if not state.is_empty():
			values[id] = state
		if not entity.removed.is_empty():
			removed[id] = entity.removed.keys()
	return {"alive": alive, "v": values, "rm": removed, "in": _input.full(), "fo": _focus,
		"dc": _draw_capture.full()}


# Where the focused UI element is: [entity id, path inside it], or [] if none.
func _focus_ref() -> Array:
	var node := get_viewport().gui_get_focus_owner()
	if node == null:
		return []
	var root := _entity_root_containing(node)
	if root == null:
		return []
	return [_entity_of_root[root.get_instance_id()], str(root.get_path_to(node))]


# Nodes removed from a recorded scene this frame (e.g. a menu freeing itself),
# unless their whole entity went or they were only moved: {entity id: [paths]}.
func _take_removed_members() -> Dictionary:
	var out := {}
	for entry in _removed_members:
		var id: int = entry[0]
		var node = entry[2]
		if not _entities.has(id):
			continue
		if is_instance_valid(node) and node.is_inside_tree():
			continue
		var path: String = entry[1]
		_entities[id].removed[path] = true
		if not out.has(id):
			out[id] = []
		out[id].append(path)
	_removed_members.clear()
	return out


#region Entities (what gets spawned and removed)

func _on_node_added(node: Node) -> void:
	if not recording or _is_ignored(node):
		return
	# Part of a scene that is already recorded (or about to be): not new.
	if _member_entity_root(node) != null:
		return
	_pending_roots.append(node)


func _on_node_removed(node: Node) -> void:
	if not recording:
		return
	var key := node.get_instance_id()
	if _entity_of_root.has(key):
		var id: int = _entity_of_root[key]
		_entity_of_root.erase(key)
		for member in _entities[id].members:
			_member_of.erase(member)
		_entities.erase(id)
		_despawns.append(id)
		return
	if _pending_roots.has(node):
		_pending_roots.erase(node)
		return
	# A node of a recorded scene going away on its own.
	var member = _member_of.get(key)
	if member != null and _entities.has(member[0]):
		_removed_members.append([member[0], member[1], node])


func _add_entity(root: Node) -> void:
	if _entity_of_root.has(root.get_instance_id()):
		return
	# Where it lives: inside which recorded entity, at which path.
	var parent_id := -1
	var parent_path := ""
	var parent := root.get_parent()
	var parent_root := _entity_root_containing(parent)
	if parent_root:
		parent_id = _entity_of_root[parent_root.get_instance_id()]
		parent_path = str(parent_root.get_path_to(parent))

	var entity := Entity.new()
	entity.id = _next_entity_id
	_next_entity_id += 1
	entity.root = root
	entity.info = {
		"id": entity.id,
		"parent": parent_id,
		"ppath": parent_path,
		"name": String(root.name),
		"scene": root.scene_file_path,
		"class": root.get_class(),
	}
	var defaults := _defaults_for(root)
	var live := {}
	for node in _members(root):
		var path := str(root.get_path_to(node))
		live[path] = true
		if node != root:
			entity.members.append(node.get_instance_id())
			_member_of[node.get_instance_id()] = [entity.id, path]
		var t = NodeState.track(node, path, defaults.get(path, {}))
		if t:
			entity.tracked.append(t)
			_prop_queue.append([entity.id, t])
		_draw_capture.add(node)
	_entities[entity.id] = entity
	_entity_of_root[root.get_instance_id()] = entity.id
	# Nodes of its scene file that were already gone (e.g. pickups a loaded
	# save removed): removed in the replay too. Only the top one of a branch.
	for path: String in defaults:
		if path != "." and not live.has(path):
			var above := path.get_base_dir()
			if above == "" or live.has(above):
				_removed_members.append([entity.id, path, null])
	_spawns.append(entity.info)


# Nodes that belong to an entity: its root and everything its scene owns.
func _members(root: Node) -> Array[Node]:
	var out: Array[Node] = [root]
	for node in root.find_children("*", "", true, false):
		if _owned_by(node, root):
			out.append(node)
	return out


static func _owned_by(node: Node, root: Node) -> bool:
	var o := node.owner
	while o:
		if o == root:
			return true
		o = o.owner
	return false


# The entity root this node belongs to as part of its scene, if any.
func _member_entity_root(node: Node) -> Node:
	var o := node.owner
	while o:
		if _entity_of_root.has(o.get_instance_id()) or _pending_roots.has(o):
			return o
		o = o.owner
	return null


# The recorded entity whose nodes include `node` (or the nearest ancestor's).
func _entity_root_containing(node: Node) -> Node:
	while node:
		if _entity_of_root.has(node.get_instance_id()):
			return node
		var owner_root := _member_entity_root(node)
		if owner_root and _entity_of_root.has(owner_root.get_instance_id()):
			return owner_root
		node = node.get_parent()
	return null


# Default values of every node in a scene (or of a bare node of that class),
# so only what differs from them gets recorded.
func _defaults_for(root: Node) -> Dictionary:
	var key := root.scene_file_path if root.scene_file_path != "" else "class:" + root.get_class()
	if _scene_defaults.has(key):
		return _scene_defaults[key]
	var template: Node = null
	if root.scene_file_path != "":
		var packed := load(root.scene_file_path) as PackedScene
		if packed:
			template = packed.instantiate()
	elif ClassDB.can_instantiate(root.get_class()):
		template = ClassDB.instantiate(root.get_class())
	var defaults := {}
	if template:
		defaults["."] = NodeState.read(template)
		# Nodes its scene has (not the ones a control makes for itself).
		for node in template.find_children("*", "", true, true):
			defaults[str(template.get_path_to(node))] = NodeState.read(node)
		template.free()
	_scene_defaults[key] = defaults
	return defaults


func _is_ignored(node: Node) -> bool:
	if node == self or is_ancestor_of(node):
		return true
	if node is Window:
		return true
	if node.has_meta(&"session_replay_ignore"):
		return true
	# Built-in parts of Godot's own controls (scroll bars, popup internals):
	# they come back by themselves when their control is rebuilt.
	if node.owner == null:
		var n := node
		while n.get_parent():
			if not n.get_parent().get_children(false).has(n):
				return true
			if n.owner != null:
				break
			n = n.get_parent()
	return false

#endregion


#region Input

func _on_window_input(event: InputEvent) -> void:
	if recording:
		_input.feed(event)


## Keys, mouse and gamepad as they are right now. Only changes are recorded.
class InputState:
	var keys := PackedInt32Array()   # physical keycodes held
	var mouse_buttons := 0           # bit (button_index - 1) per held button
	var mouse_motion := Vector2.ZERO # summed over this frame
	var wheel := 0                   # +1 up / -1 down this frame
	var pad_buttons := 0             # bit (button_index) per held button
	var pad_axes := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var device := "kbm"              # last used: "kbm" (keyboard/mouse) or "pad"
	var _dirty := {}
	var _sent_motion := false
	var _sent_wheel := false

	func feed(event: InputEvent) -> void:
		if event is InputEventKey:
			if event.echo:
				return
			var code: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
			var i := keys.find(code)
			if event.pressed and i < 0:
				keys.append(code)
				keys.sort()
				_dirty["k"] = true
			elif not event.pressed and i >= 0:
				keys.remove_at(i)
				_dirty["k"] = true
			_use("kbm")
		elif event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					wheel = 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1
			else:
				var bit: int = 1 << (event.button_index - 1)
				mouse_buttons = (mouse_buttons | bit) if event.pressed else (mouse_buttons & ~bit)
				_dirty["mb"] = true
			_use("kbm")
		elif event is InputEventMouseMotion:
			mouse_motion += event.relative
		elif event is InputEventJoypadButton:
			var bit: int = 1 << event.button_index
			pad_buttons = (pad_buttons | bit) if event.pressed else (pad_buttons & ~bit)
			_dirty["pb"] = true
			_use("pad")
		elif event is InputEventJoypadMotion and event.axis < 6:
			var value := snappedf(event.axis_value, 0.02)
			if absf(value) < 0.06:
				value = 0.0
			if value != pad_axes[event.axis]:
				pad_axes[event.axis] = value
				_dirty["pa"] = true
				if absf(value) > 0.3:
					_use("pad")

	func _use(d: String) -> void:
		if device != d:
			device = d
			_dirty["d"] = true

	func take_changes() -> Dictionary:
		var out := {}
		if _dirty.has("k"): out["k"] = keys.duplicate()
		if _dirty.has("mb"): out["mb"] = mouse_buttons
		if _dirty.has("pb"): out["pb"] = pad_buttons
		if _dirty.has("pa"): out["pa"] = pad_axes.duplicate()
		if _dirty.has("d"): out["d"] = device
		# Mouse motion and wheel only last a frame: sent while non-zero, then
		# once more as zero.
		if mouse_motion != Vector2.ZERO or _sent_motion:
			out["mm"] = mouse_motion
			_sent_motion = mouse_motion != Vector2.ZERO
		if wheel != 0 or _sent_wheel:
			out["w"] = wheel
			_sent_wheel = wheel != 0
		mouse_motion = Vector2.ZERO
		wheel = 0
		_dirty = {}
		return out

	func full() -> Dictionary:
		return {"k": keys.duplicate(), "mb": mouse_buttons, "mm": Vector2.ZERO, "w": 0,
			"pb": pad_buttons, "pa": pad_axes.duplicate(), "d": device}

#endregion


#region Helpers

static func main_scene_path() -> String:
	var main: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main.begins_with("uid://"):
		var id := ResourceUID.text_to_id(main)
		if ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return main


# "-- --no-record" -> {"no-record": ""}
static func _parse_args() -> Dictionary:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			continue
		var parts := arg.substr(2).split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	return args

#endregion
