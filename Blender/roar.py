# Heavy roars for the R6 IK/FK Blender rig (v2.22) - same style as walk.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates three one-shot, in-place actions on __PrimaryArmature:
#   Roar_Broadcast  (1.80 s) - Giant_Bug_Vocals_4: big announcing roar, stomp, head raised and sweeping
#   Roar_Passive    (1.28 s) - Giant_Bug_Vocals_3: low-key warning roar, no step, gentle rumble
#   Roar_Aggressive (1.38 s) - Giant_Bug_Vocals_1: fast threat, lunges a step in, claws forward, violent shake
# Each roar is timed to its sound: the ENV_ lists are the audio's loudness every 0.05 s
# (1 = loudest), and the roar pose, shake and head sweep follow that loudness.
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
STANCE = 0.3     # studs each foot sits out to the side (matches idle.py)
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
        "RightLeg-IK": ([], foot(hip, rfoot[0] - STANCE, rfoot[1], rfoot[2])),
        "LeftLeg-IK":  ([], foot(hip, lfoot[0] + STANCE, lfoot[1], lfoot[2])),
    }
    if HEAD_MOVES:
        pose["Head"] = ([(PITCH, head), (YAW, head_yaw)], None)
    return pose


def lerp(a, b, k):
    if isinstance(a, tuple):
        return tuple(lerp(x, y, k) for x, y in zip(a, b))
    return a + (b - a) * k


def loudness(env, t):
    """Audio loudness (0-1) at time t, from an ENV_ list sampled every 0.05 s."""
    i = t / 0.05
    lo = min(int(i), len(env) - 1)
    hi = min(lo + 1, len(env) - 1)
    return lerp(env[lo], env[hi], i - lo)


def roar_hold(t0, t1, step, env, quiet, loud, shake, sweep, period):
    """The roar itself, driven by the sound: the louder the audio, the closer the body is to
    the loud pose and the harder it shakes; the head sweeps side to side with the volume."""
    keys, t, i = [], t0, 0
    while t < t1:
        level = loudness(env, t)
        kw = {k: lerp(quiet[k], loud[k], level) for k in quiet}
        sign = (1 if i % 2 else -1) * level
        for name, amp in shake.items():
            if name == "hip_z":
                x, y, z = kw["hip"]
                kw["hip"] = (x, y, z + amp * sign)
            elif name == "arm":
                kw["arms"] = (kw["arms"][0] + amp * sign, kw["arms"][1])
            else:
                kw[name] += amp * sign
        kw["head_yaw"] = sweep * level * math.sin(2 * math.pi * (t - t0) / period)
        keys.append((t, P(**kw)))
        t, i = t + step, i + 1
    return keys


# Audio loudness every 0.05 s (measured from the sound files, 1 = loudest moment).
ENV_BROADCAST = [0.00, 0.00, 0.00, 0.01, 0.02, 0.12, 0.19, 0.28, 0.49, 0.63, 0.66, 0.79, 0.83, 0.64, 0.85, 1.00,
                 0.86, 0.71, 0.71, 0.68, 0.66, 0.66, 0.65, 0.74, 0.82, 0.61, 0.64, 0.54, 0.34, 0.34, 0.38, 0.32,
                 0.33, 0.46, 0.36, 0.46, 0.38, 0.27, 0.25, 0.28, 0.22, 0.22, 0.18, 0.10, 0.11, 0.12, 0.13, 0.22,
                 0.40, 0.19, 0.19, 0.21, 0.13, 0.02, 0.01, 0.01, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00]
ENV_PASSIVE = [0.00, 0.00, 0.00, 0.01, 0.02, 0.06, 0.10, 0.36, 0.44, 0.63, 0.59, 0.70, 0.72, 1.00, 0.74, 0.85,
               0.76, 0.90, 0.75, 0.75, 0.65, 0.45, 0.35, 0.28, 0.24, 0.11, 0.05, 0.01, 0.01, 0.01, 0.00, 0.00,
               0.00, 0.00]
ENV_AGGRESSIVE = [0.00, 0.00, 0.01, 0.02, 0.04, 0.11, 0.35, 0.74, 0.94, 0.59, 0.71, 0.70, 0.74, 0.95, 0.57, 0.78,
                  0.80, 1.00, 0.77, 0.75, 0.68, 0.35, 0.27, 0.20, 0.24, 0.10, 0.09, 0.04, 0.04, 0.02, 0.04, 0.02,
                  0.02, 0.01, 0.01, 0.01, 0.01, 0.00, 0.00]

