extends SceneTree
## Saves still previews of both states into previews/.
## Run: Godot --path . -s tools/shoot.gd

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: Control = load("res://preload.tscn").instantiate()
	root.add_child(scene)
	var shots := [
		["protect", 0, 0.42, 2.6],
		["destroy", 1, 0.78, 6.3],
	]
	for s in shots:
		scene.show_still(s[1], s[2], s[3])
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://previews/preload_%s.png" % s[0])
		print("SHOT ", s[0])
	quit()
