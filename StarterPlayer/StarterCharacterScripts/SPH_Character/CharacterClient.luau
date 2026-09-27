-- Luau caps the main chunk at 200 local registers and this script was sitting right on
-- that ceiling, so adding even one new top-level local made it fail to compile. Related
-- top-level locals are grouped into these five tables instead, freeing ~77 registers.
-- Same trick `springs` / `net` / `sphReady` already use further down.
local svc   = {} -- Roblox services
local mods  = {} -- required modules
local flags = {} -- mutable gameplay / animation state
local cam   = {} -- camera + viewmodel offsets and smoothing
local laser = {} -- laser + flashlight attachment state

-- CharacterClient
svc.replicatedStorage = game:GetService("ReplicatedStorage")
svc.runService = game:GetService("RunService")
svc.userInputService = game:GetService("UserInputService")
svc.debris = game:GetService("Debris")
svc.players = game:GetService("Players")
svc.tweenService = game:GetService("TweenService")
svc.testService = game:GetService("TestService")
svc.contextActionService = game:GetService("ContextActionService")
svc.collectionService = game:GetService("CollectionService")

local assets = svc.replicatedStorage.SPH_Assets
local modules = assets.Modules
local animations = assets.Animations
local player = svc.players.LocalPlayer
local toggleViewmodelSprint = assets.Events.ToggleViewmodelSprint

local character = script.Parent.Parent
local humanoid:Humanoid = character:WaitForChild("Humanoid")
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local rootJoint = humanoidRootPart:WaitForChild("RootJoint")
local neckJoint
if humanoid.RigType == Enum.HumanoidRigType.R6 then
	neckJoint = character.Torso.Neck
else
	neckJoint = character.UpperTorso.Neck
end
local camera = workspace.CurrentCamera
local head = character:WaitForChild("Head", 20)

-- Start in third person: camera subject is the head
camera.CameraSubject = humanoid
camera.CameraType = Enum.CameraType.Custom
if camera:FindFirstChild("WeaponRig") then camera.WeaponRig:Destroy() end

-- Force third person on spawn (clears stale LockFirstPerson from a previous life)
player.CameraMode = Enum.CameraMode.Classic

local defaultFOV = 70

-- FieldOfView lives on the CAMERA, which outlives the character -- so any FOV left dirty
-- by the previous life (dying while scoped is the usual one) is still on screen the moment
-- this script starts. Clear it here so every respawn begins at a known, unmagnified FOV
-- no matter how the last life ended.
camera.FieldOfView = defaultFOV

mods.weldMod = require(modules.WeldMod)
mods.bridgeNet = require(modules.BridgeNet)
mods.viewMod = require(modules.ViewMod)
mods.springMod = require(modules.SpringModule)
mods.hitFX = require(modules.HitFX)
local shellEjection = require(modules.ShellEjection)
mods.bulletHandler = require(modules.BulletHandler)
mods.callbacks = require(assets.Mods)
mods.bulletHandler.Initialize(player)

local config = require(assets.GameConfig)
-- Player-customisable keybinds (saved per player). ONE new top-level local on
-- purpose -- Luau caps the main chunk at 200 and this file is already close.
mods.Keybinds = require(svc.replicatedStorage:WaitForChild("NorthgateKeybinds"))
local warnPrefix = "[ SPH ] "
humanoid.WalkSpeed = config.walkSpeed

local sphWorkspace = workspace:WaitForChild("SPH_Workspace")
local shellFolder = sphWorkspace:WaitForChild("Shells")

local rayParams = RaycastParams.new()
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {character,camera,shellFolder}

local springs = {
	-- Swim state, kept here rather than as its own local: this script sits at Luau's
	-- 200-local ceiling and one more top-level local fails to compile.
	swimming = false,
	sway = mods.springMod.new(),
	move = mods.springMod.new(),
	recoil = mods.springMod.new(),
	gunRecoil = mods.springMod.new(),
	fovShoot = mods.springMod.new(), -- per-shot FOV kick (shoved on fire, added to the FOV smoother)
	-- Aim was pressed while the sprint END anim was still in its locked stretch. Mirrors
	-- sphReady.pendingAim: the press is queued instead of dropped and fires the instant the
	-- end anim passes its action threshold. Parked here for the same 200-local reason.
	sprintPendingAim = false,
	-- Cached laser RaycastParams + the gun model it was built for. Also parked here
	-- rather than as top-level locals, for the same 200-local reason as `swimming`.
	laserRayParams = nil,
	laserRayGun = nil,
}
-- 2D magnified optics (Arma-style scope view). Hung off `springs` rather than declared as a
-- top-level local: this script is already at Luau's 200-local-per-scope ceiling.
springs.scope = require(modules.ScopeSystem)
springs.scope.Init()
-- Flip-to-side magnifier. Hung off `springs` for the same reason ScopeSystem is: this
-- script is already at Luau's 200-local-per-scope ceiling.
springs.magnifier = require(modules.MagnifierSystem)
-- CTRL held = scope magnification modifier (see the mouse wheel handler further down).
-- The state is latched from InputBegan/InputEnded rather than polled with IsKeyDown so a
-- press is never missed on the frame the wheel fires. Focus loss clears it so it can't
-- stick on if you tab out mid-hold.
-- Seconds left in the window to shoulder back in after a bolt cycle that dropped the
-- aim (wepStats.unaimToChamber). 0 = nothing pending.
springs.reaimChamber = 0
springs.zoomKeyHeld = false
svc.userInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
		springs.zoomKeyHeld = true
	end
end)
svc.userInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
		-- Seconds left in the window to shoulder back in after a bolt cycle that dropped the
		-- aim (wepStats.unaimToChamber). 0 = nothing pending.
		springs.reaimChamber = 0
		springs.zoomKeyHeld = false
	end
end)
svc.userInputService.WindowFocusReleased:Connect(function() -- Seconds left in the window to shoulder back in after a bolt cycle that dropped the
	-- aim (wepStats.unaimToChamber). 0 = nothing pending.
	springs.reaimChamber = 0
	springs.zoomKeyHeld = false end)
-- Aim depth of field: cached effect + a lerp target. Driven each frame in RenderStepped (manual
-- lerp instead of TweenService, which doesn't animate post-processing effects reliably).
-- The effect's authored values become the RESTING DOF (what shows when not aiming); aiming
-- transitions to wepStats.aimDOF and back to this rest.
springs.aimDOF = game:GetService("Lighting"):FindFirstChild("AimDOF")
if springs.aimDOF then
	springs.aimDOF.Enabled = true
	springs.dofRest = {
		far = springs.aimDOF.FarIntensity, near = springs.aimDOF.NearIntensity,
		focus = springs.aimDOF.FocusDistance, radius = springs.aimDOF.InFocusRadius,
	}
else
	springs.dofRest = { far = 0, near = 0, focus = 0, radius = 0 }
end
springs.dofTarget = {
	far = springs.dofRest.far, near = springs.dofRest.near,
	focus = springs.dofRest.focus, radius = springs.dofRest.radius,
}
springs.dofSpeed = 6

-- Camera-look sway (FE-style): gun lags/swings when you turn the view, then springs back.
-- Stored on the existing `springs` table to avoid adding top-level locals (Luau 200 limit).
springs.lookSway = require(modules.Spring).new(Vector3.zero) -- rotation sway
springs.posSway = require(modules.Spring).new(Vector3.zero)  -- position sway
springs.lookSway.s = 12; springs.lookSway.d = 0.65          -- speed (snappiness) / damper (0-1, lower = bouncier)
springs.posSway.s = 9; springs.posSway.d = 0.7
springs.swayTilt = { lastPitch = 0, lastYaw = 0, x = 0, y = 0 }
-- Movement inertia: weighty drift/tilt when you start, stop or change direction.
-- Target is the gun-relative velocity; the spring lags behind it, and we read the
-- LAG (target - position) to know how hard the player just changed motion. That lag
-- drives a positional drift + a roll/pitch tilt so the gun swings into momentum.
springs.inertia = require(modules.Spring).new(Vector3.zero)
springs.inertia.s = 6.5  -- lower = heavier/floatier, lags more (smooths hard reversals)
springs.inertia.d = 0.42 -- ~1 = settles clean, lower = more overshoot/wobble (human catch-up)
-- Bob phase accumulator: integrate speed over time so the wave never snaps when
-- WalkSpeed changes (sprint/ads). Replaces raw tick()-based sine.
springs.bobState = { phase = 0, amp = 0, sprintBlend = 0, velSmooth = Vector3.zero, prevVel = Vector3.zero, wasGrounded = true }
-- Tactical lean: spring the camera (lateral offset, dip and roll) so it eases out
-- and settles with a little bounce, same feel as the sway. Lean amount on .X.
springs.lean = require(modules.Spring).new(Vector3.zero)
springs.lean.s = config.leanSpringSpeed or 7.5    -- lower = slower, more deliberate lean
springs.lean.d = config.leanSpringDamper or 0.82  -- ~1 = smooth/no bounce, lower = bouncier

-- ADS / cant "settle" wobble: a self-contained damped spring (roll degrees + its velocity)
-- kicked on aim in/out and cant. Velocity kick = smooth ramp in, then overshoot back to 0, so
-- it only shows during the transition (fully aimed = 0 = gun dead level). Runs its own physics
-- each frame (doesn't depend on the Spring module exposing velocity). All on springs, no new
-- top-level local. cantWasOn below tracks the effective cant pose, so an NV-forced cant swap
-- kicks the wobble -- and a keypress that changes nothing doesn't.
springs.wobRoll = 0   -- current roll (degrees)
springs.wobVel = 0    -- current roll velocity
-- READY-STANCE SETTLE BOUNCE. Same damped-spring trick as the ADS wobble above, but on
-- pitch AND roll, kicked when a high/low ready start or end animation finishes. Lets a
-- flat linear transition land with an overshoot without animating one by hand. X = pitch
-- (degrees), Y = roll. Both decay fully to 0, so the gun sits dead level once settled.
springs.settleP = Vector2.zero
springs.settleV = Vector2.zero
function springs.KickSettle(dir)
	local b = (wepStats and wepStats.readyBounce) or config.readyBounce or {}
	if b.enabled == false then return end
	local sp = b.speed or config.aimWobbleSpeed or 9
	springs.settleV = springs.settleV + Vector2.new(
		(b.pitch or 2.6) * dir,
		(b.roll or 1.6) * dir
	) * sp * 1.45
end
-- Last frame's EFFECTIVE cant state (key OR night vision, and only on a gun that has an
-- NVAimPart). The wobble is kicked when this flips, so a keypress that doesn't actually
-- move the gun -- e.g. toggling cant while NVGs already force it -- stays silent.
-- nil means "not synced yet"; the first frame with a weapon adopts the value without a kick.
springs.cantWasOn = nil
-- Crouch gun tilt: a held roll (left) while crouched and NOT aiming/reloading/etc -- i.e. only
-- during idle and firing. Driven by a damped spring toward its target so it eases in/out and
-- overshoots (bounces) before settling, instead of a flat blend.
springs.crouchTilt = 0
springs.crouchVel = 0

-- Blends the viewmodel lean tilt down when aiming (1 = full tilt, aim-scale when ADS),
-- sprung so it eases in/out instead of snapping the moment you ADS.
springs.vmAim = require(modules.Spring).new(Vector3.new(1, 0, 0))
springs.vmAim.s = config.leanAimBlendSpeed or 11
springs.vmAim.d = 1   -- critically damped: no bounce while the sights align
-- FOV state (stashed on the springs table to avoid top-level locals): smoothed sprint
-- widen offset, and a jump/land punch offset that decays back to 0.
springs.fovSprintCur = 0
springs.fovKickVal = 0
springs.nvFovPrev = false -- last-seen NightVisionActive; used to snap FOV instantly on NV toggle
-- Weapon cant (stashed on springs to avoid new top-level locals): cantOn = player toggled
-- cant with the cant key; cantBlend = eased 0..1 blend between the normal aim pose and the
-- canted NVAimPart pose. Night vision forces canting on regardless of cantOn.
springs.cantOn = false
springs.cantBlend = 0

local net = {
	bodyAnimRequest = mods.bridgeNet.CreateBridge("BodyAnimRequest"),
	switchWeapon = mods.bridgeNet.CreateBridge("SwitchWeapon"),
	playerFire = mods.bridgeNet.CreateBridge("PlayerFire"),
	playSound = mods.bridgeNet.CreateBridge("PlaySound"),
	repReload = mods.bridgeNet.CreateBridge("Reload"),
	repChamber = mods.bridgeNet.CreateBridge("PlayerChamber"),
	moveBolt = mods.bridgeNet.CreateBridge("MoveBolt"),
	switchFireMode = mods.bridgeNet.CreateBridge("SwitchFireMode"),
	playerDropGun = mods.bridgeNet.CreateBridge("PlayerDropGun"),
	playerToggleAttachment = mods.bridgeNet.CreateBridge("PlayerToggleAttachment"),
	repBoltOpen = mods.bridgeNet.CreateBridge("RepBoltOpen"),
	magGrab = mods.bridgeNet.CreateBridge("MagGrab"),
	playerFlipMag = mods.bridgeNet.CreateBridge("PlayerFlipMagnifier"),
	-- Fired at the exact moment our own gun drops a casing, so every other client
	-- can spawn the same brass at the same time regardless of fire mode.
	playerEjectShell = mods.bridgeNet.CreateBridge("PlayerEjectShell"),
}

local fpThreshold = 0.6

cam.rollAngle = 0
cam.cameraLeanRotation = 0

flags.holdingM1 = false
flags.cycled = true
local firstPerson = false
flags.equipping = false
flags.unequipping = false
flags.dead = false
flags.canFire = true
flags.viewmodelVisible = false
local blocked = false
-- Weapon ready-stance system (first person only): scroll down = high ready, scroll up = low ready.
-- ALL ready-stance + prone-overlay state and helpers live in ONE table so the main script
-- chunk stays under Luau's 200-local-register limit (each bare `local` costs a register).
-- Fields:
--   state         = 0 idle/none, 1 high ready, 2 low ready
--   busy          = true while a start or end transition anim is playing
--   currentName   = name of the ready anim currently playing (for stopping)
--   gen           = bumped on every transition to invalidate stale anim callbacks
--   pendingAim    = aim was pressed during a ready stance; begins ADS after the end anim
--   pendingSprint = sprint was triggered from a ready stance; starts the sprint anim after the end anim
--   stanceAnim    = name of the prone enter/exit overlay currently playing (to stop it on the next one)
-- Functions (StartAimFromReady / StartSprintAnim / ClearStanceAnim / PlayStanceTransition) are assigned below.
local sphReady = {
	state = 0, busy = false, currentName = nil, gen = 0,
	pendingAim = false, pendingSprint = false, stanceAnim = nil,
}
local ClearReadyInstant     -- forward declaration (used by DoFadeTransition before its definition)
laser.enabled = false
local laserIsIR = false      -- current laser is the IR variant (has a beam; only visible under night vision)
laser.configKey = nil   -- forces the local laser render to re-configure when mode / NV / perspective changes
-- Laser keybind: a quick tap = normal laser, holding = IR laser. The IR toggle fires
-- WHILE you hold, the moment you cross LASER_HOLD_TIME (checked per-frame in Heartbeat,
-- so no timer race / first-press miss). Releasing before then counts as a tap.
laser.keyDown = false
laser.holdConsumed = false
laser.pressTime = 0
local LASER_HOLD_TIME = 0.4
laser.flashlightEnabled = false
-- Flashlight / IR illuminator state. Everything except `flashlightEnabled` lives on the
-- `springs` table because the main chunk is at ~195 of Luau's 200 local-register limit --
-- each bare `local` costs a register, table fields cost none.
--   isIR         = the light currently on is the IR illuminator (NVG-only), not the white light
--   keyDown / holdConsumed / pressTime / holdTime = tap-vs-hold keybind, same as the laser:
--                  a quick tap = white flashlight, holding past holdTime = IR illuminator
--   configKey    = forces the render loop to re-push the light state when mode / NV /
--                  perspective changes
--   color        = the flashlight + its emitter glow are always pure white
springs.flash = {
	isIR = false,
	keyDown = false,
	holdConsumed = false,
	pressTime = 0,
	holdTime = 0.4,
	configKey = nil,
	color = Color3.fromRGB(255, 255, 255),
}
flags.vehicleSeated = false
flags.ejected = true
flags.cancelReload = false
flags.chambering = false
flags.aimHeld = false
flags.aimTransitionPlaying = false
flags.airborne = false
flags.pendingEquipTool = nil
flags.inspecting = false
flags.fireModeSwitching = false
flags.meleeing = false
flags.fireDelayActive = false

-- Whether the player has toggled into forced first person via V
flags.forcedFirstPerson = false
flags.perspectiveTransitioning = false

local fireModes = {
	Safe = 0,
	Semi = 1,
	Auto = 2,
	Burst = 3,
	Manual = 4
}
flags.bulletsCurrentlyFired = 0
-- Set true once the "ran dry mid-fire" cue has played for the current trigger hold,
-- so it only fires once when the mag empties (reset every time a real shot goes off).
flags.playedDryCue = false

local equipped: Tool, wepStats, gunAmmo, aiming, offset, freeLook
local gunModel: Model
-- Forward-declared here (it's assigned further down) so functions defined above that
-- assignment -- e.g. DoFadeTransition -- reference the real WeaponRig, not a nil global.
local weaponRig
local fakeCameraPart: BasePart
local fakeCameraMotor: Motor6D
cam.fakeCameraSmoothed = Vector3.zero
cam.freeLookOffset = CFrame.new()
cam.freeLookRotation = CFrame.new()
cam.aimingOffset = CFrame.new()
cam.aimTarget = CFrame.new()
-- Seeded from defaultFOV, NOT from camera.FieldOfView: reading the live camera here meant
-- a stale magnified FOV from the previous life became this life's aim target until Equip
-- overwrote it.
cam.aimFOVTarget = defaultFOV
cam.shakeCFrame = CFrame.new()
cam.bipodCFrame = CFrame.new()

cam.headRotationEventCooldown = 0

cam.pushbackOffset = 0
cam.currentPushbackAngle = 0
cam.currentWallYaw = 0
cam.currentWallRoll = 0

-- Smoothed sprint camera Z push -- eases out slowly when decelerating, fast when stopped
cam.sprintCamZ = 0

-- Smoothed Y dip for jump wind-up and landing anims
local JUMP_CAM_DIP = -0.6       -- how far down the camera dips (studs)
cam.jumpCamY = 0

-- Spring impulse for landing -- quick punch down and bounce back
cam.landingCamSpring = mods.springMod.new() -- kept separate, not in springs table
cam.wasLandingLocked = false

cam.hipRotation = Vector2.zero

local storageCFrame = CFrame.new(1000000,0,0)

local loadedAnims = {}
local proneMoveAnim: AnimationTrack
local walkMoveAnim: AnimationTrack
local firstEquippedGuns = {}

cam.cameraOffsetTarget = Vector3.zero

local defaultCameraMode = Enum.CameraMode.Classic

local sights = {}

local sightIndex = 1

local aimSensitivity = player:GetAttribute("SavedAimSensitivity") or config.defaultAimSensitivity
cam.proneViewmodelOffset = 0

local proneToCrouchTransition = false
local previousStance = "Standing"

laser.dotPoint = Instance.new("Attachment")
laser.dotPoint.Parent = workspace.Terrain

laser.beamFP = Instance.new("Beam")
laser.beamFP.Attachment1 = laser.dotPoint
laser.beamFP.LightInfluence = 0
laser.beamFP.Brightness = 3
laser.beamFP.Segments = 1
laser.beamFP.Width0 = 0.02
laser.beamFP.Width1 = 0.02
laser.beamFP.FaceCamera = true
laser.beamFP.Transparency = NumberSequence.new(0.5)
laser.beamFP.Name = "FirstPersonLaser"
laser.beamFP.Parent = laser.dotPoint
laser.beamFP.Enabled = false

laser.beamTP = laser.beamFP:Clone()
laser.beamTP.Name = "ThirdPersonLaser"
laser.beamTP.Parent = laser.dotPoint
laser.beamTP.Enabled = false

-- ===== BEAM LOOK (normal vs IR) ====================================================
-- WHY THE IR BEAM WAS SO FAINT:
--   1. Width 0.02 studs. Past ~30 studs that's well under a pixel, and the night-vision
--      overlay runs a BlurEffect (CONFIG.BlurSize 9.5 in the NVG script) over the whole
--      screen -- a sub-pixel line smeared by a 9.5 blur is nothing.
--   2. Transparency 0.5 on top of that.
--   3. The NVG's ColorCorrection uses Saturation = -1, which fully desaturates the frame
--      before tinting it blue. A saturated IR color (say 255,40,40) has a luminance of
--      only ~0.3, so it collapses to a dark grey and then a dark blue. The beam's COLOR
--      is irrelevant under NV -- only its LUMINANCE survives. That's why we lift the IR
--      beam color toward white.
--   4. Brightness 3 sat below the NV bloom's Threshold of 0.36 once desaturated, so it
--      never picked up any glow.
--
-- The fix is four levers: wider, brighter (HDR, so NV_Bloom grabs it), less transparent,
-- and lifted toward white so it survives the desaturation. Plus a second, much wider and
-- fainter "glow" beam behind it for the scattered-air halo a real IR beam has in a tube.
--
-- NOTE ON WHERE THIS LIVES: all of it hangs off the existing `springs` table instead of
-- being top-level locals. Luau caps the main chunk at 200 local registers and this file
-- is already at the limit (see the do..end around the Keybinds.OnChanged listener) --
-- five more top-level locals here threw
--   "Out of local registers when trying to allocate conn: exceeded limit 200"
-- at the FIRST local declared after them, which is why the error pointed at a line
-- nowhere near this code. `springs` is the file's general stash for exactly this reason.
springs.beamLook = {
	normal = {
		Width0 = 0.02,
		Width1 = 0.02,
		Brightness = 3,
		Transparency = NumberSequence.new(0.5),
		ColorLift = 0,     -- keep the authored laser color exactly
		Glow = false,
	},
	ir = {
		-- Tapered: tight at the emitter, spreading toward the dot, like scatter in air.
		Width0 = 0.03,
		Width1 = 0.07,
		-- HDR. NV_Bloom (Threshold 0.36) turns this into a real glow instead of a hairline.
		-- This is the single biggest visibility lever -- raise it first if it's still weak.
		Brightness = 18,
		-- Fades in off the muzzle so the emitter end doesn't look like a blob, solid
		-- through the middle, easing off at the far end.
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.08, 0.1),
			NumberSequenceKeypoint.new(1, 0.28),
		}),
		-- 0 = the gun's laser color as authored, 1 = pure white. Under NV everything is
		-- desaturated anyway, so this is really "how bright does it read through the tube".
		ColorLift = 0.55,
		Glow = true,
		GlowWidth0 = 0.08,
		GlowWidth1 = 0.22,
		GlowBrightness = 5,
		GlowTransparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.88),
			NumberSequenceKeypoint.new(0.12, 0.74),
			NumberSequenceKeypoint.new(1, 0.92),
		}),
	},
}

-- A wide, faint companion beam sitting behind each real beam -- the halo. Cloned from the
-- beam so it inherits the attachments; only ever enabled for IR.
-- do..end so `makeGlow` releases its register at the end of the block.
do
	local function makeGlow(beam: Beam): Beam
		local g = beam:Clone()
		g.Name = beam.Name .. "Glow"
		g:ClearAllChildren()
		g.Enabled = false
		g.ZOffset = -0.01 -- draw just behind the core beam
		g.Parent = beam.Parent
		return g
	end
	springs.laserGlowFP = makeGlow(laser.beamFP)
	springs.laserGlowTP = makeGlow(laser.beamTP)
end

-- Apply one look to a beam + its glow. `color` is the gun's authored laser color.
function springs.StyleBeam(beam: Beam, glow: Beam, color: Color3, isIR: boolean)
	local look = isIR and springs.beamLook.ir or springs.beamLook.normal
	local shown = color:Lerp(Color3.new(1, 1, 1), look.ColorLift)

	beam.Color        = ColorSequence.new(shown)
	beam.Width0       = look.Width0
	beam.Width1       = look.Width1
	beam.Brightness   = look.Brightness
	beam.Transparency = look.Transparency
	beam.LightInfluence = 0
	beam.FaceCamera   = true

	if look.Glow then
		glow.Color        = ColorSequence.new(shown)
		glow.Width0       = look.GlowWidth0
		glow.Width1       = look.GlowWidth1
		glow.Brightness   = look.GlowBrightness
		glow.Transparency = look.GlowTransparency
		glow.LightInfluence = 0
		glow.FaceCamera   = true
		glow.Attachment0  = beam.Attachment0
		glow.Attachment1  = beam.Attachment1
	end
	glow.Enabled = false -- the caller enables it in step with the core beam
end

-- ===== Laser dot + hit trail =====
-- The laser "dot" IS the ReplicatedStorage.SPH_Assets.LaserTrail part: a neon sphere
-- with a PointLight and a Trail. It rides the point the laser hits; the sphere, its
-- light and the trail are all tinted to the gun's laser color at runtime. If the
-- template is missing, no dot/trail is created.
local LASER_STORAGE_CF = CFrame.new(0, -10000, 0) -- parked here while the laser is off
local laserTrail
laser.visible = false
do
	local template = assets:FindFirstChild("LaserTrail")
	if template and template:IsA("BasePart") then
		laser.trailPart = template:Clone()
		laser.trailPart.Anchored = true
		laser.trailPart.CanCollide = false
		laser.trailPart.CanQuery = false
		laser.trailPart.CanTouch = false
		laser.trailPart.CastShadow = false
		laser.trailPart.Massless = true
		laser.trailPart.CFrame = LASER_STORAGE_CF -- start hidden

		laser.dotLight = laser.trailPart:FindFirstChildWhichIsA("Light")

		local atts = {}
		for _, child in ipairs(laser.trailPart:GetChildren()) do
			if child:IsA("Attachment") then table.insert(atts, child) end
		end

		laserTrail = laser.trailPart:FindFirstChildWhichIsA("Trail")
		if not laserTrail and #atts >= 2 then
			laserTrail = Instance.new("Trail")
			laserTrail.Attachment0 = atts[1]
			laserTrail.Attachment1 = atts[2]
			laserTrail.Lifetime = config.laserTrailLifetime or 0.3
			laserTrail.LightInfluence = 0
			laserTrail.FaceCamera = true
			laserTrail.WidthScale = NumberSequence.new(1, 0)
			laserTrail.Transparency = NumberSequence.new(0, 1)
			laserTrail.Parent = laser.trailPart
		end

		if laserTrail then
			laserTrail.Enabled = false
		end

		laser.trailPart.Parent = workspace.Terrain
	end
