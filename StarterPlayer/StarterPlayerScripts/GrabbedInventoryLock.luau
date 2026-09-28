-- GrabbedInventoryLock
-- CLASS: LocalScript
-- PLACE IN: StarterPlayer > StarterPlayerScripts
--
-- Hides your inventory bar while a creature is holding you (or you're flying /
-- down from being thrown), and puts it back when you're up again.
--
-- CreatureGrabServer sets a "Grabbed" attribute on your character when you're
-- picked up. Attributes replicate, so this just watches it. The server is what
-- actually unequips your tool and refuses re-equips (and SPH CharacterClient
-- stops trying to equip); this is only the UI, so the number keys and the hotbar
-- don't look like they should work.
--
-- This is the ONLY script that should hide the hotbar for being grabbed. If
-- something else starts toggling it too, the two fight and the bar flickers.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer

-- What the backpack UI was before we hid it, so we restore THAT rather than
-- blindly turning it on (another script may have hidden it for its own reasons).
local hiddenByUs = false
local wasEnabled = true

--[[
	LATEST CALL WINS.

	SetCoreGuiEnabled can error very early in a session, so it's retried -- and
	retrying yields. Grabbed and dropped in quick succession, the "hide" could
	still be retrying when the "show" went through, then land after it and leave
	the bar hidden while you walk around. Each call bumps `version`; an older call
	that's still retrying sees it's been overtaken and gives up.
--]]
local version = 0

local function setCoreBackpack(enabled: boolean)
	version += 1
	local mine = version
	for _ = 1, 10 do
		if mine ~= version then
			return
		end
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, enabled)
		end)
		if ok then
			return
		end
		task.wait(0.2)
	end
end

local function hide()
	if hiddenByUs then
		return
	end
	hiddenByUs = true
	local ok, enabled = pcall(function()
		return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
	end)
	wasEnabled = not ok or enabled
	task.spawn(setCoreBackpack, false)
end

local function restore()
	if not hiddenByUs then
		return
	end
	hiddenByUs = false
	task.spawn(setCoreBackpack, wasEnabled)
end

local attrConn
local thrownConn

local function onCharacter(character: Model)
	if attrConn then
		attrConn:Disconnect()
		attrConn = nil
	end
	if thrownConn then
		thrownConn:Disconnect()
		thrownConn = nil
	end

	-- A fresh body is never grabbed. Covers dying while held.
	restore()

	local function update()
		if character:GetAttribute("Grabbed") == true or character:GetAttribute("Thrown") == true then
			hide()
		else
			restore()
		end
	end

	attrConn = character:GetAttributeChangedSignal("Grabbed"):Connect(update)
	thrownConn = character:GetAttributeChangedSignal("Thrown"):Connect(update)
	update()
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end
