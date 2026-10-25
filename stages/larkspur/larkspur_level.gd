class_name LarkspurLevel
extends Level
## Larkspur Vale: an open valley starting zone under a big sky. The party sets out from the village of
## Larkspur Crossing in the south, crosses the Silverrun by the old bridge, clears the brigand camp on
## Millrise and the ruined watchtower on Watcher's Knoll, then climbs the road to Thornwatch Keep, a
## broken hill fort where Old Mossjaw holds court.
## The sim stays flat on the grid; terrain_h() is the shared, seeded height the client draws and puts units on.

const PLAT_H := 7.0 # Thornwatch plateau height
const WATER_Y := -1.0 # river and lake surface
const RIVER_W := 6.5 # river half width (m)
const BRIDGE := Vector2i(15, 20) # cell x range of the bridge deck
const FORD := Vector2i(44, 47) # cell x range of the shallow ford
const KEEP := Rect2i(44, 4, 15, 12) # courtyard cells (x 44-58, z 4-15)
const FORT := Rect2i(41, 1, 21, 17) # plateau and walls (x 41-61, z 1-17)
const GATE := Vector2i(48, 50) # gate cells in the south wall
const RAMP := Rect2i(47, 18, 5, 9) # road up to the gate (x 47-51, z 18-26)
const LAKE := Vector3(40.0, 38.0, 0.0) # Glassmere centre (world x, z)
const LAKE_R := Vector2(26.0, 18.0)
const START := Vector2(16.0, 54.0)

## The dirt road the party follows, in cells. Trees keep off it and the client paints it.
const ROAD := [Vector2(16, 58), Vector2(16, 51), Vector2(17.5, 45), Vector2(17.5, 38), Vector2(18.5, 32), Vector2(21, 29.5),
	Vector2(28, 30.5), Vector2(35, 31.5), Vector2(42, 30), Vector2(47, 28.5), Vector2(49.5, 26), Vector2(49.5, 17), Vector2(51, 12)]
const ROAD_WEST := [Vector2(18.5, 32), Vector2(14, 27), Vector2(13, 23)] # spur to the windmill
const ROAD_EAST := [Vector2(17.5, 45), Vector2(30, 43), Vector2(45, 40), Vector2(45.5, 36), Vector2(46, 31), Vector2(47, 28.5)] # via the ford

## Village houses: [cell x, cell z, yaw, roof colour index]. Each blocks a 2x2 cell footprint.
const HOUSES := [[9, 48, 0.3, 0], [22, 47, -0.2, 1], [8, 55, 1.5, 2], [23, 54, -1.4, 0], [11, 59, 0.1, 1], [20, 59, -0.1, 2]]

static var _noise: FastNoiseLite
var road_pts: Array = [] # world-space polylines (Array of PackedVector2Array)

func _configure() -> void:
	stage_id = "larkspur"
	gw = 64
	gh = 64
	rng.seed = 2207
	zone_names = { "village": "Larkspur Crossing", "vale": "Larkspur Vale", "bridge": "Larkspur Vale", "ford": "Larkspur Vale",
		"millrise": "Millrise", "glassmere": "Glassmere", "highmeadow": "Glassmere", "knoll": "Watcher's Knoll",
		"eastbank": "Thornwatch Road", "road": "Thornwatch Road", "keep": "Thornwatch Keep" }
	arena_zones = ["keep"]
	cam_far = 900.0

static func noise() -> FastNoiseLite:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.seed = 7
		_noise.frequency = 0.012
		_noise.fractal_octaves = 3
	return _noise

# ------------------------------------------------------------------ shape of the land
func river_z(x: float) -> float:
	return (38.0 + 1.8 * sin(x / T * 0.12 + 0.5)) * T

func lake_d(x: float, z: float) -> float:
	var dx := (x - LAKE.x) / LAKE_R.x
	var dz := (z - LAKE.y) / LAKE_R.y
	return sqrt(dx * dx + dz * dz)

static func _bump(x: float, z: float, cx: float, cz: float, r: float, h: float) -> float:
	var d := Vector2(x - cx, z - cz).length() / r
	return h * (0.5 + 0.5 * cos(PI * d)) if d < 1.0 else 0.0

## Signed distance (m) from a point to a cell rectangle; negative inside.
static func _rect_d(x: float, z: float, r: Rect2i) -> float:
	var x0 := r.position.x * T
	var z0 := r.position.y * T
	var x1 := (r.position.x + r.size.x) * T
	var z1 := (r.position.y + r.size.y) * T
	var dx := maxf(x0 - x, x - x1)
	var dz := maxf(z0 - z, z - z1)
	if dx < 0 and dz < 0:
		return maxf(dx, dz)
	return Vector2(maxf(dx, 0), maxf(dz, 0)).length()

