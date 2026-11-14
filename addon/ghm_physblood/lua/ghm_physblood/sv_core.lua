local G = GHMPB

util.AddNetworkString("ghmpb_hit")
util.AddNetworkString("ghmpb_death")
util.AddNetworkString("ghmpb_rag")
util.AddNetworkString("ghmpb_shot")

local function Bleeds(ent)
	if not IsValid(ent) then return false end
	if ent:IsPlayer() and not G.cv_sv_players:GetBool() then return false end
	if not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_ragdoll") then return false end
	return G.BloodTypeOf(ent) ~= nil
end
G.Bleeds = Bleeds

local function Suppressing(ent)
	if not (G.cv_sv_enable:GetBool() and G.cv_sv_suppress:GetBool()) then return false end
	if ent:IsPlayer() and not G.cv_sv_players:GetBool() then return false end
	return true
end
local function Silence(ent, eng, sup)
	if sup then
		if eng ~= DONT_BLEED then ent:SetBloodColor(DONT_BLEED) end
		ent.ghmpbSuppressed = true
	elseif ent.ghmpbSuppressed then
		if ent.ghmpbOrigBlood ~= nil then ent:SetBloodColor(ent.ghmpbOrigBlood) end
		ent.ghmpbSuppressed = nil
	end
end
local function Setup(ent)
	if not IsValid(ent) then return end
	if not (ent:IsNPC() or ent:IsNextBot() or ent:IsPlayer()) then return end
	if not ent.GetBloodColor or not ent.SetBloodColor then return end
	local eng = ent:GetBloodColor()
	if eng == nil then return end
	ent.ghmpbSetup = true
	local real = eng
	if real == DONT_BLEED and isnumber(ent.bloodColorHitFix) and ent.bloodColorHitFix ~= DONT_BLEED then real = ent.bloodColorHitFix end
	if not (ent.ghmpbSuppressed and eng == DONT_BLEED) or real ~= eng then ent.ghmpbOrigBlood = real end
	local code, own = G.Compat.BloodCode(ent)
	local c = code
	if c == nil then c = ent.ghmpbOrigBlood or eng end
	local clsBt = G.ClassBloodType and G.ClassBloodType[ent:GetClass()]
	local mdlBt = G.ModelBloodType and G.ModelBloodType(ent:GetModel())
	if clsBt then
		c = -10 - clsBt
	elseif mdlBt and mdlBt ~= G.BLOOD_RED then
		c = -10 - mdlBt
	elseif c == BLOOD_COLOR_MECH then
		c = -10 - (G.BLOOD_ROBOT or 5)
	end
	ent:SetNW2Int("ghmpb_blood", c)
	local sup = Suppressing(ent) and c ~= DONT_BLEED and c ~= BLOOD_COLOR_MECH
	Silence(ent, eng, sup)
	G.Compat.SuppressOwn(ent, sup and own)
end
G.Setup = Setup

hook.Add("OnEntityCreated", "ghmpb_setup", function(ent)
	timer.Simple(0.1, function() Setup(ent) end)
	timer.Simple(0.7, function() Setup(ent) end)
	timer.Simple(2.0, function() Setup(ent) end)
end)
hook.Add("PlayerSpawn", "ghmpb_setup", function(ply)
	ply.ghmpbSetup = nil
	timer.Simple(0.1, function() Setup(ply) end)
end)

local function Reapply()
	for _, e in ipairs(ents.GetAll()) do
		if e.ghmpbSetup then Setup(e) end
	end
end
cvars.AddChangeCallback("ghmpb_sv_suppress_default", Reapply, "ghmpb")
cvars.AddChangeCallback("ghmpb_sv_enable", Reapply, "ghmpb")
cvars.AddChangeCallback("ghmpb_sv_players", Reapply, "ghmpb")

local function Recipients(pos, ent, pos2)
	local rf = RecipientFilter()
	rf:AddPVS(pos)
	if IsValid(ent) then
		local c = ent:WorldSpaceCenter()
		if c:DistToSqr(pos) > 64 * 64 then rf:AddPVS(c) end
	end
	if pos2 then rf:AddPVS(pos2) end
	return rf
