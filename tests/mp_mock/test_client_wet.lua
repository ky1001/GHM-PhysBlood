-- (1.26.6, 27 Oct) fresh blood looks wet: runs, spatter and their heads (client, mocked GMod)
--   fresh blood gets more of the shaders' wetness (G.FreshWet), run trails and beads go in as wet blood, stamped spatter is a
--   wet film, the spatter pattern drops keep their shape, run heads are small domes lit by the surface they lie on, and the
--   droplets' light probe is never inside a wall
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function EyePos() return Vector(0, -100, 64) end
math.Round = math.Round or function(x, d) local m = 10 ^ (d or 0) return math.floor(x * m + 0.5) / m end
function LocalPlayer() return NULL end
function GetConVarNumber(n) return n == "sv_gravity" and 600 or 0 end
_G.MASK_OPAQUE = 1
local litCalls = 0
_G.render = { GetViewSetup = function() return { fov = 90 } end,
	ComputeLighting = function(pos, n) litCalls = litCalls + 1 return Vector(0.8, 0.7, 0.6) end }
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
_G.util.PointContents = function() return 0 end
G.U = G.U or {}
M.Load({ "cl_util.lua" })
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end, Caps = function() return { patches = 999, aft = 999 } end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua", "cl_surfaces.lua" })
local S = G.Surfaces

-- ---------------- fresh wetness
local coag = G.CoagTime()
local f0, f1, f2 = G.FreshWet(5), G.FreshWet(coag * 0.7), G.FreshWet(coag * 1.2)
print(string.format("     fresh wetness: just landed x%.2f, at 70 %% of the clotting time x%.2f, clotted x%.2f", f0, f1, f2))
check(math.abs(f0 - 2.5) < 1e-6 and f1 > 1 and f1 < f0 and f2 == 1, "fresh blood looks 2.5 x as wet, fading out until it has clotted")
G.cv.freshwet:SetFloat(1)
check(G.FreshWet(5) == 1, "Fresh blood wetness 1: only the Wetness setting")
G.cv.freshwet:SetFloat(2.5)
local function pool(c) return math.floor(c / 64) end
check(pool(S.LookPair(3, nil, false)) == 10 and pool(S.LookPair(3, nil, false, 2.5)) == 25, "the shaders get wetness 1.0 (old blood) / 2.5 (fresh)")
G.cv.poollook:SetFloat(2)
check(pool(S.LookPair(3, nil, false, 2.5)) == 31, "never past what the shaders take (3.1)")
G.cv.poollook:SetFloat(0)
check(pool(S.LookPair(3, nil, false, 2.5)) == 0, "Wetness 0 stays 0")
G.cv.poollook:SetFloat(1)

-- ---------------- run trails keep their stain share
local P = S.PATCH_UNITS
local N, U, V = Vector(0, 0, 1), Vector(1, 0, 0), Vector(0, 1, 0)
local plane = string.format("%d,%d,%d,%d", 0, 0, 40, 0)
local origin = Vector(0, 0, 0)
local pt = { key = plane .. "|0|0", plane = plane, i = 0, j = 0, N = N, U = U, V = V, origin = origin,
	center = origin + U * (P * 0.5) + V * (P * 0.5), cur = 1, impacts = {}, touched = 0, wetUntil = 0, hasBlood = true,
	oxy = 0.75, btype = 0, surfName = "concrete", surf = G.Surface.concrete }
S.patches[pt.key] = pt
S.IndexAdd(pt)
G.Runs = nil
S.Impact(Vector(20, 20, 0), N, Vector(2, 0, 0), 0.1, 2, 7, 0, 1, 0.15, nil, 0.7, 0)
S.Impact(Vector(20, 20, 0), N, Vector(0, 0, -100), 0.3, 2, 0, 0, 1, 0.22, nil, 0.7, 0)
check(pt.impacts[1] and math.abs(pt.impacts[1].residue - 0.15) < 1e-6, "a run trail goes in as 15 % stain (was raised to 38 %)")
check(pt.impacts[2] and math.abs(pt.impacts[2].residue - 0.38) < 1e-6, "splats keep their 38 % minimum")

-- ---------------- runs: trail, bead, heads
local impacts = {}
G.Surfaces = { PATCH_UNITS = 40, after = {}, patches = {},
	GroundFilter = function() return true end, IsGround = function() return false end, GetPatch = function() return nil end,
	Impact = function(pos, n, vel, R, vol, kind, spin, stretch, residue, tr, oxy, btype, extra)
		impacts[#impacts + 1] = { pos = Vector(pos), n = Vector(n), vel = Vector(vel), R = R, vol = vol, kind = kind, stretch = stretch,
			residue = residue, extra = extra } return true end }
