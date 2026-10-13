@tool
extends HBoxContainer
## "Replays" tab in the editor's bottom panel (next to Output): lists recorded
## sessions and turns one into a replay scene.

const RUNNER_SCRIPT := "res://addons/session_replay/replay_runner.gd"
const Library := preload("res://addons/session_replay/session_library.gd")
const RECORDINGS_DIR := Library.RECORDINGS_DIR

var _list: Tree
var _confirm_delete: ConfirmationDialog
var _pending_delete := ""
var _keep: SpinBox
var _confirm_keep: ConfirmationDialog
var _confirm_delete_all: ConfirmationDialog
var _folder: LineEdit
var _name: LineEdit
var _status: Label
var _folder_dialog: EditorFileDialog
var _paths: Array[String] = []


func _ready() -> void:
	custom_minimum_size = Vector2(0, 220)
	add_theme_constant_override("separation", 12)

	# Left: the recordings.
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(left)
	var top := HBoxContainer.new()
	left.add_child(top)
	var title := Label.new()
	title.text = "Recorded sessions (newest first). Play the game from the editor to record one."
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	top.add_child(title)
	top.add_child(_button("Refresh", refresh))
	top.add_child(_button("Delete all", _on_delete_all_pressed))
	top.add_child(_button("Open folder", func() -> void:
		DirAccess.make_dir_recursive_absolute(RECORDINGS_DIR)
		OS.shell_open(ProjectSettings.globalize_path(RECORDINGS_DIR))))
	# One row per recording, with a trash can button to delete it.
	_list = Tree.new()
	_list.hide_root = true
	_list.custom_minimum_size = Vector2(0, 150)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func() -> void: _on_recording_selected(_selected_index()))
	_list.button_clicked.connect(_on_trash_clicked)
	_list.item_activated.connect(_play_session) # double-click plays it
	left.add_child(_list)

	_confirm_delete = ConfirmationDialog.new()
	_confirm_delete.title = "Delete recording"
	_confirm_delete.ok_button_text = "Delete"
	_confirm_delete.confirmed.connect(_delete_pending)
	add_child(_confirm_delete)

	_confirm_delete_all = ConfirmationDialog.new()
	_confirm_delete_all.title = "Delete all sessions"
	_confirm_delete_all.ok_button_text = "Delete all"
	_confirm_delete_all.confirmed.connect(_delete_all)
	add_child(_confirm_delete_all)

	# Right: turn the selected one into a replay scene.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 0)
	add_child(right)
	# Whether pressing Play records the session.
	var record := CheckButton.new()
	record.text = "Record next session"
	record.button_pressed = Library.record_enabled()
	record.tooltip_text = "When on, playing the game from the editor records the session."
	record.toggled.connect(_on_record_toggled)
	right.add_child(record)

	right.add_child(_label("Save replay scene in folder:"))
	var folder_row := HBoxContainer.new()
	right.add_child(folder_row)
	_folder = LineEdit.new()
	_folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder.text = ProjectSettings.get_setting("session_replay/replays_folder", "res://replays")
	folder_row.add_child(_folder)
	folder_row.add_child(_button("...", _choose_folder))
	right.add_child(_label("Name:"))
	_name = LineEdit.new()
	_name.placeholder_text = "e.g. hub_to_first_race"
	right.add_child(_name)
	right.add_child(_button("Play session", _play_session))

	# How many recordings to keep.
	var keep_row := HBoxContainer.new()
	right.add_child(keep_row)
	var keep_label := _label("Keep the last")
	keep_row.add_child(keep_label)
	_keep = SpinBox.new()
	_keep.min_value = 1
	_keep.max_value = Library.MAX_RECORDINGS
	_keep.value = Library.max_recordings()
	_keep.tooltip_text = "Older sessions, saved replays included, are deleted when a new one starts (up to %d kept)." % Library.MAX_RECORDINGS
	_keep.value_changed.connect(_on_keep_changed)
	keep_row.add_child(_keep)
	keep_row.add_child(_label("sessions"))
	# Lowering the limit below what's on disk asks before deleting.
	_confirm_keep = ConfirmationDialog.new()
	_confirm_keep.title = "Delete old sessions"
	_confirm_keep.ok_button_text = "Delete"
	_confirm_keep.confirmed.connect(_apply_keep)
	_confirm_keep.canceled.connect(func() -> void: _keep.set_value_no_signal(Library.max_recordings()))
	add_child(_confirm_keep)
	_status = _label("")
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_status)

	_folder_dialog = EditorFileDialog.new()
	_folder_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_folder_dialog.dir_selected.connect(func(dir: String) -> void: _folder.text = dir)
	add_child(_folder_dialog)

	visibility_changed.connect(func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func _on_delete_all_pressed() -> void:
	var count := Library.sessions(_folder.text).size()
	if count == 0:
		_status.text = "There are no sessions to delete."
		return
	_confirm_delete_all.dialog_text = "Delete all %d sessions, their recordings and their saved replays? This can't be undone." % count
	_confirm_delete_all.popup_centered()


func _delete_all() -> void:
	var deleted := Library.prune(0, _folder.text)
	_status.text = "Deleted %d session(s)." % deleted
	EditorInterface.get_resource_filesystem().scan()
	refresh()


func _on_record_toggled(on: bool) -> void:
	Library.set_record_enabled(on)
	_status.text = "The next session you play will be recorded." if on else "Sessions won't be recorded until you turn this back on."


func _on_keep_changed(value: float) -> void:
	var sessions := Library.sessions(_folder.text)
	if sessions.size() <= int(value):
		_apply_keep()
		return
	var listing := ""
	for i in range(int(value), sessions.size()):
		listing += "\n" + _describe(sessions[i][1])
	_confirm_keep.dialog_text = "Keep only the last %d? These sessions and their saved replays will be deleted. This can't be undone.\n%s" % [int(value), listing]
	_confirm_keep.popup_centered()


# Saves the keep-last limit and deletes the sessions past it right away.
func _apply_keep() -> void:
	var keep := int(_keep.value)
	Library.set_max_recordings(keep)
	var deleted := Library.prune(keep, _folder.text)
	_status.text = "Keeping the last %d sessions." % keep
	if deleted > 0:
		_status.text += " Deleted %d older one(s)." % deleted
		EditorInterface.get_resource_filesystem().scan()
	refresh()


# Lists every session: the recordings in AppData, plus replays saved in the
# project whose original recording is gone, so nothing sits in the project
# without showing up here.
func refresh() -> void:
	_list.clear()
	_paths.clear()
	var root := _list.create_item()
	var trash := EditorInterface.get_editor_theme().get_icon("Remove", "EditorIcons")
	DirAccess.make_dir_recursive_absolute(RECORDINGS_DIR)
	var sessions := Library.sessions(_folder.text)
	for entry in sessions:
		var path: String = entry[1]
		_paths.append(path)
		var item := _list.create_item(root)
		item.set_text(0, _describe(path) + ("  ·  saved in project" if entry[2] else ""))
		item.set_tooltip_text(0, ProjectSettings.globalize_path(path))
		item.set_metadata(0, _paths.size() - 1)
		item.add_button(0, trash, 0, false, "Delete this session")
	if sessions.is_empty():
		_status.text = "No recordings yet. Play the game from the editor and it's recorded automatically."


# "2026-10-03 17:53  ·  1:24  ·  2.1 MB"
func _describe(path: String) -> String:
	var key := Library.sort_key(path)
	var date := key
	if key.length() >= 13:
		date = "%s-%s-%s %s:%s" % [key.substr(0, 4), key.substr(4, 2), key.substr(6, 2), key.substr(9, 2), key.substr(11, 2)]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return date + "  ·  no recording file"
	var mb := f.get_length() / 1048576.0
	# Length: the last frame number (records are read until the end).
	var frames := 0
	var ticks := 60
	var header = f.get_var()
	if header is Dictionary:
		ticks = int(header.get("ticks", 60))
	while f.get_position() < f.get_length():
		var rec = f.get_var()
		if not (rec is Dictionary):
			break
		frames = int(rec.get("end", rec.get("f", frames)))
	var seconds := frames / maxi(ticks, 1)
	return "%s  ·  %d:%02d  ·  %.1f MB" % [date, seconds / 60, seconds % 60, mb]


func _on_recording_selected(index: int) -> void:
	# Same name every time for the same recording, so it's only saved once.
	_name.text = Library.replay_name_for(_paths[index])


func _selected_index() -> int:
	var item := _list.get_selected()
	return int(item.get_metadata(0)) if item else -1


func _on_trash_clicked(item: TreeItem, _column: int, _id: int, _button: int) -> void:
	_pending_delete = _paths[int(item.get_metadata(0))]
	var files := _files_of(_pending_delete)
	var listing := ""
	for f in files:
		listing += "\n" + f
	_confirm_delete.dialog_text = "Delete this session and everything made from it? This can't be undone.\n%s" % listing
	_confirm_delete.popup_centered()


# Everything belonging to one recorded session (see Library.files_of), also
# looking in the folder typed in this tab.
func _files_of(recording: String) -> PackedStringArray:
	return Library.files_of(recording, _folder.text)


func _delete_pending() -> void:
	if _pending_delete == "":
		return
	var failed := 0
	var touched_project := false
	for path in _files_of(_pending_delete):
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) != OK:
			failed += 1
		elif path.begins_with("res://"):
			touched_project = true
	_status.text = "Deleted the session and its replay scene." if failed == 0 else "Couldn't delete %d file(s)." % failed
	_pending_delete = ""
	if touched_project:
		EditorInterface.get_resource_filesystem().scan()
	refresh()


