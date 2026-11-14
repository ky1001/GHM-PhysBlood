-- GHM PhysBlood (1.26.6): is the shader pack of this version installed?
-- The Steam Workshop can not deliver compiled shaders, so players install them from the shader pack and keep whatever
-- they installed until they run a newer installer. A few seconds into a game the files of this version's pack
-- (sh_shaderver.lua: GHMPB.ShaderPack, written by tools/make_shader_manifest.py for every shader build) are checked:
--   missing    no shader files: the Lite renderer runs
--   incomplete some files missing (the DX11 _50 files only count when the game runs DirectX 11)
--   outdated   files from an older pack under the same prefix: they still work, but this version's shader changes are not
--              there
--   ok
-- Shader sets of earlier versions (other ghmpb prefixes) are listed as well: unused, the installer can move them away.
-- Not ok: a window offers the download - again at every start until the player installs it or turns the reminder off for
-- this pack version (a newer version asks again). ghmpb_shader_check runs the check and shows the window on demand.
local G = GHMPB
G.ShaderCheck = G.ShaderCheck or {}
local SC = G.ShaderCheck
local NOTE_DIR, NOTE_FILE = "ghm_physblood", "ghm_physblood/shader_notice.txt"

local function Size(rel)
	local s = file.Size(rel, "GAME")
	if (not s or s < 0) and file.Exists("garrysmod/" .. rel, "BASE_PATH") then s = file.Size("garrysmod/" .. rel, "BASE_PATH") end
	return (s and s >= 0) and s or nil
end

