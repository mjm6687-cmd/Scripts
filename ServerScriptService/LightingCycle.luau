local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Terrain = workspace.Terrain

-----------------------------------------------------------------------
-- TUNABLES
-----------------------------------------------------------------------
local DEFAULT_DAY_MINUTES   = 20   -- real minutes for 06:00 -> 18:00 (live-editable via Lighting attribute "DayMinutes")
local DEFAULT_NIGHT_MINUTES = 20   -- real minutes for 18:00 -> 06:00 (live-editable via Lighting attribute "NightMinutes")
local APPLY_INTERVAL = 0.1    -- how often visuals refresh (s). 0.1 = smooth + cheap
local GEO_LATITUDE  = 57      -- Sitka, Alaska (~57N) sun angle, set once

-- Order of the day as ClockTime "stops". Duplicate a preset to hold it.
-- Tweak these edges to retune pacing; durations are derived from the gaps.
local STOPS = {
	{ time = 0.0,  preset = "Midnight" },
	{ time = 4.7,  preset = "Midnight" }, -- hold night
	{ time = 6.7,  preset = "Morning"  }, -- SUNRISE  (4.7->6.7 = fast, 2h)
	{ time = 7.5,  preset = "Morning"  }, -- short hold
	{ time = 11.5, preset = "Noon"     }, -- morning->noon (slow, 4h)
	{ time = 13.0, preset = "Noon"     }, -- hold midday
	{ time = 16.5, preset = "Sunset"   }, -- noon->sunset (slow, 3.5h)
	{ time = 17.0, preset = "Sunset"   }, -- short hold
	{ time = 19.0, preset = "Midnight" }, -- DUSK     (17->19 = fast, 2h)
	{ time = 24.0, preset = "Midnight" }, -- wrap (== 0.0)
}

-----------------------------------------------------------------------
-- PRESETS  (the values you tuned)
-----------------------------------------------------------------------
local C = Color3.fromRGB
local PRESETS = {
	Morning = {
		Lighting = {
			Brightness = 2, ExposureCompensation = 0.02, ShadowSoftness = 0.45,
			EnvironmentDiffuseScale = 0.2, EnvironmentSpecularScale = 0.2,
			Ambient = C(28,32,40), OutdoorAmbient = C(128,132,138),
			ColorShift_Top = C(156,152,142), ColorShift_Bottom = C(86,86,90),
		},
		Atmosphere = { Density = 0.22, Offset = 0.1, Color = C(198,196,190), Decay = C(175,165,150), Glare = 0.4, Haze = 1.5 },
		ColorCorrection = { Brightness = 0, Contrast = 0.05, Saturation = 0, TintColor = C(240,236,224) },
		Bloom = { Intensity = 0.7, Size = 24, Threshold = 1.1 },
		SunRays = { Intensity = 0.06, Spread = 0.9 },
		Clouds = { Color = C(205,210,218) }, -- Cover/Density owned by WeatherServer
		Terrain = { WaterReflectance = 0.2 },
	},
	Noon = {
		Lighting = {
			Brightness = 4, ExposureCompensation = 0, ShadowSoftness = 0.2,
			EnvironmentDiffuseScale = 0.2, EnvironmentSpecularScale = 0.5,
			Ambient = C(0,0,0), OutdoorAmbient = C(130,130,130),
			ColorShift_Top = C(255,255,255), ColorShift_Bottom = C(0,0,0),
		},
		Atmosphere = { Density = 0.22, Offset = 1, Color = C(255,255,255), Decay = C(255,255,255), Glare = 0.2, Haze = 2 },
		ColorCorrection = { Brightness = 0.01, Contrast = 0.06, Saturation = 0, TintColor = C(255,255,255) },
		Bloom = { Intensity = 1, Size = 24, Threshold = 3.2 },
		SunRays = { Intensity = 0.005, Spread = 0.1 },
		Clouds = { Color = C(255,255,255) }, -- Cover/Density owned by WeatherServer
		Terrain = { WaterReflectance = 0.3 },
	},
	Sunset = {
		Lighting = {
			Brightness = 2.2, ExposureCompensation = -0.02, ShadowSoftness = 0.4,
			EnvironmentDiffuseScale = 0.9, EnvironmentSpecularScale = 0.8,
			Ambient = C(34,30,30), OutdoorAmbient = C(130,115,110),
			ColorShift_Top = C(175,155,135), ColorShift_Bottom = C(90,80,80),
		},
		Atmosphere = { Density = 0.18, Offset = 0.25, Color = C(205,190,180), Decay = C(180,130,110), Glare = 0.4, Haze = 0.5 },
		ColorCorrection = { Brightness = -0.04, Contrast = 0.13, Saturation = 0, TintColor = C(240,230,220) },
		Bloom = { Intensity = 0.5, Size = 24, Threshold = 1.7 },
		SunRays = { Intensity = 0.12, Spread = 1 },
		Clouds = { Color = C(215,200,190) }, -- Cover/Density owned by WeatherServer
		Terrain = { WaterReflectance = 0.25 },
	},
	Midnight = {
		Lighting = {
			Brightness = 1, ExposureCompensation = 0.25, ShadowSoftness = 0.6,
			EnvironmentDiffuseScale = 0, EnvironmentSpecularScale = 0,
			Ambient = C(10,10,10), OutdoorAmbient = C(30,30,30),
			ColorShift_Top = C(84,84,84), ColorShift_Bottom = C(40,40,40),
		},
		Atmosphere = { Density = 0.05, Offset = 0, Color = C(5,5,5), Decay = C(5,5,5), Glare = 0, Haze = 2.5 },
		ColorCorrection = { Brightness = 0, Contrast = 0.01, Saturation = 0, TintColor = C(226,226,226) },
		Bloom = { Intensity = 0.5, Size = 20, Threshold = 1.6 },
		SunRays = { Intensity = 0.02, Spread = 0.6 },
		Clouds = { Color = C(56,64,80) }, -- darker night clouds; Cover/Density owned by WeatherServer
		Terrain = { WaterReflectance = 0.01 }, -- low so night water isn't too shiny
	},
}