## Ground height anywhere, including the mountains outside the playable area.
func terrain_h(x: float, z: float) -> float:
	var n := noise()
	var h := n.get_noise_2d(x, z) * 2.2
	h += _bump(x, z, 13.5 * T, 23.5 * T, 36.0, 6.0) # Millrise
	h += _bump(x, z, 39.0 * T, 25.0 * T, 24.0, 4.0) # Watcher's Knoll
	h += _bump(x, z, 30.0 * T, 8.0 * T, 40.0, 3.0) # high meadow
	# the village sits on a gentle, nearly flat green
	var vk := 1.0 - smoothstep(0.0, 16.0, _rect_d(x, z, Rect2i(6, 46, 20, 15)))
	h = lerpf(h, 0.4 + n.get_noise_2d(x * 0.5, z * 0.5) * 0.4, vk)
	# the Silverrun: banks slope down to the water, a bed below it
	var rd := absf(z - river_z(x))
	h = lerpf(h, -0.5, 1.0 - smoothstep(RIVER_W, RIVER_W + 16.0, rd))
	if rd < RIVER_W:
		var ford := x > FORD.x * T and x < (FORD.y + 1) * T
		h = lerpf(-0.5, -1.35 if ford else -3.2, smoothstep(RIVER_W, RIVER_W - (2.0 if ford else 3.5), rd))
	# Glassmere
	var ld := lake_d(x, z)
	h = lerpf(h, -0.5, 1.0 - smoothstep(1.0, 1.7, ld))
	if ld < 1.0:
		h = lerpf(-0.5, -4.0, smoothstep(1.0, 0.75, ld))
	# Thornwatch plateau with a steep, rounded scarp, and the road climbing to its gate
	var fd := _rect_d(x, z, FORT)
	var plat := 1.0 - smoothstep(-1.0, 7.0, fd)
	var rx0 := RAMP.position.x * T
	var rx1 := (RAMP.position.x + RAMP.size.x) * T
	var rz0 := RAMP.position.y * T
	var rz1 := (RAMP.position.y + RAMP.size.y) * T
	var t := clampf((rz1 - z) / (rz1 - rz0), 0.0, 1.0)
	if t > 0.0:
		var ramp_h := lerpf(h, PLAT_H, smoothstep(0.0, 1.0, t))
		var side := maxf(rx0 - x, x - rx1) # >0 beside the road
		h = lerpf(h, ramp_h, 1.0 - smoothstep(0.0, 14.0, side)) # embankments fall away on both sides
	h = lerpf(h, PLAT_H + n.get_noise_2d(x * 2.0, z * 2.0) * 0.08, clampf(plat, 0.0, 1.0))
	# mountains all around the vale
	var m := minf(minf(x, gw * T - x), minf(z, gh * T - z))
	var ridge := absf(n.get_noise_2d(x * 1.7 + 300.0, z * 1.7)) * 2.0 - 0.6
	h += 58.0 * smoothstep(13.0, -70.0, m) + 22.0 * ridge * smoothstep(13.0, -25.0, m) + 6.0 * smoothstep(14.0, 2.0, m)
	return h

func _on_bridge(x: float, z: float) -> bool:
	return x > BRIDGE.x * T - 0.5 and x < (BRIDGE.y + 1) * T + 0.5 and absf(z - river_z(x)) < RIVER_W + 3.0

## Height of the bridge deck: a shallow arch over the water.
func bridge_y(x: float, z: float) -> float:
	var u := (z - river_z(x)) / (RIVER_W + 3.0)
	return 0.1 + 1.1 * (1.0 - u * u)

func floor_y(x: float, z: float) -> float:
	if _on_bridge(x, z):
		return maxf(terrain_h(x, z), bridge_y(x, z))
	return terrain_h(x, z)

func zone_h(_zone: String) -> float:
	return 999.0 # open sky

