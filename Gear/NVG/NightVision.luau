--!nonstrict
-- (nonstrict, not strict: the CONFIG.Amplify list below is a deliberately loose table --
-- some entries carry min/max clamps and some don't, and properties are read by name --
-- which strict mode can't express without a pile of casts. Runtime behaviour is
-- identical; this just keeps Studio's script analysis quiet.)
-- ================================================================
-- NIGHT VISION SYSTEM - Phase 1.1 (effects prototype)
-- Location: a LocalScript placed ANYWHERE INSIDE the NVG device model
--   (the model root, or its "Middle" part -- both work, since the whole model is
--   welded onto your character when equipped).
--   When you equip the device from the locker, the Arsenal welds the gear onto
--   your character -- the LocalScript then runs (only on your client). Unequipping,
--   dying, or respawning destroys the gear, which destroys this script, and the
--   cleanup handler below tears the goggles down. So the script's very presence
--   means "device equipped": no separate gear check needed.
--   Because the CONFIG lives with the model, EACH NVG can be tuned independently
--   -- copy the script into every device model and edit its CONFIG.
-- Toggle: N          (goggles down / up -- the ECOTI thermal outlines ride along with it)
-- UI is aspect-locked (no stretch); grain clipped to the tube; mount baked in mask.
-- ================================================================

local Players           = game:GetService("Players")
local Lighting          = game:GetService("Lighting")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ContentProvider   = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")   -- only for JSONEncode; no web requests

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ---------------------------------------------------------------
-- On-screen notification ("NV DEVICE ON" / "NV DEVICE OFF")
-- Uses the shared SPH NotificationHandler at
--   ReplicatedStorage > SPH_Assets > Modules > NotificationHandler
-- Resolved lazily on first use and fully pcall-guarded, so a missing/renamed
-- module can never break the goggles -- the toggle just runs silently instead.
-- ---------------------------------------------------------------
local notifier
local function notify(text: string)
	if not notifier then
		local ok, mod = pcall(function()
			local assets  = ReplicatedStorage:WaitForChild("SPH_Assets", 5)
			local modules = assets and assets:WaitForChild("Modules", 5)
			local handler = modules and modules:WaitForChild("NotificationHandler", 5)
			return handler and require(handler)
		end)
		if not ok or not mod then return end
		notifier = mod
	end
	-- ALWAYS the info style (grey "i" icon) -- never success / warning / error.
	pcall(function()
		notifier.Notify(text, { Icon = "info" })
	end)
end

-- ---------------------------------------------------------------
-- Physical goggle flip (shared with other players)
-- The two tubes (NVG_TubeL / NVG_TubeR) hang off Motor6D joints anchored to the
-- invisible hinge parts (NVG_HingeL / NVG_HingeR) inside this device model.
-- Toggling swings them down over the eyes / up onto the helmet. Joints have to be
-- driven on the SERVER to replicate, so we just tell it our on/off state and it
-- runs the swing for everyone. See NightVisionServer.
-- ---------------------------------------------------------------

-- Hinge names we recognise (short or long form -- use whichever you built).
local HINGE_NAMES = {
	NVG_HingeL = true, NVG_HingeLeft  = true,
	NVG_HingeR = true, NVG_HingeRight = true,
	NVG_HingeMain = true,
}

-- Find the NVG gear model this script lives in (the one holding the hinges).
-- STOPS AT THE CHARACTER. The old version walked all the way up to Workspace, so if the
-- hinge parts hadn't replicated into the gear model yet (the script starts running the
-- instant the locker welds the gear on, before the whole model has arrived), it kept
-- climbing and "found" the hinge names somewhere else in the world -- returning
-- Workspace as the NVG model. The server then had no tubes to swing, and the goggles
-- just didn't move. That race is why it happened only sometimes. Now an unresolved
-- lookup returns nil and we simply resolve again on the next toggle.
local function resolveNVGModel(): Instance?
	local node = script.Parent
	while node and node ~= workspace and node ~= game do
		for _, d in ipairs(node:GetDescendants()) do
			if HINGE_NAMES[d.Name] then
				return node
			end
		end
		-- Never search past the character -- above it is the whole workspace, which holds
		-- every OTHER player's goggles and their identically-named hinges.
		if node:FindFirstChildOfClass("Humanoid") then
			return nil
		end
		node = node.Parent
	end
	return nil
end

local nvgModel = resolveNVGModel()

-- Re-resolve lazily: if the first attempt came up empty (or the model was swapped), try
-- again at toggle time instead of being stuck with a bad answer for the whole life.
local function getNVGModel(): Instance?
	if nvgModel and nvgModel:IsDescendantOf(game) then
		return nvgModel
	end
	nvgModel = resolveNVGModel()
	return nvgModel
end

-- Grab the server remote without blocking the rest of the script if it's missing.
local stateRemote
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("NightVisionRemotes", 10)
	if folder then
		stateRemote = folder:WaitForChild("SetState", 10)
	end
end)

-- Ask the server to swing the tubes up/down for everyone.
-- Second "goggles didn't move" cause fixed here: on a fresh join the remote often hadn't
-- replicated yet, so an early toggle hit `stateRemote == nil` and the flip was silently
-- dropped -- the vision effect came on but the tubes stayed up. Now we wait for the
-- remote instead. goggleSeq makes sure a fast double-toggle can't land out of order.
local goggleSeq = 0
local function pushGoggleState(isOn: boolean)
	local model = getNVGModel()
	if not model then
		warn("[NVG] Couldn't find the hinge parts (NVG_HingeL / NVG_HingeR / NVG_HingeMain) "
			.. "in this device model -- the tubes can't swing.")
		return
	end
	goggleSeq += 1
	local mySeq = goggleSeq
	task.spawn(function()
		if not stateRemote then
			local folder = ReplicatedStorage:FindFirstChild("NightVisionRemotes")
				or ReplicatedStorage:WaitForChild("NightVisionRemotes", 5)
			stateRemote = folder and (folder:FindFirstChild("SetState") or folder:WaitForChild("SetState", 5))
		end
		if mySeq ~= goggleSeq then return end -- a newer toggle already superseded this one
		if stateRemote then stateRemote:FireServer(model, isOn) end
	end)
end