func _choose_folder() -> void:
	_folder_dialog.current_dir = _folder.text
	_folder_dialog.popup_file_dialog()


# Plays the selected recording: makes its replay scene the first time (in the
# chosen folder, under the chosen name), then runs it like F6 would.
func _play_session() -> void:
	var index := _selected_index()
	if index < 0:
		_status.text = "Pick a recording first."
		return
	var replay_name := _clean_name(_name.text)
	if replay_name == "":
		_status.text = "Give the replay a name."
		return
	var folder := _folder.text.strip_edges().trim_suffix("/")
	if not folder.begins_with("res://"):
		_status.text = "The folder must be inside the project (res://)."
		return

	var scene_path := "%s/%s.tscn" % [folder, replay_name]
	var recording_path := "%s/%s.sreplay" % [folder, replay_name]
	if not FileAccess.file_exists(scene_path):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		Library.ignore_in_git(folder)
		var source := _paths[index]
		# A session only saved in the project already has its files there.
		if source != recording_path:
			var err := DirAccess.copy_absolute(
				ProjectSettings.globalize_path(source),
				ProjectSettings.globalize_path(recording_path))
			if err != OK:
				_status.text = "Couldn't copy the recording (error %d)." % err
				return
		# Its sound goes along with it (it may not exist for older sessions).
		var sound := source.get_basename() + ".wav"
		if FileAccess.file_exists(sound):
			DirAccess.copy_absolute(ProjectSettings.globalize_path(sound),
				ProjectSettings.globalize_path(recording_path.get_basename() + ".swav"))
		var scene := FileAccess.open(scene_path, FileAccess.WRITE)
		if scene == null:
			_status.text = "Couldn't write %s." % scene_path
			return
		scene.store_string("""[gd_scene format=3]

[ext_resource type="Script" path="%s" id="1_runner"]

[node name="%s" type="Node"]
script = ExtResource("1_runner")
recording = "%s"
""" % [RUNNER_SCRIPT, replay_name.to_pascal_case(), recording_path])
		scene.close()
		var fs := EditorInterface.get_resource_filesystem()
		fs.scan()
		await fs.filesystem_changed
		_status.text = "Saved %s and started it." % scene_path
	else:
		_status.text = "Playing %s." % scene_path
	EditorInterface.play_custom_scene(scene_path)


static func _clean_name(text: String) -> String:
	var out := ""
	for c in text.strip_edges().replace(" ", "_"):
		if c.is_valid_ascii_identifier() or c.is_valid_int() or c == "-":
			out += c
	return out


func _button(text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	return b


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