-----------------------------------------------------------------------
-- RESOLVE INSTANCES
-----------------------------------------------------------------------
local function need(parent, name)
	local inst = parent:FindFirstChild(name)
	if not inst then warn(("[DayNightCycle] Missing %s under %s"):format(name, parent.Name)) end
	return inst
end

local INSTANCES = {
	Lighting        = Lighting,
	Atmosphere      = need(Lighting, "Atmosphere"),
	ColorCorrection = need(Lighting, "ColorCorrection"),
	Bloom           = need(Lighting, "Bloom"),
	SunRays         = need(Lighting, "SunRays"),
	Clouds          = need(Terrain, "Clouds"),
	Terrain         = Terrain,
}

Lighting.GeographicLatitude = GEO_LATITUDE

-- Initialize live-editable attributes (admin commands write to these)
if Lighting:GetAttribute("DayMinutes") == nil then
	Lighting:SetAttribute("DayMinutes", DEFAULT_DAY_MINUTES)
end
if Lighting:GetAttribute("NightMinutes") == nil then
	Lighting:SetAttribute("NightMinutes", DEFAULT_NIGHT_MINUTES)
end
if Lighting:GetAttribute("StormFactor") == nil then
	Lighting:SetAttribute("StormFactor", 0) -- driven by WeatherServer (0 clear .. 1 storm)
end
-- Winter counterparts, also driven by WeatherServer. StormFactor and SnowFactor
-- are never both above zero, so the two modifiers below can't stack.
if Lighting:GetAttribute("SnowFactor") == nil then
	Lighting:SetAttribute("SnowFactor", 0)
end
if Lighting:GetAttribute("BlizzardFactor") == nil then
	Lighting:SetAttribute("BlizzardFactor", 0)
end
if Lighting:GetAttribute("Season") == nil then
	Lighting:SetAttribute("Season", "Summer")
