local G = GHMPB
G.Particles = G.Particles or {}
local P = G.Particles
local U = G.U

P.list = P.list or {}
local list = P.list

local RHO_AIR_OVER_BLOOD = 1.2 / 1060
local SIGMA = 0.058
local MU_AIR = 1.8e-5

local function DragCd(speedMS, dM)
	local re = math.max(1.2 * speedMS * dM / MU_AIR, 1e-3)
	local cd = re < 1000 and 24 / re * (1 + 0.15 * re ^ 0.687) or 0.44
	local weAir = 1.2 * speedMS * speedMS * dM / SIGMA
	return cd * math.min(1 + 0.18 * weAir, 3)
end
P.DragCd = DragCd
local TRACE_BUDGET = 900
local traceRot, traceWant, traceCost = 0, 600, 1e-5
local trA, trB = Vector(), Vector()

local function vol(rmm) return 4.18879 * rmm * rmm * rmm end
local function radiusFromVol(v) return (v / 4.18879) ^ (1 / 3) end

local WATERMASK = bit.bor(CONTENTS_WATER, CONTENTS_SLIME)
P.WATERMASK = WATERMASK

P.rate = P.rate or 0
local spawnsNow = 0
P.thinK = P.thinK or 1
local thinF, thinV = -1, 1
function P.Thin()
	local f = FrameNumber()
	if f == thinF then return thinV end
	local over = math.max(0, P.rate - 600) / 600
	local cap = G.cv.maxdrops:GetInt()
	local full = cap > 0 and math.max(0, P.Count() / cap - 0.6) / 0.4 or 0
	thinF, thinV = f, math.min(math.max(math.min(1 + 0.8 * over + 1.5 * full, 3), P.thinK), 6)
	return thinV
end
-- (1.26.6) thinning for hit spatter, against its own (higher) limit
local thinPF, thinPV = -1, 1
function P.ThinPrio()
	local f = FrameNumber()
	if f == thinPF then return thinPV end
	local over = math.max(0, P.rate - 900) / 900
	local cap = G.cv.maxdrops:GetInt() * 1.6 + 300
	local full = math.max(0, P.Count() / cap - 0.7) / 0.3
	thinPF, thinPV = f, math.min(math.max(math.min(1 + 0.6 * over + 1.2 * full, 2.5), P.thinK), 4)
	return thinPV
end
P.LAND_MS = 2.5
local function UpdateThinK(dt)
	local N = G.Native
	local want = N and N.want
	if not want or want <= 0 or dt <= 0 then P.thinK = 1 return end
	local r = math.max(P.rate * dt / (0.45 * want), (N.landMs or 0) / P.LAND_MS)
	r = math.Clamp(r, 0.5, 2)
	P.thinK = math.Clamp(P.thinK * r ^ 0.25, 1, 6)
end
P.UpdateThinK = UpdateThinK

