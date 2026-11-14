-- Server-side multiplayer / Z-City test of PhysBlood under a mocked GMod (luajit test_server.lua [ulib])
local ULIB = arg[1] == "ulib"
local M = dofile("gmod.lua")
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end

if ULIB then
	-- ULib's hook library: priorities, monitor hooks run first and their returns are ignored
	_G.HOOK_MONITOR_HIGH, _G.HOOK_HIGH, _G.HOOK_NORMAL = -2, -1, 0
	_G.ULib = {}
	local H = hook.GetTable()
	local prio = {}
	function hook.Add(ev, id, f, p) H[ev] = H[ev] or {} H[ev][id] = f prio[ev .. "\0" .. tostring(id)] = p or 0 end
	function hook.Remove(ev, id) if H[ev] then H[ev][id] = nil end prio[ev .. "\0" .. tostring(id)] = nil end
	function hook.Call(ev, gm, ...)
		local t = H[ev]
		if t then
			local ids = {}
			for id in pairs(t) do ids[#ids + 1] = id end
			table.sort(ids, function(a, b)
				local pa, pb = prio[ev .. "\0" .. tostring(a)] or 0, prio[ev .. "\0" .. tostring(b)] or 0
				if pa ~= pb then return pa < pb end
				-- (the Z-City hook first among equals: worst case)
				if a == "homigrad-damage" then return true end
				if b == "homigrad-damage" then return false end
				return tostring(a) < tostring(b)
			end)
			for _, id in ipairs(ids) do
				local a, b, c = t[id](...)
				if a ~= nil and (prio[ev .. "\0" .. tostring(id)] or 0) ~= -2 then return a, b, c end
			end
		end
	end
end

M.addons = { { title = "GHM PhysBlood", wsid = "3333333333", mounted = true } }
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua", "sv_compat.lua", "sv_core.lua", "sv_zcity.lua", "sv_history.lua", "sv_mp.lua" })
local G = GHMPB
check(M.res[1] == "ws:3333333333", "workshop item found among mounted addons: " .. tostring(M.res[1]))

-- ---------------------------------------------------------------- Z-City (loaded after PhysBlood, like lua/autorun/loader.lua)
_G.hg = { organism = {}, GetCurrentCharacter = function(p) return p end }
local util_Decal = util.Decal         -- (Z-City keeps a local copy)
hook.Add("PlayerSpawn", "ResponsiveHits_PlayerSpawn", function(ent)
	if ent:GetBloodColor() == -1 then return end
	ent.bloodColorHitFix = ent:GetBloodColor()
	ent:SetBloodColor(-1)
end)
hook.Add("PostEntityTakeDamage", "ResponsiveHits_PostEntityTakeDamage", function(ent, dmg)
	if ent:IsPlayer() or ent:IsNPC() then util_Decal("Blood", dmg:GetDamagePosition(), dmg:GetDamagePosition()) end
end)
hook.Add("EntityTakeDamage", "homigrad-damage", function(ent, dmg)
	local org = ent.organism
	if not org then return end
	if ent:IsPlayer() and IsValid(ent.FakeRagdoll) then
		local r = ent.FakeRagdoll
		local blocked = M.Engine("EntityTakeDamage", r, dmg)
		M.Engine("PostEntityTakeDamage", r, dmg, not blocked)
		return true
	end
	if dmg:IsDamageType(DMG_CRUSH) then return true end
	if org.godmode then return true end
	org.lasthit = CurTime()
	dmg:ScaleDamage(0.15)
	return not ent:IsNPC()
end)
M.hookOrder = { EntityTakeDamage = { "homigrad-damage" }, PostEntityTakeDamage = { "ResponsiveHits_PostEntityTakeDamage" } }

local function Damage(ent, dmg)
	local blocked = M.Engine("EntityTakeDamage", ent, dmg)
	local took = not blocked
	if took then ent.health = ent.health - dmg:GetDamage() end
	M.Engine("PostEntityTakeDamage", ent, dmg, took)
end
local function Hits() return #M.SentOf("ghmpb_hit") end

-- two players: p1 at the origin, p2 far away; PVS = within 3000 units
M.pvs = function(p, pos) return p.pos:Distance(pos) < 3000 end
local p1 = M.Ent("player", { pos = Vector(0, 0, 0) })
local p2 = M.Ent("player", { pos = Vector(10000, 0, 0) })
p1.organism, p2.organism = { wounds = {} }, { wounds = {} }
M.Engine("OnEntityCreated", p1) M.Engine("OnEntityCreated", p2)
M.Engine("PlayerSpawn", p1) M.Engine("PlayerSpawn", p2)
M.Advance(0.3)
check(p1:GetBloodColor() == -1, "Z-City switched the engine blood off on the player")
check(p1:GetNW2Int("ghmpb_blood", -2) == 0, "PhysBlood still knows the player's blood is red (" .. tostring(p1:GetNW2Int("ghmpb_blood", -2)) .. ")")
check(G.Bleeds(p1), "the player bleeds")

M.Advance(2.5)
check(G.Priority.mode == (ULIB and "ulib" or "wrap"), "damage hooks run first: " .. tostring(G.Priority.mode))
check(hook.GetTable().PostEntityTakeDamage.ResponsiveHits_PostEntityTakeDamage == nil, "Z-City's hit decal hook taken out")

-- a shot player (Z-City blocks the damage and takes it in its organism)
local h0 = Hits()
Damage(p1, M.Dmg({ amount = 30, pos = Vector(0, 0, 40), att = p2 }))
check(Hits() == h0 + 1, "hit on a Z-City player reaches the clients")
local hit = M.SentOf("ghmpb_hit")[Hits()]
check(hit and math.abs(hit.data[4] - 30) < 0.01, "with the damage as it arrived (30, not Z-City's 4.5): " .. tostring(hit and hit.data[4]))
check(hit and type(hit.to) == "table" and #hit.to == 1 and hit.to[1] == p1, "sent to the players who see it (p1, not far-away p2)")
check(M.decals == 0, "no blood decal from Z-City (" .. M.decals .. ")")
check(util.Decal ~= nil and (function() util.Decal("Scorch") return M.decals == 1 end)(), "other decals pass")
M.decals = 0
check((function() util.Effect("BloodImpact") return M.effects == 0 end)(), "engine BloodImpact effect dropped")

-- a Z-City NPC (damage scaled to 15 %, not blocked)
local npc = M.Ent("npc_citizen", { pos = Vector(200, 0, 0), health = 100 })
npc.organism = { wounds = {} }
M.Engine("OnEntityCreated", npc)
M.Advance(0.2)
h0 = Hits()
Damage(npc, M.Dmg({ amount = 40, pos = Vector(200, 0, 40), att = p1 }))
hit = M.SentOf("ghmpb_hit")[Hits()]
check(Hits() == h0 + 1 and math.abs(hit.data[4] - 40) < 0.01, "Z-City NPC hit with full damage: " .. tostring(hit and hit.data[4]))

-- another addon that answers every damage event, added later (1.17.0: wrapped within a second; each event is seen once)
local calls = 0
hook.Add("EntityTakeDamage", "aaa_blocker", function(ent, dmg) calls = calls + 1 return false end)
M.hookOrder.EntityTakeDamage = { "aaa_blocker", "homigrad-damage" }
M.Advance(1.1)
local npc2 = M.Ent("npc_combine_s", { pos = Vector(300, 0, 0), health = 100 })
M.Engine("OnEntityCreated", npc2)
M.Advance(0.2)
h0 = Hits()
Damage(npc2, M.Dmg({ amount = 20, pos = Vector(300, 0, 40), att = p1 }))
check(Hits() == h0 + 1, "a hit behind an addon that answers first still arrives, once (" .. (Hits() - h0) .. ")")
check(calls == 1, "the other addon's hook ran once, as before (" .. calls .. ")")
if not ULIB then
	RunConsoleCommand("ghmpb_sv_hook_priority", "0")
	M.Advance(1.1)
	check(hook.GetTable().EntityTakeDamage.aaa_blocker ~= nil and G.Priority.wrapped[hook.GetTable().EntityTakeDamage.aaa_blocker] == nil,
		"priority off: the other addon's own function is back in the table")
	RunConsoleCommand("ghmpb_sv_hook_priority", "1")
	M.Advance(1.1)
end
hook.Remove("EntityTakeDamage", "aaa_blocker")
M.hookOrder.EntityTakeDamage = { "homigrad-damage" }

-- knocked down: the damage goes to the ragdoll
local rag = M.Ent("prop_ragdoll", { pos = Vector(0, 50, 0), model = p1.model })
M.Engine("Ragdoll_Create", p1, rag)
p1.FakeRagdoll = rag p1:SetNWEntity("FakeRagdoll", rag) rag:SetNWEntity("ply", p1) rag.organism = p1.organism
check(rag:GetNW2Int("ghmpb_blood", -2) == 0, "the ragdoll carries the player's blood colour")
h0 = Hits()
Damage(p1, M.Dmg({ amount = 25, pos = Vector(0, 50, 10), att = p2 }))
local hits = M.SentOf("ghmpb_hit")
check(Hits() == h0 + 1 and hits[#hits].data[1] == rag, "a knocked-down player's hit lands once, on his ragdoll")

-- history: p2 comes over and gets what was left
M.Recv("ghmpb_ready", p2)
M.Recv("ghmpb_ready", p1)
local n0 = #M.SentOf("ghmpb_hist")
M.Advance(1.1)
check(#M.SentOf("ghmpb_hist") == n0, "nothing sent while p2 is far away and p1 saw it all")
p2.pos = Vector(600, 0, 0)
M.Advance(1.1)
local hs = M.SentOf("ghmpb_hist")
check(#hs > n0 and hs[#hs].to == p2, "catch-up sent to p2 once he is near")
local nW = hs[#hs].data[1]
check(nW and nW > 0, "world records in it: " .. tostring(nW))
M.Advance(1.1)
check(#M.SentOf("ghmpb_hist") == #hs, "nothing sent twice")

-- death: a pool
p1.alive = false
M.Engine("PlayerDeath", p1)
check(#M.SentOf("ghmpb_death") == 1, "player death sent")
local pools = 0
for _, r in pairs(G.Hist.recs) do if r.kind == 2 then pools = pools + 1 end end
check(pools == 1, "pool recorded under the body")

-- admin setter
M.Recv("ghmpb_svset", p2, "ghmpb_sv_bleed_scale", "2")
check(GetConVar("ghmpb_sv_bleed_scale"):GetFloat() == 1, "non-admin can not change server settings")
p2.superadmin = true
M.Advance(0.1)
M.Recv("ghmpb_svset", p2, "ghmpb_sv_bleed_scale", "2")
check(GetConVar("ghmpb_sv_bleed_scale"):GetFloat() == 2, "superadmin can")
M.Recv("ghmpb_svset", p2, "sv_cheats", "1")
check(GetConVar("sv_cheats") == nil, "only PhysBlood's server settings")

-- switching the takeover off gives Z-City's hook back
RunConsoleCommand("ghmpb_sv_zcity", "0")
M.Advance(2.1)
check(hook.GetTable().PostEntityTakeDamage.ResponsiveHits_PostEntityTakeDamage ~= nil, "Z-City's hit decal hook given back when the option is off")
check((function() util.Effect("BloodImpact") return M.effects == 1 end)(), "BloodImpact passes again")

-- control: without the priority Z-City's hook hides the hit (the test means something)
RunConsoleCommand("ghmpb_sv_zcity", "1")
RunConsoleCommand("ghmpb_sv_hook_priority", "0")
M.Advance(1.1)
local p3 = M.Ent("player", { pos = Vector(-300, 0, 0) })
p3.organism = { wounds = {} }
M.Engine("PlayerSpawn", p3)
M.Advance(0.3)
h0 = Hits()
Damage(p3, M.Dmg({ amount = 30, pos = Vector(-300, 0, 40), att = p2 }))
check(Hits() == h0, "control: without the priority the Z-City hit is hidden (" .. (Hits() - h0) .. " sent)")
RunConsoleCommand("ghmpb_sv_hook_priority", "1")
M.Advance(1.1)
Damage(p3, M.Dmg({ amount = 30, pos = Vector(-300, 0, 40), att = p2 }))
check(Hits() == h0 + 1, "and with it on again it arrives")

check(#M.errors == 0, "no errors (" .. #M.errors .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
