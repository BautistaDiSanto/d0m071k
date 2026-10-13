@tool
extends EditorPlugin

const AUTOLOAD_NAME := "SessionRecorder"
const AUTOLOAD_PATH := "res://addons/session_replay/session_recorder.gd"
const DOCK_SCRIPT := preload("res://addons/session_replay/replay_dock.gd")
const Library := preload("res://addons/session_replay/session_library.gd")

# Settings the plugin adds to Project Settings > session_replay. (Whether to
# record and how many sessions to keep are per machine, in session_library.gd.)
var SETTINGS := {
	"session_replay/replays_folder": "res://replays",
	# @tool scripts from these folders keep running in replays (e.g. addons that build
	# meshes). Every other script is removed from the replayed scenes.
	"session_replay/keep_scripts_from": PackedStringArray(["res://addons/"]),
}

var _dock: Control


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_add_settings()
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


# The "Session Replays" tab sits in the bottom panel, next to Output and Debugger.
func _enter_tree() -> void:
	_add_settings()
	Library.migrate_project_settings()
	for folder in Library.replay_folders():
		Library.ignore_in_git(folder)
	_dock = DOCK_SCRIPT.new()
	_dock.name = "SessionReplays"
	add_control_to_bottom_panel(_dock, "Session Replays")


func _exit_tree() -> void:
	if _dock:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null


func _add_settings() -> void:
	for key in SETTINGS:
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, SETTINGS[key])
		ProjectSettings.set_initial_value(key, SETTINGS[key])
		ProjectSettings.set_as_basic(key, true)
	ProjectSettings.add_property_info({
		"name": "session_replay/replays_folder",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_DIR,
	})
