-- benchmark (not a test): a magazine dumped into an NPC - how much work the client does per hit and per frame
-- (drops spawned, landings, world / body impacts, traces, Lua time), with the real wound, forensic and droplet code
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

local function Run(label, hits, dmg, rate)
	for k in pairs(C) do C[k] = 0 end
	P.Clear()
	W.bodies = {}
	M.now = 100
	local dt = 1 / 60
	local hitT = M.now
	local maxF, sumF, frames, perHit = 0, 0, 0, {}
	local nh = 0
	local hitClock = 0
	for f = 1, math.floor((hits / rate + 4) / dt) do
		frame = frame + 1
		M.now = M.now + dt
		local t0 = os.clock()
		while nh < hits and M.now >= hitT do
			nh = nh + 1
			hitT = hitT + 1 / rate
			local s0 = C.spawn
			local th = os.clock()
			W.OnHit(npc, Vector(-6, (nh % 5) - 2, 30 + (nh % 7) * 4), Vector(1, 0, 0), dmg, DMG_BULLET, HITGROUP_CHEST, nh == hits, shooter)
			hitClock = hitClock + os.clock() - th
			perHit[#perHit + 1] = C.spawn - s0
		end
		W.Update()
		P.Step(dt)
		M.Advance(0)
		local ms = (os.clock() - t0) * 1000
		sumF, frames = sumF + ms, frames + 1
		if ms > maxF then maxF = ms end
	end
	local avgHit = 0
	for _, n in ipairs(perHit) do avgHit = avgHit + n end
	avgHit = avgHit / math.max(#perHit, 1)
	local ts = P.traceStats or {}
	print(string.format("%-28s traced/frame %s (want %s)", label, tostring(ts.traced), tostring(ts.want and math.floor(ts.want))))
	print(string.format("%-28s hits %d: drops/hit %.0f, drops %d, landings %d, world impacts %d (%.1f per landing), body %d, traces %d | Lua %.2f ms/frame avg, worst %.2f, OnHit %.2f ms each",
		label, hits, avgHit, C.spawn, C.land, C.world, C.world / math.max(C.land, 1), C.body, C.traces, sumF / frames, maxF, hitClock * 1000 / hits))
end
Run("rifle, 10/s", 30, 35, 10)
Run("pistol, 6/s", 15, 22, 6)
Run("rifle, 15/s (SMG)", 45, 30, 15)

-- where OnHit's time goes
local F = G.Forensic
local acc, cnt = {}, {}
local function wrapT(tbl, key, name)
	local f = tbl[key]
	tbl[key] = function(...)
		local t = os.clock()
		local a, b, c, d = f(...)
		acc[name] = (acc[name] or 0) + os.clock() - t
		cnt[name] = (cnt[name] or 0) + 1
		return a, b, c, d
	end
end
for _, k in ipairs({ "BackSpatter", "ForwardSpatter", "ExitPlume", "DirectConeMist", "MistDeposit", "MistCloud", "CRBDecal", "Spatter" }) do wrapT(F, k, k) end
wrapT(P, "Spawn", "P.Spawn")
local tr0 = util.TraceLine
local trN = 0
util.TraceLine = function(t) trN = trN + 1 return tr0(t) end
local t0 = os.clock()
for i = 1, 200 do
	M.now = M.now + 0.5
	W.bodies = {}
	W.OnHit(npc, Vector(-6, 0, 40), Vector(1, 0, 0), 35, DMG_BULLET, HITGROUP_CHEST, false, shooter)
end
local tot = os.clock() - t0
print(string.format("OnHit: %.3f ms each, %d traces each", tot * 1000 / 200, trN / 200))
local rows = {}
for k, v in pairs(acc) do rows[#rows + 1] = { k, v } end
table.sort(rows, function(a, b) return a[2] > b[2] end)
for _, r in ipairs(rows) do print(string.format("  %-16s %.3f ms per hit (%d calls)", r[1], r[2] * 1000 / 200, cnt[r[1]] / 200)) end
