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
--   * SOUNDS (once their ids are filled in below): a drone from the orb that
--     breathes and lifts with the surges, soft air from the crater, a swell
--     at each surge, and stone creaks and pebble clacks from the floating
--     rocks now and then. All 3D, played locally, only when you're near.
-- Only the anomaly's own rocks, lights and sounds are touched: no camera,
-- Lighting service or screen effects.
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

-- Sound ids ("rbxassetid://..."); upload the files in Assets/Anomaly/sounds.
-- Blank ones are skipped.
local SOUNDS = {
	Hum = "rbxassetid://105462376919787",   -- hum_loop.ogg
	Air = "rbxassetid://115079028336662",   -- air_loop.ogg
	Surge = "rbxassetid://74739307029789",  -- surge.ogg
	Creaks = {                              -- rock_creak_1/2/3.ogg
		"rbxassetid://136679394687918",
		"rbxassetid://108481723739562",
		"rbxassetid://109318720231870",
	},
	Clacks = {                              -- pebble_clack_1/2.ogg
		"rbxassetid://71285117002124",
		"rbxassetid://119770884121560",
	},
}
local SOUND = {
	hearDistance = 80,        -- sounds start/stop within this range of the camera
	-- The hum/surge and the air play from invisible boxes this size, so with
	-- volumetric audio they come from the whole space, not a single point.
	volumeSize = Vector3.new(30, 30, 30),
	humVolume = 0.6,
	airVolume = 0.35,
	surgeVolume = 0.8,
	creakVolume = { 0.25, 0.5 },
	clackVolume = { 0.2, 0.4 },
	creakEvery = { 3, 8 },    -- seconds between creaks
	clackEvery = { 2, 6 },
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

-- The orb centre, wherever the model has been moved to: the Lens part itself
-- if it's loaded, otherwise the model's pivot plus the offset the builder
-- stored (both move with the model), otherwise just the pivot.
local function centreOf(model: Model): Vector3
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Lens" then
			return d.Position
		end
	end
	local offset = model:GetAttribute("OrbOffset")
	if typeof(offset) == "Vector3" then
		return (model:GetPivot() * CFrame.new(offset)).Position
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
		stopSounds(entry)
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
	return breathe, surge
end

-------------------------------------------------------------------------------
-- Sounds
-------------------------------------------------------------------------------
local Debris = game:GetService("Debris")
local soundRng = Random.new()

local function has(id)
	return type(id) == "string" and id ~= ""
end
local function pickId(list)
	local ok = {}
	for _, id in ipairs(list) do
		if has(id) then
			table.insert(ok, id)
		end
	end
	return #ok > 0 and ok[soundRng:NextInteger(1, #ok)] or nil
end

local function newSound(parent, id, volume, maxDist, looped)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped == true
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 6
	s.RollOffMaxDistance = maxDist
	s.Parent = parent
	return s
end

-- Invisible local box for a sound to play from (volumetric audio uses the
-- part's whole volume). Kept in a local folder, never replicated.
local soundFolder = Instance.new("Folder")
soundFolder.Name = "HollowLiftSoundVolumes"
soundFolder.Parent = workspace

local function volumeAt(name: string, pos: Vector3)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = SOUND.volumeSize
	p.CFrame = CFrame.new(pos)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Parent = soundFolder
	return p
end

local function floorOf(entry): Vector3
	for _, d in ipairs(entry.model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "DustSource" then
			return d.Position
		end
	end
	return entry.centre - Vector3.new(0, 12, 0)
end

local function startSounds(entry)
	entry.sounding = true
	entry.orbAnchor = volumeAt("HumVolume", entry.centre)
	if has(SOUNDS.Hum) then
		entry.hum = newSound(entry.orbAnchor, SOUNDS.Hum, SOUND.humVolume, 70, true)
		entry.hum:Play()
	end
	if has(SOUNDS.Air) then
		-- sits on the crater floor and rises up through the dust column
		entry.airAnchor = volumeAt("AirVolume", floorOf(entry) + Vector3.new(0, SOUND.volumeSize.Y / 2, 0))
		entry.air = newSound(entry.airAnchor, SOUNDS.Air, SOUND.airVolume, 45, true)
		entry.air:Play()
	end
	entry.nextCreak = os.clock() + soundRng:NextNumber(1, SOUND.creakEvery[2])
	entry.nextClack = os.clock() + soundRng:NextNumber(1, SOUND.clackEvery[2])
end

local function stopSounds(entry)
	entry.sounding = false
	for _, k in ipairs({ "orbAnchor", "airAnchor" }) do
		if entry[k] then
			entry[k]:Destroy() -- takes its sounds with it
			entry[k] = nil
		end
	end
	entry.hum, entry.air = nil, nil
end

-- A one-shot from a random rock (optionally only rocks named `only`).
local function fromRandomRock(entry, id, volRange, only)
	local list = {}
	for part in pairs(entry.rocks) do
		if part.Parent and (not only or part.Name == only) then
			table.insert(list, part)
		end
	end
	if #list == 0 or not id then
		return
	end
	local rock = list[soundRng:NextInteger(1, #list)]
	local s = newSound(rock, id, soundRng:NextNumber(volRange[1], volRange[2]), 45)
	s.PlaybackSpeed = soundRng:NextNumber(0.85, 1.15)
	s:Play()
	Debris:AddItem(s, 5)
end

local function updateSounds(entry, breathe: number, surge: number, near: boolean)
	if near and not entry.sounding then
		startSounds(entry)
	elseif not near and entry.sounding then
		stopSounds(entry)
	end
	if not entry.sounding then
		entry.lastSurge = surge
		return
	end
	if entry.hum then
		entry.hum.Volume = SOUND.humVolume * (0.8 + 0.2 * breathe + 0.35 * surge)
		entry.hum.PlaybackSpeed = 1 + 0.03 * surge
	end
	if entry.air then
		entry.air.Volume = SOUND.airVolume * (0.85 + 0.15 * breathe + 0.5 * surge)
	end
	-- Surge one-shot on the rising edge of each surge.
	if surge > 0 and (entry.lastSurge or 0) == 0 and has(SOUNDS.Surge) then
		local s = newSound(entry.orbAnchor, SOUNDS.Surge, SOUND.surgeVolume, 90)
		s:Play()
		Debris:AddItem(s, 6)
	end
	entry.lastSurge = surge
	local now = os.clock()
	if now >= entry.nextCreak then
		entry.nextCreak = now + soundRng:NextNumber(SOUND.creakEvery[1], SOUND.creakEvery[2])
		fromRandomRock(entry, pickId(SOUNDS.Creaks), SOUND.creakVolume, "Rock")
	end
	if now >= entry.nextClack then
		entry.nextClack = now + soundRng:NextNumber(SOUND.clackEvery[1], SOUND.clackEvery[2])
		fromRandomRock(entry, pickId(SOUNDS.Clacks), SOUND.clackVolume, "Grit")
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
		local dist = (entry.centre - camPos).Magnitude
		if dist <= CULL_DISTANCE then
			local breathe, surge = animateLights(entry, t)
			updateSounds(entry, breathe, surge, dist <= SOUND.hearDistance)
			local centreCF = CFrame.new(entry.centre)
			for part, info in pairs(entry.rocks) do
				info.centreCF = centreCF
				table.insert(parts, part)
				table.insert(cframes, place(info, t))
			end
		elseif entry.sounding then
			stopSounds(entry)
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end)
