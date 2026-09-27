--[[
	AuroraServer  --  Script in ServerScriptService
	------------------------------------------------
	Decides tonight's aurora and tells every client. It builds nothing itself:
	AuroraClient (StarterPlayerScripts) builds the same sky on each client from
	the seed published here, so everyone sees the same aurora.

	Each day at noon it rolls the coming night:
	  * what kind of night it is (none / quiet / active / storm -- see CHANCES)
	  * a random SEED, so the shape is different every night
	  * when it switches on and off during the night
	and during the night it fires SURGES (substorms): the aurora flares brighter
	and moves faster for a minute or so.

	CENTRE POINT: put an anchored Part named "AuroraCenter" anywhere in Workspace
	(inside a folder is fine) where you want the middle of the display. Its
	FRONT face sets which way the main arcs run (they swing +-30 degrees around
	it each night). Give it a number attribute "Area" to change how far the
	aurora spreads (studs across, default 10000). Move it while playing and the
	aurora follows.

	TESTING (set these on Lighting in the Properties window while playing):
	  AuroraForce  (string)  "Quiet" / "Active" / "Storm" / "None": every roll
	                         uses that kind of night and it is on all night.
	                         Blank = random again.
	  AuroraReroll (bool)    tick it to roll a new sky right now.

	Everything it publishes is an attribute on Lighting (they start with Aurora).
]]

local Lighting = game:GetService("Lighting")

