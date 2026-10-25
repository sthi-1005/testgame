class_name Bot
extends RefCounted
## Plays one party member through the slice by driving the simulation directly.
## Used by the headless balance test (tools/bottest.gd) and by `--bot` autoplay on a server.

var sim: Sim
var u: SUnit
var dodge := true

func _init(s: Sim, unit: SUnit) -> void:
	sim = s
	u = unit

func tick(dt: float) -> void:
	if u.dead or sim.state != "play":
		return
	var tg: SUnit = u.target if u.target and u.target.alive() and u.target.is_enemy() else null
	if tg == null:
		var cand := sim.engaged_enemies()
		if cand.is_empty():
			for e in sim.enemies:
				if e.alive():
					cand.append(e)
		cand.sort_custom(func(a: SUnit, b: SUnit): return sim._d(a.pos, u.pos) < sim._d(b.pos, u.pos))
		if cand.size():
			tg = cand[0]
			u.target = tg
	if tg == null:
		u.moving = false
		return
	var rng := D.MELEE * 0.8 if u.melee else 22.0
	var tl := sim.danger_at(u)
	if not tl.is_empty() and dodge:
		sim.escape_tele(u, tl, dt)
		return
	if u.dist_to(tg) > rng or not sim.lv.line_clear(u.pos, tg.pos):
		if u.cast.is_empty():
			sim.steer(u, tg.pos, dt, 1.0, u.r + tg.r + rng * 0.7)
			sim.anim_loco(u, "run")
		return
	u.moving = false
	u.face_to(tg.pos)
	u.auto_attack = true
	match u.kind:
		"sellsword":
			if u.hp_pct() < 0.3:
				sim.try_use(u, "wall")
			var near := 0
			for e in sim.enemies:
				if e.alive() and sim._d(e.pos, u.pos) < 8:
					near += 1
			if u.res >= 20 and near > 1:
				sim.try_use(u, "stomp")
			elif u.res >= 15:
				sim.try_use(u, "hack")
		"mage":
			if u.cds.meteor <= 0 and u.res > 40:
				sim.try_use(u, "meteor")
			elif u.res > 30:
				sim.try_use(u, "fire")
			else:
				sim.try_use(u, "frost")
		"cleric":
			var low: SUnit = null
			var hurt := 0
			for p in sim.party:
				if p.alive():
					if low == null or p.hp_pct() < low.hp_pct():
						low = p
					if p.hp_pct() < 0.6:
						hurt += 1
			if low.hp_pct() < 0.5 and u.res > 45 and u.cds.prayer <= 0 and hurt > 1:
				sim.try_use(u, "prayer")
			elif low.hp_pct() < 0.7:
				sim.try_use(u, "mend", low)
			elif low.has_buff("renew").is_empty() and low.hp_pct() < 0.9:
				sim.try_use(u, "renew", low)
			elif u.res > 150:
				sim.try_use(u, "smite")
	if u.hp_pct() < 0.3 and u.potions > 0:
		sim.try_use(u, "potion")
