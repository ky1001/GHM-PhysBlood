-- 1.21.2: a shot into the back of a head left its wound on the shoulders / back. The wound's bone now comes from the
-- hitbox the ray struck (or the hit group the server reports), the snap points of a bone are spread evenly over its
-- surface, and the snap never moves a point far along the skin (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, 0, 0) end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end

-- ---------------- matrices: translation only (the bones are not rotated in this test)
local Mx = {}
Mx.__index = Mx
local function Mat(o) return setmetatable({ o = Vector(o) }, Mx) end
Mx.__mul = function(m, v) return v + m.o end
function Mx:GetInverse() return Mat(-self.o) end
function Mx:GetTranslation() return Vector(self.o) end
local ANG = { Forward = function() return Vector(1, 0, 0) end, Right = function() return Vector(0, -1, 0) end,
	Up = function() return Vector(0, 0, 1) end }
function Mx:GetAngles() return ANG end

-- ---------------- a person facing +x: pelvis, chest (shoulders flat at z 58), neck, head (an ellipsoid, back at x -4)
local BONES = { [0] = Vector(0, 0, 36), [1] = Vector(0, 0, 48), [2] = Vector(0, 0, 58), [3] = Vector(0, 0, 62) }
local PARENT = { [0] = -1, [1] = 0, [2] = 1, [3] = 2 }
local HC, HR = Vector(0.5, 0, 66.5), Vector(4.5, 3.8, 5.0)
local verts = {}
local function add(p, n, bone) n:Normalize() verts[#verts + 1] = { pos = p, normal = n, weights = { { bone = bone, weight = 1 } } } end
-- head: the face (front) densely meshed and listed first, the back of the head with few vertices (as on real heads)
local function headPoint(th, ph)
	local d = Vector(math.cos(ph) * math.cos(th), math.cos(ph) * math.sin(th), math.sin(ph))
	local p = Vector(HC.x + HR.x * d.x, HC.y + HR.y * d.y, HC.z + HR.z * d.z)
	local n = Vector(d.x / HR.x, d.y / HR.y, d.z / HR.z)
	return p, n
end
for i = 0, 59 do for j = 0, 39 do
	local th = -1.2 + 2.4 * i / 59
	local ph = -1.2 + 2.4 * j / 39
	local p, n = headPoint(th, ph) add(p, n, 3)
end end
for i = 0, 7 do for j = 0, 7 do
	local th = math.pi - 1.9 + 3.8 * i / 7
	local ph = -1.3 + 2.6 * j / 7
	local p, n = headPoint(th, ph) add(p, n, 3)
end end
-- neck: a cylinder, radius 2.2, z 56..62
for i = 0, 15 do for k = 0, 6 do
	local a = i / 16 * math.pi * 2
	add(Vector(2.2 * math.cos(a), 2.2 * math.sin(a), 56 + k), Vector(math.cos(a), math.sin(a), 0), 2)
end end
-- torso: x -5..5, y -8..8, z 36..58; the top (shoulders) faces up
for a = 0, 16 do for b = 0, 22 do
	local y, z = -8 + a, 36 + b
	local bone = z >= 44 and 1 or 0
	add(Vector(-5, y, z), Vector(-1, 0, 0), bone)
	add(Vector(5, y, z), Vector(1, 0, 0), bone)
end end
for a = 0, 10 do for b = 0, 16 do add(Vector(-5 + a, -8 + b, 58), Vector(0, 0, 1), 1) end end
local binds = {}
for b, o in pairs(BONES) do binds[b] = { matrix = Mat(-o) } end
util.GetModelMeshes = function() return { { material = "models/test/body", verticies = verts, triangles = {} } }, binds end

-- hitboxes: chest (group 2) reaching up behind the neck, head (group 1)
local BOXES = {
	{ bone = 1, mins = Vector(-6, -8.5, 4), maxs = Vector(5.5, 8.5, 18), group = 2 },   -- (upper chest, up behind the head)
	{ bone = 3, mins = Vector(-4.6, -4.3, -1), maxs = Vector(5.5, 4.3, 10), group = 1 },
}
local ent = { valid = true }
function ent:IsValid() return true end
function ent:GetModel() return "models/test/snapper.mdl" end
function ent:IsRagdoll() return false end
function ent:GetBoneMatrix(b) return BONES[b] and Mat(BONES[b]) or nil end
function ent:GetBoneCount() return 4 end
function ent:GetBoneParent(b) return PARENT[b] end
function ent:GetChildBones(b) local c = {} for k, p in pairs(PARENT) do if p == b then c[#c + 1] = k end end return c end
function ent:GetBoneName(b) return ({ [0] = "pelvis", "chest", "neck", "head" })[b] end
function ent:GetHitboxSetCount() return 1 end
function ent:GetHitboxSet() return 0 end
function ent:GetHitBoxCount() return #BOXES end
function ent:GetHitBoxBone(h) return BOXES[h + 1].bone end
function ent:GetHitBoxBounds(h) return BOXES[h + 1].mins, BOXES[h + 1].maxs end
function ent:GetHitBoxHitGroup(h) return BOXES[h + 1].group end

G.Prof = { Count = function() end, Lap = function() end }
M.Load({ "cl_util.lua" })
local U = G.U

-- distance of a point from the head's surface (approximate, ellipsoid)
local function headSurfDist(p)
	local d = Vector((p.x - HC.x) / HR.x, (p.y - HC.y) / HR.y, (p.z - HC.z) / HR.z)
	return math.abs(d:Length() - 1) * 4.4
end

-- ---------------- the snap points of the head cover the back of the head
local c = U.meshCache["models/test/snapper.mdl"]
if c == nil then U.SnapToMesh(ent, Vector(0, 0, 66), Vector(1, 0, 0), 3) c = U.meshCache["models/test/snapper.mdl"] end
check(type(c) == "table" and c[3] ~= nil, "mesh points built per bone")
local back = 0
for _, v in ipairs(c[3]) do if v[1].x + BONES[3].x < -2 then back = back + 1 end end
check(#c[3] <= 240, "head thinned to the cap (" .. #c[3] .. " points)")
check(back >= 20, "the back of the head keeps its points (" .. back .. ")")

-- ---------------- NearestBone: overlapping boxes
local P = Vector(-4.6, 0, 61.5)           -- low on the back of the head, inside both boxes
check(U.NearestBone(ent, P) == 1, "without a hit group the overlapping chest box wins (the old behaviour)")
check(U.NearestBone(ent, P, 1) == 3, "with the server's hit group (head) the head bone is chosen")
check(U.NearestBone(ent, Vector(0, 0, 40), 1) == 1, "a stale hit group far from the point is ignored")

-- ---------------- the trace's hitbox gives the bone
local traceResult
util.TraceLine = function() return traceResult end
traceResult = { Hit = true, Entity = ent, HitPos = Vector(-4.6, 0, 64), HitNormal = Vector(-1, 0, 0), HitBox = 1 }
local sp, sn, sb = U.EntitySurface(ent, Vector(-4.6, 0, 64), Vector(1, 0, 0))
check(sb == 3, "EntitySurface returns the bone of the hitbox struck")
traceResult = { Hit = true, Entity = ent, HitPos = Vector(-4.6, 0, 40), HitNormal = Vector(-1, 0, 0), HitBox = 1 }
check(select(3, U.EntitySurface(ent, Vector(-4.6, 0, 40), Vector(1, 0, 0))) == nil, "a hitbox that does not hold the point is not trusted")

-- ---------------- snapping hits across the back of the head
local worst, worstMove, minZ = 0, 0, 1e9
for _, z in ipairs({ 61.5, 63, 65, 67, 69, 70.5 }) do
	for _, y in ipairs({ -2.5, -1, 0, 1.5, 2.5 }) do
		-- the point on the hitbox (x -4.6) behind the head, shot along +x
		local p = Vector(-4.6, y, z)
		for _, bone in ipairs({ 3, 1 }) do       -- the right bone, and a wrong one (chest)
			local q = U.SnapToMesh(ent, p, Vector(-1, 0, 0), bone)
			local move = (q - p):Length()
			if bone == 3 then worst = math.max(worst, headSurfDist(q)) end
			worstMove = math.max(worstMove, math.abs(q.z - p.z))
			minZ = math.min(minZ, q.z)
		end
	end
end
check(worst < 0.9, string.format("hits on the back of the head land on its skin (worst %.2f u off)", worst))
check(worstMove < 2.0, string.format("no hit is moved up or down the body (worst %.2f u)", worstMove))
check(minZ > 59.4, string.format("nothing ends up on the shoulders (lowest z %.1f)", minZ))

-- ---------------- the reference version follows the same limits
local q1 = U.SnapToMesh(ent, Vector(-4.6, 0, 66), Vector(-1, 0, 0), 3)
local q2 = U.RefSnapToMesh(ent, Vector(-4.6, 0, 66), Vector(-1, 0, 0), 3)
check((q1 - q2):Length() < 0.01, "fast and reference snap agree")
-- a point far from any skin stays where it is
local far = Vector(-14, 0, 66)
check((U.SnapToMesh(ent, far, Vector(-1, 0, 0), 3) - far):Length() < 1e-6, "a point far off the skin is not dragged onto it")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
