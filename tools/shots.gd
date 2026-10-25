extends SceneTree
## Renders still shots of the dungeon with the party and enemies posed, for review.
## godot --path . --rendering-driver vulkan -s tools/shots.gd -- [suffix]
func _init():
	await process_frame
	var suffix: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() else ""
	var root := Node3D.new(); get_root().add_child(root)
	var lv := Level.new()
	var wb := WorldBuilder.new(lv, root)
	wb.build()
	var we := WorldEnvironment.new(); we.environment = Look.make_environment(); root.add_child(we)
	var pool := WorldBuilder.LightPool.new(root, wb.light_sources, 8)
	var cam := Camera3D.new(); cam.fov = 62; cam.far = 300; root.add_child(cam)
	var dust := WorldBuilder.dust_motes(); root.add_child(dust)
	var T := Level.T
	var shots := [
		# name, grade, camera pos, look at, units [body, cell x, cell z, yaw, anim]
		["tunnel", 0.0, Vector3(3.95 * T, 3.4, 25.3 * T), Vector3(3.9 * T, 2.0, 19 * T), [["sellsword", 3.75, 23.4, PI, "run"], ["cleric", 3.4, 24.2, PI, "run"], ["mage", 4.35, 24.4, PI, "run"]]],
		["diggings", 0.0, Vector3(4.9 * T, 3.6, 13.9 * T), Vector3(5 * T, 1.4, 9.5 * T), [["sellsword", 4.8, 12.0, PI, "combatIdle"], ["cleric", 4.0, 13.0, PI, "cast"], ["mage", 5.8, 13.1, PI, "cast"], ["footpad", 4.2, 11.2, 0.0, "attack"], ["miner", 5.2, 10.8, 0.2, "combatIdle"]]],
		["hall", 1.0, Vector3(24.6 * T, 4.8, 11.6 * T), Vector3(28.5 * T, 2.0, 6.5 * T), [["gorrak", 28.5, 6.5, -2.4, "smash"], ["sellsword", 27.6, 7.5, 0.7, "attack"], ["cleric", 25.9, 9.8, 0.8, "cast"], ["mage", 26.6, 10.4, 0.6, "cast"], ["bat", 27.0, 8.6, 1.0, "idle"]]],
	]
	for s in shots:
		var holder := Node3D.new(); root.add_child(holder)
		for u in s[4]:
			var c := Assets.character(u[0])
			var n: Node3D = c.root
			holder.add_child(n)
			n.position = Vector3(u[1] * T, 2.4 if u[0] == "bat" else 0.0, u[2] * T)
			n.rotation.y = u[3]
			c.anim.play(u[4]); c.anim.seek(0.35, true)
		Look.grade(we.environment, s[1])
		cam.look_at_from_position(s[2], s[3])
		dust.global_position = s[2].lerp(s[3], 0.4)
		dust.restart()
		pool.update(s[2].lerp(s[3], 0.5), 0.0)
		for k in 12: await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("user://shot_%s%s.png" % [s[0], suffix])
		print("saved ", s[0])
		holder.queue_free()
	quit()
