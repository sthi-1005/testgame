class_name SkyBuilder
extends WorldBuilder
## Builds Skyroot Spire's visuals from a SkyLevel: sky and sun, the forest floor and background woods, the giant
## trees, every platform and ramp, rails, and the dressing. Bright, soft and toy-like, in the same toon shading as
## the rest of the game.

const C_GRASS := Color("#5fb54a")
const C_GRASS_HI := Color("#86cc58")
const C_BARK := Color("#8b5a3c")
const C_BARK_HI := Color("#a8734c")
const C_LEAF := [Color("#5fbf5f"), Color("#7fd062"), Color("#4aa65a"), Color("#9ad86a")]
const C_PLANK := Color("#c99a62")
const C_ROPE := Color("#e8d3a0")
const C_STONE := Color("#e6d8bc")
const C_STONE_SH := Color("#c9b693")
const C_ROOF := Color("#4fb3a9")
const C_GOLD := Color("#f2c14e")
const C_ROCK := Color("#b88f74")
const C_CAP := Color("#f4a259")
const C_GILL := Color("#f3dfbf")

var sky: SkyLevel
var sun: DirectionalLight3D
var env: Environment
var rng := RandomNumberGenerator.new()
var _mats := {}
var _sphere: SphereMesh

func _init(level: Level, parent: Node3D) -> void:
	super(level, parent)
	sky = level as SkyLevel
	rng.seed = 99
	_sphere = SphereMesh.new()
	_sphere.radius = 1.0
	_sphere.height = 2.0
	var mobile := Quality.tier == "mobile"
	_sphere.radial_segments = 12 if mobile else 20
	_sphere.rings = 6 if mobile else 10

func build() -> void:
	_environment()
	_ground()
	_forest()
	_giant(SkyLevel.SENTINEL, false)
	_giant(SkyLevel.ELDER, true)
	_giant(SkyLevel.SHELFWOOD, false)
	for p in sky.platforms:
		_platform(p)
	for r in sky.ramps:
		_ramp(r)
	_sky_dress()
	_clouds()
	_floaters()
	_bake()

## Merge every plain mesh that shares a material into one mesh: thousands of leaf balls, planks and posts
## become a few dozen draw calls, which phones need. Meshes with children (camera colliders) and imported
## props are left alone.
func _bake() -> void:
	var groups := {} # material -> SurfaceTool
	var done: Array = []
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.material_override == null or mi.get_child_count() > 0 or mi.mesh == null:
			continue
		var xf := mi.transform
		var p := mi.get_parent()
		while p != root and p is Node3D:
			xf = (p as Node3D).transform * xf
			p = p.get_parent()
		if p != root:
			continue
		var m := mi.material_override
		if not groups.has(m):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[m] = st
		for i in mi.mesh.get_surface_count():
			groups[m].append_from(mi.mesh, i, xf)
		done.append(mi)
	for mi in done:
		mi.get_parent().remove_child(mi)
		mi.free()
	for m in groups:
		var out := MeshInstance3D.new()
		out.mesh = groups[m].commit()
		out.material_override = m
		out.name = "Baked"
		root.add_child(out)

# ------------------------------------------------------------------ materials and textures
func mat(key: String, color: Color, tex: Texture2D = null, ink := 0.03, uv := Vector2.ONE) -> ShaderMaterial:
	if not _mats.has(key):
		_mats[key] = Look.toon(color, tex, ink, uv)
	return _mats[key]

static var _stex := {}

static func noise_tex(key: String, lo: Color, hi: Color, freq := 0.04, size := 128) -> Texture2D:
	if not _stex.has(key):
		var n := FastNoiseLite.new()
		n.seed = key.hash()
		n.frequency = freq
		n.fractal_octaves = 3
		var src := n.get_seamless_image(size, size)
		var img := Image.create(size, size, false, Image.FORMAT_RGB8)
		for y in size:
			for x in size:
				img.set_pixel(x, y, lo.lerp(hi, clampf(src.get_pixel(x, y).r * 1.3 - 0.15, 0, 1)))
		img.generate_mipmaps()
		_stex[key] = ImageTexture.create_from_image(img)
	return _stex[key]

static func plank_tex() -> Texture2D:
	if not _stex.has("plank"):
		var size := 128
		var img := Image.create(size, size, false, Image.FORMAT_RGB8)
		var n := FastNoiseLite.new()
		n.frequency = 0.08
		for y in size:
			var board := y / 16
			var shade := 0.92 + 0.08 * sin(board * 2.7)
			for x in size:
				var grain := n.get_noise_2d(x * 0.25, y * 3.0) * 0.08
				var c := C_PLANK * (shade + grain)
				if y % 16 == 0 or (x + board * 37) % 128 == 0:
					c = C_PLANK * 0.62
				c.a = 1.0
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		_stex.plank = ImageTexture.create_from_image(img)
	return _stex.plank

static func tile_tex() -> Texture2D:
	if not _stex.has("tile"):
		var size := 128
		var img := Image.create(size, size, false, Image.FORMAT_RGB8)
		for y in size:
			for x in size:
				var c := C_STONE * 0.92
				var tx := x % 32
				var ty := y % 32
				if tx < 2 or ty < 2:
					c = C_STONE_SH * 0.9
				elif ((x / 32) + (y / 32)) % 2 == 0:
					c = C_STONE * 0.86
				c.a = 1.0
				img.set_pixel(x, y, c)
		img.generate_mipmaps()
		_stex.tile = ImageTexture.create_from_image(img)
	return _stex.tile

