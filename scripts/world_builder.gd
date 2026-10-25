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

## Physics layer the gameplay camera collides with (bit value). Solid walls, ceilings and big rocks go here.
const CAMERA_LAYER := 2

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
		var src := img
		img = Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGB8) # the noise image is greyscale (L8) and would drop colour
		var lo := Color("#6d5240")
		var hi := Color("#94704f")
		for y in img.get_height():
			for x in img.get_width():
				img.set_pixel(x, y, lo.lerp(hi, src.get_pixel(x, y).r))
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
	# ceilings: flat over the built hall, rough sagging rock over the mine
	var ceil_mat := Look.toon(Color(0.42, 0.36, 0.31), dirt_tex(), 0.0)
	var cave := Cave.new()
	var rock := Look.toon(Color(1, 1, 1), rock_tex(), 0.0)
	var cave_st := {} # zone -> SurfaceTool, one mesh per zone keeps draw calls low and lights local
	for r in lv.rects:
		var w: float = (r[2] - r[0] + 1) * T + 2
		var d: float = (r[3] - r[1] + 1) * T + 2
		if _is_cave(r[4]):
			cave.ceiling(_cave_tool(cave_st, r[4]), r[0] * T - 1.5, r[1] * T - 1.5, (r[2] + 1) * T + 1.5, (r[3] + 1) * T + 1.5, lv.zone_h(r[4]) + 0.6)
			_stalactites(r, lv.zone_h(r[4]) + 0.6, cave)
			continue
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(w, d)
		pm.flip_faces = true
		mi.mesh = pm
		mi.material_override = ceil_mat
		_place(mi, Vector3((r[0] + r[2] + 1) * T / 2, lv.zone_h(r[4]), (r[1] + r[3] + 1) * T / 2), 0.0, 1.0)
		_camera_box(Vector3((r[0] + r[2] + 1) * T / 2, lv.zone_h(r[4]) + 0.5, (r[1] + r[3] + 1) * T / 2), Vector3(w, 1.0, d), 0.0)
	var wood := Look.toon(Color("#6a4529"), null, 0.03)
	for e in lv.decor:
		match e.kind:
			"wall":
				var c: Vector3 = e.pos - Vector3(e.dx, 0, e.dz) * (T / 2 + 0.5)
				var zn := lv.zone_at(c.x, c.z)
				if _is_cave(zn):
					var m: Vector3 = c + Vector3(e.dx, 0, e.dz) * (T / 2)
					var along := Vector3(absf(e.dz), 0, absf(e.dx))
					cave.wall(_cave_tool(cave_st, zn), m - along * T / 2, m + along * T / 2, -Vector3(e.dx, 0, e.dz), lv.zone_h(zn) + 0.6)
				else:
					for k in e.courses:
						_place(Assets.prop("dungeon-wall"), e.pos + Vector3(0, k * 4.0, 0), e.rot, 1.0)
					_camera_box(e.pos + Vector3(0, e.courses * 2.0, 0), Vector3(T + 0.4, e.courses * 4.0, 1.0), e.rot)
			"prop":
				if e.model == "dungeon-pillar" and _cave_corner(e.pos):
					continue # bare rock instead of masonry columns in the mine
				if e.model == "dungeon-pillar" and _is_cave(lv.zone_at(e.pos.x, e.pos.z)):
					_place(Assets.prop("q_rock_tall", 0.04), e.pos, e.rot, Vector3(2.4, 3.2, 2.4))
					continue
				_place(Assets.prop(e.model), e.pos, e.rot, e.scale)
				if e.model == "dungeon-pillar":
					var ps: Vector3 = e.scale if e.scale is Vector3 else Vector3.ONE * e.scale
					_camera_box(e.pos + Vector3(0, ps.y * 2.0, 0), Vector3(1.5 * ps.x, ps.y * 4.0, 1.5 * ps.z), e.rot)
			"timber":
				_box(e.pos, e.scale, wood, e.rot)
			"torch":
				_place(Assets.prop("dungeon-torch"), e.pos, e.rot, e.scale)
				fire_at(e.flame, 1.1)
				# keep the camera out of the flame: up close the light blows out the volumetric fog
				_camera_box(e.flame, Vector3(1.8, 1.8, 1.8), 0.0)
				light_sources.append({ "pos": e.light, "color": Color(1, 0.62, 0.35), "range": 18.0, "energy": 1.3 })
			"brazier":
				_place(Assets.prop(e.model), e.pos, e.rot, e.scale)
				fire_at(e.pos + Vector3(0, 1.4, 0), 2.2)
				light_sources.append({ "pos": e.pos + Vector3(0, 3, 0), "color": Color(1, 0.55, 0.25), "range": 16.0, "energy": 1.0 })
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
				# daylight pouring in through the mine mouth: a shadowed spot that lights the fog
				var sp := SpotLight3D.new()
				sp.light_color = Color(0.75, 0.85, 1.0)
				sp.light_energy = 6.0
				sp.spot_range = 40.0
				sp.spot_angle = 28.0
				sp.shadow_enabled = true
				sp.light_volumetric_fog_energy = 3.0
				_place(sp, e.pos + Vector3(0, 6, 3), 0.0, 1.0)
				sp.transform = sp.transform.looking_at(e.pos + Vector3(0, 0, -14))
			"rails":
				_build_rails(e.pos.x, e.x1, e.pos.z)
			"bell":
				_build_bell(e.pos)
	for p in lv.cart_starts():
		cart_nodes.append(_build_cart(p))
	for zn in cave_st:
		var st: SurfaceTool = cave_st[zn]
		st.index()
		st.generate_normals() # smooth normals: soft, rounded rock
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = rock
		mi.name = "Cave_" + zn
		root.add_child(mi)
		add_camera_collider(mi)
	_dress()

