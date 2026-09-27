-- ChatHide  (ModuleScript, under CreatureClient > Systems)
--
-- While you're the creature, chat is gone from your screen entirely: the chat
-- window, the input bar (so you can't type either), and chat bubbles over
-- people's heads. It all comes back exactly as it was the moment you stop being
-- the creature.
--
-- Covers both chat systems: the new TextChatService one and the old legacy
-- CoreGui chat, whichever your game is using. Turn it off for a creature with
-- systems = { chathide = false } in its CreatureConfig.

local TextChatService = game:GetService("TextChatService")
local StarterGui = game:GetService("StarterGui")

local System = {
	name = "ChatHide",
	key = "chathide",
	scope = "local",
}

-- What each setting was before we hid it, so we put back YOUR game's settings
-- rather than assuming everything was on.
local saved: { [Instance]: boolean }? = nil
local savedCoreChat: boolean? = nil

local function textChatConfigs(): { Instance }
	local list = {}
	for _, name in ipairs({ "ChatWindowConfiguration", "ChatInputBarConfiguration", "BubbleChatConfiguration" }) do
		local c = TextChatService:FindFirstChild(name)
		if c then
			table.insert(list, c)
		end
	end
	return list
end

-- SetCoreGuiEnabled can throw early in a session; retried like the backpack is.
local function setCoreChat(enabled: boolean)
	for _ = 1, 10 do
		if pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, enabled)
			end) then
			return
		end
		task.wait(0.1)
	end
end

function System.onAdded()
	if saved then
		return -- already hidden
	end
	saved = {}

	for _, c in ipairs(textChatConfigs()) do
		local ok, was = pcall(function()
			return (c :: any).Enabled
		end)
		if ok then
			saved[c] = was
			pcall(function()
				(c :: any).Enabled = false
			end)
		end
	end

	local ok, was = pcall(function()
		return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Chat)
	end)
	savedCoreChat = ok and was or true
	task.spawn(setCoreChat, false)
end

function System.onRemoved()
	if not saved then
		return
	end
	for c, was in pairs(saved) do
		if c.Parent then
			pcall(function()
				(c :: any).Enabled = was
			end)
		end
	end
	saved = nil

	local restore = savedCoreChat ~= false
	savedCoreChat = nil
	task.spawn(setCoreChat, restore)
end

return System
