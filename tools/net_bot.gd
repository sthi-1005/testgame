extends Node
## Headless network client that plays through Net like a real client would: it moves its own unit
## locally (collision against its own Level copy), sends moves and abilities, and reads snapshots.
##   godot --headless --path . res://tools/net_bot.tscn -- --join 127.0.0.1 --cls mage [--secs 60]
##   --host --wait 5 : listen-server that starts once 5 players are in the lobby
##   --solo          : OfflineMultiplayerPeer
##   --stage id      : the stage to host (see stages/stages.gd)
##   --ws            : WebSocket transport
##   --create [--room ABCD] / --room ABCD [--server-url ws://...] : online rooms on a dedicated --ws server

var lv: Level = Stages.make_level(Stages.DEFAULT)
var cls := "sellsword"
var secs := 60.0
var wait := 1
var t := 0.0
var me := 0
var pos := Vector3.INF
var yaw := 0.0
var tp := -1
var path: Array = []
var path_t := 0.0
var use_t := 0.0
var units := {} # id -> spawn info
var rows := {} # id -> row
var st := { "snaps": 0, "events": 0, "snaps_bytes": 0, "snaps_rows": 0, "snaps_max": 0, "tp": 0, "kills": 0, "states": [] }
var first_snap := -1.0
var target := 0
var act_t := 0.0
var roll_t := 0.0
var roll_dir := Vector3.ZERO
var rolls := 0

func _arg(name: String, def: String) -> String:
	var a := OS.get_cmdline_user_args()
	var i := a.find(name)
	return a[i + 1] if i >= 0 and i + 1 < a.size() else def

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	cls = _arg("--cls", cls)
	secs = float(_arg("--secs", str(secs)))
	wait = int(_arg("--wait", "1"))
	Net.stage = _arg("--stage", Net.stage)
	Net.world_received.connect(func(w):
		if w.get("stage", lv.stage_id) != lv.stage_id:
			lv = Stages.make_level(w.stage)
		for s in w.spawns:
			units[int(s.id)] = s)
	Net.you_are.connect(func(id): me = id)
	Net.events_received.connect(_on_events)
	Net.snapshot_received.connect(_on_snap)
	Net.lobby_changed.connect(func(l):
		if Net.is_leader() and l.size() >= wait and Net.state == "lobby":
			Net.start_game())
	Net.state_changed.connect(func(s): st.states.append("%s@%.1f" % [s, t]))
	if "--ws" in a:
		Net.transport = "ws"
	if "--solo" in a:
		Net.host_solo(cls)
	elif "--create" in a:
		# online room on a dedicated server; --room asks for that code so other bots can find it
		Net.create_room(cls, _arg("--server-url", "ws://127.0.0.1:%d" % Net.DEFAULT_PORT), _arg("--room", ""))
	elif "--room" in a:
		Net.join_room(_arg("--room", ""), cls, _arg("--server-url", "ws://127.0.0.1:%d" % Net.DEFAULT_PORT))
	elif "--host" in a:
		Net.host(cls, int(_arg("--port", str(Net.DEFAULT_PORT))))
	else:
		Net.join(_arg("--join", "127.0.0.1"), cls)

func _on_events(evs: Array) -> void:
	st.events += evs.size()
	for e in evs:
		match e[0]:
			"spawn":
				units[int(e[1].id)] = e[1]
			"state":
				st.states.append("sim:" + str(e[1]))

func _on_snap(s: PackedFloat32Array) -> void:
	st.snaps += 1
	if first_snap < 0:
		first_snap = t
	var n := int(s[1])
	for k in n:
		var i := 6 + k * Sim.SNAP_STRIDE
		rows[int(s[i])] = s.slice(i, i + Sim.SNAP_STRIDE)
	if rows.has(me):
		var r: PackedFloat32Array = rows[me]
		if int(r[20]) != tp:
			if tp >= 0:
				st.tp += 1
			tp = int(r[20])
			pos = Vector3(r[1], 0, r[3])
			path = []

func _alive(id: int) -> bool:
	return rows.has(id) and not (int(rows[id][19]) & 1) and rows[id][5] > 0

func _process(delta: float) -> void:
	t += delta
	if t > secs:
		_report()
		get_tree().quit()
		return
	if Net.state != "play" or me == 0 or pos == Vector3.INF or not _alive(me):
		return
	# nearest living enemy
	var best := 0
	var bd := INF
	for id in rows:
		if units.has(id) and units[id].team == "enemy" and _alive(id):
			var r: PackedFloat32Array = rows[id]
			var d := pos.distance_to(Vector3(r[1], 0, r[3]))
			if d < bd:
				bd = d
				best = id
	if best == 0:
		return
	if best != target:
		if target and not _alive(target):
			st.kills += 1
		target = best
		Net.send_target(best, true)
	var tr: PackedFloat32Array = rows[best]
	var tpos := Vector3(tr[1], 0, tr[3])
	var rng := D.MELEE * 0.8 if D.CLASSES[cls].melee else 20.0
	var casting: bool = rows[me][15] >= 0
	# Souls-style actions: swing between abilities, and every few seconds roll sideways (moving the way a
	# client does, so the server's speed check sees real roll movement)
	if roll_t > 0:
		roll_t -= delta
		var rs: float = D.ACTS.roll.dist / 0.42
		pos = lv.move_circle(pos, roll_dir.x * rs * delta, roll_dir.z * rs * delta, 0.75 * 0.9)
		Net.send_move(pos, yaw, delta)
		return
	act_t -= delta
	if act_t <= 0 and bd <= rng + 1.0 and not casting and rows[me][22] > 30:
		act_t = 0.75
		if randf() < 0.2:
			roll_dir = Vector3(cos(yaw), 0, -sin(yaw)) * (1 if randf() < 0.5 else -1)
			roll_t = 0.42
			rolls += 1
			Net.send_act("roll", atan2(roll_dir.x, roll_dir.z), 0)
			return
		Net.send_act("light", yaw, best)
	if bd > rng and not casting:
		path_t -= delta
		if path.is_empty() or path_t <= 0:
			path = lv.find_path(pos, tpos)
			path_t = 0.5
		if path.size():
			var wp: Vector3 = path[0]
			var dir := Vector3(wp.x - pos.x, 0, wp.z - pos.z)
			if dir.length() < 0.5:
				path.pop_front()
			else:
				dir = dir.normalized()
				var step: float = D.CLASSES[cls].speed * delta
				pos = lv.move_circle(pos, dir.x * step, dir.z * step, 0.75 * 0.9)
				yaw = atan2(dir.x, dir.z)
	else:
		var to := tpos - pos
		yaw = atan2(to.x, to.z)
		use_t -= delta
		if use_t <= 0:
			use_t = 0.4
			var abs: Array = D.ABILITIES[cls]
			var ab: Dictionary = abs[randi() % 2] if cls != "cleric" else abs[0]
			Net.send_use(ab.id, best if ab.target == "enemy" else me)
	Net.send_move(pos, yaw, delta)

func _report() -> void:
	var r: PackedFloat32Array = rows.get(me, PackedFloat32Array())
	print("BOT room=%s %s peer=%d unit=%d snaps=%d (%.1f/s) events=%d snapbacks=%d targets_killed=%d rolls=%d hp=%s states=%s" % [Net.room_code, cls, multiplayer.get_unique_id(), me,
		st.snaps, st.snaps / maxf(0.01, t - first_snap), st.events, st.tp, st.kills, rolls, (str(r[5]) if r.size() else "?"), st.states])