## Give a mesh a trimesh body on the camera layer, so the camera can't swing through it.
static func add_camera_collider(mi: MeshInstance3D) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = CAMERA_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = mi.mesh.create_trimesh_shape()
	body.add_child(cs)
	mi.add_child(body)

func _camera_box(pos: Vector3, size: Vector3, rot: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = CAMERA_LAYER
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	root.add_child(body)
	body.position = pos
	body.rotation.y = rot

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
	var shadow_count := 3
	func _init(parent: Node3D, srcs: Array, n := 8) -> void:
		sources = srcs
		for i in n:
			var l := OmniLight3D.new()
			l.shadow_enabled = false
			l.omni_attenuation = 1.4
			l.light_volumetric_fog_energy = 0.5 # full strength glares when the camera passes close to a flame
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
			l.shadow_enabled = i < shadow_count
			l.position = s.pos
			l.light_color = s.color
			l.omni_range = s.range
			# a little flicker on the flames
			var fl := 1.0 + (sin(t * 11.0 + i * 1.7) * 0.05 + sin(t * 23.0 + i) * 0.04 if s.get("flicker", true) else 0.0)
			l.light_energy = s.energy * fl

static func _is_cave(zone: String) -> bool:
	return zone != "hall" and zone != "gate" and zone != ""

func _cave_tool(d: Dictionary, zone: String) -> SurfaceTool:
	if not d.has(zone):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		d[zone] = st
	return d[zone]

func _cave_corner(p: Vector3) -> bool:
	var x := roundi(p.x / Level.T)
	var z := roundi(p.z / Level.T)
	if not is_equal_approx(p.x, x * Level.T) or not is_equal_approx(p.z, z * Level.T):
		return false
	for c in [[x - 1, z - 1], [x, z - 1], [x - 1, z], [x, z]]:
		if c[0] >= 0 and c[1] >= 0 and c[0] < Level.GW and c[1] < Level.GH and lv.cell(c[0], c[1]):
			if not _is_cave(lv.zone_of[c[1] * Level.GW + c[0]]):
				return false
	return true

static func rock_tex() -> Texture2D:
	if not _tex.has("rock"):
		_tex.rock = Cave.rock_tex()
	return _tex.rock

func _stalactites(r: Array, h: float, cave: Cave) -> void:
	var T := Level.T
	var m := Look.toon(Color(0.85, 0.82, 0.8), rock_tex(), 0.03)
	var n := int((r[2] - r[0] + 1) * (r[3] - r[1] + 1) * 1.2)
	for i in n:
		var x := randf_range(r[0] * T + 0.5, (r[2] + 1) * T - 0.5)
		var z := randf_range(r[1] * T + 0.5, (r[3] + 1) * T - 0.5)
		# keep the middle of the walkway clear so they don't hang in front of the camera
		var ex := minf(x - r[0] * T, (r[2] + 1) * T - x)
		var ez := minf(z - r[1] * T, (r[3] + 1) * T - z)
		var edge := minf(ex, ez)
		if edge > 2.2 and randf() < 0.8:
			continue
		var length := randf_range(0.5, 1.6) if edge > 2.2 else randf_range(0.6, 2.0)
		var mi := MeshInstance3D.new()
		mi.mesh = Cave.stalactite(length, randf_range(0.15, 0.4))
		mi.material_override = m
		mi.rotation = Vector3(randf_range(-0.15, 0.15), randf(), randf_range(-0.15, 0.15))
		_place(mi, Vector3(x, cave.ceiling_y(x, z, h) + 0.2 - length / 2, z), mi.rotation.y, 1.0)

## Visual-only dressing that the simulation doesn't need to know about.
func _dress() -> void:
	var T := Level.T
	# rails down the entrance tunnel and across the diggings
	_rail_z(3.5 * T, 15.0 * T, 27.0 * T)
	_rail_x(10 * T, 15 * T, 10.5 * T)
	_rail_x(21 * T, 23 * T, 9.5 * T)
	# lanterns hanging from the timber frames
	for e in lv.decor:
		if e.kind == "timber" and e.pos.y > 6.5 and e.pos.y < 7.5 and (e.scale.x > 6 or e.scale.z > 6) and randf() < 0.6:
			var p: Vector3 = e.pos + Vector3(0, -1.3, 0)
			_lantern(p)
	# glowing ore crystals in the diggings and the sorting cave
	for c in [[1.2, 7.3, Color(0.3, 0.8, 1.0)], [9.6, 11.6, Color(0.4, 0.9, 0.8)], [5.5, 14.6, Color(0.3, 0.7, 1.0)], [15.3, 11.5, Color(0.5, 0.6, 1.0)], [19.7, 9.2, Color(0.3, 0.9, 0.9)], [4.6, 19.0, Color(0.35, 0.75, 1.0)]]:
		var p := Vector3(c[0] * T, 0, c[1] * T)
		var cr := Assets.prop("q_crystal_rock", 0.03)
		_place(cr, p, randf() * TAU, 1.6)
		_tint_emissive(cr, c[2] * 1.6)
		light_sources.append({ "pos": p + Vector3(0, 1.5, 0), "color": c[2], "range": 9.0, "energy": 1.4, "flicker": false })
	# loose rubble and planks along the tunnel walls (small enough to ignore for collision)
	for z in range(15, 27):
		for side in [2.0 * T + 0.5, 5.0 * T - 0.5]:
			if randf() < 0.5:
				var m: String = ["k_Stone_Chunks_Small", "k_Rock_1_A_Color1", "k_Rock_2_A_Color1"][randi() % 3]
				_place(Assets.prop(m), Vector3(side + randf_range(-0.2, 0.2), 0, z * T + randf() * T), randf() * TAU, randf_range(0.6, 1.0))

func _rail_z(x: float, z0: float, z1: float) -> void:
	var iron := Look.toon(Color("#6b6a70"), null, 0.0)
	var tie := Look.toon(Color("#5a3d26"), null, 0.0)
	for s in [-0.75, 0.75]:
		_box(Vector3(x + s, 0.2, (z0 + z1) / 2), Vector3(0.14, 0.14, z1 - z0), iron)
	var z := z0 + 0.6
	while z < z1:
		_box(Vector3(x, 0.08, z), Vector3(2.3, 0.14, 0.5), tie, randf_range(-0.05, 0.05))
		z += 1.3

func _rail_x(x0: float, x1: float, z: float) -> void:
	_build_rails(x0, x1, z)

func _lantern(p: Vector3) -> void:
	var chain := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.03
	cm.height = 0.9
	chain.mesh = cm
	chain.material_override = Look.toon(Color("#2a2a2e"), null, 0.0)
	_place(chain, p + Vector3(0, 0.75, 0), 0.0, 1.0)
	var body := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.18
	bm.bottom_radius = 0.24
	bm.height = 0.5
	bm.radial_segments = 6
	body.mesh = bm
	var lm := Look.toon(Color("#ffcf80"), null, 0.02)
	lm.set_shader_parameter("emission", Color(1.0, 0.6, 0.25) * 0.55)
	body.material_override = lm
	_place(body, p, 0.0, 1.0)
	light_sources.append({ "pos": p + Vector3(0, -0.3, 0), "color": Color(1, 0.7, 0.4), "range": 12.0, "energy": 0.7 })

func _tint_emissive(n: Node, c: Color) -> void:
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if mat is ShaderMaterial:
				var copy := (mat as ShaderMaterial).duplicate() as ShaderMaterial
				copy.set_shader_parameter("tint", Color(c.r * 0.6 + 0.4, c.g * 0.6 + 0.4, c.b * 0.6 + 0.4))
				copy.set_shader_parameter("emission", c * 0.6)
				mi.set_surface_override_material(i, copy)

## Drifting dust in the air around a node (attach to the camera rig).
static func dust_motes() -> CPUParticles3D:
	var ps := CPUParticles3D.new()
	ps.amount = 160
	ps.lifetime = 6.0
	ps.preprocess = 6.0
	ps.local_coords = false
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	ps.emission_box_extents = Vector3(9, 4, 9)
	ps.direction = Vector3(0.3, 0.1, 0.2)
	ps.spread = 180
	ps.gravity = Vector3(0, -0.02, 0)
	ps.initial_velocity_min = 0.05
	ps.initial_velocity_max = 0.2
	ps.scale_amount_min = 0.5
	ps.scale_amount_max = 1.0
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 0.9, 0.75, 0))
	grad.add_point(0.3, Color(1, 0.9, 0.75, 0.5))
	grad.add_point(0.7, Color(1, 0.9, 0.75, 0.5))
	grad.set_color(grad.get_point_count() - 1, Color(1, 0.9, 0.75, 0))
	ps.color_ramp = grad
	var q := QuadMesh.new()
	q.size = Vector2(0.035, 0.035)
	var m := fire_mat().duplicate() as StandardMaterial3D
	m.albedo_color = Color(0.6, 0.55, 0.5)
	q.material = m
	ps.mesh = q
	return ps
