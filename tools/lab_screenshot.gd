## Screenshots of the monster lab, one PNG per monster, clip, time and view. Needs a display;
## headless servers: xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan ...
##   godot -s res://tools/lab_screenshot.gd -- <out_dir> [ids=wolf,harpy] [clips=walk|all|idle,hit]
##         [ts=0.5|0.3,0.5,0.7] [views=three,front,side,top,hand_r,hand_l,grip_r,grip_l,lods] [skel=1]
##         [gripoffset=0] [tag=_suffix]
## Views: three (3/4 front), front (camera on -Z looking +Z), side (camera on +X), top,
## hand_*/grip_* (close-up on that socket with skeleton and socket axes; skipped when the
## rig lacks it), lods (LOD0..3 at the same frame). The clip is paused at each t (fraction
## of its length), so every view of one t shows the same pose.
## File names: <id>_<clip>_t<pct>_<view>.png (lods: ..._lod<k>.png).
extends SceneTree

const Lab = preload("res://scenes/monster_lab.tscn")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://shots"
	DirAccess.make_dir_recursive_absolute(out)
	var opt := {"ids": "", "views": "three", "ts": "0.5", "skel": "0", "clips": "walk", "gripoffset": "1", "tag": ""}
	for a in args.slice(1):
		var kv := a.split("=", true, 1)
		opt[kv[0]] = kv[1] if kv.size() > 1 else "1"
	load("res://scripts/monster.gd").apply_grip_offset = opt["gripoffset"] == "1"
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
		var clips: PackedStringArray = m.clips() if opt["clips"] == "all" else opt["clips"].split(",")
		for clip in clips:
			if clip != "rest" and not clip in m.clips():
				continue
			for ts in opt["ts"].split(","):
				lab.select_clip(clip)
				if clip != "rest":
					m.anim.seek(m.anim.get_animation(clip).length * float(ts), true)
					m.anim.speed_scale = 0.0
				var stem := "%s/%s_%s_t%02d%s" % [out, id, clip, int(float(ts) * 100), opt["tag"]]
				for view in opt["views"].split(","):
					await _view(lab, m, view, stem, opt["skel"] == "1")
				m.anim.speed_scale = 1.0
	quit()


func _view(lab: Node3D, m: Node3D, view: String, stem: String, skel: bool) -> void:
	lab.show_skeleton = skel
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
		"three", "lods":
			lab.cam_yaw = 0.6
		"hand_r", "hand_l", "grip_r", "grip_l":
			if not m.has_socket(view):
				return
			var sk: Skeleton3D = m.skeleton
			lab.cam_target = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(view)).origin
			lab.cam_dist = 0.6 * float(m.info.get("scale_m", 1.8)) / 1.8 + 0.3
			lab.cam_yaw = 0.5 if view.ends_with("_r") else -0.5
			lab.cam_pitch = 0.1
			lab.show_skeleton = true
		_:
			push_error("unknown view " + view)
			return
	if view == "lods":
		for k in m.lods.size():
			lab.set_lod_mode(k)
			await _shot("%s_lod%d.png" % [stem, k])
		return
	await _shot("%s_%s.png" % [stem, view])


func _shot(path: String) -> void:
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(path)
	print("wrote ", path)
