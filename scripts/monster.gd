## A monster synced from monster-forge (tools/sync_monsters.py), loaded at runtime.
##
##   const Monster = preload("res://scripts/monster.gd")
##   var m: Node3D = Monster.load_monster("wolf")   # null if missing; see Monster.last_error
##   add_child(m); m.play("walk"); m.set_lod(-1)     # -1 = auto (visibility ranges)
##   m.attach_prop(Monster.make_sword(), "hand_r")
##
## Tree built here (one skeleton, every LOD skinned to it, one AnimationPlayer):
##   Monster (this script)
##     model                 GLTFDocument scene of model_rigged.glb
##       Armature/Skeleton3D
##         lod0..lod3        MeshInstance3D, same Skin, LOD0's material
##         socket_hand_r     BoneAttachment3D (created by attach_prop)
##     AnimationPlayer       library "" = every anims/<clip>.glb, tracks retargeted;
##                           UAL bipeds also "ual" = the shared UAL library (one copy for
##                           all of them), its clips aliased in "" under the monster's names
##       ual_lift            SkeletonModifier3D: the monster's floor lift on shared clips
##
## Contract (docs/monsters.md): metres, origin at the feet, +Y up, the creature faces -Z
## (so Node3D.look_at() works with use_model_front = false), creature's right is +X.
extends Node3D

const ROOT := "res://assets/monsters"
const UalLift = preload("res://scripts/ual_lift.gd")
const PROP_ROOT := "res://assets/props"
## Clip names that loop. Everything else plays once and stops on its last frame (the GLBs
## carry no loop flag; this list decides).
const LOOPING := ["idle", "walk", "run", "move", "fly", "swim", "hover"]
## One-shots that never hand over to settle_clip: the pose holds.
const HOLD_LAST := ["death"]
## The clip that moves the monster, first match wins: legless and flying plans have no
## walk (ghost and eagle fly, octopus, shark and merfolk swim). move_clip() picks it.
const MOVE_CLIPS := ["walk", "run", "move", "swim", "fly", "hover"]
## Screen-coverage switch points (fraction of viewport height), same as monster-forge's viewer.
const LOD_COVERAGE := [0.6, 0.3, 0.12]

static var last_error := ""
## Shared UAL clip libraries (monster.json ual_shared, docs/monsters.md "Shared UAL clips"),
## loaded once: "<library dir>|<skeleton path>" -> AnimationLibrary.
static var _ual_libraries := {}
## Tests only: load the clips a monster takes from the shared library from
## <ual_legacy_root>/<id>/anims_ual/<clip>.glb instead (monster-forge's per-monster bakes),
## so tools/check_ual_shared.gd can compare the two.
static var ual_legacy_root := ""
## Apply the prop manifest's grip_offset on grip_* sockets (the viewer does). Off: attach
## props as is. A switch so the lab can compare (key G); see docs/monsters.md for why.
static var apply_grip_offset := true

var id := ""
var info: Dictionary = {}           ## monster.json
var skeleton: Skeleton3D
var lods: Array[MeshInstance3D] = []
var anim: AnimationPlayer
var lod_ranges: Array[float] = []   ## camera distance where LOD k+1 takes over
var lod_mode := -1                  ## -1 auto, else the pinned LOD
var report: Dictionary = {}         ## load diagnostics, see check_monsters.gd
var radius := 1.0                   ## bounding-sphere radius of LOD0 (rest pose)
var aabb := AABB()                  ## LOD0 rest-pose AABB in this node's space
var props: Dictionary = {}          ## socket -> BoneAttachment3D
## When a one-shot clip (hit, attack_*, breath) ends, play this one (e.g. "idle"); "" holds
## the last frame. Clips in HOLD_LAST (death) always hold.
var settle_clip := ""
## Cross-fade in seconds for play() and the settle hand-over. 0 (the default) switches on
## the next frame. Clip switches otherwise jump: idle -> swim lifts the octopus 0.21 m and
## the merfolk 0.65 m in one frame (their idle is on the ground, swim hovers), and every
## move clip starts mid-stride. The lab uses 0.25.
var blend_time := 0.0
## The clip play() last started ("" after play("rest")). A one-shot that ended (death) is no
## longer is_playing() but still holds this clip's last frame.
var current_clip := ""
## Bow strings (the `string` node of bow props) are drawn; set_bowstrings_visible() changes
## it for the props held now, and attach_prop() applies it to new ones.
var show_bowstring := true
## Swarms made as ONE unit (monster.json swarm_unit): the other units spawn_swarm() made,
## children of this one (the leader, which stays at the origin). Each follows the leader's
## clip with its own phase (swarm_phase / swarm_delay), see _process.
var swarm_units: Array[Node3D] = []
## Fraction of a looping clip this unit runs ahead of the leader (0 for the leader).
var swarm_phase := 0.0
## Seconds this unit starts a one-shot (attack, hit, death) after the leader.
var swarm_delay := 0.0
## Height above the leader this unit flies / swims at (0 for ground units). Units fall to the
## floor over a HOLD_LAST clip (death): the clip only drops the unit to its own y = 0.
var swarm_height := 0.0
## monster.json ual_shared ({} for monsters with only their own clips): hip_scale (the
## skeleton's motion_scale), pelvis_offset (moved into the root bone's rest), lift curves.
var ual_shared: Dictionary = {}
var _lift_curves := {}      ## clip -> PackedFloat32Array, metres along the lift axis per frame
var _lift_fps := 30.0
var _lift_prev := ""        ## the clip play() faded out, its position then, and the fade time
var _lift_prev_pos := 0.0
var _lift_blend := 0.0


