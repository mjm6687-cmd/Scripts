--[[
	HELIPAD BUILDER  --  run in Studio's COMMAND BAR (View > Command Bar)
	--------------------------------------------------------------------
	Builds ONE helipad as Workspace > Helipad, on the ground where your camera
	is pointing, turned to face the way you're looking (snapped to 90 degrees).
	Run it again to move it: it deletes the old one first. Ctrl+Z undoes it.

	The pad only: a thin concrete slab with a small bevel and slim drainage
	grates, the green painted surface, fine markings (border, dashed inner
	square, ticks, corner brackets, outer circle, amber dash ring, touchdown
	circle, aiming marks, H), tie-down points and neon edge lights.

	PAD sets the size; every marking scales with it. Line widths are separate
	and stay the same whatever the size.
]]

local USE_CAMERA = true               -- false = build at ORIGIN instead
local ORIGIN = Vector3.new(0, 0, 0)

local PAD = 60                        -- painted square, studs across
local PAD_GREEN = Color3.fromRGB(58, 104, 80)
local LINE_WHITE = Color3.fromRGB(206, 208, 202)
local LINE_AMBER = Color3.fromRGB(214, 164, 44)

-- Line widths (studs).
local W_BORDER = 0.4
local W_DASH = 0.25
local W_TICK = 0.2
local W_BRACKET = 0.3
local W_OUTER_CIRCLE = 0.3
local W_AMBER = 0.25
local W_TOUCHDOWN = 0.6
local W_AIM = 0.3
local W_H = 1.2                       -- stroke of the H

-- Size of the middle group (circles, amber ring, aiming marks, H, tie-downs)
-- relative to the pad. Lower = more space between it and the dashed square.
local CIRCLE_SCALE = 0.82

-- Edge lights (studs).
local LIGHTS_PER_SIDE = 7
local LIGHT_LENS = 0.22               -- glowing lens diameter
local LIGHT_HEIGHT = 0.08

-------------------------------------------------------------------------------

local M = Enum.Material
local MAT = {
	slab    = { M.Concrete, "Large Concrete Tile", Color3.fromRGB(128, 128, 124) },
	surface = { M.Concrete, "Flat Concrete Dark",  PAD_GREEN },
	metal   = { M.Metal,    "Scuffed Iron",        Color3.fromRGB(88, 90, 88) },
	grate   = { M.Metal,    "Metal Grate",         Color3.fromRGB(70, 72, 70) },
	dark    = { M.SmoothPlastic, nil,              Color3.fromRGB(34, 36, 36) },
	white   = { M.Concrete, nil,                   LINE_WHITE, true },
	amber   = { M.Concrete, nil,                   LINE_AMBER, true },
	lens    = { M.Neon,     nil,                   Color3.fromRGB(90, 255, 140) },
}

local H = PAD / 2                     -- half of the green
local K = H / 30                      -- scale for marking positions (1 at PAD 60)
local C = K * CIRCLE_SCALE            -- scale for the middle group
local SLAB_TOP = 0.5                  -- slab height
local SURF = SLAB_TOP + 0.02          -- top of the green
local LINE = SURF + 0.02              -- top of the paint
local S = H + 0.9                     -- half of the slab top
local E = S + 0.7                     -- half of the slab at the ground (bevel)

-------------------------------------------------------------------------------

local old = workspace:FindFirstChild("Helipad")
if old then
	old:Destroy()
end

-- Where: the ground under the middle of the screen, facing the camera's way.
local ORIGIN_CF = CFrame.new(ORIGIN)
if USE_CAMERA and workspace.CurrentCamera then
	local cam = workspace.CurrentCamera.CFrame
	local hit = workspace:Raycast(cam.Position, cam.LookVector * 4000)
	local look = cam.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	yaw = math.floor(yaw / (math.pi / 2) + 0.5) * (math.pi / 2)
	local pos = hit and hit.Position or (cam.Position + look * 150) * Vector3.new(1, 0, 1)
	ORIGIN_CF = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end

