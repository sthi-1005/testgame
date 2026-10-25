extends SceneTree
## Renders still shots of the dungeon with the party and enemies posed, for review.
## godot --path . --rendering-driver opengl3 -s tools/shots.gd
func _init():
	var root := Node3D.new(); get_root().add_child(root)
	var lv := Level.new()
	var wb := WorldBuilder.new(lv, root)
	wb.build()
	var we := WorldEnvironment.new(); we.environment = Look.make_environment(); root.add_child(we)
	var pool := WorldBuilder.LightPool.new(root, wb.light_sources, 8)
	var cam := Camera3D.new(); cam.fov = 60; cam.far = 300; root.add_child(cam)
	var T := Level.T
	var shots := [
		# name, grade, camera pos, look at, units [body, cell x, cell z, yaw, anim]
		["tunnel", 0.0, Vector3(3.9 * T, 4.6, 26.3 * T), Vector3(3.9 * T, 1.6, 20 * T), [["sellsword", 3.7, 23.6, PI, "run"], ["cleric", 3.3, 24.4, PI, "run"], ["mage", 4.3, 24.5, PI, "run"]]],
		["diggings", 0.0, Vector3(5.0 * T, 7.0, 14.1 * T), Vector3(5 * T, 0.5, 9.0 * T), [["sellsword", 4.8, 12.0, PI, "combatIdle"], ["cleric", 3.8, 13.0, PI, "cast"], ["mage", 5.9, 13.2, PI, "cast"], ["footpad", 4.2, 11.2, 0.0, "attack"], ["miner", 5.2, 10.8, 0.2, "combatIdle"]]],
		["hall", 1.0, Vector3(23.6 * T, 7.5, 12.5 * T), Vector3(28.5 * T, 1.5, 6.5 * T), [["gorrak", 28.5, 6.5, -2.4, "smash"], ["sellsword", 27.6, 7.5, 0.7, "attack"], ["cleric", 25.5, 10.0, 0.8, "cast"], ["mage", 26.6, 11.0, 0.6, "cast"], ["bat", 27.0, 8.6, 1.0, "idle"]]],
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
		pool.update(s[2].lerp(s[3], 0.5), 0.0)
		for k in 4: await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("user://shot_%s.png" % s[0])
		print("saved ", s[0])
		holder.queue_free()
	quit()
