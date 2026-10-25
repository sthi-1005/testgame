class_name Sim
extends RefCounted
## The authoritative game simulation: units, combat, abilities, enemy and party AI, the Gorrak fight.
## Only the server runs it (in solo play the local game is the server). Clients get snapshots and events.

const SNAP_STRIDE := 22
const BASE_IDX := { "idle": 0, "combatIdle": 1, "run": 2, "walk": 3, "back": 4, "cast": 8 }

var lv: Level
var units: Array[SUnit] = []
var by_id := {}
var party: Array[SUnit] = []
var enemies: Array[SUnit] = []
var players := {} # peer id -> SUnit
var uid := 0
var game_time := 0.0
var in_combat := false
var combat_t := 99.0
var active_boss: SUnit = null
var state := "lobby" # lobby | play | wipe | victory
var state_t := 0.0
var events: Array = [] # broadcast to every client at the end of the tick
var private_events := {} # peer id -> Array, sent to one client only
var teles: Array = []
var tele_id := 0
var projs: Array = []
var proj_id := 0
var timers: Array = []
var carts: Array = [] # { x, z, vx, hit, obst }
var bell_swing := 0.0
var once := {}
var checkpoint := Vector3.ZERO
var checkpoint_i := -1 # index into lv.checkpoints() of the furthest one reached
var loot_open := false
var stats := { "dmg": {}, "heal": {}, "deaths": 0, "start": 0.0 }
var boss_scripts := {} # boss id -> stage boss script (stages/boss_script.gd); Gorrak has none
var stage_vals := [0.0, 0.0, 0.0] # snapshot header slots 2-4 for stages without carts: free for set pieces

func _init(level: Level) -> void:
	lv = level
	checkpoint = lv.start_point()

# ------------------------------------------------------------------ setup
func start(roster: Array) -> void:
	## roster: [[peer, class], ...] for the human players
	state = "play"
	for s in lv.spawns():
		spawn_enemy(s[0], s[1], s[2], s[3], s[4])
	var taken := {}
	var i := 0
	for p in roster:
		var u := spawn_member(p[1], _start_spot(i), p[0])
		players[p[0]] = u
		taken[p[1]] = true
		i += 1
	for c in D.CLASS_ORDER:
		if not taken.has(c) and party.size() < D.MAX_PLAYERS:
			spawn_member(c, _start_spot(i), 0)
			i += 1
	for p in lv.cart_starts():
		var o := [p.x, p.z, 1.5]
		lv.dyn_obst.append(o)
		carts.append({ "x": p.x, "z": p.z, "vx": 0.0, "hit": false, "obst": o })
	stats.start = game_time
	ev(["state", "play"])
	chat(lv.intro_text(), "sys")

func _start_spot(i: int) -> Vector3:
	var spots := lv.start_spots()
	var s: Vector2 = spots[i % spots.size()]
	return Vector3(s.x * Level.T, 0, s.y * Level.T)

func _new_unit() -> SUnit:
	var u := SUnit.new()
	uid += 1
	u.id = uid
	units.append(u)
	by_id[u.id] = u
	return u

func spawn_info(u: SUnit) -> Dictionary:
	return { "id": u.id, "team": u.team, "kind": u.kind, "body": u.body, "name": u.name, "short": u.short, "lvl": u.lvl, "elite": u.elite,
		"boss": u.boss, "summon": u.summon, "r": u.r, "fly": u.fly, "peer": u.peer, "max_hp": u.max_hp, "res_type": u.res_type }

func spawn_enemy(type: String, cx: float, cz: float, pack: String, yaw := 0.0) -> SUnit:
	var d := lv.enemy_def(type)
	var u := _new_unit()
	u.team = "enemy"
	u.kind = type
	u.body = d.body
	u.name = d.name
	u.lvl = d.lvl
	u.pos = Vector3(cx * Level.T, 0, cz * Level.T)
	u.home = u.pos
	u.yaw = yaw
	u.home_yaw = yaw
	u.hp = d.hp
	u.max_hp = d.hp
	u.r = d.r
	u.speed = d.speed
	u.armor = d.get("armor", 0)
	u.dmg = d.dmg
	u.swing_t = d.swing
	u.pack = pack
	u.boss = d.get("boss", "")
	u.elite = d.get("elite", false)
	u.summon = d.get("summon", false)
	u.aggro_r = d.get("aggro", 11.0)
	u.fly = d.get("fly", 2.4 if type == "bat" else 0.0)
	enemies.append(u)
	ev(["spawn", spawn_info(u)])
	return u

func spawn_member(cls: String, p: Vector3, peer: int) -> SUnit:
	var c: Dictionary = D.CLASSES[cls]
	var u := _new_unit()
	u.team = "party"
	u.kind = cls
	u.body = cls
	u.name = c.name
	u.short = c.short
	u.peer = peer
	u.ai = peer == 0
	if peer != 0:
		u.name = "%s" % c.name
	u.pos = p
	u.yaw = PI # facing north, into the mine
	u.hp = c.hp
	u.max_hp = c.hp
	u.r = 0.75
	u.speed = c.speed
	u.armor = c.armor
	u.dmg = c.dmg
	u.swing_t = c.swing
	u.res_type = c.res
	u.max_res = 100.0 if c.res == "rage" else float(c.mana)
	u.res = 0.0 if c.res == "rage" else u.max_res
	u.melee = c.melee
	for a in D.ABILITIES[cls]:
		u.cds[a.id] = 0.0
	u.cds["potion"] = 0.0
	party.append(u)
	ev(["spawn", spawn_info(u)])
	return u

func remove_unit(u: SUnit) -> void:
	units.erase(u)
	by_id.erase(u.id)
	enemies.erase(u)
	party.erase(u)
	ev(["despawn", u.id])

## A player joined mid-run: take over the AI of the same class if there is one.
func add_player(peer: int, cls: String) -> SUnit:
	if players.has(peer):
		return players[peer]
	var leader := leader_unit()
	var at := leader.pos + Vector3(1.5, 0, 1.5) if leader else checkpoint
	for m in party:
		if m.ai and m.kind == cls:
			at = m.pos
			remove_unit(m)
			break
	var u := spawn_member(cls, at, peer)
	players[peer] = u
	chat("%s joins the party." % u.short, "sys")
	return u

func drop_player(peer: int) -> void:
	if not players.has(peer):
		return
	var u: SUnit = players[peer]
	players.erase(peer)
	u.peer = 0
	u.ai = true
	chat("%s's player left. %s fights on." % [u.short, u.short], "sys")

func leader_unit() -> SUnit:
	var best: SUnit = null
	for p in players.keys():
		var u: SUnit = players[p]
		if best == null or (u.alive() and not best.alive()) or (u.alive() == best.alive() and u.peer < best.peer):
			best = u
	if best:
		return best
	return party[0] if party.size() else null

# ------------------------------------------------------------------ events
func ev(e: Array) -> void:
	events.append(e)

func private_ev(peer: int, e: Array) -> void:
	if peer == 0:
		return
	if not private_events.has(peer):
		private_events[peer] = []
	private_events[peer].append(e)

func chat(text: String, style := "sys") -> void:
	ev(["chat", text, style])

func yell(u: SUnit, text: String) -> void:
	ev(["yell", u.id, text])

func say(u: SUnit, text: String) -> void:
	if u:
		ev(["say", u.id, text])

func emote(text: String) -> void:
	ev(["emote", text])

func fx(kind: String, p: Vector3, a = null) -> void:
	ev(["fx", kind, p, a])

func sfx(name: String, p := Vector3.INF) -> void:
	ev(["sfx", name, p])

func float_text(t: SUnit, text: String, style: String) -> void:
	ev(["float", t.id, text, style])

func shake(amount: float, who: SUnit = null) -> void:
	ev(["shake", amount, who.id if who else 0])

func later(t: float, fn: Callable) -> void:
	timers.append([t, fn])

# ------------------------------------------------------------------ combat core
func mitigate(t: SUnit, amt: float) -> float:
	return amt * (1.0 - t.armor / (t.armor + 500.0))

func hostile(a: SUnit, b: SUnit) -> bool:
	return a != null and b != null and a.team != b.team

func roll_weapon(u: SUnit) -> float:
	return randf_range(u.dmg[0], u.dmg[1])

