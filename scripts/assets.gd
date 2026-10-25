class_name Assets
extends RefCounted
## Model loading, the toon conversion, and animation retargeting by bone name.
## Every character uses a body definition below; swap the model paths here to change the art.

const KAY_ALIAS := { "idle": "Idle_A", "combatIdle": "2H_Melee_Idle", "run": "Running_A", "walk": "Walking_A", "back": "Walking_B",
	"attack": "1H_Melee_Attack_Chop", "attack2": "Chop", "smash": "Hammer", "cast": "Holding_A", "release": "Throw", "heal": "Use_Item",
	"hit": "Hit_A", "death": "Death_A", "yell": "Idle_B", "spawn": "Spawn_Ground" }
const QUAT_ALIAS := { "idle": "Idle", "combatIdle": "Idle", "run": "Run", "walk": "Walk", "back": "Walk", "attack": "Weapon", "attack2": "Punch",
	"smash": "Jump", "cast": "Idle", "release": "Punch", "heal": "Yes", "hit": "HitReact", "death": "Death", "yell": "Wave", "spawn": "Yes" }
const BAT_ALIAS := { "idle": "Bat_Flying", "combatIdle": "Bat_Flying", "run": "Bat_Flying", "walk": "Bat_Flying", "back": "Bat_Flying",
	"attack": "Bat_Attack", "attack2": "Bat_Attack2", "hit": "Bat_Hit", "death": "Bat_Death" }
## Characters are drawn larger than the sim's collision circles so they hold their own in the 4 m tunnels.
const CHAR_SCALE := 1.0
const LOOPING := ["idle", "combatIdle", "run", "walk", "back", "cast"]

# Animation clips for the KayKit rig, retargeted onto every KayKit character.
const KAY_CLIPS := ["res://assets/anims/anim_general.glb", "res://assets/anims/anim_move.glb", "res://assets/anims/anim_tools.glb",
	"res://assets/anims/anim_knight1.glb", "res://assets/anims/skeleton_warrior.gltf"]

