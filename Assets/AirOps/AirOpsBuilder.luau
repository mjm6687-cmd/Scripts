--[[
	AIR OPS COMMAND BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	----------------------------------------------------------------------------
	HOW TO USE
	  1. Select your blockout part(s) for the building (one or several; a Model
	     works too).
	  2. Move the camera so you're looking at the side that should be the FRONT
	     (the entrance and the control cab's big windows face you).
	  3. Run this. The building is fitted to the blockout's footprint and sits on
	     its bottom; the blockout is moved to ServerStorage > Blockouts (not
	     deleted). Ctrl+Z undoes everything.
	  Nothing selected: it builds where the camera points, at the default size.
	  Run it again with the blockout (now in ServerStorage) re-selected, or just
	  re-run with nothing selected to rebuild in place... see ORIGIN notes below.

	WHAT IT BUILDS (Workspace > AirOpsCommand)
	  * a 2-storey operations block (left) and a 1-storey entrance wing (right),
	    in Vertical Concrete Panels, with real window openings, concrete fins,
	    floor bands, parapets with metal coping, MetalRoof0 roofs
	  * a glazed control cab on the roof, glass leaning out on three sides,
	    consoles, screens and chairs inside, beacon and antenna on top
	  * entrance: glass doors (walk-through), canopy with downlights and an
	    "AIR OPS COMMAND" sign
	  * steel switchback stair outside: ground -> first floor door -> roof
	  * lit interiors (lobby with desk, ops floor, first floor desks), rooftop
	    AC units, antenna mast, and a MESH_SatDish placeholder
]]

local DEFAULT_LENGTH, DEFAULT_DEPTH, DEFAULT_HEIGHT = 64, 36, 26  -- when nothing is selected
local MOVE_BLOCKOUT = true            -- move the selected blockout to ServerStorage > Blockouts
local SIGN_TEXT = "AIR OPS COMMAND"

local WALL = { Enum.Material.Concrete, "Vertical Concrete Panels", Color3.fromRGB(136, 136, 136) }
local ROOF = { Enum.Material.Metal, "MetalRoof0", Color3.fromRGB(120, 120, 120) }

-------------------------------------------------------------------------------

local M = Enum.Material
local MAT = {
	wall     = WALL,
	roof     = ROOF,
	band     = { M.Concrete, "Vertical Concrete Panels", Color3.fromRGB(118, 118, 118) },
	trim     = { M.Metal,    "Metal",                Color3.fromRGB(74, 78, 82) },
	steel    = { M.Metal,    "Metal",                Color3.fromRGB(58, 62, 68) },
	rail     = { M.Metal,    "Metal",                Color3.fromRGB(150, 154, 156) },
	tread    = { M.DiamondPlate, "DiamondPlate",     Color3.fromRGB(128, 130, 130) },
	floor    = { M.Concrete, "Epoxy Painted Floor",  Color3.fromRGB(150, 154, 154) },
	drywall  = { M.Plastic,  "DryWall",              Color3.fromRGB(226, 226, 222) },
	desk     = { M.Metal,    "Metal Panel 004",      Color3.fromRGB(96, 100, 104) },
	vent     = { M.Plastic,  "Metal Ventilation 1",  Color3.fromRGB(150, 150, 150) },
	glass    = { M.Glass,    nil,                    Color3.fromRGB(150, 176, 188), 0.55 },
	doorGlass= { M.Glass,    nil,                    Color3.fromRGB(150, 176, 188), 0.6, "nocollide" },
	doorLeaf = { M.Metal,    "Metal Panel 004",      Color3.fromRGB(90, 98, 106), 0, "nocollide" },
	dark     = { M.SmoothPlastic, nil,               Color3.fromRGB(30, 32, 34) },
	chair    = { M.Fabric,   nil,                    Color3.fromRGB(40, 44, 46) },
	lamp     = { M.Neon,     nil,                    Color3.fromRGB(255, 246, 228) },
	screen   = { M.Neon,     nil,                    Color3.fromRGB(70, 150, 200) },
	red      = { M.Neon,     nil,                    Color3.fromRGB(255, 60, 50) },
	placeholder = { M.Plastic, "Baseplate Tile",     Color3.fromRGB(170, 90, 230) },
}

-------------------------------------------------------------------------------
-- Where and how big: from the selection, or the camera.
-------------------------------------------------------------------------------

local Selection = game:GetService("Selection")
local camCF = workspace.CurrentCamera and workspace.CurrentCamera.CFrame

local selected = {}
local parts = {}
for _, inst in ipairs(Selection:Get()) do
	if inst:IsA("BasePart") then
		table.insert(selected, inst)
		table.insert(parts, inst)
	elseif inst:IsA("Model") or inst:IsA("Folder") then
		table.insert(selected, inst)
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
	end
end

local BASE_CF, LEN, DEP, HGT
if #parts > 0 then
	-- Frame: the biggest part's yaw.
	local big, bigVol = parts[1], 0
	for _, p in ipairs(parts) do
		local v = p.Size.X * p.Size.Y * p.Size.Z
		if v > bigVol then
			big, bigVol = p, v
		end
	end
	local lv = big.CFrame.LookVector
	local yaw = math.atan2(-lv.X, -lv.Z)
	local rot = CFrame.Angles(0, yaw, 0)
	local R, U, Bk = rot.RightVector, Vector3.yAxis, -rot.LookVector
	local minV, maxV = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(parts) do
		for _, sx in ipairs({ -0.5, 0.5 }) do
			for _, sy in ipairs({ -0.5, 0.5 }) do
				for _, sz in ipairs({ -0.5, 0.5 }) do
					local w = p.CFrame * Vector3.new(p.Size.X * sx, p.Size.Y * sy, p.Size.Z * sz)
					local l = Vector3.new(w:Dot(R), w:Dot(U), w:Dot(Bk))
					minV = Vector3.new(math.min(minV.X, l.X), math.min(minV.Y, l.Y), math.min(minV.Z, l.Z))
					maxV = Vector3.new(math.max(maxV.X, l.X), math.max(maxV.Y, l.Y), math.max(maxV.Z, l.Z))
				end
			end
		end
	end
	local c = (minV + maxV) / 2
	local center = R * c.X + Bk * c.Z
	local ext = maxV - minV
	LEN, DEP, HGT = ext.X, ext.Z, ext.Y
	-- Front = the side facing the camera.
	local extra = 0
	if camCF then
		local toCam = camCF.Position - Vector3.new(center.X, 0, center.Z)
		local dx, dz = toCam:Dot(R) / (LEN / 2), toCam:Dot(Bk) / (DEP / 2)
		if math.abs(dz) >= math.abs(dx) then
			extra = dz >= 0 and 0 or math.pi
		else
			extra = dx >= 0 and math.pi / 2 or -math.pi / 2
			LEN, DEP = DEP, LEN
		end
	end
	BASE_CF = CFrame.new(center.X, minV.Y, center.Z) * rot * CFrame.Angles(0, extra, 0)
else
	LEN, DEP, HGT = DEFAULT_LENGTH, DEFAULT_DEPTH, DEFAULT_HEIGHT
	BASE_CF = CFrame.new()
	if camCF then
		local hit = workspace:Raycast(camCF.Position, camCF.LookVector * 4000)
		local look = camCF.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		yaw = math.floor(yaw / (math.pi / 2) + 0.5) * (math.pi / 2)
		local pos = hit and hit.Position or (camCF.Position + look * 150) * Vector3.new(1, 0, 1)
		BASE_CF = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	end
end

if LEN < 40 or DEP < 24 then
	warn(("[AirOps] Footprint %.0f x %.0f is small; using at least 40 x 24."):format(LEN, DEP))
	LEN, DEP = math.max(LEN, 40), math.max(DEP, 24)
end

-------------------------------------------------------------------------------
-- Helpers (all coordinates are local: X along the front, +Z out of the front).
-------------------------------------------------------------------------------

local function part(parent, name, cf, size, mat, shape)
	local m = MAT[mat]
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = BASE_CF * cf
	p.Material = m[1]
	if m[2] then
		p.MaterialVariant = m[2]
	end
	p.Color = m[3]
	p.Transparency = m[4] or 0
	if m[5] == "nocollide" then
		p.CanCollide = false
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function box(parent, name, x0, y0, z0, x1, y1, z1, mat)
	return part(parent, name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat)
end

local function bar(parent, name, a, b, sx, sy, mat)
	-- A vertical bar needs a different "up" hint, or lookAt has no sideways axis.
	local up = math.abs((b - a).Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
	return part(parent, name, CFrame.lookAt((a + b) / 2, b, up), Vector3.new(sx, sy, (b - a).Magnitude), mat)
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
	local g = Instance.new("Model")
	g.Name = name
	g.Parent = parent
	return g
end

-- A straight wall from a to b (ground points), y0..y1, thickness t, with
-- rectangular openings { u0, u1, v0, v1, kind } (u along the wall from a,
-- v = height). kind "window" gets glass, frame, mullions and a sill; "door"
-- gets a frame and walk-through glass leaves; "opening" stays empty.
-- The wall's OUTSIDE is the side dir:Cross(up) points to: for a->b along +X
-- that's +Z. Window sills stick out on that side.
local function wall(parent, name, a, b, y0, y1, t, openings)
	local dir = (b - a).Unit
	local L = (b - a).Magnitude
	local nrm = dir:Cross(Vector3.yAxis) -- outward
	local base = CFrame.fromMatrix(Vector3.zero, dir, Vector3.yAxis, dir:Cross(Vector3.yAxis))
	local function at(u, v, w)
		return a + dir * u + Vector3.new(0, v, 0) + nrm * w
	end
	local function piece(u0, u1, v0, v1, mat, depth, off)
		if u1 - u0 < 0.01 or v1 - v0 < 0.01 then
			return nil
		end
		local c = at((u0 + u1) / 2, (v0 + v1) / 2, off or 0)
		return part(parent, name, CFrame.new(c) * base, Vector3.new(u1 - u0, v1 - v0, depth or t), mat or "wall")
	end
	-- Openings that share the same u range are stacked (e.g. a window on each
	-- floor): the wall between them is built once per column.
	table.sort(openings, function(p, q)
		if p[1] ~= q[1] then
			return p[1] < q[1]
		end
		return p[3] < q[3]
	end)
	local columns = {}
	for _, o in ipairs(openings) do
		local last = columns[#columns]
		if last and math.abs(last.u0 - o[1]) < 0.01 and math.abs(last.u1 - o[2]) < 0.01 then
			table.insert(last.list, o)
		else
			table.insert(columns, { u0 = o[1], u1 = o[2], list = { o } })
		end
	end
	local cursor = 0
	for _, col in ipairs(columns) do
		piece(cursor, col.u0, y0, y1)
		local v = y0
		for _, o in ipairs(col.list) do
			piece(col.u0, col.u1, v, o[3])
			v = o[4]
		end
		piece(col.u0, col.u1, v, y1)
		cursor = col.u1
	end
	piece(cursor, L, y0, y1)
	for _, o in ipairs(openings) do
		local u0, u1, v0, v1, kind = o[1], o[2], o[3], o[4], o[5]
		local ft = 0.25 -- frame member
		if kind == "window" then
			piece(u0, u1, v0 + 0.05, v1 - 0.05, "glass", 0.12, 0)
			piece(u0, u1, v0, v0 + ft, "trim", t * 0.6, 0)
			piece(u0, u1, v1 - ft, v1, "trim", t * 0.6, 0)
			piece(u0, u0 + ft, v0, v1, "trim", t * 0.6, 0)
			piece(u1 - ft, u1, v0, v1, "trim", t * 0.6, 0)
			local n = math.max(1, math.floor((u1 - u0) / 4 + 0.5))
			for i = 1, n - 1 do
				local u = u0 + (u1 - u0) * i / n
				piece(u - 0.08, u + 0.08, v0, v1, "trim", t * 0.5, 0)
			end
			-- Sill: thin, sticks out a little.
			piece(u0 - 0.3, u1 + 0.3, v0 - 0.3, v0, "band", t + 0.6, 0.3)
		elseif kind == "door" then
			piece(u0, u0 + ft, v0, v1, "trim", t, 0)
			piece(u1 - ft, u1, v0, v1, "trim", t, 0)
			piece(u0, u1, v1 - ft, v1, "trim", t, 0)
			local mid = (u0 + u1) / 2
			if u1 - u0 > 5 then
				piece(u0 + ft, mid - 0.05, v0, v1 - ft, "doorGlass", 0.15, 0)
				piece(mid + 0.05, u1 - ft, v0, v1 - ft, "doorGlass", 0.15, 0)
				piece(mid - 0.3, mid - 0.2, v0 + 3, v0 + 5.5, "rail", 0.5, 0)
				piece(mid + 0.2, mid + 0.3, v0 + 3, v0 + 5.5, "rail", 0.5, 0)
			else
				piece(u0 + ft, u1 - ft, v0, v1 - ft, "doorLeaf", 0.15, 0)
				piece(u1 - 0.9, u1 - 0.6, v0 + 3.4, v0 + 3.6, "rail", 0.6, 0)
			end
		end
	end
end

-- A stair flight between two ground-plan points at x0..x1 (width), climbing
-- from (zA, yA) to (zB, yB); treads, stringers, handrails on both sides.
local function flight(parent, x0, x1, zA, yA, zB, yB)
	local n = math.ceil((yB - yA) / 0.72)
	local rise = (yB - yA) / n
	local run = (zB - zA) / n
	for i = 1, n - 1 do
		local y = yA + rise * i
		local z = zA + run * (i - 1)
		box(parent, "Tread", x0 + 0.2, y - 0.12, z, x1 - 0.2, y, z + run * 1.05, "tread")
	end
	for _, x in ipairs({ x0 + 0.1, x1 - 0.1 }) do
		local a, b = Vector3.new(x, yA, zA), Vector3.new(x, yB, zB)
		local down = Vector3.new(0, -0.5, 0)
		bar(parent, "Stringer", a + down, b + down, 0.18, 0.9, "steel")
		local up = Vector3.new(0, 3.3, 0)
		bar(parent, "Handrail", a + up, b + up, 0.13, 0.13, "rail")
		bar(parent, "MidRail", a + up * 0.5, b + up * 0.5, 0.08, 0.08, "rail")
		for t = 0, 1, 0.34 do
			local p = a:Lerp(b, t)
			box(parent, "RailPost", x - 0.07, p.Y, p.Z - 0.07, x + 0.07, p.Y + 3.3, p.Z + 0.07, "rail")
		end
	end
end

local function railing(parent, a, b)
	local len = (b - a).Magnitude
	local n = math.max(1, math.ceil(len / 4.5))
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		box(parent, "Post", p.X - 0.08, p.Y, p.Z - 0.08, p.X + 0.08, p.Y + 3.4, p.Z + 0.08, "rail")
	end
	local up = Vector3.new(0, 3.4, 0)
	bar(parent, "TopRail", a + up, b + up, 0.14, 0.14, "rail")
	bar(parent, "MidRail", a + up * 0.5, b + up * 0.5, 0.08, 0.08, "rail")
end

local function wallLight(parent, pos, facing)
	-- facing: outward unit vector (local)
	local cf = CFrame.lookAt(pos, pos + facing)
	part(parent, "WallLight", cf * CFrame.new(0, 0, -0.25), Vector3.new(1, 0.6, 0.5), "dark")
	local lens = part(parent, "WallLightLens", cf * CFrame.new(0, -0.32, -0.3), Vector3.new(0.8, 0.06, 0.4), "lamp")
	addLight(lens, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 16, Angle = 110, Brightness = 1.3 })
end

local function ceilingLight(parent, x, y, z, w, d)
	local p = box(parent, "CeilingLight", x - w / 2, y - 0.08, z - d / 2, x + w / 2, y, z + d / 2, "lamp")
	addLight(p, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 16, Angle = 120, Brightness = 0.9 })
end

local function desk(parent, x, z, facing)
	-- facing +1: the person sits on the -Z side looking +Z (towards the front)
	local g = group(parent, "Desk")
	box(g, "Top", x - 2.4, 3, z - 1.2, x + 2.4, 3.2, z + 1.2, "desk")
	box(g, "Leg", x - 2.4, 0, z - 1.2, x - 2.2, 3, z + 1.2, "desk")
	box(g, "Leg", x + 2.2, 0, z - 1.2, x + 2.4, 3, z + 1.2, "desk")
	local sz = z + facing * 0.7
	box(g, "Monitor", x - 1, 3.4, sz - 0.08, x + 1, 4.7, sz + 0.08, "dark")
	box(g, "Screen", x - 0.9, 3.5, sz - facing * 0.1 - 0.02, x + 0.9, 4.6, sz - facing * 0.1 + 0.02, "screen")
	box(g, "MonitorStand", x - 0.1, 3.2, sz - 0.1, x + 0.1, 3.4, sz + 0.1, "dark")
	local cz = z - facing * 2.2
	box(g, "Seat", x - 0.9, 1.8, cz - 0.9, x + 0.9, 2.1, cz + 0.9, "chair")
	box(g, "Back", x - 0.9, 2.1, cz - facing * 0.9 - 0.15, x + 0.9, 4.6, cz - facing * 0.9 + 0.15, "chair")
	box(g, "Post", x - 0.12, 0, cz - 0.12, x + 0.12, 1.8, cz + 0.12, "steel")
end

-------------------------------------------------------------------------------
-- Dimensions
-------------------------------------------------------------------------------

local SH = math.clamp(math.floor(HGT / 2 + 0.5), 10, 13)  -- storey height
local T = 1                                                 -- wall thickness
local X0, X1 = -LEN / 2, LEN / 2
local ZF, ZB = DEP / 2, -DEP / 2
local MX = X0 + math.floor(LEN * 0.58 + 0.5)                -- main block / wing split
local HM = SH * 2                                           -- main block wall height
local FLOOR = 0.3

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Air Ops Command")
end)

