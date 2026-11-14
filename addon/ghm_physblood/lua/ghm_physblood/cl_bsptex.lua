local G = GHMPB
G.BspTex = G.BspTex or {}
local B = G.BspTex

local function Norm(name) return string.lower(string.gsub(name or "", "\\", "/")) end
B.Norm = Norm

local SKIP = bit.bor(0x2, 0x4, 0x80, 0x100, 0x200, 0x40)
local BUDGET = 0.004

local function Reader()
	local map = game.GetMap()
	local f = file.Open("maps/" .. map .. ".bsp", "rb", "GAME")
	if not f then error("the map file can not be opened") end
	if f:Read(4) ~= "VBSP" then f:Close() error("not a VBSP map file") end
	local version = f:ReadLong()
	local lumps = {}
	for i = 0, 63 do lumps[i] = { ofs = f:ReadLong(), len = f:ReadLong(), ver = f:ReadLong(), unc = f:ReadLong() } end
	local function lump(i, alt)
		local l = lumps[i]
		if (not l or l.len <= 0) and alt then l = lumps[alt] end
		if not l or l.len <= 0 then return nil end
		if l.unc ~= 0 then error("lump " .. i .. " is compressed") end
		return l
	end
	local t0 = SysTime()
	local function tick()
		if SysTime() - t0 > BUDGET then coroutine.yield() t0 = SysTime() end
	end

	local lp = lump(1) or error("no planes")
	local planes = {}
	f:Seek(lp.ofs)
	for i = 0, math.floor(lp.len / 20) - 1 do
		local nx, ny, nz, d = f:ReadFloat(), f:ReadFloat(), f:ReadFloat(), f:ReadFloat()
		f:ReadLong()
		planes[i] = { nx, ny, nz, d }
		if i % 512 == 0 then tick() end
	end
	local ls, lt = lump(43) or error("no texture names"), lump(44) or error("no texture name table")
	f:Seek(ls.ofs)
	local sdata = f:Read(ls.len) or ""
	f:Seek(lt.ofs)
	local nameAt = {}
	for i = 0, math.floor(lt.len / 4) - 1 do nameAt[i] = f:ReadLong() end
	local function name(id)
		local o = nameAt[id]
		if not o then return "" end
		local e = string.find(sdata, "\0", o + 1, true)
		return Norm(string.sub(sdata, o + 1, (e or (#sdata + 1)) - 1))
	end
	local ld = lump(2) or error("no texture data")
	local texdata = {}
	f:Seek(ld.ofs)
	for i = 0, math.floor(ld.len / 32) - 1 do
		f:Skip(12)
		local nid, w, h = f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Skip(8)
		texdata[i] = { name = name(nid), w = math.max(w, 1), h = math.max(h, 1) }
	end
	tick()
	local li = lump(6) or error("no texinfo")
	local texinfo = {}
	f:Seek(li.ofs)
	for i = 0, math.floor(li.len / 72) - 1 do
		local v = {}
		for k = 1, 16 do v[k] = f:ReadFloat() end
		local flags, td = f:ReadLong(), f:ReadLong()
		local tdd = texdata[td]
		if tdd and bit.band(flags, SKIP) == 0 then
			local w, h = tdd.w, tdd.h
			local l0 = math.sqrt(v[9] * v[9] + v[10] * v[10] + v[11] * v[11])
			local l1 = math.sqrt(v[13] * v[13] + v[14] * v[14] + v[15] * v[15])
			texinfo[i] = { name = tdd.name,
				s = Vector(v[1] / w, v[2] / w, v[3] / w), so = v[4] / w, t = Vector(v[5] / h, v[6] / h, v[7] / h), to = v[8] / h,
				l0 = { v[9], v[10], v[11], v[12] }, l1 = { v[13], v[14], v[15], v[16] },
				lu0 = l0 > 1e-6 and 1 / l0 or 16, lu1 = l1 > 1e-6 and 1 / l1 or 16 }
		end
		if i % 256 == 0 then tick() end
	end
	local lf = lump(7, 58) or error("no faces")
	local byTex = {}
	f:Seek(lf.ofs)
	local n = 0
	for i = 0, math.floor(lf.len / 56) - 1 do
		local pn = f:ReadShort()
		if pn < 0 then pn = pn + 65536 end
		local side = f:ReadByte()
		f:Skip(1)
		f:Skip(4)
		f:Skip(2)
		local ti = f:ReadShort()
		local disp = f:ReadShort()
		f:Skip(2 + 4 + 4 + 4)
		local m0, m1, s0, s1 = f:ReadLong(), f:ReadLong(), f:ReadLong(), f:ReadLong()
		f:Skip(4 + 2 + 2 + 4)
		local tinfo = texinfo[ti]
		local pl = planes[pn]
		if pl and side ~= 0 then pl = { -pl[1], -pl[2], -pl[3], -pl[4] } end
		if tinfo and pl then
			local list = byTex[tinfo.name]
			if not list then list = {} byTex[tinfo.name] = list end
			list[#list + 1] = { pl = pl, ti = tinfo, disp = disp >= 0, m0 = m0, m1 = m1, s0 = s0, s1 = s1 }
			n = n + 1
		end
		if i % 256 == 0 then tick() end
	end
	f:Close()
	B.byTex, B.faces, B.version = byTex, n, version
end

function B.Start()
	if B.state then return end
	B.state = "loading"
	B.co = coroutine.create(function()
		local ok, err = pcall(Reader)
		if ok then B.state = "ready" else B.state = "failed" B.err = tostring(err) end
		MsgN("[GHMPB] surface normal maps: " .. (ok and (B.faces .. " faces of the map read") or ("off on this map - " .. B.err)))
	end)
	hook.Add("Think", "ghmpb_bsptex", function()
		if not B.co or coroutine.status(B.co) == "dead" then hook.Remove("Think", "ghmpb_bsptex") B.co = nil return end
		local ok, err = coroutine.resume(B.co)
		if not ok then B.state = "failed" B.err = tostring(err) B.co = nil hook.Remove("Think", "ghmpb_bsptex") end
	end)
end
hook.Add("InitPostEntity", "ghmpb_bsptex", function() B.state, B.byTex, B.co = nil, nil, nil end)

function B.Lookup(pos, n, texName)
	if B.state ~= "ready" or not B.byTex then return nil end
	local list = B.byTex[Norm(texName)]
	if not list then return nil end
	local best, bs
	local px, py, pz = pos.x, pos.y, pos.z
	for k = 1, #list do
		local fc = list[k]
		local pl = fc.pl
		local dn = pl[1] * n.x + pl[2] * n.y + pl[3] * n.z
		local dd = math.abs(pl[1] * px + pl[2] * py + pl[3] * pz - pl[4])
		if (fc.disp and dn > 0.2) or (not fc.disp and dn > 0.95 and dd < 4) then
			local ti = fc.ti
			local l0, l1 = ti.l0, ti.l1
			local a = l0[1] * px + l0[2] * py + l0[3] * pz + l0[4] - fc.m0
			local b = l1[1] * px + l1[2] * py + l1[3] * pz + l1[4] - fc.m1
			local out = (fc.s0 > 0 or fc.s1 > 0) and (math.max(0, -a, a - fc.s0) * ti.lu0 + math.max(0, -b, b - fc.s1) * ti.lu1) or 8
			local score = out + (fc.disp and 0 or dd)
			if not bs or score < bs then best, bs = fc, score end
		end
	end
	if not best or bs > 48 then return nil end
	return best.ti
end
