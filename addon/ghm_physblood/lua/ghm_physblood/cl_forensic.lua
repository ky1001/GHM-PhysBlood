local G = GHMPB
G.Forensic = G.Forensic or {}
local F = G.Forensic
local U = G.U

F.RHO, F.MU, F.SIGMA = 1060, 0.004, 0.058
F.RHO_AIR, F.MU_AIR = 1.2, 1.8e-5
F.UPM = 1 / 0.01905

F.SIZES = {
	gunshotBack  = { 0.55, 0.60, 0.12, 2.0 },   -- (1.26.6) a visible size (was 0.30 mm: below a pixel, invisible stains)
	gunshotFwd   = { 0.75, 0.65, 0.12, 3.0 },   -- (was 0.40 mm)
	chunk        = { 2.2, 0.25, 1.4, 3.4 },
	blunt        = { 1.8, 0.35, 0.9, 4.2 },
	castoff      = { 2.2, 0.30, 1.0, 4.5 },
	arterial     = { 3.8, 0.25, 1.5, 6.5 },
	arterialRain = { 0.9, 0.45, 0.2, 2.0 },
	expirated    = { 0.25, 0.70, 0.05, 1.2 },
	drip         = { 4.6, 0.12, 3.8, 6.2 },
	blast        = { 1.4, 0.7, 0.12, 5.0 },
	blastHeavy   = { 2.6, 0.35, 1.2, 5.0 },
	blastClump   = { 4.6, 0.25, 3.0, 7.0 },
}

local function gauss()
	local u1, u2 = math.max(math.random(), 1e-9), math.random()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end
F.Gauss = gauss

function F.Diameter(kind, mul)
	local s = F.SIZES[kind] or F.SIZES.blunt
	return math.Clamp(s[1] * math.exp(gauss() * s[2]), s[3], s[4]) * (mul or 1)
end

function F.Volume(dmm) return 0.5235988 * dmm * dmm * dmm end
function F.DiameterOf(vol) return (vol / 0.5235988) ^ (1 / 3) end
-- (1.26.6) the least blood a stamped stain of radius rU (u) gets: a wet film - 0.035 mm on small drops, up to 0.08 mm on
-- big blotches (e = how far the stamp draws it out). The stamped spatter (spatter patterns, exit plumes) took its volume
-- from F.Volume(2.2 rU): films of a few microns, which the shaders draw as a dried stain - fresh spatter looked dry the
-- moment it landed. (Big blotches on walls now also run, as they do.)
function F.WetVol(rU, e, vol)
	local emax = G.cv.streak and G.cv.streak:GetFloat() or 3.5
	local h = math.Clamp(0.03 + 0.03 * rU, 0.035, 0.08)
	local rmm = rU * 19.05
	return math.max(vol or 0, h * 2.0944 * rmm * rmm * math.Clamp(e or 1, 1, math.min(emax, 8)))
end

local function cvs()
	local cv = G.cv
	return cv.sSize:GetFloat(), cv.sSpeed:GetFloat(), cv.sSpread:GetFloat(), cv.spray:GetFloat()
end

local function Frame(dir)
	local side = dir:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 1e-4 then side = dir:Cross(Vector(1, 0, 0)) end
	side:Normalize()
	local up = side:Cross(dir) up:Normalize()
	return side, up
end
F.Frame = Frame

function F.ConeAsym(dir, upDeg, downDeg, sideDeg)
	local side, up = Frame(dir)
	local e = gauss() * 0.5
	e = (e >= 0 and e * upDeg or e * downDeg)
	e = math.Clamp(e, -downDeg, upDeg)
	local a = math.Clamp(gauss() * 0.45 * sideDeg, -sideDeg, sideDeg)
	local er, ar = math.rad(e), math.rad(a)
	local v = dir * (math.cos(er) * math.cos(ar)) + up * math.sin(er) + side * (math.cos(er) * math.sin(ar))
	v:Normalize()
	return v
end

F.oxy = F.oxy or 0.8
-- (1.26.8) hit spatter drops a second: a magazine dumped into a body threw ~900 drops a second (each one flown,
-- traced, landed and stained), and the blood came late and the frame slow. A budget of drops (about 420 a second on
-- Ultra in a quiet scene, less with less detail - cl_governor.lua V.Detail - with a reserve for the first hits): when it
-- runs low every hit throws fewer drops (down to a quarter), a little bigger so the blood is the same (at most 1.3x as
-- wide). Single shots are untouched; the splats, the mist and the wounds are not counted.
local spTok, spT = 300, 0
local function SpatterBudget(n)
	local now = CurTime()
	local detail = (G.Gov and G.Gov.Detail and G.Gov.Detail()) or 1
	-- (1.26.8) more generous: about 650 drops a second and a reserve of 480 at full detail (the frame rate holding)
	local rate, cap = 650 * (0.35 + 0.65 * detail), 480 * (0.5 + 0.5 * detail)
	spTok = math.min(cap, spTok + math.max(now - spT, 0) * rate)
	spT = now
	local k = math.Clamp(spTok / math.max(n, 1), 0.25, 1)
	local n2 = math.max(2, math.floor(n * k + 0.5))
	spTok = math.max(spTok - n2, -cap * 0.25)
	F.spatterStats = F.spatterStats or { asked = 0, thrown = 0 }
	F.spatterStats.asked, F.spatterStats.thrown = F.spatterStats.asked + n, F.spatterStats.thrown + n2
	return n2
end
F.SpatterBudget = SpatterBudget
local function Thin(n)
	if n <= 2 then return n, 1 end
	local n0 = n
	n = SpatterBudget(n)
	local t = G.Particles and (G.Particles.ThinPrio or G.Particles.Thin) and (G.Particles.ThinPrio or G.Particles.Thin)() or 1
	if t > 1.01 and n > 2 then n = math.max(2, math.floor(n / t + 0.5)) end
	if n >= n0 then return n0, 1 end
	return n, math.min((n0 / n) ^ (1 / 3), 1.3)
end
F.Thin = Thin
-- (1.26.6) zombies throw lumps of the host's own red blood with their necrotic blood: chunks, clumps and some of the
-- big drops are red
local function ChunkType(btype) return btype == G.BLOOD_ZOMBIE and G.BLOOD_RED or btype end
local function BigDropType(btype, dmm) return (btype == G.BLOOD_ZOMBIE and dmm > 0.9 and math.random() < 0.3) and G.BLOOD_RED or btype end
F.ChunkType = ChunkType
local function spawnDrop(pos, vel, dmm, owner, oxy, btype, grace, stretch, flags)
	G.Particles.Spawn({ pos = pos, vel = vel, r = dmm * 0.5, owner = owner, oxy = oxy, btype = btype,
		spin = U.RandRange(-40, 40), stretch = stretch or 1, ownerGrace = grace or 0.1, flags = flags, prio = true })
end

