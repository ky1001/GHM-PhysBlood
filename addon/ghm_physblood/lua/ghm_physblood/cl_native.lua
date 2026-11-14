local G = GHMPB
G.Native = G.Native or {}
local N = G.Native
local mod = N.mod
local tried = N.tried or false
N.MODULES = { "ghmpb_native_v5", "ghmpb_native_v4", "ghmpb_native_v3", "ghmpb_native_v2", "ghmpb_native" }

local function Installed(name)
	if util.IsBinaryModuleInstalled then return util.IsBinaryModuleInstalled(name) end
	return file.Exists("lua/bin/gmcl_" .. name .. "_win" .. (jit.arch == "x64" and "64" or "32") .. ".dll", "GAME")
end

function N.Load()
	if tried then return mod ~= nil end
	tried = true
	N.tried = true
	local name
	for _, m in ipairs(N.MODULES) do if Installed(m) then name = m break end end
	if not name then
		print("[GHM PhysBlood] C++ module not installed - using the Lua droplet solver")
		return false
	end
	N.MODULE = name
	local ok = pcall(require, name)
	if ok and ghm_physblood and ghm_physblood.Version then
		mod = ghm_physblood
		N.mod = mod
		N.inPlace = name == "ghmpb_native_v5"
		N.oxyInData = name == "ghmpb_native_v5" or name == "ghmpb_native_v4"
		print("[GHM PhysBlood] C++ droplet solver loaded: " .. tostring(mod.Version()))
		return true
	end
	print("[GHM PhysBlood] C++ module not installed/loaded - using the Lua droplet solver")
	return false
end

function N.Available() return mod ~= nil end

function N.Spawn(o)
	local p, v = o.pos, o.vel
	local owner = IsValid(o.owner) and o.owner:EntIndex() or -1
	return mod.Spawn(p.x, p.y, p.z, v.x, v.y, v.z, o.r or 1, o.spin or 0, o.stretch or 1, owner,
		o.ownerGrace or 0.06, o.oxy or 0.75, o.btype or 0, o.broke and 1 or 0, o.flags or 0)
end

local traceData = { mask = MASK_SHOT, output = {} }
local flt = {}
traceData.filter = flt
local nBase = 0
local function BaseFilter()
	for k = #flt, 1, -1 do flt[k] = nil end
	nBase = 0
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local function add(e) if IsValid(e) then nBase = nBase + 1 flt[nBase] = e end end
	if not lp:ShouldDrawLocalPlayer() then add(lp) end
	add(lp:GetActiveWeapon())
	add(lp:GetViewModel())
	if lp.GetHands then add(lp:GetHands()) end
end
N.TRACE_MAX = 1600
N.TRACE_MS = 3

local shim = { pos = Vector(), vel = Vector() }
local segBuf = {}
function N.Step(dt)
	local g = GetConVarNumber("sv_gravity") or 600
	mod.Step(dt, 0, 0, -g)
	local ms = G.Gov and G.Gov.TraceMs() or N.TRACE_MS
	local want = math.Clamp(math.floor(ms / 1000 / math.max(N.costPer or 2e-5, 2e-6)), 100, N.TRACE_MAX)
	N.want = want
	local tSeg = SysTime()
	local seg, nseg
	if N.inPlace then
		nseg = mod.Segments(want, segBuf)
		seg = segBuf
	else
		seg = mod.Segments(want)
		nseg = seg and #seg or 0
	end
	if not seg or nseg == 0 then return end
	BaseFilter()
	local t0 = SysTime()
	tSeg = t0 - tSeg
	local tLand = 0
	local a, b = Vector(), Vector()
	local ownerEnt, ownerOk
	local traced = 0
	for i = 1, nseg, 10 do
		traced = traced + 1
		local id = seg[i]
		a:SetUnpacked(seg[i + 1], seg[i + 2], seg[i + 3])
		b:SetUnpacked(seg[i + 4], seg[i + 5], seg[i + 6])
		local oi = seg[i + 7]
		ownerEnt = oi >= 0 and Entity(oi) or nil
		ownerOk = seg[i + 8] >= seg[i + 9]
		flt[nBase + 1] = (not ownerOk and IsValid(ownerEnt)) and ownerEnt or nil
		traceData.start = a
		traceData.endpos = b
		local tr = util.TraceLine(traceData)
		local ct = G.U.TraceCorpses(a, tr.Hit and tr.HitPos or b, (not ownerOk) and ownerEnt or nil)
		if ct then tr = ct end
		if tr.Hit then
			local vx, vy, vz, r, spin, stretch, oxy, btype, _, flags = mod.Hit(id)
			if vx and not tr.HitSky and not tr.StartSolid then
				shim.vel:SetUnpacked(vx, vy, vz)
				shim.r, shim.spin, shim.stretch, shim.oxy, shim.btype, shim.flags = r, spin, stretch, oxy, btype, flags or 0
				shim.v = 4.18879 * r * r * r
				shim.owner = ownerEnt
				local tl = SysTime()
				G.Particles.Land(shim, tr)
				tLand = tLand + (SysTime() - tl)
			end
		elseif bit.band(util.PointContents(b), bit.bor(CONTENTS_WATER, CONTENTS_SLIME)) ~= 0 then
			local vx, vy, vz, r, _, _, oxy, btype = mod.Hit(id)
			if vx and G.Water then G.Water.EnterDrop(Vector(a), Vector(b), Vector(vx, vy, vz), 4.18879 * r * r * r, btype, oxy, r) end
		end
	end
	N.landMs = (N.landMs or 0) * 0.8 + tLand * 1000 * 0.2
	if traced >= 20 then
		local c = (SysTime() - t0 - tLand + tSeg) / traced
		N.costPer = N.costPer and (N.costPer * 0.8 + c * 0.2) or c
	end
end

function N.ForEachRender(fn)
	local d = mod.RenderData()
	if not d then return end
	for i = 1, #d, 8 do
		fn(Vector(d[i], d[i + 1], d[i + 2]), Vector(d[i + 3], d[i + 4], d[i + 5]), d[i + 6], d[i + 7])
	end
end

local renderBuf = {}
function N.RenderRaw()
	if N.inPlace then return renderBuf, mod.RenderData(renderBuf) end
	local d = mod.RenderData()
	return d, d and #d or 0
end
function N.Count() return mod.Count() end
function N.Clear() if mod then mod.Clear() end end
