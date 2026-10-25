class_name Level
extends RefCounted
## A stage's layout, collision and pathfinding. The server and every client build the
## same Level from a fixed seed, so obstacle positions always agree.
## This base class is Saltrock Mines. Other stages extend it (see stages/stages.gd) and override
## _configure(), _layout() and the stage hooks.
## x grows east, z grows south. The entrance is in the south, the boss hall in the northeast.

const T := 4.0 # one grid cell = one KayKit floor tile
const GW := 36
const GH := 28
const ZONE_H := { "hall": 12.0, "gate": 12.0 }
const ZONE_NAMES := { "mouth": "Saltrock Mines", "diggings": "The Lower Diggings", "cut": "Timber Cut", "sorting": "Sorting Cave",
	"cut2": "Timber Cut", "hall": "Overseer's Hall", "gate": "Overseer's Hall" }

# per-stage settings (subclasses set these in _configure)
var stage_id := "saltrock"
var gw := GW # grid size in cells
var gh := GH
var zone_names: Dictionary = ZONE_NAMES
var arena_zones: Array = ["hall", "gate"] # the boss evades when the whole party is outside these

var grid := PackedByteArray() # 0 solid, 1 floor
var zone_of: Array[String] = []
var rects: Array = [] # [x0, z0, x1, z1, zone]
var obst: Array = [] # static round obstacles [x, z, r]
var dyn_obst: Array = [] # moving ones (mine carts), same shape, mutated in place
var ob_grid: Array = []
var decor: Array = [] # visual-only placements for the client: { kind, model?, pos, rot, scale, ... }
var astar: AStarGrid2D
var rng := RandomNumberGenerator.new()

# fine navigation grid: one world unit per cell
var NW := 0
var NH := 0

func _init() -> void:
	rng.seed = 1337
	_configure()
	NW = int(gw * T)
	NH = int(gh * T)
	grid.resize(gw * gh)
	zone_of.resize(gw * gh)
	zone_of.fill("")
	_layout()
	_index_obst()
	_build_nav()

## Stage settings (grid size, names, seed). Runs before the grid is allocated.
func _configure() -> void:
	pass

## Carve the walkable cells and place obstacles and decor.
func _layout() -> void:
	carve(2, 15, 4, 26, "mouth")
	carve(1, 7, 9, 14, "diggings")
	carve(10, 9, 14, 11, "cut")
	carve(15, 5, 20, 14, "sorting")
	carve(21, 8, 22, 10, "cut2")
	carve(23, 2, 33, 15, "hall")
	carve(27, 0, 29, 1, "gate")
	_build_structure()
	_decorate()

# ------------------------------------------------------------------ stage hooks (override per stage)
## Ground height under a point. Visual only: collision and the sim stay 2D on the grid.
## Camera far plane for this stage (open stages with long views raise it).
var cam_far := 300.0

func floor_y(_x: float, _z: float) -> float:
	return 0.0

## Enemy spawns: [type, cell x, cell z, pack, facing].
func spawns() -> Array:
	return D.SPAWNS

## Extra enemy types for this stage, looked up before D.ENEMIES.
func enemy_defs() -> Dictionary:
	return {}

func enemy_def(type: String) -> Dictionary:
	var d := enemy_defs()
	return d[type] if d.has(type) else D.ENEMIES[type]

## Party start, in cell coordinates.
func start_spots() -> Array:
	return [Vector2(3.6, 24.6), Vector2(4.4, 25.2), Vector2(3.2, 25.4), Vector2(4.2, 24.0), Vector2(3.6, 25.9)]

## Where a wiped party regroups before it reaches a checkpoint.
func start_point() -> Vector3:
	return W(3.5, 24.5)

## Checkpoints in order: [zone, regroup point]. Reaching a later one out of combat moves the regroup point there.
func checkpoints() -> Array:
	return [["sorting", W(15.5, 9.5)], ["hall", W(22, 9.5)]]

func intro_text() -> String:
	return "The air in the shaft is cold and smells of lamp oil."

## The script for a stage boss (see stages/boss_script.gd), or null. Saltrock's Gorrak lives in Sim.
func boss_script(_boss: String, _sim) -> Object:
	return null

## Called once per sim tick, for stage set pieces.
func tick(_sim, _dt: float) -> void:
	pass

func carve(x0: int, z0: int, x1: int, z1: int, zone: String) -> void:
	rects.append([x0, z0, x1, z1, zone])
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			grid[z * gw + x] = 1
			zone_of[z * gw + x] = zone

