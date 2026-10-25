class_name Game
extends Node3D
## The client: builds the dungeon, shows units from server snapshots, predicts your own movement,
## and turns input into requests. Talks to a net object (LocalNet for solo, the network layer otherwise).

const INTERP_DELAY := 0.1
const CAM_MIN := 2.5
const CAM_MAX := 22.0

var net: Node
var stage_id := Stages.DEFAULT # set before the node enters the tree; a world from the server can switch it
var lv: Level
var wb: WorldBuilder
var we: WorldEnvironment
var pool: WorldBuilder.LightPool
var env: Environment
var cam: Camera3D
var dust: CPUParticles3D
var hud: Hud

var views := {} # unit id -> UnitView
var me_id := 0
var me: UnitView
var my_pos := Vector3.ZERO
var my_yaw := PI
var my_tp := -1
var moving := false
var target_id := 0
var detail := {}
var boss_id := 0
var boss_phase := ""
var state := "play"
var in_combat := false
var follow_server := false # autoplay: the server moves your unit
var touch_move := Vector2.ZERO # touch thumbstick (mobile/touch_controls.gd): x strafe, y forward, relative to the camera

# server clock: the latest snapshot time, and a smoothed render clock behind it
var server_t := 0.0
var render_t := -1.0

# camera
var cam_yaw := PI
var cam_pitch := -0.28
var cam_dist := 9.0 # zoom target (the wheel and pinch set this)
var cam_cur_dist := 9.0
var shake_amt := 0.0
var lmb := false
var rmb := false
var drag := 0.0
var grade_k := 0.0
var zone := ""
var clock := 0.0

var teles := {} # id -> { node, dur, t }
var projs := {} # id -> { node, tgt, speed }
var chest: Node3D
var chest_pos := Vector3.INF

func _ready() -> void:
	we = WorldEnvironment.new()
	add_child(we)
	_build_world()
	cam = Camera3D.new()
	cam.fov = 60
	cam.far = lv.cam_far
	cam.current = true
	add_child(cam)
	dust = WorldBuilder.dust_motes()
	add_child(dust)
	hud = Hud.new()
	hud.game = self
	add_child(hud)
	Quality.apply(self)
	if Quality.touch:
		add_child(TouchControls.new(self))

## Build the stage's level, world and environment (see stages/stages.gd).
func _build_world() -> void:
	lv = Stages.make_level(stage_id)
	wb = Stages.make_world(stage_id, lv, self)
	wb.build()
	env = wb.make_environment() if wb.has_method("make_environment") else Look.make_environment()
	we.environment = env
	pool = WorldBuilder.LightPool.new(self, wb.light_sources, 8)

## The server runs a different stage than the one built (a client joining a party): rebuild.
func _switch_stage(id: String) -> void:
	wb.root.queue_free()
	for l in pool.lights:
		l.queue_free()
	stage_id = id
	_build_world()
	Quality.apply(self)

## A sim position (y is height above the ground) to a world position on this stage's terrain.
func ground(p: Vector3) -> Vector3:
	return Vector3(p.x, p.y + lv.floor_y(p.x, p.z), p.z)

func attach(n: Node) -> void:
	net = n
	if n.get_parent() == null:
		add_child(net)
	net.world_received.connect(_on_world)
	net.snapshot_received.connect(_on_snapshot)
	net.events_received.connect(_on_events)
	net.party_detail_received.connect(func(d): detail = d)
	net.you_are.connect(_on_you_are)
	net.state_changed.connect(func(s): state = s)

# ------------------------------------------------------------------ network in
func _on_world(w: Dictionary) -> void:
	if w.get("stage", stage_id) != stage_id and Stages.has(w.stage):
		_switch_stage(w.stage)
	for info in w.spawns:
		_spawn(info)
	if w.get("boss", 0):
		boss_id = w.boss
		hud.boss_show(boss_id)

func _on_you_are(id: int) -> void:
	me_id = id
	me = views.get(id)
	if me:
		my_pos = me.position
		me.plate.visible = false
		cam_yaw = my_yaw

