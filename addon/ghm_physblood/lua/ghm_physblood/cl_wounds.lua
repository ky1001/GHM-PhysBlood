local G = GHMPB
G.Wounds = G.Wounds or {}
local W = G.Wounds
local A = G.Anatomy
local U = G.U

W.bodies = W.bodies or {}

W.faceAxes = W.faceAxes or {}
function W.FaceFrame(ent)
	local sk = A.GetSkeleton(ent)
	local scale = ent:GetModelScale() or 1
	local att = ent:LookupAttachment("eyes")
	if att and att > 0 then
		local a = ent:GetAttachment(att)
		if a then
			local m = ent:LookupAttachment("mouth")
			local mouth = (m and m > 0) and ent:GetAttachment(m) or nil
			return { eyes = a.Pos, F = a.Ang:Forward(), U = a.Ang:Up(), R = a.Ang:Right(), scale = scale, mouth = mouth and mouth.Pos }
		end
	end
	local hb = sk and (sk.head or sk.headGuess)
	if not hb then return nil end
	local M = ent:GetBoneMatrix(hb)
	if not M then return nil end
	local mdl = ent:GetModel()
	local ax = W.faceAxes[mdl]
	if not ax then
		if ent:IsNPC() or ent:IsPlayer() then
			ax = { F = WorldToLocal(ent:GetForward(), angle_zero, vector_origin, M:GetAngles()),
			       U = WorldToLocal(ent:GetUp(), angle_zero, vector_origin, M:GetAngles()) }
			W.faceAxes[mdl] = ax
		else
			ax = { F = Vector(0, 1, 0), U = Vector(1, 0, 0) }
		end
	end
	local F = LocalToWorld(ax.F, angle_zero, vector_origin, M:GetAngles())
	local Up = LocalToWorld(ax.U, angle_zero, vector_origin, M:GetAngles())
	local R = F:Cross(Up) R:Normalize()
	local eyes = M:GetTranslation() + Up * 3.2 * scale + F * 3.0 * scale
	return { eyes = eyes, F = F, U = Up, R = R, scale = scale }
end

local function Outlet(ent, kind, side)
	local f = W.FaceFrame(ent)
	if not f then return nil end
	local s = f.scale
	if kind == "nose" then
		local p = f.eyes - f.U * 2.25 * s + f.F * 0.55 * s + f.R * (0.32 * side) * s
		local n = (f.F * 0.75 - f.U * 0.65) n:Normalize()
		return p, n
	elseif kind == "mouth" then
		local p = (f.mouth or (f.eyes - f.U * 3.7 * s + f.F * 0.4 * s)) + f.R * (0.75 * side) * s
		local n = (f.F - f.U * 0.35) n:Normalize()
		return p, n
	elseif kind == "ear" then
		local p = f.eyes - f.U * 0.9 * s - f.F * 2.3 * s + f.R * (2.85 * side) * s
		return p, f.R * side
	end
end

function W.BloodVolume(ent)
	local ml = G.cv.bloodvol:GetFloat()
	local scale = ent:GetModelScale() or 1
	local sk = A.GetSkeleton(ent)
	local f = 1
	if not (sk and sk.humanoid) and ent.GetModelBounds then
		local mn, mx = ent:GetModelBounds()
		if mn and mx then
			local d = mx - mn
			f = math.Clamp(math.abs(d.x * d.y * d.z) / 48000, 0.03, 8)
		end
	end
	return ml * f * scale * scale * scale
end

local function Left(b) return math.max((b.budget or 4000) - (b.lostML or 0), 0) end
W.BloodLeft = Left

-- (1.26.6) the spatter of a bullet through a body that no longer bleeds (long dead, or drained): back spatter and the
-- traced back plume, and if it goes through the exit spray and exit plume - at 45 % strength, no new wound bleeding
function W.SpatterOnly(ent, pos, dir, dmg, dmgtype, hitgroup, attacker, btype, S)
	local Fo = G.Forensic
	if not Fo or not Fo.Ballistic or not Fo.ExitPlume or not IsValid(ent) or not dir then return end
	local surf, nrm, hitBone = U.EntitySurface(ent, pos, dir)
	if not surf or not nrm then return end
	local bone = hitBone or U.NearestBone(ent, surf, hitgroup)
	local region = A.RegionFromHit(ent, bone, hitgroup)
	local bal, balE = Fo.Ballistic(dmg, dmgtype, attacker)
	-- (1.26.10) a drained body still takes the bullet's holes (cl_holes.lua)
	local Ho = G.Holes
	if Ho and Ho.On() then
		local hs, _, hb = U.SnapToMesh(ent, surf, nrm, bone, true)
		Ho.FromBullet(ent, hb or bone, hs or surf, dir, bal, balE, 0)
	end
	local cv = G.cv
	local s = (S or 1) * 0.45
	local head = region == A.HEAD
	if head and G.VAT then G.VAT.mute = true end   -- (1.26.8) no fluid bursts from a head hit (see below)
	Fo.oxy = 0.5
	if cv.sEntry:GetFloat() > 0 then
		Fo.BackSpatter(ent, surf, nrm, dir, s, btype, cv.sEntry:GetFloat() * bal.back)
		Fo.ExitPlume(ent, surf + nrm * 1.5, (nrm * 0.55 - dir * 0.45):GetNormalized(), bal.backProf, balE * 0.67, btype, 0.5, cv.sEntry:GetFloat(), head)
	end
	if cv.sExit:GetFloat() <= 0 or not Fo.Exits(bal, region, IsValid(attacker) and attacker:GetPos():Distance(surf) or nil) then
		if G.Screen then pcall(G.Screen.FromHit, ent, surf, nrm, dir, btype, 0.5, s, false) end   -- (1.26.10)
		return
	end
	-- (1.26.8) the exit found on ragdolls too (W.FindExit)
	local ex, en, xb, onBody = W.FindExit(ent, surf, dir, region)
	if onBody and Ho and Ho.On() then
		local hx, _, hxb = U.SnapToMesh(ent, ex, en, xb, true)
		Ho.FromBullet(ent, hxb or xb, hx or ex, dir, bal, balE, 1)
	end
	Fo.ForwardSpatter(ent, ex, en, dir, s, btype, cv.sExit:GetFloat() * bal.fwd)
	Fo.ExitPlume(ent, ex, dir, bal, balE * 0.67, btype, 0.5, cv.sExit:GetFloat(), head)
	W.spatterOnly = (W.spatterOnly or 0) + 1
	if G.Screen then pcall(G.Screen.FromHit, ent, surf, nrm, dir, btype, 0.5, s, true) end   -- (1.26.10)
end

function W.CorpseFactor(b)
	local t0 = b.deathTime or b.corpseT0
	if not t0 then return 1 end
	local T = G.cv.corpsebleed:GetFloat()
	local full = math.min(30, T * 0.5)
	local t = CurTime() - t0
	if t <= full then return 1 end
	return math.Clamp(1 - (t - full) / math.max(T - full, 1), 0, 1)
end

function W.Body(ent)
	local b = W.bodies[ent]
	if b then return b end
	b = { ent = ent, wounds = {}, emitters = {}, dead = false, nextTick = 0, btype = G.BloodTypeOf(ent) or 0, lastCough = 0,
		entIndex = ent:EntIndex(), lostML = 0 }
	b.budget = W.BloodVolume(ent)
	if ent:IsRagdoll() and not G.LivingRagdoll(ent) then
		local fromNPC = ent:GetNW2Int("ghmpb_blood", -2) ~= -2 or ent.ghmpbType ~= nil
		local t0 = fromNPC and ent.GetCreationTime and ent:GetCreationTime() or nil
		b.corpseT0 = (t0 and t0 > 0 and t0 <= CurTime()) and t0 or CurTime()
	end
	W.bodies[ent] = b
	return b
end

-- (1.26.9c) wider spread, so where a body is hit shows in the colour of its blood: the neck (carotid) and the chest (lungs,
-- heart) bleed bright, oxygenated scarlet; the abdomen (liver, gut veins) and the pelvis dark, venous maroon; limbs in
-- between, the far ends of them darker (venous return)
W.REGION_OXY = {
	[A.HEAD] = 0.86, [A.NECK] = 0.94, [A.CHEST] = 0.97, [A.ABDOMEN] = 0.48, [A.PELVIS] = 0.56,
	[A.UPPERARM] = 0.8, [A.FOREARM] = 0.74, [A.HAND] = 0.72, [A.THIGH] = 0.78, [A.CALF] = 0.68, [A.FOOT] = 0.64, [A.OTHER] = 0.72,
}
-- (1.26.9c) every body has blood of its own shade: a fixed offset of its oxygenation (-0.16 .. +0.08, from the entity index,
-- carried over to its ragdoll with the body record). Blood of different bodies mixes texel by texel where it meets (the
-- live layer carries the oxygenation per texel), and a patch's settled layer keeps the volume-weighted mix
function W.OxyBias(ent)
	if not IsValid(ent) then return 0 end
	local b = W.bodies and W.bodies[ent]
	if b and b.oxyBias then return b.oxyBias end
	local v = ent.ghmpbOxyBias
	if not v then
		local x = math.sin(ent:EntIndex() * 12.9898 + 78.233) * 43758.5453
		v = -0.16 + 0.24 * (x - math.floor(x))
		ent.ghmpbOxyBias = v
	end
	if b then b.oxyBias = v end
	return v
end
local function RegOxy(region, ent)
	local o = W.REGION_OXY[region] or 0.72
	if ent then o = o + W.OxyBias(ent) end
	return math.Clamp(o, 0.3, 1)
end
W.RegOxy = RegOxy

local function MergeInto(b, e, now)
	if not e.bone or not e.lpos or e.outlet or e.geyser or (e.start and e.start > now + 0.05) then return nil end
	local bt = G.Battle and G.Battle.level or 0
	local r = 2.6 + 2.4 * bt
	local r2 = r * r
	for i = #b.emitters, 1, -1 do
		local x = b.emitters[i]
		if x.kind == e.kind and x.bone == e.bone and x.lpos and not x.outlet and not x.geyser and now < x.stop
			and x.emitted < x.reservoir and x.lpos:DistToSqr(e.lpos) < r2 then
			x.rate = x.rate + e.rate
			x.reservoir = x.reservoir + e.reservoir
			x.stop = math.max(x.stop, e.stop)
			x.radius = math.min(math.max(x.radius or 0.3, e.radius or 0.3) * 1.08, 1.2)
			x.fatal = x.fatal or e.fatal
			if e.jet and x.jet then x.jet = math.max(x.jet, e.jet) end
			x.merged = (x.merged or 0) + 1
			W.stats.merged = W.stats.merged + 1
			return x
		end
	end
	return nil
end
W.stats = W.stats or { merged = 0 }

local function AddEmitter(b, e)
	local now = CurTime()
	local m = MergeInto(b, e, now)
	if m then return m end
	e.start = e.start or now
	e.emitted = 0
	e.acc = 0
	table.insert(b.emitters, e)
	if #b.emitters > 24 then table.remove(b.emitters, 1) end
	return e
end
W.AddEmitter = AddEmitter

W.HARD_IMPACT, W.SMASH_IMPACT = 60, 150

local function Strength(dmg)
	return math.Clamp(dmg / 60, 0.3, 2.5) * G.cv.bleed:GetFloat() * G.cv_sv_bleed:GetFloat()
end

local function Shape(o, m)
	local cv = G.cv
	local speed = cv.sSpeed:GetFloat()
	o.count = math.floor((o.count or 10) * m + 0.5)
	o.r0 = (o.r0 or 0.6) * cv.sSize:GetFloat()
	o.speedMin = (o.speedMin or 100) * speed
	o.speedMax = (o.speedMax or 300) * speed
	o.cone = math.min((o.cone or 0.4) * cv.sSpread:GetFloat(), 1.4)
	if o.mist then o.mist = o.mist * math.min(m, 3) end
	return o
