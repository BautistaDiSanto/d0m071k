@tool
extends RefCounted
## The recorded sessions on disk and this machine's recording preferences,
## shared by the recorder (in the game) and the Session Replays tab (in the editor).
##
## A session is a recording in user://recordings, its replay saved in the
## project (replays folder), or both. The keep-last limit counts sessions, so it
## deletes old saved replays too.
##
## Preferences live in user://session_replay.cfg, not project.godot: they're
## yours, they survive restarts and git, and the game reads the same file.

const RECORDINGS_DIR := "user://recordings"
const PREFS_FILE := "user://session_replay.cfg"
const MAX_RECORDINGS := 5
const SETTING_REPLAYS_FOLDER := "session_replay/replays_folder"
# Where these used to be kept; read once, then removed from project.godot.
const OLD_SETTING_RECORD := "session_replay/record_editor_runs"
const OLD_SETTING_MAX := "session_replay/max_recordings"


#region Preferences

static func record_enabled() -> bool:
	return bool(_prefs().get_value("prefs", "record", true))


static func set_record_enabled(on: bool) -> void:
	_set_pref("record", on)


static func max_recordings() -> int:
	return clampi(int(_prefs().get_value("prefs", "max_recordings", MAX_RECORDINGS)), 1, MAX_RECORDINGS)


static func set_max_recordings(count: int) -> void:
	_set_pref("max_recordings", clampi(count, 1, MAX_RECORDINGS))


# Moves the old project.godot values into the preferences file.
static func migrate_project_settings() -> void:
	var moved := false
	for pair in [[OLD_SETTING_RECORD, "record"], [OLD_SETTING_MAX, "max_recordings"]]:
		if not ProjectSettings.has_setting(pair[0]):
			continue
		if not _prefs().has_section_key("prefs", pair[1]):
			_set_pref(pair[1], ProjectSettings.get_setting(pair[0]))
		ProjectSettings.set_setting(pair[0], null)
		moved = true
	if moved:
		ProjectSettings.save()


static func _prefs() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_FILE)
	return cfg


static func _set_pref(key: String, value: Variant) -> void:
	var cfg := _prefs()
	cfg.set_value("prefs", key, value)
	cfg.save(PREFS_FILE)

#endregion


#region Sessions

# Every session, newest first: [sort key, path, saved in project only].
# The path is the recording in user://recordings when it still exists,
# otherwise the .sreplay saved in the project.
static func sessions(extra_folder: String = "") -> Array:
	var list := []
	var names := {}
	for f: String in DirAccess.get_files_at(RECORDINGS_DIR):
		if f.begins_with("session_") and f.ends_with(".sreplay"):
			var path := "%s/%s" % [RECORDINGS_DIR, f]
			names[replay_name_for(path)] = true
			list.append([sort_key(path), path, false])
	for folder in replay_folders(extra_folder):
		for f: String in DirAccess.get_files_at(folder):
			if f.begins_with("replay_") and (f.ends_with(".sreplay") or f.ends_with(".tscn")):
				var path := "%s/%s.sreplay" % [folder, f.get_basename()]
				var replay_name := replay_name_for(path)
				if names.has(replay_name):
					continue
				names[replay_name] = true
				list.append([sort_key(path), path, true])
	list.sort_custom(func(a, b) -> bool: return a[0] > b[0])
	return list


# Deletes the oldest sessions (recordings and saved replays) until only `keep`
# are left. Returns how many sessions were deleted.
static func prune(keep: int, extra_folder: String = "") -> int:
	var list := sessions(extra_folder)
	var deleted := 0
	for i in range(maxi(keep, 0), list.size()):
		for path in files_of(list[i][1], extra_folder):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		deleted += 1
	return deleted


# Everything belonging to one session: the recording itself, plus its replay
# scene and the recording copied next to it (in the replays folder from Project
# Settings, and in `extra_folder`, if different).
static func files_of(recording: String, extra_folder: String = "") -> PackedStringArray:
	var files := PackedStringArray()
	for path in [recording, recording.get_basename() + ".wav"]:
		if FileAccess.file_exists(path):
			files.append(path)
	var replay_name := replay_name_for(recording)
	for folder in replay_folders(extra_folder):
		for ext in [".tscn", ".sreplay", ".swav", ".tscn.uid"]:
			var path := "%s/%s%s" % [folder, replay_name, ext]
			if FileAccess.file_exists(path) and not files.has(path):
				files.append(path)
	return files


static func replay_folders(extra_folder: String = "") -> PackedStringArray:
	var folders := PackedStringArray()
	for folder in [str(ProjectSettings.get_setting(SETTING_REPLAYS_FOLDER, "res://replays")), extra_folder]:
		folder = folder.strip_edges().trim_suffix("/")
		if folder.begins_with("res://") and not folders.has(folder) and DirAccess.dir_exists_absolute(folder):
			folders.append(folder)
	return folders


# The replay scene's name for a recording: always the same for the same one.
static func replay_name_for(recording: String) -> String:
	var file := recording.get_file().get_basename()
	if file.begins_with("replay_"):
		return file
	return "replay_" + file.trim_prefix("session_").replace("-", "").replace("T", "_")


# "20261003_200620" for both session_2026-10-03T20-06-20 and replay_20261003_200620.
static func sort_key(path: String) -> String:
	return replay_name_for(path).trim_prefix("replay_")


# Keeps a replays folder out of git: recordings are big and personal.
static func ignore_in_git(folder: String) -> void:
	var path := folder.trim_suffix("/") + "/.gitignore"
	if DirAccess.dir_exists_absolute(folder) and not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string("# Made by the Session Replay plugin: replays stay out of git.\n*\n")

#endregion
