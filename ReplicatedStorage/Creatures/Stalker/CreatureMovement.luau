-- CreatureMovement
-- CLASS: LocalScript
-- PLACE IN: the creature rig Model (direct child, sibling of Humanoid)
--
-- Ported from CharacterMovement with everything the creature doesn't have removed:
-- no crouch, no prone, no sprint, no stamina, no jumping, no swimming, no sitting,
-- no weapons, no BridgeNet / SPH_Assets / GameConfig dependencies. Fully standalone.
--
-- What it keeps from the original:
--   * raw WASD tracking + camera-relative move direction
--   * the yaw spring (turn in place from idle, spring-steered turning while moving)
--   * accel / decel WalkSpeed ramping with coast-to-stop
--   * directional momentum in first person / shift lock
--   * body lean and terrain alignment through RootJoint.C0
--   * 8-way directional walk anims with speed-matched playback
--   * turn-in-place anims driven by accumulated yaw
--   * uphill slope slowdown
--   * falling / landing anims and the landing momentum kill
--   * idle emotes
--
-- THIS REPLACES THE RIG'S Animate SCRIPT. Delete Animate from the rig, or set
-- Enabled = false on it ? running both fights over the same tracks.
--
-- Because it lives inside the rig, it exists only while the player is the creature
-- and dies with the morph. Nothing to guard, nothing to clean up.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ContentProvider = game:GetService("ContentProvider")

local character: Model = script.Parent
local localPlayer = Players.LocalPlayer

-- =====================
-- RIG RESOLUTION
-- =====================
-- WaitForChild(name, timeout) returns nil on timeout instead of throwing, so an
-- incomplete rig normally errors on the NEXT line and names the wrong thing.
-- This reports the part that's actually missing, then keeps waiting so a late
-- part still recovers instead of leaving the creature dead for its whole life.
local function requirePart(parent: Instance, name: string): Instance?
	local found = parent:WaitForChild(name, 20)
	if found then
		return found
	end

	warn(("[CreatureMovement] '%s' still has no '%s' after 20s ? the creature rig "):format(parent.Name, name)
		.. "loaded incomplete. Movement stays disabled until it appears. Check the rig "
		.. "template in ReplicatedStorage.Creatures.")

	while parent.Parent and not found do
		found = parent:WaitForChild(name, 5)
	end
	return found
end

local humanoid: Humanoid = requirePart(character, "Humanoid") :: any
local rootPart: BasePart = requirePart(character, "HumanoidRootPart") :: any
if not (humanoid and rootPart) then return end

local rootJoint: Motor6D = requirePart(rootPart, "RootJoint") :: any
if not rootJoint then return end

local animator: Animator = requirePart(humanoid, "Animator") :: any
if not animator then return end

-- Both of these are OPTIONAL, so a bare default R6 rig with nothing added still
-- moves. Missing config means every value falls back to the `or` defaults used
-- throughout this script; missing animations means it drives the body correctly
-- and simply plays nothing.
local config = {}
do
	local module = character:WaitForChild("CreatureConfig", 3)
	if module and module:IsA("ModuleScript") then
		local ok, userCfg = pcall(require, module)
		if ok and typeof(userCfg) == "table" then
			config = userCfg
		else
			warn("[CreatureMovement] CreatureConfig failed to load; using defaults.")
		end
	end
end

-- Read once rather than inline, because this is the one setting whose default is
-- TRUE ? `if config.movementLeaning then` would silently disable leaning on a rig
-- that simply has no config.
local leanEnabled = (config.movementLeaning ~= false)

local animFolder = character:WaitForChild("Animations", 3)

-- Kill the default / leftover Animate script if one is still around.
local oldAnimate = character:FindFirstChild("Animate")
if oldAnimate and oldAnimate:IsA("BaseScript") then
	oldAnimate.Enabled = false
	oldAnimate:Destroy()
end

-- Preload so the first play of any track doesn't hitch while keyframes stream in.
task.spawn(function()
	if not animFolder then
		return
	end
	local toPreload = {}
	for _, a in ipairs(animFolder:GetDescendants()) do
		if a:IsA("Animation") then
			table.insert(toPreload, a)
		end
	end
	if #toPreload > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(toPreload)
		end)
	end
end)

-- =====================
-- HUMANOID LOCKDOWN
-- =====================
-- No jumping, no climbing, no sitting. Disabling the states is what actually stops
-- them; zeroing JumpPower alone still plays the jump state on some rigs.
humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
humanoid.UseJumpPower = true
humanoid.JumpPower = 0
humanoid.AutoRotate = false -- rotation is handled manually by the yaw spring below

-- Is this rig still the body the player is actually driving?
--
-- ContextActionService bindings are NOT removed when the script that made them is
-- destroyed. This script dies with the rig, so its unbind calls are racing its own
-- destruction ? and if they lose, a binding survives with no script behind it.
-- That is how a dead creature ends up swallowing the human character's Space key
-- for the rest of the session.
--
-- So every handler asks this first. A leaked binding then passes the input
-- through instead of eating it, and the leak becomes harmless rather than fatal.
local function isActiveBody(): boolean
	return character.Parent ~= nil
		and localPlayer.Character == character
		and humanoid.Health > 0
end

-- Swallow the jump input entirely so nothing else picks it up.
ContextActionService:BindActionAtPriority("Creature_BlockJump", function()
	if not isActiveBody() then
		return Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Sink
end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)

-- =====================
-- TUNING / STATE
-- =====================
local c0Ref = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0)