end
G.Recipients = Recipients
local function ViewPos(pl)
	local ve = pl:GetViewEntity()
	if IsValid(ve) and ve ~= pl then return ve:GetPos() end
	return pl:EyePos()
end
local function Near(rf, pos)
	local r2 = G.LIVE_RANGE * G.LIVE_RANGE
	for _, pl in ipairs(rf:GetPlayers()) do
		if ViewPos(pl):DistToSqr(pos) > r2 then rf:RemovePlayer(pl) end
	end
	return rf
end
local function Send(msg, ent, pos, live)
	pos = pos or ent:WorldSpaceCenter()
	local rf
	if game.SinglePlayer() then
		rf = RecipientFilter()
		rf:AddAllPlayers()
	else
		rf = Recipients(pos, ent)
	end
	if live then Near(rf, pos) end
	if #rf:GetPlayers() > 0 then net.Send(rf) else G.DiagCount("sv: blood event kept for later (no player near it)") end
	return rf
end
G.NetSend = Send

local rateT, rateAll, ratePhys = 0, 0, 0
G.HitStats = G.HitStats or { sent = 0, physSent = 0, physBlocked = 0, rateBlocked = 0 }
local function Allow(ent, dmg, amount, fatal)
	local now = CurTime()
	if now >= rateT then rateT, rateAll, ratePhys = now + 1, 0, 0 end
	local phys = G.IsPhysicsDamage(dmg:GetDamageType())
	if not phys then
		local inf = dmg:GetInflictor()
		phys = IsValid(inf) and inf ~= ent and not inf:IsPlayer() and not inf:IsNPC() and not inf:IsWeapon()
			and (string.find(inf:GetClass(), "^prop_") ~= nil) and bit.band(dmg:GetDamageType(), bit.bor(DMG_BULLET, DMG_SLASH, DMG_BUCKSHOT, DMG_BLAST)) == 0
	end
	local hs = G.HitStats
	if phys and not fatal then
		local corpse = ent:GetClass() == "prop_ragdoll"
		if amount < G.cv_sv_physmin:GetFloat() * (corpse and 2 or 1) or (ent.ghmpbPhysNext or 0) > now
			or ratePhys >= G.cv_sv_physrate:GetInt() then
			hs.physBlocked = hs.physBlocked + 1
			return false
		end
		ent.ghmpbPhysNext = now + G.cv_sv_physcd:GetFloat() * (corpse and 1.5 or 1)
		ratePhys = ratePhys + 1
		hs.physSent = hs.physSent + 1
	end
	if not fatal and rateAll >= G.cv_sv_hitrate:GetInt() then hs.rateBlocked = hs.rateBlocked + 1 return false end
	rateAll = rateAll + 1
	hs.sent = hs.sent + 1
	return true
end

local function HitPosition(ent, dmg)
	local c = ent:WorldSpaceCenter()
	local r = math.max(ent:BoundingRadius(), 16) * 1.5
	local function ok(p)
		return p and not p:IsZero() and p:DistToSqr(ent:GetPos()) > 0.25 and p:DistToSqr(c) > 0.25 and p:DistToSqr(c) < r * r
	end
	local pos = dmg:GetDamagePosition()
	if ok(pos) then return pos end
	local shot = ent.ghmpbLastShot
	if shot and (CurTime() - shot.t) < 0.05 and ok(shot.pos) then return shot.pos end
	local rp = dmg:GetReportedPosition()
	if ok(rp) then return rp end
	if shot and (CurTime() - shot.t) < 0.05 and ok(shot.rpos) then return shot.rpos end
	local att = dmg:GetAttacker()
	if IsValid(att) and att.GetShootPos then
		local src = att:GetShootPos()
		if att.GetAimVector then
			local aim = att:GetAimVector()
			local t1 = util.TraceLine({ start = src, endpos = src + aim * ((c - src):Length() + 128),
				filter = function(e) return e == ent end, ignoreworld = true, mask = MASK_SHOT })
			if t1.Hit and ok(t1.HitPos) then return t1.HitPos end
		end
		local tr = att.GetEyeTrace and att:IsPlayer() and att:GetEyeTrace()
		if tr and tr.Entity == ent and ok(tr.HitPos) then return tr.HitPos end
		local t2 = util.TraceLine({ start = src, endpos = src + (c - src):GetNormalized() * ((c - src):Length() + 64),
			filter = function(e) return e == ent end, ignoreworld = true, mask = MASK_SHOT })
		if t2.Hit and not t2.HitPos:IsZero() and t2.HitPos:DistToSqr(c) < r * r then return t2.HitPos end
	end
	if ent.ghmpbLastHitPos and (CurTime() - (ent.ghmpbLastHitT or 0)) < 2 and ok(ent.ghmpbLastHitPos) then
		return ent.ghmpbLastHitPos
	end
	if pos and not pos:IsZero() and pos:DistToSqr(ent:GetPos()) > 0.25 and pos:DistToSqr(c) < r * r then return pos end
	return c
