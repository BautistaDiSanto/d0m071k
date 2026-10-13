# Records what the game's scripts draw themselves in _draw() (a crosshair, a
# custom button's underline, a value drawn next to a slider...). A replay
# doesn't run the game's scripts, so without this that drawing would be
# missing.
#
# Nodes like that are drawn a second time into a small offscreen viewport (only
# them and their parents: they're put on a rendering layer of their own,
# CAPTURE_BIT), one per
# canvas (CanvasLayer) they're on. Every few frames the picture is read back
# (without waiting for the GPU when the renderer allows it), cut down to the
# part that has something on it on a worker thread, and recorded as PNG when it
# changed.
# Playback shows those pictures on top (see replay_player.gd).
#
# Used by session_recorder.gd.
extends Node

const NodeState := preload("res://addons/session_replay/node_state.gd")

## The rendering layer (CanvasItem.visibility_layer) the capture viewports draw.
const CAPTURE_BIT := 1 << 19
## Size of the capture next to the game's (lower is cheaper, blurrier).
const SCALE := 1.0
## A capture every this many frames.
const EVERY := 2

# Whether a script (or one it extends) has _draw(), per script.
var _draws := {}
# Canvas id -> Group.
var _groups := {}
# Captures read back since the last frame: [Group, value] (filled by worker
# threads, see _crop).
var _done: Array = []
var _mutex := Mutex.new()
# Worker thread tasks that may still be running.
var _tasks: Array[int] = []
var _frame := 0
# Groups no longer captured, whose viewport is freed once nothing is read
# back from it any more.
var _retired: Array = []
# Canvases dropped since the last frame that still had a picture shown: it's
# taken off in the recording too.
var _cleared: Array[String] = []
var _keep_prefixes := PackedStringArray()


class Group:
	var key: String
	var canvas: RID
	var layer: CanvasLayer
	var viewport: SubViewport
	var nodes: Array[CanvasItem] = []
	var pending := false
	var hash := 0
	## As last recorded: [layer, x, y, scale, png], or [] for nothing.
	var last: Array = []


func _init(keep_prefixes: PackedStringArray) -> void:
	_keep_prefixes = keep_prefixes


## Starts capturing a node if its script draws something itself.
func add(node: Node) -> void:
	if not (node is CanvasItem) or not _draws_itself(node):
		return
	var canvas: RID = node.get_canvas()
	if not canvas.is_valid():
		return
	var key := str(canvas.get_id())
	var group: Group = _groups.get(key)
	if group == null:
		group = Group.new()
		group.key = key
		group.canvas = canvas
		group.layer = node.get_canvas_layer_node()
		var vp := SubViewport.new()
		vp.name = "DrawCapture"
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.canvas_cull_mask = CAPTURE_BIT
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.size = Vector2i((get_viewport().get_visible_rect().size * SCALE).round())
		add_child(vp)
		RenderingServer.viewport_attach_canvas(vp.get_viewport_rid(), canvas)
		group.viewport = vp
		_groups[key] = group
		# The canvas goes with its layer: let go of it first.
		if group.layer:
			group.layer.tree_exiting.connect(_drop.bind(key), CONNECT_ONE_SHOT)
	if not group.nodes.has(node):
		group.nodes.append(node)
		# A viewport only draws an item if its parents are on the layer too.
		var item: Node = node
		while item is CanvasItem and item.get_canvas() == canvas:
			item.visibility_layer |= CAPTURE_BIT
			item = item.get_parent()


## What changed since the last frame: {canvas id: [layer, x, y, scale, png],
## or [] when there's nothing drawn any more}.
func capture() -> Dictionary:
	_frame += 1
	var out := {}
	for key in _cleared:
		out[key] = []
	_cleared.clear()
	for i in range(_retired.size() - 1, -1, -1):
		if not _retired[i].pending:
			_retired[i].viewport.queue_free()
			_retired.remove_at(i)
	for key in _groups.keys():
		var g: Group = _groups[key]
		for i in range(g.nodes.size() - 1, -1, -1):
			if not is_instance_valid(g.nodes[i]) or not g.nodes[i].is_inside_tree():
				g.nodes.remove_at(i)
		var shown := false
		for n in g.nodes:
			if n.is_visible_in_tree():
				shown = true
				break
		if not shown:
			if not g.last.is_empty():
				_put_capture(g, [], out)
			if g.nodes.is_empty():
				_drop(key)
			continue
		if g.pending or (_frame + int(key)) % EVERY != 0:
			continue
		_read(g)
	_mutex.lock()
	var done := _done
	_done = []
	_mutex.unlock()
	for entry in done:
		if _groups.get(entry[0].key) == entry[0]:
			_put_capture(entry[0], entry[1], out)
	for i in range(_tasks.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_tasks[i])
			_tasks.remove_at(i)
	return out