func _spawn(info: Dictionary) -> void:
	if views.has(info.id):
		return
	var v := UnitView.new()
	add_child(v)
	v.setup(info)
	views[info.id] = v
	if info.id == me_id:
		me = v
		v.plate.visible = false

func _on_snapshot(s: PackedFloat32Array) -> void:
	server_t = s[0]
	if render_t < 0:
		render_t = server_t - INTERP_DELAY
	in_combat = s[5] > 0.5
	for k in mini(wb.cart_nodes.size(), 2):
		(wb.cart_nodes[k] as Node3D).position.x = s[2 + k]
	if wb.bell_pivot:
		wb.bell_pivot.rotation.z = sin(clock * 3.0) * s[4] * 0.6
	var n := int(s[1])
	var i := 6
	for k in n:
		var id := int(s[i])
		var v: UnitView = views.get(id)
		if v:
			var is_me := id == me_id
			v.apply(s, i, s[0], is_me)
			if is_me:
				var tp := int(s[i + 20])
				var driven := int(s[i + 19]) & 32 != 0
				if tp != my_tp or driven or follow_server:
					my_tp = tp
					my_pos = Vector3(s[i + 1], 0, s[i + 3])
					if driven or follow_server:
						my_yaw = s[i + 4]
		i += Sim.SNAP_STRIDE

func _on_events(evs: Array) -> void:
	for e in evs:
		match e[0]:
			"spawn":
				_spawn(e[1])
			"despawn":
				var v: UnitView = views.get(e[1])
				if v:
					views.erase(e[1])
					v.queue_free()
				if target_id == e[1]:
					_set_target(0, false)
			"float":
				_float_text(e[1], e[2], e[3])
			"fx":
				_fx(e[1], ground(e[2]), e[3] if e[3] != null else {})
			"chat":
				hud.chat(e[1], e[2])
			"emote":
				hud.chat(e[1], "emote")
				hud.banner(e[1], Color(1, 0.85, 0.5))
			"yell":
				var v: UnitView = views.get(e[1])
				if v:
					hud.chat("%s yells: %s" % [v.info.name, e[2]], "yell")
					hud.bubble(v, e[2], true)
			"say":
				var v: UnitView = views.get(e[1])
				if v:
					hud.chat("%s says: %s" % [v.info.name, e[2]], "say")
					hud.bubble(v, e[2], false)
			"error":
				hud.error(e[1])
			"tele":
				_tele(e)
			"tele_end":
				var tl = teles.get(e[1])
				if tl:
					tl.node.queue_free()
					teles.erase(e[1])
			"proj":
				_proj(e)
			"proj_end":
				var pr = projs.get(e[1])
				if pr:
					if e[2]:
						_burst(pr.node.position, pr.color, 14, 3.0, 0.0, 0.35)
					pr.node.queue_free()
					projs.erase(e[1])
			"boss":
				if e[1] == "show":
					boss_id = e[2]
					hud.boss_show(e[2])
				elif e[1] == "hide":
					boss_id = 0
					hud.boss_hide()
				elif e[1] == "phase":
					boss_phase = e[3]
			"state":
				state = e[1]
				if e[1] == "victory":
					hud.victory(e[2])
				elif e[1] == "wipe":
					hud.banner("Your party has fallen...", Color(1, 0.4, 0.3))
			"chest":
				_chest(ground(e[1]), e[2])
			"loot":
				hud.loot()
				if chest:
					_burst(chest.position + Vector3(0, 1, 0), Color(1, 0.85, 0.3), 40, 4.0, 3.0, 0.4)
			"shake":
				if e[2] == 0 or e[2] == me_id:
					shake_amt = maxf(shake_amt, e[1])