function SC.Run()
	local pack, pre = G.ShaderPack, G.ShaderPrefix or ""
	local r = { state = "ok", missing = {}, outdated = {}, old = {}, total = 0, present = 0,
		version = pack and pack.version or "?", prefix = pre }
	if not pack or not pack.files then r.state = "unknown" SC.result = r return r end
	local dx11 = G.GPU and G.GPU.isDX11
	local need, have, missingNeeded = 0, 0, 0
	for name, size in SortedPairs(pack.files) do
		r.total = r.total + 1
		local needed = (string.sub(name, -2) == "30") or dx11
		if needed then need = need + 1 end
		local sz = Size("shaders/fxc/" .. pre .. name .. ".vcs")
		if not sz then
			r.missing[#r.missing + 1] = name
			if needed then missingNeeded = missingNeeded + 1 end
		else
			r.present = r.present + 1
			if needed then have = have + 1 end
			if sz ~= size then r.outdated[#r.outdated + 1] = name end
		end
	end
	if have == 0 then r.state = "missing"
	elseif missingNeeded > 0 then r.state = "incomplete"
	elseif #r.outdated > 0 then r.state = "outdated" end
	r.need, r.have = need, have
	-- shader sets of earlier versions (unused by this one)
	local seen = {}
	for _, f in ipairs(file.Find("shaders/fxc/ghmpb*.vcs", "GAME") or {}) do
		local p = string.match(string.lower(f), "^(ghmpb[%w]-_)surface_ps30%.vcs$")
		if p and p ~= string.lower(pre) and not seen[p] then seen[p] = true r.old[#r.old + 1] = p end
	end
	table.sort(r.old)
	SC.result = r
	return r
end

function SC.Summary(r)
	r = r or SC.result or SC.Run()
	if r.state == "ok" then return "installed (" .. r.version .. " pack)"
	elseif r.state == "outdated" then return "outdated - " .. #r.outdated .. " file(s) from an older pack (update to " .. r.version .. ")"
	elseif r.state == "incomplete" then return "incomplete - " .. (r.need - r.have) .. " of " .. r.need .. " missing"
	elseif r.state == "missing" then return "not installed"
	end
	return "unknown"
end

local function Dismissed(r)
	local s = file.Read(NOTE_FILE, "DATA")
	return s ~= nil and string.Trim(s) == (r.version .. ":" .. r.state)
end
local function Dismiss(r)
	if not file.IsDir(NOTE_DIR, "DATA") then file.CreateDir(NOTE_DIR) end
	file.Write(NOTE_FILE, r.version .. ":" .. r.state)
end

function SC.Text(r)
	local pack = G.ShaderPack or {}
	local t
	if r.state == "missing" then
		t = "The GHM PhysBlood shader files are not installed, so the mod runs in its Lite renderer (no flowing liquid, no wet, "
			.. "glossy film). The Steam Workshop can not deliver compiled shaders: install the " .. r.version .. " shader pack for the full look."
	elseif r.state == "incomplete" then
		t = "Some GHM PhysBlood shader files are missing (" .. (r.need - r.have) .. " of " .. r.need .. "). "
			.. "Run the installer of the " .. r.version .. " shader pack again."
	elseif r.state == "outdated" then
		t = "Your GHM PhysBlood shaders come from an older version: " .. #r.outdated .. " file(s) differ from the " .. r.version
			.. " pack (" .. table.concat(r.outdated, ", ", 1, math.min(#r.outdated, 6)) .. (#r.outdated > 6 and ", ..." or "") .. "). "
			.. "They still work, but this version's shader changes are missing" .. ((pack.notes and pack.notes ~= "") and (": " .. pack.notes) or "") .. ". "
			.. "Install the " .. r.version .. " shader pack - its installer updates them in place."
	else
		t = "The GHM PhysBlood shaders of this version (" .. r.version .. ") are installed."
	end
	if #r.old > 0 then
		t = t .. "\n\nShader sets of earlier versions are installed too (" .. table.concat(r.old, ", ") .. "): this version does not "
			.. "use them. The installer can move them out of the way."
	end
	return t .. "\n\nDownload (GitHub releases): " .. (pack.url or "?") .. "\nExtract the whole zip, then double-click Install_GHM_PhysBlood_Shaders.bat "
		.. "(close Garry's Mod first) or copy its garrysmod folder over your GarrysMod folder by hand. The installer is a plain batch "
		.. "file you can read in Notepad: it finds Garry's Mod, asks before it copies anything and deletes nothing."
		.. (pack.source and ("\nSource code of the mod, the shaders and the native module: " .. pack.source) or "")
end

function SC.Popup(r)
	r = r or SC.Run()
	local pack = G.ShaderPack or {}
	if IsValid(SC.frame) then SC.frame:Remove() end
	local fr = vgui.Create("DFrame")
	SC.frame = fr
	fr:SetTitle(r.state == "ok" and "GHM PhysBlood - shaders" or (r.state == "outdated" and "GHM PhysBlood - shader update" or "GHM PhysBlood - shaders not installed"))
	if file.Exists("materials/ghm_physblood/icon64.png", "GAME") then fr:SetIcon("ghm_physblood/icon64.png") end
	fr:SetSize(math.min(600, ScrW() - 40), 300)
	fr:Center()
	fr:MakePopup()
	local txt = vgui.Create("RichText", fr)
	txt:Dock(FILL)
	txt:DockMargin(4, 4, 4, 4)
	txt:InsertColorChange(235, 235, 235, 255)
	txt:AppendText(SC.Text(r))
	function txt:PerformLayout() if self.SetFontInternal then self:SetFontInternal("DermaDefault") end end
	local row = vgui.Create("DPanel", fr)
	row:Dock(BOTTOM)
	row:SetTall(28)
	row:DockMargin(0, 4, 0, 0)
	row:SetPaintBackground(false)
	local function Btn(text, fn, right)
		local b = vgui.Create("DButton", row)
		b:SetText(text)
		b:SizeToContentsX(20)
		b:Dock(right and RIGHT or LEFT)
		b:DockMargin(right and 6 or 0, 0, right and 0 or 6, 0)
		b.DoClick = fn
		return b
	end
	if r.state ~= "ok" then
		Btn("Download shader pack", function() gui.OpenURL(pack.url) end)
		Btn("Copy link", function()
			SetClipboardText(pack.url or "")
			chat.AddText(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Shader pack link copied.")
		end)
	end
	if pack.page then Btn("Workshop page", function() gui.OpenURL(pack.page) end) end
	if pack.source then Btn("Source code", function() gui.OpenURL(pack.source) end) end
	if r.state ~= "ok" then
		Btn("Don't remind me for " .. r.version, function() Dismiss(r) fr:Close() end, true)
		Btn("Later", function() fr:Close() end, true)
	else
		Btn("Close", function() fr:Close() end, true)
	end
end

function SC.Report(r)
	r = r or SC.Run()
	MsgC(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "shader files (" .. r.prefix .. ", pack " .. r.version .. "): " .. SC.Summary(r) .. "\n")
	if #r.outdated > 0 then MsgN("  older than this version's pack: " .. table.concat(r.outdated, ", ")) end
	if #r.missing > 0 and r.state ~= "missing" then MsgN("  missing: " .. table.concat(r.missing, ", ")) end
	if #r.old > 0 then MsgN("  shader sets of earlier versions (unused): " .. table.concat(r.old, ", ")) end
end

concommand.Add("ghmpb_shader_check", function()
	local r = SC.Run()
	SC.Report(r)
	SC.Popup(r)
end, nil, "GHM PhysBlood: check the installed shader files against this version's shader pack")

hook.Add("InitPostEntity", "ghmpb_shadercheck", function()
	timer.Simple(8, function()
		local ok, r = pcall(SC.Run)
		if not ok or not r then return end
		SC.Report(r)
		if r.state == "ok" or r.state == "unknown" then return end
		if not G.cv.enable:GetBool() then return end
		-- a player who picked the Lite renderer on purpose is not asked to install the shaders
		if r.state == "missing" and G.cv.rendermode and G.cv.rendermode:GetInt() == 2 then return end
		if Dismissed(r) then return end
		chat.AddText(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Shader files: " .. SC.Summary(r) .. " - ghmpb_shader_check for details.")
		SC.Popup(r)
	end)
end)
