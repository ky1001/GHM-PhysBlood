-- Battle size, governor levers and far drops (client) under a mocked GMod
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
-- client API
local eye = Vector(0, 0, 64)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
function ScrW() return 1600 end
function ScrH() return 900 end
local frame = 0
function FrameNumber() return frame end
function GetConVarNumber(n) return n == "sv_gravity" and 600 or 0 end
function VectorRand() return Vector(0, 0, 0) end
function LocalPlayer() return NULL end
local Emeta = getmetatable(M.Ent("info_null"))
function Emeta:IsDormant() return false end
_G.ents.FindByClass = function(pat) local o = {} for _, e in ipairs(M.ents) do if e.valid and e.class:match("^npc_") then o[#o + 1] = e end end return o end
G.U = {}
M.Load({ "cl_util.lua" })
G.Wounds = { bodies = {} }
G.Prof = { cavg = {}, frame = { avg = 10 }, avg = {}, Count = function() end, Lap = function() end }
M.Load({ "cl_battle.lua", "cl_governor.lua" })
local B, V = G.Battle, G.Gov
-- (1.26.8) off by default now (the best blood out of the box): a player who turns it on in the settings, on High (on
-- Ultra the fight size counts only as far as the frame is slow)
check(G.cv.battle:GetInt() == 0 and G.cv.perfadapt:GetInt() == 0 and G.cv.quality:GetInt() == 4,
	"1.26.8 defaults: fight-size and adaptive quality off, Ultra")
G.cv.battle:SetInt(1)
G.cv.quality:SetInt(3)

-- small fight: full quality
for i = 1, 6 do M.Ent("npc_citizen", { pos = Vector(300 + i * 20, 0, 0) }):SetNW2Int("ghmpb_blood", 0) end
for _ = 1, 4 do M.now = M.now + 0.6 B.Update() end
check(B.level == 0, "6 NPCs: battle level 0 (" .. B.level .. ")")
check(V.BodySimHz(30, 2000, false) == 30, "small fight: far hidden body keeps its rate")
-- big fight
for i = 1, 40 do M.Ent("npc_combine_s", { pos = Vector(800 + i * 30, 200, 0) }):SetNW2Int("ghmpb_blood", 0) end
for _ = 1, 4 do M.now = M.now + 0.6 B.Update() end
check(B.level > 0.9, "46 NPCs: battle level ~1 (" .. string.format("%.2f", B.level) .. ")")
check(V.BodySimHz(30, 300, true) == 30, "big fight: a body near and in view keeps its full rate")
check(V.BodySimHz(30, 3000, true) < 15, "big fight: a far body runs slower (" .. V.BodySimHz(30, 3000, true) .. ")")
check(V.EmitMul(Vector(300, 0, 64)) == 1, "big fight: jets near and in view keep their drops")
check(V.EmitMul(Vector(-300, 0, 64)) > 1.5, "big fight: jets behind the camera throw fewer, bigger drops")
check(V.LiveCap(12) < 12 and V.LiveCap(12) >= 6, "big fight: fewer bodies simulated at once (" .. V.LiveCap(12) .. ")")
check(V.TraceMs() == 3, "big fight: near drops keep their trace budget")
-- the fight ends: the level falls slowly
for _, e in ipairs(M.ents) do if e.class == "npc_combine_s" then e.valid = false end end
M.now = M.now + 0.6 B.Update()
check(B.level > 0.8, "level falls slowly (" .. string.format("%.2f", B.level) .. ")")
for _ = 1, 30 do M.now = M.now + 0.6 B.Update() end
check(B.level == 0, "and is back to 0 after the fight")

-- far drops: same landing as the frame-by-frame Lua solver
G.cv.native = { GetBool = function() return false end }
G.cv.enable = { GetBool = function() return true end }
G.Water = nil
G.Gov = V
G.U.TraceCorpses = function() return nil end
local landed = {}
M.Load({ "cl_particles.lua" })
local P = G.Particles
P.Land = function(p, tr) landed[#landed + 1] = { pos = tr.HitPos, t = CurTime(), vel = p.vel } end
local function Throw(x)
	P.Spawn({ pos = Vector(x, 0, 60), vel = Vector(250, 0, 120), r = 1.2, owner = nil, oxy = 0.7, btype = 0, ownerGrace = 0 })
end
-- (a) near the camera: the Lua solver
local t0 = M.now
Throw(100)
check(#P.list == 1 and P.FarCount() == 0, "a near drop flies in the solver")
for _ = 1, 200 do M.now = M.now + 1 / 60 frame = frame + 1 P.Step(1 / 60) if #landed > 0 then break end end
local nearLand, nearT = landed[1], landed[1] and landed[1].t - t0
-- (b) far away: worked out at once
landed = {}
t0 = M.now
Throw(100 + 3000)
check(#P.list == 0 and P.FarCount() == 1, "a drop 3000 u away is worked out, not flown")
for _ = 1, 200 do M.now = M.now + 1 / 60 frame = frame + 1 P.Step(1 / 60) if #landed > 0 then break end end
local farLand, farT = landed[1], landed[1] and landed[1].t - t0
check(nearLand and farLand, "both landed")
if nearLand and farLand then
	local dx = (farLand.pos.x - 3000) - nearLand.pos.x
	print(string.format("     near: lands at x=%.1f after %.3f s   far: x=%.1f after %.3f s", nearLand.pos.x, nearT, farLand.pos.x - 3000, farT))
	check(math.abs(dx) < 3, "same place (within 3 u): " .. string.format("%.2f", dx))
	check(math.abs(farT - nearT) < 0.06, "same time (within 0.06 s)")
	check(math.abs(farLand.vel.z - nearLand.vel.z) < 25, "same landing speed")
end
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
