## Paired (synced) animations between two UAL bipeds (docs/monsters.md "Paired animations";
## the data format is monster-forge docs/anim-reuse.md "Paired animations").
##
##   const PairedAnim = preload("res://scripts/paired_anim.gd")
##   var pair := PairedAnim.new()
##   add_child(pair)
##   if pair.start("grapple", ogre, bandit):       # initiator, receiver (Monster nodes, same parent space)
##       await pair.finished                        # both are back in their exit clip (idle)
##
## A paired entry (assets/monsters/_shared/paired/<entry>.json) has variants authored for a range of
## size ratios (receiver hip_scale / initiator hip_scale); each names one clip per role (in the same
## format as the shared UAL clips, so Monster plays them with its own hip_scale and pelvis offset),
## an alignment (where the receiver stands relative to the initiator) and contacts (a point on one
## actor held on a point of the other). start():
##   1. picks the variant for the two actors' hip_scales (false when none fits);
##   2. fits the alignment: the offset scaled so each contact's arm needs the reach it had when
##      authored on the sync frame, but never closer than the two torso fronts (+ min_gap);
##   3. slides the receiver onto it over warp_frames, starts both clips on the same frame and
##      advances both AnimationPlayers itself (manual callback mode), so they stay in lockstep;
##   4. every frame, per contact with weight > 0: bends the IK role's lean bones toward the targets
##      when needed (lean), then a two-bone IK puts the contact's "from" point on its "to" point,
##      keeping the animated bend plane and the end bone's local rotation. Contacts are solved in
##      order on world-space bone transforms computed here (not by each skeleton's own update), so
##      a hand can hold a forearm that an earlier contact moved; a PairedPose SkeletonModifier3D on
##      each skeleton then writes the solved rotations;
##   5. at the last frame plays each actor's exit clip (Monster.play, cross-faded) and frees the
##      modifiers. stop() ends early the same way.
## Why not TwoBoneIK3D: it solves each skeleton in its own (deferred) update, so the receiver could
## only follow the initiator's forearm a frame late, and it has no lean; the solve here is the one
## monster-forge tools/paired.py checks offline, so both agree.
extends Node

signal finished

const ROOT := "res://assets/monsters/_shared/paired"
const LIB := "_shared/paired"
const TORSO := ["spine_01", "spine_02", "spine_03"]

var entry: Dictionary = {}
var variant: Dictionary = {}
var actors: Dictionary = {}          ## role -> Monster
var scale: Dictionary = {}           ## role -> hip_scale
var offset_scale := 1.0              ## the fitted alignment scale k
var frame := 0.0                     ## clip frame now
var fps := 30.0
var speed := 1.0
var running := false
var exit_blend := 0.25
## Per frame after step(): {contact name: [weight, distance m]} measured on the solved pose, and the
## lean (degrees) per role.
var last_contacts: Dictionary = {}
var last_lean: Dictionary = {}

var _mods: Dictionary = {}           ## role -> PairedPose
var _warp_from: Transform3D
## Where start() places the receiver (parent space): walk it there first, the warp is for small
## corrections (sidecar warp_frames).
var aligned: Transform3D
var _orders: Dictionary = {}         ## role -> bone indices parents first
var _saved_mode: Dictionary = {}


## The modifier that writes solved rotations ({bone index: local Quaternion}) on its skeleton.
class PairedPose extends SkeletonModifier3D:
	var rotations: Dictionary = {}

	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		for b in rotations:
			sk.set_bone_pose_rotation(b, rotations[b])


static func load_entry(name: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("%s/%s.json" % [ROOT, name]))
	return parsed if parsed is Dictionary else {}


## The variant whose ratio range holds s_receiver / s_initiator (0.05 slack), or {}.
static func pick_variant(e: Dictionary, s_i: float, s_r: float) -> Dictionary:
	var r := s_r / s_i
	var best := {}
	var bd := 1e9
	for v in e.get("variants", []):
		var lo := float(v["ratio"][0])
		var hi := float(v["ratio"][1])
		var d := 0.0 if (r >= lo and r <= hi) else minf(absf(r - lo), absf(r - hi))
		if d < bd:
			best = v
			bd = d
	return best if bd <= 0.05 else {}


