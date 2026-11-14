-- GHM PhysBlood (1.26.10): bullet holes on bodies.
-- Each bullet that goes into a body leaves an entry hole where it went in and, when it went through, an exit hole where
-- it came out. A hole is kept on the bone under it (it moves with the body, and goes over to the ragdoll an NPC turns
-- into) and drawn by hole_ps30: the body is drawn again over itself, and every pixel near a hole is shaded from the lit
-- frame under it - the funnel going dark down the channel, the torn rim, the abrasion collar and the bruise of an entry;
-- the bigger, star-torn exit with its everted margin. Modelled on GHM FLESH's bullet holes (a light version: painted,
-- no geometry). Drawn before the body's blood, so the blood runs over them.
-- GHM FLESH draws its own (much fuller) wounds: while it is on, PhysBlood draws and records no holes, and nothing here
-- touches what GHM FLESH hooks into (Entities.DrawStatic / DrawOverlays, Particles, Prof).
local G = GHMPB
G.Holes = G.Holes or {}
local H = G.Holes
local GPU = G.GPU
local U = G.U

H.bodies = H.bodies or {}       -- ent -> { holes = { ... }, model = path, t = last hit }
H.PER_BODY = 20                 -- holes a body keeps (the oldest goes)
H.MAX_BODIES = 40               -- bodies that keep holes (the one hit longest ago goes)
H.MAX_DRAW = 16                 -- bodies drawn a frame (the nearest)
H.DIST = 1400                   -- (a hole is under a pixel further off)
H.PER_PASS = 5                  -- holes in one draw of the body (hole_ps30's constants)
H.MAX_PASSES = 4
-- entry hole radius (units) by the ballistic class of the round (cl_forensic.lua): GHM FLESH's 0.3 for a typical round;
-- an exit is 1.7-2.8 x that in the shader, and a little more for fast rounds that tumble
H.SIZE = { pistol = 0.27, magnum = 0.32, rifle = 0.26, sniper = 0.34, buckshot = 0.2 }
H.EXIT = { pistol = 0.9, magnum = 1.1, rifle = 1.2, sniper = 1.35, buckshot = 0.8 }
local KIND = { skin = 0, cloth = 1, metal = 2 }

-- GHM FLESH on and drawing (its own Enabled(): the server switch, its shaders present, the client switch)
function H.FleshActive()
	local F = rawget(_G, "GHMFL")
	if type(F) ~= "table" then return false end
	local on = true
	if isfunction(F.Active) then
		local ok, v = pcall(F.Active)
		if ok then on = v and true or false end
	end
	if on and type(F.cv) == "table" and F.cv.enable and F.cv.enable.GetBool then
		local ok, v = pcall(F.cv.enable.GetBool, F.cv.enable)
		if ok then on = v and true or false end
	end
	return on
end

-- the hole shader is in the installed shader pack (packs before 1.26.10 have none; DirectX 11 has none)
function H.ShaderOK()
	if H.shaderOK == nil then
		local rel = "shaders/fxc/" .. GPU.Shader("hole_ps30") .. ".vcs"
		H.shaderOK = (file.Exists(rel, "GAME") or file.Exists("garrysmod/" .. rel, "BASE_PATH")) and true or false
	end
	return H.shaderOK
end

function H.Scale()
	local c = G.cv.holes
	return c and c:GetFloat() or 1
end

function H.On()
	if not G.cv.enable:GetBool() or H.Scale() <= 0 then return false end
	if G.Lite and G.Lite.on then return false end
	if not H.ShaderOK() then return false end
	return not H.FleshActive()
end

local function Body(ent)
	local b = H.bodies[ent]
	if b then return b end
	local n, oldest, oldT = 0, nil, math.huge
	for e, o in pairs(H.bodies) do
		n = n + 1
		if o.t < oldT then oldest, oldT = e, o.t end
	end
	if n >= H.MAX_BODIES and oldest ~= nil then H.bodies[oldest] = nil end
	b = { holes = {}, model = ent:GetModel(), t = CurTime() }
	H.bodies[ent] = b
	return b
end

-- a hole at wpos (on the body's surface) of a round going along dir; kind 0 entry, 1 exit; R its radius (units)
function H.Add(ent, bone, wpos, dir, kind, R, seed)
	if not IsValid(ent) or not wpos or not dir or not H.On() then return false end
	if dir:LengthSqr() < 1e-6 then return false end
	local d = dir:GetNormalized()
	local lp, ld
	if bone then lp, ld = U.BoneToLocal(ent, bone, wpos, d) end
	if not lp then
		bone = nil
		lp = ent:WorldToLocal(wpos)
		ld = WorldToLocal(d, angle_zero, vector_origin, ent:GetAngles())
	end
	local b = Body(ent)
	-- the same hole twice (a hit handled again, pellets on one spot): kept once
	for _, h in ipairs(b.holes) do
		if h.kind == kind and h.bone == bone and h.lp:DistToSqr(lp) < (0.6 * math.max(h.R, R)) ^ 2 then return false end
	end
	b.holes[#b.holes + 1] = { bone = bone, bname = bone and ent:GetBoneName(bone) or nil, lp = lp, ld = ld, kind = kind,
		R = R, seed = seed or math.random(), t = CurTime() }
	while #b.holes > H.PER_BODY do table.remove(b.holes, 1) end
	b.t = CurTime()
	H.added = (H.added or 0) + 1
	return true
end

-- from a bullet hit (cl_wounds.lua): bal / balE the round's ballistic profile and energy (Forensic.Ballistic)
function H.FromBullet(ent, bone, wpos, dir, bal, balE, kind)
	if not H.On() then return false end
	local cls = "pistol"
	local Fo = G.Forensic
	if bal and Fo and Fo.BALLISTIC then
		for k, v in pairs(Fo.BALLISTIC) do if v == bal then cls = k break end end
	end
	local R = (H.SIZE[cls] or 0.27) * (0.88 + 0.12 * math.Clamp(balE or 1, 0.7, 1.6)) * math.Clamp(H.Scale(), 0.5, 2)
	if kind == 1 then R = R * (H.EXIT[cls] or 1) end
	return H.Add(ent, bone, wpos, dir, kind, R, math.random())
end

-- an NPC turned into its ragdoll (cl_render.lua R.Transfer): its holes go over, bone by bone
function H.Transfer(from, to)
	local b = from ~= nil and H.bodies[from]
	if not b or not IsValid(to) then return end
	H.bodies[from] = nil
	local same = to:GetModel() == b.model
	local keep = {}
	for _, h in ipairs(b.holes) do
		if h.bone == nil then
			keep[#keep + 1] = h
		else
			local nb = h.bname and to:LookupBone(h.bname) or nil
			if not nb and same then nb = h.bone end
			if nb then h.bone = nb keep[#keep + 1] = h end
		end
	end
	if #keep == 0 then return end
	local nbody = H.bodies[to]
	if nbody then
		for _, h in ipairs(keep) do nbody.holes[#nbody.holes + 1] = h end
		while #nbody.holes > H.PER_BODY do table.remove(nbody.holes, 1) end
	else
		b.holes, b.model = keep, to:GetModel()
		H.bodies[to] = b
	end
end

function H.Remove(ent) H.bodies[ent] = nil end
function H.Clear() H.bodies = {} end
function H.Any() return next(H.bodies) ~= nil and H.On() end
function H.Count()
	local n = 0
	for _, b in pairs(H.bodies) do n = n + #b.holes end
	return n
end

-- bodies gone for good (5 s: an NPC is removed a moment before its ragdoll takes its holes)
local function Prune(now)
	if now < (H.pruneT or 0) then return end
	H.pruneT = now + 2
	for ent, b in pairs(H.bodies) do
		if not IsValid(ent) then
			b.goneT = b.goneT or now
			if now - b.goneT > 5 then H.bodies[ent] = nil end
		else
			b.goneT = nil
		end
	end
end

local mats = {}
local function Mat(kind)
	local k = KIND[kind] or 0
	local m = mats[k]
	if not m then
		m = GPU.Mat("hole" .. k, "model_vs30", "hole_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = "_rt_FullFrameFB", ["$linearread_basetexture"] = 1,
			["$cull"] = 1, ["$depthtest"] = 1, ["$linearwrite"] = 1 }))
		mats[k] = m
	end
	return m, k
end

local nMats = {}
local function MatCount(ent)
	local mdl = ent:GetModel() or ""
	local n = nMats[mdl]
	if not n then n = #(ent:GetMaterials() or {}) nMats[mdl] = n end
	return n
end

local P4 = {}
local function Pack(ent, h, i)
	local wp, wd = U.BoneToWorld(ent, h.bone, h.lp, h.ld)
	local o = i * 8
	if not wp then
		P4[o + 1], P4[o + 2], P4[o + 3], P4[o + 4] = 0, 0, -1e5, 0.02
		P4[o + 5], P4[o + 6], P4[o + 7], P4[o + 8] = 0, 0, 1, 0
		return
	end
	P4[o + 1], P4[o + 2], P4[o + 3], P4[o + 4] = wp.x, wp.y, wp.z, h.R
	P4[o + 5], P4[o + 6], P4[o + 7], P4[o + 8] = wd.x, wd.y, wd.z, h.kind + math.Clamp(h.seed, 0, 0.99)
end

local function SetHoles(mat, sw, sh, now, k, n)
	local p = P4
	GPU.SetC(mat, 0, 1 / sw, 1 / sh, now % 1000, k)
	GPU.SetC(mat, 1, p[1], p[2], p[3], p[4])
	GPU.SetC(mat, 2, p[5], p[6], p[7], p[8])
	GPU.SetC(mat, 3, p[9], p[10], p[11], p[12])
	GPU.SetRowsN(mat, "$viewprojmat", p[13], p[14], p[15], p[16], p[17], p[18], p[19], p[20],
		p[21], p[22], p[23], p[24], p[25], p[26], p[27], p[28])
	GPU.SetRowsN(mat, "$invviewprojmat", p[29], p[30], p[31], p[32], p[33], p[34], p[35], p[36],
		p[37], p[38], p[39], p[40], n, 0, 0, 0)
end

function H.Draw()
	if not H.On() then return end
	local now = CurTime()
	Prune(now)
	local E = G.Entities
	local eye = EyePos()
	local list = {}
	local d2max = H.DIST * H.DIST
	for ent, b in pairs(H.bodies) do
		if #b.holes > 0 and E.Visible(ent, eye) then
			local d2 = ent:GetPos():DistToSqr(eye)
			if d2 < d2max then list[#list + 1] = { ent = ent, b = b, d2 = d2 } end
		end
	end
	if #list == 0 then return end
	table.sort(list, function(a, c) return a.d2 < c.d2 end)
	local noDraw = E.NoDraw()
	local sw, sh = G.ViewSize()
	render.UpdateScreenEffectTexture()
	if G.Render then G.Render.copyFrame = FrameNumber() end
	local drawn = 0
	for li = 1, math.min(#list, H.MAX_DRAW) do
		local ent, b = list[li].ent, list[li].b
		local mi = E.ModelInfo(ent)
		if mi and mi.ok then
			local d = E.domains[ent]
			local target = ent
			if d and IsValid(d.proxy) then
				if d.proxy:GetParent() ~= ent and E.AttachProxy then E.AttachProxy(d, ent) end
				target = d.proxy
			end
			if U.EnsureBones then U.EnsureBones(ent) end
			local kinds = {}
			for _, sub in ipairs(mi.subs) do kinds[sub.kind] = true end
			local n = MatCount(ent)
			local holes = b.holes
			-- the newest first when a body has more holes than the passes take
			local first = math.max(1, #holes - H.PER_PASS * H.MAX_PASSES + 1)
			for s = first, #holes, H.PER_PASS do
				local cnt = math.min(H.PER_PASS, #holes - s + 1)
				for i = 0, H.PER_PASS - 1 do
					local h = holes[s + math.min(i, cnt - 1)]
					Pack(ent, h, i)
				end
				for kind in pairs(kinds) do
					local m, k = Mat(kind)
					SetHoles(m, sw, sh, now, k, cnt)
				end
				for i = 0, math.max(n, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
				for _, sub in ipairs(mi.subs) do render.MaterialOverrideByIndex(sub.index, (Mat(sub.kind))) end
				target:DrawModel()
				render.MaterialOverrideByIndex()
				drawn = drawn + 1
			end
		end
	end
	if drawn > 0 and G.Prof and G.Prof.Count then G.Prof.Count("bullet hole draws", drawn) end
end

hook.Add("EntityRemoved", "ghmpb_holes", function(ent, fullUpdate)
	if fullUpdate then return end
	local b = H.bodies[ent]
	if b then b.goneT = CurTime() end
end)
