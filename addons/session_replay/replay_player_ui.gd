# The bar shown at the bottom of the screen while a replay plays.
#
#   [ ---------------O------------------------ ]   timeline (click or drag)
#  [spk]---o   «     <     ||     >     »   [keys]   0:12 / 1:24   [1x]
#                     v                            hide / show arrow
#
# « / » jump 10 s, < / > jump 1 s (one frame while paused), || pauses,
# [keys] shows / hides the input overlay (input_overlay.gd), the speaker
# mutes / unmutes the recorded sound and the slider next to it sets its volume.
# [1x] picks the playback speed (0.5x to 1.5x) from a small list.
# Moving the mouse to the top middle of the screen shows a round X button that
# closes the replay (like a video player's close button).
#
# None of these controls take part in Godot's normal GUI input (all of them
# ignore the mouse): replayed clicks must reach the game underneath. Your real
# mouse arrives through handle_real_input(), called by the input shield.
# Everything is drawn with shapes so it doesn't depend on the game's font.
extends Control

const BAR_HEIGHT := 92.0
const SKIP_SECONDS := 10
const COLOR_BG := Color(0.05, 0.06, 0.08, 0.82)
const COLOR_LINE := Color(1, 1, 1, 0.35)
const COLOR_DONE := Color(1, 1, 1, 0.95)
const COLOR_ICON := Color(1, 1, 1, 0.8)
const COLOR_HOVER := Color(1, 1, 1, 1)
const COLOR_OK := Color(0.55, 1.0, 0.55)
const INPUT_OVERLAY := preload("res://addons/session_replay/input_overlay.gd")

var player: Node