end
-- Set by WeatherClient while a lightning bolt is flashing the clouds white. This
-- loop runs every 0.1s and would otherwise repaint Clouds.Color straight over a
-- 0.05s flash, eating about half of them outright.
if Lighting:GetAttribute("CloudFlash") == nil then
	Lighting:SetAttribute("CloudFlash", false)
end

-----------------------------------------------------------------------
-- BLEND + APPLY
-----------------------------------------------------------------------
local function lerpValue(a, b, t)
	if typeof(a) == "Color3" then return a:Lerp(b, t) end
	return a + (b - a) * t
end

-- smoothstep: ease in/out, no overshoot
local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Build the time-of-day blend as a table (instName -> {prop = value}).
local function buildBlend(presetA, presetB, t)
	t = smooth(t)
	local out = {}
	for instName, props in pairs(presetA) do
		out[instName] = {}
		local bProps = presetB[instName]
		for prop, valA in pairs(props) do
			out[instName][prop] = lerpValue(valA, bProps[prop], t)
		end
	end
	return out
end

-----------------------------------------------------------------------
-- STORM COUPLING
--   WeatherServer tweens Lighting attribute "StormFactor" 0..1.
--   0 = clear (untouched presets), 1 = full storm (grayer/darker/denser).
--   Tune STORM_* below to taste.
-----------------------------------------------------------------------
local GRAY = Color3.fromRGB(128, 128, 128)
local STORM_DARK_CLOUD = Color3.fromRGB(70, 72, 76)

local STORM = {
	BrightnessMul   = 0.18, -- how much darker (fraction of Brightness removed)
	Exposure        = 0.12, -- ExposureCompensation subtracted
	CCSaturation    = 0.18, -- extra desaturation
	CCBrightness    = 0.03, -- CC brightness subtracted
	TintToGray      = 0.25, -- ColorCorrection tint pulled toward gray
	AtmDensity      = 0.04, -- atmosphere density added (was 0.10 -- storms fogged up too hard)
	AtmColorToGray  = 0.30, -- atmosphere color/decay pulled toward gray
	CloudToDark     = 0.50, -- cloud color pulled toward dark gray
}

local function applyStormModifier(state, f)
	if f <= 0 then return state end

	local L = state.Lighting
	if L then
		if L.Brightness then L.Brightness = L.Brightness * (1 - STORM.BrightnessMul * f) end
		if L.ExposureCompensation then L.ExposureCompensation = L.ExposureCompensation - STORM.Exposure * f end
	end
	local cc = state.ColorCorrection
	if cc then
		if cc.Saturation then cc.Saturation = cc.Saturation - STORM.CCSaturation * f end
		if cc.Brightness then cc.Brightness = cc.Brightness - STORM.CCBrightness * f end
		if cc.TintColor then cc.TintColor = cc.TintColor:Lerp(GRAY, STORM.TintToGray * f) end
	end
	local atm = state.Atmosphere
	if atm then
		if atm.Density then atm.Density = atm.Density + STORM.AtmDensity * f end
		if atm.Color then atm.Color = atm.Color:Lerp(GRAY, STORM.AtmColorToGray * f) end
		if atm.Decay then atm.Decay = atm.Decay:Lerp(GRAY, STORM.AtmColorToGray * f) end
	end
	local cl = state.Clouds
	if cl and cl.Color then cl.Color = cl.Color:Lerp(STORM_DARK_CLOUD, STORM.CloudToDark * f) end

	return state
end

