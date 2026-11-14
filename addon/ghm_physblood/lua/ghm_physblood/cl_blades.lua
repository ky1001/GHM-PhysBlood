-- =====================================================================================
-- GHM PhysBlood 1.26.0: blood on melee weapons.
-- A blade or club that hits a bleeding body carries blood away on it. The weapon's real motion is tracked (the
-- hand that holds it: the view model's hand in first person, the body's hand bone otherwise) and decides what that
-- blood does:
--   * fast motion (a swing, the back swing, a flick): drops leave the weapon tangentially along its path - the
--     cast-off line on walls and ceilings follows the actual arc of the swing, in its direction
--   * slow motion / held still: the blood gathers at the tip and drips off - a drip trail on the floor along the
--     way the attacker walks, with tails pointing the way the drops moved
-- Sharp weapons (knives, swords, axes, claws) hold a thin film and throw fine, linear cast-off; blunt ones (bats,
-- crowbars, pipes) hold more and throw fewer, bigger drops. The blood on the weapon clots and dries over a minute
-- or two, after which it stops coming off.
-- =====================================================================================
local G = GHMPB
G.Blades = G.Blades or {}
local B = G.Blades
local U = G.U

B.list = B.list or {}
B.dropped = B.dropped or {}
B.stats = B.stats or { loads = 0, cast = 0, drips = 0, wepStamps = 0, armSplats = 0 }

local SHARP_WORDS = { "knife", "sword", "katana", "machete", "axe", "blade", "dagger", "bayonet", "sabre", "saber", "cleaver",
	"scythe", "spear", "claw", "razor", "glaive", "halberd", "kukri", "karambit", "tanto", "wakizashi", "longsword", "rapier" }
local BLUNT_WORDS = { "crowbar", "bat", "pipe", "hammer", "stunstick", "shovel", "club", "mace", "wrench", "baton", "fists",
	"stick", "pan", "plank", "sledge", "tonfa", "nightstick", "golf", "brick" }

local HAND_BONES = { "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_R_Forearm", "R_Hand", "hand_R",
	"Bip01 R Hand", "ValveBiped.Bip01_L_Hand" }

local function Amount()
	local cv = G.cv.blades
	return cv and cv:GetFloat() or 1
end

local function HasWord(s, words)
	s = string.lower(s or "")
	for _, w in ipairs(words) do if string.find(s, w, 1, true) then return true end end
	return false
end

-- sharp (true) / blunt (false) from the damage type, refined by the weapon's class / hold type
function B.Kind(attacker, dmgtype)
	local sharp = bit.band(dmgtype or 0, DMG_SLASH) ~= 0
	local wep = IsValid(attacker) and attacker.GetActiveWeapon and attacker:GetActiveWeapon()
	if IsValid(wep) then
		local cls = wep:GetClass() .. " " .. (wep.PrintName or "")
		if HasWord(cls, SHARP_WORDS) then sharp = true elseif HasWord(cls, BLUNT_WORDS) then sharp = false end
	end
	return sharp
end

-- is the entity's current weapon a melee weapon (worth tracking before its first hit)
local MELEE_HOLD = { melee = true, melee2 = true, knife = true, fist = true }
function B.IsMelee(ent)
	local wep = IsValid(ent) and ent.GetActiveWeapon and ent:GetActiveWeapon()
	if not IsValid(wep) then return false end
	local ht = wep.GetHoldType and wep:GetHoldType() or ""
	if MELEE_HOLD[ht] then return true end
	local cls = wep:GetClass()
	return HasWord(cls, SHARP_WORDS) or HasWord(cls, BLUNT_WORDS)
end

local boneCache = setmetatable({}, { __mode = "k" })
local function HandBone(ent)
	local mdl = ent:GetModel() or ""
	local c = boneCache[ent]
	if c and c.mdl == mdl then return c.bone end
	local bone
	for _, name in ipairs(HAND_BONES) do
		local b = ent:LookupBone(name)
		if b then bone = b break end
	end
	boneCache[ent] = { mdl = mdl, bone = bone or false }
	return bone or false
end

-- world position of the weapon's working end. First person: the view model's hand (it sits in front of the eye in
-- world space, where the player sees the weapon); otherwise the body's right hand.
local function FirstPerson(ent)
	return ent == LocalPlayer() and not ent:ShouldDrawLocalPlayer()
