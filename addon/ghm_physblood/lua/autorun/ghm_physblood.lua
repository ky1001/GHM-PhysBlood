GHMPB = GHMPB or {}
GHMPB.Version = "1.26.11"

local base = "ghm_physblood/"
local shared = { "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" }
local server = { "sv_compat.lua", "sv_core.lua", "sv_zcity.lua", "sv_history.lua", "sv_elements.lua", "sv_mp.lua" }
local client = {
	"cl_util.lua", "cl_prof.lua", "cl_battle.lua", "cl_governor.lua", "cl_gpu.lua", "cl_budget.lua", "cl_lighting.lua", "cl_maplights.lua", "cl_probes.lua", "cl_native.lua", "cl_particles.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_crbtypes.lua", "cl_splatmesh.lua", "cl_forensic.lua",
	"cl_entities.lua", "cl_bsptex.lua", "cl_surfaces.lua", "cl_runs.lua", "cl_tendrils.lua", "cl_water.lua", "cl_wounds.lua", "cl_holes.lua", "cl_screen.lua", "cl_trails.lua", "cl_blades.lua", "cl_smear.lua", "cl_contact.lua", "cl_footprints.lua",
	"cl_hands.lua", "cl_props.lua", "cl_tyres.lua", "cl_flesh.lua", "cl_elements.lua", "cl_dust.lua", "cl_flies.lua", "cl_zcity.lua", "cl_render.lua", "cl_lite.lua", "cl_shadercheck.lua", "cl_vat.lua", "cl_streams.lua", "cl_history.lua", "cl_presets.lua", "cl_menu.lua", "cl_debug.lua",
}

GHMPB.ClientFiles = client

for _, f in ipairs(shared) do
	if SERVER then AddCSLuaFile(base .. f) end
	include(base .. f)
end

if SERVER then
	for _, f in ipairs(client) do AddCSLuaFile(base .. f) end
	for _, f in ipairs(server) do include(base .. f) end
else
	for _, f in ipairs(client) do include(base .. f) end
end
