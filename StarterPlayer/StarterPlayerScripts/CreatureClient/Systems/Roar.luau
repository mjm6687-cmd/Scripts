-- Roar  (ModuleScript, under CreatureClient > Systems)
--
-- R, C and V fire the three roars. Input only — the server owns playback, because
-- a roar has to be heard by everyone.
--
-- The moving flag is SENT rather than read server-side. CreatureMoving is written
-- by CreatureMovement, a LocalScript, and attributes written by a client never
-- reach the server: it read nil every time and played the idle roar no matter
-- what you were doing. Only the client knows anyway — "moving" here means
-- CreatureMovement's own notion, including the coast-to-stop.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local System = {
	name = "Roar",
	key = "roar",
	scope = "local",
}

local KEY_TO_ROAR = {
	[Enum.KeyCode.R] = 1,
	[Enum.KeyCode.C] = 2,
	[Enum.KeyCode.V] = 3,
}

local SEND_COOLDOWN = 0.25 -- keeps a held key off the wire; the server has its own

local player = Players.LocalPlayer
local CreatureUtil
local roarRemote: RemoteEvent?
local lastSent = 0

function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil

	-- Spawned, not awaited: a WaitForChild here would block CreatureClient's
	-- whole startup for 30 seconds if CreatureRoarServer isn't in place.
	task.spawn(function()
		roarRemote = ReplicatedStorage:WaitForChild("CreatureRoarRemote", 30)
		if not roarRemote then
			warn("[Roar] CreatureRoarRemote never appeared — is CreatureRoarServer in ServerScriptService?")
		end
	end)

	-- Bound ONCE and never unbound. Unbinding on unmorph killed it permanently:
	-- the script runs a single time per player, so nothing ever re-bound it.
	-- The handler checks IsCreature per press and passes through otherwise.
	ContextActionService:BindActionAtPriority("Creature_Roar", function(_, inputState, inputObject)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end

		local index = KEY_TO_ROAR[inputObject.KeyCode]
		if not index then
			return Enum.ContextActionResult.Pass
		end

		local char = player.Character
		if not (char and CreatureUtil.IsCreature(char)) then
			return Enum.ContextActionResult.Pass
		end
		if not roarRemote then
			return Enum.ContextActionResult.Sink
		end

		local now = os.clock()
		if now - lastSent < SEND_COOLDOWN then
			return Enum.ContextActionResult.Sink
		end
		lastSent = now

		roarRemote:FireServer(index, char:GetAttribute("CreatureMoving") == true)
		return Enum.ContextActionResult.Sink
	end, false, 2400, Enum.KeyCode.R, Enum.KeyCode.C, Enum.KeyCode.V)
end

return System
