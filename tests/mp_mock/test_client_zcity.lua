-- Client-side Z-City test: the player's blood follows his body, Z-City's blood functions are taken over and given back
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB

-- stubs for the parts of PhysBlood the module talks to
local calls = {}
local function rec(name) return function(...) calls[#calls + 1] = { name, ... } end end
local function count(name) local n = 0 for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end return n end
G.U = { NearestBone = function() return 1 end, EntitySurface = function(_, p, d) return p, -d end, RandRange = function(a, b) return (a + b) / 2 end,
	ConeDir = function(d) return d end }
G.Particles = { Hang = rec("Hang"), Spawn = rec("Spawn"), Spray = rec("Spray"), Mist = rec("Mist"), WATERMASK = 48 }
G.Water = { Enter = rec("Water") }
G.Entities = { domains = {}, Remove = function(e) G.Entities.domains[e] = nil end, Impact = rec("Impact") }
G.Wounds = { bodies = {} }
function G.Wounds.Body(e) local b = G.Wounds.bodies[e] if not b then b = { ent = e, wounds = {}, emitters = {} } G.Wounds.bodies[e] = b end return b end
function G.Wounds.AddEmitter(b, e) b.emitters[#b.emitters + 1] = e calls[#calls + 1] = { "Emitter", e.kind } end
function G.Wounds.OnDeath(e) local b = G.Wounds.Body(e) b.dead = true calls[#calls + 1] = { "Death", e } end
G.Wounds.Stump = rec("Stump")
G.Render = {}
function G.Render.Transfer(from, to, living)
	calls[#calls + 1] = { "Transfer", from, to, living }
	local E, W = G.Entities, G.Wounds
	if E.domains[from] then E.domains[to] = E.domains[from] E.domains[from] = nil end
	if W.bodies[from] then
		local b = W.bodies[from] W.bodies[from] = nil b.ent = to
		if not living then b.dead = true end
		W.bodies[to] = b
	end
end
G.Anatomy.GetSkeleton = function() return { neck = 2 } end
G.Prof = { Lap = function() end }
-- client entity API
local Emeta = getmetatable(M.Ent("info_null"))
function Emeta:GetBoneMatrix(b) return { GetTranslation = function() return self.pos + Vector(0, 0, 10 * b) end,
	GetAngles = function() return { Forward = function() return Vector(1, 0, 0) end } end } end
function Emeta:LookupBone() return 1 end
function Emeta:SetupBones() end
function LocalPlayer() return M.lp end
function EyePos() return Vector(0, 0, 64) end
function isentity(x) return type(x) == "table" and getmetatable(x) == Emeta end
function isvector(x) return type(x) == "table" and x.x ~= nil and x.y ~= nil and x.z ~= nil end
function isangle(x) return false end

M.Load({ "cl_zcity.lua" })
local ZC = G.ZC

-- Z-City's client side
local theirs = {}
_G.hg = { organism = {}, bloodparticles1 = { 1, 2, 3 }, bloodparticles2 = {} }
for _, k in ipairs({ "addBloodPart", "addBloodPart2", "applyFountain", "explode" }) do theirs[k] = function() end hg[k] = theirs[k] end
for _, n in ipairs({ "hg_bloodimpact", "addfountain", "bloodsquirt", "bloodsquirt2" }) do net.Receive(n, function() end) end
local theirNet = net.Receivers.bloodsquirt
hook.Add("PostDrawTranslucentRenderables", "bloodpartciels", function() end)
hook.Add("HG_OrganismChanged", "explodelegs", function() end)

local p = M.Ent("player", { pos = Vector(0, 0, 0) })
M.lp = p
M.Advance(1.2)
check(ZC.installed, "taken over once Z-City is there")
check(hg.addBloodPart == ZC.our.addBloodPart and net.Receivers.bloodsquirt == ZC.our.net.bloodsquirt, "functions and net messages are PhysBlood's")
check(hook.GetTable().PostDrawTranslucentRenderables.bloodpartciels == nil, "their particle draw hook is out")
check(hook.GetTable().HG_OrganismChanged.explodelegs ~= nil, "their other hooks keep running")
check(#hg.bloodparticles1 == 0, "their particles cleared")

-- a wound drip from Z-City becomes a hanging PhysBlood drop + blood on the skin
p:SetNW2Int("ghmpb_blood", 0)
hg.addBloodPart(Vector(0, 0, 40), Vector(3, 0, 0), nil, 1, 1, false, nil, p)
check(count("Hang") == 1 and count("Impact") == 1, "wound drip -> hanging drop and film")
hg.addBloodPart(Vector(0, 0, 40), Vector(80, 0, 0), nil, 1, 1, true, nil, p)
check(count("Spawn") == 1, "arterial drop -> flying drop")
hg.addBloodPart2(Vector(0, 0, 40), Vector(0, 0, 0), nil, nil, nil, nil, true, nil, p)
check(count("Mist") == 1, "a puff out of water -> mist")

-- knocked down: the blood goes onto the ragdoll, alive
G.Wounds.Body(p) G.Entities.domains[p] = { model = p.model }
local rag = M.Ent("prop_ragdoll", { pos = Vector(0, 40, 0) })
p:SetNWEntity("FakeRagdoll", rag) rag:SetNWEntity("ply", p)
M.Advance(0.3)
check(G.Entities.domains[rag] and not G.Entities.domains[p], "blood moved onto the ragdoll")
local b = G.Wounds.bodies[rag]
check(b and not b.dead, "and the body there is alive")
check(G.LivingRagdoll(rag), "the ragdoll counts as a living body")
check(ZC.HitTarget(p) == rag, "hits on the player land on his ragdoll")
-- getting up: the ragdoll is removed
p:SetNWEntity("FakeRagdoll", NULL)
rag:Remove()
M.Engine("EntityRemoved", rag, false)
check(G.Entities.domains[p] and not G.Entities.domains[rag], "blood back on the player when he gets up")
-- dying (not knocked down): death first on the player, then onto his corpse
local corpse = M.Ent("prop_ragdoll", { pos = Vector(0, 80, 0) })
p.alive = false
check(ZC.OnDeath(p, false), "death handled for the player")
check(G.Wounds.bodies[p] and G.Wounds.bodies[p].dead, "the body died where the blood was")
p:SetNWEntity("RagdollDeath", corpse)
M.Advance(0.3)
check(G.Wounds.bodies[corpse] and G.Wounds.bodies[corpse].dead and G.Entities.domains[corpse], "then went with him onto his corpse")
check(ZC.holder[p].living == false, "and stays there")
-- respawn
p.alive = true
p:SetNWEntity("RagdollDeath", NULL)
M.Advance(0.3)
check(G.Wounds.bodies[corpse] ~= nil and ZC.holder[p].ent == p and ZC.holder[p].living, "respawned clean, corpse keeps its blood")

-- squirts and stumps
M.Recv("bloodsquirt", p, corpse, "ValveBiped.Bip01_Head1", corpse:GetBoneMatrix(1), Vector(0, 80, 60), Vector(2, 0, 0))
check(count("Emitter") >= 1, "head-shot squirt -> PhysBlood jet")
M.Recv("addfountain", p, corpse, Vector(0, 0, 0))
check(count("Stump") == 1, "head blown off -> neck stump")
M.Engine("HG_OrganismChanged", { lleg = nil }, { owner = p, llegamputated = true })
check(count("Stump") == 2, "leg torn off -> stump")

-- (1.26.7) Z-City's blood impact message carries only a position: the blood is the nearest body's type
local ant = M.Ent("npc_antlion", { pos = Vector(600, 0, 0) })
ant.ghmpbType = G.BLOOD_YELLOW
local near = { ant, p, corpse }
ents.FindInSphere = function(pos, r)
	local t = {}
	for _, e in ipairs(near) do if IsValid(e) and e:WorldSpaceCenter():Distance(pos) <= r then t[#t + 1] = e end end
	return t
end
ZC.lastHitT = nil
local function lastSpray() local l for _, c in ipairs(calls) do if c[1] == "Spray" then l = c[2] end end return l end
M.Recv("hg_bloodimpact", p, Vector(605, 0, 0), Vector(-1, 0, 0), 1, 2)
local sp = lastSpray()
check(sp and sp.btype == G.BLOOD_YELLOW, "Z-City blood impact on an antlion: yellow blood (" .. tostring(sp and sp.btype) .. ")")
M.Recv("hg_bloodimpact", p, Vector(3000, 0, 0), Vector(-1, 0, 0), 1, 2)
sp = lastSpray()
check(sp and sp.btype == G.BLOOD_RED, "with no body near: red")

-- switching it off gives everything back
RunConsoleCommand("ghmpb_sv_zcity", "0")
M.Advance(1.2)
check(not ZC.installed and hg.addBloodPart == theirs.addBloodPart and net.Receivers.bloodsquirt == theirNet, "given back when switched off")
check(hook.GetTable().PostDrawTranslucentRenderables.bloodpartciels ~= nil, "their draw hook is back")
RunConsoleCommand("ghmpb_sv_zcity", "1")
M.Advance(1.2)
check(ZC.installed and hg.addBloodPart == ZC.our.addBloodPart, "and taken over again")

check(#M.errors == 0 and (G.Diag.lastError == nil), "no errors " .. tostring(G.Diag.lastError))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
