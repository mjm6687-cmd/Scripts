--[[
	COMMAND POST BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Builds a hardened command post (TOC) as Workspace > CommandPost. Run it again
	any time: it deletes the old one and rebuilds. Ctrl+Z undoes it.

	WHERE IT GOES: if Workspace > FAB (the aviation base) exists, it sits in the
	open ground west of the main helipad, entrance facing the main road, and
	follows the FAB wherever you've moved it. Otherwise it goes at ORIGIN.
	It is kept OUTSIDE the FAB model so rebuilding the base doesn't delete it.

	WHAT'S IN IT (north is -Z; the entrance faces +Z / south):
	  * a ring of T-wall blast panels, a blast-wall chicane at the entrance and
	    a generator yard behind the building
	  * a concrete bunker with a blast hood over the door and slit windows
	  * inside: entry airlock, operations floor (map table, 8 workstations,
	    a big status screen), commander's office, comms room (radio racks),
	    briefing room (screen, chairs, lectern), server room
	  * roof: ladder, parapet, antenna masts, AC units, beacon
	Radios and the satellite dish are MESH_ placeholders (Baseplate Tile
	texture, tagged "MeshPlaceholder", "ReplaceWith" attribute) for your meshes.
]]

local PLACE_IN_FAB = true
local ORIGIN = Vector3.new(0, 0, 0) -- used when there's no FAB (or PLACE_IN_FAB is false)
local YAW = 0

local UNIT_NAME = "COMMAND POST"

-------------------------------------------------------------------------------

local M = Enum.Material
local MAT = {
	wall      = { M.Concrete, "InSitu Concrete",       Color3.fromRGB(128, 128, 124) },
	bunker    = { M.Concrete, "Layered Bunker",        Color3.fromRGB(112, 112, 108) },
	trim      = { M.Concrete, "Concrete Cladding",     Color3.fromRGB(100, 100, 97) },
	slab      = { M.Concrete, "BareConcrete",          Color3.fromRGB(118, 118, 114) },
	interior  = { M.Concrete, "Bunker Concrete Light", Color3.fromRGB(150, 150, 146) },
	floor     = { M.Concrete, "Epoxy Painted Floor",   Color3.fromRGB(96, 104, 104) },
	barrier   = { M.Concrete, "Barrier",               Color3.fromRGB(150, 150, 144) },
	ceiling   = { M.Metal,    "Suspended Ceiling",     Color3.fromRGB(170, 170, 168) },
	metal     = { M.Metal,    "Scuffed Iron",          Color3.fromRGB(90, 92, 90) },
	panel     = { M.Metal,    "Metal Panel 004",       Color3.fromRGB(96, 100, 98) },
	container = { M.Metal,    "Storage Container",     Color3.fromRGB(64, 76, 56) },
	vent      = { M.Plastic,  "Metal Ventilation 1",   Color3.fromRGB(112, 112, 112) },
	desk      = { M.WoodPlanks, "Wood Planking",       Color3.fromRGB(120, 100, 76) },
	hesco     = { M.Fabric,   nil,                     Color3.fromRGB(165, 145, 108) },
	glass     = { M.Glass,    nil,                     Color3.fromRGB(60, 76, 86), 0.35 },
	dark      = { M.SmoothPlastic, nil,                Color3.fromRGB(28, 30, 30) },
	chair     = { M.Fabric,   nil,                     Color3.fromRGB(40, 44, 44) },
	lampW     = { M.Neon,     nil,                     Color3.fromRGB(255, 244, 220) },
	ledG      = { M.Neon,     nil,                     Color3.fromRGB(80, 255, 120) },
	ledR      = { M.Neon,     nil,                     Color3.fromRGB(255, 60, 50) },
	placeholder = { M.Plastic, "Baseplate Tile",       Color3.fromRGB(200, 60, 200) },
}

local PH = {
	Radio   = Color3.fromRGB(240, 140, 60),
	SatDish = Color3.fromRGB(170, 90, 230),
}

-------------------------------------------------------------------------------

local fab = workspace:FindFirstChild("FAB")
local ORIGIN_CF
if PLACE_IN_FAB and fab and fab:IsA("Model") then
	ORIGIN_CF = fab:GetPivot() * CFrame.new(-82, 0, 18)
else
	ORIGIN_CF = CFrame.new(ORIGIN) * CFrame.Angles(0, math.rad(YAW), 0)
end

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
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function B(parent, name, x0, y0, z0, x1, y1, z1, mat, color)
	return mk(parent, "Part", name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat, color)
