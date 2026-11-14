local G = GHMPB
G.Entities = G.Entities or {}
local E = G.Entities
local GPU = G.GPU

E.domains = E.domains or {}
E.pool = E.pool or {}
E.slotCount = E.slotCount or 0

local SKIP_MAT = { "eyeball", "pupil", "glint", "iris", "cornea", "eye_", "_eye", "eyes", "teeth", "tongue", "hair",
	"lash", "brow", "lens", "glass", "visor", "tooth", "mouth", "shadow", "invisible", "nodraw", "tool" }
local CLOTH = { "sheet", "shirt", "pant", "jacket", "cloth", "uniform", "vest", "coat", "jean", "trouser", "suit",
	"hood", "glove", "sleeve", "dress", "skirt", "robe", "scarf", "sweater", "hoodie", "fabric", "gear", "outfit" }
local METAL = { "metal", "armor", "armour", "helmet", "steel", "plate", "combine_soldier", "police", "robot", "mech", "gasmask", "mask" }

E.modelInfo = E.modelInfo or {}
local function triArea(a, b, c) return (b - a):Cross(c - a):Length() * 0.5 end

local UVG = 64
local function UVRaster(cells, ua, va, ub, vb, uc, vc)
	local ax, ay, bx, by, cx, cy = ua * UVG, va * UVG, ub * UVG, vb * UVG, uc * UVG, vc * UVG
	local x0 = math.max(math.floor(math.min(ax, bx, cx)), 0)
	local x1 = math.min(math.ceil(math.max(ax, bx, cx)) - 1, UVG - 1)
	local y0 = math.max(math.floor(math.min(ay, by, cy)), 0)
	local y1 = math.min(math.ceil(math.max(ay, by, cy)) - 1, UVG - 1)
	local hit = false
	for y = y0, y1 do
		local py = y + 0.5
		for x = x0, x1 do
			local px = x + 0.5
			local w0 = (bx - px) * (cy - py) - (cx - px) * (by - py)
			local w1 = (cx - px) * (ay - py) - (ax - px) * (cy - py)
			local w2 = (ax - px) * (by - py) - (bx - px) * (ay - py)
			if (w0 >= 0 and w1 >= 0 and w2 >= 0) or (w0 <= 0 and w1 <= 0 and w2 <= 0) then cells[y * UVG + x] = true hit = true end
		end
	end
	if not hit then
		local mx, my = math.floor((ax + bx + cx) / 3), math.floor((ay + by + cy) / 3)
		if mx >= 0 and mx < UVG and my >= 0 and my < UVG then cells[my * UVG + mx] = true end
	end
end
local function UVStats(st, a, b, c)
	if not (a.u and b.u and c.u and a.v and b.v and c.v) then return end
	local area = (b.u - a.u) * (c.v - a.v) - (c.u - a.u) * (b.v - a.v)
	if area > 1e-12 then st.posA = st.posA + area * 0.5 UVRaster(st.pos, a.u, a.v, b.u, b.v, c.u, c.v)
	elseif area < -1e-12 then st.negA = st.negA - area * 0.5 UVRaster(st.neg, a.u, a.v, b.u, b.v, c.u, c.v) end
end
local function Mirrored(st)
	if not st then return false, 0 end
	local np, nn, both = 0, 0, 0
	for k in pairs(st.pos) do np = np + 1 if st.neg[k] then both = both + 1 end end
	for _ in pairs(st.neg) do nn = nn + 1 end
	local total = st.posA + st.negA
	local share = both / math.max(math.min(np, nn), 1)
	return total > 0 and st.posA > total * 0.04 and st.negA > total * 0.04 and both >= 8 and share > 0.15, share
end
E.UVRaster, E.UVStats, E.Mirrored = UVRaster, UVStats, Mirrored

