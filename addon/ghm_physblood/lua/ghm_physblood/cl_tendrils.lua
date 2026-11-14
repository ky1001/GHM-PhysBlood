local G = GHMPB
G.Tendrils = G.Tendrils or {}
local T = G.Tendrils
local U = G.U

T.heads = T.heads or {}
T.sources = T.sources or {}
T.stats = T.stats or { spawned = 0, forks = 0, beads = 0, edges = 0 }
T.MAX = 40
T.SRC_CELL = 16
T.HZ = 30

local MM = 19.05
local sqrt, floor, min, max, exp = math.sqrt, math.floor, math.min, math.max, math.exp

local function Amount()
	local cv = G.cv.tendrils
	return cv and cv:GetFloat() or 1
end

function T.Readiness(sf)
	if not sf or sf.nostain or sf.drain then return 0 end
	return math.Clamp(1.05 - (sf.pin or 0.4) * 1.0 - (sf.fabric or 0) * 1.4 - (sf.kabs or 0) * 2, 0, 1)
end

local function hash(ix, iy)
	local n = ix * 374761393 + iy * 668265263
	n = bit.bxor(n, bit.rshift(n, 13)) * 1274126177
	n = bit.bxor(n, bit.rshift(n, 16))
	return (n % 65536) / 65536
end

local function vnoiseGrad(x, y)
	local ix, iy = floor(x), floor(y)
	local fx, fy = x - ix, y - iy
	local a, b, c, d = hash(ix, iy), hash(ix + 1, iy), hash(ix, iy + 1), hash(ix + 1, iy + 1)
	local ux, uy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	local dux, duy = 6 * fx * (1 - fx), 6 * fy * (1 - fy)
	local val = a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
	local gx = ((b - a) + (a - b - c + d) * uy) * dux
	local gy = ((c - a) + (a - b - c + d) * ux) * duy
	return gx, gy, val
end

function T.Field(pos)
	local s1, s2 = 1 / 68, 1 / 22
	local gx1, gy1, v1 = vnoiseGrad(pos.x * s1 + 17.3, pos.y * s1 + 5.1)
	local gx2, gy2, v2 = vnoiseGrad(pos.x * s2 + 3.7, pos.y * s2 + 11.9)
	return -(gx1 + 0.45 * gx2), -(gy1 + 0.45 * gy2), v1 * 0.6 + v2 * 0.4
end

local function SrcKey(pos)
	local c = T.SRC_CELL
	return floor(pos.x / c) .. "," .. floor(pos.y / c) .. "," .. floor(pos.z / 8)
end

local tr = {}
local td = { mask = MASK_SOLID_BRUSHONLY, output = tr }

function T.Feed(p, pos, vol, radiusU, trIn, oxy, btype)
	local amt = Amount()
	if T.noFeed or amt <= 0 or not p or not vol or vol < 20 then return 0 end
	if p.N.z < 0.966 then return 0 end
	local sf = p.surf or G.Surface.sealed
	local ready = T.Readiness(sf)
	if ready <= 0.02 then return 0 end
	local now = CurTime()
	local key = SrcKey(pos)
	local s = T.sources[key]
	if not s then
		s = { pos = Vector(pos), vol = 0, wsum = 0, t0 = now, t = now, n = 0, nextT = now + U.RandRange(0.45, 1.35), surf = sf,
			ready = ready, info = trIn, plane = p.plane }
		T.sources[key] = s
	end
	local w = vol
	s.pos = (s.pos * s.wsum + pos * w) / (s.wsum + w)
	s.wsum = s.wsum + w
	s.vol = s.vol + vol
	s.t = now
	s.oxy, s.btype = oxy or s.oxy or 0.75, btype or s.btype or 0
	s.info = trIn or s.info
	local take = 0
	local maxN = math.floor(2 + 4 * ready * math.min(amt, 2))
	if s.vol > 950 and s.n < maxN and (s.bank or 0) < 6000 then
		take = vol * min(0.28 * ready * amt, 0.40)
		s.bank = (s.bank or 0) + take
	end
	return take
end

