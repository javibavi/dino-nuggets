extends Node

## Split-screen multiplayer router.
## - Owns two GameWorld instances (one per SubViewport).
## - Routes the InputReceiver's per-player gestures.
## - When a player shoots a bird, calls receive_attack() on the OTHER world
##   so the bird "magically appears" in front of the opponent.

@onready var p1: Node3D = $UI/Split/LeftViewport/SubViewport/GameWorld
@onready var p2: Node3D = $UI/Split/RightViewport/SubViewport/GameWorld
@onready var p1_label: Label = $UI/P1Label
@onready var p2_label: Label = $UI/P2Label
@onready var gesture_label: Label = $UI/GestureLabel
@onready var game_over_panel: PanelContainer = $UI/GameOverPanel
@onready var result_label: Label = $UI/GameOverPanel/VBoxContainer/ResultLabel
@onready var input_receiver: Node = $InputReceiver

var gesture_display_timer := 0.0

func _ready() -> void:
	game_over_panel.visible = false
	gesture_label.text = "Waiting for tracker…"

	for world in [p1, p2]:
		world.score_changed.connect(_on_score_changed)
		world.shot_fired.connect(_on_shot_fired)
		world.died.connect(_on_world_died)

	input_receiver.gesture_received.connect(_on_gesture_received)

func _process(delta: float) -> void:
	# R restarts both at any time.
	if Input.is_action_just_pressed("restart"):
		_restart_both()

	if gesture_display_timer > 0:
		gesture_display_timer -= delta
		if gesture_display_timer <= 0:
			if input_receiver.is_connected_to_tracker():
				gesture_label.text = "Camera: connected"
			else:
				gesture_label.text = "Waiting for tracker…"

func _on_score_changed(player_id: int, score: int) -> void:
	if player_id == 1:
		p1_label.text = "P1: %d" % score
	else:
		p2_label.text = "P2: %d" % score

func _on_shot_fired(player_id: int) -> void:
	# The OTHER player gets the bird shoved at them.
	var target := p2 if player_id == 1 else p1
	target.receive_attack()

func _on_world_died(_player_id: int) -> void:
	# Game over when EITHER player dies (simple co-op-versus rule).
	if game_over_panel.visible:
		return
	# Stop both worlds so the second player can't keep racking up score.
	p1.is_game_over = true
	p2.is_game_over = true
	p1.spawner.stop()
	p2.spawner.stop()
	game_over_panel.visible = true
	var s1 := int(p1.score)
	var s2 := int(p2.score)
	var verdict := "Tie!"
	if s1 > s2: verdict = "P1 wins!"
	elif s2 > s1: verdict = "P2 wins!"
	result_label.text = "P1: %d   P2: %d   —   %s" % [s1, s2, verdict]

func _restart_both() -> void:
	game_over_panel.visible = false
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
