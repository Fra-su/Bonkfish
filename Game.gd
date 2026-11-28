extends Node3D
## Arena, round flow, powerups and HUD. Server makes the decisions; everyone builds the same world.

const PLAYER := preload("res://Player.tscn")
const Powerup := preload("res://Powerup.gd")
const Fish := preload("res://Fish.gd")
const TILE := 3.0
const FALL_Y := -5.0

const MODIFIERS := [
	{"name": "Normal", "desc": ""},
	{"name": "Low Gravity", "desc": ""},
	{"name": "Ice", "desc": "Slippery floor"},
	{"name": "Heavy Hits", "desc": "+50% knockback"},
	{"name": "Small Map", "desc": ""},
	{"name": "More Powerups", "desc": ""},
	{"name": "Crumbling", "desc": "Tiles fall from the start"},
]
enum { CLASSIC, MOON, ICE, MEGA_BONKS, TINY, FRENZY, CRUMBLE }

var modifier := 0
var gravity_mult := 1.0
var friction := 1.0
var knock_mult := 1.0
var state := "waiting"        # waiting / countdown / fight / over

var tiles: Array[Node3D] = []   # static tiles + moving ones (AnimatableBody3D)
var players_node: Node3D
var powerups := {}            # pid -> Powerup node
var next_pid := 0
var alive: Array = []
var ready_peers := {}
var started_with := 0     # players alive when the round began (server)
var started_teams := 0    # teams with fish when the round began (server, Teams mode)
var round_num := 0
var round_time := 0.0
var drop_timer := 0.0
var power_timer := 0.0

var spectator_cam: Camera3D
var banner: Label
var sub_banner: Label
var scoreboard: VBoxContainer
var feed: VBoxContainer
var meter_label: Label
var power_label: Label
var pause_panel: PanelContainer
var end_btn: Button
var ping_label: Label
var special_hud: Label
var tile_mats: Array[StandardMaterial3D] = []
var pad_mat: StandardMaterial3D
var ramp_mat: StandardMaterial3D
var mover_mat: StandardMaterial3D


var room_code := ""   # set by Net before this node enters the tree (node name is "Room_<code>")
var spectator := false   # client is only watching this match
var dropped: Array[int] = []   # server: tiles dropped this round (for late spectators)
var free_cam: Camera3D
var spec_hint: Label


## This room's players: {id: {name, color, score, fish, team}}.
func roster() -> Dictionary:
	return Net.roster(room_code)


## Peer ids in this room.
func members() -> Array:
	return roster().keys()


func settings() -> Dictionary:
	return Net.room_view(room_code)


func is_teams() -> bool:
	return settings().get("mode", Net.MODE_FFA) == Net.MODE_TEAMS


## Wins needed to take the match; 0 = endless (rounds go on until the leader ends it).
func wins_needed() -> int:
	return settings().get("wins", 3)


## Server -> everyone in this room (players + spectators): run `method` here and on their copy
## of this node. (A plain .rpc() would reach players in other rooms too.)
func bc(method: String, args := []) -> void:
	var me := multiplayer.get_unique_id()
	for id in Net.watchers(room_code):
		if id != me:
			callv("rpc_id", [id, method] + args)
	callv(method, args)


func _ready() -> void:
	_build_environment()
	_build_hud()
	players_node = Node3D.new()
	players_node.name = "Players"
	add_child(players_node)
	var ids := members()
	ids.sort()
	for id in ids:
		_spawn_player(id)
	Net.player_left.connect(_on_net_player_left)
	Net.xp_gained.connect(_on_xp)
	_build_map(MAP_DOCK)
	free_cam = preload("res://SpecCam.gd").new()
	free_cam.game = self
	add_child(free_cam)
	if spectator:
		enter_free_cam()
		_watcher_ready.rpc_id(1)
	elif multiplayer.is_server():
		if multiplayer.get_unique_id() in ids:
			_peer_ready()
	else:
		_peer_ready.rpc_id(1)


func enter_free_cam() -> void:
	free_cam.global_position = spectator_cam.global_position
	free_cam.activate()
	spec_hint.visible = true


# --- spectators ------------------------------------------------------------------

## A spectator's Game node is ready: send them the current state, and tell the room's
## players to start syncing their fish to them.
@rpc("any_peer", "reliable")
func _watcher_ready() -> void:
	var id := multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or not Net.is_spectator_of(room_code, id) or not Net.allow(id, 2.0):
		return
	var pus := []
	for pid in powerups:
		pus.append([pid, powerups[pid].type, powerups[pid].position])
	_snapshot.rpc_id(id, modifier, state, round_num, dropped, pus, map_id, map_t)
	bc("_add_watcher", [id])


@rpc("authority", "reliable")
func _snapshot(m: int, st: String, rn: int, drop: Array, pus: Array, map := 0, mt := 0.0) -> void:
	_apply_modifier(m)
	_build_map(map, m == TINY)
	map_t = mt
	for i in drop:
		if i >= 0 and i < tiles.size():
			tiles[i].set_meta("dropping", true)
			(tiles[i].get_meta("cs") as CollisionShape3D).disabled = true
			tiles[i].visible = false
	for p in pus:
		_spawn_powerup(p[0], p[1], p[2])
	state = st
	round_num = rn
	show_banner("Spectating", "%s, round %d" % [settings().get("name", ""), rn], 2.5)


@rpc("authority", "call_local", "reliable")
func _add_watcher(id: int) -> void:
	for p in get_players():
		p.add_watcher(id)


func _apply_modifier(m: int) -> void:
	modifier = m
	gravity_mult = 0.45 if m == MOON else 1.0
	friction = 0.12 if m == ICE else 1.0
	knock_mult = 1.5 if m == MEGA_BONKS else 1.0