local function Rim(s)
	local hmm = 1.3 + 1.1 * (1 - s.ready)
	return sqrt(s.vol / (math.pi * hmm)) / MM
end

local function FloorAt(pos)
	td.start = pos + Vector(0, 0, 3)
	td.endpos = pos - Vector(0, 0, 4)
	util.TraceLine(td)
	if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.85 then return Vector(tr.HitPos), Vector(tr.HitNormal), tr end
	return nil
end

local function Dir(pos, n, prev, uneven)
	local gx, gy = n.x * n.z, n.y * n.z
	local real = sqrt(gx * gx + gy * gy)
	local fx, fy, res = T.Field(pos)
	local k = 0.055 * uneven
	local dx, dy = gx * 6 + fx * k, gy * 6 + fy * k
	local l = sqrt(dx * dx + dy * dy)
	if l < 1e-5 then return prev, 0, res or 0.5 end
	dx, dy = dx / l, dy / l
	if prev then
		local a = 0.24
		dx, dy = prev.x * (1 - a) + dx * a, prev.y * (1 - a) + dy * a
		l = sqrt(dx * dx + dy * dy)
		dx, dy = dx / l, dy / l
	end
	return Vector(dx, dy, 0), math.min(real * 40 + l * 0.9, 3.2), res or 0.5
end

local function LobeRadius(h)
	local frac = math.Clamp(h.vol / math.max(h.vol0, 1), 0, 1)
	return math.max(h.r0 * (frac ^ 0.58), 0.16)
end

