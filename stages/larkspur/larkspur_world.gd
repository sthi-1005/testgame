extends WorldBuilder
## Draws Larkspur Vale: sculpted, vertex-painted terrain running out to mountains, a river and lake,
## a sky with sun and clouds, instanced trees, grass and flowers, and the village, windmill, watchtower,
## brigand camp, bridge and Thornwatch Keep, all built from simple rounded shapes in the toon look.

const STEP := 3.0 # terrain vertex spacing (m)
const MARGIN := 130.0 # terrain beyond the playable square, for the mountains

## Soft-shaded vertex-colour material: same lighting as Look.TOON, colour from the mesh (or multimesh instance).
const PAINT := """
shader_type spatial;
render_mode cull_back, specular_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform float rim = 0.18;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform float detail_amt = 0.0;
uniform float detail_scale = 0.08;
uniform float sway = 0.0;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (sway > 0.0) {
		float k = max(VERTEX.y, 0.0) * sway;
		VERTEX.x += sin(TIME * 1.3 + wpos.x * 0.15 + wpos.z * 0.1) * k;
		VERTEX.z += cos(TIME * 1.1 + wpos.z * 0.15) * k * 0.6;
	}
}
void fragment() {
	vec3 c = COLOR.rgb * tint.rgb;
	if (detail_amt > 0.0) {
		float d = texture(detail, wpos.xz * detail_scale).r * 0.65 + texture(detail, wpos.xz * detail_scale * 0.23).r * 0.35;
		c *= mix(1.0 - detail_amt, 1.0 + detail_amt, d);
	}
	ALBEDO = c;
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = vec3(1.0, 0.92, 0.8) * c * f * rim;
}
void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float e = ndl * ATTENUATION;
	float b = mix(smoothstep(0.25, 0.75, e), e, 0.45);
	DIFFUSE_LIGHT += LIGHT_COLOR * b / PI;
}
"""

const WATER := """
shader_type spatial;
render_mode cull_disabled, specular_disabled, depth_draw_always;
uniform vec4 deep : source_color = vec4(0.16, 0.55, 0.78, 1.0);
uniform vec4 shallow : source_color = vec4(0.45, 0.85, 0.92, 1.0);
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 uv = wpos.xz * 0.035;
	float n = texture(detail, uv + vec2(TIME * 0.02, TIME * 0.013)).r;
	float n2 = texture(detail, uv * 1.7 - vec2(TIME * 0.017, -TIME * 0.022)).r;
	float w = n * 0.5 + n2 * 0.5;
	float spark = smoothstep(0.66, 0.74, w);
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	vec3 c = mix(deep.rgb, shallow.rgb, clamp(w * 0.8 + f * 0.5, 0.0, 1.0));
	ALBEDO = c;
	EMISSION = c * 0.35 + vec3(spark) * 0.55;
	ALPHA = 0.88;
}
"""

