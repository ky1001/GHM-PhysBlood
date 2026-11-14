-- 1.23.0: fluid-simulated blood bursts (VAT, baked by tools/bake_vat.py into data_static/ghmpb/vat/*.dat): the files are
-- read, their frames built into meshes a few at a time, bursts play at wounds / jets / big drops and end with their
-- frames; the toggle frees everything (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
function EyePos() return Vector(0, -200, 64) end
function IsValid(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end

-- the addon's data_static (next to its lua folder)
local root = M.base:gsub("lua/ghm_physblood/$", "")
local function real(path) return root .. path end
file.Exists = function(path) local f = io.open(real(path), "rb") if f then f:close() return true end return false end
file.Open = function(path, mode)
	local f = io.open(real(path), "rb")
	if not f then return nil end
	local data = f:read("*a") f:close()
	local pos = 1
	return { Size = function() return #data end, Read = function(_, n) local s = data:sub(pos, pos + n - 1) pos = pos + n return s end,
		Close = function() end }
end

-- engine: angles, matrices, materials, meshes
local A = {}
A.__index = A
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
function A:RotateAroundAxis(axis, deg) self.r = self.r + deg end
local VecMeta = getmetatable(Vector(0, 0, 0))
function VecMeta:Angle() return Angle(0, 0, 0) end
function Matrix() return { Identity = function() end, SetTranslation = function() end, SetAngles = function() end, Scale = function() end } end
local mats = {}
function Material(name)
	mats[name] = mats[name] or { name = name, v = {}, SetVector = function(self, k, x) self.v[k] = x end, GetVector = function(self, k) return self.v[k] end }
	return mats[name]
end
local made, destroyed, drawn, vertsAdded = 0, 0, 0, 0
local imeshOK = true
local current
function Mesh() made = made + 1 local m = { verts = 0, Destroy = function() destroyed = destroyed + 1 end, Draw = function() drawn = drawn + 1 end }
	m.BuildFromTriangles = function(self, v) self.verts = #v vertsAdded = vertsAdded + #v end
	return m end
_G.mesh = {
	Begin = function(m, prim, n)
		if type(m) == "table" then
			if not imeshOK then error("bad argument #1 to 'Begin' (number expected, got table)") end
			current = { m = m, n = n, v = 0 }
		else current = { n = prim, v = 0 } end
	end,
	End = function() assert(current.v == current.n * 3, "triangles: " .. current.v .. " vertices for " .. current.n) if current.m then current.m.verts = current.v end current = nil end,
	Position = function(v) assert(v.x == v.x, "NaN") end, Normal = function(v) local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) assert(l > 0.9 and l < 1.1, "normal length " .. l) end,
	TexCoord = function() end, TangentS = function() end, TangentT = function() end, UserData = function() end,
	AdvanceVertex = function() current.v = current.v + 1 vertsAdded = vertsAdded + 1 end,
}
local lightCalls = 0
_G.render = { SuppressEngineLighting = function() end, SetModelLighting = function(k, r, g, b) assert(k >= 0 and k <= 5 and r >= 0) lightCalls = lightCalls + 1 end,
	SetLocalModelLights = function() end, SetMaterial = function() end, GetRenderTarget = function() return nil end }
_G.cam = { PushModelMatrix = function() end, PopModelMatrix = function() end }
_G.MATERIAL_TRIANGLES, _G.MATERIAL_LIGHT_DIRECTIONAL = 2, 2
G.Light = { Get = function() return { r = { 0.3, 0.1, 0, 0.2 }, g = { 0.3, 0.1, 0, 0.2 }, b = { 0.3, 0.1, 0, 0.2 }, dir = Vector(0, 0, 1), col = Vector(1, 1, 1), amb = Vector(0.3, 0.3, 0.3) } end }
G.GPU = { FreshAbs = function() return 1 end }
G.Prof = { Count = function() end, Lap = function() end }
M.Load({ "cl_util.lua" })
G.U.InViewPos = function() return true end
M.Load({ "cl_vat.lua" })
local V = G.VAT

-- ---------------- the files
check(V.Installed(), "the burst data is found (data_static/ghmpb/vat)")
check(math.abs(V.F32(string.char(0, 0, 0xF0, 0x41), 1) - 30) < 1e-6 and math.abs(V.F32(string.char(0, 0, 0x70, 0x41), 1) - 15) < 1e-6
	and math.abs(V.F32(string.char(0, 0, 0x80, 0xBF), 1) + 1) < 1e-6, "float decoding (30, 15, -1)")
local f = file.Open(V.DIR .. "omni01.dat", "rb")
local h = V.Parse(f:Read(f:Size()))
check(h and h.fps == 30 and #h.frames == 28, "omni01: 30 fps, 28 frames (" .. (h and #h.frames or -1) .. ")")
local okRange, okIdx, okN = true, true, true
for _, fr in ipairs(h.frames) do
	for v = 0, fr.n - 1 do
		for k = 1, 3 do
			local x = fr.p[v * 3 + k]
			if x < h.bmin[k] - 1e-3 or x > h.bmax[k] + 1e-3 then okRange = false end
		end
		local nx, ny, nz = fr.q[v * 3 + 1], fr.q[v * 3 + 2], fr.q[v * 3 + 3]
		local l = math.sqrt(nx * nx + ny * ny + nz * nz)
		if l < 0.9 or l > 1.1 then okN = false end
	end
	for j = 1, fr.t * 3 do if fr.i[j] < 0 or fr.i[j] >= fr.n then okIdx = false end end
end
check(okRange and okIdx and okN, "every frame: positions in the box, unit normals, triangles on its vertices")
check(h.bmax[1] > 10 and h.bmin[1] < -5, "omni01 spans ~20 units (a burst of ~40 cm)")
local fr = file.Open(V.DIR .. "ribbon03.dat", "rb")
local hr = V.Parse(fr:Read(fr:Size()))
check(hr.bmax[1] > 60 and hr.bmax[2] < 15, "ribbon03 runs along +x (thrown that way)")
local fc = file.Open(V.DIR .. "crown3.dat", "rb")
local hc = V.Parse(fc:Read(fc:Size()))
check(hc.bmin[1] > -0.5 and hc.bmax[1] < 4, "crown3 rises along +x from its base")
check(V.ParseHeader("GVAT" .. string.rep("\0", 40)) == nil, "a broken file is refused")

-- ---------------- warm-up: frames built a few at a time
M.now = 5
local steps = 0
while V.Step(0.002) and steps < 10000 do steps = steps + 1 M.now = M.now + 0.016 end
local ready, total = 0, 0
for _, e in pairs(V.effects) do total = total + 1 if e.state == "ready" then ready = ready + 1 end end
check(total == 12 and ready == 12, "all 12 effects built (" .. ready .. " of " .. total .. ")")
check(V.effects.omni01.meshes[1].verts == V.effects.omni01.frames[1].t * 3, "a frame mesh: 3 vertices per triangle")
check(V.effects.omni01.h.s == nil, "the file bytes are dropped once built")

-- ---------------- playing
local inst = V.Spawn("back", Vector(0, 0, 50), Vector(0, -1, 0), 0.5, 2, 0)
check(inst and (inst.e.name == "omni01" or inst.e.name == "omni02" or inst.e.name == "omni03" or inst.e.name == "omni10"), "an entry burst picks one of its effects")
local d0 = drawn
V.Draw()
check(drawn == d0 + 1 and lightCalls >= 6, "it draws, lit (ambient cube)")
M.now = M.now + 100
V.Draw()
check(#V.inst == 0, "at its last frame it ends")
check(V.Spawn("nonsense", Vector(0, 0, 0), Vector(1, 0, 0)) == nil, "an unknown kind plays nothing")
check(V.Spawn("back", Vector(0, 9000, 0), Vector(1, 0, 0)) == nil, "too far away: nothing")
for i = 1, 30 do V.Spawn("fwd", Vector(i, 0, 50), Vector(1, 0, 0), 1, 1, 0) end
check(#V.inst == V.cvMax:GetInt(), "at most ghmpb_vat_max at once")
V.Clear()
-- crowns: only big, fast drops on floors, a few a second, not twice on one spot
local before = V.stats.spawned
V.OnDropLand(Vector(0, 0, 0), Vector(0, 0, 1), 0.8, 500, 0)
V.OnDropLand(Vector(0, 0, 0), Vector(1, 0, 0), 2.5, 500, 0)
check(V.stats.spawned == before, "small drops and walls: no crown")
V.OnDropLand(Vector(0, 0, 0), Vector(0, 0, 1), 2.5, 500, 0)
V.OnDropLand(Vector(1, 0, 0), Vector(0, 0, 1), 2.5, 500, 0)
check(V.stats.spawned == before + 1, "a big fast drop: a crown; another right after: none")
M.now = M.now + 2
V.OnDropLand(Vector(100, 0, 0), Vector(0, 0, 1), 2.5, 500, 0)
check(V.stats.spawned == before + 2, "later, elsewhere: another")
local e = {}
V.OnJet(e, Vector(0, 0, 40), Vector(0, 1, 0), 250, 0)
V.OnJet(e, Vector(0, 0, 40), Vector(0, 1, 0), 250, 0)
check(V.stats.spawned == before + 3, "an arterial jet: a ribbon per beat, not every tick")
V.OnEntry(Vector(0, 0, 50), Vector(-1, 0, 0), Vector(1, 0, 0), 1, 1)
V.OnExit(Vector(10, 0, 50), Vector(1, 0, 0), Vector(1, 0, 0), 1, 1)
V.OnBlunt(Vector(0, 0, 50), Vector(-1, 0, 0), Vector(1, 0, 0), 1, 2)
V.OnBlast(Vector(0, 0, 50), Vector(1, 0, 0), 1, 3)
check(V.stats.spawned == before + 7, "entry, exit, blow and blast each play one")
local m1 = V.Mat(1)
check(m1:GetVector("$color2") ~= nil and m1:GetVector("$color2").y > m1:GetVector("$color2").z, "yellow blood: its own material, colour from the settings")

-- ---------------- colour per blood type (1.23.1)
local function c2(bt) return V.Mat(bt):GetVector("$color2") end
local red0, yel0 = c2(0), c2(1)
RunConsoleCommand("ghmpb_vat_red_bright", "2")
local red1, yel1 = c2(0), c2(1)
check(math.abs(red1.x - red0.x * 2) < 1e-6 and math.abs(yel1.x - yel0.x) < 1e-9, "red brightness doubles red bursts only")
RunConsoleCommand("ghmpb_vat_red_bright", "1")
RunConsoleCommand("ghmpb_vat_red_hue", "1")
local red2 = c2(0)
check(red2.y > red0.y * 1.5 and math.abs(red2.x - red0.x) / red0.x < 0.05, "red hue +: towards orange (more green, same red)")
RunConsoleCommand("ghmpb_vat_red_hue", "-1")
local red3 = c2(0)
check(red3.z > red0.z * 1.5 and red3.y <= red0.y + 1e-9, "red hue -: towards crimson / purple (more blue)")
RunConsoleCommand("ghmpb_vat_red_hue", "0")
RunConsoleCommand("ghmpb_vat_yellow_hue", "1")
local yel2 = c2(1)
check(yel2.x < yel0.x and yel2.y > yel2.x, "yellow hue +: towards green")
RunConsoleCommand("ghmpb_vat_yellow_hue", "0")
RunConsoleCommand("ghmpb_vat_bright", "0.5")
local red4, grn4 = c2(0), c2(2)
RunConsoleCommand("ghmpb_vat_bright", "1")
local grn5 = c2(2)
check(math.abs(red4.x - red0.x * 0.5) < 1e-6 and math.abs(grn4.y - grn5.y * 0.5) < 1e-6, "the bursts' brightness scales every type")
local r, g, b = V.HueShift(200, 20, 10, 0)
check(math.abs(r - 200) < 1e-6 and math.abs(g - 20) < 1e-6 and math.abs(b - 10) < 1e-6, "no hue turn: the colour stays")
local pc = V.PreviewColour(1)
check(pc and pc.r >= 0 and pc.r <= 255 and pc.g <= 255, "a preview colour for the settings window")

-- ---------------- the toggle
RunConsoleCommand("ghmpb_vat", "0")
check(next(V.effects) == nil and destroyed > 0 and #V.inst == 0, "off: the meshes are freed")
check(V.Spawn("back", Vector(0, 0, 50), Vector(0, -1, 0)) == nil, "off: nothing plays")
RunConsoleCommand("ghmpb_vat", "1")
-- (a build of GMod without IMesh support in mesh.Begin: vertex tables)
imeshOK = false
steps = 0
while V.Step(0.002) and steps < 10000 do steps = steps + 1 end
check(V.Ready("omni01") and V.effects.omni01.meshes[1].verts == V.effects.omni01.frames[1].t * 3, "the vertex-table fallback builds the same meshes")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
