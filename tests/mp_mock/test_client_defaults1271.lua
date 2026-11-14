-- (1.26.8) GHM's drying settings are the defaults (clotting 535 s, drying 1816 s, soaking 0.28, fresh blood soaks in
-- slowly 1.46); players still at the old ones are moved over once; the conditions presets keep their proportions.
-- And the Ultra preset notice at the start of a map ("FPS might suffer, wanna change that? click here to open menu").
-- (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local function near(a, b) return a and b and math.abs(a - b) < 1e-6 end
local function Fresh(saved)
	M.cvars = {}
	for k, v in pairs(saved or {}) do CreateConVar(k, tostring(v)) end
	GHMPB = nil
	M.Load({ "sh_shaderver.lua", "sh_config.lua" })
	return GHMPB
end
local function F(n) return GetConVar(n):GetFloat() end

-- drying defaults
local G = Fresh()
check(near(F("ghmpb_coag_time"), 535) and near(F("ghmpb_drytime"), 1816) and near(F("ghmpb_soak_speed"), 0.28)
	and near(F("ghmpb_soak_delay"), 1.46) and near(F("ghmpb_dry_crust"), 0.6), "a new player: clotting 535 s, drying 1816 s, soaking 0.28, slow soaking 1.46, skin 0.6")
check(G.DryEnvNow() and G.DryEnvNow().id == "indoor", "at the new defaults the conditions read Indoors")
local cvC, cvD = GetConVar("ghmpb_coag_time"), GetConVar("ghmpb_drytime")
check(cvC.mx >= 535 and cvD.mx >= 1816, "the defaults are inside the settings' ranges")
local inRange = true
for _, e in ipairs(G.DRY_ENVS) do
	for k, v in pairs(e.cv) do
		local c = GetConVar(k)
		if not c or (c.mn and v < c.mn) or (c.mx and v > c.mx) then inRange = false print("     out of range: " .. e.id .. " " .. k .. " " .. v) end
	end
end
check(inRange, "every conditions preset is inside the settings' ranges")
local E = {}
for _, e in ipairs(G.DRY_ENVS) do E[e.id] = e.cv end
check(E.hot.ghmpb_drytime < E.windy.ghmpb_drytime and E.windy.ghmpb_drytime < E.indoor.ghmpb_drytime and E.indoor.ghmpb_drytime < E.cold.ghmpb_drytime,
	"drying: hot < windy < indoors < cold")
check(E.hot.ghmpb_coag_time < E.indoor.ghmpb_coag_time and E.cold.ghmpb_coag_time > E.indoor.ghmpb_coag_time, "clotting: sooner when hot, later when cold")
check(math.abs(E.hot.ghmpb_drytime / E.indoor.ghmpb_drytime - 110 / 240) < 0.01 and math.abs(E.cold.ghmpb_drytime / E.indoor.ghmpb_drytime - 720 / 240) < 0.01,
	"the presets keep their 1.26.1 proportions to Indoors")
G.ApplyDryEnv("cold")
check(G.DryEnvNow().id == "cold", "Cold and damp applies")
G.ApplyDryEnv("indoor")
check(G.DryEnvNow().id == "indoor" and near(F("ghmpb_soak_delay"), 1.46), "Indoors gives the defaults back (with the slow soaking)")

-- a player from before, still at the old defaults
Fresh({ ghmpb_config_version = 1270, ghmpb_coag_time = 180, ghmpb_drytime = 240, ghmpb_soak_speed = 1, ghmpb_soak_delay = 1 })
check(near(F("ghmpb_coag_time"), 535) and near(F("ghmpb_drytime"), 1816) and near(F("ghmpb_soak_speed"), 0.28) and near(F("ghmpb_soak_delay"), 1.46),
	"an updating player at the old defaults: moved to the new ones")
check(GetConVar("ghmpb_config_version"):GetInt() >= 1271, "settings step 1271 done")
-- a player who had set up their own drying
Fresh({ ghmpb_config_version = 1270, ghmpb_coag_time = 300, ghmpb_drytime = 240, ghmpb_soak_speed = 1, ghmpb_soak_delay = 1 })
check(near(F("ghmpb_coag_time"), 300) and near(F("ghmpb_drytime"), 240) and near(F("ghmpb_soak_speed"), 1), "a player with their own clotting time: all kept")
Fresh({ ghmpb_config_version = 1270, ghmpb_coag_time = 320, ghmpb_drytime = 720, ghmpb_soak_speed = 0.8, ghmpb_soak_delay = 1 })
check(near(F("ghmpb_drytime"), 720), "a player on the old Cold and damp: kept")
-- once only
Fresh({ ghmpb_config_version = 1271, ghmpb_coag_time = 180, ghmpb_drytime = 240, ghmpb_soak_speed = 1, ghmpb_soak_delay = 1 })
check(near(F("ghmpb_drytime"), 240), "set back to the old figures after the update: they stay")

-- the Ultra preset notice
G = Fresh()
local panels = {}
local function Panel(class)
	local p = { valid = true, class = class, calls = {} }
	panels[#panels + 1] = p
	function p:SetText(t) self.text = t end
	function p:SetTitle(t) self.title = t end
	function p:AppendText(t) self.body = (self.body or "") .. t end
	function p:Remove() self.valid = false end
	function p:Close() self.valid = false end
	function p:IsValid() return self.valid end
	return setmetatable(p, { __index = function(_, k) if k:match("^%u") then return function() end end end })
end
_G.vgui = { Create = function(class) return Panel(class) end }
_G.list = _G.list or { Set = function() end, Get = function() return {} end }
_G.spawnmenu = _G.spawnmenu or { AddToolMenuOption = function() end }
_G.ScrW, _G.ScrH = function() return 1920 end, function() return 1080 end
_G.gui = { IsGameUIVisible = function() return M.gameUI == true end, OpenURL = function() end }
local chats = {}
_G.chat = { AddText = function(...) chats[#chats + 1] = table.concat((function(...) local t = {} for _, v in ipairs({ ... }) do if type(v) == "string" then t[#t + 1] = v end end return t end)(...)) end }
G.Menu = nil
local ok, err = pcall(M.Load, { "cl_menu.lua" })
check(ok, "cl_menu.lua loads" .. (ok and "" or (": " .. tostring(err))))
local Mn = G.Menu
local opened = 0
Mn.Open = function() opened = opened + 1 end
local function Frame()
	for i = #panels, 1, -1 do local p = panels[i] if p.class == "DFrame" and p.valid then return p end end
end
local function Button(fr, text)
	for _, p in ipairs(panels) do if p.class == "DButton" and p.text == text then return p end end
end
local function MapStart()
	panels, chats = {}, {}
	hook.Run("InitPostEntity")
end

check(Mn.UltraNoticeDue(), "on Ultra, not answered yet: due")
RunConsoleCommand("ghmpb_quality", "3")
check(not Mn.UltraNoticeDue(), "on High: not due")
RunConsoleCommand("ghmpb_quality", "4")
RunConsoleCommand("ghmpb_enable", "0")
check(not Mn.UltraNoticeDue(), "the mod switched off: not due")
RunConsoleCommand("ghmpb_enable", "1")

MapStart()
M.Advance(10)
check(Frame() == nil, "nothing in the first seconds of the map")
M.Advance(3)
local fr = Frame()
local body = ""
for _, p in ipairs(panels) do if p.class == "RichText" and p.body then body = body .. p.body end end
check(fr and fr.title and fr.title:find("Ultra") and body:find("FPS might suffer") and body:find("Want to change that"),
	"12 s into the map: the window - 'FPS might suffer ... Want to change that?'")
check(#chats == 1 and chats[1]:find("ghmpb_menu"), "and a line in the chat")
local bOpen, bKeep, bLater = Button(fr, "Open settings"), Button(fr, "Keep Ultra"), Button(fr, "Later")
check(bOpen and bKeep and bLater, "buttons: Open settings, Keep Ultra, Later")
bLater.DoClick()
check(not fr.valid and Mn.UltraNoticeDue(), "Later: the window closes and asks again next time")
MapStart()
M.Advance(13)
fr = Frame()
check(fr ~= nil, "the next map: asked again")
Button(fr, "Open settings").DoClick()
check(not fr.valid and opened == 1 and Mn.lastTab == 1, "Open settings: the settings window opens on the Quality tab")
check(not Mn.UltraNoticeDue(), "and the question is answered for this version")
MapStart()
M.Advance(20)
check(Frame() == nil, "answered: no window at the next map")
RunConsoleCommand("ghmpb_ultra_notice", "")
-- one window at a time
G.ShaderCheck = { frame = Panel("DFrame") }
local shaderFrame = G.ShaderCheck.frame
panels = { shaderFrame }
chats = {}
hook.Run("InitPostEntity")
M.Advance(13)
check(Frame() == shaderFrame, "the shader files window is open: it waits")
shaderFrame:Close()
M.Advance(4)
fr = Frame()
check(fr and fr ~= shaderFrame and fr.title:find("Ultra"), "and comes up once that window is closed")
Button(fr, "Keep Ultra").DoClick()
check(not Mn.UltraNoticeDue(), "Keep Ultra: answered")
G.ShaderCheck = nil
-- a player on High never sees it
RunConsoleCommand("ghmpb_ultra_notice", "")
RunConsoleCommand("ghmpb_quality", "2")
MapStart()
M.Advance(30)
check(Frame() == nil, "Medium: no window")
-- the game menu is open: it waits
RunConsoleCommand("ghmpb_quality", "4")
M.gameUI = true
MapStart()
M.Advance(14)
check(Frame() == nil, "the game menu is open: it waits")
M.gameUI = false
M.Advance(4)
check(Frame() ~= nil, "and comes up after")
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
