--[[
	HANGAR BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------
	Builds a steel aircraft hangar with an open bifold door as Workspace > Hangar.
	It goes on the ground where your camera is pointing, with the door facing
	you (turned to the nearest 90 degrees). Run it again to move it; Ctrl+Z undoes.

	OUTSIDE  ribbed metal walls and a low gable roof, thin trims at the base,
	         corners, eaves and gables, gutters and downspouts; the bifold door
	         lifted open as a canopy (frame, lights underneath, hydraulic rams);
	         two personnel doors with awnings and lights; side windows; a flood
	         light at the peak; a concrete apron.
	INSIDE   polished floor, white liner walls; dark steel portal frames built
	         as real I-beams, purlins, girts and X-bracing; hanging high-bay
	         lights; an office block across the back with doors and windows, a
	         mezzanine with railings, and steel stairs with handrails.

	Sizes are at the top. Uses your MaterialVariants.
]]

local USE_CAMERA = true
local ORIGIN = Vector3.new(0, 0, 0)   -- used if USE_CAMERA is false (middle of the door line)
local MAKE_APRON = true

local W = 104                         -- width (studs)
local D = 90                          -- depth
local EAVE = 28                       -- wall height at the eaves
local PITCH = 1 / 12                  -- roof slope
local DOOR_X0, DOOR_X1 = -40, 24      -- door opening, left and right edge
local DOOR_H = 22                     -- door opening height

local WALL_COLOR = Color3.fromRGB(196, 200, 202)
local TRIM_COLOR = Color3.fromRGB(112, 118, 124)
local STEEL_COLOR = Color3.fromRGB(46, 52, 62)
local LINER_COLOR = Color3.fromRGB(226, 229, 229)

-------------------------------------------------------------------------------

local M = Enum.Material
local MAT = {
	wall    = { M.Metal,    "Vertical Lined Metal", WALL_COLOR },
	liner   = { M.Metal,    "Vertical Lined Metal", LINER_COLOR },
	roof    = { M.Metal,    "MetalRoof0",           Color3.fromRGB(186, 190, 192) },
	trim    = { M.Metal,    "Metal",                TRIM_COLOR },
	steel   = { M.Metal,    "Metal",                STEEL_COLOR },
	rail    = { M.Metal,    "Metal",                Color3.fromRGB(70, 76, 84) },
	tread   = { M.DiamondPlate, "DiamondPlate",     Color3.fromRGB(120, 124, 126) },
	floor   = { M.Concrete, "Epoxy Painted Floor",  Color3.fromRGB(170, 172, 172) },
	apron   = { M.Concrete, "BareConcrete",         Color3.fromRGB(178, 176, 170) },
	drywall = { M.Plastic,  "DryWall",              Color3.fromRGB(232, 232, 228) },
	cladWhite = { M.Metal,  "Metal_Cladding",       Color3.fromRGB(224, 226, 226) },
	door    = { M.Metal,    "Metal Panel 004",      Color3.fromRGB(128, 142, 152) },
	doorDark= { M.Metal,    "Metal Panel 004",      Color3.fromRGB(70, 80, 90) },
	pane    = { M.SmoothPlastic, nil,               Color3.fromRGB(38, 52, 62) },
	dark    = { M.SmoothPlastic, nil,               Color3.fromRGB(30, 32, 34) },
	joint   = { M.SmoothPlastic, nil,               Color3.fromRGB(120, 118, 112), true },
	lamp    = { M.Neon,     nil,                    Color3.fromRGB(255, 246, 228) },
}

local HW = W / 2
local RISE = HW * PITCH
local function roofY(x) -- underside of the roof sheet at x
	return EAVE + RISE * (1 - math.abs(x) / HW)
end
local FLOOR = 0.3

-------------------------------------------------------------------------------

local old = workspace:FindFirstChild("Hangar")
if old then
	old:Destroy()
end

local ORIGIN_CF = CFrame.new(ORIGIN)
if USE_CAMERA and workspace.CurrentCamera then
	local cam = workspace.CurrentCamera.CFrame
	local hit = workspace:Raycast(cam.Position, cam.LookVector * 4000)
	local look = cam.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	yaw = math.floor(yaw / (math.pi / 2) + 0.5) * (math.pi / 2)
	local pos = hit and hit.Position or (cam.Position + look * 150) * Vector3.new(1, 0, 1)
	-- The aimed point is the middle of the apron; the door line is 16 studs behind it.
	ORIGIN_CF = CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -16)
