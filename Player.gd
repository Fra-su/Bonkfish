extends CharacterBody3D
## A fish-wielding player. The owning peer simulates it; everyone else sees synced state
## and runs the same procedural animation locally.

const Powerup := preload("res://Powerup.gd")
const Ragdoll := preload("res://Ragdoll.gd")
const Fish := preload("res://Fish.gd")
const KOI_LEN := 5.6                               # Koi.obj length in mesh units (first-person scale ref)
const FISH_AIM := Vector3(0, 0.35, -1)             # head direction in the hand (forward, tilted up)
const MAX_CHARGE := 1.0                            # seconds to fully charge a bonk

const WALK_SPEED = 5.5
const SPRINT_SPEED = 8.5
const JUMP_VELOCITY = 5.5
const SENSITIVITY = 0.003
const BASE_FOV = 75.0
const FOV_CHANGE = 1.5
const SLAP_COOLDOWN = 0.5
const BASE_KNOCK = 6.0
const REACH = 2.4
const CAM_DIST = 4.5

var gravity = 9.8
var speed = WALK_SPEED
var can_slap = true
var is_third_person = true
var pitch := -0.25

# --- synced to other peers ---
var facing := 0.0
var meter := 0.0        # bonk damage: more meter = bigger launches
var fx_mask := 0
var swing_id := 0
var out := false
var ragdolled := false  # true while stunned: floppy limbs + i-frames
var charge := 0.0       # 0 = not charging, else seconds held (bonk wind-up)

var fish_id := 0
var fish: Dictionary
var fish_grip := Vector3.ZERO
var fish_base_scale := 0.16
var charging := false
var was_charging := false

# --- local ---
var game: Node
var display_name := "Fish"
var color := Color.WHITE
var stun := 0.0
var fx_time := {}       # powerup type -> seconds left
var last_hitter := 0
var last_hit_time := -100.0
var jumps := 0
var walk_t := 0.0
var shown_swing := 0
var swing_t := -1.0      # bonk animation progress 0..1, -1 when idle
const SWING_TIME := 0.4
var was_air := false
var shake := 0.0
var flash := 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var hand_mesh = $Head/Camera3D/HandMesh
@onready var fish_item = $Head/Camera3D/FishItem
@onready var anim_player: AnimationPlayer = $Head/Camera3D/FishItem/AnimationPlayer
@onready var human_model: Node3D = $"Human Model"
@onready var collision: CollisionShape3D = $CollisionShape3D
var body: Node3D
var hand: Node3D
var hand_fish: MeshInstance3D
var bubble: MeshInstance3D
var label: Label3D
var overlay: StandardMaterial3D
var ragdoll: Ragdoll