func _exit_tree() -> void:
	# The engine crashes if it shuts down while a read back is on its way:
	# let those finish first.
	for i in 3:
		if not _retired.any(func(g: Group) -> bool: return g.pending) \
				and not _groups.values().any(func(g: Group) -> bool: return g.pending):
			break
		RenderingServer.force_draw(false)
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	for key in _groups.keys():
		_drop(key)


# Stops capturing a canvas.
func _drop(key: String) -> void:
	var g: Group = _groups.get(key)
	if g == null:
		return
	_groups.erase(key)
	g.nodes.clear()
	if not g.last.is_empty():
		_cleared.append(key)
	if is_instance_valid(g.viewport):
		RenderingServer.viewport_remove_canvas(g.viewport.get_viewport_rid(), g.canvas)
		g.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		# Freed once its last read back is in (see _exit_tree).
		_retired.append(g)


## Every canvas' last picture (for keyframes).
func full() -> Dictionary:
	var out := {}
	for key in _groups:
		if not _groups[key].last.is_empty():
			out[key] = _groups[key].last
	return out


func _put_capture(g: Group, value: Array, out: Dictionary) -> void:
	if value.is_empty():
		g.hash = 0
	g.last = value
	out[g.key] = value


func _read(g: Group) -> void:
	var transform: Transform2D = g.layer.transform if g.layer else get_viewport().canvas_transform
	RenderingServer.viewport_set_canvas_transform(g.viewport.get_viewport_rid(), g.canvas,
		Transform2D.IDENTITY.scaled(Vector2(SCALE, SCALE)) * transform)
	g.pending = true
	var layer_index := g.layer.layer if g.layer else 0
	var size := g.viewport.size
	var rd := RenderingServer.get_rendering_device()
	var tex := RenderingServer.texture_get_rd_texture(g.viewport.get_texture().get_rid()) if rd else RID()
	if rd and tex.is_valid():
		rd.texture_get_data_async(tex, 0, func(data: PackedByteArray) -> void:
			if _groups.get(g.key) != g or data.size() != size.x * size.y * 4:
				g.pending = false
				return
			_tasks.append(WorkerThreadPool.add_task(_crop.bind(g, layer_index,
				Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)))))
	else:
		# Compatibility renderer: no reading back without waiting.
		_tasks.append(WorkerThreadPool.add_task(_crop.bind(g, layer_index,
			g.viewport.get_texture().get_image())))


# On a worker thread: cuts the picture down to what's drawn, and queues it if
# it changed.
func _crop(g: Group, layer_index: int, image: Image) -> void:
	var value = null
	var rect := image.get_used_rect() if image else Rect2i()
	if rect.size.x <= 0 or rect.size.y <= 0:
		if not g.last.is_empty():
			value = []
	else:
		var part := image.get_region(rect)
		var h := hash([rect, part.get_data()])
		if h != g.hash:
			g.hash = h
			value = [layer_index, rect.position.x / SCALE, rect.position.y / SCALE, SCALE,
				part.save_png_to_buffer()]
	_mutex.lock()
	if value != null:
		_done.append([g, value])
	g.pending = false
	_mutex.unlock()


func _draws_itself(node: Node) -> bool:
	var script := node.get_script() as Script
	if script == null:
		return false
	if not _draws.has(script):
		var found := false
		# Scripts kept in replays draw there themselves.
		if not NodeState.kept_in_replay(script, _keep_prefixes):
			var s := script
			while s and not found:
				for m in s.get_script_method_list():
					if m["name"] == "_draw":
						found = true
						break
				s = s.get_base_script()
		_draws[script] = found
	return _draws[script]
