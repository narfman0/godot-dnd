## Import test for synced monsters (docs/monsters.md). Loads every monster in
## assets/monsters, binds every clip, plays it and prints a table plus per-monster facts:
##   godot --headless -s res://tools/check_monsters.gd [-- id ...]
## Prints ALL PASS / FAIL at the end; exit code 1 on failure.
extends SceneTree

const Monster = preload("res://scripts/monster.gd")
const Lab = preload("res://scripts/monster_lab.gd")

var _fail := 0
var _warns: Array[String] = []


func _initialize() -> void:
	var ids := OS.get_cmdline_user_args()
	if ids.is_empty():
		ids = Monster.list_ids()
	if ids.is_empty():
		print("no monsters in res://assets/monsters (run tools/sync_monsters.py)")
		quit(1)
		return
	var rows: Array[String] = []
	rows.append("| id | bones | LOD meshes (tris) | clips | tracks bound/total | rest AABB x,y,z m | scale_m | lowest y rest / move clip (bone) | upper-mass end dz |")
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
		details.append(await _loadout(m))
		var sw: String = await _swarm(m)
		if sw != "":
			details.append(sw)
		m.queue_free()
		await process_frame
	print("\n".join(rows))
	print("")
	print("\n".join(details))
	print("")
	await _props()
	print("")
	print("WARN (%d):" % _warns.size())
	for w in _warns:
		print("  " + w)
	print("ALL PASS" if _fail == 0 else "FAIL (%d)" % _fail)
	quit(1 if _fail else 0)


## Pipeline findings that do not break loading (geometry in the floor, pops between clips):
## listed at the end, not counted as failures.
func _warn(what: String) -> void:
	_warns.append(what)


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
		var clip: String = m.move_clip()   # walk, else swim / fly
		if clip == "":
			clip = clips[0]
		var a: Animation = m.anim.get_animation(clip)
		m.play(clip)
		var root_start := Vector3.ZERO
		var low := INF
		var low_bone := ""
		var moved := 0
		var moved_any := 0   # a one-bone swarm can sit at rest exactly mid-cycle
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
			for b in sk.get_bone_count():
				if _pose_dev(sk, b) > 0.1:
					moved_any += 1
			if i == n / 2:
				for b in sk.get_bone_count():
					if _pose_dev(sk, b) > 0.1:
						moved += 1
				d.append("  %s @ %.2fs: %d/%d bones posed off rest" % [clip, t, moved, sk.get_bone_count()])
				for k in range(1, m.lods.size()):
					var fd := _follow_dev(m, pos, k)
					d.append("    LOD%d follows the skeleton: skinned with its own vs the nearest LOD0 vertex's weights, median %.4f m, p95 %.4f m (LOD0 displacement p95 %.3f m; geometry: displacement vs nearest LOD0 vertex p95 %.4f m)" % [k, fd[0], fd[1], fd[2], fd[3]])
					_check(fd[1] < 0.1 * fd[2] + 0.005, "%s: LOD%d does not follow the skeleton (p95 %.3f m)" % [m.id, k, fd[1]])
				for so in ["hand_r", "hand_l", "grip_r", "grip_l"]:
					if m.has_socket(so):
						d.append("  " + _socket(m, pos, so))
		_check(moved_any > 0, "%s/%s: no bone moved" % [m.id, clip])
		var root_end := sk.get_bone_global_pose(0).origin
		d.append("  %s: root bone travels %s over the clip (in place if ~0); %.2fs %s" % [clip, root_end - root_start, a.length, ["once", "loop", "pingpong"][a.loop_mode]])
		walk_low = "%.3f %s (%s)" % [low, clip, low_bone]
		# Every clip plays a frame and moves bones.
		var per_clip := []
		for c in clips:
			m.play(c)
			# Mid-clip, else 30%: a loop whose layers are all sin(2 pi t) (the swarm's one
			# bone, the snake's standing-wave idle since round 8) is exactly at rest at t = 0.5.
			var mv := 0
			var at := 0.5
			for f in [0.5, 0.3]:
				m.anim.seek(m.anim.get_animation(c).length * f, true)
				at = f
				mv = 0
				for b in sk.get_bone_count():
					if _pose_dev(sk, b) > 0.1:
						mv += 1
				if mv > 0:
					break
			per_clip.append("%s %d bones%s" % [c, mv, "" if at == 0.5 else " (at 30%, rest mid-cycle)"])
			_check(mv > 0, "%s/%s: no bone moved" % [m.id, c])
		d.append("  played mid-clip: " + ", ".join(per_clip))
		d.append(await _playback(m))
		d.append(_ground(m))
		d.append(await _transition(m))
		d.append(_channels(m))
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
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	if rest:
		return v
	var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / v.size()
	var mats := _skin_mats(m, mi)
	var lift := _lift(m)
	var out := PackedVector3Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = _skin_point(mats, lift, v[i], bones, w, per, i)
	return out


