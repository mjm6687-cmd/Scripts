-- Footsteps  (ModuleScript, under CreatureClient > Systems)
--
-- Driven by the "Footstep" animation marker. Runs for EVERY creature: animation
-- tracks replicate to every client's Animator, so each client hooks the marker
-- and plays the sound locally. Everyone hears everyone, nothing crosses the wire.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local System = {
	name = "Footsteps",
	key = "footsteps",
	scope = "rig",
}

local MARKER_NAME = "Footstep"

local DEFAULTS = {
	soundSet = "Stalker",
	minTimeBetweenSteps = 0.10,
	minTimeBetweenLands = 0.12,
	pitchMin = 0.90,
	pitchMax = 1.08,
	stepVolumeMultiplier = 1.0,
	sprintPitchMin = 0.82,   -- heavier impact is a LOWER sound; the cadence
	sprintPitchMax = 0.96,   -- already speeds up with the animation
	sprintVolumeMultiplier = 1.25,
	minMoveDir = 0.10,

	waterContactGrace = 0.05,
	waterCheckUpOffset = 2.0,
	waterCheckDownDistance = 8.0,

	foliageTag = "FoliageRustle",
	rustleFolder = "Rustle",
	foliagePitchMin = 0.95,
	foliagePitchMax = 1.05,
	foliageVolumeMultiplier = 0.7,
	defaultRustleRadius = 0,
	defaultRustleHeightUp = 0,
	defaultRustleHeightDown = 0,

	-- Markers are the good path: they fire exactly when a foot plants. But a rig
	-- with no animations, or animations with no Footstep events, would be totally
	-- silent — which during testing looks identical to "the sound system is
	-- broken". So distance-based steps stand in until a real marker fires, then
	-- retire permanently for that rig.
	footstepFallback = true,
	fallbackStride = 3.2,
}

local MATERIAL_TO_FOLDER = {
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Asphalt] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Granite] = "Concrete",
	[Enum.Material.Limestone] = "Concrete",
	[Enum.Material.Marble] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Basalt] = "Concrete",
	[Enum.Material.Rock] = "Rock",
	[Enum.Material.Sandstone] = "Ground",
	[Enum.Material.Grass] = "Grass",
	[Enum.Material.LeafyGrass] = "LeafyGrass",
	[Enum.Material.Fabric] = "Grass",
	[Enum.Material.Carpet] = "Grass",
	[Enum.Material.Ground] = "Ground",
	[Enum.Material.Mud] = "Mud",
	[Enum.Material.Sand] = "Sand",
	[Enum.Material.Snow] = "Snow",
	[Enum.Material.Glacier] = "Snow",
	[Enum.Material.Metal] = "Metal",
	[Enum.Material.DiamondPlate] = "DiamondPlate",
	[Enum.Material.CorrodedMetal] = "Metal",
	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "WoodPlanks",
	[Enum.Material.Plastic] = "Concrete",
	[Enum.Material.SmoothPlastic] = "Concrete",
	[Enum.Material.Water] = "Water",
}

local soundsRoot: Instance?
local rigs: { [Model]: any } = {}

-- ============================================================
-- NO-REPEAT SHUFFLE BAG
-- ============================================================
-- Pure random replays the same clip back to back often enough to read as "that's
-- one sound file". The bag draws every clip once before refilling, and a refill
-- that would open on the clip that just played swaps it back a slot.
local pickState: { [string]: { bag: { string }, last: string? } } = {}

