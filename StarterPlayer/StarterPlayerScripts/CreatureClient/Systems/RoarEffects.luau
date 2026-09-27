-- RoarEffects  (ModuleScript, under CreatureClient > Systems)
--
-- What a roar does to whoever HEARS it. Runs for players and victims — anyone in
-- range who isn't the thing doing the roaring.
--
-- ============================================================
-- BUILT ON THE RADIATION MODEL
-- ============================================================
-- Same approach as RadiationClient, because that one already works: a single 0..1
-- level drives colour, blur, bloom and a real radial vignette, and every one of
-- them gets math.noise jitter on top.
--
-- THE JITTER IS THE WHOLE TRICK. A value that eases smoothly to zero reads as a
-- tween, because nothing in the world moves like that. math.noise is smooth but
-- irregular, so contrast and brightness crawl and shudder instead of gliding —
-- which is what makes radiation feel like something happening TO you rather than
-- an effect being played AT you. It matters more over a 12-second tail than it did
-- over 2 seconds: the longer an effect lasts, the more obvious a mathematically
-- perfect fade becomes.
--
-- ============================================================
-- WHY THREE CURVES OFF ONE LEVEL
-- ============================================================
-- A 12-second decay applied flat would be twelve seconds of heavy contrast and
-- sixteen studs of blur — unplayable. So the level falls linearly and each effect
-- reads it through its own exponent. Higher exponent = collapses sooner.
--
-- The hit is violent, most of it clears in a second or two, and a faint grey tail
-- takes the full twelve to let go. Which is how it actually works: the
-- disorientation passes quickly, being rattled does not.
--
-- ============================================================
-- WHY THIS RUNS FOR NON-CREATURES
-- ============================================================
-- Every other system here is gated on being (or seeing) a creature; this one's
-- audience is people who aren't. CreatureClient calls init() and update() on every
-- system unconditionally — only onAdded/onRemoved are scoped — so a system living
-- entirely in those two hooks runs for everybody.
--
-- LightingCycle: own named effects it can't resolve, so this stacks on top of the
-- day/night curve, the creature's red vision and the night amplification.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local System = {
	name = "RoarEffects",
	key = "roareffects",
	scope = "local",
}

local DEFAULTS = {
	-- Attack is short but NOT zero: an instant onset reads as a graphics glitch,
	-- a 60ms ramp reads as an impact.
	roarFxAttack = 0.06,
	roarFxDecay = 12,

	--   colour  1.9  the long tail — still faintly drained at 8 seconds
	--   blur    3.5  gone in about a second. Being blind is frustrating, not
	--                frightening, so it must never outlast the shock.
	--   bloom   2.6
	--   fov     5    a punch, over almost immediately
	roarFxColorCurve = 1.9,
	roarFxBlurCurve = 3.5,
	roarFxBloomCurve = 2.6,
	roarFxFovCurve = 5,

	-- Colour. Heavy on purpose — with the curve above, peak is brief.
	roarFxSaturation = -0.8,
	roarFxContrast = 0.65,
	roarFxBrightness = -0.12,
	roarFxTint = Color3.fromRGB(255, 205, 195),

	-- Jitter. Speeds are noise-units per second; amps are added on top of the base
	-- value and scale with level, so a clean screen never shimmers.
	roarFxContrastJitter = 0.22,
	roarFxContrastJitterSpeed = 5,
	roarFxBrightnessJitter = 0.16,
	roarFxBrightnessJitterSpeed = 11,
	roarFxBloomJitter = 1.6,
	roarFxBloomJitterSpeed = 3.4,

	roarFxBlur = 16,

	-- Bloom, exactly as radiation uses it: intensity climbs and the threshold
	-- drops, so ordinary surfaces start to glow rather than only bright ones.
	roarFxBloom = 7,
	roarFxBloomSize = 24,
	roarFxBloomThresholdIdle = 2,
	roarFxBloomThresholdFull = 0.85,

	--[[
		Vignette. A real radial image beats the four-frame gradient trick: gradients
		give you a rectangle with soft edges and the corners never look right. This
		is the same asset RadiationClient uses. Set it to "" and the code falls back
		to building edge gradients, so nothing breaks without it.
	--]]
	roarFxVignetteImage = "rbxassetid://260155349",
	roarFxVignetteColor = Color3.fromRGB(14, 10, 10),
	roarFxVignette = 0.88,      -- opacity at peak
	roarFxVignetteSize = 0.34,  -- only used by the gradient fallback
	roarFxVignettePulse = 0.07, -- "breathing", straight from radiation
	roarFxVignettePulseSpeed = 2.4,

	-- FOV punch, degrees. Additive; loses to anything writing FieldOfView every
	-- frame (a weapon FOV smoother). Set 0 to never touch the camera.
	roarFxFov = 7,

	-- Tinnitus ring. Fades itself, so it's played once and never restarted.
	roarFxRingAsset = "rbxassetid://9069161602",
	roarFxRingVolume = 0.35,
	roarFxRingMinIntensity = 0.05,

	roarFxFalloff = 1.6,
	roarFxMinIntensity = 0.02,

	roarFxCombatMusic = true,
	roarFxCombatMinIntensity = 0.35,
}

