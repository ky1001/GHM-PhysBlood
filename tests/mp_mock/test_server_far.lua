-- 1.23.2: blood events far from the player (gm_falleritus8: ragdolls dropped from the spawn land ~28,700 units below
-- it) were sent to the client, which dropped them (too far to simulate), and single player kept nothing for later: the
-- blood down there never existed. Now hits and deaths go live only to players within G.LIVE_RANGE; everything else is
-- kept by the server's history and handed out once the player comes near - single player too (server, mocked GMod)
local M = dofile("gmod.lua")
M.sp = true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
function DamageInfo() return M.Dmg({ amount = 0, type = 0, pos = Vector(0, 0, 0) }) end
M.world = M.Ent("worldspawn")
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua", "sv_compat.lua", "sv_core.lua", "sv_zcity.lua", "sv_history.lua", "sv_mp.lua" })
local G = GHMPB
local H = G.Hist
local function Damage(ent, dmg)
	local blocked = M.Engine("EntityTakeDamage", ent, dmg)
	local took = not blocked
	if took then ent.health = ent.health - dmg:GetDamage() end
	M.Engine("PostEntityTakeDamage", ent, dmg, not blocked)
end
local function Hits() return #M.SentOf("ghmpb_hit") end

check(G.LIVE_RANGE == 9000, "live range 9000 units")
check(H.SendOn(), "single player hands out the history too")
local ply = M.Ent("player", { pos = Vector(0, 0, 0) })
M.Engine("OnEntityCreated", ply)
M.Engine("PlayerSpawn", ply)
M.Recv("ghmpb_ready", ply)
M.Advance(1)

-- a hit next to the player: live, and not handed out again later
local npc = M.Ent("npc_citizen", { pos = Vector(200, 0, 0), health = 100 })
M.Engine("OnEntityCreated", npc)
M.Advance(0.2)
local h0 = Hits()
Damage(npc, M.Dmg({ amount = 30, pos = Vector(200, 0, 40), att = ply }))
local hit = M.SentOf("ghmpb_hit")[Hits()]
check(Hits() == h0 + 1 and type(hit.to) == "table" and hit.to[1] == ply, "a hit near the player goes to him live")
M.sent = {}
M.Advance(2.5)
check(#M.SentOf("ghmpb_hist") == 0, "what he saw live is not sent again")

-- a ragdoll dropped from far above lands 20,000 units away and smashes (physics damage on a corpse)
local rag = M.Ent("prop_ragdoll", { pos = Vector(20000, 0, 10), health = 0 })
M.Engine("OnEntityCreated", rag)
M.Advance(2)
local before = H.count
M.sent = {}
Damage(rag, M.Dmg({ amount = 300, type = DMG_CRUSH, pos = Vector(20000, 0, 10), force = Vector(0, 0, -50000), att = M.world }))
check(#M.SentOf("ghmpb_hit") == 0, "far away: no live hit (the client could not simulate it)")
check(H.count > before, "but the server keeps what it left (" .. (H.count - before) .. " records)")
check((G.Diag.c["sv: blood event kept for later (no player near it)"] or 0) >= 1, "counted as kept for later")
M.Advance(2.5)
check(#M.SentOf("ghmpb_hist") == 0, "nothing handed out while the player is far")
-- the player goes down there
ply.pos = Vector(19000, 0, 0)
M.Advance(2.5)
local hs = M.SentOf("ghmpb_hist")
check(#hs >= 1 and hs[1].to == ply or (type(hs[1] and hs[1].to) == "table" and hs[1].to[1] == ply), "near it: the blood is handed to him")
local nWorld = hs[1] and hs[1].data[1] or 0
check(nWorld >= 1, "the stain under the impact (" .. tostring(nWorld) .. " world records)")
M.sent = {}
M.Advance(2.5)
check(#M.SentOf("ghmpb_hist") == 0, "once only")

-- a death far away: its pool too
ply.pos = Vector(0, 0, 0)
local npc2 = M.Ent("npc_citizen", { pos = Vector(-15000, 0, 0), health = 10 })
M.Engine("OnEntityCreated", npc2)
M.Advance(0.2)
M.sent = {}
Damage(npc2, M.Dmg({ amount = 50, pos = Vector(-15000, 0, 40), att = ply }))
M.Engine("OnNPCKilled", npc2, ply, ply)
check(#M.SentOf("ghmpb_hit") == 0 and #M.SentOf("ghmpb_death") == 0, "a kill far away: nothing live")
ply.pos = Vector(-14000, 0, 0)
M.Advance(2.5)
local pools = 0
for _, m in ipairs(M.SentOf("ghmpb_hist")) do
	local d, n = m.data, m.data[1]
	for k = 0, n - 1 do if d[2 + k * 8] == 2 then pools = pools + 1 end end
end
check(pools >= 1, "its pool is there when the player arrives")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
