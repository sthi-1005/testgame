class_name CoastWorld
extends WorldBuilder
## Builds the visual coast from a CoastLevel: terrain heightfield (beach, sea floor, cliffs), the sea
## and the flooded sanctum water, paving, ruins, palms, camp dressing, sea stacks, islands and clouds.
## Procedural geometry is merged into a few vertex-coloured meshes to keep draw calls low on phones.

const STEP := 2.0 # terrain sample spacing (m)
const MARGIN := 140.0 # terrain beyond the play grid on every side

const SAND := Color("#f1d6a2")
const SAND_WET := Color("#d9bc8c")
const SEABED := Color("#9cc9b4")
const GRASS := Color("#8fd35e")
const GRASS_DARK := Color("#69b84a")
const ROCK_A := Color("#e4b98a")
const ROCK_B := Color("#c99a70")
const MARBLE := Color("#efe5d3")
const MARBLE_SHADE := Color("#dccdb5")
const ALGAE := Color("#6fb79e")
const TRIM := Color("#4a9fe0")
const WOOD := Color("#a8754a")
const WOOD_DARK := Color("#7d5334")
const DRIFT := Color("#c8b79e")

var cl: CoastLevel
var sun: DirectionalLight3D
var grade_k := 0.0
var sanctum_water: MeshInstance3D
var sea: MeshInstance3D

var nx := 0
var nz := 0
var x0 := 0.0
var z0 := 0.0
var hts := PackedFloat32Array()
var kinds := PackedByteArray() # 0 floor, 1 sea, 2 cliff
var noise := FastNoiseLite.new()
var rng := RandomNumberGenerator.new()

var stone_st: SurfaceTool # every marble/stone piece
var wood_st: SurfaceTool
var misc_st: SurfaceTool # cloth, shells, coral, lanterns: no outline
var rock_st: SurfaceTool # sea stacks and islands
var leaf_st: SurfaceTool
var _prop_tints := {}

