# Plays a recording back by acting it out: the recorded scenes are loaded as
# "puppets" (the game's own scripts removed, nothing processing) and every
# frame the recorded node states are applied to them. Nothing is re-simulated,
# so playback shows exactly what happened and can jump anywhere instantly.
#
# Created by replay_runner.gd (the root of the scenes the Replays dock makes).
extends Node

const NodeState := preload("res://addons/session_replay/node_state.gd")
const PLAYER_UI := preload("res://addons/session_replay/replay_player_ui.gd")
const INPUT_SHIELD := preload("res://addons/session_replay/replay_input_shield.gd")
const SETTING_KEEP_SCRIPTS := "session_replay/keep_scripts_from"
## Going forward by more than this replays frame by frame; further jumps
## start from the nearest keyframe instead.
const MAX_STEP_SEEK := 300
## Playback never applies more frames than this in one rendered frame.
const MAX_FRAMES_PER_UPDATE := 8

signal finished

var header: Dictionary = {}

var _frames: Dictionary = {}       # frame -> record
var _keyframes: Array[int] = []    # frames that carry a full snapshot, sorted
var _length: int = 0
var _pos: int = -1                 # last frame applied
var _paused := false
var _speed := 1.0
var _clock := 0.0                  # replay time (s) being shown
var _ticks := 60
var _times := PackedFloat32Array() # frame -> when it happened (s)

var _container: Node               # puppets live here
var _puppets: Dictionary = {}      # entity id -> puppet root
var _originals: Dictionary = {}    # entity id -> {path: values before we changed them}
var _infos: Dictionary = {}        # entity id -> how it was spawned
var _removed: Dictionary = {}      # entity id -> {path: true} for nodes removed from it
var _scenes: Dictionary = {}       # scene path -> PackedScene
var _keep_prefixes: PackedStringArray
# Puppet nodes that run by themselves (particles, videos): they're paused and
# sped up with the replay.
var _live: Array[Node] = []
# What the game's scripts drew themselves (draw_capture.gd): canvas id -> a
# CanvasLayer showing the recorded picture.
var _drawn := {}
var _input: Dictionary = {}
var _ui: Control
# The recorded sound (session_<date>.wav next to the recording), if any.
var _audio: AudioStreamPlayer
var _volume := 1.0


#region Loading

## Loads a recording. Returns false (and says why) if it can't be played.
func open(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("Session Replay: can't open %s" % path)
		return false
	header = f.get_var()
	if not (header is Dictionary) or not header.get("header", false) or int(header.get("version", 0)) != 2:
		push_error("Session Replay: %s is not a recording this version can play (record a new session)." % path)
		return false
	NodeState.Tracked.clear_recorded_textures()
	while f.get_position() < f.get_length():
		var rec = f.get_var()
		if not (rec is Dictionary):
			break # cut short (game crashed while recording): play what we have
		if rec.has("end"):
			_length = maxi(_length, int(rec["end"]) - 1)
			break
		var frame := int(rec["f"])
		_frames[frame] = rec
		NodeState.Tracked.recorded_textures.merge(rec.get("tex", {}), true)
		_length = maxi(_length, frame)
		if rec.has("key"):
			_keyframes.append(frame)
	_keyframes.sort()
	if _keyframes.is_empty():
		push_error("Session Replay: %s has no frames." % path)
		return false
	_ticks = int(header.get("ticks", 60))
	_build_times()
	# session_x.wav in the recordings folder; replay_x.swav next to a replay
	# scene (not .wav there, so Godot doesn't import a second copy of it).
	var wav_path := path.get_basename() + ".wav"
	if not FileAccess.file_exists(wav_path):
		wav_path = path.get_basename() + ".swav"
	if FileAccess.file_exists(wav_path):
		var stream := AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(wav_path))
		if stream:
			_audio = AudioStreamPlayer.new()
			_audio.name = "RecordedSound"
			_audio.stream = stream
	return true


