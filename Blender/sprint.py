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


# Leg reach limit (studs). Feet are pulled in so the IK never over-stretches.
LEG = 2.0
REACH = 1.05 * LEG  # a touch over LEG: a planted leg reads as straight, not broken


def foot(hip, y, z):
    """Foot target (y, z) in studs, shortened front-to-back if it's out of reach."""
    hy, hz = hip[1], LEG + hip[2]
    dz = min(abs(z - hz), REACH)
    max_dy = math.sqrt(REACH ** 2 - dz ** 2)
    y = hy + max(-max_dy, min(max_dy, y - hy))
    return S(0, y, max(z, 0))


def P(hip, hips, chest, head, arms, rfoot, lfoot):
    """One pose of the stride.
    hip:   (x, y, z) body offset in studs      hips:  (lean, twist, tilt) of LowerTorso-FK
    chest: (bend, twist) extra on Torso_FK       head:  pitch (counters the lean to look ahead)
    arms:  ((right pitch, roll), (left pitch, roll))   rfoot/lfoot: (y, z) in studs
    """
    return {
        HIP_BONE:      ([(PITCH, hips[0]), (YAW, hips[1]), (ROLL, hips[2])], S(*hip)),
        "Torso_FK":    ([(PITCH, chest[0]), (YAW, chest[1])], None),
        "Head":        ([(PITCH, head)], None),
        "RightArm_FK": ([(PITCH, arms[0][0]), (ROLL, arms[0][1])], None),
        "LeftArm_FK":  ([(PITCH, arms[1][0]), (ROLL, arms[1][1])], None),
        "RightLeg-IK": ([], foot(hip, *rfoot)),
        "LeftLeg-IK":  ([], foot(hip, *lfoot)),
    }


# --- Poses for the RIGHT-foot step (the left step is mirrored automatically) ---
# The main forward lean is on LowerTorso-FK; Torso_FK adds chest bend/twist on top.
# Hips twist toward the forward leg, chest twists the other way.
CONTACT = P(  # right foot reaches out in front and hits the ground
    hip=(-0.05, 0, -0.12), hips=(18, 6, 0), chest=(0, -14), head=-18,
    arms=((35, 10), (-45, -10)), rfoot=(-1.0, 0), lfoot=(0.9, 0.4))

IMPACT = P(  # the weight lands: body sinks hard, chest crunches, hips tilt, head bobs
    hip=(-0.12, 0.05, -0.3), hips=(24, 4, -4), chest=(4, -10), head=-24,
    arms=((30, 12), (-38, -12)), rfoot=(-0.55, 0), lfoot=(0.55, 0.75))

PASS = P(  # planted foot under the body, other knee drives through
    hip=(-0.08, 0, -0.18), hips=(20, 0, -3), chest=(2, 0), head=-21,
    arms=((0, 10), (-5, -10)), rfoot=(0.1, 0), lfoot=(-0.3, 0.9))

PUSH = P(  # shove off the back foot, body rises and straightens a bit
    hip=(-0.02, -0.05, 0.0), hips=(15, -4, 0), chest=(0, 8), head=-15,
    arms=((-35, 10), (30, -10)), rfoot=(0.8, 0.05), lfoot=(-0.95, 0.45))


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
