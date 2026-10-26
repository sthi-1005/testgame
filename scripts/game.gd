class_name Game
extends Node3D
## The client: builds the dungeon, shows units from server snapshots, predicts your own movement,
## and turns input into requests. Talks to a net object (LocalNet for solo, the network layer otherwise).

const INTERP_DELAY := 0.1
const CAM_MIN := 2.5
const CAM_MAX := 14.0

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
var sfx: Sfx
var winds := {} # enemy id -> { node, mat, dur, t, glint } while it winds up a blow

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
var cam_pitch := -0.2
var cam_dist := 5.2 # zoom target (the wheel and pinch set this)
var cam_cur_dist := 5.2
var shake_amt := 0.0
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
	sfx = Sfx.new()
	add_child(sfx)
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
		_capture(true)

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
			"sfx":
				var at: Vector3 = e[2] if e[2] != Vector3.INF else my_pos
				match e[1]:
					"slam", "boom": sfx.play("slam", ground(at), 2.0)
					"charge", "roar": sfx.play("heavy_swing", ground(at))
			"wind":
				_wind(e[1], e[2], e[3], e[4], e[5])
			"swoosh":
				_end_wind(e[1])
				if e[1] != me_id:
					var v: UnitView = views.get(e[1])
					if v:
						_swoosh(v, e[2], e[3], e[4], e[5])
			"hurt":
				_hurt(e[1], e[2], e[3], e[4])

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
		v.keep_playing()
		v.tick_fx(delta)
		var near := v.position.distance_to(my_pos) < 32.0
		v.plate.visible = not v.dead and (id == hover_id or id == target_id or (near and (v.is_enemy() and (v.flags & 2 != 0 or v.position.distance_to(my_pos) < 22.0))))
	if me:
		me.position = ground(my_pos)
		me.model.rotation.y = my_yaw
		me.keep_playing()
		me.tick_fx(delta)
	if OS.has_feature("web") and not Quality.touch:
		# the browser drops pointer lock on Esc or a tab switch, and only grants it on a click
		captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if captured and state == "victory":
		_capture(false) # the end screen needs the cursor
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
	_pad_poll(delta)
	act_lock = maxf(0.0, act_lock - delta)
	if locked:
		_check_lock()
	var flags := me.flags
	var can_move := not me.dead and flags & (4 | 8 | 32) == 0 and state == "play" and not hud.typing()
	var input := Vector2.ZERO # x right, y forward, relative to the camera
	if can_move:
		if _key(KEY_W): input.y += 1
		if _key(KEY_S): input.y -= 1
		if _key(KEY_D): input.x += 1
		if _key(KEY_A): input.x -= 1
		input = input.normalized()
		if touch_move.length() > 0.15:
			input = touch_move.normalized() * minf(touch_move.length() * 1.25, 1.0)
		elif pad_move.length() > 0.2:
			input = pad_move.limit_length(1.0)
	var cf := Vector3(sin(cam_yaw), 0, cos(cam_yaw))
	var cr := Vector3(-cf.z, 0, cf.x)
	move_dir = cf * input.y + cr * input.x
	# a held dodge button turns into a sprint once you are moving
	if dodge_down and not sprinting and clock - dodge_t > SPRINT_HOLD and move_dir.length() > 0.3 and me.stam > 5:
		sprinting = true
		net.send_act("sprint", my_yaw, 0)
	if sprinting and (me.stam <= 0 or move_dir.length() < 0.1):
		sprinting = false
		net.send_act("unsprint", my_yaw, 0)
	if act_lock <= 0 and buffered != "" and clock - buffered_t < BUFFER_T:
		var k := buffered
		buffered = ""
		_act(k)
	var lt: UnitView = views.get(target_id) if locked else null
	var was_moving := moving
	moving = false
	if roll_t > 0:
		# the roll (or backstep) carries you; the server opened its i-frames when it got the press
		roll_t -= delta
		var spd := roll_dist / ROLL_MOVE_T
		if roll_t > roll_total - ROLL_MOVE_T and can_move:
			my_pos = lv.move_circle(my_pos, roll_dir.x * spd * delta, roll_dir.z * spd * delta, me.info.r)
	elif can_move and (act_lock <= 0 or swing_move > 0):
		var swinging := act_lock > 0
		if lt and not sprinting and not swinging:
			my_yaw = lerp_angle(my_yaw, atan2(lt.position.x - my_pos.x, lt.position.z - my_pos.z), clampf(delta * 14.0, 0, 1))
		if move_dir.length() > 0.05:
			moving = true
			if (lt == null or sprinting) and not swinging:
				my_yaw = lerp_angle(my_yaw, atan2(move_dir.x, move_dir.z), clampf(delta * 12.0, 0, 1))
			var spd: float = D.CLASSES[me.info.body].speed * (0.6 if flags & 16 else 1.0)
			if swinging:
				spd *= swing_move # you keep moving through a basic attack, a little slower, facing the blow
			if sprinting:
				spd *= D.SPRINT_K
			elif blocking:
				spd *= D.BLOCK_SPEED_K
			var f := Vector3(sin(my_yaw), 0, cos(my_yaw))
			var back := lt != null and not sprinting and move_dir.normalized().dot(f) < -0.4
			if back:
				spd *= 0.75
			my_pos = lv.move_circle(my_pos, move_dir.x * spd * delta, move_dir.z * spd * delta, me.info.r)
			if blocking:
				me.play_base("walk", 0.8)
			elif back:
				me.play_base("back", -0.9)
			elif lt and absf(move_dir.normalized().dot(f)) < 0.5:
				me.play_base("walk", 1.2) # strafing round a locked target
			else:
				me.play_base("run", 1.45 if sprinting else 1.05 * move_dir.length())
	if not moving and roll_t <= 0:
		if blocking:
			me.play_base("block", 1.0)
		elif was_moving or me.base in ["run", "back", "walk", "block"]:
			me.play_base("combatIdle" if in_combat and D.CLASSES[me.info.body].melee else "idle", 1.0)
	if not me.dead and flags & 32 == 0:
		net.send_move(my_pos, my_yaw, delta)

