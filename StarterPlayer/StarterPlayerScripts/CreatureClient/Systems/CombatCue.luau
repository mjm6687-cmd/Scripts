-- CombatCue  (ModuleScript, under CreatureClient > Systems)
--
-- Starts your combat music when the creature is a threat to you right now:
-- a roar close enough that you felt it. RoarEffects calls System.cue() for that.
--
-- ============================================================
-- WHY IT GOES THROUGH A BINDABLE
-- ============================================================
-- CombatMusicClient already owns everything that matters here: the 15s timeout,
-- the fade in and out, the InGame check that keeps music out of the menu, and the
-- CombatMusicGain attribute that makes background music and the radiation track
-- duck out of the way.
--
-- So this doesn't play anything. It fires ReplicatedStorage.CombatTrigger and
-- CombatMusicClient's own markCombat does the rest - meaning a creature encounter
-- behaves exactly like a firefight, and any future tuning of combat music applies
-- to it for free. A second music system would have meant two things fighting over
-- the same SoundGroup.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = {
	name = "CombatCue",
	key = "combatcue",
	scope = "local",
}

local trigger: BindableEvent?

-- Shared with RoarEffects, and created by whichever gets there first -
-- CombatMusicClient also creates it if it loads before either.
local function ensureTrigger(): BindableEvent
	local t = ReplicatedStorage:FindFirstChild("CombatTrigger")
	if not t then
		t = Instance.new("BindableEvent")
		t.Name = "CombatTrigger"
		t.Parent = ReplicatedStorage
	end
	return t
end

function System.init()
	trigger = ensureTrigger()
end

-- Called by RoarEffects when a roar actually lands on this client. Kept as a
-- function on the module so there is exactly one place that decides what
-- "in combat with the creature" means.
function System.cue()
	if not trigger then
		trigger = ensureTrigger()
	end
	trigger:Fire()
end

return System
