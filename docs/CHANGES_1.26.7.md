# GHM PhysBlood 1.26.7 (Claude, Cowork chat, 27 Oct 2026)

Built on 1.26.6 (the version on the Workshop). Installed in your two local Garry's Mod folders only. Nothing is uploaded.

## What the testers liked in 1.26.2, and what came back

I compared the 1.26.2 tester build with 1.26.6 without opening its protected Lua, using the files you can read (the
textures, VMTs, VAT data and shader files), the testers' guide, the readable 1.26.3 code it grew into, and its console
variables as `find ghmpb_` shows them in game.

* **The physics.** The settings are the same in both versions, except 1.26.6 added `ghmpb_vat_drops` and set it to **off**.
  In 1.26.2, every flying drop, hanging drip and stream was a deforming 3D fluid mesh ("VAT replaces ALL blood
  particles"). 1.26.6 also limited the splash crowns where drops land. Both are now back to 1.26.2:
  * `ghmpb_vat_drops` is on by default. Players coming from 1.26.6 get it turned on once.
  * Splash crowns follow the 1.26.2 rule again: drops of about 1.15 mm or more landing at 150 u/s or faster, at most one
    per spot every 0.65 s. The Splashes slider still scales this (0 = none, below 1 = fewer).
* **The VAT data** (drops, drips, streams, sprays, bursts) is byte-for-byte the same in 1.26.2 and 1.26.6. Nothing to
  merge there.
* **The shaders: not merged.** 1.26.2 has its own versions of 6 shaders: surface, surfstatic, bodyfilm, bodystatic, drop and
  probeenv. They are neither the 1.26.1 nor the 1.26.3 set. The 1.26.6 Lua drives the 1.26.3 shaders, and swapping in
  1.26.2 files without their source would bring back the broken constants of 1.26.5. If part of what people liked is
  1.26.2's surface look, the readable 1.26.2 source (Lua and HLSL) is needed to bring it in properly.

## Gunshot spatter: Crisis Response Blood splats instead of big drops

Players' feedback: the spatters are too large, there are only two or three spatter textures, and a pistol headshot covers
the whole wall. Your test of the first build: the new decal textures had odd black edges, and the big drops were too dense
("can we add that we use the crisis response splats instead"). The splatter now comes from the Crisis Response Blood Mod
itself (`Crisis_Response_Blood_Mod_0.3.0 (update 1).rar` from your Google Drive, the file linked on the Workshop page).

**Its splat decals** are `materials/decals/bloodplace/blood1-36` (the "aftermath" splats it lays at scale 2). They are in
PhysBlood as `materials/ghm_physblood/crb/bp1-36`, **copied byte for byte** (1024 px DXT5, 47 MB; about 3 MB of the
Workshop download, which is compressed), with the original VMT settings (DecalModulate, `$decalscale` 0.03), by
`tools/make_crb_decals.py`. bp12 and bp30 are 512 px in the mod and show at half size, as they do there.

*Why the edges looked odd:* the first build re-encoded them at 512 px with one-bit alpha (DXT1) to fit the transfer size.
That format stores transparent pixels as black - in your textures they are neutral grey (123) - so DecalModulate drew a
black rim round every drop, and the 2-3 px drops became blocky squares at half the resolution.

**Where a gunshot's blood lands** (the traced streams of the exit plume behind the body, and of the back plume onto the
floor and walls in front of it), red blood now leaves CRB splats instead of PhysBlood's wet drops:
* a few splats per hit: pistol 2, magnum and rifle 3, sniper 4, buckshot pellet 1 (back plume: half, at least 1)
* the main one bigger: about 28 u (55 cm) across for a pistol, 37 u for a rifle, up to 56 u for a sniper (the CRB mod lays
  them at 61 u); the others about half that; bigger the further the blood flew
* one random splat of the 36 each time; the rotated copies (19-36) give other orientations, and each is sized to its
  blood (`cl_crbdata.lua`) with 10 % squash
