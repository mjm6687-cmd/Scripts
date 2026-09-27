-- CreatureHeadServer
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- Relays each creature's head aim to everyone else.
--
-- The client can't replicate anything by itself — a client writing an attribute
-- is local only. So the owner sends its aim here, and the server writes it to the
-- character as LookYaw / LookPitch attributes, which DO replicate to every client.
-- CreatureHead on each client reads those and springs the neck toward them.
--
-- Attributes rather than a broadcast RemoteEvent on purpose: they carry the
-- current value to players who join or stream in later, and they cost nothing when
-- nobody is looking. A broadcast would have to be re-sent forever to achieve that.
--
-- The RemoteEvent is created here at runtime, so there's nothing to add by hand.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_NAME = "CreatureLookRemote"

local YAW_LIMIT = 89      -- hard server-side clamps; a client that sends nonsense
local PITCH_LIMIT = 89    -- gets clamped rather than snapping someone's head off
local MIN_INTERVAL = 1 / 20  -- rate limit per player

local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
end

local lastFire: { [Player]: number } = {}

remote.OnServerEvent:Connect(function(player, yaw, pitch)
	-- Everything below is a validity check on data that came from a client, so
	-- none of it can be trusted: wrong types, NaN, spam, or aiming a creature the
	-- sender doesn't own.
	if typeof(yaw) ~= "number" or typeof(pitch) ~= "number" then
		return
	end
	if yaw ~= yaw or pitch ~= pitch then -- NaN
		return
	end

	local now = os.clock()
	local last = lastFire[player]
	if last and now - last < MIN_INTERVAL then
		return
	end
	lastFire[player] = now

	local char = player.Character
	if not char then
		return
	end
	if char:GetAttribute("IsCreature") ~= true then
		return
	end

	char:SetAttribute("LookYaw", math.clamp(yaw, -YAW_LIMIT, YAW_LIMIT))
	char:SetAttribute("LookPitch", math.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT))
end)

Players.PlayerRemoving:Connect(function(player)
	lastFire[player] = nil
end)
