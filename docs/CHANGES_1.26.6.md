# GHM PhysBlood 1.26.6 (Claude, Cowork chat, 26 Oct 2026)

Built on the readable code handed over as "1.26.3" (`Claude outputs\GHM_PhysBlood_1.26.3_readable`). That code is the
1.26.4 line: it already has the 1.26.4 hit spatter (entry back spatter + exit spray + VAT bursts on gunshots) and the
1.26.1 drying/soaking settings. Not installed or uploaded anywhere except your two local Garry's Mod folders.

## What changed against that code

| # | Area | Change | File |
|---|------|--------|------|
| 1 | Floor pools | The 1.26.1-pools floor shader: pools fill the floor's shallow dips, push out lobes and bays, run short tongues down worn grooves and leave dry islands (the pools you liked in Gemini's 1.26.5). Drop-in: 1.26.3's own pool shader was byte-for-byte the 1.26.0 one, and the Lua interface is unchanged. Help texts for "Floor unevenness" updated. | `shaders\fxc\ghmpbb74_pforce_ps30.vcs`, `cl_menu.lua`, `sh_config.lua` |
| 2 | "Odd splat on every little fall" | A 3D VAT crown mesh popped up under every drip that landed (since 1.26.4). Back to the 1.26.0 rule: only big, fast drops, at most one per 0.25 s and per 12-unit cell. | `cl_vat.lua` |
| 3 | "Jelly-like" drops | Since 1.26.4 flying drops and hanging drips were drawn as 3D VAT meshes. Now a setting, off by default (`ghmpb_vat_drops`, Fluid bursts tab): drops are drawn by the blood shader again. The VAT bursts at wounds/hits stay on. | `cl_vat.lua`, `cl_menu.lua` |
| 4 | Satellite ring around landing drops | Only for big drops that fall about 2 m or are thrown (was every drip off a standing body). | `cl_particles.lua` |
| 5 | Footprints | No more 1-2 m straight smear lines when running through blood ("as if I were a car"). | `cl_footprints.lua` |
| 6 | Ragdoll blood flicker/vanishing | The bonemerged body-film proxy is no longer moved/set up every frame. | `cl_entities.lua` |
| 7 | Lite mode gray/white pools | Weak crimson sky reflection, no `$basealphaenvmapmask`, ambient floor (from Gemini's 1.26.5). | `cl_lite.lua`, `lite\stain_shine.vmt` |
| 8 | Settings reset on start-up | Custom splatter settings survive a restart (from Gemini's 1.26.5). | `cl_wounds.lua` |
| 9 | ARC9/ArcCW viewmodel shake | Reflection probes render in RenderScene, view hooks guarded (1.26.1 vm fix). | `cl_probes.lua` |
| 10 | Version | 1.26.6 | `autorun\ghm_physblood.lua` |

Hit spatter on the first hit: present and on by default (`ghmpb_splat_entry` / `ghmpb_splat_exit` = 1).

## Shaders

Prefix stays `ghmpbb74_` so players who already have the 1.26.3 pack keep working. Only `pforce_ps30` is new; every
other file is the 22 Oct set. The DX11 `pforce_ps50` is still the 1.26.3 one (no DX11 build of the new pool shader that
I could verify), so DX11 players get the 1.26.3 pool shape. Shader pack: `GHM_PhysBlood_1.26.6_Shaders_Pack.zip`.

## Checked

- `luac -p` on all 51 Lua files.
- Offline mock tests: same results as the unmodified code everywhere, plus the vm-fix test now passes (7/7).
- Shader bytecode compared (instruction streams): 1.26.3 `pforce_ps30` == 1.26.0 `pforce_ps30`; Gemini's 1.26.5 set
  == 1.26.0 shaders + the 1.26.1-pools `pforce`; 1.26.3 differs from 1.26.0 in surface, surfstatic, sim, simbody,
  bodyfilm, bodystatic, drop and probeenv, so those stay 1.26.3 (the 1.26.6 Lua is written for them).
- Not yet tested in game.

## Added (second round)

### Your own blood colours (Settings > Look > Your own blood colours)
- `ghmpb_color_custom` (on/off), `ghmpb_color_blood` (a thin film of fresh blood, "R G B") and `ghmpb_color_dense`
  (a deep pool, "R G B"), with two colour pickers and a preview: your colours next to what the blood shaders will show.
  Picking a colour turns the option on; "Reset my colours" turns it off again.
- The Hue / Fresh brightness / Density sliders still fine-tune your colours. Red (human) blood only; yellow, green and
  zombie blood keep theirs. Dried blood keeps using "Dried / old blood brightness".
- Lite renderer, 3D bursts, mist and water clouds: your colours exactly.
- Shaders: the compiled 1.26.3 shaders work the colour out from absorption spectra and only take a hue and a density,
  so the hue (-1..2) and absorption whose thin film and pool come closest to your two colours are fitted (OKLab, on a Lua
  mirror of the shaders' Kubelka-Munk optics) and sent instead. Any red, scarlet, orange-red, crimson, maroon or
  near-black comes out close; green or blue blood can not be shown by these shaders (the menu says so and shows the
  nearest). Exact colours in shader mode need two new shader constants, i.e. the 1.26.3 shader source.
- Files: `sh_config.lua`, `cl_util.lua` (U.CustomColours, U.ShaderLook, U.ShaderFit, G.BloodHue, G.BloodAbsorb,
  U.BloodDense), `cl_surfaces.lua`, `cl_entities.lua`, `cl_particles.lua`, `cl_gpu.lua`, `cl_lite.lua`, `cl_vat.lua`,
  `cl_menu.lua`.

### Outdated shader warning (every update)
- `sh_shaderver.lua` now carries the manifest of this version's shader pack (size of each of its 56 files, version,
  download link, what changed). `tools/make_shader_manifest.py` writes it: rerun it for every build whose shaders change.
- New `cl_shadercheck.lua`: 8 s into a game it checks the installed files. Missing, incomplete or from an older pack
  (the 1.26.3 pack has the old `pforce_ps30`) -> a chat line and a window: what is wrong, what is new, "Download shader
  pack", "Copy link", "Workshop page", "Later" (asks again next start), "Don't remind me for 1.26.6" (a newer version asks
  again). Shader sets of earlier versions (other `ghmpb*_` prefixes, e.g. Gemini's `ghmpbcp1_`) are listed. Players who
  chose the Lite renderer on purpose are not asked to install shaders.
- `ghmpb_shader_check` (console) and Settings > Quality > "Check shader files / get the shader pack" run it on demand;
  the renderer status line shows the result.
- Installer (shader pack): shows per install what is up to date / outdated / missing and which earlier sets are there,
  replaces outdated copies (also copies inside `garrysmod\addons\*\shaders\fxc`, so an older one can not be loaded
  instead), and asks whether to move earlier sets to `garrysmod\shaders\ghmpb_old_shaders` (never deletes).
- Download link in the manifest: (an old Google Drive link, replaced by the GitHub releases page; the 1.26.6 pack,
  byte-identical to `GHM_PhysBlood_1.26.6_Shaders_Pack.zip`, shared with anyone who has the link). The older link
  (1PALURj..., Gemini's ghmpbcp1 pack) is no longer used (changed 27 Oct).

### Checked (second round)
- New offline tests: `test_client_colours.lua` (13/13: defaults change nothing, fit lands on the default settings,
  scarlet/darker picks, sliders still act, green reported as out of reach, other blood types untouched, fit ~1 ms) and
  `test_client_shadercheck.lua` (12/12: ok / outdated (1.26.3 pack) / incomplete / missing, DX9 vs DX11, earlier sets,
  reminder and "don't remind me"). All other tests unchanged against the readable code. `luac -p` on all 52 files.
  PowerShell parser on the installer scripts. Not yet tested in game.

## Installed (26 Oct, ~19:00; second round ~19:40)

- `E:\SteamLibrary\steamapps\common\GarrysMod\garrysmod\addons\ghm_physblood` (whole addon) + `garrysmod\shaders\fxc\ghmpbb74_pforce_ps30.vcs`
- `C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\ghm_physblood` + the same shader (also in the addon's own `shaders\fxc`)
- Gemini's E: build backed up first: `Claude outputs\E_ghm_physblood_gemini_1.26.5_backup.zip`

The local addon folder overrides the Workshop copy, so restart Garry's Mod to test 1.26.6. To go back to Workshop
1.26.3, move `garrysmod\addons\ghm_physblood` out of the addons folder (e.g. into `Claude outputs`).

## Fix (third round): striped, rectangular pools "after a while" and pink footprints

- **Pools**: the readable 1.26.4-line code had narrowed the bed probe (the trace that finds the real ground under a pool
  patch) from +-6 to +-1.35 units and marked empty probe cells -1 instead of 0. A pool patch takes over the plane of any
  impact within +-5 units of it, and gentle slopes are snapped to a level plane, so on slopes and uneven ground most of a
  patch read as "no ground". Those patches became relief patches full of holes: blood landing in a hole ran straight off
  (the rectangular cut-offs and curtains down the slope) and the relief rendering across the holes drew the torn
  horizontal bands, more of them the further a pool spread. Back to the 1.26.0 values (+-6, 0) that the shaders are made
  for. `cl_surfaces.lua`
- **Footprints**: almost every print came out as a thin pink lug pattern (1.26.4-line freshness / stain values). Back to
  the 1.26.0 values: a soaked sole prints solid and dark red, the lugs show as the sole runs dry over the next steps.
  `cl_footprints.lua`
- Installed to both Garry's Mod folders (E: and C:). Restart the map (or the game) to load it.

## Fix (fourth round): pools that look dry long before the drying time

- Half of a body's pool turned into a dull, dry-looking stain with a blocky edge while it should still be wet. That part
  had settled into the static aftermath layer, which draws settled blood clotted and dull from the moment it settles
  (at aftermath resolution, hence the blocky edge). Pools settled after half the clotting time (90 s), the frame-rate
  governor cut that to 27 s (splats to 8 s) even right in front of the camera, and a square holding only blood that had
  flowed in from the pool next to it was treated as a small splat (25 s).
- Now a pool stays wet and live until it has nearly clotted: 90 % of the clotting time and at least half the drying time
  (162 s with the default settings; at most 10 min, or "Settle after" if that is longer). Squares next to a pool count
  as pool. Within ~16 m of the camera the governor keeps at least 60 % of that time (25 s for splats).
  `sh_config.lua` (G.PoolSettleTime), `cl_surfaces.lua`, `cl_menu.lua` (help text under "Settle after").

## Blocked account (removed again before the Workshop upload)

- The block on Steam account 76561198794353993 (`GHMPB.Blocked` in `autorun\ghm_physblood.lua`) is taken out of 1.26.6:
  the Garry's Mod Workshop rules count SteamID checks that keep a player from using an addon as malicious code, with a
  permanent ban from the Workshop hub for the uploader. The threats are reported to Steam.

## Fix (fifth round, 27 Oct): old blood too bright and shiny, splashes, default colours, zombie blood

- **Zombie and alien blood bright orange**: the hue and absorption fitted to your own (red) colours went to every blood
  type, so with bright own colours zombie and yellow blood came out a light orange. Own colours now apply to red blood
  only; zombie, yellow, green, synth and oil blood use the plain settings again (world, settled blood, bodies and flying
  drops). `cl_util.lua` (G.BloodHueFor / G.BloodAbsorbFor), `cl_gpu.lua`, `cl_surfaces.lua`, `cl_entities.lua`, `cl_particles.lua`
- **Old blood stays bright**: the shaders darken the dried crust by themselves, but wet and clotted blood kept the fresh
  absorption, so with bright fresh colours an old pool stayed bright scarlet. Every pool now keeps the (volume-weighted)
  time its blood arrived and darkens over the clotting time (3 min by default) to at least the default physical darkness
  (x "Dried / old blood brightness"). A few fresh drops on an old pool hardly make it look new again. With the physical
  colours (the old defaults) nothing changes. `cl_util.lua` (G.AgeFrac, G.AbsorbAged), `cl_surfaces.lua`, `cl_entities.lua`
- **Old blood stays shiny**: reflections and highlights fade with age: to 70 % as blood clots, to about 28 % once
  settled blood has dried; old body blood also loses gloss. `cl_util.lua` (G.ShineAged), `cl_lighting.lua` (reflMul)
- **Spilling and backsplash**: round 1 had cut the 3D splash crown and the ring of satellite stains back to drops that
  fall about 2 m. Crowns again for big drops and streams from about knee height (at most one per spot every ~1.1 s, so
  a dripping wound does not splat on every drip; smaller drops now and then when thrown or falling far); satellites back
  to the 1.26.4 rule. Both follow the Splashes setting (0 = none, 3 = a lot). Players still on the old "Bursts on screen"
  default of 10 get 28: at 10, each gunshot's bursts and sprays replaced the ones still playing. `cl_vat.lua`,
  `cl_particles.lua`, `cl_menu.lua`
- **Zombie blood**: chunks, blast clumps and about a third of the big drops thrown from zombies are red blood.
  `cl_forensic.lua`
- **Default colours = GHM's**: own colours on, thin 255 10 0, dense 171 9 0, fresh brightness 2.55, old blood 0.9,
  density 3.53, and his 3D burst colours. Players whose colour settings were all still at the old defaults are moved to
  the new ones once (config version 1266); anyone who changed them keeps theirs. "Reset" buttons go to the new defaults;
  "Physical colours" turns own colours off. `sh_config.lua`, `cl_vat.lua`, `cl_menu.lua`
- **Lite renderer** with bright colours: a stain could brighten the floor's red channel and lost its own lit colour.
  `cl_lite.lua`
- Checked: `luac -p` on all files; offline tests unchanged except the new and updated ones (`test_client_oldblood.lua`
  16/16, `test_client_colours.lua` updated for the new defaults, `test_client_slide.lua` slow drop below the satellite
  speed); the protected build verified file by file against the source. Not tested in game.
- Installed to both Garry's Mod folders (E: and C:); the Workshop package in `Claude outputs\Publish_PhysBlood_1.26.6`
  is rebuilt with it (not uploaded).

## Sixth round (27 Oct): exit spatter by ammunition, Next Gen Blood spatter patterns, seams in pools, slopes

- **Bullets by ammunition**: each bullet hit gets a class from its damage type, the attacker's weapon / ammunition and the
  damage - pistol / SMG, magnum, rifle, sniper (anti-materiel, crossbow), buckshot. Pistol rounds and buckshot often stay
  in the torso (buckshot goes through more often close up); rifles, magnums and snipers always go through. What goes
  through throws an exit plume: 3 to 22 traced streams per hit that carry blood onto the walls, floor, ceiling and props
  behind the body (about 4 m for a pistol, 8 m for a rifle, 12 m for a sniper), dense and big near the body, smaller and
  scattered further off, elongated at grazing angles, painted after their flight. Independent of "Max flying droplets".
  Entry back spatter and exit spray scale with the class; head shots throw more; heavy rounds throw chunks.
  `cl_forensic.lua` (F.Ballistic, F.Exits, F.ExitPlume), `cl_wounds.lua`
- **Spatter patterns from Next Gen Blood** (GHM's Cyberpunk 2077 splatters): `tools/make_ngb_spatter.py` measured the
  drops of six of its splatter textures (dense core, scattered drops, fine mist) into `cl_spatterdata.lua`. Where an
  exit plume's main stream lands close behind the body (and where an explosion's blood hits a wall) one of them is laid
  out on the surface: every drop painted with the forensic stamp (its own stain, spines, satellites), the pattern
  stretched the way the blood travelled, 17 cm (pistol) to 45 cm (sniper) across and wider the further it flew. At most
  4 a second; fewer small drops far away and in battles. Shaders unchanged. `cl_forensic.lua` (F.Spatter), autorun
- **Seams in pools / matte pools**: round 5 aged every 76 cm square on its own, so a pool spread over several squares got
  a different darkness and shine per square (rectangles, bands down slopes) and clotting pools lost shine next to their
  fresh streams. Connected blood (live and settled squares within ~1.5 squares) now forms one group every 0.5 s and
  shares one age. Wet and clotting blood keeps its full shine; only dried blood loses it. `cl_surfaces.lua`
  (S.UpdateAgeGroups), `cl_util.lua` (G.ShineAt)
- **Slopes and walls**: rivulets are wider for their volume (1.9-7.5 mm on walls) and wider still on slopes (about x2 at
  45 degrees), carry up to 0.5 ml each on gentle slopes, start from wider lanes along a pool's edge and merge when they
  touch - a few full streams instead of a dozen hair-thin threads. `cl_runs.lua`
- Tests: `test_client_ballistics.lua` (31), `test_client_slopes.lua` (6), `test_client_oldblood.lua` (grouped ageing);
  all other tests as before. The protected build passes the same tests. Not tested in game.
- Installed to E: and C:; Workshop package in the publish folder rebuilt (not uploaded).

## Fix (seventh round, 27 Oct): no back or front spatter when shooting bodies

- **The droplet limit swallowed it**: hit spatter counted against "Max flying droplets" (448 in GHM's settings, halved
  to about 224 by the frame-rate governor). Bleeding bodies keep that many drops in the air, so a gunshot's back spatter
  and exit spray mostly never spawned. Hit spatter may now go past the limit (1.6 x + 300) and is thinned against that.
  `cl_particles.lua` (prio, P.ThinPrio), `cl_forensic.lua`
- **Invisible drops**: back / exit spatter drops were forensic mist (median 0.3 / 0.4 mm) - below a pixel in the air and
  millimetre stains. Now median 0.55 / 0.75 mm, up to 2 / 3 mm.
- **Back plume**: back spatter is traced too - streams back towards the shooter onto the floor and walls in front of the
  body (0.6 m pistol ... 3.4 m sniper), like the exit plume behind it.
- **Dead and drained bodies**: spatter scaled with the corpse factor (nothing after 3 min) and the blood left. Bullets
  through a dead or drained body now throw at least 45 % of a fresh body's spatter (no new bleeding). `cl_wounds.lua`
  (W.SpatterOnly)
- Test: `test_client_gunshot.lua` (8): living NPC, fresh corpse, 5-minute-old corpse, drained body, drop sizes, the limit.

## Fix (eighth round, 27 Oct): dry-looking runs and spatter, black beads

- **Black balls on the runs**: the bead at the front of a run is drawn as a droplet, and droplets were lit with the light
  of a point 100 u in front of the camera - inside the wall or the ground when the camera was close to one, where there
  is no light. Since round 6 a head also carried up to 0.5 ml on slopes and was drawn as an 8 mm ball standing off the
  surface. Drops are now lit at a point in the open in front of the camera (the 3D drops too), and run heads are small
  domes (at most 1.5 mm, no wider than a third of the stream) lit with the light the surface under them gets.
  `cl_lighting.lua` (L.ViewProbePos), `cl_runs.lua` (R.Draw, R.HeadLight), `cl_particles.lua`, `cl_vat.lua`
- **Spatter looked dry the moment it landed**: the stamped spatter (Next Gen Blood patterns, exit plumes) was painted
  with films of 2-10 microns, which the shaders draw as a dried stain. Stamped stains now get at least a wet film (0.035
  mm on small drops, up to 0.08 mm on big blotches); big blotches on walls run. The pattern drops were also all stamped
  as grazing hits (3.5 : 1 streaks): they are round when the blood hits straight on and drawn out along its travel only
  when it hits at an angle. `cl_forensic.lua` (F.WetVol, F.Spatter, F.ExitPlume)
- **Run trails went in as 38 % dried stain** (the impact code raised their 0.35 to the splat minimum): now 15 %. The bead
  at the end of a run is a flat 0.4 mm bead instead of a 2 mm high dark dot. `cl_runs.lua`, `cl_surfaces.lua`
- **Fresh blood wetness** (new setting `ghmpb_fresh_wet`, Look tab, default 2.5): fresh blood gets that much more of the
  shaders' wetness than the Wetness setting gives - thin films on walls, spatter and runs read as liquid (glossy, deep
  red) - full until 40 % of the clotting time, fading out by the time it has clotted. It only acts on wet blood, so
  dried blood does not turn shiny. `cl_util.lua` (G.FreshWet), `cl_surfaces.lua` (S.LookPair), `sh_config.lua`, `cl_menu.lua`
- Test: `test_client_wet.lua` (24). Not tested in game.

## Performance (ninth round, 27 Oct)

- The screen was copied for the live blood layers every frame, also with no fresh blood (or no blood at all); the copy
  is made only when live blood is drawn. `cl_render.lua`, `S.HasLive`, `E.HasLive`
- Droplets outside the view (beside and behind the camera) are no longer built into the frame's mesh (16 engine calls
  each); the batches are counted while the drops are gathered. `cl_particles.lua`
- Settled blood works out its drying, age, shine, wetness and type every ~0.4 s per square instead of every frame
  (benchmark with 110 squares: 110 -> ~3.5 a frame). `cl_surfaces.lua` (DrawStatic)
- The age groups are worked out again only when blood was added, settled or removed (or at least every 5 s), and without
  a Vector call per pair of squares. `cl_surfaces.lua` (S.UpdateAgeGroups)
- Runs merge with each stream's width worked out once per pass; spatter-pattern drops under half a pixel from the
  camera are not painted. `cl_runs.lua`, `cl_forensic.lua`
- Test: `test_client_perf.lua` (12); `bench_perf.lua` (benchmark). Full suite unchanged against the baseline.