var _bar: Control
var _timeline: Timeline
var _buttons: Array[IconButton] = []
var _pause_button: IconButton
var _time_label: Label
var _status_label: Label
var _speaker: IconButton
var _volume: VolumeSlider
var _volume_before_mute := 1.0
var _speed: SpeedPicker
var _close: CloseButton
var _toggle: IconButton
var _overlay_button: IconButton
var _overlay: Control
var _hidden := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_bar = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_BG
	style.corner_radius_top_left = 10
	style.corner_radius_top_right = 10
	_bar.add_theme_stylebox_override("panel", style)
	_bar.anchor_left = 0.0
	_bar.anchor_right = 1.0
	_bar.anchor_top = 1.0
	_bar.anchor_bottom = 1.0
	_bar.offset_top = -BAR_HEIGHT
	add_child(_bar)

	_timeline = Timeline.new()
	_timeline.player = player
	_timeline.anchor_right = 1.0
	_timeline.offset_left = 24
	_timeline.offset_right = -24
	_timeline.offset_top = 10
	_timeline.offset_bottom = 34
	_bar.add_child(_timeline)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	row.anchor_right = 1.0
	row.offset_top = 40
	row.offset_bottom = 76
	_bar.add_child(row)
	row.add_child(_icon_button("rewind", func() -> void:
		player.skip_frames(-SKIP_SECONDS * _tps())))
	row.add_child(_icon_button("back", func() -> void:
		if player.is_replay_paused():
			player.step_frame(-1)
		else:
			player.skip_frames(-_tps())))
	_pause_button = _icon_button("pause", func() -> void:
		player.set_replay_paused(not player.is_replay_paused()))
	row.add_child(_pause_button)
	row.add_child(_icon_button("forward", func() -> void:
		if player.is_replay_paused():
			player.step_frame(1)
		else:
			player.skip_frames(_tps())))
	row.add_child(_icon_button("fast_forward", func() -> void:
		player.skip_frames(SKIP_SECONDS * _tps())))

	_overlay = INPUT_OVERLAY.new()
	_overlay.player = player
	add_child(_overlay)
	_overlay_button = _icon_button("keys", _toggle_overlay)
	_overlay_button.custom_minimum_size = Vector2(44, 28)
	_overlay_button.anchor_left = 1.0
	_overlay_button.anchor_right = 1.0
	_overlay_button.offset_left = -326
	_overlay_button.offset_right = -282
	_overlay_button.offset_top = 44
	_overlay_button.offset_bottom = 72
	_bar.add_child(_overlay_button)

	_time_label = Label.new()
	_time_label.anchor_left = 1.0
	_time_label.anchor_right = 1.0
	_time_label.offset_left = -270
	_time_label.offset_right = -84
	_time_label.offset_top = 44
	_time_label.offset_bottom = 72
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_bar.add_child(_time_label)

	# Playback speed, far right.
	_speed = SpeedPicker.new()
	_speed.player = player
	_speed.anchor_left = 1.0
	_speed.anchor_right = 1.0
	_speed.offset_left = -72
	_speed.offset_right = -20
	_speed.offset_top = 44
	_speed.offset_bottom = 72
	_bar.add_child(_speed)

	# Sound: speaker (mute) and volume slider, on the left.
	_speaker = _icon_button("speaker", _toggle_mute)
	_speaker.custom_minimum_size = Vector2(32, 28)
	_speaker.offset_left = 16
	_speaker.offset_right = 48
	_speaker.offset_top = 44
	_speaker.offset_bottom = 72
	_bar.add_child(_speaker)
	_volume = VolumeSlider.new()
	_volume.player = player
	_volume.offset_left = 54
	_volume.offset_right = 154
	_volume.offset_top = 46
	_volume.offset_bottom = 70
	_bar.add_child(_volume)
	if not player.has_sound():
		_speaker.dimmed = true
		_volume.modulate.a = 0.4

	_status_label = Label.new()
	_status_label.offset_left = 170
	_status_label.offset_right = 420
	_status_label.offset_top = 44
	_status_label.offset_bottom = 72
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.clip_text = true
	_bar.add_child(_status_label)

	_toggle = _icon_button("hide", _toggle_hidden)
	_toggle.custom_minimum_size = Vector2(44, 22)
	_toggle.anchor_left = 0.5
	_toggle.anchor_right = 0.5
	_toggle.anchor_top = 1.0
	_toggle.anchor_bottom = 1.0
	add_child(_toggle)
	_place_toggle()

	_close = CloseButton.new()
	_close.anchor_left = 0.5
	_close.anchor_right = 0.5
	_close.offset_left = -24
	_close.offset_right = 24
	_close.offset_top = 24
	_close.offset_bottom = 72
	add_child(_close)

	# Nothing here takes the regular GUI input (see the note at the top).
	for node in find_children("*", "Control", true, false):
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Real mouse input, from the input shield. Returns true if it was on the controls.
func handle_real_input(event: InputEvent) -> bool:
	if not (event is InputEventMouse):
		return false
	var pos: Vector2 = (event as InputEventMouse).position
	_close.mouse_moved(pos, size)

	if event is InputEventMouseMotion:
		for b in _buttons:
			b.set_hovered(b.is_visible_in_tree() and b.get_global_rect().has_point(pos))
		if _timeline.dragging:
			_timeline.drag_to(pos)
			return true
		if _volume.dragging:
			_volume.drag_to(pos)
			_update_speaker()
			return true
		return _on_controls(pos)

	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return _on_controls(pos)
	if mb.pressed:
		if _close.shown() and _close.get_global_rect().has_point(pos):
			get_tree().quit()
			return true
		if _bar.visible and _speed.click(pos):
			return true
		for b in _buttons:
			if b.is_visible_in_tree() and b.get_global_rect().has_point(pos):
				b.action.call()
				return true
		if _bar.visible and _timeline.get_global_rect().grow_individual(0, 8, 0, 8).has_point(pos):
			_timeline.start_drag(pos)
			return true
		if _bar.visible and _volume.get_global_rect().grow(4).has_point(pos):
			_volume.start_drag(pos)
			_update_speaker()
			return true
	elif _timeline.dragging:
		_timeline.end_drag(pos)
		return true
	elif _volume.dragging:
		_volume.dragging = false
		return true
	return _on_controls(pos)


