-- GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): the Crisis Response Blood splats drawn by PhysBlood itself.
--
-- GHM: "the decals disappear, I know it's an engine issue, but can we do something about it". Engine decals are
-- limited (mp_decals, 200 in multiplayer; r_decals in single player) and the engine also removes a decal when newer
-- ones cover it, so splats vanished while the shooting went on. On the world, the splats are now meshes PhysBlood keeps
-- and draws (in both renderers): the same textures, drawn with the Modulate shader (the wall times twice the texture,
-- blending to no change where the texture is clear - what DecalModulate does), laid on the surface in a 6 x 6 grid of
-- cells that each follow the surface and are left out where it ends (edges, corners, steps), so a splat does not hang
-- in the air. They stay until "splats kept" (ghmpb_splats_kept) is used up, the oldest going first, and ghmpb_clear
-- removes them. On props and brush entities (they move) the splats stay engine decals.
-- As meshes they can also turn: along the way the blood travelled (stretched up to 2x at a glancing hit), else at any
-- angle, and mirrored at random.
local G = GHMPB
G.SplatMesh = G.SplatMesh or {}
local SM = G.SplatMesh
local U = G.U
local abs, max, min = math.abs, math.max, math.min

local cvOn = CreateClientConVar("ghmpb_splat_mesh", "1", true, false, "GHM PhysBlood: draw the Crisis Response splats on the world itself, so they do not vanish (the engine's decal limit); 0 = engine decals", 0, 1)
local cvKeep = CreateClientConVar("ghmpb_splats_kept", "3000", true, false, "GHM PhysBlood: how many Crisis Response splats stay on the world when PhysBlood draws them (the oldest go first)", 100, 30000)
SM.cvOn, SM.cvKeep = cvOn, cvKeep
SM.stats = SM.stats or { laid = 0, missed = 0, cells = 0, baked = 0, removed = 0 }
SM.open = SM.open or {}
SM.batches = SM.batches or {}
SM.total = SM.total or 0

function SM.On() return cvOn:GetBool() end

local mats = {}
local function Mat(tex)
	local m = mats[tex]
	if m == nil then
		m = CreateMaterial and CreateMaterial("ghmpb_splat_" .. string.gsub(tex, "[^%w]", "_"), "Modulate", {
			["$basetexture"] = tex,
			["$mod2x"] = "1",
			["$vertexcolor"] = "1",
			["$vertexalpha"] = "1",
			["$decal"] = "1",
			["$nocull"] = "1",
		}) or false
		if m and m.IsError and m:IsError() then m = false end
		mats[tex] = m
	end
	return m
end

local GRID = 6
local BAKE_N, BAKE_T = 12, 2.0
local tr = { mask = MASK_SOLID_BRUSHONLY }

local function OpenFor(m)
	local o = SM.open[m]
	if not o then
		o = { mat = m, verts = {}, n = 0, t0 = CurTime(), sx = 0, sy = 0, sz = 0, pts = {} }
		SM.open[m] = o
	end
	return o
end

local function Bounds(pts)
	local mn = Vector(math.huge, math.huge, math.huge)
	local mx = Vector(-math.huge, -math.huge, -math.huge)
	for _, p in ipairs(pts) do
		local r = p.r
		mn.x, mn.y, mn.z = min(mn.x, p.x - r), min(mn.y, p.y - r), min(mn.z, p.z - r)
		mx.x, mx.y, mx.z = max(mx.x, p.x + r), max(mx.y, p.y + r), max(mx.z, p.z + r)
	end
	return (mn + mx) * 0.5, (mx - mn):Length() * 0.5
end

local function Rebuild(o)
	if o.mesh then o.mesh:Destroy() o.mesh = nil end
	if #o.verts > 0 then
		o.mesh = Mesh(o.mat)
		o.mesh:BuildFromTriangles(o.verts)
	end
	o.center, o.radius = Bounds(o.pts)
end

local function Count()
	local n = SM.total
	for _, o in pairs(SM.open) do n = n + o.n end
	return n
end
SM.Count = Count

