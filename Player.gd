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
var team := 0
var level := 0           # account level (0 = guest / no accounts)
var skin := 0            # fish colour skin (Accounts.SKINS index)
var sync: MultiplayerSynchronizer
var _last_bonk_from := {}            # attacker id -> time (anti-spam)

# --- anti-stunlock + fish specials ---
const RECOVER_TIME := 0.6            # extra protection after the ragdoll ends
enum { FX_PIERCE = 1, FX_BITE = 2, FX_BLEED = 4, FX_VENOM = 8, FX_CRIT = 16 }
var invuln := false                  # synced: can't be hit (ragdolled or recovering) - everyone sees it
var venom := false                   # synced: slowed by a Lionfish
var bleed := false                   # synced: Piranha bleed ticking
var _recover := 0.0
var _venom_t := 0.0
var _bleed_t := 0.0
var _bleed_tick := 0.0
var _dart_t := 0.0                   # Tetra speed burst
var _fx_tick := 0.0                  # throttle for status particles
var _predicted_at := -100000         # msec when this screen last predicted a hit on this fish
var lure_light: OmniLight3D
const MAX_BONK_POWER := 16.0         # biggest legit power (mega x mega-bonks x heavy fish x charge x run)


# --- Hit prediction -----------------------------------------------------------------
# When you bonk someone, the real launch happens on THEIR machine and only reaches your screen
# a full round trip later (~200 ms from NZ to the server). So your copy of them predicts it:
# it starts flying and flopping right away using the same formula, then the prediction fades
# out as the real synced movement arrives.

const PRED_TIME := 0.45        # how long to trust the prediction before real data must take over
var _pred_off := Vector3.ZERO  # predicted displacement added on top of the synced position
var _pred_vel := Vector3.ZERO
var _pred_t := 0.0


## Same launch formula receive_bonk() uses (velocity for a hit of `power` in `dir`).
func _knockback(dir: Vector3, power: float, pierce := false) -> Vector3:
	var resist := 0.35 if has_fx(Powerup.ANCHOR) and not pierce else 1.0
	var mag := BASE_KNOCK * (1.0 + meter) * power * resist
	return dir * mag + Vector3.UP * (3.5 + mag * 0.3)


## Called on the attacker's machine for the fish it just hit (a remote copy).
func predict_bonk(dir: Vector3, power: float, fx := 0) -> void:
	if is_multiplayer_authority() or out or ragdolled or invuln or _pred_t > 0.0:
		return  # i-frames: the real hit would be ignored too
	var pierce := fx & FX_PIERCE != 0
	var blocked := has_fx(Powerup.BUBBLE) and not pierce
	_hit_visuals(blocked, fx & FX_CRIT != 0)
	_predicted_at = Time.get_ticks_msec()
	if blocked:
		return  # bubble pops, no launch
	_pred_vel = _knockback(dir, minf(power, MAX_BONK_POWER), pierce)
	_pred_off = Vector3.ZERO
	_pred_t = PRED_TIME


func _update_prediction(delta: float) -> void:
	var real_arrived := ragdolled or velocity.length() > 4.0
	if _pred_t > 0.0 and not real_arrived:
		_pred_t -= delta
		_pred_vel.y -= gravity * (game.gravity_mult if game else 1.0) * delta
		_pred_off += _pred_vel * delta
	else:
		_pred_t = 0.0
	# Hand over to the real (synced) motion smoothly instead of snapping.
	if _pred_t <= 0.0 or real_arrived:
		_pred_off = _pred_off.lerp(Vector3.ZERO, minf(1.0, delta * 6.0))


## A spectator joined the room: start replicating this fish to them.
func add_watcher(id: int) -> void:
	if sync:
		sync.set_visibility_for(id, true)
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
var lite := false        # dedicated server copy: no visuals, just synced state

