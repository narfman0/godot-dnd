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
    -s res://tools/lab_screenshot.gd -- ~/shots clips=all ts=0.5 views=three,grip_r,lods
# any loadout (like the forge viewer's ?prop_r=&prop_l=), bow strings off:
#   ... -- ~/shots ids=harpy clips=attack_melee prop_r=longsword prop_l=none bowstring=0
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
| `anims/<clip>.glb` | one armature-only clip per file, clip name = file stem; UAL bipeds: only their own clips (see "Shared UAL clips") |
| `../_shared/ual/` | once for all UAL bipeds: `library.json` + one GLB per shared UAL clip (from `out/<source>/_shared/ual/`) |
| `../_shared/paired/` | once for all UAL bipeds: paired animations, `library.json` + `<entry>.json` sidecars + one GLB per actor clip (from `out/<source>/_shared/paired/`; see "Paired animations") |
| `monster.json` | trimmed manifest: `id`, `name`, `source`, `scale_m`, `body_plan`, `sockets` (`{socket: {bone, from}}`), `clips`, `lods` (`{k: {file, tris}}`), `joints`, plus `wields` and `shield` from the registry record (`data/registry/<source>.json`); `ual_shared` from the manifest's `anim.ual_shared` (UAL bipeds); `rider_height_m` when the manifest, the override (`data/overrides/<source>/<id>.json`) or the record sets it (centauroids, merfolk/naga: prop scale, see "Sockets and props"); `swarm_unit` when the manifest has it (a swarm made as one unit, see "Swarm units"); `tags`, the content tags from monster-forge's `data/tags.computed.json` (see "Tags") |

Props come from `out/props/<id>/` and go to `assets/props/<id>/`: `model.glb`,
`model_lod<k>.glb`, `lods.json` and `manifest.json` (copied whole; the game reads
`category`, `grip`, `grip_socket`, `stow_socket` and `prop.grip_offset` /
`prop.offhand_grip`).
- `--all` syncs every rigged monster that has clips (`anims/*.glb`) and every prop. A rig
  without clips yet (centaur-trooper in round 4) is listed as skipped; `--ids` syncs it anyway.
- `--ids a b` syncs those monsters and the props they wield.
- `--props [id ...]` syncs props only, all of them when no id is given.

Files are compared by content, so a re-run only copies what changed and prints each
added, updated or removed file. GLBs that are no longer upstream are removed (with their
`.import`). Monsters without `model_rigged.glb` are skipped. With `--all`, a synced
monster that has no rig upstream right now (being regenerated) is kept and reported.
`model_hi.glb`, `model_raw.glb`, PNGs and `paint/` are never copied.

### Tags

`monster.json` `tags` lists the monster's content tags (monster-forge `docs/tags.md`, `tools/tags.py`):
source (`srd`), creature type (`type-beast`), family (`dinosaur`, `dragon`, `canine` ...), role, trait,
movement (`flying`, `aquatic` ...), size, CR band (`cr-low` ...) and body plan. Pipeline tags (`rig-ual`,
`paired` ...) are not copied: `ual_shared` already says it. `Monster.ids_with_tags(["dinosaur"])` returns
the synced ids that carry every tag given (a random dinosaur: pick one of them). Re-sync after
monster-forge recomputes its tags.

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
      ual_lift                UAL bipeds with lift curves: SkeletonModifier3D (scripts/ual_lift.gd)
  AnimationPlayer             library "": RESET + every anims/<clip>.glb (+ aliases of shared clips)
                              library "ual": the shared UAL library (UAL bipeds; one object for all)