local function shuffleInPlace(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

local function nextSoundName(key: string, folder: Instance): string?
	local names = {}
	for _, inst in ipairs(folder:GetChildren()) do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end
	if #names == 0 then return nil end
	if #names == 1 then return names[1] end

	local st = pickState[key]
	if not st then
		st = { bag = {}, last = nil }
		pickState[key] = st
	end

	if #st.bag == 0 then
		st.bag = table.clone(names)
		shuffleInPlace(st.bag)
		if st.last and st.bag[1] == st.last and #st.bag >= 2 then
			st.bag[1], st.bag[2] = st.bag[2], st.bag[1]
		end
	end

	local chosen = table.remove(st.bag)
	if chosen == st.last and #names >= 2 then
		for _, n in ipairs(names) do
			if n ~= st.last then chosen = n break end
		end
	end

	st.last = chosen
	return chosen
end

-- ============================================================
-- PLAYBACK
-- ============================================================
local function playFrom(folder: Instance, key: string, parent: BasePart, volumeMul: number?, pitch: number)
	local chosen = nextSoundName(key, folder)
	if not chosen then return end

	local template = folder:FindFirstChild(chosen)
	if not (template and template:IsA("Sound")) then return end

	local s = template:Clone()
	if typeof(volumeMul) == "number" then
		s.Volume = template.Volume * volumeMul
	end
	s.PlaybackSpeed = pitch
	s.Parent = parent
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
end

local function playSurface(state, kind: string, matName: string, volumeMul: number?, pitch: number)
	if not state.soundSet then return end
	local kindFolder = state.soundSet:FindFirstChild(kind)
	if not (kindFolder and kindFolder:IsA("Folder")) then return end

	local matFolder = kindFolder:FindFirstChild(matName) or kindFolder:FindFirstChild("Concrete")
	if not (matFolder and matFolder:IsA("Folder")) then return end

	playFrom(matFolder, kind .. "|" .. matFolder:GetFullName(), state.root, volumeMul, pitch)
end

local function randomPitch(a: number, b: number): number
	return math.random(math.floor(a * 100), math.floor(b * 100)) / 100
end

-- ============================================================
-- WATER
-- ============================================================
local function pointHitsWater(state, origin: Vector3): boolean
	local result = workspace:Raycast(
		origin + Vector3.new(0, state.cfg.waterCheckUpOffset, 0),
		Vector3.new(0, -state.cfg.waterCheckDownDistance, 0),
		state.waterParams
	)
	return result ~= nil and result.Material == Enum.Material.Water
end

local function touchingWater(state): boolean
	if state.root and pointHitsWater(state, state.root.Position) then return true end
	if state.leftFoot and pointHitsWater(state, state.leftFoot.Position) then return true end
	if state.rightFoot and pointHitsWater(state, state.rightFoot.Position) then return true end
	return false
end

local function updateWater(state)
	if touchingWater(state) then
		state.lastWaterT = os.clock()
	end
end

local function recentlyWater(state): boolean
	return (os.clock() - state.lastWaterT) <= state.cfg.waterContactGrace
end

-- Feet in shallow water while FloorMaterial still reports the bed underneath is
-- exactly the case the grace window exists for.
local function materialFolder(state, useGrace: boolean?): string
	if touchingWater(state) or recentlyWater(state) then return "Water" end
	if useGrace and recentlyWater(state) then return "Water" end
	return MATERIAL_TO_FOLDER[state.humanoid.FloorMaterial] or "Concrete"
end

-- ============================================================
-- FOLIAGE
-- ============================================================
local function insideFoliage(state): boolean
	if not state.root then return false end
	local pos = state.root.Position
	local cfg = state.cfg

	for _, inst in ipairs(CollectionService:GetTagged(cfg.foliageTag)) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			local rel = inst.CFrame:PointToObjectSpace(pos)
			local r = inst:GetAttribute("RustleRadius")
			local hu = inst:GetAttribute("RustleHeightUp")
			local hd = inst:GetAttribute("RustleHeightDown")

			local radius = typeof(r) == "number" and r or cfg.defaultRustleRadius
			local up = typeof(hu) == "number" and hu or cfg.defaultRustleHeightUp
			local down = typeof(hd) == "number" and hd or cfg.defaultRustleHeightDown

			if math.abs(rel.X) <= radius and math.abs(rel.Z) <= radius
				and rel.Y >= -down and rel.Y <= up then
				return true
			end
		end
	end
	return false
end

local function playFoliage(state)
	if not state.soundSet or not insideFoliage(state) then return end
	local folder = state.soundSet:FindFirstChild(state.cfg.rustleFolder)
	if not (folder and folder:IsA("Folder")) then return end

	playFrom(folder, "Rustle|" .. folder:GetFullName(), state.root,
		state.cfg.foliageVolumeMultiplier,
		randomPitch(state.cfg.foliagePitchMin, state.cfg.foliagePitchMax))
end

-- ============================================================
-- STEPS
-- ============================================================
local function playStep(state)
	local hum, cfg = state.humanoid, state.cfg
	if hum.Health <= 0 then return end
	if hum.FloorMaterial == Enum.Material.Air and not recentlyWater(state) then return end
	if hum.MoveDirection.Magnitude < cfg.minMoveDir then return end
	if hum:GetState() == Enum.HumanoidStateType.Climbing then return end

	local now = os.clock()
	if now - state.lastStepT < cfg.minTimeBetweenSteps then return end
	state.lastStepT = now

	local sprinting = state.rig:GetAttribute("CreatureSprinting") == true
	local pitchMin = sprinting and cfg.sprintPitchMin or cfg.pitchMin
	local pitchMax = sprinting and cfg.sprintPitchMax or cfg.pitchMax
	local volume = sprinting and cfg.sprintVolumeMultiplier or cfg.stepVolumeMultiplier

	playSurface(state, "Walking", materialFolder(state, false), volume, randomPitch(pitchMin, pitchMax))
	playFoliage(state)
end

local function playLand(state)
	local hum, cfg = state.humanoid, state.cfg
	if hum.Health <= 0 then return end

	local now = os.clock()
	if now - state.lastLandT < cfg.minTimeBetweenLands then return end
	state.lastLandT = now

	if hum.FloorMaterial == Enum.Material.Air and not recentlyWater(state) then return end

	playSurface(state, "Landing", materialFolder(state, true),
		cfg.stepVolumeMultiplier, randomPitch(cfg.pitchMin, cfg.pitchMax))
end

-- ============================================================
-- MARKERS
-- ============================================================
local function hookTrack(state, track: AnimationTrack)
	if state.hooked[track] then return end
	state.hooked[track] = true

	table.insert(state.conns, track:GetMarkerReachedSignal(MARKER_NAME):Connect(function()
		state.markerEverFired = true -- the distance fallback retires for good
		playStep(state)
	end))

	table.insert(state.conns, track.Stopped:Connect(function()
		state.hooked[track] = nil
	end))
end

local function scanTracks(state)
	for _, track in ipairs(state.animator:GetPlayingAnimationTracks()) do
		hookTrack(state, track)
	end
end

local function getFeet(char: Model): (BasePart?, BasePart?)
	local lf = char:FindFirstChild("LeftFoot") or char:FindFirstChild("Left Leg")
	local rf = char:FindFirstChild("RightFoot") or char:FindFirstChild("Right Leg")
	if lf and lf:IsA("BasePart") and rf and rf:IsA("BasePart") then
		return lf, rf
	end
	return nil, nil
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function System.init()
	soundsRoot = ReplicatedStorage:FindFirstChild("CreatureSounds")
	if not soundsRoot then
		task.spawn(function()
			soundsRoot = ReplicatedStorage:WaitForChild("CreatureSounds", 20)
		end)
	end
end

function System.onAdded(rig: Model, config)
	local cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	task.spawn(function()
		local humanoid = rig:WaitForChild("Humanoid", 10)
		local root = rig:WaitForChild("HumanoidRootPart", 10)
		if not (humanoid and root and rig.Parent) then return end
		local animator = humanoid:WaitForChild("Animator", 10)
		if not animator then return end

		local set = soundsRoot and soundsRoot:FindFirstChild(cfg.soundSet)
		if not set then
			warn(("[Footsteps] No ReplicatedStorage.CreatureSounds.%s — %s is silent.")
				:format(tostring(cfg.soundSet), rig:GetFullName()))
		end

		local waterParams = RaycastParams.new()
		waterParams.FilterType = Enum.RaycastFilterType.Exclude
		waterParams.FilterDescendantsInstances = { rig }
		waterParams.IgnoreWater = false

		local leftFoot, rightFoot = getFeet(rig)

		local state = {
			rig = rig, humanoid = humanoid, root = root, animator = animator,
			cfg = cfg, soundSet = set, waterParams = waterParams,
			leftFoot = leftFoot, rightFoot = rightFoot,
			lastStepT = 0, lastLandT = 0, lastWaterT = 0,
			markerEverFired = false, fallbackDistance = 0, lastPos = root.Position,
			slowAccum = 0,
			hooked = setmetatable({}, { __mode = "k" }),
			conns = {},
		}
		rigs[rig] = state

		-- Roblox's own footstep sound, which would play underneath ours.
		task.defer(function()
			local s = root:FindFirstChild("Running")
			if s and s:IsA("Sound") then s:Destroy() end
		end)

		updateWater(state)
		scanTracks(state)

		table.insert(state.conns, animator.AnimationPlayed:Connect(function(track)
			hookTrack(state, track)
		end))

		table.insert(state.conns, humanoid.StateChanged:Connect(function(_, newState)
			updateWater(state)
			if newState == Enum.HumanoidStateType.Landed then
				playLand(state)
			end
		end))
	end)
end

function System.onRemoved(rig: Model)
	local state = rigs[rig]
	if state then
		for _, c in ipairs(state.conns) do
			c:Disconnect()
		end
	end
	rigs[rig] = nil
end

function System.update(dt: number)
	for rig, state in pairs(rigs) do
		if not rig.Parent or state.humanoid.Health <= 0 then
			continue
		end

		-- Water has to be sampled continuously, not at step time: a step lands on
		-- the same frame the marker fires, so a check starting then has already
		-- missed the foot entering the water.
		updateWater(state)

		if state.cfg.footstepFallback and not state.markerEverFired and state.root then
			local pos = state.root.Position
			local delta = Vector3.new(pos.X - state.lastPos.X, 0, pos.Z - state.lastPos.Z).Magnitude
			state.lastPos = pos

			if state.humanoid.FloorMaterial ~= Enum.Material.Air
				and state.humanoid.MoveDirection.Magnitude >= state.cfg.minMoveDir then
				state.fallbackDistance += delta
				if state.fallbackDistance >= state.cfg.fallbackStride then
					state.fallbackDistance = 0
					playStep(state)
				end
			else
				state.fallbackDistance = 0
			end
		end

		state.slowAccum += dt
		if state.slowAccum >= 0.15 then
			state.slowAccum = 0
			state.leftFoot, state.rightFoot = getFeet(rig)
			scanTracks(state)
		end
	end
end

return System
