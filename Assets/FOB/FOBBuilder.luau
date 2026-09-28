--[[
	FOB BUILDER  --  run this in Studio's COMMAND BAR (View > Command Bar)
	---------------------------------------------------------------------
	Builds the forward operating base + heliport from the site plan as
	Workspace > FOB. Run it again any time: it deletes the old one and rebuilds.
	Ctrl+Z undoes it.

	It's a FRAMEWORK: every building, wall, road and pad is there at the right
	size and in the right place, built from plain Parts, so you can swap in
	proper models or detail it by hand. Nothing here is scripted.

	Everything is in STUDS and matches the numbered key on the plan:
	  Perimeter  1 HESCO wall  2 corner towers  3 gate + drop bar  4 serpentine
	  Camp       5 barracks  6 spawn  7 DFAC  8 showers  9 TOC  10 comms mast
	             11 generators  12 motor pool  13 mortar pit  14 ammo point
	  Heliport   15 barrier line  16/17 helipads  18 flight ops tower
	             19 fuel point  20 aid station  21 windsock

	The base is 480 x 360 studs. On the plan NORTH is up; in Studio (with
	YAW = 0) north is -Z and east is +X.
]]

-- WHERE. ORIGIN is the middle of the base, at ground level (the Y is the height
-- of the ground surface). YAW turns the whole base, in degrees.
local ORIGIN = Vector3.new(0, 0, 0)
local YAW = 0

