-- CreatureGrabServer
-- CLASS: Script
-- PLACE IN: ServerScriptService
--
-- Owns the grab and the kill. Everything that matters happens here, because a
-- client cannot be allowed to decide that another player dies.
--
-- The client only ever REQUESTS ("I think I touched someone"). The server
-- re-checks distance, cone, line of sight, health and grab state before agreeing.
-- Nothing the client sends names a victim ? the server picks it. A modified client
-- can spam requests and still only ever grab someone who is genuinely in reach.
--
-- THE WELD IS THE TRICK
--   The victim's HumanoidRootPart is welded to the creature's Right Arm. From then
--   on the victim FOLLOWS THE ARM ? including through the Eat animation. That's why
--   eating is authored as an animation and needs no separate code to move the
--   victim to the mouth: animate the arm and the body in its grip comes along.
--
-- Both RemoteEvents are created here at runtime, so there is nothing to add by hand.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local CreatureUtil = require(ReplicatedStorage.Shared.CreatureUtil)

-- ===== TUNING =====
local GRAB_RANGE = 10          -- slightly over the client's 8, to allow for lag

-- Widened for camera aiming. The client no longer grabs whoever is in front of
-- the BODY ? it grabs whatever the hand touches, and with the camera free to look
-- anywhere the body isn't, a legitimate grab can land well off the torso's
-- forward axis. A tight cone here would reject perfectly fair grabs.
--
-- Still a cone, not a sphere: this is what stops a grab landing on someone
-- directly behind the creature, which no amount of aiming should reach.
local GRAB_CONE_ANGLE = 120
local MIN_ACTION_INTERVAL = 0.2
-- ===== HOW THE VICTIM SITS IN THE HAND =====
-- The weld is rigid to the Right Arm, so the victim's orientation follows the arm
-- exactly. When the arm swings forward, the arm's local +Y (which was world up)
-- now points backward ? which is why an un-rotated victim ends up lying flat and
-- buried in the limb.
--
-- In the arm's local space, -Z is the direction that points UP once the arm is
-- extended forward. So rotating the victim -90? about X maps their +Y onto that,
-- and they're carried face-up with the arm out. The extra few degrees of pitch,
-- yaw and roll break the symmetry so it reads as a body being carried rather than
-- a prop bolted on straight.
-- BEST WAY TO TUNE THIS: put an Attachment named GrabHoldAttachment in the rig's
-- Right Arm and drag/rotate it in Studio until it looks right. If one exists it
-- wins over every number below, and you can adjust the pose by eye instead of
-- guessing angles and restarting. The numbers are the fallback.
--[[
	================= WORKING WITH YOUR Ragdoll.luau =================

	Ragdoll.luau's HandleDeath does something that changes everything here: on
	Humanoid.Died it CLONES the character into a model named "DeadBody", parents
	the clone to Workspace, and hides the original (Transparency 1, Anchored,
	CanCollide false).

	So the body you see on the floor is NOT the character this script was holding.
	That single fact caused both of the bugs below.

	  * DECAPITATION DID NOTHING. It removed the head from the original character
	    ? which by then was invisible and anchored. The visible corpse was the
	    clone, still wearing its head.

	  * THE CORPSE APPEARED ON THE FLOOR. The arm pose is CLIENT-side: CreatureArm
	    writes Motor6D C0s on each client, and C0 writes don't replicate. The
	    SERVER's copy of the shoulder is at rest, arm hanging down ? so the welded
	    victim was, server-side, down by the creature's hip the whole time. The
	    clone was made from that, which is why the body materialised at ground
	    level instead of falling from the mouth.

	Both are handled by captureCorpse() below: it catches the clone as it's
	created, moves it to where the victim LOOKED like it was, and takes the head
	off THAT.
--]]
local CORPSE_MODEL_NAMES = { "DeadBody", "_Dead" }
local CORPSE_WAIT = 1.5      -- seconds to wait for the ragdoll clone to appear

-- Where the corpse is placed at the moment of death, relative to the mouth.
-- Slightly out and down, so it falls clear of the creature's own head rather
-- than spawning inside it and being shoved sideways by the collision.
local CORPSE_DROP_OFFSET = Vector3.new(0, -1.2, -1.0)
local CORPSE_DROP_VELOCITY = Vector3.new(0, -2, 0)

--[[
	================= RAGDOLL HANG, OR ANIMATED STRUGGLE =================

	GRAB_RAGDOLL true means the victim goes limp and hangs by the limb the creature
	has hold of, under physics ? swinging with the arm, banging off doorframes,
	dragging when you walk. Their Ragdoll.luau already had EnableRagdoll/
	DisableRagdoll for living characters; the patched version makes that look like
	the death ragdoll instead of a rigid plank, and adds a BindableEvent this can
	reach from the server.

	THE TWO ARE MUTUALLY EXCLUSIVE. Ragdolling disables the Motor6Ds, so an
	animation on a ragdolled victim does precisely nothing. Setting this true makes
	victimGrabAnim dead weight, and that's not a bug to fix ? a ragdoll cannot be
	posed, which is the whole reason it looks like a body and not a puppet.

	  ragdoll    genuinely limp, reacts to the world, no struggling at all
	  animation  they fight, but rigid, and they pass through geometry

	GRAB_LIMB is what makes it a HANG rather than a carry. Welding the victim's
	root means the creature is holding their middle and everything rotates about
	that. Welding an ARM means the arm is the fixed point and the body dangles
	beneath it off the shoulder joint ? which is the pose you get when something
	picks a person up by one limb.
--]]
local GRAB_RAGDOLL = true
local GRAB_LIMB = "Head"       -- the victim part the hand takes hold of: by the neck
-- (was "Left Arm"). The whole body now hangs off the neck joint.
local GRAB_LIMB_FALLBACK = "HumanoidRootPart"

-- Which point on the victim's head sits IN the creature's hand, in the head's own
-- space (Y is up the head). A HIGHER number here drops the whole body LOWER in
-- the hand, so the hand ends up higher on them.
--   -0.45  bottom of the head -- in practice read as the upper chest
--    0.2   current: the hand sits at the neck
-- Nudge by 0.1 at a time. Hand still on the chest -> raise it; hand on the
-- face -> lower it.
local GRAB_LIMB_GRIP = Vector3.new(0, 0.2, 0)

-- The victim's own animation while held. IGNORED while GRAB_RAGDOLL is true.
-- Without it they keep playing whatever they were doing when grabbed ? usually
-- the walk cycle, legs pumping in mid-air.
-- Overridable per creature via CreatureConfig.victimGrabAnim, since how a victim
-- hangs depends on how the thing holding them holds them.
local VICTIM_GRAB_ANIM = "rbxassetid://100352384844197"
local VICTIM_GRAB_ANIM_FADE = 0.15

local GRAB_HOLD_ATTACHMENT = "GrabHoldAttachment"

-- Does the attachment control ROTATION as well as position?
--
--   true  - the attachment's Orientation is used. A brand new Attachment has
--           Orientation 0,0,0, which is the flat inherited-from-the-arm pose that
--           looks wrong ? so if you switch this on, set its Orientation too.
--           Start from -72, 6, 10 (the angles below) and adjust from there.
--
--   false - the attachment sets WHERE the victim sits, and the angles below set
--           how they're turned. Easier: drag the attachment around freely without
--           its rotation being able to break the pose.
local GRAB_HOLD_ATTACHMENT_ROTATION = false

-- Arm local axes once the arm is extended forward:
--     -Y -> forward (down the limb)    +Z -> down    -Z -> up
-- So Y moves the victim along the arm, and Z is what raises or lowers them.
-- Positive Z hangs them BELOW the hand, which is what a shoulder grip looks like.
local GRAB_HOLD_POSITION = Vector3.new(0, -2.0, 0.45)

-- Pitch -90 stands the victim fully upright while the arm is out; easing off it
-- slumps them forward. A rigid weld can only be correct at ONE arm angle, so
-- these favour the carry pose (arm extended), not the arm-at-rest pose.
local GRAB_HOLD_PITCH = -72  -- deg
local GRAB_HOLD_YAW = 6      -- deg. slight turn across the hand
local GRAB_HOLD_ROLL = 10    -- deg. slight list, so they don't hang perfectly square

-- How far ABOVE the victim's root the creature's hand grips. This is the bit that
-- makes it read as grabbing them by the shoulder: the held point is up at their
-- shoulder line, so the rest of the body dangles beneath it. Raise toward 1.5 to
-- grab higher (scruff of the neck), drop toward 0 to hold them round the middle.
local GRAB_VICTIM_GRIP_HEIGHT = 1.0

local GRAB_HOLD_ROTATION = CFrame.Angles(
	math.rad(GRAB_HOLD_PITCH),
	math.rad(GRAB_HOLD_YAW),
	math.rad(GRAB_HOLD_ROLL)
)

local GRAB_HOLD_OFFSET = CFrame.new(GRAB_HOLD_POSITION) * GRAB_HOLD_ROTATION

--[[
	The raise is no longer timed here.

	Eating is hold-to-charge now: the client lifts the victim toward the mouth in
	proportion to how long the button has been down, and only asks for the bite at
	100%. So by the time this runs the victim is ALREADY at the mouth, and the old
	"wait out the raise, then bite" timing would have bitten well after the fact.

	That also removes the two-copies-of-the-same-number trap the previous version
	had, where these had to be kept in sync with CreatureConfig by hand.
--]]
--[[
	CHEWING.

	Between arriving at the mouth and dying, the victim gets worked on: a series of
	crunches, each with a small blood burst, a jolt of the arm and a chunk of
	health. The kill and the decapitation land on the LAST one.

	The arm shake is computed on each client from ChewStart (a server timestamp)
	rather than streamed, so everyone sees the same jerks at the same moment for
	the price of one number. And because the victim is welded to the arm, shaking
	the arm shakes the body in its grip ? no separate code moves the victim.
--]]
local CHEW_COUNT = 4          -- crunches before the kill
local CHEW_INTERVAL = 0.38    -- seconds between them
local CHEW_TIME = CHEW_COUNT * CHEW_INTERVAL

