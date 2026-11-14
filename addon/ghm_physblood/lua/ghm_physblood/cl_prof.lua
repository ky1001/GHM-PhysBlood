local G = GHMPB
G.Prof = G.Prof or {}
local P = G.Prof
local SysTime = SysTime

P.cur = {}
P.cnt = {}
P.avg = P.avg or {}
P.cavg = P.cavg or {}
P.win = P.win or {}
P.last = P.last or {}
P.frame = P.frame or { avg = 16, win = {}, last = { avg = 16, max = 16, p90 = 16 } }

function P.Lap(name, t0)
	local t = SysTime()
	P.cur[name] = (P.cur[name] or 0) + (t - t0) * 1000
	return t
end

function P.Add(name, ms) P.cur[name] = (P.cur[name] or 0) + ms end
function P.Count(name, n) P.cnt[name] = (P.cnt[name] or 0) + (n or 1) end

function P.Time(name, f, ...)
	local t = SysTime()
	local a, b, c = f(...)
	P.cur[name] = (P.cur[name] or 0) + (SysTime() - t) * 1000
	return a, b, c
end

local WINDOW = 2
local winT0 = 0
local frameTimes = {}

local lastFrame = -1
function P.EndFrame()
	local f = FrameNumber()
	if f == lastFrame then return end
	lastFrame = f
	-- (1.26.8) the Lua memory made a frame (what the garbage collector has to clear: its work falls on whatever code is
	-- running when it steps in)
	local kb = collectgarbage("count")
	if P.lastKB and kb > P.lastKB then P.cnt["Lua KB made"] = (P.cnt["Lua KB made"] or 0) + (kb - P.lastKB) end
	P.lastKB = kb
	local total = 0
	for name, ms in pairs(P.cur) do
		if string.sub(name, 1, 1) ~= "." then total = total + ms end
	end
	P.cur["=total"] = total
	for name, ms in pairs(P.cur) do
		P.avg[name] = (P.avg[name] or ms) * 0.95 + ms * 0.05
		local w = P.win[name]
		if not w then w = { 0, 0, 0 } P.win[name] = w end
		w[1] = w[1] + ms
		if ms > w[2] then w[2] = ms end
	end
	for name, n in pairs(P.cnt) do
		P.cavg[name] = (P.cavg[name] or n) * 0.95 + n * 0.05
		local w = P.win["#" .. name]
		if not w then w = { 0, 0, 0 } P.win["#" .. name] = w end
		w[1] = w[1] + n
		if n > w[2] then w[2] = n end
	end
	local ft = math.min(RealFrameTime() * 1000, 250)
	P.frame.avg = P.frame.avg * 0.93 + ft * 0.07
	frameTimes[#frameTimes + 1] = ft
	P.frames = (P.frames or 0) + 1
	P.cur, P.cnt = {}, {}
	local now = RealTime()
	if now - winT0 >= WINDOW then
		local n = math.max(#frameTimes, 1)
		local last = {}
		for name, w in pairs(P.win) do last[name] = { w[1] / n, w[2] } end
		P.last = last
		local sum, mx = 0, 0
		for _, t in ipairs(frameTimes) do sum = sum + t if t > mx then mx = t end end
		table.sort(frameTimes)
		P.frame.last = { avg = sum / n, max = mx, p90 = frameTimes[math.max(1, math.floor(n * 0.9))] or mx, n = n }
		P.win = {}
		frameTimes = {}
		winT0 = now
		if P.OnWindow then pcall(P.OnWindow, P.frame.last, last) end
	end
end
hook.Add("PreRender", "ghmpb_prof", P.EndFrame)

function P.Report()
	local lines = {}
	local fl = P.frame.last
	lines[#lines + 1] = string.format("frame: avg %.1f ms (%.0f fps), 90%% %.1f ms, worst %.1f ms over %d frames",
		fl.avg, 1000 / math.max(fl.avg, 0.1), fl.p90, fl.max, fl.n or 0)
	local list = {}
	for name, v in pairs(P.last) do if string.sub(name, 1, 1) ~= "#" then list[#list + 1] = { name, v[1], v[2] } end end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	for _, e in ipairs(list) do lines[#lines + 1] = string.format("  %-22s %6.2f ms/frame  worst %6.2f", e[1], e[2], e[3]) end
	local cl = {}
	for name, v in pairs(P.last) do if string.sub(name, 1, 1) == "#" then cl[#cl + 1] = { string.sub(name, 2), v[1], v[2] } end end
	table.sort(cl, function(a, b) return a[1] < b[1] end)
	local parts = {}
	for _, e in ipairs(cl) do parts[#parts + 1] = string.format("%s %.1f", e[1], e[2]) end
	if #parts > 0 then lines[#lines + 1] = "  per frame: " .. table.concat(parts, ", ") end
	if G.Gov and G.Gov.Describe then lines[#lines + 1] = "  " .. G.Gov.Describe() end
	local ls = G.Particles and G.Particles.landStats
	if ls and ls.skipped > 0 then lines[#lines + 1] = string.format("  landings without a stain (time budget, small drops): %d", ls.skipped) end
	lines[#lines + 1] = string.format("  Lua memory: %.1f MB", collectgarbage("count") / 1024)
	-- (1.26.8) render-target slots made while playing (each a few ms) and how often a patch waited a frame for one
	local cs = G.Budget and G.Budget.createdStats
	if cs and cs.n > 0 then
		lines[#lines + 1] = string.format("  slots made while playing: %d (%.1f ms each), patches that waited a frame for one: %d", cs.n, cs.ms / cs.n, cs.deferred)
	end
	return lines
end

concommand.Add("ghmpb_prof", function()
	for _, l in ipairs(P.Report()) do print(l) end
end, nil, "GHM PhysBlood: where the blood's share of the frame goes (last 2 seconds)")

function P.Instrument()
	if P.instrumented then return end
	P.instrumented = true
	local function wrap(tbl, key, name)
		local f = tbl and tbl[key]
		if type(f) ~= "function" then return end
		tbl[key] = function(...)
			local t = SysTime()
			local a, b, c, d = f(...)
			P.cur[name] = (P.cur[name] or 0) + (SysTime() - t) * 1000
			P.cnt[name] = (P.cnt[name] or 0) + 1
			return a, b, c, d
		end
	end
	wrap(G.Entities, "Impact", ".body impacts")
	wrap(G.Surfaces, "Impact", ".world impacts")
	wrap(G.U, "SnapToMesh", ".snap to mesh")
	wrap(G.Particles, "Land", ".drop landings")
	wrap(G.Particles, "Spawn", ".drop spawns")
	wrap(G.Particles, "UpdateHang", ".hanging drops")
	wrap(G.Native, "Step", ".native step")
	wrap(G.Smear, "RequestProbe", ".probes")
end