func cell(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return 0
	return grid[z * gw + x]

func cell_at(wx: float, wz: float) -> int:
	return cell(floori(wx / T), floori(wz / T))

func zone_at(wx: float, wz: float) -> String:
	var x := floori(wx / T)
	var z := floori(wz / T)
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return ""
	return zone_of[z * gw + x]

func zone_h(zone: String) -> float:
	return ZONE_H.get(zone, 11.0)

func ceil_at(wx: float, wz: float) -> float:
	return zone_h(zone_at(wx, wz))

## cell center -> world
static func W(cx: float, cz: float) -> Vector3:
	return Vector3((cx + 0.5) * T, 0.0, (cz + 0.5) * T)

# ------------------------------------------------------------------ collision
func solid_at(x: float, z: float, r := 0.0) -> bool:
	if not cell_at(x, z):
		return true
	if r > 0.0:
		if not cell_at(x + r, z) or not cell_at(x - r, z) or not cell_at(x, z + r) or not cell_at(x, z - r):
			return true
	return false

func near_obst(x: float, z: float) -> Array:
	var cx := floori(x / T)
	var cz := floori(z / T)
	var c: Array = []
	if cx >= 0 and cz >= 0 and cx < gw and cz < gh:
		c = ob_grid[cz * gw + cx]
	if dyn_obst.is_empty():
		return c
	return c + dyn_obst

## Slide a circle through the grid and the round obstacles. Returns the new position.
func move_circle(p: Vector3, dx: float, dz: float, r: float) -> Vector3:
	var steps := maxi(1, ceili(Vector2(dx, dz).length() / (r * 0.8)))
	var sx := dx / steps
	var sz := dz / steps
	for i in steps:
		if not solid_at(p.x + sx, p.z, r):
			p.x += sx
		if not solid_at(p.x, p.z + sz, r):
			p.z += sz
		for o in near_obst(p.x, p.z):
			var ddx: float = p.x - o[0]
			var ddz: float = p.z - o[1]
			var d := sqrt(ddx * ddx + ddz * ddz)
			var m: float = r + o[2]
			if d < m and d > 1e-4:
				var nxn := ddx / d
				var nzn := ddz / d
				var push := m - d
				var px := nxn * push
				var pz := nzn * push
				# heading straight into the obstacle: sidestep around it instead of stalling
				var sl := sqrt(sx * sx + sz * sz)
				if sl > 1e-5:
					var cr := (sx * nzn - sz * nxn) / sl
					if absf(cr) < 0.35:
						var sg := 1.0 if cr >= 0.0 else -1.0
						px += -nzn * sg * sl * 0.9
						pz += nxn * sg * sl * 0.9
				if not solid_at(p.x + px, p.z + pz, r):
					p.x += px
					p.z += pz
				elif not solid_at(p.x + nxn * push, p.z + nzn * push, r):
					p.x += nxn * push
					p.z += nzn * push
	return p

func line_clear(a: Vector3, b: Vector3) -> bool:
	var d := Vector2(b.x - a.x, b.z - a.z).length()
	var n := ceili(d / 1.0)
	for i in range(1, n):
		var t := float(i) / n
		if not cell_at(lerpf(a.x, b.x, t), lerpf(a.z, b.z, t)):
			return false
	return true

## Can a circle of radius r walk straight from a to b?
func walk_clear(a: Vector3, b: Vector3, r: float) -> bool:
	var d := Vector2(b.x - a.x, b.z - a.z).length()
	var n := ceili(d / 0.5)
	for i in range(1, n + 1):
		var t := float(i) / n
		var x := lerpf(a.x, b.x, t)
		var z := lerpf(a.z, b.z, t)
		if solid_at(x, z, r):
			return false
		for o in near_obst(x, z):
			var rr: float = o[2] + r * 0.8
			if (x - o[0]) * (x - o[0]) + (z - o[1]) * (z - o[1]) < rr * rr:
				return false
	return true

func _index_obst() -> void:
	ob_grid.resize(gw * gh)
	for i in gw * gh:
		ob_grid[i] = []
	for o in obst:
		var m: float = o[2] + 1.2
		for z in range(floori((o[1] - m) / T), floori((o[1] + m) / T) + 1):
			for x in range(floori((o[0] - m) / T), floori((o[0] + m) / T) + 1):
				if x >= 0 and z >= 0 and x < gw and z < gh:
					ob_grid[z * gw + x].append(o)

# ------------------------------------------------------------------ pathfinding
func _build_nav() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, NW, NH)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for z in NH:
		for x in NW:
			var wx := x + 0.5
			var wz := z + 0.5
			var ok := not solid_at(wx, wz, 0.7)
			if ok:
				for o in near_obst(wx, wz):
					var rr: float = o[2] + 0.6
					if (wx - o[0]) * (wx - o[0]) + (wz - o[1]) * (wz - o[1]) < rr * rr:
						ok = false
						break
			if not ok:
				astar.set_point_solid(Vector2i(x, z), true)