# ------------------------------------------------------------------ frame
func _process(delta: float) -> void:
	clock += delta
	if render_t >= 0:
		render_t += delta
		var want := server_t - INTERP_DELAY
		# drift toward the target delay instead of jumping
		render_t = lerpf(render_t, want, clampf(delta * 2.0, 0.0, 1.0))
		if absf(render_t - want) > 0.5:
			render_t = want
	for id in views:
		var v: UnitView = views[id]
		if id == me_id:
			continue
		v.interpolate(render_t)
		v.position.y += lv.floor_y(v.position.x, v.position.z)
		var near := v.position.distance_to(my_pos) < 32.0
		v.plate.visible = not v.dead and (id == hover_id or id == target_id or (near and (v.is_enemy() and (v.flags & 2 != 0 or v.position.distance_to(my_pos) < 22.0))))
	if me:
		me.position = ground(my_pos)
		me.model.rotation.y = my_yaw
	_update_camera(delta)
	_update_hover()
	_update_teles_projs(delta)
	pool.update(my_pos, clock)
	dust.global_position = cam.global_position + (-cam.global_transform.basis.z * 5.0)
	var z := lv.zone_at(my_pos.x, my_pos.z)
	if wb.has_method("grade"):
		wb.grade(env, z, delta) # the stage owns its sky and colour grade
	else:
		var hall := 1.0 if z == "hall" or z == "gate" else 0.0
		grade_k = move_toward(grade_k, hall, delta * 0.8)
		Look.grade(env, grade_k)
	if z != zone and z != "":
		var names := lv.zone_names
		if names.has(z) and (zone == "" or names.get(zone) != names[z]):
			hud.zone_banner(names[z])
		zone = z
	hud.prompt("Press F to open the strongbox" if chest and my_pos.distance_to(chest_pos) < 5.0 else "")

func _physics_process(delta: float) -> void:
	if me == null or net == null or follow_server:
		return
	var flags := me.flags
	var can_move := not me.dead and flags & (4 | 8 | 32) == 0 and state == "play" and not hud.typing()
	var fwd := 0.0
	var side := 0.0
	var turn := 0.0
	if can_move:
		if _key(KEY_W) or (lmb and rmb): fwd += 1
		if _key(KEY_S): fwd -= 1
		if _key(KEY_Q): side -= 1
		if _key(KEY_E): side += 1
		if rmb:
			if _key(KEY_A): side -= 1
			if _key(KEY_D): side += 1
		else:
			if _key(KEY_A): turn += 1
			if _key(KEY_D): turn -= 1
	if turn != 0:
		my_yaw += turn * 2.6 * delta
		if not lmb:
			cam_yaw = lerp_angle(cam_yaw, my_yaw, 1.0)
	var stick := can_move and touch_move.length() > 0.15
	var was_moving := moving
	moving = fwd != 0 or side != 0 or stick
	_fwd_input = fwd
	if moving:
		var f := Vector3(sin(my_yaw), 0, cos(my_yaw))
		var r := Vector3(-f.z, 0, f.x)
		var dir := (f * fwd + r * side).normalized()
		if stick:
			# run the way the stick points, seen from the camera, and face that way
			var cf := Vector3(sin(cam_yaw), 0, cos(cam_yaw))
			var cr := Vector3(-cf.z, 0, cf.x)
			dir = (cf * touch_move.y + cr * touch_move.x).normalized() * minf(touch_move.length() * 1.25, 1.0)
			my_yaw = atan2(dir.x, dir.z)
			fwd = 1.0
		var spd: float = D.CLASSES[me.info.body].speed * (0.6 if fwd < 0 else 1.0) * (0.6 if flags & 16 else 1.0)
		my_pos = lv.move_circle(my_pos, dir.x * spd * delta, dir.z * spd * delta, me.info.r)
		me.play_base("back" if fwd < 0 else "run", -0.9 if fwd < 0 else 1.05)
	elif was_moving or me.base in ["run", "back"]:
		me.play_base("combatIdle" if in_combat and D.CLASSES[me.info.body].melee else "idle", 1.0)
	if not me.dead and flags & 32 == 0:
		net.send_move(my_pos, my_yaw, delta)

