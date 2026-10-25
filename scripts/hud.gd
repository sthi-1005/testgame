class_name Hud
extends CanvasLayer
## Party, target and boss frames, cast bar, hotbar, chat, banners. Reads the game's unit views every frame.

var game: Game
var root: Control
var me_frame: Dictionary
var tgt_frame: Dictionary
var tot_label: Label
var party_frames: Array = []
var boss_frame: Dictionary
var boss_box: Control
var cast_box: Control
var cast_bar: ProgressBar
var cast_label: Label
var slots: Array = [] # { id, panel, cd, cd_label, key, name, flash }
var chat_box: RichTextLabel
var chat_lines: Array = []
var err_label: Label
var err_t := 0.0
var banner_label: Label
var banner_t := 0.0
var zone_label: Label
var zone_t := 0.0
var prompt_label: Label
var help_label: Label
var end_panel: Control
var bubbles: Array = [] # [label3d, t]
var font_big := 30
var built_for := ""

const BG := Color(0.07, 0.06, 0.08, 0.78)
const EDGE := Color(0.55, 0.45, 0.3, 0.9)

func _ready() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	me_frame = _frame(Vector2(16, 16), Vector2(250, 62), true)
	tgt_frame = _frame(Vector2(282, 16), Vector2(250, 62), true)
	tot_label = _label("", 13, Color(0.8, 0.8, 0.8))
	tot_label.position = Vector2(286, 80)
	root.add_child(tot_label)
	for i in 4:
		party_frames.append(_frame(Vector2(16, 96 + i * 52), Vector2(190, 44), false))
	# boss frame, top centre
	boss_box = Control.new()
	boss_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	boss_box.position = Vector2(-260, 14)
	boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(boss_box)
	boss_frame = _frame(Vector2.ZERO, Vector2(520, 50), false, boss_box)
	boss_box.visible = false
	# cast bar
	cast_box = Control.new()
	cast_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	cast_box.position = Vector2(-150, -150)
	cast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cast_box)
	cast_bar = _bar(Vector2(300, 18), Color(1, 0.75, 0.3))
	cast_box.add_child(cast_bar)
	cast_label = _label("", 13, Color.WHITE)
	cast_label.size = Vector2(300, 18)
	cast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cast_box.add_child(cast_label)
	cast_box.visible = false
	# chat
	chat_box = RichTextLabel.new()
	chat_box.bbcode_enabled = true
	chat_box.scroll_following = true
	chat_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_box.position = Vector2(16, -230)
	chat_box.size = Vector2(440, 170)
	chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chat_box.add_theme_font_size_override("normal_font_size", 14)
	chat_box.add_theme_constant_override("outline_size", 4)
	chat_box.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	root.add_child(chat_box)
	# error, banner, zone, prompt
	err_label = _center_label(20, Color(1, 0.3, 0.25), 0.22)
	banner_label = _center_label(26, Color(1, 0.85, 0.5), 0.3)
	zone_label = _center_label(40, Color(1, 0.92, 0.75), 0.16)
	prompt_label = _center_label(18, Color(1, 1, 1), 0.62)
	var help := _label("WASD move   A/D turn (strafe with right mouse)   Right-drag steer   Left-drag look   Click target   Right-click attack\nTab next enemy   F1-F5 party   1-5 abilities   6 or R potion   F loot   Esc clear target", 12, Color(0.85, 0.82, 0.75, 0.75))
	help.anchor_left = 1.0
	help.anchor_right = 1.0
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_left = -760
	help.offset_right = -16
	help.offset_top = -48
	help.offset_bottom = -8
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(help)
	help_label = help