end

function B.TipPos(ent, st)
	if not IsValid(ent) then return nil end
	local src = ent
	if FirstPerson(ent) then
		local vm = ent:GetViewModel()
		if IsValid(vm) then src = vm end
	end
	local bone = HandBone(src)
	local pos
	if bone then
		local m = src:GetBoneMatrix(bone)
		if m then pos = m:GetTranslation() end
	end
	if not pos then
		if src ~= ent then
			local eye, ang = ent:EyePos(), ent:EyeAngles()
			pos = eye + ang:Forward() * 18 + ang:Right() * 6 - ang:Up() * 8
		else
			pos = ent:WorldSpaceCenter() + ent:GetForward() * 14
		end
	end
	return pos, src ~= ent
end

local function State(ent)
	local st = B.list[ent]
	if not st then
		st = { load = 0, sharp = true, t = CurTime(), castAcc = 0, dripT = 0, vel = Vector(0, 0, 0), speed = 0 }
		B.list[ent] = st
	end
	return st
end

local ARM_CHAIN = {
	{ "ValveBiped.Bip01_R_Hand", 1.00, 0.42 },
	{ "ValveBiped.Bip01_R_Forearm", 0.62, 0.36 },
	{ "ValveBiped.Bip01_R_UpperArm", 0.28, 0.30 },
}

-- called on a melee hit on a bleeding body: blood goes onto the weapon, swinging arm & viewmodel
function B.Load(attacker, S, btype, dmgtype, siteML, oxy)
	if Amount() <= 0 or not IsValid(attacker) then return end
	local st = State(attacker)
	local sharp = B.Kind(attacker, dmgtype)
	st.sharp = sharp
	local kS = math.Clamp(S or 1, 0.3, 2.5)
	-- mm3: a blade picks up a thin film along its edge, a club a smear over its face (more when blood was already there)
	local base = sharp and U.RandRange(250, 700) or U.RandRange(350, 1000)
	local add = base * kS * (1 + math.min(siteML or 0, 3) * 0.6) * Amount()
	st.load = math.min(st.load + add, sharp and 2500 or 4000)
	st.btype, st.oxy = btype or st.btype or 0, oxy or 0.8
	st.t = CurTime()
	st.loadT = CurTime()
	B.stats.loads = B.stats.loads + 1

	local bt, ox = st.btype, st.oxy
	local tipPos = B.TipPos(attacker, st)

	-- 1. First-person C-hands & viewmodel weapon blood on melee strikes
	if FirstPerson(attacker) and G.Screen and G.Screen.HandsBlood and G.cv.vmblood and G.cv.vmblood:GetBool() and tipPos then
		G.Screen.HandsBlood(tipPos, bt, ox, math.Clamp(0.45 + 0.55 * kS, 0.35, 1.5))
	end

	-- 2. World weapon UV mesh blood + tracked load so dropped melee weapons retain & drip blood on the floor
	local E = G.Entities
	local wep = attacker.GetActiveWeapon and attacker:GetActiveWeapon()
	if IsValid(wep) then
		st.wep = wep
		wep.ghmpbBladeLoad = { load = st.load, btype = bt, oxy = ox, sharp = sharp, t0 = st.loadT }
		if E and E.Impact and not FirstPerson(attacker) then
			local wc = wep:WorldSpaceCenter()
			local wf = wep:GetForward()
			local pHit = wc + wf * (sharp and 7 or 5)
			if U and U.SnapToMesh then
				local okS, sp, sn, sb = pcall(U.SnapToMesh, wep, pHit, -wf, 0, true)
				if okS and sp then
					E.Impact(wep, sp, sn or wf, -wf * 140, sharp and 0.42 or 0.62, 16 * kS, 0, 0, sharp and 1.8 or 1.25, 0.22, sb, { btype = bt, oxy = ox })
					B.stats.wepStamps = B.stats.wepStamps + 1
				end
			else
				E.Impact(wep, pHit, wf, -wf * 140, sharp and 0.42 or 0.62, 16 * kS, 0, 0, sharp and 1.8 or 1.25, 0.22, 0, { btype = bt, oxy = ox })
				B.stats.wepStamps = B.stats.wepStamps + 1
			end
		end
	end

	-- 3. Third-person distal-to-proximal arm spatter (hand -> forearm -> upper arm)
	if E and E.Impact and not FirstPerson(attacker) then
		local fwd = attacker:GetForward()
		for i = 1, #ARM_CHAIN do
			local spec = ARM_CHAIN[i]
			local weight = spec[2]
			if i == 1 or math.random() < weight * math.min(kS, 1.4) then
				local b = attacker:LookupBone(spec[1])
				local bm = b and attacker:GetBoneMatrix(b)
				if bm then
					local bp = bm:GetTranslation()
					local nrm = (fwd * 0.65 + Vector(0, 0, 0.45) + VectorRand() * 0.25):GetNormalized()
					local hp, hn, hb = bp + nrm * 2.2, nrm, b
					if U and U.SnapToMesh then
						local okS, sp, sn, sb = pcall(U.SnapToMesh, attacker, hp, nrm, b, false)
						if okS and sp then hp, hn, hb = sp, sn or nrm, sb or b end
					end
					if E.Impact(attacker, hp, hn, -fwd * 160, spec[3] * (0.8 + 0.4 * math.random()), (10 + 18 * kS) * weight,
						0, 0, 1.15 + 0.5 * math.random(), 0.2, hb, { btype = bt, oxy = ox }) then
						B.stats.armSplats = B.stats.armSplats + 1
					end
				end
			end
		end
	end
