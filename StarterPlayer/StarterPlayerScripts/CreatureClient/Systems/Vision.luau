-- Vision  (ModuleScript, under CreatureClient > Systems)
--
-- The world drained to red, seen through a hex grid.
--
-- COMPATIBILITY WITH LightingCycle: that script rewrites Lighting.ColorCorrection,
-- Atmosphere, Bloom, SunRays, Clouds and Terrain every 0.1s. Anything written to
-- those is erased within a tenth of a second — you'd see the red flicker at 10Hz.
-- So this creates its OWN effects under names LightingCycle can't resolve
-- (it uses FindFirstChild on the exact strings "ColorCorrection" and "Bloom").
-- Roblox stacks post-processing, so storms, blizzards, winter and the day/night
-- curve all still work underneath and still read through the red.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local System = {
	name = "Vision",
	key = "vision",
	scope = "local",
}

local DEFAULTS = {
	visionTint = Color3.fromRGB(255, 74, 58),
	visionSaturation = -0.82,
	visionContrast = 0.22,
	visionBrightness = 0.035,
	visionBloom = 0.55,
	visionBloomThreshold = 0.9,
	visionBloomSize = 30,

	visionHexAsset = "rbxassetid://84308444684815",
	visionHexColor = Color3.fromRGB(255, 96, 76),
	visionHexTransparency = 0.8,
	visionHexTileSize = 128,
	visionHexDrift = 3,
	visionHexDriftSpeed = 0.25,

	visionPulseAmount = 0.05,
	visionPulseSpeed = 1.1,
	visionFadeTime = 0.45,
}

local player = Players.LocalPlayer

local colorEffect: ColorCorrectionEffect
local bloomEffect: BloomEffect
local gui: ScreenGui
local hex: ImageLabel

local cfg = table.clone(DEFAULTS)
local active = false
local baseTransparency = DEFAULTS.visionHexTransparency

function System.init()
	colorEffect = Instance.new("ColorCorrectionEffect")
	colorEffect.Name = "CreatureVision_CC"
	colorEffect.Enabled = false
	colorEffect.Parent = Lighting

	bloomEffect = Instance.new("BloomEffect")
	bloomEffect.Name = "CreatureVision_Bloom"
	bloomEffect.Enabled = false
	bloomEffect.Parent = Lighting

	-- ResetOnSpawn = false is essential: the default destroys this on every
	-- spawn, and morphing IS a spawn. Without it the grid vanishes the instant
	-- you become the creature, looking exactly like a failed asset.
	gui = Instance.new("ScreenGui")
	gui.Name = "CreatureVision"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	hex = Instance.new("ImageLabel")
	hex.Name = "HexGrid"
	hex.BackgroundTransparency = 1
	-- Oversized and offset so the drift never exposes an edge.
	hex.Size = UDim2.new(1, 64, 1, 64)
	hex.Position = UDim2.new(0, -32, 0, -32)
	hex.ScaleType = Enum.ScaleType.Tile
	hex.ImageTransparency = 1
	hex.Active = false      -- never eat a click; grabbing still has to work
	hex.Selectable = false
	hex.Parent = gui
end

function System.onAdded(char: Model, config)
	cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	hex.Image = cfg.visionHexAsset
	hex.ImageColor3 = cfg.visionHexColor
	hex.TileSize = UDim2.new(0, cfg.visionHexTileSize, 0, cfg.visionHexTileSize)
	baseTransparency = cfg.visionHexTransparency

	bloomEffect.Intensity = cfg.visionBloom
	bloomEffect.Threshold = cfg.visionBloomThreshold
	bloomEffect.Size = cfg.visionBloomSize
	colorEffect.TintColor = cfg.visionTint

	colorEffect.Enabled = true
	bloomEffect.Enabled = true
	gui.Enabled = true
	active = true

	-- Start neutral so the change reads as a transition: the world DRAINS of
	-- colour rather than being swapped for a red one.
	colorEffect.Saturation = 0
	colorEffect.Contrast = 0
	colorEffect.Brightness = 0

	local info = TweenInfo.new(cfg.visionFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(colorEffect, info, {
		Saturation = cfg.visionSaturation,
		Contrast = cfg.visionContrast,
		Brightness = cfg.visionBrightness,
	}):Play()
	TweenService:Create(hex, info, { ImageTransparency = baseTransparency }):Play()
end

function System.onRemoved()
	active = false

	local info = TweenInfo.new(cfg.visionFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local ccTween = TweenService:Create(colorEffect, info, {
		Saturation = 0, Contrast = 0, Brightness = 0,
	})
	TweenService:Create(hex, info, { ImageTransparency = 1 }):Play()
	ccTween:Play()

	-- Switched off only once the fade finishes, and only if we haven't been
	-- turned back on meanwhile — a quick unmorph/remorph would otherwise leave
	-- the effects disabled while the system thinks it's running.
	ccTween.Completed:Once(function()
		if not active then
			colorEffect.Enabled = false
			bloomEffect.Enabled = false
			gui.Enabled = false
		end
	end)
end

-- A static overlay reads as a sticker on the screen. A slow drift and a shallow
-- pulse make it read as something being looked THROUGH. Both are deliberately
-- tiny: if you can consciously watch it move, it's too much.
function System.update()
	if not active then
		return
	end

	local t = os.clock()

	if cfg.visionHexDrift > 0 then
		local dx = math.sin(t * cfg.visionHexDriftSpeed) * cfg.visionHexDrift
		local dy = math.cos(t * cfg.visionHexDriftSpeed * 0.77) * cfg.visionHexDrift
		hex.Position = UDim2.new(0, -32 + dx, 0, -32 + dy)
	end

	if cfg.visionPulseAmount > 0 then
		local pulse = math.sin(t * cfg.visionPulseSpeed) * cfg.visionPulseAmount
		hex.ImageTransparency = math.clamp(baseTransparency + pulse, 0, 1)
	end
end

return System