static func list_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	var d := DirAccess.open(ROOT)
	if d == null:
		return ids
	for sub in d.get_directories():
		if FileAccess.file_exists("%s/%s/monster.json" % [ROOT, sub]):
			ids.append(sub)
	ids.sort()
	return ids


static func _gltf_scene(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		last_error = "%s: GLTFDocument error %s" % [path, error_string(err)]
		return null
	return doc.generate_scene(state) as Node3D


## Loads assets/monsters/<id>/. fov_deg sets the auto-LOD distances.
static func load_monster(monster_id: String, fov_deg := 50.0) -> Node3D:
	last_error = ""
	var dir := "%s/%s" % [ROOT, monster_id]
	var info_text := FileAccess.get_file_as_string(dir + "/monster.json")
	var parsed = JSON.parse_string(info_text)
	if not parsed is Dictionary:
		last_error = "%s/monster.json missing or invalid" % dir
		return null
	var model := _gltf_scene("%s/%s" % [dir, parsed["lods"]["0"]["file"]])
	if model == null:
		return null
	var m: Node3D = (load("res://scripts/monster.gd") as GDScript).new()
	m.name = monster_id
	m.id = monster_id
	m.info = parsed
	model.name = "model"
	m.add_child(model)
	if not m._setup(dir, fov_deg):
		m.free()
		return null
	return m


func _setup(dir: String, fov_deg: float) -> bool:
	var skels := find_children("*", "Skeleton3D", true, false)
	if skels.size() != 1:
		last_error = "%s: expected 1 Skeleton3D, found %d" % [id, skels.size()]
		return false
	skeleton = skels[0]
	var meshes := skeleton.find_children("*", "MeshInstance3D", false, false)
	if meshes.size() != 1:
		last_error = "%s: expected 1 skinned mesh under the skeleton, found %d" % [id, meshes.size()]
		return false
	var lod0: MeshInstance3D = meshes[0]
	lod0.name = "lod0"
	lods = [lod0]
	report = {"lod_errors": [], "clips": {}}
	_mipmap_material(lod0.mesh)
	_add_lods(dir, lod0)
	aabb = lod0.mesh.get_aabb()   # skeleton and mesh nodes are identity in these exports
	radius = aabb.size.length() * 0.5
	var t := tan(deg_to_rad(fov_deg) * 0.5)
	lod_ranges.clear()
	for c in LOD_COVERAGE:
		lod_ranges.append(radius / sin(atan(c * t)))
	set_lod(-1)
	anim = AnimationPlayer.new()
	anim.name = "AnimationPlayer"
	anim.deterministic = true   # un-keyed bones fall back to RESET (off by default in 4.7)
	add_child(anim)   # root_node ".." = this node
	var lib := AnimationLibrary.new()
	ual_shared = info.get("ual_shared", {}) if ual_legacy_root == "" else {}
	var shared_clips: Dictionary = ual_shared.get("clips", {})
	var scale := 1.0
	if not shared_clips.is_empty():
		scale = _setup_ual_shared()
		if scale <= 0.0:
			return false
	for clip in info.get("clips", []):
		if shared_clips.has(clip):
			continue
		if ual_legacy_root != "" and info.get("ual_shared", {}).get("clips", {}).has(clip):
			_add_clip(lib, "%s/%s" % [ual_legacy_root, id], clip, 1.0, "anims_ual")
		else:
			_add_clip(lib, dir, clip, scale)
	lib.add_animation("RESET", _reset_animation(scale))
	anim.add_animation_library("", lib)
	if not shared_clips.is_empty():
		var shared := _ual_library(ual_shared.get("library", ""))
		if shared == null:
			return false
		anim.add_animation_library("ual", shared)
		for clip in shared_clips:   # same Animation objects, under the monster's clip names
			var a: Animation = shared.get_animation(shared_clips[clip]) if shared.has_animation(shared_clips[clip]) else null
			if a == null:
				report["clips"][clip] = {"tracks": 0, "bound": 0, "unbound": [], "length": 0.0,
						"error": "shared clip %s not in the library" % shared_clips[clip], "shared": shared_clips[clip]}
				continue
			lib.add_animation(clip, a)
			report["clips"][clip] = {"tracks": a.get_track_count(), "bound": a.get_track_count(), "unbound": [],
					"length": a.length, "error": "", "shared": shared_clips[clip]}
	anim.animation_finished.connect(_on_clip_finished)
	return true


func _on_clip_finished(clip: StringName) -> void:
	if settle_clip != "" and String(clip) not in HOLD_LAST and anim.has_animation(settle_clip):
		_lift_switch(blend_time)
		current_clip = settle_clip
		anim.play(settle_clip, blend_time)


## Every bone keyed at its rest pose. Godot drops glTF channels that never leave the rest
## pose, so clips key different bone sets. With AnimationMixer.deterministic (false by
## default on AnimationPlayer in 4.7) un-keyed tracks take the RESET animation's values;
## without both, switching walk -> idle leaves the bones idle does not key in walk's pose
## (measured: 16 of 28 wolf bones stuck, up to 58 deg). The editor's scene importer adds
## RESET itself; runtime GLTFDocument loading does not.
func _reset_animation(scale := 1.0) -> Animation:
	var a := Animation.new()
	a.length = 0.001
	var sp := String(get_path_to(skeleton))
	for b in skeleton.get_bone_count():
		var rest := skeleton.get_bone_rest(b)
		var path := NodePath("%s:%s" % [sp, skeleton.get_bone_name(b)])
		var t := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(t, path)
		a.position_track_insert_key(t, 0.0, rest.origin / scale)   # motion_scale multiplies it back
		t = a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, path)
		a.rotation_track_insert_key(t, 0.0, rest.basis.get_rotation_quaternion())
		t = a.add_track(Animation.TYPE_SCALE_3D)
		a.track_set_path(t, path)
		a.scale_track_insert_key(t, 0.0, rest.basis.get_scale())
	return a


