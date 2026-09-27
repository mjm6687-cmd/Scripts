-- Eyes  (ModuleScript, under CreatureClient > Systems)
--
-- Blinks every part named "Eye" inside Head > HeadModel by dropping its
-- Reflectance, independently of every other eye.
--
-- Two eyes blinking in sync is the most human thing a face can do — we have one
-- pair of eyelids, so ours are physically forced to match. Anything with more
-- than two eyes has no reason to.
--
-- Random intervals alone don't get you there: eyes sharing an average interval
-- drift into accidental unison periodically, and the moment they line up the
-- creature looks like it has a face. So each eye also gets a PERMANENT rate
-- multiplier, drawn once, and they can never converge.
--
-- ============================================================
-- REFLECTANCE, NOT TRANSPARENCY
-- ============================================================
-- Transparency made the eye vanish, which reads as a hole in the head. Killing
-- the reflectance instead makes it go dull — the wet shine drops out and the eye
-- is still there, just dead for a moment. Much closer to a nictitating membrane
-- than an eyelid, which is the right note for something that isn't a person.
--
-- ON THE NUMBERS: Roblox stores Reflectance as 0..1 and CLAMPS anything outside
-- it. So the -10 you asked for lands at 0 — fully matte, zero shine, which is
-- exactly the look you're after; it just can't go "more matte than matte". And
-- because 25 and -10 are plainly percentages, anything with a magnitude over 1
-- is divided by 100 below. Write 25 or 0.25, both give you a quarter.

local System = {
	name = "Eyes",
	key = "eyes",
	scope = "rig",
}

local DEFAULTS = {
	eyeHeadModelName = "HeadModel",
	eyePartName = "Eye",       -- every BasePart with this name gets blinked

	eyeOpenReflectance = 25,   -- resting shine
	eyeBlinkReflectance = -10, -- during the blink (clamps to 0 = fully matte)

	-- How long the reflectance takes to travel each way. A blink is fast, but a
	-- hard snap on a shine value reads as a lighting glitch rather than a blink,
	-- so there's a couple of frames of ramp on each edge.
	eyeCloseSpeed = 0.045,
	eyeOpenSpeed = 0.09,       -- opening slower than closing is what real lids do

	eyeBlinkMinGap = 1.8,
	eyeBlinkMaxGap = 7.5,
	eyeBlinkMinTime = 0.05,    -- short: a long blink reads as sleepy, which is a
	eyeBlinkMaxTime = 0.14,    -- warm expression and the wrong note entirely
	eyeRateMin = 0.5,
	eyeRateMax = 1.9,
	eyeDoubleBlinkChance = 0.22,
	eyeDoubleBlinkGapMin = 0.10,
	eyeDoubleBlinkGapMax = 0.24,
	eyeCloseOnDeath = true,
}

local rigs: { [Model]: any } = {}

local function randomRange(a: number, b: number): number
	if b <= a then return a end
	return a + math.random() * (b - a)
end

-- 25 -> 0.25,  -10 -> 0,  0.25 -> 0.25. See the note at the top.
local function toReflectance(value: number): number
	local v = value
	if math.abs(v) > 1 then
		v /= 100
	end
	return math.clamp(v, 0, 1)
end

local function scheduleNext(eye, cfg, now: number, isDouble: boolean)
	if isDouble then
		eye.nextAt = now + randomRange(cfg.eyeDoubleBlinkGapMin, cfg.eyeDoubleBlinkGapMax)
		eye.doubleQueued = false
	else
		eye.nextAt = now + randomRange(cfg.eyeBlinkMinGap, cfg.eyeBlinkMaxGap) * eye.rate
		eye.doubleQueued = math.random() < cfg.eyeDoubleBlinkChance
	end
end

