class_name SUnit
extends RefCounted
## One unit in the authoritative simulation. Clients never see this object, only snapshots of it.

var id := 0
var team := "enemy" # party | enemy
var kind := "" # class id for party members, enemy type for enemies
var body := ""
var name := ""
var short := ""
var lvl := 5
var peer := 0 # owning network peer, 0 for AI and enemies
var ai := false

var pos := Vector3.ZERO
var yaw := 0.0
var home := Vector3.ZERO
var home_yaw := 0.0
var r := 0.8
var fly := 0.0

var hp := 100.0
var max_hp := 100.0
var res := 0.0
var max_res := 0.0
var res_type := ""
var armor := 0.0
var dmg := [1, 2]
var swing_t := 2.0
var speed := 7.0
var melee := true
var potions := 3

var dead := false
var buffs: Array = [] # { id, t, name, every?, tick?, hot?, dot?, src? }
var cds := {}
var gcd := 0.0
var cast := {} # { ab, t, time, dur } while casting
var swing := 0.0
var stun := 0.0
var slow := 0.0
var root := 0.0
var vuln := 0.0
var forced := 0.0
var busy := 0.0
var absorb := 0.0
var threat := {} # unit id -> amount
var moving := false
var target: SUnit = null
var auto_attack := false
var engaged := false
var in_combat_t := 0.0
var pack := ""
var boss := ""
var elite := false
var summon := false
var ttl := -1.0
var aggro_r := 11.0
var charging := {}
var driven := false # server is moving this player (charge, knockback): the client follows
var tp_seq := 0 # bumped whenever the server moves a player itself, so the client snaps

# steering
var path: Array = []
var path_t := 0.0
var path_goal := Vector3.INF
var force_path := 0.0
var wc_t := 0.0
var wc_goal := Vector3.INF
var direct := true
var stall := 0.0

# animation state sent to clients
var base_anim := "idle"
var base_speed := 1.0
var act := "idle"
var act_speed := 1.0
var act_seq := 0

# boss script state
var bs := {}

func hp_pct() -> float:
	return hp / max_hp

func is_enemy() -> bool:
	return team == "enemy"

func alive() -> bool:
	return not dead

func fwd() -> Vector3:
	return Vector3(sin(yaw), 0, cos(yaw))

func face_to(p: Vector3) -> void:
	yaw = atan2(p.x - pos.x, p.z - pos.z)

func dist_to(u: SUnit) -> float:
	return Vector2(pos.x - u.pos.x, pos.z - u.pos.z).length() - r - u.r

func has_buff(bid: String) -> Dictionary:
	for b in buffs:
		if b.id == bid:
			return b
	return {}

func add_buff(b: Dictionary) -> void:
	var old := has_buff(b.id)
	if old.is_empty():
		buffs.append(b)
	else:
		old.merge(b, true)

func play(anim: String, spd := 1.0) -> void:
	act = anim
	act_speed = spd
	act_seq += 1

func set_base(anim: String, spd := 1.0) -> void:
	base_anim = anim
	base_speed = spd
