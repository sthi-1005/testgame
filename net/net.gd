extends Node
## Net (autoload): transport, rooms and lobby, and the authoritative server loop around Sim.
##
## The server owns a Sim per room and steps it at D.TICK. Each tick it sends every client in the room
## the sim's events (reliable, private events merged in) and a snapshot (unreliable). Snapshots carry
## only the rows that changed in the last few ticks, plus a full keyframe every KEYFRAME_EVERY; the
## client merges them and re-emits a complete snapshot in Sim.snapshot() format, so views never see
## the delta. Clients send their own movement (throttled to D.TICK) and actions.
##
## Rooms: a dedicated server hosts many parties at once, each behind a 4-letter code. create_room()
## asks the server for a fresh code, join_room() joins one, and invite_link() is the URL to send to
## friends (the web build reads ?room= on start). Nobody ever sees an IP. A listen server (host())
## runs one room with an empty code, for LAN play.
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
signal room_joined(code: String) # the room code is known (Net.room_code), so invite_link() works

const PROTOCOL := 3 # 3: rooms (_c_hello carries a room request)
const DEFAULT_PORT := 24565
## The public game server that create_room()/join_room() use: a wss:// URL once one is hosted. Empty
## means online rooms are off; ?server= in the page URL or --server-url on the command line overrides it.
const DEFAULT_SERVER := ""
## Where the web build lives; invite links point here.
const WEB_URL := "https://sthi-1005.github.io/testgame/"
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ" # no I or O, so codes read cleanly aloud
const CODE_LEN := 4
const MAX_ROOMS := 64
const DT := 1.0 / D.TICK
const KEYFRAME_EVERY := 15 # snapshots between full keyframes (0.5 s)
const ROWS_PER_PACKET := 13 # keeps each snapshot packet under the ENet MTU
const RESEND := 3 # a changed row rides along this many extra snapshots, to cover packet loss
const DETAIL_EVERY := 3 # ticks between party detail sends (10 Hz)
const MAX_CATCHUP := 5
const CH_SNAP := 1
const CH_DETAIL := 2

## One party on the server.
class Room:
	var code := ""
	var stage := Stages.DEFAULT
	var lobby: Array = [] # [{ peer, cls }], sorted by peer; lobby[0] is the leader
	var sim: Sim
	var ready_peers := {} # peer -> true once it has the world
	var pending_world: Array = [] # peers that joined mid-run, sent the world after this tick's events
	var snap_n := 0
	var tick := 0
	var sent_rows := {} # unit id -> last row broadcast
	var changed_at := {} # unit id -> snap_n when its row last changed

var state := "offline"
var transport := "ws" if OS.has_feature("web") else "enet" # browsers can't use ENet
var dedicated := false
var stage := Stages.DEFAULT # the stage the next run uses (set by the host before start_game / create_room)
var lobby: Array = []
var my_unit := 0
var room_code := "" # the room this client is in ("" on a LAN host)
var server_url := "" # the server this client connected to through create_room / join_room
var last_error := ""

# server
var rooms := {} # code -> Room
var _peer_room := {} # peer -> code
var _acc := 0.0
var _local_cmd := false

# client
var _cls := ""
var _want := {} # the room request sent in hello: { code, create, stage }
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

# ------------------------------------------------------------------ invites
## The online server to use: ?server= (web) or --server-url (native), else DEFAULT_SERVER.
static func online_server() -> String:
	var s: String = launch_params().get("server", "")
	return s if s != "" else DEFAULT_SERVER

## A room code from the page URL (?room=ABCD) or --room on the command line, normalised, or "".
static func launch_room() -> String:
	return normalize_code(launch_params().get("room", ""))

static func normalize_code(s: String) -> String:
	s = s.strip_edges().to_upper()
	if s.length() != CODE_LEN:
		return ""
	for ch in s:
		if not ch in CODE_CHARS:
			return ""
	return s

## { room, server } from the page URL on web, or from --room / --server-url on native.
static func launch_params() -> Dictionary:
	var out := {}
	if OS.has_feature("web"):
		var q = JavaScriptBridge.eval("window.location.search", true)
		if q is String:
			var qs: String = q
			for part in qs.trim_prefix("?").split("&", false):
				var kv := part.split("=", true, 1)
				if kv.size() == 2:
					out[kv[0]] = kv[1].uri_decode()
	var a := OS.get_cmdline_user_args()
	var i := a.find("--room")
	if i >= 0 and i + 1 < a.size():
		out.room = a[i + 1]
	i = a.find("--server-url")
	if i >= 0 and i + 1 < a.size():
		out.server = a[i + 1]
	return out

## The link to send friends for the current room. It only names the server when it isn't the default.
func invite_link() -> String:
	if room_code == "":
		return ""
	var url := "%s?room=%s" % [WEB_URL, room_code]
	if server_url != "" and server_url != DEFAULT_SERVER:
		url += "&server=" + server_url.uri_encode()
	return url

