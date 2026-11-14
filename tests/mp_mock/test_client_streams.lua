-- (1.26.7, 27 Oct) spurts after a gunshot (Universal Directional Blood style) and the continuous 3D streams of jets,
-- spurts and pouring wounds: how many spurts, when, which way, that they follow the wound, that the stream falls, breaks
-- up, comes loose and is built into a valid mesh; off switches; no spurts from corpses (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function FrameTime() return 0.02 end
function GetConVarNumber(n) if n == "sv_gravity" then return 600 end return 0 end
function VectorRand() return Vector(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1) end
function LocalPlayer() return NULL end
function EyePos() return Vector(-300, 0, 64) end
-- (1.26.8) the streams check the view: looking at the body
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
function ScrW() return 1600 end
function ScrH() return 900 end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
G.Anatomy.GetSkeleton = function() return nil end
local drops = {}
G.Entities = { Impact = function() return true end, domains = {}, Get = function() return nil end }
G.Particles = { Spray = function() end, Spawn = function(o) drops[#drops + 1] = { o = o, t = M.now } end, Drips = function() end, Hang = function() end,
	Burst = function(o) return o.count end, Thin = function() return 1 end, ThinPrio = function() return 1 end, Count = function() return 0 end }
G.Surfaces = { Impact = function() return true end, IsGround = function() return true end }
G.BloodTypeOf = function() return 0 end
G.Prof = { Count = function() end, Lap = function() end }
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
G.cv.mist:SetString("0")
-- the VAT side the streams draw with
local matSet = 0
G.VAT = setmetatable({ Mat = function() matSet = matSet + 1 return {} end, ApplyLight = function() end, cvSize = { GetFloat = function() return 1 end } }, { __index = function() return function() end end })
local tris, verts, begun = 0, 0, nil
_G.MATERIAL_TRIANGLES = 2
_G.MATERIAL_QUADS = 3
-- (1.26.8) the streams are built of quads (4 vertices a face): counted as 2 triangles each
_G.mesh = {
	Begin = function(prim, n) assert(prim == MATERIAL_QUADS or prim == MATERIAL_TRIANGLES) begun = { n = n, v = 0, per = prim == MATERIAL_QUADS and 4 or 3 } end,
	End = function() assert(begun.v == begun.n * begun.per, "mesh: " .. begun.v .. " vertices for " .. begun.n .. " primitives") tris = tris + begun.n * (begun.per == 4 and 2 or 1) begun = nil end,
	Position = function(v) assert(v.x == v.x and v.z == v.z, "NaN position") end,
	Normal = function(v) local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) assert(l > 0.98 and l < 1.02, "normal length " .. l) end,
	TexCoord = function() end, TangentS = function() end, TangentT = function() end, UserData = function() end,
	AdvanceVertex = function() begun.v = begun.v + 1 verts = verts + 1 end,
}
_G.render = _G.render or {}
render.SuppressEngineLighting = function() end
render.SetMaterial = function() end
render.SetLocalModelLights = function() end
render.GetRenderTarget = function() return nil end
M.Load({ "cl_util.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua" })
local U = G.U
-- the wound's bone moves by `shift` (the body walks)
local shift = Vector(0, 0, 0)
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n, b) return p, n, b end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.BoneFrame = nil
U.BoneToWorld = function(_, _, p, n) return p and (p + shift) or nil, n and Vector(n) or nil end
U.TraceBone = function() return nil end
M.Load({ "cl_wounds.lua", "cl_streams.lua" })
local W, St = G.Wounds, G.Streams
local world = util.TraceLine
function util.TraceLine(t)
	if t.ignoreworld then
		return { Hit = false, HitPos = t.endpos, Fraction = 1 }
	end
	-- the floor
	if t.endpos.z <= 0 and t.start.z > 0 then
		local f = t.start.z / (t.start.z - t.endpos.z)
		return { Hit = true, HitPos = t.start + (t.endpos - t.start) * f, HitNormal = Vector(0, 0, 1), Fraction = f, HitWorld = true }
	end
	return { Hit = false, HitPos = t.endpos, Fraction = 1, HitNormal = Vector(0, 0, 1) }
end
local function Body(class)
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
local function SpurtOf(ent)
	local b = W.bodies[ent]
	if not b then return nil end
	for _, e in ipairs(b.emitters) do if e.kind == "spurt" then return e end end
