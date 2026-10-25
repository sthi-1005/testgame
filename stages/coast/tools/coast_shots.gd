extends SceneTree
## Review stills of Tidecrown Ruins with the party and enemies posed.
## godot --path . --rendering-driver vulkan -s stages/coast/tools/coast_shots.gd -- [suffix] [only]
func _init():
	await process_frame
	var args := OS.get_cmdline_user_args()
	var suffix: String = args[0] if args.size() > 0 else ""
	var only: String = args[1] if args.size() > 1 else ""
	var root := Node3D.new(); get_root().add_child(root)
	var lv := CoastLevel.new()
	var wb := CoastWorld.new(lv, root)
	wb.build()
	var we := WorldEnvironment.new(); we.environment = wb.make_environment(); root.add_child(we)
	var pool := WorldBuilder.LightPool.new(root, wb.light_sources, 6)
	var cam := Camera3D.new(); cam.fov = 60; cam.far = 1500; root.add_child(cam)
	var T := Level.T
	var C := func(x, z, y := 0.0): return Vector3(x * T, y, z * T)
	var shots := [
		# name, grade, tide, camera pos, look at, units [body, cell x, cell z, yaw, anim]
		["landing", 0.0, -0.25, C.call(29.6, 43.2, 5.5), C.call(27.0, 33.0, 1.5),
			[["sellsword", 29.4, 40.0, PI, "run"], ["cleric", 28.6, 40.8, PI, "run"], ["mage", 30.3, 40.9, PI, "run"], ["coast_gull", 30.0, 37.5, 0.2, "idle"], ["coast_gull", 31.4, 37.0, 0.5, "idle"]]],
		["strand", 0.0, -0.25, C.call(27.5, 34.5, 6.0), C.call(20.0, 28.0, 0.5),
			[["sellsword", 24.0, 31.6, -2.4, "attack"], ["mage", 26.2, 33.4, -2.2, "cast"], ["cleric", 25.4, 33.9, -2.5, "cast"],
			 ["coast_raider", 22.0, 29.0, 0.8, "attack"], ["coast_raider", 24.5, 29.4, -0.6, "combatIdle"], ["coast_tidecaller", 23.2, 28.2, 0.4, "cast"]]],
		["colonnade", 0.0, -0.25, C.call(35.0, 26.5, 5.0), C.call(35.0, 12.0, 4.0),
			[["sellsword", 35.0, 22.5, PI, "run"], ["cleric", 34.2, 23.6, PI, "run"], ["mage", 35.9, 23.7, PI, "run"],
			 ["coast_sentry", 33.0, 20.5, 0.0, "combatIdle"], ["coast_sentry", 37.0, 20.5, 0.0, "combatIdle"], ["coast_corsair", 35.5, 12.8, 0.0, "idle"]]],
		["vista", 0.0, -0.25, C.call(29.0, 18.0, 9.0), C.call(8.0, 14.0, 0.0),
			[["sellsword", 27.6, 15.2, -PI / 2, "run"], ["cleric", 28.4, 16.2, -PI / 2, "run"], ["mage", 28.3, 14.6, -PI / 2, "run"]]],
		["overview", 0.0, -0.25, Vector3(-60, 150, 250), Vector3(95, 0, 95), []],
		["sanctum", 1.0, -0.25, C.call(17.6, 15.2, 6.5), C.call(8.5, 15.9, 2.0),
			[["coast_ondrak", 8.5, 16.0, PI / 2, "idle"], ["sellsword", 10.6, 16.0, -PI / 2, "attack"], ["cleric", 13.2, 18.2, -2.2, "cast"], ["mage", 12.8, 12.6, -1.0, "cast"]]],
		["tide", 1.0, 0.32, C.call(16.0, 9.0, 9.0), C.call(8.5, 16.0, 0.0),
			[["coast_ondrak", 8.5, 16.6, 0.3, "smash"], ["sellsword", 8.4, 14.2, 0.0, "combatIdle"], ["cleric", 12.8, 11.9, -2.0, "cast"], ["mage", 4.2, 11.9, 2.2, "cast"], ["coast_brineling", 10.0, 13.0, 0.0, "idle"], ["coast_brineling", 6.0, 19.0, 0.0, "idle"]]],
	]
	for s in shots:
		if only != "" and s[0] != only:
			continue
		var holder := Node3D.new(); root.add_child(holder)
		for u in s[5]:
			var c := Assets.character(u[0])
			var n: Node3D = c.root
			holder.add_child(n)
			var fly: float = lv.enemy_def({"coast_gull": "gull", "coast_brineling": "brineling"}.get(u[0], "raider")).get("fly", 0.0)
			var p := Vector3(u[1] * T, 0, u[2] * T)
			p.y = lv.floor_y(p.x, p.z) + fly
			n.position = p
			n.rotation.y = u[3]
			c.anim.play(u[4]); c.anim.seek(0.35, true)
		CoastLook.grade(we.environment, s[1])
		wb.set_tide(s[2])
		cam.look_at_from_position(s[3], s[4])
		pool.update(s[3].lerp(s[4], 0.5), 0.0)
		for k in 8: await process_frame
		await RenderingServer.frame_post_draw
		var path := "user://coast_%s%s.png" % [s[0], suffix]
		get_root().get_texture().get_image().save_png(path)
		print("saved ", ProjectSettings.globalize_path(path))
		holder.queue_free()
	print("ALLDONE")
	quit()
