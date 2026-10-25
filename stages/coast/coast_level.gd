class_name CoastLevel
extends Level
## Tidecrown Ruins: a sunlit coast. Layout, cell kinds, spawns and the boss hook.
## Same grid conventions as Level (x east, z south, T = 4 m cells). The landing is in the south,
## the beach runs north to the Sunward Colonnade, and a causeway leads west over the lagoon
## to the Drowned Sanctum, where the boss waits.
## Floor cells are walkable. Solid cells are either sea or cliff, which only changes how the
## client dresses them.

const STAGE_NAME := "Tidecrown Ruins"
const COAST_ZONES := { "landing": "Driftwood Landing", "beach": "Seaglass Strand", "colonnade": "The Sunward Colonnade",
	"causeway": "Gullstone Causeway", "sanctum": "The Drowned Sanctum" }
## the boss arena: centre and radius in cells
const SANCTUM_C := Vector2(8.5, 16.0)
const SANCTUM_R := 7.4
## plinths that stay dry when the tide rises (cell coords, radius in metres)
const PLINTHS := [[8.5, 16.0, 5.0], [4.2, 11.9, 2.6], [12.8, 11.9, 2.6], [4.2, 20.1, 2.6], [12.8, 20.1, 2.6]]

var kind: Array[String] = [] # floor: sand | stone | shallow ; solid: sea | cliff
var tide_target := -0.25 # the sanctum water level the boss wants (see CoastBoss.tick_tide)
var tide_init := false

func _configure() -> void:
	stage_id = "coast"
	gw = 50
	gh = 46
	zone_names = COAST_ZONES
	arena_zones = ["sanctum"]
	cam_far = 1500.0
	rng.seed = 4242
	for b in CoastData.BODIES:
		Assets.extra_bodies[b] = CoastData.BODIES[b]

func _layout() -> void:
	kind.resize(gw * gh)
	for z in gh:
		for x in gw:
			kind[z * gw + x] = "cliff" if _is_cliff(x, z) else "sea"
	carve_k(24, 36, 35, 42, "landing", "sand")
	carve_k(11, 25, 37, 35, "beach", "sand")
	carve_k(27, 10, 43, 24, "colonnade", "stone")
	carve_k(16, 14, 26, 17, "causeway", "stone")
	carve_circle(SANCTUM_C, SANCTUM_R, "sanctum", "shallow")
	# beach edges: a ragged shoreline instead of a straight cut
	for c in [[11, 25], [12, 25], [11, 26], [11, 35], [12, 35], [13, 35], [11, 34], [14, 35], [37, 25], [24, 35], [22, 35], [23, 35]]:
		_fill(c[0], c[1])
	for c in [[24, 42], [25, 42], [35, 42], [35, 41], [24, 41]]:
		_fill(c[0], c[1])
	# tide pools in the west of the beach
	for c in [[12, 28], [13, 28], [12, 29], [13, 29], [14, 29], [12, 30], [13, 30], [15, 32], [16, 32], [15, 33], [16, 33], [17, 33]]:
		kind[c[1] * gw + c[0]] = "shallow"
	# the plinths and the gate of the sanctum are dry stone
	for z in gh:
		for x in gw:
			if zone_of[z * gw + x] != "sanctum":
				continue
			var p := W(x, z)
			for pl in PLINTHS:
				if Vector2(p.x, p.z).distance_to(Vector2((pl[0]) * T, (pl[1]) * T)) < pl[2] + 1.0:
					kind[z * gw + x] = "stone"
			if x >= 15:
				kind[z * gw + x] = "stone"
	_dress_coast()

func _is_cliff(x: int, z: int) -> bool:
	return x >= 44 or (z <= 9 and x >= 26) or (x >= 38 and z >= 25) or (x >= 36 and z >= 36)

func carve_k(x0: int, z0: int, x1: int, z1: int, zone: String, k: String) -> void:
	rects.append([x0, z0, x1, z1, zone])
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			_set_floor(x, z, zone, k)

