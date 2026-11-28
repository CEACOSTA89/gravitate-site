extends Node3D
## The NYC arena: real buildings around the Flatiron (NYC Open Data), the buildings the giants can reach pre-shattered
## with baked collapses (made by arena-pipeline/ in the site repository), debris dust, sky, sun and haze.
##
## Files in res://arena/: arena.json (every building's footprint and height, keys shared by every device),
## city.glb (the buildings), collapse/KEY.glb (a building cut into chunks c0, c1, ...) and collapse/KEY.bin (its
## baked collapse: two takes, hit going uptown then downtown; per frame per chunk 7 int16: x, y, z in cm from the
## building's base centre, then a quaternion x, y, z, w scaled by 32767), parks.json (park outlines).
## Coordinates: metres, y up, +z uptown along the avenues, +x the west side.
##
## With `preview` on, the camera circles the Flatiron and knocks a building down every few seconds
## (tap, click or Space for the next one straight away).

const DIR := "res://arena/"

@export var preview := true
@export var knock_every := 4.5

var manifest: Dictionary
var rail: Dictionary
var buildings := {}          # key -> {node, data, scene_path, c (loaded collapse), down, t0, swapped}
var order: Array[String] = []
var collapsing: Array[String] = []
var cam: Camera3D
var hud: Label
var _t := 0.0
var _next_knock := 3.0
var _knocked := 0
var _all_down_at := -1.0
var _focus := Vector3.ZERO
var _focus_target := Vector3.ZERO
var _dust_mat: StandardMaterial3D


func _ready() -> void:
	manifest = JSON.parse_string(FileAccess.get_file_as_string(DIR + "arena.json"))
	rail = manifest["rail"]
	_environment()
	_ground_and_parks()
	var city: Node3D = $City
	for b in manifest["buildings"]:
		if not b.has("chunks"):
			continue
		var node := city.find_child(String(b["key"]).replace(".", "_"), true, false)
		if node == null:
			push_warning("arena: no node for " + b["key"])
			continue
		var path: String = DIR + "collapse/" + b["key"] + ".glb"
		buildings[b["key"]] = {"node": node, "data": b, "scene_path": path, "c": null, "down": false, "t0": 0.0, "swapped": false}
		ResourceLoader.load_threaded_request(path)        # ready before anyone is knocked into it
		order.append(b["key"])
	# nearest to the Flatiron first, the Flatiron itself last
	order.sort_custom(func(a, b): return _dist_to_tip(a) < _dist_to_tip(b))
	var lm := order.filter(func(k): return buildings[k]["data"]["landmark"])
	for k in lm:
		order.erase(k)
		order.append(k)
	_dust_mat = _make_dust_material()
	if preview:
		_preview_setup()


# ---------- look: sky, sun, haze, glow, filmic colour ----------
func _environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.47, 0.70)
	sky_mat.sky_horizon_color = Color(0.62, 0.70, 0.80)
	sky_mat.sky_energy_multiplier = 0.8
	sky_mat.ground_horizon_color = Color(0.62, 0.66, 0.70)
	sky_mat.ground_bottom_color = Color(0.22, 0.24, 0.27)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.38
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.85
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.78, 0.86)
	env.fog_density = 0.00022
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, -32.0, 0.0)
	sun.light_energy = 1.35
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1200.0
	add_child(sun)


func _ground_and_parks() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000, 4000)
	ground.mesh = plane
	var asphalt := StandardMaterial3D.new()
	asphalt.albedo_color = Color(0.11, 0.115, 0.125)
	asphalt.roughness = 0.95
	ground.material_override = asphalt
	add_child(ground)
	var parks: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DIR + "parks.json"))
	var grass := StandardMaterial3D.new()
	grass.albedo_color = Color(0.27, 0.42, 0.24)
	grass.roughness = 1.0
	grass.cull_mode = BaseMaterial3D.CULL_DISABLED
	for outline in parks["parks"]:
		var poly := PackedVector2Array()
		for p in outline:
			poly.append(Vector2(p[0], p[1]))
		var idx := Geometry2D.triangulate_polygon(poly)
		if idx.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_normal(Vector3.UP)
		for i in idx:
			st.add_vertex(Vector3(poly[i].x, 0.08, poly[i].y))
		var m := MeshInstance3D.new()
		m.mesh = st.commit()
		m.material_override = grass
		add_child(m)


