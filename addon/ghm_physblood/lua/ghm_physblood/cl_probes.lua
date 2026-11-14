local G = GHMPB
G.Probes = G.Probes or {}
local P = G.Probes
local GPU = G.GPU

P.ATLAS, P.FACE, P.BLUR = 512, 128, 32
P.CELL = 256
P.RADIUS_MIN, P.RADIUS_MAX = 48, 1000
P.DEFAULT = "ghm_physblood/probe_default"
P.FACES = { Angle(0, 0, 0), Angle(0, 180, 0), Angle(0, 90, 0), Angle(0, -90, 0), Angle(-90, 0, 0), Angle(90, 0, 0) }
P.FACE_DIR = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
P.list = P.list or {}
P.free = P.free or {}
P.made = P.made or 0
P.stats = P.stats or { faces = 0, ms = 0, avg = 0, last = 0, fills = 0, data = 0, errors = 0 }
P.bound = setmetatable({}, { __mode = "k" })

local RTF = bit.bor(4, 8, 256, 512, 32768)
local function NewRT(tag, w, h, depth)
	return GetRenderTargetEx(GPU.Name(tag), w, h, RT_SIZE_LITERAL, depth or MATERIAL_RT_DEPTH_NONE, RTF, 0, IMAGE_FORMAT_RGBA8888)
end
function P.FaceRT()
	if not P.faceRT then P.faceRT = NewRT("probeface", P.FACE, P.FACE, MATERIAL_RT_DEPTH_SEPARATE) end
	return P.faceRT
end
function P.Scratch()
	if not P.scratch then P.scratch = NewRT("probescr", P.ATLAS, P.ATLAS) end
	return P.scratch
end
local function MaxProbes()
	local cv = G.cv.reflprobes
	return cv and math.Clamp(cv:GetInt(), 0, 6) or 2
end

