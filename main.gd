extends MarginContainer
## Desktop control for Tuya bulbs over the local network. No cloud, no helper programs:
## bulbs are listed in lights.cfg and found on the network automatically.
## Each bulb gets a collapsible section with a COLOR tab (hue bar + brightness)
## and a WARM tab (warm-to-cool white + brightness).

const Tuya := preload("res://tuya.gd")
## Packed into the .exe on export (the export preset's include filter lists it).
const CONFIG_PATH := "res://lights.cfg"
## Where each bulb was found last time, so the next start is instant.
const CACHE_PATH := "user://found_bulbs.cfg"
## Window background: the same dark gradient as the app icon.
const BG_TOP := Color("#26222e")
const BG_BOTTOM := Color("#141218")
## Notification-area icon: the glowing bulb, at tray size.
const TRAY_ICON := preload("res://tray.png")

var bulbs: Array[Dictionary] = []  # {name, id, key, ip, version, device, ui, ...}
var list := VBoxContainer.new()
var status := Label.new()
var scan_prefixes: Array = []  # networks to scan; empty means this computer's own
var tray: StatusIndicator  # null when the app quits on close (not Windows, or run inside the editor)


## A horizontal colour strip you click or drag along; value runs 0 to 1.
class GradientBar extends Control:
	signal picked(value: float)
	var value := 0.0
	var _tex := GradientTexture1D.new()
	## Takes on the colour under the marker (the tab underline), so it shows the light's colour.
	var tint: ColorRect

	func _init(g: Gradient) -> void:
		_tex.gradient = g
		_tex.width = 256
		custom_minimum_size = Vector2(0, 30)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func set_value(v: float) -> void:
		value = clampf(v, 0.0, 1.0)
		if tint:
			tint.color = _tex.gradient.sample(value)
		queue_redraw()

	func _gui_input(e: InputEvent) -> void:
		var mb := e as InputEventMouseButton
		var mm := e as InputEventMouseMotion
		var click := mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed
		var drag := mm != null and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0
		if click or drag:
			set_value((e as InputEventMouse).position.x / size.x)
			picked.emit(value)
			accept_event()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_texture_rect(_tex, r, false)
		draw_rect(r, Color(0, 0, 0, 0.6), false, 2.0)
		var marker := Rect2(value * size.x - 3, -3, 6, size.y + 6)
		draw_rect(marker, Color.WHITE)
		draw_rect(marker, Color.BLACK, false, 1.5)


## The arrow on a bulb's header: ^ while closed, v while open (as in the sketch).
class Chevron extends Control:
	var open := false:
		set(v):
			open = v
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(18, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var top := h * 0.3
		var bottom := h * 0.7
		var pts := PackedVector2Array([Vector2(2, top), Vector2(w / 2, bottom), Vector2(w - 2, top)]) if open \
			else PackedVector2Array([Vector2(2, bottom), Vector2(w / 2, top), Vector2(w - 2, bottom)])
		draw_polyline(pts, Color(1, 1, 1, 0.85), 2.5, true)


func _draw() -> void:
	var r := get_rect()
	draw_polygon(
		PackedVector2Array([Vector2.ZERO, Vector2(r.size.x, 0), r.size, Vector2(0, r.size.y)]),
		PackedColorArray([BG_TOP, BG_TOP, BG_BOTTOM, BG_BOTTOM]))


func _ready() -> void:
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 16)
	_build_ui()
	_setup_tray()
	_load_config()
	if bulbs.is_empty():
		status.text = "Add your bulb's id and local_key to lights.cfg in the project folder, then restart."
		return
	for i in bulbs.size():
		_build_bulb(bulbs[i], i == 0)
	await _find_bulbs()