# ------------------------------------------------------------------ layout
func _zone_for(cx: int, cz: int) -> String:
	var x := (cx + 0.5) * T
	var z := (cz + 0.5) * T
	var edge := float(mini(mini(cx, gw - 1 - cx), mini(cz, gh - 1 - cz))) + noise().get_noise_2d(x * 3.0, z * 3.0) * 1.5
	if edge < 2.6:
		return ""
	if FORT.has_point(Vector2i(cx, cz)):
		if KEEP.has_point(Vector2i(cx, cz)):
			return "keep"
		if cz >= 16 and cx >= GATE.x and cx <= GATE.y:
			return "road"
		return ""
	if lake_d(x, z) < 1.05:
		return ""
	if absf(z - river_z(x)) < RIVER_W:
		if cx >= BRIDGE.x and cx <= BRIDGE.y:
			return "bridge"
		if cx >= FORD.x and cx <= FORD.y:
			return "ford"
		return ""
	if RAMP.has_point(Vector2i(cx, cz)):
		return "road"
	# embankments beside the upper ramp: too steep to stand on
	if cz >= RAMP.position.y and cz < RAMP.position.y + 6 and cx >= RAMP.position.x - 3 and cx < RAMP.position.x + RAMP.size.x + 3:
		return ""
	if z > river_z(x):
		return "village" if cx < 30 and cz >= 45 else "vale"
	if cz < 17 and cx < 41:
		return "glassmere" if cx < 24 else "highmeadow"
	if cx < 32:
		return "millrise"
	if cx < 42:
		return "knoll"
	return "eastbank"

func _layout() -> void:
	for cz in gh:
		for cx in gw:
			var zn := _zone_for(cx, cz)
			zone_of[cz * gw + cx] = zn if zn != "" else _outer_zone(cx, cz)
			grid[cz * gw + cx] = 1 if zn != "" else 0
	for line in [ROAD, ROAD_WEST, ROAD_EAST]:
		var pts := PackedVector2Array()
		for p in line:
			pts.append((p + Vector2(0.5, 0.5)) * T)
		road_pts.append(pts)
	_place_landmarks()
	_place_village()
	_place_trees()

## Zone label for a solid cell, so the client can tell water from cliff from fort wall.
func _outer_zone(cx: int, cz: int) -> String:
	var x := (cx + 0.5) * T
	var z := (cz + 0.5) * T
	if FORT.has_point(Vector2i(cx, cz)):
		return "_wall"
	if lake_d(x, z) < 1.05 or absf(z - river_z(x)) < RIVER_W:
		return "_water"
	return ""

func road_d(x: float, z: float) -> float:
	var best := 1e9
	for pts in road_pts:
		for i in pts.size() - 1:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var p := Vector2(x, z)
			var ab := b - a
			var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
			best = minf(best, p.distance_to(a + ab * t))
	return best

func _solid_cells(cx: int, cz: int, w: int, d: int) -> void:
	for z in range(cz, cz + d):
		for x in range(cx, cx + w):
			grid[z * gw + x] = 0

func _at(cx: float, cz: float) -> Vector3:
	var p := W(cx, cz)
	p.y = floor_y(p.x, p.z)
	return p

func _place_landmarks() -> void:
	# the windmill on Millrise, seen from everywhere in the vale
	var mill := _at(13.0, 22.5)
	_add("windmill", "", mill, 0.6, 1.0)
	obst.append([mill.x, mill.z, 4.2])
	# the broken watchtower on the knoll
	var tower := _at(39.0, 23.5)
	_add("tower", "", tower, 0.3, 1.0)
	obst.append([tower.x, tower.z, 3.6])
	# the brigand camp below Millrise: tents, a fire, loot
	for t in [[17.5, 25.5, 0.9], [23.5, 26.0, -0.6], [20.5, 24.5, 0.1]]:
		var p := _at(t[0], t[1])
		_add("tent", "", p, t[2], 1.0)
		obst.append([p.x, p.z, 2.2])
	_add("campfire", "q_campfire", _at(20.5, 28.0), 0.0, 1.6)
	obst.append([W(20.5, 28.0).x, W(20.5, 28.0).z, 0.9])
	for c in [[18.6, 27.6, "p_Crate_Wooden"], [22.6, 27.4, "p_Barrel"], [22.9, 28.1, "p_Barrel"], [17.8, 28.6, "p_Chest_Wood"]]:
		var p := _at(c[0], c[1])
		_add("prop", c[2], p, rng.randf_range(0, TAU), 1.7)
		obst.append([p.x, p.z, 0.8])
	_add("banner", "", _at(21.0, 26.0), 0.0, 1.0, { "color": Color("#8a3b3b") })
	# the bridge and the ford stones
	_add("bridge", "", _at((BRIDGE.x + BRIDGE.y + 1) / 2.0 - 0.5, 38.0), 0.0, 1.0)
	for i in 9:
		var p := W(FORD.x + 0.2 + i * 0.42, 0.0)
		p.z = river_z(p.x) + rng.randf_range(-RIVER_W * 0.7, RIVER_W * 0.7)
		p.y = terrain_h(p.x, p.z)
		_add("rock", ["k_Rock_1_A_Color1", "k_Rock_2_A_Color1"][i % 2], p, rng.randf_range(0, TAU), rng.randf_range(0.8, 1.4))
	# Thornwatch: walls round the courtyard with a gate in the south wall, fallen stones inside
	_add("fort", "", _at(51.5, 10.0), 0.0, 1.0)
	for q in [[45.5, 5.5], [57.5, 5.5], [45.5, 14.5], [57.5, 14.5]]:
		var p := _at(q[0], q[1])
		_add("ruin_pillar", "", p, rng.randf_range(0, TAU), 1.0)
		obst.append([p.x, p.z, 1.3])
	# a waterfall pouring off the northern mountains into Glassmere
	_add("waterfall", "", Vector3(LAKE.x - 4.0, WATER_Y, LAKE.y - LAKE_R.y - 10.0), 0.0, 1.0)
	# boulders scattered over the meadows
	for i in 26:
		var cx := rng.randf_range(4, 60)
		var cz := rng.randf_range(4, 60)
		if not cell(int(cx), int(cz)) or road_d(cx * T, cz * T) < 7.0 or Vector2(cx, cz).distance_to(START) < 6:
			continue
		var p := _at(cx, cz)
		var s := rng.randf_range(1.2, 2.6)
		_add("rock", ["q_rock_large", "k_Rock_1_A_Color1", "k_Rock_2_A_Color1", "q_rock_tall"][rng.randi() % 4], p, rng.randf_range(0, TAU), s)
		obst.append([p.x, p.z, 0.7 * s])

