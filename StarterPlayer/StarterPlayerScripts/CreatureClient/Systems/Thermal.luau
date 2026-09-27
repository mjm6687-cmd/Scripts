-- Thermal  (ModuleScript, under CreatureClient > Systems)
--
-- Red outlines on anything with a Humanoid. Always on while you're the creature.
--
-- ============================================================
-- WHY THE LAST VERSION DIDN'T DRAW
-- ============================================================
-- Two separate problems, both fixed here.
--
-- 1. IT COULDN'T SEE YOUR RIG.
--    It scanned `workspace:GetChildren()` ? TOP LEVEL ONLY. A rig inside a Folder
--    or a Map model was invisible to it, which is most rigs in most places.
--
-- 2. THE POOL DIDN'T RENDER.
--    It pre-built N Highlights with `Adornee = nil, Enabled = false` and re-pointed
--    them at targets later. Your ECOTI does the opposite ? it creates a Highlight
--    with its Adornee already set and destroys it when the target leaves ? and
--    that's the version that demonstrably works in your game, so this is now built
--    the same way. Pooling was an optimisation for a cost that was never the
--    problem; a couple of dozen Instance.new calls every few seconds is nothing.
--
-- Structure, naming and fade behaviour below are lifted from your ECOTI block in
-- NightVision.luau on purpose, so the two behave identically and a fix to one is
-- obvious in the other.
--
-- ============================================================
-- THE ~31 HIGHLIGHT CAP
-- ============================================================
-- Roblox renders about 31 Highlights at once and silently drops the rest ? no
-- error, no say in which ones vanish. So targets are ranked NEAREST FIRST and cut
-- off at thermalMaxTargets, same as ECOTI.

local Players = game:GetService("Players")

local System = {
	name = "Thermal",
	key = "thermal",
	scope = "local",
}

local DEFAULTS = {
	thermalRange = 750,
	thermalMaxTargets = 24,      -- HARD CAP, must stay under ~31
	thermalRefresh = 0.25,       -- seconds between rescans

	-- true  = glows through geometry (wallhack thermal)
	-- false = walls block it, like your ECOTI
	thermalThroughWalls = true,

	thermalOutlineColor = Color3.fromRGB(255, 62, 46),
	thermalOutlineTransparency = 0,
	thermalFillColor = Color3.fromRGB(255, 62, 46),
	thermalFillTransparency = 1, -- 1 = outline only

	-- Nothing pops in or out.
	thermalFadeTime = 0.35,      -- seconds to fade fully in / out
	thermalFadeDistance = 120,   -- studs of dimming at the edge of range (0 = off)

	thermalIncludeSelf = false,
	thermalIncludeDead = false,
	thermalIncludeCreatures = false,

	-- Prints what it registered and what it outlined, once a second. Turn this on
	-- if a rig still isn't lighting up ? the numbers say which half is wrong.
	thermalDebug = false,
}

local FOLDER_NAME = "CreatureThermal"

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local CreatureUtil

local cfg = table.clone(DEFAULTS)
local active = false

local folder: Folder?
-- model -> { hl, alpha (what's on screen now), want (what it's heading toward) }
local pool: { [Instance]: any } = {}
local nextScan = 0
local nextDebug = 0

-- [Humanoid] = its Model. Maintained incrementally ? never rebuilt by scanning.
local registry: { [Humanoid]: Model } = {}

-- ============================================================
-- REGISTRY
-- ============================================================
-- This is the one thing NOT taken from ECOTI. ECOTI scans Players plus the direct
-- children of a hardcoded list of folder names ("NPCs", "Enemies", "Bots"), which
-- works because you know where that game puts its NPCs. Your creature's victims
-- are R6 dummies sitting wherever you dropped them, so the name list would need
-- updating every time you build a new room.
--
-- Walking every descendant on a timer instead would be tens of thousands of
-- instances, four times a second, forever. So: one deep scan at startup, then
-- DescendantAdded/Removing keep it current. Depth stops mattering, and a rescan
-- costs "iterate the handful of Humanoids that exist".
local function registerHumanoid(inst: Instance)
	if not inst:IsA("Humanoid") then
		return
	end
	local model = inst.Parent
	if model and model:IsA("Model") then
		registry[inst] = model
	end