## Touch camera drag (same feel as a mouse drag).
func touch_look(rel: Vector2) -> void:
	cam_yaw -= rel.x * 0.006
	cam_pitch = clampf(cam_pitch - rel.y * 0.005, -1.25, 0.45)

func _key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)

# ------------------------------------------------------------------ input
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = clampf(cam_dist - 0.8, CAM_MIN, CAM_MAX)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = clampf(cam_dist + 0.8, CAM_MIN, CAM_MAX)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			var left := mb.button_index == MOUSE_BUTTON_LEFT
			if mb.pressed:
				if left: lmb = true
				else: rmb = true
				drag = 0.0
				_click_pos = mb.position
			else:
				if left: lmb = false
				else: rmb = false
				if drag < 6.0:
					_pick(mb.position, not left)
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if (lmb or rmb) else Input.MOUSE_MODE_VISIBLE
			if not (lmb or rmb):
				Input.warp_mouse(_click_pos)
	elif e is InputEventMouseMotion and (lmb or rmb):
		var mm := e as InputEventMouseMotion
		drag += mm.relative.length()
		cam_yaw -= mm.relative.x * 0.006
		cam_pitch = clampf(cam_pitch - mm.relative.y * 0.005, -1.25, 0.45)
		if rmb and me and not me.dead and me.flags & 32 == 0:
			my_yaw = cam_yaw
	elif e is InputEventKey and e.pressed and not e.echo:
		var k := (e as InputEventKey).physical_keycode
		if k >= KEY_1 and k <= KEY_5:
			_use_slot(k - KEY_1)
		elif k == KEY_6 or k == KEY_R:
			_use("potion")
		elif k == KEY_TAB:
			_tab_target()
		elif k >= KEY_F1 and k <= KEY_F5:
			_party_target(k - KEY_F1)
		elif k == KEY_F:
			if chest and my_pos.distance_to(chest_pos) < 5.0:
				net.send_loot()
		elif k == KEY_ESCAPE:
			_set_target(0, false)

var _click_pos := Vector2.ZERO

func _use_slot(i: int) -> void:
	if me == null:
		return
	var abs: Array = D.ABILITIES[me.info.body]
	if i < abs.size():
		_use(abs[i].id)

func _use(id: String) -> void:
	if me == null or me.dead:
		return
	var ab := D.ability(me.info.body, id)
	if ab.target == "enemy" and target_id and views.has(target_id) and views[target_id].is_enemy():
		var t: UnitView = views[target_id]
		my_yaw = atan2(t.position.x - my_pos.x, t.position.z - my_pos.z)
		net.send_move(my_pos, my_yaw, 0.0)
	elif ab.target == "enemy" and (target_id == 0 or not views.has(target_id) or not views[target_id].is_enemy() or views[target_id].dead):
		_tab_target()
		if target_id:
			var t: UnitView = views[target_id]
			my_yaw = atan2(t.position.x - my_pos.x, t.position.z - my_pos.z)
			net.send_move(my_pos, my_yaw, 0.0)
	if ab.cast > 0 and moving:
		hud.error("Can't do that while moving.")
		return
	hud.pressed(id)
	net.send_use(id, target_id)

func _set_target(id: int, attack: bool) -> void:
	if target_id and views.has(target_id):
		views[target_id].set_targeted(false, false)
	target_id = id
	if id and views.has(id):
		var v: UnitView = views[id]
		v.set_targeted(true, v.is_enemy())
	net.send_target(id, attack)

func unit_at(at: Vector2) -> int:
	var best := 0
	var bd := 1e9
	for id in views:
		var v: UnitView = views[id]
		if id == me_id:
			continue
		var feet := v.global_position + Vector3(0, v.fly, 0)
		var head := feet + Vector3(0, v.height(), 0)
		if cam.is_position_behind(feet):
			continue
		var a := cam.unproject_position(feet)
		var b := cam.unproject_position(head)
		var seg := b - a
		var t := clampf((at - a).dot(seg) / maxf(seg.length_squared(), 1.0), 0.0, 1.0)
		var d := at.distance_to(a + seg * t)
		var reach := maxf(16.0, seg.length() * 0.32)
		if d < reach and d < bd and not (v.dead and v.is_enemy()):
			bd = d
			best = id
	return best

