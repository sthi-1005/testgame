extends SceneTree
func _init():
	var args := OS.get_cmdline_user_args()
	var root := Node3D.new(); get_root().add_child(root)
	var we := WorldEnvironment.new(); we.environment = Look.make_environment(); Look.grade(we.environment, 1.0); we.environment.fog_enabled = false; we.environment.background_color = Color(0.5,0.5,0.55); root.add_child(we)
	var c := Assets.character(args[0]); root.add_child(c.root); c.anim.play("idle")
	if args.size() > 1:
		for m in c.root.find_children("*", "MeshInstance3D", true, false):
			for i in m.mesh.get_surface_count():
				var mat = m.get_surface_override_material(i)
				if mat: mat.next_pass = null
	var sk: Skeleton3D = c.skeleton
	print("skel global scale ", sk.global_transform.basis.get_scale(), " path ", c.root.get_path_to(sk))
	for n in c.root.find_children("*", "Node3D", true, false): if n.scale != Vector3.ONE: print("  scaled ", c.root.get_path_to(n), " ", n.scale)
	var l := OmniLight3D.new(); l.position = Vector3(2, 4, 4); l.omni_range = 20; l.light_energy = 2; root.add_child(l)
	var cam := Camera3D.new(); root.add_child(cam); cam.look_at_from_position(Vector3(0, 3, 9), Vector3(0, 1.8, 0))
	for k in 5: await process_frame
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png("user://one.png"); quit()
