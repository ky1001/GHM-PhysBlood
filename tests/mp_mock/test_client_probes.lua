-- 1.25.0: reflection probes (cl_probes.lua) and the lights of the map (cl_maplights.lua): grouping, placing, the cube faces
-- rendered within the time budget in the layout the film shaders read (ghmpb_common.h ghmpb_cubeFace), the data texels
-- decoded as the shaders decode them, the lights picked from the BSP's world light lump and players' flashlights, binding
-- 1.25.1: the floor mirror - the floor picked, the mirrored camera, the clip plane, the picture copied into the lower half of
-- the atlases on that floor with its flag texel, the shader's lookup geometry, off again
-- (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 1
function FrameNumber() return frame end
local eye = Vector(0, -300, 64)
function EyePos() return eye end
function EyeAngles() return Angle(0, 90, 0) end
function LocalPlayer() return NULL end
local players = {}
_G.player = { GetAll = function() return players end }
_G.ents = { FindByClass = function() return {} end }
_G.MATERIAL_RT_DEPTH_SEPARATE, _G.MATERIAL_RT_DEPTH_NONE, _G.RT_SIZE_LITERAL = 1, 0, 1
_G.IMAGE_FORMAT_RGBA8888, _G.IMAGE_FORMAT_RGBA16161616F, _G.MATERIAL_QUADS = 0, 24, 1

-- ---------------- render mocks: what is drawn into which target
local rts = {}
function GetRenderTargetEx(name, w, h, sz, depth)
	if not rts[name] then rts[name] = { name = name, w = w, h = h, depth = depth, GetName = function(s) return s.name end,
		Width = function(s) return s.w end, Height = function(s) return s.h end } end
	return rts[name]
end
local stack, cur, views, copies, written = {}, nil, {}, 0, {}
local clips, popped, clipOn = {}, 0, false
local curMat
local renderCost = 0.005
local failView = false
_G.render = {
	PushRenderTarget = function(rt) stack[#stack + 1] = cur cur = rt end,
	PopRenderTarget = function() cur = table.remove(stack) end,
	Clear = function() end,
	SetMaterial = function(m) curMat = m end,
	CopyTexture = function() copies = copies + 1 end,
	RenderView = function(v)
		if failView then error("RenderView failed") end
		views[#views + 1] = { target = cur, origin = Vector(v.origin), angles = v.angles, fov = v.fov, w = v.w, h = v.h, aspect = v.aspect,
			hud = v.drawhud, vm = v.drawviewmodel, zfar = v.zfar }
		M.now = M.now + renderCost
	end,
	GetRenderTarget = function() return cur end,
	EnableClipping = function(on) local was = clipOn clipOn = on return was end,
	PushCustomClipPlane = function(n, d) clips[#clips + 1] = { n = Vector(n), d = d, on = clipOn } end,
	PopCustomClipPlane = function() popped = popped + 1 end,
}
function ScrW() return 1920 end
function ScrH() return 1080 end
_G.cam = { Start2D = function() end, End2D = function() end }
-- quads: record each texel / tile drawn, with its payload
local qverts = {}
_G.mesh = {
	Begin = function() qverts = {} end,
	Position = function(v) qverts[#qverts + 1] = { pos = Vector(v) } end,
	TexCoord = function(i, a, b, c, d) local q = qverts[#qverts] if i == 1 then q.t1 = { a, b, c, d } end end,
	AdvanceVertex = function() end,
	End = function()
		for k = 1, #qverts, 4 do
			local a, c = qverts[k], qverts[k + 2]
			local W, H = cur and cur.w or 1, cur and cur.h or 1
			-- (clip space with the half pixel correction undone)
			local x0 = math.floor(((a.pos.x + 1 / W) + 1) / 2 * W + 0.5)
			local y0 = math.floor((1 - (a.pos.y - 1 / H)) / 2 * H + 0.5)
			local x1 = math.floor(((c.pos.x + 1 / W) + 1) / 2 * W + 0.5)
			local y1 = math.floor((1 - (c.pos.y - 1 / H)) / 2 * H + 0.5)
			written[#written + 1] = { target = cur, mat = curMat, x0 = x0, y0 = y0, x1 = x1, y1 = y1, t1 = a.t1 }
		end
	end,
}
function CreateMaterial(name, shader, kv)
	local m = { name = name, shader = shader, kv = kv, tex = {} }
	function m:SetTexture(k, t) self.tex[k] = t self.sets = (self.sets or 0) + 1 end
	function m:SetFloat() end
	function m:SetMatrix() end
	function m:GetName() return self.name end
	return m
end
function Matrix() return { SetUnpacked = function() end } end
G.Prof = { Count = function() end, Lap = function() return 0 end }
G.Lite = { on = false }

-- ---------------- a BSP with a world light lump (LDR, version 0: 88 bytes a light)
local function le32(n) if n < 0 then n = n + 4294967296 end return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function f32(x)
	if x == 0 then return string.char(0, 0, 0, 0) end
	local sign = x < 0 and 1 or 0
	x = math.abs(x)
	local e = math.floor(math.log(x) / math.log(2))
	local m = x / 2 ^ e - 1
	local bits = sign * 2147483648 + (e + 127) * 8388608 + math.floor(m * 8388608 + 0.5)
	return le32(bits)
end
local function Light(pos, int, typ, dir, stop, stop2)
	local t = { f32(pos.x), f32(pos.y), f32(pos.z), f32(int), f32(int), f32(int * 0.8), f32(dir.x), f32(dir.y), f32(dir.z),
		le32(0), le32(typ), le32(0), f32(stop or 0), f32(stop2 or 0), f32(0), f32(0), f32(0), f32(0), f32(1), le32(0), le32(0), le32(0) }
	return table.concat(t)
end
local lights = {
	Light(Vector(0, 0, 120), 4000, 1, Vector(0, 0, 0)),                              -- a lamp right above the pool
	Light(Vector(0, 0, -200), 9000, 1, Vector(0, 0, 0)),                             -- under the floor (blocked)
	Light(Vector(150, 0, 100), 50000, 2, Vector(1, 0, 0), 0.9, 0.8),                 -- a spot pointing away
	Light(Vector(-100, 50, 90), 2500, 2, Vector(0.6, -0.3, -0.75):GetNormalized(), 0.85, 0.7),   -- a spot on the pool
}
local lump = table.concat(lights)
local hdrLen = 8 + 64 * 16
local function BSP()
	local t = { "VBSP", le32(20) }
	for k = 0, 63 do
		if k == 15 then t[#t + 1] = le32(hdrLen) .. le32(#lump) .. le32(0) .. le32(0)
		else t[#t + 1] = le32(0) .. le32(0) .. le32(0) .. le32(0) end
	end
	return table.concat(t) .. lump
end
local bsp = BSP()
_G.file.Open = function(path)
	if path ~= "maps/test.bsp" then return nil end
	local f = { p = 0 }
	function f:Read(n) local s = bsp:sub(self.p + 1, self.p + n) self.p = self.p + n return s end
	function f:Seek(n) self.p = n end
	function f:Skip(n) self.p = self.p + n end
	function f:ReadLong()
		local b1, b2, b3, b4 = bsp:byte(self.p + 1, self.p + 4) self.p = self.p + 4
		local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
		return v >= 2147483648 and v - 4294967296 or v
	end
	function f:ReadFloat()
		local b1, b2, b3, b4 = bsp:byte(self.p + 1, self.p + 4) self.p = self.p + 4
		local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
		if v == 0 then return 0 end
		local sign = v >= 2147483648 and -1 or 1
		if sign < 0 then v = v - 2147483648 end
		local e = math.floor(v / 8388608) - 127
		local m = (v % 8388608) / 8388608 + 1
		return sign * m * 2 ^ e
	end
	function f:Close() end
	return f
end

M.Load({ "cl_util.lua", "cl_gpu.lua", "cl_maplights.lua", "cl_probes.lua" })
local P, ML = G.Probes, G.MapLights
local GPU = G.GPU

-- ---------------- the shaders' decoders, in Lua
local function byte(v) return math.floor(v * 255 + 0.5) end
local function u16(hi, lo) return byte(hi) * 256 + byte(lo) end
local function pos3(a, b) return Vector(u16(a[1], a[2]), u16(a[3], a[4]), u16(b[1], b[2])) * (32768 / 65535) - Vector(16384, 16384, 16384) end
local function cubeFace(d)
	local ax, ay, az = math.abs(d.x), math.abs(d.y), math.abs(d.z)
	local xm = ax >= ay and ax >= az
	local ym = not xm and ay >= az
	local m = xm and ax or (ym and ay or az)
	local sg = ((xm and d.x) or (ym and d.y) or d.z) >= 0 and 1 or -1
	local sx = xm and -sg * d.y or (ym and sg * d.x or -d.y)
	local sy = xm and d.z or (ym and d.z or -sg * d.x)
	return sx / m, sy / m, (xm and 0 or (ym and 2 or 4)) + (sg > 0 and 0 or 1)
end

-- ---------------- faces: RenderView's angles against the shaders' face mapping
local faceOK = true
for f = 1, 6 do
	local a = P.FACES[f]
	local F, R, U = a:Forward(), a:Right(), a:Up()
	for _, st in ipairs({ { -0.8, -0.6 }, { 0.5, 0.7 }, { 0, 0 }, { 0.9, -0.95 } }) do
		local d = F + R * st[1] + U * st[2]
		local sx, sy, face = cubeFace(d)
		if face ~= f - 1 or math.abs(sx - st[1]) > 1e-9 or math.abs(sy - st[2]) > 1e-9 then faceOK = false end
	end
	if F:Dot(P.FACE_DIR[f]) < 0.999 then faceOK = false end
end
check(faceOK, "the six RenderView angles land on the faces the shaders read, the right way round")

-- ---------------- data texels: header and lights, decoded as the shaders do
local lightsIn = { { pos = Vector(-1234.4, 5678.9, -301.2), range = 900, type = 3, col = Vector(1, 0.97, 0.92), I = 30000, dir = Vector(0, 0.6, -0.8), cosO = 0.88 } }
local tex = P.DataTexels(Vector(1001.3, -2002.6, 77.7), 333, true, lightsIn)
local at = {}
for _, q in ipairs(tex) do at[q[1] .. "," .. q[2]] = q[5] end
local c = pos3(at["384,0"], at["385,0"])
check((c - Vector(1001.3, -2002.6, 77.7)):Length() < 0.6, "header: the probe's centre to within half a unit (" .. tostring(c) .. ")")
check(byte(at["385,0"][3]) * 8 == 336 and byte(at["385,0"][4]) == 255, "header: sphere radius (to 8 u) and rendered flag")
local lp = pos3(at["384,1"], at["385,1"])
check((lp - lightsIn[1].pos):Length() < 0.6, "light 1: position")
check(byte(at["385,1"][4]) == 3 and byte(at["385,1"][3]) * 64 == 896, "light 1: type 3 (framebuffer units), range to 64 u")
local I = 2 ^ (at["386,1"][4] * 24 - 4)
check(math.abs(I / 30000 - 1) < 0.04, string.format("light 1: intensity within 4 %% (%.0f)", I))
check(math.abs(at["387,1"][4] - 0.88) < 0.005 and math.abs(at["387,1"][3] * 2 - 1 + 0.8) < 0.01, "light 1: spot direction and cone")
check(byte(at["385,2"][4]) == 0 and byte(at["385,4"][4]) == 0, "empty light slots read as type 0")
local inside = true
for _, q in ipairs(tex) do if q[1] < 384 or q[2] > 7 then inside = false end end
check(inside, "data texels only in the data area (x >= 384, rows 0..4)")

-- ---------------- the map's lights
local wl = ML.World()
check(#wl == 4, "the map's lights read from the BSP's world light lump (" .. #wl .. ")")
check(wl[3].type == 2 and math.abs(wl[3].stop - 0.9) < 1e-5 and math.abs(wl[1].col.x - 4000) < 1e-3, "with type, cone and intensity")
G.cv.maplights:SetInt(1)
local pick = ML.Pick(Vector(0, 0, 10), 4, "t")
local got = {}
for _, l in ipairs(pick) do got[#got + 1] = tostring(l.pos) end
check(#pick == 2, "picked for a pool at the origin: the lamp above and the spot on it (" .. table.concat(got, " ") .. ")")
check(pick[1] and pick[1].pos == Vector(0, 0, 120) and pick[1].type == 1, "the strongest first: the lamp above")
local exact = pick[1] and pick[1].col.x * pick[1].I / (110 * 110) or 0
check(math.abs(exact - 4000 / (110 * 110)) < 1e-6, "its intensity reproduces the engine's falloff at the pool (1 / d^2)")
-- other players' flashlights
local ply = { valid = true }
function ply:IsValid() return true end
function ply:Alive() return true end
function ply:FlashlightIsOn() return true end
function ply:IsDormant() return false end
function ply:EyePos() return Vector(0, -60, 64) end
function ply:EyeAngles() return Angle(45, 90, 0) end
function ply:EntIndex() return 7 end
players = { ply }
ML.dynT = nil
pick = ML.Pick(Vector(0, 0, 10), 4, "t2")
local fl = false
for _, l in ipairs(pick) do if l.type == 3 then fl = true end end
check(fl, "another player's flashlight on the pool: a spot in framebuffer units")
players = {}
ML.dynT = nil
G.cv.maplights:SetInt(0)
check(#ML.Pick(Vector(0, 0, 10), 4, "t3") == 0, "ghmpb_map_lights 0: none")
G.cv.maplights:SetInt(1)

-- ---------------- groups and probes
local function Patch(x, y, z, n)
	return { center = Vector(x, y, z), N = n or Vector(0, 0, 1), hasBlood = true }
end
G.Surfaces = { patches = {}, after = {} }
local S = G.Surfaces
S.patches.a = Patch(10, 10, 0)
S.patches.b = Patch(40, 30, 0)
S.after.c = Patch(20, 60, 0)
S.patches.d = Patch(600, 0, 0)                                    -- another room
S.after.e = Patch(-2000, -2000, 0)                                -- far away
S.patches.w = Patch(5, 300, 40, Vector(0, -1, 0))                 -- a wall in another cell
G.cv.reflprobes:SetInt(2)
G.cv.reflbudget:SetFloat(20)
P.Step()
local n, near = 0, nil
for k, pr in pairs(P.list) do n = n + 1 if pr.key == P.Key(Vector(10, 10, 0)) then near = pr end end
check(n == 2 and near ~= nil, "2 probes: the group closest to the camera has one (" .. n .. ")")
check(S.patches.a.reflRT == near.rt and S.after.c.reflRT == near.rt, "its patches and settled layers read it")
check(S.after.e.reflRT == nil, "blood far away: the fallback")
check(near.pos.z > 5 and near.pos.z < 30, string.format("the probe stands a little above the floor (z %.0f)", near.pos.z))
check(math.abs(near.pos.x - (10 * 2 + 40 * 2 + 20) / 5) < 1e-6, "in the middle of the group (weighted)")
check(P.fbReady and P.TexFor(S.after.e) == P.fb, "fallback atlas filled (map cubemap + lights) and bound to blood without a probe")
local envTiles = 0
for _, w in ipairs(written) do if w.target == near.rt and w.mat and w.mat.kv and w.mat.kv["$pixshader"] and w.mat.kv["$pixshader"]:find("probeenv") then envTiles = envTiles + 1 end end
check(envTiles == 12, "a new probe starts with the map's cubemap in its 6 faces and 6 blurred faces (" .. envTiles .. " tiles)")

-- ---------------- rendering faces within the budget
views = {}
for i = 1, 120 do
	frame = frame + 1
	M.now = M.now + 1 / 60
	P.Step()
end
local perSec = #views / 2
check(#views >= 6 and perSec <= 20 / (renderCost * 1000) + 3, string.format("%d faces in 2 s at 5 ms each, budget 20 ms/s (~4 a second)", #views))
local v1 = views[1]
check(v1 and v1.fov == 90 and v1.w == 128 and v1.h == 128 and v1.aspect == 1 and v1.hud == false and v1.vm == false,
	"a face: 90 deg, 128 x 128, square, no HUD / view model")
check(v1 and v1.target == P.FaceRT() and P.FaceRT().depth == MATERIAL_RT_DEPTH_SEPARATE, "into the face target (with its own depth buffer)")
local intoFloor = 0
for k = 1, math.min(#views, 6) do if views[k].angles == P.FACES[6] then intoFloor = intoFloor + 1 end end
check(intoFloor == 0 or #views < 6, "the face looking into the floor is not among the first rendered")
check(copies >= 1, "the blurred faces worked out from a copy (not read while drawn into)")
-- tiles: the face copied into its place in the atlas
local placed = true
for _, w in ipairs(written) do
	if w.mat and w.mat.kv and w.mat.kv["$pixshader"] and w.mat.kv["$pixshader"]:find("copy_ps30") then
		if (w.x1 - w.x0) ~= 128 or w.x0 % 128 ~= 0 or w.y0 % 128 ~= 0 or w.y0 > 128 then placed = false end
	end
end
check(placed, "faces land on the 128 grid of the atlas")
-- more budget: faster
views = {}
G.cv.reflbudget:SetFloat(60)
for i = 1, 120 do frame = frame + 1 M.now = M.now + 1 / 60 P.Step() end
check(#views > perSec * 2 * 2, "a bigger budget renders more faces (" .. #views .. " in 2 s)")
local valid = 0
for _, pr in pairs(P.list) do if pr.valid then valid = valid + 1 end end
check(valid == 2, "probes with all six faces rendered count as rendered (sphere and real light used): " .. valid)
G.cv.reflbudget:SetFloat(20)

-- ---------------- binding
local mat = CreateMaterial("x", "y", {})
P.Bind(mat, near.rt)
P.Bind(mat, near.rt)
check(mat.tex["$texture5"] == near.rt and mat.sets == 1, "bound once ($texture5), not set again while it stays the same")
check(P.TexAt(Vector(12, 15, 30)) == near.rt and P.TexAt(Vector(3000, 3000, 0)) == P.fb, "bodies: the nearest probe, else the fallback")

-- ---------------- (1.26.8) the probe's views without the engine's shadows (they made the shadows of bodies lying in
-- the blood flicker), and off by default
local shadowLog = {}
render.SetShadowsDisabled = function(on) shadowLog[#shadowLog + 1] = on and "off" or "on" end
local rv = render.RenderView
render.RenderView = function(v) shadowLog[#shadowLog + 1] = "view" return rv(v) end
local gc = 1
_G.GetConVar = function(n) if n == "r_shadows_gamecontrol" then return { GetInt = function() return gc end } end end
local anyPr
for _, pr in pairs(P.list) do anyPr = pr break end
if anyPr then
	P.RenderFace(anyPr, 1)
	check(table.concat(shadowLog, " ") == "off view on", "a probe face renders with the engine's shadows off, and they are on again after (" .. table.concat(shadowLog, " ") .. ")")
	shadowLog, gc = {}, 0
	P.RenderFace(anyPr, 2)
	check(table.concat(shadowLog, " ") == "view", "a map that has the shadows off keeps them off (" .. table.concat(shadowLog, " ") .. ")")
else
	check(false, "a probe to render")
end
render.RenderView = rv
check(G.cv.reflprobes:GetDefault() == "0", "the probes are off by default (the map's cubemap)")


-- ---------------- the floor mirror (1.25.1)
check(P.ATLAS == 1024 and near.rt.w == 1024 and P.fb.w == 1024, "atlases 1024 x 1024 (room for the floor mirror)")
local now0 = M.now
for _, p in pairs(S.patches) do p.wetUntil = now0 + 60 end
S.patches.hi = Patch(30, 40, 100)                                 -- a little wet blood on a higher floor, further off
S.patches.hi.wetUntil = now0 + 60
local camO, camA = Vector(0, -300, 64), Angle(30, 90, 0)
P.mpT = nil
check(P.MirrorPlane(camO, camA:Forward(), M.now) == 0, "the floor mirrored: the one with the most wet blood in front (z 0)")
P.mpT = nil
check(P.MirrorPlane(Vector(0, -300, -20), camA:Forward(), M.now) == nil, "a camera under the floor: none")
P.mpT = nil
local mo, ma = P.MirrorView(camO, camA, 0)
check(mo == Vector(0, -300, -64) and math.abs(ma.p + 30) < 1e-9 and ma.y == 90, "the mirrored camera: under the floor, pitch mirrored")
local f0, f1 = camA:Forward(), ma:Forward()
check(math.abs(f1.x - f0.x) < 1e-9 and math.abs(f1.y - f0.y) < 1e-9 and math.abs(f1.z + f0.z) < 1e-9, "looking along the mirror image of the view")
views, written, clips, popped = {}, {}, {}, 0
G.cv.mirror:SetInt(1)
P.MirrorStep(camO, camA, 75)
local mv = views[1]
check(mv and mv.target == P.MirrorRT() and P.MirrorRT().w == 1024 and P.MirrorRT().h == 512 and P.MirrorRT().depth == MATERIAL_RT_DEPTH_SEPARATE,
	"rendered into the mirror target (1024 x 512, its own depth buffer)")
check(mv and mv.origin == Vector(0, -300, -64) and mv.fov == 75 and math.abs(mv.aspect - 1920 / 1080) < 1e-9 and mv.vm == false and mv.hud == false,
	"from the mirrored camera, with the view's fov and aspect, no view model / HUD")
check(#clips == 1 and clips[1].on and clips[1].n == Vector(0, 0, 1) and math.abs(clips[1].d - 0.05) < 1e-9 and popped == 1 and not clipOn,
	"clipped at the floor (nothing under it is mirrored), clipping restored")
local mirTo, flags = {}, {}
for _, w in ipairs(written) do
	local ps = w.mat and w.mat.kv and w.mat.kv["$pixshader"] or ""
	if ps:find("copy_ps30") and w.mat.kv["$basetexture"] == P.MirrorRT():GetName() then
		if w.x0 == 0 and w.y0 == 512 and w.x1 == 1024 and w.y1 == 1024 then mirTo[w.target] = true end
	elseif w.x0 == 388 and w.y0 == 0 and w.x1 == 389 then
		flags[w.target] = w.t1
	end
end
check(mirTo[near.rt] and mirTo[P.fb], "copied into the lower half of the atlases on that floor and of the fallback")
local fl = flags[near.rt]
check(fl and fl[3] > 0.5 and math.abs(u16(fl[1], fl[2]) * (32768 / 65535) - 16384) < 0.5, "texel (388, 0): the floor's height, on")
-- the films' lookup (ghmpb_surface_main.h): the reflected ray's point 60 u out, mirrored under the floor, lies on the line from
-- the eye through the pixel - a level pool reads its own pixel of the (upside down) picture
local Ppix = Vector(10, 40, 0)
local V = (camO - Ppix):GetNormalized()
local R = -V + Vector(0, 0, 1) * (2 * V.z)                        -- reflect(-V, up)
local Y = Ppix + Vector(R.x, R.y, -R.z) * 60
local a1, a2 = (Ppix - camO):GetNormalized(), (Y - camO):GetNormalized()
check((a1 - a2):Length() < 1e-9, "the shader's lookup: a level pool reads the mirror picture at its own pixel")
-- nothing wet in view: off again (flags cleared)
for _, p in pairs(S.patches) do p.wetUntil = 0 end
written = {}
P.mpT = nil
P.MirrorStep(camO, camA, 75)
local cleared = 0
for _, w in ipairs(written) do if w.x0 == 388 and w.y0 == 0 and w.t1 and byte(w.t1[3]) == 0 then cleared = cleared + 1 end end
check(cleared >= 2 and P.mirror.z == nil, "no wet blood on a floor in view: no mirror, the flags of the atlases that had it cleared")
for _, p in pairs(S.patches) do p.wetUntil = now0 + 60 end
G.cv.mirror:SetInt(0)
views = {}
P.mpT = nil
P.MirrorStep(camO, camA, 75)
check(#views == 0, "ghmpb_reflect_mirror 0: no mirror render")
G.cv.mirror:SetInt(1)
S.patches.hi = nil

-- ---------------- off: probes 0, lite renderer, errors
G.cv.reflprobes:SetInt(0)
views = {}
for i = 1, 30 do frame = frame + 1 M.now = M.now + 1 / 60 P.Step() end
check(#views == 0 and next(P.list) == nil, "ghmpb_reflect_probes 0: no views, probes given back")
G.cv.reflprobes:SetInt(2)
G.Lite.on = true
for i = 1, 30 do frame = frame + 1 M.now = M.now + 1 / 60 P.Step() end
check(#views == 0, "lite renderer: no probes")
G.Lite.on = false
failView = true
for i = 1, 200 do frame = frame + 1 M.now = M.now + 1 / 60 P.Step() end
check(P.disabled, "a view that keeps failing switches the probes off (the map's cubemap stays)")
check(P.TexFor(S.patches.a) == P.fb, "and everything reads the fallback")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
