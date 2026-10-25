class_name UnitView
extends Node3D
## How one unit looks on a client: model, animation, blob shadow, nameplate, ward bubble.
## Position comes from interpolated server snapshots (or local prediction for your own character).

var info: Dictionary # spawn info from the server
var id := 0
var model: Node3D
var anim: AnimationPlayer
var plate: Label3D
var shadow: MeshInstance3D
var ward: MeshInstance3D
var ring: MeshInstance3D
var staff_gem: Node3D

# latest replicated state
var hp := 1.0
var max_hp := 1.0
var res := 0.0
var max_res := 0.0
var absorb := 0.0
var flags := 0
var target_id := 0
var cast_ab := -1
var cast_time := 0.0
var cast_dur := 0.0
var potions := 3
var tp_seq := 0
var dead := false
var base := "idle"
var base_speed := 1.0
var act_seq := -1
var acting := false
var yaw := 0.0
var fly := 0.0
var detail := {} # cooldowns and buffs (party only)

# interpolation buffer: [server_time, pos, yaw]
var buf: Array = []

static var _blob: Texture2D

func setup(i: Dictionary) -> void:
	info = i
	id = i.id
	name = "U%d" % id
	max_hp = i.max_hp
	hp = i.max_hp
	fly = i.get("fly", 0.0)
	var c := Assets.character(i.body)
	model = c.root
	anim = c.anim
	add_child(model)
	anim.animation_finished.connect(_on_anim_done)
	var gem := model.find_child("Gem", true, false)
	if gem:
		staff_gem = gem
	# blob shadow
	shadow = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var s: float = i.r * 2.6 * (0.8 if fly > 0 else 1.0)
	pm.size = Vector2(s, s)
	shadow.mesh = pm
	shadow.material_override = _blob_mat()
	shadow.position.y = 0.05
	add_child(shadow)
	# nameplate for enemies, name only for party
	plate = Label3D.new()
	plate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	plate.no_depth_test = true
	plate.fixed_size = true
	plate.pixel_size = 0.0011
	plate.font_size = 18
	plate.outline_size = 6
	plate.outline_modulate = Color(0, 0, 0, 0.9)
	var h: float = 2.6 * Assets.BODIES[i.body].get("scale", 1.0)
	if i.body == "gorrak":
		h = 4.4
	plate.position.y = h + fly + 0.5
	plate.text = i.name
	plate.modulate = Color(1, 0.45, 0.35) if i.team == "enemy" else Color(0.55, 0.85, 1)
	if i.get("elite", false) or i.get("boss", "") != "":
		plate.modulate = Color(1, 0.8, 0.35)
	add_child(plate)
	play_base("idle", 1.0)

static func _blob_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0, 0, 0, 0.55)
	m.albedo_texture = WorldBuilder.soft_tex()
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return m

func height() -> float:
	if info.body == "gorrak":
		return 4.0
	return 2.4 * Assets.BODIES[info.body].get("scale", 1.0)

func chest() -> Vector3:
	return global_position + Vector3(0, height() * 0.55 + (fly if not dead else 0.0), 0)

func is_enemy() -> bool:
	return info.team == "enemy"

func play_base(a: String, spd: float) -> void:
	if base == a and is_equal_approx(base_speed, spd) and not acting:
		return
	base = a
	base_speed = spd
	if acting or dead:
		return
	if anim.has_animation(a):
		anim.play(a, 0.2, absf(spd), spd < 0)

func play_act(a: String, spd: float) -> void:
	if not anim.has_animation(a):
		return
	acting = a != "idle"
	if a == "idle":
		anim.play(base, 0.15, absf(base_speed))
		return
	anim.play(a, 0.12, spd)

func _on_anim_done(_n: StringName) -> void:
	if dead:
		return
	acting = false
	if anim.has_animation(base):
		anim.play(base, 0.2, absf(base_speed), base_speed < 0)

## Apply one unit's slice of a snapshot.
func apply(s: PackedFloat32Array, i: int, t: float, is_me: bool) -> void:
	hp = s[i + 5]
	max_hp = s[i + 6]
	res = s[i + 7]
	max_res = s[i + 8]
	absorb = s[i + 9]
	cast_ab = int(s[i + 15])
	cast_time = s[i + 16]
	cast_dur = s[i + 17]
	target_id = int(s[i + 18])
	flags = int(s[i + 19])
	potions = int(s[i + 21])
	var was_dead := dead
	dead = flags & 1 != 0
	var p := Vector3(s[i + 1], s[i + 2], s[i + 3])
	buf.append([t, p, s[i + 4]])
	if buf.size() > 30:
		buf.pop_front()
	if not is_me or flags & 32 != 0:
		var b: int = s[i + 10]
		if b >= 0 and not dead:
			play_base(D.ANIMS[b], s[i + 11])
	var seq := int(s[i + 13])
	if act_seq < 0:
		act_seq = seq
	elif seq != act_seq:
		act_seq = seq
		var a: int = s[i + 12]
		if a >= 0:
			if D.ANIMS[a] == "death":
				dead = true
				acting = true
				anim.play("death", 0.1, 1.0)
			elif D.ANIMS[a] == "spawn" or (was_dead and not dead):
				acting = true
				anim.play("spawn" if anim.has_animation("spawn") else "idle", 0.1, 1.0)
			else:
				play_act(D.ANIMS[a], s[i + 14])
	if was_dead and not dead and not acting:
		play_base("idle", 1.0)
	# ward bubble
	var warded := flags & 1024 != 0 and absorb > 0
	if warded and ward == null:
		ward = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 1.6
		sm.height = 3.2
		ward.mesh = sm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_color = Color(1, 0.85, 0.45, 0.12)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		ward.material_override = m
		ward.position.y = 1.3
		add_child(ward)
	elif not warded and ward:
		ward.queue_free()
		ward = null

## Place the unit at render time rt by interpolating the snapshot buffer.
func interpolate(rt: float) -> void:
	if buf.is_empty():
		return
	var a: Array = buf[0]
	var b: Array = buf[buf.size() - 1]
	if rt <= a[0]:
		_set_pose(a[1], a[2])
		return
	if rt >= b[0]:
		_set_pose(b[1], b[2])
		return
	for k in range(buf.size() - 1, 0, -1):
		if buf[k - 1][0] <= rt:
			a = buf[k - 1]
			b = buf[k]
			break
	var f: float = (rt - a[0]) / maxf(0.0001, b[0] - a[0])
	_set_pose(a[1].lerp(b[1], f), lerp_angle(a[2], b[2], f))

func _set_pose(p: Vector3, y: float) -> void:
	var bob := 0.0
	if fly > 0 and not dead:
		bob = fly + sin(Time.get_ticks_msec() / 1000.0 * 3.0 + id) * 0.25
	position = Vector3(p.x, p.y, p.z)
	model.position.y = bob
	yaw = y
	model.rotation.y = y
	shadow.position.y = 0.05 - 0.0

func set_targeted(on: bool, hostile: bool) -> void:
	if on and ring == null:
		ring = MeshInstance3D.new()
		var tm := TorusMesh.new()
		var r: float = info.r * 1.3
		tm.inner_radius = r
		tm.outer_radius = r + 0.12
		tm.rings = 24
		tm.ring_segments = 4
		ring.mesh = tm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1, 0.3, 0.2) if hostile else Color(0.4, 1, 0.5)
		m.disable_fog = true
		ring.material_override = m
		ring.position.y = 0.1
		ring.scale.y = 0.1
		add_child(ring)
	elif not on and ring:
		ring.queue_free()
		ring = null
	if plate and is_enemy():
		plate.visible = not dead
