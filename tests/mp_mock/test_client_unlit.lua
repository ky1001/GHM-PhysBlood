-- 1.23.2: a map compiled without lighting (gm_falleritus8: both lighting lumps of the BSP empty) renders fullbright,
-- but the light queries may read black there: the blood was lit black. The BSP header tells such a map apart, and on
-- it a black probe is taken as full white light; a lit map keeps its dark corners dark (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 0
function FrameNumber() return frame end
_G.render = { ComputeLighting = function() return Vector(0, 0, 0) end }   -- what the engine answers on such a map
_G.util.GetSunInfo = function() return nil end
function LocalPlayer() return NULL end
function Matrix() return { SetUnpacked = function() end } end
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }

-- BSP v19 headers: lump k is at 8 + k * 16 (offset, length, version, fourCC)
local function le(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function Header(lens)
	local t = { "VBSP", le(19) }
	for k = 0, 63 do t[#t + 1] = le(1036) .. le(lens[k] or 100) .. le(0) .. le(0) end
	return table.concat(t)
end
local maps = {
	unlit = Header({ [8] = 0, [53] = 0 }),
	lit = Header({ [8] = 50000, [53] = 0 }),
	hdronly = Header({ [8] = 0, [53] = 80000 }),
}
local opened = 0
_G.file.Open = function(path)
	local name = path:match("^maps/(.+)%.bsp$")
	local data = name and maps[name]
	if not data then return nil end
	opened = opened + 1
	local f = { p = 0 }
	function f:Read(n) local s = data:sub(self.p + 1, self.p + n) self.p = self.p + n return s end
	function f:Seek(n) self.p = n end
	function f:ReadLong()
		local b1, b2, b3, b4 = data:byte(self.p + 1, self.p + 4)
		self.p = self.p + 4
		local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
		return v >= 2147483648 and v - 4294967296 or v
	end
	function f:Close() end
	return f
end
local map = "unlit"
_G.game.GetMap = function() return map end

G.GPU = {}
M.Load({ "cl_gpu.lua", "cl_lighting.lua" })
local L = G.Light

check(L.MapUnlit() == true, "both lighting lumps empty: the map is unlit")
L.MapUnlit() L.MapUnlit()
check(opened == 1, "read once per map (" .. opened .. " opens)")
local info = L.Get({}, Vector(0, 0, 0), 0.5)
check(info.r[1] > 0.9 and info.g[1] > 0.9 and info.b[1] > 0.9, "a black probe there reads as full white light (" .. info.r[1] .. ")")

-- a lit map: its black corners stay black
M.Engine("InitPostEntity")
map = "lit"
frame = frame + 1
M.now = M.now + 5
check(L.MapUnlit() == false, "a map with lighting is not")
local info2 = L.Get({}, Vector(9000, 0, 0), 0.5)
check(info2.r[1] < 0.01, "and a dark spot on it stays dark")
M.Engine("InitPostEntity")
map = "hdronly"
check(L.MapUnlit() == false, "HDR lighting only: lit too")
M.Engine("InitPostEntity")
map = "missing"
check(L.MapUnlit() == false, "a map file it cannot open: treated as lit")

-- the lite renderer's light follows
M.Engine("InitPostEntity")
map = "unlit"
check(L.MapUnlit() == true, "back on the unlit map")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
