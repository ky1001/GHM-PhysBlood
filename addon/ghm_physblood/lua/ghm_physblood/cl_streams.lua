-- GHM PhysBlood 1.26.7: continuous blood streams (Claude, Cowork chat, 2026-10-27).
-- Arterial jets, the spurts after a gunshot and a wound pouring off a body are drawn as one continuous liquid stream as
-- well as their drops: a 3D tube (the same wet fluid material as the VAT bursts) through the path the blood takes from the
-- wound. It follows the wound as the body moves (it is fed from the emitter every frame), falls under gravity, ripples
-- and thins along its length (Rayleigh-Plateau) and breaks off after a short length - the drops fly on from there and do
-- the landing, the stains and the pools. When the feed stops (between heartbeats, after a spurt) the stream comes loose
-- from the wound and flies off as one piece. Purely visual: no blood volume is taken here.
-- GHM's Universal Directional Blood does the same idea with a stream anchored to the wound's bone, on every hit and on
-- the ragdoll after death (bloodstream.lua).
GHMPB = GHMPB or {}
local G = GHMPB
local St = {}
G.Streams = St

local cvOn = CreateClientConVar("ghmpb_streams", "1", true, false, "GHM PhysBlood: draw arterial jets, gunshot spurts and pouring wounds as continuous 3D streams (the drops still fly)", 0, 1)
St.cvOn = cvOn

local MAX_STREAMS = 14
local MAX_SAMPLES = 26
local SIDES = 6
local SAMPLE_DT = 1 / 90
-- (1.26.8) what the streams may cost (players: "laggy since the update, fighting loads of NPCs, even on low"): the
-- number of streams and the faces drawn a frame follow the quality setting, the frame rate and the size of the fight
-- (cl_governor.lua V.Detail); only streams in view and within reach are drawn, nearest first; near ones (up to 350 u) as
-- full tubes, the others as a half tube turned to the camera (2 faces round instead of 6), every second ring past 900 u;
-- quads instead of triangles (4 vertices a face instead of 6). 1.26.7 drew up to 14 streams x 25 rings x 6 sides as
-- triangles every frame, about 12 600 vertices built in Lua; now at most 700 faces (2 800 vertices) on Ultra.
local QUAD_BUDGET = 700
local DRAW_DIST = 2500
local TUBE_DIST = 350
local function Detail()
	if G.Gov and G.Gov.Detail then return G.Gov.Detail() end
	return 1, 0
end
St.QUAD_BUDGET, St.DRAW_DIST = QUAD_BUDGET, DRAW_DIST
St.list = St.list or {}       -- emitter table -> stream
St.stats = St.stats or { streams = 0, samples = 0, drawn = 0, tris = 0, fed = 0 }

local function now() return CurTime() end

function St.On()
	return cvOn:GetBool() and G.cv.enable:GetBool() and G.VAT ~= nil and G.VAT.Mat ~= nil
end

local function Count()
	local c = 0
	for _ in pairs(St.list) do c = c + 1 end
	return c
end

