class_name CoastLook
extends RefCounted
## Shaders, materials and the sunny environment for Tidecrown Ruins. Same soft wrap lighting as Look,
## so characters and the coast sit in one style.

const TERRAIN := """
shader_type spatial;
render_mode cull_back, specular_disabled;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float grain = 0.12;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float n = texture(noise_tex, wpos.xz * 0.045).r * 0.65 + texture(noise_tex, wpos.xz * 0.21).r * 0.35;
	ALBEDO = COLOR.rgb * (1.0 - grain + n * grain * 2.0);
}
void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float e = ndl * ATTENUATION;
	float b = mix(smoothstep(0.25, 0.75, e), e, 0.45);
	DIFFUSE_LIGHT += LIGHT_COLOR * b / PI;
}
"""

## Vertex-coloured toon for procedural meshes (columns, palms, hulls).
const PAINT := """
shader_type spatial;
render_mode cull_back, specular_disabled;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 emission : source_color = vec3(0.0);
uniform float rim = 0.2;
void fragment() {
	vec3 c = COLOR.rgb * tint.rgb;
	ALBEDO = c;
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = emission + vec3(1.0, 0.92, 0.8) * c * f * rim;
}
void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float e = ndl * ATTENUATION;
	float b = mix(smoothstep(0.25, 0.75, e), e, 0.45);
	DIFFUSE_LIGHT += LIGHT_COLOR * b / PI;
}
"""

## Two-sided swaying leaves.
const LEAF := """
shader_type spatial;
render_mode cull_disabled, specular_disabled;
uniform float sway = 0.25;
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float k = UV.x; // 0 at the stem, 1 at the tip
	VERTEX.y += sin(TIME * 1.7 + w.x * 0.3 + w.z * 0.2 + k * 2.0) * sway * k * k;
	VERTEX.x += sin(TIME * 1.3 + w.z * 0.4) * sway * 0.5 * k * k;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	if (!FRONT_FACING) NORMAL = -NORMAL;
}
void light() {
	float ndl = abs(dot(NORMAL, LIGHT)) * 0.5 + 0.5;
	float e = ndl * ATTENUATION;
	float b = mix(smoothstep(0.2, 0.7, e), e, 0.5);
	DIFFUSE_LIGHT += LIGHT_COLOR * b / PI;
}
"""

const WATER := """
shader_type spatial;
render_mode cull_disabled, specular_disabled, depth_draw_opaque;
uniform sampler2D height_tex : filter_nearest, repeat_disable; // 16-bit heights packed in RG8 (see CoastWorld.height_texture)
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec4 region = vec4(0.0, 0.0, 1.0, 1.0); // x0, z0, width, depth of the height texture
uniform float level = -0.6;
uniform vec4 deep : source_color = vec4(0.05, 0.33, 0.62, 1.0);
uniform vec4 mid : source_color = vec4(0.08, 0.56, 0.76, 1.0);
uniform vec4 shallow : source_color = vec4(0.3, 0.8, 0.78, 1.0);
uniform vec4 sky : source_color = vec4(0.75, 0.9, 1.0, 1.0);
uniform float wave_amp = 0.12;
uniform float foam_k = 1.0;
uniform float clear = 0.5; // how see-through the shallows are
uniform float band_d = 0.7; // depth range where foam bands roll in
varying vec3 wpos;

float h_at(ivec2 c, ivec2 sz) {
	vec2 rg = texelFetch(height_tex, clamp(c, ivec2(0), sz - 1), 0).rg;
	return (rg.r * 255.0 * 256.0 + rg.g * 255.0) / 65535.0 * 48.0 - 24.0;
}

// manual bilinear over packed texels: float textures don't filter on every WebGL2 device
float ground(vec2 p) {
	vec2 uv = (p - region.xy) / region.zw;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return -30.0;
	ivec2 sz = textureSize(height_tex, 0);
	vec2 f = uv * vec2(sz) - 0.5;
	ivec2 i = ivec2(floor(f));
	vec2 t = fract(f);
	return mix(mix(h_at(i, sz), h_at(i + ivec2(1, 0), sz), t.x), mix(h_at(i + ivec2(0, 1), sz), h_at(i + ivec2(1, 1), sz), t.x), t.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = sin(wpos.x * 0.08 + TIME * 0.9) * 0.6 + sin(wpos.z * 0.11 - TIME * 0.7) * 0.4 + sin((wpos.x + wpos.z) * 0.21 + TIME * 1.6) * 0.25;
	float d = clamp(level - ground(wpos.xz), 0.0, 6.0);
	w *= smoothstep(0.0, 2.0, d); // calm at the shore so the foam line stays put
	VERTEX.y += w * wave_amp;
}

void fragment() {
	float n1 = texture(noise_tex, wpos.xz * 0.03 + vec2(TIME * 0.012, TIME * 0.008)).r;
	float n2 = texture(noise_tex, wpos.xz * 0.11 - vec2(TIME * 0.02, -TIME * 0.015)).r;
	float d = clamp(level - ground(wpos.xz) + (n1 - 0.5) * 0.25, 0.0, 30.0);
	vec3 col = mix(shallow.rgb, mid.rgb, smoothstep(0.0, 2.2, d));
	col = mix(col, deep.rgb, smoothstep(2.5, 12.0, d));
	// foam: a soft lip at the water line plus bands that roll in toward the shore
	float lip = 1.0 - smoothstep(0.03, 0.22 + n2 * 0.12, d);
	float band = smoothstep(0.86, 0.97, sin(d * 6.0 / band_d - TIME * 1.6 + n1 * 5.0) * 0.5 + 0.5) * (1.0 - smoothstep(band_d * 0.2, band_d, d));
	float foam = clamp(max(lip, band * 0.85) * foam_k, 0.0, 1.0);
	// sun glints on the open water
	float glint = smoothstep(0.74, 0.8, n2 * n1 * 1.9) * smoothstep(1.5, 6.0, d) * (1.0 - smoothstep(40.0, 140.0, length(VERTEX)));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	col = mix(col, sky.rgb, fres * 0.5);
	ALBEDO = mix(col, vec3(1.0), foam);
	EMISSION = vec3(1.0, 0.98, 0.9) * glint * 0.9 + col * 0.04;
	ALPHA = max(mix(clear, 0.96, smoothstep(0.0, 2.5, d)), foam);
}

void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	DIFFUSE_LIGHT += LIGHT_COLOR * mix(0.45, 0.85, ndl) * ATTENUATION / PI;
}
"""

