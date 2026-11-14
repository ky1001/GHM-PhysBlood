local G = GHMPB
G.Battle = G.Battle or {}
local B = G.Battle

-- (1.26.8) off by default (the best blood out of the box; players turn it on in the settings): players still at the old
-- default get it off once (sh_config.lua, settings step 1270)
G.cv.battle = CreateClientConVar("ghmpb_battle_lod", "0", true, false,
	"Large battles: the more NPCs fight and bleed around you, the less detail far-away and out-of-view blood gets (near blood keeps it)", 0, 1)
if G.migrate1270 and G.cv.battle:GetInt() == 1 then G.cv.battle:SetInt(0) end

B.level = B.level or 0
B.combatants, B.hps, B.bleeders = 0, 0, 0
local hits = {}
local hitN = 0

function B.OnHit()
	hitN = hitN % 256 + 1
	hits[hitN] = RealTime()
end

local function HitsPerSecond(now)
	local n = 0
	for i = 1, #hits do if now - hits[i] < 3 then n = n + 1 end end
	return n / 3
end

local RANGE2 = 4000 * 4000
local function Combatants(eye)
	local n = 0
	local function count(e)
		if IsValid(e) and not e:IsDormant() and e:GetPos():DistToSqr(eye) < RANGE2 then
			local alive = e:IsPlayer() and e:Alive() or (not e:IsPlayer() and (e:Health() or 1) > 0)
			if alive and G.BloodTypeOf(e) ~= nil then n = n + 1 end
		end
	end
	for _, e in ipairs(ents.FindByClass("npc_*")) do count(e) end
	for _, e in ipairs(player.GetAll()) do count(e) end
	return n
end

local function Bleeding()
	local n = 0
	for ent, b in pairs(G.Wounds.bodies) do
		if IsValid(ent) and #b.emitters > 0 then n = n + 1 end
	end
	return n
end

local nextT = 0
function B.Update()
	local now = RealTime()
	if now < nextT then return end
	nextT = now + 0.5
	if not G.cv.battle:GetBool() then B.level = 0 return end
	local eye = EyePos()
	B.combatants = Combatants(eye)
	B.hps = HitsPerSecond(now)
	B.bleeders = Bleeding()
	local want = math.max((B.combatants - 12) / 28, (B.hps - 6) / 34, (B.bleeders - 8) / 24)
	want = math.Clamp(want, 0, 1)
	if want > B.level then B.level = math.min(want, B.level + 0.5)
	else B.level = math.max(want, B.level - 0.05) end
end

function B.Level() return B.level end

function B.Describe()
	return string.format("battle size: %s, level %.2f (%d combatants near, %.1f hits/s, %d bodies bleeding)",
		G.cv.battle:GetBool() and "on" or "off", B.level, B.combatants, B.hps, B.bleeders)
end