local old = workspace:FindFirstChild("AirOpsCommand")
if old then
	old:Destroy()
end

local bld = Instance.new("Model")
bld.Name = "AirOpsCommand"
local shell = group(bld, "Shell")
local cab = group(bld, "ControlCab")
local stairs = group(bld, "Stairs")
local inside = group(bld, "Interior")
local roofG = group(bld, "Rooftop")
local ext = group(bld, "Exterior")

-- Floors and roofs ----------------------------------------------------------------
local ground = box(shell, "GroundFloor", X0, 0, ZB, X1, FLOOR, ZF, "floor")
box(shell, "FirstFloor", X0 + T, SH - 0.4, ZB + T, MX - T / 2, SH + 0.4, ZF - T, "floor")
box(shell, "MainRoof", X0, HM - 0.2, ZB, MX, HM + 0.6, ZF, "roof")
box(shell, "WingRoof", MX, SH - 0.2, ZB, X1, SH + 0.6, ZF, "roof")

-- Main block walls ----------------------------------------------------------------
local mainLen = MX - X0
local bays = math.max(2, math.floor((mainLen - 2) / 8))
local bayW = (mainLen - 2) / bays
do
	-- Front: a window per bay on both floors, fins between the bays.
	local open = {}
	for i = 0, bays - 1 do
		local u0 = 1 + i * bayW + 1.1
		local u1 = 1 + (i + 1) * bayW - 1.1
		table.insert(open, { u0, u1, 3.5, 8.5, "window" })
		table.insert(open, { u0, u1, SH + 2.5, SH + 9.5, "window" })
	end
	wall(shell, "Wall", Vector3.new(X0, 0, ZF - T / 2), Vector3.new(MX, 0, ZF - T / 2), 0, HM, T, open)
	for i = 0, bays do
		local x = X0 + 1 + i * bayW
		box(shell, "Fin", x - 0.3, 0.5, ZF, x + 0.3, HM + 0.6, ZF + 1.2, "band")
	end
	-- Back: every other bay.
	open = {}
	for i = 0, bays - 1, 2 do
		local u0 = 1 + i * bayW + 1.6
		local u1 = 1 + (i + 1) * bayW - 1.6
		table.insert(open, { u0, u1, 4, 8, "window" })
		table.insert(open, { u0, u1, SH + 3, SH + 8, "window" })
	end
	wall(shell, "Wall", Vector3.new(MX, 0, ZB + T / 2), Vector3.new(X0, 0, ZB + T / 2), 0, HM, T, open)
	-- Left side: first-floor door onto the stair landing (at the back), windows.
	wall(shell, "Wall", Vector3.new(X0 + T / 2, 0, ZB), Vector3.new(X0 + T / 2, 0, ZF), 0, HM, T, {
		{ 2, 5.6, SH + 0.4, SH + 8.4, "door" },
		{ DEP / 2 - 3, DEP / 2 + 3, 4, 8, "window" },
	})
	-- Right side: inside wall to the wing (doorway) below, outside wall above.
	wall(shell, "Wall", Vector3.new(MX - T / 2, 0, ZF - T), Vector3.new(MX - T / 2, 0, ZB + T), 0, SH, T, {
		{ DEP / 2 - 3, DEP / 2 + 3, 0, 8.5, "opening" },
	})
	wall(shell, "Wall", Vector3.new(MX - T / 2, 0, ZF), Vector3.new(MX - T / 2, 0, ZB), SH, HM, T, {
		{ DEP / 2 - 4, DEP / 2 + 4, SH + 3, SH + 8, "window" },
	})
	-- Floor band round the main block.
	box(shell, "FloorBand", X0 - 0.3, SH - 0.4, ZF, MX, SH + 0.5, ZF + 0.3, "band")
	box(shell, "FloorBand", X0 - 0.3, SH - 0.4, ZB - 0.3, MX, SH + 0.5, ZB, "band")
	box(shell, "FloorBand", X0 - 0.3, SH - 0.4, ZB, X0, SH + 0.5, ZF, "band")
