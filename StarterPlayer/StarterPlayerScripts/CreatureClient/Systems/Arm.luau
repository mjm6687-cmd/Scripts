-- Arm  (ModuleScript, under CreatureClient > Systems)
--
-- The right arm: camera-aimed reach, grab, carry, hold-to-eat, chew.
--
-- ABOUT "IK" ON R6: there is no elbow. The whole arm is one part on one Motor6D,
-- so this is shoulder AIMING ? two angles point the limb, and a shoulder shift
-- closes the gap rotation can't. Everything else here is the parts of a reach
-- that aren't the elbow: the path the hand takes, the twist, and the fact that a
-- held pose is never perfectly still.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")

local System = {
	name = "Arm",
	key = "arm",
	scope = "rig",
}

local GRABBABLE_TAG = "Grabbable"

local DEFAULTS = {
	grabRange = 8,
	grabTouchDistance = 4.5,
	grabMinExtend = 0.8,

	armStiffness = 40,
	armDamping = 9,
	armMaxSpeed = 420,
	armExtendPush = 0.35,
	armReturnStiffness = 22,
	armSendInterval = 1 / 12,
	armSendMinDelta = 2,

	-- Asymmetric, because this is the RIGHT arm: swinging right is away from the
	-- body, swinging LEFT crosses the chest and a rigid limb on a right-side
	-- shoulder passes straight through the torso.
	armMaxYawOutward = 110,
	armMaxYawAcross = 32,
	armMinRise = 5,
	armMaxRise = 165,

	armCarryDroop = 18,

	armReachArc = 24,
	armRollFactor = 0.5,
	armSwayAmount = 3.5,
	armSwaySpeed = 1.5,

	mouthAttachmentName = "MouthAttachment",
	armHandLength = 2,
	eatMaxShoulderShift = 3.5,
	eatShoulderDrop = 1.1,
	eatShoulderResponse = 4,
	eatSoftening = 0.35,

	eatChargeTime = 0.85,
	eatReleaseSpeed = 2.2,

	chewShakeAmount = 8,
	chewAttack = 0.35,
	chewSmoothing = 9,

	-- No grabbing or eating above this. Read from the same walkSpeed the movement
	-- uses, so "walking" means the same thing in both places.
	walkSpeed = 9,

	-- THROW. Must match CreatureGrabServer's THROW_DEFAULTS (both read these same
	-- keys out of CreatureConfig), or the drawn arc won't be where they land.
	throwSpeedMin = 45,     -- launch speed with no charge (a quick flick)
	throwSpeedMax = 140,    -- launch speed fully charged
	throwChargeTime = 1.2,  -- seconds of holding right click to reach full charge
	throwWindupMin = 0.07,  -- fully charged, the arm is already back: just this long to finish
	throwChargeShake = 1.5, -- deg of tremble in the cocked arm at full charge
	throwUpBias = 14,
	throwMinPitch = -20,
	throwMaxPitch = 65,
	throwOriginUp = 1.5,
	throwOriginRight = 1.5,
	throwTapTime = 0.25,    -- right click released faster than this = drop
	throwAimDelay = 0.12,   -- how long right click is held before the arc shows

	-- (The over-the-shoulder camera settings live in the Camera system.)

	-- Throw animation. Timings must match CreatureGrabServer's (both read these
	-- keys from CreatureConfig) -- the server releases the body mid-whip.
	throwWindupTime = 0.34,
	throwWhipTime = 0.12,
	throwFollowTime = 0.3,
	throwWindupRise = 200,   -- deg. Past straight up (180): cocked back behind the head
	throwWindupYaw = -40,    -- deg. Out to the side, loading the swing
	throwWindupExtend = 0.35,
	throwWhipRise = 70,      -- deg. Where the arm ends up after the snap: forward and down
	throwWhipYaw = 12,       -- deg. Slightly across the body, like a real follow-through
}

-- Studs/s of slack over walkSpeed before it counts as too fast. Covers the small
-- overshoot of the speed ramp and the slope/lean wobble at a normal walk.
local WALK_SPEED_SLACK = 1.5

local player = Players.LocalPlayer
local CreatureUtil
local aimRemote: RemoteEvent?
local actionRemote: RemoteEvent?

local rigs: { [Model]: any } = {}
local reaching = false
local lastGrabAttempt = 0

-- Right click, while carrying: a TAP drops, a HOLD aims a throw. Left click
-- during the hold throws.
local rightDown = false
local rightDownAt = 0
local threwThisPress = false
local aimCharge = 0      -- 0..1, how long right click has been held past the aim delay

-- ============================================================
-- AIM FLAG
-- ============================================================
--[[
	While aiming (and through the wind-up and throw) the character gets a
	ThrowAiming attribute. That's all this module does about it:

	  * the Camera system reads it and goes over the shoulder
	  * CreatureMovement reads it and turns the body to face the aim

	Set by this LocalScript, so it stays on this client -- which is fine, both
	readers are here too.
--]]
local function resetAimCamera()
	local char = player.Character
	if char then
		char:SetAttribute("ThrowAiming", nil)
	end
end

local function updateAimCamera(state, aiming: boolean, _dt: number)
	local rig = state.rig
	if aiming ~= (rig:GetAttribute("ThrowAiming") == true) then
		rig:SetAttribute("ThrowAiming", aiming or nil)
	end
end