end

-- Lens-flare glow on the laser emitter. Stashed on the existing `springs` table (mod +
-- per-model handles) to add NO new top-level local -- Luau caps the main chunk at 200
-- local registers. byModel is keyed by gun model (viewmodel + third-person) so each
-- emitter gets its own flare handle.
springs.laserFlareMod = require(modules.LensFlare)
springs.laserFlareByModel = setmetatable({}, {__mode = "k"})
-- Same idea for the flashlight emitter glow (Grip.FlashPart), keyed per gun model.
springs.flashFlareByModel = setmetatable({}, {__mode = "k"})

-- COLOR-ONLY EMITTER SWITCHING
-- Flipping Transparency on a neon part makes the engine rebuild it every time, which
-- is what was causing the hitch when the laser/flashlight toggled. So both emitter
-- parts (Grip.LaserPart and Grip.FlashPart) now stay permanently VISIBLE at
-- Transparency 0 and only change COLOR: lit = the laser's color / white, off = a dark
-- grey that reads as an unlit emitter. Nothing sets Transparency on them any more.
-- IMPORTANT: set both parts to Transparency 0 in Studio on every gun model, or they'll
-- stay invisible forever.
-- Hung off `springs` rather than declared as locals: this script is already at Luau's
-- 200-local-per-scope ceiling, and two more top-level locals overflow it.
-- One shared off color for BOTH emitters: 55,55,55. On = 255,255,255 for the
-- flashlight, the laser's own color for the laser. Material is never touched at
-- toggle time -- both parts are Neon permanently (see springs.flash.EnsureNeon).
springs.laserPartOffColor = Color3.fromRGB(55, 55, 55) -- unlit laser emitter
springs.flash.offColor    = Color3.fromRGB(55, 55, 55) -- unlit flashlight emitter

-- Force an emitter part to Neon once. Guarded, so a toggle never writes Material
-- (writing it would rebuild the part and bring the hitch straight back).
function springs.flash.EnsureNeon(part)
	if part and part:IsA("BasePart") and part.Material ~= Enum.Material.Neon then
		part.Material = Enum.Material.Neon
	end
end

-- Light up / dim the emitter glow part (Grip.LaserPart) by color, and attach or remove
-- the lens flare on it. An IR laser never lights the emitter -- there's nothing visible
-- to see -- so it sits at the off color even while the laser is on.
local function SetLaserPart(model, on, color)
	if not model then return end
	local grip = model:FindFirstChild("Grip")
	local part = grip and grip:FindFirstChild("LaserPart")
	if part and part:IsA("BasePart") then
		springs.flash.EnsureNeon(part)
		part.Color = (on and color and not laserIsIR) and color or springs.laserPartOffColor
	end

	if on and part and part:IsA("BasePart") then
		local flare = springs.laserFlareByModel[model]
		if not flare then
			local emitterAtt = grip and grip:FindFirstChild("Laser")
			flare = springs.laserFlareMod.attach(part, {
				forwardAttachment = emitterAtt,           -- aim the cone down the beam
				ignore = { character, model, weaponRig },  -- don't self-occlude
				-- No flare for the IR laser, and no flares at all while the viewer's
				-- night vision is on. (Both are live: switching to IR or toggling NVG
				-- hides the flare immediately.)
				shouldShow = function()
					return not laserIsIR and player:GetAttribute("NightVisionActive") ~= true
				end,
				-- Flare tint = the laser's own color (read live).
				getColor = function()
					return emitterAtt and emitterAtt.Color.Value or color
				end,
			})
			springs.laserFlareByModel[model] = flare
		end
	else
		local flare = springs.laserFlareByModel[model]
		if flare then
			flare:Destroy()
			springs.laserFlareByModel[model] = nil
		end
	end
end

-- Grip.Flashlight holds BOTH lights: GunLight (the normal white beam) and IRLight (the
-- IR illuminator, which only renders for a viewer wearing night vision). Returns the
-- attachment plus each light, any of which may be nil on a gun that only has one.
-- (Hung off springs.flash rather than declared as a local -- see the note at the top.)
function springs.flash.GetLights(model)
	local grip = model and model:FindFirstChild("Grip")
	local att = grip and grip:FindFirstChild("Flashlight")
	if not att then return nil, nil, nil end
	local irLight = att:FindFirstChild("IRLight")
	local gunLight = att:FindFirstChild("GunLight")
	if not gunLight then
		-- Fallback for older guns whose single light isn't named GunLight yet.
		local anyLight = att:FindFirstChildWhichIsA("Light")
		if anyLight ~= irLight then gunLight = anyLight end
	end
	return att, gunLight, irLight
end

-- Light up / dim the flashlight's emitter glow part (Grip.FlashPart): the flashlight
-- twin of SetLaserPart. Always-visible neon part, white while the white light is on,
-- springs.flash.offColor when off or while the IR illuminator is the active mode.
-- Also attaches (or removes) the lens flare on that same emitter part. The IR illuminator
-- gets NO flare at all, and the white light's flare is hidden while this viewer has night
-- vision on -- exactly how the laser's flare behaves.
function springs.flash.SetPart(model, on)
	if not model then return end
	local grip = model:FindFirstChild("Grip")
	local part = grip and grip:FindFirstChild("FlashPart")
	if part and part:IsA("BasePart") then
		springs.flash.EnsureNeon(part)
		part.Color = (on and not springs.flash.isIR) and springs.flash.color or springs.flash.offColor
	end

	-- No flare is ever built for the IR illuminator -- an IR beam has no visible glare.
	if on and part and part:IsA("BasePart") and not springs.flash.isIR then
		local flare = springs.flashFlareByModel[model]
		if not flare then
			local emitterAtt = grip and grip:FindFirstChild("Flashlight")
			flare = springs.laserFlareMod.attach(part, {
				color = springs.flash.color,                -- always white
				forwardAttachment = emitterAtt,             -- aim the cone down the beam
				ignore = { character, model, weaponRig },   -- don't self-occlude
				shouldShow = function()
					return not springs.flash.isIR and player:GetAttribute("NightVisionActive") ~= true
				end,
				getColor = function() return springs.flash.color end,
			})
			springs.flashFlareByModel[model] = flare
		end
	else
		local flare = springs.flashFlareByModel[model]
		if flare then
			flare:Destroy()
			springs.flashFlareByModel[model] = nil
		end
	end
end

-- Disable default death sound
if humanoidRootPart:FindFirstChild("Died") then
	humanoidRootPart.Died.Volume = 0
end

-- Unlock the camera if lock first person for guns is enabled
if config.lockFirstPerson then
	player.CameraMode = Enum.CameraMode.Classic
end

-- =====================
-- BLACK FADE UI
-- =====================
local playerGui = player:WaitForChild("PlayerGui")
local fadeGui = Instance.new("ScreenGui")
fadeGui.Name = "PerspectiveFadeGui"
fadeGui.ResetOnSpawn = false
fadeGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
fadeGui.IgnoreGuiInset = true
fadeGui.Parent = playerGui

local fadeFrame = Instance.new("Frame")
fadeFrame.Size = UDim2.new(2, 0, 2, 0)
fadeFrame.Position = UDim2.new(-0.5, 0, -0.5, 0)
fadeFrame.BackgroundColor3 = Color3.new(0, 0, 0)
fadeFrame.BackgroundTransparency = 1
fadeFrame.BorderSizePixel = 0
fadeFrame.ZIndex = 100
fadeFrame.Parent = fadeGui

-- =====================
-- PERSPECTIVE TOGGLE
-- =====================
--
-- HELICOPTER NOTE: the helicopter cockpit draws its own flight cursor (a white
-- dot + centre line) and hides the system cursor to do it. Every place below
-- that hands the cursor BACK is gated on player:GetAttribute("InHelicopterSeat"),
-- which the heli's Client LocalScript sets while you're in the pilot seat --
-- otherwise going third person mid-flight paints the system arrow on top of the
-- flight dot. Written inline rather than as a helper because this script is at
-- Luau's 200-local limit at the top level.
local function ApplyPerspective(toFirstPerson)
	if toFirstPerson then
		camera.CameraSubject = humanoid
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		svc.userInputService.MouseIconEnabled = false
	else
		player.CameraMode = Enum.CameraMode.Classic
		camera.CameraSubject = humanoid
		svc.userInputService.MouseIconEnabled = not equipped
			and player:GetAttribute("InHelicopterSeat") ~= true
	end
end

--[[
	THE DEATH GUARDS BELOW ARE LOAD-BEARING -- this is the "mouse stuck after dying
	in first person" bug.

	This function yields for half a second in total (0.05 + 0.4 + 0.05) while the
	fade plays, and it writes global mouse and camera state on both sides of those
	yields. Nothing used to stop it running to completion after the player died
	part-way through, and humanoid.Died fires in between:

	  * Died sets MouseIconEnabled = true and MouseBehavior = Default, then this
	    function resumes after its task.wait(0.4) and runs
	        userInputService.MouseIconEnabled = not toFirstPerson and not equipped
	    which, going INTO first person, is false. The cursor is taken away again
	    immediately after death, and nothing puts it back -- until you toggle
	    first person off, whose own final line sets it true. Which is exactly the
	    "toggle in and out to fix it" report.

	  * Dying inside the first 0.05s is worse: Died sets CameraMode = Classic, and
	    then ApplyPerspective below overwrites it with LockFirstPerson, leaving a
	    dead player locked into a first-person camera with the mouse centred.

	So: bail at every yield boundary once `dead` is set, and clear the fade and the
	transitioning flag on the way out rather than leaving the screen black and the
	toggle permanently jammed.
--]]
local function DoFadeTransition(toFirstPerson)
	if flags.perspectiveTransitioning or flags.dead then return end
	flags.perspectiveTransitioning = true

	svc.userInputService.MouseIconEnabled = false

	svc.tweenService:Create(fadeFrame, TweenInfo.new(0.05, Enum.EasingStyle.Linear), {BackgroundTransparency = 0}):Play()
	task.wait(0.05)

	-- Died during the fade-in. Hand the mouse straight back and get out before
	-- touching CameraMode -- the Died handler has already set the state it wants.
	if flags.dead then
		fadeFrame.BackgroundTransparency = 1
		svc.userInputService.MouseIconEnabled = true
		svc.userInputService.MouseBehavior = Enum.MouseBehavior.Default
		flags.perspectiveTransitioning = false
		return
	end

	ApplyPerspective(toFirstPerson)
	flags.forcedFirstPerson = toFirstPerson
	firstPerson = toFirstPerson
	character:SetAttribute("SPH_FirstPerson", toFirstPerson)
	if not toFirstPerson then ClearReadyInstant() end -- ready is FP-only; prone overlay stays (it plays in 3rd person too)

	if toFirstPerson then
		flags.viewmodelVisible = false
		-- Going to first person: clear the mouse lock
		character:SetAttribute("SPH_GunLockedMouse", false)
		if equipped then
			BindAiming()
			-- (Flashlight / IR illuminator no longer needs a manual swap here: the render
			-- loop re-pushes it whenever the perspective, mode or night vision changes.)
			springs.flash.configKey = nil
			if laser.enabled and config.laserTrail and not laserIsIR then
				laser.beamTP.Enabled = false
				laser.beamFP.Enabled = true
			end
		end
	else
		-- Keep the aim action bound in third person too so right-click can trigger
		-- over-the-shoulder aim; only unbind when unarmed.
		if equipped then BindAiming() else UnbindAiming() end
		-- Going to third person: enable mouse lock if gun is equipped
		if equipped then
			svc.userInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			character:SetAttribute("SPH_GunLockedMouse", true)
			if laser.enabled and config.laserTrail and not laserIsIR then
				laser.beamTP.Enabled = true
				laser.beamFP.Enabled = false
				if not laser.beamTP.Attachment0 and gunModel then
					-- Inlined instead of calling GetThirdPersonGunModel(); that local function
					-- is defined further down the file and isn't in scope this high up.
					laser.beamTP.Attachment0 = weaponRig.Weapon:FindFirstChildWhichIsA("Model").Grip.Laser
				end
			end
			-- (Same as above: the render loop hands the light over to the third-person
			-- model on the next frame.)
			springs.flash.configKey = nil
		else
			-- No gun: release any leftover first-person mouse lock so third person
			-- isn't stuck locked / still behaving like first person.
			svc.userInputService.MouseBehavior = Enum.MouseBehavior.Default
			character:SetAttribute("SPH_GunLockedMouse", false)
		end
		flags.viewmodelVisible = false
		cam.cameraOffsetTarget = Vector3.zero
	end

	task.wait(0.4)

	svc.tweenService:Create(fadeFrame, TweenInfo.new(0.05, Enum.EasingStyle.Linear), {BackgroundTransparency = 1}):Play()
	task.wait(0.05)

	-- The line below is the one that took the cursor away after death: going into
	-- first person it evaluates to false, and it ran AFTER humanoid.Died had
	-- already handed the mouse back. A dead player keeps the cursor, always.
	if flags.dead then
		fadeFrame.BackgroundTransparency = 1
		svc.userInputService.MouseIconEnabled = true
		svc.userInputService.MouseBehavior = Enum.MouseBehavior.Default
		flags.perspectiveTransitioning = false
		return
	end

	svc.userInputService.MouseIconEnabled = not toFirstPerson and not equipped
		and player:GetAttribute("InHelicopterSeat") ~= true

	flags.perspectiveTransitioning = false
end

svc.userInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.V then
		-- Perspective is LOCKED while something owns the camera (binoculars on the
		-- glass). Toggling mid-use would leave that script holding a perspective it
		-- never asked for, and it would hand the wrong one back when it finishes.
		if character:GetAttribute("SPH_PerspectiveLocked") then return end
		DoFadeTransition(not flags.forcedFirstPerson)
	end
end)

--[[ PERSPECTIVE REQUESTS FROM OTHER SCRIPTS -------------------------------------
	Lets another script ask for a perspective by setting
	    character:SetAttribute("SPH_ForcePerspective", true/false)
	and have the change go through DoFadeTransition, so the fade plays and
	forcedFirstPerson / firstPerson / SPH_FirstPerson all stay truthful. Used by the
	binoculars, which need first person while you're on the glass.

	A REQUEST IS A ONE-SHOT, NOT A STANDING ORDER. The value is cleared back to nil
	the moment it's read, BEFORE the transition runs. This is load-bearing: left
	set, the attribute pins the camera forever -- every later attempt to go third
	person gets yanked straight back to first, and worse, the kit genuinely believes
	it is in first person, so whatever asked for it is told the wrong thing to
	restore. Clearing it first also stops the yield inside DoFadeTransition letting
	the next poll see the same request and fire it twice.

	The companion attribute "SPH_PerspectiveLocked" blocks the V key for as long as
	another script owns the camera -- see the InputBegan handler above.

	Declares NO top-level locals -- this file is at Luau's 200-local limit, so
	everything lives inside the closure.

	Polls rather than using GetAttributeChangedSignal because DoFadeTransition
	yields ~0.5s and bails outright while flags.perspectiveTransitioning is set: a
	request landing mid-transition would be dropped by a one-shot signal handler.
	Here it simply waits, still set, and is picked up on the next pass.
--]]
task.spawn(function()
	while character.Parent do
		local want = character:GetAttribute("SPH_ForcePerspective")

		if want ~= nil and not flags.perspectiveTransitioning and not flags.dead then
			character:SetAttribute("SPH_ForcePerspective", nil) -- consume before acting
			if want ~= flags.forcedFirstPerson then
				DoFadeTransition(want)
			end
		end

		task.wait(0.05)
	end
end)

-- =====================

-- The environment sound emitter is now created server-side (MakeCharacterRig) so it
-- replicates to all clients; gun environment sounds emit from the same part for everyone.
local envSoundRef = character:WaitForChild("EnvSoundPartRef", 10)
local envSoundPart = (envSoundRef and envSoundRef.Value) or head
local envSoundFarRef = character:WaitForChild("EnvSoundPartFarRef", 10)
local envSoundPartFar = (envSoundFarRef and envSoundFarRef.Value) or envSoundPart

rig = mods.viewMod.RigModel(player)

local lArm = rig["Left Arm"]
local rArm = rig["Right Arm"]
lArm.Color = character["Left Arm"].Color
rArm.Color = character["Right Arm"].Color

for _, part in ipairs(rig:GetDescendants()) do
	if part.Name == "Skin" then
		if part.Parent.Name == "Left Arm" then
			part.Color = character["Left Arm"].Color
		elseif part.Parent.Name == "Right Arm" then
			part.Color = character["Right Arm"].Color
		end
	end
end

local vmHuman = Instance.new("Humanoid",rig)
for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
	if state == Enum.HumanoidStateType.None then continue end
	vmHuman:SetStateEnabled(state,false)
end

local vmAnimator = Instance.new("Animator",vmHuman)
local vmShirt = Instance.new("Shirt",rig)
local animBase = rig.AnimBase
animBase.CFrame = storageCFrame

rig.Parent = camera

weaponRig = character:FindFirstChild("WeaponRig") or character:WaitForChild("WeaponRig", 20)
local characterAnimator:Animator = weaponRig:WaitForChild("AnimationController").Animator

