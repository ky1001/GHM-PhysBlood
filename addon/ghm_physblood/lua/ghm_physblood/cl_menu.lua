local G = GHMPB
G.Menu = G.Menu or {}
local M = G.Menu

local ICON = "ghm_physblood/icon64.png"

M.PRESETS = {
	{ name = "Low", tip = "Weak GPUs: 256 / 128 cells, 20 Hz, small budgets (about 120 MB of video memory)",
	  cv = { ghmpb_quality = 1, ghmpb_smooth = 1, ghmpb_sim_hz = 20, ghmpb_max_entities = 6, ghmpb_max_patches = 20,
	         ghmpb_max_particles = 700, ghmpb_aftermath_res = 128, ghmpb_aftermath_max = 200 } },
	{ name = "Medium", tip = "384 / 256 cells, 30 Hz (about 600 MB of video memory)",
	  cv = { ghmpb_quality = 2, ghmpb_smooth = 2, ghmpb_sim_hz = 30, ghmpb_max_entities = 12, ghmpb_max_patches = 40,
	         ghmpb_max_particles = 1400, ghmpb_aftermath_res = 256, ghmpb_aftermath_max = 400 } },
	{ name = "High", tip = "512 / 320 cells, 30 Hz (about 1 GB of video memory)",
	  cv = { ghmpb_quality = 3, ghmpb_smooth = 2, ghmpb_sim_hz = 30, ghmpb_max_entities = 10, ghmpb_max_patches = 48,
	         ghmpb_max_particles = 2500, ghmpb_aftermath_res = 256, ghmpb_aftermath_max = 600 } },
	{ name = "Ultra", tip = "Default: 640 / 512 cells, 45 Hz (about 1.4 GB of video memory, within the default 2048 MB budget; lower the budget on cards under 6 GB)",
	  cv = { ghmpb_quality = 4, ghmpb_smooth = 2, ghmpb_sim_hz = 45, ghmpb_max_entities = 8, ghmpb_max_patches = 32,
	         ghmpb_max_particles = 4000, ghmpb_aftermath_res = 256, ghmpb_aftermath_max = 800 } },
}

function M.ApplyPreset(i)
	local p = M.PRESETS[i]
	if not p then return end
	for k, v in pairs(p.cv) do RunConsoleCommand(k, tostring(v)) end
end

function M.ResetDefaults()
	for _, cv in pairs(G.cv) do RunConsoleCommand(cv:GetName(), cv:GetDefault()) end
end

local function Tip(ctrl, cvar)
	local cv = GetConVar(cvar)
	if cv and IsValid(ctrl) and cv.GetHelpText then ctrl:SetTooltip(cv:GetHelpText()) end
	return ctrl
end

local function Check(f, label, cvar) return Tip(f:CheckBox(label, cvar), cvar) end
local function Slider(f, label, cvar, mn, mx, dec) return Tip(f:NumSlider(label, cvar, mn, mx, dec or 2), cvar) end

-- (1.26.1) how long blood takes to clot and dry at the current settings: the simulation's own drying law
-- (ghmpb_sim_main.h: k = 1 / drying time x surface x clamp(0.3 / (h + 0.1), 0.25, 3) x (1 - crust x clotted),
-- clotting dcf/dt = 4.8 / clotting time x (0.06 + cf) (1 - cf)) stepped forward in time for a few layer thicknesses.
local function Dur(s)
	if not s then return "more than 2 days" end
	if s < 90 then return string.format("%d s", math.max(1, math.floor(s + 0.5))) end
	if s < 5400 then return string.format("%d min", math.floor(s / 60 + 0.5)) end
	local h = math.floor(s / 3600)
	local m = math.floor((s - h * 3600) / 60 + 0.5)
	if m == 60 then h, m = h + 1, 0 end
	return m > 0 and string.format("%d h %d min", h, m) or string.format("%d h", h)
end
function M.DryEstimate(h0, mult, kabs, cap, kind)
	local dryT = G.DryTime() / math.max(mult or 1, 0.01)
	local r = G.cv.coag:GetBool() and 4.8 / G.CoagTime() or 0
	local crust = math.Clamp(G.cv.crust:GetFloat(), 0, 0.95)
	local soak = (kabs or 0) * G.SoakMult()
	local h, s, cf, t = h0, 0, 0, 0
	local clotT
	for _ = 1, 20000 do
		if h <= h0 * 0.05 then return t, clotT end
		if t > 172800 then return nil, clotT end
		local kd = math.Clamp(0.3 / (h + 0.1), 0.25, 3) * (1 - crust * cf) / dryT
		local ka = soak > 0 and soak * math.Clamp(1 - s / math.max(cap or 1, 1e-3), 0, 1) * (1 - 0.7 * cf) * (kind and G.SoakRamp(kind, t) or 1) or 0
		local k = kd + ka
		local dt = math.min(0.05 / math.max(k, 1e-9), r > 0 and 0.05 / r or 1e9, kind and 0.02 * G.CoagTime() or 1e9, 600)
		local dd = h * (1 - math.exp(-k * dt))
		h = h - dd
		s = s + dd * (ka / k)
		cf = math.min(cf + r * (0.06 + cf) * (1 - cf) * dt, 1)
		t = t + dt
		if not clotT and cf >= 0.9 then clotT = t end
	end
	return nil, clotT
end
function M.ClotTime()
	if not G.cv.coag:GetBool() then return nil end
	local r = 4.8 / G.CoagTime()
	local cf, t, dt = 0, 0, 0.02 / r
	while cf < 0.9 and t < 172800 do
		cf = math.min(cf + r * (0.06 + cf) * (1 - cf) * dt, 1)
		t = t + dt
	end
	return t
