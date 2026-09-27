local players = game:GetService("Players")
local runService = game:GetService("RunService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local contextActionService = game:GetService("ContextActionService")
local tweenService = game:GetService("TweenService")
local userInputService = game:GetService("UserInputService")
local contentProvider = game:GetService("ContentProvider")

local localPlayer: Player = players.LocalPlayer
local playerCharacter: Model = localPlayer.Character or localPlayer.CharacterAdded:Wait()
--[[
	WaitForChild(name, timeout) returns NIL on timeout -- it does not throw.

	So when the rig loads incomplete, the line that FAILS is not the one that
	waited, it is the next one, which indexes that nil:

	    local rootPart = playerCharacter:WaitForChild("HumanoidRootPart", 20) -- nil
	    local rootJoint = rootPart:WaitForChild("RootJoint", 20)  -- "index nil"

	That error surfaces 20 seconds after the real event and names the wrong line,
	which is why an incomplete rig looks like a bug in this script. The helper
	reports the part that is actually missing at the moment it gives up, then
	keeps waiting, so the script recovers on its own if the part arrives late
	instead of staying dead for the rest of the life.
--]]
local function requirePart(parent: Instance, name: string): Instance?
	local found = parent:WaitForChild(name, 20)
	if found then return found end

	warn(("[CharacterMovement] '%s' still has no '%s' after 20s -- the character "):format(parent.Name, name)
		.. "rig loaded incomplete. Movement stays disabled until it appears. Check for a "
		.. "custom StarterCharacter missing this part, and check client memory in the "
		.. "Developer Console -- a memory-starved client can fail to load the rig.")

	-- Keep waiting, but give up if the character itself is removed, so a dead
	-- character cannot leave this thread parked forever.
	while parent.Parent and not found do
		found = parent:WaitForChild(name, 5)
	end
	return found
end

local humanoid: Humanoid = requirePart(playerCharacter, "Humanoid") :: any
local rootPart: BasePart = requirePart(playerCharacter, "HumanoidRootPart") :: any
if not (humanoid and rootPart) then return end

local rootJoint: BasePart = requirePart(rootPart, "RootJoint") :: any
if not rootJoint then return end

-- Disable the default Animate script so it doesn't conflict with custom anims
local animateScript = playerCharacter:FindFirstChild("Animate")
if animateScript then animateScript.Enabled = false end
local assets = replicatedStorage.SPH_Assets
local modules = assets.Modules
local toggleViewmodelSprint = assets.Events.ToggleViewmodelSprint

-- Preload all animations so the first play of any animation doesn't snap/hitch
-- while its keyframe data streams in (e.g. first crouch, first unequip).
task.spawn(function()
	local toPreload = {}
	for _, anim in ipairs(assets.Animations:GetDescendants()) do
		if anim:IsA("Animation") then
			table.insert(toPreload, anim)
		end
	end
	contentProvider:PreloadAsync(toPreload)
end)

local bridgeNet = require(modules.BridgeNet)
local playerLean = bridgeNet.CreateBridge("PlayerLean")
local playerStance = bridgeNet.CreateBridge("PlayerStance")
local playerSwim = bridgeNet.CreateBridge("PlayerSwim")

local SwimController = require(modules.SwimController)

local config = require(replicatedStorage.SPH_Assets.GameConfig)
local c0Ref = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0)

local movementVector = Vector3.zero

local canChangeWalkSpeed = script:GetAttribute("CanChangeWalkSpeed")
local strafing = false
local strafingMult = config.strafeSpeedMultiplier

local canChangeStance = true
local stance = 0

local walkSpeedTween = nil

-- =====================
-- RAW INPUT TRACKING
-- =====================
local held = { W = false, A = false, S = false, D = false }
local inputMag = 0

-- Space is bound through ContextActionService, not the raw InputBegan listeners
-- further down, so its hold state has to be tracked inside that action handler.
-- While swimming it feeds Roblox's own swim ascent (humanoid.Jump).
local holdingUp = false

local function recomputeInputMag()
	local x = (held.D and 1 or 0) - (held.A and 1 or 0)
	local z = (held.W and 1 or 0) - (held.S and 1 or 0)
	local mag = math.sqrt(x * x + z * z)
	inputMag = math.clamp(mag, 0, 1)
end

local function getRawMoveDir(): Vector3
	local rawX = (held.D and 1 or 0) - (held.A and 1 or 0)
	local rawZ = (held.S and 1 or 0) - (held.W and 1 or 0)
	if rawX == 0 and rawZ == 0 then return Vector3.new(0, 0, 0) end

	local cam = workspace.CurrentCamera
	if not cam then return Vector3.new(rawX, 0, rawZ).Unit end

	local cf = cam.CFrame
	local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local right   = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)

	if forward.Magnitude > 0.001 then forward = forward.Unit end
	if right.Magnitude   > 0.001 then right   = right.Unit   end

	local dir = (forward * -rawZ) + (right * rawX)
	if dir.Magnitude > 0.001 then return dir.Unit end
	return Vector3.new(0, 0, 0)
end

-- =====================
-- TURN RADIUS TUNING
-- =====================
local TURN_RATE_WALK    = 345
local TURN_RATE_SPRINT  = 310
local TURN_RATE_CROUCH  = 300
local TURN_RATE_PRONE   = 200
local TURN_RATE_AIR     = 160

local TURN_SPEED_SCALE_POWER = 0.55
local TURN_STOP_THRESHOLD = 0.8

-- Idle-turn tuning grouped into one table (keeps the script under Luau's 200-local limit).
-- idlePivotRate* = per-stance turn velocity cap (deg/s). The turn is a force-based yaw spring
-- (overshoot + settle); lower idleDamping = more bounce, idleStiffness = how snappy the pivot is.
local TUNE = {
	idlePivotRate = 380,
	idlePivotRateCrouch = 220,
	idlePivotRateProne = 140,
	idleThreshold = 2,         -- deg; tight settle angle so the spring->movement handoff is snap-free
	idleStiffness = config.idlePivotStiffness or 90,
	idleDamping = config.idlePivotDamping or 12,
	idleSettleVel = config.idlePivotSettleVel or 20,   -- deg/s; with idleThreshold, release only once the spring has truly settled
	idleMoveThreshold = config.idlePivotMoveThreshold or 55, -- deg; start walking once facing within this
	landingDecel = config.landingDecel or 90,          -- WalkSpeed decel during landing lock
	landingVelDamp = config.landingVelocityDamp or 9,  -- higher = momentum killed faster (~9 = short 1-2 stud coast)
	lastMoveDir = Vector3.zero, -- runtime: last direction we were actually moving (for the momentum coast)
	-- Slope (uphill climbing). Only uphill movement is slowed; crossing/descending isn't.
	slopeWalkFullAngle = 12,     -- deg; climbs gentler than this don't slow you at all
	slopeWalkSteepAngle = 45,    -- deg; at/above this, walk speed = slopeWalkMinMult
	slopeWalkMinMult = 0.7,      -- walk-speed multiplier on the steepest climb
	slopeSprintFullAngle = 15,   -- deg; full sprint at/below this
	slopeSprintCutoffAngle = 35, -- deg; sprint fully gone at/above this (blends out between)
}

-- Reused downward ray for slope detection (set once; excludes the player)
TUNE.slopeRayParams = RaycastParams.new()
TUNE.slopeRayParams.FilterType = Enum.RaycastFilterType.Exclude
TUNE.slopeRayParams.FilterDescendantsInstances = { playerCharacter }
TUNE.slopeRayParams.IgnoreWater = true

-- =====================
-- TERRAIN ALIGNMENT
-- Tilts the visible body to match the ground/part surface normal, clamped per
-- stance. Applied through rootJoint.C0 (the same channel as lean), so it composes
-- with the lean tilt. Note: this rotates the visible torso relative to the upright
-- HumanoidRootPart (the Humanoid force-uprights the root every frame), so legs stay
-- ~vertical while the upper body aligns to the slope.
-- All values fall back to inline defaults, so GameConfig does not need new fields.
-- =====================
local TERRAIN = {
	enabled        = (config.terrainAlign ~= false),     -- default ON
	maxAngleStand  = config.terrainAlignMaxStand  or 6,  -- deg, standing
	maxAngleCrouch = config.terrainAlignMaxCrouch or 15, -- deg, crouched
	maxAngleProne  = config.terrainAlignMaxProne  or 45, -- deg, prone (40-50 range)
	rayLength      = config.terrainAlignRayLength or 8,  -- studs probed below root
}
TERRAIN.rayParams = RaycastParams.new()
TERRAIN.rayParams.FilterType = Enum.RaycastFilterType.Exclude
TERRAIN.rayParams.FilterDescendantsInstances = { playerCharacter }
TERRAIN.rayParams.IgnoreWater = true

-- Per-character so it works for remote players too. Stance is read from the
-- replicated "Stance" attribute (set server-side); defaults to standing.
local function getTerrainMaxAngleFor(character): number
	local s = character:GetAttribute("Stance")
	if s == "Prone" then return TERRAIN.maxAngleProne end
	if s == "Crouched" then return TERRAIN.maxAngleCrouch end
	return TERRAIN.maxAngleStand
end

-- Returns the terrain-alignment rotation expressed in rootJoint "tilt" space
-- (relative to c0Ref), already clamped to maxDeg. Identity when flat or airborne.
local function ComputeTerrainTilt(character, root: BasePart, hum: Humanoid, maxDeg: number): CFrame
	if not root then return CFrame.identity end
	if hum and hum.FloorMaterial == Enum.Material.Air then return CFrame.identity end
	-- Exclude this specific character so the ray hits the ground, not its own parts.
	TERRAIN.rayParams.FilterDescendantsInstances = { character }
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -TERRAIN.rayLength, 0), TERRAIN.rayParams)
	if not hit then return CFrame.identity end

	-- Surface normal in the root part's object space, so the tilt follows facing.
	local localN = root.CFrame:VectorToObjectSpace(hit.Normal)
	local angle = math.acos(math.clamp(localN.Y, -1, 1))
	if angle < 1e-4 then return CFrame.identity end

	local axis = Vector3.yAxis:Cross(localN)
	if axis.Magnitude < 1e-5 then return CFrame.identity end -- straight up/down, no axis
	axis = axis.Unit
	angle = math.min(angle, math.rad(maxDeg))

	-- Minimal rotation mapping body-up toward the surface normal (object space),
	-- then conjugated into tilt space: torso-vs-root = c0Ref * tilt * c0Ref:Inverse().
	local align = CFrame.fromAxisAngle(axis, angle)
	return c0Ref:Inverse() * align * c0Ref
end

local function getIdlePivotRate(): number
	if stance == 2 then return TUNE.idlePivotRateProne end
	if stance == 1 then return TUNE.idlePivotRateCrouch end
	return TUNE.idlePivotRate
end

-- =====================
-- IDLE LOOK-AROUND EMOTES
-- =====================
local IDLE_EMOTE_MIN_TIME = 10
local IDLE_EMOTE_MAX_TIME = 50
local idleEmoteTimer = 0
local idleEmoteThreshold = IDLE_EMOTE_MIN_TIME + math.random() * (IDLE_EMOTE_MAX_TIME - IDLE_EMOTE_MIN_TIME)
local currentIdleEmoteAnim: AnimationTrack? = nil

local smoothedMoveDir = Vector3.zero
local idlePivoting = false
local wasInputLastFrame = false
local idleYaw = 0      -- current sprung heading (degrees)
local idleYawVel = 0   -- heading angular velocity (deg/s)

-- =====================
-- STAMINA TUNING
-- =====================
local MAX_STAMINA = 100
local SPRINT_DRAIN_PER_SEC = 4
local REGEN_PER_SEC = MAX_STAMINA / 8
local JUMP_COST = 9
local RED_THRESHOLD = 15

local WATER_SPRINT_DRAIN_MULT = 2.1
local WATER_REGEN_MULT = 0.3

local stamina = MAX_STAMINA

--[[
	REGEN DELAY + RAMP.

	Stamina used to start refilling the instant sprinting stopped, at three times
	the drain rate -- so tapping Shift on and off was nearly free and there was
	never a moment of being winded. Now:

	  * after stamina is SPENT (sprinting or a jump) nothing refills for
	    staminaRegenDelay seconds -- longer, staminaRegenDelayEmpty, if you ran it
	    completely dry. That pause is what makes running out feel like something.
	  * then it refills slowly and builds up to the full rate over
	    staminaRegenRamp seconds, rather than snapping straight to max.

	Kept in TUNE rather than as new top-level locals: this script sits close to
	Luau's 200-local ceiling (see the note on TUNE above).
--]]
TUNE.staminaRegenDelay = 1.0       -- s after sprinting/jumping before regen starts
TUNE.staminaRegenDelayEmpty = 2.0  -- s instead, if stamina hit zero
TUNE.staminaRegenRamp = 1.0        -- s to build from a trickle up to the full regen rate
TUNE.staminaLastUse = -math.huge   -- runtime: os.clock() stamina was last spent
TUNE.staminaEmptied = false        -- runtime: last spend ran it dry

