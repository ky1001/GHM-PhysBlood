local G = GHMPB
G.ZC = G.ZC or {}
local ZC = G.ZC

G.cv_sv_zcity = CreateConVar("ghmpb_sv_zcity", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"GHM PhysBlood: with Z-City (Homigrad) loaded, PhysBlood draws all of the blood and Z-City's own blood effects are switched off", 0, 1)

local presentT, present = 0, false
function ZC.Present()
	local now = RealTime()
	if now < presentT then return present end
	presentT = now + 1
	local hg = rawget(_G, "hg")
	present = istable(hg) and (istable(hg.organism) or isfunction(hg.GetCurrentCharacter) or isfunction(hg.addBloodPart)
		or isfunction(hg.Fake) or isfunction(hg.RagdollOwner)) or false
	return present
end

function ZC.Active()
	return G.cv_sv_zcity:GetBool() and G.cv_sv_enable:GetBool() and ZC.Present()
end

-- (1.26.8) GHM: "if someone uses this mod it overwrites the Z-City multiplayer blood for the player, with or without
-- shaders, and they see it locally in their own game". Does the server run PhysBlood too? When it does not (a server
-- that lets players run their own client Lua, sv_allowcslua 1 - GMod runs a player's addon Lua on a server only when the
-- server has the addon or allows that), this client works alone: its replicated server settings keep their defaults,
-- it sends the server nothing, and Z-City's own hit messages make the hits (cl_zcity ZC.LocalHit).
local srvT, srv = 0, true
function G.ServerRuns()
	if SERVER or game.SinglePlayer() then return true end
	local now = RealTime()
	if now < srvT then return srv end
	srvT = now + 2
	srv = not util.NetworkStringToID or util.NetworkStringToID("ghmpb_hit") ~= 0
	return srv
end
function G.LocalMode() return CLIENT and not G.ServerRuns() end

function ZC.Character(p)
	if not IsValid(p) or not p:IsPlayer() then return p end
	local fake = p:GetNWEntity("FakeRagdoll")
	if p:Alive() then return IsValid(fake) and fake or p end
	local dead = p:GetNWEntity("RagdollDeath")
	if IsValid(dead) then return dead end
	if IsValid(fake) then return fake end
	return p
end

function ZC.LivingOwner(rag)
	if not IsValid(rag) or rag:IsPlayer() or not rag:IsRagdoll() then return nil end
	local p = rag:GetNWEntity("ply")
	if IsValid(p) and p:IsPlayer() and p:Alive() and p:GetNWEntity("FakeRagdoll") == rag and p:GetNWEntity("RagdollDeath") ~= rag then
		return p
	end
	return nil
end

function G.LivingRagdoll(ent)
	if IsValid(ent) and ent:GetNW2Bool("ghmpb_alive", false) then return true end
	if not ZC.Active() then return false end
	return ZC.LivingOwner(ent) ~= nil
end

ZC.stats = ZC.stats or { decals = 0, effects = 0, relayed = 0 }
local function ShouldBlock()
	if not ZC.Active() then return false end
	if CLIENT and G.cv and G.cv.enable and not G.cv.enable:GetBool() then return false end
	return true
end
-- (1.26.8) on the server: the players who switched PhysBlood off (ghmpb_enable 0) still get Z-City's blood effects and
-- decals the server makes; the others see PhysBlood's blood in their own game
if SERVER then util.AddNetworkString("ghmpb_zcdecal") end
local offT, offRF = 0, nil
local function OffPlayers()
	local now = CurTime()
	if now < offT then return offRF end
	offT = now + 0.5
	offRF = nil
	for _, p in ipairs(player.GetHumans and player.GetHumans() or player.GetAll()) do
		if IsValid(p) and p.GetInfoNum and p:GetInfoNum("ghmpb_enable", 1) == 0 then
			offRF = offRF or RecipientFilter()
			offRF:AddPlayer(p)
		end
	end
	return offRF
end
ZC.OffPlayers = OffPlayers
if not ZC.wrapped then
	ZC.wrapped = true
	local decal, effect = util.Decal, util.Effect
	ZC.origDecal, ZC.origEffect = decal, effect
	util.Decal = function(name, a, b, f, ...)
		if (ZC.block or ShouldBlock()) and isstring(name) and string.find(string.lower(name), "blood", 1, true) then
			ZC.stats.decals = ZC.stats.decals + 1
			local rf = SERVER and isvector(a) and isvector(b) and OffPlayers()
			if rf then
				net.Start("ghmpb_zcdecal", true)
				net.WriteString(name)
				net.WriteVector(a)
				net.WriteVector(b)
				net.WriteEntity(isentity(f) and IsValid(f) and f or NULL)
				net.Send(rf)
				ZC.stats.relayed = ZC.stats.relayed + 1
			end
			return
		end
		return decal(name, a, b, f, ...)
	end
	util.Effect = function(name, data, ...)
		if ZC.block or ShouldBlock() then
			local blood = name == "BloodImpact" or name == "RagdollImpact" or name == "bloodspray"
			if not blood and name == "Impact" and data and isfunction(data.GetEntity) then
				local ok, e = pcall(data.GetEntity, data)
				blood = ok and IsValid(e) and (e:IsPlayer() or e:IsRagdoll() or e:IsNPC()) or false
			end
			if blood then
				ZC.stats.effects = ZC.stats.effects + 1
				local rf = SERVER and OffPlayers()
				if rf then
					ZC.stats.relayed = ZC.stats.relayed + 1
					return effect(name, data, true, rf)
				end
				return
			end
		end
		return effect(name, data, ...)
	end
end
if CLIENT then
	net.Receive("ghmpb_zcdecal", function()
		local name, a, b, f = net.ReadString(), net.ReadVector(), net.ReadVector(), net.ReadEntity()
		if G.cv and G.cv.enable and G.cv.enable:GetBool() then return end
		if ZC.origDecal then ZC.origDecal(name, a, b, IsValid(f) and f or nil) end
	end)
end

ZC.block = false
timer.Create("ghmpb_zcity_block", 1, 0, function()
	ZC.block = ShouldBlock()
end)
