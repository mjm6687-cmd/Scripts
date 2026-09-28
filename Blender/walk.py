# Heavy walk loops in 8 directions for the R6 IK/FK Blender rig (v2.22) - same style as sprint.py.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates looping, in-place actions on __PrimaryArmature:
#   Walk_Forward, Walk_Backward, Walk_Left, Walk_Right,
#   Walk_ForwardLeft, Walk_ForwardRight, Walk_BackwardLeft, Walk_BackwardRight
# Arms are FK (rotated), legs are IK (foot targets moved). The head is never keyed.
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
HIP_BONE = "LowerTorso-FK"
CYCLE = 1.3  # seconds for a full stride (right step + left step). Higher = slower, heavier.

# Which way the character faces in this rig: -1 = faces -Y, 1 = faces +Y.
# If the walk goes backwards, flip this number.
FACING = 1

# Armature-space axes (flipped automatically by FACING).
PITCH = (-FACING, 0, 0)  # + leans torso forward, - swings arms forward
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


ARM_SWING = 0.2   # how much the arms swing (1 = full human-like swing, 0 = arms stay still)
ARM_DROP = 0.15   # studs the arms sit lower on the body (like grabbing them and pressing G, then moving down)
ARM_OUT = 10      # degrees the arms sit out from the sides
SIDE_STRIDE = 0.55  # sideways steps are shorter so the feet never cross
FOOT_GAP = 0.35     # minimum studs between the feet side to side (R6 feet start 1 stud apart)
LEG = 2.0
REACH = 1.05 * LEG  # a touch over LEG: a planted leg reads as straight, not broken


def foot(hip, x, y, z):
    """Foot offset [x, y, z] in studs, shortened if it's out of reach of the hip."""
    hx, hy, hz = hip[0], hip[1], LEG + hip[2]
    dz = min(abs(z - hz), REACH)
    max_d = math.sqrt(REACH ** 2 - dz ** 2)
    dx, dy = x - hx, y - hy
    d = math.hypot(dx, dy)
    if d > max_d:
        x, y = hx + dx * max_d / d, hy + dy * max_d / d
    return [x, y, max(z, 0)]


# --- One step, written for whichever foot just landed (the "lead" foot) --------
# along: foot position along the walking direction in studs (negative = ahead)
# sway: hip shift over the lead foot   twist: hips turn toward the forward leg
# tilt: hips drop toward the lead side  arms: (lead-side arm, other arm) swing
PHASES = [
    # (time, name)
    (0.00, dict(z=-0.10, sway=0.02, bend=0, twist=5, chest=-8, tilt=0, chest_bend=0,
                arms=(20, -25), lead=(-0.80, 0.0), trail=(0.80, 0.10))),   # lead heel plants ahead
    (0.12, dict(z=-0.22, sway=0.12, bend=3, twist=3, chest=-6, tilt=-4, chest_bend=3,
                arms=(18, -20), lead=(-0.45, 0.0), trail=(0.45, 0.30))),   # weight drops onto it
    (0.25, dict(z=-0.02, sway=0.15, bend=0, twist=0, chest=0, tilt=-3, chest_bend=1,
                arms=(0, -3), lead=(0.05, 0.0), trail=(-0.10, 0.50))),     # body rolls over it
    (0.38, dict(z=-0.05, sway=0.08, bend=-1, twist=-3, chest=5, tilt=-1, chest_bend=0,
                arms=(-18, 15), lead=(0.45, 0.0), trail=(-0.60, 0.20))),   # pushes back, other foot reaches
]


def build(ph, lead, fwd, right):
    """Pose for one phase. lead: 'R' or 'L'. fwd/right: walking direction (-1..1)."""
    side = 1 if lead == "R" else -1          # flips everything that belongs to the lead side
    hip = (-ph["sway"] * side, 0, ph["z"])   # x<0 is the character's right

    def place(along, z):
        # along<0 means ahead in the walking direction
        return foot(hip, along * right * SIDE_STRIDE, along * fwd, z)

    lead_foot, trail_foot = place(*ph["lead"]), place(*ph["trail"])
    rfoot, lfoot = (lead_foot, trail_foot) if lead == "R" else (trail_foot, lead_foot)
    # keep the feet from crossing: right foot sits at x=-0.5, left at +0.5 at rest
    gap = (0.5 + lfoot[0]) - (-0.5 + rfoot[0])
    if gap < FOOT_GAP:
        push = (FOOT_GAP - gap) / 2
        rfoot[0] -= push
        lfoot[0] += push

    lead_arm, other_arm = ph["arms"][0] * fwd, ph["arms"][1] * fwd
    rarm, larm = (lead_arm, other_arm) if lead == "R" else (other_arm, lead_arm)

    lean = 6 + 2 * fwd + ph["bend"]          # a bit less lean walking backwards
    side_lean = -3 * right                   # lean into sideways travel
    return {
        HIP_BONE:      ([(PITCH, lean), (YAW, ph["twist"] * side * fwd),
                         (ROLL, ph["tilt"] * side + side_lean)], S(*hip)),
        "Torso_FK":    ([(PITCH, ph["chest_bend"]), (YAW, ph["chest"] * side * fwd)], None),
        "RightArm_FK": ([(PITCH, rarm * ARM_SWING), (ROLL, ARM_OUT)], S(0, 0, -ARM_DROP)),
        "LeftArm_FK":  ([(PITCH, larm * ARM_SWING), (ROLL, -ARM_OUT)], S(0, 0, -ARM_DROP)),
        "RightLeg-IK": ([], S(*rfoot)),
        "LeftLeg-IK":  ([], S(*lfoot)),
    }


def cycle_keys(fwd, right):
    keys = [(t, build(ph, "R", fwd, right)) for t, ph in PHASES]
    keys += [(t + 0.5, build(ph, "L", fwd, right)) for t, ph in PHASES]
    keys.append((1.0, keys[0][1]))
    return keys


# Arms trail the body slightly so they swing with weight instead of snapping.
LAG = {"RightArm_FK": 0.04, "LeftArm_FK": 0.04}

D = math.sqrt(0.5)
DIRECTIONS = {  # name: (forward, right)
    "Walk_Forward":       (1, 0),
    "Walk_Backward":      (-1, 0),
    "Walk_Left":          (0, -1),
    "Walk_Right":         (0, 1),
    "Walk_ForwardLeft":   (D, -D),
    "Walk_ForwardRight":  (D, D),
    "Walk_BackwardLeft":  (-D, -D),
    "Walk_BackwardRight": (-D, D),
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


def all_fcurves(act):
    layers = getattr(act, "layers", None)
    if layers:
        for layer in layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    yield from bag.fcurves
    else:
        yield from act.fcurves


for name, (fwd, right) in DIRECTIONS.items():
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)

    for t, pose in cycle_keys(fwd, right):
        for bone_name, (rots, loc) in pose.items():
            frame = round((t + LAG.get(bone_name, 0)) * CYCLE * FPS)
            key(bone_name, frame, rots, loc)

    for fc in all_fcurves(action):
        fc.modifiers.new('CYCLES')  # seamless loop
    print("Created action:", name)

rig.animation_data.action = bpy.data.actions["Walk_Forward"]
scene.frame_start = 0
scene.frame_end = round(CYCLE * FPS) - 1  # last frame = first frame, so skip it when exporting
scene.frame_set(0)
print("STUD =", STUD)
