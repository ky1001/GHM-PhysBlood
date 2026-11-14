local G = GHMPB
G.Lite = G.Lite or {}
local L = G.Lite
local U = G.U
local MM = G.MM_TO_UNITS
local sqrt, floor, max, min, abs, exp = math.sqrt, math.floor, math.max, math.min, math.abs, math.exp

L.stats = L.stats or { stains = 0, pools = 0, bodyDecals = 0, decalErrors = 0, runs = 0, merged = 0, skipped = 0 }
L.batches = L.batches or {}
L.open = L.open or { list = {}, t0 = 0 }
L.pools = L.pools or {}
L.bodies = L.bodies or setmetatable({}, { __mode = "k" })
L.hash = L.hash or {}

local REQ_SHADERS = {
	"bake_ps30", "blit_ps30", "bodyfilm_ps30", "bodystatic_ps30", "clip_vs30", "copy_ps30",
	"drop_ps30", "drop_vs30", "dustaft_ps30", "dustbody_ps30", "dustworld_ps30", "elem_ps30",
	"force_ps30", "modeldust_vs30", "model_vs30", "peek_ps30", "pforce_ps30", "probeblur_ps30",
	"probeenv_ps30", "reduce_ps30", "simbody_ps30", "sim_ps30", "stamp_ps30", "surface_ps30",
	"surfstatic_ps30", "unwrap_vs30", "worlddust_vs30", "world_vs30"
}
function L.ShadersPresent()
	for i = 1, #REQ_SHADERS do
		local sh = (G.GPU and G.GPU.Shader) and G.GPU.Shader(REQ_SHADERS[i]) or ((G.ShaderPrefix or "") .. REQ_SHADERS[i])
		local rel = "shaders/fxc/" .. sh .. ".vcs"
		if not file.Exists(rel, "GAME") and not file.Exists("garrysmod/" .. rel, "BASE_PATH") then return false end
	end
	return true
end
function L.Decide()
	if not L.ShadersPresent() then return true end
	if L.forcedFallback then return true end
	local m = G.cv.rendermode and G.cv.rendermode:GetInt() or 0
	return m == 2