```

## The export contract, as verified in Godot 4.7.1

Measured by `tools/check_monsters.gd` and screenshots on the six pilots (2026-11-04), and
again on the nine body-plan pilots in round 4 (below).

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
| Grip sockets | `grip_r` / `grip_l`: non-deforming children of `hand_r` / `hand_l`, at the centre of the fist (goblin: 2 cm from the hand bone, 53-66 vertices within 5 cm), in prop space. At rest +Y points forward (-Z) and +Z points up (+Y), so a sword points forward with its -Z edge down. Goblin, harpy, ghost, merfolk-skirmisher (since round 5) and centaur-trooper (round 6, `grip_r` only) have them. |

Round 3 run (2026-11-04, after `sync_monsters.py --all`), tracks bound / total per clip:

| id | bones | clips (bound/total) | lowest y during walk (bone) |
|---|---|---|---|
| giant-spider | 37 | attack_melee 32/32, death 32/32, hit 32/32, idle 31/31, walk 31/31 | -0.001 (bone_22) |
| goblin-warrior | 40 | attack_melee 12/12, attack_ranged 8/8, death 15/15, hit 14/14, idle 14/14, walk 9/9 | -0.000 (bone_27) |
| harpy | 38 | attack_melee 14/14, death 17/17, fly 16/16, hit 18/18, idle 18/18, walk 10/10 | -0.008 (bone_0) |
| owlbear (new rig) | 22 | attack_melee 20/20, death 21/21, hit 20/20, idle 19/19, walk 18/18 | -0.012 (bone_10) |
| wolf | 28 | attack_melee 21/21, death 23/23, hit 21/21, idle 22/22, walk 18/18 | -0.001 (bone_16) |
| young-red-dragon | 67 | attack_melee 32/32, breath 26/26, death 26/26, fly 30/30, hit 34/34, idle 36/36, walk 26/26 | -0.000 (bone_20) |

Round 4 (2026-11-04): the nine body-plan pilots (monster-forge `docs/rig-anim.md`, "Body
plans"; centaur-trooper has no clips yet and is skipped). `check_monsters.gd` passes on all
15 monsters: every clip binds 100% of its tracks, every rig has 4 LODs on one `Skeleton3D`
with LOD0's skin, every loop's first and last frames match (seam 0.0000 m), every one-shot
stops on its last frame and death holds it.

| id | plan | bones | clips (bound/total) | move clip | lowest y over the move clip | death ends at y |
|---|---|---|---|---|---|---|
| constrictor-snake | serpentine | 16 | attack_melee 5/5, death 15/15, hit 15/15, idle 15/15, swim 15/15, walk 15/15 | walk | 0.000 (contact) | 0.000 |
| ghost | floating | 37 | attack_melee 12/12, death 13/13, fly 10/10, hit 13/13, idle 14/14 | fly | 0.178 (lift) | 0.000 |
| giant-eagle | avian | 32 | attack_melee 17/17, death 19/19, fly 17/17, hit 17/17, idle 16/16 | fly | 0.320 (hover) | 0.000 |
| black-pudding | amorphous | 4 | attack_melee 5/5, death 4/4, hit 4/4, idle 4/4, walk 4/4 | walk | 0.000 (contact) | 0.000 |
| violet-fungus | plant_object | 5 | attack_melee 4/4, death 6/6, hit 4/4, idle 4/4, walk 5/5 | walk | 0.000 (contact) | 0.000 |
| giant-octopus | tentacled | 42 | attack_melee 13/13, death 43/43, hit 43/43, idle 43/43, swim 42/42 | swim | 0.215 (lift) | 0.000 |
| hunter-shark | aquatic | 32 | attack_melee 13/13, death 14/14, hit 13/13, idle 13/13, swim 13/13 | swim | 0.718 (lift) | 0.000 |
| merfolk-skirmisher | merfolk_naga | 57 | attack_melee 17/17, attack_ranged 17/17, death 12/12, hit 17/17, idle 16/16, swim 13/13 | swim | 0.423 (lift) | 0.000 |
| swarm-of-rats | swarm | 1 | attack_melee 2/2, death 1/1, hit 2/2, idle 2/2, walk 2/2 | walk | 0.000 (contact) | 0.000 |

What round 4 checks, beyond rounds 1-3 (all in `check_monsters.gd`, per monster):
- **Every GLB channel that moves becomes a track.** The check reads each clip GLB's own
  channels and finds no channel that leaves the node's rest value without a Godot track
  of that type on that bone. Scale included: the blob (black-pudding root
  `spine_00`, every clip), the swarm (`root`, every clip), the octopus (root: idle, hit,
  death) and the fungus walk carry scale tracks, and seeking to the key furthest from 1
  gives the bone exactly that pose scale (pudding death: (1.57, 0.22, 1.57)). Godot needs
  nothing special for scale: the runtime `GLTFDocument` imports `scale` channels as
  `TYPE_SCALE_3D` tracks, and the RESET animation keys rest scale.
- **Ground per clip** (CPU skinning of LOD0 at 13 frames): lowest vertex at the first
  frame, the minimum over the clip and the last frame. No clip of any of the 15 monsters
  goes more than 3 cm below y = 0 (worst: young-red-dragon attack_melee -0.022, ghost hit
  -0.010, eagle hit -0.019). Every death ends with its lowest point at y = 0.000.
- **Hover height across clips.** The lift plans keep one height: hunter-shark starts
  every clip but death at 0.744 m, the ghost at 0.18-0.25 m (the hem moves; root y
  1.09-1.19 m in every clip). The ghost's hit clip dips the hem to -0.010 m for a moment.
  Three monsters change height on purpose between idle and the move clip: the octopus
  (idle on the ground, swim at 0.215 m), the merfolk (idle stands on its tail, swim at
  0.65 m) and the eagle (idle stands, fly at 0.41 m), like the harpy and dragon fly.
- **Clip switches pop without a cross-fade.** Measured at 30 fps, idle -> move clip in
  one frame moves some vertex by 0.14-1.31 m (eagle 1.31, merfolk 1.18, snake 0.80,
  ghost 0.74). With `Monster.blend_time = 0.25` the largest step is 0.03-0.26 m, about
  the size of a normal frame inside the clip (0.02-0.20 m). The lab now cross-fades
  0.25 s; the screenshot tool and the check use 0 (they seek paused clips).
- **Missing hand.** merfolk-skirmisher wields a spear (registry) but its rig has `hand_l` /
  `grip_l` only (the raised right arm was not found). `loadout_for` puts the spear on the
  right, `grip_socket("r")` is `""`, the lab skips it with a warning, and
  `attach_prop(prop, "hand_r")` returns false and frees the prop. Nothing is attached and
  nothing crashes.
- **One bone.** swarm-of-rats: 1 bone (`root`). All 4 LODs load on that skeleton with
  LOD0's skin, all five clips play, and the LOD screenshots at walk 30% show the same
  pose on LOD0-3. The check's LOD-follow probe runs mid-walk, which is exactly the rest
  pose for this clip, so its 0.0000 m says nothing here. With one bone and every weight 1
  there is nothing to disagree on. Idle and walk are at rest mid-cycle, so the "bones
  moved" probe samples them at 30%.

Screenshots (`lab_screenshot.gd clips=move ts=0.25,0.75` and `clips=death ts=0.5,1.0`,
views three and side), what they show:
- **constrictor-snake:** walk slithers with the head end reared; coils stay on the floor.
  Death: the front slumps and the head lies on the ground. Nothing in the floor.
- **ghost:** fly floats with the hem about 0.2 m up, robe trailing behind. Death falls
  forward flat onto the floor. At the last frame the back of the robe stays upright: a
  thin vertical sheet about 0.9 m high at the hem end while the body lies flat (side view).
  Looks like hem vertices weighted to bones the death clip does not rotate.
- **giant-eagle:** fly flaps with the talons hanging about 0.3-0.4 m above the floor.
  Death lands on its breast, wings spread flat, tail fan up. The lab frames the rest
  pose, so the dead eagle (which pitches forward) is partly out of frame.
- **black-pudding:** walk is a subtle ooze. Death flattens into a wide puddle (scale
  plays). No stretched skin beyond the intended squash.
- **violet-fungus:** walk rocks the stalk with the base planted. Death topples to its
  right (+X). The root clump turns with it and stands up vertically, as a rigid body.
- **giant-octopus:** swim lifts it with all tentacles curling; death splays flat on the
  floor. LOD0-3 at the same frame match.
- **hunter-shark:** swims level at 0.72-0.74 m. Death rolls belly-up and lies on the
  floor on its dorsal fin, pectoral fins up. The rest mesh is strongly curved (tail bent
  down, bbox 2.97 m tall for a 4.5 m shark).
- **merfolk-skirmisher:** swim pitches the body forward and kicks the tail, about 0.4-0.65 m
  up. Death topples onto its right side with the raised right arm sticking up into the air.
  attack_melee barely moves the arms, which are spread out in the rest pose. No prop is
  shown anywhere (above).
- **swarm-of-rats:** the mesh is a 1.44 m column of rats rather than a spread swarm. Walk
  is a small scurry. Death squashes the whole column to 15% height, so the rats are
  flattened.
- No monster in round 4 has a prop, and no prop appears on them.

Round 5 (2026-11-04): re-sync after monster-forge df2a463, 81c8194 and 6a804d3 (merfolk right
arm, eagle standing on its feet, harpy right-arm re-weight, lifted idles, ghost / fungus /
swarm / merfolk deaths, props round 2). `check_monsters.gd` ALL PASS on 15 monsters and 32
props. Clips and tracks of the monsters that changed (every clip binds 100%):

| id | clips (bound/total) | rest | lowest y idle / move clip, first frame | idle -> move, largest vertex step per frame: instant / 0.25 s cross-fade (round 4) | idle -> one-shots (attack, hit, death) jump |
|---|---|---|---|---|---|
| giant-eagle | attack_melee 15/15, death 15/15, fly 18/18, hit 16/16, idle 18/18 | stands on its talons, lowest 0.000, bbox 3.97 x 3.81 x 3.40 (round 4: 4.16 tall) | 0.357 / fly 0.373 (min 0.321 / 0.320) | 1.070 / 0.154 m (1.312 / 0.173) | 1.01-1.03 m: the one-shots start on the floor (0.000) |
| giant-octopus | unchanged counts | | 0.348 / swim 0.215 | 0.339 / 0.119 m (0.414 / 0.130) | 0.55 m: one-shots start on the floor |
| merfolk-skirmisher | attack_melee 15/15, attack_ranged 15/15, death 11/11, hit 18/18, idle 18/18, swim 14/14 | sockets now `hand_r`/`grip_r` too | 0.180 / swim 0.659 (swim min 0.431) | 1.029 / 0.155 m (1.177 / 0.152) | 0.19 m: one-shots start on the floor |
| ghost | death 15/15 (was 13) | | 0.254 / fly 0.211 | 0.743 / 0.111 m (0.744 / 0.111) | 0.04-0.15 m |
| harpy | attack_melee 15/15 (was 14) | | | 0.139 / 0.044 m (walk) | |
| violet-fungus | death 4/4 (was 6) | | | | |
| swarm-of-rats | death 2/2 (was 1) | | | | |

- **Idle -> move: the height now matches, the pop does not go away.** The eagle's idle hovers
  at its fly height (0.357 vs 0.373 m, minimum 0.321 vs 0.320). The octopus idle body is at
  the swim lift, but its lowest vertex is 0.348 m against swim's 0.215 (the tentacles hang
  differently; the check still warns 0.13 m). The merfolk idle floats at 0.180 m, while swim
  pitches the body forward and starts at 0.659. An instant switch still moves some vertex
  0.34 m (octopus) to 1.03-1.07 m (merfolk, eagle) in one frame: wing and body-pitch pose
  differences, not height. With `blend_time = 0.25` it is 0.12-0.16 m, the same as round 4.
- **New pop: lifted idle vs grounded one-shots.** The eagle, octopus and merfolk attack, hit
  and death clips all start with the lowest vertex at y = 0, while their idle now hovers.
  `settle_clip = "idle"` therefore lifts them 0.19-0.36 m after every hit or attack, and the
  first frame of each one-shot drops them. Largest vertex jump idle frame 0 -> one-shot frame
  0: eagle 1.01-1.03 m, octopus 0.55 m, merfolk 0.19 m (round 4: idle was on the floor, so
  these matched). Reported upstream.
- **merfolk-skirmisher spear.** `loadout_for` puts the registry spear on `grip_r`; it is drawn
  in the lab and the screenshots. Grip 3.3-3.4 cm from the skin, 16-20 vertices within 5 cm,
  in every sampled frame. The rest pose has the right arm raised, so idle holds the spear
  horizontally above the head (grip at y 1.87 m, tip forward (0, 0.20, -0.98)).
  attack_melee: 25% wind-up overhead with the shaft across behind the head; 50% chop down,
  point toward the floor in front (tip (-0.35, -0.93, -0.11)); 75% swept across the body,
  horizontal, tip pointing back-right. It is a sword cut, not a spear thrust. Death: lies on
  the floor on its side, left arm along the body, tail fin standing up (top 0.83 m). The
  dead spear is out of the lab's frame.
- **harpy `grip_r`** (registry unarmed; tested with a longsword through `loadout_override`
  in the lab and screenshots, and by the check, which attaches a longsword to unarmed rigs
  that have `grip_r`). Grip-to-skin during walk 0.029 m with 14 vertices within 5 cm (round 4:
  0.117 m, none within 10 cm). attack_melee 25/50/75%: 0.009 / 0.020 / 0.024 m (round 4:
  0.033 / 0.269 / 0.067). Screenshots: the hilt is inside the gauntlet at idle, blade
  forward, edge down; the cut raises the blade upright in front of the right shoulder (50%)
  and ends low across the body to the left (75%). The left side is unchanged:
  `grip_l` 0.112 m and `hand_l` 0.082 m from the skin, no vertex within 10 cm of the grip,
  so a left-hand prop would float beside the hand.
- **giant-eagle** stands on its talons at rest (lowest vertex 0.000, tail fan clear of the
  floor). Idle and fly at 50% look alike from the side: upright body, wings up, one leg
  forward, talons about 0.35 m above the floor.
- **ghost death** lies flat: last frame 1.50 x 0.78 x 2.23 m, robe spread on the floor, the
  head end the highest point (0.78 m); no vertical sheet. Hit no longer dips below the floor (min 0.000,
  was -0.010).
- **violet-fungus death** keeps the base planted: root bone `spine_00` turned 0.0 deg and moved
  0.00 m at the last frame. The stalk breaks over just above the base and the cap ends
  standing on its rim beside it, a vertical disc 1.22 m high.
- **swarm-of-rats death** scatters and sinks: root scale (1.7, 0.3, 1.7), turned 12 deg, last
  frame 1.38 x 0.43 x 2.47 m. With one bone this is a uniform squash, so each rat is also
  flattened to 30% height; it reads as a spread pile of flattened rats.
- **Bow strings.** longbow and shortbow: `string` in all 4 LODs, 8 tris, material
  `bowstring`, `set_bowstring_visible(false)` hides all four (check). On the goblin with a
  longbow (`prop_l=longbow`): idle carries the bow low and level with the stave through
  the fist; attack_ranged holds it upright, with the straight string behind the stave. The
  string passes through the goblin's left forearm and shoulder. `bowstring=0` removes
  exactly the string pixels (image diff).
- **Whip** (procedural, 992 tris, 2.50 m, 1.39 m on the goblin): the handle is in the right
  fist and the lash runs forward and sags toward the tip. It is one rigid mesh, so in
  attack_melee it is a straight rod held overhead. A real lash needs bones or a
  simulation in the game.
- **glaive / harpoon / greatclub** on the goblin's `grip_r` (`prop_r=`): at idle each points
  forward (-Z) with the shaft through the fist, the butt behind the hand. The glaive's convex
  edge faces down and its back spikes face up (the -Z edge is down at rest, as for swords).
  The harpoon's barbed head is forward and the greatclub's heavy end is forward. In
  attack_melee all three are raised overhead with the head up. They are held one-handed:
  there is no off-hand IK yet.
- **Loader change:** `load_prop` required exactly one mesh, so the new bows failed to load
  (would have fallen back to the CSG placeholder). It now takes the stave plus an optional
  `string` node (above).

Round 6 (2026-11-04): re-sync after monster-forge ede55a9, 71dd174 and 1def4a4 (new
stretched snake, a real centaur, re-rolled eagle, merfolk thrust and arm relax, lifted
one-shots). Synced with `--ids constrictor-snake centaur-trooper giant-eagle
merfolk-skirmisher giant-octopus swarm-of-rats ghost`; swarm-of-rats had no change (its
scatter death came in round 5). `--all` would also have updated the harpy (its rig is being
rewritten upstream; not synced or tested this round). `check_monsters.gd` ALL PASS on 16
monsters and 32 props; every clip binds 100%.

| id | clips (bound/total) | rest bbox x,y,z m | lowest y idle / move, first frame (min) | idle -> move per frame: instant / 0.25 s cross-fade | idle -> one-shots, largest vertex jump at frame 0 |
|---|---|---|---|---|---|
| centaur-trooper (new) | attack_melee 21/21, death 19/19, hit 19/19, idle 21/21, walk 17/17 | 1.59 x 2.40 x 2.10 | -0.004 / walk -0.003 (-0.006) | 0.379 / 0.082 m | 0.168 m (one-shots start on the floor, like idle) |
| constrictor-snake | attack_melee 6/6, death 15/15, hit 15/15, idle 15/15, swim 15/15, walk 15/15 | 0.40 x 0.56 x 4.00 | 0.000 / walk 0.000 (0.000) | 0.439 / 0.168 m; idle -> swim frame 0 jump 1.245 | 0.270 m |
| giant-eagle | attack_melee 9/9, death 8/8, fly 17/17, hit 10/10, idle 17/17 | 5.84 x 5.29 x 3.83 (round 5: 3.97 x 3.81 x 3.40) | 0.352 / fly 0.368 (0.320) | 1.754 / 0.182 m (round 5: 1.070 / 0.154) | 0.938 m: pose only, attack / hit / death now start at 0.348 (round 5: 0.000) |
| giant-octopus | attack_melee 14/14, death 43/43, hit 43/43, idle 43/43, swim 42/42 | unchanged | 0.212 / swim 0.215 (round 5: 0.348 / 0.215) | 0.275 / 0.124 m (0.339 / 0.119) | 0.225 m (round 5: 0.55): one-shots start at 0.205 |
| merfolk-skirmisher | attack_melee 16/16, attack_ranged 15/15, death 12/12, hit 19/19, idle 19/19, swim 16/16 | unchanged | 0.180 / swim 0.659 (0.431) | 1.030 / 0.139 m | 0.059 m attack_melee, hit, death (round 5: 0.19); attack_ranged 0.614 (starts from the raised rest arm) |
| ghost | death 15/15 | unchanged | | | death now starts at 0.180 (idle 0.254), jump 0.104 m, the same as hit |

Ground: no clip below -0.01 m except the centaur's death (min -0.033 m mid-fall, WARN);
every death ends at 0.000. Screenshots (`lab_screenshot.gd`, plus a scratch script that
stands the goblin next to the eagle):
- **constrictor-snake:** the 4 m mesh lies stretched along the floor (renders with its
  texture-stage colours, a python pattern). Walk: an S-wave travels along the body in the top
  view, and the whole length stays on the floor in the side view, the head end a little
  raised. attack_melee keys the front five bones only: the head rears about 0.3-0.5 m at 25%,
  drops forward and down at 50-75% and lifts a little at the end. A small strike for a 4 m
  snake.
- **centaur-trooper:** faces -Z, four legs on the floor; renders textured (palomino horse,
  bearded rider with a green hood). Walk: the four hooves cycle in diagonal pairs, and the
  hind hooves drag almost flat at the back of the stride. **The tail swings like a hind
  leg**: the manifest has no tail bones (`parts.tail` is empty), and the long tail sheet
  follows the near hind leg. At 0% it is swept forward under the belly with that leg, and
  at 50% its tip kicks forward like a hoof. attack_melee is a **thrust**, not a sword cut
  (the registry `pike` is a polearm; manifest `style: thrust`): the right forearm drives
  forward, the grip moves from z -0.69 to -1.36 m and up 0.22 m, and the prop axis stays
  forward ((-0.18, 0.24, -0.95) at 50%). The stick the reference drew (an arrow shaft out of
  the left side) shreds into a fan of dark spikes in front of the chest at 25-75%. With
  `prop_r=longsword prop_l=longbow` the lab warns "centaur-trooper: no grip_l / hand_l bone,
  longbow not shown", attaches nothing on the left and keeps the sword (no crash). Death
  lies on its side, head on the floor.
- **centaur pike: wrong scale and one-handed.** `attach_prop` scales by `scale_m / 1.8` =
  1.333 (scale_m 2.4 is the whole centaur), so the 3.5 m pike becomes 4.7 m and very thick,
  while the rider's arm is human-sized. It is a two-hander (`grip: 2`) on a one-armed rig,
  and its butt runs back along the horse's flank. `grip_r` is 13 cm from `hand_r` and 5.4 cm
  from the nearest skin at idle (0 vertices within 5 cm; goblin 2 cm), 8-9 cm in the thrust.
- **giant-eagle:** stands on its talons at rest, wings raised and symmetric in the front
  view, painted as a bald eagle. Idle and fly look the same at 25% and 75%: upright, wings
  up, one leg forward, talons ~0.35 m above the floor (small beat). attack_melee: at 25% the
  head is drawn back behind the near wing with a dark gap at the neck; at 50% the body
  pitches forward and the beak leads, forward and down; at 75% it comes back. Death lies on
  its breast, wings spread, tail fan standing up. **Scale:** 5.84 m wingspan, 5.29 m to the
  raised wing tips, the head at about 3.5 m. Next to the 1.0 m goblin, the eagle's legs alone
  are the goblin's height. A 20 ft wingspan is right for a Large giant eagle; the height
  comes from the raised wings.
- **merfolk-skirmisher:** idle holds the spear upright at the right side, the shaft from
  the tail up past the head, tip up (0.07, 0.95, -0.31), grip at y 1.52 m (round 5: level
  above the head). attack_melee is a thrust: at 25% it is drawn back with the shaft across
  the face, at 50% the arm is straight forward with the tip forward (-0.18, 0.23, -0.95), and
  at 75% it is still forward and a little up. The spear prop shows no clear blade: the
  forward end is a wooden section with lugs and a short dark tip.
- **giant-octopus:** idle, attack_melee and hit at frame 0 sit at the same height from the
  side: no pop. attack_melee at 50% rises and reaches with the front tentacles.
- **swarm-of-rats:** death unchanged since round 5: a wide pile of flattened rats.
- **ghost:** death lies flat as in round 5 (last frame 1.50 x 0.78 x 2.23 m).

Round 7 (2026-11-04): the harpy only, after monster-forge 9213dc2 and 1638b68. Its rig is now
the SkinTokens roll_1 with wing chains the rig stage inserts from the mesh (`wing_r_00..03`,
`wing_l_00..03`, both on `bone_3`), plus a seam-aware arm-wing weight blend. The hand-built
rig and its re-weights are gone. `sync_monsters.py --ids harpy` updated 11 files: the 4 LOD
GLBs, 6 clips and `monster.json`. `check_monsters.gd harpy` gives ALL PASS (with the 32 props)
and one WARN: fly starts 0.36 m above idle, which round 5 also had (0.35).

| | round 7 | round 5 |
|---|---|---|
| bones | 32: `bone_0`..`bone_21` (some), `hand_*`/`grip_*`, `wing_l_00..03`, `wing_r_00..03` | 38 |
| clips (bound/total) | attack_melee 14/14, death 17/17, fly 16/16, hit 17/17, idle 17/17, walk 10/10 | 15/15, 17/17, 16/16, 18/18, 18/18, 10/10 |
| LODs | LOD0-3 on one `Skeleton3D` with LOD0's skin, 32 binds each, all 8 `wing_*` bound; LOD1-3 follow the skeleton (p95 0.002 / 0.006 / 0.008 m) | same |
| wing tracks | fly keys all 8 `wing_*`; idle and hit key `wing_l_00`, `wing_r_00`; attack_melee, walk and death key `wing_r_00` | (no `wing_*`) |
| nearest skin at walk 0.55 s: `hand_r` / `hand_l` / `grip_r` / `grip_l` | 3.1 / 2.2 / 2.2 / 1.8 cm (12 / 14 / 6 / 16 vertices within 5 cm) | 1.9 / 8.2 / 2.9 / 11.2 cm (17 / 0 / 14 / 0) |
| `grip_r` in attack_melee 25 / 50 / 75% | 2.2 / 2.2 / 1.8 cm; grip at y 1.73 / 1.62 / 0.83 m | 0.9 / 2.0 / 2.4 cm; y 1.27 / 1.18 / 0.77 |
| grip from its hand bone | `grip_r` 0.108 m, `grip_l` 0.105 m | 0.034 m |
| lowest y idle / walk (min over the clip) | -0.008 / -0.023 | -0.002 / -0.008 |
| idle -> walk per frame: instant / 0.25 s cross-fade / inside walk | 0.206 / 0.043 / 0.054 m | 0.139 / 0.044 / 0.035 m |
| idle frame 0 -> attack_melee / hit / walk / fly frame 0 | 0.167 / 0.060 / 0.175 / 1.274 m | 0.014 / 0.025 / 0.113 / 1.378 m |
| death last frame | lying, top 0.876 m, `bone_0` turned 90 deg, ends at 0.000 | top 0.907 m |

Longsword through `loadout_override`: at idle on `grip_r` the tip points forward (0, 0.15,
-0.99) with the edge down. At attack_melee 50% the tip is (-0.57, 0.82, -0.02).

Bone trace of fly (a scratch script that seeks the clip and reads the global bone poses):
`hand_r` stays at x 0.48 and `hand_l` at x -0.37 in all four samples. The hands move only with
the body's bob (y 1.16-1.26 m). Meanwhile `wing_r_03` swings from (1.11, 1.49) at 0% through
(0.86, 1.24) and (0.36, 1.05) to (0.75, 1.07) at 75%. In attack_melee, `hand_r` rises to
y 1.63 m at 25% while `wing_r_01` stays at y 1.18-1.30 m.

Screenshots (`lab_screenshot.gd`, Xvfb). Round 5 has no harpy fly or walk shots:
- **fly, front, 0/25/50/75%:** the wings beat and the arms do not follow. Both hands hang
  at the hips in every frame, and the arm is no longer pulled into the wing. The wings are
  raised and spread at 0%, hang beside the legs at 25%, are folded down behind the hips at
  50% and spread again at 75%.
- **fly tears are at the hanging wing tips, next to the legs.** At 0% (wings spread, the top
  of the upstroke), the long lower feathers stretch sideways from the hips into flat blades
  out past the wing span, longer on the right. At 25% a thin strip runs from the hip down to
  the floor below the feet (side view). At 50% a thin dark sliver crosses in front of the
  shins at ankle height (front view). This matches the Blender count: 96 stretched edges,
  mostly feather tips skinned to the thighs and hips beside `wing_*_03`.
- **fly, side:** the wings stay behind the back. The beat is mostly sideways, so the side
  view changes little, apart from the strip at 25%.
- **attack_melee with a longsword, three-quarter, 25/50/75%:** the sword arm lifts clean of
  the wing. At 25% the right arm is straight up above the head with the blade level across
  the top. At 50% the fist is above and in front of the face and the blade is raised
  diagonally. At 75% the cut has come down across the body to the left, with the blade
  level at the belt. In all three the right wing stays where it was.
  - **Change from round 5:** the cut is now raised much higher. In round 5 the blade was
    upright in front of the right shoulder at 50%, and 25% held it low.
  - **New tear:** a flat grey sheet comes off the raised right armpit. At 25% it hangs
    down the side of the torso, and at 50% it spans across the chest under the arm. This
    is the right-side part of Blender's 48 sword-cut edges. Round 5's lower cut showed no
    such sheet.
- **attack_melee, `grip_r` close-ups:** the hilt passes through the fist at 25, 50 and 75%,
  with the guard just outside it. At 75% the forearm reads as a flat dark plate above the
  fist.
- **idle with a longsword on `grip_r`** (close-up and three-quarter): the hilt is under the
  gauntlet's fingers, the blade forward and the edge down. This is the same as round 5.
- **idle with a longsword on `grip_l`** (close-up and three-quarter): the left fingers close
  over the hilt and the blade points forward. In round 5 `grip_l` was 11 cm off the skin
  and a left-hand prop floated beside the hand.
- **walk 50%:** a normal stride with both wings hanging behind. In the side view, a thin
  strip from a hanging feather tip runs from the knee down to the floor and along it behind
  the front foot. This is the same tear as in fly (Blender: 5 walk edges).

Round 8 (2026-11-05): re-sync after monster-forge 1def4a4..f8bb67e (eagle on the avian
max-dimension scale, cobra strike, merfolk throw, harpy body seam, every legged idle starting
on the rest pose with one-shots starting on the idle's first frame and walks at the cycle
frame nearest it). Synced with `--ids` for 15 monsters (not `--all`: centaur-trooper and the
GPU stream's monsters were left alone). Updated: giant-eagle (rig, LODs, 5 clips), harpy (rig,
LODs, 5 clips; fly unchanged), constrictor-snake (5 clips), merfolk-skirmisher
(attack_ranged), goblin, wolf, owlbear, spider, dragon (clips and LOD2-3), ghost (idle,
attack, death). Octopus, pudding, fungus, shark and swarm were unchanged. `check_monsters.gd`
on the 15: ALL PASS (32 props), every clip binds 100%. WARNs are the three fly/swim height
changes (harpy fly, dragon fly, merfolk swim), as before.

**Check change:** the snake's new idle is a standing wave (sin 2πt), so at 50% it is exactly
the rest pose and the "every clip moves a bone" probe failed. The probe now tries 50%, then
30% (which the one-bone swarm already needed), and says so in the output.

Jumps, in metres. "Frame 0" is the check's `jump in` column: the largest LOD0 vertex distance
between idle frame 0 and the clip's frame 0. "Probe" is `_transition`: idle is played 0.5 s,
then the clip starts, and the largest per-frame step is reported, both instant and with a
0.25 s cross-fade. Before = round 6 (harpy: round 7).

| id | clips bound | frame 0: attack / hit / death (before) | frame 0: move clip (before) | probe instant / cross-fade (before) |
|---|---|---|---|---|
| goblin-warrior | 12/12, 15/15 ranged, 15, 14, 14, 9 | 0 / 0 / 0, ranged 0 (0.522 / 0.027 / 0.027, 0.027) | walk 0.072 (0.099, -27%) | 0.073 / 0.039 (0.116 / 0.033) |
| wolf | 21, 23, 21, 22, 18 | 0 / 0 / 0 (0.067 / 0.074 / 0.074) | walk 0.197 (0.246, -20%) | 0.221 / 0.061 (0.223 / 0.061) |
| owlbear | 20, 21, 20, 19, 18 | 0 / 0 / 0 (0.051 / 0.052 / 0.052) | walk 0.219 (0.267, -18%) | 0.221 / 0.067 (0.268 / 0.069) |
| giant-spider | 32, 32, 32, 31, 31 | 0 / 0 / 0 (0.062 each) | walk 0.093 (0.414, -78%) | 0.096 / 0.100 (0.345 / 0.042) |
| young-red-dragon | 32, breath 26, 26, fly 30, 34, 36, 26 | 0 / 0 / 0.042, breath 0 (0.775 / 0.764 / 0.764, 0.786) | walk 0.435 (0.423, +3%); fly 3.341 (same) | **1.506 / 0.269** (0.955 / 0.102) |
| harpy | 14, 17, fly 16, 17, 17, 10 | 0 / 0 / 0 (0.167 / 0.060 / 0.060) | walk 0.122 (0.175, -30%); fly 1.274 (same) | 0.174 / 0.039 (0.206 / 0.043) |
| giant-eagle (new rig, 56 bones) | 16, 16, fly 16, 15, 16 | 0.072 each (0.938) | fly 0.010 (0.616) | 1.121 / 0.192 (1.754 / 0.182) |
| constrictor-snake | 12, 15, 15, 15, swim 15, 15 | 0 / 0 / 0 (0.270) | walk 0.379 (0.717), swim 0.320 (1.245) | 0.599 / 0.215 (0.439 / 0.168) |
| merfolk-skirmisher | 16, ranged 16, 12, 19, 19, swim 16 | 0.059, ranged 0.059 (0.614) | swim 1.040 (same) | 1.030 / 0.139 (same) |
| ghost | 12, 15, fly 10, 13, 14 | 0 / 0 / 0 (0.044 / 0.104 / 0.104) | fly 0.801 (0.702) | 0.841 / 0.117 (0.742 / 0.111) |
| octopus, shark, pudding, fungus, swarm | unchanged | 0.225, 0.140, 0.041, 0.051, 0 | swim 0.384, swim 0.210, walk 0.203, walk 0.090, walk 0 | unchanged |

- **Godot agrees with Blender.** Every frame-0 number above equals the clip's `from_idle_m`
  in monster-forge `anims/clips.json` to the millimetre (for example dragon death 0.042, walk
  0.435, fly 3.341; spider walk 0.093; octopus 0.2248). The eagle's `clips.json` (22:03) is
  older than `from_idle_m` and has none. Godot measures it at 0.072 for the one-shots and
  0.010 for fly, which are the values monster-forge's docs give from a scratch run.
- **Frame 0 is now matched, but the game does not switch on frame 0.** A one-shot fired
  mid-idle starts from wherever the idle is. A scratch scan (idle sampled at 16 points of
  its cycle, against each clip's frame 0) gives the largest jump over the cycle, the jump
  at idle 0.5 s, and how far the idle wanders from its own first frame:
  - Goblin, wolf, owlbear, spider, harpy, swarm: one-shots 0.02-0.10 m at worst, which is the idle's own sway.
  - Dragon: 1.66 m. The idle swings the tail tip (`bone_66`, lying on the floor at the left
    side) 1.66 m sideways at 0.62 s and 1.34 m the other way at 1.88 s. The in-phase
    5-degree sway adds up along the 9-bone curled tail. This is why the probe got worse:
    idle -> walk 0.955 -> 1.506 m instant, 0.102 -> 0.269 m with the cross-fade.
  - Eagle: 1.69 m. The idle beats its wings (bone_36 wing tip), so mid-idle it is far from
    both its own frame 0 and fly's. This is by design, the same as a fly-to-fly switch.
  - Snake: 0.28 m (its standing wave).
  - Ghost: 0.23 m.
  - Octopus and shark: 0.36 / 0.28 m.

  The 0.25 s cross-fade stays the game's tool for mid-idle switches. Only the dragon's tail
  needs a change upstream.
- The probe's spider number has the cross-fade (0.100) larger than the instant switch
  (0.096). The walk starts 0.09 m from the idle, so the blend adds no smoothing. It is not
  a pop.
- Harpy walk's lowest point is -0.010 (round 7 -0.023). The idle, attack and hit stay at
  -0.008: these are the two hip-feather ground contacts.

Screenshots (`lab_screenshot.gd`, Xvfb, plus the eagle-and-goblin scratch scene from round 6):
- **giant-eagle rest / idle / fly:** stands on its talons with the wings raised and spread,
  3.0 m wingspan, about as tall as the 1.8 m capsule at the head. Idle 0% and fly 0% are the
  same picture. Idle 25% looks like fly 25%. At 50% the idle's wings are lower and the fly's
  are swept forward and down. The talons are about 0.35 m off the floor in idle and fly.
  **Next to the goblin**, the goblin reaches the eagle's belly. Round 6's eagle was 5.3 m to
  the wing tips, with legs alone as tall as the goblin. This scale reads right.
- **Eagle lunge (side, three-quarter, 0/25/50/75%):** small. At 25% the head draws back a
  little, at 50% the body pitches and the beak goes forward and down, and at 75% it comes
  back. No neck gap at 25% (round 6 had a dark gap). The raised wings hold their pose all
  through. It reads as a peck rather than a lunge (head travel 0.26 x body length,
  monster-forge).
- **constrictor-snake strike, 25/50/75%:** at 25% the front third rears into a cobra S, with
  the head about 0.6 m up and looking ahead. At 50% it has struck forward and down, the head
  near the floor and the body slid forward. 75% is still in the hold. The rear of the body
  stays on the floor throughout, and the top view shows a slight sideways coil at 25%. This
  is a real strike now (round 6: head up 0.3-0.5 m).
- **merfolk attack_ranged with the spear, 25/50/75%:** at 25% the spear is cocked above and
  behind the head, tip forward-up and the shaft trailing back. At 50% it is level at head
  height, tip forward, at release. At 75% the arm is forward and the spear level at chest
  height. It still starts from the relaxed arm, so there is no raised-arm pop. The spear is
  not thrown, of course: the game would detach it at release.
- **harpy fly, front, 0/25/50%:** the 0% blades are gone. The hip feathers hang beside the
  thighs, and the only long tips are the wings' own. At 25% a thin wing-tip feather hangs to
  knee height on one side, with no strip to the floor. 50% is clean.
- **harpy cut with a longsword, three-quarter, 25/50%:** at 25% the blade is level above the
  head and at 50% raised diagonally. No grey sheet under the raised right armpit at either
  frame (round 7 had one at both).
- **harpy walk, side, 0/50%:** a short stride; the near foot is forward at 0% and the far foot
  at 50%. The near wing's feathers hang in front of the legs to the floor with tapered tips,
  and no torn strip. The feet are partly hidden behind that wing, so the stride ends are
  hard to read from the side.
- **goblin idle / attack_melee / attack_ranged / hit / death at 0%, side and front:**
  pixel-identical (no pixel differs by more than 30 of 255 below the HUD).
- **young-red-dragon idle 0/25/50% (three-quarter, top):** at 0% the curled tail lies in its
  rest curve. At 25% the whole curl has swung sideways (above).

Round 9 (2026-11-05): re-sync after monster-forge f8bb67e..cade6ef (swarm units, the bounded
idle tail sway, `rider_height_m`). Synced with `--ids` for the 16 monsters already here plus
swarm-of-bats (new). Updated: swarm-of-bats (added), centaur-trooper (5 clips, monster.json),
young-red-dragon (one clip), the spear prop. `check_monsters.gd` on the 17: ALL PASS (32
props), every clip binds 100%; WARNs are the same three fly/swim height changes.

**Swarm units.** monster-forge now makes a swarm as ONE unit (its `docs/references.md` "Swarm
units"): swarm-of-bats is a single 0.3 m bat (avian plan, `custom.bat_wing`, 47 bones, clips
idle, fly, attack_melee, hit, death) and its manifest carries `swarm_unit` = {unit, plan,
rig_template, size, scale_m, swarm: {body_plan, size, scale_m}}. The sync copies it into
monster.json. The game multiplies the unit:
- `Monster.swarm_info()` returns `swarm_unit` (or {}). `spawn_swarm(count)` loads count - 1
  more units of the same id as children of this Monster (the leader, which stays at the
  origin) and returns them; `swarm_units` lists them, `swarm_aabb()` is the merged bounds.
- **Layout:** a sunflower spiral over a disc of diameter `swarm.scale_m` (1.5 m for the
  bats), less a unit radius, jittered by a third of a unit, each unit turned up to ±35° off
  the leader's -Z. Units of a flying or swimming plan (avian / aquatic, or a fly / swim /
  hover move clip) also get a height of 0..`swarm.scale_m`/2 above the leader; ground units
  (rats, beetles, claws) stay on the floor. Seeded by the id, so the layout is the same
  every time.
- **Staggered clips:** the units are slaved to the leader. `play()` on the leader starts the
  same clip on every unit (with its `blend_time`), and each frame the leader's `_process`
  sets every unit to the leader's time plus its `swarm_phase` (k × 0.618 of the clip, mod 1)
  on looping clips, or minus its `swarm_delay` (0-0.35 s) on one-shots. A one-shot that has
  ended on the leader (death holds) puts every unit on its last frame. A flying unit falls
  from its height to the floor over death (height × (1 - f²), f the clip fraction): the
  clip itself only lowers a unit to its own y = 0, so without this the dead bats lay on
  their backs in mid-air. Seeking or pausing
  the leader (lab Space, `lab_screenshot.gd`) moves the whole swarm, and LOD and speed
  follow.
- The lab spawns 12 units for any monster with `swarm_unit` (`SWARM_COUNT`; key `W` or
  `lab_screenshot.gd swarm=1` for the single unit), frames the swarm's bounds and shows
  "swarm: 12 x bat (avian, 0.3 m) over 1.5 m" in the status line.
- `check_monsters.gd` spawns 12 for such monsters: the swarm must fit the footprint plus one
  unit and every unit must be in its own pose at the same moment. Bats: spans 1.21 x 0.88 x
  1.46 m, 12 distinct idle poses.
- A game would rather drive one AnimationPlayer per unit with its own speed and steering
  (or a MultiMesh with baked vertex animation for large counts); the lab's slaving keeps
  the swarm on one timeline so it can be paused and screenshotted. swarm-of-rats is still
  the column pilot (no `swarm_unit`) and loads as one mesh, as before.

Screenshots: the bat swarm in idle, fly and attack_melee reads as a loose cloud of bats between
knee and shoulder height of the 1.8 m capsule, wings at different points of the beat; the single unit (`swarm=1`) is one bat
with spread membrane wings. Death at 50% has the bats tumbling at different heights, and at
100% all 12 lie on their backs on the floor (no squash: the unit's last frame is 0.23 x 0.17
x 0.19 m, rest height 0.18). At 2.6 m (the swarm's frame) the bats draw LOD2.

**Rider height for props.** The centaur's pike was 4.7 m (scale 1.333 from `scale_m` 2.4).
monster-forge's override now sets `rider_height_m` 1.8 for centaur-trooper (the manifest does
not carry it, so the sync reads `data/overrides/srd-5.2.1/<id>.json`), and `attach_prop`
scales by `prop_scale()`. The check's loadout line: pike scale 1.333 -> 1.000, so 4.67 ->
3.50 m. In the lab (idle and attack_melee at 50%, side and three-quarter) the pike now runs from the
horse's rump to about a body length past its chest with a slimmer shaft; before, it was a
third longer and thicker, its butt behind the rump and its head at the frame edge. monster-forge's viewer does the
same with `?prop_r=pike#centaur-trooper` (world scale 1.333 -> 1.0, 4.67 -> 3.50 m).

