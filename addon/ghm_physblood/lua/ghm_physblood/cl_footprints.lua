local G = GHMPB
G.Foot = G.Foot or {}
local F = G.Foot
local U = G.U

local TICK = 0.04
local RANGE = 2500
local MAX_WALKERS = 24
local FOOT_SIDE = 3.6
local SOLE_R = 6.0
local LOAD_MAX = 0.42
local MIN_LOAD = 0.015
local MAX_STEPS_PER_FOOT = 6
local TRANSFER = 0.38
local KEEP = 0.56
local DRY_TAU = 40

F.state = F.state or {}
F.stats = F.stats or { prints = 0, pickups = 0, creature = 0, scuffs = 0 }

F.PROFILES = {
	headcrab = { shape = 0, r = 0.6, stride = 10, probe = 5, loadMax = 0.3,
		feet = { { 6, -5, 1, 0 }, { 6, 5, 2, 0 }, { -5, -6, 2, 0 }, { -5, 6, 1, 0 } } },
	headcrab_fast = { shape = 0, r = 0.5, stride = 14, probe = 8, loadMax = 0.25,
		feet = { { 8, -8, 1, 0 }, { 8, 8, 2, 0 }, { -7, -9, 2, 0 }, { -7, 9, 1, 0 } } },
	headcrab_poison = { shape = 0, r = 0.8, stride = 11, probe = 6, loadMax = 0.3,
		feet = { { 7, -6, 1, 0 }, { 7, 6, 2, 0 }, { -6, -7, 2, 0 }, { -6, 7, 1, 0 } } },
	antlion = { shape = 1, r = 1.5, stride = 28, probe = 13,
		feet = { { 18, -12, 1, 25 }, { 18, 12, 2, 25 }, { -16, -14, 2, 150 }, { -16, 14, 1, 150 } } },
	antlionguard = { shape = 1, r = 4.5, stride = 64, probe = 29,
		feet = { { 38, -28, 1, 20 }, { 38, 28, 2, 20 }, { -34, -30, 2, 155 }, { -34, 30, 1, 155 } } },
	hunter = { shape = 0, r = 2.2, stride = 36, probe = 14,
		feet = { { 14, -14, 1, 0 }, { 14, 14, 2, 0 }, { -26, 0, 1, 0 } } },
	strider = { shape = 1, r = 6, stride = 160, probe = 70,
		feet = { { 60, -70, 1, 30 }, { 60, 70, 2, 30 }, { -90, 0, 2, 180 } } },
	bird = { shape = 2, r = 1.3, stride = 3.5, probe = 1.2, loadMax = 0.3,
		feet = { { 0, -1.2, 1, 8 }, { 0, 1.2, 2, 8 } } },
	seagull = { shape = 2, r = 1.7, stride = 4.5, probe = 1.6, loadMax = 0.3,
		feet = { { 0, -1.6, 1, 8 }, { 0, 1.6, 2, 8 } } },
	vortigaunt = { shape = 2, r = 4.2, stride = 30, probe = 5,
		feet = { { 0, -5, 1, 10 }, { 0, 5, 2, 10 } } },
	dog = { shape = 2, r = 9, stride = 50, probe = 14,
		feet = { { 0, -14, 1, 6 }, { 0, 14, 2, 6 } } },
}
F.CLASS = {
	npc_headcrab = "headcrab", npc_headcrab_fast = "headcrab_fast", npc_headcrab_black = "headcrab_poison",
	npc_headcrab_poison = "headcrab_poison", npc_antlion = "antlion", npc_antlion_worker = "antlion",
	npc_antlionguard = "antlionguard", npc_hunter = "hunter", npc_strider = "strider", npc_crow = "bird",
	npc_pigeon = "bird", npc_seagull = "seagull", npc_vortigaunt = "vortigaunt", npc_dog = "dog",
	npc_zombie_torso = false, npc_fastzombie_torso = false, npc_antlion_grub = false, npc_barnacle = false,
	npc_manhack = false, npc_cscanner = false, npc_clawscanner = false, npc_rollermine = false,
	npc_turret_floor = false, npc_turret_ceiling = false, npc_turret_ground = false, npc_combine_camera = false,
	npc_sniper = false, npc_bullseye = false, npc_enemyfinder = false, npc_combinegunship = false,
	npc_helicopter = false, npc_combinedropship = false, npc_ichthyosaur = false, npc_missiledefense = false,
	npc_launcher = false, npc_apcdriver = false, npc_vehicledriver = false, npc_cranedriver = false,
	npc_grenade_frag = false, npc_furniture = false,
}
local AREA = { [0] = 2.5, [1] = 0.53, [2] = 0.54, [3] = 0.78 }