# When each frame happened. Recordings say it ("ms"); between two frames that
# say it, and in older recordings, frames are 1 / ticks apart.
func _build_times() -> void:
	_times.resize(_length + 1)
	var last_frame := 0
	var last_time := 0.0
	for f in _length + 1:
		var rec: Dictionary = _frames.get(f, {})
		if rec.has("ms"):
			last_frame = f
			last_time = float(rec["ms"]) / 1000.0
		_times[f] = last_time + float(f - last_frame) / _ticks
	# Never backwards (keeps seeking by time simple).
	for f in range(1, _times.size()):
		_times[f] = maxf(_times[f], _times[f - 1])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_keep_prefixes = PackedStringArray(ProjectSettings.get_setting(SETTING_KEEP_SCRIPTS, ["res://addons/"]))
	_container = Node.new()
	_container.name = "Puppets"
	# Nothing in the recorded scenes runs: no processing, no physics, no input.
	_container.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(_container)
	if _audio:
		add_child(_audio)
	_quiet_autoloads()
	# Your own pointer, normal, for the replay controls.
	Input.set_custom_mouse_cursor(null)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_ui = PLAYER_UI.new()
	_ui.player = self
	layer.add_child(_ui)

	var shield := INPUT_SHIELD.new()
	shield.name = "SessionReplayInputShield"
	shield.player_ui = _ui
	get_tree().root.add_child.call_deferred(shield)

	seek(0)


# The game's autoloads keep running in a replay scene: stop them, so their
# code can't capture or hide the mouse, play sounds or change things. (They
# get no input either: see replay_input_shield.gd.)
func _quiet_autoloads() -> void:
	var tree_root := get_tree().root
	for node in tree_root.get_children():
		if node == get_tree().current_scene or node.is_ancestor_of(self) or node == self:
			continue
		if node.name == &"SessionRecorder":
			continue
		if ProjectSettings.has_setting("autoload/" + node.name):
			node.process_mode = Node.PROCESS_MODE_DISABLED


func _process(delta: float) -> void:
	# The recorded game may have captured or hidden the mouse.
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_sync_audio()
	_update_live()

	if _paused or _pos >= _length:
		return
	_clock += delta * _speed
	var steps := 0
	while _pos < _length and _times[_pos + 1] <= _clock:
		if steps >= MAX_FRAMES_PER_UPDATE:
			# Can't keep up: slow down rather than skip.
			_clock = _times[_pos]
			break
		_apply_frame(_pos + 1)
		_pos += 1
		steps += 1
	if _pos >= _length:
		_paused = true
		finished.emit()


# Particles and videos run by themselves: stopped while paused, at the
# replay's speed otherwise.
func _update_live() -> void:
	var stopped := _paused or _pos >= _length
	for i in range(_live.size() - 1, -1, -1):
		var node := _live[i]
		if not is_instance_valid(node):
			_live.remove_at(i)
			continue
		if node is VideoStreamPlayer:
			node.paused = stopped or node.get_meta(&"_sr_paused", false)
		else:
			node.speed_scale = 0.0 if stopped else node.get_meta(&"_sr_speed", 1.0) * _speed

#endregion


#region Controls (used by the player bar)

func replay_position() -> int:
	return maxi(_pos, 0)


func replay_length() -> int:
	return maxi(_length, 1)


func replay_ticks_per_second() -> int:
	return _ticks


## Seconds into the recording of the frame being shown, and in all.
func replay_time() -> float:
	return _times[clampi(_pos, 0, _length)] if not _times.is_empty() else 0.0


func replay_duration() -> float:
	return _times[_length] if not _times.is_empty() else 0.0


func is_replay_paused() -> bool:
	return _paused


func is_replay_finished() -> bool:
	return _pos >= _length


## Playback speed (1 = real time). The sound speeds up / slows down with it.
func set_speed(speed: float) -> void:
	_speed = speed
	if _audio:
		_audio.pitch_scale = speed


func get_speed() -> float:
	return _speed


## Volume of the recorded sound, 0 to 1.
func set_volume(volume: float) -> void:
	_volume = clampf(volume, 0.0, 1.0)
	if _audio:
		_audio.volume_db = linear_to_db(maxf(_volume, 0.0001))


