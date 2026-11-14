-- 1.21.0: the map file's texture mapping (cl_bsptex.lua) read from a real map (the bricks test map), and the lookup of
-- the face under a point (client, mocked GMod; a File object over the map file)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua" })
local G = GHMPB
local fh = io.open("../../addon/ghm_physblood/maps/ghmpb_bricks.bsp", "rb") or io.open("../../../garrysmod/addons/ghm_physblood/maps/ghmpb_bricks.bsp", "rb")
local DATA = fh:read("*a") fh:close()

-- File (the GMod file object) over a string
local function u32(s, o) local a, b, c, d = s:byte(o, o + 3) return a + b * 256 + c * 65536 + d * 16777216 end
local F = {}
F.__index = F
function F:Read(n) local r = DATA:sub(self.p + 1, self.p + n) self.p = self.p + n return r end
function F:Seek(p) self.p = p end
function F:Skip(n) self.p = self.p + n end
function F:Tell() return self.p end
function F:Close() end
function F:ReadByte() local b = DATA:byte(self.p + 1) self.p = self.p + 1 return b end
function F:ReadShort() local a, b = DATA:byte(self.p + 1, self.p + 2) self.p = self.p + 2 local v = a + b * 256 return v >= 32768 and v - 65536 or v end
function F:ReadLong() local v = u32(DATA, self.p + 1) self.p = self.p + 4 return v >= 2147483648 and v - 4294967296 or v end
function F:ReadFloat()
	local v = u32(DATA, self.p + 1) self.p = self.p + 4
	local sign = v >= 2147483648 and -1 or 1
	local e = math.floor(v / 8388608) % 256
	local m = v % 8388608
	if e == 0 then return sign * m * 2 ^ -149 end
	if e == 255 then return sign * math.huge end
	return sign * (1 + m / 8388608) * 2 ^ (e - 127)