-- ============================================================
-- MATH
-- ============================================================
local function springStep(current, vel, target, stiffness, damping, maxVel, dt)
	local force = (target - current) * stiffness - vel * damping
	vel = math.clamp(vel + force * dt, -maxVel, maxVel)
	return current + vel * dt, vel
end

-- Angles are a circle. 179 and -179 are 2 degrees apart on a shoulder and 358
-- apart numerically; a plain subtraction across that seam sends the arm the long
-- way round. It only bites AT the seam, which is why it shows up as an occasional
-- unexplained snap rather than something consistently broken.
local function wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function blendAngle(from: number, to: number, t: number): number
	return from + wrapAngle(to - from) * t
end

local function springStepAngle(current, vel, target, stiffness, damping, maxVel, dt)
	local force = wrapAngle(target - current) * stiffness - vel * damping
	vel = math.clamp(vel + force * dt, -maxVel, maxVel)
	return current + vel * dt, vel
end

-- ============================================================
-- TARGETS
-- ============================================================
--[[
	THE VICTIM REGISTRY.

	This used to be `workspace:GetChildren()` ? TOP LEVEL ONLY. Drop your dummies
	into an NPCs folder and the arm could no longer see any of them, because a rig
	one level down was never in that list. Same bug the thermal had, same day.

	Walking every descendant instead would be right and unaffordable: this runs on
	a click, and a real map is tens of thousands of instances.

	So the candidates are kept in a registry ? one deep scan at startup, then
	DescendantAdded/Removing keep it current. Depth stops mattering and a grab
	check only iterates the humanoids that actually exist.
--]]
local victims: { [Humanoid]: Model } = {}

local function registerHumanoid(inst: Instance)
	if not inst:IsA("Humanoid") then
		return
	end
	local model = inst.Parent
	if model and model:IsA("Model") then
		victims[inst] = model
	end
end

local function unregisterHumanoid(inst: Instance)
	if inst:IsA("Humanoid") then
		victims[inst] = nil
	end
end

local function startVictimRegistry()
	for _, d in ipairs(workspace:GetDescendants()) do
		registerHumanoid(d)
	end
	workspace.DescendantAdded:Connect(registerHumanoid)
	workspace.DescendantRemoving:Connect(unregisterHumanoid)
end

local function isValidTarget(rig: Model, model: Instance): (Humanoid?, BasePart?)
	if model == rig or not model:IsA("Model") then return nil, nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (hum and root and root:IsA("BasePart")) then return nil, nil end
	if hum.Health <= 0 or model:GetAttribute("IsCorpse") == true then return nil, nil end
	if CreatureUtil.IsCreature(model) then return nil, nil end
	if model:GetAttribute("Grabbed") == true then return nil, nil end
	if model:GetAttribute("Thrown") == true then return nil, nil end
	return hum, root
end

-- The arm points where the camera points; this only asks whether anything is
-- where the hand ended up. Measured from the HAND, so reach genuinely matters.
local function findTargetNearHand(state, handPos: Vector3): Model?
	local touch = state.cfg.grabTouchDistance
	local best, bestDist = nil, math.huge

	local function consider(model: Instance)
		local _, root = isValidTarget(state.rig, model)
		if not root then return end
		local dist = (root.Position - handPos).Magnitude
		if dist <= touch and dist < bestDist then
			best, bestDist = model, dist
		end
	end

	for _, model in ipairs(CollectionService:GetTagged(GRABBABLE_TAG)) do
		if model:IsDescendantOf(workspace) then consider(model) end
	end

	for hum, model in pairs(victims) do
		if hum.Parent ~= model then
			-- Reparented since we saw it; drop the stale row rather than trust it.
			victims[hum] = nil
		elseif model.Parent then
			consider(model)
		end
	end

	return best
end

-- ============================================================
-- POSES
-- ============================================================
local function anglesToward(state, worldPos: Vector3): (number, number)
	local d = state.torso.CFrame:VectorToObjectSpace(worldPos - state.torso.Position)
	if d.Magnitude < 0.01 then return 0, 0 end
	d = d.Unit
	return math.acos(math.clamp(-d.Y, -1, 1)), math.atan2(-d.X, -d.Z)
end

local function mouthWorldPos(state): Vector3
	local name = state.cfg.mouthAttachmentName
	for _, partName in ipairs({ "Head", "HumanoidRootPart", "Torso" }) do
		local part = state.rig:FindFirstChild(partName)
		local att = part and part:FindFirstChild(name)
		if att and att:IsA("Attachment") then
			return att.WorldPosition
		end
	end
	local head = state.rig:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position + head.CFrame.LookVector * 0.6
	end
	return state.torso.Position + Vector3.new(0, 2, 0)
end

