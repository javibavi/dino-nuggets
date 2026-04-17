extends Node

signal gesture_received(gesture: String)

## Enable to auto-launch the Python hand tracker when the game starts.
@export var auto_launch_tracker := true
## Camera index to use (try 1 if 0 doesn't work).
@export var camera_index := 1
## Swipe sensitivity threshold.
@export var swipe_threshold := 0.07
## Seconds between gestures.
@export var gesture_cooldown := 0.5

var udp_server: PacketPeerUDP
var port := 6789
var connected := false
var _tracker_pid := -1

func _ready() -> void:
	udp_server = PacketPeerUDP.new()
	var err = udp_server.bind(port, "127.0.0.1")
	if err != OK:
		push_warning("InputReceiver: Failed to bind UDP on port %d (error: %d)" % [port, err])
	else:
		print("InputReceiver: Listening on UDP 127.0.0.1:%d" % port)

	if auto_launch_tracker:
		_launch_tracker()

func _launch_tracker() -> void:
	# Get the project directory and go up one level to find hand_tracker/
	var project_dir := ProjectSettings.globalize_path("res://").rstrip("/")
	var parent_dir := project_dir.get_base_dir()
	var tracker_script := parent_dir.path_join("hand_tracker/hand_tracker.py")

	if not FileAccess.file_exists(tracker_script):
		# Fallback: try without globalize
		tracker_script = project_dir + "/../hand_tracker/hand_tracker.py"
	if not FileAccess.file_exists(tracker_script):
		push_error("InputReceiver: Cannot find hand_tracker.py at: %s" % tracker_script)
		return

	print("InputReceiver: Launching hand tracker from: %s" % tracker_script)

	var args := [
		tracker_script,
		"--camera", str(camera_index),
		"--threshold", str(swipe_threshold),
		"--cooldown", str(gesture_cooldown),
		"--port", str(port),
	]

	_tracker_pid = OS.create_process("python3", args)
	if _tracker_pid > 0:
		print("InputReceiver: Hand tracker launched (PID: %d)" % _tracker_pid)
	else:
		push_warning("InputReceiver: Failed to launch hand tracker. Run it manually:")
		push_warning("  python3 hand_tracker/hand_tracker.py --camera %d" % camera_index)

func _process(_delta: float) -> void:
	if udp_server == null:
		return
	while udp_server.get_available_packet_count() > 0:
		var packet = udp_server.get_packet()
		var message = packet.get_string_from_utf8().strip_edges()
		if message != "":
			if not connected:
				connected = true
				print("InputReceiver: Hand tracker connected!")
			gesture_received.emit(message)

func is_connected_to_tracker() -> bool:
	return connected

func _exit_tree() -> void:
	if udp_server != null:
		udp_server.close()
	_kill_tracker()

func _kill_tracker() -> void:
	if _tracker_pid > 0:
		print("InputReceiver: Stopping hand tracker (PID: %d)" % _tracker_pid)
		OS.kill(_tracker_pid)
		_tracker_pid = -1
