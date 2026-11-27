extends Camera3D
## Spectator camera: free-fly (noclip) or follow a player.
## Free cam: WASD + mouse, Space up, Ctrl/C down, Shift = fast.
## Tab: follow the next fish (Shift+Tab: previous). F: back to free cam.

const SPEED := 9.0
const FAST := 3.0
const SENS := 0.003

var game: Node
var yaw := 0.0
var pitch := -0.5
var follow: Node3D = null
var follow_dist := 7.0


func _ready() -> void:
	fov = 75.0
	position = Vector3(0, 14, 18)
	yaw = 0.0
	pitch = -0.6


func activate() -> void:
	current = true


func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * SENS
		pitch = clampf(pitch - event.relative.y * SENS, -1.5, 1.5)
	elif event is InputEventMouseButton and event.pressed and follow:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			follow_dist = maxf(3.0, follow_dist - 0.7)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			follow_dist = minf(20.0, follow_dist + 0.7)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_cycle(-1 if event.shift_pressed else 1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			follow = null


func _cycle(step: int) -> void:
	if game == null:
		return
	var list: Array = game.get_players().filter(func(p): return not p.out and not p.is_queued_for_deletion())
	if list.is_empty():
		follow = null
		return
	var i := list.find(follow)
	follow = list[posmod(i + step, list.size())]


func following_name() -> String:
	return follow.display_name if follow and is_instance_valid(follow) else ""


func _process(delta: float) -> void:
	if not current:
		return
	if follow and (not is_instance_valid(follow) or follow.out):
		follow = null
	rotation = Vector3(pitch, yaw, 0)
	if follow:
		# Orbit behind the followed fish
		var target := follow.global_position + Vector3(0, 1.4, 0)
		var want := target + Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3(0, 0, follow_dist)
		global_position = global_position.lerp(want, minf(1.0, delta * 8.0))
		return
	var input := Input.get_vector("left", "right", "up", "down")
	var vert := 0.0
	if Input.is_action_pressed("jump"):
		vert += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C):
		vert -= 1.0
	var move := global_basis * Vector3(input.x, 0, input.y) + Vector3.UP * vert
	var spd := SPEED * (FAST if Input.is_action_pressed("sprint") else 1.0)
	global_position += move * spd * delta
