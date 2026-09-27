local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local assets = ReplicatedStorage:WaitForChild("SPH_Assets")
local soundsRoot = assets:WaitForChild("FootstepSounds")
local config = require(assets.GameConfig)

local bridgeNet = require(assets.Modules.BridgeNet)
local repFootstep = bridgeNet.CreateBridge("ReplicateFootstep")

-- ===== TUNING =====
local MARKER_NAME = "Footstep"

local MIN_TIME_BETWEEN_STEPS = 0.10
local PITCH_MIN = 0.91
local PITCH_MAX = 1.05

local MIN_TIME_BETWEEN_LANDS = 0.12

local RUN_SPEED_THRESHOLD = 13.5
local MIN_MOVE_DIR = 0.10

local CROUCH_SURFACE_VOLUME_MULTIPLIER = 0.32
local CROUCH_GENERIC_VOLUME_MULTIPLIER = 0.65

local CROUCH_PITCH_MIN = 0.92
local CROUCH_PITCH_MAX = 1.03

local SWIM_PITCH_MIN = 0.92
local SWIM_PITCH_MAX = 1.06

local MIN_TIME_BETWEEN_SWIM_TRANSITIONS = 0.45
local lastSwimTransitionT = 0.0

local WATER_CONTACT_GRACE_TIME = 0.05
local lastWaterContactT = 0.0

local WATER_CHECK_UP_OFFSET = 2.0
local WATER_CHECK_DOWN_DISTANCE = 8.0

local FOLIAGE_TAG = "FoliageRustle"
local FOLIAGE_PITCH_MIN = 0.95
local FOLIAGE_PITCH_MAX = 1.05
local FOLIAGE_WALK_VOLUME_MULTIPLIER = 0.6
local FOLIAGE_RUN_VOLUME_MULTIPLIER = 1.0

-- Separate rustle sound folders for walking vs sprinting/running
local RUSTLE_FOLDER_WALK = "RustleSounds"
local RUSTLE_FOLDER_RUN = "RustleSoundsSprint"

local DEFAULT_RUSTLE_RADIUS = 0
local DEFAULT_RUSTLE_HEIGHT_UP = 0
local DEFAULT_RUSTLE_HEIGHT_DOWN = 0

-- ===== EXOSKELETON =====
-- A servo whine laid OVER whatever step just played, so the surface still reads
-- through it -- concrete still sounds like concrete, you just hear the frame
-- working on top of it. An extra layer, never a replacement.
--
-- NO MATERIAL SUB-FOLDERS, on purpose: a powered frame sounds the same on grass as
-- it does on metal, because what you are hearing is the actuators and not the
-- ground. That is why there is no EXO_MATERIAL_TO_FOLDER table -- there would be
-- nothing to put in it. Drop Sounds straight into the folder and they shuffle with
-- no repeats, exactly like every other layer in here:
--
--     SPH_Assets.FootstepSounds.ExoFootsteps        walking, crouched, prone
--     SPH_Assets.FootstepSounds.ExoFootstepsSprint  sprinting
--
-- Two folders for the same reason RustleSounds / RustleSoundsSprint are two: a
-- servo under load is a different noise, not a louder one. The sprint folder is
-- OPTIONAL -- leave it out, or leave it empty, and sprinting falls back to the walk
-- servos rather than going silent, so you can ship the suit with one folder and add
-- the sprint set later without touching this file.
--
-- The character attribute is set by ArsenalServer from the equipped suit, so it
-- replicates and other players hear the layer on you too.
local EXO_FOLDER = "ExoFootsteps"
local EXO_FOLDER_SPRINT = "ExoFootstepsSprint"

local EXO_ATTRIBUTE = "Exoskeleton"

local EXO_VOLUME_MULTIPLIER = 1.0
local EXO_SPRINT_VOLUME_MULTIPLIER = 1.0
local EXO_CROUCH_VOLUME_MULTIPLIER = 0.45 -- moving carefully works the servos less

-- Pitch is randomized per step so the same clip never reads as a loop. Sprinting
-- sits slightly higher: the actuators are driving faster, and a flat repeat of the
-- walk pitch at sprint cadence is the most obvious "that's one sound file" tell.
local EXO_PITCH_MIN = 0.94
local EXO_PITCH_MAX = 1.06
local EXO_SPRINT_PITCH_MIN = 0.96
local EXO_SPRINT_PITCH_MAX = 1.08

-- Prone: single layer with its own material folders
local PRONE_VOLUME_MULTIPLIER = 0.7
local PRONE_PITCH_MIN = 0.90
local PRONE_PITCH_MAX = 1.04