end

local function BlastOrigin(ent, dmg, center)
	local p = dmg:GetDamagePosition()
	if p:IsZero() then p = dmg:GetReportedPosition() end
	if p:IsZero() then
		local inf = dmg:GetInflictor()
		if IsValid(inf) and inf ~= ent and not inf:IsPlayer() and not inf:IsNPC() then p = inf:WorldSpaceCenter() end
	end
	if p:IsZero() then
		local f = dmg:GetDamageForce()
		p = center - (f:LengthSqr() > 1 and f:GetNormalized() or Vector(0, 0, -1)) * 64
	end
	if p:DistToSqr(center) < 16 then
		local f = dmg:GetDamageForce()
		p = center - (f:LengthSqr() > 1 and f:GetNormalized() or Vector(0, 0, -1)) * 32
	end
	return p
end

local function KillBloodless(ent, dmg)
	if G.IsDotTick(dmg) then return ent.ghmpbLastBloodless == true end
	return G.IsBloodlessDamage(dmg:GetDamageType())
end

local function ApplyBlastPhysics(ent, origin, amount)
	if not IsValid(ent) or not origin then return end
	local c = ent:WorldSpaceCenter()
	local dvec = c - origin
	local dist = math.max(dvec:Length(), 16)
	local bdir = (dvec / dist + Vector(0, 0, 0.32)):GetNormalized()
	local fmag = math.Clamp(amount * 15 * (145 / math.max(dist, 36)), 180, 1450)
	ent.ghmpbBlastOrigin = Vector(origin)
	ent.ghmpbBlastDir = Vector(bdir)
	ent.ghmpbBlastForce = fmag
	ent.ghmpbBlastT = CurTime()
	if ent:GetClass() == "prop_ragdoll" then
		local nb = ent:GetPhysicsObjectCount() or 0
		for b = 0, nb - 1 do
			local phys = ent:GetPhysicsObjectNum(b)
			if IsValid(phys) then
				local bp = phys:GetPos()
				local bd = (bp - origin)
				local bdist = math.max(bd:Length(), 14)
				bd = (bd / bdist + Vector(0, 0, 0.34) + VectorRand() * 0.14):GetNormalized()
				local k = math.Clamp(130 / bdist, 0.45, 1.5)
				phys:Wake()
				phys:ApplyForceCenter(bd * (fmag * k * math.max(phys:GetMass(), 4) * 1.15))
			end
		end
	elseif ent:IsPlayer() or ent:IsNPC() then
		pcall(function()
			ent:SetVelocity(bdir * math.Clamp(fmag * 0.42, 140, 520))
		end)
	end
end

local lastBlastSweep = 0
local function SweepBlastCorpses(origin, amount, attacker, ignoreEnt)
	local now = CurTime()
	if now - lastBlastSweep < 0.08 or not origin then return end
	lastBlastSweep = now
	for _, rag in ipairs(ents.FindInSphere(origin, 230)) do
		if IsValid(rag) and rag ~= ignoreEnt and rag:GetClass() == "prop_ragdoll" and Bleeds(rag) and (rag.ghmpbBlastCD or 0) < now then
			local c = rag:WorldSpaceCenter()
			local dist = c:Distance(origin)
			if dist < 230 then
				rag.ghmpbBlastCD = now + 0.35
				local effAmt = math.Clamp(amount * (1 - dist / 250), 18, 180)
				ApplyBlastPhysics(rag, origin, effAmt)
				local bdir = (c - origin):GetNormalized()
				net.Start("ghmpb_hit")
				net.WriteEntity(rag)
				net.WriteVector(c - bdir * 6)
				net.WriteNormal(bdir)
				net.WriteFloat(effAmt)
				net.WriteUInt(DMG_BLAST, 32)
				net.WriteUInt(0, 4)
				net.WriteBool(false)
				net.WriteEntity(IsValid(attacker) and attacker or Entity(0))
				net.WriteBool(true)
				net.WriteVector(origin)
				net.WriteUInt(rag:EntIndex(), 16)
				Send("ghmpb_hit", rag, c, true)
			end
		end
	end
