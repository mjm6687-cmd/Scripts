-- CreatureService
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- Handles morphing a player into a creature rig and back.
-- Swaps the entire Character model so none of your normal character scripts
-- come along for the ride.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local CreatureUtil = require(ReplicatedStorage.Shared.CreatureUtil)

-- Change to ServerStorage if you'd rather the rig not be visible to clients:
--   local CreatureFolder = game:GetService("ServerStorage"):WaitForChild("Creatures")
local CreatureFolder = ReplicatedStorage:WaitForChild("Creatures")

local StarterCharScripts = StarterPlayer:WaitForChild("StarterCharacterScripts")

-- Names the engine (or your own systems) may auto-copy into any character.
local function buildBlockedNames()
	local blocked = {}
	for _, inst in ipairs(StarterCharScripts:GetChildren()) do
		blocked[inst.Name] = true
	end
	return blocked
end

-- Instance classes that dress a character. A creature is not wearing your
-- avatar's hair, your issued uniform, or a BodyColors telling its head to be
-- your skin tone ? that last one is why custom skin colours "break": BodyColors
-- overwrites every limb colour on the rig, including a creature built out of
-- coloured or textured parts.
local APPEARANCE_CLASSES = {
	"Accessory",
	"CharacterMesh",
	"Shirt",
	"Pants",
	"ShirtGraphic",
	"BodyColors",
}

local function isAppearanceInstance(inst: Instance): boolean
	for _, className in ipairs(APPEARANCE_CLASSES) do
		if inst:IsA(className) then
			return true
		end
	end
	return false
end

-- Watch the rig briefly after spawn and destroy anything injected into it.
--
-- Two jobs: scripts copied out of StarterCharacterScripts, and appearance items
-- pushed on by character/appearance systems elsewhere in the game.
--
-- The appearance sweep is a CATCH-ALL on purpose. Guarding every script that
-- dresses a character means finding every one of them, and missing one is
-- invisible until you morph and find yourself wearing your own hair. This
-- catches them all, including ones added later, without either side knowing
-- about the other.
local function guardRig(rig)
	local blocked = buildBlockedNames()

	local function check(inst)
		-- The rig's own contents are tagged at clone time, so a creature that
		-- legitimately ships with a Shirt or BodyColors keeps them.
		if inst:GetAttribute("CreatureOwned") then
			return
		end

		--[[
			FOLDERS OF CHARACTER SCRIPTS, not just loose scripts.

			The check below only caught scripts whose OWN name is in
			StarterCharacterScripts. The gun framework ships as a folder
			(SPH_Character) with CharacterClient and friends inside it -- the folder
			wasn't a script so it was let through, and every script in it ran inside
			the creature. That's how a human head-aim ended up on the creature's neck.
			A blocked name directly under the rig goes, whatever it is.
		--]]
		if inst.Parent == rig and blocked[inst.Name] and not inst:IsA("BasePart") then
			task.defer(function()
				if inst.Parent == rig then
					inst:Destroy()
				end
			end)
			return
		end

		if inst:IsA("BaseScript") or inst:IsA("ModuleScript") then
			if inst:GetAttribute("CreatureScript") then
				return -- one of the rig's own scripts
			end
			if blocked[inst.Name] then
				inst:Destroy()
			end
			return
		end

		if isAppearanceInstance(inst) then
			-- Deferred: destroying inside the signal that announced the instance
			-- can fight whatever is still parenting it.
			task.defer(function()
				if inst.Parent then
					inst:Destroy()
				end
			end)
			return
		end

		-- Hair morphs arrive as plain Models rather than Accessories. Only ones
		-- parented directly to the character are touched ? a Model nested deeper
		-- is part of the rig.
		if inst:IsA("Model") and inst.Parent == rig then
			task.defer(function()
				if inst.Parent == rig then
					inst:Destroy()
				end
			end)
		end
	end

	for _, d in ipairs(rig:GetDescendants()) do
		check(d)
	end

	local conn = rig.DescendantAdded:Connect(check)

	-- 10s rather than 5: appearance systems commonly re-apply on
	-- CharacterAppearanceLoaded, which can land several seconds after spawn.
	task.delay(10, function()
		conn:Disconnect()
	end)
end

