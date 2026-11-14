-- GHM PhysBlood (1.26.10): blood on your screen, on your first-person hands and weapon.
-- GHM: "make an optional blood on screen with physics ... and it fading, if blood splattering, droplets ect hits the player
-- cam, thicker and non see through if alot of blood hits the player view, even add blood splattering on nearby npcs and
-- players body and C hands viewmodel" - on by default, any blood colour (yellow / green / zombie / synth / robot, and NPC
-- bases' blood as PhysBlood reads it), close hits and drops that fly into the camera.
--   Drops that would reach the camera (worked out when they are thrown: P.Spawn) and the spatter of hits close in front of you
--   (W.OnHit) land on the screen where they came from: a drop, or for a close hit a lobed splat with drops thrown round it.
--   On the screen the blood is a liquid: big drops run down and leave a streak, drops that meet run together, and it dries
--   (goes darker and dull) and fades away over ghmpb_screen_fade seconds.
--   Drawn as a liquid film on the lens (screen_ps30, with the 1.26.10 shader pack): each drop's thickness is added to the
--   blood kept in a half-size float target, where it runs on the GPU the way NVIDIA's HLSL Blood Shader ("Gravity Maps",
--   SDK 9.5) moves blood (see DrawShader), then one pass over the frame shows what is behind the blood through it - tinted by its colour in
--   proportion to its thickness (a thin smear is a red veil, a thick layer of it you cannot see through), bent and blurred
--   by its surface, the steep edges of the drops dark - with the blood's own deep colour and, while it is wet, highlights.
--   Without that shader (older shader pack, DirectX 11): a cheap stand-in - the same drops moved on the CPU and drawn in three
--   passes with the game's own shaders.
--   The same close hits put blood on your first-person hands and weapon (they are bodies like any other for the blood
--   simulation, drawn in the view model pass: cl_entities.lua E.DrawViewModel); it stays until you die, or wears off after
--   ghmpb_vm_fade seconds.
local G = GHMPB
G.Screen = G.Screen or {}
local S = G.Screen
local U = G.U

S.drops = S.drops or {}
S.MAX = 320
S.stats = S.stats or { hits = 0, splats = 0, drops = 0, merged = 0, vm = 0, vmStamps = 0 }

local MATS
local function Mats()
	if MATS then return MATS end
	MATS = {
		drop = { Material("ghm_physblood/screen_drop1.png", "smooth"), Material("ghm_physblood/screen_drop2.png", "smooth"),
			Material("ghm_physblood/screen_drop3.png", "smooth") },
		splat = Material("ghm_physblood/screen_splat.png", "smooth"),
		spec = Material("ghm_physblood/screen_spec.png", "smooth"),
	}
	return MATS
end

function S.Amount() local c = G.cv.screen return c and c:GetFloat() or 1 end
function S.On() return G.cv.enable:GetBool() and S.Amount() > 0 end
local function FadeTime() local c = G.cv.screenfade return c and math.Clamp(c:GetFloat(), 3, 60) or 14 end

-- the liquid-film shader (1.26.10 shader pack, DirectX 9)
function S.ShaderOK()
	if S.shaderOK == nil then
		local GPU = G.GPU
		if not GPU or not GPU.Shader or not GPU.Mat then S.shaderOK = false return false end
		local rel = "shaders/fxc/" .. GPU.Shader("screen_ps30") .. ".vcs"
		S.shaderOK = (file.Exists(rel, "GAME") or file.Exists("garrysmod/" .. rel, "BASE_PATH")) and true or false
	end
	return S.shaderOK
end

-- the colours of a blood type on the screen: its absorbance per mm of thickness (r, g, b) and its body (sRGB 0..255)
local colCache, colKey = {}, nil
local function Colours(btype, oxy)
	local key = tostring(G.cv.colHue and G.cv.colHue:GetFloat()) .. "|" .. tostring(G.cv.absorb and G.cv.absorb:GetFloat()) .. "|"
		.. tostring(G.cv.colFresh and G.cv.colFresh:GetFloat()) .. "|" .. tostring(G.cv.colBlood and G.cv.colBlood:GetString())
		.. "|" .. tostring(G.cv.colCustom and G.cv.colCustom:GetString()) .. "|" .. tostring(G.cv.colDense and G.cv.colDense:GetString())
		.. "|" .. tostring(U.ShaderColours and U.ShaderColours())
	if key ~= colKey then colCache, colKey = {}, key end
	local k = (btype or 0) * 100 + math.floor(math.Clamp(oxy or 0.75, 0, 1) * 10 + 0.5)
	local c = colCache[k]
	if c then return c end
	local tr, tg, tb = 0.75, 0.25, 0.2
	if U.BloodTrans then
		local r, g, b = U.BloodTrans(btype or 0, oxy or 0.75, 0.06)
		tr, tg, tb = math.Clamp(r / 1.07, 1e-4, 0.999), math.Clamp(g / 0.912, 1e-4, 0.999), math.Clamp(b / 0.896, 1e-4, 0.999)
	end
	local dr, dg, db = 120, 8, 4
	if U.BloodDense then dr, dg, db = U.BloodDense(btype or 0, oxy or 0.75, 150) end
	-- absorbance of 1 mm (Beer-Lambert: what 0.06 mm lets through, scaled)
	local ka, kb, kc = -math.log(tr) / 0.06, -math.log(tg) / 0.06, -math.log(tb) / 0.06
	-- (1.26.10c) GHM: "each particle is matching the color of the blood emitted" - the liquid film (screen_ps30) takes the
	-- colour the shaders give this blood (cl_util.lua U.FluidAbsorb3: their absorption, hue and absorption settings), at
	-- the film's tuned opacity: red blood as dark in all as before (the sum of its absorbance over the three colours; every
	-- type keeps its darkness relative to red). (Not its red channel alone: red blood lets nearly all red through, and
	-- scaling by that near-zero channel left every film about ten times too clear, so screen blood showed as water.)
	if U.FluidAbsorb3 and U.ShaderColours and U.ShaderColours() then
		local r0 = colCache.redRef
		if not r0 then
			local old
			if U.BloodTrans then
				local r, g, b = U.BloodTrans(0, 0.75, 0.06)
				old = -(math.log(math.Clamp(r / 1.07, 1e-4, 0.999)) + math.log(math.Clamp(g / 0.912, 1e-4, 0.999))
					+ math.log(math.Clamp(b / 0.896, 1e-4, 0.999))) / 0.06
			else
				old = -(math.log(0.75) + math.log(0.25) + math.log(0.2)) / 0.06
			end
			local n1, n2, n3 = U.FluidAbsorb3(0, 0.75, 0.06)
			r0 = { old, n1 + n2 + n3 }
			colCache.redRef = r0
		end
		local s = r0[1] / math.max(r0[2], 1e-4)
		local a1, a2, a3 = U.FluidAbsorb3(btype or 0, oxy or 0.75, 0.06)
		ka, kb, kc = a1 * s, a2 * s, a3 * s
	end
	c = { tr, tg, tb, dr, dg, db, ka, kb, kc }
	colCache[k] = c
	return c
