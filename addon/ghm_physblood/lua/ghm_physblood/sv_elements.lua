local G = GHMPB
G.Elem = G.Elem or {}
local EL = G.Elem
local K = G.EL

util.AddNetworkString("ghmpb_elem")
util.AddNetworkString("ghmpb_arc")

local band, bor = bit.band, bit.bor
local HEATT = bor(DMG_BURN, DMG_SLOWBURN)
local WAVET = bor(DMG_BLAST, DMG_SONIC, DMG_BLAST_SURFACE or 0)
local ANY = bor(HEATT, DMG_PLASMA or 0, DMG_SHOCK, DMG_ENERGYBEAM, DMG_ACID, DMG_DISSOLVE, WAVET, DMG_RADIATION)
local GAP = 18

EL.stats = EL.stats or { sent = 0, discharges = 0, shocked = 0, dried = 0 }
EL.zapT = EL.zapT or {}
EL.sentT = EL.sentT or {}

local function On() return G.cv_sv_elem:GetBool() and G.cv_sv_enable:GetBool() end
EL.On = On

function EL.Temperature()
	local sf = StormFox2
	if not sf or not sf.Temperature or not sf.Temperature.Get then return nil end
	local ok, t = pcall(sf.Temperature.Get)
	if ok and isnumber(t) then return t end
	return nil
end
local skyTr = { mask = MASK_SOLID_BRUSHONLY }
local function Outdoors(pos)
	skyTr.start = pos + Vector(0, 0, 4)
	skyTr.endpos = pos + Vector(0, 0, 4000)
	local tr = util.TraceLine(skyTr)
	return tr.HitSky or not tr.Hit
end
local downTr = { mask = MASK_SOLID_BRUSHONLY }
function EL.ColdAt(pos, nrm)
	downTr.start = pos + (nrm or Vector(0, 0, 1)) * 2
	downTr.endpos = pos - (nrm or Vector(0, 0, 1)) * 6
	local tr = util.TraceLine(downTr)
	local kind = tr.Hit and G.SurfaceKindOf(tr) or nil
	if kind == "snow" or kind == "ice" then return true end
	local t = EL.Temperature()
	return t ~= nil and t < 0 and Outdoors(pos)
end

function EL.Send(kind, pos, radius, strength, duration, ent, pos2)
	if not On() or not pos then return end
	local key = kind .. ":" .. (IsValid(ent) and ent:EntIndex() or (math.floor(pos.x / 24) .. ":" .. math.floor(pos.y / 24) .. ":" .. math.floor(pos.z / 24)))
	local now = CurTime()
	if (EL.sentT[key] or 0) > now then return end
	EL.sentT[key] = now + (kind == K.LASER and 0.05 or 0.15)
	EL.stats.sent = EL.stats.sent + 1
	G.DiagCount("sv: element events sent (" .. (G.EL_NAMES[kind] or kind) .. ")")
	net.Start("ghmpb_elem", true)
	net.WriteUInt(kind, 4)
	net.WriteVector(pos)
	net.WriteUInt(math.Clamp(math.floor((radius or 16) + 0.5), 1, 2047), 11)
	net.WriteUInt(math.Clamp(math.floor((strength or 1) * 100 + 0.5), 0, 255), 8)
	net.WriteUInt(math.Clamp(math.floor((duration or 1) * 10 + 0.5), 0, 1023), 10)
	net.WriteEntity(IsValid(ent) and ent or NULL)
	net.WriteBool(pos2 ~= nil)
	if pos2 then net.WriteVector(pos2) end
	if game.SinglePlayer() then net.Broadcast() else net.Send(G.Recipients(pos, ent, pos2)) end
end

local function WetTime(r)
	local base = G.cv_sv_wettime:GetFloat()
	if r.kind == 2 then return base * math.Clamp(math.sqrt(r.vol / 20000), 0.6, 2.5) end
	if r.kind == 1 then return base * 0.2 * math.Clamp(math.sqrt(r.vol / 1500), 0.5, 2) end
	return base * 0.1
end
function EL.Wet(r, now)
	if r.dry then return false end
	local age = (now or CurTime()) - r.t
	if r.cold and age > 40 and not r.thawed then return false end
	return age < WetTime(r)
end

