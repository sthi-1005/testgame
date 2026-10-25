class_name CoastBoss
extends BossScript
## Ondrak the Brinewarden, in the Drowned Sanctum.
## Phase 1 · Undertow: a slam on the tank and a lane of surf that drags the party toward him.
## Phase 2 · Rising Tide (65%): the sanctum floods. Anyone off the plinths is slowed and chilled,
## and brinelings rise from the water.
## Phase 3 · Maelstrom (30%): the tide comes faster and the surf splits into two lanes.
## The water level is a set piece: CoastLevel.tide_target is eased into sim.stage_vals[0] every tick.

const TIDE_HIGH := 0.32
const TIDE_RISE := 0.18 # m per second

func pull(e: SUnit) -> void:
	sim.yell(e, "The tide remembers every thief who walks this stone.")
	sim.set_phase(e, "Phase 1 · Undertow")
	e.bs.merge({ "cdA": 5.0, "cdB": 9.0, "cdT": 0.0, "p2": false, "p3": false, "flood": 0.0, "tick": 0.0 }, true)
	sim.sfx("roar", e.pos)

func update(e: SUnit, dt: float) -> bool:
	var s := e.bs
	s.cdA -= dt
	s.cdB -= dt
	s.cdT -= dt
	_flood(e, dt)
	if e.stun > 0:
		e.moving = false
		e.set_base("idle", 0.5)
		return true
	if e.busy > 0:
		e.busy -= dt
		e.moving = false
		return true
	var pct := e.hp_pct()
	if not s.p2 and pct < 0.65:
		s.p2 = true
		s.cdT = 1.0
		sim.set_phase(e, "Phase 2 · Rising Tide")
		sim.yell(e, "Come, sea. Take back what is yours!")
	if not s.p3 and pct < 0.3:
		s.p3 = true
		s.cdT = minf(s.cdT, 3.0)
		sim.set_phase(e, "Phase 3 · Maelstrom")
		sim.yell(e, "Drown with me, then!")
	if s.p2 and s.cdT <= 0 and s.flood <= 0:
		_raise_tide(e)
		s.cdT = 24.0 if s.p3 else 32.0
		return true
	if s.cdB <= 0:
		_undertow(e, 2 if s.p3 else 1)
		s.cdB = 11.0 if s.p3 else 14.0
		return true
	if s.cdA <= 0:
		_slam(e)
		s.cdA = 7.5 if s.p3 else 9.5
		return true
	return false

func death(e: SUnit) -> void:
	sim.yell(e, "The sea... will take it... back...")
	sim.emote("Ondrak the Brinewarden has been defeated! The water drains from the sanctum.")
	sim.sfx("win")
	sim.lv.tide_target = CoastLevel.WATER_SANCTUM
	for b in sim.enemies.duplicate():
		if b.kind == "brineling" and b.alive():
			sim.kill(b, null)
	sim.later(2.5, func():
		var m: SUnit = sim.ai_of("cleric")
		if m == null:
			m = sim.ai_of("mage")
		if m:
			sim.say(m, "Look at the light through that dome. Worth the swim."))
	sim.win_run(e)

func evade(e: SUnit) -> void:
	sim.lv.tide_target = CoastLevel.WATER_SANCTUM
	sim.emote("Ondrak sinks back onto his seat as the water stills.")

func _slam(e: SUnit) -> void:
	var t := e.target
	if t == null:
		return
	e.face_to(t.pos)
	e.busy = 1.9
	e.moving = false
	var p := e.pos + e.fwd() * 3.2
	sim.yell(e, ["Break!", "Down to the deep!"][randi() % 2])
	e.play("smash", 0.75)
	sim.tele_circle(e, p, 6.5, 1.6, func(tl):
		for f in sim.party:
			if f.alive() and sim.in_tele(tl, f):
				sim.deal_damage(e, f, 105, { "phys": false })
		sim.fx("burst", tl.pos, { "n": 40, "speed": 6.0, "gravity": 9.0, "color": Color(0.7, 0.95, 1.0) })
		sim.fx("ring", tl.pos + Vector3(0, 0.3, 0), { "color": Color(0.5, 0.9, 1.0), "r": 6.5 })
		sim.shake(0.5)
		sim.sfx("slam", tl.pos), Color(0.25, 0.75, 1.0))