end

-- direction the weapon is currently swinging (for the spray thrown off the wound), or nil when not known
function B.Sweep(attacker)
	local st = IsValid(attacker) and B.list[attacker]
	if st and st.speed > 120 and CurTime() - (st.velT or 0) < 0.25 then return st.vel / st.speed end
	return nil
end

local function Spawn(st, owner, pos, vel, dmm)
	G.Particles.Spawn({ pos = pos, vel = vel, r = dmm * 0.5, owner = owner, oxy = st.oxy or 0.8, btype = st.btype or 0,
		spin = U.RandRange(-30, 30), stretch = 1, ownerGrace = 0.35 })
end

local CAST_V0 = 170      -- u/s of the hand below which nothing is flung off
local DRIP_V = 70        -- u/s below which blood runs to the tip and drips
local LEVER = 1.45       -- tip speed / hand speed of a held weapon
local CLOT_TAU = 75      -- s: the blood on the weapon gels and stops coming off

local function Step(ent, st, now, dt)
	local Fo = G.Forensic
	local pos, fp = B.TipPos(ent, nil)
	if not pos then return false end
	-- smoothed velocity of the hand (first person: relative motion of the view model in the world, which includes the
	-- player's own motion and turning - a flick of the view flings blood off like a flick of the wrist)
	if st.last and dt > 0 then
		local v = (pos - st.last) / dt
		if v:LengthSqr() < 4000 * 4000 then
			local k = math.min(dt / 0.04, 1)
			st.vel = st.vel + (v - st.vel) * k
			st.speed = st.vel:Length()
			st.velT = now
		end
	end
	st.last = pos
	if st.load <= 1 then return true end
	-- clotting: the film on the weapon gels, less and less of it comes off
	local fluid = math.exp(-(now - (st.loadT or now)) / (CLOT_TAU * G.ClotScale()))
	if fluid < 0.05 then st.load = 0 return true end
	local owner = ent
	local sp = st.speed
	if sp > CAST_V0 then
		-- cast-off: the faster the swing the more is flung off (centripetal release grows with the square of the speed)
		local x = (sp - CAST_V0) / 450
		local rate = st.load * (st.sharp and 3.2 or 2.2) * x * x * fluid
		st.castAcc = st.castAcc + rate * dt
		local dir = st.vel / sp
		local dmmK = st.sharp and 0.6 or 1.0
		local guard = 0
		while guard < 6 do
			local dmm = Fo and Fo.Diameter("castoff", dmmK) or U.RandRange(1.2, 2.6) * dmmK
			local v = Fo and Fo.Volume(dmm) or 0.5236 * dmm * dmm * dmm
			if st.castAcc < v or st.load < v then break end
			guard = guard + 1
			st.castAcc = st.castAcc - v
			st.load = st.load - v
			-- drops leave along the tangent of the path, from points spread along the blade
			local along = U.RandRange(0, st.sharp and 9 or 7)
			local jit = VectorRand() * (st.sharp and 0.03 or 0.07)
			local vel = (dir + jit):GetNormalized() * sp * LEVER * U.RandRange(0.85, 1.1) + (ent:GetVelocity() * (fp and 0 or 0.5))
			Spawn(st, owner, pos + dir * along * 0.25, vel, dmm)
			B.stats.cast = B.stats.cast + 1
		end
		st.dripT = now + 0.25
	elseif sp < DRIP_V and now >= st.dripT and st.load > 12 then
		-- held / carried: blood runs down to the tip and falls off in drops (bigger, slower from a club)
		local dmm = Fo and Fo.Diameter("drip", st.sharp and 0.75 or 0.95) or 3.6
		local v = math.min(Fo and Fo.Volume(dmm) or 25, st.load)
		st.load = st.load - v
		local vel = st.vel * 0.9 + Vector(0, 0, -6)
		Spawn(st, owner, pos - Vector(0, 0, 1.5), vel, (v / 0.5236) ^ (1 / 3))
		B.stats.drips = B.stats.drips + 1
		-- a loaded weapon drips every fraction of a second, a nearly clean one every few seconds
		local wet = math.Clamp(st.load / (st.sharp and 600 or 900), 0.05, 1) * fluid
		st.dripT = now + U.RandRange(0.6, 1.4) / math.max(wet, 0.12)
	end
	return true
end

local nextScan = 0
hook.Add("Think", "ghmpb_blades", function()
	if not G.cv or not G.cv.enable:GetBool() or Amount() <= 0 then return end
	local now = CurTime()
	local dt = FrameTime()
	if dt <= 0 then return end
	-- the local player is tracked whenever a melee weapon is out (its swing direction is known before the first hit)
	if now >= nextScan then
		nextScan = now + 0.5
		local lp = LocalPlayer()
		if IsValid(lp) and lp:Alive() and B.IsMelee(lp) then State(lp) end
	end
	for ent, st in pairs(B.list) do
		-- if the tracked weapon was dropped onto the ground (e.g. GHM FLESH arm injury or disarm), hand off its wet load
		if IsValid(st.wep) and not IsValid(st.wep:GetOwner()) and st.load > 25 then
			B.dropped[st.wep] = { load = st.load * 0.65, btype = st.btype or 0, oxy = st.oxy or 0.8,
				sharp = st.sharp, loadT = st.loadT or now, nextT = now + 0.15 }
			st.wep = nil
			st.load = 0
		end
		local keep = IsValid(ent) and (not ent.Alive or ent:Alive() or ent:IsNPC())
		if keep then
			local ok, alive = pcall(Step, ent, st, now, dt)
			keep = ok and alive
			-- forget entities that are clean and no longer carrying a melee weapon
			if keep and st.load <= 1 and now - st.t > 5 and not B.IsMelee(ent) then keep = false end
		end
		if not keep then B.list[ent] = nil end
	end
	for wep, ds in pairs(B.dropped) do
		if not IsValid(wep) or IsValid(wep:GetOwner()) or ds.load <= 8 or now - ds.loadT > 45 then
			B.dropped[wep] = nil
		elseif now >= ds.nextT then
			ds.nextT = now + U.RandRange(0.45, 1.15)
			local wp = wep:WorldSpaceCenter()
			local tr = util.TraceLine({ start = wp + Vector(0, 0, 2), endpos = wp - Vector(0, 0, 10), filter = wep, mask = MASK_SOLID_BRUSHONLY })
			if tr.Hit and not tr.StartSolid and G.Surfaces and G.Surfaces.Impact then
				local give = math.min(ds.load * 0.35, 95)
				ds.load = ds.load - give
				local v = wep:GetVelocity()
				local sp = v:Length()
				G.Surfaces.Impact(tr.HitPos, tr.HitNormal, sp > 12 and v * 0.25 or vector_origin,
					ds.sharp and 0.48 or 0.68, give, sp > 25 and 3 or 1, 0, 1.2, 0.25, tr, ds.oxy, ds.btype)
			end
		end
	end
end)

function B.Clear() B.list = {} B.dropped = {} end

function B.Describe()
	local n, load = 0, 0
	for _, st in pairs(B.list) do n = n + 1 load = load + st.load end
	return string.format("blades: %d tracked, %.0f mm3 on weapons, loads %d, cast-off drops %d, drips %d", n, load,
		B.stats.loads, B.stats.cast, B.stats.drips)
end
