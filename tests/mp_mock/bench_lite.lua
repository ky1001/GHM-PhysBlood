-- benchmark (not a test): a magazine dumped into an NPC standing in front of a wall, with the Lite renderer (no
-- shaders): the real wound, forensic, droplet, rivulet and Lite code. Counts what costs in the game and is cheap here:
-- traces, render.ComputeLighting, Vector objects made (userdata in the game, garbage), Vector method calls (C calls),
-- mesh vertices built as tables, and the memory allocated (with the garbage collector stopped)
-- env: TRACE_US / LIGHT_US / VEC_US simulate the game's cost of a trace / a lighting sample / a Vector made
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local C = { tLand = 0, tHit = 0, tRuns = 0, tLite = 0, tStep = 0, tW = 0, traces = 0, light = 0, vec = 0, vcall = 0, tverts = 0, dverts = 0, land = 0, spawn = 0, stains = 0 }
local function spin(us) if us > 0 then local e = os.clock() + us * 1e-6 while os.clock() < e do end end end
local TRACE_US = tonumber(os.getenv("TRACE_US") or "0")
local LIGHT_US = tonumber(os.getenv("LIGHT_US") or "0")
local VEC_US = tonumber(os.getenv("VEC_US") or "0")
-- Vector objects and method calls
local VM = getmetatable(Vector(0, 0, 0))
for _, k in ipairs({ "__add", "__sub", "__mul", "__div", "__unm" }) do
	local f = VM[k]
	VM[k] = function(a, b) C.vec = C.vec + 1 spin(VEC_US) return f(a, b) end
end
for k, f in pairs(VM) do
	if type(f) == "function" and not k:find("^__") then
		local made = (k == "Cross" or k == "GetNormalized" or k == "Angle")
		VM[k] = function(...) C.vcall = C.vcall + 1 if made then C.vec = C.vec + 1 spin(VEC_US) end return f(...) end
	end