func _build_hotbar(cls: String) -> void:
	built_for = cls
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.add_theme_constant_override("separation", 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var abs: Array = D.ABILITIES[cls].duplicate()
	abs.append(D.POTION)
	bar.position = Vector2(-(abs.size() * 70) / 2.0, -112)
	root.add_child(bar)
	var cc: Color = D.CLASSES[cls].color
	for i in abs.size():
		var a: Dictionary = abs[i]
		var p := Panel.new()
		p.custom_minimum_size = Vector2(64, 64)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(cc.r * 0.35, cc.g * 0.35, cc.b * 0.35, 0.92) if a.id != "potion" else Color(0.35, 0.1, 0.1, 0.92)
		sb.border_color = EDGE
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		p.add_theme_stylebox_override("panel", sb)
		p.tooltip_text = "%s\n%s%s\n%s" % [a.name, ("Cost %d  " % a.cost) if a.cost else "", ("Cooldown %ds" % a.cd) if a.cd else "", a.desc]
		p.mouse_filter = Control.MOUSE_FILTER_STOP
		var nm := _label(_abbrev(a.name), 12, Color.WHITE)
		nm.size = Vector2(64, 64)
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		nm.autowrap_mode = TextServer.AUTOWRAP_WORD
		p.add_child(nm)
		var key := _label(str(i + 1) if a.id != "potion" else "6", 12, Color(1, 0.9, 0.6))
		key.position = Vector2(5, 2)
		p.add_child(key)
		var cd := ColorRect.new()
		cd.color = Color(0, 0, 0, 0.62)
		cd.size = Vector2(64, 0)
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(cd)
		var cdl := _label("", 20, Color(1, 1, 1))
		cdl.size = Vector2(64, 64)
		cdl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cdl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p.add_child(cdl)
		var id: String = a.id
		p.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				game._use(id))
		bar.add_child(p)
		slots.append({ "id": a.id, "ab": a, "panel": p, "sb": sb, "cd": cd, "cdl": cdl, "name": nm, "flash": 0.0, "key": key })

static func _abbrev(n: String) -> String:
	return n.replace(" ", "\n") if n.length() > 9 else n

# ------------------------------------------------------------------ widgets
func _label(t: String, size: int, c: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _center_label(size: int, c: Color, y: float) -> Label:
	var l := _label("", size, c)
	l.set_anchors_preset(Control.PRESET_TOP_WIDE)
	l.anchor_top = y
	l.anchor_bottom = y
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(l)
	return l

func _bar(size: Vector2, c: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.size = size
	b.custom_minimum_size = size
	b.show_percentage = false
	b.max_value = 1.0
	b.step = 0.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.08, 0.08, 0.85)
	bg.set_corner_radius_all(3)
	var fg := StyleBoxFlat.new()
	fg.bg_color = c
	fg.set_corner_radius_all(3)
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b

func _frame(pos: Vector2, size: Vector2, big: bool, parent: Control = null) -> Dictionary:
	var p := Panel.new()
	p.position = pos
	p.size = size
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG
	sb.border_color = EDGE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	(parent if parent else root).add_child(p)
	var name := _label("", 14 if big else 13, Color.WHITE)
	name.position = Vector2(8, 2)
	p.add_child(name)
	var val := _label("", 12, Color(1, 1, 1, 0.9))
	val.position = Vector2(size.x - 108, 2)
	val.size = Vector2(100, 16)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	p.add_child(val)
	var hp := _bar(Vector2(size.x - 16, 16 if big else 12), Color(0.25, 0.78, 0.3))
	hp.position = Vector2(8, 22 if big else 20)
	p.add_child(hp)
	var res := _bar(Vector2(size.x - 16, 10 if big else 6), Color(0.3, 0.5, 1))
	res.position = Vector2(8, 42 if big else 35)
	p.add_child(res)
	var extra := _label("", 11, Color(1, 0.85, 0.5))
	extra.position = Vector2(8, size.y + 1)
	p.add_child(extra)
	var f := { "panel": p, "sb": sb, "name": name, "val": val, "hp": hp, "res": res, "extra": extra, "id": 0 }
	p.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and f.id:
			game._set_target(f.id, false))
	return f

