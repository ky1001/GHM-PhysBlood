-- (1.26.8, 27 Oct) a player: "the performance got way worse since the new update - I used to fight loads of NPCs on
-- ultra with barely any lag, now it gets unbearably laggy even with the settings on low". What 1.26.7 added now follows
-- the quality setting, the frame rate and the size of the fight: the 3D fluid drops (the nearest ones only, the rest in
-- one batch), the VAT bursts and crowns, the continuous streams (budgeted, in view, nearest first, a cheaper shape
-- further off), the spurts, and the Lite pools' growth and mesh rebuilds (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 1
function FrameNumber() return frame end
function LocalPlayer() return NULL end
local eye = Vector(0, 0, 64)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameTime() return 1 / 60 end
function Matrix() return setmetatable({}, { __index = function() return function() end end }) end
local draws3d, batchVerts, batchBegun = 0, 0, 0
local meshDraw = function() draws3d = draws3d + 1 end
_G.render = { SuppressEngineLighting = function() end, SetModelLighting = function() end, SetLocalModelLights = function() end,
	SetMaterial = function() end, GetRenderTarget = function() return nil end, GetViewSetup = function() return { fov = 90 } end }
_G.cam = { PushModelMatrix = function() end, PopModelMatrix = function() end }
_G.MATERIAL_TRIANGLES, _G.MATERIAL_QUADS, _G.MATERIAL_LIGHT_DIRECTIONAL = 2, 3, 2
local prim
_G.mesh = { Begin = function(p, n) prim = p batchBegun = batchBegun + n end, End = function() end, Position = function() end,
	Normal = function() end, TexCoord = function() end, TangentS = function() end, TangentT = function() end, UserData = function() end,
	AdvanceVertex = function() batchVerts = batchVerts + 1 end }
G.Prof = { Count = function() end, Lap = function() end, cavg = {}, avg = {}, frame = { avg = 16 } }
function CreateMaterial(name) return setmetatable({ name = name }, { __index = function() return function() return Vector(1, 1, 1) end end }) end
local Vmeta = getmetatable(Vector(0, 0, 0))
Vmeta.Angle = function(self) local d = self:GetNormalized() return { Forward = function() return d end, RotateAroundAxis = function() end } end
M.Load({ "cl_util.lua", "cl_battle.lua", "cl_governor.lua", "cl_vat.lua" })
local V, Gov = G.VAT, G.Gov

-- ---------------- the detail level
local function Q(q) G.cv.quality:SetInt(q) end
Gov.p, G.Battle.level = 0, 0
Q(4) local u = Gov.Detail()
Q(2) local m = Gov.Detail()
Q(1) local l = Gov.Detail()
check(u == 1 and m == 0.6 and l == 0.3, string.format("detail by quality: ultra %.2f, medium %.2f, low %.2f", u, m, l))
Q(4) G.Battle.level = 1
local ubq = Gov.Detail()
check(ubq == 1, string.format("a big fight at a steady frame rate on ultra: full detail (%.2f)", ubq))
Gov.p = 1
local ub = Gov.Detail()
check(math.abs(ub - 0.25) < 1e-6, string.format("a big fight with the frame slow: a quarter (%.2f)", ub))
G.Battle.level, Gov.p = 0, 0
-- (1.26.8) the pressure comes down when the frame meets the target, also with the frame rate locked at it (fps_max 60:
-- it only ever went up and stayed, and the detail with it)
do
	local cvs = { ghmpb_perf_adapt = 1 }
	local gcv = GetConVar
	local fm = { GetFloat = function() return 60 end }
	GetConVar = function(n) if n == "fps_max" then return fm end return gcv(n) end
	if G.cv.perffps then G.cv.perffps:SetFloat(60) end
	if G.cv.perfadapt then G.cv.perfadapt:SetBool(true) end
	system = system or {}
	local hf = system.HasFocus
	system.HasFocus = function() return true end
	Gov.p = 1
	G.Prof.frame.avg = 16.8
	local bu = G.Battle.Update
	G.Battle.Update = function() end
	G.Prof.cavg["bodies live"] = 3   -- (blood about: the pressure would not come down for want of blood)
	local rt = RealTime
	for _ = 1, 10 do M.now = M.now + 0.6 Gov.Update() end
	G.Battle.Update = bu
	G.Prof.cavg["bodies live"] = nil
	check(Gov.p < 0.5, string.format("locked at 60 fps with blood about: the pressure comes down (1.00 -> %.2f in 6 s)", Gov.p))
	GetConVar, system.HasFocus = gcv, hf
	Gov.p, G.Prof.frame.avg = 0, 16
