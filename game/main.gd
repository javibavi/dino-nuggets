extends Node3D

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Camera3D
@onready var spawner: Node3D = $ObstacleSpawner
@onready var input_receiver: Node = $InputReceiver
@onready var score_label: Label = $UI/ScoreLabel
@onready var game_over_panel: PanelContainer = $UI/GameOverPanel
@onready var final_score_label: Label = $UI/GameOverPanel/VBoxContainer/FinalScoreLabel
@onready var ground_1: StaticBody3D = $Ground1
@onready var ground_2: StaticBody3D = $Ground2
@onready var gesture_label: Label = $UI/GestureLabel
@onready var network: Node = $Network
@onready var network_label: Label = $UI/NetworkLabel

var score := 0.0
var gesture_display_timer := 0.0
var game_speed := 15.0
var is_game_over := false
var speed_increase_rate := 0.5
var max_speed := 40.0

const GROUND_LENGTH := 200.0

## Camera offset from the player (set in _ready from initial camera position).
var camera_offset := Vector3.ZERO

func _ready() -> void:
	game_over_panel.visible = false
	spawner.player = player
	player.died.connect(_on_player_died)
	input_receiver.gesture_received.connect(_on_gesture_received)
	network.incoming_attack.connect(_on_incoming_attack)
	network.status_changed.connect(_on_network_status)
	network_label.text = "Network: offline (H=host, J=join localhost)"
	gesture_label.text = "Waiting for tracker..."
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH
	# Store the initial offset so camera tracks the player
	camera_offset = camera.global_position - player.global_position

func _process(delta: float) -> void:
	# Networking hotkeys (work even after game over)
	if Input.is_action_just_pressed("net_host"):
		network.host()
	if Input.is_action_just_pressed("net_join"):
		network.join("127.0.0.1")

	if is_game_over:
		if Input.is_action_just_pressed("restart") or Input.is_action_just_pressed("jump"):
			restart_game()
		return

	# Local shoot (keyboard fallback for the gun gesture)
	if Input.is_action_just_pressed("shoot"):
		_try_shoot()

	# Update score
	score += game_speed * delta
	score_label.text = "Score: %d" % int(score)

	# Increase speed over time
	game_speed = min(game_speed + speed_increase_rate * delta, max_speed)

	# Update spawn difficulty
	var interval = lerp(1.5, 0.6, (game_speed - 15.0) / (max_speed - 15.0))
	spawner.update_difficulty(game_speed, interval)

	# Scroll ground
	_scroll_ground(ground_1, delta)
	_scroll_ground(ground_2, delta)

	# Update obstacle speeds
	for child in spawner.get_children():
		if child.has_method("_physics_process"):
			child.speed = game_speed

	# Camera always looks at the dino's center
	camera.global_position = player.global_position + camera_offset
	camera.look_at(player.global_position + Vector3(0, 1.5, 0), Vector3.UP)

	# Gesture label timer
	if gesture_display_timer > 0:
		gesture_display_timer -= delta
		if gesture_display_timer <= 0:
			if input_receiver.is_connected_to_tracker():
				gesture_label.text = "Camera: connected"
			else:
				gesture_label.text = "Waiting for tracker..."

func _scroll_ground(ground: StaticBody3D, delta: float) -> void:
	ground.position.z += game_speed * delta
	if ground.position.z > GROUND_LENGTH:
		ground.position.z -= GROUND_LENGTH * 2.0

func _on_gesture_received(gesture: String) -> void:
	if is_game_over:
		if gesture == "swipe_up":
			restart_game()
		return

	match gesture:
		"swipe_left":
			player.move_lane(-1)
			gesture_label.text = "<< LEFT"
		"swipe_right":
			player.move_lane(1)
			gesture_label.text = "RIGHT >>"
		"swipe_up":
			player.jump()
			gesture_label.text = "JUMP ^"
		"shoot":
			_try_shoot()
			gesture_label.text = "* PEW! *"
		"ping":
			gesture_label.text = "Camera: connected"
	gesture_display_timer = 1.0

func _try_shoot() -> void:
	if is_game_over:
		return
	# Look for a bird in our current lane and ahead of us.
	var target = spawner.find_flying_in_lane(player.current_lane, player.position.z)
	if target == null:
		return
	target.shot_down()
	player.shoot()
	# Hand the bird off to the other player.
	network.send_attack(player.current_lane)

func _on_incoming_attack(_lane: int) -> void:
	if is_game_over:
		return
	# Drop a bird right in front of the LOCAL dino, regardless of which lane
	# the attacker shot from — the bird is "magically delivered" to us.
	spawner.spawn_bird_in_lane(player.current_lane, -25.0)

func _on_network_status(text: String) -> void:
	network_label.text = "Network: " + text

func _on_player_died() -> void:
	is_game_over = true
	spawner.stop()
	game_over_panel.visible = true
	final_score_label.text = "Score: %d" % int(score)

func restart_game() -> void:
	is_game_over = false
	score = 0.0
	game_speed = 15.0
	game_over_panel.visible = false
	player.is_dead = false
	player.current_lane = 0
	player.target_x = 0.0
	player.position = Vector3(0, 0.5, 0)
	player.vertical_velocity = 0.0
	player.velocity = Vector3.ZERO
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH
	spawner.reset()
