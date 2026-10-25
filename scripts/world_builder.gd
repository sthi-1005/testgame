class_name WorldBuilder
extends RefCounted
## Builds the visual dungeon from a Level: floors, walls, ceilings, props, torches, rails, carts and the bell.
## Torches don't each get a light; a small pool of lights follows the nearest flames (see LightPool).

var lv: Level
var root: Node3D
var light_sources: Array = [] # { pos, color, range, energy }
var cart_nodes: Array = []
var bell_pivot: Node3D

static var _tex := {}

func _init(level: Level, parent: Node3D) -> void:
	lv = level
	root = Node3D.new()
	root.name = "World"
	parent.add_child(root)

static func dirt_tex() -> Texture2D:
	# built synchronously (NoiseTexture2D generates on a thread and can be blank on the first frames)
	if not _tex.has("dirt"):
		var n := FastNoiseLite.new()
		n.frequency = 0.05
		n.fractal_octaves = 4
		var img := n.get_seamless_image(256, 256)
		var lo := Color("#3b2c22")
		var hi := Color("#7a634d")
		for y in img.get_height():
			for x in img.get_width():
				img.set_pixel(x, y, lo.lerp(hi, img.get_pixel(x, y).r))
		img.generate_mipmaps()
		_tex.dirt = ImageTexture.create_from_image(img)
	return _tex.dirt

static func soft_tex() -> Texture2D:
	if not _tex.has("soft"):
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
		gt.width = 64
		gt.height = 64
		_tex.soft = gt
	return _tex.soft

func _place(n: Node3D, pos: Vector3, rot: float, scale) -> Node3D:
	n.position = pos
	n.rotation.y = rot
	n.scale = scale if scale is Vector3 else Vector3.ONE * float(scale)
	root.add_child(n)
	return n

func _box(pos: Vector3, size: Vector3, mat: Material, rot := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = rot
	root.add_child(mi)
	return mi

func build() -> void:
	var T := Level.T
	# floors: stone tiles in the hall, packed dirt everywhere else (one quad per cell so lights stay local)
	var dirt := Look.toon(Color(0.85, 0.8, 0.75), dirt_tex(), 0.0, Vector2(0.5, 0.5))
	var quad := PlaneMesh.new()
	quad.size = Vector2(T, T)
	for z in Level.GH:
		for x in Level.GW:
			if not lv.cell(x, z) and lv.zone_of[z * Level.GW + x] == "":
				continue
			var zn := lv.zone_of[z * Level.GW + x]
			if zn == "hall" or zn == "gate":
				_place(Assets.prop("dungeon-floor", 0.0), Level.W(x, z) + Vector3(0, 0.02, 0), 0.0, 1.0)
			else:
				var mi := MeshInstance3D.new()
				mi.mesh = quad
				mi.material_override = dirt
				_place(mi, Level.W(x, z), 0.0, 1.0)
	# ceilings: one slab per carved rectangle at that zone's height
	var ceil_mat := Look.toon(Color(0.42, 0.36, 0.31), dirt_tex(), 0.0)
	for r in lv.rects:
		var w: float = (r[2] - r[0] + 1) * T + 2
		var d: float = (r[3] - r[1] + 1) * T + 2
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, d)
		pm.flip_faces = true
		mi.mesh = pm
		mi.material_override = ceil_mat
		_place(mi, Vector3((r[0] + r[2] + 1) * T / 2, lv.zone_h(r[4]), (r[1] + r[3] + 1) * T / 2), 0.0, 1.0)
	var wood := Look.toon(Color("#6a4529"), null, 0.03)
	for e in lv.decor:
		match e.kind:
			"wall":
				for k in e.courses:
					_place(Assets.prop("dungeon-wall"), e.pos + Vector3(0, k * 4.0, 0), e.rot, 1.0)
			"prop":
				_place(Assets.prop(e.model), e.pos, e.rot, e.scale)
			"timber":
				_box(e.pos, e.scale, wood, e.rot)
			"torch":
				_place(Assets.prop("dungeon-torch"), e.pos, e.rot, e.scale)
				fire_at(e.flame, 1.1)
				light_sources.append({ "pos": e.light, "color": Color(1, 0.62, 0.35), "range": 22.0, "energy": 2.0 })
			"brazier":
				_place(Assets.prop(e.model), e.pos, e.rot, e.scale)
				fire_at(e.pos + Vector3(0, 1.4, 0), 2.2)
				light_sources.append({ "pos": e.pos + Vector3(0, 3, 0), "color": Color(1, 0.55, 0.25), "range": 24.0, "energy": 1.8 })
			"light":
				light_sources.append({ "pos": e.pos, "color": e.color, "range": e.range, "energy": e.energy })
			"daylight":
				var mi := MeshInstance3D.new()
				var pm := PlaneMesh.new()
				pm.size = Vector2(9, 9)
				pm.orientation = PlaneMesh.FACE_Z
				mi.mesh = pm
				var m := StandardMaterial3D.new()
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.albedo_color = Color(0.81, 0.89, 1.0)
				m.disable_fog = true
				mi.material_override = m
				_place(mi, e.pos, PI, 1.0)
			"rails":
				_build_rails(e.pos.x, e.x1, e.pos.z)
			"bell":
				_build_bell(e.pos)
	for p in lv.cart_starts():
		cart_nodes.append(_build_cart(p))