--[[
	The hand can only sit on a sphere of radius armHandLength around the joint,
	and the mouth is INSIDE that sphere ? so the only way to put the hand on the
	mouth is to move the joint AWAY from it, which for a mouth above the shoulder
	means sinking the shoulder down and back. A tight eatMaxShoulderShift
	truncates exactly that, and the hand waves near the face instead of reaching.

	Returns rise, yaw, shoulder offset, and how much that yaw is worth believing:
	when the mouth is nearly straight up, dir.X and dir.Z are both ~0 and atan2 of
	two near-zero numbers swings on floating point noise alone. Obeying that
	precisely is the snap while lifting someone.
--]]
local function solveEatPose(state): (number, number, Vector3, number)
	local cfg = state.cfg
	local mouthLocal = state.torso.CFrame:PointToObjectSpace(mouthWorldPos(state))
	local shoulder = state.basePos
	local toMouth = mouthLocal - shoulder

	if toMouth.Magnitude < 0.01 then
		return 0, 0, Vector3.zero, 0
	end

	local dir = toMouth.Unit

	local wantedPivot = mouthLocal - dir * cfg.armHandLength
	local offset = wantedPivot - shoulder
	if offset.Magnitude > cfg.eatMaxShoulderShift then
		offset = offset.Unit * cfg.eatMaxShoulderShift
	end
	-- Extra deliberate sink, after the clamp so it can't be swallowed by it.
	offset = offset + Vector3.new(0, -cfg.eatShoulderDrop, 0)

	local rise = math.acos(math.clamp(-dir.Y, -1, 1))
	local yaw = math.atan2(-dir.X, -dir.Z)
	local horizontal = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
	local yawWeight = math.clamp(horizontal / 0.25, 0, 1)

	return rise, yaw, offset, yawWeight
end

-- ============================================================
-- THROW ARC
-- ============================================================
--[[
	THE SAME MATH AS THE SERVER. CreatureGrabServer's throwVelocity launches the
	body from this origin with this velocity, so drawing the parabola from here is
	drawing where they will actually go. Change one, change both.
--]]
-- How long the wind-up phase of the throw takes, given how far you'd already
-- wound up by holding. Same formula on the server, which times the release by it.
local function windupDuration(cfg, charge: number): number
	return math.max(cfg.throwWindupMin, cfg.throwWindupTime * (1 - math.clamp(charge, 0, 1)))
end

local function computeThrow(state, lookDir: Vector3, charge: number?): (Vector3?, Vector3?)
	local cfg = state.cfg
	local root = state.rig:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil, nil
	end

	local origin = root.Position
		+ Vector3.new(0, cfg.throwOriginUp, 0)
		+ root.CFrame.RightVector * cfg.throwOriginRight

	local dir = lookDir.Unit
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	end
	flat = flat.Unit

	local pitch = math.deg(math.asin(math.clamp(dir.Y, -1, 1))) + cfg.throwUpBias
	pitch = math.rad(math.clamp(pitch, cfg.throwMinPitch, cfg.throwMaxPitch))

	local launch = flat * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
	local c = math.clamp(charge or 0, 0, 1)
	local speed = cfg.throwSpeedMin + (cfg.throwSpeedMax - cfg.throwSpeedMin) * c
	return origin, launch * speed
end

-- The body in the hand, found through the weld the server made, so the arc's
-- raycasts don't hit the very person being thrown.
local function heldVictim(state): Model?
	local weld = state.arm:FindFirstChild("CreatureGrabWeld")
	local part = weld and weld:IsA("Weld") and weld.Part1
	if not part then
		return nil
	end
	return part.Parent :: any
end

-- Drawn locally, parented to the camera, so only the thrower ever sees it.
--[[
	A SMOOTH LINE, not dots: a chain of Beams, one per short stretch of flight,
	each running from one point on the parabola to the next. With segments this
	short the joins can't be seen, so it reads as one continuous curve. Beams are
	flat ribbons that always turn to face the camera (FaceCamera), so the line has
	the same width from any angle.

	Built once and reused: moving it is just setting attachment positions.
--]]
local ARC_STEP = 0.035       -- seconds of flight per segment. Smaller = smoother
local ARC_MAX_SEG = 90       -- ~3 seconds of flight
local ARC_COLOR = Color3.fromRGB(255, 70, 58)
local ARC_WIDTH_NEAR = 0.22  -- studs, at the hand
local ARC_WIDTH_FAR = 0.1    -- studs, at the far end
local ARC_FADE_NEAR = 0.05   -- transparency at the hand
local ARC_FADE_FAR = 0.65    -- transparency at the far end

local arcFolder: Folder? = nil
local arcAnchor: BasePart? = nil
local arcPoints: { Attachment } = {}
local arcBeams: { Beam } = {}
local arcMarker: BasePart? = nil
local arcParams = RaycastParams.new()
arcParams.FilterType = Enum.RaycastFilterType.Exclude
arcParams.IgnoreWater = true

local function plainPart(shape): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = ARC_COLOR
	p.Shape = shape
	return p
end

local function ensureArc()
	if arcFolder and arcFolder.Parent then
		return
	end
	arcFolder = Instance.new("Folder")
	arcFolder.Name = "CreatureThrowArc"
	arcFolder.Parent = workspace.CurrentCamera

	-- Beams hang off Attachments, and Attachments need a part to live in. This
	-- one is invisible and never moves; only the attachments' world positions do.
	local anchor = plainPart(Enum.PartType.Block)
	anchor.Name = "ArcAnchor"
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new()
	anchor.Parent = arcFolder
	arcAnchor = anchor

	arcPoints, arcBeams = {}, {}
	for i = 0, ARC_MAX_SEG do
		local a = Instance.new("Attachment")
		a.Name = "P" .. i
		a.Parent = anchor
		arcPoints[i] = a
	end

	for i = 1, ARC_MAX_SEG do
		local t0 = (i - 1) / ARC_MAX_SEG
		local t1 = i / ARC_MAX_SEG
		local beam = Instance.new("Beam")
		beam.Name = "Seg" .. i
		beam.Attachment0 = arcPoints[i - 1]
		beam.Attachment1 = arcPoints[i]
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Color = ColorSequence.new(ARC_COLOR)
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Width0 = ARC_WIDTH_NEAR + (ARC_WIDTH_FAR - ARC_WIDTH_NEAR) * t0
		beam.Width1 = ARC_WIDTH_NEAR + (ARC_WIDTH_FAR - ARC_WIDTH_NEAR) * t1
		beam.Transparency = NumberSequence.new(
			ARC_FADE_NEAR + (ARC_FADE_FAR - ARC_FADE_NEAR) * t0,
			ARC_FADE_NEAR + (ARC_FADE_FAR - ARC_FADE_NEAR) * t1
		)
		beam.Enabled = false
		beam.Parent = anchor
		arcBeams[i] = beam
	end

	local marker = plainPart(Enum.PartType.Cylinder)
	marker.Name = "Landing"
	marker.Size = Vector3.new(0.08, 3.2, 3.2)
	marker.Transparency = 1
	marker.Parent = arcFolder
	arcMarker = marker
