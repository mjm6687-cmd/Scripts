local debugMode = false

local players = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local tweenService = game:GetService("TweenService")
local runService = game:GetService("RunService")
local debris = game:GetService("Debris")
local httpService = game:GetService("HttpService")
local assets = replicatedStorage.SPH_Assets
local animations = assets.Animations
local modules = assets.Modules

local localPlayer = players.LocalPlayer

local config = require(assets.GameConfig)
local warnPrefix = "[ SPH ] "
print(warnPrefix.."Loading Client "..config.version)
local hitFX = require(modules.HitFX)
local shellEjection = require(modules.ShellEjection)
local bulletHandler = require(modules.BulletHandler)
local lensFlare = require(modules.LensFlare)

local bridgeNet = require(replicatedStorage.SPH_Assets.Modules.BridgeNet)
local bodyAnimCommand = bridgeNet.CreateBridge("BodyAnimCommand")
local repFire = bridgeNet.CreateBridge("ReplicateFire")
local repSound = bridgeNet.CreateBridge("ReplicateSound")
local repHit = bridgeNet.CreateBridge("ReplicateHit")
local repBolt = bridgeNet.CreateBridge("ReplicateBolt")
local repToggleAttachment = bridgeNet.CreateBridge("ReplicateToggleAttachment")
local repMagGrab = bridgeNet.CreateBridge("ReplicateMagGrab")
local repLean = bridgeNet.CreateBridge("ReplicateLean")
local repFlipMag = bridgeNet.CreateBridge("ReplicateFlipMagnifier")
local repEjectShell = bridgeNet.CreateBridge("ReplicateEjectShell")
local magnifierMod = require(modules.MagnifierSystem)

-- [Drone] Night vision can come from the goggles OR the Recon Drone's NV mode; the
-- drone's thermal modes also count for hiding lens flares (but can't see IR).
local function viewerHasNV()
	return localPlayer:GetAttribute("NightVisionActive") == true
		or localPlayer:GetAttribute("DroneNightVision") == true
end
local function flaresHidden()
	return viewerHasNV() or localPlayer:GetAttribute("DroneThermal") == true
end

local animLoadStorage = {}
local lasers = {}
-- Every other player's flashlight currently switched on. Tracked like `lasers` so the
-- render loop can reveal/hide IR illuminators live as THIS viewer's night vision changes.
local flashlights = {}
local FLASH_COLOR = Color3.fromRGB(255, 255, 255) -- flashlight + its emitter glow are always white

-- COLOR-ONLY EMITTER SWITCHING
-- Flipping Transparency (or Material) on a neon part forces the engine to rebuild it,
-- which is what made toggling laggy. Both emitter parts (Grip.LaserPart /
-- Grip.FlashPart) stay permanently Neon and visible at Transparency 0 and only change
-- COLOR. Off = 55,55,55 (dark unlit emitter); on = 255,255,255 for the flashlight, or
-- the laser's own color for the laser. An IR laser or IR illuminator always shows the
-- off color -- there's nothing visible to emit.
-- IMPORTANT: set both parts to Transparency 0 in Studio on every gun model.
local EMITTER_OFF_COLOR    = Color3.fromRGB(55, 55, 55)
local LASER_PART_OFF_COLOR = EMITTER_OFF_COLOR
local FLASH_PART_OFF_COLOR = EMITTER_OFF_COLOR

