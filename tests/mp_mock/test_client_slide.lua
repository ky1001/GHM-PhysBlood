-- 1.19.0: fast drops - the stain stretches with the speed along the surface, part of the drop slides on as a droplet that
-- draws a thin rivulet and ends in a bead (floors), or turns into a run (walls); slow drops and ghmpb_drop_slide 0 do neither
-- 1.24.0: ghmpb_drop_slide 1 is a short skid (less blood, a few cm, only from fast flat hits); 2 is the long 1.19 rivulet
-- (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function EyePos() return Vector(0, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameNumber() return 1 end
function GetConVarNumber(n) return n == "sv_gravity" and 600 or 0 end
function VectorRand() return Vector(0, 0, 0) end
function LocalPlayer() return NULL end
_G.MASK_SOLID = 1
_G.util.PointContents = function() return 0 end
G.U = {}
M.Load({ "cl_util.lua" })
G.Wounds = { bodies = {} }
G.Prof = { cavg = {}, frame = { avg = 10 }, avg = {}, Count = function() end, Lap = function() end }
G.cv.native = { GetBool = function() return false end }
G.Water = nil
G.Forensic = nil
G.Gov = nil
G.U.TraceCorpses = function() return nil end

-- the world: planes { p = point, n = normal, lo / hi = box it spans }
local planes = {}
function util.TraceLine(t)
	local s, e = t.start, t.endpos
	local best, bf
	for _, pl in ipairs(planes) do
		local ds, de = (s - pl.p):Dot(pl.n), (e - pl.p):Dot(pl.n)
		if ds >= 0 and de < 0 then
			local f = ds / (ds - de)
			local hp = s + (e - s) * f
			local inside = hp.x >= pl.lo.x - 1e-6 and hp.x <= pl.hi.x + 1e-6 and hp.y >= pl.lo.y - 1e-6 and hp.y <= pl.hi.y + 1e-6
				and hp.z >= pl.lo.z - 1e-6 and hp.z <= pl.hi.z + 1e-6
			if inside and (not bf or f < bf) then best, bf = pl, f end
		end
	end
	local out = t.output or {}
	if best then
		out.Hit, out.Fraction, out.HitPos, out.HitNormal, out.StartSolid, out.HitWorld, out.HitSky = true, bf, s + (e - s) * bf, Vector(best.n), false, true, false
		out.HitTexture, out.MatType = "concrete/floor", 67
	else
		out.Hit, out.Fraction, out.HitPos, out.StartSolid, out.HitWorld = false, 1, Vector(e), false, false
	end
	return out
end
local floor = { p = Vector(0, 0, 0), n = Vector(0, 0, 1), lo = Vector(-500, -500, 0), hi = Vector(500, 500, 0) }
local wall = { p = Vector(0, 0, 0), n = Vector(1, 0, 0), lo = Vector(0, -500, 0), hi = Vector(0, 500, 300) }

local impacts = {}
G.Surfaces = { PATCH_UNITS = 40, after = {}, patches = {},
	GroundFilter = function() return true end, IsGround = function() return false end, GetPatch = function() return nil end,
	Impact = function(pos, n, vel, R, vol, kind, spin, stretch) impacts[#impacts + 1] = { pos = Vector(pos), n = Vector(n), vel = Vector(vel), R = R, vol = vol, kind = kind, stretch = stretch } return true end }
G.Particles = { Hang = function() end }
M.Load({ "cl_particles.lua", "cl_runs.lua" })
local P, R = G.Particles, G.Runs
check(P.Land ~= nil and R.Slide ~= nil, "loaded: P.Land, R.Slide")

local function Drop(vel, v, r)
	return { vel = vel, v = v or 8, r = r or 1.24, stretch = 1, oxy = 0.7, btype = 0, spin = 0, flags = 0 }
end
local function Run(secs)
	for _ = 1, math.floor(secs * 30) do M.now = M.now + 1 / 30 R.Step(1 / 30) end
end
local function Sum(kind) local v = 0 for _, im in ipairs(impacts) do if not kind or im.kind == kind then v = v + im.vol end end return v end

-- ---------------- a fast drop hitting the floor at a slant
planes = { floor }
impacts, R.heads = {}, {}
-- (1.25.1: a flat, fast hit - only a drop that really skims the floor skids on)
local d = Drop(Vector(450, 0, -180))
P.Land(d, { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
local stain = impacts[1]
check(stain and stain.kind == 0, "floor: the stain is painted first")
check(stain and stain.stretch > 1.05 and stain.stretch <= 1.5, string.format("floor: the stain is a little longer with the speed along the floor - at most x 1.5, no long stamped streak (x %.2f)", stain and stain.stretch or 0))
check(#R.heads == 1 and R.heads[1].slide, "floor: a sliding droplet carries on")
local sv = R.heads[1] and R.heads[1].vol or 0
check(math.abs(stain.vol + sv - 8) < 1e-6, string.format("floor: stain %.2f + droplet %.2f = the drop's 8 ul", stain.vol, sv))
check(sv > 0.8 and sv < 2, string.format("floor: about a sixth of the drop skids on (%.2f ul)", sv))
local start = R.heads[1] and Vector(R.heads[1].pos) or Vector(0, 0, 0)
check(start.x > 0.1 and math.abs(start.y) < 1e-6, string.format("floor: it leaves from the front of the stain (x %.2f)", start.x))
Run(3)
check(#R.heads == 0, "floor: the droplet has come to rest")
local trails, beads = 0, 0
local lastX = -1e9
local monotonic = true
for k = 2, #impacts do
	local im = impacts[k]
	if im.kind == 7 then trails = trails + 1 if im.pos.x < lastX - 1e-6 then monotonic = false end lastX = im.pos.x end
	if im.kind == 0 then beads = beads + 1 end
end
check(trails >= 2 and monotonic, string.format("floor: it draws a rivulet along the way it flew (%d trail stamps)", trails))
check(beads == 1 and impacts[#impacts].kind == 0, "floor: and ends in a bead")
local endX = impacts[#impacts].pos.x
check(endX - start.x > 0.4 and endX - start.x < 4, string.format("floor: a short skid - it slid %.1f u (%.0f mm)", endX - start.x, (endX - start.x) * 19.05))
local short = endX - start.x
check(math.abs(Sum() - 8) < 1e-4, string.format("floor: all of the drop's blood is painted (%.4f ul)", Sum()))
check((R.stats.slid or 0) >= 1, "floor: counted (slid)")

-- ---------------- ghmpb_drop_slide 2: the long rivulet of 1.19
G.cv.slide:SetFloat(2)
impacts, R.heads = {}, {}
P.Land(Drop(Vector(400, 0, -250)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
local sv2 = R.heads[1] and R.heads[1].vol or 0
local s2 = R.heads[1] and Vector(R.heads[1].pos) or Vector(0, 0, 0)
Run(3)
local long = impacts[#impacts].pos.x - s2.x
check(sv2 > 2.5 and long > short * 2, string.format("ghmpb_drop_slide 2: the long rivulet (%.2f ul, %.1f u against %.1f u)", sv2, long, short))
-- a drop not fast enough along the floor for a skid at 1 (it did slide at 2)
G.cv.slide:SetFloat(1)
impacts, R.heads = {}, {}
P.Land(Drop(Vector(220, 0, -250)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
check(#R.heads == 0 and #impacts == 1, "ghmpb_drop_slide 1: below 260 u/s along the floor, no skid")
-- (1.25.1) a steeper hit (sin a 0.53) and fine spray on a wall do not skid: their stains stay where they land
impacts, R.heads = {}, {}
P.Land(Drop(Vector(400, 0, -250)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
check(#R.heads == 0, "ghmpb_drop_slide 1: a steeper hit (sin a 0.53) does not skid")
impacts, R.heads = {}, {}
for k = 1, 10 do
	P.Land(Drop(Vector(-500, 30 * k - 150, -300), 2, 0.7), { HitPos = Vector(0, 0, 120), HitNormal = Vector(1, 0, 0), HitWorld = true, HitTexture = "concrete/wall", MatType = 67 })
end
check(#R.heads == 0, "fine fast spray on a wall: no skids (no thin lines)")
-- many skimming drops in one step: only a few skid
impacts, R.heads = {}, {}
P.Step(0.001)
for k = 1, 12 do
	P.Land(Drop(Vector(450, 10 * k, -180)), { HitPos = Vector(0, 40 * k, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
end
check(#R.heads <= 3, "a burst of skimming drops: at most 3 skids a step (" .. #R.heads .. ")")
R.heads = {}

-- ---------------- a bigger drop hitting a wall: it skids along it and slows into a run
planes = { wall, floor }
impacts, R.heads = {}, {}
P.Step(0.001)
local runs0 = R.stats.slideruns or 0
d = Drop(Vector(-250, 0, -420), 60, 2.4)
P.Land(d, { HitPos = Vector(0, 0, 120), HitNormal = Vector(1, 0, 0), HitWorld = true, HitTexture = "concrete/wall", MatType = 67 })
check(#R.heads == 1 and R.heads[1].slide, "wall: a sliding droplet carries on down the wall")
local w0 = R.heads[1] and R.heads[1].vol or 0
Run(1.5)
check((R.stats.slideruns or 0) == runs0 + 1, string.format("wall: it slowed into a run (%.1f ul)", w0))
-- (1.24.0) the run keeps close to straight down: track how far it strays sideways (y) for the way it runs down (z)
local maxTheta, y0, z0 = 0, nil, nil
for _ = 1, 600 do
	M.now = M.now + 1 / 30 R.Step(1 / 30)
	for _, h in ipairs(R.heads) do if not h.slide then maxTheta = math.max(maxTheta, math.abs(h.theta or 0)) end end
end
local ymin, ymax, zmin, zmax = 1e9, -1e9, 1e9, -1e9
for _, im in ipairs(impacts) do
	if im.kind == 7 then
		ymin, ymax = math.min(ymin, im.pos.y), math.max(ymax, im.pos.y)
		zmin, zmax = math.min(zmin, im.pos.z), math.max(zmax, im.pos.z)
	end
end
check(maxTheta <= 0.45 + 1e-9, string.format("wall: the run heads at most %.0f deg off straight down (limit 26)", math.deg(maxTheta)))
check(zmax - zmin > 1 and (ymax - ymin) < 0.35 * (zmax - zmin) + 0.3, string.format("wall: and keeps close to straight down (%.2f u sideways over %.1f u)", ymax - ymin, zmax - zmin))
check(#R.heads == 0, "wall: the run has ended")
check(math.abs(Sum() - 60) < 1e-2, string.format("wall: all of the drop's blood is painted (%.4f ul)", Sum()))

-- ---------------- a slow drop: no stretch, no droplet
planes = { floor }
impacts, R.heads = {}, {}
-- (1.26.6) below the speed of the satellite ring (230 u/s)
P.Land(Drop(Vector(80, 0, -190)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
check(#impacts == 1 and impacts[1].stretch == 1 and #R.heads == 0, "slow drop: a plain stain")

-- ---------------- switched off
G.cv.slide:SetFloat(0)
impacts, R.heads = {}, {}
P.Land(Drop(Vector(400, 0, -250)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "concrete/floor", MatType = 67 })
check(#impacts == 1 and impacts[1].stretch == 1 and #R.heads == 0 and math.abs(impacts[1].vol - 8) < 1e-9, "ghmpb_drop_slide 0: the old stain, no droplet")
G.cv.slide:SetFloat(1)

-- ---------------- carpet drinks it
impacts, R.heads = {}, {}
P.Land(Drop(Vector(400, 0, -250)), { HitPos = Vector(0, 0, 0), HitNormal = Vector(0, 0, 1), HitWorld = true, HitTexture = "carpet/floor", MatType = 67, SurfaceProps = 0 })
local carpetOK = #R.heads == 0 or (R.heads[1].surf.fabric or 0) < 0.6
check(carpetOK, "absorbent surfaces do not let a droplet slide")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
