# Which properties of a node are recorded, and how they are read and applied.
#
#   key  property                         nodes
#   t    local transform (pos + rotation  Node3D
#        [+ scale])
#   tl   top_level (detached from parent) Node3D
#   t2   position, rotation, scale        Node2D
#   cs   scale, rotation                  Control not placed by a Container
#   ao   anchors, offsets                 Control not placed by a Container
#                                         (not position / size: those depend
#                                         on the parent's size and minimum
#                                         sizes, which settle later)
#   bp   button_pressed                   BaseButton in toggle mode
#   ms   custom_minimum_size              Control (containers lay out by it)
#   gc   columns                          GridContainer
#   sc   scroll position                  ScrollContainer
#   tx   texture (see texture_ref)        TextureRect, TextureButton, Sprite2D,
#                                         Sprite3D
#   fr   frame                            Sprite2D, Sprite3D
#   af   animation, frame, progress       AnimatedSprite2D, AnimatedSprite3D
#   an   animation, position              AnimationPlayer (playback seeks the
#                                         puppet's own player there, so all
#                                         the animation moves shows up too)
#   v    visible                          Node3D, CanvasItem, CanvasLayer
#   m    modulate                         CanvasItem
#   x    text                             Label, Button, RichTextLabel, LineEdit,
#                                         TextEdit, Label3D
#   r    value                            Range (progress bars, sliders)
#   c    current                          Camera3D
#   fv   fov (zoom)                       Camera3D
#   e    emitting                         particles (2D and 3D)
#   sk   bone poses, as shown (after      Skeleton3D (animations, ragdolls)
#        animation, IK, ragdoll physics)
#   vp   playing, position                VideoStreamPlayer
#   dm   lines / shapes drawn by code     MeshInstance3D showing an ImmediateMesh
#   p    every other property the node    any node
#        saves (colors, fonts, theme
#        overrides, size flags, materials,
#        meshes...) that differs from its
#        scene (or a new node of its class)
#
# "p" is what makes UI built or styled by code look right: it's checked when a
# node first appears, then again in the background a few nodes per frame.
#
# Shared by the recorder (track / capture) and the player (read / apply).
extends RefCounted

# Properties "p" never records: recorded by their own key above, about how the
# node runs rather than how it looks, or things that would make a replay act
# (play sounds, run animations).
const SKIP_PROPS := {
	"script": true, "name": true, "owner": true, "scene_file_path": true,
	"unique_name_in_owner": true, "editor_description": true, "multiplayer": true,
	"process_mode": true, "process_priority": true, "process_physics_priority": true,
	"process_thread_group": true, "process_thread_group_order": true,
	"process_thread_messages": true, "physics_interpolation_mode": true,
	"auto_translate_mode": true,
	"transform": true, "position": true, "rotation": true, "rotation_degrees": true,
	"quaternion": true, "basis": true, "scale": true, "rotation_edit_mode": true,
	"rotation_order": true, "top_level": true, "visible": true, "modulate": true,
	"global_transform": true, "global_position": true, "global_rotation": true,
	"global_rotation_degrees": true, "global_basis": true, "global_scale": true,
	"size": true, "anchor_left": true, "anchor_top": true, "anchor_right": true,
	"anchor_bottom": true, "offset_left": true, "offset_top": true, "offset_right": true,
	"offset_bottom": true, "layout_mode": true, "anchors_preset": true,
	"custom_minimum_size": true, "text": true, "value": true, "current": true, "fov": true,
	"emitting": true, "frame": true, "frame_progress": true, "animation": true,
	"columns": true, "scroll_horizontal": true, "scroll_vertical": true,
	"button_pressed": true, "playing": true, "autoplay": true, "stream_paused": true,
	"paused": true, "stream_position": true, "speed_scale": true, "active": true,
	"current_animation": true, "assigned_animation": true, "libraries": true,
	"mouse_filter": true,
}


## All recorded values of a node, as a Dictionary. Without `with_props`, the
## "p" properties are left out (playback remembers those one by one).
static func read(node: Node, with_props := true) -> Dictionary:
	return Tracked.read_node(node, with_props)


