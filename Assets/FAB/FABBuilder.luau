--[[
	FORWARD AVIATION BASE BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------------
	Builds a brutalist forward aviation base as Workspace > FAB, using the
	MaterialVariants in your MaterialService. Run it again any time: it deletes
	the old one and rebuilds. Ctrl+Z undoes it.

	LAYOUT (north is -Z in Studio when YAW = 0; the base is 560 x 440 studs):
	  North      two hangars ("01", "02") with the ops centre + control tower
	             between them, workshop annexes either side, fuel farm (NE)
	  Flight line  four helipads in front of the hangars, fuel pump by pad 4
	  Centre     the main helipad
	  West       vehicle park, vehicle maintenance shed (SW)
	  East       container yard, crew quarters block (SE)
	  South      gate "A1": piers, two guard towers, drop bar, sliding gate,
	             checkpoint booth, HESCO, serpentine barriers outside
	  Perimeter  octagonal ring of T-wall blast panels with wall lights,
	             guard towers on the east and west walls, floodlight poles

	Everything is plain Parts (no meshes), grouped into Models, so you can swap
	anything for a proper model. Only lights and signs are "live"; no scripts.

	MESH PLACEHOLDERS: things that should really be a mesh (helicopters,
	vehicles, a satellite dish...) are a single box with your "Baseplate Tile"
	texture, a colour per kind, and a name starting MESH_ (MESH_Helicopter,
	MESH_Truck...). The box is the size and position the real model should
	take. Each one is tagged "MeshPlaceholder" and has a "ReplaceWith"
	attribute saying what goes there.
]]

-- WHERE. ORIGIN = middle of the base at ground level. YAW turns it (degrees).
local ORIGIN = Vector3.new(0, 0, 0)
local YAW = 0

local BASE_NAME = "NORTHGATE"                 -- big sign next to the gate
local BASE_SUBTITLE = "FORWARD AVIATION BASE"
local GATE_CODE = "A1"

local MAKE_GROUND = true      -- the concrete apron under the whole base
local CLEAR_TERRAIN = false   -- true: clears Terrain above ground level inside the base

-------------------------------------------------------------------------------
-- MATERIALS: { base Material, MaterialVariant name (must match that base), Color,
--              transparency, paint? }. The Color tints the variant's texture.
-------------------------------------------------------------------------------
local M = Enum.Material
local MAT = {
	wall      = { M.Concrete, "InSitu Concrete",       Color3.fromRGB(128, 128, 124) },
	wallDark  = { M.Concrete, "Layered Bunker",        Color3.fromRGB(104, 104, 100) },
	building  = { M.Concrete, "Concrete Cladding",     Color3.fromRGB(120, 120, 117) },
	bldLight  = { M.Concrete, "Bunker Concrete Light", Color3.fromRGB(140, 140, 136) },
	apron     = { M.Concrete, "Tiled Concrete Dark",   Color3.fromRGB(96, 96, 94) },
	pad       = { M.Concrete, "Flat Concrete Dark",    Color3.fromRGB(78, 78, 78) },
	slab      = { M.Concrete, "BareConcrete",          Color3.fromRGB(120, 120, 116) },
	epoxy     = { M.Concrete, "Epoxy Painted Floor",   Color3.fromRGB(112, 116, 116) },
	barrier   = { M.Concrete, "Barrier",               Color3.fromRGB(150, 150, 144) },
	road      = { M.Asphalt,  "Road Asphalt",          Color3.fromRGB(70, 70, 70) },
	gravel    = { M.Slate,    "Gravel",                Color3.fromRGB(110, 106, 98) },
	hangarDoor= { M.Metal,    "Garage Door",           Color3.fromRGB(86, 90, 88) },
	metal     = { M.Metal,    "Scuffed Iron",          Color3.fromRGB(90, 92, 90) },
	panel     = { M.Metal,    "Metal Panel 004",       Color3.fromRGB(96, 100, 98) },
	corrugated= { M.Metal,    "Corrugated Metal",      Color3.fromRGB(92, 96, 92) },
	grate     = { M.Metal,    "Metal Grate",           Color3.fromRGB(74, 76, 74) },
	container = { M.Metal,    "Storage Container",     Color3.fromRGB(90, 100, 72) },
	tank      = { M.Metal,    "Streaky Metal",         Color3.fromRGB(160, 160, 156) },
	ceiling   = { M.Metal,    "Warehouse Ceiling",     Color3.fromRGB(86, 86, 86) },
	shutter   = { M.Plastic,  "MetalShutter",          Color3.fromRGB(104, 108, 106) },
	vent      = { M.Plastic,  "Metal Ventilation 1",   Color3.fromRGB(112, 112, 112) },
	hesco     = { M.Fabric,   nil,                     Color3.fromRGB(165, 145, 108) },
	glass     = { M.Glass,    nil,                     Color3.fromRGB(70, 88, 98), 0.35 },
	dark      = { M.SmoothPlastic, nil,                Color3.fromRGB(30, 32, 32) },
	red       = { M.SmoothPlastic, nil,                Color3.fromRGB(180, 40, 35) },
	lampW     = { M.Neon,     nil,                     Color3.fromRGB(255, 244, 220) },
	lampA     = { M.Neon,     nil,                     Color3.fromRGB(255, 170, 60) },
	paintW    = { M.SmoothPlastic, nil,                Color3.fromRGB(215, 215, 210), 0, true },
	paintY    = { M.SmoothPlastic, nil,                Color3.fromRGB(220, 165, 40), 0, true },
	placeholder = { M.Plastic, "Baseplate Tile",       Color3.fromRGB(200, 60, 200) },
}

