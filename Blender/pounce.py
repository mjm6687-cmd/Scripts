# Pounce animation set for the R6 IK/FK Blender rig (v2.22).
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates 3 in-place actions on __PrimaryArmature that chain together:
#   Pounce_Crouch - sink down and hold (wind-up)
#   Pounce_Start  - explosive push-off
#   Pounce_Lunge  - stretched out mid-air, holds at the end
# Arms are FK (rotated), legs are IK (foot targets moved).
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
HIP_BONE = "LowerTorso-FK"  # moves the body; swap to "PrimaryTorso_Positioner" if the feet get dragged along

# Armature-space axes: the character faces +Y in this rig.
PITCH = (-1, 0, 0)  # + leans torso/head forward, - swings arms forward
ROLL = (0, -1, 0)   # + moves right arm outward, - moves left arm outward

rig = bpy.data.objects[RIG_NAME]
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='POSE')
rig.animation_data_create()

scene = bpy.context.scene
FPS = scene.render.fps / scene.render.fps_base

# 1 "stud" in this rig's units: the neck sits about 4 studs above the feet on R6.
bones = rig.data.bones
STUD = (bones["Head"].head_local.z - bones["LeftLeg-IK"].head_local.z) / 4 or 1.0


def S(x, y, z):
    """Offset in studs relative to the character. y<0 is forward, z>0 is up."""
    return (-x * STUD, -y * STUD, z * STUD)  # flipped because the rig faces +Y


# Each pose: bone -> (rotations [(axis, degrees)], location offset in studs or None)
REST = {}

CROUCH = {
    HIP_BONE:      ([], S(0, 0.2, -0.7)),                 # drop and sit back
    "Torso_FK":    ([(PITCH, 35)], None),                 # lean in
    "Head":        ([(PITCH, -30)], None),                # eyes stay on the target
    "RightArm_FK": ([(PITCH, 30), (ROLL, 10)], None),     # arms swept back, loaded
    "LeftArm_FK":  ([(PITCH, 30), (ROLL, -10)], None),
    "RightLeg-IK": ([], S(0, -0.5, 0)),                   # front foot
    "LeftLeg-IK":  ([], S(0, 0.7, 0)),                    # back foot
}

# Slightly deeper version of the crouch so the hold isn't dead still
CROUCH_DEEP = dict(CROUCH)
CROUCH_DEEP[HIP_BONE] = ([], S(0, 0.25, -0.8))
CROUCH_DEEP["Torso_FK"] = ([(PITCH, 38)], None)

START = {
    HIP_BONE:      ([], S(0, -0.2, 0.2)),                 # body springs up and forward
    "Torso_FK":    ([(PITCH, 20)], None),
    "Head":        ([(PITCH, -15)], None),
    "RightArm_FK": ([(PITCH, -70), (ROLL, 5)], None),     # arms whip forward
    "LeftArm_FK":  ([(PITCH, -70), (ROLL, -5)], None),
    "RightLeg-IK": ([], S(0, -0.3, 0.3)),                 # front foot leaves the ground
    "LeftLeg-IK":  ([], S(0, 1.0, 0.1)),                  # back foot pushes off
}

LUNGE = {
    HIP_BONE:      ([], S(0, 0, 0.4)),
    "Torso_FK":    ([(PITCH, 70)], None),                 # body nearly horizontal
    "Head":        ([(PITCH, -60)], None),                # looking ahead
    "RightArm_FK": ([(PITCH, -160), (ROLL, 12)], None),   # reaching out in front, claws open
    "LeftArm_FK":  ([(PITCH, -160), (ROLL, -12)], None),
    "RightLeg-IK": ([], S(0, 1.2, 0.8)),                  # legs trail behind
    "LeftLeg-IK":  ([], S(0, 1.8, 0.5)),
}

ALL_BONES = sorted({b for pose in (CROUCH, START, LUNGE) for b in pose})


def apply_pose(pose, frame):
    for name in ALL_BONES:
        pb = rig.pose.bones[name]
        rots, loc = pose.get(name, ([], None))
        rest = pb.bone.matrix_local.to_quaternion()
        r = Quaternion()
        for axis, deg in rots:
            r = Quaternion(Vector(axis), math.radians(deg)) @ r
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = rest.inverted() @ r @ rest
        pb.location = rest.inverted() @ Vector(loc or (0, 0, 0))
        pb.keyframe_insert("rotation_quaternion", frame=frame)
        pb.keyframe_insert("location", frame=frame)


def make_action(name, keys):
    """keys: list of (seconds, pose)."""
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True  # keep it saved even when not assigned
    rig.animation_data.action = action
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
    for seconds, pose in keys:
        apply_pose(pose, round(seconds * FPS))
    print("Created action:", name)
    return action


make_action("Pounce_Crouch", [
    (0.00, REST),
    (0.35, CROUCH),        # sink down
    (0.70, CROUCH_DEEP),   # settle / tense
    (1.00, CROUCH),        # end on the crouch pose (Studio script holds it here)
])

make_action("Pounce_Start", [
    (0.00, CROUCH),
    (0.05, CROUCH_DEEP),   # tiny last-second dip
    (0.20, START),         # explode
])

make_action("Pounce_Lunge", [
    (0.00, START),
    (0.20, LUNGE),         # stretch out
    (0.50, LUNGE),         # hold (Studio script freezes here until landing)
])

rig.animation_data.action = bpy.data.actions["Pounce_Crouch"]
scene.frame_start = 0
scene.frame_end = round(1.0 * FPS)
scene.frame_set(0)
print("STUD =", STUD)
