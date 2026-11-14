local G = GHMPB
G.Contact = G.Contact or {}
local C = G.Contact
local U = G.U

C.stats = C.stats or { splashes = 0, splashDrops = 0, splashML = 0 }

local grid, gridT = {}, -1
local function GridKey(x, y, P) return math.floor(x / P) .. ":" .. math.floor(y / P) end
function C.Grid(now)
	now = now or CurTime()
	if now - gridT < 1 and gridT >= 0 then return grid end
	gridT = now
	grid = {}
	local S = G.Surfaces
	local P = S.PATCH_UNITS
	local dry = G.DryTime()
	for _, p in pairs(S.patches) do
		if p.hasBlood then grid[GridKey(p.center.x, p.center.y, P)] = true end
	end
	for _, a in pairs(S.after) do
		if G.DryAge(a, G.DryMult(a.surfName)) < 0.95 then grid[GridKey(a.center.x, a.center.y, P)] = true end
	end
	return grid
end

function C.NearBlood(pos, r)
	local P = G.Surfaces.PATCH_UNITS
	local cx, cy = math.floor(pos.x / P), math.floor(pos.y / P)
	r = r or 1
	for dx = -r, r do
		for dy = -r, r do
			if grid[(cx + dx) .. ":" .. (cy + dy)] then return true end
		end
	end
	return false
end

function C.ResetGrid() grid, gridT = {}, -1 end

function C.Probe(ps, pos, n, every)
	local now = CurTime()
	if now - (ps.reqT or -1e9) < (every or 0.1) then return end
	ps.reqT, ps.reqPos = now, Vector(pos)
	G.Smear.RequestProbe(ps, pos, n)
end

function C.Depth(ps, maxAge, pos, near)
	if not ps.hT or CurTime() - ps.hT > (maxAge or 0.8) then return nil end
	if pos and ps.reqPos and near and ps.reqPos:DistToSqr(pos) > near * near then return nil end
	return ps.h or 0
end

function C.Splash(pos, n, h, speed, R, vel, owner, oxy, btype, tr)
	local amt = G.cv.splash:GetFloat()
	if amt <= 0 or not h or h < 0.08 or speed < 110 then return 0 end
	R = math.Clamp(R or 4, 1, 40)
	local Rmm = R * 19.05
	local avail = math.pi * Rmm * Rmm * math.min(h, 4)
	local e = math.Clamp((speed - 110) / 500, 0, 1)
	local out = math.min(avail * (0.06 + 0.3 * e), 25000) * amt
	if out < 15 then return 0 end
	local count = math.Clamp(math.floor(out / 22), 4, math.floor(60 * math.min(amt, 2)))
	local t1 = n:Cross(Vector(0.31, 0.57, 0.76))
	if t1:LengthSqr() < 1e-4 then t1 = n:Cross(Vector(1, 0, 0)) end
	t1:Normalize()
	local t2 = n:Cross(t1)
	vel = vel or vector_origin
	local vt = vel - n * vel:Dot(n)
	local per = out / count
	local P = G.Particles
	for _ = 1, count do
		local a = math.random() * math.pi * 2
		local dir = t1 * math.cos(a) + t2 * math.sin(a)
		local sp = math.min(speed * U.RandRange(0.25, 0.6) * (0.6 + 0.8 * e), 420)
		local v = (dir + n * U.RandRange(0.35, 1.2)):GetNormalized() * sp + vt * 0.35
		local vol = per * U.RandRange(0.4, 1.6)
		local r = math.Clamp((vol / 4.18879) ^ (1 / 3), 0.25, 2.2)
		P.Spawn({ pos = pos + n * 0.6 + dir * R * U.RandRange(0.7, 1.1), vel = v, r = r, owner = IsValid(owner) and owner or nil,
			oxy = oxy or 0.6, btype = btype or 0, stretch = U.RandRange(1.2, 2.2), spin = U.RandRange(-30, 30), ownerGrace = 0.25 })
	end
	local S = G.Surfaces
	local a0 = math.random() * math.pi * 2
	for k = 0, 5 do
		local a = a0 + k / 6 * math.pi * 2
		local dir = t1 * math.cos(a) + t2 * math.sin(a)
		S.Impact(pos + dir * R * 1.5, n, -dir * R * 1.1, R * 0.55, h, 4, 0, math.min(speed * 0.4, 200), 0.12, tr, oxy, btype)
	end
	C.stats.splashes = C.stats.splashes + 1
	C.stats.splashDrops = C.stats.splashDrops + count
	C.stats.splashML = C.stats.splashML + out / 1000
	return out
end

function C.Collapsed(ent, bone)
	local gs = ent.ghmflGore
	return gs ~= nil and bone ~= nil and gs.collapse ~= nil and gs.collapse[bone] ~= nil
end

function C.Clear()
	C.ResetGrid()
end