end
local Vraw = Vector
function Vector(...) C.vec = C.vec + 1 spin(VEC_US) return Vraw(...) end
function SysTime() return os.clock() end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
local gcvn = GetConVarNumber
function GetConVarNumber(n) if n == "sv_gravity" then return 600 end return gcvn(n) end
local frame = 0
function FrameNumber() return frame end
function LocalPlayer() return NULL end
function EyePos() return Vector(-300, 0, 64) end
local ANG = { Forward = function() return Vector(1, 0, 0) end, Right = function() return Vector(0, -1, 0) end, Up = function() return Vector(0, 0, 1) end }
function EyeAngles() return ANG end
function ScrW() return 1600 end
function ScrH() return 900 end
function FrameTime() return 1 / 60 end
function RealFrameTime() return 1 / 60 end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
_G.timer = { Simple = function() end }
-- engine: materials, meshes, drawing
local function Mat(name) return { name = name, SetVector = function() end, GetVector = function() return Vraw(1, 1, 1) end, IsError = function() return false end } end
function Material(name) return Mat(name) end
function CreateMaterial(name) return Mat(name) end
function Mesh() return { BuildFromTriangles = function(_, v) C.tverts = C.tverts + #v end, Draw = function() end, Destroy = function() end } end
_G.mesh = { Begin = function() end, End = function() end, Position = function() end, Normal = function() end, TexCoord = function() end,
	Color = function() end, AdvanceVertex = function() C.dverts = C.dverts + 1 end, UserData = function() end, TangentS = function() end, TangentT = function() end }
_G.render = { SetMaterial = function() end, GetRenderTarget = function() return nil end, GetViewSetup = function() return { fov = 90 } end,
	ComputeLighting = function() C.light = C.light + 1 spin(LIGHT_US) return Vraw(0.5, 0.5, 0.5) end }
_G.MATERIAL_QUADS, _G.MATERIAL_TRIANGLES = 3, 2
util.DecalEx = function() end
G.Anatomy.GetSkeleton = function() return nil end
G.Surfaces = { Impact = function() return true end, Element = function() return 0 end, GetPatch = function() return nil end, WarmSlot = function() return false end,
	HasStatic = function() return false end, Update = function() end, DrawStatic = function() end, DrawOverlays = function() end,
	PATCH_UNITS = 40, GroundFilter = function() return true end, IsGround = function() return false end }
G.Entities = { Impact = function() return true end, Element = function() return false end, Get = function() return nil end, WarmSlot = function() return false end,
	Update = function() end, HasStatic = function() return false end, DrawStatic = function() end, DrawOverlays = function() end, domains = {} }
G.Smear = { RequestProbe = function() end }
G.Contact = { Grid = function() return {} end, NearBlood = function() return false end }
G.Dust = { GpuPass = function() end, DrawStatic = function() end, DrawLive = function() end, Any = function() return false end }
util.GetSunInfo = function() return nil end
_G.MASK_OPAQUE = _G.MASK_OPAQUE or 1
G.BloodTypeOf = function() return 0 end
G.GPU = { FreshAbs = function() return 1 end }
G.Prof = { Count = function() end, Lap = function() return SysTime() end, cavg = {}, avg = {}, frame = { avg = 16 } }
G.DiagCount = function() end
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
_G.util.PointContents = function() return 0 end
math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
function VectorRand(a, b) a = a or -1 b = b or 1 return Vector(a + (b - a) * math.random(), a + (b - a) * math.random(), a + (b - a) * math.random()) end
M.Load({ "cl_util.lua", "cl_lighting.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local U = G.U
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n, b) return p, n, b end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.BoneToWorld = function(_, _, p, n) return p and Vector(p) or nil, n and Vector(n) or nil end
U.TraceBone = function() return nil end
U.InViewPos = function() return true end
U.BoneFrame = nil
G.cv.native = { GetBool = function() return false end }
M.Load({ "cl_particles.lua", "cl_runs.lua" })
local P, R = G.Particles, G.Runs
local realLand = P.Land
P.Land = function(p, tr) C.land = C.land + 1 local t = os.clock() local a = realLand(p, tr) C.tLand = C.tLand + os.clock() - t return a end
M.Load({ "cl_wounds.lua", "cl_lite.lua" })
local W, L = G.Wounds, G.Lite
L.on = true
local realNew = L.NewStain
local world = util.TraceLine
local target
function util.TraceLine(t)
	C.traces = C.traces + 1
	spin(TRACE_US)
	if t.ignoreworld then
		return { Hit = true, Entity = target, HitPos = t.start + (t.endpos - t.start) * 0.75, HitNormal = (t.start - t.endpos):GetNormalized(), Fraction = 0.75 }
	end
	M.wallX = 160
	local r = world(t)
	if t.output then for k, v in pairs(r) do t.output[k] = v end t.output.StartSolid = false t.output.HitSky = false return t.output end
	return r
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
	P.Clear() R.Clear() L.Clear()
	W.bodies = {}
	M.now = 100
	local dt = 1 / 60
	local hitT = M.now
	local maxF, sumF, frames = 0, 0, 0
	local nh = 0
	collectgarbage("collect")
	collectgarbage("stop")
	local kb0 = collectgarbage("count")
	local heads = 0
	for f = 1, math.floor((hits / rate + 5) / dt) do
		frame = frame + 1
		M.now = M.now + dt
		local t0 = os.clock()
		while nh < hits and M.now >= hitT do
			nh = nh + 1
			hitT = hitT + 1 / rate
			local th = os.clock()
			W.OnHit(npc, Vector(-6, (nh % 5) - 2, 30 + (nh % 7) * 4), Vector(1, 0, 0), dmg, DMG_BULLET, HITGROUP_CHEST, nh == hits, shooter)
			C.tHit = C.tHit + os.clock() - th
		end
		local ta = os.clock()
		W.Update()
		local tb = os.clock()
		P.Step(dt)
		local tc = os.clock()
		R.Step(dt)
		local td = os.clock()
		L.Update(dt)
		local te = os.clock()
		C.tW, C.tStep, C.tRuns, C.tLite = C.tW + tb - ta, C.tStep + tc - tb, C.tRuns + td - tc, C.tLite + te - td
		L.DrawWorld()
		local ms = (os.clock() - t0) * 1000
		sumF, frames = sumF + ms, frames + 1
		if ms > maxF then maxF = ms end
		heads = math.max(heads, #R.heads)
	end
	local kb = collectgarbage("count") - kb0
	collectgarbage("restart")
	local st, pools = L.Counts()
	print(string.format("%-20s ms/frame: hits %.2f (%.2f per hit), wounds %.2f, drops %.2f (landings %.2f, %.3f per landing), runs %.2f, lite %.2f",
		label, C.tHit * 1000 / frames, C.tHit * 1000 / hits, C.tW * 1000 / frames, C.tStep * 1000 / frames, C.tLand * 1000 / frames, C.tLand * 1000 / math.max(C.land, 1), C.tRuns * 1000 / frames, C.tLite * 1000 / frames))
	print(string.format("%-20s %d hits: landings %d, stains %d, pools %d, run heads (most) %d, run stats %d spawned", label, hits, C.land, st, pools, heads, R.stats.spawned or 0))
	print(string.format("%-20s per frame: Lua %.2f ms avg, worst %.2f | traces %.0f, lighting %.1f, Vectors %.0f, Vector calls %.0f, mesh verts as tables %.0f, direct %.0f, alloc %.0f KB",
		label, sumF / frames, maxF, C.traces / frames, C.light / frames, C.vec / frames, C.vcall / frames, C.tverts / frames, C.dverts / frames, kb / frames))
end
Run("rifle, 10/s", 30, 35, 10)
Run("rifle, 15/s (SMG)", 45, 30, 15)
