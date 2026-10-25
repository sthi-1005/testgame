class_name CoastData
## Tidecrown Ruins: enemy types and the character bodies they use (tinted variants of the shared CC0 models).

const ENEMIES := {
	"raider": { "name": "Saltfang Raider", "body": "coast_raider", "lvl": 5, "hp": 210, "dmg": [9, 14], "swing": 1.8, "speed": 6.6, "r": 0.8, "armor": 80 },
	"tidecaller": { "name": "Saltfang Tidecaller", "body": "coast_tidecaller", "lvl": 6, "hp": 240, "dmg": [10, 15], "swing": 2.2, "speed": 6.2, "r": 0.8, "armor": 50 },
	"sentry": { "name": "Drowned Sentry", "body": "coast_sentry", "lvl": 6, "hp": 280, "dmg": [11, 16], "swing": 2.2, "speed": 5.6, "r": 0.85, "armor": 140 },
	"gull": { "name": "Saltwing", "body": "coast_gull", "lvl": 5, "hp": 70, "dmg": [4, 7], "swing": 1.3, "speed": 9.0, "r": 0.7, "armor": 0, "fly": 3.0 },
	"corsair": { "name": "Captain Marrow Vell", "body": "coast_corsair", "lvl": 6, "hp": 520, "dmg": [14, 20], "swing": 2.0, "speed": 6.4, "r": 1.0, "armor": 150, "elite": true },
	"brineling": { "name": "Brineling", "body": "coast_brineling", "lvl": 5, "hp": 60, "dmg": [4, 7], "swing": 1.4, "speed": 7.5, "r": 0.7, "armor": 0, "summon": true, "fly": 1.4 },
	"ondrak": { "name": "Ondrak the Brinewarden", "body": "coast_ondrak", "lvl": 7, "hp": 3200, "dmg": [26, 34], "swing": 2.4, "speed": 6.0, "r": 1.8, "armor": 170, "boss": "ondrak", "aggro": 16.0 },
}

const BODIES := {
	"coast_raider": { "model": "res://assets/chars/Rogue_Hooded.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.0, "tint": Color("#f0a07c"),
		"gear": [["handslot.r", "res://assets/props/p_Sword_Bronze.glb", { "scale": 1.4 }]] },
	"coast_tidecaller": { "model": "res://assets/chars/Mage.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.0, "tint": Color("#7fb8f0"),
		"gear": [["handslot.r", "@staff", {}]] },
	"coast_sentry": { "model": "res://assets/anims/skeleton_warrior.gltf", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.05, "tint": Color("#a8e8d0"),
		"gear": [["handslot.r", "res://assets/props/q_sword.glb", { "scale": 0.9 }]] },
	"coast_corsair": { "model": "res://assets/chars/Barbarian.glb", "alias": Assets.KAY_ALIAS, "clips": Assets.KAY_CLIPS, "scale": 1.18, "tint": Color("#e88a7a"),
		"gear": [["handslot.r", "res://assets/props/k_axe.glb", { "scale": 1.15 }]] },
	"coast_gull": { "model": "res://assets/chars/bat.glb", "alias": Assets.BAT_ALIAS, "scale": 0.42, "tint": Color("#ffd9c7") },
	"coast_brineling": { "model": "res://assets/chars/bat.glb", "alias": Assets.BAT_ALIAS, "scale": 0.34, "tint": Color("#7fe8ff") },
	"coast_ondrak": { "model": "res://assets/chars/orc_brute.glb", "alias": Assets.QUAT_ALIAS, "scale": 1.95, "tint": Color("#8fe0c8") },
}