## Copy the invite to the clipboard; on phones, open the system share sheet when the browser has one.
## Returns true when the share sheet opened.
func share_invite() -> bool:
	var link := invite_link()
	if link == "":
		return false
	var text := "Join my Saltrock Mines party: %s (room %s)" % [link, room_code]
	DisplayServer.clipboard_set(link)
	if OS.has_feature("web"):
		var ok = JavaScriptBridge.eval("(function(){ if (navigator.share) { navigator.share({ title: 'Saltrock Mines', text: %s, url: %s }).catch(function(){}); return true } return false })()" % [JSON.stringify(text), JSON.stringify(link)], true)
		return ok == true
	return false

# ------------------------------------------------------------------ public API
func host_solo(cls: String) -> void:
	_reset()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var r := _room_new("")
	r.stage = stage
	_join_room_srv(r, 1, cls)
	start_game()

## Listen server: this machine hosts one room (code "") and plays as peer 1. For LAN play.
func host(cls: String, port := DEFAULT_PORT) -> Error:
	_reset()
	var err := _listen(port)
	if err == OK:
		var r := _room_new("")
		r.stage = stage
		_join_room_srv(r, 1, cls)
		_set_state("lobby")
	return err

## Dedicated server: no local player, any number of rooms. See net/server.gd.
func host_dedicated(port := DEFAULT_PORT) -> Error:
	_reset()
	dedicated = true
	var err := _listen(port)
	if err == OK:
		_set_state("lobby")
	return err

## Start a new party on the online server (or `server`). room_joined fires with the code.
## `want_code` asks for a specific code (tests); the server picks another if it's taken.
func create_room(cls: String, server := "", want_code := "") -> Error:
	return _connect(server if server != "" else online_server(), cls, { "code": normalize_code(want_code), "create": true, "stage": stage })

## Join a party by its code on the online server (or `server`).
func join_room(code: String, cls: String, server := "") -> Error:
	code = normalize_code(code)
	if code == "":
		_fail("Room codes are %d letters." % CODE_LEN)
		return ERR_INVALID_PARAMETER
	return _connect(server if server != "" else online_server(), cls, { "code": code, "create": false })

## Join a LAN host or a server's default room by address: "host", "host:port", or a ws:// / wss:// URL.
func join(addr: String, cls: String) -> Error:
	return _connect(addr, cls, { "code": "", "create": false })

func leave() -> void:
	_reset()

func set_class(cls: String) -> void:
	_cmd("_c_class", [cls])

## The party leader (lowest peer in the room; the host when there is one) starts the run.
func start_game() -> void:
	_cmd("_c_start", [])

## Call every frame with the local player's position; sent at D.TICK, only when it changed.
func send_move(pos: Vector3, yaw: float, dt: float) -> void:
	_move = [pos, yaw]
	_move_dt += dt

func send_use(ab: String, target_id: int) -> void:
	_cmd("_c_use", [ab, target_id])

func send_act(kind: String, yaw: float, target_id: int) -> void:
	_cmd("_c_act", [kind, yaw, target_id])

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
	rooms.clear()
	_peer_room.clear()
	dedicated = false
	lobby = []
	my_unit = 0
	room_code = ""
	server_url = ""
	last_error = ""
	_want = {}
	_rows.clear()
	_gone.clear()
	_move = []
	_sent_move = []
	_move_dt = 0.0
	_acc = 0.0
	_set_state("offline")

func _connect(addr: String, cls: String, want: Dictionary) -> Error:
	_reset()
	_cls = cls
	_want = want
	if addr == "":
		_fail("No online server is set up yet.")
		return ERR_UNCONFIGURED
	var scheme := ""
	var h := addr
	if "://" in h:
		scheme = h.get_slice("://", 0) + "://"
		h = h.get_slice("://", 1).trim_suffix("/")
	var use_ws := scheme != "" or transport == "ws"
	var err: Error
	if use_ws:
		# a URL keeps its own port (wss:// behind a proxy is usually 443); a bare host gets ours
		var url := addr.trim_suffix("/") if scheme != "" else "ws://%s" % (h if ":" in h else "%s:%d" % [h, DEFAULT_PORT])
		var p := WebSocketMultiplayerPeer.new()
		err = p.create_client(url)
		multiplayer.multiplayer_peer = p
	else:
		var port := DEFAULT_PORT
		if h.count(":") == 1:
			port = int(h.get_slice(":", 1))
			h = h.get_slice(":", 0)
		var p := ENetMultiplayerPeer.new()
		err = p.create_client(h, port)
		multiplayer.multiplayer_peer = p
	if err != OK:
		_fail("Could not start a connection (%s)." % error_string(err))
		return err
	server_url = addr
	_set_state("connecting")
	return OK