## Runtime GLTFDocument textures have no mipmaps (the editor importer would add them);
## without them the albedo shimmers at distance.
static func _mipmap_material(mesh: Mesh) -> void:
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s) as BaseMaterial3D
		if mat == null:
			continue
		for p in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
				"emission_texture", "ao_texture"]:
			var tex := mat.get(p) as Texture2D
			if tex == null:
				continue
			var img := tex.get_image()
			if img and not img.has_mipmaps():
				img.generate_mipmaps()
				mat.set(p, ImageTexture.create_from_image(img))


## LOD k>0: take the mesh out of model_rigged_lod<k>.glb, skin it to LOD0's skeleton with
## LOD0's Skin (same joint order, checked) and give it LOD0's material (the LOD files carry
## no images).
func _add_lods(dir: String, lod0: MeshInstance3D) -> void:
	var keys: Array = info["lods"].keys()
	keys.sort_custom(func(a, b): return int(a) < int(b))
	for k in keys:
		if int(k) == 0:
			continue
		var path := "%s/%s" % [dir, info["lods"][k]["file"]]
		var sc := _gltf_scene(path)
		if sc == null:
			report["lod_errors"].append(last_error)
			continue
		var src_skel := sc.find_children("*", "Skeleton3D", true, false)
		var src_mi := sc.find_children("*", "MeshInstance3D", true, false)
		var err := _check_same_skeleton(src_skel[0] if src_skel.size() == 1 else null,
				src_mi[0].skin if src_mi.size() == 1 else null, lod0.skin)
		if err != "":
			report["lod_errors"].append("LOD%s: %s" % [k, err])
			sc.free()
			continue
		var mi := MeshInstance3D.new()
		mi.name = "lod%s" % k
		mi.mesh = src_mi[0].mesh
		mi.skin = lod0.skin
		skeleton.add_child(mi)
		mi.skeleton = NodePath("..")
		for s in mi.mesh.get_surface_count():
			mi.set_surface_override_material(s, lod0.mesh.surface_get_material(mini(s, lod0.mesh.get_surface_count() - 1)))
		lods.append(mi)
		sc.free()


func _check_same_skeleton(sk: Skeleton3D, skin: Skin, ref_skin: Skin) -> String:
	if sk == null or skin == null:
		return "no single skeleton/skinned mesh"
	if sk.get_bone_count() != skeleton.get_bone_count():
		return "bone count %d != %d" % [sk.get_bone_count(), skeleton.get_bone_count()]
	for b in sk.get_bone_count():
		if sk.get_bone_name(b) != skeleton.get_bone_name(b):
			return "bone %d is %s, LOD0 has %s" % [b, sk.get_bone_name(b), skeleton.get_bone_name(b)]
	if skin.get_bind_count() != ref_skin.get_bind_count():
		return "skin binds %d != %d" % [skin.get_bind_count(), ref_skin.get_bind_count()]
	for i in skin.get_bind_count():
		if skin.get_bind_bone(i) != ref_skin.get_bind_bone(i) or skin.get_bind_name(i) != ref_skin.get_bind_name(i):
			return "skin bind %d targets another bone" % i
		if not skin.get_bind_pose(i).is_equal_approx(ref_skin.get_bind_pose(i)):
			var d := skin.get_bind_pose(i).origin.distance_to(ref_skin.get_bind_pose(i).origin)
			if d > 1e-3:
				return "skin bind pose %d differs by %.4f m" % [i, d]
	return ""


## Loads anims/<clip>.glb (armature only) and rebinds its tracks onto our skeleton by bone
## name. Tracks whose bone is missing are dropped and counted. scale: the skeleton's
## motion_scale (UAL bipeds with shared clips), divided out of the clip's position keys; the
## root bone (its rest carries the pelvis offset then) is keyed at its own rest.
func _add_clip(lib: AnimationLibrary, dir: String, clip: String, scale := 1.0, sub := "anims") -> void:
	var rep := {"tracks": 0, "bound": 0, "unbound": [], "length": 0.0, "error": ""}
	report["clips"][clip] = rep
	var sc := _gltf_scene("%s/%s/%s.glb" % [dir, sub, clip])
	if sc == null:
		rep["error"] = last_error
		return
	var players := sc.find_children("*", "AnimationPlayer", true, false)
	if players.is_empty() or (players[0] as AnimationPlayer).get_animation_list().is_empty():
		rep["error"] = "no animation in file"
		sc.free()
		return
	var ap: AnimationPlayer = players[0]
	var names := ap.get_animation_list()
	var skel_path := String(get_path_to(skeleton))
	for n in names:
		var src: Animation = ap.get_animation(n)
		var a: Animation = src.duplicate(true)
		for t in range(a.get_track_count() - 1, -1, -1):
			rep["tracks"] += 1
			var p := a.track_get_path(t)
			var bone := String(p.get_concatenated_subnames())
			if bone == "":   # node track, e.g. the Armature object: name the node instead
				bone = String(p.get_name(p.get_name_count() - 1))
			if skeleton.find_bone(bone) >= 0:
				a.track_set_path(t, NodePath("%s:%s" % [skel_path, bone]))
				rep["bound"] += 1
			else:
				rep["unbound"].append(String(p))
				a.remove_track(t)
		if not ual_shared.is_empty():
			_unscale_positions(a, skel_path, scale)
		var key: String = clip if names.size() == 1 else "%s:%s" % [clip, n]
		a.loop_mode = Animation.LOOP_LINEAR if clip in LOOPING else Animation.LOOP_NONE
		rep["length"] = a.length
		lib.add_animation(key, a)
	sc.free()