end

-- Wing walls --------------------------------------------------------------------------
local wingMid = (MX + X1) / 2
do
	local wingLen = X1 - MX
	local du = wingMid - MX
	local open = { { du - 4, du + 4, FLOOR, 9, "door" } }
	if wingLen > 22 then
		table.insert(open, { 1.5, du - 6, 3.5, 8.5, "window" })
		table.insert(open, { du + 6, wingLen - 1.5, 3.5, 8.5, "window" })
	end
	wall(shell, "Wall", Vector3.new(MX, 0, ZF - T / 2), Vector3.new(X1, 0, ZF - T / 2), 0, SH, T, open)
	wall(shell, "Wall", Vector3.new(X1, 0, ZB + T / 2), Vector3.new(MX, 0, ZB + T / 2), 0, SH, T, {
		{ wingLen / 2 - 1.8, wingLen / 2 + 1.8, FLOOR, 8, "door" },
	})
	wall(shell, "Wall", Vector3.new(X1 - T / 2, 0, ZF), Vector3.new(X1 - T / 2, 0, ZB), 0, SH, T, {
		{ 4, DEP / 2 - 2, 3.5, 8.5, "window" },
		{ DEP / 2 + 2, DEP - 4, 3.5, 8.5, "window" },
	})
end

-- Parapets with metal coping ----------------------------------------------------------
local function parapet(x0, z0, x1, z1, y)
	box(shell, "Parapet", x0, y, z0, x1, y + 1.4, z1, "wall")
	local pad = 0.12
	box(shell, "Coping", math.min(x0, x1) - pad, y + 1.4, math.min(z0, z1) - pad, math.max(x0, x1) + pad, y + 1.55,
		math.max(z0, z1) + pad, "trim")
