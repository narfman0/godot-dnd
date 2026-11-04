## Import test for synced monsters (docs/monsters.md). Loads every monster in
## assets/monsters, binds every clip, plays it and prints a table plus per-monster facts:
##   godot --headless -s res://tools/check_monsters.gd [-- id ...]
## Prints ALL PASS / FAIL at the end; exit code 1 on failure.
extends SceneTree

const Monster = preload("res://scripts/monster.gd")

var _fail := 0


func _initialize() -> void:
	var ids := OS.get_cmdline_user_args()
	if ids.is_empty():
		ids = Monster.list_ids()
	if ids.is_empty():
		print("no monsters in res://assets/monsters (run tools/sync_monsters.py)")
		quit(1)
		return
	var rows: Array[String] = []
	rows.append("| id | bones | LOD meshes (tris) | clips | tracks bound/total | rest AABB x,y,z m | scale_m | lowest y rest / walk (bone) | upper-mass end dz |")
	rows.append("|---|---|---|---|---|---|---|---|---|")
	var details: Array[String] = []
	for id in ids:
		var m: Node3D = Monster.load_monster(id)
		if m == null:
			_check(false, "%s: %s" % [id, Monster.last_error])
			continue
		root.add_child(m)
		await process_frame
		rows.append(await _row(m, details))
		m.queue_free()
		await process_frame
	print("\n".join(rows))
	print("")
	print("\n".join(details))
	print("ALL PASS" if _fail == 0 else "FAIL (%d)" % _fail)
	quit(1 if _fail else 0)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fail += 1
		print("CHECK FAILED: " + what)