func _listen(port: int) -> Error:
	var err: Error
	if transport == "ws":
		var p := WebSocketMultiplayerPeer.new()
		err = p.create_server(port)
		if err == OK:
			multiplayer.multiplayer_peer = p
	else:
		var p := ENetMultiplayerPeer.new()
		err = p.create_server(port, MAX_ROOMS * D.MAX_PLAYERS)
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

## The room the sending peer is in, or null.
func _room() -> Room:
	return rooms.get(_peer_room.get(_sender(), null))

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

func _to_ready(r: Room, method: String, args: Array) -> void:
	for p in r.ready_peers:
		_to(p, method, args)

# ------------------------------------------------------------------ rooms and lobby (server)
func _room_new(code: String) -> Room:
	var r := Room.new()
	r.code = code
	rooms[code] = r
	return r

func _fresh_code(want: String) -> String:
	if want != "" and not rooms.has(want):
		return want
	for attempt in 50:
		var c := ""
		for k in CODE_LEN:
			c += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not rooms.has(c):
			return c
	return ""

func _join_room_srv(r: Room, peer: int, cls: String) -> void:
	_peer_room[peer] = r.code
	_to(peer, "_s_room", [r.code])
	_lobby_set(r, peer, cls)

func _lobby_set(r: Room, peer: int, cls: String) -> void:
	if not D.CLASSES.has(cls):
		cls = D.CLASS_ORDER[0]
	for e in r.lobby:
		if e.peer == peer:
			e.cls = cls
			_lobby_changed(r)
			return
	r.lobby.append({ "peer": peer, "cls": cls })
	r.lobby.sort_custom(func(a, b): return a.peer < b.peer)
	_lobby_changed(r)

func _lobby_changed(r: Room) -> void:
	for e in r.lobby:
		_to(e.peer, "_s_lobby", [r.lobby])
	if dedicated:
		lobby_changed.emit(r.lobby)

func _on_connected() -> void:
	rpc_id(1, "_c_hello", PROTOCOL, _cls, _want)

func _on_peer_left(peer: int) -> void:
	if not multiplayer.is_server():
		return
	var r: Room = rooms.get(_peer_room.get(peer, null))
	_peer_room.erase(peer)
	if r == null:
		return
	r.ready_peers.erase(peer)
	r.pending_world.erase(peer)
	for i in r.lobby.size():
		if r.lobby[i].peer == peer:
			r.lobby.remove_at(i)
			break
	if r.sim:
		r.sim.drop_player(peer)
	if dedicated and r.lobby.is_empty():
		print("Net: room %s empty, closed" % r.code)
		rooms.erase(r.code)
		return
	_lobby_changed(r)

func _reject(peer: int, reason: String) -> void:
	_to(peer, "_s_reject", [reason])
	get_tree().create_timer(0.5).timeout.connect(func():
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.disconnect_peer(peer))

