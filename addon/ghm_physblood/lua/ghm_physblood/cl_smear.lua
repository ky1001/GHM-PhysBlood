local G = GHMPB
G.Smear = G.Smear or {}
local SM = G.Smear
local A = G.Anatomy
local U = G.U

local TICK = 0.1
local MAX_BODIES = 16
local MAX_PROBES = 127
local PROBE_ROW = 127
local PROBE_ROW_TYPE = 126

local PART_R = { [A.HEAD] = 4.0, [A.NECK] = 3.0, [A.CHEST] = 7.0, [A.ABDOMEN] = 6.0, [A.PELVIS] = 6.0,
	[A.UPPERARM] = 2.6, [A.FOREARM] = 2.2, [A.HAND] = 2.0, [A.THIGH] = 3.6, [A.CALF] = 2.8, [A.FOOT] = 2.4 }
local TRUNK = { [A.HEAD] = true, [A.NECK] = true, [A.CHEST] = true, [A.ABDOMEN] = true, [A.PELVIS] = true }

SM.state = SM.state or {}
SM.parts = SM.parts or {}
SM.probeQ = SM.probeQ or {}
SM.stats = SM.stats or { smears = 0, pushes = 0, pickups = 0, probes = 0 }

local function KeyOf(bi) return TRUNK[bi.region] and bi.region or (bi.region .. tostring(bi.side or 0)) end

function SM.WetKey(ent, bone, pos)
	local sk = A.GetSkeleton(ent)
	if not sk then return nil end
	if not bone and pos then bone = U.NearestBone(ent, pos) end
	local bi = bone and sk.bones[bone]
	if not bi or not PART_R[bi.region] then return A.CHEST end
	return KeyOf(bi)
end

function SM.AddWet(d, ent, bone, pos, volume, alt)
	if not volume or volume <= 0 then return end
	local key = SM.WetKey(ent, bone, pos)
	if not key then return end
	d.wet = d.wet or {}
	d.wetF = d.wetF or {}
	local w = d.wet[key] or 0
	d.wetF[key] = ((d.wetF[key] or 0) * w + (alt and volume or 0)) / (w + volume)
	d.wet[key] = math.min(w + volume, 80000)
end

function SM.PartType(d, key, fallback)
	if not d then return fallback or 0 end
	local f = key and d.wetF and d.wetF[key] or 0
	if d.btypeB and f > 0.5 then return d.btypeB end
	return d.btype or fallback or 0
end
function SM.TypeAt(d, ent, pos)
	if not d or not d.btypeB or not d.wetF then return d and d.btype or 0 end
	return SM.PartType(d, SM.WetKey(ent, nil, pos))
end