func _init(level: Level, parent: Node3D) -> void:
	super(level, parent)
	cl = level as CoastLevel
	noise.seed = 77
	noise.frequency = 0.02
	noise.fractal_octaves = 3
	rng.seed = 9001
	for k in ["stone_st", "wood_st", "misc_st", "rock_st", "leaf_st"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		set(k, st)

func build() -> void:
	_heights()
	_terrain()
	_water()
	_paving()
	for e in cl.decor:
		_decor(e)
	_commit(stone_st, CoastLook.paint(0.035), "Stone", true)
	_commit(wood_st, CoastLook.paint(0.03), "Wood")
	_commit(misc_st, CoastLook.paint(0.0), "Misc")
	_commit(rock_st, CoastLook.paint(0.0), "Rocks", true)
	_commit(leaf_st, CoastLook.mat("leaf"), "Leaves")
	_clouds()
	sun = CoastLook.make_sun()
	root.add_child(sun)
	var tide := TideFollower.new()
	tide.world = self
	root.add_child(tide)

func _commit(st: SurfaceTool, m: Material, nm: String, cam := false) -> void:
	var mesh := st.commit()
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.name = nm
	root.add_child(mi)
	if cam:
		add_camera_collider(mi)

# ------------------------------------------------------------------ terrain heights
func _idx(i: int, j: int) -> int:
	return j * nx + i

func _cell_kind(px: float, pz: float) -> int:
	# a sample on a cell edge counts as floor if any touching cell is floor, so floors stay flat to their edges
	for o in [Vector2(0.1, 0.1), Vector2(-0.1, 0.1), Vector2(0.1, -0.1), Vector2(-0.1, -0.1)]:
		if cl.cell_at(px + o.x, pz + o.y):
			return 0
	var k := cl.kind_of(floori((px + 0.1) / Level.T), floori((pz + 0.1) / Level.T))
	return 2 if k == "cliff" else 1

## Chamfer distance (m) to the nearest sample of a kind. mode 0: floor, 1: sea, 2: anything but sea.
func _dist(mode: int) -> PackedFloat32Array:
	var d := PackedFloat32Array()
	d.resize(nx * nz)
	for k in nx * nz:
		var kk := kinds[k]
		var hit := kk == 0 if mode == 0 else (kk == 1 if mode == 1 else kk != 1)
		d[k] = 0.0 if hit else 1e6
	var s := STEP
	var dg := STEP * 1.4142
	for j in nz:
		for i in nx:
			var v := d[_idx(i, j)]
			if i > 0: v = minf(v, d[_idx(i - 1, j)] + s)
			if j > 0: v = minf(v, d[_idx(i, j - 1)] + s)
			if i > 0 and j > 0: v = minf(v, d[_idx(i - 1, j - 1)] + dg)
			if i < nx - 1 and j > 0: v = minf(v, d[_idx(i + 1, j - 1)] + dg)
			d[_idx(i, j)] = v
	for j in range(nz - 1, -1, -1):
		for i in range(nx - 1, -1, -1):
			var v := d[_idx(i, j)]
			if i < nx - 1: v = minf(v, d[_idx(i + 1, j)] + s)
			if j < nz - 1: v = minf(v, d[_idx(i, j + 1)] + s)
			if i < nx - 1 and j < nz - 1: v = minf(v, d[_idx(i + 1, j + 1)] + dg)
			if i > 0 and j < nz - 1: v = minf(v, d[_idx(i - 1, j + 1)] + dg)
			d[_idx(i, j)] = v
	return d

func _heights() -> void:
	x0 = -MARGIN
	z0 = -MARGIN
	nx = int((cl.gw * Level.T + 2 * MARGIN) / STEP) + 1
	nz = int((cl.gh * Level.T + 2 * MARGIN) / STEP) + 1
	kinds.resize(nx * nz)
	hts.resize(nx * nz)
	for j in nz:
		for i in nx:
			kinds[_idx(i, j)] = _cell_kind(x0 + i * STEP, z0 + j * STEP)
	var d_floor := _dist(0)
	var d_sea := _dist(1)
	var d_land := _dist(2)
	for j in nz:
		for i in nx:
			var px := x0 + i * STEP
			var pz := z0 + j * STEP
			var id := _idx(i, j)
			var n := noise.get_noise_2d(px, pz)
			var h := 0.0
			match kinds[id]:
				0:
					h = cl.floor_y(px, pz)
				1:
					var dl := d_land[id]
					h = -0.2 - 1.1 * smoothstep(0.0, 6.0, dl) - 10.0 * smoothstep(6.0, 50.0, dl) + n * 0.35 * smoothstep(0.0, 4.0, dl)
				2:
					var top := 12.0 + n * 7.0 + noise.get_noise_2d(px * 3.0, pz * 3.0) * 1.2
					var rise := smoothstep(0.6, 10.0, d_floor[id] + n * 2.0)
					h = top * rise * smoothstep(0.0, 7.0, d_sea[id] + 1.0) - 0.4 * (1.0 - smoothstep(0.0, 3.0, d_sea[id]))
					# chunky terraces: soften the heights toward 2.2 m steps
					var step_h := 2.2
					var q := floorf(h / step_h) * step_h + smoothstep(0.3, 0.7, fmod(h, step_h) / step_h) * step_h
					h = lerpf(h, q, 0.55 * smoothstep(1.0, 4.0, h))
			hts[id] = h

func height_at(px: float, pz: float) -> float:
	var fi := clampf((px - x0) / STEP, 0, nx - 1.001)
	var fj := clampf((pz - z0) / STEP, 0, nz - 1.001)
	var i := floori(fi)
	var j := floori(fj)
	var tx := fi - i
	var tz := fj - j
	return lerpf(lerpf(hts[_idx(i, j)], hts[_idx(i + 1, j)], tx), lerpf(hts[_idx(i, j + 1)], hts[_idx(i + 1, j + 1)], tx), tz)

func _normal(i: int, j: int) -> Vector3:
	var hl := hts[_idx(maxi(i - 1, 0), j)]
	var hr := hts[_idx(mini(i + 1, nx - 1), j)]
	var hd := hts[_idx(i, maxi(j - 1, 0))]
	var hu := hts[_idx(i, mini(j + 1, nz - 1))]
	return Vector3(hl - hr, 2.0 * STEP, hd - hu).normalized()

func _terrain_color(i: int, j: int, nrm: Vector3) -> Color:
	var id := _idx(i, j)
	var h := hts[id]
	var px := x0 + i * STEP
	var pz := z0 + j * STEP
	var v := noise.get_noise_2d(px * 2.0, pz * 2.0) * 0.05
	match kinds[id]:
		0:
			var k := cl.kind_of(floori(px / Level.T), floori(pz / Level.T))
			if cl.zone_at(px + 0.1, pz + 0.1) == "sanctum":
				return Color("#8cbfae").lightened(v)
			if k == "shallow":
				return SAND_WET.darkened(0.05)
			if k == "stone":
				return Color("#bfa47c").lightened(v)
			return SAND.lightened(v)
		1:
			if h > -0.85:
				return SAND_WET.lerp(SAND, smoothstep(-0.85, -0.25, h))
			return SEABED.lerp(SAND_WET, smoothstep(-4.0, -0.9, h)).lightened(v)
	# cliffs: rock faces in warm strata, grass on the flats, sand at the foot
	if h < 0.9:
		return SAND.lerp(SAND_WET, 0.3)
	if nrm.y > 0.8 and h > 1.4:
		return GRASS.lerp(GRASS_DARK, clampf(0.5 + noise.get_noise_2d(px * 1.5, pz * 1.5), 0.0, 1.0)).lightened(v)
	var band := int(floorf(h / 1.6)) % 2
	return (ROCK_A if band == 0 else ROCK_B).lightened(v * 1.5)

func _terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in nz:
		for i in nx:
			var nrm := _normal(i, j)
			st.set_color(_lin(_terrain_color(i, j, nrm)))
			st.set_normal(nrm)
			st.add_vertex(Vector3(x0 + i * STEP, hts[_idx(i, j)], z0 + j * STEP))
	for j in nz - 1:
		for i in nx - 1:
			var a := _idx(i, j)
			var b := _idx(i + 1, j)
			var c := _idx(i, j + 1)
			var d := _idx(i + 1, j + 1)
			if maxf(maxf(hts[a], hts[b]), maxf(hts[c], hts[d])) < -7.0:
				continue # deep sea floor, hidden under opaque water
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = CoastLook.mat("terrain")
	mi.name = "Terrain"
	root.add_child(mi)
	add_camera_collider(mi)

## Terrain heights for the water shader, packed as 16 bits in RG8 over -24..24 m
## (float textures don't filter on every WebGL2 device; the shader samples texels and blends itself).
func height_texture() -> ImageTexture:
	var h := hts.duplicate()
	# the plinths are separate meshes; add them so the water foams around them
	for pl in CoastLevel.PLINTHS:
		var c := Vector2(pl[0] * Level.T, pl[1] * Level.T)
		var r: float = pl[2] + 1.2
		for j in range(floori((c.y - r - z0) / STEP), ceili((c.y + r - z0) / STEP) + 1):
			for i in range(floori((c.x - r - x0) / STEP), ceili((c.x + r - x0) / STEP) + 1):
				var d := Vector2(x0 + i * STEP, z0 + j * STEP).distance_to(c)
				if d < r:
					h[_idx(i, j)] = maxf(h[_idx(i, j)], 0.0 if d > pl[2] else CoastLevel.PLINTH_TOP)
	var data := PackedByteArray()
	data.resize(nx * nz * 2)
	for k in nx * nz:
		var v := clampi(int(roundf((h[k] + 24.0) / 48.0 * 65535.0)), 0, 65535)
		data[k * 2] = v >> 8
		data[k * 2 + 1] = v & 255
	return ImageTexture.create_from_image(Image.create_from_data(nx, nz, false, Image.FORMAT_RG8, data))

# ------------------------------------------------------------------ water
func _water() -> void:
	var ht := height_texture()
	var region := Vector4(x0 - STEP / 2, z0 - STEP / 2, nx * STEP, nz * STEP)
	# the sea: a dense grid over the terrain region, and a wide skirt out to the horizon
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cs := 4.0
	var w := nx * STEP
	var d := nz * STEP
	var gx := int(w / cs)
	var gz := int(d / cs)
	for j in gz + 1:
		for i in gx + 1:
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(x0 + i * cs, 0, z0 + j * cs))
	for j in gz:
		for i in gx:
			var a := j * (gx + 1) + i
			st.add_index(a); st.add_index(a + 1); st.add_index(a + gx + 1)
			st.add_index(a + 1); st.add_index(a + gx + 2); st.add_index(a + gx + 1)
	var big := 4000.0
	var x1 := x0 + gx * cs
	var z1 := z0 + gz * cs
	for q in [[-big, -big, big, z0], [-big, z1, big, big], [-big, z0, x0, z1], [x1, z0, big, z1]]:
		var p := [Vector3(q[0], 0, q[1]), Vector3(q[2], 0, q[1]), Vector3(q[0], 0, q[3]), Vector3(q[2], 0, q[3])]
		for k in [0, 1, 2, 1, 3, 2]:
			st.set_normal(Vector3.UP)
			st.add_vertex(p[k])
	sea = MeshInstance3D.new()
	sea.mesh = st.commit()
	sea.position.y = CoastLevel.SEA_LEVEL
	sea.material_override = CoastLook.mat("water", { "height_tex": ht, "region": region, "level": CoastLevel.SEA_LEVEL })
	sea.name = "Sea"
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(sea)
	# the sanctum floods to its own level, inside the ring wall
	var disc := CylinderMesh.new()
	disc.top_radius = CoastLevel.SANCTUM_R * Level.T + 1.4
	disc.bottom_radius = disc.top_radius
	disc.height = 0.01
	disc.radial_segments = 64
	disc.rings = 1
	disc.cap_bottom = false
	sanctum_water = MeshInstance3D.new()
	sanctum_water.mesh = disc
	sanctum_water.position = Vector3(CoastLevel.SANCTUM_C.x * Level.T, CoastLevel.WATER_SANCTUM, CoastLevel.SANCTUM_C.y * Level.T)
	sanctum_water.material_override = CoastLook.mat("water", { "height_tex": ht, "region": region, "level": CoastLevel.WATER_SANCTUM,
		"wave_amp": 0.03, "deep": Color("#17708f"), "mid": Color("#1f8fa6"), "shallow": Color("#36b3b3"), "clear": 0.82, "foam_k": 0.7, "band_d": 0.14 })
	sanctum_water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sanctum_water.name = "SanctumWater"
	root.add_child(sanctum_water)
	# tide pools on the strand
	var pools := SurfaceTool.new()
	pools.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in cl.gh:
		for x in cl.gw:
			if cl.kind_of(x, z) != "shallow" or cl.zone_of[z * cl.gw + x] == "sanctum":
				continue
			var p := Vector3(x * Level.T - 1.0, 0, z * Level.T - 1.0)
			var s := Level.T + 2.0
			var v := [p, p + Vector3(s, 0, 0), p + Vector3(0, 0, s), p + Vector3(s, 0, s)]
			for k in [0, 1, 2, 1, 3, 2]:
				pools.set_normal(Vector3.UP)
				pools.add_vertex(v[k])
	var pm := MeshInstance3D.new()
	pm.mesh = pools.commit()
	pm.position.y = CoastLevel.WATER_POOL
	pm.material_override = CoastLook.mat("water", { "height_tex": ht, "region": region, "level": CoastLevel.WATER_POOL,
		"wave_amp": 0.0, "mid": Color("#2a9fb0"), "shallow": Color("#45bdb8"), "clear": 0.5, "foam_k": 0.6, "band_d": 0.12 })
	pm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pm.name = "Pools"
	root.add_child(pm)