func deal_damage(src: SUnit, t: SUnit, amt: float, o := {}) -> float:
	if t == null or t.dead:
		return 0.0
	var a := mitigate(t, amt) if o.get("phys", true) else amt
	var crit: bool = o.get("can_crit", true) and randf() < o.get("crit", 0.08)
	if crit:
		a *= 1.6
	if not t.has_buff("wall").is_empty():
		a *= 0.5
	if t.vuln > 0:
		a *= 1.5
	a = maxf(1.0, roundf(a))
	if t.absorb > 0:
		var ab := minf(t.absorb, a)
		t.absorb -= ab
		a -= ab
		if ab > 0 and a == 0:
			float_text(t, "Absorbed", "abs")
		if t.absorb <= 0:
			var w := t.has_buff("ward")
			if not w.is_empty():
				w.t = 0.0
	t.hp -= a
	if src and src.team == "party" and src.peer:
		stats.dmg[src.peer] = stats.dmg.get(src.peer, 0.0) + a
	if a > 0:
		var style := "dmgIn" if t.team == "party" else ("crit" if crit else "dmg")
		float_text(t, ("%d!" % a) if crit else ("%d" % a), style)
	if src and t.is_enemy():
		add_threat(t, src, a * o.get("threat", 1.0) * (1.6 if src.kind == "sellsword" else 1.0))
		engage(t, src)
	if src and not t.is_enemy() and src.is_enemy():
		engage(src, t)
	if t.peer and a > t.max_hp * 0.06:
		shake(0.25, t)
	if t.kind == "sellsword" and t.team == "party":
		t.res = minf(100.0, t.res + a * 0.35)
	if src and src.kind == "sellsword" and src.team == "party" and o.get("rage", true):
		src.res = minf(100.0, src.res + a * 0.12)
	if t.hp <= 0:
		kill(t, src)
	elif a > t.max_hp * 0.04 and t.cast.is_empty() and t.boss == "" and randf() < 0.5:
		t.play("hit", 1.4)
	return a

func heal(src: SUnit, t: SUnit, amt: float) -> float:
	if t == null or t.dead:
		return 0.0
	var a := roundf(amt * (1.5 if randf() < 0.08 else 1.0))
	var real := minf(a, t.max_hp - t.hp)
	t.hp += real
	if src and src.peer:
		stats.heal[src.peer] = stats.heal.get(src.peer, 0.0) + real
	float_text(t, "+%d" % a, "heal")
	for e in enemies:
		if e.alive() and e.threat.has(t.id):
			add_threat(e, src, real * 0.45)
	return real

func add_threat(e: SUnit, src: SUnit, amt: float) -> void:
	if src == null or src.team != "party":
		return
	e.threat[src.id] = e.threat.get(src.id, 0.0) + amt

func engage(e: SUnit, src: SUnit) -> void:
	if not e.is_enemy() or e.dead:
		return
	if e.engaged:
		return
	e.engaged = true
	e.in_combat_t = 0.0
	if src:
		add_threat(e, src, 5)
	if e.boss != "":
		start_boss(e)
	# the whole pack joins
	for o in enemies:
		if o != e and not o.engaged and o.alive() and o.pack == e.pack:
			o.engaged = true
			add_threat(o, src if src else leader_unit(), 3)
	if not once.has("firstpull"):
		once["firstpull"] = true
		var m := ai_of("mage")
		if m:
			later(0.7, func(): say(m, "I'll stay behind you. Mostly."))

func kill(t: SUnit, src: SUnit) -> void:
	t.hp = 0
	t.dead = true
	t.cast = {}
	t.target = null
	t.charging = {}
	t.driven = false
	t.play("death")
	if t.is_enemy():
		for p in party:
			if p.target == t:
				p.target = null
		if t.boss != "":
			boss_death(t)
		if t.summon:
			later(2.5, func(): remove_unit(t))
	else:
		stats.deaths += 1
		chat("%s has died." % t.short, "sys")
		if t.peer:
			private_ev(t.peer, ["chat", "You have died.", "sys"])
		for e in enemies:
			e.threat.erase(t.id)

# ------------------------------------------------------------------ telegraphs (ground warnings)
func tele_circle(src: SUnit, p: Vector3, r: float, dur: float, on_done: Callable, color := Color(1, 0.35, 0.1)) -> Dictionary:
	tele_id += 1
	var tl := { "id": tele_id, "kind": "circle", "src": src, "pos": p, "r": r, "t": 0.0, "dur": dur, "on_done": on_done }
	teles.append(tl)
	ev(["tele", tele_id, "circle", p, r, dur, color])
	return tl

func tele_lane(src: SUnit, from: Vector3, dir: Vector3, length: float, width: float, dur: float, on_done: Callable, color := Color(1, 0.3, 0.08)) -> Dictionary:
	tele_id += 1
	var tl := { "id": tele_id, "kind": "lane", "src": src, "from": from, "dir": dir, "len": length, "width": width, "t": 0.0, "dur": dur, "on_done": on_done }
	teles.append(tl)
	ev(["tele", tele_id, "lane", from, [dir, length, width], dur, color])
	return tl

func in_tele(tl: Dictionary, u: SUnit) -> bool:
	if tl.kind == "circle":
		return Vector2(u.pos.x - tl.pos.x, u.pos.z - tl.pos.z).length() < tl.r + u.r * 0.4
	var rel: Vector3 = u.pos - tl.from
	var along: float = rel.x * tl.dir.x + rel.z * tl.dir.z
	var side: float = absf(rel.x * tl.dir.z - rel.z * tl.dir.x)
	return along > -1 and along < tl.len + 1 and side < tl.width / 2 + u.r * 0.4

func update_teles(dt: float) -> void:
	for i in range(teles.size() - 1, -1, -1):
		var tl: Dictionary = teles[i]
		tl.t += dt
		var src: SUnit = tl.src
		if tl.t >= tl.dur or (src and src.dead):
			teles.remove_at(i)
			ev(["tele_end", tl.id])
			if not (src and src.dead):
				tl.on_done.call(tl)

func clear_teles() -> void:
	for tl in teles:
		ev(["tele_end", tl.id])
	teles.clear()

# ------------------------------------------------------------------ projectiles
func projectile(src: SUnit, tgt: SUnit, color: Color, spd: float, size: float, on_hit: Callable) -> void:
	proj_id += 1
	var start := src.pos + Vector3(0, 1.6, 0) + src.fwd() * 0.8
	projs.append({ "id": proj_id, "p": start, "tgt": tgt, "speed": spd, "on_hit": on_hit })
	ev(["proj", proj_id, src.id, tgt.id, start, color, spd, size])

func update_projs(dt: float) -> void:
	for i in range(projs.size() - 1, -1, -1):
		var pr: Dictionary = projs[i]
		var tgt: SUnit = pr.tgt
		var to: Vector3 = tgt.pos + Vector3(0, 1.3 + tgt.fly, 0) - pr.p
		var d := to.length()
		if d < 0.6 or tgt.dead:
			projs.remove_at(i)
			ev(["proj_end", pr.id, not tgt.dead])
			if not tgt.dead:
				pr.on_hit.call()
			continue
		pr.p += to * minf(1.0, pr.speed * dt / d)

# ------------------------------------------------------------------ abilities
func friendly_target_for(u: SUnit) -> SUnit:
	if u.peer and u.target and u.target.team == "party" and u.target.alive():
		return u.target
	var best: SUnit = null
	var bp := 2.0
	for m in party:
		if m.alive() and m.hp_pct() < bp and _d(m.pos, u.pos) < 34:
			best = m
			bp = m.hp_pct()
	return best if bp < 1.0 else u

