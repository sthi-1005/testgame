class_name HollowbarkFight
extends BossScript
## Hollowbark, the Temple Warden: an old tree spirit grown into the temple stones.
## Phase 1 Rootbind: a slam in front of him, and roots that snare whoever stands still too long.
## Phase 2 Gale Wisps (below 65%): wisps pour out of the column crowns.
## Phase 3 Stormcrown (below 30%): gust lanes sweep the floor and throw anyone caught in them.

const T := Level.T
const CENTER := Vector3(8.5 * T, 0, 5.5 * T)

func pull(e: SUnit) -> void:
	sim.yell(e, "The sky does not belong to you, little climbers.")
	sim.set_phase(e, "Phase 1 · Rootbind")
	e.bs.merge({ "cdA": 6.0, "cdR": 9.0, "cdW": 0.0, "cdG": 0.0, "p2": false, "p3": false }, true)
	sim.sfx("roar", e.pos)

func update(e: SUnit, dt: float) -> bool:
	var s := e.bs
	for k in ["cdA", "cdR", "cdW", "cdG"]:
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
	if not s.p2 and pct < 0.65:
		s.p2 = true
		s.cdW = 0.5
		sim.set_phase(e, "Phase 2 · Gale Wisps")
		sim.yell(e, "Winds of the old sky, wake!")
	if not s.p3 and pct < 0.3:
		s.p3 = true
		s.cdG = 1.0
		sim.set_phase(e, "Phase 3 · Stormcrown")
		sim.yell(e, "Then be carried off like leaves!")
	if s.p3 and s.cdG <= 0:
		_gusts(e)
		s.cdG = 12.0
		return true
	if s.p2 and s.cdW <= 0:
		_wisps(e)
		s.cdW = 24.0
		return true
	if s.cdR <= 0:
		_rootbind(e)
		s.cdR = 11.0 if s.p3 else 14.0
		return false # keeps fighting while the roots rise
	if s.cdA <= 0:
		_slam(e)
		s.cdA = 8.0 if s.p3 else 10.0
		return true
	return false

func _slam(e: SUnit) -> void:
	var t := e.target
	if t == null:
		return
	e.face_to(t.pos)
	e.busy = 1.9
	e.moving = false
	e.play("smash", 0.75)
	var p := e.pos + e.fwd() * 3.2
	sim.tele_circle(e, p, 6.5, 1.6, func(tl):
		for f in sim.party:
			if f.alive() and sim.in_tele(tl, f):
				sim.deal_damage(e, f, 110, { "phys": false })
		sim.fx("dust", tl.pos, { "n": 30, "size": 2.0 })
		sim.fx("ring", tl.pos + Vector3(0, 0.3, 0), { "color": Color(0.6, 0.9, 0.5), "r": 6.5 })
		sim.shake(0.5)
		sim.sfx("slam", tl.pos), Color(0.95, 0.55, 0.15))

## Roots burst under one party member who isn't tanking: move or be snared.
func _rootbind(e: SUnit) -> void:
	var cands: Array[SUnit] = []
	for p in sim.party:
		if p.alive() and p != e.target:
			cands.append(p)
	if cands.is_empty():
		return
	var t: SUnit = cands[randi() % cands.size()]
	sim.emote("Roots twist up through the tiles under %s!" % t.short)
	sim.tele_circle(e, t.pos, 4.0, 1.8, func(tl):
		for f in sim.party:
			if f.alive() and sim.in_tele(tl, f):
				sim.deal_damage(e, f, 55, { "phys": false })
				f.stun = maxf(f.stun, 2.0)
				if not f.cast.is_empty():
					sim.end_cast(f, false)
		sim.fx("dust", tl.pos, { "n": 18, "size": 1.2 }), Color(0.45, 0.85, 0.3))

func _wisps(e: SUnit) -> void:
	e.busy = 1.4
	e.moving = false
	e.play("yell", 1.0)
	sim.emote("The column crowns flare and Gale Wisps spill out on the wind!")
	var alive := 0
	for x in sim.enemies:
		if x.kind == "wisp_add" and x.alive():
			alive += 1
	var n := maxi(0, mini(3, 4 - alive))
	for i in n:
		sim.later(0.8 + i * 0.4, func():
			var a := randf() * TAU
			var sp := CENTER + Vector3(cos(a) * 18.0, 0, sin(a) * 14.0)
			var w: SUnit = sim.spawn_enemy("wisp_add", sp.x / T, sp.z / T, "wisps", 0.0)
			w.engaged = true
			w.ttl = 20.0
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
				sim.add_threat(w, tgt, 50)
				w.target = tgt
			sim.fx("poof", w.pos + Vector3(0, w.fly + 0.8, 0)))

## Three gust lanes across the arena along a random axis; anyone caught is thrown along the wind.
func _gusts(e: SUnit) -> void:
	e.busy = 2.4
	e.moving = false
	e.play("yell", 0.8)
	sim.emote("Hollowbark raises the Stormcrown. The wind is coming!")
	var a := randf() * TAU
	var dir := Vector3(cos(a), 0, sin(a))
	var side := Vector3(-dir.z, 0, dir.x)
	var safe := randi() % 4 # one of four lanes stays calm
	var k := 0
	for off: float in [-15.0, -5.0, 5.0, 15.0]:
		if k == safe:
			k += 1
			continue
		k += 1
		var from := CENTER + side * off - dir * 32.0
		sim.tele_lane(e, from, dir, 64.0, 9.5, 2.2, func(tl):
			for f in sim.party:
				if f.alive() and sim.in_tele(tl, f):
					sim.deal_damage(e, f, 80, { "phys": false })
					f.pos = sim.lv.move_circle(f.pos, dir.x * 9.0, dir.z * 9.0, f.r)
					f.tp_seq += 1
					f.stun = maxf(f.stun, 0.6)
			sim.fx("dust", tl.from + dir * 32.0, { "n": 24, "size": 1.6 }), Color(0.55, 0.85, 1.0))
	sim.shake(0.3)

func death(e: SUnit) -> void:
	sim.yell(e, "The wind... remembers...")
	sim.emote("Hollowbark, the Temple Warden, crumbles into leaves. The Temple of the Open Sky is yours!")
	sim.sfx("win")
	for b in sim.enemies.duplicate():
		if b.summon and b.alive():
			sim.kill(b, null)
	sim.win_run(e)

func evade(e: SUnit) -> void:
	sim.yell(e, "Climb back down, then.")
	sim.emote("Hollowbark settles back among the columns.")
