extends TextureRect

const FRAME_PATH := "/tmp/hand_tracker_frame.jpg"
const LOAD_INTERVAL := 0.15

var load_timer := 0.0
var has_ever_loaded := false

func _ready() -> void:
	# Start with a dark placeholder
	var img = Image.create(320, 240, false, Image.FORMAT_RGB8)
	img.fill(Color(0.15, 0.15, 0.15))
	texture = ImageTexture.create_from_image(img)
	print("CameraPreview: Watching %s" % FRAME_PATH)

func _process(delta: float) -> void:
	load_timer += delta
	if load_timer < LOAD_INTERVAL:
		return
	load_timer = 0.0

	if not FileAccess.file_exists(FRAME_PATH):
		return

	var file = FileAccess.open(FRAME_PATH, FileAccess.READ)
	if file == null:
		return

	var length = file.get_length()
	if length < 100:
		file.close()
		return

	var bytes = file.get_buffer(length)
	file.close()

	if bytes.size() < 100:
		return

	var img = Image.new()
	var err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		return

	texture = ImageTexture.create_from_image(img)
	if not has_ever_loaded:
		has_ever_loaded = true
		print("CameraPreview: First frame loaded!")