end

local function hideArc()
	if not arcFolder then
		return
	end
	for _, beam in ipairs(arcBeams) do
		beam.Enabled = false
	end
	if arcMarker then
		arcMarker.Transparency = 1
	end
end

local function drawArc(state)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local origin, velocity = computeThrow(state, cam.CFrame.LookVector, aimCharge)
	if not origin then
		hideArc()
		return
	end
	ensureArc()

	local exclude = { state.rig, arcFolder }
	local victim = heldVictim(state)
	if victim then
		table.insert(exclude, victim)
	end
	arcParams.FilterDescendantsInstances = exclude

	local g = Vector3.new(0, -workspace.Gravity, 0)
	local prev = origin
	arcPoints[0].WorldPosition = origin
	local landed: RaycastResult? = nil
	local used = 0

	for i = 1, ARC_MAX_SEG do
		local t = i * ARC_STEP
		local p = origin + velocity * t + g * (0.5 * t * t)
		local hit = workspace:Raycast(prev, p - prev, arcParams)
		if hit then
			-- The last stretch ends exactly where it hits, so the line meets the
			-- landing marker instead of stopping short of it or passing through.
			landed = hit
			arcPoints[i].WorldPosition = hit.Position
			used = i
			break
		end
		arcPoints[i].WorldPosition = p
		used = i
		prev = p
	end

	for i = 1, ARC_MAX_SEG do
		arcBeams[i].Enabled = i <= used
	end

	if landed and arcMarker then
		local up = landed.Normal
		-- A cylinder's flat faces point along X, so X goes onto the surface normal.
		arcMarker.CFrame = CFrame.lookAt(landed.Position + up * 0.05, landed.Position + up * 1.05)
			* CFrame.Angles(0, math.rad(90), 0)
		arcMarker.Transparency = 0.35
	elseif arcMarker then
		arcMarker.Transparency = 1
	end
end