# --- network smoothing ---
var net_pos := Vector3.ZERO    # synced: owner's real position (others smooth toward it)
const SYNC_HZ := 30.0
const SMOOTH := 14.0           # how quickly remote fish catch up to their real position
const SNAP_DIST := 5.0         # teleport instead of sliding when this far off (respawns)


func _ready() -> void:
	# Our room's Game node is two levels up (Room_<code>/Players/<id>). Several rooms can
	# run side by side on a dedicated server, so never use current_scene here.
	game = get_parent().get_parent() if get_parent() else null
	if not (game and game.has_method("report_fall")):
		game = null
	var id := get_multiplayer_authority()
	var info: Dictionary = (game.roster() if game else Net.players).get(id, {})
	display_name = info.get("name", display_name)
	color = info.get("color", color)
	team = info.get("team", 0)
	fish_id = info.get("fish", 0)
	level = info.get("level", 0)
	skin = info.get("skin", 0)

	# A dedicated server never draws anything: skip the skeleton, ragdoll, meshes and labels.
	lite = Net.dedicated
	collision_layer = 2      # players
	collision_mask = 1 | 2   # dock + other players (not ragdoll limbs)
	fish = Fish.stats(fish_id)
	if not lite:
		_build_visuals()

	# Network sync
	var cfg := SceneReplicationConfig.new()
	# Movement streams at 30 Hz (not every frame); everything else only when it changes.
	# Other players' copies glide toward net_pos instead of jumping between updates.
	for prop in ["net_pos", "velocity", "facing", "meter", "fx_mask", "swing_id", "out", "ragdolled", "charge",
			"invuln", "venom", "bleed"]:
		var path := NodePath(".:" + prop)
		cfg.add_property(path)
		var always: bool = prop in ["net_pos", "velocity", "facing"]
		cfg.property_set_replication_mode(path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS if always \
			else SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE)
	net_pos = position
	sync = MultiplayerSynchronizer.new()
	sync.name = "Sync"
	sync.replication_config = cfg
	sync.replication_interval = 1.0 / SYNC_HZ
	sync.delta_interval = 1.0 / SYNC_HZ
	sync.set_multiplayer_authority(id)
	# Only replicate to this room's players (+ the server), not to players in other rooms.
	if game:
		sync.public_visibility = false
		for pid in Net.watchers(game.room_code) + [1]:
			sync.set_visibility_for(pid, true)
	add_child(sync)

	if lite:
		camera.current = false
		set_physics_process(false)
		return
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

	var was_stunned := stun > 0.0
	stun = maxf(0.0, stun - delta)
	ragdolled = stun > 0.0
	if was_stunned and stun <= 0.0:
		_recover = RECOVER_TIME   # a short grace period after getting up: no stunlocks
	_recover = maxf(0.0, _recover - delta)
	invuln = stun > 0.0 or _recover > 0.0
	_update_statuses(delta)
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
	speed = SPRINT_SPEED if Input.is_action_pressed("sprint") and not venom else WALK_SPEED
	speed *= fish["speed"]
	if venom:
		speed *= 0.5
	if _dart_t > 0.0:
		speed *= 1.35
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
	net_pos = global_position

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
	var mult := 1.0 + (held / MAX_CHARGE if charged else 0.0)
	var hit_ids := {}   # each fish can only be hit once per swing
	if fish["special"] == "lunge" and held > 0.3 and stun <= 0.0:
		# Goblin Shark: dash forward, hitting along the way
		var fwd := -head.global_basis.z
		fwd.y = 0
		velocity += fwd.normalized() * 15.0 + Vector3.UP * 2.0
		_room_rpc("_special_fx", ["lunge", global_position])
		await get_tree().create_timer(hit_delay).timeout
		_hit_check(mult, hit_ids)
		await get_tree().create_timer(0.14).timeout
		_hit_check(mult, hit_ids)
		hit_delay += 0.14
	else:
		await get_tree().create_timer(hit_delay).timeout
		_hit_check(mult, hit_ids)
	await get_tree().create_timer(maxf(0.05, fish["cooldown"] - hit_delay)).timeout
	can_slap = true


