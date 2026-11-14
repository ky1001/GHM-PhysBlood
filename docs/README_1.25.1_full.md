# GHM PhysBlood — physically simulated blood for Garry's Mod

**Version 1.25.1** (in development) · shader set `ghmpbb74_` · C++ droplet solver v5 (optional) · Garry's Mod x86-64 and main branch

GHM PhysBlood replaces Garry's Mod's decal blood with simulated blood. Every drop that leaves a wound is a particle with volume, velocity, spin and stretch. When it lands, it is painted texel by texel into a 2D cell field that lives on the surface it hit: a model's UV space or a patch of the world. On the GPU that field then runs as a thin-film fluid. Blood runs down skin, cloth and walls, soaks into fabric and soil, pools on floors, drips off chins and ledges, clots, and dries into brown stains. It is shaded with a physically based film model on top of the lit frame, so it picks up Source's lighting, shadows, the map's lamps and the flashlight, and reflects what stands around it.

**What it is for.** PhysBlood is built as a teaching aid for **bloodstain pattern analysis (BPA)**: a crime-scene class can stage an event (a shooting, a stabbing, a beating, a body dragged across a floor) and then study the stains it leaves — impact spatter with its directionality, cast-off, arterial patterns, drip trails, pools, transfer patterns, clotting and drying. The droplet physics and stain shapes follow published forensic measurements (see [Forensic model](#forensic-model-what-the-numbers-are)). It also works as an ordinary gameplay blood mod, with styles from *Minimal* to *Horror*. It is a simulation inside a game engine: it shows how patterns form and how to read them, but it is not a forensic tool for real casework (see [Using it in class](#using-it-in-class)).

---

## Contents

1. [Status: what has been tested in game](#status-what-has-been-tested-in-game)
2. [Features at a glance](#features-at-a-glance)
3. [Install](#install)
4. [Quick start](#quick-start)
5. [Using it in class](#using-it-in-class)
6. [Settings window](#settings-window)
7. [Feature reference](#feature-reference)
8. [Console commands and settings (every one)](#console-commands-and-settings-every-one)
9. [Compatibility with other addons](#compatibility-with-other-addons)
10. [Performance and tuning](#performance-and-tuning)
11. [Known limits](#known-limits)
12. [In progress and planned](#in-progress-and-planned)
13. [Version history](#version-history)
14. [How it works inside (for developers)](#how-it-works-inside-for-developers)
15. [Source layout, building and tests](#source-layout-building-and-tests)
16. [Patent note](#patent-note)

---

## Status: what has been tested in game

Tested on the **x86-64 branch** (build 2026.09.22) on gm_construct and the included brick test map, on a separate test install of the game.

| Version | State |
|---|---|
| up to 1.18.1 | Run in game in single player (gm_construct, ghmpb_bricks): bleeding, sprays, pools, runs, water, footprints, hand prints, props, tyres, FLESH, elements, dust, flies, creature tracks, surface looks, battle scaling. 31 feature clips were recorded in game. |
| 1.19.0 – 1.25.0 | Built and run in the mocked game (`tests/mp_mock`); **1.25.0 was run in game** (October 2026): it loads and draws without errors, and the check found four things to fix — pools looked pale / brownish at low view angles, rifle exit spray left thin long lines, the reflection probes were hard to see, and the flashlight left no clear shine on wet blood. |
| **1.25.1** | Fixes for those four (floor mirror reflections, rim glints, short-skid rules) — built (shader set b74), all 31 mock test files pass, **not yet checked in game**. |
| Multiplayer, Z-City (1.15.0) | Tested in a simulation of a GMod server, ULib's hook library and Z-City only; not yet in a real multiplayer game. |
| Lite renderer (1.22.0) | From source and mock tests; not yet checked in game. |
| VAT bursts (1.23.0) | From source and mock tests (they read the real effect files); not yet checked in game. |

---

## Features at a glance

**Bleeding and wounds**
- Any model that bleeds gets its own simulated blood film (NPCs, players, ragdolls, workshop models; up to 4 materials per model, faces always included). Mirrored UV halves (left / right legs sharing one texture) get separate blood.
- Wounds sit on the bone that was hit, on the skin; entry and exit wounds traced through the body.
- Arterial spurting with a real pressure waveform and heart rate; bright oxygenated arterial blood, dark venous blood, darkest from the abdomen.
- Nose, mouth and ear bleeding from head, neck and chest trauma; coughed (expirated) blood with air bubbles; for every common skeleton (ValveBiped, bip01, Mixamo, UE, creatures).
- A blood supply per body (4 litres for a human, scaled by size); bodies empty, corpses stop bleeding as blood settles and clots.
- Four blood types (red, yellow / antlion, green, zombie) that mix per pixel; machines and props made of wood, metal, plastic… never bleed.
- Fire, shock, gas, drowning, radiation and other bloodless damage open no wounds.
- Hanging drops that swell on chins, noses, ledges and ceilings before they fall.
- Corpses that fall hard burst open; light bumps do nothing; thrown / dropped bodies bleed within limits.

**Drops, spray and forensic patterns**
- Every drop is a simulated particle: drag from its Reynolds number, break-up above a critical Weber number, spin, surface tension, coalescence (C++), far drops integrated cheaply.
- Gunshot back-spatter and forward spatter, blood mist, blunt-force spatter, melee cut arcs, cast-off off the back swing, arterial jets, expirated blood, drips — each with forensic speeds, sizes and cone angles.
- Stains follow the Hulse-Smith relations: stain diameter, number of spines, splashing threshold per surface, width / length = sin(impact angle); teardrop stains with tails, wave cast-off drops, skid streaks at very low angles, secondary spatter in wet blood, satellite drops, ricochets.
- Explosions throw a body's blood away from the blast in three pulses with shrapnel wounds.
- Fluid-simulated 3D blood bursts (VAT meshes made in LiquiGen) at wounds, jets and big impacts.
- Splatter styles: Minimal, Realistic (forensic reference amounts), Cinematic, Samurai, Horror, or custom sliders.

**Blood on surfaces**
- Thin-film fluid simulation on the GPU with exact volume conservation, contact-line pinning, wetting, momentum, absorption, levelling.
- Pools that grow from under a body along its contact line, level out within seconds, round off, finger down slopes, fill mortar joints and cracks first, stop against walls, spill over ledges and cascade down stairs, and join when they touch.
- Runs on walls decided by the weight of the blood above them: rivulets with a bead at the head that meander a little, catch in joints, follow earlier trails, merge, and stop as a teardrop bead.
- 19 surface kinds (glass, ice, metal, tile / plastic / paint, rubber, concrete, stone, brick, plaster, wood, paper / cardboard, carpet / cloth, soil, sand, gravel, grass, snow, grates, water / slime), plus skin and cloth on bodies, each with its own soaking, flow and look (halos, grain, snow melt, cracking).
- Thin blood follows the surface's normal map: it creeps along grout and grooves.
- Coagulation (autocatalytic clotting), serum separation, drying into a crust with cracks and a coffee ring; dried colour ages.
- Settled blood moves into a cheap "aftermath" layer that can be kept forever.

**Transfer patterns**
- Bodies smear blood where they slide or are dragged, wipe and push pools, and carry blood on.
- Bloody footprints (shoe soles with tread, left / right, fading over steps) and creature tracks (headcrabs, antlions, hunters, birds, paws).
- Hand prints (palm, fingers, creases) and finger drag streaks, from anyone whose hand touches a surface.
- Props soak up blood (cardboard drinks it, metal gets a film), smear it when dragged and splash in pools.
- Vehicles print tyre treads and skid marks (HL2, simfphys, LVS, Glide).
- Splashes when bodies, props or tyres hit pools.

**Look**
- Physically based shading: Kubelka-Munk optics in four wavelength bands from haemoglobin absorption spectra; thin blood scarlet and translucent, thick blood opaque deep crimson, clots maroon, dried blood met-haemoglobin brown.
- Wet gloss, live reflection probes of the surroundings, sharp mirror reflections in floor pools (1.25.1), screen-space reflections, highlights from the sun, the map's lamps, dynamic lights, projected textures and every player's flashlight, meniscus rim glints (1.25.1).
- Froth and air bubbles, clot lumps, flow streaks, meniscus edges.
- Colour settings: fresh brightness, dried brightness, hue.
- A lite renderer without custom shaders for Workshop installs.

**Environment**
- Blood in water becomes clouds that sink, drift and fade; blood washes off under water.
- Fire boils and chars blood, cold freezes it, electricity runs through connected wet pools and shocks whoever stands in them, lasers boil it, acid dissolves it, blasts slosh it.
- Explosions kick up dust that sticks to fresh blood (sand, snow, soil, concrete, plaster...).
- Flies find blood and the dead outdoors, land only on blood and scatter when disturbed.

**Scale and multiplayer**
- Adaptive quality holds your frame rate; large battles reduce far / hidden detail first; video memory budget; collision spam protection.
- Multiplayer (listen and dedicated): blood events to everyone who can see them, catch-up history for players who arrive later, server settings from the window.
- Works with VJ Base, ZBase, DrGBase, any NPC base, Z-City, GHM FLESH, GHM Euphoria, StormFox 2, vFire and GHM PhysFX.

---

## Install

### Full install (shaders — the full simulation)

| What | Where |
|---|---|
| `addons/ghm_physblood/` | `garrysmod/addons/ghm_physblood/` |
| `shaders/fxc/ghmpbb74_*.vcs` (28 compiled shaders) | `garrysmod/shaders/fxc/` |
| `lua/bin/gmcl_ghmpb_native_v5_win64.dll` (x86-64 branch) or `gmcl_ghmpb_native_v5_win32.dll` (main branch) — **optional** | `garrysmod/lua/bin/` |

The tester package is laid out the same way: one `garrysmod` folder to drag onto the game's `GarrysMod` folder (merge). Delete an older `garrysmod/addons/ghm_physblood` first. The shader file names carry the shader set (`ghmpbb74_` for 1.25.1), so a newer set never overwrites an older one; old `ghmpb*_*.vcs` files can be deleted. Do not run PhysBlood together with another blood-replacement addon.

### Workshop install (lite renderer)

The Steam Workshop does not allow compiled shaders (`shaders/fxc/*.vcs`) or DLLs. Without the shader files PhysBlood switches by itself to its **lite renderer** (1.22.0): stains, pools, body decals and drop sprites drawn with stock materials. It keeps the drops, the forensic spray, wounds, pools that grow and join, footprints, hand prints, the VAT bursts and the colour settings, but not the liquid flow on surfaces, the film relief, froth, live clotting and drying, smears on bodies or the dust. Add the shader files by hand for the full simulation. `ghmpb_render_mode` (0 automatic, 1 shaders, 2 lite) picks the renderer; Settings → Quality → Renderer.

### The C++ droplet solver (optional DLL)

Without the DLL, the Lua droplet solver is used. It gives the same results but is slower with a lot of drops (with the DLL, 400 drops in flight cost about 1 ms a frame). v4 hands each drop's blood type and oxygenation to the drop shader; v5 (1.17.0) reuses its result tables every frame (less garbage). Older `gmcl_ghmpb_native_v4_*` / `v3_*` / `v2_*` / `gmcl_ghmpb_native_win*` files can be deleted (they still load if v5 is missing; with v3 and older the drops draw with a fixed oxygenation, with v2 all red). The DLL uses only the public Lua C API, so game updates cannot break it. The Workshop cannot carry it: each player installs it by hand.

### Test assets

The addon carries the map **ghmpb_bricks** (`map ghmpb_bricks`, or pick it in the map list) and two spawnable props in **Spawn menu → Entities → GHM PhysBlood**: *Brick paving slab (blood test)* and *Brick wall section (blood test)*. Both are real geometry with recessed / proud bricks, to see how blood fills joints, is held by walls and runs over edges. They are left out of the Workshop package.

### Multiplayer servers (listen or dedicated)

Install the addon on the server. Joining players need its content (shaders, materials, models): the server tells them to download it from the addon's Workshop item (`resource.AddWorkshop`), which it finds by itself among its mounted Workshop addons (keep "PhysBlood" in the item's title), or from `ghmpb_sv_workshop_id <id>`. A server that runs the addon from its `addons` folder without a Workshop item sends the files through its own downloads instead (`ghmpb_sv_fastdl 1`, the default; set up `sv_downloadurl` for speed). The Lua is sent to clients as usual. The DLL cannot be sent.

### Publishing to the Workshop

`tools/build_workshop.py` builds `ghm_physblood/` (addon.json, stripped Lua, materials), `ghm_physblood.gma` (GMA v3 as gmad writes it) and `icon.jpg`; the test map and props stay out; `--without-vat` leaves the VAT bursts out. Upload from the game's `bin` folder: `gmpublish.exe create -addon ghm_physblood.gma -icon icon.jpg` (a 512 × 512 JPG). By hand: `gmad.exe create -folder "garrysmod/addons/ghm_physblood" -out ghm_physblood.gma` (gmad refuses files not on its whitelist — check its output).

---

## Quick start

1. Install, start a map (gm_construct or `map ghmpb_bricks`), spawn a few NPCs and shoot one.
2. Open the settings: hold **C** and click the **PhysBlood** icon, or type `ghmpb_menu`, or **Spawn menu → Options → GHM PhysBlood → Settings**.
3. Pick a quality preset (Quality tab) and a splatter style (Splatter tab).
4. Test without weapons: look at a surface or a model and use `ghmpb_test_pour 200`, `ghmpb_test_spray 40`, `ghmpb_test_wound 30 neck`, `ghmpb_test_kill` (also buttons on the Debug tab).
5. If no blood shows on a map, run `ghmpb_diag` and read (or send) its output: it says what happened to every hit and why blood was or was not painted.
6. Clean up with **Remove all blood** in the window footer or `ghmpb_clear`.

---

## Using it in class

PhysBlood reproduces the main families of bloodstain patterns used in BPA teaching. The table says what to stage and what the class can measure.

| Pattern family | What to stage | What forms |
|---|---|---|
| **Passive: drip stains, drip trails** | A wounded NPC walking; a body hanging over a ledge; `ghmpb_test_wound` on a standing NPC | Hanging drops that swell to ~0.1 ml (Tate's law) and fall; round drip stains on level floors, larger with height; drip trails along the path walked; drip-into-blood secondary spatter where drops fall into a pool |
| **Passive: flow, pools, saturation** | A body bleeding out on a floor, a slope, stairs, carpet | Pools growing from under the body along its contact line, flow down slopes in tongues, cascades over steps, soaking into carpet / cloth / soil |
| **Impact spatter: gunshot** | Shoot an NPC standing near a wall | Back spatter (entry, fine < 1 mm, wide cone towards the shooter) and forward spatter (exit, more and faster drops in a narrow cone), mist that settles within ~0.5 m |
| **Impact spatter: blunt force** | Hit a bloody body repeatedly with a crowbar or stunstick | No spatter from the first blow to clean skin; later blows throw 1–4 mm drops from the blood already there |
| **Cast-off** | Swing a bloody weapon (crowbar, knife or other melee SWEP) | A line of drops flung tangentially off the arc on the back swing, onto walls and ceilings |
| **Arterial** | `ghmpb_test_wound 40 neck` or a neck / thigh hit | Pulsing jets whose reach falls as blood pressure drops; arcs on walls and floors, bright scarlet blood |
| **Expirated** | Chest or neck wounds | Coughed blood: fine, diluted, with air bubbles that leave rings |
| **Transfer** | Drag a corpse, walk an NPC through a pool, touch walls, drive through blood | Swipes and wipes, footwear prints with tread, hand prints and finger streaks, tyre tracks, skid marks |
| **Altered stains** | Wait; use water, fire, cold | Clotting, serum separation around retracting clots, drying (edges first, coffee ring, cracks), dilution and wash-off in water, insects (flies) |
| **Voids** | An object or person standing in the spray | Drops land on whatever is in their way, leaving the area behind it clean |

**Measuring directionality and angle of impact.** A stain's width / length follows sin(impact angle), its tail points the way the drop travelled, and spines and satellites sit on the far side. Students can measure stains on screen (`ghmpb_debug 2` shows the cells under a stain), apply α = arcsin(W/L), and string back to an area of convergence. **For this, set `ghmpb_streak_max 10`**: by default (3.5) stains from impacts flatter than ~16° are kept shorter for looks, which would read as a steeper angle.

**Suggested classroom settings** (all in the window or the console):

| Setting | Value | Why |
|---|---|---|
| `ghmpb_splatter_style realistic` | Realistic | Forensic reference amounts, no cinematic boosts, no killing-blow burst, no fountain |
| `ghmpb_streak_max` | 10 | Stain length follows the impact angle down to ~6° |
| `ghmpb_drop_slide` | 0 | No skidding droplets after fast flat hits (a game-look detail) |
| `ghmpb_keep_forever` | 1 | The scene stays until you clear it; raise `ghmpb_aftermath_max` for big scenes |
| `ghmpb_perf_adaptive` / `ghmpb_battle_lod` | 0 | Full detail everywhere (if the machine keeps up) |
| `ghmpb_quality` | 3 or 4 | Finer cells: crisper small stains |
| `ghmpb_coag_time`, `ghmpb_drytime` | as needed | Real clotting takes minutes; shorten to show clotting / drying in one lesson, lengthen to keep blood wet |
| `ghmpb_flies` | 0 or 1 | Flies are realistic outdoors but can distract |

**Accuracy notes for teachers.** The physics uses forensic and fluid-mechanics measurements, but the result is an approximation in a game: one world unit is 1.905 cm, cells are about 2–6 mm, Source's hit points and hitboxes decide where wounds are, and each client simulates its own drops (two players see the same kind of pattern, not the same stains). Weapons other than guns and blades are recognised by damage type. Use it to show how patterns form and to practise reading them — not to reconstruct real events.

---
## Settings window

Open it in any of these ways:

- hold **C** and click the **PhysBlood** icon on the context-menu desktop,
- type `ghmpb_menu` in the console,
- **Spawn menu → Options → GHM PhysBlood → Settings → Open the settings window** (the server settings also have a page there for superadmins / the listen-server host).

Every control is a console setting too (listed with its default and range in [Console commands and settings](#console-commands-and-settings-every-one)).

| Tab | Section | Controls |
|---|---|---|
| **Quality** | Renderer | Renderer (automatic / shaders / lite) with a status line; *Lite: stains kept* |
| | Presets | **Low** (256 / 128 cells, 20 Hz, ~120 MB of video memory), **Medium** (default: 384 / 256 cells, 30 Hz, ~600 MB), **High** (512 / 320 cells, 30 Hz, ~1 GB), **Ultra** (640 / 512 cells, 45 Hz, ~1.4 GB — raise the budget to 2048 MB on 6 GB+ cards). Changing the cell resolution removes the blood on screen. |
| | Resolution and smoothness | Enable GHM PhysBlood; cell resolution; edge smoothing (off / smooth / smooth + organic edges); simulation rate (steps / s) |
| | Budgets | Max simulated models; max simulated world patches; max flying droplets; use the C++ droplet solver (if installed) |
| | Frame rate | Adaptive quality (hold the frame rate); target frame rate; scale with the size of the fight; live readout of the blood's share of the frame and the governor's pressure |
| | Video memory | Budget (MB) with a live readout of what is in use |
| **Look** | Blood look | Density / opacity; wetness; shine; gloss (sharpness of the shine); relief depth (dynamic normals); thin blood follows the surface's normal map; separate blood for mirrored halves of models; froth |
| | Reflections and lights | Mirror reflections in pools on the floor (1.25.1); reflection probes (groups of blood); probe time budget (ms a second); highlights from the map's lamps and flashlights |
| | Blood colour | Fresh blood brightness; dried / old blood brightness; hue (− crimson / purple, + orange / scarlet); reset colours |
| **Simulation** | Flow | Thickness (surface pinning); viscosity; body motion influence |
| | Runs on walls | Runs (0 = off); run speed |
| | Blood in water | Blood mixes into water (clouds); cloud strength; clouds last up to (s); wash-off under water |
| | Pools | Pool size (blood lost when dying); floor unevenness |
| | Blood supply | Blood volume of a human (ml); corpses bleed for (s) |
| | Coagulation and drying | Blood coagulates (clots); clotting time (s); drying time (s) |
| **Splatter** | Style | **Minimal**, **Realistic**, **Cinematic**, **Samurai**, **Horror** buttons and the current style (moving a slider makes it "custom"; console `ghmpb_splatter_style <name>`) |
| | Where blood comes from | Entry wound back-spatter; exit wound spray; melee (blade arcs, blunt hits); killing blow burst; explosions (burst thrown away from the blast); arterial jets; blood fountain from fatal cuts (samurai films); wound size on the body |
| | Droplets | Amount (all sprays); size; speed / throw distance; cone width; blood mist on impacts; cast-off from bloody weapons; drops skip and splash (ricochet streaks, secondary droplets); longest drop stain (length / width); fast drops skid on (off / short skids / long rivulets); motion trail of flying drops; hanging drops that swell before they fall |
| | Fluid bursts (VAT) | Fluid-simulated blood bursts on / off; burst size; bursts on screen at once; brightness (all bursts); a colour swatch, brightness and hue per blood type (red, yellow, green, zombie); reset burst colours; status line |
| **Aftermath** | Aftermath layer | Keep settled blood in the aftermath layer; keep the mess forever; fade out after (minutes); settle after (s without new blood) |
| | Limits | Max aftermath world patches; max bodies keeping blood; aftermath resolution; **Remove old blood now** |
| **Bleeding** | Amounts | Bleeding amount |
| | Effects | Nose / mouth / ear bleeding; arterial spurting; coughing blood (chest / neck wounds); world pools and stains; blood looks different on each surface; remove the engine's blood decals from bodies |
| | Smearing | Bodies smear blood where they slide or are dragged; smear amount; bodies moving through pools wipe them and pick blood up |
| | Footprints | Bloody footprints; footprint amount; NPCs leave footprints too |
| | Hand prints | Bloody hands leave hand prints and finger streaks; hand print amount |
| | Props and vehicles | Props soak up blood, smear it when dragged, splash when dropped in pools; prop blood amount; tyre tracks and skid marks (HL2, simfphys, LVS, Glide); tyre track amount; splashes (bodies, props, tyres hitting pools) |
| | GHM FLESH | Severed limbs bleed from the stump and keep their blood; stump bleeding |
| | Collisions | Blood from physics impacts; cooldown per body (s) |
| **Elements** | Elements | Blood reacts to fire, cold, electricity, lasers, acid, energy and blasts; blood freezes on ice and snow, and in sub-zero weather; steam and smoke; flies come to pools of blood and to the dead; how many flies; most flies at once; their buzz; explosions kick up dust that sticks to fresh blood |
| | Electricity (server) | Elements on the server (wet blood conducts); shock damage to whoever stands in the blood; reach through connected blood (units); a pool stays wet for (s) |
| **Server** | Server (host / admin) | Enable on the server; replace the engine's NPC blood; players bleed; bleeding scale |
| | Multiplayer (server) | Players who arrive later see the blood left before; remember blood for (s); hand it out within (units); most records kept |
| | Compatibility (server) | Z-City: PhysBlood draws all of the blood (Z-City's off); blood sees every hit (runs before other addons' damage hooks) |
| | Collision spam protection (server) | Minimum physics damage; cooldown per body (s); max physics bleeds per second; max blood hits per second (all) |
| **Debug** | Debug | Overlay (off / stats / cell viewer / thickness colours); shading view (off / thickness / without reflections / reflections only / layer reflectance); test buttons: **Wound the model I look at**, **Pour 60 ml where I look**, **Spray**, **Print state to console** |

The **footer** shows what is being simulated right now (bodies, patches, drops, aftermath) and has **Remove all blood**, **Remove old blood** and **Reset to defaults**.

Server settings: a client cannot set a server's convars itself (on a dedicated server not even an admin from the console), so the Server and Electricity sections ask the server, which takes the change from superadmins and the listen-server host; everyone else sees the values greyed out.

---
## Feature reference

Every feature, with the files that implement it. Version numbers say when a feature came in; later changes are noted under it. (`u` = Source units: 1 u = 1.905 cm.)

### Bleeding and wounds

#### Bleeding on any model
`cl_wounds.lua` + `cl_entities.lua`. Each bleeding model gets its own cell field in the UV space of up to 4 of its materials (faces are always included). All GPU passes render a bonemerged proxy of the entity, so it works with any NPC, player model or ragdoll.

#### Wounds on the hit bone (1.10.0)
`sh_anatomy.lua`, `sv_core.lua`, `cl_wounds.lua`. A ragdoll or NPC that was hit in its first moments (spawned and shot, a fresh corpse) used to have its skeleton map read before its bones had names; the empty map was cached for the model, so every later wound on that model counted as region "other" and blood running off the body pooled under its middle. The map is now only kept once the bones are known, the region (and with it the oxygenation and the trauma: mouth bleeding from chest hits, carotid on the neck) follows the bone that was hit, and the pooling contacts include forearms, calves, hands and feet.

#### Wounds land where the bullet hit, also on the back of the head (1.21.2)
`cl_util.lua`, `cl_entities.lua`. Hitboxes overlap (head / neck / upper chest), and the wound used to take the bone whose box centre was nearest, often the chest for a shot low on the back of the head; its snap points were also crowded into the face. Now the wound takes the bone of the hitbox the client's ray struck (or, failing that, only the boxes of the hit group the server reported), snap points are spread evenly over each bone's surface (cell means on a grid, ≤ 240 per bone), and a snap may not move the point more than 4.5 u. `ghmpb_debug_hits 1` shows the server's hit point (red) and the wound on the skin (green) with the bone name.

#### Mirrored UVs: each leg bleeds on its own (1.20.1)
`cl_entities.lua` (ModelInfo), all body shaders. Character models often map both legs, both arms or both halves of the face onto one mirrored texture region. Body blood lives in UV space, so a hit on one shin used to show on both legs, and the runs and drips of one leg were driven by the other. Each material's UV triangles are now rasterised per winding; where both windings cover a large overlapping area the part is mirrored and gets a twin cell field, and every shader keeps its half by the handedness of the surface (the sign of (dP/du × dP/dv) · N from screen derivatives — the same in the UV-space passes and on screen). At most two twins per body; if the video memory budget has no room the halves share as before. `ghmpb_uv_mirror 0` turns it off; `ghmpb_uvcheck` prints the result for the model you look at.

#### Nose, ear and mouth bleeding, arterial jets, coughing
`sh_anatomy.lua` classifies ValveBiped, bip01, Mixamo, UE and creature skeletons by bone name. `cl_wounds.lua` places the nose, mouth and ear outlets on the face (from the eye attachment or the head bone). It also handles arterial jets pulsing with the heart rate (they stop after death), coughed blood for chest and neck wounds, and exit wounds traced through the body.

#### Bright arterial and dark venous blood (1.10.0)
`sim_ps30`, `stamp_ps30`, `cl_wounds.lua`. Every cell also carries the oxygen saturation of its blood (transported with the flow and mixed where wet blood meets wet blood, like the blood type). Arterial spurts are bright scarlet; chest wounds (lungs, heart), the neck (carotid) and the scalp bleed bright, oxygenated blood; limbs bleed darker venous blood; the abdomen (liver, spleen, gut) bleeds the darkest. Where an arterial spurt lands in a venous pool the colours blend per pixel. Clotting still turns all of it maroon, and drops in flight carry their own oxygenation (C++ module v4).

#### Blood supply and corpses (1.9.0)
`cl_wounds.lua`. A human body holds **4 litres** (`ghmpb_blood_volume`); other creatures scale with their size (a headcrab has a fraction of that, an antlion guard much more). Everything that leaves it — wound sources, arterial jets, sprays, mist, the pool — comes out of that budget; a body that is nearly empty only oozes and one that has bled out stays dry. A dead body bleeds fully for the first 30 s, then less and less, and after `ghmpb_corpse_bleed_time` (180 s) new wounds stay dry: the blood has settled and clotted. NPC corpses count from the death; a ragdoll spawned as a prop counts from its first wound.

#### What bleeds: blood types per creature and material (1.9.0)
`sh_config.lua` (`G.BloodTypeOf`), `sv_core.lua`. Blood type and whether something bleeds come from its real blood colour (kept when the engine blood is suppressed), its class, its model name and **what its model is made of** (the collision model's surface properties): flesh bleeds red, zombie flesh zombie blood, alien flesh / antlion yellow; machines (manhacks, turrets, scanners, rollermines, helicopters, gunships, striders, hunters, cameras…) and ragdolls or props made of cardboard, wood, metal, plastic, rubber, glass or stone (mattresses, chairs, crates, boxes, cars, skeletons, statues, mannequins) **never bleed** — not from bullets, not from collisions and not when they "die". Blood from others still lands on them and stains them (a cardboard box soaks it up like paper). A corpse bleeds the type of the NPC it came from (client-side corpses included).

#### Fire and other damage that draws no blood (1.14.0)
`sh_config.lua` (`G.IsBloodlessDamage`, `G.IsDotTick`), `sv_core.lua`, `cl_wounds.lua`. Burn, slow burn, plasma, shock, drowning, poison, nerve gas, radiation, acid, paralysis and the combine ball's dissolve open no wound and draw no blood; mixed with a wounding type (an incendiary blast, a burning bullet) the wounding part bleeds as usual. Killed by them, a body only oozes on from wounds it already had: no fatal wound of its own, no fountain, no blood from the mouth or nose. **Damage-over-time ticks** (a point or two of generic damage with no push - GHM Euphoria hurts a downed NPC by 1 point every 1.2 s, and burning NPCs go down) open no wound either; a tick that kills counts as what hurt the body before it. A corpse without wounds and without blood on it (burned, shocked, gassed) does not bleed from being bumped.

#### Corpses that fall hard burst open (1.23.2, 1.24.0)
`cl_wounds.lua`, `cl_particles.lua` (`P.Burst`). A clean corpse (no wound, no blood) does not bleed from light bumps (< 60), so burned and shocked bodies stay clean. A hit of 60 or more opens a wound; 150 or more (a long fall) bursts it open: a ring of drops thrown up from the floor under the body, all round, 15–60° up, so they land as short teardrops pointing outwards round the pour, a pour onto the floor under it and a VAT burst. `ghmpb_diag` counts the corpses smashed open.

### Drops, spray and stains

#### Droplet simulation
`cl_particles.lua` (Lua) / `native/ghm_physblood.cpp` (C++). It handles drag from the drop's Reynolds number (Schiller–Naumann, flattened by the air's Weber number), aerodynamic break-up (Weber > 12: 2–3 fragments, > 40: 4–6), surface-tension relaxation, spin, and coalescence in flight (C++). Each landing passes velocity (relative to what it hits, so a drop landing on a running NPC is judged on the relative speed), spin and stretch to the stamp shader. **Impact regimes (1.7.0)**: a fast drop that comes in at a grazing angle (below ~20°) on a hard surface **ricochets** — part of it stays as a long serrated skid streak, the rest skips on with most of its speed and lands again further along, up to twice, so it leaves a chain of shrinking streaks that all point the way it flew (cloth and soil hold the drop instead). A big, fast drop above the surface's splash threshold throws **secondary droplets** from its crown (up to 5 real drops at 15–35 % of the impact speed, mostly forward on oblique hits) that land as satellite spatter further out than the stain's own rim. Both are capped per frame so a big spray can not multiply the drop count, and volume is conserved. **In flight** each drop is drawn as a velocity-stretched sphere with the same blood optics as the films (thin drops scarlet, big ones crimson, the scene refracted through them, sun highlight, Fresnel reflection) and a tapering motion trail — what a camera shutter sees of a moving drop (`ghmpb_drop_trail`, 0 = off).

#### How a drop becomes a stain
`stamp_ps30` writes every impact pixel by pixel into the cell field of the surface it hit. The drop's velocity sets how elongated the splat is and gives it a tail, its spin twists the splat and gives it swirl momentum, its stretch turns it into a streak, and its energy adds spines and satellite drops. `force_ps30` computes the per-texel acceleration of the body (gravity plus the texel's own motion, so rotation and swinging are included). `sim_ps30` then runs the roll-off, roll-in, lift-off and evaporation steps.

#### Forensic model: what the numbers are
`cl_forensic.lua`, the droplet solvers and `stamp_ps30`. Each way blood leaves a body follows the numbers forensic science measures. **Gunshot back spatter** (entry): drops mostly < 1 mm, up to 24 ± 8 m/s, thrown back at the shooter in a wide cone (57° up, 30° down), few drops, a fine mist. **Forward spatter** (exit): up to 47 ± 5 m/s in a narrow cone (27°), many more drops, a few tissue-laden 2–3 mm drops and the heaviest mist. **Mist**: 30–100 µm droplets stop within ~0.5 m (Stokes drag, relaxation time ρd²/18μ of 8–35 ms), hang and settle at ~0.13 m/s as a short-lived pink-red cloud, and leave a fine stippled deposit on whatever is close (walls, bodies). **Blunt force**: the first blow to clean skin does not spatter; later blows throw 1–4 mm drops at 1.5–7.6 m/s from the blood already there. **Cast-off**: a bloody weapon flings a line of 1–4 mm drops tangentially off its arc on the back swing (tip speed 6–14 m/s), overhead or sideways. **Arterial**: the jet speed follows the blood pressure at the wound (v = 0.8·√(2P/ρ), 16 / 10.7 kPa systolic / diastolic), pulsing with a real pressure waveform; blood loss lowers the pressure and raises the heart rate, so the arcs shorten; the jet breaks up into drops ~1.9× the jet diameter plus a fine rain. **Expirated** (coughed) blood: fine, diluted, with air bubbles that leave rings. **Drips**: 4.2–6.2 mm drops at up to 7.6 m/s terminal speed. In flight, drag follows the drop's Reynolds number (Schiller–Naumann) and big fast drops break up (aerodynamic Weber number > 12). On impact the stain follows the Hulse-Smith relations: stain diameter D = d/2·Re^¼, number of spines N = 1.14·√We, splashing (scalloped edges, spines, satellite drops) when the splash parameter K = √We·Re^¼ exceeds the threshold of that surface (smooth metal / paint splash easily, rough concrete and soil much less, cloth soaks), stain shape W/L = sin(impact angle). **Stain anatomy (1.7.0)**: an oblique stain is a teardrop — broad and round at the back where the drop came down, narrowing and thicker towards the front where the moving blood piles up — with a thin wobbling **tail** drawn out ahead of it (the "exclamation mark" shape, the tail points the way the drop flew), often a **wave cast-off** drop beyond the tail (the tip of the blood wave that breaks off: a small separate teardrop whose narrow end points back at the parent), and below ~12° a **skid streak** with serrated sides that thins out into lanes. A drop falling into wet blood makes a secondary spatter ring instead of a spiny stain. Old pools separate yellow serum around the clot as they retract.

> **Since 1.24.0** a stain's length / width is limited to `ghmpb_streak_max` (3.5 by default, about 16°) for looks. Set it to 10 for the full W/L = sin α relation down to about 6° (see [Using it in class](#using-it-in-class)).

#### Stain length limit, short skids, straighter runs (1.24.0)
`cl_util.lua` (`U.SplatShape`), `cl_particles.lua`, `cl_runs.lua`, `cl_smear.lua`. Fast, flat drops (a body tumbling past at 1000+ u/s, spray skimming a floor) all used to come out as stains 10× longer than wide — long needle streaks. `ghmpb_streak_max` (3.5 by default, ~16°; 10 = the old look) now limits the length / width a stamp sees: the drop's speed is kept (energy, spines and splashing still follow it), only the impact angle the stamp sees is steepened, and its extra stretch is limited when over. Stains within the limit are untouched. **For angle-of-impact measurements set it to 10.** Sliding droplets after fast hits are now short skids (`ghmpb_drop_slide 1`: only above 260 u/s along the surface, 8–23 % of the drop, ~1–3 u; `2` = the long 1.19 rivulet, `0` = none). Runs on walls meander much less (heading within 26°). Body parts skimming a surface at 400–800 u/s fade their smear out instead of drawing a long line.

#### Splatter styles
Every spray is shaped by the Splatter settings. Bullets: fine back-spatter at the entry, a cone of spray along the shot at the exit. Blades (`DMG_SLASH`): a cut along the swing and an arc of stretched drops flung along it. Clubs: a short arc. Optional burst on the killing blow and a pulsing fountain from fatal neck / head / torso wounds (Samurai). `ghmpb_splatter_style <minimal|realistic|cinematic|samurai|horror>` applies a style; moving a slider makes it "custom".

#### Explosions (1.11.0)
`sv_core.lua`, `cl_wounds.lua` (`W.Blast`), `cl_forensic.lua` (`BlastSpatter`). Blast damage (grenades, rockets, barrels, `util.BlastDamage`) is sent with the point where the explosion went off, and a body caught in it throws its blood out in one violent burst **away from the blast**, in a wide, low fan like in The Last of Us Part II: drops of every size from all over the body (torso, head, limbs), heavy clumps that paint long streaks with spines, a starburst of drops on the ground around the body, a little thrown back towards the blast, and a big blood mist that leaves fine misting over the floor and the walls behind. It leaves in three quick pulses (the blast, the body being thrown, the body tearing). The side that faced the blast gets shrapnel wounds that keep bleeding (and decide where a killed body bleeds out) and is splashed with its own blood. The burst grows with the damage and is stronger for blasts right next to the body; small, distant blasts only spatter. Splatter tab → **Explosions** (`ghmpb_splat_blast`, 0 = off; Realistic 1, Cinematic / Samurai 1.6, Horror 2.5).

#### Fluid-simulated blood bursts (VAT) (1.23.0, 1.23.1)
`cl_vat.lua`, `data_static/ghmpb/vat/*.dat`, `tools/bake_vat.py`. Twelve blood bursts simulated in LiquiGen / Houdini and exported as vertex animation textures were decoded and baked into per-frame meshes (≤ 900 triangles a frame, 15 fps, 5.6 MB). In game they play as lit 3D liquid (phong shine, the light probe's ambient and key light) at: entry wounds (thrown back between the shot and the skin normal), exits (along the shot), blunt blows and cuts (along the sweep), blasts, arterial beats (one per 0.9 s per strong jet) and crowns of big fast drops landing on floors. Not beyond 2500 u or out of view; `ghmpb_vat_max` at once (oldest goes). Colours follow the blood type and the Look colour settings, with their own brightness and hue per type (`ghmpb_vat_<red|yellow|green|zombie>_bright` / `_hue`). `ghmpb_vat 0` turns them off and frees the meshes; `ghmpb_vat_info`, `ghmpb_vat_test [kind] [size] [speed]`.

#### Hanging drops (1.8.0)
`cl_particles.lua`. Blood leaving a chin, a nose, a ledge, a stair nosing or a ceiling does not fall at once: it gathers into a pendant drop that swells until its weight beats surface tension (Tate's law, ~0.1 ml for blood), then falls; above ~0.6 ml/s the feed is a thin stream, and a hard jolt of the body it hangs from shakes the drops off. The drop hangs from the nearest bone of a body and moves with it.

### Flow on surfaces: pools, runs, soaking, clotting, drying

#### The film solver: how blood flows (all versions)
`sim_ps30` (world) / `simbody_ps30` (bodies), both built from `ghmpb_sim_main.h`, is a thin-film lubrication solver: velocity u = ρh²/(3μ)·G, contact-line pinning with per-texel surface variation (gives irregular, lobed edges), a retained film, momentum, absorption into porous surfaces and drying into stain. Volume is conserved exactly. On walls, whether blood starts to run is decided by the weight of the whole connected drop above the front (a column weight carried from texel to texel), not by the height of the front texel, so big splats and gathered blood run down in narrow rivulets while fine mist stays put; wall pinning does not grow with `ghmpb_thickness` (that setting is for how deep pools stand on floors). World patches (`cl_surfaces.lua`) tile the level on demand and follow uneven ground through a traced bed map. All live patches step together and read their neighbours' border cells (ghost cells), so pools and runs cross patch borders without a seam; splats near a border are painted into both patches with the same shape. At ledges blood falls off as drops.

#### Pools grow from under the body (TLOU2-style)
Blood that runs off a lying body reaches the floor where the body touches it (torso, head, hips, upper limbs), weighted towards the wound. Pools grow from under the body along its contact line, hidden at first and then spreading out around it, and keep growing while the body bleeds out. A world-continuous micro relief of a few mm (`ghmpb_floor_unevenness`) makes pools drift into dips and grow irregular lobes.

#### Pools on real geometry: crevices, joints, walls, edges (1.8.0)
`cl_surfaces.lua`, `pforce_ps30`, `sim_ps30`, `ghmpb_surface_main.h`. Every world patch traces the real surface under it into a **bed map** (height and normal every 0.31 u / 6 mm; flat floors are recognised from 33 × 33 probes and cost one clear, anything with steps is traced over a few frames). The pool solver runs on that height field: the push across each cell edge is the plane's own gravity plus the hydrostatic head of *bed + blood*, so blood runs into mortar joints, grooves, cracks and dips first, **fills them and then spreads over the top**, and a pool over a joint stays level. The surface normals and curvature shape the contact line: blood holds at a convex edge until enough has gathered to tip over it (Gibbs' inequality), inside corners, joint bottoms and the foot of a wall wick it along, and fronts advance at the same rate in every direction (no octagonal pools). **Walls are dams**: where something solid stands on the floor (a wall, a riser, a pillar, a big frozen prop) the pool stops against it instead of draining away, and where a patch square lies inside solid its side counts as wall too. **Edges**: blood reaching a ledge wets round the nosing and runs down the face below it (stair risers, curbs, table edges) in a few rivulets, a fast stream partly jumps off as drops; a run reaching the floor at the foot of a wall or riser carries on onto the floor, so poured blood cascades down a staircase step by step; only an overhang with nothing below it drips. Blood in a joint is drawn in the joint: the overlay ray-marches the same height field (parallax), so from a low angle it hides behind the bricks, and it is lit with the real surface normal. Frozen or resting props big enough to stand on count as ground (the bed map traces them; the patch is dropped if the prop moves). A pool that is still being fed has its neighbouring patches made in advance, and when the budget is full the patch that has been quiet longest gives up its slot, so a flowing pool is never frozen along a straight line.

#### Pools level out (1.10.0)
`sim_ps30` (`ghmpb_sim_main.h`). A pool is a liquid whose surface levels within about a second - far faster than blood can move one cell per step at a few mm per cell, which before 1.10.0 left fresh pours standing as a tall dome (several cm in the middle) that took half a minute to flatten. Cells of thick wet blood on floors now also exchange blood with cells 4, 12 and 32 cells away along the axes (2, 6, 16 along the diagonals on alternate steps, so pools stay round), when the blood is continuous between them, in proportion to the difference of their heads (floor + blood + the plane's slope). The exchange is antisymmetric, so volume is still conserved exactly. Measured in game for a 200 ml pour on concrete: ~18 mm in the middle after 1 s, 6-7 mm after 3 s, ~3 mm after 6 s and ~2-2.4 mm, flat and round, after 12 s; after that the pool stays where its contact line holds it and slowly thins as it soaks in and dries. The height it stands at is evaluated at a fixed reference cell size, so it no longer depends on the quality setting (it used to get thinner at higher resolutions). Pools over mortar joints and dips level on the free surface, and pools on a slope run downhill.

#### Pools that read as liquid, join, finger down slopes; froth; sliding drops (1.19.0)
**Pool look / wet look** (`ghmpb_pool_look`, `ghmpb_shade.h`): wet blood on the world thicker than ~0.06 mm, and on bodies from ~0.015 mm, gets a stronger mirror (F0 up to ~2.8x, reflections and highlights 1.5x; on bodies it also turns glossy sooner and shows more of the key light's sheen), a bright meniscus line along its rim and on the world ~45 % more optical depth, and under it the floor is seen blurred towards its average colour (light that went through the blood and back was scattered on the way), so grout, grain and tile texture no longer print through a pool. **Contact line** (`ghmpb_sim_main.h`, floors and slopes up to ~10°): a dry cell next to the blood also looks at a ring ~2.2 cells out - a straight front covers half of it, a notch more (filled sooner), a tip less (held) - so pools round off at the scale of a few millimetres instead of following the grid; and blood on opposite sides of a dry cell (that ring, or 5 cells out along the axes and diagonals, real blood only) makes it easy to wet, so pools within ~1.5 cm grow a bridge and join. Volume is still conserved exactly; walls keep the 1.18 rule (tests/sim_hf.py mirrors it). **Slopes** (`pforce_ps30`): lanes down the slope where the surface holds the blood a little less or more, so a pool running down a slope pushes out uneven tongues. **Froth** (`ghmpb_froth`): the stamp gives landing blood a froth share (coughed / lung blood ~85 %, bright arterial spurts ~50 %, a slow venous pour ~8 %, fast impacts some); the simulation carries it with the flowing blood (in `aux.z` of floors and gentle slopes) and lets it burst (half-life ~40 s, faster as the blood clots); the film shading draws it as rafts of small domed bubbles with their own glints, lighter than the blood, and far away as a lighter veil. **Fast drops** (`ghmpb_drop_slide`, `cl_particles.lua`, `cl_runs.lua`): above ~140 u/s along the surface the stain is a little longer (at most 1.5x - long stamped streaks read as artificial) and 12-45 % of the drop skids on from the front of the stain the way it flew, at ~12 % of that speed, slowed by the drag of its contact line; it draws a narrow rivulet and keeps enough for the bead it ends in - on a wall it slows into an ordinary run. Absorbent surfaces drink it.

> **Changed since:** 1.20.0 replaced the pool-look boosts described here (F0 up to 2.8×, highlights 1.5×, 45 % more optical depth, the key light's sheen) with physical values, and `ghmpb_pool_look` became *Wetness*. 1.24.0 made the sliding droplet a short skid by default (`ghmpb_drop_slide 2` = the rivulet described here) and capped stain stretch with `ghmpb_streak_max`. 1.25.0 made impacts trap much less froth. 1.25.1 starts skids only from flat, fast, sizeable hits, at most 3 a frame.

#### Runs on walls (1.12.0)
`cl_runs.lua`, `stamp_ps30` (stamp kind 7). Wet blood on a wall (or a slope steeper than ~15°) runs once the weight of the blood above a stretch of its lower edge beats what surface tension holds there (contact-angle hysteresis: a load of ~1.6 mm² - µl per mm of edge - on paint and concrete, less on glass and metal, more on rough brick; `ghmpb_wall_runs` scales it). The load is gathered per ~1 cm lane of the wall from every splat, pour and outflow that lands there and dries / clots away over time, so big drops (≳4.5 mm), arterial hits and clusters of spatter run while mist and small drops stay. A run is a rivulet with a bead at its head, tracked on the CPU: it slides down at a few cm/s (faster the more it carries, slower as it clots), meanders in two slow waves (more on rough walls), sticks and slips on rough ones, catches in mortar joints, follows the wet trail of an earlier run (and faster there), merges with runs it meets, leaves a thin trail that is painted into the wall's cells (real blood there: it glistens, darkens and dries) and stops in a small teardrop bead when its blood runs out. At the foot of a wall it pours into the floor pool, round a bend it carries on over the slanted face, at an edge with nothing below it becomes a hanging drop, into water it mixes as a cloud. A pool reaching the edge of a step spills over and runs down the riser as a curtain of runs onto the step below. The bead is drawn with the droplet renderer. Heads move at 30 Hz (~0.1-0.2 ms per frame for dozens of runs).

> **Since 1.24.0** runs meander much less: the heading stays within 26° of straight down and catches on rough walls kink it by at most ±0.1 rad, so runs read as straight drip runs instead of looping lines.

#### Flow changes (1.12.0)
Blood stays liquid longer: the default clotting time is 180 s (was 90 s; an unchanged old setting is moved over once), and clotting blood gets up to ~30× more viscous and pins less (was 45×), so pools keep creeping and runs keep going a little longer. Hanging drops are also drawn when no drop is in flight (they could disappear between drips).

#### Runs on bodies follow creases (1.8.0)
`force_ps30` measures the curvature of the skin / clothes: creases, folds and the gaps between limbs catch the runs, ridges shed them.

#### Drips onto surfaces and onto other bodies
Drops landing on another model are stamped into *that* model's cell field and keep running over it. Lift-off and run-off are read back from the GPU and become real falling drops.

#### Coagulation and drying
Every cell also carries its clotted volume. Clotting is autocatalytic (slow start, then fast gelation, `ghmpb_coag_time`). Clotted blood is up to ~30× more viscous (1.12.0; 45× before) and pins harder, so runs slow down and freeze. It darkens (deoxygenation) and gets a matte, wrinkled skin. Drying then turns it into a brown crust with shrinkage cracks and a darker coffee ring.

#### Surface materials and how blood looks on each (1.9.0, 1.16.0)
`sh_config.lua` (`G.Surface`, `G.SurfaceKindOf`), `cl_surfaces.lua`, `cl_particles.lua`. The surface under the blood is recognised from its **surface property** (`brick`, `plaster`, `cardboard`, `glass`, `metalgrate`, `sand`, `snow`, `grass`, `rubber`, `water`… — much finer than the engine's material type), falling back to the material type. Each kind has its own soaking and flow: **glass / ice** perfectly smooth (blood beads up, runs fast, stays glossy), **metal**, **tile / plastic** (sealed), **rubber**, **concrete / stone** (a little absorption), **brick** (porous: drinks thin blood into a dark matte stain, pools stay small), **plaster / drywall** (absorbent, feathered edges), **wood**, **paper / cardboard** (soaks through almost at once and spreads in the fibres), **carpet / cloth**, **soil**, **sand** (sinks in where it lands), **gravel**, **grass** (caught by the blades, soaks into the soil), **snow** (melts in and spreads into a wide soft stain), **grates / chain-link** (most blood falls through the holes and lands on what is below) and **water / slime** (blood dissolves, no stain). Props that do not bleed take the response of what they are made of. **1.16.0 - how fast each surface soaks blood up** was retuned and split further: **concrete / asphalt** is now its own kind (porous: thin blood soaks in), dense **stone / rock / marble** hardly absorbs at all, **ice** is its own kind (smooth like glass, a touch of melt grips the blood, and the cold keeps blood wet ~2x longer), **snow** drinks blood fastest and holds the most (and keeps what stays on top wet longer), **sand**, **carpet** and **soil** take it up faster than before. **And the blood looks different on each** (`ghmpb_material_look`, Bleeding tab): blood soaked into a porous surface keeps the colour of the blood instead of drying to a brown crust, darker and matte, browning only slowly in the aftermath; a **halo** forms around the stain - damp, darker ground around blood on concrete, brick, wood, soil, sand, gravel; a pale serum fringe in plaster, paper and carpet; pink melt water in snow; **snow** turns the stain a bright, diluted pink-red that sinks into a hollow and keeps red for a long time, with ice crystals glinting through thin blood (ice glints too); **sand, soil, concrete, carpet** speckle the edges of thin blood with their grain, on **gravel** it runs into the gaps between the stones, on **grass** it hangs on the blades; dried blood **cracks** into crisp flakes on glass, metal and rubber and not at all where it soaked in. Pools stay pools: thick blood is levelled.

#### Blood on clothes
Cloth soaks blood up: a soft, irregular, damp halo spreads past the edge of every stain along the fibres, wet cloth darkens and loses its sheen, and dried blood on fabric stiffens and darkens without the cracked crust it forms on hard surfaces.

#### Blood follows the surface's normal map (1.21.0)
`cl_bsptex.lua`, `cl_surfaces.lua`, `pforce_ps30`, `ghmpb_surface_main.h`. The engine gives Lua no texture coordinates of world faces, so the map file is read once in the background (planes, texture data, texinfo, faces; about 4 ms a frame until done) and every world patch finds the face and the `$bumpmap` (or self-shadowed bump map) of its material. Thin blood and dried stains are then shaded with the surface's own normal map, and the normal map's curvature is added to the flow: grooves, grout lines and joints draw thin blood along them, and the tilt of the bumps raises the contact-line pinning. Deep pools level it out (the fill blends by the relief depth of the surface kind: glass 0.02 mm … gravel 2.5 mm). `ghmpb_surface_normals 0` turns it off.

### Transfer patterns: smears, prints, tracks, splashes

#### Smearing and wiping
Every body part keeps a CPU estimate of the blood on it (fed by every stamp on the body, drained by smearing, lost to clotting and drying). A corpse part touching the ground (or slamming into a wall) and moving leaves a streaked smear along its path (stamp kind 3: ragged edges, striations along the motion, gaps where it lifted). The depth of blood under each contact is probed from the live world cells on the readback pass: moving through a pool wipes part of it up and shoves the rest along (stamp kind 4), and the body picks the blood up and carries it on to the next smear.

> **1.18.1**: a body first seen before its bones existed used to leave its whole model without smears for the session (fixed), and props that roll, slide or are dragged through blood wipe the pool, pick it up and leave a track. **1.24.0**: a part skimming a surface at 400–800 u/s fades its smear out instead of drawing a long line; pushing and wiping blood already there is unchanged.

#### Bloody footprints and creature tracks
`cl_footprints.lua`. The depth of blood under the feet of every player and NPC near wet blood is probed from the GPU along the path they walk (live cells, or a settled pool that has not dried yet). Stepping in blood loads that sole with about half the depth it stood in. Steps come from the distance walked, alternating left / right, toed out a little. Each step prints the sole (stamp kind 5: forefoot, the outer edge of the shank, heel, chevron / block tread): a soaked sole prints solid and glossy, then the print breaks up to the lugs and fades out after several steps, while the blood left on the sole slowly goes tacky. Prints are ordinary blood on the world, so they dry into stains and settle into the aftermath layer. **1.16.0 - only humans print shoe soles**; creatures leave their own tracks (stamp kind 5 with a creature shape, sized to the creature): **headcrabs** a diagonal trail of small leg-tip dots (fast headcrabs a wider spread, poison headcrabs bigger), **antlions / antlion guards / striders** pointed claw stabs splayed out from the body with a faint drag mark, **hunters** the three pads of their tripod, **crows, pigeons, seagulls, vortigaunts and the robot dog** three-toed prints, an unknown four-legged creature paws (pads when small) at the corners of its bounds. **Nothing**: flying, rolling and legless NPCs (manhacks, scanners, rollermines, turrets, barnacles, grubs, zombie torsos, gunships...). HL2 NPCs are known by class; workshop NPCs, NextBots and player models by their skeleton - a head on a spine standing upright on two legs prints soles, without legs nothing, any other build creature tracks.

#### Hand prints (1.13.0)
`cl_hands.lua`, `stamp_ps30`. Every character near the camera - NPCs, players (others, and yourself in third person), corpses, ragdolls, GHM FLESH's severed arms - has its hands followed. The hand's frame comes from its finger bones (fingers from the wrist to the middle knuckle, the palm facing away from the back of the hand, worked out from the index and little finger knuckles and the side), so a print lands where the palm really is, points where the fingers point and has the thumb on the right side (hands with fewer finger bones, like the HL2 citizens' three, use the middle finger instead of the little one). A hand counts as touching when its palm faces a floor, wall or anything that counts as ground and lies on it; a hand lying on its side or back, or trailing on its wrist or knuckles, touches a floor too (wrist, palm and finger tips are tested). A body out of view has its bones set up when a hand of it could print (except one GHM FLESH has cut: its bone callback must not run outside a draw). The blood on a hand is the per-part estimate every body keeps (wounds, drips and drops on the hand, part of what is on the forearm running down) plus what it picks up from a pool it rests in or is dragged through. A hand coming down prints the palm (heel pads, a lighter hollow, the creases left bare), four fingers with their joint creases and the thumb - solid when soaked, only the pads as it dries, then broken-up patches; each print takes blood off the hand. A hand dragged along leaves four parallel finger streaks - on its side or knuckles one narrow, broken smear that fades as the hand runs dry - and a side coming down leaves a small blot; dragged through a pool it wipes part of it up and shoves the rest along.

#### Props in blood (1.13.0)
`cl_props.lua`. Physics props near wet blood (or carrying blood) are followed: where the prop's own collision model touches the ground is found by tracing a 3 × 3 grid over the bottom of its box against the prop alone (a crate's whole bottom, a chair's legs, a tipped barrel's edge), redone when it tips over. Standing in or on a pool (depth probed from the GPU) the underside picks blood up - a thin film on metal, plastic or painted wood, much more on cardboard, cloth, soil or raw wood, where it soaks in and wicks up the model in its own cell simulation, and the pool loses what was drunk (a film of about 0.03 mm on sealed things up to about 0.3 mm on absorbent ones, reached over a few seconds). Models whose sides share one texture (a crate whose six faces use the same picture) have the blood their underside takes up drawn that much thinner, since it shows on every side sharing those texels. Dragged, pushed or sliding, the blood on the underside is smeared out behind it, and moving through a pool wipes part of it up and shoves the rest along. Dropped or thrown into a pool it splashes (below: the ground under a prop that is off the ground near blood is probed ahead, so the depth is known when it lands) and its underside gets splashed; set down hard with a bloody underside on a clean floor it leaves a short print.

#### Tyre tracks and skid marks (1.13.0)
`cl_tyres.lua`, `stamp_ps30`. Wheels of HL2 vehicles (the engine's `wheel_fl` .. `wheel_rr` attachments: jeep / buggy, jalopy), simfphys (`gmod_sent_vehicle_fphysics_wheel`), LVS (`lvs_wheeldrive_wheel`), Glide (`glide_wheel`) and any other entity whose class names it a wheel. The depth of the blood is probed from the GPU **ahead** of each tyre (an answer takes up to 0.3 s, by when a fast car is 100+ u further on: the ground is asked where the tyre is going to be, and each answer is used when the tyre gets there - or, answered late, the track is filled in behind it). Rolling through a pool wipes a channel the width of the tyre through it (the rest is shoved along; a deep pool flows back) and loads the tread; a loaded tyre prints its tread (lug blocks between circumferential grooves, laid out in world space so the pattern runs on seamlessly) along the path it rolls - the circumferential grooves always lighter, the gaps between the lugs filled at first, then the lugs, then patches - and each turn of the wheel gives off part of what is left, so a track fades out after a few metres. Sliding tyres print no tread: drifting, locked brakes and wheelspin smear the blood into streaky skid marks, and skidding through a pool drags it out along the skid. Fast through a pool the tread throws a spray of drops. Slip comes from the vehicle base where it has one (Glide side / forward slip, LVS skid value, simfphys skid level), otherwise from the wheel's motion (sideways speed against the car's heading - for HL2 vehicles from the line between their axles, since the models do not agree on a forward axis - or hard braking). The tyre radius comes from the base (Glide, LVS) or is measured from the ground.

#### Splashes (1.13.0)
`cl_contact.lua`. A body part, a prop or a tyre hitting a pool hard throws part of the blood under it out as a crown of drops - more and faster the harder the hit and the deeper the pool, leaning forward with the motion - and pushes the pool out from under it (a crater that flows back). The landing point is probed from the GPU while the thing is still falling, so the splash comes on the frame it lands. `ghmpb_splash` scales them (0 = none).

### Look: optics, light, reflections, colour

#### Physically based blood (1.20.0)
`ghmpb_shade.h`, `tools/pbr/`. The light falling on blood is recovered from the lit frame divided by the surface's measured albedo. Before 1.20.0 that was done per colour channel, so errors in the albedo (gamma-space texture means, blended displacement textures, model textures with baked shading) became coloured, too-strong light: pools read thin, orange and see-through, "juice or jelly". Now the irradiance is a luminance ratio with an albedo floor (only 30 % of the light's colour kept), levelled pools have relief only at the rim, and the extra boosts of 1.19.0 are gone: F0 0.027 for wet blood, 0.04 for a dry crust, liquid roughness 0.03. The optics were checked against spectral ground truth (Prahl's haemoglobin / oxyhaemoglobin absorption, reduced scattering 1.6·(600/λ), Kubelka-Munk, CIE 1931): a thick oxygenated pool at a 0.25 floor's light comes out at sRGB ≈ (99, 11, 14). Dried blood was refitted with ageing (fresh → aged absorption and scattering in the aftermath layers); a crust that kept its surface gets a Saunderson term; flying drops are opaque. Settings were renamed for what they now do: `ghmpb_pool_look` = **Wetness**, `ghmpb_reflections` = **Shine** (scales highlights too), `ghmpb_gloss` = **Gloss (sharpness)**.

#### Shading: optics, light and reflections (1.6.0)
`ghmpb_shade.h` (1.6.0 PBR pass). **Colour pipeline**: the frame, model textures and cubemaps are read raw and decoded to linear light in the shader, and the result is encoded once on write (before 1.6.0 the hardware converted as well, which doubled the gamma and washed blood out to pink). **Diffuse**: Kubelka–Munk layers — the dried stain, then the wet blood — over the surface, in four wavelength bands from the haemoglobin absorption spectra (Prahl) and the red cells' scattering; the red band is split at 615 nm, which is what turns thin blood scarlet and deep blood crimson. The liquid surface traps about half the light scattered back inside it (Saunderson correction), so wet blood is darker and more saturated than dry. Clots scatter more, dried blood is met-haemoglobin brown with a coffee ring and shrinkage cracks. Lit by the irradiance recovered from the lit framebuffer divided by the surface's measured albedo (lightmaps, dynamic lights, flashlight and shadows are all exact), with the relief of beads, drops and pool rims shaded from the light probe. Thin films on surfaces blood only partly wets (skin, paint, metal) break up into beads and smears instead of a coat of paint. **Specular**: F0 = 0.022 dielectric, GGX highlights from the sun, the dominant local light and the flashlight, a screen-space reflection of what stands around a pool with the cubemap elsewhere (roughness-filtered, Fresnel-weighted, horizon-occluded), specular anti-aliasing. A pool is a flat mirror with a meniscus at its rim; a thin film keeps the micro roughness of the skin, stone or cloth under it; gelled blood gets a satin skin, a dry crust a matte-satin sheen.

> **Since 1.20.0** F0 is 0.027 (wet) / 0.04 (dry crust) and the light is a luminance ratio (see *Physically based blood*). **Since 1.25.0** reflections come from live reflection probes (the map's cubemap only as a fallback), screen-space reflection is weaker where a probe exists, and the map's lamps add highlights. **1.25.1** adds mirror reflections on wet floors and rim glints.

#### Thick, opaque blood
Blood is a turbid medium, so the layers are shaded with the Kubelka–Munk two-flux model: the floor shows through a smear, a pool shows only the blood's own colour. Thin edges and splatter are scarlet and translucent, a pool is deep crimson, clotting blood goes maroon.

#### Fresh blood (1.18.0)
`ghmpb_shade.h`. The edge of a pool or a drop rises steeply and rounds over into its top (the meniscus of a thick liquid), deep pools stand a little taller, and the steep rim is a little darker - fresh blood reads as a body of liquid with a thickness, not a print. Still-liquid blood has a faint slow swell over its surface (no perfect mirror), small **air bubbles** catch the light in bright spurts and many in frothy blood from the lungs (they burst as it gels), running blood shows fine **streaks along its flow** instead of round ripples, and a congealing pool pulls together into soft, darker **clot lumps**.

> 1.20.0 removed the slow swell over fresh pools and the key light's sheen (with the per-channel light error they read as jelly).

#### Reflection probes, the map's lights, opaque thick blood (1.25.0)
`cl_probes.lua`, `cl_maplights.lua`, `ghmpb_shade.h`, `probeblur_ps30`, `probeenv_ps30`. **Reflection probes**: blood is grouped per 256 u cell (live patches count double), and the `ghmpb_reflect_probes` (2) groups that matter most — closest, in front, most blood — get a live cube map rendered from 10 u above the middle of the group, one 128 × 128 face at a time within `ghmpb_reflect_budget` ms a second (a quarter of that while the adaptive quality is holding the frame rate), plus blurred 32 × 32 faces for rough blood. The reflection is parallax-corrected against a sphere fitted to the room (14 traces). A new probe starts with the map's cubemap; blood without a probe reads a fallback probe around the camera. **The map's lights**: the BSP's light lump (point and spot lights with their real falloff and cones), `light_dynamic`, `env_projectedtexture`, `point_spotlight` and other players' flashlights; the 4 strongest visible at a probe give GGX highlights on wet blood. **Opaque thick blood**: under a layer thicker than ~0.1–0.45 mm (wet; 0.2–0.7 mm dried) the floor gives way to the blood's own colour — a pool shows only blood, not the floor texture through it; flying drops no longer refract. **Edges**: wider anti-aliasing and half-strength surface grain at stain edges. **Froth**: impacts trap much less (no pale dotted rings). **Dried stains**: a darker, wider rim and per-stain variation of age and density.

#### Floor mirror reflections, rim glints, fewer thin lines (1.25.1, not yet tested in game)
`cl_probes.lua`, `cl_particles.lua`, `cl_runs.lua`, `ghmpb_surface_main.h`, `ghmpb_shade.h`. The 1.25.0 in-game check found pools looking pale or brownish at low view angles (physically right: a flat liquid mirrors the bright walls behind it at grazing angles, but the blurry probe made it read as a pale film), probe reflections hard to see, no clear flashlight shine, and thin long lines in rifle exit spray.
- **Mirror reflections** (`ghmpb_reflect_mirror`, on by default): the most important wet floor height in front of you (wet floor blood within 1600 u, weighted by distance, every 0.25 s) gets a real mirrored render of the scene, 1024 × 512, clipped at the floor plane, every frame (every other frame when the adaptive quality is under heavy pressure). Smooth wet blood on that floor shows bodies, props, walls and lamps around it as a sharp, correct reflection, like water — instead of screen-space reflection, which only works at grazing angles. Rougher, clotting or dried blood keeps the probe reflection. The probe atlas grew to 1024 × 1024 to hold it. `ghmpb_diag` reports the mirror plane and its cost.
- **Rim glints**: the steep meniscus at the edge of wet blood catches the flashlight as a bright rim line on floors and walls; on bodies also the sun and the map's lights.
- **Fewer thin lines**: a skidding droplet only starts from a flat, fast, sizeable hit (drops of 0.55 mm radius or more hitting a floor at under ~25°, or drops of 1.5 mm radius or more at under ~37°, moving faster than 300 u/s along the surface; at least 1.2 µl), at most 3 a frame, and its trail tapers as it slows. A rifle shot used to start ~70 skids. Runs on walls stay fully physical (no per-burst cap).
- 31 mock test files pass; shader set b74. Not yet verified in game.

#### Smooth, non-blocky edges
The cell field is read with a bicubic B-spline filter, the outline is anti-aliased with screen-space derivatives, and (mode 2) a sub-texel organic noise that is continuous across patches breaks up the grid. `ghmpb_quality 4` doubles the default world resolution.

#### Blood colour mixing (1.9.0)
`sim_ps30`, `stamp_ps30`, `bake_ps30`, `ghmpb_common.h`, `cl_surfaces.lua`, `cl_entities.lua`. Four blood types: red, yellow (antlions, aliens), green and **zombie** (dark brown-red with an olive cast, `BLOOD_COLOR_ZOMBIE`). Every world plane and every body carries up to two types, and every cell keeps how much of its blood (wet + stain) is the second type. That amount moves with the flowing blood exactly like the volume (conserved), and where wet blood touches wet blood of the other type the two **mix** (a symmetric exchange between neighbouring cells), across patch borders too (the patches export their mix and oxygenation to their neighbours' ghost cells). The shading blends the optical absorption of the two types by their share per pixel (Beer–Lambert mixing), so zombie blood running into a red pool gives a smooth brown-to-red gradient where they meet instead of turning the whole pool zombie-coloured; poured on top, it tints the pool as it spreads and mixes. The mix is baked into the aftermath layer and dries with it. Drops carry their own type in flight (drop shader, C++ module v3), mist clouds are tinted per type.

#### Blood colours match everywhere (1.14.1)
`cl_smear.lua`, `cl_surfaces.lua`, `cl_entities.lua`, `cl_hands.lua`, `cl_props.lua`, `cl_util.lua` (`U.BloodColour`), `cl_water.lua`, `cl_particles.lua`, `cl_forensic.lua`. Blood that is carried somewhere else keeps its type (red, yellow, green, zombie): **footprints**, tyre tracks, splashes and everything else that picks blood up from the floor read the type of the blood at that very point from the GPU (a world plane holds two types; the probe reads how much of the blood there is the second one) - before, they took the type with the most blood on the whole plane, so a yellow pool on a floor with more red blood elsewhere left red footprints. Drips off a pool and flow into the next patch take the type of that patch's blood (by volume). Every body part keeps which share of its blood is another type than the body's own, so a citizen's hand dipped in an antlion's pool prints yellow, a corpse covered in zombie blood smears it, and drips off a body are the blood that is on it there; a prop's underside prints the blood it picked up. Wipes no longer register the wiper's type on the floor. **More than two blood types on one floor**: the two types a surface mixes per pixel used to belong to a whole plane - on a big floor a third type anywhere (zombies next to citizens next to antlions) was drawn in the colour of the second; they now belong to a region of about 3 × 3 m (4 × 4 patches), a new region starts with the pair of a neighbouring region that has the type, and where pools cross a border between regions with different pairs the simulation converts the type share at the border (`sim_ps30`, shader set b53). **Clouds in water and mist** had fixed colours per type; they now come from the same optics as the stains (the four-band absorption per type and oxygenation, with the hue and fresh-blood brightness settings), so a green or zombie stain and its cloud are the same blood.

> **1.18.1**: yellow, green and zombie blood keep their colour where a pool spreads (no red beads and drips beside it); yellow pools read mustard yellow, zombie blood olive-brown.

#### Blood colour settings (1.10.0)
Look tab: fresh-blood brightness (lighter / redder or darker / more opaque wet blood), dried-blood brightness (rust-brown or nearly black stains and crusts) and hue (warmer, towards orange-scarlet, or cooler, towards deep crimson / purple). They act on the blood's optical absorption, so thin splatter, pools and crusts all stay consistent, and apply to every blood type, flying drops included. The brightness curves are steeper than linear so they also show on thick pools, which stay dark at any absorption.

#### Lite renderer: no custom shaders (1.22.0)
`cl_lite.lua`, `materials/ghm_physblood/lite/`. What a Workshop install runs (the Workshop does not allow `.vcs` shaders). `ghmpb_render_mode 0` uses the shaders when their files are installed, else lite; `1` forces shaders, `2` lite (switching clears the blood). **World**: every stain is a quad from one texture atlas (splats, oblique drops, pool, run, smear, shoe, creature pad, hand, tyre, mist, small drop, bead) drawn in two passes — a modulate pass that darkens and tints the lit surface under it (lightmaps, shadows and flashlight stay exact) and, while wet, an additive shine with the cubemap and the blood's own lit colour. Transmittance comes from the same four-band optics; dry stains brown with thickness. Stains are batched into static meshes (`ghmpb_lite_stains`, 3000 by default). **Pools**: one record per pool that grows from its volume, traces room to grow in 8 directions, stops at ledges and walls and joins neighbours. **Bodies**: engine model decals per shape and blood type, coloured by the colour settings; wound outflow runs downhill along the skin as a chain of drip decals and drips off; decals move onto the corpse. **Drops**: velocity-stretched sprites. Not in lite: liquid flow on surfaces, film relief, refraction, froth, live clotting and drying, smears on bodies, explosion dust, wash-off under water. `ghmpb_lite_info` prints its state.

#### Where the shading ideas came from
The film shading started from an NVIDIA HLSL blood shader. Its ideas are carried into `ghmpb_shade.h`: the thickness-driven normals, the wet/dry blend and the absorption colour ramp.

### Environment: water, elements, dust, flies

#### Blood in water (1.12.0)
`cl_water.lua`, `sim_ps30` / `simbody_ps30`. Blood is miscible with water and a little denser, so under water it does not stain: drops that fly into water, wounds bleeding under water, hanging drops over water, runs and pools reaching water and blood washed off bodies all become **clouds** that roll up (a drop plunging in leaves a sinking thread behind its plume), sink, drift, spread by turbulent diffusion, lie flat in shallow water and fade. How red a cloud looks follows its haemoglobin optical depth (volume over area), so a drip makes a small plume that is gone in seconds and a body bleeding into a lake a crimson cloud that lasts a minute or more. Nearby blood joins an existing cloud. Clouds are drawn as lit, water-fogged sprites in the engine's water refraction view (seen from above through the surface) and in the main view under water. World patches that reach into water get the height of the water surface: there the blood thins (the contact line hardly holds), does not dry or soak in, and washes out into the water (fresh blood over several seconds, clotted blood and dried stains much slower, `ghmpb_water_wash`); along the water line the wet ground holds a pool's edge less and drinks almost nothing, so pools run out thin into the water. A body lying in water loses the blood on its submerged part the same way. **Fixed**: blood on bodies (and pools) under the water surface was not drawn in the water refraction view, so it vanished when an NPC went under water and came back when it surfaced. With the eye under water the engine draws two views into the screen each frame (first what is above the water, then the main view under water); only the main view calls `GHMPB.Entities.DrawStatic` / `DrawOverlays`, which other addons may wrap to draw their own layer on bodies once a frame (GHM Flesh draws its wounds there): called from the first pass or from the refraction view, that layer went missing on bodies in water when the player dived, and on everything above the water while a water surface was on screen. The extra water views draw through `GHMPB.Entities.RawDrawStatic` / `RawDrawOverlays`.

#### Elements (1.17.0)
`sv_elements.lua`, `cl_elements.lua`, `elem_ps30.hlsl`, `ghmpb_shade.h`. **Fire** (a burning NPC, body or prop, `env_fire`, vFire, burning damage) boils the blood under and on it - bubbles swell and burst, it steams, cooks brown and dries to a crust; dried blood kept in the heat **chars** black (decals that stay with the map) with glowing embers, and a burning body's blood boils off and chars with it. **Plasma** does the same, fast and violet-hot; a **hot crossbow bolt** that stuck hisses in the blood. **Cold**: blood on **ice** (~50 s) and **snow** (~90 s), and outdoors in sub-zero weather with **StormFox 2**, **freezes** - it stops running and drying, turns dark and glassy under a fine veil of hoarfrost with glints, and feet no longer pick it up; fire thaws it. **Fresh, warm blood steams** in the cold for its first minute. **Electricity** (sparks, zaps, stun sticks, rollermines, tesla coils, shock weapons, `env_beam`) near **wet blood runs through every pool connected to it** and **shocks every NPC and player standing in it** (`ghmpb_sv_elec_damage`, less the farther along the blood; whoever made the spark too): arcs crawl over the blood, it flashes blue-white and fizzes. The server keeps a coarse map of where blood lies (the pools of the dead, drips, trails, spatter), wet for `ghmpb_sv_wet_time`; boiled-dry and frozen blood does not conduct. **Lasers** (energy-beam damage, `env_laser`, laser / plasma ammo of other addons) boil a hot, glowing spot that spits tiny drops; swept over a pool they cut a boiled line; on dried blood they char it. **Acid** (antlion workers' spit, acid damage) mixes into the blood (yellow-green), dissolves dried blood back into the liquid, foams and gives off a green vapour. The **Combine energy ball** vaporises a lane through the blood it rolls over, and a dissolving body's blood flashes off in a red mist. **Blasts, sonic damage, thumpers and the gravity gun's punt** slosh pools outwards and throw shallow blood up as drops. **Radiation** makes blood glow faintly green. `ghmpb_elements`, `ghmpb_freeze`, `ghmpb_elem_steam` (client), `ghmpb_sv_elements` (server); Elements tab. Other addons: `GHMPB.Elem.Add(GHMPB.EL.COLD, pos, radius, strength, seconds)` on the client (a freeze gun), `GHMPB.Elem.Send(...)` / `GHMPB.Elem.Discharge(pos, strength, attacker)` on the server.

#### Explosion dust (1.18.0)
`cl_dust.lua`, `sv_elements.lua`, `elem_ps30.hlsl` (op 14), `dustaft_ps30.hlsl`, `ghmpb_dust.h` (`dustworld_ps30`, `dustbody_ps30`). A blast kicks up what the ground is made of - **sand, snow, soil, concrete or stone dust, plaster, brick dust, splinters, grit**, soot on hard floors - found from seven traces around it, with the explosive's soot near the centre. A low ring of dust in the ground's colour rolls out and grit rains down (with GHM PhysFX installed its own simulated dust and smoke are the cloud instead); over the next ~5 s the dust settles over a disc that grows from the blast. On dry ground it is lost in the ground; **fresh blood catches it**: in clumps (rafts and crusts on a pool, specks on thin films), it soaks the blood up (soaked through it turns dark red-brown - the light between the grains passes through the blood many times - while grains sticking out of a thick crust stay lighter; browning as it dries) and dries with it into a gritty, matte crust with a little wet glint between the grains. A little dust is scattered specks and small rafts, a lot is a crust with holes where the blood shows. **Snow** melts into the warm blood as pink-red slush. Settled pools and baked bodies near the blast catch it too, and it stays when the blood settles. One dust event per blast - from blast damage, explosion sounds, grenades / rockets / satchels / tripmines going off, explosive barrels and gas cans blowing up, `env_explosion`, and the explosion's own sound on each client (so a grenade on an empty floor next to a pool counts too; the map's distant battle ambience does not); thumpers shake up a little. `ghmpb_blast_dust 0` switches it off.

#### Flies (1.18.0)
`cl_flies.lua`. Outdoors and in the warm, flies find blood within minutes: here the first come ~20 s after a pool forms or a body dies and the swarm grows over two minutes. They circle and dart over the blood, **land only where there is blood** (spots are checked against the simulated blood; on a body: its wounds and its face), crawl about, take off and land again - most on moist blood, less on old dried crusts, fewer as a pool gets old - and **scatter** when someone walks up, a shot hits the body or a blast goes off - they make off a few metres the other way and come back once it is quiet (someone standing right in the blood keeps them off; a still onlooker a step away does not). Only the dead draw them: someone knocked down and still alive (a GHM Euphoria knock-down - the server marks that ragdoll - or a Z-City fake ragdoll) does not, nor does a body that moves (they settle once it has lain still for a few seconds), and a body's swarm starts its clock at death. (GHM FLESH has flies of its own around rotting corpses: `ghm_flesh_flies`.) None in the cold (StormFox 2 below ~10 C, snow, ice), none under water, fewer indoors, at night and in rain. Each fly is a tiny dark body with wings (a pale blur in flight), lit by the light where it is; the buzz comes from the flies in the air within a couple of metres of you (feeding flies are quiet). `ghmpb_flies`, `ghmpb_flies_amount`, `ghmpb_flies_max`, `ghmpb_flies_sound`.

### Persistence, performance and scale

#### Aftermath layer (settled blood)
Blood that has stopped moving is baked into a compact RGBA8 texture per world patch / body material (at the resolution of the live cells, so settling does not blur it) and drawn as its own layer underneath fresh blood. It keeps drying at the same thickness-dependent rate as live blood (splatter in minutes, deep pools many times longer), and dried blood stays clearly visible: a stain absorbs about as much as the wet film it came from, turning rust-brown when thin and black-brown when thick. It costs no simulation (its geometry is a static mesh built once), can be kept forever (`ghmpb_keep_forever`) or fade out after a set time, and is capped by count. New blood on old stains merges into the same layer when it settles, without making the old stains look wet again.

#### Video memory budget
Render targets can not be freed in Garry's Mod, so they are never created beyond `ghmpb_vram_mb`. All limits are scaled down together when the settings would need more; a patch or body that finds the budget full waits for an evicted one.

#### Performance with a lot of blood (1.14.0)
`cl_prof.lua`, `cl_governor.lua`, `cl_render.lua`, `cl_util.lua`, `cl_entities.lua`, `cl_wounds.lua`. Measured with a frame profiler that is always on (`ghmpb_prof`) in a stress scene (13 corpses, 26 limbs cut off by GHM FLESH, ~1400 drops in flight): the mod's CPU time fell from about 50 ms to 20–27 ms per frame under load. **Reading the GPU back** (drips, flow into the next patch, pool depth probes) made the CPU wait for the whole frame's GPU work: 20–35 ms every 0.3 s, a stutter three times a second. The reduce is now drawn at the end of a frame and read at the start of the next, before that frame queues any GPU work (0.2–0.3 ms when the GPU keeps up); when the GPU is the bottleneck the read still waits, and the interval grows with the measured wait. **Hits on bodies**: the bone frames, hitboxes and mesh points of a body are read once per frame into plain numbers, and the nearest bone, the snap to the skin and the drop-vs-corpse tests run on numbers (nearest bone 34× faster, snap 8× faster, same results). Drops landing next to each other on a body before its next stamp pass become one stamp. **Wounds** trace the floor under themselves every 0.4 s instead of every tick and pour what reaches the floor every 0.3 s. **Bodies behind the camera** are not drawn and simulate at a lower rate.

#### Adaptive quality (1.14.0)
`cl_governor.lua`. Twice a second the frame time is compared with `ghmpb_perf_target_fps` (default 60; a lower `fps_max` counts). While the frame is slower and the blood is a real part of it, a pressure 0..1 rises; well under the target it falls again. Under pressure, far, hidden and settled blood loses detail first: bodies away from the camera or behind it simulate less often (with a longer step, so blood still runs and dries in real time) and re-render their force field less often; fewer bodies are simulated at once (limbs count half) and a settled body is only woken if it matters more than one being simulated, never right after it settled (bodies hit by drops used to be baked and woken every frame); settling comes sooner; world patches step less often; the GPU is read less often; flying drops get a smaller collision budget and a lower cap; jets and sprays throw fewer, bigger drops (the same blood); wounds away from the camera tick less often. Blood near the camera keeps its detail. In the stress scene at full pressure: 12 live bodies instead of 29, 19 body simulation steps per frame instead of 90, 33 world patch steps instead of 90. The pressure holds while the game window is in the background (the engine caps the frame rate there). `ghmpb_perf_adaptive 0` switches it off.

#### Large battles (1.16.0)
`cl_battle.lua`, `cl_governor.lua`, `cl_particles.lua`. Twice a second the size of the fight around the camera is measured - living NPCs and players that bleed within 4000 u, hits a second, bodies bleeding right now - as a level 0..1 (0 up to ~12 combatants / ~6 hits a second / ~8 bleeding bodies, 1 at ~40 / ~40 / ~32). It rises within a second and falls over ~10 s. It acts next to the frame-time pressure, before the frame rate drops, and **never on blood near the camera and in view** (within ~700 u; up to ~1600 u only partly): blood far away or out of view simulates at lower rates, settles sooner, its wounds tick in bigger steps and its jets throw fewer, bigger drops; fewer bodies are simulated at once (the nearest and most visible keep their slots); contact checks and the GPU readback run less often. **Far drops**: a drop far from the camera (2500 u, 1400 u in the biggest fights) or out of view in a big fight does not take a collision trace every frame - its flight is integrated in closed form and traced in chords of 8 steps (160 traces a frame for all of them), and it lands on the same spot (within ~0.4 u in the tests) at the same time; mist far away or out of view is skipped. A small fight keeps every bit of detail. `ghmpb_battle_lod 0` switches it off (Quality tab → Frame rate → *Scale with the size of the fight*).

#### Collision spam protection
Server: physics / crush hits need a minimum damage (twice as much on corpses), have a cooldown per body and a per-second budget for the whole server; blood messages in general have a per-second cap (fatal hits always pass). Client: a per-body token bucket for physics hits, corpses bleed much less from collisions and never start new bleeding from them, and blood flung off a body by its own motion is limited to 1.5 ml/s per body.

#### Fixes and speed-ups (1.11.1)
**Double stains on relief walls**: on bricks, cobbles and other stepped surfaces a second, shifted copy of every stain was painted next to the real one (a fallback in the parallax shader that drew the pixel where the view ray entered the relief when the ray ended outside the blood). Removed; the ray march now also refines the hit by bisection and does not smear the blood down the sides of steps (brick edges over their joints showed a comb of streaks at grazing angles). **Performance**: the simulation skips cells with no blood anywhere near (most of a patch or body texture; they cost almost nothing now), and the shading of world and body blood only runs where there is blood (before, every pixel of a patch's quad and of a bloody body ran the whole shader); the view ray march takes as many steps as the view needs (2 on a steep view instead of 14), patches outside the view are skipped before any work. On the CPU: each drop that lands found its patch by walking every live and settled patch (~160 µs each with 400 settled patches, a large part of a frame after an explosion) - now an indexed lookup (~10-20 µs); the surface under a new patch is traced progressively within 2.5 ms per frame (a flat floor or wall after 81 traces instead of 1089; this tracing used to stall single frames for 50-100 ms after an explosion), faces too narrow to hold blood (brick sides, trims, rails) are skipped at once, drop collision traces use a table filter and a time budget, render targets are made ahead after the map loads instead of in the middle of the first fight, model vertex caches are built when a character appears, texture albedo is measured on the existing readback (no extra GPU sync), and unchanged shader constants are no longer sent again. **Maps**: brush entities of the map (doors, garage gates, lifts, func_wall / func_breakable walls) hold blood like the world while they stand still; smooth sloped surfaces (displacements, ramps) are drawn on a mesh that follows them instead of a lifted grid. **`ghmpb_diag`** prints why there is or is no blood on a map (see Console).

#### Maps without lighting, far landing zones, 2D skyboxes (1.23.2, 1.23.3)
`sv_core.lua`, `sv_history.lua`, `cl_lighting.lua`, `sh_config.lua` (`G.ScenePass`). Found on gm_falleritus8 / gm_falleritus8_2008 (ragdoll-drop maps). **Far blood**: hits more than 9000 u from every player are not simulated live; the server keeps them (single player too) and hands them out when the player comes near, so bodies landing far below the spawn are bloody when you get there. **Unlit maps** (both lighting lumps empty, they render fullbright): the light probes read black there, which turned drops, bursts and lite stains black; a black probe on such a map is now taken as white light (read once per map from the BSP header). **2D skyboxes**: on maps without a 3D skybox the engine may call the opaque draw hooks with the skybox flag set for the whole main view; the blood was simulated but never drawn. Every render hook now skips only the depth pass and the 3D skybox's own view, and if another addon's hook ends the opaque pass early, the blood is drawn late in the translucent pass once (counted in `ghmpb_diag`).

### Multiplayer and other addons

#### Multiplayer (1.15.0)
`sv_core.lua`, `sv_history.lua`, `cl_history.lua`, `sv_mp.lua`. Every client runs its own simulation; the server sends hits, deaths and ragdoll hand-overs **to every player who can see the spot or the body** (their PVS), on listen and dedicated servers alike, and bullet paths to whoever sees the shooter or where the bullet went (for client-side corpses). **Catch-up**: a player who could not see an event - far away, behind walls, or not on the server yet - would find the place clean, so the server keeps a short history of what each event left behind: drips under a wound, the trail a wounded NPC or player leaves while walking on, forward spatter on the wall or floor behind a body that was shot through, blast spatter, a pool under every body that died (moved with the corpse when it is a server ragdoll), and the wounds on bodies that exist on the server (NPCs, players, server and Z-City ragdolls), kept in the bone's frame. A player gets each record once, when he comes within `ghmpb_sv_history_range` (2500 u) of it, nearest first, and never the ones he saw happen; the client paints them as old blood - wet while young, laid down already dried in proportion to their age (`ghmpb_drytime`) - a few per frame. Records are coarse (one stain or pool per event, not every drop) and kept for `ghmpb_sv_history_time` (15 min), at most `ghmpb_sv_history_max` (3000). **Server settings from the window**: a client can not set a server's convars itself (on a dedicated server not even an admin from the console), so the Server tab asks the server, which takes it from superadmins and the listen-server host; everyone else sees the values greyed out.

#### NPC bases: VJ Base, ZBase, DrGBase and others (1.11.0)
`sv_compat.lua`, `sv_core.lua`. **VJ Base**: the blood colour comes from the SNPC's `BloodColor` (Red, Yellow, Green, Orange) and `Bleeds`; while `ghmpb_sv_suppress_default` is on, VJ's own blood particles, decals and corpse pools are switched off for those SNPCs (and back on when it is turned off); colours the simulation does not have (Blue, Purple, White, Oil) keep VJ's own effects. **ZBase**: the engine blood colour ZBase sets in its own init (read again after spawning) or its custom blood decals (red / yellow / green); ZBase's custom particles and decals are switched off the same way, synth / blue blood stays ZBase's. **DrGBase** NextBots: engine blood colour, and their corpses (made without the engine's ragdoll hook) are recognised. **Any other base**: every NPC and NextBot is set up the same way, a few times after spawning, so a base that sets its blood colour late is still read. Hits are handled after the NPC's own damage code has run, so the blood follows the damage it really took (god mode, immunities and damage multipliers of the base are respected) and whether the hit killed it is known instead of guessed (NextBots included); the killing hit always reaches the clients before the death, so the body bleeds out from the fatal wound. Corpses that a base makes itself (`ents.Create("prop_ragdoll")`) are matched to the NPC that just died there by model and position, so its wounds and blood move onto the corpse.

#### Z-City compatibility (1.15.0)
`sh_zcity.lua`, `sv_zcity.lua`, `cl_zcity.lua`. Z-City (and addons built on its `hg` library) had switched PhysBlood off: it sets every player's and NPC's engine blood colour to `DONT_BLEED` when they spawn (PhysBlood read that as "no blood"), its damage hook answers every damage event on a body with an organism, which stops all hooks after it, and it blocks the damage on players (its organism takes it). Now PhysBlood always runs with it (`ghmpb_sv_zcity 1`, the default): the real colour Z-City keeps (`bloodColorHitFix`) is used; PhysBlood's two damage hooks **run before every other addon's** (with ULib, which Z-City needs, as monitor hooks; without it every other addon's damage hook is wrapped so that it runs PhysBlood's first, checked every second - `ghmpb_sv_hook_priority`, also needed with other addons that answer damage events: 1.17.0, the 1.15.0 wrapper around `hook.Call` turned out never to see engine events in game); a hit Z-City's organism took counts, with the damage as it arrived (Z-City scales it to 15 %). A **knocked-down player** becomes a ragdoll: his blood moves onto it and lives on there (a pulse, no corpse clock), goes back onto him when he gets up, and onto his corpse when he dies, after the death has reached the client. **Z-City's own blood is switched off**: its blood particles are not drawn and leave no decals, its hit decals, head-gib and fist blood decals and the engine `BloodImpact` effect it plays are dropped. What they stood for is drawn by PhysBlood: its wounds go on bleeding for as long as Z-City says they bleed (every drop it would have spawned at a wound gathers on the skin as a PhysBlood drop that swells and falls, and the blood runs over the body; arterial wounds spurt; under water it clouds the water), head-shot squirts and coughed-up blood are PhysBlood jets from the same spot on the bone, a head blown off or a limb torn off bleeds from the stump like a GHM FLESH cut, and PhysBlood's own bleeding from a hit stops once Z-City has all of the player's wounds bandaged. Z-City's functions, net messages and hooks are taken over only while both run and given back when the option is switched off; nothing in Z-City is changed on disk, and its other hooks (bandage models, view punches) keep running.

#### GHM FLESH (1.13.0)
`cl_flesh.lua`, `cl_wounds.lua`. GHM FLESH switches its own bleeding off while PhysBlood runs, so before this nothing bled from a limb it cut off. PhysBlood follows FLESH's client hook `GHMFL_ClientSever`: the stump bleeds from the joint the limb came off - pulsing arterial jets from the neck, upper arm and thigh (weaker from forearm and calf, a corpse's only for the seconds after death), heavy venous bleeding, a first gush and a bloody cut; the severed limb (FLESH's second ragdoll of the same body) keeps the blood that was on it (the body's cells are copied onto it), takes over the wounds that were on it and drains from its cut end; it then smears, splashes and, with a hand, leaves hand prints like any corpse. Hands and body parts FLESH has collapsed print and smear nothing. No FLESH file is changed: only its public hook, its skeleton table and the state it keeps on entities are read.

---
## Console commands and settings (every one)

Every setting below is a console variable; the client ones are saved per player, the server ones (`ghmpb_sv_*`) on the server (set them in the server console, `server.cfg`, or from the window as superadmin / host). Defaults are the values after **Reset to defaults** (Medium preset, Realistic style).

### Commands

| Command | What it does |
|---|---|
| `ghmpb_menu` | Open the settings window |
| `ghmpb_splatter_style <minimal\|realistic\|cinematic\|samurai\|horror>` | Apply a splatter style (sets the splatter sliders and the pool size) |
| `ghmpb_clear` | Remove all blood (live and settled) |
| `ghmpb_clear_aftermath` | Remove the settled (aftermath) blood only |
| `ghmpb_rebuild` | Make all the blood's GPU materials again (the blood on screen is cleared). Done by itself when changing video settings in game reloads the material system |
| `ghmpb_diag` | Diagnose: what the blood did since the map loaded (hits received, drops landed, impacts painted or rejected and why — water, too narrow, no surface, waiting for video memory), frames drawn / drawn late, errors, settings and budgets, map lighting, live range, probes and lights, the mirror plane, other addons' render hooks, NPCs and their blood colours (server), a check of the surface under the crosshair, and the frame profile. Run it where blood does not show and send the output |
| `ghmpb_diag_sv` | Server half of the diagnosis (superadmin / host): server switches, hits sent, physics and rate-limit blocks, damage-hook priority and the Z-City takeover, catch-up history records, server counters (events kept for later, ...) |
| `ghmpb_prof` | Where the blood's share of the frame went over the last 2 seconds: CPU ms per part, counts of GPU passes, drops, impacts, and the adaptive quality's pressure |
| `ghmpb_dump` | Print every bleeding body (its materials, cell size, blood, mirrored half), every live world patch (surface kind, wetness, measured albedo of its texture), every settled patch and every body's wounds |
| `ghmpb_test_wound [dmg] [head\|neck\|chest\|abdomen\|thigh\|arm] [fatal]` | Wound the model you look at (client only, no damage) |
| `ghmpb_test_kill` | Fatal bleeding on the model you look at |
| `ghmpb_test_spray [count] [type]` | A droplet spray from your eyes along your aim |
| `ghmpb_test_pour [ml] [type]` | Pour blood onto the surface you look at (type 0 red, 1 yellow, 2 green, 3 zombie) |
| `ghmpb_dust_test [radius] [strength]` | Settle explosion dust where you look (no explosion) |
| `ghmpb_vat_test [kind] [size] [speed]` | Play a fluid burst where you look (kind: back, fwd, heavy, blunt, jet, crown) |
| `ghmpb_vat_info` | State of the VAT bursts (effects loaded, meshes built, playing) |
| `ghmpb_lite_info` | State of the lite renderer (stains, batches, pools, body decals) |
| `ghmpb_uvcheck` | Mirrored-UV check of the model you look at (which parts get twin blood fields) |
| `ghmpb_sv_elements_diag` | Server (superadmin / host): elements on / off, events sent, discharges, players / NPCs shocked, records dried, wet blood records now, temperature (StormFox 2) |
| `ghmpb_sv_history_clear` | Server: forget the catch-up history |

### General and renderer

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_enable` | 1 | 0/1 | Client master switch |
| `ghmpb_render_mode` | 0 | 0 – 2 | Renderer: 0 automatic (the shaders when their files are installed, else lite), 1 shaders, 2 lite (no custom shaders: stains, pools, decals and sprites) |
| `ghmpb_lite_stains` | 3000 | 200 – 20000 | Lite renderer: how many stains stay on the world (the oldest go first) |
| `ghmpb_native` | 1 | 0/1 | Use the C++ droplet solver module if installed |

### Quality, budgets and frame rate

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_quality` | 2 | 1 – 4 | Cell resolution: 1 low, 2 medium, 3 high, 4 ultra |
| `ghmpb_smooth` | 2 | 0 – 2 | Blood edge smoothing: 0 raw cells, 1 bicubic + anti-aliased, 2 + organic edges |
| `ghmpb_sim_hz` | 30 | 10 – 60 | Cell simulation steps per second |
| `ghmpb_max_entities` | 12 | 1 – 32 | Max bleeding models simulated at once |
| `ghmpb_max_patches` | 40 | 4 – 128 | Max live world cells (stains / pools being simulated) |
| `ghmpb_max_particles` | 1400 | 100 – 6000 | Max flying droplets |
| `ghmpb_vram_mb` | 1024 | 256 – 16384 | Video memory the blood may use (MB). Limits are lowered automatically to fit |
| `ghmpb_perf_adaptive` | 1 | 0/1 | Hold the frame rate: far, hidden and settled blood loses detail first when frames get slow |
| `ghmpb_perf_target_fps` | 60 | 20 – 240 | Frame rate the adaptive quality aims for |
| `ghmpb_battle_lod` | 1 | 0/1 | Large battles: the more NPCs fight and bleed around you, the less detail far-away and out-of-view blood gets (near blood keeps it) |

### Look

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_density` | 1 | 0.2 – 4 | Optical density of blood (higher = darker, more opaque) |
| `ghmpb_gloss` | 1 | 0.2 – 3 | Gloss: how sharp the shine of wet blood is (higher = a crisper mirror, lower = a softer sheen) |
| `ghmpb_normal_depth` | 1.6 | 0 – 6 | Strength of the film relief (dynamic normals) |
| `ghmpb_reflections` | 1 | 0 – 3 | Shine: strength of the reflections and highlights on blood (1 = physically correct) |
| `ghmpb_pool_look` | 1 | 0 – 2 | Wetness: how wet fresh blood looks (1 = physical; higher = even thin smears read as liquid, lower = tacky and dull) |
| `ghmpb_froth` | 1 | 0 – 2 | Froth on fresh blood: lung blood, bright spurts and hard impacts bring bubbles that float with the pool and burst over a minute (0 = none) |
| `ghmpb_surface_normals` | 1 | 0/1 | Thin blood and dried stains follow the normal map of the surface they lie on, and its grooves draw the blood along them (deep pools level it out) |
| `ghmpb_uv_mirror` | 1 | 0/1 | Models whose legs / arms share one mirrored texture get separate blood for each side (1), or share it (0: the blood shows on both) |
| `ghmpb_material_look` | 1 | 0/1 | Blood looks different on each surface (soaked-in stains, halos on porous ground, grain on sand / gravel / grass / carpet, snow and ice sparkle) |

### Reflections and lights

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_reflect_mirror` | 1 | 0/1 | Mirror reflections in blood on the floor: what stands round a pool (bodies, props, walls, lamps) is mirrored in it sharply, like water reflections (an extra render of the scene; 0 = off) |
| `ghmpb_reflect_probes` | 2 | 0 – 6 | Reflection probes: how many groups of blood get a live reflection of what stands round them (rendered views, refreshed while you play; 0 = the map's cubemap only) |
| `ghmpb_reflect_budget` | 20 | 2 – 200 | Reflection probes: milliseconds a second they may spend rendering their views (higher = they keep up faster with what moves) |
| `ghmpb_map_lights` | 1 | 0/1 | Highlights on wet blood from the lamps of the map, dynamic lights, projected textures and other players' flashlights |

### Blood colour

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_color_fresh` | 1 | 0.3 – 3 | Brightness of fresh (wet) blood: higher = lighter, redder; lower = darker |
| `ghmpb_color_dry` | 1 | 0.3 – 3 | Brightness of dried / old blood: higher = lighter rust-brown; lower = darker, blacker |
| `ghmpb_color_hue` | 0 | -1 – 1 | Blood hue: + towards orange-scarlet, - towards deep crimson / purple |

### Simulation: flow, clotting, drying

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_thickness` | 1.6 | 0.5 – 4 | How thick blood stays before it spreads (surface pinning) |
| `ghmpb_viscosity` | 1 | 0.3 – 4 | Blood viscosity multiplier (higher = slower runs) |
| `ghmpb_motion` | 1 | 0/1 | How much body motion pushes blood around (0..1) |
| `ghmpb_floor_unevenness` | 1 | 0 – 3 | Micro unevenness of floors and walls that steers pools and runs (0 = perfectly flat) |
| `ghmpb_coagulation` | 1 | 0/1 | Blood coagulates (clots, stops flowing, darkens) |
| `ghmpb_coag_time` | 180 | 15 – 900 | Seconds until spilled blood is mostly clotted |
| `ghmpb_drytime` | 240 | 20 – 3600 | Seconds for thin wet blood to dry into stain (thick pools take longer) |

### Runs on walls

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_wall_runs` | 1 | 0 – 4 | Runs on walls: how readily wet blood on walls and steep slopes runs down in rivulets (0 = off, higher = more runs) |
| `ghmpb_run_speed` | 1 | 0.25 – 3 | Speed of runs on walls (multiplier) |

### Blood in water

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_water` | 1 | 0/1 | Blood in water: drops, wounds, runs and pools reaching water make clouds that spread and fade |
| `ghmpb_water_amount` | 1 | 0.2 – 4 | How strongly blood clouds in water show (multiplier) |
| `ghmpb_water_time` | 90 | 10 – 600 | Longest time a blood cloud in water lasts (seconds) |
| `ghmpb_water_wash` | 1 | 0 – 3 | How fast blood on bodies and surfaces under water washes off into the water (0 = it stays) |

### Pools and blood supply

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_pools` | 1 | 0/1 | Allow blood pools / world stains |
| `ghmpb_pool_size` | 1 | 0 – 5 | How much blood a dying body loses into its pool (multiplier) |
| `ghmpb_blood_volume` | 4000 | 500 – 20000 | Blood a human body can lose in total (ml); other creatures scale with their size |
| `ghmpb_corpse_bleed_time` | 180 | 10 – 3600 | Seconds after death a body can still bleed (fully for the first 30 s, then less and less) |

### Splatter

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_splatter_style` | realistic | minimal / realistic / cinematic / samurai / horror | The splatter style: setting it applies the style (the splatter sliders and the pool size); moving a slider by hand makes it "custom" |
| `ghmpb_spray` | 1 | 0 – 4 | Droplet spray amount multiplier (all sprays) |
| `ghmpb_splat_entry` | 1 | 0 – 6 | Entry wound back-spatter (multiplier) |
| `ghmpb_splat_exit` | 1 | 0 – 6 | Exit wound spray (multiplier) |
| `ghmpb_splat_melee` | 1 | 0 – 6 | Blade / blunt melee spray, flung along the swing (multiplier) |
| `ghmpb_splat_kill` | 0 | 0 – 6 | Extra burst on the killing blow (multiplier) |
| `ghmpb_splat_blast` | 1 | 0 – 6 | Explosions: the directional burst of blood thrown away from the blast (multiplier) |
| `ghmpb_splat_wound` | 1 | 0 – 5 | Blood painted on the body around each wound (multiplier) |
| `ghmpb_splat_size` | 1 | 0.3 – 3 | Droplet size (multiplier) |
| `ghmpb_splat_speed` | 1 | 0.25 – 3 | Droplet speed / throw distance (multiplier) |
| `ghmpb_splat_spread` | 1 | 0.3 – 3 | Spray cone width (multiplier) |
| `ghmpb_arterial_strength` | 1 | 0 – 6 | Arterial jet flow and height (multiplier) |
| `ghmpb_geyser` | 0 | 0/1 | Samurai-film blood fountain from fatal neck / head / torso wounds |
| `ghmpb_mist` | 1 | 0/1 | Blood mist puffs on impacts |
| `ghmpb_castoff` | 1 | 0/1 | Blood flung off bloody weapons on the back swing (cast-off lines on ceilings / walls) |

### Droplets

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_drop_bounce` | 1 | 0/1 | Drops that hit at a grazing angle skip on (ricochet streaks) and fast splashes throw secondary droplets |
| `ghmpb_drop_slide` | 1 | 0 – 2 | Fast drops: part of a fast, flat drop skids on as a droplet that ends in a bead (0 = off, 1 = short skids, 2 = long thin rivulets - the 1.19 look) |
| `ghmpb_streak_max` | 3.5 | 1.5 – 10 | Longest a drop stain gets (length / width): flat, fast hits leave longer stains up to this (10 = no limit, the old long streaks) |
| `ghmpb_drop_trail` | 1 | 0 – 2 | Length of the motion trail of flying drops (0 = none, 1 = camera shutter) |
| `ghmpb_drop_hang` | 1 | 0/1 | Blood gathers into hanging drops that swell and drip (chins, noses, ledges, ceilings) |

### Fluid bursts (VAT)

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_vat` | 1 | 0/1 | Fluid-simulated blood bursts (VAT mesh particles) at wounds, jets and big drops |
| `ghmpb_vat_size` | 1 | 0.25 – 3 | Size of the VAT blood bursts |
| `ghmpb_vat_max` | 10 | 1 – 40 | VAT blood bursts on screen at once |
| `ghmpb_vat_bright` | 1 | 0.1 – 4 | Brightness of the VAT blood bursts |
| `ghmpb_vat_red_bright` | 1 | 0.1 – 4 | Brightness of red VAT blood bursts |
| `ghmpb_vat_red_hue` | 0 | -1 – 1 | Hue of red VAT blood bursts (−1…1 = −40…+40°) |
| `ghmpb_vat_yellow_bright` | 1 | 0.1 – 4 | Brightness of yellow VAT blood bursts |
| `ghmpb_vat_yellow_hue` | 0 | -1 – 1 | Hue of yellow VAT blood bursts (−1…1 = −40…+40°) |
| `ghmpb_vat_green_bright` | 1 | 0.1 – 4 | Brightness of green VAT blood bursts |
| `ghmpb_vat_green_hue` | 0 | -1 – 1 | Hue of green VAT blood bursts (−1…1 = −40…+40°) |
| `ghmpb_vat_zombie_bright` | 1 | 0.1 – 4 | Brightness of zombie VAT blood bursts |
| `ghmpb_vat_zombie_hue` | 0 | -1 – 1 | Hue of zombie VAT blood bursts (−1…1 = −40…+40°) |

### Bleeding

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_bleed` | 1 | 0 – 5 | Client bleeding amount multiplier |
| `ghmpb_face_bleed` | 1 | 0/1 | Nose / mouth / ear bleeding from head, neck and chest trauma |
| `ghmpb_arterial` | 1 | 0/1 | Arterial spurting from hit arteries |
| `ghmpb_cough` | 1 | 0/1 | Coughing blood after chest / neck wounds |
| `ghmpb_remove_engine_decals` | 1 | 0/1 | Remove the engine's blood decals (bullet splats) from bodies the mod bleeds, while the server replaces the engine's blood |

### Smears, prints, props, tyres, splashes

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_smear` | 1 | 0/1 | Bloody bodies leave smears where they slide or are dragged, and push / wipe pools |
| `ghmpb_smear_amount` | 1 | 0 – 3 | How much blood a sliding body leaves behind (multiplier) |
| `ghmpb_smear_pickup` | 1 | 0/1 | Bodies moving through pools pick up blood (and carry it on) |
| `ghmpb_footprints` | 1 | 0/1 | Characters walking through wet blood leave bloody footprints |
| `ghmpb_footprint_amount` | 1 | 0 – 3 | How much blood each footprint leaves (multiplier) |
| `ghmpb_footprint_npcs` | 1 | 0/1 | NPCs leave footprints too (not only players) |
| `ghmpb_hand_prints` | 1 | 0/1 | Bloody hands leave hand prints on floors and walls, and finger streaks where they are dragged |
| `ghmpb_hand_amount` | 1 | 0 – 3 | How much blood each hand print / finger streak leaves (multiplier) |
| `ghmpb_props` | 1 | 0/1 | Props touch blood: they soak up or get bloody in pools, smear when dragged and splash when dropped in |
| `ghmpb_props_amount` | 1 | 0 – 3 | How much blood props pick up and smear (multiplier) |
| `ghmpb_tyre_tracks` | 1 | 0/1 | Vehicles leave tyre tracks and skid marks after driving through blood |
| `ghmpb_tyre_amount` | 1 | 0 – 3 | How much blood tyres pick up and print (multiplier) |
| `ghmpb_splash` | 1 | 0 – 3 | Splashes when bodies, props or tyres hit pools (multiplier, 0 = none) |

### GHM FLESH

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_flesh` | 1 | 0/1 | GHM FLESH: limbs it cuts off bleed from the stump and keep their blood |
| `ghmpb_flesh_bleed` | 1 | 0 – 3 | GHM FLESH: how much a stump bleeds (multiplier) |

### Collisions

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_physics_blood` | 1 | 0 – 3 | Blood from physics impacts: thrown, dropped or colliding bodies (multiplier, 0 = none) |
| `ghmpb_physics_cooldown` | 1 | 0.1 – 10 | Seconds between physics-impact bleeds on the same body |

### Elements, dust and flies

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_elements` | 1 | 0/1 | Blood reacts to fire (boils, dries, chars), cold (freezes, steams), electricity (arcs), lasers, acid, energy balls and blasts |
| `ghmpb_freeze` | 1 | 0/1 | Blood freezes on ice and snow, and outdoors in sub-zero weather (StormFox 2) |
| `ghmpb_elem_steam` | 1 | 0/1 | Steam from fresh blood in the cold and from boiling blood; smoke from charring |
| `ghmpb_blast_dust` | 1 | 0/1 | Explosions kick up dust from the ground (sand, snow, soil, concrete, plaster...) that sticks to fresh blood |
| `ghmpb_flies` | 1 | 0/1 | Flies come to pools of blood and to the dead (outdoors and in the warm; none in the cold) |
| `ghmpb_flies_amount` | 1 | 0 – 3 | How many flies come (multiplier) |
| `ghmpb_flies_max` | 80 | 0 – 400 | Most flies simulated at once |
| `ghmpb_flies_sound` | 1 | 0/1 | The buzz of flies near you |

### Aftermath (settled blood)

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_aftermath` | 1 | 0/1 | Keep settled blood in a cheap static aftermath layer |
| `ghmpb_keep_forever` | 0 | 0/1 | Aftermath never fades (only map cleanup / the cap removes it) |
| `ghmpb_aftermath_fade` | 20 | 1 – 600 | Minutes before aftermath blood fades out (if not kept forever) |
| `ghmpb_aftermath_max` | 400 | 16 – 4096 | Max aftermath world patches (76 x 76 cm each) |
| `ghmpb_aftermath_bodies` | 48 | 4 – 256 | Max bodies keeping baked blood |
| `ghmpb_aftermath_res` | 256 | 128 – 512 | Aftermath world patch resolution (128 / 256 / 512) |
| `ghmpb_settle_time` | 25 | 5 – 600 | Seconds of no new blood before a world patch settles into the aftermath layer |

### Debug views

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_debug` | 0 | 0 – 3 | Debug overlay (1 = stats, 2 = cell viewer, 3 = thickness colours) |
| `ghmpb_debug_view` | 0 | 0 – 4 | Shading debug view: 0 off, 1 thickness, 2 without reflections / highlights, 3 reflections / highlights only, 4 layer reflectance |
| `ghmpb_debug_hits` | 0 | 0/1 | Show where hits on bodies land (red: server point, green: wound) |

### Server: general

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_sv_enable` | 1 | 0/1 | Master switch (server) |
| `ghmpb_sv_suppress_default` | 1 | 0/1 | Disable the engine's own blood particles/decals on NPCs so only simulated blood is used |
| `ghmpb_sv_bleed_scale` | 1 | 0 – 5 | Bleeding amount multiplier |
| `ghmpb_sv_players` | 1 | 0/1 | Players bleed too |

### Server: collision spam protection

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_sv_physics_min` | 20 | 0 – 1000 | Minimum physics / crush damage that makes a body bleed (corpses need twice as much) |
| `ghmpb_sv_physics_cooldown` | 1 | 0 – 30 | Seconds between physics-impact bleeds on the same body |
| `ghmpb_sv_physics_rate` | 15 | 1 – 200 | Max physics-impact bleeds per second on the whole server |
| `ghmpb_sv_hit_rate` | 120 | 10 – 1000 | Max blood hit messages per second on the whole server (all damage) |

### Server: elements

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_sv_elements` | 1 | 0/1 | Blood reacts to fire, cold, electricity, lasers, acid, energy balls and blasts (the server sends them, wet blood conducts) |
| `ghmpb_sv_elec_damage` | 12 | 0 – 200 | Shock damage to an NPC or player standing in wet blood that electricity runs through (0 = arcs only) |
| `ghmpb_sv_elec_range` | 700 | 50 – 4000 | How far (units) electricity runs through connected wet blood |
| `ghmpb_sv_wet_time` | 240 | 10 – 3600 | Seconds a pool of blood stays wet (conducts) on the server; small stains and spatter less, big pools more |

### Server: multiplayer catch-up

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_sv_history` | 1 | 0/1 | Players who arrive later (or join) see the blood that was left before |
| `ghmpb_sv_history_time` | 900 | 30 – 7200 | Seconds the server remembers blood for players who arrive later |
| `ghmpb_sv_history_range` | 2500 | 500 – 20000 | Distance (units) at which a player gets the blood left before he arrived |
| `ghmpb_sv_history_max` | 3000 | 100 – 20000 | Most blood records the server keeps for players who arrive later |

### Server: downloads and compatibility

| Setting | Default | Range | What it does |
|---|---|---|---|
| `ghmpb_sv_workshop_id` | (empty) | — | Workshop item that joining players download the addon's content from (empty = found by itself) |
| `ghmpb_sv_fastdl` | 1 | 0/1 | Without a Workshop item, send the addon's shaders, materials and models through the server's own downloads |
| `ghmpb_sv_zcity` | 1 | 0/1 | With Z-City (Homigrad) loaded, PhysBlood draws all of the blood and Z-City's own blood effects are switched off |
| `ghmpb_sv_hook_priority` | 1 | 0/1 | Run the blood's damage hooks before other addons' (so an addon that answers damage events cannot hide hits from it) |

---
## Compatibility with other addons

| Addon | What happens |
|---|---|
| **VJ Base** | Blood colour from the SNPC's `BloodColor` (Red, Yellow, Green, Orange) and `Bleeds`; VJ's own blood particles, decals and corpse pools are switched off for those SNPCs while `ghmpb_sv_suppress_default` is on (and back on when it is off). Blue, Purple, White and Oil keep VJ's effects. |
| **ZBase** | The engine blood colour ZBase sets, or its red / yellow / green custom decals; ZBase's own particles and decals are switched off the same way; synth / blue blood stays ZBase's. |
| **DrGBase** and any other NPC / NextBot base | Engine blood colour, read a few times after spawning (late setters work); hits handled after the NPC's own damage code, so god mode, immunities and multipliers are respected; corpses the base makes itself are matched to the NPC that died there. |
| **Z-City / Homigrad** (and addons on its `hg` library) | PhysBlood draws all of the blood and Z-City's own blood effects are off (`ghmpb_sv_zcity`); its bleeding wounds, head-shot squirts, coughs, torn-off limbs and knocked-down ragdolls are drawn by PhysBlood; bandaging stops the bleeding. Works with ULib (monitor hooks) and without it (hook wrapping, `ghmpb_sv_hook_priority`). Tested in simulation only. |
| **GHM FLESH** | Stumps of limbs it cuts off bleed (arterial jets from neck, upper arm, thigh), severed limbs keep their blood and drain from the cut end, smear and print. FLESH's wound layer is drawn inside PhysBlood's body pass; its own flies (`ghm_flesh_flies`) are separate from PhysBlood's. No FLESH file is changed. |
| **GHM Euphoria** | A knocked-down (still alive) ragdoll draws no flies; Euphoria's 1-point damage-over-time ticks open no wounds; a tick that kills counts as what hurt the body before. |
| **GHM PhysFX** | Its simulated dust and smoke are used as the explosion's cloud; PhysBlood's dust still settles into the blood. |
| **StormFox 2** | Sub-zero weather freezes blood outdoors; cold, rain and night mean fewer or no flies. |
| **vFire** | Burning entities boil and char the blood under and on them. |
| **Vehicles**: HL2 jeep / buggy / jalopy, **simfphys**, **LVS**, **Glide**, any entity whose class names it a wheel | Tyre tracks and skid marks; slip from the base where it reports one. |
| **GHM Ballistic Damage, GHM Matter** | No integration; a note about the 2D-skybox draw flag (1.23.3) was left for them. |
| Other blood-replacement addons | Do not combine: both would draw blood. |

**For addon authors.** Client: `GHMPB.Elem.Add(GHMPB.EL.COLD, pos, radius, strength, seconds)` (e.g. a freeze gun; kinds in `GHMPB.EL`: HEAT, COLD, ELEC, LASER, ACID, DISSOLVE, WAVE, RAD, PLASMA, HOT, DUST). Server: `GHMPB.Elem.Send(...)`, `GHMPB.Elem.Discharge(pos, strength, attacker)`. Drawing your own layer on bodies once a frame: wrap `GHMPB.Entities.DrawStatic` / `DrawOverlays` (the water views call `RawDrawStatic` / `RawDrawOverlays`). PhysBlood listens to GHM FLESH's `GHMFL_ClientSever` hook.

---

## Performance and tuning

- **Frame rate.** Leave `ghmpb_perf_adaptive` on and set `ghmpb_perf_target_fps` to the frame rate you want (60 by default; at or below your monitor's refresh rate). Under pressure, far, hidden and settled blood loses detail first; blood near the camera keeps it. `ghmpb_prof` shows where the frame goes. In a very big fight (30 bleeding NPCs, 12–18 hits a second, gm_construct) the blood's share of the frame went from ~80 ms to ~40 ms in 1.17.0. With GHM FLESH, much of what is left in a big dismemberment scene is FLESH's own drawing (it shows in PhysBlood's `draw:bodies old` line).
- **Reflections cost.** The floor mirror (1.25.1) renders the scene once more per frame (every other frame under heavy pressure): turn it off with `ghmpb_reflect_mirror 0` on a weak GPU or a heavy map. Probes spend at most `ghmpb_reflect_budget` ms a second (20); `ghmpb_reflect_probes 0` keeps only the map's cubemap. `ghmpb_diag` reports the ms a probe face and a mirror frame cost.
- **Weak PCs.** Quality preset Low, `ghmpb_quality 1`; or the lite renderer (`ghmpb_render_mode 2`).
- **Video memory at full use**: Low ≈ 120 MB, Medium ≈ 600 MB, High ≈ 1 GB, Ultra ≈ 1.4 GB. The default budget is 1 GB; on 6–8 GB cards set `ghmpb_vram_mb 2048` for Ultra. Memory used by a resolution you switched away from is only released when the game restarts. `ghmpb_quality 3` uses 512² cells on bodies and 320² on world patches, `4` uses 640² / 512².
- **A permanent mess**: Aftermath → *Keep the mess forever*, and raise *Max aftermath world patches*. Each 76 × 76 cm patch costs 256–400 KB of video memory (1 MB on Ultra). Drawing settled blood costs about 5–15 µs of CPU per patch on screen, so hundreds of patches are fine.
- **Density**: `ghmpb_density` 1 is the measured optical density of whole blood. 1.3–1.8 for darker, more opaque blood; lower for thinner, redder blood; above ~2 even thin splatter is nearly black-red.
- **Shine**: `ghmpb_reflections` 1 is physically correct (2–3 % at normal incidence rising to a mirror at grazing angles). Lower it if a map's cubemap is much brighter than its lighting.
- **Blood too bright or dark on one floor**: blood is lit from the frame divided by the surface's average colour, measured once per texture; `ghmpb_dump` lists the measured albedo per patch.
- **Settling**: blood settles into the aftermath layer after `ghmpb_settle_time` seconds without new blood, and with coagulation on not before it is about half clotted (half of `ghmpb_coag_time`). Bodies lying still stop re-rendering their force field and step less often; world patches step at half rate after 12 s without new blood, a third after 30 s.
- **Runs**: `ghmpb_wall_runs 2` lets drops from ~3.5 mm and light spatter clusters run; 0.5 keeps runs to heavy bleeding. `ghmpb_run_speed` only changes how fast they go.
- **Water clouds**: `ghmpb_water_amount` makes them stronger or fainter, `ghmpb_water_time` caps how long one lasts.
- **Surface kinds**: from the surface property of the texture. On the test map the brick pavement is `brick` (porous: it drinks thin blood, pools stay smaller), the cobbles `stone`, concrete and mortar `concrete`. `ghmpb_debug 2` and `ghmpb_dump` show the kind of each patch.
- **C++ solver**: 400 drops in flight cost about 1 ms of CPU a frame on the test machine.

---

## Known limits

**Layers and flow**
- New blood landing on settled (aftermath) blood is simulated as a separate live layer on top until it settles too; until then its edge can show as a rim or a different shade over the older stain (fix in progress, see below).
- Blood crossing between two world planes is handed over at the edge (over a ledge onto the face below, from a wall onto the floor at its foot), not through ghost cells; blood never climbs from a floor onto a wall.
- The bed map sees the world and frozen / resting props (radius 20 u or more). Moving props, ragdolls and NPCs are not part of it: blood flows under them.
- Separate materials of a model (face and clothes) are separate cell fields: blood passes between them as drips only.
- A run paints its trail into world patches: a long run down a tall wall makes patches along its way (they settle ~25 s later). Runs do not turn round outside corners; they stop there as a bead. On bodies the cell simulation carries the runs.
- Faces narrower than about 1.25 u (brick sides, trims, rails, the edge of a step) get no patch of their own; a drop landing there is lost.
- Impact momentum crosses patch borders only with its component across the border.
- A world patch takes one surface kind (from where its first blood landed), so a pool running from snow onto a concrete path keeps the snow look on the patch it started in. Creature footprints follow a fixed gait per kind; feet probe the blood at their own spot, so a very narrow trickle can be stepped over.

**Blood types and colour**
- A region of a world plane (about 3 × 3 m) or a body mixes two blood types; a third type there takes the second slot while there is hardly any of it yet, otherwise it is drawn in the second type's colour. Fresh blood mixes with live cells only; settled stains underneath keep their colour until the new blood settles.
- Four simulated colours (red, yellow, green, zombie). NPCs from bases with other colours (VJ Blue / Purple / White / Oil, ZBase blue or synth) keep their base's own blood effects.

**Look**
- The floor mirror covers one floor height at a time (the most important wet floor in front of you); pools at other heights (stairs, tables, slopes) and walls use the probes and screen-space reflection. Probes: 2 groups by default; other blood reads a fallback probe around the camera. Maps with a bad or missing cubemap give flat reflections until a probe is drawn.
- Blood is not drawn in water reflections. Blood landing in water (or on a water / slime surface) becomes a cloud: on maps whose floors are covered by a thin water brush the floor under it gets no stains (`ghmpb_diag` counts "impact under water"). With cheap water (low water detail) there is no refraction view: clouds and blood under the surface are only seen from under water. Water surfaces are taken as flat.
- The light of a world patch is measured once per patch (about 76 cm), so a mirror-smooth fresh pool across two patches can show highlights a little brighter on one side of the border.
- The normal map of world surfaces needs the map's lumps uncompressed; on maps with compressed lumps blood does not follow the normal map.
- Test map: on the flat brick pavement the mortar at the bottom of the joints renders black (vbsp removed those faces under the detail bricks); the collision is right, so the blood behaves correctly.
- Changing some video settings in game (`mat_specular`, shader detail, anti-aliasing, HDR) reloads the material system; PhysBlood rebuilds its materials within about half a second and the blood on screen at that moment is cleared.
- Lite renderer: no flow, relief, froth, live drying, body smears or dust (see *Lite renderer*).

**Hits and bodies**
- Client-side corpses (the default NPC ragdolls) are hit with a hitbox test because engine traces do not see them; they exist only for players who saw the death.
- Weapons that do not report where they hit (many melee / scripted weapons, direct `TakeDamage` calls) are located from the attacker's aim or a trace towards the body; only when both miss does the wound fall back to the middle of the body.
- Mirrored-UV twins need room in the video memory budget; without it the two halves share blood as before 1.20.1.
- `ghmpb_sv_suppress_default 1` sets NPC and player blood colour to `DONT_BLEED` (the real colour is kept in a networked variable and restored when off). The engine's blood splat on bodies comes with the bullet's impact effect, so each client removes the decals from every body the mod bleeds (`ghmpb_remove_engine_decals`) — that removes other addons' decals on those bodies too. Players keep the engine's blood while `ghmpb_sv_players` is off.

**Multiplayer**
- Each client runs its own simulation. Two players see the same wounds and the same kind of spray, not drop for drop the same stains. Players who arrive later get a coarse record (one stain, spatter or pool per event; the wounds on server-side bodies). Events beyond 9000 u of every player are kept and painted later as such records.
- Multiplayer, Z-City and the NPC-base flows were written against the current source of those projects and tested in a simulation (`tests/mp_mock/`); in game they were tested with engine NPCs in single player. With Z-City, `util.Decal` calls whose decal name contains "blood" and the engine `BloodImpact` effect are dropped for every addon while the takeover is on.
- Elements: electricity follows the server's coarse map of blood, so a discharge can reach a little past what is drawn or stop short of a thin smear. Fire, lasers and acid act on live blood; settled blood only chars and freezes. Fire detection covers the engine's fires and vFire; other fire addons work through their burn damage. Sub-zero weather needs StormFox 2.

---

## In progress and planned

Asked for and being worked on (in this order, after this README):

1. **Seamless layers and soaking** — fresh blood landing on a settled stain takes the stain back into the live simulation so there is one layer and no rim; pools fade in smoothly as they form and soak into the surface over time, faster on porous ground (concrete, wood, carpet, soil) than on sealed floors.
2. **TLOU2-style pools** — thin, straight capillary lines running out from the body and the pool along grout, tile joints and cracks where the surface allows it, and pools that branch into fingers; more simulation in wall splatter, with heavy spatter on walls running down as physical crime-scene drip runs.
3. **Melee trails** — blood trailing and flung off any melee weapon along its direction of motion during the swing (not only on the back swing after a hit), strongest for sharp weapons (knives, swords).
4. **Arterial trails while moving** — an NPC or player with an arterial bleed leaves spurt patterns along the path it moves.
5. Check 1.25.1 in game (mirror, rim glints, skids), then package 1.25.1.
6. Still to check in game: multiplayer with a joining client, the lite renderer, the VAT bursts.

---

## Version history

| Version | Highlights |
|---|---|
| 1.0 | First version: HLSL cell simulation, stamping, pools and the lit blood surface; the C++ droplet module; Lua wounds, bones, particles, stains, pools and settings. |
| 1.1 – 1.4 | Video memory budget with hard caps; splatter controls and style presets; TLOU2-style pool formation; collision blood-spam limiter; smearing (drag trails, wipes, pickup); a look pass on colours and wetness from in-game captures (1.4.0). |
| 1.5 | Bloody footprints; trail fluid dynamics on walls; better blood on bodies; performance; better aftermath persistence. |
| 1.6.0 | Forensic bloodstain physics (gunshot back / forward spatter, mist, blunt force, cast-off, arterial, expirated, drips; Hulse-Smith stains); PBR shading pass (linear colour pipeline, Kubelka-Munk in four bands). |
| 1.7.0 | Droplets drawn as velocity-stretched spheres with motion trails; ricochets and secondary droplets; stain anatomy (teardrop, tail, wave cast-off, skid streak). |
| 1.8.0 | Pools on real geometry (traced bed maps: joints, cracks, walls as dams, edges, stairs); brick test map and props; hanging drops; screen-space reflections; runs on bodies follow creases. |
| 1.9.0 | Blood types (incl. zombie) mixing per pixel; what bleeds by class, model and material; 4-litre blood supply; surface materials with their own soaking and flow. |
| 1.10.0 | Pools level out; arterial / venous oxygenation; blood colour settings; wounds on the hit bone; C++ module v4. |
| 1.11.0 / 1.11.1 | Directional explosion bursts; VJ Base / ZBase / DrGBase support. Fixes: double stains on relief walls; big speed-ups; brush entities and displacements hold blood; `ghmpb_diag`. |
| 1.12.0 | Runs on walls; blood in water (clouds, wash-off); blood stays liquid longer; engine blood decals removed from bodies. |
| 1.13.0 | Hand prints; props in blood; tyre tracks and skid marks; splashes; GHM FLESH stumps. |
| 1.14.0 / 1.14.1 | Performance with a lot of blood (readback, hit tests), adaptive quality, frame profiler; bloodless damage types; blood colours match everywhere (footprints, tracks, regions of 3 × 3 m). |
| 1.15.0 | Multiplayer (PVS recipients, catch-up history, dedicated servers, Workshop downloads); Z-City compatibility. |
| 1.16.0 | Large battles and far drops; per-surface looks (snow, sand, concrete, …) and absorption; creature tracks. |
| 1.17.0 | Elements (fire, cold, electricity, lasers, acid, energy balls, blasts, radiation); big-fight performance; C++ module v5; rebuild after video setting changes. |
| 1.18.0 / 1.18.1 | Explosion dust in the blood; the fresh-blood look (meniscus, bubbles, flow streaks, clot lumps); flies. Fixes: drag smears, props in blood, blood type colours. |
| 1.19.0 | Pools read as liquid, round off and join; slope fingers; froth; fast drops slide on; wetter-looking bleeding on bodies. |
| 1.20.0 / 1.20.1 | Physically based blood (luminance irradiance, spectral fit, dried-blood ageing); mirrored UVs bleed separately. |
| 1.21.0 – 1.21.2 | Blood follows the surface's normal map; fix for no blood on the world; wounds land where the bullet hit (back of the head). |
| 1.22.0 | Lite renderer without custom shaders; Workshop package. |
| 1.23.0 – 1.23.3 | Fluid-simulated VAT blood bursts and their colours per type; far landing zones, unlit maps and corpse smash bursts (gm_falleritus8); blood drawn on maps with a 2D skybox only. |
| 1.24.0 | No long lines: stain length limit, short skids, straighter runs, smears of fast parts fade; the fall-smash burst. |
| 1.25.0 | Reflection probes, the map's lights, opaque thick blood, smoother edges, dried colour variation, less froth. |
| 1.25.1 | Mirror reflections in floor pools, rim glints from the flashlight and lights, skids only from flat fast sizeable hits; probe atlas 1024². In development. |

`NOTES.md` has the engineering notes of every version (measurements, register budgets, what was verified in game).

---

## How it works inside (for developers)

**One hit, start to finish.**
1. *Server* (`sv_core.lua`, `sv_compat.lua`, `sv_zcity.lua`): damage hooks (run before other addons') turn a hit or a death into a compact net message — position, normal, bone, hit group, damage type and amount, direction, attacker, blood type, killed — sent to every player who can see the spot (PVS) within the live range; the rest goes into the catch-up history (`sv_history.lua`).
2. *Wounds* (`cl_wounds.lua`, `sh_anatomy.lua`): the hit becomes a wound on the bone's skin with sources (weeping, venous, arterial), face outlets and coughing, all drawing on the body's blood budget.
3. *Spray* (`cl_forensic.lua`): the kind of hit picks the forensic spray (back / forward spatter, mist, blunt, cast-off, blast, arterial jet) with its sizes, speeds and cones; `cl_vat.lua` adds a fluid burst.
4. *Drops* (`cl_particles.lua` / `native/ghm_physblood.cpp`): flight with drag, break-up, coalescence; landing on a body or the world, ricochets, crowns, skids, hanging drops, water.
5. *Stamping* (`stamp_ps30`): the landing is painted into the cell field of what it hit — a body material's UV space (`cl_entities.lua`) or a world patch (`cl_surfaces.lua`, 76 × 76 cm, traced bed map).
6. *Simulation* (each frame, on the GPU): `force_ps30` (bodies: gravity and body motion per texel, skin curvature) or `pforce_ps30` (world: bed height, normals, curvature, pinning noise, slope lanes, normal-map grooves) → `sim_ps30` / `simbody_ps30` (`ghmpb_sim_main.h`: thin-film flow, contact lines, levelling, absorption, clotting, drying, blood type and oxygen transport, froth) → `reduce_ps30` read back a frame later for drips, run-off into the next patch and pool depth probes.
7. *Drawing* (`cl_render.lua`): the film shaders (`surface_ps30` on the world, `bodyfilm_ps30` on bodies, `ghmpb_shade.h`) composite the blood over the lit frame with Kubelka-Munk optics, the probe / mirror reflections (`cl_probes.lua`) and the lights (`cl_lighting.lua`, `cl_maplights.lua`); drops with `drop_ps30`.
8. *Settling*: a patch or body that has stopped moving is baked (`bake_ps30`) into an RGBA8 aftermath texture and drawn with `surfstatic_ps30` / `bodystatic_ps30` on a static mesh, freeing its simulation slot.

**Cell state** (world patches): state (h wet height, s stain, mx, my momentum), force (bed height, curvature, pinning noise, lift), accumulators (lift, edge-out, oxygenated volume) and aux (clotted volume, wet neighbours, column weight on walls / froth on floors, second-type volume). Aftermath: RGBA8 (√(h/4), √(s/4), second type, mask). Neighbouring patches of a plane exchange border cells (ghost cells) so flow crosses borders without seams.

**Shaders** (28 `.vcs`, Shader Model 3, loaded through GMod's `screenspace_general` — custom HLSL needs no DLL and survives game updates): `stamp`, `force`, `pforce`, `sim`, `simbody`, `reduce`, `bake`, `surface`, `surfstatic`, `bodyfilm`, `bodystatic`, `drop` (vs + ps), `elem` (elements), `dustworld`, `dustbody`, `dustaft`, `probeblur`, `probeenv`, `copy`, `blit`, `peek` (debug readback) and the vertex shaders `clip`, `model`, `modeldust`, `unwrap`, `world`, `worlddust`. The film shaders sit at the edge of ps_3_0 (32 temporary registers, ~4000 instruction slots): the world ones are compiled at optimisation level 1 (level 3 schedules them past the register limit); `tools/slots/` reports slots and registers per shader.

**Lua modules** (`lua/ghm_physblood/`):

| File | Job |
|---|---|
| `sh_config.lua` | Console settings, constants, surface kinds and their looks, blood types, damage classification |
| `sh_anatomy.lua` | Bone names of any skeleton → body regions |
| `sh_shaderver.lua` | The compiled shader set prefix |
| `sh_zcity.lua`, `sv_zcity.lua`, `cl_zcity.lua` | Z-City / Homigrad takeover and damage-hook priority |
| `sv_core.lua` | Server: hits, deaths, ragdoll hand-overs, bullet paths, rate limits |
| `sv_compat.lua` | NPC bases (VJ, ZBase, DrGBase, generic) |
| `sv_history.lua`, `cl_history.lua` | Catch-up history for players who arrive later or far away |
| `sv_mp.lua` | Content downloads for joining players |
| `sv_elements.lua`, `cl_elements.lua` | Fire, cold, electricity, lasers, acid, energy balls, blasts, radiation |
| `cl_render.lua` | Frame orchestration: net messages, update order, draw hooks, clear / rebuild |
| `cl_gpu.lua` | Render target pools, material factory, quad helpers |
| `cl_budget.lua` | Video memory budget |
| `cl_wounds.lua` | Wounds, bleeding, blood supply, styles, corpse impacts |
| `cl_forensic.lua` | Forensic spray models |
| `cl_particles.lua`, `cl_native.lua` | Droplet solver (Lua) and the bridge to the C++ module |
| `cl_entities.lua` | Blood on models (domains, materials, mirrored UVs, hit snapping) |
| `cl_surfaces.lua` | Blood on the world (patches, bed maps, aftermath) |
| `cl_bsptex.lua` | Reads the map's face texture mapping (normal maps) |
| `cl_runs.lua` | Runs on walls and skidding droplets |
| `cl_smear.lua`, `cl_footprints.lua`, `cl_hands.lua`, `cl_props.lua`, `cl_tyres.lua`, `cl_contact.lua` | Transfer patterns and splashes |
| `cl_water.lua` | Blood in water |
| `cl_dust.lua` | Explosion dust |
| `cl_flies.lua` | Flies |
| `cl_flesh.lua` | GHM FLESH |
| `cl_lighting.lua`, `cl_maplights.lua`, `cl_probes.lua` | Light probes, the map's lights, reflection probes and the floor mirror |
| `cl_vat.lua` | VAT blood bursts |
| `cl_lite.lua` | Lite renderer |
| `cl_governor.lua`, `cl_battle.lua`, `cl_prof.lua` | Adaptive quality, battle size, frame profiler |
| `cl_util.lua` | Shared helpers (blood colour, stain shape, snapping, nearest bone) |
| `cl_menu.lua` | Settings window |
| `cl_debug.lua` | Debug overlays, test commands, `ghmpb_diag` |

---

## Source layout, building and tests

```
addon/ghm_physblood/         the addon: lua/, shaders/fxc/*.vcs, materials/, models/, maps/ (ghmpb_bricks),
                             data_static/ghmpb/vat/*.dat (VAT bursts), addon.json
shadersrc/                   HLSL sources (ghmpb_common.h, ghmpb_shade.h, ghmpb_sim_main.h, ghmpb_surface_main.h, ...)
native/                      C++ droplet solver (ghm_physblood.cpp) + build.sh (MinGW-w64) and the built DLLs
tools/                       build_addon_shaders.sh <tag> (ShaderCompile under Wine, ~5.5 min), slots/ and live/
                             (instruction slots and register liveness), build_workshop.py, strip_lua.py, bake_vat.py,
                             gen_*.py (test map, props, textures, cloud / lite / probe textures), bsp_tool.py (relight
                             the map without vbsp), pbr/ (spectral optics fits and offline renders)
testassets/                  generated sources of the test map, props and textures
tests/sim_proto.py           NumPy reference of the cell solver (mass conservation, pool size)
tests/sim_hf.py              NumPy port of the world-patch step (walls, floors, pours) to tune flows offline
tests/splat_preview.py       NumPy preview of drop stains on a floor (stain length, skids)
tests/stamp_preview.py       NumPy preview of hand print, tyre tread and finger streak stamps
tests/creature_preview.py    Preview of creature tracks
tests/mp_mock/               a mocked GMod client / server for LuaJIT: 31 test files (luajit test_*.lua) covering
                             multiplayer recipients and catch-up, hook priority (plain and ULib), Z-City, elements, flies,
                             dust, footprints, props, smears, lite renderer, VAT, probes and lights, mirrored UVs,
                             snapping, streaks, skids, unlit maps, 2D skyboxes, corpse impacts, globals
devharness/                  in-game test harness (command files, screenshots, scripted feature clips)
NOTES.md                     engine facts verified in game and engineering notes of every version
```

Build the shaders with `tools/build_addon_shaders.sh <tag>` (it bumps the set prefix in `sh_shaderver.lua` so a running game can load new files without a restart); build the DLL with `native/build.sh`; run the Lua tests with `cd tests/mp_mock && for t in test_*.lua; do luajit $t; done`.

---

## Patent note

The staining approach follows the idea described in US 10,685,152 (Take-Two Interactive): each splat is a flat 2D cell field reactive to physics, wrapped onto models and the map. PhysBlood is an independent implementation written for a mod. This is not legal advice: if you plan to publish or monetise it, have the patent situation checked.