-- Force an emitter part to Neon once (guarded so we don't rebuild it on every toggle).
local function EnsureNeon(part)
	if part and part:IsA("BasePart") and part.Material ~= Enum.Material.Neon then
		part.Material = Enum.Material.Neon
	end
end

local function AddRig(rig:Model, name:string)
	local newData = {
		animator = rig.AnimationController.Animator,
		LoadedAnimations = {}
	}
	animLoadStorage[name] = newData
end

local function FireBullet(player:Player, firePoint:CFrame, tracer:boolean)
	local tool = player.Character:FindFirstChildWhichIsA("Tool")
	if tool and tool:FindFirstChild("SPH_Weapon") then
		local rig = player.Character.WeaponRig
		local gunModel = rig.Weapon:FindFirstChildWhichIsA("Model")
		local wepStats = require(tool.SPH_Weapon.WeaponStats)
		local muzzle = gunModel.Grip.Muzzle
		local gunAmmo = tool.Ammo

		-- Speed of sound
		local soundDelay
		if config.speedOfSound then
			local distance = localPlayer:DistanceFromCharacter(firePoint.Position) / config.meterMultiplier -- Get distance to the sound origin in Meters
			if distance > 0 then -- 0 is returned if the function fails to work.
				soundDelay = distance / 343
			end
		end 

		-- Fire effects
		bulletHandler.FireFX(player, gunModel, "Muzzle", wepStats.muzzleChance, soundDelay)

		-- Fire bullet
		if gunModel and gunModel.Parent and gunModel:FindFirstChild("Grip") then
			local muzzle = gunModel.Grip.Muzzle
			local bulletOrigin = muzzle.WorldCFrame.Position
			local bulletDirection = muzzle.WorldCFrame.LookVector
			local bulletVelocity = (bulletDirection * wepStats.muzzleVelocity * config.meterMultiplier) -- 1 Meter = ~3.5 Studs (According to the dev forum)

			local tracerColor = nil
			if wepStats.tracers and gunAmmo.MagAmmo.Value % wepStats.tracerTiming == 0 then
				tracerColor = wepStats.tracerColor
			end

			bulletHandler.FireBullet(rig,bulletOrigin,bulletDirection,bulletVelocity,tool,player,tracerColor,true)

			-- Shell ejection is NOT done here any more. Driving it off the fire event meant
			-- manual-action guns (bolt, pump) never dropped brass for anyone but the shooter,
			-- because their casing leaves on the bolt cycle, not on the shot. The shooter's
			-- client now tells us exactly when it ejected, via ReplicateEjectShell below.
		end
	end 
end

-- Update character stuff
bodyAnimCommand:Connect(function(character:Model, angle)
	-- A creature's neck is not a human neck: this C1 is built for a human head and
	-- sinks a creature's head into its torso. Its head is aimed by the creature's
	-- own Head system instead. (The server also stops relaying these for
	-- creatures; this is the second lock on the same door.)
	if not character or character:GetAttribute("IsCreature") == true then return end
	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 or (not character:FindFirstChild("Torso") and not character:FindFirstChild("UpperTorso")) then return end

	-- Head movement
	local avatarType = character.Humanoid.RigType
	local joint
	if avatarType == Enum.HumanoidRigType.R6 then
		joint = character.Torso.Neck
	else
		joint = character.UpperTorso.Neck
	end

	local moveSpeed = config.replicatedHeadRotationSpeed

	tweenService:Create(joint,TweenInfo.new(moveSpeed,Enum.EasingStyle.Quad),{C1 = angle}):Play()
end)

-- Cache each remote character's resting hip C0 so the leg counter-rotation is
-- always computed from the true rest pose (not a mid-lean pose).
local hipBaseCache: {[Model]: {left: CFrame, right: CFrame}} = {}

repLean:Connect(function(character:Model, leanDirection)
	if not character:FindFirstChild("HumanoidRootPart") then return end

	local LEAN_ANGLE = config.leanBodyAngle or 17
	local HIP_COUNTER_SIGN = config.leanHipCounterSign or 1
	local PIVOT_H = config.leanPivotHeight or 1.2
	local LEAN_BASE = CFrame.Angles(math.rad(90), math.rad(180), 0)

	-- One unified lean transform, applied identically to the torso joint and both
	-- hips so the legs stay planted while the upper body leans + shifts over them.
	local leanRad = math.rad(LEAN_ANGLE * leanDirection * HIP_COUNTER_SIGN)
	local pivot = CFrame.new(0, -PIVOT_H, 0)
	local Linv = pivot * CFrame.Angles(0, 0, leanRad) * pivot:Inverse()

	-- Torso
	local baseJoint = character.HumanoidRootPart:FindFirstChild("RootJoint")
	if baseJoint then
		tweenService:Create(baseJoint,TweenInfo.new(0.5),{C1 = Linv * LEAN_BASE}):Play()
	end

	-- Hips (counter so legs stay planted)
	local torso = character:FindFirstChild("Torso")
	local leftHip = torso and torso:FindFirstChild("Left Hip")
	local rightHip = torso and torso:FindFirstChild("Right Hip")
	if leftHip and rightHip then
		local cache = hipBaseCache[character]
		if not cache then
			cache = { left = leftHip.C0, right = rightHip.C0 }
			hipBaseCache[character] = cache
			character.AncestryChanged:Connect(function()
				if not character:IsDescendantOf(game) then hipBaseCache[character] = nil end
			end)
		end
		tweenService:Create(leftHip, TweenInfo.new(0.5), { C0 = Linv * cache.left }):Play()
		tweenService:Create(rightHip, TweenInfo.new(0.5), { C0 = Linv * cache.right }):Play()
	end
end)

-- Someone else flipped their magnifier. Tweened rather than looped: this is a
-- once-in-a-while joint move on another player's gun, so a per-frame drive would be
-- wasted work. PoseFor is MagnifierSystem's stateless helper -- it works out the joint
-- and its target C0 from that gun's own rig, so the pose math lives in one place and
-- the module's own state (the local player's magnifier) is never touched.
repFlipMag:Connect(function(character:Model, flipped:boolean)
	local rig = character and character:FindFirstChild("WeaponRig")
	local gunModel = rig and rig:FindFirstChild("Weapon") and rig.Weapon:FindFirstChildWhichIsA("Model")
	local tool = character and character:FindFirstChildWhichIsA("Tool")
	if not gunModel or not tool or not tool:FindFirstChild("SPH_Weapon") then return end

	local magCfg = require(tool.SPH_Weapon.WeaponStats).magnifier
	if not magCfg then return end
	local joint, goal = magnifierMod.PoseFor(gunModel, magCfg, flipped and 1 or 0)
	if not joint then return end

	local time = flipped and (magCfg.flipTime or 0.22)
		or (magCfg.unflipTime or magCfg.flipTime or 0.22)
	tweenService:Create(joint, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ C0 = goal }):Play()