## Sets recorded values back on a node (used by playback).
static func apply(node: Node, d: Dictionary) -> void:
	for key in d:
		var v = d[key]
		match key:
			"p":
				# Counts first (tab_count, item_count...): the items they make
				# come after.
				var props: Array = v.keys()
				props.sort_custom(func(a, b): return a.ends_with("_count") and not b.ends_with("_count"))
				for prop in props:
					var value = Tracked.decode_value(v[prop])
					var current = node.get(prop)
					if Tracked.same(current, value):
						continue
					if prop.begins_with("surface_material_override/") 							and int(prop.get_slice("/", 1)) >= node.get_surface_override_material_count():
						continue
					if current is Array and value is Array and current.is_typed():
						value = Array(value, current.get_typed_builtin(),
							current.get_typed_class_name(), current.get_typed_script())
					node.set(prop, value)
			"sk":
				Tracked.apply_bones(node, v)
			"vp":
				_apply_video(node, v)
			"dm":
				node.mesh = Tracked.mesh_from_surfaces(v) if v is Array else v
			"tl":
				# Turning top_level on or off keeps where the node is on screen;
				# the recorded transform is the local one, so it's put back.
				var t: Transform3D = node.transform
				node.top_level = v
				node.transform = t
			"t":
				node.transform = Tracked.decode_t3(v)
			"t2":
				node.position = Vector2(v[0], v[1])
				node.rotation = v[2]
				node.scale = Vector2(v[3], v[4])
			"cs":
				node.scale = Vector2(v[0], v[1])
				node.rotation = v[2]
			"ao":
				for side in 4:
					node.set_anchor(side, v[side], false, false)
				for side in 4:
					node.set_offset(side, v[4 + side])
			"bp":
				node.set_pressed_no_signal(v)
			"ms":
				node.custom_minimum_size = v
			"gc":
				node.columns = v
			"sc":
				node.scroll_horizontal = v[0]
				node.scroll_vertical = v[1]
			"tx":
				node.set(Tracked.texture_property(node), Tracked.texture_from_ref(v))
			"fr":
				node.frame = v
			"af":
				if node.sprite_frames and node.sprite_frames.has_animation(v[0]):
					node.animation = v[0]
					node.set_frame_and_progress(v[1], v[2])
			"an":
				_apply_animation(node, v)
			"v":
				node.visible = v
			"m":
				node.modulate = v
			"x":
				node.text = v
			"r":
				node.set_value_no_signal(v)
			"c":
				node.current = v
			"fv":
				node.fov = v
			"e":
				node.emitting = v


# Shows an AnimationPlayer's animation at the recorded time. Puppets don't
# process, so the player only moves when it is seeked here.
static func _apply_animation(player: AnimationPlayer, v: Array) -> void:
	var anim := StringName(v[0])
	if anim == &"" or not player.has_animation(anim):
		return
	if player.assigned_animation != anim:
		player.assigned_animation = anim
	player.seek(v[1], true)


# Plays / pauses a video as it was. Its puppet processes (see replay_player.gd),
# so it runs by itself; it's only moved when it is too far from the recording.
# Playback pauses it too while the replay is paused ("_sr_paused" is what the
# recording wants).
static func _apply_video(video: VideoStreamPlayer, v) -> void:
	if not (v is Array):
		return
	var playing: bool = v[0]
	video.set_meta(&"_sr_paused", not playing)
	if playing:
		if not video.is_playing():
			video.play()
		video.paused = false
		if absf(video.stream_position - float(v[1])) > 1.5:
			video.stream_position = v[1]
	elif video.is_playing():
		video.paused = true


## Whether playback keeps a node's script running: only @tool scripts from
## the folders in Project Settings > session_replay/keep_scripts_from. They're
## written to work without the rest of the game around them (in the editor),
## so they also work in a replay; other scripts expect the game's other
## scripts and nodes, which a replay doesn't have.
static func kept_in_replay(script: Script, prefixes: PackedStringArray) -> bool:
	if not script.is_tool():
		return false
	var path := script.resource_path.get_slice("::", 0)
	for prefix in prefixes:
		if path.begins_with(prefix):
			return true
	return false


## Starts tracking a node, or returns null if nothing about it is recorded.
## `defaults` are the node's values as its scene file has them: only values
## that differ from those get recorded.
static func track(node: Node, path: String, defaults: Dictionary) -> Tracked:
	var k := Tracked.kinds_of(node)
	var props := Tracked.prop_names(node)
	if k == 0 and props.is_empty():
		return null
	var t := Tracked.new()
	t.node = node
	t.path = path
	t.kinds = k
	t.props = props
	if defaults.is_empty():
		t.first = true
	else:
		t.set_last(defaults)
	if k & Tracked.K_BONES:
		node.skeleton_updated.connect(t._on_skeleton_updated)
	return t


