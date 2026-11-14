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
M.Load({ "cl_runs.lua" })
local R = G.Runs
-- (1.26.6, 27 Oct) blood pouring off a pool on a slope runs as a few full streams, not a dozen hair-thin threads
local function Pour(N, label)
	R.heads, R.cells = {}, {}
	N = N:GetNormalized()
	local p = { plane = label, N = N, surf = G.Surface.concrete }
	local taken = 0
	for k = 1, 12 do taken = taken + R.Feed(p, Vector(0, 0, 0), 900, 2.2, 1, nil, 0.7, 0) end
	local wsum, n, vmax = 0, #R.heads, 0
	for _, h in ipairs(R.heads) do wsum = wsum + R.Width(h.vol, h.wm) vmax = math.max(vmax, h.vol) end
	return n, n > 0 and wsum / n or 0, vmax, taken
end
local nW, wW, vW = Pour(Vector(1, 0, 0), "wall")
local nS, wS, vS = Pour(Vector(0.7, 0, 0.7), "slope45")
local nG, wG, vG = Pour(Vector(0.42, 0, 0.9), "slope25")
print(string.format("     wall: %d streams, %.1f mm wide, up to %.0f ul | 45 deg: %d, %.1f mm, %.0f ul | 25 deg: %d, %.1f mm, %.0f ul", nW, wW, vW, nS, wS, vS, nG, wG, vG))
check(wS > 1.6 * 3.66 and wG > wS, "streams on slopes are wide (the old ones: about 3.7 mm), wider the gentler the slope")
check(vS > 140 and vG > vS, "they carry more blood each (old: at most 80 ul)")
check(nS <= nW, "no more streams on a slope than on a wall")
check(R.Width(80) > 3.66, "on a wall too a bit wider than before")
-- two streams side by side merge by their widths
R.heads = {}
local N = Vector(0.7, 0, 0.7):GetNormalized()
local p = { plane = "m", N = N, surf = G.Surface.concrete }
planes = { { p = Vector(0, 0, 0), n = N, lo = Vector(-500, -500, -500), hi = Vector(500, 500, 500) } }
R.SpawnHead(p, Vector(0, 0, 0), 300, 0.7, 0, nil, Vector(-0.7, 0, -0.7):GetNormalized(), 0.7)
R.SpawnHead(p, Vector(0, 0.45, 0), 300, 0.7, 0, nil, Vector(-0.7, 0, -0.7):GetNormalized(), 0.7)
R.nextMerge = 0
M.now = M.now + 0.2
R.Step(1 / 30)
local alive = 0 for _, h in ipairs(R.heads) do if not h.dead then alive = alive + 1 end end
check(alive == 1, "two streams 0.45 u apart on a slope touch and merge (" .. alive .. " left)")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
