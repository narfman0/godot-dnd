## Screenshots of the monster lab, one PNG per monster and view (needs a display or xvfb):
##   godot -s res://tools/lab_screenshot.gd -- <out_dir> [ids=wolf,harpy] [views=three,front,side,hand_r,hand_l,lods]
##         [t=0.5] [skel=1] [clip=walk]
## Views: three (3/4 front), front (camera on -Z looking +Z), side (camera on +X), top,
## hand_r / hand_l (close-up on the socket with skeleton and socket axes), lods (LOD0..3 at the same frame).
## The clip is paused at t (fraction of its length) so every view shows the same pose.
extends SceneTree

const Lab = preload("res://scenes/monster_lab.tscn")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://shots"
	DirAccess.make_dir_recursive_absolute(out)
	var opt := {"ids": "", "views": "three", "t": "0.5", "skel": "0", "clip": "walk"}
	for a in args.slice(1):
		var kv := a.split("=", true, 1)
		opt[kv[0]] = kv[1] if kv.size() > 1 else "1"
	var lab: Node3D = Lab.instantiate()
	root.add_child(lab)
	await process_frame
	if not lab.has_method("select_monster"):
		push_error("monster_lab.gd failed to load")
		quit(1)
		return
	var ids: PackedStringArray = lab.ids if opt["ids"] == "" else opt["ids"].split(",")
	for id in ids:
		lab.select_monster(id)
		var m: Node3D = lab.monster
		if m == null:
			push_error("cannot load " + id)
			continue
		var clip: String = opt["clip"] if opt["clip"] in m.clips() else "rest"
		lab.select_clip(clip)
		if clip != "rest":
			m.anim.seek(m.anim.get_animation(clip).length * float(opt["t"]), true)
			m.anim.speed_scale = 0.0
		lab.show_skeleton = opt["skel"] == "1"
		for view in opt["views"].split(","):
			lab.set_lod_mode(-1)
			lab.frame()
			lab.cam_pitch = 0.2
			match view:
				"front":
					lab.cam_yaw = 0.0
				"side":
					lab.cam_yaw = PI / 2
				"top":
					lab.cam_yaw = 0.0
					lab.cam_pitch = 1.45
				"three":
					lab.cam_yaw = 0.6
				"hand_r", "hand_l":
					if not m.has_socket(view):
						continue
					var sk: Skeleton3D = m.skeleton
					lab.cam_target = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(view)).origin
					lab.cam_dist = 0.6 * float(m.info.get("scale_m", 1.8)) / 1.8 + 0.3
					lab.cam_yaw = 0.5 if view == "hand_r" else -0.5
					lab.cam_pitch = 0.1
					lab.show_skeleton = true
			if view == "lods":
				lab.cam_yaw = 0.6
				for k in m.lods.size():
					lab.set_lod_mode(k)
					await _shot("%s/%s_lod%d.png" % [out, id, k])
				continue
			await _shot("%s/%s_%s.png" % [out, id, view])
			lab.show_skeleton = opt["skel"] == "1"
	quit()


func _shot(path: String) -> void:
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(path)
	print("wrote ", path)
