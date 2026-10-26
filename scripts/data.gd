class_name D
## Saltrock Mines: classes, abilities, enemies and spawn tables. Shared by server and client.

const MELEE := 3.4
const MAX_PLAYERS := 5
const TICK := 30 # sim and snapshot rate (Hz)

const CLASS_ORDER := ["sellsword", "cleric", "mage"]

# Souls-style actions for player-controlled units (see Sim.player_act). Stamina gates every one of them:
# an action needs stamina above zero, then spends its cost (it can drain you to zero mid-combo).
const STAMINA := 100.0
const STAM_REGEN := 34.0 # per second, once STAM_DELAY has passed since the last spend
const STAM_DELAY := 0.75
const STAM_BLOCK_REGEN := 0.35 # regen multiplier while holding block
const SPRINT_DRAIN := 14.0 # per second while sprinting and moving
const SPRINT_K := 1.45 # sprint speed multiplier
const BLOCK_SPEED_K := 0.55
const ACTS := {
	# cost, lock = seconds before the next action or free movement, hit = when the blow lands, dmg = x weapon roll
	# move = how fast you can keep walking through it (basic attacks never root you)
	"light": { "cost": 18.0, "lock": 0.62, "hit": 0.26, "dmg": 0.7, "arc": 1.1, "reach": 1.4, "move": 0.85 },
	"heavy": { "cost": 30.0, "lock": 1.05, "hit": 0.55, "dmg": 1.6, "arc": 1.35, "reach": 1.9, "stagger": 0.7, "move": 0.6 },
	"roll": { "cost": 18.0, "lock": 0.55, "dist": 5.0, "iframe": 0.42 },
	"backstep": { "cost": 12.0, "lock": 0.36, "dist": 2.6, "iframe": 0.22 },
	"parry": { "cost": 14.0, "lock": 0.6, "window": 0.28, "move": 0.5 },
}
# casters throw a bolt instead of swinging: light is quick, heavy is a charged blast
const BOLT := { "light": { "dmg": [14, 19], "speed": 30.0, "size": 0.35 }, "heavy": { "dmg": [34, 44], "speed": 24.0, "size": 0.6 } }
const AIM_RANGE := 30.0

const CLASSES := {
	"sellsword": { "name": "Bram Ironside", "short": "Bram", "title": "Sellsword", "role": "Tank", "res": "rage", "hp": 330, "armor": 260, "speed": 7.4,
		"melee": true, "swing": 2.0, "dmg": [14, 20], "guard": 0.85, "color": Color("#c8483a"),
		"blurb": "Holds the boss and takes the hits. Builds rage by fighting." },
	"cleric": { "name": "Brother Tamsin", "short": "Tamsin", "title": "Cleric", "role": "Healer", "res": "mana", "hp": 230, "armor": 140, "speed": 7.2,
		"melee": true, "swing": 2.2, "dmg": [10, 14], "guard": 0.75, "mana": 340, "color": Color("#e8d48a"),
		"blurb": "Keeps everyone standing. Heals your friendly target, or whoever is hurt worst." },
	"mage": { "name": "Ilsa Brightwick", "short": "Ilsa", "title": "Mage", "role": "Damage", "res": "mana", "hp": 200, "armor": 60, "speed": 7.2,
		"melee": false, "swing": 2.0, "dmg": [6, 9], "guard": 0.5, "mana": 380, "color": Color("#8ab4ff"),
		"blurb": "Frost and fire from range. Stand still to cast. Blink out of trouble." },
}

