class_name TouchControls
extends CanvasLayer
## On-screen controls for phones and tablets. Added by the game when Quality.touch is on.
##   left 40% of the screen: a floating thumbstick (move; you run where you push, relative to the camera)
##   anywhere else: drag to turn the camera (or flick sideways to switch a lock), pinch to zoom, tap an enemy to lock on
##   hotbar (moved to the bottom-right), with the Souls-style action pad above it: Attack, Heavy, Roll
##   (hold to sprint), Block (hold), Parry and Lock, plus Loot near a chest
## Every finger is handled here from the raw touch events, so you can hold the stick with one thumb and
## tap abilities with the other. Mouse emulation is switched off during play and back on for menus.

const STICK_R := 70.0
const TAP_MOVE := 16.0
const TAP_TIME := 0.35
const BTN := Vector2(96, 64)

var game: Game
var root: Control
var stick_draw: Control
var stick_finger := -1
var stick_origin := Vector2.ZERO
var stick_off := Vector2.ZERO
var looks := {} # finger -> { pos, start, t, moved }
var pinch_d := 0.0
var buttons: Array = [] # { node, fn, up } (up: called when the finger lifts, for held buttons)
var held := {} # finger -> button entry being held
var target_btn: Button
var loot_btn: Button
var again_btn: Button
var full_btn: Button
var laid_out := false

func _init(g: Game) -> void:
	game = g
	layer = 5

func _ready() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	stick_draw = Control.new()
	stick_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	stick_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stick_draw.draw.connect(_draw_stick)
	root.add_child(stick_draw)
	target_btn = _button("Lock", game.toggle_lock)
	var attack := _button("Attack", func(): game._act("light"))
	var heavy := _button("Heavy", func(): game._act("heavy"))
	var roll := _button("Roll", game.dodge_press, game.dodge_release)
	var block := _button("Block", game.block_press, game.block_release)
	var parry := _button("Parry", func(): game._act("parry"))
	loot_btn = _button("Loot", func(): game.net.send_loot())
	full_btn = _button("Full", _toggle_fullscreen)
	full_btn.custom_minimum_size = Vector2(72, 44)
	full_btn.visible = OS.has_feature("web")
	again_btn = _button("Play again", func(): get_tree().reload_current_scene())
	again_btn.custom_minimum_size = Vector2(200, 64)
	again_btn.visible = false
	# two rows above the hotbar, Attack under the thumb's resting spot
	var row1 := -96 - BTN.y
	var row2 := row1 - 12 - BTN.y
	_place(attack, Vector2(1, 1), Vector2(-16 - BTN.x, row1))
	_place(heavy, Vector2(1, 1), Vector2(-28 - BTN.x * 2, row1))
	_place(block, Vector2(1, 1), Vector2(-40 - BTN.x * 3, row1))
	_place(roll, Vector2(1, 1), Vector2(-16 - BTN.x, row2))
	_place(parry, Vector2(1, 1), Vector2(-28 - BTN.x * 2, row2))
	_place(target_btn, Vector2(1, 1), Vector2(-40 - BTN.x * 3, row2))
	_place(loot_btn, Vector2(1, 1), Vector2(-52 - BTN.x * 4, row1))
	_place(full_btn, Vector2(1, 0), Vector2(-88, 12))
	_place(again_btn, Vector2(0.5, 1), Vector2(-100, -96))

func _exit_tree() -> void:
	Input.emulate_mouse_from_touch = true
	game.touch_move = Vector2.ZERO

func _button(text: String, fn: Callable, up := Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = BTN
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 18)
	for st in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.06, 0.08, 0.55 if st != "pressed" else 0.85)
		sb.border_color = Color(0.55, 0.45, 0.3, 0.9)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(12)
		b.add_theme_stylebox_override(st, sb)
	b.pressed.connect(fn) # menus and the victory screen (mouse emulation on)
	root.add_child(b)
	buttons.append({ "node": b, "fn": fn, "up": up })
	return b

## Pin c to an anchor point of the screen at an offset (offsets, not position: the parent is already sized).
func _place(c: Control, anchor: Vector2, off: Vector2, size := Vector2(-1, -1)) -> void:
	if size.x < 0:
		size = c.custom_minimum_size
	c.anchor_left = anchor.x
	c.anchor_right = anchor.x
	c.anchor_top = anchor.y
	c.anchor_bottom = anchor.y
	c.offset_left = off.x
	c.offset_top = off.y
	c.offset_right = off.x + size.x
	c.offset_bottom = off.y + size.y

func _toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)

## Once the HUD has its hotbar: move it to the bottom-right under the right thumb, put the boss frame
## top-right (it would sit on the target frame at phone width), and drop the keyboard help and the chat.
func _layout_hud() -> void:
	var hud := game.hud
	if hud.slots.is_empty():
		return
	laid_out = true
	var bar := (hud.slots[0].panel as Control).get_parent() as Control
	var w := hud.slots.size() * 70.0
	_place(bar, Vector2(1, 1), Vector2(-16 - w, -16 - 64), Vector2(w, 64))
	_place(hud.boss_box, Vector2(1, 0), Vector2(-16 - 520 - (88 if full_btn.visible else 0), 14), Vector2.ZERO)
	_place(hud.cast_box, Vector2(0.5, 1), Vector2(-150, -190), Vector2.ZERO)
	if hud.help_label:
		hud.help_label.visible = false
	hud.chat_box.visible = false
	for s in hud.slots:
		(s.key as Label).visible = false
		(s.panel as Control).tooltip_text = ""

