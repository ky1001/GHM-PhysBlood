local G = GHMPB
G.GPU = G.GPU or {}
local GPU = G.GPU

local RT_FLAGS = bit.bor(4, 8, 256, 512, 32768)
GPU.FMT_F16 = IMAGE_FORMAT_RGBA16161616F
GPU.FMT_RGBA8 = IMAGE_FORMAT_RGBA8888

GPU.session = GPU.session or string.format("%x", math.floor(SysTime() * 1000) % 0xFFFFFF + math.random(0, 4095))
GPU.mats = GPU.mats or {}

local function DetectDX11()
	if ConVarExists("mat_dx11_deferred") or ConVarExists("r_dx11_simd") or ConVarExists("dx11_noslimcb") or ConVarExists("lux_dump_shaderparamhelp") then
		return true
	end
	return false
end
GPU.isDX11 = DetectDX11()

function GPU.Shader(name)
	if GPU.isDX11 then
		name = string.gsub(name, "_vs30$", "_vs50")
		name = string.gsub(name, "_ps30$", "_ps50")
	end
	return (G.ShaderPrefix or "ghmpb_") .. name
end
function GPU.Name(tag) return "ghmpb_" .. (G.ShaderPrefix or "") .. tag end
function GPU.MatName(tag) return "ghmpb_" .. (G.ShaderPrefix or "") .. GPU.session .. "_" .. tag end

function GPU.CreateMat(tag, shader, kv)
	local name = GPU.MatName(tag)
	local m = GPU.mats[name]
	if m then return m end
	m = CreateMaterial(name, shader, kv)
	GPU.mats[name] = m
	return m
end

function GPU.RT(tag, w, h, fmt)
	return GetRenderTargetEx(GPU.Name(tag), w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, RT_FLAGS, 0, fmt or GPU.FMT_F16)
end

