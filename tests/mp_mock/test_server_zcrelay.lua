-- (1.26.8) Z-City with PhysBlood on the server: each player sees the blood of his own choice - the players with PhysBlood
-- on see PhysBlood's, the ones who switched it off (ghmpb_enable 0, sent as user info) still get Z-City's blood effects
-- and decals the server makes (server, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = true, false
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local effects = {}
util.Effect = function(name, data, override, rf) effects[#effects + 1] = { name = name, rf = rf } end
local decals = 0
util.Decal = function() decals = decals + 1 end
function isvector(x) return type(x) == "table" and x.x ~= nil and x.y ~= nil and x.z ~= nil end
function isentity(x) return type(x) == "table" and x.class ~= nil end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
local ZC = G.ZC
_G.hg = { organism = {} }
local on = M.Ent("player")
local off = M.Ent("player")
function on:GetInfoNum(k, d) return 1 end
function off:GetInfoNum(k, d) return k == "ghmpb_enable" and 0 or d end
M.Advance(1.5)
check(ZC.Active(), "Z-City found, PhysBlood takes over")
util.Effect("BloodImpact", {})
local e = effects[#effects]
local to = e and e.rf and e.rf:GetPlayers() or {}
check(#effects == 1 and #to == 1 and to[1] == off, "Z-City's blood effect goes to the player who switched PhysBlood off only")
M.sent = {}
util.Decal("Blood", Vector(0, 0, 10), Vector(0, 0, -10))
local s = M.SentOf("ghmpb_zcdecal")
check(decals == 0 and #s == 1 and type(s[1].to) == "table" and s[1].to[1] == off and s[1].data[1] == "Blood",
	"and its blood decal: sent to him to make in his game, not made for everyone")
util.Decal("Scorch", Vector(0, 0, 10), Vector(0, 0, -10))
check(decals == 1, "other decals as before")
-- everyone uses PhysBlood: nothing goes out
function off:GetInfoNum() return 1 end
M.Advance(1)
effects, M.sent = {}, {}
util.Effect("BloodImpact", {})
util.Decal("Blood", Vector(0, 0, 10), Vector(0, 0, -10))
check(#effects == 0 and #M.SentOf("ghmpb_zcdecal") == 0, "everyone on PhysBlood: Z-City's blood effects and decals are left out")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
