-- Mouse  (ModuleScript, under CreatureClient > Systems)
--
-- Mouse hidden and pinned to screen centre, so moving it turns the camera with no
-- right-click hold. Locking to centre is all that's needed: Roblox's own camera
-- module already feeds mouse delta into rotation whenever MouseBehavior is
-- LockCenter — the same mechanism shift lock uses.
--
-- Z releases it: cursor back, free to click UI. Z again re-locks.
--
-- WHY THE DECISION IS MADE EVERY FRAME FROM THE CURRENT CHARACTER, rather than
-- switched on and off: an earlier version bound a loop on morph and unbound it on
-- unmorph, and if that unbind was ever missed the loop kept re-asserting
-- LockCenter with nothing left to stop it. A human character stuck in LockCenter
-- makes CharacterMovement's IsFirstPersonOrShiftLock() return true forever, which
-- turns on the sprint direction lock — "I can't sprint any more after being the
-- creature". Nothing to leak now.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local System = {
	name = "Mouse",
	key = "mouse",
	scope = "local",
}

local DEFAULTS = {
	mouseFreeKey = Enum.KeyCode.Z,
	-- false = the toggle is a tap (press Z on, press Z off)
	-- true  = hold Z for the cursor, release to go back to looking
	mouseFreeIsHold = false,
}

local player = Players.LocalPlayer
local CreatureUtil

local originalMouseIconEnabled = UserInputService.MouseIconEnabled
local applied = false
local wantLock = false
local released = false
local cfg = table.clone(DEFAULTS)

local function bindToggle()
	--[[
		BOUND ONCE, NEVER UNBOUND.

		Same rule the roar keys learned the hard way: a ContextActionService
		binding made in a script that only runs once per player cannot be re-made
		after you unbind it, so unbinding on unmorph killed the key permanently —
		morph again and Z did nothing for the rest of the session.

		So the binding is permanent and the HANDLER decides. Not a creature? Pass,
		and the keypress carries on to whatever else wants Z.
	--]]
	ContextActionService:BindActionAtPriority("Creature_FreeMouse", function(_, inputState)
		local char = player.Character
		if not (wantLock and char and CreatureUtil.IsCreature(char)) then
			return Enum.ContextActionResult.Pass
		end

		if cfg.mouseFreeIsHold then
			if inputState == Enum.UserInputState.Begin then
				released = true
			elseif inputState == Enum.UserInputState.End then
				released = false
			end
			return Enum.ContextActionResult.Sink
		end

		if inputState == Enum.UserInputState.Begin then
			released = not released
			return Enum.ContextActionResult.Sink
		end

		return Enum.ContextActionResult.Pass
	end, false, 2400, cfg.mouseFreeKey)
end

function System.init(ctx)
	CreatureUtil = ctx.CreatureUtil
	originalMouseIconEnabled = UserInputService.MouseIconEnabled
	bindToggle()
end

function System.onAdded(_char: Model, config)
	for k in pairs(DEFAULTS) do
		if config[k] ~= nil then
			cfg[k] = config[k]
		end
	end

	wantLock = true
	-- A fresh morph always starts looking, never with a stranded free cursor from
	-- the last life.
	released = false
end

function System.onRemoved()
	wantLock = false
	released = false
end

-- Situations where the player genuinely needs a cursor whether they asked or not.
-- Releasing for these is the difference between immersive and "I can't click the
-- button".
local function needsCursor(): boolean
	return released
		or UserInputService:GetFocusedTextBox() ~= nil
		or GuiService.MenuIsOpen
		or UserInputService.ModalEnabled
end

function System.update()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	local shouldLock = wantLock
		and char ~= nil
		and char.Parent ~= nil
		and hum ~= nil
		and hum.Health > 0      -- dead creature: give the cursor straight back
		and not needsCursor()

	if shouldLock then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		applied = true
	elseif applied then
		-- Written once on the way out, not every frame — stomping MouseBehavior
		-- 60 times a second would fight anything else that wants the cursor, and
		-- would also make the released state unclickable in practice.
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = originalMouseIconEnabled
		applied = false
	end
end

return System
