extends Control
## Preload screen: the orb cycles PROTECT -> DESTROY -> PROTECT while the next
## scene loads in the background. Leave `next_scene` empty to run it as a demo.

@export_file("*.tscn") var next_scene := ""
@export var cycle_seconds := 4.0          ## time spent in each state
@export var min_show_seconds := 2.0       ## never flash past faster than this
@export var protect_color := Color(1.0, 0.10, 0.42)
@export var destroy_color := Color(0.10, 1.0, 0.38)

const THEME := preload("res://theme/protect_destroy_theme.tres")
const ORB_SHADER := preload("res://orb.gdshader")

var progress := 0.0        # value shown on the ring, 0..1
var hold := false          # true = freeze state/progress (used for stills)

var _mat: ShaderMaterial
var _protect: Label
var _destroy: Label
var _status: Label
var _cycle_tag: Label
var _t := 0.0
var _state := 0            # 0 protect, 1 destroy
var _mix := 0.0
var _since_flip := 10.0
var _cycle := 1
var _target := 0.0
var _loading := false
var _row: HBoxContainer
var _or: Label
var _portrait := false


func _ready() -> void:
	theme = THEME
	_mat = ShaderMaterial.new()
	_mat.shader = ORB_SHADER
	var bg := ColorRect.new()
	bg.material = _mat
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var row := HBoxContainer.new()
	_row = row
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 44)
	add_child(row)
	_place(row, 0.755, 0.855)
	_protect = _label(row, "PROTECT", "PodTitle")
	_or = _label(row, "OR", "PodOr")
	_or.modulate = Color(1, 1, 1, 0.45)
	_destroy = _label(row, "DESTROY", "PodTitle")

	_status = _label(self, "", "PodSmall")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(_status, 0.88, 0.925)

	var tag := _label(self, "PRELOAD", "PodSmall")
	tag.modulate = Color(1, 1, 1, 0.4)
	tag.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 56)
	_cycle_tag = _label(self, "CYCLE 01", "PodSmall")
	_cycle_tag.modulate = Color(1, 1, 1, 0.4)
	_cycle_tag.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 56)

	if next_scene != "":
		_loading = ResourceLoader.load_threaded_request(next_scene) == OK
	get_viewport().size_changed.connect(_layout)
	_layout()
	_apply()


## Phones held upright: a portrait canvas, a smaller orb higher up, and the title sized to fit the width.
func _layout() -> void:
	var win := get_window()
	var screen := Vector2(win.size)
	_portrait = screen.x < screen.y
	win.content_scale_size = Vector2i(1080, 1920) if _portrait else Vector2i(1920, 1080)
	_mat.set_shader_parameter("orb_radius", 0.118 if _portrait else 0.165)
	_mat.set_shader_parameter("center", Vector2(0.5, 0.36) if _portrait else Vector2(0.5, 0.42))
	var title := 92 if _portrait else 84
	for l in [_protect, _destroy]:
		l.add_theme_font_size_override("font_size", title)
	_or.add_theme_font_size_override("font_size", 30)
	for l in [_protect, _or, _destroy]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_row.vertical = _portrait
	_row.add_theme_constant_override("separation", 6 if _portrait else 44)
	if _portrait:
		_place(_row, 0.63, 0.80)
		_place(_status, 0.82, 0.85)
	else:
		_place(_row, 0.755, 0.855)
		_place(_status, 0.88, 0.925)


func _process(delta: float) -> void:
	if not hold:
		_t += delta
		_since_flip += delta
		var phase := int(_t / cycle_seconds)
		if phase % 2 != _state:
			_state = phase % 2
			_since_flip = 0.0
		_cycle = phase / 2 + 1
		_mix = move_toward(_mix, float(_state), delta * 2.2)
		_poll_load()
		progress = move_toward(progress, _target, delta * 0.9)
	_apply()


func _poll_load() -> void:
	if not _loading:
		# demo: fill over three cycles, then start again
		_target = fmod(_t / (cycle_seconds * 3.0), 1.0)
		if _target < progress - 0.5:
			progress = 0.0
		return
	var p := []
	var status := ResourceLoader.load_threaded_get_status(next_scene, p)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_target = p[0]
	elif status == ResourceLoader.THREAD_LOAD_LOADED:
		_target = 1.0
		if progress >= 0.999 and _t >= min_show_seconds:
			_loading = false
			get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(next_scene))
	else:
		push_error("Preload: could not load %s" % next_scene)
		_loading = false


## Jump straight to a state (0 protect, 1 destroy) and progress; used for stills.
func show_still(state: int, value: float, clock: float = 2.6) -> void:
	hold = true
	_state = state
	_mix = float(state)
	_since_flip = 10.0
	_cycle = 1 + state
	_t = clock
	progress = value
	_apply()


func _apply() -> void:
	var tint := protect_color.lerp(destroy_color, _mix)
	_mat.set_shader_parameter("state", _mix)
	_mat.set_shader_parameter("progress", progress)
	_mat.set_shader_parameter("pulse", clampf(_since_flip / 1.3, 0.0, 1.0))
	_mat.set_shader_parameter("clock", _t)
	_mat.set_shader_parameter("protect_color", Vector3(protect_color.r, protect_color.g, protect_color.b))
	_mat.set_shader_parameter("destroy_color", Vector3(destroy_color.r, destroy_color.g, destroy_color.b))
	_mat.set_shader_parameter("resolution", size)
	var off := Color(1, 1, 1, 0.16)
	_protect.modulate = off.lerp(protect_color, 1.0 - _mix)
	_destroy.modulate = off.lerp(destroy_color, _mix)
	_status.text = "LOADING  %03d%%" % int(round(progress * 100.0))
	_status.modulate = tint.lerp(Color.WHITE, 0.55)
	_cycle_tag.text = "CYCLE %02d" % _cycle


func _label(parent: Node, text: String, variation: String) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	parent.add_child(l)
	return l


func _place(c: Control, top: float, bottom: float) -> void:
	c.anchor_left = 0.0
	c.anchor_right = 1.0
	c.anchor_top = top
	c.anchor_bottom = bottom
	c.offset_left = 0.0
	c.offset_right = 0.0
	c.offset_top = 0.0
	c.offset_bottom = 0.0
