--[[
	HOLLOW LIFT BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Places the "Hollow Lift" gravity anomaly (a passive, purely visual set
	piece) on the ground where your camera is pointing, as Workspace > HollowLift.
	Run it again to move or re-roll it (it deletes the old one). Ctrl+Z undoes
	it, including any terrain it carved.

	WHAT IT BUILDS (sizes x SCALE)
	  * crater, 44 across and ~4 deep: carved into Terrain if you're on terrain
	    (and the floor turned to mud), otherwise a dark mud disc
	  * radial cracks running out from the rim, following the ground
	  * the lens: two ForceField spheres hanging 13 up, a faint blue light,
	    and slow shimmer rings pulsing out of it (Ring texture)
	  * inner grit orbiting tight round the lens, mid rocks further out
	  * outer slabs of ground peeled up and tipped in, roots hanging under some
	  * one dead tree on the rim, bent away from the centre
	  * rising dust (and grit and leaves, once their textures are uploaded)
	  * Wet: a puddle with water droplets hanging above it
	  * Deep: 1.6x bigger, with a car-sized boulder turning at the top
	Everything is anchored and static; the particles are what move.

	TEXTURES: upload Assets/Anomaly/dust.png, grit.png, leaf.png and ring.png
	(Studio: Asset Manager or Toolbox > Creations) and paste their ids below.
	Left blank: dust falls back to Roblox's built-in smoke, the rest are skipped.
]]

local TEXTURES = {
	Dust = "rbxassetid://77191088568439", -- dust.png
	Grit = "rbxassetid://98553926540236", -- grit.png
	Leaf = "rbxassetid://91534275918577", -- leaf.png
	Ring = "rbxassetid://85522458077339", -- ring.png
}
local HUM_SOUND = ""        -- optional looped hum, "rbxassetid://..."

local VARIANT = "Dry"       -- "Dry", "Wet" or "Deep"
local SEED = 7              -- change for a different arrangement
local CARVE_TERRAIN = true  -- carve the crater when standing on Terrain

-------------------------------------------------------------------------------

local S = VARIANT == "Deep" and 1.6 or 1
local R = 22 * S            -- crater radius
local DEPTH = 4 * S
local LENS_H = 13 * S

local M = Enum.Material
local MAT = {
	crater  = { M.Mud,    "Mud MV",           Color3.fromRGB(58, 50, 42) },
	craterD = { M.Mud,    "Messy mud",        Color3.fromRGB(42, 37, 32) },
	crack   = { M.SmoothPlastic, nil,         Color3.fromRGB(20, 17, 14) },
	grit1   = { M.Slate,  "Gravel",           Color3.fromRGB(112, 106, 98) },
	grit2   = { M.Rock,   "Rock",             Color3.fromRGB(92, 86, 78) },
	rock1   = { M.Rock,   "Rock",             Color3.fromRGB(122, 111, 99) },
	rock2   = { M.Basalt, "Basalt",           Color3.fromRGB(100, 96, 90) },
	slab    = { M.Ground, "Ground 1",         Color3.fromRGB(94, 85, 75) },
	slabUnder = { M.Ground, "Dirt",           Color3.fromRGB(70, 60, 50) },
	root    = { M.Plastic, "Bark",            Color3.fromRGB(84, 68, 50) },
	wood    = { M.Plastic, "Bark",            Color3.fromRGB(112, 100, 86) },
	lens    = { M.ForceField, nil,            Color3.fromRGB(180, 194, 255) },
	lens2   = { M.ForceField, nil,            Color3.fromRGB(210, 190, 255) },
	water   = { M.Glass,  nil,                Color3.fromRGB(70, 92, 96), 0.35 },
	drop    = { M.Glass,  nil,                Color3.fromRGB(170, 200, 210), 0.3 },
	hidden  = { M.SmoothPlastic, nil,         Color3.new(1, 1, 1), 1 },
}
local LENS_COLOR = MAT.lens[3]
local DUST_COLOR = Color3.fromRGB(201, 185, 159)

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Hollow Lift")
end)

local old = workspace:FindFirstChild("HollowLift")
if old then
	old:Destroy()
end

-- Where: the ground in the middle of the screen.
local cam = workspace.CurrentCamera.CFrame
local hit = workspace:Raycast(cam.Position, cam.LookVector * 4000)
local C = hit and hit.Position or (cam.Position + cam.LookVector * 120)
local onTerrain = hit ~= nil and hit.Instance == workspace.Terrain

