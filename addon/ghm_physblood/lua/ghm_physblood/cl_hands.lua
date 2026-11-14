local G = GHMPB
G.Hands = G.Hands or {}
local H = G.Hands
local A = G.Anatomy
local C = G.Contact
local U = G.U

local TICK = 0.06
local RANGE = 2500
local REACH = 1.9
local PALM_GAP = 3.2
local PRINT_CD = 0.35
local WET_MIN = 40
local up0 = Vector(0, 0, 1)
local SAMPLES = { { 0, 1.9 }, { 0.5, 2.1 }, { 0.85, 1.7 } }

H.state = H.state or {}
H.rigs = H.rigs or {}
H.stats = H.stats or { hands = 0, prints = 0, drags = 0, pickups = 0, pushes = 0, blots = 0, setups = 0 }

local function Amount() return G.cv.handamt:GetFloat() end

local function Match(n, pats) for _, p in ipairs(pats) do if string.find(n, p) then return true end end return false end
local P_HAND = { "hand$", "hand_?[lr]$", "_hand_", "wrist" }
local P_INDEX = { "finger1$", "index_?0?1$", "index1$", "index_?0?1_[lr]$", "finger_?1_?0?1" }
local P_MIDDLE = { "finger2$", "middle_?0?1$", "middle1$", "middle_?0?1_[lr]$", "finger_?2_?0?1" }
local P_PINKY = { "finger4$", "pinky_?0?1$", "pinky1$", "pinky_?0?1_[lr]$", "little_?0?1", "finger_?4_?0?1" }
local P_RING = { "finger3$", "ring_?0?1$", "ring1$", "ring_?0?1_[lr]$", "finger_?3_?0?1" }

