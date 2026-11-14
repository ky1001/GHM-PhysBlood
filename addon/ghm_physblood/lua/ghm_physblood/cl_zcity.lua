local G = GHMPB
local ZC = G.ZC
local U = G.U
local A = G.Anatomy
local P = G.Particles

ZC.cstats = ZC.cstats or { drips = 0, jets = 0, clouds = 0, squirts = 0, stumps = 0, moved = 0, bandaged = 0, skipped = 0 }
local st = ZC.cstats

local function On() return ZC.Active() and G.cv.enable:GetBool() end
local function Ent(x) return (isentity(x) and IsValid(x)) and x or nil end

local function Body(owner)
	owner = Ent(owner)
	if not owner then return nil end
	if owner:IsPlayer() then return ZC.Character(owner) end
	return owner
end

ZC.holder = ZC.holder or {}

function ZC.Sync(p, target)
	if not IsValid(p) or not p:IsPlayer() then return end
	local h = ZC.holder[p]
	if not h then h = { ent = p, living = true } ZC.holder[p] = h end
	local alive = p:Alive()
	if alive and h.alive == false then
		if h.ent == p then
			G.Entities.Remove(p)
			G.Wounds.bodies[p] = nil
		end
		h.ent, h.living, h.deathDone, h.deadSince = p, true, nil, nil
	end
	if not alive and h.alive ~= false then h.deadSince = CurTime() end
	h.alive = alive
	if not h.living then return end
	local to = Ent(target) or ZC.Character(p)
	if IsValid(to) and to ~= h.ent then
		local corpse = not alive and to == p:GetNWEntity("RagdollDeath")
		local living = not (corpse and h.deathDone)
		local from = h.ent
		if from ~= nil and (G.Entities.domains[from] or G.Wounds.bodies[from]) then
			G.Render.Transfer(from, to, living)
			st.moved = st.moved + 1
			G.DiagCount("zcity: blood moved with the player's body")
		end
		h.ent = to
	end
	if not alive and h.deathDone and IsValid(h.ent) and h.ent == p:GetNWEntity("RagdollDeath") then h.living = false end
end

function ZC.OnDeath(p, bloodless)
	if not ZC.Active() or not IsValid(p) or not p:IsPlayer() then return false end
	local h = ZC.holder[p]
	if not h then ZC.Sync(p) h = ZC.holder[p] end
	if h.deathDone then return true end
	h.deathDone = true
	local body = IsValid(h.ent) and h.ent or p
	local ok, err = pcall(G.Wounds.OnDeath, body, nil, bloodless)
	if not ok then ErrorNoHalt("[GHMPB] OnDeath: " .. tostring(err) .. "\n") end
	ZC.Sync(p)
	return true
end

function ZC.HitTarget(ent)
	if not IsValid(ent) or not ZC.Active() then return ent end
	local p = ent:IsPlayer() and ent or ZC.LivingOwner(ent)
	if not p then return ent end
	ZC.Sync(p)
	local c = ZC.Character(p)
	return IsValid(c) and c or ent
end

hook.Add("Fake", "ghmpb_zcity", function(ply, rag)
	if On() and IsValid(ply) and Ent(rag) then ZC.Sync(ply, rag) end
end)

hook.Add("EntityRemoved", "ghmpb_zcity", function(ent, fullUpdate)
	if fullUpdate or not ZC.Active() then return end
	for p, h in pairs(ZC.holder) do
		if h.ent == ent and h.living then
			if IsValid(p) then
				local to = p:Alive() and p or ZC.Character(p)
				if IsValid(to) and to ~= ent then
					G.Render.Transfer(ent, to, p:Alive())
					h.ent, h.living = to, p:Alive()
				end
			else
				ZC.holder[p] = nil
			end
		end
	end
end)

local tokDrop, tokFount, tokWater = {}, {}, {}
setmetatable(tokDrop, { __mode = "k" }) setmetatable(tokFount, { __mode = "k" }) setmetatable(tokWater, { __mode = "k" })
local function Budget(tbl, key, rate, burst)
	local now = CurTime()
	local b = tbl[key]
	if not b then b = { n = burst, t = now, carry = 0 } tbl[key] = b end
	b.n = math.min(burst, b.n + (now - b.t) * rate)
	b.t = now
	if b.n < 1 then return false, b end
	b.n = b.n - 1
	return true, b
end

local function rOf(v) return (v / 4.18879) ^ (1 / 3) end
local FAR = 4000 * 4000

