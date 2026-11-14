-- (1.26.6) the player's own blood colours: defaults change nothing, picks reach the Lua colours and the shader fit
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "cl_util.lua" })
local G, U = GHMPB, GHMPB.U
G.GPU = { FreshAbs = function() return 1.85 * (math.max(G.cv.colFresh:GetFloat(), 0.3) ^ -1.6) end }
local function cv(n, v) GetConVar(n):SetString(tostring(v)) end
local function near(a, b, t) return math.abs(a - b) <= (t or 0.5) end

-- (1.26.6, 27 Oct) the defaults are GHM's colours
check(GetConVar("ghmpb_color_custom"):GetBool() and GetConVar("ghmpb_color_blood"):GetString() == "255 10 0"
	and GetConVar("ghmpb_color_dense"):GetString() == "171 9 0" and near(G.cv.colFresh:GetFloat(), 2.55, 1e-6)
	and near(G.cv.colDry:GetFloat(), 0.9, 1e-6) and near(G.cv.absorb:GetFloat(), 3.53, 1e-6), "defaults: GHM's blood colours")
local dh, dA = G.BloodHue(), G.BloodAbsorb()
print(string.format("     default colours -> shader hue %.3f absorb %.3f", dh, dA))
-- own colours are for red blood: other types get the plain hue / absorption
local plainA = G.cv.absorb:GetFloat() * G.GPU.FreshAbs()
check(near(G.BloodAbsorbFor(0), dA, 1e-9) and near(G.BloodHueFor(0), dh, 1e-9), "red blood: the fitted values")
check(near(G.BloodAbsorbFor(3), plainA, 1e-9) and near(G.BloodAbsorbFor(1), plainA, 1e-9) and G.BloodHueFor(3) == 0,
	string.format("zombie / yellow blood: the plain values (%.2f, not the fitted %.2f)", plainA, dA))
-- old blood darkens over the clotting time, to at least the default physical darkness
local fresh, aged = G.AgedAbsorb(0)
check(near(G.AbsorbAged(0, 0), fresh, 1e-9) and near(G.AbsorbAged(0, 1), aged, 1e-9) and aged >= 1.85, string.format("red: fresh %.2f -> aged %.2f", fresh, aged))
local mid = G.AbsorbAged(0, G.AgeFrac(G.CoagTime() * 0.5))
check(mid > fresh and mid < aged, string.format("half the clotting time: in between (%.2f)", mid))
check(G.AgeFrac(0) == 0 and near(G.AgeFrac(G.CoagTime()), 1, 1e-9) and near(G.AgeFrac(G.CoagTime() * 5), 1, 1e-9), "age 0..1 over the clotting time")
check(near(G.ShineAged(0, 0), 1, 1e-9) and near(G.ShineAged(1, 0), 1, 1e-6) and G.ShineAged(1, 3) < 0.4, "shine: 1 fresh and clotted (wet), < 0.4 dried")

-- the physical colours (the older defaults) for the checks below
cv("ghmpb_color_custom", 0) cv("ghmpb_color_fresh", 1) cv("ghmpb_color_dry", 1) cv("ghmpb_density", 1)
cv("ghmpb_color_blood", U.DEF_BLOOD) cv("ghmpb_color_dense", U.DEF_DENSE)
local f0, a0x = G.AgedAbsorb(0)
check(near(f0, a0x, 1e-9), "physical colours: old blood ages exactly as before (shaders only)")

local r0, g0, b0 = U.BloodColour(0, 0.75, 120)
local d0 = { U.BloodDense(0, 0.75, 120) }
local tr0 = { U.BloodTrans(0, 0.75, 0.3) }
local h0, a0 = G.BloodHue(), G.BloodAbsorb()
check(near(h0, 0, 1e-6) and near(a0, 1.85, 1e-6), "off: hue 0, absorb 1.85")
local t, d = U.ShaderLook(0, 1.85)
local function s8(c) c = math.Clamp(c, 0, 1) return math.floor((c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 + 0.5) end
print(string.format("     default shader look: thin %d %d %d  dense %d %d %d", s8(t[1]), s8(t[2]), s8(t[3]), s8(d[1]), s8(d[2]), s8(d[3])))
check(string.format("%d %d %d", s8(t[1]), s8(t[2]), s8(t[3])) == U.DEF_BLOOD and string.format("%d %d %d", s8(d[1]), s8(d[2]), s8(d[3])) == U.DEF_DENSE,
	"the default picks are what the shaders show at the default settings")

cv("ghmpb_color_custom", 1)
local fh, fA, fe = U.ShaderFit()
print(string.format("     default picks -> hue %.3f absorb %.3f err %.5f", fh, fA, fe))
check(math.abs(fh) < 0.06 and math.abs(fA - 1.85) / 1.85 < 0.06 and fe < 1e-4, "on with the default picks: the fit lands on the default settings")
local r1, g1, b1 = U.BloodColour(0, 0.75, 120)
check(near(r1, r0) and near(g1, g0, 8) and near(b1, b0, 8), "on with the default picks: Lua colour about unchanged")
local tr1 = { U.BloodTrans(0, 0.75, 0.3) }
check(near(tr1[1], tr0[1], 1e-3) and near(tr1[2], tr0[2], 1e-3), "on with the default picks: Lite transmittance unchanged")

cv("ghmpb_color_blood", "230 70 30") cv("ghmpb_color_dense", "150 30 10")
fh, fA, fe = U.ShaderFit()
t, d = U.ShaderLook(G.BloodHue(), G.BloodAbsorb())
print(string.format("     scarlet -> hue %.2f absorb %.2f err %.4f  shader thin %d %d %d dense %d %d %d", fh, fA, fe, s8(t[1]), s8(t[2]), s8(t[3]), s8(d[1]), s8(d[2]), s8(d[3])))
check(fh > 0.4 and fe < 0.004, "scarlet: warmer hue, close fit")
local r2, g2, b2 = U.BloodColour(0, 0.75, 120)
check(g2 > g0 + 10, "scarlet: the Lua colour gets the orange")
local x1, y1, z1 = U.BloodColour(1, 0.75, 120)
cv("ghmpb_color_custom", 0)
local x0, y0, z0 = U.BloodColour(1, 0.75, 120)
check(near(x1, x0) and near(y1, y0) and near(z1, z0), "other blood types keep their colour")
cv("ghmpb_color_custom", 1)

cv("ghmpb_color_blood", "150 20 20") cv("ghmpb_color_dense", "45 5 5")
fh, fA, fe = U.ShaderFit()
check(fA > 2.2, "darker picks: more absorption")
cv("ghmpb_color_hue", 0.3)
check(near(G.BloodHue(), math.Clamp(fh + 0.3, -1, 2), 1e-6), "the hue slider still fine-tunes the fitted hue")
cv("ghmpb_color_hue", 0)

cv("ghmpb_color_blood", "40 200 40") cv("ghmpb_color_dense", "10 80 10")
fh, fA, fe = U.ShaderFit()
print(string.format("     green -> err %.4f (outside what the shaders can show)", fe))
check(fe > 0.01, "green: the fit reports it can not reach it")
local r3, g3 = U.BloodColour(0, 0.75, 120)
check(g3 > r3, "green: the Lua colour is green")
cv("ghmpb_color_blood", "garbage") 
check(select(1, U.CustomColours()) ~= nil, "bad colour string falls back to the default")
local t0 = os.clock() for i = 1, 20 do cv("ghmpb_color_dense", tostring(i) .. " 5 5") U.ShaderFit() end
print(string.format("     fit time %.1f ms", (os.clock() - t0) / 20 * 1000))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