-- Placeholder colours, one per kind of mesh.
local PH = {
	Helicopter = Color3.fromRGB(230, 70, 70),
	Truck      = Color3.fromRGB(70, 140, 230),
	Humvee     = Color3.fromRGB(80, 200, 120),
	FuelTruck  = Color3.fromRGB(240, 170, 40),
	Forklift   = Color3.fromRGB(240, 220, 60),
	SatDish    = Color3.fromRGB(170, 90, 230),
	Radar      = Color3.fromRGB(60, 210, 210),
}

local CONTAINER_COLORS = {
	Color3.fromRGB(78, 92, 64), Color3.fromRGB(150, 128, 92), Color3.fromRGB(112, 116, 114),
	Color3.fromRGB(122, 72, 52), Color3.fromRGB(62, 80, 98),
}

-------------------------------------------------------------------------------

local ORIGIN_CF = CFrame.new(ORIGIN) * CFrame.Angles(0, math.rad(YAW), 0)

-- Every part goes through here. cf is relative to the base's centre.
local function mk(parent, class, name, cf, size, mat, color)
	local m = MAT[mat]
	local p = Instance.new(class)
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = ORIGIN_CF * cf
	p.Material = m[1]
	if m[2] then
		p.MaterialVariant = m[2]
	end
	p.Color = color or m[3]
	p.Transparency = m[4] or 0
	if m[5] then
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Box between two corners (x0,y0,z0) and (x1,y1,z1).
local function B(parent, name, x0, y0, z0, x1, y1, z1, mat, color)
	return mk(parent, "Part", name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat, color)
end

local function rod(parent, name, a, b, t, mat)
	return mk(parent, "Part", name, CFrame.lookAt((a + b) / 2, b), Vector3.new(t, t, (b - a).Magnitude), mat)
end

-- Upright cylinder standing on y0.
local function cyl(parent, name, x, y0, z, h, d, mat, color)
	local p = mk(parent, "Part", name, CFrame.new(x, y0 + h / 2, z) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(h, d, d), mat, color)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ring(parent, name, cx, cz, r, n, w, y0, h, mat)
	local seg = 2 * math.pi * r / n + 0.15
	for i = 0, n - 1 do
		local a = i / n * 2 * math.pi
		mk(parent, "Part", name, CFrame.new(cx + math.cos(a) * r, y0 + h / 2, cz + math.sin(a) * r) * CFrame.Angles(0, -a, 0),
			Vector3.new(w, h, seg), mat)
	end
end

local function model(parent, name, class)
	local m = Instance.new(class or "Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function addLight(part, class, props)
	local l = Instance.new(class)
	for k, v in pairs(props) do
		l[k] = v
	end
	l.Parent = part
	return l
end

-- Stencilled text on one face of a part. Back = the +Z (south) face.
local function sign(part, face, text, color, font)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = font or Enum.Font.GothamBlack
	t.TextColor3 = color or Color3.fromRGB(200, 200, 196)
	t.TextTransparency = 0.1
	t.Parent = gui
	gui.Parent = part
	return gui
end

-- A box standing in for a mesh: where it goes, how big it is, what it should be.
local CollectionService = game:GetService("CollectionService")
local function placeholder(parent, kind, cx, y0, cz, sx, sy, sz, yawDeg, replaceWith)
	local p = mk(parent, "Part", "MESH_" .. kind,
		CFrame.new(cx, y0 + sy / 2, cz) * CFrame.Angles(0, math.rad(yawDeg or 0), 0),
		Vector3.new(sx, sy, sz), "placeholder", PH[kind])
	p:SetAttribute("ReplaceWith", replaceWith)
	CollectionService:AddTag(p, "MeshPlaceholder")
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 20
		gui.LightInfluence = 0
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 0.5)
		t.Position = UDim2.fromScale(0, 0.25)
		t.BackgroundTransparency = 1
		t.Text = kind
		t.TextScaled = true
		t.Font = Enum.Font.GothamBold
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextStrokeTransparency = 0.4
		t.Parent = gui
		gui.Parent = p
	end
	return p
end

-- Jersey barrier centred at (cx, cz).
local function jersey(parent, cx, cz, len, alongX)
	local rot = alongX and CFrame.identity or CFrame.Angles(0, math.pi / 2, 0)
	mk(parent, "Part", "Barrier", CFrame.new(cx, 0.8, cz) * rot, Vector3.new(len, 1.6, 3), "barrier")
	mk(parent, "Part", "Barrier", CFrame.new(cx, 2.3, cz) * rot, Vector3.new(len, 1.4, 1.4), "barrier")
end

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build FAB")
end)

local old = workspace:FindFirstChild("FAB")
if old then
	old:Destroy()
end

local fab = Instance.new("Model")
fab.Name = "FAB"

local groundF = model(fab, "Ground", "Folder")
local perimF = model(fab, "Perimeter", "Folder")
local northF = model(fab, "Hangars", "Folder")
local flightF = model(fab, "FlightLine", "Folder")
local westF = model(fab, "West", "Folder")
local eastF = model(fab, "East", "Folder")
local gateF = model(fab, "Gate", "Folder")
local lightsF = model(fab, "Floodlights", "Folder")

-- The perimeter: an octagon, corners cut 60 studs.
local OCT = {
	Vector3.new(-220, 0, -220), Vector3.new(220, 0, -220), Vector3.new(280, 0, -160), Vector3.new(280, 0, 160),
	Vector3.new(220, 0, 220), Vector3.new(-220, 0, 220), Vector3.new(-280, 0, 160), Vector3.new(-280, 0, -160),
}

if CLEAR_TERRAIN then
	pcall(function()
		workspace.Terrain:FillBlock(ORIGIN_CF * CFrame.new(0, 60, 0), Vector3.new(600, 120, 480), Enum.Material.Air)
	end)
end

