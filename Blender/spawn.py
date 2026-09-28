# Spawn: crawls up out of the floor. R6 IK/FK Blender rig (v2.22), same stance as idle.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a one-shot, in-place "Spawn" action (about 5 s) on __PrimaryArmature:
#   starts fully underground -> claws burst up -> hands slam onto the floor -> drags its body
#   up and out -> right leg climbs out, then the left -> stands, shakes off -> idle stance.
# The body really goes below the floor (HumanoidRootPart stays put), so in Roblox whatever is
# under the floor hides it. Arms are FK (rotated), legs are IK (foot targets moved).
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
    return S(x, y, z)  # no floor limit here: the spawn starts underground


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


# R6 sizes (studs) used to keep the hands planted on the floor while the body pulls itself up.
HIP_HEIGHT = 2.0       # hips above the floor when standing
SHOULDER_ABOVE = 1.5   # shoulder joints above the hips
ARM_LEN = 1.5          # shoulder joint to the bottom of the arm
GRIP = 2.4             # how far in front of the spawn point the hands grab the floor


def climb_pose(hip_z, lean, chest, head, **extra):
    """A pulling-up pose with the hands locked to the floor at GRIP studs in front.
    Works out the arm angle (hands on the floor) and slides the body forward/back so the
    hands don't skid as the lean changes."""
    body = math.radians(lean + chest)
    shoulder_h = HIP_HEIGHT + hip_z + (SHOULDER_ABOVE - ARM_DROP) * math.cos(body)
    reach = math.acos(max(-0.95, min(0.95, shoulder_h / ARM_LEN)))      # arm angle from straight down
    hand_ahead = SHOULDER_ABOVE * math.sin(body) + ARM_LEN * math.sin(reach)
    hip_y = hand_ahead - GRIP                                            # y<0 = forward
    kw = dict(hip=(0, hip_y, hip_z), lean=lean, chest=chest, head=head,
              arms=(-math.degrees(reach) - (lean + chest), 16),
              rfoot=under(hip_z, hip_y + 0.3), lfoot=under(hip_z, hip_y + 0.4))
    kw.update(extra)
    return P(**kw)


def under(hip_z, y=0.3):
    """Feet hanging underground, a bit below and behind the hips, knees bent."""
    return (0, y, hip_z + 0.35)


SPAWN = [
    (0.00, P(hip=(0, 0, -5.6), lean=12, head=15, arms=(-175, 12),                  # fully underground
             rfoot=under(-5.6), lfoot=under(-5.6, 0.4))),
    (0.35, P(hip=(0, 0, -4.6), lean=12, head=15, arms=(-175, 14),                  # claws and head break the surface
             rfoot=under(-4.6), lfoot=under(-4.6, 0.4))),
    (0.58, P(hip=(0, 0, -4.3), lean=18, chest=4, head=0, arms=(-160, 16),          # reach over the edge
             rfoot=under(-4.3), lfoot=under(-4.3, 0.4))),
    (0.80, climb_pose(-4.1, 20, 5, -6)),                                           # hands slam onto the floor
    (0.88, climb_pose(-4.2, 22, 6, -4)),                                           # impact dip
    (1.20, climb_pose(-3.4, 35, 8, -12)),                                          # heave...
    (1.35, climb_pose(-3.3, 36, 8, -10)),                                          # (catch breath)
    (1.65, climb_pose(-2.6, 45, 8, -16)),                                          # ...chest comes out
    (2.00, climb_pose(-1.9, 50, 6, -18, rfoot=(0, 0.2, -1.0))),                    # right knee comes up
    (2.30, climb_pose(-1.5, 50, 6, -18, rfoot=(0, -0.5, 0))),                      # right foot on the floor
    (2.70, P(hip=(0, 0.05, -1.1), lean=45, chest=6, head=-16, arms=(-40, 14),     # push off, hands let go,
             rfoot=(0, -0.5, 0), lfoot=(0, 0.1, 0.3))),                             # left leg climbs out
    (3.00, P(hip=(0, 0, -0.8), lean=35, chest=6, head=-12, arms=(-20, 12),        # crouched on the floor
             rfoot=(0, -0.5, 0), lfoot=(0, 0.1, 0))),
    (3.40, P(hip=(0, 0, -0.4), lean=18, chest=2, head=-4, arms=(-5, 11),          # rises
             rfoot=(0, -0.5, 0), lfoot=(0, 0.1, 0))),
    (3.65, P(hip=(0, 0, -0.3), lean=12, arms=(0, 10), rfoot=(0, -0.25, 0.25))),    # right foot steps back
    (3.90, P(hip=(0, 0, -0.25), lean=10)),
    # shake off the dirt
    (4.05, P(hip=(0.04, 0, -0.24), lean=9, tilt=4, twist=5, head_yaw=8, head_tilt=4, arms=(-3, 14))),
    (4.15, P(hip=(-0.04, 0, -0.24), lean=9, tilt=-4, twist=-5, head_yaw=-8, head_tilt=-4, arms=(3, 14))),
    (4.25, P(hip=(0.03, 0, -0.23), lean=9, tilt=3, twist=4, head_yaw=6, head_tilt=3, arms=(-2, 13))),
    (4.35, P(hip=(-0.02, 0, -0.23), lean=9, tilt=-2, twist=-3, head_yaw=-4, head_tilt=-2, arms=(2, 12))),
    (4.45, P(hip=(0.01, 0, -0.22), lean=8, tilt=1, twist=1, head_yaw=2, arms=(0, 11))),
    (4.80, P()),                                                                   # idle stance
]

# Hands are locked to the floor while climbing, so the arms don't lag.
LAG = {"Head": 0.04}


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


old = bpy.data.actions.get("Spawn")
if old:
    bpy.data.actions.remove(old)
action = bpy.data.actions.new("Spawn")
action.use_fake_user = True
rig.animation_data.action = action
for pb in rig.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)

last = len(SPAWN) - 1
for n, (t, pose) in enumerate(SPAWN):
    for bone_name, (rots, loc) in pose.items():
        lag = LAG.get(bone_name, 0) if 0 < n < last else 0
        key(bone_name, round((t + lag) * FPS), rots, loc)

scene.frame_start = 0
scene.frame_end = round(SPAWN[-1][0] * FPS)
scene.frame_set(0)
print("Created action: Spawn", f"({SPAWN[-1][0]} s) | STUD =", STUD)
