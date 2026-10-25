extends SceneTree
func _init():
	for p in ["res://assets/chars/Barbarian.glb","res://assets/props/q_axe.glb","res://assets/chars/orc_brute.glb","res://assets/chars/bat.glb","res://assets/anims/anim_general.glb","res://assets/anims/anim_move.glb","res://assets/anims/anim_knight1.glb","res://assets/anims/anim_tools.glb","res://assets/anims/skeleton_warrior.gltf"]:
		var s = load(p)
		if s == null:
			print("FAIL ", p); continue
		var n = s.instantiate()
		print("== ", p)
		_walk(n, 0)
		var ap = n.find_children("*", "AnimationPlayer", true, false)
		for a in ap:
			print("  AP ", n.get_path_to(a), " root=", a.root_node, " anims=", a.get_animation_list())
			var lst = a.get_animation_list()
			if lst.size() > 0:
				var an = a.get_animation(lst[0])
				for i in range(min(3, an.get_track_count())):
					print("    track ", an.track_get_path(i), " type ", an.track_get_type(i))
		n.free()
	quit()
func _walk(n, d):
	if d > 4: return
	var extra = ""
	if n is Skeleton3D: extra = " bones=%d first=%s" % [n.get_bone_count(), n.get_bone_name(0)]
	if n is MeshInstance3D: extra = " mesh skin=%s" % [str(n.skin != null)]
	if n is BoneAttachment3D: extra = " bone=" + n.bone_name
	print("  ".repeat(d+1), n.name, " <", n.get_class(), ">", extra)
	for c in n.get_children(): _walk(c, d+1)