func _playing() -> bool:
	return game.me != null and game.state == "play"

func _process(_delta: float) -> void:
	if not laid_out:
		_layout_hud()
	var playing := _playing()
	# taps go to the menus as clicks, except during play where every finger is ours
	Input.emulate_mouse_from_touch = not playing
	if not playing and (stick_finger >= 0 or not looks.is_empty()):
		_release_all()
	var near_chest := game.chest != null and game.my_pos.distance_to(game.chest_pos) < 5.0
	loot_btn.visible = near_chest
	for b in buttons:
		if b.node != loot_btn and b.node != full_btn and b.node != again_btn:
			(b.node as Control).visible = game.state == "play"
	(target_btn as Button).text = "Unlock" if game.locked else "Lock"
	again_btn.visible = game.state == "victory"
	var p := game.hud.prompt_label
	if p.text.begins_with("Press F"):
		p.text = p.text.replace("Press F", "Tap Loot")

func _input(e: InputEvent) -> void:
	if not _playing():
		return
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if t.pressed:
			if _tap_ui(t.position, t.index):
				pass
			elif t.position.x < _view().x * 0.4 and stick_finger < 0:
				stick_finger = t.index
				stick_origin = t.position
				stick_off = Vector2.ZERO
			else:
				looks[t.index] = { "pos": t.position, "start": t.position, "t": Time.get_ticks_msec(), "moved": false }
				pinch_d = _pinch_dist()
		else:
			if held.has(t.index):
				held[t.index].up.call()
				held.erase(t.index)
			elif t.index == stick_finger:
				stick_finger = -1
				stick_off = Vector2.ZERO
				game.touch_move = Vector2.ZERO
			elif looks.has(t.index):
				var l: Dictionary = looks[t.index]
				var quick: bool = Time.get_ticks_msec() - int(l.t) < TAP_TIME * 1000
				if not l.moved and quick and looks.size() == 1:
					var id := game.unit_at(t.position)
					game._pick(t.position, true)
					if id and game.views[id].is_enemy():
						game.locked = true
				looks.erase(t.index)
				pinch_d = _pinch_dist()
		stick_draw.queue_redraw()
		get_viewport().set_input_as_handled()
	elif e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		if d.index == stick_finger:
			stick_off = (d.position - stick_origin).limit_length(STICK_R)
			# drag the base along when the thumb slides past the rim
			var past := (d.position - stick_origin).length() - STICK_R
			if past > 0:
				stick_origin += (d.position - stick_origin).normalized() * past
			game.touch_move = Vector2(stick_off.x, -stick_off.y) / STICK_R
		elif looks.has(d.index):
			var l: Dictionary = looks[d.index]
			l.pos = d.position
			if d.position.distance_to(l.start) > TAP_MOVE:
				l.moved = true
			if looks.size() >= 2:
				var nd := _pinch_dist()
				if pinch_d > 0:
					game.cam_dist = clampf(game.cam_dist * pinch_d / maxf(nd, 1.0), Game.CAM_MIN, Game.CAM_MAX)
				pinch_d = nd
			elif l.moved:
				game.touch_look(d.relative * 1.3)
		stick_draw.queue_redraw()
		get_viewport().set_input_as_handled()

## A finger landing on a hotbar slot or one of our buttons fires it right away.
func _tap_ui(at: Vector2, finger: int) -> bool:
	for s in game.hud.slots:
		var p := s.panel as Control
		if p.is_visible_in_tree() and p.get_global_rect().grow(4).has_point(at):
			game._use(s.id)
			return true
	for b in buttons:
		var n := b.node as Control
		if n.is_visible_in_tree() and n.get_global_rect().grow(4).has_point(at):
			b.fn.call()
			if (b.up as Callable).is_valid():
				held[finger] = b
			return true
	return false

func _pinch_dist() -> float:
	if looks.size() < 2:
		return 0.0
	var ks := looks.keys()
	return (looks[ks[0]].pos as Vector2).distance_to(looks[ks[1]].pos)

func _release_all() -> void:
	for f in held:
		held[f].up.call()
	held.clear()
	stick_finger = -1
	stick_off = Vector2.ZERO
	looks.clear()
	game.touch_move = Vector2.ZERO
	stick_draw.queue_redraw()

func _view() -> Vector2:
	return root.get_viewport_rect().size

func _draw_stick() -> void:
	if stick_finger < 0:
		# a faint hint where the stick lives
		var hint := Vector2(150, _view().y - 150)
		stick_draw.draw_arc(hint, STICK_R, 0, TAU, 48, Color(1, 1, 1, 0.18), 3.0, true)
		stick_draw.draw_circle(hint, 26, Color(1, 1, 1, 0.12))
		return
	stick_draw.draw_circle(stick_origin, STICK_R, Color(0, 0, 0, 0.25))
	stick_draw.draw_arc(stick_origin, STICK_R, 0, TAU, 48, Color(1, 0.9, 0.7, 0.55), 3.0, true)
	stick_draw.draw_circle(stick_origin + stick_off, 30, Color(1, 0.92, 0.75, 0.6))
