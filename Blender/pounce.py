# Pounce animation set for the R6 IK/FK Blender rig (v2.22) - on all fours.
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates 3 in-place actions on __PrimaryArmature that chain together:
#   Pounce_Crouch - from an all-fours stance, sink low, wiggle, tense, hold
#   Pounce_Start  - squash, then explosive push-off
#   Pounce_Lunge  - stretch out mid-air, overshoot and settle, hold
# Arms are FK (rotated), legs are IK (foot targets moved).
# Every angle is WORLD-space, not relative to the parent bone:
#   torso 0 = upright, 90 = flat;  arms 0 = straight down, negative = forward;
#   head 0 = upright facing forward.
import bpy
import math
from mathutils import Matrix, Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
HIP_BONE = "LowerTorso-FK"  # moves the body; swap to "PrimaryTorso_Positioner" if the feet get dragged along

# Armature-space axes: the character faces -Y.
PITCH = (1, 0, 0)  # + leans torso/head forward, - swings arms forward
ROLL = (0, 1, 0)   # + moves right arm outward, - moves left arm outward

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
    """Offset in studs, armature space. y<0 is forward, z>0 is up."""
    return (x * STUD, y * STUD, z * STUD)


def pose(hip, torso, head, arms, feet, sway=0.0, torso_roll=0.0, arm_spread=5):
    """Build a pose.
    hip: (y, z) body offset in studs      torso: forward lean in degrees
    head: head pitch                       arms: (right, left) arm pitch
    feet: (right (y, z), left (y, z))      sway: hip side offset in studs
    torso_roll: side tilt of the torso     arm_spread: how far the paws splay out
    """
    return {
        HIP_BONE:      ([], S(sway, hip[0], hip[1])),
        "Torso_FK":    ([(PITCH, torso), (ROLL, torso_roll)], None),
        "Head":        ([(PITCH, head)], None),
        "RightArm_FK": ([(PITCH, arms[0]), (ROLL, arm_spread)], None),
        "LeftArm_FK":  ([(PITCH, arms[1]), (ROLL, -arm_spread)], None),
        "RightLeg-IK": ([], S(0, *feet[0])),
        "LeftLeg-IK":  ([], S(0, *feet[1])),
    }


# --- Poses -------------------------------------------------------------------
# R6 arms can't bend, so chest height comes from how far the arms angle forward.
STANCE = pose(hip=(0.0, -1.35), torso=80, head=0, arms=(0, 0),
              feet=((0.6, 0), (0.9, 0)))

CROUCH_DIP = pose(hip=(0.35, -1.75), torso=82, head=-8, arms=(-30, -30),     # overshoot on the way down
                  feet=((0.5, 0), (0.8, 0)), arm_spread=9)
CROUCH = pose(hip=(0.3, -1.6), torso=80, head=-5, arms=(-25, -25),
              feet=((0.5, 0), (0.8, 0)), arm_spread=8)

# Cat-style rear wiggle while lining up the pounce; head stays locked on the target.
WIGGLE_R = pose(hip=(0.32, -1.58), torso=79, head=-5, arms=(-24, -26),
                feet=((0.5, 0), (0.8, 0)), sway=0.18, torso_roll=4, arm_spread=8)
WIGGLE_L = pose(hip=(0.32, -1.58), torso=79, head=-5, arms=(-26, -24),
                feet=((0.5, 0), (0.8, 0)), sway=-0.18, torso_roll=-4, arm_spread=8)
WIGGLE_R_SMALL = pose(hip=(0.31, -1.6), torso=80, head=-5, arms=(-25, -25),
                      feet=((0.5, 0), (0.8, 0)), sway=0.08, torso_roll=2, arm_spread=8)

SQUASH = pose(hip=(0.4, -1.85), torso=84, head=-10, arms=(-35, -35),       # coiled right before launch
              feet=((0.45, 0), (0.75, 0)), arm_spread=10)

START = pose(hip=(-0.3, -0.6), torso=60, head=-5, arms=(30, 30),           # back legs shove, paws push off
             feet=((1.2, 0.1), (1.4, 0.2)), arm_spread=5)

LUNGE_OVER = pose(hip=(-0.1, -0.5), torso=88, head=5, arms=(-95, -92),      # overstretched reach
                  feet=((2.0, 1.1), (2.2, 0.9)), arm_spread=14)
LUNGE = pose(hip=(0.0, -0.6), torso=85, head=3, arms=(-82, -80),
             feet=((1.8, 1.0), (2.0, 0.8)), arm_spread=12)
