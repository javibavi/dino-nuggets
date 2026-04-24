extends StaticBody3D

## Assign a custom 3D model (.glb/.gltf) for this obstacle in the Inspector.
@export var obstacle_model: PackedScene
## Scale applied to the custom model.
@export var model_scale := Vector3(1, 1, 1)
## Y-offset for the custom model (adjust if it floats or clips the ground).
@export var model_y_offset := 0.0
## Rotation offset in degrees (X, Y, Z).
@export var model_rotation := Vector3(0, 90, 0)
## Color override for the model. Black = (0,0,0,1).
@export var model_color := Color(0, 0, 0, 1)
## Whether to apply model_color to the model.
@export var apply_color := true
## Vertical bobbing amplitude (0 = disabled). Useful for flying obstacles like birds.
@export var bob_amplitude := 0.0
## Vertical bobbing frequency in Hz.
@export var bob_frequency := 2.0
## True for flying obstacles (birds) — eligible to be shot down.
@export var is_flying := false
## True when this obstacle was sent by the OTHER player. Pulses red so the
## receiving player can clearly see "this one came from your opponent".
@export var attack_glow := false

var speed := 15.0
var _model_instance: Node3D = null
var _bob_base_y := 0.0
var _bob_time := 0.0
var _glow_materials: Array[StandardMaterial3D] = []
var _flash_materials: Array[StandardMaterial3D] = []
var _is_shot := false
var _shot_timer := 0.0

const FLASH_DURATION := 0.15
const FLASH_RATE := 20.0

func _ready() -> void:
	_setup_model()
	_bob_base_y = position.y

func _setup_model() -> void:
	var mesh_node: MeshInstance3D = $MeshInstance3D
	if obstacle_model:
		mesh_node.visible = false
		_model_instance = obstacle_model.instantiate()
		_model_instance.name = "CustomModel"
		_model_instance.scale = model_scale
		_model_instance.position.y = model_y_offset
		_model_instance.rotation_degrees = model_rotation
		add_child(_model_instance)
		if apply_color:
			_apply_color_recursive(_model_instance)
	else:
		mesh_node.visible = true

func _apply_color_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		# get_surface_override_material_count() can be 0 on glTF imports —
		# fall back to the mesh's surface count so the override actually applies.
		var count: int = mi.get_surface_override_material_count()
		if count == 0 and mi.mesh != null:
			count = mi.mesh.get_surface_count()
		for i in count:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = model_color
			if attack_glow:
				mat.emission_enabled = true
				mat.emission = model_color
				mat.emission_energy_multiplier = 1.2
			mi.set_surface_override_material(i, mat)
			_flash_materials.append(mat)
			if attack_glow:
				_glow_materials.append(mat)
	for child in node.get_children():
		_apply_color_recursive(child)

func _physics_process(delta: float) -> void:
	if _is_shot:
		_shot_timer += delta
		var is_white: bool = int(_shot_timer * FLASH_RATE) % 2 == 0
		var flash_color: Color = Color.WHITE if is_white else Color.RED
		for mat in _flash_materials:
			mat.albedo_color = flash_color
			if mat.emission_enabled:
				mat.emission = flash_color
				mat.emission_energy_multiplier = 2.5
		if _shot_timer >= FLASH_DURATION:
			queue_free()
		return

	position.z += speed * delta
	_bob_time += delta
	if bob_amplitude > 0.0:
		position.y = _bob_base_y + sin(_bob_time * bob_frequency * TAU) * bob_amplitude
	# Pulse the emission so attack birds throb between dim and bright.
	if attack_glow and not _glow_materials.is_empty():
		var pulse: float = 1.0 + 1.5 * (0.5 + 0.5 * sin(_bob_time * 6.0))
		for mat in _glow_materials:
			mat.emission_energy_multiplier = pulse
	# Remove when behind camera
	if position.z > 10.0:
		queue_free()

func _on_area_body_entered(body: Node3D) -> void:
	if body.has_method("die"):
		body.die()

## Called when this obstacle is shot down. Flashes red/white briefly, then despawns.
func shot_down() -> void:
	if _is_shot:
		return
	_is_shot = true
	_shot_timer = 0.0
	var area: Area3D = get_node_or_null("Area3D")
	if area:
		area.monitoring = false
	if _flash_materials.is_empty():
		queue_free()