func chest_at(at: Vector2) -> bool:
	if chest == null or cam.is_position_behind(chest_pos):
		return false
	var a := cam.unproject_position(chest_pos + Vector3(0, 0.8, 0))
	var scale := cam.unproject_position(chest_pos + cam.global_transform.basis.x * 1.4 + Vector3(0, 0.8, 0)).distance_to(a)
	return at.distance_to(a) < maxf(20.0, scale)

func _pick(at: Vector2, attack: bool) -> void:
	if chest_at(at):
		if my_pos.distance_to(chest_pos) < 5.0:
			net.send_loot()
		else:
			hud.error("You are too far away.")
		return
	var best := unit_at(at)
	if best:
		_set_target(best, attack and views[best].is_enemy())
	elif not attack:
		_set_target(0, false)

var hover_id := 0
var cursor_kind := ""

func _update_hover() -> void:
	var kind := "pointer"
	var id := 0
	if not (lmb or rmb):
		var at := get_viewport().get_mouse_position()
		if chest_at(at):
			kind = "interact" if my_pos.distance_to(chest_pos) < 5.0 else "no"
		else:
			id = unit_at(at)
			if id:
				kind = "attack" if views[id].is_enemy() else "help"
	if id != hover_id:
		if hover_id and views.has(hover_id):
			views[hover_id].set_hover(false)
		hover_id = id
		if id:
			views[id].set_hover(true)
	if kind != cursor_kind:
		cursor_kind = kind
		Cursors.set_kind(kind)

func _tab_target() -> void:
	var cands: Array = []
	var f := Vector3(sin(my_yaw), 0, cos(my_yaw))
	for id in views:
		var v: UnitView = views[id]
		if not v.is_enemy() or v.dead:
			continue
		var to := v.position - my_pos
		var d := to.length()
		if d > 40 or not lv.line_clear(my_pos, v.position):
			continue
		var facing := f.dot(to / maxf(d, 0.01))
		cands.append([d - facing * 8.0, id])
	if cands.is_empty():
		return
	cands.sort_custom(func(a, b): return a[0] < b[0])
	var idx := 0
	for k in cands.size():
		if cands[k][1] == target_id:
			idx = (k + 1) % cands.size()
	_set_target(cands[idx][1], false)

func _party_target(i: int) -> void:
	var party := party_views()
	if i < party.size():
		_set_target(party[i].id, false)

func party_views() -> Array:
	var out: Array = []
	if me:
		out.append(me)
	for id in views:
		var v: UnitView = views[id]
		if v.info.team == "party" and id != me_id:
			out.append(v)
	return out

# ------------------------------------------------------------------ camera
## WoW-style: an eye-height pivot, the camera swings in behind you as you run, and a swept sphere
## against the camera collision layer pulls it in when rock gets in the way (and eases it back out).
func _update_camera(delta: float) -> void:
	var steering := lmb or rmb or touch_move != Vector2.ZERO
	if not steering and ((moving and _fwd_input >= 0) or follow_server):
		cam_yaw = lerp_angle(cam_yaw, my_yaw, clampf(delta * (1.5 if follow_server else 3.5), 0, 1))
	var want_pivot := ground(my_pos) + Vector3(0, PIVOT_H, 0)
	cam_pivot = want_pivot if cam_pivot == Vector3.INF else cam_pivot.lerp(want_pivot, clampf(delta * 14.0, 0, 1))
	cam_zoom = move_toward(cam_zoom, cam_dist, delta * maxf(6.0, absf(cam_dist - cam_zoom) * 6.0))
	var dir := Vector3(-sin(cam_yaw) * cos(cam_pitch), -sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))
	var allowed := _cam_sweep(cam_pivot, dir, cam_zoom)
	cam_cur_dist = allowed if allowed < cam_cur_dist else move_toward(cam_cur_dist, allowed, delta * 5.0)
	var pos := cam_pivot + dir * cam_cur_dist
	if shake_amt > 0:
		pos += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake_amt * 0.25
		shake_amt = maxf(0.0, shake_amt - delta * 2.5)
	cam.look_at_from_position(pos, cam_pivot + Vector3(0, 0.15, 0))
	if me:
		me.model.visible = cam_cur_dist > 1.3