local function NewHead(s, pos, dir, vol, gen, r0, canSplit)
	if #T.heads >= T.MAX then return nil end
	local baseR = r0 or math.Clamp(Rim(s) * U.RandRange(0.32, 0.48), 0.85, 2.35)
	if canSplit == nil then canSplit = (math.random() < 0.56) end
	local h = { pos = Vector(pos), last = Vector(pos), dir = Vector(dir), vol = vol, vol0 = vol, age = 0, dist = 0, acc = 0, since = 0,
		src = s, oxy = s.oxy or 0.75, btype = s.btype or 0, info = s.info, gen = gen or 0,
		r0 = baseR, rCur = baseR, canSplit = canSplit, splitDist = baseR * U.RandRange(1.3, 2.6),
		pinch = canSplit and (math.random() < 0.48), pinched = false,
		wob = math.random() * 6.28, wobRate = U.RandRange(1.1, 2.2), forks = 0 }
	T.heads[#T.heads + 1] = h
	return h
end

local function Paint(h, final)
	if h.acc <= 0.5 then return end
	local r = LobeRadius(h)
	if final then r = math.min(r, h.rCur * 0.85) end
	h.rCur = r
	local n = h.n or Vector(0, 0, 1)
	local tdir = h.dir - n * h.dir:Dot(n)
	if tdir:LengthSqr() > 1e-4 then tdir:Normalize() else tdir = h.dir end
	local v = tdir * math.Clamp(16 + (h.speed or 2) * 5.5, 16, 42)
	T.noFeed = true
	pcall(G.Surfaces.Impact, h.pos, n, v, r, h.acc, 1, 0, 1.18, 0.08, h.info, h.oxy, h.btype)
	if n.z > 0.7 and G.Surfaces.WellWave then
		local now = CurTime()
		if now >= (h.waveT or 0) then
			h.waveT = now + 0.18
			pcall(G.Surfaces.WellWave, h.pos, math.Clamp(h.acc * 0.015, 0.14, 0.45))
		end
	end
	T.noFeed = false
	h.acc = 0
	h.last = Vector(h.pos)
	h.since = 0
end

local function SpawnFrom(s, now)
	local uneven = G.cv.unevenness and G.cv.unevenness:GetFloat() or 1
	local n = Vector(0, 0, 1)
	local fpos, fn = FloorAt(s.pos)
	if fpos then n = fn end
	local d = Dir(s.pos, n, nil, max(uneven, 0.25))
	if not d then d = VectorRand() d.z = 0 d:Normalize() end
	local a = math.atan2(d.y, d.x) + (math.random() - 0.5) * 1.85
	local dir = Vector(math.cos(a), math.sin(a), 0)
	local rim = Rim(s)
	local r0 = math.Clamp(rim * U.RandRange(0.32, 0.48), 0.85, 2.35)
	local start = s.pos + dir * math.max(rim * U.RandRange(0.45, 0.64), 0.35)
	local p2, n2 = FloorAt(start)
	if not p2 then return false end
	local vol = math.min(s.bank, U.RandRange(1400, 3600) * (0.65 + 0.55 * s.ready))
	if vol < 480 then return false end
	local h = NewHead(s, p2 + Vector(0, 0, 0.02), dir, vol, 0, r0, nil)
	if h then
		h.n = n2
		h.acc = vol * 0.03
		h.vol = vol - h.acc
		s.bank = s.bank - vol
		s.n = s.n + 1
		T.stats.spawned = T.stats.spawned + 1
		G.DiagCount("tendrils: started")
		return true
	end
	return false
end

local function Step(h, dt, uneven, viscMul)
	h.age = h.age + dt
	local fpos, fn = FloorAt(h.pos)
	if not fpos then
		Paint(h, true)
		if h.vol > 20 and G.Particles then G.Particles.Hang(h.pos + h.dir * 0.2, h.dir * 3, h.vol, nil, h.oxy, h.btype) end
		h.vol = 0
		T.stats.edges = T.stats.edges + 1
		return false
	end
	local d, pull, res = Dir(fpos, fn, h.dir, uneven)
	h.dir = d or h.dir
	h.n = fn
	local clotT = 25 * G.ClotScale()
	local clot = math.Clamp(h.age / clotT, 0, 1)
	local frac = math.Clamp(h.vol / math.max(h.vol0, 1), 0.1, 1)
	local speed = (1.35 + 1.85 * pull) * (0.35 + 0.85 * frac) * (1 - 0.8 * clot) / viscMul * (G.cv.runspeed and G.cv.runspeed:GetFloat() or 1)
	speed = math.Clamp(speed, 0.25, 7.5)
	h.speed = speed
	local ds = speed * dt
	h.wob = h.wob + ds * h.wobRate
	local side = Vector(-h.dir.y, h.dir.x, 0)
	local stepv = h.dir * ds + side * (math.sin(h.wob) * 0.065 * ds)
	td.start = fpos + Vector(0, 0, 0.4)
	td.endpos = fpos + Vector(0, 0, 0.4) + stepv + h.dir * 0.3
	util.TraceLine(td)
	if tr.Hit and not tr.StartSolid and tr.HitNormal.z < 0.7 then
		Paint(h, true)
		h.vol = 0
		return false
	end
	h.pos = fpos + stepv + Vector(0, 0, 0.02)
	h.dist = h.dist + ds
	h.since = h.since + ds
	local r = LobeRadius(h)
	local widthMM = r * 1.55 * MM
	local filmMM = 1.15 * (0.55 + 0.45 * frac)
	local lose = min(filmMM * widthMM * (ds * MM), h.vol)
	h.vol = h.vol - lose
	h.acc = h.acc + lose
	if h.since >= max(r * 0.34, 0.12) then Paint(h, false) end
	if h.canSplit and h.gen < 2 and h.forks < 2 and h.vol > 340 and frac > 0.26 and #T.heads < T.MAX - 2 then
		local hitRidge = (h.dist >= h.splitDist) or (h.dist > h.r0 * 0.95 and res > 0.58 and math.random() < ds * 0.45)
		if hitRidge then
			Paint(h, false)
			local share = U.RandRange(0.38, 0.50)
			local part = h.vol * share
			local sgn = (math.random() < 0.5) and -1 or 1
			local ang1 = sgn * U.RandRange(0.32, 0.58)
			local ang2 = -sgn * U.RandRange(0.20, 0.42)
			local c1, s1 = math.cos(ang1), math.sin(ang1)
			local c2, s2 = math.cos(ang2), math.sin(ang2)
			local nd1 = Vector(h.dir.x * c1 - h.dir.y * s1, h.dir.x * s1 + h.dir.y * c1, 0)
			local nd2 = Vector(h.dir.x * c2 - h.dir.y * s2, h.dir.x * s2 + h.dir.y * c2, 0)
			local rCur = LobeRadius(h)
			local childR = math.max(rCur * sqrt(share) * 0.92, 0.22)
			local mainR = math.max(rCur * sqrt(1 - share) * 0.92, 0.22)
			local nh = NewHead(h.src, h.pos + side * (sgn * rCur * 0.22), nd1, part, h.gen + 1, childR, h.gen == 0 and math.random() < 0.35)
			if nh then
				nh.n = h.n
				h.dir = nd2
				h.vol = h.vol - part
				h.vol0 = math.max(h.vol, 1)
				h.r0 = mainR
				h.rCur = mainR
				h.forks = h.forks + 1
				h.splitDist = h.dist + mainR * U.RandRange(1.6, 3.0)
				T.stats.forks = T.stats.forks + 1
			end
		end
	end
	if h.pinch and not h.pinched and frac <= 0.26 and h.vol > 55 and r >= 0.20 then
		h.pinched = true
		Paint(h, true)
		local dropVol = h.vol * U.RandRange(0.55, 0.78)
		local dropR = math.Clamp(r * U.RandRange(0.56, 0.74), 0.14, r * 0.78)
		local dropPos = FloorAt(h.pos + h.dir * (r * U.RandRange(1.75, 2.55)))
		if dropPos then
			T.noFeed = true
			pcall(G.Surfaces.Impact, dropPos + Vector(0, 0, 0.02), h.n or Vector(0, 0, 1), h.dir * 12, dropR, dropVol, 1, 0, 1.12, 0.05, h.info, h.oxy, h.btype)
			T.noFeed = false
			T.stats.beads = T.stats.beads + 1
		end
		h.vol = 0
		return false
	end
	if h.vol < 45 or (clot >= 1 and h.age > clotT * 1.2) then
		h.acc = h.acc + h.vol
		h.vol = 0
		Paint(h, true)
		T.stats.beads = T.stats.beads + 1
		return false
	end
	return true
end

local clock = 0
local function Update(dt)
	if Amount() <= 0 or not G.cv.enable:GetBool() then return end
	local now = CurTime()
	for key, s in pairs(T.sources) do
		if now - s.t > 90 then
			T.sources[key] = nil
		elseif (s.bank or 0) > 480 and now >= s.nextT and now - s.t0 > 0.65 then
			local maxN = math.floor(2 + 4 * s.ready * math.min(Amount(), 2))
			if s.n < maxN then SpawnFrom(s, now) end
			s.nextT = now + U.RandRange(0.65, 2.1) / math.max(s.ready, 0.35)
		end
	end
	if #T.heads == 0 then clock = 0 return end
	clock = math.min(clock + dt, 3 / T.HZ)
	local step = 1 / T.HZ
	local uneven = math.max(G.cv.unevenness and G.cv.unevenness:GetFloat() or 1, 0.2)
	local visc = math.max(G.cv.viscosity:GetFloat(), 0.3)
	while clock >= step do
		clock = clock - step
		for i = #T.heads, 1, -1 do
			local h = T.heads[i]
			local ok, alive = pcall(Step, h, step, uneven, visc)
			if not ok then
				G.DiagCount("error: tendrils") if G.Diag then G.Diag.lastError = tostring(alive) end
				table.remove(T.heads, i)
			elseif not alive then
				table.remove(T.heads, i)
			end
		end
	end
end

hook.Add("Think", "ghmpb_tendrils", function()
	local dt = FrameTime()
	if dt > 0 then Update(dt) end
end)

function T.Count() return #T.heads end
function T.Clear() T.heads = {} T.sources = {} end
function T.Describe()
	local ns = 0
	for _ in pairs(T.sources) do ns = ns + 1 end
	return string.format("tendrils: %d running, %d pool sources, started %d, forks %d, beads %d, over edges %d", #T.heads, ns,
		T.stats.spawned, T.stats.forks, T.stats.beads, T.stats.edges)
end
