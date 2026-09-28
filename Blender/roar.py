# Heavy roars for the R6 IK/FK Blender rig (v2.22) - same style as walk.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates three one-shot, in-place actions on __PrimaryArmature:
#   Roar_Broadcast  (3.1 s) - big announcing roar: rears up, stomps, head raised and sweeping
#   Roar_Passive    (1.7 s) - low-key warning roar: no step, small lean, gentle rumble
#   Roar_Aggressive (1.9 s) - fast threat: coils, lunges a step in, claws forward, violent shake
# Arms are FK (rotated), legs are IK (foot targets moved). Knees stay bent the whole time.
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
HIP_BONE = "LowerTorso-FK"
HEAD_MOVES = True  # False = never key the head (it just rides on the body like in the walks)
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


def P(hip=(0, 0, -0.2), lean=8, twist=0, chest=0, chest_twist=0,
      head=0, head_yaw=0, arms=(0, 10), rfoot=(0, 0, 0), lfoot=(0, 0, 0)):
    """One pose.
    hip: body offset (x, y, z) studs; z stays well below 0 so the knees stay bent
    lean: hips forward lean (LowerTorso-FK)     chest: extra chest bend (Torso_FK), negative = puffed back
    head: head nod on top of the body, negative = looking up   head_yaw: head turn
    arms: (pitch, spread) for both arms: + pitch = back, + spread = out to the sides
    """
    head = max(-HEAD_MAX, min(HEAD_MAX, head))
    head_yaw = max(-HEAD_MAX, min(HEAD_MAX, head_yaw))
    pose = {
        HIP_BONE:      ([(PITCH, lean), (YAW, twist)], S(*hip)),
        "Torso_FK":    ([(PITCH, chest), (YAW, chest_twist)], None),
        "RightArm_FK": ([(PITCH, arms[0]), (ROLL, arms[1])], S(0, 0, -ARM_DROP)),
        "LeftArm_FK":  ([(PITCH, arms[0]), (ROLL, -arms[1])], S(0, 0, -ARM_DROP)),
        "RightLeg-IK": ([], foot(hip, *rfoot)),
        "LeftLeg-IK":  ([], foot(hip, *lfoot)),
    }
    if HEAD_MOVES:
        pose["Head"] = ([(PITCH, head), (YAW, head_yaw)], None)
    return pose


def hold(t0, t1, step, fade_to, sweep, period, base, shake):
    """Trembling roar hold. Alternates each shake value +/- and sweeps the head side to side,
    both fading down to fade_to by the end."""
    keys, t, i = [], t0, 0
    while t < t1:
        fade = 1 - (1 - fade_to) * (t - t0) / (t1 - t0)
        sign = (1 if i % 2 else -1) * fade
        kw = dict(base)
        for name, amp in shake.items():
            if name == "hip_z":
                x, y, z = kw["hip"]
                kw["hip"] = (x, y, z + amp * sign)
            elif name == "arm":
                kw["arms"] = (kw["arms"][0] + amp * sign, kw["arms"][1])
            else:
                kw[name] = kw[name] + amp * sign
        kw["head_yaw"] = sweep * fade * math.sin(2 * math.pi * (t - t0) / period)
        keys.append((t, P(**kw)))
        t, i = t + step, i + 1
    return keys


