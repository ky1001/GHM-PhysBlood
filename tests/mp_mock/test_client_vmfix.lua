-- ARC9 / ArcCW viewmodel tremor fix: the reflection probes render in RenderScene (not PostRender), and while a probe
-- view renders, CalcViewModelView / CalcView keep their values (no weapon base steps its viewmodel springs with it)
-- (mocks: the same as test_client_probes.lua)
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
local H = hook.GetTable()
check(H.RenderScene and H.RenderScene.ghmpb_probes, "the probes step in RenderScene (inside the frame, before the main view)")
check(not (H.PostRender and H.PostRender.ghmpb_probes), "no probe views at the end of the frame (PostRender)")
local vm = { IsValid = function() return true end, GetPos = function() return Vector(1, 2, 3) end, GetAngles = function() return Angle(4, 5, 6) end }
_G.IsValid = function(e) return e ~= nil and e ~= NULL and (type(e) ~= "table" or not e.IsValid or e:IsValid()) end
local a, b = H.CalcViewModelView.ghmpb_probes(nil, vm, Vector(), Angle(), Vector(7, 7, 7), Angle(0, 90, 0))
check(a == nil and b == nil, "main view: the viewmodel is left to the weapon")
check(H.CalcView.ghmpb_probes(nil, Vector(), Angle(), 90) == nil, "main view: the camera is left to the weapon / gamemode")
-- a probe face: the view render asks for the viewmodel's position - it keeps its own, the weapon is not asked
local asked, got = 0, nil
local baseRV = render.RenderView
render.RenderView = function(v)
	local p, q = hook.Call("CalcViewModelView", nil, nil, vm, Vector(), Angle(), v.origin, v.angles)
	if p then got = { p, q } else asked = asked + 1 end
	local cv = hook.Call("CalcView", nil, nil, v.origin, v.angles, 90)
	got.cv = cv
	return baseRV(v)
end
local pr = { pos = Vector(0, 0, 64), radius = 300, rt = GetRenderTargetEx("vmfix_atlas", P.ATLAS, P.ATLAS), faceT = {}, n = Vector(0, 0, 1) }
P.RenderFace(pr, 5)
check(asked == 0 and got and got[1].x == 1 and got[2].p == 4, "during a probe face the viewmodel keeps its position and angles (the weapon's GetViewModelPosition is not called)")
check(got and type(got.cv) == "table" and got.cv.angles == P.FACES[5], "during a probe face CalcView answers with the probe's own view")
check(P.rendering == false, "after the face: back to normal")
render.RenderView = baseRV
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