## A monster's own clip next to shared ones: the skeleton's motion_scale multiplies every
## position key, so divide them by it, and key the root and pelvis bones at their original
## rests when the clip has no track for them (Godot drops channels that stay at the rest; the
## rests now carry the pelvis offset that shared clips need and this baked clip already has).
func _unscale_positions(a: Animation, skel_path: String, scale: float) -> void:
	var need := _orig_rest.duplicate()
	for t in a.get_track_count():
		if a.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		need.erase(String(a.track_get_path(t).get_concatenated_subnames()))
		for k in a.track_get_key_count(t):
			a.track_set_key_value(t, k, (a.track_get_key_value(t, k) as Vector3) / scale)
	for bone in need:
		var t := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(t, NodePath("%s:%s" % [skel_path, bone]))
		a.position_track_insert_key(t, 0.0, need[bone] / scale)


var _orig_rest := {}   ## root and pelvis rest origins before _setup_ual_shared moved them


## Shared UAL clips key the UAL bones' local rotations (the same on every UAL biped) and the
## pelvis translation u in UAL's units; this monster's pelvis is hip_scale * u + pelvis_offset
## (+ its floor lift). motion_scale = hip_scale does the first; the offset goes into the root
## bone's rest (no shared clip keys the root; the pelvis rest moves back, so the rest pose is
## unchanged); the lift is a SkeletonModifier3D (scripts/ual_lift.gd). Returns hip_scale, or
## 0 on bad data.
func _setup_ual_shared() -> float:
	var s := float(ual_shared.get("hip_scale", 0.0))
	var off: Array = ual_shared.get("pelvis_offset", [])
	var rb := skeleton.find_bone(ual_shared.get("root_bone", "root"))
	var pb := skeleton.find_bone(ual_shared.get("pelvis_bone", "pelvis"))
	if s <= 0.0 or off.size() != 3 or rb < 0 or pb < 0 or skeleton.get_bone_parent(pb) != rb:
		last_error = "%s: ual_shared needs hip_scale > 0, a 3-vector pelvis_offset and a pelvis bone under the root bone" % id
		return 0.0
	var c := Vector3(off[0], off[1], off[2])
	var rr := skeleton.get_bone_rest(rb)
	var pr := skeleton.get_bone_rest(pb)
	_orig_rest = {skeleton.get_bone_name(rb): rr.origin, skeleton.get_bone_name(pb): pr.origin}
	skeleton.set_bone_rest(rb, Transform3D(rr.basis, rr.origin + rr.basis * c))
	skeleton.set_bone_rest(pb, Transform3D(pr.basis, pr.origin - c))
	skeleton.reset_bone_poses()
	skeleton.motion_scale = s
	var lift: Dictionary = ual_shared.get("lift", {})
	if not lift.is_empty():
		_lift_fps = float(ual_shared.get("fps", 30.0))
		for clip in lift:
			_lift_curves[clip] = PackedFloat32Array(lift[clip])
		var ax: Array = ual_shared.get("lift_axis", [0.0, 0.0, 1.0])
		var mod := UalLift.new()
		mod.name = "ual_lift"
		mod.monster = self
		mod.bone = rb
		mod.axis = (rr.basis * Vector3(ax[0], ax[1], ax[2])).normalized()   # root-local -> skeleton space
		skeleton.add_child(mod)
	return s