-- Call whenever stamina is spent. Restarts the pause before it refills.
function TUNE.markStaminaUse()
	TUNE.staminaLastUse = os.clock()
	TUNE.staminaEmptied = stamina <= 0
end

-- Stamina to add this frame at `rate` per second, after the pause and ramp.
function TUNE.staminaRegenAmount(rate: number, dt: number): number
	local delay = TUNE.staminaEmptied and TUNE.staminaRegenDelayEmpty or TUNE.staminaRegenDelay
	local since = os.clock() - TUNE.staminaLastUse - delay
	if since <= 0 then
		return 0
	end
	-- 0 -> 1 across the ramp. Starts at 15% rather than 0 so the bar visibly
	-- begins moving the moment the pause ends.
	local ramp = math.clamp(since / math.max(TUNE.staminaRegenRamp, 0.01), 0.15, 1)
	return rate * ramp * dt
end

-- =====================
-- SPRINT DIRECTION LOCK
-- =====================
local SPRINT_MAX_ANGLE = 50

-- =====================
-- ACCELERATION / DECELERATION TUNING
-- =====================
-- All values are in studs/s? (how fast WalkSpeed ramps up or down).
-- Set any to math.huge for instant transitions (effectively disabling smoothing).
local ACCEL_WALK    = config.accelWalk    or 28   -- standing walk acceleration
local DECEL_WALK    = config.decelWalk    or 32   -- standing walk deceleration (stopping)
local ACCEL_SPRINT  = config.accelSprint  or 18   -- sprint acceleration (wind-up)
local DECEL_SPRINT  = config.decelSprint  or 24   -- sprint ? walk/stop deceleration
local ACCEL_CROUCH  = config.accelCrouch  or 22   -- crouch acceleration
local DECEL_CROUCH  = config.decelCrouch  or 30   -- crouch deceleration
local ACCEL_PRONE   = config.accelProne   or 14   -- prone acceleration
local DECEL_PRONE   = config.decelProne   or 20   -- prone deceleration

-- Minimum speed threshold ? below this we snap to zero to avoid drifting forever
local SPEED_SNAP_THRESHOLD = config.speedSnapThreshold or 0.5

-- Landing deceleration is tuned in the TUNE table above (landingDecel / landingVelDamp).

-- The smoothed speed that gets written to humanoid.WalkSpeed each frame
local smoothedSpeed = 0

-- Directional momentum (camera-locked strafing only: FP, shift-lock).
-- smoothedWishDir is the eased move-direction vector fed to humanoid:Move. When you
-- cut to a new direction while already moving it rotates toward the input instead of
-- snapping; because it isn't re-normalized mid-turn its magnitude dips, so sharper
-- direction changes bleed more speed (a full reversal nearly stops you) and you rebuild.
-- Lower DIR_RESPONSE = heavier momentum. Starting from a stop snaps so the speed ramp
-- (smoothedSpeed) handles build-up without double-ramping.
local smoothedWishDir = Vector3.zero
local DIR_RESPONSE = config.dirResponse or 12

-- =====================
-- PRONE MATERIAL SOUNDS
-- =====================
local PRONE_CRAWL_SOUND_INTERVAL = 0.45  -- seconds between crawl sounds
local lastProneSoundTime = 0

-- Material -> sound id mapping for prone crawling
local proneMaterialSounds = config.proneMaterialSounds or {
	[Enum.Material.Grass]      = "rbxassetid://9126214737",
	[Enum.Material.Ground]     = "rbxassetid://9126214737",
	[Enum.Material.LeafyGrass] = "rbxassetid://9126214737",
	[Enum.Material.Sand]       = "rbxassetid://9126214402",
	[Enum.Material.Mud]        = "rbxassetid://9126214402",
	[Enum.Material.Snow]       = "rbxassetid://9126214402",
	[Enum.Material.Metal]      = "rbxassetid://9126213833",
	[Enum.Material.DiamondPlate] = "rbxassetid://9126213833",
	[Enum.Material.CorrodedMetal] = "rbxassetid://9126213833",
	[Enum.Material.Concrete]   = "rbxassetid://9126213521",
	[Enum.Material.Brick]      = "rbxassetid://9126213521",
	[Enum.Material.Cobblestone] = "rbxassetid://9126213521",
	[Enum.Material.Slate]      = "rbxassetid://9126213521",
	[Enum.Material.Granite]    = "rbxassetid://9126213521",
	[Enum.Material.Marble]     = "rbxassetid://9126213521",
	[Enum.Material.Limestone]  = "rbxassetid://9126213521",
	[Enum.Material.Basalt]     = "rbxassetid://9126213521",
	[Enum.Material.Pavement]   = "rbxassetid://9126213521",
	[Enum.Material.Wood]       = "rbxassetid://9126215005",
	[Enum.Material.WoodPlanks] = "rbxassetid://9126215005",
	[Enum.Material.Plastic]    = "rbxassetid://9126213521",
	[Enum.Material.SmoothPlastic] = "rbxassetid://9126213521",
	[Enum.Material.Fabric]     = "rbxassetid://9126214737",
	[Enum.Material.Carpet]     = "rbxassetid://9126214737",
}
local PRONE_SOUND_FALLBACK = "rbxassetid://9126213521"

local function PlayProneCrawlSound()
	if not rootPart then return end
	local mat = humanoid.FloorMaterial
	if mat == Enum.Material.Air then return end
	local soundId = proneMaterialSounds[mat] or PRONE_SOUND_FALLBACK
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.35
	sound.PlaybackSpeed = 0.9 + math.random() * 0.2
	sound.RollOffMaxDistance = 40
	sound.Parent = rootPart
	sound:Play()
	game:GetService("Debris"):AddItem(sound, sound.TimeLength + 0.5)
end

-- =====================
-- STATE
-- =====================
local moving = false
local proneTransitioning = false

local function TweenWalkSpeed(target: number, duration: number)
	if walkSpeedTween then
		walkSpeedTween:Cancel()
		walkSpeedTween = nil
	end
	walkSpeedTween = tweenService:Create(humanoid, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {WalkSpeed = target})
	walkSpeedTween:Play()
	walkSpeedTween.Completed:Connect(function()
		walkSpeedTween = nil
	end)
end

local function IsFirstPersonOrShiftLock()
	-- [Drone] Looking through the drone: the mouse is locked and the camera is on the
	-- drone, but that must NOT turn the character to face where the drone looks.
	if playerCharacter:GetAttribute("DroneView") == true then return false end
	local camera = workspace.CurrentCamera
	if camera then
		local head = playerCharacter:FindFirstChild("Head")
		if head then
			local dist = (camera.CFrame.Position - head.Position).Magnitude
			if dist < 1 then return true end
		end
	end
	-- Only skip LockCenter when the gun locked the mouse in third person
	local gunLocked = playerCharacter:GetAttribute("SPH_GunLockedMouse")
	local inFirstPerson = playerCharacter:GetAttribute("SPH_FirstPerson")
	if gunLocked and not inFirstPerson then return false end
	if userInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then return true end
	return false
end

local function IsInWater(): boolean
	return humanoid ~= nil and humanoid:GetState() == Enum.HumanoidStateType.Swimming
end

local function IsAirborne(): boolean
	if not humanoid then return false end
	local st = humanoid:GetState()
	return st == Enum.HumanoidStateType.Jumping
		or st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.FallingDown
end

local function IsSeated(): boolean
	if not humanoid then return false end
	return humanoid.Sit == true or humanoid:GetState() == Enum.HumanoidStateType.Seated
end

-- =====================
-- STAMINA HELPERS
-- =====================
local function PushStaminaAttrs()
	if humanoid then
		humanoid:SetAttribute("Stamina", stamina)
		humanoid:SetAttribute("MaxStamina", MAX_STAMINA)
	end
end

--[[
	EXOSKELETON -- infinite stamina.

	A powered frame carries the load, so sprinting and jumping cost nothing while
	one is worn. The attribute is put on the CHARACTER by ArsenalServer, recomputed
	from every equipped slot, and it is the server that sets it -- this client only
	reads it. A client writing it to itself would not replicate anywhere, so there
	is nothing here to exploit.

	Read fresh every time rather than cached on spawn: you equip and unequip at a
	locker mid-life, and the next sprint should already know.

	The bar is PINNED FULL rather than frozen wherever it happened to be. The HUD
	reads humanoid.Stamina, so a suit picked up at 12% would otherwise show a near-
	empty bar that never moves, which reads as a bug rather than as a feature. Full
	and unmoving is legible at a glance.
--]]
local function HasExoskeleton(): boolean
	return playerCharacter ~= nil and playerCharacter:GetAttribute("Exoskeleton") == true
end

local function CanStartSprint(): boolean
	return stance == 0 and (HasExoskeleton() or stamina > RED_THRESHOLD)
end

local function CanKeepSprint(): boolean
	return stance == 0 and (HasExoskeleton() or stamina > 0)
end

-- =====================
-- TURN RADIUS HELPERS
-- =====================
local function slewDirection(current: Vector3, target: Vector3, maxDeg: number, dt: number): Vector3
	if current.Magnitude < 0.001 then return target end
	if target.Magnitude < 0.001 then return current end

	local dot = math.clamp(current:Dot(target), -1, 1)
	local angleBetween = math.deg(math.acos(dot))

	local maxTurn = maxDeg * dt
	if maxTurn >= angleBetween then return target end

	local t = maxTurn / angleBetween
	local cx, cz = current.X, current.Z
	local tx, tz = target.X, target.Z
	local aFrom = math.atan2(cz, cx)
	local aTo   = math.atan2(tz, tx)
	local delta = aTo - aFrom
	if delta > math.pi  then delta -= 2 * math.pi end
	if delta < -math.pi then delta += 2 * math.pi end
	local aNew = aFrom + delta * t
	return Vector3.new(math.cos(aNew), 0, math.sin(aNew))
end

local function getBaseTurnRate(): number
	if IsAirborne() then return TURN_RATE_AIR end
	if stance == 2 then return TURN_RATE_PRONE end
	if stance == 1 then return TURN_RATE_CROUCH end
	if playerCharacter:GetAttribute("Sprinting") then return TURN_RATE_SPRINT end
	return TURN_RATE_WALK
end

local function GetAngleFromForward(worldDir: Vector3): number
	if not rootPart then return 0 end
	if worldDir.Magnitude < 0.01 then return 0 end
	local relativeDir = rootPart.CFrame:VectorToObjectSpace(worldDir)
	local angle = math.deg(math.atan2(relativeDir.X, -relativeDir.Z))
	return math.abs(angle)
end

local function IsSprintDirectionAllowed(): boolean
	if not IsFirstPersonOrShiftLock() then return true end
	local rawDir = getRawMoveDir()
	if rawDir.Magnitude < 0.01 then return false end
	return GetAngleFromForward(rawDir) <= SPRINT_MAX_ANGLE
end

-- =====================
-- ACCEL/DECEL HELPERS
-- =====================
-- Returns the appropriate accel and decel rates for the current state
local function getAccelDecel(): (number, number)
	if playerCharacter:GetAttribute("Sprinting") then
		return ACCEL_SPRINT, DECEL_SPRINT
	end
	if stance == 2 then return ACCEL_PRONE, DECEL_PRONE end
	if stance == 1 then return ACCEL_CROUCH, DECEL_CROUCH end
	return ACCEL_WALK, DECEL_WALK
end

-- Moves `current` toward `target` by up to `rate * dt`, respecting direction
local function moveToward(current: number, target: number, rate: number, dt: number): number
	local diff = target - current
	local step = rate * dt
	if math.abs(diff) <= step then
		return target
	end
	return current + math.sign(diff) * step
end

-- =====================
-- ANIM SPEEDS
-- =====================
local proneAnimSpeeds = {
	forward      = config.proneMoveAnimSpeed_Forward      or config.proneMoveAnimSpeed or 1.5,
	backward     = config.proneMoveAnimSpeed_Backward     or config.proneMoveAnimSpeed or 1.5,
	left         = config.proneMoveAnimSpeed_Left         or config.proneMoveAnimSpeed or 1.5,
	right        = config.proneMoveAnimSpeed_Right        or config.proneMoveAnimSpeed or 1.5,
	leftDiag     = config.proneMoveAnimSpeed_LeftDiag     or config.proneMoveAnimSpeed or 1.5,
	leftDiagRev  = config.proneMoveAnimSpeed_LeftDiagRev  or config.proneMoveAnimSpeed or 1.5,
	rightDiag    = config.proneMoveAnimSpeed_RightDiag    or config.proneMoveAnimSpeed or 1.5,
	rightDiagRev = config.proneMoveAnimSpeed_RightDiagRev or config.proneMoveAnimSpeed or 1.5,
}

local crouchAnimSpeeds = {
	forward      = config.crouchMoveAnimSpeed_Forward      or config.crouchMoveAnimSpeed or 1.5,
	backward     = config.crouchMoveAnimSpeed_Backward     or config.crouchMoveAnimSpeed or 1.5,
	left         = config.crouchMoveAnimSpeed_Left         or config.crouchMoveAnimSpeed or 1.5,
	right        = config.crouchMoveAnimSpeed_Right        or config.crouchMoveAnimSpeed or 1.5,
	leftDiag     = config.crouchMoveAnimSpeed_LeftDiag     or config.crouchMoveAnimSpeed or 1.5,
	leftDiagRev  = config.crouchMoveAnimSpeed_LeftDiagRev  or config.crouchMoveAnimSpeed or 1.5,
	rightDiag    = config.crouchMoveAnimSpeed_RightDiag    or config.crouchMoveAnimSpeed or 1.5,
	rightDiagRev = config.crouchMoveAnimSpeed_RightDiagRev or config.crouchMoveAnimSpeed or 1.5,
}

