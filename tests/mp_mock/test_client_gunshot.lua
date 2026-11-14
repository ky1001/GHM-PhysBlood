-- (1.26.6, 27 Oct) shooting a body: back and front spatter for a living NPC, a fresh corpse, a long-dead and a drained
-- body; hit spatter gets past the droplet limit (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(-300, 0, 64) end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
G.Anatomy.GetSkeleton = function() return nil end
local drops, stains, bodyImpacts = {}, {}, 0
G.Entities = { Impact = function() bodyImpacts = bodyImpacts + 1 return true end, domains = {}, Get = function() return nil end }
G.Particles = { Spray = function() end, Spawn = function(o) drops[#drops + 1] = o end, Drips = function() end, Hang = function() end,
	Burst = function(o) return o.count end, Thin = function() return 1 end, ThinPrio = function() return 1 end, Count = function() return 0 end }
G.Surfaces = { Impact = function(pos, n) stains[#stains + 1] = { pos = pos, n = n } return true end, IsGround = function() return true end }
G.BloodTypeOf = function() return 0 end
G.Prof = { Count = function() end, Lap = function() end }
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
G.cv.mist:SetString("0")
M.Load({ "cl_util.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local U = G.U
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n, b) return p, n, b end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.TraceBone = function() return nil end
M.Load({ "cl_wounds.lua" })
local W = G.Wounds
-- the world: floor at z = 0, a wall 3 m behind the body (x = 160) and one 2.5 m in front of it (x = -130)
local world = util.TraceLine
local target
function util.TraceLine(t)
	if t.ignoreworld then
		-- the exit trace through the body: it finds the body's far side
		return { Hit = true, Entity = target, HitPos = t.start + (t.endpos - t.start) * 0.75, HitNormal = (t.start - t.endpos):GetNormalized(), Fraction = 0.75 }
	end
	local s, e = t.start, t.endpos
	if s.x > -130 and e.x <= -130 then
		local f = (s.x + 130) / (s.x - e.x)
		return { Hit = true, HitPos = s + (e - s) * f, HitNormal = Vector(1, 0, 0), Fraction = f, HitWorld = true }
	end
	M.wallX = 160
	return world(t)
end
local function Body(class, dead)
	local e = { valid = true, class = class }
	function e:IsValid() return self.valid end
	function e:GetBoneMatrix() return {} end
	function e:SetupBones() end
	function e:EntIndex() return 7 end
	function e:IsRagdoll() return class == "prop_ragdoll" end
	function e:IsNPC() return class ~= "prop_ragdoll" end
	function e:IsPlayer() return false end
	function e:GetNW2Int(_, d) return d end
	function e:GetNW2Bool(_, d) return d end
	function e:GetNWEntity() return NULL end
	function e:GetModel() return "models/humans/group01/male_02.mdl" end
	function e:GetCreationTime() return 0 end
	function e:GetVelocity() return Vector(0, 0, 0) end
	function e:GetPos() return Vector(0, 0, 0) end
	function e:WorldSpaceCenter() return Vector(0, 0, 40) end
	function e:GetModelScale() return 1 end
	function e:LookupAttachment() return 0 end
	function e:BoundingRadius() return 36 end
	function e:IsWorld() return false end
	return e
end
local shooter = { valid = true }
function shooter:IsValid() return true end
function shooter:GetPos() return Vector(-250, 0, 0) end
local function Shoot(ent, dmg, label)
	drops, stains = {}, {}
	target = ent
	M.now = M.now + 5
	W.OnHit(ent, Vector(-6, 0, 50), Vector(1, 0, 0), dmg, DMG_BULLET, HITGROUP_CHEST, false, shooter)
	M.Advance(1)
	local prio, behind, front, floor = 0, 0, 0, 0
	for _, d in ipairs(drops) do if d.prio then prio = prio + 1 end end
	for _, s in ipairs(stains) do
		if s.n.x < -0.5 then behind = behind + 1 elseif s.n.x > 0.5 then front = front + 1 elseif s.n.z > 0.5 then floor = floor + 1 end
	end
	print(string.format("     %s: %d spatter drops (all past the limit: %s), stains: wall behind %d, wall in front %d, floor %d",
		label, #drops, tostring(prio == #drops), behind, front, floor))
	return #drops, behind, front, floor, prio
end
M.now = 100
local npc = Body("npc_citizen")
local d1, b1, f1, fl1, p1 = Shoot(npc, 35, "living NPC, rifle")
check(d1 >= 20 and p1 == d1, "a living NPC: back and exit spatter drops, all of them hit spatter")
check(b1 > 0 and f1 + fl1 > 0, "stains on the wall behind it and in front of it / on the floor")
-- a fresh corpse
local rag = Body("prop_ragdoll")
local d2, b2, f2, fl2 = Shoot(rag, 35, "corpse a few seconds old")
check(d2 >= 10 and b2 > 0, "a fresh corpse: spatter too")
-- a corpse 5 minutes old (past the corpse bleed time: it does not bleed any more)
local old = Body("prop_ragdoll")
W.Body(old).corpseT0 = M.now - 300
local s0 = W.spatterOnly or 0
local d3, b3, f3, fl3 = Shoot(old, 35, "corpse 5 minutes old")
check(d3 >= 5 and b3 + f3 + fl3 > 0 and (W.spatterOnly or 0) == s0 + 1, "a long-dead corpse: still back / exit spatter (no new bleeding)")
-- a drained body
local dry = Body("prop_ragdoll")
local b = W.Body(dry) b.lostML = b.budget
local d4, b4, f4, fl4 = Shoot(dry, 35, "drained body")
check(d4 >= 5 and b4 + f4 + fl4 > 0, "a drained body: still spatter")
-- sizes: visible drops
local big = 0
local d5 = Shoot(npc, 35, "size check")
for _, d in ipairs(drops) do if d.r * 2 >= 0.5 then big = big + 1 end end
check(big >= #drops * 0.4, string.format("most spatter drops are a visible size (%d of %d >= 0.5 mm)", big, #drops))

-- ---------------- the droplet limit
local M2 = dofile("gmod.lua")
GHMPB = nil
_G.SERVER, _G.CLIENT = false, true
M2.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G2 = GHMPB
function EyePos() return Vector(0, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
function ScrW() return 1600 end
function ScrH() return 900 end
_G.util.PointContents = function() return 0 end
M2.Load({ "cl_util.lua" })
G2.cv.native = { GetBool = function() return false end }
G2.Gov = nil
G2.Surfaces = { IsGround = function() return false end }
M2.Load({ "cl_particles.lua" })
local P2 = G2.Particles
GetConVar("ghmpb_max_particles"):SetString("448")
for i = 1, 448 do P2.Spawn({ pos = Vector(i, 0, 50), vel = Vector(0, 0, -1), r = 0.3 }) end
local c0 = P2.Count()
P2.Spawn({ pos = Vector(0, 5, 50), vel = Vector(0, 0, -1), r = 0.3 })
local c1 = P2.Count()
P2.Spawn({ pos = Vector(0, 6, 50), vel = Vector(0, 0, -1), r = 0.3, prio = true })
local c2 = P2.Count()
check(c0 == 448 and c1 == c0 and c2 == c0 + 1, string.format("at the droplet limit (448): bleeding drops refused, hit spatter still spawns (%d, %d, %d)", c0, c1, c2))

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