end

local function rod(parent, name, a, b, t, mat)
	-- A vertical rod needs a different "up" hint, or lookAt has no sideways axis.
	local up = math.abs((b - a).Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
	return mk(parent, "Part", name, CFrame.lookAt((a + b) / 2, b, up), Vector3.new(t, t, (b - a).Magnitude), mat)
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

local function textLabel(parent, text, pos, size, color, font, align)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = pos
	t.Size = size
	t.Text = text
	t.TextScaled = true
	t.TextColor3 = color
	t.Font = font
	t.TextXAlignment = align or Enum.TextXAlignment.Center
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.Parent = parent
	return t
end

-- A glowing display: title bar + lines of text, on one face of a dark panel.
local function screen(parent, name, x0, y0, z0, x1, y1, z1, face, title, body)
	local p = B(parent, name, x0, y0, z0, x1, y1, z1, "dark")
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, -8, 1, -8)
	bg.Position = UDim2.fromOffset(4, 4)
	bg.BackgroundColor3 = Color3.fromRGB(8, 22, 30)
	bg.BorderSizePixel = 0
	bg.Parent = gui
	textLabel(bg, title, UDim2.fromScale(0.04, 0.04), UDim2.fromScale(0.92, 0.2),
		Color3.fromRGB(110, 210, 255), Enum.Font.GothamBold, Enum.TextXAlignment.Left)
	if body then
		textLabel(bg, body, UDim2.fromScale(0.04, 0.3), UDim2.fromScale(0.92, 0.64),
			Color3.fromRGB(120, 255, 150), Enum.Font.Code, Enum.TextXAlignment.Left)
	end
	gui.Parent = p
	return p
end

local CollectionService = game:GetService("CollectionService")
local function placeholder(parent, kind, cx, y0, cz, sx, sy, sz, replaceWith)
	local p = mk(parent, "Part", "MESH_" .. kind, CFrame.new(cx, y0 + sy / 2, cz), Vector3.new(sx, sy, sz),
		"placeholder", PH[kind])
	p:SetAttribute("ReplaceWith", replaceWith)
	CollectionService:AddTag(p, "MeshPlaceholder")
	for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }) do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0
		textLabel(gui, kind, UDim2.fromScale(0, 0.25), UDim2.fromScale(1, 0.5), Color3.new(1, 1, 1),
			Enum.Font.GothamBold).TextStrokeTransparency = 0.4
		gui.Parent = p
	end
	return p
end

-- Run of T-wall panels from a to b; local +Z (the lamp side) = dir x up.
local function tWallRun(parent, a, b, h, skip, lampEvery)
	local dir = (b - a).Unit
	local L = (b - a).Magnitude
	local count = math.max(1, math.floor(L / 8 + 0.5))
	local step = L / count
	for k = 0, count - 1 do
		local pos = a + dir * ((k + 0.5) * step)
		if not (skip and skip(pos)) then
			local cf = CFrame.fromMatrix(pos, dir, Vector3.yAxis)
			local w = step - 0.3
			mk(parent, "Part", "TWall", cf * CFrame.new(0, h / 2, 0), Vector3.new(w, h, 1.6), "wall")
			mk(parent, "Part", "TWallBase", cf * CFrame.new(0, 1, 0), Vector3.new(w, 2, 6), "wall")
			mk(parent, "Part", "TWallCap", cf * CFrame.new(0, h - 0.4, 0), Vector3.new(w, 0.8, 2.2), "wall")
			if lampEvery and k % lampEvery == 1 then
				local lamp = mk(parent, "Part", "WallLamp", cf * CFrame.new(0, h - 2.5, 1.3), Vector3.new(1.4, 0.5, 1), "lampW")
				addLight(lamp, "SpotLight", { Face = Enum.NormalId.Back, Range = 22, Angle = 110, Brightness = 1.3 })
			end
		end
	end
end