-- Damage per crunch, as a FRACTION of max health. Never lethal on its own ? the
-- last bite is what kills, and a victim who bled out on crunch three would
-- release early and leave the creature chewing on nothing.
local CHEW_DAMAGE_FRACTION = 0.18

-- Multiplies the BiteBlood emitters' own counts. Leave at 1 if you've already
-- authored those emitters small; drop it to thin them out without editing each.
local CHEW_BLOOD_SCALE = 1

local EAT_HOLD_TIME = 0.55    -- held at the mouth after the final bite
local EAT_RETURN_TIME = 0.45  -- arm coming back down

-- THE BITE: the one moment when the sound plays and the victim dies.
--
-- Timed from the END of the raise, not from the click, so it lands when the arm
-- has actually delivered the victim to the mouth. Firing either on click makes
-- the whole thing feel disconnected ? you hear the crunch while the victim is
-- still down at the creature's side.
--
-- The small offset is deliberate: arriving and biting on the same frame reads as
-- a single event, whereas a beat of the victim held at the mouth before the bite
-- is what sells it.
-- The killing bite lands just after the last crunch, so the sequence reads as
-- one continuous act rather than chewing and then, separately, a kill.
local EAT_BITE_TIME = CHEW_TIME + 0.1

local EAT_TOTAL_TIME = EAT_BITE_TIME + EAT_HOLD_TIME + EAT_RETURN_TIME

local function ensureRemote(name: string): RemoteEvent
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = ReplicatedStorage
	end
	return r
end

local aimRemote = ensureRemote("CreatureArmAim")
local actionRemote = ensureRemote("CreatureArmAction")
-- Server -> the thrower's client: "launch this body from here at this velocity".
local launchRemote = ensureRemote("CreatureThrowLaunch")

local lastAction: { [Player]: number } = {}
local grabs: { [Model]: any } = {} -- [creatureRig] = { victim, weld, victimHum }

-- ============================================================
-- AIM RELAY
-- ============================================================
aimRemote.OnServerEvent:Connect(function(player, rise, yaw, extend, charge)
	if typeof(rise) ~= "number" or typeof(yaw) ~= "number" or typeof(extend) ~= "number" then
		return
	end
	if rise ~= rise or yaw ~= yaw or extend ~= extend then -- NaN
		return
	end

	local char = player.Character
	if not char or char:GetAttribute("IsCreature") ~= true then
		return
	end

	-- Up to 230, not 180: a charging throw cocks the arm back past straight up,
	-- and other players need to see that.
	char:SetAttribute("ArmRise", math.clamp(rise, 0, 230))
	char:SetAttribute("ArmYaw", math.clamp(yaw, -180, 180))
	char:SetAttribute("ArmExtend", math.clamp(extend, 0, 1))

	-- How far the victim has been lifted toward the mouth. Relayed so other
	-- clients see the partial lift rather than a body that teleports up at the
	-- moment of the bite.
	if typeof(charge) == "number" and charge == charge then
		char:SetAttribute("EatCharge", math.clamp(charge, 0, 1))
	end
end)

-- Forward declaration: doGrab (below) plays the grab sound, but the sound
-- helpers are defined further down next to the eat. Declared here so the
-- earlier function can see the local rather than creating a global.
local playCreatureSound

-- ============================================================
-- RELEASE
-- ============================================================
--[[
	The victim's own animation while they're held.

	Without this they keep playing whatever they were doing when grabbed ? usually
	the walk cycle, legs pumping in mid-air, which is the single thing that most
	gives away that they're a puppet on a weld.

	Played from the SERVER so every client sees it, at Action4 so it beats the walk
	cycle and anything else their own character scripts are running. Their
	CharacterMovement already bails out while the Grabbed attribute is set, so
	nothing is fighting this for the joints.
--]]
local function playVictimGrabAnim(victim: Model, hum: Humanoid, rig: Model?)
	--[[
		The animation id can come from the CREATURE's config, not a constant here.

		Which pose a victim hangs in depends on how the thing holding them holds
		them ? something that grabs you by the throat and something that has you by
		the ankle want different poses. So it belongs with the creature.
	--]]
	local assetId = VICTIM_GRAB_ANIM
	if rig then
		local module = rig:FindFirstChild("CreatureConfig")
		if module and module:IsA("ModuleScript") then
			local ok, cfg = pcall(require, module)
			if ok and typeof(cfg) == "table" and typeof(cfg.victimGrabAnim) == "string" then
				assetId = cfg.victimGrabAnim
			end
		end
	end

	if assetId == "" then
		return nil
	end

	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	local anim = Instance.new("Animation")
	anim.AnimationId = assetId

	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		return nil
	end

	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action4
	track:Play(VICTIM_GRAB_ANIM_FADE)
	return track
end

--[[
	NETWORK OWNERSHIP OF A WHOLE BODY, NOT JUST ITS ROOT.

	A ragdoll isn't one physics assembly: with its Motor6Ds off, every limb is its
	own assembly, joined to the others by ball sockets. SetNetworkOwner on the
	HumanoidRootPart only covered the torso's assembly -- the arms and legs stayed
	owned by the VICTIM's computer, so two clients were simulating the same body
	and fighting over it through the joints. Every part gets the same owner here.

	`owner` = a Player, nil for the server, or "auto" to hand it back to Roblox.
--]]
local function setBodyOwner(parts, owner)
	for _, part in ipairs(parts or {}) do
		if part.Parent and not part.Anchored then
			pcall(function()
				if owner == "auto" then
					part:SetNetworkOwnershipAuto()
				else
					part:SetNetworkOwner(owner)
				end
			end)
		end
	end
end

-- Weight back on, however the grab ends. See the note in doGrab.
local function restoreBodyWeight(grab)
	if grab.savedMassless then
		for part in pairs(grab.savedMassless) do
			if part.Parent then
				part.Massless = false
			end
		end
		grab.savedMassless = nil
	end
	if grab.savedPhysics then
		for part, props in pairs(grab.savedPhysics) do
			if part.Parent then
				part.CustomPhysicalProperties = props or nil
			end
		end
		grab.savedPhysics = nil
	end
	if grab.savedFriction then
		for joint, torque in pairs(grab.savedFriction) do
			if joint.Parent then
				joint.MaxFrictionTorque = torque
			end
		end
		grab.savedFriction = nil
	end
end

--[[
	Everything a SURVIVOR gets back: standing up, walking, their own physics, their
	tools. Split out of releaseVictim because a thrown victim gets it LATER -- two
	seconds after they land -- rather than the moment they leave the hand.
--]]
local function restoreSurvivor(grab)
	local victim = grab.victim

	if grab.toolBlock then
		grab.toolBlock:Disconnect()
		grab.toolBlock = nil
	end

	if not (victim and victim.Parent) then
		return
	end

	local hum = grab.victimHum
	if not (hum and hum.Parent and hum.Health > 0) then
		return
	end

	-- Only a survivor gets up. A corpse has its own ragdoll path through
	-- HandleDeath, and un-ragdolling it would stand the body back up mid-death.
	if grab.ragdolled then
		local control = ServerStorage:FindFirstChild("RagdollControl")
		if control and control:IsA("BindableEvent") then
			control:Fire(victim, false)
		end
	end

	hum.PlatformStand = false
	hum.WalkSpeed = grab.savedWalkSpeed or 16
	hum.JumpPower = grab.savedJumpPower or 50

	-- Only re-anchor on a survived release. Re-anchoring a corpse would freeze the
	-- ragdoll mid-air.
	if grab.savedAnchored then
		for part, wasAnchored in pairs(grab.savedAnchored) do
			if wasAnchored and part.Parent then
				part.Anchored = true
			end
		end
	end

	-- Hand physics back to the victim's own client (every limb, see setBodyOwner).
	local vplayer = Players:GetPlayerFromCharacter(victim)
	setBodyOwner(grab.heldParts, vplayer or "auto")
end

-- Collisions come back either way, including on death -- a corpse with no
-- collision falls straight through the floor.
local function restoreCollisions(grab)
	if grab.savedCollide then
		for part, wasCollide in pairs(grab.savedCollide) do
			if wasCollide and part.Parent then
				part.CanCollide = true
			end
		end
	end
end

--[[
	`thrown` = the victim is leaving the hand through the air rather than being
	put down. They stay ragdolled, keep no collision for a moment (so they don't
	clip the creature on the way out), and don't get up until the throw code says
	so. Returns the grab record so the throw can finish the job.
--]]
local function releaseVictim(rig: Model, killed: boolean, thrown: boolean?)
	local grab = grabs[rig]
	if not grab then
		return nil
	end
	grabs[rig] = nil

	if grab.weld then
		grab.weld:Destroy()
	end

	-- Stopped whichever way the grab ends. A dropped survivor walking away still
	-- limp in the carry pose is as wrong as a corpse would be.
	if grab.victimTrack then
		pcall(function()
			grab.victimTrack:Stop(VICTIM_GRAB_ANIM_FADE)
		end)
	end

	local victim = grab.victim
	if victim and victim.Parent then
		victim:SetAttribute("Grabbed", false)
		victim:SetAttribute("GrabbedBy", nil)

		if not thrown then
			restoreCollisions(grab)
		end

		-- Weight back BEFORE any kill below, so the corpse clone the ragdoll makes
		-- falls like a body rather than floating like a Massless one. A thrown
		-- body needs its weight too, or it flies like a paper bag.
		restoreBodyWeight(grab)

		local hum = grab.victimHum
		if killed then
			if grab.toolBlock then
				grab.toolBlock:Disconnect()
				grab.toolBlock = nil
			end
			if hum and hum.Parent then
				hum.PlatformStand = false
				hum.Health = 0
			end
		elseif not thrown then
			restoreSurvivor(grab)
		end
	elseif grab.toolBlock then
		grab.toolBlock:Disconnect()
		grab.toolBlock = nil
	end

	rig:SetAttribute("CreatureGrabbing", false)
	rig:SetAttribute("GrabVictim", nil)
	return grab