end

local function part(parent, name, cf, size, mat, color, shape)
	local m = MAT[mat]
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = ORIGIN_CF * cf
	p.Material = m[1]
	if m[2] then
		p.MaterialVariant = m[2]
	end
	p.Color = color or m[3]
	if m[4] then
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

local function box(parent, name, x0, y0, z0, x1, y1, z1, mat, color)
	return part(parent, name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat, color)
end

-- Bar from a to b; its local Y follows `up` (default world up).
local function bar(parent, name, a, b, sx, sy, mat, up)
	return part(parent, name, CFrame.lookAt((a + b) / 2, b, up or Vector3.yAxis), Vector3.new(sx, sy, (b - a).Magnitude), mat)
end

-- Round bar (cylinder) from a to b.
local function tube(parent, name, a, b, d, mat)
	return part(parent, name, CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0),
		Vector3.new((b - a).Magnitude, d, d), mat, nil, Enum.PartType.Cylinder)
end

-- I-beam from a to b: web + two flanges. `up` = direction of the beam's depth.
local function ibeam(parent, a, b, depth, flange, up)
	local cf = CFrame.lookAt((a + b) / 2, b, up)
	local len = (b - a).Magnitude
	local t = 0.14
	part(parent, "Web", cf, Vector3.new(t, depth - 2 * t, len), "steel")
	part(parent, "Flange", cf * CFrame.new(0, depth / 2 - t / 2, 0), Vector3.new(flange, t, len), "steel")
	part(parent, "Flange", cf * CFrame.new(0, -depth / 2 + t / 2, 0), Vector3.new(flange, t, len), "steel")
end

local function addLight(p, class, props)
	local l = Instance.new(class)
	for k, v in pairs(props) do
		l[k] = v
	end
	l.Parent = p
	return l
end

local function group(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- Railing between two floor points at height y: posts, top + mid rail, kick plate.
local function railing(parent, x0, z0, x1, z1, y)
	local a, b = Vector3.new(x0, y, z0), Vector3.new(x1, y, z1)
	local len = (b - a).Magnitude
	local n = math.max(1, math.ceil(len / 5))
	for i = 0, n do
		local p = a + (b - a) * (i / n)
		box(parent, "Post", p.X - 0.1, y, p.Z - 0.1, p.X + 0.1, y + 3.5, p.Z + 0.1, "rail")
	end
	local up = Vector3.new(0, 1, 0)
	bar(parent, "TopRail", a + up * 3.5, b + up * 3.5, 0.16, 0.16, "rail")
	bar(parent, "MidRail", a + up * 1.8, b + up * 1.8, 0.1, 0.1, "rail")
	bar(parent, "KickPlate", a + up * 0.2, b + up * 0.2, 0.06, 0.4, "rail")
end

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Hangar")
end)

local hangar = Instance.new("Model")
hangar.Name = "Hangar"
local shell = group(hangar, "Shell")
local frame = group(hangar, "Frame")
local door = group(hangar, "BifoldDoor")
local fronts = group(hangar, "Doors")
local inside = group(hangar, "Interior")
local lightsG = group(hangar, "Lights")
local unionQueue = {}

-- Floor and apron ------------------------------------------------------------
local floor = box(inside, "Floor", -HW, 0, -D, HW, FLOOR, 0, "floor")
if MAKE_APRON then
	local apron = group(hangar, "Apron")
	box(apron, "Apron", -HW, 0, 0, HW, FLOOR, 32, "apron")
	for x = -HW + 13, HW - 1, 13 do
		box(apron, "Joint", x - 0.06, FLOOR, 0, x + 0.06, FLOOR + 0.01, 32, "joint")
	end
	for _, z in ipairs({ 11, 22 }) do
		box(apron, "Joint", -HW, FLOOR, z - 0.06, HW, FLOOR + 0.01, z + 0.06, "joint")
	end
end

-- Walls -------------------------------------------------------------------------
local T = 0.4 -- wall sheet
box(shell, "Wall", -HW, 0, -D, -HW + T, EAVE, 0, "wall")                  -- west
box(shell, "Wall", HW - T, 0, -D, HW, EAVE, 0, "wall")                    -- east
box(shell, "Wall", -HW, 0, -D, HW, EAVE, -D + T, "wall")                  -- back
box(shell, "Wall", -HW, 0, -T, DOOR_X0, EAVE, 0, "wall")                  -- front, left of door
box(shell, "Wall", DOOR_X1, 0, -T, HW, EAVE, 0, "wall")                   -- front, right of door
box(shell, "Header", DOOR_X0, DOOR_H + 1.6, -T, DOOR_X1, EAVE, 0, "wall") -- over the door

