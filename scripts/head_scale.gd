class_name HeadScale
extends SkeletonModifier3D
## Shrinks the head bone (and the hat or helmet skinned to it) after animation, so the KayKit
## characters read less chibi and their swings aren't hidden behind a huge head. Runs after the
## AnimationPlayer every frame because some clips key the head's scale.

const SCALE := 0.68

var head := -1

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if head < 0:
		head = sk.find_bone("head")
		if head < 0:
			return
	sk.set_bone_pose_scale(head, Vector3.ONE * SCALE)
