-- CreatureBreathing
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- One job: breathing. One breath at a time, played to completion, then a random
-- gap, then the next. Two breaths can never overlap.
--
-- ============================================================
-- SETUP
-- ============================================================
-- A Part named BreathingSounds inside the rig's HumanoidRootPart, with the
-- breath Sounds directly inside it — same shape as RoarSounds:
--
--   HumanoidRootPart
--   +-- BreathingSounds     (Part — invisible, massless, no collision)
--       +-- Breath1         (Sound)
--       +-- Breath2         (Sound)
--       +-- Breath3         (Sound)
--
-- Sound names don't matter; any Sound in the part is a candidate. Set
-- Looped = FALSE on all of them — a looped breath never ends, so the loop parks
-- forever waiting for it.
--
-- The part is welded, hidden and made massless automatically, so you can just
-- drop one in. Left unwelded it would be abandoned on the ground the moment the
-- creature moved.
--
-- Still supports the old Head > Breathing folder if you have one, but the part
-- wins when both exist.
--
-- ============================================================
-- "IT SOUNDS LIKE IT'S ALL AROUND ME"
-- ============================================================
-- That's RollOffMinDistance. Inside that radius a sound plays at FULL volume with
-- no attenuation, so a big value makes it feel like it's everywhere at once
-- instead of coming from the creature. Roars want that (it's what makes them feel
-- enormous); breathing absolutely does not — it should pull you toward where the
-- creature actually is.
-- breathMinDistance below is deliberately small for exactly that reason.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureUtil = require(ReplicatedStorage.Shared.CreatureUtil)

local DEFAULTS = {
	breathPartName = "BreathingSounds",
	breathFolder = "Breathing",   -- legacy fallback: Head > Breathing
	breathMinGap = 5,             -- shortest silence between breaths (seconds)
	breathMaxGap = 35,            -- longest silence between breaths
	breathFirstDelayMin = 2,      -- first breath comes sooner, so you get feedback
	breathFirstDelayMax = 6,
	breathPitchMin = 0.94,
	breathPitchMax = 1.06,
	breathVolumeMultiplier = 1.0,
	breathMaxWait = 20,           -- safety cap waiting for a breath to finish
	breathDebug = false,

	-- Positioning. Small min distance = clearly located rather than everywhere.
	breathApplyRollOff = true,    -- false = leave your Sound properties alone
	breathMinDistance = 6,        -- full volume only this close
	breathMaxDistance = 110,      -- silent beyond here
}

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

-- Finds the emitter and makes it behave. Returns the part the sounds live in.
local function getBreathSource(rig: Model, cfg): (Instance?, BasePart?)
	local root = rig:FindFirstChild("HumanoidRootPart")

	local part = root and root:FindFirstChild(cfg.breathPartName)
	if not part then
		part = rig:FindFirstChild(cfg.breathPartName, true)
	end

	if part and part:IsA("BasePart") then
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Anchored = false

		local welded = false
		for _, d in ipairs(part:GetChildren()) do
			if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Motor6D") then
				welded = true
				break
			end
		end
		if not welded and root and part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end

		return part, part
	end

	-- Legacy: Head > Breathing folder.
	local head = rig:FindFirstChild("Head")
	local folder = head and head:FindFirstChild(cfg.breathFolder)
	if folder and folder:IsA("Folder") and head:IsA("BasePart") then
		return folder, head
	end

	return nil, nil
end

local function collectSounds(container: Instance): { Sound }
	local out = {}
	for _, s in ipairs(container:GetChildren()) do
		if s:IsA("Sound") then
			table.insert(out, s)
		end
	end
	return out
end

local function randomRange(minV: number, maxV: number): number
	if maxV <= minV then
		return minV
	end
	return minV + math.random() * (maxV - minV)
end

