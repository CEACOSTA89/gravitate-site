extends Node
## The two giants sparring on their own along the avenue (the preview), with the current game's rules: they trade
## strikes in the combination order; a clean hit knocks the other back and the hitter strides after it; a blocked
## strike does not; a giant knocked into a building brings it down; Ghost driven back through the Flatiron loses
## the round (Nullifier wins), Nullifier driven far uptown loses it (Ghost wins). Then the city resets.
## Distances are in giant heights (h), as in the current game.

const REACH := 0.78       # the farthest apart they can still land a blow
const KNOCK := 0.32       # how far a clean hit drives the other back
const STRIDE := 0.26      # how far the hitter steps after it
const RADIUS := 0.16      # a giant's footprint, for knocking down buildings

var arena: Node3D                            # arena.gd: rail, buildings, knock(), restore_all()
var A: Fighter                               # Ghost: protects the Flatiron, faces uptown
var B: Fighter                               # Nullifier: faces downtown
var h := 90.0
var z := {"A": 0.0, "B": 0.0}                # where each stands on the rail (target)
var shown := {"A": 0.0, "B": 0.0}            # where each is drawn (eases towards z)
var punches := {"A": 0, "B": 0}
var turn := "A"
var next_at := 2.0
var pending: Array = []                      # [time, attacker, kind, blocked]
var over_at := -1.0
var cam: Camera3D
var cam_mode := 0
var cam_switch_at := 0.0
var cut_until := 0.0
var cut_at := Vector3.ZERO
var label: Label
var label_until := 0.0
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	var rail: Dictionary = arena.rail
	h = float(rail["giant"])
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.far = 5000.0
	arena.add_child(cam)
	cam.make_current()
	var layer := CanvasLayer.new()
	add_child(layer)
	label = Label.new()
	label.theme = preload("res://theme/protect_destroy_theme.tres")
	label.theme_type_variation = "PodSmall"
	label.add_theme_font_size_override("font_size", 40)
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position.y = 90
	layer.add_child(label)
	var base := _models_base()
	A = Fighter.new()
	A.model_name = "ghost"
	A.facing = 1.0
	B = Fighter.new()
	B.model_name = "nullifier"
	B.facing = -1.0
	arena.add_child(A)
	arena.add_child(B)
	A.load_from(base + "ghost.glb", h)
	B.load_from(base + "nullifier.glb", h)
	_reset_round()


## The character models live on the asset host (pod-assets), next to the web build, under /models/.
func _models_base() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("location.origin", true)) + "/models/"
	return "https://pod-assets.gravitatepictures.workers.dev/models/"


func _reset_round() -> void:
	var tip := float(arena.rail["tipZ"])
	z["A"] = tip + 0.9 * h
	z["B"] = tip + 1.8 * h
	shown = z.duplicate()
	pending.clear()
	over_at = -1.0
	next_at = _now() + 1.5
	arena.restore_all()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _fighter(r: String) -> Fighter:
	return A if r == "A" else B


func _flash(text: String, seconds: float = 0.8) -> void:
	label.text = text
	label_until = _now() + seconds


func _process(delta: float) -> void:
	var now := _now()
	var ready := A.loaded and B.loaded
	if ready and over_at < 0.0:
		_fight(now)
	elif over_at > 0.0 and now - over_at > 7.0:
		_reset_round()
	# move, keep in reach
	if ready and over_at < 0.0 and pending.is_empty() and z["B"] - z["A"] > REACH * 0.9 * h:
		var step := 0.12 * h * delta
		z["A"] += step
		z["B"] -= step
	for r in ["A", "B"]:
		shown[r] = lerpf(shown[r], z[r], minf(1.0, delta * 5.0))
	var x := float(arena.rail["x"])
	A.position = Vector3(x, 0.0, shown["A"])
	B.position = Vector3(x, 0.0, shown["B"])
	if ready and over_at < 0.0:
		_buildings(now)
	_camera(now, delta)
	label.modulate.a = clampf((label_until - now) * 3.0, 0.0, 1.0)