LUNGE_FLOAT = pose(hip=(0.0, -0.55), torso=83, head=0, arms=(-76, -78),     # slight drift while airborne
                   feet=((1.7, 1.05), (1.9, 0.9)), arm_spread=11)

# Overlapping action: these bones hit each pose a little after the body does.
LAG = {"Head": 0.05, "RightArm_FK": 0.03, "LeftArm_FK": 0.02}

ALL_BONES = list(STANCE)


# --- Keying ------------------------------------------------------------------
def depth(pb):
    return len(pb.parent_recursive)


def world_to_basis(pb, parent_mats, rots, loc):
    """Pose-bone basis that puts pb at the given armature-space rotation/location."""
    rest = pb.bone.matrix_local
    if pb.parent:
        parent_rest = pb.parent.bone.matrix_local
        base = parent_mats[pb.parent.name] @ parent_rest.inverted() @ rest
    else:
        base = rest.copy()
    r = Quaternion()
    for axis, deg in rots:
        r = Quaternion(Vector(axis), math.radians(deg)) @ r
    head = rest.translation + Vector(loc) if loc else base.translation
    target = Matrix.Translation(head) @ (r @ rest.to_quaternion()).to_matrix().to_4x4()
    basis = base.inverted() @ target
    return basis, target


def armature_matrix(pb, parent_mats):
    """Armature-space pose matrix from the bone's current basis (ignores constraints)."""
    if pb.name in parent_mats:
        return parent_mats[pb.name]
    basis = Matrix.Translation(pb.location) @ pb.rotation_quaternion.to_matrix().to_4x4()
    rest = pb.bone.matrix_local
    if pb.parent:
        m = armature_matrix(pb.parent, parent_mats) @ pb.parent.bone.matrix_local.inverted() @ rest @ basis
    else:
        m = rest @ basis
    parent_mats[pb.name] = m
    return m


last_quat = {}


def set_pose(p):
    """Set every animated bone to pose p."""
    mats = {}
    for pb in sorted((rig.pose.bones[n] for n in ALL_BONES), key=depth):
        if pb.parent:
            armature_matrix(pb.parent, mats)
        rots, loc = p[pb.name]
        basis, target = world_to_basis(pb, mats, rots, loc)
        q = basis.to_quaternion()
        prev = last_quat.get(pb.name)
        if prev is not None and prev.dot(q) < 0:
            q.negate()  # keep quaternions on the same side so nothing spins the long way round
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = q
        pb.location = basis.translation
        mats[pb.name] = target  # bones go parents-first, so children see this matrix


def make_action(name, keys):
    """keys: list of (seconds, pose). Middle keys get LAG applied per bone."""
    old = bpy.data.actions.get(name)
    if old:
        bpy.data.actions.remove(old)
    action = bpy.data.actions.new(name)
    action.use_fake_user = True  # keep it saved even when not assigned
    rig.animation_data.action = action
    for pb in rig.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
    last_quat.clear()
    for i, (seconds, p) in enumerate(keys):
        set_pose(p)
        middle = 0 < i < len(keys) - 1
        for bone_name in ALL_BONES:
            pb = rig.pose.bones[bone_name]
            last_quat[bone_name] = pb.rotation_quaternion.copy()
            t = seconds + (LAG.get(bone_name, 0) if middle else 0)
            frame = round(t * FPS)
            pb.keyframe_insert("rotation_quaternion", frame=frame)
            pb.keyframe_insert("location", frame=frame)
    print("Created action:", name)
    return action


# --- Actions -----------------------------------------------------------------
make_action("Pounce_Crouch", [
    (0.00, STANCE),
    (0.30, CROUCH_DIP),      # drop, slightly too far
    (0.45, CROUCH),          # settle back up
    (0.65, WIGGLE_R),        # rear wiggle
    (0.85, WIGGLE_L),
    (1.02, WIGGLE_R_SMALL),
    (1.20, CROUCH),
    (1.40, CROUCH),          # end pose (Studio script holds it here)
])

make_action("Pounce_Start", [
    (0.00, CROUCH),
    (0.08, SQUASH),          # coil
    (0.25, START),           # explode
])

make_action("Pounce_Lunge", [
    (0.00, START),
    (0.15, LUNGE_OVER),      # stretch past the pose
    (0.30, LUNGE),           # settle
    (0.45, LUNGE_FLOAT),     # airborne drift
    (0.60, LUNGE),           # end pose (Studio script holds it until landing)
])

rig.animation_data.action = bpy.data.actions["Pounce_Crouch"]
scene.frame_start = 0
scene.frame_end = round(1.4 * FPS)
scene.frame_set(0)
print("STUD =", STUD)