end
local PT = 0.6
local roofTop = HM + 0.6
parapet(X0, ZF - PT, MX, ZF, roofTop)
parapet(X0, ZB, MX, ZB + PT, roofTop)
parapet(MX - PT, ZB + PT, MX, ZF - PT, roofTop)
-- Left parapet has a gap where the stair bridge lands (filled in after the stair is laid out).
local wingTop = SH + 0.6
parapet(MX, ZF - PT, X1, ZF, wingTop)
parapet(MX, ZB, X1, ZB + PT, wingTop)
parapet(X1 - PT, ZB + PT, X1, ZF - PT, wingTop)

-- Exterior switchback stair on the left side ------------------------------------------------
do
	local W1x0, W1x1 = X0 - 4.6, X0 - 0.6       -- inner flight
	local W2x0, W2x1 = X0 - 9, X0 - 5            -- outer flight
	local land = 5                               -- landing depth
	local run = math.min(SH * 1.6, DEP - land - 6)
	local zLand0, zLand1 = ZB + 1, ZB + 1 + land -- landing at the back, first floor level
	-- Flight 1: ground (front end) up to the landing (back).
	flight(stairs, W1x0, W1x1, zLand1 + run, FLOOR, zLand1, SH + 0.4)
	-- Landing at first floor: both lanes, posts to the ground, railing.
	local L1 = SH + 0.4
	box(stairs, "Landing", W2x0, L1 - 0.3, zLand0, X0, L1, zLand1, "tread")
	for _, p in ipairs({ { W2x0, zLand0 }, { W2x0, zLand1 - 0.4 }, { X0 - 0.4, zLand0 } }) do
		box(stairs, "Post", p[1], 0, p[2], p[1] + 0.4, L1 - 0.3, p[2] + 0.4, "steel")
	end
	railing(stairs, Vector3.new(W2x0, L1, zLand0), Vector3.new(X0 - 0.2, L1, zLand0))
	railing(stairs, Vector3.new(W2x0, L1, zLand0), Vector3.new(W2x0, L1, zLand1))
	-- Flight 2: from the landing up to roof level, heading to the front.
	flight(stairs, W2x0, W2x1, zLand1, L1, zLand1 + run, roofTop)
	-- Top landing and bridge over the inner lane to the roof.
	local zt0, zt1 = zLand1 + run, zLand1 + run + 4
	box(stairs, "TopLanding", W2x0, roofTop - 0.3, zt0, X0, roofTop, zt1, "tread")
	for _, p in ipairs({ { W2x0, zt1 - 0.4 }, { W2x1 - 0.4, zt1 - 0.4 } }) do
		box(stairs, "Post", p[1], 0, p[2], p[1] + 0.4, roofTop - 0.3, p[2] + 0.4, "steel")
	end
	railing(stairs, Vector3.new(W2x0, roofTop, zt1), Vector3.new(X0 - 0.2, roofTop, zt1))
	railing(stairs, Vector3.new(W2x0, roofTop, zt0), Vector3.new(W2x0, roofTop, zt1))
	railing(stairs, Vector3.new(W1x0, roofTop, zt0), Vector3.new(X0 - 0.2, roofTop, zt0))
	-- Left parapet, split round the bridge.
	parapet(X0, ZB + PT, X0 + PT, zt0, roofTop)
	parapet(X0, zt1, X0 + PT, ZF - PT, roofTop)
