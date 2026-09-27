-- Main game settings

local config = {}



-- Game settings

config.thirdPersonFiring = true -- Allow the player to fire from third person (unfinished)
config.arcadeBullets = false -- Gives bullets a faint streak similar to FE Gun Kit, looks pretty bad with tracers enabled

config.leaderboard = true -- Creates a simple kill death leaderboard
config.rblxDamageTags = true -- Include Roblox built in damage tags when counting kills

config.systemChat = true -- Sends messages in chat when players join, leave, and die
config.deathScreen = true -- Displays a screen after death with a respawn counter

config.fallDamage = true -- Should there be fall damage?
config.fallDamageDist = 19 -- Minimum distance to take damage
config.fallDamageMultiplier = 0.7

config.teamKill = true
config.teamTracers = false

config.firstPersonBody = true -- Should the player's body be visible in first person?
config.headRotation = true -- Should the head rotate when in third person
config.headRotationSpeed = 15
config.disableHeadRotation = false -- Disables head rotation entirely for both first and third person (Your viewmodel will still move up and down)
config.headRotationEventRate = 0.1 -- How often should head rotation be replicated
config.replicatedHeadRotationSpeed = 0.6 -- How quickly should other player's head's be rotated

config.useDeathCameraSubject = true -- If this is true, your camera will follow your corpse when you die

config.explosionRaycast = true -- Check with a raycast if players should be damaged

config.lockFirstPerson = false -- Can the player exit first person with a gun equipped?
-- DO NOT enable this setting if you want players to always be locked to first person
-- To do that, go to StarterPlayer and change the default CameraMode

config.speedOfSound = true -- Firing sounds are delayed based on distance to the player.
config.meterMultiplier = 3.5 -- Allows you to manually decide how many meters are in a stud, used for muzzle velocity and the speed of sound.

-- Gun dropping settings

config.gunDropping = false
config.dropOnDeath = false
config.dropOnLeave = false
config.dropDespawnTime = 60 -- How long should guns stay on the ground?
config.maxDroppedGuns = 15 -- How many can be on the ground at once?
config.pickupDistance = 7
config.dropGunAnchorTime = 3 -- Anchor dropped gun models after this amount of time

config.canReloadWhileAiming = false -- Can the player reload while aiming?


-- Movement settings

config.walkSpeed = 7.7
config.sprintSpeed = 18.8
config.sprintAnimMinSpeed = 0.65 -- Slowest the sprint loop plays (at low movement speed)
config.sprintAnimMaxSpeed = 1.5 -- Fastest the sprint loop plays (at high movement speed)
config.sprintBlendIn = 0.4  -- Crossfade time entering sprint / start->loop (higher = smoother, softer)
config.sprintBlendOut = 0.4 -- Crossfade time loop->end when you stop (higher = smoother, softer)
config.sprintEndActionFraction = 0.4 -- How much of the sprint END anim must play before weapon actions (aiming, firing, reloading) unlock again. The leftover tail crossfades away under whatever you do next instead of blocking you. Aim pressed during the locked stretch is queued and fires the instant this threshold is crossed. 1 = wait for the whole clip (the old behaviour), lower = snappier out of a sprint.
config.sprintSpamCooldown = 0.2 -- Min time between sprint start/end anim triggers. Spamming sprint on/off within this window is coalesced (then snaps to the final state) so the anims don't violently restart. Higher = more spam-proof but less responsive.
config.crouchSpeed = 4.4
config.proneSpeed = 3.3
config.strafeSpeedMultiplier = 1 -- Movement speed is multiplied by this while strafing or moving backwards. Set this to 1 if you don't want a movement reduction while strafing.
config.canSprintWhileStrafing = true -- Can the player sprint while not moving forwards?
-- If other scripts are conflicting with SPH's movement, you can override them using the attributes under the CharacterMovement script.

config.stanceChangeTime = 0.3 -- How long it takes to transition between stances

