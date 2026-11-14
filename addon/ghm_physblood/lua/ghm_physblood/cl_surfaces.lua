local G = GHMPB
G.Surfaces = G.Surfaces or {}
local S = G.Surfaces
local GPU = G.GPU

S.PATCH_UNITS = 40
S.BED = 16
S.patches = S.patches or {}
S.bedJobs = S.bedJobs or {}
S.after = S.after or {}
S.pool = S.pool or {}
S.slotCount = S.slotCount or 0
S.clock = S.clock or 0
S.stepId = S.stepId or 0

local function PatchRes() return G.Budget.PatchRes() end
local function AftRes() return G.Budget.AftRes() end

S.albedoQueue = S.albedoQueue or {}
if S.albedoV ~= 3 then
	S.albedoV = 3
	S.albedo = {}
	for _, p in pairs(S.patches or {}) do if p.albedoTex then S.albedoQueue[p.albedoTex] = true end end
	for _, p in pairs(S.after or {}) do if p.albedoTex then S.albedoQueue[p.albedoTex] = true end end
end
S.albedo = S.albedo or {}
local DEFAULT_ALBEDO = Vector(0.24, 0.24, 0.24)
local function SRGBToLinear(c) c = c / 255 return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function NormAlbedo(r, g, b)
	local lum = r * 0.2126 + g * 0.7152 + b * 0.0722
	if lum < 0.025 then return DEFAULT_ALBEDO end
	local tLum = math.Clamp(0.18 + 0.14 * (lum ^ 0.45), 0.18, 0.30)
	local k = tLum / lum
	r, g, b = r * k, g * k, b * k
	r = tLum + (r - tLum) * 0.35
	g = tLum + (g - tLum) * 0.35
	b = tLum + (b - tLum) * 0.35
	return Vector(math.Clamp(r, 0.14, 0.36), math.Clamp(g, 0.14, 0.36), math.Clamp(b, 0.14, 0.36))
end

function S.Albedo(texName)
	if not texName or texName == "" then return DEFAULT_ALBEDO end
	local a = S.albedo[texName]
	if a then return a end
	S.albedoQueue[texName] = true
	return DEFAULT_ALBEDO
end

local albRT, albMat
local function Measure(texName)
	local m = Material(texName)
	if not m or m:IsError() then return DEFAULT_ALBEDO end
	local t = m:GetTexture("$basetexture")
	if not t or t:IsError() then return DEFAULT_ALBEDO end
	if not albRT then
		albRT = GetRenderTargetEx(GPU.Name("albedo8"), 8, 8, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)
		albMat = GPU.CreateMat("albedo", "UnlitGeneric", { ["$basetexture"] = "vgui/white", ["$ignorez"] = 1 })
	end
	albMat:SetTexture("$basetexture", t)
	render.PushRenderTarget(albRT)
	render.Clear(0, 0, 0, 255)
	cam.Start2D()
	render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(albMat)
	surface.DrawTexturedRect(0, 0, 8, 8)
	render.OverrideBlend(false)
	cam.End2D()
	render.CapturePixels()
	local r, g, b, n = 0, 0, 0, 0
	for y = 0, 7 do
		for x = 0, 7 do
			local cr, cg, cb = render.ReadPixel(x, y)
			if cr then r = r + SRGBToLinear(cr) g = g + SRGBToLinear(cg) b = b + SRGBToLinear(cb) n = n + 1 end
		end
	end
	render.PopRenderTarget()
	if n == 0 then return DEFAULT_ALBEDO end
	return NormAlbedo(r / n, g / n, b / n)
end

local function StoreAlbedo(texName, r, g, b)
	local a = NormAlbedo(r, g, b)
	S.albedo[texName] = a
	for _, p in pairs(S.patches) do if p.albedoTex == texName then p.albedo = a end end
	for _, p in pairs(S.after) do if p.albedoTex == texName then p.albedo = a end end
end

