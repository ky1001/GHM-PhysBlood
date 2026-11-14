local G = GHMPB
G.VAT = G.VAT or {}
local V = G.VAT
local U = G.U
local floor, min, max = math.floor, math.min, math.max

V.DIR = "data_static/ghmpb/vat/"
V.effects = V.effects or {}
V.inst = V.inst or {}
V.stats = V.stats or { spawned = 0, skipped = 0, framesBuilt = 0, loadErrors = 0, drops3d = 0 }

V.KINDS = {
	back = { "omni01", "omni02", "omni03", "omni10", "omni_erode01", "spray01" },
	fwd = { "ribbon02", "ribbon03", "omni15", "stream01", "stream02" },
	heavy = { "omni11", "omni15", "omni10", "omni02", "omni_erode01", "stream01" },
	blunt = { "omni04", "omni05", "omni14", "omni_erode01" },
	jet = { "stream01", "stream02", "ribbon02", "ribbon03" },
	crown = { "crown3", "omni01" },
	spray = { "spray01", "spray02", "omni01", "omni03" },
	drip = { "drip01" },
	drop = { "drop01", "drop02", "drop03", "drop04" },
}

local cvOn = CreateClientConVar("ghmpb_vat", "1", true, false, "GHM PhysBlood: 3D fluid-simulated blood meshes (VAT particles, bursts, streams, drips and droplets)", 0, 1)
local cvSize = CreateClientConVar("ghmpb_vat_size", "1", true, false, "GHM PhysBlood: size of the VAT blood bursts", 0.25, 3)
V.cvSize = cvSize
local cvMax = CreateClientConVar("ghmpb_vat_max", "28", true, false, "GHM PhysBlood: VAT blood bursts on screen at once", 1, 80)
-- (1.26.8) the quality setting, the frame rate and the size of the fight decide how many (cl_governor.lua V.Detail)
local function Detail()
	if G.Gov and G.Gov.Detail then return G.Gov.Detail() end
	return 1, 0
end
V.Detail = Detail
V.cvOn, V.cvSize, V.cvMax = cvOn, cvSize, cvMax
-- (1.26.6) 3D mesh droplets and drips are their own setting. (1.26.7) On by default again, as in 1.26.2 (the testers liked
-- its look: every flying drop, drip and stream a deforming 3D fluid mesh); 0 = drawn by the blood shader
local cvDrops = CreateClientConVar("ghmpb_vat_drops", "1", true, false, "GHM PhysBlood: draw flying drops and hanging drips as 3D VAT meshes (0 = drawn by the blood shader)", 0, 1)
V.cvDrops = cvDrops
if G.migrate1267 and not cvDrops:GetBool() then cvDrops:SetString("1") end
-- (1.26.6) default burst colours: GHM's. (1.26.10c) GHM: "each particle is matching the color of the blood emitted" - the
-- bursts, streams and 3D drops now take the colour the shaders give that blood (V.Colour, cl_util.lua U.FluidAlbedo); these
-- settings only adjust from there, and start neutral. The 1.26.6 defaults are kept for Lite mode (no blood shaders: its
-- blood has Lua colours of its own, which they were tuned to) and to recognise players still on them
V.OLD_BRIGHT = 2.15
V.OLD_TYPE = { [0] = { 0.27, 0 }, { 1, -0.63 }, { 0.28, 0.16 }, { 1.05, -0.21 }, { 1, 0 }, { 1, 0 }, { 1, 0 }, { 1, 0 } }
V.DEF_BRIGHT = "1"
V.DEF_TYPE = {}
for bt = 0, 7 do V.DEF_TYPE[bt] = { "1", "0" } end
local cvBright = CreateClientConVar("ghmpb_vat_bright", V.DEF_BRIGHT, true, false, "GHM PhysBlood: brightness of the VAT blood bursts (1 = the colour of the blood)", 0.1, 4)
V.cvBright = cvBright
V.TYPES = { [0] = "red", "yellow", "green", "zombie", "synth", "robot", "blue", "purple" }
V.cvType = {}
for bt = 0, 7 do
	local n = V.TYPES[bt]
	V.cvType[bt] = {
		bright = CreateClientConVar("ghmpb_vat_" .. n .. "_bright", V.DEF_TYPE[bt][1], true, false, "GHM PhysBlood: brightness of " .. n .. " VAT blood bursts", 0.1, 4),
		hue = CreateClientConVar("ghmpb_vat_" .. n .. "_hue", V.DEF_TYPE[bt][2], true, false, "GHM PhysBlood: hue of " .. n .. " VAT blood bursts (-1..1 = -40..+40 degrees)", -1, 1),
	}