-- Ground ---------------------------------------------------------------------
if MAKE_GROUND then
	B(groundF, "Apron", -220, -2, -220, 220, 0, 220, "apron")
	B(groundF, "Apron", -280, -2, -160, -220, 0, 160, "apron")
	B(groundF, "Apron", 220, -2, -160, 280, 0, 160, "apron")
	-- Corner triangles: a diamond centred on each inner corner, a hair lower so
	-- it only shows where the bands above don't cover it.
	for _, c in ipairs({ { -220, -160 }, { 220, -160 }, { -220, 160 }, { 220, 160 } }) do
		mk(groundF, "Part", "Apron", CFrame.new(c[1], -1.05, c[2]) * CFrame.Angles(0, math.pi / 4, 0),
			Vector3.new(84.85, 2, 84.85), "apron")
	end
end

-- Perimeter: T-wall blast panels ------------------------------------------------
local WALL_H = 18
do
	local walls = model(perimF, "BlastWalls")
	local n = 0
	for i = 1, #OCT do
		local a, b = OCT[i], OCT[i % #OCT + 1]
		local dir = (b - a).Unit
		local L = (b - a).Magnitude
		local count = math.max(1, math.floor(L / 8 + 0.5))
		local step = L / count
		for k = 0, count - 1 do
			local pos = a + dir * ((k + 0.5) * step)
			-- Gate opening on the south wall.
			if not (i == 5 and math.abs(pos.X) < 31) then
				n += 1
				-- Local +X runs along the wall, +Z points into the base.
				local cf = CFrame.fromMatrix(pos, dir, Vector3.yAxis)
				local w = step - 0.3
				mk(walls, "Part", "TWall", cf * CFrame.new(0, WALL_H / 2, 0), Vector3.new(w, WALL_H, 1.6), "wall")
				mk(walls, "Part", "TWallBase", cf * CFrame.new(0, 1, 0), Vector3.new(w, 2, 6), "wall")
				mk(walls, "Part", "TWallCap", cf * CFrame.new(0, WALL_H - 0.4, 0), Vector3.new(w, 0.8, 2.2), "wall")
				if n % 9 == 0 then
					local lamp = mk(walls, "Part", "WallLamp", cf * CFrame.new(0, WALL_H - 3, 1.3), Vector3.new(1.6, 0.6, 1), "lampW")
					addLight(lamp, "SpotLight", { Face = Enum.NormalId.Back, Range = 32, Angle = 110, Brightness = 1.6,
						Color = MAT.lampW[3] })
				end
			end
		end
	end
end

-- Guard tower: concrete column, glazed cab, searchlight. The ladder (a climbable
-- TrussPart) is on side `ladder` ("N"/"S"/"E"/"W"), which should face inward.
local LADDER_YAW = { S = 0, N = math.pi, E = math.pi / 2, W = -math.pi / 2 }
local function guardTower(parent, name, cx, cz, ladder)
	local m = model(parent, name)
	local base = CFrame.new(cx, 0, cz) * CFrame.Angles(0, LADDER_YAW[ladder], 0)
	local function L(nm, x0, y0, z0, x1, y1, z1, mat)
		return mk(m, "Part", nm, base * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
			Vector3.new(x1 - x0, y1 - y0, z1 - z0), mat)
	end
	local col = L("Column", -6, 0, -6, 6, 24, 6, "wallDark")
	L("Floor", -8, 24, -8, 8, 25, 8, "building")
	for _, band in ipairs({ { 25, 28, "wallDark" }, { 28, 32, "glass" } }) do
		local y0, y1, mat = band[1], band[2], band[3]
		L("Wall", -8, y0, -8, 8, y1, -7.4, mat)
		L("Wall", -8, y0, -7.4, -7.4, y1, 8, mat)
		L("Wall", 7.4, y0, -7.4, 8, y1, 8, mat)
		L("Wall", -7.4, y0, 7.4, -1.6, y1, 8, mat)
		L("Wall", 1.6, y0, 7.4, 7.4, y1, 8, mat)
	end
	for _, c in ipairs({ { -8, -8 }, { 7.2, -8 }, { -8, 7.2 }, { 7.2, 7.2 } }) do
		L("Post", c[1], 28, c[2], c[1] + 0.8, 32, c[2] + 0.8, "metal")
	end
	L("Roof", -9.5, 32, -9.5, 9.5, 33.5, 9.5, "building")
	local sl = L("Searchlight", -1, 33.5, -9, 1, 35, -7.5, "metal")
	addLight(sl, "SpotLight", { Face = Enum.NormalId.Front, Range = 60, Angle = 40, Brightness = 3 })
	mk(m, "Part", "Antenna", base * CFrame.new(6, 38.5, 6), Vector3.new(0.3, 10, 0.3), "metal")
	mk(m, "TrussPart", "Ladder", base * CFrame.new(0, 13, 9), Vector3.new(2, 26, 2), "metal")
	m.PrimaryPart = col
	return m
end

guardTower(perimF, "Tower West", -265, 0, "E")
guardTower(perimF, "Tower East", 265, 0, "W")

-- Hangars + ops centre + control tower ------------------------------------------
local HANGAR_H = 32
local function hangar(label, cx)
	local m = model(northF, "Hangar " .. label)
	local x0, x1, z0, z1, H, t = cx - 45, cx + 45, -205, -135, HANGAR_H, 3
	local floor = B(m, "Floor", x0, 0, z0, x1, 0.3, z1, "epoxy")
	B(m, "Wall", x0, 0, z0, x1, H, z0 + t, "building")
	B(m, "Wall", x0, 0, z0 + t, x0 + t, H, z1, "building")
	B(m, "Wall", x1 - t, 0, z0 + t, x1, H, z1, "building")
	B(m, "Pier", x0 + t, 0, z1 - t, cx - 35, H, z1, "building")
	B(m, "Pier", cx + 35, 0, z1 - t, x1 - t, H, z1, "building")
	local lintel = B(m, "Lintel", cx - 35, 24, z1 - t, cx + 35, H, z1, "building")
	sign(lintel, Enum.NormalId.Back, label)
	-- Brutalist band across the facade, door guides, rolled-up door.
	B(m, "Band", x0 - 0.5, 26, z1, x1 + 0.5, 27.2, z1 + 1.4, "wallDark")
	B(m, "DoorGuide", cx - 36.5, 0, z1, cx - 35, 24, z1 + 1, "metal")
	B(m, "DoorGuide", cx + 35, 0, z1, cx + 36.5, 24, z1 + 1, "metal")
	B(m, "RolledDoor", cx - 35, 21.5, z1 - t - 3, cx + 35, 24, z1 - t, "hangarDoor")
	-- Roof, ceiling, lights.
	B(m, "Roof", x0 - 1, H, z0 - 1, x1 + 1, H + 2, z1 + 1, "building")
	local ceiling = B(m, "Ceiling", x0 + t, H - 0.6, z0 + t, x1 - t, H, z1 - t, "ceiling")
	addLight(ceiling, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 36, Angle = 90, Brightness = 1.2,
		Color = MAT.lampW[3] })
	for _, lx in ipairs({ -24, 0, 24 }) do
		B(m, "LightStrip", cx + lx - 0.5, H - 1.1, z0 + 10, cx + lx + 0.5, H - 0.6, z1 - 10, "lampW")
	end
	-- Roof plant.
	B(m, "Vent", cx - 30, H + 2, -195, cx - 18, H + 6, -185, "vent")
	B(m, "Vent", cx + 14, H + 2, -196, cx + 24, H + 5, -188, "vent")
	B(m, "Vent", cx - 6, H + 2, -160, cx + 4, H + 4.5, -152, "vent")
	placeholder(m, "Helicopter", cx, 0.3, -172, 12, 14, 56, 0, "Helicopter (fuselage; rotor ~57 studs across)")
	-- Taxi line from the door to the flight line.
	B(m, "TaxiLine", cx - 0.4, 0, z1, cx + 0.4, 0.05, -100, "paintY")
	m.PrimaryPart = floor
	return m
