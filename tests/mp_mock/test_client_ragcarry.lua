-- (1.26.8, 27 Oct) GHM: "blood back splatter doesn't always carry over from the NPC state to the ragdoll state, so it
-- does not always appear" (a .357 through the chest, five kills, never a splat on the wall behind). The blood a bullet
-- throws must fly whatever form the body has on this client when the hit comes: the NPC, its ragdoll that cannot be
-- traced through, no body yet (the NPC gone, its ragdoll not known), or the NPC with its ragdoll on top of it.
-- And PhysBlood on a client alone with Z-City (the server does not run it). (client, mocked GMod)
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
function isvector(x) return type(x) == "table" and x.x ~= nil and x.y ~= nil and x.z ~= nil end
function isentity(x) return type(x) == "table" and x.IsValid ~= nil and x.x == nil end
G.Anatomy.GetSkeleton = function() return nil end
local drops, stains, bodyImpacts = {}, {}, {}
G.Entities = { Impact = function(ent, pos) bodyImpacts[#bodyImpacts + 1] = { ent = ent, pos = pos } return true end, domains = {},
	Get = function() return nil end, Transfer = function() return false end }
G.Particles = { Spray = function() end, Spawn = function(o) drops[#drops + 1] = o end, Drips = function() end, Hang = function() end,
	Burst = function(o) return o.count end, Thin = function() return 1 end, ThinPrio = function() return 1 end, Count = function() return 0 end }
G.Surfaces = { Impact = function(pos, n) stains[#stains + 1] = { pos = pos, n = n } return true end, IsGround = function() return true end }
G.Prof = { Count = function() end, Lap = function() end }
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
G.cv.mist:SetString("0")
RunConsoleCommand("ghmpb_crb_splats", "0")   -- stains (counted here) rather than splat decals
M.Load({ "cl_util.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local U = G.U
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n, b) return p, n, b end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.TraceBone = function() return nil end
M.Load({ "cl_wounds.lua" })
local W = G.Wounds
G.GPU = {}
G.Native = { Load = function() end }
G.Prof.Instrument = function() end
M.Load({ "cl_render.lua" })
hook.Remove("Think", "ghmpb_house")
local R = G.Render
local F = G.Forensic
function net.BytesLeft() return #M.readq * 4 end
local byIdx = {}
function Entity(i) local e = byIdx[i] if e and e.valid then return e end return NULL end

-- the world: floor at z = 0, a wall 1.2 m behind the body (x = 60); the body stands at x = 0, shot along +x from x = -250
local traceable = {}       -- entities the engine's trace can go through (not ragdolls of this client)
local overlap = nil        -- a ragdoll standing where the NPC stands, that nobody knows yet
local function Filtered(f, e)
	if f == nil then return false end
	if type(f) == "function" then return not f(e) end
	if f == e then return true end
	if type(f) == "table" and f.IsValid == nil then for _, x in ipairs(f) do if x == e then return true end end end
	return false
end
function util.TraceLine(t)
	local s, e = t.start, t.endpos
	if t.ignoreworld then
		local ent = type(t.filter) == "function" and nil
		for _, b in ipairs(traceable) do if t.filter(b) then ent = b end end
		if ent then return { Hit = true, Entity = ent, HitPos = s + (e - s) * 0.75, HitNormal = (s - e):GetNormalized(), Fraction = 0.75 } end
		return { Hit = false, HitPos = e, HitNormal = Vector(0, 0, 0), Fraction = 1, Entity = NULL }
	end
	-- a ragdoll's box round the body (-14..14 in x and y, up to 72): starts inside it are solid
	if overlap and not Filtered(t.filter, overlap) and math.abs(s.x) < 14 and math.abs(s.y) < 14 and s.z > 0 and s.z < 72 then
		return { Hit = true, StartSolid = true, HitPos = s, HitNormal = Vector(0, 0, 0), Fraction = 0, Entity = overlap }
	end
	if s.x < 60 and e.x >= 60 then
		local f = (60 - s.x) / (e.x - s.x)
		return { Hit = true, HitPos = s + (e - s) * f, HitNormal = Vector(-1, 0, 0), Fraction = f, HitWorld = true, Entity = NULL }
	end
	if s.z >= 0 and e.z < 0 then
		local f = s.z / (s.z - e.z)
		return { Hit = true, HitPos = s + (e - s) * f, HitNormal = Vector(0, 0, 1), Fraction = f, HitWorld = true, Entity = NULL }
	end
	return { Hit = false, HitPos = e, HitNormal = Vector(0, 0, 0), Fraction = 1, Entity = NULL }
end
ents.FindInSphere = function(pos, r)
	local o = {}
	if overlap and pos:Distance(Vector(0, 0, pos.z)) < r + 14 then o[#o + 1] = overlap end
	return o
end
local nextIdx = 40
local function Body(class, o)
	o = o or {}
	nextIdx = nextIdx + 1
	local e = { valid = true, class = class, idx = o.idx or nextIdx, pos = o.pos or Vector(0, 0, 0), nw2 = {}, nwe = {} }
	function e:IsValid() return self.valid end
	function e:GetBoneMatrix() return {} end
	function e:SetupBones() end
	function e:EntIndex() return self.idx end
	function e:IsRagdoll() return class == "prop_ragdoll" or class == "class C_ClientRagdoll" end
	function e:IsNPC() return string.sub(class, 1, 4) == "npc_" end
	function e:IsPlayer() return class == "player" end
	function e:Alive() return true end
	function e:GetNW2Int(k, d) local v = self.nw2[k] if v == nil then return d end return v end
	function e:SetNW2Int(k, v) self.nw2[k] = v end
	function e:GetNW2Bool(_, d) return d end
	function e:GetNW2Entity() return NULL end
	function e:GetNWEntity(k) return self.nwe[k] or NULL end
	function e:GetNoDraw() return false end
	function e:IsDormant() return false end
	function e:GetClass() return class end
	function e:GetModel() return "models/humans/group01/male_02.mdl" end
	function e:LookupBone() return 0 end
	function e:GetCreationTime() return M.now end
	function e:GetVelocity() return Vector(0, 0, 0) end
	function e:GetPos() return Vector(self.pos) end
	function e:WorldSpaceCenter() return self.pos + Vector(0, 0, 40) end
	function e:EyePos() return self.pos + Vector(0, 0, 64) end
	function e:GetModelScale() return 1 end
	function e:LookupAttachment() return 0 end
	function e:BoundingRadius() return 36 end
	function e:IsWorld() return false end
	function e:RemoveAllDecals() end
	function e:GetBloodColor() return self.bc or BLOOD_COLOR_RED end
	byIdx[e.idx] = e
	return e
end
local shooter = Body("player", { pos = Vector(-250, 0, 0) })
local function Count()
	local behind, front, floor = 0, 0, 0
	for _, s in ipairs(stains) do
		if s.n.x < -0.5 then behind = behind + 1 elseif s.n.z > 0.5 then floor = floor + 1 end
	end
	return behind, floor
end
local function Reset() drops, stains, bodyImpacts = {}, {}, {} M.now = M.now + 5 end
local function HitMsg(ent, idx, fatal)
	M.Recv("ghmpb_hit", nil, ent, Vector(-7, 0, 50), Vector(1, 0, 0), 55, DMG_BULLET, HITGROUP_CHEST, fatal, shooter, false, idx)
end
M.now = 100

-- ---------------- 1. the NPC is there: as before
Reset()
local npc = Body("npc_citizen")
traceable = { npc }
HitMsg(npc, npc.idx, true)
M.Advance(1)
local b1 = Count()
check(b1 > 0, "the NPC is there when the hit comes: blood on the wall behind (" .. b1 .. ")")
check(W.exitStats.trace >= 1, "its exit traced by the engine")

-- ---------------- 2. the hit comes after the NPC is gone (its ragdoll not known yet)
Reset()
local npc2 = Body("npc_citizen")
local idx2 = npc2.idx
hook.Run("EntityRemoved", npc2)
npc2.valid = false
local s0 = W.shotWorld or 0
HitMsg(NULL, idx2, true)
local queued = R.pendingByIdx[idx2] and R.pendingByIdx[idx2][1]
check(queued and queued.worldDone == true and (W.shotWorld or 0) == s0 + 1, "no body for the hit: its blood flies at once, the hit waits for the ragdoll")
M.Advance(0.05)
local rag2 = Body("prop_ragdoll")
M.Recv("ghmpb_rag", nil, NULL, rag2, idx2, rag2.idx)
local spat = 0
for _, d in ipairs(drops) do if d.owner == rag2 and d.prio then spat = spat + 1 end end
M.Advance(1)
local b2 = Count()
check(b2 > 0, "blood on the wall behind all the same (" .. b2 .. ")")
check(spat == 0, "the ragdoll does not throw the bullet's spatter again (" .. spat .. " drops)")
check(#bodyImpacts > 0 and bodyImpacts[1].ent == rag2, "the wound goes on the ragdoll when it comes")
check(W.bodies[rag2] and #W.bodies[rag2].emitters > 0, "and it bleeds there")

-- the colour of a body that is gone: yellow blood stays yellow
Reset()
local ant = Body("npc_citizen")
ant:SetNW2Int("ghmpb_blood", -10 - G.BLOOD_YELLOW)
hook.Run("EntityRemoved", ant)
ant.valid = false
local seen = {}
local oi = G.Surfaces.Impact
G.Surfaces.Impact = function(pos, n, vel, r, v, k, sp, st, res, tr, oxy, btype) seen[btype or -1] = true return oi(pos, n) end
HitMsg(NULL, ant.idx, true)
M.Advance(1)
G.Surfaces.Impact = oi
check(seen[G.BLOOD_YELLOW] and not seen[G.BLOOD_RED], "the blood of an NPC that is gone keeps its colour (yellow)")

-- ---------------- 3. the hit lands on the ragdoll, which the engine cannot trace through (a ragdoll of this client)
Reset()
local npc3 = Body("npc_citizen")
local rag3 = Body("class C_ClientRagdoll")
R.ragOf[npc3] = rag3
traceable = {}
local okBoxes = U.RayHitboxes
U.RayHitboxes = function(ent, start, delta)
	if ent == rag3 then return start + delta * 0.74, -delta:GetNormalized(), 0.74, 1 end
	return nil
end
local bx0 = W.exitStats.boxes
HitMsg(npc3, npc3.idx, true)
M.Advance(1)
local b3 = Count()
check(W.exitStats.boxes == bx0 + 1, "on a ragdoll: the exit found through its hitboxes")
check(b3 > 0, "blood on the wall behind (" .. b3 .. ")")
-- and a ragdoll that fell off the bullet's path: the exit where the body was
Reset()
U.RayHitboxes = function() return nil end
local g0 = W.exitStats.guessed
HitMsg(npc3, npc3.idx, false)
M.Advance(1)
local b3b = Count()
check(W.exitStats.guessed == g0 + 1 and b3b > 0, "a ragdoll no longer where the bullet went: the exit where the body was, blood on the wall (" .. b3b .. ")")
U.RayHitboxes = okBoxes

-- ---------------- 4. the NPC with its ragdoll on top of it, not known yet
Reset()
local npc4 = Body("npc_citizen")
traceable = { npc4 }
overlap = Body("prop_ragdoll")
HitMsg(npc4, npc4.idx, true)
M.Advance(1)
local b4 = Count()
check(b4 >= math.max(10, b1 * 0.5), "an unknown ragdoll where the NPC stands: the blood passes it, the wall behind gets it (" .. b4 .. ", " .. b1 .. " without it)")
local flt = F.PlumeFilter(npc4, Vector(10, 0, 50), {})
local has = false
for _, e in ipairs(flt) do if e == overlap then has = true end end
check(has, "the ragdoll there is left out of what the blood leaving the body can land on")
overlap = nil

-- ---------------- 5. the killing shot on the ragdoll still makes spurts (it hit a living body)
Reset()
local rag5 = Body("prop_ragdoll")
rag5:SetNW2Int("ghmpb_blood", 0)
traceable = { rag5 }
W.OnHit(rag5, Vector(-7, 0, 50), Vector(1, 0, 0), 55, DMG_BULLET, HITGROUP_CHEST, true, shooter)
local spurts = 0
for _, e in ipairs(W.bodies[rag5] and W.bodies[rag5].emitters or {}) do if e.kind == "spurt" then spurts = spurts + 1 end end
check(spurts > 0, "the killing shot that reached the ragdoll spurts like on the NPC (" .. spurts .. ")")

-- ---------------- 6. PhysBlood on this client alone (the server does not run it) with Z-City
util.NetworkStringToID = function(name) return 0 end
M.now = M.now + 5
check(G.ServerRuns() == false and G.LocalMode() == true, "the server does not run PhysBlood: this client works alone")
local zp = Body("player", { pos = Vector(0, 0, 0) })
zp.bc = DONT_BLEED
check(G.BloodTypeOf(zp) == G.BLOOD_RED, "Z-City switches the engine blood off on everyone: a player still bleeds red")
local robot = Body("npc_thing")
robot.bc = DONT_BLEED
function robot:GetModel() return "models/thing/blob.mdl" end
function robot:LookupBone() return nil end
check(G.BloodTypeOf(robot) == nil, "a thing that does not bleed still does not (" .. tostring(G.BloodTypeOf(robot)) .. ", class " .. tostring(G.ClassBloodType["npc_thing"]) .. ", model " .. tostring(G.ModelBloodType(robot:GetModel())) .. ")")
-- Z-City's own hit messages make the hits
_G.hg = { organism = {}, bloodparticles1 = {}, bloodparticles2 = {}, addBloodPart = function() end, addBloodPart2 = function() end,
	applyFountain = function() end, explode = function() end }
net.Receive("hg_bloodimpact", function() end)
function Color() return {} end
MsgC = MsgC or function() end
function player.GetAll() return { shooter, zp } end
ents.FindInSphere = function(pos, r) return pos:Distance(Vector(0, 0, 40)) < r + 20 and { zp } or {} end
G.Entities.Remove = function() end
M.Load({ "cl_zcity.lua" })
local ZC = G.ZC
M.Advance(0.3)
check(ZC.installed and net.Receivers.hg_bloodimpact == ZC.our.net.hg_bloodimpact, "Z-City's blood is PhysBlood's in this game")
Reset()
traceable = { zp }
-- the entry at once (a tenth of the damage, a short direction), then the same entry again with the full damage
M.Recv("hg_bloodimpact", nil, Vector(-7, 0, 50), Vector(1, 0, 0) / 15, 3.5, 1)
M.Recv("hg_bloodimpact", nil, Vector(-7, 0.5, 50), Vector(12, 0, 0), 35, 1)
M.Advance(1)
local zb = W.bodies[zp]
local zbehind = Count()
check(zb and #zb.wounds == 1, "one bullet, one wound on the player (" .. (zb and #zb.wounds or 0) .. "), the repeat left out (" .. ZC.lstats.merged .. ")")
check(zbehind > 0, "through the body: blood on the wall behind (" .. zbehind .. ")")
check(#bodyImpacts > 0 and bodyImpacts[1].ent == zp, "the wound is on the player's body")
-- with PhysBlood on the server, the server's hits count and Z-City's messages only spray
util.NetworkStringToID = function(name) return 7 end
M.now = M.now + 5
Reset()
local h0 = ZC.lstats.hits
M.Recv("hg_bloodimpact", nil, Vector(-7, 0, 30), Vector(12, 0, 0), 35, 1)
check(ZC.lstats.hits == h0, "PhysBlood on the server: Z-City's message does not make a second hit")
check(G.ServerRuns() == true and G.BloodTypeOf(zp) == nil, "with PhysBlood on the server: its word counts again")
print(string.format("     exits: traced %d, hitboxes %d, guessed %d; blood thrown before the body %d", W.exitStats.trace, W.exitStats.boxes,
	W.exitStats.guessed, W.shotWorld or 0))
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
