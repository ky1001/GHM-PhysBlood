local G = GHMPB
G.Flies = G.Flies or {}
local F = G.Flies
local U = G.U

F.swarms = F.swarms or {}
F.stats = F.stats or { swarms = 0, flies = 0, landed = 0, probes = 0, spots = 0, scatters = 0, buzz = 0 }
F.CELL = 96
F.MIN_VOL = 2500
F.DELAY, F.RAMP = 20, 120
F.SIM_DIST = 1400
F.HEAR_DIST = 160
F.STILL = 8
F.MISSES = 10

local function On() return G.cv.enable:GetBool() and G.cv.flies:GetBool() end
F.On = On

local skyTr = { mask = MASK_SOLID_BRUSHONLY }
local function Outdoors(pos)
	skyTr.start = pos + Vector(0, 0, 8)
	skyTr.endpos = pos + Vector(0, 0, 4000)
	local tr = util.TraceLine(skyTr)
	return tr.HitSky or not tr.Hit
end
function F.Weather()
	local now = RealTime()
	if F.wT and now < F.wT then return F.wV end
	F.wT = now + 3
	local v = 1
	local t = G.Elem and G.Elem.Temperature and G.Elem.Temperature()
	if t then v = math.Clamp((t - 8) / 10, 0, 1) end
	local sf = StormFox2
	if sf then
		local ok, night = pcall(function() return sf.Time and sf.Time.IsNight and sf.Time.IsNight() end)
		if ok and night then v = v * 0.25 end
		local ok2, rain = pcall(function() return sf.Weather and sf.Weather.IsRaining and sf.Weather.IsRaining() end)
		if ok2 and rain then v = v * 0.3 end
	end
	F.wV = v
	return v
end

local function LayerVol(p)
	if p.vol then return p.vol end
	local v = 0
	for _, x in pairs(p.tvol or {}) do v = v + x end
	return v
end
local cold = { snow = true, ice = true, water = true }
local function CellKey(c) local s = F.CELL return math.floor(c.x / s) .. ":" .. math.floor(c.y / s) .. ":" .. math.floor(c.z / s) end

F.notes = F.notes or {}
F.NOTES_PER_CELL = 12
function F.Note(pos, vol, radiusU, center)
	if not On() then return end
	local k = CellKey(center or pos)
	local list = F.notes[k]
	if not list then list = {} F.notes[k] = list end
	local n = { pos = Vector(pos), vol = vol, r = math.Clamp(radiusU or 1, 0.5, 8), t = CurTime() }
	if #list < F.NOTES_PER_CELL then list[#list + 1] = n return end
	local mi, mv = nil, vol
	for i, o in ipairs(list) do if o.vol < mv then mi, mv = i, o.vol end end
	if mi then list[mi] = n end
end

function F.LivingRagdolls()
	local set = {}
	for _, p in ipairs(player.GetAll()) do
		if p:Alive() then
			local r = p:GetNW2Entity("GHMEU_Rag")
			if IsValid(r) then set[r] = true end
			local f = p:GetNWEntity("FakeRagdoll")
			if IsValid(f) then set[f] = true end
		end
	end
	for _, n in ipairs(ents.FindByClass("npc_*")) do
		local r = n:GetNW2Entity("GHMEU_Rag")
		if IsValid(r) then set[r] = true end
	end
	for _, r in ipairs(ents.FindByClass("prop_ragdoll")) do
		if r:GetNW2Bool("ghmpb_alive", false) then set[r] = true end
	end
	return set
end
function F.DeathTime(ent, living)
	if living[ent] or ent:GetNW2Bool("ghmpb_alive", false) or (G.LivingRagdoll and G.LivingRagdoll(ent)) then return nil end
	local b = G.Wounds and G.Wounds.bodies and G.Wounds.bodies[ent]
	if b and b.dead then return b.deathTime or b.corpseT0 or false end
	if b then
		if not b.corpseT0 then return nil end
		return b.corpseT0
	end
	return false
end