end)

repFire:Connect(FireBullet)

-- Another player's gun just ejected a casing. This is fired by THAT player's
-- CharacterClient at the exact moment their own brass leaves the gun, so every fire
-- mode -- full auto, semi, and manual bolt/pump cycles -- replicates identically, and
-- the shellEjectDelay is already baked into when the event arrives.
repEjectShell:Connect(function(player:Player)
	-- Same global toggle the shooter's own client respects. Without this, turning
	-- shellEjection off killed your own brass but left everyone else's.
	if not config.shellEjection then return end

	local character = player and player.Character
	if not character then return end

	local tool = character:FindFirstChildWhichIsA("Tool")
	if not tool or not tool:FindFirstChild("SPH_Weapon") then return end

	-- Other players are always seen through their third-person WeaponRig model.
	local rig = character:FindFirstChild("WeaponRig")
	local weapon = rig and rig:FindFirstChild("Weapon")
	local gunModel = weapon and weapon:FindFirstChildWhichIsA("Model")
	if not gunModel then return end

	shellEjection.ejectShell(player, tool, gunModel)
end)

repSound:Connect(function(player:Player, soundToPlay:Sound, dupeSound:boolean)
	if not soundToPlay then return end

	if not dupeSound then
		soundToPlay:Play()
	else
		if not player.Character then return end
		if not player.Character:FindFirstChild("Torso") and not player.Character:FindFirstChild("UpperTorso") then return end
		local newSound = soundToPlay:Clone()
		local parentFolder = soundToPlay.Parent
		-- Environment fire layers emit from the character's EnvSoundPart so they're the same
		-- part for everyone; other layers play from the HumanoidRootPart (or their own part).
		if parentFolder and (parentFolder.Name == "FireEnv" or parentFolder.Name == "FireEnvIndoor") then
			local envRef = player.Character:FindFirstChild("EnvSoundPartRef")
			newSound.Parent = (envRef and envRef.Value) or player.Character.HumanoidRootPart
		elseif parentFolder and parentFolder.Name == "FireEnvFar" then
			-- Far echo layer: emit from the 900-stud EnvSoundPartFar so it carries across
			-- the map. Fall back to the near emitter, then the root part, if it's missing.
			local farRef = player.Character:FindFirstChild("EnvSoundPartFarRef")
			local nearRef = player.Character:FindFirstChild("EnvSoundPartRef")
			newSound.Parent = (farRef and farRef.Value) or (nearRef and nearRef.Value) or player.Character.HumanoidRootPart
		elseif parentFolder and parentFolder:IsA("BasePart") then
			newSound.Parent = parentFolder
		else
			newSound.Parent = player.Character.HumanoidRootPart
		end
		newSound:Play()
		local soundLength = newSound.TimeLength
		if soundLength < 1 then soundLength = 1 end
		debris:AddItem(newSound,soundLength)
	end
end)