func _hit_check(charge_mult := 1.0, hit_ids := {}) -> void:
	if game == null:
		return
	var fwd := -head.global_basis.z
	fwd.y = 0
	fwd = fwd.normalized()
	var mega := has_fx(Powerup.MEGA)
	var reach: float = REACH * fish["reach"] * (1.4 if mega else 1.0)
	var special: String = fish["special"]
	var base: float = (2.0 if mega else 1.0) * game.knock_mult * fish["power"] * charge_mult
	if special == "lure":   # Anglerfish: hits harder the faster you're moving
		base *= 1.0 + clampf(Vector2(velocity.x, velocity.z).length() / SPRINT_SPEED, 0.0, 1.0) * 0.7
	var fx := 0
	match special:
		"pierce": fx |= FX_PIERCE
		"bite": fx |= FX_BITE
		"bleed": fx |= FX_BLEED
		"venom": fx |= FX_VENOM
	if special == "lucky" and randf() < 0.2:   # Goldfish: crit
		base *= 1.8
		fx |= FX_CRIT
	var shockwave := special == "shockwave" and charge_mult >= 1.9   # Blobfish: full charge
	if shockwave:
		_room_rpc("_special_fx", ["shockwave", global_position])
	var landed := false
	for p in game.get_players():
		if p == self or p.out or p.is_queued_for_deletion() or hit_ids.has(p):
			continue
		if game.is_teams() and p.team == team:
			continue  # no friendly fire
		var to: Vector3 = p.global_position - global_position
		if absf(to.y) > 2.2:
			continue
		var flat := Vector3(to.x, 0, to.z)
		var d := flat.length()
		var kdir := flat / d if d > 0.05 else fwd
		var power := base
		var in_cone := d <= reach and (d <= 0.7 or fwd.dot(flat / d) >= 0.3)
		if not in_cone:
			if shockwave and d <= 3.8:
				pass                      # everyone around gets the full hit
			elif special == "puff" and d <= 2.6:
				power *= 0.55             # Pufferfish: weaker push all around
			else:
				continue
		hit_ids[p] = true
		landed = true
		p.receive_bonk.rpc_id(p.get_multiplayer_authority(), kdir, power, multiplayer.get_unique_id(), fx)
		p.predict_bonk(kdir, power, fx)   # show the hit now instead of a round trip later
		shake = maxf(shake, 0.12)
	if landed and special == "puff":
		_room_rpc("_special_fx", ["puff", global_position])
	if landed and special == "dart":
		_dart_t = 1.2                     # Tetra: speed burst after a hit


@rpc("any_peer", "call_local", "reliable")
func receive_bonk(dir: Vector3, power: float, attacker: int, fx := 0) -> void:
	if not is_multiplayer_authority() or out or invuln:
		return  # i-frames while ragdolled and for a moment after getting up
	# Don't trust the sender: must be a fish in this room, reasonable numbers, not spamming.
	var from := multiplayer.get_remote_sender_id()
	if from != 0:
		if game == null or not game.members().has(from) or from != attacker:
			return
		var now := Time.get_ticks_msec() / 1000.0
		if now - _last_bonk_from.get(from, -10.0) < 0.2:
			return
		_last_bonk_from[from] = now
	if not (is_finite(dir.x) and is_finite(dir.y) and is_finite(dir.z) and is_finite(power)):
		return
	dir = Vector3(dir.x, 0, dir.z).normalized() if Vector2(dir.x, dir.z).length() > 0.01 else Vector3.FORWARD
	power = clampf(power, 0.0, MAX_BONK_POWER)
	var pierce := fx & FX_PIERCE != 0   # Swordfish ignores Shield and Anchor
	if has_fx(Powerup.BUBBLE) and not pierce:
		fx_time.erase(Powerup.BUBBLE)
		_recalc_fx()
		velocity += dir * 3.0
		_room_rpc("_bonk_fx", [true, false])
		return
	velocity = _knockback(dir, power, pierce)
	var resist := 0.35 if has_fx(Powerup.ANCHOR) and not pierce else 1.0
	meter += 0.15 * power * (0.5 if resist < 1.0 else 1.0)
	if fx & FX_BITE:
		meter += 0.08
	if fx & FX_BLEED:
		_bleed_t = 2.0
	if fx & FX_VENOM:
		_venom_t = 2.5
	stun = clampf(0.7 + meter * 0.3, 0.7, 1.6)
	ragdolled = true
	invuln = true
	last_hitter = attacker
	last_hit_time = Time.get_ticks_msec() / 1000.0
	shake = 0.35
	_room_rpc("_bonk_fx", [false, fx & FX_CRIT != 0])


