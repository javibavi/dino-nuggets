extends CharacterBody3D

signal died
signal shot_bird

const LANE_WIDTH := 2.5
const LANE_SWITCH_SPEED := 12.0
const JUMP_VELOCITY := 12.0
const GRAVITY := 30.0

## Assign your player 3D model (.glb/.gltf) here in the Inspector.
@export var player_model: PackedScene
## Scale of the custom model.
@export var model_scale := Vector3(1.0, 1.0, 1.0)
## Rotation offset in degrees (Y-axis) to face the right direction.
@export var model_rotation_y := 0.0
## Vertical offset to align model with ground.
@export var model_y_offset := 0.0

var current_lane := 0  # -1 = left, 0 = center, 1 = right
var target_x := 0.0
var vertical_velocity := 0.0
var is_dead := false

var _model_instance: Node3D = null

func _ready() -> void:
	target_x = 0.0
	position.x = 0.0
	_setup_model()

func _setup_model() -> void:
	# Remove old model if any
	if _model_instance:
		_model_instance.queue_free()
		_model_instance = null

	var mesh_node: MeshInstance3D = $MeshInstance3D
	if player_model:
		# Hide the placeholder box
		mesh_node.visible = false
		# Instance the custom model
		_model_instance = player_model.instantiate()
		_model_instance.name = "CustomModel"
		_model_instance.scale = model_scale
		_model_instance.rotation_degrees.y = model_rotation_y
		_model_instance.position.y = model_y_offset
		add_child(_model_instance)
	else:
		# No model assigned — show the placeholder box
		mesh_node.visible = true

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	# Keyboard input
	if Input.is_action_just_pressed("move_left"):
		move_lane(-1)
	if Input.is_action_just_pressed("move_right"):
		move_lane(1)
	if Input.is_action_just_pressed("jump"):
		jump()

	# Smooth lane switching
	position.x = move_toward(position.x, target_x, LANE_SWITCH_SPEED * delta)

	# Gravity and vertical movement
	if not is_on_floor():
		vertical_velocity -= GRAVITY * delta
	else:
		if vertical_velocity < 0:
			vertical_velocity = 0.0

	velocity = Vector3(0, vertical_velocity, 0)
	move_and_slide()

func move_lane(direction: int) -> void:
	if is_dead:
		return
	var new_lane = clamp(current_lane + direction, -1, 1)
	if new_lane != current_lane:
		current_lane = new_lane
		target_x = current_lane * LANE_WIDTH

func jump() -> void:
	if is_dead:
		return
	if is_on_floor():
		vertical_velocity = JUMP_VELOCITY

func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()

## Try to shoot a bird in the current lane. Returns true if one was shot.
## main.gd is responsible for finding the actual target via the spawner.
func shoot() -> bool:
	if is_dead:
		return false
	shot_bird.emit()
	return true