## Puts the app in the notification area (next to the clock). Closing the window
## then only hides it: clicking the icon brings it back, right-clicking it
## offers Show and Quit.
func _setup_tray() -> void:
	if OS.get_name() != "Windows" or Engine.is_embedded_in_editor() \
			or not DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR):
		return
	get_tree().set_auto_accept_quit(false)
	var menu := PopupMenu.new()
	menu.add_item("Show", 0)
	menu.add_item("Quit", 1)
	menu.id_pressed.connect(_on_tray_menu)
	add_child(menu)
	tray = StatusIndicator.new()
	tray.icon = TRAY_ICON
	tray.tooltip = ProjectSettings.get_setting("application/config/name")
	tray.pressed.connect(_on_tray_pressed)
	add_child(tray)
	tray.menu = tray.get_path_to(menu)


func _on_tray_pressed(button: int, _at: Vector2i) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_show_window()


func _on_tray_menu(id: int) -> void:
	if id == 0:
		_show_window()
	else:
		get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and tray:
		_hide_window()


## Godot can't hide its own main window, so it minimizes it and a hidden
## PowerShell call then takes it off the taskbar (unless it was reopened meanwhile).
func _hide_window() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	OS.low_processor_usage_mode = true
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var ps := "$w = Add-Type -Name W -Namespace Domotic -PassThru -MemberDefinition '" \
		+ "[DllImport(\"user32.dll\")] public static extern bool ShowWindow(System.IntPtr h, int c);" \
		+ "[DllImport(\"user32.dll\")] public static extern bool IsIconic(System.IntPtr h);'; " \
		+ "$h = [System.IntPtr]::new(%d); if ($w::IsIconic($h)) { [void]$w::ShowWindow($h, 0) }" % hwnd
	OS.create_process("powershell.exe", ["-NoProfile", "-NonInteractive", "-EncodedCommand",
		Marshalls.raw_to_base64(ps.to_utf16_buffer())])


func _show_window() -> void:
	OS.low_processor_usage_mode = false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_move_to_foreground()


func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	box.add_child(scroll)

	status.modulate = Color(1, 1, 1, 0.6)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(status)


