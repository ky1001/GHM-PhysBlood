# GHM PhysBlood 1.26.8

## Performance in big NPC fights

**Reported** (a player, on the Workshop): "The performance seems to have gotten way worse since the new update, I used to be able to fight loads of npcs on ultra settings with barely any lag, now it gets so unbearably laggy even if I have the settings on low."

**Cause:** 1.26.7 brought back the 1.26.2 3D fluid drops and splash crowns, and added the continuous streams, the spurts after every gunshot and the new Lite pools. None of them followed the quality setting, the frame rate or the size of the fight:

- **3D drops:** up to 320 drops were drawn as 3D meshes every frame, a draw each, spread over all the drops near or far. The rest weren't drawn at all.
- **Streams:** up to 14 streams of 25 rings × 6 sides were built as triangles every frame, about 12,600 vertices in Lua, whether in view or not.
- **Spurts:** every gunshot on a living body spurted again, on every body near or far.
- **Bursts:** up to 28 bursts and splash crowns at once, out to 25 m.
- **Lite pools:** every pool grew every frame, and up to 6 pool meshes were rebuilt every frame, near or far, in view or not.

**Fix:** a shared detail level (`cl_governor.lua`, `V.Detail`) scales all of these.

- **Quality setting:** Ultra 1, High 0.85, Medium 0.6, Low 0.3.
- **Frame rate and fight size:** the detail drops when frames get slow (adaptive quality) or the fight round the player gets big (the existing battle level), down to a quarter.

What each part does now:

| Part | Now |
|---|---|
| **3D drops** | Only the nearest drops become 3D meshes: up to 220 on Ultra, about 130 on Medium and 65 on Low, a quarter of that in a big fight, all within 8 m. Every other drop is drawn in the shader's single batch, so no drops are left out any more. |
| **Streams** | Only streams in view and within 25 m are drawn, nearest first. Near ones (up to 3.5 m) are full tubes; further ones are a half tube turned to the camera, with every second ring dropped past 9 m. They're built of quads, at most 700 faces a frame on Ultra (about 2,800 vertices), less with less detail. New streams aren't started out of view or out of reach, and there are fewer of them with less detail. |
| **Spurts** | In a big fight or on a slow frame, bodies far off (over 14 m) or out of view don't spurt, and the others spurt less. |
| **Bursts and crowns** | Fewer at once (Ultra, quiet: 28; big fight: about 7), and only nearer: crowns within about 14 m, less with less detail. |
| **Lite pools** | At most 24 pools grow per frame, each by the time since its own last step. Mesh rebuilds per frame follow the detail (1 to 6). Pools far off or out of view are rebuilt less often, and less often still in a big fight. |

The streams now count towards PhysBlood's own frame time, so the adaptive quality sees what they cost.

### Second pass: magazine dumps

**Reported** after the first pass: "i dont see a huge diffrence, and with mag dumping the blood renders very late and performance not good." The player's `ghmpb_prof` with Lite during a dump: 44 fps, worst frame 97 ms. PhysBlood took 11 ms a frame:

- drop landings: 4 ms (12.7 a frame, 0.31 ms each), worst 29 ms;
- the Lite update: 2.2 ms, worst 12 ms;
- the rivulets: 0.9 ms, worst 62 ms;
- the wounds: 0.8 ms, worst 22 ms.

**Causes:**

- **Lighting:** every Lite stain asked the engine for its light (`render.ComputeLighting`), a costly call. A landing makes up to 12 stains (the stain, its tail, satellites, splash ring), and every rivulet head asked again every 0.4 s.
- **Edge fitting:** every Lite stain over 0.7 u was fitted to the edge of what it lies on, with 4 to 16 traces.
- **Rivulets with Lite:** a rivulet stamped its trail every 0.3 u. With Lite each stamp is a stain of its own, so up to 80 heads made about 2,000 stains a second. With a slow frame they stepped three times in the next one.
- **Baking:** the Lite stains were baked into meshes from a table per vertex: 1,500 tables, Vectors and Colors a batch, a pool 1,300. The garbage collector cleared them in one go, which made the long frames. A batch was also baked in the middle of a landing or a rivulet step, wherever its 192nd stain came.
- **Bodies:** splats, mist and runs on bodies had no limit on model decals a frame. A body that died put up to 30 decals onto its ragdoll in one frame.
- **Drop traces (Lua solver):** only the first 900 drops in the list were traced. The newest drops of a dump flew on untraced and landed late. Each drop also made about 16 calls into the engine a frame (Vector maths and fields).

