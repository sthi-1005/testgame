extends SceneTree
## Souls-style controls test: starts a solo run, drives keyboard, mouse and pad input, and checks the
## client and the sim both did the right thing (camera-relative movement, roll i-frames, sprint, lock-on,
## light/heavy attacks, block, parry, stamina).
## godot --headless --path . -s tools/souls_test.gd -- --class sellsword [--stage id]

var fails := 0
var game: Game

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

func _key(k: Key, down: bool, shift := false) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = down
	e.shift_pressed = shift
	Input.parse_input_event(e)

func _mouse(b: MouseButton, down: bool, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = b
	e.pressed = down
	e.shift_pressed = shift
	e.position = Vector2(400, 300)
	Input.parse_input_event(e)

func _motion(rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.relative = rel
	e.position = Vector2(400, 300)
	Input.parse_input_event(e)

## Put the player next to an enemy, facing it, and park the enemy so it doesn't fight back.
func _beside(e: SUnit, su: SUnit) -> void:
	var p := e.pos + Vector3(2.4, 0, 0)
	game.my_pos = p
	su.pos = p
	game.my_yaw = atan2(e.pos.x - p.x, e.pos.z - p.z)
	su.yaw = game.my_yaw
	game.net.send_move(p, game.my_yaw, 0.0)

func _run() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in 600:
		await process_frame
		game = main.get("game")
		if game and game.me and game.state == "play":
			break
	_check(game != null and game.me != null, "solo run started")
	var sim: Sim = game.net.sim
	var su: SUnit = sim.players.values()[0]
	_check(su.souls, "the player's unit uses Souls-style actions (no auto attack)")
	await _frames(10)
	_check(game.captured or DisplayServer.get_name() == "headless", "mouse captured for the camera")
	game.captured = true # headless has no real pointer lock

	# camera-relative movement: turn the camera with the mouse, then W runs the way it faces
	_motion(Vector2(220, 0))
	await _frames(2)
	var cf := Vector3(sin(game.cam_yaw), 0, cos(game.cam_yaw))
	var start := game.my_pos
	_key(KEY_W, true)
	await _frames(30)
	_key(KEY_W, false)
	var moved := game.my_pos - start
	_check(moved.length() > 2.0 and moved.normalized().dot(cf) > 0.9, "W ran %.1f m along the camera (dot %.2f)" % [moved.length(), moved.normalized().dot(cf)])
	_check(absf(angle_difference(game.my_yaw, game.cam_yaw)) < 0.3, "the character turned to face where it runs")
	start = game.my_pos
	_key(KEY_D, true)
	await _frames(20)
	_key(KEY_D, false)
	var cr := Vector3(-cf.z, 0, cf.x)
	moved = game.my_pos - start
	_check(moved.normalized().dot(cr) > 0.9, "D ran to the camera's right (dot %.2f)" % moved.normalized().dot(cr))
	await _frames(30)

	# roll: tap Space while moving; the server opens i-frames and a hit passes through
	var hp0 := su.hp
	_key(KEY_W, true)
	await _frames(3)
	_key(KEY_SPACE, true)
	await _frames(2)
	_key(KEY_SPACE, false)
	await _frames(3)
	_check(game.roll_t > 0 and su.iframe > 0, "Space tap rolled (client %.2f, server i-frames %.2f)" % [game.roll_t, su.iframe])
	var foe: SUnit = null
	for e in sim.enemies:
		if e.alive() and e.boss == "" and (foe == null or sim._d(e.pos, su.pos) < sim._d(foe.pos, su.pos)):
			foe = e
	var dealt := sim.deal_damage(foe, su, 30, { "melee": true, "crit": 0.0 })
	_check(dealt == 0 and su.hp == hp0, "a blow during the roll was dodged")
	_check(su.stam < D.STAMINA, "the roll cost stamina (%.0f left)" % su.stam)
	await _frames(40)
	_key(KEY_W, false)

	# sprint: hold Space while moving
	await _frames(30)
	start = game.my_pos
	_key(KEY_W, true)
	_key(KEY_SPACE, true)
	await _frames(40)
	_check(game.sprinting and su.sprinting, "holding Space sprints")
	var s0 := su.stam
	await _frames(20)
	_check(su.stam < s0, "sprinting drains stamina (%.0f -> %.0f)" % [s0, su.stam])
	_key(KEY_SPACE, false)
	_key(KEY_W, false)
	await _frames(3)
	_check(not game.sprinting and not su.sprinting and game.roll_t <= 0, "releasing a held Space stops the sprint without a roll")

	# lock on (Q) to the enemy next to us; the camera turns to frame it
	su.stam = D.STAMINA
	if not foe.alive() or foe.max_hp < 150:
		for e in sim.enemies:
			if e.alive() and e.boss == "" and e.max_hp >= 150:
				foe = e
				break
	foe.hp = foe.max_hp
	_beside(foe, su)
	foe.stun = 30.0 # hold it still for the attack checks
	await _frames(5)
	game.cam_yaw = game.my_yaw + 0.7
	await _frames(2)
	_key(KEY_Q, true)
	_key(KEY_Q, false)
	await _frames(40)
	_check(game.locked and game.target_id != 0 and game.views[game.target_id].is_enemy(), "Q locked on to %s" % (game.views[game.target_id].info.name if game.target_id else "nothing"))
	var lt: UnitView = game.views.get(game.target_id)
	if lt:
		var want := atan2(lt.position.x - game.my_pos.x, lt.position.z - game.my_pos.z)
		_check(absf(angle_difference(game.cam_yaw, want)) < 0.35, "the camera swung round to the locked target")
	# lock on to the parked enemy for the attack checks
	game._set_target(foe.id, false)
	game.locked = true
	await _frames(5)

	# light attack: LMB, the blow lands after the wind-up
	var ehp := foe.hp
	s0 = su.stam
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(20)
	_check(foe.hp < ehp, "LMB light attack hit %s (%.0f -> %.0f)" % [foe.name, ehp, foe.hp])
	_check(su.stam < s0, "the attack cost stamina")
	# a second press during the swing is buffered and fires when it ends
	ehp = foe.hp
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(4)
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(70)
	_check(foe.hp < ehp and game.buffered == "", "a buffered second swing came out too")
	await _frames(20)
	# basic attacks don't root you: walk while swinging
	su.stam = D.STAMINA
	game.act_lock = 0
	await _frames(30)
	start = game.my_pos
	_key(KEY_S, true)
	await _frames(2)
	_mouse(MOUSE_BUTTON_LEFT, true)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(20)
	_check(game.act_lock > 0 and (game.my_pos - start).length() > 1.0, "kept moving through a light attack (%.1f m)" % (game.my_pos - start).length())
	_key(KEY_S, false)
	_beside(foe, su)
	await _frames(40)
	# heavy: Shift+LMB
	su.stam = D.STAMINA
	foe.hp = foe.max_hp
	ehp = foe.hp
	_mouse(MOUSE_BUTTON_LEFT, true, true)
	_mouse(MOUSE_BUTTON_LEFT, false, true)
	await _frames(45)
	_check(foe.hp < ehp and su.stam <= D.STAMINA - D.ACTS.heavy.cost + 1, "Shift+LMB heavy attack hit for %.0f (%s alive %s)" % [ehp - foe.hp, foe.name, foe.alive()])
	await _frames(40)

	# block: hold RMB, a frontal blow mostly stopped at a stamina cost
	foe.stun = 0
	su.stam = D.STAMINA
	su.yaw = atan2(foe.pos.x - su.pos.x, foe.pos.z - su.pos.z)
	_mouse(MOUSE_BUTTON_RIGHT, true)
	await _frames(3)
	_check(su.blocking, "RMB raises the guard")
	hp0 = su.hp
	su.absorb = 0 # an AI cleric's ward would soak the test blows
	dealt = sim.deal_damage(foe, su, 40, { "melee": true, "crit": 0.0 })
	_check(dealt > 0 and dealt <= sim.mitigate(su, 40) * (1.0 - su.guard) + 1 and su.stam < D.STAMINA, "a blocked blow did %.0f and cost %.0f stamina" % [dealt, D.STAMINA - su.stam])
	su.stam = 1.0
	su.absorb = 0
	dealt = sim.deal_damage(foe, su, 40, { "melee": true, "crit": 0.0 })
	_check(su.stun > 0 and not su.blocking and dealt > 15, "with no stamina left the guard breaks")
	_mouse(MOUSE_BUTTON_RIGHT, false)
	su.stun = 0
	su.act_lock = 0
	game.act_lock = 0
	await _frames(40)

	# parry: Shift+RMB opens a short window that staggers the attacker
	su.stam = D.STAMINA
	game.my_yaw = atan2(foe.pos.x - su.pos.x, foe.pos.z - su.pos.z)
	_mouse(MOUSE_BUTTON_RIGHT, true, true)
	_mouse(MOUSE_BUTTON_RIGHT, false, true)
	await _frames(2)
	foe.stun = 0
	hp0 = su.hp
	dealt = sim.deal_damage(foe, su, 40, { "melee": true, "crit": 0.0 })
	_check(dealt == 0 and foe.stun > 1.0 and foe.vuln > 0, "Shift+RMB parried the blow (attacker stunned %.1f s)" % foe.stun)
	await _frames(30)

	# no stamina, no action
	su.stam = 0
	game.act_lock = 0
	await _frames(2)
	game._act("light")
	_check(game.act_lock == 0 and not sim.act(su, "light", su.yaw), "no attack with an empty stamina bar")
	su.stam = D.STAMINA
	await _frames(5)

	# Tab moves the lock, Q lets go
	_key(KEY_Q, true)
	_key(KEY_Q, false)
	await _frames(2)
	_check(not game.locked, "Q again releases the lock")

	# enemy wind-up: an enemy swing can be stepped out of before it lands
	if not foe.alive():
		for e in sim.enemies:
			if e.alive() and e.boss == "" and e.fly == 0.0:
				foe = e
				break
	foe.hp = foe.max_hp
	foe.stun = 0
	foe.busy = 0
	foe.swing = 0
	foe.target = su
	foe.engaged = true
	foe.threat[su.id] = 999.0
	su.hp = su.max_hp
	_beside(foe, su)
	foe.face_to(su.pos)
	var seq := foe.act_seq
	for i in 120:
		await physics_frame
		if foe.act_seq != seq:
			break
	_check(foe.act_seq != seq, "%s started a swing (alive %s, dist %.1f, swing %.1f)" % [foe.name, foe.alive(), foe.dist_to(su), foe.swing])
	hp0 = su.hp
	# run straight away from it during the wind-up
	var away := (su.pos - foe.pos).normalized()
	for i in 12:
		game.my_pos = game.my_pos + away * 0.6
		game.net.send_move(game.my_pos, game.my_yaw, 1.0 / 30.0)
		await physics_frame
	await _frames(20)
	_check(su.hp == hp0, "stepping out during the wind-up avoided the hit (hp %.0f -> %.0f)" % [hp0, su.hp])

	print("souls test: %d failure(s)" % fails)
	quit(1 if fails else 0)