-- Workstation against a side wall. side = -1 (west wall, faces east) or 1.
local function workstation(parent, side, z0, z1)
	local xw = side * 16          -- wall face
	local xi = side * 12          -- inner edge of the desk
	local x0, x1 = math.min(xw, xi), math.max(xw, xi)
	B(parent, "DeskTop", x0, 3, z0, x1, 3.4, z1, "desk")
	B(parent, "DeskSide", x0, 0.5, z0, x1, 3, z0 + 0.3, "panel")
	B(parent, "DeskSide", x0, 0.5, z1 - 0.3, x1, 3, z1, "panel")
	local mx = side * 15.3
	screen(parent, "Monitor", mx - 0.15, 3.6, z0 + 0.6, mx + 0.15, 5.8, z1 - 0.6,
		side < 0 and Enum.NormalId.Right or Enum.NormalId.Left, "STATION", "ONLINE\nNET 4 OK")
	B(parent, "Keyboard", side * 13.4 - 0.5, 3.4, (z0 + z1) / 2 - 1, side * 13.4 + 0.5, 3.55, (z0 + z1) / 2 + 1, "dark")
	local cx, cz = side * 10.5, (z0 + z1) / 2
	B(parent, "ChairSeat", cx - 1, 1.8, cz - 1, cx + 1, 2.2, cz + 1, "chair")
	B(parent, "ChairBack", cx - side * 1 - 0.2, 2.2, cz - 1, cx - side * 1 + 0.2, 5, cz + 1, "chair")
	B(parent, "ChairPost", cx - 0.2, 0.5, cz - 0.2, cx + 0.2, 1.8, cz + 0.2, "metal")
end

local function ceilingLight(parent, x0, z0, x1, z1)
	local c = B(parent, "Ceiling", x0, 11.6, z0, x1, 12, z1, "ceiling")
	addLight(c, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 16, Angle = 120, Brightness = 0.9,
		Color = MAT.lampW[3] })
	local mx, mz = (x0 + x1) / 2, (z0 + z1) / 2
	B(parent, "LightPanel", mx - 2, 11.45, mz - 1, mx + 2, 11.6, mz + 1, "lampW")
end

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Command Post")
end)

local old = workspace:FindFirstChild("CommandPost")
if old then
	old:Destroy()
end

local cp = Instance.new("Model")
cp.Name = "CommandPost"

local site = model(cp, "Site")
local shell = model(cp, "Building")
local inside = model(cp, "Interior")
local roof = model(cp, "Roof")

-- Site: slab, blast-wall ring, entrance chicane, generator yard -----------------
local groundSlab = B(site, "Slab", -28, 0, -46, 28, 0.15, 50, "slab")
tWallRun(site, Vector3.new(-26, 0, -44), Vector3.new(26, 0, -44), 12, nil, 3)
tWallRun(site, Vector3.new(26, 0, -44), Vector3.new(26, 0, 38), 12, nil, 3)
tWallRun(site, Vector3.new(26, 0, 38), Vector3.new(-26, 0, 38), 12, function(p)
	return math.abs(p.X) < 5
end, 3)
tWallRun(site, Vector3.new(-26, 0, 38), Vector3.new(-26, 0, -44), 12, nil, 3)
-- Chicane: a short blast wall in front of the gap, so you walk in round it.
tWallRun(site, Vector3.new(10, 0, 46), Vector3.new(-10, 0, 46), 12)

local gen = model(site, "Generator")
B(gen, "Genset", -20, 0.15, -41, -4, 8, -32, "container")
rod(gen, "Exhaust", Vector3.new(-7, 8, -36.5), Vector3.new(-7, 13, -36.5), 0.9, "dark")
B(gen, "FuelTank", 4, 0.15, -41, 18, 3.5, -33, "panel", Color3.fromRGB(70, 80, 60))
rod(gen, "Cable", Vector3.new(-12, 0.6, -32), Vector3.new(-12, 0.6, -26), 0.6, "dark")
B(gen, "Barrier", -22, 0.15, -30.5, 20, 3, -29.5, "barrier")

-- Building shell ---------------------------------------------------------------
B(shell, "Floor", -18, 0.15, -26, 18, 0.5, 26, "floor")
B(shell, "Wall", -18, 0, -26, 18, 14, -24, "bunker")                         -- north
B(shell, "Wall", -18, 0, -24, -16, 14, 24, "bunker")                         -- west
B(shell, "Wall", 16, 0, -24, 18, 14, 24, "bunker")                           -- east
B(shell, "Wall", -18, 0, 24, -3, 14, 26, "bunker")                           -- south, west of door
B(shell, "Wall", 3, 0, 24, 18, 14, 26, "bunker")                             -- south, east of door
B(shell, "Wall", -3, 8, 24, 3, 14, 26, "bunker")                             -- over the door
B(shell, "Roof", -19, 14, -27, 19, 15.5, 27, "trim")
B(shell, "Band", -18.6, 12.2, -26.6, 18.6, 13.2, 26.6, "trim")
-- Slit windows high on the side walls.
for _, z in ipairs({ -18, -4, 6, 18 }) do
	B(shell, "SlitWindow", -18.05, 9, z - 3, -17.8, 10.4, z + 3, "glass")
	B(shell, "SlitWindow", 17.8, 9, z - 3, 18.05, 10.4, z + 3, "glass")
