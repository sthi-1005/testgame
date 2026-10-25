# Saltrock Mines (Godot 4)

A small co-op dungeon in the spirit of classic MMO five-mans: one mine, phased bosses, three classes
(Sellsword tank, Cleric healer, Mage), AI party members filling empty slots. Original names, CC0 art.

**Status: work in progress.** The server-side simulation is complete for the first slice (entrance, Lower
Diggings, Sorting Cave, Overseer's Hall, boss Gorrak) and a bot clears it with every class. The client
(HUD, controls), the networking layer and the immersion pass on the world are in progress.

Engine: Godot 4.7 (standard build, GDScript only, Compatibility renderer so the web export matches).

## Play

Open the project in Godot 4.7 and press F5, or run `godot --path .`. Pick a class and choose Play solo; AI companions fill the party.

Controls: WASD to move (A/D turn, or strafe while holding the right mouse button), right-drag to steer, left-drag to look around, wheel to zoom.
Click a unit to target it, right-click an enemy to attack, Tab for the next enemy, F1-F5 for party members, 1-5 for abilities, 6 or R for a potion, F to loot.

## Layout

| Path | What |
|---|---|
| `scripts/data.gd` (`D`) | Classes, abilities, enemies, spawn table. Shared. |
| `scripts/level.gd` (`Level`) | Grid layout, collision (`move_circle`, `walk_clear`, `line_clear`), A* (`find_path`), and a seeded decor list. Server and clients build the same Level. |
| `scripts/sunit.gd` (`SUnit`) | One unit's authoritative state. |
| `scripts/sim.gd` (`Sim`) | The authoritative simulation: combat, abilities, enemy and party AI, the Gorrak fight. Server only. |
| `scripts/bot.gd` (`Bot`) | Drives a party member through the slice (tests, `--bot`). |
| `scripts/look.gd`, `assets.gd`, `world_builder.gd`, `cave.gd`, `unit_view.gd` | Client visuals: toon shading, model loading and animation retargeting, the dungeon, unit views. |
| `main.tscn`, `scripts/main.gd`, `game.gd`, `hud.gd`, `cursors.gd`, `local_net.gd` | Title screen, the client game scene (camera, controls, effects), the HUD, context cursors, and the in-process server used for solo play. |
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

## Multiplayer (`net/`)

`Net` (autoload, `net/net.gd`) wraps the sim for solo play, listen servers and dedicated servers. All three take
the same path: solo play runs over an `OfflineMultiplayerPeer`, and on a host the local player is peer 1, whose
messages are plain calls instead of RPCs. The transport is ENet on native builds and WebSocket on web
(`Net.transport`). A browser client needs a server started with `--ws`.

- **Client API:** `host_solo(cls)`, `host(cls, port)`, `join("host[:port]", cls)`, `set_class(cls)`, `start_game()`
  (the party leader only), `leave()`. In play: `send_move(pos, yaw, dt)` (call every frame; it's sent at `D.TICK`
  and only when something changed), `send_use(ab, target_id)`, `send_target(id, attack)`, `send_loot()`.
- **Signals:** `state_changed(offline|connecting|lobby|play|disconnected|failed)` (`Net.last_error` holds the
  reason), `lobby_changed([{peer, cls}])` (leader first), `world_received(sim.world_state())`, `you_are(unit_id)`,
  `snapshot_received(PackedFloat32Array)` (always a complete `Sim.snapshot()`), `events_received(Array)` (private
  events merged in), and `party_detail_received(Dictionary)`. In party detail, `cds` and `gcd` are filled only
  for your own unit; everyone's buffs are included.
- **Ordering:** `world_received` arrives before any events for that world. Units already in the world never get
  a separate `spawn` event.
- **Wire:** the server sends each snapshot as a delta. Only the rows that changed in the last 3 ticks are sent,
  plus a full keyframe every 0.5 s, split into packets under the MTU. Units are removed only by the reliable
  `despawn` event, so a lost packet can never make one vanish. Snapshots and moves are unreliable-ordered;
  events, actions and the lobby are reliable.
- **Joins:** a mid-run join takes over the AI unit of the same class, or adds a new member. A player who leaves
  hands their unit to the AI. When the last player leaves a dedicated server, it resets to the lobby.

Dedicated server (prints bandwidth every 10 s):

```
godot --headless --path . res://net/server.tscn -- --port 24565 [--ws]
<exported build> --headless -- --server --port 24565      # same thing from an export
```

Open UDP 24565 (or TCP for `--ws`) on the host. A ~$5 VPS is plenty for one party.

Network tests:

```
godot --headless --path . res://tools/net_bot.tscn -- --solo --cls mage          # one bot client, solo
tools/net_party.sh 60                     # dedicated server plus 5 bot clients on localhost
LAG="60 15 0.03" tools/net_party.sh 60    # through tools/lagproxy.py: ~120 ms ping, ±15 ms jitter, 3% loss
```

Measured with 5 players on Godot 4.7.2: 30 snapshots/s at every client, zero snap-backs at 120 ms ping with 3% loss,
about 22 KB/s down and under 1 KB/s up per player.

## Tools

```
godot --headless -s tools/bottest.gd -- sellsword   # bot plays the slice as a class (sellsword|cleric|mage)
godot --path . --rendering-driver opengl3 -s tools/shots.gd   # renders review stills to user://
```

## Credits

All art is CC0: KayKit Adventurers, Dungeon Remastered and Character Animations by Kay Lousberg (kaylousberg.com),
and Ultimate Monsters and props by Quaternius (quaternius.com).
