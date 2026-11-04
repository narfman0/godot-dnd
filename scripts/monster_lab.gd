## Monster lab: look at any monster synced into res://assets/monsters (tools/sync_monsters.py).
## Nothing here is per-monster: the list comes from the folder, the model, LODs and clips are
## loaded at runtime by scripts/monster.gd.
##
## Mouse: drag to orbit, wheel to zoom. Keys: J/K (or PgDn/PgUp) monster, N/Shift+N clip,
## 0 rest pose, Space pause, L cycle LOD (auto, 0-3), A auto LOD, B skeleton, P props,
## F frame, arrows orbit, +/- zoom.
extends Node3D

const Monster = preload("res://scripts/monster.gd")
## Props per monster; any other monster with a hand_r socket gets the sword.
const LOADOUT := {"goblin-warrior": {"hand_r": "sword", "hand_l": "bow"}}
const FOV := 50.0

var monster: Node3D
var ids := PackedStringArray()
var cam_yaw := 0.6         ## 0 = camera on the -Z side, looking at the monster's face
var cam_pitch := 0.25
var cam_dist := 4.0
var cam_target := Vector3(0, 1, 0)
var show_skeleton := false
var show_props := true

var _camera: Camera3D
var _figure: Node3D
var _bones_mesh: ImmediateMesh
var _ui_monster: OptionButton
var _ui_clip: OptionButton
var _ui_lod: OptionButton
var _ui_skel: CheckBox
var _ui_props: CheckBox
var _status: Label
var _dragging := false


func _ready() -> void:
	_build_world()
	_build_ui()
	ids = Monster.list_ids()
	for id in ids:
		_ui_monster.add_item(id)
	if ids.is_empty():
		_status.text = "No monsters in res://assets/monsters.\nRun: python3 -I tools/sync_monsters.py --all"
		return
	select_monster(ids[0])


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.17, 0.2)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.75, 0.8)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.2
	add_child(sun)
	_camera = Camera3D.new()
	_camera.fov = FOV
	_camera.far = 500.0
	add_child(_camera)
	add_child(_grid(20, 0.5))
	_figure = _reference_figure()
	add_child(_figure)
	var skel_mi := MeshInstance3D.new()
	_bones_mesh = ImmediateMesh.new()
	skel_mi.mesh = _bones_mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.vertex_color_use_as_albedo = true
	m.render_priority = 10
	skel_mi.material_override = m
	skel_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(skel_mi)


## Ground grid: half_size metres each way, a line every step, brighter every metre, axes red (+X) and blue (+Z).
func _grid(half_size: int, step: float) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var n := int(half_size / step)
	for i in range(-n, n + 1):
		var v := i * step
		var c := Color(0.45, 0.45, 0.5) if is_zero_approx(fmod(absf(v), 1.0)) else Color(0.28, 0.28, 0.32)
		for seg in [[Vector3(v, 0, -half_size), Vector3(v, 0, half_size)], [Vector3(-half_size, 0, v), Vector3(half_size, 0, v)]]:
			var col := c
			if i == 0:
				col = Color(0.3, 0.4, 0.9) if seg[0].x == 0 else Color(0.9, 0.3, 0.3)
			im.surface_set_color(col)
			im.surface_add_vertex(seg[0] + Vector3(0, 0.001, 0))
			im.surface_set_color(col)
			im.surface_add_vertex(seg[1] + Vector3(0, 0.001, 0))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	mi.material_override = m
	return mi


