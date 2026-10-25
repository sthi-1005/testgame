class_name Cursors
extends RefCounted
## Context cursors drawn at startup (no image files): pointer, attack, interact, help (ally), and a "can't" variant.

const SIZE := 32

static var _made := {}

static func set_kind(kind: String) -> void:
	if not _made.has(kind):
		_made[kind] = _draw(kind)
	var hot := Vector2(1, 1)
	if kind == "interact":
		hot = Vector2(10, 2)
	Input.set_custom_mouse_cursor(_made[kind], Input.CURSOR_ARROW, hot)

static func _draw(kind: String) -> Texture2D:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match kind:
		"attack":
			# a sword pointing to the top-left
			_poly(img, [Vector2(1, 1), Vector2(7, 2), Vector2(22, 17), Vector2(17, 22), Vector2(2, 7)], Color("#d9dde6"), Color("#1a1418"))
			_poly(img, [Vector2(15, 24), Vector2(24, 15), Vector2(27, 18), Vector2(18, 27)], Color("#c9902f"), Color("#1a1418"))
			_poly(img, [Vector2(22, 22), Vector2(25, 21), Vector2(31, 27), Vector2(27, 31), Vector2(21, 25)], Color("#6b3b22"), Color("#1a1418"))
			_line(img, Vector2(4, 4), Vector2(18, 18), Color(1, 1, 1, 0.9))
		"interact":
			# an open hand / gear-ish grab: a gold hand
			_poly(img, [Vector2(8, 12), Vector2(8, 3), Vector2(12, 3), Vector2(12, 11), Vector2(13, 2), Vector2(17, 2), Vector2(17, 11),
				Vector2(18, 4), Vector2(22, 4), Vector2(22, 13), Vector2(23, 8), Vector2(27, 8), Vector2(26, 21), Vector2(21, 29), Vector2(11, 29), Vector2(4, 20), Vector2(3, 14), Vector2(6, 13)],
				Color("#f2c55c"), Color("#2a1a0a"))
		"help":
			# pointer with a green plus: friendly target
			_arrow(img, Color("#e8f6e8"))
			_poly(img, [Vector2(19, 22), Vector2(23, 22), Vector2(23, 18), Vector2(26, 18), Vector2(26, 22), Vector2(30, 22), Vector2(30, 25), Vector2(26, 25), Vector2(26, 29), Vector2(23, 29), Vector2(23, 25), Vector2(19, 25)],
				Color("#4fd65a"), Color("#0b2a0e"))
		"no":
			_arrow(img, Color("#a0a0a0"))
		_:
			_arrow(img, Color("#f4ead6"))
	return ImageTexture.create_from_image(img)

static func _arrow(img: Image, fill: Color) -> void:
	_poly(img, [Vector2(1, 1), Vector2(1, 22), Vector2(7, 17), Vector2(11, 26), Vector2(15, 24), Vector2(11, 16), Vector2(18, 16)], fill, Color("#1a1418"))

## Fill a polygon, then trace its edge in the outline colour.
static func _poly(img: Image, pts: Array, fill: Color, edge: Color) -> void:
	var pv := PackedVector2Array(pts)
	for y in SIZE:
		for x in SIZE:
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pv):
				img.set_pixel(x, y, fill)
	for i in pts.size():
		_line(img, pts[i], pts[(i + 1) % pts.size()], edge)

static func _line(img: Image, a: Vector2, b: Vector2, c: Color) -> void:
	var n := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		var x := clampi(int(p.x), 0, SIZE - 1)
		var y := clampi(int(p.y), 0, SIZE - 1)
		img.set_pixel(x, y, c)