-- The creature has no hands. Hiding the backpack UI client-side stops the player
-- SEEING their inventory; this stops them USING it, since number keys still fire
-- with the UI hidden. Any tool that lands on the creature goes straight back to
-- the Backpack ? it is never destroyed, so nothing is lost by morphing.
local function blockTools(player: Player, rig: Model)
	local conn
	conn = rig.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				child.Parent = backpack
			end
		end
	end)

	rig.AncestryChanged:Connect(function(_, parent)
		if not parent then
			conn:Disconnect()
		end
	end)

	-- Anything already equipped when the morph happened.
	for _, child in ipairs(rig:GetChildren()) do
		if child:IsA("Tool") then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then
				child.Parent = backpack
			end
		end
	end
end

local CreatureService = {}
local morphed = {} -- [Player] = creatureName

-- Turn a player into the named creature. Returns the new rig, or nil on failure.
function CreatureService.Morph(player: Player, creatureName: string)
	local template = CreatureFolder:FindFirstChild(creatureName)
	if not template then
		warn("[CreatureService] No creature named " .. tostring(creatureName))
		return nil
	end

	local oldChar = player.Character
	local spawnCF = (oldChar and oldChar.PrimaryPart and oldChar.PrimaryPart.CFrame)
		or CFrame.new(0, 10, 0)

	-- Unequip BEFORE the old body is destroyed. A tool still parented to the
	-- character when it goes gets destroyed with it, which silently eats the
	-- player's item every time they morph.
	if oldChar then
		local oldHum = oldChar:FindFirstChildOfClass("Humanoid")
		if oldHum then
			oldHum:UnequipTools()
		end
	end

	local rig = template:Clone()
	rig.Name = player.Name

	-- Mark it BEFORE it enters the world, so nothing gets a chance to claim it.
	rig:SetAttribute("IsCreature", true)
	CollectionService:AddTag(rig, CreatureUtil.TAG)

	-- Everything the rig template shipped with is marked as its own, BEFORE it
	-- enters the world. The sweeper then only ever removes things that arrived
	-- afterwards, so a creature designed with its own BodyColors, Shirt or
	-- sub-Models keeps them while your avatar's are still rejected.
	for _, d in ipairs(rig:GetDescendants()) do
		d:SetAttribute("CreatureOwned", true)
		if d:IsA("BaseScript") or d:IsA("ModuleScript") then
			d:SetAttribute("CreatureScript", true)
		end
	end

	--[[
		Publish the rig's joint bases as attributes, from the TEMPLATE, before
		anything has had a chance to touch them.

		CreatureHead and CreatureArm rebuild Neck.C0 and Right Shoulder.C0 from a
		"base" value every frame. Reading that base from the LIVE joint means
		whatever value happened to be there at the moment that client bound the rig
		becomes its idea of neutral ? and if any other system wrote the joint first,
		that client is now building every pose on top of a wrong baseline. The
		result is a creature that looks correct to one player and visibly broken to
		another, which is a miserable thing to debug because nothing errors.

		Attributes replicate, so every client reads the identical base regardless of
		when it bound the rig or what else ran first.
	--]]
	local rigTorso = rig:FindFirstChild("Torso")
	if rigTorso then
		local neck = rigTorso:FindFirstChild("Neck")
		if neck and neck:IsA("Motor6D") then
			rig:SetAttribute("NeckBaseC0", neck.C0)
		end

		local shoulder = rigTorso:FindFirstChild("Right Shoulder")
		if shoulder and shoulder:IsA("Motor6D") then
			rig:SetAttribute("RightShoulderBaseC0", shoulder.C0)
		end

		-- The left one too, for the two-handed eat.
		local leftShoulder = rigTorso:FindFirstChild("Left Shoulder")
		if leftShoulder and leftShoulder:IsA("Motor6D") then
			rig:SetAttribute("LeftShoulderBaseC0", leftShoulder.C0)
		end

		-- The hips, for the Arm system's torso layer: it counter-rotates them so
		-- the legs stay planted while the upper body twists.
		for _, hipName in ipairs({ "Left Hip", "Right Hip" }) do
			local hip = rigTorso:FindFirstChild(hipName)
			if hip and hip:IsA("Motor6D") then
				rig:SetAttribute(string.gsub(hipName, " ", "") .. "BaseC0", hip.C0)
			end
		end
	end

	-- And the root joint itself, which the torso layer turns.
	local rigRoot = rig:FindFirstChild("HumanoidRootPart")
	local rootJoint = rigRoot and rigRoot:FindFirstChild("RootJoint")
	if rootJoint and rootJoint:IsA("Motor6D") then
		rig:SetAttribute("RootJointBaseC0", rootJoint.C0)
	end

	rig:PivotTo(spawnCF)
	guardRig(rig)

	player.Character = rig
	rig.Parent = workspace

	blockTools(player, rig)

	if oldChar then
		oldChar:Destroy()
	end

	morphed[player] = creatureName

	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Once(function()
			morphed[player] = nil
			Debris:AddItem(rig, 5)

			--[[
				RESPAWN: let Roblox do it whenever Roblox is going to do it anyway.

				Players.CharacterAutoLoads is true in almost every game, and it already
				respawns a player whose character died ? including a character we set
				manually. Calling LoadCharacter here as well meant TWO spawns racing:
				the engine's, then ours a moment later destroying it and building
				another.

				The symptom is a character that looks fine but half works ? you come
				back unable to sprint ? because StarterCharacterScripts ran on the
				first body and bound its inputs, and then that body was thrown away
				while the bindings, keyed by name, still pointed at a humanoid that no
				longer exists.

				So: only respawn by hand when nothing else will.
			--]]
			if Players.CharacterAutoLoads then
				return
			end

			task.wait(Players.RespawnTime)
			if player.Parent and player.Character == rig then
				player:LoadCharacter() -- back to the normal human body
			end
		end)
	end

	return rig
