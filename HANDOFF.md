# Creature Animation Project — Handoff Notes

Everything needed to pick this up in a new chat. Paste this file in, and attach the
script you're working on (e.g. `Blender/sprint_human.py`) when asking for changes.

Repo: https://github.com/mjm6687-cmd/Scripts
Branch with all of this work: `claude/optimistic-turing-hq76x4`
(Not merged into main yet.)

---

## 1. How the animations are made

- Rig: **R6 IK/FK Blender Rig v2.22** (https://devforum.roblox.com/t/r6-ik-fk-blender-rig-v222/3586405)
- Animations are written as **Blender Python scripts**. Paste a script into Blender's
  **Scripting** tab -> **Run Script**. It builds the action(s) on the rig.
- View an action: Dope Sheet -> **Action Editor** -> pick it from the dropdown.
- Export: select the action -> File -> Export -> FBX. Import into Studio with
  **Animation Editor -> ... -> Import -> From FBX**, then publish to get the ID.
- Re-running a script replaces the actions it makes (no duplicates).

### Rig facts (important for anyone writing new scripts)

- Two armatures:
  - `__PrimaryArmature` — the controls you animate. **Scripts only touch this one.**
  - `InternalArmature` — the real R6 parts (Torso, Right Arm...). Follows the controls; this is what gets exported.
- Control bones used:
  - `LowerTorso-FK` — **main body bone**: forward lean, twist, tilt, and moving the body up/down.
    (Rotating `Torso_FK` alone barely moves the body.)
  - `Torso_FK` — extra chest bend / chest twist on top.
  - `Head`
  - `RightArm_FK`, `LeftArm_FK` — **arms are in FK** (rotate them).
  - `RightLeg-IK`, `LeftLeg-IK` — **legs are in IK** (move the foot targets).
  - Others exist (poles, GrabPoints, Positioners, MasterControl) but aren't used.
- All bones use quaternion rotation.
- **The character faces +Y** in this rig. Scripts have `FACING = 1`; flip to `-1` if
  something plays backwards.
- Axes used in the scripts (with FACING = 1):
  - `PITCH = (-1, 0, 0)` -> + leans torso/head forward, - swings arms forward
  - `YAW = (0, 0, 1)` -> + turns toward the character's left
  - `ROLL = (0, -1, 0)` -> + moves right arm outward / tilts torso left
- Offsets are in **studs** (1 stud measured from the rig: neck is ~4 studs above the feet).
  Helper `S(x, y, z)`: x<0 = character's right, y<0 = forward, z>0 = up.
- Rotations are applied relative to the bone's rest pose and its parent
  (`rest.inverted() @ r @ rest`). A "world-space" attempt once produced **no animation
  at all** on the real rig — don't go back to that approach.
- IK safety used in the newer scripts:
  - `REACH = 1.05 * LEG` — foot never further from the hip than this (stops snapping).
  - `MIN_REACH = 0.5 * LEG` — foot never closer than this (stops the knee folding and
    the IK flipping when legs go too high).
- Quick Blender test without the real rig is possible with `pip install bpy` + a mock
  armature using the same bone names (that's how these were checked).

### Style preferences established so far

- Creature is a **10 ft heavy creature** (bug-like; "Giant_Bug_Vocals" sounds). Animate
  at normal R6 size, scale the model in Studio.
- Creature arms **barely swing** (`ARM_SWING = 0.2`) and sit lower (`ARM_DROP = 0.15`).
- **Walks/crouch walks: never keyframe the head.**
- **Idles must be upright**, not leaned forward (base lean ~1 deg).
- **Knees never lock straight** in idles/roars (body stays >= 0.2 studs below standing).
- Idle/roar stance has feet spread: `STANCE = 0.3` studs per foot.
- Head rotation limit in roars/emotes: `HEAD_MAX = 18` (aggressive roar head ~8 deg max).
- Legs going too high breaks the IK — keep knee lift moderate.

---

## 2. Blender scripts (all in `Blender/`)

| Script | Makes | Notes |
|---|---|---|
| `idle.py` | `Idle` (loop 4 s) | Upright breathing, weight shift, small head look, feet spread |
| `walk.py` | `Walk_Forward/Backward/Left/Right/ForwardLeft/ForwardRight/BackwardLeft/BackwardRight` (loop 1.3 s) | Heavy creature walk, head NOT keyed, `ARM_SWING 0.2`, `ARM_DROP 0.15` |
| `crouch_walk.py` | `Crouch_*` 8 directions (loop 1.5 s) | Low, hunched, head not keyed |
| `sprint.py` | `Sprint_Heavy` (loop 0.8 s) | Used in game as the **Jog** |
| `sprint_full.py` | `Sprint_Full` (loop 0.7 s) | Creature sprint: big strides, deep lean, flight phase |
| `extras.py` | `Crouch_Idle` (loop), `Jump`, `Fall` (loop), `Land` | Crouch idle is low but upright. Turn-in-place was removed. |
| `roar.py` | `Roar_Broadcast` 1.8 s, `Roar_Passive` 1.28 s, `Roar_Aggressive` 1.38 s | Full-body standing roars, timed to audio loudness (echo cut off) |
| `roar_moving.py` | `Roar_*_Moving` | Same roars, **head + arms only** (play while walking) |
| `emotes.py` | `Emote_LungeFakeOut`, `Emote_GroundSlam`, `Emote_StalkScan` | Idle emotes (not currently used in game) |
| `spawn.py` | `Spawn` (4.8 s) | Crawls up out of the floor (body starts ~5.6 studs underground) |
| `sprint_human.py` | `Sprint_Human` (loop) | **Normal human R6 sprint, heavy-ish — currently being worked on** |
| `pounce.py`, `idle_test.py` | old tests | Not used |

### Roar audio mapping

- Broadcast = `Giant_Bug_Vocals_4` — real roar ~0.15–1.35 s, rest is echo
- Passive = `Giant_Bug_Vocals_3` — real roar ~0.15–1.0 s
- Aggressive = `Giant_Bug_Vocals_1` — hits at 0.3 s, pulses 0.4/0.65/0.85 s, ends ~1.05 s
- `roar.py` has the loudness envelopes (`ENV_BROADCAST` etc., one value per 0.05 s)
  driving the shake/pose. Start the sound at the same moment as the animation.

---

## 3. Current state of `sprint_human.py` (the active task)

Human R6 sprint, heavy-ish. Head is **not keyed**. Current settings:

```
CYCLE = 0.54        # seconds per full stride
ARM_SWING = 1.3     # arm rotation amount
ARM_DROP = 0.18     # arms sit lower on the body
ARM_SLIDE = 0.35    # arms physically slide forward/back with the swing
REACH = 1.05 * LEG
MIN_REACH = 0.5 * LEG
```

What it does now:
- Hips lean ~21–26 deg forward + chest bend (~30 deg total at landing).
- Hips twist ~±10, chest twists ~±14 against them; hips drop ~5 deg toward the landing side.
- Forward arm swings **in across the chest** (a yaw applied *after* the swing — a roll
  did NOT work because it just spins a forward-pointing arm) and turns inward
  (twist on its own length). It **straightens as soon as it starts swinging back**.
  Back arm stays close to the side.
- Arms also **slide** forward/back (shoulder travels with the swing).
- Strides ~1.3 studs ahead / ~1.5 behind, knee lift capped ~0.9 studs, brief flight phase.

Arm tuple format in its poses: `(pitch, roll, twist, cross)` per arm.
pitch - = forward; roll + = out (right arm); twist = turn along the arm; cross + = right arm inward.

User feedback history on this one: wanted more lean, arms crossing inward like a real
sprint (only in the forward part), arms physically lower and sliding forward/back,
longer strides, no head keys, and legs not going so high that the IK breaks.

---

## 4. Roblox side (the creature game scripts)

Folders in the repo mirror the Studio Explorer. Files changed for this work:

| Script | Type | Where |
|---|---|---|
| `CreatureMovement` | LocalScript | inside the creature rig Model |
| `CreatureConfig` | ModuleScript | inside the creature rig Model |
| `CreatureRoarServer` | Script | ServerScriptService |
| `CreatureGrabServer` | Script | ServerScriptService |
| `Arm` | ModuleScript | StarterPlayerScripts > CreatureClient > Systems |
| `Footsteps` | ModuleScript | StarterPlayerScripts > CreatureClient > Systems |

### Controls & speeds

| Gait | Key | Speed |
|---|---|---|
| Crouch | Ctrl (toggle) | 5 |
| Walk | — | 8 |
| Jog | X (toggle) | 13 |
| Sprint | hold Shift | 21 |

- Roars: R = Roar1, C = Roar2, V = Roar3. Moving -> `RoarNMoving` (upper body, no lock);
  standing -> full-body `RoarN` and the creature is rooted for its length.
- Grab/eat allowed up to jog speed; sprinting locks the arm. Aiming a throw turns jog off.
- Crouching: no jog/sprint, **no footstep sounds** (detected from the playing Crouch clips
  so all players hear silence). X while crouched stands up and jogs.
- Jumping stays disabled; Fall/Land play when walking off ledges.
- Animation playback = current speed / that gait's top speed, so at full speed every clip
  plays at 1.0x. Feet sliding forward -> lower the speed; feet sliding backward -> lower
  `jogAnimSpeed` / `sprintAnimSpeed` / `crouchAnimSpeed` / `walkAnimSpeed`.

### Animation objects needed

In the rig, a Folder named **`Animations`** with Animation objects (published IDs), named exactly:

```
Idle, Jog, Sprint, Fall, Land
WalkForward, WalkBackward, WalkLeft, WalkRight,
WalkForwardLeft, WalkForwardRight, WalkBackwardLeft, WalkBackwardRight
CrouchIdle, CrouchForward, CrouchBackward, CrouchLeft, CrouchRight,
CrouchForwardLeft, CrouchForwardRight, CrouchBackwardLeft, CrouchBackwardRight
Roar1, Roar2, Roar3, Roar1Moving, Roar2Moving, Roar3Moving
```
(`CrouchBackwardsRight` spelling also accepted. Old names like StandingIdle still work.)
Roar sounds go in the RoarSounds part named Roar1/Roar2/Roar3 — numbers must match the anims.

### Open issues

1. **Arm can't be used while jogging** (user reported, after updating everything).
   Code allows it up to jog speed + slack. Last fix: Arm and CreatureGrabServer now
   default `jogSpeed` to 13 if the config lacks it. **Debug prints were added** — check
   Studio Output for:
   - `[Arm] locked: sprinting=... speed=... limit=... (walkSpeed=... jogSpeed=...)` -> client side is blocking
   - `[CreatureGrabServer] Grab refused: ...` -> server is rejecting
   Not yet confirmed fixed. Remove `DEBUG_ARM_LOCK` and the server warn once it works.
2. Footsteps are marker-driven ("Footstep" marker). The Blender animations have no markers,
   so the distance fallback (every 3.2 studs) is used. Add markers in the Animation Editor
   for exact steps.
3. Speeds/anim speeds still being tuned in Studio.