end
-- Blast hood over the entrance, door parked open, lamp and sign.
B(shell, "Hood", -6, 9, 26, 6, 10.5, 32, "trim")
B(shell, "HoodWall", -6, 0, 26, -5, 9, 32, "bunker")
B(shell, "HoodWall", 5, 0, 26, 6, 9, 32, "bunker")
B(shell, "DoorFrame", -3.4, 0, 25.6, -3, 8.4, 26.2, "metal")
B(shell, "DoorFrame", 3, 0, 25.6, 3.4, 8.4, 26.2, "metal")
B(shell, "DoorFrame", -3.4, 8, 25.6, 3.4, 8.4, 26.2, "metal")
B(shell, "BlastDoor", 3.4, 0.5, 26.2, 4.9, 8, 26.6, "panel") -- slid open behind the hood wall
local hoodLamp = B(shell, "HoodLamp", -1, 8.6, 29, 1, 9, 30, "lampW")
addLight(hoodLamp, "PointLight", { Range = 14, Brightness = 1.4 })
local nameSign = B(shell, "NameSign", -9, 10.8, 26, 9, 13.8, 26.3, "dark")
do
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	textLabel(gui, UNIT_NAME, UDim2.fromScale(0.04, 0.12), UDim2.fromScale(0.92, 0.76),
		Color3.fromRGB(210, 210, 205), Enum.Font.GothamBlack)
	gui.Parent = nameSign
end
-- Sandbags either side of the approach.
for _, x in ipairs({ -10, 6 }) do
	B(shell, "Sandbags", x, 0.15, 28, x + 4, 3.2, 33, "hesco")
end

-- Interior walls ----------------------------------------------------------------
local W = "interior"
-- Airlock: two walls running in from the door, inner wall with a door.
B(inside, "Wall", -5.4, 0.5, 10, -4.6, 11.6, 24, W)
B(inside, "Wall", 4.6, 0.5, 10, 5.4, 11.6, 24, W)
B(inside, "Wall", -4.6, 0.5, 15.6, -3, 11.6, 16.4, W)
B(inside, "Wall", 3, 0.5, 15.6, 4.6, 11.6, 16.4, W)
B(inside, "Lintel", -3, 8, 15.6, 3, 11.6, 16.4, W)
-- Commander's office and comms room (south corners), doors onto the ops floor.
B(inside, "Wall", -16, 0.5, 9.6, -12, 11.6, 10.4, W)
B(inside, "Wall", -8, 0.5, 9.6, -5.4, 11.6, 10.4, W)
B(inside, "Lintel", -12, 8, 9.6, -8, 11.6, 10.4, W)
B(inside, "Wall", 5.4, 0.5, 9.6, 8, 11.6, 10.4, W)
B(inside, "Wall", 12, 0.5, 9.6, 16, 11.6, 10.4, W)
B(inside, "Lintel", 8, 8, 9.6, 12, 11.6, 10.4, W)
-- Briefing room and server room (north side).
B(inside, "Wall", -16, 0.5, -12.4, -10, 11.6, -11.6, W)
B(inside, "Wall", -6, 0.5, -12.4, 8, 11.6, -11.6, W)
B(inside, "Wall", 12, 0.5, -12.4, 16, 11.6, -11.6, W)
B(inside, "Lintel", -10, 8, -12.4, -6, 11.6, -11.6, W)
B(inside, "Lintel", 8, 8, -12.4, 12, 11.6, -11.6, W)
B(inside, "Wall", 3.6, 0.5, -24, 4.4, 11.6, -12.4, W)

-- Ceilings with lights, one per room.
ceilingLight(inside, -16, -11.6, 16, 9.6)     -- ops floor
ceilingLight(inside, -16, 10.4, -5.4, 24)     -- office
ceilingLight(inside, 5.4, 10.4, 16, 24)       -- comms
ceilingLight(inside, -4.6, 16.4, 4.6, 24)     -- airlock
ceilingLight(inside, -16, -24, 3.6, -12.4)    -- briefing
ceilingLight(inside, 4.4, -24, 16, -12.4)     -- servers
B(inside, "Ceiling", -4.6, 11.6, 10.4, 4.6, 12, 15.6, "ceiling")

