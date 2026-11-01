class_name Poses
extends RefCounted
## Attack and skill clips built in code from a few authored key poses, for the KayKit rig.
## A pose gives limb directions in character space (+Z forward, -X the character's right, +Y up),
## torso rotations as euler angles, a hips offset, and where the weapon's head points ("axe") and its
## cutting edge faces ("edge"). The solver turns that into bone rotations, and build() bakes the
## eased in-betweens into an ordinary Animation, so new attacks need no new animation files.
## Clip timings line up with the sim: D.ACTS hit times for light/heavy, the skill timings in Sim.

## Clip-time windows when the weapon leaves a trail (UnitView draws it).
## The swing itself is drawn out (wind-up reached early, an accelerating arc into the hit, a long follow-through)
## while the hit and recovery times stay on the sim's numbers.
const TRAILS := { "light1": [0.12, 0.4], "light2": [0.12, 0.4], "slam": [0.34, 0.66], "hack": [0.12, 0.38], "stomp": [0.46, 0.64] }

var sk: Skeleton3D
var rest_g := {} # bone -> global rest basis
var rest_o := {} # bone -> local rest origin

func _init(s: Skeleton3D) -> void:
	sk = s
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i)
		rest_g[n] = sk.get_bone_global_rest(i).basis.orthonormalized()
		rest_o[n] = sk.get_bone_rest(i).origin

## Add every built clip to a KayKit body's library (skipped for rigs without the KayKit bones).
static func add_clips(lib: AnimationLibrary, s: Skeleton3D, sk_path: String) -> void:
	for b in ["hips", "spine", "upperarm.r", "lowerarm.r", "wrist.r", "handslot.r", "upperleg.l"]:
		if s.find_bone(b) < 0:
			return
	var p := Poses.new(s)
	var m := moves()
	for k in m:
		if not lib.has_animation(k):
			lib.add_animation(k, p.build(m[k], sk_path))

# ------------------------------------------------------------------ the solver
static func _arc(a: Vector3, b: Vector3) -> Basis:
	a = a.normalized()
	b = b.normalized()
	var ax := a.cross(b)
	var d := clampf(a.dot(b), -1, 1)
	if ax.length() < 1e-5:
		if d > 0:
			return Basis()
		ax = a.cross(Vector3.FORWARD if absf(a.z) < 0.9 else Vector3.RIGHT)
	return Basis(ax.normalized(), acos(d))

## The weapon hand's frame. KayKit gear runs its haft along the hand slot's +Y with the edge on -X.
func wrist_target(pose: Dictionary) -> Basis:
	var h: Vector3 = (pose.axe as Vector3).normalized()
	var e: Vector3 = pose.get("edge", Vector3(0, 0, 1))
	e = e - h * e.dot(h)
	if e.length() < 0.1:
		e = Vector3.UP - h * h.y
	e = e.normalized()
	var hs := Basis(-e, h, (-e).cross(h))
	return hs * (rest_g["wrist.r"].inverse() * rest_g["handslot.r"]).inverse()

## bone -> local rotation, plus "hips_pos"
func solve(pose: Dictionary) -> Dictionary:
	var g := {}
	var out := {}
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i)
		var p := sk.get_bone_parent(i)
		var pn: String = sk.get_bone_name(p) if p >= 0 else ""
		var pg: Basis = g[pn] if p >= 0 else Basis()
		var b: Basis
		var v = pose.get(n)
		if v is Vector3:
			b = _arc(rest_g[n].y, v) * rest_g[n]
			var tw := 0.0
			if n == "lowerarm.r" and pose.has("axe"):
				# roll the forearm so the wrist has the least left to do
				var f: Vector3 = (v as Vector3).normalized()
				var bw0: Basis = b * (rest_g[n].inverse() * rest_g["wrist.r"])
				var bwt := wrist_target(pose)
				var a0: Vector3 = bw0.x - f * bw0.x.dot(f)
				var a1: Vector3 = bwt.x - f * bwt.x.dot(f)
				if a0.length() > 0.05 and a1.length() > 0.05:
					tw = a0.normalized().signed_angle_to(a1.normalized(), f)
			b = Basis((v as Vector3).normalized(), tw) * b
		elif v is Dictionary:
			b = Basis.from_euler(v.e) * rest_g[n]
		elif n == "wrist.r" and pose.has("axe"):
			b = wrist_target(pose)
		else:
			# unauthored bones keep their rest orientation relative to the parent
			var pr: Basis = rest_g[pn] if p >= 0 else Basis()
			b = pg * (pr.inverse() * rest_g[n])
		g[n] = b
		out[n] = (pg.inverse() * b).get_rotation_quaternion()
	out["hips_pos"] = rest_o["hips"] + pose.get("hips_off", Vector3.ZERO)
	return out