end

-- ---------------- the 3D drops: only the nearest, within reach, up to the budget; the rest in one batch
V.DropsReady = function() return true end
local fakeMesh = { Draw = meshDraw }
local fakeE = { state = "ready", fps = 30, frames = { {}, {} }, meshes = { fakeMesh, fakeMesh } }
V.effects = { drop01 = fakeE, drop02 = fakeE, drop03 = fakeE, drop04 = fakeE, drip01 = fakeE }
G.Light = { Get = function() return { dir = Vector(0, 0, -1), col = Vector(1, 1, 1), amb = Vector(0.2, 0.2, 0.2), r = { 0, 0, 0, 0 }, g = { 0, 0, 0, 0 }, b = { 0, 0, 0, 0 } } end }
G.GPU = { Mat = function() return {} end, SetC = function() end }
G.Native = { Available = function() return false end, Count = function() return 0 end }
G.BloodHue = function() return 0 end
G.BloodAbsorb = function() return 1 end
G.Runs = nil
M.Load({ "cl_particles.lua" })
local P = G.Particles
local function Fill(n)
	for i = #P.list, 1, -1 do P.list[i] = nil end
	for i = 1, n do
		local d = 30 + (i / n) * 2900       -- spread 30..2930 u ahead
		P.list[i] = { x = d, y = (i % 7) - 3, z = 40, vx = 0, vy = 0, vz = -50, r = 1.2, stretch = 1, btype = 0, oxy = 0.75 }
	end
end
local function DrawOnce()
	draws3d, batchVerts, batchBegun = 0, 0, 0
	frame = frame + 1
	P.Draw()
	return draws3d, batchVerts / 4, batchBegun
end
Fill(2000)
Q(4)
local d3, batched, begun = DrawOnce()
check(d3 <= 220 and d3 > 0, "ultra, quiet: up to 220 drops as 3D meshes (" .. d3 .. ")")
check(batched == begun and batched + d3 == P.drawn and batched > 0, string.format("every other drop drawn in the batch (%d + %d = %d)", d3, batched, P.drawn))
check(P.drawn3d == d3, "and counted")
-- the meshes go to the nearest drops
local d3x, real3d = 0, V.DrawDrops3D
V.DrawDrops3D = function(n, BX, BY, BZ, ...)
	local idx = select(9, ...)
	for c = 1, n do d3x = math.max(d3x, BX[idx[c]]) end
	return real3d(n, BX, BY, BZ, ...)
end
DrawOnce()
V.DrawDrops3D = real3d
check(d3x > 0 and d3x < 30 + 2900 * 230 / 2000, string.format("the nearest drops (the 220 nearest of 2000 spread to 2930 u: all within %.0f u)", d3x))
Q(2)
local d3m = DrawOnce()
check(d3m <= 132, "medium: up to 132 (" .. d3m .. ")")
Q(4) G.Battle.level, Gov.p = 1, 1
local d3b = DrawOnce()
check(d3b <= 55, "a big fight on ultra with the frame slow: up to 55 (" .. d3b .. ")")
G.Battle.level, Gov.p = 0, 0
-- only within 900 u: drops all far away get none
for i, p in ipairs(P.list) do p.x, p.y, p.z = 850 + (i % 200), 0, 40 p.r = 3 end
local d3f, bf = DrawOnce()
check(d3f == 0 and bf == P.drawn, "drops all past 800 u: none as meshes, all in the batch (" .. d3f .. ", " .. bf .. ")")

