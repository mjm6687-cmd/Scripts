-- HollowLiftClient
-- CLASS: LocalScript
-- PLACE IN: StarterPlayer > StarterPlayerScripts
--
-- Makes the floating rocks of every Hollow Lift anomaly move: grit orbits
-- tight round the orb, bigger rocks on slower tilted orbits, the Deep boulder
-- turns in place, and the rim slabs just sway. Nothing else is touched (no
-- camera, lighting or screen effects).
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
	local entry = { model = model, centre = centreOf(model), rocks = {} }
	anomalies[model] = entry
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			addRock(entry, d)
		end
	end
	-- Streaming: rocks can arrive later, or leave and come back.
	entry.added = model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			addRock(entry, d)
		end
	end)
	entry.removing = model.DescendantRemoving:Connect(function(d)
		entry.rocks[d] = nil
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