func _d(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

## Returns an error string, "" when the ability can be used, or "gcd".
func can_use(u: SUnit, ab: Dictionary, t: SUnit) -> String:
	if u.dead:
		return "You are dead."
	if u.stun > 0:
		return "You are stunned."
	if u.cds.get(ab.id, 0.0) > 0:
		return "That is not ready yet."
	if ab.id != "potion" and u.gcd > 0:
		return "gcd"
	if ab.id == "potion":
		if u.potions <= 0:
			return "You are out of draughts."
		if u.hp >= u.max_hp:
			return "You are already at full health."
		return ""
	if u.res < ab.cost:
		return "Not enough rage." if u.res_type == "rage" else "Not enough mana."
	if not u.cast.is_empty():
		return "You are busy casting."
	if ab.cast > 0 and u.moving:
		return "Can't do that while moving."
	if ab.target == "enemy":
		if t == null or not hostile(u, t) or t.dead:
			return "You have no target."
		var d := u.dist_to(t)
		if ab.has("range") and d > ab.range:
			return "Out of range."
		if ab.has("min_range") and d < ab.min_range:
			return "Too close."
		if not lv.line_clear(u.pos, t.pos):
			return "Target not in line of sight."
	if ab.target == "ally":
		if t == null or t.dead:
			return "No one to help."
		if u.dist_to(t) > ab.range:
			return "Out of range."
	return ""

func try_use(u: SUnit, id: String, t_override: SUnit = null) -> bool:
	var ab := D.ability(u.kind, id)
	if ab.is_empty():
		return false
	var t := t_override
	if t == null:
		if ab.target == "enemy":
			t = u.target
		elif ab.target == "ally":
			t = friendly_target_for(u)
		else:
			t = u
	var err := can_use(u, ab, t)
	if err != "":
		if u.peer and err != "gcd":
			private_ev(u.peer, ["error", err])
		return false
	if ab.target == "enemy":
		u.face_to(t.pos)
		if u.peer:
			u.auto_attack = true
	if ab.cast > 0:
		u.cast = { "ab": ab, "t": t, "time": 0.0, "dur": ab.cast }
		u.play("cast")
		sfx("cast", u.pos)
	else:
		finish_ability(u, ab, t)
	u.gcd = 0.0 if ab.id == "potion" else 1.0
	return true

func end_cast(u: SUnit, done: bool) -> void:
	if u.cast.is_empty():
		return
	var c := u.cast
	u.cast = {}
	if done:
		finish_ability(u, c.ab, c.t)
	else:
		u.play("idle")
		if u.peer:
			private_ev(u.peer, ["error", "Interrupted"])

func update_cast(u: SUnit, dt: float) -> void:
	if u.cast.is_empty():
		return
	u.cast.time += dt
	if u.moving or u.stun > 0:
		end_cast(u, false)
		return
	var t: SUnit = u.cast.t
	if t and t != u and (t.dead or (u.cast.ab.target == "enemy" and not lv.line_clear(u.pos, t.pos))):
		end_cast(u, false)
		return
	if t and t != u and not u.peer:
		u.face_to(t.pos)
	if u.cast.time >= u.cast.dur:
		end_cast(u, true)

func finish_ability(u: SUnit, ab: Dictionary, t: SUnit) -> void:
	u.res -= ab.cost
	u.cds[ab.id] = ab.cd
	var wpn := roll_weapon(u)
	match ab.id:
		"potion":
			u.potions -= 1
			heal(u, u, u.max_hp * 0.45)
			fx("burst", u.pos + Vector3(0, 1.3, 0), { "color": Color(1, 0.3, 0.25), "n": 20, "speed": 2.0, "gravity": 2.0 })
			sfx("heal", u.pos)
		"hack":
			u.play("attack", 1.3)
			_swing_at(u, t, func():
				deal_damage(u, t, wpn * 1.5 + 6, { "threat": 2.4, "rage": false })
				_impact(t, Color(1, 0.9, 0.7)))
			u.swing = maxf(u.swing, 0.5)
		"stomp":
			u.play("smash", 1.4)
			later(0.35, func():
				if u.dead:
					return
				for e in enemies:
					if e.alive() and _d(e.pos, u.pos) < 8 + e.r:
						deal_damage(u, e, wpn * 0.7, { "threat": 1.8 })
						e.slow = 6.0
				fx("dust", u.pos + Vector3(0, 0.3, 0), { "n": 26, "size": 1.4 })
				fx("ring", u.pos + Vector3(0, 0.4, 0), { "color": Color(0.9, 0.8, 0.6), "r": 8.0 })
				shake(0.35, u)
				sfx("slam", u.pos))
		"charge":
			u.charging = { "t": t, "time": 0.0 }
			u.res = minf(100, u.res + 20)
			u.driven = u.peer != 0
			u.set_base("run", 1.6)
			sfx("charge", u.pos)
		"wall":
			u.add_buff({ "id": "wall", "t": 6.0, "name": "Shield Wall" })
			fx("burst", u.pos + Vector3(0, 1.3, 0), { "color": Color(0.6, 0.8, 1), "n": 30, "speed": 3.0 })
			sfx("buff", u.pos)
		"roar":
			u.play("yell", 1.2)
			u.res = minf(100, u.res + 15)
			for e in enemies:
				if e.alive() and _d(e.pos, u.pos) < 14:
					engage(e, u)
					var top := 0.0
					for v in e.threat.values():
						top = maxf(top, v)
					e.threat[u.id] = top * 1.15 + 30
					e.target = u
					e.forced = 3.0
			fx("ring", u.pos + Vector3(0, 2.5, 0), { "color": Color(1, 0.5, 0.3), "r": 14.0 })
			sfx("roar", u.pos)
		"smite":
			u.play("release", 1.3)
			fx("sky", t.pos, { "color": Color(1, 0.95, 0.6) })
			deal_damage(u, t, 30 + randf_range(0, 10), { "phys": false })
			sfx("holy", t.pos)
		"mend":
			u.play("heal", 1.4)
			heal(u, t, 95 + randf_range(0, 25))
			fx("heal", t.pos, { "k": 1.0 })
			sfx("heal", t.pos)
		"renew":
			u.play("heal", 1.6)
			t.add_buff({ "id": "renew", "t": 8.0, "tick": 1.0, "every": 1.0, "hot": 14.0, "src": u, "name": "Renew" })
			fx("heal", t.pos, { "k": 0.5 })
			sfx("heal", t.pos)
		"ward":
			t.absorb = 80
			t.add_buff({ "id": "ward", "t": 15.0, "name": "Holy Ward" })
			sfx("buff", t.pos)
		"prayer":
			u.play("heal", 1.0)
			for m in party:
				if m.alive() and _d(m.pos, u.pos) < 30:
					heal(u, m, 70 + randf_range(0, 20))
					fx("heal", m.pos, { "k": 1.0 })
			fx("ring", u.pos + Vector3(0, 1.2, 0), { "color": Color(1, 0.95, 0.6), "r": 30.0 })
			fx("flash", u.pos + Vector3(0, 1.5, 0), { "color": Color(1, 0.9, 0.6), "energy": 4.0, "dur": 0.5, "range": 22.0 })
			sfx("heal", u.pos)
		"frost":
			u.play("release", 1.4)
			projectile(u, t, Color(0.55, 0.8, 1), 26.0, 0.45, func():
				deal_damage(u, t, 34 + randf_range(0, 10), { "phys": false })
				t.slow = 5.0)
			sfx("frost", u.pos)
		"fire":
			u.play("release", 1.4)
			projectile(u, t, Color(1, 0.5, 0.15), 22.0, 0.7, func():
				deal_damage(u, t, 58 + randf_range(0, 14), { "phys": false })
				t.add_buff({ "id": "burn", "t": 6.0, "tick": 2.0, "every": 2.0, "dot": 9.0, "src": u, "name": "Burning" }))
			sfx("fire", u.pos)
		"nova":
			for e in enemies:
				if e.alive() and _d(e.pos, u.pos) < 9 + e.r:
					deal_damage(u, e, 16, { "phys": false })
					if e.boss == "":
						e.root = 4.0
					else:
						e.slow = 4.0
					fx("frost", e.pos)
			fx("ring", u.pos + Vector3(0, 0.5, 0), { "color": Color(0.6, 0.85, 1), "r": 9.0 })
			fx("flash", u.pos + Vector3(0, 1.3, 0), { "color": Color(0.5, 0.8, 1), "energy": 3.0, "dur": 0.4 })
			sfx("frost", u.pos)
		"blink":
			var f := u.fwd()
			fx("blink", u.pos + Vector3(0, 1.3, 0))
			u.pos = lv.move_circle(u.pos, f.x * 12, f.z * 12, u.r)
			u.tp_seq += 1
			fx("blink", u.pos + Vector3(0, 1.3, 0))
			u.root = 0
			sfx("blink", u.pos)
		"meteor":
			u.play("release", 1.0)
			var tp := t.pos
			tele_circle(u, tp, 7.0, 1.2, func(_tl):
				for e in enemies:
					if e.alive() and _d(e.pos, tp) < 7 + e.r:
						deal_damage(u, e, 70 + randf_range(0, 20), { "phys": false })
				fx("explode", tp, { "color": Color(1, 0.55, 0.2) })
				shake(0.5)
				sfx("boom", tp), Color(1, 0.5, 0.15))
			fx("meteor", tp, { "dur": 1.2 })
			sfx("fire", u.pos)

func _swing_at(u: SUnit, t: SUnit, fn: Callable) -> void:
	later(0.28, func():
		if not u.dead and t and not t.dead and u.dist_to(t) < D.MELEE + 1.5:
			fn.call())

func _impact(t: SUnit, color: Color) -> void:
	fx("hit", t.pos + Vector3(0, 1.3 + t.fly, 0), { "color": color })
	sfx("hit", t.pos)

# ------------------------------------------------------------------ per-unit tick: buffs, regen, melee swings
func tick_unit(u: SUnit, dt: float) -> void:
	for k in u.cds.keys():
		if u.cds[k] > 0:
			u.cds[k] = maxf(0.0, u.cds[k] - dt)
	u.gcd = maxf(0, u.gcd - dt)
	u.stun = maxf(0, u.stun - dt)
	u.slow = maxf(0, u.slow - dt)
	u.root = maxf(0, u.root - dt)
	u.forced = maxf(0, u.forced - dt)
	if u.vuln > 0:
		u.vuln -= dt
	for b in u.buffs:
		b.t -= dt
		if b.has("every"):
			b.tick -= dt
			if b.tick <= 0:
				b.tick += b.every
				if b.has("hot"):
					heal(b.src, u, b.hot)
				if b.has("dot"):
					deal_damage(b.src, u, b.dot, { "phys": false, "can_crit": false })
	var keep: Array = []
	for b in u.buffs:
		if b.t > 0 and not u.dead:
			keep.append(b)
	u.buffs = keep
	if u.has_buff("ward").is_empty() and u.absorb > 0:
		u.absorb = 0
	if u.dead:
		return
	if u.team == "party":
		if u.res_type == "mana":
			u.res = minf(u.max_res, u.res + dt * (3.6 if in_combat else 18.0))
		elif not in_combat:
			u.res = maxf(0, u.res - dt * 6)
		if not in_combat and combat_t > 3:
			u.hp = minf(u.max_hp, u.hp + dt * u.max_hp * 0.06)
	update_cast(u, dt)
	# melee auto attack
	var t: SUnit = u.target if (not u.peer or u.auto_attack) else null
	if u.swing > 0:
		u.swing -= dt
	if t and hostile(u, t) and t.alive() and u.cast.is_empty() and u.stun <= 0 and (u.is_enemy() or u.melee):
		var d := u.dist_to(t)
		var facing := absf(angle_difference(u.yaw, atan2(t.pos.x - u.pos.x, t.pos.z - u.pos.z))) < 1.4
		if d < D.MELEE and u.swing <= 0 and (facing or u.ai or u.is_enemy()):
			u.swing = u.swing_t * (1.4 if u.slow > 0 and u.is_enemy() else 1.0)
			if u.is_enemy() or u.ai:
				u.face_to(t.pos)
			var big := u.boss != "" and randf() < 0.35
			u.play("attack2" if big else "attack", 1.1 if u.boss != "" else 1.3)
			var amt := roll_weapon(u) * (0.7 if u.kind == "cleric" else 1.0)
			_swing_at(u, t, func():
				deal_damage(u, t, amt, { "threat": 1.0 })
				_impact(t, Color(1, 0.5, 0.4) if u.is_enemy() else Color(1, 0.9, 0.7))
				if u.peer:
					sfx("swing", u.pos))

# ------------------------------------------------------------------ locomotion shared by AI units
func steer(u: SUnit, goal: Vector3, dt: float, speed_k := 1.0, stop_at := 0.3) -> bool:
	if u.stun > 0 or u.root > 0:
		u.moving = false
		return true
	var tgt := goal
	u.force_path = maxf(0, u.force_path - dt)
	u.wc_t -= dt
	if u.wc_t <= 0 or u.wc_goal == Vector3.INF or _d(u.wc_goal, goal) > 1.5:
		u.wc_t = 0.25
		u.wc_goal = goal
		u.direct = lv.walk_clear(u.pos, goal, u.r * 0.9)
	if u.force_path > 0 or not u.direct:
		if u.path.is_empty() or u.path_t <= 0 or u.path_goal == Vector3.INF or _d(u.path_goal, goal) > 3:
			u.path = lv.find_path(u.pos, goal)
			u.path_goal = goal
			u.path_t = 1.0
		u.path_t -= dt
		if not u.path.is_empty():
			while u.path.size() > 1 and _d(u.pos, u.path[0]) < 0.8:
				u.path.pop_front()
			tgt = u.path[0]
	else:
		u.path = []
	var dx := tgt.x - u.pos.x
	var dz := tgt.z - u.pos.z
	var d := sqrt(dx * dx + dz * dz)
	var at_goal := tgt.is_equal_approx(goal)
	if d <= stop_at and at_goal:
		u.moving = false
		return true
	if d < 1e-4:
		u.moving = false
		return at_goal
	var sp := u.speed * speed_k * (0.55 if u.slow > 0 else 1.0) * dt
	var step := minf(sp, maxf(0.0, d - (stop_at * 0.9 if at_goal else 0.0)))
	var p := lv.move_circle(u.pos, dx / d * step, dz / d * step, u.r)
	var gain := d - Vector2(tgt.x - p.x, tgt.z - p.z).length()
	if step > 0.01 and gain < step * 0.25:
		u.stall += dt
		if u.stall > 0.35:
			u.force_path = 1.5
			u.stall = 0
			u.path = []
	else:
		u.stall = 0
	u.moving = step > 0.001
	u.pos.x = p.x
	u.pos.z = p.z
	u.yaw += angle_difference(u.yaw, atan2(dx, dz)) * minf(1.0, dt * 12)
	return false

func separate(dt: float) -> void:
	var l: Array[SUnit] = []
	for u in units:
		if u.alive() and u.fly == 0 and not u.peer:
			l.append(u)
	for i in l.size():
		for j in range(i + 1, l.size()):
			var a := l[i]
			var b := l[j]
			var dx := b.pos.x - a.pos.x
			var dz := b.pos.z - a.pos.z
			var d := sqrt(dx * dx + dz * dz)
			var m := a.r + b.r
			if d < m and d > 1e-3:
				var push := (m - d) * 0.5 * minf(1.0, dt * 10)
				var ka := 0.1 if a.boss != "" else 1.0
				var kb := 0.1 if b.boss != "" else 1.0
				var pa := lv.move_circle(a.pos, -dx / d * push * ka, -dz / d * push * ka, a.r)
				var pb := lv.move_circle(b.pos, dx / d * push * kb, dz / d * push * kb, b.r)
				a.pos.x = pa.x
				a.pos.z = pa.z
				b.pos.x = pb.x
				b.pos.z = pb.z

func anim_loco(u: SUnit, mode: String) -> void:
	if u.dead or not u.cast.is_empty():
		return
	var spd := 0.7 if u.slow > 0 else 1.0
	match mode:
		"run":
			u.set_base("run", 1.05 * spd)
		"walk":
			u.set_base("walk", 1.0)
		_:
			u.set_base("combatIdle" if in_combat and (u.engaged if u.is_enemy() else true) and u.melee else "idle")

# ------------------------------------------------------------------ enemy AI
func update_enemy(e: SUnit, dt: float) -> void:
	if e.dead:
		return
	if e.ttl >= 0:
		e.ttl -= dt
		if e.ttl <= 0:
			e.dead = true
			e.hp = 0
			fx("poof", e.pos + Vector3(0, e.fly + 0.8, 0))
			remove_unit(e)
			return
	e.in_combat_t += dt
	if not e.engaged:
		for p in party:
			if p.alive() and _d(p.pos, e.pos) < e.aggro_r and lv.line_clear(p.pos, e.pos):
				engage(e, p)
				break
		if not e.engaged:
			if _d(e.pos, e.home) > 0.5:
				steer(e, e.home, dt, 1.0)
				anim_loco(e, "run")
			else:
				e.moving = false
				e.yaw += angle_difference(e.yaw, e.home_yaw) * dt * 4
				anim_loco(e, "idle")
			return
	# pick the highest-threat living target; sticky unless someone has 10% more
	if e.forced <= 0 or e.target == null or e.target.dead:
		var best: SUnit = null
		var bt := -1.0
		for k in e.threat.keys():
			var u: SUnit = by_id.get(k)
			if u == null or u.dead:
				e.threat.erase(k)
				continue
			if e.threat[k] > bt:
				best = u
				bt = e.threat[k]
		if e.target and e.target.alive() and best != e.target and e.threat.get(e.target.id, 0.0) * 1.1 > bt:
			best = e.target
		e.target = best
	if e.target == null:
		var near: SUnit = null
		for p in party:
			if p.alive() and (near == null or _d(p.pos, e.pos) < _d(near.pos, e.pos)):
				near = p
		if near:
			e.target = near
			add_threat(e, near, 1)
		else:
			reset_enemy(e)
			return
	if e.boss != "":
		# kited out of the arena: evade and reset after a few seconds
		var any_in := false
		for p in party:
			if p.alive() and lv.zone_at(p.pos.x, p.pos.z) in lv.arena_zones:
				any_in = true
		e.bs.out_t = 0.0 if any_in else e.bs.get("out_t", 0.0) + dt
		if e.bs.out_t > 8.0:
			_evade_boss(e)
			return
		if boss_update(e, dt):
			return # the boss script owns this tick
	if e.stun > 0 or e.busy > 0:
		e.busy = maxf(0, e.busy - dt)
		e.moving = false
		anim_loco(e, "idle")
		return
	var t := e.target
	var d := e.dist_to(t)
	if d > D.MELEE * 0.8:
		var before := e.pos
		steer(e, t.pos, dt, 1.0, e.r + t.r + D.MELEE * 0.6)
		if e.boss != "" and not lv.zone_at(e.pos.x, e.pos.z) in lv.arena_zones:
			e.pos = before # bosses never leave their arena
			e.moving = false
		anim_loco(e, "run" if e.moving else "idle")
	else:
		e.moving = false
		e.yaw += angle_difference(e.yaw, atan2(t.pos.x - e.pos.x, t.pos.z - e.pos.z)) * minf(1.0, dt * 8)
		anim_loco(e, "idle")

func _evade_boss(e: SUnit) -> void:
	var bsc = _boss_script(e)
	if bsc:
		bsc.evade(e)
	else:
		yell(e, "Gorrak not chase. Gorrak WAIT.")
		emote("Gorrak stomps back to his post.")
	for b in enemies.duplicate():
		if b.summon:
			remove_unit(b)
	clear_teles()
	reset_enemy(e)
	e.pos = e.home
	e.yaw = e.home_yaw
	e.tp_seq += 1
	e.bs = {}
	e.stun = 0
	e.vuln = 0
	e.busy = 0
	e.set_base("idle")
	active_boss = null
	ev(["boss", "hide", e.id])

func reset_enemy(e: SUnit) -> void:
	e.engaged = false
	e.threat.clear()
	e.target = null
	e.hp = e.max_hp
	e.buffs = []

# ------------------------------------------------------------------ party AI
func ai_of(cls: String) -> SUnit:
	for m in party:
		if m.ai and m.kind == cls:
			return m
	return null

func engaged_enemies() -> Array[SUnit]:
	var out: Array[SUnit] = []
	for e in enemies:
		if e.alive() and e.engaged:
			out.append(e)
	return out

func danger_at(u: SUnit) -> Dictionary:
	for tl in teles:
		var src: SUnit = tl.src
		if src and src.is_enemy() and in_tele(tl, u):
			return tl
	return {}

func escape_tele(m: SUnit, tl: Dictionary, dt: float) -> void:
	var dir: Vector3
	if tl.kind == "circle":
		dir = m.pos - tl.pos
		dir.y = 0
		if dir.length() < 0.1:
			dir = Vector3(1, 0, 0)
	else:
		var side: float = (m.pos.x - tl.from.x) * tl.dir.z - (m.pos.z - tl.from.z) * tl.dir.x
		dir = Vector3(tl.dir.z, 0, -tl.dir.x) * (1.0 if side >= 0 else -1.0)
	dir = dir.normalized()
	if not m.cast.is_empty():
		end_cast(m, false)
	steer(m, m.pos + dir * 4, dt, 1.05, 0.1)
	anim_loco(m, "run")

func formation_spot(m: SUnit) -> Vector3:
	var leader := leader_unit()
	var ais: Array[SUnit] = []
	for p in party:
		if p.ai:
			ais.append(p)
	var i := ais.find(m)
	var side := -1.0 if i % 2 == 0 else 1.0
	var row := 1.6 + floorf(i / 2.0) * 2.4
	var f := leader.fwd()
	var rt := Vector3(f.z, 0, -f.x)
	return leader.pos - f * row + rt * side * 2.9

func update_ai(m: SUnit, dt: float) -> void:
	if m.dead or not m.charging.is_empty():
		return
	var tl := danger_at(m)
	if not tl.is_empty() and m.stun <= 0:
		escape_tele(m, tl, dt)
		return
	var foes := engaged_enemies()
	var leader := leader_unit()
	if foes.is_empty():
		m.target = null
		if not m.cast.is_empty() and m.cast.ab.target == "enemy":
			end_cast(m, false)
		# out of combat: heal up, then follow the leader
		if m.kind == "cleric" and m.cast.is_empty() and m.gcd <= 0:
			var hurt: SUnit = null
			for p in party:
				if p.alive() and p.hp_pct() < 0.8 and (hurt == null or p.hp_pct() < hurt.hp_pct()):
					hurt = p
			if hurt and m.res > 40:
				if _d(m.pos, hurt.pos) > 28:
					steer(m, hurt.pos, dt, 1.0, 20)
					anim_loco(m, "run")
					return
				try_use(m, "mend", hurt)
		if not m.cast.is_empty():
			m.moving = false
			return
		if leader == null or leader == m:
			m.moving = false
			anim_loco(m, "idle")
			return
		var spot := formation_spot(m)
		var d := _d(m.pos, spot)
		if d > 1.2:
			steer(m, spot, dt, 1.25 if d > 10 else 1.0, 0.6)
			anim_loco(m, "run" if d > 2.5 else "walk")
		else:
			m.moving = false
			m.yaw += angle_difference(m.yaw, leader.yaw) * dt * 3
			anim_loco(m, "idle")
		return
	match m.kind:
		"sellsword":
			ai_tank(m, dt, foes)
		"cleric":
			ai_healer(m, dt, foes)
		_:
			ai_mage(m, dt, foes)

func primary_target(foes: Array[SUnit]) -> SUnit:
	var leader := leader_unit()
	if leader and leader.target and leader.target.is_enemy() and leader.target.alive() and leader.target.engaged:
		return leader.target
	if active_boss and active_boss.alive():
		return active_boss
	var best: SUnit = null
	for f in foes:
		if best == null or f.hp < best.hp:
			best = f
	return best

func ai_tank(m: SUnit, dt: float, foes: Array[SUnit]) -> void:
	# grab anything hitting someone else, else the leader's target
	var loose: SUnit = null
	for e in foes:
		if e.target and e.target != m and e.target.alive() and e.boss == "":
			loose = e
			break
	if loose == null:
		for e in foes:
			if e.target and e.target != m and e.boss != "":
				loose = e
				break
	var t: SUnit = m.target if m.target and m.target.alive() else null
	if loose and (t == null or t.target == m):
		t = loose
	if t == null:
		t = primary_target(foes)
	m.target = t
	if t == null:
		return
	var d := m.dist_to(t)
	if m.hp_pct() < 0.35 and m.cds.wall <= 0:
		try_use(m, "wall", m)
	var near_count := 0
	var loose_count := 0
	for e in foes:
		if _d(e.pos, m.pos) < 8:
			near_count += 1
		if e.target and e.target != m and e.target.alive() and _d(e.pos, m.pos) < 14:
			loose_count += 1
	if loose_count >= 2 and m.cds.roar <= 0:
		try_use(m, "roar", m)
	if d > 7 and d < 26 and m.cds.charge <= 0 and lv.line_clear(m.pos, t.pos):
		try_use(m, "charge", t)
		return
	if d > D.MELEE * 0.85:
		steer(m, t.pos, dt, 1.0, m.r + t.r + D.MELEE * 0.55)
		anim_loco(m, "run")
		return
	m.moving = false
	m.face_to(t.pos)
	anim_loco(m, "idle")
	if near_count >= 2 and m.res >= 20 and m.cds.stomp <= 0:
		try_use(m, "stomp", m)
	elif m.res >= 35:
		try_use(m, "hack", t)

func ai_healer(m: SUnit, dt: float, foes: Array[SUnit]) -> void:
	var tank: SUnit = null
	for p in party:
		if p.kind == "sellsword" and p.alive():
			tank = p
			break
	if tank == null:
		tank = leader_unit()
	var low: Array[SUnit] = []
	for p in party:
		if p.alive():
			low.append(p)
	low.sort_custom(func(a: SUnit, b: SUnit): return a.hp_pct() < b.hp_pct())
	var worst: SUnit = low[0] if low.size() else null
	if not m.cast.is_empty():
		m.moving = false
		return
	# stay in range of the tank but back from the fight
	var anchor := tank.pos if tank and tank.alive() else m.pos
	var foe: SUnit = active_boss if active_boss and active_boss.alive() else foes[0]
	var spot := anchor
	if foe:
		var away := anchor - foe.pos
		away.y = 0
		if away.length() < 0.1:
			away = Vector3(1, 0, 0)
		spot = anchor + away.normalized() * 12
		if lv.solid_at(spot.x, spot.z, 0.8):
			spot = anchor + away.normalized() * 5
	var too_far := worst == null or m.dist_to(worst) > 28 or not lv.line_clear(m.pos, worst.pos)
	var melee_threat: SUnit = null
	for e in foes:
		if e.target == m and _d(e.pos, m.pos) < 5:
			melee_threat = e
			break
	if too_far or _d(m.pos, spot) > 9 or melee_threat:
		if not (melee_threat and worst and worst.hp_pct() < 0.5):
			var goal := spot
			if melee_threat:
				goal = m.pos + (m.pos - melee_threat.pos).normalized() * 6
			steer(m, goal, dt, 1.0, 1.5)
			anim_loco(m, "run")
			if m.moving:
				return
	m.moving = false
	anim_loco(m, "idle")
	if m.gcd > 0:
		return
	var hurt2 := 0
	for p in low:
		if p.hp_pct() < 0.55:
			hurt2 += 1
	if hurt2 >= 2 and m.cds.prayer <= 0 and m.res >= 45:
		try_use(m, "prayer", m)
		return
	if tank and tank.alive() and tank.has_buff("ward").is_empty() and m.cds.ward <= 0 and m.res > 40 and tank.hp_pct() < 0.95:
		try_use(m, "ward", tank)
		return
	if worst and worst.hp_pct() < 0.62:
		try_use(m, "mend", worst)
		return
	if tank and tank.alive() and tank.hp_pct() < 0.9 and tank.has_buff("renew").is_empty():
		try_use(m, "renew", tank)
		return
	for p in low:
		if p.hp_pct() < 0.85 and p.has_buff("renew").is_empty():
			try_use(m, "renew", p)
			return
	if m.res > m.max_res * 0.7:
		var t := primary_target(foes)
		if t and m.dist_to(t) < 28:
			m.target = t
			try_use(m, "smite", t)

func ai_mage(m: SUnit, dt: float, foes: Array[SUnit]) -> void:
	var add: SUnit = null
	for e in foes:
		if e.summon and e.target and e.target.kind != "sellsword" and _d(e.pos, m.pos) < 26:
			add = e
			break
	var t: SUnit = add if add else primary_target(foes)
	m.target = t
	if t == null:
		return
	var close: SUnit = null
	for e in foes:
		if e.target == m and _d(e.pos, m.pos) < 4.5:
			close = e
			break
	if close and m.cast.is_empty():
		if m.cds.nova <= 0:
			try_use(m, "nova", m)
			return
		if m.cds.blink <= 0:
			m.yaw = atan2(m.pos.x - close.pos.x, m.pos.z - close.pos.z)
			try_use(m, "blink", m)
			return
	if not m.cast.is_empty():
		m.moving = false
		return
	var d := m.dist_to(t)
	if d > 24 or not lv.line_clear(m.pos, t.pos):
		steer(m, t.pos, dt, 1.0, 18)
		anim_loco(m, "run")
		return
	m.moving = false
	m.face_to(t.pos)
	anim_loco(m, "idle")
	if m.gcd > 0:
		return
	var packed := 0
	for e in foes:
		if _d(e.pos, t.pos) < 7:
			packed += 1
	if packed >= 3 and m.cds.meteor <= 0 and m.res >= 35:
		try_use(m, "meteor", t)
		return
	if t.boss != "" and m.cds.meteor <= 0 and m.res >= 60:
		try_use(m, "meteor", t)
		return
	if m.res >= 22 and (t.hp > 120 or t.boss != ""):
		try_use(m, "fire", t)
		return
	try_use(m, "frost", t)

func update_charge(u: SUnit, dt: float) -> bool:
	var c := u.charging
	if c.is_empty():
		return false
	c.time += dt
	var t: SUnit = c.t
	if t == null or t.dead or c.time > 1.6:
		u.charging = {}
		u.driven = false
		return false
	u.face_to(t.pos)
	var d := _d(u.pos, t.pos)
	var step := minf(32 * dt, d - u.r - t.r - 0.6)
	if step > 0:
		u.pos = lv.move_circle(u.pos, (t.pos.x - u.pos.x) / d * step, (t.pos.z - u.pos.z) / d * step, u.r)
	u.moving = true
	if u.dist_to(t) < 1.2 or step <= 0:
		u.charging = {}
		u.driven = false
		u.moving = false
		if t.boss == "":
			t.stun = maxf(t.stun, 1.5)
		deal_damage(u, t, roll_weapon(u) * 0.5, { "threat": 2.5 })
		fx("dust", t.pos, { "n": 14, "size": 0.8 })
		shake(0.3, u)
		u.play("attack", 1.3)
		engage(t, u)
		sfx("hit", t.pos)
	return true

# ------------------------------------------------------------------ bosses
## The stage's script for this boss, or null for Gorrak (built in below).
func _boss_script(e: SUnit) -> Object:
	if e.boss == "gorrak":
		return null
	if not boss_scripts.has(e.boss):
		boss_scripts[e.boss] = lv.boss_script(e.boss, self)
	return boss_scripts[e.boss]

func start_boss(e: SUnit) -> void:
	active_boss = e
	ev(["boss", "show", e.id])
	var bsc = _boss_script(e)
	if bsc:
		bsc.pull(e)
	else:
		gorrak_pull(e)

func boss_death(e: SUnit) -> void:
	var bsc = _boss_script(e)
	if bsc:
		bsc.death(e)
	else:
		gorrak_death(e)
	active_boss = null
	ev(["boss", "hide", e.id])
	clear_teles()

func set_phase(e: SUnit, label: String) -> void:
	e.bs.phase = label
	ev(["boss", "phase", e.id, label])

func boss_update(e: SUnit, dt: float) -> bool:
	var bsc = _boss_script(e)
	if bsc:
		return bsc.update(e, dt)
	return gorrak_update(e, dt)

## The last boss is down: drop the strongbox, then show the victory screen.
func win_run(e: SUnit) -> void:
	later(1.2, func(): ev(["chest", e.pos, e.yaw + PI]))
	later(4.0, func():
		state = "victory"
		var secs: float = game_time - stats.start
		ev(["state", "victory", { "time": secs, "deaths": stats.deaths, "dmg": stats.dmg, "heal": stats.heal }]))

func gorrak_pull(e: SUnit) -> void:
	yell(e, "Gorrak smash little thieves!")
	set_phase(e, "Phase 1 · Ground Smash")
	e.bs.merge({ "cdA": 6.0, "cdB": 0.0, "cdC": 0.0, "p2": false, "p3": false }, true)
	sfx("roar", e.pos)

func gorrak_update(e: SUnit, dt: float) -> bool:
	var s := e.bs
	s.cdA -= dt
	s.cdB -= dt
	s.cdC -= dt
	var pct := e.hp_pct()
	if s.has("charge"):
		gorrak_charging(e, dt)
		return true
	if e.stun > 0:
		e.moving = false
		e.set_base("idle", 0.5)
		return true
	if e.busy > 0:
		e.busy -= dt
		e.moving = false
		return true
	if not s.p2 and pct < 0.6:
		s.p2 = true
		s.cdB = 0.5
		set_phase(e, "Phase 2 · The Shift Bell")
		yell(e, "BACK TO WORK, VERMIN!")
	if not s.p3 and pct < 0.3:
		s.p3 = true
		s.cdC = 1.0
		set_phase(e, "Phase 3 · Cart Charge")
		yell(e, "GORRAK RUN YOU DOWN!")
	if s.p2 and s.cdB <= 0:
		gorrak_bell(e)
		s.cdB = 26.0
		return true
	if s.p3 and s.cdC <= 0:
		gorrak_windup(e)
		s.cdC = 15.0
		return true
	if s.cdA <= 0:
		gorrak_smash(e)
		s.cdA = 8.0 if s.p3 else 10.0
		return true
	return false

func gorrak_smash(e: SUnit) -> void:
	var t := e.target
	if t == null:
		return
	e.face_to(t.pos)
	e.busy = 1.9
	e.moving = false
	var p := e.pos + e.fwd() * 3.2
	yell(e, "GORRAK SMASH!")
	e.play("smash", 0.75)
	tele_circle(e, p, 6.5, 1.6, func(tl):
		for f in party:
			if f.alive() and in_tele(tl, f):
				deal_damage(e, f, 115, { "phys": false })
		fx("dust", tl.pos, { "n": 36, "size": 2.0 })
		fx("ring", tl.pos + Vector3(0, 0.3, 0), { "color": Color(0.9, 0.75, 0.5), "r": 6.5 })
		shake(0.6)
		sfx("slam", tl.pos))

func gorrak_bell(e: SUnit) -> void:
	e.busy = 1.6
	e.moving = false
	e.play("yell", 1.0)
	emote("Gorrak hammers the shift bell. Something stirs in the shafts above...")
	bell_swing = 1.0
	sfx("bell")
	later(0.9, func(): sfx("bell"))
	var alive_bats := 0
	for x in enemies:
		if x.kind == "bat" and x.alive():
			alive_bats += 1
	var n := maxi(0, mini(3, 4 - alive_bats))
	for i in n:
		later(1.0 + i * 0.35, func():
			var spots := [Level.W(24, 9), Level.W(32, 9), Level.W(28, 4), Level.W(28, 14)]
			var sp: Vector3 = spots[randi() % spots.size()]
			var b := spawn_enemy("bat", sp.x / Level.T + randf_range(-0.3, 0.3), sp.z / Level.T + randf_range(-0.3, 0.3), "bats", 0.0)
			b.engaged = true
			b.ttl = 18.0
			var cands: Array[SUnit] = []
			for p in party:
				if p.alive() and p.kind != "sellsword":
					cands.append(p)
			if cands.is_empty():
				for p in party:
					if p.alive():
						cands.append(p)
			if cands.size():
				var tgt: SUnit = cands[randi() % cands.size()]
				add_threat(b, tgt, 50)
				b.target = tgt
			fx("poof", b.pos + Vector3(0, b.fly + 0.8, 0)))

func gorrak_windup(e: SUnit) -> void:
	# pick someone at range, preferring anyone but the tank
	var cands: Array[SUnit] = []
	for p in party:
		if p.alive() and e.dist_to(p) > 4:
			cands.append(p)
	cands.sort_custom(func(a: SUnit, b: SUnit): return int(a.kind == "sellsword") < int(b.kind == "sellsword"))
	var t: SUnit = cands[0] if cands.size() else e.target
	if t == null:
		return
	e.face_to(t.pos)
	e.busy = 2.0
	e.moving = false
	var dir := t.pos - e.pos
	dir.y = 0
	dir = dir.normalized()
	var length := 0.0
	while length < 80:
		var x := e.pos.x + dir.x * (length + 1.8)
		var z := e.pos.z + dir.z * (length + 1.8)
		if lv.zone_at(x, z) != "hall" or not lv.cell_at(x, z):
			break
		var blocked := false
		for o in lv.obst:
			if o[2] >= 0.7 and (x - o[0]) * (x - o[0]) + (z - o[1]) * (z - o[1]) < (o[2] + 0.6) * (o[2] + 0.6):
				blocked = true
				break
		if blocked:
			break
		length += 0.5
	emote("Gorrak lowers his head and paws at the ground, glaring at %s!" % t.short)
	yell(e, ["OUT OF GORRAK WAY!", "GORRAK RUN YOU DOWN!"][randi() % 2])
	e.play("yell", 0.8)
	e.set_base("idle", 0.4)
	tele_lane(e, e.pos, dir, length, 4.6, 2.0, func(_tl):
		e.bs.charge = { "dir": dir, "left": length, "hit": {} }
		e.set_base("run", 1.8)
		sfx("charge", e.pos))

func gorrak_charging(e: SUnit, dt: float) -> void:
	var c: Dictionary = e.bs.charge
	var dir: Vector3 = c.dir
	var step := minf(c.left, 30 * dt)
	c.left -= step
	e.pos.x += dir.x * step
	e.pos.z += dir.z * step
	e.moving = true
	e.yaw = atan2(dir.x, dir.z)
	for f in party:
		if f.alive() and not c.hit.has(f.id) and _d(f.pos, e.pos) < e.r + f.r + 0.8:
			c.hit[f.id] = true
			deal_damage(e, f, 125, { "phys": false })
			var side := Vector3(dir.z, 0, -dir.x)
			var sgn := 1.0 if (f.pos.x - e.pos.x) * side.x + (f.pos.z - e.pos.z) * side.z >= 0 else -1.0
			f.pos = lv.move_circle(f.pos, side.x * sgn * 6, side.z * sgn * 6, f.r)
			f.tp_seq += 1
			f.stun = maxf(f.stun, 0.8)
			if not f.cast.is_empty():
				end_cast(f, false)
	for cart in carts:
		if Vector2(cart.x - e.pos.x, cart.z - e.pos.z).length() < 3.2 and not cart.hit:
			cart.hit = true
			cart.vx = signf(dir.x if dir.x != 0 else 1.0) * 18
			fx("dust", Vector3(cart.x, 0, cart.z), { "n": 20, "size": 1.2 })
			sfx("slam", Vector3(cart.x, 0, cart.z))
	if c.left <= 0:
		e.bs.erase("charge")
		e.moving = false
		e.stun = 4.5
		e.vuln = 4.5
		e.busy = 0
		e.play("hit", 0.6)
		e.set_base("idle", 0.5)
		fx("dust", e.pos + e.fwd() * 2, { "n": 40, "size": 2.2 })
		shake(0.8)
		sfx("slam", e.pos)
		emote("Gorrak slams into the wall and is DAZED! Hit him now!")

func gorrak_death(e: SUnit) -> void:
	yell(e, "Gorrak... tired...")
	emote("Gorrak the Overseer has been defeated!")
	sfx("win")
	for b in enemies.duplicate():
		if b.kind == "bat" and b.alive():
			kill(b, null)
	later(2.5, func():
		var s := ai_of("cleric")
		if s == null:
			s = ai_of("sellsword")
		if s == null:
			s = ai_of("mage")
		say(s, "One down. Something big is moving behind that rubble."))
	win_run(e)

func update_carts(dt: float) -> void:
	for c in carts:
		if c.vx == 0:
			continue
		var nx: float = c.x + c.vx * dt
		if nx < 23.6 * Level.T or nx > 33.4 * Level.T:
			c.vx = -c.vx * 0.3
			if absf(c.vx) < 1:
				c.vx = 0.0
			fx("dust", Vector3(c.x, 0, c.z), { "n": 10, "size": 1.0 })
		else:
			c.x = nx
		c.vx *= (1 - dt * 0.8)
		if absf(c.vx) < 0.3:
			c.vx = 0.0
		c.obst[0] = c.x
		for u in units:
			if u.alive() and absf(c.vx) > 6 and Vector2(u.pos.x - c.x, u.pos.z - c.z).length() < 2.2 and u.boss == "":
				deal_damage(null, u, 30, { "phys": false })
				u.pos = lv.move_circle(u.pos, 0, signf(u.pos.z - c.z if u.pos.z != c.z else 1.0) * 3, u.r)
				u.tp_seq += 1

# ------------------------------------------------------------------ player input
## A client reports where its own unit is. Movement is client-side for responsiveness; the server
## sanity-checks it and snaps the client back (tp_seq) if it is impossible.
func player_move(peer: int, p: Vector3, yaw: float, dt: float) -> void:
	var u: SUnit = players.get(peer)
	if u == null or state != "play":
		return
	if u.dead or u.stun > 0 or u.driven or not u.charging.is_empty():
		return
	u.yaw = yaw
	var moved := _d(p, u.pos)
	if u.root > 0:
		if moved > 0.05:
			u.tp_seq += 1
		return
	var limit := u.speed * 1.6 * maxf(dt, 1.0 / D.TICK) + 0.6
	if moved > limit or lv.solid_at(p.x, p.z, u.r * 0.5):
		u.tp_seq += 1
		return
	var back := false
	if moved > 0.02:
		var dv := Vector3(p.x - u.pos.x, 0, p.z - u.pos.z).normalized()
		back = dv.dot(u.fwd()) < -0.3
	u.moving = moved > 0.02
	u.pos = Vector3(p.x, 0, p.z)
	if u.moving:
		u.set_base("back" if back else "run", -0.9 if back else (0.75 if u.slow > 0 else 1.05))
	elif u.cast.is_empty():
		u.set_base("combatIdle" if in_combat and u.melee else "idle")

func player_use(peer: int, ab_id: String, target_id: int) -> void:
	var u: SUnit = players.get(peer)
	if u == null or state != "play":
		return
	if target_id:
		var t: SUnit = by_id.get(target_id)
		if t:
			u.target = t
	var ab := D.ability(u.kind, ab_id)
	if ab.is_empty():
		return
	var t_over: SUnit = null
	if ab.target == "ally" and u.target and u.target.team == "party" and u.target.alive():
		t_over = u.target
	try_use(u, ab_id, t_over)

func player_target(peer: int, target_id: int, attack: bool) -> void:
	var u: SUnit = players.get(peer)
	if u == null:
		return
	var t: SUnit = by_id.get(target_id)
	u.target = t
	if t == null or not hostile(u, t):
		u.auto_attack = false
	elif attack:
		u.auto_attack = true

func player_loot(peer: int) -> void:
	var u: SUnit = players.get(peer)
	if u == null or loot_open or active_boss or state == "lobby":
		return
	loot_open = true
	ev(["loot", u.id])

# ------------------------------------------------------------------ main tick
func step(dt: float) -> void:
	if state == "lobby":
		return
	game_time += dt
	for i in range(timers.size() - 1, -1, -1):
		timers[i][0] -= dt
		if timers[i][0] <= 0:
			var f: Callable = timers[i][1]
			timers.remove_at(i)
			f.call()
	if state == "wipe":
		state_t -= dt
		if state_t <= 0:
			_recover()
		return
	for u in units.duplicate():
		tick_unit(u, dt)
	for e in enemies.duplicate():
		update_enemy(e, dt)
	for m in party:
		if update_charge(m, dt):
			continue
		if m.ai:
			update_ai(m, dt)
	separate(dt)
	update_teles(dt)
	update_projs(dt)
	update_carts(dt)
	bell_swing = maxf(0, bell_swing - dt * 0.35)
	lv.tick(self, dt)
	# checkpoint: the furthest safe spot the party has reached
	var leader := leader_unit()
	if leader and leader.alive() and not in_combat:
		var z := lv.zone_at(leader.pos.x, leader.pos.z)
		var cps := lv.checkpoints()
		for k in range(checkpoint_i + 1, cps.size()):
			if cps[k][0] == z:
				checkpoint_i = k
				checkpoint = cps[k][1]
	var was := in_combat
	in_combat = engaged_enemies().size() > 0
	if in_combat:
		combat_t = 0
	else:
		combat_t += dt
	if was and not in_combat:
		_on_combat_end()
	var any_alive := false
	for m in party:
		if m.alive():
			any_alive = true
	if not any_alive and party.size():
		state = "wipe"
		state_t = 5.0
		ev(["state", "wipe"])
		emote("Your party has been defeated. Regrouping...")

func _on_combat_end() -> void:
	for m in party:
		if m.dead:
			_revive(m, m.pos, 0.35)
			chat("%s gets back up." % m.short, "sys")

func _revive(m: SUnit, at: Vector3, pct: float) -> void:
	m.dead = false
	m.hp = m.max_hp * pct
	m.pos = at
	m.tp_seq += 1
	m.buffs = []
	m.cast = {}
	m.stun = 0
	m.play("spawn", 1.0)
	m.set_base("idle")

func _recover() -> void:
	clear_teles()
	projs.clear()
	timers.clear()
	for e in enemies.duplicate():
		if e.summon:
			remove_unit(e)
			continue
		if e.alive():
			reset_enemy(e)
			e.pos = e.home
			e.yaw = e.home_yaw
			e.stun = 0
			e.busy = 0
			e.vuln = 0
			e.bs = {}
			e.set_base("idle")
	if active_boss:
		ev(["boss", "hide", active_boss.id])
		active_boss = null
	for c in carts:
		c.vx = 0.0
		c.hit = false
	var i := 0
	for m in party:
		var s := checkpoint + Vector3((i % 3) * 1.6 - 1.6, 0, (i / 3) * 1.6)
		_revive(m, s, 1.0)
		m.res = 0.0 if m.res_type == "rage" else m.max_res
		m.potions = 3
		for k in m.cds.keys():
			m.cds[k] = 0.0
		i += 1
	in_combat = false
	combat_t = 99
	state = "play"
	ev(["state", "play"])
	chat("You regroup and catch your breath.", "sys")

# ------------------------------------------------------------------ snapshots
func snapshot() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(6 + units.size() * SNAP_STRIDE)
	s[0] = game_time
	s[1] = units.size()
	s[2] = carts[0].x if carts.size() > 0 else stage_vals[0]
	s[3] = carts[1].x if carts.size() > 1 else stage_vals[1]
	s[4] = bell_swing if carts.size() > 0 else stage_vals[2]
	s[5] = 1.0 if in_combat else 0.0
	var ab_ids := D.ability_ids()
	var i := 6
	for u in units:
		s[i] = u.id
		s[i + 1] = u.pos.x
		s[i + 2] = u.pos.y
		s[i + 3] = u.pos.z
		s[i + 4] = u.yaw
		s[i + 5] = u.hp
		s[i + 6] = u.max_hp
		s[i + 7] = u.res
		s[i + 8] = u.max_res
		s[i + 9] = u.absorb
		s[i + 10] = D.ANIMS.find(u.base_anim)
		s[i + 11] = u.base_speed
		s[i + 12] = D.ANIMS.find(u.act)
		s[i + 13] = u.act_seq
		s[i + 14] = u.act_speed
		s[i + 15] = ab_ids.find(u.cast.ab.id) if not u.cast.is_empty() else -1
		s[i + 16] = u.cast.time if not u.cast.is_empty() else 0.0
		s[i + 17] = u.cast.dur if not u.cast.is_empty() else 0.0
		s[i + 18] = u.target.id if u.target else 0
		var flags := 0
		if u.dead: flags |= 1
		if u.engaged: flags |= 2
		if u.stun > 0: flags |= 4
		if u.root > 0: flags |= 8
		if u.slow > 0: flags |= 16
		if u.driven: flags |= 32
		if u.vuln > 0: flags |= 64
		if u.auto_attack: flags |= 128
		if not u.has_buff("wall").is_empty(): flags |= 256
		if not u.has_buff("renew").is_empty(): flags |= 512
		if not u.has_buff("ward").is_empty(): flags |= 1024
		if not u.has_buff("burn").is_empty(): flags |= 2048
		s[i + 19] = flags
		s[i + 20] = u.tp_seq
		s[i + 21] = u.potions
		i += SNAP_STRIDE
	return s

## Cooldowns and buff timers for the party, sent a few times a second for the HUD.
func party_detail() -> Dictionary:
	var out := {}
	for m in party:
		var b: Array = []
		for x in m.buffs:
			b.append([x.id, x.name, x.t])
		out[m.id] = { "cds": m.cds.duplicate(), "gcd": m.gcd, "buffs": b }
	return out

## Everything a late joiner needs to build the world as it is now.
func world_state() -> Dictionary:
	var sp: Array = []
	for u in units:
		sp.append(spawn_info(u))
	return { "stage": lv.stage_id, "spawns": sp, "state": state, "boss": active_boss.id if active_boss else 0,
		"phase": active_boss.bs.get("phase", "") if active_boss else "", "loot": loot_open }