**Fix:**

| Part | Now |
|---|---|
| **Lighting** | One sample is shared by everything within 24 u that faces the same way, kept for 3 s, at most 6 new samples a frame (`G.Light.At`, `cl_lighting.lua`). The Lite stains and pools and the rivulet heads all use it. |
| **Edge fitting** | Only stains whose quad is over 3.2 u across (blood of about 1 to 2 u), with 24 to 96 traces a frame by the detail level. Rivulet trails aren't fitted (the rivulet follows the surface itself). |
| **Rivulets** | With Lite a trail stamp every 1.2 u (with the shaders still 0.3 u, a stroke into the patch). 24 to 80 heads at once by the detail level. At most two steps a frame. |
| **Lite meshes** | Batches and pools are built straight into their meshes (`mesh.Begin` on the mesh), no tables. Baked once a frame in the Lite update, 128 stains or 1 s a batch (192 or 2 s), so fewer stains are rebuilt every frame before they are baked. |
| **Lite pools** | The search for the pool a drop lands in uses plain numbers (it made five Vector calls for each of up to 96 pools, on every landing on a floor). Fewer pool growth traces with less detail (32 to 96 a frame). |
| **Lite landings** | The crowding check uses a number key, not a string. Floor and ceiling landings no longer build a patch for the rivulets (they only start on walls). |
| **Bodies with Lite** | 3 to 12 model decals a frame by the detail level. Past that, splats, mist and runs on bodies wait; wounds always go on. A ragdoll's decals go on over the next frames, wounds first, up to 16 a frame. |
| **Drop traces (Lua solver)** | Drops are traced in turn, a share each frame, so every drop is traced within a few frames. The count is what fits into about 2 ms (less with less detail), from the measured cost of a trace (every eighth trace is timed, landings not counted). Drops in flight are plain numbers, not Vectors. |
| **Landings** | Past 12 to 60 landings a frame (by the detail level), a landing leaves only its main stain: no tail, satellites, splash ring or bounced drops. |
| **Spatter** | The drops a hit throws share a budget over time, so a magazine dump doesn't throw hundreds of drops each frame. |

**Measured** (`bench_lite.lua`, a magazine dump with Lite at 10 shots a second, traces costed at 6 µs and light samples at 40 µs as in the game):

| | First pass | Now |
|---|---|---|
| PhysBlood Lua a frame | 10.1 ms | 4.3 ms |
| Worst frame | 52 ms | 10 to 16 ms |
| A drop landing | 0.20 ms | 0.05 ms |
| Light samples a frame | 18.8 | 0.5 |
| Traces a frame | 427 | 290 |
| Garbage a frame | 650 KB | 375 KB |
| Rivulets a frame | 1.2 ms | 0.4 ms |

### Third pass: long frames with the shaders

**Measured by the player** after the second pass (`ghmpb_prof`, both on Ultra, a magazine dump):

- **Lite:** PhysBlood 3.5 ms a frame (11 ms before), worst 15 ms (83 before).
- **Shaders:** PhysBlood 7.8 ms a frame at 29 fps, with single frames of 41 to 61 ms:
  - `.rb capture (gpu wait)`: 41 ms;
  - `.world impacts`: 43 ms;
  - `wounds`: 51 ms.

**Causes:**

- **Render-target slots made mid-frame.** A patch slot is 10 render targets and 7 materials; a body slot is 10 and 9. When the ready ones ran out (36 patches, 3 big and 6 small body slots, made at load), a slot was made at the moment it was needed, in the middle of a frame. A magazine dump over fresh walls made up to 32 in one frame, and every body that started to bleed made its own.
- **Reading back.** Reading back makes the frame wait until the GPU has caught up. With the GPU busy that was 41 ms, every 1.5 s.
- **3D drops:** 1 ms a frame, a draw each, hanging drops included.
- **Streams:** 0.55 ms a frame with 8 bodies bleeding, in both modes.

**Fix:**