-- ---------------------------------------------------------------
-- CONFIG
-- ---------------------------------------------------------------
local CONFIG = {
	ToggleKey = Enum.KeyCode.N,

	-- TOGGLE ANIMATIONS (R6). Upload your "pull goggles down" and "lift goggles up"
	-- animations and paste their asset ids here. Leave "" to skip the animation for
	-- that direction (it then just switches instantly, like before).
	ToggleOnAnimId  = "rbxassetid://72913919313756",  -- reach up and pull the goggles DOWN over the eyes
	ToggleOffAnimId = "rbxassetid://136237922449042", -- lift the goggles back UP off the eyes
	-- In EACH animation, add a Keyframe Marker with THIS name at the frame where the
	-- hands reach the goggles. The vision effect and the shared NVG_Up/NVG_Down flip
	-- fire the instant that marker is hit -- so it lines up with the grab, not the
	-- keypress. You can't toggle again until the animation finishes.
	ToggleMarker = "Toggle",
	-- Safety net (seconds). If the animation's Stopped event never arrives -- asset still
	-- downloading, Animator swapped on respawn, a higher-priority anim cut it off -- the
	-- toggle used to stay locked FOREVER and N did nothing for the rest of that life.
	-- After this long we force the switch through and unlock. Set it a bit longer than
	-- your longest toggle animation.
	ToggleTimeout = 2,

	ScopeMaskId = "rbxassetid://92037083541636",

	-- Grain frames. Upload nvg_grain_1..4.png and put their ids here (order doesn't matter).
	-- The script cycles through them to make the specks twinkle like a real tube.
	GrainIds = {
		"rbxassetid://102466299076881",
		"rbxassetid://137436695557551",
		"rbxassetid://109459083570900",
		"rbxassetid://88935297266148",
	},
	GrainFPS = 14, -- how many times per second the grain frame swaps (higher = faster twinkle)

	-- Overlay sizing
	-- The mask is ONE wide image shown with Crop; ScopeZoom scales the whole overlay
	-- (tube + grain together), so it's your one dial for how big the tube is on screen.
	--   1.0 = mask sized to screen height,  >1 = bigger tube,  <1 = smaller.
	ScopeZoom  = 1.30,
	ScopeScale = 1.40, -- (unused; kept for reference)

	-- Grain diameter as a fraction of the TUBE (0.70 = the speckle disc sits just inside
	-- the tube's inner edge). The grain is a ROUND image clipped to a circle -- raise this
	-- until the speckles reach the tube wall, lower it if they spill past the mask.
	TubeScale  = 0.70,

	-- The surround's see-through is already baked into the image (~88% opaque, like your
	-- reference). This adds EXTRA transparency on top: 0 = leave the image as-is,
	-- higher = more of the world shows through the surround.
	ScopeTransparency = 0,

	-- ===========================================================
	-- LIGHT AMPLIFICATION -- what actually lets you see at night.
	-- ===========================================================
	-- Built to live alongside LightingCycle, which is a SERVER script that rewrites a
	-- whole batch of Lighting/Atmosphere properties every 0.1s from its Midnight/Morning/
	-- Noon/Sunset presets. Every property listed here is re-asserted on top of whatever
	-- the cycle last wrote, once per frame. All of it is client-local (Lighting writes on
	-- a client don't replicate), so only YOU see the amplified world.
	--
	-- Raising Brightness alone barely helped, and that's why the goggles felt weak at
	-- night: the cycle's Midnight preset gets its darkness mostly from Ambient (10,10,10),
	-- OutdoorAmbient (30,30,30) and EnvironmentDiffuseScale 0 -- Brightness is only the
	-- sun/moon multiplier, and at midnight there's almost nothing for it to multiply.
	-- So we lift the ambient terms and exposure too, which is what actually pulls detail
	-- out of the shadows.
	--
	-- Each entry is { inst, prop, mode, amount, min, max }:
	--   inst   "Lighting" or "Atmosphere" (the cycle's Atmosphere under Lighting)
	--   mode   "add"  -> cycle value + amount   (amount can be negative)
	--          "set"  -> amount, ignoring the cycle value
	--          "lift" -> Color3 lerped toward AmpLiftColor by amount (0..1)
	--   min/max  HARD clamp on the final value. Always set these on an "add" entry --
	--            they're the safety net that makes a runaway boost impossible no matter
	--            what else goes wrong. (See AMP_EPSILON below for the runaway that
	--            turned the whole screen near-black.)
	-- Delete or comment out a line to stop touching that property entirely.
	-- What "lift" pulls the ambient colors toward. This is the CEILING of the whole
	-- amplification: an ambient can never get brighter than this no matter how high you push
	-- the lift amounts, so it's the first dial to raise if the tube still feels dim.
	-- Side benefit of a higher value: in DAYLIGHT the base ambient is already bright, and
	-- lerping toward a low ceiling actually DARKENED it. At 168 that barely happens.
	AmpLiftColor = Color3.fromRGB(168, 168, 168),
	Amplify = {
		-- The conservative, known-good set. Brightness is the sun/moon multiplier; the two
		-- ambients are what actually pull detail out of Midnight's shadows.
		{ inst = "Lighting", prop = "Brightness",              mode = "add",  amount = 4.5, min = 0, max = 7 },
		{ inst = "Lighting", prop = "EnvironmentDiffuseScale", mode = "set",  amount = 1 },
		{ inst = "Lighting", prop = "Ambient",                 mode = "lift", amount = 0.425 },
		{ inst = "Lighting", prop = "OutdoorAmbient",          mode = "lift", amount = 0.525 },

		-- OPTIONAL EXTRAS -- uncomment one at a time once the basics look right.
		-- ExposureCompensation feeds Roblox's tonemapper, which is the touchiest of the
		-- bunch: too much and the engine compresses everything else toward black.
		-- { inst = "Lighting",   prop = "ExposureCompensation", mode = "add", amount = 0.35, min = -1, max = 1 },
		-- Midnight's atmosphere (Haze 2.5) fogs out anything past a few hundred studs.
		-- { inst = "Atmosphere", prop = "Haze",                 mode = "add", amount = -1.5,  min = 0, max = 10 },
		-- { inst = "Atmosphere", prop = "Density",              mode = "add", amount = -0.08, min = 0, max = 1 },
	},

	-- Print the live base/target for every amplified property once a second while the
	-- goggles are on. Turn this on if the lighting still looks wrong -- if a "base" value
	-- climbs frame after frame instead of tracking the cycle, the boost is compounding.
	AmpDebug = false,

	-- The cycle drives its OWN Bloom / ColorCorrection / SunRays instances under Lighting,
	-- and Roblox stacks every post-process effect in the game. Our NV_Bloom (Intensity 3,
	-- Threshold 0.42) on top of the cycle's Bloom is what was blowing the whole tube out to
	-- white, and the cycle's ColorCorrection TintColor was fighting the phosphor tint.
	-- While the goggles are down we just switch the cycle's effects off locally and put
	-- them back on toggle-off. The cycle only ever writes their VALUES, never .Enabled, so
	-- it never fights us over this. Names must match the instances LightingCycle resolves.
	SuppressEffects = { "Bloom", "ColorCorrection", "SunRays" },

	-- Camera field of view while the goggles are on (mimics the slight zoom of a real
	-- tube). Your original FOV is saved and restored when you toggle off.
	-- IMPORTANT: this number is ALSO published to the weapon system as the player
	-- attribute "NightVisionFOV". While a gun is equipped, CharacterClient's FOV
	-- smoother owns the camera FOV every frame -- it pins the base FOV to this value
	-- while night vision is on (hipfire AND aimed), which is why pulling out a gun no
	-- longer snaps you back to the default 70. Change it here and both paths follow.
	ScopeFOV        = 55,

	-- Phosphor tube (ColorCorrection) -- the blue tube tint + a little extra lift.
	TintColor  = Color3.fromRGB(117, 188, 255),
	Saturation = -1,
	-- Post-process lift applied AFTER the scene is lit. Cheap extra brightness, but it
	-- raises the black point too, so pushing it much past ~0.35 starts to look milky /
	-- washed out rather than brighter. Prefer raising the Amplify block above first --
	-- that adds real light, which is what actually reveals detail in shadow.
	Brightness = 0.25,
	Contrast   = 0.22,

	-- Bloom
	BloomIntensity = 3,
	BloomSize      = 100000,
	-- Scene luminance a pixel must exceed before it blooms. Raised from 0.36 to sit above
	-- the brighter amplified scene -- at 0.36 the extra light pushed ordinary surfaces over
	-- the line and hazed the tube toward white. Still far below the HDR emissives that are
	-- MEANT to glow (IR laser beams run Brightness 18), so those are untouched.
	BloomThreshold = 0.42,

	-- Blur (soft focus over the whole view)
	BlurSize = 9.5,

	-- Depth of field. Near stays soft (close-up out of focus, like a distance-focused
	-- tube); the far DOF blur is off (FarIntensity 0) so distance isn't double-blurred
	-- on top of the overall BlurEffect above.
	DOF_FocusDistance = 34,
	DOF_InFocusRadius = 7,
	-- Near blur: how soft everything CLOSER than the focus plane goes (your own gun and
	-- hands, mostly). Way down from the original 0.3 -- the BlurEffect above already softens
	-- the whole view, so a strong near blur on top of it mushed the weapon. 0 = near blur off.
	DOF_NearIntensity = 0.1,
	DOF_FarIntensity  = 0,

	-- Grain (the ROUND speckle image, shown once to fill the tube)
	GrainColor        = Color3.fromRGB(205, 228, 240),
	-- Lower = more visible grain. 0.7 is the old circular-clip default; if your speckle
	-- frames are very sparse (only a few percent alpha) you may want 0.25-0.4 instead.
	GrainTransparency = 0.7,

	-- WOBBLE -- the tube lags behind camera movement like head-mounted goggles,
	-- then springs back to center. Purely visual; moves the overlay, not the camera.
	WobbleEnabled   = true,
	WobblePush      = 150,   -- how hard camera turning kicks the tube (pixels per rad/s)
	WobbleStiffness = 95,    -- spring return strength (higher = snappier back to center)
	WobbleDamping   = 6,     -- how fast it settles (lower = bouncier/more overshoot)
	WobbleMaxOffset = 32,    -- soft limit -- it can bounce a little past this (px)
	WobbleWallStiffness = 4, -- how firm the soft limit is (higher = less overshoot past it)
	WobbleSafetyMul = 1.8,   -- hard cap = MaxOffset * this, so the mask edge never shows

	-- ===========================================================
	-- ECOTI -- the clip-on thermal imager.
	-- ===========================================================
	-- Real ECOTI clips onto the front of the tube and fuses a thermal picture into the
	-- night-vision image, so warm bodies pop out of the scene. We fake the useful half of
	-- that: every Model with a Humanoid inside range gets a Highlight (outline + faint
	-- fill). Purely client-side -- Highlights this script creates never replicate, so only
	-- YOU see them.
	--
	-- NO EXTRA KEYBIND. It rides the goggles: flip the NVGs down (N) and the outlines come
	-- with them, flip them up and they go away. EcotiEnabled below is the per-device switch
	-- -- set it false on an NVG model that shouldn't have thermal, true on one that should.
	EcotiEnabled = true,

	EcotiRange      = 250,  -- studs from the camera; anything further out isn't outlined
	EcotiMaxTargets = 24,   -- HARD CAP. Roblox only renders ~31 Highlights at once and silently
	-- drops the rest, so we keep the nearest N and stay under the limit.
	EcotiRefresh    = 0.25, -- seconds between target rescans (not every frame -- this is the cheap part)

	-- false = outlines are hidden by walls (realistic: thermal still needs line of sight).
	-- true  = wallhack-style, targets glow through geometry.
	EcotiThroughWalls = false,

	-- BRIGHTNESS. Remember NV_CC runs with Saturation -1, so the HUE of these colors is
	-- thrown away and only their brightness survives -- dim them here, not by picking a
	-- different color. Dropping the color toward grey and raising the transparencies both
	-- do the same job; using both keeps NV_Bloom (Threshold 0.42) from grabbing the
	-- outlines and smearing them into a white haze.
	EcotiOutlineColor        = Color3.fromRGB(170, 170, 170),
	EcotiOutlineTransparency = 0.45,
	EcotiFillColor           = Color3.fromRGB(150, 150, 150),
	EcotiFillTransparency    = 0.72, -- 1 = outline only, 0 = solid blob

	-- FADING -- nothing pops in or out.
	-- EcotiFadeTime      seconds for a target to fade all the way in / all the way out.
	--                    0 goes back to the old hard snap.
	-- EcotiFadeDistance  studs of falloff at the edge of EcotiRange. A target dims out as
	--                    it walks toward the limit instead of vanishing at exactly 250
	--                    studs. 0 disables the distance falloff (the fade in/out on
	--                    appearing and disappearing still applies).
	EcotiFadeTime     = 0.4,
	EcotiFadeDistance = 60,

	EcotiIncludeSelf = false, -- outline your own character too (only visible in third person)
	EcotiIncludeDead = false, -- keep outlining corpses (Health <= 0)

	-- Where to look for NPCs. Player characters are always found. Beyond that we scan the
	-- direct children of Workspace plus the direct children of each folder named here --
	-- add your own ("NPCs", "Zombies", "AI"...). Deliberately NOT a full Workspace
	-- descendant walk: that would be thousands of instances every rescan.
	EcotiSearchFolders = { "NPCs", "Enemies", "Bots" },
}

-- ---------------------------------------------------------------
-- State
-- ---------------------------------------------------------------
local enabled = false
local cc, bloom, dof, blur
local gui, scope, grainClip, grain
local loopConn
-- Per CONFIG.Amplify entry: the cycle's current un-amplified value, and the exact value
-- we last wrote (so we can tell the cycle's writes apart from our own).
local ampBase  = {}
local ampWrote = {}
local ampNextDebug -- rate-limits the CONFIG.AmpDebug printout to once a second
-- Per suppressed effect: its .Enabled before we switched it off.
local ampSuppressed = {}

--[[
	THE RESTORE BLOB -- how cleanup survives THIS SCRIPT'S DEATH.

	Everything this script changes about the world lives in Lua locals: ampBase holds
	the day/night cycle's un-amplified values, ampSuppressed holds whether the cycle's
	Bloom / ColorCorrection / SunRays were on before we switched them off. When the
	locker destroys the gear, this script dies -- and every one of those locals dies
	with it. NightVisionWatcher then has no way to put any of it back: it can delete
	the NV_* effects and the overlay, because those it can find BY NAME, but a value
	it was never told is gone for good. That's how a player ends up with the game's
	Bloom and SunRays switched off for the rest of the round.

	So we write it down where it outlives us: an attribute on Lighting. Attributes
	survive the instance they're on, not the script that wrote them -- which is
	exactly why NV_BaseFOV was the one piece of cleanup that already worked.

	JSON because attributes hold strings, not tables. Color3 goes in as {r,g,b} and
	comes back out the same way -- see the decoder in the watcher.

	Rewritten only when something in it actually CHANGES (the cycle writing a new
	base, roughly ten times a second), never once per frame.
--]]
local RESTORE_ATTR = "NV_Restore"
local restoreDirty = true

local function encodeValue(v: any): any
	if typeof(v) == "Color3" then
		return { r = v.R, g = v.G, b = v.B }
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
	if ok then
		Lighting:SetAttribute(RESTORE_ATTR, encoded)
	end
end

-- We cleaned up properly, so there is nothing left for the watcher to undo.
local function clearRestoreBlob()
	Lighting:SetAttribute(RESTORE_ATTR, nil)
end

--[[
	Undo a PREVIOUS device's changes from its blob.

	Same job the watcher does, and deliberately duplicated rather than shared: these
	are two independent scripts with no module between them, and the whole point of
	the watcher is that it works when this script doesn't exist. Twenty lines in two
	places is the cost of that independence.

	Called from buildGui, so equipping a fresh NVG also cleans up after one that died
	mid-"on" -- the watcher's grace period means it may not have fired yet.
--]]
local function decodeValue(v: any): any
	if type(v) == "table" and v.r ~= nil and v.g ~= nil and v.b ~= nil then
		return Color3.new(v.r, v.g, v.b)
	end
	return v
end

local function restoreFromBlob()
	local raw = Lighting:GetAttribute(RESTORE_ATTR)
	if type(raw) ~= "string" then return end

	local ok, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if ok and type(data) == "table" then
		for _, item in ipairs(data.light or {}) do
			local inst: any = (item.inst == "Lighting") and Lighting or Lighting:FindFirstChild(item.inst)
			if inst then
				pcall(function() inst[item.prop] = decodeValue(item.value) end)
			end
		end
		for _, item in ipairs(data.suppressed or {}) do
			local e = Lighting:FindFirstChild(item.name)
			if e then
				pcall(function() (e :: any).Enabled = item.enabled end)
			end
		end
	end

	Lighting:SetAttribute(RESTORE_ATTR, nil)
end

-- The cycle's Atmosphere lives under Lighting (LightingCycle resolves it the same way).
local function ampInstance(name: string): Instance?
	if name == "Lighting" then return Lighting end
	return Lighting:FindFirstChild(name)
end

-- How close a value has to be to what we wrote to still count as "ours".
--
-- THIS TOLERANCE IS NOT OPTIONAL, and leaving it out is what broke everything and made
-- the screen go almost black. Roblox stores these properties as 32-bit floats, but Luau
-- numbers are 64-bit doubles: write 0.6 and read back 0.60000002384185791. An exact `~=`
-- comparison therefore concluded "the day/night cycle changed this!" on EVERY single
-- frame, so the already-amplified value became the new base and the boost compounded 60
-- times a second. Brightness and exposure ran away to absurd values, Roblox's tonemapper
-- compressed the scene to compensate, and everything crushed to black.
--
-- 1e-4 is far above float32's rounding error (~1e-7) and far below anything the cycle
-- does in one 0.1s tick, so our own writes read back as ours and the cycle's don't.
local AMP_EPSILON = 1e-4

local function ampNearly(a, b): boolean
	if a == nil or b == nil then return false end
	if typeof(a) == "Color3" then
		if typeof(b) ~= "Color3" then return false end
		return math.abs(a.R - b.R) < AMP_EPSILON
			and math.abs(a.G - b.G) < AMP_EPSILON
			and math.abs(a.B - b.B) < AMP_EPSILON
	end
	if typeof(a) ~= "number" or typeof(b) ~= "number" then return a == b end
	return math.abs(a - b) < AMP_EPSILON
end

local function ampTarget(entry, base)
	if entry.mode == "set" then
		return entry.amount
	elseif entry.mode == "lift" then
		if typeof(base) ~= "Color3" then return base end
		-- Bounded by construction: a lerp toward a fixed color can never run away.
		return base:Lerp(CONFIG.AmpLiftColor, math.clamp(entry.amount, 0, 1))
	end
	local v = base + entry.amount
	-- Hard clamp. Second line of defence: even if the "is this ours?" check above were
	-- ever fooled again, the boost physically cannot climb past these bounds.
	if entry.min then v = math.max(v, entry.min) end
	if entry.max then v = math.min(v, entry.max) end
	return v
end

-- Re-assert the amplification on top of whatever LightingCycle last wrote. Called once
-- per frame from the render loop (~60fps against the cycle's ~10/sec, so it's never
-- visibly behind and there's no flicker).
--
-- It is NOT driven by Lighting's changed signals any more. That's what threw
-- "Maximum event re-entrancy depth exceeded for Object.BrightnessChanged": Roblox DEFERS
-- property-changed events, so by the time the handler ran, the `applyingLight = false`
-- line had already executed -- the guard was useless, our own write re-entered the
-- handler, wrote again, re-entered again, and the engine killed it. Once killed, the
-- boost stopped re-applying and the world went dark again mid-use.
--
-- The trick that replaces the guard: remember the value we wrote, and compare against it
-- with a tolerance (see AMP_EPSILON). Anything that isn't ours came from the cycle, so
-- that becomes the new base to amplify on top of.
local function reapplyLight()
	for _, entry in ipairs(CONFIG.Amplify) do
		local inst: any = ampInstance(entry.inst)
		if inst then
			local cur = inst[entry.prop]
			-- Anything that ISN'T (near enough) what we wrote came from the cycle, so
			-- that's the new base. See AMP_EPSILON -- an exact comparison here is what
			-- made the boost compound every frame.
			if not ampNearly(cur, ampWrote[entry]) then
				ampBase[entry] = cur
				-- The base moved, so what the watcher would have to restore moved with
				-- it. Marking it here is what keeps the blob a LIVE record rather than
				-- a snapshot from whenever the goggles went on.
				restoreDirty = true
			end
			local want = ampTarget(entry, ampBase[entry])
			if not ampNearly(cur, want) then
				inst[entry.prop] = want
			end
			ampWrote[entry] = want
		end
	end

	-- Hand the current bases to the watcher. Only when something actually moved --
	-- this is ~10 writes a second (the cycle's tick rate), not one per frame.
	if restoreDirty then
		restoreDirty = false
		writeRestoreBlob()
	end

	if CONFIG.AmpDebug and (not ampNextDebug or os.clock() >= ampNextDebug) then
		ampNextDebug = os.clock() + 1
		for _, entry in ipairs(CONFIG.Amplify) do
			print(("[NVG] %s.%s  cycle base = %s  ->  applied = %s")
				:format(entry.inst, entry.prop, tostring(ampBase[entry]), tostring(ampWrote[entry])))
		end
	end
end

-- Hand every amplified property back to the cycle, using the base we've been tracking
-- LIVE rather than a snapshot taken when the goggles went on (which, twenty in-game
-- minutes later, would be a value from a completely different preset).
local function restoreLight()
	for _, entry in ipairs(CONFIG.Amplify) do
		local inst: any = ampInstance(entry.inst)
		if inst and ampBase[entry] ~= nil then
			inst[entry.prop] = ampBase[entry]
		end
	end
	table.clear(ampBase)
	table.clear(ampWrote)
	-- We put it all back ourselves, so there's nothing left for the watcher to undo.
	clearRestoreBlob()
end

-- Switch the cycle's own post-process effects off / back on (client-local). The cycle
-- writes their property VALUES but never .Enabled, so it never fights us here.
local function setSuppressedEffects(off: boolean)
	if off then
		for _, name in ipairs(CONFIG.SuppressEffects) do
			local e = Lighting:FindFirstChild(name)
			if e and ampSuppressed[name] == nil then
				ampSuppressed[name] = e.Enabled
				e.Enabled = false
			end
		end
		-- Record what we just switched off BEFORE anything can go wrong. If this
		-- script dies in the next frame, this attribute is the only thing that knows
		-- the world's Bloom / ColorCorrection / SunRays were ever touched.
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
-- The camera FOV baseline is stashed as an attribute (NV_BaseFOV on the Camera) so
-- it survives even if this per-device script dies without cleaning up.

-- Wobble spring state
local wobOffset = Vector2.new(0, 0) -- current overlay offset (px)
local wobVel    = Vector2.new(0, 0) -- spring velocity
local prevCamCF                     -- camera CFrame from last frame

-- helper: lock a GuiObject to a square. `axis` chooses which screen dimension
-- drives the side length (Height keeps it round vs. height, Width vs. width).
local function square(obj: GuiObject, scale: number, axis: Enum.DominantAxis)
	obj.AnchorPoint = Vector2.new(0.5, 0.5)
	obj.Position = UDim2.fromScale(0.5, 0.5)
	obj.Size = UDim2.fromScale(scale, scale)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = axis
	ar.AspectType = Enum.AspectType.ScaleWithParentSize
	ar.Parent = obj
end

-- ---------------------------------------------------------------
-- ECOTI (clip-on thermal)
--
-- One Highlight per target, parented to a folder in PlayerGui. Highlights work from
-- anywhere in the DataModel as long as .Adornee points at the model, and keeping them
-- out of the character models means we never touch anything the server owns -- nothing
-- to replicate, nothing to clean off someone else's rig.
--
-- Highlights are POOLED: a target that's still in range on the next rescan keeps the
-- same Highlight, so there's no create/destroy churn (which is what makes naive
-- versions of this flicker).
--
-- FADING. The rescan only runs every EcotiRefresh (0.25s), so if the scan wrote the final
-- transparency directly, a target appearing or leaving would snap on/off a quarter-second
-- at a time -- exactly the hard pop you don't want. So the scan no longer touches
-- transparency at all: it only sets each entry's `want` (0..1, how visible this target
-- SHOULD be, including the distance falloff). ecotiStep then walks every entry's `alpha`
-- toward its `want` EVERY FRAME and writes the transparencies from that. Fading is
-- therefore smooth and framerate-independent no matter how coarse the rescan is.
-- ---------------------------------------------------------------
local ecotiFolder -- Folder in PlayerGui holding the Highlights

-- target model -> { hl, alpha (what's on screen now), want (what it's heading toward) }
type EcotiEntry = { hl: Highlight, alpha: number, want: number }
local ecotiPool: { [Instance]: EcotiEntry } = {}
local ecotiNextScan = 0

local ECOTI_FOLDER_NAME = "ECOTI_Highlights"

local function ecotiEnsureFolder()
	if ecotiFolder and ecotiFolder:IsDescendantOf(playerGui) then return end
	local stale = playerGui:FindFirstChild(ECOTI_FOLDER_NAME)
	if stale then stale:Destroy() end
	table.clear(ecotiPool)
	ecotiFolder = Instance.new("Folder")
	ecotiFolder.Name = ECOTI_FOLDER_NAME
	ecotiFolder.Parent = playerGui
end

-- Every Model with a Humanoid we're willing to consider. See CONFIG.EcotiSearchFolders
-- for why this isn't a full workspace walk.
local function ecotiCollect(out: { [Instance]: Humanoid })
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char and char.Parent then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then out[char] = hum end
		end
	end

	local roots: { Instance } = { workspace }
	for _, name in ipairs(CONFIG.EcotiSearchFolders) do
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

-- Rebuild the set of outlined targets. Nearest-first, capped at EcotiMaxTargets.
-- Sets each entry's `want` only -- ecotiStep does the actual fading.
local function ecotiScan()
	ecotiEnsureFolder()

	local cam = workspace.CurrentCamera
	if not cam then return end
	local eye = cam.CFrame.Position
	local myChar = player.Character
	local range = CONFIG.EcotiRange

	local found: { [Instance]: Humanoid } = {}
	ecotiCollect(found)

	-- Filter, then sort by distance so the cap keeps the CLOSEST targets, not whichever
	-- ones the iteration happened to reach first.
	local ranked: { { model: Instance, dist: number } } = {}
	for model, hum in pairs(found) do
		local skip = false
		if model == myChar and not CONFIG.EcotiIncludeSelf then skip = true end
		if not CONFIG.EcotiIncludeDead and hum.Health <= 0 then skip = true end
		if not skip then
			local pivotOk, pivot = pcall(function() return (model :: any):GetPivot().Position end)
			if pivotOk then
				local d = (pivot - eye).Magnitude
				if d <= range then
					table.insert(ranked, { model = model, dist = d })
				end
			end
		end
	end
	table.sort(ranked, function(a, b) return a.dist < b.dist end)

	local keep: { [Instance]: boolean } = {}
	local depth = CONFIG.EcotiThroughWalls
		and Enum.HighlightDepthMode.AlwaysOnTop
		or Enum.HighlightDepthMode.Occluded

	local fadeDist = CONFIG.EcotiFadeDistance or 0

	for i = 1, math.min(#ranked, CONFIG.EcotiMaxTargets) do
		local model = ranked[i].model
		keep[model] = true

		-- Distance falloff: dim out over the last `fadeDist` studs of range instead of
		-- blinking off the instant a target crosses EcotiRange.
		local want = 1
		if fadeDist > 0 then
			want = math.clamp((range - ranked[i].dist) / fadeDist, 0, 1)
		end

		-- A CREATURE is cold-blooded: faint at rest, hotter when it sprints, roars or
		-- feeds. The server publishes how hot it is right now as ThermalHeat (0-1,
		-- see CreatureHeat); the outline is scaled by it. Anything without the
		-- attribute shows at full strength, exactly as before.
		if (model :: any):GetAttribute("IsCreature") == true then
			local heat = (model :: any):GetAttribute("ThermalHeat")
			if typeof(heat) == "number" then
				want *= math.clamp(heat, 0, 1)
			end
		end

		local entry = ecotiPool[model]
		-- want <= 0 means this target is sitting exactly at the edge of EcotiRange, so
		-- a brand-new entry would be created here at alpha 0 / want 0 and destroyed by
		-- ecotiStep on the same frame -- create/destroy churn every rescan for anyone
		-- walking the range boundary. Nothing to show, so don't make one.
		if not entry and want <= 0 then
			continue
		end
		if not entry or not entry.hl.Parent then
			local hl = Instance.new("Highlight")
			hl.Name = "ECOTI"
			-- Start fully transparent: the fade-in below brings it up from nothing, so a
			-- target that walks into range never pops.
			hl.OutlineTransparency = 1
			hl.FillTransparency    = 1
			hl.Parent = ecotiFolder
			entry = { hl = hl, alpha = 0, want = want }
			ecotiPool[model] = entry
		end

		entry.want = want
		entry.hl.Adornee     = model
		entry.hl.DepthMode   = depth
		entry.hl.OutlineColor = CONFIG.EcotiOutlineColor
		entry.hl.FillColor    = CONFIG.EcotiFillColor
		entry.hl.Enabled = true
	end

	-- Anything that walked out of range, died, or fell off the bottom of the cap gets
	-- want = 0 and fades OUT -- it isn't destroyed here. ecotiStep removes it once it has
	-- actually reached zero. A model that's gone from the DataModel is the exception:
	-- there's nothing left to fade, so drop it immediately.
	for model, entry in pairs(ecotiPool) do
		if not model:IsDescendantOf(game) then
			entry.hl:Destroy()
			ecotiPool[model] = nil
		elseif not keep[model] then
			entry.want = 0
		end
	end
end

-- Wipe every outline IMMEDIATELY, no fade. This is the teardown path (goggles up, gear
-- unequipped, respawn) -- the whole screen is changing anyway, so there's nothing to
-- ease out of. Safe to call at any time, including from cleanup.
local function ecotiClear()
	for model, entry in pairs(ecotiPool) do
		if entry and entry.hl then entry.hl:Destroy() end
		ecotiPool[model] = nil
	end
	table.clear(ecotiPool)
	local folder = ecotiFolder or playerGui:FindFirstChild(ECOTI_FOLDER_NAME)
	if folder then folder:Destroy() end
	ecotiFolder = nil
end

-- Called once a frame from the render loop, which only runs while the goggles are down --
-- so the outlines exist exactly as long as the NVGs are on, nothing else to switch.
--
-- Two jobs, at two different rates:
--   RESCAN  every EcotiRefresh seconds -- the expensive part (who's in range).
--   FADE    every frame -- cheap, and what keeps the outlines from snapping.
local function ecotiStep(dt: number)
	if not CONFIG.EcotiEnabled then return end

	if os.clock() >= ecotiNextScan then
		ecotiNextScan = os.clock() + math.max(CONFIG.EcotiRefresh, 0.05)
		ecotiScan()
	end

	-- Per-frame fade. `step` is how far alpha may travel this frame: dt / FadeTime makes
	-- the fade take FadeTime seconds regardless of framerate. FadeTime 0 = instant (the
	-- old snap behaviour).
	local fadeTime = CONFIG.EcotiFadeTime or 0
	local step = (fadeTime > 0) and (math.min(dt, 1 / 15) / fadeTime) or 1

	for model, entry in pairs(ecotiPool) do
		if entry.alpha ~= entry.want then
			if entry.alpha < entry.want then
				entry.alpha = math.min(entry.alpha + step, entry.want)
			else
				entry.alpha = math.max(entry.alpha - step, entry.want)
			end

			-- alpha 0 -> fully transparent;  alpha 1 -> the CONFIG transparency.
			-- Interpolating toward 1 (invisible) rather than scaling the config value is
			-- what makes a dim setting like FillTransparency 0.72 still fade all the way
			-- out instead of stalling at "faint but there".
			local a = entry.alpha
			entry.hl.OutlineTransparency = 1 - (1 - CONFIG.EcotiOutlineTransparency) * a
			entry.hl.FillTransparency    = 1 - (1 - CONFIG.EcotiFillTransparency)    * a
		end

		-- Finished fading out -> now it's safe to reclaim the Highlight.
		if entry.alpha <= 0 and entry.want <= 0 then
			entry.hl:Destroy()
			ecotiPool[model] = nil
		end
	end
end

-- ---------------------------------------------------------------
-- Build overlay
-- ---------------------------------------------------------------
local function buildGui()
	-- Full reset of any stranded state from a previous device that didn't get to
	-- clean up (e.g. swapping to a new NVG while the old one was on): remove the
	-- overlay + post-process effects and restore the FOV baseline so this fresh
	-- device starts clean. (The amplified Lighting/Atmosphere properties aren't ours to
	-- restore here -- the day/night cycle re-asserts every one of them within 0.1s.)
	local stale = playerGui:FindFirstChild("NightVisionOverlay")
	if stale then stale:Destroy() end
	-- Same for a stranded ECOTI folder from a device that died mid-"on".
	ecotiClear()
	for _, name in ipairs({ "NV_CC", "NV_Bloom", "NV_DOF", "NV_Blur" }) do
		local e = Lighting:FindFirstChild(name)
		if e then e:Destroy() end
	end
	-- ...but the cycle NEVER touches .Enabled, so a stranded suppression would leave the
	-- world's Bloom / ColorCorrection / SunRays switched off for the rest of the round.
	-- The blob a dead device left behind knows their REAL previous state, so that wins;
	-- the unconditional switch-on below is the fallback for a device that died before it
	-- ever wrote one (or from a build that predates the blob entirely).
	restoreFromBlob()
	for _, name in ipairs(CONFIG.SuppressEffects) do
		local e = Lighting:FindFirstChild(name)
		if e then e.Enabled = true end
	end
	local cam0 = workspace.CurrentCamera
	if cam0 then
		local baseF = cam0:GetAttribute("NV_BaseFOV")
		if baseF ~= nil then cam0.FieldOfView = baseF; cam0:SetAttribute("NV_BaseFOV", nil) end
	end
	-- A device that died mid-"on" (swap / respawn) can leave the weapon system stuck in the
	-- forced canted pose at NV FOV. Clearing it here means a freshly equipped NVG always
	-- starts from goggles-up.
	player:SetAttribute("NightVisionActive", false)
	player:SetAttribute("NightVisionFOV", CONFIG.ScopeFOV)

	gui = Instance.new("ScreenGui")
	gui.Name = "NightVisionOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Negative DisplayOrder keeps the whole NVG overlay UNDER your game's UI.
	-- Normal ScreenGuis default to DisplayOrder 0, so they'll always sit on top.
	gui.DisplayOrder = -5
	gui.Enabled = false
	gui.Parent = playerGui

	-- GRAIN -- the round speckle image, CLIPPED TO A CIRCLE just inside the tube.
	--
	-- GrainClip is a square Frame (UIAspectRatioConstraint keeps it square against screen
	-- HEIGHT, so it stays round on any aspect ratio) with a 0.5 UICorner and
	-- ClipsDescendants -- i.e. a circular window. The grain image fills it exactly and is
	-- cut off at that circle, so the speckles live inside the tube and nowhere else.
	--
	-- Sized off TubeScale * ScopeZoom, so it tracks the mask when you change the zoom.
	-- This assumes a ONE-TUBE (or centred-lobe) mask -- a round clip is what fits it.
	grainClip = Instance.new("Frame")
	grainClip.Name = "GrainClip"
	grainClip.BackgroundTransparency = 1
	grainClip.ClipsDescendants = true
	grainClip.ZIndex = 1 -- under the mask (ZIndex 2)
	square(grainClip, CONFIG.TubeScale * CONFIG.ScopeZoom, Enum.DominantAxis.Height)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0) -- perfect circle
	corner.Parent = grainClip
	grainClip.Parent = gui

	grain = Instance.new("ImageLabel")
	grain.Name = "Grain"
	grain.BackgroundTransparency = 1
	grain.Image = CONFIG.GrainIds[1] or ""   -- "" = no image, rather than an error, while the frames are still being uploaded
	grain.ImageColor3 = CONFIG.GrainColor
	grain.ImageTransparency = CONFIG.GrainTransparency
	grain.ScaleType = Enum.ScaleType.Fit -- show the round image once, no repeating
	grain.AnchorPoint = Vector2.new(0.5, 0.5)
	grain.Position = UDim2.fromScale(0.5, 0.5)
	grain.Size = UDim2.fromScale(1, 1) -- fill the tube exactly
	grain.ZIndex = 1
	grain.Parent = grainClip

	-- Preload the grain frames so the first twinkle cycle doesn't pop in.
	task.spawn(function()
		pcall(function() ContentProvider:PreloadAsync(CONFIG.GrainIds) end)
	end)

	-- Scope mask = ONE wide image (round transparent tube + feathered see-through surround)
	-- shown full-screen with Crop. Single layer, so nothing overlaps itself: no seams and
	-- no double-darkening. The wide canvas means Crop always fills the whole screen.
	scope = Instance.new("ImageLabel")
	scope.Name = "ScopeMask"
	scope.BackgroundTransparency = 1
	scope.Image = CONFIG.ScopeMaskId
	scope.ScaleType = Enum.ScaleType.Crop -- cover the whole screen, keep the tube round
	scope.ImageTransparency = CONFIG.ScopeTransparency
	scope.AnchorPoint = Vector2.new(0.5, 0.5)
	scope.Position = UDim2.fromScale(0.5, 0.5)
	scope.Size = UDim2.fromScale(CONFIG.ScopeZoom, CONFIG.ScopeZoom)
	scope.ZIndex = 2
	scope.Parent = gui

	-- OWNER TAG -- read by NightVisionWatcher.
	-- The watcher's job is to delete a STRANDED overlay (one whose device is gone). It
	-- used to decide that from the hinge parts alone, and a device model replicates in
	-- pieces: this script can be running, and this overlay built, before the hinges have
	-- arrived on the client. On a locker swap that gap made the watcher delete the
	-- overlay of the device that had just been equipped -- which is why the UI only ever
	-- showed up for the FIRST goggles of a life. Pointing at this script proves the
	-- device is alive, hinges replicated or not.
	local owner = Instance.new("ObjectValue")
	owner.Name = "Owner"
	owner.Value = script
	owner.Parent = gui
end

-- The overlay can be destroyed out from under us (the watcher, a respawn, another
-- device's buildGui). Never trust the cached `gui`: rebuild if it isn't live.
local function ensureGui()
	if not gui or not gui:IsDescendantOf(playerGui) then
		buildGui()
	end
end

-- ---------------------------------------------------------------
-- ON / OFF
-- ---------------------------------------------------------------
local function turnOn()
	-- Rebuild the overlay if it isn't live any more. MUST be first: buildGui does a full
	-- reset that destroys NV_CC / NV_Bloom / NV_DOF / NV_Blur, so calling it after those
	-- are created would wipe the effects we just made.
	ensureGui()

	-- LIGHT AMPLIFICATION -- raise the real scene light (Brightness, both ambients,
	-- exposure, env diffuse, atmosphere haze) and keep it raised even though LightingCycle
	-- rewrites all of it from the server every 0.1s. Re-applied once per frame by the
	-- render loop below. All on THIS client -- Lighting writes on a client don't
	-- replicate -- so only we see the amplified world; everyone else still sees full night.
	table.clear(ampBase)
	table.clear(ampWrote)
	reapplyLight()
	-- Switch the cycle's own Bloom / ColorCorrection / SunRays off while the tube is down,
	-- so they don't stack on top of NV_Bloom and NV_CC.
	setSuppressedEffects(true)

	-- ---- TELL THE WEAPON SYSTEM THE GOGGLES ARE DOWN ----
	-- These two player attributes are the ONLY link between this script and
	-- CharacterClient / PlayerClient. They must be set before anything else, because:
	--   NightVisionActive -> CharacterClient FORCES the canted aim pose (NVAimPart) while
	--                        it's true, gates IR lasers / IR illuminators, and hides lens
	--                        flares. PlayerClient reads it for other players' IR gear.
	--   NightVisionFOV    -> CharacterClient's per-frame FOV smoother uses this as the base
	--                        FOV while NV is on, hipfire and aimed alike. Without it the
	--                        smoother would drag you straight back to the default 70 the
	--                        moment a gun is equipped.
	--[[
		These are written HERE for zero latency -- your own gun cants on the same frame
		the goggles drop, with no server round trip.

		But an attribute written on the client is client-local: it does NOT replicate,
		so nobody else's PlayerClient can ever see it. That's why the server writes
		NightVisionActive too, when it handles the SetState remote a moment later (see
		NightVisionServer). The server's copy replicates to everyone, including back to
		us with the same value -- so the local write is an optimistic head start on the
		authoritative one, not a competing source of truth.
	--]]
	player:SetAttribute("NightVisionFOV", CONFIG.ScopeFOV)
	player:SetAttribute("NightVisionActive", true)

	-- Camera FOV is client-owned (the cycle doesn't touch it), so we stash a baseline
	-- and restore it on cleanup. This direct write is what covers the UNARMED case --
	-- CharacterClient only drives the FOV while a gun is equipped. With a gun out it
	-- takes over on the next frame and snaps to the same ScopeFOV, so the two agree.
	local cam = workspace.CurrentCamera
	if cam then
		if cam:GetAttribute("NV_BaseFOV") == nil then
			cam:SetAttribute("NV_BaseFOV", cam.FieldOfView)
		end
		cam.FieldOfView = CONFIG.ScopeFOV
	end

	-- Reset wobble so it starts centered.
	wobOffset = Vector2.new(0, 0)
	wobVel    = Vector2.new(0, 0)
	prevCamCF = cam and cam.CFrame or nil

	cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "NV_CC"
	cc.TintColor  = CONFIG.TintColor
	cc.Saturation = CONFIG.Saturation
	cc.Contrast   = CONFIG.Contrast
	cc.Brightness = CONFIG.Brightness
	cc.Parent = Lighting

	bloom = Instance.new("BloomEffect")
	bloom.Name = "NV_Bloom"
	bloom.Intensity = CONFIG.BloomIntensity
	bloom.Size      = CONFIG.BloomSize
	bloom.Threshold = CONFIG.BloomThreshold
	bloom.Parent = Lighting

	dof = Instance.new("DepthOfFieldEffect")
	dof.Name = "NV_DOF"
	dof.FocusDistance = CONFIG.DOF_FocusDistance
	dof.InFocusRadius = CONFIG.DOF_InFocusRadius
	dof.NearIntensity = CONFIG.DOF_NearIntensity
	dof.FarIntensity  = CONFIG.DOF_FarIntensity
	dof.Parent = Lighting

	blur = Instance.new("BlurEffect")
	blur.Name = "NV_Blur"
	blur.Size = CONFIG.BlurSize
	blur.Parent = Lighting

	if gui then gui.Enabled = true end

	-- ECOTI scans on the very first frame of the render loop below, so the outlines appear
	-- with the goggles rather than up to EcotiRefresh seconds later.
	ecotiNextScan = 0

	loopConn = RunService.RenderStepped:Connect(function(dt)
		--[[
			`cc.Parent`, not just `cc`.

			Another device's buildGui destroys NV_CC as part of its reset, and a
			destroyed instance is still a perfectly valid non-nil Lua reference --
			writing to it succeeds silently, it's just not in the DataModel any more.
			So the old `if not cc then return end` never tripped, and a device whose
			effects had been taken from it kept running this loop forever: still
			amplifying Lighting every frame, still rebuilding the ECOTI folder the new
			device had just cleared. Checking Parent is what actually detects it.
		--]]
		if not cc or not cc.Parent then return end

		-- Clip-on thermal. Rescans on its own timer; fades every frame (needs dt).
		ecotiStep(dt)

		-- Keep the light boost on top of whatever the day/night cycle just wrote. Done
		-- here, once a frame, rather than from a Lighting changed-signal (see the note on
		-- reapplyLight -- that version recursed and got killed by the engine).
		reapplyLight()

		-- Cycle the grain frames so the specks twinkle like a real tube.
		-- The count check isn't paranoia: an empty GrainIds is the normal state while
		-- you're still uploading the frames, and `% 0` is a hard error every frame.
		if grain and #CONFIG.GrainIds > 1 then
			local frame = (math.floor(os.clock() * CONFIG.GrainFPS) % #CONFIG.GrainIds) + 1
			grain.Image = CONFIG.GrainIds[frame]
		end

		-- WOBBLE: the tube lags behind camera movement, then springs back to center.
		if CONFIG.WobbleEnabled and scope then
			local cam = workspace.CurrentCamera
			if cam then
				-- Clamp dt so a lag spike can't make the spring explode.
				local d = math.min(dt, 1 / 30)

				-- How much the camera turned since last frame (yaw + pitch, in radians).
				if prevCamCF then
					local rel = prevCamCF:ToObjectSpace(cam.CFrame)
					local pitch, yaw = rel:ToEulerAnglesYXZ()
					-- Kick the spring the SAME way as the turn so the tube leads the motion
					-- (look left -> tube slides left). Not physically accurate, but looks better.
					wobVel = wobVel + Vector2.new(-yaw, -pitch) * CONFIG.WobblePush
				end
				prevCamCF = cam.CFrame

				-- Damped spring back toward center (0,0).
				local accel = wobOffset * -CONFIG.WobbleStiffness - wobVel * CONFIG.WobbleDamping

				-- Soft limit: once past WobbleMaxOffset, add extra pull-back that grows
				-- with the overshoot. Acts like a springy cushion instead of a hard wall,
				-- so it can bounce a little past the limit and settle back.
				local m    = CONFIG.WobbleMaxOffset
				local wall = CONFIG.WobbleStiffness * CONFIG.WobbleWallStiffness
				local function cushion(o: number): number
					if o >  m then return -(o - m) * wall end
					if o < -m then return -(o + m) * wall end
					return 0
				end
				accel = accel + Vector2.new(cushion(wobOffset.X), cushion(wobOffset.Y))

				wobVel    = wobVel + accel * d
				wobOffset = wobOffset + wobVel * d

				-- Hard safety clamp far past the soft limit, so the mask edge can never
				-- actually slide into view no matter how hard you flick.
				local safe = m * CONFIG.WobbleSafetyMul
				wobOffset = Vector2.new(
					math.clamp(wobOffset.X, -safe, safe),
					math.clamp(wobOffset.Y, -safe, safe)
				)

				-- Move the mask and the grain together (the grain image rides inside
				-- grainClip, so moving the clip moves the speckles with it).
				local pos = UDim2.new(0.5, wobOffset.X, 0.5, wobOffset.Y)
				scope.Position = pos
				if grainClip then grainClip.Position = pos end
			end
		end
	end)
end

local function turnOff()
	-- Clear the link attribute FIRST so CharacterClient un-cants the gun and drops back to
	-- the normal aim / hipfire FOV on the very next frame, in step with the goggles lifting.
	-- NightVisionFOV is left in place (it's just a number the weapon system reads while NV
	-- is on) and re-published on every turnOn anyway.
	player:SetAttribute("NightVisionActive", false)

	if loopConn then loopConn:Disconnect() loopConn = nil end

	-- Thermal outlines go up with the goggles.
	ecotiClear()

	-- Stop re-applying amplification. Disconnecting the render loop above is all it takes
	-- now -- there are no Lighting signal connections any more. We still hand every
	-- amplified property back explicitly (from the live-tracked base, not a stale
	-- snapshot) so the FreezeTime / no-cycle case is clean instead of staying bright.
	restoreLight()
	-- Give the cycle's own post-process effects back.
	setSuppressedEffects(false)

	if gui then gui.Enabled = false end
	if cc then cc:Destroy() cc = nil end
	if bloom then bloom:Destroy() bloom = nil end
	if dof then dof:Destroy() dof = nil end
	if blur then blur:Destroy() blur = nil end

	-- Restore the original camera FOV. Idempotent: if another cleaner (the watcher /
	-- next device) already restored and cleared it, this is a harmless no-op.
	local cam = workspace.CurrentCamera
	if cam then
		local baseFOV = cam:GetAttribute("NV_BaseFOV")
		if baseFOV ~= nil then
			cam.FieldOfView = baseFOV
			cam:SetAttribute("NV_BaseFOV", nil)
		end
	end
end

-- ---------------------------------------------------------------
-- Toggle with animation
-- Pressing N plays a grab-and-flip animation. The real switch (vision effect + the
-- shared tube swing) fires on a Keyframe Marker partway through, so it
-- lines up with the hands reaching the goggles. Re-toggling is locked out until the
-- animation finishes.
-- ---------------------------------------------------------------
local busy = false        -- an animation is playing -> ignore toggle presses
local swapPending = false -- the state switch for the current play hasn't happened yet
local pendingOn = false   -- direction of the current play
local toggleGen = 0       -- bumped per toggle so a stale watchdog can't fire on a newer one

--[[
	Load the two animation tracks onto the character's Animator.

	LAZILY, not once at the top of the script. This used to run immediately, off
	whatever player.Character happened to be at that instant -- and the gear can be
	welded on during a respawn, before the Humanoid (let alone its Animator) exists.
	When that happened both tracks came back nil and stayed nil for the entire life of
	that device: no toggle animation at all, silently, with the switch falling through
	to the instant path. Now the first toggle resolves them, and a failed resolve is
	retried on the next toggle instead of being permanent.
--]]
local onTrack, offTrack
local tracksLoadedFor: Instance? = nil   -- the Animator we loaded onto
local bindTrack   -- forward declaration: ensureTracks wires each track as it loads it

local function ensureTracks()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- Already loaded onto THIS animator. A respawn brings a new one, and the old
	-- tracks belong to a Humanoid that no longer exists, so they're reloaded.
	if tracksLoadedFor == animator then return end
	tracksLoadedFor = animator

	local function loadTrack(id)
		if id and id ~= "" then
			local ok, track = pcall(function()
				local anim = Instance.new("Animation")
				anim.AnimationId = id
				local t = animator:LoadAnimation(anim)
				t.Priority = Enum.AnimationPriority.Action4 -- highest, wins over weapon anims
				return t
			end)
			if ok then return track end
		end
		return nil
	end

	onTrack  = loadTrack(CONFIG.ToggleOnAnimId)
	offTrack = loadTrack(CONFIG.ToggleOffAnimId)
	bindTrack(onTrack, true)
	bindTrack(offTrack, false)
	return true
end

-- Do the real switch (called from the animation marker, or as a fallback on end).
local function applySwap(isOn: boolean)
	enabled = isOn
	if isOn then turnOn() else turnOff() end
	pushGoggleState(isOn) -- server swings the Motor6D tubes so everyone sees it
	-- Fires at the same moment as the real switch (the animation marker), so the
	-- notification lands with the goggles moving, not with the keypress.
	notify(isOn and "NV DEVICE ON" or "NV DEVICE OFF")
end

-- Wire a track's marker (the switch point) and its end (unlock) for one direction.
-- Assigns the forward-declared local above, so ensureTracks can call it.
function bindTrack(track, isOn: boolean)
	if not track then return end
	track:GetMarkerReachedSignal(CONFIG.ToggleMarker):Connect(function()
		if busy and swapPending and pendingOn == isOn then
			swapPending = false
			applySwap(isOn)
		end
	end)
	track.Stopped:Connect(function()
		--[[
			A STALE Stopped MUST NOT UNLOCK A NEWER TOGGLE.

			The watchdog in requestToggle unlocks after ToggleTimeout even if the
			animation is still running -- so you can start a SECOND toggle while the
			first play is still going. When that first play then ends, its Stopped
			arrives against state that belongs to the second one. The pendingOn check
			catches the case where the two directions differ; it does NOT catch
			on -> off -> on, where the stale event's direction matches and it would
			apply the swap early and unlock a toggle that hasn't finished.

			IsPlaying is the tell: if this track is running again, the play that just
			stopped is not the one that owns `busy`, so it has no business here.
		--]]
		if track.IsPlaying then return end

		if busy and pendingOn == isOn then
			if swapPending then
				-- animation had no marker -> switch now so the state isn't left stuck
				swapPending = false
				applySwap(isOn)
			end
			busy = false -- unlock: you can toggle again
		end
	end)
end

local function requestToggle()
	if busy then return end -- locked while an animation plays
	-- Resolve the animation tracks now rather than at script start -- the character
	-- and its Animator may not have existed back then. Cheap after the first call.
	ensureTracks()
	local turningOn = not enabled
	local track = turningOn and onTrack or offTrack
	if track then
		busy = true
		swapPending = true
		pendingOn = turningOn
		toggleGen += 1
		local myGen = toggleGen

		if not pcall(function() track:Play() end) then
			-- The track refused to play at all (Animator torn down mid-respawn, bad asset).
			-- Don't leave the toggle locked -- just switch instantly, like the no-anim path.
			swapPending = false
			busy = false
			applySwap(turningOn)
			return
		end

		-- WATCHDOG -- the main reason the goggles sometimes did nothing at all.
		-- Everything that unlocks the toggle hung off track.Stopped. If that event never
		-- arrived (animation asset still downloading on the first press of the round, the
		-- Animator replaced on respawn, another Action4 anim cutting this one off), `busy`
		-- stayed true forever and N was dead for the rest of that life -- no error, no
		-- warning, nothing. Now, if we're still waiting after ToggleTimeout, we push the
		-- switch through and unlock. The gen check keeps a stale timer from touching a
		-- newer toggle.
		task.delay(CONFIG.ToggleTimeout or 2, function()
			if busy and toggleGen == myGen then
				if swapPending then
					swapPending = false
					applySwap(turningOn)
				end
				busy = false
			end
		end)
	else
		applySwap(turningOn) -- no animation set for this direction -> switch instantly
	end
end

buildGui()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == CONFIG.ToggleKey then
		requestToggle()
	end
end)

-- ---------------------------------------------------------------
-- Teardown -- this script is destroyed when the device is unequipped, or when the
-- character dies / respawns (the gear dies with it). The effects live on Lighting
-- and the overlay lives in PlayerGui, so they DON'T die automatically -- clean them
-- up here so nothing leaks into normal play once the goggles are gone.
-- ---------------------------------------------------------------
local cleanedUp = false
local function cleanup()
	if cleanedUp then return end
	cleanedUp = true
	enabled = false
	-- Restore lighting/FOV and remove the effects FIRST, guarding every step in a
	-- pcall so one failure can't block the rest (the gear + Animator are being torn
	-- down as this runs, so e.g. onTrack:Stop() can throw).
	pcall(turnOff)
	pcall(ecotiClear) -- belt and braces: turnOff already does this, but cleanup must not leak outlines
	if gui then pcall(function() gui:Destroy() end) gui = nil end
	pcall(function() if onTrack then onTrack:Stop() end end)
	pcall(function() if offTrack then offTrack:Stop() end end)
end

-- IMPORTANT: when the locker unequips the device, the SERVER destroys the gear and
-- that reaches us as replication -- which does NOT reliably fire `Destroying` on the
-- client. `AncestryChanged` is the signal that always fires when the gear (and this
-- script with it) is pulled out of the world, so it's the one we depend on. We keep
-- `Destroying` too for the local-Destroy case; `cleanup` is guarded to run only once.
script.AncestryChanged:Connect(function()
	if not script:IsDescendantOf(game) then
		cleanup()
	end
end)
script.Destroying:Connect(cleanup)
