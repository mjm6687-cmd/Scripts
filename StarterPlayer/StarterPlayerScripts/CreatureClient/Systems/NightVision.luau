-- NightVision  (ModuleScript, under CreatureClient > Systems)
--
-- N toggles it. The world gets brighter — not tinted, not overlaid. Detail comes
-- out of the shadows the way an animal's eyes pull it out, and the creature's red
-- vision keeps running on top unchanged.
--
-- ============================================================
-- WHY THIS ISN'T JUST "RAISE BRIGHTNESS"
-- ============================================================
-- Lighting.Brightness is only the SUN/MOON multiplier. At midnight there is almost
-- nothing for it to multiply, so raising it alone does close to nothing — which is
-- exactly why the first version of your NVG felt weak at night.
--
-- LightingCycle's Midnight preset gets its darkness mostly from Ambient (10,10,10),
-- OutdoorAmbient (30,30,30) and EnvironmentDiffuseScale 0. Those are the terms that
-- actually decide how much light exists in shadow, so those are what get lifted.
--
-- ============================================================
-- LIVING WITH LightingCycle
-- ============================================================
-- LightingCycle is a SERVER script that rewrites this whole batch of properties
-- every 0.1s from its presets. So the amplification is re-asserted once per frame
-- on top of whatever the cycle last wrote (~60fps against its ~10/sec, so it never
-- visibly lags and never flickers).
--
-- All of it is client-local — Lighting writes on a client don't replicate — so only
-- you see the brightened world. Everyone else still sees full night.
--
-- The whole approach, the epsilon below and the base-tracking are lifted from the
-- Amplify block in your NightVision.luau, because that one is proven against this
-- exact day/night cycle.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local System = {
	name = "NightVision",
	key = "nightvision",
	scope = "local",
}

local DEFAULTS = {
	nightVisionKey = Enum.KeyCode.N,
	nightVisionStartsOn = false,
	nightVisionFadeTime = 0.35,

	-- What the ambient colours are pulled TOWARD. This is the ceiling of the whole
	-- effect: ambient can never get brighter than this no matter how hard the lift
	-- amounts are pushed, so it's the first dial to raise if it still feels dim.
	--
	-- Keeping it high also fixes a daylight problem: in daytime the base ambient is
	-- already bright, and lerping toward a LOW ceiling actually DARKENS it. At 168
	-- that barely happens, so switching it on at noon does nothing much rather than
	-- looking broken.
	nightVisionLiftColor = Color3.fromRGB(168, 168, 168),
	nightVisionAmbientLift = 0.40,
	nightVisionOutdoorLift = 0.46,
	nightVisionBrightnessAdd = 3.8,
	nightVisionBrightnessMax = 5.5,
	nightVisionDiffuseScale = 1,

	--[[
		POST-PROCESS, applied AFTER the scene is lit.

		BRIGHTNESS IS THE THING THAT FLATTENS IT. It's a straight additive lift, so
		it raises the BLACK POINT by exactly as much as everything else: shadows
		that should stay black go grey, the range between darkest and lightest
		narrows, and the result looks washed out rather than brighter. That's what
		"a tiny bit too bright" actually was, so it's 0 now — all the real light
		comes from the ambient lifts above, which add light where light belongs
		instead of smearing it across the whole image.

		CONTRAST pivots around mid-grey: it pushes darks down and brights up at the
		same time. That's what puts the shape back, and it's why raising contrast
		makes a scene read as DARKER even though the bright end got brighter.
	--]]
	nightVisionPostBrightness = 0,
	nightVisionPostContrast = 0.1,
	-- Slight desaturation on top of what the red vision already does. An animal
	-- trading colour for sensitivity is the whole idea of a rod-dominant eye.
	nightVisionPostSaturation = -0.15,
}

local player = Players.LocalPlayer
local CreatureUtil

local cfg = table.clone(DEFAULTS)
local isCreature = false
local on = false

local postEffect: ColorCorrectionEffect

