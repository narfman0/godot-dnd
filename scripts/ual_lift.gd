## Floor lift for shared UAL clips (docs/monsters.md "Shared UAL clips"). monster-forge raises
## a monster's body out of the floor on some clips (deaths, some walks: its mesh is thicker
## than UAL's mannequin); a shared clip cannot carry that, so monster.json ual_shared.lift has
## the per-frame curve and this modifier adds it to the root bone after the AnimationPlayer
## has posed the skeleton. Created by monster.gd for monsters with lift curves.
extends SkeletonModifier3D

var monster: Node3D   ## scripts/monster.gd: ual_lift_now() reads its clip and time
var bone := -1        ## the root bone
var axis := Vector3.UP   ## skeleton space


func _process_modification_with_delta(_delta: float) -> void:
	if monster == null or bone < 0:
		return
	var h: float = monster.ual_lift_now()
	if h == 0.0:
		return
	var sk := get_skeleton()
	sk.set_bone_pose_position(bone, sk.get_bone_pose_position(bone) + axis * h)