function P.Spawn(o)
	if not G.cv.enable:GetBool() then return end
	spawnsNow = spawnsNow + 1
	-- (1.26.10) a drop that will fly into the camera lands on the screen (cl_screen.lua)
	local Sc = G.Screen
	if Sc and o.vel and (Sc.On() or (G.cv.vmblood and G.cv.vmblood:GetBool())) then Sc.CheckDrop(o) end
	if G.Water and o.pos and bit.band(util.PointContents(o.pos), WATERMASK) ~= 0 then
		local r = o.r or 1
		G.Water.Enter(o.pos, o.vel or vector_origin, 4.18879 * r * r * r, o.btype, o.oxy)
		return
	end
	if o.pos and o.vel and P.FarOK(o.pos) then return P.SpawnFar(o) end
	local cap = G.Gov and G.Gov.DropCap(G.cv.maxdrops:GetInt()) or G.cv.maxdrops:GetInt()
	-- (1.26.6) hit spatter (prio) may go past the limit: bleeding bodies that keep the droplet count at the limit left
	-- gunshots without any spatter
	if o.prio then cap = cap * 1.6 + 300 end
	if P.Count() >= cap then return end
	if not o.broke and P.Thin() > 1.3 then o.broke = true end
	if G.Native and G.Native.Available() and G.cv.native:GetBool() then
		P.CountedSpawn()
		return G.Native.Spawn(o)
	end
	-- (1.26.8) a drop in flight is plain numbers (position, velocity, where its last trace ended): GMod's Vector methods
	-- and fields are calls into the engine, and the solver made ~10 of them per drop per frame (plus 6 more to draw it)
	local x, y, z = o.pos:Unpack()
	local vx, vy, vz = o.vel:Unpack()
	local p = {
		x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, tx = x, ty = y, tz = z, r = o.r or 1, spin = o.spin or 0,
		stretch = o.stretch or 1, age = 0, life = o.life or 6, owner = o.owner, oxy = o.oxy or 0.75,
		btype = o.btype or 0, broke = o.broke or false, ownerGrace = o.ownerGrace or 0.06,
		flags = o.flags or 0, wc = 0,
	}
	p.v = vol(p.r)
	list[#list + 1] = p
	return p
end

function P.Spray(o)
	local n = math.floor((o.count or 10) * G.cv.spray:GetFloat() + 0.5)
	local em = G.Gov and G.Gov.EmitMul(o.pos) or 1
	local rk = 1
	if em > 1 and n > 2 then
		local n2 = math.max(2, math.floor(n / em + 0.5))
		rk = (n / n2) ^ (1 / 3)
		n = n2
	end
	for i = 1, n do
		local d = U.ConeDir(o.dir, o.cone or 0.4)
		local speed = U.RandRange(o.speedMin or 100, o.speedMax or 300)
		local r = U.DropRadius(o.r0 or 0.6, o.spread or 0.55) * rk
		speed = speed * math.Clamp((0.6 / r) ^ 0.25, 0.6, 1.6)
		P.Spawn({ pos = o.pos + d * U.RandRange(0, 0.5), vel = d * speed + (o.base or vector_origin), r = r, owner = o.owner,
			oxy = o.oxy, btype = o.btype, spin = (o.spin or 0) + U.RandRange(-40, 40),
			stretch = (o.stretch or 1) * U.RandRange(1, 1.6), ownerGrace = o.ownerGrace })
	end
	if o.mist and G.cv.mist:GetBool() then P.Mist(o.pos, o.dir, o.mist, o.btype) end
end

function P.Burst(o)
	local n = math.floor((o.count or 16) * G.cv.spray:GetFloat() + 0.5)
	local em = G.Gov and G.Gov.EmitMul(o.pos) or 1
	local rk = 1
	if em > 1 and n > 2 then
		local n2 = math.max(2, math.floor(n / em + 0.5))
		rk = (n / n2) ^ (1 / 3)
		n = n2
	end
	if n <= 0 then return 0 end
	local up = o.up or Vector(0, 0, 1)
	local side = up:Cross(Vector(1, 0, 0))
	if side:LengthSqr() < 0.01 then side = up:Cross(Vector(0, 1, 0)) end
	side:Normalize()
	local fwd = side:Cross(up)
	fwd:Normalize()
	local a0 = math.random() * 2 * math.pi
	local elMin, elMax = math.rad(o.elMin or 25), math.rad(o.elMax or 65)
	for i = 1, n do
		local az = a0 + (i - 1 + math.random() * 0.8) / n * 2 * math.pi
		local el = U.RandRange(elMin, elMax)
		local h = side * math.cos(az) + fwd * math.sin(az)
		local d = h * math.cos(el) + up * math.sin(el)
		local r = U.DropRadius(o.r0 or 0.7, o.spread or 0.7) * rk
		local speed = U.RandRange(o.speedMin or 50, o.speedMax or 170) * math.Clamp((0.6 / r) ^ 0.25, 0.6, 1.4)
		-- (1.26.9d) o.stretch: longer streaks (the radial ring round hits near the floor)
		P.Spawn({ pos = o.pos + h * U.RandRange(0, o.radius or 1.5) + up * 0.6, vel = d * speed, r = r, owner = o.owner,
			oxy = o.oxy, btype = o.btype, spin = U.RandRange(-30, 30), stretch = (o.stretch or 1) * U.RandRange(0.85, 1.3),
			ownerGrace = o.ownerGrace or 0.15 })
	end
	return n
end

function P.Drips(pos, vel, volume, owner, oxy, btype)
	local remaining = math.min(volume, 1500)
	local guard = 0
	while remaining > 2 and guard < 12 do
		guard = guard + 1
		local v = math.min(remaining, G.Forensic and G.Forensic.Volume(G.Forensic.Diameter("drip")) or U.RandRange(28, 60))
		remaining = remaining - v
		P.Spawn({ pos = pos + VectorRand() * 0.3, vel = vel + VectorRand() * 3, r = radiusFromVol(v), owner = owner,
			oxy = oxy, btype = btype, stretch = 1.6, spin = 0, ownerGrace = 0.12 })
	end
end

P.hang = P.hang or {}
local HANG_MAX = 64
local HANG_R = 1.6
local STREAM_RATE = 600

local function nearestBone(ent, pos)
	if not IsValid(ent) or not ent.GetBoneCount then return nil end
	local best, bd
	for b = 0, math.min(ent:GetBoneCount() - 1, 63) do
		local m = ent:GetBoneMatrix(b)
		if m then
			local d = m:GetTranslation():DistToSqr(pos)
			if not bd or d < bd then best, bd = b, d end
		end
	end
	return best
end

local function siteWorld(s)
	if s.ent then
		if IsValid(s.ent) and not s.ent:IsRagdoll() and G.Render and G.Render.ragOf then
			local rag = G.Render.ragOf[s.ent]
			if IsValid(rag) then s.ent, s.lastW, s.lastV = rag, nil, nil end
		end
		if not IsValid(s.ent) then return nil end
		local m = s.bone and s.ent:GetBoneMatrix(s.bone)
		if m then return LocalToWorld(s.lpos, angle_zero, m:GetTranslation(), m:GetAngles()) end
		return s.ent:LocalToWorld(s.lpos)
	end
	return s.pos
end

function P.Transfer(from, to)
	if not from or not IsValid(to) then return end
	for _, s in ipairs(P.hang) do
		if s.ent == from then
			s.ent = to
			s.lastW, s.lastV = nil, nil
		end
	end
end

function P.Hang(pos, vel, volume, ent, oxy, btype)
	if volume <= 0 then return end
	if G.Water and bit.band(util.PointContents(pos), WATERMASK) ~= 0 then
		G.Water.Enter(pos, vel or vector_origin, volume, btype, oxy)
		return
	end
	if not G.cv.hang:GetBool() then return P.Drips(pos, vel, volume, ent, oxy, btype) end
	if IsValid(ent) and ent:IsWorld() then ent = nil end
	local now = CurTime()
	local site
	for _, s in ipairs(P.hang) do
		if s.ent == ent then
			local w = siteWorld(s)
			if w and w:DistToSqr(pos) < HANG_R * HANG_R then site = s break end
		end
	end
	if not site then
		if #P.hang >= HANG_MAX then return P.Drips(pos, vel, volume, ent, oxy, btype) end
		local Fo = G.Forensic
		site = { vol = 0, t0 = now, lastIn = now, rate = 0, oxy = oxy or 0.75, btype = btype or 0,
			vcrit = (Fo and Fo.Volume(Fo.Diameter("drip")) or 52) * (ent and 1 or U.RandRange(0.8, 1.35)), phase = math.random() * 6.28 }
		if ent then
			site.ent = ent
			site.bone = nearestBone(ent, pos)
			local m = site.bone and ent:GetBoneMatrix(site.bone)
			if m then site.lpos = WorldToLocal(pos, angle_zero, m:GetTranslation(), m:GetAngles())
			else site.lpos = ent:WorldToLocal(pos) end
		else
			site.pos = Vector(pos)
		end
		P.hang[#P.hang + 1] = site
	end
	local dt = math.max(now - site.lastIn, 0.02)
	site.rate = site.rate + (volume / dt - site.rate) * math.min(dt / 0.5, 1)
	site.lastIn = now
	site.oxy, site.btype = oxy or site.oxy, btype or site.btype
	if site.rate > STREAM_RATE and site.vol + volume > site.vcrit * 0.6 then
		local pass = site.vol + volume - site.vcrit * 0.6
		site.vol = site.vcrit * 0.6
		local w = siteWorld(site) or pos
		P.Drips(w - Vector(0, 0, 0.4), vel, pass, ent, site.oxy, site.btype)
	else
		site.vol = site.vol + volume
	end
end

local UP = Vector(0, 0, 1)
function P.UpdateHang(dt)
	local now = CurTime()
	local i = 1
	while i <= #P.hang do
		local s = P.hang[i]
		local w = siteWorld(s)
		local dead = not w or s.vol < 0.5 or now - s.lastIn > 45
		if not dead then
			local v = s.lastW and (w - s.lastW) / math.max(dt, 1e-3) or vector_origin
			local acc = s.lastV and (v - s.lastV):Length() / math.max(dt, 1e-3) or 0
			s.lastW, s.lastV = w, v
			s.world = w
			local shake = acc > 1500 and s.vol > s.vcrit * 0.35
			if s.vol >= s.vcrit or shake then
				local fall = s.vol * (shake and 0.85 or 0.9)
				local r = (fall / 4.18879) ^ (1 / 3)
				if G.VAT and G.VAT.OnDrip then G.VAT.OnDrip(w, v, r, s.btype, s.ent, s.bone) end
				P.Spawn({ pos = w - UP * (r * G.MM_TO_UNITS * 1.4), vel = v * 0.8 - UP * 8, r = r, owner = s.ent, oxy = s.oxy,
					btype = s.btype, stretch = 1.7, spin = 0, ownerGrace = 0.2 })
				s.vol = s.vol - fall
				s.drops = (s.drops or 0) + 1
			end
			if now - s.lastIn > 25 then s.vol = s.vol * math.exp(-dt / 8) end
			i = i + 1
		else
			table.remove(P.hang, i)
		end
	end
end

function P.HangCount() return #P.hang end

local emitter
function P.Mist(pos, dir, amount, btype)
	local d2 = pos:DistToSqr(EyePos())
	if d2 > 2500 * 2500 or (d2 > 250 * 250 and not G.U.InViewPos(pos, 64)) then return end
	if G.VAT and G.VAT.On and G.VAT.On() then
		G.VAT.OnSpray(pos, dir, amount, btype)
		local n3d = math.Clamp(math.floor(2 + amount * 3), 2, 10)
		for _ = 1, n3d do
			local md = U.ConeDir(dir, 0.58)
			P.Spawn({ pos = pos + md * U.RandRange(0.2, 1.2), vel = md * U.RandRange(35, 130) * math.Clamp(amount, 0.5, 2),
				r = U.RandRange(0.18, 0.38), oxy = 0.8, btype = btype or 0, stretch = U.RandRange(1.1, 1.6), spin = U.RandRange(-35, 35) })
		end
		if G.VAT.Ready and G.VAT.Ready("spray01") then return end
	end
	if not emitter or not emitter:IsValid() then emitter = ParticleEmitter(pos, false) end
	if not emitter then return end
	emitter:SetPos(pos)
	-- (1.26.10c) the colour the shaders give this blood, of a fine spray (0.5 mm), lit by the game like the bursts
	local cr, cg, cb
	if U.FluidColour255 and U.ShaderColours() then cr, cg, cb = U.FluidColour255(btype or 0, 0.8, 0.5, 1.4)
	else cr, cg, cb = U.BloodColour(btype or 0, 0.75, 110) end
	for i = 1, math.floor(3 + amount * 5) do
		local pt = emitter:Add("particle/particle_smokegrenade", pos + VectorRand() * 1.5)
		if pt then
			pt:SetVelocity(U.ConeDir(dir, 0.6) * U.RandRange(20, 90) * amount)
			pt:SetDieTime(U.RandRange(0.35, 0.9))
			pt:SetStartAlpha(math.Clamp(60 * amount, 20, 140))
			pt:SetEndAlpha(0)
			pt:SetStartSize(U.RandRange(1, 3))
			pt:SetEndSize(U.RandRange(6, 16) * math.min(amount, 2))
			pt:SetColor(cr, cg, cb)
			pt:SetLighting(true)
			pt:SetAirResistance(120)
			pt:SetGravity(Vector(0, 0, -40))
			pt:SetRoll(math.Rand(0, 360))
			pt:SetRollDelta(math.Rand(-1, 1))
		end
	end
end

local function spreadRadiusU(rmm, speedN)
	local v = speedN * 0.01905
	local D = 2 * rmm / 1000
	local We = 1060 * v * v * D / SIGMA
	local xi = math.Clamp(1.0 + 0.48 * We ^ 0.25, 1.25, 6.5)
	return (rmm * xi) * G.MM_TO_UNITS
end

local function SurfaceOf(tr, ent)
	if IsValid(ent) and not ent:IsWorld() and not G.Surfaces.IsGround(ent) and G.BloodTypeOf(ent) ~= nil then return G.Surface.skin end
	return G.Surface[G.SurfaceKindOf(tr)] or G.Surface.sealed
end
P.SurfaceOf = SurfaceOf

local childBudget = 0

local pending = {}
local function Child(o)
	if childBudget <= 0 or P.Count() + #pending >= G.cv.maxdrops:GetInt() * 0.92 then return end
	childBudget = childBudget - 1
	pending[#pending + 1] = o
end
local function FlushChildren()
	for k = 1, #pending do P.Spawn(pending[k]) pending[k] = nil end
end

-- (1.26.8) landings a frame: past a number of them (a magazine dump: hundreds) a landing drop leaves its main stain
-- only - no tail, satellites, splash ring or bounced drops (up to 12 impacts and children a landing before)
local landF, landN = -1, 0
local function LandingExtras()
	local f = FrameNumber()
	if f ~= landF then landF, landN = f, 0 end
	landN = landN + 1
	local detail = G.Gov and G.Gov.Detail and G.Gov.Detail() or 1
	return landN <= 12 + 48 * detail
end
P.LandingExtras = LandingExtras
-- (1.26.8, third pass) a landing in plain numbers, Vectors made only for what is handed on (the stains' position and
-- velocity, the children): ghmpb_prof with Lite, a drop landing 0.27 ms besides its stains - about 60 Vector objects
-- and as many engine calls a landing with its tail, satellites and splash ring
local sin, cos, sqrt, abs, max, min, floor = math.sin, math.cos, math.sqrt, math.abs, math.max, math.min, math.floor
local RR = U.RandRange
local function Land(p, tr, extras)
	local ent = tr.Entity
	local entOk = IsValid(ent)
	local world = tr.HitWorld or not entOk or ent:IsWorld() or G.Surfaces.IsGround(ent)
	G.DiagCount(world and "drops: landed on the world / ground" or "drops: landed on an entity")
	local vx, vy, vz
	if p.vx and not p.vel then vx, vy, vz = p.vx, p.vy, p.vz else vx, vy, vz = p.vel:Unpack() end
	local velMoved = false
	if not world then
		local ex, ey, ez = ent:GetVelocity():Unpack()
		if ex * ex + ey * ey + ez * ez > 4 then vx, vy, vz = vx - ex, vy - ey, vz - ez velMoved = true end
	end
	local n = tr.HitNormal
	local nx, ny, nz = n:Unpack()
	local hp = tr.HitPos
	local hx, hy, hz = hp:Unpack()
	local speed = sqrt(vx * vx + vy * vy + vz * vz)
	local vn = vx * nx + vy * ny + vz * nz
	local avn = abs(vn)
	local sinA = speed > 1e-3 and avn / speed or 1
	local tx, ty, tz = vx - nx * vn, vy - ny * vn, vz - nz * vn
	local vts = sqrt(tx * tx + ty * ty + tz * tz)
	local dx, dy, dz = 0, 0, 0       -- the direction along the surface
	if vts > 1e-6 then dx, dy, dz = tx / vts, ty / vts, tz / vts end
	local surf
	if not world and G.BloodTypeOf(ent) ~= nil then surf = G.Surface.skin
	else surf = G.Surface[G.SurfaceKindOf(tr)] or G.Surface.sealed end
	local fabric = surf.fabric or 0
	local volume = p.v
	local stretch = p.stretch or 1
	local flags = p.flags or 0
	local skips = bit.band(bit.rshift(flags, 1), 3)
	local Fo = G.Forensic
	local bounce = G.cv.bounce:GetBool()
	local rr = p.r
	local MMU = G.MM_TO_UNITS

	if extras and bounce and world and sinA < 0.34 and vts > 170 and rr > 0.22 and skips < 2 and fabric < 0.8 then
		local f = math.Clamp((0.34 - sinA) / 0.28, 0, 1) * 0.65 * (1 - fabric)
		if f > 0.08 then
			local cv = volume * f
			volume = volume - cv
			stretch = stretch * (1 + 1.4 * f * math.Clamp((rr - 0.25) / 0.6, 0, 1))
			local off = rr * MMU * 3
			local kt, kn = RR(0.5, 0.72), avn * RR(0.12, 0.3)
			Child({ pos = Vector(hx + nx * 0.3 + dx * off, hy + ny * 0.3 + dy * off, hz + nz * 0.3 + dz * off),
				vel = Vector(tx * kt + nx * kn, ty * kt + ny * kn, tz * kt + nz * kn),
				r = radiusFromVol(cv), oxy = p.oxy, btype = p.btype, spin = (p.spin or 0) * 0.5, stretch = 1.4 + f,
				broke = true, ownerGrace = 0, flags = bit.bor(bit.band(flags, 1), bit.lshift(skips + 1, 1)) })
		end
	end

	local R, extra
	if Fo then
		local spines, K
		if Fo.StainVn then R, spines, K = Fo.StainVn(rr, avn) else R, spines, K = Fo.Stain(rr, Vector(vx, vy, vz), n) end
		extra = { spines = spines, K = K, flags = bit.band(flags, 1) }
		local Kc = 140 + (45 - 140) * math.Clamp(surf.rough or 0.4, 0, 1)
		if extras and bounce and K > Kc * 1.3 and rr > 0.55 and speed > 200 and fabric < 0.7 then
			local nsec = min(1 + floor((K / Kc - 1.3) * 2), 5)
			local sv = volume * min(0.035 * nsec, 0.16)
			volume = volume - sv
			local ax, ay, az = dx, dy, dz
			if vts <= 1 then
				-- a random direction along the surface
				local rx, ry, rz = math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1
				ax, ay, az = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
				local l = sqrt(ax * ax + ay * ay + az * az)
				if l < 1e-6 then ax, ay, az, l = (abs(nz) < 0.9 and ny or 0), (abs(nz) < 0.9 and -nx or nz), (abs(nz) < 0.9 and 0 or -ny), 1 end
				ax, ay, az = ax / l, ay / l, az / l
			end
			local sx, sy, sz = ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax
			local oblique = math.Clamp((1 / max(sinA, 0.15) - 1) * 0.8, 0, 1)
			local rad = R * 0.6
			for _ = 1, nsec do
				local a = RR(0, 2 * math.pi)
				local sa, ca = sin(a), cos(a)
				local ux, uy, uz = sx * sa + ax * ca, sy * sa + ay * ca, sz * sa + az * ca
				local ku, kd, kn = RR(0.6, 1.0), 0.4 + 1.2 * oblique, RR(0.3, 0.8)
				local ex, ey, ez = ux * ku + ax * kd + nx * kn, uy * ku + ay * kd + ny * kn, uz * ku + az * kd + nz * kn
				local el = sqrt(ex * ex + ey * ey + ez * ez)
				local ks = speed * RR(0.15, 0.35) / max(el, 1e-6)
				Child({ pos = Vector(hx + nx * 0.25 + ux * rad, hy + ny * 0.25 + uy * rad, hz + nz * 0.25 + uz * rad),
					vel = Vector(ex * ks, ey * ks, ez * ks),
					r = radiusFromVol(sv / nsec), oxy = p.oxy, btype = p.btype, spin = RR(-40, 40), stretch = 1.5,
					broke = true, ownerGrace = 0, flags = bit.bor(bit.band(flags, 1), bit.lshift(2, 1)) })
			end
		end
	else
		R = spreadRadiusU(rr, max(avn, 20))
	end
	-- the velocity handed on with the stain (the drop's own Vector when it was not changed)
	local vel = (not velMoved and p.vel) or Vector(vx, vy, vz)
	local slideAmt = world and G.cv.slide and G.cv.slide:GetFloat() or 0
	-- (1.26.10h) GHM: "what are these ugly textures, replace them" - big flying drops hitting a WALL left lobed blobs, a
	-- ring of satellites and a slider that skidded on along the wall and curved down under gravity (the long arcs). With
	-- the forensic spatter on (ghmpb_forensic_spatter): a big drop lays one of the forensic spatter sets (D angled
	-- impact at a glancing hit, C medium-velocity otherwise) or, when their budget is used up, a small drop; no sliders
	-- on walls. Floors are unchanged (pools, runs).
	if world and Fo and Fo.ForensicOn and abs(nz) < 0.7 and Fo.ForensicOn() then
		slideAmt = 0
		if R and R >= 0.4 then
			if extras and speed > 60 then
				local dir = speed > 1e-3 and Vector(vx / speed, vy / speed, vz / speed) or -n
				if Fo.Forensic(sinA < 0.6 and "D" or "C", hp, n, dir, R, p.btype, p.oxy, tr, min(speed / 300, 1.6)) then
					if G.VAT and rr then G.VAT.OnDropLand(hp, n, rr, speed, p.btype) end
					return
				end
			end
			R, volume, extra = Fo.ForensicSmall(R, volume, extra)
		end
	end
	local slider
	if slideAmt > 0 and vts > 140 and sinA < 0.94 and fabric < 0.6 and not surf.nostain then
		local f = math.Clamp((vts - 140) / 520, 0, 1) * math.Clamp((rr - 0.3) / 0.5, 0, 1)
		stretch = stretch * (1 + min(0.45 * min(slideAmt, 1) * f * (1 - sinA * sinA), 0.5))
		local long = slideAmt >= 1.5
		if G.Runs and G.Runs.Slide and volume > 2.5 and rr > 0.75 and (long or vts > 260) then
			local sv = volume * (long and min(0.45, (0.12 + 0.3 * f) * slideAmt) or min(0.25, (0.08 + 0.15 * f) * slideAmt))
			if sv >= 0.6 then
				local sv2, st2 = U.SplatShape(vel, n, stretch)
				local sin2 = abs(sv2:Dot(n)) / max(sv2:Length(), 1e-3)
				local e = min(math.Clamp(1 / max(sin2, 0.12), 1, 8) * math.Clamp(st2, 1, 8), 10)
				local k = R * e * 1.15
				slider = { pos = Vector(hx + dx * k + nx * 0.02, hy + dy * k + ny * 0.02, hz + dz * k + nz * 0.02), dir = Vector(dx, dy, dz),
					speed = long and min(vts * 0.12 * slideAmt, 70) or min(vts * 0.045 * slideAmt, 22), vol = sv }
				volume = volume - sv
			end
		end
	end
	extra = extra or {}
	extra.btype = p.btype
	extra.oxy = p.oxy
	local SI = G.Surfaces.Impact
	if entOk and not world then
		if ent:GetClass() == "gmod_hands" or ent:IsWeapon() then return end
		local bone = tr.HitBone
		if not bone and tr.HitBox and tr.HitBox > 0 and ent.GetHitBoxBone then bone = ent:GetHitBoxBone(tr.HitBox, ent:GetHitboxSet() or 0) end
		if G.Entities.Impact(ent, hp, n, vel, R, volume, 0, p.spin, stretch, 0.18, bone, extra) then
			if G.Wounds and G.Wounds.OnForeignBlood then G.Wounds.OnForeignBlood(ent, p, tr) end
			return
		end
	end
	if world then
		if SI(hp, n, vel, R, volume, 0, p.spin, stretch, 0.22, tr, p.oxy, p.btype, extra) then
			if G.VAT and rr then G.VAT.OnDropLand(hp, n, rr, speed, p.btype) end
			if extras and sinA < 0.72 and vts > 95 and rr > 0.32 and fabric < 0.7 and not surf.nostain then
				local sx, sy, sz = ny * dz - nz * dy, nz * dx - nx * dz, nx * dy - ny * dx
				local elong = math.Clamp(1 / max(sinA, 0.14), 1.25, 4.2)
				local nTail = min(floor(elong), 3)
				local tv = vts * 0.65
				for seg = 1, nTail do
					local k = R * elong * (seg / (nTail + 0.5)) * 0.88
					local tR = max(R * (0.72 - 0.17 * seg), 0.08)
					SI(Vector(hx + dx * k, hy + dy * k, hz + dz * k), n, Vector(dx * tv, dy * tv, dz * tv), tR, volume * 0.11 / nTail, 0, 0, 1.6 + 0.35 * seg, 0.2, tr, p.oxy, p.btype, extra)
				end
				if elong > 1.65 and speed > 145 then
					local nSat = elong > 2.4 and 2 or 1
					local sv = vts * 0.45
					for _ = 1, nSat do
						local k, ks = R * elong * RR(1.25, 2.05), RR(-R * 0.28, R * 0.28)
						SI(Vector(hx + dx * k + sx * ks, hy + dy * k + sy * ks, hz + dz * k + sz * ks), n, Vector(dx * sv, dy * sv, dz * sv),
							max(R * RR(0.22, 0.38), 0.06), volume * 0.04, 0, 0, RR(1.4, 2.2), 0.22, tr, p.oxy, p.btype)
					end
				end
			end
			-- (1.26.6) the ring of satellite stains round a landing drop (the 1.26.4 rule again: the stricter one left no
			-- splash at all); follows the Splashes setting
			local splashAmt = G.cv.splash and G.cv.splash:GetFloat() or 1
			if extras and splashAmt > 0 and speed > 230 / min(sqrt(splashAmt), 1.4) and rr > 0.65 and not surf.nostain
				and math.random() < min(splashAmt, 1) then
				local ax, ay, az = dx, dy, dz
				if vts <= 1 then
					-- n x (0.31, 0.57, 0.76), normalised
					ax, ay, az = ny * 0.76 - nz * 0.57, nz * 0.31 - nx * 0.76, nx * 0.57 - ny * 0.31
					local l = max(sqrt(ax * ax + ay * ay + az * az), 1e-6)
					ax, ay, az = ax / l, ay / l, az / l
				end
				local bx, by, bz = ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax
				local nHalo = min(((speed > 380 and rr > 1.0) and 3 or 2) + floor(max(splashAmt - 1, 0) * 1.5 + math.random() * 0.5), 6)
				for _ = 1, nHalo do
					local ha = RR(0, 2 * math.pi)
					local ca, sa = cos(ha), sin(ha)
					local ux, uy, uz = ax * ca + bx * sa, ay * ca + by * sa, az * ca + bz * sa
					local k = R * RR(1.35, 2.25)
					SI(Vector(hx + ux * k, hy + uy * k, hz + uz * k), n, Vector(ux * 45, uy * 45, uz * 45), max(R * RR(0.18, 0.34), 0.05), volume * 0.025, 6, 0, 1.2, 0.28, tr, p.oxy, p.btype)
				end
			end
			if slider and not G.Runs.Slide(tr, n, slider.pos, slider.dir, slider.speed, slider.vol, p.oxy, p.btype) then
				SI(slider.pos, n, Vector(vx * 0.3, vy * 0.3, vz * 0.3), R * 0.5, slider.vol, 0, 0, 1.5, 0.22, tr, p.oxy, p.btype)
			end
			return
		end
	end
	if entOk then G.Entities.Impact(ent, hp, n, vel, R, volume, 0, p.spin, stretch, 0.18, nil, extra) end
end

-- (1.26.8) no time budget for the landings any more: when blood first hit fresh walls and floors, making their patches
-- took the frame's budget and the small drops after it landed without a stain (GHM: "on the workshop version the blood
-- initially doesnt spawn, it is sometimes or not at all"). A landing costs about 0.05 ms now (V.Installed, numbers)
P.landStats = P.landStats or { skipped = 0 }
function P.Land(p, tr)
	Land(p, tr, LandingExtras())
end

P.far = P.far or {}
P.landing = P.landing or {}
P.farStats = P.farStats or { spawned = 0, landed = 0, lost = 0, traces = 0 }
local FAR_MAX = 4000
local FAR_TRACES = 640
local FAR_DT = 1 / 60
local farFilter = {}
-- (1.26.8) the other form of a drop's body for its grace time: the ragdoll an NPC turned into (or nothing)
local function Partner(owner)
	local R = G.Render
	local r = R and R.ragOf and R.ragOf[owner]
	if r ~= owner and IsValid(r) then return r end
	return nil
end
local passTr = { Hit = false }
local farTrace = { mask = MASK_SHOT, filter = farFilter }

function P.FarOK(pos)
	local eye = EyePos()
	local d2 = pos:DistToSqr(eye)
	local b = G.Battle and G.Battle.level or 0
	local far = 2500 - 900 * b
	if d2 > far * far then return true end
	if b > 0.35 and d2 > 950 * 950 and not G.U.InViewPos(pos, 48) then return true end
	return false
end

function P.SpawnFar(o)
	if #P.far + #P.landing >= FAR_MAX then P.farStats.lost = P.farStats.lost + 1 return end
	P.far[#P.far + 1] = { o = o, t0 = CurTime(), pos = Vector(o.pos), vel = Vector(o.vel) }
	P.farStats.spawned = P.farStats.spawned + 1
end

local function CopyTrace(tr)
	return { Hit = true, HitPos = Vector(tr.HitPos), HitNormal = Vector(tr.HitNormal), Entity = tr.Entity, HitWorld = tr.HitWorld,
		HitSky = tr.HitSky, StartSolid = tr.StartSolid, HitTexture = tr.HitTexture, SurfaceProps = tr.SurfaceProps,
		MatType = tr.MatType, HitBone = tr.HitBone, HitBox = tr.HitBox, PhysicsBone = tr.PhysicsBone, Fraction = tr.Fraction,
		HitGroup = tr.HitGroup }
end

local function FarPath(f)
	local o = f.o
	local r = o.r or 1
	local dM = 2 * r / 1000
	local kb = 3 * RHO_AIR_OVER_BLOOD / (8 * r * G.MM_TO_UNITS)
	local g = -(GetConVarNumber("sv_gravity") or 600)
	local x, y, z = f.pos:Unpack()
	local vx, vy, vz = f.vel:Unpack()
	local t, life = 0, math.min(o.life or 6, 4)
	local grace = o.ownerGrace or 0.06
	local owner = IsValid(o.owner) and o.owner or nil
	local a, b = Vector(), Vector()
	local traces = 0
	while t < life do
		local ax, ay, az, at = x, y, z, t
		local avx, avy, avz = vx, vy, vz
		for _ = 1, 8 do
			local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
			local k = math.exp(-kb * DragCd(sp * 0.01905, dM) * sp * FAR_DT)
			vx, vy, vz = vx * k, vy * k, vz * k + g * FAR_DT
			x, y, z = x + vx * FAR_DT, y + vy * FAR_DT, z + vz * FAR_DT
			t = t + FAR_DT
		end
		a:SetUnpacked(ax, ay, az)
		b:SetUnpacked(x, y, z)
		farFilter[1] = (at < grace) and owner or nil
		farFilter[2] = (at < grace) and owner and Partner(owner) or nil
		farTrace.start, farTrace.endpos = a, b
		local tr = util.TraceLine(farTrace)
		traces = traces + 1
		-- (1.26.8) starting inside a body that is not the world (the ragdoll an NPC just turned into): pass through
		if tr.StartSolid and not tr.HitWorld and IsValid(tr.Entity) and at < 0.25 then tr = { Hit = false } end
		local ct = G.U.TraceCorpses(a, tr.Hit and tr.HitPos or b, (at < grace) and owner or nil)
		if ct then tr = ct end
		if tr.Hit then
			if tr.HitSky or tr.StartSolid then return traces end
			local fr = tr.Fraction or 1
			local hvx, hvy, hvz = avx + (vx - avx) * fr, avy + (vy - avy) * fr, avz + (vz - avz) * fr
			local shim = { vel = Vector(hvx, hvy, hvz), r = r, v = 4.18879 * r * r * r, spin = o.spin or 0, stretch = o.stretch or 1,
				oxy = o.oxy or 0.75, btype = o.btype or 0, owner = owner, flags = o.flags or 0 }
			P.landing[#P.landing + 1] = { t = f.t0 + at + (t - at) * fr, shim = shim, tr = CopyTrace(tr) }
			return traces
		end
		if bit.band(util.PointContents(b), WATERMASK) ~= 0 then
			if G.Water then
				local vol = 4.18879 * r * r * r
				P.landing[#P.landing + 1] = { t = f.t0 + t, water = { Vector(a), Vector(b), Vector(vx, vy, vz), vol, o.btype, o.oxy, r } }
			end
			return traces
		end
	end
	return traces
end

function P.UpdateFar()
	local now = CurTime()
	local used = 0
	while #P.far > 0 and used < FAR_TRACES do
		local f = table.remove(P.far)
		used = used + FarPath(f)
	end
	P.farStats.traces = P.farStats.traces + used
	local i = 1
	while i <= #P.landing do
		local l = P.landing[i]
		if l.t <= now then
			P.landing[i] = P.landing[#P.landing]
			P.landing[#P.landing] = nil
			if l.water then
				local w = l.water
				G.Water.EnterDrop(w[1], w[2], w[3], w[4], w[5], w[6], w[7])
			elseif not IsValid(l.tr.Entity) and not l.tr.HitWorld then
			else
				P.Land(l.shim, l.tr)
			end
			P.farStats.landed = P.farStats.landed + 1
		else
			i = i + 1
		end
	end
end

function P.FarCount() return #P.far + #P.landing end

local traceData = { mask = MASK_SHOT, output = {} }
local flt = {}
traceData.filter = flt
local nBase = 0
local function BaseFilter()
	for k = #flt, 1, -1 do flt[k] = nil end
	nBase = 0
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local function add(e) if IsValid(e) then nBase = nBase + 1 flt[nBase] = e end end
	if not lp:ShouldDrawLocalPlayer() then add(lp) end
	add(lp:GetActiveWeapon())
	add(lp:GetViewModel())
	if lp.GetHands then add(lp:GetHands()) end
end

function P.Step(dt)
	if dt <= 0 then return end
	P.rate = P.rate + (spawnsNow / dt - P.rate) * math.min(dt, 1)
	spawnsNow = 0
	childBudget = math.floor(48 / P.Thin())
	if #P.hang > 0 then P.UpdateHang(dt) end
	if #P.far > 0 or #P.landing > 0 then P.UpdateFar() end
	if G.Native and G.Native.Available() and G.cv.native:GetBool() then
		G.Native.Step(dt)
		FlushChildren()
		UpdateThinK(dt)
		return
	end
	P.thinK = 1
	local gz = -(GetConVarNumber("sv_gravity") or 600) * dt
	local MM = G.MM_TO_UNITS
	local exp, sqrt = math.exp, math.sqrt
	local stretchK, spinK = exp(-dt / 0.09), exp(-dt * 0.8)
	BaseFilter()
	local n = #list
	-- (1.26.8) the traces: a share of the drops each frame, in turn (the window moves on every frame, so every drop is
	-- traced at least every few frames - 1.26.7 traced the first 900 in the list and the newest drops of a magazine dump
	-- went untraced, flew on and landed late), as many as fit into the trace time (about 2 ms, less with less detail:
	-- cl_governor.lua V.Detail); a drop's trace covers its path since its last one
	local want = math.max(1, math.floor(traceWant + 0.5))
	local B = math.min(n, want)
	local start = n > 0 and (traceRot % n) or 0
	traceRot = traceRot + B
	local tTr, nTr, nTimed = 0, 0, 0
	local i = 1
	local newDrops = {}
	while i <= n do
		local p = list[i]
		local age = p.age + dt
		p.age = age
		local dead = age > p.life
		if not dead then
			local vx, vy, vz = p.vx, p.vy, p.vz
			local r = p.r
			local sp = sqrt(vx * vx + vy * vy + vz * vz)
			local cd = DragCd(sp * 0.01905, 2 * r / 1000)
			local k = exp(-(3 * RHO_AIR_OVER_BLOOD * cd / (8 * r * MM)) * sp * dt)
			vx, vy, vz = vx * k, vy * k, vz * k + gz
			p.vx, p.vy, p.vz = vx, vy, vz
			p.x, p.y, p.z = p.x + vx * dt, p.y + vy * dt, p.z + vz * dt
			p.stretch = 1 + (p.stretch - 1) * stretchK
			p.spin = p.spin * spinK
			if not p.broke and r > 0.35 then
				local vm = sp * 0.01905
				local We = 1.2 * vm * vm * (2 * r / 1000) / SIGMA
				if We > 12 then
					p.broke = true
					local parts = We > 40 and math.random(4, 6) or math.random(2, 3)
					local left = p.v
					for c = 1, parts - 1 do
						local share = left * U.RandRange(0.25, 0.5)
						left = left - share
						local j = sp * 0.08
						newDrops[#newDrops + 1] = { pos = Vector(p.x, p.y, p.z),
							vel = Vector(vx + (math.random() * 2 - 1) * j, vy + (math.random() * 2 - 1) * j, vz + (math.random() * 2 - 1) * j),
							r = radiusFromVol(share), owner = p.owner, oxy = p.oxy, btype = p.btype, broke = true, stretch = 1.8,
							spin = p.spin + U.RandRange(-60, 60), ownerGrace = math.max(0, p.ownerGrace - age), flags = p.flags }
					end
					p.v = left
					p.r = radiusFromVol(left)
				end
			end
			-- in this frame's window?
			local w = i - 1 - start
			if w < 0 then w = w + n end
			if w < B then
				-- every eighth trace is timed (the cost of a trace, for the count next frame)
				local timed = nTr % 8 == 0
				local t0 = timed and SysTime()
				trA:SetUnpacked(p.tx, p.ty, p.tz)
				trB:SetUnpacked(p.x, p.y, p.z)
				traceData.start = trA
				traceData.endpos = trB
				local inGrace = age < p.ownerGrace and IsValid(p.owner)
				flt[nBase + 1] = inGrace and p.owner or nil
				flt[nBase + 2] = inGrace and Partner(p.owner) or nil
				local tr = util.TraceLine(traceData)
				-- (1.26.8) a drop thrown from inside a body that is not the world (the ragdoll an NPC just turned into,
				-- there before PhysBlood knows it is that NPC's): it passes through instead of vanishing
				if tr.StartSolid and not tr.HitWorld and IsValid(tr.Entity) and age < 0.25 then tr = passTr end
				local ct = U.TraceCorpses(trA, tr.Hit and tr.HitPos or trB, age < p.ownerGrace and p.owner or nil)
				if ct then tr = ct end
				-- the time of the traces alone (the landings have their own limits: LandingExtras)
				if timed then tTr, nTimed = tTr + (SysTime() - t0), nTimed + 1 end
				nTr = nTr + 1
				if tr.Hit then
					if not tr.HitSky and not tr.StartSolid then
						p.vel = Vector(vx, vy, vz)
						P.Land(p, tr)
					end
					dead = true
				else
					-- water: every fourth trace of a drop is enough to find it (it was every trace)
					p.wc = p.wc + 1
					if p.wc % 4 == 0 and bit.band(util.PointContents(trB), WATERMASK) ~= 0 then
						if G.Water then G.Water.EnterDrop(Vector(p.tx, p.ty, p.tz), Vector(trB), Vector(vx, vy, vz), p.v, p.btype, p.oxy, p.r) end
						dead = true
					else
						p.tx, p.ty, p.tz = p.x, p.y, p.z
					end
				end
			end
		end
		if dead then
			list[i] = list[n]
			list[n] = nil
			n = n - 1
		else
			i = i + 1
		end
	end
	-- the trace count for the next frame: what fits into the time
	if nTimed >= 4 then
		local per = tTr / nTimed
		traceCost = traceCost * 0.8 + per * 0.2
	end
	local detail = G.Gov and G.Gov.Detail and G.Gov.Detail() or 1
	local ms = (G.Gov and G.Gov.TraceMs and G.Gov.TraceMs() or 3) * (0.45 + 0.55 * detail) * 0.75
	traceWant = math.Clamp(ms / 1000 / math.max(traceCost, 1e-6), 150, TRACE_BUDGET)
	P.traceStats = P.traceStats or {}
	P.traceStats.traced, P.traceStats.want, P.traceStats.cost = nTr, traceWant, traceCost
	for _, o in ipairs(newDrops) do P.Spawn(o) end
	FlushChildren()
end

local dropMat, dropMat2, dropMatRun
local BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
local BK = {}   -- (1.26.6) true: a drop lying on a surface (rivulet heads): drawn with the light of that surface
local BD, B3, I3 = {}, {}, {}   -- (1.26.8) distance (squared) to the eye; true: drawn as a 3D mesh; the list of those
local RINGS = 32
local vpos = Vector()
local MAX_DRAW = 7000

function P.Draw()
	local nat = G.Native and G.Native.Available() and G.cv.native:GetBool()
	local count = nat and G.Native.Count() or #list
	local runs = G.Runs and G.Runs.Count() or 0
	if count == 0 and #P.hang == 0 and runs == 0 then return end
	local lite = G.Lite and G.Lite.on
	if not dropMat and not lite then
		dropMat = G.GPU.Mat("drops", "drop_vs30", "drop_ps30", {
			["$basetexture"] = "_rt_FullFrameFB", ["$linearread_basetexture"] = 1,
			["$texture1"] = "env_cubemap", ["$linearread_texture1"] = 1,
			["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$depthtest"] = 1, ["$linearwrite"] = 1 })
	end
	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	if not lite then
		local light = G.Light.Get("drops", G.Light.ViewProbePos and G.Light.ViewProbePos(eye, fwd, 100) or (eye + fwd * 100), 0.25)
		G.GPU.SetC(dropMat, 0, 1 / ScrW(), 1 / ScrH(), G.BloodHue(), G.BloodAbsorb())
		G.GPU.SetC(dropMat, 1, light.dir.x, light.dir.y, light.dir.z, 1)
		G.GPU.SetC(dropMat, 2, light.col.x, light.col.y, light.col.z, 1)
		G.GPU.SetC(dropMat, 3, light.amb.x, light.amb.y, light.amb.z, 0.6)
		-- (1.26.6) the player's own colours are for red blood: drops of other types get the plain hue and absorption
		if G.U and G.U.CustomColours and G.U.CustomColours() then
			if not dropMat2 then
				dropMat2 = G.GPU.Mat("drops2", "drop_vs30", "drop_ps30", {
					["$basetexture"] = "_rt_FullFrameFB", ["$linearread_basetexture"] = 1,
					["$texture1"] = "env_cubemap", ["$linearread_texture1"] = 1,
					["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$depthtest"] = 1, ["$linearwrite"] = 1 })
			end
			G.GPU.SetC(dropMat2, 0, 1 / ScrW(), 1 / ScrH(), G.BloodHueFor(1), G.BloodAbsorbFor(1))
			G.GPU.SetC(dropMat2, 1, light.dir.x, light.dir.y, light.dir.z, 1)
			G.GPU.SetC(dropMat2, 2, light.col.x, light.col.y, light.col.z, 1)
			G.GPU.SetC(dropMat2, 3, light.amb.x, light.amb.y, light.amb.z, 0.6)
		end
	end
	local splitTypes = not lite and dropMat2 ~= nil and G.U and G.U.CustomColours and G.U.CustomColours() ~= nil
	local ft = math.min(FrameTime(), 1 / 30)
	local trailK = G.cv.trail:GetFloat() * 0.5 * ft
	local ex, ey, ez = eye.x, eye.y, eye.z
	local fx, fy, fz = fwd.x, fwd.y, fwd.z
	local vs = render.GetViewSetup and render.GetViewSetup()
	local fov = vs and vs.fov or 75
	local pxK = ScrW() * 0.5 / math.tan(math.rad(math.Clamp(fov, 10, 170) * 0.5))
	local MM, maxD2 = G.MM_TO_UNITS, 3000 * 3000
	local n = 0
	-- (1.26.6) only drops inside the view are built into the mesh: the cone round the screen's diagonal, with a margin (wide
	-- enough whether the view's fov is the screen's width or that of a 4:3 picture)
	local asp = ScrH() / math.max(ScrW(), 1)
	local tH = math.tan(math.rad(math.Clamp(fov, 10, 170) * 0.5)) * math.max(1, 0.75 / asp)
	local cosV = math.cos(math.min(math.atan(tH * math.sqrt(1 + asp * asp)) + math.rad(6), math.rad(88)))
	-- drops gathered per batch: in the air / on a surface x red / other types
	local cAR, cAO, cSR, cSO = 0, 0, 0, 0
	local nat4 = G.Native.oxyInData or G.Native.MODULE == "ghmpb_native_v4"
	local function add(x, y, z, vx, vy, vz, rmm, st, bt, oq, onSurf)
		if n >= MAX_DRAW then return end
		st = st or 1
		if not oq then oq = math.floor(st / 1000) st = st - oq * 1000 if oq == 0 and not nat4 then oq = 7 end end
		if not bt then bt = math.floor(st / 100) st = st - bt * 100 end
		local dx, dy, dz = x - ex, y - ey, z - ez
		local along = dx * fx + dy * fy + dz * fz
		if along < -2 then return end
		local d2 = dx * dx + dy * dy + dz * dz
		if d2 > maxD2 then return end
		local ru = rmm * MM
		local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
		local ext = ru * (st or 1) + math.min(sp * trailK, ru * 12)
		if ext * pxK < 0.35 * math.max(along, 1) then return end
		if d2 > 400 and along + ext * 2 < math.sqrt(d2) * cosV then return end
		n = n + 1
		if onSurf == true then
			if (bt or 0) == 0 then cSR = cSR + 1 else cSO = cSO + 1 end
		elseif (bt or 0) == 0 then cAR = cAR + 1 else cAO = cAO + 1 end
		BX[n], BY[n], BZ[n], BVX[n], BVY[n], BVZ[n], BR[n], BS[n] = x, y, z, vx, vy, vz, rmm, st
		BT[n] = bt
		BO[n] = oq
		BK[n] = onSurf == true
		BD[n] = d2
		B3[n] = false
	end
	if nat then
		local d, dn = G.Native.RenderRaw()
		if d then for i = 1, dn or #d, 8 do add(d[i], d[i + 1], d[i + 2], d[i + 3], d[i + 4], d[i + 5], d[i + 6], d[i + 7]) end end
	else
		for i = 1, #list do local p = list[i] add(p.x, p.y, p.z, p.vx, p.vy, p.vz, p.r, p.stretch, p.btype or 0, math.floor((p.oxy or 0.75) * 9 + 0.5)) end
	end
	local now = CurTime()
	for _, s in ipairs(P.hang) do
		if s.world and s.vol > 2 then
			local r = (s.vol / 4.18879) ^ (1 / 3)
			local f = math.Clamp(s.vol / s.vcrit, 0, 1)
			local st = 1 + 0.75 * f * f + (now - s.lastIn < 0.6 and 0.05 * math.sin(now * 23 + s.phase) or 0)
			local w = s.world
			add(w.x, w.y, w.z - r * MM * st * 0.95, 0, 0, -1, r, st, s.btype or 0, math.floor((s.oxy or 0.75) * 9 + 0.5))
		end
	end
	if runs > 0 then G.Runs.Draw(add) end
	if n == 0 then return end
	if lite then return G.Lite.DrawDrops(n, BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO, trailK) end
	-- (1.26.8) the nearest drops as 3D fluid meshes (a draw each: a budget that follows the quality setting, the frame
	-- rate and the size of the fight, within 900 u), every other drop in the shader's batch below. 1.26.7 drew up to 320
	-- drops as meshes every frame (spread over all of them, near or far) and left the rest out.
	local V3 = G.VAT
	if V3 and V3.DrawDrops3D and V3.Drops3DBudget and V3.DropsReady and V3.DropsReady() then
		local budget = V3.Drops3DBudget()
		local lim2 = (V3.Drops3DDist and V3.Drops3DDist() or V3.DROP3D_DIST or 900) ^ 2
		-- the nearest within the limit: count them in rings of distance, take whole rings while they fit, then the rest
		-- of the next ring up to the budget
		local cnt = {}
		for r = 0, RINGS do cnt[r] = 0 end
		local inside = 0
		for k = 1, n do
			local d2 = BD[k]
			if d2 < lim2 then
				local r = math.floor(math.sqrt(d2 / lim2) * RINGS)
				cnt[r] = cnt[r] + 1
				inside = inside + 1
			end
		end
		local cut, acc = -1, 0
		if inside <= budget then cut = RINGS
		else
			for r = 0, RINGS do
				if acc + cnt[r] > budget then break end
				acc = acc + cnt[r]
				cut = r
			end
		end
		local n3, extra = 0, budget - acc
		for k = 1, n do
			local d2 = BD[k]
			if d2 < lim2 then
				local r = math.floor(math.sqrt(d2 / lim2) * RINGS)
				local take = r <= cut
				if not take and r == cut + 1 and extra > 0 then take = true extra = extra - 1 end
				if take and n3 < budget then
					n3 = n3 + 1
					I3[n3] = k
					B3[k] = true
				end
			end
		end
		local function Uncount(k, sign)
			if BK[k] then
				if (BT[k] or 0) == 0 then cSR = cSR + sign else cSO = cSO + sign end
			elseif (BT[k] or 0) == 0 then cAR = cAR + sign else cAO = cAO + sign end
		end
		if n3 > 0 then
			for c = 1, n3 do Uncount(I3[c], -1) end
			if not V3.DrawDrops3D(n3, BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO, trailK, I3) then
				-- not drawn as meshes after all: back into the batch
				for c = 1, n3 do Uncount(I3[c], 1) B3[I3[c]] = false end
				n3 = 0
			end
		end
		P.drawn3d = n3
		if n3 >= n then P.drawn = n return end
	end
	-- (1.26.6) the rivulet heads with the light of the surface they lie on
	local runMat
	if runs > 0 and G.Runs.HeadLight then
		local rl = (cSR + cSO) > 0 and G.Runs.HeadLight(eye)
		if rl then
			if not dropMatRun then
				dropMatRun = G.GPU.Mat("dropsrun", "drop_vs30", "drop_ps30", {
					["$basetexture"] = "_rt_FullFrameFB", ["$linearread_basetexture"] = 1,
					["$texture1"] = "env_cubemap", ["$linearread_texture1"] = 1,
					["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$depthtest"] = 1, ["$linearwrite"] = 1 })
			end
			runMat = dropMatRun
			G.GPU.SetC(runMat, 0, 1 / ScrW(), 1 / ScrH(), G.BloodHueFor(rl.bt), G.BloodAbsorbFor(rl.bt))
			G.GPU.SetC(runMat, 1, rl.dir.x, rl.dir.y, rl.dir.z, 1)
			G.GPU.SetC(runMat, 2, rl.col.x, rl.col.y, rl.col.z, 1)
			G.GPU.SetC(runMat, 3, rl.amb.x, rl.amb.y, rl.amb.z, 0.6)
		end
	end
	-- want: nil = every drop, true = red drops only, false = drops of the other blood types only
	-- onSurf: nil = all, true = only drops lying on a surface, false = only the others
	local function Use(k, want, onSurf)
		if B3[k] then return false end
		if onSurf ~= nil and BK[k] ~= onSurf then return false end
		return want == nil or ((BT[k] or 0) == 0) == want
	end
	local function Cnt(want, onSurf)
		local c = 0
		if onSurf ~= true then c = c + (want ~= false and cAR or 0) + (want ~= true and cAO or 0) end
		if onSurf ~= false then c = c + (want ~= false and cSR or 0) + (want ~= true and cSO or 0) end
		return c
	end
	local function Batch(mat, want, onSurf)
		local cnt = Cnt(want, onSurf)
		if cnt == 0 then return true end
		render.SetMaterial(mat)
		mesh.Begin(MATERIAL_QUADS, cnt)
		local ok, err = pcall(function()
		local mPos, mTC, mAdv = mesh.Position, mesh.TexCoord, mesh.AdvanceVertex
		for k = 1, n do
			if Use(k, want, onSurf) then
			vpos:SetUnpacked(BX[k], BY[k], BZ[k])
			local vx, vy, vz, rmm, st = BVX[k], BVY[k], BVZ[k], BR[k], (BS[k] or 1) + 100 * (BT[k] or 0) + 1000 * (BO[k] or 7)
			local ru = math.max(rmm * MM, 0.035)
			local trail = math.min(math.sqrt(vx * vx + vy * vy + vz * vz) * trailK, ru * 12)
			mPos(vpos) mTC(0, -1, 1, ru, st) mTC(1, vx, vy, vz, trail) mAdv()
			mPos(vpos) mTC(0, 1, 1, ru, st) mTC(1, vx, vy, vz, trail) mAdv()
			mPos(vpos) mTC(0, 1, -1, ru, st) mTC(1, vx, vy, vz, trail) mAdv()
			mPos(vpos) mTC(0, -1, -1, ru, st) mTC(1, vx, vy, vz, trail) mAdv()
			end
		end
		end)
		mesh.End()
		if not ok then ErrorNoHalt("[GHMPB] drop draw: " .. tostring(err) .. "\n") end
		return ok
	end
	local air = nil
	if runMat then air = false end
	if splitTypes then
		Batch(dropMat, true, air)
		Batch(dropMat2, false, air)
	else
		Batch(dropMat, nil, air)
	end
	if runMat then Batch(runMat, nil, true) end
	P.drawn = n
end

function P.Clear()
	for i = #list, 1, -1 do list[i] = nil end
	P.far, P.landing = {}, {}
	for i = #P.hang, 1, -1 do P.hang[i] = nil end
	for k = #pending, 1, -1 do pending[k] = nil end
	if G.Native and G.Native.Available() then G.Native.Clear() end
end

local cntF, cntV = -1, 0
function P.Count()
	if G.Native and G.Native.Available() and G.cv.native:GetBool() then
		local f = FrameNumber()
		if f ~= cntF then cntF, cntV = f, G.Native.Count() end
		return cntV
	end
	return #list
end
function P.CountedSpawn() cntV = cntV + 1 end
