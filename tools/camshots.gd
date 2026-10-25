extends SceneTree
## Gameplay-camera stills from fixed spots (before/after comparisons of scale and camera).
## godot --path . --rendering-driver vulkan --resolution 1600x900 -s tools/camshots.gd -- <suffix>
func _init():
	await process_frame
	var suffix: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() else ""
	var game := Game.new()
	get_root().add_child(game)
	var net := LocalNet.new()
	game.attach(net)
	net.host_solo("sellsword")
	if OS.get_cmdline_user_args().has("nofx"):
		net.events_received.disconnect(game._on_events)
	if OS.get_cmdline_user_args().has("peace"):
		for e in net.sim.enemies:
			e.aggro_r = 0.0
	var T := Level.T
	# name, cell x, cell z, facing (yaw)
	var only: String = OS.get_cmdline_user_args()[1] if OS.get_cmdline_user_args().size() > 1 and OS.get_cmdline_user_args()[1].begins_with("cam_") else ""
	var spots := [["cam_tunnel", 3.6, 24.0, PI], ["cam_diggings", 5.0, 13.5, PI], ["cam_cut", 13.0, 10.5, PI / 2], ["cam_hall", 24.5, 12.0, 2.4]]
	for s in spots:
		if only != "" and s[0] != only:
			continue
		var p := Vector3(s[1] * T, 0, s[2] * T)
		# move the party along so the shot shows them next to you
		for m in net.sim.party:
			m.pos = p + Vector3(randf_range(-1.5, 1.5), 0, randf_range(0.5, 2.5)).rotated(Vector3.UP, s[3] + PI)
			m.tp_seq += 1
		var u: SUnit = net.sim.players[LocalNet.PEER]
		u.pos = p
		u.yaw = s[3]
		u.tp_seq += 1
		game.my_yaw = s[3]
		game.cam_yaw = s[3]
		if OS.get_cmdline_user_args().has("oldcam"):
			game.cam_pitch = -0.42
			game.cam_dist = 11.0
		for a in OS.get_cmdline_user_args():
			if a.begins_with("pitch="): game.cam_pitch = float(a.substr(6))
			if a.begins_with("dist="): game.cam_dist = float(a.substr(5))
		for k in 40:
			await process_frame
		await RenderingServer.frame_post_draw
		print("  cam ", game.cam.global_position, " cur_dist=", game.cam_cur_dist, " pivot=", game.cam_pivot)
		if OS.get_cmdline_user_args().has("lights"):
			for l in get_root().find_children("*", "Light3D", true, false):
				if l.visible and l.global_position.distance_to(game.my_pos) < 14:
					print("  light ", l.get_class(), " ", l.get_parent().name, " ", l.global_position, " e=", l.light_energy, " vol=", l.light_volumetric_fog_energy)
			for n in get_root().find_children("*", "GPUParticles3D", true, false) + get_root().find_children("*", "CPUParticles3D", true, false):
				if n.global_position.distance_to(game.my_pos) < 6:
					print("  particles ", n.get_parent().name, " ", n.global_position)
		get_root().get_texture().get_image().save_png("user://%s%s.png" % [s[0], suffix])
		print("saved ", s[0])
	quit()
