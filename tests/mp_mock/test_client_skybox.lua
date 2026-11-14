-- 1.23.3: no blood on gm_falleritus8_2008 - simulated (16,000 impacts painted, patches live) but never drawn. The map
-- has no 3D skybox (no sky_camera); there the engine calls PostDrawOpaqueRenderables for the main view with its
-- skybox flag set (GMod wiki), and the draw hook returned on that flag. Now only the depth pass and the 3D skybox's
-- view are left out. And if another addon's opaque hook returns a value (the event ends there), the layers are drawn
-- in the translucent pass instead (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
local frame = 1
function FrameNumber() return frame end
function EyePos() return Vector(0, 0, 14800) end
function LocalPlayer() return NULL end
local screenRT = nil
_G.render = { GetRenderTarget = function() return screenRT end, UpdateScreenEffectTexture = function() end }

-- what gets drawn
local world, bodies, drops, vat = 0, 0, 0, 0
G.Surfaces = { HasStatic = function() return false end, DrawStatic = function() end, DrawOverlays = function() world = world + 1 end }
G.Entities = { HasStatic = function() return false end, DrawOverlays = function() bodies = bodies + 1 end, RawDrawOverlays = function() bodies = bodies + 1 end,
	DrawStatic = function() end, RawDrawStatic = function() end }
G.Particles = { Count = function() return 1 end, hang = {}, Draw = function() drops = drops + 1 end }
G.Prof = { Count = function() end, Lap = function() return 0 end, Instrument = function() end }
G.Native = { Load = function() end }
G.GPU = {}
M.Load({ "cl_util.lua", "cl_render.lua" })
G.VAT = { inst = { 1 }, DrawPass = function() vat = vat + 1 end }

local function Frame(opaqueArgs, translucentArgs)
	frame = frame + 1
	world, bodies, drops, vat = 0, 0, 0, 0
	if opaqueArgs then M.Engine("PostDrawOpaqueRenderables", unpack(opaqueArgs)) end
	if translucentArgs then M.Engine("PostDrawTranslucentRenderables", unpack(translucentArgs)) end
end

check(G.ScenePass(false, false, false) and G.ScenePass(false, true, false), "scene passes: plain, and the skybox flag alone")
check(not G.ScenePass(true, false, false) and not G.ScenePass(false, true, true), "not: the depth pass, the 3D skybox's view")

-- a map with a 3D skybox: the skybox view first (flag + 3D), then the main view
Frame({ false, true, true }, { false, true, true })
check(world == 0 and drops == 0, "3D skybox's view: nothing drawn in it")
Frame({ false, false, false }, { false, false, false })
check(world == 1 and bodies == 1 and drops == 1, "main view: world, bodies, drops drawn once")

-- gm_falleritus8_2008: a 2D skybox only - the main view comes with the skybox flag set
Frame({ false, true, false }, { false, false, false })
check(world == 1 and bodies == 1, "2D skybox map: the blood is drawn (it was not before 1.23.3)")
check((G.Diag.c["frames: skybox flag on the main view (map with a 2D skybox only)"] or 0) >= 1, "counted for ghmpb_diag")
check((G.Diag.c["frames: blood drawn late (the opaque pass did not reach it: another addon's hook returned a value)"] or 0) == 0,
	"and not drawn a second time in the translucent pass")

-- the depth pass draws nothing
Frame({ true, false, false }, nil)
check(world == 0, "depth pass: nothing")

-- another addon's opaque hook returns a value: the blood's hook never runs, the translucent pass draws it
hook.Add("PostDrawOpaqueRenderables", "aaa_other_addon", function() return true end)
M.hookOrder = { PostDrawOpaqueRenderables = { "aaa_other_addon" } }
Frame({ false, false, false }, { false, false, false })
check(world == 1 and bodies == 1, "opaque pass cut short by another addon: the layers are drawn late, once")
check(vat == 1, "and the fluid bursts with them")
check(drops == 1, "drops as always")
Frame(nil, { false, false, false })
check(world == 1, "next frame: again")
hook.Remove("PostDrawOpaqueRenderables", "aaa_other_addon")
Frame({ false, false, false }, { false, false, false })
check(world == 1, "that addon gone: drawn in the opaque pass only")

-- water reflection / mirrors / cameras are left out as before
screenRT = { GetName = function() return "_rt_WaterReflection" end, Width = function() return 512 end, Height = function() return 512 end }
Frame({ false, true, false }, { false, true, false })
check(world == 0 and drops == 0, "a reflection view with the skybox flag: nothing")
screenRT = nil

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
