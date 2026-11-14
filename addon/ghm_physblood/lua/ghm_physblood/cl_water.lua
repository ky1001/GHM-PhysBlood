local G = GHMPB
G.Water = G.Water or {}
local W = G.Water
local U = G.U

W.clouds = W.clouds or {}
W.MAX_CLOUDS = 64
W.stats = W.stats or { entered = 0, clouds = 0, merged = 0 }

local CONT = bit.bor(CONTENTS_WATER, CONTENTS_SLIME)
local band = bit.band
local PointContents = util.PointContents
local exp, sqrt, floor, min, max = math.exp, math.sqrt, math.floor, math.min, math.max

function W.Enabled() return G.cv.water == nil or G.cv.water:GetBool() end
function W.InWater(pos) return band(PointContents(pos), CONT) ~= 0 end

W.zCache = W.zCache or {}
local probe = Vector()
function W.SurfaceZ(pos)
	local key = floor(pos.x / 24) * 1e7 + floor(pos.y / 24) * 1e3 + floor(pos.z / 256)
	local c = W.zCache[key]
	if c and c.t > CurTime() - 20 then return c.z end
	probe:SetUnpacked(pos.x, pos.y, pos.z)
	local lo, hi = pos.z, nil
	local step = 4
	for _ = 1, 12 do
		probe.z = lo + step
		if band(PointContents(probe), CONT) == 0 then hi = probe.z break end
		lo = probe.z
		step = step * 2
	end
	local z
	if not hi then z = pos.z + 8192 else
		for _ = 1, 10 do
			local mid = (lo + hi) * 0.5
			probe.z = mid
			if band(PointContents(probe), CONT) ~= 0 then lo = mid else hi = mid end
		end
		z = (lo + hi) * 0.5
	end
	W.zCache[key] = { z = z, t = CurTime() }
	return z
end

function W.PatchWater(p)
	local P = G.Surfaces.PATCH_UNITS
	local hit
	for i = 0, 4 do
		for j = 0, 4 do
			local q = p.origin + p.U * ((i + 0.5) / 5 * P) + p.V * ((j + 0.5) / 5 * P) + p.N * 0.3
			if band(PointContents(q), CONT) ~= 0 then hit = q break end
		end
		if hit then break end
	end
	if not hit then return nil end
	local wz = W.SurfaceZ(hit)
	return { wz - p.origin.z, -p.U.z * P, -p.V.z * P, wz }
end

function W.EntityWaterZ(ent)
	if not IsValid(ent) then return nil end
	local now = CurTime()
	ent.ghmpbWaterT = ent.ghmpbWaterT or 0
	if now - ent.ghmpbWaterT < 0.5 then return ent.ghmpbWaterZ end
	ent.ghmpbWaterT = now
	local mn, mx = ent:WorldSpaceAABB()
	local z = nil
	local c = (mn + mx) * 0.5
	for _, q in ipairs({ Vector(c.x, c.y, mn.z + 1), c, Vector(mn.x + 2, mn.y + 2, mn.z + 2), Vector(mx.x - 2, mx.y - 2, mn.z + 2) }) do
		if band(PointContents(q), CONT) ~= 0 then z = W.SurfaceZ(q) break end
	end
	ent.ghmpbWaterZ = z
	return z
end

local TEX = { "ghm_physblood/cloud_core", "ghm_physblood/cloud_wisp1", "ghm_physblood/cloud_wisp2", "ghm_physblood/cloud_wisp3" }
local mats
local function Mats()
	if mats then return mats end
	mats = {}
	for k, t in ipairs(TEX) do
		mats[k] = G.GPU.CreateMat("cloud" .. k, "UnlitGeneric", { ["$basetexture"] = t, ["$translucent"] = 1, ["$vertexcolor"] = 1,
			["$vertexalpha"] = 1, ["$nocull"] = 1 })
	end
	return mats
end

local trD, outD = { mask = MASK_SOLID_BRUSHONLY }, {}
trD.output = outD

