extends Node3D

## A single self-contained dino-runner world (player + spawner + ground +
## camera). Multiple instances of this scene are placed inside SubViewports
## by main.tscn to make a split-screen game.

signal died(player_id: int)
signal score_changed(player_id: int, score: int)
signal shot_fired(player_id: int)

## 1 or 2. Selects which input actions the player listens to (p1_* / p2_*).
@export var player_id := 1

@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Camera3D
@onready var spawner: Node3D = $ObstacleSpawner
@onready var ground_1: StaticBody3D = $Ground1
@onready var ground_2: StaticBody3D = $Ground2

@onready var jump_sound: AudioStreamPlayer = $Player/jump
@onready var die_sound: AudioStreamPlayer = $Player/die
@onready var point_sound: AudioStreamPlayer = $Player/point

var score := 0.0
var game_speed := 15.0
var is_game_over := false
const SPEED_INCREASE_RATE := 0.5
const MAX_SPEED := 40.0
const GROUND_LENGTH := 200.0

var camera_offset := Vector3.ZERO

func _ready() -> void:
	# Tell the player which key bindings to use.
	player.input_prefix = "p%d" % player_id
	# Wire spawner ↔ player.
	spawner.player = player
	player.died.connect(func(): _on_player_died())
	# Save initial camera offset so it tracks the player.
	camera_offset = camera.global_position - player.global_position
	# Reset positions
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH

func _process(delta: float) -> void:
	if is_game_over:
		return

	score += game_speed * delta
	score_changed.emit(player_id, int(score))
	if int(score) % 100 == 0 and int(score) > 0:
		point_sound.play()

	game_speed = min(game_speed + SPEED_INCREASE_RATE * delta, MAX_SPEED)
	var interval = lerp(1.5, 0.6, (game_speed - 15.0) / (MAX_SPEED - 15.0))
	spawner.update_difficulty(game_speed, interval)

	_scroll_ground(ground_1, delta)
	_scroll_ground(ground_2, delta)

	for child in spawner.get_children():
		if child is Node3D and "speed" in child:
			child.speed = game_speed

	camera.global_position = player.global_position + camera_offset
	camera.look_at(player.global_position + Vector3(0, 1.5, 0), Vector3.UP)

	# Local shoot: keyboard fallback for the gun gesture.
	if Input.is_action_just_pressed("p%d_shoot" % player_id):
		try_shoot()

func _scroll_ground(ground: StaticBody3D, delta: float) -> void:
	ground.position.z += game_speed * delta
	if ground.position.z > GROUND_LENGTH:
		ground.position.z -= GROUND_LENGTH * 2.0

## Returns true if a bird was actually shot (the caller can then transfer
## that bird to the OTHER player's world).
func try_shoot() -> bool:
	if is_game_over:
		return false
	var target = spawner.find_flying_in_lane(player.current_lane, player.position.z)
	if target == null:
		return false
	target.shot_down()
	player.shoot()
	shot_fired.emit(player_id)
	return true

## Spawn a bird right in front of THIS player (called when the OTHER player
## shoots and forwards the bird).
func receive_attack() -> void:
	if is_game_over:
		return
	spawner.spawn_bird_in_lane(player.current_lane, -25.0)

## Handle a gesture from this player's hand tracker.
func on_gesture(gesture: String) -> void:
	if is_game_over and gesture == "swipe_up":
		# main.gd handles cross-player restart; ignore here
		return
	match gesture:
		"swipe_left":
			player.move_lane(-1)
		"swipe_right":
			player.move_lane(1)
		"swipe_up":
			player.jump()
			jump_sound.play()
		"shoot":
			try_shoot()

func _on_player_died() -> void:
	is_game_over = true
	spawner.stop()
	died.emit(player_id)
	die_sound.play()

func reset() -> void:
	is_game_over = false
	score = 0.0
	game_speed = 15.0
	player.is_dead = false
	player.current_lane = 0
	player.target_x = 0.0
	player.position = Vector3(0, 0.5, 0)
	player.vertical_velocity = 0.0
	player.velocity = Vector3.ZERO
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH
	spawner.reset()
