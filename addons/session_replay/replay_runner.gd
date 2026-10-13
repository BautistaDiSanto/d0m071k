# Root script of the scenes the Replays dock makes.
#
# Run the scene (F6) and the recorded session plays from its first frame, with
# the replay bar at the bottom and the input overlay on the left.
extends Node

const PLAYER := preload("res://addons/session_replay/replay_player.gd")

## The recording this scene plays (.sreplay, saved next to the scene).
@export_file("*.sreplay") var recording: String


func _ready() -> void:
	var player := PLAYER.new()
	player.name = "ReplayPlayer"
	if player.open(recording):
		add_child(player)
	else:
		player.free()
