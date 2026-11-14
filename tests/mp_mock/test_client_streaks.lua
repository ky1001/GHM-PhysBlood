-- 1.24.0: no long needle streaks. A drop stain's length / width (1 / sin of the impact angle x the drop's stretch, as the
-- stamp shader works it out) is limited to ghmpb_streak_max; the impact speed is kept, only the angle the stamp sees is
-- steeper. Steep hits are untouched, 10 turns the limit off (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "cl_util.lua" })
local G = GHMPB
local U = G.U

-- the elongation the stamp shader (stamp_ps30, kind 0) and SplatReach work out
local function E(vel, n, stretch)
	local sp = vel:Length()
	local sinA = math.abs(vel:Dot(n)) / sp
	return math.min(math.Clamp(1 / math.max(sinA, 0.12), 1, 8) * math.Clamp(stretch, 1, 8), 10)
end

check(G.cv.streak and G.cv.streak:GetFloat() == 3.5, "ghmpb_streak_max: 3.5 by default")
local floor = Vector(0, 0, 1)
local worst, unchanged, kept, dirOK = 0, true, true, true
for _, deg in ipairs({ 1, 3, 5, 8, 12, 20, 35, 60, 89 }) do
	for _, st in ipairs({ 1, 1.3, 1.6, 2.6, 4 }) do
		local a = math.rad(deg)
		local v = Vector(math.cos(a), 0.2 * math.cos(a), -math.sin(a)) * 900
		local v2, st2 = U.SplatShape(v, floor, st)
		local e2 = E(v2, floor, st2)
		worst = math.max(worst, e2)
		if math.abs(v2:Length() - v:Length()) > 1e-3 then kept = false end
		-- (same way along the floor, still into it)
		local t1 = Vector(v.x, v.y, 0):GetNormalized()
		local t2 = Vector(v2.x, v2.y, 0):GetNormalized()
		if t1:Dot(t2) < 0.9999 or v2.z >= 0 then dirOK = false end
		if E(v, floor, st) <= 3.5 and (v2 ~= v and (v2 - v):Length() > 1e-6 or st2 ~= st) then unchanged = false end
	end
end
check(worst <= 3.5 + 1e-6, string.format("the longest stain at any angle and stretch: %.2f x as long as wide (was up to 10)", worst))
check(kept, "the impact speed is kept (energy, splash, spines)")
check(dirOK, "it still points the way the drop flew, into the surface")
check(unchanged, "stains within the limit are not touched")

-- a wall: the same
local wall = Vector(-1, 0, 0)
local vw = Vector(40, 10, -1500)
local vw2, sw2 = U.SplatShape(vw, wall, 1.6)
check(E(vw2, wall, sw2) <= 3.5 + 1e-6 and vw2.z < -1000 and vw2.x > 0, string.format("a drop running down a wall at 1500 u/s: %.2f x (was %.1f x)", E(vw2, wall, sw2), E(vw, wall, 1.6)))

-- a ligament drop (stretch) is limited too, so a steep hit cannot make a needle either
local vs, ss = U.SplatShape(Vector(0, 0, -500), floor, 6)
check(E(vs, floor, ss) <= 3.5 and ss <= 1.875 + 1e-9, string.format("a straight-down ligament drop (stretch 6): %.2f x", E(vs, floor, ss)))

-- setting: shorter, and 10 = no limit (the old look)
G.cv.streak:SetFloat(2)
local v3, s3 = U.SplatShape(Vector(900, 0, -60), floor, 1)
check(E(v3, floor, s3) <= 2 + 1e-6, "ghmpb_streak_max 2: rounder stains")
G.cv.streak:SetFloat(10)
local v4, s4 = U.SplatShape(Vector(900, 0, -60), floor, 1.6)
check(v4 == Vector(900, 0, -60) or (v4 - Vector(900, 0, -60)):Length() < 1e-9, "ghmpb_streak_max 10: no limit")
check(s4 == 1.6, "(and the stretch as it was)")
G.cv.streak:SetFloat(3.5)

-- odd input: no speed, straight along the surface
local z, sz = U.SplatShape(Vector(0, 0, 0), floor, 1)
check(z:Length() == 0 and sz == 1, "a drop with no speed: as it is")
local g, sg = U.SplatShape(Vector(500, 0, 0), floor, 1)
check(E(g, floor, sg) <= 3.5 + 1e-6 and g.z < 0, "exactly along the floor: steepened into it")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
