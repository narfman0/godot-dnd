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
##     AnimationPlayer       library "" = every anims/<clip>.glb, tracks retargeted
##
## Contract (docs/monsters.md): metres, origin at the feet, +Y up, the creature faces -Z
## (so Node3D.look_at() works with use_model_front = false), creature's right is +X.
extends Node3D

const ROOT := "res://assets/monsters"
## Clip names that loop. Everything else plays once and stops on its last frame (the GLBs
## carry no loop flag; this list decides).
const LOOPING := ["idle", "walk", "run", "move", "fly", "swim", "hover"]
## One-shots that never hand over to settle_clip: the pose holds.
const HOLD_LAST := ["death"]
## Screen-coverage switch points (fraction of viewport height), same as monster-forge's viewer.
const LOD_COVERAGE := [0.6, 0.3, 0.12]

static var last_error := ""

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
	for clip in info.get("clips", []):
		_add_clip(lib, dir, clip)
	lib.add_animation("RESET", _reset_animation())
	anim.add_animation_library("", lib)
	anim.animation_finished.connect(_on_clip_finished)
	return true


func _on_clip_finished(clip: StringName) -> void:
	if settle_clip != "" and String(clip) not in HOLD_LAST and anim.has_animation(settle_clip):
		anim.play(settle_clip)


## Every bone keyed at its rest pose. Godot drops glTF channels that never leave the rest
## pose, so clips key different bone sets. With AnimationMixer.deterministic (false by
## default on AnimationPlayer in 4.7) un-keyed tracks take the RESET animation's values;
## without both, switching walk -> idle leaves the bones idle does not key in walk's pose
## (measured: 16 of 28 wolf bones stuck, up to 58 deg). The editor's scene importer adds
## RESET itself; runtime GLTFDocument loading does not.
func _reset_animation() -> Animation:
	var a := Animation.new()
	a.length = 0.001
	var sp := String(get_path_to(skeleton))
	for b in skeleton.get_bone_count():
		var rest := skeleton.get_bone_rest(b)
		var path := NodePath("%s:%s" % [sp, skeleton.get_bone_name(b)])
		var t := a.add_track(Animation.TYPE_POSITION_3D)
		a.track_set_path(t, path)
		a.position_track_insert_key(t, 0.0, rest.origin)
		t = a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, path)
		a.rotation_track_insert_key(t, 0.0, rest.basis.get_rotation_quaternion())
		t = a.add_track(Animation.TYPE_SCALE_3D)
		a.track_set_path(t, path)
		a.scale_track_insert_key(t, 0.0, rest.basis.get_scale())
	return a


## Runtime GLTFDocument textures have no mipmaps (the editor importer would add them);
## without them the albedo shimmers at distance.
func _mipmap_material(mesh: Mesh) -> void:
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
## name. Tracks whose bone is missing are dropped and counted.
func _add_clip(lib: AnimationLibrary, dir: String, clip: String) -> void:
	var rep := {"tracks": 0, "bound": 0, "unbound": [], "length": 0.0, "error": ""}
	report["clips"][clip] = rep
	var sc := _gltf_scene("%s/anims/%s.glb" % [dir, clip])
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
		var key: String = clip if names.size() == 1 else "%s:%s" % [clip, n]
		a.loop_mode = Animation.LOOP_LINEAR if clip in LOOPING else Animation.LOOP_NONE
		rep["length"] = a.length
		lib.add_animation(key, a)
	sc.free()


func clips() -> PackedStringArray:
	var out := PackedStringArray()
	if anim:
		for n in anim.get_animation_list():
			if n != "RESET" and not n.begins_with("_"):
				out.append(n)
	return out


## Plays a clip from the start; "" or "rest" stops and shows the bind pose.
func play(clip: String) -> void:
	if clip == "" or clip == "rest" or not anim.has_animation(clip):
		anim.stop()
		skeleton.reset_bone_poses()
		return
	anim.play(clip)


## -1: auto (GeometryInstance3D visibility ranges, by camera distance). k: pin LOD k.
func set_lod(k: int) -> void:
	lod_mode = k
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


## Parents prop under a BoneAttachment3D on the socket bone. Props are built for a 1.8 m
## wielder and scaled by scale_m / 1.8 (docs/equipment.md "Prop space").
func attach_prop(prop: Node3D, socket: String) -> bool:
	if not has_socket(socket):
		prop.free()
		return false
	detach_prop(socket)
	var ba := BoneAttachment3D.new()
	ba.name = "socket_" + socket
	ba.bone_name = socket
	skeleton.add_child(ba)
	var s: float = float(info.get("scale_m", 1.8)) / 1.8
	prop.scale = Vector3.ONE * s
	ba.add_child(prop)
	props[socket] = ba
	return true


func detach_prop(socket: String) -> void:
	if props.has(socket):
		props[socket].queue_free()
		props.erase(socket)


func set_props_visible(v: bool) -> void:
	for ba in props.values():
		ba.visible = v


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