local CELL = 1024
function EL.WetNear(pos, reach, now)
	local H = G.Hist
	local out = {}
	if not H or not H.cells then return out end
	now = now or CurTime()
	local f = math.floor
	local x0, x1 = f((pos.x - reach - 64) / CELL), f((pos.x + reach + 64) / CELL)
	local y0, y1 = f((pos.y - reach - 64) / CELL), f((pos.y + reach + 64) / CELL)
	local z0, z1 = f((pos.z - 96) / CELL), f((pos.z + 96) / CELL)
	for cx = x0, x1 do for cy = y0, y1 do for cz = z0, z1 do
		local c = H.cells[cx .. ":" .. cy .. ":" .. cz]
		if c then
			for _, r in pairs(c) do
				local dz = math.abs(r.pos.z - pos.z)
				if dz < 48 then
					local d = math.sqrt((r.pos.x - pos.x) ^ 2 + (r.pos.y - pos.y) ^ 2)
					if d < reach + r.rad and EL.Wet(r, now) then out[#out + 1] = r r.dEl = d end
				end
			end
		end
	end end end
	return out
end

function EL.Heat(pos, radius, amount)
	local now = CurTime()
	for _, r in ipairs(EL.WetNear(pos, radius, now)) do
		r.heat = (r.heat or 0) + amount
		r.thawed = true
		if r.heat > 4 * math.Clamp(r.vol / 20000, 0.5, 3) then r.dry = true EL.stats.dried = EL.stats.dried + 1 end
	end
end

local function Victims(pos, range)
	local out = {}
	local r2 = range * range
	local function add(e)
		if IsValid(e) and e:GetPos():DistToSqr(pos) < r2 then
			local alive = (e:IsPlayer() and e:Alive()) or (not e:IsPlayer() and (e:Health() or 0) > 0)
			if alive then out[#out + 1] = e end
		end
	end
	for _, p in ipairs(player.GetAll()) do add(p) end
	for _, e in ipairs(ents.FindInSphere(pos, range)) do
		if (e:IsNPC() or (e.IsNextBot and e:IsNextBot())) then add(e) end
	end
	return out
end

function EL.Discharge(pos, strength, attacker, src)
	if not On() or EL.zapping or not pos then return false end
	local now = CurTime()
	local ck = math.floor(pos.x / 64) .. ":" .. math.floor(pos.y / 64) .. ":" .. math.floor(pos.z / 64)
	if (EL.zapT[ck] or 0) > now then return false end
	local seeds = EL.WetNear(pos, 28, now)
	if #seeds == 0 then return false end
	EL.zapT[ck] = now + 0.35
	local range = G.cv_sv_elecrange:GetFloat()
	local list, idx = {}, {}
	local queue = {}
	for _, r in ipairs(seeds) do
		if not idx[r] then
			list[#list + 1] = r
			idx[r] = #list
			r.elPar, r.elDist = 0, r.dEl
			queue[#queue + 1] = r
		end
	end
	local qi = 1
	while qi <= #queue and #list < 64 do
		local a = queue[qi]
		qi = qi + 1
		for _, b in ipairs(EL.WetNear(a.pos, a.rad + GAP, now)) do
			if not idx[b] and #list < 64 then
				local d = math.sqrt((a.pos.x - b.pos.x) ^ 2 + (a.pos.y - b.pos.y) ^ 2)
				if d < a.rad + b.rad + GAP and a.elDist + d < range then
					list[#list + 1] = b
					idx[b] = #list
					b.elPar, b.elDist = idx[a], a.elDist + d
					queue[#queue + 1] = b
				end
			end
		end
	end
	local maxD = 0
	for _, r in ipairs(list) do maxD = math.max(maxD, r.elDist + r.rad) end
	local hit = {}
	for _, v in ipairs(Victims(pos, maxD + 64)) do
		local feet = v:GetPos()
		local onGround = true
		if v.OnGround then onGround = v:OnGround() end
		if onGround then
			for i, r in ipairs(list) do
				local d = math.sqrt((feet.x - r.pos.x) ^ 2 + (feet.y - r.pos.y) ^ 2)
				if d < r.rad + 10 and math.abs(feet.z - r.pos.z) < 22 then
					hit[#hit + 1] = { e = v, rec = i, along = r.elDist + d }
					break
				end
			end
		end
	end
	EL.stats.discharges = EL.stats.discharges + 1
	G.DiagCount("sv: electricity ran through wet blood")
	local dmgBase = G.cv_sv_elecdmg:GetFloat() * math.Clamp(strength or 1, 0.2, 2)
	EL.zapping = true
	local ok, err = pcall(function()
		for _, h in ipairs(hit) do
			local v = h.e
			local fall = math.Clamp(1 - h.along / math.max(range, 1), 0.25, 1)
			if dmgBase > 0 and (v.ghmpbZapT or 0) < now then
				v.ghmpbZapT = now + 0.4
				local d = DamageInfo()
				d:SetDamage(math.max(1, dmgBase * fall))
				d:SetDamageType(DMG_SHOCK)
				d:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
				d:SetInflictor(game.GetWorld())
				d:SetDamagePosition(v:GetPos() + Vector(0, 0, 6))
				d:SetDamageForce(Vector(0, 0, 400))
				v:TakeDamageInfo(d)
				EL.stats.shocked = EL.stats.shocked + 1
				G.DiagCount("sv: shocked through wet blood")
			end
			if v:IsPlayer() then
				v:ViewPunch(Angle(math.Rand(-6, 6), math.Rand(-6, 6), math.Rand(-4, 4)))
				v:ScreenFade(SCREENFADE.IN, Color(170, 200, 255, 50), 0.25, 0)
			end
			v:EmitSound("ambient/energy/zap" .. math.random(1, 9) .. ".wav", 70, math.random(90, 115), 0.8)
		end
	end)
	EL.zapping = false
	if not ok then ErrorNoHalt("[GHMPB] electricity: " .. tostring(err) .. "\n") end
	net.Start("ghmpb_arc", true)
	net.WriteVector(pos)
	net.WriteFloat(strength or 1)
	net.WriteUInt(#list, 7)
	for _, r in ipairs(list) do
		net.WriteVector(r.pos)
		net.WriteUInt(r.elPar or 0, 7)
		net.WriteUInt(math.Clamp(math.floor(r.rad + 0.5), 1, 255), 8)
	end
	net.WriteUInt(math.min(#hit, 31), 5)
	for i = 1, math.min(#hit, 31) do
		net.WriteEntity(hit[i].e)
		net.WriteUInt(hit[i].rec, 7)
	end
	if game.SinglePlayer() then net.Broadcast() else net.Send(G.Recipients(pos)) end
	return true, #list, #hit
end

local groundTr = { mask = MASK_SOLID_BRUSHONLY }
local function Ground(pos, depth)
	groundTr.start = pos + Vector(0, 0, 4)
	groundTr.endpos = pos - Vector(0, 0, depth or 160)
	local tr = util.TraceLine(groundTr)
	if tr.Hit and not tr.StartSolid and not tr.HitSky then return tr.HitPos end
	return nil
end
EL.Ground = Ground

local blastsRecent = {}
function EL.Blast(pos, amt, heat)
	local now = CurTime()
	for i = #blastsRecent, 1, -1 do
		local b = blastsRecent[i]
		if now - b.t > 0.6 then table.remove(blastsRecent, i)
		elseif b.p:DistToSqr(pos) < 160 * 160 then return false end
	end
	blastsRecent[#blastsRecent + 1] = { p = Vector(pos), t = now }
	EL.Send(K.WAVE, pos, math.Clamp(amt * 3, 120, 700), math.Clamp(amt / 80, 0.3, 1.5), 0.5)
	if heat then EL.Send(K.HEAT, pos, math.Clamp(amt, 30, 120), 0.6, 0.4) end
	EL.Send(K.DUST, pos, math.Clamp(amt * 2.2, 150, 520), math.Clamp(amt / 90, 0.4, 1.5), 0)
	EL.stats.blasts = (EL.stats.blasts or 0) + 1
	return true
end

local blastSeen = setmetatable({}, { __mode = "k" })
function EL.OnDamage(ent, dmg)
	if EL.zapping or not On() then return end
	local t = dmg:GetDamageType()
	if band(t, ANY) == 0 then return end
	local pos = dmg:GetDamagePosition()
	if not pos or pos:IsZero() then pos = IsValid(ent) and ent:WorldSpaceCenter() or nil end
	if not pos then return end
	local amt = dmg:GetDamage()
	local rad = IsValid(ent) and math.Clamp(ent:BoundingRadius() * 0.8, 12, 80) or 24
	if band(t, DMG_PLASMA or 0) ~= 0 then
		EL.Send(K.PLASMA, pos, 20, math.Clamp(amt / 20, 0.5, 2), 1.0, ent)
		local g = Ground(pos) if g then EL.Heat(g, 20, 1) end
	elseif band(t, HEATT) ~= 0 and band(t, DMG_BLAST) == 0 then
		EL.Send(K.HEAT, IsValid(ent) and ent:WorldSpaceCenter() or pos, rad, 0.8, 1.2, ent)
		local g = Ground(IsValid(ent) and ent:WorldSpaceCenter() or pos) if g then EL.Heat(g, rad, 0.5) end
	end
	if band(t, DMG_SHOCK) ~= 0 then
		local a = dmg:GetAttacker()
		EL.Discharge(Ground(pos, 72) or pos, math.Clamp(amt / 25, 0.3, 1.5), a, ent)
		EL.Send(K.ELEC, pos, 12, 0.6, 0.4, ent)
	end
	if band(t, DMG_ENERGYBEAM) ~= 0 then
		local a = dmg:GetAttacker()
		local from = IsValid(a) and (a.GetShootPos and a:GetShootPos() or a:WorldSpaceCenter()) or nil
		EL.Send(K.LASER, pos, 4, math.Clamp(amt / 20, 0.4, 2), 0.3, ent, from)
	end
	if band(t, DMG_ACID) ~= 0 then
		local g = Ground(pos, 96)
		EL.Send(K.ACID, pos, 10, math.Clamp(amt / 12, 0.4, 1.5), 1.5, ent, g)
	end
	if band(t, DMG_DISSOLVE) ~= 0 and IsValid(ent) then
		EL.Send(K.DISSOLVE, ent:WorldSpaceCenter(), math.Clamp(ent:BoundingRadius(), 16, 120), 1, 2.5, ent)
		local g = Ground(ent:WorldSpaceCenter()) if g then
			for _, r in ipairs(EL.WetNear(g, 40)) do r.dry = true end
		end
	end
	if band(t, WAVET) ~= 0 then
		local inf = dmg:GetInflictor()
		local key = IsValid(inf) and inf or "w" .. math.floor(pos.x / 64) .. ":" .. math.floor(pos.y / 64)
		local now = CurTime()
		if not blastSeen[key] or blastSeen[key] < now then
			blastSeen[key] = now + 0.5
			local c = (IsValid(inf) and band(t, DMG_BLAST) ~= 0) and inf:GetPos() or pos
			if band(t, DMG_BLAST) ~= 0 then
				EL.Blast(c, amt, true)
			else
				EL.Send(K.WAVE, c, math.Clamp(amt * 3, 120, 700), math.Clamp(amt / 80, 0.3, 1.5), 0.5)
			end
		end
	end
	if band(t, DMG_RADIATION) ~= 0 then
		EL.Send(K.RAD, IsValid(ent) and ent:GetPos() or pos, 80, 0.6, 20, ent)
	end
end

hook.Add("PostEntityFireBullets", "ghmpb_elements", function(ent, data)
	if not On() or not data or not data.Trace or not data.AmmoType then return end
	local id = game.GetAmmoID(data.AmmoType)
	if not id or id < 0 then return end
	local t = game.GetAmmoDamageType(id) or 0
	if band(t, bor(DMG_ENERGYBEAM, DMG_PLASMA or 0, HEATT, DMG_SHOCK, DMG_DISSOLVE)) == 0 then return end
	local tr = data.Trace
	if not tr.HitPos then return end
	if IsValid(tr.Entity) and not tr.Entity:IsWorld() then return end
	local dmgv = (data.Damage and data.Damage > 0) and data.Damage or 15
	if band(t, DMG_ENERGYBEAM) ~= 0 then EL.Send(K.LASER, tr.HitPos, 4, math.Clamp(dmgv / 20, 0.4, 2), 0.3, nil, tr.StartPos)
	elseif band(t, DMG_PLASMA or 0) ~= 0 then EL.Send(K.PLASMA, tr.HitPos, 14, 1, 0.8)
	elseif band(t, HEATT) ~= 0 then EL.Send(K.HEAT, tr.HitPos, 12, 0.8, 0.8) end
	if band(t, DMG_SHOCK) ~= 0 then EL.Discharge(tr.HitPos, math.Clamp(dmgv / 25, 0.3, 1.5), ent) EL.Send(K.ELEC, tr.HitPos, 12, 0.6, 0.4) end
end)

local tracked = {}
local TRACK = { entityflame = "flame", env_fire = "fire", _firesmoke = "fire", vfire = "fire", crossbow_bolt = "bolt",
	grenade_spit = "spit", env_laser = "laser", env_beam = "beam", prop_combine_ball = "ball",
	npc_grenade_frag = "blast", grenade_ar2 = "blast", rpg_missile = "blast", apc_missile = "blast",
	grenade_helicopter = "blast", npc_satchel = "blast", npc_tripmine = "blast" }
local BLAST_AMT = { npc_grenade_frag = 125, grenade_ar2 = 100, rpg_missile = 150, apc_missile = 100, grenade_helicopter = 150,
	npc_satchel = 150, npc_tripmine = 150 }
local EXPLOSIVE_MDL = { "explosive", "gascan", "propane", "props_phx/ww2bomb", "props_phx/mk-82", "props_phx/torpedo",
	"props_phx/amraam", "props_phx/misc/flakshell" }
hook.Add("OnEntityCreated", "ghmpb_elements", function(e)
	timer.Simple(0, function()
		if IsValid(e) and TRACK[e:GetClass()] then tracked[e] = TRACK[e:GetClass()] end
	end)
end)
hook.Add("PreCleanupMap", "ghmpb_elements", function() EL.cleaning = true end)
hook.Add("PostCleanupMap", "ghmpb_elements", function() EL.cleaning = nil end)
hook.Add("ShutDown", "ghmpb_elements", function() EL.cleaning = true end)
local function IsExplosiveProp(e)
	if e:GetClass() ~= "prop_physics" and e:GetClass() ~= "prop_physics_multiplayer" then return false end
	if e:Health() > 0 or e:GetMaxHealth() <= 0 then return false end
	local m = string.lower(e:GetModel() or "")
	for _, k in ipairs(EXPLOSIVE_MDL) do if string.find(m, k, 1, true) then return true end end
	return false
end
hook.Add("EntityRemoved", "ghmpb_elements", function(e)
	local k = tracked[e]
	if not k then
		if not EL.cleaning and On() and IsExplosiveProp(e) then
			local p = e:WorldSpaceCenter()
			timer.Simple(0, function() EL.Blast(p, 140, true) end)
		end
		return
	end
	tracked[e] = nil
	if not On() or EL.cleaning then return end
	if k == "spit" then
		local p = e:GetPos()
		local g = Ground(p, 48)
		if g then EL.Send(K.ACID, p, 14, 1, 2, nil, g) end
	elseif k == "blast" then
		local p, amt = e:GetPos(), BLAST_AMT[e:GetClass()] or 120
		timer.Simple(0, function() EL.Blast(p, amt, true) end)
	end
end)
hook.Add("AcceptInput", "ghmpb_elements", function(e, input)
	if not On() or EL.cleaning or not IsValid(e) or e:GetClass() ~= "env_explosion" or string.lower(input or "") ~= "explode" then return end
	local kv = e:GetKeyValues()
	local mag = tonumber(kv and (kv.iMagnitude or kv.imagnitude)) or 100
	if mag <= 0 then return end
	local p = e:GetPos()
	timer.Simple(0, function() EL.Blast(p, math.Clamp(mag, 40, 300), true) end)
end)
local function Var(e, name)
	local ok, v = pcall(e.GetInternalVariable, e, name)
	if ok then return v end
	return nil
end
local function ScanFires()
	if not On() then return end
	for e, k in pairs(tracked) do
		if not IsValid(e) then
			tracked[e] = nil
		elseif k == "flame" then
			local par = e:GetParent()
			local tgt = IsValid(par) and par or e
			local c = tgt:WorldSpaceCenter()
			local rad = math.Clamp(tgt:BoundingRadius() * 0.9, 16, 90)
			EL.Send(K.HEAT, c, rad, 0.9, 0.8, IsValid(par) and par or nil)
			local g = Ground(c) if g then EL.Heat(g, rad, 0.3) end
		elseif k == "fire" then
			local on = Var(e, "m_bEnabled")
			if on ~= false then
				local size = tonumber(Var(e, "firesize") or Var(e, "m_flFireSize")) or 64
				local rad = math.Clamp(size * 0.6, 16, 160)
				EL.Send(K.HEAT, e:GetPos() + Vector(0, 0, 8), rad, 1, 0.8)
				EL.Heat(e:GetPos(), rad, 0.3)
			end
		elseif k == "bolt" then
			if not e.ghmpbHot and e:GetVelocity():LengthSqr() < 25 then
				e.ghmpbHot = true
				EL.Send(K.HOT, e:GetPos(), 5, 1, 8)
			end
		elseif k == "laser" then
			local a, b = e:GetPos(), Var(e, "m_vecEndPos")
			if isvector(b) then EL.Send(K.LASER, b, 4, 1, 0.4, nil, a) end
		elseif k == "beam" then
			local b = Var(e, "m_vecEndPos")
			if isvector(b) then EL.Discharge(b, 0.8) end
			EL.Discharge(e:GetPos(), 0.8)
		elseif k == "ball" then
			for _, r in ipairs(EL.WetNear(e:GetPos(), 16)) do r.dry = true end
		end
	end
end
timer.Create("ghmpb_elements", 0.3, 0, function()
	local ok, err = pcall(ScanFires)
	if not ok then ErrorNoHalt("[GHMPB] elements: " .. tostring(err) .. "\n") end
end)

local ZAP = { "ambient/energy/zap", "ambient/energy/spark", "ambient/energy/newspark", "weapons/stunstick/spark",
	"weapons/stunstick/stunstick_impact", "ambient/levels/labs/electric_explosion", "weapons/physcannon/superphys_small_zap",
	"ambient/energy/weld", "npc/roller/mine/rmine_shockvehicle", "npc/roller/mine/rmine_taunt", "weapons/stunstick/stunstick_fleshhit" }
hook.Add("EntityEmitSound", "ghmpb_elements", function(data)
	if EL.zapping or not On() or not data or not data.SoundName then return end
	local snd = string.lower(data.SoundName)
	local pos = data.Pos or (IsValid(data.Entity) and data.Entity:GetPos())
	if not pos then return end
	if string.find(snd, "thumper", 1, true) and (string.find(snd, "hit", 1, true) or string.find(snd, "thump", 1, true)) then
		EL.Send(K.WAVE, pos, 600, 0.5, 0.5)
		EL.Send(K.DUST, pos, 220, 0.25, 0)
		return
	end
	for _, z in ipairs(ZAP) do
		if string.find(snd, z, 1, true) then
			local g = Ground(pos, 96)
			if g then timer.Simple(0, function() EL.Discharge(g, 0.7, IsValid(data.Entity) and data.Entity or nil) end) end
			return
		end
	end
	if (string.find(snd, "explode", 1, true) or string.find(snd, "explosion", 1, true)) and not string.find(snd, "loop", 1, true)
		and not string.find(snd, "physcannon", 1, true) and not string.find(snd, "energy", 1, true) and not string.find(snd, "distant", 1, true)
		and (data.SoundLevel or 140) >= 100 then
		local e = data.Entity
		if IsValid(e) and (e:GetClass() == "ambient_generic" or e:GetClass() == "env_soundscape") then return end
		local p = Vector(pos)
		timer.Simple(0, function() EL.Blast(p, 120, true) end)
	end
end)

hook.Add("GravGunPunt", "ghmpb_elements", function(ply, ent)
	if not On() or not IsValid(ent) then return end
	local g = Ground(ent:WorldSpaceCenter(), 96)
	if g then EL.Send(K.WAVE, g, 140, 0.5, 0.3) end
end)

concommand.Add("ghmpb_sv_elements_diag", function(ply)
	if IsValid(ply) and not ply:IsListenServerHost() and not ply:IsSuperAdmin() then return end
	local wet = 0
	if G.Hist and G.Hist.recs then for _, r in pairs(G.Hist.recs) do if EL.Wet(r) then wet = wet + 1 end end end
	print(string.format("[GHMPB elements sv] on %s | events sent %d | discharges %d | shocked %d | records dried %d | wet records now %d | temperature %s",
		tostring(On()), EL.stats.sent, EL.stats.discharges, EL.stats.shocked, EL.stats.dried, wet, tostring(EL.Temperature())))
end)
