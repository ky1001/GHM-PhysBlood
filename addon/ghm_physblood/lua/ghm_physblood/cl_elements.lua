local G = GHMPB
G.Elem = G.Elem or {}
local EL = G.Elem
local K = G.EL
local U = G.U

EL.src = EL.src or {}
EL.arcs = EL.arcs or {}
EL.sprites = EL.sprites or {}
EL.probes = EL.probes or {}
EL.stats = EL.stats or { events = 0, stamps = 0, steam = 0, decals = 0, arcs = 0, frozen = 0, drops = 0 }

local function On() return G.cv.enable:GetBool() and G.cv.elements:GetBool() end
EL.On = On

local function Q(x) return math.Clamp(math.floor((x or 0) * 15 + 0.5), 0, 15) end
local function Q7(x) return math.Clamp(math.floor((x or 0) * 7 + 0.5), 0, 7) end
EL.GLOW_ELEC, EL.GLOW_RAD, EL.GLOW_EMBER, EL.GLOW_PLASMA = 1, 2, 3, 4
function EL.Word(el, body)
	if not el or not On() then return 0 end
	local glow = Q(el.glow)
	local gt = glow > 0 and math.Clamp(el.glowT or 0, 0, 7) or 0
	return Q(el.frost) + 16 * Q(math.min(el.heat or 0, 1)) + 256 * Q7(el.fizz) + 2048 * gt + 16384 * glow
		+ 262144 * (body and Q(el.char) or 0)
end

local tempT, tempV = 0, nil
function EL.Temperature()
	local now = RealTime()
	if now < tempT then return tempV end
	tempT = now + 2
	tempV = nil
	local sf = StormFox2
	if sf and sf.Temperature and sf.Temperature.Get then
		local ok, t = pcall(sf.Temperature.Get)
		if ok and isnumber(t) then tempV = t end
	end
	return tempV
end
local skyTr = { mask = MASK_SOLID_BRUSHONLY }
local function Outdoors(pos)
	skyTr.start = pos + Vector(0, 0, 8)
	skyTr.endpos = pos + Vector(0, 0, 4000)
	local tr = util.TraceLine(skyTr)
	return tr.HitSky or not tr.Hit
end
function EL.ColdOf(p)
	if p.surfName == "snow" then return true, 1 / 90 end
	if p.surfName == "ice" then return true, 1 / 50 end
	local t = EL.Temperature()
	if t and t < 0 and p.center and Outdoors(p.center) then return true, math.Clamp(-t / 10, 0.2, 3) / 120 end
	return false, 0
end
local function AirCold(p)
	if p.el and p.el.cold then return true end
	local t = EL.Temperature()
	return t ~= nil and t < 8 and p.center ~= nil and Outdoors(p.center)
end

local function PState(p)
	local el = p.el
	if not el then
		el = { heat = 0, frost = 0, fizz = 0, glow = 0, glowT = 0 }
		el.cold, el.coldRate = EL.ColdOf(p)
		p.el = el
	end
	return el
end
local function DState(d)
	local el = d.el
	if not el then el = { heat = 0, frost = 0, fizz = 0, glow = 0, glowT = 0, char = 0, burnT = 0 } d.el = el end
	return el
end
EL.PState, EL.DState = PState, DState

local function ForPatches(pos, R, fn)
	local S = G.Surfaces
	local reach = R + S.PATCH_UNITS * 0.75
	local r2 = reach * reach
	for _, p in pairs(S.patches) do
		if p.center and p.center:DistToSqr(pos) < r2 and math.abs((pos - p.origin):Dot(p.N)) < math.max(R, 16) then
			fn(p, PState(p), math.Clamp(1 - p.center:Distance(pos) / reach, 0, 1))
		end
	end
end
EL.ForPatches = ForPatches

local gTr = { mask = MASK_SOLID_BRUSHONLY }
local function GroundAt(pos, depth)
	gTr.start = pos + Vector(0, 0, 4)
	gTr.endpos = pos - Vector(0, 0, depth or 140)
	local tr = util.TraceLine(gTr)
	if tr.Hit and not tr.StartSolid and not tr.HitSky then return tr.HitPos, tr.HitNormal, tr end
	return nil
end
EL.GroundAt = GroundAt

