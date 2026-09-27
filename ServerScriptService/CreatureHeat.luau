-- CreatureHeat
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- How hot each creature looks on THERMALS: the night-vision ECOTI outlines and the
-- Recon Drone's IR modes. Published as a ThermalHeat attribute (0-1) on the rig,
-- which the thermal scripts multiply the creature's outline by.
--
-- ============================================================
-- COLD-BLOODED
-- ============================================================
-- At rest the creature barely registers -- a faint shape you have to be looking
-- for. What it DOES heats it up, and that heat takes time to go away:
--
--   SPRINTING  builds over a second or two of running, cools slowly after
--   ROARING    a full-strength flash the moment it roars, fading over seconds --
--              roaring gives your position away to anyone watching on thermal
--   EATING     hot from the kill, lingering long after
--
-- The layers don't add up; the hottest one wins. So a creature can stalk nearly
-- invisibly if it moves slowly, but charging, roaring or feeding lights it up.
--
-- Worked out HERE, not on the creature's own computer, so it can't be faked: the
-- server sees how fast the creature is actually moving, and it's the server that
-- runs the roar and the kill.
--
-- Everything is tunable per creature in CreatureConfig (the THERMAL SIGNATURE
-- section); the numbers below are the fallbacks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CreatureUtil = require(ReplicatedStorage.Shared.CreatureUtil)

local DEFAULTS = {
	heatBase = 0.15,          -- at rest. 0 = invisible on thermal, 1 = a normal body
	heatSprintMax = 0.75,     -- fully exerted from sprinting
	heatSprintBuild = 1.5,    -- s of sprinting to reach heatSprintMax
	heatSprintCool = 5,       -- s to cool all the way back down after
	heatRoar = 1,             -- the flash when it roars
	heatRoarHold = 0.4,       -- s at full flash before it fades
	heatRoarFade = 3,         -- s to fade from the flash
	heatFed = 0.9,            -- right after a kill
	heatFedFade = 25,         -- s for the kill's heat to fade
	walkSpeed = 9,            -- read from the creature's own walkSpeed
}

-- Studs/s over walkSpeed that counts as sprinting. Covers the speed ramp's small
-- overshoot and slope wobble at a normal walk, same slack the grab uses.
local SPRINT_SLACK = 3

-- Ticks per second. Heat changes slowly, and the thermal scripts only rescan four
-- times a second anyway.
local TICK = 0.1

-- The attribute is only rewritten when it has moved at least this much, so a
-- creature at rest isn't replicating a new number ten times a second.
local PUBLISH_STEP = 0.02

local states: { [Model]: any } = {}

local function loadConfig(rig: Model)
	local cfg = table.clone(DEFAULTS)
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, userCfg = pcall(require, module)
		if ok and typeof(userCfg) == "table" then
			for k in pairs(DEFAULTS) do
				if typeof(userCfg[k]) == "number" then
					cfg[k] = userCfg[k]
				end
			end
		end
	end
	return cfg
end

local function stateFor(rig: Model)
	local state = states[rig]
	if not state then
		state = {
			cfg = loadConfig(rig),
			exertion = 0,        -- 0-1, how worked up it is from sprinting
			roarAt = nil,        -- os.clock() of the last roar's start
			wasRoaring = false,
			published = -1,
		}
		states[rig] = state
	end
	return state
end

local function heatOf(rig: Model, state, dt: number): number
	local cfg = state.cfg
	local now = os.clock()

	-- SPRINTING, from how fast the creature is really moving.
	local root = rig:FindFirstChild("HumanoidRootPart")
	local speed = 0
	if root and root:IsA("BasePart") then
		local v = root.AssemblyLinearVelocity
		speed = Vector3.new(v.X, 0, v.Z).Magnitude
	end
	if speed > cfg.walkSpeed + SPRINT_SLACK then
		state.exertion = math.min(state.exertion + dt / math.max(cfg.heatSprintBuild, 0.05), 1)
	else
		state.exertion = math.max(state.exertion - dt / math.max(cfg.heatSprintCool, 0.05), 0)
	end
	local sprintHeat = cfg.heatSprintMax * state.exertion

	-- ROARING: CreatureRoarServer sets CreatureRoaring for the length of a roar.
	-- The flash fires on the moment it starts.
	local roaring = rig:GetAttribute("CreatureRoaring") == true
	if roaring and not state.wasRoaring then
		state.roarAt = now
	end
	state.wasRoaring = roaring
	local roarHeat = 0
	if state.roarAt then
		local since = now - state.roarAt - cfg.heatRoarHold
		roarHeat = cfg.heatRoar * math.clamp(1 - since / math.max(cfg.heatRoarFade, 0.05), 0, 1)
	end

	-- EATING: CreatureGrabServer stamps LastFed at the killing bite.
	local fedHeat = 0
	local lastFed = rig:GetAttribute("LastFed")
	if typeof(lastFed) == "number" then
		local since = workspace:GetServerTimeNow() - lastFed
		fedHeat = cfg.heatFed * math.clamp(1 - since / math.max(cfg.heatFedFade, 0.05), 0, 1)
	end

	return math.clamp(math.max(cfg.heatBase, sprintHeat, roarHeat, fedHeat), 0, 1)
end

local function addRig(rig: Instance)
	if rig:IsA("Model") then
		local state = stateFor(rig)
		-- Published straight away, so a thermal looking at a freshly morphed
		-- creature never sees it at full brightness for the first tick.
		state.published = state.cfg.heatBase
		rig:SetAttribute("ThermalHeat", state.cfg.heatBase)
	end
end

for _, rig in ipairs(CollectionService:GetTagged(CreatureUtil.TAG)) do
	addRig(rig)
end
CollectionService:GetInstanceAddedSignal(CreatureUtil.TAG):Connect(addRig)
CollectionService:GetInstanceRemovedSignal(CreatureUtil.TAG):Connect(function(rig)
	states[rig] = nil
end)

task.spawn(function()
	local last = os.clock()
	while true do
		task.wait(TICK)
		local now = os.clock()
		local dt = now - last
		last = now

		for rig, state in pairs(states) do
			if not rig.Parent then
				states[rig] = nil
			else
				local heat = heatOf(rig, state, dt)
				if math.abs(heat - state.published) >= PUBLISH_STEP
					or (heat == state.cfg.heatBase and state.published ~= heat) then
					state.published = heat
					rig:SetAttribute("ThermalHeat", math.round(heat * 100) / 100)
				end
			end
		end
	end
end)
