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
├── CreatureBreathing           Script
└── CreatureHeat                Script  (thermal signature)

StarterPlayer
└── StarterPlayerScripts
    ├── GrabbedInventoryLock    LocalScript (hides the hotbar while grabbed/thrown)
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

StarterPack
└── Recon Drone                 Tool
    ├── DroneClient             LocalScript
    └── DroneSensors            ModuleScript
```

`Gear/NVG/NightVision.luau` is the LocalScript that goes **inside the NVG device
model** (anywhere in it) -- wherever your Arsenal keeps that model. It isn't a
fixed Explorer location, so it has its own folder here.

## Sky (day/night cycle and aurora)

```
ReplicatedStorage
└── Shared
    └── AuroraShape             ModuleScript (builds + animates the aurora)

ServerScriptService
├── LightingCycle               Script  (day/night cycle)
└── AuroraServer                Script  (rolls each night's aurora)

StarterPlayer
└── StarterPlayerScripts
    └── AuroraClient            LocalScript (builds the aurora on each client)

Workspace
└── AuroraCenter                Part you place: the middle of the aurora
```

`AuroraCenter` is an anchored, invisible, non-colliding Part anywhere in
Workspace. Its front face sets which way the main arcs run; an optional number
attribute `Area` sets how far the aurora spreads (default 10000 studs). Every
night gets a new random sky around it. For testing, set the Lighting attribute
`AuroraForce` to `Quiet`/`Active`/`Storm`/`Off`, or tick `AuroraReroll` --
or use the admin commands below.

`KohlsAdmin/Config/Addons/EnvironmentCommands.luau` is a ModuleScript that goes
in **Kohl's Admin > Config > Addons**: `;freezetime`, `;daylength`,
`;nightlength`, `;season`, `;weather`, `;time`, `;aurora`, `;aurorasurge`,
`;aurorasurges`.

## FOB / heliport

`Assets/FOB/FOBBuilder.luau` is a **Command Bar** script (View > Command Bar), not
a script you put in the game. Paste it in and press Enter: it builds the forward
operating base + heliport as `Workspace > FOB` (walls, towers, gate, tents, TOC,
motor pool, ammo point, two helipads, flight ops tower, fuel point, aid station,
roads). Change `ORIGIN` / `YAW` at the top to move or turn it. Running it again
replaces the old one; Ctrl+Z undoes it. Turn `SHOW_LABELS` off (or delete the
`BuildLabel` guis) before publishing.

## Forward Aviation Base + command post

Two more **Command Bar** builders in `Assets/FAB/`, built with the
MaterialVariants in MaterialService:

- `FABBuilder.luau` builds `Workspace > FAB`: octagonal T-wall perimeter,
  hangars 01/02 with the ops centre and control tower, fuel farm, four flight
  line pads + the main pad, vehicle park, maintenance shed, power plant,
  container yard, crew quarters, gate A1 with towers, floodlights.
- `CommandPostBuilder.luau` builds `Workspace > CommandPost`, a hardened TOC with
  a furnished interior. If the FAB exists it places itself inside it (west of
  the main pad); otherwise at `ORIGIN`.

Things that should be meshes (helicopters, vehicles, radios, satellite dish)
are `MESH_...` placeholder boxes with the `Baseplate Tile` texture, tagged
`MeshPlaceholder` with a `ReplaceWith` attribute. Swap them for your models.

`Assets/Tools/ListMaterials.luau` (Command Bar) prints everything in your
MaterialService.

## Assets

`Assets/Aurora/` -- aurora borealis textures (`aurora_curtain.png`,
`aurora_glow.png`, and `aurora_ray.png`, which is no longer used), `AuroraBuilder.luau` (a static
command-bar preview; the real aurora is the Sky scripts above), a `preview.png`, and the Python
script that generated the textures.

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
