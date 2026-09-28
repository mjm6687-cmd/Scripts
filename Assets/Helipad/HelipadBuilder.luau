--[[
	HELIPAD BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	--------------------------------------------------------------------
	Builds a detailed helipad as Workspace > Helipad, on the ground WHERE YOUR
	CAMERA IS POINTING, turned to face the way you're looking (snapped to 90
	degrees). Run it again to move it: it deletes the old one first. Ctrl+Z undoes.

	One pad (PAD_COUNT = 2 puts a second one alongside, like a flight line):
	  * concrete slab with bevelled edges, drainage grates along two sides
	  * green painted surface: white border, dashed inner line with edge ticks
	    and corner brackets, outer circle with amber dashes, the touchdown
	    circle with aiming marks, the H, tie-down points
	  * raised edge lights (green lenses) all round, glowing at night
	  * a lighting pole with two floodlights aimed at the pad
	  * a striped, lit windsock
	Parts only; uses your MaterialVariants. Colours are at the top.
]]

local PAD_COUNT = 2           -- 1 or 2
local PAD_SPACING = 96        -- centre to centre, studs, when there are 2
local USE_CAMERA = true       -- false = build at ORIGIN instead
local ORIGIN = Vector3.new(0, 0, 0)
local LIGHT_POLE = true
local WINDSOCK = true

local PAD_GREEN = Color3.fromRGB(58, 104, 80)
local LINE_WHITE = Color3.fromRGB(228, 228, 222)
local LINE_AMBER = Color3.fromRGB(232, 172, 40)

-------------------------------------------------------------------------------

local M = Enum.Material
local MAT = {
	slab    = { M.Concrete, "Large Concrete Tile", Color3.fromRGB(128, 128, 124) },
	surface = { M.Concrete, "Flat Concrete Dark",  PAD_GREEN },
	metal   = { M.Metal,    "Scuffed Iron",        Color3.fromRGB(88, 90, 88) },
	grate   = { M.Metal,    "Metal Grate",         Color3.fromRGB(70, 72, 70) },
	pole    = { M.Metal,    "Scuffed Iron",        Color3.fromRGB(150, 152, 150) },
	dark    = { M.SmoothPlastic, nil,              Color3.fromRGB(34, 36, 36) },
	white   = { M.SmoothPlastic, nil,              LINE_WHITE, 0, true },
	amber   = { M.SmoothPlastic, nil,              LINE_AMBER, 0, true },
	lensG   = { M.Neon,     nil,                   Color3.fromRGB(90, 255, 140) },
	lensW   = { M.Neon,     nil,                   Color3.fromRGB(255, 246, 225) },
	sockO   = { M.Fabric,   nil,                   Color3.fromRGB(235, 110, 30) },
	sockW   = { M.Fabric,   nil,                   Color3.fromRGB(235, 235, 230) },
}

-- Heights: slab top, painted surface top, line top.
local SLAB_TOP = 1
local SURF = SLAB_TOP + 0.05
local LINE = SURF + 0.04

-------------------------------------------------------------------------------

local old = workspace:FindFirstChild("Helipad")
if old then
	old:Destroy()
end

-- Where: the ground under the middle of the screen, facing the camera's way.
local BASE_CF = CFrame.new(ORIGIN)
if USE_CAMERA and workspace.CurrentCamera then
	local cam = workspace.CurrentCamera.CFrame
	local hit = workspace:Raycast(cam.Position, cam.LookVector * 4000)
	local look = cam.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	yaw = math.floor(yaw / (math.pi / 2) + 0.5) * (math.pi / 2)
	local pos = hit and hit.Position or (cam.Position + look * 150) * Vector3.new(1, 0, 1)
	BASE_CF = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local ORIGIN_CF = BASE_CF

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

local function B(parent, name, x0, y0, z0, x1, y1, z1, mat, color)
	return mk(parent, "Part", name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat, color)
end

-- Upright cylinder standing on y0.
local function cyl(parent, name, x, y0, z, h, d, mat, color)
	local p = mk(parent, "Part", name, CFrame.new(x, y0 + h / 2, z) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(h, d, d), mat, color)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Painted arc segments round a circle. keep(i) decides which of the n segments
-- are drawn (nil = all), so the same helper does solid and dashed rings.
local function ring(parent, name, cx, cz, r, n, w, mat, keep, lengthScale)
	local seg = (2 * math.pi * r / n) * (lengthScale or 1) + (keep and 0 or 0.12)
	for i = 0, n - 1 do
		if not keep or keep(i) then
			local a = (i + 0.5) / n * 2 * math.pi
			mk(parent, "Part", name, CFrame.new(cx + math.cos(a) * r, (SURF + LINE) / 2, cz + math.sin(a) * r)
				* CFrame.Angles(0, -a, 0), Vector3.new(w, LINE - SURF, seg), mat)
		end
	end
end

