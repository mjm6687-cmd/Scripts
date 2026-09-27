--[[
	AURORA BUILDER  --  run this in Studio's COMMAND BAR (View > Command Bar)
	-------------------------------------------------------------------------
	Builds a static aurora borealis in the sky as Workspace > Aurora. Run it again
	any time: it deletes the old one and rebuilds. Ctrl+Z undoes it.

	Made of three layers, all glowing (additive, unaffected by lighting):
	  GLOW      one wide, soft haze behind everything
	  CURTAINS  long wavy ribbons (Beams) with the curtain texture -- the shape,
	            the sharp green lower edge and the rays. The rays drift slowly.
	  SHIMMER   tall thin particles flickering along each curtain's lower edge --
	            the "one ParticleEmitter" trick, which is what makes it look alive

	BEFORE RUNNING: upload the three textures (Assets/Aurora/*.png in the GitHub
	repo) with View > Asset Manager > Import, right-click each one > Copy Asset ID,
	and paste the ids into TEXTURES below.

	This is only the LOOK. Movement, fading with the time of day and so on are for
	the proper script later -- every tunable is up here so you can shape it first.
]]

local TEXTURES = {
	curtain = "rbxassetid://0", -- aurora_curtain.png
	glow    = "rbxassetid://0", -- aurora_glow.png
	ray     = "rbxassetid://0", -- aurora_ray.png
}

-- Where it hangs. It's built around CENTER, DISTANCE studs away toward DIRECTION
-- (a flat direction; -Z is "north" in Studio's default view).
local CENTER    = Vector3.new(0, 0, 0)       -- roughly the middle of your map
local DIRECTION = Vector3.new(0, 0, -1)
local DISTANCE  = 2200                       -- studs from CENTER to the front curtain
local SEED      = 7                          -- change for a differently shaped aurora

-- Each curtain: how far back (added to DISTANCE), how high, how long, how tall,
-- how wavy, how bright. Front ones brighter and lower, back ones fainter and higher.
local CURTAINS = {
	{ back = 0,    altitude = 700,  length = 4200, height = 520, wave = 380, brightness = 2.2 },
	{ back = 450,  altitude = 820,  length = 3600, height = 420, wave = 300, brightness = 1.5 },
	{ back = 950,  altitude = 950,  length = 3200, height = 360, wave = 260, brightness = 1.0 },
	{ back = 1500, altitude = 1080, length = 2800, height = 300, wave = 200, brightness = 0.7 },
}

local GLOW = { back = 1200, altitude = 900, length = 6000, height = 1100, brightness = 0.9 }

local SEGMENTS_PER_CURTAIN = 5     -- beams chained per curtain (more = wavier)
local TILE_STUDS = 900             -- one repeat of the curtain texture spans this many studs
local RAY_DRIFT = 0.015            -- how fast the rays slide along the curtain (0 = still)

local SHIMMER = true
local SHIMMER_RATE = 5             -- particles per second per curtain segment
local SHIMMER_LIFETIME = NumberRange.new(3, 6)
local SHIMMER_SIZE = 140           -- studs; squashed into a tall thin streak

--[[
	TWO SWITCHES IN CASE IT COMES OUT WRONG (Beams orient themselves from their
	attachments, and which way is "up" in a texture varies):
	  * curtains lying FLAT, like a ribbon on the ground  -> WIDTH_ALONG_Z = true
	  * bright edge at the TOP instead of the bottom      -> FLIP_VERTICAL = true
--]]
local WIDTH_ALONG_Z = false
local FLIP_VERTICAL = false

-------------------------------------------------------------------------------

local ChangeHistoryService = game:GetService("ChangeHistoryService")
pcall(function() ChangeHistoryService:SetWaypoint("Before Aurora") end)

for name, id in pairs(TEXTURES) do
	if id == "rbxassetid://0" then
		warn(("[Aurora] TEXTURES.%s isn't set -- that layer will be blank until you paste its id."):format(name))
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

local function holderPart(name: string, cf: CFrame, size: Vector3): Part
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
	p.Parent = folder
	return p
end

-- An attachment whose X (Axis) runs along the curtain and whose width axis points up.
local function attachmentAt(parent: BasePart, pos: Vector3, tangent: Vector3): Attachment
	local up = FLIP_VERTICAL and -UP or UP
	local cf
	if WIDTH_ALONG_Z then
		local y = up:Cross(tangent).Unit
		cf = CFrame.fromMatrix(pos, tangent, y, up)
	else
		cf = CFrame.fromMatrix(pos, tangent, up)
	end
	local a = Instance.new("Attachment")
	a.Parent = parent
	a.WorldCFrame = cf
	return a
end

local function glowBeam(a0: Attachment, a1: Attachment, parent: Instance, props)
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.FaceCamera = false
	b.LightEmission = 1
	b.LightInfluence = 0
	b.Segments = 24
	b.Color = ColorSequence.new(Color3.new(1, 1, 1))
	for k, v in pairs(props) do
		(b :: any)[k] = v
	end
	b.Parent = parent
	return b
end

-- A wavy line of points for one curtain, sideways across the view.
local function curtainPoints(base: Vector3, length: number, wave: number, count: number)
	local points = {}
	local f1, f2 = rng:NextNumber(0.6, 1.4), rng:NextNumber(1.6, 2.8)
	local p1, p2 = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, math.pi * 2)
	for i = 0, count do
		local t = i / count
		local along = (t - 0.5) * length
		local depth = wave * (math.sin(t * math.pi * 2 * f1 + p1) * 0.7 + math.sin(t * math.pi * 2 * f2 + p2) * 0.3)
		local rise = wave * 0.15 * math.sin(t * math.pi * 3 + p2)
		table.insert(points, base + side * along + forward * depth + UP * rise)
	end
	return points
end

local function buildCurtain(index: number, spec)
	local model = Instance.new("Model")
	model.Name = "Curtain" .. index
	model.Parent = folder

	local base = CENTER + forward * (DISTANCE + spec.back) + UP * spec.altitude
	local holder = holderPart("Anchor", CFrame.new(base), Vector3.one)
	holder.Parent = model

	local points = curtainPoints(base, spec.length, spec.wave, SEGMENTS_PER_CURTAIN)
	local attachments, widths = {}, {}
	for i, p in ipairs(points) do
		local prev = points[math.max(i - 1, 1)]
		local nextP = points[math.min(i + 1, #points)]
		local tangent = (nextP - prev).Unit
		attachments[i] = attachmentAt(holder, p, tangent)
		-- Each point gets its own height, shared by the beams either side, so the
		-- curtain rises and falls smoothly along its length.
		widths[i] = spec.height * rng:NextNumber(0.75, 1.2)
	end

	for i = 1, #points - 1 do
		local segLen = (points[i + 1] - points[i]).Magnitude
		-- Stretch mode with a WHOLE number of repeats per beam: every beam ends
		-- exactly where the (seamlessly tiling) texture wraps, so the joins between
		-- beams don't show.
		local repeats = math.max(1, math.floor(segLen / TILE_STUDS + 0.5))

		-- Fade the two ends of the whole curtain out, rather than stopping dead.
		local t0 = (i == 1) and 1 or 0
		local t1 = (i == #points - 1) and 1 or 0
		local transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, t0),
			NumberSequenceKeypoint.new(0.35, 0),
			NumberSequenceKeypoint.new(0.65, 0),
			NumberSequenceKeypoint.new(1, t1),
		})

		glowBeam(attachments[i], attachments[i + 1], model, {
			Name = "Segment" .. i,
			Texture = TEXTURES.curtain,
			TextureMode = Enum.TextureMode.Stretch,
			TextureLength = repeats,
			TextureSpeed = RAY_DRIFT * repeats,
			Width0 = widths[i],
			Width1 = widths[i + 1],
			-- Smooth joins: both ends bend along their attachment's tangent.
			CurveSize0 = segLen * 0.35,
			CurveSize1 = segLen * 0.35,
			Brightness = spec.brightness,
			Transparency = transparency,
			ZOffset = -index,
		})

		if SHIMMER then
			-- Along the curtain's lower edge (the texture's edge sits about 30% of
			-- the height below the middle), flickering upward.
			local a, b = points[i], points[i + 1]
			local mid = (a + b) / 2 - UP * (spec.height * 0.3)
			local dir = (b - a).Unit
			local emitterPart = holderPart("Shimmer" .. i,
				CFrame.lookAt(mid, mid + dir) * CFrame.Angles(0, math.rad(90), 0),
				Vector3.new(segLen, 1, spec.wave * 0.15 + 20))
			emitterPart.Parent = model

			local pe = Instance.new("ParticleEmitter")
			pe.Texture = TEXTURES.ray
			pe.Shape = Enum.ParticleEmitterShape.Box
			pe.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
			pe.EmissionDirection = Enum.NormalId.Top
			pe.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
			pe.Rate = SHIMMER_RATE
			pe.Lifetime = SHIMMER_LIFETIME
			pe.Speed = NumberRange.new(4, 12)
			pe.Rotation = NumberRange.new(0, 0)
			pe.RotSpeed = NumberRange.new(0, 0)
			pe.LightEmission = 1
			pe.LightInfluence = 0
			pe.Brightness = spec.brightness
			pe.Size = NumberSequence.new(SHIMMER_SIZE * spec.height / 520)
			-- Negative squash stretches the particle tall and thin: a ray.
			pe.Squash = NumberSequence.new(-2.2)
			pe.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 255, 190)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 255, 140)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 200, 190)),
			})
			-- Fade in, hold faintly, fade out: a flicker, never a pop.
			pe.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.25, 0.55),
				NumberSequenceKeypoint.new(0.7, 0.65),
				NumberSequenceKeypoint.new(1, 1),
			})
			pe.LockedToPart = false
			pe.Parent = emitterPart
		end
	end
end

-- The soft haze behind everything.
do
	local model = Instance.new("Model")
	model.Name = "Glow"
	model.Parent = folder
	local base = CENTER + forward * (DISTANCE + GLOW.back) + UP * GLOW.altitude
	local holder = holderPart("Anchor", CFrame.new(base), Vector3.one)
	holder.Parent = model
	local a0 = attachmentAt(holder, base - side * (GLOW.length / 2), side)
	local a1 = attachmentAt(holder, base + side * (GLOW.length / 2), side)
	glowBeam(a0, a1, model, {
		Name = "Haze",
		Texture = TEXTURES.glow,
		TextureMode = Enum.TextureMode.Stretch,
		TextureLength = 2,
		TextureSpeed = RAY_DRIFT * 0.3,
		Width0 = GLOW.height,
		Width1 = GLOW.height,
		Brightness = GLOW.brightness,
		ZOffset = -10,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0),
			NumberSequenceKeypoint.new(0.8, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
end

for i, spec in ipairs(CURTAINS) do
	buildCurtain(i, spec)
end

pcall(function() ChangeHistoryService:SetWaypoint("Built Aurora") end)
print(("[Aurora] Built %d curtains in Workspace.Aurora, %d studs out."):format(#CURTAINS, DISTANCE))