local TUNE = {
	turnRateWalk = config.turnRateWalk or 300,
	turnRateAir = config.turnRateAir or 140,
	idlePivotRate = config.idlePivotRate or 260,
	idleStiffness = config.idleStiffness or 70,
	idleDamping = config.idleDamping or 11,
	idleMoveThreshold = config.idleMoveThreshold or 55,
	stopThreshold = config.turnSpeedStopThreshold or 0.8,
	dirResponse = config.dirResponse or 9,
	accel = config.accelWalk or 20,
	decel = config.decelWalk or 26,
	snap = config.speedSnapThreshold or 0.5,
	strafeMult = config.strafeSpeedMultiplier or 0.85,
	aimSpeedMult = config.throwAimSpeedMultiplier or 0.45,
	slopeFull = config.slopeFullAngle or 12,
	slopeSteep = config.slopeSteepAngle or 45,
	slopeMin = config.slopeMinMult or 0.65,
	landingDecel = config.landingDecel or 80,
	landingVelDamp = config.landingVelocityDamp or 9,
	landingLock = config.landingLockDuration or 0.5,
	prolongedFall = config.prolongedFallThreshold or 0.35,
	blend = config.animBlendTime or 0.2,

	-- Sprint. Every one of these is lower than its walk counterpart on purpose ?
	-- that difference IS the weight. See CreatureConfig for what each one does.
	sprintSpeed = config.sprintSpeed or 13.5,
	accelSprint = config.accelSprint or 9,
	decelSprint = config.decelSprint or 14,
	turnRateSprint = config.turnRateSprint or 150,
	sprintStiffness = config.sprintStiffness or 45,
	sprintDamping = config.sprintDamping or 9,
	sprintLeanMult = config.sprintLeanMult or 1.6,
	sprintAnimMult = config.sprintAnimSpeedMultiplier or 1.0,
	sprintMaxTurnAngle = config.sprintMaxTurnAngle or 60,
	sprintSlopeCutoff = config.sprintSlopeCutoffAngle or 30,
	sprintMinSpeedToStart = config.sprintMinSpeedToStart or 3,

	lastMoveDir = Vector3.zero,
}
TUNE.slopeRayParams = RaycastParams.new()
TUNE.slopeRayParams.FilterType = Enum.RaycastFilterType.Exclude
TUNE.slopeRayParams.FilterDescendantsInstances = { character }
TUNE.slopeRayParams.IgnoreWater = true

local TERRAIN = {
	enabled = (config.terrainAlign ~= false),
	maxAngle = config.terrainAlignMaxAngle or 10,
	rayLength = config.terrainAlignRayLength or 8,
}
TERRAIN.rayParams = RaycastParams.new()
TERRAIN.rayParams.FilterType = Enum.RaycastFilterType.Exclude
TERRAIN.rayParams.FilterDescendantsInstances = { character }
TERRAIN.rayParams.IgnoreWater = true

--[[
	WHATEVER IS IN THE HAND ISN'T GROUND.

	Both rays above point straight down from the root, and a body dangling from
	the arm swings through exactly that space. Hitting it made the terrain tilt
	lean the creature toward a limb and the slope check slow it down "uphill" on a
	leg -- the creature wobbling and dragging while carrying. So the held body is
	added to the filter for as long as it's held.

	Found through the hold CreatureGrabServer puts on the Right Arm: an
	AlignPosition whose Attachment0 sits on the held part (a living victim, or a
	corpse after a kill).
--]]
local HOLD_NAMES = { "CreatureGrabWeld", "CreatureCorpseWeld" }
local rightArm = character:FindFirstChild("Right Arm")
local filteredBody: Model? = nil

local function findHeldBody(): Model?
	if not (rightArm and rightArm.Parent) then
		rightArm = character:FindFirstChild("Right Arm")
		if not rightArm then
			return nil
		end
	end
	for _, name in ipairs(HOLD_NAMES) do
		local hold = rightArm:FindFirstChild(name)
		local grip = hold and hold:IsA("AlignPosition") and hold.Attachment0
		local model = grip and grip.Parent and grip.Parent:FindFirstAncestorOfClass("Model")
		if model and model ~= character then
			return model
		end
	end
	return nil
end

-- Only rewrites the filters when what's held changes, not every frame.
local function updateRayFilters()
	local body = findHeldBody()
	if body == filteredBody then
		return
	end
	filteredBody = body
	local list = body and { character, body } or { character }
	TUNE.slopeRayParams.FilterDescendantsInstances = list
	TERRAIN.rayParams.FilterDescendantsInstances = list
end

local maxTiltAngle = config.maxLeanAngle or 0.18

-- runtime state
local held = { W = false, A = false, S = false, D = false }
local inputMag = 0
local movementVector = Vector3.zero
local moving = false
local strafing = false
local sprinting = false      -- actually sprinting right now
local holdingSprint = false  -- the key is down; sprint may still be refused
local smoothedSpeed = 0
local smoothedWishDir = Vector3.zero
local smoothedMoveDir = Vector3.zero
local idlePivoting = false
local wasInputLastFrame = false
local idleYaw = 0
local idleYawVel = 0
local landingLocked = false
local wasFalling = false
local airborneStartTime = 0

local function recomputeInputMag()
	local x = (held.D and 1 or 0) - (held.A and 1 or 0)
	local z = (held.W and 1 or 0) - (held.S and 1 or 0)
	inputMag = math.clamp(math.sqrt(x * x + z * z), 0, 1)
end

local function getRawMoveDir(): Vector3
	local rawX = (held.D and 1 or 0) - (held.A and 1 or 0)
	local rawZ = (held.S and 1 or 0) - (held.W and 1 or 0)
	if rawX == 0 and rawZ == 0 then
		return Vector3.zero
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return Vector3.new(rawX, 0, rawZ).Unit
	end

	local cf = cam.CFrame
	local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	if forward.Magnitude > 0.001 then forward = forward.Unit end
	if right.Magnitude > 0.001 then right = right.Unit end

	local dir = (forward * -rawZ) + (right * rawX)
	if dir.Magnitude > 0.001 then
		return dir.Unit
	end
	return Vector3.zero