static func _ease(t: float, kind: String) -> float:
	match kind:
		"in": return t * t * t
		"out": return 1.0 - pow(1.0 - t, 3)
		"snap": return 1.0 - pow(1.0 - t, 5)
		"swing": return t * t * (1.6 - 0.6 * t) # gathers speed into the hit, not a snap
		_: return t * t * (3.0 - 2.0 * t)

## keys: [[time, pose, ease], ...]; the ease shapes the move into that key
func build(keys: Array, sk_path: String) -> Animation:
	var solved := []
	for k in keys:
		solved.append(solve(k[1]))
	var a := Animation.new()
	var length: float = keys[-1][0]
	a.length = length
	var tracks := {}
	for n in rest_g:
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%s:%s" % [sk_path, n]))
		tracks[n] = t
	var hp := a.add_track(Animation.TYPE_POSITION_3D)
	a.track_set_path(hp, NodePath("%s:hips" % sk_path))
	var fps := 30.0
	var steps := int(ceil(length * fps))
	for st in steps + 1:
		var tm := minf(st / fps, length)
		var j := 0
		while j < keys.size() - 1 and keys[j + 1][0] < tm:
			j += 1
		var j2 := mini(j + 1, keys.size() - 1)
		var span: float = keys[j2][0] - keys[j][0]
		var u := 0.0 if span <= 0 else clampf((tm - keys[j][0]) / span, 0, 1)
		u = _ease(u, keys[j2][2] if keys[j2].size() > 2 else "smooth")
		var ka: Dictionary = solved[j]
		var kb: Dictionary = solved[j2]
		for n in rest_g:
			a.rotation_track_insert_key(tracks[n], tm, (ka[n] as Quaternion).slerp(kb[n], u))
		a.position_track_insert_key(hp, tm, (ka.hips_pos as Vector3).lerp(kb.hips_pos, u))
	return a

# ------------------------------------------------------------------ the poses
static func stance() -> Dictionary:
	return {
		"upperarm.r": Vector3(-0.45, -0.75, 0.25), "lowerarm.r": Vector3(-0.1, 0.25, 1.0), "axe": Vector3(-0.1, 1, 0.3), "edge": Vector3(0, 0, 1),
		"upperarm.l": Vector3(0.35, -0.8, 0.3), "lowerarm.l": Vector3(-0.35, 0.1, 1.0),
		"upperleg.r": Vector3(-0.1, -1, -0.3), "lowerleg.r": Vector3(0, -1, -0.2),
		"upperleg.l": Vector3(0.1, -1, 0.3), "lowerleg.l": Vector3(0, -1, -0.1),
		"spine": {"e": Vector3(0.08, 0, 0)}, "hips_off": Vector3(0, -0.05, 0) }

static func _p(over: Dictionary, base: Dictionary = {}) -> Dictionary:
	var p := stance() if base.is_empty() else base.duplicate()
	for k in over:
		p[k] = over[k]
	return p

static func _lunge(d := 1.0) -> Dictionary:
	return { "upperleg.l": Vector3(0.12, -0.75, 0.75 * d), "lowerleg.l": Vector3(0, -1, -0.05),
		"upperleg.r": Vector3(-0.12, -0.85, -0.55 * d), "lowerleg.r": Vector3(0, -0.8, -0.7 * d),
		"hips_off": Vector3(0, -0.13 * d, 0.16 * d) }