func carve_circle(c: Vector2, r: float, zone: String, k: String) -> void:
	rects.append([floori(c.x - r), floori(c.y - r), floori(c.x + r), floori(c.y + r), zone])
	for z in range(floori(c.y - r), ceili(c.y + r) + 1):
		for x in range(floori(c.x - r), ceili(c.x + r) + 1):
			if Vector2(x + 0.5, z + 0.5).distance_to(c) <= r:
				_set_floor(x, z, zone, k)

func _set_floor(x: int, z: int, zone: String, k: String) -> void:
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return
	grid[z * gw + x] = 1
	zone_of[z * gw + x] = zone
	kind[z * gw + x] = k

func _fill(x: int, z: int) -> void:
	grid[z * gw + x] = 0
	zone_of[z * gw + x] = ""
	kind[z * gw + x] = "cliff" if _is_cliff(x, z) else "sea"

func kind_of(x: int, z: int) -> String:
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return "cliff" if _is_cliff(clampi(x, 0, gw - 1), clampi(z, 0, gh - 1)) else "sea"
	return kind[z * gw + x]

## world position of a cell coordinate without the half-cell offset (for spawns given in cells)
static func C(cx: float, cz: float) -> Vector3:
	return Vector3(cx * T, 0.0, cz * T)

# ------------------------------------------------------------------ dressing
func _put(k: String, pos: Vector3, rot := 0.0, scale = 1.0, extra := {}) -> void:
	var e := { "kind": k, "model": extra.get("model", ""), "pos": pos, "rot": rot, "scale": scale }
	e.merge(extra)
	decor.append(e)

func _ob(p: Vector3, r: float) -> void:
	obst.append([p.x, p.z, r])

func _column(p: Vector3, h: float, broken := false, r := 0.85) -> void:
	_put("column", p, rng.randf_range(0, TAU), 1.0, { "h": h, "broken": broken, "r": r })
	_ob(p, r + 0.15)

func _fallen(p: Vector3, rot: float, length: float, r := 0.85) -> void:
	_put("fallen", p, rot, 1.0, { "len": length, "r": r })
	var dir := Vector3(cos(rot), 0, -sin(rot))
	for i in range(-1, 2):
		_ob(p + dir * (length / 3.0) * i, r + 0.1)

func _palm(p: Vector3, h := 0.0) -> void:
	_put("palm", p, rng.randf_range(0, TAU), 1.0, { "h": h if h > 0 else rng.randf_range(7.5, 11.0), "lean": rng.randf_range(0.12, 0.32), "seed": rng.randi() })
	_ob(p, 0.5)

func _rock(p: Vector3, s: float, solid := true, m := "") -> void:
	if m == "":
		m = ["q_rock_large", "q_rock_tall", "q_rock_small", "k_Rock_1_A_Color1", "k_Rock_2_A_Color1"][rng.randi() % 5]
	_put("prop", p, rng.randf_range(0, TAU), s, { "model": m, "tint": Color("#d9c3a0") })
	if solid:
		_ob(p, s * 0.45)

func _prop(m: String, p: Vector3, rot: float, s, r := 0.0) -> void:
	_put("prop", p, rot, s, { "model": m })
	if r > 0:
		_ob(p, r)

