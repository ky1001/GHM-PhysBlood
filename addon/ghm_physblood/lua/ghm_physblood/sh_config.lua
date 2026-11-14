GHMPB = GHMPB or {}
local G = GHMPB

G.UNITS_TO_CM = 1.905
G.CM_TO_UNITS = 1 / 1.905
G.MM_TO_UNITS = 1 / 19.05
G.LIVE_RANGE = 9000

G.cv_sv_enable = CreateConVar("ghmpb_sv_enable", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED }, "GHM PhysBlood: master switch (server)")
G.cv_sv_suppress = CreateConVar("ghmpb_sv_suppress_default", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: disable the engine's own blood particles/decals on NPCs so only simulated blood is used")
G.cv_sv_bleed = CreateConVar("ghmpb_sv_bleed_scale", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED }, "GHM PhysBlood: bleeding amount multiplier", 0, 5)
G.cv_sv_players = CreateConVar("ghmpb_sv_players", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED }, "GHM PhysBlood: players bleed too")
G.cv_sv_physmin = CreateConVar("ghmpb_sv_physics_min", "20", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: minimum physics / crush damage that makes a body bleed (corpses need twice as much)", 0, 1000)
G.cv_sv_physcd = CreateConVar("ghmpb_sv_physics_cooldown", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: seconds between physics-impact bleeds on the same body", 0, 30)
G.cv_sv_physrate = CreateConVar("ghmpb_sv_physics_rate", "15", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: max physics-impact bleeds per second on the whole server", 1, 200)
G.cv_sv_hitrate = CreateConVar("ghmpb_sv_hit_rate", "120", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: max blood hit messages per second on the whole server (all damage)", 10, 1000)

G.cv_sv_elem = CreateConVar("ghmpb_sv_elements", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: blood reacts to fire, cold, electricity, lasers, acid, energy balls and blasts (the server sends them, wet blood conducts)", 0, 1)
G.cv_sv_elecdmg = CreateConVar("ghmpb_sv_elec_damage", "12", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: shock damage to an NPC or player standing in wet blood that electricity runs through (0 = arcs only)", 0, 200)
G.cv_sv_elecrange = CreateConVar("ghmpb_sv_elec_range", "700", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: how far (units) electricity runs through connected wet blood", 50, 4000)
G.cv_sv_wettime = CreateConVar("ghmpb_sv_wet_time", "240", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: seconds a pool of blood stays wet (conducts) on the server; small stains and spatter less, big pools more", 10, 3600)
G.EL = { HEAT = 1, COLD = 2, ELEC = 3, LASER = 4, ACID = 5, DISSOLVE = 6, WAVE = 7, RAD = 8, PLASMA = 9, HOT = 10, DUST = 11 }
G.EL_NAMES = { "heat", "cold", "electricity", "laser", "acid", "dissolve", "shock wave", "radiation", "plasma", "hot metal", "blast dust" }
G.ACID_TYPE = 2

G.Diag = G.Diag or { c = {} }
function G.DiagCount(name) local c = G.Diag.c c[name] = (c[name] or 0) + 1 end

function G.ScenePass(depth, sky, sky3d)
	return not depth and not sky3d
end

function G.IsPhysicsDamage(dmgtype)
	return bit.band(dmgtype or 0, bit.bor(DMG_CRUSH, DMG_PHYSGUN, DMG_VEHICLE, DMG_FALL)) ~= 0
		and bit.band(dmgtype or 0, bit.bor(DMG_BULLET, DMG_SLASH, DMG_BUCKSHOT, DMG_BLAST)) == 0
end

local BLOODLESS = bit.bor(DMG_BURN, DMG_SLOWBURN, DMG_PLASMA or 0, DMG_SHOCK, DMG_DROWN, DMG_DROWNRECOVER or 0, DMG_POISON,
	DMG_NERVEGAS, DMG_RADIATION, DMG_ACID, DMG_PARALYZE, DMG_DISSOLVE)
local WOUNDING = bit.bor(DMG_BULLET, DMG_SLASH, DMG_CLUB, DMG_BLAST, DMG_BLAST_SURFACE or 0, DMG_BUCKSHOT, DMG_SNIPER or 0,
	DMG_AIRBOAT, DMG_CRUSH, DMG_FALL, DMG_VEHICLE, DMG_PHYSGUN, DMG_ALWAYSGIB, DMG_SONIC, DMG_MISSILEDEFENSE or 0)
function G.IsBloodlessDamage(dmgtype)
	dmgtype = dmgtype or 0
	return bit.band(dmgtype, BLOODLESS) ~= 0 and bit.band(dmgtype, WOUNDING) == 0
end

local TICK_OK = bit.bor(DMG_DIRECT or 0, DMG_PREVENT_PHYSICS_FORCE or 0, DMG_NEVERGIB or 0)
function G.IsDotTick(dmg)
	local t = dmg:GetDamageType() or 0
	if bit.band(t, bit.bnot(TICK_OK)) ~= 0 then return false end
	local f = dmg:GetDamageForce()
	return (dmg:GetDamage() or 0) <= 2 and (not f or f:LengthSqr() < 1)
end

if CLIENT then
	local function C(name, def, help, mn, mx)
		return CreateClientConVar(name, def, true, false, help, mn, mx)
	end
	G.cv = {
		-- (1.26.8) sent to the server (user info): with Z-City it sends Z-City's own blood effects to the players who
		-- switched PhysBlood off
		enable       = CreateClientConVar("ghmpb_enable", "1", true, true, "GHM PhysBlood: client master switch", 0, 1),
		rendermode   = C("ghmpb_render_mode", "0", "Renderer: 0 automatic (the shaders when their files are installed, else lite), 1 shaders, 2 lite (no custom shaders: stains, pools, decals and sprites)", 0, 2),
		litemax      = C("ghmpb_lite_stains", "8000", "Lite renderer: how many stains stay on the world (the oldest go first)", 200, 50000),
		-- (1.26.8) GHM: "make it that it shows the best blood system out of the box, let players tweak it in settings
		-- themselves" - the defaults are the Ultra preset, and the automatic tuning (adaptive quality, the size of the fight)
		-- is off by default
		quality      = C("ghmpb_quality", "4", "Cell resolution: 1 low, 2 medium, 3 high, 4 ultra", 1, 4),
		smooth       = C("ghmpb_smooth", "2", "Blood edge smoothing: 0 raw cells, 1 bicubic + anti-aliased, 2 + organic edges", 0, 2),
		simhz        = C("ghmpb_sim_hz", "45", "Cell simulation steps per second", 10, 60),
		maxents      = C("ghmpb_max_entities", "8", "Max bleeding models simulated at once", 1, 32),
		perfadapt    = C("ghmpb_perf_adaptive", "0", "Hold the frame rate: far, hidden and settled blood loses detail first when frames get slow (off by default: full quality)", 0, 1),
		perffps      = C("ghmpb_perf_target_fps", "60", "Frame rate the adaptive quality aims for", 20, 240),
		maxpatches   = C("ghmpb_max_patches", "32", "Max live world cells (stains / pools being simulated)", 4, 128),
		maxdrops     = C("ghmpb_max_particles", "4000", "Max flying droplets", 100, 6000),
		native       = C("ghmpb_native", "1", "Use the C++ droplet solver module if installed", 0, 1),
		vram         = C("ghmpb_vram_mb", "2048", "Video memory the blood may use (MB). Limits are lowered automatically to fit", 256, 16384),
		absorb       = C("ghmpb_density", "3.53", "Optical density of blood (higher = darker, more opaque)", 0.2, 4),
		gloss        = C("ghmpb_gloss", "1", "Gloss: how sharp the shine of wet blood is (higher = a crisper mirror, lower = a softer sheen)", 0.2, 3),
		normaldepth  = C("ghmpb_normal_depth", "1.6", "Strength of the film relief (dynamic normals)", 0, 6),
		reflect      = C("ghmpb_reflections", "1", "Shine: strength of the reflections and highlights on blood (1 = physically correct)", 0, 3),
		surfaceenh   = C("ghmpb_surface_enhanced", "1", "Enhanced two-pass world blood surface shader (liquid-lens meniscus refraction, sun/flashlight rim caustics, dual-scale ripples, 3D bubble domes, full world meniscus glints and 6-step SSR; 0 = classic single-pass surface shader)", 0, 1),
		poollook     = C("ghmpb_pool_look", "1", "Wetness: how wet fresh blood looks (1 = physical; higher = even thin smears read as liquid, lower = tacky and dull)", 0, 2),
		freshwet     = C("ghmpb_fresh_wet", "2.5", "Fresh blood wetness: how much wetter blood looks while it is fresh - it shines more (4x at 2.5) and thin films, splatter and runs read as liquid, until the blood gels (1 = only the Wetness and Shine settings)", 1, 3),
		froth        = C("ghmpb_froth", "1", "Froth on fresh blood: lung blood, bright spurts and hard impacts bring bubbles that float with the pool and burst over a minute (0 = none)", 0, 2),
		screen       = C("ghmpb_screen", "1", "Blood on your screen: drops and close spatter that reach your view stick to it, run down and fade; a lot of blood turns into a thick layer you cannot see through (multiplier, 0 = off)", 0, 2),
		screenfade   = C("ghmpb_screen_fade", "14", "Blood on your screen: seconds until it has dried and faded away", 3, 60),
		screenblur   = C("ghmpb_screen_blur", "1", "Blood on your screen: how out of focus it looks. Your eye focuses past a drop sitting right on the lens, so it reads as a soft blur while the world behind it stays sharp (0 = sharp)", 0, 3),
		vmblood      = C("ghmpb_vm_blood", "1", "Blood from close hits on your first-person hands and weapon (0 = off)", 0, 1),
		vmfade       = C("ghmpb_vm_fade", "0", "Blood on your first-person hands and weapon: 0 = it dries and stays until you die, otherwise seconds until it wears off", 0, 600),
		holes        = C("ghmpb_holes", "1", "Bullet holes on bodies: an entry hole where a round went in, an exit hole where it came out (size multiplier, 0 = none). Off by itself while GHM FLESH draws its own wounds", 0, 2),
		ripples      = C("ghmpb_pool_ripples", "1", "Drops landing in a wet pool send a ring wave through it, and blood welling into a pool from a body stirs its surface (multiplier, 0 = none)", 0, 3),
		slide        = C("ghmpb_drop_slide", "1", "Fast drops: part of a fast, flat drop skids on as a droplet that ends in a bead (0 = off, 1 = short skids, 2 = long thin rivulets - the 1.19 look)", 0, 2),
		-- (1.26.8) off by default: the probes' extra views made the engine's shadows of bodies lying in the blood flicker
		reflprobes   = C("ghmpb_reflect_probes", "0", "Reflection probes: how many groups of blood get a live reflection of what stands round them (rendered views, refreshed while you play; 0 = the map's cubemap only)", 0, 6),
		reflbudget   = C("ghmpb_reflect_budget", "20", "Reflection probes: milliseconds a second they may spend rendering their views (higher = they keep up faster with what moves)", 2, 200),
		maplights    = C("ghmpb_map_lights", "1", "Highlights on wet blood from the lamps of the map, dynamic lights, projected textures and other players' flashlights", 0, 1),
		streak       = C("ghmpb_streak_max", "3.5", "Longest a drop stain gets (length / width): flat, fast hits leave longer stains up to this (10 = no limit, the old long streaks)", 1.5, 10),
		-- (1.26.10) GHM's colours are the defaults (fresh brightness 3, was 2.55; the rest were his already). Each player is
		-- asked once, on the first start, whether to take them or to set their own (cl_menu.lua M.ColourChoice)
		colFresh     = C("ghmpb_color_fresh", "3", "Brightness of fresh (wet) blood: higher = lighter, redder; lower = darker", 0.3, 3),
		colDry       = C("ghmpb_color_dry", "0.9", "Brightness of dried / old blood, and how dark wet blood turns as it clots and ages: higher = lighter rust-brown; lower = darker, blacker", 0.3, 3),
		colHue       = C("ghmpb_color_hue", "0", "Blood hue: + towards orange-scarlet, - towards deep crimson / purple", -1, 1),
		-- (1.26.6) the player's own colours for red blood (Look > Your own blood colours)
		colCustom    = C("ghmpb_color_custom", "1", "Use your own blood colours (ghmpb_color_blood / ghmpb_color_dense) for red blood", 0, 1),
		colBlood     = C("ghmpb_color_blood", "255 10 0", "Your blood colour: a thin film of fresh blood on a light floor, \"R G B\" 0-255"),
		colDense     = C("ghmpb_color_dense", "171 9 0", "Your dense blood colour: a deep pool, \"R G B\" 0-255"),
		thickness    = C("ghmpb_thickness", "1.6", "How thick blood stays before it spreads (surface pinning)", 0.5, 4),
		viscosity    = C("ghmpb_viscosity", "1", "Blood viscosity multiplier (higher = slower runs)", 0.3, 4),
		coag         = C("ghmpb_coagulation", "1", "Blood coagulates (clots, stops flowing, darkens)", 0, 1),
		-- (1.26.8) GHM's drying settings are the defaults (clotting 535 s, drying 1816 s, soaking 0.28, fresh blood soaks in
		-- slowly 1.46; they were 180 / 240 / 1 / 1): blood stays wet, glossy and liquid much longer. The ranges go further
		-- so the "Cold and damp" conditions keep their place relative to them
		coagtime     = C("ghmpb_coag_time", "535", "Seconds until spilled blood is mostly clotted", 15, 1800),
		drytime      = C("ghmpb_drytime", "1816", "Seconds for thin wet blood to dry into stain (thick pools take longer)", 20, 7200),
		timelapse    = C("ghmpb_timelapse", "1", "Time-lapse: drying, clotting and the ageing of dried blood run this many times faster (1 = real time; 10 = ten minutes of drying in one)", 1, 30),
		drybody      = C("ghmpb_dry_bodies", "1", "Drying speed of blood on bodies - skin and clothes (multiplier)", 0.1, 5),
		dryporous    = C("ghmpb_dry_porous", "1", "Drying speed on porous surfaces - concrete, brick, plaster, wood, soil, sand, gravel, grass, carpet, paper (multiplier)", 0.1, 5),
		drysealed    = C("ghmpb_dry_sealed", "1", "Drying speed on sealed surfaces - tile, paint, metal, glass, rubber, stone, grates (multiplier)", 0.1, 5),
		drycold      = C("ghmpb_dry_cold", "1", "Drying speed on ice and snow (multiplier; they already keep blood wet about twice as long)", 0.1, 5),
		soakdelay    = C("ghmpb_soak_delay", "1.46", "Fresh blood soaks in slowly: porous ground takes up only a little of a fresh pool's edge at first and more and more as the blood ages through clotting (multiplier of that delay; 0 = full rate at once, the 1.26.0 look)", 0, 3),
		soak         = C("ghmpb_soak_speed", "0.28", "How fast porous surfaces and clothes drink blood in (multiplier, 0 = nothing soaks in)", 0, 4),
		crust        = C("ghmpb_dry_crust", "0.6", "How much the skin of clotted blood slows the drying of the blood under it (0 = not at all, 0.95 = clotted pools stay wet underneath for a long time)", 0, 0.95),
		motion       = C("ghmpb_motion", "1", "How much body motion pushes blood around (0..1)", 0, 1),
		surfbump     = C("ghmpb_surface_normals", "1", "Thin blood and dried stains follow the normal map of the surface they lie on, and its grooves draw the blood along them (deep pools level it out)", 0, 1),
		uvmirror     = C("ghmpb_uv_mirror", "1", "Models whose legs / arms share one mirrored texture get separate blood for each side (1), or share it (0: the blood shows on both)", 0, 1),
		runs         = C("ghmpb_wall_runs", "1", "Runs on walls: how readily wet blood on walls and steep slopes runs down in rivulets (0 = off, higher = more runs)", 0, 4),
		runspeed     = C("ghmpb_run_speed", "1", "Speed of runs on walls (multiplier)", 0.25, 3),
		tendrils     = C("ghmpb_pool_tendrils", "1", "Pools on flat floors break out into thin, nearly straight streams that follow the fall of the floor and sometimes fork (0 = off, higher = more)", 0, 3),
		bleedtrail   = C("ghmpb_bleed_trail", "1", "Bleeders who keep moving leave a trail of drops on the ground, elongated in the direction of travel; arteries add a gush per heartbeat (0 = off)", 0, 3),
		blades       = C("ghmpb_blade_blood", "1", "Melee weapons carry blood: cast-off follows the real swing, and a bloody weapon drips along the way it is carried (0 = off)", 0, 3),
		water        = C("ghmpb_water", "1", "Blood in water: drops, wounds, runs and pools reaching water make clouds that spread and fade", 0, 1),
		wateramt     = C("ghmpb_water_amount", "1", "How strongly blood clouds in water show (multiplier)", 0.2, 4),
		watertime    = C("ghmpb_water_time", "90", "Longest time a blood cloud in water lasts (seconds)", 10, 600),
		waterwash    = C("ghmpb_water_wash", "1", "How fast blood on bodies and surfaces under water washes off into the water (0 = it stays)", 0, 3),
		smear        = C("ghmpb_smear", "1", "Bloody bodies leave smears where they slide or are dragged, and push / wipe pools", 0, 1),
		smearamt     = C("ghmpb_smear_amount", "1", "How much blood a sliding body leaves behind (multiplier)", 0, 3),
		pickup       = C("ghmpb_smear_pickup", "1", "Bodies moving through pools pick up blood (and carry it on)", 0, 1),
		castoff      = C("ghmpb_castoff", "1", "Blood flung off bloody weapons on the back swing (cast-off lines on ceilings / walls)", 0, 1),
		foot         = C("ghmpb_footprints", "1", "Characters walking through wet blood leave bloody footprints", 0, 1),
		footamt      = C("ghmpb_footprint_amount", "1", "How much blood each footprint leaves (multiplier)", 0, 3),
		footnpc      = C("ghmpb_footprint_npcs", "1", "NPCs leave footprints too (not only players)", 0, 1),
		hands        = C("ghmpb_hand_prints", "1", "Bloody hands leave hand prints on floors and walls, and finger streaks where they are dragged", 0, 1),
		handamt      = C("ghmpb_hand_amount", "1", "How much blood each hand print / finger streak leaves (multiplier)", 0, 3),
		props        = C("ghmpb_props", "1", "Props touch blood: they soak up or get bloody in pools, smear when dragged and splash when dropped in", 0, 1),
		propamt      = C("ghmpb_props_amount", "1", "How much blood props pick up and smear (multiplier)", 0, 3),
		tyres        = C("ghmpb_tyre_tracks", "1", "Vehicles leave tyre tracks and skid marks after driving through blood", 0, 1),
		tyreamt      = C("ghmpb_tyre_amount", "1", "How much blood tyres pick up and print (multiplier)", 0, 3),
		splash       = C("ghmpb_splash", "1", "Splashes when bodies, props or tyres hit pools (multiplier, 0 = none)", 0, 3),
		flesh        = C("ghmpb_flesh", "1", "GHM FLESH: limbs it cuts off bleed from the stump and keep their blood", 0, 1),
		fleshbleed   = C("ghmpb_flesh_bleed", "1", "GHM FLESH: how much a stump bleeds (multiplier)", 0, 3),
		physblood    = C("ghmpb_physics_blood", "1", "Blood from physics impacts: thrown, dropped or colliding bodies (multiplier, 0 = none)", 0, 3),
		physcd       = C("ghmpb_physics_cooldown", "1", "Seconds between physics-impact bleeds on the same body", 0.1, 10),
		unevenness   = C("ghmpb_floor_unevenness", "1", "Micro relief of floors and walls (a few mm): pools on floors fill its shallow dips and worn grooves and grow lobes, bays and dry islands; runs on walls meander (0 = perfectly flat, round pools)", 0, 3),
		poolsize     = C("ghmpb_pool_size", "1", "How much blood a dying body loses into its pool (multiplier)", 0, 5),
		bloodvol     = C("ghmpb_blood_volume", "4000", "Blood a human body can lose in total (ml); other creatures scale with their size", 500, 20000),
		corpsebleed  = C("ghmpb_corpse_bleed_time", "180", "Seconds after death a body can still bleed (fully for the first 30 s, then less and less)", 10, 3600),
		aftermath    = C("ghmpb_aftermath", "1", "Keep settled blood in a cheap static aftermath layer", 0, 1),
		forever      = C("ghmpb_keep_forever", "0", "Aftermath never fades (only map cleanup / the cap removes it)", 0, 1),
		aftfade      = C("ghmpb_aftermath_fade", "20", "Minutes before aftermath blood fades out (if not kept forever)", 1, 600),
		aftmax       = C("ghmpb_aftermath_max", "800", "Max aftermath world patches (76 x 76 cm each)", 16, 4096),
		aftbodies    = C("ghmpb_aftermath_bodies", "48", "Max bodies keeping baked blood", 4, 256),
		aftres       = C("ghmpb_aftermath_res", "256", "Aftermath world patch resolution (128 / 256 / 512)", 128, 512),
		settle       = C("ghmpb_settle_time", "25", "Seconds of no new blood before a world patch settles into the aftermath layer", 5, 600),
		spray        = C("ghmpb_spray", "1", "Droplet spray amount multiplier (all sprays)", 0, 4),
		style        = CreateClientConVar("ghmpb_splatter_style", "realistic", true, false, "Last applied splatter style (display only)"),
		sEntry       = C("ghmpb_splat_entry", "1", "Entry wound back-spatter (multiplier)", 0, 6),
		sExit        = C("ghmpb_splat_exit", "1", "Exit wound spray (multiplier)", 0, 6),
		sMelee       = C("ghmpb_splat_melee", "1", "Blade / blunt melee spray, flung along the swing (multiplier)", 0, 6),
		sKill        = C("ghmpb_splat_kill", "0", "Extra burst on the killing blow (multiplier)", 0, 6),
		sRadial      = C("ghmpb_splat_radial", "1", "Hits close to the floor (a body lying down, a head on the ground): a ring of small streaks thrown out low along the floor, all pointing away from the hit (multiplier)", 0, 6),
		sBlast       = C("ghmpb_splat_blast", "1", "Explosions: the directional burst of blood thrown away from the blast (multiplier)", 0, 6),
		sWound       = C("ghmpb_splat_wound", "1", "Blood painted on the body around each wound (multiplier)", 0, 5),
		sSize        = C("ghmpb_splat_size", "1", "Droplet size (multiplier)", 0.3, 3),
		sSpeed       = C("ghmpb_splat_speed", "1", "Droplet speed / throw distance (multiplier)", 0.25, 3),
		sSpread      = C("ghmpb_splat_spread", "1", "Spray cone width (multiplier)", 0.3, 3),
		sArtery      = C("ghmpb_arterial_strength", "1", "Arterial jet flow and height (multiplier)", 0, 6),
		geyser       = C("ghmpb_geyser", "0", "Samurai-film blood fountain from fatal neck / head / torso wounds", 0, 1),
		bleed        = C("ghmpb_bleed", "1", "Client bleeding amount multiplier", 0, 5),
		pools        = C("ghmpb_pools", "1", "Allow blood pools / world stains", 0, 1),
		elements     = C("ghmpb_elements", "1", "Blood reacts to fire (boils, dries, chars), cold (freezes, steams), electricity (arcs), lasers, acid, energy balls and blasts", 0, 1),
		elemsteam    = C("ghmpb_elem_steam", "1", "Steam from fresh blood in the cold and from boiling blood; smoke from charring", 0, 1),
		freeze       = C("ghmpb_freeze", "1", "Blood freezes on ice and snow, and outdoors in sub-zero weather (StormFox 2)", 0, 1),
		flies        = C("ghmpb_flies", "1", "Flies come to pools of blood and to the dead (outdoors and in the warm; none in the cold)", 0, 1),
		fliesamt     = C("ghmpb_flies_amount", "1", "How many flies come (multiplier)", 0, 3),
		fliesmax     = C("ghmpb_flies_max", "80", "Most flies simulated at once", 0, 400),
		fliessnd     = C("ghmpb_flies_sound", "1", "The buzz of flies near you", 0, 1),
		blastdust    = C("ghmpb_blast_dust", "1", "Explosions kick up dust from the ground (sand, snow, soil, concrete, plaster...) that sticks to fresh blood", 0, 1),
		matlook      = C("ghmpb_material_look", "1", "Blood looks different on each surface (soaked-in stains, halos on porous ground, grain on sand / gravel / grass / carpet, snow and ice sparkle)", 0, 1),
		nodecals     = C("ghmpb_remove_engine_decals", "1", "Remove the engine's blood decals (bullet splats) from bodies the mod bleeds, while the server replaces the engine's blood", 0, 1),
		mist         = C("ghmpb_mist", "1", "Blood mist puffs on impacts", 0, 1),
		bounce       = C("ghmpb_drop_bounce", "1", "Drops that hit at a grazing angle skip on (ricochet streaks) and fast splashes throw secondary droplets", 0, 1),
		trail        = C("ghmpb_drop_trail", "1", "Length of the motion trail of flying drops (0 = none, 1 = camera shutter)", 0, 2),
		hang         = C("ghmpb_drop_hang", "1", "Blood gathers into hanging drops that swell and drip (chins, noses, ledges, ceilings)", 0, 1),
		facebleed    = C("ghmpb_face_bleed", "1", "Nose / mouth / ear bleeding from head, neck and chest trauma", 0, 1),
		arterial     = C("ghmpb_arterial", "1", "Arterial spurting from hit arteries", 0, 1),
		cough        = C("ghmpb_cough", "1", "Coughing blood after chest / neck wounds", 0, 1),
		dbgview      = C("ghmpb_debug_view", "0", "Shading debug view: 0 off, 1 thickness, 2 without reflections / highlights, 3 reflections / highlights only, 4 layer reflectance", 0, 4),
		debug        = C("ghmpb_debug", "0", "Debug overlay (1 = stats, 2 = cell viewer, 3 = thickness colours)", 0, 3),
	}
	local cfgver = CreateClientConVar("ghmpb_config_version", "0", true, false, "GHM PhysBlood: internal (settings migration)")
	if cfgver:GetInt() < 1120 then
		if math.abs(G.cv.coagtime:GetFloat() - 90) < 0.01 then G.cv.coagtime:SetFloat(180) end
		cfgver:SetInt(1120)
	end
	-- (1.26.6) new default blood colours (GHM's): players whose colour settings are still at the old defaults get them
	-- (cl_vat.lua does the same for the burst colours and the number of bursts on screen)
	if cfgver:GetInt() < 1266 then
		local cv = G.cv
		local function Near(c, v) return math.abs(c:GetFloat() - v) < 1e-3 end
		if Near(cv.colFresh, 1) and Near(cv.colDry, 1) and Near(cv.absorb, 1) and Near(cv.colHue, 0) and not cv.colCustom:GetBool()
			and (cv.colBlood:GetString() == "159 13 7" or cv.colBlood:GetString() == "") and (cv.colDense:GetString() == "97 12 7" or cv.colDense:GetString() == "") then
			for _, c in ipairs({ cv.colFresh, cv.colDry, cv.absorb, cv.colCustom, cv.colBlood, cv.colDense }) do c:SetString(c:GetDefault()) end
		end
		G.migrate1266 = true
		cfgver:SetInt(1266)
	end
	-- (1.26.7) the 1.26.2 physics back: the 3D fluid drops are on again (cl_vat.lua turns them on once for 1.26.6 players)
	if cfgver:GetInt() < 1267 then
		G.migrate1267 = true
		cfgver:SetInt(1267)
	end
	-- (1.26.7, second build) Lite keeps more stains: 3000 -> 8000 for players still at the old default
	if cfgver:GetInt() < 1268 then
		if G.cv.litemax:GetInt() == 3000 then G.cv.litemax:SetInt(8000) end
		cfgver:SetInt(1268)
	end
	-- (1.26.8) GHM: "blood pools flicker when NPCs are on the blood pool" - the shadows of the bodies lying in it came and
	-- went: the reflection probes render extra views of the scene from the middle of the pool, before the main view, and
	-- the engine's shadows are worked out again for those views. The probes are off by default now (the pools reflect
	-- the map's cubemap); players still at the old default (2) get the new one
	if cfgver:GetInt() < 1269 then
		if G.cv.reflprobes:GetInt() == 2 then G.cv.reflprobes:SetInt(0) end
		cfgver:SetInt(1269)
	end
	-- (1.26.8) the best blood out of the box: players whose settings are all still at the old defaults (the Medium preset,
	-- 1 GB of video memory, adaptive quality on) get the Ultra preset, 2 GB and the automatic tuning off; anything a player
	-- set themselves stays (cl_battle.lua turns the fight-size tuning off the same way)
	if cfgver:GetInt() < 1270 then
		local cv = G.cv
		if cv.perfadapt:GetInt() == 1 then cv.perfadapt:SetInt(0) end
		if cv.quality:GetInt() == 2 and cv.simhz:GetInt() == 30 and cv.maxents:GetInt() == 12 and cv.maxpatches:GetInt() == 40
			and cv.maxdrops:GetInt() == 1400 and cv.aftmax:GetInt() == 400 then
			cv.quality:SetInt(4) cv.simhz:SetInt(45) cv.maxents:SetInt(8) cv.maxpatches:SetInt(32) cv.maxdrops:SetInt(4000)
			cv.aftmax:SetInt(800)
		end
		if cv.vram:GetInt() == 1024 then cv.vram:SetInt(2048) end
		G.migrate1270 = true
		cfgver:SetInt(1270)
	end
	-- (1.26.8) GHM's drying settings: players whose clotting, drying and soaking settings are all still at the old
	-- defaults (the old "Indoors") get the new ones; anyone who set them up themselves keeps theirs
	if cfgver:GetInt() < 1271 then
		local cv = G.cv
		local function Near(c, v) return math.abs(c:GetFloat() - v) < 1e-3 end
		if Near(cv.coagtime, 180) and Near(cv.drytime, 240) and Near(cv.soak, 1) and Near(cv.soakdelay, 1) then
			cv.coagtime:SetFloat(535) cv.drytime:SetFloat(1816) cv.soak:SetFloat(0.28) cv.soakdelay:SetFloat(1.46)
		end
		cfgver:SetInt(1271)
	end
	function G.SettleTime()
		local t = G.cv.settle:GetFloat()
		if G.cv.coag:GetBool() then t = math.max(t, G.CoagTime() * 0.5) end
		return t
	end
	-- (1.26.6) how long a pool of world blood stays live (wet, simulated) after blood last reached it: until it has nearly
	-- clotted - the aftermath layer draws settled blood clotted and dull, so a pool that settles earlier looks dry while it
	-- is still fresh. 90 % of the clotting time, at least half the drying time, at most 10 min (or "Settle after")
	function G.PoolSettleTime()
		local s = G.cv.settle:GetFloat()
		local t = math.max(s, G.DryTime() * 0.5)
		if G.cv.coag:GetBool() then t = math.max(t, G.CoagTime() * 0.9) end
		return math.min(t, math.max(s, 600))
	end
	-- (1.26.1) drying and clotting as the simulation runs them: the times set in the Drying tab, sped up by the
	-- time-lapse. Everything that waits for blood to dry or clot asks these (films, pools, aftermath ageing, soles,
	-- hands, props, weapons, pool streams, the lite renderer), so one setting moves all of it together.
	function G.DryTime()
		return math.max(G.cv.drytime:GetFloat(), 5) / math.Clamp(G.cv.timelapse:GetFloat(), 1, 30)
	end
	function G.CoagTime()
		return math.max(G.cv.coagtime:GetFloat(), 5) / math.Clamp(G.cv.timelapse:GetFloat(), 1, 30)
	end
	-- clotting time relative to 180 s (for the fixed clotting times of weapons and pool streams, which were tuned at the
	-- default of 1.26.7 and before: at the 1.26.8 default of 535 s they gel about three times later, as in GHM's test)
	function G.ClotScale() return G.CoagTime() / 180 end
	-- drying speed of each kind of surface (multiplier of 1 / drying time)
	G.DRY_GROUP = {
		skin = "drybody", cloth = "drybody",
		concrete = "dryporous", brick = "dryporous", plaster = "dryporous", wood = "dryporous", soil = "dryporous",
		sand = "dryporous", gravel = "dryporous", grass = "dryporous", carpet = "dryporous", paper = "dryporous",
		sealed = "drysealed", metal = "drysealed", glass = "drysealed", rubber = "drysealed", stone = "drysealed",
		grate = "drysealed",
		ice = "drycold", snow = "drycold",
	}
	local surfName
	-- kind: a surface name ("concrete") or its G.Surface table
	function G.DryMult(kind)
		if type(kind) == "table" then
			local n = surfName and surfName[kind]
			if not n then
				surfName = {}
				for k, v in pairs(G.Surface or {}) do surfName[v] = k end
				n = surfName[kind]
			end
			kind = n
		end
		local key = kind and G.DRY_GROUP[kind]
		local cv = key and G.cv[key]
		return cv and math.max(cv:GetFloat(), 0.05) or 1
	end
	function G.SoakMult() return math.max(G.cv.soak:GetFloat(), 0) end
	-- (1.26.1) how readily blood of a given age soaks into porous ground, 0.08 .. 1. Fresh blood is viscous and its cells
	-- clog the pores, so a fresh pool keeps a clean, glossy edge; as it ages through clotting (and serum separates from the
	-- retracting clot) the margin is drawn into the ground more and more: the soaked rim appears in the middle stages,
	-- smoothly. Ramps from 8 % to 45 % of the clotting time (x ghmpb_soak_delay), so it is complete before the blood
	-- settles (settling waits for half the clotting time). Snow, carpet and paper drink blood at once.
	G.SOAK_AT_ONCE = { snow = true, carpet = true, paper = true }
	function G.SoakRamp(kind, age)
		if G.SOAK_AT_ONCE[kind or ""] then return 1 end
		local d = G.cv.soakdelay:GetFloat()
		if d <= 0 then return 1 end
		local c = G.CoagTime() * d
		local x = math.Clamp((age - 0.14 * c) / (0.42 * c), 0, 1)
		return 0.015 + 0.985 * x * x * (3 - 2 * x)
	end
	-- how far a settled layer (aftermath patch / baked body) has dried since it settled, in drying times. Added up
	-- frame by frame, so a change of the settings (or the time-lapse) only changes how fast it goes on drying -
	-- stains that are already dry do not jump back or ahead.
	function G.DryAge(rec, mult)
		local now = CurTime()
		if not rec.bakedAt then return now / G.DryTime() end
		if rec.dryBase ~= rec.bakedAt then rec.dryBase, rec.dryAt, rec.dryAge = rec.bakedAt, rec.bakedAt, 0 end
		local dt = now - (rec.dryAt or now)
		if dt > 0 then
			rec.dryAge = (rec.dryAge or 0) + dt * (mult or 1) / G.DryTime()
			rec.dryAt = now
		end
		return rec.dryAge or 0
	end
	-- (1.26.1) conditions: starting points for the drying settings (Drying tab). Rough figures - warm, dry or moving air
	-- speeds evaporation; clotting is slower in the cold. (1.26.8) Indoors is GHM's settings, the new defaults; the
	-- others keep their 1.26.1 proportions to it (drying x7.57, clotting x2.97, soaking x0.28 of the old figures)
	G.DRY_ENVS = {
		{ id = "indoor", name = "Indoors", tip = "Room temperature (about 20 C), still air: the defaults",
		  cv = { ghmpb_drytime = 1816, ghmpb_coag_time = 535, ghmpb_dry_bodies = 1, ghmpb_dry_porous = 1, ghmpb_dry_sealed = 1,
		         ghmpb_dry_cold = 1, ghmpb_soak_speed = 0.28, ghmpb_soak_delay = 1.46, ghmpb_dry_crust = 0.6 } },
		{ id = "hot", name = "Hot and dry", tip = "A hot, dry room or summer sun (30-40 C, low humidity): blood dries about twice as fast and clots sooner",
		  cv = { ghmpb_drytime = 830, ghmpb_coag_time = 355, ghmpb_dry_bodies = 1.3, ghmpb_dry_porous = 1.2, ghmpb_dry_sealed = 1,
		         ghmpb_dry_cold = 1.5, ghmpb_soak_speed = 0.28, ghmpb_dry_crust = 0.7 } },
		{ id = "windy", name = "Outdoors, windy", tip = "Moving air carries the moisture away: thin blood dries fast and pools skin over",
		  cv = { ghmpb_drytime = 1135, ghmpb_coag_time = 505, ghmpb_dry_bodies = 1.2, ghmpb_dry_porous = 1.2, ghmpb_dry_sealed = 1,
		         ghmpb_dry_cold = 1.2, ghmpb_soak_speed = 0.28, ghmpb_dry_crust = 0.75 } },
		{ id = "cold", name = "Cold and damp", tip = "Cold, humid air (about 5 C): blood stays wet several times longer and clots slower",
		  cv = { ghmpb_drytime = 5450, ghmpb_coag_time = 950, ghmpb_dry_bodies = 0.8, ghmpb_dry_porous = 0.8, ghmpb_dry_sealed = 1,
		         ghmpb_dry_cold = 0.7, ghmpb_soak_speed = 0.22, ghmpb_dry_crust = 0.5 } },
	}
	function G.ApplyDryEnv(id)
		for _, e in ipairs(G.DRY_ENVS) do
			if e.id == id then
				for k, v in pairs(e.cv) do RunConsoleCommand(k, tostring(v)) end
				return true
			end
		end
		return false
	end
	-- the conditions the settings match now (nil = custom)
	function G.DryEnvNow()
		for _, e in ipairs(G.DRY_ENVS) do
			local same = true
			for k, v in pairs(e.cv) do
				local cv = GetConVar(k)
				if not cv or math.abs(cv:GetFloat() - v) > 0.005 then same = false break end
			end
			if same then return e end
		end
	end
	concommand.Add("ghmpb_dry_conditions", function(_, _, args)
		if not G.ApplyDryEnv(args[1] or "") then
			local ids = {}
			for _, e in ipairs(G.DRY_ENVS) do ids[#ids + 1] = e.id end
			print("[GHMPB] ghmpb_dry_conditions <" .. table.concat(ids, "|") .. ">")
		end
	end, nil, "GHM PhysBlood: set the drying settings for some conditions (indoor, hot, windy, cold)")
end

G.CLOT_VISC, G.CLOT_PIN = 30, 4

G.Surface = {
	skin    = { rough = 0.35, mu = 0.06, pin = 0.30, hret = 0.035, hdry = 0.003, lift = 0.40, liftk = 3.0, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0 },
	cloth   = { rough = 0.50, mu = 0.20, pin = 0.80, hret = 0.060, hdry = 0.003, lift = 0.55, liftk = 2.0, kabs = 0.35, cap = 1.2, pressPin = 1.5, fabric = 1.0 },
	metal   = { rough = 0.10, mu = 0.06, pin = 0.22, hret = 0.025, hdry = 0.003, lift = 0.35, liftk = 3.5, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0 },
	sealed  = { rough = 0.25, mu = 0.06, pin = 0.35, hret = 0.040, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0 },
	stone   = { rough = 0.85, mu = 0.09, pin = 0.50, hret = 0.050, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.012, cap = 0.12, pressPin = 1.5, fabric = 0.12 },
	concrete = { rough = 0.80, mu = 0.09, pin = 0.50, hret = 0.050, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.025, cap = 0.35, pressPin = 1.5, fabric = 0.22 },
	wood    = { rough = 0.60, mu = 0.10, pin = 0.55, hret = 0.050, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.025, cap = 0.30, pressPin = 1.5, fabric = 0.22 },
	soil    = { rough = 0.90, mu = 0.14, pin = 0.70, hret = 0.060, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.05, cap = 1.2, pressPin = 1.5, fabric = 0.35 },
	carpet  = { rough = 0.70, mu = 0.20, pin = 0.90, hret = 0.070, hdry = 0.003, lift = 0.50, liftk = 2.0, kabs = 0.25, cap = 1.4, pressPin = 1.5, fabric = 0.85 },
	glass   = { rough = 0.02, mu = 0.05, pin = 0.16, hret = 0.018, hdry = 0.003, lift = 0.30, liftk = 3.5, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0 },
	ice     = { rough = 0.04, mu = 0.06, pin = 0.20, hret = 0.022, hdry = 0.003, lift = 0.30, liftk = 3.5, kabs = 0.01, cap = 0.2, pressPin = 1.5, fabric = 0.0, dryk = 0.5 },
	rubber  = { rough = 0.30, mu = 0.07, pin = 0.40, hret = 0.040, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0 },
	brick   = { rough = 0.90, mu = 0.10, pin = 0.60, hret = 0.060, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.035, cap = 0.45, pressPin = 1.5, fabric = 0.28 },
	plaster = { rough = 0.55, mu = 0.08, pin = 0.45, hret = 0.045, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.03, cap = 0.35, pressPin = 1.5, fabric = 0.28 },
	paper   = { rough = 0.50, mu = 0.12, pin = 0.60, hret = 0.050, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.28, cap = 0.7, pressPin = 1.5, fabric = 0.75 },
	sand    = { rough = 1.00, mu = 0.22, pin = 1.00, hret = 0.080, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.07, cap = 1.5, pressPin = 1.5, fabric = 0.38 },
	gravel  = { rough = 1.00, mu = 0.16, pin = 0.85, hret = 0.070, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.06, cap = 1.3, pressPin = 1.5, fabric = 0.32 },
	grass   = { rough = 0.95, mu = 0.18, pin = 0.95, hret = 0.080, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.05, cap = 1.2, pressPin = 1.5, fabric = 0.38 },
	snow    = { rough = 0.80, mu = 0.12, pin = 0.75, hret = 0.060, hdry = 0.003, lift = 0.45, liftk = 3.0, kabs = 0.45, cap = 3.0, pressPin = 1.5, fabric = 0.75, dryk = 0.6 },
	grate   = { rough = 0.30, mu = 0.06, pin = 0.22, hret = 0.020, hdry = 0.003, lift = 0.25, liftk = 5.0, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0, drain = 0.8 },
	water   = { rough = 0.00, mu = 0.06, pin = 0.30, hret = 0.030, hdry = 0.003, lift = 0.40, liftk = 3.0, kabs = 0.00, cap = 1.0, pressPin = 1.5, fabric = 0.0, nostain = true },
}

G.SurfaceMatId = {
	sealed = 0, skin = 0, cloth = 6, water = 0, concrete = 1, stone = 2, metal = 3, wood = 4, soil = 5, carpet = 6,
	glass = 7, ice = 8, rubber = 9, brick = 10, plaster = 11, paper = 12, sand = 13, gravel = 14, grass = 15, snow = 16,
	grate = 17,
}

G.SurfaceMatDefaults = { soak = 0, dilute = 1, scat = 1, brown = 1, crack = 1, spark = 0, sink = 0, haloT = 0, halo = 0, haloR = 3,
	grain = 0, grainF = 0.6, grainK = 0, relief = 0.04 }
G.SurfaceRelief = { [1] = 0.08, [2] = 0.14, [3] = 0.02, [4] = 0.06, [5] = 0.16, [6] = 0.14, [7] = 0.01, [8] = 0.03, [9] = 0.05,
	[10] = 0.12, [11] = 0.06, [12] = 0.04, [13] = 0.14, [14] = 0.18, [15] = 0.16, [16] = 0.15, [17] = 0.08 }
G.SurfaceMatParams = {
	[1] = { soak = 0.6, brown = 0.8, crack = 0.3, halo = 0.45, haloR = 3, grain = 0.14, grainF = 0.3 },
	[2] = { soak = 0.2, crack = 0.7, halo = 0.2, haloR = 2, grain = 0.1, grainF = 0.5 },
	[3] = { crack = 1.3 },
	[4] = { soak = 0.55, crack = 0.3, halo = 0.45, haloR = 3, grain = 0.15, grainF = 0.3 },
	[5] = { soak = 0.8, scat = 0.8, crack = 0.15, halo = 0.6, haloR = 4, grain = 0.3, grainF = 0.25 },
	[6] = { soak = 0.85, crack = 0, halo = 0.5, haloT = 2, haloR = 4, grain = 0.2, grainF = 0.45 },
	[7] = { crack = 1.4 },
	[8] = { crack = 1.0, brown = 0.4, spark = 0.4 },
	[9] = { crack = 0.8 },
	[10] = { soak = 0.7, crack = 0.2, halo = 0.4, haloR = 3, grain = 0.12, grainF = 0.3 },
	[11] = { soak = 0.65, crack = 0.2, halo = 0.7, haloT = 2, haloR = 5, grain = 0.1, grainF = 0.4 },
	[12] = { soak = 0.9, crack = 0, halo = 0.9, haloT = 2, haloR = 6, grain = 0.12, grainF = 0.5 },
	[13] = { soak = 0.85, scat = 1.4, crack = 0, halo = 0.55, haloR = 3, grain = 0.4, grainF = 0.45 },
	[14] = { soak = 0.4, crack = 0.2, halo = 0.3, haloR = 3, grain = 0.7, grainF = 0.18, grainK = 1 },
	[15] = { soak = 0.5, crack = 0, halo = 0.2, haloR = 3, grain = 0.65, grainF = 0.5, grainK = 2 },
	[16] = { soak = 1.0, dilute = 0.55, scat = 3.0, brown = 0.25, crack = 0, spark = 1.0, sink = 1.0,
		halo = 1.0, haloT = 1, haloR = 6, grain = 0.2, grainF = 0.4 },
	[17] = { crack = 1.3 },
}
G.SurfaceMatRows = { { "soak", "dilute", "scat", "brown" }, { "crack", "spark", "sink", "haloT" }, { "halo", "haloR", "grain", "grainF" },
	{ "grainK", "relief" } }
function G.SurfaceMatValue(id, name)
	local p = G.SurfaceMatParams[id]
	local v = p and p[name]
	if v == nil and name == "relief" then v = G.SurfaceRelief[id] end
	if v == nil then v = G.SurfaceMatDefaults[name] end
	return v or 0
end

G.DustKindOf = { sand = 1, snow = 2, ice = 2, soil = 3, concrete = 4, stone = 4, sealed = 8, plaster = 5, paper = 5,
	brick = 6, wood = 7, metal = 8, glass = 8, rubber = 8, grate = 8, carpet = 8, grass = 9, gravel = 10, skin = 8, cloth = 8 }
G.DUST_NAMES = { "sand", "snow", "soil", "concrete dust", "plaster dust", "brick dust", "splinters", "soot", "soil and grass", "grit" }

G.MatTypeSurface = {
	[MAT_CONCRETE or 67] = "concrete", [MAT_TILE or 84] = "sealed", [MAT_METAL or 77] = "metal", [MAT_VENT or 86] = "metal",
	[MAT_GRATE or 71] = "grate", [MAT_COMPUTER or 80] = "metal", [MAT_GLASS or 89] = "glass", [MAT_PLASTIC or 76] = "sealed",
	[MAT_WOOD or 87] = "wood", [MAT_DIRT or 68] = "soil", [MAT_GRASS or 85] = "grass", [MAT_SAND or 78] = "sand",
	[MAT_SNOW or 74] = "snow", [MAT_FOLIAGE or 79] = "grass", [MAT_SLOSH or 83] = "water", [MAT_FLESH or 70] = "skin",
	[MAT_BLOODYFLESH or 66] = "skin", [MAT_ALIENFLESH or 72] = "skin", [MAT_ANTLION or 65] = "skin",
	[MAT_WARPSHIELD or 90] = "glass", [MAT_EGGSHELL or 69] = "sealed", [MAT_CLIP or 73] = "sealed",
}

G.SurfacePropKinds = {
	{ "watermelon", "skin" }, { "water", "water" }, { "slime", "water" }, { "wade", "water" },
	{ "metalgrate", "grate" }, { "chainlink", "grate" }, { "grate", "grate" },
	{ "glass", "glass" }, { "window", "glass" },
	{ "brick", "brick" },
	{ "plaster", "plaster" }, { "drywall", "plaster" }, { "sheetrock", "plaster" },
	{ "cardboard", "paper" }, { "paper", "paper" },
	{ "tire", "rubber" }, { "rubber", "rubber" },
	{ "carpet", "carpet" }, { "cloth", "carpet" }, { "fabric", "carpet" }, { "mattress", "carpet" }, { "foam", "carpet" },
	{ "antlionsand", "sand" }, { "quicksand", "sand" }, { "sand", "sand" },
	{ "gravel", "gravel" }, { "snow", "snow" }, { "ice", "ice" }, { "grass", "grass" }, { "foliage", "grass" },
	{ "mud", "soil" }, { "dirt", "soil" },
	{ "wood", "wood" },
	{ "tile", "sealed" }, { "ceramic", "sealed" }, { "porcelain", "sealed" }, { "pottery", "sealed" }, { "plastic", "sealed" },
	{ "concrete", "concrete" }, { "asphalt", "concrete" }, { "rock", "stone" }, { "boulder", "stone" }, { "stone", "stone" },
	{ "marble", "stone" }, { "granite", "stone" },
	{ "flesh", "skin" },
	{ "metal", "metal" }, { "canister", "metal" }, { "computer", "metal" }, { "combine", "metal" }, { "popcan", "metal" },
	{ "paintcan", "metal" }, { "weapon", "metal" }, { "ladder", "metal" }, { "vehicle", "metal" },
}
G.surfPropCache = G.surfPropCache or {}
function G.SurfaceKindOfProp(name)
	if not name or name == "" then return nil end
	local c = G.surfPropCache[name]
	if c ~= nil then return c or nil end
	local low = string.lower(name)
	local kind = false
	for _, e in ipairs(G.SurfacePropKinds) do
		if string.find(low, e[1], 1, true) then kind = e[2] break end
	end
	G.surfPropCache[name] = kind
	return kind or nil
end
function G.SurfaceKindOf(tr)
	if not tr then return "sealed" end
	local kind
	if tr.SurfaceProps and tr.SurfaceProps >= 0 and util.GetSurfacePropName then
		kind = G.SurfaceKindOfProp(util.GetSurfacePropName(tr.SurfaceProps))
	end
	return kind or G.MatTypeSurface[tr.MatType or 0] or "sealed"
end

G.BLOOD_RED, G.BLOOD_YELLOW, G.BLOOD_GREEN, G.BLOOD_ZOMBIE, G.BLOOD_SYNTH, G.BLOOD_ROBOT = 0, 1, 2, 3, 4, 5
-- (1.26.10c) the blood colours of NPC packs that none of the above has (VJ Base "Blue" / "Purple"): each with its own colour
-- in the shaders (ghmpb_common.h ghmpb_otherWet4) and in everything Lua draws (cl_util.lua U.MUA4). 8 types in all (0-7:
-- the type pair code and the drop encoding hold up to 7)
G.BLOOD_BLUE, G.BLOOD_PURPLE = 6, 7
G.BLOOD_TYPES = 8
G.BloodTypeNames = { [0] = "red", "yellow", "green", "zombie", "synth", "robot", "blue", "purple" }
local BC_ZOMBIE = BLOOD_COLOR_ZOMBIE or 5

G.NoBleedClass = {
	npc_bullseye = true, npc_enemyfinder = true,
	npc_grenade_frag = true, npc_satchel = true, npc_tripmine = true,
	npc_heli_avoidsphere = true, npc_furniture = true, npc_barnacle_tongue_tip = true,
}

G.ClassBloodType = {
	-- Robots / Machines (Dark motor oil & hydraulic fluid)
	npc_manhack = 5, npc_rollermine = 5, npc_cscanner = 5, npc_clawscanner = 5, npc_combine_camera = 5,
	npc_turret_floor = 5, npc_turret_ceiling = 5, npc_turret_ground = 5, npc_helicopter = 5,
	npc_dog = 5, npc_apcdriver = 5, npc_launcher = 5, npc_missiledefense = 5, npc_sniper = 5,
	-- Combine Synths / Bio-Mechanical Aliens (Cyan-blue synth hemolymph)
	npc_strider = 4, npc_hunter = 4, npc_combinegunship = 4, npc_combinedropship = 4,
	npc_crabsynth = 4, npc_mortarsynth = 4, npc_advisor = 4, npc_stalker = 4,
	-- Green Bioluminescent Aliens
	npc_vortigaunt = 2, npc_antlion_worker = 2, npc_antlionguard = 2, npc_alien_grunt = 2,
	npc_chumtoad = 2, npc_controller = 2, npc_nihilanth = 2, npc_bullsquid = 2,
	-- Yellow-Amber Aliens (including all Headcrab variants)
	npc_antlion = 1, npc_antlion_grub = 1, npc_headcrab = 1, npc_headcrab_fast = 1,
	npc_headcrab_black = 1, npc_headcrab_poison = 1,
	npc_barnacle = 1, npc_houndeye = 1, npc_gargantua = 1, npc_ichthyosaur = 1, npc_snark = 1,
	-- Zombies (Dark coagulated necrotic blood)
	npc_zombie = 3, npc_zombie_torso = 3, npc_fastzombie = 3, npc_fastzombie_torso = 3,
	npc_poisonzombie = 3, npc_zombine = 3,
}

G.NoBleedModel = {
	"combine_apc", "cardboard", "mattress", "mannequin", "skeleton", "statue", "/vehicles/",
	"/props_", "/props/", "furniture", "pillow", "cushion", "couch", "sofa", "chair", "table",
	"crate", "barrel", "oildrum", "wood", "plank", "door", "window", "tire", "wheel", "canister",
	"bottle", "bucket", "trash", "garbage", "bag", "sack", "cloth", "carpet", "curtain", "rope",
	"cable", "chain", "/weapons/", "hgibs", "doll", "plush", "toy", "sign", "fence", "lamp",
}

local MODEL_BLOOD_PAT = {
	-- Robots (5)
	{ "manhack", 5 }, { "scanner", 5 }, { "turret", 5 }, { "rollermine", 5 }, { "roller", 5 },
	{ "helicopter", 5 }, { "combine_camera", 5 }, { "/dog.mdl", 5 }, { "robot", 5 }, { "android", 5 },
	{ "droid", 5 }, { "cyborg", 5 }, { "/bots/", 5 }, { "bot_", 5 }, { "mech", 5 },
	-- Synths (4)
	{ "hunter", 4 }, { "strider", 4 }, { "gunship", 4 }, { "dropship", 4 }, { "synth", 4 },
	{ "advisor", 4 }, { "stalker", 4 },
	-- Green Aliens (2)
	{ "vortigaunt", 2 }, { "vort", 2 }, { "antlion_worker", 2 }, { "antlionguard", 2 }, { "agrunt", 2 },
	{ "chumtoad", 2 }, { "bullsquid", 2 }, { "controller", 2 }, { "nihilanth", 2 },
	-- Yellow Aliens (1)
	{ "antlion", 1 }, { "headcrab", 1 }, { "barnacle", 1 }, { "houndeye", 1 }, { "garg", 1 },
	{ "ichthyosaur", 1 }, { "icky", 1 }, { "snark", 1 }, { "alien", 1 },
	-- Zombies (3)
	{ "zombie", 3 }, { "zombine", 3 }, { "charple", 3 }, { "corpse1", 3 },
}

local FLESH = { flesh = 0, bloodyflesh = 0, armorflesh = 0, player = 0, zombieflesh = 3, alienflesh = 1, antlion = 1,
	antlionsand = 1, headcrab = 1, vortigaunt = 2, alienflesh_green = 2 }
local NONFLESH_PAT = { "metal", "wood", "cardboard", "paper", "plastic", "rubber", "glass", "concrete", "rock", "stone",
	"brick", "tile", "porcelain", "ceramic", "computer", "chain", "canister", "combine", "strider", "roller", "manhack",
	"gunship", "popcan", "barrel", "crate", "mattress", "gravel", "dirt", "plaster", "weapon", "grenade", "jeep",
	"airboat", "vehicle", "tire", "carpet", "cloth", "fabric", "upholstery", "cushion", "leather", "foliage", "grass",
	"sand", "snow", "ice", "water", "mud", "ceiling", "no_decal", "default_silent", "item", "ladder", "rope" }
G.modelBlood = G.modelBlood or {}
local function propType(sp)
	if not sp or sp == "" then return nil end
	sp = string.lower(sp)
	if FLESH[sp] ~= nil then return FLESH[sp] end
	if string.find(sp, "flesh", 1, true) then
		if string.find(sp, "zombie", 1, true) then return 3 end
		if string.find(sp, "green", 1, true) or string.find(sp, "vort", 1, true) then return 2 end
		if string.find(sp, "alien", 1, true) or string.find(sp, "yellow", 1, true) or string.find(sp, "antlion", 1, true) then return 1 end
		return 0
	end
	for _, pat in ipairs(NONFLESH_PAT) do if string.find(sp, pat, 1, true) then return false end end
	return nil
end
function G.ModelBloodType(mdl)
	if not mdl or mdl == "" then return nil end
	local c = G.modelBlood[mdl]
	if c ~= nil then if c == -1 then return nil end return c end
	local low = string.lower(mdl)
	local res = nil
	for _, m in ipairs(MODEL_BLOOD_PAT) do
		if string.find(low, m[1], 1, true) then res = m[2] break end
	end
	if res == nil then
		for _, k in ipairs(G.NoBleedModel) do
			if string.find(low, k, 1, true) and not string.find(low, "corpse", 1, true) then res = false break end
		end
	end
	if res == nil then
		local info = util.GetModelInfo and util.GetModelInfo(mdl)
		local flesh, other = nil, false
		if info then
			for sp in string.gmatch(info.KeyValues or "", '"surfaceprop"%s*"([^"]*)"') do
				local t = propType(sp)
				if t ~= nil and t ~= false then flesh = flesh or t elseif t == false then other = true end
			end
			local t = propType(info.SurfacePropName)
			if t ~= nil and t ~= false then flesh = flesh or t elseif t == false then other = true end
		end
		if flesh ~= nil then res = flesh elseif other then res = false end
	end
	G.modelBlood[mdl] = (res == nil) and -1 or res
	return res
end

-- (1.26.8) by model, worked out once (it is asked on every drop landing on a ragdoll: a lowercase copy of the name and
-- up to three bone lookups each time)
local charRag = {}
local function IsCharacterRagdoll(ent)
	if not IsValid(ent) then return false end
	local raw = ent:GetModel() or ""
	local c = charRag[raw]
	if c ~= nil then return c end
	local mdl = string.lower(raw)
	c = false
	if not (string.find(mdl, "/props", 1, true) and not string.find(mdl, "corpse", 1, true)) and ent.LookupBone then
		if ent:LookupBone("ValveBiped.Bip01_Pelvis") or ent:LookupBone("ValveBiped.Bip01_Spine") or ent:LookupBone("Bip01_Pelvis") then
			c = true
		end
	end
	-- a "no" is kept only once the model's bones are there (a ragdoll asked before its model was ready stays unknown)
	if c or (ent.GetBoneCount and (ent:GetBoneCount() or 0) > 1) then charRag[raw] = c end
	return c
end

function G.BloodTypeOf(ent)
	if not IsValid(ent) or ent:IsWorld() then return nil end
	if ent.ghmpbType ~= nil then return ent.ghmpbType or nil end
	local cls = ent:GetClass()
	if G.NoBleedClass[cls] then return nil end
	local clsType = G.ClassBloodType[cls]
	local mdlType = G.ModelBloodType(ent:GetModel())
	if mdlType == false and not clsType then return nil end
	local c = ent:GetNW2Int("ghmpb_blood", -2)
	if c <= -10 then return -10 - c end
	local living = ent:IsPlayer() or ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())
	if not living then
		if ent:IsRagdoll() or cls == "prop_ragdoll" then
			if mdlType == false then return nil end
			if mdlType ~= nil then return mdlType end
			if c ~= -2 and c ~= DONT_BLEED then
				if c == BLOOD_COLOR_MECH then return G.BLOOD_ROBOT end
				if c == BC_ZOMBIE then return G.BLOOD_ZOMBIE end
				if c == BLOOD_COLOR_ANTLION_WORKER or c == BLOOD_COLOR_GREEN then return G.BLOOD_GREEN end
				if c == BLOOD_COLOR_YELLOW or c == BLOOD_COLOR_ANTLION then return G.BLOOD_YELLOW end
				if IsCharacterRagdoll(ent) then return G.BLOOD_RED end
			end
			if IsCharacterRagdoll(ent) then return G.BLOOD_RED end
			return nil
		end
		return nil
	end
	if clsType then return clsType end
	if mdlType and mdlType ~= G.BLOOD_RED then return mdlType end
	local fromEngine = c == -2
	if c == -2 then
		if not ent.GetBloodColor then return mdlType or G.BLOOD_RED end
		c = ent:GetBloodColor()
	end
	if c == BLOOD_COLOR_MECH then return G.BLOOD_ROBOT end
	if c == DONT_BLEED then
		-- (1.26.8) PhysBlood on this client alone (the server does not run it, G.LocalMode): Z-City switches the engine's
		-- blood off on every player and NPC to draw its own, so "does not bleed" says nothing there - people bleed red
		if fromEngine and CLIENT and type(G.LocalMode) == "function" and G.LocalMode() and (ent:IsPlayer() or IsCharacterRagdoll(ent)) then
			return mdlType or G.BLOOD_RED
		end
		return mdlType or nil
	end
	if c == BC_ZOMBIE then return G.BLOOD_ZOMBIE end
	if c == BLOOD_COLOR_ANTLION_WORKER or c == BLOOD_COLOR_GREEN then return G.BLOOD_GREEN end
	if c == BLOOD_COLOR_YELLOW or c == BLOOD_COLOR_ANTLION then return G.BLOOD_YELLOW end
	if c == BLOOD_COLOR_RED and mdlType and mdlType ~= G.BLOOD_RED then return mdlType end
	return mdlType or G.BLOOD_RED
end
