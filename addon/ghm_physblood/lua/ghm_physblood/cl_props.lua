local G = GHMPB
G.Props = G.Props or {}
local PR = G.Props
local C = G.Contact
local U = G.U

local TICK = 0.08
local RANGE = 2000
local MAX_PROPS = 24
local REACH = 2.5

PR.state = PR.state or {}
PR.stats = PR.stats or { props = 0, smears = 0, pushes = 0, pickups = 0, soaks = 0, splashes = 0, prints = 0 }

local function Amount() return G.cv.propamt:GetFloat() end

function PR.IsProp(e)
	if not IsValid(e) or e:IsDormant() or e:IsNPC() or e:IsPlayer() or e:IsRagdoll() or e.ghmpbProxy then return false end
	if e:IsVehicle() or e.IsGlideVehicle or e.LVS or e.IsSimfphyscar then return false end
	if e:IsWeapon() and IsValid(e:GetOwner()) then return false end
	if e:GetMoveType() ~= MOVETYPE_VPHYSICS then return false end
	local c = e:GetClass()
	if string.find(c, "wheel", 1, true) then return false end
	local mdl = e:GetModel()
	if not mdl or mdl == "" or string.sub(mdl, 1, 1) == "*" then return false end
	return true
end

local absorbCache = {}
local function Absorbency(e)
	local mdl = e:GetModel()
	local a = absorbCache[mdl]
	if a then return a end
	local info = util.GetModelInfo and util.GetModelInfo(mdl)
	local kind = info and G.SurfaceKindOfProp(info.SurfacePropName) or "sealed"
	local sf = G.Surface[kind] or G.Surface.sealed
	a = math.Clamp(sf.kabs * 1.8 + (sf.fabric or 0) * 0.5, 0, 1)
	absorbCache[mdl] = a
	return a
end

local shareCache = {}
local function UVShare(e)
	local mdl = e:GetModel()
	local s = shareCache[mdl]
	if s then return s end
	local mi = G.Entities.ModelInfo(e)
	s = math.Clamp(mi and mi.ok and mi.subs[1] and mi.subs[1].uvShare or 1, 1, 8)
	shareCache[mdl] = s
	return s
end
PR.UVShare = UVShare

local function Mix(st, btype, vol)
	if btype == nil or not vol or vol <= 0 then return end
	local w = math.max(st.wet or 0, 0)
	local c = st.mix or {}
	st.mix = c
	local tot = w + vol
	for t, f in pairs(c) do c[t] = f * w / tot end
	c[btype] = (c[btype] or 0) + vol / tot
	local best, bf = nil, -1
	for t, f in pairs(c) do if f > bf then best, bf = t, f end end
	st.utype = best
end

local function OnUnderside(e, st, pos, n, vel, R, vol, residue, btype)
	local share = UVShare(e)
	Mix(st, btype, vol)
	st.wet = math.min(st.wet + vol, 200000)
	G.Entities.Impact(e, pos, n, vel, R, vol / share, 1, 0, 1, residue, nil, { btype = btype, props = true })
end

local candDirty = false
function PR.OnImpact(ent, pos, normal, volume, kind, btype, fromProps)
	if fromProps or not volume or volume <= 0 then return end
	if not PR.IsProp(ent) then return end
	local st = PR.state[ent]
	if not st then
		st = { fall = {}, wet = 0, soaked = 0, pend = {}, known = {} }
		PR.state[ent] = st
		candDirty = true
	end
	local low = normal and normal.z < -0.3
	if not low and st.zmin and pos then low = pos.z < st.zmin + math.max((st.height or 10) * 0.35, 4) end
	local d = G.Entities and G.Entities.domains and G.Entities.domains[ent]
	local add = volume * (low and 1.0 or 0.65)
	Mix(st, btype or (d and d.btype), add)
	st.wet = math.min((st.wet or 0) + add, 200000)
end

local onlyEnt
local upTr = { mask = MASK_SOLID, ignoreworld = true, filter = function(e) return e == onlyEnt end }
local groundTr = { mask = MASK_SOLID, filter = function(e) return G.Surfaces.GroundFilter(e) and e ~= onlyEnt end }