end

local function Spray(o, m)
	if m and m > 0.001 then G.Particles.Spray(Shape(o, m)) end
end
W.Spray = Spray

local function MeleeArc(ent, pos, nrm, dir, S, btype, blunt, oxy, sweepDir, bone)
	local m = G.cv.sMelee:GetFloat()
	if m <= 0.001 then return end
	local side = dir:Cross(Vector(0, 0, 1))
	if side:LengthSqr() < 0.01 then side = dir:Cross(Vector(1, 0, 0)) end
	side:Normalize()
	if math.random() < 0.5 then side = -side end
	local up = side:Cross(dir) up:Normalize()
	local sweep = (side + up * U.RandRange(-0.6, 0.6)):GetNormalized()
	-- 1.26.0: the blade's real direction of motion (G.Blades tracks the attacker's hand): the spray from the cut is
	-- dragged along the way the weapon travelled
	if sweepDir then
		local s2 = sweepDir - dir * sweepDir:Dot(dir)
		if s2:LengthSqr() > 0.04 then sweep = s2:GetNormalized() end
	end
	local lp, ln = bone and U.BoneToLocal and U.BoneToLocal(ent, bone, pos, nrm)
	if G.Forensic and G.Forensic.CastOffArc then
		G.Forensic.CastOffArc(pos + nrm * 0.5, dir, sweep, 145, math.Clamp(math.floor(4 + 4 * S), 4, 12), math.Clamp(0.6 * S * m, 0.3, 1.8), ent, oxy or 0.8, btype)
	end
	local steps = 7
	for k = 0, steps - 1 do
		local t = k / (steps - 1)
		local a = (t - 0.5) * 1.4
		local d = (sweep * math.cos(a) + dir * (math.sin(a) * 0.6 + 0.25) + nrm * 0.3):GetNormalized()
		timer.Simple(t * 0.12, function()
			if G.Render and G.Render.Redirect then ent = G.Render.Redirect(ent) end
			if not IsValid(ent) then return end
			local wpos, wnrm = pos, nrm
			if lp and U.BoneToWorld then
				local wp, wn = U.BoneToWorld(ent, bone, lp, ln)
				if wp then wpos, wnrm = wp, wn or nrm end
			end
			Spray({ pos = wpos + wnrm * 0.5 + sweep * ((t - 0.5) * 3), dir = d, cone = 0.12,
				count = math.floor((4 + 6 * S) * (blunt and 0.4 or 1)), speedMin = 180, speedMax = 480,
				r0 = blunt and 0.5 or 0.9, spread = 0.7, owner = ent, oxy = oxy or 0.8, btype = btype,
				stretch = blunt and 1.4 or 2.6, spin = 25, ownerGrace = 0.15 }, m)
		end)
	end
	return sweep
end
W.MeleeArc = MeleeArc

local function BloodAtSite(b, ent, pos, bone)
	local ml = 0
	for _, w in ipairs(b.wounds) do
		local wp
		if w.bone then
			local m = ent:GetBoneMatrix(w.bone)
			if m then wp = LocalToWorld(w.lpos, angle_zero, m:GetTranslation(), m:GetAngles()) end
		else
			wp = ent:LocalToWorld(w.lpos)
		end
		if wp and wp:DistToSqr(pos) < 10 * 10 then ml = ml + (w.pen and 1.5 or 0.6) * w.S end
	end
	local d = G.Entities.domains[ent]
	if d and d.wet and G.Smear then
		local key = G.Smear.WetKey(ent, bone, pos)
		if key and d.wet[key] then ml = ml + d.wet[key] / 1000 * 0.5 end
	end
	return ml
end
W.BloodAtSite = BloodAtSite

function W.ImmediateBlastWorld(pos, dir, dmg, blastPos, btype, ent, fatal)
	if not G.cv.enable:GetBool() or not pos then return false end
	local m = G.cv.sBlast:GetFloat()
	if m <= 0.001 or not G.Forensic then return false end
	local S = Strength(dmg)
	local bp = blastPos or (pos - dir * 48)
	local d = pos - bp
	local dist = d:Length()
	d = dist > 1 and (d / dist) or dir
	local bdir = (d + Vector(0, 0, 0.24)):GetNormalized()
	if G.VAT then
		G.VAT.OnBlast(pos, bdir, S, btype or 0, IsValid(ent) and ent or nil, nil)
	end
	local P = math.Clamp(S * (dist < 64 and 1.35 or 1.05), 0.35, 3)
	if dmg < 15 and not fatal then m = m * dmg / 15 end
	local sites = {
		{ pos = pos, w = 3 },
		{ pos = pos + Vector(0, 0, 14), w = 2 },
		{ pos = pos - Vector(0, 0, 14), w = 1.5 },
	}
	G.Forensic.BlastSpatter(IsValid(ent) and ent or nil, sites, d, P, btype or 0, m, 0.78)
	return true
end

-- (1.26.8) GHM: "blood back splatter doesn't always carry over from the NPC state to the ragdoll state, so it does not
-- always appear, while it should if the damage is right" (a .357 through the chest, five kills, no splat on the wall
-- behind once). The killing shot reaches this client while the NPC is turning into its ragdoll, and the blood thrown
-- out of the back was lost on the way: the hit waited for the ragdoll (and could be dropped), or landed on the ragdoll,
-- which this client cannot trace through like an NPC (no exit found, no exit spray, no exit plume), or the blood
-- leaving the exit wound hit the ragdoll standing in the NPC's place. Now:
--  * the exit is found on any body: the engine's trace (NPCs, players), PhysBlood's own ray through the hitboxes at the
--    body's bones (ragdolls, the engine first for them is not reliable), and when the body is no longer where the
--    bullet went (a ragdoll that fell since), where it was, from how thick the body is there (W.FindExit)
--  * a bullet's blood flies at the moment of the hit, from where and the way the server says it hit, also when the body
--    is not on this client yet or not ready (W.ShotWorld); the body's own part (wounds, bleeding) follows on the body
--  * the blood leaving a body passes the NPC and its ragdoll alike (F.PlumeFilter, cl_particles Partner)
local HG_REGION = { [HITGROUP_HEAD or 1] = A.HEAD, [HITGROUP_CHEST or 2] = A.CHEST, [HITGROUP_STOMACH or 3] = A.ABDOMEN,
	[HITGROUP_LEFTARM or 4] = A.UPPERARM, [HITGROUP_RIGHTARM or 5] = A.UPPERARM, [HITGROUP_LEFTLEG or 6] = A.THIGH,
	[HITGROUP_RIGHTLEG or 7] = A.THIGH }
W.HG_REGION = HG_REGION
-- how far a bullet goes through the body there (u, adult human): where its exit is when the body cannot be traced
W.THICK = { head = 6.5, neck = 4.5, chest = 10, abdomen = 9, pelvis = 9, upperarm = 3.5, forearm = 3, hand = 2, thigh = 5.5,
	calf = 4, foot = 3, other = 7 }
local BULLET = bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER or 0, DMG_AIRBOAT or 0)
local function IsBullet(dmgtype) return bit.band(dmgtype or 0, BULLET) ~= 0 end
W.IsBullet = IsBullet
local exitTr = { mask = MASK_SHOT, ignoreworld = true }
W.exitStats = W.exitStats or { trace = 0, boxes = 0, guessed = 0 }
-- where the bullet that went in at surf (way dir) leaves the body: pos, normal, bone, and whether that is on the body
function W.FindExit(ent, surf, dir, region)
	local far = surf + dir * 44
	local near = surf + dir * 0.5
	local function Trace()
		exitTr.start, exitTr.endpos = far, near
		exitTr.filter = function(e) return e == ent end
		local tr = util.TraceLine(exitTr)
		if tr.Hit and tr.Entity == ent and tr.HitPos:Distance(surf) < 40 then
			return tr.HitPos, tr.HitNormal, U.TraceBone(ent, tr) or U.NearestBone(ent, tr.HitPos)
		end
	end
	local function Boxes()
		if not U.RayHitboxes then return nil end
		local ok, hp, hn, _, bone = pcall(U.RayHitboxes, ent, far, near - far)
		if ok and hp and hp:Distance(surf) < 40 and hp:Distance(surf) > 0.5 then return hp, hn, bone end
	end
	local rag = ent.IsRagdoll and ent:IsRagdoll()
	local hp, hn, bone = (rag and Boxes or Trace)()
	local how = hp and (rag and "boxes" or "trace")
	if not hp then
		hp, hn, bone = (rag and Trace or Boxes)()
		how = hp and (rag and "trace" or "boxes")
	end
	if hp then
		W.exitStats[how] = W.exitStats[how] + 1
		return hp, hn, bone, true
	end
	W.exitStats.guessed = W.exitStats.guessed + 1
	local sc = ent.GetModelScale and ent:GetModelScale() or 1
	return surf + dir * (W.THICK[region] or 7) * math.Clamp(sc or 1, 0.3, 3), Vector(dir), nil, false
end

function W.ShotWorld(pos, dir, dmg, dmgtype, hitgroup, attacker, btype, ent, region)
	local Fo = G.Forensic
	if not G.cv.enable:GetBool() or not pos or not dir or not Fo or not Fo.Ballistic or not Fo.ExitPlume then return false end
	if not IsBullet(dmgtype) or btype == false then return false end
	if pos:DistToSqr(EyePos()) > (G.LIVE_RANGE + 1500) ^ 2 then return false end
	btype = btype or G.BLOOD_RED
	dir = dir:GetNormalized()
	region = region or HG_REGION[hitgroup or 0] or A.OTHER
	local head = region == A.HEAD
	if head and G.VAT then G.VAT.mute = true end   -- (1.26.8) no fluid bursts from a head hit (see below)
	local bal, balE = Fo.Ballistic(dmg, dmgtype, attacker)
	local S = Strength(dmg)
	local rox = RegOxy(region, ent)
	local cv = G.cv
	local body = IsValid(ent) and ent or nil
	local nrm = -dir
	Fo.oxy = rox
	local en = cv.sEntry:GetFloat()
	if en > 0 then
		Fo.BackSpatter(body, pos, nrm, dir, S, btype, en * bal.back * (head and 1.25 or 1))
		if bal.backProf then Fo.ExitPlume(body, pos + nrm * 1.5, nrm, bal.backProf, balE, btype, rox, en, head) end
		if G.VAT then G.VAT.OnEntry(pos, nrm, dir, S, btype, body, nil) end
	end
	local xm = cv.sExit:GetFloat()
	if xm > 0 and dmg >= 8 and Fo.Exits(bal, region, IsValid(attacker) and attacker:GetPos():Distance(pos) or nil) then
		local ex = pos + dir * (W.THICK[region] or 7)
		Fo.ForwardSpatter(body, ex, dir, dir, S, btype, xm * bal.fwd * (head and 1.25 or 1))
		Fo.ExitPlume(body, ex, dir, bal, balE, btype, rox, xm, head)
		if G.VAT then G.VAT.OnExit(ex, dir, dir, S, btype, body, nil) end
	end
	W.shotWorld = (W.shotWorld or 0) + 1
	return true
end

