-- Elements on the server (1.17.0): wet-blood map in single player, electricity through connected wet blood, element
-- events from damage, sounds and blasts (luajit test_server_elements.lua)
local M = dofile("gmod.lua")
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.sp = true
-- engine pieces the elements use
function Angle(p, y, r) return { p = p, y = y, r = r } end
_G.SCREENFADE = { IN = 1 }
_G.ents.FindInSphere = function(pos, r)
	local o = {}
	for _, e in ipairs(M.ents) do if e.valid and e:GetPos():DistToSqr(pos) < r * r then o[#o + 1] = e end end
	return o
end
_G.ents.FindByClass = function() return {} end
function game.GetWorld() return M.world end
function game.GetAmmoID() return -1 end
function game.GetAmmoDamageType() return 0 end
local E = getmetatable(M.Ent("info_null"))
function E:OnGround() return self.air ~= true end
function E:ViewPunch() self.punched = true end
function E:ScreenFade() self.faded = true end
function E:EmitSound(s) self.snd = s end
function E:GetParent() return NULL end
function E:GetShootPos() return self.pos + Vector(0, 0, 64) end
function E:IsNextBot() return false end
function DamageInfo()
	local d = M.Dmg({ amount = 0, type = 0, pos = Vector(0, 0, 0) })
	function d:SetAttacker(a) self.att = a end
	function d:SetInflictor(i) self.inf = i end
	function d:SetDamagePosition(p) self.pos = p end
	function d:SetDamageForce(f) self.force = f end
	return d
end
function E:TakeDamageInfo(d)
	self.shocks = (self.shocks or 0) + 1
	self.lastDmg = d
	M.Engine("EntityTakeDamage", self, d)
	self.health = self.health - d:GetDamage()
end
M.world = M.Ent("worldspawn")
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua", "sv_compat.lua", "sv_core.lua", "sv_zcity.lua", "sv_history.lua", "sv_elements.lua", "sv_mp.lua" })
local G = GHMPB
local H, EL = G.Hist, G.Elem
local up = Vector(0, 0, 1)

check(H.On() == true and H.SendOn() == true, "single player: blood records kept and handed out (far events, 1.23.2)")
-- three pools: A and B touching, C far away
local A = H.Add(2, Vector(0, 0, 0), up, 40000, 14, 0, {})
local B = H.Add(2, Vector(40, 0, 0), up, 20000, 10, 0, {})
local C = H.Add(2, Vector(400, 0, 0), up, 40000, 14, 0, {})
check(A and B and C and H.count == 3, "three pools recorded")
local function npc(x, y, z) local n = M.Ent("npc_citizen", { pos = Vector(x, y, z or 0), health = 100 }) return n end
local v1, v2, v3, v4 = npc(5, 5), npc(44, 2), npc(402, 0), npc(-6, 4, 60)
v4.air = true
local ply = M.Ent("player", { pos = Vector(-300, 0, 0), health = 100 })
local ok, nrec, nhit = EL.Discharge(Vector(0, 0, 1), 1, ply)
check(ok and nrec == 2 and nhit == 2, "a discharge in pool A runs through A and B (" .. tostring(nrec) .. " pools) and shocks the two standing in them (" .. tostring(nhit) .. ")")
check(v1.shocks == 1 and v2.shocks == 1 and not v3.shocks and not v4.shocks, "shocked: v1 in A, v2 in B; not v3 (pool not connected) nor v4 (in the air)")
check(v1.lastDmg:GetDamageType() == DMG_SHOCK and v1.lastDmg:GetDamage() > 5 and v1.lastDmg:GetAttacker() == ply, "shock damage " .. v1.lastDmg:GetDamage() .. ", from the attacker")
check(v2.lastDmg:GetDamage() <= v1.lastDmg:GetDamage(), "less the farther along the blood")
check(#M.SentOf("ghmpb_arc") == 1, "arcs sent to the clients")
check(EL.Discharge(Vector(0, 0, 1), 1, ply) == false, "cooldown: no second discharge right away")
check(EL.stats.discharges == 1 and v1.shocks == 1, "the shock's own damage does not set off another discharge (recursion guard)")
M.Advance(0.5)
-- burning damage on a body standing in A: heat event, and the pool dries after a while
M.sent = {}
EL.OnDamage(v1, M.Dmg({ amount = 4, type = DMG_BURN, pos = Vector(5, 5, 40) }))
local heat = M.SentOf("ghmpb_elem")
check(#heat == 1 and heat[1].data[1] == G.EL.HEAT, "burn damage: a heat event")
for _ = 1, 40 do EL.Heat(Vector(0, 0, 0), 20, 0.5) end
check(A.dry == true and not B.dry, "fire boiled pool A dry (B is outside it)")
M.Advance(0.5)
check(EL.Discharge(Vector(0, 0, 1), 1, ply) == false, "dry blood does not conduct")
local ok2, n2 = EL.Discharge(Vector(40, 0, 1), 1, ply)
check(ok2 and n2 == 1, "pool B still conducts on its own")
-- frozen
M.Advance(0.5)
C.cold = true
M.Advance(45)
check(EL.Discharge(Vector(400, 0, 1), 1, ply) == false, "frozen blood (snow / ice / sub-zero) does not conduct after ~40 s")
-- wet time
local D = H.Add(2, Vector(0, 300, 0), up, 40000, 14, 0, {})
check(EL.Discharge(Vector(0, 300, 1), 1, ply) ~= false, "a fresh pool conducts")
M.Advance(G.cv_sv_wettime:GetFloat() * 3)
check(EL.Discharge(Vector(0, 300, 1), 1, ply) == false, "a pool that has dried does not")
-- damage types
M.sent = {}
local att = M.Ent("npc_combine_s", { pos = Vector(-200, 0, 0) })
EL.OnDamage(v1, M.Dmg({ amount = 20, type = DMG_ENERGYBEAM, pos = Vector(5, 5, 40), att = att }))
local las = M.SentOf("ghmpb_elem")
check(#las == 1 and las[1].data[1] == G.EL.LASER and las[1].data[7] == true and las[1].data[8] ~= nil, "energy beam: a laser event from the attacker's muzzle")
M.sent = {}
EL.OnDamage(v2, M.Dmg({ amount = 10, type = DMG_ACID, pos = Vector(44, 2, 40) }))
check(#M.SentOf("ghmpb_elem") == 1 and M.SentOf("ghmpb_elem")[1].data[1] == G.EL.ACID, "acid damage: an acid event")
M.sent = {}
local gren = M.Ent("npc_grenade_frag", { pos = Vector(100, 100, 0) })
EL.OnDamage(v1, M.Dmg({ amount = 90, type = DMG_BLAST, pos = Vector(5, 5, 40), inf = gren }))
EL.OnDamage(v2, M.Dmg({ amount = 60, type = DMG_BLAST, pos = Vector(44, 2, 40), inf = gren }))
local waves = 0
for _, m in ipairs(M.SentOf("ghmpb_elem")) do if m.data[1] == G.EL.WAVE then waves = waves + 1 end end
check(waves == 1, "one blast damaging two bodies: one shock wave (" .. waves .. ")")
local dusts, heats = {}, 0
for _, m in ipairs(M.SentOf("ghmpb_elem")) do
	if m.data[1] == G.EL.DUST then dusts[#dusts + 1] = m end
	if m.data[1] == G.EL.HEAT then heats = heats + 1 end
end
check(#dusts == 1 and heats == 1, "and one dust cloud, one flash (" .. #dusts .. ", " .. heats .. ")")
check(#dusts == 1 and dusts[1].data[3] >= 150 and dusts[1].data[3] <= 520, "the dust reaches 1.5 .. 5 m (" .. (dusts[1] and dusts[1].data[3] or -1) .. ")")
-- an explosion that hurts nothing is heard: wave, flash and dust all the same (once); map ambience is not
M.Advance(1)
M.sent = {}
local boom = M.Ent("npc_grenade_frag", { pos = Vector(600, 0, 10) })
M.Engine("EntityEmitSound", { SoundName = "weapons/explode3.wav", Entity = boom, Pos = Vector(600, 0, 10), SoundLevel = 140 })
M.Engine("EntityEmitSound", { SoundName = "weapons/explode4.wav", Entity = boom, Pos = Vector(605, 0, 10), SoundLevel = 140 })
M.Advance(0.1)
local kinds = {}
for _, m in ipairs(M.SentOf("ghmpb_elem")) do kinds[m.data[1]] = (kinds[m.data[1]] or 0) + 1 end
check(kinds[G.EL.DUST] == 1 and kinds[G.EL.WAVE] == 1 and kinds[G.EL.HEAT] == 1, "an explosion heard: one wave, flash and dust cloud")
M.Advance(1)
M.sent = {}
local amb = M.Ent("ambient_generic", { pos = Vector(-900, 0, 300) })
M.Engine("EntityEmitSound", { SoundName = "ambient/explosions/explode_4.wav", Entity = amb, Pos = Vector(-900, 0, 300), SoundLevel = 140 })
M.Engine("EntityEmitSound", { SoundName = "ambient/levels/labs/electric_explosion1.wav", Entity = spark, Pos = Vector(-900, 300, 20), SoundLevel = 140 })
M.Advance(0.1)
local d2 = 0
for _, m in ipairs(M.SentOf("ghmpb_elem")) do if m.data[1] == G.EL.DUST then d2 = d2 + 1 end end
check(d2 == 0, "distant explosions of the map's ambience and electric explosions: no dust")
-- explosions neither the damage nor the sound hook sees (1.18.0): env_explosion's input, explosives going off
local function dustCount() local n = 0 for _, m in ipairs(M.SentOf("ghmpb_elem")) do if m.data[1] == G.EL.DUST then n = n + 1 end end return n end
function E:GetKeyValues() return self.kv or {} end
function E:GetMaxHealth() return self.maxHealth or 0 end
M.Advance(1)
M.sent = {}
local envx = M.Ent("env_explosion", { pos = Vector(800, 800, 0), kv = { iMagnitude = 90 } })
M.Engine("AcceptInput", envx, "Explode")
M.Advance(0.1)
check(dustCount() == 1, "env_explosion's Explode input: a dust cloud")
M.Advance(1)
M.sent = {}
local g2 = M.Ent("npc_grenade_frag", { pos = Vector(-800, 800, 0) })
M.Engine("OnEntityCreated", g2)
M.Advance(0.1)
M.Engine("EntityRemoved", g2)
M.Advance(0.1)
check(dustCount() == 1, "a grenade going off on an empty floor: a dust cloud")
M.Advance(1)
M.sent = {}
local barrel = M.Ent("prop_physics", { pos = Vector(-800, -800, 0), model = "models/props_c17/oildrum001_explosive.mdl", health = 0, maxHealth = 10 })
local crate = M.Ent("prop_physics", { pos = Vector(-900, -800, 0), model = "models/props_junk/wood_crate001a.mdl", health = 0, maxHealth = 10 })
local removed = M.Ent("prop_physics", { pos = Vector(-800, -1200, 0), model = "models/props_c17/oildrum001_explosive.mdl", health = 10, maxHealth = 10 })
M.Engine("EntityRemoved", barrel)
M.Engine("EntityRemoved", crate)
M.Engine("EntityRemoved", removed)
M.Advance(0.1)
check(dustCount() == 1, "an explosive barrel blowing up: a dust cloud; a crate breaking, a barrel removed: none (" .. dustCount() .. ")")
M.Advance(1)
M.sent = {}
local g3 = M.Ent("npc_grenade_frag", { pos = Vector(1200, -800, 0) })
M.Engine("OnEntityCreated", g3)
M.Advance(0.1)
M.Engine("PreCleanupMap")
M.Engine("EntityRemoved", g3)
M.Engine("PostCleanupMap")
M.Advance(0.1)
check(dustCount() == 0, "the map cleaned up: removed grenades raise no dust")
M.sent = {}
EL.OnDamage(v1, M.Dmg({ amount = 50, type = DMG_DISSOLVE, pos = Vector(5, 5, 40) }))
check(#M.SentOf("ghmpb_elem") >= 1 and M.SentOf("ghmpb_elem")[1].data[1] == G.EL.DISSOLVE, "dissolve: the body's blood flashes off")
-- sounds of electricity near wet blood
M.Advance(1)
local P = H.Add(2, Vector(0, -300, 0), up, 40000, 14, 0, {})
local v5 = npc(4, -300)
local spark = M.Ent("env_spark", { pos = Vector(0, -300, 20) })
M.Engine("EntityEmitSound", { SoundName = "ambient/energy/spark3.wav", Entity = spark, Pos = Vector(0, -300, 20) })
M.Advance(0.1)
check(v5.shocks == 1, "a spark sounding next to wet blood electrifies it")
M.Engine("EntityEmitSound", { SoundName = "physics/flesh/flesh_impact1.wav", Entity = spark, Pos = Vector(0, -300, 20) })
M.Advance(0.5)
check(v5.shocks == 1, "other sounds do nothing")
-- switched off
RunConsoleCommand("ghmpb_sv_elements", "0")
M.sent = {}
EL.OnDamage(v1, M.Dmg({ amount = 4, type = DMG_BURN, pos = Vector(5, 5, 40) }))
check(#M.SentOf("ghmpb_elem") == 0 and H.On() == true, "ghmpb_sv_elements 0: nothing sent (the records stay: far events, 1.23.2)")
check(#M.errors == 0, "no errors (" .. #M.errors .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