local film = setmetatable({}, { __mode = "k" })
local function Film(body, pos, vol, oxy)
	local f = film[body]
	if not f then f = { v = 0, t = 0 } film[body] = f end
	f.v, f.pos, f.oxy = f.v + vol, pos, oxy
	local now = CurTime()
	if now < f.t then return end
	f.t = now + 0.25
	local bone = U.NearestBone(body, f.pos)
	local m = bone and body:GetBoneMatrix(bone)
	local dir = (m and m:GetTranslation() or body:WorldSpaceCenter()) - f.pos
	if dir:LengthSqr() < 0.01 then dir = Vector(0, 0, -1) end
	dir:Normalize()
	local surf, nrm = U.EntitySurface(body, f.pos, dir)
	if surf and nrm then G.Entities.Impact(body, surf, nrm, vector_origin, 0.3, f.v, 1, 0, 1, 0, bone, { oxy = f.oxy }) end
	f.v = 0
end

local OUR = {}
ZC.our = OUR

-- (1.26.7) Z-City's impact and gib messages carry only a position: the blood type is the nearest body's (an antlion
-- bleeds yellow, a zombie its own colour), red when no body is near
local function TypeNear(pos, r)
	local best, bd = nil, (r or 48) ^ 2
	for _, e in ipairs(ents.FindInSphere(pos, r or 48)) do
		if IsValid(e) and (e:IsPlayer() or e:IsNPC() or e:IsRagdoll()) then
			local d = e:WorldSpaceCenter():DistToSqr(pos)
			if d < bd then best, bd = e, d end
		end
	end
	if not best then return G.BLOOD_RED end
	return G.BloodTypeOf(Body(best) or best)
end
ZC.TypeNear = TypeNear

function OUR.addBloodPart(pos, vel, mat, w, h, artery, kishki, owner)
	if not On() or not isvector(pos) or pos:DistToSqr(EyePos()) > FAR then return end
	local body = Body(owner)
	if body and body:IsDormant() then return end
	local btype = G.BLOOD_RED
	if body then btype = G.BloodTypeOf(body) if btype == nil then return end end
	vel = isvector(vel) and vel or vector_origin
	local size = math.Clamp(math.max(tonumber(w) or 1, tonumber(h) or 1), 0.5, 2)
	local ok, bk = Budget(tokDrop, body or "world", artery and 45 or 25, artery and 12 or 8)
	local v = (artery and 30 or 26) * size
	if not ok then bk.carry = math.min(bk.carry + v, 400) return end
	v, bk.carry = v + bk.carry, 0
	local bvel = body and body:GetVelocity() or vector_origin
	if kishki then
		P.Spawn({ pos = pos, vel = vel + bvel, r = U.RandRange(1.2, 2.4), owner = body, oxy = 0.6, btype = btype, stretch = 1.3,
			spin = U.RandRange(-60, 60), ownerGrace = 0.25 })
	elseif body and not artery and vel:LengthSqr() < 1600 then
		P.Hang(pos, bvel, v, body, 0.55, btype)
		Film(body, pos, v * 1.5, 0.55)
		st.drips = st.drips + 1
	else
		P.Spawn({ pos = pos, vel = vel + bvel, r = rOf(v), owner = body, oxy = artery and 1 or 0.7, btype = btype,
			stretch = artery and U.RandRange(1.6, 2.6) or 1.4, spin = U.RandRange(-20, 20), ownerGrace = 0.15 })
		if body and artery then
			Film(body, pos, v * 0.5, 1)
			if G.VAT and G.VAT.OnJet and vel:LengthSqr() > 2500 then
				G.VAT.OnJet(bk, pos, vel:GetNormalized(), vel:Length(), btype, body)
			end
		end
		st.jets = st.jets + 1
	end
end

function OUR.addBloodPart2(pos, vel, mat, w, h, time, water, owner, owner2)
	if not On() or not isvector(pos) or pos:DistToSqr(EyePos()) > FAR then return end
	local body = Body(Ent(owner) or Ent(owner2))
	if body and body:IsDormant() then return end
	local btype = G.BLOOD_RED
	if body then btype = G.BloodTypeOf(body) if btype == nil then return end end
	vel = isvector(vel) and vel or vector_origin
	if bit.band(util.PointContents(pos), P.WATERMASK) ~= 0 then
		if G.Water and Budget(tokWater, body or "world", 4, 3) then
			G.Water.Enter(pos, vel * 0.2, 45, btype, 0.6)
			st.clouds = st.clouds + 1
		end
	elseif G.cv.mist:GetBool() and Budget(tokWater, "mist", 8, 4) then
		P.Mist(pos, vel:LengthSqr() > 1 and vel:GetNormalized() or Vector(0, 0, 1), 0.35, btype)
	end