# --- world -------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color("4ea8de")
	sm.sky_horizon_color = Color("bde0fe")
	sm.ground_bottom_color = Color("1d5c7a")
	sm.ground_horizon_color = Color("bde0fe")
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("b9d7ea")
	env.ambient_light_energy = 0.45   # was the full bright sky: everything washed out to white
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.9
	env.fog_enabled = true
	env.fog_light_color = Color("bde0fe")
	env.fog_density = 0.006
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 0.85
	sun.shadow_enabled = not OS.has_feature("web")   # shadows are expensive in WebGL
	add_child(sun)

	var water := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(300, 300)
	pm.subdivide_width = 120
	pm.subdivide_depth = 120
	water.mesh = pm
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
uniform vec3 shallow = vec3(0.30, 0.75, 0.90);
uniform vec3 deep = vec3(0.06, 0.32, 0.50);
varying float h;
void vertex() {
	h = sin(VERTEX.x * 0.35 + TIME * 1.4) * 0.25 + cos(VERTEX.z * 0.28 + TIME * 1.1) * 0.25;
	VERTEX.y += h;
}
void fragment() {
	float sparkle = smoothstep(0.92, 1.0, sin(UV.x * 900.0 + TIME * 2.0) * sin(UV.y * 900.0 - TIME * 1.5));
	ALBEDO = mix(deep, shallow, 0.45 + h) + vec3(sparkle * 0.4);
	ROUGHNESS = 0.1;
	SPECULAR = 0.7;
}
"""
	var wm := ShaderMaterial.new()
	wm.shader = sh
	water.material_override = wm
	water.position.y = FALL_Y + 1.0
	add_child(water)

	mover_mat = StandardMaterial3D.new()
	mover_mat.albedo_color = Color("5d8aa8")   # moving platforms: blue-grey, easy to spot
	mover_mat.roughness = 0.6
	ramp_mat = StandardMaterial3D.new()
	ramp_mat.albedo_color = Color("b07d4f")
	ramp_mat.roughness = 0.9
	pad_mat = StandardMaterial3D.new()
	pad_mat.albedo_color = Color("4cd964")
	pad_mat.emission_enabled = true
	pad_mat.emission = Color("4cd964")
	pad_mat.emission_energy_multiplier = 0.4
	for c in [Color("d9b25c"), Color("c4935f"), Color("8a6b52")]:   # floor, floor alt, raised decks / falling
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		tile_mats.append(m)

	spectator_cam = Camera3D.new()
	add_child(spectator_cam)
	spectator_cam.position = Vector3(0, 24, 27)
	spectator_cam.look_at(Vector3.ZERO)


# --- maps --------------------------------------------------------------------------
# Every peer builds the same map from the map id the server sends. Moving parts are driven
# by map_t (time since the round began), so they line up on every screen with no extra traffic.

const MAPS := ["Dock", "Ring", "Islands", "Cross", "Tiers", "Stones", "Fortress", "Skyway", "Spire",
	"Shipwreck", "Falls", "Lighthouse", "Scaffold", "Elevators", "Archipelago", "Peaks", "Atoll"]
enum { MAP_DOCK, MAP_RING, MAP_ISLANDS, MAP_CROSS, MAP_TIERS, MAP_STONES, MAP_FORTRESS, MAP_SKYWAY, MAP_SPIRE,
	MAP_SHIP, MAP_FALLS, MAP_LIGHTHOUSE, MAP_SCAFFOLD, MAP_ELEVATORS, MAP_ARCHI, MAP_PEAKS, MAP_ATOLL }
const PAD_LAUNCH := 15.5   # enough to reach the 8 m Fortress towers
## Physics layer 8: moving tiles players can ride. Only these count as "platforms" for
## CharacterBody3D, so rebuilding the map (freeing static tiles) can't fling anyone.
const RIDE_LAYER := 1 << 7
const SPIRE_STEPS := 10
const PEAKS := [Vector3(-10, 0, 6), Vector3(10, 3, 6), Vector3(0, 6, -10)]   # island centres (y = height)

var map_id := MAP_DOCK
var map_t := 0.0
var movers: Array = []      # [{node, kind, base, ...}]  kind: bob / shuttle / sweeper
var sweepers: Array = []    # [{node, length, height}]
var pads: Array = []        # tiles that launch you upward
var ramps: Array = []       # sloped walkways between levels (never drop)


func _clear_map() -> void:
	for t in tiles:
		t.queue_free()
	tiles.clear()
	dropped.clear()
	for m in movers:
		if is_instance_valid(m["node"]) and not m["node"] in tiles:
			m["node"].queue_free()
	movers.clear()
	sweepers.clear()
	pads.clear()
	for r in ramps:
		r.queue_free()
	ramps.clear()


## A floor tile. `animated` tiles are AnimatableBody3D so players standing on them ride along.
func _add_tile(pos: Vector3, mat: Material, size := TILE - 0.08, animated := false) -> Node3D:
	var body: PhysicsBody3D = AnimatableBody3D.new() if animated else StaticBody3D.new()
	if animated:
		(body as AnimatableBody3D).sync_to_physics = true
		body.collision_layer = 1 | RIDE_LAYER   # players only ride bodies on this layer
	body.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 0.8, size)
	cs.shape = box
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	body.set_meta("cs", cs)
	body.set_meta("mesh", mi)
	add_child(body)
	return body


func _build_map(id: int, tiny := false) -> void:
	_clear_map()
	map_id = id
	map_t = 0.0
	# Flat classics (Dock, Ring, Islands, Cross), height maps (Tiers, Stones) and layered maps
	# with decks + ramps (Fortress, Skyway) where position actually matters.
	var n := 6
	for x in range(-n, n + 1):
		for z in range(-n, n + 1):
			var p := Vector3(x * TILE, -0.4, z * TILE)
			var d := Vector2(p.x, p.z).length()
			var mat: Material = tile_mats[(x + z + 100) % 2]
			match id:
				MAP_DOCK:
					if d <= (8.5 if tiny else 14.0):
						tiles.append(_add_tile(p, mat))
				MAP_RING:
					if d > 6.0 and d <= 14.5:
						tiles.append(_add_tile(p, mat))
				MAP_ISLANDS:
					var on_a := Vector2(p.x + 10.0, p.z).length() <= 6.0
					var on_b := Vector2(p.x - 10.0, p.z).length() <= 6.0
					if on_a or on_b or (z == 0 and absi(x) <= 1):
						tiles.append(_add_tile(p, mat))
				MAP_CROSS:
					if absi(x) <= 1 or absi(z) <= 1:
						tiles.append(_add_tile(p, mat))
				MAP_TIERS:
					if d <= 14.0:
						p.y += 1.2 * float(maxi(0, 4 - maxi(absi(x), absi(z))))   # 5 square rings, 1 tile wide: 4.8 ... 0
						var t := _add_tile(p, mat)
						tiles.append(t)
						if maxi(absi(x), absi(z)) >= 4 and (x == 0 or z == 0):
							_make_pad(t)
				MAP_STONES:
					if d <= 14.5 and (x + z) % 2 == 0:
						p.y += 0.9 * posmod(x * 5 + z * 3, 3)
						var s := _add_tile(p, mat, 2.3, true)
						tiles.append(s)
						movers.append({"node": s, "kind": "bob", "base": p,
							"amp": 0.45, "speed": 1.2, "phase": float(x * 7 + z * 3)})
				MAP_FORTRESS, MAP_SKYWAY:
					if absi(x) <= 5 and absi(z) <= 5:   # big flat ground floor
						tiles.append(_add_tile(p, mat))
				MAP_SPIRE:
					if d > 6.5 and d <= 15.0:            # ground ring around the spire
						tiles.append(_add_tile(p, mat))
				MAP_SHIP:
					if absi(z) <= 1 and absi(x) <= 5:   # the hull
						tiles.append(_add_tile(p, mat))
				MAP_FALLS:
					if absi(x) <= 5 and absi(z) <= 4:
						# three ledges stepping down toward -X; a river cuts the low ledge
						if x >= 3:
							p.y += 6.0
						elif x >= 0:
							p.y += 3.0
						elif z == 0:
							continue
						tiles.append(_add_tile(p, mat))
				MAP_LIGHTHOUSE:
					if d > 7.0 and d <= 15.0:            # rocky ring around the tower
						tiles.append(_add_tile(p, mat))
				MAP_SCAFFOLD:
					if absi(x) <= 4 and absi(z) <= 4:    # ground floor of the frame
						tiles.append(_add_tile(p, mat))
				MAP_ELEVATORS:
					if absi(x) <= 4 and absi(z) <= 2:    # ground strip between the two high decks
						tiles.append(_add_tile(p, mat))
				MAP_ARCHI:
					var on := d <= 5.0
					for k in 6:
						var c := Vector2(sin(TAU * k / 6.0), cos(TAU * k / 6.0)) * 13.0
						if Vector2(p.x, p.z).distance_to(c) <= 4.3:
							on = true
					if on:
						tiles.append(_add_tile(p, mat))
				MAP_PEAKS:
					# three islands at 0, 3 and 6 m
					for isl in PEAKS:
						if Vector2(p.x, p.z).distance_to(Vector2(isl.x, isl.z)) <= 5.2:
							p.y += isl.y
							tiles.append(_add_tile(p, mat))
							break
				MAP_ATOLL:
					# broken ring of islets: jump the gaps
					if d > 11.0 and d <= 15.5:
						var sector := posmod(int(floor((atan2(p.x, p.z) + PI) / TAU * 24.0)), 4)
						if sector != 3:   # ~3 m gaps: a running jump clears them
							tiles.append(_add_tile(p, mat))
	match id:
		MAP_RING:
			_add_sweeper(14.5, 0.9, 0.7)
		MAP_CROSS:
			_add_sweeper(9.5, 0.9, 1.0)
		MAP_ISLANDS:
			var base := Vector3(0, -0.4, 9.0)
			var shuttle := _add_tile(base, tile_mats[2], TILE - 0.08, true)
			movers.append({"node": shuttle, "kind": "shuttle", "base": base,
				"axis": Vector3(10.0, 0, 0), "speed": 0.4})
		MAP_SPIRE:
			# 10 floating steps spiralling up around the middle, 1.2 m apart, then a 12 m summit.
			for i in SPIRE_STEPS:
				var a := TAU * i / SPIRE_STEPS
				tiles.append(_add_tile(Vector3(sin(a) * 9.0, 1.2 * (i + 1) - 0.4, cos(a) * 9.0), tile_mats[2]))
			_add_deck(-1, 1, -1, 1, 1.2 * (SPIRE_STEPS + 1))
		MAP_SHIP:
			# Aft deck 2.5 m (ramp from the hull), mast top 7 m (bounce pad), cargo boom circling at 4.5 m.
			_add_deck(4, 5, -1, 1, 2.5)
			_add_ramp(Vector3(3.0, 0, 0), Vector3(10.5, 2.5, 0))
			_add_deck(-1, -1, 0, 0, 7.0)
			_pad_at(Vector3(-9.0, 0, 0))
			_add_mover_tile(Vector3(0, 4.1, 0), {"kind": "orbit", "radius": 7.5, "speed": 0.35, "phase": 0.0})
		MAP_FALLS:
			# Ramps up each ledge, logs bobbing in the river.
			_add_ramp(Vector3(-7.5, 0, -6.0), Vector3(-1.5, 3.0, -6.0))
			_add_ramp(Vector3(1.5, 3.0, 6.0), Vector3(7.5, 6.0, 6.0))
			for x in range(-5, 0):
				_add_mover_tile(Vector3(x * TILE, -0.4, 0), {"kind": "bob", "amp": 0.35, "speed": 1.6,
					"phase": float(x) * 1.3}, 2.4)
			# Raft riding diagonally up the outside of the cliffs, from the low ledge to the top one.
			_add_mover_tile(Vector3(1.5, 2.6, 15.0), {"kind": "shuttle", "axis": Vector3(10.5, 3.0, 0), "speed": 0.35})
		MAP_LIGHTHOUSE:
			# Tower top 12 m. Balcony at 6 m (ramp up from the rocks); elevator up the other side.
			_add_deck(-1, 1, -1, 1, 12.0)
			_add_deck(2, 2, -1, 1, 6.0)
			_add_ramp(Vector3(15.0, 0, 0), Vector3(7.5, 6.0, 0))   # 39 degrees
			_add_mover_tile(Vector3(-6.0, 5.6, 0), {"kind": "shuttle", "axis": Vector3(0, 6.0, 0), "speed": 0.4,
				"phase": -PI / 2})
		MAP_SCAFFOLD:
			# Storey 2 at 3 m (ramps), storey 3 at 6 m (bounce pads on storey 2), a platform circling at 4.5 m.
			for s in [Vector2i(2, 2), Vector2i(-2, 2), Vector2i(2, -2), Vector2i(-2, -2)]:
				_add_deck(s.x, s.x, s.y, s.y, 3.0)
			for s in [Vector2i(0, 3), Vector2i(0, -3), Vector2i(3, 0), Vector2i(-3, 0)]:
				_add_deck(s.x, s.x, s.y, s.y, 3.0)
			_add_ramp(Vector3(0, 0, 3.0), Vector3(0, 3.0, 7.5))
			_add_ramp(Vector3(0, 0, -3.0), Vector3(0, 3.0, -7.5))
			_add_deck(-1, 1, -1, 1, 6.5)
			for t in tiles.duplicate():
				if absf(t.position.y - 2.6) < 0.05 and absf(t.position.x) > 4.0 and absf(t.position.z) > 4.0:
					_make_pad(t)
			_add_mover_tile(Vector3(0, 4.1, 0), {"kind": "orbit", "radius": 9.0, "speed": 0.3, "phase": 0.0})
		MAP_ELEVATORS:
			# Two decks at 8 m joined by a high bridge; an elevator up to each deck.
			_add_deck(-4, 4, 4, 5, 8.0)
			_add_deck(-4, 4, -5, -4, 8.0)
			_add_deck(4, 4, -3, 3, 8.0)
			_add_mover_tile(Vector3(0, 3.6, 9.0), {"kind": "shuttle", "axis": Vector3(0, 4.0, 0), "speed": 0.45})
			_add_mover_tile(Vector3(0, 3.6, -9.0), {"kind": "shuttle", "axis": Vector3(0, 4.0, 0), "speed": 0.45,
				"phase": PI})
		MAP_ARCHI:
			# Three platforms circling between the middle island and the outer ones.
			for k in 3:
				_add_mover_tile(Vector3(0, -0.4, 0), {"kind": "orbit", "radius": 7.0, "speed": 0.28,
					"phase": TAU * k / 3.0})
		MAP_PEAKS:
			# Platforms that travel up and across between the islands.
			for k in 3:
				var a: Vector3 = PEAKS[k]
				var b: Vector3 = PEAKS[(k + 1) % 3]
				var mid := (a + b) * 0.5
				var dir := Vector3(b.x - a.x, 0, b.z - a.z)
				var half := dir.length() * 0.5 - 5.0      # stop at each island's edge
				_add_mover_tile(Vector3(mid.x, mid.y - 0.4, mid.z), {"kind": "shuttle",
					"axis": dir.normalized() * half + Vector3(0, (b.y - a.y) * 0.5, 0), "speed": 0.35,
					"phase": float(k)})
		MAP_ATOLL:
			# Rafts bobbing in the lagoon + one platform circling just inside the ring.
			for k in 4:
				var a := TAU * k / 4.0 + PI / 4.0
				_add_mover_tile(Vector3(sin(a) * 5.0, -0.4, cos(a) * 5.0), {"kind": "bob", "amp": 0.3,
					"speed": 1.4, "phase": float(k)}, 2.6)
			_add_mover_tile(Vector3(0, -0.4, 0), {"kind": "bob", "amp": 0.25, "speed": 1.1, "phase": 0.5})
			_add_mover_tile(Vector3(0, -0.4, 0), {"kind": "orbit", "radius": 9.0, "speed": 0.32, "phase": 0.0})
		MAP_FORTRESS:
			# Central deck 5 m up (you can walk underneath), two long ramps up to it.
			_add_deck(-1, 1, -1, 1, 5.0)
			_add_ramp(Vector3(0, 0, 15.5), Vector3(0, 5.0, 4.5))
			_add_ramp(Vector3(0, 0, -15.5), Vector3(0, 5.0, -4.5))
			# Side balconies 2.5 m up (west and east), each with a ramp from the ground.
			for sx in [-1, 1]:
				_add_deck(5 * sx, 4 * sx, -1, 1, 2.5)
				_add_ramp(Vector3(5.0 * sx, 0, 0), Vector3(10.5 * sx, 2.5, 0))
			# Corner towers 8 m up, only reachable with the bounce pad next to each one.
			for sx in [-1, 1]:
				for sz in [-1, 1]:
					_add_deck(4 * sx, 4 * sx, 4 * sz, 4 * sz, 8.0)
					for t in tiles:
						if is_equal_approx(t.position.x, 3 * TILE * sx) and is_equal_approx(t.position.z, 4 * TILE * sz) \
								and t.position.y < 0.0:
							_make_pad(t)
		MAP_SKYWAY:
			# Two mirrored towers: a mid deck (4.5 m) with a high deck (9 m) stacked over part of it.
			for s in [-1, 1]:
				var lo := Vector2i(-5, -5) if s < 0 else Vector2i(1, 2)
				var hi := Vector2i(-1, -2) if s < 0 else Vector2i(5, 5)
				_add_deck(lo.x, hi.x, lo.y, hi.y, 4.5)                       # mid deck
				var hx := Vector2i(-5, -3) if s < 0 else Vector2i(3, 5)
				var hz := Vector2i(-5, -4) if s < 0 else Vector2i(4, 5)
				_add_deck(hx.x, hx.y, hz.x, hz.y, 9.0)                       # high deck above it
				# ground -> mid deck, along X (reaches the deck's inner edge)
				_add_ramp(Vector3(-6.0 * s, 0, 6.0 * s), Vector3(1.5 * s, 4.5, 6.0 * s))     # 31 degrees
				# mid deck -> high deck, along Z (reaches the high deck's front edge)
				_add_ramp(Vector3(12.0 * s, 4.5, 4.7 * s), Vector3(12.0 * s, 9.0, 10.5 * s))  # 38 degrees
				# Summit 13.5 m up over the high deck, reached with a bounce pad on the high deck.
				_add_deck(5 * s, 5 * s, 5 * s, 5 * s, 13.5)
				for t in tiles:
					if is_equal_approx(t.position.x, 9.0 * s) and is_equal_approx(t.position.z, 12.0 * s) \
							and absf(t.position.y - 8.6) < 0.1:
						_make_pad(t)


## A moving tile you can ride. `m` holds the mover settings (kind + its parameters); the tile
## starts at `pos`, which is also the centre / base of its motion.
func _add_mover_tile(pos: Vector3, m: Dictionary, size := TILE - 0.08) -> Node3D:
	var t := _add_tile(pos, mover_mat, size, true)
	m["node"] = t
	m["base"] = pos
	m["phase"] = m.get("phase", 0.0)
	movers.append(m)
	return t


## Turn the ground tile at this x/z position into a bounce pad.
func _pad_at(pos: Vector3) -> void:
	for t in tiles:
		if is_equal_approx(t.position.x, pos.x) and is_equal_approx(t.position.z, pos.z) \
				and absf(t.position.y - (pos.y - 0.4)) < 0.1:
			_make_pad(t)
			return


func _make_pad(t: Node3D) -> void:
	t.get_meta("mesh").material_override = pad_mat
	pads.append(t)


## A raised deck of tiles (grid index ranges, inclusive) with its top at `top` metres.
func _add_deck(x0: int, x1: int, z0: int, z1: int, top: float) -> void:
	for x in range(mini(x0, x1), maxi(x0, x1) + 1):
		for z in range(mini(z0, z1), maxi(z0, z1) + 1):
			tiles.append(_add_tile(Vector3(x * TILE, top - 0.4, z * TILE), tile_mats[2]))


## A walkable slope from `low` to `high` (positions of the walking surface).
func _add_ramp(low: Vector3, high: Vector3, width := TILE - 0.08) -> void:
	var body := StaticBody3D.new()
	var length := low.distance_to(high)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, 0.4, length + 0.3)
	cs.shape = box
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	mi.material_override = ramp_mat
	body.add_child(mi)
	add_child(body)
	# Surface is the top of the box, so sink it by half its thickness.
	body.global_position = (low + high) * 0.5 + Vector3(0, -0.2, 0)
	body.look_at(body.global_position + (high - low), Vector3.UP)
	ramps.append(body)


## A spinning bar over the center that knocks fish off (a hazard, not a solid wall).
func _add_sweeper(length: float, height: float, speed: float) -> void:
	var pivot := Node3D.new()
	pivot.position = Vector3(0, height, 0)
	add_child(pivot)
	var bar := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(length * 2.0, 0.35, 0.35)
	bar.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("c0392b")
	bar.material_override = mat
	pivot.add_child(bar)
	var hub := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.5
	cm.bottom_radius = 0.6
	cm.height = height + 0.6
	hub.mesh = cm
	hub.material_override = mat
	hub.position.y = -height * 0.5
	pivot.add_child(hub)
	movers.append({"node": pivot, "kind": "sweeper", "speed": speed})
	sweepers.append({"node": pivot, "length": length, "height": height})


func _physics_process(delta: float) -> void:
	if state == "waiting":
		return
	map_t += delta
	for m in movers:
		var node: Node3D = m["node"]
		if not is_instance_valid(node) or node.has_meta("dropping"):
			continue
		match m["kind"]:
			"bob":
				node.position.y = m["base"].y + sin(map_t * m["speed"] + m["phase"]) * m["amp"]
			"shuttle":   # back and forth along an axis (horizontal, vertical = elevator, or diagonal)
				node.position = m["base"] + m["axis"] * sin(map_t * m["speed"] + m.get("phase", 0.0))
			"orbit":     # circles around a centre
				var a: float = map_t * m["speed"] + m["phase"]
				node.position = m["base"] + Vector3(sin(a), 0, cos(a)) * m["radius"]
			"sweeper":
				node.rotation.y = map_t * m["speed"]


## Called by the local player's physics: knock direction if a sweeper arm hits us, else ZERO.
func sweeper_hit(pos: Vector3) -> Vector3:
	for s in sweepers:
		var piv: Node3D = s["node"]
		var arm: Vector3 = piv.global_basis.x
		var rel := pos - piv.global_position
		var along := rel.dot(arm)
		if absf(along) > s["length"] or rel.y < -1.4 or rel.y > 0.6:
			continue
		var side := rel - arm * along
		side.y = 0.0
		if side.length() < 0.75:
			# Push the way the arm is sweeping (it spins counter-clockwise seen from above).
			var sweep_dir := Vector3.UP.cross(arm) * signf(along if along != 0.0 else 1.0)
			return (sweep_dir + Vector3(rel.x, 0, rel.z).normalized() * 0.4).normalized()
	return Vector3.ZERO


## True if the position is standing on a bounce pad.
func on_pad(pos: Vector3) -> bool:
	for t in pads:
		if t.has_meta("dropping"):
			continue
		var rel: Vector3 = pos - t.global_position
		if absf(rel.x) < TILE * 0.5 and absf(rel.z) < TILE * 0.5 and rel.y > 0.2 and rel.y < 0.8:
			return true
	return false


func standing_tiles() -> Array:
	return tiles.filter(func(t): return not t.has_meta("dropping"))


## Spawns spread evenly (by angle) over the map's fixed tiles. Same on every peer.
func spawn_point(id: int) -> Vector3:
	var ids := members()
	ids.sort()
	var i := maxi(ids.find(id), 0)
	var spots: Array = tiles.filter(func(t): return t is StaticBody3D and not t in pads)
	if spots.is_empty():
		spots = tiles
	if spots.is_empty():
		return Vector3(0, 2, 0)
	spots.sort_custom(func(a, b): return atan2(a.position.x, a.position.z) < atan2(b.position.x, b.position.z))
	var pick: Node3D = spots[int(float(i) / maxf(ids.size(), 1) * spots.size()) % spots.size()]
	return pick.position + Vector3(0, 1.9, 0)


# --- players -------------------------------------------------------------------

func _spawn_player(id: int) -> void:
	var p := PLAYER.instantiate()
	p.name = str(id)
	p.set_multiplayer_authority(id)
	p.position = spawn_point(id)
	players_node.add_child(p)


func get_players() -> Array:
	return players_node.get_children()


func get_player(id: int) -> Node:
	return players_node.get_node_or_null(str(id))


func local_player() -> Node:
	return get_player(multiplayer.get_unique_id())


func pname(id: int) -> String:
	if roster().has(id):
		return roster()[id]["name"]
	var p := get_player(id)
	return p.display_name if p else "???"


func _on_xp(amount: int, reason: String, unlocked: Array) -> void:
	add_feed("+%d XP (%s)" % [amount, reason])
	if not unlocked.is_empty():
		show_banner("", "Level %d - unlocked %s" % [Net.account.get("level", 1), ", ".join(unlocked)], 3.0)


func _on_net_player_left(code: String, id: int) -> void:
	if code == room_code:
		_on_player_left(id)


func _on_player_left(id: int) -> void:
	var p := get_player(id)
	if p == null or p.is_queued_for_deletion():
		return  # already handled (a listen-host hears about it twice)
	add_feed("%s left" % p.display_name)
	p.queue_free()
	if multiplayer.is_server():
		alive.erase(id)
		_check_end()


func on_local_out() -> void:
	enter_free_cam()


# --- round flow (server) -------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func _peer_ready() -> void:
	if not multiplayer.is_server():
		return
	var sid := multiplayer.get_remote_sender_id()
	if sid != 0 and (not members().has(sid) or not Net.allow(sid, 2.0)):
		return
	ready_peers[multiplayer.get_remote_sender_id() if multiplayer.get_remote_sender_id() != 0 else 1] = true
	# Only count this room's players (a dedicated server is peer 1 but not a player).
	var all_ready := members().all(func(id): return ready_peers.has(id))
	if all_ready and not members().is_empty() and state == "waiting":
		_server_start_round()


func _server_start_round() -> void:
	var m := CLASSIC if round_num == 0 else randi() % MODIFIERS.size()
	# First round on the classic dock; then a random map (Small Map only shrinks the dock).
	var map := MAP_DOCK if round_num == 0 or m == TINY else randi() % MAPS.size()
	round_num += 1
	bc("_begin_round", [m, map])


@rpc("authority", "call_local", "reliable")
func _begin_round(m: int, map := 0) -> void:
	_apply_modifier(m)
	for pid in powerups.keys():
		powerups[pid].queue_free()
	powerups.clear()
	for b in boats:
		b["node"].queue_free()
	boats.clear()
	boat_timer = randf_range(12.0, 18.0)
	_build_map(map, m == TINY)
	round_time = 0.0
	drop_timer = 0.0
	power_timer = 2.0
	state = "countdown"
	for p in get_players():
		p.reset_for_round(spawn_point(p.name.to_int()))
	var lp := local_player()
	if lp:
		lp.camera.current = true
		spec_hint.visible = false
	_countdown()


func _countdown() -> void:
	show_banner("Round %d" % round_num if round_num > 0 else "", MAPS[map_id])
	await get_tree().create_timer(0.9).timeout
	show_banner(MODIFIERS[modifier]["name"], MODIFIERS[modifier]["desc"])
	await get_tree().create_timer(1.6).timeout
	for n in ["3", "2", "1"]:
		show_banner(n, MODIFIERS[modifier]["desc"])
		await get_tree().create_timer(0.6).timeout
	show_banner("GO", "")
	state = "fight"
	if multiplayer.is_server():
		alive = get_players().map(func(p): return p.name.to_int())
		started_with = alive.size()
		var t := {}
		for id in alive:
			t[team_of(id)] = true
		started_teams = t.size()
	await get_tree().create_timer(0.8).timeout
	if state == "fight":
		show_banner("", "")


func _process(delta: float) -> void:
	_update_hud()
	_update_boats(delta)
	if not multiplayer.is_server() or state != "fight":
		return
	round_time += delta
	# Falling tiles
	var start := 2.0 if modifier == CRUMBLE else 18.0
	if round_time > start:
		drop_timer -= delta
		if drop_timer <= 0.0:
			drop_timer = maxf(0.7, 2.2 - round_time * 0.02)
			var standing := standing_tiles()
			if standing.size() > 2:
				standing.sort_custom(func(a, b): return a.position.length() > b.position.length())
				var pick: Node = standing[randi() % mini(3, standing.size())]
				bc("_drop_tile", [tiles.find(pick)])
	# Boat sweeps
	boat_timer -= delta
	if boat_timer <= 0.0 and round_time > 10.0:
		boat_timer = randf_range(15.0, 24.0)
		bc("_boat_incoming", [randf() * TAU, randf_range(-6.0, 6.0)])
	# Powerups
	power_timer -= delta
	var cap := 8 if modifier == FRENZY else 3
	if power_timer <= 0.0:
		power_timer = 2.0 if modifier == FRENZY else 6.0
		var standing := standing_tiles()
		if powerups.size() < cap and standing.size() > 0:
			var t: Node3D = standing[randi() % standing.size()]
			next_pid += 1
			bc("_spawn_powerup", [next_pid, randi() % Powerup.INFO.size(), t.position + Vector3(0, 1.6, 0)])


@rpc("authority", "call_local", "reliable")
func _drop_tile(i: int) -> void:
	if i < 0 or i >= tiles.size():
		return
	var t := tiles[i]
	if t.has_meta("dropping"):
		return
	t.set_meta("dropping", true)
	if multiplayer.is_server():
		dropped.append(i)
	var mi: MeshInstance3D = t.get_meta("mesh")
	mi.material_override = tile_mats[2]
	var tw := create_tween()
	for k in 8:
		tw.tween_property(mi, "position:x", 0.09 if k % 2 == 0 else -0.09, 0.06)
	tw.tween_callback(func():
		(t.get_meta("cs") as CollisionShape3D).disabled = true
		for pid in powerups.keys():
			if Vector2(powerups[pid].position.x - t.position.x, powerups[pid].position.z - t.position.z).length() < 1.6:
				powerups[pid].queue_free()
				powerups.erase(pid))
	tw.tween_property(t, "position:y", -30.0, 1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


# --- Boat hazard: a rogue boat skims across the dock and launches anyone in its path ---

const BOAT_MESH := preload("res://Fish/OBJ/Boat.obj")
const BOAT_LEN := 6.0
const BOAT_SPEED := 11.0
var boats: Array = []      # [{node, dir, side, dist}]
var boat_timer := 12.0


@rpc("authority", "call_local", "reliable")
func _boat_incoming(angle: float, lateral: float) -> void:
	var dir := Vector3(sin(angle), 0, cos(angle))
	var side := Vector3(dir.z, 0, -dir.x)
	var node := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BOAT_MESH
	var aabb := BOAT_MESH.get_aabb()
	var long_x := aabb.size.x > aabb.size.z
	var s := BOAT_LEN / (aabb.size.x if long_x else aabb.size.z)
	mi.scale = Vector3.ONE * s
	mi.rotation.y = 0.0 if not long_x else -PI / 2  # mesh long axis -> node +Z
	mi.position = -(mi.basis * aabb.get_center()) + Vector3(0, aabb.size.y * s * 0.5 - 0.4, 0)
	node.add_child(mi)
	add_child(node)
	node.global_position = -dir * 40.0 + side * lateral
	node.look_at(node.global_position + dir, Vector3.UP)
	node.rotate_object_local(Vector3.UP, PI)  # +Z forward
	boats.append({"node": node, "dir": dir, "side": side, "dist": 0.0})
	show_banner("", "Boat incoming", 2.5)


func _update_boats(delta: float) -> void:
	for b in boats.duplicate():
		b["dist"] += BOAT_SPEED * delta
		var n: Node3D = b["node"]
		n.global_position += b["dir"] * BOAT_SPEED * delta
		n.position.y = sin(b["dist"] * 0.6) * 0.15
		n.rotation.z = sin(b["dist"] * 0.4) * 0.06
		if b["dist"] > 80.0:
			n.queue_free()
			boats.erase(b)


## Called by the local player's physics: returns a knockback direction if the boat hits us, else ZERO.
func boat_hit(pos: Vector3) -> Vector3:
	for b in boats:
		var rel: Vector3 = pos - (b["node"] as Node3D).global_position
		var along: float = rel.dot(b["dir"])
		var across: float = rel.dot(b["side"])
		if absf(along) < BOAT_LEN * 0.5 and absf(across) < 1.5 and rel.y < 2.5 and rel.y > -1.5:
			return (b["dir"] * 0.7 + b["side"] * signf(across if across != 0.0 else 1.0)).normalized()
	return Vector3.ZERO


@rpc("authority", "call_local", "reliable")
func _spawn_powerup(pid: int, type: int, pos: Vector3) -> void:
	var p := Powerup.new()
	p.type = type
	p.pid = pid
	p.position = pos
	add_child(p)
	powerups[pid] = p


@rpc("any_peer", "call_local", "reliable")
func request_pickup(pid: int) -> void:
	if not multiplayer.is_server() or not powerups.has(pid):
		return
	var who := multiplayer.get_remote_sender_id()
	if who != 0 and (not members().has(who) or not Net.allow(who)):
		return
	bc("_powerup_taken", [pid, who if who != 0 else 1])


@rpc("authority", "call_local", "reliable")
func _powerup_taken(pid: int, who: int) -> void:
	if not powerups.has(pid):
		return
	var n: Node3D = powerups[pid]
	powerups.erase(pid)
	burst(n.global_position, Powerup.INFO[n.type]["color"])
	var p := get_player(who)
	if p and p.is_multiplayer_authority():
		p.apply_powerup(n.type)
		show_banner("", Powerup.INFO[n.type]["name"] + " - " + Powerup.INFO[n.type]["desc"], 1.8)
	n.queue_free()


@rpc("any_peer", "call_local", "reliable")
func report_fall(hitter: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = 1
	if state != "fight" or not alive.has(id) or not Net.allow(id):
		return
	alive.erase(id)
	if started_with > 1:
		Net.add_stat(id, "falls")
		if hitter != id and members().has(hitter):
			Net.add_stat(hitter, "kos")
			Net.add_xp(hitter, Net.AccountsScript.XP_KNOCKOUT, "knockout")
	bc("_player_out", [id, hitter])
	_check_end()


@rpc("authority", "call_local", "reliable")
func _player_out(id: int, hitter: int) -> void:
	var p := get_player(id)
	if p:
		burst(p.global_position + Vector3(0, 1, 0), Color.WHITE, 40)
	if hitter != 0 and hitter != id:
		add_feed("%s knocked out %s" % [pname(hitter), pname(id)])
	else:
		add_feed("%s fell off" % pname(id))


func team_of(id: int) -> int:
	return roster().get(id, {}).get("team", 0)


func _check_end() -> void:
	if state != "fight":
		return
	# Teams: ends when only one team has fish left. FFA: one fish left (also when others quit).
	# Solo practice: when you fall.
	var teams_round := is_teams() and started_teams > 1
	var done := false
	if teams_round:
		var left := {}
		for id in alive:
			left[team_of(id)] = true
		done = left.size() <= 1
	else:
		done = (started_with > 1 and alive.size() <= 1) or alive.size() == 0
	if not done:
		return
	state = "over"
	var winner := -1
	var team := -1
	var scorers := []
	if teams_round:
		if not alive.is_empty():
			team = team_of(alive[0])
			scorers = members().filter(func(id): return team_of(id) == team)
	elif alive.size() == 1:
		winner = alive[0]
		scorers = [winner]
	var match_done := false
	if not scorers.is_empty() and started_with > 1:
		Net.add_score(room_code, scorers)
		var need := wins_needed()   # 0 = endless: never ends on score
		match_done = need > 0 and scorers.any(func(id): return roster().has(id) and roster()[id]["score"] >= need)
	if started_with > 1:   # no XP for solo practice
		var A = Net.AccountsScript
		for id in members():
			var xp: int = A.XP_ROUND
			var why := "round"
			if match_done:
				Net.add_stat(id, "matches")
			if id in scorers:
				Net.add_stat(id, "rounds")
				if match_done:
					Net.add_stat(id, "wins")
				xp += A.XP_ROUND_WIN
				why = "round win"
				if match_done:
					xp += A.XP_MATCH_WIN
					why = "match win"
			Net.add_xp(id, xp, why)
	bc("_round_over", [winner, team])
	await get_tree().create_timer(4.0).timeout
	if not is_inside_tree():
		return
	if match_done:
		bc("_match_over", [winner, team])
		await get_tree().create_timer(6.0).timeout
		if is_inside_tree():
			Net.end_match(room_code)
	else:
		_server_start_round()


@rpc("authority", "call_local", "reliable")
func _round_over(winner: int, team: int) -> void:
	state = "over"
	if team >= 0:
		show_banner("%s team wins the round" % Net.TEAM_NAMES[team], "")
		for p in get_players():
			if team_of(p.name.to_int()) == team and not p.out:
				burst(p.global_position + Vector3(0, 2, 0), Net.TEAM_COLORS[team], 40)
	elif winner == -1:
		show_banner("Draw", "")
	else:
		show_banner("%s wins the round" % pname(winner), "")
		var p := get_player(winner)
		if p:
			burst(p.global_position + Vector3(0, 2, 0), p.color, 60)


@rpc("authority", "call_local", "reliable")
func _match_over(winner: int, team: int) -> void:
	if team >= 0:
		show_banner("%s team wins the match" % Net.TEAM_NAMES[team], "Returning to lobby")
	else:
		show_banner("%s wins the match" % pname(winner), "Returning to lobby")


# --- effects ---------------------------------------------------------------------

func burst(pos: Vector3, color: Color, amount := 24) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = amount
	p.lifetime = 0.8
	p.explosiveness = 1.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 3.0
	p.initial_velocity_max = 7.0
	p.gravity = Vector3(0, -9, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var sm := SphereMesh.new()
	sm.radius = 0.08
	sm.height = 0.16
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.material = mat
	p.mesh = sm
	p.position = pos
	add_child(p)
	p.emitting = true
	get_tree().create_timer(1.5).timeout.connect(p.queue_free)


## Floating text that rises and fades (e.g. "CRIT").
func popup_text(pos: Vector3, text: String, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.modulate = color
	l.font_size = 64
	l.outline_size = 10
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.pixel_size = 0.006
	l.position = pos
	add_child(l)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "position:y", pos.y + 1.2, 0.8)
	tw.tween_property(l, "modulate:a", 0.0, 0.8).set_delay(0.3)
	tw.chain().tween_callback(l.queue_free)


## Expanding flat ring on the ground (shockwave / puff).
func ring(pos: Vector3, radius: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.85
	tm.outer_radius = 1.0
	tm.rings = 32
	mi.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.position = Vector3(pos.x, pos.y + 0.15, pos.z)
	mi.scale = Vector3(0.3, 0.3, 0.3)
	add_child(mi)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(radius, 1.0, radius), 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.chain().tween_callback(mi.queue_free)


# --- HUD -------------------------------------------------------------------------

func _label(size: int, outline := 10) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_color_override("font_outline_color", Color("1d3557"))
	l.add_theme_constant_override("outline_size", outline)
	return l


func _build_hud() -> void:
	var cl := CanvasLayer.new()
	add_child(cl)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Net.make_theme()
	cl.add_child(root)

	banner = _label(60, 8)
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.position = Vector2(-600, 140)
	banner.size = Vector2(1200, 110)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(banner)
	sub_banner = _label(28, 8)
	sub_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	sub_banner.position = Vector2(-600, 250)
	sub_banner.size = Vector2(1200, 40)
	sub_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(sub_banner)

	scoreboard = VBoxContainer.new()
	scoreboard.position = Vector2(24, 20)
	root.add_child(scoreboard)

	feed = VBoxContainer.new()
	feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	feed.position = Vector2(-520, 20)
	feed.size = Vector2(500, 200)
	feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	root.add_child(feed)

	ping_label = _label(16, 5)
	ping_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	ping_label.position = Vector2(-160, -34)
	ping_label.size = Vector2(140, 24)
	ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(ping_label)

	special_hud = _label(17, 5)
	special_hud.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	special_hud.position = Vector2(32, -36)
	special_hud.add_theme_color_override("font_color", Color("ffd166"))
	root.add_child(special_hud)

	meter_label = _label(54, 14)
	meter_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	meter_label.position = Vector2(30, -100)
	root.add_child(meter_label)

	power_label = _label(26, 8)
	power_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	power_label.position = Vector2(-400, -70)
	power_label.size = Vector2(800, 40)
	power_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(power_label)

	var dot := _label(28, 6)
	dot.text = "+"
	dot.set_anchors_preset(Control.PRESET_CENTER)
	dot.position = Vector2(-8, -20)
	dot.visible = not spectator
	root.add_child(dot)

	spec_hint = _label(18, 6)
	spec_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	spec_hint.position = Vector2(-600, -40)
	spec_hint.size = Vector2(1200, 30)
	spec_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spec_hint.visible = false
	root.add_child(spec_hint)

	pause_panel = PanelContainer.new()
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.position = Vector2(-170, -200)
	pause_panel.custom_minimum_size = Vector2(340, 0)
	pause_panel.visible = false
	root.add_child(pause_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	pause_panel.add_child(v)
	var pt := Label.new()
	pt.text = "Paused"
	pt.add_theme_font_size_override("font_size", 26)
	v.add_child(pt)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 15)
	controls.add_theme_color_override("font_color", Color("9fb3c8"))
	controls.text = "Move: WASD\nJump: Space\nSprint: Shift\nAttack: left click (hold to charge)\nCamera: T\nMenu: Esc"
	v.add_child(controls)
	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(_toggle_pause)
	v.add_child(resume)
	end_btn = Button.new()
	end_btn.text = "End match"
	end_btn.pressed.connect(func(): Net.request_end_match(); _toggle_pause())
	v.add_child(end_btn)
	var leave := Button.new()
	leave.text = "Stop spectating" if spectator else "Leave match"
	leave.pressed.connect(func(): Net.leave_match())
	v.add_child(leave)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_toggle_pause()
	elif event is InputEventMouseButton and event.pressed and not pause_panel.visible \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _toggle_pause() -> void:
	pause_panel.visible = not pause_panel.visible
	end_btn.visible = Net.am_leader() and not spectator
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if pause_panel.visible else Input.MOUSE_MODE_CAPTURED


var _banner_tw: Tween
func show_banner(big: String, small: String, hold := 0.0) -> void:
	if big != "" or hold == 0.0:
		banner.text = big
	sub_banner.text = small
	if _banner_tw:
		_banner_tw.kill()
		_banner_tw = null
	if hold > 0.0:
		_banner_tw = create_tween()
		_banner_tw.tween_interval(hold)
		_banner_tw.tween_callback(func(): sub_banner.text = "")


func add_feed(text: String) -> void:
	var l := _label(20, 6)
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.size_flags_horizontal = Control.SIZE_FILL
	feed.add_child(l)
	while feed.get_child_count() > 5:
		feed.get_child(0).free()
	var tw := create_tween()
	tw.tween_interval(5.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func _update_hud() -> void:
	# Scoreboard
	# (Plain ASCII only: the web build's font has no star/bullet glyphs.)
	var r := roster()
	var ids := r.keys()
	ids.sort_custom(func(a, b): return [r[a].get("team", 0), a] < [r[b].get("team", 0), b])
	while scoreboard.get_child_count() < ids.size():
		scoreboard.add_child(_label(22, 7))
	while scoreboard.get_child_count() > ids.size():
		scoreboard.get_child(scoreboard.get_child_count() - 1).free()
	var need := wins_needed()
	for i in ids.size():
		var id = ids[i]
		var p := get_player(id)
		var score: int = r[id]["score"]
		var pips := ("W %d" % score) if need == 0 else "#".repeat(mini(score, need)) + "-".repeat(maxi(0, need - score))
		var tag: String = (Net.TEAM_NAMES[r[id].get("team", 0)] + "  ") if is_teams() else ""
		var l: Label = scoreboard.get_child(i)
		l.text = "[%s]  %s%s  %s" % [pips, tag, r[id]["name"], "(out)" if p and p.out else ""]
		l.add_theme_color_override("font_color", r[id]["color"])
	if Net.ping_ms >= 0:
		ping_label.text = "ping %d ms" % Net.ping_ms
		ping_label.add_theme_color_override("font_color", Color("b7f5b0") if Net.ping_ms < 120 \
			else (Color("ffe08a") if Net.ping_ms < 220 else Color("ff8a8a")))
	# Free cam hint (spectators, and fish that got knocked out)
	if spec_hint.visible:
		var who: String = free_cam.following_name()
		spec_hint.text = ("Following %s (F for free cam)" % who) if who != "" else "Free cam (Tab to follow a player)"
	# Local status
	var lp := local_player()
	meter_label.visible = lp != null and not lp.out
	special_hud.visible = meter_label.visible
	if lp == null:
		return
	var pct := int(lp.meter * 100)
	meter_label.text = "%d%%" % pct
	meter_label.add_theme_color_override("font_color", Color.WHITE.lerp(Color("ff4d4d"), clampf(lp.meter / 1.5, 0, 1)))
	var parts := []
	for k in lp.fx_time:
		parts.append("%s %ds" % [Powerup.INFO[k]["name"], ceili(lp.fx_time[k])])
	if lp.charge > 0.15:
		var c := clampf(lp.charge / lp.MAX_CHARGE, 0.0, 1.0)
		parts.push_front("Charge %d%%" % int(c * 100))
	# Status effects from other fish's specials
	if lp.venom:
		parts.append("Slowed (venom)")
	if lp.bleed:
		parts.append("Bleeding")
	if lp.invuln and not lp.ragdolled:
		parts.append("Protected")
	if lp._dart_t > 0.0:
		parts.append("Dart")
	power_label.text = "   ".join(parts)
	var sp: String = lp.fish["special_desc"]
	special_hud.text = "%s - %s" % [lp.fish["name"], sp] if sp != "" else lp.fish["name"]