func _row(m: Node3D, details: Array[String]) -> String:
	var sk: Skeleton3D = m.skeleton
	var info: Dictionary = m.info
	var lod_txt := []
	for mi in m.lods:
		lod_txt.append(str(mi.mesh.surface_get_array_index_len(0) / 3))
	_check(m.lods.size() == info["lods"].size(), "%s: %d LOD meshes, monster.json lists %d" % [m.id, m.lods.size(), info["lods"].size()])
	for e in m.report["lod_errors"]:
		_check(false, "%s: %s" % [m.id, e])
	# Same skeleton/skin for every LOD
	for mi in m.lods:
		_check(mi.skin == m.lods[0].skin and mi.get_node(mi.skeleton) == sk, "%s %s: not on LOD0's skeleton/skin" % [m.id, mi.name])
		_check(mi.get_active_material(0) == m.lods[0].mesh.surface_get_material(0), "%s %s: not LOD0's material" % [m.id, mi.name])
	var tex = m.lods[0].mesh.surface_get_material(0).albedo_texture
	_check(tex != null, "%s: LOD0 material has no albedo texture" % m.id)

	var clip_txt := []
	for clip in m.report["clips"]:
		var r: Dictionary = m.report["clips"][clip]
		clip_txt.append("%s %d/%d" % [clip, r["bound"], r["tracks"]])
		_check(r["error"] == "", "%s/%s: %s" % [m.id, clip, r["error"]])
		_check(r["tracks"] > 0 and r["bound"] == r["tracks"], "%s/%s: %d of %d tracks bound, unbound %s" % [m.id, clip, r["bound"], r["tracks"], r["unbound"]])

	# Rest pose geometry (LOD0, mesh space == monster space: all nodes are identity).
	var rest := _skinned(m, m.lods[0], true)
	var bb := _aabb(rest)
	var h := bb.size.y
	_check(absf(bb.position.y) < 0.01, "%s: lowest rest vertex y = %.3f" % [m.id, bb.position.y])
	var face := _facing(rest, bb)
	var hand_x := ""
	if m.has_socket("hand_r"):
		var hp := sk.get_bone_global_rest(sk.find_bone("hand_r")).origin
		var hl := sk.get_bone_global_rest(sk.find_bone("hand_l")).origin if m.has_socket("hand_l") else Vector3.ZERO
		hand_x = ", hand_r.x %+.2f hand_l.x %+.2f" % [hp.x, hl.x]
	var d := ["%s: bbox min %s max %s; facing: head-end dz %+.3f (top 25%% centroid z - body centroid z), toe dz %+.3f (feet band - shin band), extreme z of top 25%% [%.2f, %.2f]%s" % [m.id, bb.position, bb.end, face[0], face[1], face[2], face[3], hand_x]]

	# Walk (or first clip): play mid-cycle, check bones move, LODs agree, feet stay down.
	var walk_low := "-"
	var clips: PackedStringArray = m.clips()
	if clips.size():
		var clip := "walk" if "walk" in clips else clips[0]
		var a: Animation = m.anim.get_animation(clip)
		m.play(clip)
		var root_start := Vector3.ZERO
		var low := INF
		var low_bone := ""
		var moved := 0
		var n := 8
		for i in n + 1:
			var t := a.length * i / n
			m.anim.seek(t, true)
			var pos := _skinned(m, m.lods[0], false)
			var lo := _lowest(pos)
			if pos[lo].y < low:
				low = pos[lo].y
				low_bone = _dominant_bone(m, lo)
			if i == 0:
				root_start = sk.get_bone_global_pose(0).origin
			if i == n / 2:
				for b in sk.get_bone_count():
					if _pose_dev(sk, b) > 0.1:
						moved += 1
				d.append("  %s @ %.2fs: %d/%d bones posed off rest" % [clip, t, moved, sk.get_bone_count()])
				_check(moved > 0, "%s/%s: no bone moved" % [m.id, clip])
				for k in range(1, m.lods.size()):
					var fd := _follow_dev(m, pos, k)
					d.append("    LOD%d follows the skeleton: vertex displacement vs nearest LOD0 vertex, median %.4f m, p95 %.4f m (LOD0 displacement p95 %.3f m)" % [k, fd[0], fd[1], fd[2]])
					_check(fd[1] < 0.1 * fd[2] + 0.005, "%s: LOD%d does not follow the skeleton (p95 %.3f m)" % [m.id, k, fd[1]])
				for so in ["hand_r", "hand_l", "grip_r", "grip_l"]:
					if m.has_socket(so):
						d.append("  " + _socket(m, pos, so))
		var root_end := sk.get_bone_global_pose(0).origin
		d.append("  %s: root bone travels %s over the clip (in place if ~0); %.2fs %s" % [clip, root_end - root_start, a.length, ["once", "loop", "pingpong"][a.loop_mode]])
		walk_low = "%.3f (%s)" % [low, low_bone]
		# Every clip plays a frame and moves bones.
		var per_clip := []
		for c in clips:
			m.play(c)
			m.anim.seek(m.anim.get_animation(c).length * 0.5, true)
			var mv := 0
			for b in sk.get_bone_count():
				if _pose_dev(sk, b) > 0.1:
					mv += 1
			per_clip.append("%s %d bones" % [c, mv])
			_check(mv > 0, "%s/%s: no bone moved" % [m.id, c])
		d.append("  played mid-clip: " + ", ".join(per_clip))
		d.append(await _playback(m))
		for side in ["r", "l"]:
			var g: String = "grip_" + side
			if not m.has_socket(g):
				continue
			var gr := sk.get_bone_global_rest(sk.find_bone(g))
			d.append("  %s rest: +Y %s (forward = -Z), +Z %s (up = +Y), %.3f m from hand_%s" % [g, gr.basis.y.normalized(), gr.basis.z.normalized(), gr.origin.distance_to(sk.get_bone_global_rest(sk.find_bone("hand_" + side)).origin), side])
			var atk := "attack_melee" if side == "r" else "attack_ranged"
			if atk in clips:
				for f in [0.25, 0.5, 0.75]:
					m.play(atk)
					m.anim.seek(m.anim.get_animation(atk).length * f, true)
					d.append("    %s @ %d%%: %s" % [atk, int(f * 100), _socket(m, _skinned(m, m.lods[0], false), g)])
		# Switching clips: bones the new clip does not key must go back to rest (Godot drops
		# glTF channels that never leave the rest pose, so clips key different bone sets).
		m.play(clip)
		m.anim.seek(a.length * 0.5, true)
		var probe := Animation.new()
		probe.length = 1.0
		var tr := probe.add_track(Animation.TYPE_ROTATION_3D)
		probe.track_set_path(tr, NodePath("%s:%s" % [m.get_path_to(sk), sk.get_bone_name(0)]))
		probe.rotation_track_insert_key(tr, 0.0, sk.get_bone_rest(0).basis.get_rotation_quaternion())
		m.anim.get_animation_library("").add_animation("_probe", probe)
		m.anim.play("_probe")
		m.anim.seek(0.1, true)
		var stuck := 0
		var worst := 0.0
		for b in sk.get_bone_count():
			var dev := _pose_dev(sk, b)
			worst = maxf(worst, dev)
			if dev > 0.1:
				stuck += 1
		d.append("  switch %s -> a clip keying only %s: %d bones left off rest by > 0.1 deg (worst %.3f deg; 0 = mixer resets unkeyed bones)" % [clip, sk.get_bone_name(0), stuck, worst])
		_check(stuck == 0, "%s: %d bones keep the previous clip's pose after a clip switch" % [m.id, stuck])
		m.anim.stop()
		m.anim.get_animation_library("").remove_animation("_probe")
	details.append("\n".join(d))
	var facing := "%+.2f" % face[0]
	return "| %s | %d | %d (%s) | %d | %s | %.2f, %.2f, %.2f | %s | %.3f / %s | %s |" % [
		m.id, sk.get_bone_count(), m.lods.size(), " / ".join(lod_txt), clips.size(), ", ".join(clip_txt),
		bb.size.x, bb.size.y, bb.size.z, info.get("scale_m"), bb.position.y, walk_low, facing]