func get_volume() -> float:
	return _volume


func has_sound() -> bool:
	return _audio != null


# Keeps the sound where the picture is: playing while the replay plays, and
# moved to the right time after a jump (or if it drifts off).
func _sync_audio() -> void:
	if _audio == null:
		return
	var playing := not _paused and _pos < _length
	var time := replay_time()
	if not playing:
		if _audio.playing:
			_audio.stream_paused = true
		return
	if not _audio.playing:
		_audio.play(time)
	elif _audio.stream_paused:
		_audio.stream_paused = false
		_audio.seek(time)
	elif absf(_audio.get_playback_position() - time) > 0.12:
		_audio.seek(time)


func set_replay_paused(paused: bool) -> void:
	# Pressing play at the end starts over.
	if not paused and _pos >= _length:
		seek(0)
	_paused = paused
	_clock = replay_time()


func skip_frames(frames: int) -> void:
	seek(_pos + frames)


## One frame forward or back (meant for while paused).
func step_frame(direction: int) -> void:
	seek(_pos + signi(direction))


## Shows the recording as it was at `target`. Instant in both directions.
func seek(target: int) -> void:
	target = clampi(target, 0, _length)
	if target == _pos:
		return
	if target > _pos and target - _pos <= MAX_STEP_SEEK:
		for f in range(_pos + 1, target + 1):
			_apply_frame(f)
	else:
		var key := _keyframes[0]
		for k in _keyframes:
			if k <= target:
				key = k
			else:
				break
		_apply_keyframe(key)
		for f in range(key + 1, target + 1):
			_apply_frame(f)
	_pos = target
	_clock = replay_time()


## Shows the recording as it was `time` seconds in.
func seek_time(time: float) -> void:
	var lo := 0
	var hi := _length
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _times[mid] <= time:
			lo = mid
		else:
			hi = mid - 1
	seek(lo)


## Keys, mouse and gamepad at the current frame (for the input overlay).
func input_state() -> Dictionary:
	return _input

#endregion


#region Applying recorded frames

func _apply_frame(f: int) -> void:
	var rec: Dictionary = _frames.get(f, {})
	if rec.is_empty():
		_input["mm"] = Vector2.ZERO
		_input["w"] = 0
		return
	# A frame's own keyframe isn't needed when coming from the frame before.
	for id in rec.get("dp", []):
		_despawn(id)
	for info in rec.get("sp", []):
		_spawn(info)
	var removals: Dictionary = rec.get("rm", {})
	for id in removals:
		for path in removals[id]:
			_remove_member(id, path)
	_apply_values(rec.get("v", {}))
	var changes: Dictionary = rec.get("in", {})
	if not changes.has("mm"):
		_input["mm"] = Vector2.ZERO
	if not changes.has("w"):
		_input["w"] = 0
	_input.merge(changes, true)
	if rec.has("fo"):
		_apply_focus(rec["fo"])
	if rec.has("dc"):
		_apply_drawn(rec["dc"])


func _apply_keyframe(f: int) -> void:
	var key: Dictionary = _frames[f]["key"]
	var alive := {}
	for info in key["alive"]:
		alive[int(info["id"])] = info
	var removed: Dictionary = key.get("rm", {})
	for id in _puppets.keys():
		if not alive.has(id) or not _puppets.has(id) or not is_instance_valid(_puppets[id]):
			_despawn(id)
			continue
		# A node of it that was removed later than this keyframe can't be put
		# back: build that puppet again.
		var wanted: Array = removed.get(id, [])
		for path in _removed[id]:
			if not wanted.has(path):
				_despawn(id)
				break
	# Puppets that stay: back to their scene's values before applying the snapshot.
	for id in _puppets:
		_restore(id, key["v"].get(id, {}))
	for info in key["alive"]:
		var id := int(info["id"])
		if not _puppets.has(id):
			_spawn(info)
		for path in removed.get(id, []):
			_remove_member(id, path)
	_apply_values(key["v"])
	_input = key["in"].duplicate(true)
	_apply_focus(key.get("fo", []))
	_apply_drawn(key.get("dc", {}), true)


