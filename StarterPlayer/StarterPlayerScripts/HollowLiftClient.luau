-- HollowLiftClient
-- CLASS: LocalScript
-- PLACE IN: StarterPlayer > StarterPlayerScripts
--
-- Brings every Hollow Lift anomaly to life:
--   * ROCKS: grit orbits tight round the orb, bigger rocks on slower tilted
--     orbits, the Deep boulder turns in place, the rim slabs just sway.
--   * ORB LIGHTS: they breathe (brightness and reach swell and ease), shimmer
--     unevenly, drift between blue and violet, and every half minute or so
--     surge: flare brighter, whiter and wider, then fade back.
-- Only the anomaly's own rocks and lights are touched: no camera, Lighting
-- service or screen effects.
--
-- Finds anomalies by the "HollowLift" tag (the builder adds it) or by the
-- name HollowLift. Rocks are the parts named Grit, Rock, Boulder and Slab
-- inside its Rocks folder; the orb's Lens part is the centre.
--
-- It all runs locally, so the moving rocks never touch the network, and it
-- is timed off the server clock so every player sees them in the same place.
-- Anomalies further than CULL_DISTANCE from the camera aren't animated.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TAG = "HollowLift"
local CULL_DISTANCE = 350

-- Per kind of rock: seconds per turn, tilt of its orbit (fraction of its
-- radius), bob height and period, tumble speed (degrees per second).
-- Orb light animation. Brightness/range are multiples of the values the
-- builder set (stored as BaseBrightness / BaseRange attributes on each light).
local LIGHT = {
	breathePeriod = 8,        -- seconds per breath
	breathe = 0.35,           -- how much a breath adds
	shimmer = 0.08,           -- constant uneven waver
	colourPeriod = 23,        -- seconds for one blue -> violet -> blue drift
	surgeEvery = { 25, 40 },  -- seconds between surges (varies per anomaly)
	surgeLength = 4.5,        -- seconds to fade back after a surge
	surgeBoost = 1.4,         -- extra brightness at the peak of a surge
	surgeReach = 0.3,         -- extra range at the peak (fraction)
	blue = Color3.fromRGB(180, 194, 255),
	violet = Color3.fromRGB(200, 178, 255),
	white = Color3.fromRGB(235, 238, 255),
	-- how strongly each light follows the effects
	OrbLight   = { breathe = 1,   surge = 1,   range = true },
	FloorLight = { breathe = 0.8, surge = 0.7, range = false },
	CoreLight  = { breathe = 1.2, surge = 1.6, range = true },
}

local KINDS = {
	Grit    = { turn = { 60, 90 },   tilt = { 0.05, 0.2 }, bob = 0.15, bobT = { 3, 5 },  spin = { 15, 35 } },
	Rock    = { turn = { 120, 180 }, tilt = { 0.1, 0.3 },  bob = 0.3,  bobT = { 5, 7 },  spin = { 3, 8 } },
	Boulder = { turn = { 400, 400 }, tilt = { 0, 0 },      bob = 0.5,  bobT = { 8, 10 }, spin = { 1.5, 2.5 } },
	Slab    = { still = true,        bob = 0.08, bobT = { 9, 12 },    sway = 1.2 },
}

-------------------------------------------------------------------------------

local anomalies = {} -- [Model] = { centre = Part?, rocks = { [BasePart] = info } }

-- A stable pseudo-random number in [a, b] from a seed (so every client picks
-- the same speeds for the same rock).
local function hashRand(seed: number, a: number, b: number): number
	local x = math.sin(seed * 12.9898 + 78.233) * 43758.5453
	return a + (b - a) * (x - math.floor(x))
end

-- The orb centre: the builder stores it as an attribute (always there, even
-- before the orb streams in); otherwise the Lens part; otherwise the pivot.
local function centreOf(model: Model): Vector3
	local c = model:GetAttribute("OrbCentre")
	if typeof(c) == "Vector3" then
		return c
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Lens" then
			return d.Position
		end
	end
	return model:GetPivot().Position
end

local function addRock(entry, part: BasePart)
	local kind = KINDS[part.Name]
	if not kind or entry.rocks[part] then
		return
	end
	local centre = entry.centre
	local cf = part.CFrame
	local rel = cf.Position - centre
	local seed = cf.Position.X * 0.37 + cf.Position.Y * 1.73 + cf.Position.Z * 0.91
	local info = {
		kind = kind,
		rot = cf - cf.Position,            -- starting orientation
		base = cf.Position,
		r = Vector3.new(rel.X, 0, rel.Z).Magnitude,
		a0 = math.atan2(rel.Z, rel.X),
		y0 = rel.Y,
		bobT = hashRand(seed + 3, kind.bobT[1], kind.bobT[2]),
		bobPhase = hashRand(seed + 4, 0, 2 * math.pi),
	}
	if kind.still then
		local ang = hashRand(seed + 5, 0, 2 * math.pi)
		info.swayAxis = Vector3.new(math.cos(ang), 0, math.sin(ang))
		info.swayT = hashRand(seed + 6, 10, 14)
	else
		info.turn = hashRand(seed + 1, kind.turn[1], kind.turn[2])
		-- Grit alternates direction by height band; bigger rocks all go one way.
		if part.Name == "Grit" then
			info.dir = (math.floor(rel.Y / 3) % 2 == 0) and 1 or -1
		else
			info.dir = 1
		end
		info.tiltAmp = info.r * hashRand(seed + 2, kind.tilt[1], kind.tilt[2])
		info.tiltPhase = hashRand(seed + 7, 0, 2 * math.pi)
		local ax = Vector3.new(hashRand(seed + 8, -1, 1), hashRand(seed + 9, -1, 1), hashRand(seed + 10, -1, 1))
		info.spinAxis = ax.Magnitude > 0.01 and ax.Unit or Vector3.yAxis
		info.spin = math.rad(hashRand(seed + 11, kind.spin[1], kind.spin[2]))
	end
	entry.rocks[part] = info
