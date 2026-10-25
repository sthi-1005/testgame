extends SceneTree
## Review stills of Skyroot Spire with the party posed along the route.
## xvfb-run -a godot --path . --rendering-driver vulkan --resolution 1600x900 -s stages/skytemple/shots.gd -- [suffix]
func _init():
	await process_frame
	var suffix: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() else ""
	var root := Node3D.new(); get_root().add_child(root)
	var lv := SkyLevel.new()
	var wb := SkyBuilder.new(lv, root)
	wb.build()
	var we := WorldEnvironment.new(); we.environment = wb.make_environment(); root.add_child(we)
	var pool := WorldBuilder.LightPool.new(root, wb.light_sources, 6)
	var cam := Camera3D.new(); cam.fov = 60; cam.far = 1200; root.add_child(cam)
	var T := SkyLevel.T
	var F := func(cx: float, cz: float, dy := 0.0) -> Vector3:
		var p := Vector3(cx * T, 0, cz * T)
		p.y = lv.floor_y(p.x, p.z) + dy
		return p
	var party := func(cx: float, cz: float, yaw: float, anim: String) -> Array:
		return [["sellsword", cx, cz, yaw, anim], ["cleric", cx - 0.6, cz + 0.5, yaw, anim], ["mage", cx + 0.6, cz + 0.6, yaw, anim]]
	var shots := [
		# name, camera pos, look at, units [body, cell x, cell z, yaw, anim]
		["glade", F.call(9.0, 63.5, 5.0), F.call(26, 50, 10.0), party.call(11.5, 58.5, PI * 0.8, "run")],
		["canopy", Vector3(25.5 * T, 29.0, 37.5 * T), Vector3(33.5 * T, 19.0, 30.5 * T), party.call(31.8, 32.6, PI * 0.75, "idle")],
		["skybridge", F.call(14.5, 20.5, 9.0), F.call(27, 25, 3.0), party.call(20.0, 24.2, -PI / 2, "run")],
		["temple", F.call(8.5, 16.0, 16.0), F.call(8.5, 4.5, 2.0), party.call(8.5, 8.6, PI, "combatIdle") + [["sky_hollowbark", 8.5, 4.6, 0.0, "smash"]]],
		["overview", Vector3(330, 105, 330), Vector3(95, 22, 120), []],
	]
	for s in shots:
		var holder := Node3D.new(); root.add_child(holder)
		for u in s[3]:
			var c := Assets.character(u[0])
			var n: Node3D = c.root
			holder.add_child(n)
			n.position = F.call(u[1], u[2])
			n.rotation.y = u[3]
			c.anim.play(u[4]); c.anim.seek(0.35, true)
		cam.look_at_from_position(s[1], s[2])
		pool.update(s[1].lerp(s[2], 0.5), 0.0)
		for k in 8: await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("user://sky_%s%s.png" % [s[0], suffix])
		print("saved ", s[0])
		holder.queue_free()
	quit()
