--[[
	AuroraClient  --  LocalScript in StarterPlayer > StarterPlayerScripts
	---------------------------------------------------------------------
	Builds tonight's aurora on this client from the seed AuroraServer publishes
	(same seed = same sky for everyone) and animates it.

	It shows only when:
	  * it's dark (fades in over dusk, out over dawn -- matches LightingCycle)
	  * it's inside tonight's on/off window (rolled by AuroraServer)
	  * the sky is clear: StormFactor / SnowFactor and heavy cloud hide it
	and it flares up during the server's surges.

	Needs ReplicatedStorage > Shared > AuroraShape (ModuleScript).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AuroraShape = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AuroraShape"))

-- Darkness, as Lighting.ClockTime. LightingCycle's dusk runs 17 -> 19 and its
-- sunrise 4.7 -> 6.7; the aurora needs the sky properly dark, so it comes in
-- late in dusk and goes early in the dawn.
local DUSK_START, DUSK_FULL = 18.3, 19.3
local DAWN_START, DAWN_GONE = 4.4, 5.4

local WINDOW_FADE = 0.75 -- game hours to fade in after onset / out before the end

-- Heavy cloud hides it too. Terrain.Clouds.Cover from here up starts hiding it,
-- fully gone at CLOUD_GONE. Raise both if your clear nights have high cover.
local CLOUD_HIDE, CLOUD_GONE = 0.75, 0.95

local VISIBILITY_EASE = 2 -- seconds; smooths sudden changes (weather flips, testing)
local UPDATE_RATE = 30    -- animation updates per second

-------------------------------------------------------------------------------

local shape = nil
local building = false
local rebuildQueued = false

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function darkness(clock: number): number
	if clock >= 12 then
		return smooth((clock - DUSK_START) / (DUSK_FULL - DUSK_START))
	end
	return 1 - smooth((clock - DAWN_START) / (DAWN_GONE - DAWN_START))
end

local function window(): number
	local onset = Lighting:GetAttribute("AuroraOnset")
	local ends = Lighting:GetAttribute("AuroraEnd")
	if not onset or not ends then return 0 end
	local h = (Lighting.ClockTime - 12) % 24
	return smooth((h - onset) / WINDOW_FADE) * smooth((ends - h) / WINDOW_FADE)
end

local function clearSky(): number
	local block = math.max(
		Lighting:GetAttribute("StormFactor") or 0,
		Lighting:GetAttribute("SnowFactor") or 0
	)
	local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds")
	if clouds and clouds.Enabled then
		block = math.max(block, smooth((clouds.Cover - CLOUD_HIDE) / (CLOUD_GONE - CLOUD_HIDE)))
	end
	return 1 - math.clamp(block, 0, 1)
end

-- Surge envelope: quick rise (first 20%), long fade.
local function surge(): number
	local start = Lighting:GetAttribute("AuroraBurstStart") or 0
	local length = Lighting:GetAttribute("AuroraBurstLength") or 0
	local power = Lighting:GetAttribute("AuroraBurstPower") or 0
	if length <= 0 or power <= 0 then return 0 end
	local e = workspace:GetServerTimeNow() - start
	if e < 0 or e > length then return 0 end
	local rise = length * 0.2
	if e < rise then
		return power * smooth(e / rise)
	end
	return power * (1 - smooth((e - rise) / (length - rise)))
end

local function rebuild()
	if building then
		rebuildQueued = true
		return
	end
	building = true
	repeat
		rebuildQueued = false
		if shape then
			AuroraShape.Destroy(shape)
			shape = nil
		end
		local seed = Lighting:GetAttribute("AuroraSeed")
		local activity = Lighting:GetAttribute("AuroraActivity")
		if seed and activity and activity ~= "None" then
			local newShape = AuroraShape.Build({
				seed = seed,
				activity = activity,
				center = Lighting:GetAttribute("AuroraCenter") or Vector3.zero,
				yaw = Lighting:GetAttribute("AuroraYaw") or 0,
				area = Lighting:GetAttribute("AuroraArea"),
				yield = true,
			})
			if rebuildQueued then
				AuroraShape.Destroy(newShape) -- settings changed mid-build; go again
			else
				AuroraShape.Update(newShape, 0, 0, 0) -- start hidden
				newShape.folder.Parent = workspace
				shape = newShape
			end
		end
	until not rebuildQueued
	building = false
end

-- The server sets several attributes together; rebuild once, a moment later.
local pending = false
local function queueRebuild()
	if pending then return end
	pending = true
	task.delay(0.2, function()
		pending = false
		rebuild()
	end)
end

for _, name in ipairs({ "AuroraSeed", "AuroraActivity", "AuroraCenter", "AuroraYaw", "AuroraArea" }) do
	Lighting:GetAttributeChangedSignal(name):Connect(queueRebuild)
end
queueRebuild()

local visibility = nil
local accum = 0

RunService.Heartbeat:Connect(function(dt)
	if not shape then
		visibility = nil
		return
	end
	accum += dt
	if accum < 1 / UPDATE_RATE then return end
	local step = accum
	accum = 0

	local target = darkness(Lighting.ClockTime) * window() * clearSky()
	if visibility == nil then
		visibility = target
	else
		visibility += (target - visibility) * (1 - math.exp(-step / VISIBILITY_EASE * 3))
	end
	AuroraShape.Update(shape, step, visibility, surge())
end)