end

local function track(model: Instance)
	if not model:IsA("Model") or anomalies[model] then
		return
	end
	local c0 = centreOf(model)
	local seed = c0.X * 0.13 + c0.Z * 0.29
	local entry = {
		model = model, centre = c0, rocks = {}, lights = {},
		phase = hashRand(seed, 0, 2 * math.pi),
		surgeEvery = hashRand(seed + 1, LIGHT.surgeEvery[1], LIGHT.surgeEvery[2]),
		surgeOffset = hashRand(seed + 2, 0, 60),
	}
	anomalies[model] = entry
	local function consider(d)
		if d:IsA("BasePart") then
			addRock(entry, d)
		elseif d:IsA("Light") and type(LIGHT[d.Name]) == "table" then
			entry.lights[d] = {
				cfg = LIGHT[d.Name],
				brightness = d:GetAttribute("BaseBrightness") or d.Brightness,
				range = d:GetAttribute("BaseRange") or d.Range,
			}
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		consider(d)
	end
	-- Streaming: parts can arrive later, or leave and come back.
	entry.added = model.DescendantAdded:Connect(consider)
	entry.removing = model.DescendantRemoving:Connect(function(d)
		entry.rocks[d] = nil
		entry.lights[d] = nil
	end)
end

local function untrack(model: Instance)
	local entry = anomalies[model]
	if entry then
		entry.added:Disconnect()
		entry.removing:Disconnect()
		anomalies[model] = nil
	end
end

for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	track(m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
-- Also anything simply named HollowLift (e.g. built before the tag existed).
for _, d in ipairs(workspace:GetDescendants()) do
	if d.Name == TAG then
		track(d)
	end
end
workspace.DescendantAdded:Connect(function(d)
	if d.Name == TAG then
		track(d)
	end
end)
workspace.DescendantRemoving:Connect(function(d)
	if anomalies[d] then
		untrack(d)
	end
end)

-------------------------------------------------------------------------------

local function place(info, t: number): CFrame
	local bob = info.kind.bob * math.sin(2 * math.pi * t / info.bobT + info.bobPhase)
	if info.kind.still then
		local sway = math.rad(info.kind.sway) * math.sin(2 * math.pi * t / info.swayT + info.bobPhase)
		return CFrame.new(info.base + Vector3.new(0, bob, 0)) * CFrame.fromAxisAngle(info.swayAxis, sway) * info.rot
	end
	local a = info.a0 + info.dir * 2 * math.pi * t / info.turn
	-- Tilted orbit: height rises and falls round the loop, offset so the rock
	-- starts exactly where it was built.
	local y = info.y0 + info.tiltAmp * (math.sin(a + info.tiltPhase) - math.sin(info.a0 + info.tiltPhase)) + bob
	return info.centreCF * CFrame.new(math.cos(a) * info.r, y, math.sin(a) * info.r)
		* CFrame.fromAxisAngle(info.spinAxis, info.spin * t) * info.rot
end

-- 0 most of the time; jumps to 1 at a surge and fades back.
local function surgeAt(entry, t: number): number
	local s = (t + entry.surgeOffset) % entry.surgeEvery
	if s < 0.3 then
		return s / 0.3 -- quick rise
	elseif s < 0.3 + LIGHT.surgeLength then
		return math.exp(-(s - 0.3) * 4 / LIGHT.surgeLength) -- slow fade
	end
	return 0
end

local function animateLights(entry, t: number)
	local breathe = 0.5 + 0.5 * math.sin(2 * math.pi * t / LIGHT.breathePeriod + entry.phase)
	local shimmer = LIGHT.shimmer * (math.sin(t * 7.3 + entry.phase) + math.sin(t * 11.1 + 1.3) + math.sin(t * 17.7 + 2.9)) / 3
	local surge = surgeAt(entry, t)
	local drift = 0.5 + 0.5 * math.sin(2 * math.pi * t / LIGHT.colourPeriod + entry.phase * 0.5)
	local colour = LIGHT.blue:Lerp(LIGHT.violet, drift):Lerp(LIGHT.white, surge * 0.7)
	for light, info in pairs(entry.lights) do
		local cfg = info.cfg
		local k = 1 - LIGHT.breathe * 0.5 + LIGHT.breathe * breathe * cfg.breathe + shimmer + LIGHT.surgeBoost * surge * cfg.surge
		light.Brightness = info.brightness * math.max(0, k)
		if cfg.range then
			light.Range = math.min(60, info.range * (0.92 + 0.08 * breathe + LIGHT.surgeReach * surge))
		end
		if light.Name ~= "CoreLight" then
			light.Color = colour
		end
	end
end

local parts, cframes = {}, {}
RunService.Heartbeat:Connect(function()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	local t = workspace:GetServerTimeNow()
	table.clear(parts)
	table.clear(cframes)
	for _, entry in pairs(anomalies) do
		if (entry.centre - camPos).Magnitude <= CULL_DISTANCE then
			animateLights(entry, t)
			local centreCF = CFrame.new(entry.centre)
			for part, info in pairs(entry.rocks) do
				info.centreCF = centreCF
				table.insert(parts, part)
				table.insert(cframes, place(info, t))
			end
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)
