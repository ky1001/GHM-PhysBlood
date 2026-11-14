-- Active ragdolls (1.18.0): a character GHM Euphoria has knocked down lives on in its prop_ragdoll - the server marks
-- that body (NW2 "ghmpb_alive") so the clients' wounds and flies treat it as alive (luajit test_server_activerag.lua)
local M = dofile("gmod.lua")
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.sp = true
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua", "sv_compat.lua", "sv_core.lua" })
local G = GHMPB
local rag = M.Ent("prop_ragdoll")
local corpse = M.Ent("prop_ragdoll")
M.Advance(1)
check(rag:GetNW2Bool("ghmpb_alive", false) == false, "no GHM Euphoria: nothing marked")
GHM_EU = { Chars = { [rag] = { mode = "alive" }, [corpse] = { mode = "dying" } } }
M.Advance(0.6)
check(rag:GetNW2Bool("ghmpb_alive", false) == true, "knocked down, alive: its ragdoll marked")
check(corpse:GetNW2Bool("ghmpb_alive", false) == false, "dying: not")
check(G.LivingRagdoll(rag) == true and G.LivingRagdoll(corpse) == false, "G.LivingRagdoll follows the mark")
GHM_EU.Chars[rag].mode = "dead"
M.Advance(0.6)
check(rag:GetNW2Bool("ghmpb_alive", true) == false, "it died: the mark goes")
GHM_EU.Chars[rag].mode = "alive"
M.Advance(0.6)
GHM_EU.Chars[rag] = nil
M.Advance(0.6)
check(rag:GetNW2Bool("ghmpb_alive", true) == false, "released by GHM Euphoria: the mark goes")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