local walkAnimSpeeds = {
	forward      = config.walkAnimSpeed_Forward      or config.walkAnimSpeed or 1.17,
	backward     = config.walkAnimSpeed_Backward     or config.walkAnimSpeed or 1.17,
	left         = config.walkAnimSpeed_Left         or config.walkAnimSpeed or 1.17,
	right        = config.walkAnimSpeed_Right        or config.walkAnimSpeed or 1.17,
	leftDiag     = config.walkAnimSpeed_LeftDiag     or config.walkAnimSpeed or 1.17,
	leftDiagRev  = config.walkAnimSpeed_LeftDiagRev  or config.walkAnimSpeed or 1.17,
	rightDiag    = config.walkAnimSpeed_RightDiag    or config.walkAnimSpeed or 1.17,
	rightDiagRev = config.walkAnimSpeed_RightDiagRev or config.walkAnimSpeed or 1.17,
}

local SPRINT_ANIM_SPEED = config.sprintAnimSpeed or 1.3

-- =====================
-- CROUCH ANIMATIONS
-- =====================
local crouchIdleAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchIdle)
crouchIdleAnim.Looped = true
crouchIdleAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action or Enum.AnimationPriority.Idle

local crouchForwardAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkForward)
crouchForwardAnim.Looped = true
crouchForwardAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchBackwardAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkReverse)
crouchBackwardAnim.Looped = true
crouchBackwardAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchLeftAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkLeft)
crouchLeftAnim.Looped = true
crouchLeftAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchRightAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkRight)
crouchRightAnim.Looped = true
crouchRightAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchLeftDiagAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkLeftDiagonal)
crouchLeftDiagAnim.Looped = true
crouchLeftDiagAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchLeftDiagRevAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkLeftDiagonalReverse)
crouchLeftDiagRevAnim.Looped = true
crouchLeftDiagRevAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchRightDiagAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkRightDiagonal)
crouchRightDiagAnim.Looped = true
crouchRightDiagAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local crouchRightDiagRevAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.CrouchWalkRightDiagonalReverse)
crouchRightDiagRevAnim.Looped = true
crouchRightDiagRevAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local allCrouchMoveAnims = {
	crouchForwardAnim, crouchBackwardAnim, crouchLeftAnim, crouchRightAnim,
	crouchLeftDiagAnim, crouchLeftDiagRevAnim, crouchRightDiagAnim, crouchRightDiagRevAnim,
}

-- =====================
-- STANDING ANIMATIONS
-- =====================
local movPriority  = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement
local idlePriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action  or Enum.AnimationPriority.Idle

local standingIdleAnim = nil
if assets.Animations:FindFirstChild("StandingIdle") then
	standingIdleAnim = humanoid.Animator:LoadAnimation(assets.Animations.StandingIdle)
	standingIdleAnim.Looped = true
	standingIdleAnim.Priority = idlePriority
end

-- Idle look-around emotes (play occasionally while standing still, unarmed)
local idleEmoteAnims: {AnimationTrack} = {}
for i = 1, 2 do
	local animName = "IdleEmote" .. i
	if assets.Animations:FindFirstChild(animName) then
		local track = humanoid.Animator:LoadAnimation(assets.Animations[animName])
		track.Looped = false
		track.Priority = movPriority -- one tier above idle so it reliably overrides standingIdleAnim
		table.insert(idleEmoteAnims, track)
	end
end

local walkForwardAnim = nil
if assets.Animations:FindFirstChild("WalkForward") then
	walkForwardAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkForward)
	walkForwardAnim.Looped = true
	walkForwardAnim.Priority = movPriority
end

local walkBackwardAnim = nil
if assets.Animations:FindFirstChild("WalkBackward") then
	walkBackwardAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkBackward)
	walkBackwardAnim.Looped = true
	walkBackwardAnim.Priority = movPriority
end

local walkLeftAnim = nil
if assets.Animations:FindFirstChild("WalkLeft") then
	walkLeftAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkLeft)
	walkLeftAnim.Looped = true
	walkLeftAnim.Priority = movPriority
end

local walkRightAnim = nil
if assets.Animations:FindFirstChild("WalkRight") then
	walkRightAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkRight)
	walkRightAnim.Looped = true
	walkRightAnim.Priority = movPriority
end

local walkLeftDiagAnim = nil
if assets.Animations:FindFirstChild("WalkLeftDiagonal") then
	walkLeftDiagAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkLeftDiagonal)
	walkLeftDiagAnim.Looped = true
	walkLeftDiagAnim.Priority = movPriority
end

local walkLeftDiagRevAnim = nil
if assets.Animations:FindFirstChild("WalkLeftDiagonalReverse") then
	walkLeftDiagRevAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkLeftDiagonalReverse)
	walkLeftDiagRevAnim.Looped = true
	walkLeftDiagRevAnim.Priority = movPriority
end

local walkRightDiagAnim = nil
if assets.Animations:FindFirstChild("WalkRightDiagonal") then
	walkRightDiagAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkRightDiagonal)
	walkRightDiagAnim.Looped = true
	walkRightDiagAnim.Priority = movPriority
end

local walkRightDiagRevAnim = nil
if assets.Animations:FindFirstChild("WalkRightDiagonalReverse") then
	walkRightDiagRevAnim = humanoid.Animator:LoadAnimation(assets.Animations.WalkRightDiagonalReverse)
	walkRightDiagRevAnim.Looped = true
	walkRightDiagRevAnim.Priority = movPriority
end

local sprintAnim = nil
if assets.Animations:FindFirstChild("Sprint") then
	sprintAnim = humanoid.Animator:LoadAnimation(assets.Animations.Sprint)
	sprintAnim.Looped = true
	sprintAnim.Priority = movPriority
end

local allWalkAnims = {}
if walkForwardAnim then table.insert(allWalkAnims, walkForwardAnim) end
if walkBackwardAnim then table.insert(allWalkAnims, walkBackwardAnim) end
if walkLeftAnim then table.insert(allWalkAnims, walkLeftAnim) end
if walkRightAnim then table.insert(allWalkAnims, walkRightAnim) end
if walkLeftDiagAnim then table.insert(allWalkAnims, walkLeftDiagAnim) end
if walkLeftDiagRevAnim then table.insert(allWalkAnims, walkLeftDiagRevAnim) end
if walkRightDiagAnim then table.insert(allWalkAnims, walkRightDiagAnim) end
if walkRightDiagRevAnim then table.insert(allWalkAnims, walkRightDiagRevAnim) end

-- =====================
-- TURN IN PLACE ANIMATIONS
-- =====================
local turnPriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local turnInIdleAnim = nil
if assets.Animations:FindFirstChild("TurnInIdle") then
	turnInIdleAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnInIdle)
	turnInIdleAnim.Looped = true
	turnInIdleAnim.Priority = turnPriority
end

local turnOutIdleAnim = nil
if assets.Animations:FindFirstChild("TurnOutIdle") then
	turnOutIdleAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnOutIdle)
	turnOutIdleAnim.Looped = true
	turnOutIdleAnim.Priority = turnPriority
end

local turnInCrouchAnim = nil
if assets.Animations:FindFirstChild("TurnInCrouch") then
	turnInCrouchAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnInCrouch)
	turnInCrouchAnim.Looped = true
	turnInCrouchAnim.Priority = turnPriority
end

local turnOutCrouchAnim = nil
if assets.Animations:FindFirstChild("TurnOutCrouch") then
	turnOutCrouchAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnOutCrouch)
	turnOutCrouchAnim.Looped = true
	turnOutCrouchAnim.Priority = turnPriority
end

local turnInProneAnim = nil
if assets.Animations:FindFirstChild("TurnInProne") then
	turnInProneAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnInProne)
	turnInProneAnim.Looped = true
	turnInProneAnim.Priority = turnPriority
end

local turnOutProneAnim = nil
if assets.Animations:FindFirstChild("TurnOutProne") then
	turnOutProneAnim = humanoid.Animator:LoadAnimation(assets.Animations.TurnOutProne)
	turnOutProneAnim.Looped = true
	turnOutProneAnim.Priority = turnPriority
end

local allTurnAnims = {}
if turnInIdleAnim then table.insert(allTurnAnims, turnInIdleAnim) end
if turnOutIdleAnim then table.insert(allTurnAnims, turnOutIdleAnim) end
if turnInCrouchAnim then table.insert(allTurnAnims, turnInCrouchAnim) end
if turnOutCrouchAnim then table.insert(allTurnAnims, turnOutCrouchAnim) end
if turnInProneAnim then table.insert(allTurnAnims, turnInProneAnim) end
if turnOutProneAnim then table.insert(allTurnAnims, turnOutProneAnim) end

local currentTurnAnim: AnimationTrack? = nil
local lastYaw: number? = nil
local TURN_ANIM_HOLD_TIME = 0.2      -- seconds to keep playing after turning stops

-- Accumulated-yaw approach: instead of checking one frame's delta,
-- we sum yaw changes over a short window. Slow deliberate turns accumulate
-- past the threshold, but a single-pixel jitter decays away before it can.
local TURN_YAW_THRESHOLD = 3         -- degrees accumulated to trigger the anim
local TURN_JITTER_IGNORE = 0.15      -- per-frame deltas below this (degrees) are ignored as noise
local TURN_ACCUMULATE_DECAY = 8      -- degrees/sec the accumulator decays back toward zero
local accumulatedYaw = 0             -- running signed accumulator
local lastTurnDetectedAt = 0

-- =====================
-- JUMP WIND-UP & FALLING ANIMATIONS
-- =====================
local JUMP_WINDUP_DURATION = 0.45
local JUMP_LANDING_COOLDOWN = 1
local jumpWindingUp = false
local jumpOnCooldown = false
local lastLandedTime = -999

local jumpPriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action3 or Enum.AnimationPriority.Action2

local jumpWindupAnim = nil
if assets.Animations:FindFirstChild("JumpWindup") then
	jumpWindupAnim = humanoid.Animator:LoadAnimation(assets.Animations.JumpWindup)
	jumpWindupAnim.Looped = false
	jumpWindupAnim.Priority = jumpPriority
end

local fallingAnim = nil
if assets.Animations:FindFirstChild("Falling") then
	fallingAnim = humanoid.Animator:LoadAnimation(assets.Animations.Falling)
	fallingAnim.Looped = true
	fallingAnim.Priority = jumpPriority
end

local wasFalling = false
local didSprintJump = false
local LANDING_LOCK_DURATION = 0.61
local landingLocked = false

-- Prolonged fall detection: if airborne for longer than this threshold while in
-- crouch/prone/sprint, we treat it as a real fall (play fall anim, force standing, etc.)
local PROLONGED_FALL_THRESHOLD = 0.45 -- seconds airborne before it counts as a real fall
local airborneStartTime = 0           -- os.clock() when we first became airborne

local landingAnim = nil
if assets.Animations:FindFirstChild("Landing") then
	landingAnim = humanoid.Animator:LoadAnimation(assets.Animations.Landing)
	landingAnim.Looped = false
	landingAnim.Priority = jumpPriority
end

-- =====================
-- SIT ANIMATION
-- =====================
local sitAnim = nil
if assets.Animations:FindFirstChild("Sit") then
	sitAnim = humanoid.Animator:LoadAnimation(assets.Animations.Sit)
	sitAnim.Looped = true
	sitAnim.Priority = Enum.AnimationPriority.Action4
end

-- Disable default jump so we can intercept it
humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)

-- Cooldown after unseating so the same Space press doesn't trigger a jump
local justUnseated = false