func _nearest_open(x: int, z: int) -> Vector2i:
	var p := Vector2i(clampi(x, 0, NW - 1), clampi(z, 0, NH - 1))
	if not astar.is_point_solid(p):
		return p
	for r in range(1, 5):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var q := Vector2i(p.x + dx, p.y + dz)
				if q.x >= 0 and q.y >= 0 and q.x < NW and q.y < NH and not astar.is_point_solid(q):
					return q
	return Vector2i(-1, -1)

## A* over the fine grid, then string-pulled so units walk in straight lines where they can.
func find_path(a: Vector3, b: Vector3) -> Array:
	var s := _nearest_open(floori(a.x), floori(a.z))
	var g := _nearest_open(floori(b.x), floori(b.z))
	if s.x < 0 or g.x < 0:
		return []
	var ids := astar.get_id_path(s, g, true)
	if ids.is_empty():
		return []
	var pts: Array = []
	for i in range(1, ids.size()):
		pts.append(Vector3(ids[i].x + 0.5, 0, ids[i].y + 0.5))
	pts.append(Vector3(b.x, 0, b.z))
	var out: Array = []
	var cur := Vector3(a.x, 0, a.z)
	var i := 0
	while i < pts.size():
		var j := pts.size() - 1
		while j > i and not walk_clear(cur, pts[j], 0.75):
			j -= 1
		out.append(pts[j])
		cur = pts[j]
		i = j + 1
	return out

# ------------------------------------------------------------------ structure and dressing
func _add(kind: String, model: String, pos: Vector3, rot := 0.0, scale = 1.0, extra := {}) -> void:
	var e := { "kind": kind, "model": model, "pos": pos, "rot": rot, "scale": scale }
	e.merge(extra)
	decor.append(e)

func _build_structure() -> void:
	# walls on every floor/solid edge, rubble at the foot of some of them
	var dirs := [[0, -1, 0.0], [1, 0, PI / 2], [0, 1, PI], [-1, 0, -PI / 2]]
	for z in gh:
		for x in gw:
			if not cell(x, z):
				continue
			for dd in dirs:
				var dx: int = dd[0]
				var dz: int = dd[1]
				if cell(x + dx, z + dz):
					continue
				var c := W(x, z)
				var p := Vector3(c.x + dx * (T / 2 + 0.5), 0, c.z + dz * (T / 2 + 0.5))
				var h := zone_h(zone_of[z * gw + x])
				_add("wall", "dungeon-wall", p, dd[2], 1.0, { "courses": int(h / 4.0), "dx": dx, "dz": dz })
				if rng.randf() < 0.3:
					var rp := Vector3(c.x + dx * (T / 2 - 0.6) + rng.randf_range(-1.2, 1.2) * (1 if dz else 0), 0,
						c.z + dz * (T / 2 - 0.6) + rng.randf_range(-1.2, 1.2) * (1 if dx else 0))
					var m: String = ["k_Stone_Chunks_Small", "q_rock_large", "k_Stone_Chunks_Large"][rng.randi() % 3]
					_add("prop", m, rp, rng.randf_range(0, TAU), rng.randf_range(1.2, 2.2))
					obst.append([rp.x, rp.z, 0.8])
	# pillars on wall corners
	for z in gh + 1:
		for x in gw + 1:
			var a := cell(x - 1, z - 1)
			var b := cell(x, z - 1)
			var c2 := cell(x - 1, z)
			var d := cell(x, z)
			var n := a + b + c2 + d
			if n == 0 or n == 4:
				continue
			if n == 2 and ((a and b) or (c2 and d) or (a and c2) or (b and d)):
				continue # straight wall run
			var p := Vector3(x * T, 0, z * T)
			var ph := maxf(zone_h(zone_of[maxi(0, z - 1) * gw + maxi(0, x - 1)]), zone_h(zone_of[mini(gh - 1, z) * gw + mini(gw - 1, x)]))
			_add("prop", "dungeon-pillar", p, 0.0, Vector3(1.15, ph / 4.0 + 0.05, 1.15))
			obst.append([p.x, p.z, 0.75])