## Run `method` here and on this player's copy for everyone else in the room.
func _room_rpc(method: String, args := []) -> void:
	var me := multiplayer.get_unique_id()
	for pid in (Net.watchers(game.room_code) if game else []):
		if pid != me:
			callv("rpc_id", [pid, method] + args)
	callv(method, args)


@rpc("any_peer", "call_local", "reliable")
func _bonk_fx(blocked: bool, crit := false) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from != 0 and from != get_multiplayer_authority():
		return
	if Time.get_ticks_msec() - _predicted_at < 1000:
		return   # this screen already showed the hit when it predicted it
	_hit_visuals(blocked, crit)


func _hit_visuals(blocked: bool, crit: bool) -> void:
	flash = 0.25
	if game == null:
		return
	var at := global_position + Vector3(0, 1.2, 0)
	if blocked:
		game.burst(at, Color("bde0fe"), 18)
	elif crit:
		game.burst(at, Color("ffd34d"), 40)
		game.popup_text(at + Vector3(0, 0.6, 0), "CRIT", Color("ffd34d"))
	else:
		game.burst(at, Color.WHITE, 18)


## Visuals for specials (sent by the fish's owner to everyone in the room).
@rpc("any_peer", "call_local", "reliable")
func _special_fx(kind: String, pos: Vector3) -> void:
	var from := multiplayer.get_remote_sender_id()
	if (from != 0 and from != get_multiplayer_authority()) or game == null:
		return
	match kind:
		"shockwave":
			game.ring(pos, 3.8, Color("c9a4ff"))
		"puff":
			game.ring(pos, 2.6, Color("ffe08a"))
		"lunge":
			game.burst(pos + Vector3(0, 1.0, 0), Color("9fb3c8"), 30)


## Status effects on the fish's own machine: venom/bleed/dart timers (synced as flags).
func _update_statuses(delta: float) -> void:
	_venom_t = maxf(0.0, _venom_t - delta)
	_dart_t = maxf(0.0, _dart_t - delta)
	venom = _venom_t > 0.0
	if _bleed_t > 0.0:
		_bleed_t -= delta
		_bleed_tick -= delta
		if _bleed_tick <= 0.0:
			_bleed_tick = 0.5
			meter += 0.035          # Piranha bleed: a little damage every half second
	bleed = _bleed_t > 0.0


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
	net_pos = pos
	velocity = Vector3.ZERO
	meter = 0.0
	stun = 0.0
	ragdolled = false
	_recover = 0.0
	invuln = false
	_venom_t = 0.0
	_bleed_t = 0.0
	_dart_t = 0.0
	venom = false
	bleed = false
	fx_time.clear()
	_recalc_fx()
	head.rotation.y = atan2(pos.x, pos.z)
	last_hitter = 0


# --- procedural animation (runs on every peer) ---------------------------------