const PIVOT_H := 2.0
const CAM_RADIUS := 0.3
var cam_pivot := Vector3.INF
var cam_zoom := 9.0
var _fwd_input := 0.0
var _cam_shape: SphereShape3D

## How far the camera can sit from the pivot along dir: a sphere swept against collision layer 2.
func _cam_sweep(pivot: Vector3, dir: Vector3, dist: float) -> float:
	if _cam_shape == null:
		_cam_shape = SphereShape3D.new()
		_cam_shape.radius = CAM_RADIUS
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _cam_shape
	q.transform = Transform3D(Basis(), pivot)
	q.motion = dir * dist
	q.collision_mask = WorldBuilder.CAMERA_LAYER
	var r := get_world_3d().direct_space_state.cast_motion(q)
	var d := dist * r[0]
	# never inside the floor either
	var floor_t := (pivot.y - lv.floor_y(pivot.x, pivot.z) - 0.4) / maxf(-dir.y, 0.001) if dir.y < 0 else INF
	return clampf(minf(d, floor_t), 0.4, dist)

# ------------------------------------------------------------------ effects
func _float_text(id: int, text: String, style: String) -> void:
	var v: UnitView = views.get(id)
	if v == null:
		return
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0012
	l.font_size = 30 if text.ends_with("!") else 22
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.85)
	var col := Color(1, 1, 1)
	match style:
		"heal": col = Color(0.4, 1, 0.45)
		"abs": col = Color(0.9, 0.85, 0.6)
		"me": col = Color(1, 0.35, 0.3)
		"crit": col = Color(1, 0.8, 0.2)
		"spell": col = Color(1, 0.85, 0.3)
	if v.id == me_id and style != "heal":
		col = Color(1, 0.35, 0.3)
	l.modulate = col
	add_child(l)
	l.global_position = v.chest() + Vector3(randf_range(-0.6, 0.6), 0.8, randf_range(-0.6, 0.6))
	var tw := create_tween()
	tw.set_parallel()
	tw.tween_property(l, "position:y", l.position.y + 1.6, 1.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(l, "modulate:a", 0.0, 0.5).set_delay(0.6)
	tw.chain().tween_callback(l.queue_free)

static var _fx_mat: StandardMaterial3D

func _burst(p: Vector3, color: Color, n: int, speed: float, gravity: float, size: float, life := 0.7) -> void:
	if _fx_mat == null:
		_fx_mat = WorldBuilder.fire_mat().duplicate() as StandardMaterial3D
		_fx_mat.albedo_color = Color(1.4, 1.4, 1.4)
	var ps := CPUParticles3D.new()
	ps.one_shot = true
	ps.explosiveness = 0.9
	ps.amount = maxi(n, 1)
	ps.lifetime = life
	ps.direction = Vector3.UP
	ps.spread = 180
	ps.initial_velocity_min = speed * 0.4
	ps.initial_velocity_max = speed
	ps.gravity = Vector3(0, -gravity, 0)
	ps.damping_min = 1.0
	ps.damping_max = 2.0
	var grad := Gradient.new()
	grad.set_color(0, Color(color, 1.0))
	grad.set_color(1, Color(color, 0.0))
	ps.color_ramp = grad
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = _fx_mat
	ps.mesh = q
	add_child(ps)
	ps.global_position = p
	ps.emitting = true
	get_tree().create_timer(life + 0.3).timeout.connect(ps.queue_free)

func _ring(p: Vector3, color: Color, r: float) -> void:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.85
	tm.outer_radius = 1.0
	tm.rings = 32
	tm.ring_segments = 4
	mi.mesh = tm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = color
	m.disable_fog = true
	mi.material_override = m
	add_child(mi)
	mi.global_position = p
	mi.scale = Vector3(1, 0.3, 1)
	# grow the radius, not the scale, so the band stays thin (a scaled torus turns into a fat glowing donut)
	var grow := func(k: float):
		tm.outer_radius = maxf(0.3, r * k)
		tm.inner_radius = maxf(0.1, r * k - 0.35)
	var tw := create_tween()
	tw.set_parallel()
	tw.tween_method(grow, 0.05, 1.0, 0.45).set_ease(Tween.EASE_OUT)
	tw.tween_property(m, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(mi.queue_free)

func _flash(p: Vector3, color: Color, energy: float, dur: float, rng := 14.0) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	add_child(l)
	l.global_position = p
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, dur)
	tw.tween_callback(l.queue_free)

func _fx(kind: String, p: Vector3, a: Dictionary) -> void:
	var col: Color = a.get("color", Color(1, 1, 1))
	match kind:
		"burst":
			_burst(p, col, a.get("n", 20), a.get("speed", 2.0), a.get("gravity", 0.0), 0.3)
		"dust":
			_burst(p + Vector3(0, 0.3, 0), Color(0.75, 0.62, 0.45, 0.8), a.get("n", 16), 2.5 * a.get("size", 1.0), 1.0, 0.7 * a.get("size", 1.0), 1.0)
		"ring":
			_ring(p, col, a.get("r", 6.0))
		"flash":
			_flash(p, col, a.get("energy", 3.0), a.get("dur", 0.4), a.get("range", 14.0))
		"heal":
			_burst(p + Vector3(0, 1.0, 0), Color(0.5, 1, 0.55), int(18 * a.get("k", 1.0)) + 6, 1.5, -2.0, 0.3, 0.9)
		"frost":
			_burst(p + Vector3(0, 1.0, 0), Color(0.6, 0.85, 1), 16, 2.0, 1.0, 0.3)
		"fire":
			_burst(p + Vector3(0, 1.0, 0), Color(1, 0.55, 0.2), 16, 2.0, -1.0, 0.35)
		"hit":
			_burst(p, col, 10, 3.0, 2.0, 0.25, 0.4)
		"blink":
			_burst(p, Color(0.7, 0.5, 1), 26, 3.0, 0.0, 0.3)
			_flash(p, Color(0.7, 0.5, 1), 2.0, 0.3)
		"explode", "boom":
			_burst(p + Vector3(0, 0.6, 0), Color(1, 0.55, 0.2), 50, 7.0, 3.0, 0.6, 0.9)
			_flash(p + Vector3(0, 1.5, 0), Color(1, 0.6, 0.25), 6.0, 0.6, 20.0)
			shake_amt = maxf(shake_amt, 0.5)
		"meteor":
			_meteor(p, a.get("dur", 1.2))
		"sky":
			_beam(p, col)
		"poof":
			_burst(p, Color(0.6, 0.6, 0.65), 18, 2.0, 0.0, 0.5)
		"slam":
			_burst(p, Color(0.75, 0.62, 0.45), 24, 4.0, 3.0, 0.6)
		"charge", "roar":
			_ring(p + Vector3(0, 0.5, 0), Color(1, 0.6, 0.3), 6.0)
		"win":
			_burst(p + Vector3(0, 2, 0), Color(1, 0.85, 0.3), 60, 5.0, 2.0, 0.4, 1.5)
		_:
			_burst(p, col, 12, 2.0, 0.0, 0.3)

func _meteor(p: Vector3, dur: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.7
	sm.height = 1.4
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.55, 0.15)
	m.emission_enabled = true
	m.emission = Color(1, 0.5, 0.1)
	m.emission_energy_multiplier = 4.0
	mi.material_override = m
	add_child(mi)
	var top := p + Vector3(-4, 18, -4)
	mi.global_position = top
	var tw := create_tween()
	tw.tween_property(mi, "global_position", p + Vector3(0, 0.5, 0), dur).set_ease(Tween.EASE_IN)
	tw.tween_callback(mi.queue_free)

func _beam(p: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.9
	cm.bottom_radius = 0.9
	cm.height = 12
	mi.mesh = cm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(color, 0.5)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)
	mi.global_position = p + Vector3(0, 6, 0)
	var tw := create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, 0.6)
	tw.tween_callback(mi.queue_free)