-- Gables: 2-stud strips stepped up to the roof line (the roof sheet hides the
-- steps), later unioned into one part per gable.
for _, zf in ipairs({ { -T, 0, "FrontGable" }, { -D, -D + T, "BackGable" } }) do
	local strips = {}
	for x = -HW, HW - 2, 2 do
		-- Top at the strip's higher edge (the one nearer the ridge).
		local top = roofY(x + 2 <= 0 and x + 2 or x) + 0.15
		table.insert(strips, box(shell, zf[3], x, EAVE - 0.01, zf[1], x + 2, top, zf[2], "wall"))
	end
	table.insert(unionQueue, strips)
end

-- Liner inside (white), full height on the sides and back, and round the door.
local L = 0.1
box(inside, "Liner", -HW + T, FLOOR, -D + T, -HW + T + L, EAVE - 0.5, -T, "liner")
box(inside, "Liner", HW - T - L, FLOOR, -D + T, HW - T, EAVE - 0.5, -T, "liner")
box(inside, "Liner", -HW + T, FLOOR, -D + T, HW - T, EAVE - 0.5, -D + T + L, "liner")
box(inside, "Liner", -HW + T, FLOOR, -T - L, DOOR_X0 - 1, EAVE - 0.5, -T, "liner")
box(inside, "Liner", DOOR_X1 + 1, FLOOR, -T - L, HW - T, EAVE - 0.5, -T, "liner")

-- Roof: two sloped sheets with a 1.2 overhang all round, ridge cap. -------------
local OH = 1.2
do
	local function sheet(x0, x1)
		local a = Vector3.new(x0, roofY(x0) + 0.15, 0)
		local b = Vector3.new(x1, roofY(x1) + 0.15, 0)
		local dir = (b - a).Unit
		local upv = Vector3.new(-dir.Y, dir.X, 0)
		if upv.Y < 0 then
			upv = -upv
		end
		local mid = (a + b) / 2 + Vector3.new(0, 0, -D / 2)
		part(shell, "Roof", CFrame.fromMatrix(mid, dir, upv), Vector3.new((b - a).Magnitude, 0.3, D + 2 * OH), "roof")
	end
	-- roofY keeps sloping past the walls, so the overhang drops a little, like a real eave.
	sheet(-HW - OH, 0)
	sheet(0, HW + OH)
	box(shell, "RidgeCap", -0.8, roofY(0) + 0.28, -D - OH, 0.8, roofY(0) + 0.42, OH, "trim")
end

-- Trims ---------------------------------------------------------------------------
do
	-- Base trim round the outside.
	box(shell, "BaseTrim", -HW - 0.12, 0, -D - 0.12, -HW, 0.7, 0, "trim")
	box(shell, "BaseTrim", HW, 0, -D - 0.12, HW + 0.12, 0.7, 0, "trim")
	box(shell, "BaseTrim", -HW, 0, -D - 0.12, HW, 0.7, -D, "trim")
	box(shell, "BaseTrim", -HW, 0, 0, DOOR_X0, 0.7, 0.12, "trim")
	box(shell, "BaseTrim", DOOR_X1, 0, 0, HW, 0.7, 0.12, "trim")
	-- Corner trims (thin L angles).
	for _, c in ipairs({ { -1, 0 }, { 1, 0 }, { -1, -D }, { 1, -D } }) do
		local sx, z = c[1], c[2]
		local sz = z == 0 and 1 or -1
		box(shell, "CornerTrim", sx * HW - 0.1 * sx, 0, z - 0.8 * sz, sx * HW + 0.12 * sx, EAVE, z, "trim")
		box(shell, "CornerTrim", sx * HW - 0.8 * sx, 0, z, sx * HW + 0.12 * sx, EAVE, z + 0.12 * sz, "trim")
	end
	-- Rake trim along both gables, following the roof edge.
	for _, z in ipairs({ OH + 0.05, -D - OH - 0.05 }) do
		for _, s in ipairs({ -1, 1 }) do
			local a = Vector3.new(s * (HW + OH), roofY(HW + OH) + 0.05, z)
			local b = Vector3.new(0, roofY(0) + 0.05, z)
			bar(shell, "RakeTrim", a, b, 0.12, 0.8, "trim")
		end
	end
	-- Gutters along the eaves, downspouts at the corners.
	for _, s in ipairs({ -1, 1 }) do
		local gx = s * (HW + OH + 0.35)
		local gy = roofY(HW + OH) - 0.35
		box(shell, "Gutter", gx - 0.35, gy - 0.35, -D - OH, gx + 0.35, gy + 0.3, OH, "trim")
		-- Downspouts run down the wall; an angled elbow joins them to the gutter,
		-- and a short foot kicks the water out at the bottom.
		local dx = s * (HW + 0.35)
		for _, z in ipairs({ -1.2, -D + 1.2 }) do
			box(shell, "Downspout", dx - 0.2, 1.1, z - 0.2, dx + 0.2, gy - 1.6, z + 0.2, "trim")
			bar(shell, "DownspoutElbow", Vector3.new(gx, gy - 0.3, z), Vector3.new(dx, gy - 1.7, z), 0.4, 0.4, "trim")
			bar(shell, "DownspoutFoot", Vector3.new(dx, 1.3, z), Vector3.new(dx + s * 1, 0.35, z), 0.4, 0.4, "trim")
		end
	end
