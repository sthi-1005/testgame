class_name LocalNet
extends Node
## Solo play: runs the authoritative Sim in-process and speaks the same interface as the network layer,
## so the game scene doesn't care whether the server is local or remote.

signal world_received(world: Dictionary)
signal snapshot_received(snap: PackedFloat32Array)
signal events_received(events: Array)
signal party_detail_received(detail: Dictionary)
signal you_are(unit_id: int)
signal lobby_changed(players: Array)
signal state_changed(state: String)

const PEER := 1

var sim: Sim
var acc := 0.0
var detail_t := 0.0
var bot: Bot # autoplay (tests and demos)

func host_solo(cls: String) -> void:
	sim = Sim.new(Level.new())
	sim.start([[PEER, cls]])
	sim.events.clear() # the world state below already carries every spawn
	world_received.emit(sim.world_state())
	you_are.emit(sim.players[PEER].id)
	state_changed.emit("play")

func enable_bot() -> void:
	bot = Bot.new(sim, sim.players[PEER])

func _physics_process(delta: float) -> void:
	if sim == null:
		return
	acc += delta
	var dt := 1.0 / D.TICK
	var steps := 0
	while acc >= dt and steps < 4:
		acc -= dt
		steps += 1
		if bot:
			bot.tick(dt)
		sim.step(dt)
	if steps == 0:
		return
	snapshot_received.emit(sim.snapshot())
	var evs: Array = sim.events.duplicate()
	evs.append_array(sim.private_events.get(PEER, []))
	sim.events.clear()
	sim.private_events.clear()
	if evs.size():
		events_received.emit(evs)
	detail_t -= delta
	if detail_t <= 0:
		detail_t = 0.2
		party_detail_received.emit(sim.party_detail())

# ------------------------------------------------------------------ client -> server
func send_move(pos: Vector3, yaw: float, dt: float) -> void:
	if bot == null:
		sim.player_move(PEER, pos, yaw, dt)

func send_use(ab: String, target_id: int) -> void:
	sim.player_use(PEER, ab, target_id)

func send_target(id: int, attack: bool) -> void:
	sim.player_target(PEER, id, attack)

func send_loot() -> void:
	sim.player_loot(PEER)
