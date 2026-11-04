# Monsters from monster-forge (3D)

monster-forge (a sibling checkout, `../monster-forge`) generates rigged, textured, animated monsters (GLB). This
project copies them into `assets/monsters/<id>/` and loads them at runtime. Nothing is
hand-made per monster: one loader (`scripts/monster.gd`) turns any synced folder into a
playable node, and `scenes/monster_lab.tscn` shows them.

```bash
python3 -I tools/sync_monsters.py --all                 # or --ids wolf harpy
godot res://scenes/monster_lab.tscn                     # look at them
godot --headless -s res://tools/check_monsters.gd       # import test, prints ALL PASS
xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan \
    -s res://tools/lab_screenshot.gd -- /tmp/shots views=three,front,side,hand_r,hand_l,lods
```

`assets/monsters/` is git-ignored (generated art, ~15 MB per monster): sync after cloning.

## Sync (`tools/sync_monsters.py`)

Stdlib Python, run with `python3 -I`. Reads `../monster-forge/out/<source>/<id>/` (`--forge`,
`$MONSTER_FORGE`, `--source`, default `srd-5.2.1`) and writes `assets/monsters/<id>/`:

| file | from |
|---|---|
| `model_rigged.glb` | LOD0: skinned mesh, skeleton, material with embedded textures |
| `model_rigged_lod<k>.glb` | LOD k: same skeleton and joint order, geometry only, no images |
| `anims/<clip>.glb` | one armature-only clip per file, clip name = file stem |
| `monster.json` | trimmed manifest: `id`, `name`, `source`, `scale_m`, `body_plan`, `sockets` (`{socket: {bone, from}}`), `clips`, `lods` (`{k: {file, tris}}`), `joints` |

Files are compared by content, so a re-run only copies what changed and prints each
added, updated or removed file. GLBs that are no longer upstream are removed (with their
`.import`). Monsters without `model_rigged.glb` are skipped. With `--all`, a synced
monster that has no rig upstream right now (being regenerated) is kept and reported.
`model_hi.glb`, PNGs and `paint/` are never copied.

## Loading: runtime `GLTFDocument`, not the import pipeline

`Monster.load_monster(id)` reads the GLBs with `GLTFDocument.append_from_file()` +
`generate_scene()`. This is the robust option here because:

- a sync is usable right away: no editor import pass, and headless tools work on a fresh
  checkout;
- per-file import settings (no auto-LODs on the LOD files, clip files as animation
  libraries) would live in `.import` files, which this repo git-ignores;
- LOD files and clip files are treated the same way as LOD0, by name, the way the
  monster-forge viewer does it.

The editor still imports these GLBs when it opens the project (`godot --headless --import`
takes about 16 s for six monsters, without errors). It also extracts the embedded textures
next to them as PNGs. Nothing uses those imports. A game that wants VRAM-compressed
textures or drag-and-drop scenes can switch to the import pipeline. The track
retargeting and LOD wiring below stay the same.

What runtime loading does not do for you, so the loader does it:

- **Mipmaps.** Runtime GLTF textures are `ImageTexture`s without mipmaps (2048² RGBA8).
  The loader generates them, because without mipmaps the albedo shimmers at distance.
- **RESET animation.** See below.

Exported builds: add `assets/monsters/*` to the export preset's non-resource filter, the
same way as `*.json`, so the raw GLBs ship. This has not been tested with an export yet.

### Tree

```
<id> (Node3D, scripts/monster.gd)
  model                       generate_scene() of model_rigged.glb
    Armature/Skeleton3D       the only skeleton
      lod0 .. lod3            MeshInstance3D, all with LOD0's Skin and material
      socket_hand_r           BoneAttachment3D + prop (attach_prop)
  AnimationPlayer             library "": RESET + every anims/<clip>.glb
```

## The export contract, as verified in Godot 4.7.1

Measured by `tools/check_monsters.gd` and screenshots on the six pilots (2026-11-04).

