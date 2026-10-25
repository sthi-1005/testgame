# Saltrock Mines (Godot 4)

A small co-op dungeon in the spirit of classic MMO five-mans: one mine, phased bosses, three classes
(Sellsword tank, Cleric healer, Mage), AI party members filling empty slots. Original names, CC0 art.

**Status: work in progress.** The server-side simulation is complete for the first slice (entrance, Lower
Diggings, Sorting Cave, Overseer's Hall, boss Gorrak) and a bot clears it with every class. The client
(HUD, controls), the networking layer and the immersion pass on the world are in progress.

Engine: Godot 4.7 (standard build, GDScript only, Compatibility renderer so the web export matches).

## Layout

| Path | What |
|---|---|
| `scripts/data.gd` (`D`) | Classes, abilities, enemies, spawn table. Shared. |
| `scripts/level.gd` (`Level`) | Grid layout, collision (`move_circle`, `walk_clear`, `line_clear`), A* (`find_path`), and a seeded decor list. Server and clients build the same Level. |
| `scripts/sunit.gd` (`SUnit`) | One unit's authoritative state. |
| `scripts/sim.gd` (`Sim`) | The authoritative simulation: combat, abilities, enemy and party AI, the Gorrak fight. Server only. |
| `scripts/bot.gd` (`Bot`) | Drives a party member through the slice (tests, `--bot`). |
| `scripts/look.gd`, `assets.gd`, `world_builder.gd`, `cave.gd`, `unit_view.gd` | Client visuals: toon shading, model loading and animation retargeting, the dungeon, unit views. |
| `tools/` | Headless tests and render scripts (see below). |
| `assets/` | CC0 models: KayKit (Kay Lousberg) and Quaternius. |

## Simulation interface (for the network layer)

The sim is a plain `RefCounted`; whoever owns it calls these. Nothing in it touches nodes or the network.

- `var sim := Sim.new(Level.new())`
- `sim.start(roster)`: roster is `[[peer_id, class_id], ...]` for human players. AI fills missing classes.
- `sim.step(dt)`: one tick. Designed for `D.TICK` (30 Hz).
- Inputs, keyed by peer id:
  - `sim.player_move(peer, pos, yaw, dt)`: the client owns its own movement; the server sanity-checks it, and on rejection bumps the unit's `tp_seq` so the client snaps back.
  - `sim.player_use(peer, ability_id, target_id)`
  - `sim.player_target(peer, unit_id, attack)`
  - `sim.player_loot(peer)`
- Mid-run joins and leaves: `sim.add_player(peer, cls)` (takes over the AI of that class) and `sim.drop_player(peer)` (the unit becomes AI).
- Output after each step:
  - `sim.snapshot()`: a PackedFloat32Array. The header is `[time, n, cart0x, cart1x, bell, in_combat]`, then `Sim.SNAP_STRIDE` floats per unit (see the function for the field order).
  - `sim.events`: an Array of reliable events (`spawn`, `despawn`, `float`, `fx`, `sfx`, `chat`, `yell`, `emote`, `tele`, `tele_end`, `proj`, `proj_end`, `boss`, `state`, `chest`, `loot`, `shake`). The owner sends these to every client, then clears the list.
  - `sim.private_events`: `{peer: [events]}`, sent to one client (errors, "you died"), then cleared.
  - `sim.party_detail()`: cooldowns and buffs for the HUD, sent a few times a second.
  - `sim.world_state()`: everything a late joiner needs.
- `sim.players`: peer to SUnit. `sim.party` and `sim.enemies` hold all units.

## Tools

```
godot --headless -s tools/bottest.gd -- sellsword   # bot plays the slice as a class (sellsword|cleric|mage)
godot --path . --rendering-driver opengl3 -s tools/shots.gd   # renders review stills to user://
```

## Credits

All art is CC0: KayKit Adventurers, Dungeon Remastered and Character Animations by Kay Lousberg (kaylousberg.com),
and Ultimate Monsters and props by Quaternius (quaternius.com).