-- ---------------- VAT bursts: fewer and nearer with less detail
V.On = function() return true end
V.Ready = function() return true end
V.effects = { b1 = { state = "ready", radius = 10, fps = 30, frames = { {} }, meshes = {} } }
V.KINDS = V.KINDS or {}
V.KINDS.back = { "b1" }
V.KINDS.crown = { "b1" }
V.inst = {}
Q(4)
for i = 1, 60 do V.Spawn("back", Vector(100 + i, 0, 40), Vector(1, 0, 0), 1, 1, 0) end
local capU = #V.inst
V.inst = {}
Q(4) G.Battle.level, Gov.p = 1, 1
for i = 1, 60 do V.Spawn("back", Vector(100 + i, 0, 40), Vector(1, 0, 0), 1, 1, 0) end
local capB = #V.inst
check(capU == 28 and capB <= 8, string.format("bursts at once: %d quiet on ultra, %d in a big fight with the frame slow", capU, capB))
V.inst = {}
local farCrown = V.Spawn("crown", Vector(1200, 0, 0), Vector(0, 0, 1), 1, 1, 0)
check(farCrown == nil, "a splash crown 12 m off in a big fight: not played")
G.Battle.level, Gov.p = 0, 0

-- ---------------- the streams: a budget, in view, nearest first, cheaper further off
G.VAT.Mat = function() return {} end
G.VAT.cvSize = { GetFloat = function() return 1 end }
G.VAT.ApplyLight = function() end
G.Wounds = G.Wounds or { bodies = {} }
M.Load({ "cl_streams.lua" })
local St = G.Streams
local function Stream(key, x, y)
	local s = { pts = {}, btype = 0, k = 1, feedUntil = M.now + 1, lastSample = 0, phase = 0 }
	for i = 1, 26 do s.pts[i] = { x = x + i * 2, y = y, z = 60 - i, vx = 200, vy = 0, vz = -50, t = M.now - (26 - i) * 0.004, sp = 200 } end
	St.list[key] = s
end
local function DrawStreams()
	batchVerts, batchBegun = 0, 0
	frame = frame + 1
	St.Draw()
	return batchVerts
end
Q(4)
for i = 1, 14 do Stream("s" .. i, 60 + i * 40, (i % 3) * 10) end
local vU = DrawStreams()
check(prim == MATERIAL_QUADS, "built of quads")
check(vU <= St.QUAD_BUDGET * 4 and vU > 0, string.format("14 streams on ultra: %d vertices (1.26.7: up to 12 600)", vU))
Q(2) G.Battle.level, Gov.p = 1, 1
local vB = DrawStreams()
check(vB <= math.max(120, math.floor(St.QUAD_BUDGET * 0.15)) * 4 and vB < vU / 4, string.format("medium in a big fight, the frame slow: %d vertices", vB))
G.Battle.level, Gov.p = 0, 0
St.Clear()
Stream("behind", -400, 0)
check(DrawStreams() == 0, "a stream behind the camera: not drawn")
St.Clear()
Stream("near", 60, 0)
local vNear = DrawStreams()
St.Clear()
Stream("mid", 600, 0)
local vMid = DrawStreams()
check(vNear > vMid * 2, string.format("near: a full tube (%d vertices), further off a half tube turned to the camera (%d)", vNear, vMid))
St.Clear()

-- ---------------- (1.26.8, second pass) a player after the first pass: "i dont see a huge diffrence, and with mag dumping
-- the blood renders very late and performance not good" (ghmpb_prof, Lite: the drop landings 4 ms a frame, the rivulets up
-- to 62 ms, the Lite update up to 12 ms)

-- the drops' traces: a share of the drops each frame, in turn (1.26.7 traced the first 900 in the list: the newest drops
-- of a magazine dump flew on untraced and landed late), as many as fit into the time
P.Clear()
local realSys = SysTime
SysTime = os.clock
local tlMock = util.TraceLine
local nTrace = 0
util.TraceLine = function(t) nTrace = nTrace + 1 local e = os.clock() + 20e-6 while os.clock() < e do end return tlMock(t) end
local x0 = {}
for i = 1, 1200 do
	local p = P.Spawn({ pos = Vector(-100 + (i % 40) * 5, (i % 30) * 5 - 75, 500), vel = Vector(60, 0, 0), r = 0.3, broke = true, ownerGrace = 0 })
	x0[p] = p.x
end
check(P.Count() == 1200, "1200 drops in flight (" .. P.Count() .. ")")
local most = 0
for f = 1, 12 do
	frame = frame + 1
	M.now = M.now + 1 / 60
	nTrace = 0
	P.Step(1 / 60)
	if f > 2 then most = math.max(most, nTrace) end