local player = Players.LocalPlayer
local cfg = table.clone(DEFAULTS)
local CombatCue

local colorEffect: ColorCorrectionEffect
local blurEffect: BlurEffect
local bloomEffect: BloomEffect
local gui: ScreenGui
local vignette: ImageLabel?
local edges = {}
local ring: Sound?

-- 0..1, how far into the roar we are. One value drives everything.
local level = 0
local peak = 0
local rising = false
local baseFov: number? = nil

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- ============================================================
-- BUILD
-- ============================================================
local function buildEdgeFallback(parent: ScreenGui)
	-- Only used when roarFxVignetteImage is "". Four strips, each with a gradient
	-- fading inward; overlapping corners darken for free.
	local SIDES = {
		Top = { anchor = Vector2.new(0.5, 0), pos = UDim2.fromScale(0.5, 0), rot = 90 },
		Bottom = { anchor = Vector2.new(0.5, 1), pos = UDim2.fromScale(0.5, 1), rot = 270 },
		Left = { anchor = Vector2.new(0, 0.5), pos = UDim2.fromScale(0, 0.5), rot = 0 },
		Right = { anchor = Vector2.new(1, 0.5), pos = UDim2.fromScale(1, 0.5), rot = 180 },
	}

	for name, def in pairs(SIDES) do
		local frame = Instance.new("Frame")
		frame.Name = "Vignette" .. name
		frame.BackgroundColor3 = cfg.roarFxVignetteColor
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.AnchorPoint = def.anchor
		frame.Position = def.pos
		frame.ZIndex = 2

		if name == "Top" or name == "Bottom" then
			frame.Size = UDim2.new(1, 0, cfg.roarFxVignetteSize, 0)
		else
			frame.Size = UDim2.new(cfg.roarFxVignetteSize, 0, 1, 0)
		end

		local grad = Instance.new("UIGradient")
		grad.Rotation = def.rot
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		grad.Parent = frame

		frame.Parent = parent
		table.insert(edges, frame)
	end
end

function System.init()
	-- Optional: pull RoarEffects out of the Systems folder and the music cue goes
	-- with it rather than erroring.
	local sibling = script.Parent:FindFirstChild("CombatCue")
	if sibling then
		local ok, mod = pcall(require, sibling)
		if ok then
			CombatCue = mod
		end
	end

	colorEffect = Instance.new("ColorCorrectionEffect")
	colorEffect.Name = "CreatureRoarFX_CC"
	colorEffect.Enabled = false
	colorEffect.Parent = Lighting

	blurEffect = Instance.new("BlurEffect")
	blurEffect.Name = "CreatureRoarFX_Blur"
	blurEffect.Size = 0
	blurEffect.Enabled = false
	blurEffect.Parent = Lighting

	bloomEffect = Instance.new("BloomEffect")
	bloomEffect.Name = "CreatureRoarFX_Bloom"
	bloomEffect.Size = cfg.roarFxBloomSize
	bloomEffect.Intensity = 0
	bloomEffect.Threshold = cfg.roarFxBloomThresholdIdle
	bloomEffect.Enabled = false
	bloomEffect.Parent = Lighting

	-- ResetOnSpawn = false: dying to the creature is a spawn, and the roar that
	-- killed you shouldn't have its vignette deleted mid-fade.
	gui = Instance.new("ScreenGui")
	gui.Name = "CreatureRoarFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	if cfg.roarFxVignetteImage ~= "" then
		vignette = Instance.new("ImageLabel")
		vignette.Name = "Vignette"
		vignette.BackgroundTransparency = 1
		vignette.Size = UDim2.fromScale(1, 1)
		vignette.Image = cfg.roarFxVignetteImage
		vignette.ScaleType = Enum.ScaleType.Stretch
		vignette.ImageColor3 = cfg.roarFxVignetteColor
		vignette.ImageTransparency = 1
		vignette.ZIndex = 2
		vignette.Active = false -- never eat a click
		vignette.Parent = gui
	else
		buildEdgeFallback(gui)
	end

	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("CreatureRoarFxRemote", 30)
		if not remote then
			warn("[RoarEffects] CreatureRoarFxRemote never appeared — is CreatureRoarServer up to date?")
			return
		end

		remote.OnClientEvent:Connect(function(intensity, overrides)
			if typeof(intensity) ~= "number" or intensity ~= intensity then
				return
			end

			-- Per-creature tuning arrives with the event: the listener isn't the
			-- creature and can't read its CreatureConfig.
			if typeof(overrides) == "table" then
				for k in pairs(DEFAULTS) do
					if overrides[k] ~= nil then
						cfg[k] = overrides[k]
					end
				end
			end

			intensity = math.clamp(intensity, 0, 1)
			if intensity < cfg.roarFxMinIntensity then
				return
			end

			-- A second roar during the first takes the LOUDER of the two rather
			-- than restarting — restarting would make two overlapping roars weaker
			-- than one.
			peak = math.max(peak, intensity)
			rising = true

			if cfg.roarFxCombatMusic
				and CombatCue
				and intensity >= cfg.roarFxCombatMinIntensity then
				CombatCue.cue()
			end

			-- Played once, never stopped or restarted: the clip owns its own fade,
			-- and restarting one mid-decay stutters in a way that reads as a bug.
			if cfg.roarFxRingAsset ~= ""
				and intensity >= cfg.roarFxRingMinIntensity then

				if not ring then
					ring = Instance.new("Sound")
					ring.Name = "CreatureRoarRing"
					-- SoundService: this is in your head, so it must not pan or
					-- attenuate with distance.
					ring.Parent = SoundService
				end

				if not ring.IsPlaying then
					ring.SoundId = cfg.roarFxRingAsset
					ring.Looped = false
					ring.Volume = cfg.roarFxRingVolume * intensity
					ring:Play()
				end
			end
		end)
	end)