const CLOUD := """
shader_type spatial;
render_mode unshaded, cull_back;
uniform vec4 top : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 bottom : source_color = vec4(0.72, 0.82, 0.95, 1.0);
varying float ny;
void vertex() {
	ny = (MODEL_NORMAL_MATRIX * NORMAL).y;
}
void fragment() {
	ALBEDO = mix(bottom.rgb, top.rgb, smoothstep(-0.4, 0.6, ny));
}
"""

static var _sh := {}
static var _tex := {}

static func shader(name: String) -> Shader:
	if not _sh.has(name):
		var s := Shader.new()
		s.code = { "terrain": TERRAIN, "paint": PAINT, "leaf": LEAF, "water": WATER, "cloud": CLOUD }[name]
		_sh[name] = s
	return _sh[name]

static func noise_tex() -> Texture2D:
	if not _tex.has("noise"):
		var n := FastNoiseLite.new()
		n.frequency = 0.04
		n.fractal_octaves = 3
		var img := n.get_seamless_image(256, 256)
		img.convert(Image.FORMAT_RGB8)
		img.generate_mipmaps()
		_tex.noise = ImageTexture.create_from_image(img)
	return _tex.noise

static func mat(name: String, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader(name)
	if name in ["terrain", "water"]:
		m.set_shader_parameter("noise_tex", noise_tex())
	for k in params:
		m.set_shader_parameter(k, params[k])
	return m

## Vertex-coloured toon with an ink outline.
static func paint(ink_w := 0.03, tint := Color.WHITE) -> ShaderMaterial:
	var m := mat("paint", { "tint": tint })
	if ink_w > 0:
		m.next_pass = Look.ink(ink_w)
	return m

# ------------------------------------------------------------------ environment
const SKY_TOP := Color("#3f8fe0")
const SKY_HORIZON := Color("#c4ecf6")

static func make_environment() -> Environment:
	var e := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = SKY_TOP
	sm.sky_horizon_color = SKY_HORIZON
	sm.sky_curve = 0.12
	sm.ground_bottom_color = Color("#2b77b0")
	sm.ground_horizon_color = SKY_HORIZON
	sm.sun_angle_max = 20.0
	sm.sun_curve = 0.1
	sm.sky_energy_multiplier = 1.0
	sky.sky_material = sm
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color("#bcd6f0")
	e.ambient_light_energy = 0.75
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.05
	e.fog_enabled = true
	e.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	e.fog_density = 0.0016
	e.fog_light_color = Color("#cfe9f7")
	e.fog_sky_affect = 0.0
	e.fog_aerial_perspective = 0.4
	e.glow_enabled = true
	e.glow_intensity = 0.45
	e.glow_bloom = 0.04
	e.glow_hdr_threshold = 1.1
	e.adjustment_enabled = true
	e.adjustment_contrast = 1.05
	e.adjustment_saturation = 1.18
	e.ssao_enabled = true
	e.ssao_radius = 1.2
	e.ssao_intensity = 1.0
	return e

static func make_sun() -> DirectionalLight3D:
	var s := DirectionalLight3D.new()
	s.light_color = Color("#fff1d6")
	s.light_energy = 1.35
	s.shadow_enabled = true
	s.shadow_blur = 1.5
	s.directional_shadow_max_distance = 90.0
	s.rotation = Vector3(deg_to_rad(-48), deg_to_rad(-140), 0)
	return s

## Per-zone grade: bright and warm outdoors, a cooler teal light inside the drowned sanctum.
const GRADE := {
	"open": { "amb_c": Color("#bcd6f0"), "amb": 0.75, "exp": 1.05, "sat": 1.18, "fog_c": Color("#cfe9f7"), "fog": 0.0016 },
	"sanctum": { "amb_c": Color("#9fe0e0"), "amb": 0.8, "exp": 1.0, "sat": 1.22, "fog_c": Color("#a8e0e6"), "fog": 0.0035 },
}

static func grade(e: Environment, k: float) -> void:
	var a: Dictionary = GRADE.open
	var b: Dictionary = GRADE.sanctum
	e.ambient_light_color = a.amb_c.lerp(b.amb_c, k)
	e.ambient_light_energy = lerpf(a.amb, b.amb, k)
	e.tonemap_exposure = lerpf(a.exp, b.exp, k)
	e.adjustment_saturation = lerpf(a.sat, b.sat, k)
	e.fog_light_color = a.fog_c.lerp(b.fog_c, k)
	e.fog_density = lerpf(a.fog, b.fog, k)