end

-- ============================================================
-- GRAB
-- ============================================================
-- Any model with a Humanoid is edible: player characters AND plain R6 dummies.
-- Tagged models are found at any depth; untagged ones must be top-level children
-- of Workspace, which keeps the sweep cheap on a full map.
local GRABBABLE_TAG = "Grabbable"

local function isValidVictim(rig: Model, model: Instance): (Humanoid?, BasePart?)
	if model == rig or not model:IsA("Model") then
		return nil, nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (hum and root and root:IsA("BasePart")) then
		return nil, nil
	end
	if hum.Health <= 0 or model:GetAttribute("IsCorpse") == true then
		return nil, nil
	end
	if CreatureUtil.IsCreature(model) then
		return nil, nil
	end
	if model:GetAttribute("Grabbed") == true then
		return nil, nil
	end
	-- Mid-throw or still down from one. Snatching them out of the air would
	-- chain-lock a player in the ragdoll forever.
	if model:GetAttribute("Thrown") == true then
		return nil, nil
	end
	return hum, root
end

--[[
	THE VICTIM REGISTRY.

	findVictim used to scan `workspace:GetChildren()` ? TOP LEVEL ONLY. Move your
	dummies into an NPCs folder and the server stopped finding any of them, so
	every grab was rejected no matter what the client aimed at.

	A full descendant walk per grab would be correct and far too expensive on a
	real map. So: one deep scan at startup, then DescendantAdded/Removing keep the
	set current. Depth stops mattering; a grab check iterates only live humanoids.

	The client has an identical registry in its Arm module. Both halves have to
	agree on who exists, or the arm reaches for someone the server won't allow.
--]]
local victims: { [Humanoid]: Model } = {}

local function registerHumanoid(inst: Instance)
	if not inst:IsA("Humanoid") then
		return
	end
	local model = inst.Parent
	if model and model:IsA("Model") then
		victims[inst] = model
	end
end

local function unregisterHumanoid(inst: Instance)
	if inst:IsA("Humanoid") then
		victims[inst] = nil
	end
end

do
	for _, d in ipairs(workspace:GetDescendants()) do
		registerHumanoid(d)
	end
	workspace.DescendantAdded:Connect(registerHumanoid)
	workspace.DescendantRemoving:Connect(unregisterHumanoid)
end

local function findVictim(rig: Model): (Model?, Humanoid?)
	local root = rig:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, nil
	end

	local origin = root.Position
	local forward = root.CFrame.LookVector
	local maxCos = math.cos(math.rad(GRAB_CONE_ANGLE))

	local best, bestHum, bestScore = nil, nil, math.huge

	local function consider(model: Instance)
		local hum, oroot = isValidVictim(rig, model)
		if not (hum and oroot) then
			return
		end
		local offset = oroot.Position - origin
		local dist = offset.Magnitude
		if dist > GRAB_RANGE or dist <= 0.1 then
			return
		end
		local dot = forward:Dot(offset.Unit)
		if dot < maxCos then
			return
		end
		local score = dist * (2 - dot)
		if score < bestScore then
			best, bestHum, bestScore = model, hum, score
		end
	end

	for _, model in ipairs(CollectionService:GetTagged(GRABBABLE_TAG)) do
		if model:IsDescendantOf(workspace) then
			consider(model)
		end
	end

	for hum, model in pairs(victims) do
		if hum.Parent ~= model then
			-- Reparented since we saw it; drop the stale row rather than trust it.
			victims[hum] = nil
		elseif model.Parent then
			consider(model)
		end
	end

	return best, bestHum
end

local runAction  -- forward declaration; defined once doGrab/doEat/releaseVictim exist

