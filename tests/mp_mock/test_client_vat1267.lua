-- (1.26.7, 27 Oct) the 1.26.2 physics back: 3D fluid drops on by default (and turned on once for 1.26.6 players), the
-- 1.26.2 splash-crown rule scaled by the Splashes setting (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
-- a 1.26.6 player: config version 1266, 3D drops saved off
CreateClientConVar("ghmpb_config_version", "0", true, false):SetString("1266")
CreateClientConVar("ghmpb_vat_drops", "0", true, false):SetString("0")
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, -200, 64) end
function Matrix() return setmetatable({}, { __index = function() return function() end end }) end
_G.render = { SuppressEngineLighting = function() end, SetModelLighting = function() end, SetLocalModelLights = function() end,
	SetMaterial = function() end, GetRenderTarget = function() return nil end }
_G.cam = { PushModelMatrix = function() end, PopModelMatrix = function() end }
_G.MATERIAL_TRIANGLES, _G.MATERIAL_LIGHT_DIRECTIONAL = 2, 2
G.Prof = { Count = function() end, Lap = function() end }
M.Load({ "cl_util.lua", "cl_vat.lua" })
local V = G.VAT
check(GetConVar("ghmpb_config_version"):GetInt() >= 1267, "config version 1267 or later")
check(V.cvDrops:GetBool(), "a 1.26.6 player who had the 3D drops off gets them on once")
check(V.ApplyLight ~= nil and V.cvSize ~= nil, "the streams get the VAT light and size")

-- the crown rule
local spawned = {}
V.On = function() return true end
V.Spawn = function(kind, pos, n, size, speed) spawned[#spawned + 1] = { kind = kind, size = size, speed = speed } end
local function Land(x, rmm, speed, nz)
	M.now = M.now + 0.2
	local before = #spawned
	V.OnDropLand(Vector(x, 0, 0), Vector(0, 0, nz or 1), rmm, speed, 0)
	return #spawned > before
end
M.now = 10
-- (1.26.8) the crowns are off (GHM: "a water ripple particle effect, big one and small" after a headshot - removed);
-- the rule stays behind V.CROWNS
check(not Land(-300, 1.3, 170), "1.26.8: no splash crowns where blood lands")
V.CROWNS = true
check(Land(0, 1.3, 170), "a 1.3 mm drop landing at 170 u/s: a crown (the 1.26.2 rule)")
check(not Land(30, 1.0, 400), "a 1.0 mm drop: none")
check(not Land(60, 2.0, 120), "landing at 120 u/s: none")
check(not Land(90, 2.0, 300, 0.3), "on a wall: none")
M.now = M.now + 1
V.OnDropLand(Vector(200, 0, 0), Vector(0, 0, 1), 2, 300, 0)
local n1 = #spawned
M.now = M.now + 0.3
V.OnDropLand(Vector(201, 0, 0), Vector(0, 0, 1), 2, 300, 0)
check(#spawned == n1, "the same spot again within 0.65 s: none")
M.now = M.now + 0.5
V.OnDropLand(Vector(201, 0, 0), Vector(0, 0, 1), 2, 300, 0)
check(#spawned == n1 + 1, "after 0.65 s: again")
check(spawned[#spawned].speed == 1.85, "played at the 1.26.2 speed")
G.cv.splash:SetString("0")
check(not Land(400, 2, 300), "Splashes 0: none")
G.cv.splash:SetString("0.5")
local c = 0
for i = 1, 200 do M.now = M.now + 1 if Land(1000 + i * 20, 2, 300) then c = c + 1 end end
check(c > 60 and c < 140, "Splashes 0.5: about half (" .. c .. " of 200)")
G.cv.splash:SetString("1")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