local function DoJumpWindup()
	if jumpWindingUp then return end
	if jumpOnCooldown then return end
	if justUnseated then return end
	if stance ~= 0 then return end
	if IsAirborne() then return end
	if IsSeated() then return end
	if proneTransitioning then return end
	-- Only for idle/walking ? sprinting skips wind-up entirely
	if playerCharacter:GetAttribute("Sprinting") then return end

	-- Check landing cooldown
	local now = os.clock()
	if (now - lastLandedTime) < JUMP_LANDING_COOLDOWN then return end

	-- Check stamina (but don't deduct yet ? wait until the actual jump).
	-- An exoskeleton jumps for free, so it never fails this gate.
	if not HasExoskeleton() and stamina < JUMP_COST then return end

	-- Instant jump (no wind-up): fire immediately
	jumpOnCooldown = true

	-- Deduct stamina now that the jump fires
	if not HasExoskeleton() then
		stamina -= JUMP_COST
		TUNE.markStaminaUse()
		PushStaminaAttrs()
	end

	if humanoid and humanoid.Health > 0 and not IsSeated() then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.Jump = true
		-- Re-disable after a short delay so default jump can't fire again
		task.delay(0.15, function()
			if humanoid then
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			end
		end)
	end
end

-- Bind spacebar to our custom jump
contextActionService:BindActionAtPriority("SPH_Jump", function(actionName, inputState, inputObject)
	-- Track hold state first. While swimming, Space is a continuous "rise" fed to
	-- humanoid.Jump by SwimController, not a one-shot jump, so the custom jump
	-- logic below must not run.
	if inputState == Enum.UserInputState.Begin then
		holdingUp = true
	elseif inputState == Enum.UserInputState.End then
		holdingUp = false
	end
	SwimController.setHoldingUp(holdingUp)
	if SwimController.isSwimming() then
		-- Holding Space rises through the swim move vector. A PRESS additionally
		-- fires a real jump, which is what lets you hop out at the surface -- the
		-- custom jump path below is all land logic and would just reject it.
		if inputState == Enum.UserInputState.Begin then
			SwimController.requestJump()
		end
		return Enum.ContextActionResult.Sink
	end

	if inputState == Enum.UserInputState.Begin then
		-- If seated, manually unseat WITHOUT jumping
		if IsSeated() then
			humanoid.Sit = false
			justUnseated = true
			task.delay(0.4, function()
				justUnseated = false
			end)
			return Enum.ContextActionResult.Sink
		end
		-- Block jump if we just unseated (same Space press / rapid re-press)
		if justUnseated then
			return Enum.ContextActionResult.Sink
		end
		-- Sprinting: let the jump happen instantly with no wind-up
		if playerCharacter:GetAttribute("Sprinting") then
			if not IsAirborne() and stance == 0 and not jumpOnCooldown then
				-- Check landing cooldown to prevent spam
				local now = os.clock()
				local exo = HasExoskeleton()
				if (now - lastLandedTime) >= JUMP_LANDING_COOLDOWN and (exo or stamina >= JUMP_COST) then
					if not exo then
						stamina -= JUMP_COST
						TUNE.markStaminaUse()
						PushStaminaAttrs()
					end
					jumpOnCooldown = true
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					humanoid.Jump = true
					didSprintJump = true
					task.delay(0.15, function()
						if humanoid then
							humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
						end
					end)
				end
			end
			return Enum.ContextActionResult.Sink
		end
		-- Idle/walking: do the wind-up
		DoJumpWindup()
	end
	return Enum.ContextActionResult.Sink -- consume the input so default jump doesn't fire
end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

-- =====================
-- PRONE ANIMATIONS
-- =====================
local proneTransitionDownAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneTransitionDown)
proneTransitionDownAnim.Looped = false
proneTransitionDownAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action3 or Enum.AnimationPriority.Action2

local proneTransitionUpAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneTransitionUp)
proneTransitionUpAnim.Looped = false
proneTransitionUpAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action3 or Enum.AnimationPriority.Action2

local proneIdleAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.Prone_Idle)
proneIdleAnim.Looped = true
proneIdleAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action or Enum.AnimationPriority.Idle

local proneForwardAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneForward)
proneForwardAnim.Looped = true
proneForwardAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneBackwardAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneBackwards)
proneBackwardAnim.Looped = true
proneBackwardAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneLeftAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneLeft)
proneLeftAnim.Looped = true
proneLeftAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneRightAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneRight)
proneRightAnim.Looped = true
proneRightAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneLeftDiagAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneLeftDiagonal)
proneLeftDiagAnim.Looped = true
proneLeftDiagAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneLeftDiagRevAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneLeftDiagonalReverse)
proneLeftDiagRevAnim.Looped = true
proneLeftDiagRevAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneRightDiagAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneRightDiagonal)
proneRightDiagAnim.Looped = true
proneRightDiagAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local proneRightDiagRevAnim: AnimationTrack = humanoid.Animator:LoadAnimation(assets.Animations.ProneRightDiagonalReverse)
proneRightDiagRevAnim.Looped = true
proneRightDiagRevAnim.Priority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement

local allProneMoveAnims = {
	proneForwardAnim, proneBackwardAnim, proneLeftAnim, proneRightAnim,
	proneLeftDiagAnim, proneLeftDiagRevAnim, proneRightDiagAnim, proneRightDiagRevAnim,
}

-- Speed maps
local proneAnimSpeedMap = {
	[proneForwardAnim]      = proneAnimSpeeds.forward,
	[proneBackwardAnim]     = proneAnimSpeeds.backward,
	[proneLeftAnim]         = proneAnimSpeeds.left,
	[proneRightAnim]        = proneAnimSpeeds.right,
	[proneLeftDiagAnim]     = proneAnimSpeeds.leftDiag,
	[proneLeftDiagRevAnim]  = proneAnimSpeeds.leftDiagRev,
	[proneRightDiagAnim]    = proneAnimSpeeds.rightDiag,
	[proneRightDiagRevAnim] = proneAnimSpeeds.rightDiagRev,
}

local crouchAnimSpeedMap = {
	[crouchForwardAnim]      = crouchAnimSpeeds.forward,
	[crouchBackwardAnim]     = crouchAnimSpeeds.backward,
	[crouchLeftAnim]         = crouchAnimSpeeds.left,
	[crouchRightAnim]        = crouchAnimSpeeds.right,
	[crouchLeftDiagAnim]     = crouchAnimSpeeds.leftDiag,
	[crouchLeftDiagRevAnim]  = crouchAnimSpeeds.leftDiagRev,
	[crouchRightDiagAnim]    = crouchAnimSpeeds.rightDiag,
	[crouchRightDiagRevAnim] = crouchAnimSpeeds.rightDiagRev,
}

local walkAnimSpeedMap = {}
do
	local entries = {
		{walkForwardAnim,      walkAnimSpeeds.forward},
		{walkBackwardAnim,     walkAnimSpeeds.backward},
		{walkLeftAnim,         walkAnimSpeeds.left},
		{walkRightAnim,        walkAnimSpeeds.right},
		{walkLeftDiagAnim,     walkAnimSpeeds.leftDiag},
		{walkLeftDiagRevAnim,  walkAnimSpeeds.leftDiagRev},
		{walkRightDiagAnim,    walkAnimSpeeds.rightDiag},
		{walkRightDiagRevAnim, walkAnimSpeeds.rightDiagRev},
	}
	for _, e in ipairs(entries) do
		if e[1] ~= nil then walkAnimSpeedMap[e[1]] = e[2] end
	end
end

local walkAnimTable = {
	forward      = walkForwardAnim,
	backward     = walkBackwardAnim,
	left         = walkLeftAnim,
	right        = walkRightAnim,
	leftDiag     = walkLeftDiagAnim,
	leftDiagRev  = walkLeftDiagRevAnim,
	rightDiag    = walkRightDiagAnim,
	rightDiagRev = walkRightDiagRevAnim,
}

local proneAnimTable = {
	forward      = proneForwardAnim,
	backward     = proneBackwardAnim,
	left         = proneLeftAnim,
	right        = proneRightAnim,
	leftDiag     = proneLeftDiagAnim,
	leftDiagRev  = proneLeftDiagRevAnim,
	rightDiag    = proneRightDiagAnim,
	rightDiagRev = proneRightDiagRevAnim,
}

local crouchAnimTable = {
	forward      = crouchForwardAnim,
	backward     = crouchBackwardAnim,
	left         = crouchLeftAnim,
	right        = crouchRightAnim,
	leftDiag     = crouchLeftDiagAnim,
	leftDiagRev  = crouchLeftDiagRevAnim,
	rightDiag    = crouchRightDiagAnim,
	rightDiagRev = crouchRightDiagRevAnim,
}

local currentProneMoveAnim: AnimationTrack = nil
local currentCrouchMoveAnim: AnimationTrack = nil
local currentWalkAnim: AnimationTrack = nil
-- True while the creature has hold of us and the movement animation stack has
-- already been stopped. See the Grabbed branch in the RenderStepped loop.
local grabbedAnimsStopped = false

script:SetAttribute("WalkSpeed", config.walkSpeed)
script:SetAttribute("SprintSpeed", config.sprintSpeed)
script:SetAttribute("CrouchSpeed", config.crouchSpeed)
script:SetAttribute("ProneSpeed", config.proneSpeed)

playerCharacter:SetAttribute("Stance", "Standing")
playerCharacter:SetAttribute("LeanDirection", 0)

-- Disable AutoRotate ? we handle rotation manually
humanoid.AutoRotate = false

-- Init stamina
PushStaminaAttrs()

-- Init smoothed speed to current WalkSpeed
smoothedSpeed = humanoid.WalkSpeed

local function LerpNumber(number: number, target: number, speed: number)
	return number + (target - number) * speed
end

local function ToggleSprint(toggle: boolean)
	toggleViewmodelSprint:Fire(toggle)
end

local function UpdateCharacterTilt(character, deltaTime)
	--[[
		NEVER tilt a creature.

		This function is called for the local character AND, in the main loop below,
		for every other player's character. That second call runs on the OBSERVER's
		client -- so a creature gets its RootJoint.C0 rewritten by every other player
		in the server, using a base CFrame and stance rules meant for an R6 human.

		That is precisely why a transformed player looks correct on their own screen
		and wrong on everybody else's: the owner's client never runs this against
		their own creature (CreatureMovement owns that joint), but every observer's
		client does, and the torso it displaces takes the head with it.

		The creature drives its own lean and terrain alignment from CreatureMovement.
	--]]
	if character:GetAttribute("IsCreature") == true then
		return
	end

	-- Resolve parts from the passed character so this works for remote players too.
	local hum = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local joint = root and root:FindFirstChild("RootJoint")
	if not hum or hum.Health <= 0 or not root or not joint then return end

	local currentTilt = c0Ref:Inverse() * joint.C0

	-- (The movement lean -- tilting the body toward the direction you walk -- was
	-- removed. Only terrain alignment drives this joint now. Q/E corner leaning is
	-- a separate system and is untouched.)

	-- Terrain alignment (clamped per stance) ? applied to every character via C0.
	-- Disabled while seated.
	local terrainTarget = CFrame.identity
	if TERRAIN.enabled and not (hum.Sit or character:GetAttribute("SeatAnim")) then
		terrainTarget = ComputeTerrainTilt(character, root, hum, getTerrainMaxAngleFor(character))
	end

	local target = terrainTarget

	local tilt = currentTilt:Lerp(target, 0.2 ^ (1 / (deltaTime * 60)))
	joint.C0 = c0Ref * tilt
end

local function IsCharacterStrafing(character)
	if not character:FindFirstChild("HumanoidRootPart") then return end
	if movementVector.Magnitude > 0 then
		local characterLookVector = character.HumanoidRootPart.CFrame.LookVector
		local dotProduct = movementVector:Dot(characterLookVector)
		return (dotProduct < 0.7)
	end
end

local function PlayCharSound(soundName)
	assets.Events.PlayCharacterSound:FireServer(soundName)
end

local function ChangeLean(newLean)
	local lean = playerCharacter:GetAttribute("LeanDirection")
	if not config.canLean then return end
	if newLean ~= lean then PlayCharSound("Lean") end
	lean = newLean
	playerCharacter:SetAttribute("LeanDirection", lean)
	playerLean:Fire(newLean)
end

local function GetDirectionalAnim(animTable)
	if humanoid.MoveDirection.Magnitude == 0 then return nil end

	local inFirstPerson = IsFirstPersonOrShiftLock()

	if not inFirstPerson then
		return animTable.forward
	end

	local relativeDir = rootPart.CFrame:VectorToObjectSpace(humanoid.MoveDirection)
	local x = relativeDir.X
	local angle = math.deg(math.atan2(x, -relativeDir.Z))
	if angle < 0 then angle += 360 end

	local chosen
	if angle >= 337.5 or angle < 22.5 then        chosen = animTable.forward
	elseif angle >= 22.5  and angle < 67.5 then   chosen = animTable.rightDiag
	elseif angle >= 67.5  and angle < 112.5 then  chosen = animTable.right
	elseif angle >= 112.5 and angle < 157.5 then  chosen = animTable.rightDiagRev
	elseif angle >= 157.5 and angle < 202.5 then  chosen = animTable.backward
	elseif angle >= 202.5 and angle < 247.5 then  chosen = animTable.leftDiagRev
	elseif angle >= 247.5 and angle < 292.5 then  chosen = animTable.left
	elseif angle >= 292.5 and angle < 337.5 then  chosen = animTable.leftDiag
	end

	return chosen or animTable.forward
end

local function StopAllAnims(animList, except, transTime)
	for _, anim in ipairs(animList) do
		if anim ~= except then
			anim:Stop(transTime or config.stanceChangeTime)
		end
	end
end