local function Box(e)
	local mn, mx = e:OBBMins(), e:OBBMaxs()
	local pts, zmin, zmax = {}, math.huge, -math.huge
	for i = 0, 7 do
		local lp = Vector(bit.band(i, 1) == 0 and mn.x or mx.x, bit.band(i, 2) == 0 and mn.y or mx.y, bit.band(i, 4) == 0 and mn.z or mx.z)
		local wp = e:LocalToWorld(lp)
		pts[#pts + 1] = wp
		if wp.z < zmin then zmin = wp.z end
		if wp.z > zmax then zmax = wp.z end
	end
	return pts, zmin, zmax, mn, mx
end

local GRID_MAX = 4
local function Contacts(e, pts, g, n)
	local t1 = n:Cross(math.abs(n.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
	t1:Normalize()
	local t2 = n:Cross(t1)
	local a0, a1, b0, b1 = math.huge, -math.huge, math.huge, -math.huge
	for _, wp in ipairs(pts) do
		local d = wp - g
		local a, b = d:Dot(t1), d:Dot(t2)
		if a < a0 then a0 = a end
		if a > a1 then a1 = a end
		if b < b0 then b0 = b end
		if b > b1 then b1 = b end
	end
	local na = math.Clamp(math.ceil((a1 - a0) / 6), 2, GRID_MAX)
	local nb = math.Clamp(math.ceil((b1 - b0) / 6), 2, GRID_MAX)
	local sa, sb = (a1 - a0) / na, (b1 - b0) / nb
	local cps = {}
	onlyEnt = e
	for i = 0, na - 1 do
		for j = 0, nb - 1 do
			local gp = g + t1 * (a0 + (i + 0.5) * sa) + t2 * (b0 + (j + 0.5) * sb)
			upTr.start, upTr.endpos = gp - n * 0.6, gp + n * (REACH + 0.5)
			local tr = util.TraceLine(upTr)
			if tr.Hit and tr.Entity == e then
				local off = tr.StartSolid and 0 or (tr.HitPos - gp):Dot(n)
				if off <= REACH then cps[#cps + 1] = gp end
			end
		end
	end
	return cps, math.max(math.min(sa, sb), 1.5)
end

local function DepthAt(st, p, tol, now)
	local best, bd = nil, tol * tol
	for _, k in ipairs(st.known) do
		if now - k.t < 1.2 then
			local dd = k.pos:DistToSqr(p)
			if dd < bd then best, bd = k, dd end
		end
	end
	if best then return best.h, best.btype, best.oxy end
	return 0
end

local function Prop(e, now)
	local st = PR.state[e]
	if not st then st = { fall = {}, wet = 0, soaked = 0, pend = {}, known = {} } PR.state[e] = st end
	local dt = math.Clamp(now - (st.t or now), 0, 1)
	st.t = now
	local pos = e:GetPos()
	local ang = e:GetAngles()
	local v = st.pos and (pos - st.pos) / math.max(dt, 0.02) or Vector(0, 0, 0)
	if st.pos and pos:DistToSqr(st.pos) > 300 * 300 then v = Vector(0, 0, 0) end
	st.pos = pos
	local lastV = st.v or v
	st.v = v
	if st.wet > 0 then
		local tau = math.max(20, math.min(G.CoagTime() * 0.8, G.DryTime() * 0.5))
		st.wet = st.wet * math.exp(-dt / tau)
	end
	local S = G.Surfaces
	local d = G.Entities.domains[e]
	local amt = Amount()
	local oxy, btype = st.oxy or 0.65, st.btype or 0
	if d then oxy, btype = d.oxy or oxy, st.utype or d.btype or btype end
	for i = #st.pend, 1, -1 do
		local q = st.pend[i]
		local ps = q.ps
		if ps.hT and ps.hT >= q.t then
			table.remove(st.pend, i)
			local h = ps.h or 0
			table.insert(st.known, 1, { pos = q.pos, h = h, btype = ps.btype, oxy = ps.oxy, t = now })
			if #st.known > 12 then st.known[13] = nil end
			if h > 0.06 and q.seg and q.speed > 8 then
				S.Impact(q.pos, q.n, q.seg, q.R * 0.9, h, 4, 0, math.max(q.speed, 20), 0.35, q.tr, oxy, btype)
				PR.stats.pushes = PR.stats.pushes + 1
				local L = q.seg:Length()
				local pick = math.min(math.max(L, q.R) * 19.05 * 2 * q.R * 0.9 * 19.05 * math.max(h - 0.04, 0) * 0.35, 1500) * math.max(amt, 0.25)
				if pick > 6 and IsValid(e) then
					OnUnderside(e, st, q.pos + q.n * 1.0, -q.n, vector_origin, q.R, pick, 0.2, ps.btype or btype)
					PR.stats.pickups = PR.stats.pickups + 1
				end
			end
		elseif now - q.t > 1.5 then
			table.remove(st.pend, i)
		end
	end
	local pts, zmin, zmax, mn, mx = Box(e)
	st.zmin, st.height = zmin, zmax - zmin
	if v.z < -100 or st.contact == false then
		onlyEnt = e
		local c = Vector(pos.x, pos.y, zmin)
		local fast = v.z < -100
		groundTr.start, groundTr.endpos = c + Vector(0, 0, 1), c + Vector(0, 0, fast and -90 or -200) + Vector(v.x, v.y, 0) * 0.1
		local tr = util.TraceLine(groundTr)
		if tr.Hit and not tr.StartSolid and C.NearBlood(tr.HitPos) then C.Probe(st.fall, tr.HitPos, tr.HitNormal, fast and 0.08 or 0.3) end
	end
	onlyEnt = e
	local mid = e:LocalToWorld((mn + mx) * 0.5)
	groundTr.start, groundTr.endpos = mid, Vector(mid.x, mid.y, zmin - REACH - 6)
	local gtr = util.TraceLine(groundTr)
	if not gtr.Hit or gtr.StartSolid or gtr.HitSky or gtr.HitNormal.z < 0.5 or zmin - gtr.HitPos.z > REACH then
		st.contact = false
		return
	end
	local n = gtr.HitNormal
	local moved = not st.cPos or st.cPos:DistToSqr(pos) > 0.04 or not st.cAng
		or math.abs(math.AngleDifference(st.cAng.p, ang.p)) + math.abs(math.AngleDifference(st.cAng.y, ang.y)) + math.abs(math.AngleDifference(st.cAng.r, ang.r)) > 0.3
	if moved or not st.cps then
		st.cps, st.spacing = Contacts(e, pts, gtr.HitPos, n)
		st.cPos, st.cAng = pos, ang
	end
	local all = st.cps
	if #all == 0 then st.contact = false return end
	local cps, R = all, math.Clamp(st.spacing * 0.65, 1, 12)
	if #all > 6 then
		cps = {}
		for k = 1, 6 do cps[k] = all[math.floor(1.5 + (k - 1) * (#all - 1) / 5)] end
		R = math.Clamp(R * math.sqrt(#all / 6), 1, 14)
	end
	local absorb = Absorbency(e)
	local cen = Vector(0, 0, 0)
	for _, p in ipairs(cps) do cen = cen + p end
	cen = cen / #cps
	local seg, L = nil, 0
	if st.contact and st.lastCen then
		seg = st.lastCen - cen
		seg = seg - n * seg:Dot(n)
		L = seg:Length()
		if L >= 120 then seg, L = nil, 0 end
	end
	local speed = L / math.max(dt, 0.02)
	local moving = speed > 5
	if C.NearBlood(gtr.HitPos) and #st.pend < 30 and now - (st.reqT or -1e9) >= (moving and 0.05 or 0.45) then
		st.reqT = now
		local idx = { 1, math.floor((#cps + 1) / 2), #cps }
		local used = {}
		for _, k in ipairs(idx) do
			if k >= 1 and not used[k] then
				used[k] = true
				local ps = {}
				G.Smear.RequestProbe(ps, cps[k], n)
				st.pend[#st.pend + 1] = { ps = ps, t = now, pos = cps[k], n = n, R = R, tr = gtr,
					seg = (moving and seg) and Vector(seg) or nil, speed = speed }
			end
		end
	end

	local wasContact = st.contact
	st.contact = true
	if not wasContact then
		local into = -lastV:Dot(n)
		if into > 110 then
			local spanR = 0
			for _, p in ipairs(cps) do spanR = math.max(spanR, p:Distance(cen)) end
			local h = C.Depth(st.fall, 1.0, cen, math.max(st.height, R * 3) + 40) or DepthAt(st, cen, R * 3 + 12, now)
			if h and h > 0.08 then
				local out = C.Splash(cen, n, h, into, spanR + R, lastV, e, st.fall.oxy or oxy, st.fall.btype or btype, gtr)
				if out > 0 then
					PR.stats.splashes = PR.stats.splashes + 1
					for k = 1, math.min(#cps, 4) do
						local p = cps[math.random(#cps)]
						OnUnderside(e, st, p + n * 1.5, -n, lastV * 0.2, R * 0.8, out * 0.02 * amt, 0.2, st.fall.btype or btype)
					end
				end
			elseif st.wet > 8 and amt > 0 then
				local vt = lastV - n * lastV:Dot(n)
				local vol = math.min(st.wet * 0.25, 400 * amt)
				for _, p in ipairs(cps) do
					S.Impact(p, n, -vt * 0.02, R, vol / #cps, 3, 0, 1, 0.4, gtr, oxy, btype)
				end
				st.wet = st.wet - vol
				PR.stats.prints = PR.stats.prints + 1
			end
		elseif into > 8 and st.wet > 8 and amt > 0 then
			local vt = lastV - n * lastV:Dot(n)
			local k = math.Clamp(into / 110, 0.25, 1)
			local vol = math.min(st.wet * 0.18 * k, 240 * amt * k)
			for _, p in ipairs(cps) do
				S.Impact(p, n, -vt * 0.015, R * 0.85, vol / #cps, 3, 0, 1, 0.35, gtr, oxy, btype)
			end
			st.wet = st.wet - vol
			PR.stats.prints = PR.stats.prints + 1
		end
		st.lastCen = cen
		return
	end
	if seg and L >= 0.5 then
		if amt > 0 and st.wet > 4 and speed > 2.5 then
			local per = #cps
			for _, p in ipairs(cps) do
				local film = (L * 19.05) * (2 * R * 0.6 * 19.05) * 0.10
				local vol = math.min(st.wet * 0.22 / per, film * amt)
				if vol > 1.5 then
					S.Impact(p, n, seg, R * 0.8, vol, 3, 0, 1, 0.45, gtr, oxy, btype)
					st.wet = st.wet - vol
					PR.stats.smears = PR.stats.smears + 1
				end
			end
		end
		st.lastCen = cen
	elseif not seg then
		st.lastCen = cen
	end
	if st.wet > 18 and amt > 0 and now - (st.seepT or 0) > 0.35 then
		st.seepT = now
		local give = math.min(st.wet * 0.12, 90 * amt)
		if give > 3 then
			local per = #cps
			for _, p in ipairs(cps) do
				S.Impact(p, n, vector_origin, R * 0.75, give / per, 1, 0, 1, 0.3, gtr, oxy, btype)
			end
			st.wet = st.wet - give
		end
	end
	if speed <= 4 and now - (st.soakT or 0) > 0.5 then
		local sdt = math.min(now - (st.soakT or now), 1)
		st.soakT = now
		local areaMM = (2 * R * 19.05) ^ 2
		local cap = areaMM * #cps * (0.03 + 0.3 * absorb) * math.max(amt, 0.25)
		if st.soaked < cap then
			for _, p in ipairs(cps) do
				local h, bt = DepthAt(st, p, R * 3 + 12, now)
				if h > 0.06 then
					local vol = math.min(areaMM * math.min(h - 0.04, 1.5) * (0.012 + 0.08 * absorb) * sdt * amt, cap - st.soaked)
					if vol > 2 then
						OnUnderside(e, st, p + n * 1.0, -n, vector_origin, R, vol, 0.15, bt or btype)
						S.Impact(p, n, vector_origin, R, h, 4, 0, 0, math.Clamp(vol / math.max(areaMM * h, 1), 0.01, 0.3), gtr, oxy, btype)
						st.soaked = st.soaked + vol
						st.wet = math.max(st.wet - vol * absorb * 0.7, 0)
						PR.stats.soaks = PR.stats.soaks + 1
					end
				end
			end
		end
	end
end

local cands, candT = {}, 0
local function Candidates(now)
	if not candDirty and now - candT < 0.5 then return cands end
	candDirty = false
	candT = now
	local eye = EyePos()
	local list = {}
	for _, e in ipairs(ents.FindInSphere(eye, RANGE)) do
		if PR.IsProp(e) then
			local st = PR.state[e]
			local p = e:GetPos()
			if C.NearBlood(p, 4) or (st and st.wet > 4) or (G.Entities and G.Entities.domains and G.Entities.domains[e]) or (G.Lite and G.Lite.bodies and G.Lite.bodies[e]) then
				list[#list + 1] = { e, p:DistToSqr(eye) }
			end
		end
	end
	table.sort(list, function(a, b) return a[2] < b[2] end)
	cands = {}
	for k = 1, math.min(#list, MAX_PROPS) do cands[k] = list[k][1] end
	PR.stats.props = #cands
	return cands
end

function PR.Update()
	if not G.cv.enable:GetBool() or not G.cv.props:GetBool() then return end
	local now = CurTime()
	if now < (PR.next or 0) then return end
	PR.next = now + TICK * (G.Gov and G.Gov.TickMul() or 1)
	C.Grid(now)
	for _, e in ipairs(Candidates(now)) do
		if IsValid(e) then
			local ok, err = pcall(Prop, e, now)
			if not ok then ErrorNoHalt("[GHMPB] props: " .. tostring(err) .. "\n") end
		end
	end
	for e in pairs(PR.state) do if not IsValid(e) then PR.state[e] = nil end end
end

function PR.Clear()
	PR.state = {}
	candT = 0
end
