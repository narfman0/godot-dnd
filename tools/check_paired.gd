## Paired animations (docs/monsters.md "Paired animations"): plays each pair through
## scripts/paired_anim.gd frame by frame and checks, on the pose as rendered (after the
## SkeletonModifier3Ds), that every contact at full weight stays within its tolerance
## (sidecar tolerance x mean hip_scale), that nothing explodes (every bone within 2 x scale_m of
## its monster, finite) and that the feet stay on the floor.
##   godot --headless -s res://tools/check_paired.gd -- [entry=grapple] [initiator:receiver[:refuse] ...]
## Default pairs: tough:bandit (similar size), ogre:bandit (large grabs medium) and tough:hill-giant:refuse
## (Huge is two sizes up: start() must refuse it, sidecar max_size_up). Prints ALL PASS / FAIL; exit
## code 1 on failure.
extends SceneTree

const Monster = preload("res://scripts/monster.gd")
const PairedAnim = preload("res://scripts/paired_anim.gd")

var _fail := 0


func _initialize() -> void:
	var entry := "grapple"
	var pairs := []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("entry="):
			entry = a.substr(6)
		elif ":" in a:
			pairs.append(a.split(":"))
	if pairs.is_empty():
		pairs = [["tough", "bandit"], ["ogre", "bandit"], ["tough", "hill-giant", "refuse"]]
	for pr in pairs:
		if pr.size() > 2 and pr[2] == "refuse":
			await _refuse(entry, pr[0], pr[1])
		else:
			await _run(entry, pr[0], pr[1])
	print("ALL PASS" if _fail == 0 else "FAIL (%d)" % _fail)
	quit(1 if _fail else 0)


func _run(entry: String, i_id: String, r_id: String) -> void:
	var ini: Node3D = Monster.load_monster(i_id)
	var rec: Node3D = Monster.load_monster(r_id)
	if ini == null or rec == null:
		_check(false, "%s / %s: load failed: %s" % [i_id, r_id, Monster.last_error])
		return
	root.add_child(ini)
	root.add_child(rec)
	ini.play("idle")
	rec.play("idle")
	rec.position = Vector3(0.3, 0, -2.0)   # off the alignment: the warp has to bring it in
	await process_frame
	var pair = PairedAnim.new()
	root.add_child(pair)
	pair.set_process(false)   # stepped below, one clip frame at a time
	if not pair.start(entry, ini, rec):
		_check(false, "%s -> %s: start failed: %s" % [i_id, r_id, pair.last_error])
		return
	var v: Dictionary = pair.variant
	var ms: float = (pair.scale["initiator"] + pair.scale["receiver"]) * 0.5
	print("%s -> %s: variant %s (ratio %.3f), offset scale %.3f, receiver at %s" % [i_id, r_id, v["name"],
			pair.scale["receiver"] / pair.scale["initiator"], pair.offset_scale, pair.aligned.origin])
	var worst := {}
	var solver := {}
	var at_sync := {}
	var lean := 0.0
	var feet := 0.0
	var spread := 0.0
	var poses := {}
	var cap := func(role: String, sk: Skeleton3D) -> void:
		var g := []
		for i in sk.get_bone_count():
			g.append(sk.global_transform * sk.get_bone_global_pose(i))
		poses[role] = g
	ini.skeleton.skeleton_updated.connect(cap.bind("initiator", ini.skeleton))
	rec.skeleton.skeleton_updated.connect(cap.bind("receiver", rec.skeleton))
	var n := int(v["frames"])
	for f in range(1, n + 1):
		pair.step(1.0 / pair.fps)
		poses.clear()
		await process_frame
		await process_frame
		if not pair.running and f < n:
			_check(false, "stopped early at %d" % f)
			break
		if f == n:
			break   # stop() handed over to idle
		for c in v["contacts"]:
			var w := PairedAnim.contact_weight(c, pair.frame)
			if w < 1.0:
				continue
			var a: Vector3 = _point(pair, poses, c["from"])
			var b: Vector3 = _point(pair, poses, c["to"])
			var d := a.distance_to(b)
			worst[c["name"]] = maxf(worst.get(c["name"], 0.0), d)
			solver[c["name"]] = maxf(solver.get(c["name"], 0.0), pair.last_contacts[c["name"]][1])
			if int(round(pair.frame)) == int(v["sync_frame"]):
				at_sync[c["name"]] = d
		for role in ["initiator", "receiver"]:
			var m: Node3D = pair.actors[role]
			var g: Array = poses.get(role, [])
			if g.is_empty():
				_check(false, "%s: no skeleton update at frame %d" % [role, f])
				continue
			for t in g:
				var o: Vector3 = (t as Transform3D).origin
				if not o.is_finite():
					_check(false, "%s: non-finite bone at frame %d" % [role, f])
					break
				spread = maxf(spread, o.distance_to(m.global_position) / float(m.info.get("scale_m", 1.8)))
			for s in ["l", "r"]:
				var foot: Vector3 = (g[m.skeleton.find_bone("foot_" + s)] as Transform3D).origin
				feet = maxf(feet, absf(foot.y - m.global_position.y) / float(m.info.get("scale_m", 1.8)))
		lean = maxf(lean, pair.last_lean.get("initiator", 0.0))
	for c in v["contacts"]:
		var tol: float = float(c["tolerance"]) * ms
		var d: float = worst.get(c["name"], -1.0)
		print("  %-46s full contact %s: max %.4f m (solver %.4f, sync %s) tol %.3f" % [c["name"], c["frames"], d,
				solver.get(c["name"], -1.0), "%.4f" % at_sync[c["name"]] if at_sync.has(c["name"]) else "-", tol])
		_check(d >= 0.0 and d <= tol, "%s: contact %s off by %.3f m" % [i_id + "->" + r_id, c["name"], d])
	print("  lean max %.1f deg, bones within %.2f x scale_m, ankles max %.3f x scale_m off the floor" % [lean, spread, feet])
	_check(spread < 2.0, "bones exploded (%.2f x scale_m)" % spread)
	_check(feet < 0.12, "feet off the floor (%.3f x scale_m)" % feet)
	await process_frame
	_check(ini.current_clip == "idle" and rec.current_clip == "idle", "exit: %s / %s, not idle" % [ini.current_clip, rec.current_clip])
	ini.queue_free()
	rec.queue_free()
	pair.queue_free()
	await process_frame


