# Creature System (Roblox / Luau)

Morphs a player into a creature with its own movement, roars, grab/throw/eat,
head and arm aiming, vision modes, footsteps and breathing. The human side
(the SPH gun framework, human movement and footsteps) is here too.

Folders here mirror the Roblox Studio **Explorer**. Each `.luau` file is one
script; copy its contents into a script of the listed type at that location.

## Creature

```
ReplicatedStorage
├── Shared
│   └── CreatureUtil            ModuleScript
└── Creatures
    └── Stalker                 the creature rig (Model)
        ├── CreatureMovement    LocalScript  (direct child of the rig)
        └── CreatureConfig      ModuleScript (direct child of the rig)

ServerScriptService
├── CreatureService             Script
├── CreatureGrabServer          Script
├── CreatureRoarServer          Script
├── CreatureHeadServer          Script
└── CreatureBreathing           Script

StarterPlayer
└── StarterPlayerScripts
    └── CreatureClient          LocalScript
        └── Systems             Folder (child of the CreatureClient LocalScript)
            ├── Arm             ModuleScript
            ├── Camera          ModuleScript
            ├── ChatHide        ModuleScript
            ├── CombatCue       ModuleScript
            ├── Eyes            ModuleScript
            ├── Footsteps       ModuleScript
            ├── Head            ModuleScript
            ├── Hum             ModuleScript
            ├── Mouse           ModuleScript
            ├── NightVision     ModuleScript
            ├── Roar            ModuleScript
            ├── RoarEffects     ModuleScript
            ├── RoarWave        ModuleScript  (visible roar shockwave)
            ├── Thermal         ModuleScript
            └── Vision          ModuleScript
```

## Human (SPH gun framework, movement, footsteps)

```
ReplicatedStorage
└── SPH_Assets                  Folder (the rest of it is not in this repo)
    └── GameConfig              ModuleScript

ServerScriptService
└── SPH_Server                  Script

StarterPlayer
├── StarterPlayerScripts
│   ├── PlayerClient            LocalScript
│   └── Footsteps               LocalScript
└── StarterCharacterScripts
    └── SPH_Character           Folder
        ├── CharacterClient     LocalScript
        └── CharacterMovement   LocalScript
```

Notes:
- `CreatureClient/CreatureClient.luau` is the LocalScript itself. The `Systems`
  folder next to it goes **inside** that LocalScript in Studio.
- `Stalker` is the default creature name used by `CreatureService`. If your rig
  has a different name, the two rig scripts go inside that Model instead.
- RemoteEvents (`CreatureRoarRemote`, `CreatureLookRemote`, etc.) are created
  at runtime by the server scripts; nothing to add by hand.
- The human scripts depend on `ReplicatedStorage.SPH_Assets` (modules,
  animations, sounds). Only its `GameConfig` is in this repo.
- Two creature-side files share names with human-side ones: the creature's
  `Systems/Footsteps` (ModuleScript) and the human `StarterPlayerScripts/Footsteps`
  (LocalScript) are different scripts in different places.