**Dragon mid-idle (round 8's idle-cycle scan, idle sampled at 16 points against each clip's
frame 0).** monster-forge bounded the idle tail sway by tip travel:

| clip | idle(0) | idle(0.5 s) | over the idle cycle: min / mean / max (round 8 max) |
|---|---|---|---|
| attack_melee, breath, hit | 0 | 0.300 | 0 / 0.197 / 0.307 (1.66) |
| death | 0.042 | 0.298 | 0.042 / 0.214 / 0.317 (1.66) |
| walk | 0.435 | 0.608 | 0.435 / 0.510 / 0.618 (about 1.7) |
| fly | 3.341 | 3.111 | 3.100 / 3.345 / 3.590 (by design: it takes off) |

The idle wanders 0.307 m from its first frame (1.66 in round 8). The probe (idle 0.5 s then
walk) is 0.578 m instant and 0.084 m with the 0.25 s cross-fade (round 8 1.506 / 0.269, round
6 0.955 / 0.102): the cross-faded switch is now smoother than round 6's.

Round 10 (2026-11-05): wolf and centaur-trooper only, after monster-forge 882a7bd and 5600f3e.
Both are re-rigged with a 6-bone tail chain that the rig stage inserts from the mesh
(`tail_00..05`; wolf on `bone_17`, centaur on `bone_15`), and the clips drive *hanging* tails:
a pendulum sway in idle and walk, a lift about the tail's own plane in attack and hit, and in
death the tail rolls with the body. Synced with `--ids wolf centaur-trooper` from the manifests
of 02:43:32 (wolf) and 02:44:42 (centaur); each updated 10 files (rig, 3 LODs, 5 clips,
monster.json), and the props were unchanged. The owlbear was not synced: its tail rig was still
being reworked upstream. `check_monsters.gd` on the two, and on all 16 synced monsters except
the owlbear, gives ALL PASS (32 props). Every clip binds 100%. WARNs: the same three fly/swim
height changes, plus four new ones on the centaur (idle, walk, attack_melee, hit at -0.0301 m,
0.1 mm past the check's -0.03 limit: the tail end, see below).

| | wolf | centaur-trooper |
|---|---|---|
| bones | 34 (28 + `tail_00..05`) | 44 (with `tail_00..05`) |
| tracks bound (attack, death, hit, idle, walk) | 27, 24, 27, 28, 24 (round 8: 21, 23, 21, 22, 18) | 22, 19, 25, 27, 23 (round 6: 21, 19, 19, 21, 17) |
| lowest y per clip, min over the clip | attack -0.002, death -0.009, hit -0.001, idle -0.001, walk -0.001 | attack / hit / idle / walk -0.030 (`tail_05`; hit -0.032 at 4% sampled finer), death -0.009 (`bone_20`) |
| death last frame | lying, top 0.572 m, ends at 0.000 | lying, top 1.579 m, ends at 0.000 |
| frame 0 vs idle frame 0: attack / hit / death | 0 / 0 / 0 (round 8 the same) | 0 / 0 / **0.119** (`tail_05`) |
| frame 0: walk | 0.197 (round 8 0.197) | 0.185 (Blender round 7: 0.239) |
| probe idle 0.5 s -> walk: instant / 0.25 s cross-fade / inside walk | 0.221 / 0.061 / 0.055 (round 8 0.221 / 0.061) | 0.316 / 0.059 / 0.035 |
| idle-cycle scan: idle wander; worst one-shot; walk | 0.091; 0.091; 0.198 (round 8: about 0.09) | 0.156; attack and hit 0.156, death 0.260; walk 0.265 |
| `tail_05` travel: idle / walk / attack / hit | sideways 0.075 / 0.189 m; attack 0.11 m up and back, hit 0.12 m back | sideways 0.12 / 0.44 m (back 0.17 / 0.32); attack 0.22 m back, hit 0.41 m back |
| tail vertices at the end of death | y 0.18-0.43 m (body top 0.57) | y 0.87-1.47 m (body top 1.58) |

Every frame-0 number equals `from_idle_m` in `anims/clips.json`, and every idle-cycle maximum
equals `from_idle_max_m` (centaur 0.1558 / 0.2611 / 0.2663).

- **Centaur death starts 0.119 m off the idle.** The vertex is the tail end. At idle frame 0
  the floor lift has already turned the tail (`tail_05` at z 1.00 and y 0.22, against
  z 0.90 and y 0.25 at rest), while death's first frame has the tail at rest. In round 7 every
  legged one-shot started at 0 except the dragon's death (0.042). The wolf's idle does not lift
  at frame 0, so its death starts at 0.
- **Centaur tail end below the floor:** -0.030 m in idle, walk, attack and hit, from the first
  frame on. Upstream this is by design (`DIP_MAX`): the lower tail is fused to the left hind
  leg, and lifting it clear tears the sheet. The check's limit is -0.03, so it warns.
- **Tails in death stay level.** The roll turns a hanging tail with the body, so in the last
  frame it sticks out sideways at the rump's height, like the stiff legs. The centaur's tail
  is 0.87 m above the floor at its lowest point. It does not drape onto the floor.
- **Grip (centaur):** `grip_r` is 0.131 m from `hand_r`. Nearest skin is 4.5 cm at idle
  (8 vertices within 5 cm) and 4.3 cm in walk. In the thrust at 25/50/75% it is
  2.5/8.1/8.9 cm. `hand_r` is 1.2 cm from the skin in walk. The thrust at 50% is unchanged
  from round 6: grip at (-0.20, 1.65, -1.36), tip (-0.18, 0.24, -0.95). The pike is 3.5 m
  (scale 1.000, `rider_height_m`).

`lab_screenshot.gd` has a new `back` view (camera on +Z), because a hanging tail is hidden
under the rump in the top view and behind the legs in the front view.

Screenshots (`lab_screenshot.gd`, Xvfb):
- **wolf idle 0/25/50/75%, back:** the bushy tail hangs from the rump to the hocks. At 25%
  its end swings a few cm to one side and at 75% to the other (0.075 m). Side and top views
  at 0 and 50% look the same, because the top view cannot see the hanging tail.
- **wolf walk 0/25/50/75%, side, top and back:** a clean four-legged stride. From the side,
  the tail hangs behind the haunches the whole time and never follows a leg. From the back
  it swings like a pendulum, centred at 0 and 50% and to one side at 25 and 75%. At 25% its
  end is squared off. **At 75% a dark patch shows at the tail end beside the hind hock**
  (back view): a fold or back face where the swung tail meets the leg. It is not a
  stretched edge, and Blender counts 0 of those in walk.
- **wolf death, end, side and three-quarter:** the wolf lies on its side and the tail lies
  along with the body. No tear.
- **centaur walk 0/25/50/75%, side, three-quarter and back:** **the tail no longer kicks.**
  The long tail sheet hangs from the rump to the floor behind the hind legs in all four
  frames. From the back it swings side to side (to the outside at 0-25%, inward at 50%,
  straight at 75%), over the hind leg it is fused to. In round 6 it swept under the belly
  at 0% and kicked forward like a hoof at 50%. At 25% the near hind leg steps back into
  the sheet's front edge. The pike moves with the walk's right-arm swing: its head drops to
  near the floor ahead at 25% and rises above head height at 75% (three-quarter).
- **centaur death, end, side, three-quarter and back:** the centaur lies on its side. The
  tail sheet sticks out level beside the rump, parallel to the legs, rather than lying on the
  floor (see above).
- **centaur attack_melee 50% with the pike (side and three-quarter):** a thrust forward and
  up, at 3.5 m. The tail hangs behind. The dark spike fan from the reference's stick is still
  in front of the chest at the grip.

Round 11 (2026-11-05): owlbear, wolf, centaur-trooper, goblin-warrior and merfolk-skirmisher,
after monster-forge 81628b1 and c424467 (4-bone tail chains rooted at the rump, limp tails in
death, every clip starting from the idle's tail pose, arm swing from the loadout). The sync has
no dry run, so a scratch script compared every synced monster and prop against upstream with
`sync_monsters.py`'s own functions. Exactly these five differed, and the props were unchanged.
Synced with `--ids`: owlbear, wolf and centaur 10 files each (rig, 3 LODs, 5 clips,
monster.json), goblin `anims/walk.glb`, merfolk `anims/swim.glb`. A second compare finds
nothing left. `check_monsters.gd` on all 17 synced monsters: ALL PASS (32 props), every clip
binds 100%, and the WARNs are back to the three fly/swim height changes (the centaur's four
-0.0301 warnings are gone).

| | owlbear | wolf | centaur-trooper | goblin-warrior | merfolk-skirmisher |
|---|---|---|---|---|---|
| bones | 24 (20 + `tail_00..03` on `bone_11`) | 32 (28 + `tail_00..03` on `bone_17`; round 10 34) | 42 (`tail_00..03` on `bone_15`; round 10 44) | 40 | 57 |
| tracks bound | attack 24, death 24, hit 24, idle 23, walk 22 | 25, 27, 25, 26, 22 | 22, 23, 23, 25, 22 | walk 10 (round 10 9) | swim 16 |
| lowest y per clip (49 samples) | attack -0.011, death -0.012, hit -0.008, idle -0.008, walk -0.024 (`bone_10`, a foot, at 43%) | -0.002, -0.009, -0.001, -0.001, -0.002 | -0.024 in every clip (`tail_03`; round 10 -0.030 / -0.032) | walk -0.000 | swim 0.428 (lifted) |
| frame 0 vs idle frame 0: one-shots / move | 0 / 0.219 | 0 / 0.197 | 0 (death round 10 0.119) / 0.161 (round 10 0.185) | 0 / 0.072 | 0.059 / 1.040 (swims up) |
| idle-cycle worst: idle wander; one-shots; move | 0.120; 0.120; 0.219 | 0.091; 0.091; 0.198 | 0.128; 0.128; 0.259 (round 10 0.156; death 0.260; 0.265) | 0.050; 0.050; 0.072 | 0.134; 0.076; 1.091 |
| death, last frame: lowest tail vertex / `tail_03` head y (body top) | 0.393 / 0.619 (1.863) | 0.131 / 0.211 (0.572; round 10 0.18) | 0.652 / 0.859 (1.579; round 10 0.867) | - | - |
| grip +Y change over the move clip | - | - | `grip_r` (pike) 0.0 deg (round 10 23.4) | `grip_r` 11.9, `grip_l` (bow) 0.0 | `grip_r` (spear) 2.9 |

Every frame-0 number equals `from_idle_m` and every idle-cycle worst equals `from_idle_max_m`
in `anims/clips.json` within 0.4 mm (for example owlbear walk 0.2189 / 0.2193, centaur walk
0.1610 / 0.2585, merfolk 0.059 / 0.0758 and swim 1.0396 / 1.0906). The lying tails' low points
match Blender's 0.13 / 0.39 / 0.65 m. The grip angles match the clip report (pike 0, bow 0,
scimitar 11.9, spear in swim 2.9 deg). The centaur's walk frame-0 vertex is now the tail end
(`tail_03`), not a leg.

**Pike tip over the walk** (the head, 2.73 m along `grip_r` +Y, scale 1.0). Round 10's clips
were reloaded as a temporary lab monster from monster-forge's tails3 backup (02:44, the files
round 10 synced):
- Round 10: tip y 0.40..1.91 m (0% 1.52, 25% 0.48, 50% 0.81, 75% 1.82), z -3.08..-3.42.
- Round 11: tip y 1.13..1.16 m, z -3.30..-3.37, `grip_r` +Y (0, 0, -1) throughout: level and
  straight ahead.

