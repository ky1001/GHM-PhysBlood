-- (1.26.7, 27 Oct) the Crisis Response splats drawn by PhysBlood itself (cl_splatmesh.lua): engine decals vanish at the
-- engine's limit, these stay until "splats kept" is used up; laid in cells that follow the surface and leave out what
-- is not there; turned with the way the blood travelled; the forensic code sends world hits here (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "cl_util.lua" })
local G = GHMPB
function EyePos() return Vector(0, -100, 64) end
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
G.U.InViewPos = function() return true end
local meshes = { made = 0, destroyed = 0, drawn = 0, verts = 0, last = nil }
function Mesh(mat)
	meshes.made = meshes.made + 1
	local m = { mat = mat }
	function m:BuildFromTriangles(v)
		meshes.verts = meshes.verts + #v
		for _, x in ipairs(v) do assert(x.pos and x.u and x.v and x.color and x.normal, "vertex fields") end
		self.v = v
		meshes.last = v
	end
	function m:Draw() meshes.drawn = meshes.drawn + 1 end
	function m:Destroy() meshes.destroyed = meshes.destroyed + 1 end
	return m
end
local created = {}
function CreateMaterial(name, shader, kv)
	local m = { name = name, shader = shader, kv = kv }
	function m:IsError() return false end
	created[name] = m
	return m
end
local setMat = 0
_G.render = _G.render or {}
render.SetMaterial = function() setMat = setMat + 1 end
M.Load({ "cl_crbdata.lua", "cl_crbtypes.lua", "cl_splatmesh.lua" })
local SM = G.SplatMesh