function GPU.Mat(tag, vs, ps, kv, eight)
	local t = {
		["$vertexshader"] = GPU.Shader(vs),
		["$pixshader"] = GPU.Shader(ps),
		["$basetexture"] = "vgui/white",
		["$texture1"] = "vgui/white",
		["$texture2"] = "vgui/white",
		["$texture3"] = "vgui/white",
		["$copyalpha"] = 1,
		["$linearwrite"] = 1,
		["$linearread_basetexture"] = 1,
		["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1,
		["$linearread_texture3"] = 1,
		["$cull"] = 0,
		["$depthtest"] = 0,
		["$c0_x"] = 0,
	}
	if eight then
		for i = 4, 7 do t["$texture" .. i] = "vgui/white" t["$linearread_texture" .. i] = 1 end
	end
	for k, v in pairs(kv or {}) do t[k] = v end
	return GPU.CreateMat(tag, eight and "screenspace_general_8tex" or "screenspace_general", t)
end

GPU.ModelFlags = { ["$model"] = 1, ["$softwareskin"] = 1, ["$vertexnormal"] = 1 }
function GPU.Merge(a, b) local t = {} for k, v in pairs(a) do t[k] = v end for k, v in pairs(b or {}) do t[k] = v end return t end

function GPU.FreshAbs() return 1.85 * (math.max(G.cv.colFresh:GetFloat(), 0.3) ^ -1.6) end
-- (1.26.6) the hue and absorption the shaders get: cl_util.lua fits them to the player's own colours; the plain settings
-- if it did not load
G.BloodHue = G.BloodHue or function() return math.Clamp(G.cv.colHue:GetFloat(), -1, 1) end
G.BloodAbsorb = G.BloodAbsorb or function() return G.cv.absorb:GetFloat() * GPU.FreshAbs() end
G.BloodHueFor = G.BloodHueFor or function() return G.BloodHue() end
G.BloodAbsorbFor = G.BloodAbsorbFor or function() return G.BloodAbsorb() end
G.AgeFrac = G.AgeFrac or function() return 0 end
G.AbsorbAged = G.AbsorbAged or function(btype) return G.BloodAbsorbFor(btype) end
G.ShineAged = G.ShineAged or function() return 1 end
G.ShineAt = G.ShineAt or function() return 1 end
-- (1.26.6) btype: the blood type of the patch / body (own colours apply to red blood only)
function GPU.PackZW(normalDepth, fabric, btype)
	local hue = btype ~= nil and G.BloodHueFor(btype) or (G.BloodHue and G.BloodHue() or math.Clamp(G.cv.colHue:GetFloat(), -1, 1))   -- (1.26.6) -1..2 with own colours
	local dryMul = 1.65 * (math.max(G.cv.colDry:GetFloat(), 0.3) ^ -1.5) * (G.ShaderComp and G.ShaderComp().dry or 1)   -- (1.26.9c)
	return math.floor((hue + 1) * 100 + 0.5) * 8 + math.Clamp(normalDepth, 0, 7.9),
		math.floor(dryMul * 100 + 0.5) + math.Clamp(fabric or 0, 0, 1) * 0.999
end

local CNAME = {}
for i = 0, 31 do CNAME[i] = { "$c" .. i .. "_x", "$c" .. i .. "_y", "$c" .. i .. "_z", "$c" .. i .. "_w" } end
GPU.cCache = setmetatable({}, { __mode = "k" })
function GPU.SetC(mat, i, x, y, z, w)
	local n = CNAME[i]
	local c = GPU.cCache[mat]
	if not c then c = {} GPU.cCache[mat] = c end
	local b = i * 4
	x, y, z, w = x or 0, y or 0, z or 0, w or 0
	if c[b] ~= x then c[b] = x mat:SetFloat(n[1], x) end
	if c[b + 1] ~= y then c[b + 1] = y mat:SetFloat(n[2], y) end
	if c[b + 2] ~= z then c[b + 2] = z mat:SetFloat(n[3], z) end
	if c[b + 3] ~= w then c[b + 3] = w mat:SetFloat(n[4], w) end
end

local mtmp = Matrix()
GPU.rCache = setmetatable({}, { __mode = "k" })
function GPU.SetRowsN(mat, param, a1, a2, a3, a4, b1, b2, b3, b4, c1, c2, c3, c4, d1, d2, d3, d4)
	local c = GPU.rCache[mat]
	if not c then c = {} GPU.rCache[mat] = c end
	local v = c[param]
	if not v then v = {} c[param] = v end
	if v[1] == a1 and v[2] == a2 and v[3] == a3 and v[4] == a4 and v[5] == b1 and v[6] == b2 and v[7] == b3 and v[8] == b4
		and v[9] == c1 and v[10] == c2 and v[11] == c3 and v[12] == c4 and v[13] == d1 and v[14] == d2 and v[15] == d3 and v[16] == d4 then
		return
	end
	v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] = a1, a2, a3, a4, b1, b2, b3, b4
	v[9], v[10], v[11], v[12], v[13], v[14], v[15], v[16] = c1, c2, c3, c4, d1, d2, d3, d4
	mtmp:SetUnpacked(a1, a2, a3, a4, b1, b2, b3, b4, c1, c2, c3, c4, d1, d2, d3, d4)
	mat:SetMatrix(param, mtmp)
end
function GPU.SetRows(mat, param, r0, r1, r2, r3)
	GPU.SetRowsN(mat, param, r0[1] or 0, r0[2] or 0, r0[3] or 0, r0[4] or 0, r1[1] or 0, r1[2] or 0, r1[3] or 0, r1[4] or 0,
		r2[1] or 0, r2[2] or 0, r2[3] or 0, r2[4] or 0, r3[1] or 0, r3[2] or 0, r3[3] or 0, r3[4] or 0)
end

local CORNERS = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
local mPos, mTC, mAdv = mesh.Position, mesh.TexCoord, mesh.AdvanceVertex
local vtmp = Vector()

