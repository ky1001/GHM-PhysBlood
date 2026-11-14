-- (1.26.8) GHM: "when giving a headshot there is a water ripple particle effect, big one and small, please remove
-- that". A head hit throws no fluid bursts: every VAT burst asked for while a head hit is worked out comes with V.mute set,
-- a chest hit's without it, and the setting is put back after the hit, also when the hit fails (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
local gcvn = GetConVarNumber
function GetConVarNumber(n) if n == "sv_gravity" then return 600 end return gcvn(n) end
local frame = 0
function FrameNumber() return frame end
function LocalPlayer() return NULL end
function EyePos() return Vector(-300, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameTime() return 1 / 60 end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
_G.render = _G.render or {}
render.GetViewSetup = function() return { fov = 90 } end
G.Anatomy.GetSkeleton = function() return nil end
local C = { world = 0, body = 0, spawn = 0, land = 0, traces = 0 }
G.Entities = { Impact = function() C.body = C.body + 1 return true end, domains = {}, Get = function() return nil end }
G.Surfaces = { Impact = function() C.world = C.world + 1 return true end, IsGround = function() return true end, GroundFilter = function() return true end }
G.BloodTypeOf = function() return 0 end
G.Prof = { Count = function() end, Lap = function() end, cavg = {}, avg = {}, frame = { avg = 16 } }
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
_G.util.PointContents = function() return 0 end
math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
function VectorRand(a, b) a = a or -1 b = b or 1 return Vector(a + (b - a) * math.random(), a + (b - a) * math.random(), a + (b - a) * math.random()) end
M.Load({ "cl_util.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local U = G.U
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n, b) return p, n, b end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.BoneToWorld = function(_, _, p, n) return p and Vector(p) or nil, n and Vector(n) or nil end
U.TraceBone = function() return nil end
U.BoneFrame = nil
G.cv.native = { GetBool = function() return false end }
M.Load({ "cl_particles.lua" })
local P = G.Particles
local realSpawn, realLand = P.Spawn, P.Land
P.Spawn = function(o) C.spawn = C.spawn + 1 return realSpawn(o) end
P.Land = function(p, tr) C.land = C.land + 1 return realLand(p, tr) end
M.Load({ "cl_wounds.lua" })
local W = G.Wounds
local world = util.TraceLine
local target
local TRACE_US = tonumber(os.getenv("TRACE_US") or "0")
function util.TraceLine(t)
	C.traces = C.traces + 1
	if TRACE_US > 0 then local e = os.clock() + TRACE_US * 1e-6 while os.clock() < e do end end
	if t.ignoreworld then
		return { Hit = true, Entity = target, HitPos = t.start + (t.endpos - t.start) * 0.75, HitNormal = (t.start - t.endpos):GetNormalized(), Fraction = 0.75 }
	end
	M.wallX = 160
	return world(t)
end
local npc = { valid = true }
function npc:IsValid() return self.valid end
function npc:GetBoneMatrix() return {} end
function npc:SetupBones() end
function npc:EntIndex() return 7 end
function npc:IsRagdoll() return false end
function npc:IsNPC() return true end
function npc:IsPlayer() return false end
function npc:GetNW2Int(_, d) return d end
function npc:GetNW2Bool(_, d) return d end
function npc:GetNWEntity() return NULL end
function npc:GetModel() return "models/humans/group01/male_02.mdl" end
function npc:GetVelocity() return Vector(0, 0, 0) end
function npc:GetPos() return Vector(0, 0, 0) end
function npc:WorldSpaceCenter() return Vector(0, 0, 40) end
function npc:GetModelScale() return 1 end
function npc:LookupAttachment() return 0 end
function npc:BoundingRadius() return 36 end
function npc:IsWorld() return false end
function npc:WorldToLocal(v) return Vector(v) end
function npc:LocalToWorld(v) return Vector(v) end
function npc:GetAngles() return Angle(0, 0, 0) end
function npc:GetClass() return "npc_citizen" end
function npc:IsDormant() return false end
function npc:Health() return 100 end
target = npc
local shooter = { valid = true }
function shooter:IsValid() return true end
function shooter:GetPos() return Vector(-250, 0, 0) end


local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local calls = {}
G.VAT = { mute = false, On = function() return true end, Ready = function() return true end }
for _, k in ipairs({ "OnEntry", "OnExit", "OnBlunt", "OnBlast", "OnJet" }) do
	G.VAT[k] = function() calls[#calls + 1] = { k, G.VAT.mute } end
end
G.VAT.OnSpray = function() calls[#calls + 1] = { "OnSpray", G.VAT.mute } return true end
local A = G.Anatomy
local function Hit(hg, region)
	calls = {}
	W.bodies = {}
	M.now = M.now + 1
	A.RegionFromHit = function() return region end
	W.OnHit(npc, Vector(-6, 0, 60), Vector(1, 0, 0), 40, DMG_BULLET, hg, false, shooter)
	local muted, open = 0, 0
	for _, c in ipairs(calls) do if c[2] then muted = muted + 1 else open = open + 1 end end
	return muted, open
end
M.now = 100
local hm, ho = Hit(HITGROUP_HEAD, A.HEAD)
check(hm > 0 and ho == 0, string.format("a headshot: all %d burst requests muted", hm))
check(G.VAT.mute == false, "after the headshot: not muted any more")
local cm, co = Hit(HITGROUP_CHEST, A.CHEST)
check(co > 0 and cm == 0, string.format("a chest hit: its %d bursts play", co))
calls = {}
local wm, wo = 0, 0
W.ShotWorld(Vector(-6, 0, 60), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_HEAD, shooter, 0, nil, A.HEAD)
for _, c in ipairs(calls) do if c[2] then wm = wm + 1 else wo = wo + 1 end end
check(wm > 0 and wo == 0 and G.VAT.mute == false, "a headshot thrown before the body is known (ShotWorld): muted, and put back")
-- a hit that fails half way still puts the setting back
local rf = A.RegionFromHit
A.RegionFromHit = function() G.VAT.mute = true error("boom") end
local ok = pcall(W.OnHit, npc, Vector(-6, 0, 60), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_HEAD, false, shooter)
check(not ok and G.VAT.mute == false, "a head hit that fails half way: not left muted")
A.RegionFromHit = rf
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
