-- Hum  (ModuleScript, under CreatureClient > Systems)
--
-- A quiet background hum while you're the creature. Only you hear it: it's
-- played flat (2D) from SoundService on your own client, the sound of being
-- inside the thing rather than a noise it makes in the world.
--
-- Fades in when you morph and out when you stop being the creature, so it never
-- cuts in or out abruptly. Settings live in CreatureConfig (HUM section); a
-- creature can turn it off with systems = { hum = false }.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local System = {
	name = "Hum",
	key = "hum",
	scope = "local",
}

local DEFAULTS = {
	humSoundId = "rbxassetid://9126099595",
	humVolume = 0.15,     -- quiet on purpose: felt more than heard
	humFadeTime = 2.5,    -- seconds to fade in / out
	humPitch = 1,
}

local SOUND_NAME = "CreatureHum"

local sound: Sound? = nil
local fade: Tween? = nil

local function getSound(): Sound
	if sound and sound.Parent then
		return sound
	end
	-- Left over from a previous morph (fading out when we came back): reuse it.
	local existing = SoundService:FindFirstChild(SOUND_NAME)
	if existing and existing:IsA("Sound") then
		sound = existing
		return existing
	end
	local s = Instance.new("Sound")
	s.Name = SOUND_NAME
	s.Looped = true
	s.Volume = 0
	s.Parent = SoundService
	sound = s
	return s
end

local function fadeTo(volume: number, time: number, onDone: (() -> ())?)
	if fade then
		fade:Cancel()
		fade = nil
	end
	local s = getSound()
	local tween = TweenService:Create(s, TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
		Volume = volume,
	})
	fade = tween
	if onDone then
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				onDone()
			end
		end)
	end
	tween:Play()
end

function System.onAdded(_char: Model, config)
	local cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	local s = getSound()
	if s.SoundId ~= cfg.humSoundId then
		s.SoundId = cfg.humSoundId
	end
	s.PlaybackSpeed = cfg.humPitch
	if not s.IsPlaying then
		s.Volume = 0
		s:Play()
	end
	fadeTo(cfg.humVolume, cfg.humFadeTime)
end

function System.onRemoved()
	if not sound then
		return
	end
	local s = sound
	fadeTo(0, DEFAULTS.humFadeTime, function()
		if s.Parent then
			s:Stop()
		end
	end)
end

return System
