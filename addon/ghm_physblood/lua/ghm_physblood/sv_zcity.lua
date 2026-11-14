local G = GHMPB
local ZC = G.ZC

G.cv_sv_priority = CreateConVar("ghmpb_sv_hook_priority", "1", { FCVAR_ARCHIVE },
	"GHM PhysBlood: run the blood's damage hooks before other addons' (so an addon that answers damage events cannot hide hits from it)", 0, 1)

local PR = {}
G.Priority = PR
PR.mode = nil
PR.events = { EntityTakeDamage = "ghmpb_hit", PostEntityTakeDamage = "ghmpb_hit" }
PR.fn = G.HitHookFns or {}
PR.wrapped = PR.wrapped or setmetatable({}, { __mode = "k" })
local wrapped = PR.wrapped

local last = {}
local function Key(ent, dmg)
	if dmg == nil then return nil end
	local ok, k = pcall(function()
		local p = dmg:GetDamagePosition()
		return { ent, dmg, dmg:GetDamageType(), p.x, p.y, p.z, dmg:GetAttacker(), engine.TickCount() }
	end)
	return ok and k or nil
end
local function Same(a, b)
	if not a or not b then return false end
	for i = 1, 8 do if a[i] ~= b[i] then return false end end
	return true
end
local function RunOnce(event, ent, dmg, ...)
	local f = PR.fn[event]
	if not f then return end
	local k = Key(ent, dmg)
	if k and Same(last[event], k) then return end
	last[event] = k
	local ok, err = pcall(f, ent, dmg, ...)
	if not ok then ErrorNoHalt("[GHMPB] " .. event .. ": " .. tostring(err) .. "\n") end
end
PR.RunOnce = RunOnce
local ours = {}
local function Ours(event)
	ours[event] = ours[event] or function(...) RunOnce(event, ...) end
	return ours[event]
end

local function Unwrap()
	for event in pairs(PR.events) do
		local t = hook.GetTable()[event]
		if t then for k, f in pairs(t) do if wrapped[f] then t[k] = wrapped[f] end end end
	end
end

local function Plain()
	Unwrap()
	for event, id in pairs(PR.events) do
		local f = PR.fn[event]
		if f then hook.Remove(event, id) hook.Add(event, id, f) end
	end
	PR.mode = nil
end

local function Wrap()
	for event, id in pairs(PR.events) do
		if PR.fn[event] then
			local t = hook.GetTable()[event]
			if not t or t[id] ~= Ours(event) then hook.Add(event, id, Ours(event)) t = hook.GetTable()[event] end
			for k, f in pairs(t) do
				if k ~= id and isfunction(f) and not wrapped[f] then
					local own, byName = f, isstring(k)
					local w = function(...)
						if byName then RunOnce(event, ...) else RunOnce(event, select(2, ...)) end
						return own(...)
					end
					wrapped[w] = own
					t[k] = w
				end
			end
		end
	end
	PR.mode = "wrap"
end
PR.Wrap, PR.Unwrap = Wrap, Unwrap

function PR.Apply()
	if not G.cv_sv_priority:GetBool() then
		if PR.mode then Plain() end
		return
	end
	if isnumber(HOOK_MONITOR_HIGH) and ULib then
		if PR.mode ~= "ulib" then
			Unwrap()
			for event, id in pairs(PR.events) do
				local f = PR.fn[event]
				if f then hook.Remove(event, id) hook.Add(event, id, f, HOOK_MONITOR_HIGH) end
			end
			PR.mode = "ulib"
		end
		return
	end
	if PR.mode == "ulib" then Plain() end
	Wrap()
end

hook.Add("InitPostEntity", "ghmpb_priority", function() timer.Simple(0, PR.Apply) end)
timer.Create("ghmpb_priority", 1, 0, function()
	local ok, err = pcall(PR.Apply)
	if not ok then ErrorNoHalt("[GHMPB] hook priority: " .. tostring(err) .. "\n") end
end)
cvars.AddChangeCallback("ghmpb_sv_hook_priority", function() PR.Apply() end, "ghmpb")

hook.Add("Ragdoll_Create", "ghmpb_zcity", function(ply, rag)
	if not IsValid(ply) or not IsValid(rag) or not ply:IsPlayer() then return end
	if ply:GetNW2Int("ghmpb_blood", -2) == -2 and G.Setup then G.Setup(ply) end
	local bc = ply:GetNW2Int("ghmpb_blood", -2)
	if bc ~= -2 then rag:SetNW2Int("ghmpb_blood", bc) end
	rag.ghmpbHandled = true
	if G.Hist then G.Hist.OnCorpse(ply, rag) end
end)

function ZC.TookHit(ent)
	if not ZC.Active() or not IsValid(ent) then return nil end
	if ent:IsPlayer() and (IsValid(ent.FakeRagdoll) or IsValid(ent:GetNWEntity("FakeRagdoll"))) then return "redirected" end
	if ent.ghmpbZCHitT == CurTime() then return true end
	local org = ent.organism
	if istable(org) and org.lasthit == CurTime() and not org.godmode then return true end
	return nil
end

hook.Add("HomigradDamage", "ghmpb_zcity", function(ply, dmgInfo, hitgroup, ent, harm, hitBoxs, inputHole)
	if not ZC.Active() then return end
	local now = CurTime()
	if IsValid(ent) then ent.ghmpbZCHitT = now end
	if IsValid(ply) then ply.ghmpbZCHitT = now end
	local pos = istable(inputHole) and isvector(inputHole[1]) and not inputHole[1]:IsZero() and Vector(inputHole[1]) or nil
	if pos then
		local f = dmgInfo and dmgInfo:GetDamageForce()
		local dir = (f and f:LengthSqr() > 1) and f:GetNormalized() or nil
		local shot = { pos = pos, dir = dir, hg = hitgroup or 0, t = now }
		if IsValid(ent) then ent.ghmpbLastShot = shot end
		if IsValid(ply) then ply.ghmpbLastShot = shot end
	end
end)

local saved = {}
local function TakeOver()
	local active = ZC.Active()
	local t = hook.GetTable().PostEntityTakeDamage
	if active then
		if t and t.ResponsiveHits_PostEntityTakeDamage then
			saved.responsive = t.ResponsiveHits_PostEntityTakeDamage
			hook.Remove("PostEntityTakeDamage", "ResponsiveHits_PostEntityTakeDamage")
		end
	elseif saved.responsive then
		if not (t and t.ResponsiveHits_PostEntityTakeDamage) then hook.Add("PostEntityTakeDamage", "ResponsiveHits_PostEntityTakeDamage", saved.responsive) end
		saved.responsive = nil
	end
end
timer.Create("ghmpb_zcity_sv", 2, 0, function()
	local ok, err = pcall(TakeOver)
	if not ok then ErrorNoHalt("[GHMPB] Z-City: " .. tostring(err) .. "\n") end
end)
hook.Add("HomigradRun", "ghmpb_zcity", function()
	timer.Simple(0, function()
		pcall(PR.Apply)
		pcall(TakeOver)
	end)
end)