local function EmitQuad(W, H, x0, y0, x1, y1, p1, p2, p3)
	for ci = 1, 4 do
		local c = CORNERS[ci]
		local px = c[1] == 0 and x0 or x1
		local py = c[2] == 0 and y0 or y1
		local u, v = px / W, py / H
		if GPU.isDX11 then
			vtmp:SetUnpacked(u * 2 - 1, 1 - v * 2, 0)
		else
			vtmp:SetUnpacked(u * 2 - 1 - 1 / W, 1 - v * 2 + 1 / H, 0)
		end
		mPos(vtmp)
		mTC(0, u, v, 0, 0)
		if p1 then local q = (type(p1) == "function") and p1(ci, u, v) or p1 mTC(1, q[1], q[2], q[3], q[4]) end
		if p2 then local q = (type(p2) == "function") and p2(ci, u, v) or p2 mTC(2, q[1], q[2], q[3], q[4]) end
		if p3 then local q = (type(p3) == "function") and p3(ci, u, v) or p3 mTC(3, q[1], q[2], q[3], q[4]) end
		mAdv()
	end
end
GPU.EmitQuad = EmitQuad

local function EmitList(W, H, list, from, to)
	for i = from, to do
		local q = list[i]
		EmitQuad(W, H, q[1], q[2], q[3], q[4], q[5], q[6], q[7])
	end
end
function GPU.Quads(W, H, list)
	local n = #list
	if n == 0 then return end
	cam.Start2D()
	local done = 0
	while done < n do
		local batch = math.min(n - done, 4096)
		mesh.Begin(MATERIAL_QUADS, batch)
		local ok, err = pcall(EmitList, W, H, list, done + 1, done + batch)
		mesh.End()
		if not ok then ErrorNoHalt("[GHMPB] quad batch error: " .. tostring(err) .. "\n") break end
		done = done + batch
	end
	cam.End2D()
end

local fqItem = { 0, 0, 0, 0 }
local fqList = { fqItem }
function GPU.FullQuad(W, H, p1, p2, p3)
	fqItem[1], fqItem[2], fqItem[3], fqItem[4], fqItem[5], fqItem[6], fqItem[7] = 0, 0, W, H, p1, p2, p3
	GPU.Quads(W, H, fqList)
	fqItem[5], fqItem[6], fqItem[7] = nil, nil, nil
end