func _wall_torch(cx: int, cz: int, side: String, h := 3.0) -> void:
	var s: Array = { "n": [0, -1, PI], "s": [0, 1, 0.0], "e": [1, 0, -PI / 2], "w": [-1, 0, PI / 2] }[side]
	var c := W(cx, cz)
	var p := Vector3(c.x + s[0] * (T / 2), h, c.z + s[1] * (T / 2))
	var flame := p + Vector3(-s[0] * 0.55, 1.05, -s[1] * 0.55)
	_add("torch", "dungeon-torch", p, s[2], 1.4, { "flame": flame, "light": flame + Vector3(-s[0] * 1.2, 0, -s[1] * 1.2) })

func _support_frame(cx: float, cz: float, along_x: bool, span := 2 * T) -> void:
	var c := W(cx, cz)
	var half := span / 2 - 0.4
	for s in [-1, 1]:
		var p := Vector3(c.x, 0, c.z + s * half) if along_x else Vector3(c.x + s * half, 0, c.z)
		_add("timber", "", p + Vector3(0, 3.4, 0), rng.randf_range(-0.04, 0.04), Vector3(0.6, 6.8, 0.6))
		obst.append([p.x, p.z, 0.45])
	_add("timber", "", c + Vector3(0, 6.9, 0), 0.0, Vector3(0.65, 0.65, span + 0.4) if along_x else Vector3(span + 0.4, 0.65, 0.65))

func _prop_obst(m: String, p: Vector3, rot: float, s, r: float) -> void:
	_add("prop", m, p, rot, s)
	if r > 0:
		obst.append([p.x, p.z, r])