end

-- Steel frame ------------------------------------------------------------------------
local FRAMES = { -1.8, -19.4, -37, -54.6, -72.2, -88.4 }
for _, z in ipairs(FRAMES) do
	local f = group(frame, "PortalFrame")
	for _, s in ipairs({ -1, 1 }) do
		local x = s * (HW - T - 0.9)
		ibeam(f, Vector3.new(x, FLOOR, z), Vector3.new(x, roofY(x) - 1.2, z), 1.6, 0.8, Vector3.xAxis)
		box(f, "BasePlate", x - 1.1, FLOOR, z - 0.6, x + 1.1, FLOOR + 0.1, z + 0.6, "steel")
		-- Rafter from the column top up to the ridge, just under the purlins.
		ibeam(f, Vector3.new(x, roofY(x) - 1.3, z), Vector3.new(0, roofY(0) - 1.3, z), 1.5, 0.8, Vector3.yAxis)
		-- Haunch plate at the knee.
		box(f, "Haunch", x - s * 2.2 - 0.07, roofY(x) - 3.4, z - 0.07, x + 0.07 * s, roofY(x) - 0.6, z + 0.07, "steel")
	end
	box(f, "RidgePlate", -0.5, roofY(0) - 2.1, z - 0.4, 0.5, roofY(0) - 0.5, z + 0.4, "steel")
end
-- Door jamb columns and header beam.
for _, x in ipairs({ DOOR_X0 - 0.8, DOOR_X1 + 0.8 }) do
	ibeam(frame, Vector3.new(x, FLOOR, -1), Vector3.new(x, DOOR_H + 1.6, -1), 1.6, 0.9, Vector3.zAxis)
end
ibeam(frame, Vector3.new(DOOR_X0 - 1.6, DOOR_H + 0.8, -1), Vector3.new(DOOR_X1 + 1.6, DOOR_H + 0.8, -1), 1.6, 0.9, Vector3.yAxis)
-- Purlins under the roof, girts on the walls, X-bracing in one bay each side.
for x = -HW + 4, HW - 4, 6 do
	box(frame, "Purlin", x - 0.1, roofY(x) - 0.6, -D + 0.6, x + 0.1, roofY(x) - 0.05, -0.6, "steel")
end
for _, y in ipairs({ 9, 18 }) do
	for _, s in ipairs({ -1, 1 }) do
		local x = s * (HW - T - 0.5)
		box(frame, "Girt", x - 0.35, y, -D + 0.6, x + 0.35, y + 0.2, -0.6, "steel")
	end
	box(frame, "Girt", -HW + 1, y, -D + T + 0.2, HW - 1, y + 0.2, -D + T + 0.9, "steel")
end
for _, s in ipairs({ -1, 1 }) do
	local x = s * (HW - T - 0.3)
	bar(frame, "Brace", Vector3.new(x, FLOOR + 1, -19.4), Vector3.new(x, EAVE - 2, -37), 0.12, 0.12, "steel")
	bar(frame, "Brace", Vector3.new(x, FLOOR + 1, -37), Vector3.new(x, EAVE - 2, -19.4), 0.12, 0.12, "steel")