func _on_controls(pos: Vector2) -> bool:
	if _bar.visible and _speed.open and _speed.list_rect().has_point(pos):
		return true
	return (_bar.visible and _bar.get_global_rect().has_point(pos)) or _toggle.get_global_rect().has_point(pos)


func _process(_delta: float) -> void:
	if player == null:
		return
	_time_label.text = "%s / %s" % [_clock(player.replay_time()), _clock(player.replay_duration())]
	_pause_button.kind = "play" if player.is_replay_paused() else "pause"
	_pause_button.queue_redraw()
	_timeline.queue_redraw()

	if player.is_replay_finished():
		_set_status("End of recording", COLOR_OK)
	elif player.is_replay_paused():
		_set_status("Paused", Color.WHITE)
	else:
		_set_status("Replay", Color.WHITE)


func _set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.modulate = color


func _toggle_mute() -> void:
	if player.get_volume() > 0.0:
		_volume_before_mute = player.get_volume()
		player.set_volume(0.0)
	else:
		player.set_volume(maxf(_volume_before_mute, 0.1))
	_update_speaker()


func _update_speaker() -> void:
	_speaker.kind = "speaker_muted" if player.get_volume() <= 0.0 else "speaker"
	_speaker.queue_redraw()
	_volume.queue_redraw()


func _toggle_overlay() -> void:
	_overlay.visible = not _overlay.visible
	_overlay_button.dimmed = not _overlay.visible
	_overlay_button.queue_redraw()


## Keyboard shortcuts (from the input shield): Space pause, arrows step / skip,
## Esc closes the replay.
func handle_real_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_ESCAPE:
			get_tree().quit()
		KEY_SPACE:
			player.set_replay_paused(not player.is_replay_paused())
		KEY_LEFT:
			if player.is_replay_paused():
				player.step_frame(-1)
			else:
				player.skip_frames(-_tps())
		KEY_RIGHT:
			if player.is_replay_paused():
				player.step_frame(1)
			else:
				player.skip_frames(_tps())


func _toggle_hidden() -> void:
	_hidden = not _hidden
	_bar.visible = not _hidden
	_toggle.kind = "show" if _hidden else "hide"
	_place_toggle()


# The arrow sits just above the bar, or at the very bottom when the bar is hidden.
func _place_toggle() -> void:
	var bottom := -4.0 if _hidden else -BAR_HEIGHT - 2.0
	_toggle.offset_left = -22
	_toggle.offset_right = 22
	_toggle.offset_bottom = bottom
	_toggle.offset_top = bottom - 22
	_toggle.queue_redraw()


func _tps() -> int:
	return player.replay_ticks_per_second()


static func _clock(time: float) -> String:
	var seconds := int(time)
	return "%d:%02d" % [seconds / 60, seconds % 60]


func _icon_button(kind: String, action: Callable) -> IconButton:
	var b := IconButton.new()
	b.kind = kind
	b.action = action
	b.custom_minimum_size = Vector2(44, 34)
	_buttons.append(b)
	return b