func set_tide(level: float) -> void:
	sanctum_water.position.y = level
	(sanctum_water.material_override as ShaderMaterial).set_shader_parameter("level", level)

# ------------------------------------------------------------------ geometry helpers
static func _lin(c: Color) -> Color:
	return c.srgb_to_linear()

## One flat triangle. Normals face along (b - a) x (c - a); Godot's front faces wind clockwise, so emit a, c, b.
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	for p in [a, c, b]:
		st.set_color(_lin(col))
		st.set_normal(n)
		st.add_vertex(p)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(st, a, b, c, col)
	_tri(st, a, c, d, col)

## An oriented box. xf maps the unit box (-0.5..0.5) to the world.
func _sbox(st: SurfaceTool, xf: Transform3D, col: Color, top_col = null) -> void:
	var c := []
	for k in 8:
		c.append(xf * Vector3(0.5 if k & 1 else -0.5, 0.5 if k & 2 else -0.5, 0.5 if k & 4 else -0.5))
	var tc: Color = top_col if top_col != null else col.lightened(0.06)
	_quad(st, c[2], c[6], c[7], c[3], tc) # top
	_quad(st, c[0], c[1], c[5], c[4], col.darkened(0.15)) # bottom
	_quad(st, c[0], c[2], c[3], c[1], col) # -z
	_quad(st, c[4], c[5], c[7], c[6], col) # +z
	_quad(st, c[0], c[4], c[6], c[2], col.darkened(0.04)) # -x
	_quad(st, c[1], c[3], c[7], c[5], col.darkened(0.04)) # +x

func _bx(st: SurfaceTool, center: Vector3, size: Vector3, rot_y: float, col: Color, top_col = null) -> void:
	var b := Basis(Vector3.UP, rot_y).scaled(size)
	_sbox(st, Transform3D(b, center), col, top_col)

## A cylinder segment along +y from base, smooth sides. col_fn(t: 0..1 up the side) -> Color.
## jag > 0 roughens the top ring (a broken column).
func _cyl(st: SurfaceTool, xf: Transform3D, r0: float, r1: float, h: float, sides: int, col_fn: Callable, jag := 0.0, caps := true) -> void:
	var rings := 4 if jag == 0.0 else 5
	var tops := []
	for s in sides + 1:
		tops.append(rng.randf_range(-jag, jag * 0.3) if s < sides else 0.0)
	tops[sides] = tops[0]
	for k in rings:
		var t0 := float(k) / rings
		var t1 := float(k + 1) / rings
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var pts := []
			for q in [[a0, t0, s], [a1, t0, s + 1], [a1, t1, s + 1], [a0, t1, s]]:
				var r := lerpf(r0, r1, q[1])
				var y: float = h * q[1] + (tops[q[2]] if k == rings - 1 and q[1] == t1 else 0.0)
				pts.append([Vector3(cos(q[0]) * r, y, sin(q[0]) * r), Vector3(cos(q[0]), (r0 - r1) / h, sin(q[0])).normalized(), q[1]])
			for idx in [0, 1, 2, 0, 2, 3]:
				var p: Array = pts[idx]
				st.set_color(_lin(col_fn.call(p[2])))
				st.set_normal((xf.basis * p[1]).normalized())
				st.add_vertex(xf * p[0])
	if caps:
		var top_c: Color = col_fn.call(1.0).lightened(0.05)
		var ctr := xf * Vector3(0, h + (-jag * 0.3 if jag > 0 else 0.0), 0)
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var p0 := xf * Vector3(cos(a0) * r1, h + tops[s], sin(a0) * r1)
			var p1 := xf * Vector3(cos(a1) * r1, h + tops[s + 1], sin(a1) * r1)
			_tri(st, ctr, p1, p0, top_c)