-- Per amplified property: the cycle's current un-amplified value, and the exact
-- value we last wrote (so we can tell the cycle's writes apart from our own).
local ampBase = {}
local ampWrote = {}
local entries = {}

--[[
	HOW CLOSE A VALUE HAS TO BE TO WHAT WE WROTE TO STILL COUNT AS "OURS".

	THIS TOLERANCE IS NOT OPTIONAL. Roblox stores these as 32-bit floats but Luau
	numbers are 64-bit doubles: write 0.6, read back 0.60000002384185791. An exact
	`~=` therefore concludes "the cycle changed this!" on EVERY frame, so the
	already-amplified value becomes the new base and the boost compounds 60 times a
	second. Brightness runs away, Roblox's tonemapper compresses to compensate, and
	the whole screen crushes to black.

	1e-4 is far above float32 rounding error (~1e-7) and far below anything the
	cycle does in one 0.1s tick, so our writes read back as ours and its don't.
--]]
local AMP_EPSILON = 1e-4

local function nearly(a, b): boolean
	if a == nil or b == nil then
		return false
	end
	if typeof(a) == "Color3" then
		if typeof(b) ~= "Color3" then
			return false
		end
		return math.abs(a.R - b.R) < AMP_EPSILON
			and math.abs(a.G - b.G) < AMP_EPSILON
			and math.abs(a.B - b.B) < AMP_EPSILON
	end
	if typeof(a) ~= "number" or typeof(b) ~= "number" then
		return a == b
	end
	return math.abs(a - b) < AMP_EPSILON
end

-- The cycle's Atmosphere lives under Lighting; LightingCycle resolves it the same way.
local function resolve(name: string): Instance?
	if name == "Lighting" then
		return Lighting
	end
	return Lighting:FindFirstChild(name)
end

local function buildEntries()
	entries = {
		{ inst = "Lighting", prop = "Brightness", mode = "add",
			amount = cfg.nightVisionBrightnessAdd, min = 0, max = cfg.nightVisionBrightnessMax },
		{ inst = "Lighting", prop = "EnvironmentDiffuseScale", mode = "set",
			amount = cfg.nightVisionDiffuseScale },
		{ inst = "Lighting", prop = "Ambient", mode = "lift",
			amount = cfg.nightVisionAmbientLift },
		{ inst = "Lighting", prop = "OutdoorAmbient", mode = "lift",
			amount = cfg.nightVisionOutdoorLift },
	}
end

local function targetFor(entry, base)
	if entry.mode == "set" then
		return entry.amount
	elseif entry.mode == "lift" then
		if typeof(base) ~= "Color3" then
			return base
		end
		-- Bounded by construction: a lerp toward a fixed colour can't run away.
		return base:Lerp(cfg.nightVisionLiftColor, math.clamp(entry.amount, 0, 1))
	end
	local v = base + entry.amount
	-- Hard clamp, the second line of defence. Even if the "is this ours?" check
	-- above were ever fooled again, the boost physically cannot climb past these.
	if entry.min then v = math.max(v, entry.min) end
	if entry.max then v = math.min(v, entry.max) end
	return v
end

--[[
	Re-assert the amplification on top of whatever LightingCycle last wrote.

	NOT driven by Lighting's Changed signals. That's what threw "Maximum event
	re-entrancy depth exceeded for Object.BrightnessChanged" in the NVG: Roblox
	DEFERS property-changed events, so by the time the handler ran the guard flag
	had already been cleared — our own write re-entered the handler, wrote again,
	re-entered again, and the engine killed the connection. Once killed, the boost
	stopped re-applying and the world went dark again mid-use.

	Remembering what we wrote and comparing with a tolerance is what replaces it.
--]]
local function reapply()
	for _, entry in ipairs(entries) do
		local inst: any = resolve(entry.inst)
		if inst then
			local cur = inst[entry.prop]
			-- Anything that ISN'T (near enough) what we wrote came from the cycle,
			-- so that's the new base to amplify on top of.
			if not nearly(cur, ampWrote[entry]) then
				ampBase[entry] = cur
			end
			local want = targetFor(entry, ampBase[entry])
			if not nearly(cur, want) then
				inst[entry.prop] = want
			end
			ampWrote[entry] = want
		end
	end
end

-- Hand every property back using the base we've been tracking LIVE, not a snapshot
-- from when it was switched on — twenty in-game minutes later that would be a value
-- from a completely different preset.
local function restore()
	for _, entry in ipairs(entries) do
		local inst: any = resolve(entry.inst)
		if inst and ampBase[entry] ~= nil then
			inst[entry.prop] = ampBase[entry]
		end
	end
	table.clear(ampBase)
	table.clear(ampWrote)
end

local function setOn(value: boolean)
	if on == value then
		return
	end
	on = value

	local info = TweenInfo.new(cfg.nightVisionFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	if on then
		table.clear(ampBase)
		table.clear(ampWrote)
		buildEntries()
		reapply()

		postEffect.Enabled = true
		TweenService:Create(postEffect, info, {
			Brightness = cfg.nightVisionPostBrightness,
			Contrast = cfg.nightVisionPostContrast,
			Saturation = cfg.nightVisionPostSaturation,
		}):Play()
	else
		restore()

		local tween = TweenService:Create(postEffect, info, {
			Brightness = 0, Contrast = 0, Saturation = 0,
		})
		tween:Play()
		tween.Completed:Once(function()
			if not on then
				postEffect.Enabled = false
			end
		end)
	end
end

function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil

	-- Its own named effect, like CreatureVision's. LightingCycle resolves its
	-- instances by the exact strings "ColorCorrection" / "Bloom", so a distinct
	-- name means the cycle can never find this one and overwrite it — and Roblox
	-- stacks post-processing, so the red vision reads straight through.
	postEffect = Instance.new("ColorCorrectionEffect")
	postEffect.Name = "CreatureNight_CC"
	postEffect.Enabled = false
	postEffect.Parent = Lighting

	-- Bound once, never unbound — the same rule the roar keys and the grab both
	-- learned the hard way. A binding made in a script that runs once per player
	-- cannot be re-made after unbinding, so unbinding on unmorph would kill N for
	-- the rest of the session. The handler passes the key through when you're not
	-- a creature.
	ContextActionService:BindActionAtPriority("Creature_NightVision", function(_, inputState)
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		local char = player.Character
		if not (isCreature and char and CreatureUtil.IsCreature(char)) then
			return Enum.ContextActionResult.Pass
		end
		setOn(not on)
		return Enum.ContextActionResult.Sink
	end, false, 2400, DEFAULTS.nightVisionKey)
end

function System.onAdded(_char: Model, config)
	cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	isCreature = true
	on = false
	setOn(cfg.nightVisionStartsOn == true)
end

function System.onRemoved()
	isCreature = false
	-- Unconditional: leaving a player's Lighting amplified for the rest of the
	-- round because they unmorphed with it on is exactly the class of bug the
	-- restore blob exists to catch in the NVG.
	setOn(false)
end

function System.update()
	if not on then
		return
	end
	-- Once a frame, against the cycle's ~10/sec. See reapply() for why this is a
	-- loop and not a Changed connection.
	reapply()
end

return System