# --- Roar 1: broadcast (3.1 s) --------------------------------------------------
STOMP = dict(rfoot=(0, -0.5, 0), lfoot=(0, 0.1, 0))
BROADCAST = [
    (0.00, P()),                                                          # standing
    (0.45, P(hip=(0, 0.05, -0.25), lean=2, chest=-8, head=8, arms=(15, 16))),       # inhale, chin tucks
    (0.75, P(hip=(0, 0.08, -0.2), lean=-2, chest=-12, head=-12, arms=(20, 26),      # rear back, foot lifts
             rfoot=(0, -0.25, 0.25))),
    (0.95, P(hip=(0, -0.12, -0.5), lean=14, twist=4, chest=-4, head=-18,            # stomp, chest open
             arms=(30, 38), **STOMP)),
    (1.05, P(hip=(0, -0.13, -0.56), lean=16, twist=4, chest=-4, head=-18,           # overshoot
             arms=(34, 42), **STOMP)),
] + hold(1.12, 2.35, 0.07, 0.4, sweep=15, period=0.9,                             # roar: tremble + head sweep
         base=dict(hip=(0, -0.13, -0.53), lean=15, twist=4, chest=-4, head=-16, arms=(32, 40), **STOMP),
         shake=dict(hip_z=0.02, lean=1.2, chest=1.2, head=2)) + [
    (2.55, P(hip=(0, -0.05, -0.35), lean=12, chest=2, head=12, arms=(5, 12),       # exhale, foot steps back
             rfoot=(0, -0.3, 0.22))),
    (2.80, P(hip=(0, 0, -0.22), lean=9, head=3)),                                 # settle
    (3.10, P()),
]

# --- Roar 2: passive (1.7 s) ---------------------------------------------------
PASSIVE = [
    (0.00, P()),
    (0.30, P(hip=(0, 0.03, -0.24), lean=5, chest=-5, head=6, arms=(6, 13))),        # small breath in
    (0.50, P(hip=(0, -0.05, -0.3), lean=12, chest=3, head=-8, arms=(10, 15))),      # lean in a little
] + hold(0.58, 1.25, 0.08, 0.5, sweep=8, period=0.7,                              # low rumble
         base=dict(hip=(0, -0.05, -0.3), lean=12, chest=3, head=-7, arms=(10, 15)),
         shake=dict(lean=0.6, head=1.5)) + [
    (1.45, P(hip=(0, 0, -0.24), lean=9, head=4, arms=(2, 11))),                   # settle
    (1.70, P()),
]

# --- Roar 3: aggressive (1.9 s) ------------------------------------------------
LUNGE = dict(rfoot=(0, -0.65, 0), lfoot=(0, 0.2, 0))
AGGRESSIVE = [
    (0.00, P()),
    (0.18, P(hip=(0, 0.1, -0.35), lean=4, chest=-6, head=10, arms=(18, 20))),       # coil
    (0.32, P(hip=(0, 0.05, -0.3), lean=10, chest=-2, head=0, arms=(10, 22),         # foot lifts
             rfoot=(0, -0.3, 0.25))),
    (0.42, P(hip=(0, -0.25, -0.6), lean=30, twist=6, chest=8, head=-18,             # lunge in, claws forward
             arms=(-25, 32), **LUNGE)),
    (0.50, P(hip=(0, -0.27, -0.66), lean=33, twist=6, chest=8, head=-18,            # overshoot
             arms=(-30, 36), **LUNGE)),
] + hold(0.56, 1.45, 0.05, 0.6, sweep=6, period=0.35,                             # violent shake
         base=dict(hip=(0, -0.26, -0.63), lean=31, twist=6, chest=8, head=-16, arms=(-27, 34), **LUNGE),
         shake=dict(hip_z=0.03, lean=2, chest=2, head=3, arm=3)) + [
    (1.60, P(hip=(0, -0.1, -0.4), lean=16, head=8, arms=(0, 14),                  # pull back, foot returns
             rfoot=(0, -0.35, 0.22))),
    (1.90, P()),
]

ROARS = {"Roar_Broadcast": BROADCAST, "Roar_Passive": PASSIVE, "Roar_Aggressive": AGGRESSIVE}

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


for name, keys in ROARS.items():
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)

    last = len(keys) - 1
    for n, (t, pose) in enumerate(keys):
        for bone_name, (rots, loc) in pose.items():
            lag = LAG.get(bone_name, 0) if 0 < n < last else 0  # first/last keys stay lined up
            key(bone_name, round((t + lag) * FPS), rots, loc)
    print("Created action:", name, f"({keys[-1][0]} s)")

rig.animation_data.action = bpy.data.actions["Roar_Broadcast"]
scene.frame_start = 0
scene.frame_end = round(3.1 * FPS)
scene.frame_set(0)
print("STUD =", STUD)