end

-- True when the BODY should be locked to the camera (strafing, camera-relative
-- facing) rather than turning to face where it's going.
--
-- The original checked `MouseBehavior == LockCenter`, because in that game a
-- center-locked mouse only ever meant shift lock. The creature center-locks the
-- mouse just to get free-look without holding right-click, which is a camera
-- decision and says nothing about the body ? so testing MouseBehavior here would
-- put the creature permanently in strafe mode and hand rootPart.CFrame to the
-- camera every frame, fighting the yaw spring.
--
-- So: real first person only (camera inside the head), plus an explicit config
-- opt-in. With cameraMinZoom at 3 the first-person branch can't trigger anyway,
-- which is what keeps the yaw spring in charge of all turning.
local function IsBodyLockedToCamera(): boolean
	if config.bodyFollowsCamera == true then
		return true
	end
	-- Aiming a throw (set by the Arm system): face where you're aiming, and strafe,
	-- like shift lock. The camera goes over the shoulder at the same time.
	if character:GetAttribute("ThrowAiming") == true then
		return true
	end
	local cam = workspace.CurrentCamera
	if cam then
		local head = character:FindFirstChild("Head")
		if head and (cam.CFrame.Position - head.Position).Magnitude < 1 then
			return true
		end
	end
	return false
end

local function IsAirborne(): boolean
	local st = humanoid:GetState()
	return st == Enum.HumanoidStateType.Freefall
		or st == Enum.HumanoidStateType.FallingDown
		or st == Enum.HumanoidStateType.Jumping
end

-- =====================
-- ANIMATIONS
-- =====================
local movPriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action2 or Enum.AnimationPriority.Movement
local idlePriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action or Enum.AnimationPriority.Idle
local fallPriority = config.useHigherAnimPriority and Enum.AnimationPriority.Action3 or Enum.AnimationPriority.Action2

local function loadAnim(name: string, looped: boolean, priority): AnimationTrack?
	if not animFolder then
		return nil
	end
	local a = animFolder:FindFirstChild(name)
	if not a or not a:IsA("Animation") then
		return nil
	end
	local track = animator:LoadAnimation(a)
	track.Looped = looped
	track.Priority = priority
	return track
end

local ANIM = {
	idle = loadAnim("StandingIdle", true, idlePriority),
	forward = loadAnim("WalkForward", true, movPriority),
	backward = loadAnim("WalkBackward", true, movPriority),
	left = loadAnim("WalkLeft", true, movPriority),
	right = loadAnim("WalkRight", true, movPriority),
	leftDiag = loadAnim("WalkLeftDiagonal", true, movPriority),
	leftDiagRev = loadAnim("WalkLeftDiagonalReverse", true, movPriority),
	rightDiag = loadAnim("WalkRightDiagonal", true, movPriority),
	rightDiagRev = loadAnim("WalkRightDiagonalReverse", true, movPriority),
	sprint = loadAnim("Sprint", true, movPriority),
	turnIn = loadAnim("TurnInIdle", true, movPriority),
	turnOut = loadAnim("TurnOutIdle", true, movPriority),
	falling = loadAnim("Falling", true, fallPriority),
	landing = loadAnim("Landing", false, fallPriority),
}

local allWalkAnims = {}
for _, key in ipairs({ "forward", "backward", "left", "right", "leftDiag", "leftDiagRev", "rightDiag", "rightDiagRev" }) do
	if ANIM[key] then
		table.insert(allWalkAnims, ANIM[key])
	end
end

-- Everything that can be the current movement animation, sprint included. The
-- stop-all pass has to cover the sprint cycle too, or crossing the sprint
-- threshold leaves the walk cycle playing underneath it.
local allMoveAnims = table.clone(allWalkAnims)
if ANIM.sprint then
	table.insert(allMoveAnims, ANIM.sprint)
end

local allTurnAnims = {}
if ANIM.turnIn then table.insert(allTurnAnims, ANIM.turnIn) end
if ANIM.turnOut then table.insert(allTurnAnims, ANIM.turnOut) end

local baseAnimSpeed = config.walkAnimSpeed or 1.0
local walkAnimSpeedMap = {}
do
	local perDir = {
		{ ANIM.forward,      config.walkAnimSpeed_Forward },
		{ ANIM.backward,     config.walkAnimSpeed_Backward },
		{ ANIM.left,         config.walkAnimSpeed_Left },
		{ ANIM.right,        config.walkAnimSpeed_Right },
		{ ANIM.leftDiag,     config.walkAnimSpeed_LeftDiag },
		{ ANIM.leftDiagRev,  config.walkAnimSpeed_LeftDiagRev },
		{ ANIM.rightDiag,    config.walkAnimSpeed_RightDiag },
		{ ANIM.rightDiagRev, config.walkAnimSpeed_RightDiagRev },
	}
	for _, e in ipairs(perDir) do
		if e[1] then
			walkAnimSpeedMap[e[1]] = e[2] or baseAnimSpeed
		end
	end
end

-- idle emotes (IdleEmote1, IdleEmote2, ... ? as many as you add)
local idleEmoteAnims: { AnimationTrack } = {}
do
	local i = 1
	while true do
		local t = loadAnim("IdleEmote" .. i, false, movPriority)
		if not t then break end
		table.insert(idleEmoteAnims, t)
		i += 1
	end