end

-- Control cab on the main roof ---------------------------------------------------------------
do
	local cw = math.min(22, mainLen - 8)
	local cd = math.min(16, DEP - 10)
	local cx = (X0 + MX) / 2
	local cz = ZF - T - 3 - cd / 2
	local yb = roofTop                  -- cab floor
	local solid = 3.4                   -- concrete band below the glass
	local gh = 6                        -- glass height
	local tilt = math.rad(11)
	local lean = gh * math.tan(tilt)
	local baseCF = CFrame.new(cx, 0, cz)
	local function C(x0, y0, z0, x1, y1, z1, mat, name)
		return part(cab, name, baseCF * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
			Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat)
	end
	local hx, hz = cw / 2, cd / 2
	C(-hx, yb, -hz, hx, yb + 0.3, hz, "floor", "CabFloor")
	-- Solid band: front and sides; back wall is full height with the door.
	C(-hx, yb, hz - 0.6, hx, yb + solid, hz, "wall", "CabBand")
	C(-hx, yb, -hz + 0.6, -hx + 0.6, yb + solid, hz - 0.6, "wall", "CabBand")
	C(hx - 0.6, yb, -hz + 0.6, hx, yb + solid, hz - 0.6, "wall", "CabBand")
	wall(cab, "CabBack", Vector3.new(cx + hx, 0, cz - hz + 0.3), Vector3.new(cx - hx, 0, cz - hz + 0.3), yb, yb + solid + gh, 0.6,
		{ { hx - 1.8, hx + 1.8, yb + 0.3, yb + 8, "door" }, { 2, hx - 4, yb + 3.8, yb + 7.8, "window" },
			{ hx + 4, cw - 2, yb + 3.8, yb + 7.8, "window" } })
	-- Leaning glass on front, left and right, with tilted mullions and corner posts.
	-- Each side in its own frame: local +Z = outward, local X = along the side.
	-- The side panes run from the back wall to the front corner.
	local g0 = yb + solid
	for _, side in ipairs({
		{ 0, hx, hz, 0 },                 -- front
		{ -math.pi / 2, hz - 0.3, hx, 0.3 }, -- left  (local X = +Z)
		{ math.pi / 2, hz - 0.3, hx, -0.3 }, -- right (local X = -Z)
	}) do
		local sf = baseCF * CFrame.Angles(0, side[1], 0)
		local halfLen, dist, off = side[2], side[3], side[4]
		part(cab, "Glass", sf * CFrame.new(off, g0 + gh / 2, dist - 0.3 + lean / 2) * CFrame.Angles(tilt, 0, 0),
			Vector3.new(halfLen * 2, gh / math.cos(tilt), 0.15), "glass")
		local n = math.max(2, math.floor(halfLen * 2 / 4 + 0.5))
		for i = 0, n do
			local u = off - halfLen + 2 * halfLen * i / n
			local a = (sf * CFrame.new(u, g0, dist - 0.3)).Position
			local b = (sf * CFrame.new(u, g0 + gh, dist - 0.3 + lean)).Position
			bar(cab, "Mullion", a, b, 0.22, 0.3, "trim")
		end
	end
	-- Corner posts where the front glass meets the sides (they cover the wedge
	-- of air left where two leaning panes meet).
	for _, sx in ipairs({ -1, 1 }) do
		local a = Vector3.new(cx + sx * hx, g0, cz + hz - 0.3)
		local b = Vector3.new(cx + sx * (hx + lean), g0 + gh, cz + hz - 0.3 + lean)
		bar(cab, "CornerPost", a, b, 1.2, 1.2, "trim")
	end
	-- Roof with overhang and fascia, beacon, antenna.
	local rh = hz + lean + 1.4
	local rw = hx + lean + 1.4
	C(-rw, g0 + gh, -hz - 0.6, rw, g0 + gh + 0.7, rh, "roof", "CabRoof")
	C(-rw - 0.1, g0 + gh - 0.2, rh, rw + 0.1, g0 + gh + 0.9, rh + 0.15, "trim", "CabFascia")
	C(-rw - 0.15, g0 + gh - 0.2, -hz - 0.6, -rw, g0 + gh + 0.9, rh, "trim", "CabFascia")
	C(rw, g0 + gh - 0.2, -hz - 0.6, rw + 0.15, g0 + gh + 0.9, rh, "trim", "CabFascia")
	local beacon = C(-0.4, g0 + gh + 0.7, -0.4, 0.4, g0 + gh + 1.4, 0.4, "red", "Beacon")
	addLight(beacon, "PointLight", { Range = 14, Brightness = 1.5, Color = MAT.red[3] })
	local top = g0 + gh + 0.7
	bar(cab, "Antenna", Vector3.new(cx + hx - 2, top, cz - hz + 1.5), Vector3.new(cx + hx - 2, top + 9, cz - hz + 1.5), 0.25, 0.25, "rail")
	bar(cab, "Antenna", Vector3.new(cx - hx + 2, top, cz - hz + 1.5), Vector3.new(cx - hx + 2, top + 6, cz - hz + 1.5), 0.2, 0.2, "rail")
	-- Consoles along the front and sides, screens, chairs.
	C(-hx + 1, yb + 0.3, hz - 3.2, hx - 1, yb + 3.2, hz - 0.8, "desk", "Console")
	C(-hx + 0.8, yb + 0.3, -hz + 3, -hx + 2.8, yb + 3.2, hz - 3.2, "desk", "Console")
	C(hx - 2.8, yb + 0.3, -hz + 3, hx - 0.8, yb + 3.2, hz - 3.2, "desk", "Console")
	for i = -2, 2 do
		local x = i * (cw - 6) / 5
		C(x - 1.1, yb + 3.2, hz - 2.2, x + 1.1, yb + 4.6, hz - 2.05, "dark", "Monitor")
		C(x - 1, yb + 3.3, hz - 2.26, x + 1, yb + 4.5, hz - 2.2, "screen", "Screen")
		C(x - 0.9, yb + 1.8, hz - 5.6, x + 0.9, yb + 2.1, hz - 3.8, "chair", "Seat")
		C(x - 0.9, yb + 2.1, hz - 5.9, x + 0.9, yb + 4.6, hz - 5.6, "chair", "ChairBack")
	end
	local cl = C(-3, g0 + gh - 0.1, -1, 3, g0 + gh, 1, "lamp", "CabLight")
	addLight(cl, "SurfaceLight", { Face = Enum.NormalId.Bottom, Range = 12, Angle = 120, Brightness = 0.7 })