## The shared library at assets/monsters/<rel> (library.json + one GLB per clip), loaded once
## per skeleton path. Its tracks are rebound to this monster's skeleton path; Godot drops
## glTF channels that never leave the rest pose, and the library's rest is UAL's, not this
## monster's, so a dropped rotation channel is put back as a constant track at UAL's rest.
func _ual_library(rel: String) -> AnimationLibrary:
	var sp := String(get_path_to(skeleton))
	var key := "%s|%s" % [rel, sp]
	if _ual_libraries.has(key):
		return _ual_libraries[key]
	var dir := "%s/%s" % [ROOT, rel]
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(dir + "/library.json"))
	if not parsed is Dictionary:
		last_error = "%s/library.json missing or invalid" % dir
		return null
	var pelvis: String = parsed.get("pelvis_bone", "pelvis")
	var root_bone: String = parsed.get("root_bone", "root")
	var lib := AnimationLibrary.new()
	for name in parsed.get("clips", {}):
		var e: Dictionary = parsed["clips"][name]
		var sc := _gltf_scene("%s/%s" % [dir, e["file"]])
		if sc == null:
			push_warning(last_error)
			continue
		var players := sc.find_children("*", "AnimationPlayer", true, false)
		var sks := sc.find_children("*", "Skeleton3D", true, false)
		if players.is_empty() or sks.size() != 1 or (players[0] as AnimationPlayer).get_animation_list().is_empty():
			push_warning("%s: no animation or skeleton" % e["file"])
			sc.free()
			continue
		var src_sk: Skeleton3D = sks[0]
		var ap: AnimationPlayer = players[0]
		var a: Animation = ap.get_animation(ap.get_animation_list()[0]).duplicate(true)
		var have := {}
		for t in range(a.get_track_count() - 1, -1, -1):
			var p := a.track_get_path(t)
			var bone := String(p.get_concatenated_subnames())
			var ty := a.track_get_type(t)
			# rotations of every bone but the root, the pelvis position; nothing else
			if bone == "" or bone == root_bone or not (ty == Animation.TYPE_ROTATION_3D or (ty == Animation.TYPE_POSITION_3D and bone == pelvis)):
				a.remove_track(t)
				continue
			a.track_set_path(t, NodePath("%s:%s" % [sp, bone]))
			have["%s/%d" % [bone, ty]] = true
		for b in src_sk.get_bone_count():
			var bn := src_sk.get_bone_name(b)
			if bn == root_bone:
				continue
			if not have.has("%s/%d" % [bn, Animation.TYPE_ROTATION_3D]):
				var t := a.add_track(Animation.TYPE_ROTATION_3D)
				a.track_set_path(t, NodePath("%s:%s" % [sp, bn]))
				a.rotation_track_insert_key(t, 0.0, src_sk.get_bone_rest(b).basis.get_rotation_quaternion())
			if bn == pelvis and not have.has("%s/%d" % [bn, Animation.TYPE_POSITION_3D]):
				var t := a.add_track(Animation.TYPE_POSITION_3D)
				a.track_set_path(t, NodePath("%s:%s" % [sp, bn]))
				a.position_track_insert_key(t, 0.0, src_sk.get_bone_rest(b).origin)
		a.loop_mode = Animation.LOOP_LINEAR if e.get("loop", false) else Animation.LOOP_NONE
		lib.add_animation(name, a)
		sc.free()
	_ual_libraries[key] = lib
	return lib


## The floor lift (metres along the lift axis) for the pose shown now: the current clip's
## curve, cross-faded from the previous clip's over the play() blend. 0 for own clips.
func ual_lift_now() -> float:
	if current_clip == "" or _lift_curves.is_empty() or anim.assigned_animation != current_clip:
		return 0.0
	var t := anim.current_animation_position
	var h := _lift_at(current_clip, t)
	if _lift_blend > 0.0 and t < _lift_blend:
		h = lerpf(_lift_at(_lift_prev, _lift_prev_pos + t), h, t / _lift_blend)
	return h


func _lift_at(clip: String, t: float) -> float:
	var c: PackedFloat32Array = _lift_curves.get(clip, PackedFloat32Array())
	if c.is_empty() or not anim.has_animation(clip):
		return 0.0
	var a := anim.get_animation(clip)
	t = fposmod(t, a.length) if a.loop_mode != Animation.LOOP_NONE else clampf(t, 0.0, a.length)
	var f := t * _lift_fps
	var i := clampi(int(f), 0, c.size() - 1)
	return lerpf(c[i], c[mini(i + 1, c.size() - 1)], f - floorf(f))


## Remembers what play() fades out of, for the lift cross-fade.
func _lift_switch(blend: float) -> void:
	if _lift_curves.is_empty():
		return
	_lift_prev = current_clip
	_lift_prev_pos = anim.current_animation_position if current_clip != "" and anim.assigned_animation == current_clip else 0.0
	_lift_blend = blend if _lift_prev != "" else 0.0


func clips() -> PackedStringArray:
	var out := PackedStringArray()
	if anim:
		for n in anim.get_animation_list():
			if n != "RESET" and not n.begins_with("_") and not n.begins_with("ual/"):
				out.append(n)
	return out


## The locomotion clip: walk, else the first of MOVE_CLIPS this monster has ("" if none).
func move_clip() -> String:
	var have := clips()
	for c in MOVE_CLIPS:
		if c in have:
			return c
	return ""


## Plays a clip from the start; "" or "rest" stops and shows the bind pose. A swarm leader
## starts its units too (they keep their phase, see _process).
func play(clip: String) -> void:
	for u in swarm_units:
		u.blend_time = blend_time
		u.play(clip)
	if clip == "" or clip == "rest" or not anim.has_animation(clip):
		anim.stop()
		skeleton.reset_bone_poses()
		current_clip = ""
		return
	_lift_switch(blend_time)
	current_clip = clip
	anim.play(clip, blend_time)


## monster.json swarm_unit ({unit, plan, rig_template, size, scale_m, swarm: {body_plan, size,
## scale_m}}) or {} when this monster is not a swarm made as one unit.
func swarm_info() -> Dictionary:
	var su = info.get("swarm_unit")
	return su if su is Dictionary else {}