# ------------------------------------------------------------------ mesh helpers
func _mi(mesh: Mesh, m: Material, pos := Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	(parent if parent else root).add_child(mi)
	return mi

func _ball(pos: Vector3, r: Vector3, m: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := _mi(_sphere, m, pos, parent)
	mi.scale = r
	return mi

func _bx(pos: Vector3, size: Vector3, m: Material, rot := Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := _mi(bm, m, pos, parent)
	mi.rotation = rot
	return mi

func _cyl(pos: Vector3, r0: float, r1: float, h: float, m: Material, segs := 16, parent: Node3D = null) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.bottom_radius = r0
	cm.top_radius = r1
	cm.height = h
	cm.radial_segments = segs
	cm.rings = 1
	return _mi(cm, m, pos + Vector3(0, h / 2, 0), parent)

## A beam (box) from a to b with a square cross-section.
func _beam(a: Vector3, b: Vector3, w: float, m: Material) -> MeshInstance3D:
	var mi := _bx((a + b) / 2, Vector3(w, w, a.distance_to(b)), m)
	mi.look_at_from_position((a + b) / 2, b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.RIGHT)
	return mi

## A flat slab from a 2D outline (world x, z): top at y, sides down by depth, optional underside cone down by under.
func _slab(poly: PackedVector2Array, y: float, depth: float, top: Material, side: Material, under := 0.0, under_mat: Material = null, uv_scale := 0.125) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := Geometry2D.triangulate_polygon(poly)
	for i in range(0, tris.size(), 3):
		for k in [0, 1, 2]:
			var p := poly[tris[i + k]]
			st.set_uv(p * uv_scale)
			st.add_vertex(Vector3(p.x, y, p.y))
	st.generate_normals()
	_mi(st.commit(), top)
	# sides, subdivided so the edge reads as one soft band
	var ss := SurfaceTool.new()
	ss.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var a0 := Vector3(a.x, y, a.y)
		var b0 := Vector3(b.x, y, b.y)
		var a1 := Vector3(a.x, y - depth, a.y)
		var b1 := Vector3(b.x, y - depth, b.y)
		var L := a.distance_to(b)
		for q in [[a0, 0.0, 0.0], [b1, L, depth], [b0, L, 0.0], [a0, 0.0, 0.0], [a1, 0.0, depth], [b1, L, depth]]:
			ss.set_uv(Vector2(q[1], q[2]) * 0.25)
			ss.add_vertex(q[0])
	ss.generate_normals()
	_mi(ss.commit(), side)
	if under <= 0.0:
		return
	# underside: shrinking rings with a little jitter, down to a point
	var us := SurfaceTool.new()
	us.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= n
	var rings := 4
	var prev: Array = []
	for p in poly:
		prev.append(Vector3(p.x, y - depth, p.y))
	var dense := _densify(poly, 6.0)
	prev = []
	for p in dense:
		prev.append(Vector3(p.x, y - depth, p.y))
	for r in range(1, rings + 1):
		var t := float(r) / rings
		var k := 1.0 - pow(t, 0.8)
		var cur: Array = []
		for i in dense.size():
			var p := c + (dense[i] - c) * k
			var j := rng.randf_range(-1.0, 1.0) * (1.0 - t) * 1.2
			cur.append(Vector3(p.x + j, y - depth - under * t * (0.85 + 0.3 * rng.randf()), p.y + j))
		for i in dense.size():
			var a0: Vector3 = prev[i]
			var b0: Vector3 = prev[(i + 1) % dense.size()]
			var a1: Vector3 = cur[i]
			var b1: Vector3 = cur[(i + 1) % dense.size()]
			for v in [a0, b1, b0, a0, a1, b1]:
				us.set_uv(Vector2(v.x + v.z, v.y) * 0.08)
				us.add_vertex(v)
		prev = cur
	us.generate_normals()
	_mi(us.commit(), under_mat if under_mat else side)

static func _densify(poly: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var n := maxi(1, ceili(a.distance_to(b) / step))
		for k in n:
			out.append(a.lerp(b, float(k) / n))
	return out

## Extrude a cross-section profile (u across, v up) along a straight segment from a to b. Profile is open (left to right).
func _extrude(a: Vector3, b: Vector3, profile: Array, m: Material, flare := 0.0) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fwd := (b - a)
	var flat := Vector3(fwd.x, 0, fwd.z).normalized()
	var side := flat.cross(Vector3.UP).normalized()
	var segs := 8
	for s in segs:
		var t0 := float(s) / segs
		var t1 := float(s + 1) / segs
		var w0 := 1.0 + flare * (pow(1.0 - t0, 6.0) + pow(t0, 6.0))
		var w1 := 1.0 + flare * (pow(1.0 - t1, 6.0) + pow(t1, 6.0))
		for i in profile.size() - 1:
			var p: Vector2 = profile[i]
			var q: Vector2 = profile[i + 1]
			var A := a.lerp(b, t0) + side * p.x * w0 + Vector3.UP * p.y * w0
			var B := a.lerp(b, t0) + side * q.x * w0 + Vector3.UP * q.y * w0
			var Cc := a.lerp(b, t1) + side * q.x * w1 + Vector3.UP * q.y * w1
			var Dd := a.lerp(b, t1) + side * p.x * w1 + Vector3.UP * p.y * w1
			for v in [[A, t0, i], [Cc, t1, i + 1], [B, t0, i + 1], [A, t0, i], [Dd, t1, i], [Cc, t1, i + 1]]:
				st.set_uv(Vector2(v[2] * 0.6, v[1] * fwd.length() * 0.12))
				st.add_vertex(v[0])
	st.generate_normals()
	_mi(st.commit(), m)

# ------------------------------------------------------------------ sky, light, ground
func make_environment() -> Environment:
	return env

## Thin the haze as the party climbs so the drop below reads clearer from the top.
func grade(e: Environment, _zone: String, _delta: float) -> void:
	pass

func _environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#3f8fe0")
	sky_mat.sky_horizon_color = Color("#bfe6ff")
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color("#bfe6ff")
	sky_mat.ground_horizon_color = Color("#bfe6ff")
	sky_mat.sun_angle_max = 20.0
	sky_mat.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#d8ecff")
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.95
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color("#cfe9ff")
	env.fog_density = 0.0012
	env.fog_sky_affect = 0.0
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.2
	env.adjustment_contrast = 1.03
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.2
	sun = DirectionalLight3D.new()
	sun.light_color = Color("#fff1d6")
	sun.light_energy = 1.0
	sun.rotation = Vector3(deg_to_rad(-52), deg_to_rad(-35), 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	sun.shadow_blur = 1.5
	root.add_child(sun)

func _ground() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(1400, 1400)
	pm.subdivide_width = 1
	var g := mat("grass", Color.WHITE, noise_tex("grass", C_GRASS * 0.9, C_GRASS_HI, 0.05), 0.0, Vector2(60, 60))
	_mi(pm, g, Vector3(lv.gw * SkyLevel.T / 2, 0, lv.gh * SkyLevel.T / 2))

## Background woods: round-crowned trees everywhere off the route, denser further out, so every view down lands on canopy.
func _forest() -> void:
	var trunk := mat("bark", Color.WHITE, noise_tex("bark", C_BARK * 0.85, C_BARK_HI, 0.09), 0.04, Vector2(1, 3))
	var T := SkyLevel.T
	var w := lv.gw * T
	var h := lv.gh * T
	var placed := 0
	var tries := 0
	var want := 90 if Quality.tier == "mobile" else 170
	while placed < want and tries < 3000:
		tries += 1
		var p := Vector3(rng.randf_range(-160, w + 160), 0, rng.randf_range(-160, h + 160))
		if _near_route(p, 9.0):
			continue
		var far := 1.0 if p.x < -20 or p.z < -20 or p.x > w + 20 or p.z > h + 20 else 0.0
		var size := rng.randf_range(0.7, 1.3) * (1.0 + far * 0.6)
		_tree(p, size, trunk)
		placed += 1

func _near_route(p: Vector3, margin: float) -> bool:
	var T := SkyLevel.T
	for dz in [-margin, 0.0, margin]:
		for dx in [-margin, 0.0, margin]:
			if lv.cell_at(p.x + dx, p.z + dz):
				return true
	for t in [SkyLevel.ELDER, SkyLevel.SHELFWOOD, SkyLevel.SENTINEL]:
		if Vector2(p.x - t[0] * T, p.z - t[1] * T).length() < t[2] + margin + 6:
			return true
	return false

func _tree(p: Vector3, size: float, trunk: Material, parent: Node3D = null) -> void:
	var th := rng.randf_range(14, 26) * size
	var tr := rng.randf_range(0.9, 1.4) * size
	_cyl(p, tr * 1.25, tr * 0.8, th, trunk, 10, parent)
	var leaf: Material = mat("leaf%d" % (rng.randi() % 4), C_LEAF[rng.randi() % 4], null, 0.02)
	var n := rng.randi_range(3, 6)
	var cr := rng.randf_range(5.5, 8.0) * size
	_ball(p + Vector3(0, th + cr * 0.3, 0), Vector3.ONE * cr, leaf, parent)
	for i in n:
		var a := TAU * i / n + rng.randf()
		var r := cr * rng.randf_range(0.55, 0.8)
		var q := p + Vector3(cos(a) * cr * 0.75, th + rng.randf_range(-0.4, 0.5) * cr, sin(a) * cr * 0.75)
		_ball(q, Vector3.ONE * r, mat("leaf%d" % ((i + 1) % 4), C_LEAF[(i + 1) % 4], null, 0.02), parent)

## A giant tree: flared roots, a tapering trunk with a few side boughs, and a huge layered crown.
func _giant(t: Array, deck: bool) -> void:
	var T := SkyLevel.T
	var c := Vector3(t[0] * T, 0, t[1] * T)
	var r: float = t[2]
	var h: float = t[3]
	var bark := mat("bark_big", Color.WHITE, noise_tex("bark_big", C_BARK * 0.8, C_BARK_HI, 0.06), 0.06, Vector2(3, 6))
	add_camera_collider(_cyl(c, r * 1.15, r * 0.95, h * 0.5, bark, 24))
	add_camera_collider(_cyl(c + Vector3(0, h * 0.5, 0), r * 0.95, r * 0.6, h * 0.5, bark, 24))
	for i in 6:
		var a := TAU * i / 6 + 0.4
		var d := Vector3(cos(a), 0, sin(a))
		_beam(c + d * r * 0.6 + Vector3(0, r * 0.9, 0), c + d * (r * 1.9) + Vector3(0, -0.5, 0), r * 0.55, bark)
	# side boughs high up, each ending in a leaf cluster
	for i in 5:
		var a := TAU * i / 5 + 1.1
		var d := Vector3(cos(a), 0, sin(a))
		var y0 := h * rng.randf_range(0.62, 0.85)
		var tip := c + d * (r + h * 0.32) + Vector3(0, y0 + h * 0.12, 0)
		_beam(c + Vector3(0, y0, 0), tip, r * 0.32, bark)
		_ball(tip + Vector3(0, 2, 0), Vector3(1.2, 0.8, 1.2) * h * 0.13, mat("leaf%d" % (i % 4), C_LEAF[i % 4], null, 0.02))
	var crown := h * 0.3
	_ball(c + Vector3(0, h + crown * 0.25, 0), Vector3(1.3, 0.75, 1.3) * crown, mat("leaf1", C_LEAF[1], null, 0.02))
	for i in 7:
		var a := TAU * i / 7 + 0.3
		var q := c + Vector3(cos(a) * crown * 0.95, h - crown * 0.1 + rng.randf_range(-3, 4), sin(a) * crown * 0.95)
		_ball(q, Vector3(1.0, 0.7, 1.0) * crown * rng.randf_range(0.55, 0.75), mat("leaf%d" % (i % 4), C_LEAF[i % 4], null, 0.02))
	# a few high leaves dangling vines for the deck tree
	if deck:
		var vine := mat("vine", Color("#3f8a3f"), null, 0.0)
		for i in 7:
			var a := TAU * i / 7 + 0.2
			var top := h * 0.75
			var len := rng.randf_range(16, 28)
			_cyl(c + Vector3(cos(a) * (r + 9), top - len, sin(a) * (r + 9)), 0.05, 0.08, len, vine, 4)

# ------------------------------------------------------------------ platforms
func _platform(p: Dictionary) -> void:
	var poly := SkyLevel.outline(p)
	var y: float = p.h
	match p.kind:
		"glade":
			var g := mat("glade", Color.WHITE, noise_tex("glade", C_GRASS * 1.02, C_GRASS_HI * 1.05, 0.07), 0.0, Vector2.ONE)
			_slab(poly, 0.06, 0.06, g, g, 0.0, null, 0.06)
			_flowers(poly, 0.06, 70)
		"fungus":
			var cap := mat("cap", Color.WHITE, noise_tex("cap", C_CAP * 0.95, Color("#f7c27c"), 0.08), 0.05)
			_slab(poly, y, 1.4, cap, mat("cap_side", C_CAP * 0.9, null, 0.05), 4.0, mat("gill", C_GILL, null, 0.03), 0.05)
			_rails(poly, y, "wood")
		"deck":
			var wood := mat("deck", Color.WHITE, plank_tex(), 0.0, Vector2.ONE)
			_slab(poly, y, 0.9, wood, mat("deck_side", C_PLANK * 0.8, null, 0.04), 0.0, null, 0.25)
			_deck_supports(p)
			_rails(poly, y, "wood")
		"isle":
			var g := mat("isle_grass", Color.WHITE, noise_tex("isle", C_GRASS, C_GRASS_HI * 1.05, 0.06), 0.0)
			var rock := mat("rock", Color.WHITE, noise_tex("rock", C_ROCK * 0.85, C_ROCK * 1.1, 0.1), 0.06)
			_slab(poly, y, 1.6, g, rock, 18.0, rock, 0.06)
			_flowers(poly, y, 40)
			_rails(poly, y, "hedge")
		"temple":
			var tile := mat("tile", Color.WHITE, tile_tex(), 0.0)
			var rock := mat("rock", Color.WHITE, noise_tex("rock", C_ROCK * 0.85, C_ROCK * 1.1, 0.1), 0.06)
			_slab(poly, y, 2.2, tile, mat("stone", C_STONE_SH, null, 0.05), 22.0, rock, 0.1)
			# gold trim band just under the floor edge
			var trim := PackedVector2Array()
			for q in poly:
				trim.append(q)
			_slab(_grow(poly, 0.35), y - 0.6, 0.5, mat("gold", C_GOLD, null, 0.03), mat("gold", C_GOLD, null, 0.03))
			_rails(poly, y, "stone")

static func _grow(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var r := Geometry2D.offset_polygon(poly, d)
	return r[0] if r.size() else poly

func _flowers(poly: PackedVector2Array, y: float, n: int) -> void:
	var cols := [Color("#ffffff"), Color("#ffd166"), Color("#ff8fab"), Color("#c3a6ff")]
	var bb := Rect2(poly[0], Vector2.ZERO)
	for q in poly:
		bb = bb.expand(q)
	var stem := mat("stem", Color("#4f9e46"), null, 0.0)
	for i in n:
		var q := Vector2(rng.randf_range(bb.position.x, bb.end.x), rng.randf_range(bb.position.y, bb.end.y))
		if not Geometry2D.is_point_in_polygon(q, poly):
			continue
		if rng.randf() < 0.55:
			# grass tuft
			var tuft := mat("tuft", C_GRASS * 0.8, null, 0.0)
			for k in 3:
				var o := Vector3(rng.randf_range(-0.4, 0.4), 0, rng.randf_range(-0.4, 0.4))
				var blade := _cyl(Vector3(q.x, y, q.y) + o, 0.12, 0.0, rng.randf_range(0.5, 0.9), tuft, 4)
				blade.rotation = Vector3(rng.randf_range(-0.3, 0.3), 0, rng.randf_range(-0.3, 0.3))
		else:
			var col: Color = cols[rng.randi() % cols.size()]
			_cyl(Vector3(q.x, y, q.y), 0.05, 0.05, 0.45, stem, 4)
			_ball(Vector3(q.x, y + 0.5, q.y), Vector3(0.22, 0.14, 0.22), mat("petal%s" % col.to_html(), col, null, 0.015))

## Rails along a platform outline, with gaps wherever a walkway leaves it.
func _rails(poly: PackedVector2Array, y: float, style: String) -> void:
	var dense := _densify(poly, 1.0)
	var n := dense.size()
	var open: Array = []
	for i in n:
		var a := dense[i]
		var b := dense[(i + 1) % n]
		var out := (b - a).orthogonal().normalized() # outward for a clockwise-in-screen (x right, z down) outline
		var probe := (a + b) / 2 + out * 2.0
		var inside := (a + b) / 2 - out * 2.0
		if lv.cell_at(inside.x, inside.y) == 0:
			out = -out
			probe = (a + b) / 2 + out * 2.0
		open.append(lv.cell_at(probe.x, probe.y) == 1)
	# runs of closed samples
	var start := -1
	for i in n:
		if not open[i]:
			start = i
			break
	if start < 0:
		return
	var run: Array = []
	for k in n + 1:
		var i := (start + k) % n
		if k < n and not open[i]:
			run.append(dense[i])
			continue
		if run.size() > 0:
			run.append(dense[i])
			_rail_run(run, y, style)
		run = []

func _rail_run(pts: Array, y: float, style: String) -> void:
	if pts.size() < 2:
		return
	match style:
		"wood":
			var post := mat("post", C_PLANK * 0.72, null, 0.03)
			var rope := mat("rope", C_ROPE, null, 0.0)
			var i := 0
			while i < pts.size():
				var p: Vector2 = pts[i]
				_bx(Vector3(p.x, y + 0.6, p.y), Vector3(0.35, 1.2, 0.35), post)
				_ball(Vector3(p.x, y + 1.25, p.y), Vector3.ONE * 0.24, post)
				var j := mini(i + 3, pts.size() - 1)
				if j > i:
					var q: Vector2 = pts[j]
					_beam(Vector3(p.x, y + 1.1, p.y), Vector3(q.x, y + 1.1, q.y), 0.12, rope)
					_beam(Vector3(p.x, y + 0.55, p.y), Vector3(q.x, y + 0.55, q.y), 0.1, rope)
				if j == i:
					break
				i = j
		"stone":
			var st := mat("baluster", C_STONE, null, 0.03)
			var cap := mat("rail_cap", C_STONE_SH, null, 0.03)
			for k in range(0, pts.size(), 1):
				var p: Vector2 = pts[k]
				_cyl(Vector3(p.x, y, p.y), 0.22, 0.16, 0.85, st, 8)
			for k in pts.size() - 1:
				var a: Vector2 = pts[k]
				var b: Vector2 = pts[k + 1]
				_beam(Vector3(a.x, y + 0.95, a.y), Vector3(b.x, y + 0.95, b.y), 0.3, cap)
		"hedge":
			for k in range(0, pts.size(), 2):
				var p: Vector2 = pts[k]
				_ball(Vector3(p.x, y + 0.35, p.y), Vector3(1.0, 0.65, 1.0) * rng.randf_range(0.8, 1.2), mat("leaf%d" % (k % 4), C_LEAF[k % 4], null, 0.03))

func _deck_supports(p: Dictionary) -> void:
	var T := SkyLevel.T
	var c := Vector3(SkyLevel.ELDER[0] * T, p.h, SkyLevel.ELDER[1] * T)
	var beam := mat("post", C_PLANK * 0.72, null, 0.03)
	var poly := SkyLevel.outline(p)
	for q in poly:
		var e := Vector3(q.x, p.h - 0.8, q.y)
		var d := (e - c)
		d.y = 0
		_beam(c + d.normalized() * SkyLevel.ELDER[2] + Vector3(0, -12, 0), e, 0.7, beam)
		_beam(c + d.normalized() * SkyLevel.ELDER[2] + Vector3(0, -0.8, 0), e, 0.6, beam)

# ------------------------------------------------------------------ ramps
func _ramp_ends(r: Dictionary) -> Array:
	var T := SkyLevel.T
	var x0: float = r.x0 * T
	var x1: float = (r.x1 + 1) * T
	var z0: float = r.z0 * T
	var z1: float = (r.z1 + 1) * T
	var cx := (x0 + x1) / 2
	var cz := (z0 + z1) / 2
	var a: Vector3
	var b: Vector3
	var w: float
	match r.axis:
		"+x": a = Vector3(x0, r.h0, cz); b = Vector3(x1, r.h1, cz); w = z1 - z0
		"-x": a = Vector3(x1, r.h0, cz); b = Vector3(x0, r.h1, cz); w = z1 - z0
		"+z": a = Vector3(cx, r.h0, z0); b = Vector3(cx, r.h1, z1); w = x1 - x0
		"-z": a = Vector3(cx, r.h0, z1); b = Vector3(cx, r.h1, z0); w = x1 - x0
	return [a, b, w]

func _ramp(r: Dictionary) -> void:
	var e := _ramp_ends(r)
	var a: Vector3 = e[0]
	var b: Vector3 = e[1]
	var w: float = e[2]
	var hw := w / 2
	var bark := mat("bark_big", Color.WHITE, noise_tex("bark_big", C_BARK * 0.8, C_BARK_HI, 0.06), 0.06, Vector2(3, 6))
	match r.kind:
		"root", "bough":
			# flat-topped log: walkable top, rounded flanks, a fat belly underneath
			var prof := [Vector2(-hw - 0.4, -0.6), Vector2(-hw, -0.05), Vector2(-hw * 0.5, 0.05), Vector2(hw * 0.5, 0.05), Vector2(hw, -0.05),
				Vector2(hw + 0.4, -0.6)]
			var belly := [Vector2(hw + 0.4, -0.6), Vector2(hw + 1.2, -3.0), Vector2(hw * 0.7, -6.5), Vector2(0, -7.5), Vector2(-hw * 0.7, -6.5),
				Vector2(-hw - 1.2, -3.0), Vector2(-hw - 0.4, -0.6)]
			var top := mat("bark_top", Color.WHITE, noise_tex("bark_top", C_BARK_HI * 0.95, C_BARK_HI * 1.15, 0.05), 0.0, Vector2(2, 2))
			_extrude(a, b, prof, top, 0.25 if r.kind == "root" else 0.0)
			_extrude(a, b, belly, bark, 0.25 if r.kind == "root" else 0.0)
			_ramp_rail(a, b, hw, "wood")
			if r.kind == "bough":
				for i in 5:
					var t := (i + 0.5) / 5.0
					var p := a.lerp(b, t)
					var side := (b - a).cross(Vector3.UP).normalized() * (1 if i % 2 else -1)
					var tip := p + side * rng.randf_range(9, 14) + Vector3(0, rng.randf_range(2, 6), 0)
					_beam(p + Vector3(0, -3, 0), tip, 1.0, bark)
					_ball(tip, Vector3(1.0, 0.75, 1.0) * rng.randf_range(4, 6), mat("leaf%d" % (i % 4), C_LEAF[i % 4], null, 0.02))
		"rope":
			var plank := mat("slat", Color.WHITE, plank_tex(), 0.02)
			var L := a.distance_to(b)
			var n := int(L / 1.05)
			var dir := (b - a).normalized()
			for i in n:
				var p := a.lerp(b, (i + 0.5) / n) + Vector3(0, -0.12, 0)
				var mi := _bx(p, Vector3(w + 0.4, 0.22, 0.85), plank)
				mi.look_at_from_position(p, p + dir, Vector3.UP)
				mi.rotate_object_local(Vector3.UP, 0.0)
				mi.scale = Vector3((w + 0.4) / (w + 0.4), 1, 1)
				mi.rotation.y += rng.randf_range(-0.03, 0.03)
			# two long stringers underneath and the rope rails
			var side := (b - a).cross(Vector3.UP).normalized()
			var rope := mat("rope", C_ROPE, null, 0.0)
			for s: float in [-1.0, 1.0]:
				_beam(a + side * s * (hw - 0.6) + Vector3(0, -0.4, 0), b + side * s * (hw - 0.6) + Vector3(0, -0.4, 0), 0.3, mat("post", C_PLANK * 0.72, null, 0.03))
			_ramp_rail(a, b, hw, "wood")
			# saggy ropes below for the swing-bridge read
			for s: float in [-1.0, 1.0]:
				var prev := a + side * s * hw
				for k in range(1, 13):
					var t := k / 12.0
					var q := a.lerp(b, t) + side * s * hw + Vector3(0, -sin(t * PI) * 2.5 - 0.2, 0)
					_beam(prev, q, 0.08, rope)
					prev = q
		"steps":
			var stone := mat("stone_step", Color.WHITE, tile_tex(), 0.04, Vector2(0.5, 0.5))
			var rock := mat("rock", Color.WHITE, noise_tex("rock", C_ROCK * 0.85, C_ROCK * 1.1, 0.1), 0.06)
			var L := a.distance_to(Vector3(b.x, a.y, b.z))
			var steps := int(round((r.h1 - r.h0) / r.step))
			var dir := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
			for i in steps + 1:
				var t := (i + 0.5) / (steps + 1)
				var y := SkyLevel.ramp_h(r, t)
				var p := Vector3(a.x, y, a.z) + dir * L * t
				var slab := _bx(p + Vector3(0, -0.4, 0), Vector3(w - 0.6, 0.8, L / (steps + 1) - 0.25), stone)
				slab.look_at_from_position(slab.position, slab.position + dir, Vector3.UP)
				# a little rock keel under every few steps so they read as floating stones
				if i % 2 == 0:
					var k := _ball(p + Vector3(0, -1.7, 0), Vector3(w * 0.3, 0.9, 0.7), rock)
					k.rotation.y = atan2(dir.x, dir.z) + PI / 2
			_ramp_rail(a, b, hw, "stone_posts", r)

func _ramp_rail(a: Vector3, b: Vector3, hw: float, style: String, r := {}) -> void:
	var side := (b - a).cross(Vector3.UP).normalized()
	var L := Vector2(b.x - a.x, b.z - a.z).length()
	var n := maxi(2, int(L / 4.0))
	var post := mat("post", C_PLANK * 0.72, null, 0.03)
	var rope := mat("rope", C_ROPE, null, 0.0)
	var st := mat("baluster", C_STONE, null, 0.03)
	for s: float in [-1.0, 1.0]:
		var prev := Vector3.INF
		for i in n + 1:
			var t := float(i) / n
			var p := a.lerp(b, t) + side * s * (hw - 0.25)
			if style == "stone_posts":
				p.y = SkyLevel.ramp_h(r, clampf(t, 0.02, 0.98))
				_cyl(p, 0.3, 0.22, 1.3, st, 8)
				_ball(p + Vector3(0, 1.4, 0), Vector3.ONE * 0.3, mat("gold", C_GOLD, null, 0.03))
				continue
			_bx(p + Vector3(0, 0.6, 0), Vector3(0.35, 1.25, 0.35), post)
			if prev != Vector3.INF:
				_beam(prev + Vector3(0, 1.15, 0), p + Vector3(0, 1.15, 0), 0.12, rope)
				_beam(prev + Vector3(0, 0.6, 0), p + Vector3(0, 0.6, 0), 0.1, rope)
			prev = p

# ------------------------------------------------------------------ dressing
func _sky_dress() -> void:
	var bark := mat("bark", Color.WHITE, noise_tex("bark", C_BARK * 0.85, C_BARK_HI, 0.09), 0.04, Vector2(1, 3))
	for e in sky.decor:
		match e.kind:
			"tree":
				_tree(e.pos, e.scale, bark)
			"mushroom":
				_mushroom(e.pos, e.scale, e.get("glow", false))
			"prop":
				var n := Assets.prop(e.model)
				n.position = e.pos
				n.rotation.y = e.rot
				n.scale = Vector3.ONE * float(e.scale)
				root.add_child(n)
				if e.get("glow", false):
					_glow_tint(n, Color("#7ff0ff"))
					light_sources.append({ "pos": e.pos + Vector3(0, 2, 0), "color": Color("#9ff3ff"), "range": 12.0, "energy": 1.2 })
				if e.get("fire", false):
					light_sources.append({ "pos": e.pos + Vector3(0, 1.5, 0), "color": Color(1, 0.7, 0.4), "range": 14.0, "energy": 1.5 })
			"hut":
				_hut(e.pos, e.rot)
			"column":
				_column(e.pos)
			"altar":
				_altar(e.pos)

func _glow_tint(n: Node, c: Color) -> void:
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			if src is ShaderMaterial:
				var cp := (src as ShaderMaterial).duplicate() as ShaderMaterial
				cp.set_shader_parameter("emission", c * 0.6)
				cp.set_shader_parameter("tint", c)
				mi.set_surface_override_material(i, cp)

func _mushroom(p: Vector3, s: float, glow: bool) -> void:
	var stem := mat("mush_stem", Color("#fbeedd"), null, 0.03)
	var cap_c := Color("#e85d5d") if not glow else Color("#5cc8e8")
	var cap := mat("mush_cap%s" % glow, cap_c, null, 0.04)
	if glow:
		cap.set_shader_parameter("emission", cap_c * 0.35)
	_cyl(p, 0.45 * s, 0.32 * s, 1.4 * s, stem, 10)
	_ball(p + Vector3(0, 1.45 * s, 0), Vector3(1.25, 0.7, 1.25) * s, cap)
	var dot := mat("mush_dot", Color("#ffffff"), null, 0.0)
	for i in 5:
		var a := TAU * i / 5 + rng.randf()
		_ball(p + Vector3(cos(a) * 0.8 * s, 1.85 * s, sin(a) * 0.8 * s), Vector3.ONE * 0.16 * s, dot)

func _hut(p: Vector3, rot: float) -> void:
	var n := Node3D.new()
	n.position = p
	n.rotation.y = rot
	root.add_child(n)
	var wall := mat("hut_wall", Color.WHITE, plank_tex(), 0.04, Vector2(1, 1))
	var roof := mat("roof", C_ROOF, null, 0.05)
	add_camera_collider(_cyl(Vector3.ZERO, 3.2, 3.0, 3.4, wall, 14, n))
	var cone := CylinderMesh.new()
	cone.bottom_radius = 4.4
	cone.top_radius = 0.2
	cone.height = 3.2
	cone.radial_segments = 14
	_mi(cone, roof, Vector3(0, 5.0, 0), n)
	_bx(Vector3(0, 1.2, 3.05), Vector3(1.4, 2.3, 0.3), mat("door", Color("#7a4e2e"), null, 0.03), Vector3.ZERO, n)
	_ball(Vector3(0, 6.7, 0), Vector3.ONE * 0.35, mat("gold", C_GOLD, null, 0.03), n)

func _column(p: Vector3) -> void:
	var st := mat("column", C_STONE, null, 0.04)
	var gold := mat("gold", C_GOLD, null, 0.03)
	_cyl(p, 1.5, 1.5, 0.6, mat("stone", C_STONE_SH, null, 0.05), 12)
	add_camera_collider(_cyl(p + Vector3(0, 0.6, 0), 1.05, 0.9, 8.5, st, 14))
	_cyl(p + Vector3(0, 9.1, 0), 1.0, 1.45, 0.7, gold, 12)
	_bx(p + Vector3(0, 10.1, 0), Vector3(3.0, 0.6, 3.0), st)
	# a floating teal crown stone above each column
	_ball(p + Vector3(0, 12.0, 0), Vector3(0.8, 1.1, 0.8), mat("roof_glow", C_ROOF, null, 0.03))

func _altar(p: Vector3) -> void:
	var st := mat("column", C_STONE, null, 0.04)
	_cyl(p, 3.6, 3.4, 0.6, mat("stone", C_STONE_SH, null, 0.05), 20)
	_cyl(p + Vector3(0, 0.6, 0), 2.6, 2.4, 0.6, st, 20)
	var orb := mat("wind_orb", Color("#bff6ff"), null, 0.0)
	orb.set_shader_parameter("emission", Color("#7fe6ff") * 0.9)
	_ball(p + Vector3(0, 4.2, 0), Vector3.ONE * 1.3, orb)
	light_sources.append({ "pos": p + Vector3(0, 4.2, 0), "color": Color("#9ff3ff"), "range": 24.0, "energy": 2.0 })
	var gold := mat("gold", C_GOLD, null, 0.03)
	for i in 3:
		var ring := TorusMesh.new()
		ring.inner_radius = 2.0 + i * 0.6
		ring.outer_radius = 2.2 + i * 0.6
		var mi := _mi(ring, gold, p + Vector3(0, 4.2, 0))
		mi.rotation = Vector3(0.6 * i + 0.4, 0.9 * i, 0.3)

# ------------------------------------------------------------------ sky dressing
func _clouds() -> void:
	var white := mat("cloud", Color("#ffffff"), null, 0.0)
	white.set_shader_parameter("emission", Color(0.25, 0.27, 0.3))
	var T := SkyLevel.T
	var ctr := Vector3(lv.gw * T / 2, 0, lv.gh * T / 2)
	for i in 26:
		var a := rng.randf() * TAU
		var d := rng.randf_range(180, 420)
		var p := ctr + Vector3(cos(a) * d, rng.randf_range(55, 120), sin(a) * d)
		_cloud(p, rng.randf_range(10, 22), white)
	# low clouds drifting between the isles and the forest roof
	for c in [[2, 34, 22], [17, 14, 24], [-6, 8, 26], [24, 6, 30], [-8, 24, 20], [10, 38, 18]]:
		_cloud(Vector3(c[0] * T, c[2], c[1] * T), rng.randf_range(5, 8), white)

func _cloud(p: Vector3, s: float, m: Material) -> void:
	_ball(p, Vector3(1.6, 0.8, 1.2) * s, m)
	for k in 4:
		var o := Vector3(rng.randf_range(-1.4, 1.4), rng.randf_range(-0.2, 0.4), rng.randf_range(-0.8, 0.8)) * s
		_ball(p + o, Vector3.ONE * s * rng.randf_range(0.6, 0.9), m)

## Small decorative floating islands around the upper route, each with a tree or a shrine stone.
func _floaters() -> void:
	var T := SkyLevel.T
	var g := mat("isle_grass", Color.WHITE, noise_tex("isle", C_GRASS, C_GRASS_HI * 1.05, 0.06), 0.0)
	var rock := mat("rock", Color.WHITE, noise_tex("rock", C_ROCK * 0.85, C_ROCK * 1.1, 0.1), 0.06)
	var bark := mat("bark", Color.WHITE, noise_tex("bark", C_BARK * 0.85, C_BARK_HI, 0.09), 0.04, Vector2(1, 3))
	for f in [[-4, 14, 36, 5], [20, 4, 48, 6], [22, 18, 38, 4.5], [-6, 2, 50, 4], [-3, 33, 28, 5.5], [26, 12, 33, 3.5], [10, -6, 52, 5]]:
		var c := Vector2(f[0] * T, f[1] * T)
		var r: float = f[3]
		var poly := PackedVector2Array()
		for i in 9:
			var a := TAU * i / 9
			poly.append(c + Vector2(cos(a), sin(a)) * r * rng.randf_range(0.85, 1.15))
		_slab(poly, f[2], 1.0, g, rock, r * 2.2, rock)
		if rng.randf() < 0.6:
			_tree(Vector3(c.x, f[2], c.y), 0.45, bark)
		else:
			_column(Vector3(c.x, f[2], c.y))
