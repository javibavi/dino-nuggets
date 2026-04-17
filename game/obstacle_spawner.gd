extends Node3D

## Scene for tall obstacles (must dodge by lane switch).
@export var obstacle_scene: PackedScene
## Optional: separate scene for low obstacles (can jump over). If not set, uses obstacle_scene for both.
@export var low_obstacle_scene: PackedScene
@export var spawn_distance := -80.0
@export var min_interval := 0.6
@export var max_interval := 2.0

var spawn_timer := 0.0
var current_interval := 1.5
var game_speed := 15.0
var is_active := true

const LANE_WIDTH := 2.5
const LANES := [-1, 0, 1]

func _ready() -> void:
	spawn_timer = current_interval

func _process(delta: float) -> void:
	if not is_active:
		return

	spawn_timer -= delta
	if spawn_timer <= 0.0:
		spawn_obstacle()
		spawn_timer = current_interval

func spawn_obstacle() -> void:
	if obstacle_scene == null:
		return

	var lane = LANES[randi() % LANES.size()]
	var is_tall = randf() > 0.4  # 60% tall, 40% low

	var scene_to_use: PackedScene
	if is_tall:
		scene_to_use = obstacle_scene
	else:
		scene_to_use = low_obstacle_scene if low_obstacle_scene else obstacle_scene

	var obstacle = scene_to_use.instantiate()
	obstacle.position = Vector3(lane * LANE_WIDTH, 0, spawn_distance)
	obstacle.speed = game_speed

	# If using the same scene for both types and no custom model,
	# adjust the placeholder mesh/collision sizes
	if not is_tall and low_obstacle_scene == null:
		var mesh: MeshInstance3D = obstacle.get_node("MeshInstance3D")
		var collision: CollisionShape3D = obstacle.get_node("CollisionShape3D")
		var area_collision: CollisionShape3D = obstacle.get_node("Area3D/CollisionShape3D")
		mesh.mesh = mesh.mesh.duplicate()
		collision.shape = collision.shape.duplicate()
		area_collision.shape = area_collision.shape.duplicate()
		mesh.mesh.size = Vector3(1.0, 0.5, 1.0)
		mesh.position.y = 0.25
		collision.shape.size = Vector3(1.0, 0.5, 1.0)
		collision.position.y = 0.25
		area_collision.shape.size = Vector3(1.2, 0.7, 1.2)
		area_collision.position.y = 0.25

	add_child(obstacle)

func update_difficulty(speed: float, interval: float) -> void:
	game_speed = speed
	current_interval = interval

func stop() -> void:
	is_active = false

func reset() -> void:
	is_active = true
	spawn_timer = current_interval
	# Remove existing obstacles
	for child in get_children():
		child.queue_free()