end

-- Return the player to their normal character.
function CreatureService.Unmorph(player: Player)
	morphed[player] = nil
	player:LoadCharacter()
end

function CreatureService.IsMorphed(player: Player): boolean
	return morphed[player] ~= nil
end

function CreatureService.GetCreatureName(player: Player): string?
	return morphed[player]
end

Players.PlayerRemoving:Connect(function(player)
	morphed[player] = nil
end)

-- Quick access for other server scripts.
-- Cleaner long-term: move this file to a ModuleScript and `return CreatureService`
-- instead of using _G.
_G.CreatureService = CreatureService

-- ============================================================
-- EXTERNAL CONTROL SURFACE
-- ============================================================
-- A BindableEvent + BindableFunction in ServerStorage, so anything else in the
-- game (admin commands, round logic, a lobby button) can drive morphing without
-- requiring this script or knowing it exists. If this script isn't running, the
-- objects simply aren't there and the caller carries on ? no hard dependency
-- either way.
local ServerStorage = game:GetService("ServerStorage")

local control = ServerStorage:FindFirstChild("CreatureControl")
if not control then
	control = Instance.new("BindableEvent")
	control.Name = "CreatureControl"
	control.Parent = ServerStorage
end

-- control:Fire("morph", player, "Stalker")
-- control:Fire("unmorph", player)
control.Event:Connect(function(action, player, creatureName)
	if typeof(action) ~= "string" then
		return
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	action = string.lower(action)
	if action == "morph" then
		CreatureService.Morph(player, creatureName or "Stalker")
	elseif action == "unmorph" then
		CreatureService.Unmorph(player)
	end
end)

local query = ServerStorage:FindFirstChild("CreatureQuery")
if not query then
	query = Instance.new("BindableFunction")
	query.Name = "CreatureQuery"
	query.Parent = ServerStorage
end

-- query:Invoke("list")            -> { "Stalker", ... }
-- query:Invoke("ismorphed", plr)  -> boolean
-- query:Invoke("current", plr)    -> creature name or nil
query.OnInvoke = function(action, player)
	if typeof(action) ~= "string" then
		return nil
	end
	action = string.lower(action)

	if action == "list" then
		local names = {}
		for _, child in ipairs(CreatureFolder:GetChildren()) do
			if child:IsA("Model") then
				table.insert(names, child.Name)
			end
		end
		table.sort(names)
		return names
	elseif action == "ismorphed" and typeof(player) == "Instance" and player:IsA("Player") then
		return CreatureService.IsMorphed(player)
	elseif action == "current" and typeof(player) == "Instance" and player:IsA("Player") then
		return CreatureService.GetCreatureName(player)
	end

	return nil
end
