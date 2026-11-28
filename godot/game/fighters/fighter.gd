class_name Fighter
extends Node3D
## One giant (Ghost or Nullifier): a rigged model loaded at run time from the asset host (the models are kept on
## Cloudflare, not in the public repository), scaled to the Flatiron's height, posed every frame from poses.json:
## a boxer's stance with bounce, sway and head movement, and strikes (play_strike) layered on top.

signal model_ready

const POSES_PATH := "res://fighters/poses.json"
const HEIGHTS := {"ghost": 2.1797, "nullifier": 1.9817}    # the model's own height, from joints.json

@export var model_name := "ghost"
@export var facing := 1.0                  # +1 faces uptown (+z), -1 downtown

var skel: Skeleton3D
var bones := {}                            # bone name -> index
var rest := {}                             # bone name -> rest rotation
var hips_rest := Vector3.ZERO
var strike := ""                           # the strike being played
var strike_t0 := 0.0
var guard_until := 0.0                     # blocking: hold the guard high until then
var phase := 0.0
var loaded := false

static var _poses: Dictionary


static func poses() -> Dictionary:
	if _poses.is_empty():
		_poses = JSON.parse_string(FileAccess.get_file_as_string(POSES_PATH))
	return _poses


func load_from(url: String, giant_height: float) -> void:
	phase = 1.7 if model_name == "nullifier" else 0.0
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			push_warning("fighter: could not load %s (%d / %d)" % [url, result, code])
			return
		_build(body, giant_height))
	http.request(url)


func _build(body: PackedByteArray, giant_height: float) -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(body, "", state) != OK:
		push_warning("fighter: not a glTF model")
		return
	var model: Node3D = doc.generate_scene(state)
	add_child(model)
	var found := model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		push_warning("fighter: the model has no skeleton")
		return
	skel = found[0]
	for i in skel.get_bone_count():
		var n := skel.get_bone_name(i)
		bones[n] = i
		rest[n] = skel.get_bone_rest(i).basis.get_rotation_quaternion()
	hips_rest = skel.get_bone_rest(bones["hips"]).origin
	scale = Vector3.ONE * (giant_height / float(HEIGHTS.get(model_name, 2.0)))
	rotation.y = 0.0 if facing > 0.0 else PI
	loaded = true
	model_ready.emit()


func play_strike(kind: String) -> void:
	if poses()["strikes"].has(kind):
		strike = kind
		strike_t0 = _now()


func block(seconds: float) -> void:
	guard_until = _now() + seconds


## How far into the current strike its blow lands (seconds after it starts).
func hit_delay(kind: String) -> float:
	var s: Dictionary = poses()["strikes"][kind]
	return float(s["dur"]) * float(s["keys"][s["keys"].size() - 1][0])


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _q(e: Vector3, flip: bool) -> Quaternion:
	if flip:
		e = Vector3(-e.x, e.y, -e.z)
	var r := e * (PI / 180.0)
	return Quaternion(Vector3.RIGHT, r.x) * Quaternion(Vector3.UP, r.y) * Quaternion(Vector3.BACK, r.z)


static func _v(a) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _process(_delta: float) -> void:
	if not loaded:
		return
	var P := poses()
	var now := _now()
	var t := now + phase
	var target := {}
	for b in P["stance"]["bones"]:
		target[b] = _v(P["stance"]["bones"][b])
	var w := 0.0
	if strike != "":
		var s: Dictionary = P["strikes"][strike]
		var k := (now - strike_t0) / float(s["dur"])
		if k >= 1.0:
			strike = ""
		else:
			w = 1.0
			# keyframes: the stance at 0 and 1, the strike's keys between
			var keys: Array = [[0.0, {}]] + s["keys"] + [[1.0, {}]]
			for i in keys.size() - 1:
				var k0: float = keys[i][0]
				var k1: float = keys[i + 1][0]
				if k >= k0 and k <= k1:
					var u := smoothstep(0.0, 1.0, (k - k0) / maxf(k1 - k0, 0.001))
					var names := {}
					for n in keys[i][1]: names[n] = true
					for n in keys[i + 1][1]: names[n] = true
					for n in names:
						var a: Vector3 = _v(keys[i][1][n]) if keys[i][1].has(n) else target.get(n, Vector3.ZERO)
						var b: Vector3 = _v(keys[i + 1][1][n]) if keys[i + 1][1].has(n) else target.get(n, Vector3.ZERO)
						target[n] = a.lerp(b, u)
					w = 1.0 - (1.0 - u) * float(i == 0) - u * float(i == keys.size() - 2)
					break
	if now < guard_until:                  # high guard: forearms up in front of the face
		target["upper_arm_L"] = Vector3(-55, 0, 14)
		target["forearm_L"] = Vector3(-135, 0, 0)
		target["upper_arm_R"] = Vector3(-55, 0, -14)
		target["forearm_R"] = Vector3(-135, 0, 0)
	# alive between strikes: bounce on the balls of the feet, roll the shoulders, move the head
	var calm := 1.0 - 0.7 * w
	target["chest"] = target.get("chest", Vector3.ZERO) + Vector3(0, 8.0 * sin(TAU * 0.6 * t) * calm, 0)
	target["spine"] = target.get("spine", Vector3.ZERO) + Vector3(2.0 * sin(TAU * 1.7 * t) * calm, 0, 3.0 * sin(TAU * 0.6 * t + 0.5) * calm)
	target["neck"] = target.get("neck", Vector3.ZERO) + Vector3(0, 0, 5.0 * sin(TAU * 0.9 * t + 1.1) * calm)
	var flips: Array = P.get("flip_xz", [])
	for n in target:
		if bones.has(n):
			skel.set_bone_pose_rotation(bones[n], rest[n] * _q(target[n], flips.has(n)))
	var drop := float(P["stance"]["hips_drop"]) + 0.025 * sin(TAU * 1.7 * t) * calm
	skel.set_bone_pose_position(bones["hips"], hips_rest - Vector3(0, drop, 0))
