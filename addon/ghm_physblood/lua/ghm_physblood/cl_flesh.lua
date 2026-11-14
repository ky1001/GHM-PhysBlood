local G = GHMPB
G.Flesh = G.Flesh or {}
local FL = G.Flesh
local A = G.Anatomy
local U = G.U

FL.gibs = FL.gibs or {}
FL.vessels = FL.vessels or {}
FL.airways = FL.airways or {}
FL.craterWell = FL.craterWell or setmetatable({}, { __mode = "k" })
FL.stats = FL.stats or { severs = 0, stumps = 0, limbs = 0, clones = 0, vessels = 0, airways = 0, craters = 0 }

local REGION = { head = A.NECK, l_upperarm = A.UPPERARM, r_upperarm = A.UPPERARM, l_forearm = A.FOREARM, r_forearm = A.FOREARM,
	l_hand = A.HAND, r_hand = A.HAND, l_thigh = A.THIGH, r_thigh = A.THIGH, l_calf = A.CALF, r_calf = A.CALF,
	l_foot = A.FOOT, r_foot = A.FOOT }
local STRENGTH = { head = 1.6, l_upperarm = 1.3, r_upperarm = 1.3, l_forearm = 1.0, r_forearm = 1.0, l_hand = 0.6, r_hand = 0.6,
	l_thigh = 1.6, r_thigh = 1.6, l_calf = 1.1, r_calf = 1.1, l_foot = 0.7, r_foot = 0.7 }

function FL.Active() return GHMFL ~= nil end