end
hangar("01", -65)
hangar("02", 65)

do
	local ops = model(northF, "Ops Centre")
	local floor = B(ops, "Floor", -20, 0, -205, 20, 0.3, -140, "epoxy")
	B(ops, "Wall", -20, 0, -205, 20, 36, -203, "bldLight")
	B(ops, "Wall", -20, 0, -203, -18, 36, -140, "bldLight")
	B(ops, "Wall", 18, 0, -203, 20, 36, -140, "bldLight")
	B(ops, "Wall", -18, 0, -142, -3, 36, -140, "bldLight")
	B(ops, "Wall", 3, 0, -142, 18, 36, -140, "bldLight")
	B(ops, "Wall", -3, 8, -142, 3, 36, -140, "bldLight")
	B(ops, "Door", -3, 0, -141.2, 3, 8, -140.8, "panel", Color3.fromRGB(60, 64, 62))
	B(ops, "Window", -16, 20, -140, 16, 26, -139.6, "glass")
	B(ops, "Window", -16, 11, -140, 16, 14, -139.6, "glass")
	B(ops, "Canopy", -6, 8.5, -140, 6, 9.2, -136, "wallDark")
	B(ops, "Roof", -21, 36, -206, 21, 37.5, -139, "bldLight")
	-- Roof parapet, gap on the north side for the ladder.
	B(ops, "Parapet", -21, 37.5, -140, 21, 39.5, -139, "bldLight")
	B(ops, "Parapet", -21, 37.5, -205, -21 + 1, 39.5, -140, "bldLight")
	B(ops, "Parapet", 20, 37.5, -205, 21, 39.5, -140, "bldLight")
	B(ops, "Parapet", -21, 37.5, -206, -2, 39.5, -205, "bldLight")
	B(ops, "Parapet", 2, 37.5, -206, 21, 39.5, -205, "bldLight")
	mk(ops, "TrussPart", "Ladder", CFrame.new(0, 20, -207), Vector3.new(2, 40, 2), "metal")

	-- Control tower on the roof.
	B(ops, "Shaft", -10, 37.5, -185, 10, 48, -165, "wallDark")
	B(ops, "CabFloor", -14, 48, -189, 14, 49, -161, "building")
	for _, band in ipairs({ { 49, 52, "wallDark" }, { 52, 57, "glass" } }) do
		local y0, y1, mat = band[1], band[2], band[3]
		B(ops, "CabWall", -14, y0, -161.6, 14, y1, -161, mat)
		B(ops, "CabWall", -14, y0, -188.4, -13.4, y1, -161.6, mat)
		B(ops, "CabWall", 13.4, y0, -188.4, 14, y1, -161.6, mat)
		B(ops, "CabWall", -14, y0, -189, -1.6, y1, -188.4, mat)
		B(ops, "CabWall", 1.6, y0, -189, 14, y1, -188.4, mat)
	end
	for _, c in ipairs({ { -14, -189 }, { 13.2, -189 }, { -14, -161.8 }, { 13.2, -161.8 } }) do
		B(ops, "Mullion", c[1], 52, c[2], c[1] + 0.8, 57, c[2] + 0.8, "metal")
	end
	B(ops, "CabRoof", -15.5, 57, -190.5, 15.5, 58.5, -159.5, "building")
	mk(ops, "TrussPart", "Ladder", CFrame.new(0, 44.5, -190), Vector3.new(2, 14, 2), "metal")
	local cabLight = B(ops, "CabLight", -8, 48.99, -183, 8, 49.1, -167, "lampW")
	addLight(cabLight, "PointLight", { Range = 18, Brightness = 0.8, Color = MAT.lampW[3] })
	-- Antennas + a beacon.
	for _, a in ipairs({ { -9, -181, 16 }, { 7, -184, 12 }, { 10, -165, 9 }, { -4, -166, 7 } }) do
		rod(ops, "Antenna", Vector3.new(a[1], 58.5, a[2]), Vector3.new(a[1], 58.5 + a[3], a[2]), 0.35, "metal")
		B(ops, "AntennaArm", a[1] - 1.5, 58.5 + a[3] * 0.7, a[2] - 0.15, a[1] + 1.5, 58.5 + a[3] * 0.7 + 0.3, a[2] + 0.15, "metal")
	end
	local beacon = B(ops, "Beacon", -0.6, 58.5, -175.6, 0.6, 59.7, -174.4, "red")
	beacon.Material = Enum.Material.Neon
	addLight(beacon, "PointLight", { Range = 14, Brightness = 1.5, Color = Color3.fromRGB(255, 60, 50) })
	placeholder(ops, "SatDish", -14, 37.5, -150, 8, 8, 8, 0, "Satellite dish")
	placeholder(ops, "Radar", 12, 58.5, -172, 5, 6, 5, 0, "Rotating radar")
	sign(B(ops, "Sign", -12, 30, -139.6, 12, 34, -139.3, "dark"), Enum.NormalId.Back, "FLIGHT OPS",
		Color3.fromRGB(200, 200, 196), Enum.Font.GothamBold)
	ops.PrimaryPart = floor
