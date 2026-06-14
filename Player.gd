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
var already_hit = []

# View toggle
var is_third_person = false
const THIRD_PERSON_OFFSET = Vector3(0, 1.5, 3.5)
const FIRST_PERSON_OFFSET = Vector3(0, 0, 0)

@onready var head: Node3D = $Head
@onready var camera = $Head/Camera3D
@onready var hand_mesh = $Head/Camera3D/HandMesh
@onready var fish_item = $Head/Camera3D/FishItem
@onready var anim_player: AnimationPlayer = $Head/Camera3D/FishItem/AnimationPlayer
@onready var fish_hitbox: Area3D = $Head/Camera3D/FishItem/Area3D
@onready var human_model = $"Human Model"

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	fish_hitbox.monitoring = false
	
	for child in human_model.find_children("*", "MeshInstance3D"):
		child.set_layer_mask_value(1, false)
		child.set_layer_mask_value(2, true)

func _unhandled_input(event):
	if event is InputEventMouseMotion:
		head.rotate_y(-event.relative.x * SENSITIVITY)
		camera.rotate_x(-event.relative.y * SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-90), deg_to_rad(90))
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and can_slap:
			_do_slap()
	if event is InputEventKey:
		if event.is_action_pressed("View_toggle"):
			_toggle_view()

func _toggle_view():
	is_third_person = !is_third_person
	if is_third_person:
		camera.position = THIRD_PERSON_OFFSET
		camera.rotation.x = deg_to_rad(-10)
		hand_mesh.visible = false
		fish_item.visible = false
		for child in human_model.find_children("*", "MeshInstance3D"):
			child.set_layer_mask_value(1, true)
			child.set_layer_mask_value(2, false)
	else:
		camera.position = FIRST_PERSON_OFFSET
		camera.rotation.x = deg_to_rad(0)
		hand_mesh.visible = true
		fish_item.visible = true
		for child in human_model.find_children("*", "MeshInstance3D"):
			child.set_layer_mask_value(1, false)
			child.set_layer_mask_value(2, true)

func _do_slap():
	can_slap = false
	already_hit.clear()
	anim_player.play("slap")
	fish_hitbox.monitoring = true

	await get_tree().create_timer(0.15).timeout
	fish_hitbox.monitoring = false

	await get_tree().create_timer(SLAP_COOLDOWN - 0.15).timeout
	can_slap = true

func _on_area_3d_body_entered(body: Node3D) -> void:
	if body == self:
		return
	if body in already_hit:
		return
	already_hit.append(body)
	print("Hit: ", body.name)
	if body.has_method("take_slap"):
		var knockback_dir = (body.global_position - global_position).normalized()
		knockback_dir.y = 0.4
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

	# Rotate model to face direction of travel
	var flat_velocity = Vector3(velocity.x, 0, velocity.z)
	if flat_velocity.length() > 0.1:
		var target_rotation = atan2(flat_velocity.x, flat_velocity.z)
		human_model.rotation.y = lerp_angle(human_model.rotation.y, target_rotation, delta * 10.0)

	t_bob += delta * velocity.length() * float(is_on_floor())
	if not is_third_person:
		camera.transform.origin = _headbob(t_bob)

	var velocity_clamped = clamp(velocity.length(), 0.5, SPRINT_SPEED * 2)
	var target_fov = BASE_FOV + FOV_CHANGE * velocity_clamped
	camera.fov = lerp(camera.fov, target_fov, delta * 8.0)

	move_and_slide()

func take_slap(knockback: Vector3):
	velocity += knockback

func _headbob(time) -> Vector3:
	var pos = Vector3.ZERO
	pos.y = sin(time * BOB_FREQ) * BOB_AMP
	pos.x = cos(time * BOB_FREQ / 2) * BOB_AMP
	return pos
