--[[
	AuroraShape  --  ModuleScript in ReplicatedStorage > Shared
	------------------------------------------------------------
	Builds and animates the aurora. AuroraClient calls it; nothing else needs to.

	Build(settings) makes a whole sky from a SEED, so every client given the same
	seed builds exactly the same aurora -- the server only has to send a number.
	Everything is random per seed: how many arcs and bands, which way the arcs
	run, their lengths, heights, altitudes, bends, curls, folds, sheets and
	brightness. Only the centre point and the area stay put.

	Update(shape, dt, visibility, surge) moves it: curtains ripple sideways,
	heights breathe, bright patches travel along them, and a surge (a substorm)
	makes everything brighter and faster for a while.

	Same look as Assets/Aurora/AuroraBuilder.luau (the command-bar preview).
]]

local AuroraShape = {}

AuroraShape.TEXTURES = {
	curtain = "rbxassetid://77412774845819", -- aurora_curtain.png (tall, continuous-sheet version)
}

AuroraShape.DEFAULT_AREA = 10000

local SEGMENT_STUDS = 300   -- length of each beam (shorter = smoother curves, more beams)
local TILE_STUDS = 1100     -- roughly how far one repeat of the curtain texture spans
local SHEET_GAP = 130       -- studs between a curtain's sheets (its thickness)
local RAY_DRIFT = 0.012     -- how fast the rays slide along (0 = still)
local KNOT_CONTRAST = 0.6   -- 0 = even brightness along a curtain, 1 = dark gaps between bright knots
local FOLD_DEPTH = 450      -- how far a fold pushes the curtain sideways
local FLIP_VERTICAL = true  -- true: the bright edge lands at the bottom (right for these textures)

-- Motion.
local SPEED = 1                                  -- ONE KNOB for all motion: 0.5 = half as fast, 2 = twice
local WAVE_AMP = NumberRange.new(50, 120)        -- studs a curtain ripples sideways
local WAVE_PERIOD = NumberRange.new(70, 140)     -- seconds for a ripple to pass
local HEIGHT_BREATHE = 0.08                      -- how much heights rise and fall (fraction)
local HEIGHT_PERIOD = NumberRange.new(80, 160)   -- seconds per rise and fall
local PULSE = NumberRange.new(0.06, 0.14)        -- bright patches drifting along (fraction)
local PULSE_PERIOD = NumberRange.new(90, 180)    -- seconds for a bright patch to drift past
local SURGE_BRIGHT = 1.0                         -- extra brightness at a full surge (x power)
local SURGE_MOTION = 0.6                         -- extra ripple size and speed at a full surge

--[[
	What each kind of night looks like. Counts are {min, max}; the rest scale the
	base shapes below. sheets2 = chance a curtain gets a second sheet.
--]]
local ACTIVITY = {
	Quiet  = { arcs = { 1, 1 }, bands = { 1, 3 }, bright = 0.7,  height = 0.85, bend = 0.7, curl = 0.15, arcSheets2 = 0.3, bandSheets2 = 0.15, motion = 0.6 },
	Active = { arcs = { 1, 2 }, bands = { 3, 5 }, bright = 1.0,  height = 1.0,  bend = 1.0, curl = 0.4,  arcSheets2 = 0.7, bandSheets2 = 0.4,  motion = 0.8 },
	Storm  = { arcs = { 2, 3 }, bands = { 5, 7 }, bright = 1.3,  height = 1.15, bend = 1.3, curl = 0.6,  arcSheets2 = 1.0, bandSheets2 = 0.6,  motion = 1.0 },
}
AuroraShape.ACTIVITY = ACTIVITY

-- Base shapes (from the preview builder), randomised per night inside these ranges.
local ARC = {
	length = NumberRange.new(0.8, 0.95),      -- fraction of the area
	altitude = NumberRange.new(-150, 150),    -- around the night's altitude
	height = NumberRange.new(2000, 2600),
	bend = NumberRange.new(0.6, 1.6),         -- degrees per segment, either way
	wiggle = 2.5,
	folds = { 2, 4 },
	brightness = NumberRange.new(1.2, 1.5),
}
local BAND = {
	length = NumberRange.new(3000, 6500),     -- at a 10000 area; scales with it
	altitude = NumberRange.new(-200, 350),
	height = NumberRange.new(1400, 2200),
	bend = NumberRange.new(3.5, 9),
	wiggle = 9,
	folds = { 1, 3 },
	brightness = NumberRange.new(0.8, 1.3),
}
local NIGHT_ALTITUDE = NumberRange.new(1850, 2250) -- height of the display's middle above the centre
local ARC_SWING = 30                               -- arcs run along the centre part's facing, +- this many degrees