Screenshots (`lab_screenshot.gd`, Xvfb):
- **owlbear idle and walk 0/50%, side and back:** the fan tail (white-and-brown barred) hangs
  from the rump over the hind legs nearly to the floor. In idle and at walk 0% it is centred.
  At walk 50% it swings to one side, and a thin light sliver shows along its edge. From the
  side it hangs behind the haunches and does not follow a leg. No tear.
- **owlbear death, end, side, back and three-quarter:** lying on its side. From behind, the fan
  bends down off the rump but stays well above the floor (0.39 m), with a dark rim around its
  base where it bends.
- **wolf walk 25/75%, back and side:** round 10's dark patch beside the hind hock at 75% is
  down to a sliver of a few pixels at the tail's edge. At 25% the end is rounded, not squared
  off. From the side the tail hangs behind the haunches.
- **wolf death, end, side and back:** lying on its side. The tail curls down from the rump
  under the body toward the floor (0.13 m). No tear.
- **centaur walk 0/25/50/75%, side (plus three-quarter, top and front at 50%):** the pike stays
  level and straight forward at the height of the horse's back in all four frames (round 10:
  head near the floor at 25%, above head height at 75%). Its butt end (0.77 m behind the grip;
  `grip_r` at x -0.07) runs back into the horse's chest, as the top view shows.