local rng = Random.new(SEED)
local function rr(a, b)
	return a + (b - a) * rng:NextNumber()
end

local root = Instance.new("Model")
root.Name = "HollowLift"
local function group(name)
	local g = Instance.new("Model")
	g.Name = name
	g.Parent = root
	return g
end
local groundG, lensG, rocksG, tree, fx = group("Ground"), group("Lens"), group("Rocks"), group("DeadTree"), group("Particles")

local function part(parent, name, cf, size, mat, shape, solid)
	local m = MAT[mat]
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Material = m[1]
	if m[2] then
		p.MaterialVariant = m[2]
	end
	p.Color = m[3]
	p.Transparency = m[4] or 0
	if not solid then
		p.CanCollide = false
		p.CanTouch = false
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Round bar (cylinder) from a to b. `side` is any direction not along a->b.
local function limb(parent, name, a, b, d, mat, side)
	local dir = (b - a).Unit
	local up = side or Vector3.yAxis
	if math.abs(dir:Dot(up.Unit)) > 0.98 then
		up = Vector3.xAxis
	end
	return part(parent, name, CFrame.lookAt((a + b) / 2, b, up) * CFrame.Angles(0, math.pi / 2, 0),
		Vector3.new((b - a).Magnitude, d, d), mat, Enum.PartType.Cylinder, true)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { root }
-- Ground height and normal under a point (x, z offsets from the centre).
local function ground(x, z)
	local from = C + Vector3.new(x, 60, z)
	local h = workspace:Raycast(from, Vector3.new(0, -200, 0), rayParams)
	if h then
		return h.Position, h.Normal
	end
	return C + Vector3.new(x, 0, z), Vector3.yAxis
end

local function randomRot()
	return CFrame.Angles(rr(0, 2 * math.pi), rr(0, 2 * math.pi), rr(0, 2 * math.pi))
end

-- A lumpy rock: three overlapping blocks, unioned into one part at the end.
local unionQueue = {}
local function rock(parent, pos, size, mat, solid)
	local pieces = {}
	local base = CFrame.new(pos) * randomRot()
	table.insert(pieces, part(parent, "Rock", base, Vector3.new(size, size * rr(0.7, 0.9), size * rr(0.8, 1)), mat, nil, solid))
	for _ = 1, 2 do
		local off = Vector3.new(rr(-0.3, 0.3), rr(-0.3, 0.3), rr(-0.3, 0.3)) * size
		table.insert(pieces, part(parent, "Rock", base * CFrame.new(off) * randomRot(),
			Vector3.new(size * rr(0.5, 0.75), size * rr(0.45, 0.7), size * rr(0.5, 0.75)), mat, nil, solid))
	end
	table.insert(unionQueue, pieces)
end

local function seq(points)
	local kp = {}
	for _, p in ipairs(points) do
		table.insert(kp, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kp)
end

local function emitter(parent, props)
	local e = Instance.new("ParticleEmitter")
	for k, v in pairs(props) do
		e[k] = v
	end
	e.Parent = parent
	return e
end

-------------------------------------------------------------------------------
-- Crater
-------------------------------------------------------------------------------
local floorY = C.Y
if onTerrain and CARVE_TERRAIN then
	local terrain = workspace.Terrain
	-- Stepped cylinders of air, deeper towards the middle: a shallow bowl.
	for r = R, 2, -2 do
		local h = DEPTH * (1 - (r / R) ^ 2)
		pcall(function()
			terrain:FillCylinder(CFrame.new(C + Vector3.new(0, (60 - h) / 2, 0)), 60 + h, r, Enum.Material.Air)
		end)
	end
	-- Muddy floor.
	pcall(function()
		local region = Region3.new(C - Vector3.new(R, DEPTH + 6, R), C + Vector3.new(R, 4, R)):ExpandToGrid(4)
		for _, m in ipairs({ M.Grass, M.LeafyGrass, M.Ground, M.Sand, M.Snow }) do
			terrain:ReplaceMaterial(region, 4, m, M.Mud)
		end
	end)
	floorY = C.Y - DEPTH