# ---------- collapses ----------
func knock(key: String) -> void:
	var e: Dictionary = buildings.get(key, {})
	if e.is_empty() or e["down"]:
		return
	e["down"] = true
	e["t0"] = _t
	e["swapped"] = false
	collapsing.append(key)


func restore_all() -> void:
	for key in buildings:
		var e: Dictionary = buildings[key]
		e["down"] = false
		e["node"].visible = true
		if e["c"] != null:
			e["c"]["scene"].visible = false
	collapsing.clear()


func _collapse_for(e: Dictionary):
	if e["c"] != null:
		return e["c"]
	var status := ResourceLoader.load_threaded_get_status(e["scene_path"])
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return null                                        # still loading: it falls as soon as it arrives
	var packed: PackedScene = ResourceLoader.load_threaded_get(e["scene_path"]) if status == ResourceLoader.THREAD_LOAD_LOADED else load(e["scene_path"])
	var scene: Node3D = packed.instantiate()
	scene.visible = false
	var cen: Array = e["data"]["centre"]
	scene.position = Vector3(cen[0], 0.0, cen[1])
	add_child(scene)
	var nodes: Array[Node3D] = []
	for i in int(e["data"]["chunks"]):
		nodes.append(scene.find_child("c%d" % i, true, false))
	var bytes := FileAccess.get_file_as_bytes(e["scene_path"].get_basename() + ".bin")
	e["c"] = {"scene": scene, "nodes": nodes, "bytes": bytes, "n": int(e["data"]["chunks"]), "frames": int(e["data"]["frames"])}
	return e["c"]


func _pose(c: Dictionary, take: int, t: float) -> bool:
	var f := maxf(0.0, t * float(manifest["fps"]))
	var frames: int = c["frames"]
	var n: int = c["n"]
	var f0 := mini(int(f), frames - 1)
	var f1 := mini(f0 + 1, frames - 1)
	var k := f - f0
	var b: PackedByteArray = c["bytes"]
	for i in n:
		var node: Node3D = c["nodes"][i]
		if node == null:
			continue
		var a := ((take * frames + f0) * n + i) * 14
		var d := ((take * frames + f1) * n + i) * 14
		var p0 := Vector3(b.decode_s16(a), b.decode_s16(a + 2), b.decode_s16(a + 4)) / 100.0
		var p1 := Vector3(b.decode_s16(d), b.decode_s16(d + 2), b.decode_s16(d + 4)) / 100.0
		var q0 := Quaternion(b.decode_s16(a + 6), b.decode_s16(a + 8), b.decode_s16(a + 10), b.decode_s16(a + 12)).normalized()
		var q1 := Quaternion(b.decode_s16(d + 6), b.decode_s16(d + 8), b.decode_s16(d + 10), b.decode_s16(d + 12)).normalized()
		node.transform = Transform3D(Basis(q0.slerp(q1, k)), p0.lerp(p1, k))
	return f < frames - 1


func _step_collapses() -> void:
	for key in collapsing.duplicate():
		var e: Dictionary = buildings[key]
		var c = _collapse_for(e)
		if c == null:
			e["t0"] = _t
			continue
		if not e["swapped"]:
			e["swapped"] = true
			e["node"].visible = false
			c["scene"].visible = true
			_spawn_dust(e["data"])
		# uptown of the Flatiron's tip: knocked uptown (take 0); otherwise downtown (take 1). Same on every screen.
		var take := 0 if float(e["data"]["centre"][1]) > float(rail["tipZ"]) else 1
		if not _pose(c, take, _t - e["t0"]):
			collapsing.erase(key)


# ---------- dust ----------
func _make_dust_material() -> StandardMaterial3D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var r := Vector2(x - 31.5, y - 31.5).length() / 32.0
			var a := clampf(1.0 - r, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a * (3.0 - 2.0 * a)))
	var m := StandardMaterial3D.new()
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return m