end

-- Workshop annexes either side of the hangars.
for _, ax in ipairs({ { -150, -110, "Workshop West" }, { 110, 150, "Workshop East" } }) do
	local m = model(northF, ax[3])
	local body = B(m, "Body", ax[1], 0, -200, ax[2], 16, -150, "bldLight")
	B(m, "Shutter", ax[1] + 6, 0, -150, ax[2] - 14, 12, -149.6, "shutter")
	B(m, "Door", ax[2] - 10, 0, -150, ax[2] - 5, 7.5, -149.6, "panel", Color3.fromRGB(60, 64, 62))
	B(m, "Band", ax[1] - 0.5, 13, -150, ax[2] + 0.5, 14, -149, "wallDark")
	B(m, "Vent", ax[1] + 8, 16, -190, ax[1] + 18, 19, -180, "vent")
	local lamp = B(m, "Lamp", ax[1] + 16, 13.4, -149, ax[1] + 20, 13.8, -148.4, "lampW")
	addLight(lamp, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 22, Angle = 100, Brightness = 1.4 })
	m.PrimaryPart = body
end

-- Fuel farm (NE) -------------------------------------------------------------
do
	local farm = model(northF, "Fuel Farm")
	local floor = B(farm, "Gravel", 159.5, 0, -195.5, 220.5, 0.15, -134.5, "gravel")
	B(farm, "Bund", 158, 0, -197, 222, 4, -195.5, "wall")
	B(farm, "Bund", 158, 0, -134.5, 222, 4, -133, "wall")
	B(farm, "Bund", 158, 0, -195.5, 159.5, 4, -134.5, "wall")
	B(farm, "Bund", 220.5, 0, -195.5, 222, 4, -134.5, "wall")
	for _, t in ipairs({ { 175, -180, -1 }, { 205, -180, 1 }, { 175, -150, -1 }, { 205, -150, 1 } }) do
		cyl(farm, "Tank", t[1], 0.15, t[2], 20, 24, "tank")
		cyl(farm, "TankCap", t[1], 20.15, t[2], 1.2, 22, "tank", Color3.fromRGB(140, 140, 136))
		cyl(farm, "TankBand", t[1], 6, t[2], 0.8, 24.4, "metal")
		cyl(farm, "TankBand", t[1], 13, t[2], 0.8, 24.4, "metal")
		mk(farm, "TrussPart", "Ladder", CFrame.new(t[1] + t[3] * 13, 11, t[2]), Vector3.new(2, 22, 2), "metal")
	end
	-- Pipework: header along the south side, riser in the gap between the tanks,
	-- then out through the bund to the pump by pad 4.
	local y = 1.4
	rod(farm, "Pipe", Vector3.new(170, y, -136), Vector3.new(210, y, -136), 0.9, "metal")
	rod(farm, "Pipe", Vector3.new(190, y, -180), Vector3.new(190, y, -136), 0.9, "metal")
	rod(farm, "Pipe", Vector3.new(187, y, -180), Vector3.new(193, y, -180), 0.9, "metal")
	rod(farm, "Pipe", Vector3.new(175, y, -138), Vector3.new(175, y, -136), 0.9, "metal")
	rod(farm, "Pipe", Vector3.new(205, y, -138), Vector3.new(205, y, -136), 0.9, "metal")
	rod(farm, "Pipe", Vector3.new(210, y, -136), Vector3.new(210, y, -116), 0.9, "metal")
	for z = -178, -140, 8 do
		B(farm, "PipeSupport", 189.4, 0.15, z - 0.4, 190.6, y, z + 0.4, "metal")
	end
	for z = -130, -118, 6 do
		B(farm, "PipeSupport", 209.4, 0, z - 0.4, 210.6, y, z + 0.4, "metal")
	end
	B(farm, "FuelPump", 204, 0, -116, 214, 5, -110, "panel", Color3.fromRGB(150, 130, 60))
	rod(farm, "HoseReel", Vector3.new(202.6, 2.5, -114.5), Vector3.new(202.6, 2.5, -111.5), 3, "dark")
	B(farm, "PumpCanopy", 202, 8, -118, 216, 8.6, -108, "metal")
	for _, c in ipairs({ { 202, -118 }, { 215.4, -118 }, { 202, -108.6 }, { 215.4, -108.6 } }) do
		B(farm, "CanopyPost", c[1], 0, c[2], c[1] + 0.6, 8, c[2] + 0.6, "metal")
	end
	sign(B(farm, "Sign", 176, 4.2, -133.3, 204, 7.8, -133, "dark"), Enum.NormalId.Back, "FUEL — NO SMOKING",
		Color3.fromRGB(220, 165, 40), Enum.Font.GothamBold)
	farm.PrimaryPart = floor