func _box_style(bg: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(12)
	return s


## One dropdown section: header (name, on/off, arrow) and a body with the two tabs.
func _build_bulb(b: Dictionary, open: bool) -> void:
	var ui := {}
	b.ui = ui
	b.mode = "colour"
	b.sending = false
	b.queued = {}
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 0)
	list.add_child(section)

	# header
	var header := Button.new()
	header.custom_minimum_size.y = 46
	header.focus_mode = Control.FOCUS_NONE
	header.add_theme_stylebox_override("normal", _box_style(Color("#2e2a37"), 6))
	header.add_theme_stylebox_override("hover", _box_style(Color("#38333f"), 6))
	header.add_theme_stylebox_override("pressed", _box_style(Color("#38333f"), 6))
	section.add_child(header)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14
	row.offset_right = -14
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(row)
	var name_label := Label.new()
	name_label.text = b.name
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	ui.power = CheckButton.new()
	ui.power.focus_mode = Control.FOCUS_NONE
	ui.power.tooltip_text = "On / off"
	ui.power.toggled.connect(func(on): _send(b, {"20": on}))
	row.add_child(ui.power)
	ui.arrow = Chevron.new()
	row.add_child(ui.arrow)

	# body
	var body := PanelContainer.new()
	var body_style := _box_style(Color("#1e1b24"), 6)
	body_style.set_border_width_all(1)
	body_style.border_color = Color("#3b3645")
	body.add_theme_stylebox_override("panel", body_style)
	section.add_child(body)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 14)
	body.add_child(inner)

	header.pressed.connect(func():
		body.visible = not body.visible
		ui.arrow.open = body.visible)
	body.visible = open
	ui.arrow.open = open

	# tabs
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	inner.add_child(tabs)
	var group := ButtonGroup.new()
	var pages := []
	ui.tab_buttons = []
	var underlines := []
	for title in ["COLOR", "WARM"]:
		var tab := VBoxContainer.new()
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.add_theme_constant_override("separation", 2)
		var t := Button.new()
		t.text = title
		t.flat = true
		t.toggle_mode = true
		t.button_group = group
		t.focus_mode = Control.FOCUS_NONE
		t.add_theme_font_size_override("font_size", 16)
		tab.add_child(t)
		var underline := ColorRect.new()
		underline.custom_minimum_size.y = 3
		tab.add_child(underline)
		underlines.append(underline)
		t.toggled.connect(func(on): underline.modulate.a = 1.0 if on else 0.0)
		underline.modulate.a = 0.0
		tabs.add_child(tab)
		ui.tab_buttons.append(t)
		var page := VBoxContainer.new()
		page.add_theme_constant_override("separation", 8)
		inner.add_child(page)
		pages.append(page)

	# COLOR page: rainbow bar, brightness
	var rainbow := Gradient.new()
	rainbow.offsets = PackedFloat32Array([0, 1 / 6.0, 2 / 6.0, 3 / 6.0, 4 / 6.0, 5 / 6.0, 1])
	rainbow.colors = PackedColorArray([0, 1, 2, 3, 4, 5, 6].map(func(i): return Color.from_hsv(i / 6.0, 1, 1)))
	ui.hue = GradientBar.new(rainbow)
	ui.hue.tint = underlines[0]
	ui.hue.set_value(0.0)
	ui.hue.picked.connect(func(_v): _send_colour(b))
	pages[0].add_child(ui.hue)
	ui.colour_level = _brightness(pages[0], func(): _send_colour(b))

	# WARM page: warm-to-cool bar, brightness
	var whites := Gradient.new()
	whites.offsets = PackedFloat32Array([0, 0.5, 1])
	whites.colors = PackedColorArray([Color(1, 0.6, 0.2), Color(1, 0.95, 0.88), Color(0.72, 0.84, 1)])
	ui.warmth = GradientBar.new(whites)
	ui.warmth.tint = underlines[1]
	ui.warmth.set_value(0.5)
	ui.warmth.picked.connect(func(_v): _send_white(b))
	pages[1].add_child(ui.warmth)
	ui.white_level = _brightness(pages[1], func(): _send_white(b))

	for i in 2:
		ui.tab_buttons[i].toggled.connect(func(on):
			pages[i].visible = on
			if not on or ui.get("syncing", false):
				return
			if i == 0:
				_send_colour(b)
			else:
				_send_white(b))
	ui.syncing = true
	ui.tab_buttons[0].button_pressed = true
	pages[1].visible = false
	ui.syncing = false


## "Brightness", a slider and its percentage underneath. Returns the slider.
func _brightness(page: VBoxContainer, on_change: Callable) -> HSlider:
	var title := Label.new()
	title.text = "Brightness"
	page.add_child(title)
	var slider := HSlider.new()
	slider.min_value = 1
	slider.max_value = 100
	slider.value = 100
	slider.custom_minimum_size.y = 24
	page.add_child(slider)
	var pct := Label.new()
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pct.add_theme_font_size_override("font_size", 18)
	pct.text = "100 %"
	page.add_child(pct)
	slider.value_changed.connect(func(v):
		pct.text = "%d %%" % int(v)
		on_change.call())
	slider.set_meta("pct", pct)
	return slider


func _set_slider(slider: HSlider, v: float) -> void:
	slider.set_value_no_signal(v)
	slider.get_meta("pct").text = "%d %%" % int(slider.value)


func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for section in cfg.get_sections():
		var id := str(cfg.get_value(section, "id", "")).strip_edges()
		var key := str(cfg.get_value(section, "local_key", "")).strip_edges()
		if id.is_empty() or key.is_empty():
			continue
		bulbs.append({
			"name": section, "id": id, "key": key,
			"ip": str(cfg.get_value(section, "ip", "")).strip_edges(),
			"version": str(cfg.get_value(section, "version", "")).strip_edges(),
			"device": null, "from_cache": false,
		})


