# Monsters from monster-forge (3D)

monster-forge (a sibling checkout, `../monster-forge`) generates rigged, textured, animated monsters (GLB). This
project copies them into `assets/monsters/<id>/` and loads them at runtime. Nothing is
hand-made per monster: one loader (`scripts/monster.gd`) turns any synced folder into a
playable node, and `scenes/monster_lab.tscn` shows them.

```bash
python3 -I tools/sync_monsters.py --all                 # monsters + props; or --ids wolf harpy, --props
godot res://scenes/monster_lab.tscn                     # look at them
godot --headless -s res://tools/check_monsters.gd       # import test, prints ALL PASS
xvfb-run -a -s "-screen 0 1280x800x24" godot --rendering-driver vulkan \
    -s res://tools/lab_screenshot.gd -- /tmp/shots clips=all ts=0.5 views=three,grip_r,lods
```

`assets/monsters/` and `assets/props/` are git-ignored (generated art: ~15 MB per monster,
19 MB for all 32 props), so sync after cloning.

## Sync (`tools/sync_monsters.py`)

Stdlib Python, run with `python3 -I`. Reads `../monster-forge/out/<source>/<id>/` (`--forge`,
`$MONSTER_FORGE`, `--source`, default `srd-5.2.1`) and writes `assets/monsters/<id>/`:

| file | from |
|---|---|
| `model_rigged.glb` | LOD0: skinned mesh, skeleton, material with embedded textures |
| `model_rigged_lod<k>.glb` | LOD k: same skeleton and joint order, geometry only, no images |
| `anims/<clip>.glb` | one armature-only clip per file, clip name = file stem |
| `monster.json` | trimmed manifest: `id`, `name`, `source`, `scale_m`, `body_plan`, `sockets` (`{socket: {bone, from}}`), `clips`, `lods` (`{k: {file, tris}}`), `joints`, plus `wields` and `shield` from the registry record (`data/registry/<source>.json`) |

Props come from `out/props/<id>/` and go to `assets/props/<id>/`: `model.glb`,
`model_lod<k>.glb`, `lods.json` and `manifest.json` (copied whole; the game reads
`category`, `grip`, `grip_socket`, `stow_socket` and `prop.grip_offset` /
`prop.offhand_grip`).
- `--all` syncs every rigged monster and every prop.
- `--ids a b` syncs those monsters and the props they wield.
- `--props [id ...]` syncs props only, all of them when no id is given.

Files are compared by content, so a re-run only copies what changed and prints each
added, updated or removed file. GLBs that are no longer upstream are removed (with their
`.import`). Monsters without `model_rigged.glb` are skipped. With `--all`, a synced
monster that has no rig upstream right now (being regenerated) is kept and reported.
`model_hi.glb`, `model_raw.glb`, PNGs and `paint/` are never copied.

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
| Clips | one armature-only GLB per clip, listed in `manifest.anim.clips`. All tracks are `Armature/Skeleton3D:<bone>` and bind 100% by bone name, for every clip of every pilot (36 clips; table below) |
| Root motion | none: the clips are in place, and the root bone ends where it starts |
| Grip sockets | `grip_r` / `grip_l`: non-deforming children of `hand_r` / `hand_l`, at the centre of the fist (goblin: 2 cm from the hand bone, 53-66 vertices within 5 cm), in prop space. At rest +Y points forward (-Z) and +Z points up (+Y), so a sword points forward with its -Z edge down. Goblin and harpy have them. |

Round 3 run (2026-11-04, after `sync_monsters.py --all`), tracks bound / total per clip:

| id | bones | clips (bound/total) | lowest y during walk (bone) |
|---|---|---|---|
| giant-spider | 37 | attack_melee 32/32, death 32/32, hit 32/32, idle 31/31, walk 31/31 | -0.001 (bone_22) |
| goblin-warrior | 40 | attack_melee 12/12, attack_ranged 8/8, death 15/15, hit 14/14, idle 14/14, walk 9/9 | -0.000 (bone_27) |
| harpy | 38 | attack_melee 14/14, death 17/17, fly 16/16, hit 18/18, idle 18/18, walk 10/10 | -0.008 (bone_0) |
| owlbear (new rig) | 22 | attack_melee 20/20, death 21/21, hit 20/20, idle 19/19, walk 18/18 | -0.012 (bone_10) |
| wolf | 28 | attack_melee 21/21, death 23/23, hit 21/21, idle 22/22, walk 18/18 | -0.001 (bone_16) |
| young-red-dragon | 67 | attack_melee 32/32, breath 26/26, death 26/26, fly 30/30, hit 34/34, idle 36/36, walk 26/26 | -0.000 (bone_20) |

