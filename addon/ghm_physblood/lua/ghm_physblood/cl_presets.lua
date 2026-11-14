-- GHM PhysBlood (1.26.10): settings presets - save, load, rename, duplicate and delete them, and share them as XML.
-- GHM: "add a settings import and export, rename ect make presets, xml in the mods menu. so that players can share their
-- settings/presets"
--   A preset is every client setting of PhysBlood (the ghmpb_ console variables a player sets in the menu - not the server's,
--   not the master switch, the debug views or the internal ones) written as a small XML file:
--     <?xml version="1.0" encoding="UTF-8"?>
--     <ghmpb_preset name="My preset" mod="GHM PhysBlood" version="1.26.10" saved="2026-11-09 20:30">
--       <setting name="ghmpb_quality" value="4"/>
--       ...
--     </ghmpb_preset>
--   Saved in garrysmod/data/ghm_physblood/presets/ (one .xml file each): players share the file, or the XML text itself
--   (copied to the clipboard and pasted into the import box of another player's menu). Importing reads only settings PhysBlood
--   knows (anything else in the text is ignored), and the game keeps every value in its range. Deleted presets are moved to
--   presets/trash/, not erased.
local G = GHMPB
G.Presets = G.Presets or {}
local P = G.Presets

P.DIR = "ghm_physblood/presets"
P.TRASH = "ghm_physblood/presets/trash"
P.BUILTIN = "GHM defaults"

-- settings made outside sh_config.lua's G.cv table
P.EXTRA = { "ghmpb_crb_decals", "ghmpb_crb_splats", "ghmpb_splat_mesh", "ghmpb_splats_kept", "ghmpb_streams", "ghmpb_spurts",
	"ghmpb_vat", "ghmpb_vat_size", "ghmpb_vat_max", "ghmpb_vat_drops", "ghmpb_vat_bright", "ghmpb_battle_lod" }
for _, n in ipairs({ "red", "yellow", "green", "zombie", "synth", "robot", "blue", "purple" }) do
	P.EXTRA[#P.EXTRA + 1] = "ghmpb_vat_" .. n .. "_bright"
	P.EXTRA[#P.EXTRA + 1] = "ghmpb_vat_" .. n .. "_hue"
end
-- never in a preset: the master switch, debug and test tools, internal state, and what depends on the player's own PC
P.SKIP = { ghmpb_enable = true, ghmpb_debug = true, ghmpb_debug_view = true, ghmpb_debug_hits = true, ghmpb_timelapse = true,
	ghmpb_config_version = true, ghmpb_ultra_notice = true, ghmpb_colour_choice = true, ghmpb_native = true,
	ghmpb_render_mode = true }

-- the settings a preset holds: name -> ConVar, and the names in order
function P.Settings()
	local map, names = {}, {}
	local function add(cv)
		if not cv or not cv.GetName then return end
		local n = cv:GetName()
		if map[n] or P.SKIP[n] or string.sub(n, 1, 6) ~= "ghmpb_" or string.sub(n, 1, 9) == "ghmpb_sv_" then return end
		map[n] = cv
		names[#names + 1] = n
	end
	for _, cv in pairs(G.cv or {}) do add(cv) end
	for _, n in ipairs(P.EXTRA) do add(GetConVar(n)) end
	table.sort(names)
	return map, names
end

-- ---------------------------------------------------------------- XML
local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }
local function Esc(s) return (string.gsub(tostring(s), "[&<>\"']", ESC)) end
local UNESC = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function Unesc(s)
	s = string.gsub(s, "&#(%d+);", function(d) local c = tonumber(d) return (c and c >= 32 and c < 127) and string.char(c) or "" end)
	return (string.gsub(s, "&(%a+);", function(e) return UNESC[e] or "" end))
end
P.Esc, P.Unesc = Esc, Unesc

local function Stamp() return os.date("%Y-%m-%d %H:%M") end

-- a preset as XML text: values = { name -> value string } (nil: the current settings)
function P.ToXML(name, values, saved)
	local map, names = P.Settings()
	local out = { '<?xml version="1.0" encoding="UTF-8"?>',
		string.format('<ghmpb_preset name="%s" mod="GHM PhysBlood" version="%s" saved="%s">', Esc(name or "Preset"),
			Esc(G.Version or "?"), Esc(saved or Stamp())) }
	for _, n in ipairs(names) do
		local v = values and values[n]
		if v == nil and not values then v = map[n]:GetString() end
		if v ~= nil then out[#out + 1] = string.format('  <setting name="%s" value="%s"/>', Esc(n), Esc(v)) end
	end
	out[#out + 1] = "</ghmpb_preset>"
	return table.concat(out, "\n")
end

local function Attr(tag, a)
	local v = string.match(tag, "[%s]" .. a .. '%s*=%s*"([^"]*)"') or string.match(tag, "[%s]" .. a .. "%s*=%s*'([^']*)'")
	return v and Unesc(v) or nil
end

-- XML text -> { name =, version =, saved =, values = { name -> value }, count =, skipped = } or nil, why
function P.FromXML(text)
	if type(text) ~= "string" or #text == 0 then return nil, "no text" end
	if #text > 200000 then return nil, "the text is too long for a preset" end
	local root = string.match(text, "<ghmpb_preset[^>]*>")
	if not root then return nil, "this is not a GHM PhysBlood preset (no <ghmpb_preset> in it)" end
	local map = P.Settings()
	local r = { name = Attr(root, "name") or "Imported preset", version = Attr(root, "version"), saved = Attr(root, "saved"),
		values = {}, count = 0, skipped = 0 }
	for tag in string.gmatch(text, "<setting[%s][^>]*>") do
		local n, v = Attr(tag, "name"), Attr(tag, "value")
		if n and v and map[n] and #v <= 64 and not string.find(v, "[%c;\"]") then
			if r.values[n] == nil then r.count = r.count + 1 end
			r.values[n] = v
		else
			r.skipped = r.skipped + 1
		end
	end
	if r.count == 0 then return nil, "no PhysBlood settings in it" end
	r.name = string.sub(string.gsub(r.name, "[%c]", ""), 1, 48)
	if r.name == "" then r.name = "Imported preset" end
	return r
end

-- ---------------------------------------------------------------- applying
-- sets the given values (only known settings); returns how many were changed
function P.Apply(values)
	local map = P.Settings()
	local n = 0
	for name, v in pairs(values or {}) do
		local cv = map[name]
		if cv and cv:GetString() ~= v then
			RunConsoleCommand(name, v)
			n = n + 1
		end
	end
	return n
end

function P.Defaults()
	local map, names = P.Settings()
	local t = {}
	for _, n in ipairs(names) do t[n] = map[n]:GetDefault() end
	return t
end

function P.Current()
	local map, names = P.Settings()
	local t = {}
	for _, n in ipairs(names) do t[n] = map[n]:GetString() end
	return t
end

-- ---------------------------------------------------------------- files
function P.FileName(name)
	local s = string.lower(name or "preset")
	s = string.gsub(s, "[^%w%-_ ]", "")
	s = string.gsub(s, "%s+", "_")
	s = string.sub(s, 1, 40)
	if s == "" then s = "preset" end
	return s
end

local function Path(file_) return P.DIR .. "/" .. file_ end

-- every saved preset: { { name, file, saved, count }, ... } sorted by name
function P.List()
	local out = {}
	if not file.Find then return out end
	local files = file.Find(P.DIR .. "/*.xml", "DATA") or {}
	for _, f in ipairs(files) do
		local txt = file.Read(Path(f), "DATA")
		local r = txt and P.FromXML(txt)
		if r then out[#out + 1] = { name = r.name, file = f, saved = r.saved or "", count = r.count, version = r.version } end
	end
	table.sort(out, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
	return out
end

function P.Find(name)
	for _, p in ipairs(P.List()) do if string.lower(p.name) == string.lower(name) then return p end end
	return nil
end

-- a file name not taken yet for this preset name
local function FreeFile(name, except)
	local base = P.FileName(name)
	local f = base .. ".xml"
	local i = 2
	while file.Exists(Path(f), "DATA") and f ~= except do
		f = base .. "_" .. i .. ".xml"
		i = i + 1
	end
	return f
end

-- saves values (nil: the current settings) as the preset called name (an existing one of that name is overwritten)
function P.Save(name, values)
	name = string.sub(string.gsub(name or "", "[%c]", ""), 1, 48)
	if name == "" then return false, "the preset needs a name" end
	if string.lower(name) == string.lower(P.BUILTIN) then return false, "that name is GHM's defaults - pick another" end
	file.CreateDir(P.DIR)
	local old = P.Find(name)
	local f = old and old.file or FreeFile(name)
	file.Write(Path(f), P.ToXML(name, values))
	if not file.Exists(Path(f), "DATA") then return false, "could not write garrysmod/data/" .. Path(f) end
	return true, f
end

function P.Load(name)
	if string.lower(name or "") == string.lower(P.BUILTIN) then return true, P.Apply(P.Defaults()) end
	local p = P.Find(name)
	if not p then return false, "no preset called " .. tostring(name) end
	local r, why = P.FromXML(file.Read(Path(p.file), "DATA") or "")
	if not r then return false, why end
	return true, P.Apply(r.values)
end

function P.Values(name)
	if string.lower(name or "") == string.lower(P.BUILTIN) then return P.Defaults() end
	local p = P.Find(name)
	local r = p and P.FromXML(file.Read(Path(p.file), "DATA") or "")
	return r and r.values or nil
end

function P.XMLOf(name)
	if string.lower(name or "") == string.lower(P.BUILTIN) then return P.ToXML(P.BUILTIN, P.Defaults()) end
	local p = P.Find(name)
	return p and file.Read(Path(p.file), "DATA") or nil
end

-- moves a preset file into presets/trash (kept, not erased)
local function ToTrash(f)
	file.CreateDir(P.TRASH)
	local dst = P.TRASH .. "/" .. string.gsub(f, "%.xml$", "") .. "_" .. os.date("%Y%m%d_%H%M%S") .. ".xml"
	if file.Rename and file.Rename(Path(f), dst) then return true end
	-- (an old game without file.Rename: a copy in the trash first, then the file goes)
	local txt = file.Read(Path(f), "DATA")
	if txt then file.Write(dst, txt) end
	if file.Exists(dst, "DATA") and file.Delete then file.Delete(Path(f)) end
	return not file.Exists(Path(f), "DATA")
end

function P.Delete(name)
	local p = P.Find(name)
	if not p then return false, "no preset called " .. tostring(name) end
	return ToTrash(p.file)
end

function P.Rename(name, newName)
	newName = string.sub(string.gsub(newName or "", "[%c]", ""), 1, 48)
	if newName == "" then return false, "the preset needs a name" end
	if string.lower(newName) == string.lower(P.BUILTIN) then return false, "that name is GHM's defaults - pick another" end
	local p = P.Find(name)
	if not p then return false, "no preset called " .. tostring(name) end
	local other = P.Find(newName)
	if other and other.file ~= p.file then return false, "there is a preset called " .. newName .. " already" end
	local r = P.FromXML(file.Read(Path(p.file), "DATA") or "")
	if not r then return false, "the preset file could not be read" end
	local f = FreeFile(newName, p.file)
	file.Write(Path(f), P.ToXML(newName, r.values, r.saved))
	if not file.Exists(Path(f), "DATA") then return false, "could not write garrysmod/data/" .. Path(f) end
	if f ~= p.file then ToTrash(p.file) end
	return true, f
end

function P.Duplicate(name, newName)
	local v = P.Values(name)
	if not v then return false, "no preset called " .. tostring(name) end
	newName = newName or (name .. " copy")
	if P.Find(newName) then return false, "there is a preset called " .. newName .. " already" end
	return P.Save(newName, v)
end

-- imports XML text as a preset (saved under its own name, or the given one); returns ok, name or why, the parsed preset
function P.Import(text, name)
	local r, why = P.FromXML(text)
	if not r then return false, why end
	name = name or r.name
	local ok, err = P.Save(name, r.values)
	if not ok then return false, err end
	return true, name, r
end

concommand.Add("ghmpb_preset_save", function(_, _, args, str)
	local ok, why = P.Save(str ~= "" and str or "Preset " .. os.date("%H%M%S"))
	print("[GHM PhysBlood] " .. (ok and ("preset saved: garrysmod/data/" .. P.DIR .. "/" .. why) or ("not saved: " .. tostring(why))))
end, nil, "GHM PhysBlood: save the current settings as a preset (argument: its name)")
concommand.Add("ghmpb_preset_load", function(_, _, args, str)
	local ok, why = P.Load(str)
	print("[GHM PhysBlood] " .. (ok and ("preset loaded: " .. tostring(why) .. " settings changed") or ("not loaded: " .. tostring(why))))
end, nil, "GHM PhysBlood: load a saved preset (argument: its name; \"GHM defaults\" for the defaults)")
concommand.Add("ghmpb_preset_list", function()
	print("[GHM PhysBlood] presets (garrysmod/data/" .. P.DIR .. "):")
	print("  " .. P.BUILTIN .. " (built in)")
	for _, p in ipairs(P.List()) do print(string.format("  %s  (%s, %d settings, saved %s)", p.name, p.file, p.count, p.saved)) end
end, nil, "GHM PhysBlood: list the saved presets")
