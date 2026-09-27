--[[
	AURORA BUILDER  --  run this in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Builds a static aurora borealis as Workspace > Aurora. Run it again any time:
	it deletes the old one and rebuilds. Ctrl+Z undoes it.

	WHAT MAKES IT READ AS A REAL AURORA (each is a setting below):
	  * OVERHEAD ARCS  real auroras are enormous, roughly parallel arcs across the
	    whole sky. The curtains here span the map east-west, spread north to south
	    over it, so from anywhere you look up into them -- from any direction.
	    Standing under one, its rays converge overhead like the real thing.
	  * SHEETS  a real curtain isn't one flat sheet -- it's several thin ones just
	    behind each other, each with its own rays. That's the depth.
	  * BRIGHT KNOTS AND DIM STRETCHES  brightness varies smoothly along each
	    curtain instead of being even.
	  * FOLDS  curtains fold back on themselves; the brightness piles up where the
	    sheet overlaps itself.

	This is only the LOOK. Motion (rippling, rays racing along, fading with the
	time of day) is for the proper script later.

	TEXTURES: uploaded from Assets/Aurora in the GitHub repo. The curtain and glow
	images are TALL (512x1024) because a Beam runs a texture's vertical axis along
	its length.
]]

local TEXTURES = {
	curtain = "rbxassetid://87891058414431",  -- aurora_curtain.png (the tall one)
	glow    = "rbxassetid://131041612949925", -- aurora_glow.png (re-upload the tall one if the haze looks sideways)
}

-- WHERE. Centred over CENTER. DIRECTION is the way the arcs are spread (they run
-- across it); -Z is "north" in Studio, so by default they run east-west.
local CENTER    = Vector3.new(0, 0, 0)       -- the middle of your map
local DIRECTION = Vector3.new(0, 0, -1)
local SEED      = 7                          -- change for a differently shaped aurora

--[[
	THE CURTAINS, north to south across the map.
	  offset     studs from CENTER toward DIRECTION (negative = the other side)
	  radius     radius of the arc it follows (bigger = straighter). Its ends bend
	             back toward the south, like a real auroral arc
	  length     studs along the arc
	  altitude   height of the curtain's middle above CENTER
	  height     how tall the curtain is (varies along its length)
	  wave       how much it meanders in and out
	  folds      how many sharp folds it has
	  sheets     thin sheets per curtain (depth). 1-3
	  brightness overall strength
--]]
local CURTAINS = {
	{ offset = 2600,  radius = 9000,  length = 6500, altitude = 1900, height = 1100,
		wave = 280, folds = 2, sheets = 2, brightness = 1.3 },
	{ offset = 1300,  radius = 8000,  length = 7000, altitude = 1750, height = 1300,
		wave = 320, folds = 3, sheets = 3, brightness = 2.2 },
	{ offset = 0,     radius = 8500,  length = 7000, altitude = 1650, height = 1400,
		wave = 260, folds = 2, sheets = 3, brightness = 2.4 },
	{ offset = -1400, radius = 9500,  length = 6800, altitude = 1800, height = 1200,
		wave = 300, folds = 2, sheets = 2, brightness = 1.6 },
	{ offset = -2700, radius = 11000, length = 6000, altitude = 2000, height = 900,
		wave = 240, folds = 1, sheets = 1, brightness = 0.9 },
}

-- A soft haze along one extra arc. OFF: seen from below or side-on, a flat haze
-- sheet reads as a glowing rectangle. Set enabled = true to try it.
local GLOW = { enabled = false, offset = 0, radius = 9000, length = 9000, altitude = 2100, height = 2600, brightness = 0.6 }

local SEGMENT_STUDS = 320   -- length of each beam along a curtain (shorter = smoother folds, more beams)
local TILE_STUDS = 1300     -- roughly how far one repeat of the curtain texture spans
local SHEET_GAP = 70        -- studs between a curtain's sheets
local RAY_DRIFT = 0.012     -- how fast the rays slide along (0 = still)
local KNOT_CONTRAST = 0.75  -- 0 = even brightness along a curtain, 1 = dark gaps between bright knots

-- Beams orient themselves from their attachments. These are right for Studio as
-- tested; the switches are here in case a future texture flips.
local WIDTH_ALONG_Z = false
local FLIP_VERTICAL = true  -- true: the bright edge lands at the bottom

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
pcall(function() ChangeHistoryService:SetWaypoint("Before Aurora") end)