function F.Classify(e)
	local c = F.CLASS[e:GetClass()]
	if c ~= nil then
		if c == false or c == "human" then return c end
		return F.PROFILES[c]
	end
	local A = G.Anatomy
	local sk = A and A.GetSkeleton(e)
	if not sk or next(sk.bones) == nil then
		if e:IsPlayer() then return "human" end
		return nil
	end
	local legs = { [-1] = false, [1] = false }
	for _, region in ipairs({ A.FOOT, A.CALF, A.THIGH }) do
		for _, b in ipairs(sk.regions[region] or {}) do
			local side = sk.bones[b].side
			if side ~= 0 then legs[side] = true end
		end
	end
	local mins, maxs = e:OBBMins(), e:OBBMaxs()
	local len, wid, hgt = maxs.x - mins.x, maxs.y - mins.y, maxs.z - mins.z
	local upper = sk.head ~= nil and (sk.chest ~= nil or sk.abdomen ~= nil)
		and (sk.regions[A.UPPERARM] ~= nil or sk.regions[A.THIGH] ~= nil)
	if upper and legs[-1] and legs[1] and (e:IsPlayer() or hgt >= 1.2 * math.max(len, wid)) then return "human" end
	if upper and not (legs[-1] or legs[1]) then return false end
	if hgt < 3 or len < 2 or wid < 2 then return false end
	local w = math.max(len, wid)
	local fx, fy = len * 0.3, wid * 0.32
	return { shape = w < 24 and 0 or 3, r = math.Clamp(w * 0.045, 0.6, 6), stride = math.Clamp(len * 0.55, 6, 90),
		probe = fy, generic = true,
		feet = { { fx, -fy, 1, 0 }, { fx, fy, 2, 0 }, { -fx, -fy, 2, 0 }, { -fx, fy, 1, 0 } } }
end

local kinds = setmetatable({}, { __mode = "k" })
function F.Profile(e)
	local mdl = e:GetModel()
	local c = kinds[e]
	if c and c.mdl == mdl then return c.p end
	local p = F.Classify(e)
	if p == nil then return false end
	kinds[e] = { mdl = mdl, p = p }
	return p
end

local UP = Vector(0, 0, 1)
local td = { mask = MASK_SOLID, filter = function(e) return G.Surfaces.GroundFilter(e) end }
local function Ground(pos)
	td.start = pos + Vector(0, 0, 8)
	td.endpos = pos - Vector(0, 0, 16)
	local tr = util.TraceLine(td)
	if not tr.Hit or tr.StartSolid or tr.HitSky or tr.HitNormal.z < 0.68 then return nil end
	return tr
end

local function Grid(now) return G.Contact.Grid(now) end
local function NearBlood(pos) return G.Contact.NearBlood(pos) end

local function SampleWetBloodCPU(e, footPos, now)
	local S = G.Surfaces
	local bestH, bestOxy, bestBt, inDeepPool = 0, 0.65, 0, false
	if S and S.patches then
		for _, p in pairs(S.patches) do
			if p.hasBlood and p.firstKind ~= 5 and (p.vol or 0) > 2800 and p.N and p.N.z > 0.65 and now < (p.wetUntil or 0) then
				local dx, dy, dz = footPos.x - p.center.x, footPos.y - p.center.y, footPos.z - p.center.z
				if math.abs(dz) < 16 then
					local d2 = dx * dx + dy * dy
					if d2 < 20 * 20 then
						local v = p.vol or 0
						local h = math.Clamp((v - 2800) / 14000, 0.08, 0.85) * (1 - math.sqrt(d2) / 22)
						if h > bestH then
							bestH, bestOxy, bestBt = h, p.oxy or 0.65, p.btype or 0
							if d2 < 10 * 10 and v > 6000 then inDeepPool = true end
						end
					end
				end
			end
		end
	end
	if G.Lite and G.Lite.on then
		for _, pl in ipairs(G.Lite.pools or {}) do
			if pl.pos and math.abs(footPos.z - pl.pos.z) < 16 then
				local pr = (pl.r or 12) + 2
				local d2 = (footPos.x - pl.pos.x) ^ 2 + (footPos.y - pl.pos.y) ^ 2
				if d2 < pr * pr then
					local h = 0.72 * (1 - math.sqrt(d2) / (pr + 2))
					if h > bestH then bestH, bestOxy, bestBt, inDeepPool = h, pl.oxy or 0.65, pl.btype or 0, d2 < (pr * 0.5) ^ 2 end
				end
			end
		end
	end
	return bestH, bestOxy, bestBt, inDeepPool