local function UpdateProneMoveAnim()
	if IsSeated() then
		StopAllAnims(allProneMoveAnims, nil, config.stanceChangeTime)
		currentProneMoveAnim = nil
		return
	end
	if stance ~= 2 or proneTransitioning then
		StopAllAnims(allProneMoveAnims, nil, config.stanceChangeTime)
		currentProneMoveAnim = nil
		return
	end

	local targetAnim = GetDirectionalAnim(proneAnimTable)

	if targetAnim == nil then
		if currentProneMoveAnim then
			StopAllAnims(allProneMoveAnims, nil, config.stanceChangeTime)
			currentProneMoveAnim = nil
		end
	elseif targetAnim ~= currentProneMoveAnim then
		StopAllAnims(allProneMoveAnims, targetAnim, config.stanceChangeTime)
		if not targetAnim.IsPlaying then
			local s = (humanoid.WalkSpeed / script:GetAttribute("ProneSpeed")) * (proneAnimSpeedMap[targetAnim] or 1.5)
			targetAnim:Play(config.stanceChangeTime)
			targetAnim:AdjustSpeed(s)
		end
		currentProneMoveAnim = targetAnim
	else
		targetAnim:AdjustSpeed((humanoid.WalkSpeed / script:GetAttribute("ProneSpeed")) * (proneAnimSpeedMap[targetAnim] or 1.5))
	end
end

local function UpdateCrouchMoveAnim()
	if IsSeated() then
		StopAllAnims(allCrouchMoveAnims, nil, config.stanceChangeTime)
		currentCrouchMoveAnim = nil
		return
	end
	if stance ~= 1 then
		StopAllAnims(allCrouchMoveAnims, nil, config.stanceChangeTime)
		currentCrouchMoveAnim = nil
		return
	end

	local targetAnim = GetDirectionalAnim(crouchAnimTable)

	if targetAnim == nil then
		if currentCrouchMoveAnim then
			StopAllAnims(allCrouchMoveAnims, nil, config.stanceChangeTime)
			currentCrouchMoveAnim = nil
		end
	elseif targetAnim ~= currentCrouchMoveAnim then
		StopAllAnims(allCrouchMoveAnims, targetAnim, config.stanceChangeTime)
		if not targetAnim.IsPlaying then
			local s = (humanoid.WalkSpeed / script:GetAttribute("CrouchSpeed")) * (crouchAnimSpeedMap[targetAnim] or 1.5)
			targetAnim:Play(config.stanceChangeTime)
			targetAnim:AdjustSpeed(s)
		end
		currentCrouchMoveAnim = targetAnim
	else
		targetAnim:AdjustSpeed((humanoid.WalkSpeed / script:GetAttribute("CrouchSpeed")) * (crouchAnimSpeedMap[targetAnim] or 1.5))
	end
end

local function UpdateWalkAnim()
	if #allWalkAnims == 0 then return end
	if IsSeated() then
		StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
		currentWalkAnim = nil
		return
	end
	local sprintSpeed = script:GetAttribute("SprintSpeed")
	local walkSpeed = script:GetAttribute("WalkSpeed")
	local sprintAnimThreshold = walkSpeed + (sprintSpeed - walkSpeed) * 0.4
	-- Allow walk anim to play during sprint wind-up while speed is still below walk speed.
	-- This prevents the sprint anim from playing in slow-motion at low speeds (floaty look).
	local sprintingButStillSlow = playerCharacter:GetAttribute("Sprinting") and smoothedSpeed < walkSpeed
	if stance ~= 0 or smoothedSpeed > sprintAnimThreshold then
		StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
		currentWalkAnim = nil
		return
	end
	if playerCharacter:GetAttribute("Sprinting") and not sprintingButStillSlow then
		StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
		currentWalkAnim = nil
		return
	end

	local targetAnim = GetDirectionalAnim(walkAnimTable)

	if targetAnim == nil then
		if currentWalkAnim then
			StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
			currentWalkAnim = nil
		end
	elseif targetAnim ~= currentWalkAnim then
		StopAllAnims(allWalkAnims, targetAnim, config.stanceChangeTime)
		if not targetAnim.IsPlaying then
			local s = (humanoid.WalkSpeed / script:GetAttribute("WalkSpeed")) * (walkAnimSpeedMap[targetAnim] or 1.5)
			targetAnim:Play(config.stanceChangeTime)
			targetAnim:AdjustSpeed(s)
		end
		currentWalkAnim = targetAnim
	else
		targetAnim:AdjustSpeed((humanoid.WalkSpeed / script:GetAttribute("WalkSpeed")) * (walkAnimSpeedMap[targetAnim] or 1.5))
	end
end

-- =====================
-- TURN IN PLACE
-- =====================
local function getCurrentYaw(): number
	if not rootPart then return 0 end
	local look = rootPart.CFrame.LookVector
	return math.deg(math.atan2(look.X, look.Z))
end

local function StopAllTurnAnims(transTime: number?)
	local t = transTime or 0.15
	for _, anim in ipairs(allTurnAnims) do
		if anim.IsPlaying then
			anim:Stop(t)
		end
	end
	currentTurnAnim = nil
end

local function UpdateTurnAnim(yawDelta: number)
	if moving then
		StopAllTurnAnims(0.15)
		lastTurnDetectedAt = 0
		accumulatedYaw = 0
		return
	end

	local absDelta = math.abs(yawDelta)
	local now = os.clock()

	-- Ignore micro-jitter (e.g. 1-pixel mouse nudge)
	if absDelta < TURN_JITTER_IGNORE then
		yawDelta = 0
	end

	-- Accumulate yaw; if direction flips, reset so jittery back-and-forth cancels out
	if yawDelta ~= 0 then
		if (accumulatedYaw > 0 and yawDelta < 0) or (accumulatedYaw < 0 and yawDelta > 0) then
			accumulatedYaw = 0
		end
		accumulatedYaw += yawDelta
	end

	-- Decay the accumulator toward zero when no input is coming in
	-- This prevents old leftover yaw from triggering a late anim
	local dt = 1 / 60 -- approximate; good enough for decay
	if yawDelta == 0 then
		if math.abs(accumulatedYaw) <= TURN_ACCUMULATE_DECAY * dt then
			accumulatedYaw = 0
		else
			accumulatedYaw -= math.sign(accumulatedYaw) * TURN_ACCUMULATE_DECAY * dt
		end
	end

	if math.abs(accumulatedYaw) >= TURN_YAW_THRESHOLD then
		lastTurnDetectedAt = now

		local turnRight, turnLeft
		if stance == 0 then
			turnRight = turnInIdleAnim
			turnLeft = turnOutIdleAnim
		elseif stance == 1 then
			turnRight = turnInCrouchAnim
			turnLeft = turnOutCrouchAnim
		elseif stance == 2 then
			turnRight = turnInProneAnim
			turnLeft = turnOutProneAnim
		end

		local targetAnim = (accumulatedYaw > 0) and turnRight or turnLeft

		if not targetAnim then
			StopAllTurnAnims(0.15)
			return
		end

		if targetAnim ~= currentTurnAnim then
			StopAllTurnAnims(0.1)
			if not targetAnim.IsPlaying then
				targetAnim:Play(0.1)
			end
			currentTurnAnim = targetAnim
		end

		-- Keep resetting the accumulator so the anim stays alive during continuous turning
		accumulatedYaw = 0
	else
		if currentTurnAnim and (now - lastTurnDetectedAt) > TURN_ANIM_HOLD_TIME then
			StopAllTurnAnims(0.2)
		end
	end
end

-- =====================
-- STANCE
-- =====================
local function ChangeStance(change, override)
	-- Block stance changes while airborne, landing, winding up a jump, or sprinting
	if not override then
		if IsAirborne() or landingLocked or jumpWindingUp or playerCharacter:GetAttribute("Sprinting") then
			return
		end
		-- No crouching or going prone in the water.
		if change > 0 and SwimController.isSwimming() then
			return
		end
	end

	if canChangeStance or override then
		canChangeStance = false

		local number = stance + change
		if number < 0 then number = 0
		elseif number > 2 then number = 2
		end

		if number == 0 then -- Standing
			script.Parent.CharacterMovement:SetAttribute("DisableLean", false)
			StopAllAnims(allCrouchMoveAnims, nil, config.stanceChangeTime)
			crouchIdleAnim:Stop(config.stanceChangeTime)

			if stance == 2 then
				proneTransitioning = true
				script:SetAttribute("ProneTransitioning", true)
				StopAllAnims(allProneMoveAnims, nil, config.stanceChangeTime)
				local savedCanChange = canChangeWalkSpeed
				canChangeWalkSpeed = false
				TweenWalkSpeed(0, 1.0)
				smoothedSpeed = 0
				proneTransitionUpAnim:Play(0.1)
				proneIdleAnim:Stop(0.1)
				PlayCharSound("Unprone")
				task.delay(1, function()
					proneTransitioning = false
					script:SetAttribute("ProneTransitioning", false)
					canChangeWalkSpeed = savedCanChange
					canChangeStance = true
					if canChangeWalkSpeed then
						-- Don't tween ? let the accel system ramp up naturally
						-- Just ensure smoothedSpeed starts from 0 so it accelerates
					end
				end)
			else
				-- Let accel system handle the speed ramp; no need for TweenWalkSpeed
				PlayCharSound("Uncrouch")
				task.delay(config.stanceChangeTime * 0.7, function() canChangeStance = true end)
			end

			playerCharacter:SetAttribute("Stance", "Standing")
			tweenService:Create(humanoid, TweenInfo.new(config.stanceChangeTime), {HipHeight = 0}):Play()
			if playerCharacter:GetAttribute("HoldingSprint") and not playerCharacter:GetAttribute("Reloading") and not playerCharacter:GetAttribute("Inspecting") and not playerCharacter:GetAttribute("Meleeing") then
				if CanStartSprint() and IsSprintDirectionAllowed() then
					playerCharacter:SetAttribute("Sprinting", true)
					ToggleSprint(true)
				end
			end

		elseif number == 1 then -- Crouching
			script.Parent.CharacterMovement:SetAttribute("DisableLean", false)
			StopAllAnims(allProneMoveAnims, nil, config.stanceChangeTime)
			StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
			if standingIdleAnim then standingIdleAnim:Stop(config.stanceChangeTime) end
			if sprintAnim then sprintAnim:Stop(config.stanceChangeTime) end

			if stance == 2 then
				proneTransitioning = true
				script:SetAttribute("ProneTransitioning", true)
				local savedCanChange = canChangeWalkSpeed
				canChangeWalkSpeed = false
				TweenWalkSpeed(0, 1.0)
				smoothedSpeed = 0
				proneTransitionUpAnim:Play(0.1)
				proneIdleAnim:Stop(0.1)
				PlayCharSound("Unprone")
				task.delay(1, function()
					proneTransitioning = false
					script:SetAttribute("ProneTransitioning", false)
					canChangeWalkSpeed = savedCanChange
					canChangeStance = true
					if stance == 1 then
						crouchIdleAnim:Play(config.stanceChangeTime)
						-- Accel system will ramp to crouch speed naturally
					end
				end)
			else
				crouchIdleAnim:Play(config.stanceChangeTime)
				PlayCharSound("Crouch")
				task.delay(config.stanceChangeTime * 0.7, function() canChangeStance = true end)
			end

			playerCharacter:SetAttribute("Stance", "Crouched")
			playerCharacter:SetAttribute("Sprinting", false)
			tweenService:Create(humanoid, TweenInfo.new(config.stanceChangeTime), {HipHeight = 0}):Play()

		elseif number == 2 then -- Prone
			ChangeLean(0)
			script.Parent.CharacterMovement:SetAttribute("DisableLean", true)
			StopAllAnims(allCrouchMoveAnims, nil, config.stanceChangeTime)
			StopAllAnims(allWalkAnims, nil, config.stanceChangeTime)
			if standingIdleAnim then standingIdleAnim:Stop(config.stanceChangeTime) end
			if sprintAnim then sprintAnim:Stop(config.stanceChangeTime) end
			crouchIdleAnim:Stop(config.stanceChangeTime)

			proneTransitioning = true
			script:SetAttribute("ProneTransitioning", true)
			local savedCanChange = canChangeWalkSpeed
			canChangeWalkSpeed = false
			TweenWalkSpeed(0, 1.0)
			smoothedSpeed = 0
			proneTransitionDownAnim:Play(0.1)
			PlayCharSound("Prone")

			task.delay(0.82, function()
				proneTransitioning = false
				script:SetAttribute("ProneTransitioning", false)
				canChangeWalkSpeed = savedCanChange
				canChangeStance = true
				if stance == 2 then
					proneIdleAnim:Play(config.stanceChangeTime)
					-- Accel system will ramp to prone speed naturally
				end
			end)

			playerCharacter:SetAttribute("Stance", "Prone")
			tweenService:Create(humanoid, TweenInfo.new(config.stanceChangeTime * 1.55), {HipHeight = 0.25}):Play()
		end

		stance = number

		-- Tell the server our stance so it can replicate it to every client
		-- (remote terrain tilt clamps to the correct per-stance max angle).
		local stanceName = (number == 2 and "Prone") or (number == 1 and "Crouched") or "Standing"
		playerStance:Fire(stanceName)
	end
end