## A swarm made as one unit is shown as count units (this one included) scattered over the
## swarm's footprint, a disc of diameter swarm.scale_m. Units that fly or swim (avian /
## aquatic plan, or a fly / swim / hover move clip) also spread over a height band of
## 0.5 x swarm.scale_m above the leader. Deterministic (seeded by the id), each unit turned up
## to +-35 deg off the leader's -Z facing, with a staggered phase on looping clips (golden
## ratio steps, so no two units are in step) and a 0-0.35 s delay on one-shots. Returns the
## units added (count - 1); none when this is not a swarm unit. Clears earlier units.
func spawn_swarm(count := 12, fov_deg := 50.0) -> Array[Node3D]:
	for u in swarm_units:
		u.queue_free()
	swarm_units.clear()
	var su := swarm_info()
	if su.is_empty() or count < 2:
		set_process(false)
		return swarm_units
	var sw: Dictionary = su.get("swarm", {})
	var r: float = float(sw.get("scale_m", 1.5)) * 0.5
	var unit_r: float = float(su.get("scale_m", info.get("scale_m", 0.3))) * 0.5
	var volume: bool = str(su.get("plan", "")) in ["avian", "aquatic"] or move_clip() in ["fly", "swim", "hover"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(id)
	for k in range(1, count):
		var u: Node3D = (load("res://scripts/monster.gd") as GDScript).load_monster(id, fov_deg)
		if u == null:
			break
		# Sunflower spiral over the disc (even cover), jittered by a third of a unit.
		var rad := (r - unit_r) * sqrt(float(k) / float(count - 1))
		var ang := k * 2.39996323 + rng.randf_range(-0.3, 0.3)
		var pos := Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
		pos += Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)) * unit_r * 0.66
		if volume:
			pos.y = rng.randf_range(0.0, r)
			u.swarm_height = pos.y
		u.position = pos
		u.rotation.y = rng.randf_range(-0.6, 0.6)
		u.swarm_phase = fposmod(k * 0.618034, 1.0)
		u.swarm_delay = rng.randf_range(0.0, 0.35)
		u.name = "unit_%d" % k
		u.show_bowstring = show_bowstring
		add_child(u)
		u.set_lod(lod_mode)
		swarm_units.append(u)
	set_process(not swarm_units.is_empty())
	play(current_clip)
	return swarm_units


## The leader's AABB merged with every swarm unit's (this node's space); aabb alone otherwise.
func swarm_aabb() -> AABB:
	var b := aabb
	for u in swarm_units:
		b = b.merge(u.transform * u.aabb)
	return b


## Swarm leader only: every unit shows the leader's clip at the leader's time plus its phase
## (loops) or minus its delay (one-shots), so seeking or pausing the leader moves the swarm.
func _process(_delta: float) -> void:
	if swarm_units.is_empty() or anim == null:
		return
	var clip := current_clip
	var playing := clip != "" and anim.assigned_animation == clip
	for u in swarm_units:
		u.anim.speed_scale = anim.speed_scale
		if u.current_clip != clip:
			u.blend_time = blend_time
			u.play(clip)
		if not playing or not u.anim.has_animation(clip):
			u.position.y = u.swarm_height
			continue
		var a: Animation = u.anim.get_animation(clip)
		var t := anim.current_animation_position
		if a.loop_mode != Animation.LOOP_NONE:
			t = fposmod(t + u.swarm_phase * a.length, a.length)
		elif not anim.is_playing():   # the leader's one-shot ended (death holds): so do the units
			t = a.length
		else:
			t = clampf(t - u.swarm_delay, 0.0, a.length)
		u.anim.seek(t, true)
		# A dying flyer drops from its height to the floor (falling: height x (1 - f^2)).
		var f := t / a.length if clip in HOLD_LAST and a.length > 0.0 else 0.0
		u.position.y = u.swarm_height * (1.0 - f * f)


## -1: auto (GeometryInstance3D visibility ranges, by camera distance). k: pin LOD k.
func set_lod(k: int) -> void:
	lod_mode = k
	for u in swarm_units:
		u.set_lod(k)
	for i in lods.size():
		var mi := lods[i]
		if k < 0:
			mi.visible = true
			mi.visibility_range_begin = 0.0 if i == 0 else lod_ranges[mini(i - 1, lod_ranges.size() - 1)]
			mi.visibility_range_end = 0.0 if i == lods.size() - 1 else lod_ranges[mini(i, lod_ranges.size() - 1)]
		else:
			mi.visibility_range_begin = 0.0
			mi.visibility_range_end = 0.0
			mi.visible = i == k


## The LOD auto mode draws at this camera position (for readouts; the renderer decides).
## Godot measures visibility ranges from the camera to the instance's AABB centre.
func auto_lod_at(cam_pos: Vector3) -> int:
	var d := cam_pos.distance_to(global_transform * aabb.get_center())
	for i in lod_ranges.size():
		if d < lod_ranges[i]:
			return i
	return lods.size() - 1


func has_socket(socket: String) -> bool:
	return skeleton.find_bone(socket) >= 0


## Where a held prop goes for side "r" or "l": grip_<side> (non-deforming bone at the centre
## of the fist, already in prop space) when the rig has it, else hand_<side>, else "".
func grip_socket(side: String) -> String:
	for s in ["grip_" + side, "hand_" + side]:
		if has_socket(s):
			return s
	return ""


## Prop scale: props are built for a 1.8 m wielder. Centauroids and merfolk/naga are measured
## over the whole body, so monster.json rider_height_m (the humanoid part as a standing
## wielder; centaur-trooper 1.8) wins over scale_m when set (docs/equipment.md "Prop space").
func prop_scale() -> float:
	var h = info.get("rider_height_m")
	if h == null:
		h = info.get("scale_m", 1.8)
	return float(h if h != null else 1.8) / 1.8


