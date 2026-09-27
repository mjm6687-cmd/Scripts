-- Head  (ModuleScript, under CreatureClient > Systems)
--
-- Head turning: the Neck Motor6D's C0 is rotated so the head looks where the
-- camera is aimed.
--
-- WHY C0: animations write .Transform, never .C0, so rotating C0 composes ON TOP
-- of whatever animation is playing instead of being overwritten every frame.
--
-- WHY A SPRING, NOT A LERP: a lerp always eases out and arrives — light and
-- mechanical. A spring has to overcome its own inertia to start, overshoots, then
-- settles. Whip the camera and the head visibly lags before catching up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = {
	name = "Head",
	key = "head",
	scope = "rig",
}

local DEFAULTS = {
	headYawLimit = 45,
	headPitchLimit = 20,
	headStiffness = 28,       -- LOWER = heavier. The main dial.
	headDamping = 7,
	headMaxSpeed = 220,
	headCenterWhenSprinting = 0.7,
	headSendInterval = 1 / 12,
	headSendMinDelta = 1.5,
}

local player = Players.LocalPlayer
local rigs: { [Model]: any } = {}
local remote: RemoteEvent?

function System.init()
	task.spawn(function()
		remote = ReplicatedStorage:WaitForChild("CreatureLookRemote", 30)
		if not remote then
			warn("[Head] CreatureLookRemote never appeared — is CreatureHeadServer running?")
		end
	end)
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
		if not torso or not rig.Parent then
			return
		end

		local neck = torso:WaitForChild("Neck", 10)
		if not (neck and neck:IsA("Motor6D")) then
			warn("[Head] " .. rig:GetFullName() .. ".Torso has no Neck Motor6D.")
			return
		end

		local humanoid = rig:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end

		-- The neutral pose, taken from the attribute the SERVER published off the
		-- template rather than from the live joint. Reading the live joint means
		-- whatever value happened to be there when this client bound becomes its
		-- idea of neutral — so a client binding a frame late builds every pose on
		-- a different baseline, and the head looks fine to its owner and wrong to
		-- everybody else.
		local baseC0 = rig:GetAttribute("NeckBaseC0")
		if typeof(baseC0) ~= "CFrame" then
			baseC0 = neck.C0
		end

		rigs[rig] = {
			rig = rig,
			neck = neck,
			torso = torso,
			humanoid = humanoid,
			cfg = cfg,
			basePos = baseC0.Position,
			baseRot = baseC0 - baseC0.Position,
			yaw = 0, yawVel = 0,
			pitch = 0, pitchVel = 0,
			lastSendT = 0,
			lastSentYaw = 0,
			lastSentPitch = 0,
		}
	end)
end

function System.onRemoved(rig: Model)
	local state = rigs[rig]
	if state then
		-- Put the neck back, so a corpse or a reused rig isn't left cranked round.
		pcall(function()
			state.neck.C0 = CFrame.new(state.basePos) * state.baseRot
		end)
	end
	rigs[rig] = nil
end

local function springStep(current, vel, target, cfg, dt)
	local force = (target - current) * cfg.headStiffness - vel * cfg.headDamping
	local maxVel = math.rad(cfg.headMaxSpeed)
	vel = math.clamp(vel + force * dt, -maxVel, maxVel)
	return current + vel * dt, vel
end

local function localAim(state): (number, number)
	local cam = workspace.CurrentCamera
	if not cam then
		return 0, 0
	end
	local dir = state.torso.CFrame:VectorToObjectSpace(cam.CFrame.LookVector)
	-- Object-space forward is -Z, so yaw is 0 looking ahead, positive looking left.
	return math.atan2(-dir.X, -dir.Z), math.asin(math.clamp(dir.Y, -1, 1))
end

function System.update(dt: number)
	for rig, state in pairs(rigs) do
		if not rig.Parent or not state.neck.Parent or state.humanoid.Health <= 0 then
			System.onRemoved(rig)
			continue
		end

		local cfg = state.cfg
		local isLocal = (rig == player.Character)
		local targetYaw, targetPitch

		if isLocal then
			targetYaw, targetPitch = localAim(state)
		else
			-- Replicated aim, in degrees.
			targetYaw = math.rad(rig:GetAttribute("LookYaw") or 0)
			targetPitch = math.rad(rig:GetAttribute("LookPitch") or 0)
		end

		-- A sprinting creature commits its head to the direction of travel. Free
		-- looking at full speed is the single thing that most undoes the weight
		-- the movement system builds.
		if rig:GetAttribute("CreatureSprinting") == true then
			local blend = 1 - math.clamp(cfg.headCenterWhenSprinting, 0, 1)
			targetYaw *= blend
			targetPitch *= blend
		end

		local yawLimit = math.rad(cfg.headYawLimit)
		local pitchLimit = math.rad(cfg.headPitchLimit)
		targetYaw = math.clamp(targetYaw, -yawLimit, yawLimit)
		targetPitch = math.clamp(targetPitch, -pitchLimit, pitchLimit)

		state.yaw, state.yawVel = springStep(state.yaw, state.yawVel, targetYaw, cfg, dt)
		state.pitch, state.pitchVel = springStep(state.pitch, state.pitchVel, targetPitch, cfg, dt)

		-- Rebuilt from the captured base every frame, never from the previous
		-- frame's value: accumulating onto a modified C0 drifts the head further
		-- out of place each frame until it visibly detaches.
		state.neck.C0 = CFrame.new(state.basePos)
			* CFrame.Angles(state.pitch, state.yaw, 0)
			* state.baseRot

		if isLocal and remote then
			local now = os.clock()
			if now - state.lastSendT >= cfg.headSendInterval then
				local yawDeg, pitchDeg = math.deg(targetYaw), math.deg(targetPitch)
				if math.abs(yawDeg - state.lastSentYaw) >= cfg.headSendMinDelta
					or math.abs(pitchDeg - state.lastSentPitch) >= cfg.headSendMinDelta then
					state.lastSendT = now
					state.lastSentYaw, state.lastSentPitch = yawDeg, pitchDeg
					remote:FireServer(yawDeg, pitchDeg)
				end
			end
		end
	end
end

return System