end

-- Bifold door, open: a canopy hinged over the opening, tilted slightly up. ---------
do
	local cx = (DOOR_X0 + DOOR_X1) / 2
	local half = (DOOR_X1 - DOOR_X0) / 2 + 1.2
	local depth = DOOR_H / 2
	local hinge = CFrame.new(cx, DOOR_H + 1.9, 0.35) * CFrame.Angles(math.rad(-6), 0, 0)
	local function P(x0, y0, z0, x1, y1, z1, mat, name)
		return part(door, name, hinge * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
			Vector3.new(x1 - x0, y1 - y0, z1 - z0), mat)
	end
	P(-half, 0.55, 0, half, 0.8, depth, "wall", "TopSkin")
	P(-half, -0.8, 0, half, -0.6, depth, "cladWhite", "UnderSkin")
	P(-half, -0.95, depth - 0.25, half, 0.95, depth, "trim", "FrontEdge")
	P(-half, -0.95, 0, -half + 0.25, 0.95, depth, "trim", "SideEdge")
	P(half - 0.25, -0.95, 0, half, 0.95, depth, "trim", "SideEdge")
	P(-half, -0.9, 0, half, 0.9, 0.3, "steel", "HingeBeam")
	for _, z in ipairs({ depth * 0.34, depth * 0.67 }) do
		P(-half, -1.15, z - 0.2, half, -0.8, z + 0.2, "steel", "Rib")
	end
	for i = 0, 3 do
		local lx = -half + (i + 0.5) * (2 * half / 4)
		local lamp = P(lx - 1.6, -0.86, depth * 0.5 - 0.5, lx + 1.6, -0.8, depth * 0.5 + 0.5, "lamp", "Light")
		addLight(lamp, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 18, Angle = 110, Brightness = 1 })
	end
	-- Hydraulic rams from the jamb columns up to the canopy's underside.
	for _, x in ipairs({ DOOR_X0 - 0.8, DOOR_X1 + 0.8 }) do
		local base = Vector3.new(x, 11, 0.3)
		local tip = (hinge * CFrame.new(x - cx, -1.2, depth * 0.55)).Position
		local mid = base:Lerp(tip, 0.55)
		tube(door, "RamBarrel", base, mid, 0.55, "steel")
		tube(door, "RamRod", mid, tip, 0.28, "rail")
		box(door, "RamBracket", x - 0.4, 10.4, -0.1, x + 0.4, 11.6, 0.6, "steel")
	end
end

-- Personnel doors with awnings and wall lights ----------------------------------------
local function personnelDoor(x, awningW)
	local g = group(fronts, "Door")
	local dw, dh = 3.4, 7.6
	box(g, "Jamb", x - dw / 2 - 0.3, FLOOR, 0, x - dw / 2, dh + 0.3, 0.18, "trim")
	box(g, "Jamb", x + dw / 2, FLOOR, 0, x + dw / 2 + 0.3, dh + 0.3, 0.18, "trim")
	box(g, "Head", x - dw / 2 - 0.3, dh + FLOOR, 0, x + dw / 2 + 0.3, dh + 0.6, 0.18, "trim")
	box(g, "Leaf", x - dw / 2, FLOOR, 0, x + dw / 2, dh + FLOOR, 0.1, "door")
	box(g, "VisionPanel", x - 0.55, 4.6, 0.1, x + 0.55, 6.6, 0.13, "pane")
	box(g, "Handle", x + dw / 2 - 0.55, 3.5, 0.1, x + dw / 2 - 0.35, 3.7, 0.4, "rail")
	box(g, "Handle", x + dw / 2 - 1.1, 3.55, 0.3, x + dw / 2 - 0.35, 3.65, 0.4, "rail")
	box(g, "Step", x - dw / 2 - 0.6, 0, 0, x + dw / 2 + 0.6, FLOOR + 0.05, 1.4, "apron")
	-- Awning: thin sheet, fascia, two diagonal brackets.
	local ay = dh + 1.8
	local tilt = CFrame.new(x, ay, 0) * CFrame.Angles(math.rad(8), 0, 0)
	part(g, "Awning", tilt * CFrame.new(0, 0, 1.4), Vector3.new(awningW, 0.18, 2.8), "trim")
	part(g, "AwningFascia", tilt * CFrame.new(0, -0.15, 2.8), Vector3.new(awningW, 0.5, 0.1), "trim")
	for _, s in ipairs({ -1, 1 }) do
		local bx = x + s * (awningW / 2 - 0.4)
		bar(g, "Bracket", Vector3.new(bx, ay - 1.6, 0.05), (tilt * CFrame.new(s * (awningW / 2 - 0.4), -0.1, 2.3)).Position,
			0.1, 0.1, "trim")
	end
	local lamp = box(g, "WallLight", x - 0.4, ay - 1.1, 0, x + 0.4, ay - 0.5, 0.45, "dark")
	local lens = box(g, "Lens", x - 0.3, ay - 1.15, 0.05, x + 0.3, ay - 1.1, 0.4, "lamp")
	addLight(lens, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 14, Angle = 100, Brightness = 1.3 })
	return lamp
