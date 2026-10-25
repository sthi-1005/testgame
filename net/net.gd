extends Node
## Net (autoload): transport, lobby, and the authoritative server loop around Sim.
##
## The server owns the Sim and steps it at D.TICK. Each tick it sends every client the sim's events
## (reliable, private events merged in) and a snapshot (unreliable). Snapshots carry only the rows
## that changed in the last few ticks, plus a full keyframe every KEYFRAME_EVERY; the client merges
## them and re-emits a complete snapshot in Sim.snapshot() format, so views never see the delta.
## Clients send their own movement (throttled to D.TICK) and actions.
##
## Solo play, hosting (listen server) and dedicated servers all take the same path: the local
## player on a host is peer 1 and its messages are plain calls instead of RPCs.
##
## Order guarantee for views: world_received comes before any events for that world, and units in
## the world never get a separate spawn event.

signal world_received(world: Dictionary)
signal snapshot_received(snap: PackedFloat32Array)
signal events_received(events: Array)
signal party_detail_received(detail: Dictionary) # sim.party_detail() shape; cds/gcd filled only for your unit
signal you_are(unit_id: int)
signal lobby_changed(lobby: Array) # [{ peer, cls }], leader first
signal state_changed(state: String) # offline | connecting | lobby | play | disconnected | failed

const PROTOCOL := 1
const DEFAULT_PORT := 24565
const DT := 1.0 / D.TICK
const KEYFRAME_EVERY := 15 # snapshots between full keyframes (0.5 s)
const ROWS_PER_PACKET := 13 # keeps each snapshot packet under the ENet MTU
const RESEND := 3 # a changed row rides along this many extra snapshots, to cover packet loss
const DETAIL_EVERY := 3 # ticks between party detail sends (10 Hz)
const MAX_CATCHUP := 5
const CH_SNAP := 1
const CH_DETAIL := 2

var state := "offline"
var transport := "ws" if OS.has_feature("web") else "enet" # browsers can't use ENet
var dedicated := false
var stage := Stages.DEFAULT # the stage the next run uses (set by the host before start_game)
var lobby: Array = []
var my_unit := 0
var last_error := ""

# server
var sim: Sim
var _ready_peers := {} # peer -> true once it has the world
var _pending_world: Array = [] # peers that joined mid-run, sent the world after this tick's events
var _acc := 0.0
var _tick := 0
var _snap_n := 0
var _sent_rows := {} # unit id -> last row broadcast
var _changed_at := {} # unit id -> _snap_n when its row last changed
var _local_cmd := false

# client
var _cls := ""
var _rows := {} # unit id -> row (merged from snapshots)
var _gone := {} # despawned ids, so a late snapshot can't bring them back
var _move: Array = [] # [pos, yaw] waiting to send
var _move_dt := 0.0
var _move_acc := 0.0
var _sent_move: Array = []

static func is_server_launch() -> bool:
	return "--server" in OS.get_cmdline_user_args()

func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _fail("Could not reach the server."))
	multiplayer.server_disconnected.connect(func(): _set_state("disconnected"))
	multiplayer.peer_disconnected.connect(_on_peer_left)
	if is_server_launch():
		_launch_server.call_deferred()

func _launch_server() -> void:
	if get_tree().current_scene and get_tree().current_scene.scene_file_path != "res://net/server.tscn":
		get_tree().change_scene_to_file("res://net/server.tscn")

# ------------------------------------------------------------------ public API
func host_solo(cls: String) -> void:
	_reset()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_lobby_set(1, cls)
	start_game()

## Listen server: this machine hosts and plays as peer 1.
func host(cls: String, port := DEFAULT_PORT) -> Error:
	_reset()
	var err := _listen(port)
	if err == OK:
		_lobby_set(1, cls)
		_set_state("lobby")
	return err

## Dedicated server: no local player. See net/server.gd.
func host_dedicated(port := DEFAULT_PORT) -> Error:
	_reset()
	dedicated = true
	var err := _listen(port)
	if err == OK:
		_set_state("lobby")
	return err

