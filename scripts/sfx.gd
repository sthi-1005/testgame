class_name Sfx
extends Node
## Combat sounds, synthesised at startup (no audio files): swing whooshes, flesh and shield hits, the
## parry ring, the enemy wind-up glint. play(name, at) uses a small pool of 3D players.

const RATE := 22050
const POOL := 12

var streams := {}
var players: Array[AudioStreamPlayer3D] = []
var next := 0

func _ready() -> void:
	streams.swing = _whoosh(0.2, 900.0, 0.5)
	streams.heavy_swing = _whoosh(0.34, 520.0, 0.65)
	streams.hit = _thump(0.16, 120.0, 0.55, 0.5)
	streams.heavy_hit = _thump(0.3, 70.0, 0.8, 0.6)
	streams.block = _ring([880.0, 1330.0, 2090.0], 0.28, 0.45, 0.35)
	streams.parry = _ring([1760.0, 2640.0, 3520.0], 0.7, 0.5, 0.15)
	streams.glint = _ring([3000.0, 4500.0], 0.22, 0.22, 0.0)
	streams.roll = _whoosh(0.22, 300.0, 0.35)
	streams.slam = _thump(0.4, 55.0, 0.9, 0.8)
	for i in POOL:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 12.0
		p.max_distance = 60.0
		add_child(p)
		players.append(p)

func play(name: String, at: Vector3, vol_db := 0.0, pitch := 1.0) -> void:
	var st: AudioStreamWAV = streams.get(name)
	if st == null:
		return
	var p := players[next]
	next = (next + 1) % POOL
	p.stream = st
	p.global_position = at
	p.volume_db = vol_db
	p.pitch_scale = pitch * randf_range(0.93, 1.07)
	p.play()

static func _wav(data: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, int(clampf(data[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	return w

## Band-passed noise that swells and falls, its centre sweeping down: a blade through air.
static func _whoosh(dur: float, freq: float, gain: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var d := PackedFloat32Array()
	d.resize(n)
	var lp := 0.0
	var bp := 0.0
	for i in n:
		var k := float(i) / n
		var f := freq * (1.4 - k * 0.8)
		var c := clampf(TAU * f / RATE, 0.0, 1.0)
		lp += (randf_range(-1, 1) - lp) * c
		bp += (lp - bp) * c * 0.5
		d[i] = (lp - bp) * sin(PI * k) * gain * 2.5
	return _wav(d)

## A pitched-down sine thump with a short noise crack on top.
static func _thump(dur: float, freq: float, gain: float, crack: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var d := PackedFloat32Array()
	d.resize(n)
	var ph := 0.0
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var k := float(i) / n
		ph += TAU * freq * (1.0 + 2.0 * exp(-t * 30.0)) / RATE
		lp += (randf_range(-1, 1) - lp) * 0.5
		d[i] = (sin(ph) * exp(-k * 5.0) + lp * crack * exp(-t * 60.0)) * gain
	return _wav(d)

## Inharmonic partials ringing out: shields and steel.
static func _ring(freqs: Array, dur: float, gain: float, noise: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var d := PackedFloat32Array()
	d.resize(n)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for j in freqs.size():
			v += sin(TAU * freqs[j] * t) * exp(-t * (6.0 + j * 4.0) / dur * 0.5) / freqs.size()
		v += randf_range(-1, 1) * noise * exp(-t * 80.0)
		d[i] = v * gain * minf(1.0, t * 2000.0)
	return _wav(d)