-- Operations floor ------------------------------------------------------------------
do
	local ops = model(inside, "Operations")
	screen(ops, "StatusScreen", -5, 4.5, -11.6, 3, 9.5, -11.3, Enum.NormalId.Back, "OPERATIONS — STATUS",
		"AO NORTHGATE      WX: OVERCAST\nFLIGHT LINE: 2 ACTIVE\nQRF: READY\nCOMMS: GREEN   NET 4")
	screen(ops, "MapScreen", 3.5, 4.5, -11.6, 7.5, 7.5, -11.3, Enum.NormalId.Back, "GRID 38S", "CP ● 4412 7730")
	B(ops, "MapTableBase", -4.5, 0.5, -3.5, 4.5, 3, 1.5, "metal")
	B(ops, "MapTableTop", -5, 3, -4, 5, 3.6, 2, "panel")
	B(ops, "Map", -4.6, 3.6, -3.6, 4.6, 3.65, 1.6, "dark", Color3.fromRGB(70, 88, 62))
	local hang = B(ops, "TableLamp", -3, 10.6, -1.6, 3, 11, -0.4, "lampW")
	addLight(hang, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 12, Angle = 70, Brightness = 1.5 })
	rod(ops, "LampCable", Vector3.new(-2.5, 11, -1), Vector3.new(-2.5, 11.6, -1), 0.1, "dark")
	rod(ops, "LampCable", Vector3.new(2.5, 11, -1), Vector3.new(2.5, 11.6, -1), 0.1, "dark")
	for _, zr in ipairs({ { -10, -6 }, { -5.5, -1.5 }, { -1, 3 }, { 3.5, 7.5 } }) do
		workstation(ops, -1, zr[1], zr[2])
		workstation(ops, 1, zr[1], zr[2])
	end
end

-- Commander's office -------------------------------------------------------------
do
	local office = model(inside, "Commander Office")
	B(office, "DeskTop", -14, 3, 16, -8, 3.4, 19, "desk")
	B(office, "DeskBody", -14, 0.5, 18.4, -8, 3, 19, "desk")
	B(office, "DeskSide", -14, 0.5, 16, -13.6, 3, 18.4, "desk")
	B(office, "DeskSide", -8.4, 0.5, 16, -8, 3, 18.4, "desk")
	screen(office, "Laptop", -12, 3.4, 16.6, -10, 4.8, 16.8, Enum.NormalId.Front, "CMD", nil)
	B(office, "ChairSeat", -12, 1.8, 13, -10, 2.2, 15, "chair")
	B(office, "ChairBack", -12, 2.2, 12.6, -10, 5.4, 13, "chair")
	B(office, "Cabinet", -16, 0.5, 21, -14.4, 6, 23.8, "metal")
	B(office, "Cabinet", -7.2, 0.5, 21, -5.4, 6, 23.8, "metal")
	B(office, "Flagpole", -15.4, 0.5, 11, -15, 9, 11.4, "metal")
	B(office, "Flag", -15.2, 6, 11.2, -15.1, 9, 14, "dark", Color3.fromRGB(70, 84, 60))
end

-- Comms room ----------------------------------------------------------------------
do
	local comms = model(inside, "Comms")
	for i, z in ipairs({ 11, 14.5 }) do
		B(comms, "RadioRack", 13, 0.5, z, 16, 9, z + 3, "dark")
		for j = 0, 3 do
			B(comms, "LED", 12.95, 2 + j * 1.8, z + 0.5, 13, 2.3 + j * 1.8, z + 1 + (i % 2), j % 2 == 0 and "ledG" or "ledR")
		end
	end
	B(comms, "DeskTop", 6, 3, 20.4, 15.6, 3.4, 24, "desk")
	B(comms, "DeskSide", 6, 0.5, 20.4, 6.4, 3, 24, "panel")
	B(comms, "DeskSide", 15.2, 0.5, 20.4, 15.6, 3, 24, "panel")
	placeholder(comms, "Radio", 8.5, 3.4, 22.6, 3, 1.6, 1.8, "Field radio set")
	placeholder(comms, "Radio", 13, 3.4, 22.6, 3, 1.6, 1.8, "Field radio set")
	for _, x in ipairs({ 8.5, 13 }) do
		B(comms, "ChairSeat", x - 1, 1.8, 17.2, x + 1, 2.2, 19.2, "chair")
		B(comms, "ChairBack", x - 1, 2.2, 16.8, x + 1, 5, 17.2, "chair")
	end
	screen(comms, "NetBoard", 5.8, 5, 11, 6.1, 9, 18, Enum.NormalId.Right, "NETS", "CMD   36.550\nFIRES 41.225\nAIR   251.00\nLOG   38.900")
