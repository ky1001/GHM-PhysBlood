local G = GHMPB
G.Dust = G.Dust or {}
local D = G.Dust
local GPU = G.GPU

D.events = D.events or {}
D.queue = D.queue or {}
D.stats = D.stats or { blasts = 0, pulses = 0, live = 0, settled = 0, bodies = 0, puffs = 0, skipped = 0 }
D.PULSES = { { 0.35, 0.18 }, { 0.8, 0.2 }, { 1.4, 0.18 }, { 2.2, 0.16 }, { 3.2, 0.14 }, { 4.6, 0.14 } }
D.TOTAL = 1.5

local function On() return G.cv.enable:GetBool() and G.cv.blastdust:GetBool() end
D.On = On

local gTr = { mask = MASK_SOLID_BRUSHONLY }
local OFFS = {}
for i = 0, 6 do OFFS[i] = i == 0 and { 0, 0 } or { math.cos(i * 1.0472) * 40, math.sin(i * 1.0472) * 40 } end
function D.GroundKind(pos, depth)
	depth = depth or 260
	local votes, best, bn = {}, nil, 0
	local ground, normal
	for i = 0, 6 do
		local o = OFFS[i]
		gTr.start = Vector(pos.x + o[1], pos.y + o[2], pos.z + 8)
		gTr.endpos = Vector(pos.x + o[1], pos.y + o[2], pos.z - depth)
		local tr = util.TraceLine(gTr)
		if tr.Hit and not tr.StartSolid and not tr.HitSky then
			if not ground then ground, normal = tr.HitPos, tr.HitNormal end
			local kind = G.SurfaceKindOf(tr)
			local dk = kind ~= "water" and (G.DustKindOf[kind] or 8) or nil
			if dk and bit.band(util.PointContents(tr.HitPos + Vector(0, 0, 2)), CONTENTS_WATER) ~= 0 then dk = nil end
			if dk then
				votes[dk] = (votes[dk] or 0) + 1
				if votes[dk] > bn then best, bn = dk, votes[dk] end
			end
		end
	end
	if not ground or not best then return nil end
	return best, ground, normal
end

local function SetDust(o, kind, soot, w)
	local s = o.dust
	if not s then s = { k = kind, soot = soot, w = 0 } o.dust = s end
	if kind ~= s.k then
		if w > s.w then s.k = kind end
	end
	s.soot = math.max(s.soot * 0.9, soot)
	s.w = s.w + w
	s.t = CurTime()
	return s
end
D.SetDust = SetDust
function D.Word(s) return s and (s.k + 16 * math.Clamp(math.floor(s.soot * 7 + 0.5), 0, 7)) or 0 end