## Touch camera drag (same feel as a mouse drag).
func touch_look(rel: Vector2) -> void:
	_look(rel * 1.2)

func _look(rel: Vector2) -> void:
	if locked:
		# with a target held, a sideways flick moves the lock to the next enemy that way
		flick += rel.x
		if absf(flick) > FLICK:
			_switch_lock(signi(int(flick)))
			flick = 0.0
		return
	cam_yaw -= rel.x * 0.0045 * look_sens
	cam_pitch = clampf(cam_pitch - rel.y * 0.004 * look_sens, -1.2, 0.5)

func _key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)

# ------------------------------------------------------------------ souls-style actions
const SPRINT_HOLD := 0.28 # hold dodge this long and it becomes a sprint
const BUFFER_T := 0.35 # a press during an attack or roll fires when it ends, if it is this recent
const ROLL_MOVE_T := 0.42
const FLICK := 70.0
var act_lock := 0.0
var swing_move := 0.0 # speed multiplier while act_lock runs: 0 roots you (rolls), attacks keep you moving
var buffered := ""
var buffered_t := 0.0
var roll_t := 0.0
var roll_total := 0.0
var roll_dist := 0.0
var roll_dir := Vector3.ZERO
var move_dir := Vector3.ZERO
var dodge_down := false
var dodge_t := 0.0
var sprinting := false
var blocking := false
var locked := false
var flick := 0.0
var look_sens := 1.0
var captured := false
var pad_move := Vector2.ZERO
var _pad_rt := false
var _pad_lt := false
var _pad_flick := 0.0
var lock_dot: MeshInstance3D

func dodge_press() -> void:
	if dodge_down:
		return
	dodge_down = true
	dodge_t = clock

func dodge_release() -> void:
	if not dodge_down:
		return
	dodge_down = false
	if sprinting:
		sprinting = false
		net.send_act("unsprint", my_yaw, 0)
	elif clock - dodge_t <= SPRINT_HOLD:
		_act("roll")

func block_press() -> void:
	if blocking or me == null or me.dead:
		return
	blocking = true
	net.send_act("block", my_yaw, 0)

func block_release() -> void:
	if not blocking:
		return
	blocking = false
	net.send_act("unblock", my_yaw, 0)