## The last recorded values of one node. Compared every frame without
## allocating anything unless something changed.
class Tracked:
	const K_T3 := 1
	const K_T2 := 2
	const K_CS := 4
	const K_VIS := 8
	const K_MOD := 16
	const K_TEXT := 32
	const K_RANGE := 64
	const K_CAM := 128
	const K_EMIT := 256
	const K_TOP := 512
	const K_LAYOUT := 1024
	const K_MIN := 2048
	const K_COLS := 4096
	const K_SCROLL := 8192
	const K_TEX := 16384
	const K_FRAME := 32768
	const K_ASPRITE := 65536
	const K_ANIM := 131072
	const K_PRESSED := 262144
	const K_BONES := 524288
	const K_VIDEO := 1048576
	const K_DYNMESH := 2097152
	const K_FOV := 4194304

	## A value "p" can't record (e.g. a node, or a resource with a script).
	const SKIP := "@@session_replay_skip@@"
	## Lines drawn by code are recorded at most every this many frames.
	const DYNMESH_EVERY := 6
	const BONE_ROT_EPSILON := 0.0015
	const BONE_POS_EPSILON := 0.0005
	const SAVE_TEMP := "user://session_replay_tmp.res"
	const RESOURCE_CACHE := "user://session_replay_cache"

	# Resources that aren't a file of the project (made by code, or embedded in
	# a scene) are saved into the recording once and referred to by id:
	# textures as PNG, anything else as a .res file ({"res": bytes}).
	# Recording: resource instance id -> id (or null: can't be saved), and the
	# ones not written yet.
	static var _texture_ids := {}
	static var _new_textures := {}
	# Playback: id -> what the recording saved, and the decoded resources.
	static var recorded_textures := {}
	static var _decoded_textures := {}
	# Property names "p" checks, per class.
	static var _prop_names := {}

	var node: Node
	var path: String
	var kinds: int
	var changed_ever := false
	var first := false
	## Properties "p" checks on this node.
	var props := PackedStringArray()
	## Set when "p" should be checked on the next capture (when the node
	## appears; the recorder sets it again for a few nodes every frame).
	var check_props := true
	## Frames in a row nothing changed (the recorder checks nodes that have
	## been still for a while less often).
	var idle := 0
	# Last recorded "p" values (the node's own, not encoded), and which ones
	# were ever recorded (so keyframes have them).
	var _props := {}
	var _props_recorded := {}
	# Bone poses as last recorded (quantized like the file has them), and as
	# the skeleton last showed them (from skeleton_updated).
	var _bq := PackedFloat32Array()
	var _bp := PackedFloat32Array()
	var _live_q := PackedFloat32Array()
	var _live_p := PackedFloat32Array()
	var _dm_hash := 0
	var _dm_wait := 0
	var _dm: Array = []
	var _vp := []

	var _t3: Transform3D
	var _t2 := PackedFloat32Array()
	var _cs := Vector3.ZERO
	var _vis := true
	var _mod := Color.WHITE
	var _text := ""
	var _range := 0.0
	var _cam := false
	var _fov := 0.0
	var _emit := false
	var _top := false
	var _layout := PackedFloat32Array()
	var _pressed := false
	var _min := Vector2.ZERO
	var _cols := 0
	var _scroll := Vector2i.ZERO
	var _tex: Texture2D = null
	var _frame := 0
	var _asprite := []
	var _anim := []

	static func kinds_of(n: Node) -> int:
		var k := 0
		if n is Node3D:
			k |= K_T3 | K_VIS | K_TOP
			if n is Camera3D:
				k |= K_CAM | K_FOV
			if n is GPUParticles3D or n is CPUParticles3D:
				k |= K_EMIT
			if n is Sprite3D:
				k |= K_TEX | K_FRAME
			if n is AnimatedSprite3D:
				k |= K_ASPRITE
			if n is Label3D:
				k |= K_TEXT
			if n is Skeleton3D:
				k |= K_BONES
			# (Checked here, not every frame: scenes have lots of meshes. A
			# mesh set later is noticed by capture_props.)
			if n is MeshInstance3D and n.mesh is ImmediateMesh:
				k |= K_DYNMESH
		elif n is CanvasItem:
			k |= K_VIS | K_MOD
			if n is Node2D:
				k |= K_T2
			if n is GPUParticles2D or n is CPUParticles2D:
				k |= K_EMIT
			if n is Sprite2D:
				k |= K_TEX | K_FRAME
			if n is AnimatedSprite2D:
				k |= K_ASPRITE
			if n is Control:
				k |= K_MIN
				if not (n.get_parent() is Container):
					k |= K_CS | K_LAYOUT
				if n is BaseButton and n.toggle_mode:
					k |= K_PRESSED
				if n is GridContainer:
					k |= K_COLS
				if n is ScrollContainer:
					k |= K_SCROLL
				if n is TextureRect or n is TextureButton or n is NinePatchRect:
					k |= K_TEX
				if n is Label or n is Button or n is RichTextLabel or n is LineEdit or n is TextEdit:
					k |= K_TEXT
				if n is Range:
					k |= K_RANGE
				if n is VideoStreamPlayer:
					k |= K_VIDEO
		elif n is CanvasLayer:
			k |= K_VIS
		elif n is AnimationPlayer:
			k |= K_ANIM
		return k

	static func read_node(n: Node, with_props := true) -> Dictionary:
		var k := kinds_of(n)
		var d := {}
		if with_props:
			var p := {}
			for prop in prop_names(n):
				var v = n.get(prop)
				if typeof(v) != TYPE_OBJECT or v is Resource:
					p[prop] = v
			d["p"] = p
		if k & K_BONES: d["sk"] = bones_full(local_poses(n))
		if k & K_VIDEO: d["vp"] = [false, 0.0]
		if k & K_DYNMESH: d["dm"] = n.mesh
		# top_level first: it changes what "transform" means.
		if k & K_TOP: d["tl"] = n.top_level
		if k & K_T3: d["t"] = encode_t3(n.transform)
		if k & K_T2: d["t2"] = PackedFloat32Array([n.position.x, n.position.y, n.rotation, n.scale.x, n.scale.y])
		if k & K_CS: d["cs"] = PackedFloat32Array([n.scale.x, n.scale.y, n.rotation])
		if k & K_VIS: d["v"] = n.visible
		if k & K_MOD: d["m"] = n.modulate
		if k & K_TEXT: d["x"] = n.text
		if k & K_RANGE: d["r"] = n.value
		if k & K_CAM: d["c"] = n.current
		if k & K_FOV: d["fv"] = n.fov
		if k & K_EMIT: d["e"] = n.emitting
		if k & K_LAYOUT: d["ao"] = layout_of(n)
		if k & K_PRESSED: d["bp"] = n.button_pressed
		if k & K_MIN: d["ms"] = n.custom_minimum_size
		if k & K_COLS: d["gc"] = n.columns
		if k & K_SCROLL: d["sc"] = PackedInt32Array([n.scroll_horizontal, n.scroll_vertical])
		# The texture itself, not a reference: read() is only used for scene
		# defaults and playback's originals, which are never saved.
		if k & K_TEX: d["tx"] = n.get(texture_property(n))
		if k & K_FRAME: d["fr"] = n.frame
		if k & K_ASPRITE: d["af"] = asprite_state(n)
		if k & K_ANIM: d["an"] = anim_state(n)
		return d

	static func layout_of(n: Control) -> PackedFloat32Array:
		return PackedFloat32Array([n.anchor_left, n.anchor_top, n.anchor_right, n.anchor_bottom,
			n.offset_left, n.offset_top, n.offset_right, n.offset_bottom])

	## Textures drawn live by a SubViewport aren't recorded: the replayed
	## scene's own SubViewport draws them again (a saved picture of one would
	## be a single, often blank, frame).
	static func is_live_texture(tex: Texture2D) -> bool:
		return tex is ViewportTexture

	static func texture_property(n: Node) -> StringName:
		return &"texture_normal" if n is TextureButton else &"texture"

	static func asprite_state(n: Node) -> Array:
		return [String(n.animation), n.frame, snappedf(n.frame_progress, 0.001)]

	static func anim_state(n: AnimationPlayer) -> Array:
		var anim := n.assigned_animation
		if anim == &"" or not n.has_animation(anim):
			return ["", 0.0]
		return [String(anim), snappedf(n.current_animation_position, 0.0001)]

	## How a texture is saved: its file path, the id of a texture saved in the
	## recording (see take_new_textures), or "" for none.
	static func texture_ref(tex: Texture2D) -> Variant:
		if tex == null:
			return ""
		var path := tex.resource_path
		if path != "" and not path.contains("::"):
			return path
		var key := tex.get_instance_id()
		if _texture_ids.has(key):
			return _texture_ids[key]
		var id := _texture_ids.size() + 1
		_texture_ids[key] = id
		var image := tex.get_image()
		_new_textures[id] = image.save_png_to_buffer() if image else PackedByteArray()
		return id

	## Textures referenced for the first time since the last call: {id: PNG}.
	static func take_new_textures() -> Dictionary:
		var out := _new_textures
		_new_textures = {}
		return out

	## Forgets the textures of the recording played before.
	static func clear_recorded_textures() -> void:
		recorded_textures = {}
		_decoded_textures = {}

	## A texture as texture_ref() saved it (or as read() returned it).
	static func texture_from_ref(v) -> Texture2D:
		if v == null or v is Texture2D:
			return v
		if v is String:
			if v == "" or not ResourceLoader.exists(v):
				return null
			return load(v) as Texture2D
		return resource_from_ref(v) as Texture2D

	## A resource as resource_ref() saved it: a file path or a saved id.
	static func resource_from_ref(v) -> Resource:
		if v == null or v is Resource:
			return v
		if v is String:
			if v == "" or not ResourceLoader.exists(v):
				return null
			return load(v)
		if _decoded_textures.has(v):
			return _decoded_textures[v]
		var res: Resource = null
		var saved = recorded_textures.get(v)
		if saved is PackedByteArray:
			var image := Image.new()
			if not saved.is_empty() and image.load_png_from_buffer(saved) == OK:
				res = ImageTexture.create_from_image(image)
		elif saved is Dictionary and saved.has("res"):
			# Loaded from a file: write it to the user folder first.
			DirAccess.make_dir_recursive_absolute(RESOURCE_CACHE)
			var file := "%s/%s.res" % [RESOURCE_CACHE, str(v)]
			var f := FileAccess.open(file, FileAccess.WRITE)
			if f:
				f.store_buffer(saved["res"])
				f.close()
				res = ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE)
		_decoded_textures[v] = res
		return res

	## How a resource is saved in "p": its file path, or the id of a copy saved
	## in the recording. null if it can't be saved (it has a script: game data,
	## not something that's shown).
	static func resource_ref(res: Resource) -> Variant:
		if res is Texture2D:
			return texture_ref(res)
		var path := res.resource_path
		if path != "" and not path.contains("::"):
			return path
		var key := res.get_instance_id()
		if _texture_ids.has(key):
			return _texture_ids[key]
		if res.get_script() != null or res is ImmediateMesh:
			_texture_ids[key] = null
			return null
		var bytes := PackedByteArray()
		if ResourceSaver.save(res, SAVE_TEMP) == OK:
			bytes = FileAccess.get_file_as_bytes(SAVE_TEMP)
		if bytes.is_empty():
			_texture_ids[key] = null
			return null
		var id := _texture_ids.size() + 1
		_texture_ids[key] = id
		_new_textures[id] = {"res": bytes}
		return id

	## Properties "p" looks at on a node like this one.
	static func prop_names(n: Node) -> PackedStringArray:
		var cls := n.get_class()
		var names: PackedStringArray
		if _prop_names.has(cls):
			names = _prop_names[cls]
		else:
			names = PackedStringArray()
			# What these do is replayed some other way (or they'd make the
			# replay act by itself).
			var skip_all := n is AnimationMixer or n is SkeletonModifier3D \
				or n is Window or n is Timer
			if not skip_all:
				for p in n.get_property_list():
					var name: String = p["name"]
					var usage: int = p["usage"]
					if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
						continue
					if not (usage & PROPERTY_USAGE_STORAGE) and not name.begins_with("theme_override_"):
						continue
					if p["type"] in [TYPE_NIL, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]:
						continue
					if SKIP_PROPS.has(name) or name.begins_with("metadata/") \
							or name.begins_with("bones/") or name.begins_with("surface_material_override/"):
						continue
					if name == "texture" and kinds_of(n) & K_TEX:
						continue
					names.append(name)
			_prop_names[cls] = names
		# Per mesh: one material slot per surface.
		if n is MeshInstance3D:
			names = names.duplicate()
			for i in n.get_surface_override_material_count():
				names.append("surface_material_override/%d" % i)
		return names

	## Whether two property values look the same. Resources that aren't files
	## are compared by what's in them (scenes' "local to scene" copies, a
	## material duplicated by code...).
	static func same(a, b, depth := 0) -> bool:
		if typeof(a) != typeof(b):
			return false
		if typeof(a) == TYPE_OBJECT:
			if a == b:
				return true
			if not (is_instance_valid(a) and is_instance_valid(b)):
				return false
			if not (a is Resource and b is Resource) or a.get_class() != b.get_class() \
					or a.get_script() != b.get_script() or depth > 3:
				return false
			for res: Resource in [a, b]:
				if res.resource_path != "" and not res.resource_path.contains("::"):
					return false
			for p in a.get_property_list():
				if not (p["usage"] & PROPERTY_USAGE_STORAGE) or p["name"].begins_with("resource_"):
					continue
				if not same(a.get(p["name"]), b.get(p["name"]), depth + 1):
					return false
			return true
		if a is Array:
			if a.size() != b.size():
				return false
			for i in a.size():
				if not same(a[i], b[i], depth):
					return false
			return true
		return a == b

	## A property value as the recording stores it (resources become
	## {"@r": resource_ref}), or SKIP.
	static func encode_value(v) -> Variant:
		if typeof(v) == TYPE_OBJECT:
			if not is_instance_valid(v):
				return null
			if not (v is Resource) or v is ViewportTexture:
				return SKIP
			var ref = resource_ref(v)
			return SKIP if ref == null else {"@r": ref}
		if v is Array:
			var out := []
			for item in v:
				var e = encode_value(item)
				if e is String and e == SKIP:
					return SKIP
				out.append(e)
			return out
		if v is Dictionary:
			for key in v:
				if key is Object or v[key] is Object:
					return SKIP
		return v

	static func decode_value(v) -> Variant:
		if v is Dictionary and v.size() == 1 and v.has("@r"):
			return resource_from_ref(v["@r"])
		if v is Array and not v.is_typed():
			var out := []
			for item in v:
				out.append(decode_value(item))
			return out
		return v

	## Bone poses as the skeleton has them: [rotations (4 per bone), positions
	## (3 per bone)].
	static func local_poses(sk: Skeleton3D) -> Array:
		var count := sk.get_bone_count()
		var q := PackedFloat32Array()
		var p := PackedFloat32Array()
		q.resize(count * 4)
		p.resize(count * 3)
		for i in count:
			var r := sk.get_bone_pose_rotation(i)
			var o := sk.get_bone_pose_position(i)
			q[i * 4] = r.x; q[i * 4 + 1] = r.y; q[i * 4 + 2] = r.z; q[i * 4 + 3] = r.w
			p[i * 3] = o.x; p[i * 3 + 1] = o.y; p[i * 3 + 2] = o.z
		return [q, p]

	## Every bone, encoded like a change of all of them.
	static func bones_full(poses: Array) -> Array:
		var q: PackedFloat32Array = poses[0]
		var p: PackedFloat32Array = poses[1]
		var count := q.size() / 4
		var rot := PackedByteArray()
		var pos := PackedByteArray()
		rot.resize(count * 10)
		pos.resize(count * 14)
		for i in count:
			_put_rot(rot, i * 10, i, q, i * 4)
			_put_pos(pos, i * 14, i, p, i * 3)
		return [rot, pos]

	# A bone's rotation: bone index (u16), then the quaternion as 4 x s16.
	static func _put_rot(out: PackedByteArray, at: int, bone: int, q: PackedFloat32Array, qi: int) -> void:
		out.encode_u16(at, bone)
		for c in 4:
			out.encode_s16(at + 2 + c * 2, int(round(clampf(q[qi + c], -1.0, 1.0) * 32767.0)))

	# A bone's position: bone index (u16), then 3 x float.
	static func _put_pos(out: PackedByteArray, at: int, bone: int, p: PackedFloat32Array, pi: int) -> void:
		out.encode_u16(at, bone)
		for c in 3:
			out.encode_float(at + 2 + c * 4, p[pi + c])

	static func apply_bones(sk: Skeleton3D, v) -> void:
		if not (v is Array) or v.size() < 2:
			return
		var count := sk.get_bone_count()
		var rot: PackedByteArray = v[0]
		var pos: PackedByteArray = v[1]
		for at in range(0, rot.size() - 9, 10):
			var bone := rot.decode_u16(at)
			if bone < count:
				var q := Quaternion(rot.decode_s16(at + 2), rot.decode_s16(at + 4),
					rot.decode_s16(at + 6), rot.decode_s16(at + 8)) / 32767.0
				sk.set_bone_pose_rotation(bone, q.normalized())
		for at in range(0, pos.size() - 13, 14):
			var bone := pos.decode_u16(at)
			if bone < count:
				sk.set_bone_pose_position(bone, Vector3(pos.decode_float(at + 2),
					pos.decode_float(at + 6), pos.decode_float(at + 10)))

	# The skeleton's final pose this frame (after its modifiers: IK, ragdoll
	# physics...), as local bone poses.
	func _on_skeleton_updated() -> void:
		var sk := node as Skeleton3D
		if sk == null or not is_instance_valid(sk):
			return
		var count := sk.get_bone_count()
		if _live_q.size() != count * 4:
			_live_q.resize(count * 4)
			_live_p.resize(count * 3)
		var globals: Array[Transform3D] = []
		globals.resize(count)
		for i in count:
			var g := sk.get_bone_global_pose(i)
			globals[i] = g
			var parent := sk.get_bone_parent(i)
			var local := g if parent < 0 else globals[parent].affine_inverse() * g
			var r := local.basis.get_rotation_quaternion()
			_live_q[i * 4] = r.x; _live_q[i * 4 + 1] = r.y; _live_q[i * 4 + 2] = r.z; _live_q[i * 4 + 3] = r.w
			_live_p[i * 3] = local.origin.x; _live_p[i * 3 + 1] = local.origin.y; _live_p[i * 3 + 2] = local.origin.z

	# Bones that moved since they were last recorded.
	func _capture_bones(all: bool) -> Variant:
		if _live_q.is_empty():
			return null
		var count := _live_q.size() / 4
		if _bq.size() != _live_q.size():
			_bq.resize(_live_q.size())
			_bp.resize(_live_p.size())
			all = true
		var rot := PackedByteArray()
		var pos := PackedByteArray()
		for i in count:
			var qi := i * 4
			# q and -q are the same rotation.
			var sign := 1.0 if (_live_q[qi] * _bq[qi] + _live_q[qi + 1] * _bq[qi + 1]
				+ _live_q[qi + 2] * _bq[qi + 2] + _live_q[qi + 3] * _bq[qi + 3]) >= 0.0 else -1.0
			if all or absf(_live_q[qi] - sign * _bq[qi]) > BONE_ROT_EPSILON \
					or absf(_live_q[qi + 1] - sign * _bq[qi + 1]) > BONE_ROT_EPSILON \
					or absf(_live_q[qi + 2] - sign * _bq[qi + 2]) > BONE_ROT_EPSILON \
					or absf(_live_q[qi + 3] - sign * _bq[qi + 3]) > BONE_ROT_EPSILON:
				var at := rot.size()
				rot.resize(at + 10)
				_put_rot(rot, at, i, _live_q, qi)
				for c in 4:
					_bq[qi + c] = rot.decode_s16(at + 2 + c * 2) / 32767.0
			var pi := i * 3
			if all or absf(_live_p[pi] - _bp[pi]) > BONE_POS_EPSILON \
					or absf(_live_p[pi + 1] - _bp[pi + 1]) > BONE_POS_EPSILON \
					or absf(_live_p[pi + 2] - _bp[pi + 2]) > BONE_POS_EPSILON:
				var at := pos.size()
				pos.resize(at + 14)
				_put_pos(pos, at, i, _live_p, pi)
				for c in 3:
					_bp[pi + c] = _live_p[pi + c]
		if rot.is_empty() and pos.is_empty():
			return null
		return [rot, pos]

	# Lines drawn by code into an ImmediateMesh: its surfaces as
	# [[primitive, vertices, colors, material], ...], when they changed.
	func _capture_dynmesh(all: bool) -> Variant:
		var mesh = node.mesh
		if not (mesh is ImmediateMesh):
			return null
		_dm_wait -= 1
		if not all and (_dm_wait > 0 or not node.is_visible_in_tree()):
			return null
		_dm_wait = DYNMESH_EVERY
		var surfaces := []
		for s in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(s)
			var colors = arrays[Mesh.ARRAY_COLOR]
			var primitive: int = RenderingServer.mesh_get_surface(mesh.get_rid(), s).get("primitive", Mesh.PRIMITIVE_LINES)
			surfaces.append([primitive, arrays[Mesh.ARRAY_VERTEX],
				colors if colors != null else PackedColorArray(), mesh.surface_get_material(s)])
		var h := hash(surfaces)
		if not all and h == _dm_hash:
			return null
		_dm_hash = h
		for surface in surfaces:
			var m = encode_value(surface[3])
			surface[3] = null if m is String else m
		_dm = surfaces
		return surfaces

	static func mesh_from_surfaces(surfaces: Array) -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for surface in surfaces:
			var verts: PackedVector3Array = surface[1]
			if verts.is_empty():
				continue
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			var colors: PackedColorArray = surface[2]
			if colors.size() == verts.size():
				arrays[Mesh.ARRAY_COLOR] = colors
			mesh.add_surface_from_arrays(surface[0], arrays)
			var mat = decode_value(surface[3])
			if mat is Material:
				mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
		return mesh

	## Properties that changed since they were last recorded: {name: value}.
	func capture_props() -> Variant:
		check_props = false
		var d = null
		var cls := node.get_class()
		for prop in props:
			var v = node.get(prop)
			var before = _props[prop] if _props.has(prop) else ClassDB.class_get_property_default_value(cls, prop)
			if same(v, before):
				continue
			_props[prop] = v
			var e = encode_value(v)
			if e is String and e == SKIP:
				continue
			_props_recorded[prop] = true
			if d == null:
				d = {}
			d[prop] = e
		if node is MeshInstance3D and node.mesh is ImmediateMesh:
			kinds |= K_DYNMESH
		return d

	static func encode_t3(t: Transform3D) -> PackedFloat32Array:
		var q := t.basis.get_rotation_quaternion()
		var s := t.basis.get_scale()
		var out := PackedFloat32Array([t.origin.x, t.origin.y, t.origin.z, q.x, q.y, q.z, q.w])
		if not s.is_equal_approx(Vector3.ONE):
			out.append_array([s.x, s.y, s.z])
		return out

	static func decode_t3(a: PackedFloat32Array) -> Transform3D:
		var basis := Basis(Quaternion(a[3], a[4], a[5], a[6]).normalized())
		if a.size() >= 10:
			basis = basis * Basis.from_scale(Vector3(a[7], a[8], a[9]))
		return Transform3D(basis, Vector3(a[0], a[1], a[2]))

	func set_last(d: Dictionary) -> void:
		if d.has("tl"): _top = d["tl"]
		if d.has("t"): _t3 = decode_t3(d["t"])
		if d.has("t2"): _t2 = d["t2"]
		if d.has("cs"): _cs = Vector3(d["cs"][0], d["cs"][1], d["cs"][2])
		if d.has("v"): _vis = d["v"]
		if d.has("m"): _mod = d["m"]
		if d.has("x"): _text = d["x"]
		if d.has("r"): _range = d["r"]
		if d.has("c"): _cam = d["c"]
		if d.has("fv"): _fov = d["fv"]
		if d.has("e"): _emit = d["e"]
		if d.has("ao"): _layout = d["ao"]
		if d.has("bp"): _pressed = d["bp"]
		if d.has("ms"): _min = d["ms"]
		if d.has("gc"): _cols = d["gc"]
		if d.has("sc"): _scroll = Vector2i(d["sc"][0], d["sc"][1])
		if d.has("tx"): _tex = d["tx"]
		if d.has("fr"): _frame = d["fr"]
		if d.has("af"): _asprite = d["af"]
		if d.has("an"): _anim = d["an"]
		if d.has("p"): _props = d["p"].duplicate()

	## What changed since the last frame, or null if nothing did.
	func capture():
		var d = null
		var all := first
		first = false
		if kinds & K_TOP:
			var top: bool = node.top_level
			if all or top != _top:
				_top = top
				d = _put(d, "tl", top)
		if kinds & K_T3:
			var t: Transform3D = node.transform
			if all or not t.is_equal_approx(_t3):
				_t3 = t
				d = _put(d, "t", encode_t3(t))
		if kinds & K_T2:
			var t2 := PackedFloat32Array([node.position.x, node.position.y, node.rotation, node.scale.x, node.scale.y])
			if all or t2 != _t2:
				_t2 = t2
				d = _put(d, "t2", t2)
		if kinds & K_CS:
			var cs := Vector3(node.scale.x, node.scale.y, node.rotation)
			if all or not cs.is_equal_approx(_cs):
				_cs = cs
				d = _put(d, "cs", PackedFloat32Array([cs.x, cs.y, cs.z]))
		if kinds & K_VIS:
			var v: bool = node.visible
			if all or v != _vis:
				_vis = v
				d = _put(d, "v", v)
		if kinds & K_MOD:
			var m: Color = node.modulate
			if all or not m.is_equal_approx(_mod):
				_mod = m
				d = _put(d, "m", m)
		if kinds & K_TEXT:
			var x: String = node.text
			if all or x != _text:
				_text = x
				d = _put(d, "x", x)
		if kinds & K_RANGE:
			var r: float = node.value
			if all or not is_equal_approx(r, _range):
				_range = r
				d = _put(d, "r", r)
		if kinds & K_CAM:
			var c: bool = node.current
			if all or c != _cam:
				_cam = c
				d = _put(d, "c", c)
		if kinds & K_FOV:
			var fv: float = node.fov
			if all or not is_equal_approx(fv, _fov):
				_fov = fv
				d = _put(d, "fv", fv)
		if kinds & K_EMIT:
			var e: bool = node.emitting
			if all or e != _emit:
				_emit = e
				d = _put(d, "e", e)
		if kinds & K_LAYOUT:
			var ao := layout_of(node)
			if all or ao != _layout:
				_layout = ao
				d = _put(d, "ao", ao)
		if kinds & K_PRESSED:
			var bp: bool = node.button_pressed
			if all or bp != _pressed:
				_pressed = bp
				d = _put(d, "bp", bp)
		if kinds & K_MIN:
			var ms: Vector2 = node.custom_minimum_size
			if all or not ms.is_equal_approx(_min):
				_min = ms
				d = _put(d, "ms", ms)
		if kinds & K_COLS:
			var gc: int = node.columns
			if all or gc != _cols:
				_cols = gc
				d = _put(d, "gc", gc)
		if kinds & K_SCROLL:
			var sc := Vector2i(node.scroll_horizontal, node.scroll_vertical)
			if all or sc != _scroll:
				_scroll = sc
				d = _put(d, "sc", PackedInt32Array([sc.x, sc.y]))
		if kinds & K_TEX:
			var tex: Texture2D = node.get(texture_property(node))
			if is_live_texture(tex):
				pass
			elif all or tex != _tex:
				_tex = tex
				d = _put(d, "tx", texture_ref(tex))
		if kinds & K_FRAME:
			var fr: int = node.frame
			if all or fr != _frame:
				_frame = fr
				d = _put(d, "fr", fr)
		if kinds & K_ASPRITE:
			var af := asprite_state(node)
			if all or af != _asprite:
				_asprite = af
				d = _put(d, "af", af)
		if kinds & K_ANIM:
			var an := anim_state(node)
			if all or an != _anim:
				_anim = an
				d = _put(d, "an", an)
		if kinds & K_VIDEO:
			var vp := [node.is_playing() and not node.paused, snappedf(node.stream_position, 0.5)]
			if all or vp != _vp:
				_vp = vp
				d = _put(d, "vp", vp)
		if kinds & K_BONES:
			var sk = _capture_bones(all)
			if sk != null:
				d = _put(d, "sk", sk)
		if kinds & K_DYNMESH:
			var dm = _capture_dynmesh(all)
			if dm != null:
				d = _put(d, "dm", dm)
		if check_props:
			var p = capture_props()
			if p != null:
				d = _put(d, "p", p)
		if d != null:
			changed_ever = true
			idle = 0
		else:
			idle += 1
		return d

	## All values as last recorded (for keyframes). The last recorded values,
	## not the live ones, so a keyframe always matches the frames before it.
	func full() -> Dictionary:
		var d := {}
		if kinds & K_TOP: d["tl"] = _top
		if kinds & K_T3: d["t"] = encode_t3(_t3)
		if kinds & K_T2: d["t2"] = _t2
		if kinds & K_CS: d["cs"] = PackedFloat32Array([_cs.x, _cs.y, _cs.z])
		if kinds & K_VIS: d["v"] = _vis
		if kinds & K_MOD: d["m"] = _mod
		if kinds & K_TEXT: d["x"] = _text
		if kinds & K_RANGE: d["r"] = _range
		if kinds & K_CAM: d["c"] = _cam
		if kinds & K_FOV: d["fv"] = _fov
		if kinds & K_EMIT: d["e"] = _emit
		if kinds & K_LAYOUT: d["ao"] = _layout
		if kinds & K_PRESSED: d["bp"] = _pressed
		if kinds & K_MIN: d["ms"] = _min
		if kinds & K_COLS: d["gc"] = _cols
		if kinds & K_SCROLL: d["sc"] = PackedInt32Array([_scroll.x, _scroll.y])
		if kinds & K_TEX and not is_live_texture(_tex): d["tx"] = texture_ref(_tex)
		if kinds & K_FRAME: d["fr"] = _frame
		if kinds & K_ASPRITE: d["af"] = _asprite
		if kinds & K_ANIM: d["an"] = _anim
		if kinds & K_VIDEO and not _vp.is_empty(): d["vp"] = _vp
		if kinds & K_BONES and not _bq.is_empty(): d["sk"] = bones_full([_bq, _bp])
		if kinds & K_DYNMESH and not _dm.is_empty(): d["dm"] = _dm
		if not _props_recorded.is_empty():
			var p := {}
			for prop in _props_recorded:
				var e = encode_value(_props[prop])
				if not (e is String and e == SKIP):
					p[prop] = e
			d["p"] = p
		return d

	static func _put(d, key: String, value) -> Dictionary:
		if d == null:
			d = {}
		d[key] = value
		return d