end

local walkers, walkersT = {}, 0
local function Walkers(eye, now)
	if now - walkersT < 1 then return walkers end
	walkersT = now
	local list, r2 = {}, RANGE * RANGE
	local function add(e)
		if not IsValid(e) or e:IsDormant() then return end
		local dd = e:GetPos():DistToSqr(eye)
		if dd < r2 then list[#list + 1] = { e, dd } end
	end
	for _, pl in ipairs(player.GetAll()) do add(pl) end
	if G.cv.footnpc:GetBool() then
		for _, e in ipairs(ents.GetAll()) do
			if e:IsNPC() or (e.IsNextBot and e:IsNextBot()) then add(e) end
		end
	end
	table.sort(list, function(a, b) return a[2] < b[2] end)
	walkers = {}
	for k = 1, math.min(#list, MAX_WALKERS) do walkers[k] = list[k][1] end
	return walkers
end

local footBoneCache = setmetatable({}, { __mode = "k" })
local function HumanFootBones(e)
	local mdl = e:GetModel() or ""
	local c = footBoneCache[e]
	if c and c.mdl == mdl then return c.l, c.r end
	local bl = e:LookupBone("ValveBiped.Bip01_L_Foot") or e:LookupBone("Bip01 L Foot") or e:LookupBone("foot_L")
	local br = e:LookupBone("ValveBiped.Bip01_R_Foot") or e:LookupBone("Bip01 R Foot") or e:LookupBone("foot_R")
	footBoneCache[e] = { mdl = mdl, l = bl or false, r = br or false }
	return bl or false, br or false
end

local function Print(st, f, pos, face, faceR, scale, speed, turnRate, strafeDot, exactFootPos)
	local L = st.load[f]
	local stepNum = (st.steps[f] or 0) + 1
	if L < MIN_LOAD or stepNum > MAX_STEPS_PER_FOOT then
		st.load[f] = 0
		return
	end
	local side = f == 1 and -1 or 1
	local stanceMul = math.Clamp(1.05 - (speed or 0) / 650, 0.72, 1.05)
	local c = exactFootPos or (pos + faceR * (FOOT_SIDE * side * scale * stanceMul))
	local tr = Ground(c)
	if not tr then return end
	local now = CurTime()
	if st.inPool and st.inPool[f] and now - (st.inPoolT[f] or 0) < 0.12 then return end
	st.steps[f] = stepNum
	local splayDeg = (7.5 + math.Clamp((speed or 0) / 50, 0, 4.5)) * side
		+ math.Clamp((turnRate or 0) * 0.06, -14, 14)
		+ (strafeDot or 0) * 9
	local toe = math.rad(splayDeg)
	local dir = (face * math.cos(toe) + faceR * math.sin(toe)):GetNormalized()
	local loadFrac = math.Clamp(L / LOAD_MAX, 0, 1)
	local stepFrac = math.Clamp(1 - (stepNum - 1) / MAX_STEPS_PER_FOOT, 0.08, 1)
	local t = math.min(loadFrac, stepFrac)
	local R = SOLE_R * scale * (0.86 + 0.14 * t)
	local amtMul = G.cv.footamt:GetFloat()
	local film = L * TRANSFER * amtMul * (0.3 + 0.7 * t)
	local area = (2 * R * 19.05) * (0.72 * R * 19.05) * 0.78
	-- (1.26.6) 1.26.0 freshness and stain share: a soaked sole prints solid and dark, the lugs show as it runs dry
	local fresh = math.Clamp(L / 0.28, 0.04, 1)
	local residue = 0.3
	local oxy = st.oxy or 0.6
	local btype = st.btype or 0
	if G.Surfaces.Impact(tr.HitPos, tr.HitNormal, dir, R, film * area, 5, side, fresh, residue, tr, oxy, btype) then
		F.stats.prints = F.stats.prints + 1
		if stepNum == 1 and t > 0.75 and G.Particles and G.Particles.Spawn and (speed or 0) > 85 then
			local kd = (dir + tr.HitNormal * U.RandRange(0.35, 0.75) + faceR * U.RandRange(-0.25, 0.25)):GetNormalized()
			G.Particles.Spawn({ pos = tr.HitPos + tr.HitNormal * 0.5 + dir * (R * 0.7),
				vel = kd * math.Clamp((speed or 100) * U.RandRange(0.35, 0.6), 45, 175),
				r = U.RandRange(0.30, 0.55), oxy = oxy, btype = btype, stretch = U.RandRange(1.3, 1.8), spin = U.RandRange(-25, 25) })
		end
		if ((speed or 0) > 175 or math.abs(turnRate or 0) > 140) and stepNum <= 2 and t > 0.45 then
			local scuffPos = tr.HitPos + dir * (R * 0.70)
			-- (1.26.6) kind 3 takes the stroke vector in world units: keep the scuff a short drag of the sole, not a 1-2 m line
			G.Surfaces.Impact(scuffPos, tr.HitNormal, dir * math.Clamp(R * 0.9, 3, 6), R * 0.34, film * area * 0.10, 3, 0, U.RandRange(1.6, 2.4), residue * 0.75, tr, oxy, btype)
			F.stats.scuffs = (F.stats.scuffs or 0) + 1
		end
	end
	st.load[f] = L * KEEP
	if st.load[f] < MIN_LOAD then st.load[f] = 0 end
end

local function PrintCreature(st, f, pos, face, faceR, scale, prof)
	local L = st.load[f]
	local stepNum = (st.steps[f] or 0) + 1
	local maxL = prof.loadMax or LOAD_MAX
	if L < MIN_LOAD or stepNum > MAX_STEPS_PER_FOOT then
		st.load[f] = 0
		return
	end
	if st.inPool and st.inPool[f] and CurTime() - (st.inPoolT[f] or 0) < 0.12 then return end
	st.steps[f] = stepNum
	local loadFrac = math.Clamp(L / maxL, 0, 1)
	local stepFrac = math.Clamp(1 - (stepNum - 1) / MAX_STEPS_PER_FOOT, 0.08, 1)
	local t = math.min(loadFrac, stepFrac)
	local R = prof.r * scale * (0.86 + 0.14 * t)
	local Rmm = R * 19.05
	local film = L * TRANSFER * G.cv.footamt:GetFloat() * (0.3 + 0.7 * t)
	local vol = film * AREA[prof.shape] * Rmm * Rmm
	local fresh = math.Clamp(L / 0.28, 0.04, 1)   -- (1.26.6) 1.26.0 freshness, as for human soles
	local residue = 0.3
	for _, ft in ipairs(prof.feet) do
		if ft[3] == f then
			local tr = Ground(pos + face * (ft[1] * scale) + faceR * (ft[2] * scale))
			if tr then
				local sgn = ft[2] < 0 and -1 or 1
				local yaw = math.rad((ft[4] or 0) * sgn)
				local dir = face * math.cos(yaw) + faceR * math.sin(yaw)
				if G.Surfaces.Impact(tr.HitPos, tr.HitNormal, dir, R, vol, 5, sgn * (4 + prof.shape), fresh, residue, tr,
					st.oxy or 0.6, st.btype or 0) then
					F.stats.prints = F.stats.prints + 1
					F.stats.creature = F.stats.creature + 1
				end
			end
		end
	end
	st.load[f] = L * KEEP
	if st.load[f] < MIN_LOAD then st.load[f] = 0 end
end

local function Walker(e, now)
	if e:IsPlayer() and (not e:Alive() or e:InVehicle() or e:GetMoveType() == MOVETYPE_NOCLIP) then
		F.state[e] = nil
		return
	end
	local prof = F.Profile(e)
	if not prof then F.state[e] = nil return end
	local human = prof == "human"
	local side0 = human and FOOT_SIDE or prof.probe
	local st = F.state[e]
	if not st or not st.pq or not st.steps then
		st = { load = { 0, 0 }, steps = { 0, 0 }, pq = { {}, {} }, pqi = { 0, 0 }, lastH = { 0, 0 }, lastHT = { 0, 0 },
			inPool = { false, false }, inPoolT = { 0, 0 }, foot = 1, dist = 0, t = now }
		for f = 1, 2 do for k = 1, 8 do st.pq[f][k] = {} end end
		F.state[e] = st
	end
	local dt = math.Clamp(now - st.t, 0, 1)
	st.t = now
	local pos = e:GetPos()
	local last = st.pos
	st.pos = pos
	local kd = math.exp(-dt / DRY_TAU)
	st.load[1], st.load[2] = st.load[1] * kd, st.load[2] * kd

	local tr = Ground(pos)
	if not tr then st.dist = 0 return end
	local scale = e:GetModelScale() or 1
	local mv = last and (pos - last) or Vector(0, 0, 0)
	mv.z = 0
	local step = mv:Length()
	if step > 95 then step = 0 st.dist = 0 end
	local speed = step / math.max(dt, 1e-3)
	local yaw = e:IsPlayer() and e:EyeAngles().y or e:GetAngles().y
	local turnRate = st.lastYaw and (math.AngleDifference(yaw, st.lastYaw) / math.max(dt, 0.01)) or 0
	st.lastYaw = yaw
	local face = Angle(0, yaw, 0):Forward()
	local right = face:Cross(UP)
	local moveDir = step > 0.1 and (mv / step) or face
	local moveDot = face:Dot(moveDir)
	local strafeDot = right:Dot(moveDir)

	local maxLoad = human and LOAD_MAX or (prof.loadMax or LOAD_MAX)

	-- (1.26.11) True IK foot-bone tracking for nearby third-person human rigs (falls back to stride accumulator when distant or first-person)
	local ikPos1, ikPos2, ikFwd1, ikFwd2
	if human and not (e == LocalPlayer() and not e:ShouldDrawLocalPlayer()) and pos:DistToSqr(EyePos()) < 1100 * 1100 then
		local bl, br = HumanFootBones(e)
		if bl and br then
			local ml, mr = e:GetBoneMatrix(bl), e:GetBoneMatrix(br)
			if ml and mr then
				local p1, p2 = ml:GetTranslation(), mr:GetTranslation()
				if p1 and p2 and p1:DistToSqr(p2) > 0.25 and p1:DistToSqr(pos) < 85 * 85 then
					ikPos1, ikPos2 = p1, p2
					local f1, f2 = ml:GetForward(), mr:GetForward()
					f1.z, f2.z = 0, 0
					if f1:LengthSqr() > 0.04 then f1:Normalize() ikFwd1 = f1 end
					if f2:LengthSqr() > 0.04 then f2:Normalize() ikFwd2 = f2 end
				end
			end
		end
	end

	if now - (st.cpuProbeT or 0) > (speed > 15 and 0.06 or 0.25) then
		st.cpuProbeT = now
		for f = 1, 2 do
			local side = f == 1 and -1 or 1
			local ikP = f == 1 and ikPos1 or ikPos2
			local fpos = ikP and Vector(ikP.x, ikP.y, tr.HitPos.z) or (Vector(pos.x, pos.y, tr.HitPos.z) + right * (side0 * side * scale))
			local ch, coxy, cbt, deep = SampleWetBloodCPU(e, fpos, now)
			st.inPool[f] = deep
			if deep then st.inPoolT[f] = now end
			if ch > 0.06 then
				local L = math.min(maxLoad, ch * 0.65)
				if L > st.load[f] + 0.02 then
					st.load[f] = L
					st.steps[f] = 0
					st.oxy, st.btype = coxy, cbt
					F.stats.pickups = F.stats.pickups + 1
				end
			end
		end
	end

	if not (G.Lite and G.Lite.on) and now - (st.probeT or 0) > (speed > 10 and 0.08 or 0.45) and NearBlood(pos) then
		st.probeT = now
		local from = (st.probeFrom and st.probeFrom:DistToSqr(pos) < 90 * 90) and st.probeFrom or pos
		st.probeFrom = pos
		local seg = pos - from
		seg.z = 0
		local cnt = math.Clamp(math.ceil(seg:Length() / 10), 1, 3)
		for f = 1, 2 do
			local side = f == 1 and -1 or 1
			local ikP = f == 1 and ikPos1 or ikPos2
			for k = 1, cnt do
				st.pqi[f] = st.pqi[f] % #st.pq[f] + 1
				local ps = st.pq[f][st.pqi[f]]
				local pp
				if ikP and k == cnt then
					pp = Vector(ikP.x, ikP.y, tr.HitPos.z)
				else
					pp = from + seg * (k / cnt)
					pp.z = tr.HitPos.z
					pp = pp + right * (side0 * side * scale)
				end
				G.Smear.RequestProbe(ps, pp, tr.HitNormal)
			end
		end
	end
	for f = 1, 2 do
		for _, ps in ipairs(st.pq[f]) do
			if ps.hT and ps.hT ~= ps.seen then
				ps.seen = ps.hT
				if ps.hT >= st.lastHT[f] then st.lastH[f], st.lastHT[f] = ps.h or 0, ps.hT end
				if (ps.h or 0) > 0.065 and (ps.frost or 0) < 0.6 then
					local L = math.min(maxLoad, (ps.h - 0.03) * 0.58)
					if L > st.load[f] + 0.02 then
						st.load[f] = L
						st.steps[f] = 0
						st.oxy, st.btype = ps.oxy, ps.btype
						F.stats.pickups = F.stats.pickups + 1
					end
				end
			end
		end
	end

	-- IK foot touchdown/liftoff detection when live foot bone positions are available
	if ikPos1 and ikPos2 then
		st.ikAir = st.ikAir or { false, false }
		st.ikStepT = st.ikStepT or { 0, 0 }
		st.ikLastP = st.ikLastP or {}
		local anyTouch = false
		for f = 1, 2 do
			local fp = f == 1 and ikPos1 or ikPos2
			local ftr = Ground(fp)
			local hAbove = ftr and (fp.z - ftr.HitPos.z) or 12
			local movedF = st.ikLastP[f] and fp:DistToSqr(st.ikLastP[f]) or 0
			if hAbove > 4.1 * scale or (speed > 35 and movedF > (11 * scale) ^ 2 and now - st.ikStepT[f] > 0.24) then
				st.ikAir[f] = true
			end
			if st.ikAir[f] and hAbove <= 3.2 * scale and now - st.ikStepT[f] > 0.16 then
				st.ikAir[f] = false
				st.ikStepT[f] = now
				st.ikLastP[f] = Vector(fp)
				anyTouch = true
				if st.load[f] >= MIN_LOAD then
					local ikF = (f == 1 and ikFwd1 or ikFwd2)
					local useFace = (ikF and ikF:Dot(face) > 0.15) and ikF or face
					local useRight = useFace:Cross(UP)
					Print(st, f, pos, useFace, useRight, scale, speed, turnRate, strafeDot, Vector(fp.x, fp.y, pos.z))
				end
			elseif not st.ikLastP[f] then
				st.ikLastP[f] = Vector(fp)
			end
		end
		if anyTouch or speed < 5 then
			st.dist = 0
			return
		end
		-- keep stride fallback armed only if animations did not lift the foot bones (e.g. skating custom NextBot)
		if now - math.max(st.ikStepT[1], st.ikStepT[2]) < 0.85 then return end
	end

	if speed < 5 or step <= 0 then return end
	local stride
	if human then stride = math.Clamp(speed * 0.19, 22, 42) * scale
	else stride = prof.stride * scale * math.Clamp(0.85 + speed / (prof.stride * 14), 0.85, 1.5) end
	stride = stride * Lerp(math.abs(moveDot), 0.62, 1) * (moveDot < -0.3 and 0.82 or 1)
	local before = st.dist
	st.dist = st.dist + step
	if st.dist > stride * 4 then st.dist = stride end
	local startP = last or pos
	local along = stride - before
	while st.dist >= stride do
		st.dist = st.dist - stride
		st.foot = 3 - st.foot
		if st.load[st.foot] >= MIN_LOAD then
			local t = math.Clamp(along / step, 0, 1)
			local p = startP + (pos - startP) * t
			if human then Print(st, st.foot, p, face, right, scale, speed, turnRate, strafeDot)
			else PrintCreature(st, st.foot, p, face, right, scale, prof) end
		end
		along = along + stride
	end
end

function F.Update()
	if not G.cv.enable:GetBool() or not G.cv.foot:GetBool() then return end
	local now = CurTime()
	if now < (F.next or 0) then return end
	F.next = now + TICK
	Grid(now)
	for _, e in ipairs(Walkers(EyePos(), now)) do
		if IsValid(e) then
			local ok, err = pcall(Walker, e, now)
			if not ok then ErrorNoHalt("[GHMPB] footprints: " .. tostring(err) .. "\n") end
		end
	end
	for e in pairs(F.state) do if not IsValid(e) then F.state[e] = nil end end
end

function F.Load(e) local st = F.state[e] return st and st.load[1] or 0, st and st.load[2] or 0 end

function F.Clear()
	F.state = {}
	walkersT = 0
	kinds = setmetatable({}, { __mode = "k" })
end

function F.Walkers(now) return Walkers(EyePos(), now or CurTime()) end
