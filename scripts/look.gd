class_name Look
extends RefCounted
## The Signature look: cel-banded lighting with ink outlines on every mesh, a cold teal grade in the
## tunnels and a warmer, brighter one in the boss hall.

const TOON := """
shader_type spatial;
render_mode cull_back, specular_disabled;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_tex = false;
uniform vec4 albedo : source_color = vec4(1.0);
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 emission : source_color = vec3(0.0);
uniform vec2 uv_scale = vec2(1.0);
uniform float rim = 0.25;
void fragment() {
	vec4 c = albedo * tint;
	if (use_tex) c *= texture(albedo_tex, UV * uv_scale);
	ALBEDO = c.rgb;
	EMISSION = emission;
	// a thin cool rim keeps silhouettes readable in the dark
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION += vec3(1.0, 0.85, 0.7) * c.rgb * f * rim;
}
void light() {
	// soft, rounded shading: a wide wrap with one gentle step, so forms read as smooth and toy-like
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float e = ndl * ATTENUATION;
	float b = mix(smoothstep(0.25, 0.75, e), e, 0.45);
	DIFFUSE_LIGHT += LIGHT_COLOR * b / PI;
}
"""

const INK := """
shader_type spatial;
render_mode unshaded, cull_front, specular_disabled;
uniform float thickness = 0.025;
uniform vec4 color : source_color = vec4(0.16, 0.09, 0.07, 1.0);
void vertex() {
	VERTEX += NORMAL * thickness;
}
void fragment() {
	ALBEDO = color.rgb;
}
"""

const GLOW := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
uniform sampler2D tex : source_color, filter_linear;
uniform vec4 color : source_color = vec4(1.0, 0.6, 0.2, 1.0);
void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = color.rgb * COLOR.rgb;
	ALPHA = t.a * color.a * COLOR.a;
}
"""

const TELE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
uniform vec4 color : source_color = vec4(1.0, 0.35, 0.1, 1.0);
uniform float fill = 0.0;
uniform float pulse = 0.0;
uniform bool lane = false;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float a;
	if (lane) {
		float edge = smoothstep(0.82, 0.96, abs(p.x));
		float chev = step(0.5, fract(UV.y * 6.0 - abs(p.x) * 0.5 - TIME * 1.5)) * 0.25;
		a = edge * 0.9 + 0.22 + chev * (1.0 - edge) + (UV.y < fill ? 0.25 : 0.0);
	} else {
		float d = length(p);
		if (d > 1.0) discard;
		float ring = smoothstep(0.86, 0.97, d) * (1.0 - smoothstep(0.98, 1.0, d));
		a = ring * 0.95 + (d < fill ? 0.3 : 0.08);
	}
	ALBEDO = color.rgb;
	ALPHA = clamp(a * (0.75 + pulse * 0.25), 0.0, 1.0);
}
"""

static var _toon_shader: Shader
static var _ink_shader: Shader
static var _glow_shader: Shader
static var _tele_shader: Shader
static var _ink_mat: ShaderMaterial
static var _cache := {} # source material -> toon material

static func toon_shader() -> Shader:
	if _toon_shader == null:
		_toon_shader = Shader.new()
		_toon_shader.code = TOON
	return _toon_shader

static func ink(thickness := 0.025) -> ShaderMaterial:
	if _ink_shader == null:
		_ink_shader = Shader.new()
		_ink_shader.code = INK
	if is_equal_approx(thickness, 0.025) and _ink_mat:
		return _ink_mat
	var m := ShaderMaterial.new()
	m.shader = _ink_shader
	m.set_shader_parameter("thickness", thickness)
	if is_equal_approx(thickness, 0.025):
		_ink_mat = m
	return m

static func glow_mat(tex: Texture2D, color: Color) -> ShaderMaterial:
	if _glow_shader == null:
		_glow_shader = Shader.new()
		_glow_shader.code = GLOW
	var m := ShaderMaterial.new()
	m.shader = _glow_shader
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("color", color)
	return m

