## Screenshot the demo scene, optionally after picking an example by index.
##   xvfb-run -a godot --rendering-driver vulkan -s res://tools/screenshot.gd -- <out.png> [example_index]
extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame  # let _ready build the UI
	if args.size() > 1:
		main._show(Examples.ALL[int(args[1])])
	for _i in 10:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[0] if args.size() > 0 else "user://shot.png")
	quit()
