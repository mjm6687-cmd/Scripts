-- Camera  (ModuleScript, under CreatureClient > Systems)
--
-- Points the camera at whatever Humanoid you currently own, locks zoom to the
-- creature's range, hides the inventory, and runs the over-the-shoulder aim
-- camera for the throw.
--
-- The zoom values are captured at JOIN, before anything is changed, so unmorphing
-- restores whatever your game actually uses rather than Roblox's defaults.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local System = {
	name = "Camera",
	key = "camera",
	scope = "local",
}

local DEFAULTS = {
	cameraMinZoom = 3,
	cameraMaxZoom = 16,

	-- Over-the-shoulder aim (throw). See CreatureConfig's THROW section.
	throwAimShoulderRight = -3.4,  -- negative = over the LEFT shoulder
	throwAimShoulderUp = 1.0,
	throwAimZoom = 7,
	throwAimCameraSpeed = 9,
}

local player = Players.LocalPlayer

local originalMinZoom, originalMaxZoom, originalCameraMode

-- The creature being driven right now, and its settings.
local activeChar: Model? = nil
local cfg = table.clone(DEFAULTS)
local getConfig = nil   -- CreatureClient's cached config reader, from init(ctx)

-- Aim camera state.
local aimBlend = 0            -- 0 = normal camera, 1 = fully over the shoulder
local zoomBefore: number? = nil  -- where you were zoomed when aiming started
local offsetDirty = false

-- SetCoreGuiEnabled throws if CoreGui isn't ready, which happens on a fast join.
-- Retried rather than assumed, or you occasionally spawn as the creature with a
-- visible backpack and no clue why it's inconsistent.
local function setBackpack(enabled: boolean)
	for _ = 1, 10 do
		if pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, enabled)
			end) then
			return
		end
		task.wait(0.1)
	end
end

local function pointCamera(char: Model)
	local hum = char:WaitForChild("Humanoid", 10)
	if hum then
		workspace.CurrentCamera.CameraSubject = hum
	end
end

-- The creature's normal zoom range. Max first, so the two are never momentarily
-- crossed (min > max errors).
local function applyCreatureZoom()
	player.CameraMaxZoomDistance = math.max(cfg.cameraMaxZoom, cfg.cameraMinZoom)
	player.CameraMinZoomDistance = cfg.cameraMinZoom
end

-- Pin the zoom to exactly one distance. Order matters the same way.
local function pinZoom(z: number)
	if z > player.CameraMaxZoomDistance then
		player.CameraMaxZoomDistance = z
		player.CameraMinZoomDistance = z
	else
		player.CameraMinZoomDistance = z
		player.CameraMaxZoomDistance = z
	end
end

local function clearAimCamera()
	aimBlend = 0
	zoomBefore = nil
	if offsetDirty and activeChar then
		local hum = activeChar:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.CameraOffset = Vector3.zero
		end
	end
	offsetDirty = false
end

local function loadCfg(config)
	cfg = table.clone(DEFAULTS)
	for k in pairs(DEFAULTS) do
		if typeof(config) == "table" and typeof(config[k]) == "number" then
			cfg[k] = config[k]
		end
	end
end

function System.init(ctx)
	getConfig = ctx and ctx.getConfig
	originalMinZoom = player.CameraMinZoomDistance
	originalMaxZoom = player.CameraMaxZoomDistance
	originalCameraMode = player.CameraMode

	-- Also needs to run for the NORMAL character -- manually setting
	-- player.Character can leave the camera pointed at nothing.
	player.CharacterAdded:Connect(pointCamera)
	if player.Character then
		task.spawn(pointCamera, player.Character)
	end
end

function System.onAdded(char: Model, config)
	loadCfg(config)

	activeChar = char
	clearAimCamera()

	-- Force out of first person BEFORE clamping: a player already zoomed all the
	-- way in otherwise stays stuck there until they scroll.
	player.CameraMode = Enum.CameraMode.Classic
	applyCreatureZoom()

	setBackpack(false)
	pointCamera(char)
end

function System.onRemoved()
	clearAimCamera()
	activeChar = nil

	player.CameraMaxZoomDistance = math.max(originalMaxZoom, originalMinZoom)
	player.CameraMinZoomDistance = originalMinZoom
	player.CameraMode = originalCameraMode
	setBackpack(true)
end

--[[
	OVER-THE-SHOULDER AIM.

	The Arm system sets ThrowAiming on your character while you hold right click to
	aim, and keeps it through the wind-up and throw. While it's on:

	  * zoom eases from wherever you were to throwAimZoom (pinned, so scrolling
	    can't fight it)
	  * Humanoid.CameraOffset slides the view up and over the right shoulder --
	    the body is turned to face the aim by CreatureMovement, so "right" is
	    always the throwing shoulder

	When it goes off, both ease back, and the zoom lands exactly where you had it
	before you started aiming. Camera.CFrame is never touched.
--]]
function System.update(dt: number)
	--[[
		Always the CURRENT body, read fresh every frame.

		This used to trust activeChar, which is only set in onAdded -- and
		CreatureClient only calls onAdded when you go from human to creature. Die
		as the creature and respawn as one, or morph creature-to-creature, and
		activeChar was still the old dead body: this returned on its first line
		and the aim camera silently never worked again.
	--]]
	local char = player.Character
	if not (char and char.Parent and char:GetAttribute("IsCreature") == true) then
		return
	end
	if char ~= activeChar then
		-- A new body. Drop anything left over from the old one and pick up this
		-- one's settings.
		zoomBefore = nil
		aimBlend = 0
		offsetDirty = false
		activeChar = char
		if getConfig then
			local ok, config = pcall(getConfig, char)
			if ok then
				loadCfg(config)
			end
		end
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end

	local aiming = char:GetAttribute("ThrowAiming") == true

	if aiming and not zoomBefore then
		local cam = workspace.CurrentCamera
		local dist = cam and (cam.Focus.Position - cam.CFrame.Position).Magnitude or cfg.cameraMaxZoom
		zoomBefore = math.clamp(dist, cfg.cameraMinZoom, math.max(cfg.cameraMaxZoom, cfg.cameraMinZoom))
	end

	local target = aiming and 1 or 0
	aimBlend += (target - aimBlend) * (1 - math.exp(-cfg.throwAimCameraSpeed * dt))
	if not aiming and aimBlend < 0.01 then aimBlend = 0 end
	if aiming and aimBlend > 0.995 then aimBlend = 1 end

	-- Shoulder offset.
	if aimBlend > 0 then
		hum.CameraOffset = Vector3.new(cfg.throwAimShoulderRight, cfg.throwAimShoulderUp, 0) * aimBlend
		offsetDirty = true
	elseif offsetDirty then
		hum.CameraOffset = Vector3.zero
		offsetDirty = false
	end

	-- Zoom.
	if zoomBefore then
		if aimBlend == 0 and not aiming then
			-- Back where you were: hand the normal range back. The camera stays at
			-- zoomBefore, which is inside that range.
			applyCreatureZoom()
			zoomBefore = nil
		else
			pinZoom(zoomBefore + (cfg.throwAimZoom - zoomBefore) * aimBlend)
		end
	end
end

return System
