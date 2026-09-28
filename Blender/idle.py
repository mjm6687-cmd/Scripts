# Heavy idle loop for the R6 IK/FK Blender rig (v2.22) - matches the roars' standing stance.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a looping, in-place "Idle" action on __PrimaryArmature:
#   two slow, heavy breaths per loop while the weight drifts from one leg to the other,
#   arms hanging and swaying slightly, head making a small slow look around.
# Starts and ends exactly on the roars' stance, so roars blend in and out of it.
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
HIP_BONE = "LowerTorso-FK"
HEAD_MOVES = True  # False = never key the head (it just rides on the body like in the walks)
CYCLE = 4.0        # seconds per loop (two slow breaths)
HEAD_MAX = 18      # most the head ever turns or tilts, in degrees

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


def P(hip=(0, 0, -0.2), lean=8, twist=0, tilt=0, chest=0, chest_twist=0,
      head=0, head_yaw=0, arms=(0, 10), rfoot=(0, 0, 0), lfoot=(0, 0, 0)):
    """One pose.
    hip: body offset (x, y, z) studs; z stays well below 0 so the knees stay bent
    lean: hips forward lean (LowerTorso-FK)     tilt: hips side tilt, + = toward the character's left     chest: extra chest bend (Torso_FK), negative = puffed back
    head: head nod on top of the body, negative = looking up   head_yaw: head turn
    arms: (pitch, spread) for both arms: + pitch = back, + spread = out to the sides
    """
    head = max(-HEAD_MAX, min(HEAD_MAX, head))
    head_yaw = max(-HEAD_MAX, min(HEAD_MAX, head_yaw))
    pose = {
        HIP_BONE:      ([(PITCH, lean), (YAW, twist), (ROLL, tilt)], S(*hip)),
        "Torso_FK":    ([(PITCH, chest), (YAW, chest_twist)], None),
        "RightArm_FK": ([(PITCH, arms[0]), (ROLL, arms[1])], S(0, 0, -ARM_DROP)),
        "LeftArm_FK":  ([(PITCH, arms[0]), (ROLL, -arms[1])], S(0, 0, -ARM_DROP)),
        "RightLeg-IK": ([], foot(hip, *rfoot)),
        "LeftLeg-IK":  ([], foot(hip, *lfoot)),
    }
    if HEAD_MOVES:
        pose["Head"] = ([(PITCH, head), (YAW, head_yaw)], None)
    return pose



# --- The idle ------------------------------------------------------------------
# Breath in: chest swells, body rises a touch. Breath out: body sinks, leans in a bit.
# The weight shifts over the right leg on the first breath and the left leg on the second.
KEYS = [
    (0.00, P()),                                                                   # roar stance
    (0.55, P(hip=(-0.04, 0, -0.17), lean=7, tilt=-1, chest=-3, head=-2,            # breathe in, weight right
             head_yaw=-4, arms=(-1, 11))),
    (1.10, P(hip=(-0.06, 0, -0.21), lean=8, tilt=-1.5, chest=-1, head=0,           # hold
             head_yaw=-5, arms=(0, 11))),
    (1.75, P(hip=(-0.03, 0, -0.24), lean=9.5, tilt=-0.5, chest=1.5, head=2,        # breathe out, sink
             head_yaw=-2, arms=(2, 10))),
    (2.00, P()),                                                                   # back through the stance
    (2.55, P(hip=(0.04, 0, -0.17), lean=7, tilt=1, chest=-3, head=-2,              # breathe in, weight left
             head_yaw=4, arms=(-1, 11))),
    (3.10, P(hip=(0.06, 0, -0.21), lean=8, tilt=1.5, chest=-1, head=0,             # hold
             head_yaw=5, arms=(0, 11))),
    (3.75, P(hip=(0.03, 0, -0.24), lean=9.5, tilt=0.5, chest=1.5, head=2,          # breathe out, sink
             head_yaw=2, arms=(2, 10))),
    (4.00, P()),
]

# Arms and head drift a moment behind the body.
LAG = {"Head": 0.15, "RightArm_FK": 0.12, "LeftArm_FK": 0.12}


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


old = bpy.data.actions.get("Idle")
if old:
    bpy.data.actions.remove(old)
action = bpy.data.actions.new("Idle")
action.use_fake_user = True
rig.animation_data.action = action
for pb in rig.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)

for t, pose in KEYS:
    for bone_name, (rots, loc) in pose.items():
        frame = round((t / 4.0 * CYCLE + LAG.get(bone_name, 0)) * FPS)
        key(bone_name, frame, rots, loc)

for fc in all_fcurves(action):
    fc.modifiers.new('CYCLES')  # seamless loop

scene.frame_start = 0
scene.frame_end = round(CYCLE * FPS) - 1  # last frame = first frame, so skip it when exporting
scene.frame_set(0)
print("Created action: Idle | STUD =", STUD)
