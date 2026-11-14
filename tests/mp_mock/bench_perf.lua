-- benchmark (not a test): settled-blood drawing, age groups, droplet mesh building
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
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
local nL = 300
for i = 1, nL do
	local a = { key = "k" .. i, plane = "p", i = i, j = 0, N = Vector(0, 0, 1), center = Vector(100 + (i % 20) * 40, (math.floor(i / 20) - 7) * 40, 0), oxy = 0.6, btype = 0,
		albedo = Vector(0.3, 0.3, 0.3), surf = G.Surface.concrete, surfName = "concrete", bakedAt = M.now - 3000, bornT = M.now - 3000,
		aft = { res = 256, rt = { GetName = function() return "rt" .. i end } } }
	a.meshes = { [0.035] = { Draw = function() end } }
	S.after[a.key] = a
	S.IndexAdd(a)
end
for i = 1, 20 do
	local p = { key = "l" .. i, plane = "p", center = Vector(100 + i * 40, 0, 0), hasBlood = true, bornT = M.now, vol = 50 }
	S.patches[p.key] = p
	S.IndexAdd(p)
end
local t0 = os.clock()
for f = 1, 600 do M.now = M.now + 1 / 60 frame = frame + 1 S.DrawStatic() end
local tD = (os.clock() - t0) / 600 * 1000
t0 = os.clock()
for k = 1, 100 do S.groupT = 0 S.ageDirty = true S.UpdateAgeGroups(M.now + k * 0.01) end
local tG = (os.clock() - t0) / 100 * 1000
-- droplets: 3000 drops all round the camera
GHMPB.cv.native = { GetBool = function() return false end }
G.Native = { Available = function() return false end, oxyInData = true }
G.Surfaces = { IsGround = function() return false end }
G.cv.trail = G.cv.trail or { GetFloat = function() return 1 end }
G.Light.Get = function() return { dir = Vector(0, 0, 1), col = Vector(0.1, 0.1, 0.1), amb = Vector(0.1, 0.1, 0.1) } end
G.Runs = nil
M.Load({ "cl_particles.lua" })
local P = G.Particles
GetConVar("ghmpb_max_particles"):SetString("6000")
math.randomseed(3)
for i = 1, 3000 do
	local a = math.random() * 6.283
	local r = 40 + math.random() * 300
	P.Spawn({ pos = Vector(math.cos(a) * r, math.sin(a) * r, 20 + math.random() * 80), vel = Vector(0, 0, -50), r = 0.6, prio = true })
end
vtx = 0
t0 = os.clock()
for f = 1, 60 do frame = frame + 1 P.Draw() end
local tP = (os.clock() - t0) / 60 * 1000
print(string.format("RESULT drawstatic %.3f ms/frame (%d layers) | age groups %.3f ms/pass | drops %.3f ms/frame, %d vertices/frame of %d drops",
	tD, nL, tG, tP, vtx / 60, P.Count()))