-----------------------------------------------------------------------
-- SNOW COUPLING
--   WeatherServer tweens "SnowFactor" 0..1, plus "BlizzardFactor" for the heavy
--   variant layered on top.
--
--   This is deliberately NOT the storm curve inverted. A rainstorm is dark and
--   gray; a snowstorm is BRIGHT and flat. Whiteout is fog, not darkness ? the
--   heavy lifting here is atmosphere density and desaturation, not brightness
--   reduction.
--
--   The single most important line is the OutdoorAmbient lerp. Snow at night is
--   luminous because overcast light bounces off the snowpack, and lerping toward
--   a fixed cold ambient does that automatically: it lifts Midnight hard
--   (30,30,30 -> ~74,80,91) while barely touching Noon (130,130,130 -> ~127).
--   Same line, correct behaviour at every hour, no time-of-day branching.
-----------------------------------------------------------------------
local SNOW_CLOUD   = Color3.fromRGB(214, 220, 232)
local SNOW_AIR     = Color3.fromRGB(232, 238, 248)
local SNOW_TINT    = Color3.fromRGB(228, 236, 248)
local SNOW_AMBIENT = Color3.fromRGB(118, 130, 152) -- cold bounce off snowpack

-- NIGHT versions of the targets above. The day targets are near-white, and
-- lerping a Midnight atmosphere (5,5,5) halfway to (232,238,248) turned a night
-- blizzard's fog into a glowing gray-white wall. At night the snow targets now
-- fade toward these dim cold blues instead, blended by how "daytime" the base
-- preset is (see dayAmount below), so dusk/dawn transition smoothly.
local SNOW_CLOUD_NIGHT   = Color3.fromRGB(46, 52, 64)
local SNOW_AIR_NIGHT     = Color3.fromRGB(34, 38, 48)
local SNOW_TINT_NIGHT    = Color3.fromRGB(200, 208, 224)
local SNOW_AMBIENT_NIGHT = Color3.fromRGB(52, 58, 72)  -- still a slight snowpack glow

-- Blizzard at night: heavy snow blocks what little sky light there is, so it
-- should get DARKER, not brighter. 0 = off, 1 = very dark.
local BLIZZARD_NIGHT_DIM = 0.35

local SNOW = {
	MinBrightness   = 2.0,  -- floor that night is lifted toward (never lowers day)
	BrightnessLift  = 0.45,
	AmbientLift     = 0.50, -- OutdoorAmbient pulled toward SNOW_AMBIENT
	IndoorAmbLift   = 0.20, -- Ambient too, but gentler
	CCSaturation    = 0.34, -- snow scenes are close to monochrome
	CCBrightness    = 0.015,-- ADDED, not subtracted
	TintToSnow      = 0.40,
	AtmDensity      = 0.045, -- gentle snowfall haze
	AtmHaze         = 1.2,
	AtmColorToWhite = 0.55,
	CloudToLight    = 0.60,  -- clouds go pale, not dark
	SunRaysMul      = 0.25,  -- sun is behind heavy cloud
	BlizzardDensity = 0.07,  -- EXTRA atmosphere density at full blizzard
	BlizzardSat     = 0.18,  -- and extra desaturation
}

