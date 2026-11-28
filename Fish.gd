extends RefCounted
## The fish arsenal: stats per fish + automatic "hold it by the tail" placement for any fish mesh.

## cooldown = seconds between swings (raised across the board so you can't chain-stun people).
## special = id handled in Player.gd; special_desc is shown in the lobby.
const LINEUP := [
	{"name": "Koi", "mesh": "res://Fish/OBJ/Koi.obj", "desc": "Balanced",
		"special": "", "special_desc": "",
		"reach": 1.0, "power": 1.0, "cooldown": 0.65, "speed": 1.0, "length": 0.9},
	{"name": "Swordfish", "mesh": "res://Fish/OBJ/Swordfish.obj", "desc": "Long reach, weak hits",
		"special": "pierce", "special_desc": "Pierce: ignores Shield and Anchor",
		"reach": 1.5, "power": 0.8, "cooldown": 0.7, "speed": 1.0, "length": 1.4},
	{"name": "Pufferfish", "mesh": "res://Fish/OBJ/Puffer.obj", "desc": "Short reach, strong hits",
		"special": "puff", "special_desc": "Puff: also pushes everyone close around you",
		"reach": 0.8, "power": 1.5, "cooldown": 0.95, "speed": 0.9, "length": 0.7},
	{"name": "Shark", "mesh": "res://Fish/OBJ/Shark.obj", "desc": "Strong, slow swing",
		"special": "bite", "special_desc": "Bite: hits add extra damage",
		"reach": 1.2, "power": 1.35, "cooldown": 0.9, "speed": 0.85, "length": 1.2},
	{"name": "Tetra", "mesh": "res://Fish/OBJ/Tetra.obj", "desc": "Fast swing, weak hits",
		"special": "dart", "special_desc": "Dart: short speed burst after a hit",
		"reach": 0.75, "power": 0.7, "cooldown": 0.45, "speed": 1.15, "length": 0.55},
	{"name": "Tuna", "mesh": "res://Fish/OBJ/Tuna.obj", "desc": "Slightly stronger",
		"special": "", "special_desc": "",
		"reach": 1.1, "power": 1.15, "cooldown": 0.75, "speed": 0.95, "length": 1.0},
	{"name": "Anglerfish", "mesh": "res://Fish/OBJ/Anglerfish.obj", "desc": "Stronger while running",
		"special": "lure", "special_desc": "Lure: up to +70% power at full sprint",
		"reach": 1.0, "power": 0.9, "cooldown": 0.7, "speed": 1.05, "length": 0.85},
	# Higher-level unlocks (sidegrades, not upgrades)
	{"name": "Goldfish", "mesh": "res://Fish/OBJ/Goldfish.obj", "desc": "Light and quick",
		"special": "lucky", "special_desc": "Lucky: 20% chance of a critical hit (x1.8)",
		"reach": 0.9, "power": 0.85, "cooldown": 0.5, "speed": 1.12, "length": 0.75},
	{"name": "Piranha", "mesh": "res://Fish/OBJ/Piranha.obj", "desc": "Short reach, fast strong hits",
		"special": "bleed", "special_desc": "Bleed: target keeps taking damage for 2 s",
		"reach": 0.7, "power": 1.2, "cooldown": 0.5, "speed": 1.0, "length": 0.6},
	{"name": "Blobfish", "mesh": "res://Fish/OBJ/Blobfish.obj", "desc": "Very strong, very slow",
		"special": "shockwave", "special_desc": "Shockwave: a full charge hits everyone nearby",
		"reach": 0.85, "power": 1.7, "cooldown": 1.1, "speed": 0.8, "length": 0.75},
	{"name": "Lionfish", "mesh": "res://Fish/OBJ/Lionfish.obj", "desc": "Good reach and power, slower feet",
		"special": "venom", "special_desc": "Venom: target moves at half speed for 2.5 s",
		"reach": 1.2, "power": 1.1, "cooldown": 0.75, "speed": 0.92, "length": 1.0},
	{"name": "Goblin Shark", "mesh": "res://Fish/OBJ/GoblinShark.obj", "desc": "Long reach, strong, slow swing",
		"special": "lunge", "special_desc": "Lunge: a charged attack dashes you forward",
		"reach": 1.35, "power": 1.25, "cooldown": 1.0, "speed": 0.88, "length": 1.15},
]

static var _cache := {}


static func stats(i: int) -> Dictionary:
	return LINEUP[clampi(i, 0, LINEUP.size() - 1)]


## Returns {"mesh", "basis", "grip", "len"}: a basis (unscaled) that points the fish's head along
## `aim` with its tall axis up, and the tail-stalk grip point in mesh space.
static func hold_info(i: int, aim: Vector3) -> Dictionary:
	if _cache.has(i):
		return _cache[i]
	var mesh: Mesh = load(stats(i)["mesh"])
	var aabb := mesh.get_aabb()
	var verts := PackedVector3Array()
	for s in mesh.get_surface_count():
		verts.append_array(mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	# Long axis = body; of the other two, the taller one is "up" (fish are flat side to side).
	var ax := 0
	for k in 3:
		if aabb.size[k] > aabb.size[ax]:
			ax = k
	var o1 := (ax + 1) % 3
	var o2 := (ax + 2) % 3
	var up_ax := o1 if aabb.size[o1] >= aabb.size[o2] else o2
	var side_ax := o2 if up_ax == o1 else o1
	# Slice along the body; the tail end is the one whose thickness (side axis) is smallest.
	const N := 10
	var thick := []
	var tall := []
	var mid := []
	for k in N:
		thick.append([1e9, -1e9])
		tall.append([1e9, -1e9])
		mid.append([Vector3.ZERO, 0])
	for v in verts:
		var k := clampi(int((v[ax] - aabb.position[ax]) / aabb.size[ax] * N), 0, N - 1)
		thick[k][0] = minf(thick[k][0], v[side_ax])
		thick[k][1] = maxf(thick[k][1], v[side_ax])
		tall[k][0] = minf(tall[k][0], v[up_ax])
		tall[k][1] = maxf(tall[k][1], v[up_ax])
		mid[k][0] += v
		mid[k][1] += 1
	var w := func(k): return thick[k][1] - thick[k][0] if thick[k][1] > thick[k][0] else 0.0
	var h := func(k): return tall[k][1] - tall[k][0] if tall[k][1] > tall[k][0] else 0.0
	# Every fish in this asset pack faces +Z with its tail fin at -Z (checked by measuring each
	# mesh's profile: thin + tall at -Z, dense head at +Z; Swordfish's bill is the +Z end).
	var tail_low := true
	# Grip on the tail stalk: the thinnest slice in the tail-side third.
	var best := -1
	for k in range(0, 4):
		var kk := k if tail_low else N - 1 - k
		if mid[kk][1] > 0 and (best == -1 or w.call(kk) < w.call(best)):
			best = kk
	var grip: Vector3 = mid[best][0] / mid[best][1]
	# Head direction in mesh space: away from the tail (tail at the low end -> head points +axis).
	var head := Vector3.ZERO
	head[ax] = 1.0 if tail_low else -1.0
	var up := Vector3.ZERO
	up[up_ax] = 1.0
	# Basis mapping mesh head->aim and mesh up->world-ish up.
	var mesh_frame := Basis(up.cross(head), up, head)       # columns: x, y, z(head); right-handed
	var target_frame := Basis.looking_at(-aim, Vector3.UP)  # its +Z points along aim
	var info := {"mesh": mesh, "basis": target_frame * mesh_frame.inverse(),
		"grip": grip, "len": aabb.size[ax]}
	_cache[i] = info
	return info