## A lane of surf from the boss toward someone at range. It hits, then drags them back toward him.
func _undertow(e: SUnit, lanes: int) -> void:
	var cands: Array[SUnit] = []
	for p in sim.party:
		if p.alive() and e.dist_to(p) > 5 and p != e.target:
			cands.append(p)
	if cands.is_empty():
		for p in sim.party:
			if p.alive():
				cands.append(p)
	if cands.is_empty():
		return
	cands.shuffle()
	e.busy = 1.6
	e.moving = false
	e.play("yell", 0.8)
	sim.emote("Ondrak drags the surf toward %s!" % cands[0].short)
	for k in mini(lanes, cands.size()):
		var t: SUnit = cands[k]
		var dir := t.pos - e.pos
		dir.y = 0
		dir = dir.normalized()
		var length := 0.0
		while length < 60 and sim.lv.zone_at(e.pos.x + dir.x * (length + 1), e.pos.z + dir.z * (length + 1)) == "sanctum":
			length += 1.0
		sim.tele_lane(e, e.pos, dir, length + 2.0, 5.0, 2.2, func(tl):
			for f in sim.party:
				if f.alive() and sim.in_tele(tl, f):
					sim.deal_damage(e, f, 70, { "phys": false })
					var back: Vector3 = e.pos - f.pos
					back.y = 0
					var pull := minf(8.0, maxf(0.0, back.length() - e.r - 2.5))
					back = back.normalized() * pull
					f.pos = sim.lv.move_circle(f.pos, back.x, back.z, f.r)
					f.tp_seq += 1
					f.slow = maxf(f.slow, 3.0)
			sim.fx("burst", e.pos + dir * (length * 0.5), { "n": 50, "speed": 7.2, "gravity": 9.0, "color": Color(0.7, 0.95, 1.0) })
			sim.sfx("slam", e.pos), Color(0.2, 0.6, 1.0))

func _raise_tide(e: SUnit) -> void:
	e.busy = 2.0
	e.moving = false
	e.play("yell", 0.7)
	e.bs.flood = 16.0
	sim.lv.tide_target = TIDE_HIGH
	sim.emote("Ondrak raises his arms and the sea pours into the sanctum! Climb onto the plinths!")
	sim.shake(0.4)
	var alive := 0
	for x in sim.enemies:
		if x.kind == "brineling" and x.alive():
			alive += 1
	var n := maxi(0, mini(3, 5 - alive))
	var c := Vector3(CoastLevel.SANCTUM_C.x * Level.T, 0, CoastLevel.SANCTUM_C.y * Level.T)
	for i in n:
		sim.later(1.6 + i * 0.4, func():
			var a := randf_range(0, TAU)
			var p := c + Vector3(cos(a), 0, sin(a)) * randf_range(14.0, 22.0)
			var b: SUnit = sim.spawn_enemy("brineling", p.x / Level.T, p.z / Level.T, "brine", 0.0)
			b.engaged = true
			b.ttl = 20.0
			var heal: Array[SUnit] = []
			for m in sim.party:
				if m.alive() and m.kind != "sellsword":
					heal.append(m)
			if heal.size():
				var tgt: SUnit = heal[randi() % heal.size()]
				sim.add_threat(b, tgt, 50)
				b.target = tgt
			sim.fx("burst", b.pos, { "n": 24, "speed": 3.6, "gravity": 9.0, "color": Color(0.7, 0.95, 1.0) }))

## While flooded: everyone in the water (not on a plinth or the dry threshold) is slowed and chilled.
func _flood(e: SUnit, dt: float) -> void:
	var s := e.bs
	if s.flood <= 0:
		return
	s.flood -= dt
	if s.flood <= 0:
		sim.lv.tide_target = CoastLevel.WATER_SANCTUM
		sim.emote("The water drains back out to sea.")
		return
	if sim.stage_vals[0] < TIDE_HIGH - 0.15:
		return # still rising
	s.tick -= dt
	var hit: bool = s.tick <= 0
	if hit:
		s.tick = 1.0
	for f in sim.party:
		if not f.alive() or sim.lv.floor_y(f.pos.x, f.pos.z) > 0.2:
			continue
		f.slow = maxf(f.slow, 0.4)
		if hit:
			sim.deal_damage(e, f, f.max_hp * 0.025, { "phys": false, "can_crit": false })

## Every sim tick: ease the sanctum water toward its target level (snapshot header slot 2).
static func tick_tide(sim, dt: float) -> void:
	var lv = sim.lv
	if not lv.tide_init:
		lv.tide_init = true
		sim.stage_vals[0] = CoastLevel.WATER_SANCTUM
	if sim.active_boss == null:
		lv.tide_target = CoastLevel.WATER_SANCTUM
	sim.stage_vals[0] = move_toward(sim.stage_vals[0], lv.tide_target, TIDE_RISE * dt)