end
local IDLE_EMOTE_MIN = config.idleEmoteMinTime or 8
local IDLE_EMOTE_MAX = config.idleEmoteMaxTime or 35
local idleEmoteTimer = 0
local idleEmoteThreshold = IDLE_EMOTE_MIN + math.random() * (IDLE_EMOTE_MAX - IDLE_EMOTE_MIN)
local currentIdleEmote: AnimationTrack? = nil

local currentWalkAnim: AnimationTrack? = nil
local currentTurnAnim: AnimationTrack? = nil

local function StopAllAnims(list, except, transTime)
	for _, anim in ipairs(list) do
		if anim ~= except and anim.IsPlaying then
			anim:Stop(transTime or TUNE.blend)
		end
	end
end

-- =====================
-- BODY TILT (lean + terrain), applied through RootJoint.C0
-- =====================
local function ComputeTerrainTilt(): CFrame
	if humanoid.FloorMaterial == Enum.Material.Air then
		return CFrame.identity
	end
	local hit = workspace:Raycast(rootPart.Position, Vector3.new(0, -TERRAIN.rayLength, 0), TERRAIN.rayParams)
	if not hit then
		return CFrame.identity
	end

	local localN = rootPart.CFrame:VectorToObjectSpace(hit.Normal)
	local angle = math.acos(math.clamp(localN.Y, -1, 1))
	if angle < 1e-4 then
		return CFrame.identity
	end

	local axis = Vector3.yAxis:Cross(localN)
	if axis.Magnitude < 1e-5 then
		return CFrame.identity
	end
	axis = axis.Unit
	angle = math.min(angle, math.rad(TERRAIN.maxAngle))

	local align = CFrame.fromAxisAngle(axis, angle)
	return c0Ref:Inverse() * align * c0Ref
end

local function UpdateTilt(deltaTime: number)
	if humanoid.Health <= 0 then return end

	local currentTilt = c0Ref:Inverse() * rootJoint.C0

	local leanTarget = CFrame.identity
	if leanEnabled then
		-- Sprinting leans the body further into the movement. A heavy thing throws
		-- its mass forward to accelerate; this is the most readable single cue
		-- that the creature is now committed to a direction.
		local tiltAmount = maxTiltAngle * (sprinting and TUNE.sprintLeanMult or 1)
		local md = rootPart.CFrame:VectorToObjectSpace(humanoid.MoveDirection)
		leanTarget = CFrame.Angles(math.rad(-md.Z) * tiltAmount, math.rad(-md.X) * tiltAmount, 0)
	end

	local terrainTarget = CFrame.identity
	if TERRAIN.enabled then
		terrainTarget = ComputeTerrainTilt()
	end

	local target = terrainTarget * leanTarget
	local tilt = currentTilt:Lerp(target, 0.2 ^ (1 / (deltaTime * 60)))
	rootJoint.C0 = c0Ref * tilt
end

-- =====================
-- WALK ANIM SELECTION
-- =====================
-- Should the dedicated sprint cycle be playing right now?
--
-- The wind-up matters here. accelSprint is deliberately slow, so there's a stretch
-- after you press Shift where you're "sprinting" at barely walking pace. Starting
-- the sprint cycle then plays it in slow motion, which looks floaty and weightless
-- ? the exact opposite of what the slow wind-up is for. So the walk cycle covers
-- the build-up and the sprint cycle takes over once the speed has actually arrived.
local function shouldUseSprintAnim(): boolean
	if not ANIM.sprint then
		return false
	end

	local walkSpeed = config.walkSpeed or 9
	if smoothedSpeed < walkSpeed then
		return false -- still winding up; the walk cycle owns this
	end

	local blend = config.sprintAnimBlendPoint or 0.4
	local threshold = walkSpeed + (TUNE.sprintSpeed - walkSpeed) * blend

	--[[
		SPEED DECIDES, NOT THE SHIFT KEY.

		This used to be `sprinting or smoothedSpeed > threshold`, so the moment you
		held Shift at walk pace the sprint cycle started -- while you were still
		moving at 9. Now it only takes over once you're actually going fast.

		A little hysteresis (the cycle drops out a bit BELOW where it came in) so
		hovering right at the threshold doesn't flick between the two clips.
	--]]
	if currentWalkAnim == ANIM.sprint then
		return smoothedSpeed > threshold - 1.5
	end
	return smoothedSpeed > threshold
end

local function GetDirectionalAnim(): AnimationTrack?
	if humanoid.MoveDirection.Magnitude == 0 then
		return nil
	end

	if shouldUseSprintAnim() then
		return ANIM.sprint
	end

	-- Third person: the body always turns to face where it's going, so only the
	-- forward cycle ever makes sense. Strafe cycles are a first-person thing.
	if not IsBodyLockedToCamera() then
		return ANIM.forward
	end

	local rel = rootPart.CFrame:VectorToObjectSpace(humanoid.MoveDirection)
	local angle = math.deg(math.atan2(rel.X, -rel.Z))
	if angle < 0 then
		angle += 360
	end

	local chosen
	if angle >= 337.5 or angle < 22.5 then       chosen = ANIM.forward
	elseif angle >= 22.5  and angle < 67.5 then  chosen = ANIM.rightDiag
	elseif angle >= 67.5  and angle < 112.5 then chosen = ANIM.right
	elseif angle >= 112.5 and angle < 157.5 then chosen = ANIM.rightDiagRev
	elseif angle >= 157.5 and angle < 202.5 then chosen = ANIM.backward
	elseif angle >= 202.5 and angle < 247.5 then chosen = ANIM.leftDiagRev
	elseif angle >= 247.5 and angle < 292.5 then chosen = ANIM.left
	else                                          chosen = ANIM.leftDiag
	end

	return chosen or ANIM.forward
