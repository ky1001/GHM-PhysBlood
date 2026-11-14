-- (1.26.6, 27 Oct) old blood darkens and loses its shine, own colours for red blood only, zombie chunks are red, new
-- default colours and their migration, landing splashes (crowns / satellites) - client, mocked GMod
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local function near(a, b, t) return math.abs(a - b) <= (t or 1e-6) end

-- ---------------------------------------------------------------- 1. migration of the old default colours
do
	local M = dofile("gmod.lua")
	_G.SERVER, _G.CLIENT = false, true
	-- saved settings of a player who never touched the colours (old defaults), config version 1120
	local saved = { ghmpb_color_fresh = { "2.55", "1" }, ghmpb_color_dry = { "0.9", "1" }, ghmpb_density = { "3.53", "1" },
		ghmpb_color_hue = { "0", "0" }, ghmpb_color_custom = { "1", "0" }, ghmpb_color_blood = { "255 10 0", "159 13 7" },
		ghmpb_color_dense = { "171 9 0", "97 12 7" }, ghmpb_config_version = { "0", "1120" } }
	for n, v in pairs(saved) do CreateConVar(n, v[1]):SetString(v[2]) end
	M.Load({ "sh_shaderver.lua", "sh_config.lua" })
	local cv = GHMPB.cv
	check(cv.colCustom:GetBool() and cv.colBlood:GetString() == "255 10 0" and near(cv.colFresh:GetFloat(), 2.55) and near(cv.absorb:GetFloat(), 3.53),
		"untouched old default colours -> the new default colours")
	check(GetConVar("ghmpb_config_version"):GetInt() >= 1266 and GHMPB.migrate1266, "config version 1266 or later")
end
do
	local M = dofile("gmod.lua")
	GHMPB = nil
	_G.SERVER, _G.CLIENT = false, true
	local saved = { ghmpb_color_fresh = { "2.55", "1.4" }, ghmpb_color_custom = { "1", "0" }, ghmpb_config_version = { "0", "1120" } }
	for n, v in pairs(saved) do CreateConVar(n, v[1]):SetString(v[2]) end
	M.Load({ "sh_shaderver.lua", "sh_config.lua" })
	check(near(GHMPB.cv.colFresh:GetFloat(), 1.4) and not GHMPB.cv.colCustom:GetBool(), "a player's own colour settings are kept")
end

-- ---------------------------------------------------------------- 2. settled layers: absorption per blood type and age, shine
local M = dofile("gmod.lua")
GHMPB = nil
_G.SERVER, _G.CLIENT = false, true
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "cl_util.lua" })
-- (1.26.8) checked at the drying figures of 1.26.7 and before (the defaults dry and clot several times slower now)
RunConsoleCommand("ghmpb_drytime", "240") RunConsoleCommand("ghmpb_coag_time", "180")
local G = GHMPB
local frame = 0
function FrameNumber() return frame end
local eye, fwd = Vector(0, 0, 64), Vector(1, 0, 0)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return fwd end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function LocalPlayer() return NULL end
_G.render = { ComputeLighting = function() return Vector(0.2, 0.2, 0.2) end, GetViewSetup = function() return { fov = 90 } end,
	SetMaterial = function() end }
_G.util.GetSunInfo = function() return nil end
_G.util.PointContents = function() return 0 end
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
local function Mat() return { SetFloat = function() end, SetMatrix = function() end, SetTexture = function() end } end
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end, Caps = function() return { patches = 999, aft = 999 } end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua" })
local GPU = G.GPU
GPU.Mat = function() return Mat() end
GPU.ImpactTable = function() return { GetName = function() return "x" end } end
GPU.MatTable = function() return { GetName = function() return "mattable" end } end
M.Load({ "cl_surfaces.lua" })
local S = G.Surfaces
G.ViewSize = function() return 1600, 900 end
G.Light.Flashlight = function() return nil end
local got = {}
local cur
local apply, sh4 = G.Light.Apply, G.Light.ApplySH4
G.Light.Apply = function(mat, info, rough, c2w, lw, ew, refl) got[cur] = got[cur] or {} got[cur].refl = refl or 1 return apply(mat, info, rough, c2w, lw, ew, refl) end
G.Light.ApplySH4 = function(mat, info, w1, w2, w3, w4) got[cur] = got[cur] or {} got[cur].abs = w4 return sh4(mat, info, w1, w2, w3, w4) end
local function Layer(i, btype, age, dry, x)
	local a = { key = "k" .. i, plane = "p", i = i, j = 0, N = Vector(0, 0, 1), center = Vector(x or (200 + i * 400), 0, 0), oxy = 0.6, btype = btype,
		albedo = Vector(0.3, 0.3, 0.3), surf = G.Surface.concrete, surfName = "concrete", bakedAt = M.now - (dry or 0), bornT = M.now - age,
		aft = { res = 256, rt = { GetName = function() return "rt" .. i end } } }
	a.meshes = { [0.035] = { Draw = function() cur = a.key end } }
	S.after[a.key] = a
	S.IndexAdd(a)
	return a