local function PlayRandomSoundFromFolder(folder, parent)
	if not folder then return end
	local sounds = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Sound") then
			table.insert(sounds, child)
		end
	end
	if #sounds == 0 then return end
	local chosen = sounds[math.random(1, #sounds)]
	local clone = chosen:Clone()
	clone.PlaybackSpeed = clone.PlaybackSpeed * (math.random(95, 105) / 100)
	clone.Parent = parent
	clone:Play()
	svc.debris:AddItem(clone, clone.TimeLength + 0.5)
end

local function PlayRepSound(soundName)
	if not flags.dead then
		local target = gunModel.Grip:FindFirstChild(soundName)
		if target and equipped then
			if target:IsA("Folder") then
				-- A folder of variants (e.g. AimUp / AimDown): play a random one locally;
				-- the server picks one for other players (see its playSound handler).
				PlayRandomSoundFromFolder(target, firstPerson and gunModel.Grip or humanoidRootPart)
			elseif firstPerson then
				target:Play()
			else
				local clone = target:Clone()
				clone.Parent = humanoidRootPart
				clone:Play()
				svc.debris:AddItem(clone, clone.TimeLength)
			end
			net.playSound:Fire(soundName, firstPerson)
		end
	end
end

local indoorCheckParams = RaycastParams.new()
indoorCheckParams.FilterType = Enum.RaycastFilterType.Exclude
indoorCheckParams.IgnoreWater = true

--[[
	IsIndoors is a single 50-stud ray straight up from the head. Anything it hits
	counts as a ceiling and the gun switches to its FireEnvIndoor layer. That is
	right for buildings and wrong for a helicopter: the airframe above you is not
	a room, and firing from a door gunner's seat should sound like open air.

	INDOOR-ACOUSTICS EXEMPTION -- tag anything "NoIndoorSound".

	Tag a BasePart, or a Model/Folder to cover everything inside it: the filter
	matches DESCENDANTS, so one tag on the helicopter model exempts the whole
	airframe. Tags survive :Clone(), so tagging the TEMPLATE in
	ReplicatedStorage/ServerStorage means every spawned helicopter inherits it.

	NO CACHE, ON PURPOSE. The obvious implementation keeps a tagged set at the
	top level and rebuilds it on the CollectionService signals -- but this script
	compiles at exactly Luau's 200-local ceiling, and ONE more top-level local
	fails the whole file with "Out of local registers". So the tagged list is
	fetched inside the function, where it costs no top-level register at all.

	GetTagged allocates a fresh array per call, which is why this is only
	acceptable here: it runs once per shot (a handful of times a second at most),
	not per frame. Do not copy this pattern into a RenderStepped loop.

	Instances tagged outside workspace (the ReplicatedStorage template) come back
	too. Harmless -- the ray cannot hit something that is not in the world.
--]]
local function IsIndoors()
	local exclude = {character}
	if weaponRig then table.insert(exclude, weaponRig) end
	if gunModel then table.insert(exclude, gunModel) end
	for _, inst in ipairs(svc.collectionService:GetTagged("NoIndoorSound")) do
		exclude[#exclude + 1] = inst
	end
	indoorCheckParams.FilterDescendantsInstances = exclude

	local headPos = humanoidRootPart.Position + Vector3.new(0, 4, 0)
	local result = workspace:Raycast(headPos, Vector3.new(0, 50, 0), indoorCheckParams)
	return result ~= nil
end

local function PlayFireSounds()
	if not gunModel then return end
	local grip = gunModel.Grip
	local fireSounds = grip:FindFirstChild("FireSounds")
	if not fireSounds then return end

	local muzzle = grip:FindFirstChild("Muzzle")

	local muzzleTarget = (firstPerson and muzzle) or humanoidRootPart
	local envTarget = envSoundPart

	for _, layerName in ipairs({"Fire", "FireBass", "FireFar"}) do
		local folder = fireSounds:FindFirstChild(layerName)
		if folder then
			PlayRandomSoundFromFolder(folder, muzzleTarget)
		end
	end

	local indoors = IsIndoors()
	local envLayerName = indoors and "FireEnvIndoor" or "FireEnv"
	local envFolder = fireSounds:FindFirstChild(envLayerName)
	if envFolder then
		PlayRandomSoundFromFolder(envFolder, envTarget)
	end

	-- Far echo layer: play it locally too, from the 900-stud far emitter.
	local envFarFolder = fireSounds:FindFirstChild("FireEnvFar")
	if envFarFolder then
		PlayRandomSoundFromFolder(envFarFolder, envSoundPartFar)
	end

	-- Tell the server to replicate fire sounds to other players
	net.playSound:Fire("FireSounds", firstPerson, indoors)
end

local function IsLoaded()
	return not wepStats.openBolt and equipped.Chambered.Value or wepStats.openBolt and gunAmmo.MagAmmo.Value > 0
end

local function MoveBolt(direction:CFrame,silent:boolean)
	mods.bulletHandler.MoveBolt(gunModel,wepStats,direction,gunAmmo.MagAmmo.Value)
	mods.bulletHandler.MoveBolt(weaponRig.Weapon:FindFirstChildWhichIsA("Model"),wepStats,direction,gunAmmo.MagAmmo.Value)
	-- (Out-of-ammo sound is handled by the single "ran dry" cue in the fire loop,
	-- so it isn't played here anymore to avoid a doubled sound on the last shot.)
	net.moveBolt:Fire(direction,gunAmmo.MagAmmo.Value)
end

local function ToggleADS(toggle)
	if wepStats and wepStats.ADSEnabled then
		local ADSTween
		if wepStats.aimTime then
			ADSTween = TweenInfo.new(wepStats.aimTime / 20,Enum.EasingStyle.Linear,Enum.EasingDirection.Out,0,false,wepStats.aimTime / 20)
		else
			ADSTween = TweenInfo.new(0.2,Enum.EasingStyle.Linear,Enum.EasingDirection.Out,0,false,0.2)
		end
		if not toggle then
			for _, child in pairs(gunModel:GetChildren()) do
				if child.Name == "REG" then
					svc.tweenService:Create(child, ADSTween, {Transparency = 0}):Play()
				elseif child.Name == "ADS" then
					svc.tweenService:Create(child, ADSTween, {Transparency = 1}):Play()
				end
			end
		elseif toggle then
			for _, child in pairs(gunModel:GetChildren()) do
				if child.Name == "REG" then
					svc.tweenService:Create(child, ADSTween, {Transparency = 1}):Play()
				elseif child.Name == "ADS" then
					svc.tweenService:Create(child, ADSTween, {Transparency = 0}):Play()
				end
			end
		end
	end
end

local function EjectShell()
	flags.ejected = true
	if wepStats.shellEject and config.shellEjection then
		local delay = wepStats.shellEjectDelay or 0
		if delay > 0 then
			local curEquipped = equipped
			local curGunModel = gunModel
			task.delay(delay, function()
				if equipped ~= curEquipped then return end
				if firstPerson then
					shellEjection.ejectShell(player, curEquipped, curGunModel)
				else
					shellEjection.ejectShell(player, curEquipped, weaponRig.Weapon:FindFirstChildWhichIsA("Model"))
				end
				-- Tell everyone else. Fired from INSIDE the delay so their casing leaves
				-- the gun at the same moment ours does.
				net.playerEjectShell:Fire()
			end)
		else
			if firstPerson then
				shellEjection.ejectShell(player,equipped,gunModel)
			else
				shellEjection.ejectShell(player,equipped,weaponRig.Weapon:FindFirstChildWhichIsA("Model"))
			end
			net.playerEjectShell:Fire()
		end
	end
end

local function GetThirdPersonGunModel()
	return weaponRig.Weapon:FindFirstChildWhichIsA("Model")
end

local function StopAnimation(animName:string, transTime:number)
	if loadedAnims[animName] then
		if transTime then
			loadedAnims[animName]:Stop(transTime)
			loadedAnims[animName.."ThirdPerson"]:Stop(transTime)
		else
			loadedAnims[animName]:Stop()
			loadedAnims[animName.."ThirdPerson"]:Stop()
		end
	end
end

local function SwitchFireMode()
	local repitions = 0
	repeat
		repitions += 1
		flags.curFireMode += 1
		if flags.curFireMode > 4 then
			if wepStats.noSafety or true then
				flags.curFireMode = 1
			else
				flags.curFireMode = 0
				break
			end
		end
	until wepStats.fireSwitch[flags.curFireMode] or repitions > 10
	net.switchFireMode:Fire(flags.curFireMode)
end

local function UpdateAllBulletTransparency(bulletHolderPart:BasePart, transparency:number)
	for _, child in bulletHolderPart:GetChildren() do
		if child:IsA("BasePart") and string.sub(child.Name, 1, 6) == "Bullet" then
			child.Transparency = transparency
		end
	end
end

local function UpdateBulletTransparency(bulletHolderPart:BasePart, bulletNumber:number, transparency:number)
	local bulletName = "Bullet"..bulletNumber
	for _, child in bulletHolderPart:GetChildren() do
		if child:IsA("BasePart") and child.Name == bulletName then
			child.Transparency = transparency
		end
	end
end

local function PlayAnimation(animName:string, parameters:table, animType:string, preload)
	parameters = parameters or {}
	local animObject = animName and animations:FindFirstChild(animName)
	local animToPlay, tpAnim
	if loadedAnims[animName] then
		animToPlay = loadedAnims[animName]
		tpAnim = loadedAnims[animName.."ThirdPerson"]
	elseif animName and animObject then
		local newAnim = vmAnimator:LoadAnimation(animObject)
		newAnim.Looped = parameters.looped or false
		newAnim.Priority = parameters.priority or Enum.AnimationPriority.Action
		loadedAnims[animName] = newAnim

		local thirdPersonAnim:AnimationTrack = characterAnimator:LoadAnimation(animObject)
		thirdPersonAnim.Looped = parameters.looped or false
		thirdPersonAnim.Priority = parameters.priority or Enum.AnimationPriority.Action
		loadedAnims[animName.."ThirdPerson"] = thirdPersonAnim

		newAnim.KeyframeReached:Connect(function(keyframeName)
			if gunModel.Grip:FindFirstChild(keyframeName) then
				PlayRepSound(keyframeName)
			end

			if keyframeName == "MagIn" then
				local bulletHolderPart = wepStats.bulletHolder and gunModel:FindFirstChild(wepStats.bulletHolder)
				if bulletHolderPart then
					UpdateAllBulletTransparency(bulletHolderPart, 0)
				end
				net.repReload:Fire()
				if wepStats.magType > 1 then
					newAnim.DidLoop:Once(function()
						StopAnimation(animName)
					end)
				end
			elseif keyframeName == "ShellInsert" or keyframeName == "BulletInsert" then
				if flags.cancelReload then
					flags.cancelReload = false
					newAnim.Looped = false
					newAnim.Stopped:Once(function()
						if not equipped then return end
						StopAnimation(newAnim.Name)
						if not equipped.BoltReady.Value or wepStats.openBolt then
							local boltTrack = PlayAnimation(wepStats.boltClose,{priority = Enum.AnimationPriority.Action2})
							if boltTrack then
								boltTrack.Stopped:Once(function()
									flags.reloading = false
									character:SetAttribute("Reloading", false)
								end)
							end
						else
							flags.reloading = false
							character:SetAttribute("Reloading", false)
						end
					end)
				elseif gunAmmo.MagAmmo.Value + 1 >= gunAmmo.MagAmmo.MaxValue or gunAmmo.ArcadeAmmoPool.Value - 1 <= 0 then
					newAnim.DidLoop:Once(function()
						if not equipped then return end
						StopAnimation(newAnim.Name)
						if not equipped.BoltReady.Value or wepStats.operationType == 3 or wepStats.openBolt then
							local boltTrack = PlayAnimation(wepStats.boltClose,{priority = Enum.AnimationPriority.Action2})
							if boltTrack then
								boltTrack.Stopped:Once(function()
									flags.reloading = false
									character:SetAttribute("Reloading", false)
								end)
							end
						else
							flags.reloading = false
							character:SetAttribute("Reloading", false)
						end
					end)
				elseif wepStats.openBolt then
				end
				local bulletHolderPart = wepStats.bulletHolder and gunModel:FindFirstChild(wepStats.bulletHolder)
				if bulletHolderPart then
					local bulletNumber = gunAmmo.MagAmmo.MaxValue - gunAmmo.MagAmmo.Value
					UpdateBulletTransparency(bulletHolderPart, bulletNumber, 0)
				end
				net.repReload:Fire()
			elseif keyframeName == "ClipInsertEnd" then
				local ammoNeeded = gunAmmo.MagAmmo.MaxValue - gunAmmo.MagAmmo.Value
				local clipSize = wepStats.clipSize or wepStats.magazineCapacity
				if ammoNeeded > 0 then
					StopAnimation(newAnim.Name)
					if ammoNeeded >= clipSize then
						PlayAnimation(wepStats.clipReloadAnim,{looped = true,speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17})
					else
						PlayAnimation(wepStats.reloadAnim,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17},"Reload")
					end
				end
			elseif keyframeName == "ClipInsert" then
				net.repReload:Fire()
			elseif keyframeName == "SlideRelease" or keyframeName == "BoltClose" then
				net.repChamber:Fire()
				-- Only clear reloading here during standalone chambering (not mid-reload)
				-- During a reload, the animation's Stopped handler clears it when the full anim finishes
				if flags.chambering then
					flags.reloading = false
					character:SetAttribute("Reloading", false)
				end
				MoveBolt(CFrame.new(),true)
			elseif keyframeName == "SlidePull" and equipped.Chambered.Value then
				EjectShell()
			elseif keyframeName == "Switch" and not flags.reloading then
				SwitchFireMode()
			elseif keyframeName == "MagGrab" then
				if gunModel and wepStats.projectile ~= "Bullet" and gunModel:FindFirstChild(wepStats.projectile) then
					local projectile = gunModel:FindFirstChild(wepStats.projectile)
					projectile.LocalTransparencyModifier = 0
					for _, child in ipairs(projectile:GetDescendants()) do
						if child:IsA("BasePart") then child.LocalTransparencyModifier = 0 end
					end
					local thirdPersonGunModel = GetThirdPersonGunModel()
					local projectile2 = thirdPersonGunModel:FindFirstChild(wepStats.projectile)
					projectile2.LocalTransparencyModifier = 0
					for _, child in ipairs(projectile2:GetDescendants()) do
						if child:IsA("BasePart") then child.LocalTransparencyModifier = 0 end
					end
					net.magGrab:Fire()
				end
			elseif keyframeName == "BoltOpen" then
				net.repBoltOpen:Fire()
				if not flags.ejected then EjectShell() end
			elseif keyframeName == "MagPouch" then
				local bulletHolderPart = wepStats.bulletHolder and gunModel:FindFirstChild(wepStats.bulletHolder)
				if bulletHolderPart then
					UpdateAllBulletTransparency(bulletHolderPart, 0)
				end
			end
		end)

		newAnim.Stopped:Connect(function()
			if animType == "Equip" then
			elseif animType == "Reload" then
				flags.reloading = false
				-- Only update the UI attribute if autoChamber won't immediately set reloading back to true
				if not (wepStats and wepStats.autoChamber and equipped and (not equipped.Chambered.Value or wepStats.openBolt)) then
					character:SetAttribute("Reloading", false)
				end
				if wepStats and gunModel and gunModel:FindFirstChild(wepStats.projectile) and equipped.Chambered.Value then
					local projectile = gunModel:FindFirstChild(wepStats.projectile)
					projectile.LocalTransparencyModifier = 0
					for _, child in ipairs(projectile:GetDescendants()) do
						if child:IsA("BasePart") then child.LocalTransparencyModifier = 0 end
					end
				end
			end
		end)

		animToPlay = newAnim
		tpAnim = thirdPersonAnim
	end

	local playAnimFP = true
	if animType == "AimAnim" and not config.firstPersonAimAnim then
		playAnimFP = false
	end

	if animToPlay and not preload then
		if playAnimFP then
			animToPlay:Play(parameters.transSpeed or 0)
			animToPlay:AdjustSpeed(parameters.speed or 1)
		end
		tpAnim:Play(parameters.transSpeed or 0)
		tpAnim:AdjustSpeed(parameters.speed or 1)
	end

	return animToPlay, animObject
end

-- =====================
-- WEAPON READY STANCES (first person only)
-- Scroll down = high ready, scroll up = low ready. Each stance plays start -> loop,
-- and an end anim when you leave it (opposite scroll, or attempting any action).
-- The six anims are per-weapon in WeaponStats (highReady*/lowReady*).
-- =====================
local function ReadyAnimSet(stateType)
	if stateType == 1 then
		return wepStats.highReadyStartAnim, wepStats.highReadyLoopAnim, wepStats.highReadyEndAnim
	else
		return wepStats.lowReadyStartAnim, wepStats.lowReadyLoopAnim, wepStats.lowReadyEndAnim
	end
end

-- Stop whatever ready anim is currently playing (start, loop or end)
local function StopReadyCurrent(fade)
	if sphReady.currentName then
		StopAnimation(sphReady.currentName, fade or 0.2)
		sphReady.currentName = nil
	end
end

-- Enter a ready stance (1 = high, 2 = low): play start, then loop.
local function EnterReady(stateType)
	if not wepStats then return end
	local startName, loopName = ReadyAnimSet(stateType)
	sphReady.gen += 1
	local myGen = sphReady.gen
	sphReady.state = stateType
	sphReady.busy = true
	sphReady.pendingAim = false -- entering a stance cancels any queued aim
	sphReady.pendingSprint = false -- ...and any queued sprint
	StopReadyCurrent(0.1)
	local function playLoop()
		if myGen ~= sphReady.gen then return end
		sphReady.busy = false
		springs.KickSettle(1) -- the gun arrives in the stance and settles
		if loopName then
			sphReady.currentName = loopName
			PlayAnimation(loopName, {looped = true, priority = Enum.AnimationPriority.Action, transSpeed = 0.2})
		else
			sphReady.currentName = nil
		end
	end
	if startName then
		sphReady.currentName = startName
		local track = PlayAnimation(startName, {looped = false, priority = Enum.AnimationPriority.Action, transSpeed = 0.2})
		if track then
			track.Stopped:Once(playLoop)
		else
			playLoop()
		end
	else
		playLoop()
	end
end

-- Exit the current ready stance: play the end anim, then return to idle.
local function ExitReady()
	if sphReady.state == 0 then return end
	local _, _, endName = ReadyAnimSet(sphReady.state)
	sphReady.gen += 1
	local myGen = sphReady.gen
	sphReady.state = 0
	sphReady.busy = true
	StopReadyCurrent(0.15)
	-- Runs when the end transition is fully done: clear busy and, if aim was pressed
	-- during the stance, begin aiming now (deferred so it starts after the end anim).
	local function finishExit()
		sphReady.busy = false
		sphReady.currentName = nil
		springs.KickSettle(-1) -- coming back down out of the stance, opposite direction
		if sphReady.pendingSprint then
			-- Sprint was requested from the stance: now that the end anim has fully played,
			-- kick off the sprint anim (only if we're actually still sprinting). Sprint wins
			-- over a queued aim.
			sphReady.pendingSprint = false
			sphReady.pendingAim = false
			if flags.sprinting and equipped and not flags.dead and sphReady.StartSprintAnim then sphReady.StartSprintAnim() end
		elseif sphReady.pendingAim then
			sphReady.pendingAim = false
			if sphReady.StartAimFromReady then sphReady.StartAimFromReady() end
		end
	end
	-- How much of the end animation must play before a QUEUED aim takes over. You only
	-- wait this fraction of the end anim, then the rest crossfades straight into ADS.
	local READY_AIM_FRACTION = 0.5
	if endName then
		sphReady.currentName = endName
		local track = PlayAnimation(endName, {looped = false, priority = Enum.AnimationPriority.Action, transSpeed = 0.15})
		if track then
			if sphReady.pendingAim then
				-- Aim is queued: don't wait for the whole end anim. Start ADS once the end anim
				-- is ~halfway, fading the remaining half out so it blends smoothly into the sights.
				local started = false
				local function startAimEarly()
					if started then return end
					if myGen ~= sphReady.gen then return end
					started = true
					-- Sprint queued after the aim, or the aim was released during the first half:
					-- fall back to the normal finish so busy / sprint are handled correctly.
					if sphReady.pendingSprint or not sphReady.pendingAim then
						finishExit()
						return
					end
					sphReady.pendingAim = false
					sphReady.busy = false
					StopReadyCurrent(0.15) -- crossfade the remaining half of the end anim out
					if sphReady.StartAimFromReady then sphReady.StartAimFromReady() end
				end
				task.spawn(function()
					-- Wait until the clip length is known (a few frames at most), then fire at the
					-- halfway point of the end anim.
					local waited = 0
					while track.Length <= 0 and waited < 0.2 and myGen == sphReady.gen do
						waited += task.wait()
					end
					if myGen ~= sphReady.gen then return end
					local dur = (track.Length > 0 and track.Length) or 0.4
					local remaining = dur * READY_AIM_FRACTION - waited
					if remaining > 0 then task.wait(remaining) end
					startAimEarly()
				end)
				-- Safety: if the end anim finishes before the halfway timer, proceed anyway.
				track.Stopped:Once(function()
					if myGen ~= sphReady.gen then return end
					startAimEarly()
				end)
			else
				track.Stopped:Once(function()
					if myGen ~= sphReady.gen then return end
					finishExit()
				end)
			end
		else
			finishExit()
		end
	else
		finishExit()
	end
end

-- Instantly wipe ready state with no end anim (unequip, death, leaving first person).
function ClearReadyInstant()
	sphReady.gen += 1
	sphReady.state = 0
	sphReady.busy = false
	sphReady.pendingAim = false -- instant wipe drops any queued aim too
	sphReady.pendingSprint = false -- ...and any queued sprint
	StopReadyCurrent(0.1)
end

-- =====================
-- PRONE ENTER / EXIT OVERLAY (first AND third person)
-- Cosmetic only: plays a gun anim when you drop to / rise from prone. It does NOT lock
-- anything -- fire, aim, reload, melee etc. all keep working and simply play over it, so
-- higher-priority action anims (Action2) win and this gives way. PlayAnimation plays both
-- the viewmodel and the character-animator (third person / replicated) tracks, so it shows
-- in both views and to other players. Anims are per-weapon: wepStats.proneEnterAnim /
-- wepStats.proneExitAnim (optional -- omit either to skip that direction).
-- =====================
-- Stop the current transition overlay (called on unequip / death / leaving first person).
function sphReady.ClearStanceAnim()
	if sphReady.stanceAnim then
		StopAnimation(sphReady.stanceAnim, 0.15)
		sphReady.stanceAnim = nil
	end
end

function sphReady.PlayStanceTransition(animName)
	-- Interrupt any previous overlay first (e.g. going prone then immediately standing up
	-- while the enter anim is still playing -> stop it and let the exit anim take over).
	if sphReady.stanceAnim then
		StopAnimation(sphReady.stanceAnim, 0.1)
		sphReady.stanceAnim = nil
	end
	if not animName then return end -- weapon has no prone anim: nothing to do
	sphReady.stanceAnim = animName
	-- Action priority (same tier as the aim anim) so it reads while ADS but still yields to
	-- Action2 stuff like firing/reloading. Tune wepStats.proneAnimPriority per weapon if needed.
	local prio = wepStats and wepStats.proneAnimPriority or Enum.AnimationPriority.Action
	local track = PlayAnimation(animName, {looped = false, priority = prio, transSpeed = 0.12})
	if track then
		track.Stopped:Once(function()
			-- Only clear if this is still the anim we started (a newer transition may have taken over).
			if sphReady.stanceAnim == animName then sphReady.stanceAnim = nil end
		end)
	end
end

local function ChamberAnim()
	-- Already chambering (or queued to chamber): ignore repeat presses.
	if flags.chambering then return end

	-- Wait for the fire animation to FULLY finish before chambering. Both the fire anim
	-- and the bolt/chamber anim run at Action2, so if the fire anim is still playing the
	-- two blend together and the bolt anim comes out watered down / half-played. If the
	-- fire anim is still going, lock chambering and queue it to run the instant it stops.
	if wepStats.fireAnim then
		local fireTrack = loadedAnims[wepStats.fireAnim]
		if fireTrack and fireTrack.IsPlaying then
			flags.chambering = true -- lock out re-fire / re-chamber during the wait
			fireTrack.Stopped:Once(function()
				flags.chambering = false
				-- Bail if the gun's gone (unequipped / died) while we were waiting.
				if not equipped or flags.dead then return end
				ChamberAnim()
			end)
			return
		end
	end

	local animNameToPlay
	if equipped.BoltReady.Value or flags.curFireMode == fireModes.Manual then
		animNameToPlay = wepStats.boltChamber
	else
		animNameToPlay = wepStats.boltClose
	end
	if animNameToPlay then
		flags.reloading = true
		flags.chambering = true
		local playingAnim:AnimationTrack = PlayAnimation(animNameToPlay,{priority = Enum.AnimationPriority.Action2,transSpeed = 0.05})
		playingAnim.Stopped:Once(function()
			flags.chambering = false
		end)
	end
end

local function IdleAnim()
	PlayAnimation(wepStats.idleAnim,{looped = true, priority = Enum.AnimationPriority.Idle})
end

local function EquipAnim()
	local animToUse = wepStats.equipAnim
	if wepStats.firstEquipAnim and not firstEquippedGuns[equipped.Name] then
		firstEquippedGuns[equipped.Name] = true
		animToUse = wepStats.firstEquipAnim
	end
	local animTrack:AnimationTrack = PlayAnimation(animToUse,{priority = Enum.AnimationPriority.Action2, looped = false, speed = (wepStats.equipSpeedModifier or 1)},"Equip")
	local loadAttempts = 0
	while loadAttempts < 20 and (animTrack.Length == 0 or animBase.AnimBase_Grip.Transform == CFrame.new()) do
		loadAttempts += 1
		task.wait()
	end
	if firstPerson then flags.viewmodelVisible = true end
	local projectile = gunModel:FindFirstChild(wepStats.projectile)
	if (wepStats.openBolt or not equipped.Chambered.Value) and projectile and wepStats.projectile ~= "Bullet" then
		projectile.LocalTransparencyModifier = 1
		for _, child in ipairs(projectile:GetDescendants()) do
			if child:IsA("BasePart") then child.LocalTransparencyModifier = 1 end
		end
	end
end

-- Plays the unequip animation and yields until it finishes.
-- Uses wepStats.unequipAnim if defined, otherwise plays equipAnim in reverse.
local function UnequipAnim()
	if not wepStats or flags.dead then return false end
	flags.unequipping = true
	-- Hold duration for the full unequip transition (used by the deadline below)
	local unequipDur = wepStats.unequipTime or wepStats.equipTime or 1

	-- Cancel any ongoing actions
	if aiming then
		aiming = false
		character:SetAttribute("Aiming", false)
	end
	if flags.reloading then
		flags.cancelReload = true
		flags.reloading = false
		character:SetAttribute("Reloading", false)
	end
	flags.holdingM1 = false
	flags.canFire = false

	local animName = wepStats.unequipAnim or wepStats.equipAnim
	if not animName then
		flags.unequipping = false
		return false
	end

	local isReverse = (wepStats.unequipAnim == nil)
	local speed = wepStats.unequipSpeedModifier or wepStats.equipSpeedModifier or 1
	if isReverse then speed = -(speed) end

	local animTrack: AnimationTrack = PlayAnimation(animName, {
		priority = Enum.AnimationPriority.Action2,
		looped = false,
		speed = speed,
	}, "Unequip")

	if not animTrack then
		flags.unequipping = false
		return false
	end

	-- If playing in reverse, jump to the end so it plays backwards
	if isReverse then
		animTrack.TimePosition = animTrack.Length
	end

	-- Hold for exactly as long as the unequip animation actually runs, then unequip.
	-- (Waiting a fixed unequipTime instead made the rig finish the anim and then sit in
	-- its idle/default pose for the leftover time before the gun came off, most visible
	-- in third person.) Fall back to unequipDur if the anim length isn't available.
	local waited = 0
	while animTrack.Length == 0 and waited < 20 do
		waited += 1
		task.wait()
	end
	local playSpeed = math.abs(speed)
	local animDur = (animTrack.Length > 0 and playSpeed > 0) and (animTrack.Length / playSpeed) or unequipDur
	local deadline = os.clock() + animDur
	while os.clock() < deadline do
		if not flags.unequipping or flags.dead then break end
		task.wait()
	end
	flags.unequipping = false
	return true
end

-- ADS depth of field: set the AimDOF target this gun's settings while aiming, 0 when not. The
-- RenderStepped loop below smoothly lerps the effect toward this target (TweenService doesn't
-- animate DepthOfFieldEffect reliably -- it snaps). Every field is per-gun via wepStats.aimDOF,
-- else config.aimDOF, else 0. Transition speed scales with the weapon's aimTime.
local function SetAimDOF(on)
	if springs.aimDOF then springs.aimDOF.Enabled = true end
	springs.dofSpeed = 2.5 / math.max((wepStats and wepStats.aimTime) or 0.3, 0.05)
	if on then
		local d = (wepStats and wepStats.aimDOF) or {}
		local cd = config.aimDOF or {}
		springs.dofTarget = {
			far = d.farIntensity or cd.farIntensity or 0,
			near = d.nearIntensity or cd.nearIntensity or 0,
			focus = d.focusDistance or cd.focusDistance or 0,
			radius = d.inFocusRadius or cd.inFocusRadius or 0,
		}
	else
		-- back to the resting DOF (the values authored on the effect), not 0
		local r = springs.dofRest
		springs.dofTarget = { far = r.far, near = r.near, focus = r.focus, radius = r.radius }
	end
end

local function ToggleAiming(toggle)
	if flags.reloading and toggle and not config.canReloadWhileAiming then return end
	if toggle and (flags.equipping or flags.unequipping) then return end
	character:SetAttribute("Aiming", toggle)
	-- Settle-wobble: roll velocity kick so it ramps in and overshoots back to 0 during the
	-- transition (aim in rolls one way, aim out the other). Scaled by speed so the amount reads
	-- roughly as peak degrees. Added to current so fast on/off flicks stack cleanly.
	local aw = config.aimWobbleAmount or 7
	if aw > 0 then
		-- *1.45 makes the amount read ~= peak degrees of roll (cancels the damping falloff).
		springs.wobVel = springs.wobVel + aw * (config.aimWobbleSpeed or 9) * 1.45 * (toggle and 1 or -1)
	end
	if toggle then
		aiming = true
		-- The tail of a sprint end anim may still be playing -- actions unlock partway
		-- through it. Crossfade what's left into the ADS blend rather than letting both
		-- drive the arms at once.
		if sphReady.CutSprintEnd then
			sphReady.CutSprintEnd(((wepStats and wepStats.aimTime) or 0.6) / 4)
		end
		SetAimDOF(true) -- fade this gun's aim depth of field in
		-- Publish this weapon's ADS camera tilt (degrees) for the CameraBobAndFallSway script.
		character:SetAttribute("SPH_AimTilt", (wepStats and (wepStats.aimTilt or config.aimTiltDeg)) or 0)
		if wepStats.ADSEnabled and wepStats.ADSEnabled[sightIndex] then
			ToggleADS(true)
		else
			ToggleADS(false)
		end
		svc.userInputService.MouseDeltaSensitivity = aimSensitivity
		PlayRepSound("AimUp")
		if not config.lockFirstPerson then
			player.CameraMode = Enum.CameraMode.LockFirstPerson
		end
		if wepStats.aimAnim then
			local transTime = wepStats.aimTime / 4
			PlayAnimation(wepStats.aimAnim, {looped = true, priority = Enum.AnimationPriority.Action, transSpeed = transTime}, "AimAnim")
		end
	else
		aiming = false
		SetAimDOF(false) -- fade the aim depth of field back out
		ToggleADS(false)
		svc.userInputService.MouseDeltaSensitivity = 1
		PlayRepSound("AimDown")
		-- FOV eases back to default via the unified FOV smoother in RenderStepped
		-- (it targets defaultFOV whenever you're not aiming), so no separate tween here.
		if not config.lockFirstPerson then
			player.CameraMode = flags.forcedFirstPerson and Enum.CameraMode.LockFirstPerson or defaultCameraMode
		end
		if wepStats then
			StopAnimation(wepStats.aimAnim, wepStats.aimTime / 6)
		end
	end
end

-- (Over-the-shoulder / third-person aiming was removed. Right-click only aims in first
-- person now; in third person it does nothing.)

local function ReloadAnim()
	if not equipped then return end
	if not config.canReloadWhileAiming and aiming then ToggleAiming(false) end
	flags.cancelReload = false
	flags.reloading = true
	character:SetAttribute("Reloading", true)
	if wepStats.operationType == 3 or (wepStats.operationType == 2 and gunAmmo.MagAmmo.Value <= 0 and not equipped.Chambered.Value) then
		local boltOpenTrack = PlayAnimation(wepStats.boltOpen,{speed = wepStats.reloadSpeedModifier, priority = Enum.AnimationPriority.Action2, transSpeed = 0.17})
		if not boltOpenTrack then
			warn(warnPrefix.."To use operation type "..wepStats.operationType..", a 'boltOpen' animation is required.")
			flags.reloading = false
			character:SetAttribute("Reloading", false)
			return
		end
		boltOpenTrack.Stopped:Once(function()
			if wepStats.magType == 3
				and (gunAmmo.MagAmmo.MaxValue - gunAmmo.MagAmmo.Value) >= (wepStats.clipSize or wepStats.magazineCapacity)
				and gunAmmo.ArcadeAmmoPool.Value >= (wepStats.clipSize or wepStats.magazineCapacity) then
				PlayAnimation(wepStats.clipReloadAnim,{looped = true,speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17})
			else
				local bulletInsert = PlayAnimation(wepStats.reloadAnim,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17,looped = true},"Reload")
				if wepStats.magType > 1 then bulletInsert.Looped = true end
			end
		end)
	else
		-- Use reloadEmpty anim when magazine AND chamber are both empty
		local isEmptyReload = wepStats.reloadEmptyAnim and gunAmmo.MagAmmo.Value <= 0 and not equipped.Chambered.Value
		local reloadAnimName = isEmptyReload and wepStats.reloadEmptyAnim or wepStats.reloadAnim
		local reloadAnim = PlayAnimation(reloadAnimName,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17},"Reload")
		-- Auto-chamber after ANY reload (including empty reloads) when the chamber ended up
		-- empty. The `not equipped.Chambered.Value` guard means weapons whose reload anim
		-- already chambers (via a keyframe) won't double up -- it only fires if still unchambered.
		if wepStats.autoChamber then
			reloadAnim.Stopped:Once(function()
				if equipped and (not equipped.Chambered.Value or wepStats.openBolt) then
					flags.reloading = true
					local animNameToPlay = equipped.BoltReady.Value and wepStats.boltChamber or wepStats.boltClose
					local chamberTrack = PlayAnimation(animNameToPlay,{priority = Enum.AnimationPriority.Action2,transSpeed = 0.05})
					if chamberTrack then
						chamberTrack.Stopped:Once(function()
							flags.reloading = false
							character:SetAttribute("Reloading", false)
						end)
					end
				end
			end)
		end
	end
end

local function RefreshViewmodel()
	if firstPerson and not flags.equipping then
		flags.viewmodelVisible = true
	end
	local plrShirt = character:FindFirstChildWhichIsA("Shirt")
	if plrShirt then vmShirt.ShirtTemplate = plrShirt.ShirtTemplate end
	lArm.Color = character["Left Arm"].Color
	rArm.Color = character["Right Arm"].Color
	for _, part in ipairs(rig:GetDescendants()) do
		if part.Name == "Skin" then
			if part.Parent.Name == "Left Arm" then
				part.Color = character["Left Arm"].Color
			elseif part.Parent.Name == "Right Arm" then
				part.Color = character["Right Arm"].Color
			end
		end
	end
	IdleAnim()
	if mods.callbacks.onViewmodelRefresh then mods.callbacks.onViewmodelRefresh(player,rig) end
end

local function CanOpenBipod()
	if gunModel:FindFirstChild("BipodBase") and wepStats.bipodHeight then
		local bipodBase:BasePart = gunModel:FindFirstChild("BipodBase")
		local groundCheck = workspace:Raycast(bipodBase.Position, Vector3.new(0, -wepStats.bipodHeight, 0), rayParams)
		if groundCheck then
			return groundCheck.Position, bipodBase, (bipodBase.Position - groundCheck.Position).Magnitude, wepStats.bipodHeight
		end
	end
end

local function ResetHead()
	flags.viewmodelVisible = false
end

local function GetSineOffset(addition:number)
	return math.sin(tick() * addition * 1.3) * 0.3
end

local function LerpNumber(number:number, target:number, speed:number)
	return number + (target-number) * speed
end

-- Smooth soft cap (tanh): ~1:1 for small inputs, eases toward +/-limit for large ones so a
-- fast turn saturates the sway gently instead of flinging the gun or hard-clamping stiffly.
local function SoftLimit(value:number, limit:number)
	if limit <= 0 then return value end
	local e = math.exp(-2 * value / limit)
	return limit * (1 - e) / (1 + e) -- == limit * tanh(value / limit)
end

flags.recoilUpdateCD = 0
flags.fps = 0
local function UpdateViewmodelPosition(dt:number)
	flags.fps = 1 / dt
	flags.recoilUpdateCD -= dt

	-- Get the camera CFrame WITHOUT the tilt from CameraTilt script
	-- so the viewmodel (gun) stays stable while only the camera rolls.
	local tiltOffset = camera:FindFirstChild("CameraTiltOffset")
	local vmCameraCFrame = camera.CFrame
	-- Strip the ADS camera cant (applied LAST / outermost by CameraBobAndFallSway) so the gun
	-- stays upright on screen while only the view rolls. Remove it first (outermost), then the
	-- CameraTilt offset below.
	local aimTiltRad = camera:GetAttribute("SPH_AimTiltRad")
	if aimTiltRad and aimTiltRad ~= 0 then
		vmCameraCFrame = vmCameraCFrame * CFrame.Angles(0, 0, aimTiltRad):Inverse()
	end
	if tiltOffset then
		vmCameraCFrame = vmCameraCFrame * tiltOffset.Value:Inverse()
	end

	animBase.CFrame = CFrame.new((vmCameraCFrame * offset).Position)
	if not freeLook then
		animBase.CFrame *= vmCameraCFrame - vmCameraCFrame.Position
	else
		animBase.CFrame *= cam.freeLookRotation
	end
	if character:GetAttribute("Stance") == "Prone" and not equipped:GetAttribute("BipodEnabled") then
		cam.proneViewmodelOffset = LerpNumber(cam.proneViewmodelOffset,0.2,0.1)
	else
		cam.proneViewmodelOffset = LerpNumber(cam.proneViewmodelOffset,0,0.1)
	end
	animBase.CFrame *= CFrame.new(0,cam.proneViewmodelOffset,0)
	local freelookRecovery = 0.2
	cam.freeLookOffset = cam.freeLookOffset:Lerp(CFrame.new(),freelookRecovery * dt * 60)
	animBase.CFrame *= cam.freeLookOffset:Inverse()
	if equipped:GetAttribute("BipodEnabled") then
		local bipodPoint, bipodPart, bipodDistance, bipodMaxDistance = CanOpenBipod()
		if bipodPoint and bipodPart then
			cam.bipodCFrame = cam.bipodCFrame:Lerp(CFrame.new(0, (bipodMaxDistance - bipodDistance * 2) - 0.2, 0), 0.2)
		else
			cam.bipodCFrame = cam.bipodCFrame:Lerp(CFrame.new(), 0.2)
			equipped:SetAttribute("BipodEnabled", false)
			if gunModel.Grip:FindFirstChild("Bipod") then gunModel.Grip.Bipod:Play() end
		end
	else
		cam.bipodCFrame = cam.bipodCFrame:Lerp(CFrame.new(), 0.2)
	end
	animBase.CFrame *= cam.bipodCFrame
	-- ===== Aim pose + weapon cant =====
	-- Normal aim goes through AimPart. The canted pose goes through NVAimPart (the same
	-- offset the goggles use). You cant when night vision is on (FORCED) or when you've
	-- toggled cant with the cant key. The two poses are blended by springs.cantBlend, which
	-- eases over the weapon's cantInTime / cantOutTime -- so the cant has its OWN speed,
	-- separate from how fast you raise/lower the gun. The whole aimingOffset then eases
	-- toward that blended target over aimInTime (raising) / aimOutTime (lowering).
	-- A gun with no NVAimPart simply never cants.
	local normalPart = gunModel:FindFirstChild("AimPart"..sightIndex) or gunModel.AimPart
	local cantPart = gunModel:FindFirstChild("NVAimPart"..sightIndex) or gunModel:FindFirstChild("NVAimPart")

	local nvNow = player:GetAttribute("NightVisionActive") == true
	local wantCant = (nvNow or springs.cantOn) and cantPart ~= nil

	-- Settle-wobble kick, driven off whether the cant pose ACTUALLY changed -- not off the
	-- key press or the NV toggle on their own. Night vision already forces the cant on, so
	-- hitting the cant key while wearing NVGs moves nothing and must not wobble; same for a
	-- gun with no NVAimPart, which never cants at all. Covers the reverse too (dropping NV
	-- while cant is toggled on leaves you canted, so that shouldn't wobble either).
	-- nil = first frame with this weapon: sync silently so equipping never kicks a wobble.
	if springs.cantWasOn == nil then
		springs.cantWasOn = wantCant
	elseif wantCant ~= springs.cantWasOn then
		springs.cantWasOn = wantCant
		-- ONLY kick the wobble while actually aiming. The canted pose lives inside
		-- aimingOffset, which is only applied when ADS -- hipfired, flipping the cant moves
		-- the gun exactly zero. Kicking the roll spring there produced a wobble on a gun
		-- that hadn't moved: that's the weird idle wobble when toggling NVGs on/off.
		-- cantWasOn is still updated either way, so aiming afterwards doesn't double-kick.
		local cw = config.cantWobbleAmount or 7
		if aiming and cw > 0 then
			springs.wobVel = springs.wobVel + cw * (config.aimWobbleSpeed or 9) * 1.45 * (wantCant and 1 or -1)
		end
	end
	local cantTau = math.max((wantCant and (wepStats.cantInTime or config.cantInTime or 0.25)
		or (wepStats.cantOutTime or config.cantOutTime or 0.25)), 0.01) / 3
	springs.cantBlend += ((wantCant and 1 or 0) - springs.cantBlend) * (1 - math.exp(-dt / cantTau))

	local normalTarget = normalPart.CFrame:ToObjectSpace(vmCameraCFrame)
	if cantPart and springs.cantBlend > 0.0001 then
		cam.aimTarget = normalTarget:Lerp(cantPart.CFrame:ToObjectSpace(vmCameraCFrame), springs.cantBlend)
	else
		cam.aimTarget = normalTarget
	end

	if not flags.aimTransitionPlaying then
		-- aimInTime / aimOutTime are seconds to (basically) finish; tau = time/3 -> ~95% done
		-- at that time. Higher = slower, frame-rate independent.
		local aimTau = math.max((aiming and (wepStats.aimInTime or config.aimInTime or 0.3)
			or (wepStats.aimOutTime or config.aimOutTime or 0.25)), 0.01) / 3
		cam.aimingOffset = cam.aimingOffset:Lerp(aiming and cam.aimTarget or CFrame.new(), 1 - math.exp(-dt / aimTau))
	end
	if freeLook then
		animBase.CFrame *= CFrame.new(cam.aimingOffset.Position)
	else
		animBase.CFrame *= cam.aimingOffset
	end
	local rayDistance = wepStats.gunLength
	local originCFrame = firstPerson and animBase.CFrame or weaponRig.AnimBase.CFrame
	local newRay = workspace:Raycast(originCFrame.Position, originCFrame.LookVector * rayDistance, rayParams)
	local pushbackGripOffset = animBase.CFrame:ToObjectSpace(gunModel.Grip.CFrame)
	if newRay and newRay.Instance and not newRay.Instance:HasTag("SPH_NoCollide") then
		local distance = rayDistance - (originCFrame.Position - newRay.Position).Magnitude
		if config.pushBackViewmodel and distance > 0 then
			local tempDist = distance
			if blocked then tempDist /= 2 end
			cam.pushbackOffset = LerpNumber(cam.pushbackOffset, tempDist, 0.2 * 60 * dt)
		else
			cam.pushbackOffset = LerpNumber(cam.pushbackOffset, 0, 0.2 * 60 * dt)
		end
		local maxPushbackDist = wepStats.maxPushback > 0 and wepStats.maxPushback or 1
		local pushAlpha = math.clamp(cam.pushbackOffset / maxPushbackDist, 0, 1)
		local targetPushbackAngle = math.rad(90) * pushAlpha
		cam.currentPushbackAngle = LerpNumber(cam.currentPushbackAngle, targetPushbackAngle, 0.15 * 60 * dt)
		local localNormal = originCFrame:VectorToObjectSpace(newRay.Normal)
		local maxWallTilt = math.rad(config.maxWallTilt or 30)
		local wallAngle = math.clamp(math.atan2(localNormal.X, localNormal.Z), -maxWallTilt, maxWallTilt)
		local targetWallYaw  = wallAngle * (config.wallYawStrength or 1.2) * pushAlpha
		local targetWallRoll = -wallAngle * (config.wallRollStrength or 1) * pushAlpha
		cam.currentWallYaw  = LerpNumber(cam.currentWallYaw,  targetWallYaw,  0.15 * 60 * dt)
		cam.currentWallRoll = LerpNumber(cam.currentWallRoll, targetWallRoll, 0.15 * 60 * dt)

		animBase.CFrame = animBase.CFrame * pushbackGripOffset
			* CFrame.Angles(cam.currentPushbackAngle, cam.currentWallYaw, cam.currentWallRoll)
			* pushbackGripOffset:Inverse()
		if config.raiseGunAtWall then
			if distance >= wepStats.maxPushback then
				if not blocked then
					ClearReadyInstant()
					PlayAnimation(wepStats.holdUpAnim,{looped = true, priority = Enum.AnimationPriority.Action, transSpeed = 0.3})
					blocked = true
					if aiming then ToggleAiming(false) end
				end
			elseif blocked then
				StopAnimation(wepStats.holdUpAnim, 0.3)
				blocked = false
				if flags.aimHeld and not aiming and firstPerson and not flags.sprinting and not sprintAnimActive then ToggleAiming(true) end
			end
		end
	else
		if blocked then
			StopAnimation(wepStats.holdUpAnim, 0.3)
			blocked = false
			if flags.aimHeld and not aiming and firstPerson and not flags.sprinting and not sprintAnimActive then ToggleAiming(true) end
		end
		cam.pushbackOffset = LerpNumber(cam.pushbackOffset, 0, 0.2 * 60 * dt)
		local targetPushbackAngle = math.rad(90) * math.clamp(cam.pushbackOffset / (wepStats.maxPushback > 0 and wepStats.maxPushback or 1), 0, 1)
		cam.currentPushbackAngle = LerpNumber(cam.currentPushbackAngle, targetPushbackAngle, 0.15 * 60 * dt)
		cam.currentWallYaw  = LerpNumber(cam.currentWallYaw,  0, 0.15 * 60 * dt)
		cam.currentWallRoll = LerpNumber(cam.currentWallRoll, 0, 0.15 * 60 * dt)
		animBase.CFrame = animBase.CFrame * pushbackGripOffset
			* CFrame.Angles(cam.currentPushbackAngle, cam.currentWallYaw, cam.currentWallRoll)
			* pushbackGripOffset:Inverse()
	end
	animBase.CFrame *= CFrame.new(0, 0, cam.pushbackOffset)
	local relativeVelocity = humanoidRootPart.CFrame:VectorToObjectSpace(humanoidRootPart.Velocity)
	local targetRollAngle = 0
	if not aiming then targetRollAngle = math.clamp(-relativeVelocity.X, -config.maxStrafeRoll, config.maxStrafeRoll) end
	cam.rollAngle = LerpNumber(cam.rollAngle, targetRollAngle, 0.07 * dt * 60)
	animBase.CFrame *= CFrame.Angles(0, 0, math.rad(cam.rollAngle))
	-- Tactical lean: tilt the viewmodel sideways with the lean. Reads the same lean
	-- spring as the camera, so the spring does the smoothing. 25deg each side.
	-- (Flip the sign if it tilts the wrong way.)
	-- Viewmodel lean tilt. While aiming we scale it down (default 0) so the sights
	-- stay centred (a viewmodel roll rotates the sights off the camera's forward axis,
	-- which throws ADS aim off). The aim-blend is sprung (springs.vmAim) so it eases
	-- out/in smoothly instead of snapping the instant you ADS.
	springs.vmAim.t = Vector3.new(aiming and (config.leanViewmodelTiltAimScale or 0) or 1, 0, 0)
	local vmLeanTilt = (config.leanViewmodelTilt or 17) * springs.vmAim.p.X
	animBase.CFrame *= CFrame.Angles(0, 0, math.rad(vmLeanTilt * -springs.lean.p.X))
	-- ADS / cant settle wobble: integrate the little damped roll spring toward 0 (semi-implicit),
	-- then apply it. A velocity kick ramps in and overshoots, then decays fully to 0 -- so it only
	-- shows during the transition and the gun sits dead level when settled.
	local wob_s = config.aimWobbleSpeed or 9
	local wob_d = config.aimWobbleDamper or 0.4
	local wob_dt = math.min(dt, 1/30) -- clamp so a lag spike can't blow up the integrator
	springs.wobVel = springs.wobVel + (-(wob_s * wob_s) * springs.wobRoll - 2 * wob_d * wob_s * springs.wobVel) * wob_dt
	springs.wobRoll = springs.wobRoll + springs.wobVel * wob_dt
	animBase.CFrame *= CFrame.Angles(0, 0, math.rad(springs.wobRoll))
	-- Ready-stance settle bounce: same integrator, on pitch + roll. Idle cost is two
	-- multiplies once it has decayed to zero, so it's free when nothing kicked it.
	local bcfg = (wepStats and wepStats.readyBounce) or config.readyBounce or {}
	local st_s = bcfg.speed or config.aimWobbleSpeed or 9
	local st_d = bcfg.damper or config.aimWobbleDamper or 0.4
	springs.settleV = springs.settleV
		+ (springs.settleP * -(st_s * st_s) - springs.settleV * (2 * st_d * st_s)) * wob_dt
	springs.settleP = springs.settleP + springs.settleV * wob_dt
	animBase.CFrame *= CFrame.Angles(math.rad(springs.settleP.X), 0, math.rad(springs.settleP.Y))
	-- Crouch gun tilt: roll the gun left while crouched, but ONLY during idle/firing -- off
	-- while aiming, reloading, sprinting, inspecting, chambering, or in a ready stance. Eased
	-- toward the target so it blends in and out perfectly (no snap). Off = 0 = dead level.
	local crouchTilting = character:GetAttribute("Stance") == "Crouched"
		and not aiming and not flags.reloading and not flags.sprinting and not flags.inspecting
		and not flags.chambering and not flags.meleeing and sphReady.state == 0
	local crouchTarget = crouchTilting and (wepStats.crouchTiltDeg or config.crouchTiltDeg or 16) or 0
	-- Damped spring toward the target (semi-implicit): overshoots + bounces before settling.
	local ct_s = config.crouchTiltSpeed or 5    -- lower = slower transition
	local ct_d = config.crouchTiltDamper or 0.45 -- <1 = bounce; lower = bouncier
	local ct_dt = math.min(dt, 1/30)
	springs.crouchVel = springs.crouchVel + ((ct_s * ct_s) * (crouchTarget - springs.crouchTilt) - 2 * ct_d * ct_s * springs.crouchVel) * ct_dt
	springs.crouchTilt = springs.crouchTilt + springs.crouchVel * ct_dt
	animBase.CFrame *= CFrame.Angles(0, 0, math.rad(springs.crouchTilt))
	local mouseDelta = svc.userInputService:GetMouseDelta()
	local tempHipRotation = cam.hipRotation
	if config.hipfireMove and (not aiming or aiming and config.offCenterAiming) then
		local maxX = config.hipfireMoveX
		local maxY = config.hipfireMoveY
		if aiming then maxX /= 4; maxY /= 4 end
		local xRotation = math.clamp(tempHipRotation.X - mouseDelta.X * config.hipfireMoveSpeed * dt * 60,-maxX,maxX)
		local yRotation = math.clamp(tempHipRotation.Y - mouseDelta.Y * config.hipfireMoveSpeed * dt * 60,-maxY,maxY)
		tempHipRotation = Vector2.new(xRotation,yRotation)
		-- Drift back to center when mouse isn't moving
		local returnSpeed = config.hipfireMoveReturnSpeed or 0.07
		tempHipRotation = tempHipRotation:Lerp(Vector2.zero, returnSpeed * dt * 60)
		cam.hipRotation = tempHipRotation
	else
		cam.hipRotation = cam.hipRotation:Lerp(Vector2.zero,0.3)
	end
	animBase.CFrame *= CFrame.Angles(math.rad(cam.hipRotation.Y),math.rad(cam.hipRotation.X),0)
	-- Camera-look sway: lag the gun behind view rotation, then spring back (reduced when aiming).
	local swayLook = camera.CFrame.LookVector
	local swayPitch = math.asin(math.clamp(swayLook.Y, -1, 1))
	local swayYaw = -math.atan2(swayLook.X, swayLook.Z)
	local pitchChange = springs.swayTilt.lastPitch - swayPitch
	local yawChange = springs.swayTilt.lastYaw - swayYaw
	pitchChange = (math.abs(pitchChange) < 1) and pitchChange or 0 -- discard wrap/teleport spikes
	yawChange = (math.abs(yawChange) < 1) and yawChange or 0
	-- Frame-rate independent decay: keeps sway consistent at any fps. Lower decay = more
	-- view rotation builds up and lingers = bigger, longer sway. Per-weapon overridable.
	local swayCfg = wepStats.sway
	local swayDecay = math.clamp(1 - ((swayCfg and swayCfg.decay) or config.swayDecay or 30) * dt, 0, 1)
	springs.swayTilt.y = springs.swayTilt.y * swayDecay + pitchChange
	springs.swayTilt.x = springs.swayTilt.x * swayDecay + yawChange
	springs.swayTilt.lastPitch = swayPitch
	springs.swayTilt.lastYaw = swayYaw
	springs.lookSway.t = Vector3.new(springs.swayTilt.x, springs.swayTilt.y, 0)
	springs.posSway.t = Vector3.new(springs.swayTilt.x, springs.swayTilt.y, 0)
	-- Negative so the gun swings opposite the turn. Hipfire vs aim magnitude, per-weapon.
	-- ...and scaled down again while a 2D scope is up (GetSwayScale returns 1 at 1x).
	local swayMult = -(aiming and ((swayCfg and swayCfg.aimAmount) or config.swayAimAmount or 3)
		or ((swayCfg and swayCfg.amount) or config.swayAmount or 4)) * springs.scope.GetSwayScale()
	local sVec = springs.lookSway.p
	local pVec = springs.posSway.p
	local XSWY = sVec.X * swayMult
	local YSWY = sVec.Y * swayMult
	local pXSWY = pVec.X * swayMult
	local pYSWY = pVec.Y * swayMult
	-- Soft angle cap: on fast turns the sway eases toward a max instead of flinging around.
	-- maxAngle is (roughly) the max roll in degrees; roll below uses the x12 multiplier, so we
	-- bound the driver by maxAngle/12. tanh keeps normal sway ~1:1 so it never feels stiff.
	-- Per-weapon via wepStats.sway.maxAngle, else config.swayMaxAngle. Set to 0 to disable.
	local swayMax = (swayCfg and swayCfg.maxAngle) or config.swayMaxAngle or 18
	if swayMax > 0 then
		local lim = swayMax / 12
		XSWY = SoftLimit(XSWY, lim)
		YSWY = SoftLimit(YSWY, lim)
		pXSWY = SoftLimit(pXSWY, lim)
		pYSWY = SoftLimit(pYSWY, lim)
	end
	animBase.CFrame *= CFrame.new(-XSWY * 0.2, -YSWY * 0.2, 0) * CFrame.Angles(YSWY * math.rad(7.5), -XSWY * math.rad(7.5), -XSWY * math.rad(12)) * CFrame.new(-pXSWY * 0.35, -pYSWY * 0.35, 0)
	local tickTime = tick() * 0.15
	local tempDist = config.breathingDist
	if aiming then tempDist *= config.breathingAimMultiplier end
	-- Magnified optics multiply everything, breathing included -- at 6x, hipfire-sized
	-- breathing sweeps the whole tube. Scaled down by the scope's swayScale (1 at 1x).
	tempDist *= springs.scope.GetSwayScale()
	animBase.CFrame *= CFrame.new(tempDist * math.sin(tickTime * config.breathingSpeed / 2), tempDist * math.sin(tickTime * config.breathingSpeed), 0)
	local updatedRecoil = springs.recoil.Position
	local updatedGunRecoil = springs.gunRecoil:update(dt)
	if flags.recoilUpdateCD <= 0 then
		flags.recoilUpdateCD = 1 / 60
		local currentFPS = 1 / dt
		local dtMult = (currentFPS / 60) - 1
		dtMult = dtMult / 2
		updatedRecoil = springs.recoil:update(0.016 + (0.016 * dtMult))
	end
	animBase.CFrame *= CFrame.Angles(math.rad(updatedGunRecoil.X), math.rad(updatedGunRecoil.Y), 0)
	animBase.CFrame *= CFrame.new(0,0,updatedGunRecoil.Z)
	camera.CFrame *= CFrame.Angles(math.rad(updatedRecoil.X),math.rad(updatedRecoil.Y),math.rad(updatedRecoil.Z))
	if config.lowHealthEffects then
		if humanoid.Health < 35 then
			local timeStamp = os.clock() * 5
			local dampening = 50
			local randomShakeCFrame = CFrame.new(math.noise(timeStamp, 0, 0) / dampening, math.noise(0, timeStamp, 0) / dampening, math.noise(0, 0, timeStamp) / dampening)
			cam.shakeCFrame = randomShakeCFrame
		else
			cam.shakeCFrame = cam.shakeCFrame:Lerp(CFrame.new(), 0.1)
		end
		animBase.CFrame *= cam.shakeCFrame
	end
	if not flags.viewmodelVisible then
		animBase.CFrame *= storageCFrame
	end
end

local function ToggleInspect()
	if not equipped or flags.equipping or flags.unequipping or flags.reloading or aiming or flags.sprinting or blocked or flags.chambering or flags.inspecting or flags.meleeing then return end
	if wepStats and wepStats.inspectAnim then
		-- Attempting to inspect while in a ready stance exits it (action cancelled)
		if sphReady.state ~= 0 or sphReady.busy then ExitReady() return end
		flags.inspecting = true
		character:SetAttribute("Inspecting", true)
		local inspectTrack: AnimationTrack = PlayAnimation(wepStats.inspectAnim, {looped = false, priority = Enum.AnimationPriority.Action2, transSpeed = 0.2})
		inspectTrack.Stopped:Once(function()
			flags.inspecting = false
			character:SetAttribute("Inspecting", false)
		end)
	end
end

-- Gun melee / bashing was removed. `meleeing` stays permanently false (declared up
-- top) so the guard checks scattered through the file still read correctly.

-- =====================
-- SPRINT ANIMATION SEQUENCE: start -> speed-scaled loop -> end.
-- The end waits for the loop to finish its current cycle so it blends cleanly, and no
-- weapon actions are allowed while any of these are playing (see sprintAnimActive).
-- Anims are per-weapon in WeaponStats (sprintStartAnim / sprintLoopAnim / sprintEndAnim).
-- =====================
local sprintAnimState = 0      -- 0 none, 1 start, 2 loop, 3 end
local sprintAnimActive = false -- mirror of (sprintAnimState ~= 0); gates weapon actions
local sprintExitPending = false -- player stopped; waiting for the loop cycle to finish
local sprintGen = 0            -- invalidates stale start/end callbacks
local sprintLoopLastTime = nil -- last loop TimePosition, used to detect a cycle wrap

-- Adjust playback speed on BOTH the first- and third-person tracks of a loaded anim.
local function SetAnimSpeed(animName, speed)
	local fp = loadedAnims[animName]
	if fp then fp:AdjustSpeed(speed) end
	local tp = loadedAnims[animName.."ThirdPerson"]
	if tp then tp:AdjustSpeed(speed) end
end

-- Whether this weapon actually uses the sprint sequence.
local function HasSprintAnims()
	return wepStats and (wepStats.sprintStartAnim or wepStats.sprintLoopAnim) ~= nil
end

-- Play the sprint end anim, then drop back to idle / no sprint.
local function PlaySprintEnd()
	sprintGen += 1
	local myGen = sprintGen
	sprintExitPending = false
	sprintLoopLastTime = nil
	sprintAnimState = 3
	local blendOut = config.sprintBlendOut or 0.4
	-- Crossfade: fade the loop/start out while the end anim fades in over the same time.
	if wepStats and wepStats.sprintStartAnim then StopAnimation(wepStats.sprintStartAnim, blendOut) end
	if wepStats and wepStats.sprintLoopAnim then StopAnimation(wepStats.sprintLoopAnim, blendOut) end
	local endName = wepStats and wepStats.sprintEndAnim
	if endName then
		local track = PlayAnimation(endName, {looped = false, priority = Enum.AnimationPriority.Action, transSpeed = blendOut})
		if track then
			-- How much of the end anim has to play before weapon actions (aiming above all)
			-- are allowed again. Same idea as READY_AIM_FRACTION in ExitReady: you wait out
			-- this fraction, and the leftover tail crossfades away under whatever you do next
			-- instead of holding you hostage until the clip ends.
			local ACTION_FRACTION = math.clamp(config.sprintEndActionFraction or 0.7, 0, 1)
			local unlocked = false
			local function unlock()
				if unlocked or myGen ~= sprintGen then return end
				unlocked = true
				-- Actions are live again. sprintAnimState stays at 3 on purpose so the tail of
				-- the end anim keeps owning the pose until it finishes or something cuts it.
				sprintAnimActive = false
				-- Aim was stabbed during the locked stretch: honour it now. StartAimFromReady
				-- runs the same checks as a fresh press, and ToggleAiming crossfades the
				-- remaining tail out (see sphReady.CutSprintEnd) so it blends into the sights.
				if springs.sprintPendingAim then
					springs.sprintPendingAim = false
					if sphReady.StartAimFromReady then sphReady.StartAimFromReady() end
				end
			end
			task.spawn(function()
				-- Wait for the clip length to be known (a few frames at most), then fire at the
				-- threshold. Identical shape to the ExitReady early-aim timer.
				local waited = 0
				while track.Length <= 0 and waited < 0.2 and myGen == sprintGen do
					waited += task.wait()
				end
				if myGen ~= sprintGen then return end
				local remaining = ((track.Length > 0 and track.Length) or 0.4) * ACTION_FRACTION - waited
				if remaining > 0 then task.wait(remaining) end
				unlock()
			end)
			track.Stopped:Once(function()
				if myGen ~= sprintGen then return end
				unlock() -- safety: a very short clip can end before the timer lands
				sprintAnimState = 0
				sprintAnimActive = false
				springs.sprintPendingAim = false
			end)
			return
		end
	end
	sprintAnimState = 0
	sprintAnimActive = false
	springs.sprintPendingAim = false
end

-- Called by ToggleAiming when you shoulder the gun while the tail of the sprint end anim
-- is still playing (everything after the ACTION_FRACTION mark). Crossfades that remainder
-- out over the ADS blend so the two animations don't fight for the same joints.
function sphReady.CutSprintEnd(blend)
	if sprintAnimState ~= 3 then return end
	sprintGen += 1 -- invalidate the end anim's own unlock / Stopped callbacks
	sprintAnimState = 0
	sprintAnimActive = false
	springs.sprintPendingAim = false
	if wepStats and wepStats.sprintEndAnim then
		StopAnimation(wepStats.sprintEndAnim, blend or 0.15)
	end
end

-- Begin sprinting: play the start anim, then the looping run anim.
function sphReady.StartSprintAnim()
	if not HasSprintAnims() then
		sprintAnimState = 0
		sprintAnimActive = false
		return
	end
	sprintGen += 1
	local myGen = sprintGen
	sprintExitPending = false
	sprintLoopLastTime = nil
	sprintAnimActive = true
	springs.sprintPendingAim = false
	local blendIn = config.sprintBlendIn or 0.4
	local startName = wepStats.sprintStartAnim
	local loopName = wepStats.sprintLoopAnim
	-- If a previous end anim is still playing (re-sprinting mid-end), crossfade it away.
	if wepStats.sprintEndAnim then StopAnimation(wepStats.sprintEndAnim, blendIn) end
	local function beginLoop()
		if myGen ~= sprintGen then return end
		-- Crossfade the start out as the loop fades in over the same blend time.
		if startName then StopAnimation(startName, blendIn) end
		if sprintExitPending then
			-- Player already stopped during the start anim: go straight to the end.
			PlaySprintEnd()
			return
		end
		sprintAnimState = 2
		sprintLoopLastTime = nil
		if loopName then
			PlayAnimation(loopName, {looped = true, priority = Enum.AnimationPriority.Action, transSpeed = blendIn})
		end
	end
	if startName then
		sprintAnimState = 1
		local track = PlayAnimation(startName, {looped = false, priority = Enum.AnimationPriority.Action, transSpeed = blendIn})
		if track then
			-- Start the loop a touch BEFORE the start anim ends so they crossfade instead of pop.
			task.spawn(function()
				local waited = 0
				while track.Length == 0 and waited < 30 do waited += 1; task.wait() end
				local lead = math.max(0, (track.Length or 0) - blendIn)
				local elapsed = 0
				while elapsed < lead do
					if myGen ~= sprintGen then return end
					elapsed += task.wait()
				end
				beginLoop()
			end)
		else
			beginLoop()
		end
	else
		beginLoop()
	end
end

-- Per-frame: scale the loop to movement speed, and once the player has stopped, wait
-- for the loop to finish its cycle before playing the end anim.
local function UpdateSprintAnim(dt)
	if sprintAnimState == 2 and wepStats and wepStats.sprintLoopAnim then
		local loopTrack = loadedAnims[wepStats.sprintLoopAnim]
		if loopTrack and loopTrack.IsPlaying then
			local vel = humanoidRootPart.AssemblyLinearVelocity
			local horizSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			local refSpeed = math.max(config.sprintSpeed or 18.8, 0.1)
			local playSpeed = math.clamp(horizSpeed / refSpeed, config.sprintAnimMinSpeed or 0.5, config.sprintAnimMaxSpeed or 1.5)
			SetAnimSpeed(wepStats.sprintLoopAnim, playSpeed)
			if sprintExitPending then
				local t = loopTrack.TimePosition
				if sprintLoopLastTime and t < sprintLoopLastTime then
					PlaySprintEnd()
				else
					sprintLoopLastTime = t
				end
			else
				sprintLoopLastTime = nil
			end
		elseif sprintExitPending then
			PlaySprintEnd()
		end
	end
end

-- Instantly wipe sprint state (unequip / death).
local function ClearSprintInstant()
	sprintGen += 1
	sprintAnimState = 0
	sprintAnimActive = false
	sprintExitPending = false
	sprintLoopLastTime = nil
	springs.sprintPendingAim = false
	if wepStats then
		if wepStats.sprintStartAnim then StopAnimation(wepStats.sprintStartAnim, 0.1) end
		if wepStats.sprintLoopAnim then StopAnimation(wepStats.sprintLoopAnim, 0.1) end
		if wepStats.sprintEndAnim then StopAnimation(wepStats.sprintEndAnim, 0.1) end
	end
end

-- Debounced sprint-anim trigger: plays start/end to match the current `sprinting` state, but
-- once a transition fires it waits out a short cooldown before allowing the next one -- so
-- spamming sprint on/off can't violently restart the anims. After the cooldown it snaps to
-- whatever the final sprint state is. State kept on the `springs` table (no new top-level locals).
local function RequestSprintAnim()
	-- The cooldown MUST be at least as long as the crossfade blend, otherwise a new
	-- transition can fire while the previous start/end anim is still fading in and cut it
	-- off mid-blend (the "anims cutting each other off" bug). Floor it at the blend time.
	local blend = math.max(config.sprintBlendIn or 0.4, config.sprintBlendOut or 0.4)
	local COOLDOWN = math.max((wepStats and wepStats.sprintSpamCooldown) or config.sprintSpamCooldown or 0.2, blend)
	local now = os.clock()
	if now < (springs.sprintReady or 0) then
		-- A state change landed mid-cooldown. Remember it and make sure exactly one
		-- reconciler is queued to run the moment the cooldown clears, so the anim always
		-- settles onto the FINAL sprint state instead of getting stuck out of sync.
		springs.sprintPending = true
		if not springs.sprintReconciling then
			springs.sprintReconciling = true
			task.delay((springs.sprintReady or now) - now, function()
				springs.sprintReconciling = false
				if springs.sprintPending then
					springs.sprintPending = false
					RequestSprintAnim()
				end
			end)
		end
		return
	end
	if flags.sprinting then
		if sprintAnimState == 0 or sprintAnimState == 3 then sphReady.StartSprintAnim() end
	else
		if sprintAnimState == 1 or sprintAnimState == 2 then PlaySprintEnd() end
	end
	springs.sprintReady = os.clock() + COOLDOWN
	springs.sprintPending = false
end

local function ToggleSprint(toggle:boolean)
	if toggle then
		if flags.inspecting or flags.meleeing then return end
		if aiming then ToggleAiming(false) end
		svc.userInputService.MouseDeltaSensitivity = 1
		flags.holdingM1 = false
		if not wepStats then return end
		-- If in a ready stance, let its END anim finish FIRST, then start the sprint anim.
		-- Deferred via sphReady.pendingSprint -> sphReady.StartSprintAnim() in ExitReady's completion,
		-- instead of the old hard ClearReadyInstant() that skipped the ready end anim.
		if sphReady.state ~= 0 or sphReady.busy then
			sphReady.pendingSprint = true
			ExitReady()
			return
		end
		RequestSprintAnim() -- debounced start (see RequestSprintAnim)
	else
		sphReady.pendingSprint = false -- releasing sprint cancels a queued sprint-after-end
		-- Stopped sprinting: play the end anim right away (no waiting for the loop cycle), but
		-- debounced so spamming sprint on/off doesn't violently restart the anims.
		RequestSprintAnim()
	end
end

-- Begins ADS after exiting a ready stance (called from ExitReady's completion when
-- aim was pressed mid-stance). Mirrors the first-person SPH_HoldAim begin behaviour.
-- In hold mode the queued flag is cleared on release, so if we get here the button is
-- still held; in toggle mode this simply engages the toggle.
function sphReady.StartAimFromReady()
	if not equipped or flags.dead or not firstPerson then return end
	if aiming or blocked or flags.sprinting or sprintAnimActive or flags.inspecting or flags.meleeing then return end
	flags.aimHeld = true
	ToggleSprint(false)
	ToggleAiming(true)
end

-- Toggle the laser. mode = "normal" (tap) or "ir" (hold). Normal and IR share the one
-- emitter, so switching one on turns the other off. The IR laser always has a beam and
-- is only visible to viewers with night vision (the render loops gate it on NV).
local function ToggleLaser(mode)
	if not equipped or not gunModel or not gunModel:FindFirstChild("Grip") or not gunModel.Grip:FindFirstChild("Laser") then return end

	if mode == "ir" then
		if laser.enabled and laserIsIR then
			laser.enabled = false
		else
			laser.enabled, laserIsIR = true, true
		end
	else
		if laser.enabled and not laserIsIR then
			laser.enabled = false
		else
			laser.enabled, laserIsIR = true, false
		end
	end

	-- Randomized clicky toggle sound from Grip.ToggleSounds (see server for replication).
	PlayRandomSoundFromFolder(gunModel.Grip:FindFirstChild("ToggleSounds"), firstPerson and gunModel.Grip or humanoidRootPart)
	net.playSound:Fire("ToggleSounds", firstPerson)

	-- Replicate to other clients: (attachmentType 1 = laser, on/off, isIR flag so they
	-- know to gate it on THEIR night vision).
	net.playerToggleAttachment:Fire(1, laser.enabled, laserIsIR)

	-- Name it by the mode we just toggled: "IR LASER ON/OFF" for a hold, "LASER ON/OFF"
	-- for a tap.
	local prefix = (mode == "ir") and "IR LASER " or "LASER "
	-- Green tag when it comes on, grey when it goes off.
	require(modules.NotificationHandler).Notify(prefix .. (laser.enabled and "ON" or "OFF"), {
		Type = laser.enabled and "success" or "info",
		Tag = "ATTACHMENT",
	})
end

-- Push the current flashlight state onto BOTH gun models. The viewmodel holds the light
-- in first person and the third-person model holds it otherwise -- never both at once, or
-- you get a doubled light cone. The IR illuminator only lights up for a viewer who has
-- night vision on, and so does its emitter glow (nothing about IR is visible bare-eyed).
function springs.flash.Refresh()
	local f = springs.flash
	local tp = weaponRig and weaponRig:FindFirstChild("Weapon") and weaponRig.Weapon:FindFirstChildWhichIsA("Model")
	local nv = player:GetAttribute("NightVisionActive") == true
	local on = (equipped and laser.flashlightEnabled) and true or false
	local whiteOn = on and not f.isIR
	local irOn = on and f.isIR and nv

	-- Emitter glow part + lens flare (the flare itself is suppressed for IR inside SetPart).
	f.SetPart(gunModel, whiteOn or irOn)
	f.SetPart(tp, whiteOn or irOn)

	-- Hand the actual light to whichever model this viewer is looking at.
	local _, fpGun, fpIR = f.GetLights(gunModel)
	if fpGun then fpGun.Enabled = whiteOn and firstPerson end
	if fpIR then fpIR.Enabled = irOn and firstPerson end
	local _, tpGun, tpIR = f.GetLights(tp)
	if tpGun then tpGun.Enabled = whiteOn and not firstPerson end
	if tpIR then tpIR.Enabled = irOn and not firstPerson end
end

-- Toggle the flashlight. mode = "normal" (tap) or "ir" (hold) -- the exact same tap/hold
-- split as the laser. The white light and the IR illuminator share one housing, so
-- switching one on turns the other off.
function springs.flash.Toggle(mode)
	if not equipped or not gunModel or not gunModel:FindFirstChild("Grip") or not gunModel.Grip:FindFirstChild("Flashlight") then return end
	local f = springs.flash

	if mode == "ir" then
		if laser.flashlightEnabled and f.isIR then
			laser.flashlightEnabled = false
		else
			laser.flashlightEnabled, f.isIR = true, true
		end
	else
		if laser.flashlightEnabled and not f.isIR then
			laser.flashlightEnabled = false
		else
			laser.flashlightEnabled, f.isIR = true, false
		end
	end

	f.configKey = nil -- force the render loop to re-sync next frame
	f.Refresh()

	-- Randomized clicky toggle sound from Grip.ToggleSounds (see server for replication).
	PlayRandomSoundFromFolder(gunModel.Grip:FindFirstChild("ToggleSounds"), firstPerson and gunModel.Grip or humanoidRootPart)
	net.playSound:Fire("ToggleSounds", firstPerson)

	-- Replicate to other clients: (attachmentType 0 = flashlight, on/off, isIR flag so
	-- they know to gate it on THEIR night vision).
	net.playerToggleAttachment:Fire(0, laser.flashlightEnabled, f.isIR)

	local prefix = (mode == "ir") and "IR ILLUMINATOR " or "FLASHLIGHT "
	require(modules.NotificationHandler).Notify(prefix .. (laser.flashlightEnabled and "ON" or "OFF"), {
		Type = laser.flashlightEnabled and "success" or "info",
		Tag = "ATTACHMENT",
	})
end

-- Fires the IR laser mid-hold, the frame you cross LASER_HOLD_TIME while holding the
-- laser key. Per-frame elapsed check, so it's immune to the timer/first-press race.
-- The flashlight's IR illuminator uses the identical check on its own key.
svc.runService.Heartbeat:Connect(function()
	if laser.keyDown and not laser.holdConsumed and (os.clock() - laser.pressTime) >= LASER_HOLD_TIME then
		laser.holdConsumed = true
		ToggleLaser("ir")
	end
	local f = springs.flash
	if f.keyDown and not f.holdConsumed and (os.clock() - f.pressTime) >= f.holdTime then
		f.holdConsumed = true
		f.Toggle("ir")
	end
end)

local function HandleInput(actionName, inputState, inputObject)
	local inputBegan = Enum.UserInputState.Begin
	local inputEnded = Enum.UserInputState.End
	if equipped then
		if flags.unequipping or flags.equipping then return end
		-- Any weapon action cancels a ready stance: play the end anim and swallow the input.
		-- Exceptions (queued instead of dropped): aiming and firing both exit the stance and
		-- then take effect once the end animation finishes.
		--   * Aim: sphReady.pendingAim -> sphReady.StartAimFromReady() in ExitReady's completion.
		--   * Fire: we exit the stance but let the trigger press fall through so holdingM1 is
		--     set now; the fire loop is gated on sphReady.state==0 / not sphReady.busy, so the shot
		--     naturally holds until the end anim is done.
		-- Actions allowed to pass through even in a ready stance or mid-sprint, WITHOUT
		-- cancelling the stance: freelook and the laser/flashlight toggles. These just flip
		-- an attachment, so you can enable/disable a laser or flashlight while sprinting or
		-- holding high/low ready and stay in your current stance.
		local passiveAction = actionName == "SPH_Freelook"
			or actionName == "SPH_ToggleLaser"
			or actionName == "SPH_ToggleFlashlight"
			or actionName == "SPH_ToggleCant"
		if inputState == inputBegan and not passiveAction and (sphReady.state ~= 0 or sphReady.busy) then
			if actionName == "SPH_HoldAim" and firstPerson then
				sphReady.pendingAim = true
				ExitReady()
				return
			elseif actionName == "SPH_Trigger" then
				ExitReady()
				-- fall through to the SPH_Trigger handler below (no return)
			else
				ExitReady()
				return
			end
		end
		-- No weapon actions while a sprint animation is playing (start, loop or end),
		-- except the passive attachment toggles above.
		if inputState == inputBegan and not passiveAction and sprintAnimActive then
			-- ...except ADS during the END anim, which is QUEUED rather than thrown away, so
			-- stabbing aim as you pull up from a sprint feels immediate instead of eaten.
			-- It fires from PlaySprintEnd's unlock() the moment the threshold is crossed.
			if actionName == "SPH_HoldAim" and sprintAnimState == 3 and firstPerson
				and not blocked and not flags.inspecting and not flags.meleeing then
				flags.aimHeld = true
				springs.sprintPendingAim = true
			end
			return
		end
		if actionName == "SPH_Trigger" then
			if inputState == inputBegan then
				flags.cancelReload = true
				if not (flags.sprinting or flags.reloading or flags.inspecting or flags.meleeing) then
					flags.holdingM1 = true
					if not IsLoaded() and not (flags.curFireMode == fireModes.Manual and gunAmmo.MagAmmo.Value > 0) then
						PlayRepSound("TriggerPull")
					end
				end
			else
				flags.holdingM1 = false
				flags.canFire = true
				flags.bulletsCurrentlyFired = 0
				-- Play trigger reset sound on release (only when empty)
				if equipped and not (flags.sprinting or flags.reloading) then
					if not IsLoaded() and not (flags.curFireMode == fireModes.Manual and gunAmmo.MagAmmo.Value > 0) then
						PlayRepSound("TriggerRelease")
					end
				end
			end
		elseif actionName == "SPH_DropGun" and inputState == inputBegan and not flags.unequipping and not flags.equipping and not flags.inspecting and not flags.meleeing then
			local toolToDrop = equipped
			task.spawn(function()
				UnequipAnim()
				Unequip(toolToDrop)
				net.playerDropGun:Fire()
			end)
		elseif actionName == "SPH_Reload" and inputState == inputBegan and not flags.reloading and flags.cycled and not flags.inspecting and not flags.meleeing then
			-- CHANGED: If sprinting, cancel sprint first so the player slows to walk, then reload
			if flags.sprinting then
				character:SetAttribute("Sprinting", false)
				ToggleSprint(false)
			end
			if wepStats.infiniteAmmo or gunAmmo.ArcadeAmmoPool.Value > 0 then
				if (wepStats.openBolt and gunAmmo.MagAmmo.Value < gunAmmo.MagAmmo.MaxValue) then
					ReloadAnim()
				else
					if (wepStats.operationType == 4 and equipped.Chambered.Value)
						or (wepStats.operationType == 3 and gunAmmo.MagAmmo.MaxValue > 1 and gunAmmo.MagAmmo.Value + 1 >= gunAmmo.MagAmmo.MaxValue)
						or (wepStats.operationType == 2 and gunAmmo.MagAmmo.Value >= gunAmmo.MagAmmo.MaxValue) then
						return
					end
					ReloadAnim()
				end
			end
		elseif actionName == "SPH_HoldAim" then
			local toggleMode = svc.userInputService.TouchEnabled or config.toggleAiming
			if inputState == inputBegan then
				-- Aiming is first-person only. In third person, right-click does nothing.
				if firstPerson then
					if not toggleMode then
						if not blocked and not flags.sprinting and not flags.inspecting and not flags.meleeing then
							flags.aimHeld = true
							ToggleSprint(false)
							ToggleAiming(true)
						end
					else
						if not aiming and not blocked and not flags.sprinting and not flags.inspecting and not flags.meleeing then
							flags.aimHeld = true
							ToggleSprint(false)
							ToggleAiming(true)
						else
							flags.aimHeld = false
							ToggleAiming(false)
						end
					end
				end
			else
				-- Release: ADS release respects toggle mode.
				-- In hold mode, letting go before the queued aim triggers cancels it.
				if not toggleMode then sphReady.pendingAim = false; springs.sprintPendingAim = false end
				if not toggleMode and aiming then
					flags.aimHeld = false
					ToggleAiming(false)
				end
			end
		elseif actionName == "SPH_Chamber" and inputState == inputBegan and not flags.reloading and flags.cycled and not flags.inspecting and not flags.meleeing then
			-- wepStats.unaimToChamber: come OFF the sights to work the bolt, the way you
			-- actually cycle a scoped rifle, then shoulder back in once the stroke is done
			-- (only if the aim button is still held -- letting go cancels the return).
			if wepStats and wepStats.unaimToChamber and aiming then
				springs.reaimChamber = wepStats.chamberReaimWindow or 1.5
				ToggleAiming(false)
			end
			ChamberAnim()
		elseif actionName == "SPH_SwitchSights" and inputState == inputBegan and not flags.reloading and not flags.inspecting and not flags.meleeing then
			-- A gun with a magnifier spends this key flipping it in / out of the line of
			-- sight. Everything else keeps cycling AimParts exactly the way it always did.
			if springs.magnifier.Has() then
				if springs.magnifier.Toggle(aiming) then
					-- No cue on the flip: the sight-swap sounds belong to swapping sights, and
					-- borrowing them made the magnifier sound like something else. Set
					-- flipSound/unflipSound in the magnifier block if you want one; the module
					-- plays those itself.
					-- IsEngaged flips the instant the key is pressed (GetBlend is the live
					-- swing, which hasn't moved yet on this frame), so this is the state
					-- everyone else should tween toward.
					net.playerFlipMag:Fire(not springs.magnifier.IsEngaged())
				end
			elseif aiming and gunModel:FindFirstChild("AimPart2") then
				local tempIndex = sightIndex + 1
				if gunModel:FindFirstChild("AimPart"..tempIndex) then
					sightIndex = tempIndex
					PlayRepSound("AimUp")
				else
					sightIndex = 1
					PlayRepSound("AimDown")
				end
				if wepStats.ADSEnabled and wepStats.ADSEnabled[sightIndex] then ToggleADS(true) else ToggleADS(false) end
			end
		elseif actionName == "SPH_Freelook" then
			if inputState == inputBegan then
				freeLook = true
				humanoid.AutoRotate = false
				cam.freeLookRotation = camera.CFrame - camera.CFrame.Position
			else
				freeLook = false
				cam.freeLookOffset = cam.freeLookRotation:ToObjectSpace(camera.CFrame)
				cam.freeLookOffset = cam.freeLookOffset - cam.freeLookOffset.Position
				humanoid.AutoRotate = true
			end
		elseif actionName == "SPH_SwitchFireMode" and inputState == inputBegan and not flags.inspecting and not flags.fireModeSwitching and not flags.meleeing then
			flags.fireModeSwitching = true
			PlayAnimation(wepStats.switchAnim,{transSpeed = 0.2})
			task.delay(0.5, function() flags.fireModeSwitching = false end)
		elseif actionName == "SPH_ToggleLaser" and gunModel.Grip:FindFirstChild("Laser") then
			-- Press: start the hold timer. The Heartbeat check below fires IR mid-hold once
			-- the threshold is crossed. Release before that = a tap = normal laser.
			if inputState == inputBegan then
				laser.keyDown = true
				laser.holdConsumed = false
				laser.pressTime = os.clock()
			elseif inputState == inputEnded then
				laser.keyDown = false
				if not laser.holdConsumed then
					ToggleLaser("normal") -- released before the hold triggered -> tap
				end
			end
		elseif actionName == "SPH_ToggleFlashlight" and gunModel.Grip:FindFirstChild("Flashlight") then
			-- Identical tap/hold split to the laser: press starts the hold timer, the
			-- Heartbeat check above fires the IR illuminator the moment you cross
			-- springs.flash.holdTime. Releasing before that counts as a tap = white light.
			if inputState == inputBegan then
				springs.flash.keyDown = true
				springs.flash.holdConsumed = false
				springs.flash.pressTime = os.clock()
			elseif inputState == inputEnded then
				springs.flash.keyDown = false
				if not springs.flash.holdConsumed then
					springs.flash.Toggle("normal") -- released before the hold triggered -> tap
				end
			end
		elseif actionName == "SPH_ToggleSuppressor" and inputState == inputBegan then
			local suppressor: BasePart = gunModel:FindFirstChild("Suppressor")
			local suppressedFireSound = gunModel.Grip:FindFirstChild("SuppressedFire")
			if suppressor and suppressedFireSound then
				if gunModel:GetAttribute("SuppressorOn") then
					assets.Events.ToggleAttachment:FireServer("Suppressor", false)
					suppressor.Transparency = 1
				else
					assets.Events.ToggleAttachment:FireServer("Suppressor", true)
					suppressor.Transparency = 0
				end
			end
		elseif actionName == "SPH_ToggleBipod" and inputState == inputBegan then
			local bipodBase = gunModel:FindFirstChild("BipodBase")
			if bipodBase and wepStats.bipodHeight then
				if not equipped:GetAttribute("BipodEnabled") and CanOpenBipod() then
					equipped:SetAttribute("BipodEnabled", true)
					if gunModel.Grip:FindFirstChild("Bipod") then gunModel.Grip.Bipod:Play() end
				else
					equipped:SetAttribute("BipodEnabled", false)
					if gunModel.Grip:FindFirstChild("Bipod") then gunModel.Grip.Bipod:Play() end
				end
			end
		elseif actionName == "SPH_ToggleCant" and inputState == inputBegan then
			-- Toggle the weapon cant (aims through the gun's NVAimPart pose, the same one night
			-- vision uses). NV forces cant on regardless; this lets you cant WITHOUT goggles.
			-- Sticky: press again to un-cant. Reset on unequip/death. Silent -- no click or
			-- notification. Inlined (not its own function) to avoid a new top-level local
			-- (Luau caps the main chunk at 200).
			if gunModel then
				springs.cantOn = not springs.cantOn
				-- No wobble kick here: UpdateViewmodelPosition kicks it only when the cant
				-- pose actually changes, so pressing this under NVGs (already canted) or on a
				-- gun with no NVAimPart stays completely still.
			end
		elseif actionName == "SPH_Inspect" and inputState == inputBegan then
			ToggleInspect()
		end
	end
end

function BindAiming()
	svc.contextActionService:BindActionAtPriority("SPH_HoldAim", HandleInput, config.mobileButtons, config.gunInputPriority, unpack(config.aimGun))
	svc.contextActionService:SetTitle("SPH_HoldAim", "Aim")
	svc.contextActionService:SetPosition("SPH_HoldAim", UDim2.fromScale(0.24, 0.3))
end

function UnbindAiming()
	svc.contextActionService:UnbindAction("SPH_HoldAim")
end

local function BindGunInputs()
	-- Rebindable actions read their key from NorthgateKeybinds instead of GameConfig.
	-- Unpack() returns the player's current key followed by the gamepad/mouse
	-- alternates from GameConfig, so pad bindings survive a rebind untouched.
	-- HasAny() covers an action switched off in GameConfig (config.toggleCant = nil)
	-- or deliberately unbound by the player.
	local function bind(actionName, actionId, touchButton)
		if not mods.Keybinds.HasAny(actionId) then return end
		svc.contextActionService:BindActionAtPriority(actionName, HandleInput, touchButton, config.gunInputPriority, mods.Keybinds.Unpack(actionId))
	end

	svc.contextActionService:BindActionAtPriority("SPH_Trigger", HandleInput, config.mobileButtons, config.gunInputPriority, unpack(config.fireGun))
	svc.contextActionService:BindActionAtPriority("SPH_DropGun", HandleInput, false, config.gunInputPriority, unpack(config.dropKey))
	bind("SPH_Reload", "Reload", config.mobileButtons)
	bind("SPH_Chamber", "Chamber", false)
	bind("SPH_SwitchSights", "SwitchSights", false)
	svc.contextActionService:BindActionAtPriority("SPH_Freelook", HandleInput, false, config.gunInputPriority, unpack(config.freeLook))
	bind("SPH_SwitchFireMode", "FireMode", false)
	bind("SPH_ToggleLaser", "Laser", false)
	bind("SPH_ToggleFlashlight", "Flashlight", false)
	bind("SPH_ToggleCant", "Cant", false)
	svc.contextActionService:BindActionAtPriority("SPH_ToggleSuppressor", HandleInput, false, config.gunInputPriority, unpack(config.toggleSuppressor))
	svc.contextActionService:BindActionAtPriority("SPH_ToggleBipod", HandleInput, false, config.gunInputPriority, unpack(config.toggleBipod))
	svc.contextActionService:BindActionAtPriority("SPH_Inspect", HandleInput, false, config.gunInputPriority, Enum.KeyCode.P)
	BindAiming() -- first person aims down sights; third person no longer aims
	svc.contextActionService:SetTitle("SPH_Trigger", "Fire")
	svc.contextActionService:SetPosition("SPH_Trigger", UDim2.fromScale(0.3, 0.6))
	svc.contextActionService:SetTitle("SPH_Reload", "Reload")
	svc.contextActionService:SetPosition("SPH_Reload", UDim2.fromScale(0, 0.6))
end

local function UnbindGunInputs()
	svc.contextActionService:UnbindAction("SPH_Trigger")
	svc.contextActionService:UnbindAction("SPH_DropGun")
	svc.contextActionService:UnbindAction("SPH_Reload")
	svc.contextActionService:UnbindAction("SPH_HoldAim")
	svc.contextActionService:UnbindAction("SPH_Chamber")
	svc.contextActionService:UnbindAction("SPH_SwitchSights")
	svc.contextActionService:UnbindAction("SPH_Freelook")
	svc.contextActionService:UnbindAction("SPH_SwitchFireMode")
	svc.contextActionService:UnbindAction("SPH_ToggleLaser")
	svc.contextActionService:UnbindAction("SPH_ToggleFlashlight")
	svc.contextActionService:UnbindAction("SPH_ToggleCant")
	svc.contextActionService:UnbindAction("SPH_ToggleSuppressor")
	svc.contextActionService:UnbindAction("SPH_ToggleBipod")
	svc.contextActionService:UnbindAction("SPH_Inspect")
end

-- A keybind changed in settings (or the saved binds just arrived from the server).
-- ContextActionService has no "change the key" call, so the whole set is rebuilt.
-- Only matters while a gun is out; otherwise the next equip picks up the new keys.
-- Wrapped in do..end so `conn` isn't a top-level local (Luau caps the main chunk at
-- 200 and this file is close), and disconnected with the character -- this script is
-- re-created every respawn but NorthgateKeybinds is required once per client, so a
-- listener per life would pile up forever.
do
	local conn = mods.Keybinds.OnChanged(function()
		if equipped then
			UnbindGunInputs()
			BindGunInputs()
		end
	end)
	character.AncestryChanged:Connect(function()
		if conn and not character:IsDescendantOf(game) then
			conn:Disconnect()
			conn = nil
		end
	end)
end

-- Smoothly lerp the AimDOF effect toward its target every frame (set in SetAimDOF). Manual lerp
-- because TweenService snaps on DepthOfFieldEffect. Frame-rate independent via dofSpeed * dt.
svc.runService.RenderStepped:Connect(function(dt)
	local eff = springs.aimDOF
	if not eff then return end
	local t = springs.dofTarget
	local a = math.min(1, (springs.dofSpeed or 6) * dt)
	eff.FarIntensity = eff.FarIntensity + (t.far - eff.FarIntensity) * a
	eff.NearIntensity = eff.NearIntensity + (t.near - eff.NearIntensity) * a
	eff.FocusDistance = eff.FocusDistance + (t.focus - eff.FocusDistance) * a
	eff.InFocusRadius = eff.InFocusRadius + (t.radius - eff.InFocusRadius) * a
end)

humanoid.Died:Connect(function()
	flags.dead = true
	SetAimDOF(false) -- clear aim DOF if you died while aiming
	ClearSprintInstant()
	net.switchWeapon:Fire()
	equipped = nil
	wepStats = nil
	flags.fireDelayActive = false
	svc.userInputService.MouseIconEnabled = true
	svc.userInputService.MouseBehavior = Enum.MouseBehavior.Default
	character:SetAttribute("SPH_GunLockedMouse", false)

	-- A perspective fade that was in flight when we died is now abandoned mid-way,
	-- so clear its flag and its black frame here. Without this, dying inside the
	-- half-second toggle window leaves perspectiveTransitioning stuck true and the
	-- first-person key dead for the rest of the life.
	flags.perspectiveTransitioning = false
	fadeFrame.BackgroundTransparency = 1
	ToggleAiming(false)
	flags.viewmodelVisible = false
	animBase.CFrame = storageCFrame
	springs.scope.Clear() -- dying with a scope up must not leave the overlay on screen
	-- The unified FOV smoother is gated behind `equipped`, which was nil'd a few lines up,
	-- so it will never lerp the magnification back out on its own. And FieldOfView is a
	-- Camera property, not a character one, so it survives the respawn -- which is exactly
	-- why dying while scoped used to leave you stuck at ~18 FOV on the next life. Snap the
	-- camera back here, and reset the aim target with it so the next weapon starts clean.
	camera.FieldOfView = defaultFOV
	cam.aimFOVTarget = defaultFOV
	-- Same shape of bug: MouseDeltaSensitivity is only rewritten while aiming AND equipped,
	-- so a 6x optic otherwise leaves the mouse at a sixth speed for the whole respawn.
	svc.userInputService.MouseDeltaSensitivity = 1
	UnbindGunInputs()

	-- Force back to third person so the next spawn starts clean
	flags.forcedFirstPerson = false
	firstPerson = false
	character:SetAttribute("SPH_FirstPerson", false)
	-- Drop any outstanding perspective request/lock: dying while the binoculars were
	-- up would otherwise leave V jammed for the rest of this character's life.
	character:SetAttribute("SPH_ForcePerspective", nil)
	character:SetAttribute("SPH_PerspectiveLocked", nil)
	player.CameraMode = Enum.CameraMode.Classic

	if config.useDeathCameraSubject then
		repeat task.wait() until humanoid.Parent ~= character
		camera.CameraSubject = humanoid
	end
	if rig then rig:Destroy() end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = nil
end)

function Unequip(tool)
	flags.inspecting = false
	flags.meleeing = false
	flags.fireDelayActive = false
	-- Belt-and-braces: UnequipAnim() latches canFire off, and only a trigger RELEASE ever
	-- turned it back on. Paths that skip UnequipAnim (death, vehicle seat, drop) would
	-- otherwise leave the flag stuck off and eat the first shot on the next gun.
	flags.canFire = true
	flags.holdingM1 = false
	flags.bulletsCurrentlyFired = 0
	character:SetAttribute("Inspecting", false)
	character:SetAttribute("Meleeing", false)
	animBase.CFrame = storageCFrame
	net.switchWeapon:Fire()
	if tool == equipped then
		equipped = nil
		wepStats = nil
	end
	svc.userInputService.MouseIconEnabled = not flags.forcedFirstPerson
		and player:GetAttribute("InHelicopterSeat") ~= true
	character:SetAttribute("SPH_GunLockedMouse", false)
	if not flags.forcedFirstPerson then
		svc.userInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	ToggleAiming(false)
	flags.viewmodelVisible = false
	for _, track in ipairs(vmAnimator:GetPlayingAnimationTracks()) do track:Stop() end
	for _, track in ipairs(characterAnimator:GetPlayingAnimationTracks()) do track:Stop() end
	if config.lockFirstPerson then player.CameraMode = Enum.CameraMode.Classic end
	sights = {}
	springs.scope.Clear() -- drop the 2D scope overlay + un-hide the viewmodel
	proneMoveAnim = nil
	walkMoveAnim = nil
	freeLook = false
	cam.freeLookOffset = cam.freeLookRotation:ToObjectSpace(camera.CFrame)
	cam.freeLookOffset = cam.freeLookOffset - cam.freeLookOffset.Position
	humanoid.AutoRotate = true
	ClearReadyInstant()
	sphReady.ClearStanceAnim()
	ClearSprintInstant()
	SetAimDOF(false) -- clear aim DOF on unequip
	laser.enabled = false
	laserIsIR = false
	laser.configKey = nil
	springs.cantOn = false
	springs.cantBlend = 0
	springs.cantWasOn = nil -- next weapon re-syncs the cant state without a wobble kick
	if springs.boltLockConn then springs.boltLockConn:Disconnect(); springs.boltLockConn = nil end
	laser.flashlightEnabled = false
	springs.flash.isIR = false
	springs.flash.keyDown = false
	springs.flash.holdConsumed = false
	springs.flash.configKey = nil
	springs.flash.Refresh() -- kills both lights and drops the emitter glow + flare
	laser.visible = false
	laser.beamFP.Enabled = false
	laser.beamTP.Enabled = false
	springs.laserGlowFP.Enabled = false
	springs.laserGlowTP.Enabled = false
	if laser.trailPart then laser.trailPart.CFrame = LASER_STORAGE_CF end
	if laserTrail then laserTrail.Enabled = false; laserTrail:Clear() end
	SetLaserPart(gunModel, false)
	SetLaserPart(GetThirdPersonGunModel(), false) -- also drop the third-person emitter flare
	fakeCameraMotor = nil
	cam.fakeCameraSmoothed = Vector3.zero
	flags.aimTransitionPlaying = false
	UnbindGunInputs()
	if animBase:FindFirstChild("AnimBase_Grip") then
		animBase.AnimBase_Grip:Destroy()
	end
end

local function GetRotationBetween(u, v, axis)
	local dot, uxv = u:Dot(v), u:Cross(v)
	if (dot < -0.99999) then return CFrame.fromAxisAngle(axis, math.pi) end
	return CFrame.new(0, 0, 0, uxv.x, uxv.y, uxv.z, 1 + dot)
end

character.ChildAdded:Connect(function(newChild)
	if newChild:FindFirstChild("SPH_Weapon") and not assets.WeaponModels:FindFirstChild(newChild.Name) then
		warn(warnPrefix.."No gun model could be found for '"..newChild.Name.."'")
		return
	end
	-- Swimming: bounce any tool that gets equipped straight back to the Backpack.
	if newChild:FindFirstChild("SPH_Weapon") and springs.swimming then
		task.defer(function()
			if springs.swimming and newChild.Parent == character then
				humanoid:UnequipTools()
			end
		end)
		return
	end
	if newChild:FindFirstChild("SPH_Weapon") and not flags.dead and (not humanoid.Sit or humanoid.Sit and not flags.vehicleSeated) then
		-- If mid-equip, ignore completely
		if flags.equipping then return end
		-- If mid-unequip, remember this tool and let the unequip finish first
		if flags.unequipping then
			flags.pendingEquipTool = newChild
			return
		end
		-- If already equipped with a weapon, play unequip anim first
		if equipped and wepStats then
			local oldTool = equipped
			local newTool = newChild
			task.spawn(function()
				UnequipAnim()
				Unequip(oldTool)
				-- Prefer the most recently queued tool if one arrived during unequip
				local toolToEquip = flags.pendingEquipTool or newTool
				flags.pendingEquipTool = nil
				if toolToEquip and toolToEquip.Parent == character and not flags.dead then
					humanoid:EquipTool(toolToEquip)
				end
			end)
			return
		end
		flags.reloading = false
		character:SetAttribute("Reloading", false)
		svc.userInputService.MouseIconEnabled = false
		if not firstPerson then
			svc.userInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			character:SetAttribute("SPH_GunLockedMouse", true)
		end
		cam.hipRotation = Vector2.zero
		flags.equipping = true
		blocked = false
		laser.enabled = false
		laserIsIR = false
		laser.configKey = nil
		laser.flashlightEnabled = false
		springs.flash.isIR = false
		springs.flash.keyDown = false
		springs.flash.holdConsumed = false
		springs.flash.configKey = nil
		springs.cantOn = false
		springs.cantBlend = 0
		springs.cantWasOn = nil -- sync on the first frame with this gun, no wobble on equip
		flags.cycled = true
		-- UnequipAnim() sets canFire = false, and the ONLY thing that used to set it back
		-- was releasing the trigger -- so after any weapon switch the first click was eaten
		-- (very obvious on Manual/bolt-action guns, where every shot is a deliberate click).
		-- Reset the whole trigger state with the rest of the per-equip state here.
		flags.canFire = true
		flags.holdingM1 = false
		flags.bulletsCurrentlyFired = 0
		flags.chambering = false
		net.switchWeapon:Fire(newChild)
		equipped = newChild
		wepStats = require(equipped.SPH_Weapon.WeaponStats)
		springs.recoil.Damping = wepStats.recoil.damping
		springs.recoil.Speed = wepStats.recoil.speed
		springs.gunRecoil.Damping = wepStats.gunRecoil.damping
		springs.gunRecoil.Speed = wepStats.gunRecoil.speed
		-- Per-shot FOV kick spring feel (per weapon, else GameConfig). Lower damper = more bounce.
		local fk = wepStats.fovKick or {}
		springs.fovShoot.Damping = fk.damper or config.fovKickDamper or 0.7
		springs.fovShoot.Speed = fk.speed or config.fovKickSpeed or 12
		-- Look-sway tuning per weapon (falls back to GameConfig defaults). speed = catch-up
		-- rate (lower = floatier), damper = bounciness (lower = more overshoot before settle).
		local swayCfg = wepStats.sway
		springs.lookSway.s = (swayCfg and swayCfg.speed) or config.swaySpeed or 9
		springs.lookSway.d = (swayCfg and swayCfg.damper) or config.swayDamper or 0.55
		springs.posSway.s = (swayCfg and swayCfg.posSpeed) or config.swayPosSpeed or 7
		springs.posSway.d = (swayCfg and swayCfg.posDamper) or config.swayPosDamper or 0.6
		offset = wepStats.viewmodelOffset
		cam.aimFOVTarget = wepStats.aimFovDefault or defaultFOV
		springs.scope.SetWeapon(wepStats) -- 2D scopes: reads wepStats.scopes
		-- Publish this gun's ADS raise/lower timing so the CameraBobAndFallSway script can
		-- ease the aim cant (tilt) in/out at the same speed as the aim itself.
		character:SetAttribute("SPH_AimInTime", wepStats.aimInTime or config.aimInTime or 0.3)
		character:SetAttribute("SPH_AimOutTime", wepStats.aimOutTime or config.aimOutTime or 0.25)
		cam.freeLookOffset = CFrame.new()
		proneMoveAnim = wepStats.proneMoveAnim and PlayAnimation(wepStats.proneMoveAnim, {looped = true, priority = Enum.AnimationPriority.Movement, transSpeed = 1}, "ProneMove", true)
		walkMoveAnim = wepStats.walkAnim and PlayAnimation(wepStats.walkAnim, {looped = true, priority = Enum.AnimationPriority.Movement, transSpeed = 1}, "WalkMove", true)
		if not wepStats.operationType then wepStats.operationType = 1 end
		if type(wepStats.operationType) == "string" then wepStats.operationType = 1 end
		if not wepStats.magType then wepStats.magType = 1 end
		local oldGun = rig.Weapon:FindFirstChildWhichIsA("Model")
		if oldGun then oldGun:Destroy() end
		local gun = assets.WeaponModels:FindFirstChild(newChild.Name)
		if not gun then warn(warnPrefix.."Could not find a gun model with the name: '".. newChild.Name.. "'!") return end
		gun = gun:Clone()
		if not wepStats.disableAutoRigging then
			mods.weldMod.WeldModel(gun,gun.Grip,false)
			for _, partName in ipairs(wepStats.rigParts) do
				if gun:FindFirstChild(partName) then
					gun.Grip["Grip_"..partName]:Destroy()
					local newMotor = mods.weldMod.M6D(gun.Grip,gun[partName])
					newMotor.Name = partName
					newMotor.Parent = gun.Grip
				end
			end
		end
		-- Moved OUT of the disableAutoRigging block. It used to be the last thing the
		-- auto-rigger did, so turning auto-rigging off also left every part of the gun
		-- collidable -- a hand-rigged gun would shove itself around the character and the
		-- world. Uncolliding the model has nothing to do with how it was welded, so it now
		-- runs either way.
		for _, desc:BasePart in gun:GetDescendants() do
			if desc:IsA("BasePart") then desc.CanCollide = false end
		end
		for _, part in ipairs(gun:GetChildren()) do
			if part.Name == "SightReticle" then table.insert(sights,part) end
		end
		gun.Parent = rig.Weapon
		gunModel = gun
		fakeCameraPart = weaponRig:FindFirstChild("FakeCamera", true)
		fakeCameraMotor = nil
		cam.fakeCameraSmoothed = Vector3.zero
		if fakeCameraPart then
			for _, desc in ipairs(weaponRig:GetDescendants()) do
				if desc:IsA("Motor6D") and (desc.Part1 == fakeCameraPart or desc.Part0 == fakeCameraPart) then
					fakeCameraMotor = desc
					break
				end
			end
		end
		mods.weldMod.BlankM6D(rig.AnimBase,gun.Grip)
		-- Rebuild the magnifier drive for the new gun. Both models are handed over so the
		-- swing shows on the viewmodel AND on your own third-person body; other players are
		-- covered by the PlayerFlipMagnifier bridge. No-op on a gun with no magnifier block.
		springs.magnifier.SetWeapon(wepStats, { gun })
		-- The third-person gun is built by the SERVER, so on the frame you equip it usually
		-- isn't there yet -- which is why your own body's magnifier never moved while the
		-- viewmodel's did. Keep looking for a moment and hand it over when it shows up.
		if springs.magnifier.Has() then
			task.spawn(function()
				local myGun = gun
				for _ = 1, 40 do
					if gunModel ~= myGun then return end -- switched weapons; stop chasing this one
					local worldGun = weaponRig and weaponRig:FindFirstChild("Weapon")
						and weaponRig.Weapon:FindFirstChildWhichIsA("Model")
					if worldGun and springs.magnifier.AddModel(worldGun) then return end
					task.wait(0.1)
				end
			end)
		end
		if firstPerson then RefreshViewmodel() end
		BindGunInputs()
		ToggleSprint(character:GetAttribute("HoldingSprint"))
		EquipAnim()
		IdleAnim()
		gunAmmo = newChild:WaitForChild("Ammo")
		if not equipped.BoltReady.Value then MoveBolt(wepStats.boltDist,true) end
		-- Empty bolt lock (robust): latch the bolt OPEN whenever BoltReady flips to false --
		-- the authoritative "gun is empty" signal from the server. On the firing frame the
		-- client's MagAmmo is still predicting ahead of the server, so MoveBolt there sees a
		-- non-empty mag and cycles the bolt closed; by the time BoltReady replicates false,
		-- MagAmmo has reliably reached 0, so this MoveBolt holds the bolt back. Stored on the
		-- springs table (no new top-level local -- Luau caps the main chunk at 200).
		if springs.boltLockConn then springs.boltLockConn:Disconnect() end
		springs.boltLockConn = equipped.BoltReady:GetPropertyChangedSignal("Value"):Connect(function()
			if equipped and not equipped.BoltReady.Value and wepStats.emptyLockBolt
				and not wepStats.openBolt and not IsLoaded() then
				MoveBolt(wepStats.boltDist) -- wrapper also replicates the latch to other players
			end
		end)
		-- Re-assert once after equip so an already-empty gun shows the bolt locked even if the
		-- equip animation just cycled it closed.
		task.defer(function()
			if equipped == newChild and not equipped.BoltReady.Value and wepStats.emptyLockBolt
				and not wepStats.openBolt and not IsLoaded() then
				MoveBolt(wepStats.boltDist)
			end
		end)
		if config.lockFirstPerson then player.CameraMode = Enum.CameraMode.LockFirstPerson end
		flags.curFireMode = equipped.FireMode.Value
		if gunModel.Grip:FindFirstChild("Laser") then laser.beamFP.Attachment0 = gunModel.Grip.Laser end
		if wepStats.magType == 1 then
			PlayAnimation(wepStats.reloadAnim,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17},"Reload",true)
		else
			PlayAnimation(wepStats.reloadAnim,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0, looped = gunAmmo.MagAmmo.MaxValue > 1},"Reload",true)
			if wepStats.magType == 3 then
				PlayAnimation(wepStats.clipReloadAnim,{speed = wepStats.reloadSpeedModifier,priority = Enum.AnimationPriority.Action2,transSpeed = 0.17, looped = false},"Reload",true)
			end
		end
		local newEquipAnim: AnimationTrack = PlayAnimation(wepStats.equipAnim,{priority = Enum.AnimationPriority.Action2, looped = false},"Equip", true)
		newEquipAnim.Stopped:Connect(function() flags.equipping = false end)
		if wepStats.firstEquipAnim then
			local firstEquip: AnimationTrack = PlayAnimation(wepStats.firstEquipAnim,{priority = Enum.AnimationPriority.Action2, looped = false},"Equip", true)
			firstEquip.Stopped:Connect(function() flags.equipping = false end)
		end
		PlayAnimation(wepStats.boltChamber,{priority = Enum.AnimationPriority.Action2, transSpeed = 0.05, looped = false},"Chamber", true)
		if wepStats.operationType == 2 or wepStats.operationType == 3 then
			PlayAnimation(wepStats.boltOpen,{priority = Enum.AnimationPriority.Action2, transSpeed = 0, looped = false},"BoltOpen", true)
			PlayAnimation(wepStats.boltClose,{priority = Enum.AnimationPriority.Action2, looped = false},"BoltClose", true)
		end
		if wepStats.aimAnim then
			PlayAnimation(wepStats.aimAnim, {looped = true, priority = Enum.AnimationPriority.Action, transSpeed = wepStats.aimTime / 6}, "AimAnim", true)
		end
	elseif newChild.Name == "WeaponRig" then
		weaponRig = newChild
		characterAnimator = weaponRig:WaitForChild("AnimationController", 20).Animator
	end
end)

character.ChildRemoved:Connect(function(oldChild)
	if equipped and oldChild:FindFirstChild("SPH_Weapon") and assets.WeaponModels:FindFirstChild(oldChild.Name) then
		-- If we are already handling the unequip via UnequipAnim or mid-equip, skip
		if not flags.unequipping and not flags.equipping then
			task.spawn(function()
				UnequipAnim()
				Unequip(oldChild)
				-- Check if a tool was queued while we were unequipping
				local pending = flags.pendingEquipTool
				flags.pendingEquipTool = nil
				if pending and pending.Parent == character and not flags.dead then
					humanoid:EquipTool(pending)
				end
			end)
		elseif not flags.unequipping and flags.equipping then
			-- Block unequipping while the equip animation is still playing: put the tool
			-- straight back so the equip finishes. Only genuinely let it go if we're dying
			-- or being seated in a vehicle (cases where the gun must come off regardless).
			if flags.dead or flags.vehicleSeated or springs.swimming or humanoid.Sit then
				flags.equipping = false
				Unequip(oldChild)
			else
				task.defer(function()
					if not flags.dead and not flags.vehicleSeated and not springs.swimming and not humanoid.Sit
						and oldChild.Parent ~= character and oldChild:IsDescendantOf(game) then
						humanoid:EquipTool(oldChild)
					end
				end)
			end
		end
	end
end)

-- Core firing logic extracted into a function so it can be called directly or after a fire delay
local function ExecuteFire()
	if not equipped or flags.dead or not flags.cycled or flags.sprinting or sprintAnimActive or flags.reloading or flags.unequipping then return end
	if not flags.canFire or blocked or not IsLoaded() or flags.curFireMode <= 0 then return end
	if not (config.fireWithFreelook or (not config.fireWithFreelook and not freeLook)) then return end
	if flags.equipping then return end
	if proneMoveAnim and proneMoveAnim.IsPlaying then return end
	if not firstPerson and not config.thirdPersonFiring then return end
	if wepStats.fireAnim then PlayAnimation(wepStats.fireAnim,{priority = Enum.AnimationPriority.Action2, looped = false}) end
	flags.bulletsCurrentlyFired += 1
	flags.playedDryCue = false -- a live round just fired, so re-arm the out-of-ammo cue
	flags.ejected = false
	if flags.curFireMode == fireModes.Semi or flags.curFireMode == fireModes.Manual or (flags.curFireMode == fireModes.Burst and flags.bulletsCurrentlyFired >= wepStats.burstNumber) then
		flags.canFire = false
		flags.holdingM1 = false
	end
	flags.cycled = false
	local curModel = weaponRig.Weapon:FindFirstChildWhichIsA("Model")
	curModel = gunModel
	local recoilStats = wepStats.recoil
	local vertRecoil = recoilStats.vertical
	local horzRecoil = recoilStats.horizontal
	horzRecoil *= 100
	if aiming then vertRecoil /= recoilStats.aimReduction; horzRecoil /= recoilStats.aimReduction end
	if character:GetAttribute("Stance") == "Prone" then vertRecoil /= 3; horzRecoil /= 3 end
	if equipped:GetAttribute("BipodEnabled") then
		local rr = wepStats.recoilReduction or 3
		vertRecoil /= rr; horzRecoil /= rr
	end
	horzRecoil = math.random(-horzRecoil,horzRecoil)
	horzRecoil /= 100
	springs.recoil:shove(Vector3.new(vertRecoil, horzRecoil,recoilStats.camShake))
	recoilStats = wepStats.gunRecoil
	vertRecoil = recoilStats.vertical
	horzRecoil = recoilStats.horizontal
	horzRecoil *= 100
	horzRecoil = math.random(-horzRecoil, horzRecoil)
	if character:GetAttribute("Stance") == "Prone" then vertRecoil /= 1.5; horzRecoil /= 1.5 end
	if equipped:GetAttribute("BipodEnabled") then
		local rr = wepStats.recoilReduction or 3
		vertRecoil /= rr; horzRecoil /= rr
	end
	horzRecoil /= 100
	springs.gunRecoil:shove(Vector3.new(vertRecoil, horzRecoil ,recoilStats.punchMultiplier))
	-- Per-shot FOV kick (springy). Positive = widen, negative = narrow. Reduced while aiming.
	local fk = wepStats.fovKick or {}
	local fovAmt = aiming and (fk.aimAmount or config.fovKickAimAmount or 1) or (fk.amount or config.fovKickAmount or 2)
	springs.fovShoot:shove(Vector3.new(fovAmt, 0, 0))
	if flags.curFireMode ~= fireModes.Manual then EjectShell() end
	local bulletHolderPart = wepStats.bulletHolder and gunModel:FindFirstChild(wepStats.bulletHolder)
	if bulletHolderPart then
		UpdateBulletTransparency(bulletHolderPart, gunAmmo.MagAmmo.MaxValue - (gunAmmo.MagAmmo.Value - 1), 1)
	end
	local tempGunModel = firstPerson and gunModel or weaponRig.Weapon:FindFirstChildWhichIsA("Model")
	mods.bulletHandler.FireFX(player,tempGunModel,"Muzzle",wepStats.muzzleChance)

	PlayFireSounds()
	-- Tell CombatMusicClient we fired (once per trigger pull, shotguns count as one).
	local shotFiredEvent = svc.replicatedStorage:FindFirstChild("LocalShotFired")
	if shotFiredEvent then shotFiredEvent:Fire() end
	MoveBolt(wepStats.boltDist)
	local shotCount = (wepStats.shotgun and wepStats.shotgunPellets) or 1
	repeat
		shotCount -= 1
		local bulletOrigin, bulletDirection
		local tempSpread = wepStats.spread * 100
		local spreadCFrame = CFrame.Angles(math.rad(math.random(-tempSpread, tempSpread) / 100), math.rad(math.random(-tempSpread, tempSpread) / 100), 0)
		if firstPerson then
			bulletOrigin = curModel.Grip.Muzzle.WorldCFrame.Position
			bulletDirection = (curModel.Grip.Muzzle.WorldCFrame * spreadCFrame).LookVector
		else
			local muzzle = weaponRig.Weapon:FindFirstChildWhichIsA("Model").Grip.Muzzle
			local muzzlePosition = muzzle.WorldCFrame.Position
			local muzzleDirection = muzzle.WorldCFrame.LookVector
			local rayOrigin = muzzlePosition + (muzzleDirection * -3)
			local rayResult = workspace:Raycast(rayOrigin, muzzleDirection * 3, rayParams)
			bulletOrigin = rayResult and (rayResult.Position + muzzleDirection * -0.1) or muzzle.WorldCFrame.Position
			bulletDirection = (muzzle.WorldCFrame * spreadCFrame).LookVector
		end
		local bulletVelocity = bulletDirection * wepStats.muzzleVelocity * config.meterMultiplier
		local tracerColor = (wepStats.tracers and gunAmmo.MagAmmo.Value % wepStats.tracerTiming == 0) and wepStats.tracerColor or nil
		mods.bulletHandler.FireBullet(weaponRig,bulletOrigin,bulletDirection,bulletVelocity,equipped,player,tracerColor)
	until shotCount <= 0
	net.playerFire:Fire(curModel.Grip.Muzzle.WorldCFrame)
	local cycleTime = (flags.curFireMode == fireModes.Burst and wepStats.burstFireRate) or wepStats.fireRate
	if gunModel and wepStats.projectile ~= "Bullet" and gunModel:FindFirstChild(wepStats.projectile) then
		local projectile = gunModel:FindFirstChild(wepStats.projectile)
		projectile.LocalTransparencyModifier = 1
		for _, child in ipairs(projectile:GetDescendants()) do
			if child:IsA("BasePart") then child.LocalTransparencyModifier = 1 end
		end
	end
	task.wait(60 / cycleTime)
	if not equipped then return end
	if wepStats.autoChamber and flags.curFireMode == fireModes.Manual and not flags.reloading then ChamberAnim() end
	flags.cycled = true
end

svc.runService.Heartbeat:Connect(function(dt:number)
	-- Drive the sprint animation sequence (speed-scaled loop + deferred end).
	if sprintAnimState ~= 0 then UpdateSprintAnim(dt) end
	if equipped and not flags.dead and flags.holdingM1 and flags.cycled and not flags.sprinting and not sprintAnimActive and not flags.reloading and not flags.unequipping and sphReady.state == 0 and not sphReady.busy then
		if flags.canFire and not blocked and IsLoaded() and flags.curFireMode > 0
			and (config.fireWithFreelook or (not config.fireWithFreelook and not freeLook))
			and not flags.equipping and not flags.fireDelayActive then
			if proneMoveAnim and proneMoveAnim.IsPlaying then return end
			if not firstPerson and not config.thirdPersonFiring then return end

			-- =====================
			-- FIRE DELAY (e.g. revolver hammer cock)
			-- wepStats.fireDelay: number (seconds) -- delay before the shot fires
			-- wepStats.fireDelayAnim: string (optional) -- animation to play during the delay
			-- wepStats.fireDelaySound: string (optional) -- sound to play when the delay starts
			-- If fireDelay is nil or 0, fires instantly as before.
			-- =====================
			local delay = wepStats.fireDelay or 0
			if delay > 0 then
				flags.fireDelayActive = true
				-- Capture which tool we started the delay with
				local delayEquipped = equipped
				-- Play optional pre-fire animation (e.g. hammer pull)
				if wepStats.fireDelayAnim then
					PlayAnimation(wepStats.fireDelayAnim, {priority = Enum.AnimationPriority.Action2, looped = false})
				end
				-- Play optional pre-fire sound (e.g. hammer click)
				if wepStats.fireDelaySound then
					PlayRepSound(wepStats.fireDelaySound)
				end
				task.spawn(function()
					task.wait(delay)
					-- After the delay, validate that we should still fire:
					-- same weapon, still alive, didn't release trigger, didn't sprint/reload/etc
					if equipped == delayEquipped and not flags.dead and flags.holdingM1
						and not flags.sprinting and not sprintAnimActive and not flags.reloading and not flags.unequipping
						and not blocked and IsLoaded() then
						ExecuteFire()
					else
						-- Delay was cancelled -- reset so the player can try again
						if wepStats.fireDelayAnim then
							StopAnimation(wepStats.fireDelayAnim, 0.15)
						end
					end
					flags.fireDelayActive = false
				end)
			else
				-- No delay -- fire immediately (original behavior)
				ExecuteFire()
			end
		elseif not IsLoaded() then
			-- Ran dry while the trigger is still held (e.g. holding full-auto until empty).
			-- Play a one-shot "out of ammo" cue so the player hears the gun go dry.
			-- bulletsCurrentlyFired > 0 ensures we actually shot this trigger hold (not just
			-- pulling the trigger on an already-empty gun, which TriggerPull already covers).
			if flags.holdingM1 and flags.bulletsCurrentlyFired > 0 and not flags.playedDryCue then
				flags.playedDryCue = true
				local dryName = wepStats.dryFireSound or "LastRound"
				if gunModel.Grip:FindFirstChild(dryName) then
					PlayRepSound(dryName)
				elseif gunModel.Grip:FindFirstChild("Empty") then
					PlayRepSound("Empty")
				end
			end
			if flags.curFireMode == fireModes.Manual and gunAmmo.MagAmmo.Value > 0 and not flags.reloading and not flags.chambering then
				ChamberAnim()
				flags.holdingM1 = false
			elseif wepStats.emptyCloseBolt and not equipped.Chambered.Value and not equipped.BoltReady.Value and flags.bulletsCurrentlyFired == 0 then
				flags.holdingM1 = false
				net.repChamber:Fire()
				PlayRepSound("SlideRelease")
				MoveBolt(CFrame.new())
			end
		end
	end
end)

svc.runService.RenderStepped:Connect(function(dt:number)
	-- Clamp a huge frame delta instead of skipping the whole loop. A hard `return` here froze
	-- the viewmodel sway/bob on any stall frame -- most noticeably the hitch when the Esc menu
	-- opens -- and snapped it afterwards. Clamping keeps the springs/bob integrating smoothly
	-- through a lag spike while still bounding dt so they can't explode. (Note: while the menu
	-- is open Roblox forces humanoid.MoveDirection to 0, so movement-driven sway will still
	-- wind down -- that part is engine behaviour, not this script.)
	dt = math.min(dt, 0.1)

	-- ===== 2D SCOPE =====
	-- Driven first in the frame so the iris, the viewmodel hide and the magnification all
	-- land together: the viewmodel update and the FOV smoother further down both read the
	-- blend this call produces. A sight with no wepStats.scopes entry stays a normal 1x
	-- optic and this is a no-op for it.
	if equipped and gunModel and wepStats then
		-- Magnifier swing. Driven before the scope so the sight index it resolves below is
		-- this frame's, not last frame's. Cheap no-op once the swing has settled.
		springs.magnifier.Update(dt)
		springs.scope.Update(dt, {
			aiming      = aiming,
			gunModel    = gunModel,
			rig         = rig,
			-- With the magnifier back in line this becomes its magnified scopes[] entry
			-- (wepStats.magnifier.scopeIndex), and only once it's most of the way home --
			-- so the 2D view can't punch in while the glass is still swinging.
			sightIndex  = springs.magnifier.ResolveSightIndex(sightIndex),
			aimInTime   = wepStats.aimInTime or config.aimInTime or 0.3,
			aimOutTime  = wepStats.aimOutTime or config.aimOutTime or 0.25,
			firstPerson = firstPerson,
			nvActive    = player:GetAttribute("NightVisionActive") == true,
			-- Canting rolls onto the offset backup sight, so the 2D view irises out with it.
			cantBlend   = springs.cantBlend,
			-- Working the bolt KEEPS the scope up (ChamberAnim sets `reloading` too, hence
			-- the `and not chambering`) -- dropping it mid-stroke just puts a giant opaque
			-- viewmodel scope in your face. A real magazine reload still drops it.
			cycling     = flags.chambering,
			-- Horizontal speed, so the scope can damp the eye box while you're moving:
			-- walk bob isn't your eye actually leaving the glass.
			moveSpeed   = (humanoidRootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude,
			blocked     = blocked or flags.sprinting or (flags.reloading and not flags.chambering) or flags.inspecting or flags.meleeing,
		})
		-- Published for CameraBobAndFallSway, which fades the ADS camera cant out by this
		-- amount -- a rolled camera would spin the scope picture under a reticle that
		-- doesn't roll with it.
		character:SetAttribute("SPH_ScopeBlend", springs.scope.GetBlend())
	else
		if springs.scope.IsActive() then
			springs.scope.Clear()
			character:SetAttribute("SPH_ScopeBlend", 0)
		end
		-- Nothing equipped: drop the magnifier drive so it can't keep a dead gun's joints.
		if springs.magnifier.Has() then springs.magnifier.Clear() end
	end

	-- Shoulder back in after a bolt cycle that dropped the aim. `reloading` is held up by
	-- the bolt animation and cleared on its SlideRelease/BoltClose keyframe, so this waits
	-- for BOTH that and the anim itself rather than firing the instant the stroke ends.
	-- The window simply expires if something else takes over, so it can never re-aim you
	-- at a random later moment.
	if springs.reaimChamber > 0 then
		springs.reaimChamber -= dt
		if not flags.chambering and not flags.reloading then
			springs.reaimChamber = 0
			if flags.aimHeld and not aiming and equipped and firstPerson and not flags.dead
				and not flags.sprinting and not sprintAnimActive and not blocked
				and not flags.inspecting and not flags.meleeing then
				ToggleAiming(true)
			end
		end
	end

	-- Publish whether the first-person viewmodel is currently on screen. FirstPersonVisibility
	-- reads this so it keeps the REAL character arms hidden for as long as the viewmodel arms
	-- are showing -- including the whole unequip animation, where the tool has already left the
	-- character (so it looks like no gun is equipped) but the viewmodel is still animating off.
	-- Without this you briefly see both the real arms and the viewmodel arms at once.
	character:SetAttribute("SPH_ViewmodelActive", flags.viewmodelVisible)

	flags.moving = humanoid.MoveDirection.Magnitude > 0

	-- Keep mouse locked in third person when gun is equipped.
	-- Never in a helicopter: the pilot steers with a free cursor, and locking it
	-- to centre would peg the aim point to the middle of the screen.
	if not firstPerson and equipped and not flags.dead
		and player:GetAttribute("InHelicopterSeat") ~= true then
		if svc.userInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			svc.userInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
	end

	-- Reloading attribute is now set explicitly in ReloadAnim and on reload end.

	if proneMoveAnim and character:GetAttribute("Stance") == "Prone" and equipped and humanoid.FloorMaterial ~= Enum.Material.Air then
		if flags.moving and not proneMoveAnim.IsPlaying then
			PlayAnimation(wepStats.proneMoveAnim, {transSpeed = 0.5})
		elseif not flags.moving and proneMoveAnim.IsPlaying then
			StopAnimation(wepStats.proneMoveAnim, 0.5)
		end
	elseif proneMoveAnim and proneMoveAnim.IsPlaying then
		StopAnimation(wepStats.proneMoveAnim, 0.5)
	end

	if walkMoveAnim and equipped and character:GetAttribute("Stance") == "Standing" and not flags.sprinting and not aiming and humanoid.FloorMaterial ~= Enum.Material.Air then
		if flags.moving and not walkMoveAnim.IsPlaying then
			PlayAnimation(wepStats.walkAnim, {transSpeed = 0.3})
		elseif not flags.moving and walkMoveAnim.IsPlaying then
			StopAnimation(wepStats.walkAnim, 0.3)
		end
	elseif walkMoveAnim and walkMoveAnim.IsPlaying then
		StopAnimation(wepStats.walkAnim, 0.3)
	end

	cam.headRotationEventCooldown -= dt

	-- Skipped in the helicopter pilot seat: HeliCamera owns the camera there, and
	-- this clamp rewrites camera.CFrame every frame, which would fight it.
	if (humanoid.Sit and not flags.vehicleSeated and firstPerson or freeLook) and config.cameraLimitInSeats
		and player:GetAttribute("InHelicopterSeat") ~= true then
		local cameraCFrame = humanoidRootPart.CFrame:ToObjectSpace(camera.CFrame)
		local x, y, z = cameraCFrame:ToOrientation()
		local a = camera.CFrame.Position.X
		local b = camera.CFrame.Position.Y
		local c = camera.CFrame.Position.Z
		local xlimit = math.rad(math.clamp(math.deg(x),-60,60))
		local ylimit = math.rad(math.clamp(math.deg(y),-60,60))
		local zlimit = math.rad(math.clamp(math.deg(z),-60,60))
		local limitedCFrame = humanoidRootPart.CFrame:ToWorldSpace(CFrame.new(a,b,c) * CFrame.fromOrientation(xlimit,ylimit,zlimit))
		camera.CFrame = CFrame.new(camera.CFrame.Position) * (limitedCFrame - limitedCFrame.Position)
	end

	if not flags.dead and character:FindFirstChild("Head") then
		if not flags.dead then
			-- === MOUSE-AIMED HEAD ===
			-- Aim the neck at whatever the cursor is over instead of straight down the
			-- camera. A locked cursor (first person / aiming) already sits at the camera
			-- centre, so in that case we leave it on the camera and nothing changes.
			-- Kept inline (not a helper function) because this script is at Luau's
			-- 200-local limit at the top level.
			local lookDirection = camera.CFrame
			if svc.userInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
				local mousePos = svc.userInputService:GetMouseLocation() -- excludes the topbar inset
				local screenRay = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
				-- Fixed distance down the mouse ray -- deliberately NOT a raycast. Aiming at the
				-- real hit point means the head swings whenever the cursor crosses an edge (a
				-- near wall and the sky behind it are metres apart on screen but hundreds of
				-- studs apart in the world), which is the snapping. A constant depth keeps the
				-- head pointing where the cursor points, smoothly, whatever is under it.
				local targetPos = screenRay.Origin + screenRay.Direction * 250
				if springs.headAimPoint then
					springs.headAimPoint = springs.headAimPoint:Lerp(targetPos, 1 - math.exp(-14 * dt)) -- 14 = snappy, lower = floatier
				else
					springs.headAimPoint = targetPos
				end
				local headOrigin = character.Head.Position
				if (springs.headAimPoint - headOrigin).Magnitude >= 1 then
					lookDirection = CFrame.lookAt(headOrigin, springs.headAimPoint)
				end
			else
				springs.headAimPoint = nil -- re-seed on the next unlocked frame, no swing
			end
			if not config.headRotation and not firstPerson then
				lookDirection = humanoidRootPart.CFrame
			end
			local cameraDirection = humanoidRootPart.CFrame:ToObjectSpace(lookDirection).LookVector
			-- Pure free-look pitch. The torso-pitch compensation term that used to be added
			-- here (+ math.asin(torsoDirection.Y)) is gone: the animations already level the
			-- head, so adding it again double-counted and fought the pose.
			local verticalAngle = -math.asin(lookDirection.LookVector.Y)
			-- Cap the up/down tilt. Straight up or down is ~90 deg, which snaps the neck.
			-- Same 50 in every stance -- prone no longer gets its own tighter 20.
			verticalAngle = math.clamp(verticalAngle, -math.rad(50), math.rad(50))
			-- atan2 keeps the same sign as the old math.asin(X) for forward looks but stays
			-- valid when the cursor is beside/behind you.
			local yaw = math.atan2(cameraDirection.X, -cameraDirection.Z)
			-- Past 90 degrees, fold the angle back toward the front. Without this the yaw
			-- just pins at the clamp, so once the cursor is behind you a tiny move across
			-- the centre flips it from full-left to full-right. Folded, the neck eases back
			-- to centre as the target passes behind and there's no jump anywhere.
			if math.abs(yaw) > math.pi / 2 then
				yaw = (yaw >= 0 and 1 or -1) * (math.pi - math.abs(yaw))
			end
			yaw = math.clamp(yaw, -math.rad(70), math.rad(70))
			local rotationCFrame = CFrame.Angles(0, yaw/1.15, 0) * CFrame.Angles(verticalAngle, 0, 0)
			local neckCFrame = CFrame.new(0, -.5, 0) * rotationCFrame * CFrame.Angles(-math.rad(90), 0, math.rad(180))
			neckJoint.C1 = neckJoint.C1:Lerp(neckCFrame, 1 - math.exp(-config.headRotationSpeed * 0.6 * dt))
			if cam.headRotationEventCooldown <= 0 and not flags.dead and not config.disableHeadRotation then
				cam.headRotationEventCooldown = config.headRotationEventRate
				net.bodyAnimRequest:Fire(neckJoint.C1)
			end
		end

		if config.firstPersonBody and firstPerson then
			local xHead = character.HumanoidRootPart.CFrame:ToObjectSpace(camera.CFrame):ToEulerAngles()
			local rotationOffset = -1.2 + (xHead + 1.4) / 2.8
			cam.cameraOffsetTarget = Vector3.new(0,0,rotationOffset)
		else
			cam.cameraOffsetTarget = Vector3.zero
		end

		local xOffset = 0
		local yOffset = 0
		local zOffset = cam.cameraOffsetTarget.Z

		if character:GetAttribute("Stance") == "Crouched" then
			yOffset = -1
			if firstPerson then zOffset -= 0.3 end
		elseif character:GetAttribute("Stance") == "Prone" then
			yOffset = -2.8
			if firstPerson then zOffset = -2.2 end
		end

		-- Jump wind-up camera dip (sustained hold)
		local jumpDipTarget = 0
		if character:GetAttribute("JumpWindingUp") then
			jumpDipTarget = JUMP_CAM_DIP
		end
		cam.jumpCamY = cam.jumpCamY + (jumpDipTarget - cam.jumpCamY) * math.min(1, (if jumpDipTarget ~= 0 then 0.15 else 0.3) * dt * 60)
		if math.abs(cam.jumpCamY) < 0.005 then cam.jumpCamY = 0 end
		yOffset = yOffset + cam.jumpCamY

		-- Landing camera punch (one-shot spring impulse)
		local landingNow = character:GetAttribute("LandingLocked") == true
		if landingNow and not cam.wasLandingLocked then
			cam.landingCamSpring:shove(Vector3.new(0, -0.6, 0))
		end
		cam.wasLandingLocked = landingNow
		local landingBounce = cam.landingCamSpring:update(dt)
		yOffset = yOffset + landingBounce.Y
		local lean = character:GetAttribute("LeanDirection") or 0
		-- Spring the lean: ease out and settle with a slight bounce (matches the sway).
		-- One spring drives the lateral offset, the dip, and the camera roll below.
		springs.lean.t = Vector3.new(lean, 0, 0)
		local leanP = springs.lean.p.X
		xOffset = leanP
		yOffset += -0.2 * math.abs(leanP)

		-- Pull Z from actual head position so sprint lean feels right.
		-- Ease the offset out slowly while still moving (decel), fast when fully stopped.
		if firstPerson and flags.sprinting and head and head.Parent then
			local headRelative = humanoidRootPart.CFrame:PointToObjectSpace(head.Position)
			cam.sprintCamZ = headRelative.Z * 0.56
		else
			if math.abs(cam.sprintCamZ) > 0.01 then
				local vel = humanoidRootPart.AssemblyLinearVelocity
				local xzSpeed = Vector2.new(vel.X, vel.Z).Magnitude
				-- Fast return when stopped, slow ease-out when decelerating
				local returnRate = if xzSpeed > 1 then 0.025 else 0.15
				cam.sprintCamZ = cam.sprintCamZ * (1 - returnRate * dt * 60)
				if math.abs(cam.sprintCamZ) < 0.01 then cam.sprintCamZ = 0 end
			end
		end
		zOffset = zOffset + cam.sprintCamZ

		if not flags.vehicleSeated and camera.CameraType == Enum.CameraType.Custom then
			cam.cameraOffsetTarget = Vector3.new(xOffset,yOffset,zOffset)
			humanoid.CameraOffset = humanoid.CameraOffset:Lerp(cam.cameraOffsetTarget, (proneToCrouchTransition and 0.03 or 0.1) * dt * 60)
			-- NOTE: the body lean (rootJoint.C1) is now owned by MovementBanking.luau,
			-- which composes the tactical lean and the movement banking into a SINGLE C1
			-- write so the two no longer fight. This block only drives the CAMERA: the
			-- offset above and the camera roll below.
			cam.cameraLeanRotation = 15 * -leanP
			camera.CFrame *= CFrame.Angles(0,0,math.rad(cam.cameraLeanRotation))

			-- Apply FakeCamera shake from animations (high-pass filter)
			if fakeCameraMotor then
				local transform = fakeCameraMotor.Transform
				local rx, ry, rz = transform:ToEulerAnglesXYZ()
				local current = Vector3.new(rx, ry, rz)
				-- Smoothed value chases the actual value
				cam.fakeCameraSmoothed = cam.fakeCameraSmoothed:Lerp(current, 0.85 * dt * 60)
				-- Only the difference (the sharp/snappy part) hits the camera
				local shake = current - cam.fakeCameraSmoothed
				camera.CFrame *= CFrame.Angles(shake.X * 0.3, shake.Y, shake.Z)
			end
		end

		if equipped and camera.CameraType == Enum.CameraType.Custom then
			if firstPerson and not flags.viewmodelVisible then
				RefreshViewmodel()
				ToggleSprint(character:GetAttribute("HoldingSprint"))
			end
			UpdateViewmodelPosition(dt)
		elseif flags.viewmodelVisible and not flags.equipping then
			flags.viewmodelVisible = false
		end

		local walkSpeed = math.floor(humanoid.WalkSpeed)
		local cfgWalk = math.max(config.walkSpeed, 1)
		local speedRatio = walkSpeed / cfgWalk
		-- Dampening (kept from original: bigger value = smaller bob).
		local tempDampening = config.bobDampening
		local difference = tempDampening - (tempDampening / (speedRatio ~= 0 and speedRatio or 1))
		difference /= 2
		tempDampening -= difference
		if aiming then tempDampening *= config.aimBobDampening end

		local linVel = humanoidRootPart.AssemblyLinearVelocity
		local flatSpeed = Vector2.new(linVel.X, linVel.Z).Magnitude
		local grounded = (not humanoid.Sit) and humanoid.FloorMaterial ~= Enum.Material.Air
		local bob = springs.bobState

		-- Smooth sprint blend (0..1): eases the cadence AND the size between walk and
		-- sprint so nothing snaps the moment the sprint key toggles.
		bob.sprintBlend += ((flags.sprinting and 1 or 0) - bob.sprintBlend) * math.clamp(5 * dt, 0, 1)

		-- Frequency scales with speed. At/below walk it tracks speed (so ADS/crouch-slowed
		-- walking bobs slower). At walk (speedRatio 1, sprintBlend 0) this is exactly
		-- config.bobSpeed. As you ramp INTO sprint, the cadence blends up toward
		-- config.sprintBobSpeedMultiplier (>1 = faster steps) via sprintBlend so it eases in.
		local freqRatio = math.min(speedRatio, 1) + math.max(speedRatio - 1, 0) * -0.05
		local sprintFreqMult = 1 + ((config.sprintBobSpeedMultiplier or 1.5) - 1) * bob.sprintBlend
		local tempBobSpeed = config.bobSpeed * freqRatio * sprintFreqMult

		-- Amplitude tracks ground speed and eases in/out as you accel/decel. ABOVE walk
		-- it's compressed (0.3) so sprint only bobs a little bigger than walk, not a lot.
		local speedFrac = flatSpeed / cfgWalk
		local ampFrac = math.min(speedFrac, 1) + math.max(speedFrac - 1, 0) * 0.3
		local targetAmp = (grounded and flags.moving) and math.clamp(ampFrac, 0, 1.6) or 0
		bob.amp += (targetAmp - bob.amp) * math.clamp(5 * dt, 0, 1)
		-- Integrate phase over time: never snaps when WalkSpeed changes (sprint/ADS).
		bob.phase += tempBobSpeed * 0.65 * dt
		local p = bob.phase

		-- Figure-8 (Lissajous): vertical bobs at 2x the horizontal rate. Sprint pumps the
		-- whole bob bigger AND widens the side-to-side sway so it's a real figure-8, not
		-- just up/down. Everything keyed to sprintBlend so WALK stays exactly as it was.
		local bobScale = (0.3 / tempDampening) * bob.amp
		local sideScale = 0.55 + bob.sprintBlend * 0.55 -- more side-to-side when sprinting
		local bobX = math.sin(p) * bobScale * sideScale -- side to side
		local bobY = math.sin(p * 2) * bobScale * 1.15  -- up/down, double frequency
		springs.move:shove(Vector3.new(bobY, bobX, bobX) * dt * 60)
		local updatedMoveSway = springs.move:update(dt)
		-- Stride rotation. Walk keeps the original (pitch Y*0.3, roll Y*0.5). The extra
		-- nose-pitch and yaw only fade in while sprinting, and roll-per-side eases down so
		-- the wider side sway doesn't over-roll the gun.
		local strideRoll = 0.5 * (1 - bob.sprintBlend * 0.45)
		animBase.CFrame = animBase.CFrame:ToWorldSpace(CFrame.new(updatedMoveSway.Y, updatedMoveSway.X, 0)
			* CFrame.Angles(updatedMoveSway.Y * 0.3 + updatedMoveSway.X * 0.6 * bob.sprintBlend, 0, updatedMoveSway.Y * strideRoll))

		-- Movement inertia: the gun lags behind velocity changes, then drifts and rolls
		-- into the momentum with a little overshoot. Strafe is clamped so high sprint
		-- speeds can't over-roll the viewmodel.
		local relVel = humanoidRootPart.CFrame:VectorToObjectSpace(linVel)
		-- Smooth the input velocity first, so an instant A<->D reversal RAMPS the spring
		-- target across instead of teleporting it in one frame (which reads as a snap).
		bob.velSmooth = bob.velSmooth:Lerp(relVel, math.clamp(10 * dt, 0, 1))
		local inertiaScale = aiming and 0.25 or 1 -- subtle residual sway while aiming
		-- WEIGHT: feed the *change* in velocity (acceleration) back into the spring as a
		-- one-frame impulse. Starting, stopping or reversing direction now KICKS the gun,
		-- which then swings and recovers (springs.inertia is underdamped, d=0.42, so it
		-- overshoots once and settles) instead of only sliding to a steady lean. This is
		-- the Tarkov/Squad "the gun has mass and has to catch up" feel.
		-- Tuning: config.inertiaImpulse (0 = old behaviour), config.inertiaMaxImpulse (clamp).
		do
			local gain = config.inertiaImpulse or 0.35
			if gain > 0 then
				local accel = (bob.velSmooth - bob.prevVel) / cfgWalk -- gun-space, walk-normalised
				local maxI = config.inertiaMaxImpulse or 1.5
				-- negative: the gun lags OPPOSITE the way the body accelerates
				springs.inertia:accelerate(Vector3.new(
					-math.clamp(accel.X * gain * inertiaScale, -maxI, maxI),
					-math.clamp(accel.Y * gain * inertiaScale, -maxI, maxI),
					-math.clamp(accel.Z * gain * inertiaScale, -maxI, maxI)
					))
			end
		end
		bob.prevVel = bob.velSmooth
		-- Landing dip (gun) + FOV punch on land, and a FOV narrow on jump. The gun dip
		-- springs back; the FOV kick decays in the unified FOV smoother below.
		-- Tuning: config.landingInertiaDip / landingDipMinFall, config.landFOVKick / jumpFOVKick.
		if grounded and not bob.wasGrounded then
			local fallSpeed = -linVel.Y -- positive while moving downward
			local impact = math.clamp(fallSpeed / 50, 0, 1)
			local dipAmt = config.landingInertiaDip or 0.5
			if dipAmt > 0 and fallSpeed > (config.landingDipMinFall or 4) then
				-- +Y velocity -> iv.Y goes positive -> -iv.Y below pushes the gun DOWN, then recovers
				springs.inertia:accelerate(Vector3.new(0, impact * dipAmt * 6, 0))
			end
			springs.fovKickVal = (config.landFOVKick or 5) * impact -- quick FOV widen on impact
		elseif (not grounded) and bob.wasGrounded then
			springs.fovKickVal = config.jumpFOVKick or -4 -- quick FOV narrow when leaving the ground
		end
		bob.wasGrounded = grounded
		springs.inertia.t = bob.velSmooth / cfgWalk * inertiaScale
		local iv = springs.inertia.p
		local strafe = math.clamp(iv.X, -1.0, 1.0) -- cap the side lean at sprint speeds
		-- Pure roll into strafes (a clean sideways tilt, like leaning -- NO yaw twist),
		-- plus a small forward/back nod on accel/decel and a positional drift.
		animBase.CFrame *= CFrame.new(-strafe * 0.12, -iv.Y * 0.05, iv.Z * 0.05)
			* CFrame.Angles(math.rad(iv.Z * 0.6), 0, math.rad(-strafe * 7))

		-- IR laser is only visible to a viewer who has night vision on, and always shows a
		-- beam (even when config.laserTrail is off). A normal laser behaves as before.
		local viewerHasNV = player:GetAttribute("NightVisionActive") == true
		local laserShown = equipped and laser.enabled and (not laserIsIR or viewerHasNV)
		local laserWantsBeam = laserShown and (laserIsIR or config.laserTrail)
		if laserShown then
			-- Re-configure whenever mode / perspective / beam state changes (not only on the
			-- first frame), so switching to IR or toggling NV updates the view live.
			local key = (laserIsIR and "ir" or "n")..(firstPerson and "f" or "t")..(laserWantsBeam and "b" or "-")
			if not laser.visible or laser.configKey ~= key then
				laser.visible = true
				laser.configKey = key
				local laserColor = gunModel.Grip.Laser.Color.Value
				if laser.trailPart then laser.trailPart.Color = laserColor end
				if laser.dotLight then
					laser.dotLight.Color = laserColor
					-- IR dot light reaches further and burns brighter than a regular laser.
					laser.dotLight.Range = laserIsIR and 5 or 1.5
					laser.dotLight.Brightness = laserIsIR and 8 or 4
				end
				if laserTrail then laserTrail.Color = ColorSequence.new(laserColor) end
				SetLaserPart(gunModel, true, laserColor)
				SetLaserPart(GetThirdPersonGunModel(), true, laserColor)
				-- Attachment0 has to be set BEFORE styling, so the glow beam copies it.
				if laserWantsBeam and not firstPerson and not laser.beamTP.Attachment0 then
					laser.beamTP.Attachment0 = GetThirdPersonGunModel().Grip.Laser
				end
				springs.StyleBeam(laser.beamFP, springs.laserGlowFP, laserColor, laserIsIR)
				springs.StyleBeam(laser.beamTP, springs.laserGlowTP, laserColor, laserIsIR)
				laser.beamFP.Enabled = laserWantsBeam and firstPerson
				laser.beamTP.Enabled = laserWantsBeam and not firstPerson
				-- The halo only exists for IR, and only alongside its own beam.
				springs.laserGlowFP.Enabled = laserIsIR and laser.beamFP.Enabled
				springs.laserGlowTP.Enabled = laserIsIR and laser.beamTP.Enabled
			end
			local laserPoint:Attachment = firstPerson and gunModel.Grip.Laser or GetThirdPersonGunModel().Grip.Laser
			-- Built once and only rebuilt when the gun model actually changes, instead of
			-- allocating a fresh RaycastParams object on every single frame.
			local laserRayParams = springs.laserRayParams
			if not laserRayParams or springs.laserRayGun ~= gunModel then
				laserRayParams = RaycastParams.new()
				laserRayParams.FilterType = Enum.RaycastFilterType.Exclude
				laserRayParams.FilterDescendantsInstances = {gunModel, character}
				laserRayParams.RespectCanCollide = true
				springs.laserRayParams = laserRayParams
				springs.laserRayGun = gunModel
			end
			local rayResult = workspace:Raycast(laserPoint.WorldPosition, laserPoint.WorldCFrame.LookVector * 600, laserRayParams)
			laser.dotPoint.WorldPosition = rayResult and rayResult.Position or (laserPoint.WorldPosition + laserPoint.WorldCFrame.LookVector.Unit * 600)

			-- The neon sphere IS the dot: sit it on the surface (with the trail streaking
			-- behind), or park it out of sight when the laser isn't hitting anything.
			if laser.trailPart then
				if rayResult then
					laser.trailPart.Position = rayResult.Position + rayResult.Normal * 0.03 -- lift off the surface so it doesn't z-fight
					if laserTrail and not laserTrail.Enabled then
						laserTrail:Clear() -- don't streak from the parked storage position
						laserTrail.Enabled = true
					end
				else
					laser.trailPart.CFrame = LASER_STORAGE_CF
					if laserTrail and laserTrail.Enabled then
						laserTrail.Enabled = false
						laserTrail:Clear()
					end
				end
			end
		elseif laser.visible then
			laser.visible = false
			laser.configKey = nil
			laser.beamFP.Enabled = false
			laser.beamTP.Enabled = false
			springs.laserGlowFP.Enabled = false
			springs.laserGlowTP.Enabled = false
			if laser.trailPart then laser.trailPart.CFrame = LASER_STORAGE_CF end
			if laserTrail then
				laserTrail.Enabled = false
				laserTrail:Clear()
			end
			SetLaserPart(gunModel, false)
			SetLaserPart(GetThirdPersonGunModel(), false)
		end

		-- Flashlight / IR illuminator: re-push the light state whenever the mode, the
		-- perspective or THIS viewer's night vision changes. The IR illuminator (and its
		-- emitter glow) only exists for a viewer wearing NVGs, so toggling night vision
		-- has to make it appear/disappear live -- same as the IR laser above.
		local flashKey = (laser.flashlightEnabled and (springs.flash.isIR and "ir" or "n") or "off")
			..(firstPerson and "f" or "t")..(viewerHasNV and "v" or "-")
		if springs.flash.configKey ~= flashKey then
			springs.flash.configKey = flashKey
			springs.flash.Refresh()
		end

		for _, sight:BasePart in ipairs(sights) do
			local frame = sight.SurfaceGui.Frame
			local sightUI = frame:FindFirstChild("Reticle") or frame:FindFirstChild("Holo")
			-- Parallax offset: how far off the optic's axis your eye is, scaled by strength
			-- (per-optic ReticleParallax attribute, else config; 0 = locked dead-center).
			local off = (sight.CFrame:PointToObjectSpace(camera.CFrame.Position) / sight.Size)
				* (sight:GetAttribute("ReticleParallax") or config.reticleParallax or 1)
			local mag = Vector2.new(off.X, off.Y).Magnitude
			-- Clamp so the reticle can't drift past the glass rim.
			local clampR = sight:GetAttribute("ReticleClampRadius") or config.reticleClampRadius or 0.5
			local scale = (clampR > 0 and mag > clampR) and (clampR / mag) or 1
			sightUI.Position = UDim2.fromScale(0.5 + off.X * scale, 0.5 - off.Y * scale)
			-- Eye-box fade: the reticle fades/vanishes as your eye leaves the optic's axis, so a
			-- swaying gun doesn't leave a reticle stuck at the lens edge or floating off the optic.
			local fs = sight:GetAttribute("ReticleFadeStart") or config.reticleFadeStart or 0.32
			local fe = sight:GetAttribute("ReticleFadeEnd") or config.reticleFadeEnd or 0.5
			local vis = (fe > fs) and (1 - math.clamp((mag - fs) / (fe - fs), 0, 1)) or 1
			if sightUI:IsA("ImageLabel") or sightUI:IsA("ImageButton") then
				sightUI.ImageTransparency = 1 - vis -- assumes an opaque reticle image
			end
			-- The world-space 1x reticle is redundant (and doubles up) once the 2D scope
			-- view has taken over, so it's hidden while that's on screen.
			sightUI.Visible = (vis > 0.001) and not springs.scope.IsFull()
			if sightUI.Name == "Holo" then
				sightUI.Size = UDim2.fromScale(camera.FieldOfView / 70, camera.FieldOfView / 70)
			end
		end

		-- ===== Unified FOV smoother =====
		-- One frame-rate-independent smoothing for every fov change so nothing snaps:
		-- aim in/out (base = aimFOVTarget vs defaultFOV), sprint widen, and jump/land kick.
		if equipped then
			-- Sprint widen, only while not aiming and on the ground; eased in/out.
			local sprintTarget = (flags.sprinting and not aiming and grounded) and (config.sprintFOVAdd or 8) or 0
			springs.fovSprintCur += (sprintTarget - springs.fovSprintCur) * math.clamp((config.sprintFOVSpeed or 6) * dt, 0, 1)
			-- Jump/land kick decays back to 0.
			springs.fovKickVal *= math.clamp(1 - (config.fovKickDecay or 6) * dt, 0, 1)
			-- Base FOV. Normally: aim FOV while aiming, else the default hipfire FOV.
			-- With night vision ON, the base is pinned to the NV FOV whether hipfiring
			-- OR aiming (NVGs give no magnification) -- so aiming through the NVAimPart
			-- stays at NV FOV. Sprint widen, jump/land, and the per-shot FOV kick below
			-- still stack on top, so everything else stays compatible.
			local nvActive = player:GetAttribute("NightVisionActive") == true
			local baseFOV
			if nvActive then
				baseFOV = player:GetAttribute("NightVisionFOV") or defaultFOV
			else
				baseFOV = aiming and cam.aimFOVTarget or defaultFOV
			end
			-- 2D scope: eases from the normal aim FOV to the true magnified FOV as the iris
			-- closes. Returns baseFOV untouched for a 1x sight, so nothing else changes.
			baseFOV = springs.scope.GetFOV(baseFOV)
			local targetFOV = baseFOV + springs.fovSprintCur + springs.fovKickVal + springs.fovShoot:update(dt).X
			-- Use a capped dt for the FOV smoothing so a lag spike -- most notably the frame hitch
			-- when a gun is equipped and its model + animations load -- can't drive the lerp factor
			-- to 1 and SNAP the FOV across the whole gap (e.g. 55 -> defaultFOV). On frames slower
			-- than 60fps this eases a touch slower instead of jumping.
			local fovDt = math.min(dt, 1/60)
			if nvActive ~= springs.nvFovPrev then
				-- Night vision was just toggled: SNAP the FOV instantly (the goggles coming
				-- down/up shouldn't ease). Only this one change is unsmoothed -- aim, sprint
				-- and recoil FOV keep smoothing normally on every other frame.
				springs.nvFovPrev = nvActive
				camera.FieldOfView = targetFOV
			else
				-- Slightly quicker ease while a 2D scope is engaging so the magnification
				-- tracks the iris rather than trailing it. Kept close to the normal speed --
				-- pushing this high is what made the whole transition feel like a hard snap.
				local fovSmoothSpeed = springs.scope.IsActive() and 14 or (config.fovSmoothSpeed or 12)
				camera.FieldOfView += (targetFOV - camera.FieldOfView) * math.clamp(fovSmoothSpeed * fovDt, 0, 1)
			end
			-- Tracking speed scales with magnification, so 6x doesn't feel like whipping a
			-- hosepipe. Returns 1 for a 1x sight, leaving the old behaviour exactly as it was.
			if aiming then
				local wantSens = aimSensitivity * springs.scope.GetSensitivityScale()
				if math.abs(svc.userInputService.MouseDeltaSensitivity - wantSens) > 0.0005 then
					svc.userInputService.MouseDeltaSensitivity = wantSens
				end
			end
		end
	end

	if character:GetAttribute("Stance") == "Prone" and config.proneAngle then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {character}
		params.IgnoreWater = true
		params.RespectCanCollide = true
		local rayResult = workspace:Raycast(humanoidRootPart.Position, Vector3.new(0, -2, 0), params)
		if rayResult and rayResult.Instance then
			local rotateToFloorCFrame = GetRotationBetween(humanoidRootPart.CFrame.UpVector, rayResult.Normal, Vector3.new(1, 0, 0))
			rootJoint.C0 *= CFrame.Angles(rotateToFloorCFrame.X, 0, 0)
		end
	end
end)

svc.userInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
	if aiming then
		-- Variable-power 2D scope: HOLD CTRL and scroll to walk the magnification between
		-- magMin and magMax. Gated behind Ctrl so a bare scroll still does the normal aim
		-- sensitivity adjust, and so the wheel can't nudge your zoom mid-engagement.
		-- Returns false for a fixed-power scope or a 1x sight, which falls through to the
		-- original zoom/sensitivity handling below.
		if (springs.zoomKeyHeld
			or svc.userInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or svc.userInputService:IsKeyDown(Enum.KeyCode.RightControl))
			and springs.scope.AdjustZoom(input.Position.Z) then
			return
		end
		-- Aim zoom / sensitivity (first person ADS) -- unchanged
		if svc.userInputService:IsKeyDown(config.holdForScrollZoom) then
			local newFOV = cam.aimFOVTarget - input.Position.Z * 3
			cam.aimFOVTarget = math.clamp(newFOV, wepStats.aimFovMin, wepStats.aimFovMax or defaultFOV)
		else
			aimSensitivity = math.clamp(aimSensitivity - 0.01 * -input.Position.Z,0.005,1)
			svc.userInputService.MouseDeltaSensitivity = aimSensitivity
			player:SetAttribute("SavedAimSensitivity", aimSensitivity)
		end
		return
	end
	-- ===== READY STANCES (first person only): scroll down = high, scroll up = low =====
	if not equipped or not firstPerson then return end
	local dir = input.Position.Z -- +1 = scroll up, -1 = scroll down
	if sphReady.state == 0 then
		if sphReady.busy then return end
		-- Only enter from a clean idle
		if flags.sprinting or sprintAnimActive or flags.reloading or flags.equipping or flags.unequipping or flags.inspecting or flags.meleeing
			or flags.chambering or blocked or flags.dead or flags.vehicleSeated or springs.swimming or flags.fireModeSwitching or flags.holdingM1 or not flags.cycled then
			return
		end
		if dir < 0 then
			EnterReady(1) -- scroll down -> high ready
		elseif dir > 0 then
			EnterReady(2) -- scroll up -> low ready
		end
	else
		-- In a ready stance: opposite scroll plays the end anim back to idle
		if (sphReady.state == 1 and dir > 0) or (sphReady.state == 2 and dir < 0) then
			ExitReady()
		end
	end
end)

-- Deep water force-holsters the gun. The attribute is driven by SwimController
-- (locally for an instant response, then by the server so it replicates).
-- humanoid:UnequipTools() sends the tool to the Backpack, which trips the
-- character.ChildRemoved handler above -- that is what runs UnequipAnim + Unequip.
character:GetAttributeChangedSignal("Swimming"):Connect(function()
	local nowSwimming = character:GetAttribute("Swimming") == true
	if nowSwimming == springs.swimming then return end
	springs.swimming = nowSwimming
	if springs.swimming and equipped then
		humanoid:UnequipTools()
	end
end)

humanoid.Seated:Connect(function(seated, seatPart)
	if seated then
		if seatPart:IsA("VehicleSeat") and not config.canEquipInVehicleSeat then
			flags.vehicleSeated = true
			if equipped then humanoid:UnequipTools() end
		else
			flags.vehicleSeated = false
		end
	else
		flags.vehicleSeated = false
	end
end)

flags.canJump = true
character:SetAttribute("ClientCanJump", flags.canJump)

svc.userInputService.JumpRequest:Connect(function()
	if humanoid.Sit then
		character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	elseif character:GetAttribute("Stance") == "Standing" then
		if character.Humanoid.FloorMaterial == Enum.Material.Air then return end
		if flags.canJump then
			flags.canJump = false
			character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			task.wait(config.jumpCooldown)
			flags.canJump = true
		else
			character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end
	else
		character.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end
	character:SetAttribute("ClientCanJump", flags.canJump)
end)

character:GetAttributeChangedSignal("Stance"):Connect(function()
	local newStance = character:GetAttribute("Stance")
	if previousStance == "Prone" and newStance == "Crouched" then
		proneToCrouchTransition = true
		task.delay(0.5, function()
			proneToCrouchTransition = false
		end)
	end

	-- Prone enter (-> Prone) / exit (Prone ->) gun overlay. Non-blocking: we just fire off
	-- the anim; aiming and firing carry on straight through it. NOT gated on perspective --
	-- PlayAnimation plays both the first-person (viewmodel) and third-person (character
	-- animator, which replicates to other players) tracks, so it shows in both views.
	local enteringProne = newStance == "Prone" and previousStance ~= "Prone"
	local exitingProne = previousStance == "Prone" and newStance ~= "Prone"
	if (enteringProne or exitingProne) and equipped and wepStats and not flags.dead then
		sphReady.PlayStanceTransition(enteringProne and wepStats.proneEnterAnim or wepStats.proneExitAnim)
	end

	previousStance = newStance
end)

character:GetAttributeChangedSignal("Sprinting"):Connect(function()
	flags.sprinting = character:GetAttribute("Sprinting")
	if flags.sprinting and equipped then ToggleSprint(true) else ToggleSprint(false) end
end)

toggleViewmodelSprint.Event:Connect(function(toggle)
	ToggleSprint(toggle)
	flags.sprinting = toggle
	if not toggle then flags.aimHeld = false end
end)

for _, part in svc.collectionService:GetTagged("SPH_NoCollide") do
	if part:IsA("BasePart") then
		table.insert(rayParams.FilterDescendantsInstances, part)
	end
end

svc.collectionService:GetInstanceAddedSignal("SPH_NoCollide"):Connect(function(newInstance)
	if newInstance:IsA("BasePart") then
		table.insert(rayParams.FilterDescendantsInstances, newInstance)
	end
end)

flags.lastAirborne = 0
character:GetAttributeChangedSignal("Airborne"):Connect(function()
	local newValue = character:GetAttribute("Airborne")
	local airTime = tick() - flags.lastAirborne
	if not newValue and flags.airborne and airTime >= 0.5 then
		springs.lookSway:accelerate(Vector3.new(0, -0.7, 0))
		assets.Events.PlayCharacterSound:FireServer("Landing")
	elseif newValue and not flags.airborne then
		springs.lookSway:accelerate(Vector3.new(0, 0.4, 0))
	end
	flags.airborne = newValue
	if flags.airborne then flags.lastAirborne = tick() end
end)
