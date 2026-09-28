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
	  * the orb, hanging 13 up, in layers: a dark heart with a bright core,
	    a slowly turning halo of bent light, two ForceField shimmer shells,
	    streaks falling inward from ~11 studs out, flickering twinkles,
	    flat ripples spreading out horizontally, three glowing orbit trails
	    at different tilts
	  * three lights: a shadow-casting main light (range 30), a spotlight
	    straight down onto the crater (the rocks' shadows sweep across it),
	    and a small bright core light
	  * your rock meshes: small grit in a tight swarm round the lens, bigger
	    rocks further out on tilted rings, and flattened ones lifted just off
	    the ground round the rim like peeled-up slabs (tipped with the inner
	    edge higher). Picked at random from ROCK_MESHES, scaled evenly.
	  * rising dust, grit and leaves from the crater floor
	  * Wet: water droplets hanging above the floor (add the puddle in Terrain)
	  * Deep: 1.6x bigger, with a car-sized boulder turning at the top
	Everything is anchored. To make the rocks float round the orb, also put
	StarterPlayer > StarterPlayerScripts > HollowLiftClient (LocalScript) in
	the game; it finds this model by its "HollowLift" tag.
]]

-- Upload the PNGs in Assets/Anomaly and paste their ids. A blank one just
-- leaves that layer out (dust falls back to Roblox's built-in smoke).
local TEXTURES = {
	Dust = "rbxassetid://77191088568439", -- dust.png
	Grit = "rbxassetid://98553926540236", -- grit.png
	Leaf = "rbxassetid://91534275918577", -- leaf.png
	Ring = "rbxassetid://85522458077339", -- ring.png
	-- the orb
	Glow = "rbxassetid://84812883750380",     -- glow.png     (bright core, and the dark heart)
	LensRim = "rbxassetid://131042844491629",  -- lensrim.png  (the bent-light halo)
	Streak = "rbxassetid://78221922232232",   -- streak.png   (inflow streaks)
	Spark = "rbxassetid://123217368876639",    -- spark.png    (twinkles)
	Wisp = "rbxassetid://82090755078513",     -- wisp.png     (orbit trails)
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

-- Lights, in three layers. HollowLiftClient animates them (breathing,
-- shimmer, colour drift, surges) relative to these starting values.
local function addLight(class, name, parent, props)
	local l = Instance.new(class)
	l.Name = name
	for k, v in pairs(props) do
		l[k] = v
	end
	l:SetAttribute("BaseBrightness", l.Brightness)
	l:SetAttribute("BaseRange", l.Range)
	l.Parent = parent
	return l
end
-- Main light: the whole area, casting shadows.
addLight("PointLight", "OrbLight", outer, {
	Color = LENS_COLOR, Range = 30, Brightness = 0.9, Shadows = true,
})
-- Floor light: straight down onto the crater, so the orbiting rocks' shadows
-- sweep across the ground.
addLight("SpotLight", "FloorLight", outer, {
	Color = LENS_COLOR, Range = 30, Brightness = 0.8, Angle = 75, Face = Enum.NormalId.Bottom, Shadows = true,
})
-- Core light: small and bright, makes the orb and the grit round it glow.
addLight("PointLight", "CoreLight", inner, {
	Color = Color3.fromRGB(225, 230, 255), Range = 8 * S, Brightness = 1.4, Shadows = false,
})

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

-- The orb's layers are particles and Beams on attachments at its centre.
-- ZOffset pushes a layer towards the camera, so the order is:
-- dark heart (back) < halo < core (front).
local centreAtt = Instance.new("Attachment")
centreAtt.Name = "OrbCentre"
centreAtt.Parent = inner

local function layer(name, tex, props)
	if tex == "" then
		return nil
	end
	props.Name = name
	props.Texture = tex
	props.Speed = props.Speed or NumberRange.new(0)
	props.LockedToPart = true
	return emitter(centreAtt, props)
end

local steady = seq({ { 0, 1 }, { 0.25, 0.3 }, { 0.75, 0.3 }, { 1, 1 } }) -- overlapping copies = a steady image

-- Dark heart: the glow texture tinted near-black, drawn normally (not added).
layer("DarkHeart", TEXTURES.Glow, {
	Rate = 2, Lifetime = NumberRange.new(2),
	Size = NumberSequence.new(3.2 * S),
	Transparency = seq({ { 0, 1 }, { 0.25, 0.35 }, { 0.75, 0.35 }, { 1, 1 } }),
	Color = ColorSequence.new(Color3.fromRGB(4, 5, 12)),
	LightEmission = 0, LightInfluence = 0, ZOffset = 0,
})
-- Halo: thin ring of bent light round the heart, slowly turning.
layer("Halo", TEXTURES.LensRim, {
	Rate = 1.5, Lifetime = NumberRange.new(2.5),
	Size = NumberSequence.new(7 * S),
	Transparency = steady,
	Color = ColorSequence.new(Color3.fromRGB(185, 200, 255)),
	Rotation = NumberRange.new(0, 360), RotSpeed = NumberRange.new(-8, 8),
	LightEmission = 1, LightInfluence = 0, Brightness = 1.4, ZOffset = 0.3,
})
-- Core: small bright point in the middle.
layer("Core", TEXTURES.Glow, {
	Rate = 3, Lifetime = NumberRange.new(1.4, 1.8),
	Size = seq({ { 0, 1.4 * S }, { 0.5, 1.7 * S }, { 1, 1.4 * S } }),
	Transparency = steady,
	Color = ColorSequence.new(Color3.fromRGB(225, 232, 255)),
	LightEmission = 1, LightInfluence = 0, Brightness = 2, ZOffset = 0.6,
})
-- Ripples: rings lying flat (they face along their tiny upward drift),
-- spreading out round the orb like on water.
layer("Ripples", TEXTURES.Ring, {
	Rate = 0.4, Lifetime = NumberRange.new(4, 5),
	Speed = NumberRange.new(0.05),
	EmissionDirection = Enum.NormalId.Top,
	Orientation = Enum.ParticleOrientation.VelocityPerpendicular,
	Size = seq({ { 0, 2 * S }, { 1, 16 * S } }),
	Transparency = seq({ { 0, 1 }, { 0.15, 0.5 }, { 1, 1 } }),
	Color = ColorSequence.new(LENS_COLOR),
	LightEmission = 1, LightInfluence = 0,
})

-- Inflow: streaks start on an invisible sphere ~11 out and fall inward,
-- stretched along their motion, gone before they reach the core.
if TEXTURES.Streak ~= "" then
	local shell = Instance.new("Part")
	shell.Name = "InflowShell"
	shell.Shape = Enum.PartType.Ball
	shell.Size = Vector3.new(22, 22, 22) * S
	shell.CFrame = CFrame.new(lensPos)
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanTouch = false
	shell.CanQuery = false
	shell.CastShadow = false
	shell.Transparency = 1
	shell.Parent = lensG
	emitter(shell, {
		Name = "Inflow",
		Texture = TEXTURES.Streak,
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
		ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward,
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Rate = 14,
		Speed = NumberRange.new(4.5, 6),
		Lifetime = NumberRange.new(1.4, 1.7),
		Size = NumberSequence.new(0.5 * S),
		Squash = NumberSequence.new(-1.2),
		Transparency = seq({ { 0, 1 }, { 0.3, 0.45 }, { 0.8, 0.6 }, { 1, 1 } }),
		Color = ColorSequence.new(DUST_COLOR, LENS_COLOR),
		LightEmission = 0.6, LightInfluence = 0,
	})
end

-- Twinkles: sparks flickering inside the orb.
if TEXTURES.Spark ~= "" then
	emitter(inner, {
		Name = "Twinkles",
		Texture = TEXTURES.Spark,
		Shape = Enum.ParticleEmitterShape.Sphere,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
		Rate = 10,
		Speed = NumberRange.new(0.2, 0.6),
		Drag = 1,
		Lifetime = NumberRange.new(1, 2),
		Size = NumberSequence.new(0.3 * S),
		Transparency = seq({ { 0, 1 }, { 0.1, 0 }, { 0.3, 0.7 }, { 0.5, 0.1 }, { 0.7, 0.8 }, { 0.85, 0.2 }, { 1, 1 } }),
		Color = ColorSequence.new(Color3.fromRGB(230, 235, 255)),
		LightEmission = 1, LightInfluence = 0,
		Rotation = NumberRange.new(0, 90),
	})
end

-- Orbit trails: three loops round the orb at different tilts. Each loop is two
-- curved Beams (front and back half) between attachments on opposite sides;
-- the wisp texture scrolls along them.
if TEXTURES.Wisp ~= "" then
	for i, ring in ipairs({ { 4.5, 0, 0 }, { 5.5, 35, 20 }, { 6.5, -25, -40 } }) do
		local r = ring[1] * S
		local tilt = CFrame.Angles(math.rad(ring[2]), math.rad(ring[3]), 0)
		-- Each attachment's axis points along the loop's front (+Z of the tilt).
		local a0 = Instance.new("Attachment")
		a0.Name = "Trail" .. i .. "A"
		a0.CFrame = tilt * CFrame.new(-r, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0)
		a0.Parent = outer
		local a1 = Instance.new("Attachment")
		a1.Name = "Trail" .. i .. "B"
		a1.CFrame = tilt * CFrame.new(r, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0)
		a1.Parent = outer
		local k = r * 4 / 3 -- control distance that makes two halves a near circle
		for half, sign in ipairs({ 1, -1 }) do
			local b = Instance.new("Beam")
			b.Name = "Trail" .. i .. (half == 1 and "Front" or "Back")
			b.Attachment0 = a0
			b.Attachment1 = a1
			b.CurveSize0 = k * sign
			b.CurveSize1 = -k * sign
			b.Segments = 32
			b.Texture = TEXTURES.Wisp
			b.TextureMode = Enum.TextureMode.Wrap
			b.TextureLength = 6 * S
			b.TextureSpeed = 0.25 + i * 0.08
			b.Width0 = 0.7 * S
			b.Width1 = 0.7 * S
			b.FaceCamera = true
			b.LightEmission = 0.8
			b.LightInfluence = 0
			b.Color = ColorSequence.new(i == 2 and Color3.fromRGB(200, 185, 255) or LENS_COLOR)
			b.Transparency = NumberSequence.new(0.45)
			b.Parent = outer
		end
	end
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
-- Where the orb is relative to the model's pivot, so it stays right if you
-- move the model (HollowLiftClient orbits the rocks round it).
root:SetAttribute("OrbOffset", lensPos - C)
game:GetService("CollectionService"):AddTag(root, "HollowLift")
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
