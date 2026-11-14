-- Light probe cache (shared grid, per-frame budget) and the allocation-free constant uploads (client)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 0
function FrameNumber() return frame end
local queries = 0
_G.render = { ComputeLighting = function(pos, dir) queries = queries + 1 return Vector(0.2 + 0.1 * dir.z, 0.2, 0.2) end }
_G.util.GetSunInfo = function() return nil end
function LocalPlayer() return NULL end
-- (matrix / material stand-ins that count the engine calls)
local uploads = 0
function Matrix() return { SetUnpacked = function(self, ...) self.v = { ... } end } end
local function Mat()
	local m = { f = {}, mats = {} }
	function m:SetFloat(k, v) self.f[k] = v end
	function m:SetMatrix(k, mt) uploads = uploads + 1 self.mats[k] = mt.v end
	return m
end
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
G.GPU = {}
M.Load({ "cl_gpu.lua", "cl_lighting.lua" })
local L, GPU = G.Light, G.GPU

-- the grid: layers close together share one probe
local keys = {}
for i = 1, 40 do keys[i] = {} end
for i = 1, 40 do L.Get(keys[i], Vector(100 + (i % 4) * 3, 200, 10), 0.5) end
check(L.stats.probes <= 2, "40 layers within a few units: " .. L.stats.probes .. " probes (" .. queries .. " lighting queries)")
check(L.stats.shared >= 38, "the rest share them (" .. L.stats.shared .. ")")
-- the budget: past it, an older probe of the same layer is used again
M.now = M.now + 1
frame = frame + 1
local far = {}
for i = 1, 60 do far[i] = {} L.Get(far[i], Vector(i * 200, 0, 0), 0.5) end   -- 60 layers far apart, first time: all probed
local p0 = L.stats.probes
M.now = M.now + 1                -- every probe is now stale (> 0.5 s)
frame = frame + 1
for i = 1, 60 do L.Get(far[i], Vector(i * 200, 0, 0), 0.5) end
check(L.stats.probes - p0 == L.BUDGET, "a frame re-probes at most the budget (" .. (L.stats.probes - p0) .. ")")
check(L.stats.stale >= 60 - L.BUDGET, "the others keep their older probe (" .. L.stats.stale .. ")")
M.now = M.now + L.STALE_MAX + 1  -- too old even for that: probed anyway
frame = frame + 1
local p1 = L.stats.probes
for i = 1, 60 do L.Get(far[i], Vector(i * 200, 0, 0), 0.5) end
check(L.stats.probes - p1 == 60, "older than STALE_MAX: probed again whatever the budget (" .. (L.stats.probes - p1) .. ")")

-- uploads: only when something changed, no tables needed
local mat = Mat()
local info = L.Get({}, Vector(5000, 5000, 0), 0.5)
L.Apply(mat, info, 0.4, 1, 0.999, 0)
L.ApplySH4(mat, info, 0.1, 0.2, 0.3, 0.4)
check(uploads == 2, "first apply: 2 matrix uploads (" .. uploads .. ")")
L.Apply(mat, info, 0.4, 1, 0.999, 0)
L.ApplySH4(mat, info, 0.1, 0.2, 0.3, 0.4)
check(uploads == 2, "same values: nothing sent again (" .. uploads .. ")")
L.ApplySH4(mat, info, 0.1, 0.2, 0.3, 0.5)
check(uploads == 3, "one value changed: one upload (" .. uploads .. ")")
local v = mat.mats["$invviewprojmat"]
check(v and v[1] == info.r[1] and v[5] == info.g[1] and v[9] == info.b[1] and v[16] == 0.5, "rows land in order (r, g, b, caller's)")
local m2 = Mat()
GPU.SetRows(m2, "$viewprojmat", { 1, 2 }, { 3 }, {}, { 4, 5, 6, 7 })
local w = m2.mats["$viewprojmat"]
check(w and w[1] == 1 and w[2] == 2 and w[3] == 0 and w[5] == 3 and w[9] == 0 and w[16] == 7, "table form still works (missing = 0)")
-- the flashlight is worked out once a frame
local calls = 0
_G.LocalPlayer = function() calls = calls + 1 return NULL end
frame = frame + 1
for _ = 1, 50 do L.Flashlight() end
check(calls == 1, "flashlight: one look-up a frame (" .. calls .. ")")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