## addr is "host" or "host:port" (ws:// or wss:// URLs work with the WebSocket transport).
func join(addr: String, cls: String) -> Error:
	_reset()
	_cls = cls
	var port := DEFAULT_PORT
	var h := addr
	var scheme := ""
	if "://" in h:
		scheme = h.get_slice("://", 0) + "://"
		h = h.get_slice("://", 1)
	if h.count(":") == 1:
		port = int(h.get_slice(":", 1))
		h = h.get_slice(":", 0)
	var err: Error
	if transport == "ws":
		var p := WebSocketMultiplayerPeer.new()
		err = p.create_client("%s%s:%d" % [scheme if scheme else "ws://", h, port])
		multiplayer.multiplayer_peer = p
	else:
		var p := ENetMultiplayerPeer.new()
		err = p.create_client(h, port)
		multiplayer.multiplayer_peer = p
	if err != OK:
		_fail("Could not start a connection (%s)." % error_string(err))
		return err
	_set_state("connecting")
	return OK

func leave() -> void:
	_reset()

func set_class(cls: String) -> void:
	_cmd("_c_class", [cls])

## The party leader (lowest peer in the lobby; the host when there is one) starts the run.
func start_game() -> void:
	_cmd("_c_start", [])

## Call every frame with the local player's position; sent at D.TICK, only when it changed.
func send_move(pos: Vector3, yaw: float, dt: float) -> void:
	_move = [pos, yaw]
	_move_dt += dt

func send_use(ab: String, target_id: int) -> void:
	_cmd("_c_use", [ab, target_id])

func send_target(id: int, attack: bool) -> void:
	_cmd("_c_target", [id, attack])

func send_loot() -> void:
	_cmd("_c_loot", [])

func is_leader() -> bool:
	return lobby.size() > 0 and lobby[0].peer == multiplayer.get_unique_id()

# ------------------------------------------------------------------ setup
func _reset() -> void:
	if multiplayer.multiplayer_peer and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	sim = null
	dedicated = false
	lobby = []
	my_unit = 0
	last_error = ""
	_ready_peers.clear()
	_pending_world.clear()
	_sent_rows.clear()
	_changed_at.clear()
	_rows.clear()
	_gone.clear()
	_move = []
	_sent_move = []
	_move_dt = 0.0
	_acc = 0.0
	_tick = 0
	_snap_n = 0
	_set_state("offline")

func _listen(port: int) -> Error:
	var err: Error
	if transport == "ws":
		var p := WebSocketMultiplayerPeer.new()
		err = p.create_server(port)
		if err == OK:
			multiplayer.multiplayer_peer = p
	else:
		var p := ENetMultiplayerPeer.new()
		err = p.create_server(port, D.MAX_PLAYERS)
		if err == OK:
			multiplayer.multiplayer_peer = p
	if err != OK:
		_fail("Could not open port %d (%s)." % [port, error_string(err)])
	return err

func _set_state(s: String) -> void:
	if s != state:
		state = s
		state_changed.emit(s)

func _fail(msg: String) -> void:
	last_error = msg
	push_warning("Net: " + msg)
	_set_state("failed")

func _sender() -> int:
	if _local_cmd:
		return multiplayer.get_unique_id()
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else multiplayer.get_unique_id()

## Client -> server: a plain call on the host, an RPC otherwise.
func _cmd(method: String, args: Array) -> void:
	if multiplayer.is_server():
		# a local call can happen inside another peer's RPC (a lobby signal), where
		# get_remote_sender_id() would still name that peer
		_local_cmd = true
		callv(method, args)
		_local_cmd = false
	elif state in ["lobby", "play"]:
		callv("rpc_id", [1, method] + args)

## Server -> one client.
func _to(peer: int, method: String, args: Array) -> void:
	if peer == multiplayer.get_unique_id():
		callv(method, args)
	else:
		callv("rpc_id", [peer, method] + args)

func _to_ready(method: String, args: Array) -> void:
	for p in _ready_peers:
		_to(p, method, args)

# ------------------------------------------------------------------ lobby (server)
func _lobby_set(peer: int, cls: String) -> void:
	if not D.CLASSES.has(cls):
		cls = D.CLASS_ORDER[0]
	for e in lobby:
		if e.peer == peer:
			e.cls = cls
			_lobby_changed()
			return
	lobby.append({ "peer": peer, "cls": cls })
	lobby.sort_custom(func(a, b): return a.peer < b.peer)
	_lobby_changed()