end

-- Helipads ---------------------------------------------------------------------
local function helipad(parent, name, cx, cz, size, big)
	local m = model(parent, name)
	local h = size / 2
	local slab = B(m, "Pad", cx - h, 0, cz - h, cx + h, 0.4, cz + h, "pad")
	local top = 0.4
	if big then
		local i0, i1 = 3, 4.2
		B(m, "Border", cx - h + i0, top, cz - h + i0, cx + h - i0, top + 0.05, cz - h + i1, "paintW")
		B(m, "Border", cx - h + i0, top, cz + h - i1, cx + h - i0, top + 0.05, cz + h - i0, "paintW")
		B(m, "Border", cx - h + i0, top, cz - h + i1, cx - h + i1, top + 0.05, cz + h - i1, "paintW")
		B(m, "Border", cx + h - i1, top, cz - h + i1, cx + h - i0, top + 0.05, cz + h - i1, "paintW")
	end
	local r, rw = big and 32 or 18, big and 2 or 1.5
	ring(m, "Ring", cx, cz, r, big and 48 or 32, rw, top, 0.05, big and "paintW" or "paintY")
	local s, w, len = big and 9 or 6, big and 4 or 2.5, big and 28 or 18
	B(m, "H", cx - s - w / 2, top, cz - len / 2, cx - s + w / 2, top + 0.05, cz + len / 2, "paintW")
	B(m, "H", cx + s - w / 2, top, cz - len / 2, cx + s + w / 2, top + 0.05, cz + len / 2, "paintW")
	B(m, "H", cx - s, top, cz - w / 2, cx + s, top + 0.05, cz + w / 2, "paintW")
	local k = big and 4 or 2
	local stepL = size / k
	for i = 0, k - 1 do
		local d = -h + i * stepL
		for _, p in ipairs({ { d, -h }, { h, d }, { -d, h }, { -h, -d } }) do
			B(m, "EdgeLight", cx + p[1] - 0.4, top, cz + p[2] - 0.4, cx + p[1] + 0.4, top + 0.5, cz + p[2] + 0.4, "lampA")
		end
	end
	m.PrimaryPart = slab
	return m
end

for i, x in ipairs({ -175, -65, 65, 175 }) do
	helipad(flightF, "Pad " .. i, x, -75, 50, false)
end
helipad(flightF, "Main Pad", 0, 20, 90, true)
placeholder(flightF, "Helicopter", -65, 0.4, -75, 12, 14, 56, 0, "Helicopter on pad 2")
placeholder(flightF, "Helicopter", 0, 0.4, 20, 12, 14, 56, 0, "Helicopter on the main pad")
placeholder(flightF, "FuelTruck", 222, 0, -100, 9, 11, 26, 0, "Fuel tanker truck")

do
	local ws = model(flightF, "Windsock")
	local pole = B(ws, "Pole", 59.7, 0, -35.3, 60.3, 16, -34.7, "metal")
	B(ws, "Sock", 60.3, 14.4, -35.8, 66.3, 15.6, -34.6, "red", Color3.fromRGB(230, 120, 30))
	ws.PrimaryPart = pole
end

-- Roads ----------------------------------------------------------------------
do
	local roads = model(fab, "Roads", "Folder")
	B(roads, "Road", -250, 0, 90, 250, 0.1, 110, "road")
	B(roads, "Road", -15, 0, 110, 15, 0.1, 262, "road")
	for x = -245, 240, 12 do
		B(roads, "Line", x, 0.1, 99.7, x + 6, 0.15, 100.3, "paintW")
	end
	for z = 116, 256, 12 do
		B(roads, "Line", -0.3, 0.1, z, 0.3, 0.15, z + 6, "paintW")
	end
	for _, z in ipairs({ 90.6, 109.4 }) do
		B(roads, "EdgeLine", -250, 0.1, z - 0.3, 250, 0.15, z + 0.3, "paintY")
	end
end

