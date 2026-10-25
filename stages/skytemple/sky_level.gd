class_name SkyLevel
extends Level
## Skyroot Spire: a giant-tree climb from a forest glade up to an open-air temple above the canopy.
## Same 4 m grid as Level (x east, z south). Walkways never overlap in plan view, so collision stays 2D
## and floor_y(x, z) is a plain function of position.
##
## Route, south to north: Rootfloor Glade (0 m) > Rootstair (a giant root, up to 10 m) > Fungus Shelf (10 m)
## > Elder Bough (up to 20 m) > Canopy Deck (20 m) > Skybridge (up to 30 m) > Drifting Isles (30 m)
## > Cloudsteps (up to 42 m) > Temple of the Open Sky (42 m, the boss).

const SKY_W := 48
const SKY_H := 64
const SKY_ZONES := { "glade": "Rootfloor Glade", "rootstair": "The Rootstair", "shelf": "Fungus Shelf", "bough": "Elder Bough",
	"canopy": "Canopy Deck", "skybridge": "The Skybridge", "isles": "Drifting Isles", "steps": "Cloudsteps", "temple": "Temple of the Open Sky" }

## Giant trees: [cell x, cell z, trunk radius in metres, height]. The Elder Spire grows through the middle of the
## Canopy Deck; the Shelfwood carries the Fungus Shelf; the Old Sentinel stands beside the route for scale.
const ELDER := [35.5, 28.5, 8.0, 64.0]
const SHELFWOOD := [43.2, 53.5, 10.0, 48.0]
const SENTINEL := [21.0, 40.0, 13.0, 76.0]

## Platforms: { zone, x0, z0, x1, z1, h, chamfer, kind }. Ramps: { zone, x0, z0, x1, z1, h0, h1, axis, kind, step }.
## axis is the direction the ramp climbs: "+x", "-x", "+z" or "-z". step > 0 quantises the height (stairs).
## Forest-tinted versions of the shared character models for this stage's enemies.
const BODIES := {
	"sky_thornling": { "model": "res://assets/chars/Rogue_Hooded.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.0,
		"tint": Color("#8fd17a"), "gear": [["handslot.r", "res://assets/props/p_Sword_Bronze.glb", { "scale": 1.4 }]] },
	"sky_warden": { "model": "res://assets/chars/Ranger.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.05,
		"tint": Color("#d6b07a"), "gear": [["handslot.r", "res://assets/props/q_axe.glb", { "scale": 1.6, "rot": Vector3(0, PI / 2, 0) }]] },
	"sky_mossback": { "model": "res://assets/chars/Barbarian.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.3,
		"tint": Color("#9fd07a"), "gear": [["handslot.r", "res://assets/props/k_axe.glb", { "scale": 1.3 }]] },
	"sky_wisp": { "model": "res://assets/chars/bat.glb", "alias": Assets.BAT_ALIAS, "scale": 0.42, "tint": Color("#c8f4ff") },
	"sky_hollowbark": { "model": "res://assets/chars/orc_brute.glb", "alias": Assets.QUAT_ALIAS, "scale": 1.85, "tint": Color("#c79a6a"), "height": 4.4 },
}

var platforms: Array = []
var ramps: Array = []

func _configure() -> void:
	stage_id = "skytemple"
	gw = SKY_W
	gh = SKY_H
	zone_names = SKY_ZONES
	arena_zones = ["temple"]
	cam_far = 700.0
	Assets.extra_bodies.merge(BODIES, true)
	rng.seed = 4242

