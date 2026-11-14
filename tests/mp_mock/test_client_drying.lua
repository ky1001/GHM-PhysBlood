-- (1.26.1) drying settings: time-lapse, per-surface drying speeds, soaking, the clotted skin, conditions presets,
-- the drying age of settled layers (no jumps when a setting changes) and the menu's time estimates
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local function near(a, b, tol) return a and b and math.abs(a - b) <= (tol or 1e-9) * math.max(1, math.abs(b)) end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local function set(n, v) RunConsoleCommand(n, tostring(v)) end

-- defaults
check(near(G.DryTime(), 1816) and near(G.CoagTime(), 535), "defaults (1.26.8, GHM's): drying 1816 s, clotting 535 s")
local all1 = true
for k in pairs(G.Surface) do if not near(G.DryMult(k), 1) then all1 = false end end
check(all1 and near(G.SoakMult(), 0.28), "defaults: every surface dries at x1, soaking x0.28")
check(near(G.DryMult(nil), 1) and near(G.DryMult("water"), 1) and near(G.DryMult("no such kind"), 1), "unknown kinds dry at x1")
-- the laws below are checked at the figures of 1.26.7 and before (drying 240 s, clotting 180 s, soaking x1)
set("ghmpb_drytime", 240) set("ghmpb_coag_time", 180) set("ghmpb_soak_speed", 1) set("ghmpb_soak_delay", 1)

-- time-lapse
set("ghmpb_timelapse", 10)
check(near(G.DryTime(), 24) and near(G.CoagTime(), 18) and near(G.ClotScale(), 0.1), "time-lapse x10: drying 24 s, clotting 18 s")
set("ghmpb_timelapse", 1)

-- per-surface multipliers, by name and by table
set("ghmpb_dry_porous", 2) set("ghmpb_dry_cold", 0.5) set("ghmpb_dry_bodies", 3) set("ghmpb_dry_sealed", 0.25)
check(near(G.DryMult("concrete"), 2) and near(G.DryMult(G.Surface.carpet), 2), "porous x2 (by name and by table)")
check(near(G.DryMult("snow"), 0.5) and near(G.DryMult(G.Surface.ice), 0.5), "ice / snow x0.5")
check(near(G.DryMult("skin"), 3) and near(G.DryMult(G.Surface.cloth), 3), "bodies x3")
check(near(G.DryMult("glass"), 0.25) and near(G.DryMult("sealed"), 0.25) and near(G.DryMult("grate"), 0.25), "sealed x0.25")

-- the simulation constants
local C, R = {}, {}
G.GPU = {}
_G.render = _G.render or {}
_G.Matrix = _G.Matrix or function() return { SetUnpacked = function() end } end
_G.mesh = _G.mesh or { Begin = function() end, End = function() end, Position = function() end, TexCoord = function() end, AdvanceVertex = function() end }
_G.cam = _G.cam or { Start2D = function() end, End2D = function() end }
M.Load({ "cl_gpu.lua" })
local GPU = G.GPU
GPU.SetC = function(_, i, a, b, c, d) C[i] = { a, b, c, d } end
GPU.SetRowsN = function(_, _, ...) R = { ... } end
set("ghmpb_soak_speed", 3) set("ghmpb_dry_crust", 0.85)
GPU.SimParams({}, G.Surface.concrete, 256, 0.033)
check(near(C[2][3], 2 / 240) and near(C[2][4], G.Surface.concrete.kabs * 3), "concrete: 1/tau x2, absorption x3 (" .. C[2][3] .. ", " .. C[2][4] .. ")")
check(near(R[1], 4.8 / 180) and near(R[4], 0.85), "clotting rate 4.8 / 180 s, clotted-skin slow-down 0.85")
GPU.SimParams({}, G.Surface.ice, 256, 0.033)
check(near(C[2][3], 0.5 * (G.Surface.ice.dryk or 1) / 240), "ice keeps its own slower drying, x0.5 on top")
set("ghmpb_timelapse", 5)
GPU.SimParams({}, G.Surface.skin, 256, 0.033)
check(near(C[2][3], 3 * 5 / 240) and near(R[1], 4.8 * 5 / 180), "time-lapse x5 speeds drying and clotting on bodies too")
GPU.SimParams({}, G.Surface.carpet, 256, 0.033, nil, nil, nil, nil, nil, nil, nil, { heat = 0.5 })
check(near(C[2][3], 2 * 5 / 240 * (1 + 60 * 0.5)), "fire still dries blood on top of the settings")
set("ghmpb_coagulation", 0)
GPU.SimParams({}, G.Surface.carpet, 256, 0.033)
check(R[1] == 0, "coagulation off: no clotting")
set("ghmpb_coagulation", 1) set("ghmpb_timelapse", 1)