func _place_village() -> void:
	for h in HOUSES:
		var p := _at(h[0] + 0.5, h[1] + 0.5)
		_add("house", "", p, h[2], 1.0, { "roof": h[3] })
		_solid_cells(h[0], h[1], 2, 2)
	var well := _at(16.0, 51.5)
	_add("well", "", well, 0.0, 1.0)
	obst.append([well.x, well.z, 1.4])
	# a market stall, crates and barrels around the green
	for c in [[12.6, 52.0, "p_Barrel"], [12.2, 52.6, "p_Barrel"], [19.8, 56.8, "p_Crate_Wooden"], [20.4, 56.3, "p_Crate_Wooden"], [13.8, 56.5, "p_Bench"],
			[19.0, 51.0, "p_Bench"], [24.8, 50.8, "k_Wood_Log_Stack"], [7.6, 52.5, "p_Bucket_Wooden_1"]]:
		var p := _at(c[0], c[1])
		_add("prop", c[2], p, rng.randf_range(-0.4, 0.4), 1.7)
		obst.append([p.x, p.z, 0.8])
	_add("stall", "", _at(12.5, 50.5), 0.2, 1.0)
	obst.append([W(12.5, 50.5).x, W(12.5, 50.5).z, 1.8])
	# lamp posts along the road and fences round the edge of the village
	for l in [[15.0, 49.0], [17.6, 46.0], [14.8, 57.0], [18.3, 41.6]]:
		var p := _at(l[0], l[1])
		_add("lamp", "", p, 0.0, 1.0)
		obst.append([p.x, p.z, 0.35])
	for f in [[6.5, 45.5, 13.0, 45.5], [20.0, 45.0, 27.0, 46.0], [5.0, 47.0, 5.0, 58.0], [27.5, 48.0, 27.5, 58.0]]:
		_add("fence", "", _at(f[0], f[1]), 0.0, 1.0, { "to": _at(f[2], f[3]) })
	# a signpost where the road leaves the village
	_add("sign", "", _at(18.6, 45.6), -0.4, 1.0)

