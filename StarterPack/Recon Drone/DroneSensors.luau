--!nonstrict
--[[
	DroneSensors  (ModuleScript)
	PUT IN: StarterPack > Recon Drone (Tool)   <- next to DroneHUD and DroneClient

	The drone camera's sensor modes. Uses the same approach as your NVG system:

	  LIGHT AMPLIFICATION (NV + thermal)
	    Lifts Brightness / Ambient / OutdoorAmbient / EnvironmentDiffuseScale on top of
	    whatever your day/night cycle last wrote, re-asserted once per frame. It tracks the
	    cycle's value as a live "base" and compares with a tolerance (float32 read-back),
	    so the boost never compounds. Client-only, so nobody else sees the brighter world.

	  SUPPRESSED CYCLE EFFECTS
	    The cycle's Bloom / ColorCorrection / SunRays get switched off while NV or thermal
	    is on (so they don't stack with ours) and switched back to how they were after.

	  THERMAL (IR-WHT / IR-BLK)
	    Pooled Highlights on the nearest humanoid models (players + NPCs), capped under
	    Roblox's ~31 Highlight limit, fading in/out every frame while the target scan
	    runs every 0.25s. The world goes flat grey so the "hot" bodies pop.

	  CRASH-SAFE CLEANUP
	    What we changed on Lighting is written to a "Drone_Restore" attribute, so if the
	    script dies mid-flight (respawn, tool removed) the next Drone script puts it back.

	  PLAYS NICE WITH YOUR NVGs
	    If the player's NVGs are down (NightVisionActive), we skip our own amplification
	    (theirs is already running - two boosts would fight) and we hide the goggle tube
	    overlay + NV_* effects while you're in the drone view, then give them back after.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService") -- only for JSONEncode/Decode; no web requests

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ---------------------------------------------------------------
-- CONFIG
-- ---------------------------------------------------------------
local CONFIG = {
	-- Same format as your NVG CONFIG.Amplify: { inst, prop, mode, amount, min, max }
	--   "add"  -> cycle value + amount (always give add entries a min/max)
	--   "set"  -> amount
	--   "lift" -> Color3 lerped toward AmpLiftColor by amount (0..1)
	AmpLiftColor = Color3.fromRGB(168, 168, 168),
	Amplify = {
		{ inst = "Lighting", prop = "Brightness",              mode = "add",  amount = 4.5, min = 0, max = 7 },
		{ inst = "Lighting", prop = "EnvironmentDiffuseScale", mode = "set",  amount = 1 },
		{ inst = "Lighting", prop = "Ambient",                 mode = "lift", amount = 0.425 },
		{ inst = "Lighting", prop = "OutdoorAmbient",          mode = "lift", amount = 0.525 },
		-- { inst = "Atmosphere", prop = "Haze",    mode = "add", amount = -1.5,  min = 0, max = 10 },
		-- { inst = "Atmosphere", prop = "Density", mode = "add", amount = -0.08, min = 0, max = 1 },
	},

	-- Your LightingCycle's own post-process effects, switched off during NV / thermal.
	SuppressEffects = { "Bloom", "ColorCorrection", "SunRays" },

	-- Your NVG system's stuff, hidden while you're looking through the drone.
	NVGEffects = { "NV_CC", "NV_Bloom", "NV_DOF", "NV_Blur" },
	NVGOverlay = "NightVisionOverlay",

	-- Thermal targets
	ThermalRange        = 400,  -- studs from the drone camera
	ThermalMaxTargets   = 24,   -- keep under Roblox's ~31 Highlight limit (your ECOTI uses some too)
	ThermalRefresh      = 0.25, -- seconds between target rescans
	ThermalFadeTime     = 0.3,  -- fade in/out time (0 = snap)
	ThermalFadeDistance = 80,   -- studs of falloff at the edge of range
	ThermalThroughWalls = false,
	ThermalIncludeSelf  = true, -- your own character shows up hot (you're looking from the drone)
	ThermalIncludeDead  = false,
	ThermalSearchFolders = { "NPCs", "Enemies", "Bots" },
}

-- ---------------------------------------------------------------
-- MODES (T cycles through MODE_ORDER)
--   amplify  : use the light amplification
--   suppress : switch off the cycle's Bloom / ColorCorrection / SunRays
--   cc       : our ColorCorrection
--   bloom    : our Bloom (nil = none)
--   blur     : our Blur size (0 = none)
--   thermal  : Highlight look for warm bodies (nil = no thermal)
--   noise    : multiplier for the HUD noise strength
-- ---------------------------------------------------------------
local MODES = {
	["EO-DAY"] = {
		label = "EO  DAY",
		amplify = false, suppress = false,
		cc = nil, -- normal camera: no color changes at all
		blur = 0, noise = 1,
	},
	["NV"] = {
		label = "EO  NV",
		amplify = true, suppress = true,
		cc = { tint = Color3.fromRGB(140, 255, 160), saturation = -1, contrast = 0.22, brightness = 0.22 },
		bloom = { intensity = 2, size = 60, threshold = 0.42 },
		blur = 1.5, noise = 1.8,
	},
	["IR-WHT"] = {
		label = "IR  WHT-HOT",
		amplify = true, suppress = true,
		cc = { tint = Color3.fromRGB(255, 255, 255), saturation = -1, contrast = -0.25, brightness = -0.12 },
		bloom = { intensity = 0.8, size = 24, threshold = 0.95 },
		blur = 1.5, noise = 1.3,
		thermal = {
			fill = Color3.fromRGB(255, 255, 255), fillTransparency = 0,
			outline = Color3.fromRGB(255, 255, 255), outlineTransparency = 0.35,
		},
	},
	["IR-BLK"] = {
		label = "IR  BLK-HOT",
		amplify = true, suppress = true,
		cc = { tint = Color3.fromRGB(255, 255, 255), saturation = -1, contrast = -0.3, brightness = 0.12 },
		blur = 1.5, noise = 1.3,
		thermal = {
			fill = Color3.fromRGB(0, 0, 0), fillTransparency = 0,
			outline = Color3.fromRGB(20, 20, 20), outlineTransparency = 0.4,
		},
	},
}
local MODE_ORDER = { "EO-DAY", "NV", "IR-WHT", "IR-BLK" }

local EFFECT_PREFIX = "DroneSensor_"
local RESTORE_ATTR = "Drone_Restore"
local THERMAL_FOLDER = "DroneThermal"

-- ---------------------------------------------------------------
-- State
-- ---------------------------------------------------------------
local Sensors = {}
Sensors.MODE_ORDER = MODE_ORDER

local active = false
local currentMode = nil
local cc, bloom, blur
local ampBase, ampWrote = {}, {}
local ampSuppressed = {}   -- effect name -> was Enabled
local restoreDirty = true
local ampRunning = false
local hiddenNVG = {}       -- instance -> was Enabled

-- ---------------------------------------------------------------
-- Restore blob (survives this script dying)
-- ---------------------------------------------------------------
local function encodeValue(v)
	if typeof(v) == "Color3" then return { r = v.R, g = v.G, b = v.B } end
	return v
end

local function decodeValue(v)
	if type(v) == "table" and v.r ~= nil and v.g ~= nil and v.b ~= nil then
		return Color3.new(v.r, v.g, v.b)
	end
	return v
end

local function writeRestoreBlob()
	local light = {}
	for _, entry in ipairs(CONFIG.Amplify) do
		local base = ampBase[entry]
		if base ~= nil then
			table.insert(light, { inst = entry.inst, prop = entry.prop, value = encodeValue(base) })
		end
	end
	local suppressed = {}
	for name, wasEnabled in pairs(ampSuppressed) do
		table.insert(suppressed, { name = name, enabled = wasEnabled and true or false })
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode({ light = light, suppressed = suppressed })
	end)
	if ok then Lighting:SetAttribute(RESTORE_ATTR, encoded) end
end

local function restoreFromBlob()
	local raw = Lighting:GetAttribute(RESTORE_ATTR)
	if type(raw) ~= "string" then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if ok and type(data) == "table" then
		for _, item in ipairs(data.light or {}) do
			local inst = (item.inst == "Lighting") and Lighting or Lighting:FindFirstChild(item.inst)
			if inst then pcall(function() inst[item.prop] = decodeValue(item.value) end) end
		end
		for _, item in ipairs(data.suppressed or {}) do
			local e = Lighting:FindFirstChild(item.name)
			if e then pcall(function() e.Enabled = item.enabled end) end
		end
	end
	Lighting:SetAttribute(RESTORE_ATTR, nil)
end

-- ---------------------------------------------------------------
-- Light amplification (same logic as the NVG script)
-- ---------------------------------------------------------------
local AMP_EPSILON = 1e-4 -- float32 read-back tolerance; without it the boost compounds every frame

local function ampInstance(name)
	if name == "Lighting" then return Lighting end
	return Lighting:FindFirstChild(name)
end

local function ampNearly(a, b)
	if a == nil or b == nil then return false end
	if typeof(a) == "Color3" then
		if typeof(b) ~= "Color3" then return false end
		return math.abs(a.R - b.R) < AMP_EPSILON and math.abs(a.G - b.G) < AMP_EPSILON and math.abs(a.B - b.B) < AMP_EPSILON
	end
	if typeof(a) ~= "number" or typeof(b) ~= "number" then return a == b end
	return math.abs(a - b) < AMP_EPSILON
end

local function ampTarget(entry, base)
	if entry.mode == "set" then
		return entry.amount
	elseif entry.mode == "lift" then
		if typeof(base) ~= "Color3" then return base end
		return base:Lerp(CONFIG.AmpLiftColor, math.clamp(entry.amount, 0, 1))
	end
	local v = base + entry.amount
	if entry.min then v = math.max(v, entry.min) end
	if entry.max then v = math.min(v, entry.max) end
	return v
end

local function reapplyLight()
	for _, entry in ipairs(CONFIG.Amplify) do
		local inst = ampInstance(entry.inst)
		if inst then
			local cur = inst[entry.prop]
			if not ampNearly(cur, ampWrote[entry]) then
				ampBase[entry] = cur -- the cycle wrote something new: that's the new base
				restoreDirty = true
			end
			local want = ampTarget(entry, ampBase[entry])
			if not ampNearly(cur, want) then
				inst[entry.prop] = want
			end
			ampWrote[entry] = want
		end
	end
	if restoreDirty then
		restoreDirty = false
		writeRestoreBlob()
	end
end

local function restoreLight()
	for _, entry in ipairs(CONFIG.Amplify) do
		local inst = ampInstance(entry.inst)
		if inst and ampBase[entry] ~= nil then
			pcall(function() inst[entry.prop] = ampBase[entry] end)
		end
	end
	table.clear(ampBase)
	table.clear(ampWrote)
	ampRunning = false
	restoreDirty = true
end

local function setSuppressedEffects(off)
	if off then
		for _, name in ipairs(CONFIG.SuppressEffects) do
			local e = Lighting:FindFirstChild(name)
			if e and ampSuppressed[name] == nil and e:IsA("PostEffect") then
				ampSuppressed[name] = e.Enabled
				e.Enabled = false
			end
		end
		writeRestoreBlob()
	else
		for name, wasEnabled in pairs(ampSuppressed) do
			local e = Lighting:FindFirstChild(name)
			if e then e.Enabled = wasEnabled end
		end
		table.clear(ampSuppressed)
		restoreDirty = true
	end
end

-- ---------------------------------------------------------------
-- NVG coexistence: hide the goggle overlay / NV_* effects while in the drone view
-- ---------------------------------------------------------------
local function hideNVG()
	for _, name in ipairs(CONFIG.NVGEffects) do
		local e = Lighting:FindFirstChild(name)
		if e and hiddenNVG[e] == nil and e.Enabled then
			hiddenNVG[e] = true
			e.Enabled = false
		end
	end
	local overlay = playerGui:FindFirstChild(CONFIG.NVGOverlay)
	if overlay and overlay:IsA("ScreenGui") and hiddenNVG[overlay] == nil and overlay.Enabled then
		hiddenNVG[overlay] = true
		overlay.Enabled = false
	end
end

local function unhideNVG()
	for inst in pairs(hiddenNVG) do
		if inst.Parent then
			pcall(function() inst.Enabled = true end)
		end
	end
	table.clear(hiddenNVG)
end

-- ---------------------------------------------------------------
-- Thermal (pooled, fading Highlights - same idea as your ECOTI)
-- ---------------------------------------------------------------
local thermalFolder
local thermalPool = {} -- model -> { hl, alpha, want }
local thermalNextScan = 0

local function thermalEnsureFolder()
	if thermalFolder and thermalFolder:IsDescendantOf(playerGui) then return end
	local stale = playerGui:FindFirstChild(THERMAL_FOLDER)
	if stale then stale:Destroy() end
	table.clear(thermalPool)
	thermalFolder = Instance.new("Folder")
	thermalFolder.Name = THERMAL_FOLDER
	thermalFolder.Parent = playerGui
end

local function thermalClear()
	for _, entry in pairs(thermalPool) do
		if entry.hl then entry.hl:Destroy() end
	end
	table.clear(thermalPool)
	local folder = thermalFolder or playerGui:FindFirstChild(THERMAL_FOLDER)
	if folder then folder:Destroy() end
	thermalFolder = nil
end

local function thermalCollect(out)
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char and char.Parent then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then out[char] = hum end
		end
	end
	local roots = { workspace }
	for _, name in ipairs(CONFIG.ThermalSearchFolders) do
		local f = workspace:FindFirstChild(name)
		if f then table.insert(roots, f) end
	end
	for _, root in ipairs(roots) do
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("Model") and out[child] == nil then
				local hum = child:FindFirstChildOfClass("Humanoid")
				if hum then out[child] = hum end
			end
		end
	end
end

local function thermalScan(look)
	thermalEnsureFolder()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local eye = cam.CFrame.Position
	local range = CONFIG.ThermalRange

	local found = {}
	thermalCollect(found)

	local ranked = {}
	for model, hum in pairs(found) do
		local skip = (model == player.Character and not CONFIG.ThermalIncludeSelf)
			or (not CONFIG.ThermalIncludeDead and hum.Health <= 0)
		if not skip then
			local ok, pivot = pcall(function() return model:GetPivot().Position end)
			if ok then
				local d = (pivot - eye).Magnitude
				if d <= range then
					table.insert(ranked, { model = model, dist = d })
				end
			end
		end
	end
	table.sort(ranked, function(a, b) return a.dist < b.dist end)

	local keep = {}
	local depth = CONFIG.ThermalThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
	local fadeDist = CONFIG.ThermalFadeDistance or 0

	for i = 1, math.min(#ranked, CONFIG.ThermalMaxTargets) do
		local model = ranked[i].model
		keep[model] = true
		local want = 1
		if fadeDist > 0 then
			want = math.clamp((range - ranked[i].dist) / fadeDist, 0, 1)
		end
		-- A CREATURE is cold-blooded: faint at rest, hotter when it sprints, roars or
		-- feeds. Scaled by the ThermalHeat the server publishes (0-1, see
		-- CreatureHeat). Anything without it shows at full strength.
		if model:GetAttribute("IsCreature") == true then
			local heat = model:GetAttribute("ThermalHeat")
			if typeof(heat) == "number" then
				want *= math.clamp(heat, 0, 1)
			end
		end
		local entry = thermalPool[model]
		if not entry and want <= 0 then continue end
		if not entry or not entry.hl.Parent then
			local hl = Instance.new("Highlight")
			hl.Name = "Thermal"
			hl.OutlineTransparency = 1
			hl.FillTransparency = 1
			hl.Parent = thermalFolder
			entry = { hl = hl, alpha = 0, want = want }
			thermalPool[model] = entry
		end
		entry.want = want
		entry.hl.Adornee = model
		entry.hl.DepthMode = depth
		entry.hl.FillColor = look.fill
		entry.hl.OutlineColor = look.outline
		entry.hl.Enabled = true
	end

	for model, entry in pairs(thermalPool) do
		if not model:IsDescendantOf(game) then
			entry.hl:Destroy()
			thermalPool[model] = nil
		elseif not keep[model] then
			entry.want = 0
		end
	end
end

local function thermalStep(dt, look)
	if os.clock() >= thermalNextScan then
		thermalNextScan = os.clock() + math.max(CONFIG.ThermalRefresh, 0.05)
		thermalScan(look)
	end
	local fadeTime = CONFIG.ThermalFadeTime or 0
	local step = (fadeTime > 0) and (math.min(dt, 1 / 15) / fadeTime) or 1
	for model, entry in pairs(thermalPool) do
		if entry.alpha ~= entry.want then
			if entry.alpha < entry.want then
				entry.alpha = math.min(entry.alpha + step, entry.want)
			else
				entry.alpha = math.max(entry.alpha - step, entry.want)
			end
		end
		local a = entry.alpha
		entry.hl.OutlineTransparency = 1 - (1 - look.outlineTransparency) * a
		entry.hl.FillTransparency = 1 - (1 - look.fillTransparency) * a
		if entry.alpha <= 0 and entry.want <= 0 then
			entry.hl:Destroy()
			thermalPool[model] = nil
		end
	end
end

-- ---------------------------------------------------------------
-- Effects
-- ---------------------------------------------------------------
local function destroyOurEffects()
	for _, e in ipairs({ cc, bloom, blur }) do
		if e then e:Destroy() end
	end
	cc, bloom, blur = nil, nil, nil
	for _, child in ipairs(Lighting:GetChildren()) do
		if child.Name:sub(1, #EFFECT_PREFIX) == EFFECT_PREFIX then child:Destroy() end
	end
end

local function buildEffects(mode)
	destroyOurEffects()

	if mode.cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = EFFECT_PREFIX .. "CC"
		cc.TintColor = mode.cc.tint
		cc.Saturation = mode.cc.saturation
		cc.Contrast = mode.cc.contrast
		cc.Brightness = mode.cc.brightness
		cc.Parent = Lighting
	end

	if mode.bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Name = EFFECT_PREFIX .. "Bloom"
		bloom.Intensity = mode.bloom.intensity
		bloom.Size = mode.bloom.size
		bloom.Threshold = mode.bloom.threshold
		bloom.Parent = Lighting
	end

	if mode.blur and mode.blur > 0 then
		blur = Instance.new("BlurEffect")
		blur.Name = EFFECT_PREFIX .. "Blur"
		blur.Size = mode.blur
		blur.Parent = Lighting
	end
end

-- ---------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------
local function nvgActive()
	return player:GetAttribute("NightVisionActive") == true
end

function Sensors.getMode()
	return currentMode and MODES[currentMode] or MODES["EO-DAY"]
end

function Sensors.getModeName()
	return currentMode or "EO-DAY"
end

function Sensors.setMode(name)
	local mode = MODES[name]
	if not mode then return end
	currentMode = name
	if not active then return end

	buildEffects(mode)

	-- Cycle effects: off for NV/thermal, back on for EO
	setSuppressedEffects(mode.suppress)

	-- Amplification: turned off right away if this mode doesn't use it
	if not mode.amplify and ampRunning then
		restoreLight()
	end

	if not mode.thermal then
		thermalClear()
	else
		thermalNextScan = 0
	end

	-- Read by SPH's PlayerClient: NV reveals IR lasers/illuminators and hides lens flares;
	-- thermal only hides lens flares (a thermal camera can't see IR lasers).
	player:SetAttribute("DroneNightVision", name == "NV")
	player:SetAttribute("DroneThermal", mode.thermal ~= nil)
	if not mode.amplify and not mode.suppress then
		Lighting:SetAttribute(RESTORE_ATTR, nil)
	end
end

function Sensors.start(name)
	active = true
	Sensors.setMode(name or currentMode or "EO-DAY")
end

function Sensors.step(dt)
	if not active then return end
	local mode = Sensors.getMode()

	hideNVG()

	if mode.amplify then
		if nvgActive() then
			-- Goggles are already amplifying; running ours too would make them fight.
			if ampRunning then restoreLight() end
		else
			if not ampRunning then
				table.clear(ampBase)
				table.clear(ampWrote)
				ampRunning = true
			end
			reapplyLight()
		end
	end

	-- Something (e.g. an NVG buildGui reset) destroyed our effects: rebuild them
	if mode.cc and (not cc or not cc.Parent) then
		buildEffects(mode)
	end

	if mode.thermal then
		thermalStep(dt, mode.thermal)
	end
end

function Sensors.stop()
	if not active then return end
	active = false
	pcall(restoreLight)
	pcall(setSuppressedEffects, false)
	pcall(destroyOurEffects)
	pcall(thermalClear)
	pcall(unhideNVG)
	Lighting:SetAttribute(RESTORE_ATTR, nil)
	player:SetAttribute("DroneNightVision", false)
	player:SetAttribute("DroneThermal", false)
end

-- A previous Drone script that died mid-flight may have left things behind: clean up now.
do
	restoreFromBlob()
	destroyOurEffects()
	local stale = playerGui:FindFirstChild(THERMAL_FOLDER)
	if stale then stale:Destroy() end
	player:SetAttribute("DroneNightVision", false)
	player:SetAttribute("DroneThermal", false)
end

return Sensors