- **New slots a frame:** as many as fit into 3 ms, at least one (`B.MayCreateNow`). A patch that has to wait keeps its blood and gets its slot on a later frame. A body still gets its slots at once (otherwise its first wounds would be lost), but then the patches wait.
- **Slots made ahead:** after the slots made at load, a few free ones are kept ready (1 big and 2 small body slots, 4 patch slots). They are made one at a time, every 0.5 s, between frames, and only on a frame that made none (`E.KeepReserve`, `S.KeepReserve`).
- **Reading back:** when it made the frame wait more than 12 ms, up to 4 s apart (3.3 s after a 41 ms wait).
- **3D drops:** fewer and nearer with less detail. Up to 220 within 8 m on Ultra, about 100 on Medium, 27 within 5 m in a big fight (55 before).
- **Streams:** steeper with less detail. 700 faces on Ultra, about 100 in a big fight (175 before).
- **One screen copy less:** with less detail the drops use the screen copy the blood layers already made that frame. There were up to three full-screen copies a frame.
- **Lite bodies:** 2 to 8 model decals a frame (3 to 12 before).

**New in `ghmpb_prof`:**

- With Lite: `.lite world impacts`, `.lite body impacts` and `.lite model decals`. A drop landing still took 0.27 ms with Lite, and these show where.
- The slots made while playing, and how often a patch waited a frame for one.

### Fourth pass: the landings themselves

**Measured by the player** after the third pass (`ghmpb_prof`, both on Ultra):

- **Shaders:** a steady 45 fps. PhysBlood took 3.9 ms a frame, worst 7.6 ms; there were no long frames any more. 14 slots were made while playing (6.1 ms each), and no patch had to wait.
- **Lite:** 33 fps. PhysBlood took 9.7 ms a frame, worst 46 ms.
  - The landings: 4.3 ms a frame (15.7 a frame, 0.27 ms each).
  - Of that, the stains they leave took only 1.1 ms: world 0.55 ms (25 a frame), bodies 0.55 ms (7.6 a frame), model decals 0.02 ms.
  - So about 0.2 ms a landing went into the landing's own work. The drops came from 8 bleeding bodies (28 new drops a frame, with no shooting at the time).

**Cause:** a landing worked in GMod Vectors: about 30 Vector objects a landing with its tail, satellites and splash ring, and as many calls into the engine. Each Vector is a separate object the garbage collector has to clear later. A Lite stain added up to 6 more.

**Fix:**

- **A landing in plain numbers** (`cl_particles.lua`, `Land`). Vectors are made only for what is handed on: each stain's position and velocity, and the drops it throws off. The result is unchanged: an old-against-new check of 300 landings hands on the same 2,642 stains, bounced drops, rivulet slides and splash crowns, to four decimals (`patches/eq_land_1268.lua`).
- **A Lite stain in plain numbers** (`Tangent`, `NewStain`, the water check, the crowding key).
- **Together** (`bench_lite.lua`): Vectors made per landing, with its stains, went from 29.6 to 7.8; a frame from 1,260 to 750.
- **A time budget for the landings each frame:** 1.5 to 4 ms by the detail level. Past it, the smallest drops (under 0.6 mm) land without a stain. Past twice that, only the big ones (from 1.2 mm) leave a stain. This caps the long frames when a magazine's spatter comes down at once.

**New in `ghmpb_prof`:**