## Parents prop under a BoneAttachment3D on the socket bone, scaled by prop_scale().
func attach_prop(prop: Node3D, socket: String) -> bool:
	if not has_socket(socket):
		prop.free()
		return false
	detach_prop(socket)
	var ba := BoneAttachment3D.new()
	ba.name = "socket_" + socket
	ba.bone_name = socket
	skeleton.add_child(ba)
	var s: float = prop_scale()
	prop.scale = Vector3.ONE * s
	# manifest prop.grip_offset (rotation deg XYZ, translation m) applies on grip_* sockets
	# only, as in monster-forge's viewer: bows, crossbows, pistols and shields turn +90 deg
	# about X so the limbs / top rim point up and -Z (arrow, face) forward.
	var body := prop.get_node_or_null("body") as Node3D
	if body and apply_grip_offset and prop.has_meta("grip_offset") and socket.begins_with("grip_"):
		var go: Dictionary = prop.get_meta("grip_offset")
		var r: Array = go.get("rotation_deg_xyz", [0, 0, 0])
		var t: Array = go.get("translation_m", [0, 0, 0])
		body.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(r[0]), deg_to_rad(r[1]), deg_to_rad(r[2])), EULER_ORDER_XYZ), Vector3(t[0], t[1], t[2]))
	if prop.has_meta("lod_meshes"):
		_set_ranges(prop.get_meta("lod_meshes"), float(prop.get_meta("lod_radius")) * s, float(prop.get_meta("fov")))
		if prop.get_meta("string_meshes", []).size() == prop.get_meta("lod_meshes").size():
			_set_ranges(prop.get_meta("string_meshes"), float(prop.get_meta("lod_radius")) * s, float(prop.get_meta("fov")))
	ba.add_child(prop)
	set_bowstring_visible(prop, show_bowstring)
	props[socket] = ba
	return true


func detach_prop(socket: String) -> void:
	if props.has(socket):
		props[socket].queue_free()
		props.erase(socket)


func set_props_visible(v: bool) -> void:
	for ba in props.values():
		ba.visible = v


## Distances at which LOD k+1 takes over, from the viewer's screen-coverage thresholds.
static func _ranges(r: float, fov_deg: float) -> Array[float]:
	var out: Array[float] = []
	var t := tan(deg_to_rad(fov_deg) * 0.5)
	for c in LOD_COVERAGE:
		out.append(r / sin(atan(c * t)))
	return out


static func _set_ranges(meshes: Array, r: float, fov_deg: float) -> void:
	var rg := _ranges(r, fov_deg)
	for i in meshes.size():
		var mi: MeshInstance3D = meshes[i]
		mi.visibility_range_begin = 0.0 if i == 0 else rg[mini(i - 1, rg.size() - 1)]
		mi.visibility_range_end = 0.0 if i == meshes.size() - 1 else rg[mini(i, rg.size() - 1)]


## Real prop from assets/props/<id>/ (tools/sync_monsters.py), already in prop space: origin
## at the grip, +Y to the tip, -Z the edge / arrow / shield face, metres for a 1.8 m wielder.
##   prop (meta: prop_id, manifest, grip_offset, offhand_grip, lod_meshes, string_meshes)
##     body                 grip_offset goes here (attach_prop, grip_* sockets only)
##       model              GLTFDocument scene of model.glb; two-handed props keep their
##                          "offhand_grip" node (the off hand's IK target)
##         <stave/blade>, lod1..3     LOD files share LOD0's material, switched by visibility range
##         string, string_lod1..3     bows only: the straight string, its own node and
##                                    material (manifest.prop.nodes), see set_bowstring_visible
## Returns null (see last_error) when the prop is not synced.
static func load_prop(prop_id: String, fov_deg := 50.0) -> Node3D:
	var dir := "%s/%s" % [PROP_ROOT, prop_id]
	var man = JSON.parse_string(FileAccess.get_file_as_string(dir + "/manifest.json"))
	if not man is Dictionary:
		last_error = "%s/manifest.json missing or invalid" % dir
		return null
	var model := _gltf_scene(dir + "/model.glb")
	if model == null:
		return null
	var pm: Dictionary = man.get("prop", {})
	# Bows carry two mesh nodes: the stave ("prop") and the string ("string"). Every other
	# prop has one mesh.
	var string_name := str(pm.get("nodes", {}).get("string", "")) if pm.get("nodes") is Dictionary else ""
	var parts := _prop_meshes(model, string_name)
	if parts[0] == null:
		last_error = "%s: expected 1 mesh (plus an optional string) in model.glb, found %d" % [prop_id, parts[2]]
		model.free()
		return null
	var lod0: MeshInstance3D = parts[0]
	_mipmap_material(lod0.mesh)
	var lod_meshes: Array = [lod0]
	var string_meshes: Array = [parts[1]] if parts[1] != null else []
	var k := 1
	while FileAccess.file_exists("%s/model_lod%d.glb" % [dir, k]):
		var sc := _gltf_scene("%s/model_lod%d.glb" % [dir, k])
		var src: Array = _prop_meshes(sc, string_name) if sc else [null, null, 0]
		if src[0] != null:
			var mi := MeshInstance3D.new()
			mi.name = "lod%d" % k
			mi.mesh = src[0].mesh
			mi.transform = lod0.transform
			for si in mi.mesh.get_surface_count():
				mi.set_surface_override_material(si, lod0.mesh.surface_get_material(mini(si, lod0.mesh.get_surface_count() - 1)))
			lod0.get_parent().add_child(mi)
			lod_meshes.append(mi)
			if src[1] != null and string_meshes.size():
				var s0: MeshInstance3D = string_meshes[0]
				var smi := MeshInstance3D.new()
				smi.name = "%s_lod%d" % [string_name, k]
				smi.mesh = src[1].mesh
				smi.transform = s0.transform
				smi.set_surface_override_material(0, s0.mesh.surface_get_material(0))
				s0.get_parent().add_child(smi)
				string_meshes.append(smi)
		if sc:
			sc.free()
		k += 1
	var p := Node3D.new()
	p.name = "prop_" + prop_id
	var body := Node3D.new()
	body.name = "body"
	p.add_child(body)
	model.name = "model"
	body.add_child(model)
	p.set_meta("prop_id", prop_id)
	p.set_meta("manifest", man)
	p.set_meta("grip_offset", pm.get("grip_offset", {}))
	p.set_meta("offhand_grip", pm.get("offhand_grip"))
	p.set_meta("lod_meshes", lod_meshes)
	p.set_meta("string_meshes", string_meshes)
	p.set_meta("lod_radius", lod0.mesh.get_aabb().size.length() * 0.5)
	p.set_meta("fov", fov_deg)
	_set_ranges(lod_meshes, lod0.mesh.get_aabb().size.length() * 0.5, fov_deg)
	if string_meshes.size() == lod_meshes.size():
		_set_ranges(string_meshes, lod0.mesh.get_aabb().size.length() * 0.5, fov_deg)
	return p


