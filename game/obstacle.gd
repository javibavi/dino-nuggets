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

var speed := 15.0
var _model_instance: Node3D = null
var _bob_base_y := 0.0
var _bob_time := 0.0

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
		for i in mi.get_surface_override_material_count():
			var mat := StandardMaterial3D.new()
			mat.albedo_color = model_color
			mi.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_color_recursive(child)

func _physics_process(delta: float) -> void:
	position.z += speed * delta
	if bob_amplitude > 0.0:
		_bob_time += delta
		position.y = _bob_base_y + sin(_bob_time * bob_frequency * TAU) * bob_amplitude
	# Remove when behind camera
	if position.z > 10.0:
		queue_free()

func _on_area_body_entered(body: Node3D) -> void:
	if body.has_method("die"):
		body.die()

## Called when this obstacle is shot down. Just despawns for now.
func shot_down() -> void:
	queue_free()
