extends Skeleton3D
## Builds a simple 12-bone skeleton for the (unrigged) Human Model, auto-skins the mesh to it,
## and adds physical bones so the limbs can go floppy when the player is bonked.
## Hips stay kinematic (they follow the flying CharacterBody), everything else ragdolls.

# name, parent, start, end  (player space, metres; model faces -Z)
const BONES := [
	# Measured from the mesh: narrow waist ~1.0, shoulders ~1.45, arms hang in an A-pose.
	["hips", "", Vector3(0, 0.78, 0), Vector3(0, 1.05, -0.02)],
	["spine", "hips", Vector3(0, 1.05, -0.02), Vector3(0, 1.48, -0.06)],
	["head", "spine", Vector3(0, 1.52, -0.08), Vector3(0, 1.85, -0.13)],
	["arm_l", "spine", Vector3(0.17, 1.45, -0.07), Vector3(0.34, 1.29, -0.05)],
	["fore_l", "arm_l", Vector3(0.34, 1.29, -0.05), Vector3(0.50, 1.04, -0.03)],
	["arm_r", "spine", Vector3(-0.17, 1.45, -0.07), Vector3(-0.34, 1.29, -0.05)],
	["fore_r", "arm_r", Vector3(-0.34, 1.29, -0.05), Vector3(-0.50, 1.04, -0.03)],
	["thigh_l", "hips", Vector3(0.09, 0.80, 0.05), Vector3(0.09, 0.42, 0.12)],
	["shin_l", "thigh_l", Vector3(0.09, 0.42, 0.12), Vector3(0.09, 0.0, 0.12)],
	["thigh_r", "hips", Vector3(-0.09, 0.80, 0.05), Vector3(-0.09, 0.42, 0.12)],
	["shin_r", "thigh_r", Vector3(-0.09, 0.42, 0.12), Vector3(-0.09, 0.0, 0.12)],
]
const RADII := {"hips": 0.16, "spine": 0.17, "head": 0.12, "arm_l": 0.06, "fore_l": 0.055,
	"arm_r": 0.06, "fore_r": 0.055, "thigh_l": 0.08, "shin_l": 0.07, "thigh_r": 0.08, "shin_r": 0.07}
const A_POSE := 0.75       # rest arm angle below horizontal (shoulder->elbow)
const BONE_LAYER := 4     # physics layer 3: ragdoll limbs
const WORLD_MASK := 1      # collide with the dock only

var sim: PhysicalBoneSimulator3D
var skin_mesh: MeshInstance3D
var bodies: Array[PhysicalBone3D] = []
var active := false
var _fade: Tween


## source: the MeshInstance3D to skin. to_self: transform from that mesh's space into this skeleton's space.
func setup(source: MeshInstance3D, to_self: Transform3D) -> void:
	for b in BONES:
		var i := add_bone(b[0])
		var global_rest := Transform3D(Basis(), b[2])
		if b[1] != "":
			var p := find_bone(b[1])
			set_bone_parent(i, p)
			set_bone_rest(i, get_bone_global_rest(p).affine_inverse() * global_rest)
		else:
			set_bone_rest(i, global_rest)
	reset_bone_poses()
	_build_skin(source, to_self)
	_build_physics()


func _build_skin(source: MeshInstance3D, to_self: Transform3D) -> void:
	var src: Mesh = source.mesh
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var bones_arr := PackedInt32Array()
	var weights := PackedFloat32Array()
	bones_arr.resize(verts.size() * 4)
	weights.resize(verts.size() * 4)
	var nb := to_self.basis.inverse().transposed()
	for vi in verts.size():
		var v := to_self * verts[vi]
		verts[vi] = v
		if normals.size() > vi:
			normals[vi] = (nb * normals[vi]).normalized()
		# two nearest bone segments, inverse-distance weighted
		var best := [[1e9, 0], [1e9, 0]]
		for bi in BONES.size():
			var d := _seg_dist(v, BONES[bi][2], BONES[bi][3])
			if d < best[0][0]:
				best[1] = best[0]
				best[0] = [d, bi]
			elif d < best[1][0]:
				best[1] = [d, bi]
		var w0 := 1.0 / pow(best[0][0] + 0.01, 4.0)
		var w1 := 1.0 / pow(best[1][0] + 0.01, 4.0)
		bones_arr[vi * 4] = best[0][1]
		bones_arr[vi * 4 + 1] = best[1][1]
		weights[vi * 4] = w0 / (w0 + w1)
		weights[vi * 4 + 1] = w1 / (w0 + w1)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if normals.size() > 0:
		arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = null
	arrays[Mesh.ARRAY_BONES] = bones_arr
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	am.surface_set_material(0, source.get_active_material(0))

	var sk := Skin.new()
	for bi in get_bone_count():
		sk.add_named_bind(get_bone_name(bi), get_bone_global_rest(bi).affine_inverse())
	skin_mesh = MeshInstance3D.new()
	skin_mesh.name = "SkinnedHuman"
	skin_mesh.mesh = am
	skin_mesh.skin = sk
	add_child(skin_mesh)
	skin_mesh.skeleton = NodePath("..")
	source.visible = false