end

-- Entrance canopy with sign and downlights ---------------------------------------------------
do
	local cw = 16
	local y = 10
	box(ext, "Canopy", wingMid - cw / 2, y, ZF, wingMid + cw / 2, y + 0.4, ZF + 6, "band")
	local fascia = box(ext, "Fascia", wingMid - cw / 2, y - 0.3, ZF + 6, wingMid + cw / 2, y + 1.6, ZF + 6.3, "trim")
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(0.94, 0.8)
	t.Position = UDim2.fromScale(0.03, 0.1)
	t.BackgroundTransparency = 1
	t.Text = SIGN_TEXT
	t.TextScaled = true
	t.Font = Enum.Font.GothamBold
	t.TextColor3 = Color3.fromRGB(226, 228, 226)
	t.Parent = gui
	gui.Parent = fascia
	for _, x in ipairs({ wingMid - cw / 2 + 0.6, wingMid + cw / 2 - 0.6 }) do
		box(ext, "CanopyPost", x - 0.2, FLOOR, ZF + 5.4, x + 0.2, y, ZF + 5.8, "steel")
	end
	for _, x in ipairs({ wingMid - 4, wingMid + 4 }) do
		local l = box(ext, "Downlight", x - 0.5, y - 0.05, ZF + 2.5, x + 0.5, y, ZF + 3.5, "lamp")
		addLight(l, "SpotLight", { Face = Enum.NormalId.Bottom, Range = 16, Angle = 100, Brightness = 1.5 })
	end
	box(ext, "EntryMat", wingMid - 4, FLOOR, ZF, wingMid + 4, FLOOR + 0.05, ZF + 4, "dark")
	box(ext, "Step", wingMid - cw / 2, 0, ZF, wingMid + cw / 2, FLOOR, ZF + 6.4, "band")
	-- Wall lights round the building.
	wallLight(ext, Vector3.new(X0 + 4, SH - 2, ZF + 1.2), Vector3.new(0, 0, 1))
	wallLight(ext, Vector3.new(X1 - 3, SH - 3, ZF + 0.1), Vector3.new(0, 0, 1))
	wallLight(ext, Vector3.new(X1 + 0.1, SH - 3, 0), Vector3.new(1, 0, 0))
	wallLight(ext, Vector3.new(wingMid, SH - 3, ZB - 0.1), Vector3.new(0, 0, -1))
	wallLight(ext, Vector3.new(X0 - 0.1, SH + 9.8, ZB + 3.8), Vector3.new(-1, 0, 0))
