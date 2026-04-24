extends CharacterBody3D

signal died
signal shot_bird
## Emitted when the asteroid actually strikes the player (game_world plays the die sound here).
signal impact
## Emitted after the full death cinematic (asteroid fall + nugget pop-in) finishes.
signal cinematic_done

const LANE_WIDTH := 2.5
const LANE_SWITCH_SPEED := 12.0
const JUMP_VELOCITY := 12.0
const GRAVITY := 30.0

const ASTEROID_FALL_TIME := 0.7
const POST_IMPACT_LINGER := 0.9

## Assign your player 3D model (.glb/.gltf) here in the Inspector.
@export var player_model: PackedScene
## Scale of the custom model.
@export var model_scale := Vector3(1.0, 1.0, 1.0)
## Rotation offset in degrees (Y-axis) to face the right direction.
@export var model_rotation_y := 0.0
## Vertical offset to align model with ground.
@export var model_y_offset := 0.0
## Plate model shown at the ending under the floating nuggets.
@export var plate_model: PackedScene
## Scale of the plate model. Tune so the plate fits the dino's footprint.
@export var plate_scale := Vector3(2.5, 2.5, 2.5)
## Plate albedo color (applied as a material override so it stands out against the ground).
@export var plate_color := Color(0.55, 0.55, 0.6)
## Dino nuggets model that floats above the plate in the ending cinematic.
@export var nuggets_model: PackedScene
## Scale of the nuggets model.
@export var nuggets_scale := Vector3(0.8, 0.8, 0.8)
## Nuggets rotation in degrees — upright on the plate with a 45° yaw.
@export var nuggets_rotation := Vector3(0, 45, 0)
## Nuggets albedo color — darkened yellow so they read as fried chicken nuggets.
@export var nuggets_color := Color(0.65, 0.5, 0.1)
## Prefix for input actions ("p1" or "p2" in split-screen mode).
## Falls back to legacy single-player actions (move_left, move_right, jump)
## when no prefixed action exists.
@export var input_prefix := "p1"

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

	# Keyboard input — use the per-player prefix.
	if Input.is_action_just_pressed(input_prefix + "_left"):
		move_lane(-1)
	if Input.is_action_just_pressed(input_prefix + "_right"):
		move_lane(1)
	if Input.is_action_just_pressed(input_prefix + "_jump"):
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
		$jump.play()

func die() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_play_death_cinematic()

func _play_death_cinematic() -> void:
	var world := get_parent()
	if world == null:
		cinematic_done.emit()
		return
	var asteroid := _make_asteroid()
	world.add_child(asteroid)
	var impact_pos := global_position
	asteroid.global_position = impact_pos + Vector3(8, 18, -4)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(asteroid, "global_position", impact_pos + Vector3(0, 0.3, 0), ASTEROID_FALL_TIME) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(asteroid, "rotation", Vector3(TAU * 2, TAU * 3, TAU * 2), ASTEROID_FALL_TIME)
	await tween.finished
	# If the player was restarted mid-fall, bail and let reset_visuals clean up.
	if not is_inside_tree() or not is_dead:
		if is_instance_valid(asteroid):
			asteroid.queue_free()
		return
	impact.emit()
	asteroid.queue_free()
	_spawn_flash(impact_pos)
	_hide_dino()
	_spawn_nugget()
	await get_tree().create_timer(POST_IMPACT_LINGER).timeout
	if not is_inside_tree() or not is_dead:
		return
	cinematic_done.emit()

func _make_asteroid() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Asteroid"
	var mesh := SphereMesh.new()
	mesh.radius = 0.9
	mesh.height = 1.8
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.18, 0.12)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.45, 0.1)
	mat.emission_energy_multiplier = 2.0
	mi.material_override = mat
	return mi

func _spawn_flash(at_pos: Vector3) -> void:
	var world := get_parent()
	if world == null:
		return
	var flash := MeshInstance3D.new()
	flash.name = "ImpactFlash"
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	flash.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.6, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.4)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash.material_override = mat
	world.add_child(flash)
	flash.global_position = at_pos + Vector3(0, 0.5, 0)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(flash, "scale", Vector3(5, 5, 5), 0.4)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.4)
	tween.tween_property(mat, "emission_energy_multiplier", 0.0, 0.4)
	tween.chain().tween_callback(flash.queue_free)