func _fill(f: Dictionary, v: UnitView) -> void:
	f.panel.visible = v != null
	if v == null:
		f.id = 0
		return
	f.id = v.id
	var nm: String = v.info.name
	if v.info.team == "enemy":
		nm = "%s  (%d%s)" % [nm, v.info.lvl, " Elite" if v.info.elite else ""]
	f.name.text = nm
	f.name.add_theme_color_override("font_color", Color(1, 0.55, 0.45) if v.is_enemy() else Color(0.75, 0.9, 1))
	f.hp.value = v.hp / maxf(v.max_hp, 1.0)
	f.val.text = "Dead" if v.dead else "%d / %d" % [v.hp, v.max_hp]
	var hp_sb: StyleBoxFlat = f.hp.get_theme_stylebox("fill")
	hp_sb.bg_color = Color(0.45, 0.45, 0.45) if v.dead else (Color(0.8, 0.22, 0.18) if v.is_enemy() else Color(0.25, 0.78, 0.3))
	if v.absorb > 0:
		f.val.text += "  +%d" % v.absorb
	f.res.visible = v.max_res > 0
	if v.max_res > 0:
		f.res.value = v.res / v.max_res
		var rs: StyleBoxFlat = f.res.get_theme_stylebox("fill")
		rs.bg_color = Color(0.85, 0.2, 0.15) if v.info.res_type == "rage" else Color(0.3, 0.5, 1)
	f.sb.border_color = Color(1, 0.85, 0.4) if game.target_id == v.id else EDGE
	var st: Array = []
	if v.flags & 4: st.append("Stunned")
	if v.flags & 8: st.append("Frozen")
	if v.flags & 16: st.append("Slowed")
	if v.flags & 64: st.append("Dazed")
	if v.flags & 256: st.append("Shield Wall")
	if v.flags & 512: st.append("Renew")
	if v.flags & 1024: st.append("Ward")
	if v.flags & 2048: st.append("Burning")
	f.extra.text = "  ".join(st)

# ------------------------------------------------------------------ per frame
func _process(delta: float) -> void:
	if game == null or game.me == null:
		return
	var me := game.me
	if built_for == "":
		_build_hotbar(me.info.body)
	_fill(me_frame, me)
	var t: UnitView = game.views.get(game.target_id)
	_fill(tgt_frame, t)
	tot_label.text = ""
	if t and t.target_id and game.views.has(t.target_id):
		tot_label.text = "Target of target: %s" % game.views[t.target_id].info.name
	var party := game.party_views()
	for i in party_frames.size():
		_fill(party_frames[i], party[i + 1] if i + 1 < party.size() else null)
	var b: UnitView = game.views.get(game.boss_id)
	boss_box.visible = b != null
	if b:
		_fill(boss_frame, b)
		boss_frame.name.text = "%s   %s" % [b.info.name, game.boss_phase]
	# cast bar (your own, or the boss's wind-up)
	if me.cast_ab >= 0:
		cast_box.visible = true
		cast_bar.value = clampf(me.cast_time / maxf(me.cast_dur, 0.01), 0, 1)
		var ab := D.ability(me.info.body, D.ability_ids()[me.cast_ab])
		cast_label.text = ab.get("name", "")
	else:
		cast_box.visible = false
	# hotbar
	var det: Dictionary = game.detail.get(me.id, {})
	var cds: Dictionary = det.get("cds", {})
	var gcd: float = det.get("gcd", 0.0)
	for s in slots:
		var cd: float = cds.get(s.id, 0.0)
		var total: float = s.ab.cd
		var frac := 0.0
		var txt := ""
		if cd > 0 and total > 0:
			frac = cd / total
			txt = "%d" % ceil(cd)
		elif gcd > 0 and s.id != "potion":
			frac = gcd
		s.cd.size = Vector2(64, 64 * clampf(frac, 0, 1))
		s.cd.position = Vector2(0, 64 - s.cd.size.y)
		s.cdl.text = txt
		var usable: bool = me.res >= s.ab.cost and not me.dead
		if s.id == "potion":
			usable = me.potions > 0
			s.key.text = "6  x%d" % me.potions
		s.name.modulate = Color(1, 1, 1) if usable else Color(0.55, 0.45, 0.45)
		s.flash = maxf(0.0, s.flash - delta * 4.0)
		s.sb.border_color = EDGE.lerp(Color(1, 1, 0.7), s.flash)
	# timers
	err_t -= delta
	err_label.modulate.a = clampf(err_t, 0, 1)
	banner_t -= delta
	banner_label.modulate.a = clampf(banner_t, 0, 1)
	zone_t -= delta
	zone_label.modulate.a = clampf(zone_t, 0, 1)
	for i in range(bubbles.size() - 1, -1, -1):
		bubbles[i][1] -= delta
		if bubbles[i][1] <= 0:
			bubbles[i][0].queue_free()
			bubbles.remove_at(i)

