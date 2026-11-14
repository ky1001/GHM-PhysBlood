-- 1.22.0: the lite renderer (no custom shaders - Steam Workshop): world stains / pools / prints as quads, model decals on
-- bodies with runs that creep down the skin, drops as sprites; the addon's entry points switch to it (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
-- (1.26.8) checked at the drying figures of 1.26.7 and before (the defaults dry and clot several times slower now)
RunConsoleCommand("ghmpb_drytime", "240") RunConsoleCommand("ghmpb_coag_time", "180")
local G = GHMPB
function FrameNumber() return M.frame or 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, -200, 64) end
local ANG = { Forward = function() return Vector(0, 1, 0) end, Right = function() return Vector(1, 0, 0) end, Up = function() return Vector(0, 0, 1) end }
function EyeAngles() return ANG end
function ScrW() return 1920 end
function ScrH() return 1080 end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
_G.timer = { Simple = function(_, f) M.timers = M.timers or {} M.timers[#M.timers + 1] = f end }
local function RunTimers() local t = M.timers or {} M.timers = {} for _, f in ipairs(t) do f() end end

-- ---------------- engine: materials, meshes, drawing
local matLog = {}
local function Mat(name)
	local m = { name = name, vec = {} }
	function m:SetVector(k, v) self.vec[k] = v end
	function m:GetVector(k) return self.vec[k] end
	function m:IsError() return false end
	return m
end
local matCache = {}
function Material(name) matCache[name] = matCache[name] or Mat(name) return matCache[name] end
local meshes = { made = 0, destroyed = 0, drawn = 0, verts = 0 }
function Mesh(mat)
	meshes.made = meshes.made + 1
	return { BuildFromTriangles = function(_, v) meshes.verts = meshes.verts + #v
			for _, x in ipairs(v) do assert(x.pos and x.u and x.v and x.color, "vertex fields") end end,
		Draw = function() meshes.drawn = meshes.drawn + 1 end, Destroy = function() meshes.destroyed = meshes.destroyed + 1 end }
end
local dyn = { begun = 0, verts = 0, open = false }
-- (1.26.8) mesh.Begin(IMesh, primitive, count) builds a static mesh straight away (the baked stains, the pools)
_G.MATERIAL_TRIANGLES = 2
_G.mesh = {
	Begin = function(a, b, c)
		assert(not dyn.open, "mesh.Begin while open")
		dyn.open = true dyn.v = 0
		if type(a) == "table" then dyn.build, dyn.prim, dyn.n = a, b, c return end
		dyn.begun = dyn.begun + 1 dyn.n = b
	end,
	End = function()
		assert(dyn.open, "mesh.End without Begin")
		if dyn.build then
			local per = dyn.prim == MATERIAL_TRIANGLES and 3 or 4
			assert(dyn.v == dyn.n * per, "built mesh: " .. dyn.v .. " vertices for " .. dyn.n)
			meshes.verts = meshes.verts + dyn.v
			dyn.build, dyn.open = nil, false
			return
		end
		assert(dyn.v == dyn.n * 4, "quads: " .. dyn.v .. " vertices for " .. dyn.n) dyn.open = false
	end,
	Normal = function(v) assert(v.x == v.x and v.y == v.y and v.z == v.z, "NaN normal") end,
	Position = function(v) assert(v.x == v.x and v.y == v.y and v.z == v.z, "NaN vertex") end,
	TexCoord = function(_, u, v) assert(u >= -0.01 and u <= 1.01 and v >= -0.01 and v <= 1.01, "uv out of range") end,
	Color = function(r, g, b, a) assert(r >= 0 and r <= 255.5 and g >= 0 and g <= 255.5 and b >= 0 and b <= 255.5 and a >= 0 and a <= 255.5, "colour range") end,
	AdvanceVertex = function() dyn.v = dyn.v + 1 dyn.verts = dyn.verts + 1 end,
}
_G.render = { SetMaterial = function(m) matLog[#matLog + 1] = m.name end, GetRenderTarget = function() return nil end,
	ComputeLighting = function() return Vector(0.5, 0.5, 0.5) end }
_G.MATERIAL_QUADS = 3
local decals = {}
util.DecalEx = function(mat, ent, pos, n, col, w, h)
	assert(mat and mat.name, "decal material") assert(w > 0 and h > 0, "decal size")
	decals[#decals + 1] = { mat = mat.name, ent = ent, pos = Vector(pos), n = Vector(n), w = w }
end

-- ---------------- the addon's modules this one switches (the shader renderer's functions, recorded when called)
local called = {}
local function rec(name, ret) return function() called[name] = (called[name] or 0) + 1 return ret end end
G.Surfaces = { Impact = rec("S.Impact", true), Element = rec("S.Element", 3), GetPatch = rec("S.GetPatch"), WarmSlot = rec("S.WarmSlot", true),
	HasStatic = rec("S.HasStatic", true), Update = rec("S.Update"), DrawStatic = rec("S.DrawStatic"), DrawOverlays = rec("S.DrawOverlays"),
	PATCH_UNITS = 40, GroundFilter = function(e) return true end }
G.Entities = { Impact = rec("E.Impact", true), Element = rec("E.Element", true), Get = rec("E.Get"), WarmSlot = rec("E.WarmSlot", true),
	Update = rec("E.Update"), HasStatic = rec("E.HasStatic", true), DrawStatic = rec("E.DrawStatic"), DrawOverlays = rec("E.DrawOverlays"), domains = {} }
G.Smear = { RequestProbe = rec("RequestProbe") }
G.Contact = { Grid = rec("C.Grid", {}), NearBlood = rec("C.NearBlood", false) }
G.Dust = { GpuPass = rec("D.GpuPass"), DrawStatic = rec("D.DrawStatic"), DrawLive = rec("D.DrawLive"), Any = rec("D.Any", true) }
local drips = 0
G.Particles = { Drips = function(_, _, vol) drips = drips + vol end }
G.Light = { Get = function() return { amb = Vector(0.3, 0.3, 0.3), col = Vector(0.5, 0.5, 0.5), dir = Vector(0, 0, 1) } end }
G.BloodTypeOf = function() return 0 end
G.GPU = { FreshAbs = function() return math.max(G.cv.colFresh:GetFloat(), 0.3) ^ -1.6 end }
G.Prof = { Count = function() end, Lap = function() return SysTime() end }
G.DiagCount = function() end
local cleared = 0
G.Render = { ClearAll = function() cleared = cleared + 1 G.Lite.Clear() end }
M.Load({ "cl_util.lua" })
local U = G.U
U.InViewPos = function() return true end
M.Load({ "cl_lite.lua" })
local L = G.Lite

-- ---------------- which renderer
check(L.on == true, "no shader files: the lite renderer is on (automatic)")
check(not L.ShadersPresent(), "the shader files are reported missing")
RunConsoleCommand("ghmpb_render_mode", "1")
check(L.on == false and cleared == 1, "renderer 1: shaders (the blood on screen was cleared)")
G.Surfaces.Impact(Vector(0, 0, 0), Vector(0, 0, 1), Vector(0, 0, -100), 0.1, 10, 0)
G.Entities.Element(nil)
check(called["S.Impact"] == 1 and called["E.Element"] == 1, "with the shaders the original functions run")
RunConsoleCommand("ghmpb_render_mode", "0")
check(L.on == true, "back to automatic: lite")
check(G.Surfaces.WarmSlot() == false and G.Entities.WarmSlot() == false and G.Surfaces.HasStatic() == false and G.Dust.Any() == false,
	"lite: no render target warm-up, no static layers, no dust layers")
check(G.Surfaces.Element(Vector(0, 0, 0), 10, 10, 1) == 0 and G.Surfaces.GetPatch(Vector(0, 0, 0), Vector(0, 0, 1), true) == nil,
	"lite: no world patches, elements act on nothing")
check((called["S.WarmSlot"] or 0) == 0 and (called["S.GetPatch"] or 0) == 0, "lite: the shader renderer's functions are not called")
-- (a file run again - R.Rebuild / Lua refresh - wraps its new functions; the wrappers are not wrapped twice)
M.Load({ "cl_lite.lua" })
L = G.Lite
RunConsoleCommand("ghmpb_render_mode", "1")
G.Surfaces.Impact(Vector(0, 0, 0), Vector(0, 0, 1), Vector(0, 0, -100), 0.1, 10, 0)
check(called["S.Impact"] == 2, "after the file runs again the original still runs with the shaders (no wrapper loop)")
RunConsoleCommand("ghmpb_render_mode", "2")
check(L.on, "renderer 2: lite")

-- ---------------- world stains
local S = G.Surfaces
local floorTr = { HitTexture = "concrete/floor", MatType = MAT_CONCRETE, HitWorld = true }
for i = 1, 40 do
	S.Impact(Vector(i * 5, 0, 0), Vector(0, 0, 1), Vector(math.random(-50, 50), 0, -300), 0.2, 12, 0, 0, 1, 0.2, floorTr, 0.7, 0)
end
local st = L.Counts()
check(st == 40, "40 drops: 40 stains (" .. st .. ")")
local s1 = L.open.list[1]
print(string.format("     stain w %.1f %.1f %.1f  l %.1f %.1f %.1f", s1.wr, s1.wg, s1.wb, s1.lr, s1.lg, s1.lb)) check(s1.wr > s1.wg * 2 and s1.wr <= 127.6, "a stain tints red, never brightens (Modulate 2x: <= 127.5)")
check(s1.dr < s1.wr and s1.dg >= 0, "dry colour darker")
check(s1.lr > s1.lg * 3 and s1.lr > 5, "the blood's own colour (lit) for the wet pass: red")
local h1 = s1.h
check(h1 > 0.1 and h1 < 0.6, string.format("a 12 ul drop spread to 0.2 u: %.2f mm thick", h1))
-- oblique hit: elongated along the travel
S.Impact(Vector(0, 50, 0), Vector(0, 0, 1), Vector(400, 0, -60), 0.08, 12, 0, 0, 1, 0.2, floorTr, 0.7, 0)
local so = L.open.list[#L.open.list]
check((so.cell == 4 or so.cell == 5) and so.hu > so.hv and math.abs(so.ux) > 0.99, "a grazing drop: an elongated stain along its travel")
-- crowding: a flood of tiny drops on one spot is thinned
local before = L.Counts()
for i = 1, 30 do S.Impact(Vector(300, 300, 0), Vector(0, 0, 1), Vector(0, 0, -200), 0.05, 2, 0, 0, 1, 0.2, floorTr, 0.7, 0) end
check(L.Counts() - before <= 7, "30 tiny drops on one spot within a second: thinned (" .. (L.Counts() - before) .. ")")
-- prints, smears, trails, mist
S.Impact(Vector(0, -40, 0), Vector(0, 0, 1), Vector(0, 1, 0), 5.5, 60, 5, -1, 0.8, 0.3, floorTr, 0.7, 0)
local pr = L.open.list[#L.open.list]
check(pr.cell == 9 and pr.flip == 1, "left shoe print")
S.Impact(Vector(10, -40, 0), Vector(0, 0, 1), Vector(0, 1, 0), 5.5, 60, 5, 1, 0.8, 0.3, floorTr, 0.7, 0)
check(L.open.list[#L.open.list].flip == -1, "right shoe print: mirrored")
S.Impact(Vector(20, -40, 0), Vector(0, 0, 1), Vector(0, 1, 0), 3, 60, 5, 2, 0.8, 0.3, floorTr, 0.7, 0)
check(L.open.list[#L.open.list].cell == 11, "hand print")
S.Impact(Vector(30, -40, 0), Vector(0, 0, 1), Vector(0, 1, 0), 3, 60, 5, 5, 0.8, 0.3, floorTr, 0.7, 0)
check(L.open.list[#L.open.list].cell == 10, "creature track")
S.Impact(Vector(40, -40, 0), Vector(0, 0, 1), Vector(-12, 0, 0), 2, 400, 3, 0, 1, 0.3, floorTr, 0.7, 0)
local sm = L.open.list[#L.open.list]
check(sm.cell == 8 and math.abs(sm.x - 34) < 0.01 and sm.hu >= 6, "smear along its path (centre half way back)")
S.Impact(Vector(50, -40, 0), Vector(0, 0, 1), Vector(0, 0, 0), 12, 300, 6, 0, 1, 0.3, floorTr, 0.7, 0)
check(L.open.list[#L.open.list].cell == 13, "mist")
local n0 = L.Counts()
S.Impact(Vector(60, -40, 0), Vector(0, 0, 1), Vector(5, 0, 0), 2, 50, 4, 0, 1, 0.3, floorTr, 0.7, 0)
check(L.Counts() == n0, "a wipe / push leaves nothing of its own")

-- ---------------- pools: grow, stop at the edge, join
S.Impact(Vector(0, 200, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 20000, 1, 0, 1, 0, floorTr, 0.7, 0)
check(#L.pools == 1, "a pour on the floor: a pool")
S.Impact(Vector(1, 201, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 20000, 1, 0, 1, 0, floorTr, 0.7, 0)
check(#L.pools == 1 and L.pools[1].vol == 40000, "a second pour on it: the same pool, twice the blood")
local p = L.pools[1]
local rT = p.rT
for i = 1, 200 do M.now = M.now + 0.05 L.Update(0.05) end
check(math.abs(p.r - rT) < 0.2 and rT > 2.5, string.format("the pool grew to the size its volume makes (%.1f of %.1f u)", p.r, rT))
-- a drop into the pool joins it
local v0 = p.vol
S.Impact(p.pos + Vector(0.5, 0, 0), Vector(0, 0, 1), Vector(0, 0, -200), 0.1, 30, 0, 0, 1, 0.2, floorTr, 0.7, 0)
check(p.vol == v0 + 30, "a drop into the pool joins it")
-- a second pool next to it: they join as they grow
S.Impact(p.pos + Vector(p.r * 1.5 + 1.5, 0, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 40000, 1, 0, 1, 0, floorTr, 0.7, 0)
check(#L.pools == 2, "a pour beside it: a second pool")
for i = 1, 200 do M.now = M.now + 0.05 L.Update(0.05) end
check(#L.pools == 1 and L.pools[1].vol > 80000 and L.stats.merged >= 1, "the two pools grew into each other and joined")
-- an edge: the floor ends at x = 400 (a ledge) - the pool stops (or moves away from it)
local tl = util.TraceLine
util.TraceLine = function(t)
	if t.start.x > 400 then return { Hit = false, HitPos = t.endpos, HitNormal = Vector(0, 0, 0), Fraction = 1 } end
	return tl(t)
end
S.Impact(Vector(396, 0, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 200000, 1, 0, 1, 0, floorTr, 0.7, 0)
local pe = L.pools[#L.pools]
for i = 1, 300 do M.now = M.now + 0.05 L.Update(0.05) end
local function Extent(pl, ax)   -- the outline's farthest reach along a world axis
	local m = -1e9
	for i = 1, L.POOL_NDIR do
		local a = (i - 1) / L.POOL_NDIR * 2 * math.pi
		local d = pl.U * math.cos(a) + pl.V * math.sin(a)
		m = math.max(m, (pl.pos + d * pl.rr[i]):Dot(ax))
	end
	return m
end
local ex = Extent(pe, Vector(1, 0, 0))
check(ex <= 401.5, string.format("the pool does not grow over the ledge (edge at %.1f)", ex))
check(math.abs(pe.r - pe.rT) < 0.6, string.format("it grows away from the ledge instead, to its full size (%.1f of %.1f u)", pe.r, pe.rT))
util.TraceLine = tl

-- (1.26.7) pools: an uneven outline that goes round walls and runs downhill, drawn as a mesh, ripples, drying
local pp = L.pools[1]
local mn, mx = 1e9, 0
for i = 1, L.POOL_NDIR do mn, mx = math.min(mn, pp.rr[i]), math.max(mx, pp.rr[i]) end
check(mx / mn > 1.08 and mx / mn < 3, string.format("the outline is uneven, not a circle (%.1f to %.1f u)", mn, mx))
check(math.abs(L.PoolArea(pp) - math.pi * pp.r * pp.r) < 0.01, "its size is the area of the outline")
-- a wall at x = 600: the pool runs along it
M.wallX = 600
S.Impact(Vector(596, -300, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 150000, 1, 0, 1, 0, floorTr, 0.7, 0)
local pw = L.pools[#L.pools]
for i = 1, 300 do M.now = M.now + 0.05 L.Update(0.05) end
local exw = Extent(pw, Vector(1, 0, 0))
local eyw = Extent(pw, Vector(0, 1, 0)) - pw.pos.y
check(exw <= 600.6, string.format("a wall: the pool does not go through it (%.1f)", exw))
check(math.abs(pw.r - pw.rT) < 0.6 and eyw > 600 - pw.pos.x + 2, string.format("it goes along the wall instead (%.1f u along, %.1f to the wall)", eyw, 600 - pw.pos.x))
M.wallX = nil
-- a tilted floor (14 degrees, down towards +x): the pool runs downhill
local tn = Vector(0.25, 0, 1):GetNormalized()
util.TraceLine = function(t)
	local s0, e0 = t.start, t.endpos
	local fs, fe = s0:Dot(tn) - 2000 * tn.x, e0:Dot(tn) - 2000 * tn.x   -- plane through (2000, 0, 0)
	if fs >= 0 and fe < 0 then
		local f = fs / (fs - fe)
		return { Hit = true, HitPos = s0 + (e0 - s0) * f, HitNormal = tn, Fraction = f, HitWorld = true }
	end
	return { Hit = false, HitPos = e0, HitNormal = Vector(0, 0, 0), Fraction = 1 }
end
S.Impact(Vector(2000, 0, 0), tn, Vector(0, 0, 0), 1, 80000, 1, 0, 1, 0, floorTr, 0.7, 0)
local ps0 = L.pools[#L.pools]
for i = 1, 300 do M.now = M.now + 0.05 L.Update(0.05) end
local dh = Vector(tn.z, 0, -tn.x)   -- downhill along the floor
local down, up = Extent(ps0, dh) - ps0.pos:Dot(dh), Extent(ps0, -dh) + ps0.pos:Dot(dh)
check(ps0.down ~= nil and down > up * 1.25, string.format("a tilted floor: the pool runs downhill (%.1f u down, %.1f u up)", down, up))
util.TraceLine = tl
-- drawn as a mesh with a soft edge
L.Update(0.05)
check(pp.mesh ~= nil and pp.smesh ~= nil, "a pool is a mesh, with its wet shine")
local mm0 = meshes.drawn
L.DrawWorld()
check(meshes.drawn >= mm0 + 2 * #L.pools, "the pools draw (mesh and shine)")
-- a drop into a pool ripples
local nr = #L.ripples
S.Impact(pp.pos + Vector(0.3, 0, 0), Vector(0, 0, 1), Vector(0, 0, -200), 0.1, 20, 0, 0, 1, 0.2, floorTr, 0.7, 0)
check(#L.ripples == nr, "1.26.8: a drop landing in a pool makes no ripple (the white rings are gone)")
L.DrawWorld()
check(not dyn.open, "the ripple draws")

-- ---------------- probes (footprints)
local ps = {}
G.Smear.RequestProbe(ps, L.pools[1].pos, Vector(0, 0, 1))
check(ps.h and ps.h > 0.5 and ps.hT == CurTime() and ps.live, string.format("a probe in the pool reads its depth (%.2f mm)", ps.h or -1))
local ps2 = {}
G.Smear.RequestProbe(ps2, Vector(-3000, 0, 0), Vector(0, 0, 1))
check(ps2.h == 0, "a probe on clean floor reads 0")
local grid = G.Contact.Grid(CurTime())
check(G.Contact.NearBlood(L.pools[1].pos) == true and G.Contact.NearBlood(Vector(-3000, 0, 0)) == false, "the coarse grid knows where wet blood is")

-- ---------------- batches: baked into meshes, drawn, dried, capped
L.Update(0.05)
M.now = M.now + 3 L.Update(0.05)
check(#L.batches >= 1 and #L.open.list == 0 and meshes.made >= 2, "the stains were baked into static meshes")
local drawn0 = meshes.drawn
L.DrawWorld()
check(meshes.drawn > drawn0 and not dyn.open, "the world layer draws (static meshes + pools)")
local hadShine = L.batches[1].shine ~= nil
M.now = M.now + 2000
for i = 1, #L.batches + 1 do L.Update(0.05) end
check(hadShine and not L.batches[1].wet and L.batches[1].shine == nil, "dried: the batch is rebuilt dry, its shine gone")
RunConsoleCommand("ghmpb_lite_stains", "200")
for i = 1, 400 do S.Impact(Vector(math.random(-2000, 2000), math.random(-2000, 2000), 0), Vector(0, 0, 1), Vector(0, 0, -300), 0.1, 20, 0, 0, 1, 0.2, floorTr, 0.7, 0) end
M.now = M.now + 3 L.Update(0.05)
M.now = M.now + 3 L.Update(0.05)
local total = 0
for _, b in ipairs(L.batches) do total = total + b.n end
check(total <= 200 + 192 and meshes.destroyed > 0, "over the cap: the oldest batches go (" .. total .. " kept)")

-- ---------------- drops
local BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
for k = 1, 50 do
	BX[k], BY[k], BZ[k] = k, 0, 30
	BVX[k], BVY[k], BVZ[k] = (k % 3 == 0) and 0 or 200, 0, -100
	BR[k], BS[k], BT[k], BO[k] = 1.5, 1.2, k % 4, 7
end
BVX[10], BVY[10], BVZ[10] = 0, 0, 0         -- (at rest)
BX[11], BY[11], BZ[11], BVX[11], BVY[11], BVZ[11] = 0, -100, 64, 0, -300, 0    -- (flying straight at the camera)
local ok, err = pcall(L.DrawDrops, 50, BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO, 0.008)
check(ok and not dyn.open, "drops draw as sprites (" .. tostring(err) .. ")")

-- ---------------- bodies: decals, runs down the skin, transfer to the corpse
local ent = { valid = true, decalsRemoved = 0 }
function ent:IsValid() return self.valid end
function ent:WorldSpaceCenter() return Vector(0, 0, 40) end
function ent:RemoveAllDecals() self.decalsRemoved = self.decalsRemoved + 1 end
function ent:SetupBones() end
-- a vertical cylinder of skin around the z axis (radius 6): snapping projects onto it; bone 0 = the entity's origin
U.NearestBone = function() return 0 end
U.SnapToMesh = function(e, pos, n, bone)
	local r = Vector(pos.x, pos.y, 0)
	if r:Length() < 1e-3 then return pos, n end
	r:Normalize()
	if pos.z < 0 then return pos, n end            -- (the bottom of the body: no skin)
	return Vector(r.x * 6, r.y * 6, pos.z), r
end
U.BoneToLocal = function(e, bone, pos, n) return Vector(pos), n and Vector(n) or nil end
U.BoneToWorld = function(e, bone, lp, ln) return Vector(lp), ln and Vector(ln) or nil end
local E = G.Entities
E.Impact(ent, Vector(7, 0, 50), Vector(1, 0, 0), Vector(-50, 0, 0), 0.32, 220, 2, 0, 1, 0.85, 0, { oxy = 0.8 })
check(#decals == 1 and decals[1].mat:find("bwound_0") and math.abs(decals[1].pos.x - 6) < 0.01, "a wound: a wound decal on the skin")
check(E.Get(ent, false) ~= nil and E.Get(ent, false).lite, "the body is known (wound emitters pour onto it)")
for i = 1, 5 do E.Impact(ent, Vector(7, 0, 50.02 * i / i), Vector(1, 0, 0), Vector(-50, 0, 0), 0.1, 10, 0, 0, 1, 0.2, 0) end
check(#decals == 2, "splats right on top of each other within a moment: one decal")
-- the wound bleeds onto the skin: a run creeps down
local nd = #decals
for i = 1, 40 do M.frame = (M.frame or 1) + 1 E.Impact(ent, Vector(6, 0, 50), Vector(1, 0, 0), vector_origin, 0.3, 30, 1, 0, 1, 0) end
local zmin = 50
for k = nd + 1, #decals do zmin = math.min(zmin, decals[k].pos.z) end
check(#decals - nd >= 20 and zmin < 40, string.format("the run crept down the skin (%d decals, down to z %.1f)", #decals - nd, zmin))
check(L.stats.runs >= 20, "run steps counted")
-- at its end the blood drips off
for i = 1, 30 do M.frame = (M.frame or 1) + 1 E.Impact(ent, Vector(6, 0, 50), Vector(1, 0, 0), vector_origin, 0.3, 30, 1, 0, 1, 0) end
check(drips > 0, "past its longest the run drips off its end")
-- transfer onto the corpse: its decals are put on again
local rag = { valid = true, decalsRemoved = 0 }
function rag:IsValid() return true end
function rag:RemoveAllDecals() self.decalsRemoved = self.decalsRemoved + 1 end
function rag:SetupBones() end
function rag:WorldSpaceCenter() return Vector(0, 0, 40) end
local before2 = #decals
L.Transfer(ent, rag)
RunTimers()
-- (1.26.8) put on over the next frames (all at once: up to 30 model decals in one frame for every body that died)
local q0 = #L.reshootQ
M.frame = (M.frame or 1) + 1 L.Update(0)
check(q0 >= 5 and #L.reshootQ < q0, string.format("the corpse's decals go on over the next frames (%d waiting, %d after one)", q0, #L.reshootQ))
for _ = 1, 4 do M.frame = M.frame + 1 L.Update(0) end
local onRag = 0
for k = before2 + 1, #decals do if decals[k].ent == rag then onRag = onRag + 1 end end
check(onRag >= 5 and rag.decalsRemoved == 1 and L.bodies[rag] and not L.bodies[ent], "the corpse gets the body's decals (" .. onRag .. ")")
-- colour settings follow into the decal materials
local m = Material("ghm_physblood/lite/bwound_0")
local c0 = m:GetVector("$color2")
RunConsoleCommand("ghmpb_color_fresh", "2")
E.Impact(rag, Vector(-7, 0, 30), Vector(-1, 0, 0), Vector(50, 0, 0), 0.32, 220, 2, 0, 1, 0.85, 0)
check(c0 and m:GetVector("$color2") and m:GetVector("$color2").x ~= c0.x, "the decal colour follows the colour settings")
-- (1.26.8) model decals a frame: at most 8 (2 to 8 by the detail level), the wounds always
local ent3 = setmetatable({ valid = true, decalsRemoved = 0 }, { __index = ent })
M.frame = (M.frame or 1) + 1
local dd0 = #decals
for i = 1, 30 do E.Impact(ent3, Vector(7, 0, 5 + i * 2), Vector(1, 0, 0), Vector(-50, 0, 0), 0.3, 10, 0, 0, 1, 0.2, 0) end
local splats = #decals - dd0
E.Impact(ent3, Vector(7, 0, 80), Vector(1, 0, 0), Vector(-50, 0, 0), 0.32, 220, 2, 0, 1, 0.85, 0)
check(splats == 8 and #decals - dd0 == 9, string.format("30 splats on a body in one frame: %d decals, and the wound still (%d)", splats, #decals - dd0 - splats))

-- ---------------- (1.26.8, second pass) a magazine dump with Lite: "performance not good" (the drop landings 4 ms a frame)
-- a stain is fitted to the edge of what it lies on only when it is over 1.8 u across, with a budget of traces a frame
L.Clear()
local nTr = 0
local tlc = util.TraceLine
util.TraceLine = function(t) nTr = nTr + 1 return tlc(t) end
M.frame = (M.frame or 1) + 1
nTr = 0
for i = 1, 20 do S.Impact(Vector(i * 40, 900, 0), Vector(0, 0, 1), Vector(0, 0, -300), 0.3, 8, 0, 0, 1, 0.2, floorTr, 0.7, 0) end
check(nTr == 0, "20 small stains (0.6 u): no edge traces (" .. nTr .. ")")
nTr = 0
S.Impact(Vector(0, 1200, 0), Vector(0, 0, 1), Vector(0, 0, -300), 2.5, 400, 0, 0, 1, 0.2, floorTr, 0.7, 0)
check(nTr >= 4, "a big one (5 u): fitted to the edges (" .. nTr .. " traces)")
nTr = 0
for i = 1, 60 do S.Impact(Vector(i * 40, 1500, 0), Vector(0, 0, 1), Vector(0, 0, -300), 2.5, 400, 0, 0, 1, 0.2, floorTr, 0.7, 0) end
check(nTr <= 100, "60 big ones in one frame: at most 96 traces (" .. nTr .. ")")
M.frame = M.frame + 1
nTr = 0
S.Impact(Vector(0, 1800, 0), Vector(0, 0, 1), Vector(0, 0, -300), 2.5, 400, 0, 0, 1, 0.2, floorTr, 0.7, 0)
check(nTr >= 4, "the next frame: fitted again")
util.TraceLine = tlc
-- baked batches and pools are built straight into their meshes, no table per vertex
local tables = 0
local MeshMock = Mesh
Mesh = function(mat) local m = MeshMock(mat) local b = m.BuildFromTriangles m.BuildFromTriangles = function(...) tables = tables + 1 return b(...) end return m end
local v0 = meshes.verts
for i = 1, 200 do S.Impact(Vector(i * 3, 2400, 0), Vector(0, 0, 1), Vector(0, 0, -300), 0.3, 8, 0, 0, 1, 0.2, floorTr, 0.7, 0) end
S.Impact(Vector(0, 2600, 0), Vector(0, 0, 1), Vector(0, 0, 0), 1, 20000, 1, 0, 1, 0, floorTr, 0.7, 0)
L.Update(0.05)
check(#L.batches >= 1 and tables == 0 and meshes.verts > v0, string.format("a batch and a pool built straight into meshes (%d vertices, %d vertex tables)", meshes.verts - v0, tables))
Mesh = MeshMock

-- ---------------- clearing
L.Clear()
check(L.Counts() == 0 and #L.pools == 0 and #L.batches == 0, "clear: everything goes")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