function S.AlbedoTiles(tiles)
	if not next(S.albedoQueue) then return end
	if not albMat then albMat = GPU.CreateMat("albedo", "UnlitGeneric", { ["$basetexture"] = "vgui/white", ["$ignorez"] = 1 }) end
	local n = 0
	for texName in pairs(S.albedoQueue) do
		if n >= 4 or #tiles >= 240 then break end
		S.albedoQueue[texName] = nil
		local m = Material(texName)
		local t = (m and not m:IsError()) and m:GetTexture("$basetexture")
		if not t or t:IsError() then
			S.albedo[texName] = DEFAULT_ALBEDO
		else
			local x0, y0 = GPU.TileOrigin(#tiles)
			albMat:SetTexture("$basetexture", t)
			cam.Start2D()
			render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
			surface.SetDrawColor(255, 255, 255, 255)
			surface.SetMaterial(albMat)
			surface.DrawTexturedRect(x0, y0, GPU.TILE, GPU.TILE)
			render.OverrideBlend(false)
			cam.End2D()
			tiles[#tiles + 1] = { kind = "albedo", tex = texName, x0 = x0, y0 = y0 }
			n = n + 1
		end
	end
end

function S.AlbedoRead(t)
	local r, g, b, n = 0, 0, 0, 0
	for y = 0, GPU.TILE - 1 do
		for x = 0, GPU.TILE - 1 do
			local cr, cg, cb = render.ReadPixel(t.x0 + x, t.y0 + y)
			if cr then r = r + SRGBToLinear(cr) g = g + SRGBToLinear(cg) b = b + SRGBToLinear(cb) n = n + 1 end
		end
	end
	if n == 0 then S.albedo[t.tex] = DEFAULT_ALBEDO return end
	StoreAlbedo(t.tex, r / n, g / n, b / n)
end

function S.ProcessAlbedo()
	local done = 0
	for texName in pairs(S.albedoQueue) do
		S.albedoQueue[texName] = nil
		local ok, a = pcall(Measure, texName)
		S.albedo[texName] = ok and a or DEFAULT_ALBEDO
		for _, p in pairs(S.patches) do if p.albedoTex == texName then p.albedo = S.albedo[texName] end end
		for _, p in pairs(S.after) do if p.albedoTex == texName then p.albedo = S.albedo[texName] end end
		done = done + 1
		if done >= 2 then break end
	end
end

function S.EnhancedReady()
	if S.enhReady == nil then
		if not GPU or not GPU.Shader or GPU.isDX11 then
			S.enhReady = false
		else
			local ok = true
			for _, sh in ipairs({ "fbblur_ps30", "surfbase_ps30", "surfcoat_ps30" }) do
				local rel = "shaders/fxc/" .. GPU.Shader(sh) .. ".vcs"
				if not file.Exists(rel, "GAME") and not file.Exists("garrysmod/" .. rel, "BASE_PATH") then
					ok = false
					break
				end
			end
			S.enhReady = ok
		end
	end
	return S.enhReady
end

local function NewSlot(res)
	S.slotCount = S.slotCount + 1
	G.Budget.Count("patch", res)
	local id = S.slotCount
	local tag = "w" .. id .. "_" .. res
	local s = { id = id, res = res }
	s.st = { GPU.RT(tag .. "_stA", res, res), GPU.RT(tag .. "_stB", res, res) }
	s.ac = { GPU.RT(tag .. "_acA", res, res), GPU.RT(tag .. "_acB", res, res) }
	s.aux = { GPU.RT(tag .. "_axA", res, res), GPU.RT(tag .. "_axB", res, res) }
	s.ex = { GPU.RT(tag .. "_exA", res, res), GPU.RT(tag .. "_exB", res, res) }
	s.force = GPU.RT(tag .. "_frc", res, res)
	s.bed = GPU.RT(tag .. "_bed", S.BEDRES or 128, S.BEDRES or 128)
	s.sim, s.overlay, s.surfbase, s.surfcoat, s.reduce = {}, {}, {}, {}, {}
	local enhOK = S.EnhancedReady and S.EnhancedReady()
	local fbBlurName = enhOK and GPU.FBBlur and GPU.FBBlur():GetName() or "vgui/white"
	for k = 1, 2 do
		s.sim[k] = GPU.Mat(tag .. "_sim" .. k, "clip_vs30", "sim_ps30", {
			["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = s.force:GetName(), ["$texture2"] = s.ac[k]:GetName(),
			["$texture3"] = s.aux[k]:GetName(), ["$tcsize0"] = 4, ["$tcsize1"] = 4,
			["$c15_y"] = 1, ["$c15_w"] = 1, ["$c16_y"] = 1, ["$c16_w"] = 1 }, true)
		s.overlay[k] = GPU.Mat(tag .. "_ov" .. k, "world_vs30", "surface_ps30", {
			["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture2"] = s.bed:GetName(), ["$texture3"] = "vgui/white", ["$texture4"] = s.aux[k]:GetName(),
			["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1, ["$texture6"] = s.ac[k]:GetName(),
			["$texture7"] = GPU.MatTable():GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
			["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 }, true)
		if enhOK then
			s.surfbase[k] = GPU.Mat(tag .. "_sb" .. k, "world_vs30", "surfbase_ps30", {
				["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
				["$texture2"] = s.bed:GetName(), ["$texture3"] = "vgui/white", ["$texture4"] = s.aux[k]:GetName(),
				["$texture5"] = fbBlurName, ["$linearread_texture5"] = 1, ["$texture6"] = s.ac[k]:GetName(),
				["$texture7"] = GPU.MatTable():GetName(),
				["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
				["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 }, true)
			s.surfcoat[k] = GPU.Mat(tag .. "_sc" .. k, "world_vs30", "surfcoat_ps30", {
				["$basetexture"] = s.st[k]:GetName(), ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
				["$texture2"] = s.bed:GetName(), ["$texture3"] = "vgui/white", ["$texture4"] = s.aux[k]:GetName(),
				["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1,
				["$texture6"] = fbBlurName, ["$linearread_texture6"] = 1,
				["$texture7"] = GPU.MatTable():GetName(),
				["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
				["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 }, true)
		end
		s.reduce[k] = GPU.Mat(tag .. "_red" .. k, "clip_vs30", "reduce_ps30", {
			["$basetexture"] = s.ac[k]:GetName(), ["$texture1"] = s.force:GetName(), ["$texture2"] = s.force:GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
	s.pforce = GPU.Mat(tag .. "_pf", "clip_vs30", "pforce_ps30", {
		["$basetexture"] = s.bed:GetName(), ["$texture1"] = "vgui/white", ["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4 })
	return s
end

local function Clear(rt) render.PushRenderTarget(rt) render.Clear(0, 0, 0, 0) render.PopRenderTarget() end

local function TakeSlot()
	local res = PatchRes()
	S.pool[res] = S.pool[res] or {}
	local s = table.remove(S.pool[res])
	if not s then
		if not G.Budget.MayCreatePatch(res) then return nil end
		-- (1.26.8) as many new ones a frame as fit into a few ms (up to 32 before); the patch waits for its slot
		if not G.Budget.MayCreateNow() then G.Budget.NoteDeferred() return nil end
		local t0 = SysTime()
		s = NewSlot(res)
		G.Budget.NoteCreated((SysTime() - t0) * 1000)
	end
	for k = 1, 2 do Clear(s.st[k]) Clear(s.ac[k]) Clear(s.aux[k]) Clear(s.ex[k]) end
	return s
end

local function FreeSlot(s)
	if not s then return end
	S.pool[s.res] = S.pool[s.res] or {}
	table.insert(S.pool[s.res], s)
end

-- (1.26.8) a few free patch slots made ahead, one at a time between frames (cl_render.lua, every 0.5 s)
function S.KeepReserve(want)
	local res = PatchRes()
	local free = S.pool[res] and #S.pool[res] or 0
	if free >= want or not G.Budget.MayCreatePatch(res) then return false end
	local t0 = SysTime()
	FreeSlot(NewSlot(res))
	G.Budget.NoteCreated((SysTime() - t0) * 1000)
	return true
end

function S.WarmSlot(want)
	local res = PatchRes()
	local made = false
	for _ = 1, 2 do
		if (G.Budget.made.patch[res] or 0) >= want or not G.Budget.MayCreatePatch(res) then break end
		FreeSlot(NewSlot(res))
		made = true
	end
	return made
end

local stampMat, staticMat, elemMat
local function Shared()
	if not stampMat then
		stampMat = GPU.Mat("wstamp", "clip_vs30", "stamp_ps30", {
			["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white", ["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4 })
		elemMat = GPU.Mat("welem", "clip_vs30", "elem_ps30", {
			["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white", ["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4 })
		staticMat = GPU.Mat("wstatic", "world_vs30", "surfstatic_ps30", {
			["$basetexture"] = "vgui/white", ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1, ["$texture7"] = GPU.MatTable():GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
			["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 }, true)
	end
end

local function Basis(n)
	local U
	if math.abs(n.z) > 0.7 then
		U = Vector(1, 0, 0) - n * n.x
	else
		U = Vector(0, 0, 1):Cross(n)
	end
	U:Normalize()
	local V = n:Cross(U) V:Normalize()
	return U, V
end

local function PlaneKey(n, dist)
	return string.format("%d,%d,%d,%d", math.Round(n.x * 40), math.Round(n.y * 40), math.Round(n.z * 40), math.Round(dist * 2))
end

local function Count() local c = 0 for _ in pairs(S.patches) do c = c + 1 end return c end

local NB4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local function Evict(minQuiet)
	local worst, ws = nil, -math.huge
	local eye = EyePos()
	local now = CurTime()
	for key, p in pairs(S.patches) do
		if not p.bakeNow and not p.needSlot then
			local quiet = now - p.touched
			for m = 1, 4 do
				local q = S.patches[S.NbKey(p, m)]
				if q then quiet = math.min(quiet, now - q.touched) end
			end
			if not minQuiet or quiet >= minQuiet then
				local score = quiet * 1.0 + p.center:Distance(eye) * 0.004 + (now > p.wetUntil and 60 or 0) + ((p.vol or 0) < 4000 and 8 or 0)
				if score > ws then worst, ws = key, score end
			end
		end
	end
	if not worst then return end
	if G.cv.aftermath:GetBool() then S.patches[worst].bakeNow = true
	else S.RemovePatch(worst) end
end

local CELL = 64
S.cells = S.cells or {}
local function CKey(x, y, z) return ((x + 1024) * 2048 + (y + 1024)) * 2048 + (z + 1024) end
local function CellOf(v) return math.floor(v.x / CELL), math.floor(v.y / CELL), math.floor(v.z / CELL) end
function S.IndexAdd(p)
	if p.cellKey then return end
	local k = CKey(CellOf(p.center))
	local c = S.cells[k]
	if not c then c = {} S.cells[k] = c end
	c[p] = true
	p.cellKey = k
	S.ageDirty = true
end
function S.IndexRemove(p)
	local k = p.cellKey
	if not k then return end
	local c = S.cells[k]
	if c then
		c[p] = nil
		if next(c) == nil then S.cells[k] = nil end
	end
	p.cellKey = nil
	S.ageDirty = true
end

function S.RemovePatch(key)
	local p = S.patches[key]
	if not p then return end
	S.IndexRemove(p)
	S.bedJobs[key] = nil
	FreeSlot(p.slot)
	S.FreeMeshes(p)
	S.patches[key] = nil
end

S.BEDRES = 128
S.PROBE = 32
S.BED_MS = 12.0
S.bedJobs = S.bedJobs or {}

local GROUND_CLASSES = { prop_dynamic = true,
	prop_dynamic_override = true, prop_static = true, prop_door_rotating = true, func_physbox = true, func_brush = true }
function S.IsGround(ent)
	if not IsValid(ent) or ent:IsWorld() then return false end
	local c = ent:GetClass()
	if string.sub(c, 1, 15) == "ghmpb_bricktest" then return true end
	if ent:IsRagdoll() or ent:IsNPC() or ent:IsPlayer() or ent:IsWeapon() then return false end
	local mdl = ent:GetModel()
	local brush = mdl ~= nil and string.sub(mdl, 1, 1) == "*"
	if not brush then
		if not GROUND_CLASSES[c] then return false end
		if ent:BoundingRadius() < 20 then return false end
	end
	return ent:GetVelocity():LengthSqr() < 4
end
function S.GroundFilter(e) return not IsValid(e) or e:IsWorld() or S.IsGround(e) end

local bedOut = {}
local bedFilter = {}
local bedTr = { mask = MASK_SOLID, output = bedOut, filter = bedFilter }
local function BedFilterFor(p)
	for k = #bedFilter, 1, -1 do bedFilter[k] = nil end
	local P = S.PATCH_UNITS
	local mins, maxs = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
	for _, c in ipairs({ p.origin, p.origin + p.U * P, p.origin + p.V * P, p.origin + p.U * P + p.V * P }) do
		for _, q in ipairs({ c + p.N * 10, c - p.N * 10 }) do
			mins.x, mins.y, mins.z = math.min(mins.x, q.x), math.min(mins.y, q.y), math.min(mins.z, q.z)
			maxs.x, maxs.y, maxs.z = math.max(maxs.x, q.x), math.max(maxs.y, q.y), math.max(maxs.z, q.z)
		end
	end
	for _, e in ipairs(ents.FindInBox(mins, maxs)) do
		if IsValid(e) and not S.IsGround(e) then bedFilter[#bedFilter + 1] = e end
	end
end

local bedS, bedE = Vector(), Vector()
local function BedSample(p, a, b, ents)
	if not p.geo then S.GeoNums(p) end
	local nx, ny, nz = p.gnx, p.gny, p.gnz
	local ox, oy, oz = p.gox + p.gux * a + p.gvx * b, p.goy + p.guy * a + p.gvy * b, p.goz + p.guz * a + p.gvz * b
	bedS:SetUnpacked(ox + nx * 5, oy + ny * 5, oz + nz * 5)
	bedE:SetUnpacked(ox - nx * 9, oy - ny * 9, oz - nz * 9)
	bedTr.start = bedS
	bedTr.endpos = bedE
	util.TraceLine(bedTr)
	local tr = bedOut
	if tr.StartSolid then return nil, true end
	if tr.Hit and not tr.HitSky then
		local hp, hn = tr.HitPos, tr.HitNormal
		local h = (hp.x - ox) * nx + (hp.y - oy) * ny + (hp.z - oz) * nz
		local hx, hy, hz = hn.x, hn.y, hn.z
		if hx * nx + hy * ny + hz * nz > 0.55 then
			-- (1.26.6) +-6 u as in 1.26.0: a patch takes the plane of any impact within +-5 u of it (FindPatch), so the
			-- surface under it has to be accepted that far; +-1.35 u turned slopes into patches full of holes
			if math.abs(h) < 6 then
				local e = tr.Entity
				if ents and IsValid(e) and not e:IsWorld() and not ents[e] then ents[e] = { e:GetPos(), e:GetAngles() } end
				return h, hx * p.gux + hy * p.guy + hz * p.guz, hx * p.gvx + hy * p.gvy + hz * p.gvz
			end
		elseif h > -0.5 then
			return nil, true
		end
	end
	return nil
end
S.BLOCKED_MASK = 0.35

local function CoarseFrom(p, arr, res, edge)
	local N = S.BED
	local per = res / N
	local stride = edge and res + 1 or res
	local lim = edge and res or res - 1
	local cMax, cMin = {}, {}
	for cy = 0, N - 1 do
		local y0, y1 = cy * per, math.min((cy + 1) * per, lim)
		for cx = 0, N - 1 do
			local x0, x1 = cx * per, math.min((cx + 1) * per, lim)
			local mx, mn = -math.huge, math.huge
			for y = y0, y1 do
				local row = y * stride
				for x = x0, x1 do
					local h = arr[row + x]
					if h then
						if h > mx then mx = h end
						if h < mn then mn = h end
					end
				end
			end
			cMax[cy * N + cx] = mx > -math.huge and mx or nil
			cMin[cy * N + cx] = mn < math.huge and mn or nil
		end
	end
	p.cMax, p.cMin = cMax, cMin
end

local function NewProbe(p)
	return { h = {}, u = {}, v = {}, blk = {}, ents = {}, hits = 0, hmin = math.huge, hmax = -math.huge, ndev = 0, k = 0 }
end
local function ProbeSample(p, pr, x, y)
	local M, P = S.PROBE, S.PATCH_UNITS
	local k = y * (M + 1) + x
	local h, nu, nv = BedSample(p, x / M * P, y / M * P, pr.ents)
	if not h and nu then pr.blk[k] = true end
	if h then
		pr.h[k], pr.u[k], pr.v[k] = h, nu, nv
		pr.hits = pr.hits + 1
		if h < pr.hmin then pr.hmin = h end
		if h > pr.hmax then pr.hmax = h end
		pr.ndev = math.max(pr.ndev, nu * nu + nv * nv)
	end
end
local PROBE_C = 8
local function ProbeCoarse(p)
	local M = S.PROBE
	local pr = NewProbe(p)
	p.probe = pr
	BedFilterFor(p)
	for y = 0, M, PROBE_C do for x = 0, M, PROBE_C do ProbeSample(p, pr, x, y) end end
	p.groundEnts = next(pr.ents) and pr.ents or nil
	local coarse = (M / PROBE_C + 1) * (M / PROBE_C + 1)
	if pr.hits == 0 then
		local nb = 0 for _ in pairs(pr.blk) do nb = nb + 1 end
		return "empty", nil, nb > coarse * 0.5
	end
	if pr.hits == coarse and pr.hmax - pr.hmin < 0.03 and pr.ndev < 0.001 then return "flat", (pr.hmin + pr.hmax) * 0.5 end
	return "more"
end
local function ProbeRest(p, tEnd)
	local M = S.PROBE
	local pr = p.probe
	local total = (M + 1) * (M + 1)
	local k = pr.k
	local n = 0
	while k < total do
		local x, y = k % (M + 1), (k - k % (M + 1)) / (M + 1)
		if x % PROBE_C ~= 0 or y % PROBE_C ~= 0 then
			ProbeSample(p, pr, x, y)
			n = n + 1
			if n % 24 == 0 and SysTime() > tEnd then k = k + 1 break end
		end
		k = k + 1
	end
	pr.k = k
	return k >= total
end
local function ProbeClassify(p)
	local M = S.PROBE
	local pr = p.probe
	local ph, pu, pv = pr.h, pr.u, pr.v
	p.groundEnts = next(pr.ents) and pr.ents or nil
	local total = (M + 1) * (M + 1)
	if pr.hits < 3 then
		local nb = 0 for _ in pairs(pr.blk) do nb = nb + 1 end
		return "empty", nil, nb > total * 0.5
	end
	local disc = pr.hits < total
	if not disc then
		for y = 0, M do
			for x = 0, M do
				local k = y * (M + 1) + x
				for _, d in ipairs({ 1, M + 1 }) do
					local j = k + d
					if (d == 1 and x < M) or (d > 1 and y < M) then
						if math.abs(ph[k] - ph[j]) > 0.35 or (pu[k] - pu[j]) ^ 2 + (pv[k] - pv[j]) ^ 2 > 0.06 then disc = true break end
					end
				end
				if disc then break end
			end
			if disc then break end
		end
	end
	if not disc and pr.hmax - pr.hmin < 0.03 and pr.ndev < 0.001 then return "flat", (pr.hmin + pr.hmax) * 0.5 end
	return disc and "fine" or "smooth"
end

local function UploadProbe(p)
	local M, R = S.PROBE, S.BEDRES
	local pr = p.probe
	local cell = R / M
	local function val(x, y)
		local k = y * (M + 1) + x
		local h = pr.h[k]
		if h then return h, 1, pr.u[k], pr.v[k] end
		local s, c = 0, 0
		for dy = -1, 1 do for dx = -1, 1 do
			local xx, yy = x + dx, y + dy
			if xx >= 0 and xx <= M and yy >= 0 and yy <= M then
				local hh = pr.h[yy * (M + 1) + xx]
				if hh then s = s + hh c = c + 1 end
			end
		end end
		return c > 0 and s / c or 0, pr.blk[k] and S.BLOCKED_MASK or 0, 0, 0   -- (1.26.6) open void = 0, as the shaders expect
	end
	local quads = {}
	for y = 0, M - 1 do
		for x = 0, M - 1 do
			local c = { { val(x, y) }, { val(x + 1, y) }, { val(x + 1, y + 1) }, { val(x, y + 1) } }
			quads[#quads + 1] = { x * cell, y * cell, (x + 1) * cell, (y + 1) * cell, function(ci) return c[ci] end }
		end
	end
	render.PushRenderTarget(p.slot.bed)
	render.SetMaterial(GPU.Blit())
	GPU.Quads(R, R, quads)
	render.PopRenderTarget()
	CoarseFrom(p, pr.h, M, true)
end

local function UploadFine(p, fh, fu, fv)
	local R = S.BEDRES
	local quads = {}
	local function same(a, b)
		local ha, hb = fh[a], fh[b]
		if (ha == false) ~= (hb == false) then return false end
		if ha == false then return fu[a] == fu[b] end
		return math.abs(ha - hb) < 0.01 and math.abs(fu[a] - fu[b]) < 0.02 and math.abs(fv[a] - fv[b]) < 0.02
	end
	local prevSig, open = nil, {}
	for y = 0, R - 1 do
		local runs = {}
		local x = 0
		while x < R do
			local k0 = y * R + x
			local x1 = x + 1
			while x1 < R and same(k0, y * R + x1) do x1 = x1 + 1 end
			runs[#runs + 1] = { x, x1, k0 }
			x = x1
		end
		local extend = prevSig and #prevSig == #runs
		if extend then
			for i, r in ipairs(runs) do
				local q = prevSig[i]
				if q[1] ~= r[1] or q[2] ~= r[2] or not same(q[3], r[3]) then extend = false break end
			end
		end
		if extend then
			for _, q in ipairs(open) do q[4] = y + 1 end
		else
			for _, r in ipairs(runs) do
				local k = r[3]
				local h = fh[k]
				local pay = h == false and { 0, fu[k] == 1 and S.BLOCKED_MASK or 0, 0, 0 } or { h, 1, fu[k], fv[k] }
				local q = { r[1], y, r[2], y + 1, pay }
				quads[#quads + 1] = q
			end
			open = {}
			for i = #quads - #runs + 1, #quads do open[#open + 1] = quads[i] end
			prevSig = runs
		end
	end
	render.PushRenderTarget(p.slot.bed)
	render.SetMaterial(GPU.Blit())
	GPU.Quads(R, R, quads)
	render.PopRenderTarget()
	CoarseFrom(p, fh, R, false)
	local hmin, hmax = math.huge, -math.huge
	for k = 0, R * R - 1 do
		local h = fh[k]
		if h then
			if h < hmin then hmin = h end
			if h > hmax then hmax = h end
		end
	end
	return #quads, hmin, hmax
end

S.solidCells = S.solidCells or {}
S.emptyCells = S.emptyCells or {}

local function SmoothGrid(p)
	local M, N = S.PROBE, S.BED
	local st = M / N
	local pr = p.probe
	local mid, nrm = {}, {}
	for y = 0, N do
		for x = 0, N do
			local k = (y * st) * (M + 1) + x * st
			mid[y * (N + 1) + x] = pr.h[k] or 0
			nrm[y * (N + 1) + x] = { pr.u[k] or 0, pr.v[k] or 0 }
		end
	end
	local dev = 0
	for y = 0, M do
		for x = 0, M do
			if x % st ~= 0 or y % st ~= 0 then
				local h = pr.h[y * (M + 1) + x]
				if h then
					local cx, cy = math.min(math.floor(x / st), N - 1), math.min(math.floor(y / st), N - 1)
					local fx, fy = x / st - cx, y / st - cy
					local a, b = mid[cy * (N + 1) + cx], mid[cy * (N + 1) + cx + 1]
					local c, d = mid[(cy + 1) * (N + 1) + cx], mid[(cy + 1) * (N + 1) + cx + 1]
					local hi = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
					dev = math.max(dev, math.abs(h - hi))
				end
			end
		end
	end
	return mid, nrm, dev
end
S.SMOOTH_DEV = 0.08

local function EmptyPatch(p, solid)
	G.DiagCount(solid and "patch: probe found solid (removed)" or "patch: probe found no surface (removed)")
	if solid then S.solidCells[p.key] = CurTime() + 120 else S.emptyCells[p.key] = CurTime() + 8 end
end

local function SetFlat(p, h0)
	GPU.ClearTo(p.slot.bed, h0, 1, 0, 0)
	p.flat, p.relief = true, false
	p.meshKind, p.cMid, p.cNrm = "quad", nil, nil
	p.cMax, p.cMin = nil, nil
	p.bedH0 = h0
	p.probe = nil
	p.meshDirty = true
end

local function FinishProbe(p)
	local kind, h0, solid = ProbeClassify(p)
	if kind == "empty" then EmptyPatch(p, solid) return false end
	if kind == "flat" then SetFlat(p, h0) return true end
	p.flat, p.relief = false, false
	p.meshKind, p.cMid, p.cNrm = nil, nil, nil
	UploadProbe(p)
	if kind == "fine" then
		S.bedJobs[p.key] = { p = p, fine = true, k = 0, fh = {}, fu = {}, fv = {}, ents = p.groundEnts or {} }
		p.relief = true
		p.meshKind = "relief"
	else
		local mid, nrm, dev = SmoothGrid(p)
		if dev > S.SMOOTH_DEV then
			p.relief = true
			p.meshKind = "relief"
		else
			p.meshKind = "surf"
			p.cMid, p.cNrm = mid, nrm
		end
	end
	p.probe = nil
	p.forceDirty = true
	p.meshDirty = true
	return true
end

local function StartBed(p)
	local kind, h0, solid = ProbeCoarse(p)
	if kind == "empty" then EmptyPatch(p, solid) p.probe = nil return false end
	if kind == "flat" then SetFlat(p, h0) return true end
	ProbeRest(p, math.huge)
	return FinishProbe(p)
end

local function RunBedJobs(tEnd)
	local R, P = S.BEDRES, S.PATCH_UNITS
	for key, job in pairs(S.bedJobs) do
		if SysTime() > tEnd then break end
		local p = job.p
		if S.patches[key] ~= p or not p.slot then
			S.bedJobs[key] = nil
		elseif job.probe then
			BedFilterFor(p)
			if ProbeRest(p, tEnd) then
				local ok = FinishProbe(p)
				if S.bedJobs[key] == job then S.bedJobs[key] = nil end
				if not ok then S.RemovePatch(key) end
			end
		else
			local fh, fu, fv = job.fh, job.fu, job.fv
			local n = R * R
			local k = job.k
			BedFilterFor(p)
			local c = 0
			while k < n do
				local x, y = k % R, (k - k % R) / R
				local h, nu, nv = BedSample(p, (x + 0.5) / R * P, (y + 0.5) / R * P, job.ents)
				if h then fh[k], fu[k], fv[k] = h, nu, nv else fh[k], fu[k], fv[k] = false, nu and 1 or 0, 0 end
				k = k + 1
				c = c + 1
				if c % 32 == 0 and SysTime() > tEnd then break end
			end
			job.k = k
			if k >= n then
				S.bedJobs[key] = nil
				p.groundEnts = next(job.ents) and job.ents or nil
				local _, hmin, hmax = UploadFine(p, fh, fu, fv)
				if hmax >= hmin and hmax - hmin < 0.05 then
					p.relief, p.meshKind, p.bedH0 = false, "quad", (hmin + hmax) * 0.5
				else
					p.relief, p.meshKind = true, "relief"
				end
				p.forceDirty = true
				p.meshDirty = true
				S.FreeMeshes(p)
			end
		end
	end
end
S.RunBedJobs = RunBedJobs

local WHITE = "vgui/white"
local function BumpUV(p, pos)
	local m = p.bmap
	if not m then return 0, 0 end
	return pos:Dot(m.s) + m.so, pos:Dot(m.t) + m.to
end

local function ForceBake(p)
	local s = p.slot
	local g = -(GetConVarNumber("sv_gravity") or 600) * G.UNITS_TO_CM
	local texCm = S.PATCH_UNITS / s.res * G.UNITS_TO_CM
	GPU.SetC(s.pforce, 0, 0, 0, g, G.cv.unevenness:GetFloat())
	local P = S.PATCH_UNITS
	local o, U, V, n = p.origin, p.U, p.V, p.N
	local kind = (G.cv.surfbump:GetBool() and p.bumpTex and p.bmap) and p.bumpKind or 0
	local bu0, bv0 = BumpUV(p, o)
	local bu1, bv1 = BumpUV(p, o + U * P)
	local bu2, bv2 = BumpUV(p, o + V * P)
	GPU.SetC(s.pforce, 1, 1 / S.BEDRES, texCm, bu0, bv0)
	GPU.SetC(s.pforce, 3, bu1 - bu0, bu2 - bu0, bv1 - bv0, bv2 - bv0)
	s.pforce:SetTexture("$texture1", kind > 0 and p.bumpTex or WHITE)
	local mid = G.SurfaceMatId[p.surfName or "sealed"] or 0
	local strength = math.Clamp(G.SurfaceMatValue(mid, "relief") / 0.9, 0.15, 1)
	GPU.SetC(s.pforce, 2, p.i * s.res, p.j * s.res, s.res, kind > 0 and (kind + 0.99 * strength) or 0)
	p.forceDirty = nil
	render.PushRenderTarget(s.force)
	render.Clear(0, 0, 0, 0)
	render.SetMaterial(s.pforce)
	GPU.FullQuad(s.res, s.res,
		function(ci, u, v) local w = o + U * (u * P) + V * (v * P) return { w.x, w.y, w.z, 1 } end,
		{ n.x, n.y, n.z, 0 })
	render.PopRenderTarget()
end

function S.PlaneGravity(p)
	local g = Vector(0, 0, -(GetConVarNumber("sv_gravity") or 600) * G.UNITS_TO_CM)
	local an = g:Dot(p.N)
	local gt = g - p.N * an
	return gt:Dot(p.U), gt:Dot(p.V), an
end

function S.CheckGroundEnts()
	local now = CurTime()
	if (S.nextGroundCheck or 0) > now then return end
	S.nextGroundCheck = now + 0.05
	local function moved(ents)
		for e, pa in pairs(ents) do
			if not IsValid(e) then return true end
			if e:GetPos():DistToSqr(pa[1]) > 0.25 then return true end
			local a = e:GetAngles()
			if math.abs(math.AngleDifference(a.p, pa[2].p)) + math.abs(math.AngleDifference(a.y, pa[2].y)) + math.abs(math.AngleDifference(a.r, pa[2].r)) > 0.5 then return true end
		end
		return false
	end
	for key, p in pairs(S.patches) do if p.groundEnts and moved(p.groundEnts) then S.RemovePatch(key) end end
	for key, a in pairs(S.after) do if a.groundEnts and moved(a.groundEnts) then S.RemoveAfter(key) end end
end

local function GeoNums(p)
	local N, U, V, o = p.N, p.U, p.V, p.origin
	p.gnx, p.gny, p.gnz = N.x, N.y, N.z
	p.gux, p.guy, p.guz = U.x, U.y, U.z
	p.gvx, p.gvy, p.gvz = V.x, V.y, V.z
	p.gox, p.goy, p.goz = o.x, o.y, o.z
	p.geo = true
end
S.GeoNums = GeoNums
local mru = nil
local floor, huge = math.floor, math.huge
local function FindPatch(pos, n)
	local P = S.PATCH_UNITS
	local px, py, pz = pos.x, pos.y, pos.z
	local nx, ny, nz = n.x, n.y, n.z
	local live = S.patches
	local m = mru
	if m and live[m.key] == m and m.gnx * nx + m.gny * ny + m.gnz * nz > 0.9 then
		local rx, ry, rz = px - m.gox, py - m.goy, pz - m.goz
		local h = rx * m.gnx + ry * m.gny + rz * m.gnz
		if h > -5 and h < 5 then
			local u, v = rx * m.gux + ry * m.guy + rz * m.guz, rx * m.gvx + ry * m.gvy + rz * m.gvz
			if u >= 0 and u < P and v >= 0 and v < P then return m, m end
		end
	end
	local cx, cy, cz = floor(px / CELL), floor(py / CELL), floor(pz / CELL)
	local cells = S.cells
	for k = 0, 26 do
		local dx, dy, dz = 0, 0, 0
		if k > 0 then
			local q = k <= 13 and k - 1 or k
			dx, dy, dz = q % 3 - 1, floor(q / 3) % 3 - 1, floor(q / 9) - 1
		end
		local c = cells[CKey(cx + dx, cy + dy, cz + dz)]
		if c then
			for p in pairs(c) do
				if p.impacts and live[p.key] == p then
					if not p.geo then GeoNums(p) end
					if p.gnx * nx + p.gny * ny + p.gnz * nz > 0.9 then
						local rx, ry, rz = px - p.gox, py - p.goy, pz - p.goz
						local h = rx * p.gnx + ry * p.gny + rz * p.gnz
						if h > -5 and h < 5 then
							local u, v = rx * p.gux + ry * p.guy + rz * p.guz, rx * p.gvx + ry * p.gvy + rz * p.gvz
							if u >= 0 and u < P and v >= 0 and v < P then mru = p return p, p end
						end
					end
				end
			end
		end
	end
	local ref, refD = nil, huge
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		local c = cells[CKey(cx + dx, cy + dy, cz + dz)]
		if c then
			for p in pairs(c) do
				if not p.geo then GeoNums(p) end
				if p.gnx * nx + p.gny * ny + p.gnz * nz > 0.9 then
					local rx, ry, rz = px - p.gox, py - p.goy, pz - p.goz
					local h = rx * p.gnx + ry * p.gny + rz * p.gnz
					if h > -5 and h < 5 then
						local u, v = rx * p.gux + ry * p.guy + rz * p.guz, rx * p.gvx + ry * p.gvy + rz * p.gvz
						local inside = u >= 0 and u < P and v >= 0 and v < P
						local dd = inside and 0 or (math.max(0, -u, u - P) + math.max(0, -v, v - P))
						if dd < refD then ref, refD = p, dd end
					end
				end
			end
		end
	end end end
	return nil, ref
end

local function SnapNormal(n)
	if n.z > 0.97 then return Vector(0, 0, 1) end
	if n.z < -0.97 then return Vector(0, 0, -1) end
	if math.abs(n.z) < 0.03 then local h = Vector(n.x, n.y, 0) h:Normalize() return h end
	return n
end

local slOut = {}
local slTr = { mask = MASK_SOLID, output = slOut }
local function Sliver(pos, n, U, V)
	slTr.filter = S.GroundFilter
	local function on(d)
		local o = pos + d * 1.25
		slTr.start, slTr.endpos = o + n * 1.5, o - n * 1.5
		util.TraceLine(slTr)
		return slOut.Hit and not slOut.StartSolid and not slOut.HitSky and slOut.HitNormal:Dot(n) > 0.55
	end
	return not ((on(U) or on(-U)) and (on(V) or on(-V)))
end

function S.AssignBump(p)
	if p.bumpDone then return end
	local B = G.BspTex
	if not G.cv.surfbump:GetBool() or not B then p.bumpDone = true return end
	if B.state == nil then B.Start() end
	if B.state == "loading" then return end
	p.bumpDone = true
	if B.state ~= "ready" or not p.albedoTex then return end
	local m = Material(p.albedoTex)
	if not m or m:IsError() then return end
	local bt = m:GetTexture("$bumpmap")
	local kind = ((m:GetInt("$ssbump") or 0) ~= 0) and 2 or 1
	-- another addon (gmod-dx12's remaster) may have a better normal map in the same UVs: (ITexture, kind)
	local alt, altKind = hook.Run("GHMPB_SurfaceNormal", p.albedoTex, m)
	if alt then bt, kind = alt, altKind or 1 end
	if not bt or bt:IsError() then return end
	local ti = B.Lookup(p.center, p.N, p.albedoTex)
	if not ti then G.DiagCount("patch: surface normal map - no face found") return end
	p.bumpTex, p.bumpKind, p.bmap = bt, kind, ti
	p.meshDirty = true
	p.forceDirty = true
	G.DiagCount("patch: surface normal map")
end
GPU.texCache = GPU.texCache or setmetatable({}, { __mode = "k" })
local function SetBump(mat, p)
	local t = (G.cv.surfbump:GetBool() and p.bumpTex) or WHITE
	if GPU.texCache[mat] ~= t then GPU.texCache[mat] = t mat:SetTexture("$texture3", t) end
end

function S.GetPatch(pos, normal, create, surfTex, surfKind)
	local n = normal:GetNormalized()
	local found, ref = FindPatch(pos, n)
	if found then return found, found.key end
	if ref then n = ref.N else n = SnapNormal(n) end
	local dist = ref and ref.N:Dot(ref.origin) or math.Round(n:Dot(pos) * 2) / 2
	local key0 = ref and ref.plane or PlaneKey(n, dist)
	local U, V
	if ref then U, V = ref.U, ref.V else U, V = Basis(n) end
	local P = S.PATCH_UNITS
	local i = math.floor(pos:Dot(U) / P)
	local j = math.floor(pos:Dot(V) / P)
	local key = key0 .. "|" .. i .. "|" .. j
	local p = S.patches[key]
	if p or not create then return p, key end
	if (S.solidCells[key] or 0) > CurTime() then G.DiagCount("patch: square inside solid") return nil end
	if (S.emptyCells[key] or 0) > CurTime() then G.DiagCount("patch: square without surface (remembered)") return nil end
	if not G.cv.pools:GetBool() then return nil end
	if not ref and Sliver(pos, n, U, V) then G.DiagCount("patch: face too narrow (sliver)") S.emptyCells[key] = CurTime() + 8 return nil end
	G.DiagCount("patch: created")
	if Count() >= G.Budget.Caps().patches then Evict() end
	Shared()
	local origin = n * dist + U * (i * P) + V * (j * P)
	local slot = TakeSlot()
	p = { key = key, plane = key0, i = i, j = j, N = n, U = U, V = V, origin = origin,
		center = origin + U * (P * 0.5) + V * (P * 0.5), slot = slot, cur = 1, impacts = {},
		touched = CurTime(), wetUntil = 0, simAcc = 0, hasBlood = false, oxy = 0.75, btype = 0 }
	if not slot then p.needSlot = true G.DiagCount("patch: waiting for video memory (slot)") end
	if type(surfKind) == "number" then surfKind = G.MatTypeSurface[surfKind] end
	p.surfName = (surfKind and G.Surface[surfKind]) and surfKind or "sealed"
	p.surf = G.Surface[p.surfName] or G.Surface.sealed
	p.albedoTex = surfTex
	p.albedo = S.Albedo(surfTex)
	S.AssignBump(p)
	p.pendingBake = true
	p.water = G.Water and G.Water.PatchWater(p) or nil
	S.patches[key] = p
	S.IndexAdd(p)
	return p, key
end

S.planeTypes = S.planeTypes or {}
-- (1.26.10e) GHM: "raise it" - the blood types (two per region: SC1.y = type A + 8 * type B) are kept per floor patch now
-- (40 u, ~76 cm), not per 4 x 4 patches (160 u, ~3 m). A third blood type was drawn in the colour of one of the two a region
-- already held; now that only happens when three types land on the same patch. Flows across patches are mapped by Remap
S.TYPE_REGION = 1
function S.MatId(kind)
	if not G.cv.matlook:GetBool() then return 0 end
	return G.SurfaceMatId[kind or "sealed"] or 0
end

function S.TypeKey(p)
	local k = p.tkey
	if k then return k end
	local R = S.TYPE_REGION
	k = p.plane .. "#" .. math.floor(p.i / R) .. "," .. math.floor(p.j / R)
	p.tkey = k
	return k
end
local function NeighbourPair(p, t)
	local R = S.TYPE_REGION
	local ri, rj = math.floor(p.i / R), math.floor(p.j / R)
	local best, openQ
	for di = -1, 1 do
		for dj = -1, 1 do
			if di ~= 0 or dj ~= 0 then
				local q = S.planeTypes[p.plane .. "#" .. (ri + di) .. "," .. (rj + dj)]
				if q then
					if q.a == t then return q end
					if q.b == t then best = best or q
					elseif q.b == nil then openQ = openQ or q end
				end
			end
		end
	end
	if not best and openQ then
		openQ.b = t
		return openQ
	end
	return best
end
function S.TypeSlot(p, t, vol)
	t = t or 0
	vol = math.max(vol or 0, 0)
	local key = S.TypeKey(p)
	local pt = S.planeTypes[key]
	if not pt then
		local q = NeighbourPair(p, t)
		pt = q and { a = q.a, b = q.b, va = 0, vb = 0 } or { a = t, va = 0, vb = 0 }
		S.planeTypes[key] = pt
	end
	local alt
	if t == pt.a then alt = false
	elseif pt.b == nil or t == pt.b then pt.b = t alt = true
	else
		if pt.vb < 0.1 * pt.va then pt.b = t end
		alt = true
	end
	if alt then pt.vb = pt.vb + vol else pt.va = pt.va + vol end
	return alt
end
function S.PairCode(plane, fallback)
	local pt = S.planeTypes[plane]
	if not pt then
		local fb = fallback or 0
		return fb + 8 * fb
	end
	return pt.a + 8 * (pt.b or pt.a)
end
function S.FrothOK(p)
	local ax, ay = S.PlaneGravity(p)
	return ax * ax + ay * ay <= 40000
end
-- (1.26.6) wetMul: fresh blood looks wetter (G.FreshWet); the shaders take a wetness of up to 3.1
-- (1.26.9d) froth amount for the live layer (bubbles on fresh pools): floors and gentle slopes, new shader pack only
function S.FrothAmt(p)
	if not (p and G.cv.froth and G.NewShaders and G.NewShaders() and S.FrothOK(p)) then return 0 end
	return math.Clamp(G.cv.froth:GetFloat(), 0, 2)
end
function S.LookPair(pair, p, static, wetMul)
	local pool = math.min(math.floor(math.Clamp(G.cv.poollook:GetFloat(), 0, 2) * (wetMul or 1) * 10 + 0.5), 31)
	local froth = static and 0 or math.floor(S.FrothAmt(p) * 10 + 0.5)
	return pair + 64 * (pool + 32 * froth)
end

function S.MainType(plane, fallback)
	local pt = S.planeTypes[plane]
	if not pt then return fallback or 0 end
	return (pt.b and pt.vb > pt.va) and pt.b or pt.a
end

local function SplatReach(radiusU, vel, n, stretch)
	local sp = vel:Length()
	local sinA = sp > 1e-3 and math.abs(vel:Dot(n)) / sp or 1
	local e = math.min(math.Clamp(1 / math.max(sinA, 0.12), 1, 8) * math.Clamp(stretch or 1, 1, 8), 10)
	return math.min(radiusU * (2.6 * e + 5.0) + 0.5, S.PATCH_UNITS * 0.9)
end

local clipOut = {}
local clipTr = { mask = MASK_SOLID, output = clipOut }
local function OnSurfAt(q, n, refP)
	clipTr.filter = S.GroundFilter
	clipTr.start = q + n * 2.5
	clipTr.endpos = q - n * 2.5
	util.TraceLine(clipTr)
	return clipOut.Hit and not clipOut.StartSolid and not clipOut.HitSky
		and clipOut.HitNormal:Dot(n) > 0.75 and math.abs((clipOut.HitPos - refP):Dot(n)) < 1.25
end

function S.ClipStroke(pos, n, vel, r)
	if not pos or not n or not r or r <= 0.1 then return pos, vel, r end
	local v = vel or vector_origin
	local vt = v - n * v:Dot(n)
	local L = vt:Length()
	local dir
	if L > 0.05 then
		dir = vt * (1 / L)
	else
		local u = math.abs(n.z) < 0.9 and Vector(0, 0, 1):Cross(n) or Vector(1, 0, 0):Cross(n)
		u:Normalize()
		dir = u
	end
	local side = n:Cross(dir)
	side:Normalize()
	local p0 = Vector(pos)
	local p1 = p0 + dir * L
	-- Check front cap (p0 - dir * r) and back cap (p1 + dir * r)
	if not OnSurfAt(p0 - dir * r, n, pos) then
		local best = 0
		for f = 0.2, 1.0, 0.2 do
			if OnSurfAt(p0 - dir * (r * (1 - f)), n, pos) then best = f break end
		end
		if best == 0 then
			-- Even p0 is at the very lip; pull p0 inward toward p1
			local pull = math.min(r * 0.9, math.max(L * 0.6, r * 0.5))
			p0 = p0 + dir * pull
			L = math.max(0, L - pull)
		else
			local shift = r * best * 0.85
			p0 = p0 + dir * shift
			L = math.max(0, L - shift * 0.5)
		end
	end
	p1 = p0 + dir * L
	if not OnSurfAt(p1 + dir * r, n, pos) then
		local best = 0
		for f = 0.2, 1.0, 0.2 do
			if OnSurfAt(p1 + dir * (r * (1 - f)), n, pos) then best = f break end
		end
		local trim = best == 0 and r * 0.9 or (r * best * 0.85)
		if L > trim then
			L = L - trim
		else
			p0 = p0 - dir * (trim - L)
			L = 0
		end
	end
	-- Check lateral overhang (+/- side * r)
	local latP = OnSurfAt(p0 + side * r, n, pos)
	local latN = OnSurfAt(p0 - side * r, n, pos)
	if not latP and latN then
		p0 = p0 - side * (r * 0.45)
		r = r * 0.82
	elseif not latN and latP then
		p0 = p0 + side * (r * 0.45)
		r = r * 0.82
	elseif not latP and not latN then
		r = r * 0.65
	end
	return p0, dir * L, r
end

-- (1.26.9b) WET GROUND: where blood has landed in the last while, on a coarse grid of 4 u (7.6 cm) cells, as the volume
-- that is still wet there (it fades with the drying time). A drop that lands where the ground already holds a wet film
-- (about 0.1 mm and more) falls into wet blood: it merges with it and leaves no dried stain of its own. Before, every
-- landing drop turned a fifth to over a third of itself into dried stain at once (the stain share of a splat on dry
-- ground), also in the middle of a pool, so where a lot of blood kept hitting the same place a dried crust built up
-- under the wet blood: it lost its shine and turned brown and patchy instead of looking like a fresh pool.
S.wet = S.wet or {}
S.wetN = S.wetN or 0
local WET_CELL = 4
local WET_AREA = (WET_CELL * 19.05) ^ 2       -- mm2 of one cell
local function WetKey(x, y, z)
	return (math.floor(x / WET_CELL) + 8192) + (math.floor(y / WET_CELL) + 8192) * 16384
		+ (math.floor(z / WET_CELL) + 8192) * 268435456
end
-- how long a film stays wet enough to merge into (s): half the drying time, at least 8 s
function S.WetTau()
	return math.max((G.DryTime and G.DryTime() or 240) * 0.5, 8)
end
local function WetVol(c, now, tau)
	return c.v * math.exp(-math.max(now - c.t, 0) / tau)
end
local function WetCellAdd(key, v, now, tau)
	local c = S.wet[key]
	if c then
		c.v, c.t = WetVol(c, now, tau) + v, now
	else
		S.wet[key] = { v = v, t = now }
		S.wetN = S.wetN + 1
	end
end
-- blood (mm3) arriving at pos; on floors, pools spread it over the cells their puddle covers (a film of ~1.5 mm)
function S.WetAdd(pos, volume, radiusU, now, normal)
	if not pos or not volume or volume <= 0 then return end
	local tau = S.WetTau()
	if S.wetN > 6000 then
		for k, c in pairs(S.wet) do if WetVol(c, now, tau) < 5 then S.wet[k] = nil S.wetN = S.wetN - 1 end end
	end
	local r = math.max(radiusU or 0, math.sqrt(volume / (math.pi * 1.5)) / 19.05)
	if r <= WET_CELL * 0.5 or not normal or normal.z < 0.7 then
		WetCellAdd(WetKey(pos.x, pos.y, pos.z), volume, now, tau)
		return
	end
	r = math.min(r, WET_CELL * 4)
	local n = math.ceil(r / WET_CELL)
	local cells = {}
	for i = -n, n do for j = -n, n do
		if (i * i + j * j) * WET_CELL * WET_CELL <= r * r + WET_CELL * WET_CELL * 0.5 then cells[#cells + 1] = { i, j } end
	end end
	local share = volume / #cells
	for _, c in ipairs(cells) do
		WetCellAdd(WetKey(pos.x + c[1] * WET_CELL, pos.y + c[2] * WET_CELL, pos.z), share, now, tau)
	end
end
-- 0..1: how surely pos lies in wet blood (0 = dry ground, 1 = a wet film of 0.2 mm or more)
function S.WetAt(pos, now)
	if not pos then return 0 end
	local c = S.wet[WetKey(pos.x, pos.y, pos.z)]
	if not c then return 0 end
	local hmm = WetVol(c, now or CurTime(), S.WetTau()) / WET_AREA
	local x = math.Clamp((hmm - 0.05) / 0.15, 0, 1)
	return x * x * (3 - 2 * x)
end
-- (1.26.9b) the age of blood: how long the freshness of blood that arrived earlier counts against blood arriving now (s):
-- its weight falls to a third over a clotting time. Blood that came in long ago has clotted and dried (the simulation draws
-- that per texel); it should not make a lot of fresh blood landing on the same place look old - dull and darkened - as one
-- volume-weighted mean over all of it did
function S.AgeMemory()
	return math.max(G.CoagTime and G.CoagTime() or 180, 30)
end

function S.Impact(pos, normal, vel, radiusU, volume, kind, spin, stretch, residue, tr, oxy, btype, extra)
	if not G.cv.enable:GetBool() or not G.cv.pools:GetBool() then G.DiagCount("world: impact ignored (ghmpb_pools / ghmpb_enable off)") return false end
	if tr and IsValid(tr.Entity) and not tr.Entity:IsWorld() and not S.IsGround(tr.Entity) then
		if kind == 4 then return false end
		local ek = (kind == 3 or kind == 5 or kind == 7) and 0 or (kind or 0)
		if G.Entities and G.Entities.Impact then
			return G.Entities.Impact(tr.Entity, pos, normal, vel, radiusU, volume, ek, spin, stretch, residue, nil,
				{ oxy = oxy, btype = btype, K = extra and extra.K, flags = extra and extra.flags, spines = extra and extra.spines })
		end
	end
	if (kind == 3 or kind == 5 or kind == 7) and pos and normal then
		pos, vel, radiusU = S.ClipStroke(pos, normal, vel, radiusU)
	end
	if (kind or 0) == 1 and normal and normal.z > 0.45 and not (extra and extra.seepStep) and ((radiusU or 0) > 0.90 or (volume or 0) > 200) then
		S.SeepPool(pos, normal, (volume or 0) * 0.94, math.Clamp((radiusU or 1) * 0.45, 0.48, 1.25), tr, oxy, btype, vel)
		radiusU = math.Clamp((radiusU or 0.5) * 0.22, 0.22, 0.38)
		volume = math.min((volume or 0) * 0.06, 28)
	end
	if (kind or 0) == 0 and vel and normal and normal.z > 0.85 and (volume or 0) >= 2 and not (extra and extra.noWave) then
		S.DripWave(pos, normal, vel, volume)
	end
	if (kind or 0) == 0 and vel and G.U and G.U.SplatShape then vel, stretch = G.U.SplatShape(vel, normal, stretch) end
	local surfTex = tr and tr.HitTexture
	if tr and IsValid(tr.Entity) and not tr.Entity:IsWorld() then
		local mats = tr.Entity:GetMaterials()
		surfTex = tr.Entity:GetMaterial() ~= "" and tr.Entity:GetMaterial() or (mats and mats[#mats]) or surfTex
	end
	local kindName = tr and G.SurfaceKindOf(tr) or "sealed"
	local sf = G.Surface[kindName] or G.Surface.sealed
	local carries = (kind or 0) <= 2 or kind == 6
	if sf.nostain then
		G.DiagCount("world: impact on a water / slime surface (no stain)")
		if carries and G.Water then G.Water.Enter(pos + normal * 0.3, vel, volume, btype, oxy) end
		return true
	end
	if bit.band(util.PointContents(pos + normal * 0.5), bit.bor(CONTENTS_WATER, CONTENTS_SLIME)) ~= 0 then
		G.DiagCount("world: impact under water (no stain)")
		if carries and G.Water then G.Water.Enter(pos + normal * 0.5, vel, volume, btype, oxy) end
		return true
	end
	if sf.drain and normal.z > 0.3 and (volume or 0) > 0 and (kind == 0 or kind == 1 or kind == 6) then
		local through = volume * sf.drain
		volume = volume - through
		local below = pos - normal * 2
		for _ = 1, 4 do
			if bit.band(util.PointContents(below), CONTENTS_SOLID) == 0 then break end
			below = below - normal * 2
		end
		if through > 1500 then
			local tr2 = util.TraceLine({ start = below, endpos = below - Vector(0, 0, 600), mask = MASK_SOLID_BRUSHONLY })
			if tr2.Hit and not tr2.StartSolid and not tr2.HitSky then
				S.Impact(Vector(tr2.HitPos), Vector(tr2.HitNormal), Vector(0, 0, -60), math.max(radiusU, 1), through - 1500, 1, 0, 1, 0, tr2, oxy, btype)
			end
			through = 1500
		end
		if through > 3 and G.Particles and G.Particles.Drips then
			G.Particles.Drips(below, Vector(vel.x * 0.3, vel.y * 0.3, math.min(vel.z * 0.4, -20)), through, nil, oxy, btype)
		end
		if volume < 1 then return true end
	end
	local p = S.GetPatch(pos, normal, true, surfTex, kindName)
	if not p then G.DiagCount("world: impact without a patch") return false end
	if (kind == 0 or kind == 1 or kind == 3 or kind == 6) and G.Runs and (volume or 0) > 1 then
		local taken = G.Runs.Feed(p, pos, volume, radiusU, kind, tr, oxy, btype)
		if taken > 0 then
			volume = volume - taken
			if volume < 0.05 then return true end
		end
	end
	if kind == 1 and G.Tendrils and (volume or 0) >= 20 then
		local taken = G.Tendrils.Feed(p, pos, volume, radiusU, tr, oxy, btype)
		if taken > 0 then volume = volume - taken end
	end
	G.DiagCount("world: impacts painted")
	if carries and (volume or 0) >= 30 and G.Flies and G.Flies.Note then G.Flies.Note(pos, volume, radiusU, p.center) end
	local now = CurTime()
	-- 1.26.0: a patch that starts as pooling blood (kind 1) fades in instead of popping up (S.DrawOverlays)
	if not p.firstT then p.firstT, p.firstKind = now, kind or 0
	elseif (kind or 0) ~= 1 then p.firstKind = 0 end
	local seed = math.random()
	local k0 = kind or 0
	-- (1.26.9c) splats: a fresh drop on a floor keeps only a small stain share (about 5 %, a quarter of what the caller
	-- asks for); the rest is wet blood that dries on the drying clock like the pool next to it. Before, every splat was made
	-- at least 38 % dried stain the moment it landed, so spatter and droplets looked dark and dry beside a fresh, wet pool.
	-- On walls the caller's share is kept (no 38 % floor any more): the stain holds the forensic shape where the wet part
	-- runs down
	local resEff
	if k0 == 1 then
		resEff = math.Clamp(residue or 0.02, 0, 0.12)
	elseif k0 == 3 or k0 == 4 or k0 == 5 or k0 == 7 then
		resEff = residue or 0.25
	elseif k0 == 0 then
		local r0 = math.Clamp(residue or 0.22, 0, 0.45)
		local newSh = G.NewShaders and G.NewShaders()
		resEff = (normal and normal.z > 0.7 and newSh) and math.min(r0, 0.22) * 0.25 or (newSh and r0 or math.max(residue or 0.38, 0.38))
	else
		resEff = math.max(residue or 0.38, 0.38)
	end
	-- (1.26.9b) a drop that falls into wet blood merges with it: (almost) no stain of its own, and its splash number is not
	-- sent (the shaders take a stain share of a fifth from every splat that carries one)
	local intoWet = (k0 == 0 and pos) and S.WetAt(pos, now) or 0
	local splK = extra and extra.K
	if intoWet > 0 then
		resEff = resEff + (0.02 - resEff) * intoWet
		if intoWet > 0.5 then splK = nil end
		S.mergedDrops = (S.mergedDrops or 0) + 1
	end
	if k0 ~= 4 and k0 ~= 6 and pos then S.WetAdd(pos, (volume or 0) * (1 - resEff), radiusU, now, normal) end
	local rec
	local function add(pp)
		local ppAlt = kind ~= 4 and S.TypeSlot(pp, btype, volume) or false
		pp.touched = now
		S.ageDirty = true
		if (volume or 0) > 10 then pp.soakT0 = now end
		if k0 ~= 1 then pp.firstKind = 0 end
		pp.vol = (pp.vol or 0) + (volume or 0)
		-- (1.26.6) the (volume-weighted) time its blood arrived: blood darkens and loses its shine as it ages, and a few
		-- fresh drops on an old pool hardly make it look fresh again
		if kind ~= 4 and (volume or 0) > 0 then
			local w0 = pp.ageVol or 0
			-- (1.26.9b) the blood that came in earlier counts less the longer ago it arrived (S.AgeMemory): a lot of fresh
			-- blood on a patch that already held blood looks fresh, not as old as the mean of all of it
			if w0 > 0 and pp.ageT then w0 = w0 * math.exp(-math.max(now - pp.ageT, 0) / S.AgeMemory()) end
			pp.bornT = (w0 > 0 and pp.bornT) and (pp.bornT * w0 + now * volume) / (w0 + volume) or now
			pp.ageVol = math.min(w0 + volume, 1e7)
			pp.ageT = now
		end
		pp.wetUntil = math.max(pp.wetUntil, now + G.DryTime() / G.DryMult(pp.surfName) * 1.4 + 5)
		-- (1.26.9c) the patch's oxygenation is the volume-weighted mix of the blood that came in (blood that came in long ago
		-- counts less): the settled layer of a pool fed by two bodies, or by an arterial and a venous wound, keeps a mixed red,
		-- not the colour of whatever landed last
		if oxy then
			local v = math.max(volume or 0, 1)
			local w0 = pp.oxyW or 0
			if w0 > 0 and pp.oxyT then w0 = w0 * math.exp(-math.max(now - pp.oxyT, 0) / 90) end
			pp.oxy = ((pp.oxy or oxy) * w0 + oxy * v) / (w0 + v)
			pp.oxyW, pp.oxyT = math.min(w0 + v, 1e7), now
		end
		if extra and extra.wound and (kind or 0) == 1 then pp.woundPool = true end
		-- (1.26.9d) a patch a bleeding body keeps feeding: its blood stays mobile (see GPU.SimParams fed)
		if extra and extra._seep then pp.fedT = now end
		if btype ~= nil and kind ~= 4 and (volume or 0) > 0 then
			local tv = pp.tvol or {}
			pp.tvol = tv
			tv[btype] = (tv[btype] or 0) + volume
			local best, bv = pp.btype, -1
			for t, v in pairs(tv) do if v > bv then best, bv = t, v end end
			pp.btype = best
		elseif not pp.tvol then
			pp.btype = btype or pp.btype
		end
		pp.bakeNow = nil
		if #pp.impacts < 512 then
			local im = rec
			if not im or im.normal ~= pp.N or im.alt ~= ppAlt or not oxy then
				im = { wpos = pos, normal = pp.N, vel = vel, radius = radiusU, volume = volume,
					kind = k0, spin = spin or 0, stretch = stretch or 1, residue = resEff, seed = seed,
					spines = extra and extra.spines, K = splK, flags = extra and extra.flags, alt = ppAlt,
					oxy = oxy or pp.oxy }
				if not rec then rec = im end
			end
			pp.impacts[#pp.impacts + 1] = im
		end
	end
	add(p)
	if (kind == 0 or kind == 1) and (volume or 0) > 150 and G.Elem and G.Elem.NoteFresh then G.Elem.NoteFresh(p, pos, volume) end
	local reach
	if kind == 1 then
		local poolR = math.sqrt((p.vol or 0) / (math.pi * 2.0)) / 19.05 + 2
		reach = math.min(math.max(radiusU * 2.6 + 0.5, poolR), S.PATCH_UNITS * 0.9)
	elseif kind == 6 then reach = math.min(radiusU + 0.5, S.PATCH_UNITS * 0.9)
	elseif (kind or 0) >= 3 then reach = math.min(radiusU * 1.4 + vel:Length() + 0.5, S.PATCH_UNITS * 0.9)
	else reach = SplatReach(radiusU, vel, p.N, stretch) end
	local P = S.PATCH_UNITS
	if not p.geo then GeoNums(p) end
	local rx, ry, rz = pos.x - p.gox, pos.y - p.goy, pos.z - p.goz
	local lu = rx * p.gux + ry * p.guy + rz * p.guz
	local lv = rx * p.gvx + ry * p.gvy + rz * p.gvz
	if lu < reach or lu > P - reach or lv < reach or lv > P - reach then
		local live = S.patches
		for du = -1, 1 do
			for dv = -1, 1 do
				if du ~= 0 or dv ~= 0 then
					local nearU = (du == -1 and lu < reach) or (du == 1 and lu > P - reach) or du == 0
					local nearV = (dv == -1 and lv < reach) or (dv == 1 and lv > P - reach) or dv == 0
					if nearU and nearV then
						local q = live[p.plane .. "|" .. (p.i + du) .. "|" .. (p.j + dv)]
						if not q then
							local tu = du == 0 and lu or (du < 0 and -1 or P + 1)
							local tv = dv == 0 and lv or (dv < 0 and -1 or P + 1)
							q = S.GetPatch(p.origin + p.U * tu + p.V * tv, p.N, true, surfTex, kindName)
						end
						if q and q ~= p then add(q) end
					end
				end
			end
		end
	end
	return true
end

S.seepList = S.seepList or {}
function S.SeepPool(pos, normal, volume, targetR, tr, oxy, btype, vel)
	if not pos or not normal or (volume or 0) <= 1 then return end
	local now = CurTime()
	for i = #S.seepList, 1, -1 do
		local s = S.seepList[i]
		if s.n:Dot(normal) > 0.9 and s.pos:DistToSqr(pos) < 16 and s.btype == (btype or 0) then
			local rem = math.max(s.vol - s.emitted, 0) + volume
			s.vol = rem
			s.emitted = 0
			s.t0 = now - math.min(now - s.t0, 0.35)
			s.dur = math.Clamp(1.35 + math.sqrt(rem) * 0.020, 1.35, 4.2)
			s.rMax = math.Clamp(math.max(s.rMax, targetR or 0.85), 0.45, 1.30)
			return
		end
	end
	if #S.seepList >= 48 then table.remove(S.seepList, 1) end
	S.seepList[#S.seepList + 1] = {
		pos = Vector(pos),
		n = Vector(normal),
		vol = volume,
		emitted = 0,
		r0 = 0.26,
		rMax = math.Clamp(targetR or 0.85, 0.45, 1.30),
		t0 = now,
		dur = math.Clamp(1.35 + math.sqrt(volume) * 0.022, 1.35, 4.4),
		lastT = now,
		nextT = now + 0.06,
		tr = tr,
		oxy = oxy or 0.75,
		btype = btype or 0,
		vel = vel and Vector(vel) or vector_origin,
	}
end

local SEEP_EXTRA = { seepStep = true }
function S.StepSeep(now)
	if #S.seepList == 0 then return end
	local U = G.U
	for i = #S.seepList, 1, -1 do
		local s = S.seepList[i]
		if now >= s.nextT then
			local dt = math.max(now - s.lastT, 0.04)
			s.lastT = now
			s.nextT = now + 0.07
			local u = math.Clamp((now - s.t0) / s.dur, 0, 1)
			local w = math.max(6 * u * (1 - u), 0.18)
			local dVol = math.min(s.vol - s.emitted, s.vol * (dt / s.dur) * w)
			if u >= 1 then dVol = s.vol - s.emitted end
			if dVol > 0.2 then
				s.emitted = s.emitted + dVol
				local rCur = s.r0 + (s.rMax - s.r0) * (u ^ 0.65)
				local ang = math.random() * 6.2831853
				local t1 = math.abs(s.n.z) < 0.9 and Vector(0, 0, 1):Cross(s.n) or Vector(1, 0, 0):Cross(s.n)
				t1:Normalize()
				local t2 = s.n:Cross(t1)
				local rdir = t1 * math.cos(ang) + t2 * math.sin(ang)
				local jit = rdir * (rCur * 0.18 * math.random())
				local push = rdir * (8 + 14 * (1 - u)) + s.vel * 0.15
				SEEP_EXTRA.btype = s.btype
				SEEP_EXTRA.oxy = s.oxy
				S.Impact(s.pos + jit, s.n, push, rCur, dVol, 1, 0, 1, 0.02, s.tr, s.oxy, s.btype, SEEP_EXTRA)
			end
			if s.emitted >= s.vol - 0.5 or u >= 1 then
				table.remove(S.seepList, i)
			end
		end
	end
end

function S.Element(pos, R, op, k, path, vol, btype)
	local n = 0
	local now = CurTime()
	local P = S.PATCH_UNITS
	local reach = R + (path and path:Length() or 0) + P * 0.75
	local reach2 = reach * reach
	local seed = math.random()
	for _, p in pairs(S.patches) do
		if p.hasBlood and p.slot and not p.pendingBake and #p.impacts < 500 and p.center:DistToSqr(pos) < reach2 then
			local rel = pos - p.origin
			if math.abs(rel:Dot(p.N)) < math.max(R * 0.7, 12) then
				local alt = false
				if op == 12 and (vol or 0) > 0 then alt = S.TypeSlot(p, btype or G.ACID_TYPE, vol) end
				p.impacts[#p.impacts + 1] = { wpos = pos, normal = p.N, vel = path or Vector(0, 0, 0), radius = R,
					volume = vol or 0, kind = 4, spin = op, stretch = math.Clamp(k, 0, 1), residue = 0, seed = seed,
					alt = alt, oxy = p.oxy }
				if op ~= 13 and op ~= 14 then p.touched = now end
				p.wetUntil = math.max(p.wetUntil, now + 6)
				n = n + 1
			end
		end
	end
	return n
end

-- (1.26.9d) a drop falling into wet blood sends a ring wave out through it: a short outward shove of the blood around
-- the spot (the element "wave" op - momentum only, the blood keeps its volume), which the surface shader draws as ripples
-- running out across the flow. Dry floor is untouched (the op only moves wet blood). Steep falls only (spray skimming in
-- at a low angle does not ring), at most one every 0.06 s; new shader pack only
S.waveT = S.waveT or 0
function S.DripWave(pos, normal, vel, volume)
	local m = G.cv.ripples and G.cv.ripples:GetFloat() or 1
	if m <= 0 or not (G.NewShaders and G.NewShaders()) then return end
	local now = CurTime()
	if now < S.waveT then return end
	local sp = vel:Length()
	local vn = -vel:Dot(normal)
	if sp < 60 or vn < 0.7 * sp then return end
	S.waveT = now + 0.06
	local k = math.Clamp(0.014 * m * math.sqrt(volume / 30) * (vn / 220), 0.004, 0.06)
	return S.Element(pos, math.Clamp(2.2 + 0.5 * volume ^ (1 / 3), 2.5, 6), 13, k)
end
-- (1.26.9d) blood welling into a pool from a body (cl_wounds.lua): a gentle, repeated stir round the spot it comes in at
function S.WellWave(pos, k)
	local m = G.cv.ripples and G.cv.ripples:GetFloat() or 1
	if m <= 0 or not (G.NewShaders and G.NewShaders()) then return end
	S.Element(pos, 3.5, 13, math.Clamp(k * m, 0.003, 0.04))
end

local cornerW = { 0, 0, 0, 1 }
local function StampPass(p)
	local all = p.impacts
	if #all == 0 then return end
	p.impacts = {}
	local o = p.origin
	local list, elist, flist = {}, nil, nil
	-- (1.26.9d) froth: only the impacts flagged as carrying air (coughed blood, the frothy part of a wound's seep) are
	-- stamped with a froth amount, in a pass of their own; spray and plain pours bring none (no pale dotted rims)
	local fAmt = S.FrothAmt(p)
	if not p.geo then GeoNums(p) end
	local nx, ny, nz = p.gnx, p.gny, p.gnz
	for _, im in ipairs(all) do
		local w = im.wpos
		local rx, ry, rz = w.x - p.gox, w.y - p.goy, w.z - p.goz
		local dn = rx * nx + ry * ny + rz * nz
		im.px, im.py, im.pz = rx - nx * dn, ry - ny * dn, rz - nz * dn
		if im.kind == 4 and (im.spin or 0) >= 10 then elist = elist or {} elist[#elist + 1] = im
		elseif fAmt > 0 and (im.flags or 0) >= 1 and (im.kind or 0) <= 1 then flist = flist or {} flist[#flist + 1] = im
		else list[#list + 1] = im end
	end
	local s = p.slot
	local P = S.PATCH_UNITS
	local U, V, n = p.U, p.V, p.N
	local first = 1
	local groups = {}
	if #list > 0 then groups[#groups + 1] = { list, stampMat, 0 } end
	if flist then groups[#groups + 1] = { flist, stampMat, fAmt } end
	if elist then groups[#groups + 1] = { elist, elemMat, 0 } end
	for _, gr in ipairs(groups) do
		local mat, frothC
		list, mat, frothC, first = gr[1], gr[2], gr[3], 1
		while first <= #list do
			local cnt = math.min(GPU.IMPACT_COLS, #list - first + 1)
			GPU.UploadImpacts(list, first, cnt)
			GPU.SetC(mat, 0, cnt, o.x, o.y, o.z)
			GPU.SetC(mat, 1, 1 / GPU.IMPACT_COLS, 1 / 4, CurTime(), 1)
			GPU.SetC(mat, 2, 1, -2, frothC, 0)
			GPU.SetC(mat, 3, p.surf.rough or 0.4, p.surf.fabric or 0, 1 / s.res, 1)
			mat:SetTexture("$texture1", s.st[3 - p.cur])
			render.PushRenderTarget(s.st[p.cur])
			render.SetRenderTargetEx(1, s.aux[p.cur])
			render.SetRenderTargetEx(2, s.ac[p.cur])
			render.SetRenderTargetEx(3, s.ex[p.cur])
			render.SetMaterial(mat)
			GPU.Additive(true)
			GPU.FullQuad(s.res, s.res, function(ci, u, v)
				local a, b = u * P, v * P
				cornerW[1], cornerW[2], cornerW[3] = p.gox + p.gux * a + p.gvx * b, p.goy + p.guy * a + p.gvy * b, p.goz + p.guz * a + p.gvz * b
				return cornerW
			end, { nx, ny, nz, 0 })
			GPU.Additive(false)
			render.SetRenderTargetEx(3, nil)
			render.SetRenderTargetEx(2, nil)
			render.SetRenderTargetEx(1, nil)
			render.PopRenderTarget()
			first = first + cnt
		end
	end
	p.hasBlood = true
end

local NB = { { -1, 0, 1, 4, "$texture4" }, { 1, 0, 2, 5, "$texture5" }, { 0, -1, 4, 6, "$texture6" }, { 0, 1, 8, 7, "$texture7" } }
local function NbKey(p, k)
	local keys = p.nbKeys
	if not keys then
		keys = {}
		for m, nb in ipairs(NB) do keys[m] = p.plane .. "|" .. (p.i + nb[1]) .. "|" .. (p.j + nb[2]) end
		p.nbKeys = keys
	end
	return keys[k]
end
S.NbKey = NbKey
local function Neighbour(p, nb, k) return S.patches[NbKey(p, k or (nb[1] == -1 and 1 or nb[1] == 1 and 2 or nb[2] == -1 and 3 or 4))] end

local REMAP_ID = { 0, 1, 0, 1, 0, 1, 0, 1 }
local function Remap(p, q)
	local kp, kq = S.TypeKey(p), S.TypeKey(q)
	if kp == kq then return 0, 1 end
	local tp, tq = S.planeTypes[kp], S.planeTypes[kq]
	if not tq then return 0, 1 end
	if not tp then
		tp = { a = tq.a, b = tq.b, va = 0, vb = 0 }
		S.planeTypes[kp] = tp
		return 0, 1
	end
	-- (1.26.10e) blood of another type running in from a neighbour takes this region's free second slot instead of being
	-- recoloured to this region's type at the border (with a region per patch, pools of two types meet at patch edges)
	if tp.b == nil then
		local cand = tq.a ~= tp.a and tq.a or tq.b
		if cand ~= nil and cand ~= tp.a then tp.b = cand end
	end
	local b = tp.b
	if tp.a == tq.a and b == tq.b then return 0, 1 end
	if b == nil then return 0, 0 end
	local m0 = tq.a == b and 1 or 0
	local m1 = ((tq.b ~= nil and tq.b == b) and 1 or 0) - m0
	return m0, m1
end

function S.StepAll(dt, now)
	S.stepId = S.stepId + 1
	local id = S.stepId
	local act = {}
	for _, p in pairs(S.patches) do
		if not p.pendingBake and not p.bakeNow and p.hasBlood and now < p.wetUntil then
			p.stepMark = id
			act[#act + 1] = p
		end
	end
	local n0 = #act
	for k = 1, n0 do
		local p = act[k]
		for m = 1, 4 do
			local q = S.patches[NbKey(p, m)]
			if q and q.stepMark ~= id and not q.pendingBake and not q.bakeNow and q.slot.res == p.slot.res then
				q.stepMark = id
				if not q.tvol and not q.inherited then q.btype, q.oxy, q.inherited = p.btype, p.oxy, true end
				local kp, kq = S.TypeKey(p), S.TypeKey(q)
				if kp ~= kq and S.planeTypes[kp] and not S.planeTypes[kq] then
					local tp = S.planeTypes[kp]
					S.planeTypes[kq] = { a = tp.a, b = tp.b, va = 0, vb = 0 }
				end
				q.hasBlood = true
				S.ageDirty = true
				act[#act + 1] = q
			end
		end
	end
	for _, p in ipairs(act) do
		local s = p.slot
		local src, dst = p.cur, 3 - p.cur
		local mat = s.sim[src]
		local mask = 0
		local rm = REMAP_ID
		for k, nb in ipairs(NB) do
			local nk = NbKey(p, k)
			local q = S.patches[nk]
			if q and q.stepMark == id and q.slot.res == s.res then
				mask = mask + nb[3]
				mat:SetTexture(nb[5], q.slot.ex[q.cur])
				local m0, m1 = Remap(p, q)
				if m0 ~= 0 or m1 ~= 1 then
					if rm == REMAP_ID then rm = { 0, 1, 0, 1, 0, 1, 0, 1 } end
					rm[k * 2 - 1], rm[k * 2] = m0, m1
				end
			else
				mat:SetTexture(nb[5], "vgui/white")
				if not q and (S.solidCells[nk] or 0) > now then mask = mask + nb[3] * 16 end
			end
		end
		local g = GetConVarNumber("sv_gravity") or 600
		if p.gravG ~= g then p.gravG = g p.grav = { 1, S.PlaneGravity(p) } end
		local ax, ay, an = p.grav[2], p.grav[3], p.grav[4]
		-- (1.26.1) the age of the blood here sets how readily the ground drinks it (G.SoakRamp)
		local tNow = CurTime()
		p.soakT0 = p.soakT0 or p.firstT or tNow
		GPU.SimParams(mat, p.surf, s.res, dt, mask, -1, p.i * s.res, p.j * s.res, p.grav, id % 2, p.water, p.el,
			G.SoakRamp(p.surfName, tNow - p.soakT0), p.fedT and math.Clamp(1 - (tNow - p.fedT) / 6, 0, 1) or 0)
		GPU.SetC(mat, 15, rm[1], rm[2], rm[3], rm[4])
		GPU.SetC(mat, 16, rm[5], rm[6], rm[7], rm[8])
		render.PushRenderTarget(s.st[dst])
		render.SetRenderTargetEx(1, s.ac[dst])
		render.SetRenderTargetEx(2, s.aux[dst])
		render.SetRenderTargetEx(3, s.ex[dst])
		render.SetMaterial(mat)
		GPU.FullQuad(s.res, s.res, { 0, 0, 0, 0 })
		render.SetRenderTargetEx(3, nil)
		render.SetRenderTargetEx(2, nil)
		render.SetRenderTargetEx(1, nil)
		render.PopRenderTarget()
	end
	for _, p in ipairs(act) do p.cur = 3 - p.cur end
	G.Prof.Count("world patch steps", #act)
	return #act
end

local function NewAfter(p)
	return { key = p.key, plane = p.plane, i = p.i, j = p.j, N = p.N, U = p.U, V = p.V, origin = p.origin, center = p.center,
		flat = p.flat, cMax = p.cMax, cMin = p.cMin, relief = p.relief, bedH0 = p.bedH0, groundEnts = p.groundEnts,
		meshKind = p.meshKind, cMid = p.cMid, cNrm = p.cNrm,
		grid = nil, albedo = p.albedo, albedoTex = p.albedoTex, bumpTex = p.bumpTex, bumpKind = p.bumpKind, bmap = p.bmap, bumpDone = p.bumpDone,
		surfName = p.surfName, surf = p.surf, oxy = p.oxy, btype = p.btype, aft = GPU.TakeAft(AftRes()), bakedAt = CurTime(), water = p.water,
		woundPool = p.woundPool,
		el = p.el and { frost = p.el.frost, glowT = p.el.glowT, glow = p.el.glow, cold = p.el.cold, coldRate = p.el.coldRate } or nil }
end

local function BakePatch(p)
	if p.hasBlood then
		local a = S.after[p.key]
		local dryT = a and G.DryAge(a, G.DryMult(a.surfName)) or 0
		if not a then
			a = NewAfter(p)
			a.meshes, p.meshes = p.meshes, nil
			if a.meshes and a.meshes[0.07] then pcall(function() a.meshes[0.07]:Destroy() end) a.meshes[0.07] = nil end
			S.after[p.key] = a
			S.IndexAdd(a)
		end
		GPU.BakeInto(a.aft, p.slot.st[p.cur], p.slot.aux[p.cur], p.slot.bed, dryT)
		if p.dust and G.Dust then G.Dust.BakeWorld(p, a) end
		a.bakedAt = CurTime()
		S.ageDirty = true
		if p.tvol then
			a.tvol = a.tvol or {}
			for t, v in pairs(p.tvol) do a.tvol[t] = (a.tvol[t] or 0) + v end
		end
		local best, bv = p.btype, -1
		for t, v in pairs(a.tvol or {}) do if v > bv then best, bv = t, v end end
		a.oxy, a.btype = p.oxy, best
		-- (1.26.9c) a wound's pool that ran over a patch border: the patches of the same plane next to the wound's patch show
		-- its serum fringe too, so the fringe does not stop at the seam
		local wp = p.woundPool
		if not wp and p.plane and p.i and p.j then
			for di = -1, 1 do
				for dj = -1, 1 do
					if not wp and (di ~= 0 or dj ~= 0) then
						local k = p.plane .. "|" .. (p.i + di) .. "|" .. (p.j + dj)
						local q = S.patches[k] or S.after[k]
						if q and q.woundPool then wp = true end
					end
				end
			end
		end
		a.woundPool = a.woundPool or wp
		local pv, av = p.ageVol or 0, a.ageVol or 0
		if pv > 0 and p.bornT then
			-- (1.26.9b) both weights as they are now (S.AgeMemory)
			local mem, now = S.AgeMemory(), CurTime()
			if p.ageT then pv = pv * math.exp(-math.max(now - p.ageT, 0) / mem) end
			if av > 0 and a.ageT then av = av * math.exp(-math.max(now - a.ageT, 0) / mem) end
			pv = math.max(pv, 1e-3)
			a.bornT = (av > 0 and a.bornT) and (a.bornT * av + p.bornT * pv) / (av + pv) or p.bornT
			a.ageVol = av + pv
			a.ageT = now
		end
		a.pair = S.PairCode(S.TypeKey(p), p.btype)
		a.dVer, a.kT = nil, nil
		if p.el then
			a.el = a.el or {}
			a.el.frost, a.el.cold, a.el.coldRate = math.max(a.el.frost or 0, p.el.frost or 0), p.el.cold, p.el.coldRate
			if (p.el.glow or 0) > (a.el.glow or 0) then a.el.glow, a.el.glowT = p.el.glow, p.el.glowT end
		end
	end
	S.RemovePatch(p.key)
end

function S.TrimAftermath()
	local n = 0
	for _ in pairs(S.after) do n = n + 1 end
	local cap = G.Budget.Caps().aft
	if n <= cap then return end
	local eye = EyePos()
	local list = {}
	for key, a in pairs(S.after) do list[#list + 1] = { key, a.center:Distance(eye) + (CurTime() - a.bakedAt) * 2 } end
	table.sort(list, function(x, y) return x[2] > y[2] end)
	for k = 1, n - cap do S.RemoveAfter(list[k][1]) end
end

function S.RemoveAfter(key)
	local a = S.after[key]
	if not a then return end
	S.IndexRemove(a)
	GPU.FreeAft(a.aft)
	if a.dust then GPU.FreeDust(a.dust.rt) a.dust = nil end
	S.FreeMeshes(a)
	S.after[key] = nil
end

function S.HasStatic() return next(S.after) ~= nil end
-- (1.26.6) any live (simulated) square with blood to draw
function S.HasLive()
	for _, p in pairs(S.patches) do if p.hasBlood and not p.pendingBake then return true end end
	return false
end

-- (1.26.6) blood that lies together ages together: squares of world blood (live and settled) within ~1.5 squares of each
-- other form one group and share one age, the volume-weighted mean time their blood arrived - each square ageing on its
-- own drew a seam at every square's border. Regrouped every 0.5 s.
S.groupT = 0
S.ageDirty = true
function S.UpdateAgeGroups(now)
	if now < (S.groupT or 0) and now > (S.groupT or 0) - 1 then return end
	S.groupT = now + 0.5
	-- (1.26.6) regrouped only when blood was added, settled or removed, or a setting changed (at least every 5 s): with
	-- nothing new the groups come out the same - with a lot of old blood the grouping took a few ms twice a second
	local settleT = G.PoolSettleTime and G.PoolSettleTime() or G.SettleTime()
	if not S.ageDirty and S.groupSettle == settleT and now < (S.groupForceT or 0) then return end
	S.ageDirty, S.groupSettle, S.groupForceT = false, settleT, now + 5
	local list, idx = {}, {}
	for _, p in pairs(S.patches) do if p.hasBlood and p.center then list[#list + 1] = p end end
	for _, a in pairs(S.after) do if a.center then list[#list + 1] = a end end
	if #list == 0 then return end
	local parent = {}
	for i = 1, #list do parent[i] = i idx[list[i]] = i end
	local function find(i)
		while parent[i] ~= i do parent[i] = parent[parent[i]] i = parent[i] end
		return i
	end
	local reach2 = (S.PATCH_UNITS * 1.55) ^ 2
	local cells = S.cells
	-- (1.26.6) the centres as plain numbers (kept on the record: squares do not move) - a Vector method per pair was most
	-- of the cost
	-- (1.26.9b) live blood joins settled blood only when it is about as old (within a clotting time): fresh blood next to
	-- (or on) blood from an earlier fight kept the old blood's age - it looked dull and old. Live squares among themselves
	-- and settled ones among themselves still always age together (no seams across one pool)
	local born, live = {}, {}
	local joinT = S.AgeMemory()
	for i = 1, #list do
		local p = list[i]
		if not p.gx then local c = p.center p.gx, p.gy, p.gz = c.x, c.y, c.z end
		born[i] = p.bornT or (p.bakedAt and (p.bakedAt - settleT)) or p.touched or now
		live[i] = S.patches[p.key] == p
	end
	for i = 1, #list do
		local p = list[i]
		local px, py, pz = p.gx, p.gy, p.gz
		local bi = born[i]
		local cx, cy, cz = math.floor(px / CELL), math.floor(py / CELL), math.floor(pz / CELL)
		for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
			local cl = cells[CKey(cx + dx, cy + dy, cz + dz)]
			if cl then
				for q in pairs(cl) do
					local j = idx[q]
					if j and j > i then
						local qx, qy, qz = q.gx - px, q.gy - py, q.gz - pz
						if qx * qx + qy * qy + qz * qz < reach2 and (live[j] == live[i] or math.abs(born[j] - bi) <= joinT) then
							local ri, rj = find(i), find(j)
							if ri ~= rj then parent[rj] = ri end
						end
					end
				end
			end
		end end end
	end
	local sw, sb = {}, {}
	for i = 1, #list do
		local p = list[i]
		-- (the weights as they are now, S.AgeMemory)
		local w = math.max(p.ageVol or p.vol or 1, 1)
		if p.ageT then w = math.max(w * math.exp(-math.max(now - p.ageT, 0) / joinT), 1e-3) end
		local r = find(i)
		sw[r] = (sw[r] or 0) + w
		sb[r] = (sb[r] or 0) + born[i] * w
	end
	for i = 1, #list do
		local r = find(i)
		list[i].groupBorn = sb[r] / sw[r]
	end
end

cvars.AddChangeCallback("ghmpb_floor_unevenness", function()
	for _, p in pairs(S.patches) do p.forceDirty = true end
end, "ghmpb_surfaces")

function S.ClearAftermath()
	for key in pairs(S.after) do S.RemoveAfter(key) end
end

local function AfterFade(a, now)
	if G.cv.forever:GetBool() then return 1 end
	local age = now - a.bakedAt - G.cv.aftfade:GetFloat() * 60
	return 1 - math.Clamp(age / 30, 0, 1)
end

function S.FlushPending()
	if not G.cv.enable:GetBool() or (G.Lite and G.Lite.on) then return end
	local any = false
	for _, p in pairs(S.patches) do
		if #p.impacts > 0 and (p.pendingBake or p.needSlot or p.slot) then
			any = true
			break
		end
	end
	if not any then return end
	Shared()
	cam.Start3D(EyePos(), EyeAngles())
	local clip = render.EnableClipping(false)
	local rt0 = render.GetRenderTarget()
	local ok = pcall(function()
		for key, p in pairs(S.patches) do
			if p.needSlot and #p.impacts > 0 then
				local s = TakeSlot()
				if s then p.slot, p.needSlot = s, nil end
			end
			if p.pendingBake and not p.needSlot and #p.impacts > 0 then
				p.pendingBake = false
				if not StartBed(p) then
					S.RemovePatch(key)
					p = nil
				else
					ForceBake(p)
				end
			end
			if p and p.forceDirty and p.slot and not p.pendingBake then ForceBake(p) end
			if p and p.slot and not p.pendingBake and #p.impacts > 0 then StampPass(p) end
		end
	end)
	if not ok then
		for _ = 1, 8 do
			if render.GetRenderTarget() == rt0 then break end
			if not pcall(render.PopRenderTarget) then break end
		end
		for k = 1, 3 do pcall(render.SetRenderTargetEx, k, nil) end
		pcall(render.OverrideAlphaWriteEnable, false)
		pcall(render.OverrideBlend, false)
	end
	render.EnableClipping(clip)
	cam.End3D()
end

function S.Update(frameDt)
	if not G.cv.enable:GetBool() then return end
	Shared()
	local pf = S.prof
	local tp = pf and SysTime()
	local function mark(tag)
		if not pf then return end
		local t = SysTime()
		local e = pf[tag] or { 0, 0 }
		pf[tag] = e
		e[1] = e[1] + (t - tp)
		if t - tp > e[2] then e[2] = t - tp end
		tp = t
	end
	mark("albedo")
	S.CheckGroundEnts()
	mark("ground")
	local now = CurTime()
	S.StepSeep(now)
	local waiting, evicting, full = 0, 0, false
	for _, p in pairs(S.patches) do
		if p.needSlot then
			local s = not full and TakeSlot()
			if s then p.slot, p.needSlot = s, nil
			else
				full = true
				if #p.impacts > 0 then waiting = waiting + 1 end
			end
		elseif p.bakeNow then evicting = evicting + 1 end
	end
	if waiting > evicting and not G.Budget.MayCreatePatch(PatchRes()) then Evict(1.5) end
	mark("slots")
	local tBed = SysTime() + S.BED_MS * (G.Gov and G.Gov.BedMul and G.Gov.BedMul() or 1) / 1000
	local probes = 0
	for key, p in pairs(S.patches) do
		if p.pendingBake and not p.needSlot and (#p.impacts > 0 or probes == 0 or SysTime() < tBed) then
			probes = probes + 1
			p.pendingBake = false
			mark("loop")
			if not StartBed(p) then
				S.RemovePatch(key)
				p = nil
			else
				ForceBake(p)
			end
			mark("startbed")
		end
		if p and p.forceDirty and p.slot and not p.pendingBake then ForceBake(p) mark("force") end
		if p and p.slot and not p.pendingBake and #p.impacts > 0 then StampPass(p) mark("stamp") end
	end
	mark("loop")
	if next(S.bedJobs) and SysTime() < tBed then RunBedJobs(tBed) end
	mark("bedjobs")
	local newest = 0
	for _, p in pairs(S.patches) do if p.hasBlood and p.touched > newest then newest = p.touched end end
	local quietAll = now - newest
	local div = quietAll > 30 and 3 or (quietAll > 12 and 2 or 1)
	if G.Gov then div = div * G.Gov.WorldStepMul() end
	local step = math.min(div / G.cv.simhz:GetFloat(), 0.15)
	S.clock = math.min(S.clock + frameDt, step * 3)
	if frameDt > step * 1.25 and S.clock >= step then
		local long = math.min(S.clock, math.max(step, math.min(step * 2.5, 0.1)))
		S.StepAll(long, now)
		S.clock = math.max(S.clock - long, 0)
	else
		local n = 0
		while S.clock >= step and n < 2 do
			S.StepAll(step, now)
			S.clock = S.clock - step
			n = n + 1
		end
	end
	mark("step")
	local aftermath = G.cv.aftermath:GetBool()
	-- (1.26.6) a pool stays live until it has nearly clotted (G.PoolSettleTime): the aftermath layer draws settled blood
	-- clotted and dull, so a pool that settled after half the clotting time - or after 27 s when the governor cut it -
	-- looked dry while it was still fresh. A square that only holds blood which flowed in from a pool next to it counts as
	-- part of that pool (its own impact volume is small). The governor settles blood sooner only when it is far away.
	local settleLong = G.PoolSettleTime and G.PoolSettleTime() or G.SettleTime()
	local settleShort = G.cv.settle:GetFloat()
	local nearLong, nearShort = settleLong * 0.6, math.min(settleShort, 25)
	if G.Gov then
		local m = G.Gov.SettleMul()
		settleLong, settleShort = math.max(settleLong * m, 10), math.max(settleShort * m, 8)
	end
	local eyeP = EyePos()
	local poolMark = {}
	local function isPool(p)
		local v = poolMark[p]
		if v ~= nil then return v end
		v = (p.vol or 0) >= 4000
		if not v then
			for _, nb in ipairs(NB) do
				local q = Neighbour(p, nb)
				if q and (q.vol or 0) >= 4000 then v = true break end
			end
		end
		poolMark[p] = v
		return v
	end
	local function settleOf(p)
		local near = p.center:DistToSqr(eyeP) < 1600 * 1600
		if isPool(p) then return near and math.max(settleLong, nearLong) or settleLong end
		return near and math.max(settleShort, nearShort) or settleShort
	end
	local baked = 0
	for key, p in pairs(S.patches) do
		if baked >= 6 then break end
		if p.bakeNow and not p.pendingBake and not S.bedJobs[key] then
			if aftermath then BakePatch(p) else S.RemovePatch(key) end
			baked = baked + 1
		end
	end
	for key, p in pairs(S.patches) do
		if baked >= 6 then break end
		if not p.pendingBake and not p.bakeNow and not S.bedJobs[key] and #p.impacts == 0 then
			local quiet = p.bakeNow or (now - p.touched > settleOf(p))
			if quiet and not p.bakeNow then
				for _, nb in ipairs(NB) do
					local q = Neighbour(p, nb)
					if q and now - q.touched <= settleOf(q) then quiet = false break end
				end
			end
			if quiet then
				if aftermath then BakePatch(p) baked = baked + 1
				elseif now > p.wetUntil + 60 or p.bakeNow then S.RemovePatch(key) end
			end
		end
	end
	mark("bake")
	if baked > 0 then S.TrimAftermath() end
	mark("trim")
	if not G.cv.forever:GetBool() then
		for key, a in pairs(S.after) do if AfterFade(a, now) <= 0 then S.RemoveAfter(key) end end
	end
end

function S.Reduce(tiles)
	for key, p in pairs(S.patches) do
		if p.hasBlood and not p.pendingBake and CurTime() < p.wetUntil and #tiles < 240 then
			local s = p.slot
			local mat = s.reduce[p.cur]
			local bs = s.res / GPU.TILE
			GPU.SetC(mat, 0, 1 / s.res, 1 / s.res, bs, 1)
			GPU.SetC(mat, 1, 0, 0, 0, 2500)
			GPU.SetC(mat, 2, 1, 1, 1, 0)
			local x0, y0 = GPU.TileOrigin(#tiles)
			render.SetMaterial(mat)
			GPU.Quads(GPU.READBACK, GPU.READBACK, { { x0, y0, x0 + GPU.TILE, y0 + GPU.TILE,
				function(ci) local c = ({ { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } })[ci] return { c[1], c[2], 0, 0 } end } })
			tiles[#tiles + 1] = { kind = "patch", p = p, key = key, x0 = x0, y0 = y0, volNorm = 2500 }
		end
	end
end

local groundFilter = S.GroundFilter
local ofTr, ofOut = { mask = MASK_SOLID, filter = groundFilter }, {}
ofTr.output = ofOut
local function Trace(a, b)
	ofTr.start, ofTr.endpos = a, b
	util.TraceLine(ofTr)
	return ofOut
end

local function OutwardDir(p, pos, uv)
	local ax, ay = S.PlaneGravity(p)
	if ax * ax + ay * ay > 300 * 300 then
		local d = p.U * ax + p.V * ay
		d:Normalize()
		return d
	end
	for _, r in ipairs({ 0.7, 1.4, 2.4 }) do
		local acc = Vector(0, 0, 0)
		local any = false
		for k = 0, 7 do
			local a = k * math.pi / 4
			local d = p.U * math.cos(a) + p.V * math.sin(a)
			local q = pos + d * r
			local tr = Trace(q + p.N * 3, q - p.N * 1.2)
			if not tr.Hit or tr.StartSolid then acc = acc + d any = true end
		end
		if any and acc:LengthSqr() > 1e-4 then acc:Normalize() return acc end
	end
	local ox, oy = uv[1] - 0.5, uv[2] - 0.5
	local d = math.abs(ox) > math.abs(oy) and p.U * (ox > 0 and 1 or -1) or p.V * (oy > 0 and 1 or -1)
	return d
end
S.OutwardDir = OutwardDir

local function FindLip(p, pos, dir)
	local last = pos
	for t = 0, 3, 0.25 do
		local q = pos + dir * t
		local tr = Trace(q + p.N * 3, q - p.N * 1.2)
		if not tr.Hit or tr.StartSolid or tr.HitNormal:Dot(p.N) < 0.8 then return last end
		last = q
	end
	return last
end

function S.HandleOutflow(p, uv, vol, edgeFrac)
	local P = S.PATCH_UNITS
	local pos = p.origin + p.U * (uv[1] * P) + p.V * (uv[2] * P)
	local liftVol = vol * (1 - edgeFrac)
	local edgeVol = vol * edgeFrac
	local ent = p.groundEnts and next(p.groundEnts) or nil
	if liftVol > 3 then
		G.Particles.Hang(pos + p.N * 0.3, p.N * 2, liftVol, ent, p.oxy, p.btype)
	end
	if edgeVol <= 1 then return end
	local N = p.N
	local dirW = OutwardDir(p, pos, uv)
	S.stats = S.stats or { cont = 0, corner = 0, wrap = 0, drip = 0 }
	local probe = pos + dirW * 1.5
	local tr = Trace(probe + N * 4, probe - N * 6)
	if tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(N) > 0.8 then
		S.stats.cont = S.stats.cont + 1
		S.Impact(Vector(tr.HitPos), Vector(tr.HitNormal), dirW * 5, 0.35, edgeVol, 1, 0, 1, 0, tr, p.oxy, p.btype)
		return
	end
	if dirW.z < -0.3 then
		local a = pos + N * 0.3 - dirW * 0.6
		tr = Trace(a, a + dirW * 3.6)
		if tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(-dirW) > 0.5 then
			S.stats.corner = S.stats.corner + 1
			S.Impact(Vector(tr.HitPos), Vector(tr.HitNormal), dirW * 8, 0.5, edgeVol, 1, 0, 1, 0, tr, p.oxy, p.btype)
			return
		end
	end
	local lip = FindLip(p, pos, dirW)
	local q = lip + dirW * 0.4 - N * 0.8
	tr = Trace(q + dirW * 1.6, q - dirW * 2.2)
	if tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(dirW) > 0.6 then
		local runF = math.Clamp(1.4 - edgeVol / 2500, 0.35, 1)
		local hitPos, hitN = Vector(tr.HitPos), Vector(tr.HitNormal)
		local info = { HitTexture = tr.HitTexture, Entity = tr.Entity, MatType = tr.MatType }
		local down = -N - hitN * (-N):Dot(hitN)
		if down:LengthSqr() < 1e-3 then down = Vector(0, 0, -1) end
		down:Normalize()
		S.stats.wrap = S.stats.wrap + 1
		local T = N:Cross(dirW)
		if T:LengthSqr() > 1e-4 then
			T:Normalize()
			local sp = 2.2
			local sc = hitPos:Dot(T)
			local k = math.floor(sc / sp)
			local jit = (math.sin(k * 12.9898 + 78.233) * 43758.5453) % 1
			local off = (k + 0.5 + (jit - 0.5) * 0.6) * sp - sc
			local site = Trace(q + dirW * 1.6 + T * off, q - dirW * 2.2 + T * off)
			if site.Hit and not site.StartSolid and site.HitNormal:Dot(dirW) > 0.6 then
				hitPos, hitN = Vector(site.HitPos), Vector(site.HitNormal)
			end
		end
		info.HitPos, info.HitNormal = hitPos, hitN
		S.Impact(hitPos + down * 0.4, hitN, down * 6, 0.4, edgeVol * runF, 1, 0, 1, 0, info, p.oxy, p.btype)
		if runF < 1 then
			G.Particles.Hang(lip + dirW * 0.6 - N * 0.3, dirW * 10 - N * 4, edgeVol * (1 - runF), ent, p.oxy, p.btype)
		end
		return
	end
	local dripAt = lip + dirW * 0.6 - N * 0.3
	if bit.band(util.PointContents(dripAt), CONTENTS_SOLID) ~= 0 then
		tr = Trace(pos + N * 2, pos - N * 2)
		if tr.Hit and not tr.StartSolid then
			S.stats.back = (S.stats.back or 0) + 1
			S.Impact(Vector(tr.HitPos), Vector(tr.HitNormal), vector_origin, 0.35, edgeVol, 1, 0, 1, 0, tr, p.oxy, p.btype)
		end
		return
	end
	S.stats.drip = S.stats.drip + 1
	S.stats.lastDrip = lip
	G.Particles.Hang(dripAt, dirW * 6 - N * 4, edgeVol, ent, p.oxy, p.btype)
end

local function CornerAt(p, x, y)
	local N = S.BED
	local mx, mn = nil, nil
	for dy = -1, 0 do for dx = -1, 0 do
		local cx, cy = x + dx, y + dy
		if cx >= 0 and cx < N and cy >= 0 and cy < N then
			local k = cy * N + cx
			local a, b = p.cMax and p.cMax[k], p.cMin and p.cMin[k]
			if a and (not mx or a > mx) then mx = a end
			if b and (not mn or b < mn) then mn = b end
		end
	end end
	return mx or 0, mn or 0
end

local function BuildMesh(p, lift)
	Shared()
	local P = S.PATCH_UNITS
	local U, V, n = p.U, p.V, p.N
	local tu, tv = U * P, V * P
	local pd = n:Dot(p.origin)
	local relief = p.relief and 1 or 0
	local bk = (p.bumpTex and p.bmap) and p.bumpKind or 0
	local bu0, bv0 = BumpUV(p, p.origin)
	local bu1, bv1 = BumpUV(p, p.origin + U * P)
	local bu2, bv2 = BumpUV(p, p.origin + V * P)
	local function B(cu, cv) return bu0 + (bu1 - bu0) * cu + (bu2 - bu0) * cv, bv0 + (bv1 - bv0) * cu + (bv2 - bv0) * cv end
	local m = Mesh(staticMat)
	local N = S.BED
	if p.meshKind == "surf" and p.cMid then
		lift = lift + S.SMOOTH_DEV
		mesh.Begin(m, MATERIAL_QUADS, N * N)
		local ok = pcall(function()
			for y = 0, N - 1 do
				for x = 0, N - 1 do
					for ci = 1, 4 do
						local cx = x + ((ci == 2 or ci == 3) and 1 or 0)
						local cy = y + ((ci >= 3) and 1 or 0)
						local k = cy * (N + 1) + cx
						local nr = p.cNrm[k]
						local nn = n * math.sqrt(math.max(1 - nr[1] * nr[1] - nr[2] * nr[2], 0)) + U * nr[1] + V * nr[2]
						mesh.Position(p.origin + U * (cx / N * P) + V * (cy / N * P) + n * (p.cMid[k] + lift))
						local bu, bv = B(cx / N, cy / N)
						mesh.TexCoord(0, cx / N, cy / N, 0, bu)
						mesh.TexCoord(1, tu.x, tu.y, tu.z, bv)
						mesh.TexCoord(2, tv.x, tv.y, tv.z, 2 * bk)
						mesh.TexCoord(3, nn.x, nn.y, nn.z, pd)
						mesh.AdvanceVertex()
					end
				end
			end
		end)
		mesh.End()
		return ok and m or nil
	end
	if p.flat or not p.cMax or p.meshKind == "quad" then
		local o = p.origin + n * ((p.bedH0 or 0) + lift)
		mesh.Begin(m, MATERIAL_QUADS, 1)
		local ok = pcall(function()
			for ci = 1, 4 do
				local cu = (ci == 2 or ci == 3) and 1 or 0
				local cv = (ci >= 3) and 1 or 0
				mesh.Position(o + U * (cu * P) + V * (cv * P))
				local bu, bv = B(cu, cv)
				mesh.TexCoord(0, cu, cv, 0, bu)
				mesh.TexCoord(1, tu.x, tu.y, tu.z, bv)
				mesh.TexCoord(2, tv.x, tv.y, tv.z, 2 * bk)
				mesh.TexCoord(3, n.x, n.y, n.z, pd)
				mesh.AdvanceVertex()
			end
		end)
		mesh.End()
		return ok and m or nil
	end
	lift = math.max(lift, 0.35)
	local g, lo = {}, {}
	for y = 0, N do
		for x = 0, N do
			local mx, mn = CornerAt(p, x, y)
			g[y * (N + 1) + x] = p.origin + U * (x / N * P) + V * (y / N * P) + n * (mx + lift)
			lo[y * (N + 1) + x] = mn
		end
	end
	mesh.Begin(m, MATERIAL_QUADS, N * N)
	local ok = pcall(function()
		for y = 0, N - 1 do
			for x = 0, N - 1 do
				local low = math.min(lo[y * (N + 1) + x], lo[y * (N + 1) + x + 1], lo[(y + 1) * (N + 1) + x], lo[(y + 1) * (N + 1) + x + 1])
				for ci = 1, 4 do
					local cx = x + ((ci == 2 or ci == 3) and 1 or 0)
					local cy = y + ((ci >= 3) and 1 or 0)
					mesh.Position(g[cy * (N + 1) + cx])
					local bu, bv = B(cx / N, cy / N)
					mesh.TexCoord(0, cx / N, cy / N, low, bu)
					mesh.TexCoord(1, tu.x, tu.y, tu.z, bv)
					mesh.TexCoord(2, tv.x, tv.y, tv.z, relief + 2 * bk)
					mesh.TexCoord(3, n.x, n.y, n.z, pd)
					mesh.AdvanceVertex()
				end
			end
		end
	end)
	mesh.End()
	return ok and m or nil
end

function S.FreeMeshes(p)
	if p and p.meshes then
		for _, m in pairs(p.meshes) do pcall(function() m:Destroy() end) end
	end
	if p then p.meshes = nil end
end

local buildFrame, builds = -1, 0
function S.DrawPatchMesh(p, lift)
	lift = lift or 0.07
	if p.meshDirty then p.meshDirty = nil S.FreeMeshes(p) end
	p.meshes = p.meshes or {}
	local m = p.meshes[lift]
	if m == nil then
		if FrameNumber() ~= buildFrame then buildFrame, builds = FrameNumber(), 0 end
		local isFlat = p.flat or not p.cMax or p.meshKind == "quad"
		if not isFlat then
			if builds >= 48 then return end
			builds = builds + 1
		end
		m = BuildMesh(p, lift) or false
		p.meshes[lift] = m
	end
	if m then m:Draw() end
end

local coneHalf = math.rad(60)
local function UpdateCone()
	local fov = 90
	local vs = render.GetViewSetup and render.GetViewSetup()
	if vs and vs.fov then fov = vs.fov elseif IsValid(LocalPlayer()) then fov = LocalPlayer():GetFOV() end
	local aspect = ScrW() / math.max(ScrH(), 1)
	local th = math.tan(math.rad(math.Clamp(fov, 10, 170)) * 0.5) * aspect / (4 / 3)
	local tv = th / aspect
	coneHalf = math.atan(math.sqrt(th * th + tv * tv))
end
local PATCH_R = 32
local ex, ey, ez, fx, fy, fz = 0, 0, 0, 1, 0, 0
local function SetEye(eye, fwd)
	ex, ey, ez = eye.x, eye.y, eye.z
	fx, fy, fz = fwd.x, fwd.y, fwd.z
end
local function Nums(p)
	local c, n = p.center, p.N
	p.cx, p.cy, p.cz, p.nx, p.ny, p.nz = c.x, c.y, c.z, n.x, n.y, n.z
	p.probePos = c + n * 4
end
local function InView(p)
	if not p.cx then Nums(p) end
	local dx, dy, dz = p.cx - ex, p.cy - ey, p.cz - ez
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if d > 5000 or dx * p.nx + dy * p.ny + dz * p.nz >= 0 then return false end
	if d < PATCH_R * 1.5 then return true end
	local c = (dx * fx + dy * fy + dz * fz) / d
	if c > 1 then c = 1 elseif c < -1 then c = -1 end
	return math.acos(c) < coneHalf + math.asin(PATCH_R / d) + 0.05
end
S.InView = function(p, eye, fwd) SetEye(eye, fwd) return InView(p) end

local function AftMat(aft)
	local m = aft.mat
	if not m then
		GPU.aftMatN = (GPU.aftMatN or 0) + 1
		m = GPU.Mat("wst" .. GPU.aftMatN, "world_vs30", "surfstatic_ps30", {
			["$basetexture"] = aft.rt:GetName(), ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture5"] = "ghm_physblood/probe_default", ["$linearread_texture5"] = 1, ["$texture7"] = GPU.MatTable():GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
			["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 }, true)
		aft.mat = m
	end
	return m
end

S.drawVer = S.drawVer or 0
local gPrev = {}
local function DrawGlobals()
	local cv = G.cv
	local fpos, fdir = G.Light.Flashlight()
	local g1, g2, g3, g4 = 0, 0, cv.normaldepth:GetFloat(), G.BloodAbsorb()
	local g5, g6, g7, g8 = cv.smooth:GetInt(), cv.dbgview:GetInt(), cv.reflect:GetFloat(), G.BloodHue()
	local g9, g10, g11 = cv.colDry:GetFloat(), cv.matlook:GetBool(), cv.poollook:GetFloat()
	if fpos or g1 ~= gPrev[1] or g2 ~= gPrev[2] or g3 ~= gPrev[3] or g4 ~= gPrev[4] or g5 ~= gPrev[5] or g6 ~= gPrev[6]
		or g7 ~= gPrev[7] or g8 ~= gPrev[8] or g9 ~= gPrev[9] or g10 ~= gPrev[10] or g11 ~= gPrev[11] or gPrev.fl then
		S.drawVer = S.drawVer + 1
		gPrev[1], gPrev[2], gPrev[3], gPrev[4], gPrev[5], gPrev[6], gPrev[7], gPrev[8], gPrev[9], gPrev[10] = g1, g2, g3, g4, g5, g6, g7, g8, g9, g10
		gPrev[11] = g11
	end
	gPrev.fl = fpos ~= nil
	return g3, g4, g5, g6 * 4
end

function S.DrawStatic()
	if not G.cv.enable:GetBool() or not next(S.after) then return end
	Shared()
	UpdateCone()
	local sw, sh = G.ViewSize()
	local now = CurTime()
	local rt = RealTime()
	SetEye(EyePos(), EyeAngles():Forward())
	local normalDepth, absorb, smooth, dbg = DrawGlobals()
	local ver = S.drawVer
	local refr = G.refractionView
	local dry = G.DryTime()
	local poolSettle = G.PoolSettleTime and G.PoolSettleTime() or G.SettleTime()
	S.UpdateAgeGroups(now)
	local forever = G.cv.forever:GetBool()
	local fadeStart = G.cv.aftfade:GetFloat() * 60
	local SetMaterial, LightGet = render.SetMaterial, G.Light.Get
	local Probes = G.Probes
	local Elem = G.Elem and G.Elem.Word and G.Elem
	local drawn, updated = 0, 0
	for _, a in pairs(S.after) do
		if (a.water or not refr) and InView(a) then
			local fade = forever and 1 or 1 - math.Clamp((now - a.bakedAt - fadeStart) / 30, 0, 1)
			if fade > 0 then
				local mat = AftMat(a.aft)
				local light = a.dLight
				if not light or rt - a.dLightT > 0.5 then
					light = LightGet(a, a.probePos, 0.5)
					a.dLight, a.dLightT = light, light.t or rt
				end
				local fq = math.floor(fade * 128 + 0.5)
				-- (1.26.6) what changes only over seconds (drying, age, shine, wetness, type) is worked out every ~0.4 s,
				-- not every frame (and at once after a re-bake)
				if not a.kT or now >= a.kT or now < a.kT - 1 then
					a.kT = now + 0.3 + 0.2 * math.random()
					a.kAge = G.DryAge(a, G.DryMult(a.surfName))
					a.kDq = math.floor(math.Clamp(a.kAge, 0, 250) * 64)
					a.kPair = S.PairCode(a.tkey or S.TypeKey(a), a.pair or a.btype)
					-- old blood is darker and duller: age since its blood arrived (older layers: since it settled)
					local gAge = now - (a.groupBorn or a.bornT or (a.bakedAt - poolSettle))
					a.kAq = math.floor(G.AgeFrac(gAge) * 32 + 0.5)
					a.kRq = math.floor(G.ShineAt(gAge) * 64 + 0.5)
					a.kWq = math.floor((G.FreshWet and G.FreshWet(gAge) or 1) * 16 + 0.5)
				end
				local aAge, dq, pair, aq, rq, wq = a.kAge, a.kDq, a.kPair, a.kAq, a.kRq, a.kWq
				local ew = a.el and Elem and Elem.Word(a.el) or 0
				local animated = ew >= 16
				if animated or a.dEw ~= ew or a.dVer ~= ver or a.dLit ~= light or a.dFq ~= fq or a.dDq ~= dq or a.dPair ~= pair
					or a.aft.mat ~= a.dMat or a.dSw ~= sw or a.dSh ~= sh or a.dAq ~= aq or a.dRq ~= rq or a.dWq ~= wq or a.dWp ~= a.woundPool then
					a.dWp = a.woundPool
					a.dVer, a.dLit, a.dFq, a.dDq, a.dPair, a.dMat, a.dSw, a.dSh, a.dEw = ver, light, fq, dq, pair, mat, sw, sh, ew
					a.dAq, a.dRq, a.dWq = aq, rq, wq
					GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / a.aft.res, animated and now or 0)
					GPU.SetC(mat, 1, a.oxy, S.LookPair(pair, a, true, wq / 16), GPU.PackZW(normalDepth, a.surf.fabric or 0, a.btype or 0))
					-- (1.26.9c) + 1024: a wounded body bled into this pool - its serum ring may show (ghmpb_serumOn in the shader)
					G.Light.Apply(mat, light, a.surf.rough, smooth + dbg + 32 * S.MatId(a.surfName) + ((a.woundPool and G.NewShaders and G.NewShaders()) and 1024 or 0),
						GPU.LayerWord(fq / 128, aAge), ew, rq / 64)
					G.Light.ApplySH4(mat, light, a.albedo.x, a.albedo.y, a.albedo.z, G.AbsorbAged(a.btype or 0, aq / 32))
					updated = updated + 1
				end
				if not a.bumpDone then S.AssignBump(a) end
				SetBump(mat, a)
				if Probes then Probes.Bind(mat, Probes.TexFor(a)) end
				SetMaterial(mat)
				S.DrawPatchMesh(a, 0.035)
				drawn = drawn + 1
			end
		end
	end
	G.Prof.Count("world old drawn", drawn)
	G.Prof.Count("world old constants set", updated)
end

S.POOL_FADEIN = 0.55
local enhVis = {}

local function ApplyPatchUniforms(mat, p, s, sw, sh, now, normalDepth, smooth, dbg, Probes, bindProbe)
	local light = G.Light.Get(p, p.probePos, 0.3)
	GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / s.res, now)
	local gAge = now - (p.groupBorn or p.bornT or p.touched or now)
	GPU.SetC(mat, 1, p.oxy, S.LookPair(S.PairCode(p.tkey or S.TypeKey(p), p.btype), p, false, G.FreshWet and G.FreshWet(gAge) or 1),
		GPU.PackZW(normalDepth, p.surf.fabric or 0, p.btype or 0))
	local ageF = G.AgeFrac(gAge)
	local fadeIn = 0.999
	if p.firstKind == 1 and p.firstT then
		local t = math.Clamp((now - p.firstT) / S.POOL_FADEIN, 0, 1)
		fadeIn = 0.999 * t * t * (3 - 2 * t)
	end
	local fedW = (p.fedT and now - p.fedT < 6 and G.NewShaders and G.NewShaders()
		and (not G.cv.ripples or G.cv.ripples:GetFloat() > 0)) and 1024 or 0
	G.Light.Apply(mat, light, p.surf.rough, smooth + dbg + 32 * S.MatId(p.surfName) + fedW, fadeIn,
		p.el and G.Elem and G.Elem.Word(p.el) or 0, G.ShineAt(gAge))
	G.Light.ApplySH4(mat, light, p.albedo.x, p.albedo.y, p.albedo.z, G.AbsorbAged(p.btype or 0, ageF))
	if not p.bumpDone then S.AssignBump(p) end
	SetBump(mat, p)
	if bindProbe and Probes then Probes.Bind(mat, Probes.TexFor(p)) end
end

function S.DrawOverlays()
	if not G.cv.enable:GetBool() then return end
	UpdateCone()
	local sw, sh = G.ViewSize()
	local now = CurTime()
	SetEye(EyePos(), EyeAngles():Forward())
	local normalDepth = G.cv.normaldepth:GetFloat()
	local smooth = G.cv.smooth:GetInt()
	local dbg = 4 * G.cv.dbgview:GetInt()
	local refr = G.refractionView
	local Probes = G.Probes
	S.UpdateAgeGroups(now)

	local useEnh = not refr and render.GetRenderTarget() == nil
		and G.cv.surfaceenh and G.cv.surfaceenh:GetBool()
		and S.EnhancedReady() and GPU.UpdateFBBlur ~= nil

	if useEnh then
		local nVis = 0
		for _, p in pairs(S.patches) do
			if p.hasBlood and not p.pendingBake and InView(p) and p.slot and p.slot.surfbase and p.slot.surfbase[p.cur] then
				nVis = nVis + 1
				enhVis[nVis] = p
			end
		end
		for i = nVis + 1, #enhVis do enhVis[i] = nil end
		if nVis == 0 then return end

		local fbBlurRT = GPU.UpdateFBBlur(sw, sh)
		local fbBlurName = fbBlurRT:GetName()

		-- Pass 1: optical body, meniscus refraction, sunlit rim caustics & substrate Kubelka-Munk
		for i = 1, nVis do
			local p = enhVis[i]
			local s = p.slot
			local mat = s.surfbase[p.cur]
			if s.fbBlurTex ~= fbBlurName then
				s.fbBlurTex = fbBlurName
				for k = 1, 2 do
					if s.surfbase[k] then s.surfbase[k]:SetTexture("$texture5", fbBlurRT) end
					if s.surfcoat[k] then s.surfcoat[k]:SetTexture("$texture6", fbBlurRT) end
				end
			end
			ApplyPatchUniforms(mat, p, s, sw, sh, now, normalDepth, smooth, dbg, Probes, false)
			render.SetMaterial(mat)
			S.DrawPatchMesh(p, 0.07)
		end

		-- Refresh _rt_FullFrameFB so Pass 2 composites specular, 3D bubbles & 6-tap SSR in linear light over Pass 1
		render.UpdateScreenEffectTexture()
		if G.Render then G.Render.copyFrame = FrameNumber() end

		-- Pass 2: dual-scale capillary ripples, 3D bubbles, full world meniscus glints & 6-step SSR
		for i = 1, nVis do
			local p = enhVis[i]
			local s = p.slot
			local mat = s.surfcoat[p.cur]
			ApplyPatchUniforms(mat, p, s, sw, sh, now, normalDepth, smooth, dbg, Probes, true)
			render.SetMaterial(mat)
			S.DrawPatchMesh(p, 0.07)
		end
		return
	end

	for _, p in pairs(S.patches) do
		if p.hasBlood and not p.pendingBake and (p.water or not refr) and InView(p) then
			local s = p.slot
			local mat = s.overlay[p.cur]
			ApplyPatchUniforms(mat, p, s, sw, sh, now, normalDepth, smooth, dbg, Probes, true)
			render.SetMaterial(mat)
			S.DrawPatchMesh(p, 0.07)
		end
	end
end

function S.Clear()
	for key in pairs(S.patches) do S.RemovePatch(key) end
	S.ClearAftermath()
	S.planeTypes = {}
	S.seepList = {}
	S.wet, S.wetN = {}, 0
end

function S.Counts()
	local a, b = 0, 0
	for _ in pairs(S.patches) do a = a + 1 end
	for _ in pairs(S.after) do b = b + 1 end
	return a, b
end

if not next(S.cells) then
	for _, p in pairs(S.patches) do p.cellKey = nil S.IndexAdd(p) end
	for _, a in pairs(S.after) do a.cellKey = nil S.IndexAdd(a) end
end