-- Waits for a sound to genuinely finish.
--
-- Not task.wait(sound.TimeLength): TimeLength is 0 until the asset loads, so on
-- the first play that returns instantly and the gaps collapse. Ended is the real
-- signal; the timeout stops a sound that never loads parking the loop forever.
local function waitForSoundEnd(sound: Sound, maxWait: number)
	local finished = false
	local conn = sound.Ended:Once(function()
		finished = true
	end)

	local startedAt = os.clock()
	while not finished do
		if os.clock() - startedAt > maxWait then break end
		if not sound.Parent then break end
		if not sound.IsPlaying and os.clock() - startedAt > 0.5 then break end
		task.wait(0.1)
	end

	if conn then
		conn:Disconnect()
	end
end

local function runBreathing(rig: Model)
	local humanoid = rig:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	local cfg = loadConfig(rig)

	-- Give the rig a moment to finish assembling before deciding it has no part.
	local container, emitPart
	for _ = 1, 20 do
		container, emitPart = getBreathSource(rig, cfg)
		if container then break end
		task.wait(0.25)
	end

	if not (container and emitPart) then
		warn(("[CreatureBreathing] %s has no Part named '%s' in its HumanoidRootPart "):format(
			rig:GetFullName(), tostring(cfg.breathPartName))
				.. "(and no legacy Head." .. tostring(cfg.breathFolder) .. " folder) — creature will not breathe.")
		return
	end

	local sounds = collectSounds(container)
	if #sounds == 0 then
		warn(("[CreatureBreathing] '%s' contains no Sound objects — creature will not breathe.")
			:format(container:GetFullName()))
		return
	end

	for _, s in ipairs(sounds) do
		if s.Looped then
			warn(("[CreatureBreathing] '%s' has Looped = true. It never ends, so breathing "):format(s:GetFullName())
				.. "stalls after the first one. Set Looped = false.")
		end
	end

	if cfg.breathDebug then
		print(("[CreatureBreathing] %s ready: %d sound(s), emitting from %s")
			:format(rig:GetFullName(), #sounds, emitPart:GetFullName()))
	end

	local lastIndex = -1

	task.spawn(function()
		task.wait(randomRange(cfg.breathFirstDelayMin, cfg.breathFirstDelayMax))

		while rig.Parent and humanoid.Health > 0 do
			local index = math.random(1, #sounds)
			if #sounds > 1 and index == lastIndex then
				index = (index % #sounds) + 1
			end
			lastIndex = index

			local template = sounds[index]

			-- Cloned so the template's own properties stay untouched and a pitch
			-- roll never sticks to the original.
			local snd = template:Clone()
			snd.Looped = false
			snd.PlaybackSpeed = template.PlaybackSpeed * randomRange(cfg.breathPitchMin, cfg.breathPitchMax)
			snd.Volume = template.Volume * cfg.breathVolumeMultiplier

			if cfg.breathApplyRollOff and snd:GetAttribute("KeepRollOff") ~= true then
				snd.RollOffMode = Enum.RollOffMode.InverseTapered
				snd.RollOffMinDistance = cfg.breathMinDistance
				snd.RollOffMaxDistance = cfg.breathMaxDistance
			end

			snd.Parent = emitPart
			snd:Play()

			if cfg.breathDebug then
				print(("[CreatureBreathing] '%s' pitch %.2f"):format(template.Name, snd.PlaybackSpeed))
			end

			waitForSoundEnd(snd, cfg.breathMaxWait)
			snd:Destroy()

			if not rig.Parent or humanoid.Health <= 0 then
				break
			end

			local gap = randomRange(cfg.breathMinGap, cfg.breathMaxGap)
			if cfg.breathDebug then
				print(("[CreatureBreathing] next breath in %.1fs"):format(gap))
			end
			task.wait(gap)
		end
	end)
end

for _, rig in ipairs(CollectionService:GetTagged(CreatureUtil.TAG)) do
	task.spawn(runBreathing, rig)
end

CollectionService:GetInstanceAddedSignal(CreatureUtil.TAG):Connect(function(rig)
	task.spawn(runBreathing, rig)
end)