end
function L.ForceFallback(reason)
	if L.on then return end
	L.forcedFallback = true
	if G.Render and G.Render.ClearAll then pcall(G.Render.ClearAll) end
	L.on = true
	MsgC(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Custom shaders inactive (" .. tostring(reason or "not detected") .. ") -> switched to built-in Non-Shader (Lite) mode.\n")
end
L.on = L.Decide()
if L.on and not L.announced then
	L.announced = true
	MsgN("[GHMPB] lite renderer (" .. (L.ShadersPresent() and "chosen in the settings" or "the shader files are not installed") .. ")")
end

local matMod, matShine, matDrop
local function Mats()
	if not matMod then
		matMod = Material("ghm_physblood/lite/stain_mod")
		matShine = Material("ghm_physblood/lite/stain_shine")
		matDrop = Material("ghm_physblood/lite/drop")
	end
	local k = 0.025 * math.Clamp(G.cv.reflect:GetFloat(), 0, 3)   -- (1.26.6) weak, crimson-tinted sky reflection
	if L.shineK ~= k then
		L.shineK = k
		matShine:SetVector("$envmaptint", Vector(k, k * 0.12, k * 0.10))
	end
	return matMod, matShine, matDrop
end

local function G22(c) return c <= 0 and 0 or c ^ (1 / 2.2) end
function L.WetTint(btype, oxy, h)
	local r, g, b = U.BloodTrans(btype or 0, oxy or 0.75, math.Clamp(h, 0.01, 4))
	return math.min(G22(math.max(r, 0.02)), 1) * 127.5, math.min(G22(math.max(g, 0.004)), 1) * 127.5, math.min(G22(math.max(b, 0.003)), 1) * 127.5
end
local function LinSrgb255(c) c = math.Clamp(c, 0, 1) return (c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 end
local function SrgbLin255(c) c = c / 255 return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
-- (1.26.8) the shared light sample of that spot (cl_lighting.lua G.Light.At): 1.26.7 asked the engine for every stain
function L.Light(pos, n)
	local E
	if G.Light and G.Light.At then
		E = G.Light.At(pos, n)
	else
		local ok, e = pcall(render.ComputeLighting, pos + n * 1.5, n)
		E = ok and e or nil
	end
	if not E then return Vector(0.4, 0.4, 0.4) end
	if E.x + E.y + E.z < 0.03 and G.Light and G.Light.MapUnlit and G.Light.MapUnlit() then return Vector(1, 1, 1) end
	return Vector(math.max(E.x, 0.18), math.max(E.y, 0.18), math.max(E.z, 0.18))
end
function L.Diffuse(btype, oxy, h, E)
	local tr, tg = U.BloodTrans(btype or 0, oxy or 0.75, math.Clamp(h, 0.01, 4))
	-- (1.26.6) how opaque the film is: its red transmission, or half its green one for very bright blood
	local k = math.max(1 - G22(math.Clamp(tr, 0, 1)), 0.5 * (1 - G22(math.Clamp(tg or 0, 0, 1))))
	local r, g, b = U.BloodDense(btype or 0, oxy or 0.75, 105)
	return LinSrgb255(SrgbLin255(r) * E.x) * k, LinSrgb255(SrgbLin255(g) * E.y) * k, LinSrgb255(SrgbLin255(b) * E.z) * k
end

local KD = { 1.9, 11.5, 15.0 }
local TD = {
	[0] = { 1, 1, 1 },
	[1] = { 1.0, 0.9, 1.6 },
	[2] = { 1.6, 0.8, 1.4 },
	[3] = { 1.1, 1.2, 1.2 },
	[4] = { 2.4, 0.7, 0.45 },
	[5] = { 1.8, 1.7, 2.0 },
	-- (1.26.10c) blue and purple (NPC packs' blood colours)
	[6] = { 2.6, 0.75, 0.15 },
	[7] = { 1.0, 1.5, 0.35 },
}
function L.DryTint(btype, h)
	local k = math.max(G.cv.colDry:GetFloat(), 0.3)
	local t = TD[btype or 0] or TD[0]
	local he = math.Clamp(h, 0.01, 4) * 3
	local r = math.max(exp(-KD[1] * t[1] * he), 0.07) ^ (1 / k)
	local g = math.max(exp(-KD[2] * t[2] * he), 0.012) ^ (1 / k)
	local b = math.max(exp(-KD[3] * t[3] * he), 0.008) ^ (1 / k)
	return G22(r) * 127.5, G22(g) * 127.5, G22(b) * 127.5
end

local CELL_UV = {}
for k = 0, 15 do CELL_UV[k] = { (k % 4) * 0.25, floor(k / 4) * 0.25 } end
L.CELL = { splat = { 0, 1, 2, 3 }, oblique = { 4, 5 }, pool = 6, run = 7, smear = 8, shoe = 9, pad = 10, hand = 11,
	tyre = 12, mist = 13, small = 14, bead = 15 }
-- (1.26.7) the splat, oblique and small cells are the droplet decals of GHM's blood mod and the mist cell a Crisis
-- Response Blood spatter decal (tools/make_crb_lite.py): every drop lands as a drop, the fine spray is the CRB decal
local BODY = { [0] = 0.30, 0.53, 0.56, 0.63, 0.40, 0.50, 0.80, 0.30, 0.5, 0.87, 0.75, 0.8, 0.6, 0.85, 0.75, 0.5 }
local OBLIQUE_LEN = 0.55   -- (1.26.7) half length of an oblique stain over half its cell (was 0.46)

local function Basis(n)
	local a = abs(n.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0)
	local u = a:Cross(n) u:Normalize()
	local v = n:Cross(u) v:Normalize()
	return u, v
end
-- (1.26.8) in plain numbers: one Vector made (it was up to six, and as many engine calls)
local function Tangent(n, dir)
	local nx, ny, nz = n:Unpack()
	if dir then
		local dx, dy, dz = dir:Unpack()
		local d = dx * nx + dy * ny + dz * nz
		local tx, ty, tz = dx - nx * d, dy - ny * d, dz - nz * d
		local l = sqrt(tx * tx + ty * ty + tz * tz)
		if l > 1e-3 then return Vector(tx / l, ty / l, tz / l) end
	end
	-- u = a x n (a: up, or x when n is near vertical), v = n x u
	local ax, ay, az = 0, 0, 1
	if abs(nz) >= 0.9 then ax, az = 1, 0 end
	local ux, uy, uz = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
	local ul = sqrt(ux * ux + uy * uy + uz * uz)
	ux, uy, uz = ux / ul, uy / ul, uz / ul
	local vx, vy, vz = ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux
	local vl = sqrt(vx * vx + vy * vy + vz * vz)
	vx, vy, vz = vx / vl, vy / vl, vz / vl
	local a = math.random() * 6.2832
	local c, sn = math.cos(a), math.sin(a)
	return Vector(ux * c + vx * sn, uy * c + vy * sn, uz * c + vz * sn)
end
local function PlaneKey(n, pos)
	return string.format("%d,%d,%d,%d", math.Round(n.x * 40), math.Round(n.y * 40), math.Round(n.z * 40), math.Round(n:Dot(pos) * 2))
end

local HC = 40
local function HKey(x, y) return floor(x / HC) * 65536 + floor(y / HC) end
local function HashAdd(s)
	local k = HKey(s.x, s.y)
	local l = L.hash[k]
	if not l then l = {} L.hash[k] = l end
	l[#l + 1] = s
	s.hk = k
end
local function HashRemove(s)
	local l = s.hk and L.hash[s.hk]
	if not l then return end
	for i = #l, 1, -1 do if l[i] == s then table.remove(l, i) break end end
	if #l == 0 then L.hash[s.hk] = nil end
end

local function DryTime() return G.DryTime() end

-- (1.26.8) a stain is fitted to the edge of what it lies on (traces round it) only when its quad is over 3.2 u across
-- (blood of about 1 to 2 u), and with at most 24-96 traces a frame (the detail level, cl_governor.lua V.Detail): every
-- quad over 0.7 u took 4 to 16 traces, in a magazine dump hundreds a frame. A small splat past an edge by a fraction of a
-- unit doesn't show
local CLIP_MIN = 1.6
local clipF, clipLeft = -1, 0
local function GovDetail()
	if G.Gov and G.Gov.Detail then return G.Gov.Detail() end
	return 1, 0
end
local function ClipBudget(need)
	local f = FrameNumber()
	if f ~= clipF then clipF, clipLeft = f, floor(24 + 72 * GovDetail()) end
	if clipLeft < need then return false end
	return true
end
L.ClipBudget = ClipBudget
-- (1.26.8) the results written into one table (a trace returns a new table of about 20 fields otherwise: about 1.5 KB of
-- garbage a trace, and these run up to 96 times a frame)
local stainOut = {}
local stainTr = { mask = MASK_SOLID, filter = function(e) return G.Surfaces.GroundFilter(e) end, output = stainOut }
local function SurfAtOffset(pos, n, offVec)
	clipLeft = clipLeft - 1
	local q = pos + offVec
	stainTr.start = q + n * 2.5
	stainTr.endpos = q - n * 2.5
	local tr = util.TraceLine(stainTr) or stainOut
	return tr.Hit and not tr.StartSolid and not tr.HitSky and tr.HitNormal:Dot(n) > 0.82 and abs((tr.HitPos - pos):Dot(n)) < 1.2
end

local function ClipAxis(pos, n, ax, hlen)
	if hlen <= 0.35 then return -1, 1 end
	local u0, u1 = -1, 1
	if not SurfAtOffset(pos, n, ax * hlen) then
		u1 = 0.15
		for f = 0.75, 0.25, -0.25 do
			if SurfAtOffset(pos, n, ax * (hlen * f)) then u1 = f break end
		end
	end
	if not SurfAtOffset(pos, n, -ax * hlen) then
		u0 = -0.15
		for f = 0.75, 0.25, -0.25 do
			if SurfAtOffset(pos, n, -ax * (hlen * f)) then u0 = -f break end
		end
	end
	return u0, u1
end

local function NewStain(pos, n, Uax, hu, hv, cell, flip, alpha, h, vol, btype, oxy, wetMul, noClip)
	local now = CurTime()
	local px, py, pz = pos:Unpack()
	local nx, ny, nz = n:Unpack()
	local ux, uy, uz = Uax:Unpack()
	local vx, vy, vz = ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux   -- n x U
	local u0, u1, v0, v1 = -1, 1, -1, 1
	if not noClip and (hu > CLIP_MIN or hv > CLIP_MIN) and ClipBudget(4) then
		u0, u1 = ClipAxis(pos, n, Uax, hu)
		v0, v1 = ClipAxis(pos, n, Vector(vx, vy, vz), hv)
	end
	local isFoot = (cell == 9 or cell == 10 or cell == 11 or cell == 12)
	local aEff = isFoot and math.Clamp(alpha, 0, 1) or math.Clamp(math.max(alpha or 0.95, 0.94), 0, 1)
	local hEff = isFoot and h or math.max(h or 0.4, 0.42)
	local s = { x = px, y = py, z = pz, nx = nx, ny = ny, nz = nz, ux = ux, uy = uy, uz = uz,
		vx = vx, vy = vy, vz = vz, hu = hu, hv = hv, u0 = u0, u1 = u1, v0 = v0, v1 = v1,
		cell = cell, flip = flip and -1 or 1, a = aEff,
		h = hEff, vol = vol or 0, btype = btype or 0, oxy = oxy or 0.75, t = now }
	s.wetUntil = now + DryTime() * (wetMul or 1) * math.Clamp(0.35 + hEff * 0.8, 0.35, 1.6)
	s.wr, s.wg, s.wb = L.WetTint(s.btype, s.oxy, hEff)
	s.dr, s.dg, s.db = L.DryTint(s.btype, hEff)
	s.lr, s.lg, s.lb = L.Diffuse(s.btype, s.oxy, hEff, L.Light(pos, n))
	s.shine = math.Clamp(0.35 + hEff * 0.6, 0.35, 1)
	local o = L.open
	if #o.list == 0 then o.t0 = now end
	o.list[#o.list + 1] = s
	if vol and vol >= 15 then HashAdd(s) end
	L.stats.stains = L.stats.stains + 1
	-- (1.26.8) baked in L.Update, once a frame (here: in the middle of a landing or a rivulet step, a spike there), and
	-- here only past twice the batch size
	if #o.list >= L.BATCH_N * 2 then L.Bake() end
	return s
end
L.NewStain = NewStain

local CS = { -1, 1, 1, -1 }
local CT = { -1, -1, 1, 1 }
local function Corners(s, fn)
	local off = 0.04
	local cx, cy, cz = s.x + s.nx * off, s.y + s.ny * off, s.z + s.nz * off
	local ux, uy, uz = s.ux * s.hu, s.uy * s.hu, s.uz * s.hu
	local fl = s.flip
	local vx, vy, vz = s.vx * s.hv, s.vy * s.hv, s.vz * s.hv
	local u0, u1 = s.u0 or -1, s.u1 or 1
	local v0, v1 = s.v0 or -1, s.v1 or 1
	local uv = CELL_UV[s.cell]
	for k = 1, 4 do
		local a = CS[k] < 0 and u0 or u1
		local bRaw = CT[k]
		local bWorld = (bRaw * fl) < 0 and v0 or v1
		local bUV = bWorld * fl
		fn(cx + ux * a + vx * bWorld, cy + uy * a + vy * bWorld, cz + uz * a + vz * bWorld,
			uv[1] + (a + 1) * 0.125, uv[2] + (1 - bUV) * 0.125)
	end
end

-- (1.26.8) 128 stains or 1 s a batch (192 or 2 s): the stains not baked yet are built again every frame, twice
local BATCH_N, BATCH_T = 128, 1.0
L.BATCH_N = BATCH_N
-- (1.26.8) a stain's four corners straight into the mesh being built (no closure, no tables)
local evpos, evnrm = Vector(), Vector()
local function Emit(s, r, g, b, a, withNormal)
	local off = 0.04
	local cx, cy, cz = s.x + s.nx * off, s.y + s.ny * off, s.z + s.nz * off
	local ux, uy, uz = s.ux * s.hu, s.uy * s.hu, s.uz * s.hu
	local fl = s.flip
	local vx, vy, vz = s.vx * s.hv, s.vy * s.hv, s.vz * s.hv
	local u0, u1 = s.u0 or -1, s.u1 or 1
	local v0, v1 = s.v0 or -1, s.v1 or 1
	local uv = CELL_UV[s.cell]
	local mPos, mTC, mCol, mAdv = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex
	if withNormal then evnrm:SetUnpacked(s.nx, s.ny, s.nz) end
	for k = 1, 4 do
		local ea = CS[k] < 0 and u0 or u1
		local bWorld = (CT[k] * fl) < 0 and v0 or v1
		local bUV = bWorld * fl
		evpos:SetUnpacked(cx + ux * ea + vx * bWorld, cy + uy * ea + vy * bWorld, cz + uz * ea + vz * bWorld)
		mPos(evpos)
		if withNormal then mesh.Normal(evnrm) end
		mTC(0, uv[1] + (ea + 1) * 0.125, uv[2] + (1 - bUV) * 0.125)
		mCol(r, g, b, a)
		mAdv()
	end
end
L.Emit = Emit
local function BuildMesh(mat, list, shinePass, dry)
	local cnt = #list
	if cnt == 0 then return nil end
	local m = Mesh(mat)
	mesh.Begin(m, MATERIAL_QUADS, cnt)
	local ok, err = pcall(function()
		for i = 1, cnt do
			local s = list[i]
			if shinePass then Emit(s, s.lr or 0, s.lg or 0, s.lb or 0, s.shine * s.a * 255, true)
			elseif dry then Emit(s, s.dr, s.dg, s.db, s.a * 255, true)
			else Emit(s, s.wr, s.wg, s.wb, s.a * 255, true) end
		end
	end)
	mesh.End()
	if not ok then
		if m.Destroy then m:Destroy() end
		ErrorNoHalt("[GHMPB] lite batch: " .. tostring(err) .. "\n")
		return nil
	end
	return m
end

local function Bounds(list)
	local mn = Vector(math.huge, math.huge, math.huge)
	local mx = Vector(-math.huge, -math.huge, -math.huge)
	for _, s in ipairs(list) do
		local r = max(s.hu, s.hv)
		mn.x, mn.y, mn.z = min(mn.x, s.x - r), min(mn.y, s.y - r), min(mn.z, s.z - r)
		mx.x, mx.y, mx.z = max(mx.x, s.x + r), max(mx.y, s.y + r), max(mx.z, s.z + r)
	end
	return (mn + mx) * 0.5, (mx - mn):Length() * 0.5
end

local function DestroyBatch(bt)
	if bt.mod then bt.mod:Destroy() bt.mod = nil end
	if bt.shine then bt.shine:Destroy() bt.shine = nil end
	for _, s in ipairs(bt.list) do HashRemove(s) end
end

local function Bake()
	local o = L.open
	if #o.list == 0 then return end
	local mod, shine = Mats()
	local list = o.list
	L.open = { list = {}, t0 = CurTime() }
	local c, r = Bounds(list)
	local dryAt = 0
	for _, s in ipairs(list) do dryAt = max(dryAt, s.wetUntil) end
	local bt = { list = list, center = c, radius = r, dryAt = dryAt, wet = true, n = #list }
	bt.mod = BuildMesh(mod, list, false, false)
	bt.shine = BuildMesh(shine, list, true, false)
	L.batches[#L.batches + 1] = bt
	local cap = G.cv.litemax and G.cv.litemax:GetInt() or 3000
	local total = 0
	for _, b in ipairs(L.batches) do total = total + b.n end
	while total > cap and #L.batches > 1 do
		local old = table.remove(L.batches, 1)
		total = total - old.n
		DestroyBatch(old)
	end
end

L.Bake = Bake

local function DryBatches(now)
	local mod = Mats()
	for _, bt in ipairs(L.batches) do
		if bt.wet and now >= bt.dryAt then
			bt.wet = false
			if bt.mod then bt.mod:Destroy() end
			if bt.shine then bt.shine:Destroy() bt.shine = nil end
			bt.mod = BuildMesh(mod, bt.list, false, true)
			return
		end
	end
end

-- ---------------------------------------------------------------- pools
-- (1.26.7) a pool is an outline that grows: 24 directions from where the blood landed, each with its own radius. The
-- volume decides the area (about 1.6 mm deep); the growth goes to the directions that are still free, more downhill on a
-- tilted floor and a little uneven (no two pools the same shape). Each direction is felt ahead with traces: where the
-- floor ends (a ledge, a step) or something stands in the way (a wall, a prop), that direction stops and the blood goes
-- round it, so pools fill corners and run along walls. Pools that grow into each other join into one outline. It is drawn
-- as rings, thicker (darker) towards the middle with a soft edge, wet and glossy at first; as it dries the rim goes
-- first and turns darker (the ring dried blood leaves), the shine fades from the edge inward. Drops landing in it make
-- ripples.
local POOL_H = 1.6
local POOL_MAX = 96
local NDIR = 24
local DTH = 6.2831853 / NDIR
local COS, SIN = {}, {}
for i = 1, NDIR do local a = (i - 1) * DTH COS[i], SIN[i] = math.cos(a), math.sin(a) end
L.POOL_NDIR = NDIR
local function PoolTarget(vol) return sqrt(max(vol, 0) / (math.pi * POOL_H)) * MM + 0.4 end

local function PoolDir(p, i) return p.U * COS[i] + p.V * SIN[i] end
local function PoolArea(p)
	local a = 0
	local rr = p.rr
	for i = 1, NDIR do a = a + rr[i] * rr[i] end
	return 0.5 * a * DTH
end
L.PoolArea = PoolArea
local function RadiusAt(p, ang)
	local x = (ang % 6.2831853) / DTH
	local fl = floor(x)
	local i0 = fl % NDIR + 1
	local i1 = i0 % NDIR + 1
	local f = x - fl
	return p.rr[i0] * (1 - f) + p.rr[i1] * f
end
-- the outline's radius towards a world point
local function PoolReach(p, pos)
	local d = pos - p.pos
	return RadiusAt(p, math.atan2(d:Dot(p.V), d:Dot(p.U)))
end
L.PoolReach = PoolReach
local function PoolStats(p)
	local mx = 0
	for i = 1, NDIR do if p.rr[i] > mx then mx = p.rr[i] end end
	p.rMax = mx
	p.r = sqrt(PoolArea(p) / math.pi)
end

-- (1.26.8) with plain numbers kept on each pool (its middle cx.., its normal kx..): every landing on a floor went through every pool with
-- Vector calls (up to 96 pools, five calls each)
local function PoolNums(p)
	local ps, pn = p.pos, p.n
	p.cx, p.cy, p.cz = ps.x, ps.y, ps.z
	p.kx, p.ky, p.kz = pn.x, pn.y, pn.z
end
local function PoolAt(pos, n, reach)
	local best, bd
	reach = reach or 0
	local x, y, z = pos.x, pos.y, pos.z
	local nx, ny, nz = n.x, n.y, n.z
	for _, p in ipairs(L.pools) do
		if not p.cx then PoolNums(p) end
		if p.kx * nx + p.ky * ny + p.kz * nz > 0.95 then
			local dx, dy, dz = x - p.cx, y - p.cy, z - p.cz
			if abs(dx * p.kx + dy * p.ky + dz * p.kz) < 2 then
				local lim = p.rMax + reach
				local d2 = dx * dx + dy * dy + dz * dz
				if d2 < lim * lim then
					local edge = sqrt(d2) - PoolReach(p, pos)
					if edge < reach and (not bd or edge < bd) then best, bd = p, edge end
				end
			end
		end
	end
	return best
end

local function PoolAdd(p, vol, btype, oxy)
	local v0 = p.vol
	p.vol = p.vol + vol
	p.tv[btype or 0] = (p.tv[btype or 0] or 0) + vol
	local bt, bv = p.btype, -1
	for t, v in pairs(p.tv) do if v > bv then bt, bv = t, v end end
	p.btype = bt
	p.oxy = ((p.oxy or 0.75) * v0 + (oxy or 0.75) * vol) / math.max(p.vol, 1e-3)
	p.rT = math.min(PoolTarget(p.vol), 90)
	p.tAdd = CurTime()
	p.wetUntil = p.tAdd + DryTime() * 1.5
	p.dirty = true
end

local function DestroyPoolMesh(p)
	if p.mesh then p.mesh:Destroy() p.mesh = nil end
	if p.smesh then p.smesh:Destroy() p.smesh = nil end
end

local function PoolToStain(p)
	DestroyPoolMesh(p)
	local h = math.Clamp(p.vol / (math.pi * (p.r / MM) ^ 2), 0.05, 3)
	local s = NewStain(p.pos, p.n, p.U, p.r / BODY[6], p.r / BODY[6], 6, p.flip, 0.97, h, p.vol, p.btype, p.oxy)
	s.wetUntil = p.wetUntil
	L.stats.pools = L.stats.pools - 1
end

local function RemovePool(p)
	for x, pp in ipairs(L.pools) do if pp == p then table.remove(L.pools, x) break end end
	DestroyPoolMesh(p)
end

local function NewPool(pos, n, vol, btype, oxy, r0)
	if #L.pools >= POOL_MAX then
		local idx, oldest = nil, math.huge
		for i, p in ipairs(L.pools) do if p.tAdd < oldest then idx, oldest = i, p.tAdd end end
		if idx then PoolToStain(table.remove(L.pools, idx)) end
	end
	local initR = math.Clamp((r0 or 0.4) * 0.22, 0.16, 0.42)
	local U0 = Tangent(n)
	local p = { pos = Vector(pos), n = Vector(n), U = U0, V = n:Cross(U0), vol = 0, r = initR, rMax = initR, rT = 0, tv = {},
		btype = btype or 0, oxy = oxy or 0.75, t0 = CurTime(), flip = math.random() < 0.5,
		rr = {}, lim = {}, ok = {}, hz = {}, nz = {} }
	-- an uneven outline: smoothed random weights round the circle
	local raw = {}
	for i = 1, NDIR do raw[i] = math.random() - 0.5 end
	do
		local sm = {}
		for i = 1, NDIR do sm[i] = (raw[(i - 2) % NDIR + 1] + 2 * raw[i] + raw[i % NDIR + 1]) * 0.25 end
		raw = sm
	end
	-- a few broad lobes (2 and 3 round the circle, turned at random) on top of the finer unevenness
	local f2, f3 = math.random() * 6.2832, math.random() * 6.2832
	local a2, a3 = 0.2 + math.random() * 0.15, 0.1 + math.random() * 0.15
	for i = 1, NDIR do
		local a = (i - 1) * DTH
		p.rr[i], p.lim[i], p.ok[i], p.hz[i] = initR, math.huge, initR + 0.6, 0
		p.nz[i] = a2 * math.cos(2 * a + f2) + a3 * math.cos(3 * a + f3) + raw[i] * 1.2
	end
	-- the slope: on a tilted floor the blood runs downhill
	local down = Vector(0, 0, -1) - n * (-n.z)
	local sl = down:Length()
	if sl > 0.03 then p.down, p.slope = down / sl, math.Clamp(sl * 2.5, 0, 1) end
	PoolAdd(p, vol, btype, oxy)
	p.plane = PlaneKey(n, pos)
	L.pools[#L.pools + 1] = p
	L.stats.pools = L.stats.pools + 1
	return p
end

local fitOut = {}
local fitTr = { mask = MASK_SOLID, filter = function(e) return G.Surfaces.GroundFilter(e) end, output = fitOut }   -- (1.26.8) as stainTr
-- floor under the outline at distance d in direction i (at the pool's height), and nothing standing in the way
local function FloorOK(p, i, d)
	local dir = PoolDir(p, i)
	local q = p.pos + dir * d
	fitTr.start = q + p.n * 3
	fitTr.endpos = q - p.n * 3
	local tr = util.TraceLine(fitTr) or fitOut
	if not (tr.Hit and not tr.StartSolid and tr.HitNormal:Dot(p.n) > 0.9 and abs((tr.HitPos - p.pos):Dot(p.n)) < 1.2) then return false end
	local hz = (tr.HitPos - p.pos):Dot(p.n)
	fitTr.start = p.pos + p.n * 0.6 + dir * math.max(p.ok[i] - 0.4, 0)
	fitTr.endpos = q + p.n * 0.6
	local tw = util.TraceLine(fitTr) or fitOut
	if tw.Hit or tw.StartSolid then return false end
	return true, hz
end

local traceLeft = 0
local function GrowPool(p, k)
	local At = math.pi * p.rT * p.rT
	local A = PoolArea(p)
	if A >= At * 0.998 then return end
	local rr, lim, ok = p.rr, p.lim, p.ok
	-- feel ahead in the directions whose edge has reached the floor known so far
	for i = 1, NDIR do
		if traceLeft <= 0 then break end
		if rr[i] < lim[i] and rr[i] > ok[i] - 0.35 then
			local d = math.min(ok[i] + math.max(1.5, 0.25 * ok[i]), p.rT * 2.5 + 2)
			if d > ok[i] + 0.05 then
				traceLeft = traceLeft - 2
				local good, hz = FloorOK(p, i, d)
				if good then
					ok[i], p.hz[i] = d, hz
				else
					-- where exactly the floor ends or the wall stands: two halvings between the last good distance and d
					local lo, hi = ok[i], d
					for _ = 1, 2 do
						local mid = (lo + hi) * 0.5
						local g2, h2 = FloorOK(p, i, mid)
						if g2 then lo, p.hz[i] = mid, h2 else hi = mid end
					end
					traceLeft = traceLeft - 4
					ok[i] = lo
					lim[i] = math.max(lo, rr[i])
				end
			else
				lim[i] = math.max(ok[i], rr[i])
			end
		end
	end
	-- grow into the free directions
	local w, wsum = p.w or {}, 0
	p.w = w
	local dU, dV = 0, 0
	if p.down then dU, dV = p.down:Dot(p.U), p.down:Dot(p.V) end
	for i = 1, NDIR do
		local room = math.min(lim[i], ok[i]) - rr[i]
		if room > 0.005 then
			local wi = exp(1.4 * p.nz[i])
			if p.down then wi = wi * (1 + 4 * p.slope * math.max(0, COS[i] * dU + SIN[i] * dV)) end
			w[i] = math.max(wi, 0.05)
		else
			w[i] = 0
		end
		wsum = wsum + w[i]
	end
	if wsum <= 0 then return end
	local dA = (At - A) * k
	for i = 1, NDIR do
		if w[i] > 0 then
			local dr = dA * w[i] / wsum / (math.max(rr[i], 0.25) * DTH)
			rr[i] = math.min(rr[i] + dr, lim[i], ok[i])
		end
	end
	-- no spikes: each free direction leans a little towards its neighbours
	local sm = p.sm or {}
	p.sm = sm
	for i = 1, NDIR do sm[i] = rr[i] end
	for i = 1, NDIR do
		local a, b = sm[(i - 2) % NDIR + 1], sm[i % NDIR + 1]
		local v = sm[i] + 0.04 * ((a + b) * 0.5 - sm[i])
		rr[i] = math.max(math.min(v, lim[i], ok[i]), 0.05)
	end
	p.dirty = true
end

-- is a point inside a pool's outline (on its plane)?
local function Inside(p, pos)
	local d = pos - p.pos
	return d:Length() <= PoolReach(p, pos)
end
-- the bigger pool takes the smaller in: its outline becomes the outline of both, seen from its own middle
local function Join(big, small)
	local dist = big.pos:Distance(small.pos)
	for i = 1, NDIR do
		local dir = PoolDir(big, i)
		local far = big.rr[i]
		local reach = dist + small.rMax
		local step = math.max(reach / 32, 0.4)
		local t = far
		while t <= reach do
			if Inside(small, big.pos + dir * t) then far = t end
			t = t + step
		end
		if far > big.rr[i] then
			big.rr[i] = far
			big.ok[i] = math.max(big.ok[i], far)
			if big.lim[i] < far then big.lim[i] = math.huge end
		end
	end
	PoolAdd(big, small.vol, small.btype, small.oxy)
	PoolStats(big)
	RemovePool(small)
	L.stats.merged = L.stats.merged + 1
	L.stats.pools = L.stats.pools - 1
end

-- do two outlines touch (within half a unit: blood that close runs together)?
local function Touch(p, q)
	local d = q.pos:Distance(p.pos)
	if d > p.rMax + q.rMax + 0.5 then return false end
	if d < PoolReach(p, q.pos) + PoolReach(q, p.pos) + 0.5 then return true end
	for _, pair in ipairs({ { p, q }, { q, p } }) do
		local a, b = pair[1], pair[2]
		for i = 1, NDIR do
			local v = b.pos + PoolDir(b, i) * b.rr[i]
			if v:Distance(a.pos) <= PoolReach(a, v) + 0.5 then return true end
		end
	end
	return false
end
local function MergePools(now)
	for _, p in ipairs(L.pools) do
		if (p.mergeT or 0) < now then
			p.mergeT = now + 0.25
			for _, q in ipairs(L.pools) do
				if q ~= p and q.plane == p.plane then
					if Touch(p, q) then
						if q.vol > p.vol then Join(q, p) else Join(p, q) end
						return
					end
				end
			end
		end
	end
end

local rr0 = 0
-- (1.26.8) how many pools grow a frame (each with the time since its own last step): 1.26.7 stepped every pool every
-- frame. Players: "laggy since the update, fighting loads of NPCs, even on low" (cl_governor.lua V.Detail)
local GROW_PER_FRAME = 24
local function Detail()
	if G.Gov and G.Gov.Detail then return G.Gov.Detail() end
	return 1, 0
end
local function GrowPools(dt)
	local n = #L.pools
	if n == 0 then return end
	local now = CurTime()
	local tau = 1.8 * math.Clamp(G.cv.viscosity:GetFloat(), 0.3, 4)
	traceLeft = floor(32 + 64 * Detail())
	local m = math.min(n, math.max(6, math.floor(GROW_PER_FRAME * (0.4 + 0.6 * Detail()))))
	rr0 = rr0 % n + 1
	for c = 0, m - 1 do
		local p = L.pools[(rr0 + c - 1) % n + 1]
		local pdt = math.Clamp(now - (p.growT or (now - dt)), 0, 0.5)
		p.growT = now
		if pdt > 0 then
			GrowPool(p, 1 - exp(-pdt / tau))
			PoolStats(p)
		end
	end
	rr0 = (rr0 + m - 2) % n + 1
	MergePools(now)
end

-- ripples: drops landing in a pool
-- (1.26.8) none any more: GHM, "when giving a headshot there is a water ripple particle effect, big one and small,
-- please remove that" (white rings spreading over the pool as the blood dripped into it). L.RIPPLES = true brings them back
L.ripples = L.ripples or {}
L.RIPPLES = false
local function Ripple(p, pos, size)
	if not L.RIPPLES then return end
	if #L.ripples >= 32 then table.remove(L.ripples, 1) end
	L.ripples[#L.ripples + 1] = { pos = pos + p.n * 0.12, n = p.n, U = p.U, V = p.V, t0 = CurTime(),
		R = math.Clamp(size, 0.4, 3), life = 0.55 + math.random() * 0.25, p = p }
end

local function PseudoPatch(pos, n, sf, kindName, tr)
	local u, v = Basis(n)
	return { N = n, plane = PlaneKey(n, pos), surf = sf, surfName = kindName, U = u, V = v, albedoTex = tr and tr.HitTexture,
		center = pos, origin = pos }
end

local recentCells, recentT = {}, 0
local function Crowded(px, py, pz, vol)
	local now = CurTime()
	if now - recentT > 1 then recentCells, recentT = {}, now end
	local k = ((floor(px / 6) + 65536) * 131072 + (floor(py / 6) + 65536)) * 131072 + (floor(pz / 6) + 65536)
	local c = (recentCells[k] or 0) + 1
	recentCells[k] = c
	return c > 6 and vol < 40
end

local pcPos = Vector()
function L.WorldImpact(pos, normal, vel, radiusU, volume, kind, spin, stretch, residue, tr, oxy, btype, extra)
	if not G.cv.enable:GetBool() or not G.cv.pools:GetBool() then return false end
	if not pos or not normal then return false end
	if tr and IsValid(tr.Entity) and not tr.Entity:IsWorld() and not G.Surfaces.IsGround(tr.Entity) then
		if kind == 4 then return false end
		local ek = (kind == 3 or kind == 5 or kind == 7) and 0 or (kind or 0)
		return L.BodyImpact(tr.Entity, pos, normal, vel, radiusU, volume, ek, spin, stretch, residue, nil,
			{ oxy = oxy, btype = btype, K = extra and extra.K, flags = extra and extra.flags, spines = extra and extra.spines })
	end
	if (kind == 3 or kind == 5 or kind == 7) and G.Surfaces and G.Surfaces.ClipStroke then
		pos, vel, radiusU = G.Surfaces.ClipStroke(pos, normal, vel, radiusU)
	end
	kind = kind or 0
	volume = volume or 0
	vel = vel or vector_origin
	radiusU = math.max(radiusU or 0.2, 0.05)
	local n = normal:GetNormalized()
	if kind == 0 then vel, stretch = U.SplatShape(vel, n, stretch) end
	local kindName = tr and G.SurfaceKindOf(tr) or "sealed"
	local sf = G.Surface[kindName] or G.Surface.sealed
	local carries = kind <= 2 or kind == 6
	if sf.nostain then
		if carries and G.Water then G.Water.Enter(pos + n * 0.3, vel, volume, btype, oxy) end
		return true
	end
	local px, py, pz = pos:Unpack()
	local nx, ny, nz = n:Unpack()
	pcPos:SetUnpacked(px + nx * 0.5, py + ny * 0.5, pz + nz * 0.5)
	if bit.band(util.PointContents(pcPos), bit.bor(CONTENTS_WATER, CONTENTS_SLIME)) ~= 0 then
		if carries and G.Water then G.Water.Enter(pos + n * 0.5, vel, volume, btype, oxy) end
		return true
	end
	if kind == 4 then return true end
	if sf.drain and n.z > 0.3 and volume > 0 and (kind == 0 or kind == 1 or kind == 6) then
		local through = volume * sf.drain
		volume = volume - through
		if through > 3 and G.Particles and G.Particles.Drips then
			G.Particles.Drips(pos - n * 2.5, Vector(vel.x * 0.3, vel.y * 0.3, math.min(vel.z * 0.4, -20)), through, nil, oxy, btype)
		end
		if volume < 1 then return true end
	end
	if (kind == 0 or kind == 1) and G.Runs and volume > 1 and nz <= 0.966 and nz >= -0.35 then
		local taken = G.Runs.Feed(PseudoPatch(pos, n, sf, kindName, tr), pos, volume, radiusU, kind, tr, oxy, btype)
		if taken > 0 then
			volume = volume - taken
			if volume < 0.05 then return true end
		end
	end
	if carries and volume >= 30 and G.Flies and G.Flies.Note then G.Flies.Note(pos, volume, radiusU, pos) end
	btype = btype or 0
	local wetMul = 1
	if (sf.fabric or 0) >= 0.5 then wetMul = 0.5 end
	local sp = vel:Length()
	local floorish = nz > 0.7
	if kind == 1 then
		if floorish and volume >= 4 then
			local p = PoolAt(pos, n, radiusU + 1.5)
			if p then PoolAdd(p, volume, btype, oxy) Ripple(p, pos, radiusU * 1.5 + 0.8) else NewPool(pos, n, volume, btype, oxy, radiusU) end
			return true
		end
		local rs = math.Clamp(sqrt(volume / (math.pi * 0.4)) * MM, radiusU, 30)
		NewStain(pos, n, Tangent(n), rs / BODY[6], rs / BODY[6], 6, math.random() < 0.5, 0.9, 0.4, volume, btype, oxy, wetMul)
		return true
	end
	if kind == 0 or kind == 2 then
		if floorish then
			local p = PoolAt(pos, n, 0)
			if p then PoolAdd(p, volume, btype, oxy) Ripple(p, pos, radiusU * 2.2) return true end
		end
		if Crowded(px, py, pz, volume) then L.stats.skipped = L.stats.skipped + 1 return true end
		local sinA = sp > 1e-3 and abs(vel:Dot(n)) / sp or 1
		local rs = radiusU
		local h = math.Clamp(volume / (math.pi * (rs / MM) ^ 2), 0.02, 2)
		local e = math.min(math.Clamp(1 / math.max(sinA, 0.15), 1, 6) * math.Clamp(stretch or 1, 1, 4), 8, G.cv.streak and G.cv.streak:GetFloat() or 8)
		if e > 1.5 then
			local t = Tangent(n, vel)
			local c = L.CELL.oblique[math.random(1, 2)]
			NewStain(pos, n, t, rs * e / OBLIQUE_LEN, rs / BODY[c], c, math.random() < 0.5, 0.95, h, volume, btype, oxy, wetMul)
		else
			-- (1.26.7) any of the droplet shapes, each a little squashed one way or the other (players: "only two or three
			-- textures for the spatter")
			local c
			if sp < 140 then c = (math.random() < 0.5) and L.CELL.small or ({ 0, 1, 3 })[math.random(1, 3)]
			elseif sp < 420 then c = ({ 0, 1, 2, 3, L.CELL.small })[math.random(1, 5)]
			else c = ({ 0, 1, 2, 2 })[math.random(1, 4)] end
			local sq = 0.88 + math.random() * 0.24
			NewStain(pos, n, Tangent(n), rs / BODY[c] * sq, rs / BODY[c] / sq, c, math.random() < 0.5, 0.95, h, volume, btype, oxy, wetMul)
		end
		return true
	end
	if kind == 3 or kind == 7 then
		local L0 = vel:Length()
		local c = kind == 7 and L.CELL.run or L.CELL.smear
		local t = Tangent(n, L0 > 0.05 and vel or nil)
		local half = L0 * 0.5
		local w = radiusU
		local h = math.Clamp(volume / (math.max(L0, 0.5) * 2 * w / (MM * MM)), 0.01, 1.5)
		local alpha = math.Clamp(0.35 + h * 2.5, 0.3, 0.95)
		NewStain(pos + vel * 0.5, n, t, half + w * 0.8, w / BODY[c], c, math.random() < 0.5, alpha, h, volume, btype, oxy, wetMul, kind == 7)
		return true
	end
	if kind == 5 then
		local side = spin or 1
		local as = abs(side)
		local fresh = math.Clamp(stretch or 1, 0, 1)
		local alpha = math.Clamp(0.05 + 0.88 * (fresh ^ 1.15), 0.04, 0.95)
		local h = 0.004 + 0.11 * fresh
		if as == 3 then
			local L0 = vel:Length()
			NewStain(pos + vel * 0.5, n, Tangent(n, L0 > 0.05 and vel or nil), L0 * 0.5 + radiusU * 0.3, radiusU / BODY[12], 12, false,
				alpha, h, volume, btype, oxy, wetMul)
			return true
		end
		local c = (as == 2 and L.CELL.hand) or (as >= 4 and L.CELL.pad) or L.CELL.shoe
		local hl = radiusU / BODY[c]
		NewStain(pos, n, Tangent(n, vel), hl, hl, c, side > 0, alpha, h, volume, btype, oxy, wetMul)
		return true
	end
	if kind == 6 then
		local R = math.Clamp(radiusU, 1, 40)
		local alpha = math.Clamp(0.2 + volume / (R * R * 25), 0.2, 0.85)
		NewStain(pos, n, Tangent(n), R / BODY[13], R / BODY[13], 13, math.random() < 0.5, alpha, 0.05, volume, btype, oxy, wetMul)
		return true
	end
	return true
end

function L.DepthAt(pos)
	local now = CurTime()
	local best, bt, ox = 0, nil, nil
	for _, p in ipairs(L.pools) do
		local d = pos:Distance(p.pos)
		if d < p.r and abs((pos - p.pos):Dot(p.n)) < 4 then
			local wet = math.Clamp((p.wetUntil - now) / (DryTime() * 0.5), 0, 1)
			local h = math.Clamp(p.vol / (math.pi * (p.r / MM) ^ 2), 0, 3) * wet * math.Clamp((p.r - d) / 1.5, 0.2, 1)
			if h > best then best, bt, ox = h, p.btype, p.oxy end
		end
	end
	local cx, cy = floor(pos.x / HC), floor(pos.y / HC)
	for dx = -1, 1 do
		for dy = -1, 1 do
			local l = L.hash[(cx + dx) * 65536 + (cy + dy)]
			if l then
				for _, s in ipairs(l) do
					if s.cell ~= L.CELL.shoe and s.cell ~= L.CELL.pad and s.cell ~= L.CELL.hand and s.cell ~= 12 then
						local ex, ey, ez = pos.x - s.x, pos.y - s.y, pos.z - s.z
						local r = math.min(s.hu, s.hv) * 0.6
						if ex * ex + ey * ey + ez * ez < r * r and now < s.wetUntil then
							local h = s.h * math.Clamp((s.wetUntil - now) / (DryTime() * 0.3), 0, 1)
							if h > best then best, bt, ox = h, s.btype, s.oxy end
						end
					end
				end
			end
		end
	end
	return best, bt, ox
end

function L.RequestProbe(ps, cp, n)
	local h, bt, ox = L.DepthAt(cp)
	ps.h, ps.s, ps.frost, ps.hT = h, h > 0 and 0.02 or 0, 0, CurTime()
	ps.oxy, ps.btype, ps.live = ox or 0.75, bt or 0, true
end

local grid, gridT = {}, -1
function L.Grid(now)
	now = now or CurTime()
	if now - gridT < 1 and gridT >= 0 then return grid end
	gridT = now
	grid = {}
	local P = G.Surfaces.PATCH_UNITS or 40
	local function mark(x, y, r)
		for gx = floor((x - r) / P), floor((x + r) / P) do
			for gy = floor((y - r) / P), floor((y + r) / P) do grid[gx .. ":" .. gy] = true end
		end
	end
	for _, p in ipairs(L.pools) do if p.wetUntil > now then mark(p.pos.x, p.pos.y, p.r) end end
	for _, l in pairs(L.hash) do
		for _, s in ipairs(l) do if s.wetUntil > now then mark(s.x, s.y, 1) end end
	end
	return grid
end
function L.NearBlood(pos, r)
	local P = G.Surfaces.PATCH_UNITS or 40
	local cx, cy = floor(pos.x / P), floor(pos.y / P)
	r = r or 1
	for dx = -r, r do
		for dy = -r, r do
			if grid[(cx + dx) .. ":" .. (cy + dy)] then return true end
		end
	end
	return false
end

local SHAPE = { wound = "bwound", splat = "bsplat", drip = "bdrip", mist = "bmist" }
local DECAL_BASE = 4
local decalMats = {}
local REFR = { [0] = 105, 150, 120, 95, 130, 60, 110, 110 }
local function DecalMat(shape, bt)
	bt = (bt and bt >= 0 and bt <= 7) and bt or 0
	local key = shape .. bt
	local m = decalMats[key]
	if not m then
		if bt <= 3 then
			m = Material("ghm_physblood/lite/" .. SHAPE[shape] .. "_" .. bt)
		else
			m = CreateMaterial("ghmpb_lite_" .. SHAPE[shape] .. "_" .. bt, "VertexLitGeneric", {
				["$basetexture"] = "ghm_physblood/lite/" .. SHAPE[shape],
				["$decal"] = "1",
				["$translucent"] = "1",
				-- (1.26.7) splat 256 px, mist 1024 px (the CRB splat at its own resolution), the same size on the body
				["$decalscale"] = shape == "mist" and "0.00390625" or (shape == "splat" and "0.015625" or "0.03125"),
				["$color2"] = "[0.150 0.004 0.003]",
			})
		end
		decalMats[key] = m
	end
	local r, g, b = U.BloodColour(bt, 0.6, REFR[bt] or 105)
	local function lin(c) c = c / 255 return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
	local want = Vector(lin(r), lin(g), lin(b))
	local cur = m:GetVector("$color2")
	if not cur or abs(cur.x - want.x) + abs(cur.y - want.y) + abs(cur.z - want.z) > 0.004 then m:SetVector("$color2", want) end
	return m
end

-- (1.26.8) model decals a frame (the engine projects each onto the model's triangles): 2 to 8 by the detail level, past
-- that the splats, mist and runs on bodies wait (wounds always go on)
local decF, decLeft = -1, 0
local function DecalOK()
	local f = FrameNumber()
	if f ~= decF then decF, decLeft = f, floor(2 + 6 * GovDetail()) end
	if decLeft <= 0 then L.stats.decalsDeferred = (L.stats.decalsDeferred or 0) + 1 return false end
	decLeft = decLeft - 1
	return true
end
L.DecalOK = DecalOK
local function Decal(ent, shape, bt, pos, n, size)
	local s = math.Clamp(size, 0.3, 12) / DECAL_BASE
	local t0 = SysTime()
	local ok = pcall(util.DecalEx, DecalMat(shape, bt), ent, pos, n, color_white, s, s)
	-- (1.26.8) in ghmpb_prof: what the model decals cost
	local P = G.Prof
	if P and P.Add then P.Add(".lite model decals", (SysTime() - t0) * 1000) P.Count(".lite model decals") end
	if ok then L.stats.bodyDecals = L.stats.bodyDecals + 1 else L.stats.decalErrors = L.stats.decalErrors + 1 end
	return ok
end

function L.Body(ent, create)
	local b = L.bodies[ent]
	if b or not create then return b end
	local bt = G.BloodTypeOf(ent)
	b = { oxy = 0.75, btype = (type(bt) == "number") and bt or 0, recs = {}, flows = {}, nflows = 0, recent = {}, lite = true }
	L.bodies[ent] = b
	return b
end

local REC_MAX = 30
local function Record(b, ent, bone, pos, n, shape, size, bt, keep)
	local lp, ln = U.BoneToLocal(ent, bone, pos, n)
	if not lp then return end
	local r = b.recs
	r[#r + 1] = { bone = bone, lp = lp, ln = ln, shape = shape, size = size, bt = bt, keep = keep }
	if #r > REC_MAX then
		for i = 1, #r do if not r[i].keep then table.remove(r, i) break end end
		if #r > REC_MAX then table.remove(r, 1) end
	end
end

-- (1.26.8) a body's decals put on its ragdoll over the next frames, the wounds first: all at once it was up to 30 model
-- decals in one frame for every body that died (a fight's deaths: long frames with Lite)
L.reshootQ = L.reshootQ or {}
function L.Reshoot(ent, b)
	if not IsValid(ent) or not b then return end
	if ent.RemoveAllDecals then ent:RemoveAllDecals() end
	local q = L.reshootQ
	for _, r in ipairs(b.recs) do if r.keep then q[#q + 1] = { ent, r } end end
	for _, r in ipairs(b.recs) do if not r.keep then q[#q + 1] = { ent, r } end end
end
local function ReshootStep()
	local q = L.reshootQ
	local m = #q
	if m == 0 then return end
	local n = math.min(m, floor(6 + 10 * GovDetail()))
	for k = 1, n do
		local ent, r = q[k][1], q[k][2]
		if IsValid(ent) then
			local p, nn = U.BoneToWorld(ent, r.bone, r.lp, r.ln)
			if p and nn then Decal(ent, r.shape, r.bt, p, nn, r.size) end
		end
	end
	for k = 1, m - n do q[k] = q[k + n] end
	for k = m - n + 1, m do q[k] = nil end
end
L.ReshootStep = ReshootStep

function L.Transfer(from, to)
	local b = L.bodies[from]
	if not b or not IsValid(to) then return end
	L.bodies[to] = b
	L.bodies[from] = nil
	timer.Simple(0.06, function() if IsValid(to) then if to.SetupBones then to:SetupBones() end L.Reshoot(to, b) end end)
end

local SEG = 30
local RUN_MAX = 24
local function DripOff(ent, f, vol, b)
	local p, n = U.BoneToWorld(ent, f.bone, f.lp, f.ln)
	if p and G.Particles and G.Particles.Drips then
		G.Particles.Drips(p + (n or Vector(0, 0, -1)) * 0.3, Vector(0, 0, -15), vol, ent, b.oxy, f.bt)
	end
end
local function Advance(ent, b, f)
	local p, n = U.BoneToWorld(ent, f.bone, f.lp, f.ln)
	if not p or not n then f.done = true return end
	n:Normalize()
	if n.z > 0.85 then
		if DecalOK() then Decal(ent, "drip", f.bt, p, n, 1.8) end
		f.done = true
		return
	end
	if n.z < -0.6 then f.done = true return end
	local t = Vector(n.x * n.z, n.y * n.z, n.z * n.z - 1)
	local tl = t:Length()
	if tl < 0.15 then f.done = true return end
	t:Mul(1 / tl)
	local cand = p + t * 0.85
	local bone2 = U.NearestBone(ent, cand)
	local q, qn = U.SnapToMesh(ent, cand, n, bone2)
	if rawequal(qn, n) then f.done = true return end
	if not DecalOK() then return end
	Decal(ent, "drip", f.bt, q, qn, math.max(1.3 - f.n * 0.02, 0.8))
	f.n = f.n + 1
	if f.n % 3 == 0 then Record(b, ent, bone2, q, qn, "drip", math.max(1.3 - f.n * 0.02, 0.8), f.bt, false) end
	local lp, ln = U.BoneToLocal(ent, bone2, q, qn)
	if lp then f.bone, f.lp, f.ln = bone2, lp, ln end
	L.stats.runs = L.stats.runs + 1
end

local function Flow(ent, b, bone, pos, n, vol, bt)
	local lp, ln = U.BoneToLocal(ent, bone, pos, n)
	if not lp then return true end
	local key = bone .. ":" .. floor(lp.x / 0.8) .. ":" .. floor(lp.y / 0.8) .. ":" .. floor(lp.z / 0.8)
	local f = b.flows[key]
	if not f then
		if b.nflows >= 12 then
			local ok, okey = nil, nil
			for k2, f2 in pairs(b.flows) do if not ok or f2.t0 < ok.t0 then ok, okey = f2, k2 end end
			if okey then b.flows[okey] = nil b.nflows = b.nflows - 1 end
		end
		f = { bone = bone, lp = lp, ln = ln, acc = 0, n = 0, bt = bt, t0 = CurTime() }
		b.flows[key] = f
		b.nflows = b.nflows + 1
		if DecalOK() then Decal(ent, "drip", bt, pos, n, 1.4) end
	end
	f.acc = f.acc + vol
	local steps = 0
	while f.acc >= SEG and steps < 3 do
		f.acc = f.acc - SEG
		steps = steps + 1
		if f.done or f.n >= RUN_MAX then DripOff(ent, f, SEG, b) else Advance(ent, b, f) end
	end
	return true
end

function L.BodyImpact(ent, pos, normal, vel, radiusU, volume, kind, spin, stretch, residue, bone, extra)
	if not IsValid(ent) or not pos then return false end
	if not G.cv.enable:GetBool() then return false end
	kind = kind or 0
	if kind == 4 then return true end
	local b = L.Body(ent, true)
	b.touched = CurTime()
	local bt = (extra and extra.btype) or (b.typeSet and b.btype) or b.btype or 0
	if type(bt) ~= "number" then bt = 0 end
	if G.Props and G.Props.OnImpact then G.Props.OnImpact(ent, pos, normal, volume, kind, bt, extra and extra.props) end
	if not bone then bone = U.NearestBone(ent, pos) end
	local sp, sn = U.SnapToMesh(ent, pos, normal, bone)
	if not sn then sn = (pos - ent:WorldSpaceCenter()):GetNormalized() end
	if kind == 1 then return Flow(ent, b, bone, sp, sn, volume or 0, bt) end
	local now = CurTime()
	local shape, size
	if kind == 2 then shape, size = "wound", math.Clamp((radiusU or 0.3) * 7, 1.6, 4.5)
	elseif kind == 6 then shape, size = "mist", math.Clamp((radiusU or 2) * 1.2, 2, 8)
	else shape, size = "splat", math.Clamp((radiusU or 0.2) * 4.8, 0.5, 6) end
	if kind ~= 2 then
		local rc = b.recent
		for i = #rc, 1, -1 do
			local r = rc[i]
			if now - r.t > 1.2 then table.remove(rc, i)
			elseif r.p:DistToSqr(sp) < (r.s * 0.45) ^ 2 then return true end
		end
		if #rc >= 18 then L.stats.skipped = L.stats.skipped + 1 return true end
		if not DecalOK() then return true end
		rc[#rc + 1] = { p = sp, s = size, t = now }
	end
	Decal(ent, shape, bt, sp, sn, size)
	Record(b, ent, bone, sp, sn, shape, size, bt, kind == 2)
	return true
end

function L.ClearBodies()
	for ent in pairs(L.bodies) do if IsValid(ent) and ent.RemoveAllDecals then ent:RemoveAllDecals() end end
	L.bodies = setmetatable({}, { __mode = "k" })
end

local vpos = Vector()
local function SrgbLin(c) c = c / 255 return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function LinSrgb(c) c = math.Clamp(c, 0, 1) return (c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 end
function L.DrawDrops(n, BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO, trailK)
	local _, _, drop = Mats()
	local eye = EyePos()
	local ang = EyeAngles()
	local right = ang:Right()
	local lt = G.Light.Get("drops", eye + ang:Forward() * 100, 0.25)
	local E = (lt.amb or Vector(0.3, 0.3, 0.3)) + (lt.col or Vector(0, 0, 0)) * 0.5
	local ex, ey, ez = eye.x, eye.y, eye.z
	local rx, ry, rz = right.x, right.y, right.z
	local cols = {}
	render.SetMaterial(drop)
	mesh.Begin(MATERIAL_QUADS, n)
	local ok, err = pcall(function()
		local mPos, mTC, mCol, mAdv = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex
		for k = 1, n do
			local x, y, z = BX[k], BY[k], BZ[k]
			local vx, vy, vz = BVX[k], BVY[k], BVZ[k]
			local ru = math.max(BR[k] * MM, 0.035)
			local st = BS[k] or 1
			local sp = sqrt(vx * vx + vy * vy + vz * vz)
			local dx, dy, dz
			if sp > 1 then dx, dy, dz = vx / sp, vy / sp, vz / sp else dx, dy, dz = 0, 0, -1 end
			local tx, ty, tz = ex - x, ey - y, ez - z
			local sx, sy, sz = dy * tz - dz * ty, dz * tx - dx * tz, dx * ty - dy * tx
			local sl = sqrt(sx * sx + sy * sy + sz * sz)
			if sl < 1e-4 then sx, sy, sz, sl = rx, ry, rz, 1 end
			sx, sy, sz = sx / sl * ru, sy / sl * ru, sz / sl * ru
			local head = ru * st
			local tail = ru + math.min(sp * trailK, ru * 12)
			local fx, fy, fz = x + dx * head, y + dy * head, z + dz * head
			local bx, by, bz = x - dx * tail, y - dy * tail, z - dz * tail
			local bt, oq = BT[k] or 0, BO[k] or 7
			local ck = bt * 16 + oq
			local c = cols[ck]
			if not c then
				local r, g, b = U.BloodColour(bt, oq / 9, 150)
				c = { LinSrgb(SrgbLin(r) * E.x * 1.6), LinSrgb(SrgbLin(g) * E.y * 1.6), LinSrgb(SrgbLin(b) * E.z * 1.6) }
				cols[ck] = c
			end
			local r, g, b = c[1], c[2], c[3]
			local a = 235 * math.Clamp(2 * ru / (head + tail), 0.45, 1)
			vpos:SetUnpacked(fx - sx, fy - sy, fz - sz) mPos(vpos) mTC(0, 0, 0) mCol(r, g, b, a) mAdv()
			vpos:SetUnpacked(fx + sx, fy + sy, fz + sz) mPos(vpos) mTC(0, 1, 0) mCol(r, g, b, a) mAdv()
			vpos:SetUnpacked(bx + sx, by + sy, bz + sz) mPos(vpos) mTC(0, 1, 1) mCol(r, g, b, a) mAdv()
			vpos:SetUnpacked(bx - sx, by - sy, bz - sz) mPos(vpos) mTC(0, 0, 1) mCol(r, g, b, a) mAdv()
		end
	end)
	mesh.End()
	if not ok then error(err, 0) end
end

local function Quads(list, pass, now)
	local n = #list
	if n == 0 then return end
	mesh.Begin(MATERIAL_QUADS, n)
	local ok, err = pcall(function()
		for i = 1, n do
			local s = list[i]
			local r, g, b, a
			local wet = now < s.wetUntil
			if pass == "shine" then
				r, g, b = s.lr or 0, s.lg or 0, s.lb or 0
				a = wet and s.shine * s.a * 255 * math.Clamp((s.wetUntil - now) / 20, 0, 1) or 0
			elseif wet then r, g, b, a = s.wr, s.wg, s.wb, s.a * 255
			else r, g, b, a = s.dr, s.dg, s.db, s.a * 255 end
			Emit(s, r, g, b, a, false)
		end
	end)
	mesh.End()
	if not ok then error(err, 0) end
end

local function InView(c, r, eye, maxD)
	local d2 = c:DistToSqr(eye)
	if d2 > (maxD + r) ^ 2 then return false end
	return U.InViewPos(c, r)
end

-- (1.26.7) pool meshes: rings from the middle to a soft edge (built when the outline or its drying changes)
local matPool, matPoolShine, matRipple
local function PoolMats()
	if not matPool then
		matPool = Material("ghm_physblood/lite/pool_mod")
		matPoolShine = Material("ghm_physblood/lite/pool_shine")
		matRipple = Material("ghm_physblood/lite/ripple")
	end
	local k = L.shineK or 0.025
	if L.poolShineK ~= k then
		L.poolShineK = k
		if matPoolShine.SetVector then matPoolShine:SetVector("$envmaptint", Vector(k, k * 0.12, k * 0.10)) end
	end
	return matPool, matPoolShine, matRipple
end
local RING = { 0, 0.45, 0.78, 0.93, 1.0 }
local RING_H = { 1.3, 1.18, 1.0, 0.8, 0.6 }
local RING_SHINE = { 1, 1, 0.9, 0.7, 0.45 }
local NR = #RING
local function PoolFeather(p, i)
	local r = p.rr[i]
	if r >= math.min(p.lim[i], p.ok[i]) - 0.2 and p.lim[i] < math.huge then return r + 0.12 end
	return r + math.Clamp(0.06 * r + 0.45, 0.45, 2.2)
end
local function PoolVertex(p, i, k, rad)
	local x, y = COS[i] * rad, SIN[i] * rad
	local z = 0.07 + (p.hz[i] or 0) * math.Clamp(rad / math.max(p.ok[i], 0.1), 0, 1)
	return p.pos + p.U * x + p.V * y + p.n * z, x / 40 + 0.5, y / 40 + 0.5
end
local function BuildPool(p, now)
	local mod, shine = PoolMats()
	local D = DryTime()
	local A = PoolArea(p)
	local h = math.Clamp(p.vol / math.max(A / (MM * MM), 1e-3), 0.05, 3)
	if not p.E or now > (p.lightT or 0) then p.E, p.lightT = L.Light(p.pos, p.n), now + 3 end
	local cols, scols = {}, {}
	local wsum = 0
	for k = 1, NR + 1 do
		local kk = math.min(k, NR)
		local f = RING[kk]
		local hk = h * RING_H[kk]
		-- the rim dries first, and darker (the ring dried blood leaves)
		local w = math.Clamp((p.wetUntil - D * 0.3 * f - now) / (D * 0.35), 0, 1)
		wsum = wsum + w
		local wr, wg, wb = L.WetTint(p.btype, p.oxy, hk)
		local dr, dg, db = L.DryTint(p.btype, hk * (kk >= NR - 1 and 1.7 or 1))
		local a = k <= NR and 255 or 0
		cols[k] = Color(dr + (wr - dr) * w, dg + (wg - dg) * w, db + (wb - db) * w, a)
		local lr, lg, lb = L.Diffuse(p.btype, p.oxy, hk, p.E)
		scols[k] = Color(lr, lg, lb, k <= NR and 255 * w * RING_SHINE[kk] or 0)
	end
	p.wDone = wsum
	local nrm = p.n
	local cpos, cu, cv = PoolVertex(p, 1, 1, 0)
	local ring = {}
	for k = 2, NR + 1 do
		local rk = {}
		for i = 1, NDIR do
			local rad = k <= NR and p.rr[i] * RING[k] or PoolFeather(p, i)
			local pos, u, v = PoolVertex(p, i, k, rad)
			rk[i] = { pos = pos, u = u, v = v }
		end
		ring[k] = rk
	end
	-- (1.26.8) built straight into the mesh: 1.26.7 made a table per vertex (1,300 a pool, a few pools a frame)
	local function Build(mat, cl)
		local m = Mesh(mat)
		mesh.Begin(m, MATERIAL_TRIANGLES, NDIR * (2 * NR - 1))
		local ok, err = pcall(function()
			local mPos, mNrm, mTC, mCol, mAdv = mesh.Position, mesh.Normal, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex
			local function V(c, q, u, v) mPos(q) mNrm(nrm) mTC(0, u, v) mCol(c.r, c.g, c.b, c.a) mAdv() end
			for i = 1, NDIR do
				local j = i % NDIR + 1
				local a, b = ring[2][i], ring[2][j]
				V(cl[1], cpos, cu, cv) V(cl[2], a.pos, a.u, a.v) V(cl[2], b.pos, b.u, b.v)
				for k = 2, NR do
					local a0, b0, a1, b1 = ring[k][i], ring[k][j], ring[k + 1][i], ring[k + 1][j]
					local c0, c1 = cl[k], cl[k + 1]
					V(c0, a0.pos, a0.u, a0.v) V(c1, a1.pos, a1.u, a1.v) V(c1, b1.pos, b1.u, b1.v)
					V(c0, a0.pos, a0.u, a0.v) V(c1, b1.pos, b1.u, b1.v) V(c0, b0.pos, b0.u, b0.v)
				end
			end
		end)
		mesh.End()
		if not ok then
			if m.Destroy then m:Destroy() end
			ErrorNoHalt("[GHMPB] lite pool: " .. tostring(err) .. "\n")
			return nil
		end
		return m
	end
	DestroyPoolMesh(p)
	p.mesh = Build(mod, cols)
	if wsum > 0.01 then p.smesh = Build(shine, scols) end
	p.dirty = false
	p.builtT = now
	L.stats.poolBuilds = (L.stats.poolBuilds or 0) + 1
end
L.BuildPool = BuildPool
-- at most a few pool meshes a frame: changed outlines first, then drying ones every 1.5 s
-- (1.26.8) fewer a frame with less detail (1-6), and the ones far off or out of view less often: a growing pool near and
-- in view every 0.1 s, out of view or past 800 u every 0.4-0.6 s, more in a big fight; drying ones every 1.5-4 s
local function BuildPools(now)
	local detail, load = Detail()
	local left = math.max(1, math.floor(6 * detail + 0.5))
	local eye = EyePos()
	local function Interval(p, base)
		local d2 = p.pos:DistToSqr(eye)
		local k = 1
		if d2 > 800 * 800 then k = 4 end
		if not U.InViewPos(p.pos, (p.rMax or 1) + 3) then k = k * 1.5 + 2 end
		return base * k * (1 + 2 * load)
	end
	for _, p in ipairs(L.pools) do
		if left <= 0 then return end
		if not p.mesh or (p.dirty and now - (p.builtT or 0) > Interval(p, 0.1)) then BuildPool(p, now) left = left - 1 end
	end
	local D = DryTime()
	for _, p in ipairs(L.pools) do
		if left <= 0 then return end
		local drying = now > p.wetUntil - D * 0.7 and (p.wDone or 1) > 0.001
		if drying and now - (p.builtT or 0) > math.min(Interval(p, 1.5), 6) then BuildPool(p, now) left = left - 1 end
	end
end

local function DrawRipples(now, eye)
	if #L.ripples == 0 then return end
	local _, _, rip = PoolMats()
	local live = {}
	for _, r in ipairs(L.ripples) do
		if now - r.t0 < r.life and InView(r.pos, 4, eye, 2500) then live[#live + 1] = r end
	end
	for i = #L.ripples, 1, -1 do if now - L.ripples[i].t0 >= L.ripples[i].life then table.remove(L.ripples, i) end end
	if #live == 0 then return end
	render.SetMaterial(rip)
	mesh.Begin(MATERIAL_QUADS, #live)
	local ok, err = pcall(function()
		for _, r in ipairs(live) do
			local f = (now - r.t0) / r.life
			local rad = r.R * (0.35 + 1.9 * f)
			local E = (r.p and r.p.E) or Vector(0.5, 0.5, 0.5)
			local a = 90 * (1 - f) * (1 - f)
			local cr, cg, cb = math.min(255, 255 * E.x), math.min(255, 255 * E.y), math.min(255, 255 * E.z)
			local ux, vx = r.U * rad, r.V * rad
			local c = r.pos
			for q = 1, 4 do
				local su, sv = (q == 2 or q == 3) and 1 or -1, (q >= 3) and 1 or -1
				vpos:SetUnpacked(c.x + ux.x * su + vx.x * sv, c.y + ux.y * su + vx.y * sv, c.z + ux.z * su + vx.z * sv)
				mesh.Position(vpos) mesh.TexCoord(0, (su + 1) * 0.5, (sv + 1) * 0.5) mesh.Color(cr, cg, cb, a) mesh.AdvanceVertex()
			end
		end
	end)
	mesh.End()
	if not ok then error(err, 0) end
end


function L.DrawWorld()
	local mod, shine = Mats()
	local pmod, pshine = PoolMats()
	local now = CurTime()
	local eye = EyePos()
	render.SetMaterial(mod)
	for _, bt in ipairs(L.batches) do
		if bt.mod and InView(bt.center, bt.radius, eye, 6000) then bt.mod:Draw() end
	end
	Quads(L.open.list, "mod", now)
	render.SetMaterial(pmod)
	for _, p in ipairs(L.pools) do
		if p.mesh and InView(p.pos, p.rMax + 3, eye, 6000) then p.mesh:Draw() end
	end
	render.SetMaterial(shine)
	for _, bt in ipairs(L.batches) do
		if bt.shine and InView(bt.center, bt.radius, eye, 3000) then bt.shine:Draw() end
	end
	Quads(L.open.list, "shine", now)
	render.SetMaterial(pshine)
	for _, p in ipairs(L.pools) do
		if p.smesh and InView(p.pos, p.rMax + 3, eye, 3000) then p.smesh:Draw() end
	end
	DrawRipples(now, eye)
end

function L.Update(dt)
	local now = CurTime()
	ReshootStep()
	local o = L.open
	if #o.list >= BATCH_N or (#o.list > 0 and now - o.t0 > BATCH_T) then Bake() end
	DryBatches(now)
	if dt > 0 then GrowPools(dt) end
	BuildPools(now)
end

function L.Clear()
	for _, bt in ipairs(L.batches) do DestroyBatch(bt) end
	L.batches = {}
	L.open = { list = {}, t0 = 0 }
	for _, p in ipairs(L.pools) do DestroyPoolMesh(p) end
	L.pools = {}
	L.ripples = {}
	L.hash = {}
	L.reshootQ = {}
	grid, gridT = {}, -1
	L.ClearBodies()
end

function L.Counts()
	local n = #L.open.list
	for _, b in ipairs(L.batches) do n = n + b.n end
	local bodies = 0
	for ent in pairs(L.bodies) do if IsValid(ent) then bodies = bodies + 1 end end
	return n, #L.pools, bodies
end

L.origs = L.origs or {}
L.isWrap = L.isWrap or setmetatable({}, { __mode = "k" })
local function Wrap(tbl, name, liteFn)
	if not tbl then return end
	local cur = tbl[name]
	if type(cur) ~= "function" then return end
	local o = L.origs[tbl]
	if not o then o = {} L.origs[tbl] = o end
	if not L.isWrap[cur] then o[name] = cur end
	local orig = o[name]
	-- (1.26.8) the world and body impacts timed for ghmpb_prof (the drop landings cost 0.27 ms each with Lite)
	local lap = (name == "Impact") and (tbl == G.Surfaces and ".lite world impacts" or (tbl == G.Entities and ".lite body impacts")) or nil
	local w
	if lap then
		w = function(...)
			if not L.on then return orig(...) end
			local P = G.Prof
			if not (P and P.Add) then return liteFn(...) end
			local t0 = SysTime()
			local a, b, c = liteFn(...)
			P.Add(lap, (SysTime() - t0) * 1000)
			P.Count(lap)
			return a, b, c
		end
	else
		w = function(...) if L.on then return liteFn(...) end return orig(...) end
	end
	L.isWrap[w] = true
	tbl[name] = w
end
local function False() return false end
local function Zero() return 0 end
local function Nothing() end

local S, E = G.Surfaces, G.Entities
Wrap(S, "Impact", L.WorldImpact)
Wrap(S, "Element", Zero)
Wrap(S, "GetPatch", function() return nil, nil end)
Wrap(S, "WarmSlot", False)
Wrap(S, "HasStatic", False)
Wrap(S, "Update", Nothing)
Wrap(S, "DrawStatic", Nothing)
Wrap(S, "DrawOverlays", Nothing)
Wrap(E, "Impact", L.BodyImpact)
Wrap(E, "Element", False)
Wrap(E, "Get", function(ent, create) return L.Body(ent, create) end)
Wrap(E, "WarmSlot", False)
Wrap(E, "Update", Nothing)
Wrap(E, "HasStatic", False)
Wrap(E, "DrawStatic", Nothing)
Wrap(E, "DrawOverlays", Nothing)
Wrap(E, "RawDrawStatic", Nothing)
Wrap(E, "RawDrawOverlays", Nothing)
Wrap(G.Smear, "RequestProbe", L.RequestProbe)
Wrap(G.Contact, "Grid", L.Grid)
Wrap(G.Contact, "NearBlood", L.NearBlood)
Wrap(G.Dust, "GpuPass", Nothing)
Wrap(G.Dust, "DrawStatic", Nothing)
Wrap(G.Dust, "DrawLive", Nothing)
Wrap(G.Dust, "Any", False)

cvars.AddChangeCallback("ghmpb_render_mode", function()
	if (G.cv.rendermode and G.cv.rendermode:GetInt() or 0) == 1 and not L.ShadersPresent() then
		MsgC(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Custom shader files are not installed in garrysmod/shaders/fxc/ — staying in built-in Non-Shader (Lite) mode.\n")
	end
	L.forcedFallback = nil
	local on = L.Decide()
	if on == L.on then return end
	if G.Render and G.Render.ClearAll then G.Render.ClearAll() end
	L.on = on
	MsgN("[GHMPB] renderer: " .. (on and "lite (no shaders)" or "shaders"))
end, "ghmpb_lite")

concommand.Add("ghmpb_lite_info", function()
	local st, pools, bodies = L.Counts()
	MsgN(string.format("[GHMPB] renderer: %s | shader files %s | stains %d in %d batches, pools %d, bodies %d | decals %d (failed %d), run steps %d, pools joined %d, thinned %d",
		L.on and "lite" or "shaders", L.ShadersPresent() and "found" or "missing", st, #L.batches, pools, bodies,
		L.stats.bodyDecals, L.stats.decalErrors, L.stats.runs, L.stats.merged, L.stats.skipped))
end, nil, "GHM PhysBlood: what the lite renderer holds")