static func tele_mat(color: Color, lane: bool) -> ShaderMaterial:
	if _tele_shader == null:
		_tele_shader = Shader.new()
		_tele_shader.code = TELE
	var m := ShaderMaterial.new()
	m.shader = _tele_shader
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("lane", lane)
	return m

## A toon material from a plain colour or texture.
static func toon(color: Color, tex: Texture2D = null, ink_w := 0.025, uv_scale := Vector2.ONE) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = toon_shader()
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("uv_scale", uv_scale)
	if tex:
		m.set_shader_parameter("albedo_tex", tex)
		m.set_shader_parameter("use_tex", true)
	if ink_w > 0:
		m.next_pass = ink(ink_w)
	return m

## Convert an imported material to the toon look, caching per source material.
static func to_toon(src: Material, ink_w := 0.025, tint := Color.WHITE) -> Material:
	if src == null:
		return toon(Color(0.7, 0.7, 0.7), null, ink_w)
	var key := [src, ink_w, tint]
	if _cache.has(key):
		return _cache[key]
	var out: Material = src
	if src is BaseMaterial3D:
		var b := src as BaseMaterial3D
		out = toon(b.albedo_color, b.albedo_texture, ink_w)
		out.set_shader_parameter("tint", tint)
		if b.emission_enabled:
			out.set_shader_parameter("emission", b.emission * b.emission_energy_multiplier)
		if b.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			out = src # keep glass, cloth cutouts and the like as they are
	_cache[key] = out
	return out

## Walk a node tree and swap every mesh surface to the toon look.
static func apply(root: Node, ink_w := 0.025, tint := Color.WHITE) -> void:
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			mi.set_surface_override_material(i, to_toon(src, ink_w, tint))

# ------------------------------------------------------------------ colour grade per zone
const GRADE := {
	"dark": { "fog": 0.016, "fog_c": Color(0.1, 0.06, 0.08), "amb": 0.5, "amb_c": Color(0.72, 0.64, 0.75), "exp": 1.0, "con": 1.1, "sat": 1.25,
		"torch": Color(1, 0.55, 0.22) },
	"arena": { "fog": 0.008, "fog_c": Color(0.14, 0.09, 0.12), "amb": 0.7, "amb_c": Color(0.85, 0.78, 0.9), "exp": 1.15, "con": 1.08, "sat": 1.3,
		"torch": Color(1, 0.62, 0.3) },
}

static func make_environment() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.04, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.glow_enabled = true
	e.glow_intensity = 0.7
	e.glow_bloom = 0.05
	e.glow_hdr_threshold = 1.0
	e.adjustment_enabled = true
	# Forward+ only (ignored by the web/Compatibility build): volumetric fog, ambient occlusion, GI
	e.volumetric_fog_enabled = true
	e.volumetric_fog_density = 0.008
	e.volumetric_fog_albedo = Color(1.0, 0.8, 0.6)
	e.volumetric_fog_length = 48.0
	e.volumetric_fog_ambient_inject = 0.15
	e.ssao_enabled = true
	e.ssao_radius = 1.6
	e.ssao_intensity = 1.5
	e.sdfgi_enabled = false
	return e

static func grade(e: Environment, k: float) -> void:
	var a: Dictionary = GRADE.dark
	var b: Dictionary = GRADE.arena
	e.fog_density = lerpf(a.fog, b.fog, k)
	e.fog_light_color = a.fog_c.lerp(b.fog_c, k)
	e.background_color = e.fog_light_color
	e.ambient_light_color = a.amb_c.lerp(b.amb_c, k)
	e.ambient_light_energy = lerpf(a.amb, b.amb, k)
	e.tonemap_exposure = lerpf(a.exp, b.exp, k)
	e.adjustment_contrast = lerpf(a.con, b.con, k)
	e.adjustment_saturation = lerpf(a.sat, b.sat, k)