func fire_at(p: Vector3, size: float) -> void:
	var ps := CPUParticles3D.new()
	ps.amount = 18
	ps.lifetime = 0.6
	ps.local_coords = false
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	ps.emission_sphere_radius = 0.12 * size
	ps.direction = Vector3.UP
	ps.spread = 12
	ps.gravity = Vector3(0, 1.5, 0)
	ps.initial_velocity_min = 0.6 * size
	ps.initial_velocity_max = 1.2 * size
	ps.scale_amount_min = 0.6
	ps.scale_amount_max = 1.0
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.6))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1, 0.0))
	ps.scale_amount_curve = curve
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.85, 0.4, 1))
	grad.add_point(0.4, Color(1.0, 0.45, 0.1, 0.9))
	grad.set_color(grad.get_point_count() - 1, Color(0.6, 0.1, 0.02, 0))
	ps.color_ramp = grad
	var q := QuadMesh.new()
	q.size = Vector2(0.5, 0.5) * size
	q.material = fire_mat()
	ps.mesh = q
	ps.position = p
	root.add_child(ps)

static func fire_mat() -> StandardMaterial3D:
	if not _tex.has("fire_mat"):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = soft_tex()
		m.albedo_color = Color(1.6, 1.1, 0.7)
		m.disable_fog = true
		m.no_depth_test = false
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		_tex.fire_mat = m
	return _tex.fire_mat

func _build_rails(x0: float, x1: float, z: float) -> void:
	var iron := Look.toon(Color("#6b6a70"), null, 0.0)
	for s in [-0.75, 0.75]:
		_box(Vector3((x0 + x1) / 2, 0.2, z + s), Vector3(x1 - x0, 0.14, 0.14), iron)
	var tie := Look.toon(Color("#5a3d26"), null, 0.0)
	var x := x0 + 0.6
	while x < x1:
		_box(Vector3(x, 0.08, z), Vector3(0.5, 0.14, 2.3), tie, randf_range(-0.05, 0.05))
		x += 1.3

func _build_cart(p: Vector3) -> Node3D:
	var c := Node3D.new()
	c.position = p
	root.add_child(c)
	var wood := Look.toon(Color("#6e4a2c"), null, 0.03)
	var iron := Look.toon(Color("#3c3a40"), null, 0.02)
	var parts := [[Vector3(0, 1.15, 0), Vector3(2.6, 1.2, 1.8), wood], [Vector3(0, 1.8, 0), Vector3(2.75, 0.18, 1.95), iron], [Vector3(0, 0.75, 0), Vector3(2.7, 0.16, 1.86), iron]]
	for pt in parts:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = pt[1]
		mi.mesh = bm
		mi.material_override = pt[2]
		mi.position = pt[0]
		c.add_child(mi)
	for sx in [-0.85, 0.85]:
		for sz in [-0.95, 0.95]:
			var w := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.375
			cm.bottom_radius = 0.375
			cm.height = 0.18
			w.mesh = cm
			w.material_override = iron
			w.rotation.x = PI / 2
			w.position = Vector3(sx, 0.4, sz)
			c.add_child(w)
	var ore := Assets.prop("k_Iron_Nuggets")
	ore.position = Vector3(0, 1.45, 0)
	ore.scale = Vector3.ONE * 2.2
	c.add_child(ore)
	return c

func _build_bell(p: Vector3) -> void:
	var b := Node3D.new()
	b.position = p
	root.add_child(b)
	var wood := Look.toon(Color("#5b3c24"), null, 0.03)
	for s in [-1.6, 1.6]:
		var post := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.45, 6, 0.45)
		post.mesh = bm
		post.material_override = wood
		post.position = Vector3(s, 3, 0)
		b.add_child(post)
	var beam := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(4.2, 0.5, 0.55)
	beam.mesh = bb
	beam.material_override = wood
	beam.position.y = 6
	b.add_child(beam)
	bell_pivot = Node3D.new()
	bell_pivot.position.y = 5.75
	b.add_child(bell_pivot)
	var bell := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.3
	cm.bottom_radius = 1.25
	cm.height = 1.9
	cm.radial_segments = 20
	bell.mesh = cm
	var bm2 := Look.toon(Color(0.75, 0.55, 0.25), null, 0.03)
	bm2.set_shader_parameter("emission", Color(0.06, 0.035, 0.01))
	bell.material_override = bm2
	bell.position.y = -0.95
	bell_pivot.add_child(bell)

## Keep a small pool of OmniLights on the light sources nearest to a point.
class LightPool:
	var lights: Array[OmniLight3D] = []
	var sources: Array
	func _init(parent: Node3D, srcs: Array, n := 8) -> void:
		sources = srcs
		for i in n:
			var l := OmniLight3D.new()
			l.shadow_enabled = false
			l.omni_attenuation = 1.4
			parent.add_child(l)
			lights.append(l)
	func update(focus: Vector3, t: float) -> void:
		var sorted := sources.duplicate()
		sorted.sort_custom(func(a, b): return a.pos.distance_squared_to(focus) < b.pos.distance_squared_to(focus))
		for i in lights.size():
			var l := lights[i]
			if i >= sorted.size():
				l.visible = false
				continue
			var s: Dictionary = sorted[i]
			l.visible = true
			l.position = s.pos
			l.light_color = s.color
			l.omni_range = s.range
			# a little flicker on the flames
			var fl := 1.0 + (sin(t * 11.0 + i * 1.7) * 0.05 + sin(t * 23.0 + i) * 0.04 if s.get("flicker", true) else 0.0)
			l.light_energy = s.energy * fl