func _dress_coast() -> void:
	# ---- Driftwood Landing: a beached skiff, a small jetty, the first crates
	_put("boat", W(27, 43) + Vector3(0, -0.2, 1.0), 0.35, 1.0)
	_put("jetty", W(31, 42) + Vector3(0, 0, 2.0), 0.0, 1.0, { "len": 22.0 })
	_prop("p_Crate_Wooden", W(26, 38), 0.4, 1.7, 0.9)
	_prop("p_Crate_Wooden", W(26, 38) + Vector3(0.4, 1.3, 0.2), 0.9, 1.5)
	_prop("p_Barrel", W(27, 37) + Vector3(0.6, 0, 0), 0.0, 1.7, 0.8)
	_prop("p_Rope_1", W(28, 39), 0.4, 1.8)
	_put("lamp_post", W(34, 40), 0.0, 1.0)
	_ob(W(34, 40), 0.4)
	for p in [W(25, 41) + Vector3(-1.5, 0, 1), W(35, 37) + Vector3(1.4, 0, 0), W(33, 36)]:
		_palm(p)
	_rock(W(35, 42) + Vector3(1, 0, 1), 4.5, false)
	_put("driftwood", W(30, 41) + Vector3(0, 0, 1.4), 1.2, 1.0)

	# ---- Seaglass Strand: palms, a raider camp, tide pools, a wrecked hull
	for p in [[18, 26], [21, 25], [26, 26], [35, 27], [36, 30], [33, 34], [16, 34], [19, 35], [28, 34], [36, 33], [12, 27]]:
		_palm(W(p[0], p[1]) + Vector3(rng.randf_range(-1.2, 1.2), 0, rng.randf_range(-1.2, 1.2)))
	# raider camp
	var camp := W(23, 30)
	_put("campfire", camp, 0.0, 2.2, { "model": "q_campfire" })
	_ob(camp, 1.2)
	_put("tent", camp + Vector3(-6.5, 0, -3.5), 0.5, 1.0)
	_ob(camp + Vector3(-6.5, 0, -3.5), 2.6)
	_put("tent", camp + Vector3(5.5, 0, -4.5), -0.4, 0.9)
	_ob(camp + Vector3(5.5, 0, -4.5), 2.3)
	_prop("p_Crate_Wooden", camp + Vector3(3.5, 0, 3.0), 0.2, 1.7, 0.9)
	_prop("p_Barrel", camp + Vector3(4.6, 0, 1.8), 0.0, 1.7, 0.8)
	_prop("p_Chest_Wood", camp + Vector3(-3.0, 0, 3.6), 0.6, 1.6, 0.8)
	_prop("p_Bench", camp + Vector3(0, 0, -3.0), 0.0, 1.6)
	_prop("p_WeaponStand", camp + Vector3(-4.0, 0, 0.5), PI / 2, 1.6, 0.6)
	_put("flag", camp + Vector3(1.0, 0, -6.5), 0.0, 1.0, { "color": Color("#e2574c") })
	_ob(camp + Vector3(1.0, 0, -6.5), 0.3)
	# a wrecked hull beached on the lagoon shore, north of the strand
	_put("wreck", W(18, 24) + Vector3(0, 0, 0.5), -0.4, 1.0)
	# beach rocks and shells
	for p in [[14, 26], [36, 26], [20, 34], [11, 31], [30, 31]]:
		_rock(W(p[0], p[1]) + Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), rng.randf_range(2.4, 3.6))
	for i in 26:
		var p := W(rng.randi_range(12, 36), rng.randi_range(26, 34)) + Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
		_put("shell", p, rng.randf_range(0, TAU), rng.randf_range(0.7, 1.4), { "hue": rng.randf() })
	for c in [[12, 29], [13, 30], [16, 33]]:
		_put("coral", W(c[0], c[1]), rng.randf_range(0, TAU), 1.0, { "seed": rng.randi() })
	# the first ruins appear where the strand rises to the colonnade
	_column(W(28, 26), 3.5, true)
	_fallen(W(25, 27) + Vector3(0, 0, 1.5), 0.3, 7.0)

	# ---- The Sunward Colonnade: a processional avenue of columns up to a giant statue
	for z in range(22, 11, -3):
		for x in [31, 39]:
			var broken := rng.randf() < 0.35
			_column(W(x, z), rng.randf_range(4.0, 5.5) if broken else 9.0, broken)
	_put("lintel", (W(31, 13) + W(31, 16)) / 2.0 + Vector3(0, 9.0, 0), PI / 2, 1.0, { "len": 14.0 })
	_put("lintel", (W(39, 19) + W(39, 22)) / 2.0 + Vector3(0, 9.0, 0), PI / 2, 1.0, { "len": 14.0 })
	_fallen(W(35, 19), 1.2, 8.0)
	_fallen(W(29, 13) + Vector3(0, 0, 1), -0.5, 7.0)
	_fallen(W(41, 14), 0.2, 7.5)
	# the avenue's paving and a raised dais under the statue
	_put("avenue", W(35, 17), 0.0, 1.0, { "w": 28.0, "d": 56.0 })
	_put("dais", W(35, 11) + Vector3(0, 0, 0), 0.0, 1.0, { "r": 7.0 })
	_put("statue", W(35, 10) + Vector3(0, 0.9, -1.0), 0.0, 1.0)
	_ob(W(35, 10) + Vector3(0, 0, -1.0), 3.0)
	# west edge: a broken balustrade over the lagoon
	_put("balustrade", W(27, 10) + Vector3(-T / 2 - 0.4, 0, 0), 0.0, 1.0, { "len": 12 * T, "dir": Vector3(0, 0, 1), "gap": [4, 5, 6, 7] })
	_put("balustrade", W(43, 10) + Vector3(T / 2 + 0.4, 0, 0), 0.0, 1.0, { "len": 15 * T, "dir": Vector3(0, 0, 1), "gap": [] })
	for p in [[42, 23], [42, 11], [28, 22], [43, 18]]:
		_rock(W(p[0], p[1]), rng.randf_range(2.6, 3.6))
	for p in [[42, 21], [28, 11], [43, 16]]:
		_palm(W(p[0], p[1]) + Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), rng.randf_range(7, 9))
	_put("brazier", W(32, 11), 0.0, 1.0)
	_ob(W(32, 11), 0.9)
	_put("brazier", W(38, 11), 0.0, 1.0)
	_ob(W(38, 11), 0.9)

	# ---- Gullstone Causeway: a paved road over the lagoon under broken arches
	for x in [24, 20]:
		_put("arch", W(x, 14) + Vector3(0, 0, -T / 2 + 1.0), 0.0, 1.0, { "span": 4 * T - 2.0, "h": 8.0, "broken": x == 20 })
		_ob(W(x, 14) + Vector3(0, 0, -T / 2 + 1.0), 1.1)
		_ob(W(x, 17) + Vector3(0, 0, T / 2 - 1.0), 1.1)
	_put("balustrade", W(16, 14) + Vector3(0, 0, -T / 2 - 0.4), 0.0, 1.0, { "len": 11 * T, "dir": Vector3(1, 0, 0), "gap": [2, 5, 6] })
	_put("balustrade", W(16, 17) + Vector3(0, 0, T / 2 + 0.4), 0.0, 1.0, { "len": 11 * T, "dir": Vector3(1, 0, 0), "gap": [3, 4, 8] })
	_put("lamp_post", W(17, 14) + Vector3(0, 0, -0.8), 0.0, 1.0)
	_ob(W(17, 14) + Vector3(0, 0, -0.8), 0.4)
	_put("lamp_post", W(17, 17) + Vector3(0, 0, 0.8), 0.0, 1.0)
	_ob(W(17, 17) + Vector3(0, 0, 0.8), 0.4)

	# ---- The Drowned Sanctum: a ring of columns, a broken dome, flooded floor, dry plinths
	var sc := Vector3(SANCTUM_C.x * T, 0, SANCTUM_C.y * T)
	var ring_r := SANCTUM_R * T + 1.2
	var n := 20
	var standing: Array = []
	for i in n:
		var a := TAU * i / n
		var p := sc + Vector3(cos(a), 0, sin(a)) * ring_r
		if absf(wrapf(a, -PI, PI)) < 0.32:
			standing.append(false)
			continue # the gate faces the causeway (east)
		var broken := i % 3 == 1 or i % 7 == 0
		standing.append(not broken)
		_put("column", p, a, 1.0, { "h": rng.randf_range(4.5, 7.0) if broken else 12.0, "broken": broken, "r": 1.05 })
	var spans: Array = []
	for i in n:
		if standing[i] and standing[(i + 1) % n]:
			spans.append([TAU * i / n, TAU * (i + 1) / n])
	_put("ring_wall", sc, 0.0, 1.0, { "r": ring_r + 0.6, "h": 3.2, "gate": 0.36 })
	_put("dome_ring", sc + Vector3(0, 12.0, 0), 0.0, 1.0, { "r": ring_r, "spans": spans })
	# gate: two tall columns and a lintel
	for s in [-1, 1]:
		var gp := sc + Vector3(ring_r + 1.0, 0, s * 8.5)
		_put("column", gp, 0.0, 1.0, { "h": 13.0, "broken": false, "r": 1.3 })
	_put("lintel", sc + Vector3(ring_r + 1.0, 13.0, 0), PI / 2, 1.0, { "len": 19.0, "thick": 1.6 })
	for pl in PLINTHS:
		_put("plinth", C(pl[0], pl[1]), 0.0, 1.0, { "r": pl[2] })
	for i in 6:
		var a := TAU * (i + 0.5) / 6
		var p := sc + Vector3(cos(a), 0, sin(a)) * (ring_r - 3.0)
		_put("brazier", p, 0.0, 1.0, { "blue": true })
		_ob(p, 0.9)
	_put("seal", sc, 0.0, 1.0, { "r": 4.4 })

	# ---- the sea: stacks, islands and a ruined lighthouse on the horizon
	_put("sea_stack", Vector3(-30, 0, 120), 0.0, 1.0, { "h": 26.0, "r": 9.0 })
	_put("sea_stack", Vector3(-12, 0, 155), 0.0, 1.0, { "h": 16.0, "r": 6.0 })
	_put("sea_stack", Vector3(70, 0, 205), 0.0, 1.0, { "h": 20.0, "r": 7.0 })
	_put("sea_stack", Vector3(-60, 0, 30), 0.0, 1.0, { "h": 34.0, "r": 12.0 })
	_put("sea_stack", Vector3(78, 0, 82), 0.0, 1.0, { "h": 12.0, "r": 5.0 }) # in the lagoon
	_put("sea_stack", Vector3(-20, 0, -40), 0.0, 1.0, { "h": 22.0, "r": 8.0 })
	_put("lighthouse", Vector3(-60, 34, 30), 0.0, 1.0)
	_put("island", Vector3(-260, 0, 60), 0.0, 1.0, { "r": 70.0, "h": 40.0 })
	_put("island", Vector3(-180, 0, 300), 0.0, 1.0, { "r": 50.0, "h": 26.0 })
	_put("island", Vector3(-120, 0, -200), 0.0, 1.0, { "r": 60.0, "h": 34.0 })