end

local function SendHit(ent, dmg, amount, fatal)
	local dtype = dmg:GetDamageType()
	if G.IsBloodlessDamage(dtype) then G.DiagCount("sv: bloodless damage (fire, shock, gas...)") return end
	if G.IsDotTick(dmg) then G.DiagCount("sv: damage-over-time tick (no new wound)") return end
	if not Allow(ent, dmg, amount, fatal) then return end
	local blast = bit.band(dtype, bit.bor(DMG_BLAST, DMG_BLAST_SURFACE or 0)) ~= 0
	local center = ent:WorldSpaceCenter()
	local pos, dir, origin
	local shot = ent.ghmpbLastShot
	local freshShot = shot and (CurTime() - shot.t) < 0.05 and shot or nil
	if blast then
		origin = BlastOrigin(ent, dmg, center)
		dir = (center - origin):GetNormalized()
		local tr = util.TraceLine({ start = origin, endpos = center + dir * 8, filter = function(e) return e == ent end,
			ignoreworld = true, mask = MASK_SHOT })
		pos = (tr.Hit and tr.Entity == ent) and tr.HitPos or center - dir * 6
		ApplyBlastPhysics(ent, origin, amount)
		SweepBlastCorpses(origin, amount, dmg:GetAttacker(), ent)
	else
		pos = HitPosition(ent, dmg)
		dir = dmg:GetDamageForce()
		if dir:LengthSqr() < 1 and freshShot and freshShot.dir then dir = Vector(freshShot.dir) end
		if dir:LengthSqr() < 1 then
			local att = dmg:GetAttacker()
			dir = IsValid(att) and (pos - (att.GetShootPos and att:GetShootPos() or att:WorldSpaceCenter())) or Vector(0, 0, -1)
		end
		dir:Normalize()
	end
	ent.ghmpbLastHitPos = pos
	ent.ghmpbLastHitDir = dir
	ent.ghmpbLastHitT = CurTime()
	local hg = (ent.LastHitGroup and ent:LastHitGroup()) or 0
	if hg == 0 and freshShot and freshShot.hg then hg = freshShot.hg end
	net.Start("ghmpb_hit")
	net.WriteEntity(ent)
	net.WriteVector(pos)
	net.WriteNormal(dir)
	net.WriteFloat(math.min(amount, 5000))
	net.WriteUInt(dtype, 32)
	net.WriteUInt(math.Clamp(hg, 0, 15), 4)
	net.WriteBool(fatal)
	net.WriteEntity(dmg:GetAttacker())
	net.WriteBool(blast)
	if blast then net.WriteVector(origin) end
	net.WriteUInt(ent:EntIndex(), 16)
	local rf = Send("ghmpb_hit", ent, pos, true)
	G.DiagCount("sv: hit messages sent")
	if G.Hist then G.Hist.OnHit(ent, pos, dir, amount, dtype, blast, fatal, rf) end
end

local function Living(ent) return ent:IsNPC() or ent:IsPlayer() or (ent.IsNextBot and ent:IsNextBot()) end

local function Snap(dmg)
	local t = { type = dmg:GetDamageType(), pos = dmg:GetDamagePosition(), rpos = dmg:GetReportedPosition(),
		force = dmg:GetDamageForce(), att = dmg:GetAttacker(), inf = dmg:GetInflictor(), amount = dmg:GetDamage() }
	function t:GetDamageType() return self.type end
	function t:GetDamagePosition() return self.pos end
	function t:GetReportedPosition() return self.rpos end
	function t:GetDamageForce() return self.force end
	function t:GetAttacker() return self.att end
	function t:GetInflictor() return self.inf end
	function t:GetDamage() return self.amount end
	return t