function GPU.Blit()
	if not GPU.matBlit then
		GPU.matBlit = GPU.Mat("blit", "clip_vs30", "blit_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
	return GPU.matBlit
end

function GPU.ClearTo(rt, x, y, z, w)
	render.PushRenderTarget(rt)
	render.SetMaterial(GPU.Blit())
	GPU.FullQuad(rt:Width(), rt:Height(), { x or 0, y or 0, z or 0, w or 0 })
	render.PopRenderTarget()
end

function GPU.Additive(on)
	if on then
		render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	else
		render.OverrideBlend(false)
	end
end

GPU.IMPACT_COLS = 64
function GPU.ImpactTable()
	if not GPU.rtImpacts then
		GPU.rtImpacts = GPU.RT("impacts", GPU.IMPACT_COLS, 4, GPU.FMT_F16)
	end
	return GPU.rtImpacts
end

local function EmitConst(W, H, x0, y0, a, b, c, d)
	local x1, y1 = x0 + 1, y0 + 1
	for ci = 1, 4 do
		local cc = CORNERS[ci]
		local u, v = (cc[1] == 0 and x0 or x1) / W, (cc[2] == 0 and y0 or y1) / H
		if GPU.isDX11 then
			vtmp:SetUnpacked(u * 2 - 1, 1 - v * 2, 0)
		else
			vtmp:SetUnpacked(u * 2 - 1 - 1 / W, 1 - v * 2 + 1 / H, 0)
		end
		mPos(vtmp)
		mTC(0, u, v, 0, 0)
		mTC(1, a, b, c, d)
		mAdv()
	end
end
local function EmitImpacts(W, H, list, first, count)
	for k = 0, count - 1 do
		local im = list[first + k]
		local v, n = im.vel, im.normal
		local px, py, pz = im.px, im.py, im.pz
		if not px then local p = im.pos px, py, pz = p.x, p.y, p.z end
		EmitConst(W, H, k, 0, px, py, pz, im.radius)
		EmitConst(W, H, k, 1, v.x, v.y, v.z, im.volume)
		local oxq = math.floor(math.Clamp(im.oxy or 0.75, 0, 1) * 10 + 0.5)
		EmitConst(W, H, k, 2, n.x, n.y, n.z, oxq + (im.seed or 0) * 0.99)
		local code = (im.kind or 0) + 8 * math.Clamp(math.floor(im.flags or 0), 0, 1) + 16 * math.Clamp(math.floor(im.spines or 0), 0, 60)
			+ (im.alt and 1024 or 0)
		local w = ((im.kind or 0) == 0 and im.K and im.K > 1.6) and math.min(im.K, 4000) or (im.residue or 0)
		EmitConst(W, H, k, 3, im.spin or 0, im.stretch or 1, code, w)
	end
end
function GPU.UploadImpacts(list, first, count)
	local rt = GPU.ImpactTable()
	local W, H = GPU.IMPACT_COLS, 4
	if count <= 0 then return rt end
	render.PushRenderTarget(rt)
	render.SetMaterial(GPU.Blit())
	cam.Start2D()
	mesh.Begin(MATERIAL_QUADS, count * 4)
	local ok, err = pcall(EmitImpacts, W, H, list, first, count)
	mesh.End()
	cam.End2D()
	render.PopRenderTarget()
	if not ok then ErrorNoHalt("[GHMPB] impact upload: " .. tostring(err) .. "\n") end
	return rt
end

GPU.MATTAB_W, GPU.MATTAB_H = 64, 8
function GPU.MatTable()
	if not GPU.rtMatTable then GPU.rtMatTable = GPU.RT("mattable", GPU.MATTAB_W, GPU.MATTAB_H, GPU.FMT_F16) end
	return GPU.rtMatTable
end
GPU.matTableT = GPU.matTableT or 0
function GPU.MatTableList()
	local list = {}
	for id = 0, 31 do
		for row, names in ipairs(G.SurfaceMatRows) do
			local v = {}
			for k = 1, 4 do v[k] = names[k] and G.SurfaceMatValue(id, names[k]) or 0 end
			list[#list + 1] = { id * 2, (row - 1) * 2, id * 2 + 2, row * 2, v }
		end
	end
	return list
end
function GPU.UploadMatTable(force)
	local now = RealTime()
	if not force and now < GPU.matTableT then return end
	GPU.matTableT = now + 2
	GPU.matTableList = GPU.matTableList or GPU.MatTableList()
	local rt = GPU.MatTable()
	render.PushRenderTarget(rt)
	render.SetMaterial(GPU.Blit())
	GPU.Quads(GPU.MATTAB_W, GPU.MATTAB_H, GPU.matTableList)
	render.PopRenderTarget()
end

GPU.dustPool = GPU.dustPool or {}
GPU.dustCount = GPU.dustCount or 0
function GPU.TakeDust(res)
	GPU.dustPool[res] = GPU.dustPool[res] or {}
	local d = table.remove(GPU.dustPool[res])
	if not d then
		GPU.dustCount = GPU.dustCount + 1
		d = { res = res, rt = GPU.RT("dust" .. res .. "_" .. GPU.dustCount, res, res, GPU.FMT_RGBA8) }
	end
	render.PushRenderTarget(d.rt) render.Clear(0, 0, 0, 0) render.PopRenderTarget()
	return d
end
function GPU.FreeDust(d)
	if not d then return end
	GPU.dustPool[d.res] = GPU.dustPool[d.res] or {}
	table.insert(GPU.dustPool[d.res], d)
end
function GPU.Zero()
	if not GPU.rtZero then
		GPU.rtZero = GPU.RT("zero4", 4, 4, GPU.FMT_RGBA8)
		render.PushRenderTarget(GPU.rtZero) render.Clear(0, 0, 0, 0) render.PopRenderTarget()
	end
	return GPU.rtZero
end

-- (1.26.11) quarter-resolution linear-light scene low-pass for the enhanced two-pass world blood surface shader
function GPU.FBBlur(sw, sh)
	local w = math.Clamp(math.floor((sw or ScrW()) * 0.25), 64, 1024)
	local h = math.Clamp(math.floor((sh or ScrH()) * 0.25), 64, 1024)
	if not GPU.rtFBBlur or GPU.fbBlurW ~= w or GPU.fbBlurH ~= h then
		GPU.fbBlurW, GPU.fbBlurH = w, h
		GPU.rtFBBlur = GPU.RT("fbblur_" .. w .. "x" .. h, w, h, GPU.FMT_RGBA8)
	end
	return GPU.rtFBBlur
end

function GPU.FBBlurMat()
	if not GPU.matFBBlur then
		GPU.matFBBlur = GPU.Mat("fbblur", "clip_vs30", "fbblur_ps30", {
			["$basetexture"] = "_rt_FullFrameFB", ["$linearread_basetexture"] = 1,
			["$tcsize0"] = 4, ["$linearwrite"] = 1 })
	end
	return GPU.matFBBlur
end

function GPU.UpdateFBBlur(sw, sh)
	sw, sh = math.max(sw or ScrW(), 1), math.max(sh or ScrH(), 1)
	local rt = GPU.FBBlur(sw, sh)
	local mat = GPU.FBBlurMat()
	GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1, 0)
	render.PushRenderTarget(rt)
	render.SetMaterial(mat)
	GPU.FullQuad(rt:Width(), rt:Height())
	render.PopRenderTarget()
	return rt
end

GPU.READBACK = 128
GPU.TILE = 8
function GPU.Readback()
	if not GPU.rtReadback then GPU.rtReadback = GPU.RT("readback", GPU.READBACK, GPU.READBACK, GPU.FMT_RGBA8) end
	return GPU.rtReadback
end
function GPU.TileOrigin(index)
	local per = GPU.READBACK / GPU.TILE
	return (index % per) * GPU.TILE, math.floor(index / per) * GPU.TILE
end

function GPU.SimParams(mat, sf, size, dt, mask, voidFlag, ox, oy, hf, parity, water, el, soakK, fed)
	local tauInv = G.DryMult(sf) / G.DryTime()
	local thick = G.cv.thickness:GetFloat()
	local visc = G.cv.viscosity:GetFloat()
	local heat, frost = el and el.heat or 0, el and el.frost or 0
	local muM, pinM, dryM, absM, clotM = 1, 1, 1, 1, 1
	if heat > 0 or frost > 0 then
		frost = frost * math.max(1 - heat * 2, 0)
		muM = 1 + 80 * frost * frost
		pinM = 1 + 6 * frost
		dryM = (1 + 60 * heat) * (1 - 0.95 * frost)
		absM = 1 - frost
		clotM = (1 + 6 * heat) * (1 - frost)
	end
	local world = hf and hf[1] == 1
	local floorFlow = world and (hf[4] or 0) > 300
	-- (1.26.9d) a pool a bleeding body is still feeding (fed 1 -> 0 over 6 s after the last inflow): the fresh blood flowing in
	-- keeps the edge moving - it grips the floor less and runs a little thinner, so the pool keeps pushing out in lobes and fills
	-- the gaps while the body bleeds, and settles once the bleeding stops
	fed = math.Clamp(fed or 0, 0, 1)
	if fed > 0 then muM, pinM = muM * (1 - 0.25 * fed), pinM * (1 - 0.38 * fed) end
	GPU.SetC(mat, 0, 1 / size, 1 / size, dt, mask or 0)
	GPU.SetC(mat, 1, sf.mu * visc * muM * (floorFlow and 0.58 or 1), sf.pin * pinM * (floorFlow and 0.52 or 1), sf.hret, sf.hdry)
	GPU.SetC(mat, 2, sf.lift * math.sqrt(thick), sf.liftk, tauInv * (sf.dryk or 1) * dryM, sf.kabs * absM * G.SoakMult() * (soakK or 1))
	GPU.SetC(mat, 3, sf.cap, sf.pressPin * (floorFlow and 0.55 or (world and 1.35 or 1)), 0.5, 0.5)
	local rate = G.cv.coag:GetBool() and (4.8 / G.CoagTime()) or 0
	rate = rate * clotM
	if heat > 0 and rate <= 0 then rate = 0.4 * heat end
	local w1, w2, w3 = -1e4, 0, 0
	if water then w1, w2, w3 = water[1], water[2] or 0, water[3] or 0 end
	local wash = G.cv.waterwash and G.cv.waterwash:GetFloat() or 1
	local p14 = (parity or 0) + 2 * math.floor(math.Clamp(wash, 0, 3) * 4 + 0.5)
	local h1, h2, h3, h4 = 0, 0, 0, 0
	if hf then h1, h2, h3, h4 = hf[1] or 0, hf[2] or 0, hf[3] or 0, hf[4] or 0 end
	GPU.SetRowsN(mat, "$viewprojmat", rate, G.CLOT_VISC or 30, G.CLOT_PIN or 4, math.Clamp(G.cv.crust:GetFloat(), 0, 0.95), voidFlag or 0, ox or 0, oy or 0, thick - 1,
		h1, h2, h3, h4, p14, w1, w2, w3)
end

GPU.aftPool = GPU.aftPool or {}
GPU.aftCount = GPU.aftCount or 0
function GPU.TakeAft(res)
	GPU.aftPool[res] = GPU.aftPool[res] or {}
	local a = table.remove(GPU.aftPool[res])
	if not a then
		GPU.aftCount = GPU.aftCount + 1
		if G.Budget then G.Budget.Count("aft", res) end
		a = { res = res, rt = GPU.RT("aft" .. res .. "_" .. GPU.aftCount, res, res, GPU.FMT_RGBA8) }
	end
	render.PushRenderTarget(a.rt) render.Clear(0, 0, 0, 0) render.PopRenderTarget()
	a.used = false
	return a
end

function GPU.FreeAft(a)
	if not a then return end
	GPU.aftPool[a.res] = GPU.aftPool[a.res] or {}
	table.insert(GPU.aftPool[a.res], a)
end

local scratch = {}
local function Scratch(res)
	if not scratch[res] then scratch[res] = GPU.RT("aftscratch" .. res, res, res, GPU.FMT_RGBA8) end
	return scratch[res]
end

local function uvPayload(ci, u, v) return { u, v, 0, 0 } end
GPU.UVPayload = uvPayload

function GPU.Copy(dst, src)
	if not GPU.matCopyF then
		GPU.matCopyF = GPU.Mat("copyf", "clip_vs30", "copy_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
	GPU.matCopyF:SetTexture("$basetexture", src)
	render.PushRenderTarget(dst)
	render.SetMaterial(GPU.matCopyF)
	GPU.FullQuad(dst:Width(), dst:Height(), uvPayload)
	render.PopRenderTarget()
end

function GPU.BakeInto(a, state, aux, bed, dryT, acc)
	local res = a.res
	if not GPU.matBake then
		GPU.matBake = GPU.Mat("bake", "clip_vs30", "bake_ps30", { ["$tcsize0"] = 4 })
		GPU.matCopy = GPU.Mat("aftcopy", "clip_vs30", "peek_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
		GPU.SetC(GPU.matCopy, 0, 1, 1, 1, 1)
		GPU.SetC(GPU.matCopy, 1, 0, 0, 0, 0)
	end
	local old = nil
	if a.used then
		old = Scratch(res)
		GPU.matCopy:SetTexture("$basetexture", a.rt)
		render.PushRenderTarget(old)
		render.SetMaterial(GPU.matCopy)
		GPU.FullQuad(res, res, uvPayload)
		render.PopRenderTarget()
	end
	local m = GPU.matBake
	m:SetTexture("$basetexture", state)
	m:SetTexture("$texture1", aux)
	m:SetTexture("$texture2", old or "vgui/white")
	m:SetTexture("$texture3", bed or acc or "vgui/white")
	GPU.SetC(m, 0, old and 1 or 0, bed and 1 or 0, old and (dryT or 0) or 0, (not bed and acc) and 1 or 0)
	render.PushRenderTarget(a.rt)
	render.SetMaterial(m)
	GPU.FullQuad(res, res)
	render.PopRenderTarget()
	a.used = true
end

function GPU.LayerWord(fade, dry)
	return math.floor(math.Clamp(dry or 0, 0, 250) * 64) + math.Clamp(fade or 1, 0, 1) * 0.999
end
