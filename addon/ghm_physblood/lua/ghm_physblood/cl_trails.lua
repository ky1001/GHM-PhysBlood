local G = GHMPB
G.Trails = G.Trails or {}
local T = G.Trails
local U = G.U
T.stats = T.stats or { drops = 0, gushes = 0, smudges = 0 }

local function Amount()
	local cv = G.cv.bleedtrail
	return cv and cv:GetFloat() or 1
end

local DOWN = Vector(0, 0, -1)
local MIN_SPEED = 22
local wallTr = { mask = MASK_SOLID_BRUSHONLY }
local chainTr = { mask = MASK_SOLID_BRUSHONLY }

function T.Take(b, ent, e, pos, nrm, vel, free, dt)
	local amt = Amount()
	if amt <= 0 or free <= 0 or not pos then return 0 end
	local vx, vy, vz = vel.x, vel.y, vel.z
	local sp = math.sqrt(vx * vx + vy * vy + vz * vz * 0.35)
	local isRag = b.dead or ent:IsRagdoll()
	-- (1.26.9d) a body carried or dragged slowly drips too (was: only above 65 u/s)
	if isRag and sp < 28 then return 0 end
	if sp < MIN_SPEED then e.trailPh = nil return 0 end
	local artery = e.kind == "artery"
	local share
	if isRag then share = math.Clamp(0.35 + sp / 600, 0.35, 0.78)
	elseif artery then share = math.Clamp(0.22 + sp / 850, 0.22, 0.55)
	else share = math.Clamp(0.28 + sp / 650, 0.28, 0.68) end
	share = math.min(share * amt, 0.9)
	local take = free * share
	e.trailAcc = (e.trailAcc or 0) + take
	local Fo = G.Forensic
	local P = G.Particles
	local btype = b.btype or 0
	local oxy = e.oxy or 0.8
	local now = CurTime()
	if not isRag and G.Surfaces and G.Surfaces.Impact and now > (b.wallTouchT or 0) and sp > 28 then
		b.wallTouchT = now + 0.45
		local hdir = Vector(vx, vy, 0):GetNormalized()
		local side = hdir:Cross(Vector(0, 0, 1))
		for _, sgn in ipairs({ -1, 1 }) do
			wallTr.start = pos
			wallTr.endpos = pos + side * (sgn * 26)
			local tr = util.TraceLine(wallTr)
			if tr.Hit and not tr.HitSky and not tr.StartSolid and math.abs(tr.HitNormal.z) < 0.35 then
				G.Surfaces.Impact(tr.HitPos, tr.HitNormal, hdir * math.min(sp * 0.4, 85) + DOWN * 18, U.RandRange(1.8, 2.8), 65 * amt, 3, 0, U.RandRange(1.8, 2.8), 0.32, tr, oxy, btype)
				T.stats.smudges = (T.stats.smudges or 0) + 1
				break
			end
		end
	end
	local gush = false
	if artery and e.phase then
		local prev = e.trailPh or e.phase
		gush = prev < 0.1 and e.phase >= 0.1
		e.trailPh = e.phase
	end
	local guard = 0
	local function drop(dmm, spread, down)
		local v = Fo and Fo.Volume(dmm) or 0.5236 * dmm * dmm * dmm
		if e.trailAcc < v * 0.6 then return false end
		e.trailAcc = math.max(e.trailAcc - v, 0)
		local o = pos + nrm * 0.6 + DOWN * U.RandRange(0.5, 3)
		local dv = vel * U.RandRange(0.85, 1.05) + nrm * U.RandRange(4, 18) * spread + DOWN * (down or U.RandRange(4, 22))
			+ VectorRand() * (6 * spread)
		P.Spawn({ pos = o, vel = dv, r = dmm * 0.5, owner = ent, oxy = oxy, btype = btype, spin = U.RandRange(-25, 25),
			stretch = isRag and U.RandRange(1.5, 2.4) or U.RandRange(1.1, 1.7), ownerGrace = 0.25 })
		T.stats.drops = T.stats.drops + 1
		return true
	end
	if gush or (isRag and sp > 180 and math.random() < 0.45) then
		local extra = math.min(free * 0.18, 450, math.max(free - take, 0))
		take = take + extra
		e.trailAcc = e.trailAcc + extra
		local n = math.random(3, 7)
		for _ = 1, n do
			if not drop(Fo and Fo.Diameter("arterial", 0.85) or 3.2, 2.5, U.RandRange(10, 60)) then break end
		end
		T.stats.gushes = T.stats.gushes + 1
	end
	-- (1.26.9d) drip chains: a bleeding body moved at walking pace leaves a line of drops that land close enough to run into
	-- each other - a chain of joined blobs along its path, each stretched a little along the way it moved (a drop is laid
	-- every ~3 cm of travel while there is blood for it; with less blood the chain breaks up into a dotted line)
	if sp < 220 and G.Surfaces and G.Surfaces.Impact then
		e.chainD = (e.chainD or 0) + sp * dt
		local step = isRag and 1.6 or 2.1
		if e.chainD >= step then
			e.chainD = math.min(e.chainD - step, step)
			local blobV = (artery and 150 or 110) * math.Clamp(amt, 0.5, 2)
			if e.trailAcc >= blobV * 0.7 then
				chainTr.start = pos
				chainTr.endpos = pos + DOWN * 64
				local tr = util.TraceLine(chainTr)
				if tr.Hit and not tr.StartSolid and not tr.HitSky and tr.HitNormal.z > 0.6 then
					local hv = Vector(vx, vy, 0)
					if hv:LengthSqr() > 1 then hv:Normalize() end
					G.Surfaces.Impact(tr.HitPos, tr.HitNormal, hv * math.min(sp * 1.4, 160) + DOWN * 220, U.RandRange(0.5, 0.75), blobV, 0,
						U.RandRange(-20, 20), U.RandRange(1.2, 1.6), 0.2, tr, oxy, btype)
					e.trailAcc = math.max(e.trailAcc - blobV, 0)
					T.stats.chain = (T.stats.chain or 0) + 1
				end
			end
		end
	end
	while guard < 5 do
		guard = guard + 1
		local dmm = Fo and Fo.Diameter("drip", artery and 0.85 or 0.95) or 4
		if not drop(dmm, 1) then break end
	end
	if e.trailAcc > 450 then e.trailAcc = 450 end
	return take
end
