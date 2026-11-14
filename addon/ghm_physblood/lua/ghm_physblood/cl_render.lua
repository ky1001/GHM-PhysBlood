local G = GHMPB
G.Render = G.Render or {}
local R = G.Render
local GPU = G.GPU
local U = G.U

R.ragOf = R.ragOf or {}
R.ragByIdx = R.ragByIdx or {}
R.pendingByIdx = R.pendingByIdx or {}
-- (1.26.8) bodies this client lost lately (index -> blood type, false = does not bleed): a hit that comes after its
-- NPC is gone still throws blood of the right colour
R.goneByIdx = R.goneByIdx or {}
hook.Add("EntityRemoved", "ghmpb_gone", function(ent, fullUpdate)
	if fullUpdate or not IsValid(ent) then return end
	if not (ent:IsNPC() or ent:IsPlayer() or (ent.IsNextBot and ent:IsNextBot())) then return end
	local idx = ent:EntIndex()
	if not idx or idx <= 0 then return end
	local now = CurTime()
	local bt = G.BloodTypeOf(ent)
	R.goneByIdx[idx] = { btype = bt == nil and false or bt, t = now }
	for k, v in pairs(R.goneByIdx) do if now - v.t > 10 then R.goneByIdx[k] = nil end end
end)
-- (1.26.8) an index -> ragdoll link (R.ragByIdx) knows which body it came from and when. The server gives the index of a
-- body that turned into its ragdoll to the next entity it makes, and the link was kept for as long as the corpse lay
-- there: every hit on a new NPC that got that index - and its wounds and bleeding, moved over every frame by E.Update and
-- W.Update - went to the old corpse (GHM: "first few shots DO NOT register on npcs ... some npc at random do not spawn
-- any of the blood and or wounds when shot"). A link now redirects only the body it came from, or, for an index this
-- client has no entity for (a hit that comes while an NPC turns into its ragdoll), only for a few seconds; a new entity
-- taking the index drops it.
R.ragIdxOwner = R.ragIdxOwner or {}
R.ragIdxT = R.ragIdxT or {}
R.IDX_LINK_SECS = 5
local function LinkIdx(idx, rag, owner)
	if not idx or idx <= 0 or not IsValid(rag) then return end
	if IsValid(owner) and owner ~= rag then R.ragIdxOwner[idx] = owner
	elseif R.ragByIdx[idx] ~= rag then R.ragIdxOwner[idx] = false end
	R.ragByIdx[idx] = rag
	R.ragIdxT[idx] = CurTime()
end
local function UnlinkIdx(idx)
	if not idx or idx <= 0 then return end
	R.ragByIdx[idx], R.ragIdxOwner[idx], R.ragIdxT[idx] = nil, nil, nil
end
R.LinkIdx, R.UnlinkIdx = LinkIdx, UnlinkIdx
-- the ragdoll a hit on index idx goes to; ent = the entity this client has at that index now (nil: none)
function R.IdxRag(idx, ent)
	if not idx or idx <= 0 then return nil end
	local rag = R.ragByIdx[idx]
	if not IsValid(rag) then return nil end
	if IsValid(ent) then
		if ent == rag then return nil end
		return R.ragIdxOwner[idx] == ent and rag or nil
	end
	return (CurTime() - (R.ragIdxT[idx] or -math.huge)) < R.IDX_LINK_SECS and rag or nil
end
hook.Add("OnEntityCreated", "ghmpb_idxlink", function(ent)
	if not IsValid(ent) then return end
	local idx = ent:EntIndex()
	if not idx or idx <= 0 or R.ragByIdx[idx] == nil then return end
	if R.ragByIdx[idx] == ent or R.ragIdxOwner[idx] == ent then return end
	UnlinkIdx(idx)
	G.DiagCount("bodies: a new entity took a dead body's index (link dropped)")
end)
R.stats = { readbacks = 0, drips = 0, flows = 0, tiles = 0, ms = 0 }

local function Enabled()
	return G.cv.enable:GetBool() and G.cv_sv_enable:GetBool()
end

local function FindKeyByIndex(tbl, idx)
	if not idx or idx <= 0 then return nil end
	for k, v in pairs(tbl) do if v.entIndex == idx then return k end end
end

local function FlushPending(idx, rag, owner)
	if not idx or idx <= 0 or not IsValid(rag) then return end
	LinkIdx(idx, rag, owner)
	local q = R.pendingByIdx[idx]
	if not q then return end
	R.pendingByIdx[idx] = nil
	local now = CurTime()
	for _, ev in ipairs(q) do
		if now - ev.t < 1.0 then
			if ev.kind == "hit" then
				R.WatchDecals(rag)
				local ok, err = pcall(G.Wounds.OnHit, rag, ev.pos, ev.dir, ev.dmg, ev.dmgtype, ev.hg, ev.fatal,
					IsValid(ev.attacker) and ev.attacker or nil, nil, ev.blastPos, ev.worldDone)
				if not ok then ErrorNoHalt("[GHMPB] OnHit(queued): " .. tostring(err) .. "\n") end
			elseif ev.kind == "death" then
				local ok, err = pcall(G.Wounds.OnDeath, rag, nil, ev.bloodless)
				if not ok then ErrorNoHalt("[GHMPB] OnDeath(queued): " .. tostring(err) .. "\n") end
			end
		end
	end
end

function R.Transfer(from, to, living, fromIdx)
	if not IsValid(to) then return end
	if G.Lite and G.Lite.on and from ~= nil then G.Lite.Transfer(from, to) end
	local moved = false
	if from and G.Entities.domains[from] then moved = G.Entities.Transfer(from, to, living) end
	if not moved and from and G.Wounds.bodies[from] then G.Wounds.OnTransfer(from, to, living) end
	if from and G.Particles and G.Particles.Transfer then G.Particles.Transfer(from, to) end
	if from and G.VAT and G.VAT.Transfer then G.VAT.Transfer(from, to) end
	if from and G.Holes and G.Holes.Transfer then G.Holes.Transfer(from, to) end   -- (1.26.10)
	if from and G.Smear and G.Smear.state and G.Smear.state[from] then
		G.Smear.state[to] = G.Smear.state[from]
		G.Smear.state[from] = nil
	end
	local toRag = to:IsRagdoll()
	local idx = fromIdx
		or (IsValid(from) and from:EntIndex())
		or (from and G.Wounds.bodies[from] and G.Wounds.bodies[from].entIndex)
		or (from and G.Entities.domains[from] and G.Entities.domains[from].entIndex)
	if toRag then
		if from then R.ragOf[from] = to end
		R.ragOf[to] = nil
		if idx and idx > 0 then FlushPending(idx, to, from) end
	else
		if from then R.ragOf[from] = nil end
		R.ragOf[to] = nil
		if idx and idx > 0 then UnlinkIdx(idx) end
		local toIdx = to:EntIndex()
		if toIdx and toIdx > 0 then UnlinkIdx(toIdx) end
	end
end

local function Redirect(ent, idx)
	if IsValid(ent) then
		if G.ZC and G.ZC.HitTarget then
			local t = G.ZC.HitTarget(ent)
			if t ~= ent then return t end
		end
		local rag = R.ragOf[ent]
		if not IsValid(rag) then rag = R.IdxRag(ent:EntIndex(), ent) end
		if not IsValid(rag) and not ent:IsRagdoll() and (ent:GetNoDraw() or (ent:IsPlayer() and not ent:Alive())) then
			local nwRag = ent:GetNW2Entity("endo_rag")
			if IsValid(nwRag) then
				rag = nwRag
				R.ragOf[ent] = rag
				if G.Entities.domains[ent] or G.Wounds.bodies[ent] then
					R.Transfer(ent, rag, G.LivingRagdoll(rag), ent:EntIndex())
				end
			end
		end
		if IsValid(rag) and rag ~= ent and not (ent:IsPlayer() and ent:Alive() and not ent:GetNoDraw()) then return rag end
		return ent
	end
	if idx and idx > 0 then
		local e = Entity(idx)
		local rag = R.IdxRag(idx, IsValid(e) and e or nil)
		if rag then return rag end
		if IsValid(e) then
			local r2 = R.ragOf[e]
			if not IsValid(r2) and not e:IsRagdoll() and (e:GetNoDraw() or (e:IsPlayer() and not e:Alive())) then
				local nwRag = e:GetNW2Entity("endo_rag")
				if IsValid(nwRag) then r2 = nwRag R.ragOf[e] = nwRag end
			end
			if IsValid(r2) then return r2 end
			return e
		end
	end
	return ent
end
R.Redirect = Redirect

local decalWatch = {}
R.decalsRemoved = 0
local function DecalsOff()
	if G.Lite and G.Lite.on then return false end
	return G.cv.nodecals:GetBool() and Enabled() and G.cv_sv_suppress:GetBool()
end
function R.WatchDecals(ent, secs)
	if not IsValid(ent) or not ent.RemoveAllDecals then return end
	local t = RealTime() + (secs or 0.75)
	if (decalWatch[ent] or 0) < t then decalWatch[ent] = t end
end
local decalSweep = 0
hook.Add("PreRender", "ghmpb_decals", function()
	if next(decalWatch) == nil and RealTime() < decalSweep then return end
	local t0 = SysTime()
	if not DecalsOff() then decalWatch = {} decalSweep = RealTime() + 1 return end
	local now = RealTime()
	for ent, t in pairs(decalWatch) do
		if not IsValid(ent) or now > t then decalWatch[ent] = nil
		else ent:RemoveAllDecals() R.decalsRemoved = R.decalsRemoved + 1 end
	end
	if now >= decalSweep then
		decalSweep = now + 1
		for ent in pairs(G.Entities.domains) do if IsValid(ent) and ent.RemoveAllDecals then ent:RemoveAllDecals() end end
		for ent in pairs(G.Wounds.bodies) do if IsValid(ent) and ent.RemoveAllDecals then ent:RemoveAllDecals() end end
	end
	G.Prof.Lap("decals", t0)
end)

net.Receive("ghmpb_hit", function()
	local ent = net.ReadEntity()
	local pos = net.ReadVector()
	local dir = net.ReadNormal()
	local dmg = net.ReadFloat()
	local dmgtype = net.ReadUInt(32)
	local hg = net.ReadUInt(4)
	local fatal = net.ReadBool()
	local attacker = net.ReadEntity()
	local blastPos = net.ReadBool() and net.ReadVector() or nil
	local entIdx = net.BytesLeft() >= 2 and net.ReadUInt(16) or 0
	G.DiagCount("net: hit messages")
	if G.ZC then G.ZC.lastHitT = CurTime() G.ZC.lastHitPos = pos end
	if G.Battle then G.Battle.OnHit() end
	if not Enabled() then G.DiagCount("net: hit ignored (blood switched off)") return end
	R.WatchDecals(ent)
	ent = Redirect(ent, entIdx)
	R.WatchDecals(ent)
	if not IsValid(ent) then
		local worldDone = false
		if pos and pos:DistToSqr(EyePos()) <= (G.LIVE_RANGE + 1500) ^ 2 and (blastPos ~= nil or bit.band(dmgtype or 0, DMG_BLAST) ~= 0) then
			if G.Wounds and G.Wounds.ImmediateBlastWorld then
				pcall(function() worldDone = G.Wounds.ImmediateBlastWorld(pos, dir, dmg, blastPos, 0, nil, fatal) end)
			end
		end
		-- (1.26.8) a bullet that hit a body this client no longer has (an NPC that turned into its ragdoll before the
		-- message came): its blood flies now, from where and the way the server says it hit; the wounds follow on the
		-- ragdoll when it is known (FlushPending)
		if not worldDone and entIdx > 0 and G.Wounds and G.Wounds.ShotWorld and G.Wounds.IsBullet and G.Wounds.IsBullet(dmgtype) then
			local gone = R.goneByIdx[entIdx]
			local bt = G.BLOOD_RED
			if gone and (CurTime() - gone.t) < 5 then bt = gone.btype end
			local ok, res = pcall(G.Wounds.ShotWorld, pos, dir, dmg, dmgtype, hg, IsValid(attacker) and attacker or nil, bt)
			if ok then worldDone = res and true or false else ErrorNoHalt("[GHMPB] ShotWorld: " .. tostring(res) .. "\n") end
			if worldDone then G.DiagCount("net: bullet blood thrown before its body was known") end
		end
		if entIdx > 0 then
			local q = R.pendingByIdx[entIdx] or {}
			q[#q + 1] = { kind = "hit", pos = pos, dir = dir, dmg = dmg, dmgtype = dmgtype, hg = hg, fatal = fatal,
				attacker = attacker, blastPos = blastPos, worldDone = worldDone, t = CurTime() }
			R.pendingByIdx[entIdx] = q
			return
		end
		G.DiagCount("net: hit on an entity this client does not have")
		return
	end
	if ent:GetPos():DistToSqr(EyePos()) > (G.LIVE_RANGE + 1500) ^ 2 then G.DiagCount("net: hit too far away") return end
	local ok, err = pcall(G.Wounds.OnHit, ent, pos, dir, dmg, dmgtype, hg, fatal, IsValid(attacker) and attacker or nil, nil, blastPos)
	if not ok then G.DiagCount("error: OnHit") G.Diag.lastError = tostring(err) ErrorNoHalt("[GHMPB] OnHit: " .. tostring(err) .. "\n") end
end)

net.Receive("ghmpb_death", function()
	local ent = net.ReadEntity()
	local bloodless = net.ReadBool()
	local entIdx = net.BytesLeft() >= 2 and net.ReadUInt(16) or 0
	if not Enabled() then return end
	if G.ZC and G.ZC.OnDeath and G.ZC.OnDeath(ent, bloodless) then return end
	ent = Redirect(ent, entIdx)
	if not IsValid(ent) then
		if entIdx > 0 then
			local q = R.pendingByIdx[entIdx] or {}
			q[#q + 1] = { kind = "death", bloodless = bloodless, t = CurTime() }
			R.pendingByIdx[entIdx] = q
		end
		return
	end
	local ok, err = pcall(G.Wounds.OnDeath, ent, nil, bloodless)
	if not ok then ErrorNoHalt("[GHMPB] OnDeath: " .. tostring(err) .. "\n") end
end)

local function ApplyRagHandover(owner, rag, idx, ragIdx, retry)
	if not IsValid(rag) and ragIdx and ragIdx > 0 then rag = Entity(ragIdx) end
	if not IsValid(rag) or not rag:GetModel() then
		if (retry or 0) < 30 and ragIdx and ragIdx > 0 then
			timer.Simple(0.03, function() ApplyRagHandover(owner, rag, idx, ragIdx, (retry or 0) + 1) end)
		end
		return
	end
	if rag:GetNoDraw() then return end
	R.WatchDecals(rag, 1)
	if idx and idx > 0 then LinkIdx(idx, rag, owner) end
	if IsValid(owner) then R.ragOf[owner] = rag end
	local key = (owner and (G.Entities.domains[owner] or G.Wounds.bodies[owner])) and owner
		or FindKeyByIndex(G.Entities.domains, idx) or FindKeyByIndex(G.Wounds.bodies, idx)
	if key then R.Transfer(key, rag, G.LivingRagdoll(rag), idx) end
	if idx and idx > 0 then FlushPending(idx, rag, owner) end
end

net.Receive("ghmpb_rag", function()
	local owner = net.ReadEntity()
	local rag = net.ReadEntity()
	local idx = net.ReadUInt(16)
	local ragIdx = net.BytesLeft() >= 2 and net.ReadUInt(16) or 0
	ApplyRagHandover(owner, rag, idx, ragIdx, 0)
end)

net.Receive("ghmpb_shot", function()
	local a = net.ReadVector()
	local b = net.ReadVector()
	local dmg = net.ReadFloat()
	local dmgtype = net.ReadUInt(32)
	if not Enabled() or #U.corpses == 0 then return end
	local tr = U.TraceCorpses(a, b)
	if not tr then return end
	local dir = (b - a):GetNormalized()
	R.WatchDecals(tr.Entity)
	local ok, err = pcall(G.Wounds.OnHit, tr.Entity, tr.HitPos, dir, dmg, dmgtype, 0, false)
	if not ok then ErrorNoHalt("[GHMPB] corpse hit: " .. tostring(err) .. "\n") end
end)

hook.Add("CreateClientsideRagdoll", "ghmpb_rag", function(ent, rag)
	if not IsValid(rag) then return end
	local idx = IsValid(ent) and ent:EntIndex() or 0
	if IsValid(ent) then
		local t = G.BloodTypeOf(ent)
		if t == nil then t = false end
		rag.ghmpbType = t
	elseif next(R.pendingByIdx) then
		local rc = rag:WorldSpaceCenter()
		local now = CurTime()
		local bestIdx, bestD2 = 0, 150 * 150
		for pIdx, q in pairs(R.pendingByIdx) do
			for _, ev in ipairs(q) do
				if now - ev.t < 0.6 and ev.pos then
					local d2 = ev.pos:DistToSqr(rc)
					if d2 < bestD2 then bestIdx, bestD2 = pIdx, d2 end
				end
			end
		end
		if bestIdx > 0 then idx = bestIdx end
	end
	R.WatchDecals(rag, 1)
	if idx > 0 then LinkIdx(idx, rag, IsValid(ent) and ent or nil) end
	if IsValid(ent) and (G.Entities.domains[ent] or G.Wounds.bodies[ent]) then
		R.Transfer(ent, rag)
	elseif IsValid(ent) then
		R.ragOf[ent] = rag
	end
	if idx > 0 then FlushPending(idx, rag, IsValid(ent) and ent or nil) end
	U.RefreshCorpses()
end)

local rbNext = 0
local pending = nil
R.RB_DELAY = 1

local function ClearAccumulators(tiles)
	local cleared = {}
	for _, t in ipairs(tiles) do
		local s = t.kind == "entity" and t.sub.slot or (t.kind == "patch" and t.p.slot)
		if s and not cleared[s] then
			cleared[s] = true
			for k = 1, 2 do
				render.PushRenderTarget(s.ac[k])
				render.OverrideAlphaWriteEnable(true, false)
				render.OverrideBlend(true, BLEND_ZERO, BLEND_SRC_COLOR, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
				render.SetMaterial(GPU.Blit())
				GPU.FullQuad(s.ac[k]:Width(), s.ac[k]:Height(), { 0, 0, 1, 1 })
				render.OverrideBlend(false)
				render.OverrideAlphaWriteEnable(false)
				render.PopRenderTarget()
			end
		end
	end
end

local CANARY = { 0.5, 0.25, 0.75, 1 }
R.canaryFails = R.canaryFails or 0
local function CanaryXY() return GPU.READBACK - 1, GPU.READBACK - 2 end
local canaryRT, canaryMat
local function DrawCanary(W)
	if not canaryMat then
		canaryRT = GPU.RT("canary", 4, 4)
		canaryMat = GPU.Mat("canary", "clip_vs30", "peek_ps30", { ["$basetexture"] = canaryRT:GetName(), ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
		GPU.SetC(canaryMat, 0, 1, 1, 1, 1)
		GPU.SetC(canaryMat, 1, 0, 0, 0, 0)
	end
	local cx, cy = CanaryXY()
	render.SetMaterial(canaryMat)
	GPU.Quads(W, W, { { cx, cy, cx + 1, cy + 1, { 0.5, 0.5, 0, 0 } } })
end
function R.Rebuild()
	R.rebuilds = (R.rebuilds or 0) + 1
	R.canaryFails = 0
	pcall(R.ClearAll)
	GPU.session = string.format("%x", math.random(0, 0xFFFFFF))
	GPU.mats = {}
	GPU.matBlit, GPU.matCopyF, GPU.matBake, GPU.matCopy = nil, nil, nil, nil
	G.Surfaces.pool, G.Entities.pool = {}, {}
	G.Entities.staticMats = {}
	for _, list in pairs(GPU.aftPool or {}) do for _, a in ipairs(list) do a.mat = nil end end
	G.Surfaces.slotCount, G.Entities.slotCount = 0, 0
	G.Budget.made.body, G.Budget.made.patch = {}, {}
	if G.Prof then G.Prof.instrumented = false end
	local ok, err = pcall(function()
		for _, f in ipairs(GHMPB.ClientFiles or {}) do include("ghm_physblood/" .. f) end
	end)
	if not ok then G.Diag.lastError = "rebuild: " .. tostring(err) ErrorNoHalt("[GHMPB] rebuild: " .. tostring(err) .. "\n") end
	print("[GHM PhysBlood] the material system was reloaded (video settings changed): blood materials rebuilt")
end
concommand.Add("ghmpb_rebuild", function() R.Rebuild() end, nil, "GHM PhysBlood: make all GPU materials again (blood is cleared)")

local function ReadbackDraw()
	local P = G.Prof
	local t = SysTime()
	local tiles = {}
	local rt = GPU.Readback()
	if canaryRT then GPU.ClearTo(canaryRT, CANARY[1], CANARY[2], CANARY[3], CANARY[4]) end
	render.PushRenderTarget(rt)
	render.Clear(0, 0, 0, 0)
	G.Entities.Reduce(tiles)
	G.Surfaces.Reduce(tiles)
	if G.Surfaces.AlbedoTiles then G.Surfaces.AlbedoTiles(tiles) end
	local probes = G.Smear and G.Smear.DrawProbes()
	local fresh = canaryRT == nil
	DrawCanary(GPU.READBACK)
	render.PopRenderTarget()
	if fresh then GPU.ClearTo(canaryRT, CANARY[1], CANARY[2], CANARY[3], CANARY[4]) R.canarySkip = true end
	ClearAccumulators(tiles)
	P.Lap(".rb reduce draws", t)
	P.Count("rb tiles", #tiles)
	if #tiles > 0 or probes then pending = { tiles = tiles, probes = probes, frame = FrameNumber() } end
end

local function ReadbackRead()
	local pd = pending
	pending = nil
	local P = G.Prof
	local t = SysTime()
	local tiles = pd.tiles
	render.PushRenderTarget(GPU.Readback())
	render.CapturePixels()
	local waited = (SysTime() - t) * 1000
	if G.Gov then G.Gov.rbMs = G.Gov.rbMs * 0.5 + waited * 0.5 end
	t = P.Lap(".rb capture (gpu wait)", t)
	if pd.probes then G.Smear.ReadProbes(pd.probes) end
	do
		local cx, cy = CanaryXY()
		local r, g = render.ReadPixel(cx, cy)
		if R.canarySkip then R.canarySkip = nil
		elseif r and math.abs(r - 128) < 12 and math.abs(g - 64) < 12 then R.canaryFails = 0
		else
			R.canaryFails = R.canaryFails + 1
			G.DiagCount("readback: canary pixel wrong")
			if R.canaryFails == 2 and (R.rebuilds or 0) < 2 then
				timer.Simple(0, R.Rebuild)
			elseif R.canaryFails >= 4 and G.Lite and G.Lite.ForceFallback then
				timer.Simple(0, function() G.Lite.ForceFallback("GPU shader readback inactive") end)
			end
		end
	end
	local drips, flows = 0, 0
	local results = {}
	for _, t in ipairs(tiles) do
		if t.kind == "albedo" then G.Surfaces.AlbedoRead(t) else
		for y = 0, GPU.TILE - 1 do
			for x = 0, GPU.TILE - 1 do
				local r, g, b, a = render.ReadPixel(t.x0 + x, t.y0 + y)
				if r and r > 1 then
					local v = r / 255
					local vol = v * v * t.volNorm
					if vol > 2.5 then results[#results + 1] = { t, vol, g / 255, b / 255, (a or 0) / 255 } end
				end
			end
		end
		end
	end
	render.PopRenderTarget()
	t = P.Lap(".rb read pixels", t)
	for _, res in ipairs(results) do
		local t, vol = res[1], res[2]
		if t.kind == "entity" then
			if IsValid(t.ent) and G.Entities.domains[t.ent] == t.d then
				local d = t.d
				local now = CurTime()
				d.dripTok = math.min(3000, (d.dripTok or 3000) + (now - (d.dripT or now)) * 1500)
				d.dripT = now
				local v = math.min(vol, d.dripTok)
				if v > 2.5 then
					d.dripTok = d.dripTok - v
					local pos = t.origin + t.bmin + Vector(res[3] * t.bsize.x, res[4] * t.bsize.y, res[5] * t.bsize.z)
					local vel = t.ent:GetVelocity() * 0.9 + Vector(0, 0, -6)
					G.Particles.Hang(pos, vel, v, t.ent, d.oxy, G.Smear and G.Smear.TypeAt(d, t.ent, pos) or d.btype)
					drips = drips + 1
				end
			end
		elseif G.Surfaces.patches[t.key] == t.p then
			G.Surfaces.HandleOutflow(t.p, { res[3], res[4] }, vol, res[5])
			flows = flows + 1
		end
	end
	R.stats.readbacks = R.stats.readbacks + 1
	R.stats.drips = R.stats.drips + drips
	R.stats.flows = R.stats.flows + flows
	R.stats.tiles = #tiles
end

R.rbReadAt = "pre"
local function MaybeRead()
	if pending and FrameNumber() - pending.frame >= R.RB_DELAY then
		local ok, err = pcall(ReadbackRead)
		if not ok then pending = nil G.Diag.lastError = tostring(err) ErrorNoHalt("[GHMPB] readback: " .. tostring(err) .. "\n") end
	end
end
hook.Add("PreRender", "ghmpb_readback", function()
	if not Enabled() then return end
	if G.Surfaces and G.Surfaces.FlushPending then
		local t0 = SysTime()
		G.Surfaces.FlushPending()
		G.Prof.Lap("world:gpu", t0)
	end
	if R.rbReadAt ~= "pre" or not pending then return end
	local t = SysTime()
	MaybeRead()
	G.Prof.Lap("readback", t)
end)

local lastT = nil
hook.Add("PostRender", "ghmpb_sim", function()
	if not Enabled() then return end
	G.DiagCount("frames: simulation ran")
	local now = CurTime()
	local dt = lastT and math.Clamp(now - lastT, 0, 0.1) or 0
	lastT = now
	local t0 = SysTime()
	local P = G.Prof
	local ok, err = pcall(function()
		local t = SysTime()
		if G.Gov then G.Gov.Update() end
		G.Wounds.Update() t = P.Lap("wounds", t)
		if G.Smear then G.Smear.Update() end t = P.Lap("smear", t)
		if G.Foot then G.Foot.Update() end t = P.Lap("footprints", t)
		if G.Hands then G.Hands.Update() end t = P.Lap("hands", t)
		if G.Props then G.Props.Update() end t = P.Lap("props", t)
		if G.Tyres then G.Tyres.Update() end t = P.Lap("tyres", t)
		if G.Elem and G.Elem.Update then G.Elem.Update() end t = P.Lap("elements", t)
		if G.Dust then G.Dust.Update() end t = P.Lap("dust", t)
		if G.Flies then G.Flies.Update() end t = P.Lap("flies", t)
		if G.Flesh then G.Flesh.Update() end
		if dt > 0 then
			t = SysTime()
			G.Particles.Step(dt) t = P.Lap("drops", t)
			P.Count("drops flying", G.Particles.Count())
			P.Count("drops hanging", #G.Particles.hang)
			P.Count("drops far (path worked out)", G.Particles.FarCount())
			if G.Runs then G.Runs.Step(dt) end t = P.Lap("runs", t)
			if G.Water then G.Water.Update(dt) end t = P.Lap("water", t)
		end
		if G.Lite and G.Lite.on then
			G.Lite.Update(dt)
			P.Lap("lite", t)
			return
		end
		cam.Start3D(EyePos(), EyeAngles())
		local clip = render.EnableClipping(false)
		local errs = nil
		local function part(fn)
			local rt0 = render.GetRenderTarget()
			local okp, errp = pcall(fn)
			if not okp then
				errs = errs or {} errs[#errs + 1] = tostring(errp)
				for _ = 1, 8 do
					if render.GetRenderTarget() == rt0 then break end
					if not pcall(render.PopRenderTarget) then break end
				end
				for k = 1, 3 do pcall(render.SetRenderTargetEx, k, nil) end
				pcall(render.OverrideAlphaWriteEnable, false)
				pcall(render.OverrideBlend, false)
				pcall(render.MaterialOverrideByIndex)
			end
		end
		local t2 = SysTime()
		part(function() G.Entities.Update(dt) end) t2 = P.Lap("bodies:gpu", t2)
		part(function() G.Surfaces.Update(dt) end) t2 = P.Lap("world:gpu", t2)
		part(function() GPU.UploadMatTable() end)
		if G.Dust then part(function() G.Dust.GpuPass() end) t2 = P.Lap("dust:gpu", t2) end
		part(function()
			if R.rbReadAt ~= "pre" then MaybeRead() end
			if not pending and now >= rbNext then
				rbNext = now + (G.Gov and G.Gov.ReadbackInterval() or 0.3)
				ReadbackDraw()
			end
		end)
		P.Lap("readback", t2)
		render.EnableClipping(clip)
		cam.End3D()
		if errs then error(table.concat(errs, " | "), 0) end
	end)
	if not ok then
		G.DiagCount("error: frame") G.Diag.lastError = tostring(err)
		R.errors = (R.errors or 0) + 1
		if R.errors < 20 then ErrorNoHalt("[GHMPB] frame: " .. tostring(err) .. "\n") end
	end
	R.stats.ms = R.stats.ms * 0.95 + (SysTime() - t0) * 1000 * 0.05
end)

G.viewW, G.viewH = nil, nil
function G.ViewSize() return G.viewW or ScrW(), G.viewH or ScrH() end
local function IsRefraction(rt)
	local n = rt and rt.GetName and string.lower(rt:GetName() or "") or ""
	return string.find(n, "refraction", 1, true) ~= nil
end

local passFrame, passN, lastPassN = -1, 0, 1
local function MainScreenPass()
	local f = FrameNumber()
	if f ~= passFrame then
		if passFrame == f - 1 then lastPassN = math.max(passN, 1) else lastPassN = 1 end
		passFrame, passN = f, 0
	end
	passN = passN + 1
	return passN >= lastPassN
end

local function DrawSplats()
	-- (1.26.7) the Crisis Response splats PhysBlood keeps on the world (cl_splatmesh.lua), in both renderers
	local SMm = G.SplatMesh
	if not SMm or not SMm.Draw then return end
	local t = SysTime()
	local ok, err = pcall(SMm.Draw)
	G.Prof.Lap("draw:splats", t)
	if not ok then
		R.drawErrors = (R.drawErrors or 0) + 1
		if R.drawErrors < 20 then ErrorNoHalt("[GHMPB] splats: " .. tostring(err) .. "\n") end
	end
end
local function DrawLayers(rt, main)
	G.DiagCount("frames: blood drawn")
	if rt == nil then DrawSplats() end
	if G.Lite and G.Lite.on then
		G.viewW, G.viewH, G.refractionView = nil, nil, nil
		if rt ~= nil then return end
		local t = SysTime()
		local okl, errl = pcall(G.Lite.DrawWorld)
		G.Prof.Lap("draw:lite", t)
		if not okl then
			R.drawErrors = (R.drawErrors or 0) + 1
			if R.drawErrors < 20 then ErrorNoHalt("[GHMPB] lite: " .. tostring(errl) .. "\n") end
		end
		return
	end
	-- (1.26.10) bullet holes on bodies (cl_holes.lua), before the blood layers: the blood drawn next runs over them
	if rt == nil and G.Holes and G.Holes.Any() then
		local th = SysTime()
		local okh, errh = pcall(G.Holes.Draw)
		G.Prof.Lap("draw:holes", th)
		if not okh then
			R.drawErrors = (R.drawErrors or 0) + 1
			if R.drawErrors < 20 then ErrorNoHalt("[GHMPB] holes: " .. tostring(errh) .. "\n") end
		end
	end
	local E = G.Entities
	local drawStatic = main and E.DrawStatic or E.RawDrawStatic
	local drawOverlays = main and E.DrawOverlays or E.RawDrawOverlays
	local P = G.Prof
	local ok, err = pcall(function()
		local t = SysTime()
		local D = G.Dust
		if G.Surfaces.HasStatic() or E.HasStatic() then
			render.UpdateScreenEffectTexture()
			R.copyFrame = FrameNumber()
			G.Surfaces.DrawStatic() t = P.Lap("draw:world old", t)
			drawStatic() t = P.Lap("draw:bodies old", t)
			if D and D.Any() then D.DrawStatic() t = P.Lap("draw:dust old", t) end
		end
		-- (1.26.6) the screen copy for the live layers only when there is live blood to draw (it was made every frame,
		-- with no blood anywhere too)
		local liveW = not G.Surfaces.HasLive or G.Surfaces.HasLive()
		local liveB = not E.HasLive or E.HasLive()
		local liveD = D and D.Any()
		if liveW or liveB or liveD then
			render.UpdateScreenEffectTexture()
			R.copyFrame = FrameNumber()
			if liveW then G.Surfaces.DrawOverlays() t = P.Lap("draw:world", t) end
			if liveB then drawOverlays() t = P.Lap("draw:bodies", t) end
			if liveD then D.DrawLive() P.Lap("draw:dust", t) end
		end
	end)
	G.viewW, G.viewH = nil, nil
	G.refractionView = nil
	if not ok then
		G.DiagCount("error: overlays") G.Diag.lastError = tostring(err)
		R.drawErrors = (R.drawErrors or 0) + 1
		if R.drawErrors < 20 then ErrorNoHalt("[GHMPB] overlays: " .. tostring(err) .. "\n") end
	end
end

R.screenDrawn = -1
hook.Add("PostDrawOpaqueRenderables", "ghmpb_draw", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or not Enabled() then return end
	if G.Probes and G.Probes.rendering then return end
	if sky then G.DiagCount("frames: skybox flag on the main view (map with a 2D skybox only)") end
	local rt = render.GetRenderTarget()
	local main = false
	if rt ~= nil then
		if not IsRefraction(rt) then G.DiagCount("frames: other views skipped (water reflection, mirrors, cameras)") return end
		G.DiagCount("frames: blood drawn under water (refraction view)")
		G.viewW, G.viewH = rt:Width(), rt:Height()
		G.refractionView = true
	else
		G.viewW, G.viewH = nil, nil
		main = not (G.Water and G.Water.InWater(EyePos())) or MainScreenPass()
		if not main then G.DiagCount("frames: blood drawn above water, eye under water (refraction pass)") end
		R.screenDrawn = FrameNumber()
	end
	DrawLayers(rt, main)
end)

hook.Add("PostDrawTranslucentRenderables", "ghmpb_drops", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or not Enabled() then return end
	if G.Probes and G.Probes.rendering then return end
	if render.GetRenderTarget() ~= nil then return end
	local f = FrameNumber()
	if R.screenDrawn ~= f then
		R.screenDrawn = f
		G.DiagCount("frames: blood drawn late (the opaque pass did not reach it: another addon's hook returned a value)")
		G.viewW, G.viewH = nil, nil
		DrawLayers(nil, true)
	end
	local V = G.VAT
	if V and V.DrawPass and V.drawnFrame ~= f and V.inst and #V.inst > 0 then
		V.drawnFrame = f
		G.DiagCount("frames: fluid bursts drawn late (the opaque pass did not reach them)")
		V.DrawPass()
	end
	if G.Particles.Count() == 0 and #G.Particles.hang == 0 and (not G.Runs or G.Runs.Count() == 0) then return end
	if not (G.Lite and G.Lite.on) then
		-- (1.26.8) with less detail the drops refract the screen copy the blood layers made this frame: a full-screen copy
		-- less (there were up to three a frame)
		local det = G.Gov and G.Gov.Detail and G.Gov.Detail() or 1
		if R.copyFrame ~= f or det >= 0.6 then
			render.UpdateScreenEffectTexture()
			R.copyFrame = f
		end
	end
	local t = SysTime()
	local ok, err = pcall(G.Particles.Draw)
	G.Prof.Lap("draw:drops", t)
	if not ok then ErrorNoHalt("[GHMPB] drops: " .. tostring(err) .. "\n") end
end)

local nextHouse = 0
local warmNext = 0
hook.Add("Think", "ghmpb_house", function()
	local now = CurTime()
	if R.warm ~= false and Enabled() and IsValid(LocalPlayer()) and now > 1 then
		local ok, made = pcall(function()
			return G.Entities.WarmSlot(3, 6) or G.Surfaces.WarmSlot(36)
		end)
		if not ok or not made then R.warm = false end
	elseif R.warm == false and Enabled() and now >= (R.reserveNext or 0) and not (G.Lite and G.Lite.on) then
		-- (1.26.8) then a few free slots kept made ahead (one at a time, every 0.5 s, not on a frame that made one already)
		R.reserveNext = now + 0.5
		if not G.Budget.MayCreateNow or G.Budget.MayCreateNow() then
			pcall(function() return G.Entities.KeepReserve(1, 2) or G.Surfaces.KeepReserve(4) end)
		end
	end
	if now >= warmNext then
		warmNext = now + 0.25
		if U.ProcessMeshQueue then pcall(U.ProcessMeshQueue) end
	end
	if now < nextHouse then return end
	nextHouse = now + 0.3
	if G.Runs and now > (R.nextPrune or 0) then R.nextPrune = now + 5 G.Runs.Prune() end
	U.RefreshCorpses()
	for k, v in pairs(R.ragOf) do if not IsValid(v) then R.ragOf[k] = nil end end
	for _, ply in ipairs(player.GetAll()) do
		if not ply:Alive() and (G.Entities.domains[ply] or G.Wounds.bodies[ply]) then
			local rag = ply:GetRagdollEntity()
			if IsValid(rag) and rag:GetModel() == ply:GetModel() then R.Transfer(ply, rag) end
		end
	end
end)

function R.ClearAll()
	G.Particles.Clear()
	G.Entities.Clear()
	G.Surfaces.Clear()
	G.Wounds.Clear()
	if G.Runs then G.Runs.Clear() end
	if G.Tendrils then G.Tendrils.Clear() end
	if G.Blades then G.Blades.Clear() end
	if G.Water then G.Water.Clear() end
	if G.Smear then G.Smear.Clear() end
	if G.Foot then G.Foot.Clear() end
	if G.Elem and G.Elem.Clear then G.Elem.Clear() end
	if G.Dust then G.Dust.Clear() end
	if G.Flies then G.Flies.Clear() end
	if G.Hands then G.Hands.Clear() end
	if G.Props then G.Props.Clear() end
	if G.Tyres then G.Tyres.Clear() end
	if G.Flesh then G.Flesh.Clear() end
	if G.Contact then G.Contact.Clear() end
	if G.Lite and G.Lite.Clear then G.Lite.Clear() end
	if G.VAT and G.VAT.Clear then G.VAT.Clear() end
	if G.Streams and G.Streams.Clear then G.Streams.Clear() end
	if G.SplatMesh and G.SplatMesh.Clear then G.SplatMesh.Clear() end
	if G.Holes and G.Holes.Clear then G.Holes.Clear() end
	if G.Screen and G.Screen.Clear then G.Screen.Clear() end
	R.ragOf = {}
end

hook.Add("PostCleanupMap", "ghmpb_clear", function() R.ClearAll() end)
cvars.AddChangeCallback("ghmpb_enable", function(_, _, new) if tonumber(new) == 0 then R.ClearAll() end end, "ghmpb_render")
cvars.AddChangeCallback("ghmpb_quality", function() R.ClearAll() end, "ghmpb_render")
concommand.Add("ghmpb_clear", function()
	R.ClearAll()
	-- (1.26.7) the Crisis Response Blood splats laid as engine decals (on props, or with ghmpb_splat_mesh 0): cleared with
	-- the game's own decals
	if G.Forensic and G.Forensic.crbStats and (G.Forensic.crbStats.decals or 0) > 0 then pcall(RunConsoleCommand, "r_cleardecals") end
end, nil, "GHM PhysBlood: remove all blood")
function R.ClearAftermath()
	G.Surfaces.ClearAftermath()
	G.Entities.ClearAftermath()
end
concommand.Add("ghmpb_clear_aftermath", function() R.ClearAftermath() end, nil, "GHM PhysBlood: remove the baked (old) blood, keep fresh blood")
cvars.AddChangeCallback("ghmpb_aftermath", function(_, _, new) if tonumber(new) == 0 then R.ClearAftermath() end end, "ghmpb_render")

G.Native.Load()
G.Prof.Instrument()