## Starts the pair; both Monster nodes must share a parent space (the receiver is moved). False
## (see last_error) when the entry is missing, an actor has no shared UAL data, or no variant fits.
var last_error := ""
func start(entry_name: String, initiator: Node3D, receiver: Node3D) -> bool:
	last_error = ""
	entry = load_entry(entry_name)
	if entry.is_empty():
		last_error = "no paired entry %s" % entry_name
		return false
	actors = {"initiator": initiator, "receiver": receiver}
	for role in actors:
		var m: Node3D = actors[role]
		if m.ual_shared.is_empty():
			last_error = "%s: no ual_shared (not a UAL biped with shared clips)" % m.id
			return false
		scale[role] = float(m.ual_shared["hip_scale"])
	variant = pick_variant(entry, scale["initiator"], scale["receiver"])
	if variant.is_empty():
		last_error = "%s: no variant for size ratio %.2f" % [entry_name, scale["receiver"] / scale["initiator"]]
		return false
	fps = float(entry.get("fps", 30))
	for role in actors:
		var m: Node3D = actors[role]
		if not m.anim.has_animation_library("paired"):
			var lib: AnimationLibrary = m._ual_library(LIB)
			if lib == null:
				last_error = "paired library: %s" % m.last_error
				return false
			m.anim.add_animation_library("paired", lib)
		_orders[role] = _bone_order(m.skeleton)
		m.set_meta("torso_front", _torso_front(m))
	# the clips, paused at the fit frame, for the alignment fit
	for role in actors:
		var m: Node3D = actors[role]
		m.anim.play("paired/" + variant["clips"][role], 0.0)
		m.anim.seek(_t(float(variant["alignment"].get("fit", {}).get("frame", variant["sync_frame"]))), true)
	offset_scale = _fit_offset()
	var al: Dictionary = variant["alignment"]
	var off: Array = al["offset"]
	aligned = initiator.transform * Transform3D(Basis(Vector3.UP, deg_to_rad(float(al["yaw_deg"]))),
			Vector3(off[0], off[1], off[2]) * offset_scale)
	_warp_from = receiver.transform
	if int(al.get("warp_frames", 0)) <= 0:
		receiver.transform = aligned
	# both clips from frame 0, advanced by us
	for role in actors:
		var m: Node3D = actors[role]
		_saved_mode[role] = m.anim.callback_mode_process
		m.anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		m.blend_time = 0.15
		m.settle_clip = ""
		m.play("paired/" + variant["clips"][role])
		m.anim.seek(0.0, true)
		var mod := PairedPose.new()
		mod.name = "paired_pose"
		m.skeleton.add_child(mod)
		_mods[role] = mod
	frame = 0.0
	running = true
	_solve()
	return true


func _ready() -> void:
	process_priority = -1000   # before the skeletons apply their modifiers this frame


func _process(delta: float) -> void:
	if running:
		step(delta * speed)


## Advances the pair by dt seconds (tests call this with process off) and solves the contacts.
func step(dt: float) -> void:
	if not running:
		return
	var n := float(variant["frames"])
	frame = minf(frame + dt * fps, n)
	for role in actors:
		actors[role].anim.advance(dt)
	var wf := float(variant["alignment"].get("warp_frames", 0))
	if wf > 0:
		var x := clampf(frame / wf, 0.0, 1.0)
		x = x * x * (3.0 - 2.0 * x)
		actors["receiver"].transform = _warp_from.interpolate_with(aligned, x)
	_solve()
	if frame >= n:
		stop()


## Ends the pair: each actor plays its exit clip from the variant's exit spec (cross-faded).
func stop() -> void:
	if not running:
		return
	running = false
	for role in actors:
		var m: Node3D = actors[role]
		var ex: Dictionary = variant.get("exit", {}).get(role, {})
		m.anim.callback_mode_process = _saved_mode.get(role, AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE)
		m.blend_time = exit_blend
		var clip: String = ex.get("state", "idle")
		m.play(clip if m.anim.has_animation(clip) else "rest")
		if _mods.has(role):
			_mods[role].queue_free()
	_mods.clear()
	finished.emit()


