--[[
	AURORA BUILDER  --  run this in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Builds a static aurora borealis over the map as Workspace > Aurora. Run it
	again any time: it deletes the old one and rebuilds. Ctrl+Z undoes it.

	WHAT MAKES IT READ AS A REAL AURORA:
	  * OVER EVERYTHING, SEEN FROM ANYWHERE  it fills an AREA x AREA square high
	    above the map. Beams render from both sides, so every direction works;
	    standing under a curtain, its rays converge overhead like the real thing.
	  * SHAPES IN EVERY DIRECTION  a couple of long, gently curving main arcs, plus
	    bands that bend, hook and curl off in their own directions -- the way an
	    active aurora breaks up. Change SEED for a different sky.
	  * BODY  each curtain is several thin sheets spread a little apart, so looking
	    up into one you see a glowing volume, not a single line.
	  * CONTINUOUS SHEETS  the texture is a glowing sheet with finer, brighter rays
	    running through it -- no gaps between rays, which is what made the earlier
	    version look like a comb from below.
	  * VARIATION  height and brightness rise and fall smoothly along every curtain,
	    with bright knots and dim stretches, and sharp folds here and there.

	This is only the LOOK. Motion (rippling, rays racing along, fading with the
	time of day) is for the proper script later.

	TEXTURES: from Assets/Aurora in the GitHub repo. The curtain image is TALL
	(512x1024) because a Beam runs a texture's vertical axis along its length.
]]

local TEXTURES = {
	curtain = "rbxassetid://77412774845819", -- aurora_curtain.png (continuous-sheet version)
	glow    = "rbxassetid://131041612949925", -- aurora_glow.png (only used if GLOW.enabled)
}

-- WHERE. The aurora fills an AREA x AREA square centred over CENTER.
local CENTER = Vector3.new(0, 0, 0)  -- the middle of your map
local AREA = 10000                   -- studs across
local SEED = 7                       -- change for a completely different sky

--[[
	THE MAIN ARCS: long, gentle curves right across the sky, roughly east-west,
	spread north to south. These are the backbone -- the classic aurora.
--]]
local MAIN_ARCS = {
	count = 2,
	length = 9500,            -- studs along each
	altitude = 2000,          -- height of a curtain's middle above CENTER
	height = 2400,            -- how tall (varies along its length)
	bend = 1.2,               -- average turn, degrees per segment (gentle)
	wiggle = 2.5,             -- how much the turning varies along it
	folds = 3,                -- sharp folds along it
	sheets = 2,               -- thin sheets side by side (a number, or a NumberRange to pick from)
	brightness = 1.4,
}

--[[
	THE BANDS: shorter curtains that go off in their own directions -- bending,
	hooking, and now and then curling right round. What makes it look alive.
--]]
local BANDS = {
	count = 5,
	length = NumberRange.new(3000, 6500),
	altitude = NumberRange.new(1900, 2500),
	height = NumberRange.new(1400, 2200),
	bend = 7,                 -- average turn, degrees per segment (either way)
	wiggle = 9,
	curlChance = 0.4,         -- chance a band tightens into a hook / spiral at its end
	folds = 2,
	sheets = NumberRange.new(1, 2), -- each band gets 1 or 2
	brightness = NumberRange.new(0.8, 1.3),
}

local SEGMENT_STUDS = 300   -- length of each beam (shorter = smoother curves, more beams)
local TILE_STUDS = 1100     -- roughly how far one repeat of the curtain texture spans
local SHEET_GAP = 130       -- studs between a curtain's sheets (its thickness)
local RAY_DRIFT = 0.012     -- how fast the rays slide along (0 = still)
local KNOT_CONTRAST = 0.6   -- 0 = even brightness along a curtain, 1 = dark gaps between bright knots
local FOLD_DEPTH = 450      -- how far a fold pushes the curtain sideways

-- A soft haze. OFF: seen from below a flat haze sheet reads as a rectangle.
local GLOW = { enabled = false, altitude = 2300, height = 3000, brightness = 0.5 }

-- Beams orient themselves from their attachments. Right for Studio as tested.
local WIDTH_ALONG_Z = false
local FLIP_VERTICAL = true  -- true: the bright edge lands at the bottom

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
pcall(function() ChangeHistoryService:SetWaypoint("Before Aurora") end)

if TEXTURES.curtain == "rbxassetid://0" then
	warn("[Aurora] TEXTURES.curtain isn't set -- the curtains will be blank.")
end

local old = workspace:FindFirstChild("Aurora")
if old then old:Destroy() end

local folder = Instance.new("Folder")
folder.Name = "Aurora"
folder.Parent = workspace

local rng = Random.new(SEED)
local UP = Vector3.yAxis
local HALF = AREA / 2
local beamCount = 0