function D.Blast(pos, r, s, kind, src)
	if not On() or not pos then return false end
	local gk, g, n = D.GroundKind(pos)
	if not gk then D.stats.skipped = D.stats.skipped + 1 return false end
	kind = kind or gk
	local hgt = math.max(pos.z - g.z, 0)
	s = (s or 1) * math.Clamp(1 - hgt / math.max(r * 1.2, 1), 0, 1)
	if s < 0.05 then D.stats.skipped = D.stats.skipped + 1 return false end
	local now = CurTime()
	for _, ev in ipairs(D.events) do
		if now - ev.t0 < 1.0 and ev.g:DistToSqr(g) < (ev.r * 0.5) ^ 2 then
			if not (src and ev.src and src ~= ev.src) then ev.s = math.min(ev.s + s * 0.5, 1.6) end
			return true
		end
	end
	D.stats.blasts = D.stats.blasts + 1
	G.DiagCount("dust: blasts")
	D.events[#D.events + 1] = { pos = Vector(pos), g = g, n = n, r = r, s = s, kind = kind, t0 = now, i = 1, src = src }
	D.Puff(g, n, r, s, kind)
	if G.Flies then G.Flies.Disturb(g, r * 1.5) end
	return true
end

local function Reach(ev, t) return ev.r * (0.55 + 0.45 * math.min(t / 2.5, 1)) end
local function Soot(ev, dist) return math.Clamp(0.75 - dist / (ev.r * 0.6), 0, 0.75) * (ev.kind == 8 and 0 or 1) end

local function Pulse(ev, t, k)
	local S, E = G.Surfaces, G.Entities
	local R = Reach(ev, t)
	local P = S.PATCH_UNITS
	local g = ev.g
	local amt = k * ev.s * D.TOTAL
	D.stats.pulses = D.stats.pulses + 1
	if S.Element(g, R, 14, math.min(amt, 1)) > 0 then
		local reach2 = (R + P * 0.75) ^ 2
		for _, p in pairs(S.patches) do
			if p.hasBlood and p.slot and p.center:DistToSqr(g) < reach2 and math.abs((g - p.origin):Dot(p.N)) < math.max(R * 0.7, 12) then
				local dist = p.center:Distance(g)
				SetDust(p, ev.kind, Soot(ev, dist), amt * math.Clamp(1 - dist / R, 0, 1))
				D.stats.live = D.stats.live + 1
			end
		end
	end
	local reach2 = (R + P * 0.75) ^ 2
	for key, a in pairs(S.after) do
		if a.center:DistToSqr(g) < reach2 and math.abs((g - a.origin):Dot(a.N)) < math.max(R * 0.7, 12) then
			local dist = a.center:Distance(g)
			SetDust(a, ev.kind, Soot(ev, dist), amt * math.Clamp(1 - dist / R, 0, 1))
			local q = D.queue[a]
			if not q then q = { a = a, list = {} } D.queue[a] = q end
			if #q.list < 32 then q.list[#q.list + 1] = { wpos = g, radius = R, strength = math.min(amt, 1) } end
		end
	end
	for ent, d in pairs(E.domains) do
		if IsValid(ent) and ent:WorldSpaceCenter():DistToSqr(g) < (R + ent:BoundingRadius()) ^ 2 then
			local dist = ent:GetPos():Distance(g)
			SetDust(d, ev.kind, Soot(ev, dist), amt)
			if E.IsLive(d) then
				E.Element(ent, g, R, 14, math.min(amt, 1))
			end
			if E.HasAft(d) then
				local q = D.queue[d]
				if not q then q = { d = d, ent = ent, list = {} } D.queue[d] = q end
				if #q.list < 32 then q.list[#q.list + 1] = { wpos = g, radius = R, strength = math.min(amt, 1) } end
			end
			D.stats.bodies = D.stats.bodies + 1
		end
	end
end

function D.Update()
	if #D.events == 0 then return end
	local now = CurTime()
	local i = 1
	while i <= #D.events do
		local ev = D.events[i]
		local t = now - ev.t0
		while ev.i <= #D.PULSES and t >= D.PULSES[ev.i][1] do
			local ok, err = pcall(Pulse, ev, t, D.PULSES[ev.i][2])
			if not ok then G.Diag.lastError = "dust: " .. tostring(err) end
			ev.i = ev.i + 1
		end
		if ev.i > #D.PULSES then table.remove(D.events, i) else i = i + 1 end
	end
end

local SMOKE = {}
for i = 1, 9 do SMOKE[i] = "particle/smokesprites_000" .. i end
D.COLORS = { { 196, 172, 132 }, { 236, 240, 246 }, { 112, 90, 66 }, { 168, 164, 156 }, { 222, 218, 208 }, { 168, 96, 72 },
	{ 176, 140, 96 }, { 62, 60, 58 }, { 104, 100, 70 }, { 150, 144, 136 } }
local em
function D.Puff(g, n, r, s, kind)
	if not G.cv.elemsteam:GetBool() then return end
	if GHM_PFX then return end
	local eye = EyePos()
	if g:DistToSqr(eye) > 3500 * 3500 then return end
	if not em or not em:IsValid() then em = ParticleEmitter(g, false) end
	if not em then return end
	em:SetPos(g)
	local c = D.COLORS[kind] or D.COLORS[4]
	local up = n or Vector(0, 0, 1)
	local count = math.Clamp(math.floor(10 + 14 * s), 8, 26)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.Rand(-0.2, 0.2)
		local dir = Vector(math.cos(a), math.sin(a), 0)
		local pt = em:Add(SMOKE[math.random(1, 9)], g + dir * math.Rand(4, 16) + up * 4)
		if pt then
			pt:SetVelocity(dir * math.Rand(0.5, 1.1) * r * 1.6 + up * math.Rand(20, 90))
			pt:SetAirResistance(140)
			pt:SetGravity(Vector(0, 0, -30))
			pt:SetDieTime(math.Rand(3.5, 6.5))
			pt:SetStartAlpha(math.Clamp(110 * s, 40, 150))
			pt:SetEndAlpha(0)
			pt:SetStartSize(math.Rand(10, 22))
			pt:SetEndSize(math.Rand(40, 80) * math.Clamp(r / 250, 0.6, 1.6))
			pt:SetRoll(math.Rand(0, 360))
			pt:SetRollDelta(math.Rand(-0.4, 0.4))
			local v = math.Rand(0.85, 1.1)
			pt:SetColor(c[1] * v, c[2] * v, c[3] * v)
			pt:SetLighting(true)
		end
	end
	if kind ~= 8 then
		for _ = 1, math.floor(12 * s) do
			local pt = em:Add("effects/fleck_cement" .. math.random(1, 2), g + up * 6 + VectorRand() * 10)
			if pt then
				pt:SetVelocity((VectorRand() + up * 1.6):GetNormalized() * math.Rand(120, 320) * math.Clamp(s, 0.5, 1.3))
				pt:SetGravity(Vector(0, 0, -600))
				pt:SetCollide(true)
				pt:SetBounce(0.2)
				pt:SetDieTime(math.Rand(1.5, 3))
				pt:SetStartAlpha(255)
				pt:SetEndAlpha(0)
				local sz = math.Rand(0.6, 1.6)
				pt:SetStartSize(sz)
				pt:SetEndSize(sz)
				pt:SetRoll(math.Rand(0, 360))
				pt:SetColor(c[1] * 0.8, c[2] * 0.8, c[3] * 0.8)
				pt:SetLighting(true)
			end
		end
	end
	D.stats.puffs = D.stats.puffs + 1
end

local aftMat, bodyAftMat, peekMat
local function Mats()
	if not aftMat then
		aftMat = GPU.Mat("dustaft", "clip_vs30", "dustaft_ps30", {
			["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white", ["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4 })
		bodyAftMat = GPU.Mat("dustaftb", "unwrap_vs30", "dustaft_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = GPU.ImpactTable():GetName(), ["$texture1"] = "vgui/white" }))
		peekMat = GPU.Mat("dustpeek", "clip_vs30", "peek_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
end
D.ResetMats = function() aftMat, bodyAftMat, peekMat = nil, nil, nil end

local function Impacts(list, ox, oy, oz)
	local ims = {}
	for i, q in ipairs(list) do
		local w = q.wpos
		ims[i] = { px = w.x - ox, py = w.y - oy, pz = w.z - oz, radius = q.radius, vel = vector_origin, volume = 0,
			normal = Vector(0, 0, 1), kind = 4, spin = 14, stretch = q.strength, residue = 0 }
	end
	return ims
end

local function DustRes(a) return math.max(64, math.floor((a.aft and a.aft.res or 256) / 2)) end

local function DustTarget(a)
	local s = a.dust
	if not s.rt then s.rt = GPU.TakeDust(DustRes(a)) end
	return s.rt
end

local cornerW = { 0, 0, 0, 1 }
local function WorldStamp(a, list)
	local S = G.Surfaces
	local P = S.PATCH_UNITS
	local dt = DustTarget(a)
	local o, U, V, n = a.origin, a.U, a.V, a.N
	local ims = Impacts(list, o.x, o.y, o.z)
	GPU.UploadImpacts(ims, 1, #ims)
	GPU.SetC(aftMat, 0, #ims, o.x, o.y, o.z)
	GPU.SetC(aftMat, 1, 1 / GPU.IMPACT_COLS, 1 / 4, G.DryAge(a, G.DryMult(a.surfName)), 0)
	GPU.SetC(aftMat, 2, 0, 0, 0, 0)
	aftMat:SetTexture("$texture1", a.aft.rt)
	render.PushRenderTarget(dt.rt)
	render.SetMaterial(aftMat)
	GPU.Additive(true)
	GPU.FullQuad(dt.res, dt.res, function(ci, u, v)
		local x, y = u * P, v * P
		cornerW[1], cornerW[2], cornerW[3] = o.x + U.x * x + V.x * y, o.y + U.y * x + V.y * y, o.z + U.z * x + V.z * y
		return cornerW
	end, { n.x, n.y, n.z, 0 })
	GPU.Additive(false)
	render.PopRenderTarget()
end

local scratch = {}
local function Scratch(res)
	if not scratch[res] then scratch[res] = GPU.RT("dustscratch" .. res, res, res, GPU.FMT_RGBA8) end
	return scratch[res]
end
local function BodyStamp(d, ent, list)
	local E = G.Entities
	if not IsValid(d.proxy) or not IsValid(ent) then return end
	local origin = ent:GetPos()
	local ims = Impacts(list, origin.x, origin.y, origin.z)
	GPU.UploadImpacts(ims, 1, #ims)
	GPU.SetC(bodyAftMat, 0, #ims, origin.x, origin.y, origin.z)
	GPU.SetC(bodyAftMat, 1, 1 / GPU.IMPACT_COLS, 1 / 4, (d.bakedAt and G.DryAge(d, G.DryMult("skin")) or 0), 1)
	for _, sub in ipairs(d.subs) do
		if sub.aft then
			local sc = Scratch(sub.aft.res)
			GPU.Copy(sc, sub.aft.rt)
			bodyAftMat:SetTexture("$texture1", sc)
			GPU.SetC(bodyAftMat, 2, sub.hand or 0, 0, 0, 0)
			render.PushRenderTarget(sub.aft.rt)
			GPU.Additive(true)
			render.OverrideAlphaWriteEnable(true, true)
			E.DrawProxySub(d, sub.index, bodyAftMat)
			render.OverrideAlphaWriteEnable(false)
			GPU.Additive(false)
			render.PopRenderTarget()
		end
	end
end

function D.GpuPass()
	if not next(D.queue) then return end
	Mats()
	local n = 0
	for key, q in pairs(D.queue) do
		D.queue[key] = nil
		local ok, err = pcall(function()
			if q.a then
				if G.Surfaces.after[q.a.key] == q.a and q.a.aft then WorldStamp(q.a, q.list) D.stats.settled = D.stats.settled + 1 end
			elseif q.d and G.Entities.domains[q.ent] == q.d then
				BodyStamp(q.d, q.ent, q.list)
			end
		end)
		if not ok then G.Diag.lastError = "dust gpu: " .. tostring(err) end
		n = n + 1
		if n >= 16 then break end
	end
end

function D.BakeWorld(p, a)
	local s = p.dust
	if not s or not p.slot then return end
	Mats()
	SetDust(a, s.k, s.soot, s.w)
	local dt = DustTarget(a)
	GPU.SetC(peekMat, 0, 0, 0, 0.5, 0)
	GPU.SetC(peekMat, 1, 0, 0, 0, 0)
	peekMat:SetTexture("$basetexture", p.slot.ac[p.cur])
	render.PushRenderTarget(dt.rt)
	render.SetMaterial(peekMat)
	GPU.Additive(true)
	GPU.FullQuad(dt.res, dt.res, GPU.UVPayload)
	GPU.Additive(false)
	render.PopRenderTarget()
end

function D.Any()
	if not On() then return false end
	return (D.anyT or 0) > CurTime()
end
local function Scan()
	local now = CurTime()
	if (D.scanT or 0) > now then return end
	D.scanT = now + 1
	local any = false
	for _, p in pairs(G.Surfaces.patches) do if p.dust then any = true break end end
	if not any then for _, a in pairs(G.Surfaces.after) do if a.dust then any = true break end end end
	if not any then for _, d in pairs(G.Entities.domains) do if d.dust then any = true break end end end
	D.anyT = any and now + 1.5 or 0
end
hook.Add("Think", "ghmpb_dust", function() if On() then Scan() end end)

function D.IsBlastSound(data)
	if not data then return false end
	local orig = string.lower(data.OriginalSoundName or "")
	local snd = string.lower(data.SoundName or "")
	if string.find(orig, "baseexplosioneffect", 1, true) then return true end
	return string.find(snd, "^weapons/explode%d") ~= nil or string.find(snd, "^%)?weapons/explode%d") ~= nil
end
hook.Add("EntityEmitSound", "ghmpb_dust", function(data)
	if not On() or not D.IsBlastSound(data) then return end
	if (data.SoundLevel or 140) < 90 then return end
	local e = data.Entity
	local pos = data.Pos or (IsValid(e) and not e:IsWorld() and e:GetPos()) or nil
	if not pos or pos:IsZero() or pos:DistToSqr(EyePos()) > 4000 * 4000 then return end
	local p = Vector(pos)
	D.stats.heard = (D.stats.heard or 0) + 1
	timer.Simple(0, function() D.Blast(p, 264, 1.3, nil, "cl") end)
end)

local worldMat, bodyMats = nil, {}
local function WorldMat()
	if not worldMat then
		worldMat = GPU.Mat("dustworld", "worlddust_vs30", "dustworld_ps30", {
			["$basetexture"] = "vgui/white", ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture2"] = GPU.Zero():GetName(), ["$texture3"] = GPU.Zero():GetName(),
			["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4, ["$tcsize3"] = 4,
			["$depthtest"] = 1, ["$cull"] = 0, ["$linearwrite"] = 1 })
	end
	return worldMat
end
local function BodyMat(sub)
	local key = sub.path .. "|" .. (sub.hand or 0)
	local m = bodyMats[key]
	if not m then
		m = GPU.Mat("dustb_" .. util.CRC(key), "modeldust_vs30", "dustbody_ps30", GPU.Merge(GPU.ModelFlags, {
			["$basetexture"] = "vgui/white", ["$texture1"] = "_rt_FullFrameFB", ["$linearread_texture1"] = 1,
			["$texture2"] = sub.albedo and sub.albedo:GetName() or "vgui/white", ["$linearread_texture2"] = 1,
			["$texture3"] = GPU.Zero():GetName(),
			["$cull"] = 1, ["$depthtest"] = 1, ["$linearwrite"] = 1 }))
		bodyMats[key] = m
	end
	return m
end
D.ResetDrawMats = function() worldMat, bodyMats = nil, {} end

local function Blend(on)
	if on then render.OverrideBlend(true, BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
	else render.OverrideBlend(false) end
end

local function Light(mat, info, fade)
	local sd, sc = info.sunDir, info.sunCol
	GPU.SetRowsN(mat, "$viewprojmat", sd.x, sd.y, sd.z, info.sunVis, sc.x, sc.y, sc.z, fade,
		info.dir.x, info.dir.y, info.dir.z, 0, info.col.x, info.col.y, info.col.z, 0)
	G.Light.ApplySH4(mat, info, 0, 0, 0, 0)
end

local function DrawWorld(layers, settled)
	local S = G.Surfaces
	local mat = WorldMat()
	local sw, sh = G.ViewSize()
	local eye, fwd = EyePos(), EyeAngles():Forward()
	local smooth = G.cv.smooth:GetInt()
	local dry = G.DryTime()
	local now = CurTime()
	local fadeStart = G.cv.aftfade:GetFloat() * 60
	local forever = G.cv.forever:GetBool()
	local n = 0
	for _, p in pairs(layers) do
		local s = p.dust
		if s and (p.water or not G.refractionView) and S.InView(p, eye, fwd) then
			local ok = settled and (p.aft and s.rt) or (not settled and p.slot and p.hasBlood and not p.pendingBake)
			if ok then
				local fade = 1
				if settled and not forever then fade = 1 - math.Clamp((now - p.bakedAt - fadeStart) / 30, 0, 1) end
				if fade > 0 then
					local light = G.Light.Get(p, p.probePos, 0.5)
					local res = settled and p.aft.res or p.slot.res
					GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / res, 0)
					GPU.SetC(mat, 1, D.Word(s), S.PairCode(p.tkey or S.TypeKey(p), p.pair or p.btype), p.oxy or 0.75, (settled and 1 or 0) + 2 * smooth)
					if settled then
						GPU.SetC(mat, 2, 0, 0, 2, 0)
						GPU.SetC(mat, 3, p.albedo.x, p.albedo.y, p.albedo.z, G.DryAge(p, G.DryMult(p.surfName)))
						mat:SetTexture("$basetexture", p.aft.rt)
						mat:SetTexture("$texture2", s.rt.rt)
						mat:SetTexture("$texture3", GPU.Zero())
					else
						GPU.SetC(mat, 2, 0, 0, 1, 0)
						GPU.SetC(mat, 3, p.albedo.x, p.albedo.y, p.albedo.z, 0)
						mat:SetTexture("$basetexture", p.slot.st[p.cur])
						mat:SetTexture("$texture2", p.slot.ac[p.cur])
						mat:SetTexture("$texture3", p.slot.aux[p.cur])
					end
					Light(mat, light, fade)
					render.SetMaterial(mat)
					S.DrawPatchMesh(p, settled and 0.035 or 0.07)
					n = n + 1
				end
			end
		end
	end
	return n
end

local function DrawBodies(settled)
	local E = G.Entities
	if G.refractionView then return 0 end
	local sw, sh = G.ViewSize()
	local eye = EyePos()
	local smooth = G.cv.smooth:GetInt()
	local dry = G.DryTime()
	local now = CurTime()
	local noDraw = E.NoDraw()
	local n = 0
	for ent, d in pairs(E.domains) do
		local s = d.dust
		if s and IsValid(d.proxy) and E.Visible(ent, eye) then
			local any = false
			for _, sub in ipairs(d.subs) do
				if (settled and sub.aft) or (not settled and sub.slot and sub.hasBlood) then any = true break end
			end
			if any then
				local light = G.Light.Get(ent, ent:WorldSpaceCenter())
				local cnt = E.MatCount(d, ent)
				for pass = 1, E.Passes(d) do
					local drew = false
					for i = 0, math.max(cnt, 1) - 1 do render.MaterialOverrideByIndex(i, noDraw) end
					for _, sub in ipairs(d.subs) do
						if ((settled and sub.aft) or (not settled and sub.slot and sub.hasBlood)) and E.InPass(sub, pass) then
							local mat = BodyMat(sub)
							local hand = sub.hand or 0
							GPU.SetC(mat, 0, 1 / sw, 1 / sh, 1 / sub.size, 0)
							GPU.SetC(mat, 1, D.Word(s), E.PairCode(d), d.oxy or 0.75, (settled and 1 or 0) + 2 * smooth)
							if settled then
								GPU.SetC(mat, 2, 0, 0, 0, 2)
								GPU.SetC(mat, 3, hand, 0, 0, d.bakedAt and G.DryAge(d, G.DryMult("skin")) or 0)
								mat:SetTexture("$basetexture", sub.aft.rt)
								mat:SetTexture("$texture3", sub.aft.rt)
							else
								GPU.SetC(mat, 2, 0, 0, 1, 0)
								GPU.SetC(mat, 3, hand, 0, 0, 0)
								mat:SetTexture("$basetexture", sub.slot.st[sub.cur])
								mat:SetTexture("$texture3", sub.slot.ac[sub.cur])
							end
							Light(mat, light, 1)
							render.MaterialOverrideByIndex(sub.index, mat)
							drew = true
						end
					end
					if drew then d.proxy:DrawModel() end
					render.MaterialOverrideByIndex()
				end
				n = n + 1
			end
		end
	end
	return n
end

function D.DrawStatic()
	Blend(true)
	local ok, err = pcall(function()
		local n = DrawWorld(G.Surfaces.after, true)
		n = n + DrawBodies(true)
		G.Prof.Count("dust layers drawn (settled)", n)
	end)
	Blend(false)
	if not ok then G.Diag.lastError = "dust draw: " .. tostring(err) end
end
function D.DrawLive()
	Blend(true)
	local ok, err = pcall(function()
		local n = DrawWorld(G.Surfaces.patches, false)
		n = n + DrawBodies(false)
		G.Prof.Count("dust layers drawn (live)", n)
	end)
	Blend(false)
	if not ok then G.Diag.lastError = "dust draw: " .. tostring(err) end
end

function D.Clear()
	D.events, D.queue = {}, {}
	D.anyT = 0
end

function D.Describe()
	local s = D.stats
	return string.format("blast dust: %s, blasts %d (skipped %d, explosions heard here %d), pulses %d, live layer hits %d, settled layer stamps %d, body hits %d, clouds %d, settling now %d",
		On() and "on" or "off", s.blasts, s.skipped, s.heard or 0, s.pulses, s.live, s.settled, s.bodies, s.puffs, #D.events)
end
concommand.Add("ghmpb_dust_test", function(ply, cmd, args)
	if not IsValid(LocalPlayer()) then return end
	local tr = LocalPlayer():GetEyeTrace()
	if not tr.Hit then return end
	print("[GHM PhysBlood] dust:", tostring(D.Blast(tr.HitPos + tr.HitNormal * 4, tonumber(args[1]) or 260, tonumber(args[2]) or 1)), D.Describe())
end, nil, "GHM PhysBlood: settle explosion dust where you look (radius, strength) - no explosion")