local function Chain(ent, key)
	if GHMFL and GHMFL.Anatomy and GHMFL.Anatomy.Get then
		local ok, sk = pcall(GHMFL.Anatomy.Get, ent)
		if ok and sk and sk.chain and sk.chain[key] and #sk.chain[key] > 0 then return sk.chain[key] end
	end
	local region = REGION[key]
	if key == "head" then region = A.HEAD end
	local side = string.sub(key, 1, 2) == "l_" and -1 or (string.sub(key, 1, 2) == "r_" and 1 or 0)
	local sk = A.GetSkeleton(ent)
	if not sk or not region or not sk.regions[region] then return nil end
	local best, bestDepth
	for _, b in ipairs(sk.regions[region]) do
		if sk.bones[b].side == side then
			local dpt, p = 0, ent:GetBoneParent(b)
			while p and p >= 0 and dpt < 64 do dpt = dpt + 1 p = ent:GetBoneParent(p) end
			if not bestDepth or dpt < bestDepth then best, bestDepth = b, dpt end
		end
	end
	if not best then return nil end
	local out = { best }
	local function kids(b)
		for c = 0, (ent:GetBoneCount() or 0) - 1 do
			if ent:GetBoneParent(c) == b then out[#out + 1] = c kids(c) end
		end
	end
	kids(best)
	return out
end

local function OnSever(ent, key, gib)
	if not IsValid(ent) or not G.cv.enable:GetBool() or not G.cv.flesh:GetBool() then return end
	if G.BloodTypeOf(ent) == nil then return end
	FL.stats.severs = FL.stats.severs + 1
	local chain = Chain(ent, key)
	if not chain then return end
	local root = chain[1]
	local rm = ent:GetBoneMatrix(root)
	if not rm then return end
	local joint = rm:GetTranslation()
	local parent = ent:GetBoneParent(root)
	local pm = parent and parent >= 0 and ent:GetBoneMatrix(parent)
	local out
	if pm then out = joint - pm:GetTranslation() end
	if not out or out:LengthSqr() < 0.01 then
		local cm = chain[2] and ent:GetBoneMatrix(chain[2])
		out = cm and (cm:GetTranslation() - joint) or Vector(0, 0, 1)
	end
	out:Normalize()
	local S = (STRENGTH[key] or 1) * G.cv.fleshbleed:GetFloat()
	local region = REGION[key] or A.OTHER
	if pm and S > 0 then
		G.Wounds.Stump(ent, parent, joint, out, region, S, false)
		FL.stats.stumps = FL.stats.stumps + 1
	end
	if not IsValid(gib) then return end
	local t = G.BloodTypeOf(ent)
	gib.ghmpbType = t == nil and false or t
	FL.gibs[gib] = true
	if G.Entities.domains[ent] and G.Entities.Clone(ent, gib) then FL.stats.clones = FL.stats.clones + 1 end
	if G.Wounds.MoveEmitters then G.Wounds.MoveEmitters(ent, gib, chain) end
	if S > 0 then
		timer.Simple(0.05, function()
			if not IsValid(gib) then return end
			if not gib:GetBoneMatrix(root) then gib:SetupBones() end
			local gm = gib:GetBoneMatrix(root)
			if not gm then return end
			G.Wounds.Stump(gib, root, gm:GetTranslation(), -out, region, S * 0.6, true)
			FL.stats.limbs = FL.stats.limbs + 1
		end)
	end
	if G.Smear and G.Smear.state then G.Smear.state[gib] = nil end
	if U and U.RefreshCorpses then U.RefreshCorpses() end
end

hook.Add("GHMFL_ClientSever", "ghmpb_flesh", function(ent, key, gib)
	local ok, err = pcall(OnSever, ent, key, gib)
	if not ok then ErrorNoHalt("[GHMPB] GHM FLESH sever: " .. tostring(err) .. "\n") end
end)

function FL.IsGib(e) return IsValid(e) and (e.ghmflGib == true or FL.gibs[e] == true) end

-- (1.26.11) Visceral physiology & deep crater bridge to GHM FLESH 1.19+:
--   * Named severed arteries/veins (carotid, subclavian, brachial, aorta, femoral, vena cava) spawn pressure-coupled
--     PhysBlood arterial emitters + 3D streams modulated in real time by GHMFL's Windkessel pulse & tachycardia BPM.
--   * Punctured lungs & cut airways emit frothy oxygenated (oxy = 1.0) cough sprays that seed bubble rafts on floor pools.
--   * Deep cavernous craters well dark visceral blood from their lowest rim onto the body and floor below.
local function OnVesselHit(ev)
	if not ev or not IsValid(ev.ent) or not G.cv.enable:GetBool() or not G.cv.flesh:GetBool() then return false end
	local ent = ev.ent
	local bt = G.BloodTypeOf(ent)
	if bt == nil then return false end
	local W = G.Wounds
	if not W or not W.Body or not W.AddEmitter then return false end
	local b = W.Body(ent)
	if not b then return false end

	local bone = ev.bone or 0
	local wpos = ev.worldPos or ent:WorldSpaceCenter()
	local jdir = ev.jetDir or Vector(0, 0, 1)
	local lp, ln
	if U and U.BoneToLocal then lp, ln = U.BoneToLocal(ent, bone, wpos, jdir) end
	lp = lp or (ev.localPos or Vector(0, 0, 0))
	ln = ln or (ev.localDir or Vector(0, 0, 1))

	local now = CurTime()
	local scale = G.cv.fleshbleed:GetFloat() * (G.cv.bleed and G.cv.bleed:GetFloat() or 1)
	local artMul = math.max(G.cv.sArtery and G.cv.sArtery:GetFloat() or 1, 0.25)
	local mult = math.Clamp((ev.mult or 5.0) / 5.0, 0.5, 2.4)
	local bpm = 85
	if GHMFL and GHMFL.Physio and GHMFL.Physio.VitalsOf then
		local vb = GHMFL.Physio.VitalsOf(ent)
		if vb and vb > 10 then bpm = vb end
	end

	local isArt = ev.arterial ~= false
	local oxy = ev.aerated and 1.0 or (isArt and 0.98 or 0.48)
	local baseRate = (isArt and 3.8 or 1.9) * mult * scale * (isArt and artMul or 1)
	local baseJet = isArt and (U.RandRange(175, 310) * math.min(math.sqrt(artMul * mult), 1.65)) or nil

	local em = W.AddEmitter(b, {
		kind = isArt and "artery" or "weep",
		name = ev.id or "artery",
		bone = bone,
		lpos = lp,
		lnrm = ln,
		rate = baseRate,
		reservoir = (isArt and 95 or 48) * mult * scale,
		stop = now + (isArt and 36 or 22),
		surface = isArt and 0.18 or 0.52,
		radius = math.Clamp((ev.radiusCm or 0.38) * 0.95, 0.28, 0.65),
		pulseHz = bpm / 60,
		art = artMul,
		jet = baseJet,
		oxy = oxy,
	})

	FL.vessels[#FL.vessels + 1] = {
		ent = ent, btype = bt, bone = bone, lpos = lp, lnrm = ln,
		em = em, baseRate = baseRate, baseJet = baseJet,
		arterial = isArt, oxy = oxy, mult = mult,
		t0 = now, stop = now + (isArt and 24 or 12),
		streamKey = "ghmfl_v_" .. ent:EntIndex() .. "_" .. tostring(ev.idx or math.random(1, 99)),
	}
	if #FL.vessels > 32 then table.remove(FL.vessels, 1) end
	FL.stats.vessels = FL.stats.vessels + 1
	return true
end

local function OnAirwayHit(ev)
	if not ev or not IsValid(ev.ent) or not G.cv.enable:GetBool() or not G.cv.flesh:GetBool() then return end
	local ent = ev.ent
	local bt = G.BloodTypeOf(ent)
	if bt == nil then return end
	local pos = ev.worldPos or ent:WorldSpaceCenter()
	local dir = ev.dir or Vector(0, 0, 1)
	local bone = ev.bone or 0
	local lp, ln
	if U and U.BoneToLocal then lp, ln = U.BoneToLocal(ent, bone, pos, dir) end
	if G.Wounds and G.Wounds.Spray then
		G.Wounds.Spray({
			pos = pos + dir * 1.0, dir = (dir + Vector(0, 0, 0.22)):GetNormalized(),
			cone = 0.72, count = ev.cervical and 14 or 9, speedMin = 65, speedMax = 195,
			r0 = 0.58, spread = 0.9, owner = ent, oxy = 1.0, btype = bt, stretch = 1.35, spin = 12, mist = 0.9,
		}, 1.0)
	end
	FL.airways[#FL.airways + 1] = {
		ent = ent, btype = bt, bone = bone,
		lpos = lp or Vector(0, 0, 0), lnrm = ln or Vector(0, 0, 1),
		cervical = ev.cervical and true or false,
		nextCough = CurTime() + U.RandRange(0.7, 1.5),
		stop = CurTime() + 18,
	}
	if #FL.airways > 20 then table.remove(FL.airways, 1) end
	FL.stats.airways = FL.stats.airways + 1
end

local physioSubbed = false
local function EnsurePhysioBridge()
	if physioSubbed then return end
	local P = GHMFL and GHMFL.Physio
	if not P or not P.SubscribeVessel or not P.SubscribeAirway then return end
	physioSubbed = true
	P.SubscribeVessel("ghmpb_flesh", OnVesselHit)
	P.SubscribeAirway("ghmpb_flesh", OnAirwayHit)
end

local wellTr = { mask = MASK_SOLID_BRUSHONLY, output = {} }
local nextWellScan = 0

function FL.Update()
	for e in pairs(FL.gibs) do if not IsValid(e) then FL.gibs[e] = nil end end
	if not FL.Active() or not G.cv.enable:GetBool() or not G.cv.flesh:GetBool() then return end
	EnsurePhysioBridge()

	local now = CurTime()
	local P = GHMFL and GHMFL.Physio

	-- 1. Modulate severed vessel emitters & 3D streams with live Windkessel pressure and tachycardia BPM
	for i = #FL.vessels, 1, -1 do
		local v = FL.vessels[i]
		local e = v.ent
		if not IsValid(e) and e and e.ghmflRagdoll and IsValid(e.ghmflRagdoll) then e = e.ghmflRagdoll v.ent = e end
		if not IsValid(e) or now > v.stop then
			table.remove(FL.vessels, i)
		else
			local press, bpm = 1.0, 85
			if P and P.VitalsOf then
				local vb, vp, vbf = P.VitalsOf(e)
				press = math.Clamp((vp or 1) * (0.45 + 0.55 * (vbf or 1)), 0.05, 1.2)
				if vb and vb > 5 then bpm = vb elseif vb and vb <= 0 then press = press * 0.12 end
			end
			if v.em then
				v.em.pulseHz = math.max(bpm, 25) / 60
				v.em.rate = v.baseRate * press
				if v.baseJet then v.em.jet = v.baseJet * (0.35 + 0.65 * press) end
			end
			if v.arterial and press > 0.22 and G.Streams and G.Streams.Feed and U and U.LocalToWorld then
				local pulse = (P and P.PulseOf) and P.PulseOf(e, now) or (0.5 + 0.5 * math.sin(now * bpm / 60 * 6.283))
				if pulse > 0.55 then
					G.Streams.Feed(v.streamKey, function()
						if not IsValid(e) then return nil end
						local wp, wn = U.LocalToWorld(e, v.bone, v.lpos, v.lnrm)
						if not wp or not wn then return nil end
						local sp = (95 + 175 * pulse) * press * math.min(v.mult, 1.8)
						return wp + wn * 0.4, wn * sp
					end, v.btype, e, math.Clamp(0.65 * v.mult * press, 0.35, 1.5), 0.09)
				end
			end
		end
	end

	-- 2. Frothy oxygenated cough bursts from punctured lungs / cut airways
	for i = #FL.airways, 1, -1 do
		local a = FL.airways[i]
		local e = a.ent
		if not IsValid(e) or now > a.stop then
			table.remove(FL.airways, i)
		elseif now >= a.nextCough then
			local alive = not (e:IsRagdoll() and not G.LivingRagdoll(e))
			if P and P.VitalsOf then
				local vb = P.VitalsOf(e)
				if vb and vb <= 0 then alive = false end
			end
			if not alive then
				table.remove(FL.airways, i)
			else
				a.nextCough = now + U.RandRange(1.0, 2.3)
				if U and U.LocalToWorld and G.Wounds and G.Wounds.Spray then
					local wp, wn = U.LocalToWorld(e, a.bone, a.lpos, a.lnrm)
					if wp and wn then
						G.Wounds.Spray({
							pos = wp + wn * 0.8, dir = (wn + Vector(0, 0, 0.18)):GetNormalized(),
							cone = 0.68, count = a.cervical and 8 or 5, speedMin = 45, speedMax = 140,
							r0 = 0.52, spread = 0.85, owner = e, oxy = 1.0, btype = a.btype, stretch = 1.25, spin = 10, mist = 0.65,
						}, 0.85)
					end
				end
			end
		end
	end

	-- 3. Deep cavernous GHMFL craters well dark visceral blood from their lowest rim
	if now >= nextWellScan and GHMFL and GHMFL.Bodies then
		nextWellScan = now + 0.28
		local eye = EyePos()
		for ent, fb in pairs(GHMFL.Bodies) do
			if IsValid(ent) and fb and fb.patches and #fb.patches > 0 and ent:GetPos():DistToSqr(eye) < 900 * 900 then
				local bt = G.BloodTypeOf(ent)
				if bt ~= nil then
					for pi = 1, math.min(#fb.patches, 8) do
						local p = fb.patches[pi]
						if p and (p.forceDeep or p.Style == 2 or p.cavityHole) then
							local nextT = FL.craterWell[p] or 0
							local age = now - (p.t0 or now)
							if age < 22 and now >= nextT then
								FL.craterWell[p] = now + U.RandRange(0.55, 1.15)
								local bm = p.bone and ent:GetBoneMatrix(p.bone)
								local wp = bm and p.lpos and (bm * p.lpos) or ent:WorldSpaceCenter()
								local wn = Vector(0, 0, -1)
								if bm and p.lnrm then
									wn = LocalToWorld(p.lnrm, angle_zero, vector_origin, bm:GetAngles()):GetNormalized()
								end
								local rimLow = wp + Vector(0, 0, -math.Clamp((p.radius or 3) * 0.45, 0.8, 3.5))
								if G.Entities and G.Entities.Impact then
									G.Entities.Impact(ent, rimLow, wn, Vector(0, 0, -35), 0.42, 10, 1, 0, 1.15, 0.15, p.bone, { btype = bt, oxy = 0.46 })
								end
								wellTr.start = rimLow + Vector(0, 0, 2)
								wellTr.endpos = rimLow - Vector(0, 0, 38)
								util.TraceLine(wellTr)
								local r = wellTr.output
								if r and r.Hit and not r.StartSolid and G.Surfaces and G.Surfaces.Impact then
									G.Surfaces.Impact(r.HitPos, r.HitNormal, Vector(0, 0, -45), 0.75, 14, 1, 0, 1.05, 0.1, r, 0.46, bt)
									if G.Surfaces.WellWave then G.Surfaces.WellWave(r.HitPos, 0.35) end
									FL.stats.craters = FL.stats.craters + 1
								end
							end
						end
					end
				end
			end
		end
	end
end

function FL.Clear()
	FL.gibs = {}
	FL.vessels = {}
	FL.airways = {}
end