-- (1.26.1) fresh blood soaks in slowly: the ramp of the absorption with the age of the blood
check(near(G.SoakRamp("concrete", 0), 0.08), "a fresh pool on concrete: absorption at 8 %")
check(near(G.SoakRamp("concrete", 0.08 * 180), 0.08), "still 8 % at 8 % of the clotting time (14 s)")
local mid = G.SoakRamp("concrete", (0.08 + 0.185) * 180)
check(mid > 0.45 and mid < 0.63, string.format("half way (48 s): %.2f", mid))
check(near(G.SoakRamp("concrete", 0.45 * 180), 1) and near(G.SoakRamp("soil", 400), 1), "full from 45 % of the clotting time (81 s) - before it settles (90 s)")
local inc = true
for t = 0, 120, 2 do if G.SoakRamp("sand", t + 2) < G.SoakRamp("sand", t) then inc = false end end
check(inc, "smooth and never decreasing")
check(G.SoakRamp("snow", 0) == 1 and G.SoakRamp("carpet", 0) == 1 and G.SoakRamp("paper", 0) == 1, "snow, carpet and paper drink at once")
set("ghmpb_soak_delay", 0)
check(G.SoakRamp("concrete", 0) == 1, "soak delay 0: full rate at once (the 1.26.0 look)")
set("ghmpb_soak_delay", 1)
local r1 = G.SoakRamp("concrete", 48)
set("ghmpb_soak_delay", 2)
check(near(G.SoakRamp("concrete", 96), r1) and G.SoakRamp("concrete", 81) < 0.5, "soak delay 2: the same ramp, twice as long")
set("ghmpb_soak_delay", 1)
set("ghmpb_timelapse", 10)
check(near(G.SoakRamp("concrete", 0.45 * 18), 1), "time-lapse x10: ten times sooner")
set("ghmpb_timelapse", 1)
set("ghmpb_soak_speed", 1)
GPU.SimParams({}, G.Surface.concrete, 256, 0.033, nil, nil, nil, nil, nil, nil, nil, nil, 0.08)
check(near(C[2][4], G.Surface.concrete.kabs * 0.08), "the ramp reaches the simulation's absorption constant")

-- drying age of settled layers: added up, no jump when the settings change
for _, n in ipairs({ "ghmpb_dry_porous", "ghmpb_dry_cold", "ghmpb_dry_bodies", "ghmpb_dry_sealed", "ghmpb_soak_speed", "ghmpb_dry_crust" }) do
	set(n, GetConVar(n):GetDefault())
end
local a = { bakedAt = M.now }
check(near(G.DryAge(a, 1), 0), "a layer that just settled: age 0")
M.now = M.now + 120
check(near(G.DryAge(a, 1), 0.5), "120 s later: half a drying time")
set("ghmpb_timelapse", 10)
check(near(G.DryAge(a, 1), 0.5), "switching the time-lapse on does not jump the age")
M.now = M.now + 12
check(near(G.DryAge(a, 1), 1.0), "12 s at x10 = one more half drying time")
check(near(G.DryAge(a, 1), 1.0), "asking twice in a frame adds nothing")
M.now = M.now + 24
check(near(G.DryAge(a, 2), 3.0), "a surface that dries twice as fast ages twice as fast")
a.bakedAt = M.now
check(near(G.DryAge(a, 1), 0), "baked again: the age starts over")
check(G.DryAge({}, 1) > 0, "a record without a bake time counts as long dry")
set("ghmpb_timelapse", 1)

-- conditions presets (back at the defaults)
for _, n in ipairs({ "ghmpb_drytime", "ghmpb_coag_time", "ghmpb_soak_speed", "ghmpb_soak_delay", "ghmpb_dry_crust", "ghmpb_dry_bodies", "ghmpb_dry_porous", "ghmpb_dry_sealed", "ghmpb_dry_cold" }) do set(n, GetConVar(n):GetDefault()) end
local indoor = G.DRY_ENVS[1]
local same = true
for k, v in pairs(indoor.cv) do if not near(tonumber(GetConVar(k):GetDefault()), v, 1e-6) then same = false end end
check(same and indoor.id == "indoor", "the Indoors preset is the defaults")
check(G.DryEnvNow() == indoor, "at the defaults the conditions read Indoors")
check(G.ApplyDryEnv("cold") and G.DryEnvNow() and G.DryEnvNow().id == "cold" and near(G.cv.drytime:GetFloat(), 5450), "Cold and damp applied")
check(G.CoagTime() > 535, "cold: slower clotting")
G.ApplyDryEnv("hot")
check(G.DryEnvNow().id == "hot" and G.DryTime() < 1816 and G.CoagTime() < 535, "Hot and dry: faster drying and clotting")
set("ghmpb_dry_crust", 0.33)
check(G.DryEnvNow() == nil, "moving a slider makes it custom")
check(M.cmds and M.cmds.ghmpb_dry_conditions, "console command ghmpb_dry_conditions")
M.cmds.ghmpb_dry_conditions(nil, nil, { "windy" })
check(G.DryEnvNow() and G.DryEnvNow().id == "windy", "ghmpb_dry_conditions windy")
check(not G.ApplyDryEnv("nope"), "unknown conditions are refused")
M.cmds.ghmpb_dry_conditions(nil, nil, { "indoor" })

