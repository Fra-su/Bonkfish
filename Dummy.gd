extends CharacterBody3D

var gravity = 9.8
var health = 3
var is_stunned = false
const STUN_DURATION = 2.0

@onready var mesh = $MeshInstance3D

func _physics_process(delta):
	if is_stunned:
		# Let physics handle it during stun
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return
	
	# Normal idle standing
	if not is_on_floor():
		velocity.y -= gravity * delta
	move_and_slide()

func take_slap(knockback: Vector3):
	health -= 1
	_enter_stun(knockback)
	if health <= 0:
		await get_tree().create_timer(STUN_DURATION).timeout
		die()

func _enter_stun(knockback: Vector3):
	if is_stunned:
		return
	is_stunned = true
	velocity += knockback

	# Visual feedback — turn red
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color.RED
	mesh.material_override = mat

	await get_tree().create_timer(STUN_DURATION).timeout
	_exit_stun()

func _exit_stun():
	is_stunned = false
	velocity = Vector3.ZERO

	# Back to normal color
	mesh.material_override = null

func die():
	queue_free()