local function HandleMovementInput(actionName: string, inputState: EnumItem, inputObject: InputObject)
	local inputBegan = Enum.UserInputState.Begin
	local lean = playerCharacter:GetAttribute("LeanDirection")
	local sprinting = playerCharacter:GetAttribute("Sprinting")
	local equipped = playerCharacter:FindFirstChildWhichIsA("Tool") and playerCharacter:FindFirstChildWhichIsA("Tool"):FindFirstChild("SPH_Weapon")

	-- Tactical lean: HOLD to lean, release to recenter (handles Begin and End).
	if actionName == "SPH_LeanLeft" or actionName == "SPH_LeanRight" then
		local dir = (actionName == "SPH_LeanLeft") and -1 or 1
		if inputState == inputBegan then
			if stance < 2 and not sprinting and not humanoid.Sit and not SwimController.isSwimming() then
				ChangeLean(dir)
			end
		elseif inputState == Enum.UserInputState.End then
			-- Only recenter if the key being released is the one we're leaning into,
			-- so releasing one lean key doesn't cancel a lean held on the other.
			if lean == dir then ChangeLean(0) end
		end
		return
	end

	if actionName == "SPH_Sprint" then
		local sprintHeld = inputState == inputBegan
		playerCharacter:SetAttribute("HoldingSprint", sprintHeld)
		if sprintHeld and stance < 2 and moving then
			if playerCharacter:GetAttribute("Reloading") then return end
			if playerCharacter:GetAttribute("Inspecting") then return end
			if playerCharacter:GetAttribute("Meleeing") then return end
			if CanStartSprint() and IsSprintDirectionAllowed() then
				playerCharacter:SetAttribute("Sprinting", true)
				if stance == 1 then ChangeStance(-1, true) end
				if equipped and moving then ToggleSprint(true) end
				ChangeLean(0)
				-- Accel system handles the ramp ? no need for windupSpeed
			end
		elseif stance == 0 then
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
		end

	elseif inputState == inputBegan then
		if actionName == "SPH_StanceLower" and stance < 2 and not humanoid.Sit then
			if IsAirborne() or landingLocked or jumpWindingUp or sprinting then return end
			if not config.canCrouch and stance == 0 then return end
			if not config.canProne and stance == 1 then return end
			ChangeStance(1)
			if sprinting then ToggleSprint(false) end
		elseif actionName == "SPH_StanceRaise" and stance > 0 then
			if IsAirborne() or landingLocked or jumpWindingUp or sprinting then return end
			ChangeStance(-1)
		end
	end
end

local function BindCharacterInputs()
	contextActionService:BindActionAtPriority("SPH_Sprint", HandleMovementInput, false, config.movementInputPriority, unpack(config.keySprint))
	contextActionService:BindActionAtPriority("SPH_StanceLower", HandleMovementInput, config.mobileButtons, config.movementInputPriority, unpack(config.lowerStance))
	contextActionService:BindActionAtPriority("SPH_StanceRaise", HandleMovementInput, config.mobileButtons, config.movementInputPriority, unpack(config.raiseStance))
	contextActionService:BindActionAtPriority("SPH_LeanLeft", HandleMovementInput, false, config.movementInputPriority, unpack(config.leanLeft))
	contextActionService:BindActionAtPriority("SPH_LeanRight", HandleMovementInput, false, config.movementInputPriority, unpack(config.leanRight))
	contextActionService:SetTitle("SPH_StanceLower", "Crouch")
	contextActionService:SetPosition("SPH_StanceLower", UDim2.fromScale(0.4, 0))
	contextActionService:SetTitle("SPH_StanceRaise", "Stand")
	contextActionService:SetPosition("SPH_StanceRaise", UDim2.fromScale(0.55, -0.25))
end
BindCharacterInputs()

-- Initialised here rather than at the top of the file because the callbacks need
-- ChangeStance / ChangeLean / ToggleSprint, all of which are defined above.
SwimController.init({
	humanoid = humanoid,
	rootPart = rootPart,
	config = config,
	assets = assets,
	callbacks = {
		onEnterSwim = function()
			-- Water forces you upright and disarmed.
			if stance == 2 then
				ChangeStance(-1, true)
				ChangeStance(-1, true)
			elseif stance == 1 then
				ChangeStance(-1, true)
			end
			ChangeLean(0)
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)

			-- Set locally for an instant response, and fire to the server so other
			-- clients see it too (CharacterClient watches this to holster the gun).
			playerCharacter:SetAttribute("Swimming", true)
			playerSwim:Fire(true)
		end,
		onExitSwim = function()
			playerCharacter:SetAttribute("Swimming", false)
			playerSwim:Fire(false)
			-- Climbing out must not register as a fall landing.
			lastLandedTime = os.clock()
			wasFalling = false
		end,
	},
})

local function UnbindCharacterInputs()
	contextActionService:UnbindAction("SPH_Sprint")
	contextActionService:UnbindAction("SPH_StanceLower")
	contextActionService:UnbindAction("SPH_StanceRaise")
	contextActionService:UnbindAction("SPH_LeanLeft")
	contextActionService:UnbindAction("SPH_LeanRight")
end

-- =====================
-- RAW INPUT LISTENERS
-- =====================
userInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if IsSeated() then return end
	-- [Drone] WASD flies the drone while in drone view, not the character
	if playerCharacter:GetAttribute("DroneView") == true then return end
	if input.KeyCode == Enum.KeyCode.W then held.W = true; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.A then held.A = true; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.S then held.S = true; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.D then held.D = true; recomputeInputMag() end
end)

userInputService.InputEnded:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.W then held.W = false; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.A then held.A = false; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.S then held.S = false; recomputeInputMag() end
	if input.KeyCode == Enum.KeyCode.D then held.D = false; recomputeInputMag() end
end)

-- [Drone] Entering drone view: let go of every movement key so the character stops
-- instead of carrying on in whatever direction you were walking.
local function watchDroneView(char)
	char:GetAttributeChangedSignal("DroneView"):Connect(function()
		if char:GetAttribute("DroneView") == true then
			held.W, held.A, held.S, held.D = false, false, false, false
			recomputeInputMag()
		end
	end)
end
watchDroneView(playerCharacter)