-- the menu (cl_menu.lua): built against a permissive stand-in for Derma (any method exists), so the Lua of every tab
-- runs - including the Drying tab's live readouts - and its estimates are checked
local made, texts = {}, {}
local function Proxy()
	local p = {}
	made[#made + 1] = p
	return setmetatable(p, { __index = function(_, k)
		if k == "SetText" then return function(_, t) texts[#texts + 1] = t end end
		if k == "GetText" then return function() return "" end end
		return function() return Proxy() end
	end })
end
_G.list = _G.list or { Set = function() end, Get = function() return {} end }
_G.spawnmenu = _G.spawnmenu or { AddToolMenuOption = function() end }
_G.vgui = { Create = function() return Proxy() end }
_G.Derma_Query = function() end
G.Menu = nil
local ok, err = pcall(M.Load, { "cl_menu.lua" })
check(ok, "cl_menu.lua loads" .. (ok and "" or (": " .. tostring(err))))
local Mn = G.Menu
-- build the whole window with stand-ins for the modules it reads
local GM = getmetatable(G)
rawset(G, "Wounds", rawget(G, "Wounds") or { STYLES = {}, StyleById = function() end, ApplyStyle = function() end })
rawset(G, "VAT", rawget(G, "VAT") or {})
_G.LocalPlayer = _G.LocalPlayer or function() return NULL end
_G.game = _G.game or {}
game.SinglePlayer = game.SinglePlayer or function() return true end
_G.GetConVarString = _G.GetConVarString or function(n) local c = GetConVar(n) return c and c:GetString() or "" end
setmetatable(G, { __index = function(_, k) return Proxy() end })
local okB, errB = pcall(Mn.Build, Proxy())
check(okB, "the settings window builds" .. (okB and "" or (": " .. tostring(errB))))
-- the live readouts: the Drying tab's must run (others read modules that are only stand-ins here)
local thinks = 0
for _, p in ipairs(made) do
	local th = rawget(p, "Think")
	if th then thinks = thinks + 1 local o, e = pcall(th, p) if not o then print("info: a readout of another tab needs a real module: " .. tostring(e)) end end
end
local sawEnv, sawEst = false, false
for _, t in ipairs(texts) do
	if type(t) == "string" and t:find("Current conditions:") then sawEnv = true end
	if type(t) == "string" and t:find("On a sealed floor") then sawEst = true end
end
check(sawEnv and sawEst, "the Drying tab's readouts run (conditions, time estimates) - " .. thinks .. " readouts")
setmetatable(G, GM)
if ok and Mn and Mn.DryEstimate then
	local thin = Mn.DryEstimate(0.1, 1)
	local film = Mn.DryEstimate(1, 1)
	local pool = Mn.DryEstimate(3, 1)
	check(thin and film and pool and thin < film and film < pool, string.format("thicker dries slower: %.0f s < %.0f s < %.0f s", thin or -1, film or -1, pool or -1))
	-- a thin film with no clotting: k between 1.5 and 3 per drying time -> 95 % in ln(20) / 3 .. ln(20) / 1.5 drying times
	set("ghmpb_coagulation", 0)
	local t0 = Mn.DryEstimate(0.1, 1)
	check(t0 >= math.log(20) / 3 * G.DryTime() * 0.98 and t0 <= math.log(20) / 1.5 * G.DryTime() * 1.02, string.format("thin film follows the drying law (%.0f s)", t0))
	set("ghmpb_coagulation", 1)
	set("ghmpb_timelapse", 10)
	local poolT = Mn.DryEstimate(3, 1)
	check(near(poolT, pool / 10, 0.05), string.format("time-lapse x10: a pool dries 10x sooner (%.0f vs %.0f s)", poolT, pool))
	set("ghmpb_timelapse", 1)
	set("ghmpb_dry_crust", 0.95)
	local slow = Mn.DryEstimate(3, 1)
	check(slow == nil or slow > pool * 1.3, "a stronger clotted skin keeps a pool wet longer" .. (slow and "" or " (more than 2 days)"))
	set("ghmpb_dry_crust", 0.6)
	local cs = G.Surface.concrete
	check(Mn.DryEstimate(0.1, 1, cs.kabs, cs.cap) < thin, "concrete drinks a thin smear in sooner than it dries on tile")
	check(Mn.DryEstimate(0.1, 1, cs.kabs, cs.cap, "concrete") > Mn.DryEstimate(0.1, 1, cs.kabs, cs.cap), "fresh blood soaking in slowly takes longer on concrete")
	local ct = Mn.ClotTime()
	check(ct and math.abs(ct - G.CoagTime()) / G.CoagTime() < 0.15, string.format("90 %% clotted at about the clotting time (%.0f s)", ct or -1))
	local rep = Mn.DryReport()
	check(type(rep) == "string" and rep:find("3 mm pool") and rep:find("Clotted"), "the readout text")
	print(rep)
	set("ghmpb_drytime", 3600) set("ghmpb_dry_sealed", 0.1) set("ghmpb_dry_crust", 0.95)
	check(Mn.DryEstimate(3, G.DryMult("sealed")) == nil, "very slow settings: 'more than 2 days', no endless loop")
end
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