end
personnelDoor(-46, 6.5)
personnelDoor(40, 9)

-- Side windows (east wall): two storeys over the front bay.
for _, y in ipairs({ 5, 16 }) do
	for _, z in ipairs({ -7, -13, -19 }) do
		local x = HW
		box(fronts, "Window", x, y, z - 1.6, x + 0.06, y + 3, z + 1.6, "pane")
		box(fronts, "WindowFrame", x, y - 0.12, z - 1.72, x + 0.14, y, z + 1.72, "trim")
		box(fronts, "WindowFrame", x, y + 3, z - 1.72, x + 0.14, y + 3.12, z + 1.72, "trim")
		box(fronts, "WindowFrame", x, y, z - 1.72, x + 0.14, y + 3, z - 1.6, "trim")
		box(fronts, "WindowFrame", x, y, z + 1.6, x + 0.14, y + 3, z + 1.72, "trim")
		box(fronts, "Mullion", x, y, z - 0.05, x + 0.1, y + 3, z + 0.05, "trim")
	end
end

-- Flood light under the peak of the front gable.
do
	local fy = roofY(0) - 2.2
	box(lightsG, "GableFloodBody", -0.9, fy, 0, 0.9, fy + 1, 0.8, "dark")
	local lens = box(lightsG, "GableFloodLens", -0.75, fy - 0.05, 0.1, 0.75, fy, 0.7, "lamp")
	addLight(lens, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 40, Angle = 110, Brightness = 1.6 })
end

-- High-bay lights hanging from the purlins -----------------------------------------------
for _, x in ipairs({ -33, -11, 11, 33 }) do
	for _, z in ipairs({ -12, -30, -48, -66 }) do
		local y = 20
		box(lightsG, "Cable", x - 0.04, y + 1.1, z - 0.04, x + 0.04, roofY(x) - 0.6, z + 0.04, "dark")
		part(lightsG, "Housing", CFrame.new(x, y + 0.6, z) * CFrame.Angles(0, 0, math.pi / 2), Vector3.new(1, 1.8, 1.8),
			"cladWhite", nil, Enum.PartType.Cylinder)
		local lens = part(lightsG, "Lens", CFrame.new(x, y + 0.08, z) * CFrame.Angles(0, 0, math.pi / 2),
			Vector3.new(0.06, 1.5, 1.5), "lamp", nil, Enum.PartType.Cylinder)
		addLight(lens, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 40, Angle = 120, Brightness = 1.1 })
	end
end