## light | heavy | roll | parry. Plays at once on your own character; the server checks stamina and
## timing, owns the i-frames, parry window and damage.
func _act(kind: String) -> void:
	if me == null or me.dead or state != "play" or follow_server or me.flags & (4 | 32) != 0:
		return
	if act_lock > 0 or roll_t > 0:
		buffered = kind
		buffered_t = clock
		return
	if me.stam <= 0:
		hud.stamina_flash()
		return
	var lt: UnitView = views.get(target_id) if locked else null
	var yaw := my_yaw
	var tid := target_id if locked else 0
	if kind == "roll":
		if move_dir.length() > 0.2:
			roll_dir = move_dir.normalized()
			yaw = atan2(roll_dir.x, roll_dir.z)
		else:
			kind = "backstep"
			roll_dir = -Vector3(sin(my_yaw), 0, cos(my_yaw))
		var a: Dictionary = D.ACTS[kind]
		roll_dist = a.dist
		roll_total = a.lock
		roll_t = a.lock
		if blocking:
			block_release()
		if kind == "roll":
			me.play_act("roll", 1.35)
			me.local_act_ms = Time.get_ticks_msec()
	else:
		if lt:
			yaw = atan2(lt.position.x - my_pos.x, lt.position.z - my_pos.z)
		elif kind != "parry":
			var melee: bool = D.CLASSES[me.info.body].melee
			var aim := atan2(move_dir.x, move_dir.z) if move_dir.length() > 0.2 else (my_yaw if melee else cam_yaw)
			var soft := _soft_target(aim, 5.5 if melee else D.AIM_RANGE, 1.0 if melee else 0.45)
			yaw = atan2(soft.position.x - my_pos.x, soft.position.z - my_pos.z) if soft else aim
			if soft and not melee:
				tid = soft.id
		var anim := ""
		match kind:
			"light":
				combo = (combo + 1) % 2
				anim = ("attack" if combo == 0 else "attack2") if D.CLASSES[me.info.body].melee else "release"
			"heavy":
				anim = "smash" if D.CLASSES[me.info.body].melee else "release"
			"parry":
				anim = "attack2"
		me.play_act(anim, 1.8 if kind == "parry" else (1.5 if kind == "light" else 1.0))
		me.local_act_ms = Time.get_ticks_msec()
	act_lock = D.ACTS[kind].lock
	swing_move = D.ACTS[kind].get("move", 0.0)
	my_yaw = yaw
	if kind in ["light", "heavy"]:
		var melee: bool = D.CLASSES[me.info.body].melee
		sfx.play("heavy_swing" if kind == "heavy" else "swing", ground(my_pos) + Vector3(0, 1.2, 0), -4.0 if melee else -8.0)
		if melee:
			var a: Dictionary = D.ACTS[kind]
			get_tree().create_timer(a.hit, false, true).timeout.connect(func():
				if me and not me.dead:
					_swoosh(me, my_yaw, D.MELEE * 0.6 + a.reach, a.arc, kind == "heavy"))
	elif kind == "roll" or kind == "backstep":
		sfx.play("roll", ground(my_pos), -6.0)
	net.send_move(my_pos, my_yaw, 0.0)
	net.send_act(kind, yaw, tid)
	hud.pressed(kind)

var combo := 0

## The enemy an unlocked attack turns toward: the nearest one in a cone around aim.
func _soft_target(aim: float, reach: float, cone: float) -> UnitView:
	var best: UnitView = null
	var bs := INF
	for id in views:
		var v: UnitView = views[id]
		if not v.is_enemy() or v.dead:
			continue
		var d := Vector2(v.position.x - my_pos.x, v.position.z - my_pos.z).length()
		var off := absf(angle_difference(aim, atan2(v.position.x - my_pos.x, v.position.z - my_pos.z)))
		if d > reach + v.info.r or off > cone or not lv.line_clear(my_pos, v.position):
			continue
		var sc := d + off * 6.0
		if sc < bs:
			bs = sc
			best = v
	return best

