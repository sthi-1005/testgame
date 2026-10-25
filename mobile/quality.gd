class_name Quality
extends RefCounted
## Picks a quality tier and touch mode once at startup, scales the UI for small
## screens, and trims the game's lights and effects on the mobile tier.
##   high:   desktop Forward+, everything on (the default on PC).
##   mobile: Compatibility (phones, tablets, the web build): lower 3D resolution, fewer lights and shadows.
## Command line (after `--`): --quality high|mobile, --touch (force the touch controls on a desktop),
## --phone (also size the HUD as on a phone).
## Static so it works under `godot -s` tools too; setup() runs once, from the title screen or the game.

static var tier := "high"
static var touch := false
static var phone := false # touch with a short screen side under ~500 points: the HUD gets scaled up
static var _done := false
static var _force_phone := false
static var _rotate_note: Control

static func setup() -> void:
	if _done:
		return
	_done = true
	var args := OS.get_cmdline_user_args()
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	tier = "mobile" if compat or OS.has_feature("mobile") or OS.has_feature("web") else "high"
	touch = OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios") \
		or (OS.has_feature("web") and DisplayServer.is_touchscreen_available())
	for i in args.size():
		if args[i] == "--quality" and i + 1 < args.size():
			tier = args[i + 1]
		elif args[i] == "--touch":
			touch = true
		elif args[i] == "--phone":
			touch = true
			_force_phone = true
	if tier == "mobile":
		Engine.max_fps = 60
	if touch:
		_add_rotate_note()
		_fit_ui()
		_window().size_changed.connect(_fit_ui)
	print("Quality: tier=%s touch=%s" % [tier, touch])

## Thumb-sized UI: the project's base size is 1600x900 (canvas_items, expand). On a phone in landscape
## that makes a 64 px hotbar slot about 5 mm tall, so scale everything up until the logical screen is
## roughly 560 px on its short side (phones) or 760 px (tablets). Phones in portrait get a
## "turn sideways" note over everything, since the menu and HUD are laid out for landscape.
static func _fit_ui() -> void:
	var w := _window()
	var px := Vector2(w.size)
	if px.x <= 0 or px.y <= 0:
		return
	var short_pts := minf(px.x, px.y) / maxf(DisplayServer.screen_get_scale(), 1.0)
	phone = short_pts < 500.0 or _force_phone
	var base: float = minf(px.x / 1600.0, px.y / 900.0)
	var want := 560.0 if phone else 760.0
	w.content_scale_factor = maxf(1.0, minf(px.x, px.y) / (want * base))
	if _rotate_note:
		_rotate_note.visible = phone and px.y > px.x

static func _add_rotate_note() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.03, 0.05, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	var l := Label.new()
	l.text = "Turn your phone sideways to play."
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.add_theme_font_size_override("font_size", 26)
	bg.add_child(l)
	bg.visible = false
	layer.add_child(bg)
	_window().add_child.call_deferred(layer)
	_rotate_note = bg

static func _window() -> Window:
	return (Engine.get_main_loop() as SceneTree).root

static func is_portrait() -> bool:
	var s := _window().size
	return s.y > s.x

## Called by the game once the world is built.
static func apply(game: Node) -> void:
	setup()
	if tier != "mobile":
		return
	var vp := game.get_viewport()
	vp.scaling_3d_scale = 0.75
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var e: Environment = game.env
	e.volumetric_fog_enabled = false
	e.ssao_enabled = false
	e.ssil_enabled = false
	e.sdfgi_enabled = false
	# 4 nearest torches instead of 8, and only the closest one casts shadows
	var pool = game.pool
	pool.shadow_count = 1
	while pool.lights.size() > 4:
		pool.lights.pop_back().queue_free()
	for n in game.find_children("*", "SpotLight3D", true, false):
		(n as Light3D).shadow_enabled = false
