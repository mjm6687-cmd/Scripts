-- ReplicatedStorage/Shared/CreatureUtil (ModuleScript)
local CollectionService = game:GetService("CollectionService")

local CreatureUtil = {}

CreatureUtil.TAG = "Creature"

function CreatureUtil.IsCreature(character)
	if not character then return false end
	return character:GetAttribute("IsCreature") == true
		or CollectionService:HasTag(character, CreatureUtil.TAG)
end

-- convenience for scripts that start from a player
function CreatureUtil.IsPlayerCreature(player)
	return CreatureUtil.IsCreature(player.Character)
end

return CreatureUtil