# --- the solve -------------------------------------------------------------------------------------
func _t(f: float) -> float:
	return f / fps


## Contact weight at frame f: 1 over frames [a, b], smoothstep ramps of blend[0] / blend[1] frames.
static func contact_weight(c: Dictionary, f: float) -> float:
	var a := float(c["frames"][0])
	var b := float(c["frames"][1])
	var bi := float(c["blend"][0])
	var bo := float(c["blend"][1])
	if f < a - bi or f > b + bo:
		return 0.0
	var x := 1.0
	if f < a:
		x = (f - (a - bi)) / maxf(bi, 1e-9)
	elif f > b:
		x = 1.0 - (f - b) / maxf(bo, 1e-9)
	else:
		return 1.0
	return x * x * (3.0 - 2.0 * x)


static func _bone_order(sk: Skeleton3D) -> PackedInt32Array:
	var depth := {}
	var out := []
	for i in sk.get_bone_count():
		var d := 0
		var p := sk.get_bone_parent(i)
		while p >= 0:
			d += 1
			p = sk.get_bone_parent(p)
		out.append([d, i])
	out.sort()
	var o := PackedInt32Array()
	for x in out:
		o.append(x[1])
	return o


## World transforms of every bone as animated now (no modifiers).
func _globals(role: String) -> Array:
	var m: Node3D = actors[role]
	var sk: Skeleton3D = m.skeleton
	var g := []
	g.resize(sk.get_bone_count())
	var base := sk.global_transform
	for i in sk.get_bone_count():
		g[i] = base * sk.get_bone_global_pose(i)
	return g


func _point(role: String, g: Array, spec: Dictionary) -> Vector3:
	var sk: Skeleton3D = actors[role].skeleton
	var b := sk.find_bone(spec["bone"])
	var fb := sk.find_bone(spec.get("frame_bone", spec["bone"]))
	var o: Array = spec["offset"]
	return (g[b] as Transform3D).origin + (g[fb] as Transform3D).basis.orthonormalized() * (Vector3(o[0], o[1], o[2]) * scale[role])


## Rotates bone b's world basis by r (about its own origin), keeps its new parent-relative transform
## and carries its descendants along. touched collects the rotated bones (their local rotations are
## what the modifier writes).
func _rotate(role: String, g: Array, rel: Array, b: int, r: Basis, touched: Dictionary) -> void:
	var sk: Skeleton3D = actors[role].skeleton
	var t: Transform3D = g[b]
	g[b] = Transform3D(r * t.basis, t.origin)
	var p := sk.get_bone_parent(b)
	rel[b] = g[b] if p < 0 else (g[p] as Transform3D).affine_inverse() * (g[b] as Transform3D)
	touched[b] = true
	var moved := {b: true}
	for i in _orders[role]:
		var q := sk.get_bone_parent(i)
		if q >= 0 and moved.has(q):
			g[i] = (g[q] as Transform3D) * (rel[i] as Transform3D)
			moved[i] = true


func _rel(role: String, g: Array) -> Array:
	var sk: Skeleton3D = actors[role].skeleton
	var rel := []
	rel.resize(g.size())
	for i in g.size():
		var p := sk.get_bone_parent(i)
		rel[i] = g[i] if p < 0 else (g[p] as Transform3D).affine_inverse() * (g[i] as Transform3D)
	return rel