function EL.Probe(pos, n, cb)
	if not G.Smear or #EL.probes > 48 then return end
	local ps = {}
	G.Smear.RequestProbe(ps, pos, n or Vector(0, 0, 1))
	EL.probes[#EL.probes + 1] = { ps = ps, cb = cb, t = CurTime(), pos = pos, n = n }
end
local function RunProbes(now)
	local list = EL.probes
	local i = 1
	while i <= #list do
		local pr = list[i]
		if pr.ps.hT then
			table.remove(list, i)
			local ok, err = pcall(pr.cb, pr.ps, pr.pos, pr.n)
			if not ok then G.Diag.lastError = tostring(err) end
		elseif now - pr.t > 1.5 then
			table.remove(list, i)
		else
			i = i + 1
		end
	end
end

local function Seen(pos, far)
	local d2 = pos:DistToSqr(EyePos())
	if d2 > (far or 2000) ^ 2 then return false end
	return d2 < 200 * 200 or U.InViewPos(pos, 64)
end

local em
local function Emitter(pos)
	if not em or not em:IsValid() then em = ParticleEmitter(pos, false) end
	if em then em:SetPos(pos) end
	return em
end
local SMOKE = {}
for i = 1, 9 do SMOKE[i] = "particle/smokesprites_000" .. i end
function EL.Steam(pos, amount, hard)
	if not G.cv.elemsteam:GetBool() or not Seen(pos) then return end
	local e = Emitter(pos)
	if not e then return end
	for _ = 1, hard and 3 or 1 do
		local pt = e:Add(SMOKE[math.random(1, 9)], pos + VectorRand() * 2)
		if pt then
			pt:SetVelocity(Vector(math.Rand(-5, 5), math.Rand(-5, 5), math.Rand(10, 26) * (hard and 1.8 or 1)))
			pt:SetDieTime(math.Rand(1.6, 3.4))
			pt:SetStartAlpha(math.Clamp((hard and 46 or 24) * amount, 6, 70))
			pt:SetEndAlpha(0)
			pt:SetStartSize(math.Rand(1.5, 3))
			pt:SetEndSize(math.Rand(9, 18) * (hard and 1.4 or 1))
			pt:SetRoll(math.Rand(0, 360))
			pt:SetRollDelta(math.Rand(-0.6, 0.6))
			pt:SetColor(232, 234, 238)
			pt:SetLighting(true)
			pt:SetAirResistance(30)
			pt:SetGravity(Vector(0, 0, 8))
		end
	end
	EL.stats.steam = EL.stats.steam + 1
end
function EL.Smoke(pos, amount, r, g, b)
	if not G.cv.elemsteam:GetBool() or not Seen(pos) then return end
	local e = Emitter(pos)
	if not e then return end
	local pt = e:Add(SMOKE[math.random(1, 9)], pos + VectorRand() * 2)
	if pt then
		pt:SetVelocity(Vector(math.Rand(-6, 6), math.Rand(-6, 6), math.Rand(14, 32)))
		pt:SetDieTime(math.Rand(1.5, 3))
		pt:SetStartAlpha(math.Clamp(50 * amount, 8, 90))
		pt:SetEndAlpha(0)
		pt:SetStartSize(math.Rand(2, 4))
		pt:SetEndSize(math.Rand(10, 22))
		pt:SetRoll(math.Rand(0, 360))
		pt:SetRollDelta(math.Rand(-0.5, 0.5))
		pt:SetColor(r or 40, g or 36, b or 34)
		pt:SetLighting(true)
		pt:SetAirResistance(25)
		pt:SetGravity(Vector(0, 0, 10))
	end
end
function EL.Glow(pos, col, size, life)
	if #EL.sprites > 64 then return end
	EL.sprites[#EL.sprites + 1] = { pos = Vector(pos), col = col, size = size, t0 = RealTime(), life = life or 0.2 }
end
local function Sizzle(pos, vol)
	if not Seen(pos, 1500) then return end
	sound.Play("ambient/levels/canals/toxic_slime_sizzle" .. math.random(2, 4) .. ".wav", pos, 62, math.random(105, 125), vol or 0.35)
end

local charMats
local charCells = {}
function EL.Char(pos, n, size)
	if not charMats then
		charMats = {}
		for i = 1, 3 do
			charMats[i] = G.GPU.CreateMat("char" .. i, "LightmappedGeneric", {
				["$basetexture"] = "ghm_physblood/char" .. i, ["$decal"] = 1, ["$translucent"] = 1,
				["$vertexcolor"] = 1, ["$vertexalpha"] = 1, ["$decalscale"] = 0.125 })
		end
	end
	local key = math.floor(pos.x / 6) .. ":" .. math.floor(pos.y / 6) .. ":" .. math.floor(pos.z / 6)
	local now = CurTime()
	if (charCells[key] or 0) > now then return false end
	charCells[key] = now + 20
	local s = math.Clamp(size or 6, 2, 24) / 16
	local ok = pcall(util.DecalEx, charMats[math.random(1, 3)], game.GetWorld(), pos, n, Color(255, 255, 255, 255), s, s)
	if ok then EL.stats.decals = EL.stats.decals + 1 end
	return ok
end

function EL.NoteFresh(p, pos, vol)
	local list = p.fresh
	if not list then list = {} p.fresh = list end
	local now = CurTime()
	for _, f in ipairs(list) do
		if f.pos:DistToSqr(pos) < 100 then f.vol, f.t = f.vol + vol, now return end
	end
	if #list >= 8 then table.remove(list, 1) end
	list[#list + 1] = { pos = Vector(pos), vol = vol, t = now }
end

local function SrcKey(kind, pos, ent)
	if IsValid(ent) then return kind .. ":" .. tostring(ent) end
	return kind .. ":" .. math.floor(pos.x / 24) .. ":" .. math.floor(pos.y / 24) .. ":" .. math.floor(pos.z / 24)
end

local Laser, Acid, Dissolve, Wave, Spark
function EL.Add(kind, pos, r, s, dur, ent, pos2)
	if not On() or not pos then return end
	EL.stats.events = EL.stats.events + 1
	G.DiagCount("elements: " .. (G.EL_NAMES[kind] or tostring(kind)))
	if kind == K.LASER then return Laser(pos, s, ent, pos2) end
	if kind == K.ACID then return Acid(pos, r, s, ent, pos2) end
	if kind == K.DISSOLVE then return Dissolve(pos, r, ent) end
	if kind == K.WAVE then return Wave(pos, r, s) end
	if kind == K.ELEC then return Spark(pos, s, ent) end
	local now = CurTime()
	local key = SrcKey(kind, pos, ent)
	local o = EL.src[key]
	if o then
		o.pos, o.r, o.s = Vector(pos), math.max(r, o.r * 0.7), math.max(s, o.s * 0.8)
		o.untilT = math.max(o.untilT, now + dur)
		return o
	end
	o = { kind = kind, pos = Vector(pos), r = r, s = s, untilT = now + dur, t0 = now, ent = ent, exp = 0,
		nextProbe = now, nextSnd = now + math.Rand(0, 1) }
	EL.src[key] = o
	return o
end

net.Receive("ghmpb_elem", function()
	local kind = net.ReadUInt(4)
	local pos = net.ReadVector()
	local r = net.ReadUInt(11)
	local s = net.ReadUInt(8) / 100
	local dur = net.ReadUInt(10) / 10
	local ent = net.ReadEntity()
	local pos2 = net.ReadBool() and net.ReadVector() or nil
	if kind == K.DUST then
		if G.Dust then local ok, err = pcall(G.Dust.Blast, pos, r, s, nil, "sv") if not ok then G.Diag.lastError = "dust: " .. tostring(err) end end
		return
	end
	EL.Add(kind, pos, r, s, dur, IsValid(ent) and ent or nil, pos2)
end)

local function BodyHeat(ent, s, dt, boil)
	local d = G.Entities.domains[ent]
	if not d then return end
	local el = DState(d)
	el.heat = math.max(el.heat, s)
	el.frost = math.max(0, el.frost - s * dt * 0.5)
	el.burnT = el.burnT + dt * s
	el.char = math.Clamp(el.burnT / 25, 0, 1)
	if boil and math.random() < 0.5 then
		G.Entities.Element(ent, ent:WorldSpaceCenter(), math.max(ent:BoundingRadius(), 12), 10, math.min(0.05 * s, 0.3))
	end
end

local function TickHeat(o, dt, now)
	local hot = o.kind == K.HOT
	local plasma = o.kind == K.PLASMA
	local c = (IsValid(o.ent) and not hot) and o.ent:WorldSpaceCenter() or o.pos
	local R = hot and math.max(o.r, 4) or math.max(o.r * 0.8, 6)
	local rate = plasma and 1.2 or (hot and 0.5 or 0.3)
	local g, n = GroundAt(c, hot and 24 or 140)
	if g then
		local S = G.Surfaces
		local k = math.min(rate * o.s * dt, 0.6)
		if S.Element(g, R, 10, k) > 0 then EL.stats.stamps = EL.stats.stamps + 1 end
		ForPatches(g, R, function(p, el, f)
			el.heat = math.max(el.heat, math.min(o.s, 1) * f)
			el.frost = math.max(0, el.frost - o.s * dt * 0.5)
		end)
		o.exp = o.exp + o.s * dt
		if now >= o.nextProbe then
			o.nextProbe = now + (hot and 0.6 or 0.4)
			local a = math.Rand(0, math.pi * 2)
			local rr = math.Rand(0, R * 0.7)
			local pp = g + Vector(math.cos(a) * rr, math.sin(a) * rr, 0)
			local gp, gn = GroundAt(pp + Vector(0, 0, 8), 24)
			if gp then
				EL.Probe(gp, gn, function(ps)
					if (ps.h or 0) > 0.03 then
						EL.Steam(gp + gn * 1, math.Clamp(ps.h, 0.3, 1.5), true)
						if now >= o.nextSnd then o.nextSnd = now + math.Rand(1.6, 3) Sizzle(gp, hot and 0.45 or 0.3) end
					elseif (ps.s or 0) > 0.04 and o.exp > (plasma and 0.6 or 2.5) then
						EL.Smoke(gp + gn, 0.6)
						if EL.Char(gp, gn, math.Clamp(R * 0.45, 3, 14)) then
							ForPatches(gp, 6, function(p, el) el.glowT, el.glow = EL.GLOW_EMBER, math.max(el.glow, 0.5) end)
						end
					end
				end)
			end
		end
		if plasma then EL.Glow(g + n * 2, Color(200, 120, 255), 18, 0.2) end
	end
	if IsValid(o.ent) and not hot then BodyHeat(o.ent, math.min(o.s, 1), dt, true) end
	if not hot then
		for ent in pairs(G.Entities.domains) do
			if ent ~= o.ent and IsValid(ent) and ent:GetPos():DistToSqr(c) < R * R then BodyHeat(ent, math.min(o.s, 1) * 0.6, dt, true) end
		end
	end
end

local function TickCold(o, dt)
	local g = GroundAt(o.pos) or o.pos
	ForPatches(g, o.r, function(p, el, f)
		el.frost = math.min(1, el.frost + o.s * f * dt / 4)
		el.heat = 0
	end)
	for ent, d in pairs(G.Entities.domains) do
		if IsValid(ent) and ent:GetPos():DistToSqr(o.pos) < o.r * o.r then
			local el = DState(d)
			el.frost = math.min(1, el.frost + o.s * dt / 4)
			el.heat = 0
		end
	end
	if math.random() < 0.3 then EL.Smoke(g + Vector(math.Rand(-o.r, o.r) * 0.5, math.Rand(-o.r, o.r) * 0.5, 2), 0.4, 225, 235, 245) end
end

local function TickRad(o)
	local g = GroundAt(o.pos) or o.pos
	ForPatches(g, o.r, function(p, el, f)
		el.glowT = EL.GLOW_RAD
		el.glow = math.max(el.glow, o.s * f)
	end)
	for ent, d in pairs(G.Entities.domains) do
		if IsValid(ent) and ent:GetPos():DistToSqr(o.pos) < o.r * o.r then
			local el = DState(d)
			el.glowT, el.glow = EL.GLOW_RAD, math.max(el.glow, o.s)
		end
	end
end

local lastLaser
Laser = function(pos, s, ent, from)
	local now = CurTime()
	local dir = from and (pos - from):GetNormalized() or Vector(0, 0, -1)
	EL.Glow(pos - dir * 1, Color(255, 190, 120), 10 + 6 * s, 0.12)
	if IsValid(ent) and G.Entities.domains[ent] then
		G.Entities.Element(ent, pos, 3, 10, math.min(0.5 * s, 0.9))
		local el = DState(G.Entities.domains[ent])
		el.heat = math.max(el.heat, 0.6)
		EL.Steam(pos, 0.7, true)
		if math.random() < 0.3 then Sizzle(pos, 0.3) end
		return
	end
	local tr = util.TraceLine({ start = pos - dir * 8, endpos = pos + dir * 16, mask = MASK_SOLID_BRUSHONLY })
	if not tr.Hit then return end
	local hp, n = tr.HitPos, tr.HitNormal
	local path
	if lastLaser and now - lastLaser.t < 0.4 and lastLaser.p:DistToSqr(hp) < 32 * 32 then path = lastLaser.p - hp end
	lastLaser = { p = hp, t = now }
	if G.Surfaces.Element(hp, 2.5, 10, math.min(0.6 * s, 0.9), path) > 0 then EL.stats.stamps = EL.stats.stamps + 1 end
	EL.Probe(hp, n, function(ps)
		if (ps.h or 0) > 0.05 then
			EL.Steam(hp + n, 0.8, true)
			if math.random() < 0.35 then Sizzle(hp, 0.35) end
			for _ = 1, math.random(1, 3) do
				local v = (n * math.Rand(60, 140) + VectorRand() * 60)
				G.Particles.Spawn({ pos = hp + n * 0.6, vel = v, r = math.Rand(0.15, 0.35), oxy = ps.oxy or 0.6, btype = ps.btype or 0, life = 2 })
				EL.stats.drops = EL.stats.drops + 1
			end
		elseif (ps.s or 0) > 0.03 then
			EL.Smoke(hp + n, 0.5)
			EL.Char(hp, n, 3)
		end
	end)
end

Acid = function(pos, r, s, ent, ground)
	local S = G.Surfaces
	local gp, gn, tr = GroundAt(ground or pos, 96)
	if gp then
		S.Impact(gp, gn, Vector(0, 0, -40), math.Clamp(r * 0.35, 1.5, 6), 2500 * s, 1, 0, 1, 0, tr, 0.3, G.ACID_TYPE)
		S.Element(gp, r, 12, math.min(0.35 * s, 0.8), nil, 0, G.ACID_TYPE)
		ForPatches(gp, r + 12, function(p, el, f) el.fizz = math.max(el.fizz, f) end)
		for _ = 1, 3 do EL.Smoke(gp + gn * 2 + VectorRand() * r * 0.3, 0.6, 140, 190, 70) end
		Sizzle(gp, 0.5)
	end
	if IsValid(ent) and G.Entities.domains[ent] then
		G.Entities.Element(ent, pos, 6, 12, math.min(0.5 * s, 0.9), nil, 400 * s, G.ACID_TYPE)
		local el = DState(G.Entities.domains[ent])
		el.fizz = 1
	end
end

Dissolve = function(pos, r, ent)
	local S = G.Surfaces
	local gp = GroundAt(pos, 160)
	if gp then S.Element(gp, math.max(r * 0.6, 16), 11, 0.8) end
	EL.Glow(pos, Color(200, 230, 255), 48, 0.35)
	if IsValid(ent) then
		local d = G.Entities.domains[ent]
		if d then
			local el = DState(d)
			el.glowT, el.glow = EL.GLOW_ELEC, 1
		end
		local bt = G.BloodTypeOf and G.BloodTypeOf(ent) or 0
		for k = 0, 5 do
			timer.Simple(k * 0.25, function()
				if not IsValid(ent) then return end
				local b = math.random(0, math.max((ent:GetBoneCount() or 1) - 1, 0))
				local bp = ent:GetBonePosition(b) or ent:WorldSpaceCenter()
				G.Particles.Mist(bp, VectorRand(), 1.2, bt or 0)
				if d then G.Entities.Element(ent, bp, 10, 11, 0.6) end
			end)
		end
	end
end

local balls = setmetatable({}, { __mode = "k" })
local function TrackBalls(now)
	for _, b in ipairs(ents.FindByClass("prop_combine_ball")) do
		local p = b:GetPos()
		local last = balls[b]
		balls[b] = p
		local gp, gn = GroundAt(p, 26)
		if gp then
			local path = (last and last:DistToSqr(p) < 400 * 400) and (last - p) or nil
			if path then path = path - gn * path:Dot(gn) end
			if G.Surfaces.Element(gp, 9, 11, 0.9, path) > 0 then
				EL.stats.stamps = EL.stats.stamps + 1
				G.Particles.Mist(gp + gn * 2, gn, 0.8, 0)
				EL.Glow(gp + gn * 3, Color(220, 240, 255), 24, 0.15)
			end
		end
	end
end

Wave = function(pos, r, s)
	local gp = GroundAt(pos, 200)
	if not gp then return end
	if G.Surfaces.Element(gp, r, 13, math.Clamp(s, 0.1, 1)) > 0 then EL.stats.stamps = EL.stats.stamps + 1 end
	for _ = 1, 6 do
		local a = math.Rand(0, math.pi * 2)
		local rr = math.Rand(8, r * 0.35)
		local pp, pn = GroundAt(gp + Vector(math.cos(a) * rr, math.sin(a) * rr, 16), 48)
		if pp then
			EL.Probe(pp, pn, function(ps)
				if (ps.h or 0) > 0.12 and (ps.frost or 0) < 0.5 then
					local out = (pp - gp) out.z = 0
					out = out:GetNormalized()
					for _ = 1, math.random(2, 4) do
						G.Particles.Spawn({ pos = pp + pn * 0.5, vel = pn * math.Rand(70, 190) * s + out * math.Rand(40, 140) * s + VectorRand() * 20,
							r = math.Rand(0.4, 1.0), oxy = ps.oxy or 0.6, btype = ps.btype or 0 })
						EL.stats.drops = EL.stats.drops + 1
					end
				end
			end)
		end
	end
end

Spark = function(pos, s, ent)
	if not Seen(pos) then return end
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetNormal(Vector(0, 0, 1))
	ed:SetMagnitude(1)
	ed:SetScale(1)
	ed:SetRadius(4)
	util.Effect("ElectricSpark", ed)
end

local up = Vector(0, 0, 1.2)
function EL.Arc(src, str, recs, vic)
	if not On() then return end
	local now = CurTime()
	local segs = {}
	for _, r in ipairs(recs) do
		local a = (r.par > 0 and recs[r.par]) and recs[r.par].p or src
		segs[#segs + 1] = { a + up, r.p + up }
		for _ = 1, math.min(3, math.floor(r.r / 10) + 1) do
			local ang = math.Rand(0, math.pi * 2)
			segs[#segs + 1] = { r.p + up, r.p + Vector(math.cos(ang), math.sin(ang), 0) * r.r * math.Rand(0.4, 0.9) + up }
		end
	end
	for _, v in ipairs(vic) do
		if IsValid(v.e) then
			local rp = recs[v.rec] and recs[v.rec].p or src
			local feet = v.e:GetPos()
			segs[#segs + 1] = { rp + up, feet + up }
			segs[#segs + 1] = { feet + up, feet + Vector(0, 0, math.max(v.e:OBBMaxs().z * 0.55, 10)) }
			local ed = EffectData()
			ed:SetOrigin(feet + Vector(0, 0, 4))
			ed:SetNormal(Vector(0, 0, 1))
			ed:SetMagnitude(2)
			ed:SetScale(1)
			ed:SetRadius(6)
			util.Effect("ElectricSpark", ed)
			local d = G.Entities.domains[v.e]
			if d then local el = DState(d) el.glowT, el.glow = EL.GLOW_ELEC, 1 end
		end
	end
	EL.arcs[#EL.arcs + 1] = { segs = segs, t0 = RealTime(), life = 0.3 + 0.2 * math.min(str, 1.5), str = str }
	EL.stats.arcs = EL.stats.arcs + 1
	for i, r in ipairs(recs) do
		ForPatches(r.p, r.r, function(p, el, f) el.glowT, el.glow = EL.GLOW_ELEC, math.max(el.glow, 0.6 + 0.4 * f) end)
		G.Surfaces.Element(r.p, r.r, 10, 0.03 * str)
		if i <= 4 then
			EL.Steam(r.p + up, 0.5, false)
			local dl = DynamicLight(4096 + (EL.stats.arcs * 4 + i) % 64)
			if dl then
				dl.pos = r.p + Vector(0, 0, 6)
				dl.r, dl.g, dl.b = 120, 160, 255
				dl.brightness = 2 * math.min(str, 1.5)
				dl.size = 140 + r.r * 2
				dl.decay = 1200
				dl.dietime = now + 0.25
			end
		end
	end
	if Seen(src, 2500) then sound.Play("ambient/energy/spark" .. math.random(1, 6) .. ".wav", src, 75, math.random(90, 110), 0.7) end
	if recs[1] and #recs > 2 and Seen(recs[#recs].p, 2500) then sound.Play("ambient/energy/zap" .. math.random(1, 9) .. ".wav", recs[#recs].p, 70, 100, 0.5) end
	Spark(src, str)
end
net.Receive("ghmpb_arc", function()
	local src = net.ReadVector()
	local str = net.ReadFloat()
	local n = net.ReadUInt(7)
	local recs = {}
	for i = 1, n do recs[i] = { p = net.ReadVector(), par = net.ReadUInt(7), r = net.ReadUInt(8) } end
	local nv = net.ReadUInt(5)
	local vic = {}
	for i = 1, nv do vic[i] = { e = net.ReadEntity(), rec = net.ReadUInt(7) } end
	EL.Arc(src, str, recs, vic)
end)

local nextT, nextScan, nextAmb = 0, 0, 0
local GLOW_DECAY = { 3.0, 1 / 30, 0.35, 1.0 }
local function Decay(el, dt)
	el.heat = math.max(0, (el.heat or 0) - dt * 0.8)
	el.fizz = math.max(0, (el.fizz or 0) - dt / 8)
	if (el.glow or 0) > 0 then el.glow = math.max(0, el.glow - dt * (GLOW_DECAY[el.glowT or 1] or 1)) end
end

function EL.Update()
	if not On() then return end
	local now = CurTime()
	if now < nextT then return end
	local dt = math.Clamp(now - (EL.lastT or now), 0, 0.3)
	EL.lastT = now
	nextT = now + 0.1
	RunProbes(now)
	if now >= nextScan then
		nextScan = now + 0.3
		for _, f in ipairs(ents.FindByClass("entityflame")) do
			local par = f:GetParent()
			if IsValid(par) and G.Entities.domains[par] then EL.Add(K.HEAT, par:WorldSpaceCenter(), math.Clamp(par:BoundingRadius() * 0.9, 16, 90), 0.9, 0.8, par) end
		end
	end
	TrackBalls(now)
	for key, o in pairs(EL.src) do
		if now > o.untilT or (o.ent ~= nil and not IsValid(o.ent)) then
			EL.src[key] = nil
		else
			local ok, err = pcall(function()
				if o.kind == K.HEAT or o.kind == K.PLASMA or o.kind == K.HOT then TickHeat(o, dt, now)
				elseif o.kind == K.COLD then TickCold(o, dt)
				elseif o.kind == K.RAD then TickRad(o) end
			end)
			if not ok then G.Diag.lastError = tostring(err) EL.src[key] = nil end
		end
	end
	if now >= nextAmb then
		local adt = now - (EL.ambT or now)
		EL.ambT = now
		nextAmb = now + 0.25
		local freeze = G.cv.freeze:GetBool()
		local steam = G.cv.elemsteam:GetBool()
		local frozen = 0
		local S = G.Surfaces
		for _, p in pairs(S.patches) do
			local el = PState(p)
			if el.cold and freeze then
				el.frost = math.min(1, el.frost + (el.coldRate or 0) * adt * (1 - math.min(el.heat, 1)))
			elseif el.frost > 0 then
				el.frost = math.max(0, el.frost - adt * 0.02)
			end
			if el.frost > 0.5 then frozen = frozen + 1 end
			Decay(el, adt)
			if steam and p.fresh and #p.fresh > 0 and el.frost < 0.8 and AirCold(p) then
				for i = #p.fresh, 1, -1 do
					local f = p.fresh[i]
					local age = now - f.t
					if age > 55 then
						table.remove(p.fresh, i)
					elseif math.random() < math.min(f.vol / 3000, 1) * (1 - age / 55) * 0.5 then
						EL.Steam(f.pos + p.N * 1.5, 0.6 * (1 - age / 55) + 0.2, false)
					end
				end
			end
		end
		for _, a in pairs(S.after) do
			local el = a.el
			if el then
				if el.cold and freeze then el.frost = math.min(1, (el.frost or 0) + (el.coldRate or 0) * adt) end
				Decay(el, adt)
			end
		end
		for _, d in pairs(G.Entities.domains) do
			if d.el then
				Decay(d.el, adt)
				if (d.el.frost or 0) > 0 then d.el.frost = math.max(0, d.el.frost - adt * 0.01) end
			end
		end
		EL.stats.frozen = frozen
	end
end

local boltMat, glowMat2
local function Jagged(a, b, seed, out)
	local d = b - a
	local len = d:Length()
	local m = math.Clamp(math.floor(len / 5), 2, 14)
	local side = d:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 1e-4 then side = Vector(1, 0, 0) end
	side:Normalize()
	local upv = Vector(0, 0, 1)
	out[1] = a
	for i = 1, m - 1 do
		local t = i / m
		local amp = math.sin(t * math.pi) * math.min(len * 0.12, 6)
		local h1 = math.sin(seed * 12.9898 + i * 78.233) * 43758.5453
		local h2 = math.sin(seed * 39.3468 + i * 11.135) * 24634.6345
		h1, h2 = h1 - math.floor(h1) - 0.5, h2 - math.floor(h2) - 0.5
		out[i + 1] = a + d * t + side * (h1 * 2 * amp) + upv * (math.abs(h2) * amp * 0.6)
	end
	out[m + 1] = b
	for i = m + 2, #out do out[i] = nil end
	return out
end
local pts = {}
hook.Add("PostDrawTranslucentRenderables", "ghmpb_elements", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) then return end
	if #EL.arcs == 0 and #EL.sprites == 0 then return end
	local rt = RealTime()
	if not boltMat then boltMat = Material("trails/electric") glowMat2 = Material("sprites/light_glow02_add") end
	local i = 1
	while i <= #EL.arcs do
		local a = EL.arcs[i]
		local age = rt - a.t0
		if age > a.life then
			table.remove(EL.arcs, i)
		else
			local fade = 1 - age / a.life
			local flick = (math.floor(rt * 30) % 3 == 0) and 0.45 or 1
			local seed = math.floor(rt * 20)
			render.SetMaterial(boltMat)
			for si, sg in ipairs(a.segs) do
				Jagged(sg[1], sg[2], seed + si * 7, pts)
				render.StartBeam(#pts)
				for k, p in ipairs(pts) do
					render.AddBeam(p, (1.6 + 1.4 * math.min(a.str, 1.5)) * fade, k / #pts, Color(170, 200, 255, 255 * fade * flick))
				end
				render.EndBeam()
			end
			render.SetMaterial(glowMat2)
			for si, sg in ipairs(a.segs) do
				if si % 3 == 1 then render.DrawSprite(sg[2], 14 * fade, 14 * fade, Color(150, 190, 255, 160 * fade * flick)) end
			end
			i = i + 1
		end
	end
	i = 1
	render.SetMaterial(glowMat2)
	while i <= #EL.sprites do
		local sp = EL.sprites[i]
		local age = rt - sp.t0
		if age > sp.life then
			table.remove(EL.sprites, i)
		else
			local f = 1 - age / sp.life
			local c = sp.col
			render.DrawSprite(sp.pos, sp.size * (0.7 + 0.3 * f), sp.size * (0.7 + 0.3 * f), Color(c.r, c.g, c.b, 255 * f))
			i = i + 1
		end
	end
end)

function EL.Clear()
	EL.src, EL.arcs, EL.sprites, EL.probes = {}, {}, {}, {}
	charCells = {}
end

function EL.Describe()
	local n = 0
	for _ in pairs(EL.src) do n = n + 1 end
	local s = EL.stats
	return string.format("elements: %s, sources %d, events %d, stamps %d, arcs %d, char marks %d, steam puffs %d, drops thrown %d, frozen patches %d, temperature %s",
		On() and "on" or "off", n, s.events, s.stamps, s.arcs, s.decals, s.steam, s.drops, s.frozen, tostring(EL.Temperature()))
end
