local G = GHMPB
G.Light = G.Light or {}
local L = G.Light

local AX = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local cache = setmetatable({}, { __mode = "k" })

local unlit = nil
function L.MapUnlit()
	if unlit ~= nil then return unlit end
	unlit = false
	local ok, res = pcall(function()
		local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
		if not f then return false end
		local r = false
		if f:Read(4) == "VBSP" then
			f:Seek(8 + 8 * 16 + 4)
			local ldr = f:ReadLong() or 0
			f:Seek(8 + 53 * 16 + 4)
			local hdr = f:ReadLong() or 0
			r = ldr <= 0 and hdr <= 0
		end
		f:Close()
		return r
	end)
	unlit = ok and res == true
	if unlit then MsgN("[GHMPB] this map has no baked lighting (it renders fullbright): the blood is lit to match") end
	return unlit
end
hook.Add("InitPostEntity", "ghmpb_unlit", function() unlit = nil end)

local function probe(pos)
	local s = {}
	for i = 1, 6 do s[i] = render.ComputeLighting(pos, AX[i]) end
	if L.MapUnlit() then
		local m = 0
		for i = 1, 6 do m = math.max(m, s[i].x, s[i].y, s[i].z) end
		if m < 0.02 then for i = 1, 6 do s[i] = Vector(1, 1, 1) end end
	end
	local function sh(ch)
		local px, nx = s[1][ch], s[2][ch]
		local py, ny = s[3][ch], s[4][ch]
		local pz, nz = s[5][ch], s[6][ch]
		local c0 = (px + nx + py + ny + pz + nz) / 6
		return { c0, (px - nx) * 0.5, (py - ny) * 0.5, (pz - nz) * 0.5 }
	end
	local r, g, b = sh("x"), sh("y"), sh("z")
	local lx = r[2] * 0.2126 + g[2] * 0.7152 + b[2] * 0.0722
	local ly = r[3] * 0.2126 + g[3] * 0.7152 + b[3] * 0.0722
	local lz = r[4] * 0.2126 + g[4] * 0.7152 + b[4] * 0.0722
	local dir = Vector(lx, ly, lz)
	local mag = dir:Length()
	if mag < 1e-4 then dir = Vector(0.3, 0.2, 0.93) else dir:Mul(1 / mag) end
	local col = Vector(math.max(0, r[2] * dir.x + r[3] * dir.y + r[4] * dir.z),
		math.max(0, g[2] * dir.x + g[3] * dir.y + g[4] * dir.z),
		math.max(0, b[2] * dir.x + b[3] * dir.y + b[4] * dir.z))
	return { r = r, g = g, b = b, dir = dir, col = col * 2.0, amb = Vector(r[1], g[1], b[1]) }
end

local sunInfo, sunNext = nil, 0
local function Sun()
	if CurTime() > sunNext then
		sunNext = CurTime() + 2
		sunInfo = util.GetSunInfo()
	end
	return sunInfo
end

L.BUDGET = 14
L.STALE_MAX = 3
local grid = {}
local gridN, probesFrame, probesN = 0, -1, 0
local function GridKey(pos)
	return (math.floor(pos.x / 32) + 1024) + (math.floor(pos.y / 32) + 1024) * 2048 + (math.floor(pos.z / 32) + 1024) * 4194304
end
L.stats = { probes = 0, shared = 0, stale = 0 }