-- Sheets: the main one, then a fainter one beside it, a little taller.
local SHEETS = {
	{ offset = 0, bright = 1.0, scale = 1.0 },
	{ offset = 1, bright = 0.6, scale = 1.1 },
}

local UP = Vector3.yAxis
local TAU = math.pi * 2

-------------------------------------------------------------------------------

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
	local a = Instance.new("Attachment")
	a.Parent = parent
	a.WorldCFrame = CFrame.fromMatrix(pos, tangent, up)
	return a
end

local function makeBeam(a0: Attachment, a1: Attachment, parent: Instance, props): Beam
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
	return b
end

local function flatDir(deg: number): Vector3
	local r = math.rad(deg)
	return Vector3.new(math.cos(r), 0, math.sin(r))
end

-- Everything random for one sky comes from this rng, in a fixed order, so the
-- same seed always gives the same sky on every client.
local function newSky(rng: Random, center: Vector3, yaw: number, area: number)
	local sky = { rng = rng, center = center, half = area / 2, area = area }

	function sky.pick(v)
		if typeof(v) == "NumberRange" then
			return rng:NextNumber(v.Min, v.Max)
		elseif type(v) == "table" then
			return rng:NextInteger(v[1], v[2])
		end
		return v
	end

	function sky.sign()
		return rng:NextNumber() < 0.5 and -1 or 1
	end

	-- Smooth random values along a curtain (0..1): a few sine waves with random
	-- phases, so neighbouring points agree and nothing steps.
	function sky.smoothField(count: number, lowFreq: number, highFreq: number)
		local f1, f2, f3 = rng:NextNumber(0.5, 1) * lowFreq, rng:NextNumber(1, 2) * lowFreq, rng:NextNumber(0.6, 1) * highFreq
		local p1, p2, p3 = rng:NextNumber(0, TAU), rng:NextNumber(0, TAU), rng:NextNumber(0, TAU)
		local out = {}
		for i = 0, count do
			local t = i / count
			local v = 0.5 * math.sin(t * TAU * f1 + p1) + 0.3 * math.sin(t * TAU * f2 + p2) + 0.2 * math.sin(t * TAU * f3 + p3)
			out[i + 1] = v * 0.5 + 0.5
		end
		return out
	end

	-- The frame the area is laid out in: X along the arcs, Z across them.
	sky.heading = yaw + rng:NextNumber(-ARC_SWING, ARC_SWING)
	sky.axisX = flatDir(sky.heading)
	sky.axisZ = flatDir(sky.heading + 90)
	sky.altitude = sky.pick(NIGHT_ALTITUDE)
	return sky
end

