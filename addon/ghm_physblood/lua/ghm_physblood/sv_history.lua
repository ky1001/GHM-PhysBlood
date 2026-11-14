local G = GHMPB
G.Hist = G.Hist or {}
local H = G.Hist

util.AddNetworkString("ghmpb_hist")
util.AddNetworkString("ghmpb_ready")

local FL = { FCVAR_ARCHIVE }
G.cv_sv_hist = CreateConVar("ghmpb_sv_history", "1", FL, "GHM PhysBlood: players who arrive later (or join) see the blood that was left before", 0, 1)
G.cv_sv_histtime = CreateConVar("ghmpb_sv_history_time", "900", FL, "GHM PhysBlood: seconds the server remembers blood for players who arrive later", 30, 7200)
G.cv_sv_histmax = CreateConVar("ghmpb_sv_history_max", "3000", FL, "GHM PhysBlood: most blood records the server keeps for players who arrive later", 100, 20000)
G.cv_sv_histrange = CreateConVar("ghmpb_sv_history_range", "2500", FL, "GHM PhysBlood: distance (units) at which a player gets the blood left before he arrived", 500, 20000)

local CELL = 1024
local floor = math.floor
local band, bor = bit.band, bit.bor

local function SendOn() return G.cv_sv_hist:GetBool() and G.cv_sv_enable:GetBool() end
local function On() return G.cv_sv_enable:GetBool() and (SendOn() or (G.cv_sv_elem ~= nil and G.cv_sv_elem:GetBool())) end
H.On, H.SendOn = On, SendOn

function H.Clear()
	H.recs, H.cells, H.order, H.head, H.count, H.nextId = {}, {}, {}, 1, 0, 1
	H.bleeders = {}
	H.bodies = setmetatable({}, { __mode = "k" })
	for _, pl in ipairs(player.GetAll()) do pl.ghmpbHS, pl.ghmpbHB = nil, nil end
end
if not H.recs then H.Clear() end

local function Key(p) return floor(p.x / CELL) .. ":" .. floor(p.y / CELL) .. ":" .. floor(p.z / CELL) end

local function Unlink(r)
	local c = H.cells[r.key]
	if c then c[r.id] = nil if next(c) == nil then H.cells[r.key] = nil end end
end
local function Link(r)
	r.key = Key(r.pos)
	local c = H.cells[r.key]
	if not c then c = {} H.cells[r.key] = c end
	c[r.id] = r
end

local function Remove(r)
	Unlink(r)
	H.recs[r.id] = nil
	H.count = H.count - 1
end

local function MarkKnown(have, id)
	if not have then return end
	for _, pl in ipairs(have) do
		pl.ghmpbHS = pl.ghmpbHS or {}
		pl.ghmpbHS[id] = true
	end
end

