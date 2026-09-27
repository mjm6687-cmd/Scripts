-- RoarWave  (ModuleScript, under CreatureClient > Systems)
--
-- The roar made visible: shells of ForceField-material spheres bursting out
-- from the creature's mouth. Everyone sees it -- the roar is loud enough that
-- the air itself shows it.
--
-- ============================================================
-- WHY EACH CLIENT DRAWS ITS OWN
-- ============================================================
-- CreatureRoarServer only announces "this creature roared roar N, here"
-- (CreatureRoarWaveRemote, to every player). Each client builds the spheres
-- locally and tweens them. Tweening a part's Size on the SERVER replicates at
-- network rate, so a wave that should be one smooth burst arrives as a stutter
-- of steps -- and the fast attack is the whole effect.
--
-- Like RoarEffects, this lives entirely in init(), so it runs for everybody,
-- creature or not.
--
-- ============================================================
-- TUNING
-- ============================================================
-- Per creature, in CreatureConfig: roarWave = false turns it off, and
-- roarWaves = { [1] = {...}, [2] = {...}, [3] = {...} } overrides any of the
-- fields in WAVE_DEFAULTS below, per roar. Anything left out falls through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local System = {
	name = "RoarWave",
	key = "roarwave",
	scope = "local",
}

--[[
	One entry per roar, matching the three roar profiles in CreatureRoarServer:
	the range of the wave says what kind of roar it was, same as the sound does.

	  radius        studs the outermost shell reaches
	  duration      seconds to get there and fade out
	  rings         how many shells, each a little smaller and a little later
	  ringGap       seconds between shells
	  ringShrink    each later shell's radius as a fraction of the one before
	  color         ForceField glows in this colour
	  transparency  how see-through each shell starts (1 = invisible)
--]]
local WAVE_DEFAULTS = {
	[1] = { -- R, broadcast: calling across the map. Big, slow, layered.
		radius = 170, duration = 2.4, rings = 3, ringGap = 0.2, ringShrink = 0.8,
		color = Color3.fromRGB(255, 255, 255), transparency = 0.8,
	},
	[2] = { -- C, passive: close range, barely there. You have to be near it.
		radius = 22, duration = 1.3, rings = 1, ringGap = 0, ringShrink = 1,
		color = Color3.fromRGB(255, 255, 255), transparency = 0.8,
	},
	[3] = { -- V, aggressive: aimed at someone. Fast and hard.
		radius = 65, duration = 0.95, rings = 2, ringGap = 0.09, ringShrink = 0.75,
		color = Color3.fromRGB(255, 255, 255), transparency = 0.8,
	},
}

-- A shell this big starts at the mouth, not at zero: a sphere growing from a
-- point spends its first frames as an invisible speck.
local START_SIZE = 2

-- Don't build waves for roars this far from the camera; nobody could see them.
local MAX_VIEW_DISTANCE = 1500