func _ready() -> void:
	game = get_tree().current_scene
	if not (game and game.has_method("report_fall")):
		game = null
	var id := get_multiplayer_authority()
	if Net.players.has(id):
		display_name = Net.players[id]["name"]
		color = Net.players[id]["color"]

	# Visual rig: Body pivot -> human model + a fish held in the right hand.
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	human_model.reparent(body)
	var src: MeshInstance3D = human_model.get_node("Cube_001")
	ragdoll = Ragdoll.new()
	ragdoll.name = "Skeleton"
	body.add_child(ragdoll)
	ragdoll.setup(src, human_model.transform * src.transform)
	overlay = StandardMaterial3D.new()
	overlay.albedo_color = Color(color, 0.45)
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ragdoll.skin_mesh.material_overlay = overlay
	collision_layer = 2      # players
	collision_mask = 1 | 2   # dock + other players (not ragdoll limbs)

	# Fish hand rides the arm bone, so it flops with the ragdoll.
	var attach := BoneAttachment3D.new()
	attach.bone_name = "fore_l"
	ragdoll.add_child(attach)
	hand = Node3D.new()
	hand.position = Vector3(0.16, -0.25, 0.02)  # wrist (fore_l end, A-pose)
	attach.add_child(hand)
	# Chosen fish, held by the tail (grip + orientation worked out from the mesh shape).
	if Net.players.has(id):
		fish_id = Net.players[id].get("fish", 0)
	fish = Fish.stats(fish_id)
	var hold := Fish.hold_info(fish_id, FISH_AIM)
	fish_grip = hold["grip"]
	fish_base_scale = fish["length"] / hold["len"]
	hand_fish = MeshInstance3D.new()
	hand_fish.mesh = hold["mesh"]
	hand_fish.basis = hold["basis"].scaled(Vector3.ONE * fish_base_scale)
	_place_fish_grip()
	hand.add_child(hand_fish)
	# First-person view model uses the same fish (pack shares Koi's orientation).
	var fp_mesh: MeshInstance3D = $Head/Camera3D/FishItem/FishMesh
	fp_mesh.mesh = hold["mesh"]
	fp_mesh.basis = fp_mesh.basis.scaled(Vector3.ONE * (KOI_LEN / hold["len"]) * (fish["length"] / 0.9))

	bubble = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.2
	sm.height = 2.4
	bubble.mesh = sm
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.55, 0.8, 1.0, 0.28)
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.rim_enabled = true
	bm.rim = 1.0
	bubble.material_override = bm
	bubble.position.y = 1.0
	bubble.visible = false
	add_child(bubble)

	label = Label3D.new()
	label.position.y = 2.4
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 44
	label.outline_size = 12
	label.pixel_size = 0.006
	label.modulate = color
	add_child(label)

	# Network sync
	var cfg := SceneReplicationConfig.new()
	for prop in ["position", "velocity", "facing", "meter", "fx_mask", "swing_id", "out", "ragdolled", "charge"]:
		var path := NodePath(".:" + prop)
		cfg.add_property(path)
		var always: bool = prop == "position" or prop == "velocity"
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS if always \
			else SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	var sync := MultiplayerSynchronizer.new()
	sync.name = "Sync"
	sync.replication_config = cfg
	sync.set_multiplayer_authority(id)
	add_child(sync)

	camera.current = is_multiplayer_authority()
	if is_multiplayer_authority():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		label.visible = false
	else:
		hand_mesh.visible = false
		fish_item.visible = false
	_apply_view()


func _set_own_visuals_layer(first_person: bool) -> void:
	for mi in [ragdoll.skin_mesh, hand_fish]:
		mi.set_layer_mask_value(1, not first_person)
		mi.set_layer_mask_value(2, first_person)


func _apply_view() -> void:
	var fp := is_multiplayer_authority() and not is_third_person
	_set_own_visuals_layer(fp)
	if is_multiplayer_authority():
		hand_mesh.visible = fp
		fish_item.visible = fp


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		head.rotate_y(-event.relative.x * SENSITIVITY)
		pitch = clampf(pitch - event.relative.y * SENSITIVITY, deg_to_rad(-80), deg_to_rad(70))
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Tap = quick bonk. Hold = wind up a charged bonk (up to 2x power), release to swing.
		if event.pressed and can_slap and not out and not _frozen() and stun <= 0.0:
			charging = true
			charge = 0.0
		elif not event.pressed and charging:
			charging = false
			var c := charge
			charge = 0.0
			_do_slap(c)
	elif event.is_action_pressed("View_toggle"):
		is_third_person = not is_third_person
		_apply_view()


func has_fx(t: int) -> bool:
	return fx_mask & (1 << t) != 0


