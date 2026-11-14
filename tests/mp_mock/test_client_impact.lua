-- World impacts: the patch lookup (plain-number geometry, last patch first) and splats reaching over patch borders
-- (neighbours found by key, a missing one looked for by place) - client, mocked GMod
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
math.Round = math.Round or function(x, d) local m = 10 ^ (d or 0) return math.floor(x * m + 0.5) / m end
function LocalPlayer() return NULL end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
_G.util.PointContents = function() return 0 end
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end, Caps = function() return { patches = 999, aft = 999 } end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua", "cl_surfaces.lua" })
local S = G.Surfaces
local P = S.PATCH_UNITS
local N, U, V = Vector(0, 0, 1), Vector(1, 0, 0), Vector(0, 1, 0)
local plane = string.format("%d,%d,%d,%d", 0, 0, 40, 0)
local function Make(i, j, live)
	local origin = U * (i * P) + V * (j * P)
	local p = { key = plane .. "|" .. i .. "|" .. j, plane = plane, i = i, j = j, N = N, U = U, V = V, origin = origin,
		center = origin + U * (P * 0.5) + V * (P * 0.5), cur = 1, impacts = {}, touched = 0, wetUntil = 0, hasBlood = true,
		oxy = 0.75, btype = 0, surfName = "concrete", surf = G.Surface.concrete }
	if live then S.patches[p.key] = p else S.after[p.key] = p end
	S.IndexAdd(p)
	return p
end
local grid = {}
for i = -1, 1 do for j = -1, 1 do grid[i .. "," .. j] = Make(i, j, true) end end
-- a settled layer of another floor 3 m higher (must never be picked)
Make(0, 0, false).origin = Vector(0, 0, 160)
local function Counts()
	local o = {}
	for k, p in pairs(grid) do o[k] = #p.impacts p.impacts = {} end
	return o
end
local function Hit(x, y, r)
	S.Impact(Vector(x, y, 0), Vector(0, 0, 1), Vector(0, 0, -100), r or 0.3, 50, 0, 0, 1, 0.2, nil, 0.7, 0)
	return Counts()
end
-- lookups
for _, c in ipairs({ { 5, 5, "0,0" }, { 45, 5, "1,0" }, { -5, 25, "-1,0" }, { 20, -30, "0,-1" }, { 79, 79, "1,1" }, { 5, 5, "0,0" } }) do
	local p = S.GetPatch(Vector(c[1], c[2], 0.5), N, false)
	check(p == grid[c[3]], string.format("lookup (%d, %d) -> patch %s", c[1], c[2], c[3]))
end
check(S.GetPatch(Vector(5, 5, 20), N, false) == nil, "20 u above the floor: no patch")
-- a splat in the middle of a patch stays there
local c = Hit(20, 20)
check(c["0,0"] == 1 and c["1,0"] == 0 and c["-1,0"] == 0, "middle: one patch")
-- near the +u edge: the neighbour paints its part too
c = Hit(39.5, 20)
check(c["0,0"] == 1 and c["1,0"] == 1 and c["1,1"] == 0 and c["0,1"] == 0, "at an edge: the neighbour across it")
-- at a corner: all four
c = Hit(39.6, 39.6)
check(c["0,0"] == 1 and c["1,0"] == 1 and c["0,1"] == 1 and c["1,1"] == 1 and c["-1,0"] == 0, "at a corner: four patches")
-- a big splat reaches all eight neighbours
c = Hit(20, 20, 9)
local all = true
for _, v in pairs(c) do if v ~= 1 then all = false end end
check(all, "a big splat: the patch and its eight neighbours")
-- a missing neighbour is looked for (and made) by place, as before
local missing = grid["1,0"]
S.patches[missing.key] = nil
S.IndexRemove(missing)
local asked = {}
local realGet = S.GetPatch
S.GetPatch = function(pos, n, create, ...)
	if create then asked[#asked + 1] = pos end
	return realGet(pos, n, false, ...)
end
Hit(39.5, 20)
S.GetPatch = realGet
check(#asked >= 2 and math.abs(asked[#asked].x - 41) < 1e-6 and math.abs(asked[#asked].y - 20) < 1e-6,
	"missing neighbour: looked for at its place (" .. #asked .. " lookups, the last at x " .. (asked[#asked] and asked[#asked].x or -1) .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
