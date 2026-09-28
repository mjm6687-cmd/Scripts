--[[
	HOLLOW LIFT BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Places the "Hollow Lift" gravity anomaly (a passive, purely visual set
	piece) where your camera is pointing, as Workspace > HollowLift. Run it
	again to move or re-roll it (it deletes the old one). Ctrl+Z undoes it.

	The ground is yours: sculpt the crater with Roblox Terrain first, then
	point at its middle and run this. It doesn't touch Terrain and doesn't add
	a tree.

	WHAT IT BUILDS (sizes x SCALE)
	  * the lens: two ForceField spheres hanging 13 up, a faint blue light,
	    and slow shimmer rings pulsing out of it
	  * your rock meshes: small grit in a tight swarm round the lens, bigger
	    rocks further out on tilted rings, and flattened ones lifted just off
	    the ground round the rim like peeled-up slabs (tipped with the inner
	    edge higher). Picked at random from ROCK_MESHES, scaled evenly.
	  * rising dust, grit and leaves from the crater floor
	  * Wet: water droplets hanging above the floor (add the puddle in Terrain)
	  * Deep: 1.6x bigger, with a car-sized boulder turning at the top
	Everything is anchored and static; the particles are what move.
]]

local TEXTURES = {
	Dust = "rbxassetid://77191088568439", -- dust.png
	Grit = "rbxassetid://98553926540236", -- grit.png
	Leaf = "rbxassetid://91534275918577", -- leaf.png
	Ring = "rbxassetid://85522458077339", -- ring.png
}

