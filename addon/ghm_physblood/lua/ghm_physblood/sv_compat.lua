local G = GHMPB
G.Compat = G.Compat or {}
local C = G.Compat

-- (1.26.10c) every colour VJ Base has: Blue, Purple, White and Oil were left out (those NPCs did not bleed with PhysBlood and
-- kept their own particles). Codes -10 - type are PhysBlood's own types (G.BloodTypeOf): White = synth (milky), Oil = robot
-- (black), Blue and Purple their own
local VJ_MAP = { Red = BLOOD_COLOR_RED, Yellow = BLOOD_COLOR_YELLOW, Green = BLOOD_COLOR_GREEN, Orange = BLOOD_COLOR_YELLOW,
	Blue = -16, Purple = -17, White = -14, Oil = -15 }
local DECAL_MAP = { { "blue", -16 }, { "purple", -17 }, { "violet", -17 }, { "white", -14 }, { "oil", -15 }, { "black", -15 },
	{ "zombie", BLOOD_COLOR_ZOMBIE or 5 }, { "red", BLOOD_COLOR_RED }, { "yellow", BLOOD_COLOR_YELLOW },
	{ "antlion", BLOOD_COLOR_YELLOW }, { "green", BLOOD_COLOR_GREEN }, { "alien", BLOOD_COLOR_GREEN } }

function C.BaseOf(ent)
	if not IsValid(ent) then return nil end
	if ent.IsVJBaseSNPC then return "vj" end
	if ent.IsZBaseNPC then return "zbase" end
	if ent.IsDrGNextbot then return "drg" end
	return nil
end

function C.BloodCode(ent)
	local base = C.BaseOf(ent)
	if base == "vj" then
		if ent.Bleeds == false then return DONT_BLEED, false end
		local bc = ent.BloodColor
		if isstring(bc) then
			local m = VJ_MAP[bc]
			if m then return m, true end
			return DONT_BLEED, false
		end
		return nil, false
	elseif base == "zbase" then
		local own = (ent.CustomBloodParticles or ent.CustomBloodDecals) and true or false
		local c = ent:GetBloodColor()
		if ent.ghmpbSuppressed and c == DONT_BLEED then c = ent.ghmpbOrigBlood or c end
		if c ~= DONT_BLEED and c ~= BLOOD_COLOR_MECH then return c, own end
		local dec = ent.CustomBloodDecals
		if isstring(dec) then
			local low = string.lower(dec)
			for _, m in ipairs(DECAL_MAP) do
				if string.find(low, m[1], 1, true) then return m[2], true end
			end
		end
		return DONT_BLEED, false
	end
	return nil, false
end

function C.SuppressOwn(ent, on)
	local base = C.BaseOf(ent)
	if base == "vj" then
		if on and not ent.ghmpbOwnSaved then
			ent.ghmpbOwnSaved = { ent.HasBloodParticle, ent.HasBloodDecal, ent.HasBloodPool }
			ent.HasBloodParticle, ent.HasBloodDecal, ent.HasBloodPool = false, false, false
		elseif not on and ent.ghmpbOwnSaved then
			local s = ent.ghmpbOwnSaved
			ent.HasBloodParticle, ent.HasBloodDecal, ent.HasBloodPool = s[1], s[2], s[3]
			ent.ghmpbOwnSaved = nil
		end
	elseif base == "zbase" then
		if on and not ent.ghmpbOwnSaved then
			ent.ghmpbOwnSaved = { ent.CustomBloodParticles, ent.CustomBloodDecals }
			ent.CustomBloodParticles, ent.CustomBloodDecals = false, false
		elseif not on and ent.ghmpbOwnSaved then
			ent.CustomBloodParticles, ent.CustomBloodDecals = ent.ghmpbOwnSaved[1], ent.ghmpbOwnSaved[2]
			ent.ghmpbOwnSaved = nil
		end
	end
end

C.dying = C.dying or {}
function C.RememberDying(ent)
	if not IsValid(ent) then return end
	for _, r in ipairs(C.dying) do if r.ent == ent then r.pos, r.t = ent:GetPos(), CurTime() return end end
	table.insert(C.dying, { ent = ent, idx = ent:EntIndex(), mdl = ent:GetModel(), pos = ent:GetPos(), t = CurTime(),
		bc = ent:GetNW2Int("ghmpb_blood", -2) })
	if #C.dying > 32 then table.remove(C.dying, 1) end
end

function C.MatchCorpse(rag)
	if not IsValid(rag) or rag.ghmpbHandled then return nil end
	local now, mdl, p = CurTime(), rag:GetModel(), rag:GetPos()
	local best, bd
	for i = #C.dying, 1, -1 do
		local r = C.dying[i]
		if now - r.t > 4 then
			table.remove(C.dying, i)
		elseif not r.used and r.mdl == mdl then
			local d = r.pos:DistToSqr(p)
			if d < 96 * 96 and (not bd or d < bd) then best, bd = r, d end
		end
	end
	if best then best.used = true end
	return best
end

local marked = {}
timer.Create("ghmpb_activeragdolls", 0.5, 0, function()
	local EU = rawget(_G, "GHM_EU")
	local chars = EU and EU.Chars
	local ENDO = rawget(_G, "ENDO")
	local bodies = ENDO and ENDO.Bodies
	local alive = {}
	if istable(chars) then
		for rag, ch in pairs(chars) do
			if IsValid(rag) and istable(ch) and ch.mode == "alive" then
				alive[rag] = true
				if not marked[rag] then
					rag:SetNW2Bool("ghmpb_alive", true)
					marked[rag] = true
				end
			end
		end
	end
	if istable(bodies) then
		for rag, b in pairs(bodies) do
			if IsValid(rag) and istable(b) and b.state ~= "dead" then
				alive[rag] = true
				if not marked[rag] then
					rag:SetNW2Bool("ghmpb_alive", true)
					marked[rag] = true
				end
			end
		end
	end
	for rag in pairs(marked) do
		if not alive[rag] then
			if IsValid(rag) then rag:SetNW2Bool("ghmpb_alive", false) end
			marked[rag] = nil
		end
	end
end)