func _marble_fn(algae_h: float, h: float, base := MARBLE) -> Callable:
	return func(t: float) -> Color:
		var y := t * h
		var c := base.lerp(MARBLE_SHADE, 0.5 + 0.5 * sin(y * 1.7))
		if y < algae_h:
			c = ALGAE.lerp(c, smoothstep(algae_h * 0.4, algae_h, y))
		return c

func _flat(c: Color) -> Callable:
	return func(_t: float) -> Color: return c

# ------------------------------------------------------------------ paving
func _paving() -> void:
	for z in cl.gh:
		for x in cl.gw:
			if cl.cell(x, z) == 0 or cl.kind_of(x, z) != "stone":
				continue
			var zn := cl.zone_of[z * cl.gw + x]
			for q in 4:
				if rng.randf() < (0.1 if zn == "colonnade" else 0.16):
					continue
				var c := Vector3(x * Level.T + 1.0 + (q % 2) * 2.0, 0.0, z * Level.T + 1.0 + (q / 2) * 2.0)
				if zn == "sanctum":
					c.y = cl.floor_y(c.x, c.z)
				var tint := Color("#e8d9bb").lerp(Color("#cdb68f"), rng.randf())
				if rng.randf() < 0.08:
					tint = Color("#bfe0dc") # a few sea-glass blue tiles
				var b := Basis(Vector3.UP, rng.randf_range(-0.04, 0.04)).rotated(Vector3.RIGHT, rng.randf_range(-0.02, 0.02))
				_sbox(stone_st, Transform3D(b.scaled(Vector3(1.86, 0.22, 1.86)), c + Vector3(0, -0.07, 0)), tint.darkened(0.08), tint)

# ------------------------------------------------------------------ decor
func _decor(e: Dictionary) -> void:
	var p: Vector3 = e.pos
	match e.kind:
		"column":
			_column(p, e.h, e.broken, e.r)
		"fallen":
			var dir := Vector3(cos(e.rot), 0, -sin(e.rot))
			var n := 3
			var seg: float = e.len / n
			for i in n:
				var c: Vector3 = p + dir * (seg * (i - 1) + rng.randf_range(-0.3, 0.3))
				var b := Basis(Vector3.UP, e.rot + rng.randf_range(-0.15, 0.15)) * Basis(Vector3.BACK, PI / 2)
				var xf := Transform3D(b, c + Vector3(0, e.r * 0.82, 0) - (b * Vector3(0, seg * 0.45, 0)))
				_cyl(stone_st, xf, e.r, e.r * 0.96, seg * 0.9, 14, _marble_fn(0.0, seg), 0.0)
		"lintel":
			var thick: float = e.get("thick", 1.2)
			_bx(stone_st, p + Vector3(0, thick / 2, 0), Vector3(thick * 1.3, thick, e.len), e.rot - PI / 2, MARBLE_SHADE, MARBLE)
			_bx(stone_st, p + Vector3(0, thick + 0.15, 0), Vector3(thick * 1.5, 0.3, e.len + 0.6), e.rot - PI / 2, TRIM, TRIM.lightened(0.15))
		"arch":
			_arch(p, e.span, e.h, e.broken)
		"balustrade":
			_balustrade(p, e.dir, e.len, e.gap)
		"dais":
			_disc(stone_st, p + Vector3(0, 0.03, 0), e.r, 0.12, 40, func(r): return MARBLE if int(r * 1.2) % 2 == 0 else Color("#cfe6ec"))
		"statue":
			_statue(p)
		"brazier":
			_brazier(p, e.get("blue", false))
		"ring_wall":
			_ring_wall(p, e.r, e.h, e.gate)
		"dome_ring":
			_dome_ring(p, e.r, e.spans)
		"plinth":
			var xf := Transform3D(Basis(), p + Vector3(0, -1.6, 0))
			_cyl(stone_st, xf, e.r + 1.1, e.r + 1.1, 1.55, 36, _marble_fn(1.4, 1.55, MARBLE_SHADE), 0.0)
			_cyl(stone_st, Transform3D(Basis(), p + Vector3(0, -1.0, 0)), e.r, e.r, 1.0 + CoastLevel.PLINTH_TOP, 36, _marble_fn(0.9, 1.6), 0.0)
		"seal":
			_disc(misc_st, p + Vector3(0, CoastLevel.PLINTH_TOP + 0.02, 0), e.r, 0.04, 48,
				func(r): return Color("#f2c14e") if (int(r * 2.0) % 3 == 0) else Color("#3d8fd1"))
		"palm":
			_palm(p, e.h, e.lean, e.rot, e.seed)
		"prop":
			_prop(e.model, p, e.rot, e.scale, e.get("tint", Color.WHITE))
		"campfire":
			_prop(e.model, p, e.rot, e.scale)
			_flame(p + Vector3(0, 0.5, 0), 1.6, Color(1, 0.6, 0.2))
			light_sources.append({ "pos": p + Vector3(0, 2, 0), "color": Color(1, 0.6, 0.3), "range": 14.0, "energy": 1.2 })
		"tent":
			_tent(p, e.rot, e.scale)
		"flag":
			_cyl(wood_st, Transform3D(Basis(), p), 0.12, 0.1, 7.0, 6, _flat(WOOD_DARK))
			_leaf_quad(p + Vector3(0.1, 6.8, 0), Vector3(2.6, 0, 0), Vector3(0, -1.6, 0), e.color)
		"boat":
			_hull(p, e.rot, 7.0, 2.6, 1.2, false)
		"wreck":
			_hull(p, e.rot, 16.0, 6.0, 3.4, true)
		"jetty":
			_jetty(p, e.len)
		"lamp_post":
			_cyl(wood_st, Transform3D(Basis(), p), 0.16, 0.13, 3.6, 6, _flat(WOOD_DARK))
			_bx(wood_st, p + Vector3(0.6, 3.55, 0), Vector3(1.4, 0.16, 0.16), 0.0, WOOD_DARK)
			_bx(misc_st, p + Vector3(1.2, 3.0, 0), Vector3(0.45, 0.6, 0.45), 0.0, Color("#ffe39a"))
			light_sources.append({ "pos": p + Vector3(1.2, 3.0, 0), "color": Color(1, 0.8, 0.5), "range": 10.0, "energy": 0.6, "flicker": false })
		"driftwood":
			for i in 3:
				var b := Basis(Vector3.UP, e.rot + i * 0.9) * Basis(Vector3.BACK, PI / 2 + rng.randf_range(-0.1, 0.1))
				_cyl(wood_st, Transform3D(b, p + Vector3(i * 0.7, 0.25, i * 0.4)), 0.28, 0.16, rng.randf_range(2.5, 4.0), 6, _flat(DRIFT))
		"shell":
			var c := Color.from_hsv(0.02 + e.hue * 0.12, 0.35, 1.0)
			_cyl(misc_st, Transform3D(Basis(Vector3.UP, e.rot).scaled(Vector3.ONE * e.scale), p), 0.32, 0.02, 0.28, 7, _flat(c))
		"coral":
			_coral(p + Vector3(0, CoastLevel.POOL_FLOOR, 0))
		"sea_stack":
			_spire(rock_st, p + Vector3(0, -8, 0), e.r, e.h + 8, true, 0.3)
		"lighthouse":
			var fn := func(t: float) -> Color: return Color("#f7f2ea") if int(t * 6) % 2 == 0 else Color("#e2574c")
			_cyl(stone_st, Transform3D(Basis(), p - Vector3(0, 1, 0)), 3.2, 2.4, 15.0, 16, fn, 2.2)
			_bx(stone_st, p + Vector3(0, 13.5, 0), Vector3(5.4, 0.6, 5.4), 0.4, MARBLE_SHADE)
		"island":
			_spire(rock_st, p + Vector3(0, -6, 0), e.r, e.h + 6, true, 0.6)

