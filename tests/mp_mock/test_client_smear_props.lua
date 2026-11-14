-- 1.18.1: dragged bodies smear even when their model was first seen before its bones existed; rolling / sliding props
-- keep their contact, wipe and pick up a pool they cross (probe answers used where they were asked), then smear (client)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function Lerp(t, a, b) return a + (b - a) * t end
function EyePos() return Vector(0, 0, 64) end
math.AngleDifference = math.AngleDifference or function(a, b)
	local d = (a - b) % 360
	if d > 180 then d = d - 360 end
	return d
end
_G.MOVETYPE_VPHYSICS = 6
_G.MASK_SOLID = 1
local E = getmetatable(M.Ent("info_null"))
function E:GetBoneCount() return self.bones and #self.bones or 0 end
function E:GetBoneName(b) return self.bones and self.bones[b + 1] or "__INVALIDBONE__" end
function E:GetUp() return Vector(0, 0, 1) end
function E:GetModelScale() return 1 end
function E:GetMoveType() return self.mt or 0 end
function E:IsVehicle() return false end
function E:IsWeapon() return false end
function E:GetOwner() return NULL end

-- ------------------------------------------------------------------ shared stubs
local impacts, bodyImpacts = {}, {}
local pending = {}
local POOL = { x0 = -25, x1 = 25, h = 1.2, btype = 1 }
G.U = { corpses = {}, NearestBone = function() return 0 end }
G.Entities = { domains = {}, ModelInfo = function() return nil end,
	Impact = function(e, pos, n, vel, R, vol, kind, side, fresh, residue, bone, extra) bodyImpacts[#bodyImpacts + 1] = { e = e, vol = vol, extra = extra } end }
G.Surfaces = { PATCH_UNITS = 40, after = {}, GroundFilter = function() return true end,
	Impact = function(pos, n, dir, R, vol, kind) impacts[#impacts + 1] = { pos = pos, dir = dir, R = R, vol = vol, kind = kind } return true end }
-- (the GPU readback: an answer ~0.3 s after the question, with the pool depth where it was asked)
local function Ask(ps, pos)
	pending[#pending + 1] = { ps = ps, pos = Vector(pos), at = M.now + 0.3 }
	ps.oxy, ps.btype, ps.live = 0.6, POOL.btype, true
end
local function Pump()
	for i = #pending, 1, -1 do
		local q = pending[i]
		if M.now >= q.at then
			table.remove(pending, i)
			local inside = q.pos.x >= POOL.x0 and q.pos.x <= POOL.x1 and math.abs(q.pos.y) < 40
			q.ps.h, q.ps.s, q.ps.hT = inside and POOL.h or 0, 0, M.now
		end
	end
end
G.Contact = { Grid = function() end, NearBlood = function() return true end, Collapsed = function() return false end,
	Probe = function(ps, pos, n, every)
		if M.now - (ps.reqT or -1e9) < (every or 0.1) then return end
		ps.reqT, ps.reqPos = M.now, Vector(pos)
		Ask(ps, pos)
	end,
	Depth = function(ps, maxAge, pos, near)
		if not ps.hT or M.now - ps.hT > (maxAge or 0.8) then return nil end
		if pos and ps.reqPos and near and ps.reqPos:DistToSqr(pos) > near * near then return nil end
		return ps.h or 0
	end,
	Splash = function() return 0 end }

M.Load({ "cl_smear.lua" })
local SM = G.Smear
SM.RequestProbe = function(ps, pos) Ask(ps, pos) end

-- ------------------------------------------------------------------ world traces: floor at z = 0, plus the test prop
local prop
local realTrace = util.TraceLine
function util.TraceLine(t)
	if t.ignoreworld then
		-- only the prop: a vertical ray against its shape
		if not prop or not t.filter(prop) then return { Hit = false, Fraction = 1, HitPos = t.endpos } end
		local s, e = t.start, t.endpos
		local z = prop.Bottom(s.x, s.y)
		if z and z >= math.min(s.z, e.z) and z <= math.max(s.z, e.z) then
			return { Hit = true, Entity = prop, HitPos = Vector(s.x, s.y, z), Fraction = (z - s.z) / (e.z - s.z), StartSolid = false }
		end
		return { Hit = false, Fraction = 1, HitPos = e }
	end
	return realTrace(t)
end

-- ================================================================== 1) dragged body
local BIPED = { "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Head1",
	"ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Thigh",
	"ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_R_Foot" }
local MAT = {}
MAT.__index = MAT
function MAT:GetTranslation() return Vector(self.p) end
local rag = M.Ent("prop_ragdoll", { model = "models/humans/group01/male_07.mdl", bones = {} })
function rag:GetBoneMatrix(b)
	if #self.bones == 0 then return nil end
	return setmetatable({ p = self.pos + Vector(-b * 6, (b % 2) * 4, 4) }, MAT)
end
_G.ents.FindByClass = function(c) local o = {} for _, e in ipairs(M.ents) do if e.valid and e.class == c then o[#o + 1] = e end end return o end
local d = { btype = 0, oxy = 0.7 }
G.Entities.domains[rag] = d
-- first frame: no bones yet
M.now = 10
rag.pos = Vector(-200, 0, 0)
SM.Update()
check(SM.parts[rag.model] == nil, "a body without bones yet: no (empty) part list kept for its model")
-- its bones arrive; it is bloody and dragged along x at 45 u/s
rag.bones = BIPED
A = G.Anatomy
A.Cache[rag.model] = nil
for b = 0, #BIPED - 1 do SM.AddWet(d, rag, b, rag.pos, 6000) end
impacts = {}
for k = 1, 60 do
	M.now = 10 + k * 0.1
	rag.pos = Vector(-200 + k * 4.5, 0, 0)
	SM.Update()
	Pump()
end
local smears = 0
for _, i in ipairs(impacts) do if i.kind == 3 then smears = smears + 1 end end
check(SM.parts[rag.model] and #SM.parts[rag.model] > 0, "its parts are found once the bones exist (" .. #(SM.parts[rag.model] or {}) .. ")")
check(smears > 20, "dragged body leaves smears (" .. smears .. ", stats " .. SM.stats.smears .. ")")
rag.valid = false

-- ================================================================== 2) props
G.cv.props:SetBool(true)
M.Load({ "cl_props.lua" })
local PR = G.Props
_G.ents.FindInSphere = function() local o = {} for _, e in ipairs(M.ents) do if e.valid then o[#o + 1] = e end end return o end

-- a drum lying on its side (axis along y, radius 12, 45 long) rolling along x; turning about y as it rolls
local function Drum(x0)
	local e = M.Ent("prop_physics", { model = "models/props_c17/oildrum001.mdl", mt = MOVETYPE_VPHYSICS })
	e.pos, e.roll = Vector(x0, 0, 12), 0
	function e:OBBMins() return Vector(-12, -22.5, -12) end
	function e:OBBMaxs() return Vector(12, 22.5, 12) end
	function e:GetAngles() return { p = math.deg(self.roll) % 360, y = 0, r = 0 } end
	function e:LocalToWorld(lp)
		local c, s = math.cos(self.roll), math.sin(self.roll)
		return self.pos + Vector(c * lp.x + s * lp.z, lp.y, -s * lp.x + c * lp.z)
	end
	function e:WorldToLocal(wp)
		local d = wp - self.pos
		local c, s = math.cos(self.roll), math.sin(self.roll)
		return Vector(c * d.x - s * d.z, d.y, s * d.x + c * d.z)
	end
	function e.Bottom(x, y)
		if math.abs(y) > 22.5 then return nil end
		local dx = x - e.pos.x
		if math.abs(dx) >= 12 then return nil end
		return e.pos.z - math.sqrt(144 - dx * dx)
	end
	return e
end
-- a crate (20 x 20 x 20) sliding along x
local function Crate(x0)
	local e = M.Ent("prop_physics", { model = "models/props_junk/wood_crate001a.mdl", mt = MOVETYPE_VPHYSICS })
	e.pos = Vector(x0, 0, 10)
	function e:OBBMins() return Vector(-10, -10, -10) end
	function e:OBBMaxs() return Vector(10, 10, 10) end
	function e:GetAngles() return { p = 0, y = 0, r = 0 } end
	function e:LocalToWorld(lp) return self.pos + lp end
	function e:WorldToLocal(wp) return wp - self.pos end
	function e.Bottom(x, y)
		if math.abs(x - e.pos.x) > 10 or math.abs(y) > 10 then return nil end
		return e.pos.z - 10
	end
	return e
end

local function Run(e, v0, decel, rolls, T)
	impacts, bodyImpacts, pending = {}, {}, {}
	PR.Clear()
	for k in pairs(PR.stats) do PR.stats[k] = 0 end
	prop = e
	local v, t0 = v0, M.now
	local dt = 1 / 60
	local pushX, smearX = {}, {}
	while M.now - t0 < T do
		M.now = M.now + dt
		v = math.max(v - decel * dt, 0)
		e.pos = e.pos + Vector(v * dt, 0, 0)
		if rolls then e.roll = e.roll + v * dt / 12 end
		Pump()
		PR.Update()
	end
	for _, i in ipairs(impacts) do
		if i.kind == 4 then pushX[#pushX + 1] = i.pos.x end
		if i.kind == 3 then smearX[#smearX + 1] = i.pos.x end
	end
	e.valid = false
	return pushX, smearX, PR.stats
end
local function range(t) local a, b = math.huge, -math.huge for _, x in ipairs(t) do a, b = math.min(a, x), math.max(b, x) end return a, b end

-- rolling drum: 170 u/s, rolling to a stop ~250 units on
M.now = 100
local drum = Drum(-130)
local pushX, smearX, st = Run(drum, 170, 58, true, 5)
local a, b = range(pushX)
check(#pushX > 0, string.format("rolling drum wipes / shoves the pool it rolls through (%d pushes, x %.0f..%.0f)", #pushX, a, b))
local inPool = #pushX > 0 and a >= POOL.x0 - 15 and b <= POOL.x1 + 15
check(inPool, "the pushes are where the pool is (answers used where they were asked)")
check(st.pickups > 0, "the drum picks up blood from it (" .. st.pickups .. " pickups)")
local after = 0
for _, x in ipairs(smearX) do if x > POOL.x1 then after = after + 1 end end
local sa, sb = range(smearX)
check(after > 5, string.format("then leaves a bloody track beyond the pool (%d smears there, x %.0f..%.0f)", after, sa, sb))
local typed = true
for _, bi in ipairs(bodyImpacts) do if not bi.extra or bi.extra.btype ~= POOL.btype then typed = false end end
check(#bodyImpacts > 0 and typed, "what it picked up is the pool's blood type")

-- sliding crate at 60 u/s through the pool, slowing to a stop
M.now = 200
local crate = Crate(-80)
local pX, sX, st2 = Run(crate, 60, 9, false, 6)
local after2 = 0
for _, x in ipairs(sX) do if x > POOL.x1 then after2 = after2 + 1 end end
check(#pX > 0 and st2.pickups > 0, "sliding crate wipes the pool and picks it up (" .. #pX .. " pushes, " .. st2.pickups .. " pickups)")
check(after2 > 5, "and smears it out behind it (" .. after2 .. ")")

-- a resting prop costs no new contact traces
M.now = 300
local still = Crate(200)
prop = still
PR.Clear()
local n0 = 0
local tr0 = util.TraceLine
util.TraceLine = function(t) if t.ignoreworld then n0 = n0 + 1 end return tr0(t) end
for k = 1, 30 do M.now = M.now + 0.1 PR.Update() end
util.TraceLine = tr0
check(n0 <= 16, "a prop at rest is traced once, then left (" .. n0 .. " contact traces in 3 s)")
still.valid = false

check(#M.errors == 0, "no errors (" .. #M.errors .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