- **centaur death, end, back and side:** the tail sheet droops from the rump and its far end
  bends down toward the floor (round 10: level, sticking out beside the rump). It does not
  reach the floor (0.65 m).
- **goblin walk 0/50%, side and three-quarter, longsword + longbow:** the bow is held the same
  in both frames and the same as at idle frame 0: horizontal, limbs fore and aft at the hip
  (the lab's +90° `grip_offset`, see "Sockets and props"). The sword swings a little (11.9°).
- **merfolk swim 0/25/50/75%, side and three-quarter:** the spear is held steady, head forward
  and down at the waist, while the tail beats.

### Animations

Clip tracks are rebound by bone name: `track.path = <path to our Skeleton3D>:<bone>`.
Tracks whose bone is missing are dropped and counted (`report.clips[clip].unbound`).
None were dropped on the pilots.

`Monster.move_clip()` is the locomotion clip: `walk`, else the first of `run`, `move`,
`swim`, `fly`, `hover` that the monster has (`MOVE_CLIPS`). The lab starts on it, and
`lab_screenshot.gd clips=move` shoots it. `Monster.blend_time` (default 0) cross-fades
`play()` and the settle hand-over; the lab sets 0.25 s. `Monster.current_clip` is the
clip `play()` last started; the lab HUD shows "death (last frame)" for a held one-shot.

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

### Shared UAL clips

Bipeds rigged straight onto the Quaternius UAL skeleton (monster-forge `rig_source: "ual"`, 65 bones,
same names everywhere) share their UAL clips: monster-forge `tools/ual_library.py` keeps one GLB per
UAL clip (`_shared/ual/Idle_Loop.glb`, `Walk_Loop`, `Jog_Fwd_Loop`, `Punch_Cross`, `Sword_Attack`,
`Hit_Chest`, `Death01`, the spell chain, three `Zombie_*`; 11 files, 0.9 MB) and the monster keeps
only its own clips (procedural ones: attack_ranged, robe-safe walks, ...) in `anims/`.
`monster.json` `ual_shared` says which clip is which: `clips` {our name: library clip}, plus
`hip_scale`, `pelvis_offset`, `lift_axis`, `fps`, `lift` {clip: metres per frame}.

A library clip keys the UAL bones' local rotations (identical on every UAL biped: monster-forge bakes
them that way) and the pelvis translation `u` in UAL's units; nothing else, so every other bone stays
at this monster's rest (its proportions). The monster's pelvis must be
`hip_scale * u + pelvis_offset + lift(t) * lift_axis`. `Monster._setup_ual_shared()` does this
without copying any clip:
- `Skeleton3D.motion_scale = hip_scale` (Godot multiplies every position track by it). The
  monster's own clips and RESET have their position keys divided by it at load.