-- Flat painted strip between two points on the pad (x, z).
local function stripe(parent, name, x0, z0, x1, z1, w, mat)
	local a = Vector3.new(x0, 0, z0)
	local b = Vector3.new(x1, 0, z1)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	return mk(parent, "Part", name, CFrame.lookAt(Vector3.new(mid.X, (SURF + LINE) / 2, mid.Z),
		Vector3.new(b.X, (SURF + LINE) / 2, b.Z)), Vector3.new(w, LINE - SURF, len), mat)
end

local function model(parent, name)
	local m = Instance.new("Model")
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

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Helipad")
end)

local root = Instance.new("Model")
root.Name = "Helipad"

local H = 38      -- half-size of the painted square
local S = 41      -- half-size of the slab top
local E = 43      -- half-size of the slab at the ground (after the bevel)

local function buildPad(name, cx)
	local pad = model(root, name)
	local slabF = model(pad, "Slab")
	local paint = model(pad, "Markings")
	local lights = model(pad, "Lights")

	-- Slab: flat top, bevelled edges, low corner blocks.
	local slab = B(slabF, "Slab", cx - S, 0, -S, cx + S, SLAB_TOP, S, "slab")
	local bevelLen = math.sqrt((E - S) ^ 2 + SLAB_TOP ^ 2)
	local bevelAng = math.atan2(SLAB_TOP, E - S)
	local t = 0.6
	for k = 0, 3 do
		local side = CFrame.new(cx, 0, 0) * CFrame.Angles(0, k * math.pi / 2, 0)
		-- Top line of the bevel runs from (z=-E, y=0) up to (z=-S, y=SLAB_TOP).
		local up = Vector3.new(0, math.cos(bevelAng), -math.sin(bevelAng))
		local mid = Vector3.new(0, SLAB_TOP / 2, -(E + S) / 2) - up * (t / 2)
		mk(slabF, "Part", "Bevel", side * CFrame.new(mid) * CFrame.Angles(-bevelAng, 0, 0),
			Vector3.new(2 * S, t, bevelLen), "slab")
	end
	for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		B(slabF, "Corner", cx + c[1] * S, 0, c[2] * S, cx + c[1] * E, SLAB_TOP * 0.5, c[2] * E, "slab")
	end
	-- Drainage grates along the north and south edges of the slab top.
	for _, sz in ipairs({ -1, 1 }) do
		B(slabF, "Drain", cx - H, SLAB_TOP - 0.3, sz * (H + 1), cx + H, SLAB_TOP + 0.02, sz * (H + 2.4), "grate")
	end

	-- Green surface.
	B(paint, "Surface", cx - H, SLAB_TOP, -H, cx + H, SURF, H, "surface")

	-- Border: solid white line just inside the edge.
	local b0, b1 = H - 2.6, H - 1.2
	stripe(paint, "Border", cx - b1, -(b0 + b1) / 2, cx + b1, -(b0 + b1) / 2, b1 - b0, "white")
	stripe(paint, "Border", cx - b1, (b0 + b1) / 2, cx + b1, (b0 + b1) / 2, b1 - b0, "white")
	stripe(paint, "Border", cx - (b0 + b1) / 2, -b0, cx - (b0 + b1) / 2, b0, b1 - b0, "white")
	stripe(paint, "Border", cx + (b0 + b1) / 2, -b0, cx + (b0 + b1) / 2, b0, b1 - b0, "white")

	-- Inner dashed square, ticks out to the border, and corner brackets.
	local r = H - 8
	for k = 0, 3 do
		-- Work along the north edge and rotate it round for the other three.
		local rot = CFrame.Angles(0, k * math.pi / 2, 0)
		local function P(x, z)
			local v = rot * Vector3.new(x, 0, z)
			return cx + v.X, v.Z
		end
		for x = -r + 10, r - 14, 7 do
			local ax, az = P(x, -r)
			local bx, bz = P(x + 4, -r)
			stripe(paint, "Dash", ax, az, bx, bz, 0.7, "white")
		end
		for x = -r + 12, r - 12, 12 do
			local ax, az = P(x, -r - 1.5)
			local bx, bz = P(x, -b0 + 1)
			stripe(paint, "Tick", ax, az, bx, bz, 0.6, "white")
		end
		-- Corner bracket at this edge's west end.
		local ax, az = P(-r, -r)
		local bx, bz = P(-r + 7, -r)
		stripe(paint, "Bracket", ax, az, bx, bz, 1, "white")
		bx, bz = P(-r, -r + 7)
		stripe(paint, "Bracket", ax, az, bx, bz, 1, "white")
		-- Amber hold-short dashes along the outside of the border.
		for x = -H + 5, H - 8, 9 do
			local cx0, cz0 = P(x, -H + 0.5)
			local cx1, cz1 = P(x + 3, -H + 0.5)
			stripe(paint, "Amber", cx0, cz0, cx1, cz1, 0.6, "amber")
		end
	end

	-- Circles: outer (white), amber dashes just outside it, touchdown circle,
	-- aiming dashes between them.
	ring(paint, "OuterCircle", cx, 0, 29, 96, 0.9, "white")
	ring(paint, "AmberRing", cx, 0, 31.2, 72, 0.7, "amber", function(i)
		return i % 2 == 0
	end, 0.9)
	ring(paint, "TouchdownCircle", cx, 0, 19, 72, 2, "white")
	ring(paint, "AimingMark", cx, 0, 24, 16, 1.1, "white", function(i)
		return i % 2 == 1
	end, 0.55)

	-- H: 3-wide strokes, 18 tall.
	stripe(paint, "H", cx - 7, -9, cx - 7, 9, 3, "white")
	stripe(paint, "H", cx + 7, -9, cx + 7, 9, 3, "white")
	stripe(paint, "H", cx - 5.5, 0, cx + 5.5, 0, 3, "white")

	-- Tie-down points (flush steel rings).
	for _, c in ipairs({ { -12, -12 }, { 12, -12 }, { -12, 12 }, { 12, 12 } }) do
		cyl(paint, "TieDown", cx + c[1], SLAB_TOP, c[2], SURF - SLAB_TOP + 0.03, 1.4, "metal")
		cyl(paint, "TieDownEye", cx + c[1], SURF, c[2], 0.12, 0.7, "dark")
	end

	-- Edge lights: 8 a side, raised fixtures with green lenses.
	local n = 8
	local step = (2 * (H - 1.9)) / n
	for k = 0, 3 do
		local rot = CFrame.Angles(0, k * math.pi / 2, 0)
		for i = 0, n - 1 do
			local v = rot * Vector3.new(-(H - 1.9) + i * step, 0, -(H - 1.9))
			local x, z = cx + v.X, v.Z
			cyl(lights, "LightBase", x, LINE, z, 0.35, 1.3, "metal")
			local lens = cyl(lights, "LightLens", x, LINE + 0.35, z, 0.3, 0.8, "lensG")
			if i == 0 then
				addLight(lens, "PointLight", { Range = 10, Brightness = 1, Color = MAT.lensG[3] })
			end
		end
	end

	-- Lighting pole at the south-east corner, two heads aimed at the middle.
	if LIGHT_POLE then
		local pm = model(pad, "LightPole")
		local px, pz = cx + E + 3, E + 3
		B(pm, "Footing", px - 1.5, 0, pz - 1.5, px + 1.5, 1.2, pz + 1.5, "slab")
		cyl(pm, "Pole", px, 1.2, pz, 34, 0.9, "pole")
		B(pm, "Crossbar", px - 3, 34.2, pz - 0.3, px + 3, 34.8, pz + 0.3, "pole")
		for _, dx in ipairs({ -2.2, 2.2 }) do
			local head = Vector3.new(px + dx, 33.4, pz)
			local aim = Vector3.new(cx, 0, 0)
			local hp = mk(pm, "Part", "Head", CFrame.lookAt(head, aim), Vector3.new(2.2, 1.2, 1), "dark")
			mk(pm, "Part", "Lens", CFrame.lookAt(head, aim) * CFrame.new(0, 0, -0.55), Vector3.new(1.9, 0.9, 0.1), "lensW")
			addLight(hp, "SpotLight", { Face = Enum.NormalId.Front, Range = 70, Angle = 70, Brightness = 2.4,
				Color = MAT.lensW[3] })
		end
	end

	pad.PrimaryPart = slab
	return pad