local MERGE = { [1] = 6, [2] = 24, [3] = 12 }
function H.Add(kind, pos, nrm, vol, rad, bt, have, dir)
	if not On() or vol <= 0 then return nil end
	local now = CurTime()
	local c = H.cells[Key(pos)]
	if c then
		local m = MERGE[kind] or 8
		for _, r in pairs(c) do
			if r.kind == kind and r.bt == bt and r.pos:DistToSqr(pos) < m * m and r.nrm:Dot(nrm) > 0.8 then
				r.vol = r.vol + vol
				r.rad = math.max(r.rad, rad)
				r.t = now
				MarkKnown(have, r.id)
				return r
			end
		end
	end
	local r = { id = H.nextId, kind = kind, pos = Vector(pos), nrm = Vector(nrm), dir = dir and Vector(dir) or Vector(nrm) * -1,
		vol = vol, rad = rad, bt = bt or 0, t = now }
	if G.Elem and G.Elem.ColdAt then r.cold = G.Elem.ColdAt(r.pos, r.nrm) end
	H.nextId = H.nextId + 1
	H.recs[r.id] = r
	H.order[#H.order + 1] = r.id
	H.count = H.count + 1
	Link(r)
	MarkKnown(have, r.id)
	return r
end

local function Move(r, pos, nrm)
	Unlink(r)
	r.pos, r.nrm = Vector(pos), Vector(nrm)
	Link(r)
end

local floorTr = { mask = MASK_SOLID_BRUSHONLY }
local function Floor(pos, depth)
	floorTr.start = pos + Vector(0, 0, 2)
	floorTr.endpos = pos - Vector(0, 0, depth or 256)
	local tr = util.TraceLine(floorTr)
	if tr.Hit and not tr.StartSolid and not tr.HitSky and tr.HitNormal.z > 0.5 then return tr end
	return nil
end

local function NearestBone(ent, pos)
	local best, bd
	local set = ent.GetHitboxSet and ent:GetHitboxSet() or 0
	local nh = ent.GetHitBoxCount and ent:GetHitBoxCount(set) or 0
	if nh and nh > 0 then
		for h = 0, nh - 1 do
			local b = ent:GetHitBoxBone(h, set)
			local bp = b and ent:GetBonePosition(b)
			if bp then
				local d = bp:DistToSqr(pos)
				if not bd or d < bd then best, bd = b, d end
			end
		end
		if best then return best end
	end
	for b = 0, math.min((ent:GetBoneCount() or 0) - 1, 255) do
		local bp = ent:GetBonePosition(b)
		if bp then
			local d = bp:DistToSqr(pos)
			if not bd or d < bd then best, bd = b, d end
		end
	end
	return best
end

local function Known(pl, ent)
	pl.ghmpbHB = pl.ghmpbHB or setmetatable({}, { __mode = "k" })
	local k = pl.ghmpbHB[ent]
	if not k then k = {} pl.ghmpbHB[ent] = k end
	return k
end

function H.BodyHit(ent, pos, dir, S, bt, have)
	if not ent.GetBoneCount then return end
	local b = NearestBone(ent, pos)
	if not b then return end
	local bp, ba = ent:GetBonePosition(b)
	if not bp or not ba then return end
	local lp = WorldToLocal(pos, angle_zero, bp, ba)
	local ln = WorldToLocal(-dir, angle_zero, vector_origin, ba)
	local list = ent.ghmpbBH or {}
	ent.ghmpbBH = list
	local n = (ent.ghmpbBHn or 0) + 1
	ent.ghmpbBHn = n
	list[#list + 1] = { i = n, b = b, lp = lp, ln = ln, S = S, t = CurTime(), bt = bt or 0 }
	if #list > 12 then table.remove(list, 1) end
	H.bodies[ent] = true
	if have then for _, pl in ipairs(have) do Known(pl, ent)[n] = true end end
end

local BULLET = bor(DMG_BULLET, DMG_BUCKSHOT, DMG_SNIPER or 0, DMG_AIRBOAT)
function H.OnHit(ent, pos, dir, amount, dtype, blast, fatal, rf)
	if not On() or not IsValid(ent) then return end
	local bt = G.BloodTypeOf(ent)
	if bt == nil then return end
	local S = math.Clamp(amount / 60, 0.3, 2.5) * G.cv_sv_bleed:GetFloat()
	local have = rf and rf:GetPlayers() or nil
	local fl = Floor(pos)
	if fl then H.Add(1, fl.HitPos, fl.HitNormal, 1500 * S, 3 + 2 * S, bt, have, dir) end
	if blast then
		if fl then H.Add(3, fl.HitPos, fl.HitNormal, 5000 * S, 40, bt, have, dir) end
	elseif band(dtype, BULLET) ~= 0 and amount >= 8 then
		local tr = util.TraceLine({ start = pos + dir * 12, endpos = pos + dir * 180, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.StartSolid and not tr.HitSky then H.Add(3, tr.HitPos, tr.HitNormal, 900 * S, 10 + 6 * S, bt, have, dir) end
	end
	H.BodyHit(ent, pos, dir, S, bt, have)
	if not fatal and (ent:IsNPC() or ent:IsPlayer() or (ent.IsNextBot and ent:IsNextBot()) or G.LivingRagdoll(ent)) then
		H.bleeders[ent] = math.max(H.bleeders[ent] or 0, CurTime() + 25)
	end
end

local function PoolRadius(vol) return math.sqrt(vol / (math.pi * 2)) / 19.05 end

local function WoundWorldPos(ent)
	local bh = ent.ghmpbBH
	if bh and #bh > 0 then
		local h = bh[#bh]
		if h.bone and h.bone >= 0 and h.lp then
			local m = ent:GetBoneMatrix(h.bone)
			if m then return LocalToWorld(h.lp, angle_zero, m:GetTranslation(), m:GetAngles()) end
			local bp, ba = ent:GetBonePosition(h.bone)
			if bp then return LocalToWorld(h.lp, angle_zero, bp, ba or angle_zero) end
		elseif h.lp then
			return ent:LocalToWorld(h.lp)
		end
	end
	if ent.ghmpbLastHitPos and (CurTime() - (ent.ghmpbLastHitT or 0)) < 5 then
		return ent.ghmpbLastHitPos
	end
	return ent:WorldSpaceCenter()
end

local function Follow(r, corpse)
	if not r or not IsValid(corpse) then return end
	for _, d in ipairs({ 5, 15 }) do
		timer.Simple(d, function()
			if not IsValid(corpse) or H.recs[r.id] ~= r then return end
			local fl = Floor(WoundWorldPos(corpse), 96)
			if fl then Move(r, fl.HitPos, fl.HitNormal) end
		end)
	end
end

function H.OnDeath(ent, bloodless, rf)
	if not On() or not IsValid(ent) then return end
	H.bleeders[ent] = nil
	local bt = G.BloodTypeOf(ent)
	if bt == nil then return end
	local fl = Floor(WoundWorldPos(ent), 128)
	if not fl then return end
	local vol = (bloodless and 0.3 or 1) * 480000 * G.cv_sv_bleed:GetFloat()
	local r = H.Add(2, fl.HitPos, fl.HitNormal, vol, PoolRadius(vol), bt, rf and rf:GetPlayers() or nil)
	if not r then return end
	r.src, r.srcT = ent, CurTime()
	if ent:IsPlayer() then
		local rag = ent:GetNWEntity("RagdollDeath")
		if IsValid(rag) then Follow(r, rag) end
	end
end

function H.OnCorpse(owner, rag)
	if not IsValid(owner) or not IsValid(rag) then return end
	if owner.ghmpbBH and owner:GetModel() == rag:GetModel() then
		rag.ghmpbBH, rag.ghmpbBHn = table.Copy(owner.ghmpbBH), owner.ghmpbBHn
		H.bodies[rag] = true
		for _, pl in ipairs(player.GetAll()) do
			if pl.ghmpbHB and pl.ghmpbHB[owner] then pl.ghmpbHB[rag] = table.Copy(pl.ghmpbHB[owner]) end
		end
	end
	if not On() then return end
	local now = CurTime()
	for i = #H.order, math.max(1, #H.order - 64), -1 do
		local r = H.recs[H.order[i]]
		if r and r.kind == 2 and r.src == owner and now - (r.srcT or 0) < 10 then Follow(r, rag) break end
	end
end

local function Bleeding(ent, untilT, now)
	if not IsValid(ent) then return false end
	if ent:IsPlayer() and not ent:Alive() then return false end
	if (ent:IsNPC() or (ent.IsNextBot and ent:IsNextBot())) and ent:Health() <= 0 then return false end
	local org = ent.organism
	if istable(org) and istable(org.wounds) and #org.wounds > 0 and (org.blood or 5000) > 10 then return true end
	return now < untilT
end

local function Trails()
	local now = CurTime()
	for ent, untilT in pairs(H.bleeders) do
		if not Bleeding(ent, untilT, now) then
			H.bleeders[ent] = nil
		else
			local v = ent:GetVelocity()
			if v:Length2DSqr() > 400 then
				local fl = Floor(ent:WorldSpaceCenter(), 128)
				local bt = G.BloodTypeOf(ent)
				if fl and bt ~= nil then
					local rf = RecipientFilter() rf:AddPVS(fl.HitPos)
					H.Add(1, fl.HitPos, fl.HitNormal, 150, 1.5, bt, rf:GetPlayers(), v:GetNormalized())
				end
			end
		end
	end
end

local function Expire()
	local maxAge, maxN, now = G.cv_sv_histtime:GetFloat(), G.cv_sv_histmax:GetInt(), CurTime()
	while H.head <= #H.order do
		local r = H.recs[H.order[H.head]]
		if r then
			if H.count <= maxN and now - r.t <= maxAge then break end
			Remove(r)
		end
		H.head = H.head + 1
	end
	if H.head > 2000 then
		local o = {}
		for i = H.head, #H.order do o[#o + 1] = H.order[i] end
		H.order, H.head = o, 1
	end
end

local function ViewPos(pl)
	local ve = pl:GetViewEntity()
	if IsValid(ve) and ve ~= pl then return ve:GetPos() end
	return pl:EyePos()
end

local MAX_WORLD, MAX_BODIES = 48, 16
local function SendTo(pl, range)
	local o = ViewPos(pl)
	local known = pl.ghmpbHS or {}
	pl.ghmpbHS = known
	local r2 = range * range
	local list = {}
	local x0, x1 = floor((o.x - range) / CELL), floor((o.x + range) / CELL)
	local y0, y1 = floor((o.y - range) / CELL), floor((o.y + range) / CELL)
	local z0, z1 = floor((o.z - range * 0.6) / CELL), floor((o.z + range * 0.6) / CELL)
	for cx = x0, x1 do
		for cy = y0, y1 do
			for cz = z0, z1 do
				local c = H.cells[cx .. ":" .. cy .. ":" .. cz]
				if c then
					for id, r in pairs(c) do
						if not known[id] then
							local d = r.pos:DistToSqr(o)
							if d < r2 then r.d = d list[#list + 1] = r end
						end
					end
				end
			end
		end
	end
	local bodies = {}
	for ent in pairs(H.bodies) do
		if not IsValid(ent) or not ent.ghmpbBH then
			H.bodies[ent] = nil
		elseif ent ~= pl and ent:GetPos():DistToSqr(o) < r2 and pl:TestPVS(ent) then
			local kn = Known(pl, ent)
			local miss = {}
			for _, h in ipairs(ent.ghmpbBH) do if not kn[h.i] then miss[#miss + 1] = h end end
			if #miss > 0 then bodies[#bodies + 1] = { ent = ent, hits = miss, kn = kn } end
		end
	end
	if #list == 0 and #bodies == 0 then return end
	table.sort(list, function(a, b) return a.d < b.d end)
	local nW, nB = math.min(#list, MAX_WORLD), math.min(#bodies, MAX_BODIES)
	local now = CurTime()
	net.Start("ghmpb_hist")
	net.WriteUInt(nW, 8)
	for i = 1, nW do
		local r = list[i]
		known[r.id] = true
		net.WriteUInt(r.kind, 3)
		net.WriteVector(r.pos)
		net.WriteNormal(r.nrm)
		net.WriteNormal(r.dir)
		net.WriteFloat(r.vol)
		net.WriteFloat(r.rad)
		net.WriteUInt(r.bt, 3)
		net.WriteFloat(now - r.t)
	end
	net.WriteUInt(nB, 8)
	for i = 1, nB do
		local e = bodies[i]
		net.WriteEntity(e.ent)
		net.WriteUInt(#e.hits, 4)
		for _, h in ipairs(e.hits) do
			e.kn[h.i] = true
			net.WriteUInt(h.b, 8)
			net.WriteVector(h.lp)
			net.WriteNormal(h.ln)
			net.WriteFloat(h.S)
			net.WriteFloat(now - h.t)
			net.WriteUInt(h.bt, 3)
		end
	end
	net.Send(pl)
	G.DiagCount("sv: history records sent")
end

timer.Create("ghmpb_history", 1, 0, function()
	if not On() then return end
	local ok, err = pcall(function()
		Trails()
		Expire()
		if not SendOn() then return end
		local range = G.cv_sv_histrange:GetFloat()
		for _, pl in ipairs(player.GetHumans()) do
			if pl.ghmpbReady then SendTo(pl, range) end
		end
	end)
	if not ok then ErrorNoHalt("[GHMPB] history: " .. tostring(err) .. "\n") end
end)

net.Receive("ghmpb_ready", function(_, pl)
	if IsValid(pl) then pl.ghmpbReady = true end
end)

hook.Add("PlayerSpawn", "ghmpb_history", function(pl) pl.ghmpbBH, pl.ghmpbBHn = nil, nil end)
hook.Add("PostCleanupMap", "ghmpb_history", function() H.Clear() end)
concommand.Add("ghmpb_sv_history_clear", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() and not ply:IsListenServerHost() then return end
	H.Clear()
end, nil, "GHM PhysBlood: forget the blood kept for players who arrive later")