-- Maps floor materials to prone-specific sound folders (Metal, Grass, Dirt, Concrete)
local PRONE_MATERIAL_TO_FOLDER = {
	-- Metal
	[Enum.Material.Metal]          = "Metal",
	[Enum.Material.DiamondPlate]   = "Metal",
	[Enum.Material.CorrodedMetal]  = "Metal",

	-- Grass
	[Enum.Material.Grass]          = "Grass",
	[Enum.Material.LeafyGrass]     = "Grass",
	[Enum.Material.Fabric]         = "Grass",
	[Enum.Material.Carpet]         = "Grass",

	-- Dirt
	[Enum.Material.Ground]         = "Dirt",
	[Enum.Material.Mud]            = "Dirt",
	[Enum.Material.Sand]           = "Dirt",
	[Enum.Material.Snow]           = "Dirt",

	-- Concrete (default / fallback)
	[Enum.Material.Concrete]       = "Concrete",
	[Enum.Material.Asphalt]        = "Concrete",
	[Enum.Material.Brick]          = "Concrete",
	[Enum.Material.Cobblestone]    = "Concrete",
	[Enum.Material.Pavement]       = "Concrete",
	[Enum.Material.Rock]           = "Concrete",
	[Enum.Material.Granite]        = "Concrete",
	[Enum.Material.Limestone]      = "Concrete",
	[Enum.Material.Marble]         = "Concrete",
	[Enum.Material.Slate]          = "Concrete",
	[Enum.Material.Basalt]         = "Concrete",
	[Enum.Material.Sandstone]      = "Concrete",

	-- Wood -> Concrete (no wood-specific prone folder)
	[Enum.Material.Wood]           = "Concrete",
	[Enum.Material.WoodPlanks]     = "Concrete",

	-- Plastic -> Concrete
	[Enum.Material.Plastic]        = "Concrete",
	[Enum.Material.SmoothPlastic]  = "Concrete",
}

local MATERIAL_TO_FOLDER = {
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Asphalt] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Rock] = "Rock",
	[Enum.Material.Granite] = "Concrete",
	[Enum.Material.Limestone] = "Concrete",
	[Enum.Material.Marble] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Basalt] = "Concrete",
	[Enum.Material.Sandstone] = "Ground",

	[Enum.Material.Grass] = "Grass",
	[Enum.Material.LeafyGrass] = "LeafyGrass",

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

	[Enum.Material.Water] = "Water",
}

local character: Model?
local humanoid: Humanoid?
local rootPart: BasePart?
local animator: Animator?

local leftFoot: BasePart?
local rightFoot: BasePart?

local lastStepT = 0
local lastLandT = 0

local lastGroundMaterial: Enum.Material = Enum.Material.Concrete

local markerConns = {}
local stoppedConns = {}
local diedConn: RBXScriptConnection? = nil
local rsConn: RBXScriptConnection? = nil
local stateConn: RBXScriptConnection? = nil

local hookedTracks = setmetatable({}, { __mode = "k" })

-- ============================================================
-- CREATURE GUARD
-- ============================================================
-- The creature has its own footstep system (CreatureFootsteps), with its own
-- sound set and its own surface handling. Both scripts hook the SAME "Footstep"
-- animation marker, so without this guard every creature step fires twice --
-- once from here with the SPH sounds, once from CreatureFootsteps with the
-- creature ones.
--
-- The attribute is set by CreatureService BEFORE the rig is parented, so it is
-- already readable the moment CharacterAdded fires.
local function isCreatureCharacter(char: Instance?): boolean
	return char ~= nil and char:GetAttribute("IsCreature") == true
end

-- ============================================================
-- NO-REPEAT SHUFFLE-BAG per folder key
-- ============================================================
local pickState: {[string]: {bag: {string}, last: string?}} = {}