func pressed(id: String) -> void:
	for s in slots:
		if s.id == id:
			s.flash = 1.0

func typing() -> bool:
	return false

func chat(text: String, style: String) -> void:
	var c := "#d8d0c0"
	match style:
		"yell": c = "#ff6a4a"
		"say": c = "#f4f0e0"
		"emote": c = "#ffcc66"
		"loot": c = "#7fd0ff"
	chat_box.append_text("[color=%s]%s[/color]\n" % [c, text])

func error(text: String) -> void:
	err_label.text = text
	err_t = 1.6

func banner(text: String, c: Color) -> void:
	banner_label.text = text
	banner_label.add_theme_color_override("font_color", c)
	banner_t = 3.5

func zone_banner(text: String) -> void:
	zone_label.text = text
	zone_t = 3.0

func prompt(text: String) -> void:
	prompt_label.text = text

func bubble(v: UnitView, text: String, loud: bool) -> void:
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0011
	l.font_size = 20
	l.width = 360
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.outline_size = 8
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.modulate = Color(1, 0.55, 0.4) if loud else Color(1, 1, 0.92)
	v.add_child(l)
	l.position.y = v.height() + v.fly + 1.3
	bubbles.append([l, 4.5])

func boss_show(_id: int) -> void:
	boss_box.visible = true

func boss_hide() -> void:
	boss_box.visible = false

func loot() -> void:
	var l: Array = game.lv.loot_lines()
	chat(l[0], "loot")
	banner(l[1], Color(0.5, 0.85, 1))

func victory(s: Dictionary) -> void:
	end_panel = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 0.8, 0.4)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	end_panel.add_theme_stylebox_override("panel", sb)
	end_panel.set_anchors_preset(Control.PRESET_CENTER)
	end_panel.size = Vector2(460, 300)
	end_panel.position = Vector2(-230, -170)
	root.add_child(end_panel)
	var lines: Array = ["[center][font_size=28][color=#ffd27a]%s[/color][/font_size][/center]" % game.lv.victory_title(),
		"[center]Time %d:%02d    Deaths %d[/center]" % [int(s.time) / 60, int(s.time) % 60, s.deaths], ""]
	var dm: Array = []
	for id in s.dmg:
		dm.append([s.dmg[id], id])
	dm.sort_custom(func(a, b): return a[0] > b[0])
	lines.append("[b]Damage[/b]")
	for d in dm:
		lines.append("  %s  %d" % [_peer_name(d[1]), d[0]])
	var hl: Array = []
	for id in s.heal:
		hl.append([s.heal[id], id])
	hl.sort_custom(func(a, b): return a[0] > b[0])
	lines.append("[b]Healing[/b]")
	for d in hl:
		lines.append("  %s  %d" % [_peer_name(d[1]), d[0]])
	lines.append("\n[center]Open the strongbox (F), or press Enter to play again.[/center]")
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.text = "\n".join(lines)
	rt.position = Vector2(20, 16)
	rt.size = Vector2(420, 270)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	end_panel.add_child(rt)

## Victory stats are keyed by player (peer), not unit.
func _peer_name(peer) -> String:
	for id in game.views:
		var v: UnitView = game.views[id]
		if v.info.get("peer", 0) == int(peer):
			return "%s (%s)" % [v.info.name, D.CLASSES[v.info.body].title] if D.CLASSES.has(v.info.body) else v.info.name
	return "Player %s" % peer