-- West: vehicle park + maintenance shed -------------------------------------------
do
	local park = model(westF, "Vehicle Park")
	for x = -250, -120, 10 do
		jersey(park, x + 5, -38, 9.6, true)
	end
	for _, row in ipairs({ { -30, 5 }, { 45, 80 } }) do
		for x = -248, -120, 16 do
			B(park, "BayLine", x - 0.3, 0, row[1], x + 0.3, 0.05, row[2], "paintW")
		end
		local zEdge = row[1] == -30 and row[2] or row[1]
		B(park, "BayLine", -248, 0, zEdge - 0.3, -120, 0.05, zEdge + 0.3, "paintW")
	end
	for _, z in ipairs({ -28, 78 }) do
		for x = -244, -128, 16 do
			B(park, "WheelStop", x, 0, z - 0.5, x + 8, 0.6, z + 0.5, "barrier")
		end
	end

	for _, x in ipairs({ -240, -208, -176 }) do
		placeholder(park, "Truck", x, 0, -12, 9, 10, 26, 0, "Military cargo truck")
		placeholder(park, "Humvee", x + 16, 0, 64, 8.5, 7, 17, 180, "Humvee / light vehicle")
	end

	local shed = model(westF, "Maintenance Shed")
	local floor = B(shed, "Floor", -213, 0, 131, -137, 0.2, 188, "epoxy")
	B(shed, "Wall", -215, 0, 188, -135, 18, 190, "corrugated")
	B(shed, "Wall", -215, 0, 130, -213, 18, 188, "corrugated")
	B(shed, "Wall", -137, 0, 130, -135, 18, 188, "corrugated")
	B(shed, "Roof", -216, 18, 129, -134, 19.2, 191, "panel")
	for _, x in ipairs({ -212.25, -175, -137.75 }) do
		B(shed, "Column", x - 0.75, 0, 130, x + 0.75, 18, 131.5, "metal")
	end
	B(shed, "Beam", -213, 16.5, 130, -137, 18, 131.5, "metal")
	for _, x in ipairs({ -188, -162 }) do
		B(shed, "BayLine", x - 0.3, 0.2, 134, x + 0.3, 0.25, 186, "paintY")
	end
	for _, x in ipairs({ -208, -182, -156 }) do
		B(shed, "Workbench", x, 0.2, 183.5, x + 14, 3.2, 187, "metal")
		B(shed, "ToolRack", x, 5, 187.4, x + 14, 11, 188, "grate")
	end
	for _, x in ipairs({ -200, -175, -150 }) do
		local strip = B(shed, "LightStrip", x - 0.5, 17.4, 136, x + 0.5, 18, 182, "lampW")
		if x == -175 then
			addLight(strip, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 22, Angle = 120, Brightness = 1.4 })
		end
	end
	placeholder(shed, "Truck", -200, 0.2, 160, 9, 10, 26, 180, "Truck under repair")
	placeholder(shed, "Humvee", -175, 0.2, 158, 8.5, 7, 17, 180, "Humvee under repair")
	shed.PrimaryPart = floor

	local power = model(westF, "Power Plant")
	local pad = B(power, "Slab", -110, 0, 135, -45, 0.3, 195, "slab")
	for _, z in ipairs({ 140, 156, 172 }) do
		B(power, "Genset", -104, 0.3, z, -82, 9.3, z + 9, "container", Color3.fromRGB(64, 76, 56))
		rod(power, "Exhaust", Vector3.new(-86, 9.3, z + 4.5), Vector3.new(-86, 14, z + 4.5), 0.9, "dark")
	end
	B(power, "Transformer", -72, 0.3, 146, -54, 8, 162, "panel")
	B(power, "Transformer", -72, 0.3, 170, -58, 6, 182, "panel")
	for x = -110, -50, 10 do
		jersey(power, x + 5, 131.5, 9.6, true)
	end
	power.PrimaryPart = pad
end

