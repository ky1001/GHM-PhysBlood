-- Settled world blood (aftermath) drawing: a layer whose state did not change is drawn without setting its
-- constants again; anything that changes them (light, fade, drying, view, settings, flashlight, a re-bake) sets them
-- (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 0
function FrameNumber() return frame end
local eye, fwd = Vector(0, 0, 64), Vector(1, 0, 0)
function EyePos() return eye end
function EyeAngles() return { Forward = function() return fwd end } end
function ScrW() return 1600 end
function ScrH() return 900 end
local flashOn = false
local ply = { FlashlightIsOn = function() return flashOn end, EyePos = function() return eye end,
	EyeAngles = function() return { Forward = function() return fwd end } end, GetFOV = function() return 90 end }
function LocalPlayer() return ply end
local oldIsValid = IsValid
function IsValid(e) if e == ply then return true end return oldIsValid(e) end
local engineCalls, draws = 0, 0
_G.render = { ComputeLighting = function() return Vector(0.2, 0.2, 0.2) end, GetViewSetup = function() return { fov = 90 } end,
	SetMaterial = function() end }
_G.util.GetSunInfo = function() return nil end
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
function Matrix() return { SetUnpacked = function() end } end
local function Mat()
	local m = {}
	function m:SetFloat() engineCalls = engineCalls + 1 end
	function m:SetMatrix() engineCalls = engineCalls + 1 end
	function m:SetTexture() end
	return m
end
G.GPU = {}
G.Prof = { Count = function(n, v) G.Prof.last = G.Prof.last or {} G.Prof.last[n] = v end, Lap = function() return 0 end }
G.Budget = { PatchRes = function() return 256 end, AftRes = function() return 256 end }
M.Load({ "cl_gpu.lua", "cl_lighting.lua" })
local GPU = G.GPU
GPU.Mat = function() return Mat() end
GPU.ImpactTable = function() return { GetName = function() return "x" end } end
GPU.MatTable = function() return { GetName = function() return "mattable" end } end
M.Load({ "cl_surfaces.lua" })
local S = G.Surfaces
G.ViewSize = function() return 1600, 900 end

-- 30 settled layers on a floor in front of the camera, 10 behind it
local function Layer(i, x, y)
	local a = { key = "k" .. i, plane = "p", i = i, j = 0, N = Vector(0, 0, 1), center = Vector(x, y, 0), oxy = 0.6, btype = 0,
		albedo = Vector(0.3, 0.3, 0.3), surf = G.Surface.concrete, surfName = "concrete", bakedAt = M.now,
		aft = { res = 256, rt = { GetName = function() return "rt" .. i end } } }
	a.meshes = { [0.035] = { Draw = function() draws = draws + 1 end } }
	S.after[a.key] = a
	return a
end
local layers = {}
for i = 1, 30 do layers[i] = Layer(i, 200 + (i % 6) * 40, (math.floor(i / 6) - 2) * 40) end
for i = 31, 40 do layers[i] = Layer(i, -400 - i * 10, 0) end

local function Frame(dt)
	M.now = M.now + (dt or 0.016)
	frame = frame + 1
	engineCalls, draws = 0, 0
	S.DrawStatic()
	return engineCalls, draws, G.Prof.last["world old constants set"]
end
local c, d, u = Frame()
check(d == 30, "30 layers in view drawn, the 10 behind the camera not (" .. d .. ")")
check(u == 30 and c > 100, "first frame: every layer's constants set (" .. u .. " layers, " .. c .. " engine calls)")
c, d, u = Frame()
check(d == 30 and u == 0 and c == 0, "next frame, nothing changed: drawn without a single constant call (" .. c .. ")")
c, d, u = Frame(0.6)
check(u == G.Light.BUDGET, "light probes renewed after 0.5 s: as many layers set again as probes fit the budget (" .. u .. ")")
c, d, u = Frame()
check(u == G.Light.BUDGET, "the next ones a frame later, within the budget again (" .. u .. ")")
c, d, u = Frame()
check(u == 30 - 2 * G.Light.BUDGET, "the last ones the frame after (" .. u .. ")")
c, d, u = Frame()
check(u == 0, "and then quiet again (" .. u .. ")")
-- drying moves on: the layer word changes in 1/64 steps of the drying time
local dry = G.cv.drytime:GetFloat()
c, d, u = Frame(dry / 64 + 0.01)
check(u == 30, "drying moved a step: constants set (" .. u .. ")")
Frame()
-- a setting changed
RunConsoleCommand("ghmpb_reflections", "0.5")
c, d, u = Frame()
check(u == 30, "a setting changed: every layer set again (" .. u .. ")")
c, d, u = Frame()
check(u == 0, "quiet again (" .. u .. ")")
-- flashlight on: it moves with the player, so every frame
flashOn = true
local _, _, u1 = Frame()
local _, _, u2 = Frame()
check(u1 == 30 and u2 == 30, "flashlight on: set every frame (" .. u1 .. ", " .. u2 .. ")")
flashOn = false
Frame()
c, d, u = Frame()
check(u == 0, "flashlight off again: quiet (" .. u .. ")")
-- a re-bake of one layer (fresh blood settled onto it) sets that one again
layers[3].dVer = nil
layers[3].oxy = 0.9
c, d, u = Frame()
check(u == 1, "a re-baked layer is set again on its own (" .. u .. ")")
-- an element state on every layer (the elements give every patch one, mostly all zero): still quiet
G.Elem = { Word = function(el) return ((el.glow or 0) > 0 and 16384 or 0) + ((el.frost or 0) > 0 and 15 or 0) end }
for _, a in ipairs(layers) do a.el = { glow = 0, frost = 0, heat = 0, fizz = 0 } end
Frame()
c, d, u = Frame()
check(u == 0, "an all-zero element state does not make a layer animated (" .. u .. ")")
layers[6].el.frost = 1
c, d, u = Frame()
local _, _, u3 = Frame()
check(u == 1 and u3 == 0, "frozen blood is set once and then still (" .. u .. ", " .. u3 .. ")")
-- an element on a layer keeps it animated
layers[5].el = { glow = 0.5, glowT = 1 }
local _, _, e1 = Frame()
local _, _, e2 = Frame()
check(e1 == 1 and e2 == 1, "a layer under an element is set every frame (" .. e1 .. ", " .. e2 .. ")")
-- turning around: the layers behind come into view, the others leave
fwd = Vector(-1, 0, 0)
c, d, u = Frame()
check(d == 10, "turned round: the 10 layers behind are drawn now (" .. d .. ")")
-- fading out (ghmpb_aftermath_fade minutes + 30 s)
RunConsoleCommand("ghmpb_aftermath_forever", "0")
fwd = Vector(1, 0, 0)
M.now = M.now + G.cv.aftfade:GetFloat() * 60 + 15
c, d, u = Frame()
check(d == 30 and u == 30, "half faded: still drawn, set (" .. d .. ", " .. u .. ")")

-- the water's refraction view (another view size): only layers reaching into water are drawn there, and drawing
-- them there does not make every other layer set its constants again in the main view
RunConsoleCommand("ghmpb_keep_forever", "1")
layers[7].water = { 0, 0, 0, -10 }
layers[8].water = { 0, 0, 0, -10 }
Frame() Frame()
G.refractionView = true
G.ViewSize = function() return 512, 512 end
c, d, u = Frame()
check(d == 2 and u == 2, "refraction view: only the 2 layers in water drawn and set (" .. d .. ", " .. u .. ")")
G.refractionView = nil
G.ViewSize = function() return 1600, 900 end
c, d, u = Frame()
check(d == 30 and u <= 3, "main view after it: the others keep their constants (" .. u .. " set: the 2 in water + the animated one)")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
