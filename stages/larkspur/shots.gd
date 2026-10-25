extends SceneTree
## Review stills of Larkspur Vale with the party and enemies posed.
## xvfb-run -a godot --path . --rendering-driver opengl3 -s stages/larkspur/shots.gd -- [suffix] [only]
func _init():
	await process_frame
	var a := OS.get_cmdline_user_args()
	var suffix: String = a[0] if a.size() > 0 else ""
	var only: String = a[1] if a.size() > 1 else ""
	var root := Node3D.new(); get_root().add_child(root)
	var t0 := Time.get_ticks_msec()
	var lv := Stages.make_level("larkspur")
	var t1 := Time.get_ticks_msec()
	var wb := Stages.make_world("larkspur", lv, root)
	wb.build()
	print("level %d ms, world %d ms, decor %d" % [t1 - t0, Time.get_ticks_msec() - t1, lv.decor.size()])
	var we := WorldEnvironment.new(); we.environment = wb.make_environment(); root.add_child(we)
	var cam := Camera3D.new(); cam.fov = 60; cam.far = 900; root.add_child(cam)
	var T := Level.T
	var C := func(cx: float, cz: float, up: float) -> Vector3:
		var p := Level.W(cx - 0.5, cz - 0.5)
		return Vector3(p.x, lv.floor_y(p.x, p.z) + up, p.z)
	var shots := [
		# name, camera, look at, units [body, cell x, cell z, yaw, anim]
		["vista", C.call(16.6, 49.5, 3.4), C.call(18.0, 30.0, 3.0), [["sellsword", 16.4, 46.6, PI, "run"], ["cleric", 15.6, 47.4, PI, "run"], ["mage", 17.3, 47.6, PI, "run"]]],
		["camp", C.call(19.8, 35.0, 4.0), C.call(18.0, 25.0, 2.5), [["sellsword", 20.0, 30.6, PI, "attack"], ["cleric", 19.0, 32.4, PI + 0.3, "cast"], ["mage", 21.2, 32.8, PI - 0.3, "cast"],
			["footpad", 19.6, 29.4, 0.2, "attack"], ["footpad", 21.4, 29.2, -0.4, "combatIdle"], ["miner", 21.0, 27.6, 0.0, "run"]]],
		["keep", C.call(52.5, 15.3, 6.0), C.call(50.5, 7.0, 2.0), [["gorrak", 51.0, 9.0, 0.0, "smash"], ["sellsword", 51.2, 10.6, PI, "attack"], ["cleric", 49.2, 13.4, PI + 0.4, "cast"], ["mage", 53.4, 13.8, PI - 0.4, "cast"], ["bat", 47.0, 10.0, 1.0, "idle"]]],
		["overview", C.call(40.0, 31.0, 14.0), C.call(18.0, 36.0, 0.0), []],
		["fromkeep", C.call(51.5, 12.5, 10.0), C.call(30.0, 45.0, 0.0), [["sellsword", 49.6, 17.6, PI * 0.8, "idle"], ["mage", 50.6, 17.9, PI * 0.8, "idle"], ["cleric", 50.0, 18.6, PI * 0.8, "idle"]]],
	]
	for s in shots:
		if only != "" and s[0] != only:
			continue
		var holder := Node3D.new(); root.add_child(holder)
		for u in s[3]:
			var c := Assets.character(u[0])
			var n: Node3D = c.root
			holder.add_child(n)
			var p := Level.W(u[1] - 0.5, u[2] - 0.5)
			n.position = Vector3(p.x, lv.floor_y(p.x, p.z) + (3.0 if u[0] == "bat" else 0.0), p.z)
			n.rotation.y = u[3]
			c.anim.play(u[4]); c.anim.seek(0.35, true)
		cam.look_at_from_position(s[1], s[2])
		for k in 8: await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("user://lark_%s%s.png" % [s[0], suffix])
		print("saved ", s[0])
		holder.queue_free()
	quit()