local function applySnowModifier(state, f, b)
	if f <= 0 then return state end
	b = math.clamp(b or 0, 0, 1) * f

	local L = state.Lighting

	-- How "daytime" the base scene is, 0 = Midnight, 1 = Noon/Morning. Read from
	-- the preset's OutdoorAmbient BEFORE we change it (Midnight is 30, day ~130).
	-- Nothing earlier (the storm modifier) touches OutdoorAmbient, so it's clean.
	local dayAmount = 1
	if L and L.OutdoorAmbient then
		dayAmount = math.clamp((L.OutdoorAmbient.R * 255 - 30) / (128 - 30), 0, 1)
	end
	local night = 1 - dayAmount

	local ambTarget   = SNOW_AMBIENT_NIGHT:Lerp(SNOW_AMBIENT, dayAmount)
	local airTarget   = SNOW_AIR_NIGHT:Lerp(SNOW_AIR, dayAmount)
	local cloudTarget = SNOW_CLOUD_NIGHT:Lerp(SNOW_CLOUD, dayAmount)
	local tintTarget  = SNOW_TINT_NIGHT:Lerp(SNOW_TINT, dayAmount)

	-- Blizzard-at-night darkening, 0 in daytime.
	local nightDim = BLIZZARD_NIGHT_DIM * b * night

	if L then
		-- Brightness lift is daytime/dusk only now; at night it was the main
		-- reason the whole scene glowed.
		if L.Brightness and L.Brightness < SNOW.MinBrightness then
			L.Brightness = L.Brightness + (SNOW.MinBrightness - L.Brightness) * SNOW.BrightnessLift * f * dayAmount
		end
		if L.Brightness then L.Brightness = L.Brightness * (1 - nightDim) end
		if L.OutdoorAmbient then
			L.OutdoorAmbient = L.OutdoorAmbient:Lerp(ambTarget, SNOW.AmbientLift * f)
			L.OutdoorAmbient = L.OutdoorAmbient:Lerp(Color3.new(0, 0, 0), nightDim)
		end
		if L.Ambient then L.Ambient = L.Ambient:Lerp(ambTarget, SNOW.IndoorAmbLift * f) end
		if L.ExposureCompensation then L.ExposureCompensation = L.ExposureCompensation - 0.3 * nightDim end
	end
	local cc = state.ColorCorrection
	if cc then
		if cc.Saturation then cc.Saturation = cc.Saturation - (SNOW.CCSaturation + SNOW.BlizzardSat * b) * f end
		if cc.Brightness then cc.Brightness = cc.Brightness + SNOW.CCBrightness * f * dayAmount end
		if cc.TintColor then cc.TintColor = cc.TintColor:Lerp(tintTarget, SNOW.TintToSnow * f) end
	end
	local atm = state.Atmosphere
	if atm then
		if atm.Density then atm.Density = math.min(1, atm.Density + (SNOW.AtmDensity + SNOW.BlizzardDensity * b) * f) end
		if atm.Haze then atm.Haze = atm.Haze + SNOW.AtmHaze * f end
		if atm.Color then atm.Color = atm.Color:Lerp(airTarget, SNOW.AtmColorToWhite * f) end
		if atm.Decay then atm.Decay = atm.Decay:Lerp(airTarget, SNOW.AtmColorToWhite * f) end
	end
	local cl = state.Clouds
	if cl and cl.Color then cl.Color = cl.Color:Lerp(cloudTarget, SNOW.CloudToLight * f) end
	local sr = state.SunRays
	if sr and sr.Intensity then sr.Intensity = sr.Intensity * (1 - (1 - SNOW.SunRaysMul) * f) end

	return state
end

-----------------------------------------------------------------------
-- WINTER COUPLING
--   Driven by the Lighting attribute "Season" ("Summer" / "Winter"), the same
--   one WeatherServer reads when a storm forms. This is the AMBIENT season look:
--   it is on the whole time it is winter, clear skies included, and is entirely
--   separate from SnowFactor (which only runs while snow is actually falling).
--
--   Winter light is COLD and WEAK, not dark: a low sun through thin high cloud.
--   So the work here is color temperature (blues in the ambient, sun, air and
--   clouds) plus a small brightness cut, NOT a big brightness cut -- that just
--   reads as "storm" and the storm modifier already owns that look.
--
--   Applied LAST, after snow, on purpose: applySnowModifier derives dayAmount
--   from the preset's OutdoorAmbient, and cooling that value first would make it
--   read a winter noon as partly night.
-----------------------------------------------------------------------
local WINTER_AMBIENT = Color3.fromRGB(96, 112, 140)  -- cold skylight bounce
local WINTER_AIR     = Color3.fromRGB(150, 170, 200) -- distant haze goes blue
local WINTER_TINT    = Color3.fromRGB(214, 228, 248)
local WINTER_CLOUD   = Color3.fromRGB(186, 198, 216)
local WINTER_SUN_TOP    = Color3.fromRGB(190, 205, 232) -- pale blue-white sun
local WINTER_SUN_BOTTOM = Color3.fromRGB(68, 78, 98)

-- Night versions. Lerping a Midnight scene toward the daytime blues above turns
-- 3am into glowing navy; at night winter only needs a faint steel edge.
local WINTER_AMBIENT_NIGHT = Color3.fromRGB(44, 52, 68)
local WINTER_AIR_NIGHT     = Color3.fromRGB(30, 36, 48)