local function Parts(ent)
	local mdl = ent:GetModel() or ""
	local list = SM.parts[mdl]
	if list then return list end
	list = {}
	local sk = A.GetSkeleton(ent)
	if sk then
		local seen = {}
		for b = 0, sk.count - 1 do
			local bi = sk.bones[b]
			if bi and PART_R[bi.region] and bi.region ~= A.HAND then
				local key = KeyOf(bi)
				if not seen[key] then
					seen[key] = true
					list[#list + 1] = { bone = b, key = key, r = PART_R[bi.region] }
				end
			end
		end
	end
	if #list > 0 then SM.parts[mdl] = list end
	return list
end

local probeMat
function SM.RequestProbe(ps, cp, n)
	if #SM.probeQ >= MAX_PROBES then return end
	local S = G.Surfaces
	local P = S.PATCH_UNITS
	local p, key = S.GetPatch(cp, n, false)
	if p and p.slot and not p.pendingBake and p.hasBlood then
		local rel = cp - p.origin
		ps.oxy, ps.btype, ps.live = p.oxy, p.btype, true
		ps.frost = p.el and p.el.frost or 0
		SM.probeQ[#SM.probeQ + 1] = { p = p, u = rel:Dot(p.U) / P, v = rel:Dot(p.V) / P, ps = ps, plane = S.TypeKey(p) }
		return
	end
	local a = (p and S.after[p.key]) or (key and S.after[key])
	if a and a.aft then
		local dry = math.Clamp(G.DryAge(a, G.DryMult(a.surfName)), 0, 1)
		if dry < 0.95 then
			local rel = cp - a.origin
			ps.oxy, ps.btype, ps.live = a.oxy, a.btype, false
			ps.frost = a.el and a.el.frost or 0
			SM.probeQ[#SM.probeQ + 1] = { a = a, u = rel:Dot(a.U) / P, v = rel:Dot(a.V) / P, ps = ps, dry = dry, plane = S.TypeKey(a) }
			return
		end
	end
	ps.h, ps.s, ps.frost, ps.hT = 0, 0, 0, CurTime()
end

function SM.DrawProbes()
	local q = SM.probeQ
	if #q == 0 then return nil end
	SM.probeQ = {}
	local GPU = G.GPU
	if not probeMat then
		probeMat = GPU.Mat("probe", "clip_vs30", "peek_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
	end
	GPU.SetC(probeMat, 1, 0, 0, 0, 0)
	local groups, order = {}, {}
	for k, pr in ipairs(q) do
		pr.x = k - 1
		local src = pr.p or pr.a
		local g = groups[src]
		if not g then g = {} groups[src] = g order[#order + 1] = src end
		g[#g + 1] = { pr.x, PROBE_ROW, pr.x + 1, PROBE_ROW + 1, { pr.u, pr.v, 0, 0 } }
		if pr.p then
			g.typeQ = g.typeQ or {}
			g.typeQ[#g.typeQ + 1] = { pr.x, PROBE_ROW_TYPE, pr.x + 1, PROBE_ROW_TYPE + 1, { pr.u, pr.v, 0, 0 } }
		end
	end
	for _, src in ipairs(order) do
		local tex
		if src.slot then
			tex = src.slot.st[src.cur]
			GPU.SetC(probeMat, 0, 0.25, 0.25, 0.25, 0.25)
		elseif src.aft then
			tex = src.aft.rt
			GPU.SetC(probeMat, 0, 1, 1, 1, 1)
		end
		if tex then
			probeMat:SetTexture("$basetexture", tex)
			render.SetMaterial(probeMat)
			GPU.Quads(GPU.READBACK, GPU.READBACK, groups[src])
		end
		local tq = groups[src].typeQ
		if tq and src.slot and src.slot.aux then
			GPU.SetC(probeMat, 0, 0, 0, 0, 0.25)
			probeMat:SetTexture("$basetexture", src.slot.aux[src.cur])
			render.SetMaterial(probeMat)
			GPU.Quads(GPU.READBACK, GPU.READBACK, tq)
		end
	end
	return q
end

function SM.ReadProbes(q)
	if not q then return end
	local now = CurTime()
	local types = G.Surfaces.planeTypes
	for _, pr in ipairs(q) do
		local r, g, b = render.ReadPixel(pr.x, PROBE_ROW)
		r, g, b = (r or 0) / 255, (g or 0) / 255, (b or 0) / 255
		local frac
		if pr.a then
			pr.ps.h = 4 * r * r * (1 - (pr.dry or 0))
			pr.ps.s = 4 * g * g + 4 * r * r * (pr.dry or 0)
			frac = b
		else
			pr.ps.h = r * 4
			pr.ps.s = g * 4
			local _, _, _, a2 = render.ReadPixel(pr.x, PROBE_ROW_TYPE)
			local all = r * 4 + g * 4
			frac = all > 0.01 and ((a2 or 0) / 255 * 4) / all or 0
		end
		local pt = pr.plane and types[pr.plane]
		if pt then pr.ps.btype = (pt.b ~= nil and frac > 0.5) and pt.b or pt.a end
		pr.ps.hT = now
	end
	SM.stats.probes = SM.stats.probes + #q
end

local filterEnt
local traceData = { mask = MASK_SOLID, filter = function(e) return not IsValid(e) or (e ~= filterEnt and not (e:IsNPC() or e:IsPlayer() or e:IsRagdoll())) end }

-- 1.26.0: a body that has just fallen keeps twitching and sliding a little while the pool forms under it. Real drag
-- marks need a real drag: below DRAG_MIN u/s during the settle time nothing is smeared or wiped, so the pool that
-- grows under a fresh corpse is not covered by a dark smeared print of the body
local SETTLE_T, DRAG_MIN = 3.0, 45
SM.SETTLE_T = SETTLE_T
local function Settling(st, speed)
	return st and st.born and CurTime() - st.born < SETTLE_T and speed < DRAG_MIN
end
SM.Settling = Settling

local function Move(ent, d, ps, part, p, cp, n, seg, L, R, tr, speed, st)
	local S = G.Surfaces
	local amt = G.cv.smearamt:GetFloat()
	local oxy, btype = d and d.oxy or 0.7, SM.PartType(d, part.key)
	local wet = d and d.wet and d.wet[part.key] or 0
	local fast = math.Clamp((speed - 400) / 400, 0, 1)
	if Settling(st, speed) then return end
	if amt > 0 and wet > 15 and speed > 6 and fast < 1 then
		local film = (L * 19.05) * (2 * R * 0.6 * 19.05) * 0.10
		local vol = math.min(wet * 0.2, film * amt) * (1 - fast)
		if vol > 4 then
			S.Impact(cp, n, seg, R * 0.75, vol, 3, 0, 1, 0.45, tr, oxy, btype)
			d.wet[part.key] = wet - vol
			SM.stats.smears = SM.stats.smears + 1
		end
	end
	local freshProbe = ps.h and CurTime() - (ps.hT or 0) < 1.0
	local h = freshProbe and ps.h or 0
	if h > 0.06 and speed > 15 then
		local wipe = ps.live and 0.35 or 0.24
		if ps.live then
			S.Impact(cp, n, seg, R * 0.85, h, 4, 0, speed, wipe, tr, oxy, btype)
			SM.stats.pushes = SM.stats.pushes + 1
		end
		if G.cv.pickup:GetBool() and (ps.frost or 0) < 0.7 then
			local area = (L * 19.05) * (2 * R * 0.85 * 19.05)
			local pick = math.min(area * math.max(h - 0.04, 0) * wipe, 1500)
			if pick > 8 then
				G.Entities.Impact(ent, p - n * (R * 0.6), -n, vector_origin, R * 0.9, pick, 1, 0, 1, 0, part.bone, { btype = ps.btype, oxy = ps.oxy })
				local dom = G.Entities.domains and G.Entities.domains[ent]
				if dom then SM.AddWet(dom, ent, part.bone, p, pick * 0.55, dom.btype and ps.btype and ps.btype ~= dom.btype) end
				SM.stats.pickups = SM.stats.pickups + 1
			end
		end
	end
end

local function Part(ent, d, st, part, now, dt, scale)
	if G.Contact and G.Contact.Collapsed(ent, part.bone) then return end
	local m = ent:GetBoneMatrix(part.bone)
	if not m then return end
	local p = m:GetTranslation()
	local ps = st.parts[part.key]
	if not ps then ps = {} st.parts[part.key] = ps end
	local R = part.r * scale
	local v = ps.lastP and (p - ps.lastP) / math.max(dt, 0.02) or Vector(0, 0, 0)
	ps.lastP = p
	filterEnt = ent
	if v.z < -100 and G.Contact then
		traceData.start = p
		traceData.endpos = p + Vector(v.x * 0.1, v.y * 0.1, -70)
		local ft = util.TraceLine(traceData)
		ps.fall = ps.fall or {}
		if ft.Hit and not ft.StartSolid and G.Contact.NearBlood(ft.HitPos) then G.Contact.Probe(ps.fall, ft.HitPos, ft.HitNormal, 0.08) end
	end
	traceData.start = p
	traceData.endpos = p - Vector(0, 0, R + 2.5)
	local tr = util.TraceLine(traceData)
	local slam = false
	if not tr.Hit or tr.StartSolid then
		local sp = v:Length()
		if sp > 80 then
			traceData.endpos = p + v * ((R + 3) / sp)
			tr = util.TraceLine(traceData)
			slam = true
		end
	end
	if not tr.Hit or tr.StartSolid or tr.HitSky then ps.last = nil return end
	local cp, n = tr.HitPos, tr.HitNormal
	local vt = v - n * v:Dot(n)
	if ps.last and ps.lastN and ps.lastN:Dot(n) > 0.9 and cp:DistToSqr(ps.last) < 48 * 48 then
		local seg = ps.last - cp
		seg = seg - n * seg:Dot(n)
		local L = seg:Length()
		if L >= 1.0 then
			Move(ent, d, ps, part, p, cp, n, seg, L, R, tr, vt:Length(), st)
			ps.last, ps.lastN = cp, n
		end
	else
		local wet = d and d.wet and d.wet[part.key] or 0
		local into = -v:Dot(n)
		local hFall = (into > 110 and ps.fall and G.Contact) and G.Contact.Depth(ps.fall, 1.0, cp, R * 3 + 40) or nil
		if hFall and hFall > 0.08 then
			local out = G.Contact.Splash(cp, n, hFall, into, R * 1.3, v, ent, ps.fall.oxy or (d and d.oxy), ps.fall.btype or (d and d.btype), tr)
			if out > 0 then
				G.Entities.Impact(ent, p - n * (R * 0.6), -n, vector_origin, R, math.min(out * 0.15, 800), 1, 0, 1, 0.2, part.bone, { btype = ps.fall.btype })
			end
		elseif (slam or into > 110) and wet > 40 and G.cv.smearamt:GetFloat() > 0 then
			local seg = -vt * 0.03
			local vol = math.min(wet * 0.2, 300 * G.cv.smearamt:GetFloat())
			local settling = st.born and now - st.born < SETTLE_T
			-- (a fresh corpse hitting the floor presses its blood out into the pool that is forming: no smear print)
			G.Surfaces.Impact(cp, n, settling and vector_origin or seg, settling and math.min(R * 0.42, 1.35) or R * 0.8, vol, settling and 1 or 3, 0, 1, settling and 0 or 0.4, tr,
				d.oxy or 0.7, SM.PartType(d, part.key))
			d.wet[part.key] = wet - vol
			SM.stats.smears = SM.stats.smears + 1
		end
		ps.last, ps.lastN = cp, n
	end
	if now - (ps.probeT or 0) > 0.25 then
		ps.probeT = now
		SM.RequestProbe(ps, cp, n)
	end
end

local function Body(ent, now)
	local st = SM.state[ent]
	if not st then st = { parts = {}, born = now } SM.state[ent] = st end
	local dt = math.min(now - (st.t or now), 1)
	st.t = now
	local d = G.Entities.domains[ent]
	if d and d.wet and dt > 0 then
		local tau = math.max(20, math.min(G.CoagTime() * 0.8, G.DryTime() * 0.5))
		local k = math.exp(-dt / tau)
		for key, v in pairs(d.wet) do
			v = v * k
			d.wet[key] = v > 1 and v or nil
		end
	end
	local c = ent:WorldSpaceCenter()
	local moved = st.c and c:DistToSqr(st.c) or 1e9
	st.c = c
	if moved < 0.3 and now < (st.idleNext or 0) then return end
	st.idleNext = now + 1.0
	local scale = ent:GetModelScale() or 1
	for _, part in ipairs(Parts(ent)) do Part(ent, d, st, part, now, dt, scale) end

	-- (1.26.11) Actor-to-actor contact transfer: a blood-soaked body bumping or dragged against another NPC, player or ragdoll
	-- transfers a conserved smear onto the touching body
	if d and d.wet and moved > 1.2 and now >= (st.xferNext or 0) and G.Entities and G.Entities.Impact then
		st.xferNext = now + 0.28
		local bestKey, bestWet = nil, 160
		for k, w in pairs(d.wet) do
			if w > bestWet then bestKey, bestWet = k, w end
		end
		if bestKey then
			local lp = LocalPlayer()
			for _, other in ipairs(ents.FindInSphere(c, 30 * scale)) do
				if other ~= ent and IsValid(other) and (other:IsNPC() or other:IsPlayer() or other:IsRagdoll() or (other.IsNextBot and other:IsNextBot()))
					and not (other == lp and not lp:ShouldDrawLocalPlayer()) then
					local oc = other:WorldSpaceCenter()
					local dir = oc - c
					local dist = dir:Length()
					if dist > 0.5 and dist < 28 * scale then
						dir:Mul(1 / dist)
						local hitP = c + dir * (dist * 0.55)
						local give = math.min(bestWet * 0.16, 220)
						local bt = SM.PartType(d, bestKey)
						local boneO = U and U.NearestBone and U.NearestBone(other, hitP) or nil
						if G.Entities.Impact(other, hitP, -dir, dir * 45, 0.52, give, 1, 0, 1.35, 0.25, boneO, { btype = bt, oxy = d.oxy or 0.65 }) then
							d.wet[bestKey] = math.max(bestWet - give, 0)
							SM.stats.transfers = (SM.stats.transfers or 0) + 1
							break
						end
					end
				end
			end
		end
	end
end

function SM.Update()
	if not G.cv.enable:GetBool() or not G.cv.smear:GetBool() then return end
	local now = CurTime()
	if now < (SM.next or 0) then return end
	SM.next = now + TICK * (G.Gov and G.Gov.TickMul() or 1)
	local eye = EyePos()
	local cands, seen = {}, {}
	local function add(e)
		if IsValid(e) and not seen[e] and e:IsRagdoll() and not e:IsDormant() then
			seen[e] = true
			local dd = e:GetPos():DistToSqr(eye)
			if dd < 3000 * 3000 then cands[#cands + 1] = { e, dd } end
		end
	end
	for e in pairs(G.Entities.domains) do add(e) end
	for _, e in ipairs(U.corpses) do add(e) end
	for _, e in ipairs(ents.FindByClass("prop_ragdoll")) do add(e) end
	if G.Flesh and G.Flesh.gibs then for e in pairs(G.Flesh.gibs) do add(e) end end
	table.sort(cands, function(a, b) return a[2] < b[2] end)
	local n = math.min(#cands, MAX_BODIES)
	local function run(k)
		local ok, err = pcall(Body, cands[k][1], now)
		if not ok then ErrorNoHalt("[GHMPB] smear: " .. tostring(err) .. "\n") end
	end
	for k = 1, math.min(n, 4) do run(k) end
	local rest = n - 4
	if rest > 0 then
		local t0 = SysTime()
		local start = (SM.rr or 0) % rest
		SM.rr = start
		for i = 0, rest - 1 do
			run(4 + (start + i) % rest + 1)
			SM.rr = start + i + 1
			if SysTime() - t0 > 0.001 then break end
		end
	end
	for e in pairs(SM.state) do if not IsValid(e) then SM.state[e] = nil end end
end

function SM.Clear()
	SM.state = {}
	SM.probeQ = {}
end