local emitter
local SETTLE = Vector(0, 0, -7)
local MIST_MATS = { "particle/particle_smokegrenade", "particle/smokesprites_0001", "particle/smokesprites_0003" }
function F.MistCloud(pos, dir, speedUps, cone, amount, btype, expirated, sizeMul)
	if not G.cv.mist:GetBool() or amount <= 0 then return end
	if G.VAT and G.VAT.On and G.VAT.On() and not G.VAT.mute then
		G.VAT.OnSpray(pos, dir, amount * (sizeMul or 1), btype)
		if G.VAT.Ready and G.VAT.Ready("spray01") then return end
	end
	if not emitter or not emitter:IsValid() then emitter = ParticleEmitter(pos, false) end
	if not emitter then return end
	emitter:SetPos(pos)
	-- (1.26.10c) the colour the shaders give this blood, of a fine mist (0.3 mm), lit by the game
	local cr, cg, cb
	if U.FluidColour255 and U.ShaderColours() then cr, cg, cb = U.FluidColour255(btype or 0, expirated and 0.95 or 0.8, 0.3, 1.4)
	else cr, cg, cb = U.BloodColour(btype or 0, expirated and 0.95 or 0.8, 172) end
	local w = expirated and 0.12 or 0.06
	local light = expirated and 1.35 or 1
	local r = math.min(255, (cr + (255 - cr) * w) * light)
	local g = math.min(255, (cg + (255 - cg) * w) * light)
	local b = math.min(255, (cb + (255 - cb) * w) * light)
	local n = math.Clamp(math.floor(6 + amount * 10), 5, 30)
	local sm = sizeMul or 1
	local aPeak = math.Clamp(28 + 22 * amount, 24, 64)
	local life = math.Clamp(amount, 0.7, 1.3)
	for i = 1, n do
		local d = U.ConeDir(dir, cone * U.RandRange(0.3, 1))
		local pt = emitter:Add(MIST_MATS[math.random(#MIST_MATS)], pos + VectorRand() * 0.4)
		if pt then
			local tau = U.RandRange(0.008, 0.035)
			local v0 = d * speedUps * U.RandRange(0.4, 1.0)
			local s0 = U.RandRange(1.2, 2.6) * sm
			local s1 = U.RandRange(5, 10) * sm
			local a0 = aPeak * U.RandRange(0.6, 1)
			local die = U.RandRange(0.7, 1.8) * life
			local born = CurTime()
			pt:SetVelocity(v0)
			pt:SetDieTime(die + 0.1)
			pt:SetStartAlpha(a0) pt:SetEndAlpha(a0)
			pt:SetStartSize(s0) pt:SetEndSize(s0)
			pt:SetColor(r, g, b)
			pt:SetLighting(true)
			pt:SetRoll(math.Rand(0, 360))
			pt:SetRollDelta(math.Rand(-0.8, 0.8))
			pt:SetCollide(true)
			pt:SetBounce(0)
			pt:SetAirResistance(0)
			pt:SetNextThink(CurTime())
			local drift = VectorRand() * 2.5
			pt:SetThinkFunction(function(p)
				local now = CurTime()
				local dt = FrameTime()
				local age = now - born
				local v = p:GetVelocity()
				local target = SETTLE + drift
				p:SetVelocity(target + (v - target) * math.exp(-dt / tau))
				tau = math.min(tau * (1 + dt * 6), 0.6)
				local sz = s0 + (s1 - s0) * (1 - math.exp(-age / 0.09)) + age * 3 * sm
				local a = a0 * math.min(1, age / 0.012 + 0.35) * math.exp(-age / (die * 0.45))
				p:SetStartSize(sz) p:SetEndSize(sz)
				p:SetStartAlpha(a) p:SetEndAlpha(a)
				p:SetNextThink(now)
			end)
		end
	end
end

local mistTrace = { mask = MASK_SHOT }
local mistFlt = {}
function F.MistDeposit(pos, dir, cone, vol, reach, owner, oxy, btype, expirated)
	if vol <= 0 then return end
	local th = G.Particles and G.Particles.Thin and G.Particles.Thin() or 1
	local rays = math.max(3, math.floor(7 / th + 0.5))
	local hits = {}
	local wsum = 0
	mistTrace.filter = F.PlumeFilter and F.PlumeFilter(owner, pos, mistFlt) or F.BodyFilter(owner)   -- (1.26.8)
	for i = 1, rays do
		local d = i == 1 and dir or U.ConeDir(dir, cone)
		mistTrace.start = pos
		mistTrace.endpos = pos + d * reach
		local tr = util.TraceLine(mistTrace)
		if tr.Hit and not tr.HitSky and not tr.StartSolid then
			local dist = tr.Fraction * reach
			local w = 1 / (1 + (dist / 14) ^ 2)
			hits[#hits + 1] = { tr = tr, d = d, dist = dist, w = w }
			wsum = wsum + w
		end
	end
	if wsum <= 0 then return end
	for _, h in ipairs(hits) do
		local tr = h.tr
		local share = vol * h.w / wsum * (#hits / rays)
		local isFloor = tr.HitNormal.z > 0.45
		local R = isFloor and math.Clamp(0.65 + h.dist * 0.04, 0.65, 1.85) or (2.2 + h.dist * 0.18)
		local vel = h.d * 60
		local extra = { flags = expirated and 1 or 0, btype = btype, oxy = oxy }
		local ent = tr.Entity
		local hp, hn = Vector(tr.HitPos), Vector(tr.HitNormal)
		local delay = math.Clamp(h.dist / 260 + (isFloor and U.RandRange(0.06, 0.16) or 0.01), 0.02, 0.38)
		timer.Simple(delay, function()
			if IsValid(ent) and not ent:IsWorld() then
				if G.Entities and G.Entities.Impact then
					G.Entities.Impact(ent, hp, hn, vel, R, share, 6, 0, 1, 0.35, nil, extra)
				end
			elseif G.Surfaces and G.Surfaces.Impact then
				G.Surfaces.Impact(hp, hn, vel, R, share, 6, 0, 1, 0.35, tr, oxy, btype, extra)
			end
		end)
	end
end

function F.DirectConeMist(pos, dir, coneDeg, reach, count, intensity, owner, oxy, btype, gun, set)
	if not G.Surfaces or not G.Surfaces.Impact or count <= 0 or intensity <= 0.01 then return end
	local sz, _, spread, amt = cvs()
	-- (1.26.7) gunshots with Crisis Response splats: the splats are the spray, the cone throws a third of its drops,
	-- smaller (still wet, they run)
	local rCap = 1.2
	if gun and F.SplatMode(btype) then
		count = math.max(1, math.floor(count / 3))
		rCap = 0.6
	end
	local th = G.Particles and G.Particles.Thin and G.Particles.Thin() or 1
	local nRays = math.max(2, math.floor(count * math.min(amt, 1.8) / math.sqrt(th) + 0.5))
	mistTrace.filter = F.PlumeFilter and F.PlumeFilter(owner, pos, mistFlt) or F.BodyFilter(owner)   -- (1.26.8)
	local coneRad = math.rad(coneDeg * spread)
	for i = 1, nRays do
		local d = U.ConeDir(dir, coneRad)
		d = (d + Vector(0, 0, U.RandRange(-0.28, 0.08))):GetNormalized()
		mistTrace.start = pos
		mistTrace.endpos = pos + d * reach
		local tr = util.TraceLine(mistTrace)
		if tr.Hit and not tr.HitSky and not tr.StartSolid then
			local dist = tr.Fraction * reach
			local distFactor = math.Clamp(1 - (dist / reach) * 0.65, 0.2, 1)
			local hn = Vector(tr.HitNormal)
			local hp = Vector(tr.HitPos)
			local cosInc = math.abs(d:Dot(hn))
			local elong = math.Clamp(1 / math.max(cosInc, 0.18), 1.0, 3.0)
			-- (1.26.7) mist drops, not blotches (was 0.55 + 0.95 i, up to 3.2 u)
			local R = math.Clamp((0.3 + 0.4 * intensity * distFactor) * sz, 0.12, rCap)
			local vol = F.Volume(R * 2.1) * (0.8 + 0.9 * intensity)
			local vel = d * (180 + 160 * intensity * distFactor)
			local extra = { spines = math.floor(8 + 14 * intensity), K = 160 * intensity, flags = 0, btype = btype, oxy = oxy }
			local hitEnt = tr.Entity
			local flightSpd = 380 + 180 * intensity
			local delay = math.Clamp(dist / flightSpd + (hn.z > 0.45 and U.RandRange(0.04, 0.11) or 0.008), 0.015, 0.34)
			timer.Simple(delay, function()
				if not G.Surfaces or not G.Surfaces.Impact then return end
				if IsValid(hitEnt) and not hitEnt:IsWorld() and not G.Surfaces.IsGround(hitEnt) then
					G.Entities.Impact(hitEnt, hp, hn, vel, R, vol, 0, U.RandRange(-30, 30), elong, 0.22, nil, extra)
				else
					-- (1.26.10h) a forensic spatter set instead of a big splat (A back-spatter, B exit spray)
					local Rs, vs, es = R, vol, extra
					if R >= F.FORENSIC_MIN_R and F.ForensicOn() then
						if F.Forensic(set or "A", hp, hn, d, R, btype, oxy, tr, intensity) then return end
						Rs, vs, es = F.ForensicSmall(R, vol, extra)
						elong = math.min(elong, 1.6)
					end
					G.Surfaces.Impact(hp, hn, vel, Rs, vs, 0, U.RandRange(-30, 30), elong, 0.22, tr, oxy, btype, es)
					if elong > 1.35 and Rs == R then
						local vt = d - hn * d:Dot(hn)
						local vtl = vt:Length()
						if vtl > 1e-3 then
							local tdir = vt / vtl
							local nTail = math.min(math.floor(elong), 3)
							for seg = 1, nTail do
								local frac = seg / (nTail + 0.4)
								local tPos = hp + tdir * (R * elong * frac * 0.85)
								local tR = math.max(R * (0.68 - 0.16 * seg), 0.1)
								G.Surfaces.Impact(tPos, hn, tdir * 160, tR, vol * 0.14 / nTail, 0, 0, 1.6 + 0.3 * seg, 0.2, tr, oxy, btype)
							end
						end
					end
				end
			end)
		end
	end
end

function F.CastOffArc(pos, baseDir, sweepVec, reach, count, intensity, owner, oxy, btype)
	if not G.Surfaces or not G.Surfaces.Impact or count <= 0 then return end
	local sz, sp, spread, amt = cvs()
	local nSteps = math.Clamp(math.floor(count * math.min(amt, 1.8) + 0.5), 3, 14)
	local sw = (sweepVec and sweepVec:LengthSqr() > 0.01) and sweepVec:GetNormalized() or Frame(baseDir)
	mistTrace.filter = F.BodyFilter(owner)
	for i = 0, nSteps - 1 do
		local t = (i / math.max(nSteps - 1, 1)) - 0.5
		local rayDir = (baseDir + sw * (t * 1.45 * spread) + Vector(0, 0, U.RandRange(-0.18, 0.12))):GetNormalized()
		mistTrace.start = pos
		mistTrace.endpos = pos + rayDir * reach
		local tr = util.TraceLine(mistTrace)
		if tr.Hit and not tr.HitSky and not tr.StartSolid then
			local dist = tr.Fraction * reach
			local distF = math.Clamp(1 - (dist / reach) * 0.55, 0.25, 1)
			local elong = math.Clamp(1.55 + math.abs(t) * 1.5, 1.4, 3.2)
			local R = math.Clamp((0.45 + 0.75 * intensity * (1 - math.abs(t) * 0.35) * distF) * sz, 0.18, 2.6)
			local vol = F.Volume(R * 2.0) * intensity
			local vel = (rayDir + sw * (t >= 0 and 0.35 or -0.35)):GetNormalized() * (220 * sp)
			local hp, hn = Vector(tr.HitPos), Vector(tr.HitNormal)
			local delay = math.Clamp(0.02 + (i / math.max(nSteps, 1)) * 0.14 + dist / 420, 0.02, 0.32)
			timer.Simple(delay, function()
				if G.Surfaces and G.Surfaces.Impact then
					G.Surfaces.Impact(hp, hn, vel, R, vol, 0, U.RandRange(-35, 35), elong, 0.22, tr, oxy, btype)
				end
			end)
		end
	end
end

function F.ArterialGush(ent, pos, jetDir, jetSpeed, btype, oxy, strength)
	if not G.Surfaces or not G.Surfaces.Impact then return end
	local sz, _, spread = cvs()
	local dir = U.ConeDir(jetDir, 0.16 * spread)
	local curPos = Vector(pos)
	local stepDist = math.Clamp(jetSpeed * 0.12, 18, 42)
	mistTrace.filter = F.BodyFilter(ent)
	for step = 1, 3 do
		local dropVec = Vector(0, 0, -0.14 * step * step)
		local segDir = (dir + dropVec):GetNormalized()
		local nextPos = curPos + segDir * stepDist
		mistTrace.start = curPos
		mistTrace.endpos = nextPos
		local tr = util.TraceLine(mistTrace)
		if tr.Hit and not tr.HitSky and not tr.StartSolid then
			local hn = Vector(tr.HitNormal)
			local hp = Vector(tr.HitPos)
			local cosInc = math.abs(segDir:Dot(hn))
			local elong = math.Clamp(1 / math.max(cosInc, 0.18), 1.3, 3.2)
			local R = math.Clamp((0.85 + 0.65 * (strength or 1)) * sz, 0.35, 3.2)
			local vol = F.Volume(R * 2.4) * (strength or 1)
			local vel = segDir * math.max(jetSpeed, 180)
			local extra = { spines = 18, K = 210, flags = 0, btype = btype, oxy = oxy or 1.0 }
			local totalDist = (step - 1) * stepDist + tr.Fraction * stepDist
			local delay = math.Clamp(totalDist / math.max(jetSpeed, 220) + (hn.z > 0.45 and 0.035 or 0.01), 0.015, 0.28)
			timer.Simple(delay, function()
				if not G.Surfaces or not G.Surfaces.Impact then return end
				-- (1.26.10h) on walls: the angled-impact spatter set (D) instead of a big splat; floors keep theirs
				if R >= F.FORENSIC_MIN_R and math.abs(hn.z) < 0.7 and F.ForensicOn() then
					if F.Forensic("D", hp, hn, segDir, R, btype, oxy or 1.0, tr, strength or 1) then return end
					local Rs, vs, es = F.ForensicSmall(R, vol, extra)
					G.Surfaces.Impact(hp, hn, vel, Rs, vs, 0, U.RandRange(-30, 30), math.min(elong, 1.6), 0.24, tr, oxy or 1.0, btype, es)
					return
				end
				G.Surfaces.Impact(hp, hn, vel, R, vol, 0, U.RandRange(-30, 30), elong, 0.24, tr, oxy or 1.0, btype, extra)
				local vt = segDir - hn * segDir:Dot(hn)
				local vtl = vt:Length()
				if vtl > 1e-3 then
					local tdir = vt / vtl
					for s = 1, 2 do
						local tPos = hp + tdir * (R * elong * s * 0.55)
						G.Surfaces.Impact(tPos, hn, tdir * 190, R * (0.68 - 0.18 * s), vol * 0.18, 0, 0, 1.8 + 0.3 * s, 0.2, tr, oxy or 1.0, btype)
					end
				end
			end)
			return
		end
		curPos = nextPos
	end
end

-- ---------------------------------------------------------------- (1.26.6) ballistics
-- The class of a bullet hit from its damage type, the ammunition / weapon of the attacker and the damage. It decides
-- whether the bullet leaves the body, how much blood the hit throws, and how far the blood carried out of the exit wound
-- reaches the walls, floor and props behind the body (F.ExitPlume). dmg = what is typical for the class (energy scale).
-- (1.26.7) fewer and smaller stains per hit (players: "a pistol headshot covers the entire wall"): rays 9/13/15/22/3 ->
-- 6/9/10/15/2, the biggest stains (rMax) about a third smaller; the fine spray is the CRB decal now
F.BALLISTIC = {
	pistol   = { dmg = 22,  exitTorso = 0.75, exitOther = 0.95, reach = 220, cone = 15, rays = 6,  rMin = 0.35, rMax = 1.0, chunks = 0, back = 0.9,  fwd = 0.9 },
	magnum   = { dmg = 55,  exitTorso = 1.0,  exitOther = 1.0,  reach = 340, cone = 19, rays = 9,  rMin = 0.45, rMax = 1.4, chunks = 1, back = 1.15, fwd = 1.25 },
	rifle    = { dmg = 35,  exitTorso = 1.0,  exitOther = 1.0,  reach = 400, cone = 21, rays = 10, rMin = 0.45, rMax = 1.5, chunks = 2, back = 1.2,  fwd = 1.35 },
	sniper   = { dmg = 100, exitTorso = 1.0,  exitOther = 1.0,  reach = 600, cone = 26, rays = 15, rMin = 0.6,  rMax = 2.2, chunks = 4, back = 1.45, fwd = 1.8, burst = true },
	buckshot = { dmg = 9,   exitTorso = 0.22, exitOther = 0.5,  reach = 190, cone = 13, rays = 2,  rMin = 0.3,  rMax = 0.8, chunks = 0, back = 0.75, fwd = 0.7 },
}
F.BALLISTIC.magnum.burst = true
F.BALLISTIC.rifle.burst = true
-- radius (u) of the spatter pattern the main stream paints where it lands close behind the body
-- (1.26.7) 9/13/14/22/6 -> 6/8/9/14/4: a pistol's spatter is about 20-35 cm across
F.BALLISTIC.pistol.patR, F.BALLISTIC.magnum.patR, F.BALLISTIC.rifle.patR = 6, 8, 9
F.BALLISTIC.sniper.patR, F.BALLISTIC.buckshot.patR = 14, 4
-- (1.26.7) Crisis Response splats (ghmpb_crb_splats): how many of the plume's streams lay a CRB splat decal, and the
-- radius (u) holding most of the main splat's blood (the others are about half that). A pistol's main splat is a decal
-- about 28 u (55 cm) across, a sniper's about 47 u; the Crisis Response Blood Mod lays them at 61 u.
F.BALLISTIC.pistol.splats, F.BALLISTIC.pistol.splatR = 2, 10
F.BALLISTIC.magnum.splats, F.BALLISTIC.magnum.splatR = 3, 12
F.BALLISTIC.rifle.splats, F.BALLISTIC.rifle.splatR = 3, 13
F.BALLISTIC.sniper.splats, F.BALLISTIC.sniper.splatR = 4, 17
F.BALLISTIC.buckshot.splats, F.BALLISTIC.buckshot.splatR = 1, 6
-- (1.26.6) back spatter as traced streams too: back towards the shooter, shorter and wider than the exit plume
for cls, p in pairs(F.BALLISTIC) do
	p.backProf = { reach = p.reach * (cls == "buckshot" and 0.35 or 0.3), cone = 38, rays = math.max(2, math.ceil(p.rays * 0.6)),
		rMin = p.rMin * 0.7, rMax = p.rMax * 0.75, chunks = 0, dmg = p.dmg, patR = p.patR * 0.6,
		splats = math.max(1, math.floor(p.splats / 2)), splatR = p.splatR * 0.6 }
end

-- (1.26.7) gunshot spatter, the Crisis Response Blood way (players: "smaller, more varied spatters, not the same two or
-- three on every wall, a pistol headshot must not cover the whole wall"):
--  * the fine spray: one of the 36 spatter decals of GHM's Crisis Response Blood Mod (thousands of tiny drops, the real
--    look of high-velocity spatter), sized to the spatter (cl_crbdata.lua); other blood types: recoloured copies
--  * the bigger drops of one of the 18 CRB spatter patterns (cl_spatterdata.lua), as PhysBlood stains: wet, they run,
--    soak in and dry
-- Every hit is different: a random decal and a random pattern (not the same one), the pattern turned to any angle and
-- mirrored, scaled 0.8-1.25, and only part of its drops - fewer for weaker hits and far away. sizeU = the spatter's
-- radius (u); dd = the way the blood travelled (hits at an angle stretch the drops along it).
local cvCrbDecals = CreateClientConVar("ghmpb_crb_decals", "1", true, false, "GHM PhysBlood: fine gunshot spray from the Crisis Response Blood spatter decals (0 = PhysBlood drops only)", 0, 1)
F.cvCrbDecals = cvCrbDecals
-- (1.26.7, from players' feedback: "these big drops are too dense") the blood a gunshot carries onto the walls and floor
-- lands as Crisis Response splats instead of PhysBlood's wet drops: the traced streams of the exit and back plumes lay
-- CRB splat decals (F.BALLISTIC splats / splatR), only the main stream keeps one small wet stain that can run and dry,
-- the spatter patterns' big drops are not laid, and the forward cone throws a third of its drops, smaller. Every blood
-- type, on the world and on props: red blood with the CRB decals as they are, the others (yellow, green, zombie, synth,
-- robot) with recoloured copies in the colour PhysBlood gives that blood. Bodies keep the PhysBlood stains.
local cvCrbSplats = CreateClientConVar("ghmpb_crb_splats", "1", true, false, "GHM PhysBlood: gunshot spatter on walls and floors as Crisis Response splats instead of PhysBlood's big wet drops (needs ghmpb_crb_decals)", 0, 1)
F.cvCrbSplats = cvCrbSplats
-- (1.26.7) every blood type: red blood uses the 36 original splats as they are; yellow, green, zombie, synth and robot
-- blood use recoloured copies of 10 of them (cl_crbtypes.lua, tools/make_crb_types.py: the same DecalModulate splats,
-- recoloured with PhysBlood's own absorption bands for that blood, so they look and behave like the red ones)
local function CRBList(btype)
	btype = btype or 0
	if btype == 0 then return nil, true end
	local T = GHMPB.CRBTypeDecals
	return T and T[btype] or nil, false
end
F.CRBList = CRBList
function F.HasCRB(btype)
	local list, red = CRBList(btype)
	return red or (list ~= nil and #list > 0)
end
function F.SplatMode(btype)
	return F.HasCRB(btype) and cvCrbSplats:GetBool() and cvCrbDecals:GetBool() and GHMPB.CRBDecals ~= nil
		and util ~= nil and util.DecalEx ~= nil
end
local function IsBody(e)
	return IsValid(e) and ((e.IsNPC and e:IsNPC()) or (e.IsPlayer and e:IsPlayer()) or (e.IsRagdoll and e:IsRagdoll())) or false
end
F.IsBody = IsBody
-- can a splat land on this entity (nil = the world)? Not on bodies (they keep PhysBlood's body blood); DecalModulate
-- splats take the world, brush entities and model props alike
function F.SplatTakes(ent, btype)
	return F.HasCRB(btype) and not IsBody(ent)
end
local crbMats = {}
-- engine decals: at most 16 at once, then 10 a second (a magazine dumped into a crowd does not churn the decal list)
local crbTokens, crbT = 16, 0
F.crbStats = F.crbStats or { decals = 0, failed = 0, throttled = 0, typed = 0 }
function F.CRBDecal(pos, n, sizeU, ent, btype, dir)
	local D = GHMPB.CRBDecals
	btype = btype or 0
	if not D or #D == 0 or not cvCrbDecals:GetBool() or not util or not util.DecalEx or not pos or not n then return false end
	if not F.SplatTakes(ent, btype) then return false end
	local list, red = CRBList(btype)
	local now = CurTime()
	crbTokens = math.min(16, crbTokens + math.max(now - crbT, 0) * 10)
	crbT = now
	if crbTokens < 1 then F.crbStats.throttled = (F.crbStats.throttled or 0) + 1 return false end
	crbTokens = crbTokens - 1
	local i = red and math.random(1, #D) or list[math.random(1, #list)]
	if not D[i] then return false end
	local key = btype * 100 + i
	local m = crbMats[key]
	if m == nil then
		m = Material(red and ("ghm_physblood/crb/bp" .. i) or ("ghm_physblood/crb/t" .. btype .. "_bp" .. i))
		if not m or (m.IsError and m:IsError()) then m = false end
		crbMats[key] = m
	end
	if not m then F.crbStats.failed = F.crbStats.failed + 1 return false end
	local W = GHMPB.CRB_DECAL_UNITS or 30.72
	local s = sizeU / math.max(D[i].r * W, 1)
	local sx, sy = s * U.RandRange(0.9, 1.1), s * U.RandRange(0.9, 1.1)
	local onEnt = IsValid(ent) and not ent:IsWorld()
	-- (1.26.7) on the world PhysBlood draws the splat itself (cl_splatmesh.lua): engine decals vanish at the engine's
	-- limit; as a mesh it stays (until "splats kept" is used up) and turns with the way the blood travelled
	local SMm = G.SplatMesh
	if not onEnt and SMm and SMm.On and SMm.On() and SMm.Lay then
		local px = (D[i].px or 1024) / 1024
		local tex = red and ("ghm_physblood/crb/bp" .. i) or ("ghm_physblood/crb/t" .. btype .. "_bp" .. i)
		if SMm.Lay(pos, n, tex, sx * W * px, sy * W * px, dir) then
			if not red then F.crbStats.typed = (F.crbStats.typed or 0) + 1 end
			F.crbStats.decals = F.crbStats.decals + 1
			F.crbStats.meshed = (F.crbStats.meshed or 0) + 1
			return true
		end
	end
	local target = onEnt and ent or (game and game.GetWorld and game.GetWorld())
	local ok = pcall(util.DecalEx, m, target, pos, n, color_white, sx, sy)
	if ok and not red then F.crbStats.typed = (F.crbStats.typed or 0) + 1 end
	if ok then F.crbStats.decals = F.crbStats.decals + 1 else F.crbStats.failed = F.crbStats.failed + 1 end
	return ok
end

local patTokens, patT = 4, 0
F.patStats = F.patStats or { patterns = 0, drops = 0 }
-- (1.26.10h) set: one of GHMPB.SpatterSets (cl_spatterdata.lua) instead of the measured patterns, with a token bucket of
-- its own (F.Forensic lays them in place of the big spiky splats)
local setTokens, setT = 8, 0
function F.Spatter(hp, hn, dd, sizeU, btype, oxy, tr, energy, ent, set)
	local pats = GHMPB.SpatterPatterns
	if set then pats = GHMPB.SpatterSets and GHMPB.SpatterSets[set] end
	if not pats or #pats == 0 or not G.Surfaces or not G.Surfaces.Impact or not hp or not hn then return 0 end
	local now = CurTime()
	if set then
		setTokens = math.min(8, setTokens + math.max(now - setT, 0) * 6)
		setT = now
		if setTokens < 1 then return 0 end
		setTokens = setTokens - 1
	else
		patTokens = math.min(4, patTokens + math.max(now - patT, 0) * 4)
		patT = now
		if patTokens < 1 then return 0 end
		patTokens = patTokens - 1
	end
	energy = energy or 1
	local hit = IsValid(ent) and not ent:IsWorld() and ent or nil
	local sc = U.RandRange(0.8, 1.25)
	-- the fine spray
	local decal = F.CRBDecal(hp + hn * 0.1, hn, sizeU * sc, hit, btype, dd)
	-- the bigger drops
	local pat = pats[math.random(1, #pats)]
	dd = dd or -hn
	local cosI = math.abs(dd:Dot(hn))
	local t1 = math.abs(hn.z) < 0.9 and Vector(0, 0, 1):Cross(hn) or Vector(1, 0, 0):Cross(hn)
	t1:Normalize()
	local t2 = hn:Cross(t1)
	local t = dd - hn * dd:Dot(hn)
	local E = 1
	if t:LengthSqr() < 1e-4 or cosI > 0.93 then
		-- square on: any angle
		local a = math.random() * 6.2831853
		t = t1 * math.cos(a) + t2 * math.sin(a)
	else
		t:Normalize()
		E = math.Clamp(1 / math.max(cosI, 0.3), 1, 2.6)
	end
	local b = hn:Cross(t)
	if math.random() < 0.5 then b = -b end
	local shift = (E - 1) * 0.35
	-- how many of the drops: the biggest third always (fewer for weak hits), the rest thinned by energy, distance and
	-- battles
	local dist = hp:Distance(EyePos())
	local far = math.Clamp(1.25 - dist / 1800, 0.3, 1) * (1 - 0.5 * (G.Battle and G.Battle.level or 0))
	local keepBig = math.Clamp(0.5 + 0.35 * energy, 0.5, 1)
	local keepSmall = far * math.Clamp(0.25 + 0.35 * energy, 0.25, 0.9)
	-- the small drops are not painted where they would be under half a pixel from the camera
	local vs = render and render.GetViewSetup and render.GetViewSetup()
	local pxK = (ScrW and ScrW() or 1600) * 0.5 / math.tan(math.rad(math.Clamp(vs and vs.fov or 75, 10, 170) * 0.5))
	local minR = 0.5 * dist / pxK
	local d, n = pat.d, pat.n
	local big = math.floor(n / 3)
	local K = 110 + 70 * math.min(energy, 1.6)
	local made = 0
	local jit = 0.025 * sizeU * sc
	for i = 0, n - 1 do
		if math.random() < (i < big and keepBig or keepSmall) then
			local u, v, r, ang, el = d[i * 5 + 1], d[i * 5 + 2], d[i * 5 + 3], d[i * 5 + 4], d[i * 5 + 5]
			local rU = r * sizeU * sc * (0.85 + 0.15 * E) * U.RandRange(0.8, 1.2)
			if set and rU > 0.5 then rU = 0.5 end -- (1.26.10h) forensic sets: droplets only, nothing over ~1 cm
			if rU >= 0.08 and (i < big or rU >= minR) then
				local pos = hp + (t * ((u + shift) * E) + b * v) * sizeU * sc + t1 * U.RandRange(-jit, jit) + t2 * U.RandRange(-jit, jit) + hn * 0.05
				local dir, st = t * math.cos(ang) + b * math.sin(ang), el
				if E > 1.25 then dir, st = t, math.min(el * math.sqrt(E), 4) end
				st = math.max(st or 1, 1)
				local sa = 1 / st
				local vel = (dir * math.sqrt(math.max(1 - sa * sa, 0)) - hn * sa) * 260
				local vol = F.WetVol(rU, st, F.Volume(rU * 2.2) * 1.1)
				local extra = { spines = math.floor(3 + 14 * math.min(r * 30, 1)), K = K, flags = 0, btype = btype, oxy = oxy }
				if hit then
					if G.Entities and G.Entities.Impact then G.Entities.Impact(hit, pos, hn, vel, rU, vol, 0, U.RandRange(-30, 30), 1, 0.22, nil, extra) end
				else
					G.Surfaces.Impact(pos, hn, vel, rU, vol, 0, U.RandRange(-30, 30), 1, 0.22, tr, oxy, btype, extra)
				end
				made = made + 1
			end
		end
	end
	-- the fine mist round it (without the decal: it stands in for the fine spray)
	local m = pat.mist
	if m and m[4] > 0.01 and not hit then
		local mr = m[3] * sizeU * sc * (0.7 + 0.3 * E)
		local dens = decal and 0.5 or 1
		G.Surfaces.Impact(hp + (t * ((m[1] + shift) * E) + b * m[2]) * sizeU * sc, hn, t * 60, mr,
			90 * dens * math.min(m[4] * 4, 1.5) * (sizeU / 14) ^ 2 * math.min(energy, 1.6), 6, 0, E, 0.3, tr, oxy, btype)
	end
	if set then
		F.forensicStats = F.forensicStats or { laid = 0, small = 0 }
		F.forensicStats.drops = (F.forensicStats.drops or 0) + made
	else
		F.patStats.patterns = F.patStats.patterns + 1
		F.patStats.drops = F.patStats.drops + made
	end
	return math.max(made, decal and 1 or 0)
end
-- names of ammunition and weapons (HL2, ARC9, TFA, CW2, M9K, MW base...): the first that matches decides
local AMMO_CLASS = {
	-- (1.26.7) Z-City's ammunition names first where the general patterns below would get them wrong or miss them
	-- ("7.62x25" is a pistol round, ".22 Long Rifle" is not a rifle, "5.7x28" / "4.6x30" are PDW rounds)
	{ "7.62x25", "pistol" }, { "22 long", "pistol" }, { "9x18", "pistol" }, { "9x17", "pistol" }, { "7.65x17", "pistol" },
	{ ".40 sw", "pistol" }, { "4.6x30", "pistol" }, { "5.7x28", "pistol" }, { "38 special", "pistol" }, { "taser", "buckshot" },
	{ "action express", "magnum" }, { "9x39", "rifle" }, { ".366", "rifle" }, { "12.7x55", "rifle" },
	{ "14.5x114", "sniper" }, { "12.7x108", "sniper" }, { "23x75", "buckshot" }, { "/70 gauge", "buckshot" },
	{ "buck", "buckshot" }, { "shotgun", "buckshot" }, { "shell", "buckshot" }, { "gauge", "buckshot" }, { "12g", "buckshot" },
	{ "pellet", "buckshot" }, { "spas", "buckshot" }, { "slug", "magnum" },
	{ "sniper", "sniper" }, { "crossbow", "sniper" }, { "xbow", "sniper" }, { "bmg", "sniper" }, { "338", "sniper" },
	{ "lapua", "sniper" }, { "50cal", "sniper" }, { "antimat", "sniper" }, { "308", "sniper" }, { "7.62x54", "sniper" },
	{ "762x54", "sniper" }, { "dmr", "sniper" }, { "marksman", "sniper" }, { "awp", "sniper" }, { "barrett", "sniper" },
	{ "357", "magnum" }, { "magnum", "magnum" }, { "44", "magnum" }, { "50ae", "magnum" }, { "revolver", "magnum" }, { "deagle", "magnum" },
	{ "ar2", "rifle" }, { "rifle", "rifle" }, { "556", "rifle" }, { "5.56", "rifle" }, { "223", "rifle" }, { "762", "rifle" },
	{ "7.62", "rifle" }, { "545", "rifle" }, { "5.45", "rifle" }, { "300", "rifle" }, { "assault", "rifle" }, { "carbine", "rifle" },
	{ "airboat", "rifle" }, { "ak47", "rifle" }, { "m4a1", "rifle" }, { "m16", "rifle" },
	{ "pistol", "pistol" }, { "smg", "pistol" }, { "9mm", "pistol" }, { "9x19", "pistol" }, { "45", "pistol" }, { "acp", "pistol" },
	{ "380", "pistol" }, { "22", "pistol" }, { "57", "pistol" }, { "46", "pistol" },
}
F.AMMO_CLASS = AMMO_CLASS
-- (1.26.10h) GHM: "replace the big blob blood texture with something more of forensic aerosol spray droplets" - the big
-- spiky splats (exit plume streams, the gunshot cones, a burst on a nearby wall, arterial jets on walls) become one of the
-- forensic spatter sets: A gunshot back-spatter, B exit spray, C medium-velocity impact, D angled impact, E fine mist (far),
-- F heavy close hit. Splats under F.FORENSIC_MIN_R stay as they are; floors keep their pools and streaks. When the sets'
-- token bucket is empty the splat is laid as a small drop, never as a blob. ghmpb_forensic_spatter 0 = the old splats.
local cvForensic = CreateClientConVar("ghmpb_forensic_spatter", "1", true, false, "GHM PhysBlood: big splats on walls are laid as forensic droplet spatter (fine mist and drops with tails) instead of one big spiky blob (0 = the old big splats)", 0, 1)
F.FORENSIC_MIN_R = 0.55
F.cvForensic = cvForensic
function F.ForensicOn() return cvForensic:GetBool() and GHMPB.SpatterSets ~= nil end
-- lays set (pattern radius from the splat's size R); true when laid
function F.Forensic(set, hp, hn, dd, R, btype, oxy, tr, energy)
	if not F.ForensicOn() or not GHMPB.SpatterSets[set] then return false end
	F.forensicStats = F.forensicStats or { laid = 0, small = 0 }
	if F.Spatter(hp, hn, dd, math.Clamp(R * 9, 7, 36), btype, oxy, tr, energy or 1, nil, set) > 0 then
		F.forensicStats.laid = F.forensicStats.laid + 1
		return true
	end
	F.forensicStats.small = F.forensicStats.small + 1
	return false
end
-- a big splat that could not get a pattern: a small drop instead (radius, volume, extra)
function F.ForensicSmall(R, vol, extra)
	local e = {}
	if extra then for k, v in pairs(extra) do e[k] = v end end
	e.spines = 3
	e.K = math.min(e.K or 120, 120)
	return math.Clamp(R * 0.32, 0.12, 0.45), vol * 0.05, e
end

local function WeaponNames(attacker)
	if not IsValid(attacker) or not attacker.GetActiveWeapon then return nil end
	local ok, w = pcall(attacker.GetActiveWeapon, attacker)
	if not ok or not IsValid(w) then return nil end
	local name = ""
	local at = w.GetPrimaryAmmoType and w:GetPrimaryAmmoType()
	if at and at >= 0 and game.GetAmmoName then name = game.GetAmmoName(at) or "" end
	if name == "" and istable(w.Primary) and isstring(w.Primary.Ammo) then name = w.Primary.Ammo end
	return string.lower(name), string.lower(w:GetClass() or "")
end
-- profile, energy (0.7..1.6 of what is typical for the class), class name
function F.Ballistic(dmg, dmgtype, attacker)
	dmg = dmg or 20
	local cls
	if bit.band(dmgtype or 0, DMG_BUCKSHOT or 0) ~= 0 then cls = "buckshot"
	elseif bit.band(dmgtype or 0, DMG_SNIPER or 0) ~= 0 then cls = "sniper" end
	if not cls then
		local ammo, wep = WeaponNames(attacker)
		-- the ammunition first, then the weapon's class name
		for _, s in ipairs({ ammo or "", wep or "" }) do
			if s ~= "" then
				for _, m in ipairs(AMMO_CLASS) do if string.find(s, m[1], 1, true) then cls = m[2] break end end
			end
			if cls then break end
		end
	end
	if not cls then cls = dmg >= 80 and "sniper" or (dmg >= 45 and "magnum" or (dmg >= 28 and "rifle" or "pistol")) end
	-- weapon packs that put rifles on HL2's pistol / SMG ammunition: the damage tells
	if cls == "pistol" and dmg >= 42 then cls = dmg >= 80 and "sniper" or "rifle"
	elseif cls == "rifle" and dmg >= 85 then cls = "sniper" end
	local prof = F.BALLISTIC[cls]
	return prof, math.Clamp(math.sqrt(dmg / prof.dmg), 0.7, 1.6), cls
end
-- does the bullet leave the body? torso: chest, abdomen, pelvis; buckshot goes through more often close up
function F.Exits(prof, region, dist)
	local torso = region == "chest" or region == "abdomen" or region == "pelvis"
	local p = torso and prof.exitTorso or prof.exitOther
	if prof == F.BALLISTIC.buckshot and dist then p = p * math.Clamp(2.2 - dist / 300, 0.5, 2) end
	return math.random() < p
end

-- The blood a bullet carries out of the exit wound, to whatever is behind the body: traced streams in a cone round the
-- bullet's path (straight at first, then falling), painted where they land with the delay of their flight - dense and
-- big near the body, smaller and scattered further off, elongated at grazing angles, small satellite drops round the
-- near ones, a bigger central splash for heavy rounds. Returns the number of streams.
local plumeTr = { mask = MASK_SHOT }
local plumeFlt = {}
-- (1.26.7) what the blood thrown out of a body must not land on: the body itself, and with Z-City the other half of the
-- character (the hidden player while his fake ragdoll lies there, the ragdoll while he stands)
function F.BodyFilter(ent)
	if not IsValid(ent) then return nil end
	local t = { ent }
	-- (1.26.8) an NPC and the ragdoll it turned into (both can be there for a moment, at the same place)
	local R = G.Render
	local rag = R and R.ragOf and R.ragOf[ent]
	if IsValid(rag) and rag ~= ent then t[#t + 1] = rag end
	local ZC = G.ZC
	if not (ZC and ZC.Active and ZC.Active()) then return #t > 1 and t or ent end
	local p = ent:IsPlayer() and ent or (ent:IsRagdoll() and ent:GetNWEntity("ply")) or nil
	if IsValid(p) and p:IsPlayer() then
		if p ~= ent then t[#t + 1] = p end
		for _, k in ipairs({ "FakeRagdoll", "RagdollDeath" }) do
			local r = p:GetNWEntity(k)
			if IsValid(r) and r ~= ent then t[#t + 1] = r end
		end
	end
	return #t > 1 and t or ent
end
-- (1.26.8) what the blood leaving a body must not land on right where it leaves it: the body (see F.BodyFilter) and any
-- other form of it this client has there at that moment - the server's ragdoll of an NPC killed by the shot can already
-- be on this client, at the same place, before PhysBlood knows it is that NPC's (the blood thrown out the back hit it
-- and was gone, so no splat reached the wall). Bodies whose bounds come within 20 u of where the blood leaves.
function F.PlumeFilter(ent, start, out)
	out = out or {}
	for k = #out, 1, -1 do out[k] = nil end
	local bf = F.BodyFilter(ent)
	if istable(bf) then for i = 1, #bf do out[#out + 1] = bf[i] end elseif bf then out[1] = bf end
	if start and ents and ents.FindInSphere then
		for _, e in ipairs(ents.FindInSphere(start, 20)) do
			if IsBody(e) then
				local dup = false
				for i = 1, #out do if out[i] == e then dup = true break end end
				if not dup then out[#out + 1] = e end
			end
		end
	end
	return out
end
local plumeTokens, plumeT = 180, 0
F.plumeStats = F.plumeStats or { streams = 0, landed = 0 }
function F.ExitPlume(ent, pos, dir, prof, e, btype, oxy, mul, head)
	mul = mul or 1
	if not G.Surfaces or not G.Surfaces.Impact or mul <= 0.001 or not pos or not dir then return 0 end
	if pos:DistToSqr(EyePos()) > 3500 * 3500 then return 0 end
	local now = CurTime()
	plumeTokens = math.min(180, plumeTokens + math.max(now - plumeT, 0) * 180)
	plumeT = now
	local sz, sp, spread, amt = cvs()
	e = e or 1
	local hk = head and 1.1 or 1   -- (1.26.7) was 1.3
	local n = math.floor(prof.rays * e * hk * math.min(mul, 3) * math.Clamp(amt, 0.3, 2) + math.random())
	n = math.min(n, math.floor(plumeTokens), 40)
	if n <= 0 then return 0 end
	plumeTokens = plumeTokens - n
	local reach = prof.reach * math.sqrt(e) * math.Clamp(sp, 0.5, 2)
	local cone = math.rad(prof.cone * math.Clamp(spread, 0.3, 3))
	local side, up = Frame(dir)
	local rk = math.sqrt(e) * (head and 1.05 or 1) * math.Clamp(math.sqrt(mul), 0.6, 1.4)
	local start = pos + dir * 1.5
	plumeTr.filter = F.PlumeFilter(ent, start, plumeFlt)
	for i = 1, n do
		local d = dir
		if i > 1 then
			local a = cone * math.min(math.abs(gauss()) * 0.6, 1.7)
			local phi = math.random() * 6.2831853
			d = dir * math.cos(a) + (side * math.cos(phi) + up * math.sin(phi)) * math.sin(a)
		end
		-- the drops fall as they fly: a straight first stretch, then bending down
		local L1 = reach * U.RandRange(0.35, 0.55)
		plumeTr.start = start
		plumeTr.endpos = start + d * L1
		local tr = util.TraceLine(plumeTr)
		-- (1.26.8) starting inside something that is not the world (a ragdoll that is not known yet, a hat, a prop worn
		-- by the body): leave it out and go on, the blood is already outside the body
		local tries = 0
		while tr.StartSolid and not tr.HitWorld and IsValid(tr.Entity) and tries < 2 do
			tries = tries + 1
			plumeFlt[#plumeFlt + 1] = tr.Entity
			tr = util.TraceLine(plumeTr)
		end
		local dist = tr.Fraction * L1
		local dd = d
		if not tr.Hit then
			dd = (d - Vector(0, 0, U.RandRange(0.15, 0.45))):GetNormalized()
			plumeTr.start = tr.HitPos
			plumeTr.endpos = tr.HitPos + dd * (reach - L1)
			tr = util.TraceLine(plumeTr)
			dist = L1 + tr.Fraction * (reach - L1)
		end
		F.plumeStats.streams = F.plumeStats.streams + 1
		if tr.Hit and not tr.HitSky and not tr.StartSolid then
			local f = math.Clamp(dist / reach, 0, 1)
			local hn, hp = Vector(tr.HitNormal), Vector(tr.HitPos)
			local cosI = math.abs(dd:Dot(hn))
			local elong = math.Clamp(1 / math.max(cosI, 0.16), 1, 4.5)
			local centre = i == 1 and prof.burst
			local R = math.Clamp((prof.rMax + (prof.rMin - prof.rMax) * f) * U.RandRange(0.45, 1.1) * sz * rk * (centre and 1.25 or 1), 0.15, 3.5)
			local vol = F.WetVol(R, elong * elong, F.Volume(R * 2.2) * (1.1 - 0.5 * f) * (centre and 1.3 or 1))
			local vel = dd * ((650 - 350 * f) * math.Clamp(sp, 0.5, 2))
			local extra = { spines = math.floor(8 + 16 * (1 - f) * e), K = 150 + 90 * (1 - f) * e, flags = 0, btype = btype, oxy = oxy }
			local hitEnt = tr.Entity
			local spin = U.RandRange(-30, 30)
			local delay = math.Clamp(dist / (1100 + 400 * e) + U.RandRange(0.005, 0.03), 0.01, 0.6)
			local sats = (f < 0.55 and R > 0.7) and math.random(1, centre and 5 or 3) or 0
			-- the main stream (and a second one of a sniper round) lays one of the measured spatter patterns where it
			-- lands, bigger the further it flew
			local patR = (prof.patR and f < 0.8 and (i == 1 or (i == 2 and prof == F.BALLISTIC.sniper)))
				and prof.patR * (0.6 + 0.7 * f) * rk * sz * (i == 1 and 1 or 0.7) or nil
			-- (1.26.7) Crisis Response splats: the first streams lay a CRB splat each (the main one bigger), the rest
			-- nothing; the main stream keeps a small wet stain
			local splat = prof.splats and F.SplatMode(btype)
			local splatU = splat and i <= prof.splats
				and prof.splatR * (0.75 + 0.5 * f) * rk * sz * (i == 1 and U.RandRange(0.85, 1.15) or U.RandRange(0.45, 0.7)) or nil
			timer.Simple(delay, function()
				if not G.Surfaces or not G.Surfaces.Impact then return end
				F.plumeStats.landed = F.plumeStats.landed + 1
				local onEnt = IsValid(hitEnt) and not hitEnt:IsWorld() and not G.Surfaces.IsGround(hitEnt)
				if splat and F.SplatTakes(onEnt and hitEnt or nil, btype) and not IsBody(hitEnt) then
					if splatU and F.CRBDecal(hp + hn * 0.1, hn, splatU, onEnt and hitEnt or nil, btype, dd) then
						F.plumeStats.splats = (F.plumeStats.splats or 0) + 1
					end
					if i == 1 then
						local Rw = math.min(R * 0.6, 1.0)
						local vw = F.WetVol(Rw, elong * elong, F.Volume(Rw * 2.2) * (1.1 - 0.5 * f))
						if onEnt then
							if G.Entities and G.Entities.Impact then G.Entities.Impact(hitEnt, hp, hn, vel, Rw, vw, 0, spin, elong, 0.22, nil, extra) end
						elseif math.abs(hn.z) < 0.7 and F.ForensicOn() then
							-- (1.26.10h) on walls: a forensic spatter set (F close, B exit spray, E far) instead of the big
							-- streaked wet blob of the main stream (GHM's screenshot: "what are these ugly textures")
							if not F.Forensic((centre and f < 0.3) and "F" or (f > 0.7 and "E" or "B"), hp, hn, dd, math.max(Rw, F.FORENSIC_MIN_R), btype, oxy, tr, e) then
								local Rs, vs, es = F.ForensicSmall(Rw, vw, extra)
								G.Surfaces.Impact(hp, hn, vel, Rs, vs, 0, spin, math.min(elong, 1.6), 0.22, tr, oxy, btype, es)
							end
						else
							G.Surfaces.Impact(hp, hn, vel, Rw, vw, 0, spin, elong, 0.22, tr, oxy, btype, extra)
						end
					end
					return
				end
				if patR and F.Spatter(hp, hn, dd, patR, btype, oxy, tr, e, onEnt and hitEnt or nil) > 0 then return end
				if onEnt then
					if G.Entities and G.Entities.Impact then G.Entities.Impact(hitEnt, hp, hn, vel, R, vol, 0, spin, elong, 0.22, nil, extra) end
					return
				end
				-- (1.26.10h) a forensic spatter set instead of the big streaked splat: F the heavy main stream close by, E far,
				-- B (exit spray) the rest
				if R >= F.FORENSIC_MIN_R and F.ForensicOn() then
					local set = (centre and f < 0.3) and "F" or (f > 0.7 and "E" or "B")
					if F.Forensic(set, hp, hn, dd, R, btype, oxy, tr, e) then return end
					local Rs, vs, es = F.ForensicSmall(R, vol, extra)
					G.Surfaces.Impact(hp, hn, vel, Rs, vs, 0, spin, math.min(elong, 1.6), 0.22, tr, oxy, btype, es)
					return
				end
				G.Surfaces.Impact(hp, hn, vel, R, vol, 0, spin, elong, 0.22, tr, oxy, btype, extra)
				if sats > 0 then
					local t1 = math.abs(hn.z) < 0.9 and Vector(0, 0, 1):Cross(hn) or Vector(1, 0, 0):Cross(hn)
					t1:Normalize()
					local t2 = hn:Cross(t1)
					for _ = 1, sats do
						local a = math.random() * 6.2831853
						local o = t1 * math.cos(a) + t2 * math.sin(a)
						local sv, sr, sst = o * 120 + vel * 0.3, math.max(R * U.RandRange(0.18, 0.35), 0.12), U.RandRange(1.1, 2.0)
						local se = sst / math.max(math.abs(sv:GetNormalized():Dot(hn)), 0.12)
						G.Surfaces.Impact(hp + o * (R * U.RandRange(1.4, 2.6)), hn, sv, sr, F.WetVol(sr, se, vol * 0.05), 0, U.RandRange(-40, 40), sst, 0.24, tr, oxy, btype)
					end
				end
			end)
		end
	end
	-- heavy rounds tear out a few chunks of blood that fly on fast
	if (prof.chunks or 0) > 0 and G.Particles and G.Particles.Spawn then
		for _ = 1, math.floor(prof.chunks * e * math.min(mul, 2) + math.random()) do
			local d = F.ConeAsym(dir, 10 * spread, 12 * spread, 10 * spread)
			spawnDrop(start, d * U.RandRange(9, 18) * F.UPM * sp, F.Diameter("chunk", sz), ent, F.oxy * 0.95, ChunkType(btype), 0.12, U.RandRange(1.2, 1.8))
		end
	end
	return n
end

function F.BackSpatter(ent, pos, nrm, bdir, S, btype, mul)
	mul = mul or 1
	if mul <= 0.001 then return end
	local sz, sp, spread, amt = cvs()
	local back = -bdir
	local vmax = math.max(8, 24 + gauss() * 6) * F.UPM * sp
	local n, dk = Thin(math.floor((10 + 20 * math.min(S, 2.5)) * mul * amt + 0.5))
	for i = 1, n do
		local d = F.ConeAsym(back, 57 * spread, 30 * spread, 50 * spread)
		local dmm = F.Diameter("gunshotBack", sz) * dk
		local v = vmax * (0.25 + 0.75 * math.random() ^ 0.7) * math.Clamp((0.4 / dmm) ^ 0.2, 0.7, 1.3)
		spawnDrop(pos + nrm * 0.4 + d * U.RandRange(0, 0.4), d * v, dmm, ent, F.oxy, btype, 0.08, U.RandRange(1, 1.5))
	end
	F.DirectConeMist(pos + nrm * 0.5, back, 32, 95, math.Clamp(math.floor(3 + 3 * S * mul), 2, 8), 0.55 * math.min(S, 2) * mul, ent, F.oxy, btype, true, "A")
	if G.cv.mist:GetBool() then
		local m = 0.35 * math.min(S, 2.5) * mul
		F.MistCloud(pos + nrm * 0.5, back, 12 * F.UPM * sp, 0.6 * spread, m, btype)
		F.MistDeposit(pos + nrm * 0.5, back, 0.55 * spread, 22 * S * mul, 32, ent, F.oxy, btype)
	end
end

function F.ForwardSpatter(ent, pos, nrm, bdir, S, btype, mul)
	mul = mul or 1
	if mul <= 0.001 then return end
	local sz, sp, spread, amt = cvs()
	local vmax = math.max(20, 47 + gauss() * 5) * F.UPM * sp
	local n, dk = Thin(math.floor((24 + 46 * math.min(S, 2.5)) * mul * amt + 0.5))
	for i = 1, n do
		local d = F.ConeAsym(bdir, 27 * spread, 28 * spread, 26 * spread)
		local dmm = F.Diameter("gunshotFwd", sz) * dk
		local v = vmax * (0.2 + 0.8 * math.random() ^ 0.6) * math.Clamp((0.5 / dmm) ^ 0.2, 0.7, 1.3)
		spawnDrop(pos + nrm * 0.4 + d * U.RandRange(0, 0.6), d * v, dmm, ent, F.oxy, BigDropType(btype, dmm), 0.12, U.RandRange(1.0, 1.3))
	end
	local chunks = math.floor((1 + 2 * math.min(S, 1.5)) * mul + math.random())
	for i = 1, chunks do
		local d = F.ConeAsym(bdir, 15 * spread, 18 * spread, 14 * spread)
		spawnDrop(pos + nrm * 0.4, d * vmax * U.RandRange(0.1, 0.26), F.Diameter("chunk", sz), ent, F.oxy * 0.95, ChunkType(btype), 0.12, U.RandRange(1.0, 1.5))
	end
	F.DirectConeMist(pos + nrm * 0.5, bdir, 24, 165, math.Clamp(math.floor(3 + 3 * S * mul), 3, 9), 0.95 * math.min(S, 2.2) * mul, ent, F.oxy, btype, true, "B")
	if G.cv.mist:GetBool() then
		local m = 0.9 * math.min(S, 2.5) * mul
		F.MistCloud(pos + nrm * 0.5, bdir, 25 * F.UPM * sp, 0.4 * spread, m, btype, false, 1.4)
		F.MistDeposit(pos + nrm * 0.5, bdir, 0.4 * spread, 70 * S * mul, 52, ent, F.oxy, btype)
	end
end

function F.BlastSpatter(ent, sites, d, P, btype, mul, oxy)
	mul = mul or 1
	if mul <= 0.001 or #sites == 0 then return end
	local sz, sp, spread, amt = cvs()
	oxy = oxy or 0.75
	local dh = Vector(d.x, d.y, 0)
	if dh:LengthSqr() < 0.04 then dh = Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) end
	dh:Normalize()
	local up = Vector(0, 0, 1)
	local side = dh:Cross(up)
	side:Normalize()
	local axis = (dh + up * (0.16 + 0.55 * math.Clamp(d.z, 0, 1))):GetNormalized()
	local tot = 0
	for _, s in ipairs(sites) do tot = tot + s.w end
	local function pick()
		local r = math.random() * tot
		for _, s in ipairs(sites) do r = r - s.w if r <= 0 then return s end end
		return sites[#sites]
	end
	local Pc = math.min(P, 2.8)
	local c0 = sites[1].pos
	if G.Surfaces and G.Surfaces.Impact then
		local gtr = util.TraceLine({ start = c0 + up * 16, endpos = c0 - up * 165, mask = MASK_SOLID_BRUSHONLY })
		if gtr.Hit and not gtr.HitSky and not gtr.StartSolid and gtr.HitNormal.z > 0.45 then
			local poolR = math.Clamp((2.8 + 1.5 * Pc) * sz, 2.0, 6.8)
			local poolVol = 480 * Pc * mul
			local cExtra = { spines = math.floor(16 + 8 * Pc), K = 190, flags = 0, btype = btype, oxy = oxy }
			local gPos, gNrm = Vector(gtr.HitPos), Vector(gtr.HitNormal)
			local gDelay = math.Clamp(math.max(c0.z - gPos.z, 8) / 380 + 0.025, 0.025, 0.14)
			timer.Simple(gDelay, function()
				if not G.Surfaces or not G.Surfaces.Impact then return end
				G.Surfaces.Impact(gPos, gNrm, dh * 140, math.Clamp(poolR * 0.24, 0.45, 1.35), poolVol * 0.14, 0, U.RandRange(-20, 20), 1.35, 0.28, gtr, oxy, btype, cExtra)
				G.Surfaces.Impact(gPos, gNrm, dh * 45, poolR, poolVol, 1, 0, 1.15, 0.04, gtr, oxy * 0.9, btype)
			end)
			for sat = 1, 6 do
				local sa = math.rad(U.RandRange(-85, 85))
				local sdir = (dh * math.cos(sa) + side * math.sin(sa)):GetNormalized()
				local sdist = poolR * U.RandRange(0.9, 2.2)
				local str = util.TraceLine({ start = gPos + sdir * sdist + up * 20, endpos = gPos + sdir * sdist - up * 48, mask = MASK_SOLID_BRUSHONLY })
				if str.Hit and not str.HitSky and not str.StartSolid then
					local sPos, sNrm = Vector(str.HitPos), Vector(str.HitNormal)
					local sR = poolR * U.RandRange(0.20, 0.36)
					local sSpin = U.RandRange(-30, 30)
					local sElong = U.RandRange(1.8, 2.9)
					local sDelay = math.Clamp(sdist / 360 + U.RandRange(0.03, 0.09), 0.03, 0.25)
					timer.Simple(sDelay, function()
						if G.Surfaces and G.Surfaces.Impact then
							G.Surfaces.Impact(sPos, sNrm, sdir * 210, sR, poolVol * 0.14, 0, sSpin, sElong, 0.32, str, oxy, btype, cExtra)
						end
					end)
				end
			end
		end
		local nStar = math.Clamp(math.floor((10 + 6 * Pc) * math.min(mul, 2) + 0.5), 8, 18)
		for r = 1, nStar do
			local isFwd = (r <= math.ceil(nStar * 0.72))
			local angDeg = isFwd and U.RandRange(-68, 68) * spread or (180 + U.RandRange(-65, 65) * spread)
			local ar = math.rad(angDeg)
			local rayH = (dh * math.cos(ar) + side * math.sin(ar)):GetNormalized()
			local maxDist = (isFwd and U.RandRange(95, 225) or U.RandRange(48, 120)) * math.Clamp(0.75 + 0.25 * Pc, 0.75, 1.45)
			local losTr = util.TraceLine({ start = c0 + up * 8, endpos = c0 + up * 8 + rayH * maxDist, mask = MASK_SOLID_BRUSHONLY })
			local reachDist = losTr.Hit and math.max(losTr.Fraction * maxDist - 6, 12) or maxDist
			local nSegs = isFwd and math.random(3, 5) or math.random(2, 3)
			for seg = 1, nSegs do
				local t = seg / nSegs
				local dStep = 14 + (reachDist - 14) * (t ^ 0.85)
				local probe = c0 + rayH * dStep
				local ftr = util.TraceLine({ start = probe + up * 24, endpos = probe - up * 165, mask = MASK_SOLID_BRUSHONLY })
				if ftr.Hit and not ftr.HitSky and not ftr.StartSolid and ftr.HitNormal.z > 0.45 then
					local streakR = math.Clamp((1.45 - 0.20 * seg) * math.sqrt(Pc) * sz, 0.36, 2.6)
					local streakElong = U.RandRange(2.1, 3.6) * (isFwd and 1.15 or 0.85)
					local streakVol = F.Volume(streakR * 2.2) * (1.25 - 0.16 * seg) * mul
					local extra = { spines = math.floor(14 + 10 * Pc), K = 190, flags = 0, btype = btype, oxy = oxy }
					local fPos, fNrm = Vector(ftr.HitPos), Vector(ftr.HitNormal)
					local fSpin = U.RandRange(-25, 25)
					local fDelay = math.Clamp(dStep / (420 + 90 * Pc) + U.RandRange(0.015, 0.055), 0.02, 0.34)
					timer.Simple(fDelay, function()
						if G.Surfaces and G.Surfaces.Impact then
							G.Surfaces.Impact(fPos, fNrm, rayH * (240 + 80 * Pc), streakR, streakVol, 0, fSpin, streakElong, 0.36, ftr, oxy, btype, extra)
						end
					end)
				end
			end
			local wallPitch = math.rad(U.RandRange(-12, 28))
			local wallDir = (rayH * math.cos(wallPitch) + up * math.sin(wallPitch)):GetNormalized()
			local wtr = util.TraceLine({ start = c0 + up * U.RandRange(-10, 18), endpos = c0 + wallDir * (maxDist * 1.25), mask = MASK_SOLID_BRUSHONLY })
			if wtr.Hit and not wtr.HitSky and not wtr.StartSolid and math.abs(wtr.HitNormal.z) < 0.68 then
				local wDist = wtr.Fraction * (maxDist * 1.25)
				local wFall = math.Clamp(1 - wDist / 280, 0.25, 1)
				local wR = math.Clamp((1.45 + 1.25 * Pc * wFall) * sz, 0.48, 3.9)
				local wVol = F.Volume(wR * 2.5) * (1.2 + 0.65 * Pc) * mul
				local wElong = U.RandRange(1.5, 2.8)
				local extra = { spines = 22, K = 230, flags = 0, btype = btype, oxy = oxy }
				local wPos, wNrm = Vector(wtr.HitPos), Vector(wtr.HitNormal)
				local wSpin = U.RandRange(-35, 35)
				local wSide = wNrm:Cross(up):GetNormalized()
				local nSat = math.random(2, 4)
				local wDelay = math.Clamp(wDist / 520 + U.RandRange(0.01, 0.04), 0.015, 0.28)
				timer.Simple(wDelay, function()
					if not G.Surfaces or not G.Surfaces.Impact then return end
					-- (1.26.10h) a forensic spatter set instead of the big splat and its satellites: F close by, C further away
					if F.ForensicOn() then
						if F.Forensic(wDist < 120 and "F" or "C", wPos, wNrm, wallDir, wR, btype, oxy, wtr, math.min(Pc, 1.6)) then return end
						local Rs, vs, es = F.ForensicSmall(wR, wVol, extra)
						G.Surfaces.Impact(wPos, wNrm, wallDir * 280, Rs, vs, 0, wSpin, 1.3, 0.45, wtr, oxy, btype, es)
						return
					end
					G.Surfaces.Impact(wPos, wNrm, wallDir * 280, wR, wVol, 0, wSpin, wElong, 0.45, wtr, oxy, btype, extra)
					-- (1.26.6) and one of the measured spatter patterns round it
					if wDist < 220 and math.random() < 0.6 then F.Spatter(wPos, wNrm, wallDir, math.Clamp(wR * 6, 8, 30), btype, oxy, wtr, math.min(Pc, 1.6)) end
					for sat = 1, nSat do
						local spOff = wSide * U.RandRange(-wR * 2.2, wR * 2.2) + up * U.RandRange(-wR * 1.8, wR * 2.2)
						local spPos = wPos + spOff
						G.Surfaces.Impact(spPos, wNrm, (wallDir + spOff:GetNormalized() * 0.35):GetNormalized() * 210, wR * U.RandRange(0.26, 0.48), wVol * 0.14, 0, U.RandRange(-40, 40), U.RandRange(1.6, 2.6), 0.42, wtr, oxy, btype)
					end
				end)
			end
		end
		local nCeil = math.Clamp(math.floor((3 + 2 * Pc) * math.min(mul, 1.8) + 0.5), 2, 7)
		for cIdx = 1, nCeil do
			local cAng = math.rad(U.RandRange(-70, 70) * spread)
			local cPitch = math.rad(U.RandRange(38, 82))
			local cH = (dh * math.cos(cAng) + side * math.sin(cAng)):GetNormalized()
			local cDir = (cH * math.cos(cPitch) + up * math.sin(cPitch)):GetNormalized()
			local ctr = util.TraceLine({ start = c0 + up * 10, endpos = c0 + cDir * 220, mask = MASK_SOLID_BRUSHONLY })
			if ctr.Hit and not ctr.HitSky and not ctr.StartSolid and ctr.HitNormal.z < -0.35 then
				local cR = math.Clamp((1.15 + 0.95 * Pc) * sz, 0.45, 3.2)
				local cVol = F.Volume(cR * 2.3) * Pc * mul
				local hp = Vector(ctr.HitPos)
				local hn = Vector(ctr.HitNormal)
				local cDelay = math.Clamp((ctr.Fraction * 220) / 480 + U.RandRange(0.01, 0.04), 0.015, 0.25)
				timer.Simple(cDelay, function()
					if G.Surfaces and G.Surfaces.Impact then
						G.Surfaces.Impact(hp, hn, cDir * 220, cR, cVol, 0, U.RandRange(-35, 35), U.RandRange(1.2, 2.0), 0.44, ctr, oxy, btype)
					end
					if G.Particles and G.Particles.Hang then
						G.Particles.Hang(hp + hn * 0.25, Vector(0, 0, -4), math.min(cVol * 0.45, 180), nil, oxy, btype)
					end
				end)
				local nDrips = math.random(2, 4)
				for dIdx = 1, nDrips do
					timer.Simple(cDelay + U.RandRange(0.3, 2.2) * dIdx * 0.5, function()
						if not G.Particles or not G.Particles.Spawn then return end
						local dmm = F.Diameter("drip", sz)
						spawnDrop(hp + hn * 0.4 + VectorRand() * (cR * 0.6), Vector(0, 0, -12), dmm, nil, oxy * 0.9, btype, 0, 1.65)
					end)
				end
			end
		end
	end
	local vmax = math.max(14, 29 + gauss() * 4) * F.UPM * sp * math.Clamp(0.75 + 0.22 * Pc, 0.75, 1.35)
	local nFan = math.floor((65 + 115 * Pc) * mul * amt + 0.5)
	local nGround = math.floor((24 + 44 * Pc) * mul * amt + 0.5)
	local nClump = math.floor((6 + 14 * Pc) * mul + math.random())
	local nBack = math.floor(nFan * 0.14 + 0.5)
	local function src(s) return s.pos + d * 6 + VectorRand() * 2.5 end
	for _ = 1, nFan do
		local s = pick()
		local dirn = F.ConeAsym(axis, 32 * spread, 22 * spread, 58 * spread)
		local dmm = F.Diameter("blast", sz)
		local v = vmax * (0.2 + 0.8 * math.random() ^ 0.65) * math.Clamp((0.8 / dmm) ^ 0.25, 0.65, 1.45)
		spawnDrop(src(s), dirn * v, dmm, ent, oxy, btype, 0.25, U.RandRange(1.4, 2.6))
	end
	for _ = 1, nGround do
		local s = pick()
		local a = math.Rand(0, 2 * math.pi)
		local h = (Vector(math.cos(a), math.sin(a), 0) * 0.55 + dh * 1.05):GetNormalized()
		local e = math.rad(math.Rand(6, 32))
		local dirn = (h * math.cos(e) - up * math.sin(e)):GetNormalized()
		local dmmH = F.Diameter("blastHeavy", sz)
		spawnDrop(src(s), dirn * U.RandRange(6, 15) * F.UPM * sp, dmmH, ent, oxy, BigDropType(btype, dmmH), 0.25, U.RandRange(1.7, 2.8))
	end
	for _ = 1, nClump do
		local s = pick()
		local dirn = F.ConeAsym(axis, 38 * spread, 15 * spread, 42 * spread)
		spawnDrop(src(s), dirn * U.RandRange(6, 15) * F.UPM * sp, F.Diameter("blastClump", sz), ent, oxy * 0.95, ChunkType(btype), 0.25, U.RandRange(2.0, 3.4))
	end
	local nSheet = math.floor((14 + 16 * Pc) * math.min(mul, 2) + math.random())
	for _ = 1, nSheet do
		local s = pick()
		local el = math.rad(math.Rand(-48, 16))
		local az = math.rad(math.Clamp(gauss() * 28, -68, 68) * spread)
		local dirn = ((dh * math.cos(az) + side * math.sin(az)) * math.cos(el) + up * math.sin(el)):GetNormalized()
		local start = s.pos + d * 6
		local tr = util.TraceLine({ start = start, endpos = start + dirn * 290, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.HitSky and not tr.StartSolid and G.Surfaces and G.Surfaces.Impact then
			local speed = U.RandRange(7, 14) * F.UPM * sp
			local vel = dirn * speed
			local rmm = U.RandRange(3.2, 5.4) * sz
			local hp, hn = Vector(tr.HitPos), Vector(tr.HitNormal)
			local R, spines, K = F.Stain(rmm, vel, hn)
			local shVol = F.Volume(2.1 * rmm) * mul
			local shSpin = U.RandRange(-40, 40)
			local shElong = U.RandRange(1.6, 2.7)
			local shExtra = { spines = spines, K = K, flags = 0, btype = btype, oxy = oxy }
			local shDelay = math.Clamp((tr.Fraction * 290) / math.max(speed, 220) + U.RandRange(0.01, 0.05), 0.015, 0.35)
			local shWall = math.abs(hn.z) < 0.7
			local shDist = tr.Fraction * 290
			timer.Simple(shDelay, function()
				if G.Surfaces and G.Surfaces.Impact then
					-- (1.26.10h) on walls: a forensic spatter set (F close, C further) or a small drop instead of the big sheet blob
					if shWall and R >= F.FORENSIC_MIN_R and F.ForensicOn() then
						if F.Forensic(shDist < 120 and "F" or "C", hp, hn, dirn, R, btype, oxy, tr, math.min(Pc, 1.6)) then return end
						local Rs, vs, es = F.ForensicSmall(R, shVol, shExtra)
						G.Surfaces.Impact(hp, hn, vel, Rs, vs, 0, shSpin, 1.3, 0.40, tr, oxy, btype, es)
						return
					end
					G.Surfaces.Impact(hp, hn, vel, R, shVol, 0, shSpin, shElong, 0.40, tr, oxy, btype, shExtra)
				end
			end)
		end
	end
	for _ = 1, nBack do
		local s = pick()
		local dirn = F.ConeAsym(-axis, 40 * spread, 20 * spread, 60 * spread)
		spawnDrop(s.pos - d * 4, dirn * U.RandRange(3, 8) * F.UPM * sp, F.Diameter("blast", sz), ent, oxy, btype, 0.2, U.RandRange(1.1, 1.8))
	end
	if G.cv.mist:GetBool() then
		local c = sites[1].pos + d * 6
		F.MistCloud(c, axis, 24 * F.UPM * sp, 1.0 * spread, math.min(2.4 * Pc * mul, 4.5), btype, false, 2.2)
		F.MistDeposit(c, axis, 0.75 * spread, 310 * Pc * mul, 135, ent, oxy, btype)
		F.MistDeposit(c, (dh - up * 0.7):GetNormalized(), 0.8 * spread, 210 * Pc * mul, 95, ent, oxy, btype)
	end
end

function F.BluntSpatter(ent, pos, nrm, bdir, S, btype, bloodML, mul)
	mul = mul or 1
	if bloodML <= 0.02 or mul <= 0.001 then return 0 end
	local sz, sp, spread, amt = cvs()
	local n = math.floor(math.Clamp(4 + 10 * S * math.min(bloodML, 2), 3, 40) * mul * amt + 0.5)
	local axis = (nrm - bdir * 0.35):GetNormalized()
	local used = 0
	for i = 1, n do
		local d = U.ConeDir(axis, math.rad(70) * spread)
		local dmm = F.Diameter("blunt", sz)
		used = used + F.Volume(dmm)
		spawnDrop(pos + nrm * 0.5, d * U.RandRange(1.5, 7.6) * F.UPM * sp, dmm, ent, F.oxy, BigDropType(btype, dmm), 0.1, U.RandRange(1, 1.6))
	end
	F.DirectConeMist(pos + nrm * 0.5, axis, 42, 85, math.Clamp(math.floor(2 + 3 * S * mul), 2, 7), 0.45 * math.min(S, 2) * mul, ent, F.oxy, btype)
	return used
end

function F.CastOff(attacker, hitPos, S, btype, bloodML)
	if not IsValid(attacker) or bloodML <= 0.02 then return end
	local sz, sp, spread, amt = cvs()
	local eye = attacker.EyePos and attacker:EyePos() or attacker:WorldSpaceCenter()
	local fwd = (attacker.EyeAngles and attacker:EyeAngles() or attacker:GetAngles()):Forward()
	local right = fwd:Cross(Vector(0, 0, 1)) right:Normalize()
	local pivot = eye - Vector(0, 0, 8) + right * 5
	local a = hitPos - pivot
	local rad = math.Clamp(a:Length(), 18, 48)
	a:Normalize()
	local overhead = hitPos.z < pivot.z - 4
	local b = overhead and Vector(0, 0, 1) or right
	b = (b - a * b:Dot(a)) b:Normalize()
	local tipSpeed = U.RandRange(6, 14) * F.UPM * sp
	local n = math.floor(math.Clamp(3 + 8 * bloodML, 3, 18) * amt + 0.5)
	local sweep = math.rad(U.RandRange(120, 160))
	local dur = U.RandRange(0.22, 0.34)
	F.CastOffArc(hitPos, fwd, b, 135, math.Clamp(math.floor(4 + 3 * S), 4, 10), math.Clamp(0.55 * S, 0.35, 1.5), attacker, 0.85, btype)
	for i = 1, n do
		local t = (i - 0.5) / n
		timer.Simple(0.05 + t * dur, function()
			if not IsValid(attacker) then return end
			local th = t * sweep
			local p = pivot + (a * math.cos(th) + b * math.sin(th)) * rad
			local tang = (b * math.cos(th) - a * math.sin(th))
			local d = (tang + VectorRand() * 0.06 * spread):GetNormalized()
			spawnDrop(p, d * tipSpeed * U.RandRange(0.85, 1.1) + attacker:GetVelocity(), F.Diameter("castoff", sz),
				attacker, 0.85, btype, 0.3, U.RandRange(1.3, 2.2))
		end)
	end
end

function F.ArterialPulse(phase)
	local p = math.exp(-((phase - 0.14) / 0.1) ^ 2) + 0.3 * math.exp(-((phase - 0.42) / 0.08) ^ 2)
	return math.min(p, 1)
end

function F.Arterial(lostML, phase, strength)
	local vol = math.Clamp(1 - lostML / 2200, 0.15, 1)
	local sys = 16000 * vol ^ 1.3
	local dia = 10700 * vol ^ 1.5
	local pulse = F.ArterialPulse(phase)
	local P = dia * 0.4 + (sys - dia * 0.4) * pulse
	local v = 0.8 * math.sqrt(2 * P / F.RHO) * math.min(math.sqrt(strength or 1), 1.4)
	local hz = (1.4 + 1.0 * (1 - vol))
	return v * F.UPM, P / 16000, hz
end

function F.Expirated(ent, pos, nrm, S, btype, base)
	local sz, sp, spread, amt = cvs()
	local n = math.floor((12 + 20 * math.min(S, 2)) * amt + 0.5)
	for i = 1, n do
		local d = U.ConeDir(nrm, 0.45 * spread)
		local dmm = F.Diameter("expirated", sz)
		spawnDrop(pos + nrm * 0.4, d * U.RandRange(3, 12) * F.UPM * sp + (base or vector_origin), dmm, ent, 0.95, btype, 0.2, 1, 1)
	end
	if G.cv.mist:GetBool() then
		F.MistCloud(pos + nrm * 0.5, nrm, 6 * F.UPM * sp, 0.5, 0.45 * math.min(S, 2), btype, true)
		F.MistDeposit(pos + nrm * 0.5, nrm, 0.5, 12 * S, 24, ent, 0.95, btype, true)
	end
end

-- (1.26.8) the same from the speed into the surface (u/s, plain number): the landings work in numbers
function F.StainVn(rmm, vnAbs)
	local d = 2 * rmm / 1000
	local vn = math.max(vnAbs * 0.01905, 0.3)
	local Re = F.RHO * vn * d / F.MU
	local We = F.RHO * vn * vn * d / F.SIGMA
	local D = math.max(1.2 * d, 0.5 * d * Re ^ 0.25)
	local N = math.floor(math.Clamp(1.14 * math.sqrt(We), 0, 60))
	local K = math.sqrt(We) * Re ^ 0.25
	return D * 0.5 * F.UPM, N, K
end
function F.Stain(rmm, vel, n)
	local d = 2 * rmm / 1000
	local vn = math.abs(vel:Dot(n)) * 0.01905
	vn = math.max(vn, 0.3)
	local Re = F.RHO * vn * d / F.MU
	local We = F.RHO * vn * vn * d / F.SIGMA
	local D = math.max(1.2 * d, 0.5 * d * Re ^ 0.25)
	local N = math.floor(math.Clamp(1.14 * math.sqrt(We), 0, 60))
	local K = math.sqrt(We) * Re ^ 0.25
	return D * 0.5 * F.UPM, N, K
end