function W.Blast(ent, b, blastPos, dir, dmg, S, btype, fatal, corpseHit, worldDone)
	local m = G.cv.sBlast:GetFloat()
	local sk = A.GetSkeleton(ent)
	local E = G.Entities
	local c = ent:WorldSpaceCenter()
	local d = c - blastPos
	local dist = d:Length()
	d = dist > 1 and (d / dist) or dir
	local bdir = (d + Vector(0, 0, 0.24)):GetNormalized()
	if not worldDone and G.VAT and m > 0 and IsValid(ent) then
		G.VAT.OnBlast(c, bdir, S, btype, ent, sk and (sk.chest or sk.pelvis))
	end
	if m <= 0.001 or not G.Forensic then return end
	local P = math.Clamp(S * (dist < 64 and 1.35 or 1.05), 0.35, 3)
	if dmg < 15 and not fatal then m = m * dmg / 15 end
	if corpseHit then m = m * 0.65 end
	local sites = {}
	local function add(bone, w)
		if not bone then return end
		local mtx = ent:GetBoneMatrix(bone)
		if mtx then sites[#sites + 1] = { pos = mtx:GetTranslation(), bone = bone, w = w } end
	end
	if sk then
		add(sk.chest, 3) add(sk.abdomen, 2) add(sk.pelvis, 1.5) add(sk.neck, 0.6) add(sk.head or sk.headGuess, 1)
		for _, r in ipairs({ A.UPPERARM, A.FOREARM, A.THIGH, A.CALF }) do
			for _, bb in ipairs(sk.regions[r] or {}) do add(bb, 0.45) end
		end
	end
	if #sites == 0 then sites[1] = { pos = c, w = 1 } end
	if not worldDone then
		G.Forensic.BlastSpatter(ent, sites, d, P, btype, m, 0.78)
	end
	local woundMul = G.cv.sWound:GetFloat()
	local near = {}
	for _, s in ipairs(sites) do if s.bone then near[#near + 1] = s end end
	if #near == 0 then return end
	table.sort(near, function(x, y) return x.pos:DistToSqr(blastPos) < y.pos:DistToSqr(blastPos) end)
	local nW = math.min(#near, math.floor(2 + 2.5 * P * math.min(m, 2) + math.random() * 2))
	local now = CurTime()
	for wIdx = 1, nW do
		local s = near[math.random(1, math.min(#near, nW + 2))]
		local surf, nrm = U.EntitySurface(ent, s.pos + VectorRand() * 4, d)
		surf, nrm, s.bone = U.SnapToMesh(ent, surf, nrm, s.bone, true)
		local lp, ln = U.BoneToLocal(ent, s.bone, surf, nrm)
		local region = A.RegionFromHit(ent, s.bone, 0)
		local ox = RegOxy(region)
		if woundMul > 0 then
			E.Impact(ent, surf, nrm, d * 60, 0.25 * math.sqrt(P), 110 * P * woundMul, 2, 0, 1, 0.85, s.bone, { oxy = ox, btype = btype })
			E.Impact(ent, surf + VectorRand() * 2, nrm, d * 150, 1.2 + 0.6 * math.random(), 190 * P * woundMul, 0,
				U.RandRange(-30, 30), 1.8, 0.4, s.bone, { oxy = ox, btype = btype })
		end
		if lp then
			table.insert(b.wounds, { bone = s.bone, lpos = lp, lnrm = ln, region = region, S = S * 0.7, time = now, pen = true })
			if #b.wounds > 12 then table.remove(b.wounds, 1) end
			if not corpseHit then
				AddEmitter(b, { kind = "weep", bone = s.bone, lpos = lp, lnrm = ln, rate = 0.45 * P, reservoir = 10 * P, stop = now + 35,
					surface = 0.75, radius = 0.35, oxy = ox * 0.9 })
				if wIdx == 1 and P >= 0.75 and G.cv.arterial:GetBool() then
					local art = math.max(G.cv.sArtery:GetFloat(), 0.6)
					AddEmitter(b, { kind = "artery", name = "blast", bone = s.bone, lpos = lp, lnrm = ln, rate = 3.6 * P * art,
						reservoir = 65 * P * art, stop = now + 18, surface = 0.15, radius = 0.4, pulseHz = 1.4, art = art,
						jet = U.RandRange(170, 290) * math.min(math.sqrt(art), 1.4), oxy = 1.0 })
				end
			end
		end
	end
	b.lostML = b.lostML + 45 * P * m
end

-- (1.26.9d) the ring of streaks round a hit close to the floor: n small drops laid at a shallow angle round fp, each a
-- stretched stain with its tail pointing away from the hit (the tail is the part of the drop that ran on along the floor)
local streakTr = { mask = MASK_SOLID_BRUSHONLY }
function W.RadialStreaks(fp, up, dir, n, oxy, btype)
	local S = G.Surfaces
	if not (S and S.Impact) then return 0 end
	local side = up:Cross(Vector(1, 0, 0))
	if side:LengthSqr() < 0.01 then side = up:Cross(Vector(0, 1, 0)) end
	side:Normalize()
	local fwd = side:Cross(up)
	fwd:Normalize()
	local bd = dir and (dir - up * dir:Dot(up)) or nil
	if bd and bd:LengthSqr() > 0.01 then bd:Normalize() else bd = nil end
	local Fo = G.Forensic
	local laid = 0
	-- (laid 60 a frame: a big ring is a few hundred stains with their tails)
	local function one()
		local az = math.random() * 2 * math.pi
		local h = side * math.cos(az) + fwd * math.sin(az)
		if bd and math.random() < 0.25 then
			h:Mul(0.55)
			h:Add(bd)
			h:Normalize()
		end
		local u = math.random()
		local d = 5 + 75 * u ^ 1.4
		local p0 = fp + h * d + up * 8
		streakTr.start = p0
		streakTr.endpos = p0 - up * 30
		local tr = util.TraceLine(streakTr)
		if tr.Hit and not tr.StartSolid and not tr.HitSky and tr.HitNormal.z > 0.5 then
			local a = math.rad(U.RandRange(-5, 5) + 38 - 28 * u)
			local sp = U.RandRange(220, 460)
			local nrm = tr.HitNormal
			local vel = h * (math.cos(a) * sp) - nrm * (math.sin(a) * sp)
			local rmm = (2.4 - 1.1 * u) * U.RandRange(0.75, 1.3)
			local vn = math.sin(a) * sp
			local R = (Fo and Fo.StainVn) and Fo.StainVn(rmm, vn) or (rmm * 2.6 * G.MM_TO_UNITS)
			local vol = 4.18879 * rmm * rmm * rmm
			if S.Impact(tr.HitPos, nrm, vel, R, vol * 0.86, 0, U.RandRange(-15, 15), U.RandRange(1.25, 1.75), 0.22, tr, oxy, btype) then
				laid = laid + 1
				if math.random() < 0.7 then
					local elong = math.Clamp(1 / math.max(math.sin(a), 0.14), 1.25, 4.2)
					local nT = math.min(math.floor(elong), 3)
					for seg = 1, nT do
						local kk = R * elong * (seg / (nT + 0.5)) * 0.88 + R * 0.5
						S.Impact(tr.HitPos + h * kk, nrm, vel * 0.65, math.max(R * (0.72 - 0.17 * seg), 0.05), vol * 0.14 / nT, 0, 0,
							1.6 + 0.35 * seg, 0.2, tr, oxy, btype)
					end
				end
			end
		end
	end
	local function batch(left)
		for _ = 1, math.min(left, 60) do one() end
		W.radialLaid = (W.radialLaid or 0) + laid
		laid = 0
		if left > 60 then timer.Simple(0, function() batch(left - 60) end) end
	end
	batch(n)
	W.radialBursts = (W.radialBursts or 0) + 1
	return n
end

function W.OnHit(ent, pos, dir, dmg, dmgtype, hitgroup, fatal, attacker, retry, blastPos, worldDone)
	if G.Render and G.Render.Redirect then ent = G.Render.Redirect(ent) end
	if not IsValid(ent) or not G.cv.enable:GetBool() then return end
	if G.Flies and not retry then G.Flies.Disturb(pos or ent:WorldSpaceCenter(), 40) end
	local btype = G.BloodTypeOf(ent)
	if btype == nil then G.DiagCount("hit: on a body that does not bleed on this client (" .. ent:GetClass() .. ")") return end
	if U.EnsureBones then U.EnsureBones(ent) end
	if not ent:GetBoneMatrix(0) then
		ent:SetupBones()
		if U.InvalidateBones then U.InvalidateBones(ent) end
		if not ent:GetBoneMatrix(0) and (retry or 0) < 12 then
			if not worldDone and (blastPos ~= nil or bit.band(dmgtype or 0, DMG_BLAST) ~= 0) then
				worldDone = W.ImmediateBlastWorld(pos or ent:WorldSpaceCenter(), dir, dmg, blastPos, btype, ent, fatal)
			elseif not worldDone and IsBullet(dmgtype) and pos and dir then
				-- (1.26.8) the bullet's blood flies now, not when the body's bones are ready
				worldDone = W.ShotWorld(pos, dir, dmg, dmgtype, hitgroup, attacker, btype, ent)
			end
			timer.Simple(0.03, function() W.OnHit(ent, pos, dir, dmg, dmgtype, hitgroup, fatal, attacker, (retry or 0) + 1, blastPos, worldDone) end)
			return
		end
	end
	local b = W.Body(ent)
	b.btype = btype
	local S = Strength(dmg)
	local cf, left = W.CorpseFactor(b), Left(b)
	if cf <= 0 or left < 1 then
		if fatal then W.OnDeath(ent, nil) end
		-- (1.26.6) a long-dead or drained body still throws blood when a bullet goes through it (it does not bleed again)
		if bit.band(dmgtype or 0, bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT)) ~= 0 and not worldDone then
			W.SpatterOnly(ent, pos, dir, dmg, dmgtype, hitgroup, attacker, btype, S)
		end
		return
	end
	-- (1.26.6) gunshot spatter of a dead or draining body: at least 45 % of a fresh body's
	local spatS = math.max(S * cf * math.min(1, left / 250), S * 0.45)
	S = S * cf * math.min(1, left / 250)
	local phys = G.IsPhysicsDamage(dmgtype)
	local corpseHit = phys and (b.dead or (ent:IsRagdoll() and not G.LivingRagdoll(ent)))
	local hard = corpseHit and dmg >= W.HARD_IMPACT
	if corpseHit and not fatal and not hard and #b.wounds == 0 and not G.Entities.domains[ent]
		and not (G.Lite and G.Lite.bodies and G.Lite.bodies[ent]) then return end
	b.lostML = b.lostML + 1.0 * S
	if phys and not fatal then
		local m = G.cv.physblood:GetFloat()
		if m <= 0 then return end
		local now0 = CurTime()
		local cd = math.max(G.cv.physcd:GetFloat(), 0.1)
		b.physTok = math.min(2, (b.physTok or 2) + (now0 - (b.physT or now0)) / cd)
		b.physT = now0
		W.physStats = W.physStats or { allowed = 0, blocked = 0 }
		if b.physTok < 1 then W.physStats.blocked = W.physStats.blocked + 1 return end
		b.physTok = b.physTok - 1
		W.physStats.allowed = W.physStats.allowed + 1
		S = S * m * (corpseHit and (hard and 0.7 or 0.35) or 1)
	end
	local shot = bit.band(dmgtype, bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT)) ~= 0
	local surf, nrm, hitBone = U.EntitySurface(ent, pos, dir)
	local bone = hitBone or U.NearestBone(ent, surf, shot and hitgroup or nil)
	local region = A.RegionFromHit(ent, bone, hitgroup)
	if region == A.HEAD and G.VAT then G.VAT.mute = true end   -- (1.26.8) no fluid bursts from a head hit (see below)
	local trauma = A.Trauma[region] or A.Trauma[A.OTHER]
	local rox = RegOxy(region, ent)
	local woundX = { oxy = rox }
	if G.Forensic then G.Forensic.oxy = rox end
	local pen = A.IsPenetrating(dmgtype)
	local blunt = A.IsBlunt(dmgtype)
	local blast = bit.band(dmgtype, DMG_BLAST) ~= 0 or blastPos ~= nil
	surf, nrm, bone = U.SnapToMesh(ent, surf, nrm, bone, true)
	if W.HitDebug then W.HitDebug(ent, pos, dir, bone, surf, nrm, hitBone ~= nil) end
	local lp, ln = U.BoneToLocal(ent, bone, surf, nrm)
	if not lp then
		bone = nil
		lp = ent:WorldToLocal(surf)
		ln = WorldToLocal(nrm, angle_zero, vector_origin, ent:GetAngles())
	end
	local E = G.Entities
	local P = G.Particles
	local now = CurTime()
	local sk = A.GetSkeleton(ent)

	local cv = G.cv
	local woundMul = cv.sWound:GetFloat()
	local slash = bit.band(dmgtype, DMG_SLASH) ~= 0 and bit.band(dmgtype, bit.bor(DMG_BULLET, DMG_BUCKSHOT)) == 0
	local club = bit.band(dmgtype, DMG_CLUB) ~= 0
	local Fo = G.Forensic
	local bullet = bit.band(dmgtype, bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT)) ~= 0
	-- (1.26.6) ballistic class of a bullet hit (pistol, magnum, rifle, sniper, buckshot): how much it throws, whether it
	-- goes through, and how far the blood from the exit wound reaches
	local bal, balE
	if bullet and Fo and Fo.Ballistic then bal, balE = Fo.Ballistic(dmg, dmgtype, attacker) end
	-- (1.26.10) the bullet hole where it went in (cl_holes.lua; none while GHM FLESH draws its own wounds)
	if bullet and pen and not blast and G.Holes then G.Holes.FromBullet(ent, bone, surf, dir, bal, balE, 0) end
	local Bl = G.Blades
	local bladesOn = Bl and G.cv.blades and G.cv.blades:GetFloat() > 0 and attacker and IsValid(attacker)
	if slash then
		local sweep = MeleeArc(ent, surf, nrm, dir, S, btype, false, rox, bladesOn and Bl.Sweep(attacker) or nil, bone) or dir
		if G.VAT then G.VAT.OnBlunt(surf, nrm, -sweep, S, btype, ent, bone) end
		if woundMul > 0 then E.Impact(ent, surf, nrm, sweep * 400, 0.35 * math.sqrt(S), 260 * S * woundMul, 2, 0, 3.0, 0.9, bone, woundX) end
		if bladesOn and not corpseHit then
			Bl.Load(attacker, S, btype, dmgtype, BloodAtSite(b, ent, surf, bone), rox)
		elseif Fo and attacker and G.cv.castoff:GetBool() and not corpseHit then
			Fo.CastOff(attacker, surf, S, btype, 0.25 * S + BloodAtSite(b, ent, surf, bone) * 0.3)
		end
	elseif pen or blast then
		if woundMul > 0 then E.Impact(ent, surf, nrm, dir * 50, 0.32 * math.sqrt(S), 220 * S * woundMul, 2, 0, 1, 0.85, bone, woundX) end
		if blast and Fo then
			W.Blast(ent, b, blastPos or (surf - dir * 48), dir, dmg, S, btype, fatal, corpseHit, worldDone)
		elseif Fo and bullet then
			-- (1.26.8) not again when it flew already (W.ShotWorld: the hit came before the body could take it)
			if not worldDone then
				Fo.BackSpatter(ent, surf, nrm, dir, math.max(S, spatS), btype, cv.sEntry:GetFloat() * (bal and bal.back * (region == A.HEAD and 1.25 or 1) or 1))
				-- (1.26.6) and traced back towards the shooter onto the floor and walls in front of the body
				if bal and bal.backProf and Fo.ExitPlume and cv.sEntry:GetFloat() > 0 then
					Fo.ExitPlume(ent, surf + nrm * 1.5, (nrm * 0.55 - dir * 0.45):GetNormalized(), bal.backProf,
						balE * math.sqrt(math.max(spatS / math.max(Strength(dmg), 0.01), 0.45)), btype, rox, cv.sEntry:GetFloat(), region == A.HEAD)
				end
				if G.VAT and cv.sEntry:GetFloat() > 0 then G.VAT.OnEntry(surf, nrm, dir, S, btype, ent, bone) end
			end
		else
			local out = (nrm * 0.65 - dir * 0.35) out:Normalize()
			Spray({ pos = surf + nrm * 0.4, dir = out, cone = 0.55, count = math.floor(8 + 14 * S), speedMin = 60, speedMax = 240,
				r0 = 0.32, spread = 0.65, owner = ent, oxy = rox, btype = btype, mist = 0.35 * S, ownerGrace = 0.08 }, cv.sEntry:GetFloat())
		end
	else
		local site = Fo and BloodAtSite(b, ent, surf, bone) or 0
		E.Impact(ent, surf, nrm, dir * 20, 0.6, 6 * S * math.max(woundMul, 0.2), 1, 0, 1, 0.3, bone, woundX)
		if Fo and not phys then
			local used = Fo.BluntSpatter(ent, surf, nrm, dir, S, btype, site, cv.sEntry:GetFloat())
			if used > 0 and G.VAT then G.VAT.OnBlunt(surf, nrm, dir, S, btype, ent, bone) end
			if used > 0 and attacker and club then
				if bladesOn then Bl.Load(attacker, S * 0.8, btype, dmgtype, site, rox)
				elseif G.cv.castoff:GetBool() then Fo.CastOff(attacker, surf, S, btype, site * 0.35) end
			end
			if dmg > 10 then
				table.insert(b.wounds, { bone = bone, lpos = lp, lnrm = ln, region = region, S = S * 0.4, time = now, pen = false })
			end
		elseif club and dmg > 15 then
			MeleeArc(ent, surf, nrm, dir, S, btype, true, rox, bladesOn and Bl.Sweep(attacker) or nil, bone)
		elseif dmg > 25 then
			Spray({ pos = surf + nrm * 0.4, dir = nrm, cone = 0.7, count = math.floor(3 + 5 * S), speedMin = 40, speedMax = 140,
				r0 = 0.3, spread = 0.5, owner = ent, oxy = rox, btype = btype, ownerGrace = 0.08 }, cv.sEntry:GetFloat())
		end
	end

	if corpseHit and dmg >= W.SMASH_IMPACT and not pen and not blast then
		local k = math.Clamp(dmg / W.SMASH_IMPACT, 1, 3)
		local ftr = util.TraceLine({ start = surf + Vector(0, 0, 8), endpos = surf - Vector(0, 0, 64), mask = MASK_SOLID_BRUSHONLY })
		local onFloor = ftr.Hit and not ftr.StartSolid and not ftr.HitSky and ftr.HitNormal.z > 0.5
		local m = cv.sEntry:GetFloat()
		if m > 0.001 then
			local speed = cv.sSpeed:GetFloat()
			G.Particles.Burst({ pos = onFloor and Vector(ftr.HitPos) or surf, up = onFloor and Vector(ftr.HitNormal) or Vector(0, 0, 1),
				count = math.floor(16 * k * m + 0.5), speedMin = 50 * speed, speedMax = (150 + 30 * k) * speed, elMin = 15, elMax = 60,
				r0 = 0.7 * cv.sSize:GetFloat(), spread = 0.7, radius = 2, owner = ent, oxy = rox * 0.8, btype = btype, ownerGrace = 0.15 })
		end
		if onFloor then
			G.Surfaces.Impact(ftr.HitPos, ftr.HitNormal, vector_origin, 3, 30000 * k * math.min(S, 1.5), 1, 0, 1, 0, ftr, rox * 0.8, btype)
		end
		if G.VAT then G.VAT.OnBlunt(surf, nrm, dir, S * k, btype, ent, bone) end
		W.smashes = (W.smashes or 0) + 1
	end

	-- (1.26.6) whether the bullet leaves the body depends on its class and where it hit (pistol rounds and buckshot often
	-- stay in the torso; buckshot goes through more often close up)
	local exits = true
	local exitWound
	if bal and Fo.Exits then
		exits = Fo.Exits(bal, region, IsValid(attacker) and attacker:GetPos():Distance(surf) or nil)
	end
	-- (1.26.10) the spatter of a hit close in front of you lands on your screen, your hands and the bodies next to it
	-- (cl_screen.lua); whether it went through is known just below
	local screenHit = not phys and G.Screen ~= nil
	if exits and pen and bit.band(dmgtype, bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT)) ~= 0 and dmg >= 8 then
		-- (1.26.8) found on ragdolls too, and where the body was when it has moved off the bullet's path (W.FindExit)
		local ex, en, xb, onBody = W.FindExit(ent, surf, dir, region)
		if onBody then
			ex, en, xb = U.SnapToMesh(ent, ex, en, xb, true)
			exitWound = { xb = xb, ex = ex, en = en }
			if G.Holes then G.Holes.FromBullet(ent, xb, ex, dir, bal, balE, 1) end   -- (1.26.10) and where it came out
			if woundMul > 0 then E.Impact(ent, ex, en, dir * 80, 0.42 * math.sqrt(S), 380 * S * woundMul, 2, 0, 1, 0.8, xb, woundX) end
		end
		if Fo then
			if not worldDone then
				local xm = cv.sExit:GetFloat()
				Fo.ForwardSpatter(ent, ex, en, dir, math.max(S, spatS), btype, xm * (bal and bal.fwd * (region == A.HEAD and 1.25 or 1) or 1))
				-- the blood the bullet carries out to the walls, floor and props behind the body
				if bal and Fo.ExitPlume and xm > 0 then
					Fo.ExitPlume(ent, ex, dir, bal, balE * math.sqrt(math.Clamp(cf * math.min(1, left / 250), 0.45, 1)), btype, rox, xm, region == A.HEAD)
				end
				if G.VAT and cv.sExit:GetFloat() > 0 then G.VAT.OnExit(ex, en, dir, S, btype, ent, xb) end
			end
		else
			Spray({ pos = ex + en * 0.5, dir = dir, cone = 0.33, count = math.floor(26 + 44 * S), speedMin = 220, speedMax = 720,
				r0 = 0.8, spread = 0.75, owner = ent, oxy = rox, btype = btype, stretch = 1.6, spin = 30, mist = 0.9 * S,
				ownerGrace = 0.12 }, cv.sExit:GetFloat())
		end
		if onBody then b.exitCount = (b.exitCount or 0) + 1 end
	end
	if screenHit then
		local ok, err = pcall(G.Screen.FromHit, ent, surf, nrm, dir, btype, rox, math.max(S, spatS), exitWound ~= nil)
		if not ok then ErrorNoHalt("[GHMPB] screen blood: " .. tostring(err) .. "\n") end
	end

	local wound = { bone = bone, lpos = lp, lnrm = ln, region = region, S = S, time = now, pen = pen }
	table.insert(b.wounds, wound)
	if #b.wounds > 12 then table.remove(b.wounds, 1) end
	local replacedFallback = false
	if b.dead and b.emitters then
		for _, em in ipairs(b.emitters) do
			if em.fallback then
				em.bone, em.lpos, em.lnrm = bone, lp, ln
				em.lpv, em.lnv, em.ftr = nil, nil, nil
				em.oxy = rox * 0.9
				em.fallback = nil
				replacedFallback = true
			end
		end
	end
	if not corpseHit and (pen or (dmg > 20 and math.random() < math.max(trauma.weep, 0.25))) then
		AddEmitter(b, { kind = "weep", bone = bone, lpos = lp, lnrm = ln, rate = 0.35 * S, reservoir = 9 * S, stop = now + 30,
			surface = 0.85, radius = 0.3, oxy = rox * 0.9 })
		local deadBody = b.dead or (ent:IsRagdoll() and not G.LivingRagdoll(ent))
		if deadBody and pen and not fatal and not replacedFallback then
			local poolMul = cv.poolsize:GetFloat()
			local rateMul = poolMul ^ 0.7
			-- (1.26.9d) a shot body keeps bleeding into its pool for longer (the pool keeps flowing out for over a minute)
			AddEmitter(b, { kind = "fatal", bone = bone, lpos = lp, lnrm = ln, rate = 5.5 * S * rateMul,
				reservoir = math.min(150 * S * poolMul, Left(b)), stop = now + 75, surface = 0.45, radius = 0.4,
				oxy = rox * 0.85, fatal = true })
		end
	end

	local art = cv.sArtery:GetFloat()
	if pen and dmg >= 12 and cv.arterial:GetBool() and art > 0 and math.random() < math.min(1, trauma.artery * math.max(1, art * 0.5)) then
		AddEmitter(b, { kind = "artery", name = trauma.arteryName, bone = bone, lpos = lp, lnrm = ln, rate = 3.2 * S * art,
			reservoir = 70 * S * art, stop = now + 32, surface = 0.2, radius = 0.35, pulseHz = 1.25, art = art,
			jet = U.RandRange(150, 280) * math.min(math.sqrt(art), 1.4), oxy = 1.0 })
	end

	-- (1.26.7) spurts from the wound after the hit (Universal Directional Blood style): out of the exit wound along the
	-- bullet's path when it went through, else out of the entry wound back towards the shooter
	-- (a dead body has no pressure left: no spurts from shooting a corpse; a living one's carry on onto its ragdoll)
	-- (1.26.8) and the killing shot that reaches this client after the body became its ragdoll: it hit a living body
	if pen and bullet and dmg >= 10 and not corpseHit
		and (fatal or (not b.dead and not (ent:IsRagdoll() and not G.LivingRagdoll(ent))))
		and cv.arterial:GetBool() then
		local xlp, xln
		if exitWound and exitWound.xb then xlp, xln = U.BoneToLocal(ent, exitWound.xb, exitWound.ex, exitWound.en) end
		if xlp and xln then W.AddSpurts(b, ent, exitWound.xb, xlp, xln, dir, dmg, rox)
		else W.AddSpurts(b, ent, bone, lp, ln, -dir, dmg, rox) end
	end

	local kill = cv.sKill:GetFloat()
	if fatal and kill > 0 then
		local out = (nrm * 0.75 - dir * 0.15 + Vector(0, 0, 0.3)):GetNormalized()
		Spray({ pos = surf + nrm * 0.5, dir = out, cone = 0.8, count = math.floor(24 + 24 * S), speedMin = 150, speedMax = 480,
			r0 = 0.9, spread = 0.8, owner = ent, oxy = math.min(rox + 0.1, 1), btype = btype, stretch = 1.8, spin = 30, mist = 1.0 * S, ownerGrace = 0.15 }, kill)
		if pen and not slash then
			Spray({ pos = surf + dir * 8, dir = dir, cone = 0.45, count = math.floor(20 + 20 * S), speedMin = 250, speedMax = 700,
				r0 = 0.9, spread = 0.8, owner = ent, oxy = math.min(rox + 0.1, 1), btype = btype, stretch = 2.0, spin = 30, mist = 0.8 * S, ownerGrace = 0.2 }, kill)
		end
	end

	-- (1.26.9d) a hit close to the floor (a body lying down, a head on the ground): the blood is thrown out low and lands at a
	-- shallow angle all round - a dense ring of small, stretched streaks with tails, all pointing away from the hit (denser and
	-- rounder near it, longer and thinner further out; the lower the hit, the denser; a head shot throws the most). Laid
	-- straight onto the floor (a drop thrown out that low lands within a fraction of a second, and as particles most of them
	-- were lost on the body or came down too fine to see). At most one ring per body every 0.35 s
	local rad = cv.sRadial and cv.sRadial:GetFloat() or 1
	if rad > 0 and pen and bullet and not slash and not worldDone and now >= (b.radialT or 0) then
		local ftr = util.TraceLine({ start = surf + Vector(0, 0, 2), endpos = surf - Vector(0, 0, 34), mask = MASK_SOLID_BRUSHONLY })
		if ftr.Hit and not ftr.StartSolid and ftr.HitNormal.z > 0.7 then
			b.radialT = now + 0.35
			local recent = (b.radialN or 0) * math.exp(-math.max(now - (b.radialLT or 0), 0) / 2)
			b.radialN, b.radialLT = recent + 1, now
			local hgt = math.max(surf.z - ftr.HitPos.z, 0)
			local k = rad * math.Clamp(1.15 - hgt / 34, 0.25, 1) * (region == A.HEAD and 1.5 or 1) / (1 + recent)
			local n = math.min(math.floor((60 + 70 * math.min(S, 1.6)) * k), 240)
			if n > 0 then W.RadialStreaks(ftr.HitPos, ftr.HitNormal, dir, n, rox, btype) end
		end
	end

	if sk and (sk.head or sk.headGuess) and G.cv.facebleed:GetBool() and not corpseHit then
		local isFace = false
		if region == A.HEAD then
			local f = W.FaceFrame(ent)
			isFace = f and (surf - f.eyes):GetNormalized():Dot(f.F) > -0.1 or false
		end
		local function roll(c) return c > 0 and math.random() < c end
		local noseC = trauma.nose * ((region == A.HEAD and not isFace and pen) and 0.5 or 1)
		local mouthC = trauma.mouth
		local earC = pen and trauma.ears or trauma.earsBlunt
		if blast then earC = math.max(earC, 0.7) noseC = math.max(noseC, 0.5) end
		if bit.band(dmgtype, DMG_FALL) ~= 0 and dmg > 30 then noseC = math.max(noseC, 0.6) mouthC = math.max(mouthC, 0.35) end
		local delay = trauma.delayed and U.RandRange(1.0, 4.0) or 0
		local hb = sk.head or sk.headGuess
		if roll(noseC) then
			AddEmitter(b, { kind = "nose", bone = hb, outlet = "nose", rate = 0.22 * S, reservoir = 7 * S, start = now + delay * 0.5,
				stop = now + 50, surface = 0.92, radius = 0.12, oxy = 0.7 })
		end
		if roll(mouthC) then
			AddEmitter(b, { kind = "mouth", bone = hb, outlet = "mouth", rate = 0.3 * S, reservoir = 12 * S, start = now + delay,
				stop = now + 55, surface = 0.85, radius = 0.22, oxy = (region == A.CHEST) and 0.95 or 0.7,
				spit = (region == A.CHEST or region == A.NECK) and 0.35 or 0.1 })
		end
		if roll(earC) then
			local side = 0
			local f = W.FaceFrame(ent)
			if f and not blast then side = (surf - f.eyes):Dot(f.R) >= 0 and 1 or -1 end
			AddEmitter(b, { kind = "ear", bone = hb, outlet = "ear", side = side, rate = 0.09 * S, reservoir = 3.5 * S,
				start = now + U.RandRange(0.5, 2.5), stop = now + 70, surface = 0.95, radius = 0.12, oxy = 0.55 })
		end
		if trauma.cough > 0 and pen and G.cv.cough:GetBool() and math.random() < trauma.cough then
			b.coughUntil = math.max(b.coughUntil or 0, now + 25 * math.min(S, 1.5))
			b.coughStart = now + delay
			b.coughS = math.max(b.coughS or 0, S)
		end
	end

	if fatal then W.OnDeath(ent, region) end
	b.lastRegion = region
end

function W.OnDeath(ent, region, bloodless, retry)
	if G.Render and G.Render.Redirect then ent = G.Render.Redirect(ent) end
	if not IsValid(ent) then return end
	if not W.bodies[ent] and G.BloodTypeOf(ent) == nil then return end
	if U.EnsureBones then U.EnsureBones(ent) end
	if not ent:GetBoneMatrix(0) then
		ent:SetupBones()
		if U.InvalidateBones then U.InvalidateBones(ent) end
		if not ent:GetBoneMatrix(0) and (retry or 0) < 12 then
			timer.Simple(0.03, function() W.OnDeath(ent, region, bloodless, (retry or 0) + 1) end)
			return
		end
	end
	local b = W.Body(ent)
	if b.dead then return end
	b.dead = true
	b.deathTime = CurTime()
	region = region or b.lastRegion
	local now = CurTime()
	local poolMul = G.cv.poolsize:GetFloat()
	local total = (320 + math.random() * 380) * G.cv.bleed:GetFloat() * G.cv_sv_bleed:GetFloat() * poolMul
	if bloodless then total = total * 0.3 end
	total = math.min(total, Left(b))
	if total < 1 then return end
	local rateMul = poolMul ^ 0.7
	local REGION_W = { [A.NECK] = 3, [A.CHEST] = 2.5, [A.ABDOMEN] = 2.2, [A.HEAD] = 2, [A.PELVIS] = 2, [A.THIGH] = 1.6,
		[A.UPPERARM] = 1, [A.CALF] = 0.8 }
	local latest = b.wounds[#b.wounds]
	local rest = {}
	for i = 1, #b.wounds - 1 do rest[#rest + 1] = b.wounds[i] end
	table.sort(rest, function(a, c) return (REGION_W[a.region] or 0.6) * a.S > (REGION_W[c.region] or 0.6) * c.S end)
	local ws = {}
	if latest then ws[1] = latest end
	for _, w in ipairs(rest) do ws[#ws + 1] = w end
	local n = math.min(#ws, 3)
	for k = 1, n do
		local w = ws[k]
		-- (1.26.9d) bleeding out takes longer (120 s, was 60): the pool round a body keeps growing for a couple of minutes
		AddEmitter(b, { kind = "fatal", bone = w.bone, lpos = w.lpos, lnrm = w.lnrm, rate = 12 / n * rateMul, reservoir = total / n,
			stop = now + 120, surface = 0.5, radius = 0.45, oxy = RegOxy(w.region, ent) * 0.9, fatal = true })
	end
	if n == 0 and not bloodless then
		local sk = A.GetSkeleton(ent)
		local bone = sk and (sk.chest or sk.abdomen or sk.pelvis) or 0
		AddEmitter(b, { kind = "fatal", bone = bone, lpos = vector_origin, lnrm = Vector(0, 0, 1), rate = 3 * rateMul, reservoir = total * 0.4,
			stop = now + 40, surface = 0.5, radius = 0.5, oxy = 0.72, fatal = true, fallback = true })
	end
	local sk = A.GetSkeleton(ent)
	if G.cv.geyser:GetBool() and G.cv.arterial:GetBool() and not bloodless then
		local w = ws[1]
		local reg = w and w.region or region
		if not w or reg == A.NECK or reg == A.HEAD or reg == A.CHEST or reg == A.ABDOMEN then
			local art = math.max(G.cv.sArtery:GetFloat(), 0.5)
			AddEmitter(b, { kind = "artery", geyser = true, bone = w and w.bone or (sk and (sk.neck or sk.chest)),
				lpos = w and w.lpos or vector_origin, lnrm = w and w.lnrm or Vector(0, 0, 1),
				rate = 7 * art, reservoir = 120 * art, start = now + 0.05, stop = now + 9, surface = 0.05, radius = 0.45,
				pulseHz = 1.7, jet = U.RandRange(260, 360) * math.min(math.sqrt(art), 1.25), up = 1.0, oxy = 1.0,
				fallback = (w == nil) or nil })
		end
	end
	local hb = sk and (sk.head or sk.headGuess)
	if hb and not bloodless and (region == A.HEAD or region == A.NECK or region == A.CHEST) and G.cv.facebleed:GetBool() then
		AddEmitter(b, { kind = "mouth", bone = hb, outlet = "mouth", rate = 0.7, reservoir = 30, start = now + U.RandRange(0.5, 2),
			stop = now + 60, surface = 0.8, radius = 0.25, oxy = 0.8 })
		if math.random() < 0.5 then
			AddEmitter(b, { kind = "nose", bone = hb, outlet = "nose", rate = 0.25, reservoir = 8, start = now + U.RandRange(1, 3),
				stop = now + 60, surface = 0.9, radius = 0.12, oxy = 0.7 })
		end
	end
end

local function EmitterFrame(ent, e)
	if e.outlet then
		local side = e.side or 0
		if e.outlet == "ear" and side == 0 then side = (math.random() < 0.5) and -1 or 1 end
		if e.outlet == "nose" and side == 0 then side = (math.random() < 0.5) and -1 or 1 end
		if e.outlet == "mouth" and side == 0 then side = (math.random() - 0.5) * 1.2 end
		return Outlet(ent, e.outlet, side)
	end
	local bone, lp, ln = e.bone, e.lpos, e.lnrm
	if bone == nil or not lp or not U.BoneFrame then return U.BoneToWorld(ent, bone, lp, ln) end
	local F = U.BoneFrame(ent, bone)
	if not F then return nil end
	if e.lpv ~= lp then e.lpv, e.lpx, e.lpy, e.lpz = lp, lp.x, lp.y, lp.z end
	local x, y, z = e.lpx, e.lpy, e.lpz
	local pos = Vector(F[1] + F[4] * x + F[7] * y + F[10] * z, F[2] + F[5] * x + F[8] * y + F[11] * z, F[3] + F[6] * x + F[9] * y + F[12] * z)
	if not ln then return pos, nil end
	if e.lnv ~= ln then e.lnv, e.lnx, e.lny, e.lnz = ln, ln.x, ln.y, ln.z end
	x, y, z = e.lnx, e.lny, e.lnz
	return pos, Vector(F[4] * x + F[7] * y + F[10] * z, F[5] * x + F[8] * y + F[11] * z, F[6] * x + F[9] * y + F[12] * z)
end

-- (1.26.7) spurts after a gunshot, the way GHM's Universal Directional Blood does them: one to five short gushes from
-- the wound (more for heavier rounds), the first 0.1-0.4 s after the hit and then every 0.5-1.5 s, thrown along the
-- bullet's path (out of the exit wound; back towards the shooter from an entry wound) mixed with the way the wound faces
-- (60 : 40) and the way the body moves. They follow the wound's bone,
-- onto the ragdoll if the body dies. Each gush is a short stream (cl_streams.lua) breaking into drops.
local cvSpurts = CreateClientConVar("ghmpb_spurts", "1", true, false, "GHM PhysBlood: spurts from gunshot wounds after the hit (0 = off, 1 = normal, up to 3 = more)", 0, 3)
W.cvSpurts = cvSpurts

function W.AddSpurts(b, ent, bone, lp, ln, dir, dmg, oxy)
	local k = cvSpurts:GetFloat()
	if k <= 0 or not bone or not lp or not ln or not dir then return end
	-- (1.26.8) in a big fight or on a slow frame: no spurts on bodies far off or out of view, fewer on the others
	-- (players: "laggy since the update, fighting loads of NPCs")
	local detail, load = 1, 0
	if G.Gov and G.Gov.Detail then detail, load = G.Gov.Detail() end
	if load > 0.25 and IsValid(ent) then
		local d2 = ent:GetPos():DistToSqr(EyePos())
		if d2 > 1400 * 1400 or (U.InView and not U.InView(ent, 24)) then return end
	end
	k = k * math.Clamp(0.35 + 0.65 * detail / 0.6, 0.35, 1)
	local now = CurTime()
	local n = math.Clamp(math.floor(dmg / 15 * k + math.random() * 0.6), 1, math.floor(5 * math.max(k, 1)))
	for _, e in ipairs(b.emitters) do
		if e.kind == "spurt" then
			-- the newest wound spurts (the older spurts carry on from it)
			e.n = math.min((e.n or 0) + n, 10)
			e.bone, e.lpos, e.lnrm = bone, lp, ln
			e.lpv, e.lnv = nil, nil
			e.shot, e.dmg = Vector(dir), math.max(e.dmg or 0, dmg)
			e.stop = math.max(e.stop, now + 20)
			return e
		end
	end
	return AddEmitter(b, { kind = "spurt", bone = bone, lpos = lp, lnrm = ln, n = n, nextT = now + U.RandRange(0.1, 0.4),
		shot = Vector(dir), dmg = dmg, rate = 0, reservoir = 1e9, stop = now + 20, surface = 0, radius = 0.3, oxy = oxy or 0.9 })
end

local function Spurt(b, ent, e, now, dt, vel, cf)
	local P, Fo = G.Particles, G.Forensic
	if not e.burstEnd then
		if (e.n or 0) <= 0 then e.stop = 0 return end
		if now < e.nextT then return end
		e.n = e.n - 1
		e.nextT = now + U.RandRange(0.5, 1.5)
		local dur = U.RandRange(0.14, 0.26)
		e.burstEnd = now + dur
		local ml = U.RandRange(0.35, 0.8) * math.Clamp((e.dmg or 30) / 30, 0.7, 1.6) * math.min(cvSpurts:GetFloat(), 1.5)
		e.burstRate = math.min(ml, Left(b)) / dur
		e.burstSpeed = U.RandRange(150, 250)
		e.jit = VectorRand() * 0.22
		e.acc = 0
	end
	if now >= e.burstEnd then e.burstEnd = nil return end
	local pos, nrm = EmitterFrame(ent, e)
	if not pos then return end
	nrm = nrm or -e.shot
	local d = e.shot * 0.6 + nrm * 0.4 + e.jit
	d:Normalize()
	if vel:LengthSqr() > 100 then d = d + vel:GetNormalized() * 0.5 d:Normalize() end
	-- out of the wound, never back into the body
	local dn = d:Dot(nrm)
	if dn < 0.2 then d = d + nrm * (0.3 - dn) d:Normalize() end
	local ml = math.min(e.burstRate * dt * cf, Left(b))
	if ml <= 0 then return end
	b.lostML = (b.lostML or 0) + ml
	e.emitted = e.emitted + ml
	e.acc = e.acc + ml * 1000
	local speed = e.burstSpeed
	local out = pos + nrm * 0.3
	if G.Streams then
		local d0 = Vector(d)
		G.Streams.Feed(e, function()
			if not IsValid(ent) then return nil end
			local p, n = EmitterFrame(ent, e)
			if not p then return nil end
			return p + (n or d0) * 0.3, d0 * speed + ent:GetVelocity()
		end, b.btype, ent, 0.8, e.burstEnd - now)
	end
	local em = G.Gov and G.Gov.EmitMul(pos) or 1
	local vmin = math.max(Fo and Fo.Volume(Fo.Diameter("arterial")) or 25, 18) * em
	while e.acc > vmin do
		local v = math.min(e.acc, vmin * U.RandRange(0.7, 1.3))
		e.acc = e.acc - v
		local dd = U.ConeDir(d, 0.1)
		P.Spawn({ pos = out, vel = dd * speed * U.RandRange(0.82, 1.12) + vel, r = (v / 4.18879) ^ (1 / 3), owner = ent, oxy = e.oxy,
			btype = b.btype, stretch = U.RandRange(1.6, 2.8), spin = U.RandRange(-20, 20), ownerGrace = 0.15 })
	end
end

local floorEnt
local floorTrace = { mask = MASK_SOLID, filter = function(e) return not IsValid(e) or (e ~= floorEnt and not (e:IsNPC() or e:IsPlayer() or e:IsRagdoll())) end }

local CONTACT_R = 14
local function Contacts(b, ent)
	local now = CurTime()
	if b.contacts and now < (b.contactsT or 0) then return b.contacts end
	b.contactsT = now + 0.75
	local list = {}
	local sk = A.GetSkeleton(ent)
	if sk then
		local bones = {}
		for _, bb in ipairs({ sk.head or sk.headGuess or -1, sk.neck or -1, sk.chest or -1, sk.abdomen or -1, sk.pelvis or -1 }) do
			if bb >= 0 then bones[#bones + 1] = bb end
		end
		for _, r in ipairs({ A.UPPERARM, A.THIGH, A.FOREARM, A.CALF, A.HAND, A.FOOT }) do
			for _, bb in ipairs(sk.regions[r] or {}) do if #bones < 24 then bones[#bones + 1] = bb end end
		end
		for _, bone in ipairs(bones) do
			local m = ent:GetBoneMatrix(bone)
			if m then
				local p = m:GetTranslation()
				floorEnt = ent
				floorTrace.start = p + Vector(0, 0, 2)
				floorTrace.endpos = p - Vector(0, 0, 16)
				local tr = util.TraceLine(floorTrace)
				if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.5 and p.z - tr.HitPos.z < 12 then
					list[#list + 1] = { pos = tr.HitPos, n = tr.HitNormal, tr = tr }
				end
			end
		end
	end
	b.contacts = list
	return list
end

-- (1.26.9c) wound = true: a pool a wounded body bled into (the serum ring of its settled blood is drawn only there)
local SEEP_EXTRA = { _seep = true, wound = true }
-- (1.26.9d) some of it with air in it (flags 1: frothy): big bubbles ride on the fresh pool near the body and burst
local SEEP_FROTH = { _seep = true, wound = true, flags = 1 }
local function PoolFromFootprint(b, ent, wpos, vol, e, tr0, seep)
	local S = G.Surfaces
	seep = seep or 1
	local j = VectorRand()
	j.z = 0
	j:Mul(0.14 + 0.20 * seep)
	local r = math.Clamp(0.30 + 0.52 * seep, 0.30, 0.85)
	-- (1.26.9d) the blood runs out from under the body: its push points away from the body's middle (with some scatter), so
	-- the pool keeps spreading outwards in lobes while the body bleeds instead of growing as an even disc round the wound
	local rdir
	local out = wpos - ent:WorldSpaceCenter()
	out.z = 0
	if out:LengthSqr() > 4 then
		out:Normalize()
		rdir = VectorRand() * 0.6
		rdir:Add(out)
	else
		rdir = VectorRand()
	end
	rdir.z = 0
	if rdir:LengthSqr() < 1e-4 then rdir = Vector(1, 0, 0) end
	rdir:Normalize()
	local frothP = 0.35 + 0.35 * math.Clamp(((e.oxy or 0.7) - 0.6) / 0.35, 0, 1)
	S.Impact(tr0.HitPos + j, tr0.HitNormal, rdir * (14 + 30 * seep), r, vol, 1, 0, 1.05, 0.02, tr0, e.oxy, b.btype,
		math.random() < frothP and SEEP_FROTH or SEEP_EXTRA)
	-- (1.26.9d) the blood welling in stirs the pool's surface round the spot (S.WellWave), every 0.3-0.5 s per body
	local now = CurTime()
	if S.WellWave and now >= (e.wellT or 0) and tr0.HitNormal.z > 0.85 then
		e.wellT = now + 0.3 + 0.2 * math.random()
		S.WellWave(tr0.HitPos + j, 0.008 + 0.012 * seep)
	end
end

local function Tick(b, dt)
	local ent = b.ent
	local now = CurTime()
	local E = G.Entities
	local P = G.Particles
	local S = G.Surfaces
	local grav = Vector(0, 0, -1)
	local vel = ent:GetVelocity()
	local d = E.Get(ent, false)
	local oxySum, oxyW = 0, 0
	local left = Left(b)
	local cf = W.CorpseFactor(b)
	if left <= 0 or cf <= 0 then
		for i = #b.emitters, 1, -1 do b.emitters[i] = nil end
	end
	for i = #b.emitters, 1, -1 do
		local e = b.emitters[i]
		if now > e.stop or e.emitted >= e.reservoir then
			table.remove(b.emitters, i)
		elseif e.kind == "spurt" then
			if now >= e.start and cf > 0 then Spurt(b, ent, e, now, dt, vel, cf) end
		elseif now >= e.start then
			local rate = e.rate
			local Fo = G.Forensic
			if e.kind == "artery" and Fo and not e.geyser then
				e.phase = ((e.phase or 0) + dt * (e.hz or 1.4)) % 1
				local jet, flowRel, hz = Fo.Arterial(b.lostML or 0, e.phase, e.art or 1)
				e.hz = hz
				local alive = b.dead and math.max(0, 1 - (now - b.deathTime) / 8) or 1
				rate = rate * ((0.15 + 0.85 * flowRel) * alive + 0.04)
				e.jetNow = jet * (0.3 + 0.7 * alive)
			elseif e.kind == "artery" then
				local beat = math.max(0, math.sin((now - e.start) * e.pulseHz * math.pi * 2)) ^ 2
				local alive
				if e.geyser then alive = math.max(0, 1 - (now - e.start) / math.max(e.stop - e.start, 1)) ^ 0.6
				else alive = b.dead and math.max(0, 1 - (now - b.deathTime) / 8) or 1 end
				rate = rate * (0.15 + 0.85 * beat * alive)
				e.jetNow = e.jet * (0.35 + 0.65 * beat) * (0.3 + 0.7 * alive)
			elseif e.fatal then
				local t = now - e.start
				local ramp = math.Clamp(t / 2.8, 0.08, 1.0)
				ramp = ramp * ramp * (3 - 2 * ramp)
				rate = rate * (1.75 * ramp) * math.exp(-math.max(t - 1.5, 0) / 55)
			end
			local ml = math.min(rate * cf * dt, e.reservoir - e.emitted, left)
			left = left - ml
			e.emitted = e.emitted + ml
			b.lostML = (b.lostML or 0) + ml
			local mm3 = ml * 1000
			local pos, nrm = EmitterFrame(ent, e)
			if pos and mm3 > 0 then
				oxySum = oxySum + e.oxy * mm3 oxyW = oxyW + mm3
				local floorFrac = 0
				local tr = e.ftr
				if not tr or now >= e.ftrT or pos:DistToSqr(e.ftrP) > 4 then
					floorTrace.start = pos + Vector(0, 0, 1)
					floorTrace.endpos = pos - Vector(0, 0, 32)
					floorEnt = ent
					tr = util.TraceLine(floorTrace)
					e.ftr, e.ftrT, e.ftrP = tr, now + 0.4, pos
				end
				if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.5 then
					local gap = pos.z - tr.HitPos.z
					local lying = b.dead or ent:IsRagdoll()
					local dragSp = lying and gap < 6 and math.sqrt(vel:Length2DSqr()) or 0
					if dragSp > 25 then
						-- (1.26.9d) a body dragged along the floor with the wound on the ground: the blood is wiped out along the
						-- way it is dragged - a long, streaky smear behind it (not a row of round pools)
						floorFrac = 0.8
						e.dragAcc = (e.dragAcc or 0) + mm3 * floorFrac
						if now >= (e.dragT or 0) and e.dragAcc > 15 then
							local seg = Vector(-vel.x, -vel.y, 0) * math.Clamp(now - (e.dragLT or (now - 0.1)), 0.05, 0.3)
							e.dragT, e.dragLT = now + 0.08, now
							S.Impact(tr.HitPos, tr.HitNormal, seg, math.Clamp(0.9 + 2.2 * (e.radius or 0.4), 1.0, 2.0), e.dragAcc, 3, 0, 1, 0.3, tr, e.oxy, b.btype)
							e.dragAcc = 0
						end
						e.poolStart = nil
					elseif gap < 4 then
						floorFrac = 0.72
					elseif lying and gap < 16 and vel:LengthSqr() < 55 * 55 then
						floorFrac = (nrm.z < -0.3) and 0.85 or ((nrm.z < 0.45) and 0.6 or 0.35)
						if e.fatal then floorFrac = math.max(floorFrac, 0.75) end
					end
					if floorFrac > 0 and dragSp <= 25 then
						if not e.poolStart then
							e.poolStart = now
							e.poolT = now + U.RandRange(0.18, 0.32)
						end
						local seep = math.Clamp((now - e.poolStart) / 3.2, 0.08, 1.0)
						seep = seep * seep * (3 - 2 * seep)
						floorFrac = floorFrac * seep
						e.poolAcc = (e.poolAcc or 0) + mm3 * floorFrac
						if now >= (e.poolT or 0) or e.poolAcc > 240 then
							e.poolT = now + 0.10 * (G.Gov and G.Gov.WoundTickMul(ent) or 1)
							if lying then
								PoolFromFootprint(b, ent, pos, e.poolAcc, e, tr, seep)
							else
								local r = math.Clamp(e.radius * (0.65 + 0.65 * seep), 0.24, 0.78)
								S.Impact(tr.HitPos, tr.HitNormal, vector_origin, r, e.poolAcc, 1, 0, 1, 0.02, tr, e.oxy, b.btype, SEEP_EXTRA)
							end
							e.poolAcc = 0
						end
					end
				end
				local rest = mm3 * (1 - floorFrac)
				local surfaceVol = rest * e.surface
				local free = rest - surfaceVol
				if d then
					e.surfAcc = (e.surfAcc or 0) + surfaceVol
					if now >= (e.surfT or 0) or e.surfAcc > 400 then
						e.surfT = now + 0.2 * (G.Gov and G.Gov.WoundTickMul(ent) or 1)
						E.Impact(ent, pos, nrm, vector_origin, e.radius, e.surfAcc, 1, 0, 1, 0, e.bone, { oxy = e.oxy, btype = b.btype })
						e.surfAcc = 0
					end
				else free = rest end
				if G.Trails and free > 0 and nrm then free = free - G.Trails.Take(b, ent, e, pos, nrm, vel, free, dt) end
				if e.kind == "artery" then
					e.acc = e.acc + free
					local jet = e.jetNow or e.jet
					local em = G.Gov and G.Gov.EmitMul(pos) or 1
					local vmin, vmax = (e.geyser and 60 or 18) * em, (e.geyser and 140 or 45) * em
					-- (1.26.7) the jet as one continuous stream from the wound (cl_streams.lua)
					if G.Streams and (e.jetNow or e.jet or 0) > 80 and free > 0 then
						local up = Vector(0, 0, 0.25 + (e.up or 0))
						G.Streams.Feed(e, function()
							if not IsValid(ent) then return nil end
							local p, n = EmitterFrame(ent, e)
							if not p or not n then return nil end
							return p + n * 0.3, (n + up):GetNormalized() * (e.jetNow or e.jet or 0) + ent:GetVelocity()
						end, b.btype, ent, e.geyser and 1.25 or 1, 0.16)
					end
					if G.VAT and e.acc > vmin and (e.jetNow or e.jet or 0) > 80 then
						G.VAT.OnJet(e, pos + nrm * 0.3, (nrm + Vector(0, 0, 0.25 + (e.up or 0))):GetNormalized(), jet, b.btype, ent, e.bone)
					end
					if Fo and Fo.ArterialGush and e.acc > vmin and (e.jetNow or e.jet or 0) > 95 and (e.gushT or 0) < now then
						e.gushT = now + 0.22
						Fo.ArterialGush(ent, pos + nrm * 0.3, (nrm + Vector(0, 0, 0.25 + (e.up or 0))):GetNormalized(), jet, b.btype, 1.0, e.art or 1)
					end
					while e.acc > vmin do
						local v = (Fo and not e.geyser) and Fo.Volume(Fo.Diameter("arterial")) * em or U.RandRange(vmin, vmax)
						v = math.min(e.acc, v)
						e.acc = e.acc - v
						local dir = U.ConeDir((nrm + Vector(0, 0, 0.25 + (e.up or 0))):GetNormalized(), e.geyser and 0.2 or 0.12)
						P.Spawn({ pos = pos + nrm * 0.3, vel = dir * jet * U.RandRange(0.8, 1.1) + vel, r = (v / 4.18879) ^ (1 / 3),
							owner = ent, oxy = 1, btype = b.btype, stretch = U.RandRange(1.8, 3.2), spin = U.RandRange(-20, 20), ownerGrace = 0.15 })
						if Fo and math.random() < 0.3 / em then
							local rd = U.ConeDir(dir, 0.3)
							P.Spawn({ pos = pos + nrm * 0.4, vel = rd * jet * U.RandRange(0.6, 1.0) + vel, r = Fo.Diameter("arterialRain") * 0.5,
								owner = ent, oxy = 1, btype = b.btype, stretch = 1.4, spin = 0, ownerGrace = 0.15 })
						end
					end
				else
					e.acc = e.acc + free
					-- (1.26.7) a wound losing blood fast with nothing under it pours: a thin continuous stream to the drips
					if G.Streams and nrm and e.kind == "fatal" and dt > 0 and free / dt > 260 then
						G.Streams.Feed(e, function()
							if not IsValid(ent) then return nil end
							local p, n = EmitterFrame(ent, e)
							if not p or not n then return nil end
							return p + n * 0.2, ent:GetVelocity() + n * 14
						end, b.btype, ent, math.Clamp(free / dt / 900, 0.4, 0.75), 0.16)
					end
					if e.acc > 35 then
						local sp = (e.spit or 0) > 0 and math.random() < e.spit
						if sp then
							P.Spray({ pos = pos + nrm * 0.3, dir = nrm, cone = 0.4, count = 6, speedMin = 50, speedMax = 160, r0 = 0.45,
								spread = 0.5, owner = ent, oxy = e.oxy, btype = b.btype, ownerGrace = 0.15, base = vel })
						else
							P.Hang(pos + nrm * 0.2, vel + nrm * 3, e.acc, ent, e.oxy, b.btype)
						end
						e.acc = 0
					end
				end
			end
		end
	end
	if b.coughUntil and now < b.coughUntil and not b.dead and G.cv.cough:GetBool() and now > (b.coughStart or 0) and now > b.lastCough then
		b.lastCough = now + U.RandRange(2.0, 6.0)
		local sk = A.GetSkeleton(ent)
		local pos, nrm = Outlet(ent, "mouth", 0)
		if pos then
			local cs = b.coughS or 1
			if G.Forensic then
				G.Forensic.Expirated(ent, pos, nrm, cs, b.btype, vel)
			else
				P.Spray({ pos = pos + nrm * 0.4, dir = nrm, cone = 0.45, count = math.floor(10 + 16 * cs), speedMin = 90, speedMax = 320,
					r0 = 0.38, spread = 0.7, owner = ent, oxy = 0.95, btype = b.btype, mist = 0.8, ownerGrace = 0.2, base = vel })
			end
			if d then E.Impact(ent, pos, nrm, vector_origin, 0.3, 60 * cs, 1, 0, 1, 0, nil, { oxy = 0.95, btype = b.btype }) end
		end
	end
	if d and oxyW > 0 then d.oxy = d.oxy * 0.85 + (oxySum / oxyW) * 0.15 end
	if d and b.btype and (d.btype ~= b.btype or not d.typeSet) then
		d.btype, d.typeSet = b.btype, true
		if d.btypeB == d.btype then d.btypeB = nil end
	end
end

function W.Stump(ent, bone, wpos, wnrm, region, S, limb)
	if not IsValid(ent) or not G.cv.enable:GetBool() or not bone then return end
	local btype = G.BloodTypeOf(ent)
	if btype == nil then return end
	local b = W.Body(ent)
	b.btype = btype
	if W.CorpseFactor(b) <= 0 or Left(b) < 1 then return end
	if ent:IsRagdoll() and not b.dead and not G.LivingRagdoll(ent) then b.dead = true b.deathTime = b.corpseT0 or CurTime() end
	local lp, ln = U.BoneToLocal(ent, bone, wpos, wnrm)
	if not lp then return end
	local now = CurTime()
	local cv = G.cv
	local rox = RegOxy(region, ent)
	local art = cv.sArtery:GetFloat()
	S = S * cv.bleed:GetFloat()
	if limb then
		AddEmitter(b, { kind = "weep", bone = bone, lpos = lp, lnrm = ln, rate = 1.6 * S, reservoir = 30 * S, stop = now + 25,
			surface = 0.55, radius = 0.6, oxy = rox * 0.8, fatal = true })
	else
		AddEmitter(b, { kind = "weep", bone = bone, lpos = lp, lnrm = ln, rate = 2.0 * S, reservoir = 60 * S, stop = now + 45,
			surface = 0.55, radius = 0.7, oxy = rox * 0.9, fatal = true })
		local strong = region == A.NECK or region == A.HEAD or region == A.UPPERARM or region == A.THIGH
		local weak = region == A.FOREARM or region == A.CALF
		if (strong or weak) and cv.arterial:GetBool() and art > 0 then
			AddEmitter(b, { kind = "artery", name = "stump", bone = bone, lpos = lp, lnrm = ln, rate = (strong and 5.0 or 2.2) * S * art,
				reservoir = (strong and 140 or 50) * S * art, stop = now + 35, surface = 0.15, radius = 0.5, pulseHz = 1.3, art = art,
				jet = U.RandRange(120, 240) * math.min(math.sqrt(art), 1.4) * (strong and 1 or 0.7), oxy = 1.0 })
		end
	end
	Spray({ pos = wpos + wnrm * 0.5, dir = wnrm, cone = 0.7, count = math.floor((limb and 8 or 14) + 16 * S), speedMin = 50,
		speedMax = limb and 160 or 260, r0 = 0.9, spread = 0.8, owner = ent, oxy = rox, btype = btype, stretch = 1.6, spin = 20,
		ownerGrace = 0.25 }, 1)
	G.Entities.Impact(ent, wpos, wnrm, vector_origin, 1.3, (limb and 350 or 600) * S, 2, 0, 1, 0.8, bone, { oxy = rox, btype = btype })
	b.lostML = (b.lostML or 0) + 4 * S
end

function W.MoveEmitters(from, to, bones)
	local b = W.bodies[from]
	if not b or not IsValid(to) then return end
	local set = {}
	for _, bn in ipairs(bones) do set[bn] = true end
	local nb
	for i = #b.emitters, 1, -1 do
		local e = b.emitters[i]
		if e.bone and set[e.bone] and not e.outlet then
			nb = nb or W.Body(to)
			table.remove(b.emitters, i)
			if e.kind == "artery" then e.kind = "weep" e.rate = e.rate * 0.4 e.reservoir = e.reservoir * 0.3 e.surface = 0.6 end
			table.insert(nb.emitters, e)
		end
	end
	if nb then nb.btype = b.btype nb.deathTime = nb.deathTime or CurTime() nb.dead = true end
end

function W.Update()
	local now = CurTime()
	for ent, b in pairs(W.bodies) do
		if IsValid(ent) and not ent:IsRagdoll() and G.Render and G.Render.Redirect then
			local rag = G.Render.Redirect(ent, b.entIndex)
			if IsValid(rag) and rag ~= ent then
				G.Render.Transfer(ent, rag, G.LivingRagdoll(rag), b.entIndex)
				ent = rag
				b = W.bodies[rag] or b
			end
		end
		if not IsValid(ent) then
			b.orphan = b.orphan or now
			if now - b.orphan > 2 then W.bodies[ent] = nil end
		elseif #b.emitters == 0 and not (b.coughUntil and now < b.coughUntil) then
			b.lastTick = now
		elseif now >= b.nextTick then
			local iv = 0.1 * (G.Gov and G.Gov.WoundTickMul(ent) or 1)
			local dt = math.min(now - (b.lastTick or now), math.max(0.3, iv * 1.5))
			if dt > 0 then Tick(b, dt) end
			b.lastTick = now
			b.nextTick = now + iv
		end
	end
end

function W.OnTransfer(from, to, living)
	local b = W.bodies[from]
	if not b then return end
	W.bodies[from] = nil
	local old = W.bodies[to]
	if old and old ~= b then
		for _, w in ipairs(old.wounds) do b.wounds[#b.wounds + 1] = w end
		for _, e in ipairs(old.emitters) do b.emitters[#b.emitters + 1] = e end
		while #b.wounds > 12 do table.remove(b.wounds, 1) end
		while #b.emitters > 24 do table.remove(b.emitters, 1) end
		b.lostML = (b.lostML or 0) + (old.lostML or 0)
	end
	b.ent = to
	b.entIndex = to:EntIndex()
	b.orphan = nil
	if living then
		b.corpseT0 = nil
	else
		b.dead = true
		b.deathTime = b.deathTime or CurTime()
	end
	W.bodies[to] = b
end

function W.IsBleeding(ent)
	local b = W.bodies[ent]
	if not b then return false end
	local now = CurTime()
	for _, e in ipairs(b.emitters) do
		if now <= e.stop and e.emitted < e.reservoir then return true end
	end
	return b.coughUntil ~= nil and now < b.coughUntil and not b.dead
end

function W.OnDomainRemoved(ent) end
function W.OnForeignBlood(ent, p, tr) end

function W.Clear() W.bodies = {} end

-- (1.26.8) GHM: "when giving a headshot there is a water ripple particle effect, big one and small, please remove
-- that". While a head hit is worked out the fluid bursts are muted (G.VAT.mute, set above where the region is known:
-- cl_vat.lua V.Spawn throws no entry, exit or spray burst then), and the setting is put back after the hit, also when it
-- fails half way. Wraps the functions this file has just defined (a reload of the file wraps its new ones)
for _, name in ipairs({ "OnHit", "ShotWorld", "SpatterOnly" }) do
	local inner = W[name]
	W[name] = function(...)
		local V = G.VAT
		local prev = V and V.mute or false
		local ok, a, b, c = pcall(inner, ...)
		if V then V.mute = prev end
		if not ok then error(a, 0) end
		return a, b, c
	end
end

W.STYLES = {
	{ id = "minimal", name = "Minimal", tip = "Little spray, small wounds and pools",
	  cv = { ghmpb_splat_entry = 0.3, ghmpb_splat_exit = 0.3, ghmpb_splat_melee = 0.3, ghmpb_splat_kill = 0, ghmpb_splat_radial = 0.3, ghmpb_splat_blast = 0.35, ghmpb_splat_wound = 0.6,
	         ghmpb_splat_size = 0.8, ghmpb_splat_speed = 0.8, ghmpb_splat_spread = 0.9, ghmpb_arterial_strength = 0.5,
	         ghmpb_geyser = 0, ghmpb_pool_size = 0.6 } },
	{ id = "realistic", name = "Realistic", tip = "Forensic reference amounts: fine back-spatter, a cone of spray from exit wounds, realistic pools",
	  cv = { ghmpb_splat_entry = 1, ghmpb_splat_exit = 1, ghmpb_splat_melee = 1, ghmpb_splat_kill = 0, ghmpb_splat_radial = 1, ghmpb_splat_blast = 1, ghmpb_splat_wound = 1,
	         ghmpb_splat_size = 1, ghmpb_splat_speed = 1, ghmpb_splat_spread = 1, ghmpb_arterial_strength = 1,
	         ghmpb_geyser = 0, ghmpb_pool_size = 1 } },
	{ id = "cinematic", name = "Cinematic", tip = "Action-film hits: bigger exit sprays, a burst on the killing shot, wide glossy pools",
	  cv = { ghmpb_splat_entry = 1.6, ghmpb_splat_exit = 2.2, ghmpb_splat_melee = 2, ghmpb_splat_kill = 1, ghmpb_splat_radial = 1.6, ghmpb_splat_blast = 1.6, ghmpb_splat_wound = 1.4,
	         ghmpb_splat_size = 1.2, ghmpb_splat_speed = 1.3, ghmpb_splat_spread = 1.15, ghmpb_arterial_strength = 1.6,
	         ghmpb_geyser = 0, ghmpb_pool_size = 1.8 } },
	{ id = "samurai", name = "Samurai", tip = "Chanbara: long arcs of blood flung along every blade swing, fountains from fatal cuts",
	  cv = { ghmpb_splat_entry = 2.2, ghmpb_splat_exit = 3, ghmpb_splat_melee = 4.5, ghmpb_splat_kill = 3, ghmpb_splat_radial = 1.6, ghmpb_splat_blast = 1.6, ghmpb_splat_wound = 2,
	         ghmpb_splat_size = 1.5, ghmpb_splat_speed = 1.8, ghmpb_splat_spread = 1.3, ghmpb_arterial_strength = 4,
	         ghmpb_geyser = 1, ghmpb_pool_size = 2.5 } },
	{ id = "horror", name = "Horror", tip = "Heavy, wet gore: big drops everywhere, soaked wounds, huge pools",
	  cv = { ghmpb_splat_entry = 3, ghmpb_splat_exit = 4, ghmpb_splat_melee = 3, ghmpb_splat_kill = 2.5, ghmpb_splat_radial = 2.5, ghmpb_splat_blast = 2.5, ghmpb_splat_wound = 3,
	         ghmpb_splat_size = 1.9, ghmpb_splat_speed = 1.3, ghmpb_splat_spread = 1.8, ghmpb_arterial_strength = 3,
	         ghmpb_geyser = 0, ghmpb_pool_size = 3.5 } },
}
W.STYLE_CVARS = {}
for k in pairs(W.STYLES[2].cv) do W.STYLE_CVARS[#W.STYLE_CVARS + 1] = k end

function W.StyleById(id)
	for _, st in ipairs(W.STYLES) do if st.id == id then return st end end
end

-- (1.26.6) the preset whose values all match the current settings, if any
function W.StyleNow()
	for _, st in ipairs(W.STYLES) do
		local same = true
		for k, v in pairs(st.cv) do
			local c = GetConVar(k)
			if not c or math.abs(c:GetFloat() - v) > 0.005 then same = false break end
		end
		if same then return st end
	end
end

function W.ApplyStyle(id)
	local st = W.StyleById(string.lower(id or ""))
	if not st then return false end
	W.applying = true
	for k, v in pairs(st.cv) do
		local c = GetConVar(k)
		if c then c:SetFloat(v) end
		if RunConsoleCommand then RunConsoleCommand(k, tostring(v)) end
	end
	G.cv.style:SetString(st.id)
	if RunConsoleCommand then RunConsoleCommand("ghmpb_splatter_style", st.id) end
	W.applying = false
	return true
end

cvars.AddChangeCallback("ghmpb_splatter_style", function(_, _, new)
	if W.applying or new == "custom" then return end
	-- (1.26.6) config.cfg runs ghmpb_splatter_style after the individual settings: never let that overwrite a player's
	-- own values on start-up
	if CurTime() < 2 and not W.StyleNow() then
		W.applying = true
		G.cv.style:SetString("custom")
		if RunConsoleCommand then RunConsoleCommand("ghmpb_splatter_style", "custom") end
		W.applying = false
		return
	end
	if not W.ApplyStyle(new) then print("[GHMPB] unknown splatter style '" .. tostring(new) .. "' (minimal, realistic, cinematic, samurai, horror)") end
end, "ghmpb_style")
for _, name in ipairs(W.STYLE_CVARS) do
	cvars.AddChangeCallback(name, function()
		if W.applying then return end
		if G.cv.style:GetString() ~= "custom" then
			W.applying = true
			G.cv.style:SetString("custom")
			if RunConsoleCommand then RunConsoleCommand("ghmpb_splatter_style", "custom") end
			W.applying = false
		end
	end, "ghmpb_style")
end