## Spawn table for this stage: [type, cell x, cell z, pack, facing]
const COAST_SPAWNS := [
	["gull", 30.0, 37.5, "l1", 0.0], ["gull", 31.4, 37.0, "l1", 0.0],
	["raider", 22.0, 29.0, "b1", 0.8], ["raider", 24.5, 29.4, "b1", -0.6], ["tidecaller", 23.2, 28.2, "b1", 0.0],
	["sentry", 14.6, 31.2, "b2", 1.2], ["sentry", 15.6, 30.2, "b2", 1.6],
	["gull", 33.0, 27.5, "b3", 0.0], ["gull", 34.2, 28.4, "b3", 0.0], ["gull", 32.6, 28.8, "b3", 0.0],
	["sentry", 33.0, 20.5, "c1", PI], ["sentry", 37.0, 20.5, "c1", PI],
	["raider", 36.0, 15.5, "c2", PI], ["tidecaller", 34.5, 16.2, "c2", PI],
	["corsair", 35.5, 12.8, "c3", 0.0], ["raider", 33.8, 13.6, "c3", 0.0], ["raider", 37.2, 13.6, "c3", 0.0],
	["sentry", 21.5, 15.4, "d1", PI / 2], ["sentry", 21.5, 16.6, "d1", PI / 2],
	["ondrak", 8.5, 16.0, "boss", -PI / 2],
]