# target: enemy | ally | self | none. ranges in world units (one floor tile is 4)
const ABILITIES := {
	"sellsword": [
		{ "id": "hack", "name": "Hack", "cost": 15, "cd": 0.0, "cast": 0.0, "target": "enemy", "range": MELEE, "desc": "A heavy blow for 150% weapon damage. Lots of threat." },
		{ "id": "stomp", "name": "Thunderstomp", "cost": 20, "cd": 6.0, "cast": 0.0, "target": "none", "desc": "Damage and slow every enemy within 8 yards." },
		{ "id": "charge", "name": "Charge", "cost": 0, "cd": 12.0, "cast": 0.0, "target": "enemy", "range": 26.0, "min_range": 6.0, "desc": "Rush an enemy at range. Stuns it briefly and gives 20 rage." },
		{ "id": "wall", "name": "Shield Wall", "cost": 10, "cd": 25.0, "cast": 0.0, "target": "self", "desc": "Take 50% less damage for 6 seconds." },
		{ "id": "roar", "name": "Rallying Roar", "cost": 0, "cd": 14.0, "cast": 0.0, "target": "none", "desc": "Every nearby enemy turns on you. Gives 15 rage." },
	],
	"cleric": [
		{ "id": "smite", "name": "Smite", "cost": 10, "cd": 0.0, "cast": 1.8, "target": "enemy", "range": 30.0, "desc": "Holy damage to your enemy target." },
		{ "id": "mend", "name": "Mend", "cost": 18, "cd": 0.0, "cast": 1.5, "target": "ally", "range": 32.0, "desc": "A strong heal on your friendly target, or whoever is hurt worst." },
		{ "id": "renew", "name": "Renew", "cost": 12, "cd": 0.0, "cast": 0.0, "target": "ally", "range": 32.0, "desc": "Heals over 8 seconds. Instant." },
		{ "id": "ward", "name": "Holy Ward", "cost": 20, "cd": 9.0, "cast": 0.0, "target": "ally", "range": 32.0, "desc": "A shield that absorbs damage for 15 seconds." },
		{ "id": "prayer", "name": "Prayer of Light", "cost": 45, "cd": 24.0, "cast": 2.0, "target": "none", "desc": "Heals the whole party." },
	],
	"mage": [
		{ "id": "frost", "name": "Frostbolt", "cost": 12, "cd": 0.0, "cast": 1.6, "target": "enemy", "range": 30.0, "desc": "Cold damage that slows the target." },
		{ "id": "fire", "name": "Fireball", "cost": 22, "cd": 0.0, "cast": 2.4, "target": "enemy", "range": 30.0, "desc": "Big fire damage, then it keeps burning." },
		{ "id": "nova", "name": "Frost Nova", "cost": 15, "cd": 18.0, "cast": 0.0, "target": "none", "desc": "Freeze every enemy within 9 yards in place for 4 seconds." },
		{ "id": "blink", "name": "Blink", "cost": 10, "cd": 12.0, "cast": 0.0, "target": "self", "desc": "Teleport forward 12 yards." },
		{ "id": "meteor", "name": "Meteor", "cost": 35, "cd": 20.0, "cast": 0.0, "target": "enemy", "range": 32.0, "desc": "Calls a meteor down on your target. Hits everything near it." },
	],
}
const POTION := { "id": "potion", "name": "Healing Draught", "cost": 0, "cd": 30.0, "cast": 0.0, "target": "self", "desc": "Restore 45% of your health. Three in your pack." }

const ENEMIES := {
	"footpad": { "name": "Greymask Footpad", "body": "footpad", "lvl": 5, "hp": 210, "dmg": [9, 14], "swing": 1.8, "speed": 6.6, "r": 0.8, "armor": 80 },
	"miner": { "name": "Shackled Digger", "body": "miner", "lvl": 5, "hp": 180, "dmg": [8, 12], "swing": 2.0, "speed": 6.2, "r": 0.8, "armor": 60 },
	"taskmaster": { "name": "Greymask Taskmaster", "body": "taskmaster", "lvl": 6, "hp": 330, "dmg": [12, 18], "swing": 2.0, "speed": 6.4, "r": 0.95, "armor": 120, "elite": true },
	"bat": { "name": "Shaft Bat", "body": "bat", "lvl": 5, "hp": 55, "dmg": [3, 6], "swing": 1.2, "speed": 9.0, "r": 0.7, "armor": 0, "summon": true },
	"gorrak": { "name": "Gorrak the Overseer", "body": "gorrak", "lvl": 7, "hp": 3000, "dmg": [28, 37], "swing": 2.3, "speed": 6.2, "r": 1.8, "armor": 180, "boss": "gorrak", "aggro": 14.0 },
}

# [type, cell x, cell z, pack, facing]
const SPAWNS := [
	["footpad", 4.2, 11.2, "a1", PI], ["miner", 5.2, 10.8, "a1", PI],
	["miner", 7.3, 8.4, "a2", 2.4], ["miner", 8.0, 9.2, "a2", 3.4],
	["footpad", 12.5, 10.5, "b1", -PI / 2],
	["taskmaster", 17.4, 9.6, "c1", -PI / 2], ["miner", 16.6, 8.6, "c1", -2.0], ["miner", 16.6, 10.8, "c1", -1.2],
	["footpad", 18.5, 12.6, "c2", -2.4], ["footpad", 18.7, 7.2, "c3", -0.8],
	["miner", 25.2, 12.1, "d1", 1.2], ["miner", 26.0, 11.2, "d1", 1.6],
	["gorrak", 28.5, 6.5, "boss", PI],
]

static func ability(cls: String, id: String) -> Dictionary:
	if id == "potion":
		return POTION
	for a in ABILITIES.get(cls, []):
		if a.id == id:
			return a
	return {}

# Every ability id in a fixed order, so snapshots can send an index instead of a string.
static var _ab_ids: Array = []
static func ability_ids() -> Array:
	if _ab_ids.is_empty():
		for c in CLASS_ORDER:
			for a in ABILITIES[c]:
				_ab_ids.append(a.id)
		_ab_ids.append("potion")
	return _ab_ids

const ANIMS := ["idle", "combatIdle", "run", "walk", "back", "attack", "attack2", "smash", "cast", "release", "heal", "hit", "death", "yell", "spawn", "roll", "block"]