-- =====================
-- MAIN LOOP
-- =====================
runService.RenderStepped:Connect(function(deltaTime)
	--[[
		GRABBED BY A CREATURE.

		The creature welds this character's HumanoidRootPart to its arm. A weld only
		wins while nothing else is moving the part -- and the first-person branch of
		this loop assigns rootPart.CFrame outright, every frame. The two fight, and
		the victim tears free of the hand or judders violently in it.

		So while held: stop driving. Move(Vector3.zero) cancels any momentum the
		Humanoid was still carrying into the grab, and returning before the movement
		and rotation code means nothing writes CFrame at all.

		PlatformStand (set server-side) already stops the Humanoid's own physics;
		this is about stopping OUR physics.

		The attribute is set by CreatureGrabServer and cleared on release, including
		on death and on the watchdog path, so this can never latch on.
	--]]
	if playerCharacter:GetAttribute("Grabbed") == true then
		humanoid:Move(Vector3.zero, false)

		--[[
			STOP THE ANIMATIONS TOO, ONCE.

			Returning early stops us DRIVING the character, but it also skips every
			animation decision below � so whatever was playing when the grab landed
			just keeps looping. That's why a grabbed player hung from the creature's
			hand with their legs still pumping through the walk cycle.

			CreatureGrabServer plays a hold pose on the victim at Action4, which beats
			these on any joint it keyframes � but only on the joints it keyframes. A
			hold pose that doesn't touch the legs would still let the walk cycle show
			through underneath, so the movement stack has to actually stop rather than
			be painted over.

			Guarded by grabbedAnimsStopped so this runs on the FIRST grabbed frame and
			not sixty times a second: Stop() on an already-stopped track restarts its
			fade, which would hold every track permanently mid-blend.
		--]]
		if not grabbedAnimsStopped then
			grabbedAnimsStopped = true

			StopAllAnims(allWalkAnims, nil, 0.15)
			StopAllAnims(allCrouchMoveAnims, nil, 0.15)
			StopAllAnims(allProneMoveAnims, nil, 0.15)
			StopAllTurnAnims(0.15)

			currentWalkAnim = nil
			currentCrouchMoveAnim = nil
			currentProneMoveAnim = nil

			if standingIdleAnim then standingIdleAnim:Stop(0.15) end
			if sprintAnim then sprintAnim:Stop(0.15) end
			if crouchIdleAnim then crouchIdleAnim:Stop(0.15) end
			if proneIdleAnim then proneIdleAnim:Stop(0.15) end
			if fallingAnim then fallingAnim:Stop(0.1) end
			if landingAnim then landingAnim:Stop(0.1) end
			if jumpWindupAnim then jumpWindupAnim:Stop(0) end
			if currentIdleEmoteAnim then
				currentIdleEmoteAnim:Stop(0.15)
				currentIdleEmoteAnim = nil
			end

			-- Smoothing state zeroed as well, or the frame you're released replays
			-- the speed and direction you had when you were grabbed and the character
			-- lurches off in whatever direction you were last running.
			smoothedMoveDir = Vector3.zero
			smoothedSpeed = 0
			inputMag = 0
			accumulatedYaw = 0
			lastYaw = nil
		end

		return
	else
		-- Released. Clearing the latch here rather than on the attribute's changed
		-- signal means it can never be left set by a grab that ended while this
		-- script was disabled, respawning, or otherwise not listening.
		grabbedAnimsStopped = false
	end

	movementVector = humanoid.MoveDirection.Magnitude > 0 and humanoid.MoveDirection.Unit or Vector3.zero

	-- =====================
	-- SWIMMING
	-- =====================
	-- Roblox's Humanoid owns the actual swim physics: buoyancy, water drag, sinking
	-- and the Space-to-rise. All we do here is supply the horizontal drive (exactly
	-- how Roblox drives swimming anyway), keep the body facing the right way, and
	-- stop the ground animations from playing over the swim ones.
	-- NOTHING in this branch may write rootPart.CFrame. On the ground that's
	-- harmless -- the Humanoid re-derives your position from the floor each step --
	-- but in water it fights the physics solver and reads as micro-teleporting.
	-- Orientation is handled by an AlignOrientation constraint inside
	-- SwimController, which also cancels the engine's 90-degree swim tilt.
	local isSwimming, swimMoveVector = SwimController.update(
		(held.D and 1 or 0) - (held.A and 1 or 0),
		(held.W and 1 or 0) - (held.S and 1 or 0)
	)
	if isSwimming then
		-- The move vector is fully 3D and camera-relative, which is how Roblox's own
		-- ControlModule drives swimming: look down and hold W to dive. getRawMoveDir()
		-- is deliberately flat, so it is NOT used here.
		humanoid.WalkSpeed = SwimController.getSwimSpeed()
		humanoid:Move(swimMoveVector, false)

		moving = swimMoveVector.Magnitude > 0.01
		smoothedSpeed = humanoid.WalkSpeed
		local flatWish = Vector3.new(swimMoveVector.X, 0, swimMoveVector.Z)
		smoothedWishDir = flatWish
		if flatWish.Magnitude > 0.001 then TUNE.lastMoveDir = flatWish.Unit end

		-- Keep the yaw spring synced to actual facing so stepping back onto land
		-- doesn't snap the body round to a stale heading.
		local fd = rootPart.CFrame.LookVector
		if (fd.X * fd.X + fd.Z * fd.Z) > 0.000001 then
			idleYaw = math.deg(math.atan2(fd.X, fd.Z))
		end
		idleYawVel = 0

		-- Clear ground state so surfacing doesn't fire a landing or fall anim
		idlePivoting = false
		landingLocked = false
		jumpWindingUp = false
		wasFalling = false

		-- Stop anything that was mid-play when we hit the water
		StopAllAnims(allWalkAnims, nil, 0.2)
		StopAllAnims(allCrouchMoveAnims, nil, 0.2)
		StopAllAnims(allProneMoveAnims, nil, 0.2)
		StopAllTurnAnims(0.15)
		if sprintAnim and sprintAnim.IsPlaying then sprintAnim:Stop(0.2) end
		if standingIdleAnim and standingIdleAnim.IsPlaying then standingIdleAnim:Stop(0.2) end
		if crouchIdleAnim and crouchIdleAnim.IsPlaying then crouchIdleAnim:Stop(0.2) end
		if fallingAnim and fallingAnim.IsPlaying then fallingAnim:Stop(0.15) end
		if landingAnim and landingAnim.IsPlaying then landingAnim:Stop(0.15) end
		currentWalkAnim, currentCrouchMoveAnim, currentProneMoveAnim = nil, nil, nil

		-- Stamina still ticks. The WATER_ multipliers you already had now apply.
		-- An exoskeleton stays pinned full even here: a powered frame that quietly
		-- ran out of charge while you swam would be a very confusing bug to hit.
		if HasExoskeleton() then
			stamina = MAX_STAMINA
		else
			stamina = math.min(stamina + TUNE.staminaRegenAmount(REGEN_PER_SEC * WATER_REGEN_MULT, deltaTime), MAX_STAMINA)
		end
		PushStaminaAttrs()
		return
	end

	-- Terrain alignment, for this character and everyone else's.
	if TERRAIN.enabled then
		UpdateCharacterTilt(playerCharacter, deltaTime)
		for _, player in ipairs(players:GetPlayers()) do
			if player ~= localPlayer and player.Character then
				UpdateCharacterTilt(player.Character, deltaTime)
			end
		end
	end

	-- =====================
	-- WALK SPEED ? UNIFIED ACCEL/DECEL SYSTEM
	-- =====================
	-- Slope steepness along the current move direction (0 when flat, crossing, or descending).
	local climbAngle = 0
	do
		local md = TUNE.lastMoveDir
		if rootPart and humanoid.FloorMaterial ~= Enum.Material.Air and md.Magnitude > 0.001 then
			local hit = workspace:Raycast(rootPart.Position, Vector3.new(0, -8, 0), TUNE.slopeRayParams)
			if hit then
				local n = hit.Normal
				local slopeAngle = math.deg(math.acos(math.clamp(n.Y, -1, 1)))
				if slopeAngle > 0.5 then
					local uphill = Vector3.new(-n.X, 0, -n.Z)
					if uphill.Magnitude > 0.001 then
						climbAngle = slopeAngle * math.clamp(md.Unit:Dot(uphill.Unit), 0, 1)
					end
				end
			end
		end
	end

	if canChangeWalkSpeed then
		if not walkSpeedTween then
			-- 1) Determine the target speed for the current state
			local targetWalkSpeed = script:GetAttribute("WalkSpeed")
			if playerCharacter:GetAttribute("Stance") == "Prone" then
				targetWalkSpeed = script:GetAttribute("ProneSpeed")
			elseif playerCharacter:GetAttribute("Stance") == "Crouched" then
				targetWalkSpeed = script:GetAttribute("CrouchSpeed")
			elseif playerCharacter:GetAttribute("Sprinting") then
				if not strafing or (config.canSprintWhileStrafing and strafing) then
					targetWalkSpeed = script:GetAttribute("SprintSpeed")
				end
			end

			if humanoid.Health < 25 and config.lowHealthEffects then
				targetWalkSpeed *= humanoid.Health / 25
			end
			strafing = IsCharacterStrafing(playerCharacter)
			playerCharacter:SetAttribute("Strafing", strafing)
			if strafing then targetWalkSpeed *= strafingMult end

			-- Slope: gradually slow uphill climbs; sprint bleeds back toward walk speed and is
			-- gone by the cutoff angle. Only affects uphill movement (climbAngle is 0 otherwise).
			if climbAngle > TUNE.slopeWalkFullAngle then
				if playerCharacter:GetAttribute("Sprinting") then
					local sprintT = math.clamp((climbAngle - TUNE.slopeSprintFullAngle) / (TUNE.slopeSprintCutoffAngle - TUNE.slopeSprintFullAngle), 0, 1)
					local walkEquivalent = script:GetAttribute("WalkSpeed")
					if strafing then walkEquivalent *= strafingMult end
					targetWalkSpeed = targetWalkSpeed + (walkEquivalent - targetWalkSpeed) * sprintT
				end
				local t = math.clamp((climbAngle - TUNE.slopeWalkFullAngle) / (TUNE.slopeWalkSteepAngle - TUNE.slopeWalkFullAngle), 0, 1)
				targetWalkSpeed *= (1 - t * (1 - TUNE.slopeWalkMinMult))
			end

			-- 2) Target is zero when there's no movement input, so momentum bleeds off via the
			-- decel ramp (coast to a stop) instead of braking. Also zero while turning in place / blocked.
			if inputMag == 0 or idlePivoting or jumpWindingUp or landingLocked then
				targetWalkSpeed = 0
			end

			-- 3) Pick accel or decel rate based on whether we're speeding up or slowing down
			local accelRate, decelRate = getAccelDecel()
			local rate
			if targetWalkSpeed > smoothedSpeed then
				rate = accelRate   -- speeding up
			else
				rate = decelRate   -- slowing down (including stopping)
			end

			-- Landing lock: bleed speed off much faster so we don't float forward
			if landingLocked then
				rate = math.max(rate, TUNE.landingDecel)
			end

			-- 4) Ramp smoothedSpeed toward target
			smoothedSpeed = moveToward(smoothedSpeed, targetWalkSpeed, rate, deltaTime)

			-- 5) Snap to zero if below threshold to prevent eternal micro-drift
			if smoothedSpeed < SPEED_SNAP_THRESHOLD and targetWalkSpeed == 0 then
				smoothedSpeed = 0
			end

			-- 6) Write to humanoid
			humanoid.WalkSpeed = smoothedSpeed
		else
			-- A tween is active (stance transitions use this) ? just track strafing
			strafing = IsCharacterStrafing(playerCharacter)
			playerCharacter:SetAttribute("Strafing", strafing)
			-- Keep smoothedSpeed in sync so there's no jump when tween finishes
			smoothedSpeed = humanoid.WalkSpeed
		end
	else
		-- canChangeWalkSpeed is false (e.g. during prone transition)
		-- Keep smoothedSpeed in sync
		smoothedSpeed = humanoid.WalkSpeed
	end

	-- =====================
	-- SPRINT DIRECTION ENFORCEMENT
	-- =====================
	local isSprinting = playerCharacter:GetAttribute("Sprinting")
	if isSprinting then
		if not CanKeepSprint() then
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
		elseif not IsSprintDirectionAllowed() then
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
		elseif climbAngle >= TUNE.slopeSprintCutoffAngle then
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
		end
	end

	-- =====================
	-- STAMINA UPDATE
	-- =====================
	local activelyDraining = playerCharacter:GetAttribute("Sprinting") and (inputMag > 0)
	local inWater = IsInWater()
	local drainRate = SPRINT_DRAIN_PER_SEC * (inWater and WATER_SPRINT_DRAIN_MULT or 1)
	local regenRate = REGEN_PER_SEC * (inWater and WATER_REGEN_MULT or 1)

	if HasExoskeleton() then
		-- Free sprint. Checked BEFORE the drain rather than by zeroing drainRate,
		-- so the "stamina hit zero, stop sprinting" branch below cannot fire at all
		-- while a frame is worn -- not even on the frame you equip it.
		stamina = MAX_STAMINA
	elseif activelyDraining then
		stamina -= drainRate * deltaTime
		if stamina <= 0 then
			stamina = 0
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
		end
		TUNE.markStaminaUse()
	else
		-- Waits out the pause after the last spend, then ramps up. See TUNE.
		stamina += TUNE.staminaRegenAmount(regenRate, deltaTime)
		if stamina > MAX_STAMINA then stamina = MAX_STAMINA end
	end
	PushStaminaAttrs()

	-- =====================
	-- TURN RADIUS + IDLE PIVOT + humanoid:Move() OVERRIDE
	-- =====================
	local inFirstPerson = IsFirstPersonOrShiftLock()
	local seated = IsSeated()

	if seated then
		if not humanoid.AutoRotate then humanoid.AutoRotate = true end
		smoothedMoveDir = Vector3.zero
		idlePivoting = false
		wasInputLastFrame = false
		moving = false
		-- Force stop all movement anims while seated so WASD doesn't play them
		humanoid:Move(Vector3.zero, false)
		StopAllAnims(allWalkAnims, nil, 0.15)
		StopAllAnims(allCrouchMoveAnims, nil, 0.15)
		StopAllAnims(allProneMoveAnims, nil, 0.15)
		if sprintAnim and sprintAnim.IsPlaying then sprintAnim:Stop(0.15) end
		if standingIdleAnim and standingIdleAnim.IsPlaying then standingIdleAnim:Stop(0.15) end
		currentWalkAnim = nil
		currentCrouchMoveAnim = nil
		currentProneMoveAnim = nil
	else
		if humanoid.AutoRotate then humanoid.AutoRotate = false end

		local rawDir = getRawMoveDir()
		local hasInput = rawDir.Magnitude > 0.001
		local vel = rootPart.AssemblyLinearVelocity
		local actualXZSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		local physicallyMoving = actualXZSpeed > TURN_STOP_THRESHOLD

		if inFirstPerson then
			idlePivoting = false
			wasInputLastFrame = hasInput

			local cam = workspace.CurrentCamera
			if cam then
				local camLook = cam.CFrame.LookVector
				local camXZ = Vector3.new(camLook.X, 0, camLook.Z)
				if camXZ.Magnitude > 0.001 then
					local lookDir = camXZ.Unit
					local up = Vector3.new(0, 1, 0)
					local targetRot = CFrame.lookAt(Vector3.zero, lookDir, up)
					rootPart.CFrame = CFrame.new(rootPart.CFrame.Position) * targetRot
					smoothedMoveDir = lookDir
					idleYaw = math.deg(math.atan2(lookDir.X, lookDir.Z))
					idleYawVel = 0
				end
			end

			if hasInput then
				-- Directional momentum: ease the move vector toward the input instead of
				-- snapping. Only snap when genuinely starting from rest (low smoothedSpeed)
				-- so the speed ramp handles build-up. While already moving we ALWAYS ease --
				-- even through a zero crossing on a full A<->D reversal -- so rapid direction
				-- spam bleeds speed and rebuilds (inertia) instead of teleporting the heading.
				if smoothedSpeed < SPEED_SNAP_THRESHOLD then
					smoothedWishDir = rawDir
				else
					local a = 1 - math.exp(-DIR_RESPONSE * deltaTime)
					smoothedWishDir = smoothedWishDir:Lerp(rawDir, a)
				end
				humanoid:Move(smoothedWishDir, false)
				TUNE.lastMoveDir = rawDir
				moving = true
			elseif smoothedSpeed > SPEED_SNAP_THRESHOLD and TUNE.lastMoveDir.Magnitude > 0.001 and not landingLocked and not jumpWindingUp then
				smoothedWishDir = TUNE.lastMoveDir  -- resync so the next direction eases from the coast heading
				humanoid:Move(TUNE.lastMoveDir, false)  -- coast: ride momentum down to a stop
				moving = true
			else
				smoothedWishDir = Vector3.zero
				humanoid:Move(Vector3.zero, false)
				moving = false
			end

		else
			local justPressedFromIdle = hasInput and not wasInputLastFrame and not physicallyMoving
			if justPressedFromIdle then
				idlePivoting = true
				-- seed the yaw spring from current facing so it springs out from here
				local fd0 = rootPart.CFrame.LookVector
				if (fd0.X * fd0.X + fd0.Z * fd0.Z) > 0.000001 then
					idleYaw = math.deg(math.atan2(fd0.X, fd0.Z))
				end
				idleYawVel = 0
			end
			wasInputLastFrame = hasInput

			if hasInput then
				-- One yaw spring drives ALL third-person turning: the in-place pivot from idle AND
				-- turning while moving. force = displacement*stiffness - velocity*damping (overshoot+settle).
				local targetYaw = math.deg(math.atan2(rawDir.X, rawDir.Z))
				local diff = targetYaw - idleYaw
				if diff > 180 then diff -= 360 elseif diff < -180 then diff += 360 end

				-- Velocity cap: idle-pivot rate while turning in place, the normal per-state
				-- turn rate (getBaseTurnRate) once moving. TUNE stiffness/damping give the bounce.
				local cap = idlePivoting and getIdlePivotRate() or getBaseTurnRate()
				local force = diff * TUNE.idleStiffness - idleYawVel * TUNE.idleDamping
				idleYawVel = math.clamp(idleYawVel + force * deltaTime, -cap, cap)
				idleYaw += idleYawVel * deltaTime
				if idleYaw > 180 then idleYaw -= 360 elseif idleYaw < -180 then idleYaw += 360 end

				local rad = math.rad(idleYaw)
				local newDir = Vector3.new(math.sin(rad), 0, math.cos(rad))
				local up = Vector3.new(0, 1, 0)
				local pos = rootPart.CFrame.Position
				local newCF = CFrame.lookAt(pos, pos + newDir, up)
				rootPart.CFrame = CFrame.new(pos) * (newCF - newCF.Position)
				smoothedMoveDir = newDir

				-- From idle: turn in place until roughly facing, then commit to moving.
				-- Already moving: keep moving and let the spring steer the body as you turn.
				if idlePivoting and math.abs(diff) > TUNE.idleMoveThreshold then
					humanoid:Move(Vector3.zero, false)
					moving = false
				else
					idlePivoting = false
					humanoid:Move(newDir, false)
					TUNE.lastMoveDir = newDir
					moving = true
				end
			else
				-- Idle / brief release: keep the spring synced to actual facing.
				idlePivoting = false
				idleYawVel = 0
				local fd = rootPart.CFrame.LookVector
				if (fd.X * fd.X + fd.Z * fd.Z) > 0.000001 then
					idleYaw = math.deg(math.atan2(fd.X, fd.Z))
				end

				-- COAST: keep walking in the last move direction while WalkSpeed (momentum) bleeds
				-- off, so you decelerate to a stop instead of braking. Walk anim slows with WalkSpeed.
				if smoothedSpeed > SPEED_SNAP_THRESHOLD and TUNE.lastMoveDir.Magnitude > 0.001 and not landingLocked and not jumpWindingUp then
					humanoid:Move(TUNE.lastMoveDir, false)
					smoothedMoveDir = TUNE.lastMoveDir
					moving = true
				else
					smoothedMoveDir = Vector3.zero
					humanoid:Move(Vector3.zero, false)
					moving = false
				end
			end
		end
	end

	-- Landing lock: kill residual horizontal momentum so the character plants on
	-- landing instead of floating/sliding forward (e.g. after a sprint jump).
	if landingLocked and rootPart then
		local v = rootPart.AssemblyLinearVelocity
		local factor = math.clamp(1 - TUNE.landingVelDamp * deltaTime, 0, 1)
		rootPart.AssemblyLinearVelocity = Vector3.new(v.X * factor, v.Y, v.Z * factor)
	end

	-- Re-engage sprint (blocked while reloading, inspecting, or meleeing)
	if not playerCharacter:GetAttribute("Sprinting") and playerCharacter:GetAttribute("HoldingSprint") and moving and inputMag > 0 and climbAngle < TUNE.slopeSprintCutoffAngle and stance == 0 and not playerCharacter:GetAttribute("Reloading") and not playerCharacter:GetAttribute("Inspecting") and not playerCharacter:GetAttribute("Meleeing") then
		if CanStartSprint() and IsSprintDirectionAllowed() then
			playerCharacter:SetAttribute("Sprinting", true)
			ToggleSprint(true)
		end
	end

	if (not moving or inputMag == 0) and playerCharacter:GetAttribute("Sprinting") then
		playerCharacter:SetAttribute("Sprinting", false)
		ToggleSprint(false)
	end

	UpdateProneMoveAnim()
	UpdateCrouchMoveAnim()
	UpdateWalkAnim()

	-- Crouch idle
	if stance == 1 and not IsSeated() then
		if not moving and not crouchIdleAnim.IsPlaying then
			crouchIdleAnim:Play(config.stanceChangeTime)
		elseif moving and crouchIdleAnim.IsPlaying then
			crouchIdleAnim:Stop(config.stanceChangeTime)
		end
	end

	-- Standing idle
	if standingIdleAnim then
		if stance == 0 and not playerCharacter:GetAttribute("Sprinting") and not IsSeated() then
			if not moving and not standingIdleAnim.IsPlaying then
				standingIdleAnim:Play(config.stanceChangeTime)
			elseif moving and standingIdleAnim.IsPlaying then
				standingIdleAnim:Stop(config.stanceChangeTime)
			end
		elseif standingIdleAnim.IsPlaying then
			standingIdleAnim:Stop(config.stanceChangeTime)
		end
	end

	-- Idle look-around emotes: only while standing still, unarmed, with no tool equipped
	if #idleEmoteAnims > 0 then
		local hasToolEquipped = playerCharacter:FindFirstChildWhichIsA("Tool") ~= nil
		local idleEligible = stance == 0
			and not moving
			and not playerCharacter:GetAttribute("Sprinting")
			and not IsSeated()
			and not hasToolEquipped

		if idleEligible then
			if currentIdleEmoteAnim then
				if not currentIdleEmoteAnim.IsPlaying then
					currentIdleEmoteAnim:Stop(0.3)
					currentIdleEmoteAnim = nil
				end
			else
				idleEmoteTimer += deltaTime
				if idleEmoteTimer >= idleEmoteThreshold then
					idleEmoteTimer = 0
					idleEmoteThreshold = IDLE_EMOTE_MIN_TIME + math.random() * (IDLE_EMOTE_MAX_TIME - IDLE_EMOTE_MIN_TIME)
					local anim = idleEmoteAnims[math.random(1, #idleEmoteAnims)]
					currentIdleEmoteAnim = anim
					anim:Play(0.2)
				end
			end
		else
			idleEmoteTimer = 0
			if currentIdleEmoteAnim then
				currentIdleEmoteAnim:Stop(0.15)
				currentIdleEmoteAnim = nil
			end
		end
	end

	-- Sprint anim
	if sprintAnim then
		local sprintSpeed = script:GetAttribute("SprintSpeed")
		local walkSpeed = script:GetAttribute("WalkSpeed")
		local sprintAnimThreshold = walkSpeed + (sprintSpeed - walkSpeed) * 0.4
		-- Don't start sprint anim until speed has actually reached walk speed.
		-- This lets the walk anim cover the wind-up phase so it doesn't look floaty.
		local sprintingButStillSlow = playerCharacter:GetAttribute("Sprinting") and smoothedSpeed < walkSpeed
		local shouldPlaySprint = stance == 0 and moving and not IsSeated() and not sprintingButStillSlow and (playerCharacter:GetAttribute("Sprinting") or smoothedSpeed > sprintAnimThreshold)
		if shouldPlaySprint then
			if not sprintAnim.IsPlaying then
				sprintAnim:Play(config.stanceChangeTime)
			end
			local baseSprintAnimSpeed = (humanoid.WalkSpeed / sprintSpeed) * SPRINT_ANIM_SPEED
			if IsAirborne() then
				sprintAnim:AdjustSpeed(baseSprintAnimSpeed * 0.15)
			else
				sprintAnim:AdjustSpeed(baseSprintAnimSpeed)
			end
		elseif sprintAnim.IsPlaying then
			sprintAnim:Stop(config.stanceChangeTime)
		end
	end

	-- =====================
	-- FALLING ANIM & JUMP LANDING COOLDOWN
	-- =====================
	do
		local airborne = IsAirborne()
		local sprintAnimActive = sprintAnim and sprintAnim.IsPlaying
		local isSprinting = playerCharacter:GetAttribute("Sprinting")

		-- Track when we first become airborne
		if airborne and not wasFalling then
			airborneStartTime = os.clock()
		end

		local airborneTime = airborne and (os.clock() - airborneStartTime) or 0
		local prolongedFall = airborneTime >= PROLONGED_FALL_THRESHOLD

		-- For crouch/prone: suppress fall anim for short falls, but play it on prolonged falls.
		-- For sprint: suppress fall anim if sprint anim is still active AND fall is short.
		-- On prolonged fall in any of these states: force to standing, stop sprint, play fall anim.
		local inLowStance = stance == 1 or stance == 2
		local suppressForStance = inLowStance and not prolongedFall
		local suppressForSprint = didSprintJump and sprintAnimActive and not prolongedFall

		local suppressFalling = suppressForStance or suppressForSprint

		-- Prolonged fall while crouched/prone: force back to standing
		if airborne and prolongedFall and inLowStance then
			if stance == 2 then
				ChangeStance(-1, true) -- prone -> crouch
				ChangeStance(-1, true) -- crouch -> standing
			elseif stance == 1 then
				ChangeStance(-1, true) -- crouch -> standing
			end
		end

		-- Prolonged fall while sprinting: cancel sprint
		if airborne and prolongedFall and isSprinting then
			playerCharacter:SetAttribute("Sprinting", false)
			ToggleSprint(false)
			didSprintJump = false
		end

		-- Track whether the falling anim was actually playing before we land.
		-- This prevents landing anim from firing after micro-airborne moments
		-- (running down slopes, small bumps) where the fall was too brief to matter.
		local fallingAnimWasPlaying = fallingAnim and fallingAnim.IsPlaying

		if fallingAnim then
			if airborne and not wasFalling and not jumpWindingUp then
				if not suppressFalling then
					fallingAnim:Play(0.15)
				end
			elseif airborne and not suppressFalling and not fallingAnim.IsPlaying and not jumpWindingUp then
				-- Sprint anim stopped mid-air, or stance cleared after prolonged fall ? transition to falling
				fallingAnim:Play(0.15)
			elseif airborne and suppressFalling and fallingAnim.IsPlaying then
				-- Sprint anim took over or low stance is still active ? stop falling anim
				fallingAnim:Stop(0.15)
			elseif not airborne and wasFalling then
				fallingAnim:Stop(0.15)
				lastLandedTime = os.clock()
				jumpOnCooldown = true

				-- Landing anim: only if the falling anim was actually playing (real fall, not a micro-bump)
				-- Skip landing anim if still sprinting (short sprint jump that didn't trigger prolonged)
				if fallingAnimWasPlaying and landingAnim and stance == 0 and not playerCharacter:GetAttribute("Sprinting") then
					landingLocked = true
					playerCharacter:SetAttribute("LandingLocked", true)
					landingAnim:Play(0.05)

					-- Lock walkspeed to 0 smoothly via the accel system
					-- landingLocked flag is checked in the walk speed section

					task.delay(LANDING_LOCK_DURATION, function()
						landingLocked = false
						if landingAnim then
							playerCharacter:SetAttribute("LandingLocked", false)
							landingAnim:Stop(0.15)
						end
					end)
				end

				didSprintJump = false
			end
		end

		-- Track landing even without falling anim
		if not airborne and wasFalling then
			if not fallingAnim then
				lastLandedTime = os.clock()
				jumpOnCooldown = true

				-- Without a falling anim we can't tell if it was a real fall,
				-- so skip landing anim to avoid false triggers from micro-bumps
			end
			didSprintJump = false
		end

		wasFalling = airborne
	end

	-- Clear jump cooldown once enough time has passed since landing
	if jumpOnCooldown and not IsAirborne() and not jumpWindingUp then
		if (os.clock() - lastLandedTime) >= JUMP_LANDING_COOLDOWN then
			jumpOnCooldown = false
		end
	end

	-- =====================
	-- PRONE MATERIAL SOUNDS
	-- =====================
	if stance == 2 and moving and not proneTransitioning then
		local now = os.clock()
		if now - lastProneSoundTime >= PRONE_CRAWL_SOUND_INTERVAL then
			lastProneSoundTime = now
			PlayProneCrawlSound()
		end
	end

	-- Turn in place anims
	local curYaw = getCurrentYaw()
	local yawDelta = 0
	if lastYaw ~= nil then
		yawDelta = curYaw - lastYaw
		if yawDelta > 180 then yawDelta -= 360 end
		if yawDelta < -180 then yawDelta += 360 end
	end
	lastYaw = curYaw
	UpdateTurnAnim(yawDelta)
end)

humanoid.Seated:Connect(function(seated, seatPart)
	if seated then
		UnbindCharacterInputs()
		ToggleSprint(false)
		ChangeLean(0)
		humanoid.AutoRotate = true
		smoothedMoveDir = Vector3.zero
		idlePivoting = false
		wasInputLastFrame = false
		held.W, held.A, held.S, held.D = false, false, false, false
		inputMag = 0
		smoothedSpeed = 0
		moving = false
		StopAllTurnAnims(0.1)
		lastYaw = nil
		accumulatedYaw = 0
		if playerCharacter:GetAttribute("Stance") == "Crouched" then
			ChangeStance(-1, true)
		elseif playerCharacter:GetAttribute("Stance") == "Prone" then
			ChangeStance(-1, true)
			ChangeStance(-1, true)
		end
		-- Stop all movement/idle anims
		StopAllAnims(allWalkAnims, nil, 0.2)
		StopAllAnims(allCrouchMoveAnims, nil, 0.2)
		StopAllAnims(allProneMoveAnims, nil, 0.2)
		if sprintAnim and sprintAnim.IsPlaying then sprintAnim:Stop(0.2) end
		if standingIdleAnim and standingIdleAnim.IsPlaying then
			standingIdleAnim:Stop(0.2)
		end
		if crouchIdleAnim and crouchIdleAnim.IsPlaying then
			crouchIdleAnim:Stop(0.2)
		end
		if currentIdleEmoteAnim then
			currentIdleEmoteAnim:Stop(0.2)
			currentIdleEmoteAnim = nil
		end
		idleEmoteTimer = 0
		currentWalkAnim = nil
		currentCrouchMoveAnim = nil
		currentProneMoveAnim = nil
		-- Play sit anim
		if sitAnim and not sitAnim.IsPlaying then
			sitAnim:Play(0.25)
		end
		-- Force stop movement
		humanoid:Move(Vector3.zero, false)
	else
		-- Stop sit anim on unseat
		if sitAnim and sitAnim.IsPlaying then
			sitAnim:Stop(0.25)
		end
		humanoid.AutoRotate = false
		smoothedMoveDir = Vector3.zero
		idlePivoting = false
		wasInputLastFrame = false
		held.W, held.A, held.S, held.D = false, false, false, false
		inputMag = 0
		moving = false
		BindCharacterInputs()
	end
end)

humanoid.Died:Connect(function()
	SwimController.reset()
	holdingUp = false
	stamina = MAX_STAMINA
	PushStaminaAttrs()
	humanoid.AutoRotate = true
	held.W, held.A, held.S, held.D = false, false, false, false
	inputMag = 0
	smoothedMoveDir = Vector3.zero
	smoothedSpeed = 0
	idlePivoting = false
	jumpWindingUp = false
	playerCharacter:SetAttribute("JumpWindingUp", false)
	jumpOnCooldown = false
	wasFalling = false
	didSprintJump = false
	airborneStartTime = 0
	landingLocked = false
	justUnseated = false
	lastLandedTime = -999
	playerCharacter:SetAttribute("LandingLocked", false)
	if jumpWindupAnim then jumpWindupAnim:Stop(0) end
	if fallingAnim then fallingAnim:Stop(0) end
	if landingAnim then landingAnim:Stop(0) end
	if sitAnim then sitAnim:Stop(0) end
	StopAllTurnAnims(0)
	lastYaw = nil
	accumulatedYaw = 0
end)

script:GetAttributeChangedSignal("CanChangeWalkSpeed"):Connect(function()
	canChangeWalkSpeed = script:GetAttribute("CanChangeWalkSpeed")
end)