## Lock on to the enemy nearest the middle of the screen, or let go. With nothing to lock, the camera
## swings back behind you.
func toggle_lock() -> void:
	if locked:
		_unlock()
		return
	var best := 0
	var bs := INF
	var mid := get_viewport().get_visible_rect().size / 2.0
	for id in _lock_candidates():
		var v: UnitView = views[id]
		var sp := cam.unproject_position(v.chest())
		var sc := sp.distance_to(mid) + v.position.distance_to(my_pos) * 6.0
		if sc < bs:
			bs = sc
			best = id
	if best:
		locked = true
		flick = 0.0
		_set_target(best, false)
	else:
		recenter = true

func _unlock() -> void:
	locked = false
	if target_id and views.has(target_id) and views[target_id].is_enemy():
		_set_target(0, false)

func _lock_candidates() -> Array:
	var out: Array = []
	for id in views:
		var v: UnitView = views[id]
		if not v.is_enemy() or v.dead or v.position.distance_to(my_pos) > 30.0:
			continue
		if cam.is_position_behind(v.chest()) or not lv.line_clear(my_pos, v.position):
			continue
		out.append(id)
	return out

## Move the lock to the next enemy to the left (-1) or right (+1) on screen.
func _switch_lock(side: int) -> void:
	var cur: UnitView = views.get(target_id)
	if cur == null:
		return
	var cx := cam.unproject_position(cur.chest()).x
	var best := 0
	var bd := INF
	for id in _lock_candidates():
		if id == target_id:
			continue
		var dx: float = cam.unproject_position(views[id].chest()).x - cx
		if signf(dx) == side and absf(dx) < bd:
			bd = absf(dx)
			best = id
	if best:
		_set_target(best, false)

func _check_lock() -> void:
	var v: UnitView = views.get(target_id)
	if v == null or v.dead or not v.is_enemy() or v.position.distance_to(my_pos) > 40.0:
		locked = false
		# Souls hands the lock to the next enemy when the one you held dies, if one is close
		var next := 0
		var bd := 14.0
		for id in views:
			var o: UnitView = views[id]
			if o.is_enemy() and not o.dead and o.flags & 2 != 0 and o.position.distance_to(my_pos) < bd:
				bd = o.position.distance_to(my_pos)
				next = id
		if next:
			locked = true
			_set_target(next, false)
		else:
			_set_target(0, false)

func _capture(on: bool) -> void:
	if Quality.touch:
		return
	captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

## Controller: left stick moves, right stick looks (a flick switches the lock), triggers are edges.
func _pad_poll(delta: float) -> void:
	if Input.get_connected_joypads().is_empty():
		pad_move = Vector2.ZERO
		return
	var lx := Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var ly := Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	pad_move = Vector2(lx, -ly) if Vector2(lx, ly).length() > 0.2 else Vector2.ZERO
	var rx := Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var ry := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if locked:
		if absf(rx) > 0.7 and _pad_flick == 0.0:
			_pad_flick = signf(rx)
			_switch_lock(int(_pad_flick))
		elif absf(rx) < 0.3:
			_pad_flick = 0.0
	else:
		if absf(rx) > 0.15: cam_yaw -= rx * 3.0 * delta
		if absf(ry) > 0.15: cam_pitch = clampf(cam_pitch - ry * 2.0 * delta, -1.2, 0.5)
	var rt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) > 0.5
	if rt and not _pad_rt: _act("heavy")
	_pad_rt = rt
	var lt := Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT) > 0.5
	if lt and not _pad_lt: _act("parry")
	_pad_lt = lt