@rpc("any_peer", "reliable")
func _c_hello(proto: int, cls: String, want: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var peer := _sender()
	if proto != PROTOCOL:
		_reject(peer, "Version mismatch: update the game.")
		return
	var code: String = normalize_code(str(want.get("code", "")))
	var r: Room
	if want.get("create", false) and dedicated:
		if rooms.size() >= MAX_ROOMS:
			_reject(peer, "The server is full. Try again in a bit.")
			return
		code = _fresh_code(code)
		r = _room_new(code)
		var st: String = str(want.get("stage", Stages.DEFAULT))
		r.stage = st if Stages.has(st) else Stages.DEFAULT
		print("Net: room %s opened (%s)" % [code, r.stage])
	else:
		r = rooms.get(code)
		if r == null and code == "" and dedicated:
			r = _room_new("") # a dedicated server's default room, for joins by address
			r.stage = stage
		if r == null:
			_reject(peer, "No party with code %s. Check the code, or ask for a new link." % code if code != "" else "That host isn't running a party.")
			return
	if r.lobby.size() >= D.MAX_PLAYERS:
		_reject(peer, "The party is full.")
		return
	_join_room_srv(r, peer, cls)
	if r.sim:
		r.sim.add_player(peer, _lobby_cls(r, peer))
		r.pending_world.append(peer)

@rpc("any_peer", "reliable")
func _c_class(cls: String) -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim == null:
		_lobby_set(r, _sender(), cls)

@rpc("any_peer", "reliable")
func _c_start() -> void:
	var r := _room()
	if not multiplayer.is_server() or r == null or r.sim != null or r.lobby.is_empty() or r.lobby[0].peer != _sender():
		return
	var roster: Array = []
	for e in r.lobby:
		roster.append([e.peer, e.cls])
	r.sim = Sim.new(Stages.make_level(r.stage))
	r.sim.start(roster)
	# the world below already holds every unit, so their spawn events would be duplicates
	r.sim.events = r.sim.events.filter(func(e): return e[0] != "spawn")
	for e in r.lobby:
		_send_world(r, e.peer)
	_flush_events(r)
	if dedicated:
		print("Net: room %s started with %d players" % [r.code, r.lobby.size()])

func _lobby_cls(r: Room, peer: int) -> String:
	for e in r.lobby:
		if e.peer == peer:
			return e.cls
	return D.CLASS_ORDER[0]

func _send_world(r: Room, peer: int) -> void:
	_to(peer, "_s_world", [r.sim.world_state()])
	var u: SUnit = r.sim.players.get(peer)
	_to(peer, "_s_you", [u.id if u else 0])
	r.ready_peers[peer] = true
	r.snap_n = -1 # next snapshot is a keyframe, so the newcomer gets every row

# ------------------------------------------------------------------ input (server)
@rpc("any_peer", "unreliable_ordered", "call_remote", CH_SNAP)
func _c_move(pos: Vector3, yaw: float, dt: float) -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim:
		r.sim.player_move(_sender(), pos, yaw, clampf(dt, 0.0, 0.5))

@rpc("any_peer", "reliable")
func _c_use(ab: String, target_id: int) -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim:
		r.sim.player_use(_sender(), ab, target_id)

@rpc("any_peer", "reliable")
func _c_act(kind: String, yaw: float, target_id: int) -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim:
		r.sim.player_act(_sender(), kind, yaw, target_id)

@rpc("any_peer", "reliable")
func _c_target(id: int, attack: bool) -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim:
		r.sim.player_target(_sender(), id, attack)

@rpc("any_peer", "reliable")
func _c_loot() -> void:
	var r := _room()
	if multiplayer.is_server() and r and r.sim:
		r.sim.player_loot(_sender())

# ------------------------------------------------------------------ tick
func _process(delta: float) -> void:
	if multiplayer.is_server() and rooms.size():
		_acc += delta
		var n := 0
		while _acc >= DT and n < MAX_CATCHUP:
			for r in rooms.values():
				if r.sim:
					_server_tick(r)
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

func _server_tick(r: Room) -> void:
	r.sim.step(DT)
	_flush_events(r)
	for p in r.pending_world:
		_send_world(r, p)
	r.pending_world.clear()
	_broadcast_snapshot(r)
	if r.tick % DETAIL_EVERY == 0:
		_send_detail(r)
	r.tick += 1

## Party detail, trimmed per client: cooldowns only for its own unit (others get empty cds), buffs
## for everyone. Cuts this message by about 80%.
func _send_detail(r: Room) -> void:
	var d := r.sim.party_detail()
	for p in r.ready_peers:
		var u: SUnit = r.sim.players.get(p)
		var mine := u.id if u else 0
		var out := {}
		for id in d:
			out[id] = d[id] if id == mine else { "cds": {}, "gcd": 0.0, "buffs": d[id].buffs }
		_to(p, "_s_detail", [out])

func _flush_events(r: Room) -> void:
	for p in r.ready_peers:
		var evs: Array = r.sim.events
		if r.sim.private_events.has(p):
			evs = evs + r.sim.private_events[p]
		if evs.size():
			_to(p, "_s_events", [evs])
	r.sim.events = []
	r.sim.private_events = {}

## Wire format: [time, n_rows, cart0x, cart1x, bell, in_combat, last] then n_rows rows. A tick's rows
## are split over several packets to stay under the MTU; last is 1 on the tick's final packet.
## Units leave only through reliable despawn events, so a lost packet can't remove one.
func _broadcast_snapshot(r: Room) -> void:
	var full := r.sim.snapshot()
	var stride := Sim.SNAP_STRIDE
	r.snap_n += 1
	var key := r.snap_n % KEYFRAME_EVERY == 0
	var rows: Array[PackedFloat32Array] = []
	var i := 6
	while i < full.size():
		var id := int(full[i])
		var row := full.slice(i, i + stride)
		if r.sent_rows.get(id) != row:
			r.sent_rows[id] = row
			r.changed_at[id] = r.snap_n
		if key or r.snap_n - int(r.changed_at.get(id, -99)) <= RESEND:
			rows.append(row)
		i += stride
	var start := 0
	while true:
		var n := mini(ROWS_PER_PACKET, rows.size() - start)
		var last := start + n >= rows.size()
		var out := PackedFloat32Array([full[0], n, full[2], full[3], full[4], full[5], 1.0 if last else 0.0])
		for k in n:
			out.append_array(rows[start + k])
		_to_ready(r, "_s_snap", [out])
		start += n
		if last:
			break

# ------------------------------------------------------------------ client side
@rpc("authority", "reliable")
func _s_room(code: String) -> void:
	room_code = code
	room_joined.emit(code)

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