local function Scan(now)
	local S, E = G.Surfaces, G.Entities
	local seen = {}
	local cells = {}
	local function addLayer(p, settled)
		if not p.center or cold[p.surfName or ""] then return end
		local v = LayerVol(p)
		if v <= 0 then return end
		local k = CellKey(p.center)
		local c = cells[k]
		if not c then c = { vol = 0, sx = 0, sy = 0, sz = 0, n = p.N, t = math.huge, layers = {} } cells[k] = c end
		c.vol = c.vol + v
		c.sx, c.sy, c.sz = c.sx + p.center.x * v, c.sy + p.center.y * v, c.sz + p.center.z * v
		c.t = math.min(c.t, settled and (p.bakedAt or now) or (p.created or p.touched or now))
		c.layers[#c.layers + 1] = p
		if p.N.z > (c.n.z or 0) then c.n = p.N end
	end
	for _, p in pairs(S.patches) do if p.hasBlood then addLayer(p, false) end end
	for _, a in pairs(S.after) do addLayer(a, true) end
	for k, c in pairs(cells) do
		if c.vol >= F.MIN_VOL and c.n.z > 0.5 then
			local key = "p" .. k
			seen[key] = true
			local sw = F.swarms[key]
			local pos = Vector(c.sx / c.vol, c.sy / c.vol, c.sz / c.vol)
			if not sw then
				sw = { key = key, kind = "pool", t0 = math.min(c.t, now), flies = {}, spots = {}, probeT = 0, buzzT = now + math.Rand(2, 5) }
				sw.outdoors = Outdoors(pos)
				F.swarms[key] = sw
				F.stats.swarms = F.stats.swarms + 1
			end
			sw.pos, sw.n, sw.vol, sw.layers, sw.cell = pos, c.n, c.vol, c.layers, k
			sw.cap = math.Clamp(2 + c.vol / 9000, 2, 10)
		end
	end
	for k, list in pairs(F.notes) do
		if not cells[k] and (list[1] and now - list[1].t > 10 or not list[1]) then F.notes[k] = nil end
	end
	local living = F.LivingRagdolls()
	F.living = {}
	for r in pairs(living) do if IsValid(r) then F.living[#F.living + 1] = r end end
	for ent, d in pairs(E.domains) do
		local died = nil
		if IsValid(ent) and (ent:IsRagdoll() or ent:GetClass() == "prop_ragdoll") then died = F.DeathTime(ent, living) end
		if died ~= nil then
			local key = "b" .. tostring(ent)
			seen[key] = true
			local sw = F.swarms[key]
			if not sw then
				sw = { key = key, kind = "body", ent = ent, t0 = math.min(died or now, now), flies = {}, spots = {}, probeT = 0,
					buzzT = now + math.Rand(2, 5) }
				sw.outdoors = Outdoors(ent:WorldSpaceCenter())
				F.swarms[key] = sw
				F.stats.swarms = F.stats.swarms + 1
			end
			sw.pos, sw.n = ent:WorldSpaceCenter(), Vector(0, 0, 1)
			sw.cap = 9
		end
	end
	for key, sw in pairs(F.swarms) do
		if not seen[key] then F.swarms[key] = nil end
	end
end

local function Want(sw, now, weather)
	local age = now - sw.t0
	local w = math.Clamp((age - F.DELAY) / F.RAMP, 0, 1)
	if sw.kind == "pool" then w = w * math.Clamp(1.4 - age / 1800, 0.35, 1) end
	local n = math.floor(sw.cap * w * weather * (sw.outdoors and 1 or 0.45) * G.cv.fliesamt:GetFloat() + 0.5)
	if sw.kind == "pool" and #sw.spots == 0 and (sw.misses or 0) >= F.MISSES then return 0 end
	if sw.kind == "body" and now - (sw.stillSince or now) < F.STILL then n = math.min(n, #sw.flies) end
	return n
end

local probeTr = { mask = MASK_SOLID_BRUSHONLY }
local function ProbeSpot(sw, now, recheck)
	if not G.Smear or not sw.layers or #sw.layers == 0 then return end
	local q, N
	local notes = sw.cell and F.notes[sw.cell]
	if recheck then
		q, N = recheck.pos, recheck.n
	elseif notes and #notes > 0 and math.random() < 0.85 then
		local n = notes[math.random(1, #notes)]
		local a, r = math.Rand(0, 6.2832), math.sqrt(math.random()) * n.r * 1.3
		N = sw.n or Vector(0, 0, 1)
		local T = math.abs(N.z) < 0.9 and N:Cross(Vector(0, 0, 1)):GetNormalized() or Vector(1, 0, 0)
		local B = N:Cross(T)
		q = n.pos + T * (math.cos(a) * r) + B * (math.sin(a) * r)
	else
		local p = sw.layers[math.random(1, #sw.layers)]
		local P = G.Surfaces.PATCH_UNITS
		local x, y = math.Rand(0.1, 0.9) * P, math.Rand(0.1, 0.9) * P
		q, N = p.origin + p.U * x + p.V * y, p.N
	end
	probeTr.start = q + N * 6
	probeTr.endpos = q - N * 6
	local tr = util.TraceLine(probeTr)
	if not tr.Hit then return end
	local ps = {}
	G.Smear.RequestProbe(ps, tr.HitPos, tr.HitNormal)
	sw.pending = sw.pending or {}
	sw.pending[#sw.pending + 1] = { ps = ps, pos = tr.HitPos, n = tr.HitNormal, t = now, recheck = recheck }
	F.stats.probes = F.stats.probes + 1
end
local function DropSpot(sw, sp, now)
	for i = #sw.spots, 1, -1 do if sw.spots[i] == sp then table.remove(sw.spots, i) end end
	for _, f in ipairs(sw.flies) do
		if f.spot == sp then
			f.spot = nil
			if f.state == "land" then
				f.state = "fly"
				f.vel = (f.n or Vector(0, 0, 1)) * math.Rand(60, 110) + VectorRand() * 40
				f.flyT = now + math.Rand(2, 6)
			end
		end
	end
	F.stats.dropped = (F.stats.dropped or 0) + 1
end
local function ReadSpots(sw, now)
	local list = sw.pending
	if not list then return end
	for i = #list, 1, -1 do
		local pr = list[i]
		if pr.ps.hT then
			table.remove(list, i)
			local h, s = pr.ps.h or 0, pr.ps.s or 0
			local blood = (h > 0.02 or s > 0.05) and (pr.ps.frost or 0) < 0.5
			if pr.recheck then
				if blood then pr.recheck.t, pr.recheck.wet, sw.foundT = now, h > 0.02, now
				else DropSpot(sw, pr.recheck, now) end
			elseif blood then
				sw.misses, sw.foundT = 0, now
				if h > 0.02 or math.random() < 0.5 then
					if #sw.spots >= 10 then table.remove(sw.spots, 1) end
					sw.spots[#sw.spots + 1] = { pos = pr.pos, n = pr.n, wet = h > 0.02, t = now }
					F.stats.spots = F.stats.spots + 1
				end
			else
				sw.misses = (sw.misses or 0) + 1
			end
		elseif now - pr.t > 2 then
			table.remove(list, i)
		end
	end
end
local function BodySpots(sw)
	local ent = sw.ent
	if not IsValid(ent) then return end
	local b = G.Wounds and G.Wounds.bodies and G.Wounds.bodies[ent]
	local spots = {}
	if b and b.wounds then
		for i = #b.wounds, math.max(1, #b.wounds - 7), -1 do
			local w = b.wounds[i]
			if w.bone and w.lpos then spots[#spots + 1] = { bone = w.bone, lpos = w.lpos, lnrm = w.lnrm or Vector(0, 0, 1), wet = true } end
		end
	end
	local head = ent:LookupBone("ValveBiped.Bip01_Head1")
	if head then spots[#spots + 1] = { bone = head, lpos = Vector(3, -4, 0), lnrm = Vector(0, -1, 0), wet = true } end
	sw.spots = spots
end
local function SpotPos(sw, sp)
	if not sp.bone then return sp.pos, sp.n end
	local ent = sw.ent
	if not IsValid(ent) then return nil end
	local m = ent:GetBoneMatrix(sp.bone)
	if not m then return nil end
	local pos = LocalToWorld(sp.lpos, angle_zero, m:GetTranslation(), m:GetAngles())
	local n = LocalToWorld(sp.lnrm, angle_zero, vector_origin, m:GetAngles())
	return pos, n
end

function F.Disturb(pos, r)
	if not pos then return end
	local now = CurTime()
	for _, sw in pairs(F.swarms) do
		if sw.pos and sw.pos:DistToSqr(pos) < (r + 40) ^ 2 then
			sw.calmT = math.max(sw.calmT or 0, now + math.Rand(4, 8))
			sw.fleeFrom = Vector(pos)
			for _, f in ipairs(sw.flies) do
				if f.state == "land" then
					f.state = "fly"
					local away = f.pos - pos away.z = math.abs(away.z) + 10
					f.vel = away:GetNormalized() * math.Rand(120, 200)
					f.flyT = now + math.Rand(3, 7)
				end
			end
			F.stats.scatters = F.stats.scatters + 1
		end
	end
end

local function NewFly(sw, landed)
	local f = { phase = math.random() * 100, speed = math.Rand(60, 120), kind = math.random() < 0.55 and 1 or 2,
		size = math.Rand(0.32, 0.46) }
	local c = sw.pos
	if landed and #sw.spots > 0 then
		local sp = sw.spots[math.random(1, #sw.spots)]
		local pos, n = SpotPos(sw, sp)
		if pos then
			f.state, f.spot, f.pos, f.n, f.vel = "land", sp, pos + n * 0.1, n, Vector(0, 0, 0)
			f.landT = CurTime() + math.Rand(1, 10)
			return f
		end
	end
	local a = math.Rand(0, math.pi * 2)
	f.state = "fly"
	f.pos = c + Vector(math.cos(a), math.sin(a), 0) * math.Rand(60, 140) + Vector(0, 0, math.Rand(20, 60))
	f.vel = (c - f.pos):GetNormalized() * f.speed
	f.flyT = CurTime() + math.Rand(3, 9)
	return f
end

local function StepFly(sw, f, dt, now, calm)
	if f.state == "land" then
		local pos, n = SpotPos(sw, f.spot)
		if not pos then f.state = "fly" f.flyT = now + 3 return end
		f.crawl = f.crawl or Vector(0, 0, 0)
		if (f.crawlT or 0) < now then
			f.crawlT = now + math.Rand(0.4, 1.4)
			local t1 = n:Cross(Vector(0.3, 0.6, 0.74)):GetNormalized()
			local t2 = n:Cross(t1)
			local a = math.Rand(0, math.pi * 2)
			f.crawlTo = f.crawl + (t1 * math.cos(a) + t2 * math.sin(a)) * math.Rand(0.15, 0.5)
			if f.crawlTo:Length() > 1.6 then f.crawlTo = f.crawlTo * 0.4 end
			f.head = (f.crawlTo - f.crawl):GetNormalized()
		end
		f.crawl = f.crawl + (f.crawlTo - f.crawl) * math.min(dt * 3, 1)
		f.pos = pos + n * 0.1 + f.crawl
		f.n = n
		if now > f.landT or not calm then
			f.state = "fly"
			f.vel = n * math.Rand(60, 110) + VectorRand() * 40
			f.flyT = now + math.Rand(2, 8)
		end
		return
	end
	local c = sw.pos
	if (f.turnT or 0) < now then
		f.turnT = now + math.Rand(0.12, 0.45)
		local a = math.Rand(0, math.pi * 2)
		local away = not calm and sw.fleeFrom and (c - sw.fleeFrom)
		if away then
			away.z = 0
			local l = away:Length()
			if l < 1 then away = Vector(math.cos(f.phase), math.sin(f.phase), 0) else away:Mul(1 / l) end
			local r = math.Rand(25, 45)
			f.goal = c + away * math.Rand(110, 170) + Vector(math.cos(a) * r, math.sin(a) * r, math.Rand(25, 70))
		else
			local r = calm and math.Rand(6, 26) or math.Rand(30, 70)
			f.goal = c + Vector(math.cos(a) * r, math.sin(a) * r, math.Rand(2, calm and 22 or 50))
		end
	end
	local goal = f.goal
	local land = calm and now > f.flyT and #sw.spots > 0
	if land then
		f.spot = f.spot or sw.spots[math.random(1, #sw.spots)]
		local pos = SpotPos(sw, f.spot)
		if pos then
			goal = pos
			if pos:DistToSqr(f.pos) < 1.5 * 1.5 then
				f.state, f.landT, f.crawl, f.crawlT = "land", now + math.Rand(f.spot.wet and 3 or 1.5, f.spot.wet and 14 or 6), nil, 0
				f.vel = Vector(0, 0, 0)
				return
			end
		else
			f.spot = nil
		end
	else
		f.spot = nil
	end
	local to = goal - f.pos
	local d = to:Length()
	local sp = land and math.min(f.speed, d * 4 + 10) or f.speed
	to:Mul(sp / math.max(d, 1e-3))
	local k = math.min(dt * (land and 8 or 5), 1)
	f.vel = f.vel + (to - f.vel) * k + VectorRand() * (dt * 220)
	f.pos = f.pos + f.vel * dt
	if sw.kind == "pool" then
		local hgt = (f.pos - c):Dot(sw.n)
		if hgt < 0.5 then f.pos = f.pos + sw.n * (0.5 - hgt) f.vel = f.vel + sw.n * 40 end
	end
end

local nextScan = 0
function F.Update()
	if not On() then
		if next(F.swarms) then F.swarms = {} end
		return
	end
	local now = CurTime()
	if now >= nextScan then
		nextScan = now + 2
		local ok, err = pcall(Scan, now)
		if not ok then G.Diag.lastError = "flies: " .. tostring(err) end
	end
	local dt = math.Clamp(now - (F.lastT or now), 0, 0.1)
	F.lastT = now
	if dt <= 0 then return end
	local weather = F.Weather()
	local eye = EyePos()
	local maxN = G.cv.fliesmax:GetInt()
	local total, landed = 0, 0
	for _, sw in pairs(F.swarms) do
		if sw.kind == "body" and IsValid(sw.ent) and sw.pos and sw.pos:DistToSqr(eye) < F.SIM_DIST * F.SIM_DIST then
			local c = sw.ent:WorldSpaceCenter()
			if not sw.lastPos or sw.lastPos:DistToSqr(c) > 3 * 3 then
				sw.stillSince = now
				if sw.lastPos then
					sw.calmT = math.max(sw.calmT or 0, now + 3)
					sw.fleeFrom = sw.lastPos
				end
				sw.lastPos = c
			end
		end
		local want = math.min(Want(sw, now, weather), maxN - total)
		local near = sw.pos and sw.pos:DistToSqr(eye) < F.SIM_DIST * F.SIM_DIST
		if not near or want <= 0 then
			sw.flies = {}
			sw.sleeping = want
			if near and sw.kind == "pool" and (sw.misses or 0) >= F.MISSES then
				ReadSpots(sw, now)
				if now >= sw.probeT then sw.probeT = now + 2 ProbeSpot(sw, now) end
			end
		else
			if sw.kind == "body" then
				if (sw.spotT or 0) < now then sw.spotT = now + 5 BodySpots(sw) end
			else
				ReadSpots(sw, now)
				if #sw.spots < 8 and now >= sw.probeT then
					sw.probeT = now + 0.6
					ProbeSpot(sw, now)
				elseif #sw.spots > 0 and now >= (sw.recheckT or 0) then
					sw.recheckT = now + 2.5
					local old
					for _, sp in ipairs(sw.spots) do if not old or (sp.t or 0) < (old.t or 0) then old = sp end end
					ProbeSpot(sw, now, old)
				end
			end
			if (sw.checkT or 0) < now then
				sw.checkT = now + 0.3
				for _, r in ipairs(F.living or {}) do
					if IsValid(r) and r ~= sw.ent then
						local rp = r:WorldSpaceCenter()
						if rp:DistToSqr(sw.pos) < 48 * 48 then
							sw.calmT = math.max(sw.calmT or 0, now + 2)
							sw.fleeFrom = rp
							break
						end
					end
				end
				for _, e in ipairs(ents.FindInSphere(sw.pos, 56)) do
					if (e:IsPlayer() or e:IsNPC() or e:IsNextBot()) and e ~= sw.ent and (not e.Alive or e:Alive()) then
						local ep = e:GetPos()
						if e:GetVelocity():LengthSqr() > 40 * 40 then
							F.Disturb(ep, 30)
							break
						elseif ep:DistToSqr(sw.pos) < 28 * 28 then
							sw.calmT = math.max(sw.calmT or 0, now + 2)
							sw.fleeFrom = ep
							break
						end
					end
				end
			end
			local fl = sw.flies
			local fresh = sw.sleeping ~= nil
			sw.sleeping = nil
			while #fl < want do fl[#fl + 1] = NewFly(sw, fresh) end
			while #fl > want do table.remove(fl) end
			local calm = (sw.calmT or 0) < now
			for _, f in ipairs(fl) do
				StepFly(sw, f, dt, now, calm)
				if f.state == "land" then landed = landed + 1 end
			end
			if now >= sw.buzzT and #fl > 0 then
				local best, bd, nAir = nil, math.huge, 0
				for _, f in ipairs(fl) do
					if f.state ~= "land" then
						nAir = nAir + 1
						local d2 = f.pos:DistToSqr(eye)
						if d2 < bd then best, bd = f, d2 end
					end
				end
				if best then
					sw.buzzT = now + math.Rand(3, 6) / math.min(1 + nAir * 0.1, 1.5)
					local d = math.sqrt(bd)
					if d < F.HEAR_DIST and now >= (F.buzzGlobalT or 0) and G.cv.fliessnd:GetBool() then
						F.buzzGlobalT = now + 2
						local fall = 1 - d / F.HEAR_DIST
						sound.Play("ambient/creatures/flies" .. math.random(1, 5) .. ".wav", best.pos, 45,
							math.random(95, 110), math.Clamp(0.1 + nAir * 0.03, 0.1, 0.35) * fall * fall)
						F.stats.buzz = F.stats.buzz + 1
					end
				else
					sw.buzzT = now + math.Rand(1, 2)
				end
			end
			total = total + #fl
		end
	end
	F.stats.flies, F.stats.landed = total, landed
	G.Prof.Count("flies", total)
end

local function Quad(a, b, c, d, r, g, bl, al)
	mesh.Position(a) mesh.Color(r, g, bl, al) mesh.AdvanceVertex()
	mesh.Position(b) mesh.Color(r, g, bl, al) mesh.AdvanceVertex()
	mesh.Position(c) mesh.Color(r, g, bl, al) mesh.AdvanceVertex()
	mesh.Position(d) mesh.Color(r, g, bl, al) mesh.AdvanceVertex()
end
local BODY = { { 18, 30, 22 }, { 26, 26, 30 } }
local function DrawFlies()
	local eye = EyePos()
	local vfwd = EyeAngles():Forward()
	local list, n = {}, 0
	for _, sw in pairs(F.swarms) do
		for _, f in ipairs(sw.flies) do
			local d2 = f.pos:DistToSqr(eye)
			if d2 < 1500 * 1500 and (f.pos - eye):Dot(vfwd) > 0 then n = n + 1 list[n] = f f.d2 = d2 end
		end
	end
	if n == 0 then return end
	render.SetColorMaterial()
	local rt = RealTime()
	mesh.Begin(MATERIAL_QUADS, n * 3)
	local ok, err = pcall(function()
		for i = 1, n do
			local f = list[i]
			local p = f.pos
			local lc = render.GetLightColor(p)
			local li = math.Clamp((lc.x + lc.y + lc.z) / 3, 0.04, 1)
			local bc = BODY[f.kind]
			local dir = (f.state == "land") and (f.head or Vector(1, 0, 0)) or f.vel:GetNormalized()
			local up = (f.state == "land") and f.n or Vector(0, 0, 1)
			local side = dir:Cross(up)
			if side:LengthSqr() < 1e-4 then side = Vector(0, 1, 0) end
			side:Normalize()
			local L, W = f.size, f.size * 0.42
			local far = math.max(1, math.sqrt(f.d2) / 400)
			L, W = L * far, W * far
			local r, g, b = bc[1] * li * 1.6, bc[2] * li * 1.6, bc[3] * li * 1.6
			Quad(p + dir * L * 0.55, p + side * W, p - dir * L * 0.45, p - side * W, r, g, b, 255)
			local wa
			if f.state == "land" then
				wa = 70
				local wb = p + up * 0.04 - dir * L * 0.1
				Quad(wb, wb + side * W * 1.1 - dir * L * 0.55, wb - dir * L * 0.75, wb - side * W * 1.1 - dir * L * 0.55, 200 * li, 205 * li, 215 * li, wa)
			else
				wa = 40 + 40 * math.abs(math.sin(rt * 90 + f.phase))
				local wb = p + up * 0.03
				Quad(wb + dir * L * 0.2 + side * W * 2.2, wb - dir * L * 0.25 + side * W * 2.4, wb - dir * L * 0.25 - side * W * 2.4,
					wb + dir * L * 0.2 - side * W * 2.2, 210 * li, 215 * li, 225 * li, wa)
			end
			local hp = p + dir * L * 0.5
			Quad(hp + dir * W * 0.6, hp + side * W * 0.7, hp - dir * W * 0.3, hp - side * W * 0.7, r * 0.6, g * 0.5, b * 0.5, 255)
		end
	end)
	mesh.End()
	if not ok then G.Diag.lastError = "flies draw: " .. tostring(err) end
end
hook.Add("PostDrawTranslucentRenderables", "ghmpb_flies", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or not On() or render.GetRenderTarget() ~= nil then return end
	if F.stats.flies == 0 then return end
	local t = SysTime()
	DrawFlies()
	G.Prof.Lap("draw:flies", t)
end)

function F.Clear() F.swarms = {} F.notes = {} end
function F.Describe()
	local s = F.stats
	local n = 0
	for _ in pairs(F.swarms) do n = n + 1 end
	return string.format("flies: %s, swarms %d (seen %d), flies %d (%d on the blood), spots found %d of %d probes, scatters %d, buzzes %d, weather %.2f",
		On() and "on" or "off", n, s.swarms, s.flies, s.landed, s.spots, s.probes, s.scatters, s.buzz, F.Weather())
end
