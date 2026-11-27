extends Node3D
## A floating, spinning pickup. Spawned on every peer by Game.gd.

enum { MEGA, ZOOM, ANCHOR, BUBBLE, SPRING, FRESH }

const INFO := [
	{"name": "MEGA FISH", "letter": "M", "color": Color("ff6b6b"), "time": 8.0, "desc": "Huge fish, double bonk power"},
	{"name": "ZOOM", "letter": "Z", "color": Color("ffd43b"), "time": 8.0, "desc": "Run way faster"},
	{"name": "ANCHOR", "letter": "A", "color": Color("495057"), "time": 8.0, "desc": "Barely budge when bonked"},
	{"name": "BUBBLE", "letter": "B", "color": Color("74c0fc"), "time": 15.0, "desc": "Blocks the next bonk"},
	{"name": "SPRING", "letter": "S", "color": Color("69db7c"), "time": 10.0, "desc": "Big jumps + double jump"},
	{"name": "FRESH", "letter": "+", "color": Color("f783ac"), "time": 0.0, "desc": "Bonk meter reset to 0%"},
]

var type := 0
var pid := 0
var requested := false
var t := 0.0
var orb: MeshInstance3D


func _ready() -> void:
	var info: Dictionary = INFO[type]
	orb = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.4
	sm.height = 0.8
	orb.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = info["color"]
	mat.emission_enabled = true
	mat.emission = info["color"]
	mat.emission_energy_multiplier = 0.6
	mat.roughness = 0.2
	orb.material_override = mat
	add_child(orb)

	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.6
	ring.mesh = tm
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(1, 1, 1, 0.8)
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = rmat
	ring.rotation.x = PI / 2
	orb.add_child(ring)

	var lbl := Label3D.new()
	lbl.text = info["letter"]
	lbl.font_size = 96
	lbl.outline_size = 18
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.pixel_size = 0.006
	orb.add_child(lbl)

	scale = Vector3.ZERO
	create_tween().tween_property(self, "scale", Vector3.ONE, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _process(delta: float) -> void:
	t += delta
	orb.position.y = sin(t * 3.0) * 0.15
	orb.rotation.y += delta * 2.0
