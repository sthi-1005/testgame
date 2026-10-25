class_name Stages
extends RefCounted
## Every playable stage. A stage is a Level subclass (layout, spawns, checkpoints, boss scripts, floor height)
## plus a WorldBuilder subclass that draws it (geometry, sky, lighting, grade). The server and every client
## build the same Level from the stage id, which travels in Sim.world_state().stage.
##
## To add a stage: put it in stages/<id>/, extend Level and WorldBuilder, and add a row here.

const DEFAULT := "saltrock"

const LIST := [
	{ "id": "saltrock", "name": "Saltrock Mines", "blurb": "A lamp-lit mine run by thieves. Tunnels, carts and Gorrak the Overseer.",
		"level": "res://scripts/level.gd", "world": "res://scripts/world_builder.gd" },
]

static func info(id: String) -> Dictionary:
	for s in LIST:
		if s.id == id:
			return s
	return LIST[0]

static func has(id: String) -> bool:
	for s in LIST:
		if s.id == id:
			return true
	return false

static func make_level(id: String) -> Level:
	var lv: Level = load(info(id).level).new()
	return lv

## The client-side builder for a stage. Call build() on it afterwards.
static func make_world(id: String, lv: Level, parent: Node3D) -> WorldBuilder:
	return load(info(id).world).new(lv, parent)