end
function M.DryReport()
	local sealed = G.DryMult("sealed")
	local lines = {}
	local clotT = M.ClotTime()
	local thin = M.DryEstimate(0.1, sealed)
	local film = M.DryEstimate(1, sealed)
	local pool = M.DryEstimate(3, sealed)
	local cs = G.Surface and G.Surface.concrete
	local thinC = cs and M.DryEstimate(0.1, G.DryMult("concrete"), cs.kabs, cs.cap, "concrete")
	local body = M.DryEstimate(0.1, G.DryMult("skin"))
	lines[#lines + 1] = "On a sealed floor (tile, paint):"
	lines[#lines + 1] = "   thin smear (0.1 mm): " .. Dur(thin) .. "   |   1 mm film: " .. Dur(film) .. "   |   3 mm pool: " .. Dur(pool)
	lines[#lines + 1] = "Thin smear on concrete (soaks in too): " .. Dur(thinC) .. "   |   on skin: " .. Dur(body)
	lines[#lines + 1] = G.cv.coag:GetBool() and ("Clotted (90 %): " .. Dur(clotT)) or "Clotting is off."
	local tl = G.cv.timelapse:GetFloat()
	if tl > 1.01 then lines[#lines + 1] = string.format("Time-lapse x%.1f is on: these are game times.", tl) end
	lines[#lines + 1] = "(Times to 95 % dry, from the simulation's own drying law; real pools also level, soak and clot unevenly.)"
	return table.concat(lines, "\n")
end

function M.CanSetServer()
	local lp = LocalPlayer()
	return game.SinglePlayer() or (IsValid(lp) and (lp:IsSuperAdmin() or lp:IsListenServerHost()))
end
local function SvSet(cvar, v)
	if game.SinglePlayer() or (IsValid(LocalPlayer()) and LocalPlayer():IsListenServerHost()) then RunConsoleCommand(cvar, tostring(v)) return end
	if type(G.ServerRuns) == "function" and not G.ServerRuns() then return end   -- (1.26.8) the server does not run PhysBlood: nothing to set there
	net.Start("ghmpb_svset")
	net.WriteString(cvar)
	net.WriteString(tostring(v))
	net.SendToServer()
end
local function SvCheck(f, label, cvar)
	local cv = GetConVar(cvar)
	local cb = f:CheckBox(label)
	if not cv then return cb end
	cb:SetChecked(cv:GetBool())
	function cb:OnChange(v)
		if (v and 1 or 0) ~= cv:GetInt() then
			self.ghmpbSync = RealTime() + 1
			SvSet(cvar, v and 1 or 0)
		end
	end
	local think = cb.Think
	function cb:Think()
		if think then think(self) end
		if self:GetChecked() ~= cv:GetBool() and (self.ghmpbSync or 0) < RealTime() then self:SetChecked(cv:GetBool()) end
		local can = M.CanSetServer()
		if self.ghmpbCan ~= can then self.ghmpbCan = can self:SetEnabled(can) end
	end
	return Tip(cb, cvar)
end
local function SvSlider(f, label, cvar, mn, mx, dec)
	local cv = GetConVar(cvar)
	local sl = f:NumSlider(label, nil, mn, mx, dec or 2)
	if not cv then return sl end
	sl:SetValue(cv:GetFloat())
	function sl:OnValueChanged(v)
		if math.abs(v - cv:GetFloat()) < 1e-4 then return end
		self.ghmpbSync = RealTime() + 1
		timer.Create("ghmpb_svset_" .. cvar, 0.3, 1, function() SvSet(cvar, string.format("%." .. (dec or 2) .. "f", v)) end)
	end
	local think = sl.Think
	function sl:Think()
		if think then think(self) end
		if not self:IsEditing() and (self.ghmpbSync or 0) < RealTime() and math.abs(self:GetValue() - cv:GetFloat()) > 1e-4 then
			self:SetValue(cv:GetFloat())
		end
		local can = M.CanSetServer()
		if self.ghmpbCan ~= can then self.ghmpbCan = can self:SetEnabled(can) end
	end
	return Tip(sl, cvar)
end

local function Combo(f, label, cvar, choices)
	local lbl = vgui.Create("DLabel", f)
	lbl:SetText(label)
	lbl:SetDark(true)
	local cb = vgui.Create("DComboBox", f)
	cb:SetSortItems(false)
	for _, c in ipairs(choices) do cb:AddChoice(c[2], tostring(c[1])) end
	local last
	function cb:Think()
		local v = GetConVarString(cvar)
		if v == last then return end
		last = v
		local n = tonumber(v)
		for _, c in ipairs(choices) do if tonumber(c[1]) == n then self:SetValue(c[2]) return end end
		self:SetValue(v)
	end
	function cb:OnSelect(_, _, data)
		if data ~= GetConVarString(cvar) then RunConsoleCommand(cvar, data) end
	end
	f:AddItem(lbl, cb)
	Tip(cb, cvar)
	return cb
end

local function Form(parent, title)
	local f = vgui.Create("DForm", parent)
	f:Dock(TOP)
	f:DockMargin(0, 0, 0, 6)
	f:SetName(title)
	return f
end

local function Tab(sheet, name, icon)
	local sp = vgui.Create("DScrollPanel", sheet)
	sp:Dock(FILL)
	sheet:AddSheet(name, sp, icon)
	return sp
end

-- (1.26.10) the Presets tab: save, load, rename, duplicate and delete presets of all the settings, and share them as XML
-- (cl_presets.lua)
local function BtnRow(f, list)
	local row = vgui.Create("DPanel", f)
	row:SetTall(24)
	row:SetPaintBackground(false)
	for _, b in ipairs(list) do
		local btn = vgui.Create("DButton", row)
		btn:SetText(b[1])
		if b[3] then btn:SetTooltip(b[3]) end
		btn:SizeToContentsX(18)
		btn:Dock(LEFT)
		btn:DockMargin(0, 0, 6, 0)
		btn.DoClick = b[2]
	end
	f:AddItem(row)
	return row
end

local function PresetsTab(t)
	local PR = G.Presets
	if type(PR) ~= "table" or type(PR.BUILTIN) ~= "string" or type(PR.List) ~= "function" then return end
	local f = Form(t, "My presets")
	f:Help("A preset holds all of your PhysBlood settings (not the server's). Save yours, switch between them, and share them: "
		.. "each one is a small XML file in garrysmod/data/" .. PR.DIR .. "/ - send the file, or copy its text below. "
		.. "\"" .. PR.BUILTIN .. "\" sets everything back to how GHM PhysBlood comes.")
	local lv = vgui.Create("DListView", f)
	lv:SetTall(170)
	lv:SetMultiSelect(false)
	lv:AddColumn("Preset")
	lv:AddColumn("Saved"):SetFixedWidth(118)
	lv:AddColumn("Settings"):SetFixedWidth(58)
	f:AddItem(lv)
	local status = vgui.Create("DLabel", f)
	status:SetText("")
	status:SetWrap(true)
	status:SetAutoStretchVertical(true)
	local function Msg(ok, txt)
		status:SetText(txt)
		status:SetTextColor(ok and Color(30, 110, 30) or Color(170, 50, 20))
	end
	local function Refresh(sel)
		lv:Clear()
		local b = lv:AddLine(PR.BUILTIN, "built in", "")
		b.presetName = PR.BUILTIN
		for _, p in ipairs(PR.List()) do
			local line = lv:AddLine(p.name, p.saved, tostring(p.count))
			line.presetName = p.name
			if sel and string.lower(p.name) == string.lower(sel) then lv:SelectItem(line) end
		end
		if sel and string.lower(sel) == string.lower(PR.BUILTIN) then lv:SelectItem(b) end
	end
	M.RefreshPresets = Refresh
	local function Selected(own)
		local _, line = lv:GetSelectedLine()
		local n = line and line.presetName
		if not n then Msg(false, "Pick a preset in the list first.") return nil end
		if own and string.lower(n) == string.lower(PR.BUILTIN) then Msg(false, "GHM's defaults are built in: save a copy to change them.") return nil end
		return n
	end
	local function Load(n)
		local ok, r = PR.Load(n)
		if ok then Msg(true, "Loaded \"" .. n .. "\": " .. r .. " settings changed.") else Msg(false, "Not loaded: " .. tostring(r)) end
	end
	local function SaveAs(n, values)
		local ok, why = PR.Save(n, values)
		if ok then Msg(true, "Saved \"" .. n .. "\" (garrysmod/data/" .. PR.DIR .. "/" .. why .. ").") Refresh(n)
		else Msg(false, "Not saved: " .. tostring(why)) end
		return ok
	end
	function lv:DoDoubleClick(_, line) if line and line.presetName then Load(line.presetName) end end
	BtnRow(f, {
		{ "Load", function() local n = Selected() if n then Load(n) end end, "Set all settings to the selected preset (double-click works too)" },
		{ "Save current as new...", function()
			Derma_StringRequest("GHM PhysBlood - save preset", "Name of the new preset:", "My preset", function(txt)
				txt = string.Trim(txt or "")
				if PR.Find(txt) then
					Derma_Query("There is a preset called \"" .. txt .. "\" already. Overwrite it with your current settings?", "GHM PhysBlood",
						"Overwrite", function() SaveAs(txt) end, "Cancel")
				else
					SaveAs(txt)
				end
			end)
		end, "Save all your current settings as a new preset" },
		{ "Update", function()
			local n = Selected(true)
			if not n then return end
			Derma_Query("Overwrite \"" .. n .. "\" with your current settings?", "GHM PhysBlood", "Overwrite", function() SaveAs(n) end, "Cancel")
		end, "Put your current settings into the selected preset" },
	})
	BtnRow(f, {
		{ "Rename...", function()
			local n = Selected(true)
			if not n then return end
			Derma_StringRequest("GHM PhysBlood - rename preset", "New name for \"" .. n .. "\":", n, function(txt)
				local ok, why = PR.Rename(n, string.Trim(txt or ""))
				if ok then Msg(true, "Renamed to \"" .. string.Trim(txt) .. "\".") Refresh(string.Trim(txt)) else Msg(false, "Not renamed: " .. tostring(why)) end
			end)
		end },
		{ "Duplicate", function()
			local n = Selected()
			if not n then return end
			local nn = n .. " copy"
			local i = 2
			while PR.Find(nn) do nn = n .. " copy " .. i i = i + 1 end
			local ok, why = PR.Duplicate(n, nn)
			if ok then Msg(true, "Copied to \"" .. nn .. "\".") Refresh(nn) else Msg(false, "Not copied: " .. tostring(why)) end
		end },
		{ "Delete", function()
			local n = Selected(true)
			if not n then return end
			Derma_Query("Delete the preset \"" .. n .. "\"? (Its file is moved to garrysmod/data/" .. PR.TRASH .. "/.)", "GHM PhysBlood", "Delete", function()
				local ok, why = PR.Delete(n)
				if ok then Msg(true, "Deleted \"" .. n .. "\" (moved to the trash folder).") Refresh() else Msg(false, "Not deleted: " .. tostring(why)) end
			end, "Cancel")
		end },
		{ "Refresh", function() Refresh() Msg(true, "List read again from garrysmod/data/" .. PR.DIR .. "/.") end, "Read the presets folder again (after putting a received .xml file in it)" },
	})
	f:AddItem(status)

	local x = Form(t, "Share: export / import (XML)")
	x:Help("Export: show a preset (or your current settings) as XML, then copy it and send it. Import: paste a preset's XML text "
		.. "into the box and press Import - it is saved as a preset in your list. Only PhysBlood's own settings are read from it; "
		.. "anything else is ignored, and every value is kept in its range.")
	local box = vgui.Create("DTextEntry", x)
	box:SetMultiline(true)
	box:SetTall(150)
	box:SetVerticalScrollbarEnabled(true)
	box:SetFont("DefaultFixed")
	if box.SetMaximumCharCount then box:SetMaximumCharCount(200000) end
	x:AddItem(box)
	M.presetBox = box
	BtnRow(x, {
		{ "Selected preset", function()
			local n = Selected()
			if not n then return end
			box:SetText(PR.XMLOf(n) or "")
			Msg(true, "\"" .. n .. "\" as XML in the box below the list.")
		end, "Show the selected preset as XML" },
		{ "Current settings", function()
			box:SetText(PR.ToXML("My settings"))
			Msg(true, "Your current settings as XML in the box.")
		end, "Show your current settings as XML" },
		{ "Copy", function()
			SetClipboardText(box:GetValue() or "")
			Msg(true, "Copied to the clipboard.")
		end, "Copy the XML in the box to the clipboard" },
	})
	BtnRow(x, {
		{ "Import...", function()
			local txt = box:GetValue() or ""
			local r, why = PR.FromXML(txt)
			if not r then Msg(false, "Not imported: " .. tostring(why) .. ".") return end
			Derma_StringRequest("GHM PhysBlood - import preset", "Save the imported preset (" .. r.count .. " settings"
				.. (r.skipped > 0 and (", " .. r.skipped .. " unknown ones left out") or "") .. ") as:", r.name, function(name)
				name = string.Trim(name or "")
				local function Do()
					local ok, res = PR.Import(txt, name)
					if not ok then Msg(false, "Not imported: " .. tostring(res)) return end
					Refresh(name)
					Msg(true, "Imported as \"" .. name .. "\".")
					Derma_Query("Load \"" .. name .. "\" now?", "GHM PhysBlood", "Load it", function() Load(name) end, "Not now")
				end
				if PR.Find(name) then
					Derma_Query("There is a preset called \"" .. name .. "\" already. Overwrite it?", "GHM PhysBlood", "Overwrite", Do, "Cancel")
				else
					Do()
				end
			end)
		end, "Save the XML in the box as a preset" },
		{ "Clear", function() box:SetText("") end },
	})
	Refresh()
end

local function Usage()
	if G.Lite and G.Lite.on and G.Lite.Counts then
		local st, pools, bodies = G.Lite.Counts()
		return string.format("Lite renderer: %d stains, %d pools, %d bodies with blood, %d drops   |   CPU %.2f ms/frame",
			st, pools, bodies, G.Particles.Count and G.Particles.Count() or 0, G.Render.stats and G.Render.stats.ms or 0)
	end
	local live, baked = 0, 0
	for _, d in pairs(G.Entities.domains or {}) do
		if G.Entities.IsLive and G.Entities.IsLive(d) then live = live + 1 end
		if G.Entities.HasAft and G.Entities.HasAft(d) then baked = baked + 1 end
	end
	local pl, pa = 0, 0
	if G.Surfaces.Counts then pl, pa = G.Surfaces.Counts() end
	return string.format("Simulated now: %d models, %d world patches, %d drops   |   Aftermath: %d bodies, %d world patches   |   CPU %.2f ms/frame",
		live, pl, G.Particles.Count and G.Particles.Count() or 0, baked, pa, G.Render.stats and G.Render.stats.ms or 0)
end

function M.Build(frame)
	frame:SetTitle("GHM PhysBlood - Settings")
	frame:SetIcon(ICON)
	frame:SetSizable(true)
	frame:SetMinWidth(520)
	frame:SetMinHeight(420)

	local foot = vgui.Create("DPanel", frame)
	foot:Dock(BOTTOM)
	foot:SetTall(56)
	foot:DockMargin(0, 4, 0, 0)
	foot:SetPaintBackground(false)
	local usage = vgui.Create("DLabel", foot)
	usage:Dock(TOP)
	usage:SetTall(18)
	usage:SetTextColor(Color(220, 220, 220))
	local nextU = 0
	function usage:Think()
		if RealTime() < nextU then return end
		nextU = RealTime() + 0.5
		self:SetText(Usage())
	end
	local row = vgui.Create("DPanel", foot)
	row:Dock(FILL)
	row:SetPaintBackground(false)
	local function FootBtn(text, tip, fn)
		local b = vgui.Create("DButton", row)
		b:SetText(text)
		b:SetTooltip(tip)
		b:Dock(LEFT)
		b:DockMargin(0, 6, 6, 0)
		b:SizeToContentsX(24)
		b.DoClick = fn
		return b
	end
	FootBtn("Remove all blood", "Removes live and aftermath blood everywhere (ghmpb_clear)", function() RunConsoleCommand("ghmpb_clear") end)
	FootBtn("Remove old blood", "Removes only the aftermath layer, keeps fresh blood (ghmpb_clear_aftermath)",
		function() RunConsoleCommand("ghmpb_clear_aftermath") end)
	local reset = FootBtn("Reset to defaults", "Sets every client option back to its default", function()
		Derma_Query("Reset all GHM PhysBlood client settings to their defaults?", "GHM PhysBlood", "Reset", M.ResetDefaults, "Cancel")
	end)
	reset:Dock(RIGHT)
	reset:DockMargin(6, 6, 0, 0)

	local sheet = vgui.Create("DPropertySheet", frame)
	sheet:Dock(FILL)

	local t = Tab(sheet, "Quality", "icon16/cog.png")
	local fr = Form(t, "Renderer")
	Combo(fr, "Renderer", "ghmpb_render_mode", { { 0, "Automatic" }, { 1, "Shaders (full look)" }, { 2, "Lite (no shaders)" } })
	local rs = fr:Help("")
	function rs:Think()
		if (self.nextT or 0) > RealTime() then return end
		self.nextT = RealTime() + 0.5
		local L = G.Lite
		local have = L and L.ShadersPresent and L.ShadersPresent()
		local SC = G.ShaderCheck
		local st = (SC and SC.Summary) and SC.Summary(SC.result) or (have and "installed" or "not installed")
		self:SetText("Now: " .. ((L and L.on) and "lite" or "shaders") .. "   |   shader files: " .. st)
		self:SetTextColor((SC and SC.result and SC.result.state ~= "ok") and Color(170, 70, 20) or Color(40, 40, 40))
	end
	-- (1.26.6) check the installed shader files against this version's pack; offers the download when they are older
	local sb = fr:Button("Check shader files / get the shader pack")
	sb.DoClick = function() RunConsoleCommand("ghmpb_shader_check") end
	fr:ControlHelp("Shaders: the full look - blood flows and spreads as a liquid, glossy wet film, live drying. It needs the shader files (garrysmod/shaders/fxc), which the Steam Workshop can not deliver. Lite: drawn with the game's own shaders - stains, prints, runs and growing pools on the world, decals on bodies, drops as sprites; the physics (wounds, drops, spatter, runs, footprints) is the same. Automatic picks the shaders when their files are installed. Switching removes the blood on screen.")
	Slider(fr, "Lite: stains kept", "ghmpb_lite_stains", 200, 50000, 0)
	fr:ControlHelp("Lite pools grow as blood does: round the edges of the floor, along walls, downhill on a slope, each a different shape, darker where they are deep; they dry from the rim in (it goes darker), and drops landing in them ripple.")
	Check(fr, "Draw the Crisis Response splats myself (they do not vanish)", "ghmpb_splat_mesh")
	Slider(fr, "Splats kept", "ghmpb_splats_kept", 100, 30000, 0)
	fr:ControlHelp("The game removes old decals once it has too many (200 in multiplayer) or when new ones cover them, so splats vanished while the shooting went on. On: PhysBlood draws the splats on the world itself (both renderers), so they stay until this many are on the map, the oldest going first; they also turn with the way the blood flew. Off: engine decals. Splats on props stay engine decals (props move).")
	local f = Form(t, "Presets")
	f:Help("Pick a starting point, then fine-tune below. Changing the cell resolution removes the blood that is on screen.")
	local pr = vgui.Create("DPanel", f)
	pr:SetTall(26)
	pr:SetPaintBackground(false)
	for i, p in ipairs(M.PRESETS) do
		local b = vgui.Create("DButton", pr)
		b:SetText(p.name)
		b:SetTooltip(p.tip)
		b:Dock(LEFT)
		b:DockMargin(0, 0, 6, 0)
		b:SetWide(84)
		b.DoClick = function() M.ApplyPreset(i) end
	end
	f:AddItem(pr)
	f = Form(t, "Resolution and smoothness")
	Check(f, "Enable GHM PhysBlood", "ghmpb_enable")
	Combo(f, "Cell resolution", "ghmpb_quality", {
		{ 1, "Low - 256 body / 128 world cells" }, { 2, "Medium - 384 / 256" }, { 3, "High - 512 / 384" }, { 4, "Ultra - 640 / 512" } })
	Combo(f, "Edge smoothing", "ghmpb_smooth", {
		{ 0, "Off - raw cells (sharpest, blocky)" }, { 1, "Smooth - bicubic + anti-aliased edges" },
		{ 2, "Smooth + organic edges (recommended)" } })
	f:ControlHelp("Smoothing interpolates the cell field with a bicubic B-spline, anti-aliases the blood outline and breaks up the grid with a fine organic noise, so trails and pools stay round and soft instead of pixelated.")
	Slider(f, "Simulation rate (steps / s)", "ghmpb_sim_hz", 10, 60, 0)
	f = Form(t, "Budgets")
	Slider(f, "Max simulated models", "ghmpb_max_entities", 1, 32, 0)
	Slider(f, "Max simulated world patches", "ghmpb_max_patches", 4, 128, 0)
	Slider(f, "Max flying droplets", "ghmpb_max_particles", 100, 6000, 0)
	Check(f, "Use the C++ droplet solver (if installed)", "ghmpb_native")
	f = Form(t, "Frame rate")
	f:Help("Off by default: the blood keeps its full quality. Turn these on if big fights slow your game down.")
	Check(f, "Adaptive quality (hold the frame rate)", "ghmpb_perf_adaptive")
	Slider(f, "Target frame rate", "ghmpb_perf_target_fps", 20, 240, 0)
	f:ControlHelp("When a lot of blood slows the game down (many bleeding bodies, dismemberment, big pools), blood far away, behind you or no longer moving loses detail first: it simulates less often, settles into the static layer sooner and jets throw fewer, bigger drops. Blood close to the camera keeps its full detail. Console: ghmpb_prof shows where the frame goes.")
	Check(f, "Scale with the size of the fight", "ghmpb_battle_lod")
	f:ControlHelp("A fight between a few NPCs keeps every detail. In a large battle (dozens of NPCs, many hits a second, many bodies bleeding) blood far away or out of view gets less detail before the frame rate drops, and fewer bodies are simulated at once - the nearest and most visible keep theirs. Blood near you and in view keeps its full detail.")
	local gov = f:Help("")
	local nextG = 0
	local govBase = gov.Think
	function gov:Think()
		if govBase then govBase(self) end
		if RealTime() < nextG then return end
		nextG = RealTime() + 0.5
		local fl = G.Prof and G.Prof.frame.last
		local p = G.Gov and G.Gov.p or 0
		if not fl then return end
		local bl = G.Battle and G.Battle.level or 0
		self:SetText(string.format("Now: %.0f fps (blood %.1f ms of %.1f ms per frame), quality reduced by %d%%, battle size %d%%", 1000 / math.max(fl.avg, 0.1),
			G.Prof.last["=total"] and G.Prof.last["=total"][1] or 0, fl.avg, math.floor(p * 100 + 0.5), math.floor(bl * 100 + 0.5)))
		self:SetTextColor(p > 0.05 and Color(190, 80, 30) or Color(40, 110, 40))
	end
	f = Form(t, "Video memory")
	Combo(f, "Budget", "ghmpb_vram_mb", { { 512, "512 MB - 2 GB cards" }, { 1024, "1 GB - 4 GB cards" },
		{ 2048, "2 GB - 6-8 GB cards (default)" }, { 3072, "3 GB - 10-12 GB cards" }, { 4096, "4 GB - 16 GB+ cards" } })
	local mem = f:Help("")
	local nextM = 0
	local memBase = mem.Think
	function mem:Think()
		if memBase then memBase(self) end
		if RealTime() < nextM then return end
		nextM = RealTime() + 0.5
		local B = G.Budget
		local c = B.Caps()
		local txt = string.format("At full use: %d MB of the %d MB budget. Allocated so far: %d MB.", math.floor(c.needMB + 0.5),
			c.budgetMB, math.floor(B.Allocated() + 0.5))
		if c.scale < 1 then
			txt = txt .. string.format("\nOver budget - limits lowered to fit: %d models (of %d), %d world patches (of %d), %d old-blood patches (of %d), %d old-blood bodies (of %d).",
				c.ents, G.cv.maxents:GetInt(), c.patches, G.cv.maxpatches:GetInt(), c.aft, G.cv.aftmax:GetInt(), c.aftb, G.cv.aftbodies:GetInt())
			self:SetTextColor(Color(190, 80, 30))
		else
			self:SetTextColor(Color(40, 110, 40))
		end
		self:SetText(txt)
	end
	f:ControlHelp("Blood memory can not be released while the game runs: after changing the resolution or the aftermath resolution, restart the game to free the old buffers.")
	f:ControlHelp("C++ solver: " .. ((G.Native and G.Native.Available and G.Native.Available()) and "loaded" or "not installed - using the Lua solver"))

	t = Tab(sheet, "Look", "icon16/palette.png")
	f = Form(t, "Blood look")
	Check(f, "Enhanced two-pass surface shader (refraction, caustics & 3D bubbles)", "ghmpb_surface_enhanced")
	f:ControlHelp("Draws live world blood in two passes (optical body + liquid coat) instead of one: bends the floor under translucent rims, focuses sun and flashlight caustics, restores 3D bubble domes and dual-scale capillary ripples, and unlocks full meniscus rim glints. Untick at any time to switch back to the classic single-pass shader.")
	Slider(f, "Density / opacity", "ghmpb_density", 0.2, 4, 2)
	f:ControlHelp("How quickly blood turns opaque with thickness. Thick blood hides the floor below it; thin edges and splatter stay bright and translucent.")
	Slider(f, "Wetness", "ghmpb_pool_look", 0, 2, 2)
	f:ControlHelp("How wet fresh blood looks. 1 = physical. Higher: even thin smears and splatter read as liquid - glossy and deep red. Lower: blood looks tacky and dull, as if it had begun to dry.")
	Slider(f, "Fresh blood wetness", "ghmpb_fresh_wet", 1, 3, 2)
	f:ControlHelp("How much wetter blood looks while it is fresh: it shines more (4x at the default: sharp reflections of the lights and everything around it, on pools, spatter and blood on bodies) and thin films, splatter and runs read as liquid - glossy and deep red - instead of a dry stain. Fades out as the blood gels and clots (old blood does not turn shiny). 1 = only the Wetness and Shine settings.")
	Slider(f, "Shine", "ghmpb_reflections", 0, 3, 2)
	f:ControlHelp("Strength of the reflections and highlights on blood. 1 = physically correct: wet blood is a dark liquid that reads as wet through sharp reflections of the lights and everything around it.")
	Slider(f, "Gloss (sharpness of the shine)", "ghmpb_gloss", 0.2, 3, 2)
	Slider(f, "Relief depth (dynamic normals)", "ghmpb_normal_depth", 0, 6, 2)
	Check(f, "Thin blood follows the surface's normal map", "ghmpb_surface_normals")
	f:ControlHelp("Thin blood and dried stains take on the relief of the surface's own normal map - grout, cracks, wood grain, pores - and its grooves draw thin blood along them. How thick the blood must be to level it out depends on the surface: almost nothing on glass and metal, a lot on gravel, soil and grass. Deep pools are smooth.")
	Check(f, "Separate blood for mirrored halves of models", "ghmpb_uv_mirror")
	f:ControlHelp("Many models paint both legs (or arms) from one mirrored half of their texture. On: each side gets its own blood. Off: a wound on one leg shows on both (uses less video memory).")
	Slider(f, "Froth", "ghmpb_froth", 0, 2, 2)
	f:ControlHelp("Bubbles on fresh blood: coughed-up lung blood is frothy, bright arterial spurts and hard, fast impacts trap air, a slow venous pour hardly any. The froth floats and flows with the pool and bursts over a minute or so, faster as the blood clots. On floors and gentle slopes.")
	Slider(f, "Pool ripples", "ghmpb_pool_ripples", 0, 3, 2)
	f:ControlHelp("A drop landing in a wet pool sends a ring wave out through it, and blood welling into a pool from a body stirs its surface. 0 = none.")
	f = Form(t, "Reflections and lights")
	Slider(f, "Reflection probes (groups of blood)", "ghmpb_reflect_probes", 0, 6, 0)
	f:ControlHelp("Each group of blood nearest to you gets a live reflection of what stands round it - walls, lamps, bodies, you - rendered from the middle of the group and refreshed while you play, so pools mirror the real scene instead of the map's baked cubemap. 0 = the map's cubemap only (the default: the probes' extra views can make the shadows of bodies lying in the blood flicker).")
	Slider(f, "Probe time budget (ms a second)", "ghmpb_reflect_budget", 2, 200, 0)
	f:ControlHelp("How much time the probes may spend rendering their views. A face is one small render of the scene: on a heavy map it costs more, so they refresh more slowly within the same budget.")
	Check(f, "Highlights from the map's lamps and flashlights", "ghmpb_map_lights")
	f:ControlHelp("The strongest lights around each group of blood - lamps of the map, dynamic lights, projected textures, other players' flashlights - each put a glint in the wet blood (your own flashlight always does). The light ON the blood already comes from every light in the game.")
	f = Form(t, "Blood colour")
	Slider(f, "Fresh blood brightness", "ghmpb_color_fresh", 0.3, 3, 2)
	f:ControlHelp("Wet blood: higher is lighter and redder (thin splatter scarlet, pools crimson), lower is darker and more opaque.")
	Slider(f, "Dried / old blood brightness", "ghmpb_color_dry", 0.3, 3, 2)
	f:ControlHelp("Dried stains and crusts, and how dark wet blood turns as it clots and ages (over the clotting time): higher is a lighter rust-brown, lower is darker, nearly black. Old blood also loses most of its shine as it dries.")
	Slider(f, "Hue (- crimson / purple, + orange / scarlet)", "ghmpb_color_hue", -1, 1, 2)
	f:ControlHelp("Arterial blood (spurting arteries, lungs / chest, neck) is brighter than venous blood from limbs and dark blood from the abdomen (liver, gut); where they meet they mix per pixel.")
	local rb = f:Button("Reset colours")
	rb.DoClick = function()
		for _, n in ipairs({ "ghmpb_color_fresh", "ghmpb_color_dry", "ghmpb_color_hue", "ghmpb_density" }) do
			local c = GetConVar(n)
			if c then RunConsoleCommand(n, c:GetDefault()) end
		end
	end

	-- (1.26.6) the player's own blood colours: a thin film of fresh blood and dense blood (pools)
	f = Form(t, "Your own blood colours")
	Check(f, "Use my own blood colours (red blood)", "ghmpb_color_custom")
	f:ControlHelp("Pick the colour of a thin film of fresh blood and of dense blood (deep pools, thick runs). The sliders above still fine-tune both. Yellow, green and zombie blood keep their own colours.")
	local function Picker(label, cvar, def)
		f:Help(label)
		local box = vgui.Create("DPanel", f)
		box:SetTall(132)
		box:SetPaintBackground(false)
		local mx = vgui.Create("DColorMixer", box)
		mx:Dock(FILL)
		mx:SetPalette(false)
		mx:SetAlphaBar(false)
		mx:SetWangs(true)
		local function FromCV()
			local r, g, b = G.U.ParseRGB(GetConVar(cvar):GetString(), def)
			return Color(r, g, b)
		end
		box.applied = GetConVar(cvar):GetString()
		mx:SetColor(FromCV())
		function mx:ValueChanged(col)
			local s = string.format("%d %d %d", math.floor(col.r + 0.5), math.floor(col.g + 0.5), math.floor(col.b + 0.5))
			if s == box.applied then return end
			box.pending = s
			timer.Create("ghmpb_colpick_" .. cvar, 0.2, 1, function()
				if not IsValid(box) or not box.pending then return end
				box.applied = box.pending
				box.pending = nil
				RunConsoleCommand(cvar, box.applied)
				if not GetConVar("ghmpb_color_custom"):GetBool() then RunConsoleCommand("ghmpb_color_custom", "1") end
			end)
		end
		-- follow the setting when it changes elsewhere (reset button, console)
		function box:Think()
			if (self.nextT or 0) > RealTime() then return end
			self.nextT = RealTime() + 0.4
			local s = GetConVar(cvar):GetString()
			if not self.pending and s ~= self.applied then
				local r, g, b = G.U.ParseRGB(s, def)
				self.applied = string.format("%d %d %d", r, g, b)
				mx:SetColor(Color(r, g, b))
			end
		end
		f:AddItem(box)
	end
	Picker("Blood colour - a thin film of fresh blood on a light floor", "ghmpb_color_blood", G.U.DEF_BLOOD)
	Picker("Dense blood colour - a deep pool", "ghmpb_color_dense", G.U.DEF_DENSE)
	local pv = vgui.Create("DPanel", f)
	pv:SetTall(80)
	pv:SetPaintBackground(false)
	local function S8(c) c = math.Clamp(c, 0, 1) return (c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 end
	function pv:Paint(w, h)
		local U = G.U
		local t2, d2 = U.ShaderLook(G.BloodHue(), G.BloodAbsorb())
		local r1, g1, b1 = U.ParseRGB(GetConVar("ghmpb_color_blood"):GetString(), U.DEF_BLOOD)
		local r2, g2, b2 = U.ParseRGB(GetConVar("ghmpb_color_dense"):GetString(), U.DEF_DENSE)
		local cw = math.floor((w - 30) / 4)
		local items = {
			{ "Your thin", Color(r1, g1, b1) }, { "Shaders: thin", Color(S8(t2[1]), S8(t2[2]), S8(t2[3])) },
			{ "Your dense", Color(r2, g2, b2) }, { "Shaders: dense", Color(S8(d2[1]), S8(d2[2]), S8(d2[3])) },
		}
		for i, it in ipairs(items) do
			local x = (i - 1) * (cw + 10)
			draw.SimpleText(it[1], "DermaDefault", x + 2, 0, Color(40, 40, 40))
			draw.RoundedBox(4, x, 16, cw, 34, Color(20, 20, 20))
			draw.RoundedBox(4, x + 1, 17, cw - 2, 32, it[2])
		end
		local on = U.CustomOn()
		local _, _, e = U.ShaderFit()
		local off = on and e and e > 0.004
		local msg = (not on) and "Off - the blood uses the sliders above."
			or (off and "Outside what the blood shaders can show: they use the closest. Lite, 3D bursts and mist show yours exactly."
			or "The blood shaders match your colours closely.")
		draw.SimpleText(msg, "DermaDefault", 0, 58, off and Color(170, 70, 20) or Color(40, 110, 40))
	end
	f:AddItem(pv)
	f:ControlHelp("The blood shaders work the colour of blood out from how it absorbs light. They can shift it from crimson / purple to scarlet / orange and from bright to near black, but not out of the red family (green or blue blood comes out as the nearest red). The Lite renderer, the 3D bursts and the mist show any colour.")
	local rb2 = f:Button("Reset to the default colours")
	rb2.DoClick = function()
		for _, n in ipairs({ "ghmpb_color_custom", "ghmpb_color_blood", "ghmpb_color_dense" }) do
			local c = GetConVar(n)
			if c then RunConsoleCommand(n, c:GetDefault()) end
		end
	end
	local rbY = f:Button("GHM's colours (the defaults)")
	rbY.DoClick = function() M.ApplyGHMColours() end
	f:ControlHelp("The colours GHM PhysBlood comes with. Console: ghmpb_colour_choose shows the first-start choice again.")
	local rb3 = f:Button("Physical colours (the shaders' own, no picked colours)")
	rb3.DoClick = function()
		RunConsoleCommand("ghmpb_color_custom", "0")
		RunConsoleCommand("ghmpb_color_fresh", "1") RunConsoleCommand("ghmpb_color_dry", "1") RunConsoleCommand("ghmpb_density", "1")
	end

	t = Tab(sheet, "Simulation", "icon16/drink.png")
	f = Form(t, "Flow")
	Slider(f, "Thickness (surface pinning)", "ghmpb_thickness", 0.5, 4, 2)
	f:ControlHelp("Higher: blood stays in thick, round beads and pools instead of spreading thin.")
	Slider(f, "Viscosity", "ghmpb_viscosity", 0.3, 4, 2)
	Slider(f, "Body motion influence", "ghmpb_motion", 0, 1, 2)
	f = Form(t, "Runs on walls")
	Slider(f, "Runs (0 = off)", "ghmpb_wall_runs", 0, 4, 2)
	f:ControlHelp("Wet blood on a wall runs once there is more of it than its lower edge can hold: big drops, arterial hits and clusters of spatter shed rivulets that meander down, follow earlier runs, merge, leave a thin trail and stop in a small bead when their blood runs out. Higher: runs start from less blood.")
	Slider(f, "Run speed", "ghmpb_run_speed", 0.25, 3, 2)
	Slider(f, "Pool streams (0 = off)", "ghmpb_pool_tendrils", 0, 3, 2)
	f:ControlHelp("A pool on a smooth, level-looking floor sends out thin straight streams once it holds enough blood: they follow the real slope of the floor and its tiny unevenness, branch now and then, end in a small bead and drip over edges. Rough, porous or soaking floors (carpet, dirt, grass) hold the blood in the pool instead.")
	Slider(f, "Blood trail from moving bleeders", "ghmpb_bleed_trail", 0, 3, 2)
	f:ControlHelp("A wounded body that walks or runs drips part of its bleeding along its path (falling drops carry its speed: elongated stains point the way it went). An arterial wound adds a gush of drops on every pulse.")
	Slider(f, "Blood on melee weapons", "ghmpb_blade_blood", 0, 3, 2)
	f:ControlHelp("A blade or club that hits a bleeding body picks blood up. Swinging it throws cast-off drops along the real swing path (lines of drops on walls and ceiling); holding it still lets it drip. Blades carry thin films, clubs more. The blood dries on the weapon over about a minute.")
	f = Form(t, "Blood in water")
	Check(f, "Blood mixes into water (clouds)", "ghmpb_water")
	f:ControlHelp("Drops, wounds, runs and pools that reach water turn into red clouds that sink, spread and fade; pools running into water thin out at the water line. A body lying in water loses its wet blood into it.")
	Slider(f, "Cloud strength", "ghmpb_water_amount", 0.2, 4, 2)
	Slider(f, "Clouds last up to (s)", "ghmpb_water_time", 10, 600, 0)
	Slider(f, "Wash-off under water", "ghmpb_water_wash", 0, 3, 2)
	f:ControlHelp("How fast blood on a body or a surface under water mixes into the water: fresh wet blood goes over several seconds, clotted blood and dried stains much slower. 0 = it stays on.")
	f = Form(t, "Pools")
	Slider(f, "Pool size (blood lost when dying)", "ghmpb_pool_size", 0, 5, 2)
	f:ControlHelp("Pools grow from under the body where it touches the floor, close to the wound, and keep spreading while the body bleeds out.")
	Slider(f, "Floor unevenness", "ghmpb_floor_unevenness", 0, 3, 2)
	f:ControlHelp("Real floors are never flat: a pool is a small lake on a few millimetres of relief - it fills the shallow dips first, pushes lobes and bays along them, runs short tongues down worn grooves and leaves dry islands where the floor is a hair higher, so it never spreads as a round disc. Runs on walls meander. Higher = more ragged pools; 0 = perfectly flat, round pools.")
	f:ControlHelp("Pools behave as a liquid: their edges round off, pools that come within about a centimetre of each other pull together and join into one, and on a slope a pool runs down in uneven tongues and fingers.")
	f = Form(t, "Blood supply")
	Slider(f, "Blood volume of a human (ml)", "ghmpb_blood_volume", 500, 20000, 0)
	f:ControlHelp("Everything a body loses (wounds, jets, sprays, its pool) comes out of this. Other creatures scale with their size. A body that has bled out stays dry.")
	Slider(f, "Corpses bleed for (s)", "ghmpb_corpse_bleed_time", 10, 3600, 0)
	f:ControlHelp("New wounds on a dead body bleed fully for the first 30 s, then less and less; after this time they stay dry (the blood has settled and clotted). A spawned ragdoll counts from its first wound.")
	f = Form(t, "Coagulation and drying")
	f:Help("Clotting, drying and soaking have their own tab now: Drying.")

	t = Tab(sheet, "Drying", "icon16/hourglass.png")
	f = Form(t, "Conditions")
	f:Help("Starting points for the settings below (rough figures: warm, dry or moving air dries blood faster; cold slows clotting). Console: ghmpb_dry_conditions <indoor|hot|windy|cold>.")
	local er = vgui.Create("DPanel", f)
	er:SetTall(26)
	er:SetPaintBackground(false)
	for _, e in ipairs(G.DRY_ENVS) do
		local b = vgui.Create("DButton", er)
		b:SetText(e.name)
		b:SetTooltip(e.tip)
		b:Dock(LEFT)
		b:DockMargin(0, 0, 6, 0)
		b:SetWide(104)
		b.DoClick = function() G.ApplyDryEnv(e.id) end
	end
	f:AddItem(er)
	local envNow = f:Help("")
	local envBase = envNow.Think
	function envNow:Think()
		if envBase then envBase(self) end
		local e = G.DryEnvNow()
		local txt = "Current conditions: " .. (e and e.name or "Custom")
		if self:GetText() ~= txt then self:SetText(txt) end
	end
	f = Form(t, "Time-lapse")
	Slider(f, "Time-lapse (x real time)", "ghmpb_timelapse", 1, 30, 1)
	f:ControlHelp("Runs drying, clotting and the ageing of dried blood this many times faster, everything else at normal speed: x10 shows twenty minutes of drying in two - a whole drying sequence in one lesson. Blood that has already dried does not jump: it only goes on faster. Set back to 1 for real time.")
	f = Form(t, "Clotting")
	Check(f, "Blood coagulates (clots)", "ghmpb_coagulation")
	Slider(f, "Clotting time (s)", "ghmpb_coag_time", 15, 1800, 0)
	f:ControlHelp("Clotting starts slowly, then gels quickly (about 90 % after this time). Clotted blood gets darker and matte, stops running and holds its shape; it also slows down how fast blood dries and soaks in. Weapons and pool streams gel with it too.")
	Slider(f, "Clotted skin slows drying", "ghmpb_dry_crust", 0, 0.95, 2)
	f:ControlHelp("A clot forms a skin that keeps the blood under it wet: 0 = clotted blood dries as fast as liquid blood, 0.95 = a clotted pool stays wet underneath for a long time. Default 0.6.")
	f = Form(t, "Drying speed")
	Slider(f, "Drying time of thin blood (s)", "ghmpb_drytime", 20, 7200, 0)
	f:ControlHelp("How long a thin film takes to dry into a stain. Thicker blood takes longer (a pool many times longer): edges dry first, the middle of a pool last. Dried blood turns into a brown crust that darkens further as it ages.")
	Slider(f, "On bodies (skin, clothes)", "ghmpb_dry_bodies", 0.1, 5, 2)
	Slider(f, "On porous ground (concrete, brick, wood, soil, carpet...)", "ghmpb_dry_porous", 0.1, 5, 2)
	Slider(f, "On sealed surfaces (tile, paint, metal, glass, stone...)", "ghmpb_dry_sealed", 0.1, 5, 2)
	Slider(f, "On ice and snow", "ghmpb_dry_cold", 0.1, 5, 2)
	f:ControlHelp("Multipliers of the drying speed per kind of surface: 2 = dries twice as fast there, 0.5 = stays wet twice as long. Ice and snow already keep blood wet about twice as long as other ground.")
	Slider(f, "Soaking in (porous ground, clothes)", "ghmpb_soak_speed", 0, 4, 2)
	f:ControlHelp("How fast porous surfaces and clothes drink blood in (cardboard and carpet fastest, concrete slowly, tile and metal not at all). Soaked-in blood leaves a darker, matte stain. 0 = nothing soaks in, blood only dries on top.")
	Slider(f, "Fresh blood soaks in slowly", "ghmpb_soak_delay", 0, 3, 2)
	f:ControlHelp("A fresh pool keeps a clean, glossy edge: porous ground (concrete, soil, sand, wood...) takes up only a little of it at first, and more and more as the blood ages through clotting - the soaked rim around a pool appears in the middle stages, smoothly. Higher = it takes longer; 0 = full soaking at once. Snow, carpet and paper always drink blood at once.")
	f = Form(t, "How long it takes at these settings")
	local est = f:Help("")
	local estNext, estKey = 0, nil
	local estBase = est.Think
	function est:Think()
		if estBase then estBase(self) end
		if RealTime() < estNext then return end
		estNext = RealTime() + 0.5
		local txt = M.DryReport()
		if txt ~= estKey then estKey = txt self:SetText(txt) f:InvalidateLayout() end
	end

	t = Tab(sheet, "Splatter", "icon16/weather_rain.png")
	f = Form(t, "Style")
	f:Help("Pick a style, then fine-tune below (moving a slider makes it a custom style). Console: ghmpb_splatter_style <name>.")
	local sr = vgui.Create("DPanel", f)
	sr:SetTall(26)
	sr:SetPaintBackground(false)
	for _, st in ipairs(G.Wounds.STYLES) do
		local b = vgui.Create("DButton", sr)
		b:SetText(st.name)
		b:SetTooltip(st.tip)
		b:Dock(LEFT)
		b:DockMargin(0, 0, 6, 0)
		b:SetWide(84)
		b.DoClick = function() G.Wounds.ApplyStyle(st.id) end
	end
	f:AddItem(sr)
	local cur = f:Help("")
	local curBase = cur.Think
	function cur:Think()
		if curBase then curBase(self) end
		local id = G.cv.style:GetString()
		local st = G.Wounds.StyleById(id)
		local txt = "Current style: " .. (st and st.name or "Custom")
		if self:GetText() ~= txt then self:SetText(txt) end
	end
	f = Form(t, "Where blood comes from")
	Slider(f, "Entry wound back-spatter", "ghmpb_splat_entry", 0, 6, 2)
	Slider(f, "Exit wound spray", "ghmpb_splat_exit", 0, 6, 2)
	Slider(f, "Melee (blade arcs, blunt hits)", "ghmpb_splat_melee", 0, 6, 2)
	Slider(f, "Killing blow burst", "ghmpb_splat_kill", 0, 6, 2)
	Slider(f, "Ring of streaks round hits near the floor", "ghmpb_splat_radial", 0, 6, 2)
	Slider(f, "Explosions (burst thrown away from the blast)", "ghmpb_splat_blast", 0, 6, 2)
	Slider(f, "Arterial jets", "ghmpb_arterial_strength", 0, 6, 2)
	Check(f, "Blood fountain from fatal cuts (samurai films)", "ghmpb_geyser")
	Slider(f, "Wound size on the body", "ghmpb_splat_wound", 0, 5, 2)
	Slider(f, "Blood on your screen", "ghmpb_screen", 0, 2, 2)
	f:ControlHelp("Drops that fly into your view and the spatter of hits close in front of you land on the screen, in the blood's own colour (red, yellow, green...): big drops run down and leave a trail, and it dries and fades away. A lot of blood turns into a thick layer you cannot see through. 0 = off.")
	Slider(f, "Screen blood fades after (s)", "ghmpb_screen_fade", 3, 60, 0)
	Slider(f, "Screen blood blur", "ghmpb_screen_blur", 0, 3, 2)
	f:ControlHelp("How out of focus the blood on the screen looks. Your eye focuses past a drop sitting right on the lens, so the blood blurs softly while the world behind it stays sharp - stronger where the blood is thick. 0 = sharp, 1 = default.")
	Check(f, "Blood on my first-person hands and weapon", "ghmpb_vm_blood")
	Slider(f, "Hands / weapon blood wears off after (s, 0 = until I die)", "ghmpb_vm_fade", 0, 600, 0)
	f:ControlHelp("Close hits put blood on your hands and weapon too. 0 = it dries on them and stays until you die; otherwise it wears off after that many seconds. A weapon you switch away from loses its blood; your hands keep theirs.")
	Slider(f, "Bullet holes on bodies", "ghmpb_holes", 0, 2, 2)
	f:ControlHelp("Each round leaves an entry hole where it went in and, when it went through, a bigger, torn exit hole where it came out. The size is a multiplier; 0 = none. Needs the 1.26.10 shader pack. Off by itself while GHM FLESH is on: it draws its own wounds.")
	f = Form(t, "Droplets")
	Slider(f, "Amount (all sprays)", "ghmpb_spray", 0, 4, 2)
	Slider(f, "Size", "ghmpb_splat_size", 0.3, 3, 2)
	Slider(f, "Speed / throw distance", "ghmpb_splat_speed", 0.25, 3, 2)
	Slider(f, "Cone width", "ghmpb_splat_spread", 0.3, 3, 2)
	Check(f, "Blood mist on impacts (cloud + fine misting stains)", "ghmpb_mist")
	Check(f, "Cast-off from bloody weapons", "ghmpb_castoff")
	Check(f, "Drops skip and splash (ricochet streaks, secondary droplets)", "ghmpb_drop_bounce")
	Slider(f, "Longest drop stain (length / width)", "ghmpb_streak_max", 1.5, 10, 1)
	f:ControlHelp("Flat, fast hits leave longer stains, up to this many times as long as wide (3.5 = realistic; 10 = no limit, the long needle streaks of older versions).")
	Slider(f, "Fast drops skid on", "ghmpb_drop_slide", 0, 2, 2)
	f:ControlHelp("Part of a really fast, flat drop skids on a few cm as a droplet and ends in a small bead (on a wall it may run on down). 0 = off, 1 = short skids, 2 = long thin rivulets (the older look).")
	Slider(f, "Motion trail of flying drops", "ghmpb_drop_trail", 0, 2, 2)
	Check(f, "Hanging drops that swell before they fall", "ghmpb_drop_hang")
	f:ControlHelp("Bullets by ammunition (pistol / SMG, magnum, rifle, sniper, buckshot - from the damage type, the weapon's ammunition and the damage): pistol rounds and buckshot often stay in the torso, rifles, magnums and snipers go through. What goes through carries blood out of the exit wound onto the walls, floor and props behind the body - about 4 m for a pistol, 8 m for a rifle, 12 m for a sniper; the Exit wound spray slider scales it. Where it lands (and on the floor in front of the body) it leaves Crisis Response Blood splats: a few of its 36 splat decals, sized to the round, with one small wet stain in the middle that runs and dries. Every blood type gets them in its own colour: red blood the CRB decals as they are, yellow, green, zombie, synth and robot blood recoloured copies in the colour PhysBlood gives that blood. They land on the world and on props; bodies keep PhysBlood's own body blood. Off: PhysBlood's own wet drops in one of the CRB spatter patterns instead.")
	f:ControlHelp("Forensic model: gunshots throw fine back spatter towards the shooter and a narrow, faster, misty forward spatter from the exit; blows only spatter once blood is exposed and flick cast-off lines off the weapon; arterial jets pulse with the heart and weaken as blood is lost; coughed blood is fine and bubbly. Where drops land, the stain size, spines and satellites follow the impact speed, angle and surface (rough concrete splashes, glass and paint stay round, cloth wicks).")
	Check(f, "Fine gunshot spray from the Crisis Response Blood decals", "ghmpb_crb_decals")
	Check(f, "   gunshot spatter as Crisis Response splats instead of big drops", "ghmpb_crb_splats")
	f = Form(t, "Fluid bursts (VAT)")
	Check(f, "3D fluid-simulated blood bursts, streams & droplets", "ghmpb_vat")
	Check(f, "   also draw flying drops and drips as 3D meshes", "ghmpb_vat_drops")
	f:ControlHelp("On (default, the 1.26.2 look): every flying drop and hanging drip is a deforming 3D fluid mesh. Off: drawn by the blood shader, wet and lit like the pools.")
	Check(f, "Continuous 3D streams (arterial jets, gunshot spurts, pouring wounds)", "ghmpb_streams")
	Slider(f, "Spurts after a gunshot", "ghmpb_spurts", 0, 3, 2)
	f:ControlHelp("Streams: a jet or a pour is drawn as one stream of blood from the wound, falling and rippling until it breaks into drops (the drops do the stains and pools). Spurts: a bullet wound gushes one to five more times after the hit, a moment apart, along the bullet's path - it carries on on the ragdoll. 0 = no spurts.")
	Slider(f, "Burst size", "ghmpb_vat_size", 0.25, 3, 2)
	Slider(f, "Bursts on screen at once", "ghmpb_vat_max", 1, 80, 0)
	Slider(f, "Brightness (all bursts)", "ghmpb_vat_bright", 0.1, 4, 2)
	f:ControlHelp("The bursts, streams and 3D drops have the colour of the blood they come from, as the blood shaders draw it (the Look tab's colours, every blood type its own). The sliders below only adjust from there: 1 and 0 = the blood's own colour.")
	local TYPE_LABEL = { [0] = "Red (people)", "Yellow (antlions, aliens)", "Green", "Zombie", "Synth (Combine synths)", "Oil (robots, machines)",
		"Blue (NPC packs)", "Purple (NPC packs)" }
	for bt = 0, 7 do
		local n = G.VAT and G.VAT.TYPES and G.VAT.TYPES[bt] or ({ [0] = "red", "yellow", "green", "zombie", "synth", "robot", "blue", "purple" })[bt]
		local sw = vgui.Create("DPanel", f)
		sw:SetTall(18)
		function sw:Paint(w, h)
			local c = (G.VAT and G.VAT.PreviewColour) and G.VAT.PreviewColour(bt) or color_white
			draw.SimpleText(TYPE_LABEL[bt], "DermaDefaultBold", 0, h / 2, Color(30, 30, 30), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
			draw.RoundedBox(3, w - 64, 1, 60, h - 2, Color(20, 20, 20))
			draw.RoundedBox(3, w - 63, 2, 58, h - 4, c)
		end
		f:AddItem(sw)
		Slider(f, "   brightness", "ghmpb_vat_" .. n .. "_bright", 0.1, 4, 2)
		Slider(f, "   hue", "ghmpb_vat_" .. n .. "_hue", -1, 1, 2)
	end
	local rb = f:Button("Reset burst colours")
	rb.DoClick = function()
		local function Def(n) local c = GetConVar(n) if c then RunConsoleCommand(n, c:GetDefault()) end end
		Def("ghmpb_vat_bright")
		for _, n in ipairs({ "red", "yellow", "green", "zombie", "synth", "robot", "blue", "purple" }) do
			Def("ghmpb_vat_" .. n .. "_bright") Def("ghmpb_vat_" .. n .. "_hue")
		end
	end
	local vs = f:Help("")
	function vs:Think()
		if (self.nextT or 0) > RealTime() then return end
		self.nextT = RealTime() + 1
		local V = G.VAT
		if not V or not V.Installed() then self:SetText("The burst data is not installed.") return end
		local ready, total = 0, 0
		for _, e in pairs(V.effects) do total = total + 1 if e.state == "ready" then ready = ready + 1 end end
		self:SetText(string.format("Effects ready: %d of %d   |   bursts playing: %d   |   3D drops: %d", ready, total, #V.inst, V.stats and V.stats.drops3d or 0))
	end
	f:ControlHelp("Liquid sheets, ligaments and ribbons from fluid simulations, played as mesh particles on top of the drops: a burst thrown back from bullet entries, a long spray from exits and arterial jets, heavy bursts from blasts, thick splashes from blows, crowns where big drops hit the floor. They are only the look of the moment - the stains and pools still come from the drops. Off frees their video memory (about 60 MB when all are loaded).")
	f:ControlHelp("Colour: the bursts start from the blood colour of the Look tab (brightness, hue, density - for all blood); the sliders here change only the bursts, per blood type. Hue turns the colour up to 40 degrees: red goes towards orange (+) or crimson / purple (-), yellow towards green (+) or orange (-).")

	t = Tab(sheet, "Aftermath", "icon16/picture.png")
	f = Form(t, "Aftermath layer")
	f:Help("Blood that has stopped moving is baked into a cheap static layer. It stays visible (and keeps drying) without using simulation slots, so a scene can collect hundreds of stains. Fresh blood is simulated on top of it.")
	Check(f, "Keep settled blood in the aftermath layer", "ghmpb_aftermath")
	Check(f, "Keep the mess forever", "ghmpb_keep_forever")
	Slider(f, "Fade out after (minutes)", "ghmpb_aftermath_fade", 1, 600, 0)
	f:ControlHelp("Ignored while the mess is kept forever. Map cleanup and the caps below still remove old blood.")
	Slider(f, "Settle after (s without new blood)", "ghmpb_settle_time", 5, 600, 0)
	f:ControlHelp("For splatter. Pools stay wet and live until they have nearly clotted (90 % of the clotting time, at least half the drying time, Drying tab), because settled blood is drawn clotted and dull.")
	f = Form(t, "Limits")
	Slider(f, "Max aftermath world patches", "ghmpb_aftermath_max", 16, 4096, 0)
	Slider(f, "Max bodies keeping blood", "ghmpb_aftermath_bodies", 4, 256, 0)
	Combo(f, "Aftermath resolution", "ghmpb_aftermath_res", { { 128, "128 - lowest memory" }, { 256, "256 - default" }, { 512, "512 - sharpest" } })
	f:ControlHelp("Each aftermath world patch covers 76 x 76 cm and uses 64 KB (128), 256 KB (256) or 1 MB (512) of video memory.")
	f:Button("Remove old blood now", "ghmpb_clear_aftermath")

	t = Tab(sheet, "Bleeding", "icon16/heart.png")
	f = Form(t, "Amounts")
	Slider(f, "Bleeding amount", "ghmpb_bleed", 0, 5, 2)
	f = Form(t, "Effects")
	Check(f, "Nose / mouth / ear bleeding", "ghmpb_face_bleed")
	Check(f, "Arterial spurting", "ghmpb_arterial")
	Check(f, "Coughing blood (chest / neck wounds)", "ghmpb_cough")
	Check(f, "World pools and stains", "ghmpb_pools")
	Check(f, "Blood looks different on each surface", "ghmpb_material_look")
	f:ControlHelp("Snow drinks blood into a wide pink-red stain that sinks in, with sparkle around it; concrete, brick and plaster soak thin blood into a matte, darker stain with a damp halo; sand, gravel, grass and carpet break it up along their grain; ice and glass keep it glossy and wet longer. How fast each surface soaks blood up is always simulated.")
	Check(f, "Remove the engine's blood decals from bodies", "ghmpb_remove_engine_decals")
	f:ControlHelp("The engine paints its own blood splat decal on every body it shoots, even with its blood switched off. While the server replaces the engine's blood, these are removed from every body the mod bleeds.")
	f = Form(t, "Smearing")
	Check(f, "Bodies smear blood where they slide or are dragged", "ghmpb_smear")
	Slider(f, "Smear amount", "ghmpb_smear_amount", 0, 3, 2)
	Check(f, "Bodies moving through pools wipe them and pick blood up", "ghmpb_smear_pickup")
	f:ControlHelp("Drag trails, streaks where corpses slide or are thrown against walls, pools dragged out into smears. Blood picked up from a pool is carried on and smeared further.")
	f = Form(t, "Footprints")
	Check(f, "Bloody footprints", "ghmpb_footprints")
	Slider(f, "Footprint amount", "ghmpb_footprint_amount", 0, 3, 2)
	Check(f, "NPCs leave footprints too", "ghmpb_footprint_npcs")
	f:ControlHelp("Walking through wet blood (fresh or a pool that has not dried yet) soaks the soles: a trail of prints follows, solid and glossy at first, then broken up to the tread and fading out after several steps.")
	f = Form(t, "Hand prints")
	Check(f, "Bloody hands leave hand prints and finger streaks", "ghmpb_hand_prints")
	Slider(f, "Hand print amount", "ghmpb_hand_amount", 0, 3, 2)
	f:ControlHelp("NPCs, players, corpses and severed arms: a bloody hand that touches a floor or wall prints the palm, fingers and thumb (solid when soaked, only the pads as it dries); a hand dragged along leaves four finger streaks. Hands get bloody from wounds, from what runs down the arm, and from pools they touch.")
	f = Form(t, "Props and vehicles")
	Check(f, "Props soak up blood, smear it when dragged, splash when dropped in pools", "ghmpb_props")
	Slider(f, "Prop blood amount", "ghmpb_props_amount", 0, 3, 2)
	Check(f, "Tyre tracks and skid marks (HL2, simfphys, LVS, Glide)", "ghmpb_tyre_tracks")
	Slider(f, "Tyre track amount", "ghmpb_tyre_amount", 0, 3, 2)
	Slider(f, "Splashes (landing drops and streams; bodies, props, tyres hitting pools)", "ghmpb_splash", 0, 3, 2)
	f:ControlHelp("Where drops and streams land: the 3D splash crown (big drops, gushes, blood falling from about knee height or more) and the ring of satellite stains. 0 = none, higher = more and bigger.")
	f:ControlHelp("A crate or barrel standing in a pool gets a bloody underside (cardboard and cloth soak it up), smears it out when dragged and throws a crown of drops when dropped into a pool. Wheels rolling through blood print their tread for a few turns; drifting, braking or wheelspin smears it into skid marks.")
	f = Form(t, "GHM FLESH")
	Check(f, "Severed limbs bleed from the stump and keep their blood", "ghmpb_flesh")
	Slider(f, "Stump bleeding", "ghmpb_flesh_bleed", 0, 3, 2)
	f:ControlHelp("With GHM FLESH installed: a limb it cuts off leaves an arterial / venous bleeding stump, and the severed limb keeps the blood that was on it, drains from its cut end, smears and leaves hand prints.")
	f = Form(t, "Collisions")
	Slider(f, "Blood from physics impacts", "ghmpb_physics_blood", 0, 3, 2)
	Slider(f, "Cooldown per body (s)", "ghmpb_physics_cooldown", 0.1, 10, 1)
	f:ControlHelp("Stops piles of thrown, dropped or colliding bodies from spraying blood on every bump. Corpses bleed much less from collisions and never start new bleeding from them. 0 = no blood from collisions.")

	t = Tab(sheet, "Elements", "icon16/lightning.png")
	f = Form(t, "Elements")
	Check(f, "Blood reacts to fire, cold, electricity, lasers, acid, energy and blasts", "ghmpb_elements")
	f:ControlHelp("Fire boils the blood (bubbling, steaming, cooking brown), dries it to a crust and chars dried blood black, its embers glowing. Lasers and plasma boil a hot, hissing spot and spit tiny drops; a beam swept over a pool cuts a line. Acid mixes into the blood (yellow-green), dissolves dried blood and fizzes. The Combine energy ball vaporises the blood it rolls through and a dissolving body's blood flashes off in a red mist. Blasts, thumpers and the gravity gun's punt slosh pools and throw up drops. Radiation makes blood glow faintly.")
	Check(f, "Blood freezes on ice and snow, and in sub-zero weather", "ghmpb_freeze")
	f:ControlHelp("Frozen blood stops running and drying, turns glassy with a white hoarfrost bloom and glints, and is not picked up by feet. Weather needs StormFox 2 (its temperature). Fire thaws it again.")
	Check(f, "Steam and smoke", "ghmpb_elem_steam")
	f:ControlHelp("Fresh, warm blood steams in the cold for its first minute; boiling blood steams hard, charring blood smokes, acid gives off a green vapour. Also the dust clouds of explosions.")
	Check(f, "Flies come to pools of blood and to the dead", "ghmpb_flies")
	f:ControlHelp("Outdoors and in the warm, flies find blood within minutes (here: the first after ~20 s, the swarm grows over two minutes): they land on moist blood and on the wounds and faces of the dead - less on old dried crusts - crawl about, circle and land again, and scatter when someone walks up, a shot hits or a blast goes off. None in the cold (StormFox 2 below ~10 C, snow, ice) or under water, fewer indoors, at night or in rain.")
	Slider(f, "How many flies", "ghmpb_flies_amount", 0, 3, 2)
	Slider(f, "Most flies at once", "ghmpb_flies_max", 0, 400, 0)
	Check(f, "Their buzz", "ghmpb_flies_sound")
	Check(f, "Explosions kick up dust that sticks to fresh blood", "ghmpb_blast_dust")
	f:ControlHelp("A blast throws up what the ground is made of - sand, snow, soil, concrete or plaster dust, brick, splinters, grit - with the explosive's soot, and it settles around over a few seconds. Wet blood catches it in clumps, soaks it up and dries with it into a gritty crust; snow melts into the warm blood as pink slush. Thumpers shake up a little dust too.")
	f = Form(t, "Electricity (server)")
	SvCheck(f, "Elements on the server (wet blood conducts)", "ghmpb_sv_elements")
	SvSlider(f, "Shock damage to whoever stands in the blood", "ghmpb_sv_elec_damage", 0, 100, 0)
	SvSlider(f, "Reach through connected blood (units)", "ghmpb_sv_elec_range", 50, 2000, 0)
	SvSlider(f, "A pool stays wet for (s)", "ghmpb_sv_wet_time", 10, 1200, 0)
	f:ControlHelp("Sparks, zaps, stun sticks, rollermines, tesla coils and shock weapons near wet blood: the current runs through every pool connected to it (small gaps are jumped) and shocks every NPC and player standing in it - whoever made the spark too. Arcs crawl over the blood and it flashes blue-white. Frozen and boiled-dry blood does not conduct.")

	t = Tab(sheet, "Server", "icon16/server.png")
	f = Form(t, "Server (host / admin)")
	f:Help(M.CanSetServer() and "These are server settings: they apply to every player on the server."
		or "These are server settings. Only superadmins and the listen-server host can change them.")
	SvCheck(f, "Enable on the server", "ghmpb_sv_enable")
	SvCheck(f, "Replace the engine's NPC blood", "ghmpb_sv_suppress_default")
	SvCheck(f, "Players bleed", "ghmpb_sv_players")
	SvSlider(f, "Bleeding scale", "ghmpb_sv_bleed_scale", 0, 5, 2)
	f = Form(t, "Multiplayer (server)")
	SvCheck(f, "Players who arrive later see the blood left before", "ghmpb_sv_history")
	SvSlider(f, "Remember blood for (s)", "ghmpb_sv_history_time", 30, 7200, 0)
	SvSlider(f, "Hand it out within (units)", "ghmpb_sv_history_range", 500, 20000, 0)
	SvSlider(f, "Most records kept", "ghmpb_sv_history_max", 100, 20000, 0)
	f:ControlHelp("Every player who can see a hit or a death gets it as it happens. Players who could not - far away, behind walls, or joining later - get what it left (stains, spatter, pools, wounds on bodies) once they come near, painted as old blood.")
	f = Form(t, "Compatibility (server)")
	SvCheck(f, "Z-City: PhysBlood draws all of the blood (Z-City's off)", "ghmpb_sv_zcity")
	SvCheck(f, "Blood sees every hit (runs before other addons' damage hooks)", "ghmpb_sv_hook_priority")
	f:ControlHelp("Z-City switches the engine blood off on everyone and answers every damage event itself, which hid all hits from PhysBlood. With these on PhysBlood always runs alongside it, follows knocked-down players onto their ragdoll, and Z-City's own blood particles, decals and sprays are replaced by PhysBlood's.")
	f:ControlHelp("In multiplayer each player sees the blood in his own game, with the shaders or without (Lite), as he set it here. A player who switches PhysBlood off (the master switch) gets Z-City's own blood back, the server's blood effects included."
		.. ((type(G.LocalMode) == "function" and G.LocalMode()) and " This server does not run PhysBlood: it runs in your game only, made from Z-City's own hit messages (these server settings cannot be changed here)." or ""))
	f = Form(t, "Collision spam protection (server)")
	SvSlider(f, "Minimum physics damage", "ghmpb_sv_physics_min", 0, 200, 0)
	SvSlider(f, "Cooldown per body (s)", "ghmpb_sv_physics_cooldown", 0, 30, 1)
	SvSlider(f, "Max physics bleeds per second", "ghmpb_sv_physics_rate", 1, 200, 0)
	SvSlider(f, "Max blood hits per second (all)", "ghmpb_sv_hit_rate", 10, 1000, 0)

	t = Tab(sheet, "Presets", "icon16/page_save.png")
	PresetsTab(t)

	t = Tab(sheet, "Debug", "icon16/bug.png")
	f = Form(t, "Debug")
	Combo(f, "Overlay", "ghmpb_debug", { { 0, "Off" }, { 1, "Stats" }, { 2, "Stats + cell viewer (look at a model / floor)" }, { 3, "Stats + thickness colours" } })
	Combo(f, "Shading view", "ghmpb_debug_view", { { 0, "Normal" }, { 2, "Without reflections / highlights" }, { 3, "Reflections / highlights only" }, { 4, "Recovered light" } })
	f:Help("Test tools (single player / sandbox):")
	f:Button("Wound the model I look at", "ghmpb_test_wound", "40")
	f:Button("Pour 60 ml where I look", "ghmpb_test_pour", "60")
	f:Button("Spray", "ghmpb_test_spray", "40")
	f:Button("Print state to console", "ghmpb_dump")

	local want = M.lastTab
	if want and sheet.Items[want] then sheet:SetActiveTab(sheet.Items[want].Tab) end
	function sheet:OnActiveTabChanged(_, new)
		for i, it in ipairs(self.Items) do if it.Tab == new then M.lastTab = i end end
	end
	return frame
end

function M.Open()
	if IsValid(M.frame) then M.frame:MakePopup() M.frame:MoveToFront() return M.frame end
	local fr = vgui.Create("DFrame")
	fr:SetSize(math.min(640, ScrW() - 40), math.min(720, ScrH() - 40))
	fr:Center()
	M.Build(fr)
	fr:MakePopup()
	M.frame = fr
	return fr
end

concommand.Add("ghmpb_menu", function() M.Open() end, nil, "GHM PhysBlood: open the settings window")

list.Set("DesktopWindows", "GHMPhysBlood", {
	title = "PhysBlood",
	icon = ICON,
	width = 640,
	height = 720,
	onewindow = true,
	init = function(icon, window) M.Build(window) end,
})

hook.Add("PopulateToolMenu", "ghmpb_menu", function()
	spawnmenu.AddToolMenuOption("Options", "GHM PhysBlood", "ghmpb_client", "Settings", "", "", function(p)
		p:ClearControls()
		p:Help("Physically simulated blood: droplets, cell-simulated films on models and the world, pools that flow, clot and dry.")
		local b = p:Button("Open the settings window")
		b.DoClick = function() M.Open() end
		p:ControlHelp("Also: console ghmpb_menu, or hold C and click the PhysBlood icon.")
		p:CheckBox("Enable", "ghmpb_enable")
		p:NumSlider("Cell resolution (1-4)", "ghmpb_quality", 1, 4, 0)
		p:NumSlider("Edge smoothing (0-2)", "ghmpb_smooth", 0, 2, 0)
		p:CheckBox("Blood coagulates", "ghmpb_coagulation")
		p:CheckBox("Keep settled blood (aftermath layer)", "ghmpb_aftermath")
		p:CheckBox("Keep the mess forever", "ghmpb_keep_forever")
		p:Button("Remove all blood", "ghmpb_clear")
		p:Button("Remove old blood", "ghmpb_clear_aftermath")
	end)
	spawnmenu.AddToolMenuOption("Options", "GHM PhysBlood", "ghmpb_server", "Server", "", "", function(p)
		p:ClearControls()
		p:Help("Server settings (superadmins / listen server host).")
		SvCheck(p, "Enable", "ghmpb_sv_enable")
		SvCheck(p, "Replace the engine's NPC blood", "ghmpb_sv_suppress_default")
		SvCheck(p, "Players bleed", "ghmpb_sv_players")
		SvSlider(p, "Bleeding scale", "ghmpb_sv_bleed_scale", 0, 5, 2)
		SvCheck(p, "Players who arrive later see the blood left before", "ghmpb_sv_history")
		SvCheck(p, "Z-City: PhysBlood draws all of the blood", "ghmpb_sv_zcity")
	end)
end)

-- (1.26.8) Ultra is the default preset now and the automatic tuning is off, so a few seconds into a map players on Ultra
-- are told it can cost frame rate, with a button to the settings (GHM: "give a warning for ppl using the new update
-- starting a map, with preset set to ultra (FPS might suffer), wanna change that? click here to open menu").
-- "Open settings" and "Keep Ultra" answer it for this version; "Later" asks again at the next map. Waits for the shader
-- files window (8 s in), the settings window and the game menu, so only one window comes up at a time.
M.ULTRA_NOTE = "1.26.8"
local ultraSeen = CreateClientConVar("ghmpb_ultra_notice", "", true, false, "GHM PhysBlood: internal (the version whose Ultra preset notice was answered)")

function M.UltraNoticeDue()
	if not G.cv.enable:GetBool() then return false end
	if not G.cv.quality or G.cv.quality:GetInt() < 4 then return false end
	return ultraSeen:GetString() ~= M.ULTRA_NOTE
end

function M.UltraNotice()
	if IsValid(M.ultraFrame) then M.ultraFrame:Remove() end
	local fr = vgui.Create("DFrame")
	M.ultraFrame = fr
	fr:SetTitle("GHM PhysBlood - Ultra preset")
	if file.Exists("materials/" .. ICON, "GAME") then fr:SetIcon(ICON) end
	fr:SetSize(math.min(520, ScrW() - 40), 180)
	fr:Center()
	fr:MakePopup()
	local txt = vgui.Create("RichText", fr)
	txt:Dock(FILL)
	txt:DockMargin(4, 4, 4, 4)
	txt:InsertColorChange(235, 235, 235, 255)
	txt:AppendText("GHM PhysBlood is set to the Ultra preset: the best-looking blood, and it no longer turns the quality down by "
		.. "itself.\n\nFPS might suffer, most of all in big fights or on older graphics cards. Want to change that?")
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
	Btn("Open settings", function()
		ultraSeen:SetString(M.ULTRA_NOTE)
		fr:Close()
		M.lastTab = 1 -- the Quality tab (presets, adaptive quality)
		M.Open()
	end)
	Btn("Keep Ultra", function() ultraSeen:SetString(M.ULTRA_NOTE) fr:Close() end, true)
	Btn("Later", function() fr:Close() end, true)
	return fr
end

function M.UltraNoticeBusy()
	if G.ShaderCheck and IsValid(G.ShaderCheck.frame) then return true end
	if IsValid(M.frame) or IsValid(M.colourFrame) then return true end
	-- (1.26.10) the first-start colour choice goes first
	if M.ColourChoiceDue and M.ColourChoiceDue() then return true end
	return gui.IsGameUIVisible and gui.IsGameUIVisible() or false
end

hook.Add("InitPostEntity", "ghmpb_ultra_notice", function()
	local tries = 0
	local function Try()
		tries = tries + 1
		local ok, due = pcall(M.UltraNoticeDue)
		if not ok or not due then return end
		if M.UltraNoticeBusy() then
			if tries < 60 then timer.Simple(3, Try) end
			return
		end
		chat.AddText(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Quality: Ultra (FPS might suffer) - ghmpb_menu to change it.")
		pcall(M.UltraNotice)
	end
	timer.Simple(12, Try)
end)

-- (1.26.10) blood colours on the first start (GHM - GalaxyHighMarshal, the author: "make my current color blood settings default, give the players the
-- first option to choose their own color settings or pick mine on start up, and it must remember the settings picked, not
-- to annoy players by asking it everytime"). GHM's colours are the defaults; a few seconds into the first map each player
-- picks once: "Use GHM's colours" sets them (players who had other colours saved get them too), "Choose my own" keeps
-- what they have and opens the colour settings. Closing the window counts as keeping their own. The answer is saved with
-- the settings (ghmpb_colour_choice) and never asked again; ghmpb_colour_choose brings the window back. Waits for the
-- shader files window, the settings window and the game menu, as the Ultra notice does (which waits for this one).
M.GHM_COLOURS = {
	{ "ghmpb_color_fresh", "3" }, { "ghmpb_color_dry", "0.9" }, { "ghmpb_color_hue", "0" }, { "ghmpb_density", "3.53" },
	{ "ghmpb_color_custom", "1" }, { "ghmpb_color_blood", "255 10 0" }, { "ghmpb_color_dense", "171 9 0" },
}
local colourChoice = CreateClientConVar("ghmpb_colour_choice", "", true, false, "GHM PhysBlood: internal (blood colours picked on the first start: ghm / own)")

function M.ApplyGHMColours()
	for _, c in ipairs(M.GHM_COLOURS) do RunConsoleCommand(c[1], c[2]) end
end

function M.ColourChoiceDue()
	return G.cv.enable:GetBool() and colourChoice:GetString() == ""
end

local function Swatch(parent, label, rgb)
	local U = G.U
	local r, g, b = 200, 20, 10
	if U and U.ParseRGB then r, g, b = U.ParseRGB(rgb, rgb) end
	local p = vgui.Create("DPanel", parent)
	p:SetWide(150)
	p:Dock(LEFT)
	p:DockMargin(0, 0, 8, 0)
	function p:Paint(w, h)
		draw.SimpleText(label, "DermaDefault", 0, 0, Color(230, 230, 230))
		draw.RoundedBox(4, 0, 16, w, h - 16, Color(r, g, b))
	end
	return p
end

function M.ColourChoice()
	if IsValid(M.colourFrame) then M.colourFrame:Remove() end
	local fr = vgui.Create("DFrame")
	M.colourFrame = fr
	fr:SetTitle("GHM PhysBlood - blood colours")
	if file.Exists("materials/" .. ICON, "GAME") then fr:SetIcon(ICON) end
	fr:SetSize(math.min(540, ScrW() - 40), 250)
	fr:Center()
	fr:MakePopup()
	local answered = false
	local function Answer(v)
		answered = true
		colourChoice:SetString(v)
	end
	-- (closing the window keeps the player's own colours, and is remembered too)
	function fr:OnClose() if not answered then Answer("own") end end
	local txt = vgui.Create("RichText", fr)
	txt:Dock(TOP)
	txt:SetTall(62)
	txt:DockMargin(4, 4, 4, 0)
	txt:InsertColorChange(235, 235, 235, 255)
	txt:AppendText("Which blood colours do you want? You can use GHM's - the colours GHM PhysBlood comes with - or choose "
		.. "your own in the settings. You are only asked once; you can change the colours any time in the settings (Look tab).")
	function txt:PerformLayout() if self.SetFontInternal then self:SetFontInternal("DermaDefault") end end
	local sw = vgui.Create("DPanel", fr)
	sw:Dock(TOP)
	sw:SetTall(70)
	sw:DockMargin(4, 6, 4, 0)
	sw:SetPaintBackground(false)
	local yb, yd = "255 10 0", "171 9 0"
	for _, c in ipairs(M.GHM_COLOURS) do
		if c[1] == "ghmpb_color_blood" then yb = c[2] elseif c[1] == "ghmpb_color_dense" then yd = c[2] end
	end
	Swatch(sw, "GHM's: fresh, thin", yb)
	Swatch(sw, "GHM's: a deep pool", yd)
	local row = vgui.Create("DPanel", fr)
	row:Dock(BOTTOM)
	row:SetTall(30)
	row:DockMargin(0, 4, 0, 0)
	row:SetPaintBackground(false)
	local function Btn(text, fn, right)
		local b = vgui.Create("DButton", row)
		b:SetText(text)
		b:SizeToContentsX(24)
		b:Dock(right and RIGHT or LEFT)
		b:DockMargin(right and 6 or 0, 0, right and 0 or 6, 0)
		b.DoClick = fn
		return b
	end
	Btn("Use GHM's colours", function()
		Answer("ghm")
		M.ApplyGHMColours()
		fr:Close()
		chat.AddText(Color(255, 180, 80), "[GHM PhysBlood] ", color_white, "Blood colours: GHM's. Change them any time in ghmpb_menu (Look tab).")
	end)
	Btn("Choose my own", function()
		Answer("own")
		fr:Close()
		M.lastTab = 2 -- the Look tab (blood colour, your own blood colours)
		M.Open()
	end, true)
	return fr
end

concommand.Add("ghmpb_colour_choose", function() M.ColourChoice() end, nil, "GHM PhysBlood: choose the blood colours again (GHM's or your own)")

hook.Add("InitPostEntity", "ghmpb_colour_choice", function()
	local tries = 0
	local function Try()
		tries = tries + 1
		local ok, due = pcall(M.ColourChoiceDue)
		if not ok or not due then return end
		if (G.ShaderCheck and IsValid(G.ShaderCheck.frame)) or IsValid(M.frame) or IsValid(M.ultraFrame)
			or (gui.IsGameUIVisible and gui.IsGameUIVisible()) then
			if tries < 100 then timer.Simple(3, Try) end
			return
		end
		pcall(M.ColourChoice)
	end
	timer.Simple(10, Try)
end)
