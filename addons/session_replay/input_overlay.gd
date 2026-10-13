# Shows the recorded input on screen during a replay: the keys the game's
# Input Map uses (laid out like a keyboard) plus the mouse, or a gamepad when
# a controller was the last thing used. Pressed keys and buttons light up.
#
#     Q   W   E          .-----.
#   SHIFT A   S   D      | L|R |   mouse (buttons, wheel, side buttons)
#   CTRL [  SPACE  ]     '-----'
#
# Kept deliberately plain: rounded boxes, thin edges, white when pressed.
#
# Drawn with shapes and the default font, so it doesn't depend on the game's
# theme. The player bar's [keys] button shows or hides it.
extends Control

const U := 44.0           # key size
const GAP := 5.0
const RADIUS := 6.0
const FONT_SIZE := 15
const MARGIN := 24.0
const BAR_SPACE := 92.0 + 24.0

# Neutral and quiet: dark see-through keys with a thin light edge; pressed
# keys turn solid white with dark text.
const COLOR_LINE := Color(1, 1, 1, 0.35)
const COLOR_FILL := Color(0.08, 0.09, 0.11, 0.55)
const COLOR_ON := Color(0.95, 0.96, 0.98, 0.95)
const COLOR_TEXT := Color(1, 1, 1, 0.85)
const COLOR_TEXT_ON := Color(0.08, 0.09, 0.11)

# Where keys sit: keycode -> [column, row, width in keys].
# Row 0: Q row, row 1: A row (Shift on the left, like most game overlays),
# row 2: Z row, row 3: Ctrl / Alt / Space.
const GRID := {
	KEY_TAB: [0, 0, 1], KEY_Q: [1, 0, 1], KEY_W: [2, 0, 1], KEY_E: [3, 0, 1], KEY_R: [4, 0, 1],
	KEY_T: [5, 0, 1], KEY_Y: [6, 0, 1], KEY_U: [7, 0, 1], KEY_I: [8, 0, 1], KEY_O: [9, 0, 1], KEY_P: [10, 0, 1],
	KEY_SHIFT: [0, 1, 1], KEY_A: [1, 1, 1], KEY_S: [2, 1, 1], KEY_D: [3, 1, 1], KEY_F: [4, 1, 1],
	KEY_G: [5, 1, 1], KEY_H: [6, 1, 1], KEY_J: [7, 1, 1], KEY_K: [8, 1, 1], KEY_L: [9, 1, 1],
	KEY_Z: [1, 2, 1], KEY_X: [2, 2, 1], KEY_C: [3, 2, 1], KEY_V: [4, 2, 1], KEY_B: [5, 2, 1],
	KEY_N: [6, 2, 1], KEY_M: [7, 2, 1],
	KEY_CTRL: [0, 3, 1], KEY_SPACE: [1, 3, 3], KEY_ALT: [4, 3, 1],
}
const MODIFIERS := [KEY_TAB, KEY_SHIFT, KEY_CTRL, KEY_SPACE, KEY_ALT]
const NAMES := {
	KEY_SHIFT: "SHIFT", KEY_CTRL: "CTRL", KEY_ALT: "ALT", KEY_TAB: "TAB", KEY_SPACE: "",
	KEY_ESCAPE: "ESC", KEY_ENTER: "ENTER", KEY_BACKSPACE: "BACK", KEY_UP: "UP",
	KEY_DOWN: "DOWN", KEY_LEFT: "LEFT", KEY_RIGHT: "RIGHT",
}

var player: Node

var _grid_keys: Array = []   # [keycode, Rect2] laid out in the keyboard block
var _extra_keys: Array = []  # [keycode, Rect2] used keys that aren't in GRID
var _kb_size := Vector2.ZERO
var _wheel_flash := 0.0
var _wheel_dir := 0
var _motion := Vector2.ZERO
var _font: Font


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_layout_keyboard(_used_keys())


func _process(delta: float) -> void:
	if not visible or player == null:
		return
	var input: Dictionary = player.input_state()
	if int(input.get("w", 0)) != 0:
		_wheel_dir = int(input["w"])
		_wheel_flash = 0.25
	_wheel_flash = maxf(_wheel_flash - delta, 0.0)
	var mm: Vector2 = input.get("mm", Vector2.ZERO)
	_motion = _motion.lerp(mm.limit_length(40.0) / 40.0, 0.35)
	queue_redraw()


# Keys bound in the Input Map (the game's own actions, not Godot's ui_* ones).
func _used_keys() -> Array:
	var keys := []
	for action in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				var code: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
				if code != 0 and not keys.has(code):
					keys.append(code)
	return keys