for name, id in pairs(TEXTURES) do
	if id == "rbxassetid://0" then
		warn(("[Aurora] TEXTURES.%s isn't set -- that layer will be blank."):format(name))
	end
end

local old = workspace:FindFirstChild("Aurora")
if old then old:Destroy() end

local folder = Instance.new("Folder")
folder.Name = "Aurora"
folder.Parent = workspace

local rng = Random.new(SEED)
local UP = Vector3.yAxis
local forward = Vector3.new(DIRECTION.X, 0, DIRECTION.Z).Unit
local side = forward:Cross(UP).Unit
local beamCount = 0

local function holderPart(name: string, cf: CFrame, size: Vector3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- An attachment whose Axis runs along the curtain and whose width axis is vertical.
local function attachmentAt(parent: BasePart, pos: Vector3, tangent: Vector3): Attachment
	local up = FLIP_VERTICAL and -UP or UP
	local cf
	if WIDTH_ALONG_Z then
		cf = CFrame.fromMatrix(pos, tangent, up:Cross(tangent).Unit, up)
	else
		cf = CFrame.fromMatrix(pos, tangent, up)
	end
	local a = Instance.new("Attachment")
	a.Parent = parent
	a.WorldCFrame = cf
	return a
end

local function makeBeam(a0: Attachment, a1: Attachment, parent: Instance, props)
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.FaceCamera = false
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Segments = 20
	b.Color = ColorSequence.new(Color3.new(1, 1, 1))
	for k, v in pairs(props) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	beamCount += 1
	return b
end

-- Smooth random values along a curtain: a few sine waves with random phases, so
-- neighbouring points agree and nothing steps.
local function smoothField(count: number, lowFreq: number, highFreq: number)
	local f1, f2, f3 = rng:NextNumber(0.5, 1) * lowFreq, rng:NextNumber(1, 2) * lowFreq, rng:NextNumber(0.6, 1) * highFreq
	local p1, p2, p3 = rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)
	local out = {}
	for i = 0, count do
		local t = i / count
		local v = 0.5 * math.sin(t * 6.283 * f1 + p1) + 0.3 * math.sin(t * 6.283 * f2 + p2) + 0.2 * math.sin(t * 6.283 * f3 + p3)
		out[i + 1] = v * 0.5 + 0.5 -- 0..1
	end
	return out
end

--[[
	The centre-line of one curtain: points along an arc of `radius` whose middle
	sits `offset` toward DIRECTION, meandering in and out (`wave`) with a few sharp folds.
	Returns the points and the outward (away from CENTER) direction at each, which
	is what the sheets are offset along.
--]]
local function arcPath(spec, count: number)
	local arcCenter = CENTER + forward * (spec.offset - spec.radius)
	local halfAngle = (spec.length / 2) / spec.radius
	local meander = smoothField(count, 1.2, 3)

	-- Folds: tight bumps at random places along the arc, pushing the sheet back
	-- and forth sharply.
	local folds = {}
	for _ = 1, spec.folds or 0 do
		table.insert(folds, {
			at = rng:NextNumber(0.15, 0.85),
			width = rng:NextNumber(0.025, 0.05),
			amp = spec.wave * rng:NextNumber(1.2, 2.0) * (rng:NextNumber() < 0.5 and -1 or 1),
		})
	end

	local points, outward = {}, {}
	for i = 0, count do
		local t = i / count
		local angle = -halfAngle + t * halfAngle * 2
		local dir = forward * math.cos(angle) + side * math.sin(angle)
		local depth = spec.wave * (meander[i + 1] * 2 - 1)
		for _, f in ipairs(folds) do
			depth += f.amp * math.exp(-((t - f.at) / f.width) ^ 2)
		end
		local rise = spec.height * 0.06 * math.sin(t * 9.42 + spec.offset)
		points[i + 1] = arcCenter + dir * (spec.radius + depth) + UP * (spec.altitude + rise)
		outward[i + 1] = dir
	end
	return points, outward
end