func _solve() -> void:
	var f := frame
	var g := {}
	var rel := {}
	var touched := {}
	for role in actors:
		g[role] = _globals(role)
		rel[role] = _rel(role, g[role])
		touched[role] = {}
	last_lean = {}
	# lean first (per role, from that role's lean contacts with weight)
	for role in actors:
		var lc := []
		for c in variant["contacts"]:
			if c.has("lean") and c["ik"]["role"] == role and contact_weight(c, f) > 0.0:
				lc.append(c)
		if lc.is_empty():
			continue
		var total := 0.0
		var max_deg := float(lc[0]["lean"].get("max_deg", 40.0))
		var w := 0.0
		for c in lc:
			w = maxf(w, contact_weight(c, f))
		for _it in 3:
			var deg := _lean(role, g, rel, touched, lc, f, max_deg - total, w)
			total += deg
			if deg < 0.5:
				break
		last_lean[role] = total
	# contacts in order
	for c in variant["contacts"]:
		var w := contact_weight(c, f)
		if w <= 0.0:
			continue
		var role: String = c["ik"]["role"]
		var to_role: String = c["to"]["role"]
		var target := _point(to_role, g[to_role], c["to"])
		_two_bone(role, g[role], rel[role], touched[role], c, target, w)
	# measure, hand the rotations to the modifiers
	last_contacts = {}
	for c in variant["contacts"]:
		var w := contact_weight(c, f)
		var a := _point(c["from"]["role"], g[c["from"]["role"]], c["from"])
		var b := _point(c["to"]["role"], g[c["to"]["role"]], c["to"])
		last_contacts[c["name"]] = [w, a.distance_to(b)]
	for role in actors:
		var sk: Skeleton3D = actors[role].skeleton
		var rots := {}
		for b in touched[role]:
			var p := sk.get_bone_parent(b)
			var gb: Transform3D = g[role][b]
			var local := gb.basis if p < 0 else (g[role][p] as Transform3D).basis.inverse() * gb.basis
			if p < 0:
				local = sk.global_transform.basis.inverse() * gb.basis
			rots[b] = local.orthonormalized().get_rotation_quaternion()
		if _mods.has(role):
			_mods[role].rotations = rots


## Analytic two-bone IK on world transforms (monster-forge tools/paired.py two_bone_ik).
func _two_bone(role: String, g: Array, rel: Array, dirty: Dictionary, c: Dictionary, target: Vector3, w: float) -> void:
	var sk: Skeleton3D = actors[role].skeleton
	var ch: Array = c["ik"]["chain"]
	var ak := sk.find_bone(ch[0])
	var bk := sk.find_bone(ch[1])
	var ck := sk.find_bone(ch[2])
	var o: Array = c["from"]["offset"]
	var tip_local: Vector3 = Vector3(o[0], o[1], o[2]) * float(scale[role])
	for _it in 3:
		var a: Vector3 = g[ak].origin
		var b: Vector3 = g[bk].origin
		var cc: Vector3 = g[ck].origin
		var tip: Vector3 = (g[ck] as Transform3D).basis.orthonormalized() * tip_local + cc
		var t := target - (tip - cc)
		var lab := a.distance_to(b)
		var lcb := b.distance_to(cc)
		var lat := clampf(a.distance_to(t), 1e-4, (lab + lcb) * 0.999)
		var ac_ab0 := acos(clampf((cc - a).normalized().dot((b - a).normalized()), -1, 1))
		var ba_bc0 := acos(clampf((a - b).normalized().dot((cc - b).normalized()), -1, 1))
		var ac_ab1 := acos(clampf((lcb * lcb - lab * lab - lat * lat) / (-2.0 * lab * lat), -1, 1))
		var ba_bc1 := acos(clampf((lat * lat - lab * lab - lcb * lcb) / (-2.0 * lab * lcb), -1, 1))
		var axis := (cc - a).cross(b - a)
		if axis.length() < 1e-6:
			axis = (t - a).cross(Vector3.UP)
		axis = axis.normalized()
		var r0 := Basis(axis, ac_ab1 - ac_ab0)
		var r1 := Basis(axis, ba_bc1 - ba_bc0)
		var c1 := a + r0 * (b - a) + r0 * r1 * (cc - b)
		var r2 := _rot_between(c1 - a, t - a)
		var ra := r2 * r0
		var rb := r2 * r0 * r1
		if w < 1.0:
			ra = Basis(Quaternion().slerp(ra.get_rotation_quaternion(), w))
			rb = Basis(Quaternion().slerp(rb.get_rotation_quaternion(), w))
		# ra about a (the root), then the middle bone's world rotation set to rb x its old one
		var old_b: Basis = (g[bk] as Transform3D).basis
		_rotate(role, g, rel, ak, ra, dirty)
		var now_b: Basis = (g[bk] as Transform3D).basis
		_rotate(role, g, rel, bk, (rb * old_b) * now_b.inverse(), dirty)