end
-- (1.26.6) players still on the old defaults get the new ones: the burst colours, and 28 bursts on screen instead of the
-- 1.26.1 default of 10 (with 10, every gunshot's bursts and sprays replaced the ones still playing - cut off half-way)
-- (1.26.10c: the colour part of this is gone - neutral is the default again)
if G.migrate1266 then
	if cvMax:GetInt() == 10 then cvMax:SetInt(28) end
end
-- (1.26.10c) players on the 1.26.6 burst colours get the neutral ones (the bursts take the blood's colour now)
do
	local function Near(cv, v) return math.abs(cv:GetFloat() - v) < 1e-3 end
	local old = Near(cvBright, V.OLD_BRIGHT)
	for bt = 0, 5 do old = old and Near(V.cvType[bt].bright, V.OLD_TYPE[bt][1]) and Near(V.cvType[bt].hue, V.OLD_TYPE[bt][2]) end
	if old then
		cvBright:SetString(V.DEF_BRIGHT)
		for bt = 0, 7 do V.cvType[bt].bright:SetString(V.DEF_TYPE[bt][1]) V.cvType[bt].hue:SetString(V.DEF_TYPE[bt][2]) end
		V.migratedColours = true
	end
end

-- (1.26.8) asked once (again every 10 s while missing): V.On() asked the file system on every drop landing (the splash
-- crowns) and several times a frame - a search through every mounted addon, about 0.2 ms a call (ghmpb_prof: a drop
-- landing 0.2-0.25 ms besides its stains, with the shaders and with Lite)
local installed, installedT = nil, -1
function V.Installed()
	if installed then return true end
	local now = RealTime()
	if installed == nil or now >= installedT then
		installed = file.Exists(V.DIR .. "omni01.dat", "GAME") or false
		installedT = now + 10
	end
	return installed
end
function V.On() return cvOn:GetBool() and G.cv.enable:GetBool() and V.Installed() end

local function U16(s, i) local a, b = string.byte(s, i, i + 1) return a + b * 256 end
local function F32(s, i)
	local b1, b2, b3, b4 = string.byte(s, i, i + 3)
	local sign = b4 >= 128 and -1 or 1
	local e = (b4 % 128) * 2 + floor(b3 / 128)
	local m = (b3 % 128) * 65536 + b2 * 256 + b1
	if e == 0 then return sign * m * 2 ^ -149 end
	if e == 255 then return sign * math.huge end
	return sign * (1 + m / 8388608) * 2 ^ (e - 127)
end
V.F32 = F32

function V.ParseHeader(s)
	if not s or #s < 36 or string.sub(s, 1, 4) ~= "GVAT" then return nil, "not a VAT file" end
	local fps = F32(s, 6)
	local nf = U16(s, 10)
	fps = max(fps * 1.6, nf * 1.65)
	local bmin = { F32(s, 12), F32(s, 16), F32(s, 20) }
	local bmax = { F32(s, 24), F32(s, 28), F32(s, 32) }
	local frames = {}
	local pos = 36
	for f = 1, nf do
		if pos + 3 > #s then return nil, "truncated" end
		local nv, nt = U16(s, pos), U16(s, pos + 2)
		frames[f] = { n = nv, t = nt, at = pos + 4 }
		pos = pos + 4 + nv * 9 + nt * 6
	end
	if pos - 1 ~= #s then return nil, "size mismatch" end
	return { fps = fps, frames = frames, bmin = bmin, bmax = bmax, s = s }
end

function V.DecodeFrame(h, fr)
	local s, pos = h.s, fr.at
	local bmin, bmax = h.bmin, h.bmax
	local kx, ky, kz = (bmax[1] - bmin[1]) / 65535, (bmax[2] - bmin[2]) / 65535, (bmax[3] - bmin[3]) / 65535
	local byte = string.byte
	local p, q, idx = {}, {}, {}
	local nv, nt = fr.n, fr.t
	for v = 0, nv - 1 do
		local o = pos + v * 6
		local a1, a2, b1, b2, c1, c2 = byte(s, o, o + 5)
		p[v * 3 + 1] = bmin[1] + (a1 + a2 * 256) * kx
		p[v * 3 + 2] = bmin[2] + (b1 + b2 * 256) * ky
		p[v * 3 + 3] = bmin[3] + (c1 + c2 * 256) * kz
	end
	pos = pos + nv * 6
	for v = 0, nv - 1 do
		local a, b, c = byte(s, pos + v * 3, pos + v * 3 + 2)
		q[v * 3 + 1] = (a >= 128 and a - 256 or a) / 127
		q[v * 3 + 2] = (b >= 128 and b - 256 or b) / 127
		q[v * 3 + 3] = (c >= 128 and c - 256 or c) / 127
	end
	pos = pos + nv * 3
	for t = 0, nt - 1 do
		local o = pos + t * 6
		local a1, a2, b1, b2, c1, c2 = byte(s, o, o + 5)
		idx[t * 3 + 1], idx[t * 3 + 2], idx[t * 3 + 3] = a1 + a2 * 256, b1 + b2 * 256, c1 + c2 * 256
	end
	return p, q, idx
end

function V.Parse(s)
	local h, err = V.ParseHeader(s)
	if not h then return nil, err end
	for _, fr in ipairs(h.frames) do fr.p, fr.q, fr.i = V.DecodeFrame(h, fr) end
	return h
end

local function HueShift(r, g, b, deg)
	r, g, b = r / 255, g / 255, b / 255
	local mx, mn = max(r, g, b), min(r, g, b)
	local d = mx - mn
	if d < 1e-6 then return r * 255, g * 255, b * 255 end
	local h
	if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
	h = (h * 60 + deg) % 360
	local sat, v = d / mx, mx
	local c = v * sat
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local rr, gg, bb
	if h < 60 then rr, gg, bb = c, x, 0 elseif h < 120 then rr, gg, bb = x, c, 0 elseif h < 180 then rr, gg, bb = 0, c, x
	elseif h < 240 then rr, gg, bb = 0, x, c elseif h < 300 then rr, gg, bb = x, 0, c else rr, gg, bb = c, 0, x end
	return (rr + m) * 255, (gg + m) * 255, (bb + m) * 255
end
V.HueShift = HueShift
local function lin(c) c = c / 255 return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
local function srgb(c) c = math.Clamp(c, 0, 1) return (c <= 0.0031308 and c * 12.92 or 1.055 * c ^ (1 / 2.4) - 0.055) * 255 end

-- the colour ($color2, linear) of blood chord mm thick: what the drop shader gives that blood (U.FluidAlbedo) times the
-- ratio of its light to the light these materials get (ApplyLight: 0.75 / 0.65 of it), then the burst settings.
-- (1.26.10d) measured in game (gm_construct in daylight, red, yellow, blue and purple drops side by side, the median of
-- each drop's own colour channel): test 14 - the 3D drops 0.78x as bright as the drop shader's at 1.4, 1.29x at 2.2,
-- 2.29x at 3.2; test 15 - 1.25x at 1.55 (a tumbling 3D drop's shading varies a lot from shot to shot). 1.5 matches them
-- on average
V.LIGHT_K = 1.5
V.COLOR2_GAMMA = true
function V.Colour(bt, chord)
	bt = (bt and bt >= 0 and bt <= 7) and bt or 0
	local r, g, b
	if U.FluidAlbedo and U.ShaderColours and U.ShaderColours() then
		r, g, b = U.FluidAlbedo(bt, 0.75, chord or 2.5)
		r, g, b = r * V.LIGHT_K, g * V.LIGHT_K, b * V.LIGHT_K
	else
		-- Lite: the 1.26.6 look (its blood's own Lua colours)
		local o = V.OLD_TYPE[bt] or V.OLD_TYPE[0]
		local sr, sg, sb = U.BloodDense(bt, 0.75, 120)
		if o[2] ~= 0 then sr, sg, sb = HueShift(sr, sg, sb, o[2] * 40) end
		local k0 = o[1] * V.OLD_BRIGHT
		r, g, b = lin(sr) * k0, lin(sg) * k0, lin(sb) * k0
	end
	local c = V.cvType[bt] or V.cvType[0]
	local hue = c and c.hue:GetFloat() or 0
	if hue ~= 0 then
		local sr, sg, sb = HueShift(srgb(r), srgb(g), srgb(b), math.Clamp(hue, -1, 1) * 40)
		r, g, b = lin(sr), lin(sg), lin(sb)
	end
	local k = (c and c.bright:GetFloat() or 1) * cvBright:GetFloat()
	return r * k, g * k, b * k
end
function V.PreviewColour(bt)
	local r, g, b = V.Colour(bt)
	return Color(srgb(r * 2.2), srgb(g * 2.2), srgb(b * 2.2))
end

local mats = {}
local zeroVec = Vector(0, 0, 0)
-- (1.26.10c) a material per blood type and thickness: a fine drop is lighter than a thick stream, as in the drop shader
V.CHORDS = { 0.5, 1.2, 2.5, 5.0 }
local function ChordClass(chord)
	if not chord then return 3 end
	if chord < 0.8 then return 1 elseif chord < 1.8 then return 2 elseif chord < 3.8 then return 3 end
	return 4
end
V.ChordClass = ChordClass
local function Mat(bt, chord)
	bt = (bt and bt >= 0 and bt <= 7) and bt or 0
	local cls = ChordClass(chord)
	local key = bt * 10 + cls
	local m = mats[key]
	if not m then
		m = CreateMaterial("ghmpb_vat_fluid_" .. bt .. "_" .. cls, "VertexLitGeneric", {
			["$basetexture"] = "ghm_physblood/vat/white",
			["$bumpmap"] = "ghm_physblood/vat/liquid_n",
			["$color2"] = "[0.220 0.005 0.004]",
			["$phong"] = "1",
			["$phongexponent"] = "115",
			["$phongboost"] = "11",
			["$phongfresnelranges"] = "[0.04 0.38 1.0]",
			["$rimlight"] = "1",
			["$rimlightexponent"] = "4",
			["$rimlightboost"] = "0.65",
			["$nocull"] = "1",
		})
		pcall(function()
			m:SetVector("$envmaptint", zeroVec)
			m:SetUndefined("$envmap")
		end)
		mats[key] = m
	end
	local want = Vector(V.Colour(bt, V.CHORDS[cls]))
	-- (1.26.10c) the game takes $color2 as a gamma-space colour (it turns it into linear with a power of 2.2 before it
	-- multiplies the texture): the linear colour of the blood goes in gamma-encoded. (Test 13: passed in linear, the 3D drops
	-- came out ~20x darker than the same drops drawn by the drop shader - near black whatever their blood.) Lite keeps the
	-- 1.26.6 values as they were
	if V.COLOR2_GAMMA and U.ShaderColours and U.ShaderColours() then
		want:SetUnpacked(math.max(want.x, 0) ^ (1 / 2.2), math.max(want.y, 0) ^ (1 / 2.2), math.max(want.z, 0) ^ (1 / 2.2))
	end
	local cur = m:GetVector("$color2")
	if not cur or math.abs(cur.x - want.x) + math.abs(cur.y - want.y) + math.abs(cur.z - want.z) > 0.004 then m:SetVector("$color2", want) end
	return m
end
V.Mat = Mat

local vp, vn, vt, vb = Vector(), Vector(), Vector(), Vector()
local useTables = false
local function Tangents(nx, ny, nz)
	local tx, ty, tz
	if nz < 0.9 and nz > -0.9 then tx, ty, tz = ny, -nx, 0 else tx, ty, tz = 0, nz, -ny end
	local l = math.sqrt(tx * tx + ty * ty + tz * tz)
	if l < 1e-6 then return 1, 0, 0, 0, 1, 0 end
	tx, ty, tz = tx / l, ty / l, tz / l
	return tx, ty, tz, ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
end
V.Tangents = Tangents
local function BuildFrame(h, fr)
	local m = Mesh(Mat(0))
	if fr.t == 0 then return m end
	local p, q, idx = V.DecodeFrame(h, fr)
	if not useTables then
		local ok = pcall(mesh.Begin, m, MATERIAL_TRIANGLES, fr.t)
		if ok then
			local okb, err = pcall(function()
				local mPos, mNrm, mTC, mAdv = mesh.Position, mesh.Normal, mesh.TexCoord, mesh.AdvanceVertex
				local mTS, mTT, mUD = mesh.TangentS, mesh.TangentT, mesh.UserData
				for j = 1, fr.t * 3 do
					local v = idx[j] * 3
					local px, py, pz = p[v + 1], p[v + 2], p[v + 3]
					local nx, ny, nz = q[v + 1], q[v + 2], q[v + 3]
					local tx, ty, tz, bx, by, bz = Tangents(nx, ny, nz)
					local uu = (px * 0.18 + py * 0.11)
					local vv = (pz * 0.18 - py * 0.11)
					vp:SetUnpacked(px, py, pz)
					vn:SetUnpacked(nx, ny, nz)
					vt:SetUnpacked(tx, ty, tz)
					vb:SetUnpacked(bx, by, bz)
					mPos(vp) mNrm(vn) mTC(0, uu, vv)
					if mTS then mTS(vt) mTT(vb) end
					if mUD then mUD(tx, ty, tz, 1) end
					mAdv()
				end
			end)
			mesh.End()
			if not okb then error(err, 0) end
			return m
		end
		useTables = true
	end
	local verts = {}
	for j = 1, fr.t * 3 do
		local v = idx[j] * 3
		local px, py, pz = p[v + 1], p[v + 2], p[v + 3]
		local nx, ny, nz = q[v + 1], q[v + 2], q[v + 3]
		local tx, ty, tz, bx, by, bz = Tangents(nx, ny, nz)
		verts[j] = { pos = Vector(px, py, pz), normal = Vector(nx, ny, nz), u = px * 0.18 + py * 0.11, v = pz * 0.18 - py * 0.11,
			tangent = Vector(tx, ty, tz), binormal = Vector(bx, by, bz), userdata = { tx, ty, tz, 1 } }
	end
	m:BuildFromTriangles(verts)
	return m
end

function V.Load(name)
	local e = V.effects[name]
	if e then return e end
	e = { name = name, state = "missing", meshes = {}, built = 0 }
	V.effects[name] = e
	local path = V.DIR .. name .. ".dat"
	if not file.Exists(path, "GAME") then return e end
	local f = file.Open(path, "rb", "GAME")
	if not f then e.state = "failed" return e end
	local s = f:Read(f:Size())
	f:Close()
	local data, err = V.ParseHeader(s)
	if not data then e.state = "failed" V.stats.loadErrors = V.stats.loadErrors + 1 e.err = tostring(err) return e end
	e.h, e.fps, e.frames, e.bmin, e.bmax = data, data.fps, data.frames, data.bmin, data.bmax
	e.radius = math.max(math.abs(data.bmin[1]), math.abs(data.bmax[1]), math.abs(data.bmin[2]), math.abs(data.bmax[2]),
		math.abs(data.bmin[3]), math.abs(data.bmax[3]))
	e.state = "building"
	return e
end

local order
local function Order()
	if order then return order end
	order = {}
	local seen = {}
	for _, fast in ipairs({ "drop01", "drop02", "drop03", "drop04", "drip01", "spray01", "spray02", "crown3" }) do
		seen[fast] = true
		order[#order + 1] = fast
	end
	local maxN = 0
	for _, list in pairs(V.KINDS) do maxN = math.max(maxN, #list) end
	for k = 1, maxN do
		for _, kind in ipairs({ "back", "fwd", "crown", "jet", "blunt", "heavy", "spray", "drip", "drop" }) do
			local n = V.KINDS[kind] and V.KINDS[kind][k]
			if n and not seen[n] then seen[n] = true order[#order + 1] = n end
		end
	end
	return order
end

function V.Step(budget)
	if not V.On() then return false end
	local t0 = SysTime()
	budget = budget or 0.003
	for _, name in ipairs(Order()) do
		local e = V.Load(name)
		if e.state == "building" then
			while e.built < #e.frames do
				local i = e.built + 1
				local ok, m = pcall(BuildFrame, e.h, e.frames[i])
				if not ok then e.state = "failed" e.err = tostring(m) V.stats.loadErrors = V.stats.loadErrors + 1 break end
				e.meshes[i] = m
				e.built = i
				V.stats.framesBuilt = V.stats.framesBuilt + 1
				if SysTime() - t0 > budget then return true end
			end
			if e.state == "building" then
				e.state = "ready"
				e.h.s = nil
			end
		end
		if SysTime() - t0 > budget then return true end
	end
	return false
end

function V.Ready(name)
	local e = V.effects[name]
	return e ~= nil and e.state == "ready"
end

function V.Free()
	for _, e in pairs(V.effects) do
		for _, m in pairs(e.meshes or {}) do if m and m.Destroy then m:Destroy() end end
	end
	V.effects = {}
	V.inst = {}
end

local keyLight = { { type = MATERIAL_LIGHT_DIRECTIONAL or 2, color = Vector(0, 0, 0), dir = Vector(0, 0, -1) } }
local function ApplyLight(it, posOverride)
	local p = posOverride or (it and it.pos)
	local lt = G.Light and G.Light.Get and p and G.Light.Get(it or "vat_drops", p, 0.3)
	if not lt then
		for k = 0, 5 do render.SetModelLighting(k, 0.3, 0.3, 0.3) end
		render.SetLocalModelLights()
		return
	end
	local r, g, b = lt.r, lt.g, lt.b
	for axis = 1, 3 do
		local k = (axis - 1) * 2
		render.SetModelLighting(k, math.max(r[1] + r[axis + 1], 0) * 0.75, math.max(g[1] + g[axis + 1], 0) * 0.75, math.max(b[1] + b[axis + 1], 0) * 0.75)
		render.SetModelLighting(k + 1, math.max(r[1] - r[axis + 1], 0) * 0.75, math.max(g[1] - g[axis + 1], 0) * 0.75, math.max(b[1] - b[axis + 1], 0) * 0.75)
	end
	local L = keyLight[1]
	L.color = lt.col * 0.65
	L.dir = -lt.dir
	render.SetLocalModelLights(keyLight)
end
V.ApplyLight = ApplyLight

-- (1.26.8) GHM: "when giving a headshot there is a water ripple particle effect, big one and small, please remove
-- that". A head hit throws no fluid bursts (V.mute, set by cl_wounds.lua while it works out a head hit): no splash at
-- the entry or the exit, no spray burst (the mist falls back to its soft puffs). Streams from the wounds and the drips
-- stay
function V.Spawn(kind, pos, dir, size, speed, btype, ent, bone)
	if not V.On() or not pos or not dir then return nil end
	if V.mute and kind ~= "jet" and kind ~= "drip" and kind ~= "drop" then V.stats.muted = (V.stats.muted or 0) + 1 return nil end
	local list = V.KINDS[kind]
	if not list then return nil end
	local eye = EyePos()
	-- (1.26.8) fewer and only nearer bursts with less detail (a big fight, a slow frame, a lower quality setting); the
	-- splash crowns where blood lands nearer still
	local detail = Detail()
	local far = (kind == "crown" and 1400 or 2500) * (0.45 + 0.55 * detail)
	if pos:DistToSqr(eye) > far * far then V.stats.skipped = V.stats.skipped + 1 return nil end
	local ready = {}
	for _, n in ipairs(list) do if V.Ready(n) then ready[#ready + 1] = n end end
	if #ready == 0 then V.stats.skipped = V.stats.skipped + 1 return nil end
	local e = V.effects[ready[math.random(1, #ready)]]
	local s = math.Clamp((size or 1) * cvSize:GetFloat(), 0.04, 6)
	if not U.InViewPos(pos, e.radius * s) then V.stats.skipped = V.stats.skipped + 1 return nil end
	local d = dir:GetNormalized()
	local roll = math.random() * 360
	local ang = d:Angle()
	ang:RotateAroundAxis(d, roll)
	local inst = { e = e, t0 = CurTime(), pos = Vector(pos), ang = ang, roll = roll, s = s, speed = math.Clamp(speed or 1, 0.2, 8),
		btype = btype or 0 }
	if IsValid(ent) and U.BoneToLocal then
		bone = bone or (U.NearestBone and U.NearestBone(ent, pos))
		local lpos, ldir = U.BoneToLocal(ent, bone, pos, d)
		if lpos then
			inst.ent, inst.bone, inst.lpos, inst.ldir = ent, bone, lpos, ldir
		end
	end
	local cap = math.max(4, math.floor(cvMax:GetInt() * detail + 0.5))
	while #V.inst >= cap do table.remove(V.inst, 1) end
	V.inst[#V.inst + 1] = inst
	V.stats.spawned = V.stats.spawned + 1
	return inst
end

function V.Transfer(from, to)
	if not from or not IsValid(to) then return end
	for _, it in ipairs(V.inst) do
		if it.ent == from then it.ent = to end
	end
end

local M = Matrix()
local scaleV = Vector(1, 1, 1)
function V.Draw()
	if #V.inst == 0 then return end
	local now = CurTime()
	local list = V.inst
	render.SuppressEngineLighting(true)
	local ok, err = pcall(function()
		for i = #list, 1, -1 do
			local it = list[i]
			local e = it.e
			local f = floor((now - it.t0) * e.fps * it.speed) + 1
			if f > #e.frames or e.state ~= "ready" then
				table.remove(list, i)
			else
				if it.ent then
					if IsValid(it.ent) and not it.ent:IsRagdoll() and G.Render and G.Render.ragOf and IsValid(G.Render.ragOf[it.ent]) then
						it.ent = G.Render.ragOf[it.ent]
					end
					if IsValid(it.ent) and it.lpos and U.BoneToWorld then
						local wp, wd = U.BoneToWorld(it.ent, it.bone, it.lpos, it.ldir)
						if wp then
							it.pos = wp
							if wd and wd:LengthSqr() > 1e-4 then
								wd:Normalize()
								local ang = wd:Angle()
								ang:RotateAroundAxis(wd, it.roll or 0)
								it.ang = ang
							end
						end
					end
				end
				local m = e.meshes[f]
				if m and e.frames[f].t > 0 then
					ApplyLight(it)
					render.SetMaterial(Mat(it.btype))
					M:Identity()
					M:SetTranslation(it.pos)
					M:SetAngles(it.ang)
					scaleV:SetUnpacked(it.s, it.s, it.s)
					M:Scale(scaleV)
					cam.PushModelMatrix(M)
					m:Draw()
					cam.PopModelMatrix()
				end
			end
		end
	end)
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
	if not ok then error(err, 0) end
end

local dropPos = Vector()
local dropVel = Vector()
local dropAng = Angle()
local MAX_3D_DROPS = 220
local dropNames = { "drop01", "drop02", "drop03", "drop04" }
-- (1.26.8) each 3D drop is a draw of its own: the nearest drops get them, up to this many (Ultra in a quiet scene 220,
-- Medium about 130, Low about 65, a quarter of that in a big fight), and only within 800 u - the others go into the one
-- batch the blood shader draws (a 3D mesh further off is a few pixels anyway). 1.26.7 drew 320 every frame, spread over
-- all the drops near or far, and left the rest out.
V.DROP3D_DIST = 800
-- (1.26.8, second pass) fewer and nearer still with less detail: up to 220 on Ultra, about 80 on Medium, 12 in a big fight
-- (a draw each: ghmpb_prof with the shaders, 1-1.4 ms a frame for the drops), within 4 to 8 m
function V.Drops3DBudget()
	local d = Detail()
	return math.max(12, math.floor(MAX_3D_DROPS * d * d))
end
function V.Drops3DDist() return V.DROP3D_DIST * (0.5 + 0.5 * Detail()) end

function V.DropsReady()
	return V.On() and cvDrops:GetBool() and V.Ready("drop01") and V.Ready("drop02") and V.Ready("drop03") and V.Ready("drop04") and V.Ready("drip01")
end

function V.DrawDrops3D(n, BX, BY, BZ, BVX, BVY, BVZ, BR, BS, BT, BO, trailK, idx3)
	if not V.DropsReady() then return false end
	local now = CurTime()
	local MM = G.MM_TO_UNITS
	local sizeMul = cvSize:GetFloat()
	local eye = EyePos()
	local fwd = EyeAngles():Forward()
	local dripE = V.effects["drip01"]
	local dropE = { V.effects["drop01"], V.effects["drop02"], V.effects["drop03"], V.effects["drop04"] }
	local limit = idx3 and n or min(n, MAX_3D_DROPS)
	local stride = n > limit and (n / limit) or 1
	render.SuppressEngineLighting(true)
	ApplyLight("vat_drops", G.Light and G.Light.ViewProbePos and G.Light.ViewProbePos(eye, fwd, 90) or (eye + fwd * 90))
	local lastKey = -1
	local drawn = 0
	local ok, err = pcall(function()
		local idx = 1
		for c = 1, limit do
			local k
			if idx3 then k = idx3[c] else k = floor(idx) idx = idx + stride end
			local x, y, z = BX[k], BY[k], BZ[k]
			local vx, vy, vz = BVX[k], BVY[k], BVZ[k]
			local rmm = BR[k] or 0.6
			local st = BS[k] or 1
			local bt = BT[k] or 0
			-- (1.26.10c) its own colour: its blood type, and as light or dark as a drop that size (the chord through it)
			local key = bt * 10 + ChordClass(2 * rmm)
			if key ~= lastKey then
				render.SetMaterial(Mat(bt, 2 * rmm))
				lastKey = key
			end
			dropPos:SetUnpacked(x, y, z)
			local ru = max(rmm * MM, 0.045) * sizeMul
			local isHang = (vx == 0 and vy == 0 and vz == -1)
			if isHang and dripE and dripE.state == "ready" then
				local nf = #dripE.frames
				local f = math.Clamp(floor(((st - 1.0) / 0.85) * (nf - 1)) + 1, 1, nf)
				local m = dripE.meshes[f]
				if m then
					dropAng:SetUnpacked(0, (k * 53) % 360, 0)
					M:Identity()
					M:SetTranslation(dropPos)
					M:SetAngles(dropAng)
					local sr = ru * 1.35
					scaleV:SetUnpacked(sr, sr, sr * max(st * 0.85, 1.0))
					M:Scale(scaleV)
					cam.PushModelMatrix(M)
					m:Draw()
					cam.PopModelMatrix()
					drawn = drawn + 1
				end
			else
				local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
				local kindIdx
				if st > 1.55 or sp > 260 then kindIdx = 4
				elseif sp > 160 then kindIdx = 3
				elseif rmm > 1.3 then kindIdx = 2
				else kindIdx = 1 end
				local e = dropE[kindIdx] or dropE[1]
				if e and e.state == "ready" then
					local nf = #e.frames
					local f = (floor(now * e.fps * 1.45 + k * 3.7) % nf) + 1
					local m = e.meshes[f]
					if m then
						if sp > 1e-2 then
							dropVel:SetUnpacked(vx, vy, vz)
							dropAng = dropVel:Angle()
							dropAng.r = (k * 67 + now * 90) % 360
						else
							dropAng:SetUnpacked(0, (k * 67) % 360, 0)
						end
						local trail = min(sp * trailK / max(ru, 0.04), 3.8)
						local sx = ru * math.Clamp(st + trail * 0.65, 1.0, 5.5)
						local sr = ru * 1.18
						M:Identity()
						M:SetTranslation(dropPos)
						M:SetAngles(dropAng)
						scaleV:SetUnpacked(sx, sr, sr)
						M:Scale(scaleV)
						cam.PushModelMatrix(M)
						m:Draw()
						cam.PopModelMatrix()
						drawn = drawn + 1
					end
				end
			end
		end
	end)
	render.SetLocalModelLights()
	render.SuppressEngineLighting(false)
	V.stats.drops3d = drawn
	if not ok then ErrorNoHalt("[GHMPB] vat drops3d: " .. tostring(err) .. "\n") return false end
	return true
end

function V.Clear() V.inst = {} end

local lastCrown, crownCells = 0, {}
function V.OnEntry(pos, nrm, dir, S, btype, ent, bone)
	local d = (nrm * 0.45 - dir * 0.55)
	V.Spawn("back", pos + nrm * 0.3, d, 0.34 + 0.18 * math.min(S, 2.5), 2.35, btype, ent, bone)
end
function V.OnExit(pos, nrm, dir, S, btype, ent, bone)
	V.Spawn("fwd", pos + nrm * 0.3, dir * 0.85 + nrm * 0.15, 0.48 + 0.22 * math.min(S, 2.5), 2.15, btype, ent, bone)
end
function V.OnBlunt(pos, nrm, dir, S, btype, ent, bone)
	V.Spawn("blunt", pos + nrm * 0.3, nrm * 0.7 - dir * 0.3, 0.45 + 0.25 * math.min(S, 2), 2.0, btype, ent, bone)
end
function V.OnBlast(pos, dir, S, btype, ent, bone)
	local d = (dir and dir:LengthSqr() > 0.01) and dir:GetNormalized() or Vector(0, 0, 1)
	V.Spawn("heavy", pos, d, 0.9 + 0.35 * math.min(S, 2.5), 1.9, btype, ent, bone)
	V.Spawn("fwd", pos + d * 4, (d + Vector(0, 0, 0.35)):GetNormalized(), 0.75 + 0.28 * math.min(S, 2.5), 2.1, btype, ent, bone)
	V.Spawn("spray", pos + d * 2, d, 0.85 + 0.3 * math.min(S, 2.5), 1.85, btype, ent, bone)
end
function V.OnJet(e, pos, dir, jet, btype, ent, bone)
	local now = CurTime()
	if (e.vatT or 0) > now then return end
	e.vatT = now + 0.42
	V.Spawn("jet", pos, dir, math.Clamp(jet / 240, 0.35, 1.05), 1.95, btype, ent, bone or e.bone)
end
function V.OnSpray(pos, dir, amount, btype, ent, bone)
	if not V.On() or (amount or 0) <= 0.08 then return false end
	local d = (dir and dir:LengthSqr() > 0.01) and dir:GetNormalized() or Vector(0, 0, 1)
	local inst = V.Spawn("spray", pos, d, math.Clamp(0.32 + 0.35 * math.min(amount, 2.5), 0.28, 1.4), U.RandRange(1.65, 2.25), btype, ent, bone)
	return inst ~= nil
end
function V.OnDrip(pos, vel, rmm, btype, ent, bone)
	if not V.On() or not cvDrops:GetBool() then return end
	V.Spawn("drip", pos, Vector(0, 0, -1), math.Clamp((rmm or 1.5) * 0.14, 0.12, 0.45), 1.75, btype, ent, bone)
end
V.CROWNS = false
function V.OnDropLand(pos, n, rmm, speed, btype)
	-- (1.26.8) no splash crowns where blood lands any more (GHM: the "water ripple" after a headshot, big and small)
	if not V.CROWNS then return end
	-- (1.26.7) the splash crown where blood lands: the 1.26.2 rule again (drops from about 1.15 mm landing at 150 u/s or
	-- faster, at most one per spot every 0.65 s), scaled by the Splashes setting (0 = none, below 1 = fewer, above = more)
	local amt = G.cv.splash and G.cv.splash:GetFloat() or 1
	if not V.On() or amt <= 0 or n.z < 0.55 or rmm < 1.15 or speed < 150 then return end
	if amt < 1 and math.random() > amt then return end
	local now = CurTime()
	if now - lastCrown < 0.08 / math.min(amt, 2) / math.max(Detail(), 0.15) then return end
	local k = floor(pos.x / 10) .. ":" .. floor(pos.y / 10)
	if (crownCells[k] or 0) > now then return end
	crownCells[k] = now + 0.65 / math.min(math.max(amt, 1), 2)
	lastCrown = now
	V.Spawn("crown", pos + n * 0.05, n, math.Clamp(rmm / 2.2, 0.42, 1.65) * math.Clamp(speed / 360, 0.68, 1.35) * math.Clamp(0.75 + 0.25 * amt, 0.75, 1.5), 1.85, btype)
end

hook.Add("Think", "ghmpb_vat", function()
	if not V.On() then
		if next(V.effects) ~= nil and not cvOn:GetBool() then V.Free() end
		return
	end
	if CurTime() < 1.0 then return end
	if not V.warmDone then
		local more = V.Step(0.004)
		if not more then V.warmDone = true end
	end
end)
cvars.AddChangeCallback("ghmpb_vat", function(_, _, new)
	if tonumber(new) == 0 then V.Free() end
	V.warmDone = false
end, "ghmpb_vat")

function V.DrawPass()
	if #V.inst == 0 then return end
	local t = SysTime()
	local ok, err = pcall(V.Draw)
	if G.Prof then G.Prof.Lap("draw:vat", t) end
	if not ok then
		V.errors = (V.errors or 0) + 1
		if V.errors < 20 then ErrorNoHalt("[GHMPB] vat: " .. tostring(err) .. "\n") end
	end
end
hook.Add("PostDrawOpaqueRenderables", "ghmpb_vat", function(depth, sky, sky3d)
	if not G.ScenePass(depth, sky, sky3d) or #V.inst == 0 then return end
	if render.GetRenderTarget() ~= nil then return end
	V.drawnFrame = FrameNumber()
	V.DrawPass()
end)

concommand.Add("ghmpb_vat_info", function()
	local ready, total, frames = 0, 0, 0
	for _, e in pairs(V.effects) do
		total = total + 1
		if e.state == "ready" then ready = ready + 1 frames = frames + #e.frames end
	end
	MsgN(string.format("[GHMPB] VAT bursts: %s, data %s | effects ready %d of %d (%d frames) | playing %d | 3D drops %d | spawned %d, skipped %d, load errors %d",
		cvOn:GetBool() and "on" or "off", V.Installed() and "installed" or "not installed", ready, total, frames, #V.inst,
		V.stats.drops3d or 0, V.stats.spawned, V.stats.skipped, V.stats.loadErrors))
	for n, e in pairs(V.effects) do if e.err then MsgN("    " .. n .. ": " .. e.err) end end
end, nil, "GHM PhysBlood: the VAT blood bursts")

concommand.Add("ghmpb_vat_test", function(ply, _, args)
	local tr = LocalPlayer():GetEyeTrace()
	local kind = args[1] or "back"
	local pos = tr.HitPos + tr.HitNormal * 2
	local inst = V.Spawn(kind, pos, kind == "crown" and tr.HitNormal or (tr.HitNormal + Vector(0, 0, 0.3)), tonumber(args[2]) or 1, tonumber(args[3]) or 1, 0)
	MsgN("[GHMPB] vat test " .. kind .. ": " .. (inst and ("playing " .. inst.e.name) or "nothing ready (ghmpb_vat_info)"))
end, nil, "GHM PhysBlood: play a VAT burst where you look (kind: back, fwd, heavy, blunt, jet, crown, spray, drip, drop; size; speed)")
