local G = GHMPB
G.Gov = G.Gov or {}
local V = G.Gov
V.p = V.p or 0
local nextT = 0

local function BloodLoad()
	local P = G.Prof
	local live = P.cavg["bodies live"] or 0
	local steps = P.cavg["world patch steps"] or 0
	local drops = P.cavg["drops flying"] or 0
	return live >= 2 or steps >= 12 or drops >= 150
end

function V.Update()
	if G.Battle then G.Battle.Update() end
	local now = RealTime()
	if now < nextT then return end
	nextT = now + 0.5
	if not G.cv.perfadapt:GetBool() then V.p = 0 return end
	if V.force then V.p = V.force return end
	if system.HasFocus and not system.HasFocus() and not V.ignoreFocus then return end
	local target = 1000 / math.max(G.cv.perffps:GetFloat(), 10)
	local fm = GetConVar("fps_max")
	local cap = fm and fm:GetFloat() or 0
	if cap > 0 then target = math.max(target, 1000 / cap) end
	local ft = G.Prof.frame.avg
	local p = V.p
	local own = G.Prof.avg["=total"] or 0
	if ft > target * 1.08 and BloodLoad() and own > math.max(1.5, ft * 0.08) then
		p = p + math.Clamp((ft / target - 1) * 0.2, 0.03, 0.15)
	elseif ft < target * 0.85 then
		p = p - 0.04
	elseif ft <= target * 1.03 then
		-- (1.26.8) the frame meets the target: the pressure comes down. With the frame rate locked (fps_max, vsync) at the
		-- target the frame can't get 15 % faster than it, so the pressure only ever went up and stayed there: blood settled
		-- and dried three times sooner, the world simulation ran at half its rate and every detail level was cut, at a
		-- steady 60 fps (GHM: "the new version looks horrible", ghmpb_prof: pressure 0.5-1.0 at 59-60 fps)
		p = p - 0.06
	elseif not BloodLoad() then
		p = p - 0.02
	end
	V.p = math.Clamp(p, 0, 1)
end

-- (1.26.8) on Ultra the size of the fight cuts quality only as far as the frame is actually slow (the highest preset keeps
-- its best quality while the frame rate holds: GHM, "best quality with highest preset")
local function Bt()
	local b = G.Battle
	local lv = b and b.level or 0
	if lv > 0 and G.cv.quality and G.cv.quality:GetInt() >= 4 then lv = lv * math.min(1, (V.p or 0) * 4) end
	return lv
end
local function Pg(k) return math.max(V.p, Bt() * k) end
local function Pl(dist, seen)
	local b = Bt()
	if b <= 0 then return V.p end
	local w
	if seen and dist < 700 then w = 0 elseif seen and dist < 1600 then w = 0.55 else w = 1 end
	return math.max(V.p, b * w)
end
V.Pl = Pl
local function PosLoad(pos)
	if not pos then return V.p end
	local eye = EyePos()
	local dist = pos:Distance(eye)
	local seen = true
	if G.U.InViewPos then seen = G.U.InViewPos(pos, 24) end
	return Pl(dist, seen)
end
V.rbMs = V.rbMs or 0
-- (1.26.8) back to 1.26.7 (0.3-1.5 s): reading back brings the blood running off bodies and over the edges of walls and
-- floors, and the colour of the surfaces under new blood; read every 4-6 s these came in late, coarse steps
function V.ReadbackInterval()
	return math.Clamp(0.3 + 0.6 * Pg(0.3), V.rbMs * 0.05, 1.5)
end

function V.BodySimHz(hz, dist, seen, d)
	local p = Pl(dist, seen)
	if p <= 0 then return hz end
	local k = 1 - p * (dist > 700 and 0.75 or 0.45)
	if not seen then k = k * (1 - 0.5 * p) end
	return math.max(hz * k, 5)
end

function V.BodyForceHz(rate, dist, seen)
	local p = Pl(dist, seen)
	if p <= 0 then return rate end
	return math.max(rate * (1 - 0.6 * p), 0.5)
end

-- (1.26.8) back to 1.26.7: the longer steps of the fifth pass made the blood on walls and floors run in coarse steps
-- (GHM: "i want the bleeding physics on surfaces smoother")
function V.WorldStepMul() return 1 + 1.5 * Pg(0.4) end

function V.SettleMul(dist, seen)
	if dist then return 1 - 0.7 * Pl(dist, seen) end
	return 1 - 0.7 * Pg(0.4)
end

function V.LiveCap(cap) return math.max(math.min(cap, 6), math.floor(cap * (1 - 0.45 * Pg(0.8)) + 0.5)) end

function V.TraceMs() return 3 - 1.8 * V.p end

function V.BedMul() return 1 - 0.6 * Pg(0.6) end

function V.TickMul() return 1 + Pg(0.5) end

function V.EmitMul(pos) return (1 + 1.2 * PosLoad(pos)) * (G.Particles and G.Particles.Thin and G.Particles.Thin() or 1) end

-- (1.26.8) and in a big fight too (it followed the frame rate only)
function V.DropCap(cap) return math.max(200, math.floor(cap * (1 - 0.5 * math.max(V.p, Bt() * 0.6)))) end

function V.Pressed() return V.p > 0.1 or Bt() > 0.2 end

function V.WoundTickMul(ent)
	if V.p <= 0 and Bt() <= 0 then return 1 end
	local U = G.U
	local dist = IsValid(ent) and ent:GetPos():Distance(EyePos()) or 5000
	local seen = IsValid(ent) and U.InView(ent, 24)
	local p = Pl(dist, seen)
	if p <= 0 then return 1 end
	if dist < 700 and seen then return 1 + 0.6 * p end
	return 1 + 2 * p
end

function V.Describe()
	local s = string.format("adaptive quality: %s, target %d fps, pressure %.2f (readback every %.2f s, settle x%.2f, live bodies x%.2f)",
		G.cv.perfadapt:GetBool() and "on" or "off", G.cv.perffps:GetInt(), V.p, V.ReadbackInterval(), V.SettleMul(), 1 - 0.45 * Pg(0.8))
	if G.Battle then s = s .. " | " .. G.Battle.Describe() end
	return s
end

-- (1.26.8) a player: "the performance got way worse since the new update - I used to fight loads of NPCs on ultra with
-- barely any lag, now it gets unbearably laggy even with the settings on low". 1.26.7 brought back the 1.26.2 3D fluid
-- drops and splash crowns, added the continuous streams and the spurts after every gunshot, and the Lite pools: none of
-- them followed the quality setting, the frame rate or the size of the fight. How much of those costly parts there may
-- be now: 1 = all of it (Ultra, a quiet scene), less with a lower quality setting (Low 0.3, Medium 0.6, High 0.85) and
-- less the slower the frame (adaptive quality) and the bigger the fight round the player (down to a quarter).
-- Returns the detail and the load (0 = quiet, 1 = the frame is slow or a big battle).
local QK = { 0.3, 0.6, 0.85, 1 }
V.QK = QK
function V.Detail()
	local q = G.cv.quality and G.cv.quality:GetInt() or 2
	-- (1.26.8) the fight's size counts only as far as the frame is slow (the detail was cut by up to three quarters in
	-- every fight at a steady 60 fps)
	local load = math.max(V.p or 0, Bt() * math.min(1, (V.p or 0) * 4))
	return (QK[math.Clamp(q, 1, 4)] or 0.6) * (1 - 0.75 * load), load
end