func _layout_keyboard(used: Array) -> void:
	var max_col := 3
	var z_row := false
	var bottom_row := false
	for code in used:
		if GRID.has(code):
			var g: Array = GRID[code]
			max_col = maxi(max_col, g[0] + g[2] - 1)
			z_row = z_row or g[1] == 2
			bottom_row = bottom_row or g[1] == 3
	var rows := [0, 1]
	if z_row:
		rows.append(2)
	if bottom_row:
		rows.append(3)

	# Extra keys (Esc, Enter, arrows...) go in a row above the block.
	var top := 0.0
	var x := 0.0
	for code in used:
		if GRID.has(code):
			continue
		var w := maxf(U * 0.8, _font.get_string_size(_name(code), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE - 3).x + 18.0)
		_extra_keys.append([code, Rect2(x, 0, w, U * 0.6)])
		x += w + GAP
	if not _extra_keys.is_empty():
		top = U * 0.6 + GAP * 2

	for code in GRID:
		var g: Array = GRID[code]
		if not rows.has(g[1]) or g[0] > max_col:
			continue
		if MODIFIERS.has(code) and not used.has(code):
			continue
		var row_index := rows.find(g[1])
		var rect := Rect2(g[0] * (U + GAP), top + row_index * (U + GAP), g[2] * U + (g[2] - 1) * GAP, U)
		_grid_keys.append([code, rect])
		_kb_size = _kb_size.max(rect.end)
	_kb_size = _kb_size.max(Vector2(x, 0))


func _draw() -> void:
	if player == null:
		return
	var input: Dictionary = player.input_state()
	if input.get("d", "kbm") == "pad":
		_draw_gamepad(input)
	else:
		_draw_keyboard(input)


#region Keyboard and mouse

func _draw_keyboard(input: Dictionary) -> void:
	var mouse_h := U * 2 + GAP
	var block_h := maxf(_kb_size.y, mouse_h)
	var origin := Vector2(MARGIN, size.y - BAR_SPACE - block_h)
	var held: PackedInt32Array = input.get("k", PackedInt32Array())
	for entry in _grid_keys + _extra_keys:
		var rect: Rect2 = entry[1]
		rect.position += origin
		_draw_key(rect, _name(entry[0]), held.has(entry[0]))
	var mouse_origin := origin + Vector2(_kb_size.x + U * 0.6, block_h - mouse_h)
	_draw_mouse(Rect2(mouse_origin, Vector2(U * 1.6, mouse_h)), int(input.get("mb", 0)))


func _draw_key(rect: Rect2, text: String, on: bool) -> void:
	_box(rect, on, RADIUS)
	if text != "":
		var fs := FONT_SIZE if text.length() <= 2 else FONT_SIZE - 3
		var y := rect.position.y + rect.size.y / 2.0 + fs * 0.35
		draw_string(_font, Vector2(rect.position.x, y), text, HORIZONTAL_ALIGNMENT_CENTER,
			rect.size.x, fs, COLOR_TEXT_ON if on else COLOR_TEXT)


# A plain mouse: rounded body, a line between the two buttons, a small wheel.
func _draw_mouse(r: Rect2, buttons: int) -> void:
	var split := r.position.y + r.size.y * 0.42
	var mid := r.position.x + r.size.x / 2.0
	var radius := r.size.x * 0.45
	_box(r, false, radius)
	# A pressed button fills its half of the top.
	if buttons & 1:
		_fill_top(Rect2(r.position, Vector2(r.size.x / 2.0, split - r.position.y)), true, radius)
	if buttons & 2:
		_fill_top(Rect2(Vector2(mid, r.position.y), Vector2(r.size.x / 2.0, split - r.position.y)), false, radius)
	draw_line(Vector2(r.position.x, split), Vector2(r.end.x, split), COLOR_LINE, 1.0, true)
	draw_line(Vector2(mid, r.position.y), Vector2(mid, split), COLOR_LINE, 1.0, true)
	var wheel := Rect2(Vector2(mid - 4, r.position.y + 12), Vector2(8, split - r.position.y - 24))
	_box(wheel, (buttons & 4) != 0 or _wheel_flash > 0.0, 4.0)
	# Side buttons as two short marks on the left edge.
	for i in 2:
		var on := (buttons & (1 << (MOUSE_BUTTON_XBUTTON1 - 1 + i))) != 0
		var y := split + 12 + i * 16
		draw_line(Vector2(r.position.x - 4, y), Vector2(r.position.x - 4, y + 10), COLOR_ON if on else COLOR_LINE, 3.0, true)
	# Movement: a small dot that leans the way the mouse moves.
	var center := Vector2(mid, (split + r.end.y) / 2.0)
	draw_circle(center + _motion * 10.0, 3.0, COLOR_ON if _motion.length() > 0.15 else COLOR_LINE)