repHit:Connect(function(tool:Tool, raycastResult:RaycastResult)
	local hitPart = raycastResult.Instance
	local bulletStats = require(tool.SPH_Weapon.WeaponStats)
	if raycastResult.Instance and bulletStats.projectile == "Bullet" then
		hitFX.HitEffect(raycastResult.Position,hitPart,raycastResult.Normal)
	end
end)

repBolt:Connect(function(player, direction, magAmmo)
	local gunModel = player.Character.WeaponRig.Weapon:FindFirstChildWhichIsA("Model")
	local wepStats = require(player.Character:FindFirstChildWhichIsA("Tool").SPH_Weapon.WeaponStats)
	local boltData = {
		fireMoveParts = wepStats.fireMoveParts;
		fireRate = wepStats.fireRate;
		emptyLockBolt = wepStats.emptyLockBolt;
	}
	bulletHandler.MoveBolt(gunModel,boltData,direction,magAmmo)
end)

local LASER_STORAGE_CF = CFrame.new(0, -10000, 0) -- park the sphere here while it isn't hitting anything

-- ===== BEAM LOOK (normal vs IR) ====================================================
-- Must stay in sync with the identical table in CharacterClient -- this is the same beam
-- seen on someone ELSE'S gun. See the long comment there for why the old IR beam was
-- nearly invisible (sub-pixel width, 0.5 transparency, and the NVG ColorCorrection's
-- Saturation = -1 crushing a saturated color to a dark grey before the blue tint).
local BEAM_LOOK = {
	normal = {
		Width0 = 0.02, Width1 = 0.02,
		Brightness = 3,
		Transparency = NumberSequence.new(0.5),
		ColorLift = 0,
		Glow = false,
	},
	ir = {
		Width0 = 0.03, Width1 = 0.07,
		Brightness = 18, -- HDR -> the NVG's NV_Bloom (Threshold 0.36) turns it into a glow
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.08, 0.1),
			NumberSequenceKeypoint.new(1, 0.28),
		}),
		ColorLift = 0.55, -- toward white, so it survives the tube's full desaturation
		Glow = true,
		GlowWidth0 = 0.08, GlowWidth1 = 0.22,
		GlowBrightness = 5,
		GlowTransparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.88),
			NumberSequenceKeypoint.new(0.12, 0.74),
			NumberSequenceKeypoint.new(1, 0.92),
		}),
	},
}

-- Style a beam and build/return its wide faint halo companion (IR only).
local function StyleBeam(beam, color, isIR)
	local look = isIR and BEAM_LOOK.ir or BEAM_LOOK.normal
	local shown = color:Lerp(Color3.new(1, 1, 1), look.ColorLift)

	beam.Color          = ColorSequence.new(shown)
	beam.Width0         = look.Width0
	beam.Width1         = look.Width1
	beam.Brightness     = look.Brightness
	beam.Transparency   = look.Transparency
	beam.LightInfluence = 0
	beam.FaceCamera     = true

	if not look.Glow then return nil end

	local glow = beam:Clone()
	glow.Name          = "ReplicatedLaserBeamGlow"
	glow.ZOffset       = -0.01 -- draw just behind the core beam
	glow.Width0        = look.GlowWidth0
	glow.Width1        = look.GlowWidth1
	glow.Brightness    = look.GlowBrightness
	glow.Transparency  = look.GlowTransparency
	glow.Parent        = beam.Parent
	return glow
end

-- Remove any existing laser object for an attachment (used to clear a prior mode
-- before rebuilding, and on toggle-off).
local function removeLaserForAttachment(attachment)
	for i, laserObject in ipairs(lasers) do
		if laserObject.attachment == attachment then
			if laserObject.laserDot then laserObject.laserDot:Destroy() end
			if laserObject.sphere then laserObject.sphere:Destroy() end
			if laserObject.flare then laserObject.flare:Destroy() end
			if laserObject.laserPart and laserObject.laserPart.Parent then laserObject.laserPart.Color = LASER_PART_OFF_COLOR end
			table.remove(lasers, i)
			break
		end
	end
