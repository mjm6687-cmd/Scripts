# Movement extras for the R6 IK/FK Blender rig (v2.22) - same stance and style as idle.py / roar.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates these actions on __PrimaryArmature:
#   Crouch_Idle (loop, 4 s)    - breathing idle in the crouch-walk pose
#   Jump        (0.35 s)       - push off and tuck the legs (Roblox plays Fall right after)
#   Fall        (loop, 0.8 s)  - airborne: legs hanging, arms out for balance
#   Land        (0.6 s)        - heavy impact: deep knee bend, body crunches, recovers to the idle stance
#   Turn_Left / Turn_Right (loop, 1.2 s) - heavy shuffle steps for turning on the spot
# Arms are FK (rotated), legs are IK (foot targets moved).
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



def all_fcurves(act):
    layers = getattr(act, "layers", None)
    if layers:
        for layer in layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    yield from bag.fcurves
    else:
        yield from act.fcurves


# --- Crouch idle (loop, 4 s) ---------------------------------------------------
# Same body as the crouch walks (low, hunched, arms hanging forward); breathes and shifts weight.
CROUCH = dict(hip=(0, 0, -0.75), lean=24, chest=6, arms=(-15, 10))


def crouch(**changes):
    kw = dict(CROUCH)
    kw.update(changes)
    return P(**kw)


CROUCH_IDLE = [
    (0.00, crouch()),
    (0.55, crouch(hip=(-0.04, 0, -0.71), lean=23, tilt=-1, chest=4, head=-2, head_yaw=-4, arms=(-16, 11))),
    (1.10, crouch(hip=(-0.06, 0, -0.74), lean=24, tilt=-1.5, chest=5, head_yaw=-5, arms=(-15, 11))),
    (1.75, crouch(hip=(-0.03, 0, -0.78), lean=25.5, tilt=-0.5, chest=7, head=2, head_yaw=-2, arms=(-13, 10))),
    (2.00, crouch()),
    (2.55, crouch(hip=(0.04, 0, -0.71), lean=23, tilt=1, chest=4, head=-2, head_yaw=4, arms=(-16, 11))),
    (3.10, crouch(hip=(0.06, 0, -0.74), lean=24, tilt=1.5, chest=5, head_yaw=5, arms=(-15, 11))),
    (3.75, crouch(hip=(0.03, 0, -0.78), lean=25.5, tilt=0.5, chest=7, head=2, head_yaw=2, arms=(-13, 10))),
    (4.00, crouch()),
]

# --- Jump / Fall / Land ----------------------------------------------------------
# In the air the feet are pulled up toward the body, so the knees stay bent.
AIR = dict(hip=(0, 0, -0.15), lean=12, chest=2, head=-4, arms=(-15, 22),
           rfoot=(0, -0.15, 0.55), lfoot=(0, 0.2, 0.4))

JUMP = [
    (0.00, P()),
    (0.08, P(hip=(0, 0.05, -0.5), lean=20, chest=4, head=4, arms=(18, 16))),        # quick load
    (0.20, P(hip=(0, -0.05, -0.1), lean=6, chest=-4, head=-6, arms=(-30, 16),       # explode up, arms swing up
             rfoot=(0, 0.05, 0.15), lfoot=(0, 0.15, 0.25))),
    (0.35, P(**AIR)),                                                              # tuck
]

FALL = [
    (0.00, P(**AIR)),
    (0.40, P(hip=(0, 0, -0.13), lean=10, chest=1, head=-6, arms=(-18, 26),         # arms drift out for balance,
             rfoot=(0, -0.1, 0.45), lfoot=(0, 0.25, 0.5))),                         # legs paddle slightly
    (0.80, P(**AIR)),
]

LAND = [
    (0.00, P(**AIR)),
    (0.06, P(hip=(0, 0, -0.45), lean=20, chest=4, head=0, arms=(-20, 22))),         # feet hit the ground
    (0.14, P(hip=(0, 0.05, -0.92), lean=32, chest=10, head=8, arms=(-28, 20))),     # deep crunch
    (0.22, P(hip=(0, 0.04, -0.85), lean=30, chest=9, head=6, arms=(-24, 18))),
    (0.40, P(hip=(0, 0.02, -0.45), lean=16, chest=3, head=2, arms=(-6, 12))),       # heave back up
    (0.60, P()),                                                                   # idle stance
]