func _layout() -> void:
	platform("glade", 5, 51, 17, 62, 0.0, 2, "glade")
	ramp("rootstair", 18, 54, 29, 56, 0.0, 10.0, "+x", "root")
	platform("shelf", 30, 48, 40, 59, 10.0, 2, "fungus")
	ramp("bough", 34, 35, 36, 47, 10.0, 20.0, "-z", "bough")
	platform("canopy", 29, 22, 41, 34, 20.0, 2, "deck")
	ramp("skybridge", 16, 23, 28, 25, 20.0, 30.0, "-x", "rope")
	platform("isles", 4, 17, 15, 30, 30.0, 2, "isle")
	ramp("steps", 7, 11, 9, 16, 30.0, 42.0, "-z", "steps", 1.0)
	platform("temple", 1, 0, 15, 10, 42.0, 3, "temple")
	for t in [ELDER, SHELFWOOD]:
		var c := W(t[0] - 0.5, t[1] - 0.5)
		obst.append([c.x, c.z, t[2] + 0.4])
	_sky_decorate()

## Open sky: no ceiling anywhere.
func zone_h(_zone: String) -> float:
	return 200.0

func platform(zone: String, x0: int, z0: int, x1: int, z1: int, h: float, chamfer: int, kind: String) -> void:
	platforms.append({ "zone": zone, "x0": x0, "z0": z0, "x1": x1, "z1": z1, "h": h, "chamfer": chamfer, "kind": kind })
	rects.append([x0, z0, x1, z1, zone])
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			# cut the corners into a rough octagon: |dx| + |dz| from the nearest corner below chamfer is solid
			var cx := mini(x - x0, x1 - x)
			var cz := mini(z - z0, z1 - z)
			if cx + cz < chamfer:
				continue
			grid[z * gw + x] = 1
			zone_of[z * gw + x] = zone

func ramp(zone: String, x0: int, z0: int, x1: int, z1: int, h0: float, h1: float, axis: String, kind: String, step := 0.0) -> void:
	ramps.append({ "zone": zone, "x0": x0, "z0": z0, "x1": x1, "z1": z1, "h0": h0, "h1": h1, "axis": axis, "kind": kind, "step": step })
	rects.append([x0, z0, x1, z1, zone])
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			grid[z * gw + x] = 1
			zone_of[z * gw + x] = zone

## 0..1 along a ramp's climb at a world position.
static func ramp_t(r: Dictionary, wx: float, wz: float) -> float:
	var t := 0.0
	match r.axis:
		"+x": t = (wx - r.x0 * T) / ((r.x1 + 1 - r.x0) * T)
		"-x": t = ((r.x1 + 1) * T - wx) / ((r.x1 + 1 - r.x0) * T)
		"+z": t = (wz - r.z0 * T) / ((r.z1 + 1 - r.z0) * T)
		"-z": t = ((r.z1 + 1) * T - wz) / ((r.z1 + 1 - r.z0) * T)
	return clampf(t, 0.0, 1.0)

static func ramp_h(r: Dictionary, t: float) -> float:
	var h := lerpf(r.h0, r.h1, t)
	if r.step > 0.0:
		h = r.h0 + floorf((h - r.h0) / r.step + 0.5) * r.step
	return h

## Floor height at a world position (0 off the walkways: the forest floor).
func floor_y(wx: float, wz: float) -> float:
	var zn := zone_at(wx, wz)
	if zn == "":
		return 0.0
	for p in platforms:
		if p.zone == zn:
			return p.h
	for r in ramps:
		if r.zone == zn:
			return ramp_h(r, ramp_t(r, wx, wz))
	return 0.0

func plat(zone: String) -> Dictionary:
	for p in platforms:
		if p.zone == zone:
			return p
	return {}

## A platform's outline in world space (x, z), corners cut by its chamfer, counter-clockwise from the north-west.
static func outline(p: Dictionary) -> PackedVector2Array:
	var x0: float = p.x0 * T
	var z0: float = p.z0 * T
	var x1: float = (p.x1 + 1) * T
	var z1: float = (p.z1 + 1) * T
	var c: float = p.chamfer * T
	return PackedVector2Array([Vector2(x0 + c, z0), Vector2(x1 - c, z0), Vector2(x1, z0 + c), Vector2(x1, z1 - c),
		Vector2(x1 - c, z1), Vector2(x0 + c, z1), Vector2(x0, z1 - c), Vector2(x0, z0 + c)])