function E.ModelInfo(ent)
	local mdl = ent:GetModel()
	if not mdl then return nil end
	local mi = E.modelInfo[mdl]
	-- (1.26.8) a model asked before its materials were loaded (no materials yet) is worked out again a little later: it
	-- was kept as "no blood on this model" for the rest of the game
	if mi and (mi.ok or not mi.retryAt or RealTime() < mi.retryAt) then return mi end
	mi = { subs = {}, ok = false }
	E.modelInfo[mdl] = mi
	local mats = ent:GetMaterials() or {}
	local areaByName, uvByName, windByName = {}, {}, {}
	local ok, meshes = pcall(util.GetModelMeshes, mdl, 0, 0)
	if ok and meshes then
		for _, m in ipairs(meshes) do
			local tris = m.triangles
			local area, uv = 0, 0
			local name = string.lower(m.material or "")
			local st = windByName[name]
			if not st then st = { pos = {}, neg = {}, posA = 0, negA = 0 } windByName[name] = st end
			if tris then
				for i = 1, #tris - 2, 3 do
					local a, b, c = tris[i], tris[i + 1], tris[i + 2]
					if a and b and c and a.pos and b.pos and c.pos then
						area = area + triArea(a.pos, b.pos, c.pos)
						if a.u and b.u and c.u then
							uv = uv + math.abs((b.u - a.u) * (c.v - a.v) - (c.u - a.u) * (b.v - a.v)) * 0.5
						end
						UVStats(st, a, b, c)
					end
				end
			end
			areaByName[name] = (areaByName[name] or 0) + area
			uvByName[name] = (uvByName[name] or 0) + uv
		end
	end
	for i, path in ipairs(mats) do
		local lp = string.lower(path)
		local skip = false
		for _, s in ipairs(SKIP_MAT) do if string.find(lp, s, 1, true) then skip = true break end end
		local area, uvArea, wind = areaByName[lp], uvByName[lp], windByName[lp]
		if not area then
			local file = string.match(lp, "([^/]+)$")
			for n, a in pairs(areaByName) do if string.match(n, "([^/]+)$") == file then area, uvArea, wind = a, uvByName[n], windByName[n] break end end
		end
		local imat = Material(path)
		if imat and not imat:IsError() then
			if bit.band(imat:GetInt("$flags") or 0, 2097152 + 256) ~= 0 then skip = true end
		end
		if not skip then
			local kind = "skin"
			local isFace = string.find(lp, "face", 1, true) or string.find(lp, "head", 1, true) or string.find(lp, "skin", 1, true) ~= nil
			for _, s in ipairs(CLOTH) do if string.find(lp, s, 1, true) then kind = "cloth" break end end
			for _, s in ipairs(METAL) do if string.find(lp, s, 1, true) then kind = "metal" break end end
			local sp = imat and not imat:IsError() and string.lower(imat:GetString("$surfaceprop") or "") or ""
			if string.find(sp, "metal") or string.find(sp, "armor") then kind = "metal"
			elseif string.find(sp, "cloth") or string.find(sp, "carpet") or string.find(sp, "fabric") then kind = "cloth"
			elseif string.find(sp, "flesh") then kind = kind == "metal" and "metal" or kind end
			if isFace and kind == "cloth" then kind = "skin" end
			local mirror, share = Mirrored(wind)
			table.insert(mi.subs, { index = i - 1, path = path, area = area or 0, kind = kind, face = isFace and true or false,
				uvShare = math.max(uvArea or 1, 1), mirror = mirror, mirrorShare = share })
		end
	end
	table.sort(mi.subs, function(a, b) return a.area > b.area end)
	local top = mi.subs[1] and mi.subs[1].area or 0
	for k = #mi.subs, 2, -1 do
		local s = mi.subs[k]
		if s.area < top * (s.face and 0.004 or 0.015) then table.remove(mi.subs, k) end
	end
	while #mi.subs > 4 do
		local drop = nil
		for k = #mi.subs, 1, -1 do if not mi.subs[k].face then drop = k break end end
		table.remove(mi.subs, drop or #mi.subs)
	end
	mi.ok = #mi.subs > 0
	if not mi.ok and #mats == 0 then mi.retryAt = RealTime() + 3 end
	return mi
end

local function SlotSizes() return G.Budget.BodySizes() end

local function NewSlot(size)
	E.slotCount = E.slotCount + 1
	G.Budget.Count("body", size)
	local id = E.slotCount
	local tag = "e" .. id .. "_" .. size
	local s = { id = id, size = size }
	s.st = { GPU.RT(tag .. "_stA", size, size), GPU.RT(tag .. "_stB", size, size) }
	s.ac = { GPU.RT(tag .. "_acA", size, size), GPU.RT(tag .. "_acB", size, size) }
	s.aux = { GPU.RT(tag .. "_axA", size, size), GPU.RT(tag .. "_axB", size, size) }
	s.force = GPU.RT(tag .. "_frc", size, size)
	s.pos = { GPU.RT(tag .. "_p0", size, size), GPU.RT(tag .. "_p1", size, size), GPU.RT(tag .. "_p2", size, size) }
	s.sim, s.overlay, s.forceMat, s.reduce = {}, {}, {}, {}
	for k = 1, 2 do
		s.sim[k] = GPU.Mat(tag .. "_sim" .. k, "clip_vs30", "simbody_ps30", {
			["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = s.force:GetName(), ["$texture2"] = s.ac[k]:GetName(),
			["$texture3"] = s.aux[k]:GetName(), ["$tcsize0"] = 4, ["$tcsize1"] = 4 }, true)
		s.overlay[k] = GPU.Mat(tag .. "_ov" .. k, "model_vs30", "bodyfilm_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture2"] = "vgui/white", ["$linearread_texture2"] = 1, ["$texture3"] = "vgui/white",
			["$texture4"] = s.force:GetName(), ["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1,
			["$texture6"] = s.aux[k]:GetName(), ["$texture7"] = s.ac[k]:GetName(),
			["$cull"] = 1, ["$depthtest"] = 1, ["$linearwrite"] = 1 }), true)
		s.reduce[k] = GPU.Mat(tag .. "_red" .. k, "clip_vs30", "reduce_ps30", {
			["$basetexture"] = s.ac[k]:GetName(), ["$texture1"] = s.force:GetName(), ["$texture2"] = s.pos[1]:GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
	for r = 1, 3 do
		local prev = ((r + 1) % 3) + 1
		local prev2 = (r % 3) + 1
		s.forceMat[r] = GPU.Mat(tag .. "_frc" .. r, "unwrap_vs30", "force_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = s.pos[prev]:GetName(), ["$texture1"] = s.pos[prev2]:GetName() }))
	end
	return s
end

local function Clear(rt) render.PushRenderTarget(rt) render.Clear(0, 0, 0, 0) render.PopRenderTarget() end

local function TakeSlot(size)
	E.pool[size] = E.pool[size] or {}
	local s = table.remove(E.pool[size])
	if not s then
		if not G.Budget.MayCreateBody(size) then return nil end
		-- (1.26.8) a body gets its slot at once (its first wounds would be lost otherwise), but counts towards the new
		-- slots of the frame (cl_budget.lua B.MayCreateNow: the patches wait), and E.KeepReserve keeps a few made ahead
		local t0 = SysTime()
		s = NewSlot(size)
		if G.Budget.NoteCreated then G.Budget.NoteCreated((SysTime() - t0) * 1000) end
	end
	for k = 1, 2 do Clear(s.st[k]) Clear(s.ac[k]) Clear(s.aux[k]) end
	for k = 1, 3 do Clear(s.pos[k]) end
	Clear(s.force)
	return s
end

local function FreeSlot(s)
	if not s then return end
	E.pool[s.size] = E.pool[s.size] or {}
	table.insert(E.pool[s.size], s)
end

function E.WarmSlot(big, small)
	local sz, ssz = SlotSizes()
	for _, t in ipairs({ { sz, big }, { ssz, small } }) do
		local size, want = t[1], t[2]
		if (G.Budget.made.body[size] or 0) < want and G.Budget.MayCreateBody(size) then
			FreeSlot(NewSlot(size))
			return true
		end
	end
	return false
end

-- (1.26.8) a few free slots made ahead, one at a time between frames (cl_render.lua, every 0.5 s): in a fight each body
-- that started to bleed made its slots in the middle of a frame (ghmpb_prof with the shaders: "wounds" 51 ms)
function E.KeepReserve(big, small)
	local sz, ssz = SlotSizes()
	for _, t in ipairs({ { sz, big }, { ssz, small } }) do
		local size, want = t[1], t[2]
		local free = E.pool[size] and #E.pool[size] or 0
		if free < want and G.Budget.MayCreateBody(size) then
			local t0 = SysTime()
			FreeSlot(NewSlot(size))
			if G.Budget.NoteCreated then G.Budget.NoteCreated((SysTime() - t0) * 1000) end
			return true
		end
	end
	return false
end

local function AttachSlot(sub)
	sub.slot = TakeSlot(sub.size)
	if not sub.slot then return false end
	sub.cur = 1
	sub.hasBlood = false
	for k = 1, 2 do
		local ov = sub.slot.overlay[k]
		ov:SetTexture("$texture2", sub.albedo or "vgui/white")
		ov:SetTexture("$texture3", sub.bump or "vgui/white")
	end
	for r = 1, 3 do sub.slot.forceMat[r]:SetTexture("$texture2", sub.bump or "vgui/white") end
	return true
end

local function AttachAll(d)
	for _, sub in ipairs(d.subs) do
		if not sub.slot and not AttachSlot(sub) then
			for _, s2 in ipairs(d.subs) do
				if s2.slot then FreeSlot(s2.slot) s2.slot = nil end
			end
			return false
		end
	end
	return true
end

local stampMat, noDraw, elemMat
local function Shared()
	if not stampMat then
		stampMat = GPU.Mat("estamp", "unwrap_vs30", "stamp_ps30", GPU.Merge(GPU.ModelFlags, { ["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white" }))
		elemMat = GPU.Mat("eelem", "unwrap_vs30", "elem_ps30", GPU.Merge(GPU.ModelFlags, { ["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white" }))
		noDraw = GPU.CreateMat("nodraw", "UnlitGeneric", { ["$no_draw"] = 1 })
	end
end

E.staticMats = E.staticMats or {}
local function StaticMat(sub)
	local key = sub.path .. "|" .. (sub.hand or 0)
	local m = E.staticMats[key]
	if not m then
		m = GPU.Mat("bst_" .. util.CRC(key), "model_vs30", "bodystatic_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = "vgui/white", ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture2"] = sub.albedo and sub.albedo:GetName() or "vgui/white", ["$linearread_texture2"] = 1,
			["$texture3"] = sub.bump and sub.bump:GetName() or "vgui/white",
			["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1,
			["$cull"] = 1, ["$depthtest"] = 1, ["$linearwrite"] = 1 }), true)
		E.staticMats[key] = m
	end
	return m
end

local Pressed
local function IsLive(d) for _, sub in ipairs(d.subs) do if sub.slot then return true end end return false end
local function HasAft(d) for _, sub in ipairs(d.subs) do if sub.aft then return true end end return false end
local function Weight(d) return d.gib and 0.5 or 1 end
local function CountLive() local n = 0 for _, d in pairs(E.domains) do if IsLive(d) then n = n + Weight(d) end end return n end
function E.LiveCap()
	local cap = G.Budget.Caps().ents
	if G.Gov then cap = G.Gov.LiveCap(cap) end
	return cap
end
local function IsGib(ent) return ent.ghmflGib == true or (G.Flesh and G.Flesh.gibs and G.Flesh.gibs[ent] == true) end
E.IsLive, E.HasAft = IsLive, HasAft
-- (1.26.10) where a body is, as the origin its blood's positions are kept relative to (in half floats): the entity's position,
-- but for your first-person weapon and hands a bone of the hand - a view model's own position reads as the map's origin, far
-- from it, and the positions lost their precision (stamps missed the weapon, its blood ran off)
-- (1.26.10) your first-person hands and weapon: their bones are only right while the view model is being drawn - asked for
-- them at any other time (setting the bones up for a stamp, a proxy or the blood's origin) the game set them up in the wrong
-- place for that frame and the weapon was not drawn. Their bones are read in the view model pass (E.DrawViewModel) and
-- nothing else touches them
local function IsVMEnt(ent)
	local c = ent:GetClass()
	return c == "viewmodel" or c == "gmod_hands"
end
E.IsVMEnt = IsVMEnt
-- (1.26.10c) their bones are read once, while the view model is drawn (E.VMPassBegin / RecordVMBones), and kept: their
-- stamps and forces are worked out after the frame from that copy, on a proxy of their own that is not attached to them
-- (passes into other render targets in the middle of the view model pass made the hands and the weapon flicker, and a
-- proxy bonemerged to the view model had the game set its bones up outside that pass)
E.inVM = nil
local function RecordVMBones(ent, d)
	d = d or E.domains[ent]
	if not d or not IsValid(ent) then return end
	local n = ent.GetBoneCount and ent:GetBoneCount() or 0
	local mats = d.vmBones or {}
	for i = 0, n - 1 do
		local m = ent:GetBoneMatrix(i)
		if m then
			local c = mats[i]
			if c then c:Set(m) else mats[i] = Matrix(m) end
		else
			mats[i] = nil
		end
	end
	d.vmBones, d.vmBoneN, d.vmBonesT = mats, n, CurTime()
	local b = ent:LookupBone("ValveBiped.Bip01_R_Hand") or 0
	local m = mats[b]
	d.vmOrigin = m and m:GetTranslation() or d.vmOrigin
end
E.RecordVMBones = RecordVMBones
function E.VMPassBegin(ent)
	E.inVM = ent
	if E.domains[ent] then RecordVMBones(ent) end
end
function E.VMPassEnd() E.inVM = nil end
local function Origin(ent)
	local c = ent:GetClass()
	if c == "viewmodel" or c == "gmod_hands" then
		local d = E.domains[ent]
		if E.inVM ~= ent then return d and d.vmOrigin or EyePos() end
		local b = ent:LookupBone("ValveBiped.Bip01_R_Hand") or 0
		local p = ent:GetBonePosition(b)
		if p then
			if d then d.vmOrigin = p end
			return p
		end
		return d and d.vmOrigin or EyePos()
	end
	return ent:GetPos()
end
E.Origin = Origin
-- a stamp's bone-relative position back in the world: for your hands and weapon from the bones read in the view model pass
local function ImpactToWorld(d, im)
	if IsVMEnt(d.ent) and E.inVM ~= d.ent then
		local m = d.vmBones and d.vmBones[im.bone]
		if not m then return nil end
		return LocalToWorld(im.lpos, angle_zero, m:GetTranslation(), m:GetAngles()),
			im.lnrm and LocalToWorld(im.lnrm, angle_zero, vector_origin, m:GetAngles()) or nil
	end
	return G.U.BoneToWorld(d.ent, im.bone, im.lpos, im.lnrm)
end

function E.Get(ent, create)
	local d = E.domains[ent]
	if d then
		if create and not IsLive(d) then E.Wake(d) end
		return d
	end
	if not create then return nil end
	if not G.cv.enable:GetBool() then return nil end
	if not IsValid(ent) or ent:IsWorld() or not ent:GetModel() then return nil end
	local mi = E.ModelInfo(ent)
	if not mi or not mi.ok then return nil end
	if CountLive() >= E.LiveCap() then
		if Pressed() and not E.Admit(ent, nil) then G.DiagCount("bodies: new body refused (adaptive quality)") return nil end
		E.EvictLive()
	end
	Shared()
	local big, small = SlotSizes()
	d = { ent = ent, model = ent:GetModel(), subs = {}, touched = CurTime(), wetUntil = 0, created = CurTime(),
		oxy = 0.75, btype = G.BloodTypeOf(ent) or 0, typeSet = G.BloodTypeOf(ent) ~= nil, simAcc = 0, forceAcc = 1, hist = {}, ring = 1, histN = 0,
		impacts = {}, entIndex = ent:EntIndex() }
	local propKind
	if not d.typeSet then
		local mInfo = util.GetModelInfo and util.GetModelInfo(ent:GetModel())
		propKind = mInfo and G.SurfaceKindOfProp(mInfo.SurfacePropName)
		if propKind == "water" then propKind = "sealed" elseif propKind == "grate" then propKind = "metal" end
	end
	local gib = IsGib(ent)
	d.gib = gib
	local twins = 0
	-- (1.26.10) your first-person weapon: metal (its materials read as cloth, and blood soaked into it out of sight); the gloves
	-- of the first-person hands: rubber (blood stays on them)
	local cls = ent:GetClass()
	for n, info in ipairs(mi.subs) do
		local size = (n == 1 and not gib) and big or small
		local kind = propKind or info.kind
		local lpth = string.lower(info.path or "")
		if cls == "viewmodel" and not (string.find(lpth, "hand", 1, true) or string.find(lpth, "arm", 1, true) or string.find(lpth, "skin", 1, true)) then
			kind = "metal"
		elseif cls == "gmod_hands" and kind == "cloth" and string.find(lpth, "glove", 1, true) then
			kind = "rubber"
		end
		local sub = { index = info.index, path = info.path, kind = kind, size = size, cur = 1,
			surf = G.Surface[kind] or G.Surface.skin, hasBlood = false, hand = 0 }
		local m = Material(info.path)
		local base = m and not m:IsError() and m:GetTexture("$basetexture")
		local bumpName = m and not m:IsError() and m:GetString("$bumpmap")
		local bump = bumpName and bumpName ~= "" and m:GetTexture("$bumpmap")
		sub.albedo = (base and not base:IsError()) and base or nil
		sub.bump = (bump and not bump:IsError()) and bump or nil
		d.subs[#d.subs + 1] = sub
		if info.mirror and twins < 2 and G.cv.uvmirror:GetBool() then
			twins = twins + 1
			sub.hand = 1
			local tw = { index = info.index, path = info.path, kind = kind, size = small, cur = 1, surf = sub.surf,
				hasBlood = false, hand = 2, albedo = sub.albedo, bump = sub.bump }
			d.subs[#d.subs + 1] = tw
		end
	end
	d.twins = twins > 0 or nil
	if not AttachAll(d) then
		if not d.twins then return nil end
		E.DropTwins(d)
		if not AttachAll(d) then return nil end
	end
	if not E.MakeProxy(d, ent) then
		for _, sub in ipairs(d.subs) do FreeSlot(sub.slot) end
		return nil
	end
	E.domains[ent] = d
	return d
end

function E.DropTwins(d)
	for k = #d.subs, 1, -1 do
		local sub = d.subs[k]
		if (sub.hand or 0) == 2 then
			FreeSlot(sub.slot) sub.slot = nil
			GPU.FreeAft(sub.aft) sub.aft = nil
			table.remove(d.subs, k)
		else
			sub.hand = 0
		end
	end
	d.twins = nil
	G.DiagCount("bodies: mirrored-UV twins dropped (budget)")
end

local function Passes(d) return d.twins and 2 or 1 end
local function InPass(sub, pass) return ((sub.hand or 0) == 2) == (pass == 2) end
E.Passes, E.InPass = Passes, InPass

function E.Wake(d)
	if CountLive() + Weight(d) > E.LiveCap() then
		if Pressed() then
			local p = math.max(G.Gov.p, G.Battle and G.Battle.level * 0.6 or 0)
			local hold = E.Near(d.ent) and (0.5 + 1.5 * p) or (1 + 5 * p)
			if d.bakedAt and CurTime() - d.bakedAt < hold then return false end
			if not E.Admit(d.ent, d) then return false end
		end
		E.EvictLive(d)
	end
	if not AttachAll(d) then return false end
	d.forceValid = false
	d.hist, d.histN = {}, 0
	return true
end

function E.MakeProxy(d, ent)
	if IsValid(d.proxy) then d.proxy:Remove() end
	d.proxy = ClientsideModel(ent:GetModel(), RENDERGROUP_OPAQUE)
	if not IsValid(d.proxy) then return false end
	d.proxy:SetNoDraw(true)
	d.proxy.ghmpbProxy = true
	E.AttachProxy(d, ent)
	d.forceValid = false
	return true
end

local function VMProxyBones(p, nb)
	local d = p.ghmpbDomain
	local mats = d and d.vmBones
	if not mats then return end
	for i = 0, (nb or 0) - 1 do
		local m = mats[i]
		if m then p:SetBoneMatrix(i, m) end
	end
end
-- does the proxy need (re)attaching to its body?
local function NeedsAttach(d, ent)
	if IsVMEnt(ent) then return not d.vmProxy end
	return d.proxy:GetParent() ~= ent
end
E.NeedsAttach = NeedsAttach

function E.AttachProxy(d, ent)
	local p = d.proxy
	if not IsValid(p) or not IsValid(ent) then return end
	if IsVMEnt(ent) then
		-- (your hands / weapon: a free-standing copy posed from the bones read in the view model pass)
		if IsValid(p:GetParent()) then p:SetParent(NULL) end
		p:RemoveEffects(EF_BONEMERGE)
		p.ghmpbDomain = d
		if not p.ghmpbVMCB then p.ghmpbVMCB = p:AddCallback("BuildBonePositions", VMProxyBones) end
		p:SetPos(d.vmOrigin or EyePos())
		p:SetSkin(ent:GetSkin() or 0)
		for _, bg in ipairs(ent:GetBodyGroups() or {}) do p:SetBodygroup(bg.id, ent:GetBodygroup(bg.id)) end
		d.vmProxy = true
		d.hist, d.histN = {}, 0
		return
	end
	p:SetParent(ent)
	p:AddEffects(EF_BONEMERGE)
	p:SetPos(ent:GetPos())
	p:SetAngles(ent:GetAngles())
	p:SetSkin(ent:GetSkin() or 0)
	for _, bg in ipairs(ent:GetBodyGroups() or {}) do p:SetBodygroup(bg.id, ent:GetBodygroup(bg.id)) end
	p:SetModelScale(ent:GetModelScale() or 1, 0)
	if not IsVMEnt(ent) then
		if p.InvalidateBoneCache then p:InvalidateBoneCache() end
		p:SetupBones()
	end
	d.hist, d.histN = {}, 0
end

local function FreeDomain(d)
	for _, sub in ipairs(d.subs) do
		FreeSlot(sub.slot) sub.slot = nil
		GPU.FreeAft(sub.aft) sub.aft = nil
	end
end

function E.Remove(ent)
	local d = E.domains[ent]
	if not d then return end
	FreeDomain(d)
	if IsValid(d.proxy) then d.proxy:Remove() end
	E.domains[ent] = nil
	if G.Wounds and G.Wounds.OnDomainRemoved then G.Wounds.OnDomainRemoved(ent) end
end

function E.Bake(d)
	G.Prof.Count("body bakes")
	local dryT = d.bakedAt and G.DryAge(d, G.DryMult("skin")) or 0
	for _, sub in ipairs(d.subs) do
		if sub.slot then
			if sub.hasBlood then
				sub.aft = sub.aft or GPU.TakeAft(sub.size)
				GPU.BakeInto(sub.aft, sub.slot.st[sub.cur], sub.slot.aux[sub.cur], nil, dryT, sub.slot.ac[sub.cur])
			end
			FreeSlot(sub.slot)
			sub.slot = nil
			sub.hasBlood = false
		end
	end
	d.impacts = {}
	d.bakedAt = CurTime()
	d.forceValid = false
	E.TrimAftermath()
end

local function Score(ent, d, now, eye)
	local valid = IsValid(ent)
	local s = ((d and d.wetUntil or now + 1) < now and 1000 or 0) + (valid and (IsVMEnt(ent) and 0 or Origin(ent):Distance(eye)) or 5000) * 0.1
		+ (d and (now - (d.touched or now)) or 0)
	if valid and not G.U.InView(ent, 24) then s = s + 150 end
	if (d and d.gib) or (not d and valid and IsGib(ent)) then s = s + 40 end
	return s
end

Pressed = function() return G.Gov ~= nil and (G.Gov.Pressed and G.Gov.Pressed() or G.Gov.p > 0.1) end

function E.Near(ent)
	if IsValid(ent) and IsVMEnt(ent) then return true end
	return IsValid(ent) and Origin(ent):DistToSqr(EyePos()) < 450 * 450 and G.U.InView(ent, 24)
end

function E.Admit(ent, d)
	local eye, now = EyePos(), CurTime()
	local mine = Score(ent, d, now, eye) - ((d and d.wetUntil < now) and 1000 or 0)
	local margin = 20 + 30 * (G.Gov and G.Gov.p or 0)
	for e2, d2 in pairs(E.domains) do
		if d2 ~= d and IsLive(d2) and Score(e2, d2, now, eye) > mine + margin then return true end
	end
	return false
end

function E.EvictLive(keep)
	if E.pendingBake and next(E.pendingBake) then return end
	local worst, ws = nil, -math.huge
	local eye = EyePos()
	local now = CurTime()
	for ent, d in pairs(E.domains) do
		if d ~= keep and IsLive(d) then
			local score = Score(ent, d, now, eye)
			if score > ws then worst, ws = ent, score end
		end
	end
	if not worst then return end
	if G.cv.aftermath:GetBool() then E.pendingBake = E.pendingBake or {} E.pendingBake[worst] = true
	else E.Remove(worst) end
end

function E.TrimAftermath()
	local list = {}
	for ent, d in pairs(E.domains) do if HasAft(d) and not IsLive(d) then list[#list + 1] = { ent, d } end end
	local cap = G.Budget.Caps().aftb
	if #list <= cap then return end
	local eye = EyePos()
	table.sort(list, function(a, b)
		local da = IsValid(a[1]) and a[1]:GetPos():DistToSqr(eye) or 1e12
		local db = IsValid(b[1]) and b[1]:GetPos():DistToSqr(eye) or 1e12
		return da + (CurTime() - (a[2].bakedAt or 0)) * 1e3 > db + (CurTime() - (b[2].bakedAt or 0)) * 1e3
	end)
	for k = 1, #list - cap do E.Remove(list[k][1]) end
end

function E.Transfer(from, to, living)
	local d = E.domains[from]
	if not d or not IsValid(to) then return false end
	if to:GetModel() ~= d.model then return false end
	if E.domains[to] and E.domains[to] ~= d then E.Remove(to) end
	E.domains[from] = nil
	d.ent = to
	d.entIndex = to:EntIndex()
	d.orphan = nil
	d.forceValid = false
	E.domains[to] = d
	E.AttachProxy(d, to)
	if G.Wounds and G.Wounds.OnTransfer then G.Wounds.OnTransfer(from, to, living) end
	return true
end

E.pendingClone = E.pendingClone or {}
function E.Clone(from, to)
	if not E.domains[from] or not IsValid(to) then return false end
	E.pendingClone[to] = from
	return true
end
local function CloneNow(from, to)
	local src = E.domains[from]
	if not src or not IsValid(to) or to:GetModel() ~= src.model then return false end
	local d = E.Get(to, true)
	if not d then return false end
	d.oxy, d.btype, d.typeSet, d.btypeB = src.oxy, src.btype, src.typeSet, src.btypeB
	d.dust = src.dust and table.Copy(src.dust) or nil
	d.wet = src.wet and table.Copy(src.wet) or nil
	d.wetF = src.wetF and table.Copy(src.wetF) or nil
	d.wetUntil = math.max(d.wetUntil, src.wetUntil or 0)
	d.bakedAt = src.bakedAt
	d.dryBase, d.dryAt, d.dryAge = src.dryBase, src.dryAt, src.dryAge
	d.touched = CurTime()
	for i, sub in ipairs(d.subs) do
		local ss = src.subs[i]
		if ss and ss.index == sub.index and (ss.hand or 0) == (sub.hand or 0) then
			if ss.slot and sub.slot then
				for k = 1, 2 do
					GPU.Copy(sub.slot.st[k], ss.slot.st[ss.cur])
					GPU.Copy(sub.slot.aux[k], ss.slot.aux[ss.cur])
				end
				sub.hasBlood = ss.hasBlood
			end
			if ss.aft then
				sub.aft = sub.aft or GPU.TakeAft(ss.aft.res)
				GPU.Copy(sub.aft.rt, ss.aft.rt)
				sub.aft.used = true
			end
		end
	end
	d.forceValid = false
	return true
end

local function BodyAlt(d, t)
	if t == nil then return false end
	if not d.typeSet then d.btype, d.typeSet = t, true return false end
	if t == d.btype then return false end
	d.btypeB = d.btypeB or t
	return true
end
function E.PairCode(d) return d.btype + 8 * (d.btypeB or d.btype) end
function E.LookPair(d) return E.PairCode(d) + 64 * math.floor(math.Clamp(G.cv.poollook:GetFloat(), 0, 2) * 10 + 0.5) end

function E.Impact(ent, pos, normal, vel, radiusU, volume, kind, spin, stretch, residue, bone, extra)
	if IsValid(ent) and not ent:IsRagdoll() and G.Render and G.Render.Redirect then
		ent = G.Render.Redirect(ent)
	end
	local d = E.Get(ent, true)
	if not d then return false end
	if (kind or 0) == 0 and vel and normal and G.U and G.U.SplatShape then vel, stretch = G.U.SplatShape(vel, normal, stretch) end
	local list = d.impacts
	local nI = #list
	kind = kind or 0
	if nI > 0 and pos and (kind == 0 or kind == 1) then
		local mr = 0.5 + 2.0 * math.max(G.Gov and G.Gov.p or 0, (G.Battle and G.Battle.level or 0) * 0.55)
		local px, py, pz = pos.x, pos.y, pos.z
		local bt = extra and extra.btype
		for i = nI, math.max(1, nI - 7), -1 do
			local im = list[i]
			if im.rx and im.kind == kind and im.bt == bt then
				local dx, dy, dz = im.rx - px, im.ry - py, im.rz - pz
				local rr = mr + 0.5 * math.min(im.radius or 0, radiusU or 0)
				if dx * dx + dy * dy + dz * dz < rr * rr then
					local v0, v1 = im.volume or 0, volume or 0
					if v1 > 0 then
						im.oxy = ((im.oxy or 0.75) * v0 + ((extra and extra.oxy) or d.oxy or 0.75) * v1) / (v0 + v1)
						im.volume = v0 + v1
						im.radius = ((im.radius or 0) ^ 3 + (radiusU or 0) ^ 3) ^ (1 / 3)
					end
					d.touched = CurTime()
					if G.Smear then G.Smear.AddWet(d, ent, im.bone, pos, volume, im.alt) end
					if G.Props and G.Props.OnImpact then G.Props.OnImpact(ent, pos, normal, volume, kind, bt, extra and extra.props) end
					G.Prof.Count("body impacts merged")
					return true
				end
			end
		end
	end
	if not bone and pos then bone = G.U.NearestBone(ent, pos) end
	local alt = BodyAlt(d, extra and extra.btype)
	if G.Smear then G.Smear.AddWet(d, ent, bone, pos, volume, alt) end
	if G.Props and G.Props.OnImpact then G.Props.OnImpact(ent, pos, normal, volume, kind, extra and extra.btype, extra and extra.props) end
	local pos0 = pos
	pos, normal, bone = G.U.SnapToMesh(ent, pos, normal, bone)
	local lpos, lnrm
	if bone and pos and G.U.BoneToLocal then
		lpos, lnrm = G.U.BoneToLocal(ent, bone, pos, normal)
	end
	d.touched = CurTime()
	d.wetUntil = math.max(d.wetUntil, CurTime() + G.DryTime() / G.DryMult("skin") * 1.3 + 5)
	if #d.impacts < 256 then
		local rawX, rawY, rawZ
		if pos0 then rawX, rawY, rawZ = pos0.x, pos0.y, pos0.z end
		d.impacts[#d.impacts + 1] = { wpos = pos, normal = normal, lpos = lpos, lnrm = lnrm, vel = vel, radius = radiusU, volume = volume,
			kind = kind or 0, spin = spin or 0, stretch = stretch or 1, residue = residue or 0.2, seed = math.random(),
			spines = extra and extra.spines, K = extra and extra.K, flags = extra and extra.flags, alt = alt,
			oxy = extra and extra.oxy or d.oxy, rx = rawX, ry = rawY, rz = rawZ, bone = bone, bt = extra and extra.btype }
	end
	return true
end

function E.Element(ent, pos, R, op, k, path, vol, btype)
	local d = E.domains[ent]
	if not d or not IsLive(d) or #d.impacts >= 250 then return false end
	if op == 14 then
		d.impacts[#d.impacts + 1] = { wpos = Vector(pos), normal = Vector(0, 0, 1), vel = Vector(0, 0, 0), radius = R, volume = 0,
			kind = 4, spin = op, stretch = math.Clamp(k, 0, 1), residue = 0, seed = math.random(), alt = false, oxy = d.oxy }
		return true
	end
	local bone = G.U.NearestBone(ent, pos)
	local p2, n2, b2 = G.U.SnapToMesh(ent, pos, nil, bone)
	bone = b2 or bone
	if not n2 then n2 = (pos - ent:WorldSpaceCenter()):GetNormalized() end
	local lpos, lnrm = G.U.BoneToLocal and G.U.BoneToLocal(ent, bone, p2, n2)
	local alt = false
	if op == 12 and (vol or 0) > 0 then alt = BodyAlt(d, btype or G.ACID_TYPE) end
	d.impacts[#d.impacts + 1] = { wpos = p2, normal = n2, lpos = lpos, lnrm = lnrm, vel = path or Vector(0, 0, 0), radius = R, volume = vol or 0,
		kind = 4, spin = op, stretch = math.Clamp(k, 0, 1), residue = 0, seed = math.random(), alt = alt, oxy = d.oxy, bone = bone }
	d.touched = CurTime()
	d.wetUntil = math.max(d.wetUntil, CurTime() + 6)
	return true
end

local function MatCount(d, ent)
	ent = ent or d.ent
	local m = ent:GetModel()
	if d.nMatsModel ~= m then d.nMatsModel, d.nMats = m, #(ent:GetMaterials() or {}) end
	return d.nMats
end

local function PrepProxy(d)
	local ent, p = d.ent, d.proxy
	if not IsValid(ent) or not IsValid(p) then return end
	-- (1.26.6) only make sure the ragdoll's bones are current. Moving and re-setting up the bonemerged proxy here fought
	-- the engine's bonemerge, and blood on ragdolls flickered or vanished.
	if IsVMEnt(ent) then
		if d.vmOrigin then p:SetPos(d.vmOrigin) end
		if p.InvalidateBoneCache then p:InvalidateBoneCache() end
		p:SetupBones()
		return
	end
	if G.U.EnsureBones then G.U.EnsureBones(ent) end
end

local function DrawProxySub(d, subIndex, mat)
	local p = d.proxy
	local n = MatCount(d)
	for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, i == subIndex and mat or noDraw) end
	p:DrawModel()
	render.MaterialOverrideByIndex()
end
E.DrawProxySub, E.MatCount = DrawProxySub, MatCount
function E.NoDraw() Shared() return noDraw end

local function StampPass(d)
	local all = d.impacts
	if #all == 0 then return end
	d.impacts = {}
	PrepProxy(d)
	local origin = Origin(d.ent)
	local list, elist = {}, nil
	local ox, oy, oz = origin.x, origin.y, origin.z
	for _, im in ipairs(all) do
		if im.bone and im.lpos and G.U.BoneToWorld then
			local wp, wn = ImpactToWorld(d, im)
			if wp then
				im.wpos = wp
				if wn then im.normal = wn end
			end
		end
		local w = im.wpos
		im.px, im.py, im.pz = w.x - ox, w.y - oy, w.z - oz
		if im.kind == 4 and (im.spin or 0) >= 10 then elist = elist or {} elist[#elist + 1] = im else list[#list + 1] = im end
	end
	local mat = stampMat
	if #list == 0 and elist then list, elist, mat = elist, nil, elemMat end
	local first = 1
	while first <= #list do
		local n = math.min(GPU.IMPACT_COLS, #list - first + 1)
		GPU.UploadImpacts(list, first, n)
		GPU.SetC(mat, 0, n, origin.x, origin.y, origin.z)
		GPU.SetC(mat, 1, 1 / GPU.IMPACT_COLS, 1 / 4, CurTime(), 1)
		for _, sub in ipairs(d.subs) do
			if sub.slot then
				GPU.SetC(mat, 2, 3.5, 0.05, 0, sub.hand or 0)
				GPU.SetC(mat, 3, sub.surf.rough or 0.35, sub.surf.fabric or 0, 1 / sub.size, 1)
				mat:SetTexture("$texture1", sub.slot.st[3 - sub.cur])
				render.PushRenderTarget(sub.slot.st[sub.cur])
				render.SetRenderTargetEx(1, sub.slot.aux[sub.cur])
				render.SetRenderTargetEx(2, sub.slot.ac[sub.cur])
				GPU.Additive(true)
				render.OverrideAlphaWriteEnable(true, true)
				G.Prof.Count("body stamp draws")
				DrawProxySub(d, sub.index, mat)
				render.OverrideAlphaWriteEnable(false)
				GPU.Additive(false)
				render.SetRenderTargetEx(2, nil)
				render.SetRenderTargetEx(1, nil)
				render.PopRenderTarget()
				sub.hasBlood = true
			end
		end
		first = first + n
		if first > #list and elist then list, elist, mat, first = elist, nil, elemMat, 1 end
	end
end

local function ForcePass(d, now)
	PrepProxy(d)
	local h = d.hist
	local ring = d.ring
	local origin = Origin(d.ent)
	local g = -(GetConVarNumber("sv_gravity") or 600) * G.UNITS_TO_CM
	local t1, t2 = h[1], h[2]
	local dt1 = t1 and (now - t1.t) or 0.05
	local dt2 = (t1 and t2) and (t1.t - t2.t) or 0.05
	local level = (t1 and t2 and dt1 < 0.5 and dt2 < 0.5) and 2 or 0
	for _, sub in ipairs(d.subs) do
		local s = sub.slot
		if s then
			local mat = s.forceMat[ring]
			GPU.SetC(mat, 0, 0, 0, g, dt1)
			GPU.SetC(mat, 1, origin.x, origin.y, origin.z, dt2)
			local o1 = t1 and t1.o or origin
			local o2 = t2 and t2.o or origin
			GPU.SetC(mat, 2, o1.x, o1.y, o1.z, level)
			GPU.SetC(mat, 3, o2.x, o2.y, o2.z, math.Clamp(G.cv.motion:GetFloat(), 0, 1) + 4 * (sub.hand or 0))
			render.PushRenderTarget(s.force)
			render.Clear(0, 0, 0, 0)
			render.SetRenderTargetEx(1, s.pos[ring])
			render.Clear(0, 0, 0, 0)
			render.OverrideAlphaWriteEnable(true, true)
			G.Prof.Count("body force draws")
			DrawProxySub(d, sub.index, mat)
			render.OverrideAlphaWriteEnable(false)
			render.SetRenderTargetEx(1, nil)
			render.PopRenderTarget()
			sub.lastPos = ring
		end
	end
	table.insert(h, 1, { t = now, o = origin })
	h[3] = nil
	d.ring = (ring % 3) + 1
	d.forceValid = true
end

local function SimPass(d, dt)
	for _, sub in ipairs(d.subs) do
		if sub.slot and sub.hasBlood then
			local s = sub.slot
			local src, dst = sub.cur, 3 - sub.cur
			local mat = s.sim[src]
			mat:SetTexture("$texture4", s.pos[sub.lastPos or 1])
			local wz = G.Water and G.Water.EntityWaterZ(d.ent)
			GPU.SimParams(mat, sub.surf, s.size, dt, 0, nil, nil, nil, { 2, 0, 0, 0 }, nil, wz and { wz - d.ent:GetPos().z } or nil, d.el)
			render.PushRenderTarget(s.st[dst])
			render.SetRenderTargetEx(1, s.ac[dst])
			render.SetRenderTargetEx(2, s.aux[dst])
			render.SetMaterial(mat)
			GPU.FullQuad(s.size, s.size, { 0, 0, 0, 0 })
			G.Prof.Count("body sim steps")
			render.SetRenderTargetEx(2, nil)
			render.SetRenderTargetEx(1, nil)
			render.PopRenderTarget()
			sub.cur = dst
		end
	end
end

function E.Update(frameDt)
	if not G.cv.enable:GetBool() then return end
	Shared()
	local now = CurTime()
	local hz = G.cv.simhz:GetFloat()
	local step = 1 / hz
	local eye = EyePos()
	local settle0 = G.SettleTime()
	local aftermath = G.cv.aftermath:GetBool()
	if aftermath and CountLive() > E.LiveCap() then E.EvictLive() end
	if next(E.pendingClone) ~= nil then
		local list = E.pendingClone
		E.pendingClone = {}
		for to, from in pairs(list) do
			local ok, err = pcall(CloneNow, from, to)
			if not ok then ErrorNoHalt("[GHMPB] clone: " .. tostring(err) .. "\n") end
		end
	end
	if E.pendingBake then
		for ent in pairs(E.pendingBake) do local d = E.domains[ent] if d and IsLive(d) then E.Bake(d) end end
		E.pendingBake = nil
	end
	for ent, d in pairs(E.domains) do
		if IsValid(ent) and not ent:IsRagdoll() and G.Render and G.Render.Redirect then
			local rag = G.Render.Redirect(ent, d.entIndex)
			if IsValid(rag) and rag ~= ent then
				G.Render.Transfer(ent, rag, G.LivingRagdoll(rag), d.entIndex)
				ent = rag
			end
		end
		if not IsValid(ent) then
			d.orphan = d.orphan or now
			if now - d.orphan > 1.5 then E.Remove(ent) end
		elseif not IsValid(d.proxy) and not E.MakeProxy(d, ent) then
			E.Remove(ent)
		elseif IsLive(d) then
			G.Prof.Count("bodies live")
			if NeedsAttach(d, ent) then E.AttachProxy(d, ent) end
			local vm = IsVMEnt(ent)
			local dist = vm and 0 or Origin(ent):Distance(eye)
			local active = now < d.wetUntil
			local seen = G.U.InView(ent, 24)
			local c = ent:WorldSpaceCenter()
			if d.lastC then
				local sp = math.sqrt(c:DistToSqr(d.lastC)) / math.max(frameDt, 1e-3)
				if sp > 3 then d.movedAt = now end
			else
				d.movedAt = now
			end
			d.lastC = c
			local rest = now - (d.movedAt or now)
			local quiet = now - (d.touched or now)
			-- (your hands / weapon: here too, after the frame, from the bones read when they were last drawn - see RecordVMBones;
			-- E.vmPassesInPass = true does them in the view model pass instead, as test 10 did)
			local passes = not vm or (not E.vmPassesInPass and d.vmBones ~= nil and now - (d.vmBonesT or -1) < 0.25)
			if #d.impacts > 0 and passes then
				if not d.forceValid then ForcePass(d, now) end
				StampPass(d)
				if vm then E.vmAfterPasses = (E.vmAfterPasses or 0) + 1 end
			end
			if active then
				local fRate = dist < 1200 and 15 or 5
				if rest > 2 then fRate = 0.5 end
				if not seen then fRate = math.min(fRate, 3) end
				if G.Gov then fRate = G.Gov.BodyForceHz(fRate, dist, seen) end
				if frameDt > 0.05 then fRate = math.min(fRate, 0.5 / frameDt) end
				d.forceAcc = d.forceAcc + frameDt
				if passes and (d.forceAcc >= 1 / fRate or not d.forceValid) then
					d.forceAcc = 0
					ForcePass(d, now)
					if vm then E.vmAfterPasses = (E.vmAfterPasses or 0) + 1 end
				end
				local simHz = dist < 1500 and hz or math.min(hz, 10)
				if rest > 3 and quiet > 8 then simHz = simHz / (quiet > 20 and 3 or 2) end
				if not seen then simHz = math.min(simHz, 10) end
				if G.Gov then simHz = G.Gov.BodySimHz(simHz, dist, seen, d) end
				local sstep = 1 / simHz
				d.simAcc = math.min(d.simAcc + frameDt, math.max(step * 3, sstep * 1.5))
				if frameDt > sstep * 1.25 and d.simAcc >= sstep then
					local long = math.min(d.simAcc, math.max(sstep, math.min(sstep * 2.5, 0.12)))
					SimPass(d, long)
					d.simAcc = math.max(d.simAcc - long, 0)
				else
					local n = 0
					while d.simAcc >= sstep and n < 2 do
						SimPass(d, sstep)
						d.simAcc = d.simAcc - sstep
						n = n + 1
					end
				end
			end
			local settle = settle0
			if G.Gov then settle = math.max(settle * G.Gov.SettleMul(dist, seen), 8) end
			local bleeding = G.Wounds and G.Wounds.IsBleeding and G.Wounds.IsBleeding(ent)
			if aftermath and not vm and not bleeding and #d.impacts == 0 and now - d.touched > (rest > 3 and settle or settle * 2) then
				E.Bake(d)
			end
		elseif NeedsAttach(d, ent) then
			E.AttachProxy(d, ent)
		end
	end
end

E.readbackIndex = E.readbackIndex or {}
function E.Reduce(tiles)
	for ent, d in pairs(E.domains) do
		if IsValid(ent) and CurTime() < d.wetUntil and d.forceValid then
			local mn, mx = ent:GetRenderBounds()
			local scale = ent:GetModelScale() or 1
			mn = mn * scale - Vector(24, 24, 24) mx = mx * scale + Vector(24, 24, 24)
			local r = math.max(mx:Length(), mn:Length())
			local bmin = Vector(-r, -r, -r)
			local bsize = Vector(2 * r, 2 * r, 2 * r)
			local origin = d.hist[1] and d.hist[1].o or ent:GetPos()
			for _, sub in ipairs(d.subs) do
				if sub.slot and sub.hasBlood and #tiles < 240 then
					local s = sub.slot
					local mat = s.reduce[sub.cur]
					mat:SetTexture("$texture2", s.pos[sub.lastPos or 1])
					local bs = s.size / GPU.TILE
					GPU.SetC(mat, 0, 1 / s.size, 1 / s.size, bs, 0)
					GPU.SetC(mat, 1, bmin.x, bmin.y, bmin.z, 2500)
					GPU.SetC(mat, 2, bsize.x, bsize.y, bsize.z, 0)
					local index = #tiles
					local x0, y0 = GPU.TileOrigin(index)
					render.SetMaterial(mat)
					GPU.Quads(GPU.READBACK, GPU.READBACK, { { x0, y0, x0 + GPU.TILE, y0 + GPU.TILE,
						function(ci) local c = ({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } })[ci] return { c[1], c[2], 0, 0 } end } })
					tiles[#tiles + 1] = { kind = "entity", ent = ent, d = d, sub = sub, x0 = x0, y0 = y0, origin = origin,
						bmin = bmin, bsize = bsize, volNorm = 2500 }
				end
			end
		end
	end
end

-- (1.26.10) your first-person hands and weapon have blood of their own (cl_screen.lua); they are drawn in the view model pass
-- (E.DrawViewModel), never with the world
local function IsViewModel(ent)
	local c = ent:GetClass()
	return c == "viewmodel" or c == "gmod_hands"
end
E.IsViewModel = IsViewModel
local function Visible(ent, eye)
	return IsValid(ent) and not ent:IsDormant() and not ent:GetNoDraw() and ent:GetPos():DistToSqr(eye) < 6000 * 6000
		and not IsViewModel(ent)
		and not (ent == LocalPlayer() and not ent:ShouldDrawLocalPlayer())
		and G.U.InView(ent)
		and (not G.refractionView or (G.Water and G.Water.EntityWaterZ(ent) ~= nil))
end

local function Smooth() return G.cv.smooth:GetInt() end
E.Visible = Visible

-- (1.26.6) any body with live blood to draw
function E.HasLive()
	for _, d in pairs(E.domains) do
		for _, sub in ipairs(d.subs or {}) do if sub.slot and sub.hasBlood then return true end end
	end
	return false
end

function E.HasStatic()
	for _, d in pairs(E.domains) do if HasAft(d) then return true end end
	return false
end

function E.DrawStatic()
	if not G.cv.enable:GetBool() then return end
	local sw, sh = G.ViewSize()
	local now = CurTime()
	local eye = EyePos()
	local normalDepth = G.cv.normaldepth:GetFloat()
	local absorb = G.BloodAbsorb()
	local gloss = G.cv.gloss:GetFloat()
	local dry = G.DryTime()
	for ent, d in pairs(E.domains) do
		if IsValid(d.proxy) and Visible(ent, eye) and HasAft(d) then
			if NeedsAttach(d, ent) then E.AttachProxy(d, ent) end
			PrepProxy(d)
			Shared()
			local light = G.Light.Get(ent, ent:WorldSpaceCenter())
			local probe = G.Probes and G.Probes.TexAt(ent:WorldSpaceCenter())
			local n = MatCount(d, ent)
			local dAge = d.bakedAt and G.DryAge(d, G.DryMult("skin")) or 0
			local lw = GPU.LayerWord(1, dAge)
			-- (1.26.6) own colours for red blood only; baked (old) body blood darkens and loses gloss and shine as it ages
			local dF = d.bakedAt and G.AgeFrac(now - d.bakedAt + 30) or 0
			local dAbs = G.AbsorbAged(d.btype or 0, dF)
			local dShine = G.ShineAged(dF, dAge)
			local dGloss = math.min(gloss, 1) + (gloss - math.min(gloss, 1)) * dShine
			for pass = 1, Passes(d) do
				local drew = false
				for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
				for _, sub in ipairs(d.subs) do
					if sub.aft and InPass(sub, pass) then
						local mat = StaticMat(sub)
						mat:SetTexture("$basetexture", sub.aft.rt)
						GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / sub.size, now)
						GPU.SetC(mat, 1, d.oxy, E.LookPair(d), GPU.PackZW(normalDepth, sub.surf.fabric or 0, d.btype or 0))
						G.Light.Apply(mat, light, sub.surf.rough, (sub.bump and 1 or 0) + 4 * (sub.hand or 0), lw, d.el and G.Elem and G.Elem.Word(d.el, true) or 0, dShine)
						G.Light.ApplySH4(mat, light, dAbs, 1, dGloss, Smooth() + 4 * G.cv.dbgview:GetInt())
						if probe then G.Probes.Bind(mat, probe) end
						render.MaterialOverrideByIndex(sub.index, mat)
						drew = true
					end
				end
				if drew then d.proxy:DrawModel() end
				render.MaterialOverrideByIndex()
			end
		end
	end
end

function E.DrawOverlays()
	if not G.cv.enable:GetBool() then return end
	local sw, sh = G.ViewSize()
	local now = CurTime()
	local eye = EyePos()
	local normalDepth = G.cv.normaldepth:GetFloat()
	local absorb = G.BloodAbsorb()
	local gloss = G.cv.gloss:GetFloat()
	local dv = G.cv.dbgview:GetInt()
	local mode = ((G.cv.debug:GetInt() == 3 and 1 or (dv >= 2 and dv or 0)) * 4) + Smooth()
	for ent, d in pairs(E.domains) do
		if IsValid(d.proxy) and Visible(ent, eye) then
			local any = false
			for _, sub in ipairs(d.subs) do if sub.slot and sub.hasBlood then any = true break end end
			if any then
				if NeedsAttach(d, ent) then E.AttachProxy(d, ent) end
				PrepProxy(d)
				Shared()
				local light = G.Light.Get(ent, ent:WorldSpaceCenter())
				local probe = G.Probes and G.Probes.TexAt(ent:WorldSpaceCenter())
				local n = MatCount(d, ent)
				for pass = 1, Passes(d) do
					local drew = false
					for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
					for _, sub in ipairs(d.subs) do
						if sub.slot and sub.hasBlood and InPass(sub, pass) then
							local mat = sub.slot.overlay[sub.cur]
							GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / sub.size, now)
							GPU.SetC(mat, 1, d.oxy, E.LookPair(d), GPU.PackZW(normalDepth, sub.surf.fabric or 0, d.btype or 0))
							G.Light.Apply(mat, light, sub.surf.rough, (sub.bump and 1 or 0) + 4 * (sub.hand or 0), 0.999, d.el and G.Elem and G.Elem.Word(d.el, true) or 0)
							G.Light.ApplySH4(mat, light, (d.btype or 0) == 0 and absorb or G.BloodAbsorbFor(d.btype), 1, gloss, mode)
							if probe then G.Probes.Bind(mat, probe) end
							render.MaterialOverrideByIndex(sub.index, mat)
							drew = true
						end
					end
					if drew then
						d.proxy:DrawModel()
						G.Prof.Count("body overlay draws")
					end
					render.MaterialOverrideByIndex()
				end
			end
		end
	end
end

-- (1.26.10) the blood on your first-person hands or weapon (cl_screen.lua), drawn in the view model pass right after them
-- (PostDrawViewModel / PostDrawPlayerHands): the baked layer, then the live one, as E.DrawStatic / E.DrawOverlays do for
-- the bodies in the world - over the entity itself (a bonemerged proxy does not follow a view model)
-- (the frame as it is with the view model drawn: render.UpdateScreenEffectTexture here handed back the copy made earlier in the
-- frame, without the weapon, and the blood shader then painted the background over the weapon wherever it had blood - the
-- weapon vanished. A copy of our own, made right here)
local vmFB, vmFBW, vmFBH
local function ViewModelFrame()
	local w, h = ScrW(), ScrH()
	if not vmFB or vmFBW ~= w or vmFBH ~= h then
		vmFB = GPU.RT("vmfb_" .. w .. "x" .. h, w, h, GPU.FMT_RGBA8)
		vmFBW, vmFBH = w, h
	end
	render.CopyRenderTargetToTexture(vmFB)
	return vmFB
end
local function WithFrame(mat, tex)
	local old = mat:GetTexture("$texture1")
	mat:SetTexture("$texture1", tex)
	return old
end

function E.DrawViewModel(ent)
	local d = E.domains[ent]
	if not d or not IsValid(ent) or not G.cv.enable:GetBool() then return end
	if ent:GetModel() ~= d.model then E.Remove(ent) return end
	RecordVMBones(ent, d)
	-- (its stamps and forces: after the frame (E.Update), unless E.vmPassesInPass - then here, as in test 10)
	local now0 = CurTime()
	if E.vmPassesInPass and IsValid(d.proxy) and IsLive(d) then
		E.vmInPasses = (E.vmInPasses or 0) + 1
		if #d.impacts > 0 then
			if not d.forceValid then ForcePass(d, now0) end
			StampPass(d)
		end
		if now0 < d.wetUntil and (not d.forceValid or now0 - (d.vmForceT or 0) > 1 / 15) then
			d.vmForceT = now0
			ForcePass(d, now0)
		end
	end
	local live, aft = false, HasAft(d)
	for _, sub in ipairs(d.subs) do if sub.slot and sub.hasBlood then live = true break end end
	-- (what was drawn, for the debug view and the in-game test)
	E.vmDiag = E.vmDiag or {}
	local dg = E.vmDiag[ent] or { calls = 0, drew = 0 }
	E.vmDiag[ent] = dg
	dg.calls, dg.live, dg.aft, dg.t = dg.calls + 1, live, aft, CurTime()
	if not live and not aft then return end
	dg.drew = dg.drew + 1
	Shared()
	local fbTex = ViewModelFrame()
	local restore = {}
	local sw, sh = G.ViewSize()
	local now = CurTime()
	local normalDepth = G.cv.normaldepth:GetFloat()
	local absorb = G.BloodAbsorb()
	local gloss = G.cv.gloss:GetFloat()
	local light = G.Light.Get(ent, ent:WorldSpaceCenter())
	local probe = G.Probes and G.Probes.TexAt(ent:WorldSpaceCenter())
	local n = MatCount(d, ent)
	if aft then
		local dAge = d.bakedAt and G.DryAge(d, G.DryMult("skin")) or 0
		local lw = GPU.LayerWord(1, dAge)
		local dF = d.bakedAt and G.AgeFrac(now - d.bakedAt + 30) or 0
		local dAbs = G.AbsorbAged(d.btype or 0, dF)
		local dShine = G.ShineAged(dF, dAge)
		local dGloss = math.min(gloss, 1) + (gloss - math.min(gloss, 1)) * dShine
		for pass = 1, Passes(d) do
			local drew = false
			for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
			for _, sub in ipairs(d.subs) do
				if sub.aft and InPass(sub, pass) then
					local mat = StaticMat(sub)
					mat:SetTexture("$basetexture", sub.aft.rt)
					if restore[mat] == nil then restore[mat] = WithFrame(mat, fbTex) or false end
					GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / sub.size, now)
					GPU.SetC(mat, 1, d.oxy, E.LookPair(d), GPU.PackZW(normalDepth, sub.surf.fabric or 0, d.btype or 0))
					G.Light.Apply(mat, light, sub.surf.rough, (sub.bump and 1 or 0) + 4 * (sub.hand or 0), lw, d.el and G.Elem and G.Elem.Word(d.el, true) or 0, dShine)
					G.Light.ApplySH4(mat, light, dAbs, 1, dGloss, Smooth() + 4 * G.cv.dbgview:GetInt())
					if probe then G.Probes.Bind(mat, probe) end
					render.MaterialOverrideByIndex(sub.index, mat)
					drew = true
				end
			end
			if drew then ent:DrawModel() end
			render.MaterialOverrideByIndex()
		end
	end
	if live then
		local dv = G.cv.dbgview:GetInt()
		local mode = ((G.cv.debug:GetInt() == 3 and 1 or (dv >= 2 and dv or 0)) * 4) + Smooth()
		for pass = 1, Passes(d) do
			local drew = false
			for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
			for _, sub in ipairs(d.subs) do
				if sub.slot and sub.hasBlood and InPass(sub, pass) then
					local mat = sub.slot.overlay[sub.cur]
					if restore[mat] == nil then restore[mat] = WithFrame(mat, fbTex) or false end
					GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / sub.size, now)
					GPU.SetC(mat, 1, d.oxy, E.LookPair(d), GPU.PackZW(normalDepth, sub.surf.fabric or 0, d.btype or 0))
					G.Light.Apply(mat, light, sub.surf.rough, (sub.bump and 1 or 0) + 4 * (sub.hand or 0), 0.999, d.el and G.Elem and G.Elem.Word(d.el, true) or 0)
					G.Light.ApplySH4(mat, light, (d.btype or 0) == 0 and absorb or G.BloodAbsorbFor(d.btype), 1, gloss, mode)
					if probe then G.Probes.Bind(mat, probe) end
					render.MaterialOverrideByIndex(sub.index, mat)
					drew = true
				end
			end
			if drew then
				ent:DrawModel()
				G.Prof.Count("view model blood draws")
			end
			render.MaterialOverrideByIndex()
		end
	end
	-- (the materials are shared: back to the frame copy the bodies in the world use)
	for mat, old in pairs(restore) do
		if old then mat:SetTexture("$texture1", old) else mat:SetTexture("$texture1", "_rt_FullFrameFB") end
	end
end

E.RawDrawStatic, E.RawDrawOverlays = E.DrawStatic, E.DrawOverlays
E.ghmflWrapped = nil

function E.Clear()
	for ent in pairs(E.domains) do E.Remove(ent) end
end

function E.ClearAftermath()
	for ent, d in pairs(E.domains) do
		for _, sub in ipairs(d.subs) do GPU.FreeAft(sub.aft) sub.aft = nil end
		if not IsLive(d) then E.Remove(ent) end
	end
end
