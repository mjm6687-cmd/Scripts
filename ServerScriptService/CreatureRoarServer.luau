-- CreatureRoarServer
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- Plays the roars. Server-side, so every client hears them with no broadcasting.
--
-- ============================================================
-- SETUP
-- ============================================================
-- Inside the creature rig's HumanoidRootPart, a Part named RoarSounds:
--
--   HumanoidRootPart
--   +-- RoarSounds          (Part ? invisible, massless, no collision)
--       +-- Roar1           (Folder)
--       ?   +-- Near        (Sound)  the close, detailed roar
--       ?   +-- Distant     (Sound)  the far-off layer
--       +-- Roar2           (Folder)
--       +-- Roar3           (Folder)
--
-- A Roar folder may also hold several Nears (Near1, Near2...) and it picks one at
-- random. Or skip folders entirely and make Roar1 a plain Sound ? you get the near
-- layer only.
--
-- This script welds RoarSounds to the HumanoidRootPart at spawn if it isn't
-- already, so you can just drop a part in without wiring anything. Left unwelded
-- it would be left behind on the ground the moment the creature moved.
--
-- ============================================================
-- WHY TWO LAYERS
-- ============================================================
-- Roblox sounds are point sources, so a single roar just gets quieter with
-- distance ? which reads as "small thing far away", not "huge thing far away".
--
-- The fix is two clips playing at once with different rolloff curves:
--   NEAR    ? the detailed roar. Big RollOffMinDistance so it stays at full
--             volume across a wide core rather than falling off from the first
--             stud. That flat core is what makes it feel volumetric instead of
--             like a speaker at a point.
--   DISTANT ? a duller, longer clip carrying much further. Close up it's buried
--             under the near layer; far away it's all that's left, so the roar
--             arrives as a low roll across the map instead of vanishing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local CreatureUtil = require(ReplicatedStorage.Shared.CreatureUtil)

