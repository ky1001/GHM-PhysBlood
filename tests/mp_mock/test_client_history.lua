-- Client catch-up: decode what sv_history sends and paint it
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
-- (1.26.8) checked at the drying figures of 1.26.7 and before (the defaults dry and clot several times slower now)
RunConsoleCommand("ghmpb_drytime", "240") RunConsoleCommand("ghmpb_coag_time", "180")
local G = GHMPB
local imp = {}
G.Surfaces = { Impact = function(pos, n, vel, r, vol, kind, spin, stretch, residue) imp[#imp + 1] = { kind = kind, vol = vol, residue = residue, r = r } return true end }
local eimp = {}
G.Entities = { Impact = function(e, pos, n, vel, r, vol, kind, spin, stretch, residue) eimp[#eimp + 1] = { kind = kind, vol = vol } end }
G.U = { EntitySurface = function(_, p, d) return p, -d end, SnapToMesh = function(_, p, n) return p, n end, RandRange = function(a, b) return a + (b - a) * math.random() end }
G.Prof = { Lap = function() end }
local Emeta = getmetatable(M.Ent("info_null"))
function Emeta:GetBoneMatrix(b) return { GetTranslation = function() return self.pos end, GetAngles = function() return angle_zero end } end
function EyePos() return Vector(0, 0, 64) end
function VectorRand() return Vector(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) end
function net.SendToServer() end
M.Load({ "cl_history.lua" })

local npc = M.Ent("npc_citizen", { pos = Vector(100, 0, 0) })
npc:SetNW2Int("ghmpb_blood", 0)
M.now = 1000
-- (exactly the order sv_history writes)
M.readq = {
	3,
	2, Vector(10, 0, 0), Vector(0, 0, 1), Vector(1, 0, 0), 480000, 14.8, 0, 5,          -- a fresh pool
	2, Vector(400, 0, 0), Vector(0, 0, 1), Vector(1, 0, 0), 480000, 14.8, 0, 800,       -- an old pool
	3, Vector(50, 0, 0), Vector(0, 0, 1), Vector(1, 0, 0), 900, 12, 0, 30,             -- spatter
	1,
	npc, 2,
	1, Vector(0, 0, 2), Vector(1, 0, 0), 0.8, 10, 0,
	2, Vector(0, 2, 0), Vector(0, 1, 0), 1.2, 600, 0,
}
net.Receivers.ghmpb_hist(0)
check(#G.HistCl.world == 3 and #G.HistCl.bodies == 1, "decoded 3 world records and a body")
for _ = 1, 3 do M.Engine("Think") end
check(#G.HistCl.world == 0, "all painted")
local pours, dried, drops = 0, 0, 0
for _, i in ipairs(imp) do
	if i.kind == 1 then pours = pours + 1 elseif i.residue == 1 then dried = dried + 1 else drops = drops + 1 end
end
check(pours == 1, "the fresh pool pours (wet): " .. pours)
check(dried >= 3, "the old pool is laid down dried: " .. dried)
check(drops >= 5, "spatter as drops: " .. drops)
check(#eimp >= 4, "wounds painted on the body: " .. #eimp)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