-- feed: key = the emitter (any table); src() gives the wound's position and the velocity of the blood leaving it (asked
-- every frame while the feed holds, so the stream stays on a moving wound between the wound ticks); hold = how long this
-- feed lasts (s); k = thickness (1 = an artery)
local function Lay(s, t, pos, vel, attached)
	local pts = s.pts
	local head = pts[#pts]
	if attached and head and not head.loose and t - s.lastSample < SAMPLE_DT then
		head.x, head.y, head.z = pos.x, pos.y, pos.z
		head.vx, head.vy, head.vz = vel.x, vel.y, vel.z
		return
	end
	if head and not attached then head.loose = true end
	pts[#pts + 1] = { x = pos.x, y = pos.y, z = pos.z, vx = vel.x, vy = vel.y, vz = vel.z, t = t, sp = vel:Length(), first = not attached }
	s.lastSample = t
	if #pts > MAX_SAMPLES then table.remove(pts, 1) end
end

function St.Feed(key, src, btype, ent, k, hold)
	if not St.On() or not key or not src then return end
	local t = now()
	local s = St.list[key]
	if not s then
		-- (1.26.8) no new stream out of reach or out of view, and fewer of them with less detail
		local p0 = src()
		local eye = EyePos and EyePos()
		if p0 and eye then
			local d2 = p0:DistToSqr(eye)
			if d2 > DRAW_DIST * DRAW_DIST then return end
			if d2 > 160 * 160 and G.U and G.U.InViewPos and not G.U.InViewPos(p0, 80) then return end
		end
		local cap = math.max(3, math.floor(MAX_STREAMS * Detail() + 0.5))
		if Count() >= cap then
			-- the oldest loose stream goes first
			local worst, wt = nil, math.huge
			for kk, ss in pairs(St.list) do
				if ss.feedUntil < wt then worst, wt = kk, ss.feedUntil end
			end
			if worst and wt < t then St.list[worst] = nil else return end
		end
		s = { pts = {}, btype = btype or 0, ent = ent, k = k or 1, feedUntil = 0, lastSample = 0, phase = math.random() * 6.283 }
		St.list[key] = s
	end
	local attached = t <= s.feedUntil
	s.btype, s.ent, s.k, s.src = btype or s.btype, ent, k or s.k, src
	s.feedUntil = math.max(s.feedUntil, t + math.Clamp(hold or 0.06, 0.02, 0.4))
	St.stats.fed = St.stats.fed + 1
	local pos, vel = src()
	if pos and vel then Lay(s, t, pos, vel, attached) end
end

local tr = { mask = MASK_SOLID_BRUSHONLY, output = {} }
local function BreakAge(sp, k)
	-- a fast thin jet holds together for a shorter time than a slow thick pour
	return math.Clamp(0.05 + 9 / math.max(sp, 20) * (0.6 + 0.4 * k), 0.07, 0.24)
end

function St.Update(dt)
	if dt <= 0 then return end
	local t = now()
	local g = -(GetConVarNumber and GetConVarNumber("sv_gravity") or 600)
	local nS, nP = 0, 0
	for key, s in pairs(St.list) do
		local pts = s.pts
		local attached = t <= s.feedUntil and s.src ~= nil
		if attached then
			local ok, pos, vel = pcall(s.src)
			if ok and pos and vel then Lay(s, t, pos, vel, true) else attached = false s.src = nil end
		elseif s.src then
			s.src = nil
			if pts[#pts] then pts[#pts].loose = true end
		end
		local drag = math.exp(-0.35 * dt)
		for i = #pts, 1, -1 do
			local p = pts[i]
			local isHead = attached and i == #pts
			if not isHead then
				p.vz = p.vz + g * dt
				p.vx, p.vy, p.vz = p.vx * drag, p.vy * drag, p.vz * drag
				p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
			end
			if t - p.t > BreakAge(p.sp, s.k) then
				-- broken up into drops from here on: this sample and everything older goes
				for j = i, 1, -1 do table.remove(pts, j) end
				break
			end
		end
		-- the front of the stream stops where it reaches the floor, a wall or another solid prop, feeding live pools & ripples
		local f = pts[1]
		if f and #pts >= 2 and util and util.TraceLine then
			local nx = pts[2]
			tr.mask = MASK_SOLID
			tr.filter = s.ent
			tr.start = Vector(nx.x, nx.y, nx.z)
			tr.endpos = Vector(f.x, f.y, f.z)
			local r = util.TraceLine(tr)
			if r and r.Hit and not r.StartSolid then
				if not r.HitSky and G.Surfaces and G.Surfaces.Impact then
					local vx, vy, vz = f.vx or 0, f.vy or 0, f.vz or -120
					local vn = r.HitNormal
					if r.Entity and IsValid(r.Entity) and (r.Entity:IsNPC() or r.Entity:IsPlayer() or r.Entity:IsRagdoll()) then
						if G.Entities and G.Entities.Impact and t >= (s.entImpT or 0) then
							s.entImpT = t + 0.08
							G.Entities.Impact(r.Entity, r.HitPos, vn, Vector(vx, vy, vz), 0.36 * (s.k or 1), 9 * (s.k or 1),
								0, 0, 1.25, 0.15, nil, { btype = s.btype or 0, oxy = 0.95 })
						end
					elseif (not r.Entity or r.Entity:IsWorld()) and t >= (s.surfImpT or 0) then
						s.surfImpT = t + 0.065
						local vVec = Vector(vx, vy, vz)
						local tang = vVec - vn * vVec:Dot(vn)
						local impVel = tang:LengthSqr() > 4 and tang or vVec
						local vol = math.Clamp(11 * (s.k or 1), 4, 28)
						G.Surfaces.Impact(r.HitPos, vn, impVel * 0.55, math.Clamp(0.55 * (s.k or 1), 0.3, 1.1), vol, 1, 0, 1.15, 0.08, r, 0.95, s.btype or 0)
						if vn.z > 0.7 and G.Surfaces.WellWave and t >= (s.waveT or 0) then
							s.waveT = t + 0.085
							G.Surfaces.WellWave(r.HitPos, math.Clamp(0.42 * (s.k or 1), 0.2, 1.0))
						end
					end
				end
				table.remove(pts, 1)
			end
		end
		if #pts == 0 or (not attached and t - s.feedUntil > 0.5) then
			St.list[key] = nil
		else
			nS, nP = nS + 1, nP + #pts
		end
	end
	St.stats.streams, St.stats.samples = nS, nP
end

-- drawing: a tube of SIDES faces through the samples
local vp, vn, vt, vb = Vector(), Vector(), Vector(), Vector()
local cosT, sinT = {}, {}
for i = 0, SIDES do cosT[i] = math.cos(i / SIDES * 2 * math.pi) sinT[i] = math.sin(i / SIDES * 2 * math.pi) end

-- (1.26.8) the rings' tables are kept and used again every frame (a new table for every ring of every stream, every
-- frame, was about 100 KB of garbage a frame with a few bodies bleeding)
local ringPool, ringUsed = {}, 0
local function NewRing()
	ringUsed = ringUsed + 1
	local R = ringPool[ringUsed]
	if not R then R = {} ringPool[ringUsed] = R end
	return R
end

-- the tube's rings, newest (at the wound) first; a stream that came loose and started again is two pieces
local function Rings(s, base, t, eye)
	local pts = s.pts
	local n = #pts
	local pieces = {}
	if n < 2 then return pieces end
	local k = s.k or 1
	local rings
	local ux, uy, uz            -- a side vector carried along the tube (parallel transport)
	local lo = n                -- the newest sample of the current piece
	for i = n, 1, -1 do
		local p = pts[i]
		if not rings then rings, ux, lo = {}, nil, i end
		-- direction along the flow (from the wound outwards), from the piece's own neighbours (not across a break)
		local older = (i > 1 and not p.first) and pts[i - 1] or p
		local newer = (i < lo) and pts[i + 1] or p
		local tx, ty, tz = older.x - newer.x, older.y - newer.y, older.z - newer.z
		local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
		if tl < 1e-5 then tx, ty, tz, tl = p.vx, p.vy, p.vz, math.sqrt(p.vx * p.vx + p.vy * p.vy + p.vz * p.vz) end
		if tl < 1e-5 then tx, ty, tz, tl = 0, 0, -1, 1 end
		tx, ty, tz = tx / tl, ty / tl, tz / tl
		if not ux then
			-- first side vector: across the stream, facing the camera
			local cx, cy, cz = eye.x - p.x, eye.y - p.y, eye.z - p.z
			ux, uy, uz = ty * cz - tz * cy, tz * cx - tx * cz, tx * cy - ty * cx
		else
			local d = ux * tx + uy * ty + uz * tz
			ux, uy, uz = ux - tx * d, uy - ty * d, uz - tz * d
		end
		local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
		if ul < 1e-5 then
			if math.abs(tz) < 0.9 then ux, uy, uz = -ty, tx, 0 else ux, uy, uz = 1, 0, 0 end
			ul = math.sqrt(ux * ux + uy * uy + uz * uz)
		end
		ux, uy, uz = ux / ul, uy / ul, uz / ul
		local wx, wy, wz = ty * uz - tz * uy, tz * ux - tx * uz, tx * uy - ty * ux
		-- radius: thins and ripples (varicose waves grow along the jet) towards where it breaks up
		local age = t - p.t
		local f = math.Clamp(age / BreakAge(p.sp, k), 0, 1)
		local ripple = 1 + 0.32 * f * math.sin(s.phase + age * 95 + i * 1.7)
		local r = base * k * (1 - 0.45 * f) * ripple
		local endOfPiece = (i == 1) or p.first
		if endOfPiece then r = r * 0.55 end      -- the loose front and a fresh start are rounded off
		local R = NewRing()
		R.x, R.y, R.z, R.ux, R.uy, R.uz, R.wx, R.wy, R.wz, R.tx, R.ty, R.tz, R.r, R.v = p.x, p.y, p.z, ux, uy, uz, wx, wy, wz, tx, ty, tz, r, age * 6
		rings[#rings + 1] = R
		if endOfPiece then
			if #rings >= 2 then pieces[#pieces + 1] = rings end
			rings = nil
		end
	end
	return pieces
end

-- the rings of a piece with every second one left out (the first and the last stay)
local function Decimate(rings, step)
	if step <= 1 or #rings <= 3 then return rings end
	local out = {}
	for i = 1, #rings, step do out[#out + 1] = rings[i] end
	if out[#out] ~= rings[#rings] then out[#out + 1] = rings[#rings] end
	return out
end

-- the side directions of a ring: a full tube (SIDES round) or a half tube facing the camera (3 directions: one side,
-- towards the camera, the other side - the normals round it so it still reads as a round stream)
local HALF_C, HALF_S = { [0] = 1, 0, -1 }, { [0] = 0, 1, 0 }
local function RingDirs(R, half, eye)
	if not half then return cosT, sinT, SIDES end
	-- turn the ring's frame so its w axis faces the camera
	local cx, cy, cz = eye.x - R.x, eye.y - R.y, eye.z - R.z
	local d = cx * R.tx + cy * R.ty + cz * R.tz
	cx, cy, cz = cx - R.tx * d, cy - R.ty * d, cz - R.tz * d
	local l = math.sqrt(cx * cx + cy * cy + cz * cz)
	if l > 1e-5 then
		cx, cy, cz = cx / l, cy / l, cz / l
		R.wx, R.wy, R.wz = cx, cy, cz
		R.ux, R.uy, R.uz = R.ty * cz - R.tz * cy, R.tz * cx - R.tx * cz, R.tx * cy - R.ty * cx
	end
	return HALF_C, HALF_S, 2
end

function St.Draw()
	if not St.On() or next(St.list) == nil then return end
	local V = G.VAT
	local eye = EyePos()
	local t = now()
	local size = (G.VAT.cvSize and G.VAT.cvSize:GetFloat()) or 1
	local base = 0.2 * size
	-- (1.26.8, second pass) steeper with less detail: 700 faces on Ultra, 60 in a big fight (175 before; ghmpb_prof: the
	-- streams' drawing 0.55-1.2 ms a frame with a few bodies bleeding, about 11 engine calls a vertex)
	local det = Detail()
	local budget = math.max(60, math.floor(QUAD_BUDGET * det * det))
	ringUsed = 0
	-- the streams in view, nearest first
	local order = {}
	local InV = G.U and G.U.InViewPos
	for _, s in pairs(St.list) do
		local h = s.pts[#s.pts]
		if h and #s.pts >= 2 then
			local dx, dy, dz = h.x - eye.x, h.y - eye.y, h.z - eye.z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 < DRAW_DIST * DRAW_DIST and (d2 < 120 * 120 or not InV or InV(Vector(h.x, h.y, h.z), 60)) then
				order[#order + 1] = { s = s, d2 = d2 }
			end
		end
	end
	if #order == 0 then return end
	table.sort(order, function(a, b) return a.d2 < b.d2 end)
	local byType, quads = {}, 0
	for _, o in ipairs(order) do
		if quads >= budget then break end
		local d = math.sqrt(o.d2)
		local half = d > TUBE_DIST
		local step = d > 900 and 2 or 1
		local sides = half and 2 or SIDES
		for _, rings in ipairs(Rings(o.s, base, t, eye)) do
			rings = Decimate(rings, step)
			local q = (#rings - 1) * sides
			if q > 0 and quads + q <= budget then
				local bt = o.s.btype or 0
				byType[bt] = byType[bt] or {}
				table.insert(byType[bt], { rings = rings, half = half })
				quads = quads + q
			end
		end
	end
	if quads == 0 then return end
	local mPos, mNrm, mTC, mAdv = mesh.Position, mesh.Normal, mesh.TexCoord, mesh.AdvanceVertex
	local mTS, mTT, mUD = mesh.TangentS, mesh.TangentT, mesh.UserData
	render.SuppressEngineLighting(true)
	local drawn = 0
	local ok, err = pcall(function()
		for bt, list in pairs(byType) do
			-- light: where the nearest stream of this type is
			local r0 = list[1].rings[1]
			if V.ApplyLight then V.ApplyLight("streams", Vector(r0.x, r0.y, r0.z)) end
			-- (1.26.10c: a stream is thick blood - the colour of a 5 mm chord of it)
			render.SetMaterial(V.Mat(bt, 5.0))
			local nq = 0
			for _, piece in ipairs(list) do nq = nq + (#piece.rings - 1) * (piece.half and 2 or SIDES) end
			mesh.Begin(MATERIAL_QUADS, nq)
			local function vert(R, C, S, j, uCoord)
				local c, sn = C[j], S[j]
				local nx, ny, nz = R.ux * c + R.wx * sn, R.uy * c + R.wy * sn, R.uz * c + R.wz * sn
				vp:SetUnpacked(R.x + nx * R.r, R.y + ny * R.r, R.z + nz * R.r)
				vn:SetUnpacked(nx, ny, nz)
				mPos(vp) mNrm(vn) mTC(0, uCoord, R.v)
				if mTS then
					vt:SetUnpacked(R.tx, R.ty, R.tz)
					vb:SetUnpacked(ny * R.tz - nz * R.ty, nz * R.tx - nx * R.tz, nx * R.ty - ny * R.tx)
					mTS(vt) mTT(vb)
				end
				if mUD then mUD(R.tx, R.ty, R.tz, 1) end
				mAdv()
			end
			for _, piece in ipairs(list) do
				local rings, half = piece.rings, piece.half
				local sides = half and 2 or SIDES
				local CA, SA = RingDirs(rings[1], half, eye)
				for i = 1, #rings - 1 do
					local A, B = rings[i], rings[i + 1]
					local CB, SB = RingDirs(B, half, eye)
					for j = 0, sides - 1 do
						local u0, u1 = j / sides, (j + 1) / sides
						vert(A, CA, SA, j, u0) vert(B, CB, SB, j, u0) vert(B, CB, SB, j + 1, u1) vert(A, CA, SA, j + 1, u1)
					end
					CA, SA = CB, SB
				end
				drawn = drawn + 1
			end
			mesh.End()
		end
	end)
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
	St.stats.drawn, St.stats.tris = drawn, quads * 2
	if not ok then ErrorNoHalt("[GHMPB] streams: " .. tostring(err) .. "\n") end
end

function St.Clear() St.list = {} end

hook.Add("Think", "ghmpb_streams", function()
	if next(St.list) == nil then return end
	local t = SysTime()
	St.Update(FrameTime and FrameTime() or 0.016)
	-- (1.26.8) counted in PhysBlood's own time, so the adaptive quality sees what the streams cost
	if G.Prof and G.Prof.Lap then G.Prof.Lap("streams", t) end
end)

hook.Add("PostDrawOpaqueRenderables", "ghmpb_streams", function(depth, sky, sky3d)
	if next(St.list) == nil then return end
	if G.ScenePass and not G.ScenePass(depth, sky, sky3d) then return end
	if render.GetRenderTarget() ~= nil then return end
	local t = SysTime()
	St.Draw()
	if G.Prof and G.Prof.Lap then G.Prof.Lap("draw:streams", t) end
end)

cvars.AddChangeCallback("ghmpb_streams", function(_, _, new)
	if tonumber(new) == 0 then St.Clear() end
end, "ghmpb_streams")