local function Store(m, o)
	if o.n == 0 then return end
	if not o.mesh then Rebuild(o) end
	SM.batches[#SM.batches + 1] = { mat = m, mesh = o.mesh, n = o.n, center = o.center, radius = o.radius, t = o.t0 }
	SM.total = SM.total + o.n
	SM.open[m] = nil
	SM.stats.baked = SM.stats.baked + 1
end

-- over the budget: the oldest go first (the oldest stored batch, or else the oldest splats still open)
local function Cap()
	local keep = cvKeep:GetInt()
	while Count() > keep do
		if #SM.batches == 0 then
			local om, oo
			for m, o in pairs(SM.open) do if not oo or o.t0 < oo.t0 then om, oo = m, o end end
			if not oo then break end
			Store(om, oo)
		end
		local b = table.remove(SM.batches, 1)
		if b.mesh then b.mesh:Destroy() end
		SM.total = SM.total - b.n
		SM.stats.removed = SM.stats.removed + b.n
	end
end

local function Bake(m, o)
	Store(m, o)
	Cap()
end

-- lay a splat: tex = the material / texture path, w x h its size in units, dir = the way the blood travelled (or nil)
function SM.Lay(pos, n, tex, w, h, dir)
	if not pos or not n or not tex or not w or not h then return false end
	local m = Mat(tex)
	if not m then return false end
	n = n:GetNormalized()
	local Ua, E = nil, 1
	if dir and dir:LengthSqr() > 1e-6 then
		local d = dir:GetNormalized()
		local t = d - n * d:Dot(n)
		if t:LengthSqr() > 1e-4 then
			t:Normalize()
			E = math.Clamp(1 / max(abs(d:Dot(n)), 0.4), 1, 2.0)
			local a = (math.random() - 0.5) * 0.6
			Ua = t * math.cos(a) + n:Cross(t) * math.sin(a)
		end
	end
	if not Ua then
		local base = abs(n.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
		local u = base:Cross(n) u:Normalize()
		local v = n:Cross(u)
		local a = math.random() * 6.2831853
		Ua = u * math.cos(a) + v * math.sin(a)
	end
	local Va = n:Cross(Ua)
	local hu, hv = w * 0.5 * E, h * 0.5
	local mirror = math.random() < 0.5
	local col = Color(255, 255, 255, 255)
	local nrm = Vector(n)
	local new = {}
	local step = 2 / GRID
	local function TU(u) local t = (u + 1) * 0.5 return mirror and 1 - t or t end
	local function TV(v) return 1 - (v + 1) * 0.5 end
	for a = 0, GRID - 1 do
		for b = 0, GRID - 1 do
			local cu, cv = -1 + (a + 0.5) * step, -1 + (b + 0.5) * step
			local c = pos + Ua * (cu * hu) + Va * (cv * hv)
			tr.start = c + n * 3
			tr.endpos = c - n * 3
			local t = util.TraceLine(tr)
			if t.Hit and t.HitWorld and not t.StartSolid and not t.HitSky and t.HitNormal:Dot(n) > 0.85
				and abs((t.HitPos - pos):Dot(n)) < 1.5 then
				local z = (t.HitPos - pos):Dot(n) + 0.06
				local u0, u1, v0, v1 = -1 + a * step, -1 + (a + 1) * step, -1 + b * step, -1 + (b + 1) * step
				local function P(u, v) return pos + Ua * (u * hu) + Va * (v * hv) + n * z end
				local q00 = { pos = P(u0, v0), normal = nrm, u = TU(u0), v = TV(v0), color = col }
				local q10 = { pos = P(u1, v0), normal = nrm, u = TU(u1), v = TV(v0), color = col }
				local q11 = { pos = P(u1, v1), normal = nrm, u = TU(u1), v = TV(v1), color = col }
				local q01 = { pos = P(u0, v1), normal = nrm, u = TU(u0), v = TV(v1), color = col }
				new[#new + 1] = q00 new[#new + 1] = q10 new[#new + 1] = q11
				new[#new + 1] = q00 new[#new + 1] = q11 new[#new + 1] = q01
			end
		end
	end
	if #new == 0 then SM.stats.missed = SM.stats.missed + 1 return false end
	local o = OpenFor(m)
	for i = 1, #new do o.verts[#o.verts + 1] = new[i] end
	o.n = o.n + 1
	o.pts[#o.pts + 1] = { x = pos.x, y = pos.y, z = pos.z, r = max(hu, hv) }
	SM.stats.laid = SM.stats.laid + 1
	SM.stats.cells = SM.stats.cells + #new / 6
	Rebuild(o)
	if o.n >= BAKE_N then Bake(m, o) else Cap() end
	return true
end

function SM.Update()
	local now = CurTime()
	for m, o in pairs(SM.open) do
		if o.n > 0 and now - o.t0 > BAKE_T then Bake(m, o) end
	end
end

local function InView(c, r, eye)
	if not c then return false end
	if c:DistToSqr(eye) > (6000 + r) ^ 2 then return false end
	return not U.InViewPos or U.InViewPos(c, r)
end

function SM.Draw()
	if #SM.batches == 0 and next(SM.open) == nil then return end
	local eye = EyePos()
	for _, b in ipairs(SM.batches) do
		if b.mesh and InView(b.center, b.radius, eye) then
			render.SetMaterial(b.mat)
			b.mesh:Draw()
		end
	end
	for m, o in pairs(SM.open) do
		if o.mesh and InView(o.center, o.radius, eye) then
			render.SetMaterial(m)
			o.mesh:Draw()
		end
	end
end

function SM.Clear()
	for _, b in ipairs(SM.batches) do if b.mesh then b.mesh:Destroy() end end
	for _, o in pairs(SM.open) do if o.mesh then o.mesh:Destroy() end end
	SM.batches, SM.open, SM.total = {}, {}, 0
end

hook.Add("Think", "ghmpb_splatmesh", function() if next(SM.open) ~= nil then SM.Update() end end)
cvars.AddChangeCallback("ghmpb_splats_kept", function() Cap() end, "ghmpb_splatmesh")

concommand.Add("ghmpb_splats_info", function()
	MsgN(string.format("[GHMPB] splats drawn by PhysBlood: %s | %d kept (of %d), %d batches | laid %d, missed (no surface) %d, removed (oldest) %d",
		cvOn:GetBool() and "on" or "off (engine decals)", Count(), cvKeep:GetInt(), #SM.batches, SM.stats.laid, SM.stats.missed, SM.stats.removed))
end, nil, "GHM PhysBlood: the Crisis Response splats PhysBlood draws on the world")
