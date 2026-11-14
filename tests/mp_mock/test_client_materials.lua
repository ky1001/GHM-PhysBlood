-- Surface kinds, absorption and the shader material ids (client) under a mocked GMod
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local K = G.SurfaceKindOfProp
check(K("concrete") == "concrete" and K("concrete_block") == "concrete" and K("asphalt") == "concrete", "concrete / asphalt -> concrete")
check(K("rock") == "stone" and K("boulder") == "stone" and K("marble") == "stone", "rock / boulder / marble -> stone")
check(K("snow") == "snow" and K("ice") == "ice" and K("glass") == "glass" and K("glassbottle") == "glass", "snow / ice / glass")
check(K("slipperyslime") == "water" and K("metalgrate") == "grate" and K("dirt") == "soil", "older kinds unchanged")
check(G.MatTypeSurface[MAT_CONCRETE or 67] == "concrete" and G.MatTypeSurface[MAT_SNOW or 74] == "snow", "MAT_ fallbacks")
-- every kind has a look id inside the packed range, the ids match ghmpb_setMat
for k in pairs(G.Surface) do
	local id = G.SurfaceMatId[k]
	check(id and id >= 0 and id <= 17, "look id for " .. k .. " = " .. tostring(id))
end
check(G.SurfaceMatId.snow == 16 and G.SurfaceMatId.concrete == 1 and G.SurfaceMatId.sealed == 0 and G.SurfaceMatId.grate == 17, "ids match the shader")
-- packed word: smooth (0..3) + 4 x debug (0..4) + 32 x id decodes back
for _, id in ipairs({ 0, 1, 16, 17 }) do for sm = 0, 3 do for dbg = 0, 4 do
	local w = sm + 4 * dbg + 32 * id
	local mid = math.floor(w / 32 + 1e-3)
	local rem = w - mid * 32
	local d = math.floor(rem / 4 + 0.01)
	if mid ~= id or d ~= dbg or rem - d * 4 ~= sm then check(false, "decode " .. w) end
end end end
check(true, "packed words decode")
-- absorption order: snow soaks fastest, then sand, paper, carpet ... dense stone and sealed surfaces least
local S = G.Surface
check(S.snow.kabs > S.sand.kabs and S.sand.kabs > S.carpet.kabs and S.carpet.kabs > S.soil.kabs, "soak rate: snow > sand > carpet > soil")
check(S.concrete.kabs > S.stone.kabs and S.stone.kabs > S.sealed.kabs and S.brick.kabs > S.concrete.kabs, "soak rate: brick > concrete > stone > sealed")
check(S.snow.cap >= S.sand.cap and S.stone.cap < S.concrete.cap, "capacity")
check(S.ice.dryk < 1 and S.snow.dryk < 1 and (S.sealed.dryk or 1) == 1, "cold surfaces dry slower")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
