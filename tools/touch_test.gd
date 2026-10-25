extends SceneTree
## Touch controls test: starts a solo run with the touch layer on, plays fingers on the screen, and
## checks each control did its job. With a renderer it also saves a phone-sized still.
## xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 --resolution 1688x780 \
##   -s tools/touch_test.gd -- --class sellsword --phone --quality mobile [--shot user://touch.png]

var fails := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

func _touch(i: int, at: Vector2, down: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = i
	e.position = at
	e.pressed = down
	root.push_input(e, true) # positions are in the HUD's logical coordinates

func _drag(i: int, from: Vector2, to: Vector2, steps := 6) -> void:
	for k in steps:
		var e := InputEventScreenDrag.new()
		e.index = i
		var a := from.lerp(to, float(k) / steps)
		var b := from.lerp(to, float(k + 1) / steps)
		e.position = b
		e.relative = b - a
		root.push_input(e, true) # positions are in the HUD's logical coordinates
		await process_frame

func _run() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	var game: Game
	for i in 600:
		await process_frame
		game = main.get("game")
		if game and game.me and game.state == "play" and not game.hud.slots.is_empty():
			break
	_check(game != null and game.me != null, "solo run started")
	var tc: TouchControls = null
	for c in game.get_children():
		if c is TouchControls:
			tc = c
	_check(tc != null, "touch layer added")
	await _frames(10)
	var view: Vector2 = tc.root.get_viewport_rect().size
	print("window %s  content scale %.2f  logical view %s  phone=%s" % [root.size, root.content_scale_factor, view, Quality.phone])
	_check(view.y < 700 and view.y > 450, "HUD scaled up for a phone (logical height %d)" % view.y)
	_check(not Input.emulate_mouse_from_touch, "mouse emulation off during play")
	var bar_rect: Rect2 = (game.hud.slots[0].panel as Control).get_parent().get_global_rect()
	_check(bar_rect.end.x <= view.x + 1 and bar_rect.position.x > view.x * 0.5 and bar_rect.end.y <= view.y + 1, "hotbar at bottom-right %s" % bar_rect)

	# thumbstick: push up, the unit should run away from the camera
	var start := game.my_pos
	var stick := Vector2(160, view.y - 160)
	_touch(0, stick, true)
	await _drag(0, stick, stick + Vector2(0, -90))
	_check(game.touch_move.y > 0.9, "stick up gives forward %.2f" % game.touch_move.y)
	await _frames(30)
	var cf := Vector3(sin(game.cam_yaw), 0, cos(game.cam_yaw))
	var moved := game.my_pos - start
	_check(moved.length() > 1.0 and moved.normalized().dot(cf) > 0.7, "unit ran %.1f m along the camera's forward (dot %.2f)" % [moved.length(), moved.normalized().dot(cf)])

	# second finger taps a hotbar slot while the stick is held (an instant ability, so moving is fine)
	var slot := -1
	for i in game.hud.slots.size():
		if float(game.hud.slots[i].ab.get("cast", 0)) == 0.0 and game.hud.slots[i].id != "potion":
			slot = i
			break
	var p := game.hud.slots[slot].panel as Control
	var flashed := false
	game.hud.slots[slot].flash = 0.0
	_touch(1, p.get_global_rect().get_center(), true)
	flashed = float(game.hud.slots[slot].flash) > 0.0
	_touch(1, p.get_global_rect().get_center(), false)
	_check(flashed, "tapping slot %d (%s) with a second finger used it" % [slot, game.hud.slots[slot].id])
	_touch(0, stick + Vector2(0, -90), false)
	await process_frame
	_check(game.touch_move == Vector2.ZERO, "stick released")

	# camera drag on the right half
	var yaw := game.cam_yaw
	var r := Vector2(view.x * 0.6, view.y * 0.4)
	_touch(2, r, true)
	await _drag(2, r, r + Vector2(160, 0))
	_touch(2, r + Vector2(160, 0), false)
	_check(absf(angle_difference(yaw, game.cam_yaw)) > 0.5, "drag turned the camera %.2f rad" % angle_difference(yaw, game.cam_yaw))

	# pinch out to zoom in
	var dist := game.cam_dist
	var c := Vector2(view.x * 0.62, view.y * 0.45)
	_touch(3, c - Vector2(40, 0), true)
	_touch(4, c + Vector2(40, 0), true)
	await _drag(4, c + Vector2(40, 0), c + Vector2(160, 0))
	_touch(4, c + Vector2(160, 0), false)
	_touch(3, c - Vector2(40, 0), false)
	_check(game.cam_dist < dist - 1.0, "pinch zoomed in %.1f -> %.1f" % [dist, game.cam_dist])

	# Target button picks the nearest enemy (stand next to one for the press)
	game._set_target(0, false)
	var foe: UnitView = null
	for v in game.views.values():
		if v.is_enemy() and not v.dead and (foe == null or v.position.distance_to(game.my_pos) < foe.position.distance_to(game.my_pos)):
			foe = v
	var keep := game.my_pos
	game.my_pos = foe.position + Vector3(1.5, 0, 0)
	var tb := tc.target_btn.get_global_rect().get_center()
	_touch(5, tb, true)
	_touch(5, tb, false)
	game.my_pos = keep
	_check(game.target_id != 0 and game.views[game.target_id].is_enemy() and game.locked, "Lock button locked on to enemy %d" % game.target_id)
	_touch(5, tb, true)
	_touch(5, tb, false)
	_check(not game.locked, "Lock again lets go")

	# action pad: Attack, Roll (tap), Block (hold)
	var pad := {}
	for b in tc.buttons:
		pad[(b.node as Button).text] = (b.node as Control).get_global_rect().get_center()
	_touch(7, pad["Attack"], true)
	_touch(7, pad["Attack"], false)
	_check(game.act_lock > 0, "Attack button swung (lock %.2f)" % game.act_lock)
	await _frames(40)
	_touch(7, pad["Roll"], true)
	await _frames(2)
	_touch(7, pad["Roll"], false)
	_check(game.roll_t > 0, "Roll tap dodged")
	await _frames(40)
	_touch(8, pad["Block"], true)
	await _frames(4)
	var su: SUnit = game.net.sim.players[1] if game.net.get("sim") else null
	_check(game.blocking and (su == null or su.blocking), "Block held raises the guard")
	_touch(8, pad["Block"], false)
	await _frames(2)
	_check(not game.blocking and (su == null or not su.blocking), "Block released lowers it")

	# tap a party member on screen to target them
	var ally := 0
	for v in game.party_views():
		if v.id != game.me_id and not game.cam.is_position_behind(v.global_position):
			ally = v.id
			var at := game.cam.unproject_position(v.global_position + Vector3(0, v.height() * 0.5, 0))
			var covered := false
			for bt in tc.buttons:
				if (bt.node as Control).is_visible_in_tree() and (bt.node as Control).get_global_rect().grow(8).has_point(at):
					covered = true
			if not covered and Rect2(Vector2(view.x * 0.42, 0), view - Vector2(view.x * 0.42, 0)).has_point(at):
				_touch(6, at, true)
				_touch(6, at, false)
				await process_frame
				_check(game.target_id == ally, "tap on %s targeted them (got %d)" % [v.info.name, game.target_id])
				break
	if ally == 0:
		print("skip tap-to-target: no ally in the right half of the screen")

	var shot := ""
	var args := OS.get_cmdline_user_args()
	var k := args.find("--shot")
	if k >= 0 and k + 1 < args.size():
		shot = args[k + 1]
	if shot != "" and DisplayServer.get_name() != "headless":
		game.cam_dist = 11.0
		_touch(0, stick, true)
		await _drag(0, stick, stick + Vector2(50, -60))
		await _frames(20)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(shot)
		print("saved ", ProjectSettings.globalize_path(shot))
	print("touch test: %d failure(s)" % fails)
	quit(1 if fails else 0)