func _apply_values(values: Dictionary) -> void:
	# Bone poses last: an AnimationPlayer seeked in this frame would move them.
	var bones := []
	for id in values:
		var puppet: Node = _puppets.get(id)
		if puppet == null or not is_instance_valid(puppet):
			continue
		var originals: Dictionary = _originals[id]
		var by_path: Dictionary = values[id]
		for path in by_path:
			var node := puppet.get_node_or_null(NodePath(path))
			if node == null:
				continue
			var vals: Dictionary = by_path[path]
			if not originals.has(path):
				originals[path] = NodeState.read(node, false)
			if vals.has("p"):
				# Only the properties the recording changes are remembered.
				var original: Dictionary = originals[path]
				if not original.has("p"):
					original["p"] = {}
				for prop in vals["p"]:
					if not original["p"].has(prop):
						original["p"][prop] = node.get(prop)
			if vals.has("sk"):
				bones.append([node, vals["sk"]])
				vals = vals.duplicate()
				vals.erase("sk")
			NodeState.apply(node, vals)
	for b in bones:
		NodeState.apply(b[0], {"sk": b[1]})


# Shows what the game's scripts drew themselves, as recorded. With `all`,
# pictures not in `changes` are hidden (a keyframe has every one shown).
func _apply_drawn(changes: Dictionary, all := false) -> void:
	if all:
		for key in _drawn:
			if not changes.has(key):
				_drawn[key].visible = false
	for key in changes:
		var v: Array = changes[key]
		var layer: CanvasLayer = _drawn.get(key)
		if v.is_empty():
			if layer:
				layer.visible = false
			continue
		var image := Image.new()
		if image.load_png_from_buffer(v[4]) != OK:
			continue
		if layer == null:
			layer = CanvasLayer.new()
			layer.name = "Drawn"
			var picture := TextureRect.new()
			picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
			picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			picture.stretch_mode = TextureRect.STRETCH_SCALE
			# The recorded pictures have their colors already multiplied by alpha.
			var material := CanvasItemMaterial.new()
			material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
			picture.material = material
			layer.add_child(picture)
			add_child(layer)
			_drawn[key] = layer
		layer.layer = v[0]
		layer.visible = true
		var rect: TextureRect = layer.get_child(0)
		rect.texture = ImageTexture.create_from_image(image)
		rect.position = Vector2(v[1], v[2])
		rect.size = Vector2(image.get_size()) / float(v[3])


# Shows which UI element had keyboard / gamepad focus (the highlighted button).
func _apply_focus(ref: Array) -> void:
	var node: Control = null
	if ref.size() == 2:
		var puppet = _puppets.get(int(ref[0]))
		if puppet != null and is_instance_valid(puppet):
			node = puppet.get_node_or_null(NodePath(ref[1])) as Control
	if node and node.is_visible_in_tree():
		node.grab_focus()
	else:
		get_viewport().gui_release_focus()


# Puts a puppet back as its scene has it, before a keyframe is applied.
# Properties ("p") that the keyframe sets again anyway are left alone (setting
# some of them twice, like a viewport's own world, upsets the engine); their
# originals are kept for the next time.
func _restore(id: int, keyframe_values: Dictionary = {}) -> void:
	var puppet: Node = _puppets[id]
	var originals: Dictionary = _originals[id]
	var kept_originals := {}
	for path in originals:
		var node := puppet.get_node_or_null(NodePath(path))
		if node == null:
			continue
		var values: Dictionary = originals[path]
		var kept := {}
		if values.has("p"):
			var in_key: Dictionary = keyframe_values.get(path, {}).get("p", {})
			# Put back in the opposite order they were changed in (a mesh's
			# material before the mesh, and so on).
			var props := {}
			var names: Array = values["p"].keys()
			names.reverse()
			for prop in names:
				if in_key.has(prop):
					kept[prop] = values["p"][prop]
				else:
					props[prop] = values["p"][prop]
			values = values.duplicate()
			values["p"] = props
		NodeState.apply(node, values)
		if not kept.is_empty():
			var original := NodeState.read(node, false)
			original["p"] = kept
			kept_originals[path] = original
	_originals[id] = kept_originals

