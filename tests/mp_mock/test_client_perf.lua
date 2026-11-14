-- (1.26.6, 27 Oct) performance: settled blood works out its slow values every ~0.4 s, old blood is left out of the age
-- groups, droplets outside the view are not built into the mesh, live-layer helpers (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 0
function FrameNumber() return frame end
local eye, fwd = Vector(0, 0, 64), Vector(1, 0, 0)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return fwd end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameTime() return 1 / 60 end
function LocalPlayer() return NULL end
local vtx = 0
_G.render = { ComputeLighting = function() return Vector(0.2, 0.2, 0.2) end, GetViewSetup = function() return { fov = 90 } end,
	SetMaterial = function() end }
_G.util.GetSunInfo = function() return nil end
_G.mesh = { Position = function() vtx = vtx + 1 end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
local function Mat() local m = {} function m:SetFloat() end function m:SetMatrix() end function m:SetTexture() end return m end
G.U = G.U or {}
M.Load({ "cl_util.lua" })
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua" })
G.Light.Flashlight = function() return nil end
local GPU = G.GPU
GPU.Mat = function() return Mat() end
GPU.ImpactTable = function() return { GetName = function() return "x" end } end
GPU.MatTable = function() return { GetName = function() return "mattable" end } end
M.Load({ "cl_surfaces.lua" })
local S = G.Surfaces
G.ViewSize = function() return 1600, 900 end
-- 100 old settled squares, 10 fresh ones and a live square among them
for i = 1, 110 do
	local old = i <= 100
	local a = { key = "k" .. i, plane = "p", i = i, j = 0, N = Vector(0, 0, 1), center = Vector(300 + (i % 10) * 20, (math.floor(i / 10) - 5) * 20, 0),
		oxy = 0.6, btype = 0, albedo = Vector(0.3, 0.3, 0.3), surf = G.Surface.concrete, surfName = "concrete",
		bakedAt = old and M.now - 4000 or M.now - 5, bornT = old and M.now - 4000 or M.now - 20,
		aft = { res = 256, rt = { GetName = function() return "rt" .. i end } } }
	a.meshes = { [0.035] = { Draw = function() end } }
	S.after[a.key] = a
	S.IndexAdd(a)
end
local lp = { key = "live", plane = "p", center = Vector(300, -120, 0), hasBlood = true, bornT = M.now, vol = 50 }
S.patches[lp.key] = lp
S.IndexAdd(lp)
-- age groups: worked out again only when something changed
S.groupT = 0
S.UpdateAgeGroups(M.now)
local all = true
for i = 1, 110 do if not S.after["k" .. i].groupBorn then all = false end end
check(all and lp.groupBorn ~= nil, "every square gets its group's age")
local probe = S.after["k5"]
probe.groupBorn = 12345
S.UpdateAgeGroups(M.now + 0.6)
check(probe.groupBorn == 12345, "half a second later, nothing changed: not grouped again")
S.ageDirty = true
S.UpdateAgeGroups(M.now + 1.2)
check(probe.groupBorn ~= 12345, "blood added (or settled, or removed): grouped again")
probe.groupBorn = 12345
S.UpdateAgeGroups(M.now + 7)
check(probe.groupBorn ~= 12345, "and at least every 5 s")
-- settled blood: the slow values every ~0.4 s ("keep forever", so the old squares are drawn too)
G.cv.forever:SetString("1")
local calls = 0
local DryAge0 = G.DryAge
G.DryAge = function(...) calls = calls + 1 return DryAge0(...) end
local perFrame = {}
for f = 1, 30 do
	M.now = M.now + 1 / 60
	frame = frame + 1
	calls = 0
	S.DrawStatic()
	perFrame[f] = calls
end
local tot = 0 for f = 2, 30 do tot = tot + perFrame[f] end
print(string.format("     drying worked out: first frame %d squares, then %.1f a frame on average (%d squares)", perFrame[1], tot / 29, 110))
check(perFrame[1] >= 100 and tot / 29 < 15, "settled squares work out their drying and age every ~0.4 s, not every frame")
G.DryAge = DryAge0
check(S.HasLive() == true, "a live square with blood: the live layers are drawn")
lp.hasBlood = false
check(S.HasLive() == false, "no live blood: no screen copy for the live layers")
-- droplets: only the ones in view are built into the mesh
G.cv.native = { GetBool = function() return false end }
G.Native = { Available = function() return false end, oxyInData = true }
G.Surfaces = { IsGround = function() return false end }
G.cv.trail = G.cv.trail or { GetFloat = function() return 1 end }
G.Light.Get = function() return { dir = Vector(0, 0, 1), col = Vector(0.1, 0.1, 0.1), amb = Vector(0.1, 0.1, 0.1) } end
G.Runs = nil
M.Load({ "cl_particles.lua" })
local P = G.Particles
local function DrawOnly(list)
	P.Clear()
	for _, q in ipairs(list) do P.Spawn({ pos = q, vel = Vector(0, 0, -1), r = 1, prio = true }) end
	vtx = 0
	frame = frame + 1
	P.Draw()
	return vtx / 4
end
check(DrawOnly({ Vector(60, 0, 64) }) == 1, "a drop straight ahead is drawn")
check(DrawOnly({ Vector(-60, 0, 64) }) == 0, "a drop behind the camera is not")
check(DrawOnly({ Vector(0, 60, 64) }) == 0, "a drop right beside the camera (90 degrees off) is not")
-- the screen's corner: 45 degrees across, 25 up at fov 90 / 16:9
local c = Vector(60, 60 * math.tan(math.rad(44)), 64 + 60 * math.tan(math.rad(24)))
check(DrawOnly({ c }) == 1, "a drop in the corner of the screen still is")
check(DrawOnly({ Vector(5, 8, 66) }) == 1, "a drop right at the camera is kept")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