local function holderPart(name: string, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Transparency = 1
	p.Size = Vector3.one
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
	b.Segments = 16
	b.Color = ColorSequence.new(Color3.new(1, 1, 1))
	for k, v in pairs(props) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	beamCount += 1
	return b
end

local function pick(v)
	if typeof(v) == "NumberRange" then
		return rng:NextNumber(v.Min, v.Max)
	end
	return v
end

-- Smooth random values along a curtain (0..1): a few sine waves with random
-- phases, so neighbouring points agree and nothing steps.
local function smoothField(count: number, lowFreq: number, highFreq: number)
	local f1, f2, f3 = rng:NextNumber(0.5, 1) * lowFreq, rng:NextNumber(1, 2) * lowFreq, rng:NextNumber(0.6, 1) * highFreq
	local p1, p2, p3 = rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)
	local out = {}
	for i = 0, count do
		local t = i / count
		local v = 0.5 * math.sin(t * 6.283 * f1 + p1) + 0.3 * math.sin(t * 6.283 * f2 + p2) + 0.2 * math.sin(t * 6.283 * f3 + p3)
		out[i + 1] = v * 0.5 + 0.5
	end
	return out
end

local function flatDir(deg: number): Vector3
	local r = math.rad(deg)
	return Vector3.new(math.cos(r), 0, math.sin(r))
end

--[[
	A curtain's centre-line: walk forward SEGMENT_STUDS at a time, turning a little
	each step. The turn follows a smooth random curve around `bend`, and a curling
	band turns harder and harder toward its end (a hook, or a spiral). It's steered
	back in near the edge of the area so nothing wanders off the map. Folds push the
	line sideways sharply in a few places.
--]]
local function wanderPath(start: Vector3, heading: number, length: number, spec)
	local count = math.max(4, math.floor(length / SEGMENT_STUDS + 0.5))
	local turnField = smoothField(count, 1.3, 4)
	local points = {}
	local pos, h = start, heading
	for i = 0, count do
		local t = i / count
		points[i + 1] = pos

		local turn = spec.bend + spec.wiggle * (turnField[i + 1] * 2 - 1)
		if spec.curl then
			turn *= 1 + 3 * t * t -- tightening toward the end
		end

		-- Near the edge of the area, steer back toward the middle.
		local flat = Vector3.new(pos.X - CENTER.X, 0, pos.Z - CENTER.Z)
		local edge = math.max(math.abs(flat.X), math.abs(flat.Z)) / HALF
		if edge > 0.6 and flat.Magnitude > 1 then
			local want = math.deg(math.atan2(-flat.Z, -flat.X))
			local diff = (want - h + 540) % 360 - 180
			turn += math.clamp(diff / 30, -1, 1) * 20 * math.clamp((edge - 0.6) / 0.3, 0, 1)
		end

		h += turn
		pos += flatDir(h) * SEGMENT_STUDS
	end

	-- Tangents, the sideways (outward) direction, and folds along it.
	local folds = {}
	for _ = 1, spec.folds or 0 do
		table.insert(folds, {
			at = rng:NextNumber(0.15, 0.85),
			-- Wide enough to span several beams, so a fold is an S-bend and not a spike.
			width = rng:NextNumber(0.06, 0.11),
			amp = FOLD_DEPTH * rng:NextNumber(0.7, 1.3) * (rng:NextNumber() < 0.5 and -1 or 1),
		})
	end
	local outward = {}
	for i = 1, #points do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		local tangent = Vector3.new(nextP.X - prev.X, 0, nextP.Z - prev.Z).Unit
		outward[i] = UP:Cross(tangent).Unit
	end
	for i = 1, #points do
		local t = (i - 1) / (#points - 1)
		local shift = 0
		for _, f in ipairs(folds) do
			shift += f.amp * math.exp(-((t - f.at) / f.width) ^ 2)
		end
		points[i] += outward[i] * shift
	end
	return points, outward
end

local function buildSheet(model: Model, holder: BasePart, brightness: number, points, heights, knots, sheetIndex: number, sheetBright: number)
	local attachments = {}
	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		attachments[i] = attachmentAt(holder, p, (nextP - prev).Unit)
	end

	local function alphaAt(k: number): number
		if k == 1 or k == #points then
			return 1 -- the whole curtain fades out at both ends
		end
		return math.clamp((1 - knots[k]) * KNOT_CONTRAST, 0, 1)
	end

	for i = 1, #points - 1 do
		local segLen = (points[i + 1] - points[i]).Magnitude
		-- Whole repeats per beam keeps the joins seamless; the sheet index nudges
		-- the count so each sheet's rays sit differently from its neighbours'.
		local repeats = math.max(1, math.floor(segLen / TILE_STUDS * (1 + 0.27 * (sheetIndex - 1)) + 0.5))
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
			Brightness = brightness * sheetBright,
			Transparency = NumberSequence.new(alphaAt(i), alphaAt(i + 1)),
		})
	end