func _lobby_changed() -> void:
	for e in lobby:
		_to(e.peer, "_s_lobby", [lobby])
	if dedicated:
		lobby_changed.emit(lobby)

func _on_connected() -> void:
	rpc_id(1, "_c_hello", PROTOCOL, _cls)

func _on_peer_left(peer: int) -> void:
	if not multiplayer.is_server():
		return
	_ready_peers.erase(peer)
	_pending_world.erase(peer)
	for i in lobby.size():
		if lobby[i].peer == peer:
			lobby.remove_at(i)
			break
	if sim:
		sim.drop_player(peer)
		if dedicated and lobby.is_empty():
			print("Net: party empty, back to lobby")
			sim = null
			_set_state("lobby")
	_lobby_changed()

func _reject(peer: int, reason: String) -> void:
	_to(peer, "_s_reject", [reason])
	get_tree().create_timer(0.5).timeout.connect(func():
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.disconnect_peer(peer))

@rpc("any_peer", "reliable")
func _c_hello(proto: int, cls: String) -> void:
	if not multiplayer.is_server():
		return
	var peer := _sender()
	if proto != PROTOCOL:
		_reject(peer, "Version mismatch: update the game.")
		return
	if lobby.size() >= D.MAX_PLAYERS:
		_reject(peer, "The party is full.")
		return
	_lobby_set(peer, cls)
	if sim:
		sim.add_player(peer, _lobby_cls(peer))
		_pending_world.append(peer)

@rpc("any_peer", "reliable")
func _c_class(cls: String) -> void:
	if multiplayer.is_server() and sim == null and _in_lobby(_sender()):
		_lobby_set(_sender(), cls)

@rpc("any_peer", "reliable")
func _c_start() -> void:
	if not multiplayer.is_server() or sim != null or lobby.is_empty() or lobby[0].peer != _sender():
		return
	var roster: Array = []
	for e in lobby:
		roster.append([e.peer, e.cls])
	sim = Sim.new(Stages.make_level(stage))
	sim.start(roster)
	# the world below already holds every unit, so their spawn events would be duplicates
	sim.events = sim.events.filter(func(e): return e[0] != "spawn")
	for e in lobby:
		_send_world(e.peer)
	_flush_events()
	_acc = 0.0
	if dedicated:
		print("Net: run started with %d players" % lobby.size())
		_set_state("play")

func _in_lobby(peer: int) -> bool:
	return lobby.any(func(e): return e.peer == peer)

func _lobby_cls(peer: int) -> String:
	for e in lobby:
		if e.peer == peer:
			return e.cls
	return D.CLASS_ORDER[0]

func _send_world(peer: int) -> void:
	_to(peer, "_s_world", [sim.world_state()])
	var u: SUnit = sim.players.get(peer)
	_to(peer, "_s_you", [u.id if u else 0])
	_ready_peers[peer] = true
	_snap_n = -1 # next snapshot is a keyframe, so the newcomer gets every row

# ------------------------------------------------------------------ input (server)
@rpc("any_peer", "unreliable_ordered", "call_remote", CH_SNAP)
func _c_move(pos: Vector3, yaw: float, dt: float) -> void:
	if multiplayer.is_server() and sim:
		sim.player_move(_sender(), pos, yaw, clampf(dt, 0.0, 0.5))

@rpc("any_peer", "reliable")
func _c_use(ab: String, target_id: int) -> void:
	if multiplayer.is_server() and sim:
		sim.player_use(_sender(), ab, target_id)

@rpc("any_peer", "reliable")
func _c_target(id: int, attack: bool) -> void:
	if multiplayer.is_server() and sim:
		sim.player_target(_sender(), id, attack)

@rpc("any_peer", "reliable")
func _c_loot() -> void:
	if multiplayer.is_server() and sim:
		sim.player_loot(_sender())

# ------------------------------------------------------------------ tick
func _process(delta: float) -> void:
	if multiplayer.is_server() and sim:
		_acc += delta
		var n := 0
		while _acc >= DT and n < MAX_CATCHUP:
			_server_tick()
			_acc -= DT
			n += 1
		if n == MAX_CATCHUP:
			_acc = 0.0 # fell badly behind (breakpoint, hitch): drop time rather than spiral
	if state == "play" and not dedicated:
		_move_acc += delta
		if _move_acc >= DT:
			_move_acc = fmod(_move_acc, DT)
			if _move.size() and _move != _sent_move:
				_cmd("_c_move", [_move[0], _move[1], _move_dt])
				_sent_move = _move
			_move_dt = 0.0