## Works out each bulb's IP address and protocol version (unless lights.cfg has
## them): first from what was found last time, then from the broadcasts Tuya
## devices send, and if those are blocked (often by the firewall) by trying every
## address on the local network.
func _find_bulbs() -> void:
	_apply_cache()
	await _discover()
	var stale := false
	for b in bulbs:
		if b.from_cache and await Tuya.new(b.id, b.key, b.ip, b.version).get_dps() == null:
			b.ip = ""
			b.version = ""
			b.from_cache = false
			stale = true
	if stale:
		await _discover()

	var problems := []
	for b in bulbs:
		if b.ip.is_empty() or b.version.is_empty():
			problems.append("%s wasn't found on the network. Is it on and on the same Wi-Fi as this computer? Check its local_key too." % b.name)
		elif b.version not in ["3.3", "3.4", "3.5"]:
			problems.append("%s uses protocol %s, which this app doesn't support yet." % [b.name, b.version])
		else:
			b.device = Tuya.new(b.id, b.key, b.ip, b.version)
	_save_cache()
	status.text = "\n".join(problems) if problems else "Ready: " + ", ".join(bulbs.map(func(b): return "%s (%s, v%s)" % [b.name, b.ip, b.version]))
	await _read_state()


func _unresolved() -> Array:
	return bulbs.filter(func(b): return b.ip.is_empty() or b.version.is_empty())


func _discover() -> void:
	if _unresolved().is_empty():
		return
	status.text = "Looking for your bulb on the network..."
	await _listen_for_broadcasts(6000)
	if not _unresolved().is_empty():
		status.text = "Searching every address on your network for the bulb..."
		await _scan_network()


func _listen_for_broadcasts(duration_ms: int) -> void:
	var sockets: Array[PacketPeerUDP] = []
	for port in [6666, 6667, 7000]:
		var s := PacketPeerUDP.new()
		if s.bind(port) == OK:
			sockets.append(s)
	var asker := PacketPeerUDP.new()
	asker.set_broadcast_enabled(true)
	var deadline := Time.get_ticks_msec() + duration_ms
	var next_ask := 0
	while Time.get_ticks_msec() < deadline and not _unresolved().is_empty():
		if Time.get_ticks_msec() >= next_ask:
			# v3.5 devices only announce themselves when asked
			for my_ip in _local_ips():
				asker.set_dest_address(my_ip.substr(0, my_ip.rfind(".")) + ".255", 7000)
				asker.put_packet(Tuya.devinfo_request(my_ip))
			next_ask = Time.get_ticks_msec() + 2000
		for s in sockets:
			while s.get_available_packet_count() > 0:
				var info = Tuya.decode_broadcast(s.get_packet())
				if info == null:
					continue
				for b in _unresolved():
					if info.get("gwId", info.get("devId", "")) == b.id:
						if b.ip.is_empty():
							b.ip = str(info.get("ip", ""))
						if b.version.is_empty():
							b.version = str(info.get("version", ""))
		await get_tree().create_timer(0.1).timeout
	for s in sockets:
		s.close()
	asker.close()


## Tries port 6668 (Tuya's) on every address of each local network, then asks each
## device that answers whether it accepts a bulb's key, trying each protocol version.
func _scan_network() -> void:
	var prefixes := scan_prefixes if not scan_prefixes.is_empty() else _local_ips().map(func(a): return a.substr(0, a.rfind(".")))
	var open_hosts := []
	for prefix in prefixes:
		var pending := {}
		for i in range(1, 255):
			var t := StreamPeerTCP.new()
			var host := "%s.%d" % [prefix, i]
			if t.connect_to_host(host, Tuya.PORT) == OK:
				pending[host] = t
		var deadline := Time.get_ticks_msec() + 2500
		while Time.get_ticks_msec() < deadline and not pending.is_empty():
			for host in pending.keys():
				var t: StreamPeerTCP = pending[host]
				t.poll()
				if t.get_status() == StreamPeerTCP.STATUS_CONNECTED:
					open_hosts.append(host)
				if t.get_status() != StreamPeerTCP.STATUS_CONNECTING:
					t.disconnect_from_host()
					pending.erase(host)
			await get_tree().process_frame
		for t in pending.values():
			t.disconnect_from_host()
	for host in open_hosts:
		for b in _unresolved():
			if not b.ip.is_empty() and b.ip != host:
				continue
			var versions := [b.version] if b.version else ["3.5", "3.4", "3.3"]
			for ver in versions:
				var probe = Tuya.new(b.id, b.key, host, ver)
				probe.timeout_ms = 2000
				if await probe.get_dps() != null:
					b.ip = host
					b.version = ver
					break
			if b.ip == host and b.version:
				break