end

function OUR.applyFountain(pos, ang, mul, mul2, forward, ent)
	if not On() or not isvector(pos) or pos:DistToSqr(EyePos()) > FAR then return end
	local body = Body(ent)
	local b = body and G.Wounds.bodies[body]
	if b and b.zcStumpUntil and CurTime() < b.zcStumpUntil then return end
	local btype = G.BLOOD_RED
	if body then btype = G.BloodTypeOf(body) if btype == nil then return end end
	local ok, bk = Budget(tokFount, body or "world", 22, 6)
	if not ok then return end
	local dir = isangle(ang) and ang:Forward() or Vector(0, 0, 1)
	local speed = math.Clamp((tonumber(forward) or 150) * 0.6, 50, 260)
	P.Spawn({ pos = pos, vel = U.ConeDir(dir, 0.15) * speed * U.RandRange(0.8, 1.1) + (body and body:GetVelocity() or vector_origin),
		r = rOf(U.RandRange(20, 45)), owner = body, oxy = 1, btype = btype, stretch = U.RandRange(1.8, 3), spin = U.RandRange(-20, 20),
		ownerGrace = 0.2 })
	if body and G.VAT and G.VAT.OnJet then
		G.VAT.OnJet(bk, pos, dir, speed, btype, body)
	end
	st.jets = st.jets + 1
end

function OUR.explode(pos, size, force)
	if not On() or not isvector(pos) then return end
	local bt = TypeNear(pos, 60)
	if bt == nil then return end
	size = tonumber(size) or 1
	P.Spray({ pos = pos, dir = Vector(0, 0, 1), cone = 1.5, count = math.floor(26 * size + 8), speedMin = 60, speedMax = 240 * math.sqrt(size),
		r0 = 0.9, spread = 0.8, oxy = 0.7, btype = bt, mist = 0.8 * size, base = isvector(force) and force * 0.2 or nil })
end

local function BoneSpot(body, boneName, m, pos, dir)
	local bone = isstring(boneName) and body:LookupBone(boneName)
	if not bone or not m or not isvector(pos) or not isvector(dir) then return nil end
	local lp, la = WorldToLocal(pos, dir:Angle(), m:GetTranslation(), m:GetAngles())
	return bone, lp, la:Forward(), dir:Length()
end

function ZC.Squirt(ent, boneName, m, pos, dir, mouth)
	local body = Body(ent)
	if not body or body:IsDormant() then return end
	local btype = G.BloodTypeOf(body)
	if btype == nil then return end
	local bone, lp, ln, len = BoneSpot(body, boneName, m, pos, dir)
	if not bone then return end
	local W = G.Wounds
	local b = W.Body(body)
	b.btype = btype
	local now = CurTime()
	if mouth then
		W.AddEmitter(b, { kind = "mouth", bone = bone, lpos = lp, lnrm = ln, rate = 9, reservoir = 7, start = now, stop = now + 0.7,
			surface = 0.25, radius = 0.25, oxy = 0.7, spit = 1 })
		local p = ent:IsPlayer() and ent or ZC.LivingOwner(body)
		if p == LocalPlayer() and isfunction(ViewPunch) then
			pcall(ViewPunch, Angle(15, 0, 0))
			timer.Simple(0.25, function() if isfunction(ViewPunch) then pcall(ViewPunch, Angle(15, 0, 0)) end end)
		end
	else
		W.AddEmitter(b, { kind = "artery", geyser = true, bone = bone, lpos = lp, lnrm = ln, rate = 7, reservoir = 16, start = now,
			stop = now + 2.6, surface = 0.1, radius = 0.3, pulseHz = 2.0, jet = math.Clamp((len or 2) * 90, 80, 260), up = 0, oxy = 1 })
	end
	st.squirts = st.squirts + 1
end

local function Stump(body, boneName, fallback, region, S, ahead)
	if not body or body:IsDormant() then return nil end
	local bone = body:LookupBone(boneName) or fallback
	if not bone then return nil end
	local m = body:GetBoneMatrix(bone)
	if not m then body:SetupBones() m = body:GetBoneMatrix(bone) end
	if not m then return nil end
	local fwd = m:GetAngles():Forward()
	local pos = m:GetTranslation() + fwd * ahead
	G.Wounds.Stump(body, bone, pos, fwd, region, S)
	st.stumps = st.stumps + 1
	return pos, fwd