## A clickable icon (play, pause, arrows...) drawn with shapes.
class IconButton extends Control:
	var kind := ""
	var action: Callable
	var dimmed := false
	var _hovered := false

	func set_hovered(h: bool) -> void:
		if h != _hovered:
			_hovered = h
			queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var col := COLOR_HOVER if _hovered else COLOR_ICON
		if dimmed:
			col.a *= 0.4
		var h := 9.0
		match kind:
			"speaker", "speaker_muted":
				# Box and cone, then sound waves (or a cross when muted).
				var body := PackedVector2Array([c + Vector2(-9, -4), c + Vector2(-5, -4), c + Vector2(1, -9),
					c + Vector2(1, 9), c + Vector2(-5, 4), c + Vector2(-9, 4)])
				draw_colored_polygon(body, col)
				if kind == "speaker":
					draw_arc(c + Vector2(2, 0), 5.0, -0.9, 0.9, 12, col, 1.6, true)
					draw_arc(c + Vector2(2, 0), 9.0, -0.9, 0.9, 16, col, 1.6, true)
				else:
					draw_line(c + Vector2(5, -4), c + Vector2(11, 4), col, 1.8, true)
					draw_line(c + Vector2(5, 4), c + Vector2(11, -4), col, 1.8, true)
			"keys": # a small keyboard
				var r := Rect2(c - Vector2(15, 9), Vector2(30, 18))
				draw_rect(r, col, false, 2.0)
				for i in 4:
					draw_rect(Rect2(r.position + Vector2(4 + i * 6, 4), Vector2(4, 3)), col)
				draw_rect(Rect2(r.position + Vector2(8, 11), Vector2(14, 3)), col)
			"play":
				_tri(c + Vector2(2, 0), h, 1, col)
			"pause":
				draw_rect(Rect2(c + Vector2(-7, -h), Vector2(5, h * 2)), col)
				draw_rect(Rect2(c + Vector2(2, -h), Vector2(5, h * 2)), col)
			"forward":
				_tri(c, h, 1, col)
			"back":
				_tri(c, h, -1, col)
			"fast_forward":
				_tri(c + Vector2(-6, 0), h, 1, col)
				_tri(c + Vector2(6, 0), h, 1, col)
			"rewind":
				_tri(c + Vector2(-6, 0), h, -1, col)
				_tri(c + Vector2(6, 0), h, -1, col)
			"hide": # arrow pointing down
				draw_polyline([c + Vector2(-10, -4), c + Vector2(0, 5), c + Vector2(10, -4)], col, 3.0, true)
			"show": # arrow pointing up
				draw_polyline([c + Vector2(-10, 5), c + Vector2(0, -4), c + Vector2(10, 5)], col, 3.0, true)

	func _tri(center: Vector2, h: float, dir: int, col: Color) -> void:
		var w := h * 1.1 * dir
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(-w / 2, -h), center + Vector2(w / 2, 0), center + Vector2(-w / 2, h)]), col)


## Round X at the top middle of the screen, shown only while the mouse is
## near there. Clicking it closes the replay.
class CloseButton extends Control:
	const ZONE := Vector2(360, 140) # area around the top middle that shows it
	var _target := 0.0
	var _alpha := 0.0
	var _hover := false

	func mouse_moved(pos: Vector2, screen: Vector2) -> void:
		var near := absf(pos.x - screen.x / 2.0) < ZONE.x / 2.0 and pos.y < ZONE.y
		_target = 1.0 if near else 0.0
		_hover = get_global_rect().has_point(pos)

	func shown() -> bool:
		return _alpha > 0.3

	func _process(delta: float) -> void:
		var a := move_toward(_alpha, _target, delta * 6.0)
		if a != _alpha:
			_alpha = a
			queue_redraw()

	func _draw() -> void:
		if _alpha <= 0.0:
			return
		var c := size / 2.0
		draw_circle(c, 24.0, Color(0.05, 0.06, 0.08, (0.85 if _hover else 0.65) * _alpha))
		var col := Color(1, 1, 1, 0.95 * _alpha)
		draw_line(c + Vector2(-8, -8), c + Vector2(8, 8), col, 2.0, true)
		draw_line(c + Vector2(-8, 8), c + Vector2(8, -8), col, 2.0, true)