else
	part(groundG, "Crater", CFrame.new(C + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(0.1, 2 * R, 2 * R), "crater", Enum.PartType.Cylinder)
	part(groundG, "CraterCore", CFrame.new(C + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(0.1, 1.2 * R, 1.2 * R), "craterD", Enum.PartType.Cylinder)
end

-- Radial cracks from the rim outward, two kinked segments each, on the ground.
for i = 1, 11 do
	local a = (i / 11) * 2 * math.pi + rr(-0.15, 0.15)
	local r0 = R * rr(0.85, 0.95)
	local len = rr(6, 14) * S
	local kink = rr(-0.12, 0.12)
	local p0 = Vector3.new(math.cos(a) * r0, 0, math.sin(a) * r0)
	local p1 = p0 + Vector3.new(math.cos(a + kink), 0, math.sin(a + kink)) * len * 0.55
	local p2 = p1 + Vector3.new(math.cos(a - kink), 0, math.sin(a - kink)) * len * 0.45
	for _, seg in ipairs({ { p0, p1, 0.4 }, { p1, p2, 0.25 } }) do
		local mid = (seg[1] + seg[2]) / 2
		local gp, n = ground(mid.X, mid.Z)
		local along = (seg[2] - seg[1])
		along = (along - n * along:Dot(n)).Unit
		local cf = CFrame.fromMatrix(gp + n * 0.02, along:Cross(n), n, -along)
		part(groundG, "Crack", cf, Vector3.new(seg[3] * S, 0.12, (seg[2] - seg[1]).Magnitude + 0.2), "crack")
	end
end

-------------------------------------------------------------------------------
-- Lens
-------------------------------------------------------------------------------
local lensPos = C + Vector3.new(0, LENS_H, 0)
local outer = part(lensG, "Lens", CFrame.new(lensPos), Vector3.new(6, 6, 6) * S, "lens", Enum.PartType.Ball)
local inner = part(lensG, "LensCore", CFrame.new(lensPos), Vector3.new(4, 4, 4) * S, "lens2", Enum.PartType.Ball)
for _, p in ipairs({ outer, inner }) do
	p.CastShadow = false
	p.CanQuery = false
end
local light = Instance.new("PointLight")
light.Color = LENS_COLOR
light.Range = 14 * S
light.Brightness = 0.6
light.Shadows = false
light.Parent = outer
if TEXTURES.Ring ~= "" then
	local att = Instance.new("Attachment")
	att.Name = "RingSource"
	att.Parent = inner
	emitter(att, {
		Name = "ShimmerRings",
		Texture = TEXTURES.Ring,
		Rate = 0.35,
		Lifetime = NumberRange.new(5, 6),
		Speed = NumberRange.new(0),
		Size = seq({ { 0, 3 * S }, { 1, 14 * S } }),
		Transparency = seq({ { 0, 1 }, { 0.15, 0.55 }, { 1, 1 } }),
		LightEmission = 1,
		LightInfluence = 0,
		Color = ColorSequence.new(LENS_COLOR),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-3, 3),
		LockedToPart = true,
	})
end
if HUM_SOUND ~= "" then
	local s = Instance.new("Sound")
	s.Name = "Hum"
	s.SoundId = HUM_SOUND
	s.Looped = true
	s.Volume = 0.5
	s.RollOffMaxDistance = 60 * S
	s.Playing = true
	s.Parent = outer
end

-------------------------------------------------------------------------------
-- Rocks
-------------------------------------------------------------------------------
-- Inner grit: small, tight round the lens.
for i = 1, 26 do
	local a = rr(0, 2 * math.pi)
	local r = rr(3, 7) * S
	local pos = C + Vector3.new(math.cos(a) * r, rr(7, 20) * S, math.sin(a) * r)
	local sz = rr(0.3, 0.8) * S
	part(rocksG, "Grit", CFrame.new(pos) * randomRot(), Vector3.new(sz, sz * rr(0.6, 1), sz * rr(0.7, 1)),
		i % 2 == 0 and "grit1" or "grit2")
end
-- Mid rocks: bigger, on tilted rings, solid.
for i = 1, 12 do
	local a = (i / 12) * 2 * math.pi + rr(-0.3, 0.3)
	local r = rr(8, 13) * S
	local tilt = rr(-0.35, 0.35)
	local h = LENS_H + math.sin(a) * r * tilt + rr(-4, 4) * S
	h = math.clamp(h, 3 * S, 18 * S)
	rock(rocksG, C + Vector3.new(math.cos(a) * r, h, math.sin(a) * r), rr(1, 3) * S, i % 3 == 0 and "rock2" or "rock1", true)
end
if VARIANT == "Deep" then
	rock(rocksG, C + Vector3.new(rr(-3, 3), 30 * S, rr(-3, 3)), 8 * S, "rock2", true)
end

-- Outer slabs: peeled up and tipped with the inner edge higher.
for i = 1, 7 do
	local a = (i / 7) * 2 * math.pi + rr(-0.25, 0.25)
	local r = rr(14, 20) * S
	local gp = ground(math.cos(a) * r, math.sin(a) * r)
	local lift = rr(0.5, 2) * S
	local radial = Vector3.new(math.cos(a), 0, math.sin(a))
	local tangent = Vector3.yAxis:Cross(radial) -- so tangent, up, radial is a proper frame
	local w, t, d = rr(4, 8) * S, 0.6 * S, rr(2, 4) * S
	-- Long side along the tangent; tip so the inner (centre-side) edge rises.
	local cf = CFrame.fromMatrix(gp + Vector3.new(0, lift, 0), tangent, Vector3.yAxis, radial)
		* CFrame.Angles(math.rad(rr(10, 25)), 0, 0) * CFrame.Angles(0, 0, math.rad(rr(-6, 6)))
	part(rocksG, "Slab", cf, Vector3.new(w, t, d), "slab", nil, true)
	part(rocksG, "SlabUnderside", cf * CFrame.new(0, -t / 2 - 0.1 * S, 0), Vector3.new(w * 0.92, 0.2 * S, d * 0.9), "slabUnder", nil, true)
	if i % 2 == 1 then
		for _ = 1, 3 do
			local top = (cf * CFrame.new(rr(-w / 3, w / 3), -t / 2, rr(-d / 3, d / 3))).Position
			local bottom = top + Vector3.new(rr(-0.6, 0.6), -rr(0.8, 1.8) * S, rr(-0.6, 0.6))
			limb(rocksG, "Root", top, bottom, rr(0.12, 0.25) * S, "root")
		end
	end
end

-------------------------------------------------------------------------------
-- Dead tree on the rim, bent away from the centre
-------------------------------------------------------------------------------
do
	local a = rr(0, 2 * math.pi)
	local away = Vector3.new(math.cos(a), 0, math.sin(a))
	local sideV = away:Cross(Vector3.yAxis)
	local base = ground(away.X * (R + 2 * S), away.Z * (R + 2 * S))
	local H, bend = 18 * S, 7 * S
	local function P(t)
		return base + Vector3.new(0, H * t, 0) + away * (bend * t * t)
	end
	local n = 8
	for i = 0, n - 1 do
		local t0, t1 = i / n, (i + 1) / n
		limb(tree, "Trunk", P(t0) - Vector3.new(0, i == 0 and 0.6 or 0.1, 0), P(t1) + (P(t1) - P(t0)).Unit * 0.15,
			(1.3 - 0.9 * t0) * S, "wood", away)
	end
	-- Root flare.
	for k = -1, 1 do
		local dir = (away * -1 + sideV * k * 0.9).Unit
		limb(tree, "Root", base + Vector3.new(0, 0.6 * S, 0), base + dir * 2.2 * S - Vector3.new(0, 0.3, 0), 0.5 * S, "wood", sideV)
	end
	-- Branches, all on the far side, curling up and out.
	for _, b in ipairs({ { 0.45, 1, 5 }, { 0.6, -1, 4.5 }, { 0.75, 1, 3.5 }, { 0.9, -0.5, 3 } }) do
		local start = P(b[1])
		local mid = start + (away * 0.8 + sideV * b[2] * 0.6 + Vector3.new(0, 0.5, 0)).Unit * b[3] * 0.55 * S
		local tip = mid + (away * 0.6 + sideV * b[2] * 0.3 + Vector3.new(0, 0.9, 0)).Unit * b[3] * 0.5 * S
		limb(tree, "Branch", start, mid, (0.45 - b[1] * 0.2) * S, "wood", away)
		limb(tree, "Branch", mid, tip, (0.3 - b[1] * 0.15) * S, "wood", away)
	end
end

-------------------------------------------------------------------------------
-- Wet: a puddle with water hanging over it
-------------------------------------------------------------------------------
if VARIANT == "Wet" then
	part(groundG, "Puddle", CFrame.new(C.X, floorY + 0.12, C.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(0.06, 14 * S, 12 * S), "water", Enum.PartType.Cylinder).Reflectance = 0.3
	for _ = 1, 18 do
		local a, r = rr(0, 2 * math.pi), rr(0, 6) * S
		local d = rr(0.15, 0.32) * S
		part(groundG, "Droplet", CFrame.new(C + Vector3.new(math.cos(a) * r, rr(1, 8) * S, math.sin(a) * r)),
			Vector3.new(d, d, d), "drop", Enum.PartType.Ball)
	end
end

-------------------------------------------------------------------------------
-- Particles: rising dust, grit, leaves
-------------------------------------------------------------------------------
local function source(name, size, y)
	local p = part(fx, name, CFrame.new(C.X, y, C.Z), size, "hidden")
	p.CanQuery = false
	p.CastShadow = false
	return p
end
local dustSrc = source("DustSource", Vector3.new(14 * S, 1, 14 * S), floorY + 0.6)
emitter(dustSrc, {
	Name = "RisingDust",
	Texture = TEXTURES.Dust ~= "" and TEXTURES.Dust or "rbxasset://textures/particles/smoke_main.dds",
	Shape = Enum.ParticleEmitterShape.Disc,
	EmissionDirection = Enum.NormalId.Top,
	Rate = 5,
	Lifetime = NumberRange.new(9, 13),
	Speed = NumberRange.new(1, 2),
	SpreadAngle = Vector2.new(8, 8),
	Acceleration = Vector3.new(0, 0.15, 0),
	Size = seq({ { 0, 1.2 * S }, { 0.5, 2.2 * S }, { 1, 3 * S } }),
	Transparency = seq({ { 0, 1 }, { 0.15, 0.6 }, { 0.7, 0.8 }, { 1, 1 } }),
	Color = ColorSequence.new(DUST_COLOR),
	LightInfluence = 1,
	Rotation = NumberRange.new(0, 360),
	RotSpeed = NumberRange.new(-10, 10),
})
if TEXTURES.Grit ~= "" then
	local col = source("GritColumn", Vector3.new(10 * S, 20 * S, 10 * S), C.Y + 11 * S)
	emitter(col, {
		Name = "RisingGrit",
		Texture = TEXTURES.Grit,
		Shape = Enum.ParticleEmitterShape.Box,
		EmissionDirection = Enum.NormalId.Top,
		Rate = 5,
		Lifetime = NumberRange.new(6, 9),
		Speed = NumberRange.new(0.4, 1),
		Size = NumberSequence.new(0.8 * S),
		Transparency = seq({ { 0, 1 }, { 0.2, 0.2 }, { 0.8, 0.3 }, { 1, 1 } }),
		Color = ColorSequence.new(Color3.fromRGB(150, 140, 122)),
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-20, 20),
	})
end
if TEXTURES.Leaf ~= "" then
	local leafSrc = source("LeafSource", Vector3.new(10 * S, 1, 10 * S), floorY + 0.8)
	emitter(leafSrc, {
		Name = "RisingLeaves",
		Texture = TEXTURES.Leaf,
		Shape = Enum.ParticleEmitterShape.Disc,
		EmissionDirection = Enum.NormalId.Top,
		Rate = 0.8,
		Lifetime = NumberRange.new(14, 18),
		Speed = NumberRange.new(1.2, 2),
		SpreadAngle = Vector2.new(10, 10),
		Size = NumberSequence.new(0.6 * S),
		Transparency = seq({ { 0, 1 }, { 0.08, 0 }, { 0.85, 0 }, { 1, 1 } }),
		LightInfluence = 1,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
	})
end

-------------------------------------------------------------------------------

root.WorldPivot = CFrame.new(C)
root.PrimaryPart = outer
root.Parent = workspace

-- Union each rock's pieces into one part (needs to be in Workspace).
for _, pieces in ipairs(unionQueue) do
	local first = table.remove(pieces, 1)
	local ok, u = pcall(function()
		return first:UnionAsync(pieces)
	end)
	if ok and u then
		u.Name = "Rock"
		u.Anchored = true
		u.UsePartColor = true
		u.Parent = first.Parent
		first:Destroy()
		for _, p in ipairs(pieces) do
			p:Destroy()
		end
	end
end

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build Hollow Lift")
	end)
end

local count = 0
for _, d in ipairs(root:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
local missing = {}
for k, v in pairs(TEXTURES) do
	if v == "" then
		table.insert(missing, k)
	end
end
print(("[HollowLift] Built Workspace.HollowLift (%s, %s): %d parts."):format(VARIANT,
	onTerrain and "carved into terrain" or "on parts", count))
if #missing > 0 then
	print("[HollowLift] No texture id yet for: " .. table.concat(missing, ", ")
		.. " (upload the PNGs in Assets/Anomaly and paste the ids at the top).")
end
