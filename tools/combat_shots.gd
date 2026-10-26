extends SceneTree
## Review stills of a fight up close: an enemy winding up, your swing landing, the hit after it.
## (--fixed-fps keeps game time in step with frames even though software rendering is slow)
## xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-driver opengl3 --resolution 1600x900 --fixed-fps 60 \
##   -s tools/combat_shots.gd -- --class sellsword --stage larkspur --out /tmp/shots

var out := "user://combat"
var game: Game

func _initialize() -> void:
	_run.call_deferred()

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s/%s.png" % [out, name])
	print("shot ", name)

func _frames(n: int) -> void:
	for i in n:
		await physics_frame

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var k := args.find("--out")
	if k >= 0:
		out = args[k + 1]
	DirAccess.make_dir_recursive_absolute(out)
	var main: Node = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in 600:
		await process_frame
		game = main.get("game")
		if game and game.me and game.state == "play":
			break
	var sim: Sim = game.net.sim
	var su: SUnit = sim.players.values()[0]
	su.hp = 99999
	su.max_hp = 99999
	await _frames(30)
	var foe: SUnit = null
	for e in sim.enemies:
		if e.alive() and e.boss == "" and e.max_hp >= 150 and e.fly == 0.0:
			foe = e
			break
	foe.hp = 99999
	foe.max_hp = 99999
	# stand side-on so the camera sees both of you
	var p := foe.pos + Vector3(3.0, 0, 0)
	game.my_pos = p
	su.pos = p
	game.my_yaw = atan2(foe.pos.x - p.x, foe.pos.z - p.z)
	game.net.send_move(p, game.my_yaw, 0)
	game._set_target(foe.id, false)
	game.locked = true
	foe.target = su
	foe.engaged = true
	foe.threat[su.id] = 999.0
	foe.face_to(su.pos)
	await _frames(45)
	game.cam_yaw = game.my_yaw - 0.9 # look across the fight, not down your back
	game.locked = false
	# the enemy's wind-up, half way in
	foe.swing = 0
	var seq := foe.act_seq
	for i in 120:
		await physics_frame
		if foe.act_seq != seq:
			break
	await _frames(15)
	await _shot("1_enemy_windup")
	await _frames(40)
	# your light attack: just as it lands, then a beat after
	foe.stun = 30
	su.stam = D.STAMINA
	game.act_lock = 0
	game._act("light")
	await _frames(15)
	await _shot("2_swing_lands")
	await _frames(3)
	await _shot("3_after_hit")
	await _frames(50)
	su.stam = D.STAMINA
	game._act("heavy")
	await _frames(33)
	await _shot("4_heavy_lands")
	quit()
