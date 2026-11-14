local G = GHMPB
G.Runs = G.Runs or {}
local R = G.Runs
local U = G.U

R.heads = R.heads or {}
R.cells = R.cells or {}
R.trails = R.trails or {}
R.MAX = 80
R.CELL = 0.45
R.HEAD_MAX = 80
R.TRAIL_CELL = 0.35
R.stats = R.stats or { spawned = 0, merged = 0, floor = 0, drip = 0, stopped = 0, bent = 0, water = 0 }
R.stats.slides = R.stats.slides or 0
R.stats.slid = R.stats.slid or 0
R.stats.slideruns = R.stats.slideruns or 0
R.SLIDE_MAX = 40

local MM = 19.05
local exp, sqrt, floor, min, max, abs = math.exp, math.sqrt, math.floor, math.min, math.max, math.abs

local function Amount()
	local cv = G.cv.runs
	return cv and cv:GetFloat() or 1
end

local function Hold(sf)
	return 2.1 * (sf.pin or 0.4) / max(Amount(), 0.05)
end
R.Hold = Hold

-- (1.26.6) width (mm) of a rivulet of volume v: wider for its volume than before (1.6-4.6 mm: hair-thin threads), and
-- wm wider still the flatter the slope (blood spreads sideways where gravity pulls it less)
local function Width(v, wm) return math.Clamp(1.6 + 0.75 * math.max(v, 0) ^ (1 / 3), 1.9, 7.5) * (wm or 1) end
local function SlopeK(N) return math.Clamp((N and N.z or 0) / 0.966, 0, 1) end
local function WMul(N) return 1 + 1.3 * SlopeK(N) end
R.Width, R.WMul = Width, WMul

local function Downhill(N)
	local D = Vector(0, 0, -1) + N * N.z
	local l = D:Length()
	if l < 1e-3 then return nil end
	D:Mul(1 / l)
	return D
end

local function WetTau()
	local t = G.cv.coag:GetBool() and G.CoagTime() * 0.4 or 60
	return math.Clamp(t, 12, 90)
end

local function CellKey(i, j) return (i + 131072) * 262144 + (j + 131072) end

-- (1.26.8) the cost of the rivulets follows the detail level (cl_governor.lua V.Detail): fewer heads at once with less
-- detail (24 to 80), and a trail stamped every 0.3 u with the shaders (a stroke into the patch) but every 1.2 u with
-- Lite, where each stamp is a quad of its own (1.26.7: a quad every 0.3 u, 27 a second for every head, up to 80 heads -
-- the Lite stains filled up with rivulet bits and the frame with their cost)
local function Detail()
	if G.Gov and G.Gov.Detail then return G.Gov.Detail() end
	return 1, 0
end
local function MaxHeads() return math.floor(24 + (R.MAX - 24) * Detail()) end
R.MaxHeads = MaxHeads
local function Lite() return G.Lite and G.Lite.on end
-- (1.26.8) with the shaders always 0.3 u and 0.25 u, as in 1.26.7 (GHM: "the bleeding physics on surfaces smoother")
local function TrailStep() return Lite() and 1.2 or 0.3 end
local function SlideStep() return Lite() and 1.0 or 0.25 end

local function Info(tr, p)
	return { HitTexture = (tr and tr.HitTexture) or (p and p.albedoTex), Entity = tr and tr.Entity, MatType = tr and tr.MatType,
		SurfaceProps = tr and tr.SurfaceProps, HitWorld = tr and tr.HitWorld }
end

local function Meander(h, rough)
	h.k1, h.p1, h.a1 = U.RandRange(0.3, 0.6), math.random() * 6.283, (0.025 + 0.07 * rough) * U.RandRange(0.6, 1.3)
	h.k2, h.p2, h.a2 = U.RandRange(1.6, 2.8), math.random() * 6.283, (0.008 + 0.02 * rough) * U.RandRange(0.5, 1.2)
end