func _hide_dino() -> void:
	if _model_instance:
		_model_instance.visible = false
	var placeholder: MeshInstance3D = $MeshInstance3D
	placeholder.visible = false

func _spawn_nugget() -> void:
	_spawn_plate()
	_spawn_floating_nuggets()

func _spawn_plate() -> void:
	if plate_model == null:
		return
	var plate: Node3D = plate_model.instantiate()
	plate.name = "Plate"
	# Hover the plate up at about the dino's waist so the whole display
	# reads above the ground clutter.
	plate.position = Vector3(0, 0.1, 0)
	plate.scale = Vector3.ZERO
	_apply_albedo_recursive(plate, plate_color)
	add_child(plate)
	# Pop the plate in with a small bounce.
	var tween := create_tween()
	tween.tween_property(plate, "scale", plate_scale, 0.3) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

func _spawn_floating_nuggets() -> void:
	var nuggets: Node3D
	if nuggets_model:
		nuggets = nuggets_model.instantiate()
		# The nuggets .blend ships with a flat backing plane (Cube with zero
		# thickness on one axis) — strip it before it becomes a floating wall.
		_strip_flat_meshes(nuggets)
	elif player_model:
		# Fallback: scaled-down dino model if no nuggets model is assigned.
		nuggets = player_model.instantiate()
	else:
		return
	# A pivot wrapper handles the bob + turntable spin so those always act
	# on world Y regardless of the orientation the user dials in.
	nuggets.rotation_degrees = nuggets_rotation
	_apply_albedo_recursive(nuggets, nuggets_color)
	var final_scale: Vector3 = nuggets_scale if nuggets_model else (model_scale * 0.35)
	nuggets.scale = Vector3.ZERO
	var pivot := Node3D.new()
	pivot.name = "Nuggets"
	# Sit well above the lifted plate.
	var hover_y := 0.9
	pivot.position = Vector3(0, hover_y, 0)
	pivot.add_child(nuggets)
	add_child(pivot)
	# Pop-in scale.
	var pop_tween := create_tween()
	pop_tween.tween_property(nuggets, "scale", final_scale, 0.3) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	# Endless gentle bob (on the pivot so tilt doesn't skew the axis).
	var bob_tween := create_tween().set_loops()
	bob_tween.tween_property(pivot, "position:y", hover_y + 0.15, 0.9) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	bob_tween.tween_property(pivot, "position:y", hover_y, 0.9) \
		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	# Turntable spin around the world-Y axis.
	var spin_tween := create_tween().set_loops()
	spin_tween.tween_property(pivot, "rotation:y", TAU, 6.0)

func _strip_flat_meshes(node: Node) -> void:
	# Walks the tree and frees any MeshInstance3D whose mesh collapses on an
	# axis — that's a plane, which we don't want showing up behind the nuggets.
	var to_free: Array[Node] = []
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh:
				var size: Vector3 = mi.mesh.get_aabb().size
				if size.x < 0.01 or size.y < 0.01 or size.z < 0.01:
					to_free.append(child)
					continue
		_strip_flat_meshes(child)
	for n in to_free:
		n.queue_free()

func _apply_albedo_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var count: int = mi.get_surface_override_material_count()
		if count == 0 and mi.mesh != null:
			count = mi.mesh.get_surface_count()
		for i in count:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color
			mi.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_albedo_recursive(child, color)

## Called by game_world.reset() to clear cinematic leftovers and restore the dino.
func reset_visuals() -> void:
	for node_name in ["Nugget", "Plate", "Nuggets"]:
		var n := get_node_or_null(node_name)
		if n:
			n.queue_free()
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child.name == "Asteroid" or child.name == "ImpactFlash":
				child.queue_free()
	_setup_model()

## Try to shoot a bird in the current lane. Returns true if one was shot.
## main.gd is responsible for finding the actual target via the spawner.
func shoot() -> bool:
	if is_dead:
		return false
	shot_bird.emit()
	return true