static func moves() -> Dictionary:
	var s := stance()
	var m := {}
	# light 1: forehand diagonal, high right to low left, stepping in
	var w1 := _p({ "spine": {"e": Vector3(-0.1, -0.7, 0.1)}, "upperarm.r": Vector3(-0.75, 0.6, -0.25), "lowerarm.r": Vector3(-0.2, 1, -0.3),
		"axe": Vector3(-0.3, 0.75, -0.6), "edge": Vector3(0, 0.3, 1) })
	var c1 := _p(_lunge(0.8).merged({ "spine": {"e": Vector3(0.25, 0.1, 0)}, "upperarm.r": Vector3(-0.25, 0.1, 1), "lowerarm.r": Vector3(0.1, -0.1, 1),
		"axe": Vector3(0.15, -0.35, 1), "edge": Vector3(0.55, -0.8, 0) }, true))
	var s1 := _p(_lunge().merged({ "spine": {"e": Vector3(0.35, 0.65, -0.1)}, "upperarm.r": Vector3(0.45, -0.45, 0.8), "lowerarm.r": Vector3(0.5, -0.6, 0.6),
		"axe": Vector3(0.75, -0.6, 0.3), "edge": Vector3(0.2, -0.3, -0.9) }, true))
	m.light1 = [[0.0, s], [0.11, w1, "out"], [0.26, c1, "swing"], [0.38, s1, "out"], [0.46, s1], [0.62, s]]
	# light 2: backhand, sweeping left to right across the body
	var w2 := _p(_lunge(0.6).merged({ "spine": {"e": Vector3(0.15, 0.8, 0)}, "upperarm.r": Vector3(0.35, -0.05, 0.75), "lowerarm.r": Vector3(0.95, 0.15, 0.1),
		"axe": Vector3(1, 0.15, -0.2), "edge": Vector3(0, 0, 1) }, true))
	var c2 := _p(_lunge().merged({ "spine": {"e": Vector3(0.15, 0.0, 0)}, "upperarm.r": Vector3(-0.3, 0.0, 1), "lowerarm.r": Vector3(-0.3, 0.05, 1),
		"axe": Vector3(-0.2, 0.05, 1), "edge": Vector3(-1, 0, 0) }, true))
	var s2 := _p(_lunge().merged({ "spine": {"e": Vector3(0.15, -0.75, 0)}, "upperarm.r": Vector3(-0.9, 0.05, 0.4), "lowerarm.r": Vector3(-0.35, 0.05, 1),
		"axe": Vector3(-1, 0.1, 0.1), "edge": Vector3(0, 0, -1) }, true))
	m.light2 = [[0.0, s], [0.11, w2, "out"], [0.26, c2, "swing"], [0.38, s2, "out"], [0.46, s2], [0.62, s]]
	# heavy: rise up and slam overhead into the ground
	var w3 := _p({ "spine": {"e": Vector3(-0.45, 0, 0)}, "upperarm.r": Vector3(-0.15, 1, -0.15), "lowerarm.r": Vector3(0, 0.45, -0.9),
		"axe": Vector3(0, -0.5, -0.85), "edge": Vector3(0, 1, -0.4), "upperarm.l": Vector3(0.3, 0.9, 0.1), "lowerarm.l": Vector3(-0.2, 0.5, -0.6),
		"upperleg.l": Vector3(0.1, -1, 0.15), "upperleg.r": Vector3(-0.1, -1, -0.1), "lowerleg.r": Vector3(0, -0.8, -0.6), "hips_off": Vector3(0, 0.12, -0.05) })
	var s3 := _p(_lunge(1.3).merged({ "spine": {"e": Vector3(0.7, 0, 0)}, "upperarm.r": Vector3(-0.1, -0.35, 1), "lowerarm.r": Vector3(0, -0.85, 0.55),
		"axe": Vector3(0, -0.35, 1), "edge": Vector3(0, -1, -0.3) }, true))
	m.slam = [[0.0, s], [0.32, w3, "out"], [0.55, s3, "swing"], [0.82, s3], [1.05, s]]
	# Hack: a hop forward into an overhead cleave (lands on the sim's 0.28 s swing)
	var hk := w3.duplicate()
	hk["hips_off"] = Vector3(0, 0.38, 0)
	m.hack = [[0.0, s], [0.11, hk, "out"], [0.28, s3, "swing"], [0.48, s3], [0.7, s]]
	# Thunderstomp: crouch, jump with both hands up, land on the sim's 0.6 s stamp
	var crouch := _p({ "hips_off": Vector3(0, -0.22, 0), "upperleg.l": Vector3(0.15, -0.6, 0.75), "lowerleg.l": Vector3(0, -1, -0.2),
		"upperleg.r": Vector3(-0.15, -0.6, 0.6), "lowerleg.r": Vector3(0, -1, -0.4), "spine": {"e": Vector3(0.4, 0, 0)} })
	var j0 := _p({ "spine": {"e": Vector3(-0.3, 0, 0)}, "upperarm.r": Vector3(-0.5, 0.85, 0.1), "lowerarm.r": Vector3(-0.1, 1, -0.2),
		"axe": Vector3(0.2, 0.4, -1), "edge": Vector3(0, 1, 0.4), "upperarm.l": Vector3(0.5, 0.85, 0.1), "lowerarm.l": Vector3(0.1, 1, -0.2),
		"upperleg.l": Vector3(0.1, -0.5, 0.85), "lowerleg.l": Vector3(0, -1, -0.2), "upperleg.r": Vector3(-0.1, -0.6, 0.6), "lowerleg.r": Vector3(0, -1, -0.5),
		"hips_off": Vector3(0, 0.95, 0) })
	var j1 := _p({ "spine": {"e": Vector3(0.75, 0, 0)}, "upperarm.r": Vector3(-0.6, -0.6, 0.5), "lowerarm.r": Vector3(-0.2, -1, 0.3),
		"axe": Vector3(-0.3, -0.4, 1), "edge": Vector3(0, -1, -0.3), "upperarm.l": Vector3(0.6, -0.6, 0.5), "lowerarm.l": Vector3(0.2, -1, 0.3),
		"upperleg.l": Vector3(0.3, -0.6, 0.7), "lowerleg.l": Vector3(0, -1, -0.1), "upperleg.r": Vector3(-0.3, -0.6, 0.6), "lowerleg.r": Vector3(0, -0.9, -0.4),
		"hips_off": Vector3(0, -0.28, 0.05) })
	m.stomp = [[0.0, s], [0.14, crouch, "out"], [0.38, j0, "out"], [0.6, j1, "in"], [0.85, j1], [1.15, s]]
	# Rallying Roar: gather, then chest out and arms wide
	var r0 := _p({ "spine": {"e": Vector3(0.4, 0, 0)}, "upperarm.r": Vector3(-0.5, -0.6, 0.5), "lowerarm.r": Vector3(0.1, 0.4, 1), "axe": Vector3(0, 1, 0.2),
		"upperarm.l": Vector3(0.5, -0.6, 0.5), "lowerarm.l": Vector3(-0.1, 0.4, 1), "hips_off": Vector3(0, -0.12, 0) })
	var r1 := _p({ "spine": {"e": Vector3(-0.45, 0, 0)}, "upperarm.r": Vector3(-0.9, 0.45, -0.1), "lowerarm.r": Vector3(-0.5, 1, 0), "axe": Vector3(0, 1, 0.3),
		"upperarm.l": Vector3(0.9, 0.45, -0.1), "lowerarm.l": Vector3(0.5, 1, 0), "upperleg.l": Vector3(0.35, -1, 0.15), "upperleg.r": Vector3(-0.35, -1, -0.1),
		"hips_off": Vector3(0, -0.08, 0) })
	m.roar = [[0.0, s], [0.12, r0, "out"], [0.24, r1, "snap"], [1.0, r1], [1.35, s]]
	# Charge: shield forward, head down, legs driving; then the bash on arrival
	var ra := _p(_lunge(1.1).merged({ "spine": {"e": Vector3(0.45, 0.25, 0)}, "upperarm.l": Vector3(0.25, -0.1, 1), "lowerarm.l": Vector3(-0.75, 0.15, 0.6),
		"upperarm.r": Vector3(-0.6, -0.7, -0.2), "lowerarm.r": Vector3(-0.2, -0.3, 1), "axe": Vector3(0, 0.5, -1), "edge": Vector3(0, 1, 0.5) }, true))
	var rb := ra.duplicate()
	rb["upperleg.l"] = Vector3(0.12, -0.85, -0.55)
	rb["lowerleg.l"] = Vector3(0, -0.8, -0.7)
	rb["upperleg.r"] = Vector3(-0.12, -0.75, 0.75)
	rb["lowerleg.r"] = Vector3(0, -1, -0.05)
	m.rush = [[0.0, s], [0.12, ra, "out"], [0.3, rb], [0.48, ra], [0.66, rb], [0.84, ra], [1.02, rb], [1.2, ra], [1.4, rb], [1.6, ra]]
	var bash := ra.duplicate()
	bash["upperarm.l"] = Vector3(0.1, 0.05, 1)
	bash["lowerarm.l"] = Vector3(-0.85, 0.2, 0.45)
	bash["spine"] = {"e": Vector3(0.3, 0.1, 0)}
	m.bash = [[0.0, ra], [0.08, bash, "snap"], [0.25, bash], [0.55, s]]
	return m