func _decorate() -> void:
	# entrance tunnel: timber frames and daylight spilling in from the mouth
	for z in range(16, 26, 2):
		_support_frame(3.0, z, false, 3 * T)
	_add("daylight", "", Vector3(3.5 * T, 4, 27.5 * T))
	_add("light", "", Vector3(3.5 * T, 6, 26 * T), 0.0, 1.0, { "color": Color(0.6, 0.75, 1), "range": 34.0, "energy": 2.2 })
	_add("light", "", Vector3(3.5 * T, 4, 22 * T), 0.0, 1.0, { "color": Color(0.55, 0.68, 0.9), "range": 22.0, "energy": 0.8 })
	_wall_torch(2, 18, "w")
	_wall_torch(4, 22, "e")
	_prop_obst("p_Barrel", W(4, 24) + Vector3(1.3, 0, 0), 0.3, 1.7, 0.8)
	_prop_obst("p_Crate_Wooden", W(2, 23) + Vector3(-0.8, 0, 0.5), 0.5, 1.7, 0.9)

	# lower diggings: ore heaps, timber, lanterns
	for t in [[1, 9, "w"], [9, 8, "e"], [5, 7, "n"], [2, 14, "s"], [8, 13, "e"]]:
		_wall_torch(t[0], t[1], t[2])
	for o in [[2, 8, "k_Gold_Nuggets"], [8, 9, "k_Iron_Nuggets"], [1, 12, "k_Stone_Chunks_Large"], [9, 13, "k_Copper_Nuggets"], [6, 7, "k_Stone_Chunks_Small"]]:
		var p := W(o[0], o[1]) + Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1))
		_prop_obst(o[2], p, rng.randf_range(0, 6), 2.6, 1.3)
	_prop_obst("k_Wood_Log_Stack", W(1, 10) + Vector3(-0.6, 0, 0), PI / 2, 2.2, 1.5)
	_prop_obst("k_Wood_Planks_Stack_Small", W(7, 14) + Vector3(0, 0, 0.6), 0.2, 2.2, 0)
	_prop_obst("p_Bucket_Wooden_1", W(3, 13) + Vector3(-1.2, 0, 1), 0.0, 1.7, 0)
	_prop_obst("p_Rope_1", W(6, 13), 0.4, 1.8, 0)
	for x in [10.5, 12.5, 14.5]:
		_support_frame(x, 10.0, true, 3 * T)
	for q in [[3, 9], [7, 12]]:
		_prop_obst("dungeon-pillar", W(q[0], q[1]), 0.4, Vector3(0.7, 2, 0.7), 0.6)

	# sorting cave: crates and barrels of ore, a workbench
	for t in [[15, 7, "w"], [20, 12, "e"], [17, 5, "n"], [16, 14, "s"]]:
		_wall_torch(t[0], t[1], t[2])
	for s in [[15, 6, "p_Crate_Wooden", 1.8, 0.0], [15, 6, "p_Crate_Wooden", 1.8, 1.3], [19, 6, "p_Barrel", 1.8, 0.0], [19, 7, "p_Barrel", 1.8, 0.0],
			[15, 13, "p_Crate_Metal", 1.6, 0.0], [19, 13, "p_Workbench", 1.7, 0.0], [18, 13, "p_Barrel_Holder", 1.7, 0.0]]:
		var ox := -0.8 if s[0] == 15 else (0.8 if s[0] == 19 else 0.0)
		var p := W(s[0], s[1]) + Vector3(ox, s[4], -0.8 if s[1] == 6 else 0.8)
		_prop_obst(s[2], p, rng.randf_range(-0.3, 0.3), s[3], 0.0 if s[4] > 0 else 1.1)
	_support_frame(21.0, 9.0, true, 3 * T)
	_support_frame(22.3, 9.0, true, 3 * T)

	# overseer's hall: rails, carts, the shift bell, braziers
	for t in [[23, 3, "w"], [23, 8, "w"], [23, 13, "w"], [33, 4, "e"], [33, 9, "e"], [33, 14, "e"], [25, 2, "n"], [31, 2, "n"], [26, 15, "s"], [31, 15, "s"]]:
		_wall_torch(t[0], t[1], t[2])
	_add("rails", "", Vector3(23.1 * T, 0, 13.5 * T), 0.0, 1.0, { "x1": 34 * T - 0.4 })
	for p in [W(24, 3), W(32, 3), W(24, 14), W(32, 11)]:
		_add("brazier", "p_Cauldron", p, rng.randf_range(0, 6), 2.2)
		obst.append([p.x, p.z, 1.1])
	_prop_obst("p_Anvil", W(32, 6) + Vector3(1, 0, 0), PI / 2, 2.0, 0.9)
	_prop_obst("p_Table_Large", W(24, 6) + Vector3(-0.8, 0, 0), PI / 2, 1.7, 0)
	obst.append([W(24, 6).x - 0.8, W(24, 6).z - 1.2, 0.9])
	obst.append([W(24, 6).x - 0.8, W(24, 6).z + 1.2, 0.9])
	_prop_obst("p_Cage_Small", W(33, 8) + Vector3(1, 0, 0), 0.3, 2.4, 1.0)
	_prop_obst("p_Chain_Coil", W(26, 7), 0.4, 2.0, 0)
	_prop_obst("k_Gold_Nuggets", W(33, 2) + Vector3(1, 0, -1), 0.4, 3.0, 1.4)
	for q in [[26, 5], [30, 5], [26, 10], [30, 10]]:
		_prop_obst("dungeon-pillar", W(q[0], q[1]) + Vector3(T / 2, 0, 0), 0.0, Vector3(1.1, 3.05, 1.1), 1.0)
	for x in range(24, 33, 2):
		_add("timber", "", Vector3((x + 0.5) * T, 11.4, 9 * T), 0.0, Vector3(0.7, 0.7, 13 * T))
	_add("prop", "dungeon-banner", W(27, 2) + Vector3(0, 0, -1.6), 0.0, 1.3)
	_add("prop", "dungeon-banner", W(29, 2) + Vector3(0, 0, -1.6), 0.0, 1.3)
	# the shift bell (Gorrak rings it in phase 2)
	var bell := Vector3(28.5 * T, 0, 2.9 * T)
	_add("bell", "", bell)
	obst.append([bell.x - 1.6, bell.z, 0.5])
	obst.append([bell.x + 1.6, bell.z, 0.5])
	# the sealed gate north: rubble and a portcullis of timbers, closed for this slice
	for i in 7:
		var m: String = ["q_rock_tall", "k_Stone_Chunks_Large", "q_rock_large"][rng.randi() % 3]
		_add("prop", m, W(28, 0) + Vector3(rng.randf_range(-5, 5), rng.randf_range(0, 1.5), rng.randf_range(-1, 3)), rng.randf_range(0, 6), rng.randf_range(2.5, 4.5))
	for i in range(-2, 3):
		_add("timber", "", W(28, 1) + Vector3(i * 2.2, 3.5, 1.6), 0.0, Vector3(0.45, 7, 0.45))
	_add("timber", "", W(28, 1) + Vector3(0, 6.6, 1.6), 0.0, Vector3(10, 0.5, 0.5))
	_add("timber", "", W(28, 1) + Vector3(0, 2.4, 1.6), 0.0, Vector3(10, 0.4, 0.4))
	for x in range(27, 30):
		for z in range(0, 2):
			grid[z * GW + x] = 0

## Mine-cart start positions on the hall rails.
func cart_starts() -> Array:
	return [Vector3(25.5 * T, 0, 13.5 * T), Vector3(31 * T, 0, 13.5 * T)]