-- East: container yard + crew quarters -------------------------------------------
do
	local yard = model(eastF, "Container Yard")
	local ci = 0
	for _, z in ipairs({ -30, -6, 30, 55 }) do
		for _, x in ipairs({ 125, 149, 173, 197 }) do
			ci += 1
			local col = CONTAINER_COLORS[(ci - 1) % #CONTAINER_COLORS + 1]
			B(yard, "Container", x, 0, z, x + 22, 9, z + 9, "container", col)
			if ci % 3 == 1 then
				local col2 = CONTAINER_COLORS[(ci + 1) % #CONTAINER_COLORS + 1]
				B(yard, "Container", x + 1, 9, z, x + 23, 18, z + 9, "container", col2)
			end
		end
	end
	for x = 115, 245, 10 do
		jersey(yard, x + 5, -38, 9.6, true)
	end
	-- Pallets of crates beside the yard.
	for i, p in ipairs({ { 226, -28 }, { 234, -28 }, { 226, -18 }, { 234, 32 }, { 226, 40 } }) do
		B(yard, "Pallet", p[1], 0, p[2], p[1] + 6, 0.6, p[2] + 6, "container", Color3.fromRGB(110, 90, 60))
		B(yard, "Crates", p[1] + 0.3, 0.6, p[2] + 0.3, p[1] + 5.7, 3.6 + (i % 2) * 2, p[2] + 5.7, "container",
			Color3.fromRGB(78, 92, 64))
	end

	placeholder(yard, "Forklift", 236, 0, 10, 5, 8, 10, 90, "Forklift")

	local crew = model(eastF, "Crew Quarters")
	local body = B(crew, "Body", 60, 0, 130, 200, 22, 195, "building")
	for _, y in ipairs({ { 5, 8 }, { 15, 18 } }) do
		B(crew, "Windows", 64, y[1], 129.6, 196, y[2], 130, "glass")
	end
	for _, x in ipairs({ 95, 160 }) do
		B(crew, "Door", x, 0, 129.6, x + 6, 8, 130, "panel", Color3.fromRGB(60, 64, 62))
		B(crew, "Canopy", x - 3, 8.5, 126, x + 9, 9.2, 130, "wallDark")
		local lamp = B(crew, "Lamp", x + 2, 8, 129.2, x + 4, 8.4, 129.6, "lampW")
		addLight(lamp, "PointLight", { Range = 14, Brightness = 1.2 })
	end
	B(crew, "Band", 59.5, 11, 129, 200.5, 12, 130, "wallDark")
	B(crew, "Parapet", 60, 22, 130, 200, 24, 131, "building")
	B(crew, "Parapet", 60, 22, 194, 200, 24, 195, "building")
	B(crew, "Parapet", 60, 22, 131, 61, 24, 194, "building")
	B(crew, "Parapet", 199, 22, 131, 200, 24, 194, "building")
	for _, x in ipairs({ 80, 120, 170 }) do
		B(crew, "Vent", x, 22, 150, x + 10, 25, 160, "vent")
	end
	crew.PrimaryPart = body
end

-- Gate ------------------------------------------------------------------------
do
	local piers = model(gateF, "Piers")
	local pw = B(piers, "Pier", -30, 0, 214, -18, 24, 226, "wallDark")
	local pe = B(piers, "Pier", 18, 0, 214, 30, 24, 226, "wallDark")
	sign(pe, Enum.NormalId.Back, GATE_CODE)
	sign(pw, Enum.NormalId.Back, GATE_CODE)
	B(piers, "PierCap", -31, 24, 213, -17, 25.5, 227, "wall")
	B(piers, "PierCap", 17, 24, 213, 31, 25.5, 227, "wall")
	for _, x in ipairs({ -24, 24 }) do
		local lamp = B(piers, "Lamp", x - 1, 21, 226, x + 1, 21.6, 227, "lampW")
		addLight(lamp, "SpotLight", { Face = Enum.NormalId.Back, Range = 40, Angle = 100, Brightness = 2 })
	end

	local board = B(gateF, "NameSign", -100, 6, 220.9, -40, 15, 221.5, "panel", Color3.fromRGB(58, 62, 62))
	local gui = sign(board, Enum.NormalId.Back, BASE_NAME, Color3.fromRGB(205, 205, 200), Enum.Font.GothamBlack)
	local lbl = gui:FindFirstChildOfClass("TextLabel")
	lbl.Size = UDim2.fromScale(0.9, 0.6)
	lbl.Position = UDim2.fromScale(0.05, 0.05)
	local sub = lbl:Clone()
	sub.Text = BASE_SUBTITLE
	sub.Font = Enum.Font.GothamBold
	sub.Size = UDim2.fromScale(0.9, 0.25)
	sub.Position = UDim2.fromScale(0.05, 0.68)
	sub.Parent = gui

	guardTower(gateF, "Gate Tower West", -34, 200, "N")
	guardTower(gateF, "Gate Tower East", 34, 200, "N")

	B(gateF, "BarPost", 15.5, 0, 204.5, 16.5, 4.5, 205.5, "metal")
	B(gateF, "DropBar", -15, 3.3, 204.75, 15.5, 3.8, 205.25, "red")
	-- Sliding gate, parked open against the inside of the wall.
	local gate = model(gateF, "Sliding Gate")
	B(gate, "Frame", 18, 0, 211, 54, 1, 212, "metal")
	B(gate, "Frame", 18, 13, 211, 54, 14, 212, "metal")
	B(gate, "Mesh", 18, 1, 211.3, 54, 13, 211.7, "grate")
	B(gate, "Rail", 16, 0, 210.8, 58, 0.3, 212.2, "metal")

	local booth = model(gateF, "Checkpoint")
	B(booth, "Body", 22, 0, 180, 32, 3, 190, "bldLight")
	B(booth, "Glass", 22, 3, 180, 32, 7.5, 190, "glass")
	B(booth, "Roof", 21, 7.5, 179, 33, 8.5, 191, "wallDark")

	local hesco = model(gateF, "HESCO")
	for _, side in ipairs({ -1, 1 }) do
		for i = 0, 8 do
			local x0 = side == 1 and (32 + i * 4.2) or (-32 - i * 4.2 - 4)
			B(hesco, "HESCO", x0, 0, 224, x0 + 4, 5, 228, "hesco")
		end
	end

	local serp = model(gateF, "Serpentine")
	jersey(serp, -6, 236, 18, true)
	jersey(serp, 6, 250, 18, true)
	jersey(serp, -6, 264, 18, true)
end

-- Floodlights ---------------------------------------------------------------------
for i, p in ipairs({
	{ -105, -42 }, { 105, -42 }, { -60, 75 }, { 60, 75 }, { -235, -120 },
	{ 235, -120 }, { -235, 125 }, { 235, 125 }, { -30, 150 }, { 30, 150 },
}) do
	local m = model(lightsF, "Floodlight " .. i)
	local x, z = p[1], p[2]
	B(m, "Plinth", x - 1.5, 0, z - 1.5, x + 1.5, 1.5, z + 1.5, "barrier")
	local pole = B(m, "Pole", x - 0.5, 1.5, z - 0.5, x + 0.5, 40, z + 0.5, "metal")
	B(m, "Arm", x - 4, 39, z - 0.4, x + 4, 39.8, z + 0.4, "metal")
	for _, dx in ipairs({ -3, 3 }) do
		B(m, "Housing", x + dx - 1.2, 37.8, z - 1, x + dx + 1.2, 39, z + 1, "dark")
		local lamp = B(m, "Lamp", x + dx - 1, 37.6, z - 0.8, x + dx + 1, 37.8, z + 0.8, "lampW")
		if dx == 3 then
			addLight(lamp, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 70, Angle = 110, Brightness = 2.2,
				Color = MAT.lampW[3] })
		end
	end
	m.PrimaryPart = pole
end

-------------------------------------------------------------------------------

fab.WorldPivot = ORIGIN_CF
fab.Parent = workspace

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build FAB")
	end)
end

-- Report any variant names that don't exist in this place (they'd show as plain
-- material): easy to fix in the MAT table at the top.
local MaterialService = game:GetService("MaterialService")
local have = {}
for _, d in ipairs(MaterialService:GetDescendants()) do
	if d:IsA("MaterialVariant") then
		have[d.Name .. "|" .. d.BaseMaterial.Name] = true
	end
end
local missing = {}
for key, m in pairs(MAT) do
	if m[2] and not have[m[2] .. "|" .. m[1].Name] then
		table.insert(missing, ("%s (%s on %s)"):format(key, m[2], m[1].Name))
	end
end

local count = 0
for _, d in ipairs(fab:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[FAB] Built Workspace.FAB: %d parts."):format(count))
if #missing > 0 then
	warn("[FAB] These MaterialVariants weren't found, so those parts use the plain material: "
		.. table.concat(missing, ", "))
end