-- Back office block, mezzanine, stairs --------------------------------------------------------
do
	local off = group(inside, "Offices")
	local fz = -76                          -- front face of the office block
	local top = 11                          -- underside of the mezzanine deck
	local ox0, ox1 = -34, 40
	box(off, "Front", ox0, FLOOR, fz - 0.3, ox1, top, fz, "drywall")
	box(off, "Side", ox0, FLOOR, -D + T + L, ox0 + 0.3, top, fz, "drywall")
	box(off, "Side", ox1 - 0.3, FLOOR, -D + T + L, ox1, top, fz, "drywall")
	for _, x in ipairs({ -24, -4, 16, 32 }) do
		box(off, "Door", x - 1.7, FLOOR, fz, x + 1.7, FLOOR + 7.6, fz + 0.08, "doorDark")
		box(off, "DoorFrame", x - 1.85, FLOOR, fz, x - 1.7, FLOOR + 7.75, fz + 0.12, "trim")
		box(off, "DoorFrame", x + 1.7, FLOOR, fz, x + 1.85, FLOOR + 7.75, fz + 0.12, "trim")
		box(off, "DoorFrame", x - 1.85, FLOOR + 7.6, fz, x + 1.85, FLOOR + 7.75, fz + 0.12, "trim")
		box(off, "Handle", x + 1.1, 3.6, fz + 0.08, x + 1.4, 3.7, fz + 0.3, "rail")
		box(off, "DoorGlass", x - 0.4, 5, fz + 0.08, x + 0.4, 6.8, fz + 0.1, "pane")
	end
	for _, x in ipairs({ -14, 6, 24 }) do
		box(off, "Window", x - 2, 4, fz, x + 2, 7, fz + 0.06, "pane")
		box(off, "WindowFrame", x - 2.12, 3.88, fz, x + 2.12, 4, fz + 0.14, "trim")
		box(off, "WindowFrame", x - 2.12, 7, fz, x + 2.12, 7.12, fz + 0.14, "trim")
		box(off, "WindowFrame", x - 2.12, 4, fz, x - 2, 7, fz + 0.14, "trim")
		box(off, "WindowFrame", x + 2, 4, fz, x + 2.12, 7, fz + 0.14, "trim")
	end
	-- Mezzanine deck (over the offices and the storage bay beside the stairs).
	local dx0 = -45
	box(off, "Deck", dx0, top, -D + T + L, ox1, top + 0.5, fz, "tread")
	box(off, "DeckEdge", dx0, top - 0.7, fz - 0.05, ox1, top + 0.5, fz + 0.15, "steel")
	box(off, "DeckEdge", dx0 - 0.15, top - 0.7, -D + T + L, dx0 + 0.05, top + 0.5, fz, "steel")
	box(off, "DeckPost", dx0, FLOOR, fz - 0.5, dx0 + 0.5, top - 0.7, fz, "steel")
	box(off, "DeckPost", dx0, FLOOR, -D + 2, dx0 + 0.5, top - 0.7, -D + 2.5, "steel")
	local deckTop = top + 0.5
	railing(off, -40, fz + 0.1, ox1, fz + 0.1, deckTop)
	railing(off, dx0 + 0.1, fz, dx0 + 0.1, -D + T + L + 0.2, deckTop)
	railing(off, ox1 - 0.1, fz, ox1 - 0.1, -D + T + L + 0.2, deckTop)

	-- Stairs up to the deck, climbing towards the back.
	local sx0, sx1 = dx0, -40
	local z0, z1 = -56, fz
	local steps = 17
	local rise = (deckTop - FLOOR) / steps
	local run = (z0 - z1) / steps
	for i = 1, steps - 1 do
		local y = FLOOR + i * rise
		local zf = z0 - (i - 1) * run
		box(off, "Tread", sx0 + 0.25, y - 0.12, zf - run - 0.1, sx1 - 0.25, y, zf, "tread")
	end
	for _, x in ipairs({ sx0 + 0.12, sx1 - 0.12 }) do
		local a = Vector3.new(x, FLOOR + 0.3, z0 + 0.4)
		local b = Vector3.new(x, deckTop - 0.2, z1)
		local down = Vector3.new(0, -0.55, 0)
		bar(off, "Stringer", a + down, b + down, 0.2, 1, "steel")
		local up = Vector3.new(0, 3.3, 0)
		bar(off, "Handrail", a + up, b + up, 0.14, 0.14, "rail")
		bar(off, "MidRail", a + up * 0.5, b + up * 0.5, 0.08, 0.08, "rail")
		for t = 0, 1, 0.25 do
			local p = a:Lerp(b, t)
			box(off, "RailPost", x - 0.08, p.Y, p.Z - 0.08, x + 0.08, p.Y + 3.3, p.Z + 0.08, "rail")
		end
	end
end

-------------------------------------------------------------------------------

hangar.PrimaryPart = floor
hangar.WorldPivot = ORIGIN_CF
hangar.Parent = workspace

-- Union each gable's strips into one part (needs to be in Workspace first).
for _, strips in ipairs(unionQueue) do
	local first = table.remove(strips, 1)
	local ok, u = pcall(function()
		return first:UnionAsync(strips)
	end)
	if ok and u then
		u.Name = first.Name
		u.Anchored = true
		u.UsePartColor = true
		u.Parent = first.Parent
		first:Destroy()
		for _, p in ipairs(strips) do
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
		ChangeHistoryService:SetWaypoint("Build Hangar")
	end)
end

local count = 0
for _, d in ipairs(hangar:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[Hangar] Built Workspace.Hangar: %d parts."):format(count))
