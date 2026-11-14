-- Footprints: humans print shoe soles, creatures their own tracks, flying / legless NPCs nothing (client)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function Lerp(t, a, b) return a + (b - a) * t end
function Angle(p, y, r)
	local a = math.rad(y)
	return { y = y, Forward = function() return Vector(math.cos(a), math.sin(a), 0) end }
end
function EyePos() return Vector(0, 0, 64) end
_G.MOVETYPE_NOCLIP = 8
_G.ents.GetAll = function() local o = {} for _, e in ipairs(M.ents) do if e.valid then o[#o + 1] = e end end return o end
local E = getmetatable(M.Ent("info_null"))
function E:GetBoneCount() return self.bones and #self.bones or 3 end
function E:GetBoneName(b) return self.bones and self.bones[b + 1] or ("bone" .. b) end
function E:GetBoneMatrix() return nil end
function E:GetUp() return Vector(0, 0, 1) end
function E:OBBMins() return self.mins or Vector(-16, -16, 0) end
function E:OBBMaxs() return self.maxs or Vector(16, 16, 72) end
function E:GetModelScale() return 1 end
function E:GetAngles() return { y = 0 } end
function E:EyeAngles() return { y = 0 } end
function E:GetMoveType() return 2 end
function E:InVehicle() return false end
G.Contact = { Grid = function() end, NearBlood = function() return true end }
-- (a pool for x < 40: walkers step in it and walk out of it)
G.Smear = { RequestProbe = function(ps, p) ps.h, ps.hT, ps.oxy, ps.btype = p.x < 40 and 1.0 or 0, M.now, 0.5, 0 end }
local impacts = {}
G.Surfaces = { GroundFilter = function() return true end,
	Impact = function(pos, n, dir, R, vol, kind, side, fresh) impacts[#impacts + 1] = { pos = pos, R = R, vol = vol, kind = kind, side = side, fresh = fresh, dir = dir } return true end }
M.Load({ "cl_footprints.lua" })
local F = G.Foot

local BIPED = { "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Head1",
	"ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Thigh",
	"ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_R_Foot" }
local TORSO = { "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Head1",
	"ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_R_UpperArm" }
local SPIDER = { "root", "body", "leg_front_l1", "leg_front_r1", "leg_back_l1", "leg_back_r1" }
local mdlN = 0
local function ent(class, o) o = o or {} o.pos = o.pos or Vector(0, 0, 0) mdlN = mdlN + 1 o.model = o.model or ("models/test" .. mdlN .. ".mdl") return M.Ent(class, o) end

-- classification
check(F.Classify(ent("npc_citizen", { bones = BIPED })) == "human", "citizen (humanoid with legs): shoe soles")
check(F.Classify(ent("npc_zombie", { bones = BIPED })) == "human", "zombie: shoe soles")
check(F.Classify(ent("npc_headcrab")) == F.PROFILES.headcrab, "headcrab: its own track")
check(F.Classify(ent("npc_headcrab_fast")) == F.PROFILES.headcrab_fast, "fast headcrab")
check(F.Classify(ent("npc_antlion")).shape == 1, "antlion: claw stabs")
check(F.Classify(ent("npc_hunter")).shape == 0 and #F.Classify(ent("npc_hunter")).feet == 3, "hunter: tripod pads")
check(F.Classify(ent("npc_crow")).shape == 2, "crow: three toes")
check(F.Classify(ent("npc_manhack")) == false and F.Classify(ent("npc_cscanner")) == false and F.Classify(ent("npc_rollermine")) == false, "flying / rolling: nothing")
check(F.Classify(ent("npc_zombie_torso")) == false, "zombie torso: nothing")
check(F.Classify(ent("npc_workshop_torso", { bones = TORSO })) == false, "unknown legless humanoid: nothing")
local sp = F.Classify(ent("npc_workshop_spider", { bones = SPIDER, mins = Vector(-30, -30, 0), maxs = Vector(30, 30, 30) }))
check(type(sp) == "table" and sp.generic and sp.shape == 3 and #sp.feet == 4, "unknown creature: generic paws from its bounds")
local small = F.Classify(ent("npc_workshop_bug", { bones = SPIDER, mins = Vector(-6, -6, 0), maxs = Vector(6, 6, 6) }))
check(type(small) == "table" and small.shape == 0 and small.r < 1, "small unknown creature: pads")
check(F.Classify(ent("npc_workshop_human", { bones = BIPED })) == "human", "unknown humanoid with legs: shoe soles")
local QUAD = { "pelvis", "spine", "spine2", "head", "leg_l_front", "leg_r_front", "leg_l_back", "leg_r_back", "foot_l", "foot_r" }
local dog = F.Classify(ent("npc_workshop_dog", { bones = QUAD, mins = Vector(-24, -12, 0), maxs = Vector(24, 12, 34) }))
check(type(dog) == "table" and dog.shape == 3, "unknown four-legged rig with a head: paws, not soles")
local pl = ent("player", { bones = BIPED })
check(F.Classify(pl) == "human", "player: shoe soles")
check(F.Classify(ent("npc_workshop_pending", { bones = {} })) == nil, "no bones yet: asked again later")
for _, e in ipairs(M.ents) do e.valid = false end

-- walking through blood
local function walk(class, o, steps, dx)
	impacts = {}
	F.Clear()
	local e = ent(class, o)
	local t0 = M.now + 2
	for k = 0, steps do
		M.now = t0 + k * 0.06
		e.pos = Vector(k * dx, 0, 0)
		F.Update()
	end
	e.valid = false
	return impacts
end
G.cv.footnpc:SetBool(true)
local hum = walk("npc_citizen", { bones = BIPED }, 60, 6)
local okH = #hum > 0
for _, i in ipairs(hum) do if i.kind ~= 5 or math.abs(i.side) ~= 1 then okH = false end end
check(okH, "citizen: " .. #hum .. " shoe prints (|side| 1)")
local hc = walk("npc_headcrab", {}, 60, 2)
local okC, sizes = #hc > 0, true
for _, i in ipairs(hc) do
	if i.kind ~= 5 or math.abs(i.side) ~= 4 then okC = false end
	if math.abs(i.R - 0.6) > 1e-6 then sizes = false end
end
check(okC and sizes, "headcrab: " .. #hc .. " leg-tip prints (|side| 4, r 0.6), no shoe soles")
-- two dots per step (diagonal pairs), on both sides of its path
local left, right = 0, 0
for _, i in ipairs(hc) do if i.pos.y > 0 then left = left + 1 else right = right + 1 end end
check(left > 0 and right > 0, "headcrab prints on both sides of its path (" .. left .. " / " .. right .. ")")
local an = walk("npc_antlion", {}, 60, 8)
local okA = #an > 0
for _, i in ipairs(an) do if math.abs(i.side) ~= 5 then okA = false end end
check(okA, "antlion: " .. #an .. " claw stabs (|side| 5)")
-- splayed: rear claws point backwards
local back = 0
for _, i in ipairs(an) do if i.dir.x < -0.5 then back = back + 1 end end
check(back > 0, "antlion rear claws point back (" .. back .. ")")
local mh = walk("npc_manhack", {}, 60, 6)
check(#mh == 0, "manhack: no prints")
-- volume: the film is the sole load (a headcrab foot holds 0.3 mm) x the part printed per step: vol / (AREA R^2)
local i = hc[1]
local Rmm = i.R * 19.05
check(i.vol > 0 and math.abs(i.vol / (2.5 * Rmm * Rmm) - 0.3 * 0.38) < 0.02, string.format("headcrab film %.3f mm", i.vol / (2.5 * Rmm * Rmm)))
check(#M.errors == 0, "no errors (" .. #M.errors .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