| contract | result |
|---|---|
| Units, origin | metres; the lowest rest-pose vertex is at y = 0.000 for every pilot; the bbox is centred on x and z |
| Size | `scale_m` = the longest body axis: height for upright plans (goblin 1.00, harpy 1.70), length on z for the rest (wolf 1.50, owlbear 2.80, giant spider 3.00, dragon 6.30) |
| Up | +Y |
| Facing | **-Z**, for all six. The head end is at -Z for the quadrupeds and the dragon, and the front and top screenshots show the faces toward -Z. On handed bipeds `hand_r` is at +X (creature's right = +X). Use `Node3D.look_at(target)` as is (`use_model_front = false`). This is the opposite of glTF's own "+Z is front" and of Godot's `Vector3.MODEL_FRONT` (+Z). |
| Skeleton | one `Skeleton3D` per file. Bones named `bone_<n>`, socket bones named by socket. LOD1-3 have the same bone names in the same order and the same skin binds (by index) and bind poses as LOD0. Checked per file, any difference is rejected. |
| LOD material | the LOD files have a material (`Material_0.001`, not LOD0's name) without textures. The loader applies LOD0's material as a surface override. |
| Clips | armature-only GLB. All tracks are `Armature/Skeleton3D:<bone>` and bind 100% by bone name (wolf 18/18, owlbear 18/18, spider 31/31, harpy 12/12, dragon 27/27, goblin 9/9) |
| Root motion | none: walk clips are in place, and the root bone ends where it starts |

### Animations

Clip tracks are rebound by bone name: `track.path = <path to our Skeleton3D>:<bone>`.
Tracks whose bone is missing are dropped and counted (`report.clips[clip].unbound`).
None were dropped on the pilots. Clips named `idle`, `walk`, `run`, `move`, `fly`,
`swim` and `hover` loop. Every other clip plays once.

Godot's glTF importer drops channels that never leave the rest pose. The walk GLBs
carry one channel per bone and property (wolf: 84), but only the 17-18 that move become
tracks. The constant channels all equal the rest pose, so nothing is lost. The catch is
that clips then key different bone sets, and an `AnimationPlayer` leaves bones the new
clip does not key in the old clip's pose. Measured: after walk -> a clip keying one bone,
16 of the wolf's 28 bones stayed posed, by up to 58°. The loader fixes this with
`AnimationPlayer.deterministic = true` (false by default in 4.7) plus a `RESET` animation
that keys every bone's rest pose. The check now leaves 0 bones off rest. The editor
importer makes RESET itself; runtime loading does not.

### LODs

All LOD meshes are skinned to the one LOD0 skeleton with the same `Skin`, so a clip
drives every LOD. Checked by CPU skinning: each LOD-k vertex matched to its nearest LOD0
vertex moves the same way mid-walk (p95 difference 2-37 mm while LOD0 vertices move up to
0.07-0.45 m). Screenshots at the same frame show the same pose and texture on LOD0-3.

Switching is **automatic, with `GeometryInstance3D.visibility_range_begin/end`**. The
switch distances come from the monster-forge viewer's screen-coverage thresholds (LOD0
above 60% of the viewport height, LOD1 30%, LOD2 12%), turned into camera distances from
LOD0's bounding sphere and the camera FOV:
`d = r / sin(atan(c * tan(fov / 2)))`. For the wolf at fov 50° that is 3.6, 7.0 and 17.2 m,
and for the dragon 22, 43 and 107 m. `set_lod(k)` pins a level, and `set_lod(-1)` goes back
to auto. Verified with `RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME`: between each pair of
switch distances the monster adds an exact multiple (main pass plus shadow splits) of
that LOD's triangle count, and never a mix. Godot's own mesh auto-LOD does not apply,
because runtime meshes have no generated LODs.

### Sockets and props

`attach_prop(prop, socket)` adds a `BoneAttachment3D` (`bone_name = socket`) under the
skeleton and parents the prop to it, scaled by `scale_m / 1.8`. `make_sword()` and
`make_bow()` are placeholders in the prop space from monster-forge's `docs/equipment.md`:
origin at the grip, +Y along the blade or limbs, and -Z the cutting edge (red stripe) or
arrow (yellow). The lab gives every monster with `hand_r` a sword, and the goblin a sword
plus a bow on `hand_l`.

**Mismatch: the socket bone is not a grip frame.** equipment.md defines the socket as the
deform hand bone (head at the wrist) and the prop origin as the centre of the fist, with +Y
along the blade. In Godot a `BoneAttachment3D` puts the prop at the bone's origin with the
bone's axes. That is the wrist, with +Y running wrist -> fingers (0° from the hand bone's
direction). On the goblin the sword hangs from the wrist, pointing down along the fingers
and through the floor. A held weapon needs a grip frame: origin about half a hand-length
along the hand bone, and +Y across the palm (thumb side). Either the rig exports
`grip_r` / `grip_l` child bones in prop space, or equipment.md specifies the
hand-to-grip offset per rig. Until then, props need a hand-tuned offset node.

## Monster lab (`scenes/monster_lab.tscn`)

A ground grid (0.5 m, brighter every metre, +X red, +Z blue), a 1.8 m reference capsule
with a nose on -Z, and a sun with shadows. The monster list is every folder in
`assets/monsters/` with a `monster.json`.

| input | action |
|---|---|
| drag (left or right button), wheel | orbit, zoom |
| arrows, `+` / `-` | orbit, zoom |
| `J` / `K`, PgDn / PgUp, first dropdown | next / previous monster |
| `N` / `Shift+N`, second dropdown | next / previous clip; `0` rest pose |
| Space | pause / resume |
| `L`, third dropdown | cycle LOD auto -> 0 -> 1 -> 2 -> 3; `A` back to auto |
| `B`, checkbox | skeleton overlay (sockets magenta, socket +Y green, -Z red) |
| `P`, checkbox | props |
| `F` | frame the monster |

The status line shows the LOD that auto mode draws, the camera distance and the switch
distances.

## Known issues in the current pilots (reported upstream)

- Walk clips push geometry below y = 0 mid-stride. Lowest skinned vertex over a cycle:
  owlbear -0.19 m (leg bone_25), dragon -0.10 m (tail bone_64), harpy -0.10 m (pelvis
  bone_0), wolf -0.05 m (foot bone_26), goblin -0.03 m, spider -0.01 m.
- Harpy: the skeleton is off-centre (root at x +0.068, shoulders at +0.26 / -0.125). The
  right forearm and hand bones (bone_18, bone_19) carry no vertex with weight > 0.5. The
  right arm is skinned to the wing chain (bone_11, bone_12), so `hand_r` does not follow
  the visible right hand. The harpy's `hand_*` sockets are added child bones at the
  hand bone's tail, 8-9 cm off the mesh. The goblin's are the renamed hand bones, at
  the wrist, 2.3 cm from the surface.
- LOD files name their material `Material_0.001` rather than LOD0's `Material_0`
  (`docs/lods.md` says same name). Harmless here, because the material is overridden.
- With `--verbose`, Godot warns "Buffer view byte stride should be declared for vertex
  attributes". There are no warnings without `--verbose`.
