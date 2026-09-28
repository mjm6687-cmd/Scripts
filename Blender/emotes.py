# Idle emotes for the R6 IK/FK Blender rig (v2.22) - same stance as idle.py and roar.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates three one-shot, in-place actions on __PrimaryArmature that start and end on the
# idle stance, so they can play straight out of the idle and back into it:
#   Emote_LungeFakeOut (2.1 s) - lunges at someone, stops dead, stares, tilts its head
#   Emote_GroundSlam   (2.4 s) - rears up, hammers both arms into the ground, heaves back up
#   Emote_StalkScan    (4.5 s) - sinks low, scans in jerky bug-like steps, locks on
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


def P(hip=(0, 0, -0.2), lean=8, twist=0, tilt=0, chest=0, chest_twist=0,
      head=0, head_yaw=0, head_tilt=0, arms=(0, 10), rfoot=(0, 0, 0), lfoot=(0, 0, 0)):
    """One pose. P() with no arguments is the idle/roar stance.
    hip: body offset (x, y, z) studs; z stays below 0 so the knees stay bent
    lean: hips forward lean (LowerTorso-FK)       twist: hips turn, + = toward the character's left
    tilt: hips side tilt, + = toward the left     chest / chest_twist: extra bend / turn on Torso_FK
    head: nod, negative = looking up   head_yaw: turn, + = left   head_tilt: ear-to-shoulder, + = left
    arms: (pitch, spread) for both arms: + pitch = back, - = forward/up, + spread = out to the sides
    rfoot / lfoot: (x, y, z) studs from the stance position, y<0 = forward
    """
    clamp = lambda v: max(-HEAD_MAX, min(HEAD_MAX, v))
    pose = {
        HIP_BONE:      ([(PITCH, lean), (YAW, twist), (ROLL, tilt)], S(*hip)),
        "Torso_FK":    ([(PITCH, chest), (YAW, chest_twist)], None),
        "RightArm_FK": ([(PITCH, arms[0]), (ROLL, arms[1])], S(0, 0, -ARM_DROP)),
        "LeftArm_FK":  ([(PITCH, arms[0]), (ROLL, -arms[1])], S(0, 0, -ARM_DROP)),
        "RightLeg-IK": ([], foot(hip, rfoot[0] - STANCE, rfoot[1], rfoot[2])),
        "LeftLeg-IK":  ([], foot(hip, lfoot[0] + STANCE, lfoot[1], lfoot[2])),
    }
    if HEAD_MOVES:
        pose["Head"] = ([(PITCH, clamp(head)), (YAW, clamp(head_yaw)), (ROLL, clamp(head_tilt))], None)
    return pose


# --- Emote 1: lunge fake-out (2.1 s) -------------------------------------------
# Coils, lunges a step at someone with claws out... and stops dead. Stares, tilts its
# head, then slowly straightens up and pulls the foot back.
STEP = dict(rfoot=(0, -0.7, 0), lfoot=(0, 0.2, 0))
LUNGE_FAKE_OUT = [
    (0.00, P()),
    (0.25, P(hip=(0, 0.12, -0.35), lean=4, chest=-6, head=6, arms=(15, 18))),       # coil
    (0.34, P(hip=(0, 0.0, -0.3), lean=14, chest=0, head=0, arms=(0, 22),            # foot lifts
             rfoot=(0, -0.35, 0.25))),
    (0.45, P(hip=(0, -0.3, -0.6), lean=30, twist=5, chest=8, head=-8,              # lunge lands, claws out
             arms=(-35, 30), **STEP)),
    (0.52, P(hip=(0, -0.34, -0.64), lean=33, twist=5, chest=9, head=-8,            # ...stops dead
             arms=(-40, 32), **STEP)),
    (0.80, P(hip=(0, -0.33, -0.62), lean=32, twist=5, chest=8, head=-7,            # frozen stare
             arms=(-39, 31), **STEP)),
    (1.10, P(hip=(0, -0.33, -0.62), lean=32, twist=5, chest=8, head=-6,            # slow creepy head tilt
             head_tilt=12, arms=(-38, 31), **STEP)),
    (1.30, P(hip=(0, -0.32, -0.61), lean=31, twist=5, chest=8, head=-6,
             head_tilt=12, arms=(-37, 30), **STEP)),
    (1.60, P(hip=(0, -0.15, -0.4), lean=18, twist=2, chest=4, head=0,              # slowly straightens
             head_tilt=4, arms=(-10, 16), **STEP)),
    (1.85, P(hip=(0, -0.05, -0.28), lean=10, head=0, arms=(0, 11),                 # foot comes back
             rfoot=(0, -0.35, 0.2))),
    (2.10, P()),
]