local MAKE_GROUND = true   -- dirt + concrete slabs under the base (off if you're on terrain)
local MAKE_SPAWNS = true   -- 3 SpawnLocations in the assembly area
local SHOW_LABELS = true   -- floating name tags over each building, for while you build

-------------------------------------------------------------------------------

local STYLE = {
	ground   = { Color3.fromRGB(139, 123, 94),  Enum.Material.Ground },
	concrete = { Color3.fromRGB(152, 152, 146), Enum.Material.Concrete },
	pad      = { Color3.fromRGB(118, 121, 121), Enum.Material.Concrete },
	road     = { Color3.fromRGB(88, 84, 78),    Enum.Material.Asphalt },
	gravel   = { Color3.fromRGB(128, 120, 106), Enum.Material.Pebble },
	hesco    = { Color3.fromRGB(176, 156, 118), Enum.Material.Fabric },
	sandbag  = { Color3.fromRGB(162, 142, 102), Enum.Material.Fabric },
	berm     = { Color3.fromRGB(118, 98, 70),   Enum.Material.Ground },
	tent     = { Color3.fromRGB(96, 104, 72),   Enum.Material.Fabric },
	hut      = { Color3.fromRGB(150, 138, 110), Enum.Material.Wood },
	wood     = { Color3.fromRGB(122, 96, 66),   Enum.Material.WoodPlanks },
	metal    = { Color3.fromRGB(92, 96, 92),    Enum.Material.Metal },
	crate    = { Color3.fromRGB(84, 92, 60),    Enum.Material.Wood },
	rubber   = { Color3.fromRGB(35, 36, 34),    Enum.Material.SmoothPlastic },
	glass    = { Color3.fromRGB(160, 190, 200), Enum.Material.Glass, 0.55 },
	red      = { Color3.fromRGB(190, 40, 35),   Enum.Material.SmoothPlastic },
	white    = { Color3.fromRGB(235, 235, 230), Enum.Material.SmoothPlastic },
	orange   = { Color3.fromRGB(230, 120, 30),  Enum.Material.Fabric },
	light    = { Color3.fromRGB(255, 170, 60),  Enum.Material.Neon },
	-- Painted markings: can't be walked into, shot or touched.
	paintY   = { Color3.fromRGB(232, 168, 40),  Enum.Material.SmoothPlastic, 0, true },
	paintW   = { Color3.fromRGB(230, 230, 225), Enum.Material.SmoothPlastic, 0, true },
}

local ORIGIN_CF = CFrame.new(ORIGIN) * CFrame.Angles(0, math.rad(YAW), 0)
local DOOR_H = 8

-- Plan coordinates (x east 0..480, z south 0..360, y up) -> local CFrame.
local function P(px, y, pz)
	return CFrame.new(px - 240, y, pz - 180)
end

local function place(parent, class, name, cf, size, style)
	local s = STYLE[style]
	local p = Instance.new(class)
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = ORIGIN_CF * cf
	p.Color = s[1]
	p.Material = s[2]
	p.Transparency = s[3] or 0
	if s[4] then
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

-- Box by its plan footprint: top-left corner (x, z), w east, d south, from y0 up h.
local function box(parent, name, x, z, w, d, y0, h, style)
	return place(parent, "Part", name, P(x + w / 2, y0 + h / 2, z + d / 2), Vector3.new(w, h, d), style)
end

-- Thin rod between two plan points (Vector3(px, y, pz)).
local function rod(parent, name, a, b, t, style)
	local A = Vector3.new(a.X - 240, a.Y, a.Z - 180)
	local B = Vector3.new(b.X - 240, b.Y, b.Z - 180)
	local up = math.abs((B - A).Unit.Y) > 0.99 and Vector3.zAxis or Vector3.yAxis
	return place(parent, "Part", name, CFrame.lookAt((A + B) / 2, B, up), Vector3.new(t, t, (B - A).Magnitude), style)
end

-- Ring of n segments. skip(angle) = true leaves a gap there (angle 3pi/2 = north).
local function ring(parent, name, cx, cz, r, n, w, y0, h, style, skip)
	local seg = 2 * math.pi * r / n + 0.2
	for i = 0, n - 1 do
		local a = i / n * 2 * math.pi
		if not (skip and skip(a)) then
			place(parent, "Part", name, P(cx + math.cos(a) * r, y0 + h / 2, cz + math.sin(a) * r) * CFrame.Angles(0, -a, 0),
				Vector3.new(w, h, seg), style)
		end
	end
end

local function folder(parent, name, class)
	local f = Instance.new(class or "Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function label(part, text, height)
	if not SHOW_LABELS then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "BuildLabel"
	gui.Size = UDim2.fromOffset(220, 26)
	gui.StudsOffset = Vector3.new(0, height, 0)
	gui.MaxDistance = 400
	gui.AlwaysOnTop = true
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.3
	t.Font = Enum.Font.GothamBold
	t.TextSize = 16
	t.Parent = gui
	gui.Parent = part
end

--[[
	A tent (pitched roof) or hut (flat roof). Long axis runs east-west; a door
	gap in both short (east/west) ends. Returns the Model.
--]]
local function building(parent, name, x, z, w, d, o)
	local m = folder(parent, name, "Model")
	local base = P(x + w / 2, 0, z + d / 2)
	local H, t, door, st = o.wallH, 0.4, o.door, o.style
	local function part(nm, cf, size, s)
		return place(m, "Part", nm, base * cf, size, s or st)
	end
	local floor = part("Floor", CFrame.new(0, 0.2, 0), Vector3.new(w, 0.4, d), "wood")
	part("Wall", CFrame.new(0, H / 2, -d / 2 + t / 2), Vector3.new(w, H, t))
	part("Wall", CFrame.new(0, H / 2, d / 2 - t / 2), Vector3.new(w, H, t))
	local side = (d - 2 * t - door) / 2
	for _, sx in ipairs({ -1, 1 }) do
		local ex = sx * (w / 2 - t / 2)
		for _, sz in ipairs({ -1, 1 }) do
			part("Wall", CFrame.new(ex, H / 2, sz * (door / 2 + side / 2)), Vector3.new(t, H, side))
		end
		if H > DOOR_H then
			part("Lintel", CFrame.new(ex, (DOOR_H + H) / 2, 0), Vector3.new(t, H - DOOR_H, door))
		end
	end
	if o.kind == "tent" then
		local R, half = o.roofH, d / 2
		local len, ang = math.sqrt(half * half + R * R), math.atan2(R, half)
		part("Roof", CFrame.new(0, H + R / 2, -half / 2) * CFrame.Angles(-ang, 0, 0), Vector3.new(w + 1, 0.3, len))
		part("Roof", CFrame.new(0, H + R / 2, half / 2) * CFrame.Angles(ang, 0, 0), Vector3.new(w + 1, 0.3, len))
	else
		part("Roof", CFrame.new(0, H + 0.25, 0), Vector3.new(w + 1, 0.5, d + 1))
	end
	m.PrimaryPart = floor
	label(floor, name, H + (o.roofH or 0) + 3)
	return m
end

--[[
	Watch tower: legs, deck at deckH, low wall round the deck with a gap where a
	climbable TrussPart ladder comes up, and a roof. ladder = side the ladder is
	on ("N"/"S"/"E"/"W"). cab = glass control cab instead of an open roof.
--]]
local LADDER_YAW = { S = 0, N = math.pi, E = math.pi / 2, W = -math.pi / 2 }
local function tower(parent, name, x, z, size, deckH, ladder, cab)
	local m = folder(parent, name, "Model")
	local base = P(x + size / 2, 0, z + size / 2) * CFrame.Angles(0, LADDER_YAW[ladder], 0)
	local function part(nm, cf, sz, s, class)
		return place(m, class or "Part", nm, base * cf, sz, s)
	end
	local e = size / 2 - 0.5
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			part("Leg", CFrame.new(sx * e, deckH / 2, sz * e), Vector3.new(1, deckH, 1), "wood")
		end
	end
	local deck = part("Deck", CFrame.new(0, deckH + 0.5, 0), Vector3.new(size, 1, size), "wood")
	local top = deckH + 1

	-- Low wall: full on three sides, gap of 3 on the ladder (+Z) side.
	local lowStyle = cab and "hut" or "sandbag"
	local function walls(y0, h, s)
		part("Wall", CFrame.new(0, y0 + h / 2, -e), Vector3.new(size, h, 1), s)
		part("Wall", CFrame.new(-e, y0 + h / 2, 0), Vector3.new(1, h, size), s)
		part("Wall", CFrame.new(e, y0 + h / 2, 0), Vector3.new(1, h, size), s)
		local pw = (size - 3) / 2
		for _, sx in ipairs({ -1, 1 }) do
			part("Wall", CFrame.new(sx * (1.5 + pw / 2), y0 + h / 2, e), Vector3.new(pw, h, 1), s)
		end
	end
	walls(top, 3, lowStyle)
	local roofY
	if cab then
		walls(top + 3, 5, "glass")
		roofY = top + 8
	else
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				part("Post", CFrame.new(sx * e, top + 3.5, sz * e), Vector3.new(1, 7, 1), "wood")
			end
		end
		roofY = top + 7
	end
	part("Roof", CFrame.new(0, roofY + 0.25, 0), Vector3.new(size + 1, 0.5, size + 1), cab and "metal" or "wood")
	-- TrussParts are climbable. Height must be a multiple of 2.
	local lh = deckH + 2
	lh += lh % 2
	part("Ladder", CFrame.new(0, lh / 2, size / 2 + 1), Vector3.new(2, lh, 2), "metal", "TrussPart")
	m.PrimaryPart = deck
	label(deck, name, roofY - deckH + 3)
	return m
end

-- Jersey barrier centred at (cx, cz), len long, running east-west or north-south.
local function jersey(parent, cx, cz, len, alongX)
	local rot = alongX and CFrame.identity or CFrame.Angles(0, math.pi / 2, 0)
	place(parent, "Part", "Barrier", P(cx, 0.8, cz) * rot, Vector3.new(len, 1.6, 3), "concrete")
	place(parent, "Part", "Barrier", P(cx, 2.3, cz) * rot, Vector3.new(len, 1.4, 1.4), "concrete")
end

-- Helipad: 70x70 slab 1 tall, yellow circle and H, 8 edge lights.
local function helipad(parent, name, x, z)
	local m = folder(parent, name, "Model")
	local slab = box(m, "Pad", x, z, 70, 70, 0, 1, "pad")
	local cx, cz = x + 35, z + 35
	ring(m, "Marking", cx, cz, 30, 40, 2, 1, 0.1, "paintY")
	box(m, "Marking", cx - 10.75, cz - 12, 3.5, 24, 1, 0.1, "paintY")
	box(m, "Marking", cx + 7.25, cz - 12, 3.5, 24, 1, 0.1, "paintY")
	box(m, "Marking", cx - 9, cz - 1.75, 18, 3.5, 1, 0.1, "paintY")
	for _, o in ipairs({ { 0, 0 }, { 35, 0 }, { 70, 0 }, { 0, 35 }, { 70, 35 }, { 0, 70 }, { 35, 70 }, { 70, 70 } }) do
		local l = place(m, "Part", "EdgeLight", P(x + o[1], 1.3, z + o[2]), Vector3.new(1, 0.6, 1), "light")
		local pl = Instance.new("PointLight")
		pl.Color = STYLE.light[1]
		pl.Range = 14
		pl.Brightness = 1.5
		pl.Parent = l
	end
	m.PrimaryPart = slab
	label(slab, name, 6)
	return m
end

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local recording
pcall(function()
	recording = ChangeHistoryService:TryBeginRecording("Build FOB")
end)

local old = workspace:FindFirstChild("FOB")
if old then
	old:Destroy()
end

local fob = Instance.new("Model")
fob.Name = "FOB"

local perimeter = folder(fob, "Perimeter")
local camp = folder(fob, "Camp")
local heli = folder(fob, "Heliport")
local roads = folder(fob, "Roads")
local spawns = folder(fob, "Spawns")

-- Ground ---------------------------------------------------------------------
if MAKE_GROUND then
	local ground = folder(fob, "Ground")
	box(ground, "CampGround", 0, 0, 290, 360, -2, 2, "ground")
	box(ground, "HeliportApron", 290, 0, 190, 360, -2, 2, "concrete")
end

-- Roads ----------------------------------------------------------------------
box(roads, "GateRoad", 120, 200, 30, 220, 0, 0.2, "road")
box(roads, "MainRoad", 20, 190, 320, 20, 0, 0.2, "road")
for zz = 214, 412, 10 do
	box(roads, "Line", 134.75, zz, 0.5, 5, 0.2, 0.05, "paintW")
end
for xx = 26, 330, 10 do
	box(roads, "Line", xx, 199.75, 5, 0.5, 0.2, 0.05, "paintW")
end

-- 1 Perimeter wall (gap for the gate at x 120..150 on the south side) ---------
do
	local wall = folder(perimeter, "HESCOWall")
	box(wall, "Wall", 0, 0, 480, 4, 0, 10, "hesco")
	box(wall, "Wall", 0, 356, 120, 4, 0, 10, "hesco")
	box(wall, "Wall", 150, 356, 330, 4, 0, 10, "hesco")
	box(wall, "Wall", 0, 4, 4, 352, 0, 10, "hesco")
	box(wall, "Wall", 476, 4, 4, 352, 0, 10, "hesco")
end

-- 2 Corner towers, ladders on the inside ----------------------------------------
tower(perimeter, "Tower NW", 0, 0, 16, 20, "S")
tower(perimeter, "Tower NE", 464, 0, 16, 20, "S")
tower(perimeter, "Tower SW", 0, 344, 16, 20, "N")
tower(perimeter, "Tower SE", 464, 344, 16, 20, "N")

-- 3 Gate tower + drop bar ------------------------------------------------------
do
	local gate = folder(perimeter, "Gate")
	tower(gate, "Gate Tower", 152, 336, 14, 16, "N")
	box(gate, "BarPost", 148.5, 343.5, 1, 1, 0, 4, "metal")
	box(gate, "DropBar", 120, 343.75, 28.5, 0.5, 3.4, 0.5, "red")
end

-- 4 Serpentine outside the gate ------------------------------------------------
do
	local serp = folder(perimeter, "Serpentine")
	jersey(serp, 122, 373.5, 28, true)
	jersey(serp, 148, 387.5, 28, true)
	jersey(serp, 122, 401.5, 28, true)
end

-- 5 Barracks -----------------------------------------------------------------
do
	local barracks = folder(camp, "Barracks")
	local n = 0
	for _, zz in ipairs({ 20, 48, 76 }) do
		for _, xx in ipairs({ 20, 66 }) do
			n += 1
			building(barracks, "Barracks " .. n, xx, zz, 36, 16, { kind = "tent", wallH = 7, roofH = 5, door = 5, style = "tent" })
		end
	end
end

-- 6 Assembly area / spawn + flagpole ------------------------------------------
do
	local assembly = folder(camp, "Assembly")
	local pole = box(assembly, "Flagpole", 60.8, 155.8, 0.4, 0.4, 0, 30, "metal")
	box(assembly, "Flag", 61, 155.95, 6, 0.1, 25, 4, "orange")
	label(pole, "Assembly area", 18)
	if MAKE_SPAWNS then
		for _, xx in ipairs({ 34, 54, 74 }) do
			local sp = place(spawns, "SpawnLocation", "SpawnLocation", P(xx + 6, 0.5, 132), Vector3.new(12, 1, 12), "concrete")
			sp.Neutral = true
		end
	end
end

-- 7 DFAC, 8 Showers ----------------------------------------------------------
building(camp, "DFAC", 122, 20, 56, 36, { kind = "tent", wallH = 9, roofH = 7, door = 8, style = "tent" })
building(camp, "Showers", 190, 20, 40, 20, { kind = "hut", wallH = 9, door = 5, style = "hut" })

-- 9 TOC with a sandbag ring (gaps east and west, in line with its doors) -------
do
	local toc = building(camp, "TOC", 150, 90, 60, 44, { kind = "hut", wallH = 11, door = 8, style = "hut" })
	local bags = folder(toc, "Sandbags")
	box(bags, "Sandbags", 145, 85, 70, 1.5, 0, 3, "sandbag")
	box(bags, "Sandbags", 145, 137.5, 70, 1.5, 0, 3, "sandbag")
	for _, xx in ipairs({ 145, 213.5 }) do
		box(bags, "Sandbags", xx, 86.5, 1.5, 21.5, 0, 3, "sandbag")
		box(bags, "Sandbags", xx, 116, 1.5, 21.5, 0, 3, "sandbag")
	end
end

-- 10 Comms mast --------------------------------------------------------------
do
	local mast = folder(camp, "CommsMast", "Model")
	local pole = box(mast, "Mast", 234.5, 99.5, 1, 1, 0, 60, "metal")
	for _, g in ipairs({ { 223, 88 }, { 249, 90 }, { 240, 114 } }) do
		rod(mast, "GuyWire", Vector3.new(235, 45, 100), Vector3.new(g[1], 0, g[2]), 0.15, "metal")
		box(mast, "Anchor", g[1] - 0.75, g[2] - 0.75, 1.5, 1.5, 0, 0.6, "concrete")
	end
	mast.PrimaryPart = pole
	label(pole, "Comms mast", 33)
end

-- 11 Generators --------------------------------------------------------------
do
	local gen = folder(camp, "Generators", "Model")
	local skid = box(gen, "Skid", 222, 124, 26, 14, 0, 0.5, "concrete")
	box(gen, "Generator", 224, 128, 10, 6, 0.5, 5, "metal")
	box(gen, "Generator", 236, 128, 10, 6, 0.5, 5, "metal")
	box(gen, "Exhaust", 225, 129, 0.6, 0.6, 5.5, 2, "rubber")
	box(gen, "Exhaust", 237, 129, 0.6, 0.6, 5.5, 2, "rubber")
	gen.PrimaryPart = skid
	label(skid, "Generators", 9)
end

-- 12 Motor pool: gravel, bay lines, a maintenance canopy over three bays ------
do
	local mp = folder(camp, "MotorPool", "Model")
	local lot = box(mp, "Gravel", 20, 225, 90, 115, 0, 0.15, "gravel")
	for _, zz in ipairs({ 250, 275, 300, 325 }) do
		box(mp, "BayLine", 20, zz - 0.2, 50, 0.4, 0.15, 0.05, "paintW")
	end
	box(mp, "BayLine", 69.8, 225, 0.4, 115, 0.15, 0.05, "paintW")
	for _, xx in ipairs({ 21, 68 }) do
		for _, zz in ipairs({ 226, 262, 298 }) do
			box(mp, "CanopyPost", xx, zz, 1, 1, 0, 14, "metal")
		end
	end
	box(mp, "CanopyRoof", 20, 225, 50, 75, 14, 0.5, "metal")
	mp.PrimaryPart = lot
	label(lot, "Motor pool", 18)
end

-- 13 Mortar pit: sandbag ring, entry facing north (toward the road) ---------
do
	local pit = folder(camp, "MortarPit", "Model")
	local floor = box(pit, "Floor", 166, 236, 18, 18, 0, 0.2, "gravel")
	ring(pit, "Sandbags", 175, 245, 12, 16, 2, 0, 4, "sandbag", function(a)
		return math.abs(a - 3 * math.pi / 2) < 0.3
	end)
	box(pit, "Baseplate", 173.5, 243.5, 3, 3, 0.2, 0.4, "metal")
	rod(pit, "Tube", Vector3.new(175, 0.6, 245), Vector3.new(175, 5, 241), 0.6, "rubber")
	pit.PrimaryPart = floor
	label(floor, "Mortar pit", 8)
end

-- 14 Ammo supply point: earth berm with one gap to the south ------------------
do
	local asp = folder(camp, "AmmoSupplyPoint", "Model")
	box(asp, "Berm", 209, 264, 72, 7, 0, 8, "berm")
	box(asp, "Berm", 209, 271, 7, 65, 0, 8, "berm")
	box(asp, "Berm", 274, 271, 7, 65, 0, 8, "berm")
	box(asp, "Berm", 216, 329, 25, 7, 0, 8, "berm")
	box(asp, "Berm", 255, 329, 19, 7, 0, 8, "berm")
	local slab = box(asp, "Hardstand", 216, 271, 58, 58, 0, 0.3, "concrete")
	for _, c in ipairs({ { 222, 278 }, { 242, 278 }, { 222, 296 }, { 242, 296 } }) do
		box(asp, "AmmoStack", c[1], c[2], 14, 10, 0.3, 4, "crate")
	end
	asp.PrimaryPart = slab
	label(slab, "Ammo supply point", 12)
end

-- 15 Heliport barrier line, gap where the main road comes through -------------
do
	local line = folder(heli, "BarrierLine")
	for zz = 6, 178, 12 do
		jersey(line, 290, zz + 5.5, 11, false)
	end
	for zz = 210, 342, 12 do
		jersey(line, 290, zz + 5.5, 11, false)
	end
end

-- 16 / 17 Helipads -------------------------------------------------------------
helipad(heli, "Pad 1", 340, 40)
helipad(heli, "Pad 2 (Medevac)", 340, 250)

-- 18 Flight ops tower ----------------------------------------------------------
tower(heli, "Flight Ops Tower", 300, 140, 28, 24, "S", true)

-- 19 Fuel point (FARP): low berm, two bladders, hose out the west gap --------
do
	local farp = folder(heli, "FuelPoint", "Model")
	box(farp, "Berm", 426, 146, 46, 3, 0, 3, "berm")
	box(farp, "Berm", 426, 211, 46, 3, 0, 3, "berm")
	box(farp, "Berm", 469, 149, 3, 62, 0, 3, "berm")
	box(farp, "Berm", 426, 149, 3, 25, 0, 3, "berm")
	box(farp, "Berm", 426, 186, 3, 25, 0, 3, "berm")
	local b1 = box(farp, "FuelBladder", 432, 152, 14, 56, 0, 3, "rubber")
	box(farp, "FuelBladder", 452, 152, 14, 56, 0, 3, "rubber")
	rod(farp, "Hose", Vector3.new(439, 0.5, 180), Vector3.new(412, 0.5, 180), 0.6, "rubber")
	farp.PrimaryPart = b1
	label(b1, "Fuel point (FARP)", 8)
end

-- 20 Aid station + red cross sign ------------------------------------------------
do
	local aid = building(heli, "Aid Station", 298, 222, 34, 26, { kind = "tent", wallH = 8, roofH = 5, door = 6, style = "tent" })
	box(aid, "SignPost", 314.7, 251.7, 0.6, 0.6, 0, 9, "metal")
	box(aid, "Sign", 312, 251.35, 6, 0.3, 6, 6, "white")
	box(aid, "Cross", 314.25, 251.2, 1.5, 0.6, 7, 4, "red")
	box(aid, "Cross", 313, 251.2, 4, 0.6, 8.25, 1.5, "red")
end

-- 21 Windsock --------------------------------------------------------------------
do
	local ws = folder(heli, "Windsock", "Model")
	local pole = box(ws, "Pole", 454.75, 29.75, 0.5, 0.5, 0, 14, "metal")
	box(ws, "Sock", 455.25, 29.3, 5, 1.4, 12.6, 1.4, "orange")
	ws.PrimaryPart = pole
	label(pole, "Windsock", 10)
end

-------------------------------------------------------------------------------

fob.WorldPivot = ORIGIN_CF
fob.Parent = workspace

if recording then
	pcall(function()
		ChangeHistoryService:FinishRecording(recording, Enum.FinalizeRecordingOperation.Commit)
	end)
else
	pcall(function()
		ChangeHistoryService:SetWaypoint("Build FOB")
	end)
end

local count = 0
for _, d in ipairs(fob:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("[FOB] Built Workspace.FOB: %d parts, centred on %s."):format(count, tostring(ORIGIN)))
