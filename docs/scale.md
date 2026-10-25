# Scale and camera reference

Every stage follows these numbers, so characters, spaces and the camera feel the same from one stage to the next.
1 world unit = 1 metre (a WoW yard is close enough).

## Characters
| Thing | Size |
|---|---|
| Player character (KayKit model at scale 1.0, `Assets.CHAR_SCALE = 1.0`) | 2.4 tall, about 1.6 wide at the shoulders |
| Collision radius (party, small enemies) | 0.75 to 0.95 |
| Large enemy or boss (Gorrak) | 4 to 5 tall, radius 1.8 |
| Run speed | about 7.3 per second (3 body heights a second) |
| Melee reach | 3.4 |

## Spaces
Design for a party of five fighting a pack, plus a camera behind them. Steven finds tight tunnels claustrophobic, so err on the open side.
| Thing | Minimum | Typical |
|---|---|---|
| Floor tile (`Level.T`) | 4 | 4 |
| Corridor or tunnel width | 10 (2.5 tiles, 4 characters) | 12 to 16 |
| Room or arena | 32 x 32 | 40 to 60 across |
| Ceiling in caves | 9 | 10 to 14 |
| Doorway or timber frame (clear opening) | 6 wide x 5 tall | 8 x 6 |
| Wall torch (flame) | 2.8 above the floor | |
| Table, crate, barrel | about 1 to 1.3 tall (props scaled 1.5 to 1.8 from the kits) | |
| Pillar | 1.2 to 1.6 thick | |

Open-air stages have no ceiling limit. Keep walkable ledges and bridges at least 8 wide.

## Camera (scripts/game.gd)
- Pivot: 2.0 above the player's feet (eye height).
- Default distance 9, zoom range 2.5 to 22 (mouse wheel or pinch). Default pitch -0.28 rad (about 16 degrees down). Pitch range -1.25 to 0.45. FOV 60.
- Collision: a 0.3-radius sphere is swept from the pivot to the camera against physics layer 2 (bit value 2). Any wall, ceiling or large rock that should stop the camera needs a StaticBody3D on layer 2 (mask 0 is fine). The camera pulls in instantly when blocked and eases back out. `WorldBuilder.add_camera_collider(mesh_instance)` adds a trimesh body on that layer.
- When you move forward without holding a mouse button, the camera swings behind you smoothly. Right-drag steers. Left-drag orbits.
- A stage may set its own default distance (an open sky temple can sit at 11). Keep the pitch and pivot the same.