-- Out FAST, then slow down: the burst is the violent part, the spreading is the
-- echo of it. Quint is sharper than Quart, and that sharpness is what reads as
-- a pressure wave rather than a bubble inflating.
local SIZE_EASING = TweenInfo.new(1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local CreatureUtil
local getConfig
local folder: Folder?

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	-- Local to this client; parented under the camera so it can never collide
	-- with or be found by anything in the world.
	local f = Instance.new("Folder")
	f.Name = "CreatureRoarWaves"
	f.Parent = workspace.CurrentCamera
	folder = f
	return f
end

local function plainPart(shape: Enum.PartType, color: Color3): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.ForceField
	p.Color = color
	return p
end

-- Settings for roar `index` on this rig: WAVE_DEFAULTS, then the creature's own
-- overrides on top. nil = this creature has waves switched off.
local function waveSettings(rig: Model?, index: number)
	local base = WAVE_DEFAULTS[index]
	if not base then
		return nil
	end
	local out = table.clone(base)

	local cfg = rig and getConfig and getConfig(rig)
	if typeof(cfg) == "table" then
		if cfg.roarWave == false then
			return nil
		end
		local overrides = typeof(cfg.roarWaves) == "table" and cfg.roarWaves[index]
		if typeof(overrides) == "table" then
			for k in pairs(base) do
				if overrides[k] ~= nil then
					out[k] = overrides[k]
				end
			end
		end
	end
	return out
end

-- Where the roar comes out: the mouth if the rig has one (read on THIS client,
-- so it's where this player sees the head), else the head, else what the server
-- sent -- which is all there is when the creature is streamed out.
local function roarOrigin(rig: Model?, fallback: Vector3): Vector3
	if rig and rig.Parent then
		local cfg = getConfig and getConfig(rig)
		local mouthName = (typeof(cfg) == "table" and typeof(cfg.mouthAttachmentName) == "string")
			and cfg.mouthAttachmentName or "MouthAttachment"
		local head = rig:FindFirstChild("Head")
		local mouth = head and head:FindFirstChild(mouthName)
		if mouth and mouth:IsA("Attachment") then
			return mouth.WorldPosition
		end
		if head and head:IsA("BasePart") then
			return head.Position
		end
	end
	return fallback
end

local function spawnShell(origin: Vector3, radius: number, duration: number, color: Color3, transparency: number)
	local shell = plainPart(Enum.PartType.Ball, color)
	shell.Name = "RoarShell"
	shell.Size = Vector3.one * START_SIZE
	shell.CFrame = CFrame.new(origin)
	shell.Transparency = transparency
	shell.Parent = ensureFolder()

	local diameter = radius * 2
	TweenService:Create(shell,
		TweenInfo.new(duration, SIZE_EASING.EasingStyle, SIZE_EASING.EasingDirection),
		{ Size = Vector3.one * diameter }
	):Play()

	-- The fade LAGS the growth (Quad In): the shell holds its strength through the
	-- burst and only thins out as it slows, so it reads as spending its energy
	-- rather than just vanishing.
	TweenService:Create(shell,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 }
	):Play()

	Debris:AddItem(shell, duration + 0.1)
end

local function playWave(rig: Model?, index: number, serverOrigin: Vector3)
	local s = waveSettings(rig, index)
	if not s then
		return
	end

	local origin = roarOrigin(rig, serverOrigin)

	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - origin).Magnitude > MAX_VIEW_DISTANCE + s.radius then
		return
	end

	local rings = math.max(1, math.floor(s.rings))
	for i = 1, rings do
		local radius = s.radius * (s.ringShrink ^ (i - 1))
		local transparency = math.clamp(s.transparency, 0, 1)
		local delay = s.ringGap * (i - 1)
		if delay <= 0 then
			spawnShell(origin, radius, s.duration, s.color, transparency)
		else
			task.delay(delay, spawnShell, origin, radius, s.duration, s.color, transparency)
		end
	end
end

function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil
	getConfig = ctx.getConfig

	-- Spawned, not awaited, so a missing server script can't hold up the rest of
	-- CreatureClient's startup.
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("CreatureRoarWaveRemote", 30)
		if not remote then
			warn("[RoarWave] CreatureRoarWaveRemote never appeared - is CreatureRoarServer up to date?")
			return
		end

		remote.OnClientEvent:Connect(function(rig, index, serverOrigin)
			if typeof(index) ~= "number" or typeof(serverOrigin) ~= "Vector3" then
				return
			end
			-- The rig can legitimately be nil here: with streaming on, a creature
			-- far away doesn't exist on this client. The wave still plays from the
			-- position the server sent.
			if typeof(rig) ~= "Instance" or not rig:IsA("Model") then
				rig = nil
			elseif CreatureUtil and not CreatureUtil.IsCreature(rig) then
				rig = nil
			end
			playWave(rig, math.floor(index), serverOrigin)
		end)
	end)
end

return System