local function FloorBelow(pos)
	trD.start = pos
	trD.endpos = pos - Vector(0, 0, 1200)
	util.TraceLine(trD)
	return outD.Hit and outD.HitPos.z or (pos.z - 1200)
end

local function Life()
	return G.cv.watertime and G.cv.watertime:GetFloat() or 90
end

local function AddPuff(c, core)
	c.puffs = c.puffs or {}
	if #c.puffs >= 7 then return end
	local off = VectorRand() * (core and 0.12 or 0.45)
	off.z = off.z * 0.6
	c.puffs[#c.puffs + 1] = { off = off, sz = core and U.RandRange(0.85, 1.05) or U.RandRange(0.8, 1.4), w = core and 0.85 or U.RandRange(0.55, 0.95),
		tex = core and 1 or math.random(2, #TEX), rot = math.Rand(0, 360), rotV = math.Rand(-9, 9), born = CurTime() }
end

local function NewCloud(pos, vel, vol, btype, oxy, surfZ)
	if #W.clouds >= W.MAX_CLOUDS then
		local worst, wi = nil, nil
		for i, c in ipairs(W.clouds) do
			local s = c.alpha - c.age * 0.001
			if not worst or s < worst then worst, wi = s, i end
		end
		if wi then table.remove(W.clouds, wi) end
	end
	local sp = vel:Length()
	local dir = sp > 1 and vel / sp or Vector(0, 0, -1)
	local pen = math.Clamp(sp * 0.012, 0.3, 6)
	local p = pos + dir * pen * 0.6
	p.z = math.min(p.z, surfZ - 0.4)
	local c = { pos = p, vol = vol, age = 0, rd2 = 0.04, r = 0.3, alpha = 0, btype = btype or 0, oxy = oxy or 0.75,
		vel = dir * min(sp * 0.03, 6), surfZ = surfZ, floorZ = FloorBelow(p + Vector(0, 0, 1)), seed = math.random() }
	if vel.z < -40 and sp > 60 then c.tendril = { len = 0.3, w = U.RandRange(0.35, 0.6), tex = math.random(2, #TEX) } end
	W.clouds[#W.clouds + 1] = c
	W.stats.clouds = W.stats.clouds + 1
	AddPuff(c, true)
	local n = math.Clamp(floor(vol ^ (1 / 3) / 2.5), 1, 4)
	for _ = 1, n do AddPuff(c, false) end
	return c
end

function W.Kill(c) c.dead = true end

function W.Enter(pos, vel, vol, btype, oxy, surfZ)
	if not W.Enabled() or not vol or vol < 0.01 then return end
	G.DiagCount("water: blood entered water")
	W.stats.entered = W.stats.entered + 1
	vol = vol * (G.cv.wateramt and G.cv.wateramt:GetFloat() or 1)
	vel = vel or vector_origin
	surfZ = surfZ or W.SurfaceZ(pos)
	local best, bd = nil, math.huge
	for _, c in ipairs(W.clouds) do
		if not c.dead and (c.btype == (btype or 0)) then
			local reach = math.max(c.r * 1.5, 6)
			local d2 = c.pos:DistToSqr(pos)
			if d2 < reach * reach and d2 < bd then best, bd = c, d2 end
		end
	end
	if best then
		local c = best
		local f = vol / (c.vol + vol)
		c.vol = c.vol + vol
		c.pos = c.pos + (pos - c.pos) * f * 0.5
		c.pos.z = math.min(c.pos.z, c.surfZ - 0.4)
		c.oxy = c.oxy + ((oxy or 0.75) - c.oxy) * f
		c.fresh = CurTime()
		if f > 0.15 then AddPuff(c, false) end
		W.stats.merged = W.stats.merged + 1
		return c
	end
	return NewCloud(pos, vel, vol, btype, oxy, surfZ)
end

local trW, outW = { mask = bit.bor(CONTENTS_WATER, CONTENTS_SLIME) }, {}
trW.output = outW
local rippleT, rippleN = 0, 0
function W.EnterDrop(a, b, vel, vol, btype, oxy, rmm)
	if not W.Enabled() then return end
	trW.start, trW.endpos = a, b
	util.TraceLine(trW)
	local entry, surfZ
	if outW.Hit and not outW.StartSolid then
		entry = Vector(outW.HitPos)
		surfZ = entry.z
		local now = CurTime()
		if now - rippleT > 0.25 then rippleT, rippleN = now, 0 end
		if (rmm or 0) > 0.9 and rippleN < 4 then
			rippleN = rippleN + 1
			local ed = EffectData()
			ed:SetOrigin(entry)
			ed:SetScale(math.Clamp((rmm or 1) * 2.5, 2, 10))
			ed:SetFlags(0)
			util.Effect("waterripple", ed, true, true)
		end
	else
		entry = Vector(b)
	end
	return W.Enter(entry, vel, vol, btype, oxy, surfZ)
end

local nextFloor = 0
function W.Update(dt)
	if #W.clouds == 0 or dt <= 0 then return end
	local life = Life()
	local now = CurTime()
	local doFloor = now > nextFloor
	if doFloor then nextFloor = now + 1 end
	for i = #W.clouds, 1, -1 do
		local c = W.clouds[i]
		if c.dead then table.remove(W.clouds, i) else
			c.age = c.age + dt
			local v3 = c.vol ^ (1 / 3)
			local Kd = 0.18 + 0.03 * c.r
			if c.onFloor then Kd = Kd * 1.8 end
			c.rd2 = c.rd2 + 4 * Kd * dt
			local roll = 0.4 * v3 * (1 - exp(-c.age / 1.2))
			c.r = math.max(sqrt(c.rd2), roll, 0.25)
			local tau = 0.035 * c.vol / (c.r * c.r)
			local fadeIn = math.min(c.age / 0.25, 1)
			local fadeOut = 1 - math.Clamp((c.age - life * 0.75) / (life * 0.25), 0, 1)
			c.alpha = (1 - exp(-tau * 1.3)) * 0.85 * fadeIn * fadeOut
			c.vel = c.vel * exp(-dt * 2.5)
			local sink = 1.6 * exp(-c.age / 7) + 0.15
			local p = c.pos
			p.x = p.x + c.vel.x * dt + (math.sin(now * 0.31 + c.seed * 20) * 0.12) * dt
			p.y = p.y + c.vel.y * dt + (math.cos(now * 0.27 + c.seed * 31) * 0.12) * dt
			p.z = p.z + (c.vel.z - sink) * dt
			if doFloor and not c.onFloor then c.floorZ = FloorBelow(Vector(p.x, p.y, math.min(p.z + 2, c.surfZ - 0.2))) end
			local depth = c.surfZ - c.floorZ
			c.flat = depth < c.r * 1.6
			local bottom = c.floorZ + math.min(c.r * 0.35, depth * 0.5)
			if p.z < bottom then p.z = bottom c.onFloor = true end
			local top = c.surfZ - math.min(c.r * 0.4, depth * 0.5)
			if p.z > top then p.z = top end
			if c.tendril then
				c.tendril.len = math.min(c.tendril.len + (sink + 0.8 * exp(-c.age / 2)) * dt * 1.4, 2 + c.r)
				if c.age > 14 then c.tendril = nil end
			end
			if (c.alpha < 0.012 and c.age > 2) or c.age > life then
				table.remove(W.clouds, i)
			end
		end
	end
end

function W.Count() return #W.clouds end

function W.Clear()
	W.clouds = {}
	W.zCache = {}
end

local UP = Vector(0, 0, 1)
local list = {}
function W.Draw()
	local n = #W.clouds
	if n == 0 then return end
	local eye = EyePos()
	local eyeWet = W.InWater(eye)
	local rt = render.GetRenderTarget()
	if (rt == nil and not eyeWet) or (rt ~= nil and eyeWet) then return end
	local m = Mats()
	local now = CurTime()
	local k = 0
	local fogMode = render.GetFogMode()
	local fs, fe, fz = render.GetFogDistances()
	local fr, fg, fb = render.GetFogColor()
	local fogOn = fogMode and fogMode ~= MATERIAL_FOG_NONE and fe and fs and fe > fs
	local below = fogMode == MATERIAL_FOG_LINEAR_BELOW_FOG_Z
	for _, c in ipairs(W.clouds) do
		if c.alpha > 0.004 and c.puffs then
			local L = render.ComputeLighting(c.pos, UP) + render.ComputeLighting(c.pos, -UP) * 0.6
			local lum = math.Clamp((L.x * 0.3 + L.y * 0.59 + L.z * 0.11) ^ 0.45 * 1.1, 0.12, 1.0)
			local r0, g0, b0 = U.BloodColour(c.btype or 0, c.oxy or 0.75, 92)
			local f = 0
			if fogOn then
				local dist = c.pos:Distance(eye)
				if below and fz and eye.z > c.pos.z then
					dist = dist * math.Clamp((fz - c.pos.z) / math.max(eye.z - c.pos.z, 1e-3), 0, 1)
				end
				f = math.Clamp((dist - fs) / (fe - fs), 0, 1)
			end
			local cr, cg, cb = r0 * lum, g0 * lum, b0 * lum
			cr, cg, cb = cr + (fr - cr) * f, cg + (fg - cg) * f, cb + (fb - cb) * f
			local fa = 1 - 0.75 * f
			for _, pf in ipairs(c.puffs) do
				k = k + 1
				local e = list[k]
				if not e then e = {} list[k] = e end
				local p = c.pos + pf.off * c.r
				if c.flat then p.z = c.pos.z end
				e.p, e.d = p, p:DistToSqr(eye)
				e.size = c.r * 2.2 * pf.sz * (c.flat and 1.5 or 1)
				e.mat = m[pf.tex]
				e.rot = pf.rot + pf.rotV * (now - pf.born)
				e.flat = c.flat
				local a = c.alpha * pf.w * math.Clamp((now - pf.born) / 0.4, 0, 1) * fa
				e.col = Color(math.Clamp(cr, 0, 255), math.Clamp(cg, 0, 255), math.Clamp(cb, 0, 255), math.Clamp(a * 255, 0, 255))
				e.beam = nil
			end
			local td = c.tendril
			if td and not c.flat then
				k = k + 1
				local e = list[k]
				if not e then e = {} list[k] = e end
				e.beam = true
				e.p = c.pos + Vector(0, 0, c.r * 0.15)
				e.p2 = c.pos - Vector(0, 0, td.len)
				e.d = (c.pos - Vector(0, 0, td.len * 0.5)):DistToSqr(eye)
				e.size = math.max(c.r * td.w, 0.25)
				e.mat = m[td.tex]
				local a = math.min(c.alpha * 1.1, 0.9) * fa * math.Clamp(1 - c.age / 14, 0, 1)
				e.col = Color(math.Clamp(cr, 0, 255), math.Clamp(cg, 0, 255), math.Clamp(cb, 0, 255), math.Clamp(a * 255, 0, 255))
			end
		end
	end
	for j = k + 1, #list do list[j] = nil end
	if k == 0 then return end
	table.sort(list, function(a, b) return a.d > b.d end)
	for j = 1, k do
		local e = list[j]
		render.SetMaterial(e.mat)
		if e.beam then
			render.DrawBeam(e.p, e.p2, e.size, 0, 1, e.col)
		else
			local nrm = e.flat and UP or (eye - e.p)
			if not e.flat then nrm:Normalize() end
			render.DrawQuadEasy(e.p, nrm, e.size, e.size, e.col, e.rot)
		end
	end
end

hook.Add("PostDrawTranslucentRenderables", "ghmpb_water", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or #W.clouds == 0 then return end
	local ok, err = pcall(W.Draw)
	if not ok then G.DiagCount("error: water clouds") G.Diag.lastError = tostring(err) end
end)