end

local function RecordScaleHit(ent, hitgroup, dmg)
	if not IsValid(ent) then return end
	local p = dmg:GetDamagePosition()
	local rp = dmg:GetReportedPosition()
	local f = dmg:GetDamageForce()
	ent.ghmpbLastShot = {
		pos = not p:IsZero() and Vector(p) or nil,
		rpos = not rp:IsZero() and Vector(rp) or nil,
		dir = f:LengthSqr() > 1 and f:GetNormalized() or nil,
		hg = hitgroup,
		t = CurTime()
	}
end
hook.Add("ScaleNPCDamage", "ghmpb_shotpos", RecordScaleHit)
hook.Add("ScalePlayerDamage", "ghmpb_shotpos", RecordScaleHit)

G.HitHookFns = G.HitHookFns or {}
G.HitHookFns.EntityTakeDamage = function(ent, dmg)
	if not G.cv_sv_enable:GetBool() then return end
	if G.ZC and G.ZC.Active and G.ZC.Active() and IsValid(ent) and istable(ent.organism) and ent.organism.godmode then return end
	if G.Elem and G.Elem.OnDamage then
		local ok, err = pcall(G.Elem.OnDamage, ent, dmg)
		if not ok then G.DiagCount("sv: error in elements") G.Diag.lastError = tostring(err) end
	end
	if not Bleeds(ent) then
		if IsValid(ent) and (ent:IsNPC() or ent:IsNextBot() or ent:IsPlayer() or ent:GetClass() == "prop_ragdoll") then
			G.DiagCount("sv: damage on something that does not bleed (" .. ent:GetClass() .. ")")
		end
		return
	end
	G.DiagCount("sv: damage on something that bleeds")
	if not G.IsDotTick(dmg) then ent.ghmpbLastBloodless = G.IsBloodlessDamage(dmg:GetDamageType()) end
	if Living(ent) then
		if not ent.ghmpbSetup then Setup(ent) end
		ent.ghmpbPreHealth = ent:Health()
		ent.ghmpbPendingDmg = Snap(dmg)
		ent.ghmpbPendingT = CurTime()
		return
	end
	local amount = dmg:GetDamage()
	if amount <= 0.5 then return end
	SendHit(ent, dmg, amount, false)
end
hook.Add("EntityTakeDamage", "ghmpb_hit", G.HitHookFns.EntityTakeDamage)

local Death
G.HitHookFns.PostEntityTakeDamage = function(ent, dmg, took)
	local pre = ent.ghmpbPreHealth
	if pre == nil then return end
	local snap = ent.ghmpbPendingDmg
	ent.ghmpbPreHealth, ent.ghmpbPendingDmg = nil, nil
	if not IsValid(ent) or not G.cv_sv_enable:GetBool() then return end
	local post = ent:Health()
	local drop = pre - post
	local amount = math.max(dmg:GetDamage(), drop)
	local zc = G.ZC and G.ZC.TookHit and G.ZC.TookHit(ent)
	if zc == "redirected" then return end
	if zc then
		took = true
		amount = math.max(amount, snap and snap.amount or 0)
	end
	local bt = G.BloodTypeOf(ent)
	if (bt == G.BLOOD_ROBOT or bt == G.BLOOD_SYNTH) and amount > 0.5 then took = true end
	if not took and drop <= 0 then return end
	if amount <= 0.5 then return end
	local fatal = pre > 0 and post <= 0
	if fatal then ent.ghmpbKillBloodless = KillBloodless(ent, dmg) end
	local c = ent:WorldSpaceCenter()
	local dp = dmg:GetDamagePosition()
	local useDmg = (snap and (dp:IsZero() or dp:DistToSqr(c) < 0.5) and snap.pos and not snap.pos:IsZero() and snap.pos:DistToSqr(c) >= 0.5) and snap or dmg
	SendHit(ent, useDmg, amount, fatal)
	if fatal and not ent:IsPlayer() then Death(ent) end