end
local never = 0
for _, p in ipairs(P.list) do if p.tx == x0[p] then never = never + 1 end end
check(never == 0, "every drop traced within 12 frames (" .. never .. " of " .. P.Count() .. " never)")
check(most < 600 and most >= 150, string.format("traces a frame: %d (what fits into about 2 ms at 20 us a trace; 1.26.7: 900)", most))
util.TraceLine = tlMock
SysTime = realSys
P.Clear()

-- the extras of a landing (tail, satellites, splash ring, bounced drops): only so many landings a frame get them
local impacts = 0
G.Surfaces = G.Surfaces or {}
local sImp, sIsG = G.Surfaces.Impact, G.Surfaces.IsGround
G.Surfaces.Impact = function() impacts = impacts + 1 return true end
G.Surfaces.IsGround = function() return false end
local landTr = { Hit = true, HitWorld = true, HitPos = Vector(100, 0, 0), HitNormal = Vector(0, 0, 1), MatType = MAT_CONCRETE }
local function OneLanding()
	impacts = 0
	P.Land({ vel = Vector(600, 0, -250), r = 1.4, v = 11.5, stretch = 1, spin = 0, oxy = 0.75, btype = 0, flags = 0 }, landTr)
	return impacts
end
frame = frame + 1
Q(4)
local first = OneLanding()
for _ = 1, 100 do OneLanding() end
local late = OneLanding()
check(first > 1 and late == 1, string.format("a fast oblique landing: %d stains with its tail and satellites; the 102nd landing in one frame: %d", first, late))
frame = frame + 1
check(OneLanding() == first, "the next frame: the extras again")
G.Surfaces.Impact, G.Surfaces.IsGround = sImp, sIsG

-- the light of a stain / pool / rivulet head: one engine sample shared by everything within 24 u that faces the same
-- way, at most 6 new samples a frame (1.26.7: render.ComputeLighting for every Lite stain)
local lightCalls = 0
render.ComputeLighting = function() lightCalls = lightCalls + 1 return Vector(0.5, 0.4, 0.3) end
util.GetSunInfo = function() return nil end
M.Load({ "cl_lighting.lua" })
local Lt = G.Light
frame = frame + 1
local up = Vector(0, 0, 1)
for i = 1, 50 do Lt.At(Vector(1 + (i % 20), 2 + (i % 7), 0), up) end
check(lightCalls == 1, "50 stains on one spot of floor: 1 light sample (" .. lightCalls .. ")")
Lt.At(Vector(1, 2, 0), Vector(1, 0, 0))
check(lightCalls == 2, "a wall there faces another way: its own sample")
lightCalls = 0
frame = frame + 1
for i = 1, 20 do Lt.At(Vector(500 + i * 100, 0, 0), up) end
check(lightCalls == 6, "20 new spots in one frame: 6 samples, the rest share the last one (" .. lightCalls .. ")")
frame = frame + 1
Lt.At(Vector(500 + 15 * 100, 0, 0), up)
check(lightCalls == 7, "the next frame: a sample for a spot still without one")
M.now = M.now + 3.5
frame = frame + 1
Lt.At(Vector(1, 2, 0), up)
check(lightCalls == 8, "after 3 s: sampled again (the light may have changed)")

-- the rivulets: fewer heads at once with less detail; with Lite a trail stamp every 1.2 u (a quad each), not every 0.3 u
G.Surface = G.Surface or {}
M.Load({ "cl_runs.lua" })
local R = G.Runs
Gov.p, G.Battle.level = 0, 0
Q(4)
check(R.MaxHeads() == 80, "rivulet heads at once: 80 on ultra")
Q(1) G.Battle.level, Gov.p = 1, 1
check(R.MaxHeads() < 30, "low, a big fight, the frame slow: " .. R.MaxHeads())
Q(4) G.Battle.level, Gov.p = 0, 0
local stamps = 0
G.Surfaces = { Impact = function(_, _, _, _, _, kind) if kind == 7 then stamps = stamps + 1 end return true end, GroundFilter = function() return true end,
	GetPatch = function() return nil end }