end

-- ============================================================
-- APPLY
-- ============================================================
local function applyFov(amount: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	-- Additive, restoring exactly what it started from. If something else owns
	-- FieldOfView every frame it simply wins and this quietly does nothing, rather
	-- than the two fighting and strobing.
	if amount <= 0.001 then
		if baseFov then
			cam.FieldOfView = baseFov
			baseFov = nil
		end
		return
	end

	if not baseFov then
		baseFov = cam.FieldOfView
	end
	cam.FieldOfView = baseFov + amount
end

local function clearAll()
	colorEffect.Enabled = false
	blurEffect.Enabled = false
	bloomEffect.Enabled = false
	gui.Enabled = false
	applyFov(0)
end

function System.update(dt: number)
	if level <= 0 and not rising then
		return
	end

	if rising then
		level = math.min(level + dt / math.max(cfg.roarFxAttack, 0.01), peak)
		if level >= peak then
			rising = false
		end
	else
		level = math.max(level - dt / math.max(cfg.roarFxDecay, 0.05), 0)
		if level <= 0 then
			peak = 0
		end
	end

	local L = level
	if L <= 0 then
		clearAll()
		return
	end

	local colorL = L ^ cfg.roarFxColorCurve
	local blurL = L ^ cfg.roarFxBlurCurve
	local bloomL = L ^ cfg.roarFxBloomCurve
	local fovL = L ^ cfg.roarFxFovCurve

	local clock = os.clock()
	-- math.noise returns roughly -0.5..0.5 and varies smoothly, which is what gives
	-- an organic crawl instead of a tween. Each stream gets its own offset so
	-- contrast and brightness never shudder in lockstep.
	local cNoise = math.noise(clock * cfg.roarFxContrastJitterSpeed, 0)
	local brNoise = math.noise(clock * cfg.roarFxBrightnessJitterSpeed, 41.7)
	local blNoise = math.noise(clock * cfg.roarFxBloomJitterSpeed, 17.3)

	colorEffect.Enabled = true
	colorEffect.Saturation = cfg.roarFxSaturation * colorL
	colorEffect.Contrast = cfg.roarFxContrast * colorL
		+ cNoise * cfg.roarFxContrastJitter * colorL
	colorEffect.Brightness = cfg.roarFxBrightness * colorL
		+ brNoise * cfg.roarFxBrightnessJitter * colorL
	-- Tint lerps FROM white, so at L = 0 it is exactly neutral and can't leave a
	-- permanent cast behind if a frame is ever missed.
	colorEffect.TintColor = Color3.new(1, 1, 1):Lerp(cfg.roarFxTint, colorL)

	blurEffect.Enabled = blurL > 0.001
	blurEffect.Size = cfg.roarFxBlur * blurL

	bloomEffect.Enabled = bloomL > 0.001
	bloomEffect.Intensity = math.max(0,
		cfg.roarFxBloom * bloomL + blNoise * cfg.roarFxBloomJitter * bloomL)
	bloomEffect.Threshold = lerp(
		cfg.roarFxBloomThresholdIdle, cfg.roarFxBloomThresholdFull, bloomL)

	-- The vignette rides the COLOUR curve and breathes, so the edges stay faintly
	-- closed in as long as the world stays faintly grey. One sensation, not two.
	gui.Enabled = true
	local pulse = math.sin(clock * cfg.roarFxVignettePulseSpeed) * cfg.roarFxVignettePulse
	local opacity = math.clamp((cfg.roarFxVignette + pulse) * colorL, 0, 1)

	if vignette then
		vignette.ImageTransparency = 1 - opacity
	else
		for _, frame in ipairs(edges) do
			frame.BackgroundTransparency = 1 - opacity
		end
	end

	applyFov(cfg.roarFxFov * fovL)
end

return System
