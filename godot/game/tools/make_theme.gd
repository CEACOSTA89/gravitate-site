extends SceneTree
## Rebuilds theme/protect_destroy_theme.tres from the Orbitron variable font.
## Run: Godot --headless --path . -s tools/make_theme.gd

func _init() -> void:
	var base: FontFile = load("res://fonts/Orbitron-Variable.ttf")
	var wght := TextServerManager.get_primary_interface().name_to_tag("wght")

	var black := FontVariation.new()
	black.base_font = base
	black.variation_opentype = {wght: 900}
	black.spacing_glyph = 8

	var medium := FontVariation.new()
	medium.base_font = base
	medium.variation_opentype = {wght: 500}
	medium.spacing_glyph = 7

	var th := Theme.new()
	th.default_font = medium
	th.default_font_size = 22

	th.set_type_variation("PodTitle", "Label")
	th.set_font("font", "PodTitle", black)
	th.set_font_size("font_size", "PodTitle", 84)
	th.set_color("font_color", "PodTitle", Color.WHITE)

	th.set_type_variation("PodOr", "Label")
	th.set_font("font", "PodOr", medium)
	th.set_font_size("font_size", "PodOr", 30)
	th.set_color("font_color", "PodOr", Color.WHITE)

	th.set_type_variation("PodSmall", "Label")
	th.set_font("font", "PodSmall", medium)
	th.set_font_size("font_size", "PodSmall", 22)
	th.set_color("font_color", "PodSmall", Color.WHITE)

	var err := ResourceSaver.save(th, "res://theme/protect_destroy_theme.tres")
	print("THEME_SAVED ", err)
	quit()
