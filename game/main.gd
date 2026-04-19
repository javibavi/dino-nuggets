extends Node

## Split-screen multiplayer router.
## - Owns two GameWorld instances (one per SubViewport).
## - Routes the InputReceiver's per-player gestures.
## - When a player shoots a bird, calls receive_attack() on the OTHER world
##   so the bird "magically appears" in front of the opponent.

@onready var p1: Node3D = $UI/Split/LeftViewport/SubViewport/GameWorld
@onready var p2: Node3D = $UI/Split/RightViewport/SubViewport/GameWorld
@onready var timer_label: Label = $UI/TimerPanel/P1Label
@onready var p2_label: Label = $UI/P2Label
@onready var gesture_label: Label = $UI/GestureLabel
@onready var game_over_panel: PanelContainer = $UI/GameOverPanel
@onready var result_label: Label = $UI/GameOverPanel/VBoxContainer/ResultLabel
@onready var input_receiver: Node = $InputReceiver

var gesture_display_timer := 0.0
var elapsed_time := 0.0
var game_running := false

func _ready() -> void:
	game_over_panel.visible = false
	gesture_label.text = "Waiting for tracker…"
	p2_label.visible = false
	game_running = true

	for world in [p1, p2]:
		world.shot_fired.connect(_on_shot_fired)
		world.died.connect(_on_world_died)

	input_receiver.gesture_received.connect(_on_gesture_received)

func _format_time(t: float) -> String:
	var m := int(t) / 60
	var s := int(t) % 60
	return "%d:%02d" % [m, s]

func _process(delta: float) -> void:
	# R restarts both at any time.
	if Input.is_action_just_pressed("restart"):
		_restart_both()

	if game_running:
		elapsed_time += delta
		timer_label.text = _format_time(elapsed_time)

	if gesture_display_timer > 0:
		gesture_display_timer -= delta
		if gesture_display_timer <= 0:
			if input_receiver.is_connected_to_tracker():
				gesture_label.text = "Camera: connected"
			else:
				gesture_label.text = "Waiting for tracker…"

func _on_shot_fired(player_id: int) -> void:
	# The OTHER player gets the bird shoved at them.
	var target := p2 if player_id == 1 else p1
	target.receive_attack()

func _on_world_died(player_id: int) -> void:
	# Game over when EITHER player dies (simple co-op-versus rule).
	if game_over_panel.visible:
		return
	# Freeze both worlds and mark both players dead so stray obstacles
	# can't re-trigger this and flip the result.
	p1.is_game_over = true
	p2.is_game_over = true
	p1.player.is_dead = true
	p2.player.is_dead = true
	p1.spawner.freeze()
	p2.spawner.freeze()
	game_running = false
	game_over_panel.visible = true
	var verdict := "P2 wins!" if player_id == 1 else "P1 wins!"
	result_label.text = "%s   —   %s" % [_format_time(elapsed_time), verdict]

func _restart_both() -> void:
	game_over_panel.visible = false
	elapsed_time = 0.0
	game_running = true
	p1.reset()
	p2.reset()

func _on_gesture_received(player_id: int, gesture: String) -> void:
	# player_id 0 = unprefixed (e.g. "ping"). Treat as a status update.
	if player_id == 0:
		if gesture == "ping":
			gesture_label.text = "Camera: connected"
			gesture_display_timer = 1.0
		return

	gesture_label.text = "P%d: %s" % [player_id, gesture]
	gesture_display_timer = 1.0

	if game_over_panel.visible:
		# Allow swipe_up from either player to restart.
		if gesture == "swipe_up":
			_restart_both()
		return

	var world := p1 if player_id == 1 else p2
	world.on_gesture(gesture)
