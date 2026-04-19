extends Node3D

## Scene for tall obstacles (must dodge by lane switch).
@export var obstacle_scene: PackedScene
## Optional: separate scene for low obstacles (can jump over). If not set, uses obstacle_scene for both.
@export var low_obstacle_scene: PackedScene
## Optional: flying obstacle scene (e.g. bird). Spawns elevated and forces a lane switch.
@export var bird_scene: PackedScene
## Probability (0–1) that any spawn is a bird instead of a ground obstacle.
@export var bird_chance := 0.25
## Y position at which birds spawn.
@export var bird_height := 2.5
@export var spawn_distance := -80.0
@export var min_interval := 0.6
@export var max_interval := 2.0

var spawn_timer := 0.0
var current_interval := 1.5
var game_speed := 15.0
var is_active := true
var player: Node3D = null

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
	var is_bird = bird_scene != null and randf() < bird_chance
	var is_tall := false

	var scene_to_use: PackedScene
	var spawn_y := 0.0
	if is_bird:
		# Bird flies straight at the player — spawn in the player's current lane.
		if player and "current_lane" in player:
			lane = player.current_lane
		scene_to_use = bird_scene
		spawn_y = bird_height
	else:
		is_tall = randf() > 0.4  # 60% tall, 40% low
		if is_tall:
			scene_to_use = obstacle_scene
		else:
			scene_to_use = low_obstacle_scene if low_obstacle_scene else obstacle_scene

	var obstacle = scene_to_use.instantiate()
	obstacle.position = Vector3(lane * LANE_WIDTH, spawn_y, spawn_distance)
	obstacle.speed = game_speed

	# If using the same scene for both types and no custom model,
	# adjust the placeholder mesh/collision sizes
	if not is_bird and not is_tall and low_obstacle_scene == null:
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

## Spawn a bird directly in a given lane at a given Z (relative to spawner).
## Used for cross-player attacks coming from the opponent.
func spawn_bird_in_lane(lane: int, z_distance: float = -25.0) -> void:
	if bird_scene == null:
		return
	lane = clamp(lane, -1, 1)
	var bird = bird_scene.instantiate()
	bird.position = Vector3(lane * LANE_WIDTH, bird_height, z_distance)
	bird.speed = game_speed
	add_child(bird)

## Find the nearest flying obstacle in a given lane that is in front of the player.
## Returns null if none.
func find_flying_in_lane(lane: int, player_z: float) -> Node3D:
	var lane_x = lane * LANE_WIDTH
	var best: Node3D = null
	var best_z := -INF
	for child in get_children():
		if not (child is Node3D):
			continue
		if not ("is_flying" in child) or not child.is_flying:
			continue
		# Same lane (with tolerance) and ahead of the player
		if abs(child.position.x - lane_x) > LANE_WIDTH * 0.5:
			continue
		if child.position.z >= player_z:
			continue
		# "Closest in front" = largest z (least negative)
		if child.position.z > best_z:
			best_z = child.position.z
			best = child
	return best

func update_difficulty(speed: float, interval: float) -> void:
	game_speed = speed
	current_interval = interval

func stop() -> void:
	is_active = false

func freeze() -> void:
	is_active = false
	for child in get_children():
		if "speed" in child:
			child.speed = 0.0

func reset() -> void:
	is_active = true
	spawn_timer = current_interval
	# Remove existing obstacles
	for child in get_children():
		child.queue_free()
