extends SceneTree
## Headless balance test: a bot plays the whole slice as one class with two AI party members.
## godot --headless -s tools/bottest.gd -- <class> [seconds] [nododge] [--stage id]

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var cls: String = args[0] if args.size() > 0 else "sellsword"
	var limit: float = float(args[1]) if args.size() > 1 else 500.0
	seed(int(args[3]) if args.size() > 3 else 7)
	var si := args.find("--stage")
	var sim := Sim.new(Stages.make_level(args[si + 1] if si >= 0 else Stages.DEFAULT))
	sim.start([[2, cls]])
	var bot := Bot.new(sim, sim.players[2])
	bot.dodge = not args.has("nododge")
	var dt := 1.0 / D.TICK
	var t := 0.0
	var log: Array = []
	var wipes := 0
	var started := Time.get_ticks_msec()
	while t < limit:
		bot.tick(dt)
		sim.step(dt)
		for e in sim.events:
			if e[0] in ["chat", "emote"]:
				log.append("%ds %s" % [t, e[1]])
			elif e[0] == "yell":
				log.append("%ds YELL %s" % [t, e[2]])
			elif e[0] == "state" and e[1] == "wipe":
				wipes += 1
				log.append("%ds WIPE" % t)
		sim.events.clear()
		sim.private_events.clear()
		t += dt
		if sim.active_boss and fmod(t, 10.0) < dt:
			var b := sim.active_boss
			var parts: Array = []
			for p in sim.party:
				parts.append("%s %d/%d @%.0f,%.0f%s" % [p.short, p.hp, p.res, p.pos.x / Level.T, p.pos.z / Level.T, (" C:" + p.cast.ab.id) if not p.cast.is_empty() else ""])
			log.append("SNAP %d boss %d @%.0f,%.0f %s | %s" % [t, b.hp, b.pos.x / Level.T, b.pos.z / Level.T, b.bs.get("phase", ""), " | ".join(parts)])
		if sim.state == "victory" or wipes >= 3:
			break
	var left: Array = []
	for e in sim.enemies:
		if e.alive():
			left.append("%s@%.1f,%.1f" % [e.name, e.pos.x / Level.T, e.pos.z / Level.T])
	for l in log.slice(-70):
		print(l)
	print("RESULT class=%s state=%s t=%d wipes=%d deaths=%d left=%s pos=%.1f,%.1f ms=%d" % [cls, sim.state, t, wipes, sim.stats.deaths, left,
		bot.u.pos.x / Level.T, bot.u.pos.z / Level.T, Time.get_ticks_msec() - started])
	quit()