function L.Get(key, pos, maxAge)
	local c = cache[key]
	local now = RealTime()
	maxAge = maxAge or 0.12
	if c and now - c.t < maxAge and c.pos:DistToSqr(pos) < 64 then return c end
	local gk = GridKey(pos)
	local gc = grid[gk]
	if gc and now - gc.t < maxAge then cache[key] = gc L.stats.shared = L.stats.shared + 1 return gc end
	local f = FrameNumber()
	if f ~= probesFrame then probesFrame, probesN = f, 0 end
	if probesN >= L.BUDGET then
		local old = c or gc
		if old and now - old.t < L.STALE_MAX and old.pos:DistToSqr(pos) < 4096 then
			L.stats.stale = L.stats.stale + 1
			return old
		end
	end
	probesN = probesN + 1
	L.stats.probes = L.stats.probes + 1
	c = probe(pos)
	c.t, c.pos = now, pos
	local sun = Sun()
	c.sunDir, c.sunVis, c.sunCol = Vector(0, 0, 1), 0, Vector(0, 0, 0)
	if sun and sun.direction then
		c.sunDir = sun.direction
		local tr = util.TraceLine({ start = pos + sun.direction * 4, endpos = pos + sun.direction * 16000, mask = MASK_OPAQUE })
		local vis = (tr.HitSky and 1 or 0) * (1 - (sun.obstruction or 0))
		c.sunVis = vis
		local a = math.max(0.05, c.amb.x * 0.2126 + c.amb.y * 0.7152 + c.amb.z * 0.0722)
		c.sunCol = Vector(1.0, 0.94, 0.84) * math.Clamp(a * 3.0, 0.3, 4.0)
	end
	cache[key] = c
	if not grid[gk] then
		gridN = gridN + 1
		if gridN > 4096 then grid, gridN = {}, 1 end
	end
	grid[gk] = c
	return c
end

