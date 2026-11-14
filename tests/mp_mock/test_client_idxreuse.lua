-- (1.26.8) GHM: "first few shots DO NOT register on npcs and spawn blood, actually some npc at random do not spawn any
-- of the blood and or wounds when shot". The server gives the entity index of a body that turned into its ragdoll to
-- the next entity it makes, and this client kept the index -> ragdoll link for as long as the corpse lay there: every hit
-- on a new NPC that got the index (and its wounds and bleeding, every frame) went to the old corpse. A link must only
-- redirect the body it came from, and an index this client has no entity for only for a few seconds. (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(-300, 0, 64) end
local Emeta = getmetatable(NULL)
function Emeta:GetNoDraw() return self.nodraw == true end
function Emeta:GetNW2Entity() return NULL end
G.Entities = { Impact = function() return true end, domains = {}, Get = function() return nil end, Transfer = function() return false end }
G.Particles = { Spray = function() end, Spawn = function() end, Drips = function() end, Hang = function() end,
	Burst = function(o) return o.count end, Thin = function() return 1 end, ThinPrio = function() return 1 end, Count = function() return 0 end }
G.Surfaces = { Impact = function() return true end, IsGround = function() return true end }
G.Prof = { Count = function() end, Lap = function() end }
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end, Add = function() return setmetatable({}, { __index = function() return function() end end }) end } end
M.Load({ "cl_util.lua", "cl_spatterdata.lua", "cl_crbdata.lua", "cl_forensic.lua", "cl_wounds.lua" })
G.U.RefreshCorpses = function() end
G.GPU = {}
G.Native = { Load = function() end }
G.Prof.Instrument = function() end
M.Load({ "cl_render.lua" })
hook.Remove("Think", "ghmpb_house")
local R = G.Render
local W = G.Wounds
local byIdx = {}
function Entity(i) local e = byIdx[i] if e and e.valid then return e end return NULL end
local function Npc(idx)
	local e = M.Ent("npc_citizen", { pos = Vector(0, 0, 0) })
	e.idx = idx
	byIdx[idx] = e
	hook.Run("OnEntityCreated", e)
	return e
end
local function ClientRag(owner)
	local r = M.Ent("prop_ragdoll", { pos = Vector(0, 0, 0) })
	r.idx = -1
	hook.Run("CreateClientsideRagdoll", owner, r)
	return r
end

-- an NPC dies (a ragdoll of this client) and its index is given to a new NPC
local a = Npc(45)
local ragA = ClientRag(a)
check(R.Redirect(a, 45) == ragA, "the dead NPC's hits go to its ragdoll")
a:Remove()
check(R.Redirect(NULL, 45) == ragA, "a hit that comes after the NPC is gone: its ragdoll")
local b = Npc(45)
check(R.Redirect(b, 45) == b, "a new NPC with the dead one's index: its hits stay on it")
local hits = {}
W.OnHit = function(ent) hits[#hits + 1] = ent end
function net.BytesLeft() return #M.readq * 4 end
M.Recv("ghmpb_hit", nil, b, Vector(0, 0, 40), Vector(1, 0, 0), 30, DMG_BULLET, 2, false, NULL, false, 45)
check(#hits == 1 and hits[1] == b, "the hit message is worked out on the new NPC, not on the old corpse")
-- the frame-by-frame check of the bodies (E.Update / W.Update) asks the same
check(R.Redirect(b, b:EntIndex()) == b, "its wounds are not moved over to the old corpse")

-- the same when the new entity's creation was not seen (a full update, a reload of the file)
local c = Npc(46)
local ragC = ClientRag(c)
c:Remove()
local d = M.Ent("npc_combine_s", { pos = Vector(0, 0, 0) })
d.idx = 46 byIdx[46] = d
check(R.Redirect(d, 46) == d, "a link only redirects the body it came from")

-- a server ragdoll handed over (ghmpb_rag), then a hit for the index while this client has no entity there
local e = Npc(47)
local ragE = M.Ent("prop_ragdoll", { pos = Vector(0, 0, 0) })
ragE.idx = 60 byIdx[60] = ragE
hook.Run("OnEntityCreated", ragE)
M.Recv("ghmpb_rag", nil, e, ragE, 47, 60)
check(R.Redirect(e, 47) == ragE, "server ragdoll: the dying NPC's hits go to it")
e:Remove()
M.Advance(1)
check(R.Redirect(NULL, 47) == ragE, "1 s later, a hit for the index (no entity): the ragdoll")
M.Advance(6)
check(R.Redirect(NULL, 47) ~= ragE, "minutes later the corpse does not take hits meant for an index")
local f = Npc(47)
check(R.Redirect(f, 47) == f and R.ragByIdx[47] == nil, "a new NPC at that index: the link is dropped")
check(IsValid(ragE) and R.Redirect(ragE, 60) == ragE, "the old corpse itself still takes its own hits")

-- a living body is never sent to someone else's ragdoll by index
local g = Npc(48)
R.LinkIdx(48, ragA, nil)
check(R.Redirect(g, 48) == g, "an index linked without an owner does not take a living NPC's hits")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