func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _build_physics() -> void:
	sim = PhysicalBoneSimulator3D.new()
	sim.name = "Sim"
	add_child(sim)
	sim.active = false
	for b in BONES:
		var start: Vector3 = b[2]
		var end: Vector3 = b[3]
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + b[0]
		pb.bone_name = b[0]
		pb.collision_layer = BONE_LAYER
		pb.collision_mask = WORLD_MASK
		pb.mass = 3.0 if b[0] in ["hips", "spine"] else 1.0
		pb.linear_damp = 0.5
		pb.angular_damp = 4.0
		pb.friction = 0.8
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_PIN if b[1] != "" else PhysicalBone3D.JOINT_TYPE_NONE
		# Capsule centred on the segment, Y along the bone.
		var dir := (end - start).normalized()
		var basis := _basis_y_to(dir)
		var body_xf := Transform3D(basis, (start + end) * 0.5)
		var bone_xf := Transform3D(Basis(), start)
		pb.transform = body_xf
		pb.body_offset = body_xf.affine_inverse() * bone_xf
		pb.joint_offset = Transform3D(Basis(), body_xf.affine_inverse() * start)
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = RADII[b[0]]
		cap.height = maxf(start.distance_to(end), cap.radius * 2.0 + 0.01)
		cs.shape = cap
		pb.add_child(cs)
		sim.add_child(pb)
		bodies.append(pb)


func _basis_y_to(dir: Vector3) -> Basis:
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.999:
		return Basis() if dir.y > 0 else Basis(Vector3.RIGHT, PI)
	var axis := up.cross(dir).normalized()
	return Basis(axis, up.angle_to(dir))


# --- Skeletal animation (procedural keyframes) ---------------------------------
# Bones rest in a T-pose with identity bases. Rotating around X swings a limb forward (-Z)
# for downward-pointing legs; arms are first dropped around Z, then swung around X.
# The fish is held in the character's right hand (+X side, bones *_l).

var _air := 0.0


func _q(x: float, y := 0.0, z := 0.0) -> Quaternion:
	return Quaternion.from_euler(Vector3(x, y, z))


func _arm(hang: float, swing: float, twist := 0.0) -> Quaternion:
	# hang: rotation about Z (drop arm from T-pose), then swing forward about X
	return Quaternion(Vector3.RIGHT, swing) * Quaternion(Vector3.UP, twist) * Quaternion(Vector3.BACK, hang)


func _pose(bone: String, q: Quaternion, k: float) -> void:
	var i := find_bone(bone)
	set_bone_pose_rotation(i, get_bone_pose_rotation(i).slerp(q, k))