- The Lua memory, and the Lua memory made each frame (`Lua KB made`, for the whole game's Lua, not only PhysBlood).
- How many landings were left without a stain by the time budget.

### Fifth pass: the real cost of a landing

**Measured by the player** after the fourth pass (`ghmpb_prof`; fps locked at 60):

- **Shaders, in a magazine dump:** 42 fps, PhysBlood 10.9 ms a frame.
  - A landing still took 0.29 ms, about 0.2 ms of it besides its stains.
  - The world simulation: 1.9 ms, 18.5 patch steps a frame.
  - The rivulets: 1.2 ms.
  - The drops' drawing: 1.4 ms.
  - The streams' drawing: 1.2 ms.
- **Lite, two bodies bleeding:** 59 fps (the limit), PhysBlood 5.2 ms.
  - A landing still took 0.29 ms, 0.25 ms of it besides its stains, whether its work was in Vectors or in numbers.
- **Lua memory made each frame:** 700 to 790 KB (the whole game).

**Cause of the landing cost:** `V.On()`, asked on every landing (for the splash crowns), looked for the VAT data on disk every time (`file.Exists` with the "GAME" path). That is a search through every mounted addon, and it was also asked several times a frame by the drops, bursts and streams.

**Fix:**

| Part | Now |
|---|---|
| **VAT data on disk** | Looked for once, and again every 10 s only while it is missing (`V.Installed`). |
| **Character ragdolls** | Whether a ragdoll is a character (a lowercase copy of the model name and up to three bone lookups) is worked out once per model. It was asked on every drop landing on a ragdoll. |
| **Lua garbage: Lite edge and pool traces** | The results are written into one table (`output`) instead of a new table of about 20 fields per trace, up to about 190 traces a frame. |
| **Lua garbage: streams** | The rings' tables are kept and used again every frame (a new table for every ring of every stream, every frame). |
| **World simulation** | Longer steps under load: up to 3.5 times the base step in a big fight or on slow frames (2.5 before), within the 0.15 s the simulation allows. |
| **Rivulets with the shaders** | A trail stamp every 0.3 to 0.6 u by the detail level. 15 to 30 steps a second (each step of each head is two traces). |
| **3D drops** | Fall off with the square of the detail level: 220 on Ultra when quiet, about 80 on Medium, 12 in a big fight. |
| **Streams** | Fall off with the square of the detail level: 700 faces on Ultra, 60 in a big fight. |
| **Reading back** | The interval follows the longest recent GPU wait, fading slowly. An average let one 22 ms wait be forgotten after two short ones. |

**Test:** `test_client_perf1268.lua` checks that the VAT data is looked for on disk once over 100 calls.

### Measured after the fifth pass

`ghmpb_prof` in a magazine dump, fps locked at 60:

| | Lite | Shaders |
|---|---|---|
| Frame rate | 60 fps | 59 fps |
| PhysBlood a frame | 3.3 ms (11 ms in the first report) | 4.1 ms |
| A drop landing | 0.05 ms (0.27 ms before) | 0.04 ms (0.29 ms before) |
| Lua memory made a frame | 375 KB (715-790 KB before) | 361 KB |

One long frame remained with the shaders: the GPU wait when reading back (26 ms, every 2 s). That wait is the GPU catching up with the frames queued ahead of it, so it can't be made shorter, only rarer. Reading back now waits up to 6 s apart after a long wait (about 4 s after a 26 ms one).

### Sixth pass: quality back (after the first upload)

**Reported** on the uploaded version: "we over optimized, now on the workshop version the blood initially doesnt spawn, it is sometimes or not atall and i want the bleeding physics on surfaces smoother and best quality with highest preset", and "the new version looks horrible again" (screenshots: coarse, stepped edges, grey dried patches, blood running in steps), with the 1.26.2 testers build as the reference.

**Causes:**

- **The adaptive quality never came back down with the frame rate locked.** The pressure went down only when the frame was 15 % faster than the target. With `fps_max` (or vsync) at the target, that can never happen, so after the first busy moment it stayed at 0.5-1.0 at a steady 60 fps (the player's `ghmpb_prof`). Pressure that high means:
  - blood settled and dried up to three times sooner;
  - drops came out up to twice as big and fewer;
  - the world simulation ran at half its rate;
  - the drops got fewer traces;
  - every detail level of this version was cut by up to three quarters.
- **The size of the fight cut the detail even at 60 fps.**
- **Landings were left without a stain.** The time budget for landings (fourth pass) counted the making of new patches. The first blood on fresh walls and floors used up the budget, so the small drops after it landed without a stain: 150-700 skipped in the player's profiles.
- **The fifth pass made the world simulation, the rivulets and reading back coarser.** It used longer world steps, a rivulet trail stamp every 0.6 u at 15 steps a second, and read back every 4-6 s.

**Fix:**

| Part | Now |
|---|---|
| **Adaptive quality** | The pressure comes down whenever the frame meets the target (within 3 %), 0.06 every half second. It still goes up when the frame is slow and the blood's own share of it is big. |
| **Size of the fight** | On Ultra it cuts quality only as far as the frame is actually slow. The detail level of this version counts it that way on every preset. |
| **Landing time budget** | Gone (a landing costs about 0.05 ms now). |
| **World simulation steps** | As in 1.26.7. |
| **Rivulets with the shaders** | A trail stamp every 0.3 u at 30 steps a second, as in 1.26.7. |
| **Reading back** | 0.3-1.5 s apart, as in 1.26.7. |
| **Hit spatter budget** | About 650 drops a second with a reserve of 480 at full detail (was 420 and 320). |
| **New slots a frame** | Up to 6 ms of them (was 3). |
| **Character ragdolls** | A "no" is kept for a model only once its bones are there. |

**Not merged: 1.26.2's surface look.** The 1.26.2 testers build has its own versions of six shaders (surface, surfstatic, bodyfilm, bodystatic, drop, probeenv). The shaders are installed with the shader pack, not with the Workshop addon. There is no readable 1.26.2 shader or Lua source to take them from: the `ghmpb_trash` folder holds older compiled shader builds (b2 to b44), the 1.26.1 pools build and dev-harness screenshots. The protected 1.26.2 build was not opened.

**Tests:** `test_client_perf1268.lua` (41 checks):

- a big fight at a steady frame rate on Ultra keeps full detail;
- a big fight with the frame slow cuts it to a quarter;
- locked at 60 fps with blood about, the pressure comes down (from 1.00 to 0.40 in 6 s);
- the other big-fight checks now run with the frame slow.

## The best blood out of the box

**Requested:** "disable the automatic tuning to fps on default ... make it that it shows the best blood system out of the box, let players tweak it in settings themselves."

| Setting | Default before | Default now |
|---|---|---|
| Cell resolution (`ghmpb_quality`) | Medium (2) | Ultra (4) |
| Simulation rate (`ghmpb_sim_hz`) | 30 | 45 |
| Max simulated models (`ghmpb_max_entities`) | 12 | 8 (the Ultra preset: each is bigger) |
| Max simulated world patches (`ghmpb_max_patches`) | 40 | 32 (the same) |
| Max flying droplets (`ghmpb_max_particles`) | 1,400 | 4,000 |
| Max aftermath patches (`ghmpb_aftermath_max`) | 400 | 800 |
| Video memory budget (`ghmpb_vram_mb`) | 1,024 MB | 2,048 MB |
| Adaptive quality (`ghmpb_perf_adaptive`) | on | **off** |
| Scale with the size of the fight (`ghmpb_battle_lod`) | on | **off** |

- **Players updating** (settings step 1270):
  - adaptive quality and the fight-size scaling are turned off once;
  - whoever still has all of the old Medium defaults gets the Ultra preset;
  - a 1 GB budget becomes 2 GB.
  - Settings a player changed themselves stay as they are.
  - Turning the tuning back on after the update sticks.
- **The menu** (Settings, Performance):
  - Ultra is marked as the default;
  - the 2 GB budget is marked as the default (with a note to lower it on cards under 6 GB);
  - the frame-rate section says the tuning is off by default and can be turned on if big fights slow the game down.

**Tests:**

- New `test_client_defaults1270.lua` (8 checks):
  - a new player starts on Ultra with the tuning off and 2 GB;
  - an updating player on the old defaults is moved over;
  - a player on Low with 512 MB keeps it;
  - tuning turned back on stays on.
- `test_client_battle.lua` turns the fight-size scaling on first, as a player would.

### GHM's drying settings are the defaults

**Requested:** GHM's tested Drying tab settings as the defaults.

| Setting | Default before | Default now |
|---|---|---|
| Clotting time (`ghmpb_coag_time`) | 180 s | 535 s |
| Drying time of thin blood (`ghmpb_drytime`) | 240 s | 1,816 s |
| Soaking in (`ghmpb_soak_speed`) | 1 | 0.28 |
| Fresh blood soaks in slowly (`ghmpb_soak_delay`) | 1 | 1.46 |
| Clotted skin, per-surface drying, time-lapse | unchanged (0.6, x1, x1) | unchanged |

- **What it means at these settings** (the Drying tab's own estimate, to 95 % dry):
  - sealed floor: a thin smear takes 1 h 31 min, a 1 mm film 5 h 7 min, a 3 mm pool 9 h 46 min;
  - a thin smear on concrete soaks in within 21 min;
  - blood is 90 % clotted after 9 min.
- **Cost:** wet blood stays live in the simulation longer.
  - A world pool stays live for up to 10 min instead of about 2.7 min.
  - A body stays live for about 4.5 min instead of 1.5 min.
  - The limits on simulated models and world patches still cap it.
- **Conditions presets:**
  - "Indoors" is the new defaults, including the slow soaking.
  - The other presets keep their proportions to it: Hot and dry 830 s / 355 s, Outdoors windy 1,135 s / 505 s, Cold and damp 5,450 s / 950 s.
  - Clotting can now be set up to 1,800 s and drying up to 7,200 s, so Cold and damp fits.
- **Players updating** (settings step 1271): anyone whose clotting, drying and soaking settings are all at the old defaults gets the new ones; anyone who set their own keeps them.
- Weapons and pool streams still scale their clotting from 180 s. At the new default they gel about three times later, as in GHM's test.

### Ultra preset notice at the start of a map

**Requested:** a warning for players on Ultra when they start a map ("FPS might suffer, wanna change that? click here to open menu").

- **When it shows:** 12 s into a map, if the mod is on, the preset is Ultra, and the notice hasn't been answered for 1.26.8. It also puts a line in the chat.
- **The window says:** "GHM PhysBlood is set to the Ultra preset: the best-looking blood, and it no longer turns the quality down by itself. FPS might suffer, most of all in big fights or on older graphics cards. Want to change that?"
- **Buttons:**
  - **Open settings** opens the settings window on the Quality tab;
  - **Keep Ultra** closes it;
  - both answer it for this version (`ghmpb_ultra_notice`);
  - **Later** asks again at the next map.
- **Only one window at a time:** it waits while the shader files window, the settings window or the game menu is open (for up to 3 minutes).

**Tests:**

- New `test_client_defaults1271.lua` (33 checks): the defaults; the presets' ranges and proportions; the migration; and the notice (when it is due, the window and its text, each button, waiting for the other windows and the game menu).
- `test_client_drying.lua`:
  - checks the new defaults;
  - runs its drying-law checks at the old figures;
  - checks the conditions presets at the new ones;
  - a pool that would take more than 2 days counts as "longer".
- `test_client_history.lua`, `test_client_lite.lua` and `test_client_oldblood.lua` pin the old drying figures, because their timings assume them.

## Shots on some NPCs made no blood or wounds

**Reported:** "first few shots DO NOT register on npcs and spawn blood, actually some npc at random do not spawn any of the blood and or wounds when shot."

- **Cause** (in the client since 1.26.6, `cl_render.lua`):
  - When an NPC turns into its ragdoll, the client links the NPC's entity index to the ragdoll (`R.ragByIdx`), so hits that arrive during the change still land on the body.
  - The link was kept for as long as the corpse lay there.
  - The server gives a freed index to the next entity it makes (after about a second).
  - So a new NPC that got a dead NPC's index sent every hit to the old corpse. Every frame, `E.Update` and `W.Update` also moved its wounds and bleeding over to the corpse.
  - The NPC showed nothing until it died, then its own ragdoll took the killing shot. Which NPCs were affected looked random, because it depends on which indices the server reuses.
- **Fix:**
  - A link remembers which body it came from and when.
  - A living entity is sent to a ragdoll only by its own link.
  - An index the client has no entity for follows a link only for 5 s, which covers a hit arriving while the NPC is turning into its ragdoll.
  - A new entity taking the index drops the link.
- **Also:**
  - A model whose materials weren't loaded yet the first time it was hit is worked out again 3 s later. It used to stay "no blood on this model" for the rest of the game.
  - Hits on bodies that don't bleed on this client now show up in `ghmpb_diag`.
- **Tests:** new `test_client_idxreuse.lua` (12 checks).
  - The NPC's own ragdoll still takes its hits.
  - A new NPC with a dead one's index keeps its hits (both the hit message and the per-frame check), including when its creation wasn't seen.
  - A server ragdoll takes hits for its index for a few seconds but not minutes later.
  - A new entity at the index drops the link, and the old corpse keeps its own hits.
  - With the old `cl_render.lua`, 6 of the checks fail.

## No "water ripple" on headshots

**Reported:** "when giving a headshot there is a water ripple particle effect, big one and small, please remove that." It wasn't clear which effect it was, and the answer was to remove all three that could look like it:

- **The fluid bursts from a head hit** (the 3D VAT splashes: a small one where the bullet goes in, a bigger one where it comes out, and the spray bursts).
  - While a head hit is worked out, `G.VAT.mute` is set (`cl_wounds.lua`, where the region is known: `W.OnHit`, `W.ShotWorld`, `W.SpatterOnly`). `V.Spawn` then throws no burst.
  - The setting is put back after the hit, also when the hit fails half way.
  - The mist from a head hit falls back to its soft puffs. Streams from the wound and drips stay.
- **The splash crowns** where big drops land on the floor: off (`V.CROWNS`).
- **The white rings over Lite pools** as blood drips into them: off (`L.RIPPLES`).

**Tests:**

- New `test_client_headburst.lua` (5 checks):
  - a headshot's burst requests are all muted;
  - a chest hit's are not;
  - a headshot thrown before the body is known is muted;
  - the setting is put back after a hit, also one that fails half way.
- `test_client_perf1268.lua`: no entry or spray burst while muted, the wound's jet still plays.
- `test_client_vat1267.lua`: no crowns by default; the crown rule still checked behind `V.CROWNS`.
- `test_client_lite.lua`: a drop into a pool makes no ripple.

## Back splatter now carries over from the NPC to its ragdoll

**Reported:** "blood back splatter doesn't always carry over from npc state to ragdoll state making them not always appear." The video showed five .357 kills. Every one left the spatter thrown back towards the shooter on the floor, but none left a splat on the wall behind the NPC.

**Cause:** the killing shot reaches the client while the NPC is turning into its ragdoll. The blood thrown out of the back could be lost in three ways:

- **The NPC was already gone.** The hit waited for the ragdoll to be known, and could be dropped. Even when it arrived, the blood came late, from where the ragdoll had moved to.
- **The hit landed on the ragdoll.** The client can't trace through a ragdoll the way it traces through an NPC. No exit was found, so there was no exit spray and no blood on the wall behind.
- **The NPC and its new ragdoll overlapped for a moment.** The blood leaving the exit wound hit the ragdoll, a body no one knew about yet, and was gone. Drops thrown from inside it vanished.

**Fix:**

- **Exits are found on every body** (`W.FindExit`):
  - NPCs and players: the engine's trace, as before.
  - Ragdolls: PhysBlood's own ray through the hitboxes at the body's current bones.
  - A ragdoll that has fallen off the bullet's path since the shot: the exit is placed where the body was, from how thick the body is at that spot (head, chest, limbs).
- **A bullet's blood flies at the moment of the hit** (`W.ShotWorld`), from where and in the direction the server says it hit. This includes when the body is not on the client yet, or its bones are not ready.
  - It covers the back spatter towards the shooter and, through the body, the exit spray and the blood on the walls and floor behind.
  - Bodies that are gone keep their blood colour (yellow, green and so on).
  - The wounds and bleeding follow on the ragdoll once it is known, and the blood is not thrown a second time.
- **The blood leaving a body passes both forms of it** (the NPC and its ragdoll):
  - `F.PlumeFilter` leaves out bodies right where the blood leaves.
  - A stream that starts inside something that is not the world goes on through it.
  - Drops thrown from inside the ragdoll pass out of it instead of vanishing (`cl_particles`).
- **The killing shot spurts on the ragdoll too.** When that shot reaches the client only after the body became its ragdoll, it now spurts like it would on the NPC.
- **New diagnostics** (`ghmpb_diag`): how bullet exits were found (traced, through hitboxes, or where the body was), and how much blood was thrown before its body was known.

## Pools flickering when bodies lie in them

**Reported:** "bloodpools flicker when npc are on the bloodpool." The clip showed the bodies' shadows appearing and disappearing for a frame or two, several times a second, over and around the pools.

**Cause (most likely):** the reflection probes. They render extra views of the scene from just above each pool, usually from inside the bodies lying in it, before the main view of every frame. The engine works its shadows out again for each of those views, so the shadows the main view used kept changing.

**Fix:**

- **Probes off by default.** Pools reflect the map's cubemap instead. Players still at the old default (2) get the new one once (settings step 1269).
- **When switched on** (Settings, "Reflection probes"), each probe view renders without the engine's shadows (`r_shadows_gamecontrol`, the way a `shadow_control` entity sets it). Maps that have shadows switched off are left alone.

## Z-City multiplayer: each player sees PhysBlood in their own game

**Requested:** "if someone uses this mod it overwrites the Zcity multiplayer blood effect for the player, so that it works with or without shaders and they can see it locally in their own game."

### Server runs PhysBlood

- Each player sees the blood in their own game, with the shaders or with Lite, as they have set it.
- A player who switches PhysBlood off (`ghmpb_enable 0`, now sent to the server as user info) gets Z-City's own blood back:
  - Z-City's blood functions are given back in their game, as before.
  - New: the blood effects and blood decals that the Z-City server makes are now sent to that player only. They are no longer dropped for everyone.

### Server does not run PhysBlood

**Local mode:** PhysBlood works alone in the player's game.

- The client notices that the server does not know PhysBlood's network messages. It then:
  - sends the server nothing;
  - keeps its server settings at their defaults;
  - makes hits from Z-City's own hit messages (`hg_bloodimpact`).
- Each hit puts a wound on the body and throws back spatter. When the bullet goes through, it also throws the exit spray and blood onto the wall behind.
- For each hit, PhysBlood:
  - **merges duplicates:** Z-City sends two or three messages for one bullet, so the first makes the hit and the rest are left out;
  - **takes the bullet class from the shooter:** the player whose aim passes the hit gives the weapon.
- **Players bleed red:** Z-City switches the engine's blood off on every player and NPC. In local mode, players and humanoid NPCs still bleed red.

**Limit:** Garry's Mod runs a player's own addon Lua on a server only when the server has the addon or allows client Lua (`sv_allowcslua 1`). On other servers the game doesn't load PhysBlood at all.

**Not replaced in local mode:** the small blood puffs and decals that the Z-City server itself sends. The engine draws those without Lua.

### Menu

The Compatibility section explains the per-player behaviour, and says when the server does not run PhysBlood.

## Tests (mocked GMod, LuaJIT)

- New `test_client_ragcarry.lua` (23 checks):
  - the NPC is there;
  - the NPC is gone when the hit comes;
  - the hit lands on an untraceable ragdoll;
  - the ragdoll has fallen off the bullet's path;
  - an unknown ragdoll overlaps the NPC (this check fails without the fix: 6 splats on the wall instead of 31);
  - colour of a body that is gone;
  - spurts on the ragdoll;
  - local mode: detection, blood type, a hit from Z-City's messages with the duplicate left out, no second hit when the server runs PhysBlood.
- `test_client_probes.lua`: 3 new checks (probe views render without shadows and turn them back on after; maps with shadows off stay off; probes off by default).
- New `test_client_perf1268.lua` (41 checks):
  - detail by quality and fight size;
  - the nearest drops as meshes up to the budget, the rest in the batch, none past 8 m;
  - fewer bursts and no far crowns in a big fight;
  - streams as quads within the budget, none behind the camera, a full tube near and a half tube further off;
  - third pass: new slots a frame within 3 ms, at least one; reading back every 3.3 s after a 41 ms wait; 27 3D drops within 5 m in a big fight;
  - second pass: every one of 1,200 drops traced within 12 frames, with about 150 traces a frame at 20 µs a trace; a landing's extras up to the limit a frame, then the main stain only; light samples shared on one spot, a facing of its own, 6 new a frame, sampled again after 3 s; fewer rivulet heads with less detail; a rivulet stamps its trail a quarter as often with Lite.
- `test_client_lite.lua`, 7 new checks: small stains get no edge traces, big ones do, at most 96 a frame, again the next frame; batches and pools built straight into meshes; 8 model decals a frame plus the wound; a ragdoll's decals over the next frames. The mock builds meshes from `mesh.Begin` on a mesh, and the bleeding onto a body runs over frames as in the game.
- New `bench_lite.lua` (not a test): a magazine dump with Lite, counting traces, light samples, Vectors, mesh vertices and garbage. `bench_magdump.lua`: gravity set (the mock had none, so drops floated).
- `test_client_streams.lua`: the mesh mock accepts quads; the camera looks at the body.
- New `test_server_zcrelay.lua` (5 checks): Z-City's blood effects and decals reach only the players who switched PhysBlood off.
- Rest of the suite: unchanged against 1.26.7. The same older tests fail before and after (bsptex, drying, lite, look, materials, probes, slide, vat, globals, server_far).
