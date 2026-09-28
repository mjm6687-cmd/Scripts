-- CreatureConfig
-- CLASS: ModuleScript
-- PLACE IN: the creature rig Model (direct child, sibling of Humanoid)
--
-- Per-creature tuning, read by CreatureMovement and CreatureFootsteps.
-- Each creature rig carries its own copy, so a slow heavy creature and a twitchy
-- fast one can share the same scripts with different numbers.

return {
	--[[
		=====================
		SYSTEMS  (read by CreatureClient)
		=====================
		Switch whole systems off for THIS creature. Anything not listed is ON, so
		an empty table (or no table at all) means everything runs.

		This is what makes each creature template a different thing rather than the
		same creature with different numbers ? a blind one, a mute one, one that
		can't grab.

		Valid keys:
		  head        neck follows the camera
		  arm         reach, grab, carry, eat
		  eyes        blinking
		  footsteps   marker-driven step sounds
		  camera      zoom clamp + hidden inventory
		  mouse       centre-lock and the Z release
		  vision      red world + hex grid
		  nightvision the N light amplification
		  thermal     red outlines on humanoids
		  roar        R / C / V

		? camera and mouse are the two to think twice about. Off, that creature
		gets a normal third-person camera and a free cursor ? a legitimate design
		choice, but it plays very differently.
	--]]
	systems = {
		-- thermal = false,
		-- nightvision = false,
		-- roar = false,
	},

	-- =====================
	-- SPEED
	-- =====================
	walkSpeed = 8,             -- normal movement speed (WalkForward etc.). Was 9
	accelWalk = 20,            -- studs/s^2 ramp up   (lower = heavier wind-up)
	decelWalk = 26,            -- studs/s^2 ramp down (lower = longer coast)
	speedSnapThreshold = 0.5,  -- below this while stopping, snap to 0

	-- =====================
	-- JOG  (X toggles)
	-- =====================
	-- The in-between gait. Toggled, not held. You can still grab and eat while
	-- jogging (the arm only locks at sprint speed); aiming a throw drops you
	-- back to a walk and turns the jog off. No jogging sideways or backwards --
	-- strafing falls back to the walk speed. Shift from a jog goes to a sprint.
	jogSpeed = 13,
	accelJog = 16,             -- studs/s^2 ramp up to jog speed
	decelJog = 22,             -- studs/s^2 ramp down while above walk speed
	jogAnimSpeed = 1.0,        -- playback rate of the Jog clip at full jog speed
	jogAnimBlendPoint = 0.5,   -- 0-1 between walk and jog speed: where the Jog clip takes over
	jogLeanMult = 1.25,        -- body lean while jogging (sprint uses sprintLeanMult)

	-- =====================
	-- CROUCH  (Ctrl toggles)
	-- =====================
	-- Slow and silent: crouch clips play no footsteps. Crouching turns the jog
	-- off and blocks sprinting; pressing X while crouched stands up and jogs.
	crouchSpeed = 5,
	crouchAnimSpeed = 1.0,     -- playback rate of the Crouch clips at full crouch speed
	crouchLeanMult = 0.6,      -- less body lean while crouched

	-- =====================
	-- SPRINT  (hold Shift)
	-- =====================
	-- Same walk animation and same footstep clips ? only faster, lower and
	-- heavier. Everything here is deliberately WORSE than the walk equivalent;
	-- that gap is what the weight is made of.
	sprintSpeed = 21,  -- was 27 (26, 19, briefly 35)

	accelSprint = 13,   -- was 9. Walk (8) to sprint (21) in roughly 1s
	-- a visible wind-up instead of an instant snap.
	decelSprint = 18,   -- was 14
	-- and you can't just stop. Also applies while slowing
	-- DOWN from a sprint, not only while holding shift.

	turnRateSprint = 150,  -- vs turnRateWalk 300. Half the turn rate = wide arcs.
	sprintStiffness = 45,  -- vs idleStiffness 70. Softer spring, so the body is
	-- SLOW TO START coming round, not merely slow to rotate.
	-- This is the single biggest "heavy" contributor.
	sprintDamping = 9,     -- vs idleDamping 11. A little more overshoot at the
	-- end of a turn, like mass settling.

	sprintLeanMult = 1.6,  -- body throws itself further into the movement

	-- ---- sprint animation ----
	-- An Animation named "Sprint" in the rig's Animations folder. With one there,
	-- it plays instead of the walk cycle while sprinting. Without one, the walk
	-- cycle speeds up to cover it and everything still works.
	-- Playback multiplier for the Sprint clip at full sprint speed. The Sprint
	-- clip is now a real sprint (not the walk cycle sped up), so 1.0 is the
	-- starting point: lower if the legs look frantic, higher if the feet slide.
	sprintAnimSpeed = 1.0,  -- was 1.4 while the walk cycle stood in for a sprint
	sprintAnimBlendPoint = 0.25, -- 0-1 between jog (13) and sprint (21) speed: the sprint cycle takes over at ~15 studs/s
	-- sprint cycle takes over when you're above walk
	-- pace without holding Shift (coasting down).

	-- Only used when there is NO Sprint animation and the walk cycle is standing
	-- in for one. Below 1.0 the legs under-rotate and you get deliberate skidding
	-- weight; 1.0 keeps the feet planted. Above 1.0 looks frantic.
	sprintAnimSpeedMultiplier = 1.0,

	sprintMaxTurnAngle = 60,      -- deg; cornering harder than this drops the sprint
	sprintSlopeCutoffAngle = 30,  -- deg; no sprinting up anything steeper
	sprintMinSpeedToStart = 3,    -- must already be moving this fast to start

	-- Footstep audio while sprinting. Lower pitch, louder ? heavier impact is a
	-- LOWER sound. The cadence already speeds up on its own, since the animation
	-- is playing faster.
	sprintPitchMin = 0.82,
	sprintPitchMax = 0.96,
	sprintVolumeMultiplier = 1.25,

	-- =====================
	-- BODY LEAN (movement tilt through RootJoint.C0)
	-- =====================
	movementLeaning = true,
	maxLeanAngle = 0.18,       -- radians at full tilt; 0.12 subtle, 0.3 very loose

	-- =====================
	-- TERRAIN ALIGNMENT (upper body follows slope normal)
	-- =====================
	terrainAlign = true,
	terrainAlignMaxAngle = 10, -- degrees
	terrainAlignRayLength = 8, -- studs probed below the root

	-- =====================
	-- TURNING (yaw spring)
	-- =====================
	-- The body turns on a spring: displacement * stiffness - velocity * damping.
	-- Lower damping = more overshoot/wobble, which reads as "heavy animal".
	turnRateWalk = 300,        -- deg/s cap while moving
	turnRateAir = 140,         -- deg/s cap while airborne
	idlePivotRate = 260,       -- deg/s cap while turning in place from a standstill
	idleStiffness = 70,
	idleDamping = 11,
	idleMoveThreshold = 55,    -- deg; from idle, start walking once facing within this
	turnSpeedStopThreshold = 0.8, -- studs/s below which we count as standing still

	-- Directional momentum (first person / shift lock only).
	-- Lower = heavier; a hard reversal bleeds more speed before rebuilding.
	dirResponse = 9,

	-- =====================
	-- SLOPES (uphill only)
	-- =====================
	slopeFullAngle = 12,       -- deg; gentler climbs don't slow you
	slopeSteepAngle = 45,      -- deg; at/above this you're at slopeMinMult
	slopeMinMult = 0.65,       -- speed multiplier on the steepest climb

	-- =====================
	-- STRAFING
	-- =====================
	strafeSpeedMultiplier = 0.85,

	-- =====================
	-- ANIMATION
	-- =====================
	animBlendTime = 0.4,       -- was 0.2. Crossfade between movement anims
	useHigherAnimPriority = false,
	walkAnimSpeed = 1.0,       -- global playback multiplier at full walk speed
	-- Per-direction overrides; nil falls back to walkAnimSpeed.
	walkAnimSpeed_Forward      = nil,
	walkAnimSpeed_Backward     = nil,
	walkAnimSpeed_Left         = nil,
	walkAnimSpeed_Right        = nil,
	walkAnimSpeed_LeftDiag     = nil,
	walkAnimSpeed_LeftDiagRev  = nil,
	walkAnimSpeed_RightDiag    = nil,
	walkAnimSpeed_RightDiagRev = nil,

	-- =====================
	-- TURN-IN-PLACE ANIMS
	-- =====================
	turnYawThreshold = 3,      -- deg accumulated before the turn anim fires
	turnJitterIgnore = 0.15,   -- deg; per-frame deltas under this are noise
	turnAccumulateDecay = 8,   -- deg/s the accumulator bleeds back to zero
	turnAnimHoldTime = 0.2,    -- seconds the anim keeps playing after turning stops

	-- =====================
	-- IDLE EMOTES (head twitches, sniffing, look-arounds)
	-- =====================
	idleEmoteMinTime = 8,
	idleEmoteMaxTime = 35,

	-- =====================
	-- FALLING / LANDING
	-- =====================
	-- No jumping, but the creature can still walk off ledges.
	prolongedFallThreshold = 0.35, -- seconds airborne before it counts as a real fall
	landingLockDuration = 0.5,     -- seconds pinned after a real landing
	landingDecel = 80,             -- WalkSpeed bleed rate during the landing lock
	landingVelocityDamp = 9,       -- horizontal momentum kill rate on landing

	-- =====================
	-- CAMERA  (read by CreatureCamera)
	-- =====================
	-- Zoom is clamped to this range while you're the creature, and restored to
	-- whatever the player had when you morph back. A minimum above 0.5 is what
	-- actually blocks first person ? CameraMode alone doesn't hold.
	cameraMinZoom = 3,
	cameraMaxZoom = 16,

	-- false: the body turns to face where it's going (the yaw spring drives
	--        everything). This is what you want with a center-locked mouse ?
	--        the mouse steers the CAMERA, the keys steer the BODY.
	-- true:  the body locks to the camera and strafes, like shift lock. Needs the
	--        seven directional strafe animations to look right.
	bodyFollowsCamera = false,

	-- =====================
	-- ARM REACH / GRAB  (read by CreatureArm)
	-- =====================
	-- R6 has no elbow, so this is shoulder aiming rather than real IK: two angles
	-- point the single arm part at a target, and a small shoulder push sells the
	-- extension. Hold left click to reach, click again while holding someone to eat.
	--
	-- NOTE: the SERVER has its own copies of grabRange and grabConeAngle in
	-- CreatureGrabServer, deliberately a bit looser than these to allow for lag.
	-- Raising the numbers here alone won't let you grab further ? the server
	-- would refuse. Raise both.
	-- AIMED WITH THE CAMERA. The arm reaches exactly where you're looking; it does
	-- not seek out a victim or drift toward one. A grab lands when the HAND ends
	-- up on somebody, so grabTouchDistance is the real difficulty dial.
	grabRange = 8,             -- studs the arm can reach
	grabTouchDistance = 4.5,   -- studs from the hand that counts as a catch.
	-- Raise for a more forgiving grab, lower to make
	-- the player genuinely connect.
	grabConeAngle = 70,        -- no longer used for aiming; kept because the
	-- SERVER still cone-checks (at a wider 120?) to
	-- reject grabs behind the creature.

	-- Shoulder limits applied to the camera aim, in degrees. ASYMMETRIC, because
	-- this is the RIGHT arm: swinging right is away from the body and barely
	-- limited, swinging LEFT crosses the chest and a rigid limb rotating about a
	-- right-side shoulder passes straight through the torso.
	armMaxYawOutward = 110,    -- away from the body (right, for a right arm)
	armMaxYawAcross = 32,      -- across the chest. Lower this if it still clips.
	armMinRise = 5,            -- 0 = straight down
	armMaxRise = 165,          -- 90 = level, 180 = straight up

	-- Carrying: you aim freely, but the arm sags below the aim so the weight reads.
	armCarryDroop = 18,        -- degrees below where you're pointing

	-- HOLD-TO-EAT. Holding click lifts the victim toward the mouth in proportion
	-- to how long it's been down; the bite only lands at 100%. Let go early and
	-- they come back down.
	eatChargeTime = 0.85,      -- seconds of holding to reach the mouth
	eatReleaseSpeed = 2.2,     -- how fast the charge falls when you let go

	-- CHEWING. Once the victim reaches the mouth they aren't killed instantly ?
	-- they're worked on: a run of crunches, each with a bone-crack sound, a small
	-- blood spatter, a jolt of the arm and a bite of health. The kill and the
	-- decapitation land on the last one.
	-- Count, spacing, damage and spatter size live at the top of
	-- CreatureGrabServer (CHEW_COUNT, CHEW_INTERVAL, CHEW_DAMAGE_FRACTION,
	-- CHEW_BLOOD_SCALE), since the server owns the timing.
	chewShakeAmount = 8,       -- degrees of arm jolt per crunch. The direction
	-- alternates, so it reads as tearing side to side
	-- rather than nodding. 15+ gets violent.
	grabMinExtend = 0.8,       -- how far out the arm must be (0-1) before it can
	-- catch anyone. Stops the grab landing on the first
	-- frame of the click while the arm is still at the
	-- creature's side. Lower = snappier, less of a lunge.
	armStiffness = 40,         -- LOWER = heavier arm
	armDamping = 9,
	armMaxSpeed = 420,         -- deg/s cap on the arm swing
	armExtendPush = 0.35,      -- studs the shoulder shifts toward the target
	armReturnStiffness = 22,   -- softer spring used when relaxing back to rest
	armSendInterval = 1 / 12,  -- how often arm angles go to the server
	armSendMinDelta = 2,       -- deg of change before it bothers sending

	-- ---- making one rigid part read as a limb ----
	-- R6 has no elbow, so aiming a single part at a target gives you a stick
	-- pointing at a thing. These put back the parts of a reach that aren't the
	-- elbow: the PATH the hand takes, the TWIST of the limb, and the fact that a
	-- held pose is never perfectly still.
	armReachArc = 24,        -- deg of extra lift through the MIDDLE of the reach,
	-- zero at both ends. Biggest single improvement ? the
	-- hand curves up and comes down instead of travelling
	-- in a straight line. Push to 35 for a big overhand
	-- swipe, drop to 10 for a quick snatch.
	armRollFactor = 0.5,     -- twist as the limb swings across the body.
	-- 0 = none (broom handle), 1 = fully follows the yaw.
	-- Matters most with claws or spikes welded on.
	-- (armAimHeightBias removed ? it existed to angle the arm when the code chose
	--  the target. With camera aiming the player supplies the angle themselves.)
	armSwayAmount = 3.5,     -- deg of drift while extended, so a held pose isn't a
	-- freeze-frame. Felt, not seen ? 8+ looks drunk.
	armSwaySpeed = 1.5,

	-- Where the arm sits while CARRYING somebody, relative to the torso.
	-- Forward + down + out. Never level, never straight in front ? that pose is
	-- the one that reads as a plank with a body hanging off it.
	armCarryForward = 4.5,
	armCarryDown = 2.2,      -- weight pulling the arm toward the ground
	armCarryOut = 1.6,       -- clear of the body rather than in front of it

	--[[
		---- THE VICTIM'S POSE WHILE HELD ----
		What the person in your hand is doing. Without it they keep playing whatever
		they were doing when grabbed ? usually the walk cycle, legs pumping in
		mid-air, which is the single thing that most gives away that they're a
		puppet on a weld.

		Played from the SERVER at Action4, so everyone sees it and it beats their
		own movement animations. It's per-CREATURE rather than global because how a
		victim hangs depends on how the thing holding them holds them ? by the
		throat and by the ankle are different poses.

		Author it looping: a slight sway reads far better than a frozen frame.
	--]]
	victimGrabAnim = "rbxassetid://100352384844197", -- "" for none

	-- ---- procedural eat ----
	-- Put an Attachment named MouthAttachment in the Head (or HumanoidRootPart)
	-- and drag it to where the bite should happen. The arm brings the victim to
	-- that exact point.
	--
	-- Blood emitters are DIRECT CHILDREN of that attachment, grouped by NAME:
	--     BiteBlood_Spray, BiteBlood_Mist   -> fire on each chewing crunch
	--     KillBlood_Burst, KillBlood_Gush   -> fire on the killing bite
	--     anything else                     -> fires on both
	--
	-- NOT folders. A ParticleEmitter must be a direct child of a BasePart or an
	-- Attachment; that is what gives it a position. Inside a Folder it has nowhere
	-- to emit from and renders NOTHING, while Emit() still succeeds silently.
	-- (An attribute BloodGroup = "Bite" or "Kill" overrides the name if you'd
	--  rather not rename.)
	mouthAttachmentName = "MouthAttachment",
	armHandLength = 2,          -- studs from the shoulder joint to the grip point.
	-- Measure it: joint at the top of the arm, grip
	-- near the bottom. Wrong value = hand stops short
	-- of the mouth or punches through the head.

	--[[
		THE SHOULDER HAS TO MOVE, usually a long way DOWN.

		The hand can only ever sit on a sphere of radius armHandLength around the
		shoulder joint ? and the mouth is INSIDE that sphere. So the only way to
		put the hand on the mouth is to move the joint away from it, which for a
		mouth above the shoulder means sinking the shoulder down and back.

		eatMaxShoulderShift caps that movement. Set too low it truncates exactly
		the motion the solve asked for, and the hand waves near the face instead of
		reaching it. IF THE HAND STILL FALLS SHORT, RAISE THIS FIRST.
	--]]
	eatMaxShoulderShift = 3.5,  -- studs the shoulder may travel (was 1.4)
	eatShoulderDrop = 1.1,      -- extra deliberate sink on top of the solve, so it
	-- reads as hunching into the bite
	eatShoulderResponse = 4,    -- how fast it follows. LOWER = heavier and less
	-- snappy. Was 10, which was most of the snap.
	eatSoftening = 0.35,        -- the spring SOFTENS as the victim nears the mouth
	-- instead of stiffening. 0 = off, 0.6 = laboured.
	chewAttack = 0.35,          -- fraction of each crunch spent moving INTO the
	-- jolt. Near 0 is a snap; higher is heavier.
	chewSmoothing = 9,          -- THE anti-snap dial. The jolt is a fast, large
	-- step, and applied raw the arm teleports to each
	-- point on the curve instead of travelling there.
	-- This makes it follow. LOWER = heavier and softer.

	-- AFTER THE KILL the body stays in the hand for a moment, then the arm tosses
	-- it aside (about two seconds from kill to landing). How long it's held, how
	-- long the swing takes and how hard it's tossed live at the top of
	-- CreatureGrabServer (CORPSE_HOLD_TIME, CORPSE_TOSS_TIME, CORPSE_TOSS_FORWARD /
	-- SIDE / UP). CORPSE_HOLD = false puts back the instant drop.

	-- Eating is HOLD-to-eat all the way through: let go of left click during the
	-- chewing and it aborts ? the victim survives, stays in your hand, and the arm
	-- lowers. Right click still drops them outright, mid-chew included.

	-- (eatRaiseTime / eatHoldTime / eatReturnTime are gone. The raise is driven by
	--  how long you hold the button now, so there is no fixed timeline for the
	--  client and server to keep in sync ? which also retires the trap where those
	--  three had to be edited in two files at once.)

	-- =====================
	-- THROW  (read by Arm AND CreatureGrabServer -- keep them reading the same keys)
	-- =====================
	-- While carrying someone: TAP right click to drop them. HOLD right click to aim
	-- -- a red arc shows where they'll land -- and LEFT click while holding to throw.
	-- Let go of right click without throwing and they stay in your hand.
	--
	-- The first thing they hit (floor, wall, anything) does throwDamage, then they
	-- stay ragdolled for throwRagdollTime before getting up. They can't be grabbed
	-- again until they're up.
	-- HOLD TO CHARGE. The longer right click is held, the further back the arm
	-- winds (and trembles at full), and the harder the throw.
	throwSpeedMin = 45,       -- studs/s at launch with no charge (a quick flick)
	throwSpeedMax = 140,      -- studs/s fully charged. Higher = further and flatter
	throwChargeTime = 1.2,    -- seconds of holding right click to reach full charge
	throwWindupMin = 0.07,    -- fully charged the arm is already back; this is all that's left
	throwChargeShake = 1.5,   -- deg of tremble in the cocked arm at full charge
	throwUpBias = 14,         -- deg added to your aim, so looking level still arcs.
	-- This is the arc you START with: SCROLL while aiming to change it, down
	-- for a flatter throw, up for a higher lob. It stays where you leave it.
	throwArcMin = -10,        -- deg; the flattest you can scroll to
	throwArcMax = 40,         -- deg; the highest lob
	throwArcStep = 4,         -- deg per scroll notch
	throwAimSpeedMultiplier = 0.45, -- walk speed while aiming (0.45 = 45%)
	throwMinPitch = -20,      -- deg; lowest you can aim (stops spiking into the floor)
	throwMaxPitch = 65,       -- deg; highest
	throwOriginUp = 1.5,      -- where they launch from, relative to the root:
	throwOriginRight = 1.5,   -- up and to the right, roughly the right hand
	throwDamage = 75,         -- on impact. Massive on purpose
	throwKillCharge = 0.85,   -- charged at least this much (0-1) = kills on impact

	-- BOWLING: anyone the thrown body flies past gets knocked down and ragdolled.
	throwKnockRadius = 4,     -- studs from the flying body that counts as a hit
	throwKnockMinSpeed = 25,  -- the body has to be moving this fast to knock anyone
	throwKnockTime = 3,       -- seconds they stay down
	throwKnockForce = 0.6,    -- fraction of the body's speed they get sent flying with
	throwKnockDamage = 10,    -- damage to each person hit (0 = none)
	throwRagdollTime = 2,     -- seconds down after they land
	throwTapTime = 0.25,      -- right click shorter than this counts as a tap (drop)
	throwAimDelay = 0.12,     -- how long right click is held before the arc appears

	-- Over-the-shoulder camera while aiming (and through the throw itself). The body
	-- turns to face your aim while it's on.
	throwAimShoulderRight = -3.4, -- studs the camera shifts right. NEGATIVE = left shoulder (was -2.4)
	throwAimShoulderUp = 1.0,     -- and up
	throwAimZoom = 5.5,           -- camera distance while aiming. Lower = closer (was 7)
	throwAimCameraSpeed = 9,      -- how fast it eases in and out

	-- The throw animation: the arm cocks back behind the head, then whips forward
	-- and down. The victim is still in the hand, so they get swung with it, and
	-- they leave the hand partway through the whip.
	throwWindupTime = 0.34,   -- seconds cocking back on an UNCHARGED throw (less the more you charged)
	throwWhipTime = 0.12,     -- seconds snapping forward. Shorter = more violent
	throwReleaseAt = 0.65,    -- 0-1 through the whip: when they leave the hand
	throwFollowTime = 0.3,    -- follow-through before the arm settles
	throwWindupRise = 200,    -- deg. 180 is straight up; past it is cocked behind the head
	throwWindupYaw = -40,     -- deg. Negative = out to the side
	throwWindupExtend = 0.35, -- 0-1 how far out the arm is while cocked
	throwWhipRise = 70,       -- deg. Where the arm finishes: forward and down
	throwWhipYaw = 12,        -- deg. Slightly across the body

	-- =====================
	-- LEFT HAND WHILE EATING  (read by Systems > Arm)
	-- =====================
	-- As the victim is lifted to the mouth, the left hand comes in and grabs their
	-- body too, so both hands push them in; the chew crunches jolt both arms.
	-- Cosmetic, and everyone sees it.
	leftArmEat = true,        -- false = the eat stays one-handed
	leftArmStiffness = 35,    -- LOWER = heavier, slower arm
	leftArmDamping = 9,
	leftArmMaxSpeed = 360,    -- deg/s
	leftArmGripUp = 0.4,      -- studs above the victim's torso centre the hand aims (the chest)
	leftArmMaxYawAcross = 55, -- deg the left arm may swing across the chest. Lower if it clips
	leftArmChewJolt = 1,      -- share of each chew crunch the left arm takes

	-- =====================
	-- TORSO LAYER  (read by Systems > Arm)
	-- =====================
	-- The upper body moves with the arm: it twists and leans back as a throw
	-- winds up, snaps round and leans into the whip, leans into a reach, leans
	-- away from someone being carried, hunches into the bite. It bends at the
	-- WAIST: the hips are turned back by the same amount, so the legs stay
	-- planted and keep walking. Everyone sees it.
	-- Yaw: negative turns the right shoulder back. Lean: negative = forward.
	torsoLayer = true,        -- false = the torso never moves for the arm
	torsoFollowYaw = 0.4,     -- share of the arm's swing the shoulders turn with
	torsoMaxYaw = 40,         -- deg, either way
	torsoMaxLeanForward = 20, -- deg
	torsoMaxLeanBack = 15,    -- deg
	torsoMaxRoll = 10,        -- deg of side lean
	torsoStiffness = 30,      -- LOWER = heavier, slower body. 15 sluggish, 60 snappy
	torsoDamping = 8,
	torsoMaxSpeed = 300,      -- deg/s
	torsoThrowStiffness = 110, -- during a throw, so the body keeps up with the whip
	torsoWindupYaw = -30,     -- arm cocked back: right shoulder pulled back...
	torsoWindupLean = 10,     -- ...and leaning back
	torsoWhipYaw = 25,        -- the snap: shoulders round the other way...
	torsoWhipLean = -14,      -- ...leaning forward into it
	torsoReachLean = -7,      -- leaning into an empty-handed reach
	torsoCarryRoll = 4,       -- leaning away from the weight in the hand
	torsoEatLean = -10,       -- hunching into the bite
	torsoChewJolt = 0.4,      -- share of each chew crunch the whole body takes

	-- =====================
	-- HUM  (read by Systems > Hum)
	-- =====================
	-- A quiet background hum only you hear while you're the creature. Fades in on
	-- morph, out when you stop being it. Turn off per creature with
	-- systems = { hum = false }.
	humSoundId = "rbxassetid://9126099595",
	humVolume = 0.15,     -- quiet on purpose. 0.3 is noticeable, 0.05 barely there
	humFadeTime = 2.5,    -- seconds to fade in / out
	humPitch = 1,         -- below 1 = deeper and slower

	-- =====================
	-- HEAD TURNING  (read by CreatureHead)
	-- =====================
	-- The head is on a spring, not a lerp ? it has to overcome its own inertia to
	-- start moving, then overshoots slightly and settles.
	headYawLimit = 45,        -- deg left/right before the head stops following
	headPitchLimit = 20,      -- deg up/down
	headStiffness = 28,       -- LOWER = heavier. The main dial. 15 = very sluggish,
	-- 50 = alert and quick, 100+ = basically a lerp.
	headDamping = 7,          -- lower = more overshoot and wobble on arrival.
	-- Keep it near sqrt(4*stiffness)?10 for a clean
	-- settle; go under for a visible double-take.
	headMaxSpeed = 220,       -- deg/s cap, so a fast camera flick can't snap it
	headCenterWhenSprinting = 0.7, -- 0 = look freely while sprinting,
	-- 1 = head locked forward. Sprinting should
	-- commit the head to the direction of travel.
	headSendInterval = 1 / 12,     -- how often your aim goes to the server
	headSendMinDelta = 1.5,        -- deg of change before it bothers sending

	-- =====================
	-- ROARING  (read by CreatureRoarServer) ? keys R, C, V
	-- =====================
	-- Sounds live in a Part named RoarSounds inside the HumanoidRootPart:
	--     RoarSounds > Roar1 > Near (Sound) + Distant (Sound)
	-- Several Near1/Near2/... in a folder are picked from at random.
	roarPartName = "RoarSounds",
	roarCooldown = 3.5,            -- seconds between roars
	roarCount = 3,                 -- keys 1..N are bound

	-- NEAR layer ? the detailed roar you hear up close.
	-- roarNearMinDistance is the "volumetric" trick: the sound stays at FULL
	-- volume anywhere inside this radius instead of falling off from the first
	-- stud, so it feels like a wall of noise rather than a point source.
	roarNearMinDistance = 40,
	-- The near layer carrying too far is the #1 reason a roar never sounds
	-- distant: its detail has to DISAPPEAR before the muffled layer can take over.
	-- If roars still sound close from far away, lower this before anything else.
	roarNearMaxDistance = 190,
	roarNearVolumeMult = 1.0,

	-- DISTANT layer ? a duller, longer clip that carries much further. Buried
	-- under the near layer close up; the only thing left far away, so the roar
	-- rolls across the map instead of just disappearing.
	roarDistantMinDistance = 160,
	roarDistantMaxDistance = 1600,
	roarDistantVolumeMult = 0.9,

	--[[
		---- PER-ROAR RANGE ----

		The six values above are the fallback; this overrides them per roar. Range
		IS the meaning here ? a sound the whole map hears reads as an announcement,
		and one that dies at thirty studs reads as something said to you
		specifically. Anything you leave out falls through to the defaults.

		  1 (R)  BROADCAST    calling across the map. Huge flat core, enormous tail.
		  2 (C)  PASSIVE      close range, not a threat. Intimate, almost no tail:
		                      you have to be near it to know it happened.
		  3 (V)  AGGRESSIVE   a threat to whoever is nearby. Loudest up close
		                      (nearVolume 1.15) and carries well, but not map-wide ?
		                      it's aimed at someone, not announced.

		nearMin is the "volumetric" dial: full volume anywhere inside it, so a big
		one feels like a wall of noise rather than a point source. nearMax is what
		decides whether it sounds far away ? the close detail has to DISAPPEAR
		before the muffled distant layer can take over.
	--]]
	roarProfiles = {
		[1] = { -- broadcast
			nearMin = 70, nearMax = 320, nearVolume = 1.0,
			distantMin = 280, distantMax = 3000, distantVolume = 1.0,
		},
		[2] = { -- passive
			nearMin = 14, nearMax = 85, nearVolume = 0.8,
			distantMin = 75, distantMax = 420, distantVolume = 0.5,
		},
		[3] = { -- aggressive
			nearMin = 40, nearMax = 180, nearVolume = 1.15,
			distantMin = 160, distantMax = 1100, distantVolume = 0.85,
		},
	},

	--[[
		---- WHAT THE ROAR DOES TO EVERYONE ELSE ----
		Anyone in earshot ? players and victims, not the creature itself ? gets a
		screen reaction: colour drains out, a blur pulse, a vignette closing in
		from the edges, and an FOV punch. No screen shake.

		All of it runs on ONE envelope, a fast attack and a slow decay. Effects
		with their own separate timings read as several things happening at once
		rather than as one event, and the moment a player can pick them apart the
		illusion is over.

		The radius comes from the roar's OWN profile above (the distant layer's
		reach), so the broadcast roar hits far more people than the passive one
		with nothing extra to set. If you can hear it, you feel it. Intensity falls
		off per player, so someone at the edge of earshot gets a hint and someone
		standing underneath gets the lot.
	--]]
	--[[
		---- WHAT THE ROAR DOES TO EVERYONE ELSE ----
		Anyone in earshot ? players and victims, not the creature itself ? gets a
		screen reaction. No screen shake.

		BUILT ON THE RADIATION MODEL, because that one already works: one 0..1
		level drives colour, blur, bloom and a real radial vignette, and every one
		of them gets math.noise jitter on top.

		THE JITTER IS THE TRICK. A value easing smoothly to zero reads as a tween,
		because nothing in the world moves like that. math.noise is smooth but
		irregular, so contrast and brightness crawl and shudder rather than glide.
		That matters more over a 12-second tail than a 2-second one: the longer an
		effect lasts, the more obvious a mathematically perfect fade becomes.

		THE THREE CURVES. A 12s decay applied flat would be twelve seconds of heavy
		contrast and sixteen studs of blur ? unplayable. So the level falls
		linearly and each effect reads it through its own exponent; higher collapses
		sooner. The hit is violent, most clears in a second or two, and a faint grey
		tail takes the full twelve to let go. Which is how it works: the
		disorientation passes quickly, being rattled does not.

		RADIUS is capped independently of the audio (roarFxMaxRadius). Audio range
		says "this happened"; effect radius says "this happened TO YOU".
	--]]
	roarFx = true,
	roarFxRadiusMult = 0.85,    -- fraction of the distant layer's reach
	roarFxMaxRadius = 650,      -- HARD CAP on that, whatever the roar's audio range
	roarFxAffectsCreatures = false, -- other creatures shrug it off
	roarFxAttack = 0.06,
	roarFxDecay = 12,
	roarFxColorCurve = 1.9,
	roarFxBlurCurve = 3.5,
	roarFxBloomCurve = 2.6,
	roarFxFovCurve = 5,
	roarFxSaturation = -0.8,
	roarFxContrast = 0.65,
	roarFxBrightness = -0.12,
	roarFxTint = Color3.fromRGB(255, 205, 195),
	roarFxContrastJitter = 0.22,
	roarFxContrastJitterSpeed = 5,
	roarFxBrightnessJitter = 0.16,
	roarFxBrightnessJitterSpeed = 11,
	roarFxBloomJitter = 1.6,
	roarFxBloomJitterSpeed = 3.4,
	roarFxBlur = 16,
	roarFxBloom = 7,
	roarFxBloomSize = 24,
	roarFxBloomThresholdIdle = 2,
	roarFxBloomThresholdFull = 0.85,
	roarFxVignetteImage = "rbxassetid://260155349",
	roarFxVignetteColor = Color3.fromRGB(14, 10, 10),
	roarFxVignette = 0.88,
	roarFxVignetteSize = 0.34,
	roarFxVignettePulse = 0.07,
	roarFxVignettePulseSpeed = 2.4,
	roarFxFov = 7,
	roarFxRingAsset = "rbxassetid://9069161602",
	roarFxRingVolume = 0.35,
	roarFxRingMinIntensity = 0.05,
	roarFxFalloff = 1.6,
	roarFxMinIntensity = 0.02,
	roarFxCombatMusic = true,
	roarFxCombatMinIntensity = 0.35,

	--[[
		---- THE VISIBLE SHOCKWAVE (read by Systems > RoarWave) ----
		ForceField spheres bursting out from the mouth, seen by everyone. Each
		roar has its own look:
		R a huge slow layered wave, C one small pulse, V a fast hard one. All
		white at 0.8 transparency by default.

		roarWave = false switches it off for this creature. roarWaves overrides
		any of these per roar; anything left out keeps the built-in value:

		  radius        studs the outermost shell reaches
		  duration      seconds to get there and fade
		  rings         how many shells
		  ringGap       seconds between shells
		  ringShrink    each later shell's size vs the one before (0-1)
		  color         the ForceField glow colour
		  transparency  how see-through each shell starts (1 = invisible)

		e.g. roarWaves = { [1] = { radius = 250, color = Color3.fromRGB(255, 255, 255) } }
	--]]
	roarWave = true,
	roarWaves = {},

	-- ---- roar animations ----
	-- ONE per roar, in the rig's Animations folder: Roar1, Roar2, Roar3.
	-- (Falls back to a single "Roar" if a numbered one is missing.)
	--
	-- The same clip plays whether you're standing or walking, which puts one
	-- requirement on it: AUTHOR IT WITH NO KEYFRAMES ON THE LEGS. The walk cycle
	-- then keeps driving them underneath and the two blend on their own ? that's a
	-- property of the animation data, not something the code arranges, and it's
	-- exactly why one clip can cover both cases.
	--
	-- If the clip DOES move the legs it will override the walk and the creature
	-- will appear to skate while bellowing. That's what roarLockMovement is for:
	-- switch it on and you're rooted for the clip's length, at the cost of not
	-- being able to roar on the move.
	roarLockMovement = false,
	roarLockFallbackTime = 1.6,  -- used when the clip's Length still reads 0
	roarLockMaxTime = 5,         -- ceiling, so a bad clip can't freeze you

	roarPitchMin = 0.96,
	roarPitchMax = 1.04,
	-- false = the script leaves every RollOff property on your Sounds alone.
	-- You can also set a KeepRollOff attribute on one Sound to exempt just it.
	roarApplyRollOff = true,

	-- ---- SYNTHETIC DISTANT LAYER ----
	-- Only one roar recording? The distant layer is built from it at runtime.
	-- Distance is really two things: air eats high frequencies long before low
	-- ones, and what reaches you has bounced off everything on the way. So gut
	-- the treble, keep the bass, drown it in reverb, drop the pitch a little.
	-- If you ever record a real distant version, name it Distant and it wins.
	roarSynthDistant = true,
	roarDistantDelay = 0.14,       -- arrival delay; also stops the two layers
	-- sounding like one clip played twice
	roarDistantHighGain = -42,     -- dB ? the big one. Kills the crack and detail.
	roarDistantMidGain = -12,      -- dB
	roarDistantLowGain = 5,        -- dB ? bass survives distance, so lift it
	roarDistantOctave = 0.88,      -- pitch drop reads as bigger and further off

	-- ---- ECHO ----
	-- The roar coming back off the landscape a beat later: darker, quieter, and
	-- separate. This is the cue reverb was supposed to give, built by hand ? and
	-- because it's its own Sound rather than an effect on the original, nothing
	-- ducks the dry signal and nothing sounds cut off.
	-- The DELAY is what implies scale. Long delay = big world.
	roarEcho = true,
	roarEchoDelay = 0.42,          -- seconds after the roar
	roarEchoVolumeMult = 0.4,
	roarEchoHighGain = -55,        -- dB ? almost nothing but low end left
	roarEchoMidGain = -16,
	roarEchoLowGain = 4,
	roarEchoOctave = 0.84,

	-- =====================
	-- VISION  (read by CreatureVision)
	-- =====================
	-- The creature's view: the world drained to red, seen through a hex grid.
	--
	-- COMPATIBILITY: CreatureVision never touches Lighting.ColorCorrection,
	-- Atmosphere, Bloom, SunRays, Clouds or Terrain ? LightingCycle rewrites all
	-- of those every 0.1s and would erase anything put there. It creates its own
	-- effects instead (CreatureVision_CC, CreatureVision_Bloom) and Roblox stacks
	-- them on top, so storms, blizzards, winter and the day/night cycle all still
	-- work underneath and still read through the red.
	visionTint = Color3.fromRGB(255, 74, 58),
	visionSaturation = -0.82,      -- toward monochrome, then tinted. -1 is a flat
	-- red silhouette; a little left keeps materials
	-- distinguishable.
	visionContrast = 0.22,
	visionBrightness = 0.035,      -- small lift so night is still playable
	visionBloom = 0.55,
	visionBloomThreshold = 0.9,
	visionBloomSize = 30,

	visionHexAsset = "rbxassetid://84308444684815",
	visionHexColor = Color3.fromRGB(255, 96, 76),
	visionHexTransparency = 0.8,   -- HIGH is subtle. 0.7 gets heavy fast.
	visionHexTileSize = 128,       -- pixels per tile
	visionHexDrift = 3,            -- pixels the grid wanders
	visionHexDriftSpeed = 0.25,
	visionPulseAmount = 0.05,      -- transparency swing
	visionPulseSpeed = 1.1,
	visionFadeTime = 0.45,         -- seconds to fade in/out on morph

	-- =====================
	-- THERMAL VISION  (read by Systems > Thermal)
	-- =====================
	-- Red outlines on anything with a Humanoid. Always on while you're the
	-- creature ? there's no toggle.
	--
	-- Built the same way as the ECOTI block in your NightVision.luau: a Highlight
	-- is created per target with its Adornee already set and destroyed when the
	-- target leaves. The earlier pre-built pool that re-pointed its Adornee simply
	-- didn't render.
	--
	-- ? thermalMaxTargets MUST stay under about 31. Roblox renders roughly that
	-- many Highlight instances at once and then silently stops drawing the rest ?
	-- no error, no warning, and no control over which ones vanish. Targets are
	-- ranked NEAREST FIRST, so in a crowded server the ones you lose are distant.
	thermalRange = 750,            -- studs
	thermalMaxTargets = 24,        -- how many can be outlined at once
	thermalRefresh = 0.25,         -- seconds between target rescans

	thermalOutlineColor = Color3.fromRGB(255, 62, 46),
	thermalOutlineTransparency = 0,
	thermalFillColor = Color3.fromRGB(255, 62, 46),
	thermalFillTransparency = 1,   -- 1 = outlines only, no fill

	-- Nothing pops in or out.
	thermalFadeTime = 0.35,        -- seconds to fade fully in / out
	thermalFadeDistance = 120,     -- studs of dimming at the edge of range (0 = off)

	thermalThroughWalls = true,    -- false = line of sight only, like your ECOTI
	thermalIncludeSelf = false,
	thermalIncludeDead = false,      -- ? a dummy at 0 Health won't outline
	thermalIncludeCreatures = false, -- outline other creatures

	-- Prints "N humanoids known, N in range, N outlined" once a second. Turn this
	-- on if a rig isn't lighting up ? the numbers say which half is wrong.
	thermalDebug = false,

	-- =====================
	-- THERMAL SIGNATURE  (read by CreatureHeat, on the server)
	-- =====================
	-- How this creature looks on PLAYERS' thermals (the NVG ECOTI outlines and the
	-- Recon Drone's IR modes). It's cold-blooded: faint at rest, hotter when it
	-- sprints, roars or feeds, cooling off afterwards. 1 = as bright as a normal
	-- body, 0 = invisible. The hottest layer wins; they don't add up.
	heatBase = 0.15,          -- at rest: a faint shape you have to be looking for
	heatSprintMax = 0.75,     -- fully exerted from sprinting
	heatSprintBuild = 1.5,    -- s of sprinting to get there
	heatSprintCool = 5,       -- s to cool back down after stopping
	heatRoar = 1,             -- the flash when it roars: gives its position away
	heatRoarHold = 0.4,       -- s at full flash
	heatRoarFade = 3,         -- s to fade from the flash
	heatFed = 0.9,            -- right after a kill
	heatFedFade = 25,         -- s for the kill's heat to fade

	-- =====================
	-- NIGHT VISION  (read by Systems > NightVision) ? key N
	-- =====================
	-- Not a tint and not an overlay: it raises the actual scene light, so detail
	-- comes out of the shadows the way an animal's eyes pull it out. The red
	-- creature vision keeps running on top.
	--
	-- WHY NOT JUST RAISE BRIGHTNESS: Lighting.Brightness is only the sun/moon
	-- multiplier, and at midnight there's almost nothing for it to multiply.
	-- LightingCycle's Midnight preset gets its darkness from Ambient (10,10,10),
	-- OutdoorAmbient (30,30,30) and EnvironmentDiffuseScale 0 ? so those are what
	-- get lifted. Same finding your NVG's Amplify block landed on.
	--
	-- All client-local: Lighting writes on a client don't replicate, so only you
	-- see it. Everyone else still sees full night.
	nightVisionKey = Enum.KeyCode.N,
	nightVisionStartsOn = false,   -- true = already on the moment you morph
	nightVisionFadeTime = 0.35,

	-- THE CEILING of the whole effect: ambient can never get brighter than this
	-- however hard the lifts are pushed, so RAISE THIS FIRST if it still feels dim.
	-- Keeping it high also keeps daytime sane ? lerping an already-bright daytime
	-- ambient toward a LOW ceiling actually darkens it, which looks broken.
	nightVisionLiftColor = Color3.fromRGB(225, 225, 225),  -- was 168
	nightVisionAmbientLift = 0.75,    -- was 0.40. 0-1 toward the ceiling
	nightVisionOutdoorLift = 0.80,    -- was 0.46
	nightVisionBrightnessAdd = 5,     -- was 3.8. On top of whatever the cycle set
	nightVisionBrightnessMax = 7,     -- was 5.5. Hard clamp; a runaway boost is impossible
	nightVisionDiffuseScale = 1,      -- EnvironmentDiffuseScale, set outright

	--[[
		POST-PROCESS, applied AFTER the scene is lit.

		BRIGHTNESS IS THE THING THAT FLATTENS IT. It's a straight additive lift, so
		it raises the BLACK POINT by exactly as much as everything else: shadows
		that should stay black go grey, the range between darkest and lightest
		narrows, and it looks washed out rather than brighter. Hence 0 ? all the
		real light comes from the ambient lifts above, which put light where light
		belongs instead of smearing it over the whole image.

		CONTRAST pivots around mid-grey: darks go down and brights go up together.
		That's what puts the shape back, and it's why raising contrast can make a
		scene read as DARKER even though the bright end got brighter.

		IF IT'S STILL TOO BRIGHT: drop nightVisionOutdoorLift first (it's the one
		doing most of the work outdoors), then nightVisionAmbientLift. Reach for
		more contrast only once the flatness is gone ? past about 0.35 the shadows
		crush to solid black and you lose the detail the whole thing exists for.
	--]]
	nightVisionPostBrightness = 0,
	nightVisionPostContrast = 0.22,   -- was 0.1. More light needs more contrast or it goes grey and flat
	nightVisionPostSaturation = -0.15, -- an animal trading colour for sensitivity

	-- =====================
	-- EYES / BLINKING  (read by Systems > Eyes)
	-- =====================
	-- Every BasePart named "Eye" inside Head > HeadModel is an eye. They blink
	-- INDEPENDENTLY: separate timers, separate durations, and a permanent per-eye
	-- rate multiplier drawn once. That last one is the important one ? eyes sharing
	-- an average interval will drift into accidental unison sooner or later, and
	-- two eyes blinking together is the most human thing a face can do.
	--
	-- A blink is a REFLECTANCE drop, not transparency. Transparency made the eye
	-- vanish, which reads as a hole in the head; killing the shine makes it go dull
	-- ? still there, just dead for a moment. Closer to a nictitating membrane than
	-- an eyelid, which is the right note for something that isn't a person.
	--
	-- ON THE NUMBERS: Roblox stores Reflectance as 0..1 and CLAMPS outside that, so
	-- -10 lands at 0 (fully matte ? which is the look, it just can't go further).
	-- Anything with a magnitude over 1 is divided by 100, so 25 and 0.25 both work.
	eyeHeadModelName = "HeadModel",
	eyePartName = "Eye",         -- every BasePart with this name gets blinked
	eyeOpenReflectance = 25,     -- resting shine
	eyeBlinkReflectance = -10,   -- during the blink (clamps to 0)

	-- A shine value snapping instantly reads as a lighting glitch rather than a
	-- blink, so there's a short ramp on each edge. Set both to 0 for a hard snap.
	eyeCloseSpeed = 0.045,       -- seconds to close
	eyeOpenSpeed = 0.09,         -- slower than closing, like real lids

	eyeBlinkMinGap = 1.8,        -- seconds between blinks, before the multiplier
	eyeBlinkMaxGap = 7.5,
	eyeBlinkMinTime = 0.05,      -- how long shut. Keep it short: a long blink
	eyeBlinkMaxTime = 0.14,      -- reads as sleepy, which is a warm expression.
	eyeRateMin = 0.5,            -- per-eye multiplier range, fixed for its life.
	eyeRateMax = 1.9,            -- Widen for a more chaotic, less uniform face.
	eyeDoubleBlinkChance = 0.22, -- chance a blink is followed straight by another
	eyeDoubleBlinkGapMin = 0.10,
	eyeDoubleBlinkGapMax = 0.24,
	eyeCloseOnDeath = true,      -- eyes left matte on a corpse (wet eyes look alive)

	-- =====================
	-- MOUSE  (read by Systems > Mouse)
	-- =====================
	-- The cursor is hidden and pinned to screen centre, so moving the mouse turns
	-- the camera with no right-click hold. Z releases it ? cursor back, free to
	-- click UI ? and Z again re-locks. Releasing also stops the camera following
	-- the mouse, since Roblox only reads mouse delta while it's centre-locked.
	--
	-- A fresh morph always starts locked, so you can never come back from a
	-- respawn with a stranded free cursor.
	mouseFreeKey = Enum.KeyCode.Z,
	mouseFreeIsHold = false,     -- false = tap to toggle (better for using UI)
	-- true  = hold Z for the cursor, release to look
	--         (better for a quick glance without
	--          losing your aim)

	-- =====================
	-- BREATHING  (read by CreatureBreathing)
	-- =====================
	-- Sounds live in the rig at: Head > Breathing > any Sounds you like.
	-- One plays, finishes completely, then a random gap, then the next.
	-- Set Looped = false on every breath Sound.
	breathPartName = "BreathingSounds", -- Part inside HumanoidRootPart
	breathFolder = "Breathing",         -- legacy fallback: Head > Breathing
	breathMinGap = 5,          -- shortest silence between breaths (seconds)
	breathMaxGap = 35,         -- longest silence between breaths
	breathFirstDelayMin = 2,   -- the very first breath comes sooner than the
	breathFirstDelayMax = 6,   -- normal gap, so you get feedback quickly
	breathPitchMin = 0.94,
	breathPitchMax = 1.06,
	breathVolumeMultiplier = 1.0,
	breathMaxWait = 20,        -- safety cap waiting for a breath to finish
	breathDebug = false,       -- true = print every breath to Output

	-- Positioning. If breathing sounds like it's ALL AROUND you rather than
	-- coming from the creature, breathMinDistance is the cause: inside that
	-- radius a sound plays at full volume with no attenuation. Roars want a big
	-- one (it's what makes them feel enormous); breathing wants a small one, so
	-- it pulls you toward where the creature actually is.
	breathApplyRollOff = true, -- false = leave your Sound properties alone
	breathMinDistance = 6,     -- full volume only this close
	breathMaxDistance = 110,   -- silent beyond here

	-- =====================
	-- FOOTSTEP SOUNDS  (read by CreatureFootsteps)
	-- =====================
	-- Which folder under ReplicatedStorage.CreatureSounds this creature uses.
	-- Two creatures can share one set, or each have their own.
	soundSet = "Stalker",

	minTimeBetweenSteps = 0.10,  -- debounce; stops doubled markers stacking
	minTimeBetweenLands = 0.12,
	pitchMin = 0.90,
	pitchMax = 1.08,
	stepVolumeMultiplier = 1.0,  -- scales the template Sound's own Volume
	minMoveDir = 0.10,           -- MoveDirection below this = not really walking

	-- Steps are driven by a "Footstep" keyframe marker in the walk animation. If
	-- the animation has no markers yet, silence looks like a broken script ? so
	-- distance-based steps stand in until a real marker fires, then retire
	-- permanently for that rig. Nothing to switch off once you've added markers.
	footstepFallback = true,
	fallbackStride = 3.2,        -- studs travelled per stand-in step

	-- Water is detected by raycast from the root AND both feet, not just
	-- FloorMaterial, so ankle-deep water still sounds wet.
	waterContactGrace = 0.05,      -- seconds a wet contact keeps counting
	waterCheckUpOffset = 2.0,      -- ray starts this far above the point
	waterCheckDownDistance = 8.0,  -- and probes this far down

	-- =====================
	-- FOLIAGE RUSTLE LAYER
	-- =====================
	-- Reuses CollectionService-tagged parts. Each tagged part may carry
	-- RustleRadius / RustleHeightUp / RustleHeightDown attributes; the defaults
	-- below apply to any that don't.
	foliageTag = "FoliageRustle",
	rustleFolder = "Rustle",        -- folder name inside the sound set
	foliagePitchMin = 0.95,
	foliagePitchMax = 1.05,
	foliageVolumeMultiplier = 0.7,
	defaultRustleRadius = 0,
	defaultRustleHeightUp = 0,
	defaultRustleHeightDown = 0,
}