config.canLean = true -- Can the player lean around corners
config.canCrouch = true -- Can the player crouch
config.canProne = true -- Can the player go prone (This setting doesn't matter if canCrouch is false)
config.proneAngle = false -- Adjust prone angle based on ground

config.jumpCooldown = 1.6 -- Time between jumps

config.useHigherAnimPriority = true -- Uses higher animation priorities for the Crouch and Prone animations to avoid conflicting with the default tool idle animation.
config.firstPersonAimAnim = false -- Should aim animations play in first person?
config.proceduralAimAnim = true -- Used only in first person.

-- Sprint animation
config.sprintAnimSpeed = 1.16 -- Sprint animation playback speed multiplier

-- Acceleration / Deceleration settings
-- All values are in studs/s? ? controls how fast WalkSpeed ramps up or down.
-- Set any to math.huge for instant transitions (disables smoothing for that state).
config.accelWalk = 18       -- How fast you ramp up to walk speed from standstill
config.decelWalk = 18       -- How fast you slow down when you stop walking
config.accelSprint = 18     -- How fast you accelerate into sprint speed (the "wind-up" feel)
config.decelSprint = 16     -- How fast you decelerate from sprint (e.g. releasing shift)
config.accelCrouch = 16     -- Crouch acceleration
config.decelCrouch = 30     -- Crouch deceleration
config.accelProne = 14      -- Prone acceleration
config.decelProne = 20      -- Prone deceleration
config.speedSnapThreshold = 0.5 -- Below this speed when stopping, snap to zero to prevent micro-drift

-- Movement banking (character tilts from feet when turning at speed)
config.bankMaxAngle = 18 -- Max tilt angle in degrees
config.bankSpeedThreshold = 8 -- Minimum speed before banking starts (studs/s)
config.bankSpeedFull = 16 -- Speed at which banking reaches full strength
config.bankSmoothSpeed = 12 -- Interpolation speed (higher = snappier response)
config.bankYawForMax = 120 -- Turn rate in deg/s that produces max tilt


-- Input settings

-- To disable a keybind, set it to nil
-- config.example = {nil}
-- To add an alternate input, add another item to the table
-- config.example = {input1, input2, input3}

config.keySprint = {Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3}
config.keyReload = {Enum.KeyCode.R, Enum.KeyCode.ButtonX}
config.keyChamber = {Enum.KeyCode.T}
config.sightSwitch = {Enum.KeyCode.Y} -- Cycles AimParts, and flips the magnifier on guns that have one
config.freeLook = {Enum.KeyCode.SysReq}
config.lowerStance = {Enum.KeyCode.C}
config.raiseStance = {Enum.KeyCode.X}
config.switchFireMode = {Enum.KeyCode.F}
config.leanLeft = {Enum.KeyCode.Q}
config.leanRight = {Enum.KeyCode.E}
config.dropKey = {Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB}
config.pickupKey = {Enum.KeyCode.G}
config.toggleLaser = {Enum.KeyCode.J}
config.toggleFlashlight = {Enum.KeyCode.H}
config.toggleCant = {Enum.KeyCode.B} -- Tilt/cant the gun while aiming (set to nil to disable; night vision forces cant on)
config.holdForScrollZoom = Enum.KeyCode.LeftControl
config.fireGun = {Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2}
config.aimGun = {Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2}
-- Moved off Y: it was sharing a key with config.sightSwitch, and because the suppressor
-- action is bound LAST at the same priority it won the input and swallowed every Y press --
-- so sight switching (and the magnifier flip) never saw the key at all.
config.toggleSuppressor = {Enum.KeyCode.K} -- Unfinished
config.toggleBipod = {Enum.KeyCode.Z}

config.defaultAimSensitivity = 0.4 -- Scrolling up and down while aiming will increase/decrease your aim sensitivity
config.gunInputPriority = 100 -- Priority level for gun inputs
config.movementInputPriority = 100 -- Priority level for movement inputs

config.mobileButtons = true -- Adds mobile buttons on screen if using a touchscreen device
config.toggleAiming = false -- Switches all players to using toggle aim instead of hold to aim


-- Performance settings

config.animDistance = 1000 -- Maximum distance to see a player's animations
config.fireEffectDistance = 4000 -- Maximum distance for firing effects to be replicated
config.maxBulletDistance = 6000 -- Bullets that fly further than this distance will be deleted
config.maxHitDistance = 1000 -- Maximum distance to see bullet hit effects

config.ragdolls = true -- Should players ragdoll on death?
config.bodyDespawn = 60 -- Bodies are removed after this time
config.bodyLimit = 15 -- Maximum number of bodies
config.bodyAnchorTime = 10 -- Corpse is anchored and uncollided after this amount of time

config.shellEjection = true -- Game-wide override for shell ejection
config.shellDistance = 50 -- Shells won't be ejected beyond this distance
config.shellMaxCount = 30 -- Maximum that can be on the ground at once
config.shellDespawn = 10 -- Shells are auto deleted after this amount of time
config.shellAnchorTime = 3 -- Shells are anchored after this amount of time

config.firstPersonHolsters = false -- Should holsters be shown in first person? (Very laggy if you have too many holsters at once)
config.blurEffects = false -- Experimental stuff with depth of field

-- Aiming depth of field (drives the "AimDOF" DepthOfFieldEffect in Lighting while aiming, back
-- to 0 when not). These are the GLOBAL defaults; override per weapon with a wepStats.aimDOF table.
-- All 0 = no DOF. Match the DepthOfFieldEffect properties.
config.aimDOF = {
	farIntensity = 0,   -- 0-1: blur strength for things FAR past the focus plane
	nearIntensity = 0,  -- 0-1: blur strength for things NEAR the camera
	focusDistance = 0,  -- studs: the distance that stays sharp
	inFocusRadius = 0,  -- studs: size of the sharp zone around focusDistance
}

config.despawnEmptyAmmoBoxes = true -- Should empty ammo boxes be destroyed after some time?
config.ammoBoxDespawnTime = 10

config.maxBullets = 300 -- Maximum number of bullets that are cached (Cache size will temporarily increase if this is exceeded)

config.bulletHoles = true
config.bulletHoleDespawnTime = 20

config.glassShatter = true -- Should glass shatter when shot? (Must be named "Glass" or given tag "BreakableGlass")
config.glassShardDespawnTime = 30 -- How long should shards stay on the ground?
config.glassRespawnTime = 120 -- How long until glass is replaced?



-- Physics settings

config.bulletAcceleration = Vector3.new(0, -workspace.Gravity, 0) -- This is used for the bullet drop force
config.useBulletForce = true -- Should bullet impacts be able to push things around?
config.bulletPen = true -- Can bullets pierce objects?



-- Viewmodel settings

config.breathingSpeed = 7 -- Speed of the breathing cycle
config.breathingDist = 0.01 -- Distance the viewmodel will move while breathing
config.breathingAimMultiplier = 0.17 -- Breathing dist is multiplied by this when aiming, the closer this number is to 1 the more breathing there is

config.bobSpeed = 14 -- How quickly the viewmodel should move back and forth, this is scaled based on walk speed
config.sprintBobSpeedMultiplier = 1.5 -- Step cadence while sprinting vs walking (1 = same as walk, >1 = faster sprint steps)
config.bobDampening = 7 -- Higher number = less bobbing
config.aimBobDampening = 2.-- Higher number = less bobbing while aiming
config.cameraMovement = false -- Should the camera bob around?
config.cameraBobDampening = 1 -- Higher number = less bobbing
config.cameraTilting = false -- Should the camera tilt when looking and moving around?
config.cameraLimitInSeats = true -- Limit camera angle to 180 degrees when sitting in a seat (Disabling this may cause issues with other camera settings)
config.canEquipInVehicleSeat = false -- Can the player equip guns while using a vehicle? (Setting this to true may cause input overlaps.)

config.hipfireMove = false -- Allows you to move your gun off center while hip firing
config.hipfireMoveX = 7 -- Max angle that the gun can move horizontally
config.hipfireMoveY = 7 -- Max angle that the gun can move vertically
config.hipfireMoveSpeed = 0.058
config.offCenterAiming = false -- Allow the player to move off center while aiming (requires hipfireMove)

config.aimTiltDeg = 0 -- Default camera "cant"/tilt (in degrees) applied while aiming. Per-gun override: wepStats.aimTilt. 0 = no tilt. (Handled by the CameraBobAndFallSway script.)

-- ADS transition timing (SECONDS). Global defaults; override per weapon with wepStats.aimInTime /
-- aimOutTime. This is literally how long the gun takes to raise into / lower out of aim. Higher =
-- slower. The aim cant (tilt) eases in/out over these same times.
config.aimInTime = 0.3   -- seconds to raise into aim
config.aimOutTime = 0.25 -- seconds to lower out of aim
-- Weapon cant pose timing (SECONDS). How fast you ease into / out of the canted (NVAimPart) pose,
-- toggled by config.toggleCant and forced on by night vision. Per weapon: wepStats.cantInTime / cantOutTime.
config.cantInTime = 0.25 -- seconds to cant in
config.cantOutTime = 0.25 -- seconds to cant out

-- Optic reticle parallax / eye-box. The reticle shifts as your eye moves off the optic's axis
-- (parallax). Without bounds a swaying gun pushes the reticle right off the glass. These clamp it
-- to the lens rim and fade it out as your eye leaves the eye-box. Per-optic override: put a NUMBER
-- attribute of the same name on the SightReticle part (ReticleParallax / ReticleClampRadius /
-- ReticleFadeStart / ReticleFadeEnd).
config.reticleParallax = 1       -- parallax strength: 1 = full/realistic, 0 = reticle locked dead-center (no drift)
config.reticleClampRadius = 0.5  -- max reticle offset from center, in scale units (0.5 = the frame/glass edge)
config.reticleFadeStart = 0.32   -- offset where the reticle starts fading out (eye leaving the box)
config.reticleFadeEnd = 0.5      -- offset where the reticle is fully gone

-- ADS / cant "settle" wobble: a springy ROLL overshoot on the viewmodel when you raise/lower
-- the gun, cant, or swap canted<->regular aim -- a sideways tilt that ramps in and bounces back
-- to zero so the transition reads alive instead of robotic. Fully decays to 0, so a settled aim
-- sits dead level. Amounts read roughly as PEAK DEGREES of roll -- scale to taste. Lower damper
-- = more overshoot/wobble; higher speed = snappier settle. 0 amount = off.
config.aimWobbleAmount = 7    -- ~peak roll degrees when aiming IN / OUT
config.cantWobbleAmount = 7   -- ~peak roll degrees when canting / swapping cant<->regular
config.aimWobbleSpeed = 9     -- settle speed (higher = snappier / smaller)
config.aimWobbleDamper = 0.4  -- bounciness (~1 = no bounce, lower = more overshoot/wobble)

-- Crouch gun tilt: while crouched (and only during idle/firing -- not aiming, reloading,
-- sprinting, inspecting, chambering, or a ready stance) the viewmodel rolls left this many
-- degrees, eased smoothly in/out. Per-gun override: wepStats.crouchTiltDeg. 0 = off. Flip the
-- sign to tilt right instead.
config.crouchTiltDeg = 11    -- degrees of left roll while crouched idle/firing
config.crouchTiltSpeed = 5   -- transition speed (lower = slower)
config.crouchTiltDamper = 0.45 -- bounciness (~1 = no bounce/clean settle, lower = bouncier overshoot)

config.pushBackViewmodel = true -- Should the gun move back when getting close to a wall?
config.raiseGunAtWall = true -- Should the gun be raised when too close to a wall? 

config.fireWithFreelook = false -- Can the player fire their gun while freelook is active?

config.maxStrafeRoll = 25 -- How much the viewmodel can lean left and right when strafing

-- Movement weight / inertia (Tarkov/Squad-style momentum)
config.inertiaImpulse = 0.35 -- How hard sharp velocity changes (start/stop/reverse) kick the gun. 0 = old steady-lean only, higher = heavier/swingier
config.inertiaMaxImpulse = 1.5 -- Per-axis clamp so a hard reversal at sprint speed can't fling the viewmodel
config.landingInertiaDip = 0.5 -- How much the gun dips when you land from a fall. 0 = off
config.landingDipMinFall = 4 -- Minimum downward speed (studs/s) before a landing dip triggers

-- Rotational gun sway (the gun lags behind your camera rotation, then springs back)
-- These are global defaults. Any weapon can override them with a wepStats.sway table.
config.swayAmount = 2.5 -- Hipfire swing magnitude / how FAR it travels (independent of the lag/bounce feel)
config.swayAimAmount = 1.8 -- How far it travels while aiming
config.swaySpeed = 9 -- Catch-up speed of the rotation spring (lower = slower, floatier recovery. Was 12)
config.swayDamper = 0.55 -- Bounciness (lower = more overshoot/wobble before it settles, 1 = clean stop. Was 0.65)
config.swayPosSpeed = 7 -- Catch-up speed of the position spring (lower = floatier. Was 9)
config.swayPosDamper = 0.6 -- Bounciness of the position spring (lower = bouncier. Was 0.7)
config.swayDecay = 30 -- How much view rotation builds up before decaying (lower = bigger/longer sway. Was 42)
config.swayMaxAngle = 18 -- Soft cap (degrees) on how far the sway can swing on fast turns. It eases toward this smoothly (tanh) so normal sway stays 1:1 and it never looks stiff. Lower = tighter cap. 0 = no cap.

-- FOV (field of view) feel. Base FOV is 55 (set on the camera / StarterPlayer).
-- One smoother now drives ALL fov changes (aim in/out, sprint, jump/land) so nothing snaps.
config.fovSmoothSpeed = 12 -- Master smoothing speed for every fov change (higher = snappier, lower = floatier). Frame-rate independent
config.sprintFOVAdd = 0 -- How much FOV widens at full sprint, added to the base (0 = off)
config.sprintFOVSpeed = 6 -- How fast the sprint FOV eases in and out
config.jumpFOVKick = -4 -- FOV punch when you jump (negative = a quick narrow that recovers, 0 = off)
config.landFOVKick = 5 -- FOV punch when you land hard (positive = quick widen, scaled by impact, 0 = off)
config.fovKickDecay = 6 -- How fast the jump/land FOV kicks fade back out

-- Per-shot FOV kick (a springy FOV punch each time you fire). Global defaults; override per weapon
-- with a wepStats.fovKick table. Positive amount = FOV widens (recoil punch), negative = narrows.
config.fovKickAmount = 2 -- FOV kick per shot while hip firing (degrees). 0 = off.
config.fovKickAimAmount = 1 -- FOV kick per shot while aiming (usually smaller). 0 = off.
config.fovKickSpeed = 12 -- Spring catch-up speed (higher = snappier recovery).
config.fovKickDamper = 0.7 -- Spring bounciness (lower = more overshoot/bounce; 1 = clean).

config.showAccessoriesFP = true -- Should accessories be shown in first person?


-- Effects settings

config.lowHealthEffects = true -- Low health visual effects, reduced movement speed, and shaking when aiming
config.damageFlinching = true -- Camera gets knocked off center when taking damage
config.suppressionEffects = true -- Tunnel vision and crack sounds
config.footstepSounds = true -- Replaces the default walk sound with material based sounds

config.tracerStartDistance = 15 -- Tracers and arcade bullets don't appear until they're this distance away from you
config.fireSoundVariation = 500 -- Lowering this number increases the variation in pitch (playback speed) of fire and echo sounds

config.firstPersonEcho = true -- If this is set to false other players will hear echo sounds, but not yourself

config.laserTrail = false -- Should lasers have a trail



-- Destruction settings

config.destructibleObjects = true
config.destructibleDespawnTime = 30
config.disablePlayerDebrisCollision = true -- Stops players from colliding with debris from destroyed objects.


-- Anti Exploit settings

config.printKillLogs = true -- Prints a message in output when a player kills another.
config.serverSideHitCheck = false -- Uses a server-side raycast to check if a shot was possible.
config.listenForKillAll = true -- Kicks players that attempt to kill multiple players at once.
config.multiKillThreshold = 2 -- Trying to kill more than this number of players at once will kick the player (If the setting above is enabled).
config.antiFreecam = true -- Prevent players from firing shots if their camera is too far away.
config.requireEquippedGun = true -- Guns cannot deal damage if not currently equipped.
config.listenForReloadSpam = true -- Adds cooldown for how often the reload event can be fired.
config.listenForExplosionSpam = true -- Kicks players that attempt to call bulletHit with explosions too frequently.
config.killAngleCheck = false -- Prevents players from killing enemies that aren't being looked at.

--config.ammoCountCheck = false -- Prevents players from firing the bulletHit event without firing a gun
--config.multiKillDistanceCheck = false -- Tries to pevent players from killing multiple players that are far away from each other (Requires listenForKillAll)
--config.strikes = false -- Attempt to use events suspiciously will add a "strike" to a player
--config.maxStrike = 3 -- If a player reaches this number of strikes, they will be kicked from the game
--config.serverBanList = false -- If a player is kicked by SPH for exploiting, they will also be banned from this server


-- Version

config.version = "v1.3.0" -- Used only for debugging and analytics

return config -- DO NOT try to add new or custom settings after this line!