local WINTER = {
	BrightnessMul   = 0.08, -- weak low sun, a small cut only
	AmbientToCold   = 0.40, -- OutdoorAmbient toward the cold target
	IndoorAmbToCold = 0.30,
	SunToCold       = 0.35, -- ColorShift_Top / _Bottom
	TintToCold      = 0.32,
	CCSaturation    = 0.12, -- winter is a low-chroma season
	AtmColorToCold  = 0.30,
	AtmDensity      = 0.012, -- a touch more haze in cold air
	CloudToCold     = 0.35,
	WaterReflectMul = 1.15,  -- near-freezing water reads glassier
}

local function applyWinterModifier(state, w)
	if w <= 0 then return state end

	local L = state.Lighting

	-- Same dayAmount trick applySnowModifier uses, but read from the ORIGINAL
	-- preset ambient would be nicer; snow may have already lifted it. Close enough
	-- either way, and it keeps this function standalone.
	local dayAmount = 1
	if L and L.OutdoorAmbient then
		dayAmount = math.clamp((L.OutdoorAmbient.R * 255 - 30) / (128 - 30), 0, 1)
	end

	local ambTarget = WINTER_AMBIENT_NIGHT:Lerp(WINTER_AMBIENT, dayAmount)
	local airTarget = WINTER_AIR_NIGHT:Lerp(WINTER_AIR, dayAmount)

	if L then
		if L.Brightness then L.Brightness = L.Brightness * (1 - WINTER.BrightnessMul * w) end
		if L.OutdoorAmbient then L.OutdoorAmbient = L.OutdoorAmbient:Lerp(ambTarget, WINTER.AmbientToCold * w) end
		if L.Ambient then L.Ambient = L.Ambient:Lerp(ambTarget, WINTER.IndoorAmbToCold * w) end
		-- Sun/moon color itself. This is the line that sells it: warm sunlight is
		-- what makes a scene feel summery, far more than the ambient does.
		if L.ColorShift_Top then L.ColorShift_Top = L.ColorShift_Top:Lerp(WINTER_SUN_TOP, WINTER.SunToCold * w * dayAmount) end
		if L.ColorShift_Bottom then L.ColorShift_Bottom = L.ColorShift_Bottom:Lerp(WINTER_SUN_BOTTOM, WINTER.SunToCold * w * dayAmount) end
	end

	local cc = state.ColorCorrection
	if cc then
		if cc.Saturation then cc.Saturation = cc.Saturation - WINTER.CCSaturation * w end
		if cc.TintColor then cc.TintColor = cc.TintColor:Lerp(WINTER_TINT, WINTER.TintToCold * w) end
	end

	local atm = state.Atmosphere
	if atm then
		if atm.Density then atm.Density = math.min(1, atm.Density + WINTER.AtmDensity * w) end
		if atm.Color then atm.Color = atm.Color:Lerp(airTarget, WINTER.AtmColorToCold * w) end
		if atm.Decay then atm.Decay = atm.Decay:Lerp(airTarget, WINTER.AtmColorToCold * w) end
	end

	local cl = state.Clouds
	if cl and cl.Color then cl.Color = cl.Color:Lerp(WINTER_CLOUD, WINTER.CloudToCold * w * dayAmount) end

	local tr = state.Terrain
	if tr and tr.WaterReflectance then
		tr.WaterReflectance = math.clamp(tr.WaterReflectance * (1 + (WINTER.WaterReflectMul - 1) * w), 0, 1)
	end

	return state
end

-- How cold the world currently looks, 0 = summer, 1 = full winter. Eased in the
-- main loop rather than snapped, so ";season winter" fades over WINTER_FADE
-- seconds instead of hard-cutting the whole sky in one frame.
local WINTER_FADE = 10
local winterBlend = (Lighting:GetAttribute("Season") == "Winter") and 1 or 0

