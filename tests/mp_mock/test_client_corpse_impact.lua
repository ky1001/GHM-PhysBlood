-- 1.23.2: a fresh corpse with no wound yet did not bleed from bumps at all (1.14.0, meant for burned / shocked bodies).
-- On a ragdoll drop map (gm_falleritus8) every body is such a corpse: none of them ever bled. A hard impact now opens
-- it, and a body smashed by a long fall bursts open and pours onto the floor (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "sh_zcity.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, -200, 64) end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
G.Anatomy.GetSkeleton = function() return nil end

-- what the hit turns into
local bodyImpacts, sprays, world = 0, 0, 0
local burst
G.Entities = { Impact = function() bodyImpacts = bodyImpacts + 1 return true end, domains = {}, Get = function() return nil end }
G.Particles = { Spray = function() sprays = sprays + 1 end, Spawn = function() end, Drips = function() end, Hang = function() end,
	Burst = function(o) sprays = sprays + 1 burst = o return o.count end }
G.Surfaces = { Impact = function() world = world + 1 return true end }
G.BloodTypeOf = function() return 0 end
G.Prof = { Count = function() end, Lap = function() end }
M.Load({ "cl_util.lua" })
local U = G.U
U.EntitySurface = function(_, p, d) return p, -d, nil end
U.SnapToMesh = function(_, p, n) return p, n end
U.NearestBone = function() return 0 end
U.BoneToLocal = function(_, _, p, n) return Vector(p), n and Vector(n) or nil end
U.TraceBone = function() return nil end
M.Load({ "cl_wounds.lua" })
local W = G.Wounds

local function Rag(x)
	local e = { valid = true, x = x }
	function e:IsValid() return self.valid end
	function e:GetBoneMatrix() return {} end
	function e:SetupBones() end
	function e:EntIndex() return 100 + self.x end
	function e:IsRagdoll() return true end
	function e:IsNPC() return false end
	function e:IsPlayer() return false end
	function e:GetNW2Int(_, d) return d end
	function e:GetNW2Bool(_, d) return d end
	function e:GetNWEntity() return NULL end
	function e:GetModel() return "models/humans/group01/male_02.mdl" end
	function e:GetCreationTime() return 0 end
	function e:GetVelocity() return Vector(0, 0, 0) end
	function e:GetPos() return Vector(self.x, 0, 10) end
	function e:WorldSpaceCenter() return Vector(self.x, 0, 10) end
	function e:GetModelScale() return 1 end
	function e:LookupAttachment() return 0 end
	function e:BoundingRadius() return 36 end
	return e
end
M.now = 100
local crush = DMG_CRUSH

-- a light bump on a clean corpse: nothing (as before - burned / shocked bodies do not start bleeding from bumps)
local a = Rag(0)
W.OnHit(a, Vector(0, 0, 10), Vector(0, 0, -1), 45, crush, 0, false, nil)
check(bodyImpacts == 0 and sprays == 0, "a light bump on a clean corpse: no blood")

-- a hard impact: it opens the body
local b = Rag(50)
W.OnHit(b, Vector(50, 0, 10), Vector(0, 0, -1), 80, crush, 0, false, nil)
check(bodyImpacts >= 1, "a hard impact on a clean corpse bleeds (" .. bodyImpacts .. " body stamps)")
check(#W.Body(b).wounds >= 1, "and leaves a wound there (later bumps bleed too)")

-- smashed by a long fall: a burst and a pour onto the floor
local c = Rag(100)
local s0, w0 = sprays, world
W.OnHit(c, Vector(100, 0, 10), Vector(0, 0, -1), 400, crush, 0, false, nil)
check(sprays > s0, "smashed by a fall: it bursts open (" .. (sprays - s0) .. " sprays)")
check(world > w0, "and blood pours onto the floor under it")
-- (1.24.0) a burst all round from the floor under it, thrown up and out - not skimming the floor in one direction
check(burst and burst.up and burst.up.z > 0.9 and burst.elMin >= 10 and burst.elMax <= 70 and burst.count >= 16,
	"the burst leaves all round, up and out from the floor (" .. tostring(burst and burst.count) .. " drops)")
check(burst and burst.pos.z < 10 and burst.speedMax <= 300, "from the floor under the body, at moderate speed")
check((W.smashes or 0) >= 1, "counted")

-- the hard-impact limits
check(W.HARD_IMPACT == 60 and W.SMASH_IMPACT == 150, "limits: 60 opens, 150 smashes")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
