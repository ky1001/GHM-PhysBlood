-- The bridge to the C++ drop solver (client): the v5 module fills two tables in place; older modules hand back new
-- tables; landings still go through G.Particles.Land
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function LocalPlayer() return NULL end
function GetConVarNumber() return 600 end
function Entity() return NULL end

local function Fake(version)
	local drops = {}
	local calls = { seg = 0, segNew = 0, rd = 0, rdNew = 0 }
	local m = { calls = calls }
	function m.Version() return version end
	function m.Spawn(x, y, z) drops[#drops + 1] = { id = #drops + 1, x = x, y = y, z = z, alive = true } return #drops end
	function m.Step() end
	function m.Count() local n = 0 for _, d in ipairs(drops) do if d.alive then n = n + 1 end end return n end
	function m.Clear() drops = {} end
	function m.Segments(max, tbl)
		calls.seg = calls.seg + 1
		local t = tbl or {}
		if not tbl then calls.segNew = calls.segNew + 1 end
		local i = 0
		for _, d in ipairs(drops) do
			if d.alive then
				for _, v in ipairs({ d.id, d.x, d.y, d.z + 10, d.x, d.y, d.z - 10, -1, 0, 0 }) do i = i + 1 t[i] = v end
			end
		end
		if tbl then return i end
		return t
	end
	function m.Hit(id) drops[id].alive = false return 0, 0, -100, 1, 0, 1, 0.7, 0, -1, 0 end
	function m.RenderData(tbl)
		calls.rd = calls.rd + 1
		local t = tbl or {}
		if not tbl then calls.rdNew = calls.rdNew + 1 end
		local i = 0
		for _, d in ipairs(drops) do
			if d.alive then for _, v in ipairs({ d.x, d.y, d.z, 0, 0, -1, 1, 1 }) do i = i + 1 t[i] = v end end
		end
		if tbl then return i end
		return t
	end
	return m
end

local function Run(modName)
	local fake = Fake(modName)
	package.loaded[modName] = nil
	package.preload[modName] = function() _G.ghm_physblood = fake return true end
	_G.util.IsBinaryModuleInstalled = function(n) return n == modName end
	local lands = 0
	G.Particles = { Land = function() lands = lands + 1 end }
	G.U = { TraceCorpses = function() return nil end }
	_G.util.TraceLine = function(td) return { Hit = true, HitPos = td.endpos, HitNormal = Vector(0, 0, 1) } end
	_G.util.PointContents = function() return 0 end
	G.Native = nil
	M.Load({ "cl_native.lua" })
	local N = G.Native
	check(N.Load() and N.MODULE == modName, modName .. ": loaded")
	for i = 1, 5 do N.Spawn({ pos = Vector(i, 0, 50), vel = Vector(0, 0, -10) }) end
	N.Step(0.1)
	check(lands == 5, modName .. ": the 5 drops' segments traced and landed (" .. lands .. ")")
	for i = 1, 3 do N.Spawn({ pos = Vector(i, 0, 50), vel = Vector(0, 0, -10) }) end
	local d, n = N.RenderRaw()
	check(n == 3 * 8 and d[1] == 1 and d[17] == 3, modName .. ": render data of the 3 drops in flight (" .. tostring(n) .. ")")
	-- fewer drops next frame: the count says where the frame's data ends
	N.Step(0.1)
	local d2, n2 = N.RenderRaw()
	check(n2 == 0, modName .. ": all landed - no render data (" .. tostring(n2) .. ")")
	return fake.calls, d, d2
end
local c5, a5, b5 = Run("ghmpb_native_v5")
check(c5.segNew == 0 and c5.rdNew == 0, "v5: no new tables (segments " .. c5.seg .. " calls, render " .. c5.rd .. " calls)")
check(a5 == b5, "v5: the same render table every frame")
check(G.Native.inPlace and G.Native.oxyInData, "v5: in place, oxygen level in the data")
local c4 = Run("ghmpb_native_v4")
check(c4.segNew == c4.seg and c4.rdNew == c4.rd, "v4: new tables as before")
check(not G.Native.inPlace and G.Native.oxyInData, "v4: not in place, oxygen level in the data")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