end

-- Interior ------------------------------------------------------------------------------------
do
	-- Lobby (wing): reception desk facing the door, lights.
	local lz = ZF - T - 7
	box(inside, "Reception", wingMid - 4, FLOOR, lz - 1.2, wingMid + 4, 3.6, lz + 1.2, "desk")
	box(inside, "ReceptionTop", wingMid - 4.2, 3.6, lz - 1.4, wingMid + 4.2, 3.8, lz + 1.4, "trim")
	for _, x in ipairs({ MX + 5, wingMid, X1 - 5 }) do
		ceilingLight(inside, x, SH - 0.2, 0, 3, 1.2)
	end
	-- Ground floor ops room (main block): ceiling lights, desks facing the front.
	for _, x in ipairs({ X0 + mainLen * 0.25, X0 + mainLen * 0.5, X0 + mainLen * 0.75 }) do
		for _, z in ipairs({ ZB + DEP * 0.3, ZB + DEP * 0.7 }) do
			ceilingLight(inside, x, SH - 0.4, z, 4, 1.2)
		end
	end
	for _, x in ipairs({ X0 + mainLen * 0.3, X0 + mainLen * 0.55, X0 + mainLen * 0.8 }) do
		desk(inside, x, ZF - T - 4, 1)
	end
	-- First floor: lights and a row of desks at the front windows.
	for _, x in ipairs({ X0 + mainLen * 0.25, X0 + mainLen * 0.5, X0 + mainLen * 0.75 }) do
		for _, z in ipairs({ ZB + DEP * 0.3, ZB + DEP * 0.7 }) do
			ceilingLight(inside, x, HM - 0.2, z, 4, 1.2)
		end
	end
	for _, x in ipairs({ X0 + mainLen * 0.3, X0 + mainLen * 0.55, X0 + mainLen * 0.8 }) do
		local g = group(inside, "Upstairs")
		desk(g, x, ZF - T - 4, 1)
		for _, p in ipairs(g:GetDescendants()) do
			if p:IsA("BasePart") then
				p.CFrame = p.CFrame + BASE_CF.UpVector * (SH + 0.4)
			end
		end
	end
