-- (1.26.6) shader pack check: ok / outdated / incomplete / missing, older sets, the reminder
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua" })
local G = GHMPB
local fs, data = {}, {}
_G.file = {
	Size = function(p, path) return fs[p] or -1 end,
	Exists = function(p, path) if path == "DATA" then return data[p] ~= nil end return fs[p] ~= nil end,
	Find = function(pat, path)
		local out = {}
		for p in pairs(fs) do local n = string.match(p, "^shaders/fxc/(ghmpb.*%.vcs)$") if n then out[#out + 1] = n end end
		return out, {}
	end,
	Read = function(p) return data[p] end, Write = function(p, s) data[p] = s end,
	IsDir = function() return true end, CreateDir = function() end,
}
_G.SortedPairs = _G.SortedPairs or function(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) local i = 0 return function() i = i + 1 if k[i] then return k[i], t[k[i]] end end end
string.Trim = string.Trim or function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.concommand = { Add = function() end }
local hooks = {}
_G.hook = { Add = function(n, id, f) hooks[n .. id] = f end }
G.GPU = { isDX11 = false }
M.Load({ "cl_shadercheck.lua" })
local SC = G.ShaderCheck
local pre = G.ShaderPrefix
local function install(sizes) fs = {} for n, s in pairs(sizes) do fs["shaders/fxc/" .. pre .. n .. ".vcs"] = s end end

install(G.ShaderPack.files)
local r = SC.Run()
check(r.state == "ok" and r.total == 56 and #r.outdated == 0, "the 1.26.6 pack: ok (" .. SC.Summary(r) .. ")")

local old = {} for k, v in pairs(G.ShaderPack.files) do old[k] = v end
old.pforce_ps30 = 4124
install(old)
r = SC.Run()
check(r.state == "outdated" and #r.outdated == 1 and r.outdated[1] == "pforce_ps30", "the 1.26.3 pack: outdated, pforce_ps30 (" .. SC.Summary(r) .. ")")
check(SC.Text(r):find("older version", 1, true) ~= nil and SC.Text(r):find("floor-pool", 1, true) ~= nil, "the text says what is new")

fs["shaders/fxc/ghmpbcp1_surface_ps30.vcs"] = 27081
fs["shaders/fxc/ghmpbcp1_pforce_ps30.vcs"] = 7371
r = SC.Run()
check(#r.old == 1 and r.old[1] == "ghmpbcp1_", "earlier sets are listed (" .. table.concat(r.old, ",") .. ")")

install({})
r = SC.Run()
check(r.state == "missing", "nothing installed: missing")

local part = {} for k, v in pairs(G.ShaderPack.files) do part[k] = v end
part.surface_ps30 = nil
install(part)
check(SC.Run().state == "incomplete", "a ps30 file missing: incomplete")
local no50 = {} for k, v in pairs(G.ShaderPack.files) do if k:sub(-2) == "30" then no50[k] = v end end
install(no50)
check(SC.Run().state == "ok", "DX11 files missing on DX9: ok")
G.GPU.isDX11 = true
check(SC.Run().state == "incomplete", "DX11 files missing on DX11: incomplete")
G.GPU.isDX11 = false

-- the start-up reminder, and "don't remind me for this version"
install(old)
local popups = 0
SC.Popup = function() popups = popups + 1 end
_G.chat = { AddText = function() end }
_G.timer = { Simple = function(_, f) f() end }
hooks["InitPostEntityghmpb_shadercheck"]()
check(popups == 1, "outdated: the window opens at start-up")
data["ghm_physblood/shader_notice.txt"] = G.ShaderPack.version .. ":outdated"
hooks["InitPostEntityghmpb_shadercheck"]()
check(popups == 1, "dismissed for this version: no window")
data["ghm_physblood/shader_notice.txt"] = "1.26.5:outdated"
hooks["InitPostEntityghmpb_shadercheck"]()
check(popups == 2, "dismissed for an older version: asks again")
install({})
GetConVar("ghmpb_render_mode"):SetString("2")
hooks["InitPostEntityghmpb_shadercheck"]()
check(popups == 2, "Lite picked on purpose and no shaders: not asked")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