local function Rig(ent)
	local mdl = ent:GetModel()
	if not mdl then return nil end
	local rig = H.rigs[mdl]
	if rig ~= nil then return rig or nil end
	local sk = A.GetSkeleton(ent)
	rig = {}
	if sk then
		for _, side in ipairs({ -1, 1 }) do
			local h = { side = side }
			for b, bi in pairs(sk.bones) do
				if bi.side == side and (bi.region == A.HAND or bi.region == A.FOREARM) then
					local n = A.NormaliseBoneName(bi.name)
					if bi.region == A.HAND then
						if Match(n, P_INDEX) then h.index = h.index or b
						elseif Match(n, P_MIDDLE) then h.middle = h.middle or b
						elseif Match(n, P_PINKY) then h.pinky = h.pinky or b
						elseif Match(n, P_RING) then h.ring = h.ring or b
						elseif not string.find(n, "finger") and not string.find(n, "thumb") and Match(n, P_HAND) then
							h.hand = (h.hand and h.hand < b) and h.hand or b
						end
					end
				end
			end
			if not h.hand then
				for b = 0, sk.count - 1 do
					local bi = sk.bones[b]
					if bi and bi.side == side and bi.region == A.HAND then h.hand = b break end
				end
			end
			if h.hand then rig[#rig + 1] = h end
		end
	end
	if #rig > 0 then H.rigs[mdl] = rig
	elseif sk and sk.count > 0 and next(sk.bones) ~= nil then H.rigs[mdl] = false end
	return #rig > 0 and rig or nil
end

local function Frame(ent, h, scale)
	local m = ent:GetBoneMatrix(h.hand)
	if not m then return nil end
	local W = m:GetTranslation()
	local far = h.pinky or h.ring or h.middle
	if h.middle and h.index and far then
		local mm, mi, mp = ent:GetBoneMatrix(h.middle), ent:GetBoneMatrix(h.index), ent:GetBoneMatrix(far)
		if mm and mi and mp then
			local M = mm:GetTranslation()
			local fdir = M - W
			local kn = fdir:Length()
			if kn > 0.3 then
				fdir:Mul(1 / kn)
				local across = mi:GetTranslation() - mp:GetTranslation()
				across = across - fdir * across:Dot(fdir)
				if across:LengthSqr() > 1e-4 then
					across:Normalize()
					local palm = fdir:Cross(across) * (h.side < 0 and 1 or -1)
					return W, fdir, palm, math.Clamp(kn * 1.95, 3, 16 * scale)
				end
			end
		end
	end
	return W, m:GetForward(), -m:GetRight() * (h.side < 0 and -1 or 1), 7.5 * scale
end

local filterEnt
local td = { mask = MASK_SOLID, filter = function(e)
	if not IsValid(e) or e:IsWorld() then return true end
	if e == filterEnt or e:IsNPC() or e:IsPlayer() or e:IsRagdoll() then return false end
	return G.Surfaces.IsGround(e)
end }

local function Hand(ent, st, h, d, now, scale, wetKeys)
	local hs = st.hands[h.side]
	if not hs then hs = { probe = {} } st.hands[h.side] = hs end
	if C.Collapsed(ent, h.hand) then hs.contact = false return end
	local key, keyF = wetKeys[1], wetKeys[2]
	local wetH = d and d.wet and d.wet[key] or 0
	local wetF = d and d.wet and keyF and d.wet[keyF] or 0
	local wet = wetH + wetF * 0.35
	local W, fdir, palm, len = Frame(ent, h, scale)
	if not W then return end
	if wet < WET_MIN and not C.NearBlood(W) then hs.contact = false return end
	H.stats.hands = H.stats.hands + 1
	local R = len * 0.5
	local center = W + fdir * R
	filterEnt = ent
	td.start = center - palm * 1.5
	td.endpos = center + palm * (REACH + 2.5)
	local tr = util.TraceLine(td)
	local gap = tr.Hit and (tr.HitPos - center):Dot(palm) or 99
	local touching = tr.Hit and not tr.StartSolid and not tr.HitSky and -tr.HitNormal:Dot(palm) > 0.55 and gap < PALM_GAP * scale
	local edge = false
	local cpSide
	local low = 99
	if not touching then
		local btr
		for _, smp in ipairs(SAMPLES) do
			local p = W + fdir * (len * smp[1])
			td.start = p + up0
			td.endpos = p - Vector(0, 0, smp[2] * scale + REACH)
			local t2 = util.TraceLine(td)
			if t2.Hit and not t2.StartSolid and not t2.HitSky and t2.HitNormal.z > 0.7 then
				local m = (p - t2.HitPos):Dot(t2.HitNormal) - smp[2] * scale
				if m < low then low, btr = m, t2 end
			end
		end
		if btr and low < 0.6 then
			tr, touching, edge = btr, true, -btr.HitNormal:Dot(palm) <= 0.55
			cpSide = center - btr.HitNormal * (center - btr.HitPos):Dot(btr.HitNormal)
		end
	end
	hs.dg = hs.dg or {}
	hs.dg.gap, hs.dg.facing, hs.dg.mode = gap, tr.Hit and -tr.HitNormal:Dot(palm) or 0, touching and (edge and "side" or "palm") or "none"
	hs.dg.height = low
	if not touching then
		hs.contact = false
		hs.last = nil
		return
	end
	local cp, n = cpSide or tr.HitPos, tr.HitNormal
	local S = G.Surfaces
	local amt = Amount()
	local oxy = d and d.oxy or 0.6
	local btype = d and G.Smear.PartType(d, (wetH >= wetF * 0.35 or not keyF) and key or keyF) or (G.BloodTypeOf(ent) or 0)
	if n.z > 0.5 and C.NearBlood(cp) then C.Probe(hs.probe, cp, n, hs.contact and 0.15 or 0) end
	local hPool = C.Depth(hs.probe, 0.8, cp, R * 2 + 6) or 0
	local fw = fdir - n * fdir:Dot(n)
	if fw:LengthSqr() < 1e-4 then fw = n:Cross(Vector(0.31, 0.57, 0.76)) end
	fw:Normalize()
	local function Take(vol)
		if not (d and d.wet) then return end
		local fromH = math.min(vol, wetH)
		d.wet[key] = math.max(wetH - fromH, 0)
		if keyF and vol > fromH then d.wet[keyF] = math.max(wetF - (vol - fromH) / 0.35, 0) end
	end
	if not hs.contact then
		hs.contact = true
		hs.last = cp
		if hPool > 0.05 then
			local pick = math.min(math.pi * (R * 19.05) ^ 2 * 0.5 * math.min(hPool, 1.5) * 0.3, 900)
			G.Entities.Impact(ent, edge and (cp + n * 0.8) or (center + palm * 0.6), edge and -n or palm, vector_origin, R * 0.6, pick, 1, 0, 1, 0.2, h.hand, { btype = hs.probe.btype })
			H.stats.pickups = H.stats.pickups + 1
			return
		end
		if edge then
			if wet >= WET_MIN and amt > 0 and now - (hs.printT or 0) > PRINT_CD then
				hs.printT = now
				local vol = math.min(wet * 0.12, 180) * amt
				if vol > 2 and S.Impact(cp, n, fw * R * 0.4, R * 0.35, vol, 3, 0, 1, 0.4, tr, oxy, btype) then
					Take(vol / math.max(amt, 0.01))
					H.stats.blots = H.stats.blots + 1
				end
			end
			return
		end
		if wet >= WET_MIN and amt > 0 and now - (hs.printT or 0) > PRINT_CD then
			hs.printT = now
			local fresh = math.Clamp(wet / 700, 0, 1)
			local area = (2 * R * 19.05) * (0.9 * R * 19.05) * 0.55
			local vol = math.min(wet * 0.35, (0.02 + 0.13 * fresh) * area) * amt
			if vol > 2 and S.Impact(cp + fw * 0, n, fw, R, vol, 5, h.side > 0 and 2 or -2, fresh, 0.3, tr, oxy, btype) then
				Take(vol / math.max(amt, 0.01))
				H.stats.prints = H.stats.prints + 1
			end
		end
		return
	end
	local seg = hs.last and (hs.last - cp) or vector_origin
	seg = seg - n * seg:Dot(n)
	local L = seg:Length()
	if L < 1.0 then return end
	if L > 60 then hs.last = cp return end
	hs.last = cp
	local halfW = edge and R * 0.3 or R * 0.5
	if wet > 15 and amt > 0 then
		local film = (L * 19.05) * (2 * halfW * 19.05) * 0.08
		local vol = math.min(wet * 0.18, film * amt)
		if vol > 1.5 then
			S.Impact(cp, n, seg, halfW, vol, 3, edge and 0 or 5, 1, 0.45, tr, oxy, btype)
			Take(vol / math.max(amt, 0.01))
			H.stats.drags = H.stats.drags + 1
		end
	end
	if hPool > 0.06 then
		S.Impact(cp, n, seg, halfW, hPool, 4, 0, math.max(L / TICK, 20), 0.35, tr, oxy, btype)
		H.stats.pushes = H.stats.pushes + 1
		local pick = math.min(L * 19.05 * 2 * halfW * 19.05 * math.max(hPool - 0.04, 0) * 0.35, 600)
		if pick > 5 then
			G.Entities.Impact(ent, edge and (cp + n * 0.8) or (center + palm * 0.6), edge and -n or palm, vector_origin, R * 0.6, pick, 1, 0, 1, 0.2, h.hand, { btype = hs.probe.btype })
			H.stats.pickups = H.stats.pickups + 1
		end
	end
end

local function Keys(ent, h)
	h.keys = h.keys or {}
	local keys = h.keys[ent:GetModel()]
	if keys then return keys end
	local fb
	local sk = A.GetSkeleton(ent)
	if sk then
		for b, bi in pairs(sk.bones) do if bi.side == h.side and bi.region == A.FOREARM then fb = b break end end
	end
	keys = { G.Smear.WetKey(ent, h.hand), fb and G.Smear.WetKey(ent, fb) or nil }
	h.keys[ent:GetModel()] = keys
	return keys
end

local function Body(ent, now)
	local rig = Rig(ent)
	if not rig then return end
	local st = H.state[ent]
	if not st then st = { hands = {} } H.state[ent] = st end
	local dt = math.Clamp(now - (st.t or now), 0, 1)
	st.t = now
	local d = G.Entities.domains[ent]
	local scale = ent:GetModelScale() or 1
	if d and d.wet and not ent:IsRagdoll() and dt > 0 then
		local tau = math.max(20, math.min(G.CoagTime() * 0.8, G.DryTime() * 0.5))
		local k = math.exp(-dt / tau)
		for _, h in ipairs(rig) do
			for _, key in ipairs(Keys(ent, h)) do if d.wet[key] then d.wet[key] = d.wet[key] * k end end
		end
	end
	local need = C.NearBlood(ent:GetPos(), 2)
	if not need and d and d.wet then
		for _, h in ipairs(rig) do
			local ks = Keys(ent, h)
			if (d.wet[ks[1]] or 0) + (ks[2] and d.wet[ks[2]] or 0) * 0.35 >= WET_MIN then need = true break end
		end
	end
	if not need then
		for _, h in ipairs(rig) do local hs = st.hands[h.side] if hs then hs.contact = false hs.last = nil end end
		return
	end
	local pos = ent:GetPos()
	local m0 = ent:GetBoneMatrix(0)
	local p0 = m0 and m0:GetTranslation()
	local stale = p0 == nil or (st.pos ~= nil and st.p0 ~= nil and pos:DistToSqr(st.pos) > 0.25 and p0:DistToSqr(st.p0) < 1e-4)
	if stale then
		if ent.ghmflGore ~= nil then
			st.pos = pos
			for _, h in ipairs(rig) do local hs = st.hands[h.side] if hs then hs.contact = false hs.last = nil end end
			return
		end
		ent:SetupBones()
		m0 = ent:GetBoneMatrix(0)
		p0 = m0 and m0:GetTranslation()
		H.stats.setups = H.stats.setups + 1
	end
	st.pos, st.p0 = pos, p0
	for _, h in ipairs(rig) do
		local keys = Keys(ent, h)
		Hand(ent, st, h, d, now, scale, keys)
	end
end

local list, listT = {}, 0
local function Bodies(now)
	if now - listT < 1 then return list end
	listT = now
	local eye = EyePos()
	local seen, out = {}, {}
	local function add(e)
		if not IsValid(e) or seen[e] or e:IsDormant() then return end
		if e == LocalPlayer() and not e:ShouldDrawLocalPlayer() then return end
		if e:IsPlayer() and not e:Alive() then return end
		seen[e] = true
		local dd = e:GetPos():DistToSqr(eye)
		if dd < RANGE * RANGE then out[#out + 1] = { e, dd } end
	end
	if G.Foot and G.Foot.Walkers then for _, e in ipairs(G.Foot.Walkers(now)) do add(e) end end
	for _, pl in ipairs(player.GetAll()) do add(pl) end
	for e in pairs(G.Entities.domains) do if IsValid(e) and (e:IsRagdoll() or e:IsNPC() or e:IsPlayer()) then add(e) end end
	for _, e in ipairs(U.corpses or {}) do add(e) end
	for _, e in ipairs(ents.FindByClass("prop_ragdoll")) do add(e) end
	if G.Flesh and G.Flesh.gibs then for e in pairs(G.Flesh.gibs) do add(e) end end
	table.sort(out, function(a, b) return a[2] < b[2] end)
	list = {}
	for k = 1, math.min(#out, 32) do list[k] = out[k][1] end
	return list
end

function H.Update()
	if not G.cv.enable:GetBool() or not G.cv.hands:GetBool() then return end
	local now = CurTime()
	if now < (H.next or 0) then return end
	H.next = now + TICK * (G.Gov and G.Gov.TickMul() or 1)
	C.Grid(now)
	local list = Bodies(now)
	local function run(e)
		if IsValid(e) then
			local ok, err = pcall(Body, e, now)
			if not ok then ErrorNoHalt("[GHMPB] hands: " .. tostring(err) .. "\n") end
		end
	end
	for k = 1, math.min(#list, 4) do run(list[k]) end
	local rest = #list - 4
	if rest > 0 then
		local t0 = SysTime()
		local start = (H.rr or 0) % rest
		H.rr = start
		for i = 0, rest - 1 do
			run(list[4 + (start + i) % rest + 1])
			H.rr = start + i + 1
			if SysTime() - t0 > 0.001 then break end
		end
	end
	for e in pairs(H.state) do if not IsValid(e) then H.state[e] = nil end end
end

function H.Wet(ent)
	local d = G.Entities.domains[ent]
	local rig = Rig(ent)
	if not d or not d.wet or not rig then return 0, 0 end
	local out = {}
	for _, h in ipairs(rig) do out[h.side] = d.wet[G.Smear.WetKey(ent, h.hand)] or 0 end
	return out[-1] or 0, out[1] or 0
end

function H.Clear()
	H.state = {}
	listT = 0
end