# ------------------------------------------------------------------ input
## Keyboard and mouse, Souls-style: the mouse is captured and turns the camera.
##   WASD move (relative to the camera)   Space tap roll / hold sprint   LMB light   Shift+LMB heavy
##   RMB hold block   Shift+RMB parry   Q or middle mouse lock on   Tab switch lock   R potion
##   1-5 abilities   F1-F5 party target   E or F loot   Esc free the cursor (click to grab it again)
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = clampf(cam_dist - 0.6, CAM_MIN, CAM_MAX)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = clampf(cam_dist + 0.6, CAM_MIN, CAM_MAX)
		elif not captured:
			# free cursor: click a unit to target it, or click the world to take the camera back
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				var id := unit_at(mb.position)
				if id or chest_at(mb.position):
					_pick(mb.position, false)
					if id and views[id].is_enemy():
						locked = true
				elif not Quality.touch:
					_capture(true)
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_act("heavy" if mb.shift_pressed else "light")
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed and mb.shift_pressed:
				_act("parry")
			elif mb.pressed:
				block_press()
			else:
				block_release()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE and mb.pressed:
			toggle_lock()
	elif e is InputEventMouseMotion and captured:
		_look((e as InputEventMouseMotion).relative)
	elif e is InputEventJoypadButton:
		var jb := e as InputEventJoypadButton
		match jb.button_index:
			JOY_BUTTON_RIGHT_SHOULDER:
				if jb.pressed: _act("light")
			JOY_BUTTON_LEFT_SHOULDER:
				if jb.pressed: block_press()
				else: block_release()
			JOY_BUTTON_B:
				if jb.pressed: dodge_press()
				else: dodge_release()
			JOY_BUTTON_RIGHT_STICK:
				if jb.pressed: toggle_lock()
			JOY_BUTTON_X:
				if jb.pressed: _use("potion")
			JOY_BUTTON_A:
				if jb.pressed and chest and my_pos.distance_to(chest_pos) < 5.0: net.send_loot()
			JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_Y:
				if jb.pressed:
					_use_slot([JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_Y].find(jb.button_index))
	elif e is InputEventKey and not e.echo:
		var k := (e as InputEventKey).physical_keycode
		if k == KEY_SPACE:
			if e.pressed: dodge_press()
			else: dodge_release()
			return
		if not e.pressed:
			return
		if k >= KEY_1 and k <= KEY_5:
			_use_slot(k - KEY_1)
		elif k == KEY_6 or k == KEY_R:
			_use("potion")
		elif k == KEY_Q:
			toggle_lock()
		elif k == KEY_TAB:
			if locked: _switch_lock(-1 if (e as InputEventKey).shift_pressed else 1)
			else: toggle_lock()
		elif k >= KEY_F1 and k <= KEY_F5:
			locked = false
			_party_target(k - KEY_F1)
		elif k == KEY_F or k == KEY_E:
			if chest and my_pos.distance_to(chest_pos) < 5.0:
				net.send_loot()
		elif k == KEY_ESCAPE:
			_capture(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		dodge_down = false
		block_release()

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
	if not captured:
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

## Abilities that need an enemy lock on to one if you have none (see toggle_lock).
func _tab_target() -> void:
	if locked:
		_switch_lock(1)
	else:
		toggle_lock()

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
## Souls-style: over the right shoulder, turned by the mouse or right stick and never swung round for
## you. Locked on, it keeps you and the target in frame. A swept sphere against the camera collision layer
## pulls it in when rock gets in the way (and eases it back out).
func _update_camera(delta: float) -> void:
	var lt: UnitView = views.get(target_id) if locked else null
	if follow_server:
		cam_yaw = lerp_angle(cam_yaw, my_yaw, clampf(delta * 1.5, 0, 1))
	elif lt:
		var to := lt.chest() - (ground(my_pos) + Vector3(0, PIVOT_H, 0))
		var flat := Vector2(to.x, to.z).length()
		cam_yaw = lerp_angle(cam_yaw, atan2(to.x, to.z), clampf(delta * 7.0, 0, 1))
		var want_pitch := clampf(atan2(to.y, maxf(flat, 1.0)) - 0.22, -0.9, 0.25)
		cam_pitch = lerpf(cam_pitch, want_pitch, clampf(delta * 4.0, 0, 1))
	elif recenter:
		cam_yaw = lerp_angle(cam_yaw, my_yaw, clampf(delta * 10.0, 0, 1))
		cam_pitch = lerpf(cam_pitch, -0.2, clampf(delta * 8.0, 0, 1))
		if absf(angle_difference(cam_yaw, my_yaw)) < 0.03:
			recenter = false
	var head := ground(my_pos) + Vector3(0, PIVOT_H, 0)
	var right := Vector3(-cos(cam_yaw), 0, sin(cam_yaw))
	var want_pivot := head + right * _cam_sweep(head, right, SHOULDER, 0.0)
	cam_pivot = want_pivot if cam_pivot == Vector3.INF else cam_pivot.lerp(want_pivot, clampf(delta * 14.0, 0, 1))
	cam_zoom = move_toward(cam_zoom, cam_dist, delta * maxf(6.0, absf(cam_dist - cam_zoom) * 6.0))
	var dir := Vector3(-sin(cam_yaw) * cos(cam_pitch), -sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))
	var allowed := _cam_sweep(cam_pivot, dir, cam_zoom)
	cam_cur_dist = allowed if allowed < cam_cur_dist else move_toward(cam_cur_dist, allowed, delta * 5.0)
	var pos := cam_pivot + dir * cam_cur_dist
	if shake_amt > 0:
		pos += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake_amt * 0.25
		shake_amt = maxf(0.0, shake_amt - delta * 2.5)
	cam.look_at_from_position(pos, cam_pivot - dir * 4.0)
	if me:
		me.model.visible = cam_cur_dist > 1.3
	_update_lock_dot(lt)

