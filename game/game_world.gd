extends Node3D

## A single self-contained dino-runner world (player + spawner + ground +
## camera). Multiple instances of this scene are placed inside SubViewports
## by main.tscn to make a split-screen game.

signal died(player_id: int)
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
const MAX_SPEED := 120.0
const GROUND_LENGTH := 200.0

var camera_offset := Vector3.ZERO

func _ready() -> void:
	# Tell the player which key bindings to use.
	player.input_prefix = "p%d" % player_id
	# Wire spawner ↔ player.
	spawner.player = player
	player.died.connect(func(): _on_player_died())
	player.impact.connect(func(): die_sound.play())
	# Save initial camera offset so it tracks the player.
	camera_offset = camera.global_position - player.global_position
	# Reset positions
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH
	
func _format_time(t: float) -> String:
	var m := int(t) / 60
	var s := int(t) % 60
	return "%d:%02d" % [m, s]

func _process(delta: float) -> void:
	if is_game_over:
		return


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
	# Muzzle burst fires on every attempt so misses still feel like "a shot".
	_spawn_shoot_particles()
	var target = spawner.find_flying_in_lane(player.current_lane, player.position.z)
	if target == null:
		return false
	target.shot_down()
	player.shoot()
	point_sound.play()
	shot_fired.emit(player_id)
	return true

func _spawn_shoot_particles() -> void:
	var particles := CPUParticles3D.new()
	particles.name = "ShootBurst"
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.amount = 24
	particles.lifetime = 0.35
	# Shoot forward toward where the birds come from (-Z in this world).
	particles.direction = Vector3(0, 0.2, -1)
	particles.spread = 22.0
	particles.initial_velocity_min = 6.0
	particles.initial_velocity_max = 11.0
	particles.gravity = Vector3.ZERO
	particles.scale_amount_min = 0.08
	particles.scale_amount_max = 0.16
	particles.color = Color(1.0, 0.85, 0.3)
	particles.color_ramp = _shoot_color_ramp()
	add_child(particles)
	particles.global_position = player.global_position + Vector3(0, 1.0, -0.4)
	# Clean up once the burst has played out (timer is a safety net).
	get_tree().create_timer(particles.lifetime + 0.3).timeout.connect(particles.queue_free)

func _shoot_color_ramp() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([
		Color(1.0, 0.95, 0.7, 1.0),
		Color(1.0, 0.7, 0.2, 0.8),
		Color(1.0, 0.4, 0.1, 0.0),
	])
	return g

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
	# die_sound now plays on impact (see player.impact connection in _ready).

func reset() -> void:
	is_game_over = false
	game_speed = 15.0
	player.is_dead = false
	player.current_lane = 0
	player.target_x = 0.0
	player.position = Vector3(0, 0.5, 0)
	player.vertical_velocity = 0.0
	player.velocity = Vector3.ZERO
	player.reset_visuals()
	ground_1.position.z = 0.0
	ground_2.position.z = -GROUND_LENGTH
	spawner.reset()
