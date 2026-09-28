# Human R6 sprint loop for the R6 IK/FK Blender rig (v2.22) - a normal person sprinting, a bit heavy.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a looping, in-place "Sprint_Human" action on __PrimaryArmature:
#   upright-ish running lean, full opposite arm swing, knees driving, a short flight phase,
#   and a solid landing on each step so it still has some weight.
# Arms are FK (rotated), legs are IK (foot targets moved).
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
ACTION_NAME = "Sprint_Human"
HIP_BONE = "LowerTorso-FK"
CYCLE = 0.54  # seconds for a full stride (right step + left step). Higher = slower, heavier.

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
ARM_SWING = 1.3  # how much the arms swing (1 = full human-like swing, 0 = arms stay still)
ARM_DROP = 0.18  # studs the arms sit lower on the body (like grabbing them and pressing G, then moving down)
ARM_SLIDE = 0.35  # studs the whole arm slides forward/back with the swing (at a 60 degree swing)
REACH = 1.05 * LEG      # a touch over LEG: a planted leg reads as straight, not broken
MIN_REACH = 0.5 * LEG   # never pull the foot closer to the hip than this, or the knee folds and the IK flips


def foot(hip, y, z):
    """Foot target (y, z) in studs, kept between MIN_REACH and REACH from the hip."""
    hy, hz = hip[1], LEG + hip[2]
    dz = min(abs(z - hz), REACH)
    max_dy = math.sqrt(REACH ** 2 - dz ** 2)
    y = hy + max(-max_dy, min(max_dy, y - hy))
    # Too close (a knee pulled right up under the hip): lower the foot until the leg has room.
    dy = y - hy
    if dy * dy + (z - hz) ** 2 < MIN_REACH ** 2:
        z = hz - math.sqrt(max(MIN_REACH ** 2 - dy * dy, 0))
    return S(0, y, max(z, 0))


def P(hip, hips, chest, arms, rfoot, lfoot):
    """One pose of the stride. The head is never keyed: it stays level with the body.
    hip:   (x, y, z) body offset in studs      hips:  (lean, twist, tilt) of LowerTorso-FK
    chest: (bend, twist) extra on Torso_FK
    arms:  ((right pitch, roll, twist, cross), (left ...))   rfoot/lfoot: (y, z) in studs
           pitch - = forward; roll + = out for the right arm, - = out for the left;
           twist turns the arm on its own length (+ turns the right arm inward);
           cross swings the (forward) arm in across the chest (+ = right arm inward)
    """
    def arm(a):
        return [(YAW, a[2]), (ROLL, a[1]), (PITCH, a[0] * ARM_SWING), (YAW, a[3])]
    return {
        HIP_BONE:      ([(PITCH, hips[0]), (YAW, hips[1]), (ROLL, hips[2])], S(*hip)),
        "Torso_FK":    ([(PITCH, chest[0]), (YAW, chest[1])], None),
        # The shoulder travels with the swing: forward arm slides forward, back arm back.
        "RightArm_FK": (arm(arms[0]), S(0, arms[0][0] / 60 * ARM_SLIDE, -ARM_DROP)),
        "LeftArm_FK":  (arm(arms[1]), S(0, arms[1][0] / 60 * ARM_SLIDE, -ARM_DROP)),
        "RightLeg-IK": ([], foot(hip, *rfoot)),
        "LeftLeg-IK":  ([], foot(hip, *lfoot)),
    }


# --- Poses for the RIGHT-foot step (the left step is mirrored automatically) ---
# The main forward lean is on LowerTorso-FK; Torso_FK adds chest bend/twist on top.
# Hips twist toward the forward leg, chest twists the other way.
# The forward arm swings in across the chest and turns inward on the way
# forward; as soon as it starts back it straightens out, so the back swing is
# straight. The back arm stays close to the side. Hips and chest twist hard against each other.
CONTACT = P(  # right foot lands out in front, left arm forward and across
    hip=(-0.06, -0.05, -0.32), hips=(22, 10, 1), chest=(4, -14),
    arms=((50, 6, 0, 0), (-60, -4, -28, -32)), rfoot=(-1.6, 0), lfoot=(1.5, 0.5))

IMPACT = P(  # weight lands: body dips, chest crunches, hips drop to the landing side
    hip=(-0.12, 0, -0.42), hips=(26, 7, -5), chest=(8, -10),
    arms=((42, 7, 0, 0), (-48, -2, -8, -10)), rfoot=(-0.8, 0), lfoot=(0.7, 0.9))

PASS = P(  # planted foot under the body, other knee drives up and through
    hip=(-0.08, -0.05, -0.3), hips=(23, 0, -3), chest=(5, 0),
    arms=((0, 6, 0, 0), (-5, -6, 0, 0)), rfoot=(0.3, 0), lfoot=(-0.65, 0.95))

PUSH = P(  # drive off the back foot: both feet leave the ground briefly
    hip=(-0.03, -0.1, 0.0), hips=(21, -8, 0), chest=(4, 12),
    arms=((-55, 4, 26, 30), (45, -6, 0, 0)), rfoot=(1.55, 0.3), lfoot=(-1.6, 0.45))


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

# Arms trail the body slightly so they swing with weight instead of snapping.
LAG = {"RightArm_FK": 0.04, "LeftArm_FK": 0.04}


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
