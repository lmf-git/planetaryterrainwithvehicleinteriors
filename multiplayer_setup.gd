extends Node

## Multiplayer setup and connection management
## Add this as an autoload singleton or attach to your main scene

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal server_disconnected()

const PORT = 7000
const MAX_CLIENTS = 8

var peer: ENetMultiplayerPeer
var players: Dictionary = {}  # peer_id -> player_data

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_player_connected)
	multiplayer.peer_disconnected.connect(_on_player_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

## Host a new game
func create_server() -> void:
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(PORT, MAX_CLIENTS)
	if error == OK:
		multiplayer.multiplayer_peer = peer
		print("[MULTIPLAYER] Server created on port ", PORT)
		_add_player(1)  # Add host player
	else:
		print("[MULTIPLAYER] Failed to create server: ", error)

## Join an existing game
func join_server(address: String = "127.0.0.1") -> void:
	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(address, PORT)
	if error == OK:
		multiplayer.multiplayer_peer = peer
		print("[MULTIPLAYER] Connecting to server at ", address)
	else:
		print("[MULTIPLAYER] Failed to connect: ", error)

## Stop hosting/disconnect
func stop_multiplayer() -> void:
	if peer:
		peer.close()
	multiplayer.multiplayer_peer = null
	players.clear()
	print("[MULTIPLAYER] Disconnected")

## Callbacks
func _on_player_connected(id: int) -> void:
	print("[MULTIPLAYER] Player connected: ", id)
	_add_player(id)
	player_connected.emit(id)

func _on_player_disconnected(id: int) -> void:
	print("[MULTIPLAYER] Player disconnected: ", id)
	_remove_player(id)
	player_disconnected.emit(id)

func _on_connected_to_server() -> void:
	print("[MULTIPLAYER] Successfully connected to server")
	var my_id = multiplayer.get_unique_id()
	_add_player(my_id)

func _on_connection_failed() -> void:
	print("[MULTIPLAYER] Connection to server failed")

func _on_server_disconnected() -> void:
	print("[MULTIPLAYER] Server disconnected")
	stop_multiplayer()
	server_disconnected.emit()

## Player management
func _add_player(id: int) -> void:
	players[id] = {
		"peer_id": id,
		"ready": false
	}

func _remove_player(id: int) -> void:
	players.erase(id)

func get_player_count() -> int:
	return players.size()

func is_server() -> bool:
	return multiplayer.is_server()

func get_my_id() -> int:
	return multiplayer.get_unique_id()