end

-- Playback is tied to actual WalkSpeed, so the SAME walk cycle covers walking,
-- sprinting and every speed in between ? at 13.5 against a 9 walkSpeed it plays
-- 1.5x on its own. That's also what keeps the feet planted through the accel ramp
-- and the coast-down instead of sliding.
-- sprintAnimMult is a thumb on the scale for when a straight 1.5x looks comical:
-- below 1.0 the legs under-rotate and you get deliberate skidding weight; above,
-- a frantic scramble. 1.0 is honest and plants correctly.
local function getAnimPlaybackSpeed(target: AnimationTrack): number
	-- The sprint cycle is authored at sprint pace, so it divides by sprintSpeed.
	-- Dividing it by walkSpeed like the walk cycles would play it ~1.6x too fast.
	if target == ANIM.sprint then
		return (humanoid.WalkSpeed / TUNE.sprintSpeed) * (config.sprintAnimSpeed or 1.0)
	end

	local walkSpeed = config.walkSpeed or 9
	local s = (humanoid.WalkSpeed / walkSpeed) * (walkAnimSpeedMap[target] or baseAnimSpeed)

	-- Only reached while sprinting when there is NO Sprint animation, so the walk
	-- cycle is standing in for one. sprintAnimMult is the thumb on the scale for
	-- how convincing that stand-in looks.
	if sprinting then
		s *= TUNE.sprintAnimMult
	end
	return s
end

local function UpdateWalkAnim()
	if #allMoveAnims == 0 then return end

	local target = GetDirectionalAnim()

	if target == nil then
		if currentWalkAnim then
			StopAllAnims(allMoveAnims, nil, TUNE.blend)
			currentWalkAnim = nil
		end
	elseif target ~= currentWalkAnim then
		StopAllAnims(allMoveAnims, target, TUNE.blend)
		if not target.IsPlaying then
			target:Play(TUNE.blend)
		end
		target:AdjustSpeed(getAnimPlaybackSpeed(target))
		currentWalkAnim = target
	else
		target:AdjustSpeed(getAnimPlaybackSpeed(target))
	end
end

-- =====================
-- TURN IN PLACE
-- =====================
local TURN_YAW_THRESHOLD = config.turnYawThreshold or 3
local TURN_JITTER_IGNORE = config.turnJitterIgnore or 0.15
local TURN_ACCUM_DECAY = config.turnAccumulateDecay or 8
local TURN_HOLD_TIME = config.turnAnimHoldTime or 0.2
local accumulatedYaw = 0
local lastTurnDetectedAt = 0
local lastYaw: number? = nil

local function StopAllTurnAnims(t: number?)
	for _, anim in ipairs(allTurnAnims) do
		if anim.IsPlaying then
			anim:Stop(t or 0.15)
		end
	end
	currentTurnAnim = nil
end

-- Accumulated-yaw approach: sum yaw changes over a short window instead of
-- testing one frame's delta, so a slow deliberate turn still triggers but a
-- one-pixel mouse jitter decays away before it can.
local function UpdateTurnAnim(yawDelta: number, dt: number)
	if #allTurnAnims == 0 then return end

	if moving then
		StopAllTurnAnims(0.15)
		lastTurnDetectedAt = 0
		accumulatedYaw = 0
		return
	end

	if math.abs(yawDelta) < TURN_JITTER_IGNORE then
		yawDelta = 0
	end

	if yawDelta ~= 0 then
		if (accumulatedYaw > 0 and yawDelta < 0) or (accumulatedYaw < 0 and yawDelta > 0) then
			accumulatedYaw = 0
		end
		accumulatedYaw += yawDelta
	else
		if math.abs(accumulatedYaw) <= TURN_ACCUM_DECAY * dt then
			accumulatedYaw = 0
		else
			accumulatedYaw -= math.sign(accumulatedYaw) * TURN_ACCUM_DECAY * dt
		end
	end

	local now = os.clock()
	if math.abs(accumulatedYaw) >= TURN_YAW_THRESHOLD then
		lastTurnDetectedAt = now
		local target = (accumulatedYaw > 0) and ANIM.turnIn or ANIM.turnOut
		if not target then
			StopAllTurnAnims(0.15)
			return
		end
		if target ~= currentTurnAnim then
			StopAllTurnAnims(0.1)
			if not target.IsPlaying then
				target:Play(0.1)
			end
			currentTurnAnim = target
		end
		accumulatedYaw = 0
	elseif currentTurnAnim and (now - lastTurnDetectedAt) > TURN_HOLD_TIME then
		StopAllTurnAnims(0.2)
	end
end

-- =====================
-- HELPERS
-- =====================
local function moveToward(current: number, target: number, rate: number, dt: number): number
	local diff = target - current
	local step = rate * dt
	if math.abs(diff) <= step then
		return target
	end
	return current + math.sign(diff) * step
end

local function IsStrafing(): boolean
	if movementVector.Magnitude <= 0 then
		return false
	end
	return movementVector:Dot(rootPart.CFrame.LookVector) < 0.7
end

-- =====================
-- RAW INPUT
-- =====================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	local k = input.KeyCode
	if k == Enum.KeyCode.W then held.W = true; recomputeInputMag()
	elseif k == Enum.KeyCode.A then held.A = true; recomputeInputMag()
	elseif k == Enum.KeyCode.S then held.S = true; recomputeInputMag()
	elseif k == Enum.KeyCode.D then held.D = true; recomputeInputMag()
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	local k = input.KeyCode
	if k == Enum.KeyCode.W then held.W = false; recomputeInputMag()
	elseif k == Enum.KeyCode.A then held.A = false; recomputeInputMag()
	elseif k == Enum.KeyCode.S then held.S = false; recomputeInputMag()
	elseif k == Enum.KeyCode.D then held.D = false; recomputeInputMag()
	end