## 1.8 m capsule with a nose on -Z: it faces the same way as the monsters.
func _reference_figure() -> Node3D:
	var f := Node3D.new()
	f.name = "reference_1_8m"
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.22
	cap.height = 1.8
	body.mesh = cap
	body.position.y = 0.9
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.6, 0.7)
	body.material_override = m
	f.add_child(body)
	var nose := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.08, 0.06, 0.12)
	nose.mesh = bm
	nose.position = Vector3(0, 1.62, -0.25)
	nose.material_override = m
	f.add_child(nose)
	return f


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_ui_monster = OptionButton.new()
	_ui_monster.item_selected.connect(func(i): select_monster(ids[i]))
	box.add_child(_ui_monster)
	_ui_clip = OptionButton.new()
	_ui_clip.item_selected.connect(func(i): select_clip(_ui_clip.get_item_text(i)))
	box.add_child(_ui_clip)
	_ui_lod = OptionButton.new()
	for t in ["LOD auto", "LOD0", "LOD1", "LOD2", "LOD3"]:
		_ui_lod.add_item(t)
	_ui_lod.item_selected.connect(func(i): set_lod_mode(i - 1))
	box.add_child(_ui_lod)
	_ui_skel = CheckBox.new()
	_ui_skel.text = "skeleton (B)"
	_ui_skel.toggled.connect(func(on): show_skeleton = on)
	box.add_child(_ui_skel)
	_ui_props = CheckBox.new()
	_ui_props.text = "props (P)"
	_ui_props.button_pressed = true
	_ui_props.toggled.connect(func(on): set_props_visible(on))
	box.add_child(_ui_props)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	box.add_child(_status)
	var help := Label.new()
	help.text = "drag orbit · wheel zoom · J/K monster · N clip · 0 rest · space pause\nL LOD · A auto · B skeleton · P props · F frame"
	help.add_theme_font_size_override("font_size", 11)
	box.add_child(help)


func select_monster(id: String) -> void:
	if monster:
		monster.queue_free()
		monster = null
	var m: Node3D = Monster.load_monster(id, FOV)
	if m == null:
		_status.text = "load failed: " + Monster.last_error
		return
	monster = m
	add_child(m)
	_ui_monster.select(ids.find(id))
	var loadout: Dictionary = LOADOUT.get(id, {"hand_r": "sword"})
	for socket in loadout:
		var prop: Node3D = Monster.make_sword() if loadout[socket] == "sword" else Monster.make_bow()
		m.attach_prop(prop, socket)
	m.set_props_visible(show_props)
	_figure.position = Vector3(m.aabb.position.x - 0.6, 0, 0)
	_ui_clip.clear()
	_ui_clip.add_item("rest")
	for c in m.clips():
		_ui_clip.add_item(c)
	var start: String = "walk" if "walk" in m.clips() else ("rest" if m.clips().is_empty() else m.clips()[0])
	select_clip(start)
	set_lod_mode(m.lod_mode)
	frame()


func select_clip(clip: String) -> void:
	if not monster:
		return
	monster.play(clip)
	for i in _ui_clip.item_count:
		if _ui_clip.get_item_text(i) == clip:
			_ui_clip.select(i)


func set_lod_mode(k: int) -> void:
	if not monster:
		return
	monster.set_lod(clampi(k, -1, monster.lods.size() - 1))
	_ui_lod.select(monster.lod_mode + 1)


func set_props_visible(on: bool) -> void:
	show_props = on
	_ui_props.set_pressed_no_signal(on)
	if monster:
		monster.set_props_visible(on)


func frame() -> void:
	if not monster:
		return
	cam_target = monster.aabb.get_center()
	cam_dist = monster.radius / sin(deg_to_rad(FOV) * 0.5) * 1.05


func _process(_delta: float) -> void:
	cam_pitch = clampf(cam_pitch, -0.2, 1.45)
	cam_dist = maxf(cam_dist, 0.3)
	var dir := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))
	_camera.position = cam_target + dir * cam_dist
	_camera.look_at(cam_target)
	_draw_skeleton()
	if monster:
		var drawn: int = monster.auto_lod_at(_camera.global_position) if monster.lod_mode < 0 else monster.lod_mode
		var clip: String = monster.anim.current_animation if monster.anim.is_playing() else "rest"
		_status.text = "%s  %s  scale_m %s\nbones %d  clip %s %s\nLOD%d drawn (%s)  %d tris\ncamera %.1f m  switch at %s m" % [
			monster.info["name"], monster.info.get("body_plan", ""), monster.info.get("scale_m"),
			monster.skeleton.get_bone_count(), clip, "" if not monster.anim.is_playing() or monster.anim.speed_scale > 0 else "(paused)",
			drawn, "auto" if monster.lod_mode < 0 else "pinned", monster.lods[drawn].mesh.surface_get_array_index_len(0) / 3,
			_camera.global_position.distance_to(monster.aabb.get_center()),
			", ".join(Array(monster.lod_ranges).map(func(r): return "%.1f" % r))]