func _tele(e: Array) -> void:
	# ["tele", id, kind, pos/from, r | [dir, len, width], dur, color]
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var col: Color = e[6]
	if e[2] == "circle":
		pm.size = Vector2(e[4], e[4]) * 2.0
		mi.material_override = Look.tele_mat(col, false)
		mi.mesh = pm
		add_child(mi)
		mi.global_position = ground(e[3]) + Vector3(0, 0.07, 0)
	else:
		var dir: Vector3 = e[4][0]
		var length: float = e[4][1]
		var width: float = e[4][2]
		pm.size = Vector2(width, length)
		mi.material_override = Look.tele_mat(col, true)
		mi.mesh = pm
		add_child(mi)
		var from: Vector3 = ground(e[3])
		mi.global_position = from + dir * (length / 2) + Vector3(0, 0.07, 0)
		mi.rotation.y = atan2(dir.x, dir.z)
	teles[e[1]] = { "node": mi, "dur": e[5], "t": 0.0 }

func _proj(e: Array) -> void:
	# ["proj", id, src, tgt, start, color, speed, size]
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.22 * e[7]
	sm.height = 0.44 * e[7]
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var col: Color = e[5]
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 3.0
	mi.material_override = m
	add_child(mi)
	mi.global_position = ground(e[4])
	var trail := CPUParticles3D.new()
	trail.amount = 24
	trail.lifetime = 0.35
	trail.local_coords = false
	trail.gravity = Vector3.ZERO
	trail.initial_velocity_min = 0.0
	trail.initial_velocity_max = 0.3
	var q := QuadMesh.new()
	q.size = Vector2(0.35, 0.35) * e[7]
	if _fx_mat == null:
		_burst(e[4], col, 1, 0.0, 0.0, 0.01)
	q.material = _fx_mat
	trail.mesh = q
	var grad := Gradient.new()
	grad.set_color(0, Color(col, 0.9))
	grad.set_color(1, Color(col, 0.0))
	trail.color_ramp = grad
	mi.add_child(trail)
	projs[e[1]] = { "node": mi, "tgt": e[3], "speed": e[6], "color": col }

func _update_teles_projs(delta: float) -> void:
	for id in teles:
		var tl: Dictionary = teles[id]
		tl.t += delta
		var m: ShaderMaterial = tl.node.material_override
		m.set_shader_parameter("fill", clampf(tl.t / tl.dur, 0.0, 1.0))
		m.set_shader_parameter("pulse", 0.5 + 0.5 * sin(clock * 10.0))
	for id in projs:
		var pr: Dictionary = projs[id]
		var v: UnitView = views.get(pr.tgt)
		if v == null:
			continue
		var to: Vector3 = v.chest() - pr.node.global_position
		var d := to.length()
		if d > 0.05:
			pr.node.global_position += to * minf(1.0, pr.speed * delta / d)

func _chest(p: Vector3, rot: float) -> void:
	chest = Assets.prop("dungeon-chest", 0.03)
	add_child(chest)
	chest.global_position = p
	chest.rotation.y = rot
	chest.scale = Vector3.ONE * 1.6
	chest_pos = p
	_burst(p + Vector3(0, 1, 0), Color(1, 0.85, 0.3), 30, 3.0, 1.0, 0.35)