func _column(p: Vector3, h: float, broken: bool, r: float) -> void:
	var base_y := cl.floor_y(p.x, p.z) if cl.cell_at(p.x, p.z) else minf(0.0, height_at(p.x, p.z))
	var wet := 1.6 if (cl.zone_at(p.x, p.z) == "sanctum" or base_y < -0.1 or height_at(p.x, p.z) < -0.3) else 0.0
	var b := Vector3(p.x, base_y, p.z)
	if not cl.cell_at(p.x, p.z):
		b.y = minf(height_at(p.x, p.z), 0.0) - 0.4
	_bx(stone_st, b + Vector3(0, 0.45, 0), Vector3(r * 2.6, 0.9, r * 2.6), rng.randf_range(-0.05, 0.05), MARBLE_SHADE)
	var shaft_h := h - (0.0 if broken else 1.1)
	_cyl(stone_st, Transform3D(Basis(Vector3.UP, rng.randf_range(0, 1)), b + Vector3(0, 0.9, 0)), r, r * 0.86, shaft_h - 0.9, 14,
		_marble_fn(wet, shaft_h), 0.7 if broken else 0.0, broken)
	if broken:
		# a drum or two lying at its foot
		var a := rng.randf_range(0, TAU)
		var dp := b + Vector3(cos(a), 0, sin(a)) * (r * 2.6)
		var bb := Basis(Vector3.UP, a) * Basis(Vector3.BACK, PI / 2)
		_cyl(stone_st, Transform3D(bb, dp + Vector3(0, r * 0.8, 0) - bb * Vector3(0, 0.8, 0)), r * 0.9, r * 0.86, 1.6, 12, _marble_fn(0.0, 1.6), 0.4)
		return
	var top := b + Vector3(0, h - 1.1, 0)
	_cyl(stone_st, Transform3D(Basis(), top), r * 0.86, r * 1.28, 0.55, 14, _flat(MARBLE), 0.0, false)
	_bx(stone_st, top + Vector3(0, 0.62, 0), Vector3(r * 2.7, 0.16, r * 2.7), 0.0, TRIM, TRIM.lightened(0.15))
	_bx(stone_st, top + Vector3(0, 0.88, 0), Vector3(r * 2.8, 0.42, r * 2.8), 0.0, MARBLE_SHADE, MARBLE)

func _arch(p: Vector3, span: float, h: float, broken: bool) -> void:
	for s in [0.0, span]:
		_column(p + Vector3(0, 0, s), h, false, 1.0)
	var c := p + Vector3(0, h, span / 2)
	var n := 13
	var last := n if not broken else 6
	for i in last:
		var a0 := PI * i / n
		var a1 := PI * (i + 1) / n
		var am := (a0 + a1) / 2
		var rr := span / 2
		var pos := c + Vector3(0, sin(am) * rr, -cos(am) * rr)
		var b := Basis(Vector3.RIGHT, -(PI / 2 - am))
		_sbox(stone_st, Transform3D(b.scaled(Vector3(2.0, 1.3, rr * (a1 - a0) * 1.04)), pos + b * Vector3(0, 0.65, 0)), MARBLE_SHADE, MARBLE)

func _balustrade(p: Vector3, dir: Vector3, length: float, gaps: Array) -> void:
	var segs := int(length / Level.T)
	var side := Vector3(dir.z, 0, dir.x)
	for s in segs:
		if s in gaps:
			continue
		var a := p + dir * (s * Level.T)
		var y := minf(height_at(a.x, a.z), 0.0) if not cl.cell_at(a.x + side.x, a.z + side.z) else 0.0
		y = minf(height_at(a.x + dir.x * 2, a.z + dir.z * 2), 0.0)
		for k in 4:
			var q := a + dir * (k + 0.5)
			_cyl(stone_st, Transform3D(Basis(), Vector3(q.x, y, q.z)), 0.2, 0.16, 1.1, 6, _flat(MARBLE))
		var mid := a + dir * (Level.T / 2)
		var rot := atan2(dir.x, dir.z)
		_bx(stone_st, Vector3(mid.x, y + 1.2, mid.z), Vector3(0.55, 0.22, Level.T), rot, MARBLE_SHADE, MARBLE)
		_bx(stone_st, Vector3(mid.x, y + 0.05, mid.z), Vector3(0.7, 0.3, Level.T), rot, MARBLE_SHADE)

func _disc(st: SurfaceTool, p: Vector3, r: float, h: float, sides: int, col_fn: Callable) -> void:
	var rings := maxi(2, int(r))
	for k in rings:
		var r0 := r * k / rings
		var r1 := r * (k + 1) / rings
		var c: Color = col_fn.call(r0 + 0.01)
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var v := [Vector3(cos(a0) * r0, h, sin(a0) * r0), Vector3(cos(a1) * r0, h, sin(a1) * r0), Vector3(cos(a1) * r1, h, sin(a1) * r1), Vector3(cos(a0) * r1, h, sin(a0) * r1)]
			_quad(st, p + v[0], p + v[1], p + v[2], p + v[3], c)
	for s in sides:
		var a0 := TAU * s / sides
		var a1 := TAU * (s + 1) / sides
		_quad(st, p + Vector3(cos(a0) * r, h, sin(a0) * r), p + Vector3(cos(a1) * r, h, sin(a1) * r), p + Vector3(cos(a1) * r, -0.2, sin(a1) * r), p + Vector3(cos(a0) * r, -0.2, sin(a0) * r), MARBLE_SHADE)