-- ============================================================
-- INPUT
-- ============================================================
local function bindInput()
	-- Bound ONCE, never unbound: this module loads a single time per player, so
	-- unbinding on unmorph killed the grab permanently. Both handlers check
	-- IsCreature per press and pass through when you're human.
	ContextActionService:BindActionAtPriority("Creature_Reach", function(_, inputState)
		local char = player.Character
		if not (char and CreatureUtil.IsCreature(char)) then
			return Enum.ContextActionResult.Pass
		end
		-- Left click WHILE AIMING a throw is the throw, not a reach or an eat.
		if inputState == Enum.UserInputState.Begin and rightDown
			and char:GetAttribute("CreatureGrabbing") == true
			and char:GetAttribute("CreatureEating") ~= true then
			-- One timestamp for both: the wind-up plays from it here, and the server
			-- times the release from it too, so the body leaves the hand when the
			-- arm on THIS screen gets there, not a round trip later.
			local stamp = workspace:GetServerTimeNow()
			local charge = aimCharge
			local cam = workspace.CurrentCamera
			if cam and actionRemote then
				actionRemote:FireServer("Throw", cam.CFrame.LookVector, stamp, charge)
			end
			threwThisPress = true
			aimCharge = 0
			hideArc()
			local st = rigs[char]
			if st then
				st.localThrowStart = stamp
				st.localThrowCharge = charge
			end
			return Enum.ContextActionResult.Sink
		end

		-- One meaning, decided by context in update(): empty-handed it extends the
		-- arm, holding somebody it charges the eat.
		reaching = (inputState == Enum.UserInputState.Begin)
		return Enum.ContextActionResult.Sink
	end, false, 2500, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

	ContextActionService:BindActionAtPriority("Creature_Drop", function(_, inputState)
		local char = player.Character
		if not (char and CreatureUtil.IsCreature(char)) then
			return Enum.ContextActionResult.Pass
		end
		--[[
			TAP = drop. HOLD = aim a throw (the arc draws in update()), and left
			click during the hold throws. Letting go of a hold without throwing
			keeps them in your hand.
		--]]
		if inputState == Enum.UserInputState.Begin then
			if char:GetAttribute("CreatureGrabbing") ~= true then
				-- Nothing held: let right click do whatever it normally does.
				return Enum.ContextActionResult.Pass
			end
			rightDown = true
			rightDownAt = os.clock()
			threwThisPress = false
			aimCharge = 0
			-- The server starts its own clock here, so it can check the charge we
			-- claim later against how long we really held.
			if actionRemote then
				actionRemote:FireServer("AimStart")
			end
			return Enum.ContextActionResult.Sink
		end

		if inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			if not rightDown then
				return Enum.ContextActionResult.Pass
			end
			rightDown = false
			aimCharge = 0
			hideArc()

			local state = rigs[char]
			local tapTime = state and state.cfg.throwTapTime or DEFAULTS.throwTapTime
			if inputState == Enum.UserInputState.End
				and not threwThisPress
				and os.clock() - rightDownAt < tapTime
				and char:GetAttribute("CreatureGrabbing") == true
				and actionRemote then
				actionRemote:FireServer("Drop")
			end
			return Enum.ContextActionResult.Sink
		end

		return Enum.ContextActionResult.Pass
	end, false, 2500, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL1)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil

	startVictimRegistry()

	--[[
		THE LAUNCH. When you throw someone, your computer keeps simulating their
		body (it was already, while you carried them), so it's your computer that
		sends them flying -- from the origin and at the velocity the server chose.
		That's what keeps the throw smooth on your screen instead of freezing and
		jumping while the server catches up.
	--]]
	task.spawn(function()
		local launch = ReplicatedStorage:WaitForChild("CreatureThrowLaunch", 30)
		if not launch then
			return
		end
		launch.OnClientEvent:Connect(function(victim, launchCFrame, velocity, spin)
			if typeof(victim) ~= "Instance" or not victim:IsA("Model") or not victim.Parent then
				return
			end
			if typeof(launchCFrame) ~= "CFrame" or typeof(velocity) ~= "Vector3" then
				return
			end

			-- The grab weld is gone on the server; make sure it's gone here too
			-- before moving anything, or the body is yanked back to the hand.
			local char = player.Character
			local arm = char and char:FindFirstChild("Right Arm")
			local weld = arm and arm:FindFirstChild("CreatureGrabWeld")
			if weld then
				weld:Destroy()
			end

			victim:PivotTo(launchCFrame)
			for _, part in ipairs(victim:GetDescendants()) do
				if part:IsA("BasePart") and not part.Anchored then
					part.AssemblyLinearVelocity = velocity
					if typeof(spin) == "Vector3" then
						part.AssemblyAngularVelocity = spin
					end
				end
			end
		end)
	end)

	task.spawn(function()
		aimRemote = ReplicatedStorage:WaitForChild("CreatureArmAim", 30)
		actionRemote = ReplicatedStorage:WaitForChild("CreatureArmAction", 30)
		if not actionRemote then
			warn("[Arm] CreatureArmAction never appeared ? is CreatureGrabServer running?")
		end
	end)

	bindInput()
end

function System.onAdded(rig: Model, config)
	local cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	task.spawn(function()
		local torso = rig:WaitForChild("Torso", 10)
		if not torso or not rig.Parent then return end
		local shoulder = torso:WaitForChild("Right Shoulder", 10)
		if not (shoulder and shoulder:IsA("Motor6D")) then
			warn("[Arm] " .. rig:GetFullName() .. ".Torso has no 'Right Shoulder' Motor6D.")
			return
		end
		local humanoid = rig:WaitForChild("Humanoid", 10)
		local arm = rig:WaitForChild("Right Arm", 10)
		if not (humanoid and arm) then return end

		-- From the attribute the server published off the template, so every
		-- client agrees on neutral no matter when it bound.
		local baseC0 = rig:GetAttribute("RightShoulderBaseC0")
		if typeof(baseC0) ~= "CFrame" then
			baseC0 = shoulder.C0
		end

		rigs[rig] = {
			rig = rig, torso = torso, shoulder = shoulder, arm = arm,
			humanoid = humanoid, cfg = cfg,
			basePos = baseC0.Position,
			baseRot = baseC0 - baseC0.Position,
			rise = 0, riseVel = 0,
			yaw = 0, yawVel = 0,
			extend = 0, extendVel = 0,
			shoulderOffset = Vector3.zero,
			eatCharge = 0, sentCharge = -1,
			eatFired = false, cancelSent = false,
			chewRise = 0, chewRoll = 0, chewYaw = 0,
			swayPhase = math.random() * 100,
			lastSendT = 0, lastSentRise = 0, lastSentYaw = 0,
		}
	end)
end

function System.onRemoved(rig: Model)
	local state = rigs[rig]
	if state then
		pcall(function()
			state.shoulder.C0 = CFrame.new(state.basePos) * state.baseRot
		end)
	end
	local wasLocal = state and (rig == player.Character or player.Character == nil or not rig.Parent)
	rigs[rig] = nil
	reaching = false
	if wasLocal then
		rightDown = false
		hideArc()
		resetAimCamera()
	end
end

-- ============================================================
-- UPDATE
-- ============================================================
function System.update(dt: number)
	for rig, state in pairs(rigs) do
		if not rig.Parent or not state.shoulder.Parent or state.humanoid.Health <= 0 then
			System.onRemoved(rig)
			continue
		end

		local cfg = state.cfg
		local isLocal = (rig == player.Character)

		--[[
			WALKING OR STANDING ONLY.

			While sprinting, or still carrying sprint speed while coasting down from
			one, the arm acts as if the button isn't held: no reach, no grab, the eat
			charge drains, and an eat already in progress is cancelled (the victim
			stays in your hand). Slow back down with the button still held and it
			picks up again on its own.

			Carrying somebody while you run is still allowed -- only USING the arm is
			locked. CreatureGrabServer refuses Grab and Eat at speed too, so this is
			the feel, not the security.
		--]]
		local armFree = true
		if isLocal then
			local root = rig:FindFirstChild("HumanoidRootPart")
			local v = root and root.AssemblyLinearVelocity or Vector3.zero
			local speed = Vector3.new(v.X, 0, v.Z).Magnitude
			armFree = rig:GetAttribute("CreatureSprinting") ~= true
				and speed <= cfg.walkSpeed + WALK_SPEED_SLACK
		end
		-- ---- throw animation clock ----
		-- Local: our own predicted start. Everyone else: the server's ThrowStart.
		local throwStart = (isLocal and state.localThrowStart) or rig:GetAttribute("ThrowStart")
		local throwT = (typeof(throwStart) == "number") and (workspace:GetServerTimeNow() - throwStart) or -1
		-- How charged that throw was, which decides how much wind-up is left to do.
		local throwCharge = (isLocal and state.localThrowCharge) or rig:GetAttribute("ThrowCharge") or 0
		if typeof(throwCharge) ~= "number" then throwCharge = 0 end
		local throwWindup = windupDuration(cfg, throwCharge)
		local throwTotal = throwWindup + cfg.throwWhipTime + cfg.throwFollowTime
		local throwActive = throwT >= 0 and throwT < throwTotal
		if isLocal and state.localThrowStart and throwT >= throwTotal then
			state.localThrowStart = nil
		end

		-- Aiming a throw borrows left click, so it can't also be reaching/eating.
		local reach = reaching and armFree and not (isLocal and rightDown)

		if isLocal then
			local aiming = rightDown
				and not threwThisPress
				and rig:GetAttribute("CreatureGrabbing") == true
				and rig:GetAttribute("CreatureEating") ~= true
				and os.clock() - rightDownAt >= cfg.throwAimDelay
			-- The charge builds the whole time you're aiming.
			if aiming then
				aimCharge = math.clamp((os.clock() - rightDownAt - cfg.throwAimDelay) / math.max(cfg.throwChargeTime, 0.05), 0, 1)
			else
				aimCharge = 0
			end
			-- The shoulder camera (and the body facing the aim) holds through the
			-- wind-up and throw, not just while the arc is showing.
			updateAimCamera(state, aiming or throwActive, dt)
			if aiming then
				drawArc(state)
			else
				hideArc()
				-- Dropped or thrown some other way while the button was down.
				if rightDown and rig:GetAttribute("CreatureGrabbing") ~= true then
					rightDown = false
				end
			end
		end

		-- ---- eat charge ----
		if isLocal then
			local eatingNow = rig:GetAttribute("CreatureEating") == true
			local holdingNow = rig:GetAttribute("CreatureGrabbing") == true

			if eatingNow then
				-- Keep holding or they live. Latched, because CreatureEating won't
				-- clear until the server answers and this would otherwise send a
				-- cancel every frame of the round trip.
				if not reach then
					if not state.cancelSent and actionRemote then
						state.cancelSent = true
						actionRemote:FireServer("CancelEat")
					end
				else
					state.eatCharge = 1
				end
			elseif holdingNow and reach then
				state.eatCharge = math.min(state.eatCharge + dt / math.max(cfg.eatChargeTime, 0.05), 1)
				if state.eatCharge >= 1 and not state.eatFired and actionRemote then
					state.eatFired = true
					actionRemote:FireServer("Eat")
				end
			else
				state.eatCharge = math.max(state.eatCharge - dt * cfg.eatReleaseSpeed, 0)
				if state.eatCharge <= 0 then
					state.eatFired = false
					state.cancelSent = false
				end
			end
		else
			state.eatCharge = rig:GetAttribute("EatCharge") or 0
		end

		local targetRise, targetYaw, targetExtend = 0, 0, 0
		local targetShoulderOffset = Vector3.zero
		local stiffness = cfg.armReturnStiffness

		local holding = rig:GetAttribute("CreatureGrabbing") == true

		-- eatCharge > 0 keeps us here while the arm comes down from a bite;
		-- without it, letting go dropped straight to rest and the eat pose
		-- vanished in one frame.
		if isLocal and (reach or holding or state.eatCharge > 0) then
			-- Cast from the TORSO, not the camera: in third person the camera sits
			-- studs behind the creature, and aiming from there offsets everything
			-- by that gap.
			local cam = workspace.CurrentCamera
			local aimDir = cam and cam.CFrame.LookVector or state.torso.CFrame.LookVector
			local aimAt = state.torso.Position + aimDir * cfg.grabRange

			targetRise, targetYaw = anglesToward(state, aimAt)

			-- Clamped on the TARGET, before the spring, so the arm eases into its
			-- limit instead of being yanked back by a post-spring clamp.
			-- Negative yaw is outward (right), positive is across the chest.
			targetYaw = math.clamp(targetYaw,
				-math.rad(cfg.armMaxYawOutward), math.rad(cfg.armMaxYawAcross))
			targetRise = math.clamp(targetRise,
				math.rad(cfg.armMinRise), math.rad(cfg.armMaxRise))

			targetExtend = 1
			stiffness = cfg.armStiffness

			local charge = math.clamp(state.eatCharge, 0, 1)

			if holding or charge > 0 then
				targetRise -= math.rad(cfg.armCarryDroop)
			end

			if charge > 0 then
				local eatRise, eatYaw, eatOffset, eatYawWeight = solveEatPose(state)
				targetRise = targetRise + (eatRise - targetRise) * charge
				targetYaw = blendAngle(targetYaw, eatYaw, charge * eatYawWeight)
				targetShoulderOffset = eatOffset * charge
				-- SOFTENS as it closes. Stiffening made the arm snap the last
				-- stretch to the mouth ? the moment that most wants weight.
				stiffness = cfg.armStiffness * (1 - charge * cfg.eatSoftening)
			end

			--[[
				WINDING UP WHILE YOU CHARGE. The arm pulls back further the longer
				right click is held, reaching the full cocked-behind-the-head pose
				at full charge. Fed in as the spring TARGET, so it's smooth, and it
				goes out on the normal arm replication, so other players see the
				creature winding up too.

				Eased (charge squared at the start) so the first moments move the
				arm a little and it really loads up toward the end.
			--]]
			if isLocal and aimCharge > 0 then
				local c = aimCharge
				local load = 1 - (1 - c) * (1 - c)
				targetRise = targetRise + (math.rad(cfg.throwWindupRise) - targetRise) * load
				targetYaw = blendAngle(targetYaw, math.rad(cfg.throwWindupYaw), load)
				targetExtend = targetExtend + (cfg.throwWindupExtend - targetExtend) * load
			end

			-- Contact test from the hand. The extend gate means the arm has to be
			-- physically most of the way out before it can catch anything.
			if reach and not holding
				and state.extend >= cfg.grabMinExtend
				and os.clock() - lastGrabAttempt > 0.15
				and actionRemote then
				local handPos = state.arm.Position - state.arm.CFrame.UpVector * 1
				if findTargetNearHand(state, handPos) then
					lastGrabAttempt = os.clock()
					actionRemote:FireServer("Grab")
				end
			end

		elseif not isLocal then
			targetRise = math.rad(rig:GetAttribute("ArmRise") or 0)
			targetYaw = math.rad(rig:GetAttribute("ArmYaw") or 0)
			targetExtend = rig:GetAttribute("ArmExtend") or 0
			stiffness = (targetExtend > 0.01) and cfg.armStiffness or cfg.armReturnStiffness

			-- The mouth pose is SOLVED here, not sent: it depends on this rig's own
			-- MouthAttachment, which every client already has. Only the charge
			-- crosses the wire.
			local charge = math.clamp(state.eatCharge, 0, 1)
			if charge > 0 then
				local eatRise, eatYaw, eatOffset, eatYawWeight = solveEatPose(state)
				targetRise = targetRise + (eatRise - targetRise) * charge
				targetYaw = blendAngle(targetYaw, eatYaw, charge * eatYawWeight)
				targetShoulderOffset = eatOffset * charge
			end
		end

		-- ---- springs ----
		local maxVel = math.rad(cfg.armMaxSpeed)
		state.rise, state.riseVel = springStep(state.rise, state.riseVel, targetRise, stiffness, cfg.armDamping, maxVel, dt)
		-- Yaw wraps; rise is 0..180 with no seam, so only yaw needs the angle spring.
		state.yaw, state.yawVel = springStepAngle(state.yaw, state.yawVel, targetYaw, stiffness, cfg.armDamping, maxVel, dt)
		state.extend, state.extendVel = springStep(state.extend, state.extendVel, targetExtend, stiffness, cfg.armDamping, 20, dt)

		--[[
			THE THROW. Written straight over the springs rather than fed to them as a
			target: the springs are tuned heavy, and a 0.12s whip through a heavy
			spring comes out as a lazy wave. So:

			  WIND-UP   eases from wherever the arm was to cocked back behind the head
			  WHIP      accelerates (t squared) forward and down -- the violent part.
			            The body is released partway through, by the server.
			  FOLLOW    holds the finished pose a beat, then hands back to the springs,
			            which carry the arm down to rest from exactly where it stopped.
		--]]
		if throwActive then
			local W, S, F = throwWindup, cfg.throwWhipTime, cfg.throwFollowTime
			local upRise, upYaw = math.rad(cfg.throwWindupRise), math.rad(cfg.throwWindupYaw)
			local downRise, downYaw = math.rad(cfg.throwWhipRise), math.rad(cfg.throwWhipYaw)

			local poseRise, poseYaw, poseExtend, weight
			if throwT < W then
				local p = throwT / math.max(W, 0.01)
				weight = p * p * (3 - 2 * p)
				poseRise, poseYaw, poseExtend = upRise, upYaw, cfg.throwWindupExtend
			elseif throwT < W + S then
				local p = (throwT - W) / math.max(S, 0.01)
				p = p * p
				weight = 1
				poseRise = upRise + (downRise - upRise) * p
				poseYaw = upYaw + (downYaw - upYaw) * p
				poseExtend = cfg.throwWindupExtend + (1 - cfg.throwWindupExtend) * p
			else
				local p = math.clamp((throwT - W - S) / math.max(F, 0.01), 0, 1)
				-- Hold for the first third, then release to the springs.
				local fade = math.clamp((p - 0.33) / 0.67, 0, 1)
				weight = 1 - fade * fade * (3 - 2 * fade)
				poseRise, poseYaw, poseExtend = downRise, downYaw, 1
			end

			state.rise = state.rise + (poseRise - state.rise) * weight
			state.yaw = state.yaw + wrapAngle(poseYaw - state.yaw) * weight
			state.extend = state.extend + (poseExtend - state.extend) * weight
			if weight > 0.5 then
				-- The springs pick up from here afterwards with no stored momentum
				-- yanking the arm somewhere else.
				state.riseVel, state.yawVel, state.extendVel = 0, 0, 0
			end
		end

		-- ---- overlays ----
		local arcOffset, rollOffset, swayRise, swayYaw = 0, 0, 0, 0
		local overlayFade = 1 - math.clamp(state.eatCharge, 0, 1)

		-- ARC: extra lift peaking mid-reach, zero at both ends, so the hand curves
		-- instead of travelling in a straight line. Zero at full extension means
		-- the final pose is unchanged.
		arcOffset = math.sin(math.clamp(state.extend, 0, 1) * math.pi)
			* math.rad(cfg.armReachArc) * overlayFade

		-- TWIST as the limb swings across the body. Subtle on a bare R6 arm; the
		-- difference between a limb and a broom handle with claws welded on.
		rollOffset = -state.yaw * cfg.armRollFactor

		if state.extend > 0.05 then
			local t = os.clock() * cfg.armSwaySpeed + state.swayPhase
			local amount = math.rad(cfg.armSwayAmount) * state.extend * overlayFade
			swayRise = math.sin(t) * amount
			swayYaw = math.sin(t * 0.73 + 1.3) * amount
		end

		--[[
			Straining: the cocked arm trembles more the more it's loaded.

			This was sampling noise 23 times a second, which at full charge read as
			the arm spazzing out rather than straining. Tremble that reads as
			EFFORT is slow and small: a few wavers a second.
		--]]
		if isLocal and aimCharge > 0.3 then
			local strain = ((aimCharge - 0.3) / 0.7) ^ 2
			local amp = math.rad(cfg.throwChargeShake) * strain
			local tt = os.clock() * 6
			swayRise += math.noise(tt, 1.7) * amp
			swayYaw += math.noise(tt, 8.3) * amp * 0.6
		end

		-- ---- chew jolts ----
		local rawChewRise, rawChewRoll, rawChewYaw = 0, 0, 0
		local chewStart = rig:GetAttribute("ChewStart")
		if typeof(chewStart) == "number" then
			local interval = rig:GetAttribute("ChewInterval") or 0.38
			local count = rig:GetAttribute("ChewCount") or 4
			local t = workspace:GetServerTimeNow() - chewStart

			if t >= 0 and t < interval * count then
				local index = math.floor(t / interval)
				local phase = (t / interval) % 1

				-- A crunch needs an ATTACK, not just a decay: starting at full
				-- strength and falling away is a hit mathematically and a jump cut
				-- visually, because nothing ever travels INTO the pose.
				local attack = math.clamp(cfg.chewAttack, 0.01, 0.9)
				local decay
				if phase < attack then
					local p = phase / attack
					decay = p * p * (3 - 2 * p)
				else
					local p = (phase - attack) / (1 - attack)
					decay = (1 - p) * (1 - p)
				end

				local dir = (index % 2 == 0) and 1 or -1
				rawChewRise = math.rad(cfg.chewShakeAmount) * decay * dir
				rawChewRoll = math.rad(cfg.chewShakeAmount * 0.7) * decay * -dir
				rawChewYaw = math.rad(cfg.chewShakeAmount * 0.35) * decay * dir
			end
		end

		-- Smoothed, unlike the other overlays. The jolt is a fast, LARGE step, and
		-- applied raw the arm teleports to each point on the curve instead of
		-- travelling there ? that was the snap, and reshaping the curve never
		-- fixed it because the curve was never the problem.
		local chewFollow = 1 - math.exp(-cfg.chewSmoothing * dt)
		state.chewRise += (rawChewRise - state.chewRise) * chewFollow
		state.chewRoll += (rawChewRoll - state.chewRoll) * chewFollow
		state.chewYaw += (rawChewYaw - state.chewYaw) * chewFollow

		arcOffset += state.chewRise
		rollOffset += state.chewRoll
		swayYaw += state.chewYaw

		-- ---- write C0 ----
		local follow = 1 - math.exp(-cfg.eatShoulderResponse * dt)
		state.shoulderOffset = state.shoulderOffset:Lerp(targetShoulderOffset, follow)

		local finalRise = state.rise + arcOffset + swayRise
		local finalYaw = state.yaw + swayYaw

		local pushDir = Vector3.new(
			-math.sin(state.rise) * math.sin(state.yaw),
			-math.cos(state.rise),
			-math.sin(state.rise) * math.cos(state.yaw)
		)
		local pivot = state.basePos
			+ pushDir * (state.extend * cfg.armExtendPush)
			+ state.shoulderOffset

		state.shoulder.C0 = CFrame.new(pivot)
			* CFrame.Angles(0, finalYaw, 0)
			* CFrame.Angles(finalRise, 0, rollOffset)
			* state.baseRot

		-- ---- publish ----
		if isLocal and aimRemote then
			local now = os.clock()
			if now - state.lastSendT >= cfg.armSendInterval then
				local riseDeg, yawDeg = math.deg(targetRise), math.deg(targetYaw)
				local charge = math.clamp(state.eatCharge, 0, 1)
				-- Charge gets its own threshold: the angles barely move during a
				-- charge, so waiting on an angle change would send the whole lift
				-- as one jump at the end.
				if math.abs(riseDeg - state.lastSentRise) >= cfg.armSendMinDelta
					or math.abs(yawDeg - state.lastSentYaw) >= cfg.armSendMinDelta
					or math.abs(charge - state.sentCharge) >= 0.06 then
					state.lastSendT = now
					state.lastSentRise, state.lastSentYaw = riseDeg, yawDeg
					state.sentCharge = charge
					aimRemote:FireServer(riseDeg, yawDeg, targetExtend, charge)
				end
			end
		end
	end
end

return System