## This computer's private IPv4 addresses, home-router style (192.168.x.x) first.
func _local_ips() -> Array:
	var found := []
	for prefix in ["192.168.", "10.", "172."]:
		for addr in IP.get_local_addresses():
			if addr.begins_with(prefix) and addr.count(".") == 3:
				found.append(addr)
	return found


func _apply_cache() -> void:
	var cache := ConfigFile.new()
	if cache.load(CACHE_PATH) != OK:
		return
	for b in bulbs:
		if b.ip.is_empty() and b.version.is_empty() and cache.has_section(b.id):
			b.ip = cache.get_value(b.id, "ip", "")
			b.version = cache.get_value(b.id, "version", "")
			b.from_cache = true


func _save_cache() -> void:
	var cache := ConfigFile.new()
	for b in bulbs:
		if b.device != null:
			cache.set_value(b.id, "ip", b.ip)
			cache.set_value(b.id, "version", b.version)
	cache.save(CACHE_PATH)


## Loads each bulb's current settings so its controls start where the bulb is.
func _read_state() -> void:
	for b in bulbs:
		if b.device == null:
			continue
		var dps = await b.device.get_dps()
		if not dps is Dictionary:
			continue
		var ui: Dictionary = b.ui
		if dps.has("20"):
			ui.power.set_pressed_no_signal(bool(dps["20"]))
		if dps.has("22"):
			_set_slider(ui.white_level, int(dps["22"]) / 10)
		if dps.has("23"):
			ui.warmth.set_value(int(dps["23"]) / 1000.0)
		var hsv := str(dps.get("24", ""))
		if hsv.length() == 12:
			ui.hue.set_value(hsv.substr(0, 4).hex_to_int() / 360.0)
			_set_slider(ui.colour_level, hsv.substr(8, 4).hex_to_int() / 10)
		ui.syncing = true
		ui.tab_buttons[0 if dps.get("21", "white") == "colour" else 1].button_pressed = true
		ui.syncing = false


## Sends to one bulb. While a command is on its way, newer changes are merged and
## sent right after, so dragging a slider doesn't pile up commands.
func _send(b: Dictionary, dps: Dictionary) -> void:
	if b.device == null:
		status.text = "%s isn't connected yet." % b.name
		return
	b.queued.merge(dps, true)
	if b.sending:
		return
	b.sending = true
	while not b.queued.is_empty():
		var next: Dictionary = b.queued
		b.queued = {}
		var err: String = await b.device.set_dps(next)
		status.text = "%s: %s" % [b.name, err] if err else ""
	b.sending = false


func _send_white(b: Dictionary) -> void:
	b.ui.power.set_pressed_no_signal(true)
	await _send(b, {"20": true, "21": "white", "22": int(b.ui.white_level.value * 10), "23": int(b.ui.warmth.value * 1000)})


## Tuya's colour format: hue 0-360, saturation and value 0-1000, each as 4 hex digits.
func _send_colour(b: Dictionary) -> void:
	b.ui.power.set_pressed_no_signal(true)
	var hue := int(b.ui.hue.value * 360) % 360
	var level: int = max(10, int(b.ui.colour_level.value * 10))
	await _send(b, {"20": true, "21": "colour", "24": "%04x%04x%04x" % [hue, 1000, level]})