- `pelvis_offset` (root-local) moves into the root bone's rest and out of the pelvis rest, so the
  rest pose is unchanged; no shared clip keys the root. Own clips get root / pelvis position tracks
  at the original rests when Godot dropped them (constant at rest). The root bone has no skin
  weights on any UAL biped (checked), so its rest moving shows nothing.
- `lift` (monster-forge raises a body out of the floor on some clips: deaths, some walks, because
  its mesh is thicker than UAL's mannequin) is added to the root bone by `scripts/ual_lift.gd`, a
  `SkeletonModifier3D`, from the current clip's curve, cross-faded from the previous clip's over
  `blend_time`. Modifier poses exist only between the modifier pass and `skeleton_updated`
  (`get_bone_global_pose()` in `_process` is the animated pose without them): checks that skin on
  the CPU add the lift themselves (`check_monsters.gd` `_skinned`).

The library is loaded once (`Monster._ual_libraries`, per library and skeleton path) into an
`AnimationLibrary` added to each UAL biped's player as `"ual"`; the clips it uses are also added to
`""` under the monster's names (the same `Animation` objects), so `play("idle")`, `clips()` and the
lab work unchanged and an own clip of the same name wins. Godot drops glTF channels that stay at
the file's rest, which is UAL's rest here, so dropped rotation channels are put back as constant
tracks. Loop mode comes from `library.json` (`loop`).

`godot --headless -s res://tools/check_ual_shared.gd -- [forge=../monster-forge] [id ...]` loads
each UAL biped twice, as above and with every shared clip read from monster-forge's per-monster
bake (`out/srd-5.2.1/<id>/anims_ual/<clip>.glb`, `Monster.ual_legacy_root`), and compares every
bone's global pose (root excluded) as rendered at 0/25/50/75/100% of each clip and 0.1 s into an
idle -> clip cross-fade. On ape, flesh-golem, skeleton, stone-giant, archmage (own attack_melee,
attack_ranged), mummy (zombie clips), wolf (no shared clips), and priest, oni, storm-giant (own
walk / death / fly / swim): 0.0000-0.0001 m on every clip, ALL PASS. One known difference: 0.1 s into
a cross-fade from a shared clip into an own clip that turns the root bone (fly, swim), the offset
rides the root instead of the pelvis, 0.06 m on the 7.9 m storm giant and 0.005 m on the oni; it is
gone when the fade ends (the check allows 1% of scale_m mid-fade). `check_monsters.gd` on the same ids: ALL PASS, and its WARN list is the same as with the
per-monster clips.

### Paired animations

Two UAL bipeds playing one clip pair together (`scripts/paired_anim.gd`; data format and authoring:
monster-forge docs/anim-reuse.md "Paired animations"). Pilot entry: `grapple`. A sidecar
(`_shared/paired/<entry>.json`) lists variants by size ratio (receiver / initiator `hip_scale`:
`grapple` 0.75-1.18, `grapple_big` 0.42-0.75, `grapple_up` 1.18-2.4), each with one clip per role (the shared UAL clip
format, so each monster plays its clip with its own `hip_scale` and pelvis offset), an alignment
(the receiver's root relative to the initiator's) and contacts (a point on one actor held on a point
of the other: the initiator's palms on the receiver's shoulders, the receiver's palms on the
initiator's forearms; in `grapple_up`, for a receiver up to one size larger, the receiver bends and
presses its palms on the initiator's shoulders and the initiator reaches up and holds its forearms).

```gdscript
const PairedAnim = preload("res://scripts/paired_anim.gd")
var pair := PairedAnim.new()
add_child(pair)
if pair.start("grapple", ogre, bandit):   # initiator, receiver; false + pair.last_error otherwise
    await pair.finished                    # both back in idle (the variant's exit states)
```

`start()` picks the variant, loads `_shared/paired/` into each player as library `"paired"`
(`Monster._ual_library()`), fits the alignment (offset scaled so each contact's arm needs the reach
it had when authored on the sync frame, never closer than the two torso fronts), slides the receiver
onto `pair.aligned` over `warp_frames` (4: walk it there first), starts both clips on the same frame
and advances both `AnimationPlayer`s itself (manual callback mode: lockstep). Every frame it bends
the spine of a role with lean contacts forward when the targets are further than authored (lean;
the initiator in `grapple`, the receiver in `grapple_up`) and solves a
two-bone IK per contact on world-space bone transforms, in contact order, so the receiver's hands
hold the initiator's already-solved forearms (`grapple_up` lists the receiver's contacts first, so
there the initiator's hands follow the receiver's solved forearms); a `PairedPose` `SkeletonModifier3D` per skeleton
writes the rotations. Not `TwoBoneIK3D`: it runs in each skeleton's own deferred update
(`Skeleton3D.advance()` only queues it), so one skeleton cannot follow another's IK'd pose in the
same frame, and it has no lean; this solve is the one monster-forge checks offline, and the two
agree. At the last frame each actor cross-fades into its exit clip. `last_contacts` / `last_lean`
give the solved distances per frame.

`godot --headless -s res://tools/check_paired.gd -- [entry=grapple] [initiator:receiver ...]` steps
each pair frame by frame and measures the contacts on the pose as rendered (after the modifiers),
plus finite bones, feet on the floor and the hand-over to idle. Default pairs, 2026-11-08: tough ->
bandit (similar size) max 0.4 cm, ogre -> bandit (large grabs medium; offset 0.45 m, lean up to
21 deg) max 0.9 cm, tolerance 2.8 / 3.7 cm: ALL PASS, the same numbers as monster-forge's
`tools/paired.py check`. `grapple_up` (2026-11-08): bandit -> ogre (1.82) max 2.8 cm, tough -> ogre
1.3 cm, guard -> troll and priest -> troll (2.04) 0.6 cm; hill-giant -> ogre (`grapple_big`, ratio
0.75, lean 55 deg) 1.7 cm. tough -> hill-giant (2.10) fails by ~50 cm: the hill giant is Huge (two
sizes up), its arms are short and its belly holds the tough 1 m off; callers should refuse grapples
more than one size up anyway. Sync: any UAL biped brings `_shared/paired/` along
(`tools/sync_monsters.py --ids bandit tough ogre guard`).

### LODs

All LOD meshes are skinned to the one LOD0 skeleton with the same `Skin`, so a clip
drives every LOD. Checked by CPU skinning (`check_monsters.gd`, mid-clip): each LOD-k vertex is
matched to its nearest LOD0 vertex whose normal agrees (dot > 0.3, so a tentacle tip resting on
the body is not matched to the body under it) and skinned at its own rest position twice, with its own
influences and with the LOD0 vertex's; p95 of the difference must stay under 0.1 x p95 of LOD0's
displacement + 5 mm. Until 2026-11-08 the check compared the two vertices' displacements, which also
measured the decimation (LOD3 vertices sit up to 7-14 cm off the nearest LOD0 vertex where fingers and
robe folds collapse): bandit's death clip read 8.7 cm on LOD3 with weights that agree to 0.8 cm. That
number is still printed ("geometry"). Screenshots at the same frame show the same pose and texture on
LOD0-3. monster-forge `tools/relod.py check` runs the same comparison on every monster (docs/lods.md
"Rigged LODs").

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
`grip_l` when the rig has them (goblin, harpy, ghost, merfolk, centaur right only), else `hand_r` / `hand_l`.
`attach_prop(prop, socket)` adds a `BoneAttachment3D` (`bone_name = socket`) under the
skeleton, parents the prop to it, and scales it by `prop_scale()`: `rider_height_m / 1.8`
when monster.json has `rider_height_m` (round 9; centaur-trooper 1.8, so its 3.5 m pike stays
3.5 m), else `scale_m / 1.8`. Centauroids and merfolk/naga are measured over the whole body,
so `scale_m` alone over-scales their props (the centaur's pike was 4.7 m). monster-forge's
viewer applies the same rule.

**Real props.** `Monster.load_prop(id)` loads `assets/props/<id>/`:
- **Tree:** `prop_<id>` holds `body`, which holds `model` (the GLTF scene).
- **Bow strings:** bows have two mesh nodes, the stave (`prop`) and a straight string
  (`string`, 8 tris, material `bowstring`), named in `manifest.prop.nodes`, in model.glb and
  every LOD. The loader keeps the string with its own material, adds `string_lod1-3` beside
  it with the same visibility ranges as the stave, and lists them in the prop's
  `string_meshes` meta. `Monster.set_bowstring_visible(prop, on)` hides or shows them, and
  `monster.set_bowstrings_visible(on)` does that for every held prop (`show_bowstring`
  applies to props attached later). Lab key `S`, `lab_screenshot.gd bowstring=0`.
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

Melee weapons and (since props round 2) bows have none. Crossbows, pistols and the shield
have +90° about X.
`Monster.apply_grip_offset` (lab key `G`, `lab_screenshot.gd gripoffset=0`) turns it off
to compare.

**Lab loadout** (`monster_lab.gd loadout_for()`), from `monster.json` `wields` and each
prop's manifest:
- The first prop whose `grip_socket` is `hand_r` goes on the right hand, and the first on
  `hand_l` (bows) on the left.
- A shield takes the left hand only when the record has `shield` and nothing else claimed
  that hand.
- A two-handed prop (`grip: 2`) clears the left hand.
- `loadout_override` (`{"r": id, "l": id}`, `""` = empty hand) replaces this for every
  monster, like the forge viewer's `?prop_r=&prop_l=`; `lab_screenshot.gd prop_r=longsword
  prop_l=none` sets it. Used to test unarmed rigs with grips (harpy) and props no pilot wields.

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
- **Scale by body plan.** `scale_m / 1.8` applies to upright wielders only; `rider_height_m`
  covers centauroids (and merfolk/naga once their overrides set it).

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
| `S` | show / hide bow strings |
| `G` | toggle `grip_offset` on grip sockets (reloads the monster) |
| `W` | swarm units: 12 / 1 (monsters with `swarm_unit`; `lab_screenshot.gd swarm=1`) |

The status line shows the LOD that auto mode draws, the camera distance and the switch
distances.

## Known issues in the current pilots (reported upstream)

- Fixed in round 2: walk clips no longer push geometry below y = 0. The worst is now the
  owlbear at -0.015 m (in round 1 it was -0.19 m).
- Fixed in round 3: every pilot's material now has `metallicFactor` 0, so it renders
  matte. The metallic texture's blue channel is 255 throughout, but the factor zeroes it.
  In round 2 the goblin and harpy were effectively full metal and read almost black
  without an environment.
- Harpy, rounds 1-3 (hand-built rig, retired in round 7): the skeleton was off-centre (root
  at x +0.068, shoulders at +0.26 / -0.125). The right forearm and hand bones (bone_18,
  bone_19) carried no vertex with weight > 0.5. The right arm was skinned to the wing chain
  (bone_11, bone_12), so `hand_r` did not follow the visible right hand, and the `hand_*`
  sockets sat 8-9 cm off the mesh. The round 7 rig has 32 bones with `wing_*` chains, and
  all four hand and grip sockets are 1.8-3.1 cm from the skin. The arms are still not
  mirrored: `hand_r` is at x +0.48 and `hand_l` at -0.37, the elbows at +0.37 / -0.25.
- Round 7, reported upstream: the harpy's hanging wing tips tear next to the legs in fly
  (stretched sideways at 0%, a strip to the floor at 25-50%) and in walk. Its sword cut now
  raises the arm above the head and pulls a flat sheet off the right armpit (25-50%). The
  idle -> attack_melee frame-0 jump is 0.167 m (round 5 0.014). Walk dips to -0.023 m.
  Round 8 re-checked: the fly blades, the armpit sheet and the walk strip are gone, the
  frame-0 jumps are 0, and walk's lowest point is -0.010 m.
- Round 8, reported upstream: the dragon's new in-phase idle tail sway moves the curled
  tail tip 1.66 m within the idle, so a mid-idle switch to walk pops 1.5 m (0.27 m
  cross-faded; round 6 0.96 / 0.10). Round 9 re-checked: the idle wanders 0.31 m, the worst
  mid-idle jump into a one-shot is 0.31-0.32 m and into walk 0.62 m, and the probe is
  0.58 / 0.084 m. The eagle's lunge is a small peck. Round 6's eagle
  (neck gap, 1.75 m idle -> fly pop, 5.3 m size) and the merfolk throw are fixed.
- LOD files name their material `Material_0.001` rather than LOD0's `Material_0`
  (`docs/lods.md` says same name). Harmless here, because the material is overridden.
- Round 4 (body-plan pilots), reported upstream in monster-forge `docs/TODO.md` E. Round 5
  re-checked them: the ghost sheet, the merfolk hand, the fungus root clump and the swarm
  squash are fixed upstream; the idle -> move pop is not (see "Round 5"):
  - The ghost's robe hem stays upright as a vertical sheet at the end of death.
  - The merfolk has no right arm socket, so its spear is never shown, and its
    attack_melee barely moves.
  - The swarm mesh is a 1.44 m column of rats, and death squashes them flat.
  - The violet fungus topples with its root clump.
  - The octopus, merfolk and eagle change height between idle and swim/fly by design.
    The game cross-fades (`blend_time`) or adds a take-off.
- Round 5, reported upstream: the eagle, octopus and merfolk now idle in the air but their
  attack, hit and death clips start on the floor (0.19-1.03 m jump on every settle to idle);
  the harpy's left `grip_l` is 11 cm off the skin; the merfolk's spear attack is a sword
  cut; the bow string passes through the goblin's forearm in attack_ranged; the whip is a
  rigid mesh. Round 6 re-checked them: the eagle, octopus and merfolk one-shots now start at
  the idle height, and the merfolk thrusts with the spear held upright at idle.
- Round 6, reported upstream: the centaur's tail has no bones and swings with the near hind
  leg; the reference's arrow-shaft stick shreds in the thrust; there is no left arm, and its
  two-handed pike gets the upright-body prop scale (1.333, 4.7 m long); death dips to
  -0.033 m. Round 10: the tail has its own chain (`tail_00..05`, 4 bones since round 11) and hangs and
  swings behind the hind legs in the walk. It does not kick. The pike is 3.5 m since round
  9. The stick fan and the 8-9 cm grip in the thrust remain. The eagle's idle -> fly instant switch is the largest pop of all (1.75 m), and
  its attack wind-up shows a gap at the neck. The merfolk's attack_ranged still starts from
  the raised rest arm (0.61 m jump).
- Round 10, reported upstream: the centaur's death starts 0.119 m off the idle (the idle's
  tail lift against the death's tail at rest). Its tail end sits at -0.030 m in idle, walk,
  attack and hit, which trips the check's -0.03 WARN by 0.1 mm. In death, both tails stay
  level with the rolled body instead of lying on the floor (the centaur's is 0.87 m up). The
  wolf's walk at 75% shows a dark fold at the tail end beside the hind hock (back view).
  Round 11 re-checked them (see "Round 11"): the centaur's death starts at 0, its tail end
  sits at -0.024 m (no WARN), and the wolf's fold is down to a sliver. The tails now droop in
  death but still do not reach the floor (lowest tail vertex wolf 0.13 m, owlbear 0.39,
  centaur 0.65; open upstream, it needs softer tail weights at the base).
- Round 11, reported upstream: the walk's pike is level now (tip y 1.13-1.16 m, was
  0.40-1.91), but its butt end runs back into the horse's chest. The owlbear's fan tail shows
  a thin light sliver at its edge at walk 50% (back view) and a dark rim at its base in the
  lying pose.
- With `--verbose`, Godot warns "Buffer view byte stride should be declared for vertex
  attributes". There are no warnings without `--verbose`.