## Bind matrices of mi's skin under the skeleton's current pose (pose x bind).
func _skin_mats(m: Node3D, mi: MeshInstance3D) -> Array[Transform3D]:
	var sk: Skeleton3D = m.skeleton
	var skin: Skin = mi.skin
	var mats: Array[Transform3D] = []
	for i in skin.get_bind_count():
		var b := skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(skin.get_bind_name(i))
		mats.append(sk.get_bone_global_pose(b) * skin.get_bind_pose(i))
	return mats


## Shared UAL clips: the floor lift is a SkeletonModifier3D on the root bone (an ancestor of
## every weighted bone); get_bone_global_pose() is the pose before modifiers, so add it.
func _lift(m: Node3D) -> Vector3:
	var sk: Skeleton3D = m.skeleton
	var mod: Node = sk.get_node_or_null("ual_lift")
	return Vector3.ZERO if mod == null else mod.axis * m.ual_lift_now()


## Point p skinned with vertex k's influences (bones, weights, per influences per vertex).
func _skin_point(mats: Array[Transform3D], lift: Vector3, p: Vector3, bones: PackedInt32Array, w: PackedFloat32Array, per: int, k: int) -> Vector3:
	var out := lift
	for j in per:
		var wt := w[k * per + j]
		if wt > 0.0:
			out += (mats[bones[k * per + j]] * p) * wt
	return out