# Fills the left or right top corner of the mouse for a pressed button.
func _fill_top(r: Rect2, left: bool, radius: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_ON
	sb.corner_radius_top_left = int(radius) if left else 0
	sb.corner_radius_top_right = 0 if left else int(radius)
	sb.anti_aliasing = true
	draw_style_box(sb, r.grow(-1.0))

#endregion


#region Gamepad

func _draw_gamepad(input: Dictionary) -> void:
	var b := int(input.get("pb", 0))
	var axes: PackedFloat32Array = input.get("pa", PackedFloat32Array([0, 0, 0, 0, 0, 0]))
	var o := Vector2(MARGIN, size.y - BAR_SPACE - 214)

	# Triggers (fill = how far they're pulled) and bumpers.
	_trigger(Rect2(o + Vector2(30, 0), Vector2(80, 14)), axes[4], "LT")
	_trigger(Rect2(o + Vector2(210, 0), Vector2(80, 14)), axes[5], "RT")
	_pill(Rect2(o + Vector2(30, 22), Vector2(80, 16)), _on(b, JOY_BUTTON_LEFT_SHOULDER), "LB")
	_pill(Rect2(o + Vector2(210, 22), Vector2(80, 16)), _on(b, JOY_BUTTON_RIGHT_SHOULDER), "RB")

	# Body: a plain rounded panel.
	_box(Rect2(o + Vector2(0, 48), Vector2(320, 150)), false, 28.0)

	_stick(o + Vector2(70, 100), Vector2(axes[0], axes[1]), _on(b, JOY_BUTTON_LEFT_STICK))
	_stick(o + Vector2(205, 155), Vector2(axes[2], axes[3]), _on(b, JOY_BUTTON_RIGHT_STICK))

	# D-pad.
	var d := o + Vector2(115, 155)
	_box(Rect2(d + Vector2(-8, -26), Vector2(16, 17)), _on(b, JOY_BUTTON_DPAD_UP), 3.0)
	_box(Rect2(d + Vector2(-8, 9), Vector2(16, 17)), _on(b, JOY_BUTTON_DPAD_DOWN), 3.0)
	_box(Rect2(d + Vector2(-26, -8), Vector2(17, 16)), _on(b, JOY_BUTTON_DPAD_LEFT), 3.0)
	_box(Rect2(d + Vector2(9, -8), Vector2(17, 16)), _on(b, JOY_BUTTON_DPAD_RIGHT), 3.0)

	# Face buttons.
	var f := o + Vector2(250, 100)
	_face(f + Vector2(0, 22), _on(b, JOY_BUTTON_A), "A")
	_face(f + Vector2(22, 0), _on(b, JOY_BUTTON_B), "B")
	_face(f + Vector2(-22, 0), _on(b, JOY_BUTTON_X), "X")
	_face(f + Vector2(0, -22), _on(b, JOY_BUTTON_Y), "Y")

	# Back / Start.
	_pill(Rect2(o + Vector2(128, 94), Vector2(22, 12)), _on(b, JOY_BUTTON_BACK), "")
	_pill(Rect2(o + Vector2(170, 94), Vector2(22, 12)), _on(b, JOY_BUTTON_START), "")


static func _on(buttons: int, button: int) -> bool:
	return (buttons & (1 << button)) != 0


func _stick(center: Vector2, axis: Vector2, pressed: bool) -> void:
	draw_circle(center, 24.0, COLOR_FILL)
	draw_arc(center, 24.0, 0, TAU, 48, COLOR_LINE, 1.0, true)
	var tip := center + axis.limit_length(1.0) * 12.0
	draw_circle(tip, 9.0, COLOR_ON if pressed or axis.length() > 0.2 else COLOR_FILL)
	draw_arc(tip, 9.0, 0, TAU, 32, COLOR_LINE, 1.0, true)


func _face(center: Vector2, pressed: bool, letter: String) -> void:
	draw_circle(center, 10.0, COLOR_ON if pressed else COLOR_FILL)
	draw_arc(center, 10.0, 0, TAU, 32, COLOR_LINE, 1.0, true)
	draw_string(_font, center + Vector2(-10, 5), letter, HORIZONTAL_ALIGNMENT_CENTER, 20, 12,
		COLOR_TEXT_ON if pressed else COLOR_TEXT)


func _pill(r: Rect2, pressed: bool, text: String) -> void:
	_box(r, pressed, r.size.y / 2.0)
	if text != "":
		draw_string(_font, Vector2(r.position.x, r.end.y - 3), text, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 11,
			COLOR_TEXT_ON if pressed else COLOR_TEXT)


func _trigger(r: Rect2, amount: float, text: String) -> void:
	_box(r, false, r.size.y / 2.0)
	if amount > 0.0:
		var fill := StyleBoxFlat.new()
		fill.bg_color = COLOR_ON
		fill.set_corner_radius_all(int(r.size.y / 2.0))
		fill.anti_aliasing = true
		draw_style_box(fill, Rect2(r.position, Vector2(maxf(r.size.x * clampf(amount, 0.0, 1.0), r.size.y), r.size.y)))
	draw_string(_font, Vector2(r.position.x, r.end.y - 3), text, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 11,
		COLOR_TEXT_ON if amount > 0.5 else COLOR_TEXT)

#endregion


# A rounded box: dark and see-through, or solid light when pressed.
func _box(r: Rect2, on: bool, radius: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_ON if on else COLOR_FILL
	sb.border_color = COLOR_LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(int(radius))
	sb.anti_aliasing = true
	draw_style_box(sb, r)


static func _name(code: int) -> String:
	if NAMES.has(code):
		return NAMES[code]
	return OS.get_keycode_string(code).to_upper()
