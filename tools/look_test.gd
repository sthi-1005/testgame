extends SceneTree
## Renders every body in a row with toon shading, to check models, gear and retargeted animation.
func _init():
	var root := Node3D.new()
	get_root().add_child(root)
	var we := WorldEnvironment.new()
	we.environment = Look.make_environment()
	Look.grade(we.environment, float(OS.get_cmdline_user_args()[0]) if OS.get_cmdline_user_args().size() else 0.0)
	root.add_child(we)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(40, 20)
	floor.mesh = pm
	floor.material_override = Look.toon(Color(0.45, 0.4, 0.35), null, 0)
	root.add_child(floor)
	var bodies := ["sellsword", "cleric", "mage", "footpad", "taskmaster", "miner", "gorrak", "bat"]
	var anims := ["run", "cast", "attack", "idle", "combatIdle", "walk", "attack", "idle"]
	var i := 0
	for b in bodies:
		var c := Assets.character(b)
		var n: Node3D = c.root
		root.add_child(n)
		n.position = Vector3(-10.5 + i * 3.0, 2.4 if b == "bat" else 0.0, 0)
		var ap: AnimationPlayer = c.anim
		print(b, " anims=", ap.get_animation_list())
		ap.play(anims[i])
		ap.seek(0.3, true)
		i += 1
	var l := OmniLight3D.new(); l.position = Vector3(-3, 4, 4); l.omni_range = 26; l.light_energy = 2.2; l.light_color = Color(1, 0.55, 0.22)
	root.add_child(l)
	var l2 := OmniLight3D.new(); l2.position = Vector3(8, 4, 3); l2.omni_range = 20; l2.light_energy = 1.6; l2.light_color = Color(1, 0.6, 0.3)
	root.add_child(l2)
	var cam := Camera3D.new(); cam.position = Vector3(0, 4.2, 13); cam.fov = 50
	root.add_child(cam)
	cam.look_at(Vector3(0, 1.4, 0))
	for k in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png("user://look.png")
	print("saved")
	quit()
