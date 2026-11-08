## Shared UAL clips vs monster-forge's per-monster bakes (docs/monsters.md "Shared UAL clips").
## Loads each monster twice: as the game does (shared library, motion_scale, root offset, lift
## modifier) and with every shared clip read from <forge>/out/srd-5.2.1/<id>/anims_ual/<clip>.glb
## (the per-monster bake, Monster.ual_legacy_root), then compares every bone's global pose at
## 0, 25, 50, 75 and 100% of each clip (2 mm), and a cross-fade into each clip at 0.1 s (1% of
## scale_m).
##   godot --headless -s res://tools/check_ual_shared.gd -- [forge=../monster-forge] [id ...]
## Prints ALL PASS / FAIL; exit code 1 on failure. Needs the monster-forge checkout.
extends SceneTree

const Monster = preload("res://scripts/monster.gd")
const POS_TOL := 0.002   # m
const ROT_TOL := 0.2     # deg

var _fail := 0


func _initialize() -> void:
	var forge := ProjectSettings.globalize_path("res://").path_join("../monster-forge")
	var ids := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("forge="):
			forge = a.substr(6)
		else:
			ids.append(a)
	if ids.is_empty():
		for id in Monster.list_ids():
			var info = JSON.parse_string(FileAccess.get_file_as_string("res://assets/monsters/%s/monster.json" % id))
			if info is Dictionary and info.has("ual_shared"):
				ids.append(id)
	var legacy_root := forge.path_join("out/srd-5.2.1")
	for id in ids:
		Monster.ual_legacy_root = ""
		var m: Node3D = Monster.load_monster(id)
		Monster.ual_legacy_root = legacy_root
		var r: Node3D = Monster.load_monster(id)
		Monster.ual_legacy_root = ""
		if m == null or r == null:
			_check(false, "%s: load failed: %s" % [id, Monster.last_error])
			continue
		root.add_child(m)
		root.add_child(r)
		var sh: Dictionary = m.ual_shared
		var line := "%s: %s, %d shared clip(s) %s, own %s, lift curves %s" % [id,
				"motion_scale %.4f" % m.skeleton.motion_scale if not sh.is_empty() else "no shared clips",
				sh.get("clips", {}).size(), sh.get("clips", {}).keys(),
				Array(m.clips()).filter(func(c): return not sh.get("clips", {}).has(c)), sh.get("lift", {}).keys()]
		print(line)
		for clip in m.clips():
			var a: Animation = m.anim.get_animation(clip)
			var b: Animation = r.anim.get_animation(clip)
			if a == null or b == null:
				_check(false, "%s %s: missing (%s / %s)" % [id, clip, a, b])
				continue
			_check(absf(a.length - b.length) < 0.02, "%s %s: length %.3f vs %.3f" % [id, clip, a.length, b.length])
			var worst := [0.0, 0.0, "", 0.0]
			for f in [0.0, 0.25, 0.5, 0.75, 1.0]:
				for x in [m, r]:
					x.blend_time = 0.0
					x.play(clip)
					x.anim.seek(a.length * f, true)
					x.anim.speed_scale = 0.0
				var d := await _diff_after_update(m.skeleton, r.skeleton)
				if d[0] > worst[0] or d[1] > worst[1]:
					worst = [maxf(d[0], worst[0]), maxf(d[1], worst[1]), d[2], f]
			# cross-fade from idle into the clip, 0.1 s in
			for x in [m, r]:
				x.anim.speed_scale = 1.0
				x.blend_time = 0.0
				x.play("idle" if x.anim.has_animation("idle") else clip)
				x.anim.seek(0.4, true)
				x.blend_time = 0.25
				x.play(clip)
				x.anim.advance(0.1)
				x.anim.speed_scale = 0.0
			var bl := await _diff_after_update(m.skeleton, r.skeleton)
			var shared: bool = sh.get("clips", {}).has(clip)
			print("  %-13s %-6s pose diff max %.4f m / %.3f deg (%s at %d%%); idle->clip blend %.4f m / %.3f deg" % [
					clip, "shared" if shared else "own", worst[0], worst[1], worst[2], int(worst[3] * 100), bl[0], bl[1]])
			_check(worst[0] < POS_TOL and worst[1] < ROT_TOL, "%s %s: shared rebuild off the bake" % [id, clip])
			# Mid-fade into an own clip that turns the root bone (fly, swim) the offset rides the root
			# (shared) instead of the pelvis (bake): a few cm on a giant, gone when the fade ends.
			_check(bl[0] < 0.01 * float(m.info.get("scale_m", 1.8)), "%s %s: cross-fade off the bake by %.3f m" % [id, clip, bl[0]])
			for x in [m, r]:
				x.anim.speed_scale = 1.0
		m.queue_free()
		r.queue_free()
		await process_frame
	print("ALL PASS" if _fail == 0 else "FAIL (%d)" % _fail)
	quit(1 if _fail else 0)


## Bone poses as rendered: SkeletonModifier3D results (the lift) only exist between the
## modifier pass and skeleton_updated, then the animated pose is restored. Capture both there.
func _diff_after_update(a: Skeleton3D, b: Skeleton3D) -> Array:
	var got := {}
	var cap := func(sk: Skeleton3D, key: String) -> void:
		var poses := []
		for i in sk.get_bone_count():
			poses.append(sk.get_bone_global_pose(i))
		got[key] = poses
	a.skeleton_updated.connect(cap.bind(a, "a"))
	b.skeleton_updated.connect(cap.bind(b, "b"))
	for _i in 3:
		await process_frame
	for c in a.skeleton_updated.get_connections():
		a.skeleton_updated.disconnect(c["callable"])
	for c in b.skeleton_updated.get_connections():
		b.skeleton_updated.disconnect(c["callable"])
	return _diff(a, b, got.get("a", []), got.get("b", []))


## [max position diff m, max rotation diff deg, worst bone] over every bone's global pose,
## in each monster's own node space (both sit at the origin).
func _diff(a: Skeleton3D, b: Skeleton3D, pa: Array, pb: Array) -> Array:
	var dp := 0.0
	var dr := 0.0
	var worst := ""
	for i in a.get_bone_count():
		if i == a.find_bone("root"):   # its rest carries the pelvis offset on shared monsters (unweighted)
			continue
		var ga: Transform3D = pa[i] if i < pa.size() else a.get_bone_global_pose(i)
		var j := b.find_bone(a.get_bone_name(i))
		var gb: Transform3D = pb[j] if j < pb.size() else b.get_bone_global_pose(j)
		var p := ga.origin.distance_to(gb.origin)
		var r := rad_to_deg(ga.basis.get_rotation_quaternion().angle_to(gb.basis.get_rotation_quaternion()))
		if p > dp:
			dp = p
			worst = a.get_bone_name(i)
		dr = maxf(dr, r)
	return [dp, dr, worst]


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fail += 1
		print("CHECK FAILED: " + what)