const FALL := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
void fragment() {
	float n = texture(detail, vec2(UV.x * 1.5, UV.y * 0.6 - TIME * 0.9)).r;
	float streak = smoothstep(0.35, 0.75, n);
	vec3 c = mix(vec3(0.55, 0.85, 1.0), vec3(1.0), streak);
	float edge = smoothstep(0.0, 0.12, UV.x) * smoothstep(1.0, 0.88, UV.x);
	ALBEDO = c;
	ALPHA = (0.7 + streak * 0.3) * edge;
}
"""

const ROOFS := [Color("#d0574a"), Color("#4f7fc0"), Color("#e08a3a")]

var lk: LarkspurLevel
var _shaders := {}
var _mats := {}
var _detail: Texture2D
var sun: DirectionalLight3D

func _init(level: Level, parent: Node3D) -> void:
	super(level, parent)
	lk = level as LarkspurLevel

# ------------------------------------------------------------------ materials
func _shader(name: String, code: String) -> Shader:
	if not _shaders.has(name):
		var s := Shader.new()
		s.code = code
		_shaders[name] = s
	return _shaders[name]

func detail_tex() -> Texture2D:
	if _detail == null:
		var n := FastNoiseLite.new()
		n.seed = 11
		n.frequency = 0.04
		n.fractal_octaves = 3
		var img := n.get_seamless_image(256, 256)
		img.generate_mipmaps()
		_detail = ImageTexture.create_from_image(img)
	return _detail

## The vertex-colour toon material, optionally with ink outlines and wind sway.
func paint(ink_w := 0.0, detail := 0.0, sway := 0.0, key := "") -> ShaderMaterial:
	var k := "%s/%s/%s/%s" % [ink_w, detail, sway, key]
	if _mats.has(k):
		return _mats[k]
	var m := ShaderMaterial.new()
	m.shader = _shader("paint", PAINT)
	m.set_shader_parameter("detail", detail_tex())
	m.set_shader_parameter("detail_amt", detail)
	m.set_shader_parameter("sway", sway)
	if ink_w > 0:
		m.next_pass = Look.ink(ink_w)
	_mats[k] = m
	return m

func toon(c: Color, ink_w := 0.03) -> ShaderMaterial:
	var k := "toon/%s/%s" % [c.to_html(), ink_w]
	if not _mats.has(k):
		_mats[k] = Look.toon(c, null, ink_w)
	return _mats[k]

# ------------------------------------------------------------------ sky, sun, grade
func make_environment() -> Environment:
	var e := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#3f8fe0")
	sky_mat.sky_horizon_color = Color("#bfe3f5")
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color("#6f9a6a")
	sky_mat.ground_horizon_color = Color("#bfe3f5")
	sky_mat.sun_angle_max = 20.0
	sky_mat.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#c9dcf0")
	e.ambient_light_energy = 0.45
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_density = 0.0011
	e.fog_light_color = Color("#cfe6f7")
	e.fog_sun_scatter = 0.15
	e.fog_aerial_perspective = 0.2
	e.fog_sky_affect = 0.0
	e.glow_enabled = true
	e.glow_intensity = 0.35
	e.glow_bloom = 0.03
	e.glow_hdr_threshold = 1.1
	e.adjustment_enabled = true
	e.adjustment_contrast = 1.04
	e.adjustment_saturation = 1.0
	# Forward+ only (ignored on the web build)
	e.ssao_enabled = true
	e.ssao_radius = 2.0
	e.ssao_intensity = 1.2
	return e

func grade(_env: Environment, _zone: String, _delta: float) -> void:
	pass # one bright day across the whole vale

func _sun() -> void:
	sun = DirectionalLight3D.new()
	sun.light_color = Color("#fff1d6")
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	if Quality.tier == "mobile":
		sun.directional_shadow_max_distance = 45.0
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_blur = 1.5
	sun.rotation = Vector3(deg_to_rad(-48), deg_to_rad(-35), 0)
	root.add_child(sun)

# ------------------------------------------------------------------ build
func build() -> void:
	_sun()
	_terrain()
	_water()
	_waterfall()
	_clouds()
	var trees: Array = []
	var pines: Array = []
	for e in lv.decor:
		match e.kind:
			"tree":
				trees.append(e)
			"pine":
				pines.append(e)
			"prop", "campfire":
				_place(Assets.prop(e.model), e.pos, e.rot, e.scale)
				if e.kind == "campfire":
					fire_at(e.pos + Vector3(0, 0.5, 0), 1.6)
			"rock":
				_place(Assets.prop(e.model, 0.03), e.pos - Vector3(0, 0.25, 0), e.rot, e.scale)
			"house":
				_house(e)
			"windmill":
				_windmill(e.pos, e.rot)
			"tower":
				_tower(e.pos, e.rot)
			"tent":
				_tent(e.pos, e.rot)
			"banner":
				_banner(e.pos, e.color)
			"bridge":
				_bridge()
			"fort":
				_fort()
			"ruin_pillar":
				_ruin_pillar(e.pos, e.rot)
			"well":
				_well(e.pos)
			"stall":
				_stall(e.pos, e.rot)
			"lamp":
				_lamp(e.pos)
			"fence":
				_fence(e.pos, e.to)
			"sign":
				_sign(e.pos, e.rot)
	_trees(trees, false)
	_trees(pines, true)
	_grass_and_flowers()

# ------------------------------------------------------------------ terrain
func _terrain_color(x: float, z: float, h: float, slope: float) -> Color:
	var n := LarkspurLevel.noise()
	var v := n.get_noise_2d(x * 1.9 + 50.0, z * 1.9) # broad patches
	var grass := Color("#8cc56a").lerp(Color("#62a356"), clampf(v * 1.4 + 0.5, 0.0, 1.0))
	grass = grass.lerp(Color("#b3cf74"), clampf(n.get_noise_2d(x * 4.0, z * 4.0 + 77.0) * 2.0 - 0.6, 0.0, 0.6))
	var c := grass
	# sandy banks by the water
	if h < 0.2:
		c = c.lerp(Color("#e6d7a8"), clampf((0.0 - h) / 0.6, 0.0, 1.0))
	# the road and the village green
	var rd := lk.road_d(x, z)
	var road_w := 2.6 + n.get_noise_2d(x * 3.0, z * 3.0) * 0.7
	c = c.lerp(Color("#d9c39a"), 1.0 - smoothstep(road_w - 1.2, road_w + 0.6, rd))
	var zn := lk.zone_of_at(x, z)
	if zn == "keep":
		c = Color("#c4b59b").lerp(Color("#a99a83"), clampf(n.get_noise_2d(x * 9.0, z * 9.0) + 0.5, 0.0, 1.0))
	# cliffs and mountains: rock on steep ground, snow up high
	var rock := Color("#9c8f80").lerp(Color("#7d8299"), clampf((h - 10.0) / 30.0, 0.0, 1.0))
	c = c.lerp(rock, smoothstep(0.55, 0.85, slope))
	if h > 18.0:
		c = c.lerp(Color("#6d9a55"), clampf((h - 18.0) / 10.0, 0.0, 0.5) * (1.0 - smoothstep(0.55, 0.85, slope)))
	c = c.lerp(Color("#eef2f8"), smoothstep(50.0, 58.0, h + n.get_noise_2d(x * 3.0, z * 3.0) * 6.0) * (1.0 - smoothstep(0.75, 0.95, slope) * 0.5))
	return c

func _terrain() -> void:
	var size := Vector2(lv.gw * Level.T, lv.gh * Level.T)
	var nx := int((size.x + MARGIN * 2) / STEP) + 1
	var nz := int((size.y + MARGIN * 2) / STEP) + 1
	var hs := PackedFloat32Array()
	hs.resize(nx * nz)
	for j in nz:
		for i in nx:
			hs[j * nx + i] = lk.terrain_h(-MARGIN + i * STEP, -MARGIN + j * STEP)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in nz:
		for i in nx:
			var x := -MARGIN + i * STEP
			var z := -MARGIN + j * STEP
			var h := hs[j * nx + i]
			var hl := hs[j * nx + maxi(i - 1, 0)]
			var hr := hs[j * nx + mini(i + 1, nx - 1)]
			var hd := hs[maxi(j - 1, 0) * nx + i]
			var hu := hs[mini(j + 1, nz - 1) * nx + i]
			var nrm := Vector3(hl - hr, 2.0 * STEP, hd - hu).normalized()
			st.set_normal(nrm)
			st.set_color(_terrain_color(x, z, h, 1.0 - nrm.y * nrm.y if nrm.y < 0.999 else 0.0).srgb_to_linear())
			st.add_vertex(Vector3(x, h, z))
	for j in nz - 1:
		for i in nx - 1:
			var a := j * nx + i
			st.add_index(a)
			st.add_index(a + 1)
			st.add_index(a + nx)
			st.add_index(a + 1)
			st.add_index(a + nx + 1)
			st.add_index(a + nx)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = paint(0.0, 0.12)
	mi.name = "Terrain"
	root.add_child(mi)
	add_camera_collider(mi)

func _water() -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(lv.gw * Level.T + 200, lv.gh * Level.T + 200)
	pm.subdivide_width = 8
	pm.subdivide_depth = 8
	mi.mesh = pm
	var m := ShaderMaterial.new()
	m.shader = _shader("water", WATER)
	m.set_shader_parameter("detail", detail_tex())
	mi.material_override = m
	mi.position = Vector3(lv.gw * Level.T / 2, LarkspurLevel.WATER_Y, lv.gh * Level.T / 2)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

func _waterfall() -> void:
	for e in lv.decor:
		if e.kind != "waterfall":
			continue
		var base: Vector3 = e.pos
		var top_y := lk.terrain_h(base.x, base.z - 14.0) + 2.0
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(9.0, top_y - base.y + 2.0)
		mi.mesh = qm
		var m := ShaderMaterial.new()
		m.shader = _shader("fall", FALL)
		m.set_shader_parameter("detail", detail_tex())
		mi.material_override = m
		mi.position = Vector3(base.x, (top_y + base.y) / 2.0, base.z - 3.0)
		mi.rotation.x = -0.25
		root.add_child(mi)
		# spray where it lands
		var ps := CPUParticles3D.new()
		ps.amount = 40
		ps.lifetime = 1.4
		ps.position = Vector3(base.x, base.y + 0.3, base.z)
		ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		ps.emission_box_extents = Vector3(4, 0.2, 1)
		ps.direction = Vector3.UP
		ps.spread = 35
		ps.initial_velocity_min = 2.0
		ps.initial_velocity_max = 4.0
		ps.gravity = Vector3(0, -4, 0)
		ps.scale_amount_min = 2.0
		ps.scale_amount_max = 3.5
		var q := QuadMesh.new()
		q.size = Vector2(0.6, 0.6)
		var fm := fire_mat().duplicate() as StandardMaterial3D
		fm.albedo_color = Color(0.9, 0.97, 1.0, 0.5)
		fm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		q.material = fm
		ps.mesh = q
		root.add_child(ps)

func _clouds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var m := Look.toon(Color(1, 1, 1), null, 0.0)
	m.set_shader_parameter("emission", Color(0.55, 0.6, 0.68))
	var holder := Drift.new()
	holder.speed = Vector3(0.6, 0, 0.25)
	root.add_child(holder)
	for i in 16:
		var c := Node3D.new()
		var ang := rng.randf() * TAU
		var r := rng.randf_range(160.0, 330.0)
		c.position = Vector3(128 + cos(ang) * r, rng.randf_range(80.0, 125.0), 128 + sin(ang) * r)
		holder.add_child(c)
		for k in rng.randi_range(4, 7):
			var s := MeshInstance3D.new()
			var sm := SphereMesh.new()
			var rr := rng.randf_range(7.0, 13.0)
			sm.radius = rr
			sm.height = rr * 1.4
			sm.radial_segments = 16
			sm.rings = 8
			s.mesh = sm
			s.material_override = m
			s.position = Vector3(k * 9.0 - 25.0 + rng.randf_range(-3, 3), rng.randf_range(-2, 4), rng.randf_range(-6, 6))
			s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			c.add_child(s)

## Slowly moves its children (clouds), wrapping them around the vale.
class Drift extends Node3D:
	var speed := Vector3.ZERO
	func _process(delta: float) -> void:
		for c in get_children():
			var n := c as Node3D
			n.position += speed * delta
			if n.position.x > 128 + 360:
				n.position.x -= 720

## Spins a node around its local z axis (windmill sails).
class Spin extends Node3D:
	var rate := 0.6
	func _process(delta: float) -> void:
		rotation.z += rate * delta

# ------------------------------------------------------------------ mesh helpers
func _mesh(mesh: Mesh, mat: Material, pos: Vector3, rot := Vector3.ZERO, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	(parent if parent else root).add_child(mi)
	return mi

func _boxm(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b

func _cyl(top: float, bottom: float, h: float, seg := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c

func _group(pos: Vector3, rot: float) -> Node3D:
	var g := Node3D.new()
	g.position = pos
	g.rotation.y = rot
	root.add_child(g)
	return g

# ------------------------------------------------------------------ buildings and landmarks
func _house(e: Dictionary) -> void:
	var g := _group(e.pos - Vector3(0, 0.3, 0), e.rot)
	var plaster := toon(Color("#f3e6cc"))
	var timber := toon(Color("#7a5236"), 0.025)
	var stone := toon(Color("#b8ad9c"))
	var roof := toon(ROOFS[e.roof % ROOFS.size()])
	_mesh(_boxm(Vector3(7.4, 1.0, 5.8)), stone, Vector3(0, 0.5, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(7.0, 3.4, 5.4)), plaster, Vector3(0, 2.7, 0), Vector3.ZERO, g)
	for sx in [-3.45, 3.45]:
		for sz in [-2.65, 2.65]:
			_mesh(_boxm(Vector3(0.35, 3.6, 0.35)), timber, Vector3(sx, 2.6, sz), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(7.1, 0.3, 5.5)), timber, Vector3(0, 4.3, 0), Vector3.ZERO, g)
	_mesh(_prism_x(8.4, 3.2, 6.8), roof, Vector3(0, 6.0, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(1.0, 3.0, 1.0)), stone, Vector3(2.2, 6.6, -1.2), Vector3.ZERO, g)
	# door and windows facing +z (south)
	_mesh(_boxm(Vector3(1.4, 2.4, 0.2)), toon(Color("#6b4228"), 0.02), Vector3(0, 2.2, 2.75), Vector3.ZERO, g)
	var glass := toon(Color("#ffe6a8"), 0.02)
	glass.set_shader_parameter("emission", Color(0.25, 0.18, 0.05))
	for wx in [-2.3, 2.3]:
		_mesh(_boxm(Vector3(1.1, 1.1, 0.2)), glass, Vector3(wx, 2.9, 2.75), Vector3.ZERO, g)
	# flower boxes
	for wx in [-2.3, 2.3]:
		_mesh(_boxm(Vector3(1.4, 0.35, 0.45)), timber, Vector3(wx, 2.2, 2.95), Vector3.ZERO, g)
		for k in 3:
			_mesh(_sphere(0.22), toon([Color("#ff7aa8"), Color("#ffd94a"), Color("#ffffff")][k], 0.0), Vector3(wx - 0.45 + k * 0.45, 2.5, 2.95), Vector3.ZERO, g)

## Prism with its ridge along x (gable roof).
func _prism_x(w: float, h: float, d: float) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-w / 2, -h / 2, -d / 2)
	var b := Vector3(w / 2, -h / 2, -d / 2)
	var c := Vector3(w / 2, -h / 2, d / 2)
	var dd := Vector3(-w / 2, -h / 2, d / 2)
	var e := Vector3(-w / 2, h / 2, 0)
	var f := Vector3(w / 2, h / 2, 0)
	for tri in [[a, e, f], [a, f, b], [dd, c, f], [dd, f, e], [a, dd, e], [b, f, c], [a, b, c], [a, c, dd]]:
		st.add_vertex(tri[2]) # Godot fronts are clockwise
		st.add_vertex(tri[1])
		st.add_vertex(tri[0])
	st.generate_normals()
	return st.commit()

func _sphere(r: float, seg := 12) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = seg
	s.rings = maxi(4, seg / 2)
	return s

func _windmill(pos: Vector3, rot: float) -> void:
	var g := _group(pos - Vector3(0, 0.5, 0), rot)
	var stone := toon(Color("#efe4cf"))
	var wood := toon(Color("#8a5b38"), 0.025)
	_mesh(_cyl(3.0, 4.1, 13.0, 20), stone, Vector3(0, 6.5, 0), Vector3.ZERO, g)
	_mesh(_cyl(3.3, 3.3, 0.5, 20), wood, Vector3(0, 13.0, 0), Vector3.ZERO, g)
	_mesh(_cyl(0.0, 3.6, 4.0, 20), toon(Color("#c9533f")), Vector3(0, 15.2, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(1.6, 2.6, 0.3)), toon(Color("#6b4228"), 0.02), Vector3(0, 1.8, 4.0), Vector3(-0.08, 0, 0), g)
	for wy in [5.5, 9.5]:
		_mesh(_boxm(Vector3(0.9, 1.1, 0.3)), toon(Color("#5a6b80"), 0.02), Vector3(0, wy, 3.55 - wy * 0.07), Vector3(-0.08, 0, 0), g)
	var hub := Spin.new()
	hub.position = Vector3(0, 12.6, 3.8)
	g.add_child(hub)
	_mesh(_cyl(0.5, 0.5, 1.2, 12), wood, Vector3.ZERO, Vector3(PI / 2, 0, 0), hub)
	var cloth := toon(Color("#fbf6ea"), 0.02)
	for k in 4:
		var arm := Node3D.new()
		arm.rotation.z = k * PI / 2
		hub.add_child(arm)
		_mesh(_boxm(Vector3(0.35, 10.0, 0.3)), wood, Vector3(0, 5.2, 0.3), Vector3.ZERO, arm)
		_mesh(_boxm(Vector3(2.0, 7.4, 0.12)), cloth, Vector3(1.15, 6.2, 0.45), Vector3.ZERO, arm)

func _tower(pos: Vector3, rot: float) -> void:
	var g := _group(pos - Vector3(0, 0.6, 0), rot)
	var stone := toon(Color("#b9ab95"))
	var dark := toon(Color("#998b77"))
	_mesh(_cyl(3.0, 3.6, 9.0, 18), stone, Vector3(0, 4.5, 0), Vector3.ZERO, g)
	# broken crown: uneven merlons round the top
	for k in 9:
		var a := k * TAU / 9.0
		var h: float = [1.6, 0.0, 2.2, 1.0, 0.0, 0.0, 1.8, 2.6, 0.7][k]
		if h <= 0.0:
			continue
		_mesh(_boxm(Vector3(1.4, h, 1.0)), stone, Vector3(cos(a) * 2.6, 9.0 + h / 2, sin(a) * 2.6), Vector3(0, -a, 0), g)
	_mesh(_boxm(Vector3(1.4, 2.6, 0.4)), toon(Color("#3d3530"), 0.0), Vector3(0, 1.5, 3.3), Vector3(-0.1, 0, 0), g)
	for k in 6:
		var a := k * 1.1 + 0.4
		_place(Assets.prop("q_rock_large", 0.03), pos + Vector3(cos(a) * 5.0, -0.4, sin(a) * 5.0), a, randf_range(0.9, 1.5))
	_mesh(_boxm(Vector3(5.0, 0.9, 1.1)), dark, Vector3(3.2, 0.3, 3.4), Vector3(0.1, 0.6, 0.05), g)

func _tent(pos: Vector3, rot: float) -> void:
	var g := _group(pos - Vector3(0, 0.15, 0), rot)
	_mesh(_prism_x(4.6, 3.0, 4.2), toon(Color("#c9a46a")), Vector3(0, 1.5, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(0.2, 3.4, 0.2)), toon(Color("#6b4a2e"), 0.02), Vector3(-2.3, 1.7, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(0.2, 3.4, 0.2)), toon(Color("#6b4a2e"), 0.02), Vector3(2.3, 1.7, 0), Vector3.ZERO, g)
	_mesh(_prism_x(0.1, 2.2, 1.6), toon(Color("#5a3d26"), 0.0), Vector3(2.32, 1.1, 0), Vector3.ZERO, g)

func _banner(pos: Vector3, color: Color) -> void:
	var g := _group(pos, 0.0)
	_mesh(_cyl(0.12, 0.14, 6.0, 8), toon(Color("#6b4a2e"), 0.02), Vector3(0, 3.0, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(1.8, 2.4, 0.08)), toon(color, 0.02), Vector3(0.95, 4.6, 0), Vector3.ZERO, g)

func _bridge() -> void:
	var stone := toon(Color("#c4b69e"))
	var dark := toon(Color("#a29480"))
	var x0 := LarkspurLevel.BRIDGE.x * Level.T - 0.5
	var x1 := (LarkspurLevel.BRIDGE.y + 1) * Level.T + 0.5
	var xc := (x0 + x1) / 2.0
	var span := LarkspurLevel.RIVER_W + 3.0
	var zc := lk.river_z(xc)
	var n := 14
	for i in n:
		var z0 := zc - span + 2.0 * span * i / n
		var z1 := zc - span + 2.0 * span * (i + 1) / n
		var y0 := lk.bridge_y(xc, z0)
		var y1 := lk.bridge_y(xc, z1)
		var zm := (z0 + z1) / 2.0
		var len := Vector2(z1 - z0, y1 - y0).length()
		var tilt := -atan2(y1 - y0, z1 - z0)
		_mesh(_boxm(Vector3(x1 - x0, 0.6, len + 0.05)), stone, Vector3(xc, (y0 + y1) / 2.0 - 0.3, zm), Vector3(tilt, 0, 0))
		for sx in [x0 - 0.4, x1 + 0.4]:
			_mesh(_boxm(Vector3(0.7, 1.1, len + 0.05)), dark, Vector3(sx, (y0 + y1) / 2.0 + 0.35, zm), Vector3(tilt, 0, 0))
	# the arch underneath and the piers on each bank
	for s in [-1, 1]:
		_mesh(_boxm(Vector3(x1 - x0 + 1.6, 3.4, 3.0)), dark, Vector3(xc, -1.0, zc + s * (span - 1.0)))
	_mesh(_boxm(Vector3(x1 - x0, 1.6, 2.2)), dark, Vector3(xc, -0.6, zc))

func _fort() -> void:
	var stone := toon(Color("#b8a88e"))
	var dark := toon(Color("#9d8d76"))
	var k := LarkspurLevel.KEEP
	var T := Level.T
	var y := LarkspurLevel.PLAT_H
	var x0 := k.position.x * T - 1.6
	var x1 := (k.position.x + k.size.x) * T + 1.6
	var z0 := k.position.y * T - 1.6
	var z1 := (k.position.y + k.size.y) * T + 1.6
	var gx0 := LarkspurLevel.GATE.x * T
	var gx1 := (LarkspurLevel.GATE.y + 1) * T
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var runs := [[Vector2(x0, z0), Vector2(x1, z0)], [Vector2(x0, z0), Vector2(x0, z1)], [Vector2(x1, z0), Vector2(x1, z1)],
		[Vector2(x0, z1), Vector2(gx0 - 1.0, z1)], [Vector2(gx1 + 1.0, z1), Vector2(x1, z1)]]
	for r in runs:
		var a: Vector2 = r[0]
		var b: Vector2 = r[1]
		var len := a.distance_to(b)
		var segs := maxi(1, int(len / 4.0))
		var along_x := absf(b.x - a.x) > absf(b.y - a.y)
		for i in segs:
			var t0 := float(i) / segs
			var t1 := float(i + 1) / segs
			var m := a.lerp(b, (t0 + t1) / 2.0)
			var h := rng.randf_range(4.0, 6.5) if rng.randf() > 0.12 else rng.randf_range(1.2, 2.2) # some fallen stretches
			var sz := Vector3(len / segs + 0.05, h, 2.0) if along_x else Vector3(2.0, h, len / segs + 0.05)
			_mesh(_boxm(sz), stone, Vector3(m.x, y + h / 2.0 - 0.3, m.y))
			if h > 3.0 and i % 2 == 0:
				var ms := Vector3(1.6, 1.0, 2.2) if along_x else Vector3(2.2, 1.0, 1.6)
				_mesh(_boxm(ms), stone, Vector3(m.x, y + h + 0.2, m.y))
			if rng.randf() < 0.25:
				_place(Assets.prop("k_Stone_Chunks_Large", 0.03), Vector3(m.x + rng.randf_range(-2, 2), y, m.y + rng.randf_range(-2, 2)) + (Vector3(0, 0, 2.2) if along_x else Vector3(2.2, 0, 0)) * (1 if m.x > 200 or m.y > 40 else -1), rng.randf() * TAU, 1.6)
	# corner towers and the gatehouse
	for c in [Vector2(x0, z0), Vector2(x1, z0), Vector2(x0, z1), Vector2(x1, z1), Vector2(gx0 - 1.5, z1), Vector2(gx1 + 1.5, z1)]:
		var big: bool = c.x != gx0 - 1.5 and c.x != gx1 + 1.5
		var h := rng.randf_range(8.0, 11.0) if big else 10.0
		_mesh(_cyl(2.6 if big else 2.0, 3.0 if big else 2.3, h, 16), dark, Vector3(c.x, y + h / 2.0 - 0.5, c.y))
		for q in 6:
			if rng.randf() < 0.3:
				continue
			var a := q * TAU / 6.0
			var r := 2.4 if big else 1.8
			_mesh(_boxm(Vector3(1.0, 1.0, 0.8)), dark, Vector3(c.x + cos(a) * r, y + h, c.y + sin(a) * r), Vector3(0, -a, 0))
	_mesh(_boxm(Vector3(gx1 - gx0 + 4.0, 1.4, 2.2)), dark, Vector3((gx0 + gx1) / 2.0, y + 8.6, z1))
	# old flagstones underfoot and a brazier on each side of Mossjaw's rock
	var ctr := Vector3((x0 + x1) / 2.0, y, (z0 + z1) / 2.0 - 4.0)
	_place(Assets.prop("q_rock_large", 0.03), ctr + Vector3(0, -0.3, -6.0), 0.4, 3.2)
	for s in [-1, 1]:
		var p := ctr + Vector3(s * 8.0, 0, -3.0)
		_place(Assets.prop("p_Cauldron"), p, 0.0, 2.0)
		fire_at(p + Vector3(0, 1.3, 0), 2.0)
	for s in [-1, 1]:
		_banner(Vector3((gx0 + gx1) / 2.0 + s * 4.5, y, z1 - 2.0), Color("#8a3b3b"))

func _ruin_pillar(pos: Vector3, rot: float) -> void:
	var g := _group(pos, rot)
	var stone := toon(Color("#c2b49c"))
	var h := 3.0 + fmod(absf(pos.x * 0.37 + pos.z * 0.11), 3.5)
	_mesh(_cyl(0.85, 1.0, h, 12), stone, Vector3(0, h / 2.0, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(2.3, 0.6, 2.3)), stone, Vector3(0, 0.3, 0), Vector3.ZERO, g)
	_mesh(_cyl(0.85, 0.85, 1.4, 12), stone, Vector3(1.6, 0.6, 0.8), Vector3(PI / 2, 0.6, 0), g)

func _well(pos: Vector3) -> void:
	var g := _group(pos, 0.3)
	var stone := toon(Color("#c9bfae"))
	var wood := toon(Color("#7a5236"), 0.025)
	_mesh(_cyl(1.3, 1.4, 1.1, 16), stone, Vector3(0, 0.55, 0), Vector3.ZERO, g)
	_mesh(_cyl(1.0, 1.0, 0.1, 16), toon(Color("#3f7fb0"), 0.0), Vector3(0, 0.95, 0), Vector3.ZERO, g)
	for s in [-1.15, 1.15]:
		_mesh(_boxm(Vector3(0.22, 2.6, 0.22)), wood, Vector3(s, 1.6, 0), Vector3.ZERO, g)
	_mesh(_prism_x(3.2, 1.0, 2.0), toon(Color("#d0574a")), Vector3(0, 3.3, 0), Vector3.ZERO, g)

func _stall(pos: Vector3, rot: float) -> void:
	var g := _group(pos, rot)
	var wood := toon(Color("#8a5b38"), 0.025)
	_mesh(_boxm(Vector3(3.6, 1.0, 1.6)), wood, Vector3(0, 0.5, 0), Vector3.ZERO, g)
	for sx in [-1.7, 1.7]:
		_mesh(_boxm(Vector3(0.2, 2.8, 0.2)), wood, Vector3(sx, 1.4, -0.7), Vector3.ZERO, g)
		_mesh(_boxm(Vector3(0.2, 2.4, 0.2)), wood, Vector3(sx, 1.2, 0.7), Vector3.ZERO, g)
	var awn := _mesh(_boxm(Vector3(4.0, 0.12, 2.2)), toon(Color("#f4f0e6"), 0.02), Vector3(0, 2.6, 0), Vector3(0.2, 0, 0), g)
	for k in 4:
		_mesh(_boxm(Vector3(0.5, 0.13, 2.22)), toon(Color("#d0574a"), 0.0), Vector3(-1.5 + k * 1.0, 2.6, 0), Vector3(0.2, 0, 0), g)
	awn.visible = true
	for k in 5:
		_mesh(_sphere(0.22, 8), toon([Color("#e8413c"), Color("#f2b134"), Color("#7cc35a")][k % 3], 0.0), Vector3(-1.2 + k * 0.6, 1.15, 0.2), Vector3.ZERO, g)

func _lamp(pos: Vector3) -> void:
	var g := _group(pos, 0.0)
	_mesh(_cyl(0.1, 0.14, 3.6, 8), toon(Color("#3d3a3f"), 0.02), Vector3(0, 1.8, 0), Vector3.ZERO, g)
	var glass := toon(Color("#ffe1a0"), 0.02)
	glass.set_shader_parameter("emission", Color(0.9, 0.6, 0.25) * 0.5)
	_mesh(_cyl(0.22, 0.3, 0.55, 6), glass, Vector3(0, 3.75, 0), Vector3.ZERO, g)
	_mesh(_cyl(0.0, 0.4, 0.35, 6), toon(Color("#3d3a3f"), 0.02), Vector3(0, 4.2, 0), Vector3.ZERO, g)

func _fence(a: Vector3, b: Vector3) -> void:
	var wood := toon(Color("#9a6c45"), 0.02)
	var len := Vector2(b.x - a.x, b.z - a.z).length()
	var n := maxi(1, int(len / 2.4))
	var prev := Vector3.INF
	for i in n + 1:
		var t := float(i) / n
		var p := a.lerp(b, t)
		p.y = lk.terrain_h(p.x, p.z)
		_mesh(_boxm(Vector3(0.22, 1.3, 0.22)), wood, p + Vector3(0, 0.55, 0))
		if prev != Vector3.INF:
			var m := (prev + p) / 2.0
			var d := p - prev
			var yaw := atan2(d.x, d.z)
			for hy in [0.55, 1.0]:
				_mesh(_boxm(Vector3(0.1, 0.14, d.length())), wood, m + Vector3(0, hy, 0), Vector3(-atan2(d.y, Vector2(d.x, d.z).length()), yaw, 0))
		prev = p

func _sign(pos: Vector3, rot: float) -> void:
	var g := _group(pos, rot)
	var wood := toon(Color("#8a5b38"), 0.025)
	_mesh(_boxm(Vector3(0.22, 2.8, 0.22)), wood, Vector3(0, 1.4, 0), Vector3.ZERO, g)
	_mesh(_boxm(Vector3(1.9, 0.5, 0.12)), toon(Color("#e6c98f"), 0.02), Vector3(0.5, 2.4, 0), Vector3(0, 0, 0.08), g)
	_mesh(_boxm(Vector3(1.6, 0.45, 0.12)), toon(Color("#e6c98f"), 0.02), Vector3(-0.4, 1.8, 0), Vector3(0, 0.4, -0.06), g)

# ------------------------------------------------------------------ vegetation
## A rounded canopy of overlapping blobs, white so the instance colour tints it.
func _canopy_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var blobs := [[Vector3(0, 4.6, 0), 2.3], [Vector3(1.3, 4.0, 0.4), 1.6], [Vector3(-1.2, 4.1, -0.3), 1.7], [Vector3(0.2, 5.6, -0.6), 1.5], [Vector3(-0.3, 3.9, 1.2), 1.4]]
	for b in blobs:
		var sm := _sphere(b[1], 12)
		var arr := sm.get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in idx:
			# squash a little and shade the underside darker, like a painted tree
			var v: Vector3 = verts[i] * Vector3(1, 0.85, 1)
			var shade := 0.78 + 0.22 * clampf(norms[i].y * 0.5 + 0.5, 0.0, 1.0)
			st.set_color(Color(shade, shade, shade).srgb_to_linear())
			st.set_normal(norms[i])
			st.add_vertex(v + b[0])
	return st.commit()

func _pine_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tiers := [[2.0, 2.6, 3.0], [3.6, 2.0, 2.6], [5.0, 1.4, 2.2]]
	for t in tiers:
		var cm := _cyl(0.0, t[1], t[2], 10)
		var arr := cm.get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in idx:
			var shade := 0.8 + 0.2 * clampf(norms[i].y, 0.0, 1.0)
			st.set_color(Color(shade, shade, shade).srgb_to_linear())
			st.set_normal(norms[i])
			st.add_vertex(verts[i] + Vector3(0, t[0], 0))
	return st.commit()

func _trunk_mesh(pine: bool) -> Mesh:
	return _cyl(0.22, 0.38, 3.6 if not pine else 2.4, 8)

func _trees(list: Array, pine: bool) -> void:
	if list.is_empty():
		return
	var canopy := _pine_mesh() if pine else _canopy_mesh()
	var trunk := _trunk_mesh(pine)
	var mm_c := MultiMesh.new()
	mm_c.transform_format = MultiMesh.TRANSFORM_3D
	mm_c.use_colors = true
	mm_c.mesh = canopy
	mm_c.instance_count = list.size()
	var mm_t := MultiMesh.new()
	mm_t.transform_format = MultiMesh.TRANSFORM_3D
	mm_t.mesh = trunk
	mm_t.instance_count = list.size()
	var greens := [Color("#69b84a"), Color("#86c64f"), Color("#4f9e45"), Color("#9ccc52")] if not pine else [Color("#3f8a52"), Color("#4b9a5a"), Color("#357a4a")]
	for i in list.size():
		var e: Dictionary = list[i]
		var s: float = e.scale
		var b := Basis(Vector3.UP, e.rot).scaled(Vector3(s, s * (1.0 + e.hue * 0.15), s))
		var p: Vector3 = e.pos - Vector3(0, 0.3, 0)
		mm_c.set_instance_transform(i, Transform3D(b, p))
		var gcol: Color = greens[int(e.hue * 97.0) % greens.size()]
		# autumn touches in the broadleaf groves
		if not pine and e.hue > 0.9:
			gcol = Color("#e3a73e")
		mm_c.set_instance_color(i, gcol.srgb_to_linear())
		mm_t.set_instance_transform(i, Transform3D(b, p + Vector3(0, (1.8 if not pine else 1.2) * s, 0)))
	var ci := MultiMeshInstance3D.new()
	ci.multimesh = mm_c
	ci.material_override = paint(0.035, 0.0, 0.025, "canopy")
	root.add_child(ci)
	var ti := MultiMeshInstance3D.new()
	ti.multimesh = mm_t
	ti.material_override = toon(Color("#7a5236"), 0.03)
	root.add_child(ti)

## Grass tufts and wildflowers scattered over the walkable meadows (fewer on phones).
func _grass_and_flowers() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var mobile := Quality.tier == "mobile"
	var n_grass := 2500 if mobile else 9000
	var n_flower := 900 if mobile else 3200
	# a tuft: three thin blades as flattened cones
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 3:
		var cm := _cyl(0.0, 0.07, 0.5, 4)
		var arr := cm.get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var off := Vector3(cos(k * 2.1) * 0.1, 0.25, sin(k * 2.1) * 0.1)
		var tilt := Basis(Vector3(cos(k * 2.1 + 1.0), 0, sin(k * 2.1 + 1.0)), 0.25)
		for i in idx:
			var v: Vector3 = tilt * verts[i] + off
			var shade := 0.7 + 0.3 * (v.y / 0.5)
			st.set_color(Color(shade, shade, shade).srgb_to_linear())
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	var tuft := st.commit()
	var flower := _sphere(0.11, 6)
	var mm_g := MultiMesh.new()
	mm_g.transform_format = MultiMesh.TRANSFORM_3D
	mm_g.use_colors = true
	mm_g.mesh = tuft
	var mm_f := MultiMesh.new()
	mm_f.transform_format = MultiMesh.TRANSFORM_3D
	mm_f.use_colors = true
	mm_f.mesh = flower
	var gs: Array = []
	var fs: Array = []
	var W := lv.gw * Level.T
	var H := lv.gh * Level.T
	var tries := 0
	var n := LarkspurLevel.noise()
	while (gs.size() < n_grass or fs.size() < n_flower) and tries < (n_grass + n_flower) * 4:
		tries += 1
		var x := rng.randf_range(0, W)
		var z := rng.randf_range(0, H)
		if not lv.cell_at(x, z):
			continue
		var zn := lv.zone_at(x, z)
		if zn in ["keep", "bridge", "ford", "road"]:
			continue
		var y := lk.floor_y(x, z)
		if y < 0.0 or lk.road_d(x, z) < 3.8:
			continue
		var t := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.8, 1.5)), Vector3(x, y - 0.05, z))
		var patch := n.get_noise_2d(x * 5.0 + 11.0, z * 5.0)
		if fs.size() < n_flower and patch > 0.15 and rng.randf() < 0.6:
			t.origin.y += 0.25
			fs.append([t, [Color("#ff8fb8"), Color("#ffe066"), Color("#ffffff"), Color("#b98cff"), Color("#ff9a4d")][rng.randi() % 5]])
		elif gs.size() < n_grass:
			gs.append([t, Color("#5fae4a").lerp(Color("#93c95a"), rng.randf())])
	mm_g.instance_count = gs.size()
	for i in gs.size():
		mm_g.set_instance_transform(i, gs[i][0])
		mm_g.set_instance_color(i, (gs[i][1] as Color).srgb_to_linear())
	mm_f.instance_count = fs.size()
	for i in fs.size():
		mm_f.set_instance_transform(i, fs[i][0])
		mm_f.set_instance_color(i, (fs[i][1] as Color).srgb_to_linear())
	var gi := MultiMeshInstance3D.new()
	gi.multimesh = mm_g
	gi.material_override = paint(0.0, 0.0, 0.18, "grass")
	gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(gi)
	var fi := MultiMeshInstance3D.new()
	fi.multimesh = mm_f
	var fm := paint(0.0, 0.0, 0.0, "flower")
	fi.material_override = fm
	fi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(fi)