func _process(delta: float) -> void:
	visible = not out
	if collision.disabled != out:
		collision.disabled = out

	# Other players: glide toward their latest synced position (+ a little prediction from
	# their velocity) instead of jumping 30 times a second.
	if not is_multiplayer_authority():
		_update_prediction(delta)
		var target := net_pos + velocity * (0.5 / SYNC_HZ) + _pred_off
		if lite or global_position.distance_to(target) > SNAP_DIST:
			global_position = target
		else:
			global_position = global_position.lerp(target, minf(1.0, delta * SMOOTH))
	if lite:
		return

	var flat_speed := Vector2(velocity.x, velocity.z).length()
	var airborne := absf(velocity.y) > 0.8 or (is_multiplayer_authority() and not is_on_floor())
	var moving := clampf(flat_speed / WALK_SPEED, 0.0, 1.5)
	var tumbling := airborne and (ragdolled or flat_speed > 9.0)
	walk_t += delta * (3.0 + flat_speed * 1.7)

	# Ragdoll on hit (synced flag, so every peer sees the flop)
	var floppy := ragdolled or _pred_t > 0.0
	if floppy and not ragdoll.active:
		ragdoll.start_ragdoll(_pred_vel if _pred_t > 0.0 and not ragdolled else velocity)
	elif not floppy and ragdoll.active:
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
	var tint := Color(color, 0.45)
	if venom:
		tint = Color(0.55, 0.15, 0.8, 0.6)            # Lionfish venom: purple
	if invuln and not ragdolled:
		tint.a *= 0.35 + 0.65 * float(int(walk_t * 3.0) % 2)   # blink while protected after getting up
	overlay.albedo_color = tint.lerp(Color(1, 1, 1, 0.9), flash * 4.0)
	# Status particles (throttled)
	_fx_tick -= delta
	if _fx_tick <= 0.0 and game and (bleed or venom):
		_fx_tick = 0.25
		game.burst(global_position + Vector3(0, 1.1, 0), Color("d62839") if bleed else Color("a35cff"), 4)
	if lure_light:
		lure_light.light_energy = 0.6 + 0.6 * clampf(Vector2(velocity.x, velocity.z).length() / SPRINT_SPEED, 0.0, 1.0)

	var tags := ""
	for k in Powerup.INFO.size():
		if has_fx(k):
			tags += "[" + Powerup.INFO[k]["letter"] + "]"
	label.text = "%s%s %s\n%d%%" % [("Lv %d  " % level) if level > 0 else "", display_name, tags, int(meter * 100)]

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


## Everything you can see: skeleton + skinned human, ragdoll, held fish, bubble, name label.
func _build_visuals() -> void:
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
	fish = Fish.stats(fish_id)
	var hold := Fish.hold_info(fish_id, FISH_AIM)
	fish_grip = hold["grip"]
	fish_base_scale = fish["length"] / hold["len"]
	hand_fish = MeshInstance3D.new()
	hand_fish.mesh = hold["mesh"]
	hand_fish.basis = hold["basis"].scaled(Vector3.ONE * fish_base_scale)
	_place_fish_grip()
	hand.add_child(hand_fish)
	if fish["special"] == "lure":   # Anglerfish: its lure glows (brighter the faster you run)
		lure_light = OmniLight3D.new()
		lure_light.light_color = Color("9ff5ff")
		lure_light.omni_range = 2.5
		lure_light.position = Vector3(0, 0.3, -0.5)
		hand.add_child(lure_light)
	var tint: Color = preload("res://Accounts.gd").SKINS[clampi(skin, 0, preload("res://Accounts.gd").SKINS.size() - 1)]["color"]
	var skin_mat: StandardMaterial3D = null
	if tint.a > 0.0:
		skin_mat = StandardMaterial3D.new()
		skin_mat.albedo_color = tint
		skin_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		hand_fish.material_overlay = skin_mat
	# First-person view model uses the same fish (pack shares Koi's orientation).
	var fp_mesh: MeshInstance3D = $Head/Camera3D/FishItem/FishMesh
	fp_mesh.mesh = hold["mesh"]
	fp_mesh.material_overlay = skin_mat
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