end

-- Briefing room ---------------------------------------------------------------------
do
	local brief = model(inside, "Briefing")
	screen(brief, "BriefScreen", -12, 3.5, -24, -2, 9.5, -23.7, Enum.NormalId.Back, "MISSION BRIEF",
		"1. SITUATION\n2. MISSION\n3. EXECUTION\n4. SUSTAINMENT\n5. COMMAND & SIGNAL")
	B(brief, "Lectern", 0.5, 0.5, -22, 2.3, 4.5, -20.8, "desk")
	for _, z in ipairs({ -18.5, -15 }) do
		for _, x in ipairs({ -14, -11, -8, -5, -2 }) do
			B(brief, "ChairSeat", x - 0.9, 1.8, z - 0.9, x + 0.9, 2.2, z + 0.9, "chair")
			B(brief, "ChairBack", x - 0.9, 2.2, z + 0.9, x + 0.9, 4.6, z + 1.2, "chair")
			B(brief, "ChairPost", x - 0.2, 0.5, z - 0.2, x + 0.2, 1.8, z + 0.2, "metal")
		end
	end
end

-- Server room ---------------------------------------------------------------------------
do
	local servers = model(inside, "Servers")
	for _, x in ipairs({ 5, 8.6, 12.2 }) do
		B(servers, "Rack", x, 0.5, -24, x + 3.2, 10, -21, "dark")
		for j = 0, 5 do
			B(servers, "LED", x + 0.4, 2 + j * 1.3, -21.05, x + 1.6, 2.2 + j * 1.3, -21, j % 3 == 0 and "ledR" or "ledG")
		end
	end
	B(servers, "ACUnit", 13.5, 0.5, -16, 16, 8, -13, "vent")
end

-- Roof ------------------------------------------------------------------------------------
do
	B(roof, "Parapet", -19, 15.5, -27, 19, 17.5, -26, "trim")
	B(roof, "Parapet", -19, 15.5, 26, 19, 17.5, 27, "trim")
	B(roof, "Parapet", 18, 15.5, -26, 19, 17.5, 26, "trim")
	B(roof, "Parapet", -19, 15.5, -26, -18, 17.5, -1.6, "trim")
	B(roof, "Parapet", -19, 15.5, 1.6, -18, 17.5, 26, "trim")
	mk(roof, "TrussPart", "Ladder", CFrame.new(-20, 9, 0), Vector3.new(2, 18, 2), "metal")
	for _, a in ipairs({ { 10, -18, 20 }, { 13, -8, 15 }, { 5, -21, 12 } }) do
		rod(roof, "Mast", Vector3.new(a[1], 15.5, a[2]), Vector3.new(a[1], 15.5 + a[3], a[2]), 0.4, "metal")
		B(roof, "MastBase", a[1] - 1, 15.5, a[2] - 1, a[1] + 1, 16, a[2] + 1, "metal")
		for _, g in ipairs({ { 3, 0 }, { -3, 0 }, { 0, 3 } }) do
			rod(roof, "GuyWire", Vector3.new(a[1], 15.5 + a[3] * 0.75, a[2]),
				Vector3.new(a[1] + g[1], 15.5, a[2] + g[2]), 0.1, "metal")
		end
	end
	placeholder(roof, "SatDish", -9, 15.5, -17, 7, 7, 7, "Satellite dish")
	B(roof, "ACUnit", 4, 15.5, 8, 12, 19, 14, "vent")
	B(roof, "ACUnit", -12, 15.5, 10, -5, 18.5, 16, "vent")
	local beacon = B(roof, "Beacon", 9.4, 15.5 + 20, -18.6, 10.6, 15.5 + 20.8, -17.4, "ledR")
	addLight(beacon, "PointLight", { Range = 12, Brightness = 1.4, Color = MAT.ledR[3] })
end

-------------------------------------------------------------------------------

cp.PrimaryPart = groundSlab
cp.Parent = workspace

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build Command Post")
	end)
end

local count = 0
for _, d in ipairs(cp:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[CommandPost] Built Workspace.CommandPost: %d parts%s."):format(count,
	(PLACE_IN_FAB and fab) and ", placed inside the FAB" or ""))