G.Particles.Hang = function() end
M.wallX = 600
local tlRuns = util.TraceLine
util.TraceLine = function(t)   -- (the engine fills t.output when given one)
	local r = tlRuns(t)
	if t.output then for k in pairs(t.output) do t.output[k] = nil end for k, v in pairs(r) do t.output[k] = v end return t.output end
	return r
end
local function Stamps(lite)
	R.Clear()
	G.Lite = { on = lite }
	stamps = 0
	local plane = { N = Vector(-1, 0, 0), plane = "wall", surf = G.Surface.sealed }
	R.SpawnHead(plane, Vector(599.98, 0, 120), 400, 0.75, 0, nil, Vector(0, 0, -1), 1)
	for _ = 1, 120 do M.now = M.now + 1 / 60 R.Step(1 / 60) end
	local h = R.heads[1]
	return stamps, h and h.dist or 0
end
local sShader, dShader = Stamps(false)
local sLite, dLite = Stamps(true)
check(sShader > 0 and sLite > 0 and sLite * 3 <= sShader, string.format("a rivulet running %.0f u: %d trail stamps with the shaders, %d with Lite", dShader, sShader, sLite))
M.wallX = nil
G.Lite = nil
util.TraceLine = tlRuns

-- ---------------- (1.26.8, third pass) with the shaders: frames of 41-51 ms (".rb capture (gpu wait)", ".world impacts",
-- "wounds") and 1 ms a frame for the 3D drops, on Ultra
-- new render-target slots a frame: as many as fit into 6 ms, at least one (up to 32 before)
M.Load({ "cl_budget.lua" })
local B = G.Budget
frame = frame + 1
check(B.MayCreateNow(), "a new slot: allowed")
B.NoteCreated(8)
check(not B.MayCreateNow(), "after one that took 8 ms: no more this frame")
frame = frame + 1
check(B.MayCreateNow(), "the next frame: again")
B.NoteCreated(1) B.NoteCreated(1)
check(B.MayCreateNow(), "two quick ones (2 ms): a third may follow")
B.NoteCreated(4.5)
check(not B.MayCreateNow(), "past 6 ms: no more")
-- 3D drops and streams: steeper with less detail
Q(4) G.Battle.level, Gov.p = 1, 1
local b3 = V.Drops3DBudget()
check(b3 <= 30, "3D drops in a big fight on ultra: " .. b3 .. " (55 before)")
check(V.Drops3DDist() <= 500, "within " .. V.Drops3DDist() .. " u")
G.Battle.level, Gov.p = 0, 0
check(V.Drops3DBudget() == 220 and V.Drops3DDist() == 800, "ultra, quiet: 220 within 800 u")

-- ---------------- (1.26.8) no fluid bursts while a head hit is worked out (V.mute, set by cl_wounds.lua)
V.On = function() return true end
V.Ready = function() return true end
V.effects = { b1 = { state = "ready", radius = 10, fps = 30, frames = { {} }, meshes = {} } }
V.KINDS.back, V.KINDS.jet, V.KINDS.spray = { "b1" }, { "b1" }, { "b1" }
V.inst = {}
Q(4) G.Battle.level = 0
V.mute = true
local mb = V.Spawn("back", Vector(100, 0, 40), Vector(1, 0, 0), 1, 1, 0)
local ms = V.Spawn("spray", Vector(100, 0, 40), Vector(1, 0, 0), 1, 1, 0)
local mj = V.Spawn("jet", Vector(100, 0, 40), Vector(1, 0, 0), 1, 1, 0)
V.mute = false
local ub = V.Spawn("back", Vector(100, 0, 40), Vector(1, 0, 0), 1, 1, 0)
check(mb == nil and ms == nil and mj ~= nil and ub ~= nil, "muted (a head hit): no entry or spray burst, the wound's jet still; not muted: the burst")

-- ---------------- (1.26.8, fifth pass) a drop landing cost 0.2-0.25 ms besides its stains, with the shaders and with Lite:
-- V.On() looked for the VAT data on disk (file.Exists: a search through every mounted addon) on every landing
local fsCalls = 0
local fe = file.Exists
file.Exists = function(...) fsCalls = fsCalls + 1 return true end
M.now = M.now + 11
for _ = 1, 100 do V.Installed() end
check(fsCalls == 1 and V.Installed(), "the VAT data looked for on disk once, not on every call (" .. fsCalls .. " for 100)")
file.Exists = fe

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
