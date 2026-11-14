-- 1.19.0: the look settings packed into the world film shaders' SC1.y (type pair + 64 * (pool look * 10 + 32 * froth * 10)),
-- decoded the way ghmpb_shade.h does it, in single precision; froth only on floors and gentle slopes (the simulation's own
-- test: the plane's gravity along it at most 200 cm/s^2) and never on the aftermath (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function GetConVarNumber(n) return n == "sv_gravity" and 600 or 0 end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
_G.util.PointContents = function() return 0 end
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end, Caps = function() return { patches = 999, aft = 999 } end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua", "cl_surfaces.lua" })
local S = G.Surfaces

-- single precision, as the shader sees the constant and works on it
local ffi = require("ffi")
local fb = ffi.new("float[1]")
local function f32(x) fb[0] = x return fb[0] end
local function div(a, b) return f32(f32(a) / f32(b)) end
local function frac(x) x = f32(x) return f32(x - math.floor(x)) end
local function pairCodeAt(c) return f32(frac(div(c, 64)) * 64) end
local function lookWord(c) return math.floor(div(c, 64)) end
local function poolLook(c) local w = lookWord(c) return f32((w - 32 * math.floor(div(w, 32))) * f32(0.1)) end
local function frothAmt(c) return f32(math.floor(div(lookWord(c), 32)) * f32(0.1)) end
local function poolLookAt(c) return f32(math.floor(f32(frac(div(c, 2048)) * 32)) * f32(0.1)) end

local function Patch(nz)
	local N = Vector(math.sqrt(1 - nz * nz), 0, nz)
	local U = Vector(0, 1, 0)
	local V = N:Cross(U)
	return { N = N, U = U, V = V }
end
local flat, ramp8, ramp15, wall = Patch(1), Patch(math.cos(math.rad(8))), Patch(math.cos(math.rad(15))), Patch(0)
check(S.FrothOK(flat) and S.FrothOK(ramp8), "froth on floors and gentle slopes (8 deg)")
check(not S.FrothOK(ramp15) and not S.FrothOK(wall), "no froth on steeper slopes (15 deg) and walls")

local okAll = true
local worst = ""
for _, pl in ipairs({ 0, 0.3, 1, 1.5, 2 }) do
	for _, fr in ipairs({ 0, 0.5, 1, 2 }) do
		G.cv.poollook:SetFloat(pl)
		G.cv.froth:SetFloat(fr)
		for a = 0, 3 do
			for b = 0, 3 do
				local pair = a + 8 * b
				for _, case in ipairs({ { flat, false, fr }, { wall, false, 0 }, { flat, true, 0 } }) do
					local c = f32(S.LookPair(pair, case[1], case[2]))
					local okP = pairCodeAt(c) == pair
					local okL = math.abs(poolLook(c) - pl) < 1e-6 and math.abs(poolLookAt(c) - pl) < 1e-6
					local okF = math.abs(frothAmt(c) - case[3]) < 1e-6
					if not (okP and okL and okF) then
						okAll = false
						worst = string.format("pool %.1f froth %.1f pair %d: decoded pair %g pool %g / %g froth %g", pl, fr, pair, pairCodeAt(c), poolLook(c), poolLookAt(c), frothAmt(c))
					end
				end
			end
		end
	end
end
check(okAll, "every type pair, pool look and froth setting decodes exactly (both ways of decoding the pool look) " .. worst)
G.cv.poollook:SetFloat(1)
G.cv.froth:SetFloat(1)
check(S.LookPair(9, flat, false) == 9 + 64 * (10 + 320), "default settings: pair + 64 * (10 + 32 * 10)")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
