# Test animation for the R6 IK/FK Blender rig (v2.22).
# Run in Blender: Scripting tab > New/Open > Run Script.
# Creates a looping 2-second "Idle_Test" action on __PrimaryArmature.
import bpy
import math
from mathutils import Quaternion, Vector

RIG_NAME = "__PrimaryArmature"
ACTION_NAME = "Idle_Test"
LENGTH = 60  # frames (2 seconds at 30 fps)

# Armature-space axes. If a motion goes the wrong way, flip the sign of the degrees.
PITCH = (1, 0, 0)  # lean forward/back
YAW = (0, 0, 1)    # turn left/right
ROLL = (0, 1, 0)   # tilt sideways

rig = bpy.data.objects[RIG_NAME]
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='POSE')

rig.animation_data_create()
action = bpy.data.actions.new(ACTION_NAME)
rig.animation_data.action = action


def key(bone_name, frame, rot=(), loc=None):
    """rot: list of (axis, degrees) in armature space. loc: armature-space offset."""
    pb = rig.pose.bones[bone_name]
    rest = pb.bone.matrix_local.to_quaternion()
    r = Quaternion()
    for axis, deg in rot:
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


# Frame 0 and LENGTH are the same pose so the loop is seamless.
for f in (0, LENGTH):
    key("Torso_FK", f)
    key("Head", f)
    key("RightArm_FK", f)
    key("LeftArm_FK", f)

mid = LENGTH // 2
key("Torso_FK", mid, rot=[(PITCH, -2)])              # chest lifts slightly
key("Head", mid, rot=[(PITCH, 3), (ROLL, 2)])        # small head tilt
key("RightArm_FK", mid, rot=[(ROLL, 4)])             # arms drift out a bit
key("LeftArm_FK", mid, rot=[(ROLL, -4)])

for fc in all_fcurves(action):
    fc.modifiers.new('CYCLES')

scene = bpy.context.scene
scene.frame_start = 0
scene.frame_end = LENGTH
scene.frame_set(0)
print("Created action:", ACTION_NAME)