### Animations

Clip tracks are rebound by bone name: `track.path = <path to our Skeleton3D>:<bone>`.
Tracks whose bone is missing are dropped and counted (`report.clips[clip].unbound`).
None were dropped on the pilots.

Loop modes come from a name list, `Monster.LOOPING` (`idle`, `walk`, `run`, `move`, `fly`,
`swim`, `hover`), not from the GLB, which has no loop flag. Every other clip (`hit`,
`death`, `attack_*`, `breath`) is `LOOP_NONE`: it plays once and stops on its last frame.
`Monster.settle_clip` sets what happens next. With `""` (the default) the last frame holds.
The lab sets it to `"idle"`, so hit, attacks and breath go back to idle afterwards, while
clips in `Monster.HOLD_LAST` (`death`) always hold their last frame. The check plays every
clip for its length + 0.3 s in real frames:
- looping clips are still playing;
- one-shots have stopped, within 0.06° of their last frame;
- with `settle_clip = "idle"`, hit, attacks and breath move on to idle, and death holds.

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

**Where props go.** Held props go on `grip_socket("r")` / `grip_socket("l")`: `grip_r` /
`grip_l` when the rig has them (goblin, harpy), else `hand_r` / `hand_l`.
`attach_prop(prop, socket)` adds a `BoneAttachment3D` (`bone_name = socket`) under the
skeleton, parents the prop to it, and scales it by `scale_m / 1.8`. This scaling is meant
for upright bodies; the loader does not check the body plan, since only handed bodies get
props.

**Real props.** `Monster.load_prop(id)` loads `assets/props/<id>/`:
- **Tree:** `prop_<id>` holds `body`, which holds `model` (the GLTF scene).
- **LODs:** `model_lod1-3` meshes are added beside LOD0 with LOD0's material and
  switched by visibility range. Their radius is rescaled when the prop is attached.
- **Metadata:** `manifest`, `grip_offset`, `offhand_grip`.
- **Fallback:** when a prop is not synced, the lab uses the CSG placeholders
  `make_sword()` / `make_bow()`, which are in the same prop space.

`tools/check_monsters.gd` loads all 32 props. Each has 4 LODs sharing LOD0's material,
the origin (grip) inside the mesh bounds, and the measured length within 2 cm of
`length_check`. The axis is +Y for most props, -Z for crossbows and pistols, and
max(X, Y) for the shield. Every manifest `offhand_grip` has a matching `offhand_grip` node
in model.glb (fork, glaive, greataxe, greatclub, greatsword, pike, quarterstaff, and the
light and heavy crossbows).

