class_name Cave
extends RefCounted
## Rough rock for the mine tunnels: wall strips and ceilings displaced by 3D noise sampled in world space,
## so neighbouring pieces line up without seams. The boss hall keeps its cut-stone walls.

var noise := FastNoiseLite.new()
var noise2 := FastNoiseLite.new()
var amp := 0.9

func _init() -> void:
	noise.seed = 4242
	noise.frequency = 0.16
	noise.fractal_octaves = 3
	noise2.seed = 99
	noise2.frequency = 0.05
	noise2.fractal_octaves = 2

func disp(p: Vector3, inward: Vector3) -> Vector3:
	var d := Vector3(noise.get_noise_3d(p.x, p.y, p.z), noise.get_noise_3d(p.x + 71.0, p.y, p.z) * 0.35, noise.get_noise_3d(p.x, p.y - 33.0, p.z + 17.0))
	d += Vector3(noise2.get_noise_3d(p.x, p.y, p.z), 0, noise2.get_noise_3d(p.z, p.y, p.x)) * 1.6
	d *= amp
	# never bulge more than a little into the walkable space
	var into := d.dot(inward)
	if into > amp * 0.3:
		d -= inward * (into - amp * 0.3)
	return d

## One wall strip from a to b (on the floor line), facing inward, h high.
func wall(st: SurfaceTool, a: Vector3, b: Vector3, inward: Vector3, h: float) -> void:
	var along := (b - a)
	var length := along.length()
	along /= length
	var a2 := a - along * 0.6 - inward * 0.5
	var nu := maxi(2, int(ceil((length + 1.2) / 0.7)))
	var nv := maxi(2, int(ceil((h + 1.0) / 0.7)))
	var grid: Array = []
	for j in nv + 1:
		var row: Array = []
		for i in nu + 1:
			var p := a2 + along * ((length + 1.2) * i / nu) + Vector3.UP * (-0.3 + (h + 1.0) * j / nv)
			# lean the upper wall inward a bit so tunnels read as carved, not built
			var lean := clampf((p.y - 4.0) / 6.0, 0.0, 1.0)
			p += inward * lean * lean * 1.4
			row.append(p + disp(p, inward))
		grid.append(row)
	for j in nv:
		for i in nu:
			var p00: Vector3 = grid[j][i]
			var p10: Vector3 = grid[j][i + 1]
			var p01: Vector3 = grid[j + 1][i]
			var p11: Vector3 = grid[j + 1][i + 1]
			var uv := Vector2(float(i) / nu * length / 4.0, float(j) / nv * h / 4.0)
			var du := Vector2(1.0 / nu * length / 4.0, 0)
			var dv := Vector2(0, 1.0 / nv * h / 4.0)
			_tri(st, p00, p01, p10, uv, uv + dv, uv + du, inward)
			_tri(st, p10, p01, p11, uv + du, uv + dv, uv + du + dv, inward)

func ceiling_y(x: float, z: float, h: float) -> float:
	var sag := (noise.get_noise_3d(x * 0.7, 5.0, z * 0.7) * 0.5 + 0.5) * 1.6 + noise2.get_noise_2d(x, z) * 0.5
	return h - sag

## A rough ceiling over a rectangle at height h, sagging down in places.
func ceiling(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float, h: float) -> void:
	var nx := maxi(2, int(ceil((x1 - x0) / 0.9)))
	var nz := maxi(2, int(ceil((z1 - z0) / 0.9)))
	var grid: Array = []
	for j in nz + 1:
		var row: Array = []
		for i in nx + 1:
			var p := Vector3(lerpf(x0, x1, float(i) / nx), h, lerpf(z0, z1, float(j) / nz))
			var sag := (noise.get_noise_3d(p.x * 0.7, 5.0, p.z * 0.7) * 0.5 + 0.5) * 1.6 + noise2.get_noise_2d(p.x, p.z) * 0.5
			p.y -= sag
			row.append(p)
		grid.append(row)
	for j in nz:
		for i in nx:
			var p00: Vector3 = grid[j][i]
			var p10: Vector3 = grid[j][i + 1]
			var p01: Vector3 = grid[j + 1][i]
			var p11: Vector3 = grid[j + 1][i + 1]
			var uv := Vector2(p00.x, p00.z) / 4.0
			_tri(st, p00, p10, p01, uv, Vector2(p10.x, p10.z) / 4.0, Vector2(p01.x, p01.z) / 4.0, Vector3.DOWN)
			_tri(st, p10, p11, p01, Vector2(p10.x, p10.z) / 4.0, Vector2(p11.x, p11.z) / 4.0, Vector2(p01.x, p01.z) / 4.0, Vector3.DOWN)

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, facing: Vector3) -> void:
	# keep the front face toward the room (Godot treats clockwise winding as front)
	var n := (b - a).cross(c - a)
	if n.dot(facing) > 0:
		var t := b
		b = c
		c = t
		var tu := ub
		ub = uc
		uc = tu
	for v in [[a, ua], [b, ub], [c, uc]]:
		st.set_uv(v[1])
		st.add_vertex(v[0])

## A downward-pointing rock spike.
static func stalactite(length: float, radius: float) -> Mesh:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = 0.02
	cm.height = length
	cm.radial_segments = 6
	cm.rings = 1
	return cm

static func rock_tex() -> Texture2D:
	var n := FastNoiseLite.new()
	n.seed = 7
	n.frequency = 0.02
	n.fractal_octaves = 4
	var img := n.get_seamless_image(256, 256)
	var dark := Color("#3b322e")
	var light := Color("#6a5c52")
	for y in img.get_height():
		for x in img.get_width():
			var v := img.get_pixel(x, y).r
			var strata := 0.5 + 0.5 * sin(y / 256.0 * TAU * 6.0 + v * 4.0)
			var c := dark.lerp(light, clampf(v * 0.8 + strata * 0.25, 0.0, 1.0))
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