end

-- Remove the tracked flashlight for an attachment: kill both lights, hide the emitter
-- glow and drop its lens flare. Used before rebuilding (mode switch) and on toggle-off.
local function removeFlashlightForAttachment(attachment)
	for i = #flashlights, 1, -1 do
		local o = flashlights[i]
		if o.attachment == attachment then
			if o.gunLight then o.gunLight.Enabled = false end
			if o.irLight then o.irLight.Enabled = false end
			if o.flashPart and o.flashPart.Parent then o.flashPart.Color = FLASH_PART_OFF_COLOR end
			if o.flare then o.flare:Destroy() end
			table.remove(flashlights, i)
		end
	end
end

-- IR illuminators are invisible without night vision -- the light itself AND the emitter
-- glow on the gun. The white flashlight is always visible. Applies the current state.
local function applyFlashlightVisibility(o, show)
	if o.shown == show then return end
	o.shown = show
	if o.gunLight then o.gunLight.Enabled = show and not o.isIR end
	if o.irLight then o.irLight.Enabled = show and o.isIR end
	-- Color only: white while the white light is on, off color when off or in IR mode.
	if o.flashPart and o.flashPart.Parent then
		o.flashPart.Color = (show and not o.isIR) and FLASH_COLOR or FLASH_PART_OFF_COLOR
	end
end

-- IR lasers are only visible to a viewer who has night vision on. Show/hide every
-- visible piece (sphere dot, its light, the beam, the emitter glow part).
local function applyIRVisibility(o, show)
	if o.irShown == show then return end
	o.irShown = show
	if o.light then o.light.Enabled = show end
	if o.beam then o.beam.Enabled = show end
	if o.glow then o.glow.Enabled = show end
	-- The IR emitter never lights up, so it stays at the off color regardless of NV.
	if o.laserPart and o.laserPart.Parent then o.laserPart.Color = LASER_PART_OFF_COLOR end
	if o.sphere then o.sphere.Transparency = show and (o.baseTransparency or 0) or 1 end
	if o.trail and not show then o.trail.Enabled = false; o.trail:Clear() end
end