# ------------------------------------------------------------------ stage hooks
func spawns() -> Array:
	return COAST_SPAWNS

func start_spots() -> Array:
	return [Vector2(29.6, 40.2), Vector2(30.4, 40.8), Vector2(28.8, 40.9), Vector2(30.2, 39.6), Vector2(29.2, 41.5)]

func start_point() -> Vector3:
	return W(29, 40)

func checkpoints() -> Array:
	return [["beach", W(27, 33)], ["colonnade", W(35, 23)], ["causeway", W(26, 15.5)]]

func intro_text() -> String:
	return "Gulls wheel over the strand. Past the ruins, the old sanctum floods with every tide."

## open sky: the camera never meets a ceiling
func zone_h(_zone: String) -> float:
	return 80.0

func victory_title() -> String:
	return "Ondrak the Brinewarden is defeated"

func loot_lines() -> Array:
	return ["You lift the lid of the Brinewarden's coffer: a Tidecrown Circlet, a Pearl of Still Water and 22 silver.",
		"Loot: Tidecrown Circlet, Pearl of Still Water, 22 silver"]

func cart_starts() -> Array:
	return []

func enemy_defs() -> Dictionary:
	return CoastData.ENEMIES

func boss_script(boss: String, sim) -> Object:
	return CoastBoss.new(sim) if boss == "ondrak" else null

