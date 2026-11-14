local G = GHMPB
G.Budget = G.Budget or {}
local B = G.Budget

local MB = 1 / (1024 * 1024)
B.RESERVE = 24
B.SMALL_PER_BODY = 2
B.BODY_BYTES = 80
B.PATCH_BYTES = 72
B.AFT_BYTES = 4

function B.BodySizes(q)
	q = q or G.cv.quality:GetInt()
	if q <= 1 then return 256, 128 elseif q == 2 then return 384, 256 elseif q == 3 then return 512, 384 end
	return 640, 448
end

function B.PatchRes(q)
	q = q or G.cv.quality:GetInt()
	if q <= 1 then return 128 elseif q == 2 then return 256 elseif q == 3 then return 320 end
	return 512
end

function B.AftRes()
	local r = G.cv.aftres:GetInt()
	if r <= 160 then return 128 end
	return math.max(r <= 320 and 256 or 512, B.PatchRes())
end

function B.Costs(q)
	local big, small = B.BodySizes(q)
	local res = B.PatchRes(q)
	local ar = B.AftRes()
	local bodyTex = big * big + B.SMALL_PER_BODY * small * small
	return {
		ents = bodyTex * B.BODY_BYTES * MB,
		patches = res * res * B.PATCH_BYTES * MB,
		aft = ar * ar * B.AFT_BYTES * MB,
		aftb = bodyTex * B.AFT_BYTES * MB,
	}
end

local MIN = { ents = 2, patches = 8, aft = 16, aftb = 4 }
local ORDER = { "ents", "patches", "aft", "aftb" }

local function Requested()
	local aftOn = G.cv.aftermath:GetBool()
	return {
		ents = G.cv.maxents:GetInt(),
		patches = G.cv.maxpatches:GetInt(),
		aft = aftOn and G.cv.aftmax:GetInt() or 0,
		aftb = aftOn and G.cv.aftbodies:GetInt() or 0,
	}
end

local cache, cacheT, cacheKey = nil, 0, nil
function B.Caps()
	local now = RealTime()
	local key = G.cv.vram:GetInt() .. G.cv.quality:GetInt() .. G.cv.aftres:GetInt() .. G.cv.maxents:GetInt() .. "|"
		.. G.cv.maxpatches:GetInt() .. "|" .. G.cv.aftmax:GetInt() .. "|" .. G.cv.aftbodies:GetInt() .. (G.cv.aftermath:GetBool() and "a" or "")
	if cache and cacheKey == key and now - cacheT < 1 then return cache end
	local req = Requested()
	local cost = B.Costs()
	local need = B.RESERVE
	for _, k in ipairs(ORDER) do need = need + req[k] * cost[k] end
	local budget = math.max(G.cv.vram:GetInt(), 128)
	local caps = { needMB = need, budgetMB = budget, scale = 1 }
	if need <= budget then
		for _, k in ipairs(ORDER) do caps[k] = req[k] end
	else
		local s = (budget - B.RESERVE) / math.max(need - B.RESERVE, 1)
		caps.scale = s
		local used = B.RESERVE
		for _, k in ipairs(ORDER) do
			caps[k] = req[k] > 0 and math.max(math.min(MIN[k], req[k]), math.floor(req[k] * s)) or 0
			used = used + caps[k] * cost[k]
		end
		if used > budget and caps.aft > MIN.aft then
			caps.aft = math.max(MIN.aft, caps.aft - math.ceil((used - budget) / math.max(cost.aft, 1e-6)))
		end
	end
	cache, cacheT, cacheKey = caps, now, key
	return caps
end

B.made = B.made or { body = {}, patch = {}, aft = {} }

local function made(kind, size) return B.made[kind][size] or 0 end
function B.Count(kind, size) B.made[kind][size] = made(kind, size) + 1 end

function B.MayCreateBody(size)
	local caps = B.Caps()
	local big = B.BodySizes()
	local limit = (caps.ents + 2) * (size == big and 1 or 3)
	return made("body", size) < limit
end

-- (1.26.8) new render-target slots (a patch's or a body's: 8 to 10 render targets and their materials, several ms each)
-- a frame: as many as fit into 3 ms, at least one. A magazine dump over a fresh wall made up to 32 in one frame
-- (ghmpb_prof with the shaders: a frame of 43 ms in the world impacts, 51 ms in the wounds)
B.CREATE_MS = 6
local crF, crN, crMs = -1, 0, 0
function B.MayCreateNow()
	local f = FrameNumber()
	if f ~= crF then crF, crN, crMs = f, 0, 0 end
	return crN == 0 or crMs < B.CREATE_MS
end
function B.NoteCreated(ms)
	local f = FrameNumber()
	if f ~= crF then crF, crN, crMs = f, 0, 0 end
	crN, crMs = crN + 1, crMs + ms
	B.createdStats = B.createdStats or { n = 0, ms = 0, deferred = 0 }
	B.createdStats.n, B.createdStats.ms = B.createdStats.n + 1, B.createdStats.ms + ms
end
function B.NoteDeferred()
	B.createdStats = B.createdStats or { n = 0, ms = 0, deferred = 0 }
	B.createdStats.deferred = B.createdStats.deferred + 1
end

function B.MayCreatePatch(res)
	return made("patch", res) < B.Caps().patches + 6
end

function B.Allocated()
	local total = B.RESERVE
	for size, n in pairs(B.made.body) do total = total + n * size * size * B.BODY_BYTES * MB end
	for res, n in pairs(B.made.patch) do total = total + n * res * res * B.PATCH_BYTES * MB end
	for res, n in pairs(B.made.aft) do total = total + n * res * res * B.AFT_BYTES * MB end
	return total
end