--[[
	A curtain's centre-line: walk forward SEGMENT_STUDS at a time, turning a little
	each step. The turn follows a smooth random curve around `bend`, and a curling
	band turns harder and harder toward its end (a hook, or a spiral). It's steered
	back in near the edge of the area so nothing wanders off. Folds push the line
	sideways sharply in a few places.
--]]
local function wanderPath(sky, start: Vector3, heading: number, length: number, walk)
	local rng = sky.rng
	local count = math.max(4, math.floor(length / SEGMENT_STUDS + 0.5))
	local turnField = sky.smoothField(count, 1.3, 4)
	local points = {}
	local pos, h = start, heading
	for i = 0, count do
		local t = i / count
		points[i + 1] = pos

		local turn = walk.bend + walk.wiggle * (turnField[i + 1] * 2 - 1)
		if walk.curl then
			turn *= 1 + 3 * t * t -- tightening toward the end
		end

		-- Near the edge of the area (a square turned to the arcs), steer back in.
		local flat = Vector3.new(pos.X - sky.center.X, 0, pos.Z - sky.center.Z)
		local edge = math.max(math.abs(flat:Dot(sky.axisX)), math.abs(flat:Dot(sky.axisZ))) / sky.half
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
	for _ = 1, walk.folds do
		table.insert(folds, {
			at = rng:NextNumber(0.15, 0.85),
			-- Wide enough to span several beams, so a fold is an S-bend and not a spike.
			width = rng:NextNumber(0.06, 0.11),
			amp = FOLD_DEPTH * rng:NextNumber(0.7, 1.3) * sky.sign(),
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

local function buildSheet(model: Model, holder: BasePart, points, heights, knots, sheetIndex: number, brightness: number)
	local sheet = { attachments = {}, basePos = {}, heights = heights, beams = {}, bright = brightness }

	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		local a = attachmentAt(holder, p, (nextP - prev).Unit)
		sheet.attachments[i] = a
		sheet.basePos[i] = a.Position
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
		-- the count so each sheet's rays sit differently from its neighbour's.
		local repeats = math.max(1, math.floor(segLen / TILE_STUDS * (1 + 0.27 * (sheetIndex - 1)) + 0.5))
		sheet.beams[i] = makeBeam(sheet.attachments[i], sheet.attachments[i + 1], model, {
			Name = ("Sheet%d_%d"):format(sheetIndex, i),
			Texture = AuroraShape.TEXTURES.curtain,
			TextureMode = Enum.TextureMode.Stretch,
			TextureLength = repeats,
			TextureSpeed = RAY_DRIFT * repeats * (1 + 0.15 * (sheetIndex - 1)),
			Width0 = heights[i],
			Width1 = heights[i + 1],
			CurveSize0 = segLen * 0.35,
			CurveSize1 = segLen * 0.35,
			Brightness = 0, -- Update() sets it
			Transparency = NumberSequence.new(alphaAt(i), alphaAt(i + 1)),
		})
	end
	return sheet
end

local function buildCurtain(sky, folder: Instance, name: string, start: Vector3, heading: number, spec)
	local rng = sky.rng
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = folder

	local base = Vector3.new(start.X, sky.center.Y + spec.altitude, start.Z)
	local holder = holderPart("Anchor", CFrame.new(base), model)
	local points, outward = wanderPath(sky, base, heading, spec.length, spec)

	local count = #points - 1
	local heightField = sky.smoothField(count, 1.5, 4)
	local knots = sky.smoothField(count, 2, 6)
	local heights = {}
	for i = 1, #points do
		heights[i] = spec.height * (0.5 + 0.7 * heightField[i])
		-- A little up-and-down along its length, so the lower edge isn't level.
		points[i] += UP * (spec.height * 0.07 * math.sin(i * 0.37 + spec.altitude))
	end

	local curtain = {
		model = model,
		sheets = {},
		outward = outward,
		count = #points,
		-- Motion, all random per curtain.
		phase = rng:NextNumber(0, TAU),
		waveAmp = sky.pick(WAVE_AMP),
		waveSpeed = TAU / sky.pick(WAVE_PERIOD),
		waveCount = rng:NextNumber(1.5, 3.5) * (#points / 30),
		heightSpeed = TAU / sky.pick(HEIGHT_PERIOD),
		heightWaves = rng:NextNumber(1, 2.5),
		pulse = sky.pick(PULSE),
		pulseSpeed = TAU / sky.pick(PULSE_PERIOD) * sky.sign(),
		pulseWaves = rng:NextNumber(1, 2.5),
		-- Reused every Update so nothing is allocated per frame.
		offsets = table.create(#points, Vector3.zero),
		scales = table.create(#points, 1),
		glows = table.create(#points, 1),
	}

	for s = 1, spec.sheets do
		local def = SHEETS[s]
		local sheetPoints, sheetHeights = {}, {}
		for i, p in ipairs(points) do
			sheetPoints[i] = p + outward[i] * (def.offset * SHEET_GAP)
			sheetHeights[i] = heights[i] * def.scale
		end
		curtain.sheets[s] = buildSheet(model, holder, sheetPoints, sheetHeights, knots, s, spec.brightness * def.bright)
	end
	return curtain
end

--[[
	settings = {
		seed     = number,             same seed -> same sky
		activity = "Quiet" | "Active" | "Storm",
		center   = Vector3,            the middle of the display
		yaw      = number,             degrees; the arcs run roughly along this
		area     = number?,            studs across (default 10000)
		yield    = boolean?,           pause a frame between curtains
	}
	Returns a shape table: shape.folder is a Folder, NOT parented -- parent it
	to workspace yourself once Build returns.
--]]
function AuroraShape.Build(settings)
	local act = ACTIVITY[settings.activity] or ACTIVITY.Active
	local area = settings.area or AuroraShape.DEFAULT_AREA
	local scale = area / 10000
	local sky = newSky(Random.new(settings.seed), settings.center, settings.yaw or 0, area)
	local pick = sky.pick

	local folder = Instance.new("Folder")
	folder.Name = "AuroraSky"

	local shape = { folder = folder, curtains = {}, clock = 0, enabled = true, motion = act.motion }

	-- MAIN ARCS: start at one side of the area, spread across it, running along
	-- the night's heading.
	local arcCount = pick(act.arcs)
	for i = 1, arcCount do
		local t = (arcCount == 1) and 0.5 or (i - 1) / (arcCount - 1)
		local across = (t - 0.5) * area * 0.45 + sky.rng:NextNumber(-400, 400) * scale
		local start = sky.center - sky.axisX * (sky.half * 0.92) + sky.axisZ * across
		local spec = {
			length = pick(ARC.length) * area,
			altitude = sky.altitude + pick(ARC.altitude),
			height = pick(ARC.height) * act.height,
			bend = pick(ARC.bend) * sky.sign(),
			wiggle = ARC.wiggle,
			curl = false,
			folds = pick(ARC.folds),
			sheets = sky.rng:NextNumber() < act.arcSheets2 and 2 or 1,
			brightness = pick(ARC.brightness) * act.bright,
		}
		table.insert(shape.curtains, buildCurtain(sky, folder, "Arc" .. i, start, sky.heading + sky.rng:NextNumber(-8, 8), spec))
		if settings.yield then task.wait() end
	end

	-- BANDS: anywhere inside the area, any direction.
	local bandCount = pick(act.bands)
	for i = 1, bandCount do
		local start = sky.center
			+ sky.axisX * (sky.rng:NextNumber(-1, 1) * sky.half * 0.55)
			+ sky.axisZ * (sky.rng:NextNumber(-1, 1) * sky.half * 0.55)
		local spec = {
			length = pick(BAND.length) * scale,
			altitude = sky.altitude + pick(BAND.altitude),
			height = pick(BAND.height) * act.height,
			bend = pick(BAND.bend) * act.bend * sky.sign(),
			wiggle = BAND.wiggle * act.bend,
			curl = sky.rng:NextNumber() < act.curl,
			folds = pick(BAND.folds),
			sheets = sky.rng:NextNumber() < act.bandSheets2 and 2 or 1,
			brightness = pick(BAND.brightness) * act.bright,
		}
		table.insert(shape.curtains, buildCurtain(sky, folder, "Band" .. i, start, sky.rng:NextNumber(0, 360), spec))
		if settings.yield then task.wait() end
	end

	return shape
end

local function setEnabled(shape, on: boolean)
	shape.enabled = on
	for _, c in ipairs(shape.curtains) do
		for _, sheet in ipairs(c.sheets) do
			for _, b in ipairs(sheet.beams) do
				b.Enabled = on
			end
		end
	end
end

--[[
	visibility: 0 = gone, 1 = full (night, clear sky, inside tonight's window).
	surge:      0 = calm, higher = a substorm flaring (about 0..1.5).
--]]
function AuroraShape.Update(shape, dt: number, visibility: number, surge: number)
	if visibility <= 0.002 then
		if shape.enabled then setEnabled(shape, false) end
		return
	end
	if not shape.enabled then setEnabled(shape, true) end

	local motion = SPEED * shape.motion * (1 + surge * SURGE_MOTION)
	shape.clock += dt * motion
	local t = shape.clock
	local glowMul = visibility * (1 + surge * SURGE_BRIGHT)

	for _, c in ipairs(shape.curtains) do
		local n = c.count
		local amp = c.waveAmp * (1 + surge * SURGE_MOTION) / 1.5
		local offsets, scales, glows, outward = c.offsets, c.scales, c.glows, c.outward
		for i = 1, n do
			local u = (i - 1) / (n - 1)
			local w = math.sin(u * c.waveCount * TAU - t * c.waveSpeed + c.phase)
				+ 0.5 * math.sin(u * c.waveCount * 2.3 * TAU + t * c.waveSpeed * 1.7 + c.phase * 2)
			offsets[i] = outward[i] * (w * amp)
			scales[i] = 1 + HEIGHT_BREATHE * math.sin(u * c.heightWaves * TAU - t * c.heightSpeed + c.phase * 3)
			glows[i] = 1 + c.pulse * math.sin(u * c.pulseWaves * TAU - t * c.pulseSpeed + c.phase * 1.3)
		end
		for _, sheet in ipairs(c.sheets) do
			local atts, basePos, heights, beams = sheet.attachments, sheet.basePos, sheet.heights, sheet.beams
			for i = 1, n do
				atts[i].Position = basePos[i] + offsets[i]
			end
			local bright = sheet.bright * glowMul
			for i = 1, n - 1 do
				local b = beams[i]
				b.Width0 = heights[i] * scales[i]
				b.Width1 = heights[i + 1] * scales[i + 1]
				b.Brightness = bright * (glows[i] + glows[i + 1]) * 0.5
			end
		end
	end
end

function AuroraShape.Destroy(shape)
	if shape and shape.folder then
		shape.folder:Destroy()
	end
end

return AuroraShape