func _statue(p: Vector3) -> void:
	_bx(stone_st, p + Vector3(0, 1.0, 0), Vector3(7.5, 2.0, 5.5), 0.0, MARBLE_SHADE, MARBLE)
	_bx(stone_st, p + Vector3(0, 2.15, 0), Vector3(8.0, 0.3, 6.0), 0.0, TRIM, TRIM.lightened(0.15))
	var c := Assets.character("cleric")
	var n: Node3D = c.root
	n.position = p + Vector3(0, 2.3, 0)
	n.rotation.y = 0.0
	n.scale = Vector3.ONE * 3.6
	root.add_child(n)
	var stone := Color("#e9dfcd")
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			if src is ShaderMaterial:
				var d := (src as ShaderMaterial).duplicate() as ShaderMaterial
				d.set_shader_parameter("use_tex", false)
				d.set_shader_parameter("albedo", stone)
				d.set_shader_parameter("tint", Color.WHITE)
				mi.set_surface_override_material(i, d)
	c.anim.play("heal")
	c.anim.seek(0.55, true)
	c.anim.pause()

func _brazier(p: Vector3, blue: bool) -> void:
	var y := cl.floor_y(p.x, p.z)
	var b := Vector3(p.x, y, p.z)
	_cyl(stone_st, Transform3D(Basis(), b), 0.5, 0.35, 1.6 - y, 10, _marble_fn(0.0 if not blue else 0.8 - y, 1.6 - y))
	_cyl(stone_st, Transform3D(Basis(), Vector3(p.x, 1.55, p.z)), 0.35, 1.0, 0.6, 12, _flat(Color("#c7a36b")))
	var col := Color(0.35, 0.9, 1.0) if blue else Color(1, 0.62, 0.25)
	_flame(Vector3(p.x, 2.25, p.z), 1.8, col)
	light_sources.append({ "pos": Vector3(p.x, 3.2, p.z), "color": col, "range": 16.0, "energy": 1.4 })

func _ring_wall(c: Vector3, r: float, h: float, gate: float) -> void:
	var n := 56
	for i in n:
		var a := TAU * (i + 0.5) / n
		if absf(wrapf(a, -PI, PI)) < gate:
			continue
		if rng.randf() < 0.18:
			continue
		var hh := h * rng.randf_range(0.35, 1.0)
		var p := c + Vector3(cos(a), 0, sin(a)) * r
		var base := minf(height_at(p.x, p.z), 0.0) - 0.6
		var seg := TAU * r / n * 1.02
		_bx(stone_st, Vector3(p.x, base + hh / 2, p.z), Vector3(1.4, hh, seg), -a, MARBLE_SHADE, MARBLE)

## The ring beam of the old dome, only where both columns under it still stand.
func _dome_ring(c: Vector3, r: float, spans: Array) -> void:
	for sp in spans:
		var a0: float = sp[0]
		var a1: float = sp[1]
		var n := maxi(2, int((a1 - a0) * r / 3.0))
		for i in n:
			var a := lerpf(a0, a1, (i + 0.5) / n)
			var p := c + Vector3(cos(a), 0, sin(a)) * r
			var seg := (a1 - a0) * r / n * 1.04
			_bx(stone_st, p + Vector3(0, 0.6, 0), Vector3(2.6, 1.2, seg), -a, MARBLE_SHADE, MARBLE)
			_bx(stone_st, p + Vector3(0, 1.35, 0), Vector3(2.9, 0.3, seg), -a, TRIM, TRIM.lightened(0.15))

func _palm(p: Vector3, h: float, lean: float, rot: float, sd: int) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = sd
	var dir := Vector3(cos(rot), 0, sin(rot))
	var segs := 9
	var pos := Vector3(p.x, cl.floor_y(p.x, p.z) - 0.2, p.z)
	var up := Vector3.UP
	var seg_h := h / segs
	for i in segs:
		var t := float(i) / segs
		var bend := (Vector3.UP + dir * lean * (0.4 + t * 1.6)).normalized()
		var b := Basis(up.cross(bend).normalized(), up.angle_to(bend)) if up.cross(bend).length() > 1e-4 else Basis()
		var r0 := lerpf(0.42, 0.24, t)
		var col := Color("#b9875a") if i % 2 == 0 else Color("#a37249")
		_cyl(wood_st, Transform3D(b, pos), r0, r0 * 0.92, seg_h * 1.05, 7, _flat(col), 0.0, false)
		pos += bend * seg_h
	# crown: drooping fronds and a few coconuts
	var crown := pos
	for i in 3:
		var a := TAU * i / 3.0
		_sphere(misc_st, crown + Vector3(cos(a) * 0.35, -0.35, sin(a) * 0.35), 0.28, Color("#7a5a33"))
	var n := 9
	for i in n:
		var a := TAU * i / n + r.randf_range(-0.2, 0.2)
		var length := r.randf_range(3.6, 4.8)
		var out := Vector3(cos(a), 0, sin(a))
		_frond(crown, out, length, r.randf_range(0.15, 0.45))

func _frond(base: Vector3, out: Vector3, length: float, lift: float) -> void:
	var side := Vector3(-out.z, 0, out.x)
	var segs := 6
	var prev_l := base
	var prev_r := base
	for k in segs:
		var t := float(k + 1) / segs
		var c := base + out * length * t + Vector3(0, lift * length * t - 2.2 * t * t, 0)
		var w := sin(t * PI) * 0.75 + 0.08
		var l := c - side * w
		var rr := c + side * w
		var col := Color("#5cbf4a").lerp(Color("#3f9a3c"), t)
		var t0 := float(k) / segs
		for v in [[prev_l, t0], [l, t], [c, t], [prev_l, t0], [c, t], [prev_r, t0], [prev_r, t0], [c, t], [rr, t]]:
			leaf_st.set_color(_lin(col))
			leaf_st.set_uv(Vector2(v[1], 0))
			leaf_st.set_normal(Vector3.UP)
			leaf_st.add_vertex(v[0])
		prev_l = l
		prev_r = rr
		# keep the stem continuous
		if k == 0:
			pass