-- ===== DEFAULTS (each rig's CreatureConfig can override) =====
local DEFAULTS = {
	roarPartName = "RoarSounds",
	roarCooldown = 3.5,            -- seconds between roars
	roarCount = 3,                 -- how many roars are bound (keys 1..N)

	-- Near layer
	roarNearMinDistance = 40,      -- full volume out to here ? the "volumetric" core
	-- Dropped from 320: a near layer that carries too far is the main reason a
	-- roar never sounds distant. Its detail has to DISAPPEAR before the muffled
	-- layer can take over ? otherwise you always hear the close version underneath
	-- and your ear calls it close, however filtered the other layer is.
	roarNearMaxDistance = 190,
	roarNearVolumeMult = 1.0,

	-- Distant layer
	roarDistantMinDistance = 160,
	roarDistantMaxDistance = 1600, -- heard most of the way across a map
	roarDistantVolumeMult = 0.9,

	--[[
		PER-ROAR RANGE.

		The three roars aren't the same kind of noise, so they shouldn't carry the
		same distance. Range IS the meaning here: a sound the whole map hears reads
		as an announcement, and one that dies at thirty studs reads as something
		said to you specifically. Anything in this table overrides the values above
		for that roar only; anything missing falls through to them.

		  1  BROADCAST   calling across the map. Huge flat core, enormous tail.
		  2  PASSIVE     close-range, not a threat. Short, intimate, no long tail.
		  3  AGGRESSIVE  a threat to whoever is nearby. Loud and punchy up close,
		                 carrying well but not map-wide ? it's aimed at someone.
	--]]
	roarProfiles = {
		[1] = { -- broadcast
			nearMin = 70, nearMax = 320, nearVolume = 1.0,
			distantMin = 280, distantMax = 3000, distantVolume = 1.0,
		},
		[2] = { -- passive
			nearMin = 14, nearMax = 85, nearVolume = 0.8,
			distantMin = 75, distantMax = 420, distantVolume = 0.5,
		},
		[3] = { -- aggressive
			nearMin = 40, nearMax = 180, nearVolume = 1.15,
			distantMin = 160, distantMax = 1100, distantVolume = 0.85,
		},
	},

	--[[
		---- WHAT THE ROAR DOES TO EVERYONE ELSE ----
		Anyone in earshot gets a screen reaction: colour drains, a blur pulse, a
		vignette closing in, an FOV punch. Handled by the RoarEffects client
		system; these values are sent along with the event, because the listener
		isn't the creature and can't read its CreatureConfig.

		Radius comes from the roar's OWN profile ? the distant layer's max distance
		? so the broadcast roar reaches far more people than the passive one with
		nothing extra to configure. If you can hear it, you feel it.
	--]]
	roarFx = true,
	roarFxRadiusMult = 0.85,    -- fraction of the distant layer's reach
	roarFxMaxRadius = 650,      -- HARD CAP on that, whatever the roar's audio range
	roarFxAffectsCreatures = false, -- other creatures shrug it off
	roarFxAttack = 0.06,
	roarFxDecay = 12,
	roarFxColorCurve = 1.9,
	roarFxBlurCurve = 3.5,
	roarFxBloomCurve = 2.6,
	roarFxFovCurve = 5,
	roarFxSaturation = -0.8,
	roarFxContrast = 0.65,
	roarFxBrightness = -0.12,
	roarFxTint = Color3.fromRGB(255, 205, 195),
	roarFxContrastJitter = 0.22,
	roarFxContrastJitterSpeed = 5,
	roarFxBrightnessJitter = 0.16,
	roarFxBrightnessJitterSpeed = 11,
	roarFxBloomJitter = 1.6,
	roarFxBloomJitterSpeed = 3.4,
	roarFxBlur = 16,
	roarFxBloom = 7,
	roarFxBloomSize = 24,
	roarFxBloomThresholdIdle = 2,
	roarFxBloomThresholdFull = 0.85,
	roarFxVignetteImage = "rbxassetid://260155349",
	roarFxVignetteColor = Color3.fromRGB(14, 10, 10),
	roarFxVignette = 0.88,
	roarFxVignetteSize = 0.34,
	roarFxVignettePulse = 0.07,
	roarFxVignettePulseSpeed = 2.4,
	roarFxFov = 7,
	roarFxRingAsset = "rbxassetid://9069161602",
	roarFxRingVolume = 0.35,
	roarFxRingMinIntensity = 0.05,
	roarFxFalloff = 1.6,
	roarFxMinIntensity = 0.02,
	roarFxCombatMusic = true,
	roarFxCombatMinIntensity = 0.35,

	roarPitchMin = 0.96,
	roarPitchMax = 1.04,
	roarApplyRollOff = true,       -- false = leave your Sound properties untouched

	-- Movement lock during a full-body (idle) roar.
	roarLockMovement = false,
	roarLockFallbackTime = 1.6,    -- used when the animation's Length reads 0
	roarLockMaxTime = 5,           -- hard ceiling, so a bad clip can't freeze you

	-- ---- SYNTHETIC DISTANT LAYER ----
	-- With no separate distant recording, the distant layer is built from the
	-- near clip at runtime with SoundEffects.
	--
	-- Distance in the real world is mostly two things: air absorbs high
	-- frequencies long before low ones, and what reaches you has bounced off
	-- everything on the way. So: gut the treble, keep the bass, drown it in
	-- reverb, drop the pitch slightly. That's what "far away" sounds like.
	roarSynthDistant = true,
	roarDistantDelay = 0.14,       -- arrival delay; also stops the two layers
	-- sounding like one clip played twice
	roarDistantHighGain = -42,     -- dB. THE big one ? kills the crack and detail
	roarDistantMidGain = -12,      -- dB
	roarDistantLowGain = 5,        -- dB. bass survives distance, so lift it
	roarDistantOctave = 0.88,      -- pitch drop reads as bigger and further off

	-- ---- ECHO ----
	-- The slapback off the landscape. This is the cue reverb was meant to provide,
	-- built by hand instead: another copy of the clip, later, quieter and even more
	-- filtered. Because it's a separate Sound rather than an effect on the
	-- original, nothing ducks the dry signal and nothing sounds cut off.
	-- A long delay is what implies a big space ? that's the whole trick.
	roarEcho = true,
	roarEchoDelay = 0.42,          -- seconds after the roar. Longer = bigger world.
	roarEchoVolumeMult = 0.4,
	roarEchoHighGain = -55,        -- dB. almost nothing but low end left
	roarEchoMidGain = -16,
	roarEchoLowGain = 4,
	roarEchoOctave = 0.84,
}

local roarRemote = ReplicatedStorage:FindFirstChild("CreatureRoarRemote")
if not roarRemote then
	roarRemote = Instance.new("RemoteEvent")
	roarRemote.Name = "CreatureRoarRemote"
	roarRemote.Parent = ReplicatedStorage
end

local fxRemote = ReplicatedStorage:FindFirstChild("CreatureRoarFxRemote")
if not fxRemote then
	fxRemote = Instance.new("RemoteEvent")
	fxRemote.Name = "CreatureRoarFxRemote"
	fxRemote.Parent = ReplicatedStorage
end

-- "This creature roared roar N, here" -- to EVERY player, so each can draw the
-- visible shockwave (the RoarWave client system). Just the announcement; each
-- client builds and animates the spheres itself, which is what keeps them smooth.
local waveRemote = ReplicatedStorage:FindFirstChild("CreatureRoarWaveRemote")
if not waveRemote then
	waveRemote = Instance.new("RemoteEvent")
	waveRemote.Name = "CreatureRoarWaveRemote"
	waveRemote.Parent = ReplicatedStorage
end

local FX_KEYS = {
	"roarFxAttack", "roarFxDecay", "roarFxColorCurve", "roarFxBlurCurve",
	"roarFxBloomCurve", "roarFxFovCurve", "roarFxSaturation",
	"roarFxContrast", "roarFxBrightness", "roarFxTint",
	"roarFxContrastJitter", "roarFxContrastJitterSpeed",
	"roarFxBrightnessJitter", "roarFxBrightnessJitterSpeed",
	"roarFxBloomJitter", "roarFxBloomJitterSpeed", "roarFxBlur",
	"roarFxBloom", "roarFxBloomSize", "roarFxBloomThresholdIdle",
	"roarFxBloomThresholdFull", "roarFxVignetteImage", "roarFxVignetteColor",
	"roarFxVignette", "roarFxVignetteSize", "roarFxVignettePulse",
	"roarFxVignettePulseSpeed", "roarFxFov", "roarFxRingAsset",
	"roarFxRingVolume", "roarFxRingMinIntensity", "roarFxFalloff",
	"roarFxMinIntensity", "roarFxCombatMusic", "roarFxCombatMinIntensity",
}

local lastRoar: { [Model]: number } = {}

local function loadConfig(rig: Model)
	local cfg = table.clone(DEFAULTS)
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, userCfg = pcall(require, module)
		if ok and typeof(userCfg) == "table" then
			for k in pairs(DEFAULTS) do
				if userCfg[k] ~= nil then
					cfg[k] = userCfg[k]
				end
			end
		end
	end
	return cfg
end

--[[
	Fold roar N's profile into a copy of the config.

	Done as a MERGE rather than by teaching every call site about profiles: the
	rolloff values are read in four separate places (near layer, real distant
	layer, synthetic distant layer, echo), and threading an index through all of
	them is how you end up with the echo still using the default range because one
	call site got missed.
--]]
local PROFILE_KEYS = {
	nearMin = "roarNearMinDistance",
	nearMax = "roarNearMaxDistance",
	nearVolume = "roarNearVolumeMult",
	distantMin = "roarDistantMinDistance",
	distantMax = "roarDistantMaxDistance",
	distantVolume = "roarDistantVolumeMult",
}

local function withProfile(cfg, index: number)
	local profiles = cfg.roarProfiles
	if typeof(profiles) ~= "table" then
		return cfg
	end
	local profile = profiles[index]
	if typeof(profile) ~= "table" then
		return cfg
	end

	local merged = table.clone(cfg)
	for short, full in pairs(PROFILE_KEYS) do
		if profile[short] ~= nil then
			merged[full] = profile[short]
		end
	end
	return merged
end

-- ============================================================
-- THE ROAR PART
-- ============================================================
local function getRoarPart(rig: Model, cfg): BasePart?
	local root = rig:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local part = root:FindFirstChild(cfg.roarPartName)
	if not part then
		-- Also accept it anywhere in the rig, in case it got parented elsewhere.
		part = rig:FindFirstChild(cfg.roarPartName, true)
	end
	if not (part and part:IsA("BasePart")) then
		return nil
	end

	-- Make it behave: invisible, weightless, non-colliding, and actually attached.
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false

	local alreadyWelded = false
	for _, d in ipairs(part:GetChildren()) do
		if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Motor6D") then
			alreadyWelded = true
			break
		end
	end
	if not alreadyWelded and part ~= root then
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
	end

	return part
end

-- ============================================================
-- PLAYBACK
-- ============================================================
-- Collects the Sounds for one layer. A folder may hold several (Near1, Near2...)
-- for variation, or exactly one.
local function collectLayer(container: Instance, layerName: string): { Sound }
	local out = {}
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Sound") and string.sub(child.Name, 1, #layerName) == layerName then
			table.insert(out, child)
		end
	end
	return out
end

local function playLayer(template: Sound, parent: BasePart, cfg, isDistant: boolean, pitch: number)
	local snd = template:Clone()
	snd.Looped = false
	snd.PlaybackSpeed = template.PlaybackSpeed * pitch

	if cfg.roarApplyRollOff and snd:GetAttribute("KeepRollOff") ~= true then
		snd.RollOffMode = Enum.RollOffMode.InverseTapered
		if isDistant then
			snd.RollOffMinDistance = cfg.roarDistantMinDistance
			snd.RollOffMaxDistance = cfg.roarDistantMaxDistance
			snd.Volume = template.Volume * cfg.roarDistantVolumeMult
		else
			snd.RollOffMinDistance = cfg.roarNearMinDistance
			snd.RollOffMaxDistance = cfg.roarNearMaxDistance
			snd.Volume = template.Volume * cfg.roarNearVolumeMult
		end
	end

	snd.Parent = parent
	snd:Play()

	-- TimeLength can be 0 before the asset loads, so Debris gets a generous
	-- ceiling rather than a computed length that might be zero.
	Debris:AddItem(snd, math.max(snd.TimeLength, 1) + 12)
	return snd
end

-- Builds the distant layer out of the near clip. Used when a Roar folder has no
-- Distant sound of its own, or when the roar is a plain Sound.
--
-- Effect ORDER matters, and Priority is what sets it: EQ first so the reverb is
-- fed already-dulled audio. Reverberating the full-range clip and then cutting
-- the treble leaves a bright tail underneath, which sounds like a filter sweep
-- rather than distance.
local function playFilteredCopy(template: Sound, parent: BasePart, cfg, pitch: number, opts): number
	local snd = template:Clone()
	snd.Name = template.Name .. opts.suffix
	snd.Looped = false
	snd.PlaybackSpeed = template.PlaybackSpeed * pitch

	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMinDistance = cfg.roarDistantMinDistance
	snd.RollOffMaxDistance = cfg.roarDistantMaxDistance
	snd.Volume = template.Volume * opts.volumeMult

	local eq = Instance.new("EqualizerSoundEffect")
	eq.HighGain = opts.highGain
	eq.MidGain = opts.midGain
	eq.LowGain = opts.lowGain
	eq.Priority = 0
	eq.Parent = snd

	local pitchShift = Instance.new("PitchShiftSoundEffect")
	pitchShift.Octave = opts.octave
	pitchShift.Priority = 1
	pitchShift.Parent = snd

	snd.Parent = parent

	local length = snd.TimeLength
	if opts.delay > 0 then
		task.delay(opts.delay, function()
			if snd.Parent then
				snd:Play()
			end
		end)
	else
		snd:Play()
	end

	-- Generous ceiling, since TimeLength reads 0 until the asset has loaded.
	Debris:AddItem(snd, math.max(length, 1) + opts.delay + 12)
	return length + opts.delay
end

local function playSyntheticDistant(template: Sound, parent: BasePart, cfg, pitch: number): number
	local longest = playFilteredCopy(template, parent, cfg, pitch, {
		suffix = "_Distant",
		delay = cfg.roarDistantDelay,
		volumeMult = cfg.roarDistantVolumeMult,
		highGain = cfg.roarDistantHighGain,
		midGain = cfg.roarDistantMidGain,
		lowGain = cfg.roarDistantLowGain,
		octave = cfg.roarDistantOctave,
	})

	-- The echo: the roar coming back off the landscape a beat later, darker and
	-- quieter. It's a separate Sound rather than a reverb effect, so nothing ducks
	-- the original ? that's what went wrong with ReverbSoundEffect.
	if cfg.roarEcho then
		local echoLen = playFilteredCopy(template, parent, cfg, pitch, {
			suffix = "_Echo",
			delay = cfg.roarEchoDelay,
			volumeMult = cfg.roarEchoVolumeMult,
			highGain = cfg.roarEchoHighGain,
			midGain = cfg.roarEchoMidGain,
			lowGain = cfg.roarEchoLowGain,
			octave = cfg.roarEchoOctave,
		})
		longest = math.max(longest, echoLen)
	end

	return longest
end

--[[
	ROAR ANIMATIONS ? one per roar.

	    Roar1, Roar2, Roar3     in the rig's Animations folder
	    (falls back to a single "Roar" if a numbered one is missing)

	The Idle/Moving split is gone. ONE clip now plays whether you're standing or
	walking, which changes what the clip has to be: author it with NO KEYFRAMES ON
	THE LEGS. Then the walk cycle keeps driving them underneath and the two blend
	on their own ? that's a property of the animation data, not something the code
	arranges, which is exactly why one clip can cover both cases.

	If you DO put leg keyframes in it, the roar will override the walk and the
	creature will appear to skate while bellowing. That's what roarLockMovement is
	for: switch it on and you're rooted for the clip's length, at the cost of not
	being able to roar on the move.
--]]
-- Action2, not Action3: it has to sit ABOVE the walk cycle on the joints it
-- actually touches, without being so high that it stomps everything else. A
-- locking roar is a different kind of action and gets the higher slot.
local ROAR_PRIORITY_UPPER = Enum.AnimationPriority.Action2
local ROAR_PRIORITY_FULL = Enum.AnimationPriority.Action3

local function pickRoarAnim(folder: Instance, index: number)
	for _, name in ipairs({ "Roar" .. index, "Roar" }) do
		local a = folder:FindFirstChild(name)
		if a and a:IsA("Animation") then
			return a, name
		end
	end
	return nil, nil
end

-- Returns the track and whether it should lock movement.
local function playRoarAnimation(rig: Model, index: number, lockMovement: boolean)
	local hum = rig:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local folder = rig:FindFirstChild("Animations")
	if not (animator and folder) then
		return nil, false
	end

	local anim = pickRoarAnim(folder, index)
	if not anim then
		return nil, false
	end

	local track = animator:LoadAnimation(anim)
	track.Priority = lockMovement and ROAR_PRIORITY_FULL or ROAR_PRIORITY_UPPER
	track.Looped = false
	track:Play(0.15)

	return track, lockMovement
end

local function doRoar(rig: Model, index: number, movingHint: boolean?)
	local cfg = withProfile(loadConfig(rig), index)

	local now = os.clock()
	local last = lastRoar[rig]
	if last and now - last < cfg.roarCooldown then
		return
	end

	local part = getRoarPart(rig, cfg)
	if not part then
		warn(("[CreatureRoarServer] %s has no Part named '%s' in its HumanoidRootPart ? no roar.")
			:format(rig:GetFullName(), tostring(cfg.roarPartName)))
		return
	end

	local entry = part:FindFirstChild("Roar" .. index)
	if not entry then
		warn(("[CreatureRoarServer] No 'Roar%d' inside %s."):format(index, part:GetFullName()))
		local names = {}
		for _, child in ipairs(part:GetChildren()) do
			table.insert(names, child.Name .. " (" .. child.ClassName .. ")")
		end
		if #names == 0 then
			warn("[CreatureRoarServer]   ...that part is EMPTY. Put your roar Sounds inside it, named Roar1/Roar2/Roar3.")
		else
			warn("[CreatureRoarServer]   it contains: " .. table.concat(names, ", "))
		end
		return
	end

	lastRoar[rig] = now

	local pitch = math.random(
		math.floor(cfg.roarPitchMin * 100),
		math.floor(cfg.roarPitchMax * 100)
	) / 100

	local longest = 0

	if entry:IsA("Sound") then
		-- Plain Sound: play it near, and synthesise the distant layer from it.
		local snd = playLayer(entry, part, cfg, false, pitch)
		longest = math.max(longest, snd.TimeLength)
		if cfg.roarSynthDistant then
			longest = math.max(longest, playSyntheticDistant(entry, part, cfg, pitch))
		end

	elseif entry:IsA("Folder") then
		local nears = collectLayer(entry, "Near")
		local distants = collectLayer(entry, "Distant")

		-- A folder holding one unlabelled Sound still works ? treat it as the near.
		if #nears == 0 and #distants == 0 then
			for _, child in ipairs(entry:GetChildren()) do
				if child:IsA("Sound") then
					table.insert(nears, child)
				end
			end
		end

		if #nears == 0 and #distants == 0 then
			warn(("[CreatureRoarServer] '%s' contains no Sounds."):format(entry:GetFullName()))
			return
		end

		local nearTemplate = (#nears > 0) and nears[math.random(1, #nears)] or nil

		if nearTemplate then
			local snd = playLayer(nearTemplate, part, cfg, false, pitch)
			longest = math.max(longest, snd.TimeLength)
		end

		if #distants > 0 then
			-- A real distant recording beats a synthesised one, so it wins.
			-- Same pitch roll as the near layer, so the two read as one voice
			-- rather than two creatures roaring slightly out of tune.
			local snd = playLayer(distants[math.random(1, #distants)], part, cfg, true, pitch)
			longest = math.max(longest, snd.TimeLength)
		elseif cfg.roarSynthDistant and nearTemplate then
			longest = math.max(longest, playSyntheticDistant(nearTemplate, part, cfg, pitch))
		end
	else
		return
	end

	-- Published so anything else can react ? breathing could hold off, a HUD
	-- could show a cooldown.
	rig:SetAttribute("CreatureRoaring", true)

	-- The visible shockwave, for everyone. The position goes along because a
	-- player too far away to have the creature streamed in still sees the wave.
	-- Whether this creature has waves, and how big, is read from its
	-- CreatureConfig on each client.
	waveRemote:FireAllClients(rig, index, part.Position)

	--[[
		THE VICTIM REACTION.

		Fired per player rather than broadcast, because intensity depends on how
		far away each one is ? a shared broadcast would mean someone at the edge of
		earshot gets the same faceful as someone standing under it.

		This sits in doRoar deliberately, so every roar gets the reaction
		whatever triggered it.
	--]]
	if cfg.roarFx then
		local origin = part.Position
		--[[
			The screen effect's reach is capped INDEPENDENTLY of the audio's.

			Derived purely from the distant layer, the broadcast roar (3000 studs
			of audio) was still whiting out screens 1800 studs away, which is
			absurd ? you can hear a thing across a valley without it staggering
			you. Audio range says "this happened"; the effect radius says "this
			happened TO YOU", and those are different distances.

			So the cap applies to every roar equally. A broadcast roar still
			carries much further than a passive one ? you just stop feeling it at
			the same distance either way.
		--]]
		local radius = math.min(
			cfg.roarDistantMaxDistance * cfg.roarFxRadiusMult,
			cfg.roarFxMaxRadius
		)

		local overrides = {}
		for _, key in ipairs(FX_KEYS) do
			overrides[key] = cfg[key]
		end

		for _, other in ipairs(Players:GetPlayers()) do
			local char = other.Character
			local oroot = char and char:FindFirstChild("HumanoidRootPart")

			-- Never the creature that roared. Other creatures are optional, and
			-- off by default: a thing that deafens itself is not a predator.
			local skip = (char == rig)
				or (not cfg.roarFxAffectsCreatures and char and CreatureUtil.IsCreature(char))

			if oroot and not skip then
				local dist = (oroot.Position - origin).Magnitude
				if dist <= radius then
					-- Falloff > 1 concentrates it near the creature, so the
					-- difference between "close" and "audible" is felt rather
					-- than being a flat gradient across the whole radius.
					local t = 1 - math.clamp(dist / math.max(radius, 1), 0, 1)
					local intensity = t ^ cfg.roarFxFalloff
					fxRemote:FireClient(other, intensity, overrides)
				end
			end
		end
	end

	-- One clip per roar, played the same way standing or moving. movingHint still
	-- arrives from the client and is still accepted by the remote, but nothing
	-- reads it any more ? the animation no longer depends on what you're doing.
	local track, shouldLock = playRoarAnimation(rig, index, cfg.roarLockMovement == true)

	if shouldLock then
		-- Length can read 0 before the asset has loaded, so the lock falls back to
		-- a sane duration rather than unlocking on the same frame it locked.
		local lockTime = 0
		if track then
			lockTime = track.Length
		end
		if lockTime <= 0 then
			lockTime = cfg.roarLockFallbackTime
		end
		lockTime = math.min(lockTime, cfg.roarLockMaxTime)

		rig:SetAttribute("RoarLocked", true)

		-- Cleared on a timer AND on death, because a creature that dies mid-roar
		-- would otherwise respawn... well, it wouldn't, but the attribute would
		-- outlive the roar on a rig that is still around for its Debris window.
		task.delay(lockTime, function()
			if rig.Parent then
				rig:SetAttribute("RoarLocked", false)
			end
		end)
	end

	task.delay(math.max(longest, 1), function()
		if rig.Parent then
			rig:SetAttribute("CreatureRoaring", false)
		end
	end)
end

-- ============================================================
-- REMOTE
-- ============================================================
local DEBUG = true -- set false once roaring works

print("[CreatureRoarServer] Running. Remote created at ReplicatedStorage.CreatureRoarRemote")

roarRemote.OnServerEvent:Connect(function(player, index, movingNow)
	if typeof(index) ~= "number" or index ~= index then
		return
	end
	index = math.floor(index)

	if DEBUG then
		print(("[CreatureRoarServer] roar %d from %s (moving=%s)")
			:format(index, player.Name, tostring(movingNow)))
	end

	local rig = player.Character
	if not rig or rig:GetAttribute("IsCreature") ~= true then
		if DEBUG then warn("[CreatureRoarServer] rejected: sender is not a creature") end
		return
	end
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		if DEBUG then warn("[CreatureRoarServer] rejected: no humanoid or dead") end
		return
	end

	local cfg = loadConfig(rig)
	if index < 1 or index > cfg.roarCount then
		if DEBUG then warn("[CreatureRoarServer] rejected: index outside 1.." .. cfg.roarCount) end
		return
	end

	-- Only a boolean is accepted; anything else falls through to the velocity
	-- check inside doRoar. Which variant plays is cosmetic, so a client choosing
	-- its own is fine ? the worst a liar achieves is the wrong roar animation.
	if typeof(movingNow) ~= "boolean" then
		movingNow = nil
	end

	doRoar(rig, index, movingNow)
end)

CollectionService:GetInstanceRemovedSignal(CreatureUtil.TAG):Connect(function(rig)
	lastRoar[rig] = nil
end)

Players.PlayerRemoving:Connect(function(player)
	for rig in pairs(lastRoar) do
		if Players:GetPlayerFromCharacter(rig) == player then
			lastRoar[rig] = nil
		end
	end
end)