# --- Roar 1: broadcast (1.80 s) ------------------------------------------------
# Sound: starts at 0.15 s, full blast 0.35-1.35 s; everything after that is echo, so the body settles.
STOMP = dict(rfoot=(0, -0.5, 0), lfoot=(0, 0.1, 0))
BROADCAST = [
    (0.00, P()),                                                                  # standing
    (0.12, P(hip=(0, 0.06, -0.22), lean=-2, chest=-10, head=-8, arms=(18, 24),     # quick rear-back, foot lifts
             rfoot=(0, -0.25, 0.25))),
    (0.28, P(hip=(0, -0.12, -0.5), lean=14, twist=4, chest=-4, head=-18,           # stomp as the sound hits
             arms=(30, 38), **STOMP)),
] + roar_hold(0.34, 1.38, 0.073, ENV_BROADCAST, sweep=15, period=1.0,
              quiet=dict(hip=(0, -0.08, -0.4), lean=10, twist=3, chest=0, head=-6, arms=(12, 22), **STOMP),
              loud=dict(hip=(0, -0.13, -0.55), lean=16, twist=4, chest=-5, head=-18, arms=(34, 42), **STOMP),
              shake=dict(hip_z=0.02, lean=1.5, chest=1.5, head=2.5)) + [
    (1.52, P(hip=(0, -0.05, -0.35), lean=12, chest=2, head=12, arms=(5, 12),      # exhale, foot steps back
             rfoot=(0, -0.3, 0.22))),
    (1.66, P(hip=(0, 0, -0.22), lean=9, head=3)),                                 # settle
    (1.80, P()),
]

# --- Roar 2: passive (1.28 s) --------------------------------------------------
# Sound: starts at 0.15 s, full 0.35-1.0 s; the fade after that is echo.
PASSIVE = [
    (0.00, P()),
    (0.20, P(hip=(0, 0.03, -0.24), lean=5, chest=-5, head=6, arms=(6, 13))),       # small breath in
] + roar_hold(0.36, 1.02, 0.1, ENV_PASSIVE, sweep=8, period=0.7,
              quiet=dict(hip=(0, 0, -0.24), lean=8, chest=0, head=0, arms=(3, 11)),
              loud=dict(hip=(0, -0.06, -0.32), lean=13, chest=3, head=-9, arms=(10, 15)),
              shake=dict(lean=0.6, head=1.5)) + [
    (1.14, P(hip=(0, 0, -0.24), lean=9, head=4, arms=(2, 11))),                   # settle
    (1.28, P()),
]

# --- Roar 3: aggressive (1.38 s) -----------------------------------------------
# Sound: slams in at 0.3 s, pulses at 0.4 / 0.65 / 0.85 s, ends at 1.05 s; the tail is echo.
LUNGE = dict(rfoot=(0, -0.65, 0), lfoot=(0, 0.2, 0))
AGGRESSIVE = [
    (0.00, P()),
    (0.10, P(hip=(0, 0.1, -0.35), lean=4, chest=-6, head=6, arms=(18, 20))),        # coil
    (0.22, P(hip=(0, 0.05, -0.3), lean=10, chest=-2, head=0, arms=(10, 22),         # foot lifts
             rfoot=(0, -0.3, 0.25))),
    (0.34, P(hip=(0, -0.25, -0.6), lean=30, twist=6, chest=8, head=-6,              # lunge lands with the hit
             arms=(-25, 32), **LUNGE)),
] + roar_hold(0.38, 1.04, 0.05, ENV_AGGRESSIVE, sweep=6, period=0.35,
              quiet=dict(hip=(0, -0.2, -0.5), lean=22, twist=5, chest=5, head=-2, arms=(-10, 26), **LUNGE),
              loud=dict(hip=(0, -0.27, -0.66), lean=33, twist=6, chest=9, head=-8, arms=(-30, 36), **LUNGE),
              shake=dict(hip_z=0.03, lean=2, chest=2, head=1.5, arm=3)) + [
    (1.18, P(hip=(0, -0.1, -0.4), lean=16, head=4, arms=(0, 14),                  # pull back, foot returns
             rfoot=(0, -0.35, 0.22))),
    (1.38, P()),
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
scene.frame_end = round(BROADCAST[-1][0] * FPS)
scene.frame_set(0)
print("STUD =", STUD)