## Degrees between a bone's pose and its rest (rotation; position error counted per cm,
## scale error per 0.01).
func _pose_dev(sk: Skeleton3D, b: int) -> float:
	var p := sk.get_bone_pose(b)
	var r := sk.get_bone_rest(b)
	var ang := rad_to_deg(p.basis.get_rotation_quaternion().angle_to(r.basis.get_rotation_quaternion()))
	# scale (blob squash and stretch, swarm): 0.01 scale counts like 1 deg
	return maxf(maxf(ang, p.origin.distance_to(r.origin) * 100.0), (p.basis.get_scale() - r.basis.get_scale()).length() * 100.0)


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
## the rest pose whose normal agrees (dot > 0.3; else the nearest) and skinned twice at its own rest position: with its own influences (as the
## engine draws it) and with the LOD0 vertex's. They agree when the LOD carries LOD0's skin
## weights. (Comparing displacements, |disp_k - disp_0|, also measured the decimation: a LOD3
## vertex 6-12 cm off its nearest LOD0 vertex (collapsed fingers, robe folds) moves differently
## under a large turn even with identical weights; bandit's death clip read 8.7 cm that way
## with weights that agree to 0.8 cm. That number is still printed, as "geometry".)
## Returns [median, p95 of the weights difference, p95 of |disp_0|, p95 of |disp_k - disp_0|].
func _follow_dev(m: Node3D, pos0: PackedVector3Array, k: int) -> Array:
	var rest0 := _skinned(m, m.lods[0], true)
	var restk := _skinned(m, m.lods[k], true)
	var posk := _skinned(m, m.lods[k], false)
	var arr0: Array = (m.lods[0] as MeshInstance3D).mesh.surface_get_arrays(0)
	var nrm0: PackedVector3Array = arr0[Mesh.ARRAY_NORMAL]
	var nrmk: PackedVector3Array = (m.lods[k] as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var bones0: PackedInt32Array = arr0[Mesh.ARRAY_BONES]
	var w0: PackedFloat32Array = arr0[Mesh.ARRAY_WEIGHTS]
	var per0 := bones0.size() / rest0.size()
	var mats0 := _skin_mats(m, m.lods[0])
	var lift := _lift(m)
	var geo := PackedFloat32Array()
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
		var agree := -1   # nearest whose normal agrees: where two sheets touch (tentacle on body) the
		var ad := INF     # nearest vertex can be on the other one
		for r in 3:
			for dx in range(-r, r + 1):
				for dy in range(-r, r + 1):
					for dz in range(-r, r + 1):
						for j in grid.get(c + Vector3i(dx, dy, dz), PackedInt32Array()):
							var dd := restk[i].distance_squared_to(rest0[j])
							if dd < bd:
								bd = dd
								best = j
							if dd < ad and nrm0[j].dot(nrmk[i]) > 0.3:
								ad = dd
								agree = j
			if agree >= 0:
				break
		if best >= 0:
			var ref := agree if agree >= 0 else best
			errs.append((posk[i] - _skin_point(mats0, lift, restk[i], bones0, w0, per0, ref)).length())
			geo.append(((posk[i] - restk[i]) - (pos0[best] - rest0[best])).length())
	errs.sort()
	mags.sort()
	geo.sort()
	return [errs[errs.size() / 2], errs[int(errs.size() * 0.95)], mags[int(mags.size() * 0.95)], geo[int(geo.size() * 0.95)]]


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
		worst = maxf(worst, (q.basis.get_scale() - (p[b] as Transform3D).basis.get_scale()).length() * 100.0)
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


## Every synced prop loads; its LODs share LOD0's material; size matches length_check.
func _props() -> void:
	var d := DirAccess.open(Monster.PROP_ROOT)
	if d == null:
		print("no props synced")
		return
	var rows := ["| prop | LODs (tris) | AABB x,y,z m | length_check m | grip_offset deg | offhand_grip node | string |", "|---|---|---|---|---|---|---|"]
	for pid in d.get_directories():
		var p: Node3D = Monster.load_prop(pid)
		if p == null:
			_check(false, "prop %s: %s" % [pid, Monster.last_error])
			continue
		var meshes: Array = p.get_meta("lod_meshes")
		var tris := []
		for mi in meshes:
			tris.append(str(mi.mesh.surface_get_array_index_len(0) / 3))
			_check(mi.get_active_material(0) == meshes[0].mesh.surface_get_material(0), "prop %s %s: not LOD0's material" % [pid, mi.name])
		var bb: AABB = meshes[0].mesh.get_aabb()
		var pm: Dictionary = p.get_meta("manifest").get("prop", {})
		var lc: Dictionary = pm.get("length_check", {})
		var ax := String(lc.get("axis", "+Y"))
		var meas := bb.size.y
		if ax.ends_with("Z"):
			meas = bb.size.z
		elif ax.begins_with("max"):
			meas = maxf(bb.size.x, bb.size.y)
		_check(absf(meas - float(lc.get("target_m", meas))) < 0.02, "prop %s: length %.3f, target %s" % [pid, meas, lc.get("target_m")])
		_check(bb.has_point(Vector3.ZERO) or bb.grow(0.01).has_point(Vector3.ZERO), "prop %s: origin (grip) outside the mesh bounds" % pid)
		var strings: Array = p.get_meta("string_meshes", [])
		var sname = (pm.get("nodes", {}) as Dictionary).get("string") if pm.get("nodes") is Dictionary else null
		var str_txt := "-"
		if sname != null:
			# Bows: the string is its own node and material in model.glb and every LOD, and
			# set_bowstring_visible hides all of them.
			_check(strings.size() == meshes.size(), "prop %s: string in %d of %d LODs" % [pid, strings.size(), meshes.size()])
			for smi in strings:
				_check(String((smi as MeshInstance3D).get_active_material(0).resource_name) == "bowstring", "prop %s %s: string material %s, not bowstring" % [pid, smi.name, (smi as MeshInstance3D).get_active_material(0).resource_name])
			Monster.set_bowstring_visible(p, false)
			var hidden := strings.all(func(x): return not x.visible)
			Monster.set_bowstring_visible(p, true)
			_check(hidden and strings.all(func(x): return x.visible), "prop %s: set_bowstring_visible does not toggle every string LOD" % pid)
			var sb: AABB = strings[0].mesh.get_aabb()
			str_txt = "%d LODs, %d tris, y %.2f..%.2f, z %.2f..%.2f, hide ok" % [strings.size(), strings[0].mesh.surface_get_array_index_len(0) / 3, sb.position.y, sb.end.y, sb.position.z, sb.end.z]
		else:
			_check(strings.is_empty(), "prop %s: string meshes without manifest.prop.nodes.string" % pid)
		var oh = p.find_child("offhand_grip", true, false)
		if pm.get("offhand_grip") != null:
			_check(oh != null, "prop %s: manifest has offhand_grip but model.glb has no such node" % pid)
		rows.append("| %s | %d (%s) | %.2f, %.2f, %.2f | %s %.2f | %s | %s | %s |" % [pid, meshes.size(), "/".join(tris), bb.size.x, bb.size.y, bb.size.z, ax, meas,
			p.get_meta("grip_offset").get("rotation_deg_xyz", "-"), ("%s" % (oh as Node3D).position) if oh else "-", str_txt])
		p.free()
	print("\n".join(rows))


## Swarms made as one unit (monster.json swarm_unit): spawn_swarm(12) as the lab does, then
## the units must fit the swarm's footprint (disc of diameter swarm.scale_m, plus one unit)
## and show different poses at the same moment (staggered phases).
func _swarm(m: Node3D) -> String:
	var su: Dictionary = m.swarm_info()
	if su.is_empty():
		return ""
	var units: Array = m.spawn_swarm(12)
	_check(units.size() == 11, "%s: spawn_swarm(12) made %d extra units" % [m.id, units.size()])
	var foot: float = float(su.get("swarm", {}).get("scale_m", 1.5))
	var b: AABB = m.swarm_aabb()
	_check(maxf(b.size.x, b.size.z) <= foot + float(su.get("scale_m", 0.3)) + 0.01, "%s: swarm spans %.2f x %.2f m, footprint %.2f m" % [m.id, b.size.x, b.size.z, foot])
	var clip: String = "idle" if "idle" in m.clips() else m.move_clip()
	m.play(clip)
	m.anim.seek(0.3, true)
	await process_frame
	await process_frame
	var poses := []
	for n in [m] + units:
		var s2: Skeleton3D = n.skeleton
		var q := PackedFloat32Array()
		for bi in s2.get_bone_count():
			var r := s2.get_bone_pose_rotation(bi)
			q.append_array([r.x, r.y, r.z, r.w])
		poses.append(q)
	var distinct := 0
	for i in poses.size():
		var same := false
		for j in i:
			var d := 0.0
			for k in poses[i].size():
				d = maxf(d, absf(poses[i][k] - poses[j][k]))
			if d < 1e-4:
				same = true
		if not same:
			distinct += 1
	_check(distinct >= poses.size() - 1, "%s: only %d of %d swarm units in distinct poses" % [m.id, distinct, poses.size()])
	var out := "  swarm: %d x %s (%s, %s m) over %.2f m: spans %.2f x %.2f x %.2f m, %d distinct %s poses at the same moment" % [
		units.size() + 1, su.get("unit"), su.get("plan"), su.get("scale_m"), foot, b.size.x, b.size.y, b.size.z, distinct, clip]
	m.spawn_swarm(1)
	m.play("rest")
	return out


## The lab's loadout, attached as the lab does it, sampled mid-clip: where the prop's tip
## (+Y) and edge/arrow (-Z) point in the world.
func _loadout(m: Node3D) -> String:
	var lo: Dictionary = Lab.loadout_for(m)
	var out := []
	if lo.is_empty():
		if not m.has_socket("grip_r"):
			return "  loadout: none (wields %s)" % [m.info.get("wields", [])]
		# Unarmed in the registry but the rig has a right grip (harpy): test it with a
		# longsword attached by hand, the way the lab's loadout_override does.
		lo = {"r": "longsword"}
		out.append("  loadout: none (wields %s); test prop %s on grip_r" % [m.info.get("wields", []), lo])
	else:
		out.append("  loadout: %s (wields %s, shield %s)" % [lo, m.info.get("wields", []), m.info.get("shield", false)])
	for side in lo:
		var sock: String = m.grip_socket(side)
		var p: Node3D = Monster.load_prop(lo[side])
		_check(p != null, "%s: prop %s does not load" % [m.id, lo[side]])
		if p != null and sock == "":
			# e.g. merfolk-skirmisher: a spear for the right hand, no hand_r bone. attach_prop
			# must refuse a missing bone (and free the prop) rather than attach anywhere.
			_check(not m.attach_prop(p, "hand_" + side) and m.props.is_empty(), "%s: attach_prop accepted missing bone hand_%s" % [m.id, side])
			out.append("    %s: no grip_%s / hand_%s bone, %s not attached (attach_prop refuses: ok)" % [m.id, side, side, lo[side]])
			_warn("%s wields %s but has no grip_%s / hand_%s socket: not shown" % [m.id, lo[side], side, side])
			continue
		if p == null:
			continue
		m.attach_prop(p, sock)
	await process_frame
	for clip in ["idle", "attack_melee", "attack_ranged"]:
		if not clip in m.clips():
			continue
		m.play(clip)
		m.anim.seek(m.anim.get_animation(clip).length * 0.5, true)
		await process_frame
		for side in lo:
			var ba: Node3D = m.props.get(m.grip_socket(side))
			if ba == null:
				continue
			var body := (ba.get_child(0) as Node3D).get_node("body") as Node3D
			var g := body.global_transform
			var pos := _skinned(m, m.lods[0], false)
			var near := INF
			var n5 := 0
			for v in pos:
				var dd := v.distance_to(g.origin)
				near = minf(near, dd)
				if dd < 0.05:
					n5 += 1
			out.append("    %s @50%% %s on %s: grip %s (nearest skin %.3f m, %d verts within 5 cm), tip (+Y) %s, edge/arrow (-Z) %s, scale %.3f" % [clip, lo[side], m.grip_socket(side),
				g.origin, near, n5, g.basis.y.normalized(), -g.basis.z.normalized(), g.basis.y.length()])
	for side in lo:
		m.detach_prop(m.grip_socket(side))
	m.play("rest")
	return "\n".join(out)


## Ground contact and height per clip, sampled at 13 frames (CPU skinning of LOD0):
## lowest vertex y at the first frame, minimum over the clip, at the last frame, and the root
## bone's y range. Then the jumps a clip switch makes without a cross-fade: the largest vertex
## distance between idle's first frame and this clip's first frame (entering it from idle),
## and between this clip's last frame and idle's first frame (settling back to idle).
## Hover clips (lift) should start at idle's height; death should end lying on y = 0.
func _ground(m: Node3D) -> String:
	var sk: Skeleton3D = m.skeleton
	var out := ["  ground per clip (lowest vertex y: first / min over clip / last frame; root y range; jump vs idle frame 0 entering / settling, m):"]
	var idle0 := PackedVector3Array()
	if "idle" in m.clips():
		m.play("idle")
		m.anim.seek(0.0, true)
		idle0 = _skinned(m, m.lods[0], false)
	var tol := 0.02 * maxf(float(m.info.get("scale_m", 1.0)), 1.0)
	for c in m.clips():
		var a: Animation = m.anim.get_animation(c)
		m.play(c)
		var n := 12
		var lo_min := INF
		var first := PackedVector3Array()
		var last := PackedVector3Array()
		var ry := Vector2(INF, -INF)
		for i in n + 1:
			m.anim.seek(a.length * i / n, true)
			var pos := _skinned(m, m.lods[0], false)
			lo_min = minf(lo_min, pos[_lowest(pos)].y)
			var r := sk.get_bone_global_pose(0).origin.y
			ry = Vector2(minf(ry.x, r), maxf(ry.y, r))
			if i == 0:
				first = pos
			if i == n:
				last = pos
		var lo0 := first[_lowest(first)].y
		var lo1 := last[_lowest(last)].y
		var jin := _max_dist(idle0, first) if idle0.size() and c != "idle" else 0.0
		var jout := _max_dist(last, idle0) if idle0.size() and c != "idle" and not c in m.HOLD_LAST else 0.0
		var seam := _max_dist(first, last) if c in m.LOOPING else -1.0
		var end_txt := ""
		if c in m.HOLD_LAST:
			# How the body ends: last-frame bounds (lying flat = low top) and how far the
			# root bone turned (a planted base keeps ~0).
			var eb := _aabb(last)
			end_txt = "; last frame bbox %.2f x %.2f x %.2f (top y %.3f, rest %.3f), root bone %s turned %.1f deg, moved %.2f m, scale %s" % [
				eb.size.x, eb.size.y, eb.size.z, eb.end.y, m.aabb.end.y, sk.get_bone_name(0),
				rad_to_deg(sk.get_bone_pose_rotation(0).angle_to(sk.get_bone_rest(0).basis.get_rotation_quaternion())),
				sk.get_bone_pose_position(0).distance_to(sk.get_bone_rest(0).origin), sk.get_bone_pose_scale(0)]
		out.append("    %s: %.3f / %.3f / %.3f; root y %.3f..%.3f; jump in %.3f out %.3f%s%s" % [c, lo0, lo_min, lo1, ry.x, ry.y, jin, jout,
			"" if seam < 0 else "; loop seam %.4f" % seam, end_txt])
		if lo_min < -0.03:
			_warn("%s/%s: geometry %.3f m below the floor" % [m.id, c, lo_min])
		if c in m.HOLD_LAST and absf(lo1) > 0.05:
			_warn("%s/%s: last frame's lowest point at y %.3f (not lying on the floor)" % [m.id, c, lo1])
		if seam > 0.01:
			_warn("%s/%s: loop seam %.3f m (first and last frame differ)" % [m.id, c, seam])
		if c != "idle" and idle0.size() and absf(lo0 - idle0[_lowest(idle0)].y) > tol:
			_warn("%s/%s: starts with its lowest point at y %.3f, idle at %.3f (height pop of %.2f m when switching)" % [m.id, c, lo0, idle0[_lowest(idle0)].y, absf(lo0 - idle0[_lowest(idle0)].y)])
	m.play("rest")
	return "\n".join(out)


func _max_dist(a: PackedVector3Array, b: PackedVector3Array) -> float:
	var w := 0.0
	for i in mini(a.size(), b.size()):
		w = maxf(w, a[i].distance_to(b[i]))
	return w


## Godot's glTF importer drops channels that never leave the rest pose. Read each clip GLB's
## own channels and check that every channel which does leave the rest pose (any key off the
## node's rest translation / rotation / scale) became a track of that type on that bone, and
## that scale tracks really play: seek to the key furthest from 1 and compare the bone's
## pose scale with the key.
func _channels(m: Node3D) -> String:
	var sk: Skeleton3D = m.skeleton
	var out := []
	for c in m.clips():
		var path := "%s/%s/anims/%s.glb" % [Monster.ROOT, m.id, c]
		var shared: Dictionary = m.ual_shared.get("clips", {})
		if shared.has(c):   # a shared UAL clip: the library's GLB (its rest is UAL's, as the tracks')
			var lib = JSON.parse_string(FileAccess.get_file_as_string("%s/%s/library.json" % [Monster.ROOT, m.ual_shared["library"]]))
			path = "%s/%s/%s" % [Monster.ROOT, m.ual_shared["library"], lib["clips"][shared[c]]["file"]]
		var g := _glb(path)
		if g.is_empty():
			_check(false, "%s/%s: cannot read %s" % [m.id, c, path])
			continue
		var j: Dictionary = g["json"]
		var bin: PackedByteArray = g["bin"]
		var a: Animation = m.anim.get_animation(c)
		var have := {}
		for t in a.get_track_count():
			have["%s|%d" % [String(a.track_get_path(t)).get_slice(":", 1), a.track_get_type(t)]] = t
		var moving := {"translation": 0, "rotation": 0, "scale": 0}
		var missing := []
		for anim in j.get("animations", []):
			for ch in anim["channels"]:
				var tgt: Dictionary = ch["target"]
				var node: Dictionary = j["nodes"][int(tgt["node"])]
				var prop: String = tgt["path"]
				if not moving.has(prop):
					continue
				var vals := _accessor(j, bin, int(anim["samplers"][int(ch["sampler"])]["output"]))
				var rest: Array = node.get(prop, {"translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]}[prop])
				var off := false
				for k in vals.size() / rest.size():
					for e in rest.size():
						if absf(vals[k * rest.size() + e] - float(rest[e])) > 1e-4:
							off = true
				if not off:
					continue
				moving[prop] += 1
				var ty: int = {"translation": Animation.TYPE_POSITION_3D, "rotation": Animation.TYPE_ROTATION_3D, "scale": Animation.TYPE_SCALE_3D}[prop]
				if not have.has("%s|%d" % [node.get("name", ""), ty]):
					missing.append("%s.%s" % [node.get("name", ""), prop])
		_check(missing.is_empty(), "%s/%s: GLB channels that leave the rest pose but have no Godot track: %s" % [m.id, c, missing])
		var scl := 0
		var scale_ok := ""
		for key in have:
			if not key.ends_with("|%d" % Animation.TYPE_SCALE_3D):
				continue
			scl += 1
			var t: int = have[key]
			var best := 0
			for k in a.track_get_key_count(t):
				if (a.track_get_key_value(t, k) - Vector3.ONE).length() > (a.track_get_key_value(t, best) - Vector3.ONE).length():
					best = k
			m.play(c)
			m.anim.seek(a.track_get_key_time(t, best), true)
			var b := sk.find_bone(key.get_slice("|", 0))
			var want: Vector3 = a.track_get_key_value(t, best)
			var got := sk.get_bone_pose_scale(b)
			_check(got.is_equal_approx(want) or (got - want).length() < 1e-3, "%s/%s: scale track on %s keys %s, the bone plays %s" % [m.id, c, sk.get_bone_name(b), want, got])
			scale_ok = " (scale plays: %s %s at %.2fs)" % [sk.get_bone_name(b), got, a.track_get_key_time(t, best)]
		out.append("%s GLB moving T/R/S %d/%d/%d -> tracks %d (scale %d)%s" % [c, moving["translation"], moving["rotation"], moving["scale"], a.get_track_count(), scl, scale_ok])
	m.play("rest")
	return "  channels: " + "; ".join(out)


## {json, bin} of a GLB, or {} on error.
func _glb(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	if f.get_32() != 0x46546C67:
		return {}
	f.get_32()
	f.get_32()
	var jl := f.get_32()
	f.get_32()
	var j = JSON.parse_string(f.get_buffer(jl).get_string_from_utf8())
	var bin := PackedByteArray()
	if f.get_position() < f.get_length():
		var bl := f.get_32()
		f.get_32()
		bin = f.get_buffer(bl)
	return {"json": j, "bin": bin} if j is Dictionary else {}


## Float accessor (VEC3 / VEC4 / SCALAR, tightly packed or strided) as a flat array.
func _accessor(j: Dictionary, bin: PackedByteArray, idx: int) -> PackedFloat32Array:
	var acc: Dictionary = j["accessors"][idx]
	var bv: Dictionary = j["bufferViews"][int(acc["bufferView"])]
	var comps: int = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[acc["type"]]
	var stride: int = int(bv.get("byteStride", comps * 4))
	var base: int = int(bv.get("byteOffset", 0)) + int(acc.get("byteOffset", 0))
	var out := PackedFloat32Array()
	if int(acc["componentType"]) != 5126:
		return out
	for i in int(acc["count"]):
		for e in comps:
			out.append(bin.decode_float(base + i * stride + e * 4))
	return out


## Switching idle -> move clip in real 30 fps frames: the largest distance any LOD0 vertex
## moves in one frame, with an instant switch and with Monster.blend_time 0.25 s, against
## the largest per-frame step inside the move clip itself (normal motion).
func _transition(m: Node3D) -> String:
	var mv: String = m.move_clip()
	if mv == "" or not "idle" in m.clips():
		return "  transition: no idle / move clip"
	var out := []
	var steady := 0.0
	for bt in [0.0, 0.25]:
		m.blend_time = bt
		m.play("idle")
		await _run(m, 0.5)
		var prev := _skinned(m, m.lods[0], false)
		m.play(mv)
		var worst := 0.0
		for i in 15:
			m.anim.advance(1.0 / 30.0)
			var pos := _skinned(m, m.lods[0], false)
			var step := _max_dist(prev, pos)
			if i >= 10 and bt == 0.0:
				steady = maxf(steady, step)
			elif i < 10:
				worst = maxf(worst, step)
			prev = pos
		out.append("%s %.3f m" % ["instant" if bt == 0.0 else "cross-fade %.2fs" % bt, worst])
	m.blend_time = 0.0
	m.play("rest")
	return "  transition idle -> %s, largest vertex step per 1/30 s frame: %s; inside %s %.3f m" % [mv, ", ".join(out), mv, steady]