# --- Turn in place (loop, 1.2 s) -------------------------------------------------
# Each foot counter-rotates while planted (so it stays put while the body turns) and
# then lifts and steps around into the turn. TURN_STEP is how far the body turns per loop.
TURN_STEP = 30  # degrees per 1.2 s loop


def turn_feet(angle_r, angle_l, lift_r, lift_l):
    """Foot offsets (from the stance) for feet rotated around the body by the given angles."""
    def spot(x, angle, lift):
        a = math.radians(angle)
        return (x * math.cos(a) - x, x * math.sin(a), lift)  # rotate (x, 0) around the body centre
    return dict(rfoot=spot(-(0.5 + STANCE), angle_r, lift_r), lfoot=spot(0.5 + STANCE, angle_l, lift_l))


def turn_keys(direction):
    """direction: +1 = turn left, -1 = turn right. The foot on the turning side steps first."""
    half = TURN_STEP / 2 * direction
    keys = []
    for i in range(13):
        t = i / 12                                       # 0..1 through the loop
        lead_swing = t < 0.4                             # first foot steps during 0-0.4
        trail_swing = 0.5 <= t < 0.9                     # second foot steps during 0.5-0.9

        def angle(swinging, start, length, phase):
            if swinging:
                k = (t - start) / length
                return -half + 2 * half * k, 0.35 * math.sin(math.pi * k)
            return half - 2 * half * phase, 0.0         # planted: slide back against the turn

        lead = angle(lead_swing, 0.0, 0.4, (t - 0.4) / 0.6 if t >= 0.4 else 0)
        trail_phase = (t - 0.9) / 0.6 if t >= 0.9 else (t + 0.1) / 0.6
        trail = angle(trail_swing, 0.5, 0.4, trail_phase)
        # which real foot is which
        if direction > 0:   # turning left: left foot leads
            feet = turn_feet(trail[0], lead[0], trail[1], lead[1])
        else:
            feet = turn_feet(lead[0], trail[0], lead[1], trail[1])
        dip = -0.2 - 0.06 * (math.sin(2 * math.pi * t * 2) ** 2)   # small bob on each plant
        keys.append((t * 1.2, P(hip=(0, 0, dip), twist=6 * direction, chest_twist=4 * direction,
                                 head_yaw=10 * direction, **feet)))
    return keys


ACTIONS = {
    # name: (keys, loops, lag)
    "Crouch_Idle": (CROUCH_IDLE, True, {"Head": 0.15, "RightArm_FK": 0.12, "LeftArm_FK": 0.12}),
    "Jump":        (JUMP, False, {"RightArm_FK": 0.03, "LeftArm_FK": 0.03}),
    "Fall":        (FALL, True, {"RightArm_FK": 0.05, "LeftArm_FK": 0.05}),
    "Land":        (LAND, False, {"Head": 0.03, "RightArm_FK": 0.04, "LeftArm_FK": 0.04}),
    "Turn_Left":   (turn_keys(1), True, {"RightArm_FK": 0.05, "LeftArm_FK": 0.05}),
    "Turn_Right":  (turn_keys(-1), True, {"RightArm_FK": 0.05, "LeftArm_FK": 0.05}),
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


for name, (keys, loops, lag_for) in ACTIONS.items():
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
            # loops shift every key (period stays the same); one-shots keep first/last lined up
            lag = lag_for.get(bone_name, 0) if loops or 0 < n < last else 0
            key(bone_name, round((t + lag) * FPS), rots, loc)
    if loops:
        for fc in all_fcurves(action):
            fc.modifiers.new('CYCLES')
    print("Created action:", name, f"({keys[-1][0]} s{', loop' if loops else ''})")

rig.animation_data.action = bpy.data.actions["Crouch_Idle"]
scene.frame_start = 0
scene.frame_end = round(4.0 * FPS) - 1
scene.frame_set(0)
print("STUD =", STUD)