end

-- Rooftop kit ----------------------------------------------------------------------------------
do
	for i, x in ipairs({ MX + 5, MX + 13 }) do
		if x + 4 < X1 - 1 then
			box(roofG, "ACUnit", x, wingTop, ZB + 3, x + 6, wingTop + 3, ZB + 7, "vent")
			box(roofG, "ACFan", x + 1.5, wingTop + 3, ZB + 3.8, x + 4.5, wingTop + 3.05, ZB + 6.2, "dark")
			if i == 1 then
				bar(roofG, "Duct", Vector3.new(x, wingTop + 1.2, ZB + 5), Vector3.new(MX, wingTop + 1.2, ZB + 5), 1, 1, "rail")
			end
		end
	end
	local sx = math.min(X1 - 5, MX + 20)
	local dish = box(roofG, "MESH_SatDish", sx - 2.5, wingTop, 1, sx + 2.5, wingTop + 5, 6, "placeholder")
	dish:SetAttribute("ReplaceWith", "Satellite dish")
	game:GetService("CollectionService"):AddTag(dish, "MeshPlaceholder")
	-- Antenna mast with guy wires at the back of the main roof.
	local mx, mz = X0 + 5, ZB + 5
	bar(roofG, "Mast", Vector3.new(mx, roofTop, mz), Vector3.new(mx, roofTop + 16, mz), 0.35, 0.35, "rail")
	for _, g in ipairs({ { 3, 0 }, { -2, 2.5 }, { -2, -2.5 } }) do
		bar(roofG, "GuyWire", Vector3.new(mx, roofTop + 12, mz), Vector3.new(mx + g[1], roofTop, mz + g[2]), 0.06, 0.06, "rail")
	end
end

-------------------------------------------------------------------------------

bld.PrimaryPart = ground
bld.WorldPivot = BASE_CF
bld.Parent = workspace

if MOVE_BLOCKOUT and #selected > 0 then
	local store = game:GetService("ServerStorage")
	local folder = store:FindFirstChild("Blockouts")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Blockouts"
		folder.Parent = store
	end
	for _, inst in ipairs(selected) do
		inst.Parent = folder
	end
end
pcall(function()
	Selection:Set({ bld })
end)

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build Air Ops Command")
	end)
end

local count = 0
for _, d in ipairs(bld:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[AirOps] Built Workspace.AirOpsCommand: %.0f x %.0f footprint, storeys %d studs, %d parts."):format(
	LEN, DEP, SH, count))