#endregion


#region Puppets

func _spawn(info: Dictionary) -> void:
	var id := int(info["id"])
	if _puppets.has(id) and is_instance_valid(_puppets[id]):
		return
	var parent: Node = _container
	var parent_puppet = _puppets.get(int(info["parent"]))
	if parent_puppet != null and is_instance_valid(parent_puppet):
		parent = parent_puppet.get_node_or_null(NodePath(info["ppath"]))
		if parent == null:
			parent = parent_puppet

	var node: Node = null
	var scene_path: String = info.get("scene", "")
	if scene_path != "":
		if not _scenes.has(scene_path):
			_scenes[scene_path] = load(scene_path)
		var packed := _scenes[scene_path] as PackedScene
		if packed:
			node = packed.instantiate()
	if node == null:
		var cls: String = info.get("class", "Node")
		node = ClassDB.instantiate(cls) if ClassDB.can_instantiate(cls) else Node.new()
	_make_puppet(node)
	node.name = info["name"]
	parent.add_child(node)
	_puppets[id] = node
	_originals[id] = {}
	_infos[id] = info
	_removed[id] = {}


func _despawn(id) -> void:
	var node = _puppets.get(id)
	_forget(id)
	if node == null or not is_instance_valid(node):
		return
	# Puppets inside it go with it.
	for other in _puppets.keys():
		var p = _puppets[other]
		if not is_instance_valid(p) or node.is_ancestor_of(p):
			_forget(other)
	node.get_parent().remove_child(node)
	node.queue_free()


func _forget(id) -> void:
	_puppets.erase(id)
	_originals.erase(id)
	_infos.erase(id)
	_removed.erase(id)


func _remove_member(id, path: String) -> void:
	var puppet = _puppets.get(id)
	if puppet == null or not is_instance_valid(puppet) or _removed[id].has(path):
		return
	_removed[id][path] = true
	var node: Node = puppet.get_node_or_null(NodePath(path))
	if node and node != puppet:
		node.get_parent().remove_child(node)
		node.queue_free()


# The game's scripts don't run in a replay: they're removed (except @tool ones
# from folders listed in Project Settings > session_replay/keep_scripts_from,
# like addons that build meshes), and so are signal connections that pointed
# at them.
func _make_puppet(root: Node) -> void:
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "", true, false))
	for node in nodes:
		var script := node.get_script() as Script
		if script and not _keep_script(script):
			node.set_script(null)
		# Your own mouse doesn't hover or press the recorded UI.
		if node is Control:
			node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# The recording has all the sound, and the final bone poses.
		if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
			node.autoplay = false
		elif node is SkeletonModifier3D or node is AnimationTree:
			node.active = false
		# These run by themselves in a replay (see _update_live).
		elif node is GPUParticles3D or node is CPUParticles3D or node is GPUParticles2D 				or node is CPUParticles2D:
			node.set_meta(&"_sr_speed", node.speed_scale)
			node.process_mode = Node.PROCESS_MODE_ALWAYS
			_live.append(node)
		elif node is VideoStreamPlayer:
			node.process_mode = Node.PROCESS_MODE_ALWAYS
			_live.append(node)
	for node in nodes:
		for sig in node.get_signal_list():
			for c in node.get_signal_connection_list(sig["name"]):
				# Only connections saved in the scene file (made in the editor).
				if not (c["flags"] & CONNECT_PERSIST):
					continue
				var callable: Callable = c["callable"]
				var target := callable.get_object()
				if target == null or not is_instance_valid(target) or not target.has_method(callable.get_method()):
					node.disconnect(sig["name"], callable)


func _keep_script(script: Script) -> bool:
	return NodeState.kept_in_replay(script, _keep_prefixes)

#endregion

