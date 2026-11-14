-- Flies (1.18.0, client): swarms at pools and the dead, the delay before they come, landing only where the blood is,
-- scattering, the cold, distance (luajit test_client_flies.lua)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local eye = Vector(0, -110, 40)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return Vector(0, 1, 0) end } end
function VectorRand() return Vector(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) end
function math.Rand(a, b) return a + (b - a) * math.random() end
math.randomseed(7)
local buzz = 0
_G.sound = { Play = function() buzz = buzz + 1 end }
local walkers = {}
_G.ents.FindInSphere = function(pos, r) local o = {} for _, e in ipairs(walkers) do if e.pos:Distance(pos) < r then o[#o + 1] = e end end return o end
-- outdoors: nothing above; the floor at z = 0
_G.util.TraceLine = function(td)
	if td.endpos.z > td.start.z then return { Hit = false } end
	return { Hit = true, HitPos = Vector(td.start.x, td.start.y, 0), HitNormal = Vector(0, 0, 1) }
end
G.Prof = { Count = function() end, Lap = function() return 0 end }
-- the blood: a pool of settled layers, a little stain elsewhere, a dead body
local S = { patches = {}, after = {}, PATCH_UNITS = 40 }
G.Surfaces = S
local function layer(list, x, y, vol, surf)
	local p = { key = x .. ":" .. y, origin = Vector(x - 20, y - 20, 0), center = Vector(x, y, 0), N = Vector(0, 0, 1),
		U = Vector(1, 0, 0), V = Vector(0, 1, 0), tvol = { [0] = vol }, bakedAt = M.now, surfName = surf or "concrete" }
	list[p.key] = p
	return p
end
layer(S.after, 0, 0, 30000)
layer(S.after, 40, 0, 12000)
layer(S.after, 400, 400, 600)            -- a few drops: no flies
layer(S.after, -900, 0, 40000, "snow")   -- a pool on snow: none
local E = { domains = {} }
G.Entities = E
local rag = M.Ent("prop_ragdoll")
rag.pos = Vector(200, 0, 4)
rag.GetPos = function(self) return self.pos end
rag.WorldSpaceCenter = function(self) return self.pos + Vector(0, 0, 6) end
rag.IsRagdoll = function() return true end
rag.LookupBone = function() return 6 end
rag.GetBoneMatrix = function() return { GetTranslation = function() return Vector(200, 20, 8) end, GetAngles = function() return { } end } end
E.domains[rag] = { created = M.now, subs = {} }
function LocalToWorld(p, a, op, oa) return op + p, a end
_G.angle_zero = {}
-- the probe answers: blood where x < 70 (the pool), none elsewhere
local probes = 0
-- (and a small pool at (610, 5): 4 u across, in a layer of 40)
local small = Vector(610, 5, 0)
poolGone = false
local smallProbes = 0
G.Smear = { RequestProbe = function(ps, pos)
	probes = probes + 1
	local inSmall = Vector(pos.x, pos.y, 0):Distance(small) < 4
	if math.abs(pos.x - 610) < 30 then smallProbes = smallProbes + 1 end
	ps.h = (((pos.x < 70 and pos.x > -30) and not poolGone) or inSmall) and 0.4 or 0 ps.s = 0 ps.hT = M.now end }
-- (a corpse: died a moment ago)
G.Wounds = { bodies = { [rag] = { dead = true, deathTime = M.now, wounds = { { bone = 6, lpos = Vector(0, 0, 2), lnrm = Vector(0, 0, 1) } } } } }
-- engine pieces for the living ragdolls (GHM Euphoria's knock-downs)
local EM = getmetatable(rag)
function EM:GetNW2Entity(k, d) local v = self.nw2[k] if v == nil then return d or NULL end return v end
function EM:SetNW2Entity(k, v) self.nw2[k] = v end
function EM:Alive() return (self.health or 0) > 0 end
function EM:GetNW2Bool(k, d) local v = self.nw2[k] if v == nil then return d end return v end
function EM:SetNW2Bool(k, v) self.nw2[k] = v end
_G.ents.FindByClass = function(pat)
	local o = {}
	local lp = "^" .. string.gsub(pat, "%*", ".*") .. "$"
	for _, e in ipairs(M.ents) do if e.valid and string.find(e.class, lp) then o[#o + 1] = e end end
	return o
end
M.Load({ "cl_flies.lua" })
local F = G.Flies

local function run(sec) for _ = 1, math.floor(sec / 0.05) do M.Advance(0.05) F.Update() end end
local function count(kind)
	local n, l = 0, 0
	for _, sw in pairs(F.swarms) do
		if not kind or sw.kind == kind then
			for _, f in ipairs(sw.flies) do n = n + 1 if f.state == "land" then l = l + 1 end end
		end
	end
	return n, l
end
run(10)
local n = 0 for _ in pairs(F.swarms) do n = n + 1 end
check(n == 2, "two swarms: the pool and the body - not the drops, not the pool on snow (" .. n .. ")")
check(count() == 0, "no flies in the first seconds")
run(150)
local pn, pl = count("pool")
local bn, bl = count("body")
check(pn >= 4 and bn >= 6, "after two and a half minutes: a swarm at the pool and at the body (" .. pn .. ", " .. bn .. ")")
check(pl >= 1 and bl >= 1, "some of them on the blood (" .. pl .. ", " .. bl .. ")")
-- they land only where the probes found blood
local bad = 0
for _, sw in pairs(F.swarms) do
	if sw.kind == "pool" then
		for _, f in ipairs(sw.flies) do if f.state == "land" and (f.pos.x >= 72 or f.pos.x <= -32) then bad = bad + 1 end end
		check(#sw.spots > 0, "landing spots found on the blood (" .. #sw.spots .. " of " .. probes .. " probes)")
	end
end
check(bad == 0, "no fly on bare floor (" .. bad .. ")")
-- someone walks up: they take off
local walker = M.Ent("player")
walker.pos = Vector(10, 0, 0)
walker.IsPlayer = function() return true end
walker.IsNPC = function() return false end
walker.IsNextBot = function() return false end
walker.GetVelocity = function() return Vector(150, 0, 0) end
walkers[1] = walker
run(0.4)
local _, pl2 = count("pool")
check(pl2 == 0, "someone walks through: the flies at the pool take off (" .. pl2 .. " still down)")
walkers[1] = nil
run(25)
local _, pl3 = count("pool")
check(pl3 >= 1, "and settle again afterwards (" .. pl3 .. ")")
check(buzz > 0, "their buzz near the player (" .. buzz .. ")")
-- (heard only close by: from 5 m off, none)
local eye0, b0 = eye, buzz
eye = Vector(0, -300, 64)
run(20)
check(buzz == b0, "5 m away from the flies: no buzz (" .. (buzz - b0) .. ")")
eye = eye0
-- someone standing at the blood: they keep off - well away from them, not circling round them (and their buzz with them)
walker.pos = Vector(20, 0, 0)
walker.GetVelocity = function() return Vector(0, 0, 0) end
walkers[1] = walker
run(4)
local minD, down = math.huge, 0
for _, sw in pairs(F.swarms) do
	if sw.kind == "pool" then
		for _, f in ipairs(sw.flies) do
			minD = math.min(minD, Vector(f.pos.x, f.pos.y, 0):Distance(walker.pos))
			if f.state == "land" then down = down + 1 end
		end
	end
end
check(down == 0 and minD > 45, "someone standing at the pool: the flies keep off, away from them (" .. down .. " down, nearest " .. math.floor(minD) .. " u)")
walkers[1] = nil
run(25)
local _, plb = count("pool")
check(plb >= 1, "they come back once the person has gone (" .. plb .. ")")
-- a small pool: the probes start where the blood landed (S.Impact notes it), so they find it
local sp = layer(S.after, 600, 0, 30000)
F.Note(Vector(610, 5, 0), 30000, 2, sp.center)
F.swarms["p" .. math.floor(600 / 96) .. ":" .. math.floor(0 / 96) .. ":0"] = nil
run(170)
local smallSpots = 0
for _, sw in pairs(F.swarms) do
	if sw.kind == "pool" and sw.pos.x > 300 then smallSpots = #sw.spots end
end
check(smallSpots >= 2, "a pool a few units across: landing spots found on it (" .. smallSpots .. " spots, " .. smallProbes .. " probes there)")
-- someone alive lying as a ragdoll (knocked down: GHM Euphoria) - even long bloodied - draws no flies; once dead, it does
local downed = M.Ent("player")
downed.pos = Vector(-200, 60, 0)
local drag = M.Ent("prop_ragdoll")
drag.pos = Vector(-200, 0, 4)
drag.GetPos = function(self) return self.pos end
drag.WorldSpaceCenter = function(self) return self.pos + Vector(0, 0, 6) end
drag.IsRagdoll = function() return true end
drag.LookupBone = function() return 6 end
drag.GetBoneMatrix = rag.GetBoneMatrix
downed:SetNW2Entity("GHMEU_Rag", drag)
E.domains[drag] = { created = M.now - 600, subs = {} }
-- (its blood came over from the living player: no time of death)
G.Wounds.bodies[drag] = { dead = false, wounds = { { bone = 6, lpos = Vector(0, 0, 2), lnrm = Vector(0, 0, 1) } } }
run(10)
local hasDowned = false
for _, sw in pairs(F.swarms) do if sw.ent == drag then hasDowned = true end end
check(not hasDowned, "a knocked-down player's ragdoll (alive, bloodied ten minutes ago): no swarm on him")
-- the zone around him: they keep off the blood next to him
-- he dies there (ghmpb_death): flies come, from his death on
downed.health = 0
G.Wounds.bodies[drag].dead, G.Wounds.bodies[drag].deathTime = true, M.now
run(5)
local swd
for _, sw in pairs(F.swarms) do if sw.ent == drag then swd = sw end end
check(swd ~= nil and swd.t0 >= M.now - 6 and #swd.flies == 0, "dead: a swarm on his body, its clock from his death (no flies yet)")
E.domains[drag] = nil
G.Wounds.bodies[drag] = nil
-- an NPC knocked down (its owner hidden and not sent to this client), hit on the ragdoll first (the wounds took it for
-- a corpse): the server's mark says it lives - no swarm
local nrag = M.Ent("prop_ragdoll")
nrag.pos = Vector(-200, -60, 4)
nrag.GetPos = function(self) return self.pos end
nrag.WorldSpaceCenter = function(self) return self.pos + Vector(0, 0, 6) end
nrag.IsRagdoll = function() return true end
nrag.LookupBone = function() return 6 end
nrag.GetBoneMatrix = rag.GetBoneMatrix
nrag:SetNW2Bool("ghmpb_alive", true)
E.domains[nrag] = { created = M.now - 300, subs = {} }
G.Wounds.bodies[nrag] = { dead = false, corpseT0 = M.now - 300, wounds = { { bone = 6, lpos = Vector(0, 0, 2), lnrm = Vector(0, 0, 1) } } }
run(6)
local onN = false
for _, sw in pairs(F.swarms) do if sw.ent == nrag then onN = true end end
check(not onN, "a knocked-down NPC's ragdoll marked alive by the server: no swarm")
-- it dies there; it thrashes for a while: no flies settle until it has lain still
nrag:SetNW2Bool("ghmpb_alive", false)
F.DELAY, F.RAMP = 0, 1
local t0 = M.now
for i = 1, 60 do
	nrag.pos = Vector(-200 + (i % 2) * 12, -60, 4)
	M.Advance(0.25) F.Update()
end
local swn
for _, sw in pairs(F.swarms) do if sw.ent == nrag then swn = sw end end
check(swn ~= nil and #swn.flies == 0, "dead but thrashing (15 s): a swarm, no flies on it yet (" .. (swn and #swn.flies or -1) .. ")")
run(14)
check(swn ~= nil and #swn.flies > 0, "lying still for a while: they come (" .. (swn and #swn.flies or -1) .. ")")
F.DELAY, F.RAMP = 20, 120
E.domains[nrag] = nil
G.Wounds.bodies[nrag] = nil
-- the pool's blood is gone (washed away, mopped up) though its layers are still listed: the spots are checked again,
-- dropped, and the flies leave
local function poolFlies() local n = 0 for _, sw in pairs(F.swarms) do if sw.kind == "pool" and sw.pos.x < 300 and sw.pos.x > -300 then n = n + #sw.flies end end return n end
local before = poolFlies()
poolGone = true
run(45)
check(before > 0 and poolFlies() == 0, "the pool's blood gone: its flies leave (" .. before .. " -> " .. poolFlies() .. ")")
poolGone = false
run(30)
check(poolFlies() > 0, "blood there again: they come back (" .. poolFlies() .. ")")
-- far away: not simulated
eye = Vector(5000, 5000, 64)
run(1)
check(count() == 0, "far away: no flies simulated")
eye = Vector(0, -110, 40)
run(0.2)
local _, back = count()
check(back >= 2, "coming back: they are already sitting on the blood (" .. back .. ")")
-- a blast scatters them
F.Disturb(Vector(300, 0, 0), 400)
local _, after = count()
check(after == 0, "a blast: all of them in the air")
-- the cold
StormFox2 = { Temperature = { Get = function() return -2 end } }
G.Elem = { Temperature = function() return -2 end }
F.wT = nil
run(3)
check(count() == 0, "in the cold: none")
G.Elem = nil
F.wT = nil
RunConsoleCommand("ghmpb_flies", "0")
run(1)
check(next(F.swarms) == nil, "ghmpb_flies 0: none")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