local function part(parent, name, cf, size, mat)
	local m = MAT[mat]
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = ORIGIN_CF * cf
	p.Material = m[1]
	if m[2] then
		p.MaterialVariant = m[2]
	end
	p.Color = m[3]
	if m[4] then -- paint: can't be bumped into, shot or touched
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

local function box(parent, name, x0, y0, z0, x1, y1, z1, mat)
	return part(parent, name, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), mat)
end

local function cyl(parent, name, x, y0, z, h, d, mat)
	local p = part(parent, name, CFrame.new(x, y0 + h / 2, z) * CFrame.Angles(0, 0, math.pi / 2),
		Vector3.new(h, d, d), mat)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Painted strip from (x0, z0) to (x1, z1).
local function stripe(parent, name, x0, z0, x1, z1, w, mat)
	local y = (SURF + LINE) / 2
	local a, b = Vector3.new(x0, y, z0), Vector3.new(x1, y, z1)
	return part(parent, name, CFrame.lookAt((a + b) / 2, b), Vector3.new(w, LINE - SURF, (b - a).Magnitude), mat or "white")
end

-- Painted ring of n segments; keep(i) picks which are drawn (dashes), fill is
-- how much of each kept segment is painted.
local function ring(parent, name, r, n, w, mat, keep, fill)
	local seg = 2 * math.pi * r / n
	for i = 0, n - 1 do
		if not keep or keep(i) then
			local a = (i + 0.5) / n * 2 * math.pi
			part(parent, name, CFrame.new(math.cos(a) * r, (SURF + LINE) / 2, math.sin(a) * r) * CFrame.Angles(0, -a, 0),
				Vector3.new(w, LINE - SURF, keep and seg * (fill or 0.6) or seg + 0.03), mat)
		end
	end
end

local function group(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build Helipad")
end)

local pad = Instance.new("Model")
pad.Name = "Helipad"
local slabF = group(pad, "Slab")
local paint = group(pad, "Markings")
local lights = group(pad, "Lights")

-- Slab, with a small bevel all round.
local slab = box(slabF, "Slab", -S, 0, -S, S, SLAB_TOP, S, "slab")
do
	local run, rise = E - S, SLAB_TOP
	local len, ang = math.sqrt(run * run + rise * rise), math.atan2(rise, run)
	local t = 0.25
	local up = Vector3.new(0, math.cos(ang), -math.sin(ang))
	local mid = Vector3.new(0, rise / 2, -(E + S) / 2) - up * (t / 2)
	for k = 0, 3 do
		part(slabF, "Bevel", CFrame.Angles(0, k * math.pi / 2, 0) * CFrame.new(mid) * CFrame.Angles(-ang, 0, 0),
			Vector3.new(2 * S, t, len), "slab")
	end
	for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		box(slabF, "Corner", c[1] * S, 0, c[2] * S, c[1] * E, SLAB_TOP * 0.45, c[2] * E, "slab")
	end
	-- Slim drainage grates in the concrete margin, north and south.
	for _, sz in ipairs({ -1, 1 }) do
		box(slabF, "Drain", -H + 2, SLAB_TOP - 0.15, sz * (H + 0.2), H - 2, SLAB_TOP + 0.01, sz * (H + 0.7), "grate")
	end
end

-- Green surface.
box(paint, "Surface", -H, SLAB_TOP, -H, H, SURF, H, "surface")

-- Border: thin solid line just in from the edge.
local BORDER_C = H - 0.9 - W_BORDER / 2
do
	local c, hw = BORDER_C, W_BORDER / 2
	stripe(paint, "Border", -c - hw, -c, c + hw, -c, W_BORDER)
	stripe(paint, "Border", -c - hw, c, c + hw, c, W_BORDER)
	stripe(paint, "Border", -c, -c + hw, -c, c - hw, W_BORDER)
	stripe(paint, "Border", c, -c + hw, c, c - hw, W_BORDER)