end

function ZC.Decapitated(ent, force)
	local body = Body(ent)
	local sk = body and A.GetSkeleton(body)
	local pos, fwd = Stump(body, "ValveBiped.Bip01_Neck1", sk and sk.neck, A.NECK, 1.6, 4)
	if not pos then return end
	local b = G.Wounds.bodies[body]
	if b then b.zcStumpUntil = CurTime() + 30 end
	P.Spray({ pos = pos, dir = fwd, cone = 0.9, count = 30, speedMin = 80, speedMax = 300, r0 = 0.9, spread = 0.8, owner = body, oxy = 0.9,
		btype = G.BloodTypeOf(body) or G.BLOOD_RED, mist = 1.2, ownerGrace = 0.25, base = isvector(force) and force * 0.05 or nil })
end

local LIMBS = {
	lleg = { "ValveBiped.Bip01_L_Calf", A.CALF }, rleg = { "ValveBiped.Bip01_R_Calf", A.CALF },
	larm = { "ValveBiped.Bip01_L_Forearm", A.FOREARM }, rarm = { "ValveBiped.Bip01_R_Forearm", A.FOREARM },
}
local ampSeen = setmetatable({}, { __mode = "k" })
local function CheckAmputations(body, org)
	if not IsValid(body) or not istable(org) then return end
	local seen = ampSeen[body]
	if not seen then seen = {} ampSeen[body] = seen end
	for key, L in pairs(LIMBS) do
		if org[key .. "amputated"] and not seen[key] then
			seen[key] = true
			Stump(body, L[1], nil, L[2], 1.2, 8)
		end
	end
end
hook.Add("HG_OrganismChanged", "ghmpb_zcity", function(oldorg, org)
	if not On() or not istable(org) then return end
	local body = Body(org.owner)
	if not body then return end
	CheckAmputations(body, org)
end)