repToggleAttachment:Connect(function(attachment,toggle,character,isIR)
	if attachment.Name == "Flashlight" then
		-- Grip.Flashlight holds two lights: GunLight (white beam) and IRLight (IR
		-- illuminator). Only one is ever on, and IR only renders for a viewer with NVGs.
		removeFlashlightForAttachment(attachment) -- clear any prior mode before rebuilding
		if not toggle then return end

		local irLight = attachment:FindFirstChild("IRLight")
		local gunLight = attachment:FindFirstChild("GunLight")
		if not gunLight then
			-- Fallback for older guns whose single light isn't named GunLight yet.
			local anyLight = attachment:FindFirstChildWhichIsA("Light")
			if anyLight ~= irLight then gunLight = anyLight end
		end

		-- Light up the gun's emitter part (Grip.FlashPart) on this player's model, and give
		-- the WHITE light a lens flare on it. The IR illuminator gets no flare at all, and
		-- the white flare is hidden while this viewer has night vision on (same as lasers).
		local flashPart, flashFlare
		local gunModel = character and character:FindFirstChild("WeaponRig")
			and character.WeaponRig.Weapon:FindFirstChildWhichIsA("Model")
		local grip = gunModel and gunModel:FindFirstChild("Grip")
		flashPart = grip and grip:FindFirstChild("FlashPart")
		if flashPart and flashPart:IsA("BasePart") then
			EnsureNeon(flashPart)
			flashPart.Color = (isIR == true) and FLASH_PART_OFF_COLOR or FLASH_COLOR
			if not (isIR == true) then
				flashFlare = lensFlare.attach(flashPart, {
					color = FLASH_COLOR,
					forwardAttachment = attachment,
					ignore = { character },
					shouldShow = function()
						return not flaresHidden() -- [Drone]
					end,
				})
			end
		else
			flashPart = nil
		end

		local newFlash = {
			attachment = attachment,
			gunLight = gunLight,
			irLight = irLight,
			flashPart = flashPart,
			flare = flashFlare,
			isIR = isIR == true,
			shown = nil,
		}
		table.insert(flashlights, newFlash)
		-- A white light shows immediately; an IR one waits until this viewer puts NVGs on.
		applyFlashlightVisibility(newFlash, (not newFlash.isIR) or viewerHasNV()) -- [Drone]
	elseif attachment.Name == "Laser" then
		if toggle then -- (re)create the laser object
			removeLaserForAttachment(attachment) -- clear any prior laser/mode before rebuilding

			local laserColor = attachment.Color.Value

			-- Kept as the beam end + hit tracker for the beam.
			local laserDot = Instance.new("Attachment",workspace.Terrain)
			laserDot.Name = "ReplicatedLaser"

			-- The visible dot is the neon LaserTrail sphere (matches the local view), with
			-- its PointLight and Trail all tinted to the laser color. Falls back to the old
			-- billboard dot if the LaserTrail template isn't in SPH_Assets.
			local sphere, trail, light, baseTransparency
			local template = assets:FindFirstChild("LaserTrail")
			if template and template:IsA("BasePart") then
				sphere = template:Clone()
				sphere.Anchored = true
				sphere.CanCollide = false
				sphere.CanQuery = false
				sphere.CanTouch = false
				sphere.CastShadow = false
				sphere.Massless = true
				sphere.Color = laserColor
				sphere.CFrame = LASER_STORAGE_CF
				baseTransparency = sphere.Transparency
				light = sphere:FindFirstChildWhichIsA("Light")
				if light then
					light.Color = laserColor
					-- IR dot light reaches further and burns brighter than a regular laser.
					light.Range = isIR and 5 or 1.5
					light.Brightness = isIR and 8 or 4
				end
				trail = sphere:FindFirstChildWhichIsA("Trail")
				if trail then
					trail.Color = ColorSequence.new(laserColor)
					trail.Enabled = false
				end
				sphere.Parent = workspace.Terrain
			else
				local laserDotUI = assets.HUD.LaserDotUI:Clone()
				laserDotUI.Enabled = true
				laserDotUI.Dot.ImageColor3 = laserColor
				laserDotUI.Parent = laserDot
			end

			-- Light up the gun's emitter part (Grip.LaserPart) on this player's model.
			local gunModel = character.WeaponRig.Weapon:FindFirstChildWhichIsA("Model")
			local laserPart = gunModel and gunModel.Grip:FindFirstChild("LaserPart")
			local laserFlareHandle
			if laserPart and laserPart:IsA("BasePart") then
				-- Color only -- no Transparency writes (see the note at the top).
				EnsureNeon(laserPart)
				laserPart.Color = (isIR == true) and LASER_PART_OFF_COLOR or laserColor

				-- Lens flare on the emitter, aimed down the beam. The IR laser gets NO flare
				-- at all; the normal laser's flare is hidden while this viewer has night
				-- vision on.
				if not (isIR == true) then
					laserFlareHandle = lensFlare.attach(laserPart, {
						color = laserColor,
						forwardAttachment = gunModel.Grip:FindFirstChild("Laser"),
						ignore = { character },
						shouldShow = function()
							return not flaresHidden() -- [Drone]
						end,
					})
				end
			end

			-- Beam: normal lasers use config.laserTrail; an IR laser ALWAYS has a beam.
			local laserBeam, laserGlow
			if config.laserTrail or isIR then
				laserBeam = Instance.new("Beam")
				laserBeam.Attachment1 = laserDot
				laserBeam.Segments = 1
				laserBeam.Name = "ReplicatedLaserBeam"
				laserBeam.Parent = laserDot
				laserBeam.Enabled = true
				-- Attachment0 before styling, so the cloned halo inherits both endpoints.
				if gunModel then laserBeam.Attachment0 = gunModel.Grip.Laser end
				laserGlow = StyleBeam(laserBeam, laserColor, isIR == true)
			end

			local newLaser = {}
			newLaser.laserDot = laserDot
			newLaser.sphere = sphere
			newLaser.trail = trail
			newLaser.light = light
			newLaser.beam = laserBeam
			newLaser.glow = laserGlow -- IR halo (nil for a normal laser); parented to laserDot
			newLaser.laserPart = laserPart
			newLaser.flare = laserFlareHandle
			newLaser.attachment = attachment
			newLaser.ignoreModel = character
			newLaser.isIR = isIR == true
			newLaser.baseTransparency = baseTransparency
			table.insert(lasers,newLaser)

			-- IR lasers start hidden unless this viewer already has night vision on.
			if newLaser.isIR then
				applyIRVisibility(newLaser, viewerHasNV()) -- [Drone]
			end
		else
			removeLaserForAttachment(attachment)
		end
	end
end)