## A small glowing dot on the locked target's chest, drawn over everything.
func _update_lock_dot(lt: UnitView) -> void:
	if lock_dot == null:
		lock_dot = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.14
		sm.height = 0.28
		lock_dot.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1, 0.92, 0.75)
		m.no_depth_test = true
		m.disable_fog = true
		m.render_priority = 10
		lock_dot.material_override = m
		add_child(lock_dot)
	lock_dot.visible = lt != null
	if lt:
		lock_dot.global_position = lt.chest()

const PIVOT_H := 1.85
const SHOULDER := 0.75 # camera sits this far right of your head
var recenter := false
const CAM_RADIUS := 0.3
var cam_pivot := Vector3.INF
var cam_zoom := 5.2
var _cam_shape: SphereShape3D

## How far the camera can sit from the pivot along dir: a sphere swept against collision layer 2.
func _cam_sweep(pivot: Vector3, dir: Vector3, dist: float, min_d := 0.4) -> float:
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
	return clampf(minf(d, floor_t), min_d, dist)

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
	l.font_size = 40 if text.ends_with("!") else 30
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

# ------------------------------------------------------------------ attack readability
## A fan on the ground in front of a winding-up enemy, filling red until the blow lands, a glint on it
## just before the strike, and the enemy itself glowing hotter (UnitView.wind_up).
func _wind(id: int, dur: float, reach: float, arc: float, big: bool) -> void:
	var v: UnitView = views.get(id)
	if v == null or v.dead:
		return
	_end_wind(id)
	var mi := MeshInstance3D.new()
	mi.mesh = _fan_mesh(0.6, reach, arc, 18, false)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_fog = true
	m.no_depth_test = false
	m.albedo_color = Color(0.95, 0.12, 0.05, 0.0)
	mi.material_override = m
	add_child(mi)
	v.wind_up(dur)
	winds[id] = { "node": mi, "mat": m, "dur": dur, "t": 0.0, "glint": false, "big": big }
	_place_wind(v, mi)

func _place_wind(v: UnitView, mi: Node3D) -> void:
	mi.global_position = v.global_position + Vector3(0, 0.09, 0)
	mi.rotation.y = v.yaw

func _end_wind(id: int) -> void:
	var w = winds.get(id)
	if w:
		w.node.queue_free()
		winds.erase(id)
	var v: UnitView = views.get(id)
	if v:
		v.windup = 0.0