end

local offsets = PAD_COUNT >= 2 and { -PAD_SPACING / 2, PAD_SPACING / 2 } or { 0 }
for i, x in ipairs(offsets) do
	buildPad("Pad " .. i, x)
end

-- Windsock at the north-west corner of the first pad.
if WINDSOCK then
	local ws = model(root, "Windsock")
	local wx, wz = offsets[1] - E - 5, -E - 5
	B(ws, "Footing", wx - 1.2, 0, wz - 1.2, wx + 1.2, 1, wz + 1.2, "slab")
	cyl(ws, "Mast", wx, 1, wz, 16, 0.5, "pole")
	cyl(ws, "Swivel", wx, 17, wz, 0.8, 0.8, "metal")
	-- Sock: five tapering bands, alternating orange and white, blowing east.
	local x = wx + 0.6
	for i = 0, 4 do
		local d = 1.9 - i * 0.28
		local seg = mk(ws, "Part", "Sock", CFrame.new(x + 0.8, 16.8 - i * 0.12, wz), Vector3.new(1.6, d, d),
			i % 2 == 0 and "sockO" or "sockW")
		seg.Shape = Enum.PartType.Cylinder
		x += 1.6
	end
	local lamp = cyl(ws, "MastLight", wx, 17.8, wz, 0.4, 0.6, "lensW")
	addLight(lamp, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 12, Angle = 60, Brightness = 1.5 })
end

root.WorldPivot = ORIGIN_CF
root.Parent = workspace

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build Helipad")
	end)
end

local count = 0
for _, d in ipairs(root:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[Helipad] Built Workspace.Helipad: %d pad(s), %d parts."):format(#offsets, count))
