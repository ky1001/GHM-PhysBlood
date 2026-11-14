local G = GHMPB
G.Debug = G.Debug or {}
local D = G.Debug
local GPU = G.GPU

local peekMat, peekRT
function D.Peek(rt, uvs, scale, offset)
	if G.Lite and G.Lite.on then return {} end
	if not peekMat then
		peekMat = GPU.Mat("peek", "clip_vs30", "peek_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4 })
		peekRT = GPU.RT("peekrt", 64, 1, GPU.FMT_RGBA8)
	end
	scale = scale or 1 offset = offset or 0
	peekMat:SetTexture("$basetexture", rt)
	GPU.SetC(peekMat, 0, scale, scale, scale, scale)
	GPU.SetC(peekMat, 1, offset, offset, offset, offset)
	local quads = {}
	for k, uv in ipairs(uvs) do
		if k > 64 then break end
		quads[#quads + 1] = { k - 1, 0, k, 1, { uv[1], uv[2], 0, 0 } }
	end
	local out = {}
	render.PushRenderTarget(peekRT)
	render.Clear(0, 0, 0, 0)
	render.SetMaterial(peekMat)
	GPU.Quads(64, 1, quads)
	render.CapturePixels()
	for k = 1, #quads do
		local r, g, b, a = render.ReadPixel(k - 1, 0)
		local function dec(c) return c and ((c / 255 - offset) / scale) or nil end
		out[k] = { dec(r), dec(g), dec(b), dec(a) }
	end
	render.PopRenderTarget()
	return out
end

function D.Scan(rt, n, scale, offset)
	n = n or 8
	local uvs = {}
	for y = 0, n - 1 do for x = 0, n - 1 do uvs[#uvs + 1] = { (x + 0.5) / n, (y + 0.5) / n } end end
	local mx = { -math.huge, -math.huge, -math.huge, -math.huge }
	local i = 1
	while i <= #uvs do
		local chunk = {}
		for k = i, math.min(i + 63, #uvs) do chunk[#chunk + 1] = uvs[k] end
		local v = D.Peek(rt, chunk, scale, offset)
		for _, c in ipairs(v) do for ch = 1, 4 do if c[ch] and c[ch] > mx[ch] then mx[ch] = c[ch] end end end
		i = i + 64
	end
	return mx
end

local function CountT(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local viewMats = {}
local function ViewMat(rt)
	local name = rt:GetName()
	local m = viewMats[name]
	if not m then
		m = G.GPU.CreateMat("view_" .. name, "UnlitGeneric", { ["$basetexture"] = name, ["$translucent"] = 0, ["$ignorez"] = 1 })
		viewMats[name] = m
	end
	return m
end

hook.Add("HUDPaint", "ghmpb_debug", function()
	local lvl = G.cv.debug:GetInt()
	if lvl <= 0 then return end
	local st = G.Render.stats
	local lines = {
		string.format("GHM PhysBlood %s  shaders %s  native %s", G.Version or "?", G.ShaderPrefix or "?", G.Native.Available() and "C++" or "Lua"),
		(function()
			local live, aft = 0, 0
			for _, d in pairs(G.Entities.domains) do
				if G.Entities.IsLive(d) then live = live + 1 end
				if G.Entities.HasAft(d) then aft = aft + 1 end
			end
			local pl, pa = G.Surfaces.Counts()
			return string.format("models live %d / baked %d   patches live %d / aftermath %d   bodies %d  drops %d",
				live, aft, pl, pa, CountT(G.Wounds.bodies), G.Particles.Count())
		end)(),
		string.format("cpu %.2f ms/frame  readbacks %d  tiles %d  drips %d  flows %d  corpses %d", st.ms, st.readbacks, st.tiles, st.drips, st.flows, #G.U.corpses),
		string.format("smears %d  pushes %d  pickups %d  probes %d   footprints %d  soles loaded %d", G.Smear.stats.smears, G.Smear.stats.pushes,
			G.Smear.stats.pickups, G.Smear.stats.probes, G.Foot and G.Foot.stats.prints or 0, G.Foot and G.Foot.stats.pickups or 0),
		G.Hands and string.format("hand prints %d  finger streaks %d   props: smears %d  soaks %d  splashes %d   tyres: prints %d  skids %d",
			G.Hands.stats.prints, G.Hands.stats.drags, G.Props.stats.smears, G.Props.stats.soaks, G.Contact.stats.splashes,
			G.Tyres.stats.prints, G.Tyres.stats.skids) or "",
		string.format("errors: frame %d  draw %d   video memory: allocated %d MB, full use %d of %d MB, style %s", G.Render.errors or 0,
			G.Render.drawErrors or 0, G.Budget.Allocated(), G.Budget.Caps().needMB, G.Budget.Caps().budgetMB, G.cv.style:GetString()),
	}
	local y = 80
	for _, l in ipairs(lines) do
		draw.SimpleTextOutlined(l, "DermaDefault", 20, y, color_white, 0, 0, 1, color_black)
		y = y + 14
	end
	if lvl == 2 then
		local tr = LocalPlayer():GetEyeTrace()
		local d = IsValid(tr.Entity) and G.Entities.Get(tr.Entity, false)
		local x = 20
		if d and d.subs then
			for _, sub in ipairs(d.subs) do
				local s = sub.slot
				if s then
					render.SetMaterial(ViewMat(s.st[sub.cur]))
					render.DrawScreenQuadEx(x, y + 10, 256, 256)
					render.SetMaterial(ViewMat(s.force))
					render.DrawScreenQuadEx(x, y + 270, 256, 256)
				elseif sub.aft then
					render.SetMaterial(ViewMat(sub.aft.rt))
					render.DrawScreenQuadEx(x, y + 10, 256, 256)
				end
				draw.SimpleTextOutlined(sub.path .. " (" .. sub.kind .. (s and ")" or ", baked)"), "DermaDefault", x, y, color_white, 0, 0, 1, color_black)
				x = x + 262
			end
		else
			local p = G.Surfaces.GetPatch(tr.HitPos, tr.HitNormal, false)
			if p and p.slot then
				render.SetMaterial(ViewMat(p.slot.st[p.cur]))
				render.DrawScreenQuadEx(x, y + 10, 256, 256)
				render.SetMaterial(ViewMat(p.slot.force))
				render.DrawScreenQuadEx(x + 262, y + 10, 256, 256)
				draw.SimpleTextOutlined("patch " .. p.key .. " (" .. p.surfName .. ")", "DermaDefault", x, y, color_white, 0, 0, 1, color_black)
			end
		end
	end
end)

local REGIONS = { head = "ValveBiped.Bip01_Head1", neck = "ValveBiped.Bip01_Neck1", chest = "ValveBiped.Bip01_Spine2",
	abdomen = "ValveBiped.Bip01_Spine", thigh = "ValveBiped.Bip01_R_Thigh", arm = "ValveBiped.Bip01_L_UpperArm" }

concommand.Add("ghmpb_test_wound", function(ply, _, args)
	local tr = ply:GetEyeTrace()
	local ent = tr.Entity
	if not IsValid(ent) then print("[GHMPB] look at a model") return end
	local dmg = tonumber(args[1]) or 30
	local pos, dir = tr.HitPos, tr.Normal
	if args[2] and REGIONS[args[2]] then
		local b = ent:LookupBone(REGIONS[args[2]])
		if b then
			local m = ent:GetBoneMatrix(b)
			if m then pos = m:GetTranslation() dir = (pos - ply:EyePos()):GetNormalized() end
		end
	end
	G.Wounds.OnHit(ent, pos, dir, dmg, DMG_BULLET, 0, args[3] == "fatal")
end)

concommand.Add("ghmpb_test_kill", function(ply)
	local ent = ply:GetEyeTrace().Entity
	if IsValid(ent) then G.Wounds.OnDeath(ent, G.Anatomy.CHEST) end
end)

concommand.Add("ghmpb_test_spray", function(ply, _, args)
	G.Particles.Spray({ pos = ply:EyePos() + ply:GetAimVector() * 20, dir = ply:GetAimVector(), cone = 0.2,
		count = tonumber(args[1]) or 40, speedMin = 250, speedMax = 600, r0 = 0.6, spread = 0.7, oxy = 0.8, btype = tonumber(args[2]) or 0,
		stretch = 1.5, spin = 20, mist = 0.5 })
end)

concommand.Add("ghmpb_test_pour", function(ply, _, args)
	local tr = ply:GetEyeTrace()
	local ml = tonumber(args[1]) or 60
	local bt = math.Clamp(math.floor(tonumber(args[2]) or 0), 0, 3)
	if IsValid(tr.Entity) and not tr.Entity:IsWorld() then
		G.Entities.Impact(tr.Entity, tr.HitPos, tr.HitNormal, vector_origin, 0.8, ml * 1000, 1, 0, 1, 0, nil, { btype = bt })
	else
		G.Surfaces.Impact(tr.HitPos, tr.HitNormal, vector_origin, 1.2, ml * 1000, 1, 0, 1, 0, tr, 0.7, bt)
	end
end)

concommand.Add("ghmpb_uvcheck", function(ply)
	local ent = IsValid(ply) and ply:GetEyeTrace().Entity
	if not IsValid(ent) or not ent:GetModel() then print("[GHMPB] uvcheck: look at a model") return end
	G.Entities.modelInfo[ent:GetModel()] = nil
	local mi = G.Entities.ModelInfo(ent)
	print("[GHMPB] uvcheck", ent:GetModel(), "uv_mirror", G.cv.uvmirror:GetInt())
	for _, s in ipairs(mi and mi.subs or {}) do
		print(string.format("    %-48s %-6s mirrored %-5s overlap %3d %%", s.path, s.kind, tostring(s.mirror), math.floor((s.mirrorShare or 0) * 100 + 0.5)))
	end
end)

concommand.Add("ghmpb_dump", function()
	for ent, d in pairs(G.Entities.domains) do
		print("[GHMPB] domain", ent, d.model, "subs", #d.subs, "wet", math.Round(d.wetUntil - CurTime(), 1), "oxy", math.Round(d.oxy, 2))
		for _, s in ipairs(d.subs) do print("   ", s.index, s.path, s.kind, s.size, "blood", s.hasBlood, "half", s.hand or 0) end
	end
	for key, p in pairs(G.Surfaces.patches) do
		local al = p.albedo or vector_origin
		print("[GHMPB] patch", key, p.surfName, "blood", p.hasBlood, "wet", math.Round(p.wetUntil - CurTime(), 1),
			"albedo", string.format("%.2f %.2f %.2f", al.x, al.y, al.z), p.albedoTex)
	end
	for key, a in pairs(G.Surfaces.after) do
		print("[GHMPB] aftermath", key, a.surfName, "res", a.aft and a.aft.res, "age", math.Round(CurTime() - a.bakedAt))
	end
	for ent, b in pairs(G.Wounds.bodies) do
		print("[GHMPB] body", ent, "wounds", #b.wounds, "emitters", #b.emitters, "dead", b.dead)
	end
end)

local function DiagSurface(L)
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local tr = util.TraceLine({ start = ply:EyePos(), endpos = ply:EyePos() + ply:GetAimVector() * 4000, mask = MASK_SHOT, filter = ply })
	if not tr.Hit then L("crosshair: nothing hit") return end
	local ent = tr.Entity
	local prop = (tr.SurfaceProps and tr.SurfaceProps >= 0 and util.GetSurfacePropName) and util.GetSurfacePropName(tr.SurfaceProps) or "?"
	L(string.format("crosshair: %s  texture %s  surfaceprop %s  MatType %s -> blood surface '%s'  sky %s  dist %.0f",
		IsValid(ent) and ent:GetClass() or (tr.HitWorld and "world" or "?"), tostring(tr.HitTexture), tostring(prop), tostring(tr.MatType),
		G.SurfaceKindOf(tr), tostring(tr.HitSky), tr.HitPos:Distance(ply:EyePos())))
	local S = G.Surfaces
	if IsValid(ent) and not ent:IsWorld() then
		L("  entity counts as ground:", tostring(S.IsGround(ent)), "model", tostring(ent:GetModel()), "radius", math.floor(ent:BoundingRadius()), "moving", tostring(ent:GetVelocity():LengthSqr() >= 4))
	end
	local c = util.PointContents(tr.HitPos + tr.HitNormal * 0.5)
	L("  contents above the surface:", c, bit.band(c, CONTENTS_WATER) ~= 0 and "(WATER: blood dissolves)" or "")
	local p, key = S.GetPatch(tr.HitPos, tr.HitNormal, false)
	L("  patch here:", p and ("live, " .. tostring(p.meshKind) .. (p.needSlot and ", waiting for a slot" or "") .. (p.pendingBake and ", not probed yet" or "")) or "none",
		"| square key", tostring(key), "solid until", string.format("%.0f", (S.solidCells[key or ""] or 0) - CurTime()),
		"no surface until", string.format("%.0f", (S.emptyCells[key or ""] or 0) - CurTime()))
end

concommand.Add("ghmpb_diag", function()
	local L = function(...) MsgC(Color(255, 120, 120), "[GHMPB diag] ") print(...) end
	local S, E = G.Surfaces, G.Entities
	L("version", G.Version, "shaders", tostring(G.ShaderPrefix), "map", game.GetMap(), "singleplayer", tostring(game.SinglePlayer()))
	L("map lighting:", G.Light and G.Light.MapUnlit and (G.Light.MapUnlit() and "none (fullbright map: the blood is lit white)" or "baked") or "?",
		"| live blood range", G.LIVE_RANGE, "units | corpses smashed open by impacts", G.Wounds and G.Wounds.smashes or 0)
	local dc = G.Diag.c
	L("drawing: frames drawn", dc["frames: blood drawn"] or 0, "of", dc["frames: simulation ran"] or 0, "simulated | drawn late (another addon's hook cut the opaque pass short)",
		dc["frames: blood drawn late (the opaque pass did not reach it: another addon's hook returned a value)"] or 0,
		"| main view with the skybox flag (2D skybox map)", dc["frames: skybox flag on the main view (map with a 2D skybox only)"] or 0)
	if G.Probes and G.Probes.Describe then L(G.Probes.Describe()) end
	if G.MapLights and G.MapLights.Describe then L(G.MapLights.Describe()) end
	local sh = G.ShaderPrefix or ""
	local surfSh = (G.GPU and G.GPU.Shader) and G.GPU.Shader("surface_ps30") or (sh .. "surface_ps30")
	local simSh = (G.GPU and G.GPU.Shader) and G.GPU.Shader("sim_ps30") or (sh .. "sim_ps30")
	L("shader files present:", tostring(file.Exists("shaders/fxc/" .. surfSh .. ".vcs", "GAME")), tostring(file.Exists("shaders/fxc/" .. simSh .. ".vcs", "GAME")), "| dx11 (LUX):", tostring(G.GPU and G.GPU.isDX11 or false))
	if G.Lite and G.Lite.Counts then
		local st, pools, bodies = G.Lite.Counts()
		local ls = G.Lite.stats
		L("renderer:", G.Lite.on and "lite (no shaders)" or "shaders", "| lite: stains", st, "pools", pools, "bodies", bodies,
			"decals", ls.bodyDecals, "failed", ls.decalErrors, "run steps", ls.runs, "pools joined", ls.merged, "thinned", ls.skipped)
	end
	L("client: enable", G.cv.enable:GetInt(), "pools", G.cv.pools:GetInt(), "quality", G.cv.quality:GetInt(), "max patches", G.cv.maxpatches:GetInt(),
		"vram MB", G.cv.vram:GetInt(), "| server: enable", G.cv_sv_enable:GetInt(), "suppress engine blood", G.cv_sv_suppress:GetInt())
	L("native drop solver:", tostring(G.Native and G.Native.Available and G.Native.Available()), tostring(G.Native and G.Native.MODULE))
	local caps = G.Budget.Caps()
	L("budget: patches", caps.patches, "bodies", caps.ents, "aftermath", caps.aft, "| allocated MB", string.format("%.0f", G.Budget.Allocated()))
	local live, after = S.Counts()
	L("now: world patches", live, "settled", after, "bodies", table.Count(E.domains), "drops", G.Particles.Count(),
		"runs on walls", G.Runs and G.Runs.Count() or 0, "clouds in water", G.Water and G.Water.Count() or 0)
	if G.Runs then
		local st = G.Runs.stats
		L("runs: started", st.spawned, "merged", st.merged, "stopped", st.stopped, "reached a floor", st.floor, "dripped off an edge", st.drip, "went round a bend", st.bent)
	end
	if G.Tendrils and G.Tendrils.Describe then L(G.Tendrils.Describe()) end
	if G.DryTime then
		local env = G.DryEnvNow and G.DryEnvNow()
		L(string.format("drying: thin blood %.0f s (setting %.0f s, time-lapse x%.1f), clotting %.0f s%s, bodies x%.2f porous x%.2f sealed x%.2f ice/snow x%.2f, soak x%.2f, crust %.2f, conditions %s",
			G.DryTime(), G.cv.drytime:GetFloat(), G.cv.timelapse:GetFloat(), G.CoagTime(), G.cv.coag:GetBool() and "" or " (off)",
			G.cv.drybody:GetFloat(), G.cv.dryporous:GetFloat(), G.cv.drysealed:GetFloat(), G.cv.drycold:GetFloat(), G.cv.soak:GetFloat(),
			G.cv.crust:GetFloat(), env and env.name or "custom"))
	end
	if G.Blades and G.Blades.Describe then L(G.Blades.Describe()) end
	if G.Trails and G.Trails.stats then L("bleeder trails: drops", G.Trails.stats.drops, "arterial gushes", G.Trails.stats.gushes) end
	if G.Hands then
		local h, p, t, c = G.Hands.stats, G.Props.stats, G.Tyres.stats, G.Contact.stats
		L("hands: prints", h.prints, "blots", h.blots or 0, "streaks", h.drags, "pickups", h.pickups, "| props near blood", p.props, "smears", p.smears,
			"pushes", p.pushes, "soaks", p.soaks, "splashes", p.splashes, "prints", p.prints)
		L("tyres: wheels", t.wheels, "tread prints", t.prints, "skid marks", t.skids, "furrows", t.furrows, "sprays", t.sprays,
			"| splashes", c.splashes, "drops", c.splashDrops, "| GHM FLESH", GHMFL and "loaded" or "not loaded", "severs", G.Flesh.stats.severs,
			"stumps", G.Flesh.stats.stumps, "limbs", G.Flesh.stats.limbs, "copied", G.Flesh.stats.clones)
	end
	if G.ZC then
		local z, zs = G.ZC.cstats or {}, G.ZC.stats or {}
		L("Z-City:", G.ZC.Present() and "loaded" or "not loaded", "| takeover", G.ZC.Active() and "on" or "off", "installed", tostring(G.ZC.installed),
			"| wound drips", z.drips, "jets", z.jets, "clouds", z.clouds, "squirts", z.squirts, "stumps", z.stumps, "moved with body", z.moved,
			"bandaged", z.bandaged, "| their decals dropped", zs.decals, "effects dropped", zs.effects)
		local ls = G.ZC.lstats or {}
		L("server runs PhysBlood:", type(G.ServerRuns) == "function" and tostring(G.ServerRuns()) or "?", "| this client alone (from Z-City's hit messages): hits",
			ls.hits or 0, "on the world", ls.world or 0, "repeats left out", ls.merged or 0)
	end
	if G.Wounds and G.Wounds.exitStats then
		local x = G.Wounds.exitStats
		L("bullet exits: traced", x.trace, "through hitboxes", x.boxes, "where the body was", x.guessed,
			"| blood thrown before its body was known", G.Wounds.shotWorld or 0)
	end
	if G.Battle then
		local fs = G.Particles.farStats or {}
		L(G.Battle.Describe(), "| far drops: worked out", fs.spawned, "landed", fs.landed, "traces", fs.traces, "lost (queue full)", fs.lost)
	end
	if G.Elem and G.Elem.Describe then L(G.Elem.Describe()) end
	if G.Dust and G.Dust.Describe then L(G.Dust.Describe()) end
	if G.Flies and G.Flies.Describe then L(G.Flies.Describe()) end
	if G.HistCl then
		local hs = G.HistCl.stats
		L("catch-up (blood from far away, or from before you joined): stains / pools painted", hs.world, "bodies", hs.bodies, "skipped", hs.skipped, "waiting", #G.HistCl.world + #G.HistCl.bodies)
	end
	if G.Prof then
		L("frame profile (last 2 s):")
		for _, l in ipairs(G.Prof.Report()) do print("    " .. l) end
	end
	local rows = {}
	for k, v in pairs(G.Diag.c) do rows[#rows + 1] = { k, v } end
	table.sort(rows, function(a, b) return a[1] < b[1] end)
	L("since the map loaded:")
	for _, r in ipairs(rows) do print(string.format("    %-62s %d", r[1], r[2])) end
	if G.Diag.lastError then L("last error:", G.Diag.lastError) end
	for _, ev in ipairs({ "PostRender", "PostDrawOpaqueRenderables", "PostDrawTranslucentRenderables" }) do
		local names = {}
		for name in pairs(hook.GetTable()[ev] or {}) do names[#names + 1] = tostring(name) end
		L("hooks on " .. ev .. ":", table.concat(names, ", "))
	end
	DiagSurface(L)
	RunConsoleCommand("ghmpb_diag_sv")
end, nil, "GHM PhysBlood: print why there is (or is no) blood on this map - state, counters, the surface under the crosshair")

local hitDbg = CreateClientConVar("ghmpb_debug_hits", "0", false, false, "Show where hits on bodies land (red: server point, green: wound)")
D.hits = D.hits or {}
G.Wounds.HitDebug = function(ent, pos, dir, bone, surf, nrm, fromTrace)
	if not hitDbg:GetBool() then return end
	local name = bone and ent:GetBoneName(bone) or "?"
	local moved = (surf and pos) and surf:Distance(pos) or 0
	MsgN(string.format("[GHMPB] hit %s: bone %s (%s), wound %.1f u from the server's point", tostring(ent), name,
		fromTrace and "hitbox struck" or "nearest hitbox", moved))
	local h = D.hits
	h[#h + 1] = { t = RealTime(), pos = Vector(pos), surf = Vector(surf), nrm = Vector(nrm or -dir), dir = Vector(dir), name = name }
	if #h > 12 then table.remove(h, 1) end
end
hook.Add("PostDrawTranslucentRenderables", "ghmpb_debug_hits", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or #D.hits == 0 then return end
	local now = RealTime()
	render.SetColorMaterialIgnoreZ()
	for i = #D.hits, 1, -1 do
		local h = D.hits[i]
		if now - h.t > 10 then table.remove(D.hits, i) else
			render.DrawLine(h.pos - h.dir * 16, h.pos, Color(255, 200, 0), false)
			render.DrawWireframeSphere(h.pos, 0.8, 6, 6, Color(255, 40, 40), false)
			render.DrawWireframeSphere(h.surf, 0.6, 6, 6, Color(40, 255, 40), false)
			render.DrawLine(h.surf, h.surf + h.nrm * 4, Color(40, 255, 40), false)
			render.DrawLine(h.pos, h.surf, Color(255, 255, 255), false)
		end
	end
end)
hook.Add("HUDPaint", "ghmpb_debug_hits", function()
	if #D.hits == 0 then return end
	for _, h in ipairs(D.hits) do
		local sp = h.surf:ToScreen()
		if sp.visible then draw.SimpleText(h.name, "DebugFixedSmall", sp.x + 6, sp.y - 6, Color(120, 255, 120)) end
	end
end)