end
hook.Add("PostEntityTakeDamage", "ghmpb_hit", G.HitHookFns.PostEntityTakeDamage)

Death = function(ent)
	if not IsValid(ent) or not Bleeds(ent) then return end
	local pdmg = ent.ghmpbPendingDmg
	if pdmg and ent.ghmpbPendingT == CurTime() then ent.ghmpbKillBloodless = KillBloodless(ent, pdmg) end
	if ent.ghmpbPreHealth ~= nil and pdmg and ent.ghmpbPendingT == CurTime() then
		local pre = ent.ghmpbPreHealth
		ent.ghmpbPreHealth, ent.ghmpbPendingDmg = nil, nil
		local ok, err = pcall(function()
			local amount = math.max(pdmg:GetDamage(), pre > 0 and pre or 0)
			if amount > 0.5 then SendHit(ent, pdmg, amount, pre > 0) end
		end)
		if not ok then ErrorNoHalt("[GHMPB] killing hit: " .. tostring(err) .. "\n") end
	end
	G.Compat.RememberDying(ent)
	if ent.ghmpbDeathSent and (CurTime() - ent.ghmpbDeathSent) < 5 then return end
	ent.ghmpbDeathSent = CurTime()
	net.Start("ghmpb_death")
	net.WriteEntity(ent)
	net.WriteBool(ent.ghmpbKillBloodless == true)
	net.WriteUInt(ent:EntIndex(), 16)
	local rf = Send("ghmpb_death", ent, nil, true)
	if G.Hist then G.Hist.OnDeath(ent, ent.ghmpbKillBloodless == true, rf) end
end
hook.Add("OnNPCKilled", "ghmpb_death", function(npc) Death(npc) end)
hook.Add("PlayerDeath", "ghmpb_death", function(ply) ply.ghmpbDeathSent = nil if G.cv_sv_players:GetBool() then Death(ply) end end)
hook.Add("EntityRemoved", "ghmpb_dying", function(ent)
	if ent.ghmpbSetup and not ent:IsPlayer() and (ent.ghmpbDeathSent or ent:Health() <= 0) then G.Compat.RememberDying(ent) end
end)

local function Handover(owner, rag, idx, bc)
	if not IsValid(rag) or rag.ghmpbHandled then return end
	rag.ghmpbHandled = true
	if IsValid(owner) then
		local obt = G.BloodTypeOf(owner)
		bc = owner:GetNW2Int("ghmpb_blood", -2)
		if obt == nil then
			bc = DONT_BLEED
		elseif obt ~= G.BLOOD_RED then
			bc = -10 - obt
		elseif bc == -2 and owner.GetBloodColor then
			bc = owner:GetBloodColor()
		end
		idx = owner:EntIndex()
		rag.ghmpbLastHitPos = owner.ghmpbLastHitPos
		rag.ghmpbLastHitDir = owner.ghmpbLastHitDir
		rag.ghmpbLastHitT = owner.ghmpbLastHitT
		rag.ghmpbBlastOrigin = owner.ghmpbBlastOrigin
		rag.ghmpbBlastDir = owner.ghmpbBlastDir
		rag.ghmpbBlastForce = owner.ghmpbBlastForce
		rag.ghmpbBlastT = owner.ghmpbBlastT
	end
	if bc == nil or bc == -2 then bc = BLOOD_COLOR_RED end
	rag:SetNW2Int("ghmpb_blood", bc)
	if G.Hist and IsValid(owner) then G.Hist.OnCorpse(owner, rag) end
	if not rag:GetNoDraw() then
		net.Start("ghmpb_rag")
		net.WriteEntity(IsValid(owner) and owner or NULL)
		net.WriteEntity(rag)
		net.WriteUInt(idx or 0, 16)
		net.WriteUInt(rag:EntIndex(), 16)
		Send("ghmpb_rag", rag)
	end
	timer.Simple(0, function()
		if not IsValid(rag) or rag:GetNoDraw() then return end
		if rag.ghmpbBlastT and (CurTime() - rag.ghmpbBlastT) < 0.45 and rag.ghmpbBlastOrigin then
			ApplyBlastPhysics(rag, rag.ghmpbBlastOrigin, (rag.ghmpbBlastForce or 450) / 10)
		end
		net.Start("ghmpb_rag")
		net.WriteEntity(IsValid(owner) and owner or NULL)
		net.WriteEntity(rag)
		net.WriteUInt(idx or 0, 16)
		net.WriteUInt(rag:EntIndex(), 16)
		Send("ghmpb_rag", rag)
	end)
