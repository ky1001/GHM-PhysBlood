local G = GHMPB
G.MapLights = G.MapLights or {}
local M = G.MapLights

M.world = M.world or nil
M.cells = M.cells or {}
M.dyn = M.dyn or {}
M.stats = M.stats or { world = 0, dyn = 0, picks = 0, traces = 0 }
M.CELL = 512
M.REACH = 2048
local EMIT_POINT, EMIT_SPOT = 1, 2

local function ReadLights()
	local list = {}
	local ok, err = pcall(function()
		local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
		if not f then return end
		if f:Read(4) ~= "VBSP" then f:Close() return end
		local function Lump(k)
			f:Seek(8 + k * 16)
			return f:ReadLong() or 0, f:ReadLong() or 0, f:ReadLong() or 0
		end
		local ofs, len, ver = Lump(54)
		if len <= 0 then ofs, len, ver = Lump(15) end
		if len > 0 then
			local size = ver >= 1 and 100 or 88
			local n = math.min(math.floor(len / size), 8192)
			f:Seek(ofs)
			for _ = 1, n do
				local ox, oy, oz = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
				local ix, iy, iz = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
				local nx, ny, nz = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
				if size == 100 then f:Skip(12) end
				f:Skip(4)
				local typ = f:ReadLong()
				f:Skip(4)
				local stop, stop2, expo, radius = f:ReadFloat(), f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
				local ca, la, qa = f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
				f:Skip(12)
				if (typ == EMIT_POINT or typ == EMIT_SPOT) and ix and ix + iy + iz > 0 then
					list[#list + 1] = { pos = Vector(ox, oy, oz), col = Vector(ix, iy, iz), type = typ, dir = Vector(nx, ny, nz),
						stop = stop or 0, stop2 = stop2 or 0, expo = expo or 0, radius = radius or 0, ca = ca or 0, la = la or 0, qa = qa or 0,
						world = true, id = #list + 1 }
				end
			end
		end
		f:Close()
	end)
	if not ok then G.DiagCount("lights: the map's light lump could not be read") G.Diag.lastError = tostring(err) end
	return list
end

function M.World()
	if M.world then return M.world end
	M.world = ReadLights()
	M.cells = {}
	for _, l in ipairs(M.world) do
		local k = math.floor(l.pos.x / M.CELL) .. "," .. math.floor(l.pos.y / M.CELL) .. "," .. math.floor(l.pos.z / M.CELL)
		local c = M.cells[k]
		if not c then c = {} M.cells[k] = c end
		c[#c + 1] = l
	end
	M.stats.world = #M.world
	return M.world
end
hook.Add("InitPostEntity", "ghmpb_maplights", function() M.world = nil M.vis = {} end)

function M.Radiance(l, pos)
	local d = pos - l.pos
	local dist = d:Length()
	if l.radius > 0 and dist > l.radius then return 0 end
	local den = l.ca + l.la * dist + l.qa * dist * dist
	local scale = den > 1e-6 and 1 / den or 1 / math.max(dist * dist, 1)
	if l.type == EMIT_SPOT then
		local dot = d:Dot(l.dir) / math.max(dist, 1e-3)
		if dot <= l.stop2 then return 0 end
		if dot < l.stop then scale = scale * (dot - l.stop2) / math.max(l.stop - l.stop2, 1e-4) end
		if l.expo > 0 then scale = scale * math.max(dot, 0) ^ l.expo end
	end
	return scale
end

local FL_COS = math.cos(math.rad(28))
function M.Dynamic()
	local now = RealTime()
	if M.dynT and now - M.dynT < 0.5 then return M.dyn end
	M.dynT = now
	local list = {}
	local me = LocalPlayer()
	for _, ply in ipairs(player.GetAll()) do
		if ply ~= me and IsValid(ply) and ply:Alive() and ply.FlashlightIsOn and ply:FlashlightIsOn() and not ply:IsDormant() then
			list[#list + 1] = { pos = ply:EyePos(), dir = ply:EyeAngles():Forward(), cosO = FL_COS, range = 900, fb = 30000,
				col = Vector(1, 0.97, 0.92), key = "fl" .. ply:EntIndex() }
		end
	end
	for _, cls in ipairs({ "env_projectedtexture", "point_spotlight", "light_dynamic" }) do
		for _, e in ipairs(ents.FindByClass(cls)) do
			if IsValid(e) and not e:IsDormant() then
				local c = e:GetColor()
				local col = Vector((c.r or 255) / 255, (c.g or 255) / 255, (c.b or 255) / 255)
				if col.x + col.y + col.z > 0.05 then
					local spot = cls ~= "light_dynamic"
					list[#list + 1] = { pos = e:GetPos(), dir = e:GetForward(), cosO = spot and math.cos(math.rad(40)) or -1,
						range = spot and 1200 or 600, fb = spot and 30000 or 15000, col = col, key = cls .. e:EntIndex() }
				end
			end
		end
	end
	M.dyn = list
	M.stats.dyn = #list
	return list
end

M.vis = M.vis or {}
local trOut = {}
local trData = { mask = MASK_SOLID_BRUSHONLY, output = trOut }
local function Clear(key, from, to)
	local now = RealTime()
	local c = M.vis[key]
	if c and now - c.t < 3 and c.p:DistToSqr(from) < 64 then return c.v end
	trData.start, trData.endpos = from, to + (from - to):GetNormalized() * 6
	local tr = util.TraceLine(trData) or trOut
	M.stats.traces = M.stats.traces + 1
	local v = not tr.Hit or tr.Fraction > 0.98
	M.vis[key] = { t = now, p = Vector(from), v = v }
	return v
end

function M.Pick(pos, n, keyBase)
	n = n or 4
	if not G.cv.maplights or not G.cv.maplights:GetBool() then return {} end
	M.stats.picks = M.stats.picks + 1
	local cand = {}
	M.World()
	local r = math.ceil(M.REACH / M.CELL)
	local cx, cy, cz = math.floor(pos.x / M.CELL), math.floor(pos.y / M.CELL), math.floor(pos.z / M.CELL)
	for x = cx - r, cx + r do
		for y = cy - r, cy + r do
			for z = cz - 1, cz + 1 do
				local c = M.cells[x .. "," .. y .. "," .. z]
				if c then
					for _, l in ipairs(c) do
						local d2 = pos:DistToSqr(l.pos)
						if d2 < M.REACH * M.REACH then
							local s = M.Radiance(l, pos)
							if s > 0 then
								local rad = l.col * s
								local lum = rad.x * 0.2126 + rad.y * 0.7152 + rad.z * 0.0722
								cand[#cand + 1] = { l = l, lum = lum, rad = rad, d2 = d2 }
							end
						end
					end
				end
			end
		end
	end
	for _, l in ipairs(M.Dynamic()) do
		local d = pos - l.pos
		local dist = d:Length()
		if dist < l.range then
			local cone = l.cosO < -0.5 and 1 or math.Clamp((d:Dot(l.dir) / math.max(dist, 1e-3) - l.cosO) / math.max(1 - l.cosO, 1e-3) * 3, 0, 1)
			if cone > 0 then
				local fbRad = l.fb / math.max(dist * dist, 16) * (1 - dist / l.range) ^ 2 * cone
				cand[#cand + 1] = { l = l, lum = fbRad * 0.33, fb = fbRad, d2 = dist * dist }
			end
		end
	end
	table.sort(cand, function(a, b) return a.lum > b.lum end)
	local out = {}
	for _, c in ipairs(cand) do
		if #out >= n then break end
		local l = c.l
		if Clear((keyBase or "") .. (l.key or l.id), pos, l.pos) then
			local o = { pos = l.pos, range = l.world and (l.radius > 0 and l.radius or 4096) or l.range }
			if l.world then
				local m = math.max(c.rad.x, c.rad.y, c.rad.z, 1e-6)
				o.col = c.rad / m
				o.I = m * c.d2
				o.type = l.type == EMIT_SPOT and 2 or 1
				o.dir = l.dir
				o.cosO = l.type == EMIT_SPOT and math.max(l.stop2, -1) or -1
			else
				local m = math.max(l.col.x, l.col.y, l.col.z, 1e-6)
				o.col = l.col / m
				o.I = l.fb * m
				o.type = l.cosO < -0.5 and 1 or 3
				if o.type == 1 then o.I = o.I / 3 end
				o.dir = l.dir
				o.cosO = l.cosO
			end
			out[#out + 1] = o
		end
	end
	return out
end

function M.Describe()
	return string.format("lights: %d of the map (lump), %d dynamic / flashlights, %d picks, %d visibility traces",
		M.stats.world, M.stats.dyn, M.stats.picks, M.stats.traces)
end