local function shuffleInPlace(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
end

local function getSoundNames(folder: Folder): {string}
	local names = {}
	for _, inst in ipairs(folder:GetChildren()) do
		if inst:IsA("Sound") then
			table.insert(names, inst.Name)
		end
	end
	return names
end

local function nextSoundNameNoRepeat(key: string, folder: Folder): string?
	local names = getSoundNames(folder)
	if #names == 0 then
		return nil
	end
	if #names == 1 then
		return names[1]
	end

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
			if n ~= st.last then
				chosen = n
				break
			end
		end
	end

	st.last = chosen
	return chosen
end

local function cleanup()
	for _, c in ipairs(markerConns) do
		c:Disconnect()
	end
	table.clear(markerConns)

	for _, c in ipairs(stoppedConns) do
		c:Disconnect()
	end
	table.clear(stoppedConns)

	table.clear(hookedTracks)

	if diedConn then
		diedConn:Disconnect()
		diedConn = nil
	end
	if rsConn then
		rsConn:Disconnect()
		rsConn = nil
	end
	if stateConn then
		stateConn:Disconnect()
		stateConn = nil
	end
end

-- ============================================================
-- HELPERS ? stance / state checks using SPH attributes
-- ============================================================
local function getHorizontalSpeed(): number
	if not rootPart then
		return 0
	end
	local v = rootPart.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

local function isProneTransitioning(): boolean
	if not character then
		return false
	end
	local proneT = character:GetAttribute("ProneTransitioning")
	if proneT == true then
		return true
	end
	local charMovement = character:FindFirstChild("CharacterMovement")
	if charMovement then
		local scriptRef = charMovement:FindFirstChild("CharacterMovement")
		if scriptRef and scriptRef:GetAttribute("ProneTransitioning") == true then
			return true
		end
	end
	return false
end

local function getStance(): string
	if not character then
		return "Standing"
	end
	return character:GetAttribute("Stance") or "Standing"
end

local function isCrouching(): boolean
	return getStance() == "Crouched"
end

local function isProne(): boolean
	return getStance() == "Prone"
end

local function isCrouchingOrProne(): boolean
	local s = getStance()
	return s == "Crouched" or s == "Prone"
end

local function isSwimming(): boolean
	if not humanoid then
		return false
	end
	return humanoid:GetState() == Enum.HumanoidStateType.Swimming
end

local function isClimbing(): boolean
	if not humanoid then
		return false
	end
	return humanoid:GetState() == Enum.HumanoidStateType.Climbing
end

local function hasExoskeleton(): boolean
	if not character then
		return false
	end
	return character:GetAttribute(EXO_ATTRIBUTE) == true
end

local function isSprinting(): boolean
	if not character then
		return false
	end
	return character:GetAttribute("Sprinting") == true
end

local function currentMode(): "Walking" | "Running"
	if isSprinting() then
		return "Running"
	end
	return (getHorizontalSpeed() >= RUN_SPEED_THRESHOLD) and "Running" or "Walking"
end

local function materialToFolderName(mat: Enum.Material): string
	return MATERIAL_TO_FOLDER[mat] or "Concrete"
end

local function killDefaultRunningSound()
	if not rootPart then
		return
	end
	local s = rootPart:FindFirstChild("Running")
	if s and s:IsA("Sound") then
		s:Destroy()
	end
end

-- ============================================================
-- SOUND PLAYBACK FUNCTIONS
-- ============================================================
local function resolveMatFolder(kindFolder: Folder, matName: string): Folder?
	local matFolder = kindFolder:FindFirstChild(matName)
	if not (matFolder and matFolder:IsA("Folder")) then
		matFolder = kindFolder:FindFirstChild("Concrete")
	end
	if matFolder and matFolder:IsA("Folder") then
		return matFolder
	end
	return nil
end

local function playSurfaceSfxOnRoot(
	kind: "Walking" | "Running" | "Jumping" | "Landing",
	root: BasePart,
	matName: string,
	volumeMultiplier: number?,
	playbackSpeed: number,
	soundName: string?
): string?
	local kindFolder = soundsRoot:FindFirstChild(kind)
	if not (kindFolder and kindFolder:IsA("Folder")) then
		return nil
	end

	local matFolder = resolveMatFolder(kindFolder, matName)
	if not matFolder then
		return nil
	end

	local template: Sound? = nil

	if soundName and #soundName > 0 then
		local inst = matFolder:FindFirstChild(soundName)
		if inst and inst:IsA("Sound") then
			template = inst
		else
			soundName = nil
		end
	end

	if not template then
		local key = kind .. "|" .. matFolder:GetFullName()
		local chosenName = nextSoundNameNoRepeat(key, matFolder)
		if not chosenName then
			return nil
		end
		local inst = matFolder:FindFirstChild(chosenName)
		if not (inst and inst:IsA("Sound")) then
			return nil
		end
		template = inst
		soundName = chosenName
	end

	local s = template:Clone()
	if typeof(volumeMultiplier) == "number" then
		s.Volume = template.Volume * volumeMultiplier
	end
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return soundName
end

local function playGenericSfxOnRoot(
	folderName: string,
	root: BasePart,
	volumeMultiplier: number?,
	playbackSpeed: number,
	soundName: string?
): string?
	local folder = soundsRoot:FindFirstChild(folderName)
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local template: Sound? = nil

	if soundName and #soundName > 0 then
		local inst = folder:FindFirstChild(soundName)
		if inst and inst:IsA("Sound") then
			template = inst
		else
			soundName = nil
		end
	end

	if not template then
		local key = folderName .. "|" .. folder:GetFullName()
		local chosenName = nextSoundNameNoRepeat(key, folder)
		if not chosenName then
			return nil
		end
		local inst = folder:FindFirstChild(chosenName)
		if not (inst and inst:IsA("Sound")) then
			return nil
		end
		template = inst
		soundName = chosenName
	end

	local s = template:Clone()
	if typeof(volumeMultiplier) == "number" then
		s.Volume = template.Volume * volumeMultiplier
	end
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return soundName
end

local function playOneShotSingle(
	folderName: string,
	root: BasePart,
	volumeMultiplier: number?,
	playbackSpeed: number,
	preferredSoundName: string?
): string?
	local folder = soundsRoot:FindFirstChild(folderName)
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local template: Sound? = nil

	if preferredSoundName and #preferredSoundName > 0 then
		local byName = folder:FindFirstChild(preferredSoundName)
		if byName and byName:IsA("Sound") then
			template = byName
		end
	end

	if not template then
		local key = folderName .. "|" .. folder:GetFullName()
		local chosenName = nextSoundNameNoRepeat(key, folder)
		if not chosenName then
			return nil
		end

		local inst = folder:FindFirstChild(chosenName)
		if not (inst and inst:IsA("Sound")) then
			return nil
		end
		template = inst
	end

	local s = template:Clone()
	if typeof(volumeMultiplier) == "number" then
		s.Volume = template.Volume * volumeMultiplier
	end
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return template.Name
end

local function playRustleLayerOnRoot(root: BasePart, playbackSpeed: number, volumeMultiplier: number, mode: ("Walking" | "Running")?): string?
	local folderName = (mode == "Running") and RUSTLE_FOLDER_RUN or RUSTLE_FOLDER_WALK
	local folder = soundsRoot:FindFirstChild(folderName)
	-- Fall back to the walking rustle folder if the sprint-specific one is missing
	if not (folder and folder:IsA("Folder")) then
		folder = soundsRoot:FindFirstChild(RUSTLE_FOLDER_WALK)
	end
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local key = "Rustle|" .. folder:GetFullName()
	local chosenName = nextSoundNameNoRepeat(key, folder)
	if not chosenName then
		return nil
	end

	local template = folder:FindFirstChild(chosenName)
	if not (template and template:IsA("Sound")) then
		return nil
	end

	local s = template:Clone()
	s.Volume = template.Volume * volumeMultiplier
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return template.Name
end

local function playSprintFoleyLayerOnRoot(root: BasePart, playbackSpeed: number, soundName: string?): string?
	local folder = soundsRoot:FindFirstChild("SprintFoley")
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local template: Sound? = nil

	if soundName and #soundName > 0 then
		local inst = folder:FindFirstChild(soundName)
		if inst and inst:IsA("Sound") then
			template = inst
		else
			soundName = nil
		end
	end

	if not template then
		local key = "SprintFoley|" .. folder:GetFullName()
		local chosenName = nextSoundNameNoRepeat(key, folder)
		if not chosenName then
			return nil
		end

		local inst = folder:FindFirstChild(chosenName)
		if not (inst and inst:IsA("Sound")) then
			return nil
		end
		template = inst
		soundName = chosenName
	end

	local s = template:Clone()
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return soundName
end

local function playWalkFoleyLayerOnRoot(root: BasePart, playbackSpeed: number, soundName: string?): string?
	local folder = soundsRoot:FindFirstChild("WalkFoley")
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local template: Sound? = nil

	if soundName and #soundName > 0 then
		local inst = folder:FindFirstChild(soundName)
		if inst and inst:IsA("Sound") then
			template = inst
		else
			soundName = nil
		end
	end

	if not template then
		local key = "WalkFoley|" .. folder:GetFullName()
		local chosenName = nextSoundNameNoRepeat(key, folder)
		if not chosenName then
			return nil
		end

		local inst = folder:FindFirstChild(chosenName)
		if not (inst and inst:IsA("Sound")) then
			return nil
		end
		template = inst
		soundName = chosenName
	end

	local s = template:Clone()
	s.PlaybackSpeed = playbackSpeed
	s.Parent = root
	s.Ended:Connect(function()
		s:Destroy()
	end)
	s:Play()

	return soundName
end

--[[
	Which servo folder a step uses, with the sprint set falling back to the walk set.

	Resolved from the MODE rather than sent over the wire as a folder name, so the
	listener picks the folder the same way the walker did. It has the identical
	Assets tree -- it replicated from the same place -- so both ends reach the same
	answer, and nothing that arrives over a remote gets to name a folder.

	The fallback checks for an actual Sound, not just the Folder. An empty
	ExoFootstepsSprint is what you have in Studio the moment you create it, and
	"sprinting is silent until you fill this in" is a worse default than "sprinting
	reuses the walk servos".
--]]
local function resolveExoFolderName(mode: ("Walking" | "Running")?): string
	if mode ~= "Running" then
		return EXO_FOLDER
	end
	local sprintFolder = soundsRoot:FindFirstChild(EXO_FOLDER_SPRINT)
	if sprintFolder and sprintFolder:IsA("Folder") then
		for _, inst in ipairs(sprintFolder:GetChildren()) do
			if inst:IsA("Sound") then
				return EXO_FOLDER_SPRINT
			end
		end
	end
	return EXO_FOLDER
end

local function getAnimationNameFromTrack(track: AnimationTrack): string
	if track.Animation and track.Animation.Name and #track.Animation.Name > 0 then
		return track.Animation.Name
	end
	return track.Name or ""
end

local function isLandingAnimPlaying(): boolean
	if not animator then
		return false
	end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track.IsPlaying then
			local animName = string.lower(getAnimationNameFromTrack(track))
			if string.find(animName, "landing") or animName == "land" then
				return true
			end
		end
	end

	return false
end

local function getFootParts(char: Model): (BasePart?, BasePart?)
	local lf = char:FindFirstChild("LeftFoot")
	local rf = char:FindFirstChild("RightFoot")

	if lf and lf:IsA("BasePart") and rf and rf:IsA("BasePart") then
		return lf, rf
	end

	local ll = char:FindFirstChild("LeftLowerLeg")
	local rl = char:FindFirstChild("RightLowerLeg")

	return (ll and ll:IsA("BasePart")) and ll or nil, (rl and rl:IsA("BasePart")) and rl or nil
end

-- ============================================================
-- WATER DETECTION
-- ============================================================
local function makeWaterRayParams(): RaycastParams?
	if not character then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = false
	return params
end

local function pointHitsWater(origin: Vector3): boolean
	local params = makeWaterRayParams()
	if not params then
		return false
	end

	local result = Workspace:Raycast(
		origin + Vector3.new(0, WATER_CHECK_UP_OFFSET, 0),
		Vector3.new(0, -WATER_CHECK_DOWN_DISTANCE, 0),
		params
	)

	return result ~= nil and result.Material == Enum.Material.Water
end

local function isTouchingWater(): boolean
	if rootPart and pointHitsWater(rootPart.Position) then
		return true
	end
	if leftFoot and pointHitsWater(leftFoot.Position) then
		return true
	end
	if rightFoot and pointHitsWater(rightFoot.Position) then
		return true
	end
	return false
end

local function updateWaterContact()
	if isTouchingWater() then
		lastWaterContactT = os.clock()
	end
end

local function recentlyTouchedWater(): boolean
	return (os.clock() - lastWaterContactT) <= WATER_CONTACT_GRACE_TIME
end

local function shouldUseWaterMaterial(): boolean
	return isTouchingWater() or recentlyTouchedWater()
end

local function getMaterialFolder(useWaterGrace: boolean?): string
	if shouldUseWaterMaterial() or (useWaterGrace and recentlyTouchedWater()) then
		return "Water"
	end

	if not humanoid then
		return "Concrete"
	end

	return materialToFolderName(humanoid.FloorMaterial)
end

-- ============================================================
-- FOLIAGE DETECTION
-- ============================================================
local function isInsideFoliage(): boolean
	if not rootPart then
		return false
	end

	local rootPos = rootPart.Position

	for _, inst in ipairs(CollectionService:GetTagged(FOLIAGE_TAG)) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(Workspace) then
			local relative = inst.CFrame:PointToObjectSpace(rootPos)

			local customRadius = inst:GetAttribute("RustleRadius")
			local customHeightUp = inst:GetAttribute("RustleHeightUp")
			local customHeightDown = inst:GetAttribute("RustleHeightDown")

			local radius = typeof(customRadius) == "number" and customRadius or DEFAULT_RUSTLE_RADIUS
			local heightUp = typeof(customHeightUp) == "number" and customHeightUp or DEFAULT_RUSTLE_HEIGHT_UP
			local heightDown = typeof(customHeightDown) == "number" and customHeightDown or DEFAULT_RUSTLE_HEIGHT_DOWN

			if math.abs(relative.X) <= radius
				and math.abs(relative.Z) <= radius
				and relative.Y >= -heightDown
				and relative.Y <= heightUp then
				return true
			end
		end
	end

	return false
end

local function playFoliageLayer(mode: "Walking" | "Running")
	if not humanoid or not rootPart then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isClimbing() then
		return
	end
	if not isInsideFoliage() then
		return
	end

	local speed = math.random(math.floor(FOLIAGE_PITCH_MIN * 100), math.floor(FOLIAGE_PITCH_MAX * 100)) / 100
	local volumeMultiplier = (mode == "Running") and FOLIAGE_RUN_VOLUME_MULTIPLIER or FOLIAGE_WALK_VOLUME_MULTIPLIER
	local chosenName = playRustleLayerOnRoot(rootPart, speed, volumeMultiplier, mode)
	if chosenName then
		repFootstep:Fire({
			kind = "Foliage",
			mode = mode,
			speed = speed,
			volumeMultiplier = volumeMultiplier,
			soundName = chosenName,
		})
	end
end

-- ============================================================
-- OTHER PLAYERS SFX (via BridgeNet)
-- ============================================================
repFootstep:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end

	local char = data.character
	if typeof(char) ~= "Instance" or not char:IsA("Model") then
		return
	end
	if player.Character == char then
		return
	end

	-- Somebody else's creature. Their own CreatureFootsteps already plays on
	-- every client, so handling their steps here too would double them for
	-- everyone watching.
	if isCreatureCharacter(char) then
		return
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart") and hum) then
		return
	end

	local kind = data.kind

	-- Jump sounds removed
	if kind == "Jumping" then
		return
	end

	if kind == "Crouch" then
		local stance = char:GetAttribute("Stance")
		if stance ~= "Crouched" and stance ~= "Prone" then
			return
		end
		playGenericSfxOnRoot("Crouch", root, data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	-- Prone: single layer with material-specific sounds
	if kind == "Prone" then
		local stance = char:GetAttribute("Stance")
		if stance ~= "Prone" then
			return
		end
		playSurfaceSfxOnRoot("ProneFootsteps", root, data.matName or "Concrete", data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	if kind == "Swim" then
		if hum:GetState() ~= Enum.HumanoidStateType.Swimming then
			return
		end
		playGenericSfxOnRoot("Swimming", root, data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	if kind == "SwimEnter" then
		playOneShotSingle("SwimEnter", root, data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	if kind == "SwimExit" then
		playOneShotSingle("SwimExit", root, data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	if kind == "SprintFoley" then
		if char:GetAttribute("Sprinting") ~= true then
			return
		end
		playSprintFoleyLayerOnRoot(root, data.speed or 1, data.soundName)
		return
	end

	if kind == "WalkFoley" then
		local stance = char:GetAttribute("Stance")
		if stance == "Crouched" or stance == "Prone" then
			return
		end
		if char:GetAttribute("Sprinting") == true then
			return
		end
		playWalkFoleyLayerOnRoot(root, data.speed or 1, data.soundName)
		return
	end

	--[[
		The servo layer on somebody else.

		Re-checked against THEIR character's own attribute rather than trusted from
		the packet, the same way Crouch, Prone and SprintFoley are. The attribute is
		server-set, so this is the authoritative copy: a client that lies about
		wearing a frame gets no sound out of anyone else's game.
	--]]
	if kind == "Exo" then
		if char:GetAttribute(EXO_ATTRIBUTE) ~= true then
			return
		end
		playGenericSfxOnRoot(resolveExoFolderName(data.mode), root, data.volumeMultiplier, data.speed or 1, data.soundName)
		return
	end

	if kind == "Foliage" then
		playRustleLayerOnRoot(root, data.speed or 1, data.volumeMultiplier or 0.6, data.mode)
		return
	end

	-- Surface footstep (Walking/Running/Jumping/Landing)
	local stance = char:GetAttribute("Stance")
	if stance == "Crouched" or stance == "Prone" then
		return
	end
	if hum:GetState() == Enum.HumanoidStateType.Swimming then
		return
	end
	if hum:GetState() == Enum.HumanoidStateType.Climbing then
		return
	end

	playSurfaceSfxOnRoot(kind :: any, root, data.matName, data.volumeMultiplier, data.speed or 1, data.soundName)
end)

-- ============================================================
-- LOCAL PLAYER SFX
-- ============================================================
local function playSurfaceSfx(
	kind: "Walking" | "Running" | "Jumping" | "Landing",
	materialFolderName: string?,
	volumeMultiplier: number?
)
	if not humanoid or not rootPart then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end

	local matName = materialFolderName or getMaterialFolder(false)
	local speed = math.random(math.floor(PITCH_MIN * 100), math.floor(PITCH_MAX * 100)) / 100

	local chosenSoundName = playSurfaceSfxOnRoot(kind, rootPart, matName, volumeMultiplier, speed, nil)
	if not chosenSoundName then
		return
	end
	repFootstep:Fire({
		kind = kind,
		matName = matName,
		volumeMultiplier = volumeMultiplier,
		speed = speed,
		soundName = chosenSoundName,
	})
end

--[[
	The exoskeleton servo layer, played over a step that has already happened.

	Called from the step functions AFTER their own surface sound, rather than from
	the animation marker directly, so it can never fire on a step that was itself
	suppressed -- landing animations, prone transitions, climbing and swimming all
	bail out before reaching here, and a servo whine with no footstep under it would
	give away a player who did not actually take one.

	Volume is the only thing STANCE changes. The frame is the same machine crouched
	as it is standing; it is just not working as hard. Sprinting is the one case
	that gets its own sounds, because a servo under load is a different noise
	rather than a louder one.

	Crouched and prone always use the walk set, whatever the mode argument says --
	there is no such thing as a sprinting crouch, and the caller passing "Running"
	by accident should not be able to produce one.
--]]
local function playExoLayer(mode: ("Walking" | "Running")?)
	if not rootPart then
		return
	end
	if not hasExoskeleton() then
		return
	end

	local crouched = isCrouchingOrProne()
	local sprinting = (mode == "Running") and not crouched

	local pitchMin = sprinting and EXO_SPRINT_PITCH_MIN or EXO_PITCH_MIN
	local pitchMax = sprinting and EXO_SPRINT_PITCH_MAX or EXO_PITCH_MAX
	local speed = math.random(math.floor(pitchMin * 100), math.floor(pitchMax * 100)) / 100

	local volumeMultiplier
	if crouched then
		volumeMultiplier = EXO_CROUCH_VOLUME_MULTIPLIER
	elseif sprinting then
		volumeMultiplier = EXO_SPRINT_VOLUME_MULTIPLIER
	else
		volumeMultiplier = EXO_VOLUME_MULTIPLIER
	end

	local resolvedMode = sprinting and "Running" or "Walking"
	local chosen = playGenericSfxOnRoot(resolveExoFolderName(resolvedMode), rootPart, volumeMultiplier, speed, nil)
	if not chosen then
		return
	end

	repFootstep:Fire({
		kind = "Exo",
		mode = resolvedMode,
		volumeMultiplier = volumeMultiplier,
		speed = speed,
		soundName = chosen,
	})
end

-- Plays crouch footstep (surface sound at reduced volume + crouch foley layer)
-- OR prone footstep (single layer from ProneFootsteps material folders)
local function playCrouchOrProneStep()
	if not humanoid or not rootPart then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air and not shouldUseWaterMaterial() then
		return
	end
	if humanoid.MoveDirection.Magnitude < MIN_MOVE_DIR then
		return
	end
	if isProneTransitioning() then
		return
	end
	if not isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end
	if isLandingAnimPlaying() then
		return
	end

	local now = os.clock()
	if now - lastStepT < MIN_TIME_BETWEEN_STEPS then
		return
	end
	lastStepT = now

	if isProne() then
		-- Single layer: material-specific prone sounds from ProneFootsteps folder
		local proneMatName = PRONE_MATERIAL_TO_FOLDER[humanoid.FloorMaterial] or "Concrete"
		if shouldUseWaterMaterial() then
			proneMatName = "Concrete"  -- no water-specific prone sound, fall back
		end
		local pronePitch = math.random(math.floor(PRONE_PITCH_MIN * 100), math.floor(PRONE_PITCH_MAX * 100)) / 100
		local proneName = playSurfaceSfxOnRoot("ProneFootsteps", rootPart, proneMatName, PRONE_VOLUME_MULTIPLIER, pronePitch, nil)

		if proneName then
			repFootstep:Fire({
				kind = "Prone",
				matName = proneMatName,
				volumeMultiplier = PRONE_VOLUME_MULTIPLIER,
				speed = pronePitch,
				soundName = proneName,
			})
		end
	else
		-- Crouch: surface layer + crouch foley (unchanged)
		local matName = getMaterialFolder(false)
		local footPitch = math.random(math.floor(PITCH_MIN * 100), math.floor(PITCH_MAX * 100)) / 100
		local footName = playSurfaceSfxOnRoot("Walking", rootPart, matName, CROUCH_SURFACE_VOLUME_MULTIPLIER, footPitch, nil)

		if footName then
			repFootstep:Fire({
				kind = "Walking",
				matName = matName,
				volumeMultiplier = CROUCH_SURFACE_VOLUME_MULTIPLIER,
				speed = footPitch,
				soundName = footName,
			})
		end

		local genericVolMult = CROUCH_GENERIC_VOLUME_MULTIPLIER
		local crouchPitch = math.random(math.floor(CROUCH_PITCH_MIN * 100), math.floor(CROUCH_PITCH_MAX * 100)) / 100
		local crouchName = playGenericSfxOnRoot("Crouch", rootPart, genericVolMult, crouchPitch, nil)

		if crouchName then
			repFootstep:Fire({
				kind = "Crouch",
				volumeMultiplier = genericVolMult,
				speed = crouchPitch,
				soundName = crouchName,
			})
		end
	end

	-- No mode: crouched and prone are always the walk servo set.
	playExoLayer("Walking")
	playFoliageLayer("Walking")
end

local function playSwimStep()
	if not humanoid or not rootPart then
		return
	end
	if humanoid.MoveDirection.Magnitude < MIN_MOVE_DIR then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if not isSwimming() then
		return
	end
	if isLandingAnimPlaying() then
		return
	end

	local now = os.clock()
	if now - lastStepT < MIN_TIME_BETWEEN_STEPS then
		return
	end
	lastStepT = now

	local speed = math.random(math.floor(SWIM_PITCH_MIN * 100), math.floor(SWIM_PITCH_MAX * 100)) / 100
	local chosen = playGenericSfxOnRoot("Swimming", rootPart, nil, speed, nil)
	if not chosen then
		return
	end
	repFootstep:Fire({
		kind = "Swim",
		speed = speed,
		soundName = chosen,
	})
end

local function playSwimEnter()
	if not humanoid or not rootPart then
		return
	end
	if isProneTransitioning() then
		return
	end

	local now = os.clock()
	if now - lastSwimTransitionT < MIN_TIME_BETWEEN_SWIM_TRANSITIONS then
		return
	end
	lastSwimTransitionT = now

	local speed = 1.0
	local chosenName = playOneShotSingle("SwimEnter", rootPart, nil, speed, "Enter")
	if not chosenName then
		chosenName = playOneShotSingle("SwimEnter", rootPart, nil, speed, nil)
	end
	if not chosenName then
		return
	end

	repFootstep:Fire({
		kind = "SwimEnter",
		speed = speed,
		soundName = chosenName,
	})
end

local function playSwimExit()
	if not humanoid or not rootPart then
		return
	end
	if isProneTransitioning() then
		return
	end

	local now = os.clock()
	if now - lastSwimTransitionT < MIN_TIME_BETWEEN_SWIM_TRANSITIONS then
		return
	end
	lastSwimTransitionT = now

	local speed = 1.0
	local chosenName = playOneShotSingle("SwimExit", rootPart, nil, speed, "Exit")
	if not chosenName then
		chosenName = playOneShotSingle("SwimExit", rootPart, nil, speed, nil)
	end
	if not chosenName then
		return
	end

	repFootstep:Fire({
		kind = "SwimExit",
		speed = speed,
		soundName = chosenName,
	})
end

local function playSprintFoley()
	if not humanoid or not rootPart then
		return
	end
	if not isSprinting() then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end
	if isLandingAnimPlaying() then
		return
	end

	local speed1 = math.random(math.floor(PITCH_MIN * 100), math.floor(PITCH_MAX * 100)) / 100
	local chosen1 = playSprintFoleyLayerOnRoot(rootPart, speed1, nil)
	if chosen1 then
		repFootstep:Fire({
			kind = "SprintFoley",
			speed = speed1,
			soundName = chosen1,
		})
	end
end

local function playWalkFoley()
	if not humanoid or not rootPart then
		return
	end
	if isSprinting() then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end
	if isLandingAnimPlaying() then
		return
	end

	local speed = math.random(math.floor(PITCH_MIN * 100), math.floor(PITCH_MAX * 100)) / 100
	local chosen = playWalkFoleyLayerOnRoot(rootPart, speed, nil)
	if chosen then
		repFootstep:Fire({
			kind = "WalkFoley",
			speed = speed,
			soundName = chosen,
		})
	end
end

local function playFootstep(mode: "Walking" | "Running")
	if not humanoid or not rootPart then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air and not shouldUseWaterMaterial() then
		return
	end
	if humanoid.MoveDirection.Magnitude < MIN_MOVE_DIR then
		return
	end
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end
	if isLandingAnimPlaying() then
		return
	end

	local now = os.clock()
	if now - lastStepT < MIN_TIME_BETWEEN_STEPS then
		return
	end
	lastStepT = now

	playSurfaceSfx(mode, nil, nil)
	if mode == "Running" and isSprinting() then
		playSprintFoley()
	else
		playWalkFoley()
	end
	-- The servo layer follows the same test the foley layer above does, so the two
	-- always agree about whether this was a sprint. Running fast without the sprint
	-- attribute (downhill, say) is a walk as far as both of them are concerned.
	playExoLayer((mode == "Running" and isSprinting()) and "Running" or "Walking")
	playFoliageLayer(mode)
end

local function playLand()
	if not humanoid then
		return
	end
	local now = os.clock()
	if now - lastLandT < MIN_TIME_BETWEEN_LANDS then
		return
	end
	lastLandT = now
	if isProneTransitioning() then
		return
	end
	if isCrouchingOrProne() then
		return
	end
	if isSwimming() then
		return
	end
	if isClimbing() then
		return
	end
	if humanoid.FloorMaterial == Enum.Material.Air and not recentlyTouchedWater() then
		return
	end

	playSurfaceSfx("Landing", getMaterialFolder(true), nil)
end

-- ============================================================
-- MARKER ROUTING
-- ============================================================
local function shouldAcceptMarkerFrom(animName: string): ("Walking" | "Running" | nil)
	if isProneTransitioning() then return nil end
	if isCrouchingOrProne() then return nil end
	if isSwimming() then return nil end
	if isClimbing() then return nil end
	if isLandingAnimPlaying() then return nil end

	local name = string.lower(animName)
	local modeNow = currentMode()

	if string.find(name, "walk") then
		return (modeNow == "Walking") and "Walking" or nil
	end

	if string.find(name, "sprint") then
		return (modeNow == "Running") and "Running" or nil
	end

	if string.find(name, "jog") or string.find(name, "run") then
		return (modeNow == "Running") and "Running" or nil
	end

	return nil
end

local function hookTrack(track: AnimationTrack)
	if hookedTracks[track] then
		return
	end
	hookedTracks[track] = true

	local conn = track:GetMarkerReachedSignal(MARKER_NAME):Connect(function()
		if not humanoid then
			return
		end

		local animName = getAnimationNameFromTrack(track)
		local name = string.lower(animName)

		if isCrouchingOrProne() then
			if string.find(name, "crouch") or string.find(name, "prone") then
				playCrouchOrProneStep()
			end
			return
		end

		if isSwimming() then
			if string.find(name, "swim") then
				playSwimStep()
			end
			return
		end

		local modeToPlay = shouldAcceptMarkerFrom(animName)
		if not modeToPlay then
			return
		end
		playFootstep(modeToPlay)
	end)

	table.insert(markerConns, conn)

	local stopConn = track.Stopped:Connect(function()
		hookedTracks[track] = nil
	end)

	table.insert(stoppedConns, stopConn)
end

local function scanAndHookPlayingTracks()
	if not animator then
		return
	end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		hookTrack(track)
	end
end

-- ============================================================
-- CHARACTER BINDING
-- ============================================================
local function bindCharacter(char: Model)
	cleanup()

	-- Morphed into a creature: stay unbound entirely. Nulling the state as
	-- well as returning matters -- cleanup() drops the connections, but a
	-- stale `character` left pointing at the creature would let anything that
	-- reads it later act on the wrong rig.
	if isCreatureCharacter(char) then
		character, humanoid, rootPart, animator = nil, nil, nil, nil
		leftFoot, rightFoot = nil, nil
		return
	end

	character = char
	humanoid = char:WaitForChild("Humanoid")
	rootPart = char:WaitForChild("HumanoidRootPart")
	animator = humanoid:WaitForChild("Animator")

	leftFoot, rightFoot = getFootParts(char)
	updateWaterContact()

	task.defer(killDefaultRunningSound)

	diedConn = humanoid.Died:Connect(function()
		cleanup()
	end)

	local function updateGroundMaterial()
		if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air and humanoid.FloorMaterial ~= Enum.Material.Water then
			lastGroundMaterial = humanoid.FloorMaterial
		end
	end
	updateGroundMaterial()

	local wasSwimming = false

	stateConn = humanoid.StateChanged:Connect(function(_, newState)
		updateGroundMaterial()
		updateWaterContact()

		local nowSwimming = (newState == Enum.HumanoidStateType.Swimming)

		if nowSwimming and not wasSwimming then
			playSwimEnter()
		end

		if (not nowSwimming) and wasSwimming then
			playSwimExit()
		end

		wasSwimming = nowSwimming

		if newState == Enum.HumanoidStateType.Landed then
			playLand()
		end
	end)

	scanAndHookPlayingTracks()

	local t = 0
	rsConn = RunService.RenderStepped:Connect(function(dt)
		if character ~= char then
			return
		end
		t += dt

		updateGroundMaterial()
		updateWaterContact()

		if t >= 0.15 then
			t = 0

			if character then
				leftFoot, rightFoot = getFootParts(character)
			end

			scanAndHookPlayingTracks()
		end
	end)
end

player.CharacterAdded:Connect(bindCharacter)
if player.Character then
	bindCharacter(player.Character)
end  