func tick(sim, dt: float) -> void:
	CoastBoss.tick_tide(sim, dt)

# ------------------------------------------------------------------ ground height (visual only; the sim is flat)
const SANCTUM_FLOOR := -0.7
const POOL_FLOOR := -0.5
const PLINTH_TOP := 0.6
const WATER_SANCTUM := -0.25 # the resting tide inside the sanctum; the boss raises it
const WATER_POOL := -0.15
const SEA_LEVEL := -0.6

## Height of the walkable ground at a point: 0 on sand and stone, below the water line in the
## sanctum and the tide pools, raised on the sanctum plinths. Units, telegraphs and effects use it.
func floor_y(wx: float, wz: float) -> float:
	var x := floori(wx / T)
	var z := floori(wz / T)
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return 0.0
	if zone_of[z * gw + x] == "sanctum":
		var best := SANCTUM_FLOOR
		for pl in PLINTHS:
			var d := Vector2(wx, wz).distance_to(Vector2(pl[0] * T, pl[1] * T))
			# the plinth top, then a two-step ramp down into the water
			best = maxf(best, lerpf(PLINTH_TOP, SANCTUM_FLOOR, smoothstep(pl[2], pl[2] + 2.2, d)))
		# the threshold by the causeway climbs out of the water
		return lerpf(best, 0.0, smoothstep(15.2 * T, 16.4 * T, wx))
	# tide pools: a soft dip per shallow cell
	var h := 0.0
	var fx := wx / T - 0.5
	var fz := wz / T - 0.5
	var x0 := floori(fx)
	var z0 := floori(fz)
	var tx := smoothstep(0.0, 1.0, fx - x0)
	var tz := smoothstep(0.0, 1.0, fz - z0)
	var a := _pool(x0, z0)
	var b := _pool(x0 + 1, z0)
	var c := _pool(x0, z0 + 1)
	var d2 := _pool(x0 + 1, z0 + 1)
	h = lerpf(lerpf(a, b, tx), lerpf(c, d2, tx), tz)
	return h

func _pool(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= gw or z >= gh:
		return 0.0
	return POOL_FLOOR if kind[z * gw + x] == "shallow" and zone_of[z * gw + x] != "sanctum" else 0.0