function System.onAdded(rig: Model, config)
	local cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	cfg.openValue = toReflectance(cfg.eyeOpenReflectance)
	cfg.blinkValue = toReflectance(cfg.eyeBlinkReflectance)

	task.spawn(function()
		local head = rig:WaitForChild("Head", 10)
		if not head or not rig.Parent then
			return
		end

		local headModel = head:WaitForChild(cfg.eyeHeadModelName, 10)
		if not headModel then
			warn(("[Eyes] %s.Head has no '%s' — no eyes to blink.")
				:format(rig:GetFullName(), tostring(cfg.eyeHeadModelName)))
			return
		end

		local now = os.clock()
		local eyes = {}

		for _, d in ipairs(headModel:GetDescendants()) do
			-- Name match on a BasePart. MeshPart and Part both qualify; a Decal or
			-- SpecialMesh named "Eye" does not, since neither has a Reflectance.
			if d:IsA("BasePart") and d.Name == cfg.eyePartName then
				local eye = {
					part = d,
					current = cfg.openValue,
					target = cfg.openValue,
					rate = randomRange(cfg.eyeRateMin, cfg.eyeRateMax),
					closedUntil = nil,
					doubleQueued = false,
				}
				d.Reflectance = cfg.openValue
				-- Staggered first blink. Without this every eye starts its timer on
				-- the same frame and the creature's very first blink is perfectly
				-- synchronised — the exact thing this avoids, at the exact moment
				-- the player first sees it.
				eye.nextAt = now + randomRange(0, cfg.eyeBlinkMaxGap) * eye.rate
				table.insert(eyes, eye)
			end
		end

		if #eyes == 0 then
			warn(("[Eyes] '%s' contains no BaseParts named '%s'.")
				:format(headModel:GetFullName(), tostring(cfg.eyePartName)))
			return
		end

		rigs[rig] = {
			rig = rig,
			cfg = cfg,
			eyes = eyes,
			humanoid = rig:FindFirstChildOfClass("Humanoid"),
			dead = false,
		}
	end)
end

function System.onRemoved(rig: Model)
	rigs[rig] = nil
end

function System.update(dt: number)
	local now = os.clock()

	for rig, state in pairs(rigs) do
		if not rig.Parent then
			rigs[rig] = nil
			continue
		end

		local cfg = state.cfg

		-- Death latches: a corpse shouldn't keep paying for a blink loop. The eyes
		-- are left matte rather than shiny — a dead thing with wet eyes looks alive.
		if cfg.eyeCloseOnDeath and state.humanoid and state.humanoid.Health <= 0 then
			if not state.dead then
				state.dead = true
				for _, eye in ipairs(state.eyes) do
					if eye.part.Parent then
						eye.part.Reflectance = cfg.blinkValue
					end
				end
			end
			continue
		end

		for _, eye in ipairs(state.eyes) do
			if eye.part.Parent then
				-- TIMING
				if eye.closedUntil then
					if now >= eye.closedUntil then
						eye.target = cfg.openValue
						eye.closedUntil = nil
						scheduleNext(eye, cfg, now, eye.doubleQueued)
					end
				elseif now >= eye.nextAt then
					eye.target = cfg.blinkValue
					eye.closedUntil = now + randomRange(cfg.eyeBlinkMinTime, cfg.eyeBlinkMaxTime)
				end

				-- RAMP. Closing and opening get their own speeds, so the blink has
				-- a direction to it instead of being symmetrical.
				if eye.current ~= eye.target then
					local closing = (eye.target < eye.current)
					local speed = closing and cfg.eyeCloseSpeed or cfg.eyeOpenSpeed
					-- Travel measured against the full open->blink span, so the ramp
					-- takes `speed` seconds whatever those two values happen to be.
					local span = math.abs(cfg.openValue - cfg.blinkValue)
					local stepSize = (speed > 0 and span > 0)
						and (span * math.min(dt, 1 / 15) / speed)
						or math.huge

					if closing then
						eye.current = math.max(eye.current - stepSize, eye.target)
					else
						eye.current = math.min(eye.current + stepSize, eye.target)
					end

					eye.part.Reflectance = eye.current
				end
			end
		end
	end
end

return System
