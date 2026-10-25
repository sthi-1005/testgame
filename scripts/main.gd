extends Node
## Title screen: pick a stage and a class. Solo runs the server in-process (LocalNet).
## Command line (after `--`): --stage <id> picks the stage (stages/stages.gd); --class <id> skips the menu; --bot autoplays; --shots saves review stills; --server is handled by Net.

var menu: Control
var game: Game
var cls := "sellsword"
var stage := Stages.DEFAULT
var args := {}

func _ready() -> void:
	var net := get_node_or_null("/root/Net")
	if net and net.has_method("is_server_launch") and net.is_server_launch():
		return
	_parse_args()
	Quality.setup()
	Cursors.set_kind("pointer")
	if args.get("stage") is String and Stages.has(args.stage):
		stage = args.stage
	if args.has("class"):
		cls = args["class"]
		_start()
	else:
		_build_menu()

func _parse_args() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		var k: String = a[i].trim_prefix("--")
		if i + 1 < a.size() and not a[i + 1].begins_with("--"):
			args[k] = a[i + 1]
			i += 2
		else:
			args[k] = true
			i += 1

func _build_menu() -> void:
	menu = Control.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(menu)
	var bg := ColorRect.new()
	bg.color = Color("#120d0c")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-430, -250)
	box.size = Vector2(860, 500)
	box.add_theme_constant_override("separation", 18)
	menu.add_child(box)
	var title := Label.new()
	title.text = "SALTROCK MINES"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color("#ffcf80"))
	box.add_child(title)
	var sub := Label.new()
	sub.text = "Pick a stage and a class. AI companions fill the rest of the party."
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color("#c8bca8"))
	box.add_child(sub)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 12)
	srow.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(srow)
	var sgroup := ButtonGroup.new()
	for st in Stages.LIST:
		var sb := Button.new()
		sb.toggle_mode = true
		sb.button_group = sgroup
		sb.custom_minimum_size = Vector2(205, 96) # four fit across the menu
		sb.text = "%s\n%s" % [st.name, st.blurb]
		sb.autowrap_mode = TextServer.AUTOWRAP_WORD
		sb.add_theme_font_size_override("font_size", 13)
		sb.button_pressed = st.id == stage
		var sid: String = st.id
		sb.pressed.connect(func(): stage = sid)
		srow.add_child(sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var group := ButtonGroup.new()
	for c in D.CLASS_ORDER:
		var d: Dictionary = D.CLASSES[c]
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(270, 170)
		b.text = "%s\n%s · %s\n\n%s" % [d.name, d.title, d.role, d.blurb]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD
		b.add_theme_font_size_override("font_size", 16)
		b.button_pressed = c == cls
		var cc: String = c
		b.pressed.connect(func(): cls = cc)
		row.add_child(b)
	var go := Button.new()
	go.text = "Play solo"
	go.custom_minimum_size = Vector2(260, 54)
	go.add_theme_font_size_override("font_size", 22)
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go.pressed.connect(_start)
	box.add_child(go)
	var net := get_node_or_null("/root/Net")
	if net == null:
		var mp := Label.new()
		mp.text = "Multiplayer (host / join) arrives with the network layer."
		mp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mp.add_theme_color_override("font_color", Color("#8a8070"))
		box.add_child(mp)
		return
	var mrow := HBoxContainer.new()
	mrow.alignment = BoxContainer.ALIGNMENT_CENTER
	mrow.add_theme_constant_override("separation", 10)
	box.add_child(mrow)
	var host := Button.new()
	host.text = "Host a party"
	host.custom_minimum_size = Vector2(170, 40)
	host.pressed.connect(func(): _start_net(""))
	mrow.add_child(host)
	var addr := LineEdit.new()
	addr.placeholder_text = "host address, e.g. 192.168.1.20"
	addr.custom_minimum_size = Vector2(280, 40)
	mrow.add_child(addr)
	var join := Button.new()
	join.text = "Join"
	join.custom_minimum_size = Vector2(110, 40)
	join.pressed.connect(func(): _start_net(addr.text.strip_edges() if addr.text.strip_edges() != "" else "127.0.0.1"))
	mrow.add_child(join)

## Host (addr == "") or join a networked party. The lobby sits on top of the game until the run starts.
func _start_net(addr: String) -> void:
	var net := get_node("/root/Net")
	net.stage = stage
	var err: Error = net.host(cls) if addr == "" else net.join(addr, cls)
	if err != OK:
		return
	menu.queue_free()
	menu = null
	game = Game.new()
	game.stage_id = stage # a joining client switches to the host's stage when the world arrives
	add_child(game)
	game.attach(net)
	var lobby := PanelContainer.new()
	lobby.set_anchors_preset(Control.PRESET_CENTER)
	lobby.position = Vector2(-220, -140)
	lobby.custom_minimum_size = Vector2(440, 280)
	game.hud.add_child(lobby)
	var v := VBoxContainer.new()
	lobby.add_child(v)
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(info)
	var start := Button.new()
	start.text = "Start the run"
	start.pressed.connect(func(): net.start_game())
	v.add_child(start)
	var refresh := func(_x = null):
		if not is_instance_valid(lobby):
			return
		var lines: Array = ["Hosting %s on port %d" % [Stages.info(net.stage).name, net.DEFAULT_PORT] if addr == "" else "Party at %s (%s)" % [addr, net.state], ""]
		for p in net.lobby:
			lines.append("%s  %s" % [D.CLASSES[p.cls].title if D.CLASSES.has(p.cls) else p.cls, "(leader)" if p == net.lobby[0] else ""])
		if net.last_error != "":
			lines.append("\n" + net.last_error)
		info.text = "\n".join(lines)
		start.visible = net.is_leader()
	net.lobby_changed.connect(refresh)
	net.state_changed.connect(func(st):
		if st == "play" and is_instance_valid(lobby):
			lobby.queue_free()
		else:
			refresh.call())
	refresh.call()

func _start() -> void:
	if menu:
		menu.queue_free()
		menu = null
	game = Game.new()
	game.stage_id = stage
	add_child(game)
	var net := LocalNet.new()
	net.stage = stage
	game.attach(net)
	net.host_solo(cls)
	if args.has("bot"):
		net.enable_bot()
		game.follow_server = true
	if args.has("shots"):
		_shots()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.physical_keycode == KEY_ENTER and game and game.state == "victory":
		get_tree().reload_current_scene()

## Review mode: save a still every few seconds and quit after the victory screen.
func _shots() -> void:
	var dir: String = args.get("shots") if args.get("shots") is String else "user://play"
	DirAccess.make_dir_recursive_absolute(dir)
	var every: float = float(args.get("every", "8"))
	var limit: float = float(args.get("limit", "420"))
	var t := 0.0
	var n := 0
	var after_win := -1.0
	while t < limit:
		await get_tree().create_timer(every).timeout
		t += every
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/play_%03d.png" % [dir, n])
		print("shot %d t=%d state=%s" % [n, t, game.state])
		n += 1
		if game.state == "victory" and after_win < 0:
			after_win = t
		if after_win >= 0 and t - after_win > every * 1.5:
			break
	get_tree().quit()