## [main mesh or null, string mesh or null, mesh count]: the main mesh is the one mesh not
## named string_name; null when there is not exactly one.
static func _prop_meshes(sc: Node, string_name: String) -> Array:
	var main: MeshInstance3D = null
	var str_mi: MeshInstance3D = null
	var n_main := 0
	var all := sc.find_children("*", "MeshInstance3D", true, false)
	for mi in all:
		if string_name != "" and mi.name == string_name:
			str_mi = mi
		else:
			main = mi
			n_main += 1
	return [main if n_main == 1 else null, str_mi, all.size()]


## Shows or hides a bow's string (all LODs). For a game that draws its own string, or pulls
## it back with the arrow. No-op on props without one.
static func set_bowstring_visible(prop: Node3D, on: bool) -> void:
	for mi in prop.get_meta("string_meshes", []):
		(mi as MeshInstance3D).visible = on


## The same for every prop this monster holds.
func set_bowstrings_visible(on: bool) -> void:
	show_bowstring = on
	for ba in props.values():
		for prop in ba.get_children():
			set_bowstring_visible(prop, on)


static func _box(size: Vector3, pos: Vector3, color: Color, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metal
	mat.roughness = 0.4
	mi.material_override = mat
	return mi


## Placeholder one-handed sword in prop space: origin at the grip (centre of the fist), +Y
## along the blade, -Z the cutting edge (painted red). 1.0 m overall, for a 1.8 m wielder.
static func make_sword() -> Node3D:
	var p := Node3D.new()
	p.name = "sword"
	p.add_child(_box(Vector3(0.03, 0.2, 0.03), Vector3(0, 0, 0), Color(0.35, 0.2, 0.1)))            # grip
	p.add_child(_box(Vector3(0.05, 0.05, 0.05), Vector3(0, -0.12, 0), Color(0.6, 0.5, 0.2), 0.8))   # pommel
	p.add_child(_box(Vector3(0.03, 0.03, 0.22), Vector3(0, 0.11, 0), Color(0.6, 0.5, 0.2), 0.8))    # guard, across the edges
	p.add_child(_box(Vector3(0.01, 0.75, 0.05), Vector3(0, 0.125 + 0.375, 0), Color(0.8, 0.8, 0.85), 0.9))  # blade
	p.add_child(_box(Vector3(0.012, 0.75, 0.01), Vector3(0, 0.5, -0.025), Color(0.9, 0.1, 0.1)))    # edge, -Z
	return p


## Placeholder bow: origin at the grip, limbs along +-Y, the arrow (yellow) pointing -Z,
## the string on +Z (toward the archer). 1.0 m tall.
static func make_bow() -> Node3D:
	var p := Node3D.new()
	p.name = "bow"
	var wood := Color(0.45, 0.28, 0.12)
	p.add_child(_box(Vector3(0.035, 0.16, 0.04), Vector3.ZERO, wood))
	for sgn in [1.0, -1.0]:
		var limb := _box(Vector3(0.025, 0.42, 0.025), Vector3(0, sgn * 0.28, 0.04), wood)
		limb.rotation.x = sgn * 0.25   # tips bend back toward the string (+Z)
		p.add_child(limb)
	p.add_child(_box(Vector3(0.004, 0.84, 0.004), Vector3(0, 0, 0.1), Color(0.9, 0.9, 0.8)))   # string
	p.add_child(_box(Vector3(0.01, 0.01, 0.7), Vector3(0, 0.02, -0.2), Color(0.95, 0.85, 0.1)))  # arrow, tip at -Z
	return p