## A bright arc where a weapon just went: in front of the attacker, chest high, sweeping and fading.
func _swoosh(v: UnitView, yaw: float, reach: float, arc: float, heavy: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _fan_mesh(reach * 0.45, reach * (1.1 if heavy else 1.0), arc, 20, true)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_fog = true
	var col := Color(1, 0.7, 0.3) if heavy else Color(1, 1, 0.95)
	if v.is_enemy():
		col = Color(1, 0.45, 0.3)
	m.albedo_color = Color(col, 0.9)
	mi.material_override = m
	add_child(mi)
	mi.global_position = v.global_position + Vector3(0, v.height() * (0.42 if heavy else 0.5), 0)
	mi.rotation = Vector3(0.2 if heavy else -0.15, yaw, 0.0) # heavy blows come down, light ones across
	var dur := 0.3 if heavy else 0.22
	var tw := create_tween()
	tw.set_parallel()
	tw.tween_property(m, "albedo_color:a", 0.0, dur).set_ease(Tween.EASE_IN)
	tw.tween_property(mi, "rotation:y", yaw - 0.35, dur)
	tw.chain().tween_callback(mi.queue_free)

## A struck unit: flash, knockback and hitstop on the views, a shake if it involves you, and a sound.
func _hurt(id: int, src_id: int, kind: String, heavy: bool) -> void:
	var v: UnitView = views.get(id)
	if v == null:
		return
	var src: UnitView = views.get(src_id)
	var from := src.global_position if src else v.global_position - Vector3(sin(v.yaw), 0, cos(v.yaw))
	v.struck(kind, from, heavy)
	if src and kind in ["hit", "block"]:
		src.freeze = maxf(src.freeze, 0.11 if heavy else 0.065)
	var at := v.chest()
	match kind:
		"hit":
			sfx.play("heavy_hit" if heavy else "hit", at)
			if id == me_id:
				shake_amt = maxf(shake_amt, 0.45 if heavy else 0.25)
			elif src_id == me_id:
				shake_amt = maxf(shake_amt, 0.22 if heavy else 0.1)
		"block":
			sfx.play("block", at)
			_burst(at + (from - v.global_position).normalized() * 0.5, Color(1, 0.9, 0.6), 14, 4.0, 4.0, 0.15, 0.3)
			if id == me_id:
				shake_amt = maxf(shake_amt, 0.18)
		"parry":
			sfx.play("parry", at, 3.0)
			_flash(at, Color(1, 0.9, 0.5), 4.0, 0.3, 10.0)
			_ring(v.global_position + Vector3(0, 1.2, 0), Color(1, 0.85, 0.4), 3.0)
			shake_amt = maxf(shake_amt, 0.3)
		"dodge":
			sfx.play("roll", at, -10.0, 1.4)

## A flat fan (a slice of a ring) facing +z, spanning +-arc. trail=true fades it in along the sweep.
static func _fan_mesh(r_in: float, r_out: float, arc: float, segs: int, trail: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segs:
		var a0 := -arc + 2.0 * arc * i / segs
		var a1 := -arc + 2.0 * arc * (i + 1) / segs
		var k0 := float(i) / segs if trail else 1.0
		var k1 := float(i + 1) / segs if trail else 1.0
		var p := [Vector3(sin(a0), 0, cos(a0)) * r_in, Vector3(sin(a0), 0, cos(a0)) * r_out,
			Vector3(sin(a1), 0, cos(a1)) * r_in, Vector3(sin(a1), 0, cos(a1)) * r_out]
		# the outer edge glows brightest, the inner fades out
		var c := [Color(1, 1, 1, k0 * 0.25), Color(1, 1, 1, k0), Color(1, 1, 1, k1 * 0.25), Color(1, 1, 1, k1)]
		for q in [0, 1, 2, 2, 1, 3]:
			st.set_color(c[q])
			st.add_vertex(p[q])
	return st.commit()

func _update_winds(delta: float) -> void:
	for id in winds.keys():
		var w: Dictionary = winds[id]
		var v: UnitView = views.get(id)
		if v == null or v.dead or v.flags & 4 != 0:
			_end_wind(id)
			continue
		w.t += delta
		var k := clampf(w.t / w.dur, 0.0, 1.0)
		(w.mat as StandardMaterial3D).albedo_color.a = 0.2 + 0.55 * k * k
		w.node.global_position = v.global_position + Vector3(0, 0.09, 0)
		if not w.glint and k > 0.7:
			# the tell: a glint on the weapon arm a beat before it falls
			w.glint = true
			var hand := v.global_position + Vector3(sin(v.yaw) * 0.5 - cos(v.yaw) * 0.6, v.height() * 0.85, cos(v.yaw) * 0.5 + sin(v.yaw) * 0.6)
			_burst(hand, Color(1, 0.95, 0.8), 10, 1.5, 0.0, 0.35, 0.25)
			_flash(hand, Color(1, 0.6, 0.3), 2.5, 0.2, 6.0)
			sfx.play("glint", hand, -2.0)
		if w.t > w.dur + 0.3:
			_end_wind(id)

func _update_teles_projs(delta: float) -> void:
	_update_winds(delta)
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
