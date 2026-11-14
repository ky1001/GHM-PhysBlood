local G = GHMPB

util.AddNetworkString("ghmpb_svset")

G.cv_sv_wsid = CreateConVar("ghmpb_sv_workshop_id", "", { FCVAR_ARCHIVE },
	"GHM PhysBlood: Workshop item that joining players download the addon's content from (empty = found by itself)")
G.cv_sv_fastdl = CreateConVar("ghmpb_sv_fastdl", "1", { FCVAR_ARCHIVE },
	"GHM PhysBlood: without a Workshop item, send the addon's shaders, materials and models through the server's own downloads", 0, 1)

local function FindWorkshopId()
	local id = string.Trim(G.cv_sv_wsid:GetString() or "")
	if id ~= "" then return id end
	for _, a in ipairs(engine.GetAddons() or {}) do
		local title = string.lower(a.title or "")
		if a.mounted and a.wsid and tostring(a.wsid) ~= "0" and string.find(title, "physblood", 1, true) then return tostring(a.wsid) end
	end
	return nil
end

local function AddDir(dir, pattern, n)
	local files, dirs = file.Find(dir .. "*", "GAME")
	for _, f in ipairs(files or {}) do
		if string.match(f, pattern) then resource.AddFile(dir .. f) n = n + 1 end
	end
	for _, d in ipairs(dirs or {}) do n = AddDir(dir .. d .. "/", pattern, n) end
	return n
end

local function Content()
	if game.SinglePlayer() then return end
	local id = FindWorkshopId()
	if id and string.match(id, "^%d+$") then
		resource.AddWorkshop(id)
		MsgC(Color(120, 200, 255), "[GHM PhysBlood] ", color_white, "joining players download the content from Workshop item " .. id .. "\n")
		return
	end
	if not G.cv_sv_fastdl:GetBool() then
		MsgC(Color(255, 160, 80), "[GHM PhysBlood] ", color_white, "no Workshop item and ghmpb_sv_fastdl 0: players need the addon installed themselves\n")
		return
	end
	local n = 0
	n = AddDir("shaders/fxc/", "^ghmpb.*%.vcs$", n)
	for _, d in ipairs({ "materials/ghmpb/", "materials/ghm_physblood/", "materials/models/ghmpb/" }) do
		n = AddDir(d, "%.vmt$", n)
		n = AddDir(d, "%.vtf$", n)
		n = AddDir(d, "%.png$", n)
	end
	n = AddDir("models/ghmpb/", "%.mdl$", n)
	MsgC(Color(120, 200, 255), "[GHM PhysBlood] ", color_white, "no Workshop item found: " .. n .. " content files are sent through the server's downloads (set ghmpb_sv_workshop_id to use the Workshop)\n")
end
Content()

G.SV_SETTABLE = {
	ghmpb_sv_enable = true, ghmpb_sv_suppress_default = true, ghmpb_sv_players = true, ghmpb_sv_bleed_scale = true,
	ghmpb_sv_physics_min = true, ghmpb_sv_physics_cooldown = true, ghmpb_sv_physics_rate = true, ghmpb_sv_hit_rate = true,
	ghmpb_sv_zcity = true, ghmpb_sv_hook_priority = true, ghmpb_sv_history = true, ghmpb_sv_history_time = true,
	ghmpb_sv_history_max = true, ghmpb_sv_history_range = true,
	ghmpb_sv_elements = true, ghmpb_sv_elec_damage = true, ghmpb_sv_elec_range = true, ghmpb_sv_wet_time = true,
}
net.Receive("ghmpb_svset", function(_, ply)
	if not IsValid(ply) or not (ply:IsSuperAdmin() or ply:IsListenServerHost()) then return end
	local now = CurTime()
	if (ply.ghmpbSetT or 0) > now then return end
	ply.ghmpbSetT = now + 0.05
	local name, value = net.ReadString(), net.ReadString()
	if not G.SV_SETTABLE[name] or not GetConVar(name) then return end
	if not string.match(value, "^%-?[%d%.]+$") then return end
	RunConsoleCommand(name, value)
	MsgC(Color(120, 200, 255), "[GHM PhysBlood] ", color_white, ply:Nick() .. " set " .. name .. " " .. value .. "\n")
end)
