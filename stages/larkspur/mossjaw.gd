class_name MossjawFight
extends BossScript
## Old Mossjaw, the hill ogre who runs the Thornwatch brigands, fought in the open courtyard of the keep.
## Phase 1 (100-60%): Earthshaker (a ring around him: melee must step out) and Boulder Toss (a circle on
##   someone at range).
## Phase 2 (under 60%): Carrion Call. Crows drop from the broken towers every 25 s and go for the back line.
## Phase 3 (under 30%): Rockslide. He kicks rubble off the north wall: three lanes sweep the courtyard,
##   and he hits 25% harder.

const TOWERS := [Vector2(45.5, 5.0), Vector2(57.5, 5.0), Vector2(45.5, 14.5), Vector2(57.5, 14.5)]
const LANE_X := [45.5, 48.5, 51.5, 54.5, 57.5]

func pull(e: SUnit) -> void:
	sim.yell(e, "More little heroes for the pot!")
	sim.set_phase(e, "Phase 1 · Earthshaker")
	e.bs.merge({ "slam": 7.0, "toss": 4.0, "crows": 0.0, "slide": 0.0, "p2": false, "p3": false }, true)
	sim.sfx("roar", e.pos)

func update(e: SUnit, dt: float) -> bool:
	var s := e.bs
	for k in ["slam", "toss", "crows", "slide"]:
		s[k] -= dt
	if e.stun > 0:
		e.moving = false
		e.set_base("idle", 0.5)
		return true
	if e.busy > 0:
		e.busy -= dt
		e.moving = false
		return true
	var pct := e.hp_pct()
	if not s.p2 and pct < 0.6:
		s.p2 = true
		s.crows = 0.5
		sim.set_phase(e, "Phase 2 · Carrion Call")
		sim.yell(e, "Crows! Pick their bones clean!")
	if not s.p3 and pct < 0.3:
		s.p3 = true
		s.slide = 1.0
		sim.set_phase(e, "Phase 3 · Rockslide")
		sim.yell(e, "Mossjaw bring the whole wall down on you!")
		e.dmg = [e.dmg[0] * 1.25, e.dmg[1] * 1.25]
	if s.p2 and s.crows <= 0:
		_crows(e)
		s.crows = 25.0
		return true
	if s.p3 and s.slide <= 0:
		_rockslide(e)
		s.slide = 11.0
		return true
	if s.slam <= 0:
		_slam(e)
		s.slam = 9.0 if s.p3 else 11.0
		return true
	if s.toss <= 0:
		s.toss = 8.0 if _toss(e) else 2.0
		return e.busy > 0
	return false

func _slam(e: SUnit) -> void:
	e.busy = 2.2
	e.moving = false
	e.play("smash", 0.7)
	sim.yell(e, ["Ground's shaking, little ones!", "MOSSJAW STOMP!"][randi() % 2])
	sim.tele_circle(e, e.pos, 8.0, 2.0, func(tl):
		for f in sim.party:
			if f.alive() and sim.in_tele(tl, f):
				sim.deal_damage(e, f, 80, { "phys": false })
		sim.fx("dust", tl.pos, { "n": 44, "size": 2.4 })
		sim.fx("ring", tl.pos + Vector3(0, 0.3, 0), { "color": Color(0.85, 0.75, 0.5), "r": 8.0 })
		sim.shake(0.7)
		sim.sfx("slam", tl.pos))

## Throw a boulder at someone standing well away from him, preferring anyone but the tank.
func _toss(e: SUnit) -> bool:
	var cands: Array[SUnit] = []
	for p in sim.party:
		if p.alive() and e.dist_to(p) > 9.0:
			cands.append(p)
	if cands.is_empty():
		return false
	cands.sort_custom(func(a: SUnit, b: SUnit): return int(a.kind == "sellsword") < int(b.kind == "sellsword"))
	var t: SUnit = cands[randi() % mini(2, cands.size())]
	e.face_to(t.pos)
	e.busy = 1.0
	e.moving = false
	e.play("release", 0.8)
	sim.emote("Old Mossjaw hefts a boulder at %s!" % t.short)
	sim.tele_circle(e, t.pos, 4.5, 2.4, func(tl):
		for f in sim.party:
			if f.alive() and sim.in_tele(tl, f):
				sim.deal_damage(e, f, 75, { "phys": false })
		sim.fx("dust", tl.pos, { "n": 30, "size": 1.8 })
		sim.shake(0.4)
		sim.sfx("slam", tl.pos))
	return true

func _crows(e: SUnit) -> void:
	e.busy = 1.4
	e.moving = false
	e.play("yell", 1.0)
	sim.emote("Old Mossjaw whistles. Crows burst from the broken towers!")
	var alive := 0
	for x in sim.enemies:
		if x.kind == "crow" and x.alive():
			alive += 1
	for i in maxi(0, mini(3, 4 - alive)):
		sim.later(0.8 + i * 0.3, func():
			var sp: Vector2 = TOWERS[randi() % TOWERS.size()]
			var b: SUnit = sim.spawn_enemy("crow", sp.x + randf_range(-0.3, 0.3), sp.y + randf_range(-0.3, 0.3), "crows", 0.0)
			b.engaged = true
			b.ttl = 20.0
			var cands: Array[SUnit] = []
			for p in sim.party:
				if p.alive() and p.kind != "sellsword":
					cands.append(p)
			if cands.is_empty():
				for p in sim.party:
					if p.alive():
						cands.append(p)
			if cands.size():
				var tgt: SUnit = cands[randi() % cands.size()]
				sim.add_threat(b, tgt, 50)
				b.target = tgt
			sim.fx("poof", b.pos + Vector3(0, b.fly + 0.8, 0)))

## Three of the five courtyard columns get a lane of tumbling rubble from the north wall.
func _rockslide(e: SUnit) -> void:
	e.busy = 1.5
	e.moving = false
	e.play("smash", 0.9)
	sim.emote("Old Mossjaw kicks the north wall. Rubble comes tumbling down!")
	var cols := LANE_X.duplicate()
	cols.shuffle()
	for i in 3:
		var from := Level.W(cols[i], 3.6)
		sim.tele_lane(e, from, Vector3(0, 0, 1), 46.0, 6.0, 2.6, func(tl):
			for f in sim.party:
				if f.alive() and sim.in_tele(tl, f):
					sim.deal_damage(e, f, 85, { "phys": false })
			for k in 5:
				sim.fx("dust", tl.from + Vector3(0, 0, 4.0 + k * 9.0), { "n": 14, "size": 1.6 })
			sim.shake(0.5)
			sim.sfx("slam", tl.from + Vector3(0, 0, 20)))

func death(e: SUnit) -> void:
	sim.yell(e, "Mossjaw... only wanted... the road toll...")
	sim.emote("Old Mossjaw has been defeated! The road north is open again.")
	sim.sfx("win")
	for b in sim.enemies.duplicate():
		if b.kind == "crow" and b.alive():
			sim.kill(b, null)
	sim.later(2.5, func():
		var s: SUnit = sim.ai_of("cleric")
		if s == null:
			s = sim.ai_of("sellsword")
		if s:
			sim.say(s, "Look at that view. You can see all the way back to the Crossing."))
	sim.win_run(e)

func evade(e: SUnit) -> void:
	sim.yell(e, "Run home, then! Mossjaw keeps the keep.")
	sim.emote("Old Mossjaw lumbers back to his rock.")