func _draw_skeleton() -> void:
	_bones_mesh.clear_surfaces()
	if not show_skeleton or not monster:
		return
	var sk: Skeleton3D = monster.skeleton
	_bones_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for b in sk.get_bone_count():
		var p := sk.get_bone_parent(b)
		if p < 0:
			continue
		var is_socket: bool = sk.get_bone_name(b) in monster.info.get("sockets", {})
		var col := Color(1, 0.3, 0.9) if is_socket else Color(1, 0.85, 0.2)
		_bones_mesh.surface_set_color(col)
		_bones_mesh.surface_add_vertex(sk.global_transform * sk.get_bone_global_pose(p).origin)
		_bones_mesh.surface_set_color(col)
		_bones_mesh.surface_add_vertex(sk.global_transform * sk.get_bone_global_pose(b).origin)
	# socket axes: +Y green (prop's blade), -Z red (prop's edge)
	for s in monster.info.get("sockets", {}):
		var bi := sk.find_bone(s)
		if bi < 0:
			continue
		var g := sk.global_transform * sk.get_bone_global_pose(bi)
		for ax in [[g.basis.y.normalized() * 0.15, Color(0.2, 1, 0.2)], [-g.basis.z.normalized() * 0.15, Color(1, 0.2, 0.2)]]:
			_bones_mesh.surface_set_color(ax[1])
			_bones_mesh.surface_add_vertex(g.origin)
			_bones_mesh.surface_set_color(ax[1])
			_bones_mesh.surface_add_vertex(g.origin + ax[0])
	_bones_mesh.surface_end()


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_dragging = ev.pressed
		elif ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist *= 0.9
		elif ev.pressed and ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist *= 1.1
	elif ev is InputEventMouseMotion and _dragging:
		cam_yaw -= ev.relative.x * 0.01
		cam_pitch += ev.relative.y * 0.01
	elif ev is InputEventKey and ev.pressed and monster:
		var clips: PackedStringArray = monster.clips()
		match ev.keycode:
			KEY_J, KEY_PAGEDOWN:
				select_monster(ids[(ids.find(monster.id) + 1) % ids.size()])
			KEY_K, KEY_PAGEUP:
				select_monster(ids[(ids.find(monster.id) - 1 + ids.size()) % ids.size()])
			KEY_N:
				if clips.size():
					var cur := clips.find(monster.anim.current_animation)
					select_clip(clips[(cur + (-1 if ev.shift_pressed else 1) + clips.size()) % clips.size()])
			KEY_0:
				select_clip("rest")
			KEY_SPACE:
				monster.anim.speed_scale = 0.0 if monster.anim.speed_scale > 0 else 1.0
			KEY_L:
				set_lod_mode(monster.lod_mode + 1 if monster.lod_mode + 1 < monster.lods.size() else -1)
			KEY_A:
				set_lod_mode(-1)
			KEY_B:
				show_skeleton = not show_skeleton
				_ui_skel.set_pressed_no_signal(show_skeleton)
			KEY_P:
				set_props_visible(not show_props)
			KEY_F:
				frame()
			KEY_LEFT:
				cam_yaw += 0.15
			KEY_RIGHT:
				cam_yaw -= 0.15
			KEY_UP:
				cam_pitch += 0.1
			KEY_DOWN:
				cam_pitch -= 0.1
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				cam_dist *= 0.9
			KEY_MINUS, KEY_KP_SUBTRACT:
				cam_dist *= 1.1
