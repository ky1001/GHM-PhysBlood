-- GPU helpers (client): the impact table is written straight into the mesh (positions as numbers or as a vector),
-- FullQuad / Quads without per-call tables
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local verts, begun = {}, 0
local cur = {}
_G.mesh = {
	Begin = function(_, n) begun = n verts = {} end, End = function() end,
	Position = function(v) cur.pos = { v.x, v.y, v.z } end,
	TexCoord = function(stage, a, b, c, d) cur[stage] = { a, b, c, d } end,
	AdvanceVertex = function() verts[#verts + 1] = cur cur = {} end,
}
_G.cam = { Start2D = function() end, End2D = function() end }
_G.render = { PushRenderTarget = function() end, PopRenderTarget = function() end, SetMaterial = function() end }
function Matrix() return { SetUnpacked = function() end } end
function Vector(x, y, z)
	local v = { x = x or 0, y = y or 0, z = z or 0 }
	function v:SetUnpacked(a, b, c) self.x, self.y, self.z = a, b, c end
	return v
end
G.GPU = {}
M.Load({ "cl_gpu.lua" })
local GPU = G.GPU
GPU.ImpactTable = function() return {} end
GPU.Blit = function() return {} end
local ims = {
	{ px = 1, py = 2, pz = 3, radius = 0.5, vel = Vector(4, 5, 6), volume = 7, normal = Vector(0, 0, 1), oxy = 1, seed = 0.5, kind = 0, spin = 9, stretch = 2, residue = 0.3 },
	{ pos = Vector(-1, -2, -3), radius = 1.5, vel = Vector(0, 0, -1), volume = 70, normal = Vector(1, 0, 0), kind = 1, K = 10, spines = 3, alt = true },
}
GPU.UploadImpacts(ims, 1, 2)
check(begun == 8 and #verts == 32, "two impacts: 8 quads, 32 vertices (" .. begun .. ", " .. #verts .. ")")
local function row(k, r) return verts[(k * 4 + r) * 4 + 1][1] end
local a = row(0, 0)
check(a[1] == 1 and a[2] == 2 and a[3] == 3 and a[4] == 0.5, "position from numbers + radius")
local b = row(1, 0)
check(b[1] == -1 and b[2] == -2 and b[3] == -3 and b[4] == 1.5, "position from a vector + radius")
local c = row(0, 1)
check(c[1] == 4 and c[3] == 6 and c[4] == 7, "velocity + volume")
local d = row(0, 2)
check(d[3] == 1 and math.abs(d[4] - (10 + 0.5 * 0.99)) < 1e-9, "normal + oxygen word")
local e = row(1, 3)
check(e[3] == 1 + 16 * 3 + 1024 and e[4] == 0, "kind / spines / second type word (a source keeps its residue, not K)")
local f = row(0, 3)
check(f[1] == 9 and f[2] == 2 and f[4] == 0.3, "spin, stretch, residue")
-- the texel of impact k, row r
local p0 = verts[(1 * 4 + 2) * 4 + 1].pos
check(math.abs(p0[1] - (1 / 64 * 2 - 1 - 1 / 64)) < 1e-9, "impact 1 lands in column 1")
-- FullQuad: payload function per corner, nothing kept between calls
local calls = 0
GPU.FullQuad(16, 16, function(ci, u, v) calls = calls + 1 return { u, v, 0, 1 } end, { 1, 2, 3, 4 })
check(calls == 4 and #verts == 4 and verts[3][1][1] == 1 and verts[3][2][4] == 4, "FullQuad: 4 corners, both payloads")
GPU.FullQuad(16, 16, { 5, 5, 5, 5 })
check(#verts == 4 and verts[1][2] == nil, "the next FullQuad does not carry the old second payload")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
