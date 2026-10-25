extends Node
## Dedicated server entry.
##   godot --headless --path . res://net/server.tscn -- --port 24565 [--ws]
##   or any build with: --headless -- --server [--port N] [--ws]
## --ws serves WebSocket instead of ENet (needed for browser clients).

var _stat_t := 0.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port := Net.DEFAULT_PORT
	var i := args.find("--port")
	if i >= 0 and i + 1 < args.size():
		port = int(args[i + 1])
	if "--ws" in args:
		Net.transport = "ws"
	Engine.max_fps = D.TICK * 4 # headless otherwise spins a core
	if Net.host_dedicated(port) != OK:
		printerr(Net.last_error)
		get_tree().quit(1)
		return
	Net.lobby_changed.connect(func(l): print("Net: lobby %s" % [l]))
	print("Saltrock server listening on %s port %d" % [Net.transport, port])

func _process(delta: float) -> void:
	_stat_t += delta
	if _stat_t < 10.0 or Net.transport != "enet" or Net.sim == null:
		return
	var host: ENetConnection = (multiplayer.multiplayer_peer as ENetMultiplayerPeer).host
	var sent := host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
	var recv := host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
	print("Net: %d players, out %.1f KB/s, in %.1f KB/s, sim %s" % [Net.lobby.size(), sent / _stat_t / 1024.0, recv / _stat_t / 1024.0, Net.sim.state])
	_stat_t = 0.0