# ------------------------------------------------------------------ dressing with gameplay footprints
func _solid(kind: String, model: String, p: Vector3, rot: float, s, r: float, extra := {}) -> void:
	p.y = floor_y(p.x, p.z)
	_add(kind, model, p, rot, s, extra)
	if r > 0:
		obst.append([p.x, p.z, r])

func _sky_decorate() -> void:
	# glade: a few young trees, mushrooms and boulders around the edges, a campfire where the party starts
	for t in [[6.5, 53.5, 1.0], [15.8, 53.0, 1.2], [6.2, 60.5, 0.9], [16.2, 60.8, 1.1], [9.0, 51.8, 0.8], [14.0, 61.6, 0.8]]:
		_solid("tree", "", W(t[0], t[1]), rng.randf_range(0, TAU), t[2], 1.6 * t[2])
	for m in [[7.5, 56.0], [12.0, 52.5], [16.0, 57.5], [8.5, 61.0]]:
		_solid("mushroom", "", W(m[0], m[1]), rng.randf_range(0, TAU), rng.randf_range(1.2, 1.8), 0.9)
	_solid("prop", "q_campfire", W(11, 59.5), 0.0, 2.0, 1.0, { "fire": true })
	for r in [[6, 57], [16.5, 55.5], [11.0, 62.3]]:
		_solid("prop", "q_rock_large", W(r[0], r[1]), rng.randf_range(0, TAU), 2.4, 1.2)
	# fungus shelf: glowing caps and a lost supply cache
	for m in [[32, 50.5], [38.5, 51], [38.8, 57.5], [31.5, 57.5]]:
		_solid("mushroom", "", W(m[0], m[1]), rng.randf_range(0, TAU), rng.randf_range(1.6, 2.2), 1.1, { "glow": true })
	_solid("prop", "p_Crate_Wooden", W(39, 54) + Vector3(1, 0, 0), 0.3, 1.7, 0.9)
	_solid("prop", "p_Barrel", W(39, 55.2) + Vector3(1, 0, 0), 0.0, 1.7, 0.8)
	# canopy deck: a lookout hut, lanterns, crates and ropes
	_solid("hut", "", W(38.5, 24.5), PI * 0.8, 1.0, 3.4)
	_solid("prop", "p_Crate_Wooden", W(31.5, 31.5), 0.4, 1.7, 0.9)
	_solid("prop", "p_Crate_Wooden", W(32.3, 32.0), 1.1, 1.5, 0.9)
	_solid("prop", "p_Barrel", W(39.5, 31.5), 0.0, 1.7, 0.8)
	_solid("prop", "p_Rope_1", W(34, 23.2), 0.4, 1.8, 0.0)
	# drifting isles: standing stones and crystals
	for s in [[6, 20, 0.0], [13.2, 20.5, 0.6], [5.5, 27.5, 1.2], [13.5, 28.2, 2.0]]:
		_solid("prop", "q_rock_tall", W(s[0], s[1]), s[2], 2.6, 1.3)
	for c in [[9.5, 19.2], [7.2, 24.0], [12.8, 24.8]]:
		_solid("prop", "q_crystal", W(c[0], c[1]), rng.randf_range(0, TAU), 2.2, 0.9, { "glow": true })
	# temple: a ring of columns and the wind altar in the middle
	var tc := Vector3(8.5 * T, 0, 5.5 * T)
	for i in 10:
		var a := TAU * i / 10.0 + 0.31
		var p := tc + Vector3(cos(a) * 21.0, 0, sin(a) * 18.0)
		if p.z > 9.6 * T and absf(p.x - 8.5 * T) < 10.0:
			continue # leave the stair landing open
		_solid("column", "", p, a, 1.0, 1.2)
	_solid("altar", "", tc + Vector3(0, 0, -6.5), 0.0, 1.0, 2.2)

