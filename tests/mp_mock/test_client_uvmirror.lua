-- 1.20.1: models that map both legs (arms, face halves) onto the same, mirrored part of their texture get separate blood
-- per side: the mirrored copy is detected from the UV winding of the triangles (cl_entities.lua ModelInfo), and such a
-- part gets a twin set of blood targets (hand 1 / hand 2) that every pass keeps apart (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, 0, 0) end

-- ---------------- a test model: "pants" with both legs on one mirrored texture region, a "face" with two plain islands,
-- a "shirt" with a flipped island of its own (no copy on top of it)
local function quadStrip(tris, x0, x1, z0, z1, u0, u1, v0, v1, n, mirror)
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local function P(a, b)
				local x = x0 + (x1 - x0) * a / n
				local z = z0 + (z1 - z0) * b / n
				local u = u0 + (u1 - u0) * a / n
				local v = v0 + (v1 - v0) * b / n
				return { pos = Vector(mirror and -x or x, 0, z), normal = Vector(0, -1, 0), u = u, v = v }
			end
			local a, b, c, d = P(i, j), P(i + 1, j), P(i + 1, j + 1), P(i, j + 1)
			if mirror then
				-- (mirrored geometry: the order is reversed to keep the faces pointing out, the texture coordinates are the same)
				tris[#tris + 1] = a tris[#tris + 1] = c tris[#tris + 1] = b
				tris[#tris + 1] = a tris[#tris + 1] = d tris[#tris + 1] = c
			else
				tris[#tris + 1] = a tris[#tris + 1] = b tris[#tris + 1] = c
				tris[#tris + 1] = a tris[#tris + 1] = c tris[#tris + 1] = d
			end
		end
	end
end
local pants, face, shirt = {}, {}, {}
quadStrip(pants, 4, 10, 0, 40, 0.05, 0.45, 0.1, 0.9, 6, false)    -- left leg
quadStrip(pants, 4, 10, 0, 40, 0.05, 0.45, 0.1, 0.9, 6, true)     -- right leg: the same texels, mirrored
quadStrip(face, -4, 4, 60, 68, 0.05, 0.45, 0.05, 0.45, 4, false)  -- two plain islands
quadStrip(face, -4, 4, 52, 60, 0.55, 0.95, 0.55, 0.95, 4, false)
quadStrip(shirt, -8, 8, 40, 56, 0.05, 0.45, 0.05, 0.95, 6, false)
quadStrip(shirt, -8, 8, 40, 56, 0.55, 0.95, 0.05, 0.95, 6, true)  -- a flipped island of its own
local MESHES = { { material = "models/test/pants", triangles = pants }, { material = "models/test/face", triangles = face },
	{ material = "models/test/shirt", triangles = shirt } }
util.GetModelMeshes = function() return MESHES end
local MATS = { "models/test/pants", "models/test/face", "models/test/shirt" }
local IMat = { IsError = function() return false end, GetInt = function() return 0 end, GetString = function() return "" end,
	GetTexture = function() return nil end }
function Material() return IMat end
local ent = { GetModel = function() return "models/test/person.mdl" end, GetMaterials = function() return MATS end,
	IsValid = function() return true end, IsWorld = function() return false end, EntIndex = function() return 5 end,
	GetPos = function() return Vector(0, 0, 0) end, GetSkin = function() return 0 end, GetBodyGroups = function() return {} end,
	GetModelScale = function() return 1 end }
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end

-- ---------------- GPU / budget stubs (enough for a domain to be made)
local made = {}
local smallLimit = 99
G.Budget = { BodySizes = function() return 384, 256 end, Count = function(kind, size) made[size] = (made[size] or 0) + 1 end,
	MayCreateBody = function(size) return size ~= 256 or (made[256] or 0) < smallLimit end, Caps = function() return { ents = 8, aftb = 8 } end }
local function obj() return { GetName = function() return "rt" end, SetTexture = function() end, SetFloat = function() end } end
G.GPU = { RT = function() return obj() end, Mat = function() return obj() end, CreateMat = function() return obj() end,
	Merge = function(a, b) local t = {} for k, v in pairs(a or {}) do t[k] = v end for k, v in pairs(b or {}) do t[k] = v end return t end,
	ModelFlags = {}, ImpactTable = function() return obj() end, FreeAft = function() end, TakeAft = function() return obj() end }
_G.render = { PushRenderTarget = function() end, PopRenderTarget = function() end, Clear = function() end }
function ClientsideModel() return { SetNoDraw = function() end, SetParent = function() end, AddEffects = function() end, SetPos = function() end,
	SetSkin = function() end, SetBodygroup = function() end, SetModelScale = function() end, IsValid = function() return true end,
	Remove = function() end } end
_G.EF_BONEMERGE = 1
_G.RENDERGROUP_OPAQUE = 0
G.Surface = { skin = { rough = 0.4 }, cloth = { rough = 0.6, fabric = 1 } }
G.BloodTypeOf = function() return 0 end
G.DiagCount = function() end
G.Prof = { Count = function() end }
G.U = { InView = function() return true end }
M.Load({ "cl_entities.lua" })
local E = G.Entities

-- ---------------- detection
local mi = E.ModelInfo(ent)
local by = {}
for _, s in ipairs(mi.subs) do by[s.path] = s end
check(by["models/test/pants"] and by["models/test/pants"].mirror == true, string.format("pants: both legs on one mirrored region -> mirrored (overlap %d %%)", math.floor((by["models/test/pants"].mirrorShare or 0) * 100)))
check(by["models/test/face"] and by["models/test/face"].mirror == false, "face: plain islands -> not mirrored")
check(by["models/test/shirt"] and by["models/test/shirt"].mirror == false, "shirt: a flipped island of its own (no copy on top) -> not mirrored")

-- ---------------- the domain: a twin for the mirrored part
local d = E.Get(ent, true)
check(d ~= nil, "a domain is made")
local hands = {}
for _, s in ipairs(d.subs) do hands[#hands + 1] = s.path:match("test/(%a+)") .. ":" .. s.hand .. ":" .. s.size end
print("     subs " .. table.concat(hands, " "))
local pA, pB
for _, s in ipairs(d.subs) do if s.path == "models/test/pants" then if s.hand == 1 then pA = s elseif s.hand == 2 then pB = s end end end
check(pA and pB and pA.index == pB.index, "pants: two sets of targets, one per half, for the same material")
check(pA and pB and pA.slot and pB.slot and pA.slot ~= pB.slot, "pants: each half has targets of its own")
check(d.twins == true and E.Passes(d) == 2, "the body's layer is drawn in two passes")
check(E.InPass(pA, 1) and not E.InPass(pA, 2) and E.InPass(pB, 2) and not E.InPass(pB, 1), "pass 1 draws the first half, pass 2 the mirrored one")
for _, s in ipairs(d.subs) do if s.path ~= "models/test/pants" then check(s.hand == 0 and E.InPass(s, 1), s.path .. ": one set, drawn in pass 1") end end
E.Remove(ent)

-- ---------------- no room for the twin: the old, shared blood rather than none
-- (room for two small sets: the face and one for the pants - not for a twin)
E.pool, made = {}, {}
smallLimit = 2
d = E.Get(ent, true)
check(d ~= nil, "budget without room for the twin: a domain is still made")
local np = 0
for _, s in ipairs(d and d.subs or {}) do if s.path == "models/test/pants" then np = np + 1 check(s.hand == 0, "pants: back to one shared set") end end
check(np == 1 and not d.twins and E.Passes(d) == 1, "no twin, one pass")
E.Remove(ent)
smallLimit = 99

-- ---------------- switched off
G.cv.uvmirror:SetInt(0)
d = E.Get(ent, true)
local tw = 0
for _, s in ipairs(d.subs) do if s.hand ~= 0 then tw = tw + 1 end end
check(tw == 0 and E.Passes(d) == 1, "ghmpb_uv_mirror 0: no twins")
E.Remove(ent)
G.cv.uvmirror:SetInt(1)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