end
_G.file = { Open = function(path, mode, where) return setmetatable({ p = 0 }, F) end }
_G.game = { GetMap = function() return "ghmpb_bricks" end }
_G.hook = _G.hook or {}
local thinks = {}
hook.Add = function(ev, name, fn) if ev == "Think" then thinks[name] = fn end end
hook.Remove = function(ev, name) if ev == "Think" then thinks[name] = nil end end
function SysTime() return os.clock() end
_G.bit = _G.bit or require("bit")
M.Load({ "cl_bsptex.lua" })
local B = G.BspTex
B.Start()
local frames = 0
while thinks.ghmpb_bsptex and frames < 10000 do thinks.ghmpb_bsptex() frames = frames + 1 end
check(B.state == "ready", "the map is read (" .. tostring(B.state) .. (B.err and (": " .. B.err) or "") .. ") in " .. frames .. " frames")
local nt = 0
for name, list in pairs(B.byTex or {}) do nt = nt + 1 print(string.format("     %-40s %d faces", name, #list)) end
check(nt > 0 and (B.faces or 0) > 0, "faces with textures: " .. tostring(B.faces))

-- every face's texinfo maps its own lightmap rectangle's centre back into it: the lookup finds a face for points on faces
local tested, found = 0, 0
for name, list in pairs(B.byTex or {}) do
	for _, fc in ipairs(list) do
		if not fc.disp and (fc.s0 > 0 or fc.s1 > 0) and tested < 400 then
			-- the point at the middle of the face's lightmap rectangle, on its plane
			local l0, l1, pl = fc.ti.l0, fc.ti.l1, fc.pl
			local n = Vector(pl[1], pl[2], pl[3])
			-- solve: P . l0 + l0w - m0 = s0/2, P . l1 + l1w - m1 = s1/2, P . n = d
			local A = { { l0[1], l0[2], l0[3], fc.m0 + fc.s0 / 2 - l0[4] }, { l1[1], l1[2], l1[3], fc.m1 + fc.s1 / 2 - l1[4] }, { pl[1], pl[2], pl[3], pl[4] } }
			local function det3(a) return a[1][1] * (a[2][2] * a[3][3] - a[2][3] * a[3][2]) - a[1][2] * (a[2][1] * a[3][3] - a[2][3] * a[3][1]) + a[1][3] * (a[2][1] * a[3][2] - a[2][2] * a[3][1]) end
			local D = det3(A)
			if math.abs(D) > 1e-9 then
				local function col(k) local c = {} for r = 1, 3 do c[r] = {} for q = 1, 3 do c[r][q] = (q == k) and A[r][4] or A[r][q] end end return det3(c) / D end
				local P = Vector(col(1), col(2), col(3))
				tested = tested + 1
				local ti = B.Lookup(P, n, string.upper(name))
				if ti then found = found + 1 end
			end
		end
	end
end
check(tested > 0 and found == tested, string.format("a point on a face finds a face of its texture (%d of %d)", found, tested))
-- a texture coordinate from the lookup is in the texture's repeat units (u = P . s + so)
local any = next(B.byTex or {})
local fc = any and B.byTex[any][1]
if fc then
	local s = fc.ti.s
	check(s:Length() > 0 and s:Length() < 1, string.format("texture axes over the texture size (|s| = %.4f per unit: %.1f units per repeat)", s:Length(), 1 / s:Length()))
end
check(B.Lookup(Vector(1e5, 1e5, 1e5), Vector(0, 0, 1), any or "") == nil, "far away from every face: nothing")
check(B.Lookup(Vector(0, 0, 0), Vector(0, 0, 1), "no/such/texture") == nil, "an unknown texture: nothing")

-- ---------------- a patch on a face gets that face's mapping and the material's normal map (cl_surfaces.lua S.AssignBump)
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function GetConVarNumber(n) return n == "sv_gravity" and 600 or 0 end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
_G.util.PointContents = function() return 0 end
G.GPU = {}
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.DiagCount = function() end
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end, Caps = function() return { patches = 999, aft = 999 } end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua", "cl_surfaces.lua" })
local S = G.Surfaces
local bumpTex = { IsError = function() return false end, GetName = function() return "ghmpb/test/brick_normal" end }
local MATS = { ["ghmpb/test/brick"] = { bump = bumpTex, ss = 0 }, ["ghmpb/test/mortar"] = { bump = bumpTex, ss = 1 }, ["ghmpb/test/concrete"] = {} }
function Material(name)
	local m = MATS[B.Norm(name)] or {}
	return { IsError = function() return false end, GetTexture = function(_, k) return k == "$bumpmap" and m.bump or nil end,
		GetInt = function(_, k) return k == "$ssbump" and m.ss or nil end }
end
-- a point on a brick face
local fcB = B.byTex["ghmpb/test/brick"][1]
local function onFace(fc)
	local l0, l1, pl = fc.ti.l0, fc.ti.l1, fc.pl
	local A = { { l0[1], l0[2], l0[3], fc.m0 + fc.s0 / 2 - l0[4] }, { l1[1], l1[2], l1[3], fc.m1 + fc.s1 / 2 - l1[4] }, { pl[1], pl[2], pl[3], pl[4] } }
	local function det3(a) return a[1][1] * (a[2][2] * a[3][3] - a[2][3] * a[3][2]) - a[1][2] * (a[2][1] * a[3][3] - a[2][3] * a[3][1]) + a[1][3] * (a[2][1] * a[3][2] - a[2][2] * a[3][1]) end
	local D = det3(A)
	local function col(k) local c = {} for r = 1, 3 do c[r] = {} for q = 1, 3 do c[r][q] = (q == k) and A[r][4] or A[r][q] end end return det3(c) / D end
	return Vector(col(1), col(2), col(3)), Vector(pl[1], pl[2], pl[3])
end
local P1, N1 = onFace(fcB)
local p = { center = P1, N = N1, albedoTex = "GHMPB/TEST/BRICK" }
S.AssignBump(p)
check(p.bumpDone and p.bumpTex == bumpTex and p.bumpKind == 1 and p.bmap ~= nil, "a brick patch: the brick normal map, as a normal map")
check(p.bmap and p.bmap.name == "ghmpb/test/brick" and p.meshDirty and p.forceDirty, "its face's texture mapping, and its meshes and force field are made again")
local fcM = B.byTex["ghmpb/test/mortar"][1]
local P2, N2 = onFace(fcM)
local q = { center = P2, N = N2, albedoTex = "ghmpb/test/mortar" }
S.AssignBump(q)
check(q.bumpKind == 2, "a self-shadowing ssbump map is told apart (kind 2)")
local fcC = B.byTex["ghmpb/test/concrete"][1]
local P3, N3 = onFace(fcC)
local r = { center = P3, N = N3, albedoTex = "ghmpb/test/concrete" }
S.AssignBump(r)
check(r.bumpDone and r.bumpTex == nil and (r.bumpKind or 0) == 0, "a material without a normal map: none")
G.cv.surfbump:SetInt(0)
local t = { center = P1, N = N1, albedoTex = "ghmpb/test/brick" }
S.AssignBump(t)
check(t.bumpDone and t.bumpTex == nil, "ghmpb_surface_normals 0: none")
G.cv.surfbump:SetInt(1)
-- relief depth per kind of surface (how thick blood levels the relief out)
check(G.SurfaceMatValue(7, "relief") < 0.05 and G.SurfaceMatValue(14, "relief") > 2 and G.SurfaceMatValue(0, "relief") > 0.05,
	"relief depth: glass shallow, gravel deep, the default in between")
local rows = G.GPU.MatTableList and G.GPU.MatTableList()
local relRow
for _, rw in ipairs(rows or {}) do if rw[1] == 14 * 2 and rw[2] == 3 * 2 then relRow = rw end end
check(relRow and math.abs(relRow[5][2] - G.SurfaceMatValue(14, "relief")) < 1e-9, "the material table carries it (row 3 .y)")

-- a file that is not a map
DATA = "IBSP" .. string.rep("\0", 2000)
B.state, B.byTex = nil, nil
B.Start()
while thinks.ghmpb_bsptex do thinks.ghmpb_bsptex() end
check(B.state == "failed" and B.Lookup(Vector(0, 0, 0), Vector(0, 0, 1), "x") == nil, "not a map file: off (" .. tostring(B.err) .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
