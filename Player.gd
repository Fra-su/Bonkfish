extends CharacterBody3D

var speed
const WALK_SPEED = 5.0
const SPRINT_SPEED = 8.0
const JUMP_VELOCITY = 5
const SENSITIVITY = 0.003

const BOB_FREQ = 2.5
const BOB_AMP = 0.06
var t_bob = 0.0

const BASE_FOV = 75.0
const FOV_CHANGE = 1.5

var gravity = 9.8

# Slap state
var can_slap = true
const SLAP_COOLDOWN = 0.6
const SLAP_KNOCKBACK = 12.0

@onready var head: Node3D = $Head
@onready var camera = $Head/Camera3D
@onready var hand_mesh = $Head/Camera3D/HandMesh
@onready var fish_item = $Head/Camera3D/FishItem
@onready var anim_player: AnimationPlayer = $Head/Camera3D/FishItem/AnimationPlayer
@onready var fish_hitbox: Area3D = $Head/Camera3D/FishItem/Area3D

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# Hitbox starts disabled — only active during swing
	fish_hitbox.monitoring = false

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		head.rotate_y(-event.relative.x * SENSITIVITY)
		camera.rotate_x(-event.relative.y * SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-90), deg_to_rad(90))

	# Slap input
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and can_slap:
			_do_slap()

func _do_slap():
	can_slap = false
	anim_player.play("slap")         # plays your swing animation
	fish_hitbox.monitoring = true     # enable hitbox during swing

	# Disable hitbox and reset after cooldown
	await get_tree().create_timer(0.15).timeout
	fish_hitbox.monitoring = false

	await get_tree().create_timer(SLAP_COOLDOWN - 0.15).timeout
	can_slap = true

func _on_fish_hitbox_body_entered(body):
	if body == self:
		return  # don't hit yourself
	if body.has_method("take_slap"):
		# Direction from us to them, then launch them
		var knockback_dir = (body.global_position - global_position).normalized()
		knockback_dir.y = 0.4   # slight upward pop
		body.take_slap(knockback_dir * SLAP_KNOCKBACK)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if Input.is_action_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	if Input.is_action_pressed("sprint"):
		speed = SPRINT_SPEED
	else:
		speed = WALK_SPEED

	var input_dir := Input.get_vector("left", "right", "up", "down")
	var direction := (head.global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if is_on_floor():
		if direction:
			velocity.x = direction.x * speed
			velocity.z = direction.z * speed
		else:
			velocity.x = lerp(velocity.x, direction.x * speed, delta * 7.0)
			velocity.z = lerp(velocity.z, direction.z * speed, delta * 7.0)
	else:
		velocity.x = lerp(velocity.x, direction.x * speed, delta * 4.0)
		velocity.z = lerp(velocity.z, direction.z * speed, delta * 4.0)

	t_bob += delta * velocity.length() * float(is_on_floor())
	camera.transform.origin = _headbob(t_bob)

	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	move_and_slide()

func take_slap(knockback: Vector3):
	velocity += knockback   # other players/dummies call this

func _headbob(time) -> Vector3:
	var pos = Vector3.ZERO
	pos.y = sin(time * BOB_FREQ) * BOB_AMP
	pos.x = cos(time * BOB_FREQ / 2) * BOB_AMP
	return pos