func _fight(now: float) -> void:
	if now >= next_at and pending.is_empty():
		var attacker := turn
		turn = "B" if turn == "A" else "A"
		punches[attacker] += 1
		var combo: Array = Fighter.poses()["combo"]
		var kind: String = combo[(punches[attacker] - 1) % combo.size()]
		var f := _fighter(attacker)
		f.play_strike(kind)
		var blocked := rng.randf() < 0.28
		if blocked:
			_fighter("B" if attacker == "A" else "A").block(0.9)
		pending.append([now + f.hit_delay(kind), attacker, kind, blocked])
		_flash(kind.to_upper().replace("SIDEKICK", "SIDE KICK"), 0.7)
		next_at = now + float(Fighter.poses()["strikes"][kind]["dur"]) + 0.45 + rng.randf() * 0.7
	for p in pending.duplicate():
		if now < p[0]:
			continue
		pending.erase(p)
		var attacker: String = p[1]
		var defender := "B" if attacker == "A" else "A"
		if z["B"] - z["A"] > REACH * h:
			_flash("OUT OF REACH", 0.6)
		elif p[3]:
			_flash("BLOCKED", 0.7)
		else:
			var kick: bool = p[2] in ["sidekick", "roundhouse"]
			var push := KNOCK * h * (1.35 if kick else 1.0)
			var dir := 1.0 if defender == "B" else -1.0
			z[defender] += dir * push
			z[attacker] += dir * STRIDE * h
			_flash(("GHOST" if attacker == "A" else "NULLIFIER") + " HITS", 0.8)


func _buildings(now: float) -> void:
	var x := float(arena.rail["x"])
	var r := RADIUS * h
	for who in ["A", "B"]:
		var pz: float = shown[who]
		var probes := [Vector2(x, pz), Vector2(x - r, pz), Vector2(x + r, pz), Vector2(x, pz - r), Vector2(x, pz + r)]
		for key in arena.buildings:
			var e: Dictionary = arena.buildings[key]
			if e["down"]:
				continue
			var poly := PackedVector2Array()
			for p in e["data"]["pts"]:
				poly.append(Vector2(p[0], p[1]))
			for q in probes:
				if Geometry2D.is_point_in_polygon(q, poly):
					arena.knock(key)
					var c: Array = e["data"]["centre"]
					cut_at = Vector3(c[0], 0.0, c[1])
					cut_until = now + 3.2
					if e["data"]["landmark"]:
						over_at = now
						_flash("THE FLATIRON FALLS · NULLIFIER WINS", 6.0)
					break
	if over_at < 0.0 and z["B"] - float(arena.rail["tipZ"]) > 6.0 * h:
		over_at = now
		_flash("NEIGHBORHOOD SAVED · GHOST WINS", 6.0)


func _camera(now: float, delta: float) -> void:
	var x := float(arena.rail["x"])
	var mid: float = (shown["A"] + shown["B"]) / 2.0
	var pos: Vector3
	var look: Vector3
	if now < cut_until:                                         # a building is coming down: wide shot of it
		pos = cut_at + Vector3(-1.3 * h, 0.75 * h, 1.4 * h)
		look = cut_at + Vector3(0, 0.25 * h, 0)
	else:
		if now > cam_switch_at:
			cam_mode = (cam_mode + 1) % 3
			cam_switch_at = now + 9.0
		match cam_mode:
			0:      # behind Ghost, over the shoulder, looking uptown at Nullifier
				pos = Vector3(x - 0.45 * h, 1.25 * h, shown["A"] - 1.3 * h)
				look = Vector3(x, 0.5 * h, shown["A"] + 0.9 * h)
			1:      # behind Nullifier, looking downtown at Ghost and the Flatiron
				pos = Vector3(x - 0.45 * h, 1.25 * h, shown["B"] + 1.3 * h)
				look = Vector3(x, 0.5 * h, shown["B"] - 0.9 * h)
			_:      # high and wide, circling slowly
				var a := now * 0.12
				pos = Vector3(x + sin(a) * 2.2 * h, 1.7 * h, mid + cos(a) * 2.2 * h)
				look = Vector3(x, 0.4 * h, mid)
	cam.position = cam.position.lerp(pos, minf(1.0, delta * 2.5)) if cam.position != Vector3.ZERO else pos
	cam.look_at(look, Vector3.UP)
