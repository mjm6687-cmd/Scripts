# Heavy roar for the R6 IK/FK Blender rig (v2.22) - same style as walk.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a one-shot, in-place "Roar" action on __PrimaryArmature:
#   inhale and rear back -> step in and thrust forward -> roar with a trembling hold
#   and a slow head sweep -> exhale and settle back to standing.
# Arms are FK (rotated), legs are IK (foot targets moved).
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
ACTION_NAME = "Roar"
HIP_BONE = "LowerTorso-FK"
HEAD_MOVES = True  # False = never key the head (it just rides on the body like in the walks)
SPEED = 1.0        # higher = faster roar, lower = slower and heavier

# Which way the character faces in this rig: -1 = faces -Y, 1 = faces +Y.
FACING = 1

# Armature-space axes (flipped automatically by FACING).
PITCH = (-FACING, 0, 0)  # + leans torso/head forward, - swings arms forward
YAW = (0, 0, 1)          # - turns to the character's right
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


ARM_DROP = 0.15  # studs the arms sit lower on the body (matches the walks)
LEG = 2.0
REACH = 1.05 * LEG


def foot(hip, x, y, z):
    """Foot offset in studs, shortened if it's out of reach of the hip."""
    hx, hy, hz = hip[0], hip[1], LEG + hip[2]
    dz = min(abs(z - hz), REACH)
    max_d = math.sqrt(REACH ** 2 - dz ** 2)
    dx, dy = x - hx, y - hy
    d = math.hypot(dx, dy)
    if d > max_d:
        x, y = hx + dx * max_d / d, hy + dy * max_d / d
    return S(x, y, max(z, 0))


def P(hip=(0, 0, -0.05), lean=6, twist=0, chest=0, chest_twist=0,
      head=None, head_yaw=0, arms=(0, 10), rfoot=(0, 0, 0), lfoot=(0, 0, 0)):
    """One pose.
    hip: body offset (x, y, z) studs     lean: hips forward lean (LowerTorso-FK)
    chest: extra chest bend (Torso_FK), negative = puffed back
    head: where the head points in the world: 0 = level, negative = looking up
          (None = leave it level with the body, same as the walks)
    arms: (pitch, spread) for both arms: + pitch = back, + spread = out to the sides
    """
    head_rel = 0 if head is None else head - lean - chest  # undo the body lean
    pose = {
        HIP_BONE:      ([(PITCH, lean), (YAW, twist)], S(*hip)),
        "Torso_FK":    ([(PITCH, chest), (YAW, chest_twist)], None),
        "RightArm_FK": ([(PITCH, arms[0]), (ROLL, arms[1])], S(0, 0, -ARM_DROP)),
        "LeftArm_FK":  ([(PITCH, arms[0]), (ROLL, -arms[1])], S(0, 0, -ARM_DROP)),
        "RightLeg-IK": ([], foot(hip, *rfoot)),
        "LeftLeg-IK":  ([], foot(hip, *lfoot)),
    }
    if HEAD_MOVES:
        pose["Head"] = ([(PITCH, head_rel), (YAW, head_yaw)], None)
    return pose


# --- The roar ------------------------------------------------------------------
KEYS = [
    (0.00, P()),                                                        # standing, same as the walk
    (0.45, P(hip=(0, 0.05, 0.05), lean=0, chest=-8, head=8,             # inhale: chest swells, chin tucks
             arms=(15, 16))),
    (0.75, P(hip=(0, 0.10, 0.08), lean=-5, chest=-12, head=-20,         # rear back, right foot lifts
             arms=(20, 26), rfoot=(0, -0.25, 0.3))),
    (0.95, P(hip=(0, -0.15, -0.45), lean=24, twist=5, chest=10,         # slam forward: step in, arms fling back
             chest_twist=-3, head=-12, arms=(38, 40),
             rfoot=(0, -0.55, 0), lfoot=(0, 0.1, 0))),
    (1.05, P(hip=(0, -0.17, -0.52), lean=27, twist=5, chest=12,         # overshoot
             chest_twist=-3, head=-15, arms=(42, 44),
             rfoot=(0, -0.55, 0), lfoot=(0, 0.1, 0))),
]

# Roar hold: the whole body trembles and the head sweeps slowly side to side,
# both fading out as the breath runs out.
t, i = 1.12, 0
while t < 2.35:
    fade = 1 - 0.6 * (t - 1.12) / 1.23
    shake = (1 if i % 2 else -1) * fade
    KEYS.append((t, P(hip=(0, -0.16, -0.5 + 0.02 * shake), lean=25 + 1.5 * shake, twist=5,
                      chest=11 + 1.5 * shake, chest_twist=-3, head=-14 + 3 * shake,
                      head_yaw=7 * fade * math.sin(2 * math.pi * (t - 1.12) / 0.9),
                      arms=(40 + 2 * shake, 42), rfoot=(0, -0.55, 0), lfoot=(0, 0.1, 0))))
    t, i = t + 0.07, i + 1

KEYS += [
    (2.55, P(hip=(0, -0.05, -0.2), lean=14, chest=4, head=10,           # exhale: head drops, right foot steps back
             arms=(5, 12), rfoot=(0, -0.3, 0.25))),
    (2.80, P(hip=(0, 0, -0.02), lean=7, head=2, arms=(0, 10))),         # settle
    (3.10, P()),                                                        # back to standing
]

# Arms and head land a moment after the body so the motion has weight.
LAG = {"Head": 0.04, "RightArm_FK": 0.05, "LeftArm_FK": 0.05}


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


old = bpy.data.actions.get(ACTION_NAME)
if old:
    bpy.data.actions.remove(old)
action = bpy.data.actions.new(ACTION_NAME)
action.use_fake_user = True
rig.animation_data.action = action
for pb in rig.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)

last = len(KEYS) - 1
for n, (t, pose) in enumerate(KEYS):
    for bone_name, (rots, loc) in pose.items():
        lag = LAG.get(bone_name, 0) if 0 < n < last else 0  # first/last keys stay lined up
        key(bone_name, round((t + lag) / SPEED * FPS), rots, loc)

scene.frame_start = 0
scene.frame_end = round(KEYS[-1][0] / SPEED * FPS)
scene.frame_set(0)
print("Created action:", ACTION_NAME, "| STUD =", STUD)