end)

-- =====================
-- SPRINT INPUT
-- =====================
-- Bound here rather than up with the jump block because the handler closes over
-- `holdingSprint`, which is declared further down ? a closure made before that
-- declaration can't see it.
ContextActionService:BindActionAtPriority("Creature_Sprint", function(_, inputState)
	-- Same leak guard as the jump block. This one already returned Pass, so it
	-- couldn't steal the key ? but a leaked copy would still be writing
	-- holdingSprint on a destroyed rig every time the human pressed Shift.
	if not isActiveBody() then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		holdingSprint = true
	elseif inputState == Enum.UserInputState.End then
		holdingSprint = false
	end
	return Enum.ContextActionResult.Pass
end, false, 2000, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3)

smoothedSpeed = humanoid.WalkSpeed
character:SetAttribute("CreatureMoving", false)
character:SetAttribute("CreatureSprinting", false)

-- =====================
-- MAIN LOOP
-- =====================
local loopConn
loopConn = RunService.RenderStepped:Connect(function(deltaTime)
	if not character.Parent or humanoid.Health <= 0 then
		return
	end

	movementVector = humanoid.MoveDirection.Magnitude > 0 and humanoid.MoveDirection.Unit or Vector3.zero

	updateRayFilters()
	UpdateTilt(deltaTime)

	-- ---- uphill slope angle along the current heading ----
	local climbAngle = 0
	do
		local md = TUNE.lastMoveDir
		if humanoid.FloorMaterial ~= Enum.Material.Air and md.Magnitude > 0.001 then
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

	-- Rooted by a full-body roar. Set by CreatureRoarServer for the length of the
	-- animation, and only for the idle variant ? the moving variant is head and
	-- arms only and deliberately doesn't lock.
	local roarLocked = character:GetAttribute("RoarLocked") == true

	strafing = IsStrafing()
	character:SetAttribute("CreatureStrafing", strafing)

	-- ---- sprint eligibility ----
	-- Refused rather than merely slowed in each of these cases, because a heavy
	-- creature that can sprint sideways, from a standstill, or up a cliff stops
	-- reading as heavy. You have to already be under way and pointed somewhere.
	-- Carrying somebody (CreatureGrabbing is set by the server and replicates):
	-- no sprinting at all while they're in your hand.
	local carrying = character:GetAttribute("CreatureGrabbing") == true

	local wantsSprint = holdingSprint
		and not carrying
		and inputMag > 0
		and not landingLocked
		and not roarLocked
		and not idlePivoting
		and not strafing
		and climbAngle < TUNE.sprintSlopeCutoff

	if wantsSprint then
		if not sprinting then
			-- Starting: needs existing momentum. No launching from a dead stop.
			sprinting = smoothedSpeed >= TUNE.sprintMinSpeedToStart
		end
	else
		sprinting = false
	end

	-- ---- WalkSpeed accel / decel ----
	local targetSpeed = sprinting and TUNE.sprintSpeed or (config.walkSpeed or 9)

	if strafing then
		targetSpeed *= TUNE.strafeMult
	end

	-- Aiming a throw (and through the wind-up and throw itself): slowed right
	-- down. ThrowAiming is set by the Arm system on this same client. It goes
	-- through the normal decel ramp, so you slow into the aim rather than stopping.
	if character:GetAttribute("ThrowAiming") == true then
		targetSpeed *= TUNE.aimSpeedMult
	end

	if climbAngle > TUNE.slopeFull then
		local t = math.clamp((climbAngle - TUNE.slopeFull) / (TUNE.slopeSteep - TUNE.slopeFull), 0, 1)
		targetSpeed *= (1 - t * (1 - TUNE.slopeMin))
	end

	-- Target zero with no input so momentum bleeds off through the decel ramp
	-- (coast to a stop) rather than braking dead.
	if inputMag == 0 or idlePivoting or landingLocked or roarLocked then
		targetSpeed = 0
	end

	-- The sprint decel rate stays in force while SLOWING DOWN from a sprint, not
	-- only while sprinting ? otherwise releasing shift snaps you back to the walk
	-- decel and the creature stops on a dime, which throws away the weight the
	-- wind-up just built. Anything above walk speed is still carrying sprint
	-- momentum and coasts like it.
	local walkSpeed = config.walkSpeed or 9
	local carryingSprintMomentum = sprinting or smoothedSpeed > walkSpeed + 0.1

	local rate
	if targetSpeed > smoothedSpeed then
		rate = sprinting and TUNE.accelSprint or TUNE.accel
	else
		rate = carryingSprintMomentum and TUNE.decelSprint or TUNE.decel
	end

	if landingLocked then
		rate = math.max(rate, TUNE.landingDecel)
	end

	smoothedSpeed = moveToward(smoothedSpeed, targetSpeed, rate, deltaTime)
	if smoothedSpeed < TUNE.snap and targetSpeed == 0 then
		smoothedSpeed = 0
	end
	humanoid.WalkSpeed = smoothedSpeed

	character:SetAttribute("CreatureSprinting", sprinting)

	-- ---- turning + humanoid:Move override ----
	--
	-- Rooted: no drive, no turning. Returning before the movement block rather
	-- than zeroing the speed alone matters ? the yaw spring would otherwise still
	-- rotate the body toward the keys, so you'd be spinning on the spot in the
	-- middle of a full-body roar. The keys stay read, so releasing the lock
	-- resumes normally.
	if roarLocked then
		humanoid:Move(Vector3.zero, false)
		smoothedWishDir = Vector3.zero
		smoothedMoveDir = Vector3.zero
		idlePivoting = false
		idleYawVel = 0
		moving = false
		character:SetAttribute("CreatureMoving", false)

		-- Keep the yaw spring synced to where the body actually is, so the moment
		-- the lock lifts it doesn't snap round to a heading from before the roar.
		local fd = rootPart.CFrame.LookVector
		if (fd.X * fd.X + fd.Z * fd.Z) > 1e-6 then
			idleYaw = math.deg(math.atan2(fd.X, fd.Z))
		end

		UpdateWalkAnim()
		UpdateTurnAnim(0, deltaTime)
		return
	end

	local inFirstPerson = IsBodyLockedToCamera()
	local rawDir = getRawMoveDir()
	local hasInput = rawDir.Magnitude > 0.001
	local vel = rootPart.AssemblyLinearVelocity
	local physicallyMoving = Vector3.new(vel.X, 0, vel.Z).Magnitude > TUNE.stopThreshold

	if inFirstPerson then
		idlePivoting = false
		wasInputLastFrame = hasInput

		local cam = workspace.CurrentCamera
		if cam then
			local camXZ = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
			if camXZ.Magnitude > 0.001 then
				local lookDir = camXZ.Unit
				local targetRot = CFrame.lookAt(Vector3.zero, lookDir, Vector3.yAxis)
				if character:GetAttribute("ThrowAiming") == true then
					-- Swings round to the aim rather than snapping: entering aim with
					-- the camera behind you would otherwise flip the body 180 in a frame.
					local currentRot = rootPart.CFrame - rootPart.CFrame.Position
					local rot = currentRot:Lerp(targetRot, 1 - math.exp(-12 * deltaTime))
					rootPart.CFrame = CFrame.new(rootPart.CFrame.Position) * rot
					local fd = rot.LookVector
					smoothedMoveDir = Vector3.new(fd.X, 0, fd.Z).Unit
					idleYaw = math.deg(math.atan2(fd.X, fd.Z))
				else
					rootPart.CFrame = CFrame.new(rootPart.CFrame.Position) * targetRot
					smoothedMoveDir = lookDir
					idleYaw = math.deg(math.atan2(lookDir.X, lookDir.Z))
				end
				idleYawVel = 0
			end
		end

		if hasInput then
			-- Directional momentum: ease the move vector toward the input rather than
			-- snapping. Snap only when starting from rest, so the speed ramp handles
			-- build-up instead of double-ramping. While moving we always ease, even
			-- through a full reversal, so direction spam bleeds speed and rebuilds.
			if smoothedSpeed < TUNE.snap then
				smoothedWishDir = rawDir
			else
				local a = 1 - math.exp(-TUNE.dirResponse * deltaTime)
				smoothedWishDir = smoothedWishDir:Lerp(rawDir, a)
			end
			humanoid:Move(smoothedWishDir, false)
			TUNE.lastMoveDir = rawDir
			moving = true
		elseif smoothedSpeed > TUNE.snap and TUNE.lastMoveDir.Magnitude > 0.001 and not landingLocked then
			smoothedWishDir = TUNE.lastMoveDir
			humanoid:Move(TUNE.lastMoveDir, false)
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
			local fd0 = rootPart.CFrame.LookVector
			if (fd0.X * fd0.X + fd0.Z * fd0.Z) > 1e-6 then
				idleYaw = math.deg(math.atan2(fd0.X, fd0.Z))
			end
			idleYawVel = 0
		end
		wasInputLastFrame = hasInput

		if hasInput then
			-- One yaw spring drives all third-person turning: the in-place pivot from
			-- idle AND steering while moving.
			-- force = displacement * stiffness - velocity * damping (overshoot + settle)
			local targetYaw = math.deg(math.atan2(rawDir.X, rawDir.Z))
			local diff = targetYaw - idleYaw
			if diff > 180 then diff -= 360 elseif diff < -180 then diff += 360 end

			-- Sprinting swaps in a lower velocity cap AND a softer spring. The cap
			-- alone would just clamp the turn; dropping stiffness too means the
			-- body takes longer to even start coming round, which is what reads as
			-- momentum rather than as a speed limit. Wide arcs, not slow rotation.
			local cap, stiffness, damping
			if idlePivoting then
				cap, stiffness, damping = TUNE.idlePivotRate, TUNE.idleStiffness, TUNE.idleDamping
			elseif IsAirborne() then
				cap, stiffness, damping = TUNE.turnRateAir, TUNE.idleStiffness, TUNE.idleDamping
			elseif sprinting then
				cap, stiffness, damping = TUNE.turnRateSprint, TUNE.sprintStiffness, TUNE.sprintDamping
			else
				cap, stiffness, damping = TUNE.turnRateWalk, TUNE.idleStiffness, TUNE.idleDamping
			end

			-- Cornering harder than the creature can commit to drops the sprint ?
			-- you have to slow down to turn sharply, then build back up.
			if sprinting and math.abs(diff) > TUNE.sprintMaxTurnAngle then
				sprinting = false
				character:SetAttribute("CreatureSprinting", false)
			end

			local force = diff * stiffness - idleYawVel * damping
			idleYawVel = math.clamp(idleYawVel + force * deltaTime, -cap, cap)
			idleYaw += idleYawVel * deltaTime
			if idleYaw > 180 then idleYaw -= 360 elseif idleYaw < -180 then idleYaw += 360 end

			local rad = math.rad(idleYaw)
			local newDir = Vector3.new(math.sin(rad), 0, math.cos(rad))
			local pos = rootPart.CFrame.Position
			local newCF = CFrame.lookAt(pos, pos + newDir, Vector3.yAxis)
			rootPart.CFrame = CFrame.new(pos) * (newCF - newCF.Position)
			smoothedMoveDir = newDir

			-- From idle: pivot in place until roughly facing, then commit to walking.
			-- Already moving: keep walking and let the spring steer the body round.
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
			idlePivoting = false
			idleYawVel = 0
			local fd = rootPart.CFrame.LookVector
			if (fd.X * fd.X + fd.Z * fd.Z) > 1e-6 then
				idleYaw = math.deg(math.atan2(fd.X, fd.Z))
			end

			-- Coast: keep walking the last heading while WalkSpeed bleeds off, so the
			-- creature decelerates to a stop instead of stopping dead. The walk anim
			-- slows with WalkSpeed, so the feet stay matched the whole way down.
			if smoothedSpeed > TUNE.snap and TUNE.lastMoveDir.Magnitude > 0.001 and not landingLocked then
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

	character:SetAttribute("CreatureMoving", moving)

	-- Landing lock: kill residual horizontal momentum so the creature plants
	-- instead of sliding forward off a drop.
	if landingLocked then
		local v = rootPart.AssemblyLinearVelocity
		local factor = math.clamp(1 - TUNE.landingVelDamp * deltaTime, 0, 1)
		rootPart.AssemblyLinearVelocity = Vector3.new(v.X * factor, v.Y, v.Z * factor)
	end

	-- ---- animations ----
	UpdateWalkAnim()

	if ANIM.idle then
		if not moving and not ANIM.idle.IsPlaying then
			ANIM.idle:Play(TUNE.blend)
		elseif moving and ANIM.idle.IsPlaying then
			ANIM.idle:Stop(TUNE.blend)
		end
	end

	-- idle emotes
	if #idleEmoteAnims > 0 then
		if not moving and not IsAirborne() then
			if currentIdleEmote then
				if not currentIdleEmote.IsPlaying then
					currentIdleEmote = nil
				end
			else
				idleEmoteTimer += deltaTime
				if idleEmoteTimer >= idleEmoteThreshold then
					idleEmoteTimer = 0
					idleEmoteThreshold = IDLE_EMOTE_MIN + math.random() * (IDLE_EMOTE_MAX - IDLE_EMOTE_MIN)
					local anim = idleEmoteAnims[math.random(1, #idleEmoteAnims)]
					currentIdleEmote = anim
					anim:Play(0.2)
				end
			end
		else
			idleEmoteTimer = 0
			if currentIdleEmote then
				currentIdleEmote:Stop(0.15)
				currentIdleEmote = nil
			end
		end
	end

	-- ---- falling / landing ----
	do
		local airborne = IsAirborne()

		if airborne and not wasFalling then
			airborneStartTime = os.clock()
		end

		local airborneTime = airborne and (os.clock() - airborneStartTime) or 0
		local prolonged = airborneTime >= TUNE.prolongedFall
		local fallingWasPlaying = ANIM.falling and ANIM.falling.IsPlaying

		if ANIM.falling then
			if airborne and prolonged and not ANIM.falling.IsPlaying then
				ANIM.falling:Play(0.15)
			elseif not airborne and wasFalling then
				ANIM.falling:Stop(0.15)

				-- Landing anim only after a real fall, so walking over bumps and down
				-- slopes doesn't fire it every few steps.
				if fallingWasPlaying and ANIM.landing then
					landingLocked = true
					character:SetAttribute("CreatureLanding", true)
					ANIM.landing:Play(0.05)
					task.delay(TUNE.landingLock, function()
						landingLocked = false
						character:SetAttribute("CreatureLanding", false)
						if ANIM.landing then
							ANIM.landing:Stop(0.15)
						end
					end)
				end
			end
		end

		wasFalling = airborne
	end

	-- ---- turn-in-place anims ----
	local look = rootPart.CFrame.LookVector
	local curYaw = math.deg(math.atan2(look.X, look.Z))
	local yawDelta = 0
	if lastYaw ~= nil then
		yawDelta = curYaw - lastYaw
		if yawDelta > 180 then yawDelta -= 360 end
		if yawDelta < -180 then yawDelta += 360 end
	end
	lastYaw = curYaw
	UpdateTurnAnim(yawDelta, deltaTime)
end)

-- =====================
-- CLEANUP
-- =====================
humanoid.Died:Connect(function()
	humanoid.AutoRotate = true
	held.W, held.A, held.S, held.D = false, false, false, false
	inputMag = 0
	smoothedSpeed = 0
	moving = false
	sprinting = false
	holdingSprint = false
	character:SetAttribute("CreatureSprinting", false)
	ContextActionService:UnbindAction("Creature_Sprint")
	idlePivoting = false
	landingLocked = false
	StopAllTurnAnims(0)
	StopAllAnims(allMoveAnims, nil, 0.1)
	if ANIM.idle then ANIM.idle:Stop(0.1) end
	if ANIM.falling then ANIM.falling:Stop(0) end
	if ANIM.landing then ANIM.landing:Stop(0) end
	if currentIdleEmote then currentIdleEmote:Stop(0) end
	character:SetAttribute("CreatureMoving", false)
	ContextActionService:UnbindAction("Creature_BlockJump")
	if loopConn then
		loopConn:Disconnect()
	end
end)

character.AncestryChanged:Connect(function(_, parent)
	if not parent then
		ContextActionService:UnbindAction("Creature_BlockJump")
		ContextActionService:UnbindAction("Creature_Sprint")
		if loopConn then
			loopConn:Disconnect()
		end
	end
end)