func _frozen() -> bool:
	return game != null and game.state == "countdown"


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or out:
		return
	var gm: float = game.gravity_mult if game else 1.0
	var fric: float = game.friction if game else 1.0

	stun = maxf(0.0, stun - delta)
	ragdolled = stun > 0.0
	shake = maxf(0.0, shake - delta)
	var changed := false
	for k in fx_time.keys():
		fx_time[k] -= delta
		if fx_time[k] <= 0.0:
			fx_time.erase(k)
			changed = true
	if changed:
		_recalc_fx()

	if is_on_floor():
		jumps = 0
	else:
		velocity.y -= gravity * gm * delta

	var spring := has_fx(Powerup.SPRING)
	if Input.is_action_just_pressed("jump") and not _frozen() and stun <= 0.0:
		if is_on_floor():
			velocity.y = JUMP_VELOCITY * (1.35 if spring else 1.0)
			jumps = 1
		elif spring and jumps < 2:
			velocity.y = JUMP_VELOCITY * 1.15
			jumps = 2

	if charging:
		if stun > 0.0 or out:
			charging = false
			charge = 0.0
		else:
			charge = minf(charge + delta, MAX_CHARGE)
	speed = SPRINT_SPEED if Input.is_action_pressed("sprint") else WALK_SPEED
	speed *= fish["speed"]
	if has_fx(Powerup.ZOOM):
		speed *= 1.6
	if charge > 0.15:
		speed *= 0.6  # winding up slows you down
	var input_dir := Vector2.ZERO if _frozen() else Input.get_vector("left", "right", "up", "down")
	var dir := (head.global_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if stun > 0.0:
		# Launched: barely any control, let the bonk carry you.
		velocity.x += dir.x * speed * delta * 1.5
		velocity.z += dir.z * speed * delta * 1.5
		if is_on_floor():
			velocity.x = lerpf(velocity.x, 0.0, delta * 2.0 * fric)
			velocity.z = lerpf(velocity.z, 0.0, delta * 2.0 * fric)
	elif is_on_floor():
		var k := minf(1.0, delta * 12.0 * fric)
		velocity.x = lerpf(velocity.x, dir.x * speed, k)
		velocity.z = lerpf(velocity.z, dir.z * speed, k)
	else:
		velocity.x = lerpf(velocity.x, dir.x * speed, delta * 3.0)
		velocity.z = lerpf(velocity.z, dir.z * speed, delta * 3.0)

	move_and_slide()
	facing = head.rotation.y

	# Rogue boat
	if game and stun <= 0.0 and game.state == "fight":
		var bd: Vector3 = game.boat_hit(global_position)
		if bd != Vector3.ZERO:
			receive_bonk(bd, 1.7, 0)

	if global_position.y < Game_FALL_Y():
		if game and game.state == "fight":
			out = true
			velocity = Vector3.ZERO
			var recent := Time.get_ticks_msec() / 1000.0 - last_hit_time < 6.0
			game.report_fall.rpc_id(1, last_hitter if recent else 0)
			game.on_local_out()
		else:
			global_position = game.spawn_point(get_multiplayer_authority()) if game else Vector3(0, 3, 0)
			velocity = Vector3.ZERO

	# Powerup pickups (server confirms)
	if game:
		for pu in game.powerups.values():
			if not pu.requested and pu.global_position.distance_to(global_position + Vector3(0, 1, 0)) < 1.4:
				pu.requested = true
				game.request_pickup.rpc_id(1, pu.pid)


## Keep the tail stalk in the fist (also when MEGA scales the fish up).
func _place_fish_grip() -> void:
	hand_fish.position = -(hand_fish.basis * fish_grip)


func Game_FALL_Y() -> float:
	return game.FALL_Y if game else -10.0


func _do_slap(held := 0.0) -> void:
	if not can_slap or out or _frozen():
		return
	can_slap = false
	var charged := held > 0.15
	swing_id += 1
	anim_player.stop()
	anim_player.play("slap")
	# A charged swing is already wound up, so it lands sooner.
	var hit_delay := 0.06 if charged else 0.14
	await get_tree().create_timer(hit_delay).timeout
	_hit_check(1.0 + (held / MAX_CHARGE if charged else 0.0))
	await get_tree().create_timer(maxf(0.05, fish["cooldown"] - hit_delay)).timeout
	can_slap = true


func _hit_check(charge_mult := 1.0) -> void:
	if game == null:
		return
	var fwd := -head.global_basis.z
	fwd.y = 0
	fwd = fwd.normalized()
	var mega := has_fx(Powerup.MEGA)
	var reach: float = REACH * fish["reach"] * (1.4 if mega else 1.0)
	var run_bonus := 1.0
	if fish["name"] == "Anglerfish":  # hits harder the faster you're moving
		run_bonus = 1.0 + clampf(Vector2(velocity.x, velocity.z).length() / SPRINT_SPEED, 0.0, 1.0) * 0.7
	for p in game.get_players():
		if p == self or p.out or p.is_queued_for_deletion():
			continue
		var to: Vector3 = p.global_position - global_position
		if absf(to.y) > 2.2:
			continue
		var flat := Vector3(to.x, 0, to.z)
		var d := flat.length()
		if d > reach or (d > 0.7 and fwd.dot(flat / d) < 0.3):
			continue
		var kdir := flat / d if d > 0.05 else fwd
		var power: float = (2.0 if mega else 1.0) * game.knock_mult * fish["power"] * charge_mult * run_bonus
		p.receive_bonk.rpc_id(p.get_multiplayer_authority(), kdir, power, multiplayer.get_unique_id())
		shake = maxf(shake, 0.12)


@rpc("any_peer", "call_local", "reliable")
func receive_bonk(dir: Vector3, power: float, attacker: int) -> void:
	if not is_multiplayer_authority() or out or stun > 0.0:
		return  # i-frames while ragdolled
	if has_fx(Powerup.BUBBLE):
		fx_time.erase(Powerup.BUBBLE)
		_recalc_fx()
		velocity += dir * 3.0
		_bonk_fx.rpc(true)
		return
	var resist := 0.35 if has_fx(Powerup.ANCHOR) else 1.0
	var mag := BASE_KNOCK * (1.0 + meter) * power * resist
	velocity = dir * mag + Vector3.UP * (3.5 + mag * 0.3)
	meter += 0.15 * power * (0.5 if resist < 1.0 else 1.0)
	stun = clampf(0.7 + meter * 0.3, 0.7, 1.6)
	ragdolled = true
	last_hitter = attacker
	last_hit_time = Time.get_ticks_msec() / 1000.0
	shake = 0.35
	_bonk_fx.rpc(false)


@rpc("any_peer", "call_local", "reliable")
func _bonk_fx(blocked: bool) -> void:
	flash = 0.25
	if game:
		game.burst(global_position + Vector3(0, 1.2, 0), Color("bde0fe") if blocked else Color.WHITE, 18)


func apply_powerup(type: int) -> void:
	if type == Powerup.FRESH:
		meter = 0.0
	else:
		fx_time[type] = Powerup.INFO[type]["time"]
	_recalc_fx()


func _recalc_fx() -> void:
	var m := 0
	for k in fx_time:
		m |= 1 << k
	fx_mask = m


func reset_for_round(pos: Vector3) -> void:
	out = false
	if not is_multiplayer_authority():
		return
	global_position = pos
	velocity = Vector3.ZERO
	meter = 0.0
	stun = 0.0
	ragdolled = false
	fx_time.clear()
	_recalc_fx()
	head.rotation.y = atan2(pos.x, pos.z)
	last_hitter = 0


# --- procedural animation (runs on every peer) ---------------------------------

func _process(delta: float) -> void:
	visible = not out
	if collision.disabled != out:
		collision.disabled = out

	var flat_speed := Vector2(velocity.x, velocity.z).length()
	var airborne := absf(velocity.y) > 0.8 or (is_multiplayer_authority() and not is_on_floor())
	var moving := clampf(flat_speed / WALK_SPEED, 0.0, 1.5)
	var tumbling := airborne and (ragdolled or flat_speed > 9.0)
	walk_t += delta * (3.0 + flat_speed * 1.7)

	# Ragdoll on hit (synced flag, so every peer sees the flop)
	if ragdolled and not ragdoll.active:
		ragdoll.start_ragdoll(velocity)
	elif not ragdolled and ragdoll.active:
		ragdoll.stop_ragdoll()

	body.rotation.y = lerp_angle(body.rotation.y, facing, minf(1.0, delta * 18.0))
	if tumbling:
		body.rotation.x = wrapf(body.rotation.x - delta * 7.0, -PI, PI)
		body.rotation.z = lerp_angle(body.rotation.z, 0.0, delta * 5.0)
	else:
		body.rotation.x = lerp_angle(body.rotation.x, 0.0, minf(1.0, delta * 10.0))  # lean is on the spine bone now
		var waddle := 0.0 if airborne else sin(walk_t) * 0.05 * minf(moving, 1.0)
		body.rotation.z = lerp_angle(body.rotation.z, waddle, minf(1.0, delta * 12.0))
	var bob := 0.0 if airborne else absf(sin(walk_t)) * 0.12 * minf(moving, 1.0)
	body.position.y = lerpf(body.position.y, bob, minf(1.0, delta * 15.0))

	# Landing dip (position only - physical bones can't take non-uniform scale)
	if was_air and not airborne:
		body.position.y = -0.12
	was_air = airborne

	# Skeletal animation: walk / jump / bonk
	if swing_id != shown_swing:
		shown_swing = swing_id
		swing_t = 0.3 if was_charging else 0.0  # charged: already wound up, go straight to the slam
	was_charging = charge > 0.15
	if swing_t >= 0.0:
		swing_t += delta / SWING_TIME
		if swing_t > 1.0:
			swing_t = -1.0
	var pose_swing := swing_t
	if was_charging and swing_t < 0.0:
		pose_swing = 0.29 * minf(1.0, (charge - 0.15) / 0.2)  # hold the wind-up pose
	ragdoll.animate(delta, walk_t, moving, airborne, velocity.y, pose_swing)
	var fish_size := fish_base_scale * (2.3 if has_fx(Powerup.MEGA) else 1.0)
	if was_charging:  # quiver as it charges
		fish_size *= 1.0 + charge / MAX_CHARGE * 0.25 + sin(walk_t * 9.0 + charge * 40.0) * 0.03 * charge
	hand_fish.scale = hand_fish.scale.lerp(Vector3.ONE * fish_size, minf(1.0, delta * 8.0))
	_place_fish_grip()
	if is_multiplayer_authority():
		fish_item.scale = Vector3.ONE * (1.6 if has_fx(Powerup.MEGA) else 1.0)

	bubble.visible = has_fx(Powerup.BUBBLE)
	if bubble.visible:
		bubble.scale = Vector3.ONE * (1.0 + sin(walk_t * 0.5) * 0.04)

	flash = maxf(0.0, flash - delta)
	overlay.albedo_color = Color(color, 0.45).lerp(Color(1, 1, 1, 0.9), flash * 4.0)

	var tags := ""
	for k in Powerup.INFO.size():
		if has_fx(k):
			tags += "[" + Powerup.INFO[k]["letter"] + "]"
	label.text = "%s %s\n%d%%" % [display_name, tags, int(meter * 100)]

	if is_multiplayer_authority():
		_update_camera(delta)


func _update_camera(delta: float) -> void:
	var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.4
	camera.rotation.x = pitch
	if is_third_person:
		camera.position = Vector3(0.6, 0.3, 0) + Vector3(0, -sin(pitch), cos(pitch)) * CAM_DIST + jitter
	else:
		camera.position = jitter
	var target_fov := BASE_FOV + FOV_CHANGE * clampf(Vector2(velocity.x, velocity.z).length(), 0.5, SPRINT_SPEED * 2)
	camera.fov = lerpf(camera.fov, target_fov, delta * 8.0)