static func _rot_between(u: Vector3, v: Vector3) -> Basis:
	var a := u.normalized()
	var b := v.normalized()
	var x := a.cross(b)
	var d := clampf(a.dot(b), -1, 1)
	if x.length() < 1e-9:
		if d > 0:
			return Basis()
		var p := a.cross(Vector3.RIGHT) if absf(a.x) < 0.9 else a.cross(Vector3.UP)
		return Basis(p.normalized(), PI)
	return Basis(x.normalized(), atan2(x.length(), d))


## Lean (monster-forge tools/paired.py lean): the smallest forward bend <= max_deg, shared by the lean
## bones, after which every lean contact's chain needs no more of its reach than when authored on
## this frame. Returns degrees applied (x the contacts' weight).
func _lean(role: String, g: Dictionary, rel: Dictionary, touched: Dictionary, lc: Array, f: float, max_deg: float, w: float) -> float:
	var sk: Skeleton3D = actors[role].skeleton
	var gr: Array = g[role]
	var bones: Array = lc[0]["lean"]["bones"]
	var piv: Vector3 = gr[sk.find_bone(bones[0])].origin
	var items := []
	var tmean := Vector3.ZERO
	for c in lc:
		var ch: Array = c["ik"]["chain"]
		var ak := sk.find_bone(ch[0])
		var bk := sk.find_bone(ch[1])
		var ck := sk.find_bone(ch[2])
		var o: Array = c["from"]["offset"]
		var cc: Vector3 = gr[ck].origin
		var tip: Vector3 = (gr[ck] as Transform3D).basis.orthonormalized() * (Vector3(o[0], o[1], o[2]) * scale[role]) + cc
		var t := _point(c["to"]["role"], g[c["to"]["role"]], c["to"]) - (tip - cc)
		var ln: float = gr[ak].origin.distance_to(gr[bk].origin) + gr[bk].origin.distance_to(cc)
		var reach: Array = c["lean"]["reach"]
		items.append([gr[ak].origin, ln, t, maxf(float(reach[clampi(int(round(f)), 0, reach.size() - 1)]), 0.05)])
		tmean += t
	tmean /= lc.size()
	var dirh := tmean - piv
	dirh.y = 0.0
	if dirh.length() < 1e-6 or max_deg <= 0.0:
		return 0.0
	var axis := Vector3.UP.cross(dirh.normalized()).normalized()
	var worst := func(th: float) -> float:
		var r := Basis(axis, th)
		var m := 0.0
		for it in items:
			var a2: Vector3 = piv + r * ((it[0] as Vector3) - piv)
			m = maxf(m, (it[2] as Vector3).distance_to(a2) / float(it[1]) / float(it[3]))
		return m
	var th := 0.0
	var mx := deg_to_rad(max_deg)
	while worst.call(th) > 1.0 and th < mx:
		th = minf(mx, th + deg_to_rad(1.0))
	th *= w
	if th <= 0.0:
		return 0.0
	for bn in bones:
		_rotate(role, gr, rel[role], sk.find_bone(bn), Basis(axis, th / bones.size()), touched[role])
	return rad_to_deg(th)