const BODIES := {
	"sellsword": { "model": "res://assets/chars/Barbarian.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.0,
		"gear": [["handslot.r", "res://assets/props/k_axe.glb", { "scale": 1.15 }], ["handslot.l", "res://assets/props/p_Shield_Wooden.glb", { "rot": Vector3(0, PI / 2, 0), "pos": Vector3(0, 0, 0.05), "scale": 1.6 }]] },
	"cleric": { "model": "res://assets/chars/Knight.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.0,
		"gear": [["handslot.r", "res://assets/anims/anim_knight1.glb#1H_Sword", {}], ["handslot.l", "res://assets/anims/anim_knight1.glb#Round_Shield", {}]] },
	"mage": { "model": "res://assets/chars/Mage.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.0, "gear": [["handslot.r", "@staff", {}]] },
	"footpad": { "model": "res://assets/chars/Rogue_Hooded.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.0, "tint": Color("#9a9aa6"),
		"gear": [["handslot.r", "res://assets/props/p_Sword_Bronze.glb", { "scale": 1.4 }]] },
	"taskmaster": { "model": "res://assets/chars/Rogue_Hooded.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.18, "tint": Color("#c07a70"),
		"gear": [["handslot.r", "res://assets/props/q_sword.glb", { "scale": 0.9 }]] },
	"miner": { "model": "res://assets/chars/Ranger.glb", "alias": KAY_ALIAS, "clips": KAY_CLIPS, "scale": 1.0, "tint": Color("#b8a890"),
		"gear": [["handslot.r", "res://assets/props/q_axe.glb", { "scale": 1.6, "rot": Vector3(0, PI / 2, 0) }]] },
	"gorrak": { "model": "res://assets/chars/orc_brute.glb", "alias": QUAT_ALIAS, "scale": 1.75 },
	"bat": { "model": "res://assets/chars/bat.glb", "alias": BAT_ALIAS, "scale": 0.42 },
}

## Bodies a stage adds at runtime (tinted variants, its own bosses), merged in from the stage's Level._configure().
static var extra_bodies := {}

static func body_def(name: String) -> Dictionary:
	return extra_bodies[name] if extra_bodies.has(name) else BODIES[name]

static var _scenes := {}
static var _libs := {} # body -> AnimationLibrary
static var _props := {} # model name -> Node3D template

static func scene(path: String) -> PackedScene:
	if not _scenes.has(path):
		_scenes[path] = load(path)
	return _scenes[path]

## A prop model by short name (assets/props or assets/dungeon), converted to toon and cached.
static func prop(name: String, ink_w := 0.03) -> Node3D:
	var key := "%s/%s" % [name, ink_w]
	if not _props.has(key):
		var path := "res://assets/dungeon/%s.glb" % name
		if not ResourceLoader.exists(path):
			path = "res://assets/props/%s.glb" % name
		var ps := scene(path)
		if ps == null:
			push_warning("missing prop " + name)
			_props[key] = null
		else:
			var n := ps.instantiate() as Node3D
			Look.apply(n, ink_w)
			_props[key] = n
	var tpl: Node3D = _props[key]
	if tpl == null:
		return Node3D.new()
	return tpl.duplicate() as Node3D

## One mesh pulled out of a model file ("file.glb#NodeName").
static func sub_mesh(spec: String) -> Node3D:
	var parts := spec.split("#")
	var root := scene(parts[0]).instantiate()
	var found := root.find_child(parts[1], true, false) as Node3D
	var out := Node3D.new()
	if found:
		var copy := found.duplicate() as Node3D
		copy.transform = Transform3D.IDENTITY
		out.add_child(copy)
		Look.apply(out)
	root.free()
	return out

static func skeleton_of(root: Node) -> Skeleton3D:
	var s := root.find_children("*", "Skeleton3D", true, false)
	return s[0] if s.size() else null

## Build (once per body) an AnimationLibrary whose tracks point at this model's skeleton.
static func library_for(body: String, model: Node) -> AnimationLibrary:
	if _libs.has(body):
		return _libs[body]
	var def: Dictionary = body_def(body)
	var lib := AnimationLibrary.new()
	var sk := skeleton_of(model)
	var alias: Dictionary = def.alias
	var wanted := {}
	for k in alias:
		wanted[alias[k]] = k
	if def.has("clips") and sk:
		var sk_path := str(model.get_path_to(sk))
		for path in def.clips:
			var src := scene(path).instantiate()
			var ap := src.find_children("*", "AnimationPlayer", true, false)
			if ap.is_empty():
				src.free()
				continue
			var player: AnimationPlayer = ap[0]
			for an in player.get_animation_list():
				var clip := an.get_slice("/", an.get_slice_count("/") - 1)
				if not wanted.has(clip) or lib.has_animation(wanted[clip]):
					continue
				var a := player.get_animation(an).duplicate(true) as Animation
				for t in range(a.get_track_count() - 1, -1, -1):
					var tp := a.track_get_path(t)
					var bone := str(tp.get_concatenated_subnames())
					if bone == "" or sk.find_bone(bone) < 0:
						a.remove_track(t)
						continue
					# only the hips keep their translation; other bones would stretch between rigs
					if a.track_get_type(t) == Animation.TYPE_POSITION_3D and bone != "hips":
						a.remove_track(t)
						continue
					a.track_set_path(t, NodePath("%s:%s" % [sk_path, bone]))
				lib.add_animation(wanted[clip], a)
			src.free()
	else:
		# the model carries its own clips (Quaternius)
		var ap := model.find_children("*", "AnimationPlayer", true, false)
		if ap.size():
			var player: AnimationPlayer = ap[0]
			var root_node := player.get_node(player.root_node)
			for an in player.get_animation_list():
				var clip := an.get_slice("/", an.get_slice_count("/") - 1)
				if not wanted.has(clip) or lib.has_animation(wanted[clip]):
					continue
				var a := player.get_animation(an).duplicate(true) as Animation
				for t in a.get_track_count():
					var n := root_node.get_node_or_null(NodePath(str(a.track_get_path(t)).get_slice(":", 0)))
					if n:
						var sub := str(a.track_get_path(t).get_concatenated_subnames())
						a.track_set_path(t, NodePath("%s:%s" % [model.get_path_to(n), sub]))
				lib.add_animation(wanted[clip], a)
	# alias any logical animation the model lacks to one it has
	for k in alias:
		if not lib.has_animation(k):
			for fallback in ["idle", "attack"]:
				if lib.has_animation(fallback):
					lib.add_animation(k, lib.get_animation(fallback))
					break
	for k in LOOPING:
		if lib.has_animation(k):
			lib.get_animation(k).loop_mode = Animation.LOOP_LINEAR
	_libs[body] = lib
	return lib

static func make_staff() -> Node3D:
	var tn := Node3D.new()
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.height = 2.3
	cm.top_radius = 0.045
	cm.bottom_radius = 0.06
	cm.radial_segments = 8
	shaft.mesh = cm
	shaft.material_override = Look.toon(Color("#5b3a22"))
	shaft.position.y = 0.4
	tn.add_child(shaft)
	var knot := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.07
	tm.outer_radius = 0.14
	knot.mesh = tm
	knot.material_override = Look.toon(Color("#c99a3c"))
	knot.position.y = 1.5
	tn.add_child(knot)
	var gem := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	sm.radial_segments = 6
	sm.rings = 3
	gem.mesh = sm
	var gm := Look.toon(Color("#9fd2ff"))
	gm.set_shader_parameter("emission", Color(0.25, 0.55, 1.0) * 2.0)
	gem.material_override = gm
	gem.position.y = 1.72
	gem.name = "Gem"
	tn.add_child(gem)
	tn.position = Vector3(0, -0.3, 0)
	return tn

## Build a character: the model, its gear on the hand bones and an AnimationPlayer with its clips.
static func character(body: String) -> Dictionary:
	var def: Dictionary = body_def(body)
	var model := scene(def.model).instantiate() as Node3D
	var lib := library_for(body, model)
	for old in model.find_children("*", "AnimationPlayer", true, false):
		old.get_parent().remove_child(old)
		old.free()
	var sk := skeleton_of(model)
	# Quaternius rigs sit under a 100x armature node with centimetre meshes: scale the ink to match
	var unit := 1.0
	var n: Node = sk
	while n and n != model:
		if n is Node3D:
			unit *= (n as Node3D).scale.x
		n = n.get_parent()
	Look.apply(model, 0.02 / maxf(unit, 0.0001), def.get("tint", Color.WHITE))
	for g in def.get("gear", []):
		if sk == null or sk.find_bone(g[0]) < 0:
			continue
		var att := BoneAttachment3D.new()
		att.bone_name = g[0]
		sk.add_child(att)
		var item: Node3D
		var src: String = g[1]
		if src == "@staff":
			item = make_staff()
		elif "#" in src:
			item = sub_mesh(src)
		else:
			item = scene(src).instantiate() as Node3D
			Look.apply(item, 0.02)
		var o: Dictionary = g[2]
		if o.has("rot"):
			item.rotation = o.rot
		if o.has("pos"):
			item.position = o.pos
		if o.has("scale"):
			item.scale = Vector3.ONE * o.scale
		att.add_child(item)
	var ap := AnimationPlayer.new()
	ap.name = "Anim"
	model.add_child(ap)
	ap.root_node = ap.get_path_to(model)
	ap.add_animation_library("", lib)
	model.scale = Vector3.ONE * def.get("scale", 1.0) * CHAR_SCALE
	return { "root": model, "anim": ap, "skeleton": sk }
