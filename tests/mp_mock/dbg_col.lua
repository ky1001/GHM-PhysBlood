local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
M.Load({ "sh_shaderver.lua", "sh_config.lua", "cl_util.lua" })
local G, U = GHMPB, GHMPB.U
G.GPU = { FreshAbs = function() return 1.85 * (math.max(G.cv.colFresh:GetFloat(), 0.3) ^ -1.6) end }
print(U.BloodColour(0, 0.75, 120))
GetConVar("ghmpb_color_custom"):SetString("1")
GetConVar("ghmpb_color_blood"):SetString("230 70 30")
print(U.CustomOn(), U.CustomColours())
print(U.BloodColour(0, 0.75, 120))