## CPU linear-blend skinning of a MeshInstance3D's surface 0 with the current (or rest) pose,
## in the monster's space. Godot skins on the GPU and has no readback, so this re-does it.
func _skinned(m: Node3D, mi: MeshInstance3D, rest: bool) -> PackedVector3Array:
	var sk: Skeleton3D = m.skeleton
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if rest:
		return v
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / v.size()
	var skin: Skin = mi.skin
	var mats: Array[Transform3D] = []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		mats.append(sk.get_bone_global_pose(b) * skin.get_bind_pose(i))
	var out := PackedVector3Array()
	out.resize(v.size())
	for i in v.size():
		var p := Vector3.ZERO
		for j in per:
			var wt := w[i * per + j]
			if wt > 0.0:
				p += (mats[bones[i * per + j]] * v[i]) * wt
		out[i] = p
	return out


## Degrees between a bone's pose and its rest (rotation; position error counted per cm).
func _pose_dev(sk: Skeleton3D, b: int) -> float:
	var p := sk.get_bone_pose(b)
	var r := sk.get_bone_rest(b)
	var ang := rad_to_deg(p.basis.get_rotation_quaternion().angle_to(r.basis.get_rotation_quaternion()))
	return maxf(ang, p.origin.distance_to(r.origin) * 100.0)


func _lowest(pts: PackedVector3Array) -> int:
	var best := 0
	for i in pts.size():
		if pts[i].y < pts[best].y:
			best = i
	return best


func _dominant_bone(m: Node3D, vi: int) -> String:
	var arr: Array = m.lods[0].mesh.surface_get_arrays(0)
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var best := 0
	for j in per:
		if w[vi * per + j] > w[vi * per + best]:
			best = j
	var skin: Skin = m.lods[0].skin
	return m.skeleton.get_bone_name(skin.get_bind_bone(bones[vi * per + best]))


func _aabb(pts: PackedVector3Array) -> AABB:
	var bb := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		bb = bb.expand(p)
	return bb


## Does LOD k deform like LOD0? Each LOD k vertex is matched to its nearest LOD0 vertex in
## the rest pose; with the same skeleton and skin their displacements under the current pose
## agree. Returns [median, p95 of |disp_k - disp_0|, p95 of |disp_0|].
func _follow_dev(m: Node3D, pos0: PackedVector3Array, k: int) -> Array:
	var rest0 := _skinned(m, m.lods[0], true)
	var restk := _skinned(m, m.lods[k], true)
	var posk := _skinned(m, m.lods[k], false)
	var cell := 0.05 * maxf(m.aabb.size.y, 0.5)
	var grid := {}
	for i in rest0.size():
		var c := Vector3i((rest0[i] / cell).floor())
		if not grid.has(c):
			grid[c] = PackedInt32Array()
		grid[c].append(i)
	var errs := PackedFloat32Array()
	var mags := PackedFloat32Array()
	for i in rest0.size():
		mags.append((pos0[i] - rest0[i]).length())
	for i in restk.size():
		var c := Vector3i((restk[i] / cell).floor())
		var best := -1
		var bd := INF
		for r in 3:
			for dx in range(-r, r + 1):
				for dy in range(-r, r + 1):
					for dz in range(-r, r + 1):
						for j in grid.get(c + Vector3i(dx, dy, dz), PackedInt32Array()):
							var dd := restk[i].distance_squared_to(rest0[j])
							if dd < bd:
								bd = dd
								best = j
			if best >= 0:
				break
		if best >= 0:
			errs.append(((posk[i] - restk[i]) - (pos0[best] - rest0[best])).length())
	errs.sort()
	mags.sort()
	return [errs[errs.size() / 2], errs[int(errs.size() * 0.95)], mags[int(mags.size() * 0.95)]]