-- How often each kind of night comes up (weights, don't need to add to 100).
local CHANCES = {
	{ kind = "None",   weight = 20 },
	{ kind = "Quiet",  weight = 45 },
	{ kind = "Active", weight = 28 },
	{ kind = "Storm",  weight = 7 },
}

--[[
	When it's on, in hours after noon: 6 = 18:00, 12 = midnight, 17 = 05:00.
	AuroraClient also fades it with the darkness, so an early onset still waits
	for the sky to get dark.
--]]
local ONSET = NumberRange.new(6.5, 10)   -- 18:30 .. 22:00
local ENDS = NumberRange.new(14.5, 17.5) -- 02:30 .. 05:30

-- Surges, in real seconds. every = gap between them.
local SURGES = {
	Quiet  = { every = NumberRange.new(240, 600), length = NumberRange.new(20, 40), power = NumberRange.new(0.3, 0.6) },
	Active = { every = NumberRange.new(120, 300), length = NumberRange.new(25, 60), power = NumberRange.new(0.5, 1.0) },
	Storm  = { every = NumberRange.new(50, 150),  length = NumberRange.new(30, 80), power = NumberRange.new(0.8, 1.5) },
}

local CENTER_NAME = "AuroraCenter"
local DEFAULT_AREA = 10000

-------------------------------------------------------------------------------

local rng = Random.new()

local function pick(range: NumberRange): number
	return rng:NextNumber(range.Min, range.Max)
end

local function nightHours(): number
	return (Lighting.ClockTime - 12) % 24
end

local function rollKind(): string
	local forced = Lighting:GetAttribute("AuroraForce")
	if type(forced) == "string" and forced ~= "" then
		for _, c in ipairs(CHANCES) do
			if c.kind:lower() == forced:lower() then
				return c.kind
			end
		end
		warn(("[Aurora] AuroraForce %q isn't None/Quiet/Active/Storm -- rolling randomly."):format(forced))
	end
	local total = 0
	for _, c in ipairs(CHANCES) do total += c.weight end
	local r = rng:NextNumber(0, total)
	for _, c in ipairs(CHANCES) do
		r -= c.weight
		if r <= 0 then return c.kind end
	end
	return CHANCES[#CHANCES].kind
end

-- Centre point -------------------------------------------------------------

local warnedNoCenter = false

local function publishCenter()
	local part = workspace:FindFirstChild(CENTER_NAME, true)
	local pos, yaw, area = Vector3.zero, 0, DEFAULT_AREA
	if part and part:IsA("BasePart") then
		pos = part.Position
		local look = part.CFrame.LookVector
		yaw = math.deg(math.atan2(look.Z, look.X))
		area = tonumber(part:GetAttribute("Area")) or DEFAULT_AREA
	elseif not warnedNoCenter then
		warnedNoCenter = true
		warn("[Aurora] No Part named " .. CENTER_NAME .. " in Workspace -- centring the aurora on 0, 0, 0.")
	end

	-- Only publish real changes: each one makes every client rebuild the sky.
	local oldPos = Lighting:GetAttribute("AuroraCenter")
	local oldYaw = Lighting:GetAttribute("AuroraYaw") or 0
	if typeof(oldPos) ~= "Vector3" or (oldPos - pos).Magnitude > 5 then
		Lighting:SetAttribute("AuroraCenter", pos)
	end
	if math.abs((yaw - oldYaw + 180) % 360 - 180) > 1 then
		Lighting:SetAttribute("AuroraYaw", yaw)
	end
	if Lighting:GetAttribute("AuroraArea") ~= area then
		Lighting:SetAttribute("AuroraArea", area)
	end
end

-- Rolling a night ---------------------------------------------------------

local kind = "None"
local nextSurge = math.huge

local function scheduleSurge(fromNow: number)
	local s = SURGES[kind]
	nextSurge = s and (os.clock() + fromNow) or math.huge
end

local function roll()
	kind = rollKind()
	local forced = (Lighting:GetAttribute("AuroraForce") or "") ~= ""
	publishCenter()
	Lighting:SetAttribute("AuroraOnset", forced and 5.5 or pick(ONSET))
	Lighting:SetAttribute("AuroraEnd", forced and 18.5 or pick(ENDS))
	Lighting:SetAttribute("AuroraBurstStart", 0)
	Lighting:SetAttribute("AuroraBurstLength", 0)
	Lighting:SetAttribute("AuroraBurstPower", 0)
	-- Kind last, seed after it: clients rebuild when the seed changes.
	Lighting:SetAttribute("AuroraActivity", kind)
	Lighting:SetAttribute("AuroraSeed", rng:NextInteger(1, 2 ^ 30))
	if SURGES[kind] then
		scheduleSurge(pick(SURGES[kind].every) * 0.5)
	else
		scheduleSurge(0)
	end
	print(("[Aurora] Tonight: %s (on %.1fh after noon, off %.1fh after noon)."):format(
		kind, Lighting:GetAttribute("AuroraOnset"), Lighting:GetAttribute("AuroraEnd")))
end

if Lighting:GetAttribute("AuroraForce") == nil then
	Lighting:SetAttribute("AuroraForce", "")
end
Lighting:SetAttribute("AuroraReroll", false)

Lighting:GetAttributeChangedSignal("AuroraReroll"):Connect(function()
	if Lighting:GetAttribute("AuroraReroll") then
		Lighting:SetAttribute("AuroraReroll", false)
		roll()
	end
end)
Lighting:GetAttributeChangedSignal("AuroraForce"):Connect(roll)

roll()

-- Main loop: new night at noon, surges during the night, follow the centre.
local lastHours = nightHours()
while true do
	task.wait(1)
	local h = nightHours()

	-- Crossed noon (going forward): roll the coming night.
	if h < lastHours and lastHours - h > 12 then
		roll()
	end
	lastHours = h

	publishCenter()

	local s = SURGES[kind]
	if s and os.clock() >= nextSurge then
		local onset = Lighting:GetAttribute("AuroraOnset") or 0
		local ends = Lighting:GetAttribute("AuroraEnd") or 0
		if h >= onset and h <= ends then
			local length = pick(s.length)
			Lighting:SetAttribute("AuroraBurstLength", length)
			Lighting:SetAttribute("AuroraBurstPower", pick(s.power))
			Lighting:SetAttribute("AuroraBurstStart", workspace:GetServerTimeNow())
			scheduleSurge(length + pick(s.every))
		else
			scheduleSurge(10) -- not on yet; check again shortly
		end
	end
end