func _leaf_quad(p: Vector3, along: Vector3, down: Vector3, col: Color) -> void:
	var segs := 5
	for k in segs:
		var t0 := float(k) / segs
		var t1 := float(k + 1) / segs
		var a := p + along * t0
		var b := p + along * t1
		for v in [[a, t0], [b, t1], [b + down, t1], [a, t0], [b + down, t1], [a + down, t0]]:
			leaf_st.set_color(_lin(col))
			leaf_st.set_uv(Vector2(v[1] * 0.8, 0))
			leaf_st.set_normal(Vector3.BACK)
			leaf_st.add_vertex(v[0])

func _sphere(st: SurfaceTool, c: Vector3, r: float, col: Color) -> void:
	var la := 5
	var lo := 8
	for i in la:
		var t0 := PI * i / la
		var t1 := PI * (i + 1) / la
		for j in lo:
			var p0 := TAU * j / lo
			var p1 := TAU * (j + 1) / lo
			var v := [Vector3(sin(t0) * cos(p0), cos(t0), sin(t0) * sin(p0)), Vector3(sin(t0) * cos(p1), cos(t0), sin(t0) * sin(p1)),
				Vector3(sin(t1) * cos(p1), cos(t1), sin(t1) * sin(p1)), Vector3(sin(t1) * cos(p0), cos(t1), sin(t1) * sin(p0))]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_color(_lin(col))
				st.set_normal(v[k])
				st.add_vertex(c + v[k] * r)

func _tent(p: Vector3, rot: float, s: float) -> void:
	var b := Basis(Vector3.UP, rot)
	var w := 3.2 * s
	var l := 4.2 * s
	var h := 3.0 * s
	var stripes := [Color("#f6efe0"), Color("#e2574c")]
	var n := 6
	for i in n:
		var z0 := -l / 2 + l * i / n
		var z1 := -l / 2 + l * (i + 1) / n
		var col: Color = stripes[i % 2]
		for sgn in [-1, 1]:
			var a := p + b * Vector3(sgn * w, 0, z0)
			var bb := p + b * Vector3(sgn * w, 0, z1)
			var c := p + b * Vector3(0, h, z1)
			var d := p + b * Vector3(0, h, z0)
			_quad(misc_st, a, bb, c, d, col)
			_quad(misc_st, a, d, c, bb, col.darkened(0.2))
	for sgn in [-1, 1]:
		_tri(misc_st, p + b * Vector3(-w, 0, sgn * l / 2), p + b * Vector3(w, 0, sgn * l / 2), p + b * Vector3(0, h, sgn * l / 2), Color("#f6efe0").darkened(0.1))
		_tri(misc_st, p + b * Vector3(w, 0, sgn * l / 2), p + b * Vector3(-w, 0, sgn * l / 2), p + b * Vector3(0, h, sgn * l / 2), Color("#f6efe0").darkened(0.1))
	_cyl(wood_st, Transform3D(Basis(), p + b * Vector3(0, 0, l / 2 + 0.05)), 0.1, 0.1, h + 0.4, 5, _flat(WOOD_DARK))

func _hull(p: Vector3, rot: float, length: float, beam: float, depth: float, wrecked: bool) -> void:
	var b := Basis(Vector3.UP, rot)
	if wrecked:
		b = b * Basis(Vector3.FORWARD, 0.35)
	var base := p + Vector3(0, minf(height_at(p.x, p.z), 0.0) + (0.2 if wrecked else 0.35), 0)
	var segs := 10
	var ribs := 6
	var prev := []
	for k in segs + 1:
		var t := float(k) / segs
		var z := (t - 0.5) * length
		var wk := sin(t * PI) * 0.9 + 0.1
		wk = pow(wk, 0.6)
		var ring := []
		for q in ribs + 1:
			var a := PI * q / ribs # 0..PI across the bottom
			ring.append(base + b * Vector3(-cos(a) * beam / 2 * wk, -sin(a) * depth * wk + depth * 0.6, z))
		if k > 0:
			for q in ribs:
				var col := (WOOD if q % 2 == 0 else WOOD_DARK)
				if wrecked and k in [3, 4, 7] and q in [1, 2, 4]:
					continue # holes in the planking
				_quad(wood_st, prev[q], ring[q], ring[q + 1], prev[q + 1], col)
				_quad(wood_st, prev[q], prev[q + 1], ring[q + 1], ring[q], col.darkened(0.3))
		prev = ring
	# gunwale and thwarts
	for sgn in [-1, 1]:
		_sbox(wood_st, Transform3D(b.scaled(Vector3(0.22, 0.22, length * 0.92)), base + b * Vector3(sgn * beam * 0.45, depth * 0.62, 0)), WOOD_DARK)
	for k in (2 if not wrecked else 4):
		_sbox(wood_st, Transform3D(b.scaled(Vector3(beam * 0.85, 0.14, 0.5)), base + b * Vector3(0, depth * 0.35, (k - 0.5) * length * 0.25)), WOOD)
	if wrecked:
		_cyl(wood_st, Transform3D(b * Basis(Vector3.RIGHT, 0.4), base + b * Vector3(0, 0.0, length * 0.1)), 0.32, 0.26, 7.0, 7, _flat(WOOD_DARK), 0.4)
	else:
		for sgn in [-1, 1]:
			_sbox(wood_st, Transform3D((b * Basis(Vector3.UP, sgn * 0.3)).scaled(Vector3(0.12, 0.08, 3.6)), base + b * Vector3(sgn * (beam * 0.5 + 0.2), depth * 0.5, 0.4)), WOOD)

func _jetty(p: Vector3, length: float) -> void:
	var n := int(length / 2.0)
	for k in n:
		var c := p + Vector3(0, 0, k * 2.0)
		if k % 2 == 0:
			for sx in [-1.6, 1.6]:
				var post := c + Vector3(sx, 0, 0)
				var g := minf(height_at(post.x, post.z), 0.0)
				_cyl(wood_st, Transform3D(Basis(), Vector3(post.x, g - 0.5, post.z)), 0.2, 0.2, 0.8 - g + 0.3, 6, _flat(WOOD_DARK))
		if rng.randf() < 0.08:
			continue
		_bx(wood_st, c + Vector3(rng.randf_range(-0.1, 0.1), 0.25, 0), Vector3(3.8, 0.16, 1.8), rng.randf_range(-0.04, 0.04), WOOD, WOOD.lightened(0.08))