func _place_trees() -> void:
	var n := noise()
	for cz in range(-6, gh + 6):
		for cx in range(-6, gw + 6):
			var x := (cx + rng.randf()) * T
			var z := (cz + rng.randf()) * T
			var walk := cell(floori(x / T), floori(z / T)) == 1
			var zn := zone_at(x, z)
			var forest := n.get_noise_2d(x * 2.2 + 90.0, z * 2.2) # groves where this is high
			var p_tree := 0.02 + clampf((forest - 0.2) * 1.4, 0.0, 0.5) # mostly open meadow, a few groves
			if not walk:
				# the slopes outside the vale are wooded up to the treeline
				var m := minf(minf(x, gw * T - x), minf(z, gh * T - z))
				if zone_of_at(x, z) in ["_water", "_wall"] or m < -55.0:
					continue
				p_tree = 0.45 if m > -30.0 else 0.2
			elif zn in ["keep", "road", "bridge", "ford", "village"]:
				continue
			if rng.randf() > p_tree:
				continue
			if walk and (road_d(x, z) < 8.0 or Vector2(x, z).distance_to(START * T) < 26.0 or _near_spawn(x, z, 9.0) or _near_obst(x, z, 3.5)):
				continue
			var y := terrain_h(x, z)
			if y < WATER_Y + 0.3:
				continue
			var s := rng.randf_range(0.85, 1.35) * (1.25 if not walk else 1.0)
			var kind := "pine" if (forest > 0.35 or not walk) and rng.randf() < 0.6 else "tree"
			_add(kind, "", Vector3(x, y, z), rng.randf_range(0, TAU), s, { "hue": rng.randf() })
			if walk:
				obst.append([x, z, 0.75 * s])

func zone_of_at(x: float, z: float) -> String:
	var cx := floori(x / T)
	var cz := floori(z / T)
	if cx < 0 or cz < 0 or cx >= gw or cz >= gh:
		return ""
	return zone_of[cz * gw + cx]

func _near_spawn(x: float, z: float, r: float) -> bool:
	for s in spawns():
		if Vector2(x - s[1] * T, z - s[2] * T).length() < r:
			return true
	return false

func _near_obst(x: float, z: float, r: float) -> bool:
	for o in obst:
		if Vector2(x - o[0], z - o[1]).length() < r + o[2]:
			return true
	return false

# ------------------------------------------------------------------ stage hooks
func enemy_defs() -> Dictionary:
	return {
		"brigand": { "name": "Thornwatch Brigand", "body": "footpad", "lvl": 5, "hp": 210, "dmg": [9, 14], "swing": 1.8, "speed": 6.6, "r": 0.8, "armor": 80 },
		"poacher": { "name": "Vale Poacher", "body": "miner", "lvl": 4, "hp": 170, "dmg": [7, 11], "swing": 2.0, "speed": 6.4, "r": 0.8, "armor": 50 },
		"captain": { "name": "Brigand Captain", "body": "taskmaster", "lvl": 6, "hp": 360, "dmg": [12, 18], "swing": 2.0, "speed": 6.4, "r": 0.95, "armor": 120, "elite": true },
		"crow": { "name": "Carrion Crow", "body": "bat", "lvl": 5, "hp": 50, "dmg": [3, 6], "swing": 1.2, "speed": 9.5, "r": 0.7, "armor": 0, "summon": true, "fly": 3.0 },
		"mossjaw": { "name": "Old Mossjaw", "body": "gorrak", "lvl": 7, "hp": 3200, "dmg": [26, 34], "swing": 2.3, "speed": 6.2, "r": 1.8, "armor": 180, "boss": "mossjaw", "aggro": 16.0 },
	}

func spawns() -> Array:
	return [
		["poacher", 16.6, 43.6, "a", 0.2], ["poacher", 19.2, 44.2, "a", -0.2],
		["brigand", 19.4, 29.4, "b", 0.3], ["brigand", 22.2, 29.0, "b", -0.3], ["poacher", 21.0, 26.9, "b", 0.0],
		["brigand", 11.6, 26.6, "c", 0.5], ["poacher", 15.4, 27.4, "c", 0.0],
		["captain", 38.6, 28.0, "d", -0.8], ["brigand", 37.2, 26.8, "d", -1.0], ["brigand", 40.4, 29.6, "d", -0.5],
		["poacher", 45.4, 32.6, "e", 0.0], ["poacher", 43.8, 31.6, "e", 0.4],
		["brigand", 48.2, 20.2, "f", 0.0], ["brigand", 50.8, 20.2, "f", 0.0],
		["mossjaw", 51.0, 8.5, "boss", 0.0],
	]

func start_spots() -> Array:
	return [Vector2(16.0, 54.6), Vector2(16.9, 55.2), Vector2(15.1, 55.2), Vector2(16.5, 56.0), Vector2(15.5, 56.0)]

func start_point() -> Vector3:
	return W(16.0, 55.0)

func checkpoints() -> Array:
	return [["millrise", W(18.5, 32.5)], ["knoll", W(35.0, 31.5)], ["road", W(49.5, 25.5)]]

func intro_text() -> String:
	return "Morning in Larkspur Crossing. Brigands have taken the old keep on the ridge, and the road north isn't safe."

func boss_script(boss: String, sim) -> Object:
	if boss == "mossjaw":
		return MossjawFight.new(sim)
	return null