local function doGrab(player: Player?, rig: Model)
	if grabs[rig] then
		return
	end

	local victim, victimHum = findVictim(rig)
	if not (victim and victimHum) then
		return
	end

	local arm = rig:FindFirstChild("Right Arm")
	local vroot = victim:FindFirstChild("HumanoidRootPart")
	if not (arm and vroot) then
		return
	end

	-- PlatformStand is what actually takes control away: it stops the victim's
	-- Humanoid driving its own physics, so the weld wins. Zeroing WalkSpeed alone
	-- would not ? their movement script writes WalkSpeed every frame.
	local savedWalkSpeed = victimHum.WalkSpeed
	local savedJumpPower = victimHum.JumpPower
	victimHum.PlatformStand = true

	-- Test dummies are very often anchored. An anchored part cannot be moved by a
	-- weld, so the grab would appear to do nothing at all ? the single most
	-- confusing failure in this whole system. Unanchor, remembering what to put
	-- back if they escape the grab by some other route.
	local savedAnchored = {}
	for _, part in ipairs(victim:GetDescendants()) do
		if part:IsA("BasePart") and part.Anchored then
			savedAnchored[part] = true
			part.Anchored = false
		end
	end

	-- Collisions off while held. A welded body that still collides grinds against
	-- the creature's own limbs, and the solver answers by shoving them apart ?
	-- which shows up as the victim juddering in the hand and sinking into the arm.
	-- Turning collision off is what makes the hold sit still.
	local savedCollide = {}
	for _, part in ipairs(victim:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			savedCollide[part] = true
			part.CanCollide = false
		end
	end

	--[[
		THE HELD BODY MUST NOT PUSH THE CREATURE AROUND.

		Welded to the arm, the victim becomes part of the creature's own physics
		assembly. Two things then wreck the creature's movement:

		  * COLLISION. The ragdoll switches its ColliderParts and Head back ON when it
		    goes limp (Ragdoll.luau's SetLimbsLoose), after the loop above has already
		    run. A dangling body scraping the floor or jammed against the creature's
		    own legs drags and shoves the whole creature.
		  * MASS. A full body hanging off one arm is extra weight on one side of the
		    creature, swinging on ball sockets, which the Humanoid has to fight every
		    step.

		So every part of the victim is made Massless now, and heldParts is enforced
		non-colliding EVERY FRAME by the loop at the bottom of this file. Every frame
		rather than once, because the ragdoll's own handler runs after this (deferred
		signals) and turns the colliders back on.

		Both are undone in releaseVictim before the victim dies or is dropped.
	--]]
	--[[
		MASSLESS ISN'T ENOUGH ON ITS OWN. Roblox only honours Massless on a part
		that is WELDED to something with mass. Once the ragdoll goes limp, only the
		gripped limb is welded to the creature -- the torso, head and legs hang off
		it through ball sockets as separate assemblies, and at full weight. That
		dangling weight is what made the creature turn around the victim instead of
		around itself.

		So every part is also dropped to the lowest density Roblox allows. The body
		still swings and dangles exactly the same; it just weighs next to nothing.
	--]]
	local LIGHT = PhysicalProperties.new(0.01, 0.3, 0)

	--[[
		JOINT FRICTION OFF WHILE HELD. The ragdoll's joints have a little friction
		so a normal body settles instead of flailing. On a body this light,
		that same friction is enough to lock every joint -- the victim hung in
		the hand like a statue. Zeroed here, put back on release, so the body
		dangles freely in the hand and has its proper weight and friction again
		the moment it's thrown or dropped.
	--]]
	local savedFriction = {}
	for _, d in ipairs(victim:GetDescendants()) do
		if d:IsA("BallSocketConstraint") and d.MaxFrictionTorque > 0 then
			savedFriction[d] = d.MaxFrictionTorque
			d.MaxFrictionTorque = 0
		end
	end
	local heldParts = {}
	local savedMassless = {}
	local savedPhysics = {}
	for _, part in ipairs(victim:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(heldParts, part)
			if not part.Massless then
				savedMassless[part] = true
				part.Massless = true
			end
			savedPhysics[part] = part.CustomPhysicalProperties or false
			part.CustomPhysicalProperties = LIGHT
		end
	end

	victim:SetAttribute("Grabbed", true)
	victim:SetAttribute("GrabbedBy", rig.Name)

	--[[
		NO WEAPONS IN THE HAND.

		Whatever they were holding goes back to their Backpack (never destroyed, so
		nothing is lost if they're dropped), and anything they try to equip while held
		is sent straight back. Their client hides the inventory bar too
		(GrabbedInventoryLock), but that's only the UI: this is the part that actually
		stops a gun being fired from inside the creature's fist.

		Players only. An NPC dummy has no Backpack to put things in.
	--]]
	local toolBlock
	local victimPlayer = Players:GetPlayerFromCharacter(victim)
	if victimPlayer then
		victimHum:UnequipTools()
		toolBlock = victim.ChildAdded:Connect(function(child)
			if not child:IsA("Tool") then
				return
			end
			-- Deferred: reparenting inside the ChildAdded that announced it fights
			-- the equip that is still in progress.
			task.defer(function()
				if child.Parent == victim then
					local backpack = victimPlayer:FindFirstChildOfClass("Backpack")
					if backpack then
						child.Parent = backpack
					end
				end
			end)
		end)
	end

	-- The grabber's client owns the victim's physics while held, so the carry is
	-- smooth on the screen that matters most. Ownership returns on release.
	setBodyOwner(heldParts, player)

	--[[
		WHAT THE HAND ACTUALLY HAS HOLD OF.

		Welding the ROOT means the creature holds them by the middle and the whole
		body pivots about that point. Welding a LIMB means that limb is the fixed
		point and everything else hangs off it through the shoulder constraint ?
		which, once they're ragdolled, is the difference between carrying someone
		and having them dangle from one arm.

		Falls back to the root if the limb is missing, so a rig built differently
		still gets grabbed rather than silently failing.
	--]]
	local heldPart = victim:FindFirstChild(GRAB_LIMB)
	if not (heldPart and heldPart:IsA("BasePart")) then
		heldPart = victim:FindFirstChild(GRAB_LIMB_FALLBACK)
	end
	if not (heldPart and heldPart:IsA("BasePart")) then
		heldPart = vroot
	end

	local weld = Instance.new("Weld")
	weld.Name = "CreatureGrabWeld"
	weld.Part0 = arm
	weld.Part1 = heldPart

	-- C0 = where on the ARM the grip is. An Attachment placed by hand in Studio
	-- beats any number we could pick here, so it wins when present.
	local holdAtt = arm:FindFirstChild(GRAB_HOLD_ATTACHMENT)
	if holdAtt and holdAtt:IsA("Attachment") then
		if GRAB_HOLD_ATTACHMENT_ROTATION then
			weld.C0 = holdAtt.CFrame -- position AND orientation from the attachment
		else
			-- Position from the attachment, rotation from the constants. Lets you
			-- drag the attachment anywhere without its own orientation (which
			-- starts at 0,0,0 and looks flat) wrecking the pose.
			weld.C0 = CFrame.new(holdAtt.Position) * GRAB_HOLD_ROTATION
		end
	else
		weld.C0 = GRAB_HOLD_OFFSET
	end

	-- C1 = where on the held part the hand closes. For a limb that's near its top
	-- end; for the root fallback it's the old offset up the torso, which put the
	-- hand at shoulder height rather than glued to their middle.
	if heldPart == vroot then
		weld.C1 = CFrame.new(0, GRAB_VICTIM_GRIP_HEIGHT, 0)
	else
		weld.C1 = CFrame.new(GRAB_LIMB_GRIP)
	end

	weld.Parent = arm

	grabs[rig] = {
		victim = victim,
		victimHum = victimHum,
		weld = weld,
		savedWalkSpeed = savedWalkSpeed,
		savedJumpPower = savedJumpPower,
		savedAnchored = savedAnchored,
		savedCollide = savedCollide,
		savedMassless = savedMassless,
		savedPhysics = savedPhysics,
		savedFriction = savedFriction,
		owner = player,
		heldParts = heldParts,
		toolBlock = toolBlock,
		eatSession = 0,
		heldPart = heldPart,
		ragdolled = false,
		-- Skipped entirely while ragdolling: motors are off, so a track would load,
		-- play, and move nothing.
		victimTrack = (not GRAB_RAGDOLL) and playVictimGrabAnim(victim, victimHum, rig) or nil,
	}

	if GRAB_RAGDOLL then
		local control = ServerStorage:FindFirstChild("RagdollControl")
		if control and control:IsA("BindableEvent") then
			control:Fire(victim, true)
			grabs[rig].ragdolled = true
		else
			-- Not fatal. Without the patched Ragdoll.luau the victim just hangs
			-- rigid, which is the behaviour that existed before this option.
			warn("[CreatureGrabServer] ServerStorage.RagdollControl missing ? "
				.. "is Ragdoll.luau the patched version? Holding rigid instead.")
		end
	end

	rig:SetAttribute("CreatureGrabbing", true)
	rig:SetAttribute("GrabVictim", victim.Name)

	playCreatureSound(rig, "Grab")

	-- If the victim dies or despawns some other way, let go rather than dragging
	-- a corpse around welded to the arm.
	local diedConn
	diedConn = victimHum.Died:Connect(function()
		diedConn:Disconnect()
		releaseVictim(rig, false)
	end)

	victim.AncestryChanged:Once(function(_, parent)
		if not parent then
			releaseVictim(rig, false)
		end
	end)
end

-- ============================================================
-- EAT
-- ============================================================
-- ============================================================
-- SOUNDS
-- ============================================================
-- Played from the SERVER, so they replicate to every client automatically ? the
-- same reason the breathing lives on the server.
-- Sounds live at ReplicatedStorage.CreatureSounds.<soundSet>.Grab and .Eat, as
-- flat folders of Sounds (no material subfolders ? biting someone sounds the same
-- whatever they happen to be standing on).
-- ============================================================
-- DECAPITATION
-- ============================================================
local DECAPITATE_ON_EAT = true
local DECAPITATE_DELAY = 0.05  -- seconds after the bite; small, so it reads as
-- part of the same moment rather than a sequel

--[[
	CATCH THE RAGDOLL CLONE.

	Armed BEFORE the victim is killed, because Ragdoll.luau's HandleDeath runs
	synchronously on Humanoid.Died and the clone exists before Health = 0 has even
	returned. Connecting afterwards would miss it every time.

	Matching by name is crude but it's what the ragdoll gives us: it names the
	clone "DeadBody" (RagdollMod uses "<name>_Dead"). To stop two simultaneous
	deaths stealing each other's corpse, the match also checks the model is near
	where this victim actually was.
--]]
local function captureCorpse(victim: Model, near: Vector3, onFound)
	local conn
	local done = false

	local function consider(child: Instance)
		if done or not child:IsA("Model") then
			return
		end

		local matches = false
		for _, suffix in ipairs(CORPSE_MODEL_NAMES) do
			if child.Name == suffix or string.find(child.Name, suffix, 1, true) then
				matches = true
				break
			end
		end
		if not matches then
			return
		end

		-- The ragdoll now builds the corpse by MOVING the real parts into an
		-- empty model that's already in Workspace, so this can fire a moment
		-- before the parts arrive. Give it a beat rather than rejecting it.
		task.spawn(function()
			local root = child:FindFirstChild("HumanoidRootPart")
				or child:FindFirstChildWhichIsA("BasePart")
			local waited = 0
			while not root and waited < 0.5 and child.Parent do
				task.wait(0.05)
				waited += 0.05
				root = child:FindFirstChild("HumanoidRootPart")
					or child:FindFirstChildWhichIsA("BasePart")
			end
			if done or not root then
				return
			end
			-- Generous, in case the corpse isn't quite where the victim was.
			if (root.Position - near).Magnitude > 60 then
				return
			end

			done = true
			if conn then
				conn:Disconnect()
			end
			onFound(child)
		end)
	end

	conn = workspace.ChildAdded:Connect(consider)

	-- Give up rather than leaking a connection if the ragdoll never produces one
	-- (a victim with no Ragdoll script, an NPC dummy, a different death path).
	task.delay(CORPSE_WAIT, function()
		if not done and conn then
			conn:Disconnect()
		end
	end)
end

--[[
	Put the corpse where the player SAW the victim die, and let it fall from there.

	The server's idea of where the body was is wrong by design ? the arm that was
	holding it is posed entirely on the clients. So rather than trying to replicate
	the arm, the corpse is simply placed at the mouth attachment, which is the one
	point every client agrees the victim had been brought to.

	The small velocity matters: a body that appears and drops from a dead stop
	reads as a spawned prop. One already moving reads as something released.
--]]
local function dropCorpseAt(corpse: Model, atCFrame: CFrame)
	if not (corpse and corpse.Parent) then
		return
	end

	-- Any weld cloned along with the body still points at the creature's arm, which
	-- would leave the corpse hanging off it forever. The original is destroyed in
	-- releaseVictim; this is its twin inside the clone.
	for _, d in ipairs(corpse:GetDescendants()) do
		if d:IsA("Weld") or d:IsA("WeldConstraint") then
			local p0, p1 = d.Part0, d.Part1
			local outside = (p0 and not p0:IsDescendantOf(corpse))
				or (p1 and not p1:IsDescendantOf(corpse))
			if outside then
				d:Destroy()
			end
		end
	end

	local ok = pcall(function()
		corpse:PivotTo(atCFrame * CFrame.new(CORPSE_DROP_OFFSET))
	end)
	if not ok then
		return
	end

	for _, d in ipairs(corpse:GetDescendants()) do
		if d:IsA("BasePart") and not d.Anchored then
			d.AssemblyLinearVelocity = CORPSE_DROP_VELOCITY
		end
	end
end

--[[
	Take the victim's head off.

	ORDER MATTERS. Destroying a Head kills the Humanoid by itself ? the Neck joint
	goes with it and the character falls apart. So this runs AFTER releaseVictim
	has already set Health to 0 and unwelded them. Do it the other way round and
	the Died signal fires while the grab is still live, the watchdog releases them
	as a survivor, and the kill you actually wanted never happens.

	Anything riding the head goes too. A floating hat, or hair hanging in the air
	where a head used to be, is worse than leaving the head on ? so hats, hair
	morphs and anything else welded to the head are destroyed with it.

	The Neck is deliberately not caught by that rule: it joins the head to the
	TORSO, and the torso is not a hat.
--]]
local function decapitate(victim: Model)
	if not (victim and victim.Parent) then
		return
	end

	local head = victim:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return
	end

	local doomed = {}

	-- Anything joined to the head by a weld of any kind.
	for _, d in ipairs(victim:GetDescendants()) do
		if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
			local other
			if d.Part0 == head then
				other = d.Part1
			elseif d.Part1 == head then
				other = d.Part0
			end

			if other and other ~= head then
				-- Walk up to whatever container sits directly under the character,
				-- so a hair morph is removed as one model rather than one mesh.
				local top = other
				while top.Parent and top.Parent ~= victim do
					top = top.Parent
				end
				-- A bare BasePart here is the Torso (via the Neck) ? left alone.
				if top:IsA("Accessory") or (top:IsA("Model") and top ~= victim) then
					doomed[top] = true
				end
			end
		end
	end

	-- Accessories attached the normal way: a Handle Attachment whose name also
	-- exists on the head is exactly how Roblox decides a hat goes on a head.
	for _, child in ipairs(victim:GetChildren()) do
		if child:IsA("Accessory") then
			local handle = child:FindFirstChild("Handle")
			if handle then
				for _, att in ipairs(handle:GetChildren()) do
					if att:IsA("Attachment") and head:FindFirstChild(att.Name) then
						doomed[child] = true
						break
					end
				end
			end
		end
	end

	for inst in pairs(doomed) do
		if inst.Parent then
			inst:Destroy()
		end
	end

	-- Decals, face plates and meshes parented inside the head go with it.
	head:Destroy()
end

-- ============================================================
-- BLOOD
-- ============================================================
-- Put your ParticleEmitters INSIDE the MouthAttachment. An emitter parented to an
-- Attachment emits from that attachment's position, so they follow the mouth for
-- free ? no positioning code, and they move with the head turn.
--
-- Leave every emitter's Enabled = false. Emit() fires a one-off burst regardless
-- of Enabled, which is exactly what you want here: a burst on the bite, not a
-- constant dribble the rest of the time.
--
-- Per-emitter tuning, set as ATTRIBUTES on the emitter itself in Studio:
--     EmitCount  (number) how many particles this burst   -- default below
--     EmitDelay  (number) seconds to wait first           -- default 0
-- The delay is what lets you stage it: a spray at 0, a heavier drip at 0.2.
local BLOOD_DEFAULT_COUNT = 25

local function getMouthAttachment(rig: Model): Attachment?
	local name = "MouthAttachment"
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, cfg = pcall(require, module)
		if ok and typeof(cfg) == "table" and typeof(cfg.mouthAttachmentName) == "string" then
			name = cfg.mouthAttachmentName
		end
	end

	for _, partName in ipairs({ "Head", "HumanoidRootPart", "Torso" }) do
		local part = rig:FindFirstChild(partName)
		if part then
			local att = part:FindFirstChild(name)
			if att and att:IsA("Attachment") then
				return att
			end
		end
	end
	return nil
end

--[[
	TWO BLOOD SETS, ONE ATTACHMENT ? GROUPED BY NAME, NOT BY FOLDER.

	    MouthAttachment
	    +-- BiteBlood_Spray     ? fire on each chewing crunch
	    +-- BiteBlood_Mist      ?
	    +-- KillBlood_Burst     ? fire on the killing bite
	    +-- KillBlood_Gush      ?

	NOT folders. A ParticleEmitter has to be a direct child of a BasePart or an
	Attachment ? that is what gives it a position in the world. Put one inside a
	Folder and it has nowhere to emit from, so it renders nothing at all, while
	Emit() still returns perfectly happily. Silent and total.

	So the grouping is by name prefix: anything starting "BiteBlood" is crunch
	spatter, anything starting "KillBlood" is the kill burst. An emitter matching
	neither fires on BOTH, which keeps an older loose setup working.

	An attribute `BloodGroup` of "Bite" or "Kill" overrides the name, for when you
	would rather not rename things.
--]]
local function bloodGroupOf(emitter: ParticleEmitter): string?
	local tag = emitter:GetAttribute("BloodGroup")
	if typeof(tag) == "string" then
		local lowered = string.lower(tag)
		if lowered == "bite" then return "Bite" end
		if lowered == "kill" then return "Kill" end
	end

	local name = string.lower(emitter.Name)
	if string.sub(name, 1, 9) == "biteblood" then return "Bite" end
	if string.sub(name, 1, 9) == "killblood" then return "Kill" end

	return nil -- ungrouped: belongs to both
end

-- Warned once per rig, not per burst, or a chew would print four times a crunch.
local warnedFolders: { [Model]: boolean } = {}

local function emitBlood(rig: Model, group: string?, scale: number?)
	local att = getMouthAttachment(rig)
	if not att then
		return
	end

	scale = scale or 1

	-- Direct children only. Anything deeper is, by definition, inside something
	-- that isn't an Attachment, and therefore isn't rendering.
	local fired = 0
	for _, emitter in ipairs(att:GetChildren()) do
		if emitter:IsA("ParticleEmitter") then
			local emitterGroup = bloodGroupOf(emitter)

			-- nil group = ungrouped, fires for everything.
			if group == nil or emitterGroup == nil or emitterGroup == group then
				local count = emitter:GetAttribute("EmitCount")
				if typeof(count) ~= "number" then
					count = BLOOD_DEFAULT_COUNT
				end
				count = math.max(1, math.round(count * scale))

				local delay = emitter:GetAttribute("EmitDelay")
				if typeof(delay) ~= "number" or delay <= 0 then
					emitter:Emit(count)
				else
					task.delay(delay, function()
						-- The creature may have died or despawned during the delay,
						-- and emitting from a destroyed emitter errors.
						if emitter.Parent then
							emitter:Emit(count)
						end
					end)
				end
				fired += 1
			end
		end
	end

	-- The specific mistake that produces "no particles at all", called out by name
	-- rather than left as silence.
	if fired == 0 and not warnedFolders[rig] then
		warnedFolders[rig] = true

		local buried = 0
		for _, d in ipairs(att:GetDescendants()) do
			if d:IsA("ParticleEmitter") and d.Parent ~= att then
				buried += 1
			end
		end

		if buried > 0 then
			warn(("[CreatureGrabServer] %d ParticleEmitter(s) under %s are inside a Folder. ")
				:format(buried, att:GetFullName())
				.. "An emitter must be a DIRECT child of the Attachment or it has no "
				.. "position and renders nothing. Move them up and rename them "
				.. "BiteBlood... / KillBlood... instead of foldering them.")
		else
			warn(("[CreatureGrabServer] No ParticleEmitters directly under %s.")
				:format(att:GetFullName()))
		end
	end
end

local function getSoundSetName(rig: Model): string
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, cfg = pcall(require, module)
		if ok and typeof(cfg) == "table" and typeof(cfg.soundSet) == "string" then
			return cfg.soundSet
		end
	end
	return "Stalker"
end

function playCreatureSound(rig: Model, folderName: string)
	local soundsRoot = ReplicatedStorage:FindFirstChild("CreatureSounds")
	if not soundsRoot then
		return
	end
	local set = soundsRoot:FindFirstChild(getSoundSetName(rig))
	if not set then
		return
	end
	local folder = set:FindFirstChild(folderName)
	if not (folder and folder:IsA("Folder")) then
		return
	end

	local options = {}
	for _, s in ipairs(folder:GetChildren()) do
		if s:IsA("Sound") then
			table.insert(options, s)
		end
	end
	if #options == 0 then
		return
	end

	local parent = rig:FindFirstChild("Head") or rig:FindFirstChild("HumanoidRootPart")
	if not parent then
		return
	end

	local template = options[math.random(1, #options)]
	local snd = template:Clone()
	snd.Looped = false
	snd.PlaybackSpeed = template.PlaybackSpeed * (math.random(92, 106) / 100)
	snd.Parent = parent
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	-- Belt and braces: a sound that fails to load never fires Ended, and would
	-- otherwise sit in the rig forever.
	task.delay(10, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

local function doEat(rig: Model)
	local grab = grabs[rig]
	if not grab then
		return
	end
	if rig:GetAttribute("CreatureEating") == true then
		return
	end

	-- The arm is already at the mouth by the time this runs ? the client held the
	-- button long enough to put it there. CreatureEating pins it there through the
	-- bite so it can't sag while the victim is being killed.
	rig:SetAttribute("CreatureEating", true)

	--[[
		A token for THIS eat.

		Cancelling can't just check "is the victim still held" ? they are, that's
		the point of a cancel. So every scheduled crunch and the killing bite carry
		the session they belong to, and a cancel bumps it. Anything still queued
		from the abandoned eat finds a mismatch and quietly does nothing, instead
		of landing a crunch on somebody you decided to spare.
	--]]
	local session = (grab.eatSession or 0) + 1
	grab.eatSession = session

	local function sessionLive(): boolean
		local g = grabs[rig]
		return g ~= nil and g.eatSession == session and rig.Parent ~= nil
	end

	-- Published for the clients to drive the arm jolts from. One timestamp and two
	-- numbers is the whole sync: every client computes the same shake.
	rig:SetAttribute("ChewStart", workspace:GetServerTimeNow())
	rig:SetAttribute("ChewInterval", CHEW_INTERVAL)
	rig:SetAttribute("ChewCount", CHEW_COUNT)

	--[[
		The crunches. Each one is a sound, a small spatter and a bite of health.

		Scheduled individually rather than in a loop with waits, so a creature that
		dies or despawns partway through simply stops ? each one re-checks that the
		grab is still live before doing anything.
	--]]
	for i = 1, CHEW_COUNT do
		task.delay(CHEW_INTERVAL * (i - 1) + 0.05, function()
			if not sessionLive() then
				return -- cancelled, or a different eat has started since
			end
			local grab = grabs[rig]

			playCreatureSound(rig, "Chew")
			emitBlood(rig, "Bite", CHEW_BLOOD_SCALE)

			local hum = grab.victimHum
			if hum and hum.Parent and hum.Health > 0 then
				-- Floored at 1: the final bite is what kills. A victim who died on
				-- crunch three would trip the Died handler, release early, and
				-- leave the creature chewing on an empty hand.
				local damage = hum.MaxHealth * CHEW_DAMAGE_FRACTION
				hum.Health = math.max(1, hum.Health - damage)
			end
		end)
	end

	-- The bite: sound and death together, once the arm has reached the mouth.
	task.delay(EAT_BITE_TIME, function()
		-- Re-checked rather than assumed: the victim may have died, despawned,
		-- been released by the watchdog, or had the eat CANCELLED during the chew.
		-- Killing someone the player deliberately let go of is the worst of those.
		if not sessionLive() then
			return
		end

		-- Grabbed before the release, because releaseVictim clears the record.
		local victim = grabs[rig].victim

		playCreatureSound(rig, "Eat")
		emitBlood(rig, "Kill")

		--[[
			ARMED BEFORE THE KILL, not after.

			Ragdoll.luau's HandleDeath runs synchronously on Humanoid.Died, so the
			"DeadBody" clone exists before the line that sets Health = 0 has even
			returned. Connecting to ChildAdded afterwards misses it every time ?
			which is exactly why the head never came off and the body appeared on
			the floor.
		--]]
		local mouth = getMouthAttachment(rig)
		local dropAt = mouth and mouth.WorldCFrame
		local victimRoot = victim and victim:FindFirstChild("HumanoidRootPart")
		local near = (victimRoot and victimRoot.Position)
			or (dropAt and dropAt.Position)
			or Vector3.zero

		if victim then
			captureCorpse(victim, near, function(corpse)
				-- Both fixes land on the CLONE, because the clone is the body the
				-- player can actually see.
				if dropAt then
					dropCorpseAt(corpse, dropAt)
				end
				if DECAPITATE_ON_EAT then
					task.delay(DECAPITATE_DELAY, function()
						decapitate(corpse)
					end)
				end
			end)
		end

		releaseVictim(rig, true) -- true = the victim dies

		--[[
			Fallback for a victim with no ragdoll clone at all ? a plain R6 dummy,
			an NPC, anything whose death doesn't go through Ragdoll.luau. There the
			original body IS the corpse, so it gets the same treatment directly.
		--]]
		if victim then
			task.delay(CORPSE_WAIT, function()
				if victim.Parent and victim:FindFirstChild("Head") then
					local root = victim:FindFirstChild("HumanoidRootPart")
					-- Anchored means Ragdoll.luau hid it and a clone took over, so
					-- there is nothing here worth touching.
					if root and not root.Anchored then
						if dropAt then
							dropCorpseAt(victim, dropAt)
						end
						if DECAPITATE_ON_EAT then
							decapitate(victim)
						end
					end
				end
			end)
		end
	end)

	task.delay(EAT_TOTAL_TIME, function()
		-- Only this session may clear the flags. A cancel followed by a fresh eat
		-- would otherwise have the OLD timer switch off the NEW one partway through.
		if sessionLive() or (rig.Parent and grabs[rig] == nil) then
			rig:SetAttribute("CreatureEating", false)
			-- Cleared so a later eat can't inherit a stale chew window and shake
			-- the arm on a victim that isn't being chewed yet.
			rig:SetAttribute("ChewStart", nil)
		end
	end)
end

-- ============================================================
-- THROW
-- ============================================================
--[[
	Hold right click while carrying someone to aim (the Arm system draws the arc),
	left click to throw. A tap of right click still just drops them.

	THE ARC HAS TO MATCH. The creature's client draws the trajectory from exactly
	the same origin and launch velocity this computes, with the same numbers out of
	CreatureConfig, so where the line lands is where the body lands. That's also
	why the body is MOVED to that origin before it's launched: the server's copy of
	the arm is at rest by the hip (the pose is client-side only), so launching from
	where the server thinks the victim is would start the arc a few studs off.

	    throwVelocity(rig, cfg, lookDir) -> origin, velocity

	If you change the math here, change computeThrow in Arm to match.

	THE LANDING. The body flies ragdolled with the server owning its physics.
	The first real impact -- a floor, a wall, a tree -- does throwDamage, and from
	that moment they stay ragdolled for throwRagdollTime before getting up.
--]]
local THROW_DEFAULTS = {
	throwSpeedMin = 45,       -- studs/s at launch with no charge
	throwSpeedMax = 140,      -- studs/s fully charged
	throwChargeTime = 1.2,    -- seconds of holding right click for full charge
	throwAimDelay = 0.12,     -- the hold before charging starts (matches Arm)
	throwWindupMin = 0.07,    -- wind-up left to do when fully charged
	throwUpBias = 14,         -- deg added to your aim, so a level aim still arcs
	throwMinPitch = -20,      -- deg; can't spike them straight into the floor
	throwMaxPitch = 65,
	throwOriginUp = 1.5,      -- launch point, relative to the creature's root
	throwOriginRight = 1.5,
	throwDamage = 75,         -- on the first impact. Massive on purpose.
	throwKillCharge = 0.85,   -- a throw charged at least this much KILLS on impact
	throwRagdollTime = 2,     -- seconds down after that impact

	-- BOWLING: people the flying body passes through get knocked flat.
	throwKnockRadius = 4,     -- studs from the flying body that counts as a hit
	throwKnockMinSpeed = 25,  -- the body must be moving at least this fast to knock anyone
	throwKnockTime = 3,       -- seconds they stay ragdolled
	throwKnockForce = 0.6,    -- how much of the body's speed they're sent flying with
	throwKnockDamage = 10,    -- damage to each person hit (0 = none)

	-- The arm animation (played by the Arm system on every client). The body
	-- leaves the hand partway through the whip, so these set WHEN it's released.
	throwWindupTime = 0.34,   -- arm cocks back and up
	throwWhipTime = 0.12,     -- arm snaps forward
	throwReleaseAt = 0.65,    -- 0-1 through the whip: the moment they leave the hand
	throwFollowTime = 0.3,    -- follow-through before the arm settles
}

local THROW_NO_COLLIDE = 0.2      -- s of no collision after release, to clear the creature
local THROW_IMPACT_DROP = 22      -- studs/s of speed lost in one frame = hit something
local THROW_GROUND_RAY = 3.2      -- studs under the root that counts as landed
local THROW_MAX_FLIGHT = 6        -- failsafe: counts as landed after this (no damage)

local function throwConfigOf(rig: Model)
	local cfg = table.clone(THROW_DEFAULTS)
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, userCfg = pcall(require, module)
		if ok and typeof(userCfg) == "table" then
			for k in pairs(THROW_DEFAULTS) do
				if typeof(userCfg[k]) == "number" then
					cfg[k] = userCfg[k]
				end
			end
		end
	end
	return cfg
end

local function windupDuration(cfg, charge: number): number
	return math.max(cfg.throwWindupMin, cfg.throwWindupTime * (1 - math.clamp(charge, 0, 1)))
end

local function throwVelocity(rig: Model, cfg, lookDir: Vector3, charge: number?): (Vector3?, Vector3?)
	local root = rig:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil, nil
	end

	local origin = root.Position
		+ Vector3.new(0, cfg.throwOriginUp, 0)
		+ root.CFrame.RightVector * cfg.throwOriginRight

	local dir = lookDir.Unit
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	end
	flat = flat.Unit

	local pitch = math.deg(math.asin(math.clamp(dir.Y, -1, 1))) + cfg.throwUpBias
	pitch = math.rad(math.clamp(pitch, cfg.throwMinPitch, cfg.throwMaxPitch))

	local launch = flat * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
	local c = math.clamp(charge or 0, 0, 1)
	local speed = cfg.throwSpeedMin + (cfg.throwSpeedMax - cfg.throwSpeedMin) * c
	return origin, launch * speed
end

local thrownBodies: { [Model]: any } = {}

--[[
	THE WIND-UP.

	Clicking doesn't throw on the spot any more. It publishes ThrowStart (a server
	timestamp, same trick as ChewStart) and every client's Arm system plays the
	same wind-up and whip from it -- the victim is still welded to the arm, so
	they get swung back and then hurled with it. The actual launch (doThrow below)
	fires on the frame the arm passes forward.

	While it plays the grab is committed: no drop, no eat, no second throw.
--]]
local startThrow

local function doThrow(player: Player?, rig: Model, lookDir: Vector3, charge: number?)
	local grab = grabs[rig]
	if not grab then
		return
	end
	local victim = grab.victim
	local vroot = victim and victim:FindFirstChild("HumanoidRootPart")
	if not (victim and victim.Parent and vroot) then
		return
	end

	local cfg = throwConfigOf(rig)
	local origin, velocity = throwVelocity(rig, cfg, lookDir, charge)
	if not origin then
		return
	end

	releaseVictim(rig, false, true)
	victim:SetAttribute("Thrown", true)

	local hum = grab.victimHum
	if hum and hum.Parent then
		hum.PlatformStand = true
	end

	-- Limp in the air even with GRAB_RAGDOLL off, or they'd fly like a plank.
	if not grab.ragdolled then
		local control = ServerStorage:FindFirstChild("RagdollControl")
		if control and control:IsA("BindableEvent") then
			control:Fire(victim, true)
			grab.ragdolled = true
		end
	end

	local spin = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 6
	local launchCFrame = CFrame.new(origin) * (vroot.CFrame - vroot.Position)

	--[[
		WHO FLIES THE BODY: THE THROWER.

		This used to hand the body to the SERVER at the moment of release. The
		thrower's computer had been simulating it the whole carry, so it suddenly
		stopped, and nothing moved on the thrower's screen until the server's
		positions arrived a round trip later -- the body froze, then jumped halfway
		along the arc.

		Now the thrower keeps ownership, exactly as while carrying, and does the
		launch itself (the Arm system listens on CreatureThrowLaunch). Their screen
		sees a perfectly smooth throw; everyone else sees it replicated the same way
		they saw the carry. Costs nothing extra -- it's the same physics, just not
		changing hands mid-air.

		The server still owns the rules: it picked the origin and velocity, it
		detects the landing, and it deals the damage.
	--]]
	local flyer = (player and player.Parent) and player or nil
	if flyer then
		setBodyOwner(grab.heldParts, flyer)
		launchRemote:FireClient(flyer, victim, launchCFrame, velocity, spin)
	else
		-- No thrower client to hand it to: the server flies it.
		setBodyOwner(grab.heldParts, nil)
		victim:PivotTo(launchCFrame)
		for _, part in ipairs(grab.heldParts or {}) do
			if part.Parent and not part.Anchored then
				part.AssemblyLinearVelocity = velocity
				part.AssemblyAngularVelocity = spin
			end
		end
	end

	local now = os.clock()
	thrownBodies[victim] = {
		grab = grab,
		thrower = player,
		rig = rig,
		cfg = cfg,
		startedAt = now,
		noCollideUntil = now + THROW_NO_COLLIDE,
		collisionsBack = false,
		prevSpeed = velocity.Magnitude,
		landedAt = nil,
		flyer = flyer,
		charge = charge or 0,
		knocked = {},   -- everyone this throw has already bowled over
	}

	playCreatureSound(rig, "Throw")
end

--[[
	LAG COMPENSATION.

	The thrower's arm starts winding up the instant they click (their client
	doesn't wait for us), and they stamp the click with the shared server clock.
	By the time the request lands here, half a round trip has already gone -- and
	the launch message we send back will take another half. Timed naively, the
	body left the hand a whole round trip after the arm had swung through on the
	thrower's screen.

	So everything is timed from THEIR click, and the launch is sent one trip
	EARLY, so it arrives on their screen at the moment their arm reaches the
	release point. Capped at MAX_THROW_LAG so a bad stamp (or a lying client) can
	only ever make the throw a little earlier, never skip the wind-up.
--]]
local MAX_THROW_LAG = 0.35

startThrow = function(player: Player?, rig: Model, lookDir: Vector3, clientStamp: number?, clientCharge: number?)
	local grab = grabs[rig]
	if not grab or grab.throwing then
		return
	end
	grab.throwing = true

	local cfg = throwConfigOf(rig)
	local now = workspace:GetServerTimeNow()

	--[[
		THE CHARGE, CHECKED. The client says how charged the throw is; it can't be
		more charged than the time since it told us it started aiming (AimStart)
		allows, plus a little slack for lag. A modified client can't skip the hold
		to get full-power throws.
	--]]
	local charge = 0
	if typeof(clientCharge) == "number" and clientCharge == clientCharge and grab.aimStartedAt then
		local held = os.clock() - grab.aimStartedAt - cfg.throwAimDelay + 0.3
		local allowed = math.clamp(held / math.max(cfg.throwChargeTime, 0.05), 0, 1)
		charge = math.clamp(clientCharge, 0, allowed)
	end
	grab.aimStartedAt = nil
	-- Published so every other client knows how much wind-up is left to animate.
	rig:SetAttribute("ThrowCharge", charge)

	local oneWay = 0
	if typeof(clientStamp) == "number" and clientStamp == clientStamp then
		oneWay = math.clamp(now - clientStamp, 0, MAX_THROW_LAG)
	end
	local startedAt = now - oneWay
	rig:SetAttribute("ThrowStart", startedAt)

	local releaseDelay = windupDuration(cfg, charge) + cfg.throwWhipTime * math.clamp(cfg.throwReleaseAt, 0, 1)
	-- Already `oneWay` into the wind-up, and the launch needs `oneWay` to arrive.
	local wait = math.max(0, releaseDelay - oneWay * 2)
	task.delay(wait, function()
		-- Still the same grab? The victim may have died, been eaten by nothing,
		-- or the creature may have died during the wind-up.
		if grabs[rig] == grab and rig.Parent then
			grab.throwing = false
			doThrow(player, rig, lookDir, charge)
		else
			grab.throwing = false
		end
	end)

	local total = windupDuration(cfg, charge) + cfg.throwWhipTime + cfg.throwFollowTime
	task.delay(total + 0.5, function()
		if rig.Parent and rig:GetAttribute("ThrowStart") == startedAt then
			rig:SetAttribute("ThrowStart", nil)
		end
	end)
end

local throwRayParams = RaycastParams.new()
throwRayParams.FilterType = Enum.RaycastFilterType.Exclude
throwRayParams.IgnoreWater = true

--[[
	THE KILL THUD: the only impact sound in the game now, and only when a throw
	lands hard enough to kill.

	Uses a Sound from CreatureSounds.<soundSet>.ThrowKill if you've made that
	folder; otherwise it borrows one from the victim's own Ragdoll script's
	impactsounds folder, so it works out of the box.
--]]
local function playThrowKillSound(victim: Model, rig: Model, at: BasePart)
	local options = {}

	local root = ReplicatedStorage:FindFirstChild("CreatureSounds")
	local set = root and root:FindFirstChild(getSoundSetName(rig))
	local folder = set and set:FindFirstChild("ThrowKill")
	if folder then
		for _, s in ipairs(folder:GetChildren()) do
			if s:IsA("Sound") then table.insert(options, s) end
		end
	end

	if #options == 0 then
		local ragdoll = victim:FindFirstChild("Ragdoll")
		local impacts = ragdoll and ragdoll:FindFirstChild("impactsounds")
		if impacts then
			for _, s in ipairs(impacts:GetChildren()) do
				if s:IsA("Sound") then table.insert(options, s) end
			end
		end
	end

	if #options == 0 then
		return
	end

	local snd = options[math.random(1, #options)]:Clone()
	snd.Looped = false
	snd.Parent = at
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	task.delay(10, function()
		if snd.Parent then snd:Destroy() end
	end)
end

local function throwImpact(victim: Model, rec, withDamage: boolean)
	rec.landedAt = os.clock()
	if not withDamage then
		return
	end

	local hum = rec.grab.victimHum
	if not (hum and hum.Parent and hum.Health > 0) then
		return
	end

	-- A hard throw is lethal outright; anything less does the normal damage.
	-- Health + MaxHealth rather than MaxHealth alone, so health boosts or
	-- overheal can't let someone walk away from a full-power throw.
	local damage = rec.cfg.throwDamage
	if (rec.charge or 0) >= rec.cfg.throwKillCharge then
		damage = hum.Health + hum.MaxHealth
	end

	-- Kill credit, the same way the medical bleed does it, so a throw that kills
	-- resolves through the normal creator/Killer death flow.
	if rec.thrower and rec.thrower.Parent then
		local creator = Instance.new("ObjectValue")
		creator.Name = "creator"
		creator.Value = rec.thrower
		creator.Parent = hum
		task.delay(0.5, function()
			creator:Destroy()
		end)
		if hum.Health - damage <= 0 and not victim:FindFirstChild("Killer") then
			local killer = Instance.new("ObjectValue")
			killer.Name = "Killer"
			killer.Value = rec.thrower
			killer.Parent = victim
		end
	end

	hum:TakeDamage(damage)

	if hum.Health <= 0 then
		local at = victim:FindFirstChild("Torso") or victim:FindFirstChild("HumanoidRootPart")
		if at and at:IsA("BasePart") then
			playThrowKillSound(victim, rec.rig, at)
		end
	end
end

--[[
	BOWLING PINS.

	While a thrown body is flying, anyone it passes close to gets knocked down:
	ragdolled through the same RagdollControl the grab uses, shoved along the
	direction the body was travelling, and stood back up after throwKnockTime.

	Done by DISTANCE, not by physics collisions. Collisions between two ragdolls
	are unreliable (glancing hits, bodies clipping through each other at speed),
	and it's the flying body's path that should decide who goes down, not whether
	two limbs happened to touch on one frame.

	The server takes over each pin's physics while they're down, so the shove it
	gives them actually applies (a player's own computer normally runs their body
	and would ignore it), then hands it back when they get up.
--]]
local KNOCK_UP = 18   -- studs/s of lift added to the shove, so they go over rather than slide

local function knockDown(model: Model, hum: Humanoid, rec, push: Vector3)
	rec.knocked[model] = true
	model:SetAttribute("Knocked", true)

	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	local control = ServerStorage:FindFirstChild("RagdollControl")
	local ragdolled = false
	if control and control:IsA("BindableEvent") then
		control:Fire(model, true)
		ragdolled = true
	else
		hum.PlatformStand = true
	end

	setBodyOwner(parts, nil)

	-- Applied now AND a frame later: the ragdoll goes limp on a deferred signal,
	-- and splitting the body into loose limbs can drop a velocity set a moment
	-- before it.
	local function shove()
		for _, p in ipairs(parts) do
			if p.Parent and not p.Anchored then
				p.AssemblyLinearVelocity = push
			end
		end
	end
	shove()
	task.defer(shove)

	local dmg = rec.cfg.throwKnockDamage
	if dmg > 0 and hum.Health > 0 then
		if rec.thrower and rec.thrower.Parent then
			local creator = Instance.new("ObjectValue")
			creator.Name = "creator"
			creator.Value = rec.thrower
			creator.Parent = hum
			task.delay(0.5, function()
				creator:Destroy()
			end)
		end
		hum:TakeDamage(dmg)
	end

	task.delay(rec.cfg.throwKnockTime, function()
		if not model.Parent then
			return
		end
		model:SetAttribute("Knocked", nil)
		-- Died meanwhile, or got grabbed while down: those paths own the body now.
		if hum.Health <= 0 or model:GetAttribute("Grabbed") == true then
			return
		end
		if ragdolled then
			local c = ServerStorage:FindFirstChild("RagdollControl")
			if c and c:IsA("BindableEvent") then
				c:Fire(model, false)
			end
		end
		hum.PlatformStand = false
		local owner = Players:GetPlayerFromCharacter(model)
		setBodyOwner(parts, owner or "auto")
	end)
end

local function knockNearby(victim: Model, rec, vroot: BasePart, velocity: Vector3)
	local speed = velocity.Magnitude
	if speed < rec.cfg.throwKnockMinSpeed then
		return
	end
	local radius = rec.cfg.throwKnockRadius
	local here = vroot.Position

	for hum, model in pairs(victims) do
		if model ~= victim and model ~= rec.rig and model.Parent and hum.Parent == model
			and not rec.knocked[model]
			and hum.Health > 0
			and model:GetAttribute("Knocked") ~= true
			and model:GetAttribute("Grabbed") ~= true
			and model:GetAttribute("Thrown") ~= true
			and model:GetAttribute("IsCorpse") ~= true
			and not CreatureUtil.IsCreature(model) then
			local root = model:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and not root.Anchored
				and (root.Position - here).Magnitude <= radius then
				local push = velocity * rec.cfg.throwKnockForce + Vector3.new(0, KNOCK_UP, 0)
				knockDown(model, hum, rec, push)
			end
		end
	end
end

local function finishThrow(victim: Model, rec)
	thrownBodies[victim] = nil
	if victim.Parent then
		victim:SetAttribute("Thrown", false)
	end
	restoreSurvivor(rec.grab)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for victim, rec in pairs(thrownBodies) do
		local hum = rec.grab.victimHum
		local vroot = victim:FindFirstChild("HumanoidRootPart")

		if not victim.Parent or not vroot then
			thrownBodies[victim] = nil
			if rec.grab.toolBlock then
				rec.grab.toolBlock:Disconnect()
			end
			continue
		end

		-- Clear of the creature first, THEN solid again.
		if now < rec.noCollideUntil then
			for _, part in ipairs(rec.grab.heldParts or {}) do
				if part.CanCollide then
					part.CanCollide = false
				end
			end
		elseif not rec.collisionsBack then
			rec.collisionsBack = true
			restoreCollisions(rec.grab)
			-- The ragdoll's own collision hulls. The grab kept these off; the
			-- ragdoll only turns them on as it goes limp, which already happened.
			for _, d in ipairs(victim:GetDescendants()) do
				if d:IsA("BasePart") and d.Name == "ColliderPart" then
					d.CanCollide = true
				end
			end
		end

		if not (hum and hum.Parent and hum.Health > 0) then
			-- Died (to the impact or anything else). The ragdoll's death path owns
			-- the body now; nothing here stands it back up.
			thrownBodies[victim] = nil
			victim:SetAttribute("Thrown", false)
			if rec.grab.toolBlock then
				rec.grab.toolBlock:Disconnect()
			end
			continue
		end

		if not rec.landedAt and rec.flyer and rec.flyer.Parent then
			for _, part in ipairs(rec.grab.heldParts or {}) do
				if part.Parent and not part.Anchored then
					local ok, current = pcall(part.GetNetworkOwner, part)
					if ok and current ~= rec.flyer then
						pcall(part.SetNetworkOwner, part, rec.flyer)
					end
				end
			end
		end

		if not rec.landedAt then
			local t = now - rec.startedAt
			local v = vroot.AssemblyLinearVelocity
			local speed = v.Magnitude

			-- Bowling: anyone in the flight path goes down.
			if rec.collisionsBack then
				knockNearby(victim, rec, vroot, v)
			end

			if t > THROW_MAX_FLIGHT then
				throwImpact(victim, rec, false)
			elseif t > 0.12 and rec.collisionsBack then
				local hit = (rec.prevSpeed - speed) > THROW_IMPACT_DROP
				if not hit and v.Y <= 1 then
					throwRayParams.FilterDescendantsInstances = { victim, rec.rig }
					hit = workspace:Raycast(vroot.Position, Vector3.new(0, -THROW_GROUND_RAY, 0), throwRayParams) ~= nil
				end
				if hit then
					throwImpact(victim, rec, true)
				end
			end
			rec.prevSpeed = speed
		elseif now - rec.landedAt >= rec.cfg.throwRagdollTime then
			finishThrow(victim, rec)
		end
	end
end)

-- ============================================================
-- ACTION ROUTING
-- ============================================================
-- Called by the player remote below. `player` is only used by doGrab, to hand
-- the victim's network ownership to the grabber.
runAction = function(rig: Model, action: string, player: Player?, arg: any?, arg2: any?, arg3: any?)
	--[[
		Mid-eat, only the escape hatches are allowed through.

		Grab and Eat are still blocked ? you can't start a second eat or grab
		somebody else with a body already in your mouth. But cancelling and
		dropping have to work DURING the eat, which is the whole point of them.
	--]]
	if rig:GetAttribute("CreatureEating") == true then
		if action ~= "CancelEat" and action ~= "Drop" then
			return
		end
	end

	-- Mid wind-up: committed. Nothing else until the body has left the hand.
	local current = grabs[rig]
	if current and current.throwing then
		return
	end

	if action == "Grab" then
		doGrab(player, rig)
	elseif action == "Eat" then
		doEat(rig)
	elseif action == "CancelEat" then
		local grab = grabs[rig]
		if grab then
			-- Bumping the session is what actually stops it: every queued crunch
			-- and the killing bite check it before firing.
			grab.eatSession = (grab.eatSession or 0) + 1
		end
		rig:SetAttribute("CreatureEating", false)
		rig:SetAttribute("ChewStart", nil)
	elseif action == "Throw" then
		if typeof(arg) == "Vector3" then
			startThrow(player, rig, arg, arg2, arg3)
		end
	elseif action == "Drop" then
		-- false = they live. releaseVictim already puts back PlatformStand,
		-- collisions, walk speed and anchoring, so a dropped victim is fully
		-- restored and can just walk away.
		releaseVictim(rig, false)
	end
end

--[[
	NO GRABBING OR EATING AT SPRINT SPEED.

	The Arm system on the creature's client already stops you, but that is just a
	client that could be modified. This is the check that counts: Grab and Eat are
	refused while the creature is moving faster than a walk. Drop and CancelEat are
	always allowed -- letting go should never be blocked.

	Measured from the root's velocity (which the server sees), against the rig's
	own walkSpeed plus slack for lag and the speed ramp.
--]]
local SPRINT_LOCK_SLACK = 3

local function walkSpeedOf(rig: Model): number
	local module = rig:FindFirstChild("CreatureConfig")
	if module and module:IsA("ModuleScript") then
		local ok, cfg = pcall(require, module)
		if ok and typeof(cfg) == "table" and typeof(cfg.walkSpeed) == "number" then
			return cfg.walkSpeed
		end
	end
	return 9
end

local function tooFastToUseArm(rig: Model): boolean
	local root = rig:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	return speed > walkSpeedOf(rig) + SPRINT_LOCK_SLACK
end

actionRemote.OnServerEvent:Connect(function(player, action, arg, arg2, arg3)
	if typeof(action) ~= "string" then
		return
	end

	--[[
		AIMSTART: right click went down while holding someone. It only starts the
		charge clock, so it skips the shared action limiter -- otherwise the throw
		or the drop that follows it a moment later would be swallowed by it.
	--]]
	if action == "AimStart" then
		local rig = player.Character
		local grab = rig and grabs[rig]
		if grab and not grab.throwing then
			grab.aimStartedAt = os.clock()
		end
		return
	end

	local now = os.clock()
	local last = lastAction[player]
	if last and now - last < MIN_ACTION_INTERVAL then
		return
	end
	lastAction[player] = now

	local rig = player.Character
	if not rig or rig:GetAttribute("IsCreature") ~= true then
		return
	end
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end

	if (action == "Grab" or action == "Eat") and tooFastToUseArm(rig) then
		return
	end

	-- Throw carries the aim direction. Anything that isn't a sane, finite
	-- direction is dropped here rather than trusted downstream.
	if action == "Throw" then
		if typeof(arg) ~= "Vector3" then
			return
		end
		if arg.X ~= arg.X or arg.Y ~= arg.Y or arg.Z ~= arg.Z or arg.Magnitude < 0.1 or arg.Magnitude > 1e3 then
			return
		end
	else
		arg = nil
	end

	if action ~= "Throw" or typeof(arg2) ~= "number" then
		arg2 = nil
	end
	if action ~= "Throw" or typeof(arg3) ~= "number" then
		arg3 = nil
	end

	runAction(rig, action, player, arg, arg2, arg3)
end)

-- ============================================================
-- CLEANUP
-- ============================================================
CollectionService:GetInstanceRemovedSignal(CreatureUtil.TAG):Connect(function(rig)
	releaseVictim(rig, false)
end)

Players.PlayerRemoving:Connect(function(player)
	lastAction[player] = nil
	for rig in pairs(grabs) do
		if Players:GetPlayerFromCharacter(rig) == player then
			releaseVictim(rig, false)
		end
	end
end)

-- Keeps every held body non-colliding, every frame. See the note in doGrab: the
-- ragdoll turns its collider parts back on after the grab, and anything else that
-- touches CanCollide would do the same. Only writes when a part has flipped, so
-- it costs a property read per part otherwise.
RunService.Heartbeat:Connect(function()
	for _, grab in pairs(grabs) do
		local parts = grab.heldParts
		if parts then
			for _, part in ipairs(parts) do
				if part.CanCollide then
					part.CanCollide = false
				end
				-- The ragdoll splits the body into separate assemblies AFTER the
				-- grab, and new assemblies don't inherit the owner. Kept in line
				-- here so the grabber's computer is the only one simulating it.
				if grab.owner and part.Parent and not part.Anchored then
					local ok, current = pcall(part.GetNetworkOwner, part)
					if ok and current ~= grab.owner then
						pcall(part.SetNetworkOwner, part, grab.owner)
					end
				end
			end
		end
	end
end)

-- A grab can be orphaned if the creature dies mid-carry, or if the victim is
-- teleported far away by something else. Checked on a slow tick rather than
-- trusted to the event handlers alone.
task.spawn(function()
	while true do
		task.wait(1)
		for rig, grab in pairs(grabs) do
			local hum = rig:FindFirstChildOfClass("Humanoid")
			local rigRoot = rig:FindFirstChild("HumanoidRootPart")
			local vroot = grab.victim and grab.victim:FindFirstChild("HumanoidRootPart")

			local broken = not rig.Parent
				or not hum or hum.Health <= 0
				or not grab.victim or not grab.victim.Parent
				or not vroot or not rigRoot
				or (vroot.Position - rigRoot.Position).Magnitude > 40

			if broken then
				releaseVictim(rig, false)
			end
		end
	end
end)