G.Particles = { Hang = function() end }
G.Light.Get = function() return { dir = Vector(0, 0, 1), col = Vector(0.5, 0.5, 0.5), sunVis = 1, sunDir = Vector(0.3, 0, 0.95), sunCol = Vector(1, 0.94, 0.84) } end
M.Load({ "cl_runs.lua" })
local R = G.Runs
local wallN = Vector(1, 0, 0)
local wp = { plane = "w", N = wallN, surf = G.Surface.plaster }
R.heads = {}
R.SpawnHead(wp, Vector(0, 0, 100), 480, 0.7, 0, nil, Vector(0, 0, -1), 1)
R.SpawnHead(wp, Vector(0, 30, 100), 3, 0.7, 0, nil, Vector(0, 0, -1), 1)
local drawn = {}
R.Draw(function(x, y, z, vx, vy, vz, rmm, st, bt, oq, onSurf) drawn[#drawn + 1] = { x = x, r = rmm, on = onSurf } end)
check(#drawn == 2 and drawn[1].r <= 1.5 and drawn[2].r < 1, string.format("run heads are small domes: 0.48 ml -> %.2f mm, 3 ul -> %.2f mm (were %.1f / %.1f mm)",
	drawn[1].r, drawn[2].r, (480 / 4.18879) ^ (1 / 3) * 0.85, (3 / 4.18879) ^ (1 / 3) * 0.85))
check(drawn[1].on == true and drawn[2].on == true, "marked as lying on a surface")
check(drawn[1].x - 0 < drawn[1].r * G.MM_TO_UNITS * 0.5, "sitting on the wall, not standing off it")
local rl = R.HeadLight(Vector(-100, 0, 100))
check(rl and math.abs(rl.amb.x - 0.8) < 1e-6 and math.abs(rl.amb.z - 0.6) < 1e-6, "they are lit with the light the wall gets there")
check(rl and rl.dir.z > 0.9 and rl.col.x > 0, "and the sun for their highlight")
local c0 = litCalls
R.HeadLight(Vector(-100, 0, 100))
check(litCalls == c0, "the surface light is kept a moment, not worked out every frame")
-- trail and bead
impacts = {}
local h = R.heads[1]
h.acc = 5
h.last = h.pos + Vector(0, 0, 1)
R.heads = { h }
-- (Trail is local: a run that stops paints its trail and its bead)
h.vol = 2.6
h.speed, h.pause, h.age, h.slowT = 0, 0, 2, 2
R.Step(1 / 30)
local trail, bead
for _, im in ipairs(impacts) do if im.kind == 7 then trail = im elseif im.kind == 0 then bead = im end end
check(trail and math.abs(trail.residue - 0.15) < 1e-6, "the trail is asked for as 15 % stain")
local hb = bead and bead.vol / (2.0944 * (bead.R * 19.05) ^ 2 * (bead.stretch or 1))
check(bead and hb < 0.5 and bead.extra and bead.extra.K and bead.extra.K > 1.5, string.format("the bead at the end is flat (%.2f mm deep, was up to 2 mm) and wet", hb or -1))

-- ---------------- stamped spatter: a wet film, the drops keep their shape
G.Surfaces = { Impact = function(pos, n, vel, R, vol, kind, spin, stretch, residue, tr, oxy, btype, extra)
	impacts[#impacts + 1] = { pos = pos, n = n, vel = vel, R = R, vol = vol, kind = kind, stretch = stretch } return true end,
	IsGround = function() return true end }
G.Entities = { Impact = function() return true end }
G.Particles = { Spawn = function() end, Thin = function() return 1 end, Count = function() return 0 end }
M.Load({ "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local F = G.Forensic
M.now = M.now + 10
impacts = {}
F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 0, 0.8, nil, 1)
local nd, round, thin, minH, hs = 0, 0, 0, 1e9, {}
for _, im in ipairs(impacts) do
	if im.kind == 0 then
		nd = nd + 1
		local sinA = math.abs(im.vel:GetNormalized():Dot(im.n))
		local e = math.min(1 / math.max(sinA, 0.12), 8) * (im.stretch or 1)
		if e < 2 then round = round + 1 end
		local hmm = im.vol / (2.0944 * (im.R * 19.05) ^ 2 * e)
		minH = math.min(minH, hmm)
		hs[#hs + 1] = hmm
	end
end
table.sort(hs)
print(string.format("     a pattern straight onto a wall: %d drops, %d of them round, films %.3f mm (thinnest) .. %.3f mm (median)", nd, round, minH, hs[math.floor(#hs / 2) + 1] or 0))
check(nd > 15 and round > nd * 0.7, "hit straight on, most drops are round stains (they were all 3.5 : 1 streaks)")  -- (1.26.7) fewer drops: the fine spray is the CRB decal
check(minH >= 0.03, "every drop is at least a wet film (were films of a few microns)")
-- at a grazing angle they are drawn out along the travel
impacts = {}
M.now = M.now + 10
F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(0.35, 0.94, 0):GetNormalized(), 14, 0, 0.8, nil, 1)
local along, n0 = 0, 0
for _, im in ipairs(impacts) do
	if im.kind == 0 then
		n0 = n0 + 1
		local t = im.vel - im.n * im.vel:Dot(im.n)
		if t:Length() > 1 and math.abs(t:GetNormalized().y) > 0.95 then along = along + 1 end
	end
end
check(along > 15 and along >= n0 * 0.8, "at a grazing angle the drops are drawn out the way the blood travelled (" .. along .. " of " .. n0 .. ")")
-- the exit plume's stains too
impacts = {}
M.wallX = 70
M.now = M.now + 10
F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), F.BALLISTIC.pistol, 1, 0, 0.8, 1)
M.Advance(1)
local pmin = 1e9
for _, im in ipairs(impacts) do
	if im.kind == 0 and im.R > 0.3 then
		local sinA = math.abs(im.vel:GetNormalized():Dot(im.n))
		local e = math.min(math.min(1 / math.max(sinA, 0.12), 8) * (im.stretch or 1), 3.5)
		pmin = math.min(pmin, im.vol / (2.0944 * (im.R * 19.05) ^ 2 * e))
	end
end
check(pmin < 1e8 and pmin >= 0.03, string.format("exit plume stains are wet films too (thinnest %.3f mm)", pmin))

-- ---------------- droplet light probe
local wallX = 50
util.TraceLine = function(t)
	local out = t.output or {}
	local s, e = t.start, t.endpos
	if s.x < wallX and e.x >= wallX then
		local f = (wallX - s.x) / (e.x - s.x)
		out.Hit, out.StartSolid, out.HitPos, out.HitNormal, out.Fraction = true, false, s + (e - s) * f, Vector(-1, 0, 0), f
	else
		out.Hit, out.StartSolid, out.HitPos, out.Fraction = false, false, Vector(e), 1
	end
	return out
end
local pp = G.Light.ViewProbePos(Vector(0, 0, 64), Vector(1, 0, 0), 100)
check(pp.x < wallX - 2, string.format("camera 50 u from a wall: the drops are lit in front of it (x = %.0f), not inside it (x = 100)", pp.x))
local pf = G.Light.ViewProbePos(Vector(0, 0, 64), Vector(0, 1, 0), 100)
check(math.abs(pf.y - 100) < 1e-6, "nothing in the way: 100 u in front of the camera as before")

-- ---------------- drawing: run heads in their own batch, with the surface's light
local M2 = dofile("gmod.lua")
GHMPB = nil
_G.SERVER, _G.CLIENT = false, true
M2.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G2 = GHMPB
function EyePos() return Vector(0, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameTime() return 1 / 60 end
local mats, consts, batches, curMat = {}, {}, {}, nil
_G.render = { GetViewSetup = function() return { fov = 90 } end, SetMaterial = function(m) curMat = m end,
	ComputeLighting = function() return Vector(0.5, 0.5, 0.5) end }
_G.mesh = { Begin = function(_, cnt) batches[#batches + 1] = { mat = curMat, n = cnt } end, End = function() end,
	Position = function() end, TexCoord = function() end, AdvanceVertex = function() end }
_G.util.PointContents = function() return 0 end
G2.U = G2.U or {}
M2.Load({ "cl_util.lua" })
G2.cv.native = { GetBool = function() return false end }
G2.Native = { Available = function() return false end, oxyInData = true }
G2.Gov = nil
G2.Surfaces = { IsGround = function() return false end }
G2.cv.trail = G2.cv.trail or { GetFloat = function() return 1 end }
G2.GPU = { Mat = function(tag) local m = { tag = tag } mats[tag] = m return m end,
	SetC = function(m, i, x, y, z, w) consts[m.tag .. i] = { x, y, z, w } end }
local lightAt
G2.Light = { Get = function(key, pos) if key == "drops" then lightAt = pos end
	return { dir = Vector(0, 0, 1), col = Vector(0.1, 0.1, 0.1), amb = Vector(0.05, 0.05, 0.05) } end,
	ViewProbePos = function(eye, fwd, d) return eye + fwd * 40 end }
G2.Runs = { Count = function() return 1 end,
	Draw = function(add) add(60, 0, 64, 0, 0, -1, 1.2, 1.3, 0, 7, true) end,
	HeadLight = function() return { amb = Vector(0.9, 0.8, 0.7), dir = Vector(0, 0, 1), col = Vector(0.3, 0.3, 0.3), bt = 0 } end }
M2.Load({ "cl_particles.lua" })
local P2 = G2.Particles
P2.Spawn({ pos = Vector(60, 2, 70), vel = Vector(0, 0, -100), r = 0.6 })
P2.Spawn({ pos = Vector(60, -2, 70), vel = Vector(0, 0, -100), r = 0.6 })
P2.Draw()
local byTag = {}
for _, b in ipairs(batches) do byTag[b.mat and b.mat.tag or "?"] = (byTag[b.mat and b.mat.tag or "?"] or 0) + b.n end
print(string.format("     batches: drops %d, run heads %d", byTag.drops or 0, byTag.dropsrun or 0))
check((byTag.dropsrun or 0) == 1 and (byTag.drops or 0) == (P2.drawn or 0) - 1 and (byTag.drops or 0) >= 2, "the run head is drawn in its own batch, the flying drops in theirs")
local c3 = consts["dropsrun3"]
check(c3 and math.abs(c3[1] - 0.9) < 1e-6 and math.abs(c3[3] - 0.7) < 1e-6, "lit with the light of the surface it lies on")
check(lightAt and lightAt.x < 50, "the flying drops' light is taken in the open in front of the camera")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