-- (1.26.8) the light a surface point receives (render.ComputeLighting): one sample shared by everything within 24 u
-- facing the same way, kept for 3 s. The Lite stains, the Lite pools and the rivulet heads asked the engine for each
-- one of their own: in a magazine dump dozens of times a frame, and the call is a costly one (players: "laggy since the
-- update", "with mag dumping performance not good"). At most L.AT_BUDGET new samples a frame; past that, the one known
-- for that spot, else the last one taken for that facing. The vector returned is shared: read it, don't change it
L.AT_CELL, L.AT_TTL, L.AT_BUDGET = 24, 3, 6
local atCache, atN, atFrame, atLeft = {}, 0, -1, 0
local atLast = {}
local abs, floor = math.abs, math.floor
local function Facing(n)
	local ax, ay, az = abs(n.x), abs(n.y), abs(n.z)
	if az >= ax and az >= ay then return n.z >= 0 and 5 or 6 end
	if ax >= ay then return n.x >= 0 and 1 or 2 end
	return n.y >= 0 and 3 or 4
end
L.atStats = L.atStats or { samples = 0, shared = 0, stale = 0 }
function L.At(pos, n)
	local f = Facing(n)
	local c = L.AT_CELL
	local px, py, pz = pos.x, pos.y, pos.z
	local key = (((floor(px / c) + 4096) * 8192 + (floor(py / c) + 4096)) * 8192 + (floor(pz / c) + 4096)) * 8 + f
	local now = RealTime()
	local e = atCache[key]
	if e and now < e.t then L.atStats.shared = L.atStats.shared + 1 return e.E end
	local fr = FrameNumber()
	if fr ~= atFrame then atFrame, atLeft = fr, L.AT_BUDGET end
	if atLeft <= 0 then
		local old = (e and e.E) or atLast[f]
		if old then L.atStats.stale = L.atStats.stale + 1 return old end
	end
	atLeft = atLeft - 1
	L.atStats.samples = L.atStats.samples + 1
	local nx, ny, nz = n.x, n.y, n.z
	local ok, E = pcall(render.ComputeLighting, Vector(px + nx * 1.5, py + ny * 1.5, pz + nz * 1.5), n)
	if not ok or not E then E = Vector(0.4, 0.4, 0.4) end
	if not e then
		atN = atN + 1
		if atN > 4096 then atCache, atN = {}, 1 end
		e = {}
		atCache[key] = e
	end
	e.E, e.t = E, now + L.AT_TTL
	atLast[f] = E
	return E
end

-- (1.26.6) where to light the droplets: up to dist in front of the camera, but in the open. With the camera close to a
-- wall or the ground, eye + forward * 100 lay inside it, where there is no light - the drops came out black
local vpOut = {}
local vpTr = { mask = MASK_OPAQUE, output = vpOut }
function L.ViewProbePos(eye, fwd, dist)
	vpTr.start = eye
	vpTr.endpos = eye + fwd * dist
	util.TraceLine(vpTr)
	local tr = vpOut
	if tr.Hit and not tr.StartSolid and tr.HitPos then
		return tr.HitPos + (tr.HitNormal or -fwd) * 4 - fwd * 2
	end
	return eye + fwd * dist
end

local flFrame, flPos, flDir = -1, nil, nil
local FL_COS = math.cos(math.rad(28))
function L.Flashlight()
	local f = FrameNumber()
	if f ~= flFrame then
		flFrame, flPos, flDir = f, nil, nil
		local ply = LocalPlayer()
		if IsValid(ply) and ply.FlashlightIsOn and ply:FlashlightIsOn() then
			-- a torch is held beside and below the eye, not inside it: a light exactly at the eye can only
			-- mirror off a flat pool straight back along the view ray, so its glint would sit at one point
			-- under the player and never show anywhere else (1.26.0)
			local ang = ply:EyeAngles()
			flPos, flDir = ply:EyePos() + ang:Right() * 7 - ang:Up() * 6, ang:Forward()
		end
	end
	if not flPos then return nil end
	return flPos, flDir, FL_COS, 900
end

-- (1.26.6) reflMul: shine of this patch / body (old blood loses its shine, G.ShineAged)
-- (1.26.10) fresh blood's extra shine in quarters: 2 x (Fresh blood wetness - 1) - 3 at the default 2.5 (fresh, liquid
-- blood 4 x as shiny as the settled pool's look), none at 1
function L.FreshShineQ()
	local cv = G.cv.freshwet
	local fw = cv and math.Clamp(cv:GetFloat(), 1, 3) or 2.5
	return math.floor((fw - 1) * 2 * 4 + 0.5)
end
function L.Apply(mat, info, rough, c2w, layerWord, elemWord, reflMul)
	local GPU = G.GPU
	local envWord = math.floor(math.Clamp(G.cv.reflect:GetFloat() * (reflMul or 1) * (G.ShaderComp and G.ShaderComp().refl or 1), 0, 3) * 64 + 0.5) + math.Clamp(rough or 0.35, 0, 1) * 0.999
	-- (1.26.10) fresh blood's extra shine (the shaders: 256 x 4 x it on top, until the blood gels), from "Fresh blood
	-- wetness" - only for the shader pack that reads it (an older one would take it for a huge reflection strength)
	if G.NewShaders and G.NewShaders() then envWord = envWord + 256 * L.FreshShineQ() end
	GPU.SetC(mat, 2, info.dir.x, info.dir.y, info.dir.z, c2w or 0)
	local fpos, fdir, fcos, frange = L.Flashlight()
	GPU.SetC(mat, 3, info.col.x, info.col.y, info.col.z, (fpos and 1 or 0) + 2 * (elemWord or 0))
	local fx, fy, fz, dx, dy, dz = 0, 0, 0, 0, 0, -1
	if fpos then fx, fy, fz, dx, dy, dz = fpos.x, fpos.y, fpos.z, fdir.x, fdir.y, fdir.z end
	local sd, sc = info.sunDir, info.sunCol
	GPU.SetRowsN(mat, "$viewprojmat", sd.x, sd.y, sd.z, info.sunVis, sc.x, sc.y, sc.z, envWord,
		fx, fy, fz, layerWord or 0.999, dx, dy, dz, math.floor(frange or 900) + (fcos or 0.9) * 0.999)
end

function L.ApplySH4(mat, info, w1, w2, w3, w4)
	local r, g, b = info.r, info.g, info.b
	G.GPU.SetRowsN(mat, "$invviewprojmat", r[1], r[2], r[3], r[4], g[1], g[2], g[3], g[4], b[1], b[2], b[3], b[4], w1, w2, w3, w4)
end
function L.ApplySH(mat, info, row3)
	L.ApplySH4(mat, info, row3[1] or 0, row3[2] or 0, row3[3] or 0, row3[4] or 0)
end

function L.Forget(key) cache[key] = nil end