local envMat, blurMat, copyMat
local function Mats()
	if envMat then return end
	envMat = GPU.Mat("probeenv", "clip_vs30", "probeenv_ps30", { ["$basetexture"] = "env_cubemap", ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	blurMat = GPU.Mat("probeblur", "clip_vs30", "probeblur_ps30", { ["$basetexture"] = P.Scratch():GetName(), ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	copyMat = GPU.Mat("probecopy", "clip_vs30", "copy_ps30", { ["$basetexture"] = P.FaceRT():GetName(), ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
end

local TILES_ENV, TILES_BLUR = {}, {}
for f = 0, 5 do
	local c, r = f % 3, math.floor(f / 3)
	TILES_ENV[#TILES_ENV + 1] = { c * P.FACE, r * P.FACE, (c + 1) * P.FACE, (r + 1) * P.FACE, { f, c * P.FACE, r * P.FACE, P.FACE } }
	local blur = { f * P.BLUR, 256, (f + 1) * P.BLUR, 256 + P.BLUR, { f, f * P.BLUR, 256, P.BLUR } }
	TILES_ENV[#TILES_ENV + 1] = blur
	TILES_BLUR[#TILES_BLUR + 1] = blur
end
local CORNER_UV = { { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 1, 1, 0, 0 }, { 0, 1, 0, 0 } }
local function CornerUV(ci) return CORNER_UV[ci] end

function P.FillEnv(rt)
	Mats()
	render.PushRenderTarget(rt)
	render.SetMaterial(envMat)
	GPU.Quads(P.ATLAS, P.ATLAS, TILES_ENV)
	render.PopRenderTarget()
	P.stats.fills = P.stats.fills + 1
end

function P.Blur(rt)
	Mats()
	render.CopyTexture(rt, P.Scratch())
	render.PushRenderTarget(rt)
	render.SetMaterial(blurMat)
	GPU.Quads(P.ATLAS, P.ATLAS, TILES_BLUR)
	render.PopRenderTarget()
end

local function B(v) return math.Clamp(math.floor(v + 0.5), 0, 255) / 255 end
local function U16(x)
	local q = math.Clamp(math.floor((x + 16384) / 32768 * 65535 + 0.5), 0, 65535)
	return math.floor(q / 256), q % 256
end
P.U16 = U16
function P.DataTexels(pos, radius, valid, lights)
	local list = {}
	local function px(x, y, a, b, c, d) list[#list + 1] = { x, y, x + 1, y + 1, { B(a), B(b), B(c), B(d) } } end
	pos = pos or vector_origin
	local hx, lx = U16(pos.x)
	local hy, ly = U16(pos.y)
	local hz, lz = U16(pos.z)
	px(384, 0, hx, lx, hy, ly)
	px(385, 0, hz, lz, (radius or 0) / 8, valid and 255 or 0)
	for i = 1, 4 do
		local l = lights and lights[i]
		if l then
			local ax, bx = U16(l.pos.x)
			local ay, by = U16(l.pos.y)
			local az, bz = U16(l.pos.z)
			px(384, i, ax, bx, ay, by)
			px(385, i, az, bz, math.min((l.range or 4096) / 64, 255), l.type)
			local e = math.Clamp((math.log(math.max(l.I or 0, 1e-6)) / math.log(2) + 4) / 24, 0, 1)
			px(386, i, l.col.x * 255, l.col.y * 255, l.col.z * 255, e * 255)
			local d = l.dir or Vector(0, 0, -1)
			px(387, i, (d.x * 0.5 + 0.5) * 255, (d.y * 0.5 + 0.5) * 255, (d.z * 0.5 + 0.5) * 255, math.Clamp(l.cosO or 0, 0, 1) * 255)
		else
			px(385, i, 0, 0, 0, 0)
		end
	end
	return list
end
function P.WriteData(rt, pos, radius, valid, lights)
	render.PushRenderTarget(rt)
	render.SetMaterial(GPU.Blit())
	GPU.Quads(P.ATLAS, P.ATLAS, P.DataTexels(pos, radius, valid, lights))
	render.PopRenderTarget()
	P.stats.data = P.stats.data + 1
end

local trOut = {}
local trData = { mask = MASK_SOLID_BRUSHONLY, output = trOut }
local DIRS = {}
for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
	{ 1, 1, 1 }, { -1, 1, 1 }, { 1, -1, 1 }, { -1, -1, 1 }, { 1, 1, -1 }, { -1, 1, -1 }, { 1, -1, -1 }, { -1, -1, -1 } }) do
	DIRS[#DIRS + 1] = Vector(d[1], d[2], d[3]):GetNormalized()
end
function P.Place(center, n)
	for _, lift in ipairs({ 10, 24, 48 }) do
		local p = center + n * lift
		if bit.band(util.PointContents(p), CONTENTS_SOLID) == 0 then return p end
	end
	return center + n * 10
end
function P.Radius(pos)
	local ds = {}
	for _, d in ipairs(DIRS) do
		trData.start, trData.endpos = pos, pos + d * P.RADIUS_MAX
		local tr = util.TraceLine(trData) or trOut
		ds[#ds + 1] = (tr.Hit and not tr.StartSolid) and tr.Fraction * P.RADIUS_MAX or P.RADIUS_MAX
	end
	table.sort(ds)
	return math.Clamp(ds[math.floor(#ds / 2) + 1], P.RADIUS_MIN, P.RADIUS_MAX)
end

local function Zero(rt)
	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 0)
	render.PopRenderTarget()
	return rt
end
local function NewAtlas()
	local rt = table.remove(P.free)
	if rt then return rt end
	if P.made >= 6 then return nil end
	P.made = P.made + 1
	return Zero(NewRT("probe" .. P.made, P.ATLAS, P.ATLAS))
end

local function Key(c) return math.floor(c.x / P.CELL) .. "," .. math.floor(c.y / P.CELL) .. "," .. math.floor(c.z / P.CELL) end
P.Key = Key
function P.Regroup()
	local S = G.Surfaces
	local groups = {}
	local function add(p, w)
		local c, n = p.center, p.N
		if not c or not n then return end
		local k = Key(c)
		local g = groups[k]
		if not g then g = { key = k, w = 0, sum = Vector(0, 0, 0), nsum = Vector(0, 0, 0), members = {} } groups[k] = g end
		g.w = g.w + w
		g.sum:Add(c * w)
		g.nsum:Add(n * w)
		g.members[#g.members + 1] = p
	end
	for _, p in pairs(S.patches or {}) do if p.hasBlood then add(p, 2) end end
	for _, a in pairs(S.after or {}) do add(a, 1) end
	local eye = (MainEyePos or EyePos)()
	local fwd = (MainEyeAngles or EyeAngles)():Forward()
	local ranked = {}
	for k, g in pairs(groups) do
		g.center = g.sum / g.w
		local dist = g.center:Distance(eye)
		if dist < 3500 then
			local front = (g.center - eye):Dot(fwd) > -150 and 1.5 or 1
			g.score = math.sqrt(g.w) * front / (1 + dist / 500) * (P.list[k] and 1.4 or 1)
			ranked[#ranked + 1] = g
		end
	end
	table.sort(ranked, function(a, b) return a.score > b.score end)
	local keep = {}
	for i = 1, math.min(MaxProbes(), #ranked) do keep[ranked[i].key] = ranked[i] end
	for k, pr in pairs(P.list) do
		if not keep[k] then
			P.free[#P.free + 1] = pr.rt
			P.list[k] = nil
		end
	end
	for k, g in pairs(keep) do
		local pr = P.list[k]
		local n = g.nsum:LengthSqr() > 1e-6 and g.nsum:GetNormalized() or Vector(0, 0, 1)
		local pos = P.Place(g.center, n)
		if not pr then
			local rt = NewAtlas()
			if rt then
				pr = { key = k, rt = rt, faceT = { -1e9, -1e9, -1e9, -1e9, -1e9, -1e9 }, valid = false, dataT = 0 }
				pr.pos, pr.n, pr.radius = pos, n, P.Radius(pos)
				P.FillEnv(rt)
				P.list[k] = pr
			end
		elseif pr.pos:DistToSqr(pos) > 48 * 48 then
			pr.pos, pr.n, pr.radius = pos, n, P.Radius(pos)
			for f = 1, 6 do pr.faceT[f] = -1e9 end
			pr.valid, pr.dataT = false, 0
		end
		if pr then pr.score = g.score end
	end
	for _, g in pairs(groups) do
		local pr = P.list[g.key]
		for _, m in ipairs(g.members) do m.reflRT = pr and pr.rt or nil end
	end
end

local view = { x = 0, y = 0, w = 128, h = 128, fov = 90, aspect = 1, drawhud = false, drawmonitors = false,
	drawviewmodel = false, dopostprocess = false, bloomtone = false, znear = 1.5 }
function P.RenderFace(pr, f)
	Mats()
	view.origin, view.angles = pr.pos, P.FACES[f]
	view.w, view.h = P.FACE, P.FACE
	view.zfar = math.Clamp(pr.radius * 6, 600, 4000)
	P.rendering = true
	-- (1.26.8) the probe's view without the engine's shadows: rendering them for this view (from the middle of a pool,
	-- often inside the bodies lying in it) re-sized and re-drew the shadow textures the main view uses, so the shadows of
	-- those bodies came and went (r_shadows_gamecontrol, as a shadow_control entity sets it; left alone when the map has
	-- the shadows off)
	local sc = GetConVar and GetConVar("r_shadows_gamecontrol")
	local noShadows = render.SetShadowsDisabled and not (sc and sc:GetInt() == 0)
	if noShadows then render.SetShadowsDisabled(true) end
	render.PushRenderTarget(P.FaceRT())
	render.Clear(0, 0, 0, 255, true, true)
	local ok, err = pcall(render.RenderView, view)
	render.PopRenderTarget()
	if noShadows then render.SetShadowsDisabled(false) end
	P.rendering = false
	if not ok then
		P.stats.errors = P.stats.errors + 1
		G.DiagCount("probes: a view failed to render") G.Diag.lastError = tostring(err)
		if P.stats.errors >= 3 then P.disabled = true ErrorNoHalt("[GHMPB] reflection probes off: " .. tostring(err) .. "\n") end
		return false
	end
	local c, r = (f - 1) % 3, math.floor((f - 1) / 3)
	render.PushRenderTarget(pr.rt)
	render.SetMaterial(copyMat)
	GPU.Quads(P.ATLAS, P.ATLAS, { { c * P.FACE, r * P.FACE, (c + 1) * P.FACE, (r + 1) * P.FACE, CornerUV } })
	render.PopRenderTarget()
	return true
end

function P.Step()
	if P.disabled or not G.cv.enable:GetBool() then return end
	if G.Lite and G.Lite.on then return end
	local now = RealTime()
	local dt = math.Clamp(now - (P.lastT or now), 0, 0.25)
	P.lastT = now
	Mats()
	if not P.fb or now - (P.fbT or 0) > 2 then
		P.fb = P.fb or Zero(NewRT("probefb", P.ATLAS, P.ATLAS))
		P.FillEnv(P.fb)
		local mep = (MainEyePos or EyePos)()
		P.WriteData(P.fb, mep, 0, false, G.MapLights and G.MapLights.Pick(mep, 4, "fb") or nil)
		P.fbT = now
		P.fbReady = true
	end
	if MaxProbes() == 0 then
		if next(P.list) then for k, pr in pairs(P.list) do P.free[#P.free + 1] = pr.rt P.list[k] = nil end end
		return
	end
	if now - (P.groupT or 0) > 0.5 then
		P.groupT = now
		P.Regroup()
	end
	for _, pr in pairs(P.list) do
		if now - (pr.dataT or 0) > 0.5 then
			pr.dataT = now
			pr.lights = G.MapLights and G.MapLights.Pick(pr.pos, 4, pr.key) or nil
			P.WriteData(pr.rt, pr.pos, pr.radius, pr.valid, pr.lights)
		end
	end
	local budget = G.cv.reflbudget and G.cv.reflbudget:GetFloat() or 20
	if G.Gov and (G.Gov.p or 0) > 0.8 then budget = budget * 0.25 end
	P.tokens = math.min((P.tokens or 0) + budget * dt, math.max(budget * 0.5, 8))
	if P.tokens <= 0 then return end
	local best, bf, bw = nil, nil, -1
	for _, pr in pairs(P.list) do
		for f = 1, 6 do
			local age = now - pr.faceT[f]
			if age > 0.3 then
				local w = age * (pr.score or 1) * (P.FACE_DIR[f]:Dot(pr.n) < -0.7 and 0.25 or 1)
				if w > bw then best, bf, bw = pr, f, w end
			end
		end
	end
	if not best then return end
	local t0 = SysTime()
	if not P.RenderFace(best, bf) then return end
	best.faceT[bf] = now
	if not best.valid then
		local all = true
		for f = 1, 6 do if best.faceT[f] < -1e8 then all = false break end end
		if all then best.valid, best.dataT = true, 0 end
	end
	P.Blur(best.rt)
	local ms = (SysTime() - t0) * 1000
	P.tokens = P.tokens - ms
	P.stats.faces = P.stats.faces + 1
	P.stats.ms = P.stats.ms + ms
	P.stats.last = ms
	P.stats.avg = P.stats.avg * 0.9 + ms * 0.1
	G.Prof.Lap("probes", t0)
end

-- (1.26.1 vm fix) the faces are rendered at the start of the frame (RenderScene, before the main view), not at its end
-- (PostRender): after a render.RenderView the global EyeAngles() / EyePos() keep that view until the next main view
-- starts, and weapon bases read them for the viewmodel's sway (ARC9: EyeAngles() - last EyeAngles() every frame), so
-- each probe face jerked the gun. The main view that follows RenderScene puts the render context back.
local function ProbeStep()
	if P.rendering then return end
	local ok, err = pcall(P.Step)
	if not ok then
		P.rendering = false
		P.stats.errors = P.stats.errors + 1
		G.DiagCount("error: probes") G.Diag.lastError = tostring(err)
		if P.stats.errors < 5 then ErrorNoHalt("[GHMPB] probes: " .. tostring(err) .. "\n") else P.disabled = true end
	end
end
hook.Remove("PostRender", "ghmpb_probes")
hook.Add("RenderScene", "ghmpb_probes", function() ProbeStep() end)
-- while a probe view renders, the viewmodel and the camera keep their values: a weapon base must not step its
-- viewmodel springs (sway, inertia, look) with a probe view's angles (ArcCW / ARC9 tremor)
hook.Add("CalcViewModelView", "ghmpb_probes", function(wep, vm, oldPos, oldAng, pos, ang)
	if P.rendering and IsValid(vm) then return vm:GetPos(), vm:GetAngles() end
end)
hook.Add("CalcView", "ghmpb_probes", function(ply, origin, angles, fov, znear, zfar)
	if P.rendering then return { origin = origin, angles = angles, fov = fov, znear = znear, zfar = zfar } end
end)

function P.TexFor(obj)
	if obj and obj.reflRT and not P.disabled then return obj.reflRT end
	return P.fbReady and P.fb or nil
end
function P.TexAt(pos)
	if not P.disabled then
		local best, bd = nil, 400 * 400
		for _, pr in pairs(P.list) do
			local d = pr.pos:DistToSqr(pos)
			if d < bd then best, bd = pr, d end
		end
		if best then return best.rt end
	end
	return P.fbReady and P.fb or nil
end
function P.Bind(mat, tex)
	if tex and P.bound[mat] ~= tex then
		mat:SetTexture("$texture5", tex)
		P.bound[mat] = tex
	end
end

function P.Clear()
	for k, pr in pairs(P.list) do P.free[#P.free + 1] = pr.rt P.list[k] = nil end
end
hook.Add("InitPostEntity", "ghmpb_probes", function() P.Clear() P.fbT = 0 P.disabled = nil P.stats.errors = 0 end)

function P.Describe()
	local n, valid = 0, 0
	for _, pr in pairs(P.list) do n = n + 1 if pr.valid then valid = valid + 1 end end
	return string.format("reflection probes: %d (%d rendered all round) of %d, faces rendered %d, %.1f ms a face (last %.1f), budget %s ms/s%s",
		n, valid, MaxProbes(), P.stats.faces, P.stats.avg, P.stats.last, tostring(G.cv.reflbudget and G.cv.reflbudget:GetFloat()),
		P.disabled and " - OFF after errors" or "")
end