-- (1.26.8) PhysBlood on this client alone (the server does not run it, G.LocalMode): Z-City's own hit message makes the
-- hit - the wound on the body, the back spatter, and through the body the exit spray and the blood on the wall behind,
-- like a hit from PhysBlood's server part. Z-City sends two or three messages for one bullet (the entry at once with a
-- tenth of the damage and a short direction, the entry again a moment later with the full damage): the first makes the
-- hit, the others are left out. The weapon (for the bullet's class) is the shooter's whose aim passes the hit.
local recent = {}
local function Shooter(pos, dir, victim)
	local best, bd = nil, 40 * 40
	for _, p in ipairs(player.GetAll()) do
		if IsValid(p) and p ~= victim and p:Alive() then
			local eye = p:EyePos()
			local v = eye - pos
			local along = -v:Dot(dir)
			if along > 8 and along < 12000 then
				local d2 = (pos - dir * along - eye):LengthSqr()
				if d2 < bd then best, bd = p, d2 end
			end
		end
	end
	return best
end
ZC.Shooter = Shooter
local function BodyNear(pos, r)
	local best, bd = nil, (r or 48) ^ 2
	for _, e in ipairs(ents.FindInSphere(pos, r or 48)) do
		if IsValid(e) and (e:IsPlayer() or e:IsNPC() or e:IsRagdoll()) and not e:GetNoDraw() then
			local d = e:WorldSpaceCenter():DistToSqr(pos)
			if d < bd then best, bd = e, d end
		end
	end
	return best and (Body(best) or best) or nil
end
ZC.BodyNear = BodyNear
ZC.lstats = ZC.lstats or { hits = 0, merged = 0, world = 0 }
function ZC.LocalHit(pos, vel, mul, amt)
	if not isvector(pos) or not isvector(vel) or vel:LengthSqr() < 1e-8 then return false end
	if not (G.Wounds and G.Wounds.OnHit) then return false end
	local now = CurTime()
	for i = #recent, 1, -1 do if now - recent[i].t > 0.25 then table.remove(recent, i) end end
	for _, h in ipairs(recent) do
		if h.pos:DistToSqr(pos) < 14 * 14 then ZC.lstats.merged = ZC.lstats.merged + 1 return true end
	end
	recent[#recent + 1] = { pos = Vector(pos), t = now }
	if pos:DistToSqr(EyePos()) > FAR then return true end
	local dir = vel:GetNormalized()
	local dmg = tonumber(mul) or 10
	if vel:Length() < 0.12 then dmg = dmg * 10 end
	dmg = math.Clamp(dmg, 8, 400)
	local body = BodyNear(pos, 48)
	local attacker = Shooter(pos, dir, body and (body:IsPlayer() and body or ZC.LivingOwner(body)) or nil)
	if body and not body:IsDormant() then
		local ok, err = pcall(G.Wounds.OnHit, body, pos, dir, dmg, DMG_BULLET, 0, false, attacker)
		if not ok then ErrorNoHalt("[GHMPB] Z-City hit: " .. tostring(err) .. "\n") end
		ZC.lstats.hits = ZC.lstats.hits + 1
	elseif G.Wounds.ShotWorld then
		G.Wounds.ShotWorld(pos, dir, dmg, DMG_BULLET, 0, attacker, G.BLOOD_RED)
		ZC.lstats.world = ZC.lstats.world + 1
	end
	return true
end

OUR.net = {
	hg_bloodimpact = function()
		local pos = net.ReadVector()
		local vel = net.ReadVector()
		local mul = net.ReadFloat()
		local amt = net.ReadInt(8)
		if not On() or not isvector(pos) then st.skipped = st.skipped + 1 return end
		if ZC.lastHitT and CurTime() - ZC.lastHitT < 0.15 and ZC.lastHitPos and ZC.lastHitPos:DistToSqr(pos) < 80 * 80 then
			st.skipped = st.skipped + 1
			return
		end
		if type(G.LocalMode) == "function" and G.LocalMode() and ZC.LocalHit(pos, vel, mul, amt) then return end
		local dir = (isvector(vel) and vel:LengthSqr() > 0.001) and -vel:GetNormalized() or Vector(0, 0, 1)
		local sz = math.Clamp((tonumber(mul) or 1) * 0.25, 0.4, 2.0)
		local cnt = math.Clamp(math.floor((tonumber(amt) or 1) * 5 * sz), 4, 24)
		local bt = TypeNear(pos, 40)
		if bt == nil then st.skipped = st.skipped + 1 return end
		P.Spray({ pos = pos, dir = dir, cone = 0.65, count = cnt, speedMin = 80, speedMax = 260 * sz,
			r0 = 0.65, spread = 0.6, oxy = 0.75, btype = bt, mist = 0.4 * sz })
		st.jets = st.jets + 1
	end,
	addfountain = function()
		local ent = net.ReadEntity()
		local force = net.ReadVector()
		if On() and IsValid(ent) then ZC.Decapitated(ent, force) end
	end,
	bloodsquirt = function()
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end
		local bn, m, pos, dir = net.ReadString(), net.ReadMatrix(), net.ReadVector(), net.ReadVector()
		if On() then ZC.Squirt(ent, bn, m, pos, dir, false) end
	end,
	bloodsquirt2 = function()
		local ent = net.ReadEntity()
		if not IsValid(ent) then return end
		local bn, m, pos, dir = net.ReadString(), net.ReadMatrix(), net.ReadVector(), net.ReadVector()
		if On() then ZC.Squirt(ent, bn, m, pos, dir, true) end
	end,
	bloody_decal_1 = function()
		local wep = net.ReadEntity()
		if not On() then return end
		if IsValid(wep) and G.Blades and G.Blades.Load then
			local owner = wep:GetOwner()
			if IsValid(owner) then
				G.Blades.Load(owner, 1.2, G.BLOOD_RED, wep.DamageType or DMG_SLASH, 1, 0.8)
			end
		end
		st.skipped = st.skipped + 1
	end,
}

local FUNCS = { "addBloodPart", "addBloodPart2", "applyFountain", "explode" }
local noop = function() end
local saved = { fn = {}, net = {}, hook = {}, bp = {} }
ZC.saved = saved
ZC.installed = false

local function Install()
	local hg = rawget(_G, "hg")
	if not istable(hg) then return end
	for _, k in ipairs(FUNCS) do
		if hg[k] ~= OUR[k] then
			if hg[k] ~= nil then saved.fn[k] = hg[k] end
			hg[k] = OUR[k]
		end
	end
	local bph = rawget(_G, "bloodparticles_hook")
	if istable(bph) then
		for i = 1, 4 do
			if bph[i] ~= noop then
				if bph[i] ~= nil then saved.bp[i] = bph[i] end
				bph[i] = noop
			end
		end
	end
	for name, f in pairs(OUR.net) do
		local cur = net.Receivers[name]
		if cur ~= f then
			if cur then saved.net[name] = cur end
			net.Receivers[name] = f
		end
	end
	local t = hook.GetTable().PostDrawTranslucentRenderables
	if t and t.bloodpartciels then
		saved.hook.bloodpartciels = t.bloodpartciels
		hook.Remove("PostDrawTranslucentRenderables", "bloodpartciels")
	end
	if istable(hg.bloodparticles1) and #hg.bloodparticles1 > 0 then table.Empty(hg.bloodparticles1) end
	if istable(hg.bloodparticles2) and #hg.bloodparticles2 > 0 then table.Empty(hg.bloodparticles2) end
	if not ZC.installed then
		ZC.installed = true
		MsgC(Color(120, 200, 255), "[GHM PhysBlood] ", color_white, "Z-City found: PhysBlood draws the blood, Z-City's blood effects are off (ghmpb_sv_zcity)"
			.. ((type(G.LocalMode) == "function" and G.LocalMode()) and " - the server does not run PhysBlood: in your game only, from Z-City's own hit messages\n" or "\n"))
	end
end

local function Restore()
	if not ZC.installed then return end
	ZC.installed = false
	local hg = rawget(_G, "hg")
	if istable(hg) then
		for _, k in ipairs(FUNCS) do
			if hg[k] == OUR[k] then hg[k] = saved.fn[k] end
		end
	end
	local bph = rawget(_G, "bloodparticles_hook")
	if istable(bph) then
		for i = 1, 4 do
			if bph[i] == noop and saved.bp[i] then bph[i] = saved.bp[i] end
		end
	end
	for name, f in pairs(saved.net) do
		if net.Receivers[name] == OUR.net[name] then net.Receivers[name] = f end
	end
	if saved.hook.bloodpartciels then
		hook.Add("PostDrawTranslucentRenderables", "bloodpartciels", saved.hook.bloodpartciels)
		saved.hook.bloodpartciels = nil
	end
end

local function Bandages(p)
	local w, a = p.wounds, p.arterialwounds
	if not istable(w) and not istable(a) then return end
	local noW, noA = not istable(w) or #w == 0, not istable(a) or #a == 0
	if not noW and not noA then return end
	local body = ZC.Character(p)
	local b = body and G.Wounds.bodies[body]
	if not b or b.dead or #b.emitters == 0 then return end
	local last = 0
	for _, wd in ipairs(b.wounds) do if (wd.time or 0) > last then last = wd.time end end
	if CurTime() - last < 2 then return end
	for i = #b.emitters, 1, -1 do
		local e = b.emitters[i]
		if (noW and (e.kind == "weep" or e.kind == "spurt") and not e.fatal) or (noA and e.kind == "artery" and not e.geyser and e.name ~= "stump") then
			table.remove(b.emitters, i)
			st.bandaged = st.bandaged + 1
		end
	end
end

local function Check()
	if On() then Install() else Restore() return end
	for _, p in ipairs(player.GetAll()) do
		ZC.Sync(p)
		local body = ZC.Character(p)
		local org = (IsValid(body) and (body.new_organism or body.organism)) or p.new_organism or p.organism
		if org then CheckAmputations(body, org) end
		if p:Alive() then
			Bandages(p)
		else
			local h = ZC.holder[p]
			if h and not h.deathDone and h.deadSince and CurTime() - h.deadSince > 2 and G.cv_sv_players:GetBool()
				and (G.Wounds.bodies[h.ent] or G.Entities.domains[h.ent]) then
				ZC.OnDeath(p, false)
			end
		end
	end
	for p in pairs(ZC.holder) do if not IsValid(p) then ZC.holder[p] = nil end end
end
hook.Add("Player-Ragdoll think", "ghmpb_zcity", function(ply, ent)
	if not On() then return end
	if IsValid(ply) and ply:IsPlayer() then ZC.Sync(ply, ent) end
	local body = Ent(ent) or Body(ply)
	local org = (body and (body.new_organism or body.organism)) or (IsValid(ply) and (ply.new_organism or ply.organism))
	if body and org then CheckAmputations(body, org) end
end)
timer.Create("ghmpb_zcity", 0.25, 0, function()
	local ok, err = pcall(Check)
	if not ok then G.DiagCount("error: zcity") G.Diag.lastError = tostring(err) end
end)
hook.Add("HomigradRun", "ghmpb_zcity", function() timer.Simple(0, function() pcall(Check) end) end)
hook.Add("InitPostEntity", "ghmpb_zcity", function() timer.Simple(1, function() pcall(Check) end) end)