end

local function unregisterHumanoid(inst: Instance)
	if inst:IsA("Humanoid") then
		registry[inst] = nil
	end
end

local function startRegistry()
	for _, d in ipairs(workspace:GetDescendants()) do
		registerHumanoid(d)
	end
	workspace.DescendantAdded:Connect(registerHumanoid)
	workspace.DescendantRemoving:Connect(unregisterHumanoid)
end

-- ============================================================
-- FOLDER
-- ============================================================
-- A Highlight only renders while it's a descendant of Workspace or PlayerGui.
-- PlayerGui, so nothing is ever parented into a model the server owns.
local function ensureFolder()
	if folder and folder:IsDescendantOf(playerGui) then
		return
	end
	local stale = playerGui:FindFirstChild(FOLDER_NAME)
	if stale then
		stale:Destroy()
	end
	table.clear(pool)
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = playerGui
end

-- ============================================================
-- SCAN
-- ============================================================
local ranked = {}

local function scan()
	ensureFolder()

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	-- Measured from the CAMERA, not the character: at 750 studs the difference is
	-- invisible, but it means the outlines still behave sensibly while the camera
	-- is detached from the body (death, a cutscene, spectating).
	local cam = workspace.CurrentCamera
	local eye = cam and cam.CFrame.Position or (root and root.Position)
	if not eye then
		return
	end

	table.clear(ranked)
	local range = cfg.thermalRange

	for hum, model in pairs(registry) do
		if hum.Parent ~= model then
			-- Reparented since we saw it; drop the stale row rather than trust it.
			registry[hum] = nil
		elseif model.Parent then
			local skip = false

			if model == char and not cfg.thermalIncludeSelf then
				skip = true
			elseif not cfg.thermalIncludeDead and (hum.Health <= 0 or model:GetAttribute("IsCorpse") == true) then
				-- The IsCorpse check is belt and braces: health alone missed the
				-- ragdoll's corpses for a while, and a body should never glow.
				skip = true
			elseif not cfg.thermalIncludeCreatures and CreatureUtil.IsCreature(model) then
				skip = true
			end

			if not skip then
				-- GetPivot, not HumanoidRootPart: it works on any Model, including a
				-- rig whose root is named something else or missing entirely.
				local ok, pivot = pcall(function()
					return model:GetPivot().Position
				end)
				if ok then
					local dist = (pivot - eye).Magnitude
					if dist <= range then
						table.insert(ranked, { model = model, dist = dist })
					end
				end
			end
		end
	end

	-- Nearest first, so the cap drops the far ones ? the ones least likely to be
	-- missed ? rather than whichever the iteration happened to reach last.
	table.sort(ranked, function(a, b)
		return a.dist < b.dist
	end)

	local depth = cfg.thermalThroughWalls
		and Enum.HighlightDepthMode.AlwaysOnTop
		or Enum.HighlightDepthMode.Occluded

	local fadeDist = cfg.thermalFadeDistance or 0
	local keep = {}
	local shown = math.min(#ranked, cfg.thermalMaxTargets)

	for i = 1, shown do
		local model = ranked[i].model
		keep[model] = true

		-- Distance falloff: dim out over the last `fadeDist` studs instead of
		-- blinking off the instant a target crosses the range limit.
		local want = 1
		if fadeDist > 0 then
			want = math.clamp((range - ranked[i].dist) / fadeDist, 0, 1)
		end

		local entry = pool[model]

		-- want <= 0 means it's sitting exactly on the range boundary: a new entry
		-- would be born at alpha 0 and reaped on the same frame. Create/destroy
		-- churn every rescan for anyone walking that line, and nothing to show.
		if not entry and want <= 0 then
			continue
		end

		if not entry or not entry.hl.Parent then
			local hl = Instance.new("Highlight")
			hl.Name = "Thermal"
			-- Adornee set BEFORE parenting, and the instance exists only while it
			-- has a target. This is the ECOTI pattern and the reason this version
			-- renders where the pooled one didn't.
			hl.Adornee = model
			hl.OutlineColor = cfg.thermalOutlineColor
			hl.FillColor = cfg.thermalFillColor
			hl.DepthMode = depth
			-- Start invisible; the per-frame fade brings it up from nothing so a
			-- target walking into range never pops.
			hl.OutlineTransparency = 1
			hl.FillTransparency = 1
			hl.Enabled = true
			hl.Parent = folder

			entry = { hl = hl, alpha = 0, want = want }
			pool[model] = entry
		end

		entry.want = want
		entry.hl.Adornee = model
		entry.hl.DepthMode = depth
		entry.hl.OutlineColor = cfg.thermalOutlineColor
		entry.hl.FillColor = cfg.thermalFillColor
		entry.hl.Enabled = true
	end

	-- Anything that left range, died, or fell off the bottom of the cap fades OUT
	-- rather than being destroyed here; step() reaps it once it reaches zero. A
	-- model that's gone from the DataModel is the exception ? nothing left to fade.
	for model, entry in pairs(pool) do
		if not model:IsDescendantOf(game) then
			entry.hl:Destroy()
			pool[model] = nil
		elseif not keep[model] then
			entry.want = 0
		end
	end

	if cfg.thermalDebug and os.clock() >= nextDebug then
		nextDebug = os.clock() + 1
		local registered = 0
		for _ in pairs(registry) do
			registered += 1
		end
		print(("[Thermal] %d humanoids known, %d in range, %d outlined")
			:format(registered, #ranked, shown))
	end
end

-- ============================================================
-- FADE
-- ============================================================
-- The rescan runs 4x a second. If it wrote transparency directly, a target
-- appearing or leaving would snap on and off a quarter-second at a time. So the
-- scan only sets each entry's `want`, and this walks `alpha` toward it every
-- frame ? smooth and framerate-independent no matter how coarse the rescan is.
local function step(dt: number)
	local fadeTime = cfg.thermalFadeTime or 0
	-- dt clamped so one lag spike can't jump a fade to completion.
	local amount = (fadeTime > 0) and (math.min(dt, 1 / 15) / fadeTime) or 1

	for model, entry in pairs(pool) do
		if entry.alpha ~= entry.want then
			if entry.alpha < entry.want then
				entry.alpha = math.min(entry.alpha + amount, entry.want)
			else
				entry.alpha = math.max(entry.alpha - amount, entry.want)
			end

			-- Interpolating toward 1 (invisible), rather than scaling the config
			-- value, is what lets a dim setting still fade all the way out instead
			-- of stalling at "faint but there".
			local a = entry.alpha
			entry.hl.OutlineTransparency = 1 - (1 - cfg.thermalOutlineTransparency) * a
			entry.hl.FillTransparency = 1 - (1 - cfg.thermalFillTransparency) * a
		end

		if entry.alpha <= 0 and entry.want <= 0 then
			entry.hl:Destroy()
			pool[model] = nil
		end
	end
end

local function clearAll()
	for model, entry in pairs(pool) do
		if entry and entry.hl then
			entry.hl:Destroy()
		end
		pool[model] = nil
	end
	table.clear(pool)

	local f = folder or playerGui:FindFirstChild(FOLDER_NAME)
	if f then
		f:Destroy()
	end
	folder = nil
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil
	startRegistry()
end

function System.onAdded(_char: Model, config)
	cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end
	cfg.thermalMaxTargets = math.clamp(cfg.thermalMaxTargets, 1, 30)

	clearAll()
	ensureFolder()
	active = true
	nextScan = 0 -- scan on the very next frame, not in 0.25s
end

function System.onRemoved()
	active = false
	clearAll()
end

function System.update(dt: number)
	if not active then
		return
	end

	if os.clock() >= nextScan then
		nextScan = os.clock() + math.max(cfg.thermalRefresh, 0.05)
		scan()
	end

	step(dt)
end

return System