**grip_offset.** It is applied the way the viewer applies it (`loadRealProp` in
monster-forge's `viewer/app.js`):
- only on `grip_*` sockets, never on `hand_*`;
- as `body.transform = (Basis.from_euler(rotation_deg_xyz, EULER_ORDER_XYZ), translation_m)`;
- Godot's XYZ order is X·Y·Z, the same as three.js 'XYZ'.

Melee weapons have none. Bows, crossbows, pistols and the shield have +90° about X.
`Monster.apply_grip_offset` (lab key `G`, `lab_screenshot.gd gripoffset=0`) turns it off
to compare.

**Lab loadout** (`monster_lab.gd loadout_for()`), from `monster.json` `wields` and each
prop's manifest:
- The first prop whose `grip_socket` is `hand_r` goes on the right hand, and the first on
  `hand_l` (bows) on the left.
- A shield takes the left hand only when the record has `shield` and nothing else claimed
  that hand.
- A two-handed prop (`grip: 2`) clears the left hand.

So the goblin carries a scimitar on `grip_r` and a shortbow on `grip_l`; its shield is not
shown, and stowing is a game job (below). Monsters with no `wields` (the harpy and the
four beasts) carry nothing.

**Round 3 verdicts** (goblin at t=0.5, screenshots plus numbers from `check_monsters.gd`):
- **Scimitar on `grip_r`: correct in every clip.** The hilt is inside the closed fist.
  - idle and walk: tip forward (0, 0.15, -0.99), curved edge down.
  - attack_melee: blade raised overhead, tip (0.02, 0.92, 0.40), edge forward (-0.43, 0.37, -0.83).
  - Scale 0.556 (1.0 m goblin), so 0.44 m.
- **Shortbow on `grip_l` with grip_offset +90° X: wrong in the shooting pose.**
  - attack_ranged: the bow lies flat in front of the chest, limbs horizontal (tip (-0.58, 0, 0.81)), arrow direction straight up (0, 1, 0).
  - idle: upright beside the leg. This looks right, but the stave crosses the fist sideways instead of running through it.
- **The same shortbow with the offset off:**
  - attack_ranged: limbs vertical, string toward the archer, arrow forward. Correct.
  - idle: the stave runs through the fist and points forward, held low. Also correct for a stave.
- **Conclusion:** a bow's stave runs through the fist exactly like a sword's handle, so
  `grip_offset` should be identity for bows. The +90° only makes the rest pose look upright,
  and it breaks every pose where the forearm is raised. An upright bow at rest belongs in
  the idle clip's wrist, or in a separate carry offset that is not used in combat. The lab
  still applies the offset by default, to mirror the viewer; press `G` to compare.
- **Shield and crossbows/pistols:** not exercised by a pilot (the goblin's shield is not
  drawn). The same question applies: does the shield's handle (or the pistol's grip) run
  along prop +Y, through the fist? If yes, the +90° is wrong for them too.

**What the game still has to do with props:**
- **Off-hand IK.** Two-handed props carry an `offhand_grip` node, 0.3-0.6 m along +Y
  (−Z for crossbows). Drive a two-bone IK on the other arm (`SkeletonIK3D`, or a
  `TwoBoneIK3D` modifier in 4.7) toward
  `prop.find_child("offhand_grip").global_transform` every frame. The lab does not do
  this, so two-handers would be held one-handed.
- **Stowing.** Sheathe one-handers on `hip_l`, two-handers, bows and shields on `back`,
  using `stow_socket` from the prop manifest. These sockets have no defined frame yet:
  the prop-space orientation on `back` / `hip_*` still has to be specified upstream, the
  way the grips were.
- **Swapping per clip.** For example, sheathe the scimitar for attack_ranged (the lab keeps
  it in hand), and show the shield when no bow is drawn.
- **Scale by body plan.** `scale_m / 1.8` applies to upright wielders only.

**History: before round 2 there were no grip bones, and the hand bone is not a grip
frame.** A `BoneAttachment3D` on `hand_r` puts the prop at the wrist with +Y running
wrist -> fingers. On the goblin the sword hung from the wrist, pointing down through
the floor. The rig stage now exports `grip_r` / `grip_l` in prop space.

## Monster lab (`scenes/monster_lab.tscn`)

A ground grid (0.5 m, brighter every metre, +X red, +Z blue) and a 1.8 m reference capsule
with a nose on -Z. Lighting is close to the monster-forge viewer's studio setup:
- a procedural sky that supplies ambient light and reflections;
- a key light with shadows from the front-right, where the monsters face (the round 1 sun
  lit them from behind);
- a fill light from behind-left.

Without the sky, metallic surfaces render nearly black. Some pilots export metallic ≈ 1.0
(goblin, harpy; see below). The monster list is every folder in
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
| `G` | toggle `grip_offset` on grip sockets (reloads the monster) |

The status line shows the LOD that auto mode draws, the camera distance and the switch
distances.

## Known issues in the current pilots (reported upstream)

- Fixed in round 2: walk clips no longer push geometry below y = 0. The worst is now the
  owlbear at -0.015 m (in round 1 it was -0.19 m).
- Fixed in round 3: every pilot's material now has `metallicFactor` 0, so it renders
  matte. The metallic texture's blue channel is 255 throughout, but the factor zeroes it.
  In round 2 the goblin and harpy were effectively full metal and read almost black
  without an environment.
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
