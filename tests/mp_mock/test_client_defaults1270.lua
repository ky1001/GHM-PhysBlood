-- (1.26.8) GHM: "disable the automatic tuning to fps on default ... make it that it shows the best blood system out of
-- the box, let players tweak it in settings themselves". New players start on the Ultra preset with the automatic tuning
-- off; players whose settings were all still at the old defaults are moved over once; settings a player changed stay
-- (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local function Fresh(saved)
	M.cvars = {}
	for k, v in pairs(saved or {}) do CreateConVar(k, tostring(v)) end
	GHMPB = nil
	M.Load({ "sh_shaderver.lua", "sh_config.lua" })
	G = GHMPB
	G.U = G.U or {}
	G.Wounds = { bodies = {} }
	M.Load({ "cl_battle.lua" })
	return G.cv
end
local function I(n) return GetConVar(n):GetInt() end
-- a new player
local cv = Fresh()
check(I("ghmpb_quality") == 4 and I("ghmpb_sim_hz") == 45 and I("ghmpb_max_particles") == 4000 and I("ghmpb_max_patches") == 32
	and I("ghmpb_max_entities") == 8 and I("ghmpb_aftermath_max") == 800, "a new player: the Ultra preset")
check(I("ghmpb_perf_adaptive") == 0 and I("ghmpb_battle_lod") == 0, "a new player: adaptive quality and fight-size tuning off")
check(I("ghmpb_vram_mb") == 2048, "a new player: a 2 GB video memory budget")
-- a player from 1.26.7 still on the old defaults
Fresh({ ghmpb_config_version = 1269, ghmpb_quality = 2, ghmpb_sim_hz = 30, ghmpb_max_entities = 12, ghmpb_max_patches = 40,
	ghmpb_max_particles = 1400, ghmpb_aftermath_max = 400, ghmpb_perf_adaptive = 1, ghmpb_battle_lod = 1, ghmpb_vram_mb = 1024 })
check(I("ghmpb_quality") == 4 and I("ghmpb_sim_hz") == 45 and I("ghmpb_max_particles") == 4000, "an updating player on the old defaults: moved to Ultra")
check(I("ghmpb_perf_adaptive") == 0 and I("ghmpb_battle_lod") == 0 and I("ghmpb_vram_mb") == 2048, "and the automatic tuning off, 2 GB")
check(I("ghmpb_config_version") >= 1270, "settings step 1270 done")
-- a player who had set their own
Fresh({ ghmpb_config_version = 1269, ghmpb_quality = 1, ghmpb_sim_hz = 20, ghmpb_max_entities = 6, ghmpb_max_patches = 20,
	ghmpb_max_particles = 700, ghmpb_aftermath_max = 200, ghmpb_perf_adaptive = 1, ghmpb_battle_lod = 1, ghmpb_vram_mb = 512 })
check(I("ghmpb_quality") == 1 and I("ghmpb_sim_hz") == 20 and I("ghmpb_vram_mb") == 512, "a player on Low with 512 MB: kept")
-- once only: a player who turns the tuning back on keeps it
Fresh({ ghmpb_config_version = 1270, ghmpb_perf_adaptive = 1, ghmpb_battle_lod = 1 })
check(I("ghmpb_perf_adaptive") == 1 and I("ghmpb_battle_lod") == 1, "turned back on after the update: stays on")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