local function buildSheet(model: Model, holder: BasePart, spec, points, heights, knots, sheetIndex: number, sheetBright: number)
	local attachments = {}
	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		attachments[i] = attachmentAt(holder, p, (nextP - prev).Unit)
	end

	for i = 1, #points - 1 do
		local segLen = (points[i + 1] - points[i]).Magnitude
		-- Whole repeats per beam keeps the joins seamless; the sheet index nudges
		-- the count so each sheet's rays sit differently from its neighbours'.
		local repeats = math.max(1, math.floor(segLen / TILE_STUDS * (1 + 0.23 * (sheetIndex - 1)) + 0.5))

		-- Brightness knots along the curtain, as transparency so it blends smoothly
		-- across each beam instead of stepping at the joins. The ends of the whole
		-- curtain fade right out.
		local function alphaAt(k: number): number
			local a = (1 - knots[k]) * KNOT_CONTRAST
			if k == 1 or k == #points then a = 1 end
			return math.clamp(a, 0, 1)
		end
		local transparency = NumberSequence.new(alphaAt(i), alphaAt(i + 1))

		makeBeam(attachments[i], attachments[i + 1], model, {
			Name = ("Sheet%d_%d"):format(sheetIndex, i),
			Texture = TEXTURES.curtain,
			TextureMode = Enum.TextureMode.Stretch,
			TextureLength = repeats,
			TextureSpeed = RAY_DRIFT * repeats * (1 + 0.15 * (sheetIndex - 1)),
			Width0 = heights[i],
			Width1 = heights[i + 1],
			CurveSize0 = segLen * 0.35,
			CurveSize1 = segLen * 0.35,
			Brightness = spec.brightness * sheetBright,
			Transparency = transparency,
		})
	end
end

local function buildCurtain(index: number, spec)
	local model = Instance.new("Model")
	model.Name = "Curtain" .. index
	model.Parent = folder

	local holder = holderPart("Anchor", CFrame.new(CENTER + forward * spec.offset + UP * spec.altitude), Vector3.one, model)
	local count = math.max(4, math.floor(spec.length / SEGMENT_STUDS + 0.5))
	local points, outward = arcPath(spec, count)

	-- Height rises and falls smoothly along the curtain; brightness knots too.
	local heightField = smoothField(count, 1.5, 4)
	local knots = smoothField(count, 2, 6)
	local heights = {}
	for i = 1, #points do
		heights[i] = spec.height * (0.55 + 0.75 * heightField[i])
	end

	-- Sheets: the main one, then fainter ones just behind (and one just in front),
	-- slightly taller or shorter, each with its own ray pattern.
	local sheetDefs = {
		{ offset = 0, bright = 1.0, scale = 1.0 },
		{ offset = SHEET_GAP, bright = 0.55, scale = 1.12 },
		{ offset = -SHEET_GAP * 0.7, bright = 0.4, scale = 0.85 },
	}
	for s = 1, math.clamp(spec.sheets or 1, 1, 3) do
		local def = sheetDefs[s]
		local sheetPoints, sheetHeights = {}, {}
		for i, p in ipairs(points) do
			sheetPoints[i] = p + outward[i] * def.offset
			sheetHeights[i] = heights[i] * def.scale
		end
		buildSheet(model, holder, spec, sheetPoints, sheetHeights, knots, s, def.bright)
	end
end

-- The haze: one long soft arc, in a few beams so it bends. Off by default.
if GLOW.enabled then
	local model = Instance.new("Model")
	model.Name = "Glow"
	model.Parent = folder
	local holder = holderPart("Anchor", CFrame.new(CENTER + forward * GLOW.offset + UP * GLOW.altitude), Vector3.one, model)
	local spec = { offset = GLOW.offset, radius = GLOW.radius, length = GLOW.length,
		altitude = GLOW.altitude, height = GLOW.height, wave = 150, folds = 0 }
	local count = 6
	local points = arcPath(spec, count)
	local attachments = {}
	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		attachments[i] = attachmentAt(holder, p, (nextP - prev).Unit)
	end
	for i = 1, count do
		local segLen = (points[i + 1] - points[i]).Magnitude
		local t0 = (i == 1) and 1 or 0
		local t1 = (i == count) and 1 or 0
		makeBeam(attachments[i], attachments[i + 1], model, {
			Name = "Haze" .. i,
			Texture = TEXTURES.glow,
			TextureMode = Enum.TextureMode.Stretch,
			TextureLength = 1,
			TextureSpeed = RAY_DRIFT * 0.3,
			Width0 = GLOW.height,
			Width1 = GLOW.height,
			CurveSize0 = segLen * 0.35,
			CurveSize1 = segLen * 0.35,
			Brightness = GLOW.brightness,
			Transparency = NumberSequence.new(t0, t1),
			ZOffset = -10,
		})
	end
end

for i, spec in ipairs(CURTAINS) do
	buildCurtain(i, spec)
end

pcall(function() ChangeHistoryService:SetWaypoint("Built Aurora") end)
print(("[Aurora] Built %d curtains over the map: %d beams."):format(#CURTAINS, beamCount))
