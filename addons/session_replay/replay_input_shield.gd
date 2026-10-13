# Keeps your own mouse and keyboard to the replay controls while a replay plays.
#
# It sits as the last child of the root, which gets every input event first,
# stops it, and hands mouse events and the player's shortcut keys to the
# controls. (The recorded scenes don't process input anyway; this keeps the
# game's autoloads out of it too.)
extends Node

var player_ui: Control


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.child_entered_tree.connect(_stay_last)


# Anything added to the root after us would get input first; move back to the end.
func _stay_last(node: Node) -> void:
	if node != self:
		get_parent().move_child.call_deferred(self, -1)


func _input(event: InputEvent) -> void:
	if not is_instance_valid(player_ui):
		return
	get_viewport().set_input_as_handled()
	if event is InputEventMouse:
		player_ui.handle_real_input(event)
	elif event is InputEventKey:
		player_ui.handle_real_key(event)
