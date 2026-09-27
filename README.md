# Creature System (Roblox / Luau)

Morphs a player into a creature with its own movement, roars, grab/throw/eat,
head and arm aiming, vision modes, footsteps and breathing.

Folders here mirror the Roblox Studio **Explorer**. Each `.luau` file is one
script; copy its contents into a script of the listed type at that location.

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
            ├── RoarWave        ModuleScript  (new: visible roar shockwave)
            ├── Thermal         ModuleScript
            └── Vision          ModuleScript
```

Notes:
- `CreatureClient/CreatureClient.luau` is the LocalScript itself. The `Systems`
  folder next to it goes **inside** that LocalScript in Studio.
- `Stalker` is the default creature name used by `CreatureService`. If your rig
  has a different name, the two rig scripts go inside that Model instead.
- RemoteEvents (`CreatureRoarRemote`, `CreatureLookRemote`, etc.) are created
  at runtime by the server scripts; nothing to add by hand.
