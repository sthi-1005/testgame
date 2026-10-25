extends SceneTree
func _init():
	for p in ["res://assets/chars/Barbarian.glb","res://assets/anims/anim_knight1.glb"]:
		var n = load(p).instantiate()
		var sk: Skeleton3D = n.find_children("*", "Skeleton3D", true, false)[0]
		var names = []
		for i in sk.get_bone_count(): names.append(sk.get_bone_name(i))
		print(p, " ", names)
		var aabb = AABB()
		for m in n.find_children("*", "MeshInstance3D", true, false): aabb = aabb.merge(m.get_aabb())
		print("  aabb ", aabb, " hips rest ", sk.get_bone_rest(sk.find_bone("hips")).origin)
		n.free()
	quit()
