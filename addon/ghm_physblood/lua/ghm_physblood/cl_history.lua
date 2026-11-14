local G = GHMPB
G.HistCl = G.HistCl or {}
local HC = G.HistCl
local U = G.U

HC.world = HC.world or {}
HC.bodies = HC.bodies or {}
HC.stats = HC.stats or { world = 0, bodies = 0, skipped = 0 }

local function Ready()
	if type(G.ServerRuns) == "function" and not G.ServerRuns() then return end   -- (1.26.8) PhysBlood on this client alone
	net.Start("ghmpb_ready")
	net.SendToServer()
end
hook.Add("InitPostEntity", "ghmpb_history", function()
	timer.Simple(1, Ready)
	timer.Simple(8, Ready)
end)

net.Receive("ghmpb_hist", function()
	local now = CurTime()
	for _ = 1, net.ReadUInt(8) do
		local r = { kind = net.ReadUInt(3), pos = net.ReadVector(), nrm = net.ReadNormal(), dir = net.ReadNormal(), vol = net.ReadFloat(),
			rad = net.ReadFloat(), bt = net.ReadUInt(3) }
		r.t = now - net.ReadFloat()
		HC.world[#HC.world + 1] = r
	end
	for _ = 1, net.ReadUInt(8) do
		local ent = net.ReadEntity()
		local hits = {}
		for j = 1, net.ReadUInt(4) do
			hits[j] = { b = net.ReadUInt(8), lp = net.ReadVector(), ln = net.ReadNormal(), S = net.ReadFloat() }
			hits[j].t = now - net.ReadFloat()
			hits[j].bt = net.ReadUInt(3)
		end
		HC.bodies[#HC.bodies + 1] = { ent = ent, hits = hits, tries = 0 }
	end
end)

local function Wet(t)
	local age = CurTime() - t
	return math.Clamp(1 - age / (G.DryTime() * 1.2), 0, 1)
end

local function Tangents(n)
	local up = math.abs(n.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
	local t = n:Cross(up) t:Normalize()
	return t, n:Cross(t)
end

local function Spread(v, speed)
	local rmm = (v / 4.18879) ^ (1 / 3)
	local vm = speed * 0.01905
	local We = 1060 * vm * vm * (2 * rmm / 1000) / 0.058
	return rmm * math.Clamp(1 + 0.48 * We ^ 0.25, 1.25, 6.5) * G.MM_TO_UNITS
end

local trW = { mask = MASK_SOLID_BRUSHONLY }
local function ApplyWorld(r)
	trW.start, trW.endpos = r.pos + r.nrm * 6, r.pos - r.nrm * 12
	local tr = util.TraceLine(trW)
	if not tr.Hit or tr.StartSolid or tr.HitSky then HC.stats.skipped = HC.stats.skipped + 1 return end
	local S = G.Surfaces
	local wet = Wet(r.t)
	local p, n = tr.HitPos, tr.HitNormal
	local t, b = Tangents(n)
	if r.kind == 2 then
		if wet > 0.05 then S.Impact(p, n, vector_origin, math.max(r.rad * 0.4, 1.5), r.vol * wet, 1, 0, 1, 0, tr, 0.6, r.bt) end
		if wet < 0.95 then
			for _ = 1, 3 do
				local off = (t * U.RandRange(-1, 1) + b * U.RandRange(-1, 1)) * r.rad * 0.3
				S.Impact(p + off, n, vector_origin, r.rad * U.RandRange(0.55, 0.8), r.vol * (1 - wet) * 0.2 / 3, 0, 0, 1, 1, tr, 0.6, r.bt)
			end
		end
	else
		local spatter = r.kind == 3
		local cnt = spatter and math.Clamp(math.floor(r.vol / 60), 5, 40) or math.Clamp(math.floor(r.vol / 150), 2, 8)
		local per = r.vol / cnt
		local residue = 1 - wet * 0.75
		for _ = 1, cnt do
			local a = math.random() * math.pi * 2
			local off = (t * math.cos(a) + b * math.sin(a)) * r.rad * math.sqrt(math.random())
			local v = per * U.RandRange(0.3, 1.7)
			local vel = spatter and (r.dir + VectorRand() * 0.25) * U.RandRange(150, 450) or -n * U.RandRange(180, 320)
			S.Impact(p + off, n, vel, Spread(v, vel:Length()), v, 0, 0, 1, residue, tr, 0.6, r.bt)
		end
	end
	HC.stats.world = HC.stats.world + 1
end

local function ApplyBody(e)
	local ent = e.ent
	if not IsValid(ent) then return true end
	if ent:IsDormant() or not ent:GetBoneMatrix(0) then return false end
	local btype = G.BloodTypeOf(ent)
	if btype == nil then return true end
	local E = G.Entities
	for _, h in ipairs(e.hits) do
		local m = ent:GetBoneMatrix(h.b)
		if m then
			local pos = LocalToWorld(h.lp, angle_zero, m:GetTranslation(), m:GetAngles())
			local nrm = LocalToWorld(h.ln, angle_zero, vector_origin, m:GetAngles())
			local surf, sn = U.EntitySurface(ent, pos, -nrm)
			surf, sn = U.SnapToMesh(ent, surf, sn, h.b)
			local wet = Wet(h.t)
			local S = h.S
			E.Impact(ent, surf, sn, vector_origin, 0.32 * math.sqrt(S), 220 * S, 2, 0, 1, 0.85, h.b, { oxy = 0.6 })
			if wet > 0.05 then E.Impact(ent, surf, sn, vector_origin, 0.4, 500 * S * wet, 1, 0, 1, 0, h.b, { oxy = 0.6 }) end
			if wet < 0.95 then E.Impact(ent, surf, sn, vector_origin, 0.9 * math.sqrt(S), 300 * S * (1 - wet), 0, 0, 1, 1, h.b, { oxy = 0.6 }) end
		end
	end
	HC.stats.bodies = HC.stats.bodies + 1
	return true
end

local PER_FRAME = 4
hook.Add("Think", "ghmpb_history", function()
	if #HC.world == 0 and #HC.bodies == 0 then return end
	if not (G.cv.enable:GetBool() and G.cv_sv_enable:GetBool()) then HC.world, HC.bodies = {}, {} return end
	local t = SysTime()
	local eye = EyePos()
	if #HC.world > PER_FRAME then
		table.sort(HC.world, function(a, b) return a.pos:DistToSqr(eye) > b.pos:DistToSqr(eye) end)
	end
	for _ = 1, PER_FRAME do
		local r = table.remove(HC.world)
		if not r then break end
		local ok, err = pcall(ApplyWorld, r)
		if not ok then G.DiagCount("error: history") G.Diag.lastError = tostring(err) end
	end
	local e = HC.bodies[1]
	if e then
		local ok, done = pcall(ApplyBody, e)
		e.tries = e.tries + 1
		if not ok or done or e.tries > 300 then table.remove(HC.bodies, 1) end
	end
	G.Prof.Lap("history", t)
end)

hook.Add("PostCleanupMap", "ghmpb_history", function() HC.world, HC.bodies = {}, {} end)