end

-- Sheets: the main one, then fainter ones either side, a little taller or shorter.
local SHEETS = {
	{ offset = 0,     bright = 1.0,  scale = 1.0 },
	{ offset = 1,     bright = 0.6,  scale = 1.1 },
	{ offset = -0.8,  bright = 0.45, scale = 0.9 },
	{ offset = 1.9,   bright = 0.3,  scale = 1.2 },
}

local function buildCurtain(name: string, start: Vector3, heading: number, spec)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = folder

	local length = pick(spec.length)
	local altitude = pick(spec.altitude)
	local height = pick(spec.height)
	local brightness = pick(spec.brightness)
	local walk = {
		bend = spec.bend * (rng:NextNumber() < 0.5 and -1 or 1) * rng:NextNumber(0.5, 1.3),
		wiggle = spec.wiggle,
		curl = spec.curlChance and rng:NextNumber() < spec.curlChance or false,
		folds = spec.folds,
	}

	local base = Vector3.new(start.X, CENTER.Y + altitude, start.Z)
	local holder = holderPart("Anchor", CFrame.new(base), model)
	local points, outward = wanderPath(base, heading, length, walk)

	local count = #points - 1
	local heightField = smoothField(count, 1.5, 4)
	local knots = smoothField(count, 2, 6)
	local heights = {}
	for i = 1, #points do
		heights[i] = height * (0.5 + 0.7 * heightField[i])
		-- A little up-and-down along its length, so the lower edge isn't level.
		points[i] += UP * (height * 0.07 * math.sin(i * 0.37 + altitude))
	end

	local sheetCount = math.clamp(math.floor(pick(spec.sheets or 1) + 0.5), 1, #SHEETS)
	for s = 1, sheetCount do
		local def = SHEETS[s]
		local sheetPoints, sheetHeights = {}, {}
		for i, p in ipairs(points) do
			sheetPoints[i] = p + outward[i] * (def.offset * SHEET_GAP)
			sheetHeights[i] = heights[i] * def.scale
		end
		buildSheet(model, holder, brightness, sheetPoints, sheetHeights, knots, s, def.bright)
	end
end

-- MAIN ARCS: start at the western edge, spread north to south, heading east.
for i = 1, MAIN_ARCS.count do
	local t = (MAIN_ARCS.count == 1) and 0.5 or (i - 1) / (MAIN_ARCS.count - 1)
	local z = CENTER.Z + (t - 0.5) * AREA * 0.45 + rng:NextNumber(-400, 400)
	local start = Vector3.new(CENTER.X - HALF * 0.92, 0, z)
	buildCurtain("Arc" .. i, start, rng:NextNumber(-8, 8), MAIN_ARCS)
end

-- BANDS: anywhere inside the area, any direction.
for i = 1, BANDS.count do
	local start = CENTER + Vector3.new(rng:NextNumber(-HALF, HALF) * 0.55, 0, rng:NextNumber(-HALF, HALF) * 0.55)
	buildCurtain("Band" .. i, start, rng:NextNumber(0, 360), BANDS)
end

-- Optional haze along a gentle arc through the middle.
if GLOW.enabled then
	local model = Instance.new("Model")
	model.Name = "Glow"
	model.Parent = folder
	local base = Vector3.new(CENTER.X - HALF * 0.9, CENTER.Y + GLOW.altitude, CENTER.Z)
	local holder = holderPart("Anchor", CFrame.new(base), model)
	local points = wanderPath(base, 0, AREA * 0.9, { bend = 0.5, wiggle = 1, folds = 0 })
	local attachments = {}
	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		attachments[i] = attachmentAt(holder, p, (nextP - prev).Unit)
	end
	for i = 1, #points - 1 do
		local segLen = (points[i + 1] - points[i]).Magnitude
		makeBeam(attachments[i], attachments[i + 1], model, {
			Name = "Haze" .. i,
			Texture = TEXTURES.glow,
			TextureMode = Enum.TextureMode.Stretch,
			TextureLength = 1,
			Width0 = GLOW.height,
			Width1 = GLOW.height,
			CurveSize0 = segLen * 0.35,
			CurveSize1 = segLen * 0.35,
			Brightness = GLOW.brightness,
			Transparency = NumberSequence.new((i == 1) and 1 or 0, (i == #points - 1) and 1 or 0),
		})
	end
end

pcall(function() ChangeHistoryService:SetWaypoint("Built Aurora") end)
print(("[Aurora] Built %d arcs and %d bands over a %d-stud area: %d beams.")
	:format(MAIN_ARCS.count, BANDS.count, AREA, beamCount))
