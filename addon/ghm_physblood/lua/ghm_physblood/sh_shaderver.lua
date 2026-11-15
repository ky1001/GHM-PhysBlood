
GHMPB = GHMPB or {}
GHMPB.ShaderPrefix = "ghmpbb74_"

-- (1.26.6) the shader pack this version is built for: the size of each of its files (tools/make_shader_manifest.py writes
-- this block - rerun it, with the new version, for every build whose shaders change). cl_shadercheck.lua compares the
-- installed files with it and asks players whose files come from an older pack to install this one.
GHMPB.ShaderPack = {
	version = "1.26.11",
	notes = "two-pass enhanced world blood surface shader (surfbase_ps30 + surfcoat_ps30 + quarter-res fbblur_ps30, toggled live by ghmpb_surface_enhanced): liquid-lens meniscus refraction, sun and flashlight rim caustics, dual-scale capillary ripples, 3D normal-mapped micro and macro bubbles, fibrin clot mottling, full world 55-deg meniscus rim glints and 6-step screen-space reflections; clear scarlet pools like 1.26.2 that stay red as they clot, and every blood type clearer; pools no longer see-through (opaque from 0.18 mm, thin smears still see-through)",
	url = "https://github.com/ky1001/GHM-PhysBlood/releases/latest",
	source = "https://github.com/ky1001/GHM-PhysBlood",
	page = "https://steamcommunity.com/profiles/76561198050670994/myworkshopfiles/?appid=4000",
	files = {
		bake_ps30 = 617, bake_ps50 = 1627, blit_ps30 = 489, blit_ps50 = 397,
		bodyfilm_ps30 = 11943, bodyfilm_ps50 = 33986, bodystatic_ps30 = 11439, bodystatic_ps50 = 31349,
		clip_vs30 = 596, clip_vs50 = 565, copy_ps30 = 522, copy_ps50 = 540,
		drop_ps30 = 2213, drop_ps50 = 5551, drop_vs30 = 1066, drop_vs50 = 1753,
		dustaft_ps30 = 831, dustaft_ps50 = 1976, dustbody_ps30 = 3333, dustbody_ps50 = 8685,
		dustworld_ps30 = 3504, dustworld_ps50 = 9547, elem_ps30 = 2269, elem_ps50 = 3837,
		fbblur_ps30 = 744,
		force_ps30 = 1685, force_ps50 = 3109, hole_ps30 = 2883, model_vs30 = 696, model_vs50 = 1208,
		modeldust_vs30 = 696, modeldust_vs50 = 1207, peek_ps30 = 543, peek_ps50 = 717,
		pforce_ps30 = 4500, pforce_ps50 = 7368, probeblur_ps30 = 1599, probeblur_ps50 = 2287,
		probeenv_ps30 = 832, probeenv_ps50 = 1023, reduce_ps30 = 1036, reduce_ps50 = 1791, screen_ps30 = 3448,
		sim_ps30 = 9046, sim_ps50 = 42367, simbody_ps30 = 7672, simbody_ps50 = 35741,
		stamp_ps30 = 9841, stamp_ps50 = 33254, surface_ps30 = 14722, surface_ps50 = 44550,
		surfbase_ps30 = 10654, surfcoat_ps30 = 12619,
		surfstatic_ps30 = 13731, surfstatic_ps50 = 40886, unwrap_vs30 = 654, unwrap_vs50 = 861,
		world_vs30 = 753, world_vs50 = 1308, worlddust_vs30 = 753, worlddust_vs50 = 1308,
	},
}
