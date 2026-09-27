--[[
	DroneClient  (LocalScript)
	PUT IN: StarterPack > Recon Drone (Tool)   <- directly inside the Tool

	Controls
	  Click the floor ............ deploy drone
	  Click anywhere (drone out) . start flying
	  (while flying) click ....... stop flying
	  WASD ....................... move
	  Space / E .................. up
	  LeftShift / Q .............. down
	  Mouse ...................... look / turn
	  Hold E on the drone ........ pick it back up

	The camera sits at the "DroneCamera" part inside the drone model.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")

local tool = script.Parent
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local remote = ReplicatedStorage:WaitForChild("DroneRemote")
local moveRemote = ReplicatedStorage:WaitForChild("DroneMoveRemote")
local HUD = require(tool:WaitForChild("DroneHUD"))

-- On-screen notifications via your SPH NotificationHandler
--   ReplicatedStorage > SPH_Assets > Modules > NotificationHandler
-- Resolved lazily and pcall-guarded, so a missing module never breaks the drone.
local notifier
-- notify(text, type, tag)
--   type = "info" | "success" | "warning" | "error"  (colour of the tag box)
--   tag  = word in the tag box                         (defaults to "DRONE")
local function notify(text, kind, tag)
	if not notifier then
		local ok, mod = pcall(function()
			local assets = ReplicatedStorage:WaitForChild("SPH_Assets", 5)
			local modules = assets and assets:WaitForChild("Modules", 5)
			local handler = modules and modules:WaitForChild("NotificationHandler", 5)
			return handler and require(handler)
		end)
		if not ok or not mod then return end
		notifier = mod
	end
	pcall(function()
		notifier.Notify(text, { Type = kind or "info", Tag = tag or "DRONE" })
	end)
end

-- Settings --------------------------------------------------------------------
local DEPLOY_RANGE = 30        -- max studs from you to the deploy spot (server allows a little more)
local PICKUP_RANGE = 15        -- max studs from you to pick the drone up (server allows a little more)
local FLOOR_NORMAL_Y = 0.6     -- how "flat" a surface must be to count as floor

local SPEED = 40               -- horizontal flying speed
local VERTICAL_SPEED = 25      -- up/down speed
local ACCELERATION = 3         -- lower = smoother / floatier, higher = snappier
local MAX_RANGE = 1000         -- how far the drone can fly from your character
local COLLISION_SKIN = 0.08    -- gap kept between the drone and whatever it touches
-- (the collision box itself is measured from your drone model's visible parts)

-- Crashing
local CRASH_SPEED = 0.35       -- fraction of SPEED: hitting a wall/object faster than this = crash
local GROUND_CRASH_SPEED = 30  -- studs/s straight into the GROUND needed to crash (so normal
-- landings / descending at full speed don't crash)
-- Engine start (first time you fly it after deploying)
local ENGINE_SPOOL_TIME = 1.0  -- seconds the engine spools up; you can look around but not move

local CRASH_STATIC_TIME = 2    -- seconds of "SIGNAL LOST" static before the view returns to you
local CRASH_SOUND_FADE = 0.2   -- seconds for the engine sound to die out after a crash
local SEND_RATE = 30           -- position updates per second sent to other players

-- Wind noise (only the pilot hears it - it's a local sound, not in the world)
local WIND_SOUND_ID = "rbxassetid://103410800974365"
local WIND_SPEED_THRESHOLD = 0.6 -- fraction of SPEED you need to be going (0.6 = 60% of max speed)
local WIND_DELAY = 0.4           -- seconds of fast flying before the wind kicks in
local WIND_VOLUME = 0.25         -- max volume
local WIND_FADE_IN = 3           -- how fast it fades in (lower = slower)
local WIND_FADE_OUT = 10         -- how fast it fades out when you let go / slow down
local OTHERS_SMOOTHING = 15    -- how smoothly other players' drones move on your screen

local MOUSE_SENSITIVITY = 0.0035

-- Zoom (scroll wheel while flying)
local ZOOM_LEVELS = { 1, 1.5, 2, 3, 4, 6, 8 } -- each scroll notch moves one step
local ZOOM_SMOOTHING = 6       -- how fast it glides to the new zoom (higher = faster)
local NFOV_AT = 4              -- HUD says NFOV (narrow) from this zoom up
local REFOCUS_BLUR = 12        -- blur for the BIGGEST zoom jump (1x <-> 8x); small jumps blur much less
local REFOCUS_TIME = 0.45      -- seconds to "find focus" after the biggest jump (small jumps are quicker)

local TILT_AMOUNT = 0.35       -- how much it leans forward/sideways when moving
local BANK_AMOUNT = 0.08       -- how much it rolls when turning
local MAX_BANK = 0.45
local CAMERA_TILT_FOLLOW = 0.5 -- 0 = camera stays level, 1 = camera leans fully with the drone


local ROTOR_IDLE_SPEED = 45    -- rotor spin (radians/sec) while hovering
local ROTOR_FLY_SPEED = 80     -- rotor spin while flying (goes up with speed)

-- Motor sound (DroneHum in the DroneSound part - everyone hears it)
local HUM_IDLE_PITCH = 0.85    -- hovering, not being flown
local HUM_IDLE_VOLUME = 0.35
local HUM_FLY_PITCH = 1.0      -- being flown, standing still
local HUM_FLY_VOLUME = 0.5
local HUM_SPEED_PITCH = 0.35   -- extra pitch at full speed
local HUM_SPEED_VOLUME = 0.35  -- extra volume at full speed
local HUM_CLIMB_PITCH = 0.1    -- extra pitch when climbing (less when descending)
local HUM_PILOT_VOLUME = 0.6   -- volume multiplier for the pilot

-- State -----------------------------------------------------------------------
local drone = nil
local piloting = false   -- you're controlling it (camera + input)
local flying = false     -- drone is being moved by this script (also while it settles after you stop)
local dronePos = Vector3.zero
local settleTime = 0
local flightTime = 0     -- total flying time for this deploy (drives the HUD timer/battery)
local fastTime = 0       -- how long you've been going fast (for the wind noise)
local zoomIndex = 1
local zoom = 1
local baseFOV = 70
local refocus = 0        -- 1 = just zoomed, counts down to 0 as it comes into focus
local refocusStrength = 0 -- how big the last zoom jump was (0..1) -> how much it blurs
local refocusDuration = REFOCUS_TIME
local zoomBlur = nil
local crashed = false
local spoolLeft = 0 -- seconds of engine spool-up left (movement locked while > 0)
local colSize = Vector3.new(3, 1, 3)   -- collision box size (world-aligned, fits any yaw)
local colOffset = Vector3.zero         -- box center relative to the drone's pivot
local pendingCrash = nil -- impact velocity, set by moveWithCollision when a hit is hard enough
local windVolume = 0

local sendTimer = 0
local targetYaw, targetPitch = 0, 0
local yaw, pitch = 0, 0
local turnRate = 0
local currentVel = Vector3.zero
local lean = CFrame.new()

local function smooth(rate, dt)
	-- frame-rate independent smoothing factor
	return 1 - math.exp(-rate * dt)
end

-- Wind noise ----------------------------------------------------------------
local windSound = Instance.new("Sound")
windSound.Name = "DroneWind"
windSound.SoundId = WIND_SOUND_ID
windSound.Looped = true
windSound.Volume = 0
windSound.Parent = SoundService -- created by a LocalScript = only you hear it

local function updateWind(dt, active)
	local horizSpeed = Vector3.new(currentVel.X, 0, currentVel.Z).Magnitude
	local threshold = SPEED * WIND_SPEED_THRESHOLD

	if active and horizSpeed >= threshold then
		fastTime += dt
	else
		fastTime = math.max(fastTime - dt * 2, 0) -- a quick dip doesn't fully reset it
	end

	local target = 0
	local over = math.clamp((horizSpeed - threshold) / math.max(SPEED - threshold, 1), 0, 1)
	if active and fastTime >= WIND_DELAY then
		-- gusty: volume wobbles a bit over time
		local gust = 1 + math.noise(os.clock() * 0.8, 1.7) * 0.5
		target = WIND_VOLUME * (0.7 + 0.3 * over) * gust
	end

	local rate = target > windVolume and WIND_FADE_IN or WIND_FADE_OUT
	windVolume += (target - windVolume) * (1 - math.exp(-rate * dt))

	if windVolume > 0.01 then
		if not windSound.IsPlaying then windSound:Play() end
		windSound.Volume = windVolume
		windSound.PlaybackSpeed = 0.95 + over * 0.1 + math.noise(os.clock() * 0.5, 4.2) * 0.06
	elseif windSound.IsPlaying then
		windSound.Volume = 0
		windSound:Stop()
	end
end

local function stopWind()
	fastTime = 0
	windVolume = 0
	windSound.Volume = 0
	windSound:Stop()
end

-- Wind while the wreck tumbles: no delay, follows fall speed, extra buffeting
local function tumbleWind(dt, speed)
	local strength = math.clamp(speed / (SPEED * WIND_SPEED_THRESHOLD), 0, 1.2)
	local buffet = 1 + math.noise(os.clock() * 3, 7.1) * 0.6
	local target = WIND_VOLUME * strength * buffet
	windVolume += (target - windVolume) * (1 - math.exp(-8 * dt))
	if windVolume > 0.01 then
		if not windSound.IsPlaying then windSound:Play() end
		windSound.Volume = windVolume
		windSound.PlaybackSpeed = 0.95 + math.clamp(speed / SPEED, 0, 1) * 0.15
	elseif windSound.IsPlaying then
		windSound.Volume = 0
		windSound:Stop()
	end
end

local function getCharacter()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, root
end

-- Finds your drone in workspace.Drones (works with StreamingEnabled)
local function findMyDrone()
	if not player:GetAttribute("HasDrone") then return nil end
	local folder = workspace:FindFirstChild("Drones")
	return folder and folder:FindFirstChild(player.Name .. "_Drone")
end

local function getBody()
	return drone and drone.Parent and (drone.PrimaryPart or drone:FindFirstChild("Body"))
end

local function getCamPart()
	return drone and drone:FindFirstChild("DroneCamera", true)
end

-- Raycast from the mouse, skipping invisible / non-collidable parts
local function mouseRaycast()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	local ignore = { player.Character, workspace:FindFirstChild("Drones") }
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	for _ = 1, 20 do
		params.FilterDescendantsInstances = ignore
		local result = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
		local part = result and result.Instance
		if part and part ~= workspace.Terrain and (part.Transparency >= 0.95 or not part.CanCollide) then
			table.insert(ignore, part)
		else
			return result
		end
	end
	return nil
end

local function key(k)
	return UserInputService:IsKeyDown(k) and 1 or 0
end

-- First person hides your head/body (Roblox does that when the camera is inside your
-- head, every frame). While you look through the drone, undo that so you can see yourself.
local function showMyCharacter()
	local myChar = player.Character
	if not myChar then return end
	for _, part in ipairs(myChar:GetDescendants()) do
		if part:IsA("BasePart") and part.LocalTransparencyModifier ~= 0 then
			part.LocalTransparencyModifier = 0
		end
	end
end

-- Freeze the character while flying ------------------------------------------
local savedWalk, savedJumpPower, savedJumpHeight, savedAutoRotate
local FREEZE_ACTION = "DroneFreezeCharacter"
local function freezeCharacter(on)
	local _, hum = getCharacter()
	if on then
		ContextActionService:BindActionAtPriority(FREEZE_ACTION, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value + 1,
		Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump,
		Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
		Enum.KeyCode.Space, Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
		-- the drone's up/down keys, plus SPH sprint / lean / stance keys, so flying
		-- doesn't make your character sprint, lean or change stance
		Enum.KeyCode.LeftShift, Enum.KeyCode.Q, Enum.KeyCode.E,
		Enum.KeyCode.C, Enum.KeyCode.X, Enum.KeyCode.Z, Enum.KeyCode.LeftControl)
		if hum then
			savedWalk, savedJumpPower, savedJumpHeight, savedAutoRotate =
				hum.WalkSpeed, hum.JumpPower, hum.JumpHeight, hum.AutoRotate
			hum.WalkSpeed = 0
			hum.JumpPower = 0
			hum.JumpHeight = 0
			hum.AutoRotate = false
			hum:Move(Vector3.zero)
		end
	else
		ContextActionService:UnbindAction(FREEZE_ACTION)
		if hum and savedWalk then
			hum.WalkSpeed = savedWalk
			hum.JumpPower = savedJumpPower
			hum.JumpHeight = savedJumpHeight
			hum.AutoRotate = savedAutoRotate
		end
		savedWalk = nil
	end
end

-- Zoom ------------------------------------------------------------------------
local function setZoomBlur(size)
	if size <= 0.05 then
		if zoomBlur then zoomBlur.Enabled = false end
		return
	end
	if not zoomBlur or not zoomBlur.Parent then
		zoomBlur = Instance.new("BlurEffect")
		zoomBlur.Name = "DroneZoomBlur"
		zoomBlur.Parent = Lighting -- client-side, only you see it
	end
	zoomBlur.Enabled = true
	zoomBlur.Size = size
end

local function resetZoom()
	zoomIndex = 1
	zoom = 1
	refocus = 0
	refocusStrength = 0
	if zoomBlur then
		zoomBlur:Destroy()
		zoomBlur = nil
	end
end

UserInputService.InputChanged:Connect(function(input)
	if not piloting or input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
	local dir = input.Position.Z > 0 and 1 or -1
	local newIndex = math.clamp(zoomIndex + dir, 1, #ZOOM_LEVELS)
	if newIndex ~= zoomIndex then
		zoomIndex = newIndex
		-- How big is this jump, from where the lens is RIGHT NOW to the new target?
		-- 1x->1.5x is a small nudge; 1x->8x is the whole range.
		local fullRange = math.log(ZOOM_LEVELS[#ZOOM_LEVELS] / ZOOM_LEVELS[1])
		local jump = math.clamp(math.abs(math.log(ZOOM_LEVELS[newIndex] / zoom)) / fullRange, 0, 1)
		-- stack with any focus hunt that's still going (fast scrolling = bigger blur)
		local current = refocus * refocusStrength
		refocusStrength = math.max(jump, current)
		refocusDuration = REFOCUS_TIME * (0.35 + 0.65 * refocusStrength)
		refocus = 1 -- lose focus, then hunt back in
	end
end)

-- Piloting --------------------------------------------------------------------
-- The drone is anchored and moved with CFrames every frame, so it's perfectly
-- smooth on your screen (no physics / network jitter).

local crashDrone -- defined below

local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude

-- Measure a collision box that fits the drone's visible parts (arms, rotors, legs...).
-- It's world-aligned and square from above, sized to the drone's widest reach, so
-- turning never swings a corner into a wall. The DroneSound part and invisible parts
-- don't count. The box starts just clear of the floor, so the first cast can't begin
-- "inside" the ground (casts ignore anything they start inside - that's how the
-- drone used to slip through things).
local function measureCollision(model)
	local pivot = model:GetPivot().Position
	local reach, minY, maxY = 0, math.huge, -math.huge
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 and part.Name ~= "DroneSound" then
			local half = part.Size / 2
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = part.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
						local rel = corner - pivot
						reach = math.max(reach, Vector3.new(rel.X, 0, rel.Z).Magnitude)
						minY = math.min(minY, rel.Y)
						maxY = math.max(maxY, rel.Y)
					end
				end
			end
		end
	end
	if minY == math.huge then return end
	-- square footprint a bit inside the full diagonal reach (so it isn't overly fat)
	local side = math.max(reach * 2 * 0.85, 0.5)
	local height = math.max(maxY - minY, 0.3)
	-- lift the bottom slightly so a drone resting on the floor isn't touching it
	colSize = Vector3.new(side, height - 0.04, side)
	colOffset = Vector3.new(0, (maxY + minY) / 2 + 0.02, 0)
end

-- Moves pos by delta, stopping at walls/floors and sliding along them
local function moveWithCollision(pos, delta)
	castParams.FilterDescendantsInstances = { player.Character, workspace:FindFirstChild("Drones") }
	for _ = 1, 3 do
		if delta.Magnitude < 1e-4 then break end
		local hit = workspace:Blockcast(CFrame.new(pos + colOffset), colSize, delta, castParams)
		if not hit then
			pos += delta
			break
		end
		local dir = delta.Unit
		local travel = math.max(hit.Distance - COLLISION_SKIN, 0)
		pos += dir * travel
		local remaining = delta - dir * travel
		delta = remaining - hit.Normal * remaining:Dot(hit.Normal)
		local into = currentVel:Dot(hit.Normal)
		if into < 0 then
			-- Hard enough to crash? (floors get a higher limit so landing is fine)
			local limit = hit.Normal.Y > 0.7 and GROUND_CRASH_SPEED or SPEED * CRASH_SPEED
			if -into >= limit and not pendingCrash then
				pendingCrash = currentVel
			end
			currentVel -= hit.Normal * into
		end
	end
	return pos
end

local function setCamPartHidden(hidden)
	local camPart = getCamPart()
	if camPart then
		camPart.LocalTransparencyModifier = hidden and 1 or 0
	end
end

local function endFlight(tellServer)
	if not flying then return end
	flying = false
	RunService:UnbindFromRenderStep("DroneFlight")
	if drone and drone.Parent then
		local levelCF = CFrame.new(dronePos) * CFrame.Angles(0, yaw, 0)
		drone:PivotTo(levelCF)
		if tellServer ~= false then
			remote:FireServer("Pilot", false, levelCF)
		end
	end
end

local function stopPilot(tellServer)
	if not piloting then return end
	piloting = false
	pcall(function() RunService:UnbindFromRenderStep("DroneCrashCam") end)

	local _, hum = getCharacter()
	camera.CameraType = Enum.CameraType.Custom
	if hum then camera.CameraSubject = hum end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	freezeCharacter(false)
	local char = player.Character
	if char then char:SetAttribute("DroneView", false) end
	stopWind()
	setCamPartHidden(false)
	HUD.hide()
	camera.FieldOfView = baseFOV
	resetZoom()

	if tellServer == false then
		endFlight(false) -- drone is gone / you died: stop immediately
	else
		settleTime = 0 -- let it glide to a stop and level out, then endFlight
	end
end

-- Crash: drone stops being flown, the server drops the wreck, the feed cuts to static,
-- and then the tool is taken away.
-- The feed dying (used for wall crashes AND a dead battery)
local function crashFeed(reason)
	if crashed then return end
	local message = "DRONE DESTROYED" -- same message whether it hit something or the battery died
	crashed = true
	flying = false
	RunService:UnbindFromRenderStep("DroneFlight")
	setZoomBlur(0)
	if piloting then
		HUD.signalLost(CRASH_STATIC_TIME)
		-- Keep the camera bolted to the drone's camera part so you ride the tumble,
		-- with wind rushing past as it falls (wind stops in stopPilot)
		local lastPos = nil
		local tumbleSpeed = currentVel.Magnitude -- carry on from how fast we were going
		RunService:BindToRenderStep("DroneCrashCam", Enum.RenderPriority.Camera.Value + 1, function(dt)
			local body = getBody()
			if not body then return end
			local camPart = getCamPart()
			local camPos = camPart and camPart.Position or body.Position
			camera.CFrame = CFrame.new(camPos) * drone:GetPivot().Rotation * CFrame.Angles(pitch, 0, 0)
			showMyCharacter()

			-- how fast is the wreck moving (estimated from its position, smoothed)
			if lastPos and dt > 0 then
				local raw = (body.Position - lastPos).Magnitude / dt
				tumbleSpeed += (math.min(raw, SPEED * 3) - tumbleSpeed) * smooth(8, dt)
			end
			lastPos = body.Position
			tumbleWind(dt, tumbleSpeed)
		end)
		task.delay(CRASH_STATIC_TIME, function()
			stopPilot(false)
			task.spawn(notify, message, "error", "SIGNAL LOST") -- after the static, so the HUD isn't covering it
		end)
	else
		stopWind()
		task.spawn(notify, message, "error", "SIGNAL LOST")
	end
end

crashDrone = function(impactVel, droneCF)
	if crashed then return end
	remote:FireServer("Crash", droneCF, impactVel)
	crashFeed("impact")
end

local function update(dt)
	local body = getBody()
	if not body then
		stopPilot(false)
		endFlight(false)
		return
	end

	flightTime += dt
	local fwd, right, up = 0, 0, 0

	if piloting then
		-- Smoothed mouse look
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		local delta = UserInputService:GetMouseDelta()
		local sens = MOUSE_SENSITIVITY / zoom -- slower turning when zoomed in
		targetYaw -= delta.X * sens
		targetPitch = math.clamp(targetPitch - delta.Y * sens, -1.3, 1.3)

		if spoolLeft <= 0 then
			fwd = key(Enum.KeyCode.W) - key(Enum.KeyCode.S)
			right = key(Enum.KeyCode.D) - key(Enum.KeyCode.A)
			up = math.clamp(key(Enum.KeyCode.Space) + key(Enum.KeyCode.E), 0, 1)
			- math.clamp(key(Enum.KeyCode.LeftShift) + key(Enum.KeyCode.Q), 0, 1)
		end
	end

	-- Raw mouse look (no smoothing - your camera scripts handle that)
	local prevYaw = yaw
	yaw = targetYaw
	pitch = targetPitch

	-- How fast we're turning (used to bank into turns)
	local yawRate = (yaw - prevYaw) / math.max(dt, 1 / 240)
	turnRate += (yawRate - turnRate) * smooth(8, dt)

	local yawCF = CFrame.Angles(0, yaw, 0)

	local wish = yawCF.LookVector * fwd + yawCF.RightVector * right
	if wish.Magnitude > 0 then
		wish = wish.Unit * SPEED
	end
	wish += Vector3.new(0, up * VERTICAL_SPEED, 0)

	-- Engine start: can't move until it has spooled up
	if spoolLeft > 0 then
		spoolLeft -= dt
		wish = Vector3.zero
	end

	-- Range limit
	local _, _, root = getCharacter()
	if root then
		local offset = dronePos - root.Position
		if offset.Magnitude > MAX_RANGE then
			local outward = offset.Unit
			local outSpeed = wish:Dot(outward)
			if outSpeed > 0 then
				wish -= outward * outSpeed
			end
		end
	end

	-- Smoothed velocity (eases in and out), then move with collisions
	currentVel = currentVel:Lerp(wish, smooth(ACCELERATION, dt))
	-- wind only while you're actually pushing the drone (not while it coasts to a stop)
	updateWind(dt, piloting and (fwd ~= 0 or right ~= 0))
	dronePos = moveWithCollision(dronePos, currentVel * dt)

	-- Turns to face where you look, leans into movement, banks into turns
	local localVel = yawCF:VectorToObjectSpace(currentVel)
	local pitchLean = (localVel.Z / SPEED) * TILT_AMOUNT
	local rollLean = (-localVel.X / SPEED) * TILT_AMOUNT
		+ math.clamp(turnRate * BANK_AMOUNT, -MAX_BANK, MAX_BANK)
	lean = lean:Lerp(CFrame.Angles(pitchLean, 0, rollLean), smooth(8, dt))

	local droneCF = CFrame.new(dronePos) * yawCF * lean
	drone:PivotTo(droneCF)

	if pendingCrash then
		local impact = pendingCrash
		pendingCrash = nil
		crashDrone(impact, droneCF)
		return
	end

	-- Tell the server (for other players) ~30x a second
	sendTimer += dt
	if sendTimer >= 1 / SEND_RATE then
		sendTimer = 0
		moveRemote:FireServer(droneCF)
	end

	if piloting then
		-- Camera sits at the DroneCamera part and leans a bit with the drone
		local camPart = getCamPart()
		local camPos = camPart and camPart.Position or (dronePos + yawCF.LookVector * (body.Size.Z / 2 + 0.5))
		local camLean = CFrame.new():Lerp(lean, CAMERA_TILT_FOLLOW)
		camera.CFrame = CFrame.new(camPos) * yawCF * camLean * CFrame.Angles(pitch, 0, 0)

		-- Zoom: glide to the target level (true optical zoom: FOV from the tangent)
		local targetZoom = ZOOM_LEVELS[zoomIndex]
		zoom += (targetZoom - zoom) * smooth(ZOOM_SMOOTHING, dt)
		camera.FieldOfView = math.deg(2 * math.atan(math.tan(math.rad(baseFOV) / 2) / zoom))

		-- Refocus blur: blurry while the lens moves, then it "hunts" back into focus
		-- (both parts scale with how far the zoom is actually moving)
		local fullRange = math.log(ZOOM_LEVELS[#ZOOM_LEVELS] / ZOOM_LEVELS[1])
		local remaining = math.abs(math.log(targetZoom / zoom)) / fullRange
		local moving = math.clamp(remaining * 1.5, 0, 1)
		if remaining < 0.02 then
			refocus = math.max(refocus - dt / refocusDuration, 0)
		end
		local hunt = refocusStrength * refocus * (0.55 + 0.45 * math.abs(math.sin(refocus * math.pi * 2.5)))
		setZoomBlur(REFOCUS_BLUR * math.max(moving, hunt))

		showMyCharacter()

		HUD.update(dt, {
			dronePos = dronePos,
			velocity = currentVel,
			operatorPos = root and root.Position or dronePos,
			maxRange = MAX_RANGE,
			flightTime = flightTime,
			battery = tool:GetAttribute("Battery") or 100,
			zoom = zoom,
			nfov = zoom >= NFOV_AT,
			ignore = { player.Character, workspace:FindFirstChild("Drones") },
		})
	else
		-- Settling after you stopped flying
		settleTime += dt
		local _, leanAngle = lean:ToAxisAngle()
		if (currentVel.Magnitude < 0.3 and math.abs(leanAngle) < 0.02) or settleTime > 2 then
			endFlight(true)
		end
	end
end

local function startPilot()
	local body = getBody()
	if piloting or not body then return end
	piloting = true

	if not flying then
		-- Fresh start from where the drone is hovering
		local pivot = drone:GetPivot()
		local _, y, _ = pivot:ToEulerAnglesYXZ()
		dronePos = pivot.Position
		targetYaw, yaw = y, y
		turnRate = 0
		currentVel = Vector3.zero
		lean = CFrame.new()
		sendTimer = 0
		flying = true
		measureCollision(drone)
		-- First flight since deploying: engine is off, so it has to spool up first
		spoolLeft = (drone:GetAttribute("EngineOn") ~= true) and ENGINE_SPOOL_TIME or 0
		remote:FireServer("Pilot", true)
		-- Runs right after the default camera so nothing overwrites our drone view
		RunService:BindToRenderStep("DroneFlight", Enum.RenderPriority.Camera.Value + 1, update)
	end
	-- (if it was still settling, we just take control again)

	targetPitch, pitch = 0, 0

	freezeCharacter(true)
	-- Tells SPH's CharacterMovement you're in the drone: it drops your held movement
	-- keys and stops turning the character to face the (drone) camera
	local char = player.Character
	if char then char:SetAttribute("DroneView", true) end
	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseIconEnabled = false
	setCamPartHidden(true) -- so the camera part itself doesn't block your view
	baseFOV = camera.FieldOfView
	resetZoom()
	HUD.show()
end

-- Other players' drones: glide smoothly to the positions the server sends ----
local othersTarget = setmetatable({}, { __mode = "k" }) -- [model] = CFrame

moveRemote.OnClientEvent:Connect(function(model, cf)
	if model and model ~= drone then
		othersTarget[model] = cf
	end
end)

RunService.RenderStepped:Connect(function(dt)
	for model, target in pairs(othersTarget) do
		if not model.Parent or not model:GetAttribute("Flying") then
			othersTarget[model] = nil
		else
			model:PivotTo(model:GetPivot():Lerp(target, smooth(OTHERS_SMOOTHING, dt)))
		end
	end
end)

-- Spinning rotors + motor sound (for every drone in the game) ---------------
-- The DroneHum_Near / _Distant / _Echo layers live in the DroneSound part (made by the server, so everyone
-- hears it in 3D). Each client shapes its pitch/volume locally from the drone's movement.
local rotorData = setmetatable({}, { __mode = "k" })

RunService.PreSimulation:Connect(function(dt)
	local folder = workspace:FindFirstChild("Drones")
	if not folder or dt <= 0 then return end
	local now = os.clock()

	for _, model in ipairs(folder:GetChildren()) do
		local data = rotorData[model]
		if not data then
			data = {
				motors = {}, nextScan = 0, angle = 0, speed = 0,
				lastPos = model:GetPivot().Position, vel = Vector3.zero,
				prevSpeed = 0, pitch = HUM_IDLE_PITCH, volume = 0,
			}
			rotorData[model] = data
		end

		-- (Re)find rotors + sound until they've streamed in
		if (#data.motors == 0 or not data.sound) and now >= data.nextScan then
			data.nextScan = now + 1
			table.clear(data.motors)
			for _, m in ipairs(model:GetDescendants()) do
				if m:IsA("Motor6D") and m.Name == "RotorMotor" then
					table.insert(data.motors, m)
				end
			end
			data.layers = {}
			for _, snd in ipairs(model:GetDescendants()) do
				if snd:IsA("Sound") and snd:GetAttribute("DroneLayerVolume") then
					table.insert(data.layers, snd)
				end
			end
			data.sound = data.layers[1]
		end

		-- How is this drone moving?
		local pos = model:GetPivot().Position
		local isMine = (model == drone and flying)
		local vel
		if isMine then
			vel = currentVel
		else
			-- estimate from how far it moved this frame (smoothed)
			local raw = (pos - data.lastPos) / dt
			if raw.Magnitude > SPEED * 3 then raw = data.vel end -- ignore teleports
			data.vel = data.vel:Lerp(raw, smooth(6, dt))
			vel = data.vel
		end
		data.lastPos = pos

		local isFlying = isMine or model:GetAttribute("Flying") == true
		local speed = vel.Magnitude
		local speed01 = math.clamp(speed / SPEED, 0, 1)
		local climb = math.clamp(vel.Y / VERTICAL_SPEED, -1, 1)
		local accel = (speed - data.prevSpeed) / dt
		data.prevSpeed = speed

		-- Rotors
		local isCrashed = model:GetAttribute("Crashed") == true
		-- engine is off until the first flight (your own drone counts as on the moment you fly)
		local engineOn = (isMine or model:GetAttribute("EngineOn") ~= false) and not isCrashed
		local target = ROTOR_IDLE_SPEED
		if isCrashed or not engineOn then
			target = 0 -- dead / switched-off motors: still
		elseif isFlying then
			target = ROTOR_FLY_SPEED + speed * 1.0
		end
		data.speed += (target - data.speed) * smooth(isCrashed and 5 or 3, dt)
		data.angle = (data.angle + data.speed * dt) % (math.pi * 2)
		for i, motor in ipairs(data.motors) do
			local dir = (i % 2 == 0) and 1 or -1 -- neighbours spin opposite ways
			motor.Transform = CFrame.Angles(0, data.angle * dir, 0) -- spin around the drone's up axis
		end

		-- Motor sound: higher + louder when fast, strains when climbing/accelerating,
		-- relaxes when dropping
		-- Crashed: engine sound winds down over CRASH_SOUND_FADE (volume + pitch drop)
		if isCrashed and data.layers and #data.layers > 0 then
			if not data.crashT then
				data.crashT = 0
				data.crashVolume = data.volume
				data.crashPitch = data.pitch
			end
			data.crashT += dt
			local a = math.clamp(data.crashT / CRASH_SOUND_FADE, 0, 1)
			for _, snd in ipairs(data.layers) do
				if snd.Parent then
					snd.Volume = data.crashVolume * (1 - a) * (snd:GetAttribute("DroneLayerVolume") or 1)
					snd.PlaybackSpeed = data.crashPitch * (1 - 0.3 * a)
				end
			end
		end

		-- Engine off: silent, and parked at a low pitch so switching on spools UP from it
		if not isCrashed and not engineOn and data.layers then
			data.volume = 0
			data.pitch = 0.4
			for _, snd in ipairs(data.layers) do
				if snd.Parent then snd.Volume = 0 end
			end
		end

		if engineOn and data.layers and #data.layers > 0 then
			local wantPitch, wantVolume = HUM_IDLE_PITCH, HUM_IDLE_VOLUME
			if isFlying then
				wantPitch = HUM_FLY_PITCH + speed01 * HUM_SPEED_PITCH
					+ climb * HUM_CLIMB_PITCH
					+ math.clamp(accel / 80, -0.05, 0.12)
				wantVolume = HUM_FLY_VOLUME + speed01 * HUM_SPEED_VOLUME + math.max(climb, 0) * 0.1
			end
			if isMine and piloting then
				wantVolume *= HUM_PILOT_VOLUME -- camera's right on the drone, so tone it down for you
			end
			-- spooling up from off is a bit slower than normal pitch changes
			local pitchRate = data.pitch < HUM_IDLE_PITCH * 0.95 and 2.5 or 4
			data.pitch += (wantPitch - data.pitch) * smooth(pitchRate, dt)
			data.volume += (wantVolume - data.volume) * smooth(4, dt)
			-- Every layer follows the same pitch; each keeps its own share of the volume.
			-- The distance mix happens by itself through each layer's rolloff.
			for _, snd in ipairs(data.layers) do
				if snd.Parent then
					snd.PlaybackSpeed = data.pitch
					snd.Volume = data.volume * (snd:GetAttribute("DroneLayerVolume") or 1)
				end
			end
		end
	end
end)

-- Hover to pick up -------------------------------------------------------------
-- While the tool is out and you're not flying, hovering your own drone highlights it;
-- clicking it picks it up (if you're close enough).
local hoverHighlight = Instance.new("Highlight")
hoverHighlight.Name = "DroneHover"
hoverHighlight.FillColor = Color3.fromRGB(255, 255, 255)
hoverHighlight.FillTransparency = 0.75
hoverHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
hoverHighlight.OutlineTransparency = 0
hoverHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
hoverHighlight.Enabled = false
hoverHighlight.Parent = player:WaitForChild("PlayerGui") -- local only

local getHoverParts -- defined below
local hoverParams = RaycastParams.new()
hoverParams.FilterType = Enum.RaycastFilterType.Include

-- Helper parts that aren't really "the drone": never hoverable, never highlighted
local IGNORE_PARTS = { DroneSound = true }

-- The drone's real, visible parts (cached per model)
local hoverPartsCache = setmetatable({}, { __mode = "k" })
getHoverParts = function(model)
	local cached = hoverPartsCache[model]
	if cached and #cached > 0 then return cached end
	local parts = {}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			if IGNORE_PARTS[p.Name] then
				p.LocalTransparencyModifier = 1 -- hidden on your screen, so the highlight skips it
			elseif p.Transparency < 1 then
				table.insert(parts, p)
			end
		end
	end
	hoverPartsCache[model] = parts
	return parts
end

-- Is the mouse over MY drone right now? (only while it's idle - not flown, not settling)
local function hoveringMyDrone()
	if crashed or piloting or flying then return false end
	local myDrone = findMyDrone()
	if not myDrone then return false end
	drone = myDrone
	local mousePos = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	hoverParams.FilterDescendantsInstances = getHoverParts(myDrone)
	return workspace:Raycast(ray.Origin, ray.Direction * 1000, hoverParams) ~= nil
end

local CAN_PICKUP_COLOR = Color3.fromRGB(90, 230, 120)   -- green: close enough, click to pick up
local CANT_PICKUP_COLOR = Color3.fromRGB(235, 70, 70)   -- red: too far away

RunService.RenderStepped:Connect(function()
	local equipped = tool.Parent == player.Character
	local hovering = equipped and hoveringMyDrone()
	hoverHighlight.Adornee = hovering and drone or nil
	hoverHighlight.Enabled = hovering
	if hovering then
		local _, _, root = getCharacter()
		local inRange = root and (drone:GetPivot().Position - root.Position).Magnitude <= PICKUP_RANGE
		local color = inRange and CAN_PICKUP_COLOR or CANT_PICKUP_COLOR
		hoverHighlight.OutlineColor = color
		hoverHighlight.FillColor = color
	end
end)

-- Tool ------------------------------------------------------------------------
tool.Activated:Connect(function()
	if crashed then return end
	if piloting then
		stopPilot()
		return
	end

	-- Clicking your (highlighted) drone picks it up
	if hoveringMyDrone() then
		local _, _, root = getCharacter()
		if root and (drone:GetPivot().Position - root.Position).Magnitude <= PICKUP_RANGE then
			remote:FireServer("PickUp")
		else
			task.spawn(notify, "PICKUP OUT OF RANGE", "error", "CANNOT PICK UP")
		end
		return
	end

	drone = findMyDrone()

	if player:GetAttribute("HasDrone") then
		if not getBody() then
			warn("[Drone] Drone hasn't loaded on your screen yet, try again in a sec")
			return
		end
		-- Drone is out: any click starts flying
		startPilot()
		return
	end

	-- No drone yet: clicking the floor deploys it
	local result = mouseRaycast()
	if result and result.Normal.Y >= FLOOR_NORMAL_Y then
		local _, _, root = getCharacter()
		if root and (result.Position - root.Position).Magnitude > DEPLOY_RANGE then
			task.spawn(notify, "DEPLOYMENT OUT OF RANGE", "error", "CANNOT DEPLOY")
			return
		end
		if root then
			if (tool:GetAttribute("Battery") or 100) < 5 then
				task.spawn(notify, "BATTERY TOO LOW TO DEPLOY", "warning", "CANNOT DEPLOY")
				return
			end
			remote:FireServer("Deploy", result.Position)
		end
	end
end)

tool.Unequipped:Connect(function()
	stopPilot()
end)

remote.OnClientEvent:Connect(function(action, model, reason)
	if action == "Deployed" then
		flightTime = 0
		-- New airframe, new sensor: the last drone's dead pixels die with it.
		pcall(HUD.resetSensor)
		drone = findMyDrone() or model
		task.spawn(notify, "DRONE DEPLOYED", "success")
	elseif action == "Crashed" then
		crashFeed(reason or model) -- e.g. battery died (no-op if we already crashed into something)
	elseif action == "Recovered" then
		task.spawn(notify, "DRONE RECOVERED", "success")
	elseif action == "PickedUp" then
		stopPilot(false)
		endFlight(false)
		drone = nil
	end
end)

-- Safety: if the tool gets removed mid-flight, put everything back (camera, lighting, HUD)
tool.AncestryChanged:Connect(function()
	if not tool:IsDescendantOf(game) then
		stopPilot(false)
		endFlight(false)
		windSound:Destroy()
		hoverHighlight:Destroy()
	end
end)

-- Safety: put the camera back if you die mid-flight
local char = player.Character or player.CharacterAdded:Wait()
char:WaitForChild("Humanoid").Died:Connect(function()
	stopPilot(false)
	endFlight(false)
	drone = nil
end)
