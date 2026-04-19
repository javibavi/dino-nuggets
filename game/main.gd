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
@onready var game_over_panel: PanelContainer = $UI/GameOverPanel
@onready var result_label: Label = $UI/GameOverPanel/VBoxContainer/ResultLabel
@onready var input_receiver: Node = $InputReceiver

func _ready() -> void:
	game_over_panel.visible = false

	for world in [p1, p2]:
		world.score_changed.connect(_on_score_changed)
		world.shot_fired.connect(_on_shot_fired)
		world.died.connect(_on_world_died)

	input_receiver.gesture_received.connect(_on_gesture_received)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		_restart_both()

func _on_score_changed(player_id: int, score: int) -> void:
	if player_id == 1:
		p1_label.text = "P1: %d" % score
	else:
		p2_label.text = "P2: %d" % score

func _on_shot_fired(player_id: int) -> void:
	var target := p2 if player_id == 1 else p1
	target.receive_attack()

func _on_world_died(_player_id: int) -> void:
	if game_over_panel.visible:
		return
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
	if game_over_panel.visible:
		if gesture == "swipe_up":
			_restart_both()
		return

	var world := p1 if player_id == 1 else p2
	world.on_gesture(gesture)