local ROCK_MESHES = {
	"rbxassetid://81563159111199", "rbxassetid://118058038983872", "rbxassetid://109306462245586",
	"rbxassetid://97395341108063", "rbxassetid://110816468905837", "rbxassetid://85272015031397",
	"rbxassetid://131332326536758", "rbxassetid://138806244309953", "rbxassetid://122983019125220",
	"rbxassetid://98496969382774", "rbxassetid://82540124586099", "rbxassetid://103417469222032",
	"rbxassetid://125287271589866", "rbxassetid://130349255085849",
}
-- true: give every rock your "Rock"/"Basalt"/"Gravel" materials so they match;
-- false: leave them as they load (CreateMeshPartAsync doesn't bring a texture).
local USE_ROCK_MATERIAL = true

local HUM_SOUND = ""        -- optional looped hum, "rbxassetid://..."
local VARIANT = "Dry"       -- "Dry", "Wet" or "Deep"
local SEED = 7              -- change for a different arrangement

-------------------------------------------------------------------------------

local S = VARIANT == "Deep" and 1.6 or 1
local LENS_H = 13 * S

local M = Enum.Material
local ROCK_LOOKS = {
	{ M.Rock,   "Rock",   Color3.fromRGB(122, 111, 99) },
	{ M.Basalt, "Basalt", Color3.fromRGB(100, 96, 90) },
	{ M.Slate,  "Gravel", Color3.fromRGB(112, 106, 98) },
}
local LENS_COLOR = Color3.fromRGB(180, 194, 255)
local DUST_COLOR = Color3.fromRGB(201, 185, 159)

-------------------------------------------------------------------------------

local AssetService = game:GetService("AssetService")
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

local rng = Random.new(SEED)
local function rr(a, b)
	return a + (b - a) * rng:NextNumber()
end
local function randomRot()
	return CFrame.Angles(rr(0, 2 * math.pi), rr(0, 2 * math.pi), rr(0, 2 * math.pi))
end

local root = Instance.new("Model")
root.Name = "HollowLift"
local function group(name)
	local g = Instance.new("Model")
	g.Name = name
	g.Parent = root
	return g
end
local lensG, rocksG, fx = group("Lens"), group("Rocks"), group("Particles")

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { root }
-- Ground height under a point (x, z offsets from the centre).
local function groundY(x, z)
	local h = workspace:Raycast(C + Vector3.new(x, 60, z), Vector3.new(0, -200, 0), rayParams)
	return h and h.Position.Y or C.Y
end
local floorY = groundY(0, 0)

-------------------------------------------------------------------------------
-- Rock meshes: load each once, then clone.
-------------------------------------------------------------------------------
local templates = {}
local failed = {}
for _, id in ipairs(ROCK_MESHES) do
	local ok, mp = pcall(function()
		return AssetService:CreateMeshPartAsync(id)
	end)
	if ok and mp then
		table.insert(templates, mp)
	else
		table.insert(failed, id)
	end
end
if #failed > 0 then
	warn("[HollowLift] Couldn't load these rock meshes: " .. table.concat(failed, ", "))
end

-- A rock at cf, its biggest side `size` studs; `squash` flattens it (slabs).
local function rock(name, cf, size, squash, solid)
	if #templates == 0 then
		return nil
	end
	local t = templates[rng:NextInteger(1, #templates)]
	local p = t:Clone()
	p.Name = name
	local native = t.Size
	local k = size / math.max(native.X, native.Y, native.Z)
	p.Size = Vector3.new(native.X * k, native.Y * k * (squash or 1), native.Z * k)
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = solid == true
	p.CanTouch = false
	if USE_ROCK_MATERIAL then
		local look = ROCK_LOOKS[rng:NextInteger(1, #ROCK_LOOKS)]
		p.Material = look[1]
		p.MaterialVariant = look[2]
		p.Color = look[3]
	end
	p.Parent = rocksG
	return p
end

-------------------------------------------------------------------------------
-- Lens
-------------------------------------------------------------------------------
local lensPos = C + Vector3.new(0, LENS_H, 0)
local function ball(name, d, color)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(d, d, d)
	p.CFrame = CFrame.new(lensPos)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = M.ForceField
	p.Color = color
	p.Parent = lensG
	return p
end
local outer = ball("Lens", 6 * S, LENS_COLOR)
local inner = ball("LensCore", 4 * S, Color3.fromRGB(210, 190, 255))

local light = Instance.new("PointLight")
light.Color = LENS_COLOR
light.Range = 14 * S
light.Brightness = 0.6
light.Shadows = false
light.Parent = outer

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
-- Inner grit: small, tight round the lens, not solid.
for _ = 1, 26 do
	local a = rr(0, 2 * math.pi)
	local r = rr(3, 7) * S
	rock("Grit", CFrame.new(C + Vector3.new(math.cos(a) * r, rr(7, 20) * S, math.sin(a) * r)) * randomRot(),
		rr(0.4, 0.9) * S)
end
-- Mid rocks: bigger, on tilted rings, solid.
for i = 1, 12 do
	local a = (i / 12) * 2 * math.pi + rr(-0.3, 0.3)
	local r = rr(8, 13) * S
	local h = math.clamp(LENS_H + math.sin(a) * r * rr(-0.35, 0.35) + rr(-4, 4) * S, 3 * S, 18 * S)
	rock("Rock", CFrame.new(C + Vector3.new(math.cos(a) * r, h, math.sin(a) * r)) * randomRot(), rr(1.5, 3.5) * S, 1, true)
end
if VARIANT == "Deep" then
	rock("Boulder", CFrame.new(C + Vector3.new(rr(-3, 3), 30 * S, rr(-3, 3))) * randomRot(), 9 * S, 1, true)
end
-- Rim slabs: flattened rocks lifted off the ground, inner edge tipped up.
for i = 1, 7 do
	local a = (i / 7) * 2 * math.pi + rr(-0.25, 0.25)
	local r = rr(14, 20) * S
	local x, z = math.cos(a) * r, math.sin(a) * r
	local radial = Vector3.new(math.cos(a), 0, math.sin(a))
	local tangent = Vector3.yAxis:Cross(radial) -- tangent, up, radial is a proper frame
	local pos = Vector3.new(C.X + x, groundY(x, z) + rr(0.5, 2) * S, C.Z + z)
	local cf = CFrame.fromMatrix(pos, tangent, Vector3.yAxis, radial)
		* CFrame.Angles(math.rad(rr(10, 25)), 0, 0) * CFrame.Angles(0, rr(-0.3, 0.3), math.rad(rr(-6, 6)))
	rock("Slab", cf, rr(5, 8) * S, 0.35, true)
end

-------------------------------------------------------------------------------
-- Wet: water hanging above the floor
-------------------------------------------------------------------------------
if VARIANT == "Wet" then
	for _ = 1, 18 do
		local a, r = rr(0, 2 * math.pi), rr(0, 6) * S
		local d = rr(0.15, 0.32) * S
		local p = Instance.new("Part")
		p.Name = "Droplet"
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(d, d, d)
		p.CFrame = CFrame.new(C.X + math.cos(a) * r, floorY + rr(1, 8) * S, C.Z + math.sin(a) * r)
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.Material = M.Glass
		p.Transparency = 0.3
		p.Color = Color3.fromRGB(170, 200, 210)
		p.Parent = fx
	end
end

-------------------------------------------------------------------------------
-- Particles: rising dust, grit, leaves
-------------------------------------------------------------------------------
local function source(name, size, y)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.new(C.X, y, C.Z)
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Transparency = 1
	p.Parent = fx
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

for _, t in ipairs(templates) do
	t:Destroy()
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
print(("[HollowLift] Built Workspace.HollowLift (%s): %d parts, %d of %d rock meshes loaded."):format(
	VARIANT, count, #templates, #ROCK_MESHES))