local function Spawn(p, pos, vol, oxy, btype, info, D, steep)
	if #R.heads >= MaxHeads() then return false end
	local N = Vector(p.N)
	local T = N:Cross(D)
	T:Normalize()
	local h = { plane = p.plane, N = N, D = D, T = T, steep = steep, pos = Vector(pos), last = Vector(pos), vol = vol, age = 0, wm = WMul(N),
		oxy = oxy or 0.75, btype = btype or 0, surf = p.surf, info = info, theta = 0, steer = 0,
		speed = 0, dist = 0, sinceStamp = 0, acc = 0, pause = 0, seed = math.random() * 100, lastTrail = 0 }
	Meander(h, (p.surf and p.surf.rough) or 0.5)
	R.heads[#R.heads + 1] = h
	R.stats.spawned = R.stats.spawned + 1
	G.DiagCount("runs: started")
	return true
end
R.SpawnHead = Spawn

-- 1.26.0: cells are laid out across (T) and down (D) the slope, each R.CELL wide and R.CELL_TALL high: the blood of a
-- spatter that sits above a spot runs into the same rivulet, so dense spatter / heavy contact stains join up and run
-- (in 1.25 each 0.45 u square had to collect the whole hold on its own - only direct heavy hits ever ran)
R.CELL_TALL = 3
-- kind weights: drops / pools carry their full volume, smears and mist deposits wet the wall but are spread thin
local FEED_W = { [0] = 1.0, [1] = 1.0, [3] = 0.55, [6] = 0.6 }
R.FEED_W = FEED_W

function R.Feed(p, pos, vol, radiusU, kind, tr, oxy, btype)
	if R.noFeed or Amount() <= 0 or not p or not vol or vol < 0.5 then return 0 end
	local N = p.N
	if N.z > 0.966 or N.z < -0.35 then return 0 end
	local sf = p.surf or G.Surface.sealed
	if (sf.fabric or 0) >= 0.8 or sf.nostain then return 0 end
	local D = Downhill(N)
	if not D then return 0 end
	local steep = sqrt(max(1 - N.z * N.z, 0.05))
	local now = CurTime()
	local cells = R.cells[p.plane]
	if not cells then cells = {} R.cells[p.plane] = cells end
	local tau = WetTau()
	local hold = Hold(sf)
	-- (1.26.6) on slopes wider lanes (fewer, fuller streams) and heads that carry more
	local sk = SlopeK(N)
	local wm = WMul(N)
	local c = R.CELL * (1 + 2 * sk)
	local ct = c * R.CELL_TALL
	local headMax = R.HEAD_MAX * (1.75 + 4.5 * sk)
	local wet = vol * (FEED_W[kind or 0] or 0.8)
	local T = N:Cross(D)
	T:Normalize()
	radiusU = math.max(radiusU or 0.1, 0.05)
	local nLat = math.Clamp(floor(2 * radiusU / c + 0.5), 1, 5)
	local laneW = math.min(c, 2 * radiusU / nLat)
	local taken = 0
	local spawnable = kind == 0 or kind == 1 or (kind == 3 and vol > 6) or kind == 6
	for k = 1, nLat do
		local off = (k - (nLat + 1) / 2) * (2 * radiusU / nLat)
		local q = pos + T * off
		local u, v = q:Dot(T), q:Dot(D)
		local key = CellKey(floor(u / c), floor(v / ct))
		local cell = cells[key]
		if not cell then cell = { v = 0, t = now, w = 0 } cells[key] = cell end
		local age = exp(-(now - cell.t) / tau)
		cell.v = cell.v * age + wet / nLat
		cell.w = math.max(cell.w * age, laneW)
		cell.t = now
		local cellHold = hold * (cell.w * MM) / steep
		local excess = math.min(cell.v - cellHold, headMax)
		if spawnable and excess > 1.2 then
			local w = Width(excess, wm)
			local vStop = hold * w / steep
			if excess > vStop * 0.9 + 0.8 then
				local y = sqrt(max(radiusU * radiusU - off * off, 0)) * 0.85
				local at = q + D * y
				if Spawn(p, at, excess, oxy, btype, Info(tr, p), D, steep) then
					cell.v = cell.v - excess
					taken = taken + excess
				end
			end
		end
	end
	return math.min(taken, vol * 0.8)
end

local function TrailAdd(h)
	local t = R.trails[h.plane]
	if not t then t = {} R.trails[h.plane] = t end
	local c = R.TRAIL_CELL
	local u, v = h.pos:Dot(h.N:Cross(h.T)), h.pos:Dot(h.T)
	t[CellKey(floor(u / c), floor(v / c))] = { a = u, b = v, t = CurTime() }
end

local function TrailAhead(h)
	local t = R.trails[h.plane]
	if not t then return nil end
	local c = R.TRAIL_CELL
	local along = h.N:Cross(h.T)
	local now, life = CurTime(), WetTau() * 2
	local best, bd = nil, 1.0
	for _, ahead in ipairs({ 0.3, 0.75 }) do
		local q = h.pos + h.D * ahead
		local u, v = q:Dot(along), q:Dot(h.T)
		local iu, iv = floor(u / c), floor(v / c)
		for dj = -3, 3 do
			local e = t[CellKey(iu, iv + dj)]
			if e and now - e.t < life then
				local d = e.b - v
				if abs(d) < bd then best, bd = d, abs(d) end
			end
		end
	end
	return best
end

local function Trail(h, final)
	if h.acc <= 0.02 then h.acc = 0 return end
	local w = Width(h.vol, h.wm) * (h.slide and 0.75 or 1)
	local path = h.last - h.pos
	-- (1.26.6) 15 % stain (was 38 %: the trails looked dry at once)
	G.Surfaces.Impact(h.pos, h.N, path, w * 0.5 / MM, h.acc, 7, 0, 1, 0.15, h.info, h.oxy, h.btype)
	h.acc = 0
	h.last = Vector(h.pos)
	h.sinceStamp = 0
end

local BEAD_X = { K = 2, spines = 0, flags = 0 }
local function Bead(h)
	if h.vol < 0.3 then return end
	-- (1.26.6) a flat bead about 0.4 mm deep (it was a dot up to 2 mm high, a dark lump at the end of every run), wet:
	-- the standard 20 % stain of a drop (K) instead of the 38 % minimum
	local v = min(h.vol, 2.5)
	local rmm = min(sqrt(v / (2.0944 * 0.4)), Width(h.vol, h.wm) * 0.6)
	R.noFeed = true
	G.Surfaces.Impact(h.pos + h.D * (rmm * 0.35 / MM), h.N, -h.N * 40 + h.D * 8, rmm / MM, v, 0, 0, 1.15, 0.1, h.info, h.oxy, h.btype, BEAD_X)
	R.noFeed = false
	h.vol = 0
end

local trA, trB = {}, {}
local tdA = { mask = MASK_SOLID, output = trA }
local tdB = { mask = MASK_SOLID, output = trB }

local function Copy(tr)
	return { HitTexture = tr.HitTexture, Entity = tr.Entity, MatType = tr.MatType, SurfaceProps = tr.SurfaceProps,
		HitWorld = tr.HitWorld, HitPos = Vector(tr.HitPos), HitNormal = Vector(tr.HitNormal) }
end

local function Finish(h, why)
	R.stats[why] = (R.stats[why] or 0) + 1
	h.dead = true
end

local function Move(h, dir, ds)
	local N = h.N
	local from, to = h.pos, h.pos + dir * ds
	tdA.filter = G.Surfaces.GroundFilter
	tdB.filter = tdA.filter
	tdA.start = from + N * 0.2
	tdA.endpos = to + N * 0.2 + dir * 0.15
	util.TraceLine(tdA)
	if trA.Hit and not trA.StartSolid and trA.HitNormal:Dot(dir) < -0.35 then
		tdB.start = to + N * 1.4 + dir * 0.1
		tdB.endpos = to - N * 0.4 + dir * 0.1
		util.TraceLine(tdB)
		if trB.Hit and not trB.StartSolid and trB.HitNormal:Dot(N) > 0.96 and (trB.HitPos - from):Dot(N) < 1.25 then
			local catch = h.vol * 0.12
			h.vol = h.vol - catch
			h.acc = h.acc + catch
			Trail(h)
			h.pos = trB.HitPos + N * 0.02
			h.last = Vector(h.pos)
			h.pause = math.max(h.pause, U.RandRange(0.15, 0.6))
			return true
		end
		Trail(h, true)
		if h.vol > 0.3 then
			local info = Copy(trA)
			local nrm = info.HitNormal
			local tang = dir - nrm * dir:Dot(nrm)
			local arrivalVel = (tang:LengthSqr() > 0.01 and tang:GetNormalized() or dir) * (h.speed * 10 + 24)
			G.Surfaces.Impact(info.HitPos, nrm, arrivalVel, Width(h.vol, h.wm) * 0.42 / MM, h.vol, 1, 0, 1.12, 0, info, h.oxy, h.btype)
			if nrm.z > 0.7 and G.Surfaces.WellWave then
				G.Surfaces.WellWave(info.HitPos, math.Clamp(h.vol * 0.08, 0.18, 0.95))
			end
			h.vol = 0
		end
		Finish(h, "floor")
		return false
	end
	tdB.start = to + N * 0.6
	tdB.endpos = to - N * 1.0
	util.TraceLine(tdB)
	if trB.Hit and not trB.StartSolid and not trB.HitSky then
		local d = trB.HitNormal:Dot(N)
		if d > 0.96 then
			h.pos = trB.HitPos + N * 0.02
			if G.Water and G.Water.InWater(h.pos + N * 0.3) then
				Trail(h, true)
				if h.vol > 0.3 then G.Water.Enter(h.pos + N * 0.3, dir * (h.speed + 5), h.vol, h.btype, h.oxy) h.vol = 0 end
				Finish(h, "water")
				return false
			end
			return true
		end
		if d > 0.35 then
			Trail(h, true)
			local nN = Vector(trB.HitNormal)
			local nD = Downhill(nN)
			if nD and nN.z <= 0.966 and nN.z >= -0.35 then
				h.N, h.D = nN, nD
				h.wm = WMul(nN)
				h.T = nN:Cross(nD) h.T:Normalize()
				h.steep = sqrt(max(1 - nN.z * nN.z, 0.05))
				h.pos = trB.HitPos + nN * 0.02
				h.last = Vector(h.pos)
				h.info = Copy(trB)
				local p = G.Surfaces.GetPatch(h.pos, nN, false)
				h.plane = p and p.plane or h.plane
				R.stats.bent = R.stats.bent + 1
				return true
			end
			local info = Copy(trB)
			local nrm = info.HitNormal
			local tang = dir - nrm * dir:Dot(nrm)
			local arrivalVel = (tang:LengthSqr() > 0.01 and tang:GetNormalized() or dir) * 24
			G.Surfaces.Impact(info.HitPos, nrm, arrivalVel, Width(h.vol, h.wm) * 0.42 / MM, h.vol, 1, 0, 1.12, 0, info, h.oxy, h.btype)
			if nrm.z > 0.7 and G.Surfaces.WellWave then
				G.Surfaces.WellWave(info.HitPos, math.Clamp(h.vol * 0.08, 0.18, 0.95))
			end
			h.vol = 0
			Finish(h, "floor")
			return false
		end
	end
	Trail(h, true)
	if h.vol > 0.5 then
		G.Particles.Hang(from + dir * 0.15 - N * 0.05, dir * 4, h.vol, nil, h.oxy, h.btype)
		h.vol = 0
	end
	Finish(h, "drip")
	return false
end

function R.Slide(tr, n, pos, dir, speed, vol, oxy, btype)
	if speed < 3 or not vol or vol < 0.5 or #R.heads >= MaxHeads() then return false end
	local nSlide = 0
	for _, h in ipairs(R.heads) do if h.slide and not h.dead then nSlide = nSlide + 1 end end
	if nSlide >= R.SLIDE_MAX then return false end
	local N = Vector(n)
	local D = dir - N * dir:Dot(N)
	local l = D:Length()
	if l < 1e-3 then return false end
	D:Mul(1 / l)
	local p = G.Surfaces.GetPatch and G.Surfaces.GetPatch(pos, N, false)
	local sf = (p and p.surf) or (tr and G.Surface[G.SurfaceKindOf(tr)]) or G.Surface.sealed
	if (sf.fabric or 0) >= 0.6 or sf.nostain then return false end
	local T = N:Cross(D)
	T:Normalize()
	local h = { slide = true, plane = p and p.plane or string.format("n%d,%d,%d", math.floor(N.x * 50 + 0.5), math.floor(N.y * 50 + 0.5), math.floor(N.z * 50 + 0.5)),
		N = N, D = Vector(D), T = T, steep = sqrt(max(1 - N.z * N.z, 0.05)), pos = Vector(pos), last = Vector(pos), vol = vol, age = 0, wm = WMul(N),
		oxy = oxy or 0.75, btype = btype or 0, surf = sf, info = Info(tr, p), theta = 0, steer = 0, v = D * speed, speed = speed,
		dist = 0, sinceStamp = 0, acc = 0, pause = 0, seed = math.random() * 100, lastTrail = 0, dirW = Vector(D) }
	Meander(h, sf.rough or 0.5)
	R.heads[#R.heads + 1] = h
	R.stats.slides = R.stats.slides + 1
	G.DiagCount("runs: sliding droplets started")
	return true
end

local function SlideEnd(h)
	if h.vol < 0.3 then h.acc = h.acc + h.vol h.vol = 0 end
	Trail(h, true)
	h.D = h.dirW or h.D
	Bead(h)
	Finish(h, "slid")
end

local function StepSlide(h, dt)
	h.age = h.age + dt
	local sf = h.surf
	local rough = sf.rough or 0.5
	local N = h.N
	local g = GetConVarNumber("sv_gravity") or 600
	local gt = Vector(0, 0, -g) - N * (-g * N.z)
	local v = h.v - N * h.v:Dot(N)
	local sp = v:Length()
	local drag = (2.2 + 3.0 * rough) * sp + (40 + 90 * rough)
	if sp > 1e-3 then v:Mul(math.max(sp - drag * dt, 0) / sp) end
	local steepFace = N.z <= 0.966
	if not steepFace then v = v + gt * (0.3 * dt) end
	v = v - N * v:Dot(N)
	sp = v:Length()
	h.v, h.speed = v, sp
	if sp < (steepFace and 6 or 2) then
		local D = Downhill(N)
		local w = Width(h.vol, h.wm)
		if D and steepFace and N.z >= -0.35 and Amount() > 0 and h.vol > Hold(sf) * w / h.steep * 1.25 + 1.5 then
			Trail(h, true)
			h.slide = nil
			h.D = D
			h.T = N:Cross(D) h.T:Normalize()
			h.steep = sqrt(max(1 - N.z * N.z, 0.05))
			h.speed, h.theta, h.steer, h.dist, h.age = 0, 0, 0, 0, 0
			R.stats.slideruns = R.stats.slideruns + 1
			return
		end
		SlideEnd(h)
		return
	end
	local dir = v / sp
	local ds = sp * dt
	if Move(h, dir, ds) then
		h.dist = h.dist + ds
		h.sinceStamp = h.sinceStamp + ds
		local film = (sf.hret or 0.04) * 0.6 + (sf.kabs or 0) * 0.25
		local keep = math.min(0.45, h.vol)
		local dv = math.min(film * Width(h.vol, h.wm) * 0.75 * (ds * MM), h.vol - keep)
		h.vol = h.vol - dv
		h.acc = h.acc + dv
		h.dirW = dir
		if h.sinceStamp >= SlideStep() then Trail(h) end
		if h.vol <= keep + 1e-6 then SlideEnd(h) end
	end
end

R.HZ = 30
local function StepHeads(dt)
	local amount = Amount()
	local speedMul = G.cv.runspeed and G.cv.runspeed:GetFloat() or 1
	local coagT = G.cv.coag:GetBool() and G.CoagTime() or 1e9
	local visc = G.cv.viscosity:GetFloat()
	local now = CurTime()
	for _, h in ipairs(R.heads) do
		if h.slide and not h.dead then
			StepSlide(h, dt)
		elseif not h.dead then
			h.age = h.age + dt
			local sf = h.surf
			local rough = sf.rough or 0.5
			local hold = Hold(sf)
			local w = Width(h.vol, h.wm)
			local clot = math.Clamp(h.age / math.max(coagT * 0.5, 5), 0, 1)
			local vStop = hold * w / h.steep * 0.8 * (1 + 1.5 * clot * clot)
			if h.speed < 0.06 and h.pause <= 0 and h.age > 0.5 then h.slowT = (h.slowT or 0) + dt else h.slowT = 0 end
			if h.vol <= vStop or amount <= 0 or h.slowT > 1.2 then
				Trail(h, true)
				Bead(h)
				Finish(h, "stopped")
			else
				local ex = (h.vol - vStop) / 25
				local v = 1.8 * sqrt(math.min(ex, 6)) * h.steep ^ 0.8 * (1.2 - 0.45 * rough) * (1 - 0.75 * clot) / math.max(visc, 0.3) * speedMul
				local lat = ((h.noMergeT or 0) < now) and TrailAhead(h) or nil
				local loss = 1
				local onTrail = lat and abs(lat) < 0.3
				if lat then
					h.steer = h.steer + math.Clamp(lat * 1.8, -0.5, 0.5) * math.min(dt * 5, 1)
					if onTrail then
						v = v * 1.35
						loss = 0.45
					end
				end
				if h.pause > 0 then
					h.pause = h.pause - dt
					v = v * 0.08
				end
				h.speed = h.speed + (math.Clamp(v, 0, 8) - h.speed) * math.min(dt * 8, 1)
				local ds = h.speed * dt
				if ds > 1e-4 then
					if rough > 0.35 and not onTrail and math.random() < ds * 0.35 * rough then
						h.pause = U.RandRange(0.1, 0.55) * rough
						h.steer = h.steer + (math.random() - 0.5) * 0.2 * rough
					end
					local wave = h.a1 * math.sin(h.k1 * h.dist + h.p1) + h.a2 * math.sin(h.k2 * h.dist + h.p2)
					h.steer = h.steer * exp(-ds * (lat and 0.3 or 1.2))
					h.theta = math.Clamp(wave * (onTrail and 0.2 or 1) + h.steer, -0.45, 0.45)
					local dir = h.D * math.cos(h.theta) + h.T * math.sin(h.theta)
					if Move(h, dir, ds) then
						h.dist = h.dist + ds
						h.sinceStamp = h.sinceStamp + ds
						local film = (sf.hret or 0.04) * 0.85 + (sf.kabs or 0) * 0.25
						local dv = film * w * (ds * MM) * loss
						dv = math.min(dv, h.vol)
						h.vol = h.vol - dv
						h.acc = h.acc + dv
						h.dirW = dir
						if h.dist - h.lastTrail > 0.15 then h.lastTrail = h.dist TrailAdd(h) end
						if h.sinceStamp >= TrailStep() then Trail(h) end
						-- 1.26.0: a full rivulet forks at bumps and pores of the wall: part of it splits off sideways and runs
						-- its own way (smooth walls rarely, rough plaster / brick more often)
						if not onTrail and h.vol > vStop * 2.2 + 6 and #R.heads < MaxHeads() - 4 and (h.forks or 0) < 3
							and math.random() < ds * (0.025 + 0.1 * rough) then
							local part = h.vol * U.RandRange(0.3, 0.45)
							local side = (math.random() < 0.5) and -1 or 1
							local nh = { plane = h.plane, N = h.N, D = h.D, T = h.T, steep = h.steep, pos = h.pos + h.T * (side * 0.12), wm = h.wm,
								last = Vector(h.pos), vol = part, age = h.age, oxy = h.oxy, btype = h.btype, surf = h.surf, info = h.info,
								theta = 0, steer = side * U.RandRange(0.18, 0.35), speed = h.speed * 0.6, dist = 0, sinceStamp = 0, acc = 0,
								pause = 0, seed = math.random() * 100, lastTrail = 0, forks = (h.forks or 0) + 1 }
							Meander(nh, rough)
							h.vol = h.vol - part
							h.forks = (h.forks or 0) + 1
							h.steer = h.steer - side * 0.12
							nh.noMergeT, h.noMergeT = now + 1.5, now + 1.5
							R.heads[#R.heads + 1] = nh
							R.stats.forks = (R.stats.forks or 0) + 1
						end
					end
				end
			end
		end
	end
	if (R.nextMerge or 0) < now then
		R.nextMerge = now + 0.1
		local n = #R.heads
		-- (1.26.6) each stream's width once per pass (it was worked out for every pair)
		local ws = {}
		for k = 1, n do local h = R.heads[k] ws[k] = Width(h.vol, h.wm) end
		for i = 1, n do
			local a = R.heads[i]
			if not a.dead and (a.noMergeT or 0) < now then
				for j = i + 1, n do
					local b = R.heads[j]
					if not b.dead and b.plane == a.plane and (b.noMergeT or 0) < now then
						local mr = math.max(0.3, 0.5 * (ws[i] + ws[j]) / MM)
						if a.pos:DistToSqr(b.pos) < mr * mr then
							local keep, gone, kk = a, b, i
							if b.pos.z < a.pos.z then keep, gone, kk = b, a, j end
							Trail(gone, true)
							keep.vol = keep.vol + gone.vol
							gone.vol = 0
							gone.dead = true
							ws[kk] = Width(keep.vol, keep.wm)
							R.stats.merged = R.stats.merged + 1
							if gone == a then break end
						end
					end
				end
			end
		end
	end
	for i = #R.heads, 1, -1 do if R.heads[i].dead then table.remove(R.heads, i) end end
end

function R.Step(dt)
	if #R.heads == 0 then R.clock = 0 return end
	-- (1.26.8) at most two steps a frame (three before: a slow frame made the next one slower still); 30 steps a second
	-- with the shaders, as in 1.26.7 (smooth paths), 15 to 30 with Lite by the detail level
	local hz = (Lite() and R.HZ * (0.5 + 0.5 * Detail())) or R.HZ
	R.clock = math.min((R.clock or 0) + dt, 2 / hz)
	local step = 1 / hz
	while R.clock >= step do
		R.clock = R.clock - step
		StepHeads(step)
	end
end

function R.Prune()
	local now = CurTime()
	local tau = WetTau()
	for plane, cells in pairs(R.cells) do
		local any = false
		for k, c in pairs(cells) do
			if now - c.t > tau * 3 then cells[k] = nil else any = true end
		end
		if not any then R.cells[plane] = nil end
	end
	for plane, t in pairs(R.trails) do
		local any = false
		for k, e in pairs(t) do
			if now - e.t > tau * 2 then t[k] = nil else any = true end
		end
		if not any then R.trails[plane] = nil end
	end
end

-- (1.26.6) the bead at the front of a rivulet: a small dome on the surface - at most 1.5 mm round and no wider than a third
-- of the stream (heads carry up to 0.5 ml on slopes since 1.26.6: drawn as a sphere of their volume they were balls of up
-- to 8 mm standing off the surface). The last argument marks it as lying on a surface (lit by the surface's light)
function R.Draw(add)
	local MMU = G.MM_TO_UNITS
	for _, h in ipairs(R.heads) do
		if not h.dead and h.vol > 0.5 then
			local r = math.min((h.vol / 4.18879) ^ (1 / 3) * 0.85, Width(h.vol, h.wm) * 0.3, 1.5)
			local p = h.pos + h.N * (r * MMU * 0.3)
			local d = h.dirW or h.D
			add(p.x, p.y, p.z, d.x * 0.6, d.y * 0.6, d.z * 0.6, r, 1.25 + math.min(h.speed * 0.08, 0.35), h.btype or 0, math.floor((h.oxy or 0.75) * 9 + 0.5), true)
		end
	end
end

-- (1.26.6) the light the rivulet heads are drawn with: what the surface under them receives (weighted to the heads nearest
-- the camera), and the sun (or the strongest light) for their highlight. nil: no heads
function R.HeadLight(eye)
	local now = CurTime()
	local wsum, ar, ag, ab = 0, 0, 0, 0
	local near, nd = nil, math.huge
	for _, h in ipairs(R.heads) do
		if not h.dead and h.vol > 0.5 then
			if not h.litE or now - (h.litT or 0) > 0.4 or now < (h.litT or 0) then
				-- (1.26.8) the shared sample of that spot (cl_lighting.lua G.Light.At), not one engine call per head
				h.litE = (G.Light and G.Light.At) and G.Light.At(h.pos, h.N) or render.ComputeLighting(h.pos + h.N * 0.5, h.N)
				h.litT = now
			end
			local d2 = h.pos:DistToSqr(eye)
			local w = 1 / (1 + d2 / 10000)
			local e = h.litE
			ar, ag, ab, wsum = ar + e.x * w, ag + e.y * w, ab + e.z * w, wsum + w
			if d2 < nd then near, nd = h, d2 end
		end
	end
	if not near then return nil end
	local dir, col = Vector(0, 0, 1), Vector(0, 0, 0)
	local lt = G.Light and G.Light.Get and G.Light.Get("runheads", near.pos + near.N * 2, 0.4)
	if lt then
		if (lt.sunVis or 0) > 0 and lt.sunDir then
			dir, col = lt.sunDir, lt.sunCol * (lt.sunVis * 0.35)
		elseif lt.dir then
			dir, col = lt.dir, lt.col * 0.3
		end
	end
	return { amb = Vector(ar / wsum, ag / wsum, ab / wsum), dir = dir, col = col, bt = near.btype or 0 }
end

function R.Count() return #R.heads end

function R.Clear()
	R.heads = {}
	R.cells = {}
	R.trails = {}
end
