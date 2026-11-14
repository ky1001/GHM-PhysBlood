local G = GHMPB
G.Tyres = G.Tyres or {}
local T = G.Tyres
local C = G.Contact
local U = G.U

local TICK = 0.04
local RANGE = 3000
local MAX_WHEELS = 32
local LOAD_MAX = 0.35
local KEEP_TURN = 0.55
local KEEP_SKID = 0.35
local PRINT_FRAC = 0.3
local SEG_MAX = 30
local RING = 24

T.state = T.state or {}
T.stats = T.stats or { wheels = 0, prints = 0, skids = 0, furrows = 0, pickups = 0, sprays = 0 }

local function Amount() return G.cv.tyreamt:GetFloat() end

local HL2_ATT = { "wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr" }
local wheels, wheelsT = {}, 0

local function IsWheelClass(c) return string.find(c, "wheel", 1, true) ~= nil end

local function Scan(now)
	if now - wheelsT < 1 then return wheels end
	wheelsT = now
	local eye = EyePos()
	local list = {}
	for _, e in ipairs(ents.FindInSphere(eye, RANGE)) do
		if IsValid(e) and not e:IsDormant() then
			local c = e:GetClass()
			if c == "glide_wheel" then
				list[#list + 1] = { key = e, kind = "glide", ent = e, veh = e:GetParent() }
			elseif c == "lvs_wheeldrive_wheel" then
				list[#list + 1] = { key = e, kind = "lvs", ent = e, veh = e.GetBase and e:GetBase() or e:GetParent() }
			elseif c == "gmod_sent_vehicle_fphysics_wheel" then
				list[#list + 1] = { key = e, kind = "simf", ent = e, veh = e.GetBaseEnt and e:GetBaseEnt() or e:GetParent() }
			elseif e:IsVehicle() and string.sub(c, 1, 12) == "prop_vehicle" then
				for _, name in ipairs(HL2_ATT) do
					local id = e:LookupAttachment(name)
					if id and id > 0 then
						e.ghmpbWheelKeys = e.ghmpbWheelKeys or {}
						local key = e.ghmpbWheelKeys[name] or {}
						e.ghmpbWheelKeys[name] = key
						list[#list + 1] = { key = key, kind = "hl2", ent = e, veh = e, att = id }
					end
				end
			elseif IsWheelClass(c) and (e:GetMoveType() == MOVETYPE_VPHYSICS or IsValid(e:GetParent())) and not e:IsWeapon() then
				list[#list + 1] = { key = e, kind = "generic", ent = e, veh = e:GetParent() }
			end
		end
	end
	for _, w in ipairs(list) do w.dist = w.ent:GetPos():DistToSqr(eye) end
	table.sort(list, function(a, b) return a.dist < b.dist end)
	wheels = {}
	for k = 1, math.min(#list, MAX_WHEELS) do wheels[k] = list[k] end
	T.stats.wheels = #wheels
	return wheels
end

local function WheelFrame(w)
	local e, veh = w.ent, w.veh
	local up = IsValid(veh) and veh:GetUp() or Vector(0, 0, 1)
	if w.kind == "hl2" then
		local a = e:GetAttachment(w.att)
		if not a then return nil end
		return a.Pos, nil, nil, up, nil, true
	elseif w.kind == "glide" then
		local r = e.GetRadius and e:GetRadius() or nil
		local slip
		if e.GetSideSlip and e.GetForwardSlip then
			slip = math.Clamp(math.max(math.abs(e:GetSideSlip()) - 0.1, 0) * 1.5 + math.max(math.abs(e:GetForwardSlip() * 0.04) - 0.1, 0), 0, 1)
		end
		local ground = not e.GetContactSurface or e:GetContactSurface() > 0
		return e:GetPos(), (r and r > 1) and r or nil, nil, up, slip, ground
	elseif w.kind == "lvs" then
		local r = e.GetRadius and e:GetRadius() or nil
		local wd = e.GetWidth and e:GetWidth() or nil
		local slip
		if e.GetSkid then slip = math.Clamp((math.min(0.3 + (e:GetSkid() or 0) / 4000, 1) ^ 2 - 0.2) / 0.5, 0, 1) end
		return e:GetPos(), (r and r > 1) and r or nil, (wd and wd > 0.5) and wd * 0.5 or nil, up, slip, true
	elseif w.kind == "simf" then
		local slip
		if e.GetSkidSound then slip = math.Clamp(((e:GetSkidSound() or 0) - 40) / 120, 0, 1) end
		local ground = not e.GetOnGround or (e:GetOnGround() or 0) > 0.5
		return e:GetPos(), nil, nil, up, slip, ground
	end
	return e:GetPos(), nil, nil, up, nil, true
end

local function HL2Heading(veh, now)
	local c = veh.ghmpbHead
	if c and c.t == now then return c.dir end
	local function At(name)
		local id = veh:LookupAttachment(name)
		local a = id and id > 0 and veh:GetAttachment(id)
		return a and a.Pos
	end
	local fl, fr, rl, rr = At("wheel_fl"), At("wheel_fr"), At("wheel_rl"), At("wheel_rr")
	local dir
	if fl and fr and rl and rr then
		dir = fl + fr - rl - rr
		if dir:LengthSqr() > 1 then dir:Normalize() else dir = nil end
	end
	veh.ghmpbHead = { t = now, dir = dir }
	return dir
end

local vehFilter
local td = { mask = MASK_SOLID, filter = function(e)
	if not IsValid(e) or e:IsWorld() then return true end
	if e == vehFilter or e:GetParent() == vehFilter or e:IsPlayer() or e:IsNPC() or e:IsRagdoll() then return false end
	if IsWheelClass(e:GetClass()) then return false end
	return G.Surfaces.IsGround(e)
end }

local function Stamp(st, cp, n, seg, halfW, tr, amt, skid, speed)
	local S = G.Surfaces
	local L = seg:Length()
	if L < 0.5 then return end
	local circ = 2 * math.pi * st.radius
	if skid then
		if st.load > 0.01 and amt > 0 then
			local film = st.load * 0.7 * math.min(skid * 1.5, 1)
			local vol = film * (L * 19.05) * (2 * halfW * 19.05) * 0.8 * amt
			if vol > 2 then
				S.Impact(cp, n, seg, halfW, vol, 3, 0, 1, 0.45, tr, st.oxy, st.btype)
				T.stats.skids = T.stats.skids + 1
			end
			st.load = st.load * KEEP_SKID ^ (L / circ)
		end
	else
		if st.load > 0.004 and amt > 0 then
			local fresh = math.Clamp(st.load / 0.3, 0, 1)
			local vol = st.load * PRINT_FRAC * (L * 19.05) * (2 * halfW * 19.05) * 0.8 * amt
			if vol > 1 and S.Impact(cp, n, seg, halfW, vol, 5, 3, fresh, 0.3, tr, st.oxy, st.btype) then
				T.stats.prints = T.stats.prints + 1
			end
		end
		st.load = st.load * KEEP_TURN ^ (L / circ)
	end
end

local function Wheel(w, now)
	local st = T.state[w.key]
	if not st then
		st = { load = 0, probes = {}, pi = 0, radius = 14, oxy = 0.6, btype = 0 }
		for k = 1, RING do st.probes[k] = {} end
		T.state[w.key] = st
	end
	local dt = math.Clamp(now - (st.t or now), 0, 0.5)
	st.t = now
	if st.load > 0 then st.load = st.load * math.exp(-dt / 60) end
	local center, radius, halfW, up, slip, ground = WheelFrame(w)
	if not center then return end
	vehFilter = IsValid(w.veh) and w.veh or w.ent
	local reach = (radius or st.radius) + 8
	td.start = center
	td.endpos = center - up * reach
	local tr = util.TraceLine(td)
	if not tr.Hit or tr.StartSolid or tr.HitSky or tr.HitNormal.z < 0.3 or ground == false then
		st.lastCp = nil
		return
	end
	local gap = (center - tr.HitPos):Dot(up)
	if not radius then
		if gap > 3 and gap < 45 then st.radius = st.radius * 0.8 + gap * 0.2 end
		radius = st.radius
		if gap > radius + 3 then st.lastCp = nil return end
	else
		st.radius = radius
		if gap > radius + 4 then st.lastCp = nil return end
	end
	halfW = math.Clamp(halfW or radius * 0.33, 2, 14)
	local cp, n = tr.HitPos, tr.HitNormal
	local amt = Amount()
	local last = st.lastCp
	st.lastCp = cp
	local seg = last and (last - cp) or vector_origin
	seg = seg - n * seg:Dot(n)
	local L = seg:Length()
	if L > 300 then return end
	local speed = L / math.max(dt, 1e-3)
	if L > 0.2 then st.dir = -seg / L end
	local dir = st.dir or (IsValid(w.veh) and w.veh:GetForward() or Vector(1, 0, 0))
	dir = dir - n * dir:Dot(n)
	if dir:LengthSqr() < 1e-4 then dir = n:Cross(Vector(0.31, 0.57, 0.76)) end
	dir:Normalize()
	local ri = (G.Gov and G.Gov.ReadbackInterval() or 0.3) + 0.05
	local lead0 = math.min(speed * ri, 260)
	local lead1 = math.min(speed * (ri + TICK * 1.5), 280)
	local ahead = cp + dir * lead1
	if C.NearBlood(cp) or C.NearBlood(ahead) then
		local cnt = speed < 40 and 1 or math.Clamp(math.ceil((lead1 - lead0) / 10), 1, 2)
		if speed >= 40 or now - (st.probeT or 0) > 0.12 then
			st.probeT = now
			for k = 1, cnt do
				st.pi = st.pi % RING + 1
				local ps = st.probes[st.pi]
				ps.reqT, ps.hT, ps.used = nil, nil, nil
				C.Probe(ps, cp + dir * (lead0 + (lead1 - lead0) * (k - 0.5) / cnt), n, 0)
			end
		end
	end
	local hits
	for _, ps in ipairs(st.probes) do
		if ps.hT and not ps.used and ps.reqPos then
			if now - ps.hT > 1.2 or (ps.h or 0) <= 0.05 then
				ps.used = true
			else
				local rel = ps.reqPos - cp
				rel = rel - n * rel:Dot(n)
				local along = rel:Dot(dir)
				local lat = (rel - dir * along):Length()
				if lat > halfW + 12 and along < 0 then
					ps.used = true
				elseif lat <= halfW + 5 and along <= halfW and along >= -math.max(speed * 1.3, 60) then
					ps.used = true
					hits = hits or {}
					hits[#hits + 1] = { pos = ps.reqPos, along = along, h = ps.h, btype = ps.btype, oxy = ps.oxy }
				end
			end
		end
	end
	if not last or L < 0.3 then
		if hits then
			for _, hit in ipairs(hits) do
				local load = math.min(LOAD_MAX, hit.h * 0.55)
				if load > st.load then st.load, st.oxy, st.btype = load, hit.oxy or st.oxy, hit.btype or st.btype T.stats.pickups = T.stats.pickups + 1 end
			end
		end
		return
	end
	local skid = slip
	if not skid then
		local vel = dir * speed
		local fwd = (w.kind == "hl2" and IsValid(w.veh) and HL2Heading(w.veh, now)) or dir
		fwd = fwd - n * fwd:Dot(n)
		fwd:Normalize()
		local lat = math.abs(vel:Dot(n:Cross(fwd)))
		local lastSpeed = st.speed or speed
		local decel = (lastSpeed - speed) / math.max(dt, 1e-3)
		skid = 0
		if lat > 100 and lat / math.max(speed, 1) > 0.4 then skid = math.Clamp((lat / speed - 0.4) * 2.5, 0.3, 1) end
		if decel > 380 and speed > 120 then skid = math.max(skid, 0.6) end
	end
	st.speed = speed
	skid = skid > 0.25 and skid or nil
	local printFrom = last
	if hits then
		table.sort(hits, function(a, b) return a.along < b.along end)
		local fl = math.Clamp(L, 6, 40)
		local side = n:Cross(dir)
		for _, hit in ipairs(hits) do
			local hp = hit.pos
			local wipe = skid and 0.45 or 0.65
			G.Surfaces.Impact(hp, n, -dir * fl, halfW * 1.1, hit.h, 4, 0, skid and math.max(speed, 20) or math.Clamp(speed * 0.2, 20, 60), wipe,
				tr, hit.oxy or st.oxy, hit.btype or st.btype)
			T.stats.furrows = T.stats.furrows + 1
			local load = math.min(LOAD_MAX, hit.h * 0.55)
			if load > st.load then
				st.load = load
				st.oxy, st.btype = hit.oxy or st.oxy, hit.btype or st.btype
				T.stats.pickups = T.stats.pickups + 1
			end
			if speed > 240 and G.cv.splash:GetFloat() > 0 then
				local P = G.Particles
				local cnt = math.min(math.floor((speed - 200) / 90 * math.min(hit.h, 2) * G.cv.splash:GetFloat()) + 1, 8)
				for _ = 1, cnt do
					local sgn = math.random() < 0.5 and -1 or 1
					local v = dir * speed * U.RandRange(0.1, 0.5) + side * sgn * speed * U.RandRange(0.1, 0.35) + n * speed * U.RandRange(0.1, 0.4)
					P.Spawn({ pos = hp + n * 1 + side * sgn * halfW * U.RandRange(0.6, 1.1), vel = v,
						r = U.RandRange(0.4, 1.4), owner = w.veh, oxy = hit.oxy or st.oxy, btype = hit.btype or st.btype, stretch = U.RandRange(1.3, 2.4), ownerGrace = 0.3 })
				end
				T.stats.sprays = T.stats.sprays + 1
			end
		end
		local lastHit = hits[#hits].pos
		local rel = lastHit - cp
		printFrom = cp + dir * math.min(rel:Dot(dir), 0)
		if (printFrom - cp):Length() < 1 then return end
	end
	if st.load <= 0.004 then return end
	local path = printFrom - cp
	path = path - n * path:Dot(n)
	local PL = path:Length()
	if PL < 0.5 then return end
	local pieces = math.ceil(PL / SEG_MAX)
	for k = 1, pieces do
		local a = cp + path * ((k - 1) / pieces)
		Stamp(st, a, n, path / pieces, halfW, tr, amt, skid, speed)
	end
end

function T.Update()
	if not G.cv.enable:GetBool() or not G.cv.tyres:GetBool() then return end
	local now = CurTime()
	if now < (T.next or 0) then return end
	T.next = now + TICK
	C.Grid(now)
	for _, w in ipairs(Scan(now)) do
		if IsValid(w.ent) then
			local ok, err = pcall(Wheel, w, now)
			if not ok then ErrorNoHalt("[GHMPB] tyres: " .. tostring(err) .. "\n") end
		end
	end
	for k, st in pairs(T.state) do if now - (st.t or 0) > 10 then T.state[k] = nil end end
end

function T.Load(key) local st = T.state[key] return st and st.load or 0 end

function T.Clear()
	T.state = {}
	wheelsT = 0
end