# --- alignment fit ---------------------------------------------------------------------------------
## The reach ratio of every contact at full weight on frame f with the receiver placed at offset scale
## k: |wrist target - chain root| / (upper + lower length). Poses as animated now (the fit frame).
func _reach(k: float, f: float) -> Dictionary:
	var al: Dictionary = variant["alignment"]
	var off: Array = al["offset"]
	var ini: Node3D = actors["initiator"]
	var place := ini.transform * Transform3D(Basis(Vector3.UP, deg_to_rad(float(al["yaw_deg"]))), Vector3(off[0], off[1], off[2]) * k)
	var keep: Transform3D = actors["receiver"].transform
	actors["receiver"].transform = place
	var g := {"initiator": _globals("initiator"), "receiver": _globals("receiver")}
	actors["receiver"].transform = keep
	var out := {}
	for c in variant["contacts"]:
		if contact_weight(c, f) < 1.0:
			continue
		var role: String = c["ik"]["role"]
		var sk: Skeleton3D = actors[role].skeleton
		var ch: Array = c["ik"]["chain"]
		var gr: Array = g[role]
		var a: Vector3 = gr[sk.find_bone(ch[0])].origin
		var b: Vector3 = gr[sk.find_bone(ch[1])].origin
		var cc: Vector3 = gr[sk.find_bone(ch[2])].origin
		var o: Array = c["from"]["offset"]
		var tip: Vector3 = (gr[sk.find_bone(ch[2])] as Transform3D).basis.orthonormalized() * (Vector3(o[0], o[1], o[2]) * scale[role]) + cc
		var t := _point(c["to"]["role"], g[c["to"]["role"]], c["to"]) - (tip - cc)
		out[c["name"]] = a.distance_to(t) / (a.distance_to(b) + b.distance_to(cc))
	return out


func _fit_offset() -> float:
	var al: Dictionary = variant["alignment"]
	var k0 := 0.0
	for r in al["scale_weights"]:
		k0 += float(al["scale_weights"][r]) * scale[r] / float(variant["authored_scale"][r])
	var fit: Dictionary = al.get("fit", {})
	if fit.is_empty():
		return k0
	var f := float(fit["frame"])
	var want := {}
	for c in variant["contacts"]:
		if c.has("reach"):
			want[c["name"]] = float(c["reach"])
	var g := func(k: float) -> float:
		var r: Dictionary = _reach(k, f)
		var m := -1e9
		for n in r:
			if want.has(n):
				m = maxf(m, r[n] / want[n])
		return m - 1.0
	var lo := float(fit["range"][0]) * k0
	var hi := float(fit["range"][1]) * k0
	var k := 0.0
	if g.call(lo) >= 0.0:
		k = lo
	elif g.call(hi) <= 0.0:
		k = hi
	else:
		for _i in 30:
			var mid := (lo + hi) * 0.5
			if g.call(mid) < 0.0:
				lo = mid
			else:
				hi = mid
		k = (lo + hi) * 0.5
	if fit.has("min_gap"):
		var off: Array = al["offset"]
		var d := Vector3(off[0], off[1], off[2]).length()
		var ms: float = (float(scale["initiator"]) + float(scale["receiver"])) * 0.5
		var need: float = actors["initiator"].get_meta("torso_front") + actors["receiver"].get_meta("torso_front") + float(fit["min_gap"]) * ms
		k = maxf(k, need / d)
	return k


## How far the torso reaches ahead of the root at rest: the furthest LOD0 vertex (towards -Z, the
## facing) whose largest skin weight is on spine_01/02/03 (sidecar alignment.fit.depth).
static func _torso_front(m: Node3D) -> float:
	var mi: MeshInstance3D = m.lods[0]
	var skin: Skin = mi.skin
	var sk: Skeleton3D = m.skeleton
	var torso := {}
	for i in skin.get_bind_count():
		var bn := skin.get_bind_name(i)
		var bone := sk.find_bone(bn) if bn != "" else skin.get_bind_bone(i)
		if sk.get_bone_name(bone) in TORSO:
			torso[i] = true
	var best := 0.0
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var bones = arr[Mesh.ARRAY_BONES]
		var wts = arr[Mesh.ARRAY_WEIGHTS]
		if bones == null or wts == null or v.is_empty():
			continue
		var per := int(bones.size() / v.size())
		for i in v.size():
			var bw := -1.0
			var bb := -1
			for k in per:
				if float(wts[i * per + k]) > bw:
					bw = wts[i * per + k]
					bb = bones[i * per + k]
			if torso.has(bb):
				best = maxf(best, -v[i].z)
	return best