func _coral(p: Vector3) -> void:
	var cols := [Color("#ff8a7a"), Color("#ffb35c"), Color("#f06fa8"), Color("#ffd166")]
	for i in 6:
		var a := rng.randf_range(0, TAU)
		var q := p + Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.3, 1.6)
		var b := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0, 0.5))
		_cyl(misc_st, Transform3D(b, q), 0.16, 0.1, rng.randf_range(0.4, 0.9), 6, _flat(cols[i % cols.size()]))
	for i in 3:
		_sphere(misc_st, p + Vector3(rng.randf_range(-1, 1), 0.1, rng.randf_range(-1, 1)), rng.randf_range(0.25, 0.4), cols[(i + 2) % cols.size()])

## A rounded rock spire or island: a noisy tapered column with warm strata and a grassy top.
func _spire(st: SurfaceTool, p: Vector3, r: float, h: float, grass: bool, taper := 0.75) -> void:
	var rings := 10
	var sides := 16
	var pts := []
	var lean := Vector3(noise.get_noise_1d(p.x) * 0.25, 0, noise.get_noise_1d(p.z) * 0.25) * r
	for k in rings + 1:
		var t := float(k) / rings
		var row := []
		# a lumpy profile: a wide foot, a waist and a rounded shoulder under the grassy cap
		var prof := (1.0 - t * taper) * (1.0 + 0.18 * sin(t * PI * 2.0 + p.x)) * (1.25 - 0.25 * smoothstep(0.0, 0.25, t))
		for s in sides:
			var a := TAU * s / sides
			var n := noise.get_noise_3d(cos(a) * 2.2 + p.x * 0.1, t * 3.0 + p.z * 0.1, sin(a) * 2.2)
			var rr := r * prof * (1.0 + n * 0.55)
			if k == rings:
				rr *= 0.6
			row.append(p + lean * t + Vector3(cos(a) * rr, h * t + (n * 2.0 if k == rings else 0.0), sin(a) * rr))
		pts.append(row)
	var top := p + lean + Vector3(0, h + 1.2, 0)
	for k in rings:
		for s in sides:
			var s1 := (s + 1) % sides
			var y: float = pts[k][s].y - p.y
			var col := ROCK_A if int(y / 3.1) % 2 == 0 else ROCK_B
			if grass and k >= rings - 1:
				col = GRASS
			_quad(st, pts[k][s], pts[k + 1][s], pts[k + 1][s1], pts[k][s1], col)
	for s in sides:
		_tri(st, top, pts[rings][(s + 1) % sides], pts[rings][s], GRASS if grass else ROCK_A)

func _prop(m: String, p: Vector3, rot: float, s, tint := Color.WHITE) -> void:
	var n := Assets.prop(m)
	if tint != Color.WHITE:
		for mm in n.find_children("*", "MeshInstance3D", true, false):
			var mi := mm as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var src := mi.get_active_material(i)
				var key := [src, tint]
				if not _prop_tints.has(key) and src is ShaderMaterial:
					var d := (src as ShaderMaterial).duplicate() as ShaderMaterial
					d.set_shader_parameter("tint", tint)
					_prop_tints[key] = d
				if _prop_tints.has(key):
					mi.set_surface_override_material(i, _prop_tints[key])
	n.position = Vector3(p.x, p.y + cl.floor_y(p.x, p.z), p.z)
	n.rotation.y = rot
	n.scale = s if s is Vector3 else Vector3.ONE * float(s)
	root.add_child(n)

# ------------------------------------------------------------------ fire, clouds
static var _fire_mat: StandardMaterial3D

func _flame(p: Vector3, size: float, col: Color) -> void:
	var ps := CPUParticles3D.new()
	ps.amount = 16
	ps.lifetime = 0.7
	ps.local_coords = false
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	ps.emission_sphere_radius = 0.15 * size
	ps.direction = Vector3.UP
	ps.spread = 12
	ps.gravity = Vector3(0, 1.5, 0)
	ps.initial_velocity_min = 0.6 * size
	ps.initial_velocity_max = 1.2 * size
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.6))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1, 0.0))
	ps.scale_amount_curve = curve
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 0.85, 1).lerp(col, 0.3))
	grad.add_point(0.4, Color(col, 0.9))
	grad.set_color(grad.get_point_count() - 1, Color(col.darkened(0.3), 0.0))
	ps.color_ramp = grad
	var q := QuadMesh.new()
	q.size = Vector2(0.55, 0.55) * size * 0.6
	if _fire_mat == null:
		_fire_mat = StandardMaterial3D.new()
		_fire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_fire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_fire_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_fire_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		_fire_mat.vertex_color_use_as_albedo = true
		_fire_mat.albedo_texture = WorldBuilder.soft_tex()
	q.material = _fire_mat
	ps.mesh = q
	ps.position = p
	root.add_child(ps)

func _clouds() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cr := RandomNumberGenerator.new()
	cr.seed = 31
	var ctr := Vector3(cl.gw * Level.T / 2, 0, cl.gh * Level.T / 2)
	for i in 16:
		var a := cr.randf_range(0, TAU)
		var dist := cr.randf_range(420, 760)
		var c := ctr + Vector3(cos(a) * dist, cr.randf_range(70, 150), sin(a) * dist)
		var size := cr.randf_range(26, 48)
		for k in 7:
			var o := Vector3(cr.randf_range(-1.6, 1.6), cr.randf_range(-0.2, 0.5), cr.randf_range(-0.8, 0.8)) * size
			var rr := size * cr.randf_range(0.45, 0.8) * (1.0 - absf(o.x) / (size * 2.4))
			_sphere(st, c + o, rr, Color.WHITE)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = CoastLook.mat("cloud")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Clouds"
	root.add_child(mi)

# ------------------------------------------------------------------ environment and set pieces (called by Game)
func make_environment() -> Environment:
	return CoastLook.make_environment()

func grade(env: Environment, zone: String, delta: float) -> void:
	grade_k = move_toward(grade_k, 1.0 if zone == "sanctum" else 0.0, delta * 0.6)
	CoastLook.grade(env, grade_k)

## Follows the sanctum water level from server snapshots (header slot 2, see CoastBoss.tick_tide).
class TideFollower extends Node:
	var world: CoastWorld
	var target := CoastLevel.WATER_SANCTUM
	var level := CoastLevel.WATER_SANCTUM
	var hooked := false

	func _process(delta: float) -> void:
		if not hooked:
			var game := world.root.get_parent()
			var n = game.get("net") if game else null
			if n and n.has_signal("snapshot_received"):
				n.snapshot_received.connect(func(s: PackedFloat32Array):
					if s.size() > 2 and s[2] != 0.0:
						target = s[2])
				hooked = true
		level = lerpf(level, target, clampf(delta * 4.0, 0.0, 1.0))
		world.set_tide(level)