## Playback speed: shows "1x"; click to open a small list above it.
class SpeedPicker extends Control:
	const SPEEDS := [0.5, 0.75, 1.0, 1.25, 1.5]
	const ROW := 26.0
	var player: Node
	var open := false
	var _hover := -1

	static func label(s: float) -> String:
		return ("%sx" % str(s)).replace(".0x", "x")

	# The list, in the bar's coordinates' global space (above the button).
	func list_rect() -> Rect2:
		var r := get_global_rect()
		var h := ROW * SPEEDS.size() + 8
		return Rect2(Vector2(r.position.x - 8, r.position.y - h - 6), Vector2(r.size.x + 16, h))

	## Handles a click. Returns true if it was on the button or the list.
	func click(pos: Vector2) -> bool:
		if get_global_rect().has_point(pos):
			open = not open
			queue_redraw()
			return true
		if open:
			var lr := list_rect()
			open = false
			queue_redraw()
			if lr.has_point(pos):
				var i := clampi(int((pos.y - lr.position.y - 4) / ROW), 0, SPEEDS.size() - 1)
				player.set_speed(SPEEDS[i])
				return true
		return false

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var r := Rect2(Vector2.ZERO, size)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.12 if open else 0.06)
		sb.set_corner_radius_all(6)
		draw_style_box(sb, r)
		draw_string(font, Vector2(0, size.y / 2 + 6), label(player.get_speed()), HORIZONTAL_ALIGNMENT_CENTER, size.x, 15, COLOR_DONE)
		if not open:
			return
		# The list is drawn above the button (outside its own rect).
		var lr := list_rect()
		var local := Rect2(lr.position - get_global_rect().position, lr.size)
		var panel := StyleBoxFlat.new()
		panel.bg_color = Color(0.05, 0.06, 0.08, 0.95)
		panel.set_corner_radius_all(8)
		draw_style_box(panel, local)
		for i in SPEEDS.size():
			var row := Rect2(local.position + Vector2(4, 4 + i * ROW), Vector2(local.size.x - 8, ROW))
			if is_equal_approx(SPEEDS[i], player.get_speed()):
				var cur := StyleBoxFlat.new()
				cur.bg_color = Color(1, 1, 1, 0.15)
				cur.set_corner_radius_all(5)
				draw_style_box(cur, row)
			draw_string(font, Vector2(row.position.x, row.position.y + ROW / 2 + 5), label(SPEEDS[i]),
				HORIZONTAL_ALIGNMENT_CENTER, row.size.x, 14, COLOR_DONE)


## Volume slider: a short line with a knob. 0 (left) to full (right).
class VolumeSlider extends Control:
	var player: Node
	var dragging := false

	func start_drag(pos: Vector2) -> void:
		dragging = true
		drag_to(pos)

	func drag_to(pos: Vector2) -> void:
		player.set_volume(clampf((pos.x - get_global_rect().position.x) / maxf(size.x, 1.0), 0.0, 1.0))
		queue_redraw()

	func _draw() -> void:
		var y := size.y / 2.0
		var x: float = player.get_volume() * size.x
		draw_line(Vector2(0, y), Vector2(size.x, y), COLOR_LINE, 3.0, true)
		draw_line(Vector2(0, y), Vector2(x, y), COLOR_DONE, 3.0, true)
		draw_circle(Vector2(x, y), 6.0, COLOR_DONE)


## The timeline: a line with a circle at the current position.
## Click or drag anywhere on it to jump there (the jump happens on release).
class Timeline extends Control:
	var player: Node
	var dragging := false
	var _drag_ratio := 0.0

	func start_drag(pos: Vector2) -> void:
		dragging = true
		drag_to(pos)

	func drag_to(pos: Vector2) -> void:
		_drag_ratio = clampf((pos.x - get_global_rect().position.x) / maxf(size.x, 1.0), 0.0, 1.0)
		queue_redraw()

	func end_drag(pos: Vector2) -> void:
		drag_to(pos)
		dragging = false
		player.seek(int(_drag_ratio * player.replay_length()))

	func _draw() -> void:
		var y := size.y / 2.0
		var ratio: float = _drag_ratio if dragging else float(player.replay_position()) / float(player.replay_length())
		ratio = clampf(ratio, 0.0, 1.0)
		var x: float = ratio * size.x
		draw_line(Vector2(0, y), Vector2(size.x, y), COLOR_LINE, 3.0, true)
		draw_line(Vector2(0, y), Vector2(x, y), COLOR_DONE, 3.0, true)
		draw_circle(Vector2(x, y), 8.0, COLOR_DONE)
		draw_circle(Vector2(x, y), 8.0, Color.BLACK, false, 1.5, true)