end
S.Colours = Colours

-- a drop on the screen: (x, y) 0..1 of the screen, radius r (share of the screen height), kind 0 drop, 1 splat, 2 streak;
-- rot (radians) and stretch: drawn out along its own x (a drop thrown at a slant); th = its thickness at the middle (mm)
local function Add(x, y, r, btype, oxy, kind, rot, stretch, th)
	local list = S.drops
	if #list >= S.MAX then
		-- full: run into the nearest drop instead
		local best, bd = nil, math.huge
		for _, d in ipairs(list) do
			local dd = (d.x - x) ^ 2 + (d.y - y) ^ 2
			if dd < bd then best, bd = d, dd end
		end
		if best then best.r = math.min((best.r ^ 3 + r ^ 3) ^ (1 / 3), 0.4) best.t0 = CurTime() end
		return best
	end
	kind = kind or 0
	local d = { x = x, y = y, r = r, btype = btype or 0, oxy = oxy or 0.75, kind = kind, rot = rot or math.random() * math.pi * 2,
		stretch = stretch or 1, t0 = CurTime(), vy = 0, trailY = y, var = math.random(1, 3), seed = math.random(),
		th = th or (kind == 1 and math.Clamp(0.35 + r * 2.5, 0.4, 1.2) or math.Clamp(r * 20, 0.04, 0.8)) }
	list[#list + 1] = d
	S.stats.drops = S.stats.drops + 1
	return d
end
S.Add = Add

-- a splat on the screen at (x, y) (0..1 of the screen) of size r (share of the screen height), strength k: a ragged patch
-- of a few blobs run together for a close hit, drops thrown round it (many drawn out into a teardrop along the way they
-- flew) and a fine mist
function S.Splat(x, y, r, btype, oxy, k)
	local amt = S.Amount()
	r = r * math.sqrt(amt)
	local asp = ScrH() / math.max(ScrW(), 1)
	Add(x, y, r * 0.75, btype, oxy, 1)
	for j = 1, math.random(2, 4) do
		local a = math.random() * math.pi * 2
		local dd = r * (0.35 + math.random() * 0.4)
		Add(x + math.cos(a) * dd * asp, y + math.sin(a) * dd, r * (0.3 + math.random() * 0.25), btype, oxy, 1)
	end
	local n = math.floor(3 + 5 * math.min(k or 1, 2) * amt)
	for i = 1, n do
		local a = math.random() * math.pi * 2
		local dist = r * (0.75 + math.random() * 1.5)
		local rr = r * (0.03 + math.random() * 0.11)
		local long = math.random() < 0.45
		Add(x + math.cos(a) * dist * asp, y + math.sin(a) * dist, rr, btype, oxy, 0, a, long and (1.6 + math.random() * 1.6) or 1)
	end
	for i = 1, math.floor((6 + 10 * math.min(k or 1, 2)) * amt) do
		local a = math.random() * math.pi * 2
		local dist = r * (0.8 + math.random() * 2.6)
		Add(x + math.cos(a) * dist * asp, y + math.sin(a) * dist, 0.002 + math.random() * 0.005, btype, oxy, 0)
	end
	S.stats.splats = S.stats.splats + 1
end

-- where a world point lands on the screen (0..1), or nil when it is not in view. Worked out from the camera of the last
-- frame drawn (captured while the frame is drawn: Vector:ToScreen only knows the right camera while the main view is being
-- rendered, and hits come in between frames)
S.view = S.view or nil
local function ScreenAt(pos)
	local v = S.view
	local x, y
	if v and RealTime() - v.t < 1 then
		local d = pos - v.o
		local z = d:Dot(v.f)
		if z < 1 then return nil end
		x = 0.5 + 0.5 * d:Dot(v.r) / (z * v.tx)
		y = 0.5 - 0.5 * d:Dot(v.u) / (z * v.ty)
	else
		local s = pos:ToScreen()
		if not s or not s.visible then return nil end
		x, y = s.x / ScrW(), s.y / ScrH()
	end
	if x < -0.1 or x > 1.1 or y < -0.1 or y > 1.1 then return nil end
	return x, y
end
S.ScreenAt = ScreenAt
local function CaptureView()
	local o, a = EyePos(), EyeAngles()
	local fov = 75
	local vs = render.GetViewSetup and render.GetViewSetup()
	if vs and vs.fov then fov = vs.fov end
	local asp = ScrW() / math.max(ScrH(), 1)
	local tx = math.tan(math.rad(math.Clamp(fov, 10, 170) * 0.5))
	S.view = { o = o, f = a:Forward(), r = a:Right(), u = a:Up(), tx = tx, ty = tx / asp, t = RealTime() }
end

local function Viewer()
	local lp = LocalPlayer()
	if not IsValid(lp) then return nil end
	return lp
end

-- (from P.Spawn) a drop just thrown: does it fly into the camera in the next 0.35 s? Then it lands on the screen when it
-- would get there, where it comes from. Drops thrown by your own body (first person) do not.
local G_ACC = 600
function S.CheckDrop(o)
	if not o.pos or not o.vel then return end
	local lp = Viewer()
	if not lp then return end
	if o.owner == lp and not lp:ShouldDrawLocalPlayer() then return end
	local eye = EyePos()
	local px, py, pz = o.pos:Unpack()
	local ex, ey, ez = eye:Unpack()
	local rx, ry, rz = ex - px, ey - py, ez - pz
	local dd = rx * rx + ry * ry + rz * rz
	if dd > 220 * 220 then return end
	local vx, vy, vz = o.vel:Unpack()
	local vv = vx * vx + vy * vy + vz * vz
	if vv < 400 then return end
	local t = (rx * vx + ry * vy + rz * vz) / vv
	if t <= 0 or t > 0.35 then return end
	-- where it is then (falling meanwhile) and how far from the eye
	local hx, hy, hz = px + vx * t, py + vy * t, pz + vz * t - 0.5 * G_ACC * t * t
	local mx, my, mz = hx - ex, hy - ey, hz - ez
	local miss = math.sqrt(mx * mx + my * my + mz * mz)
	if miss > 7 then return end
	-- nothing solid in between
	local tr = util.TraceLine({ start = o.pos, endpos = Vector(hx, hy, hz), mask = MASK_SOLID, filter = { lp, o.owner } })
	if tr.Hit and tr.Fraction < 0.95 then return end
	local spd = math.sqrt(vv)
	local back = Vector(hx - vx / spd * 14, hy - vy / spd * 14, hz - vz / spd * 14)
	local r = math.Clamp((o.r or 0.6) * 0.012, 0.004, 0.035)
	local bt, oxy = o.btype or 0, o.oxy or 0.75
	-- a drop that comes in at a slant is drawn out along its way across the screen
	local sx, sy = ScreenAt(Vector(px, py, pz))
	S.stats.hits = S.stats.hits + 1
	timer.Simple(t, function()
		if r > 0.012 and G.cv.vmblood and G.cv.vmblood:GetBool() then S.HandsBlood(back, bt, oxy, 0.3) end
		if not S.On() then return end
		local x, y = ScreenAt(back)
		if not x then return end
		local rot, st = nil, 1
		if sx then
			local dx, dy = (x - sx) * ScrW(), (y - sy) * ScrH()
			local l = math.sqrt(dx * dx + dy * dy)
			if l > 2 then rot, st = math.atan2(dy, dx), 1 + math.min(l / (r * ScrH() * 6), 1.5) end
		end
		Add(x, y, r * math.sqrt(S.Amount()), bt, oxy, 0, rot, st)
	end)
end

-- (from W.OnHit) a hit at surf (normal nrm, the round / blow going along dir) of strength k: its back spatter (towards where
-- the round came from, off the surface) and its exit spray (along dir, when it went through) reach you when you are close
-- in front of it - the closer and the more squarely in the spray, the more. Splashes nearby bodies as well.
function S.FromHit(ent, surf, nrm, dir, btype, oxy, k, exits)
	if not surf or not dir then return end
	local lp = Viewer()
	if not lp then return end
	local eye = EyePos()
	local toEye = eye - surf
	local d = toEye:Length()
	if d < 1 then return end
	toEye:Mul(1 / d)
	local back = (nrm and (nrm * 0.55 - dir * 0.45) or -dir):GetNormalized()
	local f = math.max(toEye:Dot(back), exits and toEye:Dot(dir) or -1)
	local reach = 95
	-- (the screen and the hands / weapon each with their own setting: blood on the hands with the screen blood off too)
	local vmOn = G.cv.vmblood and G.cv.vmblood:GetBool()
	if d < reach and f > 0.15 and (S.On() or vmOn) and lp:Alive() then
		local tr = util.TraceLine({ start = surf + toEye * 2, endpos = eye, mask = MASK_SOLID_BRUSHONLY })
		if not tr.Hit then
			local prox = 1 - d / reach
			local w = math.Clamp((k or 1), 0.2, 2.5) * prox * prox * math.Clamp(f, 0, 1)
			local x, y = ScreenAt(surf)
			if not x then x, y = 0.5 + (math.random() - 0.5) * 0.3, 0.45 + (math.random() - 0.5) * 0.3 end
			if w > 0.02 and S.On() then
				-- the splat lands a little off the point hit, towards where the spray goes
				x = x + (math.random() - 0.5) * 0.06
				y = y + (math.random() - 0.5) * 0.06
				S.Splat(x, y, math.Clamp(0.03 + 0.16 * w, 0.03, 0.3), btype, oxy, w * 2)
				-- more drops scattered over the view, the closer the more
				for i = 1, math.floor(w * 14 * S.Amount()) do
					Add(math.Clamp(x + (math.random() - 0.5) * (0.4 + prox), 0, 1), math.Clamp(y + (math.random() - 0.5) * (0.35 + prox), 0, 1),
						0.004 + math.random() * 0.02 * (0.5 + w), btype, oxy, 0)
				end
			end
			if vmOn then S.HandsBlood(surf, btype, oxy, w) end
		end
	end
	S.SplashNeighbours(ent, surf, nrm, dir, btype, oxy, k, exits)
end

-- the spatter of a hit lands on the bodies standing close to it (NPCs, players, ragdolls - not the one hit), on the side
-- facing it, more on those squarely in the back spatter or the exit spray
function S.SplashNeighbours(ent, surf, nrm, dir, btype, oxy, k, exits)
	local E = G.Entities
	if not E or not E.Impact then return end
	local back = (nrm and (nrm * 0.55 - dir * 0.45) or -dir):GetNormalized()
	local lp = LocalPlayer()
	local n = 0
	for _, o in ipairs(ents.FindInSphere(surf, 72)) do
		if n >= 4 then break end
		if o ~= ent and IsValid(o) and (o:IsNPC() or o:IsPlayer() or o:IsRagdoll() or (o.IsNextBot and o:IsNextBot()))
			and not (o == lp and not lp:ShouldDrawLocalPlayer()) and G.BloodTypeOf(o) ~= nil then
			local c = o:WorldSpaceCenter()
			local to = c - surf
			local dist = to:Length()
			if dist > 1 then
				to:Mul(1 / dist)
				local f = math.max(to:Dot(back), exits and to:Dot(dir) or -1)
				if f > 0.2 then
					local tr = util.TraceLine({ start = surf + to * 2, endpos = c, filter = ent, mask = MASK_SHOT })
					if tr.Entity == o then
						local w = math.Clamp(k or 1, 0.2, 2.5) * (1 - dist / 72) * f
						local m = math.floor(1 + 4 * w)
						for i = 1, m do
							local jit = VectorRand() * (1.5 + 3 * w)
							E.Impact(o, tr.HitPos + jit, tr.HitNormal, to * 300, 0.25 + 0.35 * math.random() * w, 2 + 10 * w, 0, 0,
								1.2 + math.random(), 0.2, nil, { btype = btype, oxy = oxy })
						end
						n = n + 1
					end
				end
			end
		end
	end
end

-- blood on your first-person hands and weapon from something at pos: stamps on the side of them facing it and on their
-- top (the spray comes in from the front and falls on them - the side you see), each put on the model's surface
S.vmLast = S.vmLast or {}
-- (their bones are only right while the view model is drawn: a request is kept and done in the view model pass - see
-- cl_entities.lua IsVMEnt)
S.vmQueue = S.vmQueue or {}
local HAND_BONES = { "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_L_Forearm",
	"ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_L_Finger1", "ValveBiped.Bip01_R_Finger2", "ValveBiped.Bip01_L_Finger2" }
local UP = Vector(0, 0, 1)
function S.HandsBlood(pos, btype, oxy, w)
	local E = G.Entities
	local lp = LocalPlayer()
	if not E or not E.Impact or not IsValid(lp) or not lp:Alive() or lp:ShouldDrawLocalPlayer() then return end
	if not G.cv.vmblood or not G.cv.vmblood:GetBool() then return end
	if #S.vmQueue < 16 then S.vmQueue[#S.vmQueue + 1] = { pos = pos, btype = btype, oxy = oxy, w = w, t = CurTime(), done = {} } end
end

-- (in the view model pass, for the hands or the weapon being drawn: the requests not done for it yet)
function S.HandsBloodNow(ent)
	local q = S.vmQueue
	if #q == 0 or not IsValid(ent) then return end
	local now = CurTime()
	for i = #q, 1, -1 do
		local r = q[i]
		if not r.done[ent] then
			r.done[ent] = true
			local ok, err = pcall(S.HandsBloodOn, ent, r.pos, r.btype, r.oxy, r.w)
			if not ok and (S.errors or 0) < 10 then S.errors = (S.errors or 0) + 1 ErrorNoHalt("[GHMPB] view model blood: " .. tostring(err) .. "\n") end
		end
		-- (kept a moment for the other of the two - hands and weapon are drawn in two passes)
		if now - r.t > 0.5 then table.remove(q, i) end
	end
end

function S.HandsBloodOn(ent, pos, btype, oxy, w)
	local E = G.Entities
	w = math.min(w or 0.5, 1.5)
	do
		if IsValid(ent) and not ent:GetNoDraw() and ent:GetModel() and ent:GetModel() ~= "" then
			local cands = {}
			for _, bn in ipairs(HAND_BONES) do
				local b = ent:LookupBone(bn)
				if b then cands[#cands + 1] = b end
			end
			if #cands == 0 then
				-- a weapon without an arm rig: its own bones
				for b = 0, math.min((ent.GetBoneCount and ent:GetBoneCount() or 1) - 1, 12) do cands[#cands + 1] = b end
			end
			local m = math.floor(4 + 8 * w)
			for i = 1, m do
				local b = cands[math.random(1, math.max(#cands, 1))]
				local bp = b and ent:GetBonePosition(b) or ent:WorldSpaceCenter()
				if bp then
					local to = (pos - bp):GetNormalized()
					local nd = (to * 0.6 + UP * 0.8 + VectorRand() * 0.35):GetNormalized()
					local p, n, bb = bp + nd * 3, nd, b
					if U.SnapToMesh then
						local okS, sp, sn, sb = pcall(U.SnapToMesh, ent, bp + nd * 3, nd, b, true)
						if okS and sp then p, n, bb = sp, sn or nd, sb or b end
					end
					if E.Impact(ent, p, n, -to * 200, 0.3 + 0.6 * math.random(), 8 + 24 * w, 0, 0, 1 + math.random(), 0.2, bb,
						{ btype = btype, oxy = oxy }) then
						S.stats.vmStamps = S.stats.vmStamps + 1
						local key = "vm_" .. ent:GetClass()
						S.stats[key] = (S.stats[key] or 0) + 1
					end
				end
			end
			S.vmLast[ent] = CurTime()
			S.stats.vm = S.stats.vm + 1
		end
	end
end

-- ---------------------------------------------------------------- the liquid on the screen
local function Step(dt)
	local list = S.drops
	if #list == 0 then return end
	local now = CurTime()
	local fade = FadeTime()
	local asp = ScrH() / math.max(ScrW(), 1)
	local add = {}
	for i = #list, 1, -1 do
		local d = list[i]
		local age = now - d.t0
		if age > fade or d.y > 1.15 then
			table.remove(list, i)
		else
			-- big, wet drops run down (faster the bigger), leave a streak and lose volume to it; they stop as they dry or
			-- shrink. A splat's thick middle runs too, more slowly
			local wet = 1 - math.Clamp(age / (fade * 0.45), 0, 1)
			local over = d.r - (d.kind == 1 and 0.05 or 0.016)
			if d.kind ~= 2 and over > 0 and wet > 0.05 then
				local sp = d.kind == 1 and 0.35 or 1
				d.vy = math.min(d.vy + over * 30 * sp * dt, over * 16 * wet * sp)
				local dy = d.vy * dt
				d.y = d.y + dy
				-- the streak it leaves: one long, even, thin line behind it (a new one every quarter of the screen)
				local w = (d.kind == 1 and d.r * 0.1 or d.r * 0.22)
				local st = d.streak
				if st and (st.dead or st.top == nil or d.y - st.top > 0.25) then st = nil end
				if not st then
					add[#add + 1] = { d, w }
				else
					local bot = d.y - d.r * 0.3
					local half = math.max((bot - st.top) * 0.5, w)
					st.y = st.top + half
					st.stretch = half / st.r
				end
				if d.kind == 0 then d.r = math.max(d.r ^ 3 - w * w * dy * 0.6, 0) ^ (1 / 3) end
			end
		end
	end
	for _, a in ipairs(add) do
		-- a streak: drawn out along y (its own x turned a quarter)
		local d, w = a[1], a[2]
		local top = d.y - d.r * 0.3 - w
		local t = Add(d.x, top + w, w, d.btype, d.oxy, 2, math.pi * 0.5, 1, d.th * 0.3)
		if t and t ~= d and t.kind == 2 then t.t0 = d.t0 t.trail = true t.top = top d.streak = t end
	end
	-- drops that meet run together (moving ones only: the rest stay where they landed)
	for i = 1, #list do
		local a = list[i]
		if a and a.vy > 0 and not a.dead and a.kind == 0 then
			for j = 1, #list do
				local b = list[j]
				if b ~= a and not b.dead and not b.trail and b.kind == 0 then
					local dx, dy = (a.x - b.x) / asp, a.y - b.y
					local rr = (a.r + b.r) * 0.6
					if dx * dx + dy * dy < rr * rr then
						local v1, v2 = a.r ^ 3, b.r ^ 3
						a.x = (a.x * v1 + b.x * v2) / (v1 + v2)
						a.r = (v1 + v2) ^ (1 / 3)
						a.th = math.max(a.th, b.th)
						a.t0 = math.max(a.t0, b.t0)
						b.dead = true
						S.stats.merged = S.stats.merged + 1
					end
				end
			end
		end
	end
	for i = #list, 1, -1 do if list[i].dead then table.remove(list, i) end end
end
S.Step = Step

-- how a drop looks now: its fade (1 .. 0), how wet it still is (1 .. 0) and how far it has dried (0 .. 1)
local function Life(d, now, fade)
	local age = now - d.t0
	local a = 1 - math.Clamp((age - fade * 0.55) / (fade * 0.45), 0, 1)
	local wet = 1 - math.Clamp(age / (fade * 0.5), 0, 1)
	local dry = math.Clamp(age / fade, 0, 1)
	return a, wet, dry
end

-- the light where you stand (linear) and how bright it is
local function EyeLight()
	local lc = render.GetLightColor and render.GetLightColor(EyePos()) or Vector(0.5, 0.5, 0.5)
	local lum = lc.x * 0.2126 + lc.y * 0.7152 + lc.z * 0.0722
	return lc, lum
end

-- ---------------------------------------------------------------- drawn as a liquid film (screen_ps30)
-- GHM: "the screen blood needs to use the nvidia blood physics shader" - the blood on the lens is kept from frame to frame in
-- two half-size float targets and runs on the GPU the way NVIDIA's HLSL Blood Shader does it (SDK 9.5, Kevin Myers, "Gravity
-- Maps", 2004): every step each texel passes on the share of its blood that stands above a minimum height to its neighbours,
-- the way gravity (down the screen, turned with the view) and the lens' unevenness send it - big drops run down in rivulets
-- and leave a trail, drops that meet run together, the wet height dries away and the stain then fades (screen_ps30 mode 2).
-- New blood is added to what is there (mode 0, each drop's shape worked out in the shader) and the frame is drawn through
-- it (mode 1).
S.sim = S.sim or { cur = 1, acc = 0, untilT = 0, clear = true, steps = 0 }
local SIM_STEP = 1 / 60
S.SIM = { minH = 0.8, speed = 14, tilt = 1.0, dry = 2.5, fade = 8, wetH = 0.5, stick = 0.6 }
function S.SimActive() return S.sim.untilT > RealTime() end
local vtmp = Vector()
local CX, CY = { -1, 1, 1, -1 }, { -1, -1, 1, 1 }
local function ClearRT(rt)
	render.PushRenderTarget(rt)
	-- (colour only: the target has no depth buffer, and a clear that asks for depth too is refused)
	render.Clear(0, 0, 0, 0)
	render.PopRenderTarget()
end
local function Deposit(list, W, H, fh)
	local mPos, mTC, mAdv = mesh.Position, mesh.TexCoord, mesh.AdvanceVertex
	mesh.Begin(MATERIAL_QUADS, #list)
	for _, d in ipairs(list) do
		local c = Colours(d.btype, d.oxy)
		-- its thickness at the middle (mm): the absorbance it adds
		local th = d.th
		-- (+ 3 / mm in every colour: blood is turbid - its cells scatter the light, so a millimetre of it is all but opaque
		-- even in red, while a thin smear stays a clear red veil)
		local ar, ag, ab = (c[7] + 3) * th / 8, (c[8] + 3) * th / 8, (c[9] + 3) * th / 8
		-- its wet height in film texels: a drop stands like a cap of about 0.45 its radius (a big one runs, a small one stays),
		-- a splat is a flat sheet with lumps (only its thickest lumps run), a streak is flat
		local rt = d.r * fh
		local kind = d.kind
		local hw = rt * (kind == 0 and 0.45 or (kind == 1 and 0.05 or 0.15))
		local amp = kind == 1 and 0.16 or (kind == 2 and 0 or 0.08)
		local expo = kind == 0 and 0.5 or (kind == 1 and 0.3 or 0.35)
		-- a drop drawn out by its flight is a teardrop (thin tail behind), a streak a capsule as long as it is stretched
		local z = kind == 2 and d.stretch or (kind == 0 and math.Clamp((d.stretch - 1) * 0.7, 0, 0.85) or 0)
		local ax, ay = d.r * H * d.stretch, d.r * H
		local co, si = math.cos(d.rot or 0), math.sin(d.rot or 0)
		local cx, cy = d.x * W, d.y * H
		for ci = 1, 4 do
			local lx, ly = CX[ci], CY[ci]
			local ox, oy = lx * ax, ly * ay
			local px, py = cx + ox * co - oy * si, cy + ox * si + oy * co
			vtmp:SetUnpacked(px / W * 2 - 1, 1 - py / H * 2, 0)
			mPos(vtmp)
			-- (a streak's own x is turned a quarter: its length runs along its local x, x < 0 its top end)
			mTC(0, lx, ly, d.seed, kind)
			mTC(1, ar, ag, ab, hw)
			mTC(2, amp, expo, z, 0)
			mAdv()
		end
	end
	mesh.End()
end
-- gravity on the screen: down the screen when you look level, turned when the view rolls; weaker when you look up or down
-- (the lens then faces the ground or the sky and the blood on it hardly runs)
local function ScreenGravity()
	local a = EyeAngles()
	local r, u = a:Right(), a:Up()
	local gx, gy = -r.z, u.z
	local gm = math.sqrt(gx * gx + gy * gy)
	if gm < 1e-3 then return 0, 1, 0 end
	return gx / gm, gy / gm, gm
end
local function DrawShader(list, fade)
	local GPU = G.GPU
	local W, H = ScrW(), ScrH()
	local fw, fh = math.max(math.floor(W / 2), 1), math.max(math.floor(H / 2), 1)
	local sim = S.sim
	if not S.rtA or S.rtW ~= fw or S.rtH ~= fh then
		S.rtA = GPU.RT("screenfilmA_" .. fw .. "x" .. fh, fw, fh, GPU.FMT_F16)
		S.rtB = GPU.RT("screenfilmB_" .. fw .. "x" .. fh, fw, fh, GPU.FMT_F16)
		S.rtW, S.rtH = fw, fh
		S.runA = GPU.Mat("screenrunA_" .. fw .. "x" .. fh, "clip_vs30", "screen_ps30", { ["$tcsize0"] = 4, ["$basetexture"] = S.rtA:GetName() })
		S.runB = GPU.Mat("screenrunB_" .. fw .. "x" .. fh, "clip_vs30", "screen_ps30", { ["$tcsize0"] = 4, ["$basetexture"] = S.rtB:GetName() })
		S.compA = GPU.Mat("screencompA_" .. fw .. "x" .. fh, "clip_vs30", "screen_ps30", { ["$tcsize0"] = 4, ["$basetexture"] = S.rtA:GetName(),
			["$texture1"] = "_rt_FullFrameFB" })
		S.compB = GPU.Mat("screencompB_" .. fw .. "x" .. fh, "clip_vs30", "screen_ps30", { ["$tcsize0"] = 4, ["$basetexture"] = S.rtB:GetName(),
			["$texture1"] = "_rt_FullFrameFB" })
		sim.clear = true
	end
	S.filmMat = S.filmMat or GPU.Mat("screenfilm", "clip_vs30", "screen_ps30", { ["$tcsize0"] = 4, ["$tcsize1"] = 4, ["$tcsize2"] = 4 })
	local rnow = RealTime()
	if #list == 0 and rnow >= sim.untilT then return end
	-- (when all of it has gone, the next blood starts on a clean lens)
	if sim.clear or rnow >= sim.untilT then
		ClearRT(S.rtA) ClearRT(S.rtB)
		sim.clear, sim.cur, sim.acc, sim.lastT = false, 1, 0, rnow
	end
	-- 1. the new blood, added to what is on the lens
	if #list > 0 then
		local film = S.filmMat
		GPU.SetC(film, 0, 0, 0, 0, 0)
		render.PushRenderTarget(sim.cur == 1 and S.rtA or S.rtB)
		GPU.Additive(true)
		render.OverrideAlphaWriteEnable(true, true)
		render.SetMaterial(film)
		cam.Start2D()
		local ok, err = pcall(Deposit, list, W, H, fh)
		cam.End2D()
		render.OverrideAlphaWriteEnable(false)
		GPU.Additive(false)
		render.PopRenderTarget()
		S.stats.deposited = (S.stats.deposited or 0) + #list
		S.drops = {}
		sim.untilT = rnow + fade * 1.1
		if not ok then error(err) end
	end
	-- 2. it runs: steps of 1/60 s (at most 3 a frame)
	local dt = math.Clamp(rnow - (sim.lastT or rnow), 0, 0.1)
	sim.lastT = rnow
	sim.acc = math.min(sim.acc + dt, SIM_STEP * 3)
	if sim.acc >= SIM_STEP then
		local P = S.SIM
		local sc = fh / 450
		local gx, gy, gm = ScreenGravity()
		for _, m in ipairs({ S.runA, S.runB }) do
			GPU.SetC(m, 0, 1 / fw, 1 / fh, 0, 2)
			GPU.SetC(m, 1, SIM_STEP, P.minH * sc, P.speed * sc * math.max(gm, 0.2), P.tilt)
			GPU.SetC(m, 2, P.dry / fade, P.fade / fade, P.wetH * sc, P.stick)
			GPU.SetC(m, 3, gx, gy, 0, 0)
		end
		-- (no blending: each step writes every texel of the other target)
		render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
		local n = 0
		while sim.acc >= SIM_STEP and n < 3 do
			local src = sim.cur == 1 and S.runA or S.runB
			render.PushRenderTarget(sim.cur == 1 and S.rtB or S.rtA)
			render.OverrideAlphaWriteEnable(true, true)
			render.SetMaterial(src)
			GPU.FullQuad(fw, fh)
			render.OverrideAlphaWriteEnable(false)
			render.PopRenderTarget()
			sim.cur = 3 - sim.cur
			sim.acc = sim.acc - SIM_STEP
			n = n + 1
		end
		render.OverrideBlend(false)
		sim.steps = sim.steps + n
	end
	-- 3. the frame seen through it (everything left fades out over the last fifth of its time)
	local comp = sim.cur == 1 and S.compA or S.compB
	render.UpdateScreenEffectTexture()
	local lc, lum = EyeLight()
	local lk = math.Clamp(lum, 0.08, 1.2) / math.max(lum, 1e-3) * 0.45
	local left = math.Clamp((sim.untilT - rnow) / (fade * 0.2), 0, 1)
	-- (1.26.10e) GHM: "could the blood on screen be blurrier ... like a camera trying to focus onto it or like eyes blur" -
	-- C0.z is how far the world behind the blood is thrown out of focus (share of the screen); the shader widens it where
	-- the blood is thick. ghmpb_screen_blur scales it (0 = off, 1 = default), console-tunable.
	local blur = G.cv.screenblur and math.Clamp(G.cv.screenblur:GetFloat(), 0, 3) or 1
	GPU.SetC(comp, 0, 1 / fw, 1 / fh, 0.022 * blur, 1)
	GPU.SetC(comp, 1, left, 0.012, 0.25, 1)
	GPU.SetC(comp, 2, lc.x * lk, lc.y * lk, lc.z * lk, 90)
	local sk = math.Clamp(lum * 1.4 + 0.15, 0.15, 1.2) * left
	GPU.SetC(comp, 3, 0.8 * sk, lc.x * lk * 0.7 * left, lc.y * lk * 0.7 * left, lc.z * lk * 0.7 * left)
	render.SetMaterial(comp)
	GPU.FullQuad(W, H)
end

-- ---------------------------------------------------------------- without the shader: three passes with the game's own
local function DrawFallback(list, now, fade)
	local m = Mats()
	local w, h = ScrW(), ScrH()
	local lc, lum = EyeLight()
	lum = math.Clamp(lum * 1.6 + 0.2, 0.2, 1)
	cam.Start2D()
	-- 1. absorption: a film tints what is behind it (dst *= 1 - coverage * (1 - T))
	render.OverrideBlend(true, BLEND_ZERO, BLEND_ONE_MINUS_SRC_COLOR or 10, BLENDFUNC_ADD)
	for _, d in ipairs(list) do
		local c = Colours(d.btype, d.oxy)
		local a = Life(d, now, fade)
		local t = math.Clamp(d.th, 0.05, 1.2) / 0.06
		local tr, tg, tb = c[1] ^ t, c[2] ^ t, c[3] ^ t
		surface.SetMaterial(d.kind == 1 and m.splat or m.drop[d.var])
		surface.SetDrawColor((1 - tr) * 255 * a, (1 - tg) * 255 * a, (1 - tb) * 255 * a, 255)
		local s = d.r * h * (d.kind == 1 and 2.2 or 2)
		surface.DrawTexturedRectRotated(d.x * w, d.y * h, s * d.stretch, s, -math.deg(d.rot or 0))
	end
	-- 2. its body: dark, opaque in proportion to its thickness (premultiplied: dst = src + dst * (1 - a))
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD)
	for _, d in ipairs(list) do
		local c = Colours(d.btype, d.oxy)
		local a, wet, dry = Life(d, now, fade)
		local thick = math.Clamp(d.th / 1.2, 0.05, 1) * (d.kind == 1 and 0.85 or 0.6) * a
		local dk = (1 - 0.45 * dry) * 0.45 * lum
		surface.SetMaterial(d.kind == 1 and m.splat or m.drop[d.var])
		surface.SetDrawColor(c[4] * dk * thick, c[5] * dk * thick, c[6] * dk * thick, 255 * thick)
		local s = d.r * h * (d.kind == 1 and 2.2 or 2)
		surface.DrawTexturedRectRotated(d.x * w, d.y * h, s * d.stretch, s, -math.deg(d.rot or 0))
	end
	-- 3. while it is wet: a highlight on each drop (the light from above and to the left)
	render.OverrideBlend(true, BLEND_ONE, BLEND_ONE, BLENDFUNC_ADD)
	surface.SetMaterial(m.spec)
	for _, d in ipairs(list) do
		local _, wet = Life(d, now, fade)
		if wet > 0.02 and d.r > 0.006 and d.kind ~= 2 then
			local v = 80 * wet * lum
			surface.SetDrawColor(v, v * 0.92, v * 0.9, 255)
			local s = d.r * h * (d.kind == 1 and 0.6 or 0.5)
			surface.DrawTexturedRect(d.x * w - d.r * h * 0.35 - s * 0.5, d.y * h - d.r * h * 0.4 - s * 0.5, s, s)
		end
	end
	render.OverrideBlend(false)
	cam.End2D()
end

function S.Draw()
	local list = S.drops
	local fade = FadeTime()
	if S.ShaderOK() then
		S.path = "shader"
		DrawShader(list, fade)
	else
		if #list == 0 then return end
		S.path = "fallback"
		DrawFallback(list, CurTime(), fade)
	end
end

function S.Clear()
	S.drops = {}
	S.sim.untilT, S.sim.clear = 0, true
end

hook.Add("RenderScreenspaceEffects", "ghmpb_screen", function()
	CaptureView()
	if #S.drops == 0 and not S.SimActive() then return end
	if not S.On() then S.Clear() return end
	local ok, err = pcall(S.Draw)
	if not ok then
		render.OverrideBlend(false)
		render.OverrideAlphaWriteEnable(false)
		S.errors = (S.errors or 0) + 1
		-- the shader path failing: the next frames draw without it
		if S.path == "shader" then S.shaderOK = false end
		if S.errors < 10 then ErrorNoHalt("[GHMPB] screen blood: " .. tostring(err) .. "\n") end
	end
end)

local lastT, wasAlive = 0, true
hook.Add("Think", "ghmpb_screen", function()
	local now = RealTime()
	local dt = math.min(now - lastT, 0.1)
	lastT = now
	-- (the CPU physics is for the drawing without the shader: with it the blood runs on the GPU)
	if #S.drops > 0 and not S.ShaderOK() then
		local ok, err = pcall(Step, dt)
		if not ok and (S.errors or 0) < 10 then S.errors = (S.errors or 0) + 1 ErrorNoHalt("[GHMPB] screen blood: " .. tostring(err) .. "\n") end
	end
	-- the hands and weapon: cleared when you die (or after their fade time); the screen when you come back
	-- (requests for the hands / weapon that no view model pass took - third person, no weapon - are dropped)
	for i = #S.vmQueue, 1, -1 do if CurTime() - S.vmQueue[i].t > 1 then table.remove(S.vmQueue, i) end end
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local alive = lp:Alive()
	local E = G.Entities
	if wasAlive and not alive then
		for ent in pairs(S.vmLast) do if E and E.Remove then E.Remove(ent) end end
		S.vmLast = {}
	elseif alive and not wasAlive then
		S.Clear()
	end
	wasAlive = alive
	local vf = G.cv.vmfade and G.cv.vmfade:GetFloat() or 0
	if vf > 0 then
		local t = CurTime()
		for ent, last in pairs(S.vmLast) do
			if t - last > vf then
				if E and E.Remove then E.Remove(ent) end
				S.vmLast[ent] = nil
			end
		end
	end
end)

-- the blood on your hands and weapon is drawn right after them, in the view model pass (drawing them again from in here must
-- not start this over)
local inVM = false
S.vmDraws = S.vmDraws or 0
local function DrawVM(ent)
	if inVM or not IsValid(ent) then return end
	local E = G.Entities
	if E and E.VMPassBegin then E.VMPassBegin(ent) end
	if #S.vmQueue > 0 then S.HandsBloodNow(ent) end
	if not E or not E.domains or not E.domains[ent] or not E.DrawViewModel then
		if E and E.VMPassEnd then E.VMPassEnd() end
		return
	end
	inVM = true
	local ok, err = pcall(E.DrawViewModel, ent)
	inVM = false
	if E.VMPassEnd then E.VMPassEnd() end
	render.MaterialOverrideByIndex()
	S.vmDraws = S.vmDraws + 1
	if not ok then
		S.errors = (S.errors or 0) + 1
		if S.errors < 10 then ErrorNoHalt("[GHMPB] view model blood: " .. tostring(err) .. "\n") end
	end
end
hook.Add("PostDrawViewModel", "ghmpb_vmblood", function(vm) DrawVM(vm) end)
hook.Add("PostDrawPlayerHands", "ghmpb_vmblood", function(hands) DrawVM(hands) end)

concommand.Add("ghmpb_screen_test", function(_, _, args)
	local bt = tonumber(args[1] or "0") or 0
	S.Splat(0.45 + math.random() * 0.1, 0.4 + math.random() * 0.1, 0.12, bt, 0.75, 1.5)
	for i = 1, 20 do Add(math.random(), math.random() * 0.8, 0.005 + math.random() * 0.03, bt, 0.75, 0) end
end, nil, "GHM PhysBlood: throw some blood on your screen (argument: blood type 0 red, 1 yellow, 2 green, 3 zombie, 4 synth, 5 robot, 6 blue, 7 purple)")