func _server_tick() -> void:
	sim.step(DT)
	_flush_events()
	for p in _pending_world:
		_send_world(p)
	_pending_world.clear()
	_broadcast_snapshot()
	if _tick % DETAIL_EVERY == 0:
		_send_detail()
	_tick += 1

## Party detail, trimmed per client: cooldowns only for its own unit (others get empty cds), buffs
## for everyone. Cuts this message by about 80%.
func _send_detail() -> void:
	var d := sim.party_detail()
	for p in _ready_peers:
		var u: SUnit = sim.players.get(p)
		var mine := u.id if u else 0
		var out := {}
		for id in d:
			out[id] = d[id] if id == mine else { "cds": {}, "gcd": 0.0, "buffs": d[id].buffs }
		_to(p, "_s_detail", [out])

func _flush_events() -> void:
	for p in _ready_peers:
		var evs: Array = sim.events
		if sim.private_events.has(p):
			evs = evs + sim.private_events[p]
		if evs.size():
			_to(p, "_s_events", [evs])
	sim.events = []
	sim.private_events = {}

## Wire format: [time, n_rows, cart0x, cart1x, bell, in_combat, last] then n_rows rows. A tick's rows
## are split over several packets to stay under the MTU; last is 1 on the tick's final packet.
## Units leave only through reliable despawn events, so a lost packet can't remove one.
func _broadcast_snapshot() -> void:
	var full := sim.snapshot()
	var stride := Sim.SNAP_STRIDE
	_snap_n += 1
	var key := _snap_n % KEYFRAME_EVERY == 0
	var rows: Array[PackedFloat32Array] = []
	var i := 6
	while i < full.size():
		var id := int(full[i])
		var row := full.slice(i, i + stride)
		if _sent_rows.get(id) != row:
			_sent_rows[id] = row
			_changed_at[id] = _snap_n
		if key or _snap_n - int(_changed_at.get(id, -99)) <= RESEND:
			rows.append(row)
		i += stride
	var start := 0
	while true:
		var n := mini(ROWS_PER_PACKET, rows.size() - start)
		var last := start + n >= rows.size()
		var out := PackedFloat32Array([full[0], n, full[2], full[3], full[4], full[5], 1.0 if last else 0.0])
		for k in n:
			out.append_array(rows[start + k])
		_to_ready("_s_snap", [out])
		start += n
		if last:
			break

# ------------------------------------------------------------------ client side
@rpc("authority", "reliable")
func _s_lobby(l: Array) -> void:
	lobby = l
	if state == "connecting":
		_set_state("lobby")
	lobby_changed.emit(l)

@rpc("authority", "reliable")
func _s_reject(reason: String) -> void:
	_fail(reason)

@rpc("authority", "reliable")
func _s_world(w: Dictionary) -> void:
	_rows.clear()
	_gone.clear()
	_set_state("play")
	world_received.emit(w)

@rpc("authority", "reliable")
func _s_you(id: int) -> void:
	my_unit = id
	you_are.emit(id)

@rpc("authority", "reliable")
func _s_events(evs: Array) -> void:
	for e in evs:
		if e[0] == "despawn":
			_gone[e[1]] = true
			_rows.erase(e[1])
		elif e[0] == "spawn":
			_gone.erase(e[1].id)
	events_received.emit(evs)

@rpc("authority", "unreliable_ordered", "call_remote", CH_SNAP)
func _s_snap(d: PackedFloat32Array) -> void:
	if state != "play":
		return
	var stride := Sim.SNAP_STRIDE
	var i := 7
	for k in int(d[1]):
		var id := int(d[i])
		if not _gone.has(id):
			_rows[id] = d.slice(i, i + stride)
		i += stride
	if d[6] < 0.5:
		return
	var out := PackedFloat32Array([d[0], _rows.size(), d[2], d[3], d[4], d[5]])
	for row in _rows.values():
		out.append_array(row)
	snapshot_received.emit(out)

@rpc("authority", "unreliable_ordered", "call_remote", CH_DETAIL)
func _s_detail(d: Dictionary) -> void:
	party_detail_received.emit(d)