local function applyState(state)
	for instName, props in pairs(state) do
		local inst = INSTANCES[instName]
		if inst then
			for prop, val in pairs(props) do
				inst[prop] = val
			end
		end
	end
end

-- Find the two surrounding stops for a clock time, blend, apply weather, write.
local function applyForClock(clock)
	clock = clock % 24
	local f = math.clamp(Lighting:GetAttribute("StormFactor") or 0, 0, 1)
	local s = math.clamp(Lighting:GetAttribute("SnowFactor") or 0, 0, 1)
	local bz = math.clamp(Lighting:GetAttribute("BlizzardFactor") or 0, 0, 1)

	for i = 1, #STOPS - 1 do
		local s0, s1 = STOPS[i], STOPS[i + 1]
		if clock >= s0.time and clock <= s1.time then
			local span = s1.time - s0.time
			local t = span > 0 and (clock - s0.time) / span or 0
			local state = buildBlend(PRESETS[s0.preset], PRESETS[s1.preset], t)

			applyStormModifier(state, f)

			-- At deep night, pin atmosphere density to 0.2 (storms don't thicken it).
			if s0.preset == "Midnight" and s1.preset == "Midnight" and state.Atmosphere then
				state.Atmosphere.Density = 0.2
			end

			-- SNOW RUNS AFTER THE PIN, DELIBERATELY. The pin is a hard assignment,
			-- so anything applied before it is thrown away ? a night blizzard's
			-- whiteout would silently vanish and no amount of tuning SNOW.AtmDensity
			-- would bring it back. Storms keep the old behaviour; snow overrides it.
			applySnowModifier(state, s, bz)

			-- Ambient season tint. Runs all winter, clear skies included, and last
			-- so it doesn't skew the dayAmount the snow modifier derives.
			applyWinterModifier(state, winterBlend)

			-- Yield Clouds.Color to the lightning flash while one is running. Dropping
			-- the key (rather than skipping applyState) leaves every OTHER property
			-- -- brightness, atmosphere, water -- updating normally through the flash.
			-- Must stay AFTER both modifiers: they read Clouds.Color, and nil would
			-- throw.
			if state.Clouds and Lighting:GetAttribute("CloudFlash") then
				state.Clouds.Color = nil
			end

			applyState(state)
			return
		end
	end
	-- fallback (shouldn't hit if STOPS span 0..24)
	local state = buildBlend(PRESETS.Midnight, PRESETS.Midnight, 0)
	applyStormModifier(state, f)
	applySnowModifier(state, s, bz)
	applyWinterModifier(state, winterBlend)
	applyState(state)
end

-----------------------------------------------------------------------
-- DRIVE THE CLOCK
-----------------------------------------------------------------------
local lastTick = os.clock()

while true do
	local now = os.clock()
	local dt = now - lastTick
	lastTick = now

	-- Ease the season look in/out so flipping Season doesn't snap the whole sky.
	local winterTarget = (Lighting:GetAttribute("Season") == "Winter") and 1 or 0
	if winterBlend ~= winterTarget then
		local step = dt / WINTER_FADE
		if winterTarget > winterBlend then
			winterBlend = math.min(winterTarget, winterBlend + step)
		else
			winterBlend = math.max(winterTarget, winterBlend - step)
		end
	end

	if not Lighting:GetAttribute("FreezeTime") then
		-- read live ClockTime so admin changes are respected, then advance
		local clock = Lighting.ClockTime
		local isDay = clock >= 6 and clock < 18
		local dayMin = Lighting:GetAttribute("DayMinutes") or DEFAULT_DAY_MINUTES
		local nightMin = Lighting:GetAttribute("NightMinutes") or DEFAULT_NIGHT_MINUTES
		local minutes = isDay and dayMin or nightMin
		local rate = 12 / (math.max(minutes, 0.0001) * 60) -- game-hours per real second
		Lighting.ClockTime = (clock + rate * dt) % 24
	end

	applyForClock(Lighting.ClockTime)
	task.wait(APPLY_INTERVAL)
end