# ------------------------------------------------------------------ stage hooks
const ENEMIES := {
	"thornling": { "name": "Thornling Skulker", "body": "sky_thornling", "lvl": 5, "hp": 190, "dmg": [9, 13], "swing": 1.8, "speed": 6.8, "r": 0.8, "armor": 70 },
	"warden": { "name": "Bramble Warden", "body": "sky_warden", "lvl": 6, "hp": 240, "dmg": [10, 15], "swing": 2.0, "speed": 6.2, "r": 0.85, "armor": 110 },
	"mossback": { "name": "Mossback Brute", "body": "sky_mossback", "lvl": 6, "hp": 430, "dmg": [14, 20], "swing": 2.2, "speed": 6.0, "r": 1.2, "armor": 140, "elite": true },
	"wisp": { "name": "Gale Wisp", "body": "sky_wisp", "lvl": 5, "hp": 75, "dmg": [4, 7], "swing": 1.3, "speed": 9.5, "r": 0.7, "armor": 0, "fly": 3.0 },
	"wisp_add": { "name": "Gale Wisp", "body": "sky_wisp", "lvl": 5, "hp": 60, "dmg": [4, 7], "swing": 1.3, "speed": 9.5, "r": 0.7, "armor": 0, "fly": 3.0, "summon": true },
	"hollowbark": { "name": "Hollowbark, the Temple Warden", "body": "sky_hollowbark", "lvl": 7, "hp": 3200, "dmg": [26, 35], "swing": 2.4, "speed": 6.0,
		"r": 1.8, "armor": 180, "boss": "hollowbark", "aggro": 15.0 },
}

func enemy_defs() -> Dictionary:
	return ENEMIES

# [type, cell x, cell z, pack, facing]; world position = cell * T
func spawns() -> Array:
	return [
		["thornling", 15.6, 54.6, "g1", -PI / 2], ["thornling", 15.8, 56.6, "g1", -PI / 2],
		["warden", 25.0, 55.5, "r1", -PI / 2],
		["mossback", 36.0, 52.5, "s1", PI * 0.75], ["thornling", 34.0, 51.5, "s1", PI], ["thornling", 37.6, 54.2, "s1", -PI / 2],
		["wisp", 35.0, 42.0, "b1", 0.0], ["wisp", 36.4, 40.5, "b1", 0.0],
		["warden", 32.5, 30.5, "c1", 0.0], ["thornling", 31.2, 29.0, "c1", 0.3], ["thornling", 33.6, 29.4, "c1", -0.3],
		["mossback", 39.0, 25.5, "c2", 0.6],
		["wisp", 22.5, 24.0, "k1", PI / 2], ["wisp", 21.0, 25.0, "k1", PI / 2],
		["mossback", 9.5, 25.0, "i1", PI / 2], ["warden", 11.0, 23.6, "i1", PI / 2],
		["thornling", 8.0, 19.5, "i2", 0.0], ["thornling", 9.6, 19.8, "i2", 0.0],
		["hollowbark", 8.5, 4.2, "boss", 0.0],
	]

func start_spots() -> Array:
	return [Vector2(11.0, 58.6), Vector2(12.0, 59.2), Vector2(10.2, 59.4), Vector2(11.8, 58.0), Vector2(11.0, 60.0)]

func start_point() -> Vector3:
	return W(10.5, 58.5)

func checkpoints() -> Array:
	return [["shelf", W(32, 55)], ["canopy", W(34, 33)], ["isles", W(13, 27)], ["steps", W(8, 16)]]

func intro_text() -> String:
	return "Sunlight pours through the leaves. Far above, the Temple of the Open Sky floats on the wind."

func boss_script(boss: String, sim) -> Object:
	if boss == "hollowbark":
		return HollowbarkFight.new(sim)
	return null
