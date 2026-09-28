# Heavy sprint loop for the R6 IK/FK Blender rig (v2.22) - big, heavy creature.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a looping, in-place "Sprint_Heavy" action on __PrimaryArmature.
# Arms are FK (rotated), legs are IK (foot targets moved).
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
ACTION_NAME = "Sprint_Heavy"
HIP_BONE = "LowerTorso-FK"
CYCLE = 0.8  # seconds for a full stride (right step + left step). Higher = slower, heavier.

# Which way the character faces in this rig: -1 = faces -Y, 1 = faces +Y.
# If the run goes backwards, flip this number.
FACING = 1

# Armature-space axes (flipped automatically by FACING).
PITCH = (-FACING, 0, 0)  # + leans torso/head forward, - swings arms forward
YAW = (0, 0, 1)          # - turns the chest to the character's right
ROLL = (0, -FACING, 0)   # + moves right arm outward / tilts torso left

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
    """Offset in studs relative to the character. x<0 is its right, y<0 forward, z>0 up."""
    return (-x * STUD * FACING, -y * STUD * FACING, z * STUD)


# --- Poses for the RIGHT-foot step (the left step is mirrored automatically) ---
# Each pose: bone -> (rotations [(axis, degrees)], location offset in studs or None)
CONTACT = {  # right heel hits the ground way out in front
    HIP_BONE:      ([], S(-0.05, 0, -0.2)),
    "Torso_FK":    ([(PITCH, 22), (YAW, -8)], None),
    "Head":        ([(PITCH, -17)], None),
    "RightArm_FK": ([(PITCH, 35), (ROLL, 10)], None),
    "LeftArm_FK":  ([(PITCH, -45), (ROLL, -10)], None),
    "RightLeg-IK": ([], S(0, -1.3, 0)),
    "LeftLeg-IK":  ([], S(0, 1.2, 0.5)),
}

IMPACT = {  # the weight lands: body sinks hard, chest crunches, head bobs
    HIP_BONE:      ([], S(-0.12, 0.05, -0.45)),
    "Torso_FK":    ([(PITCH, 26), (YAW, -6), (ROLL, -3)], None),
    "Head":        ([(PITCH, -13)], None),
    "RightArm_FK": ([(PITCH, 30), (ROLL, 12)], None),
    "LeftArm_FK":  ([(PITCH, -38), (ROLL, -12)], None),
    "RightLeg-IK": ([], S(0, -0.7, 0)),
    "LeftLeg-IK":  ([], S(0, 0.7, 1.0)),
}

PASS = {  # planted foot under the body, other knee drives through high
    HIP_BONE:      ([], S(-0.08, 0, -0.3)),
    "Torso_FK":    ([(PITCH, 22), (ROLL, -2)], None),
    "Head":        ([(PITCH, -16)], None),
    "RightArm_FK": ([(PITCH, 0), (ROLL, 10)], None),
    "LeftArm_FK":  ([(PITCH, -5), (ROLL, -10)], None),
    "RightLeg-IK": ([], S(0, 0.1, 0)),
    "LeftLeg-IK":  ([], S(0, -0.4, 1.2)),
}

PUSH = {  # shove off the back foot, body at its highest
    HIP_BONE:      ([], S(-0.02, -0.05, 0.0)),
    "Torso_FK":    ([(PITCH, 18), (YAW, 5)], None),
    "Head":        ([(PITCH, -19)], None),
    "RightArm_FK": ([(PITCH, -35), (ROLL, 10)], None),
    "LeftArm_FK":  ([(PITCH, 30), (ROLL, -10)], None),
    "RightLeg-IK": ([], S(0, 1.0, 0.1)),
    "LeftLeg-IK":  ([], S(0, -1.2, 0.5)),
}


def mirror(pose):
    """Swap left/right so the same step works for the other foot."""
    out = {}
    for name, (rots, loc) in pose.items():
        if "Right" in name:
            name = name.replace("Right", "Left")
        elif "Left" in name:
            name = name.replace("Left", "Right")
        rots = [(axis, deg if axis == PITCH else -deg) for axis, deg in rots]
        if loc:
            loc = (-loc[0], loc[1], loc[2])
        out[name] = (rots, loc)
    return out


# (fraction of the cycle, pose)
KEYS = [
    (0.00, CONTACT), (0.12, IMPACT), (0.25, PASS), (0.38, PUSH),
    (0.50, mirror(CONTACT)), (0.62, mirror(IMPACT)), (0.75, mirror(PASS)), (0.88, mirror(PUSH)),
    (1.00, CONTACT),
]

# Arms and head trail the body slightly so they swing with weight instead of snapping.
LAG = {"Head": 0.05, "RightArm_FK": 0.04, "LeftArm_FK": 0.04}


def key(bone_name, frame, rots, loc):
    pb = rig.pose.bones[bone_name]
    rest = pb.bone.matrix_local.to_quaternion()
    r = Quaternion()
    for axis, deg in rots:
        r = Quaternion(Vector(axis), math.radians(deg)) @ r
    pb.rotation_mode = 'QUATERNION'
    pb.rotation_quaternion = rest.inverted() @ r @ rest
    pb.keyframe_insert("rotation_quaternion", frame=frame)
    if loc is not None:
        pb.location = rest.inverted() @ Vector(loc)
        pb.keyframe_insert("location", frame=frame)


def all_fcurves(act):
    layers = getattr(act, "layers", None)
    if layers:
        for layer in layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    yield from bag.fcurves
    else:
        yield from act.fcurves


old = bpy.data.actions.get(ACTION_NAME)
if old:
    bpy.data.actions.remove(old)
action = bpy.data.actions.new(ACTION_NAME)
action.use_fake_user = True
rig.animation_data.action = action
for pb in rig.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)

for t, pose in KEYS:
    for bone_name, (rots, loc) in pose.items():
        frame = round((t + LAG.get(bone_name, 0)) * CYCLE * FPS)
        key(bone_name, frame, rots, loc)

for fc in all_fcurves(action):
    fc.modifiers.new('CYCLES')  # seamless loop

scene.frame_start = 0
scene.frame_end = round(CYCLE * FPS) - 1  # last frame = first frame, so skip it when exporting
scene.frame_set(0)
print("Created action:", ACTION_NAME, "| STUD =", STUD)