# --- Emote 2: ground slam (2.4 s) ----------------------------------------------
# Rears up with both arms overhead, hammers them into the ground in front, stays
# down breathing hard for a moment, then heaves itself back up.
SLAM_DOWN = dict(hip=(0, -0.15, -0.8), lean=40, chest=12, head=9, arms=(-71, 13))
GROUND_SLAM = [
    (0.00, P()),
    (0.45, P(hip=(0, 0.08, -0.16), lean=-6, chest=-12, head=-12, arms=(-150, 15))),  # rear up, arms overhead
    (0.62, P(hip=(0, 0.1, -0.15), lean=-8, chest=-13, head=-14, arms=(-160, 16))),   # hang at the top
    (0.78, P(hip=(0, -0.15, -0.75), lean=37, chest=12, head=8, arms=(-70, 13))),     # SLAM
    (0.84, P(hip=(0, -0.16, -0.84), lean=42, chest=13, head=10, arms=(-73, 12))),    # impact overshoot
    (0.92, P(hip=(0, -0.15, -0.77), lean=39, chest=12, head=9, arms=(-70, 13))),     # recoil
    (1.00, P(**SLAM_DOWN)),
    (1.25, P(hip=(0, -0.15, -0.76), lean=39, chest=10, head=8, arms=(-70, 13))),     # heavy breath
    (1.50, P(**SLAM_DOWN)),
    (1.85, P(hip=(0, -0.05, -0.4), lean=18, chest=4, head=2, arms=(-15, 12))),       # heave back up
    (2.15, P(hip=(0, 0, -0.24), lean=9, arms=(2, 10))),                              # settle
    (2.40, P()),
]

# --- Emote 3: stalk scan (4.5 s) -----------------------------------------------
# Sinks low and scans in jerky, bug-like steps: left, further left, back, right,
# further right... then locks on, leans in with a head tilt, and eases back up.
LOW = dict(hip=(0, 0.02, -0.4), lean=16, chest=4, head=-6, arms=(-5, 14))


def look(yaw_total, tilt=0, **extra):
    """Scan pose looking yaw_total degrees left (+) or right (-), split across hips, chest and head."""
    kw = dict(LOW)
    kw.update(twist=yaw_total * 0.3, chest_twist=yaw_total * 0.25, head_yaw=yaw_total * 0.45,
              head_tilt=tilt)
    kw.update(extra)
    return P(**kw)


# Each look is a quick snap (0.08 s) followed by a still hold, like an insect.
STALK_SCAN = [
    (0.00, P()),
    (0.40, look(0)),                          # sink low
    (0.60, look(0)),
    (0.68, look(18)),                         # snap left
    (1.10, look(18)),
    (1.18, look(34, tilt=6)),                 # further left, slight tilt
    (1.70, look(34, tilt=6)),
    (1.80, look(0)),                          # back to center
    (2.20, look(0)),
    (2.28, look(-18)),                        # snap right
    (2.70, look(-18)),
    (2.78, look(-34, tilt=-6)),               # further right
    (3.10, look(-34, tilt=-6)),
    (3.25, look(-34, tilt=-10, hip=(0, -0.12, -0.45), lean=22, arms=(-14, 16))),   # lock on, lean in
    (3.80, look(-34, tilt=-10, hip=(0, -0.13, -0.46), lean=22, arms=(-15, 16))),
    (4.20, look(-10, hip=(0, 0, -0.3), lean=11)),                                  # ease back
    (4.50, P()),
]

EMOTES = {
    "Emote_LungeFakeOut": (LUNGE_FAKE_OUT, {"Head": 0.04, "RightArm_FK": 0.05, "LeftArm_FK": 0.05}),
    "Emote_GroundSlam":   (GROUND_SLAM, {"Head": 0.04, "RightArm_FK": 0.03, "LeftArm_FK": 0.03}),
    "Emote_StalkScan":    (STALK_SCAN, {"RightArm_FK": 0.06, "LeftArm_FK": 0.06}),  # head snaps, no lag
}


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


for name, (keys, lag_for) in EMOTES.items():
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
            lag = lag_for.get(bone_name, 0) if 0 < n < last else 0  # first/last keys stay lined up
            key(bone_name, round((t + lag) * FPS), rots, loc)
    print("Created action:", name, f"({keys[-1][0]} s)")

rig.animation_data.action = bpy.data.actions["Emote_LungeFakeOut"]
scene.frame_start = 0
scene.frame_end = round(LUNGE_FAKE_OUT[-1][0] * FPS)
scene.frame_set(0)
print("STUD =", STUD)