## start() must refuse the pair on size (the receiver more than max_size_up categories larger)
## and leave both monsters untouched.
func _refuse(entry: String, i_id: String, r_id: String) -> void:
	var ini: Node3D = Monster.load_monster(i_id)
	var rec: Node3D = Monster.load_monster(r_id)
	if ini == null or rec == null:
		_check(false, "%s / %s: load failed: %s" % [i_id, r_id, Monster.last_error])
		return
	root.add_child(ini)
	root.add_child(rec)
	ini.play("idle")
	rec.play("idle")
	var before := rec.transform
	await process_frame
	var pair = PairedAnim.new()
	root.add_child(pair)
	pair.set_process(false)
	var ok := pair.start(entry, ini, rec)
	print("%s -> %s: %s (%s / %s, %d sizes up)" % [i_id, r_id, "started" if ok else "refused: " + pair.last_error,
			ini.info.get("size", "?"), rec.info.get("size", "?"), PairedAnim.sizes_up(ini, rec)])
	_check(not ok, "%s -> %s: started, should be refused on size" % [i_id, r_id])
	_check(pair.last_error.contains("sizes larger"), "%s -> %s: refused for another reason: %s" % [i_id, r_id, pair.last_error])
	_check(not pair.running and rec.transform == before, "%s -> %s: refused pair moved the receiver" % [i_id, r_id])
	ini.queue_free()
	rec.queue_free()
	pair.queue_free()
	await process_frame


func _point(pair, poses: Dictionary, spec: Dictionary) -> Vector3:
	var role: String = spec["role"]
	var sk: Skeleton3D = pair.actors[role].skeleton
	var g: Array = poses[role]
	var b := sk.find_bone(spec["bone"])
	var fb := sk.find_bone(spec.get("frame_bone", spec["bone"]))
	var o: Array = spec["offset"]
	return (g[b] as Transform3D).origin + (g[fb] as Transform3D).basis.orthonormalized() * (Vector3(o[0], o[1], o[2]) * pair.scale[role])


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fail += 1
		print("CHECK FAILED: " + what)