end
local A = {
	Layer(1, 0, 0), Layer(2, 0, 400), Layer(3, 3, 0), Layer(4, 1, 400), Layer(5, 0, 1200, 1200),
	-- one pool over three squares side by side: its blood arrived at different times
	Layer(6, 0, 0, 0, 3000), Layer(7, 0, 300, 0, 3040), Layer(8, 0, 120, 0, 3080),
}
-- the meshes draw after the constants are set: catch which layer is being set from its material
local matOf = {}
local AftMatOrig = GPU.Mat
GPU.Mat = function(tag) local m = Mat() return m end
-- draw: constants are set before each Draw, so record by the layer drawn next - simpler: set cur from the loop order
local order = {}
for _, a in pairs(S.after) do order[#order + 1] = a end
local Draw0 = S.DrawPatchMesh
S.DrawPatchMesh = function(a, lift) cur = nil return Draw0(a, lift) end
-- wrap Apply again to know the layer: InView / constants happen inside the loop just before DrawPatchMesh(a)
local lastSet = {}
G.Light.ApplySH4 = function(mat, info, w1, w2, w3, w4) lastSet.abs = w4 return sh4(mat, info, w1, w2, w3, w4) end
G.Light.Apply = function(mat, info, rough, c2w, lw, ew, refl) lastSet.refl = refl or 1 return apply(mat, info, rough, c2w, lw, ew, refl) end
S.DrawPatchMesh = function(a, lift) got[a.key] = { abs = lastSet.abs, refl = lastSet.refl } return Draw0(a, lift) end
G.DryAge = function(rec) return (M.now - rec.bakedAt) / G.DryTime() end
frame = 1
S.DrawStatic()
local fresh0 = G.BloodAbsorb()
local plain = G.cv.absorb:GetFloat() * GPU.FreshAbs()
local _, aged0 = G.AgedAbsorb(0)
print(string.format("     red fresh %.3f, red 400 s %.3f, zombie fresh %.3f, yellow 400 s %.3f, red dried %.3f",
	got.k1.abs, got.k2.abs, got.k3.abs, got.k4.abs, got.k5.abs))
check(near(got.k1.abs, fresh0, 1e-3), "red, fresh: the colour fitted to the player's picks")
check(near(got.k2.abs, aged0, 0.02) and got.k2.abs > 5 * got.k1.abs, "red, older than the clotting time: as dark as the physical default")
check(near(got.k3.abs, plain, 1e-3), "zombie blood: the plain absorption, not the bright fitted one")
check(got.k4.abs >= plain - 1e-3, "yellow blood, old: never brighter than fresh")
print(string.format("     shine: fresh %.2f, clotted %.2f, dried %.2f", got.k1.refl, got.k2.refl, got.k5.refl))
check(near(got.k1.refl, 1, 0.02) and got.k5.refl < 0.4, "shine: fresh 1, long dried < 0.4")
check(G.ShineAt(G.CoagTime() * 0.95) > 0.99, "wet and clotting blood keeps its full shine")
print(string.format("     one pool over 3 squares: absorption %.3f %.3f %.3f, shine %.2f %.2f %.2f", got.k6.abs, got.k7.abs, got.k8.abs, got.k6.refl, got.k7.refl, got.k8.refl))
check(near(got.k6.abs, got.k7.abs, 1e-6) and near(got.k7.abs, got.k8.abs, 1e-6) and near(got.k6.refl, got.k8.refl, 1e-6),
	"one pool over several squares: one darkness and shine for all of them (no seams)")
check(got.k6.abs > got.k1.abs and got.k6.abs < got.k2.abs, "its age is the mean of its blood's")
-- nothing changes -> no constants set again
lastSet = {}
frame = 2
local n0 = 0
G.Light.ApplySH4 = function(...) n0 = n0 + 1 return sh4(...) end
S.DrawStatic()
check(n0 == 0, "a frame later: no constants set again (" .. n0 .. ")")
M.now = M.now + 20
frame = 3
S.DrawStatic()
check(n0 > 0, "20 s later the fresh layer has aged a step: its constants are set again (" .. n0 .. ")")

-- ---------------------------------------------------------------- 3. live patches: volume-weighted age of their blood
do
	local P = S.PATCH_UNITS
	local N, U, V = Vector(0, 0, 1), Vector(1, 0, 0), Vector(0, 1, 0)
	local plane = string.format("%d,%d,%d,%d", 0, 0, 40, 0)
	local p = { key = plane .. "|0|0", plane = plane, i = 0, j = 0, N = N, U = U, V = V, origin = Vector(0, 0, 0),
		center = Vector(P * 0.5, P * 0.5, 0), cur = 1, impacts = {}, touched = 0, wetUntil = 0, hasBlood = true,
		oxy = 0.75, btype = 0, surfName = "concrete", surf = G.Surface.concrete }
	S.patches[p.key] = p
	S.IndexAdd(p)
	local t0 = M.now
	S.Impact(Vector(20, 20, 0), N, Vector(0, 0, -100), 0.5, 150, 1, 0, 1, 0.02, nil, 0.7, 0)
	check(p.bornT and near(p.bornT, t0, 1e-6), "a pool: its blood's age starts")
	M.now = M.now + 100
	S.Impact(Vector(20, 20, 0), N, Vector(0, 0, -100), 0.3, 10, 0, 0, 1, 0.2, nil, 0.7, 0)
	check(p.bornT and M.now - p.bornT > 90, string.format("a few fresh drops on it: it stays old (age %.0f s)", M.now - p.bornT))
	S.Impact(Vector(20, 20, 0), N, Vector(0, 0, -100), 0.5, 150, 1, 0, 1, 0.02, nil, 0.7, 0)
	check(M.now - p.bornT < 60, string.format("as much fresh blood again: half as old (age %.0f s)", M.now - p.bornT))
end

-- ---------------------------------------------------------------- 4. zombie chunks are red
M.Load({ "cl_forensic.lua" })
check(G.Forensic.ChunkType(G.BLOOD_ZOMBIE) == G.BLOOD_RED and G.Forensic.ChunkType(G.BLOOD_YELLOW) == G.BLOOD_YELLOW
	and G.Forensic.ChunkType(G.BLOOD_RED) == G.BLOOD_RED, "zombie chunks are red blood, other types keep theirs")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