## phase: walk cycle time. moving: 0..1.5 run amount. airborne: in the air.
## vy: vertical speed. swing: bonk progress 0..1 (or -1 when not swinging).
func animate(delta: float, phase: float, moving: float, airborne: bool, vy: float, swing: float) -> void:
	if active:
		return
	var m := minf(moving, 1.2)
	_air = move_toward(_air, 1.0 if airborne else 0.0, delta * 6.0)
	var a := _air
	var k := minf(1.0, delta * 14.0)
	var s := sin(phase)

	# Legs: walk cycle blended into a tucked jump pose (rising) / reaching fall pose.
	var rising := clampf(vy / 5.0, 0.0, 1.0)
	var tuck := lerpf(0.5, 1.3, rising)
	_pose("thigh_l", _q(lerpf(s * 0.65 * m, tuck, a)), k)
	_pose("thigh_r", _q(lerpf(-s * 0.65 * m, tuck * 0.45, a)), k)
	_pose("shin_l", _q(lerpf(-(0.5 + 0.5 * sin(phase - 1.3)) * 0.9 * m, -tuck * 1.3, a)), k)
	_pose("shin_r", _q(lerpf(-(0.5 - 0.5 * sin(phase - 1.3)) * 0.9 * m, -tuck * 0.7, a)), k)

	# Torso: lean into the run, a little bounce twist.
	var twist := s * 0.12 * m
	var lean := -0.12 * m - 0.1 * a
	# Free arm (left hand, -X): swings opposite its leg; flails up in the air.
	var free_hang := lerpf(1.25, 0.2, a)
	var free_swing := lerpf(s * 0.55 * m, -0.3, a)
	# Fish arm: held down-forward with the elbow bent, so the fish points ahead.
	var fish_hang := -1.35
	var fish_swing := lerpf(0.75 + s * 0.15 * m, 0.3, a)
	var fish_fore := 1.0
	var fish_twist := 0.0

	if swing >= 0.0:
		# Bonk: wind up overhead & back, slam down across, recover.
		var wind := 0.0
		var strike := 0.0
		if swing < 0.3:
			wind = ease(swing / 0.3, 0.5)
		elif swing < 0.5:
			wind = 1.0 - (swing - 0.3) / 0.2
			strike = ease((swing - 0.3) / 0.2, 2.0)
		else:
			strike = 1.0 - ease((swing - 0.5) / 0.5, 0.6)
		# wind: arm straight up, elbow cocked back. strike: arm thrust out in front.
		fish_hang = lerpf(lerpf(fish_hang, 1.45, wind), -1.5, strike)
		fish_swing = lerpf(lerpf(fish_swing, -0.4, wind), 1.55, strike)
		fish_fore = lerpf(lerpf(fish_fore, -1.2, wind), 0.15, strike)
		fish_twist = lerpf(0.0, 0.6, strike)
		twist += 0.45 * wind - 0.6 * strike
		lean += -0.25 * strike
		k = minf(1.0, delta * 30.0)  # snappy

	_pose("hips", _q(0, -twist * 0.4, 0), k)
	_pose("spine", _q(lean, twist, 0), k)
	_pose("head", _q(-lean * 0.6, -twist * 0.8, 0), k)
	# Hang angles are written relative to a T-pose; the mesh rests in an A-pose (~0.75 rad down).
	_pose("arm_l", _arm(fish_hang + A_POSE, fish_swing, fish_twist), k)
	# Elbows bend forward: rotation about the forearm's local Y (sign flips per side).
	_pose("fore_l", _q(0, fish_fore, 0), k)
	_pose("arm_r", _arm(free_hang - A_POSE, free_swing), k)
	_pose("fore_r", _q(0, -lerpf(0.35 + 0.2 * m, 0.8, a), 0), k)


## Go floppy. `vel` is the launch velocity (world space) to fling the limbs with.
func start_ragdoll(vel: Vector3) -> void:
	if active:
		return
	active = true
	if _fade:
		_fade.kill()
	sim.active = true
	sim.influence = 1.0
	var names: Array[StringName] = []
	for b in BONES:
		if b[0] != "hips":
			names.append(StringName(b[0]))
	sim.physical_bones_start_simulation(names)
	for pb in bodies:
		if pb.bone_name != &"hips":
			# Start limbs moving with the launch so the joints don't have to yank them along.
			pb.linear_velocity = vel + Vector3(randf_range(-1.5, 1.5), randf_range(0, 1.5), randf_range(-1.5, 1.5))


## Blend back to the standing pose.
func stop_ragdoll() -> void:
	if not active:
		return
	active = false
	_fade = create_tween()
	_fade.tween_property(sim, "influence", 0.0, 0.35).set_trans(Tween.TRANS_SINE)
	_fade.tween_callback(func():
		sim.physical_bones_stop_simulation()
		sim.active = false)
