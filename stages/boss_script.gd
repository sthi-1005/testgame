class_name BossScript
extends RefCounted
## Base for a stage's boss fight. Level.boss_script(id, sim) returns one; Sim calls these on the server only.
## Use the Sim helpers for everything players see: sim.yell, sim.emote, sim.set_phase, sim.tele_circle,
## sim.tele_lane, sim.spawn_enemy, sim.deal_damage, sim.fx, sim.shake, sim.later, and sim.win_run(e) on death.
## Per-fight state goes in e.bs (a Dictionary that is cleared on evade and wipe).

var sim # Sim

func _init(s) -> void:
	sim = s

## The party engaged the boss.
func pull(_e: SUnit) -> void:
	pass

## Once per tick while engaged. Return true to take over this tick (skip the default chase and melee).
func update(_e: SUnit, _dt: float) -> bool:
	return false

## The boss died. Call sim.win_run(e) if this ends the stage.
func death(e: SUnit) -> void:
	sim.win_run(e)

## The party left the arena and the boss is resetting. Summons are removed by Sim.
func evade(e: SUnit) -> void:
	sim.emote("%s returns to its post." % e.name)