end

-- Dashed inner square, ticks out to the border, corner brackets.
do
	local r = H - 5.5 * K
	local bIn = BORDER_C - W_BORDER / 2
	for k = 0, 3 do
		local rot = CFrame.Angles(0, k * math.pi / 2, 0)
		local function seg(x, z, x2, z2, w, nm)
			local a = rot * Vector3.new(x, 0, z)
			local c = rot * Vector3.new(x2, 0, z2)
			stripe(paint, nm, a.X, a.Z, c.X, c.Z, w)
		end
		-- Dashes centred on the side, clear of the corner brackets.
		local dash, gap = 2.4 * K, 2.2 * K
		local count = math.floor((2 * (r - 7 * K) + gap) / (dash + gap))
		local x = -(count * (dash + gap) - gap) / 2
		for _ = 1, count do
			seg(x, -r, x + dash, -r, W_DASH, "Dash")
			x += dash + gap
		end
		for _, j in ipairs({ -1.5, -0.5, 0.5, 1.5 }) do
			seg(j * 9.5 * K, -r - 1 * K, j * 9.5 * K, -bIn - 0.5, W_TICK, "Tick")
		end
		seg(-r - W_BRACKET / 2, -r, -r + 4.5 * K, -r, W_BRACKET, "Bracket")
		seg(-r, -r, -r, -r + 4.5 * K, W_BRACKET, "Bracket")
	end
end

-- Circles and aiming marks.
ring(paint, "OuterCircle", 23 * C, 120, W_OUTER_CIRCLE, "white")
ring(paint, "AmberRing", 24.2 * C, 80, W_AMBER, "amber", function(i)
	return i % 2 == 0
end, 0.9)
ring(paint, "TouchdownCircle", 14 * C, 96, W_TOUCHDOWN, "white")
-- Aiming marks: short arcs on the axes and diagonals.
for i = 0, 7 do
	local a = i * math.pi / 4
	local r = 18.5 * C
	part(paint, "AimingMark", CFrame.new(math.cos(a) * r, (SURF + LINE) / 2, math.sin(a) * r) * CFrame.Angles(0, -a, 0),
		Vector3.new(W_AIM, LINE - SURF, 3 * C), "white")
end

-- H.
do
	local tall, wide = 11 * C, 7.4 * C
	local hx = wide / 2 - W_H / 2
	stripe(paint, "H", -hx, -tall / 2, -hx, tall / 2, W_H)
	stripe(paint, "H", hx, -tall / 2, hx, tall / 2, W_H)
	stripe(paint, "H", -hx + W_H / 2, 0, hx - W_H / 2, 0, W_H)
end

-- Tie-down points: small flush steel rings.
for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
	local x, z = c[1] * 8.5 * C, c[2] * 8.5 * C
	cyl(paint, "TieDown", x, SLAB_TOP, z, SURF - SLAB_TOP + 0.015, 0.5, "metal")
	cyl(paint, "TieDownEye", x, SURF + 0.015, z, 0.01, 0.25, "dark")
end

-- Edge lights: just the glowing lens, set into the edge of the green.
do
	local d = H - 0.4
	local step = 2 * d / LIGHTS_PER_SIDE
	for k = 0, 3 do
		local rot = CFrame.Angles(0, k * math.pi / 2, 0)
		for i = 0, LIGHTS_PER_SIDE - 1 do
			local v = rot * Vector3.new(-d + i * step, 0, -d)
			cyl(lights, "Light", v.X, SURF, v.Z, LIGHT_HEIGHT, LIGHT_LENS, "lens")
		end
	end
end

pad.PrimaryPart = slab
pad.WorldPivot = ORIGIN_CF
pad.Parent = workspace

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
for _, d in ipairs(pad:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[Helipad] Built Workspace.Helipad: %d parts."):format(count))