## [head-end dz, toe dz, min z of top band, max z of top band]
func _facing(pts: PackedVector3Array, bb: AABB) -> Array:
	var h := bb.size.y
	var all_z := 0.0
	var top_z := 0.0
	var top_n := 0
	var top_min := INF
	var top_max := -INF
	var foot_z := 0.0
	var foot_n := 0
	var shin_z := 0.0
	var shin_n := 0
	for p in pts:
		var y := p.y - bb.position.y
		all_z += p.z
		if y > 0.75 * h:
			top_z += p.z
			top_n += 1
			top_min = minf(top_min, p.z)
			top_max = maxf(top_max, p.z)
		if y < 0.04 * h:
			foot_z += p.z
			foot_n += 1
		elif y < 0.2 * h:
			shin_z += p.z
			shin_n += 1
	return [top_z / maxi(top_n, 1) - all_z / pts.size(),
			foot_z / maxi(foot_n, 1) - shin_z / maxi(shin_n, 1), top_min, top_max]


## Loop modes come from Monster.LOOPING, not the GLB: looping clips keep playing past their
## length; one-shots stop on their last frame; with settle_clip they hand over to idle,
## except death, which holds.
func _playback(m: Node3D) -> String:
	var sk: Skeleton3D = m.skeleton
	var out := []
	for c in m.clips():
		var a: Animation = m.anim.get_animation(c)
		m.settle_clip = ""
		m.play(c)
		m.anim.seek(a.length, true)
		var last := _pose(sk)
		m.play("rest")
		m.play(c)
		await _run(m, a.length + 0.3)
		var playing: bool = m.anim.is_playing()
		var dev := _pose_diff(sk, last)
		var looping: bool = c in m.LOOPING
		if looping:
			_check(playing and a.loop_mode == Animation.LOOP_LINEAR, "%s/%s should loop" % [m.id, c])
			out.append("%s loops" % c)
		else:
			_check(not playing and dev < 0.1 and a.loop_mode == Animation.LOOP_NONE, "%s/%s should play once and hold its last frame (playing %s, %.2f deg off last frame)" % [m.id, c, playing, dev])
			var settled := ""
			m.settle_clip = "idle" if "idle" in m.clips() else ""
			m.play("rest")
			m.play(c)
			await _run(m, a.length + 0.3)
			settled = m.anim.current_animation if m.anim.is_playing() else "holds"
			if c in m.HOLD_LAST:
				_check(settled == "holds" and _pose_diff(sk, last) < 0.1, "%s/%s should hold its last frame even with settle_clip" % [m.id, c])
			out.append("%s once, holds last frame (%.2f deg); with settle_clip=idle -> %s" % [c, dev, settled])
	m.settle_clip = ""
	m.play("rest")
	return "  playback (real frames): " + "; ".join(out)


func _run(m: Node3D, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		m.anim.advance(1.0 / 30.0)
		t += 1.0 / 30.0
		await process_frame


func _pose(sk: Skeleton3D) -> Array:
	var p := []
	for b in sk.get_bone_count():
		p.append(sk.get_bone_pose(b))
	return p


func _pose_diff(sk: Skeleton3D, p: Array) -> float:
	var worst := 0.0
	for b in sk.get_bone_count():
		var q: Transform3D = sk.get_bone_pose(b)
		worst = maxf(worst, rad_to_deg(q.basis.get_rotation_quaternion().angle_to((p[b] as Transform3D).basis.get_rotation_quaternion())))
		worst = maxf(worst, q.origin.distance_to((p[b] as Transform3D).origin) * 100.0)
	return worst


## Where the socket bone is relative to the skinned surface, and which way its +Y points.
func _socket(m: Node3D, pos: PackedVector3Array, socket: String) -> String:
	var sk: Skeleton3D = m.skeleton
	var b := sk.find_bone(socket)
	var g := sk.get_bone_global_pose(b)
	var near := INF
	var n_close := 0
	var n5 := 0
	for p in pos:
		var dd := p.distance_to(g.origin)
		near = minf(near, dd)
		if dd < 0.1:
			n_close += 1
		if dd < 0.05:
			n5 += 1
	var par := sk.get_bone_parent(b)
	var par_dir := (g.origin - sk.get_bone_global_pose(par).origin).normalized()
	var ang := rad_to_deg(g.basis.y.normalized().angle_to(par_dir))
	return "%s: global %s, nearest skinned vertex %.3f m, %d verts within 5 cm, %d within 10 cm; +Y %s (%.0f deg from parent bone %s direction); -Z %s" % [
		socket, g.origin, near, n5, n_close, g.basis.y.normalized(), ang, sk.get_bone_name(par), -g.basis.z.normalized()]