end
local function Run(sec, each)
	local steps = math.floor(sec / 0.02 + 0.5)
	for _ = 1, steps do
		M.now = M.now + 0.02
		W.Update()
		M.Engine("Think")
		if each then each() end
	end
end

-- 1. a rifle-class hit on a living NPC
math.randomseed(7)
local npc = Body("npc_citizen")
M.now = 100
drops = {}
W.OnHit(npc, Vector(-6, 0, 50), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_CHEST, false, shooter)
local sp = SpurtOf(npc)
check(sp ~= nil, "a gunshot wound gets spurts")
local n0 = sp and sp.n or 0
check(n0 >= 2 and n0 <= 5, "40 damage: 2-5 spurts (" .. n0 .. ")")
check(sp and sp.nextT - M.now >= 0.09 and sp.nextT - M.now <= 0.41, "the first spurt 0.1-0.4 s after the hit")
local hitDrops = #drops
local bursts, lastBurst, gaps, fed0 = 0, nil, {}, St.stats.fed
local maxSamples, fellBelow, headOnWound, drawnTris = 0, false, true, 0
local burstStart = {}
Run(7, function()
	local e = SpurtOf(npc)
	if e and e.burstEnd and not burstStart[e.burstEnd] then
		burstStart[e.burstEnd] = true
		bursts = bursts + 1
		if lastBurst then gaps[#gaps + 1] = M.now - lastBurst end
		lastBurst = M.now
	end
	for _, s in pairs(St.list) do
		maxSamples = math.max(maxSamples, #s.pts)
		local f, h = s.pts[1], s.pts[#s.pts]
		if f and h and #s.pts >= 4 then
			-- the front fell below where a straight line from the wound would put it
			local vz = h.vz
			if f.z < h.z + vz * (M.now - f.t) - 2 then fellBelow = true end
		end
	end
	if next(St.list) and drawnTris == 0 then
		local before = tris
		St.Draw()
		drawnTris = tris - before
	end
end)
check(bursts == n0, "every spurt played (" .. bursts .. " of " .. n0 .. ")")
local okGaps = #gaps > 0
for _, g in ipairs(gaps) do if g < 0.45 or g > 1.6 then okGaps = false end end
check(okGaps, "spurts 0.5-1.5 s apart")
local function SpurtDrops(from, sign)
	local n, along = 0, 0
	for i = from + 1, #drops do
		local o = drops[i].o
		local v = o.vel:Length()
		if v > 100 and v < 320 then
			n = n + 1
			if o.vel.x * sign > 0 then along = along + 1 end
		end
	end
	return n, along
end
local spDrops, back = SpurtDrops(hitDrops, -1)
check(spDrops >= n0 * 4, "the spurts throw drops (" .. spDrops .. ")")
check(spDrops > 0 and back / spDrops > 0.8, "no exit wound: out of the entry wound, back towards the shooter (" .. back .. " of " .. spDrops .. ")")
check(St.stats.fed > fed0, "the spurts feed streams")
check(maxSamples >= 4 and maxSamples <= 26, "a stream has a few to 26 samples (" .. maxSamples .. ")")
check(fellBelow, "the stream bends down under gravity")
check(drawnTris > 0, "the stream is built into a mesh (" .. drawnTris .. " triangles, vertices checked)")
check(SpurtOf(npc) == nil, "the spurt emitter is gone when its spurts are done")
Run(1)
check(next(St.list) == nil, "streams end after the feed stops")

-- 1b. the bullet goes through: the spurts come out of the exit wound along its path
St.Clear()
local npcX = Body("npc_citizen")
local exitTrace = true
local tl0 = util.TraceLine
function util.TraceLine(t)
	if t.ignoreworld and exitTrace then
		return { Hit = true, Entity = npcX, HitPos = Vector(6, 0, 50), HitNormal = Vector(1, 0, 0), Fraction = 0.75 }
	end
	return tl0(t)
end
local fromX = #drops
W.OnHit(npcX, Vector(-6, 0, 50), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_CHEST, false, shooter)
local spX = SpurtOf(npcX)
check(spX ~= nil and spX.lpos and spX.lpos.x > 0, "a through-and-through shot spurts from the exit wound")
local afterHit = #drops
Run(4)
local nX, fwdX = 0, 0
for i = afterHit + 1, #drops do
	local o = drops[i].o
	local v = o.vel:Length()
	if o.pos.x > 0 and v > 100 and v < 320 then nX = nX + 1 if o.vel.x > 0 then fwdX = fwdX + 1 end end
end
check(nX > 0 and fwdX / nX > 0.8, "along the bullet's path (" .. fwdX .. " of " .. nX .. ")")
util.TraceLine = tl0
Run(1)

-- 2. the stream stays on a moving wound and comes loose when the feed stops
St.Clear()
local key = {}
local wound = Vector(0, 0, 40)
local function src() return wound + Vector(0, 0, 0), Vector(180, 0, 60) end
St.Feed(key, src, 0, npc, 1, 0.3)
local follow = true
for i = 1, 10 do
	wound = Vector(i * 1.5, 0, 40)
	M.now = M.now + 0.02
	M.Engine("Think")
	local s = St.list[key]
	local h = s and s.pts[#s.pts]
	if not h or math.abs(h.x - wound.x) > 1e-6 then follow = false end
end
check(follow, "the stream's start follows the moving wound")
local s = St.list[key]
local nBefore = s and #s.pts or 0
check(nBefore >= 4, "samples laid along the way, the oldest broken off into drops (" .. nBefore .. ")")
Run(0.2)
s = St.list[key]
local loose = s == nil or (s.pts[#s.pts] == nil) or math.abs(s.pts[#s.pts].x - wound.x) > 1
check(loose, "after the feed ends the stream comes loose and flies on")
Run(0.6)
check(St.list[key] == nil, "and is gone soon after")
-- a stream that starts again is a second piece, not joined across the gap
St.Clear()
local function slow() return wound, Vector(60, 0, 20) end
St.Feed(key, slow, 0, npc, 1, 0.06)
Run(0.1)
St.Feed(key, slow, 0, npc, 1, 0.06)
Run(0.04)
local pieces = 0
for _, p in ipairs(St.list[key] and St.list[key].pts or {}) do if p.first then pieces = pieces + 1 end end
check(pieces == 2, "a stream that starts again is two pieces (" .. pieces .. ")")
local before = tris
St.Draw()
check(tris > before, "two pieces draw")

-- 3. an arterial jet feeds a stream
St.Clear()
local npc2 = Body("npc_citizen")
local b2 = W.Body(npc2)
b2.btype = 0
W.AddEmitter(b2, { kind = "artery", bone = 0, lpos = Vector(0, 0, 50), lnrm = Vector(1, 0, 0), rate = 4, reservoir = 70, stop = M.now + 20,
	surface = 0.1, radius = 0.35, pulseHz = 1.25, art = 1, jet = 230, oxy = 1 })
local fed1 = St.stats.fed
local seen = false
Run(2, function() if St.list[b2.emitters[1]] then seen = true end end)
check(St.stats.fed > fed1 and seen, "an arterial jet is drawn as a stream")

-- 4. off switches, and corpses
St.Clear()
local npc3 = Body("npc_citizen")
W.cvSpurts:SetString("0")
W.OnHit(npc3, Vector(-6, 0, 50), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_CHEST, false, shooter)
check(SpurtOf(npc3) == nil, "ghmpb_spurts 0: no spurts")
W.cvSpurts:SetString("1")
local rag = Body("prop_ragdoll")
local br = W.Body(rag)
br.dead, br.deathTime = true, M.now - 2
W.OnHit(rag, Vector(-6, 0, 50), Vector(1, 0, 0), 40, DMG_BULLET, HITGROUP_CHEST, false, shooter)
check(SpurtOf(rag) == nil, "shooting a corpse: no spurts")
St.cvOn:SetString("0")
St.Feed({}, src, 0, npc, 1, 0.2)
check(next(St.list) == nil, "ghmpb_streams 0: no streams")
St.cvOn:SetString("1")
-- 5. small damage: no spurts
local npc4 = Body("npc_citizen")
W.OnHit(npc4, Vector(-6, 0, 50), Vector(1, 0, 0), 6, DMG_BULLET, HITGROUP_CHEST, false, shooter)
check(SpurtOf(npc4) == nil, "under 10 damage: no spurts")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