end

hook.Add("CreateEntityRagdoll", "ghmpb_rag", function(owner, rag)
	if not IsValid(owner) or not IsValid(rag) then return end
	Handover(owner, rag)
end)

hook.Add("OnEntityCreated", "ghmpb_corpse", function(ent)
	if not IsValid(ent) or ent:GetClass() ~= "prop_ragdoll" then return end
	timer.Simple(0, function()
		if not IsValid(ent) or ent.ghmpbHandled then return end
		local r = G.Compat.MatchCorpse(ent)
		if r then Handover(IsValid(r.ent) and r.ent or nil, ent, r.idx, r.bc) end
	end)
end)

hook.Add("PostEntityFireBullets", "ghmpb_shot", function(ent, data)
	if not G.cv_sv_enable:GetBool() then return end
	local tr = data and data.Trace
	if not tr or not tr.StartPos or not tr.HitPos then return end
	if IsValid(tr.Entity) and Bleeds(tr.Entity) then
		tr.Entity.ghmpbLastShot = {
			pos = Vector(tr.HitPos),
			dir = (tr.HitPos - tr.StartPos):GetNormalized(),
			hg = tr.HitGroup or 0,
			t = CurTime()
		}
		return
	end
	net.Start("ghmpb_shot", true)
	net.WriteVector(tr.StartPos)
	net.WriteVector(tr.HitPos + (tr.HitPos - tr.StartPos):GetNormalized() * 4)
	net.WriteFloat(math.min((data.Damage and data.Damage > 0) and data.Damage or 12, 5000))
	net.WriteUInt(DMG_BULLET, 32)
	if game.SinglePlayer() then net.Broadcast() else net.Send(Recipients(tr.StartPos, nil, tr.HitPos)) end
end)

concommand.Add("ghmpb_diag_sv", function(ply)
	if IsValid(ply) and not ply:IsListenServerHost() and not ply:IsSuperAdmin() then return end
	local L = function(...) MsgC(Color(120, 200, 255), "[GHMPB diag sv] ") print(...) end
	L("enable", G.cv_sv_enable:GetInt(), "suppress engine blood", G.cv_sv_suppress:GetInt(), "players bleed", G.cv_sv_players:GetInt())
	local hs = G.HitStats
	L("hits sent", hs.sent, "physics sent", hs.physSent, "physics blocked", hs.physBlocked, "rate blocked", hs.rateBlocked)
	if G.Priority then L("damage hooks run first:", tostring(G.Priority.mode or "no"), "| Z-City", G.ZC.Present() and "loaded" or "not loaded",
		"takeover", G.ZC.Active() and "on" or "off", "| their decals dropped", G.ZC.stats.decals, "effects dropped", G.ZC.stats.effects) end
	if G.Hist and G.Hist.count then L("history (multiplayer): records", G.Hist.count, "bleeding bodies", table.Count(G.Hist.bleeders),
		"bodies with wounds", table.Count(G.Hist.bodies)) end
	local rows = {}
	for k, v in pairs(G.Diag.c) do if string.sub(k, 1, 3) == "sv:" then rows[#rows + 1] = { k, v } end end
	table.sort(rows, function(a, b) return a[1] < b[1] end)
	for _, r in ipairs(rows) do print(string.format("    %-62s %d", r[1], r[2])) end
	local n = 0
	for _, e in ipairs(ents.GetAll()) do
		if (e:IsNPC() or e:IsNextBot()) and n < 12 then
			n = n + 1
			L(string.format("  %s  model %s  engine blood %s  blood used %s  base %s  bleeds %s", e:GetClass(), tostring(e:GetModel()),
				tostring(e.GetBloodColor and e:GetBloodColor()), tostring(e:GetNW2Int("ghmpb_blood", -2)), tostring(G.Compat.BaseOf(e)), tostring(Bleeds(e))))
		end
	end
end)
