local G = GHMPB
G.U = G.U or {}
local U = G.U

local rand = math.random
function U.RandRange(a, b) return a + (b - a) * rand() end

function U.ConeDir(dir, half)
	local up = math.abs(dir.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
	local r = dir:Cross(up) r:Normalize()
	local u = r:Cross(dir) u:Normalize()
	local cosT = 1 - rand() * (1 - math.cos(half))
	local sinT = math.sqrt(math.max(0, 1 - cosT * cosT))
	local phi = rand() * math.pi * 2
	return dir * cosT + r * (math.cos(phi) * sinT) + u * (math.sin(phi) * sinT)
end

function U.DropRadius(r0, s)
	local x = rand() + rand() + rand() - 1.5
	return math.Clamp(r0 * math.exp(x * s), 0.05, 4)
end

function U.Clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

function U.SplatShape(vel, n, stretch)
	stretch = math.max(stretch or 1, 1)
	local cv = G.cv and G.cv.streak
	local emax = cv and cv:GetFloat() or 3.5
	if emax >= 9.99 or not vel or not n then return vel, stretch end
	local sp = vel:Length()
	if sp < 1e-3 then return vel, stretch end
	local vn = vel:Dot(n)
	local sinA = math.abs(vn) / sp
	if math.min(math.Clamp(1 / math.max(sinA, 0.12), 1, 8) * math.min(stretch, 8), 10) <= emax then return vel, stretch end
	stretch = math.min(stretch, 1 + (emax - 1) * 0.35)
	local lim = emax / stretch
	if sinA * lim >= 1 then return vel, stretch end
	local vt = vel - n * vn
	local vts = vt:Length()
	if vts < 1e-3 then return vel, stretch end
	local s2 = 1 / lim
	local c2 = math.sqrt(math.max(1 - s2 * s2, 0))
	local out = vt * (sp * c2 / vts)
	out:Add(n * ((vn <= 0 and -1 or 1) * sp * s2))
	return out, stretch
end

function U.IsMainView(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) then return false end
	return render.GetRenderTarget() == nil
end

function U.RefNearestBone(ent, pos)
	local best, bd = nil, math.huge
	local sets = ent:GetHitboxSetCount() or 0
	if sets > 0 then
		local set = ent:GetHitboxSet() or 0
		for hb = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
			local bone = ent:GetHitBoxBone(hb, set)
			if bone then
				local m = ent:GetBoneMatrix(bone)
				if m then
					local mins, maxs = ent:GetHitBoxBounds(hb, set)
					local lp = WorldToLocal(pos, angle_zero, m:GetTranslation(), m:GetAngles())
					local c = Vector(math.Clamp(lp.x, mins.x, maxs.x), math.Clamp(lp.y, mins.y, maxs.y), math.Clamp(lp.z, mins.z, maxs.z))
					local d = c:DistToSqr(lp) + 0.02 * ((mins + maxs) * 0.5):DistToSqr(lp)
					if d < bd then best, bd = bone, d end
				end
			end
		end
	end
	if best then return best end
	for b = 0, (ent:GetBoneCount() or 0) - 1 do
		local m = ent:GetBoneMatrix(b)
		if m then
			local d = m:GetTranslation():DistToSqr(pos)
			if d < bd then best, bd = b, d end
		end
	end
	return best or 0
end

function U.BoneToLocal(ent, bone, pos, dir)
	local m = bone and ent:GetBoneMatrix(bone)
	if not m then return nil end
	local lp = WorldToLocal(pos, angle_zero, m:GetTranslation(), m:GetAngles())
	local ld = dir and WorldToLocal(dir, angle_zero, vector_origin, m:GetAngles()) or nil
	return lp, ld
end

function U.BoneToWorld(ent, bone, lp, ld)
	if bone == nil then
		return ent:LocalToWorld(lp), ld and LocalToWorld(ld, angle_zero, vector_origin, ent:GetAngles()) or nil
	end
	local m = ent:GetBoneMatrix(bone)
	if not m then return nil end
	local wp = LocalToWorld(lp, angle_zero, m:GetTranslation(), m:GetAngles())
	local wd = ld and LocalToWorld(ld, angle_zero, vector_origin, m:GetAngles()) or nil
	return wp, wd
end

function U.RefRayHitboxes(ent, start, delta)
	local set = ent:GetHitboxSet() or 0
	local best, bn, bf, bb = nil, nil, math.huge, nil
	for hb = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
		local bone = ent:GetHitBoxBone(hb, set)
		local m = bone and ent:GetBoneMatrix(bone)
		if m then
			local mins, maxs = ent:GetHitBoxBounds(hb, set)
			if mins then
				local hp, hn, fr = util.IntersectRayWithOBB(start, delta, m:GetTranslation(), m:GetAngles(), mins, maxs)
				if hp and fr and fr < bf then best, bn, bf, bb = hp, hn, fr, bone end
			end
		end
	end
	return best, bn, bf, bb
end

function U.TraceBone(ent, tr)
	if not tr or not tr.Hit or tr.Entity ~= ent then return nil end
	local bone
	if ent:IsRagdoll() then
		local pb = tr.PhysicsBone
		if pb and pb >= 0 and ent.TranslatePhysBoneToBone then bone = ent:TranslatePhysBoneToBone(pb) end
	else
		local hb = tr.HitBox
		local set = ent:GetHitboxSet() or 0
		if hb and hb >= 0 and hb < (ent:GetHitBoxCount(set) or 0) then bone = ent:GetHitBoxBone(hb, set) end
	end
	if bone and bone >= 0 and U.OnBoneBox(ent, bone, tr.HitPos, 1.5) then return bone end
	return nil
end

function U.EntitySurface(ent, pos, dir)
	local tr = util.TraceLine({
		start = pos - dir * 24, endpos = pos + dir * 12,
		filter = function(e) return e == ent end, mask = MASK_SHOT,
		ignoreworld = true,
	})
	if tr.Hit and tr.Entity == ent then return tr.HitPos, tr.HitNormal, U.TraceBone(ent, tr) end
	local hp, hn, _, bone = U.RayHitboxes(ent, pos - dir * 24, dir * 36)
	if hp then return hp, hn, bone end
	return pos, -dir, nil
end

U.corpses = U.corpses or {}
function U.RefreshCorpses()
	local list = {}
	local seen = {}
	local function add(e)
		if IsValid(e) and not seen[e] and e:GetBoneCount() and e:GetBoneCount() > 1 then
			seen[e] = true
			list[#list + 1] = e
		end
	end
	for _, e in ipairs(ents.FindByClass("class C_ClientRagdoll")) do add(e) end
	for e in pairs(G.Entities and G.Entities.domains or {}) do if IsValid(e) and e:EntIndex() < 0 then add(e) end end
	U.corpses = list
end

local ctr = {}
function U.RefTraceCorpses(start, endpos, ignore)
	local list = U.corpses
	if #list == 0 then return nil end
	local delta = endpos - start
	local len2 = delta:LengthSqr()
	if len2 < 1e-6 then return nil end
	local bestF, best = math.huge, nil
	for i = 1, #list do
		local e = list[i]
		if e ~= ignore and IsValid(e) then
			local c = e:WorldSpaceCenter()
			local r = e:BoundingRadius() + 4
			local t = math.Clamp((c - start):Dot(delta) / len2, 0, 1)
			if (start + delta * t):DistToSqr(c) < r * r then
				local hp, hn, fr, bone = U.RefRayHitboxes(e, start, delta)
				if hp and fr < bestF then
					bestF = fr
					ctr.Hit, ctr.HitPos, ctr.HitNormal, ctr.Entity, ctr.Fraction, ctr.HitWorld, ctr.HitSky, ctr.StartSolid, ctr.HitBone =
						true, hp, hn, e, fr, false, false, false, bone
					best = ctr
				end
			end
		end
	end
	return best
end

function U.Now() return CurTime() end

U.meshCache = U.meshCache or {}
local SNAP_SKIP = { "eyeball", "eye_", "teeth", "tongue", "mouth", "glint", "iris", "cornea" }

local SNAP_PER_BONE = 240
local function BuildBoneVerts(mdl)
	local ok, meshes, binds = pcall(util.GetModelMeshes, mdl, 0, 0)
	if not ok or not meshes or not binds then return false end
	local function build(inv)
		local c, sum, n = {}, 0, 0
		local mats = {}
		for id, bp in pairs(binds) do
			if bp.matrix then mats[id] = inv and bp.matrix:GetInverse() or bp.matrix end
		end
		for _, m in ipairs(meshes) do
			local mat = string.lower(m.material or "")
			local skip = false
			for _, s in ipairs(SNAP_SKIP) do if string.find(mat, s, 1, true) then skip = true break end end
			if not skip then
				local verts = m.verticies or {}
				local stride = math.max(1, math.floor(#verts / 6000))
				for i = 1, #verts, stride do
					local v = verts[i]
					local wb, ww = nil, -1
					for _, w in ipairs(v.weights or {}) do if w.weight > ww then wb, ww = w.bone, w.weight end end
					local M = wb and mats[wb]
					if M and v.pos and v.normal then
						local lp = M * v.pos
						local ln = (M * (v.pos + v.normal)) - lp
						ln:Normalize()
						local list = c[wb]
						if not list then list = {} c[wb] = list end
						list[#list + 1] = { lp, ln }
						sum = sum + lp:Length() n = n + 1
					end
				end
			end
		end
		return c, n > 0 and sum / n or math.huge
	end
	local a, ma = build(false)
	local b, mb = build(true)
	local c = (ma <= mb) and a or b
	for bone, list in pairs(c) do
		if #list > SNAP_PER_BONE then c[bone] = U.Thin(list, SNAP_PER_BONE) end
	end
	return c
end

function U.Thin(list, cap)
	local function key(p, n, h)
		local ax, ay, az = math.abs(n.x), math.abs(n.y), math.abs(n.z)
		local f
		if ax >= ay and ax >= az then f = n.x >= 0 and 0 or 1 elseif ay >= az then f = n.y >= 0 and 2 or 3 else f = n.z >= 0 and 4 or 5 end
		return ((math.floor(p.x / h) * 4096 + math.floor(p.y / h)) * 4096 + math.floor(p.z / h)) * 8 + f
	end
	local h = 0.6
	local cells, order
	for _ = 1, 40 do
		cells, order = {}, {}
		for i = 1, #list do
			local v = list[i]
			local k = key(v[1], v[2], h)
			local cl = cells[k]
			if not cl then
				cl = { 0, 0, 0, 0, 0, 0, 0 }
				cells[k] = cl
				order[#order + 1] = cl
			end
			local p, n = v[1], v[2]
			cl[1], cl[2], cl[3] = cl[1] + p.x, cl[2] + p.y, cl[3] + p.z
			cl[4], cl[5], cl[6] = cl[4] + n.x, cl[5] + n.y, cl[6] + n.z
			cl[7] = cl[7] + 1
		end
		if #order <= cap then break end
		h = h * 1.25
	end
	local out = {}
	for i = 1, #order do
		local cl = order[i]
		local k = cl[7]
		local n = Vector(cl[4] / k, cl[5] / k, cl[6] / k)
		if n:LengthSqr() < 1e-6 then n = Vector(list[1][2]) end
		n:Normalize()
		out[#out + 1] = { Vector(cl[1] / k, cl[2] / k, cl[3] / k), n }
	end
	return out
end

U.meshQueue = U.meshQueue or {}
function U.QueueMesh(ent)
	if not IsValid(ent) then return end
	local mdl = ent:GetModel()
	if not mdl or U.meshCache[mdl] ~= nil or U.meshQueue[mdl] then return end
	U.meshQueue[mdl] = ent
end
function U.ProcessMeshQueue()
	local mdl, ent = next(U.meshQueue)
	if not mdl then return end
	U.meshQueue[mdl] = nil
	if U.meshCache[mdl] == nil then U.meshCache[mdl] = BuildBoneVerts(mdl) end
	if IsValid(ent) and G.Anatomy and G.Anatomy.GetSkeleton then pcall(G.Anatomy.GetSkeleton, ent) end
end
hook.Add("OnEntityCreated", "ghmpb_meshq", function(ent)
	timer.Simple(0.5, function()
		if not IsValid(ent) then return end
		if ent:IsNPC() or ent:IsPlayer() or ent.Type == "nextbot" or ent.IsVJBaseSNPC or ent.IsZBaseNPC or ent.IsDrGNextbot then
			U.QueueMesh(ent)
		end
	end)
end)

function U.RefSnapToMesh(ent, pos, nrm, bone)
	if not IsValid(ent) or not pos then return pos, nrm end
	local mdl = ent:GetModel()
	if not mdl then return pos, nrm end
	local c = U.meshCache[mdl]
	if c == nil then c = BuildBoneVerts(mdl) U.meshCache[mdl] = c end
	if not c then return pos, nrm end
	bone = bone or U.RefNearestBone(ent, pos)
	local M = ent:GetBoneMatrix(bone)
	if not M then return pos, nrm end
	local mp, ma = M:GetTranslation(), M:GetAngles()
	local lp = WorldToLocal(pos, angle_zero, mp, ma)
	local ln = nrm and WorldToLocal(nrm, angle_zero, vector_origin, ma) or nil
	local best, bd = nil, math.huge
	local function scan(list, Mb)
		for i = 1, #list do
			local v = list[i]
			local d = v[1]:DistToSqr(lp)
			if ln and v[2]:Dot(ln) < 0 then d = d * 4 + 4 end
			if d < bd then best, bd = v, d end
		end
	end
	if c[bone] then scan(c[bone]) end
	local parent = ent:GetBoneParent(bone)
	if not best or bd > 4 then
		local candidates = {}
		if parent and parent >= 0 then candidates[#candidates + 1] = parent end
		for _, ch in ipairs(ent:GetChildBones(bone) or {}) do candidates[#candidates + 1] = ch end
		for _, cb in ipairs(candidates) do
			local Mc = ent:GetBoneMatrix(cb)
			if Mc and c[cb] then
				local lpc = WorldToLocal(pos, angle_zero, Mc:GetTranslation(), Mc:GetAngles())
				local lnc = nrm and WorldToLocal(nrm, angle_zero, vector_origin, Mc:GetAngles()) or nil
				for _, v in ipairs(c[cb]) do
					local d = v[1]:DistToSqr(lpc)
					if lnc and v[2]:Dot(lnc) < 0 then d = d * 4 + 4 end
					if d < bd then
						best, bd = v, d
						bone, M, mp, ma, lp, ln = cb, Mc, Mc:GetTranslation(), Mc:GetAngles(), lpc, lnc
					end
				end
			end
		end
	end
	if not best or bd > U.SNAP_REACH2 then return pos, nrm end
	local vn = best[2]
	local off = lp - best[1]
	local t = off:Dot(vn)
	if off:LengthSqr() - t * t > U.SNAP_LAT2 or t * t > U.SNAP_MOVE2 then return pos, nrm end
	local q = lp - vn * t
	return LocalToWorld(q, angle_zero, mp, ma), LocalToWorld(vn, angle_zero, vector_origin, ma)
end

local FrameNumber, sqrt, huge = FrameNumber, math.sqrt, math.huge
local frames = setmetatable({}, { __mode = "k" })

function U.InvalidateBones(ent)
	if ent then frames[ent] = nil end
end

function U.EnsureBones(ent, force)
	if not IsValid(ent) or not ent.SetupBones then return end
	local fn = FrameNumber()
	if not force and ent.ghmpbBoneF == fn and ent:GetBoneMatrix(0) then return end
	ent.ghmpbBoneF = fn
	frames[ent] = nil
	ent:SetupBones()
end

local function EntFrame(ent)
	local fn = FrameNumber()
	local c = frames[ent]
	if c and c.f == fn then return c end
	if ent:IsRagdoll() and ent:EntIndex() > 0 and ent.ghmpbBoneF ~= fn then
		ent.ghmpbBoneF = fn
		ent:SetupBones()
	end
	c = { f = fn, b = {} }
	frames[ent] = c
	return c
end

local function BoneFrame(ent, bone)
	local c = EntFrame(ent)
	local F = c.b[bone]
	if F ~= nil then return F end
	local m = ent:GetBoneMatrix(bone)
	if not m then
		ent:SetupBones()
		m = ent:GetBoneMatrix(bone)
		if not m then c.b[bone] = false return false end
	end
	local o, a = m:GetTranslation(), m:GetAngles()
	local f, r, u = a:Forward(), a:Right(), a:Up()
	F = { o.x, o.y, o.z, f.x, f.y, f.z, -r.x, -r.y, -r.z, u.x, u.y, u.z }
	c.b[bone] = F
	return F
end
U.BoneFrame = BoneFrame

local boxCache = {}
local function Hitboxes(ent)
	local c = EntFrame(ent)
	if c.hb then return c.hb end
	local list = {}
	c.hb = list
	if (ent:GetHitboxSetCount() or 0) <= 0 then return list end
	local set = ent:GetHitboxSet() or 0
	local key = (ent:GetModel() or "") .. "#" .. set
	local boxes = boxCache[key]
	if not boxes then
		boxes = {}
		for hb = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
			local bone = ent:GetHitBoxBone(hb, set)
			local mins, maxs = ent:GetHitBoxBounds(hb, set)
			local group = ent.GetHitBoxHitGroup and ent:GetHitBoxHitGroup(hb, set) or 0
			if bone and mins and maxs then boxes[#boxes + 1] = { bone, mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z, group or 0 } end
		end
		boxCache[key] = boxes
	end
	for i = 1, #boxes do
		local b = boxes[i]
		local F = BoneFrame(ent, b[1])
		if F then
			list[#list + 1] = { b[1], F, b[2], b[3], b[4], b[5], b[6], b[7], (b[2] + b[5]) * 0.5, (b[3] + b[6]) * 0.5, (b[4] + b[7]) * 0.5, b[8] }
		end
	end
	return list
end

local function Clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

local function BoxDist(h, px, py, pz)
	local F = h[2]
	local dx, dy, dz = px - F[1], py - F[2], pz - F[3]
	local lx = dx * F[4] + dy * F[5] + dz * F[6]
	local ly = dx * F[7] + dy * F[8] + dz * F[9]
	local lz = dx * F[10] + dy * F[11] + dz * F[12]
	local cx, cy, cz = Clamp(lx, h[3], h[6]) - lx, Clamp(ly, h[4], h[7]) - ly, Clamp(lz, h[5], h[8]) - lz
	local ex, ey, ez = h[9] - lx, h[10] - ly, h[11] - lz
	return cx * cx + cy * cy + cz * cz, ex * ex + ey * ey + ez * ez
end

function U.OnBoneBox(ent, bone, pos, tol)
	local list = Hitboxes(ent)
	local px, py, pz = pos.x, pos.y, pos.z
	local any = false
	for i = 1, #list do
		local h = list[i]
		if h[1] == bone then
			any = true
			if BoxDist(h, px, py, pz) <= tol * tol then return true end
		end
	end
	return not any and #list == 0
end

function U.NearestBone(ent, pos, hitgroup)
	local px, py, pz = pos.x, pos.y, pos.z
	local best, bd = nil, huge
	local list = Hitboxes(ent)
	if hitgroup and hitgroup > 0 then
		for i = 1, #list do
			local h = list[i]
			if h[12] == hitgroup then
				local o, c = BoxDist(h, px, py, pz)
				local d = o + 0.02 * c
				if d < bd then best, bd = h[1], d end
			end
		end
		if best and bd < 12 * 12 then return best end
		best, bd = nil, huge
	end
	for i = 1, #list do
		local h = list[i]
		local o, c = BoxDist(h, px, py, pz)
		local d = o + 0.02 * c
		if d < bd then best, bd = h[1], d end
	end
	if best then return best end
	for b = 0, (ent:GetBoneCount() or 0) - 1 do
		local F = BoneFrame(ent, b)
		if F then
			local dx, dy, dz = px - F[1], py - F[2], pz - F[3]
			local d = dx * dx + dy * dy + dz * dz
			if d < bd then best, bd = b, d end
		end
	end
	return best or 0
end

local function RayBoxes(ent, sx, sy, sz, dx, dy, dz)
	local list = Hitboxes(ent)
	local bf, bb, bF, bAxis, bSign = huge, nil, nil, 0, 0
	for i = 1, #list do
		local h = list[i]
		local F = h[2]
		local ox, oy, oz = sx - F[1], sy - F[2], sz - F[3]
		local s1 = ox * F[4] + oy * F[5] + oz * F[6]
		local s2 = ox * F[7] + oy * F[8] + oz * F[9]
		local s3 = ox * F[10] + oy * F[11] + oz * F[12]
		local d1 = dx * F[4] + dy * F[5] + dz * F[6]
		local d2 = dx * F[7] + dy * F[8] + dz * F[9]
		local d3 = dx * F[10] + dy * F[11] + dz * F[12]
		local tmin, tmax, axis, sign = -huge, huge, 0, 0
		local miss = false
		if d1 > -1e-9 and d1 < 1e-9 then
			if s1 < h[3] or s1 > h[6] then miss = true end
		else
			local t1, t2 = (h[3] - s1) / d1, (h[6] - s1) / d1
			local sg = -1
			if t1 > t2 then t1, t2 = t2, t1 sg = 1 end
			if t1 > tmin then tmin, axis, sign = t1, 1, sg end
			if t2 < tmax then tmax = t2 end
		end
		if not miss then
			if d2 > -1e-9 and d2 < 1e-9 then
				if s2 < h[4] or s2 > h[7] then miss = true end
			else
				local t1, t2 = (h[4] - s2) / d2, (h[7] - s2) / d2
				local sg = -1
				if t1 > t2 then t1, t2 = t2, t1 sg = 1 end
				if t1 > tmin then tmin, axis, sign = t1, 2, sg end
				if t2 < tmax then tmax = t2 end
			end
		end
		if not miss then
			if d3 > -1e-9 and d3 < 1e-9 then
				if s3 < h[5] or s3 > h[8] then miss = true end
			else
				local t1, t2 = (h[5] - s3) / d3, (h[8] - s3) / d3
				local sg = -1
				if t1 > t2 then t1, t2 = t2, t1 sg = 1 end
				if t1 > tmin then tmin, axis, sign = t1, 3, sg end
				if t2 < tmax then tmax = t2 end
			end
		end
		if not miss and tmin <= tmax and tmax >= 0 and tmin <= 1 then
			local fr = tmin > 0 and tmin or 0
			if fr < bf then bf, bb, bF, bAxis, bSign = fr, h[1], F, (tmin > 0) and axis or 0, sign end
		end
	end
	if not bb then return nil end
	local hp = Vector(sx + dx * bf, sy + dy * bf, sz + dz * bf)
	local hn
	if bAxis == 0 then
		local l = sqrt(dx * dx + dy * dy + dz * dz)
		hn = l > 0 and Vector(-dx / l, -dy / l, -dz / l) or Vector(0, 0, 1)
	else
		local k = bAxis * 3 + 1
		hn = Vector(bF[k] * bSign, bF[k + 1] * bSign, bF[k + 2] * bSign)
	end
	return hp, hn, bf, bb
end

function U.RayHitboxes(ent, start, delta)
	return RayBoxes(ent, start.x, start.y, start.z, delta.x, delta.y, delta.z)
end

local cf = { f = -1 }
local function CorpseFrame()
	local fn = FrameNumber()
	local list = U.corpses
	if cf.f == fn and cf.src == list then return cf end
	cf.f, cf.src = fn, list
	local n = 0
	for i = 1, #list do
		local e = list[i]
		if IsValid(e) then
			local c = e:WorldSpaceCenter()
			local r = e:BoundingRadius() + 4
			n = n + 1
			local row = cf[n]
			if not row then row = {} cf[n] = row end
			row[1], row[2], row[3], row[4], row[5] = e, c.x, c.y, c.z, r * r
		end
	end
	cf.n = n
	return cf
end

local ctr = {}
function U.TraceCorpses(start, endpos, ignore)
	if #U.corpses == 0 then return nil end
	local sx, sy, sz = start.x, start.y, start.z
	local dx, dy, dz = endpos.x - sx, endpos.y - sy, endpos.z - sz
	local len2 = dx * dx + dy * dy + dz * dz
	if len2 < 1e-6 then return nil end
	local C = CorpseFrame()
	local bestF, best = huge, nil
	for i = 1, C.n do
		local row = C[i]
		local e = row[1]
		if e ~= ignore then
			local cx, cy, cz = row[2], row[3], row[4]
			local t = ((cx - sx) * dx + (cy - sy) * dy + (cz - sz) * dz) / len2
			if t < 0 then t = 0 elseif t > 1 then t = 1 end
			local qx, qy, qz = sx + dx * t - cx, sy + dy * t - cy, sz + dz * t - cz
			if qx * qx + qy * qy + qz * qz < row[5] and IsValid(e) then
				local hp, hn, fr, bone = RayBoxes(e, sx, sy, sz, dx, dy, dz)
				if hp and fr < bestF then
					bestF = fr
					ctr.Hit, ctr.HitPos, ctr.HitNormal, ctr.Entity, ctr.Fraction, ctr.HitWorld, ctr.HitSky, ctr.StartSolid, ctr.HitBone =
						true, hp, hn, e, fr, false, false, false, bone
					best = ctr
				end
			end
		end
	end
	return best
end

local function Flat(c, bone)
	local fl = c.flat
	if not fl then fl = {} c.flat = fl end
	local a = fl[bone]
	if a ~= nil then return a end
	local list = c[bone]
	if not list then fl[bone] = false return false end
	a = {}
	for i = 1, #list do
		local v = list[i]
		local p, n = v[1], v[2]
		local k = (i - 1) * 6
		a[k + 1], a[k + 2], a[k + 3], a[k + 4], a[k + 5], a[k + 6] = p.x, p.y, p.z, n.x, n.y, n.z
	end
	fl[bone] = a
	return a
end

local function ScanFlat(a, lx, ly, lz, nx, ny, nz, hasN, bi, bd)
	for k = 1, #a, 6 do
		local ex, ey, ez = a[k] - lx, a[k + 1] - ly, a[k + 2] - lz
		local d = ex * ex + ey * ey + ez * ez
		if hasN and a[k + 3] * nx + a[k + 4] * ny + a[k + 5] * nz < 0 then d = d * 4 + 4 end
		if d < bd then bi, bd = k, d end
	end
	return bi, bd
end

local SNAP_REACH2 = 7 * 7
local SNAP_LAT2 = 3.5 * 3.5
local SNAP_MOVE2 = 4.5 * 4.5
U.SNAP_REACH2, U.SNAP_LAT2, U.SNAP_MOVE2 = SNAP_REACH2, SNAP_LAT2, SNAP_MOVE2

local boneInfo = {}
local function Neighbours(ent, mdl, bone)
	local bi = boneInfo[mdl]
	if not bi then bi = {} boneInfo[mdl] = bi end
	local nb = bi[bone]
	if nb then return nb end
	nb = {}
	local parent = ent:GetBoneParent(bone)
	if parent and parent >= 0 then nb[#nb + 1] = parent end
	for _, ch in ipairs(ent:GetChildBones(bone) or {}) do nb[#nb + 1] = ch end
	bi[bone] = nb
	return nb
end

function U.SnapToMesh(ent, pos, nrm, bone, force)
	if not IsValid(ent) or not pos then return pos, nrm, bone end
	local mdl = ent:GetModel()
	if not mdl then return pos, nrm, bone end
	local c = U.meshCache[mdl]
	if c == nil then c = BuildBoneVerts(mdl) U.meshCache[mdl] = c end
	if not c then return pos, nrm, bone end
	bone = bone or U.NearestBone(ent, pos)
	local F = BoneFrame(ent, bone)
	if not F then return pos, nrm, bone end
	local px, py, pz = pos.x, pos.y, pos.z
	local hasN = nrm ~= nil
	local wx, wy, wz = 0, 0, 0
	if hasN then wx, wy, wz = nrm.x, nrm.y, nrm.z end
	local function toLocal(Fr)
		local dx, dy, dz = px - Fr[1], py - Fr[2], pz - Fr[3]
		return dx * Fr[4] + dy * Fr[5] + dz * Fr[6], dx * Fr[7] + dy * Fr[8] + dz * Fr[9], dx * Fr[10] + dy * Fr[11] + dz * Fr[12],
			wx * Fr[4] + wy * Fr[5] + wz * Fr[6], wx * Fr[7] + wy * Fr[8] + wz * Fr[9], wx * Fr[10] + wy * Fr[11] + wz * Fr[12]
	end
	local lx, ly, lz, nx, ny, nz = toLocal(F)
	local bi, bd, bA, bF, bBone = nil, huge, nil, F, bone
	local a = Flat(c, bone)
	if a then bi, bd = ScanFlat(a, lx, ly, lz, nx, ny, nz, hasN, nil, huge) bA = a end
	if not bi or bd > 4 then
		local nb = Neighbours(ent, mdl, bone)
		for j = 1, #nb do
			local cb = nb[j]
			local Fc = BoneFrame(ent, cb)
			local ac = Fc and Flat(c, cb)
			if ac then
				local clx, cly, clz, cnx, cny, cnz = toLocal(Fc)
				local i2, d2 = ScanFlat(ac, clx, cly, clz, cnx, cny, cnz, hasN, nil, bd)
				if i2 and d2 < bd then
					bi, bd, bA, bF, bBone = i2, d2, ac, Fc, cb
					lx, ly, lz = clx, cly, clz
				end
			end
		end
	end
	if not bi or (not force and bd > SNAP_REACH2) then return pos, nrm, bone end
	local vx, vy, vz = bA[bi + 3], bA[bi + 4], bA[bi + 5]
	local ex, ey, ez = lx - bA[bi], ly - bA[bi + 1], lz - bA[bi + 2]
	local t = ex * vx + ey * vy + ez * vz
	local qx, qy, qz
	if ex * ex + ey * ey + ez * ez - t * t > SNAP_LAT2 or t * t > SNAP_MOVE2 then
		if not force then return pos, nrm, bone end
		qx, qy, qz = bA[bi], bA[bi + 1], bA[bi + 2]
	else
		qx, qy, qz = lx - vx * t, ly - vy * t, lz - vz * t
	end
	local Fr = bF
	return Vector(Fr[1] + Fr[4] * qx + Fr[7] * qy + Fr[10] * qz, Fr[2] + Fr[5] * qx + Fr[8] * qy + Fr[11] * qz, Fr[3] + Fr[6] * qx + Fr[9] * qy + Fr[12] * qz),
		Vector(Fr[4] * vx + Fr[7] * vy + Fr[10] * vz, Fr[5] * vx + Fr[8] * vy + Fr[11] * vz, Fr[6] * vx + Fr[9] * vy + Fr[12] * vz),
		bBone
end

local MUA_DEOX, MUA_OX = { 12.5, 1.25, 62.0, 88.0 }, { 6.3, 0.39, 52.0, 78.0 }
local MUA = {
	[1] = { 0.5, 0.42, 0.6, 20.0 },
	[2] = { 5.0, 8.0, 1.0, 9.0 },
	[3] = { 10.0, 3.5, 7.0, 22.0 },
	[4] = { 10.78, 17.60, 1.68, 1.25 },
	[5] = { 25.82, 18.80, 20.95, 52.30 },
	[6] = { 14.0, 9.0, 4.0, 0.6 },
	[7] = { 6.0, 1.2, 18.0, 2.5 },
}
local LAYER = 0.12
local function Lin(c) return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function Srgb(c) c = math.Clamp(c, 0, 1) return c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055 end
local function Bands(btype, oxy, hue, absorb, layer)
	layer = layer or LAYER
	local m = MUA[btype]
	local mu = {}
	if m then mu = m else
		oxy = math.Clamp(oxy or 0.75, 0, 1)
		for i = 1, 4 do mu[i] = MUA_DEOX[i] + (MUA_OX[i] - MUA_DEOX[i]) * oxy end
	end
	local hm = { math.exp(-1.6 * hue), math.exp(-0.3 * hue), math.exp(-0.8 * hue), math.exp(1.1 * hue) }
	local T = {}
	for i = 1, 4 do T[i] = math.exp(-2 * mu[i] * hm[i] * absorb * layer) end
	return 0.25 * T[1] + 0.82 * T[2], 0.012 * T[1] + 0.9 * T[3], 0.016 * T[3] + 0.88 * T[4]
end
local REF_R = Bands(0, 0.75, 0, 1)

-- (1.26.6) the player's own blood colours (Look > Your own blood colours): a thin film of fresh blood and a deep pool,
-- sRGB "R G B". The defaults are what the shaders show at the default settings (U.ShaderLook(0, 1.85)), so turning the
-- option on with them changes next to nothing. Lua-drawn blood (Lite, 3D bursts, mist, water) gets the picked colour at
-- the brightness the default would have; the shaders get the fitted hue and absorption (U.ShaderFit). Red blood only.
U.DEF_BLOOD, U.DEF_DENSE = "159 13 7", "97 12 7"
local function ParseRGB(s, def)
	local r, g, b = string.match(s or "", "(%d+)[%s,;]+(%d+)[%s,;]+(%d+)")
	if not r then r, g, b = string.match(def, "(%d+) (%d+) (%d+)") end
	return math.Clamp(tonumber(r) or 0, 0, 255), math.Clamp(tonumber(g) or 0, 0, 255), math.Clamp(tonumber(b) or 0, 0, 255)
end
U.ParseRGB = ParseRGB
local function LinRGB(s, def)
	local r, g, b = ParseRGB(s, def)
	return { math.max(Lin(r / 255), 1e-4), math.max(Lin(g / 255), 1e-4), math.max(Lin(b / 255), 1e-4) }
end
local DEF_THIN_L, DEF_DENSE_L = LinRGB(U.DEF_BLOOD, U.DEF_BLOOD), LinRGB(U.DEF_DENSE, U.DEF_DENSE)
local cust = {}
function U.CustomOn()
	local cv = G.cv
	return cv.colCustom ~= nil and cv.colCustom:GetBool()
end
-- linear thin and dense colours of the player, or nil when the option is off
function U.CustomColours()
	if not U.CustomOn() then return nil end
	local s1, s2 = G.cv.colBlood:GetString(), G.cv.colDense:GetString()
	if cust.s1 ~= s1 or cust.s2 ~= s2 then
		local t, d = LinRGB(s1, U.DEF_BLOOD), LinRGB(s2, U.DEF_DENSE)
		cust = { s1 = s1, s2 = s2, thin = t, dense = d, at = {} }
		-- the thin pick as an absorbance relative to the default's (Lite transmittance: T_custom = T_default ^ a)
		for i = 1, 3 do
			local a0 = -math.log(math.Clamp(DEF_THIN_L[i] / 0.8, 1e-4, 0.98))
			local a1 = -math.log(math.Clamp(t[i] / 0.8, 1e-4, 0.98))
			cust.at[i] = math.Clamp(a1 / a0, 0.02, 6)
		end
	end
	return cust.thin, cust.dense
end

-- mirror of the shaders' wet-blood optics (Kubelka-Munk two-flux, the four absorption bands above, the shaders'
-- scattering) for the fit and the menu preview: a 0.1 mm film on a light floor, and a deep pool
local MUS = { 1.54, 1.54, 1.14, 1.72 }
local function KM(K, S, d, Rg)
	local a = 1 + K / S
	local b = math.sqrt(a * a - 1)
	local e = math.exp(-2 * math.min(b * S * d, 20))
	local t = (1 - e) / (1 + e)
	return (t - Rg * (a * t - b)) / math.max(a * t - Rg * t + b, 1e-5)
end
function U.ShaderLook(hue, A, oxy)
	oxy = math.Clamp(oxy or 0.75, 0, 1)
	local hm = { math.exp(-1.6 * hue), math.exp(-0.3 * hue), math.exp(-0.8 * hue), math.exp(1.1 * hue) }
	local t, d = {}, {}
	for i = 1, 4 do
		local mu = MUA_DEOX[i] + (MUA_OX[i] - MUA_DEOX[i]) * oxy
		local K, S = 2 * mu * hm[i] * A, 0.75 * MUS[i]
		t[i], d[i] = KM(K, S, 0.10, 0.8), KM(K, S, 4.0, 0.3)
	end
	return { 0.35 * t[1] + 0.65 * t[2], 0.1 * t[1] + 0.9 * t[3], 0.12 * t[3] + 0.88 * t[4] },
		{ 0.35 * d[1] + 0.65 * d[2], 0.1 * d[1] + 0.9 * d[3], 0.12 * d[3] + 0.88 * d[4] }
end
local function OkLab(c)
	local l = 0.4122214708 * c[1] + 0.5363325363 * c[2] + 0.0514459929 * c[3]
	local m = 0.2119034982 * c[1] + 0.6806995451 * c[2] + 0.1073969566 * c[3]
	local s = 0.0883024619 * c[1] + 0.2817188376 * c[2] + 0.6299787005 * c[3]
	l, m, s = math.max(l, 0) ^ (1 / 3), math.max(m, 0) ^ (1 / 3), math.max(s, 0) ^ (1 / 3)
	return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
end
local function Dist2(a, b)
	local l1, a1, b1 = OkLab(a)
	local l2, a2, b2 = OkLab(b)
	return (l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2
end
U.ColourDist2 = Dist2
-- the hue (-1..2) and absorption scale (the shaders' density x fresh brightness) whose film and pool come closest to the
-- player's colours, and the error (OKLab distance squared, weighted; > ~0.004 = clearly off)
function U.ShaderFit()
	local thin, dense = U.CustomColours()
	if not thin then return nil end
	local f = cust.fit
	if f then return f[1], f[2], f[3] end
	local function E(h, A)
		local t, d = U.ShaderLook(h, A)
		return 0.4 * Dist2(t, thin) + 0.6 * Dist2(d, dense)
	end
	local bh, bA, be = 0, 1.85, math.huge
	for hi = -10, 20 do
		local h = hi * 0.1
		for ai = 0, 30 do
			local A = 0.25 * math.exp(ai * 0.13)
			local e = E(h, A)
			if e < be then bh, bA, be = h, A, e end
		end
	end
	local sh, sa = 0.05, 0.065
	for _ = 1, 4 do
		local nh, nA = bh, bA
		for dh = -2, 2 do
			for da = -2, 2 do
				local h = math.Clamp(bh + dh * sh, -1, 2)
				local A = math.Clamp(bA * math.exp(da * sa), 0.2, 14)
				local e = E(h, A)
				if e < be then nh, nA, be = h, A, e end
			end
		end
		bh, bA = nh, nA
		sh, sa = sh * 0.5, sa * 0.5
	end
	cust.fit = { bh, bA, be }
	return bh, bA, be
end
-- what the shaders get: the settings' hue and absorption, or with the player's colours on the fitted ones, still fine-tuned
-- by the Hue / Fresh brightness / Density sliders
-- (1.26.9c) the 1.26.9c shader pack is built from the readable shader source (the 1.26.6 - 1.26.8 packs came from a
-- different set): the same colour settings give a lighter, pinker blood in it. When its files are installed, the
-- absorption, hue, dried darkness and shine the shaders get are scaled so the blood keeps the look players know (measured
-- in game against the 1.26.8 pack, same pour, same settings). With an older pack installed nothing changes.
-- (1.26.9d) and the look GHM picked from a reference video: deeper, near-black red pools (deep: the absorption of red
-- blood is raised up to 3x, but never past what the default colours give - those are already that dark), a slightly cooler
-- crimson (redHue) and less shine, while thin edges and spatter stay a brighter red (the thin-film boost in the shaders
-- is lower)
-- (1.26.10e) GHM: "get me this look for the blood and all blood colors again" (his 1.26.2 shots: pools a clear, saturated
-- scarlet, about sRGB (75-105, 5, 2), thin smears see-through, deep pools opaque, and they stay red) - the 1.26.9d video look
-- is taken back out: deep 3 -> 1 and redHue -0.2 -> 0 (red pools were a near-black maroon, ~(50, 6, 5) in game; the shine
-- stays at 0.07 - more of it lays a milky sky reflection over the red outdoors). Two more for every blood type:
--   ageMax: clotting may darken blood to at most 1.5x its fresh absorption. The 1.26.6 ageing took every type to the same
--     absorption (9.75 with the default colours: 4.6x fresh for red, ~2x for the others), so every pool that had sat for a
--     few minutes went black-brown. Older blood is still a little darker.
--   other: the types other than red get half the absorption (2.5 instead of 5.1 at the defaults), so yellow, green, zombie,
--     synth, blue and purple pools are as clear and bright as the red ones again (red got ~3x lighter). Oil stays black.
--   Lua-drawn blood (drops, bursts, mist, the screen film) follows, as it takes these same values.
-- (1.26.10g) GHM: "blood lost all of its reflections and wetness". The shine was set for the near-black 1.26.9d pools:
--   with the body 2.3x lighter the same reflection is lost against it, and pools read as matte paint. Worked out offline
--   (a port of the shaders' floor shading, calibrated on in-game shots of 1.26.10d and checked against 1.26.10e):
--   deep 1 -> 1.75 and refl 0.07 -> 0.094 give the 1.26.10d sheen back on a scarlet pool (sRGB ~(98-102, 39, 40)).
--   refl alone would need 0.14 and turns the pools milky; deep alone loses the scarlet. At Shine 1 the shaders get the
--   reflection in 64ths, so 0.07 was 4/64 and 0.094 is 6/64 (1.5x). Thin smears stay see-through, deep pools opaque.
G.SHADER_COMP_PACK = "1.26.11"
G.SHADER_COMP = { abs = 4.5, hue = 0, dry = 6.0, refl = 0.094, deep = 1.75, redHue = 0, ageMax = 1.5, other = 0.5 }
local NEUTRAL_COMP = { abs = 1, hue = 0, dry = 1, refl = 1, deep = 1, redHue = 0 }
function G.ShaderComp()
	local c = G.shaderCompOn
	if c == nil then
		local pack = G.ShaderPack
		local want = pack and pack.files and pack.files.surfstatic_ps30
		local rel = "shaders/fxc/" .. (G.ShaderPrefix or "") .. "surfstatic_ps30.vcs"
		local ok, sz = pcall(function()
			local s = file.Size(rel, "GAME")
			if (not s or s < 0) and file.Exists("garrysmod/" .. rel, "BASE_PATH") then s = file.Size("garrysmod/" .. rel, "BASE_PATH") end
			return s
		end)
		if not ok then sz = nil end
		c = (want ~= nil and sz == want and pack.version == G.SHADER_COMP_PACK) and true or false
		G.shaderCompOn = c
	end
	return c and G.SHADER_COMP or NEUTRAL_COMP
end
-- (1.26.9c) true when the 1.26.9c / 1.26.9d shader pack is installed. The serum flag (+1024 in the material word) and the small
-- floor-splat stain share need those shaders: with an older pack the flag would be read as a wrong material and the
-- droplets would look faint, so both stay as in 1.26.9b there
function G.NewShaders() G.ShaderComp() return G.shaderCompOn == true end
function G.BloodHue()
	local cv = G.cv
	local h = cv.colHue and cv.colHue:GetFloat() or 0
	local fh = U.ShaderFit()
	local c = G.ShaderComp()
	local ho = c.hue + (c.redHue or 0)
	if fh then return math.Clamp(fh + h + ho, -1, 2) end
	return math.Clamp(h + ho, -1, 1)
end
function G.BloodAbsorb()
	local cv = G.cv
	local a = (cv.absorb and cv.absorb:GetFloat() or 1) * (G.GPU and G.GPU.FreshAbs and G.GPU.FreshAbs() or 1.85)
	local fh, fA = U.ShaderFit()
	local c = G.ShaderComp()
	local k = c.abs
	local v = fh and (fA * a / 1.85 * k) or (a * k)
	local d = c.deep or 1
	if d > 1 then v = math.max(v, math.min(v * d, 1.85 * k)) end
	return v
end
-- (1.26.6) the player's own colours are for red blood only: every other blood type (yellow, green, zombie, synth, oil)
-- gets the plain settings' hue and absorption - the values fitted to bright own colours made zombie and alien blood a
-- bright orange
function G.BloodHueFor(btype)
	if (btype or 0) == 0 then return G.BloodHue() end
	return math.Clamp((G.cv.colHue and G.cv.colHue:GetFloat() or 0) + G.ShaderComp().hue, -1, 1)
end
function G.BloodAbsorbFor(btype)
	if (btype or 0) == 0 then return G.BloodAbsorb() end
	local cv = G.cv
	local c = G.ShaderComp()
	return (cv.absorb and cv.absorb:GetFloat() or 1) * (G.GPU and G.GPU.FreshAbs and G.GPU.FreshAbs() or 1.85) * c.abs * (c.other or 1)
end
-- (1.26.6) blood darkens as it clots and ages (deoxygenation, methaemoglobin). The shaders darken the dried crust on
-- their own, but wet and clotted blood keeps the fresh absorption - with bright fresh colours an old pool stayed bright
-- scarlet for ever. Over the clotting time the absorption goes from the fresh value to at least the default physical
-- one (1.85 x the "Dried / old blood brightness" setting); blood that is already that dark is left alone.
function G.AgedAbsorb(btype)
	local fresh = G.BloodAbsorbFor(btype)
	local k = math.max(G.cv.colDry and G.cv.colDry:GetFloat() or 1, 0.3) ^ -1.5
	local c = G.ShaderComp()
	local aged = 1.85 * k * c.abs
	if c.ageMax then aged = math.min(aged, fresh * c.ageMax) end   -- (1.26.10e)
	return fresh, math.max(fresh, aged)
end
-- (1.26.6) how much wetter fresh blood looks than the Wetness setting says (the shaders' wetness, which only acts on the
-- wet film): thin films, splatter and runs keep the look of a liquid - glossy, deep red, not a dry stain - while the blood
-- is fresh. Full until 40 % of the clotting time, then fading out, gone once it has clotted
function G.FreshWet(age)
	local cv = G.cv.freshwet
	local fw = cv and math.Clamp(cv:GetFloat(), 1, 3) or 2.5
	if fw <= 1 then return 1 end
	local x = math.Clamp(((age or 0) / math.max(G.CoagTime and G.CoagTime() or 180, 5) - 0.4) / 0.6, 0, 1)
	return 1 + (fw - 1) * (1 - x * x * (3 - 2 * x))
end
-- how far blood of this (volume-weighted) age has aged, 0..1 over the clotting time
function G.AgeFrac(age)
	if not age or age <= 0 then return 0 end
	local x = math.Clamp(age / math.max(G.CoagTime and G.CoagTime() or 180, 5), 0, 1)
	return x * x * (3 - 2 * x)
end
-- absorption for blood that has aged f (0..1)
function G.AbsorbAged(btype, f)
	local fresh, aged = G.AgedAbsorb(btype)
	if f <= 0 or aged <= fresh * 1.001 then return fresh end
	return fresh * (aged / fresh) ^ math.min(f, 1)
end
-- shine (multiplier of the reflections and highlights) of blood that has dried dry drying times: wet and clotted blood
-- keep their full shine, dried blood loses most of it (f, the clotting, is not used any more: pools that lost shine as
-- they clotted looked matte next to their fresh streams)
function G.ShineAged(f, dry)
	local d = math.Clamp(((dry or 0) - 0.15) / 1.6, 0, 1)
	return 1 - 0.65 * d * d * (3 - 2 * d)
end
-- the same for world blood of a given age (s): dry from the clotting time on
function G.ShineAt(age)
	return G.ShineAged(0, math.max((age or 0) - (G.CoagTime and G.CoagTime() or 180), 0) / math.max(G.DryTime and G.DryTime() or 240, 5))
end

local colCache, colKey = {}, nil
local function Colour(btype, oxy, refR, dense)
	local cv = G.cv
	local hue = cv.colHue and math.Clamp(cv.colHue:GetFloat(), -1, 1) or 0
	local absorb = (cv.absorb and cv.absorb:GetFloat() or 1) * (G.GPU and G.GPU.FreshAbs and G.GPU.FreshAbs() or 1)
	local custom = (btype or 0) == 0 and U.CustomColours() ~= nil
	local key = hue .. "|" .. absorb .. (custom and ("|" .. cust.s1 .. "|" .. cust.s2) or "")
	if key ~= colKey then colCache, colKey = {}, key end
	local ck = (btype or 0) * 100000 + math.floor(math.Clamp(oxy or 0.75, 0, 1) * 20 + 0.5) * 1000 + math.floor(refR) + (dense and 0.5 or 0)
	local c = colCache[ck]
	if c then return c[1], c[2], c[3] end
	local r, g, b = Bands(btype or 0, oxy, hue, absorb)
	local k = Lin(refR / 255) / REF_R
	r, g, b = r * k, g * k, b * k
	if custom then
		-- the player's colour at the brightness the default would have here (its red channel: the sliders, the oxygen and
		-- refR all act on it as before)
		local base = dense and cust.dense or cust.thin
		local q = r / (dense and DEF_DENSE_L[1] or DEF_THIN_L[1])
		r, g, b = base[1] * q, base[2] * q, base[3] * q
	end
	c = { Srgb(r) * 255, Srgb(g) * 255, Srgb(b) * 255 }
	colCache[ck] = c
	return c[1], c[2], c[3]
end
-- the colour of blood (sRGB 0-255, its red channel near refR at the default settings): thin blood, spray, mist
function U.BloodColour(btype, oxy, refR) return Colour(btype, oxy, refR, false) end
-- (1.26.6) the same for a body of blood (Lite pools, 3D bursts): the player's dense colour when theirs are on
function U.BloodDense(btype, oxy, refR) return Colour(btype, oxy, refR, true) end

function U.BloodTrans(btype, oxy, h)
	local cv = G.cv
	local hue = cv.colHue and math.Clamp(cv.colHue:GetFloat(), -1, 1) or 0
	local absorb = (cv.absorb and cv.absorb:GetFloat() or 1) * (G.GPU and G.GPU.FreshAbs and G.GPU.FreshAbs() or 1)
	local r, g, b = Bands(btype or 0, oxy, hue, absorb, h)
	if (btype or 0) == 0 and U.CustomColours() then
		-- relative to the clear value (h = 0), so the player's absorbance scales the default's
		local a = cust.at
		r = 1.07 * math.Clamp(r / 1.07, 1e-5, 1) ^ a[1]
		g = 0.912 * math.Clamp(g / 0.912, 1e-5, 1) ^ a[2]
		b = 0.896 * math.Clamp(b / 0.896, 1e-5, 1) ^ a[3]
	end
	return r, g, b
end

-- (1.26.10c) GHM: "can we make it that each particle is matching the color of the blood emitted" - the colour of blood as the
-- shaders draw it, for everything Lua draws (the 3D drops, bursts and streams, the mist, the screen): the shaders' own
-- absorption (ghmpb_common.h ghmpb_muaWet4W and ghmpb_otherWet4, 4 bands: 580-610 nm, 620-700 nm, green, blue), their
-- scattering, the hue and absorption the shaders get (G.BloodHueFor / G.BloodAbsorbFor: the player's own colours and the
-- shader pack's compensation included) and the drop shader's Kubelka-Munk body colour of the chord through a drop. Before,
-- Lua-drawn blood had colours of its own (older absorption values, the picked colour at its own brightness, the bursts'
-- own brightness and hue): bright red bursts and mist over near-black pools, synth and oil drops cyan and black next to
-- brown pools. (The new types' values are tuned for the absorption the shaders get with the 1.26.10 pack, ~5 for the
-- blood types other than red: blue, purple and synth come out as bright as yellow and red pools.)
U.MUA4 = {
	[1] = { 0.5, 0.42, 0.6, 20.0 }, [2] = { 5.0, 8.0, 1.0, 9.0 }, [3] = { 10.0, 3.5, 7.0, 22.0 },
	[4] = { 0.9, 0.75, 0.42, 0.3 }, [5] = { 25.8, 18.8, 21.0, 52.3 }, [6] = { 12.0, 8.0, 2.2, 0.28 }, [7] = { 3.5, 0.32, 14.0, 0.45 },
}
local RED_DEOX4, RED_OX4 = { 12.0, 2.4 * 0.8, 28.0 * 5.0, 40.0 * 6.0 }, { 8.0, 0.35 * 0.8, 24.0 * 5.0, 26.0 * 6.0 }
local MUS4 = { 1.54, 1.54, 1.14, 1.72 }
local mtmp = {}
local function Mua4(bt, oxy)
	local m = U.MUA4[bt or 0]
	if m then return m end
	oxy = math.Clamp(oxy or 0.75, 0, 1)
	for i = 1, 4 do mtmp[i] = RED_DEOX4[i] + (RED_OX4[i] - RED_DEOX4[i]) * oxy end
	return mtmp
end
U.Mua4 = Mua4
local function HueMul(h) return math.exp(-1.6 * h), math.exp(-0.3 * h), math.exp(-0.8 * h), math.exp(1.1 * h) end
local fluidCache, fluidKey = {}, nil
local function FluidKey()
	local cv = G.cv
	return tostring(G.BloodHueFor and G.BloodHueFor(0)) .. "|" .. tostring(G.BloodAbsorbFor and G.BloodAbsorbFor(0)) .. "|"
		.. tostring(G.BloodAbsorbFor and G.BloodAbsorbFor(1)) .. "|" .. tostring(cv.colHue and cv.colHue:GetFloat())
end
-- the body colour (linear albedo, as the drop shader shades it: Kubelka-Munk over the chord with the Saunderson surface
-- correction) of a piece of blood chord mm thick
function U.FluidAlbedo(bt, oxy, chord)
	bt = bt or 0
	local key = FluidKey()
	if key ~= fluidKey then fluidCache, fluidKey = {}, key end
	local ck = bt * 100000 + math.floor(math.Clamp(oxy or 0.75, 0, 1) * 20 + 0.5) * 1000 + math.floor(math.Clamp(chord or 2, 0.01, 99) * 10 + 0.5)
	local c = fluidCache[ck]
	if c then return c[1], c[2], c[3] end
	local A = G.BloodAbsorbFor and G.BloodAbsorbFor(bt) or 1.85
	local h1, h2, h3, h4 = HueMul(G.BloodHueFor and G.BloodHueFor(bt) or 0)
	local hm = { h1, h2, h3, h4 }
	local m = Mua4(bt, oxy)
	local d = math.Clamp(chord or 2, 0.01, 99)
	local r = {}
	for i = 1, 4 do
		local K, S = 2 * m[i] * hm[i] * A, 0.75 * MUS4[i]
		local a = 1 + K / S
		local b = math.sqrt(a * a - 1)
		local e = math.exp(-2 * math.min(b * S * d, 20))
		local t = (1 - e) / (1 + e)
		local R = t / math.max(a * t + b, 1e-5)
		r[i] = 0.94 * 0.52 * R / (1 - 0.48 * R)
	end
	c = { 0.35 * r[1] + 0.65 * r[2], 0.1 * r[1] + 0.9 * r[3], 0.12 * r[3] + 0.88 * r[4] }
	fluidCache[ck] = c
	return c[1], c[2], c[3]
end
-- the same as sRGB 0-255, times k (the lighting of what draws it: 1.4 for the game's own lit materials - the bursts' and
-- the mist's lighting is ~0.7 of the light the drop shader puts on its drops)
function U.FluidColour255(bt, oxy, chord, k)
	local r, g, b = U.FluidAlbedo(bt, oxy, chord)
	k = k or 1.4
	return Srgb(r * k) * 255, Srgb(g * k) * 255, Srgb(b * k) * 255
end
-- absorbance per mm (r, g, b) of a thin film of this blood seen through (the screen): Beer-Lambert in the 4 bands
function U.FluidAbsorb3(bt, oxy, d)
	d = d or 0.06
	local A = G.BloodAbsorbFor and G.BloodAbsorbFor(bt or 0) or 1.85
	local h1, h2, h3, h4 = HueMul(G.BloodHueFor and G.BloodHueFor(bt or 0) or 0)
	local hm = { h1, h2, h3, h4 }
	local m = Mua4(bt or 0, oxy)
	local T = {}
	for i = 1, 4 do T[i] = math.exp(-2 * m[i] * hm[i] * A * d) end
	local tr, tg, tb = 0.35 * T[1] + 0.65 * T[2], 0.1 * T[1] + 0.9 * T[3], 0.12 * T[3] + 0.88 * T[4]
	return -math.log(math.max(tr, 1e-6)) / d, -math.log(math.max(tg, 1e-6)) / d, -math.log(math.max(tb, 1e-6)) / d
end
-- what Lua-drawn blood should follow: the shaders' colours while they draw the blood, Lite's own otherwise
function U.ShaderColours() return not (G.Lite and G.Lite.on) end

local cone = { f = -1 }
function U.ViewCone()
	local f = FrameNumber()
	if cone.f == f then return cone end
	cone.f = f
	cone.eye = EyePos()
	cone.fwd = EyeAngles():Forward()
	local fov = 90
	local vs = render.GetViewSetup and render.GetViewSetup()
	if vs and vs.fov then fov = vs.fov end
	local aspect = ScrW() / math.max(ScrH(), 1)
	local th = math.tan(math.rad(math.Clamp(fov, 10, 170)) * 0.5)
	cone.half = math.atan(th * math.sqrt(1 + 1 / (aspect * aspect))) + math.rad(6)
	return cone
end

function U.InViewPos(p, r)
	local c = U.ViewCone()
	r = r or 0
	local v = p - c.eye
	local d = v:Length()
	if d <= r then return true end
	local cosA = v:Dot(c.fwd) / d
	local a = math.acos(math.Clamp(cosA, -1, 1))
	return a <= c.half + math.asin(math.min(r / d, 1))
end

function U.InView(ent, extra)
	if not IsValid(ent) then return false end
	local c = U.ViewCone()
	local p = ent:WorldSpaceCenter()
	local r = (ent:BoundingRadius() or 40) * 1.2 + (extra or 12)
	local v = p - c.eye
	local d = v:Length()
	if d <= r then return true end
	local cosA = v:Dot(c.fwd) / d
	local a = math.acos(math.Clamp(cosA, -1, 1))
	return a <= c.half + math.asin(math.min(r / d, 1))
end
