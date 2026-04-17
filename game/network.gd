extends Node

## Lightweight ENet multiplayer for the dino runner.
## - One peer hosts (port 7777 by default), the other connects to host's IP.
## - When the local player shoots a bird, send_attack() RPCs the remote peer
##   so a bird spawns in front of THEIR dino.
## - Decoupled from the rest of the game by signals — main.gd wires it up.

signal incoming_attack(lane: int)
signal status_changed(text: String)

@export var port := 7777

var peer: ENetMultiplayerPeer = null
var mode := "offline"  # "offline" | "host" | "client"
var remote_connected := false

func _ready() -> void:
	# Allow command-line auto-config: --host, or --join=<ip>
	for arg in OS.get_cmdline_user_args():
		if arg == "--host":
			host()
		elif arg.begins_with("--join="):
			join(arg.substr("--join=".length()))

func host() -> bool:
	_teardown()
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(port, 1)
	if err != OK:
		_set_status("Host failed (%d)" % err)
		return false
	multiplayer.multiplayer_peer = peer
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	mode = "host"
	_set_status("Hosting on port %d — waiting…" % port)
	return true

func join(ip: String) -> bool:
	_teardown()
	peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(ip, port)
	if err != OK:
		_set_status("Join failed (%d)" % err)
		return false
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	mode = "client"
	_set_status("Connecting to %s:%d…" % [ip, port])
	return true

func _teardown() -> void:
	remote_connected = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	if peer != null:
		peer.close()
		peer = null
	mode = "offline"

func _on_peer_connected(_id: int) -> void:
	remote_connected = true
	_set_status("Peer connected!")

func _on_peer_disconnected(_id: int) -> void:
	remote_connected = false
	_set_status("Peer disconnected.")

func _on_connected_to_server() -> void:
	remote_connected = true
	_set_status("Connected to host!")

func _on_connection_failed() -> void:
	remote_connected = false
	_set_status("Connection failed.")

func _on_server_disconnected() -> void:
	remote_connected = false
	_set_status("Host disconnected.")

func _set_status(text: String) -> void:
	print("Network: ", text)
	status_changed.emit(text)

## Called locally when this player shoots a bird. Tells the remote peer to
## drop a bird in their face.
func send_attack(lane: int) -> void:
	if not remote_connected:
		return
	rpc("_remote_receive_attack", lane)

@rpc("any_peer", "call_remote", "reliable")
func _remote_receive_attack(lane: int) -> void:
	incoming_attack.emit(lane)
