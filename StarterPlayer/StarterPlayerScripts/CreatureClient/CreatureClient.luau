-- CreatureClient
-- CLASS: LocalScript
-- PLACE IN: StarterPlayer > StarterPlayerScripts
--
-- The one entry point for every client-side creature system. Add a ModuleScript
-- to the Systems folder underneath this and it runs; no other wiring.
--
-- ============================================================
-- WHAT THIS OWNS SO THE SYSTEMS DON'T HAVE TO
-- ============================================================
--   * ONE CollectionService hook, instead of nine
--   * ONE RenderStepped loop, instead of six
--   * ONE config load per creature, cached � they were each requiring the rig's
--     CreatureConfig separately
--   * ERROR ISOLATION. A system that throws is switched off and reported; the
--     others carry on. In a single flat script one bad line took down everything
--     below it.
--   * EXPLICIT ORDER. CreatureArm and CreatureHead both write Motor6D C0s and
--     CreatureMovement writes RootJoint. Before, the order was whatever order
--     the connections happened to be made in. Now it's the order of ORDER below.
--
-- ============================================================
-- SYSTEM INTERFACE
-- ============================================================
-- A system module returns a table. Every field is optional except `scope`.
--
--   scope = "rig"    runs for EVERY creature in the world, local or not
--                    (footsteps, head turn, arm, eyes � things others see)
--   scope = "local"  runs only while YOU are a creature
--                    (vision, thermal, camera, mouse, roar input)
--
--   key       = "thermal"   name in config.systems used to switch it off
--   init(ctx)               once at startup
--   onAdded(rig, cfg, isLocal)
--   onRemoved(rig)
--   update(dt)              every frame, only while something is active
--
-- A "local" system's onAdded/onRemoved receive the local character.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local CreatureUtil = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CreatureUtil"))

local player = Players.LocalPlayer

-- Frame order. Anything not listed still runs, after these, in load order.
-- Movement first (it owns the root), then the joints that hang off it, then the
-- purely visual passes.
local ORDER = {
	"Head",
	"Arm",
	"Eyes",
	"Footsteps",
	"Camera",
	"Mouse",
	"Vision",
	"NightVision",
	"Thermal",
	"Roar",
	"RoarEffects",
	"RoarWave",
	"CombatCue",
}

-- ============================================================
-- LOAD
-- ============================================================
local systemsFolder = script:WaitForChild("Systems")
local systems = {}

do
	local byName = {}
	for _, module in ipairs(systemsFolder:GetChildren()) do
		if module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if not ok then
				warn(("[CreatureClient] '%s' failed to load: %s"):format(module.Name, tostring(result)))
			elseif typeof(result) ~= "table" then
				warn(("[CreatureClient] '%s' did not return a table."):format(module.Name))
			else
				result.name = result.name or module.Name
				result.scope = result.scope or "rig"
				result.key = result.key or string.lower(result.name)
				byName[module.Name] = result
			end
		end
	end

	for _, name in ipairs(ORDER) do
		if byName[name] then
			table.insert(systems, byName[name])
			byName[name] = nil
		end
	end
	for _, leftover in pairs(byName) do
		table.insert(systems, leftover)
	end
end

-- ============================================================
-- SAFETY
-- ============================================================
-- A system that errors is disabled rather than left to throw every frame. One
-- warning, not sixty a second � a spamming Output is how you lose the actual
-- error in the noise.
local dead = {}

local function guard(system, fnName, ...)
	local fn = system[fnName]
	if not fn or dead[system] then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		dead[system] = true
		warn(("[CreatureClient] '%s' disabled � error in %s: %s")
			:format(system.name, fnName, tostring(err)))
	end
end

-- ============================================================
-- CONFIG
-- ============================================================
local configCache: { [Model]: any } = {}

local function getConfig(rig: Model)
	local cached = configCache[rig]
	if cached ~= nil then
		return cached
	end

	local cfg = {}
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, userCfg = pcall(require, module)
		if ok and typeof(userCfg) == "table" then
			cfg = userCfg
		end
	end

	configCache[rig] = cfg
	return cfg
end

--[[
	PER-CREATURE SYSTEMS.

	config.systems = { thermal = false, eyes = false }

	Absent means ON. A creature with no eyes to blink simply never starts that
	system, rather than starting it so it can discover it has nothing to do.
--]]
local function systemEnabled(system, cfg): boolean
	local list = cfg.systems
	if typeof(list) ~= "table" then
		return true
	end
	return list[system.key] ~= false
end

-- ============================================================
-- STATE
-- ============================================================
local activeRigs: { [Model]: boolean } = {}
local localActive = false

local function addRig(rig: Model)
	if activeRigs[rig] then
		return
	end
	activeRigs[rig] = true

	local cfg = getConfig(rig)
	local isLocal = (rig == player.Character)

	for _, system in ipairs(systems) do
		if system.scope == "rig" and systemEnabled(system, cfg) then
			guard(system, "onAdded", rig, cfg, isLocal)
		end
	end
end

local function removeRig(rig: Model)
	if not activeRigs[rig] then
		return
	end
	activeRigs[rig] = nil
	configCache[rig] = nil

	for _, system in ipairs(systems) do
		if system.scope == "rig" then
			guard(system, "onRemoved", rig)
		end
	end
end

local function setLocalCreature(char: Model?)
	if char then
		if localActive then
			return
		end
		localActive = true

		local cfg = getConfig(char)
		for _, system in ipairs(systems) do
			if system.scope == "local" and systemEnabled(system, cfg) then
				guard(system, "onAdded", char, cfg, true)
			end
		end
	else
		if not localActive then
			return
		end
		localActive = false

		for _, system in ipairs(systems) do
			if system.scope == "local" then
				guard(system, "onRemoved")
			end
		end
	end
end

-- ============================================================
-- START
-- ============================================================
local ctx = {
	player = player,
	CreatureUtil = CreatureUtil,
	getConfig = getConfig,
	isRigActive = function(rig)
		return activeRigs[rig] == true
	end,
}

for _, system in ipairs(systems) do
	guard(system, "init", ctx)
end

for _, rig in ipairs(CollectionService:GetTagged(CreatureUtil.TAG)) do
	task.spawn(addRig, rig)
end

CollectionService:GetInstanceAddedSignal(CreatureUtil.TAG):Connect(function(rig)
	task.spawn(addRig, rig)
end)

CollectionService:GetInstanceRemovedSignal(CreatureUtil.TAG):Connect(removeRig)

local function onCharacter(char: Model)
	if CreatureUtil.IsCreature(char) then
		setLocalCreature(char)
	else
		setLocalCreature(nil)
	end
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end

-- Safety net shared by every local system: if the creature goes away without a
-- replacement arriving, don't leave the player stuck with red vision, a hidden
-- cursor and a locked camera for the rest of the session.
player.CharacterRemoving:Connect(function(char)
	if CreatureUtil.IsCreature(char) then
		task.delay(Players.RespawnTime + 3, function()
			if player.Character == nil or not CreatureUtil.IsCreature(player.Character) then
				setLocalCreature(nil)
			end
		end)
	end
end)

RunService.RenderStepped:Connect(function(dt)
	for _, system in ipairs(systems) do
		if system.update then
			guard(system, "update", dt)
		end
	end
end)

local names = {}
for _, s in ipairs(systems) do
	table.insert(names, s.name)
end
print("[CreatureClient] " .. #systems .. " systems: " .. table.concat(names, ", "))