runService.RenderStepped:Connect(function()
	local viewerNV = viewerHasNV() -- [Drone]

	-- Other players' flashlights: nothing to aim, just keep IR illuminators gated on this
	-- viewer's night vision (and clean up when the gun model goes away).
	for i = #flashlights, 1, -1 do
		local flashObject = flashlights[i]
		if flashObject.attachment and flashObject.attachment.Parent then
			applyFlashlightVisibility(flashObject, (not flashObject.isIR) or viewerNV)
		else
			if flashObject.flare then flashObject.flare:Destroy() end
			if flashObject.flashPart and flashObject.flashPart.Parent then flashObject.flashPart.Color = FLASH_PART_OFF_COLOR end
			table.remove(flashlights, i)
		end
	end

	-- Iterate BACKWARDS. The old forward ipairs() removed entries mid-loop, which shifts
	-- every later element down one index and silently skips the next laser that frame.
	for i = #lasers, 1, -1 do
		local laserObject = lasers[i]
		local laserPoint = laserObject.attachment
		if laserPoint and laserPoint.Parent then
			-- IR laser: only this viewer's night vision reveals it. Update its visibility
			-- live, and when hidden just park the dot and skip the raycast.
			if laserObject.isIR then
				applyIRVisibility(laserObject, viewerNV)
			end
			if laserObject.isIR and not viewerNV then
				if laserObject.sphere then laserObject.sphere.CFrame = LASER_STORAGE_CF end
			else
				-- Built ONCE per laser and reused. The old code allocated a fresh
				-- RaycastParams every frame for every visible laser in the game, which is
				-- pure garbage-collector churn at 60fps.
				local laserRayParams = laserObject.rayParams
				if not laserRayParams then
					laserRayParams = RaycastParams.new()
					laserRayParams.FilterType = Enum.RaycastFilterType.Exclude
					laserRayParams.FilterDescendantsInstances = {laserObject.ignoreModel}
					laserRayParams.RespectCanCollide = true
					laserObject.rayParams = laserRayParams
				end
				local laserDotPoint = laserObject.laserDot
				local rayResult = workspace:Raycast(laserPoint.WorldPosition, laserPoint.WorldCFrame.LookVector * 600, laserRayParams)
				if rayResult then
					laserDotPoint.WorldPosition = rayResult.Position
					if laserObject.sphere then
						laserObject.sphere.Position = rayResult.Position + rayResult.Normal * 0.03
						if laserObject.trail and not laserObject.trail.Enabled then
							laserObject.trail:Clear()
							laserObject.trail.Enabled = true
						end
					end
				else
					laserDotPoint.WorldPosition = laserPoint.WorldPosition + laserPoint.WorldCFrame.LookVector * 600
					if laserObject.sphere then
						laserObject.sphere.CFrame = LASER_STORAGE_CF
						if laserObject.trail and laserObject.trail.Enabled then
							laserObject.trail.Enabled = false
							laserObject.trail:Clear()
						end
					end
				end
			end
		else
			laserObject.laserDot:Destroy()
			if laserObject.sphere then laserObject.sphere:Destroy() end
			if laserObject.flare then laserObject.flare:Destroy() end
			if laserObject.laserPart and laserObject.laserPart.Parent then laserObject.laserPart.Color = LASER_PART_OFF_COLOR end
			table.remove(lasers,i)
		end
	end
end)

repMagGrab:Connect(function(magPart)
	if magPart then
		magPart.LocalTransparencyModifier = 0
		for _, part in ipairs(magPart:GetDescendants()) do
			if part:IsA("BasePart") then part.LocalTransparencyModifier = 0 end
		end
	end
end)


print(warnPrefix.."Main Client loaded successfully!")