check(SM.On(), "on by default: PhysBlood draws the splats on the world")
-- open floor (the mock world: a floor at z = 0)
check(SM.Lay(Vector(0, 0, 0), Vector(0, 0, 1), "ghm_physblood/crb/bp3", 30, 30, nil), "a splat on the floor")
local v = meshes.last
check(v and #v == 36 * 6, "on open floor: all 36 cells (" .. (v and #v / 6 or 0) .. ")")
local mat = created["ghmpb_splat_ghm_physblood_crb_bp3"]
check(mat and mat.shader == "Modulate" and mat.kv["$basetexture"] == "ghm_physblood/crb/bp3" and mat.kv["$mod2x"] == "1",
	"drawn with the Modulate shader (2x, like DecalModulate) and the CRB texture as it is")
local zmin, zmax, umin, umax = 1e9, -1e9, 1e9, -1e9
for _, x in ipairs(v) do
	zmin, zmax = math.min(zmin, x.pos.z), math.max(zmax, x.pos.z)
	umin, umax = math.min(umin, x.u), math.max(umax, x.u)
end
check(zmin > 0 and zmax < 0.2, string.format("on the surface, just above it (%.2f to %.2f)", zmin, zmax))
check(umin >= 0 and umax <= 1, "the whole texture, once")
-- a ledge: the floor ends at x = 5; the cells over the void are left out
local tl = util.TraceLine
util.TraceLine = function(t)
	if t.start.x > 5 then return { Hit = false, HitPos = t.endpos, HitNormal = Vector(0, 0, 0), Fraction = 1 } end
	return tl(t)
end
SM.Lay(Vector(0, 50, 0), Vector(0, 0, 1), "ghm_physblood/crb/bp4", 30, 30, Vector(1, 0, 0))
local n2 = #meshes.last
local xmax = -1e9
for k = n2 - 1, 1, -1 do end
util.TraceLine = tl
local lastCells = 0
do
	-- the open list holds both splats now: count the second one's cells by position
	local cnt, xm = 0, -1e9
	for _, x in ipairs(meshes.last) do if x.pos.y > 30 then cnt = cnt + 1 xm = math.max(xm, x.pos.x) end end
	lastCells = cnt / 6
	xmax = xm
end
check(lastCells > 6 and lastCells < 36 and xmax <= 5 + 30 / 6 * 1.01, string.format("at a ledge: the cells over the void are left out (%d cells, to x %.1f)", lastCells, xmax))
-- turned with the way the blood went, and stretched at a glancing hit
SM.Clear()
SM.Lay(Vector(0, 0, 0), Vector(0, 0, 1), "ghm_physblood/crb/bp5", 20, 20, Vector(0.3, 0, -1))
local ex, ey = 0, 0
for _, x in ipairs(meshes.last) do ex, ey = math.max(ex, math.abs(x.pos.x)), math.max(ey, math.abs(x.pos.y)) end
check(ex > 10.2 or ey > 10.2, string.format("square-ish hit: about its size (%.1f x %.1f)", ex, ey))
SM.Clear()
SM.Lay(Vector(0, 0, 0), Vector(0, 0, 1), "ghm_physblood/crb/bp5", 20, 20, Vector(1, 0, -0.5))
ex, ey = 0, 0
for _, x in ipairs(meshes.last) do ex, ey = math.max(ex, math.abs(x.pos.x)), math.max(ey, math.abs(x.pos.y)) end
check(ex > ey * 1.4, string.format("a glancing hit along +x: stretched along it (%.1f along, %.1f across)", ex, ey))
-- a wall: laid on it (normal -x), only where the wall is
M.wallX = 100
SM.Clear()
local okw = SM.Lay(Vector(100, 0, 40), Vector(-1, 0, 0), "ghm_physblood/crb/bp6", 30, 30, Vector(1, 0, 0))
local onWall = true
for _, x in ipairs(meshes.last or {}) do if math.abs(x.pos.x - 99.94) > 0.2 then onWall = false end end
check(okw and onWall, "on a wall: on its surface")
M.wallX = nil
-- nothing there: nothing laid
check(not SM.Lay(Vector(0, 0, 500), Vector(0, 0, 1), "ghm_physblood/crb/bp7", 30, 30), "in the air: nothing laid")
-- batches and the budget: the oldest go first
SM.Clear()
RunConsoleCommand("ghmpb_splats_kept", "100")
for i = 1, 300 do SM.Lay(Vector(i * 40, 0, 0), Vector(0, 0, 1), "ghm_physblood/crb/bp" .. (i % 36 + 1), 20, 20) end
check(SM.Count() <= 100 and SM.Count() >= 88, "300 splats with 100 kept: the oldest went (" .. SM.Count() .. " kept)")
local nm = #SM.batches
for _, o in pairs(SM.open) do if o.mesh then nm = nm + 1 end end
check(nm >= 1, "kept as static meshes (" .. nm .. ")")
local d0 = meshes.drawn
SM.Draw()
check(meshes.drawn > d0 and setMat > 0, "drawn")
M.now = M.now + 5
SM.Update()
local open = 0 for _ in pairs(SM.open) do open = open + 1 end
check(open == 0, "after 2 s the open splats are baked too")
RunConsoleCommand("ghmpb_splats_kept", "3000")
-- clear
SM.Clear()
check(SM.Count() == 0 and #SM.batches == 0, "ghmpb_clear: all gone")

-- ---------------- the forensic code sends world hits here, props keep engine decals
local hits = {}
G.Surfaces = { Impact = function() return true end, IsGround = function() return true end }
G.Entities = { Impact = function() return true end }
G.Particles = { Spawn = function() end, Thin = function() return 1 end, Count = function() return 0 end }
M.Load({ "cl_spatterdata.lua", "cl_forensic.lua" })
local F = G.Forensic
local decals = {}
util.DecalEx = function(m, ent, pos, n, col, w, h) decals[#decals + 1] = { m = m, ent = ent } end
Material = function(name) return { name = name, IsError = function() return false end } end
game = game or {}
game.GetWorld = game.GetWorld or function() return NULL end
M.now = M.now + 10
check(F.CRBDecal(Vector(0, 0, 0), Vector(0, 0, 1), 8, nil, 0, Vector(1, 0, -1)) and #decals == 0 and SM.Count() == 1,
	"a splat on the world: drawn by PhysBlood, no engine decal")
check(F.CRBDecal(Vector(0, 40, 0), Vector(0, 0, 1), 8, nil, G.BLOOD_YELLOW) and SM.Count() == 2, "yellow blood too")
local yellow = false
for k in pairs(created) do if k:find("t1_bp", 1, true) then yellow = true end end
check(yellow, "with the yellow splats")
local prop = M.Ent("prop_physics")
F.CRBDecal(Vector(0, 80, 0), Vector(0, 0, 1), 8, prop, 0)
check(#decals == 1 and decals[1].ent == prop, "on a prop: an engine decal (it moves)")
RunConsoleCommand("ghmpb_splat_mesh", "0")
M.now = M.now + 10
F.CRBDecal(Vector(0, 120, 0), Vector(0, 0, 1), 8, nil, 0)
check(#decals == 2, "ghmpb_splat_mesh 0: engine decals again")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