* only the main stream keeps one small wet PhysBlood stain (under 1 u) in the middle, which can run and dry
* the spatter patterns' big drops are not laid, nor the satellite drops
* the forward cone from the exit throws a third of its drops, none over 0.6 u
* at most 16 splats at once, then 10 a second (a magazine into a crowd does not churn the engine's decal list)

Measured offline with a wall 1.3 m behind the body: a rifle exit used to leave 67 wet stains on it; now 3 splats and 1
small wet stain. The flying 3D drops (the physics) are unchanged.

**Every blood type gets the same splats in its own colour** (yellow: antlions and aliens; green: acid; zombie; synth;
robot oil). The splat shader (DecalModulate) has no colour setting, so `tools/make_crb_types.py` makes recoloured copies:
per texel it fits the thickness of blood from the red texel with PhysBlood's own red absorption bands, puts the same
thickness of the other blood through that type's bands (the colour PhysBlood gives its stains and drops), and keeps the
shape (alpha), the neutral grey, the resolution (1024 px), the format and the mipmaps. Each type has 10 of the 18
patterns (the ones with the most blood): `crb/t<type>_bp<n>`, 50 textures, 62 MB. They land on the world and on props;
blood landing on bodies keeps the PhysBlood stains. Thick drops shade dark the way thick blood of that colour does.

With the new setting off, gunshots lay the earlier mix: one splat with the bigger drops of one of 18 patterns measured
from the CRB decals (`cl_spatterdata.lua`), turned, mirrored and scaled at random.

**Smaller and fewer** (applies to the PhysBlood drops: other blood types, splats off):

| Setting | Before | Now |
|---|---|---|
| Spatter size, pistol / magnum / rifle / sniper / buckshot | 9 / 13 / 14 / 22 / 6 u | 6 / 8 / 9 / 14 / 4 u |
| Streams per exit | 9 / 13 / 15 / 22 / 3 | 6 / 9 / 10 / 15 / 2 |
| Biggest stains | | about a third smaller |
| Headshot bonus | 30 % | 10 % |
| Forward cone mist | blotches up to 6 cm, 4-14 of them | drops up to 2 cm, 3-9 of them |

## Splats no longer vanish

Engine decals are limited: the game keeps only so many (`mp_decals`, 200 in multiplayer; `r_decals` in single player)
and also removes a decal when newer ones cover it, so the splats disappeared while the shooting went on. On the world,
PhysBlood now draws the splats itself (`cl_splatmesh.lua`, both renderers):
* the same textures, drawn with the Modulate shader (the wall times twice the texture, no change where the texture is
  clear - what DecalModulate does), so they look the same as the decals
* laid in a 6 x 6 grid of cells that each follow the surface; cells where the surface ends (edges, corners, steps) are
  left out, so a splat does not hang in the air
* they stay until **Splats kept** (`ghmpb_splats_kept`, default 3000, up to 30000) is used up, the oldest going first;
  `ghmpb_clear` removes them, `ghmpb_splats_info` tells how many there are
* as meshes they can turn: along the way the blood travelled (stretched up to 2x at a glancing hit), else at any angle,
  and mirrored
* on props and doors (they move) the splats stay engine decals
* **Draw the Crisis Response splats myself** (`ghmpb_splat_mesh`, on) switches it; off = engine decals

## Lite mode: pools and more stains

**Pools** (`cl_lite.lua`) are an outline that grows instead of one round texture:
* 24 directions from where the blood landed, each with its own radius; the volume sets the area (about 1.6 mm deep)
* each direction is felt ahead with traces: where the floor ends (a ledge, a step) or a wall or prop stands in the way,
  it stops at that spot (found to a few tenths of a unit), and the blood goes round it - pools fill corners and run
  along walls with a straight edge
* each pool a different shape: a few broad lobes and finer unevenness; on a tilted floor it runs downhill (on a 14
  degree floor, 9 u down against 6 u up in the test)
* pools whose outlines touch join into one outline
* drawn as rings from the middle to a soft edge, darker where the blood is deep, with the wet shine
* drying: the rim goes first and turns darker (the ring dried blood leaves), the shine fades from the edge in
* drops landing in a pool make ripples
* new textures (uncompressed): `lite/pool.vtf` (512 px surface detail), `lite/ripple.vtf`, materials `pool_mod`,
  `pool_shine`, `ripple` (`tools/make_lite_pool.py`)

**More stains kept:** "Lite: stains kept" defaults to 8000 (was 3000, players still at 3000 get 8000 once) and goes up
to 50000.

## Z-City

Checked against your Z-City gamemode (Workshop 3657285193; read only, nothing copied). Its player models
(`models/zcity/m|f/...`, clothes as sub-materials on the body) take the blood the same way in shader and Lite mode: the
shader blood is drawn on a copy of the body's own model that follows its bones, the Lite blood as engine decals on the
body; when a player is knocked down, the blood moves onto his ragdoll and back, and onto the corpse when he dies (all as
before). New for this build:
* **Its ammunition:** Z-City's round names are recognised where the general patterns got them wrong or missed them:
  7.62x25 and .22 Long Rifle are pistol rounds (not rifle), 9x18, 9x17, 7.65x17, .40 S&W, 4.6x30, 5.7x28 and .38 Special
  pistol, .50 Action Express magnum, 9x39, .366 TKM and 12.7x55 rifle, 14.5x114 and 12.7x108 sniper, 23x75 and 20/70
  shotgun. The less-lethal rounds (beanbag, rubber, flash, traumatic, tranquilizer darts) are club damage in Z-City and
  make no gunshot spatter.
* **A knocked-down player no longer catches his own spray:** the spray traces skip the player, his ragdoll and his
  corpse, not only the body that was hit (the invisible player stands where his ragdoll lies).
* **Z-City's own blood messages** (impacts and gibs, which carry only a position) now take the blood type of the nearest
  body, so an antlion or a zombie hit in Z-City bleeds its own colour instead of red.

**Lite mode** (the players without the shader pack):
* Every drop lands as one of your droplet shapes (`effects/droplets` drop7, drop2, drop11, drop3, drop1; drop5 and drop4
  for oblique hits). Before, it landed as a whole splash texture, which made each little drop a big splat and showed only 3
  shapes.
* Each drop gets a random shape, angle and squash.
* The mist is a CRB spatter decal crop. Body splats use drop7, and the body mist uses a CRB decal crop.
* Its textures are uncompressed (BGRA8888, as PhysBlood's own were in 1.26.6) and at the resolution their source has:
  the body mist is the CRB splat at its full 1024 px (`$decalscale` 0.00390625, the same size on the body).

**Settings:**
* New: "Fine gunshot spray from the Crisis Response Blood decals" (`ghmpb_crb_decals`, on).
* New: "gunshot spatter as Crisis Response splats instead of big drops" (`ghmpb_crb_splats`, on; needs the one above).
* `ghmpb_clear` now also clears these decals (it runs `r_cleardecals`).

**Not touched, as asked:** your streak decals (`decals/streaks`) and wound/flesh decals (`decals/flesh`); PhysBlood's own
streak/run textures (`bdrip`, run and bead cells) and wound textures (`bwound`); pools, smears, footprints. The CRB
archive's own droplet textures are 8x8 placeholders, so the droplet shapes come from your Next Gen Blood copy (same
names).

## Streams (how your blood mod does them, brought in)

Your mod (`bloodstream.lua`, `d4_dmg_k8.lua`) gives every bullet wound a few delayed spurts, anchored to the bone so they
carry on on the ragdoll, and a continuous stream from the wound. PhysBlood only had arterial jets, drawn as separate
drops. New:

* **Spurts after a gunshot** (`ghmpb_spurts`, 0-3, default 1):
  * 1-5 short gushes from the wound for a hit of 10+ damage (damage / 15, as in your mod).
  * The first comes 0.1-0.4 s after the hit, then one every 0.5-1.5 s.
  * Each is about 0.35-0.8 ml in 0.14-0.26 s, as drops at 150-250 u/s.
  * Direction: out of the exit wound along the bullet's path when it went through, otherwise out of the entry wound back
    towards the shooter. This is mixed 60:40 with the way the wound faces, plus the body's movement, and never into the
    body.
  * Spurts follow the bone and carry on on the ragdoll. A new hit moves them to the newest wound (at most 10 waiting).
  * No spurts from shooting a corpse. They also follow the Arterial spurting switch, and Z-City bandages stop them.
* **Continuous 3D streams** (`ghmpb_streams`, default on, new file `cl_streams.lua`):
  * Arterial jets, death geysers, spurts and fast-pouring wounds are drawn as one stream from the wound: a tube in the
    same wet fluid material as the VAT bursts.
  * It follows the moving wound every frame and falls under gravity.
  * It ripples and thins along its length, then breaks up into the drops after 0.07-0.24 s of flight. The drops do the
    stains and pools; the stream takes no blood itself.
  * When the feed stops (between heartbeats, after a spurt) it comes loose and flies off as one piece.
  * Limits: at most 14 streams of 26 samples.
* Menu: Fluid bursts tab, "Continuous 3D streams" and "Spurts after a gunshot".

## Files

Lua:
* `autorun/ghm_physblood.lua` (1.26.7, loads `cl_streams.lua` and `cl_crbdata.lua`)
* `cl_crbdata.lua` (new)
* `cl_crbtypes.lua` (new: which recoloured splats each blood type has)
* `cl_splatmesh.lua` (new: the splats PhysBlood draws on the world)
* `cl_streams.lua` (new)
* `cl_wounds.lua`
* `cl_vat.lua`
* `sh_config.lua` (Lite stains kept 8000, settings step 1268)
* `cl_spatterdata.lua`
* `cl_lite.lua` (pools as growing outlines, ripples)
* `cl_menu.lua`
* `cl_render.lua` (draws and clears the splat meshes)
* `cl_zcity.lua` (Z-City's blood messages in the right blood type)
* `cl_forensic.lua` (the CRB spray decal, the new spatter, smaller gunshot numbers)

Materials:
* `crb/bp1-36.vtf` and `crb/bp1-36.vmt` (new: your splat decals, copied, 47 MB)
* `lite/stains.vtf`
* `lite/bsplat.vtf`
* `lite/bmist.vtf`
* `lite/bsplat_0-3.vmt`
* `lite/bmist_0-3.vmt` (`$decalscale` 0.015625)

* `crb/t1-5_bp*.vtf/.vmt` (new: the splats recoloured for the other blood types, 62 MB)
* `lite/stains.vtf`, `bsplat.vtf`, `bmist.vtf` uncompressed again (bmist at 1024 px)
* `lite/pool.vtf`, `lite/ripple.vtf`, `pool_mod.vmt`, `pool_shine.vmt`, `ripple.vmt` (new: the Lite pools)

The GMA is 147.0 MB (about 20 MB compressed, as the Workshop sends it: the splats are mostly empty and pack small). It
came to your PC in six parts (`.gma.part1-6`, the transfer takes files up to 30 MB); `Publish_PhysBlood_1.26.7.bat`
joins them, checks the size, then uploads.

Tools: `tools/make_crb_decals.py`, `tools/make_crb_types.py`, `tools/make_lite_pool.py`, `tools/make_crb_spatter.py` (`CRB_SET=bloodplace`), `tools/make_crb_lite.py`.
Patch: `patches/1267_lua_vmt.diff`.
Tests: `test_client_streams.lua` (26 checks), `test_client_vat1267.lua` (12 checks).

**No new shader pack.** Only Lua and materials changed, and the materials ship in the GMA.

## Checked

* All 55 Lua files compile.
* Full offline suite: every existing test gives the same result as on 1.26.6 (the same known mock failures), and the two
  new test files pass.
* Updated tests:
  * ballistics (59 checks): 18 patterns, 36 decals, sized to the spatter, 21 different decals in 30 hits; splats: at
    most one small wet stain per exit, 2/3/3/4/1 splats, sizes, the PhysBlood drops again with the setting off; every
    other blood type its own recoloured splats; splats on the world and props, none on bodies; the cone thinned; the
    decal throttle
  * Z-City (27 checks): the new ammunition names, the body filter, impacts in the nearby body's blood type
  * splat meshes (new, 21 checks): all cells on open floor, the Modulate material with the CRB texture, on the surface,
    cells over a ledge left out, stretched along a glancing hit, on a wall, nothing in the air, the budget (oldest
    first), drawn, baked, cleared; world hits go to the meshes, props keep engine decals, the setting off = decals
  * Lite (10 new checks): pools stop at a ledge and grow away from it to full size, uneven outlines, along a wall, downhill
    on a tilted floor, drawn as meshes with shine, ripples
  * wet: the same checks with fewer drops
  * oldblood: config version 1267
* Preview images of the decals, the Lite atlas, a pistol and a rifle exit's splats on a wall, and the recoloured splats
  of every blood type on a light and a dark wall, and Lite pools (free, by a wall, two side by side) wet, drying
  and dry.
* This build (splats, original textures) is not yet tested in game. Your test of the first build found the black edges and the dense big drops.