func _spawn_dust(b: Dictionary) -> void:
	var h := float(b["height"])
	var pts: Array = b["pts"]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in pts:
		lo = Vector2(minf(lo.x, p[0]), minf(lo.y, p[1]))
		hi = Vector2(maxf(hi.x, p[0]), maxf(hi.y, p[1]))
	var centre := (lo + hi) / 2.0
	# a wave rolling out from the base, and a taller column where it stood
	for spec in [[Vector3((hi.x - lo.x) / 2.0, 4.0, (hi.y - lo.y) / 2.0), 6.0, 16.0, 0.6, 40 + int(h * 0.4), 9.0],
				[Vector3(6.0, h * 0.35, 6.0), 2.0, 5.0, 2.2, 14 + int(h * 0.15), 10.0]]:
		var p := CPUParticles3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * (10.0 + h * 0.12)          # puffs this big, grown further over their life
		quad.material = _dust_mat
		p.mesh = quad
		p.position = Vector3(centre.x, spec[0].y, centre.y)
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		p.emission_box_extents = Vector3(spec[0].x, spec[0].y if spec[0].y > 5.0 else 2.0, spec[0].z)
		p.amount = spec[4]
		p.lifetime = spec[5]
		p.one_shot = true
		p.explosiveness = 0.85
		p.direction = Vector3(0, 0.15, 0)
		p.spread = 180.0
		p.initial_velocity_min = spec[1]
		p.initial_velocity_max = spec[2]
		p.gravity = Vector3(0, spec[3], 0)
		p.damping_min = 1.5
		p.damping_max = 3.0
		p.scale_amount_min = 0.8
		p.scale_amount_max = 1.5
		var grow := Curve.new()
		grow.add_point(Vector2(0.0, 0.35))
		grow.add_point(Vector2(1.0, 3.0))
		p.scale_amount_curve = grow
		var fade := Gradient.new()
		fade.set_color(0, Color(0.80, 0.77, 0.72, 0.0))
		fade.set_color(1, Color(0.80, 0.77, 0.72, 0.0))
		fade.add_point(0.08, Color(0.80, 0.77, 0.72, 0.55))
		fade.add_point(0.55, Color(0.76, 0.74, 0.70, 0.30))
		p.color_ramp = fade
		add_child(p)
		p.emitting = true
		p.finished.connect(p.queue_free)


# ---------- preview: circle the Flatiron, knock buildings down ----------
func _preview_setup() -> void:
	cam = Camera3D.new()
	cam.fov = 50.0
	cam.far = 5000.0
	add_child(cam)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.theme = preload("res://theme/protect_destroy_theme.tres")
	hud.theme_type_variation = "PodSmall"
	hud.position = Vector2(40, 30)
	hud.modulate = Color(1, 1, 1, 0.85)
	layer.add_child(hud)


func _unhandled_input(event: InputEvent) -> void:
	if not preview:
		return
	var tap: bool = (event is InputEventMouseButton and event.pressed) or (event is InputEventScreenTouch and event.pressed) \
		or (event is InputEventKey and event.pressed and event.keycode == KEY_SPACE)
	if tap:
		_next_knock = _t


func _process(delta: float) -> void:
	_t += delta
	_step_collapses()
	if not preview:
		return
	var tip := Vector3(float(rail["x"]), 0.0, float(rail["tipZ"]))
	if _focus == Vector3.ZERO:
		_focus = tip
		_focus_target = tip
	_focus = _focus.lerp(_focus_target, minf(1.0, delta * 0.8))      # swing over to whatever is falling
	var a := _t * 0.08
	var radius := 230.0
	cam.position = _focus + Vector3(sin(a) * radius, 115.0 + 20.0 * sin(_t * 0.11), cos(a) * radius)
	cam.look_at(_focus + Vector3(0, 25, 0), Vector3.UP)
	if _t >= _next_knock and _knocked < order.size():
		knock(order[_knocked])
		var cen: Array = buildings[order[_knocked]]["data"]["centre"]
		_focus_target = Vector3(cen[0], 0.0, cen[1])
		_knocked += 1
		_next_knock = _t + (knock_every * 2.0 if _knocked == order.size() - 1 else knock_every)
		if _knocked == order.size():
			_all_down_at = _t
	if _all_down_at > 0.0 and _t - _all_down_at > 16.0:
		restore_all()
		_knocked = 0
		_all_down_at = -1.0
		_next_knock = _t + 2.0
	hud.text = "ARENA PREVIEW  ·  FLATIRON / MADISON SQUARE  ·  NYC OPEN DATA  ·  %d / %d DOWN  ·  TAP FOR THE NEXT" % [_knocked, order.size()]


func _dist_to_tip(key: String) -> float:
	var c: Array = buildings[key]["data"]["centre"]
	return Vector2(c[0], c[1]).distance_to(Vector2(float(rail["x"]), float(rail["tipZ"])))
