-- Minimal Garry's Mod server environment for running PhysBlood's server files under LuaJIT (dev test only).
local M = {}
_G.SERVER, _G.CLIENT = true, false

-- ------------------------------------------------------------------ math / string / table helpers
function math.Clamp(v, a, b) return v < a and a or (v > b and b or v) end
math.Round = math.Round or function(x, d) local m = 10 ^ (d or 0) return math.floor(x * m + 0.5) / m end
function string.Trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function table.Copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = type(v) == "table" and getmetatable(v) == nil and table.Copy(v) or v end
	return setmetatable(o, getmetatable(t))
end
function table.Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
function table.Empty(t) for k in pairs(t) do t[k] = nil end end
function isnumber(x) return type(x) == "number" end
function isstring(x) return type(x) == "string" end
function istable(x) return type(x) == "table" end
function isfunction(x) return type(x) == "function" end
function isbool(x) return type(x) == "boolean" end

-- ------------------------------------------------------------------ Vector
local V = {}
V.__index = V
local function Vec(x, y, z)
	if type(x) == "table" then return setmetatable({ x = x.x, y = x.y, z = x.z }, V) end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V)
end
_G.Vector = Vec
V.__add = function(a, b) return Vec(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vec(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return Vec(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
	if type(a) == "number" then return Vec(b.x * a, b.y * a, b.z * a) end
	if type(b) == "number" then return Vec(a.x * b, a.y * b, a.z * b) end
	return Vec(a.x * b.x, a.y * b.y, a.z * b.z)
end
V.__div = function(a, b) return Vec(a.x / b, a.y / b, a.z / b) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
V.__tostring = function(a) return string.format("(%.1f %.1f %.1f)", a.x, a.y, a.z) end
function V:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
function V:Length() return math.sqrt(self:LengthSqr()) end
function V:Length2DSqr() return self.x * self.x + self.y * self.y end
function V:DistToSqr(o) return (self - o):LengthSqr() end
function V:Distance(o) return (self - o):Length() end
function V:Dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:Cross(o) return Vec(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x) end
function V:GetNormalized() local l = self:Length() if l < 1e-9 then return Vec(0, 0, 0) end return self / l end
function V:Normalize() local n = self:GetNormalized() self.x, self.y, self.z = n.x, n.y, n.z end
function V:IsZero() return self.x == 0 and self.y == 0 and self.z == 0 end
function V:Mul(s) self.x, self.y, self.z = self.x * s, self.y * s, self.z * s end
function V:Add(o) self.x, self.y, self.z = self.x + o.x, self.y + o.y, self.z + o.z end
function V:Set(o) self.x, self.y, self.z = o.x, o.y, o.z end
function V:Unpack() return self.x, self.y, self.z end
function V:SetUnpacked(x, y, z) self.x, self.y, self.z = x, y, z end
function V:Angle() local d = self:GetNormalized() return { Forward = function() return d end } end
-- (Source angles: pitch down, yaw left; AngleVectors)
local A = {}
A.__index = A
function _G.Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
local function AV(a)
	local sp, cp = math.sin(math.rad(a.p)), math.cos(math.rad(a.p))
	local sy, cy = math.sin(math.rad(a.y)), math.cos(math.rad(a.y))
	local sr, cr = math.sin(math.rad(a.r)), math.cos(math.rad(a.r))
	return Vec(cp * cy, cp * sy, -sp), Vec(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp), Vec(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
end
function A:Forward() local f = AV(self) return f end
function A:Right() local _, r = AV(self) return r end
function A:Up() local _, _, u = AV(self) return u end
_G.vector_origin = Vec(0, 0, 0)
_G.angle_zero = { p = 0, y = 0, r = 0 }
function WorldToLocal(pos, ang, opos, oang) return pos - opos, ang end
function LocalToWorld(pos, ang, opos, oang) return pos + opos, ang end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
_G.color_white = Color(255, 255, 255)

-- ------------------------------------------------------------------ constants
local consts = {
	DONT_BLEED = -1, BLOOD_COLOR_RED = 0, BLOOD_COLOR_YELLOW = 1, BLOOD_COLOR_GREEN = 2, BLOOD_COLOR_MECH = 3,
	BLOOD_COLOR_ANTLION = 4, BLOOD_COLOR_ZOMBIE = 5, BLOOD_COLOR_ANTLION_WORKER = 6,
	DMG_GENERIC = 0, DMG_CRUSH = 1, DMG_BULLET = 2, DMG_SLASH = 4, DMG_BURN = 8, DMG_VEHICLE = 16, DMG_FALL = 32, DMG_BLAST = 64,
	DMG_CLUB = 128, DMG_SHOCK = 256, DMG_SONIC = 512, DMG_ENERGYBEAM = 1024, DMG_PREVENT_PHYSICS_FORCE = 2048, DMG_NEVERGIB = 4096,
	DMG_ALWAYSGIB = 8192, DMG_DROWN = 16384, DMG_PARALYZE = 32768, DMG_NERVEGAS = 65536, DMG_POISON = 131072, DMG_RADIATION = 262144,
	DMG_DROWNRECOVER = 524288, DMG_ACID = 1048576, DMG_SLOWBURN = 2097152, DMG_REMOVENORAGDOLL = 4194304, DMG_PHYSGUN = 8388608,
	DMG_PLASMA = 16777216, DMG_AIRBOAT = 33554432, DMG_DISSOLVE = 67108864, DMG_BLAST_SURFACE = 134217728, DMG_DIRECT = 268435456,
	DMG_BUCKSHOT = 536870912, DMG_SNIPER = 1073741824, DMG_MISSILEDEFENSE = 2147483648,
	HITGROUP_GENERIC = 0, HITGROUP_HEAD = 1, HITGROUP_CHEST = 2, HITGROUP_STOMACH = 3, HITGROUP_LEFTARM = 4, HITGROUP_RIGHTARM = 5,
	HITGROUP_LEFTLEG = 6, HITGROUP_RIGHTLEG = 7, FCVAR_ARCHIVE = 128, FCVAR_REPLICATED = 8192, FCVAR_NOTIFY = 256,
	MASK_SHOT = 1, MASK_SOLID_BRUSHONLY = 2, MASK_SOLID = 3, CONTENTS_WATER = 32, CONTENTS_SLIME = 16, CONTENTS_SOLID = 1,
}
for k, v in pairs(consts) do _G[k] = v end
local mats = { "MAT_ALIENFLESH", "MAT_ANTLION", "MAT_BLOODYFLESH", "MAT_CLIP", "MAT_COMPUTER", "MAT_CONCRETE", "MAT_DIRT", "MAT_EGGSHELL",
	"MAT_FLESH", "MAT_FOLIAGE", "MAT_GLASS", "MAT_GRASS", "MAT_GRATE", "MAT_METAL", "MAT_PLASTIC", "MAT_SAND", "MAT_SLOSH", "MAT_SNOW",
	"MAT_TILE", "MAT_VENT", "MAT_WARPSHIELD", "MAT_WOOD" }
for i, k in ipairs(mats) do _G[k] = 64 + i end

-- ------------------------------------------------------------------ time
M.now = 1
function CurTime() return M.now end
function RealTime() return M.now end
function SysTime() return M.now end

-- ------------------------------------------------------------------ output
M.log = {}
function MsgC(...) local t = {} for _, v in ipairs({ ... }) do if type(v) == "string" then t[#t + 1] = v end end M.log[#M.log + 1] = table.concat(t) end
function Msg(...) M.log[#M.log + 1] = table.concat({ ... }) end
function MsgN(...) Msg(...) end
M.errors = {}
function ErrorNoHalt(s) M.errors[#M.errors + 1] = s io.stderr:write("ErrorNoHalt: " .. tostring(s)) end

-- ------------------------------------------------------------------ convars
M.cvars = {}
local CV = {}
CV.__index = CV
function CV:GetBool() return (tonumber(self.v) or 0) ~= 0 end
function CV:GetInt() return math.floor(tonumber(self.v) or 0) end
function CV:GetFloat() return tonumber(self.v) or 0 end
function CV:GetString() return tostring(self.v) end
function CV:GetName() return self.name end
function CV:GetDefault() return self.def end
function CV:SetString(v) self.v = v end
function CV:SetInt(v) self.v = tostring(math.floor(v)) end
function CV:SetFloat(v) self.v = tostring(v) end
function CV:SetBool(v) self.v = v and "1" or "0" end
function CV:GetHelpText() return "" end
function CreateConVar(name, def, flags, help, mn, mx)
	local c = M.cvars[name]
	if c then return c end
	c = setmetatable({ name = name, def = def, v = def, mn = mn, mx = mx }, CV)
	M.cvars[name] = c
	return c
end
-- (client convars: name, default, save, userinfo, help, min, max)
function CreateClientConVar(name, def, save, userinfo, help, mn, mx) return CreateConVar(name, def, 0, help, mn, mx) end
function GetConVar(name) return M.cvars[name] end
M.cvcb = {}
_G.cvars = { AddChangeCallback = function(name, f) M.cvcb[name] = M.cvcb[name] or {} table.insert(M.cvcb[name], f) end }
function RunConsoleCommand(name, v)
	local c = M.cvars[name]
	if not c then return end
	local old = c.v
	v = tonumber(v) or v
	if c.mn and tonumber(v) then v = math.max(c.mn, v) end
	if c.mx and tonumber(v) then v = math.min(c.mx, v) end
	c.v = tostring(v)
	for _, f in ipairs(M.cvcb[name] or {}) do f(name, old, c.v) end
end
_G.concommand = { Add = function(name, f) M.cmds = M.cmds or {} M.cmds[name] = f end }

-- ------------------------------------------------------------------ hook (GMod semantics: stop at the first non-nil)
local H = {}
_G.hook = {}
function hook.Add(ev, id, f) H[ev] = H[ev] or {} H[ev][id] = f end
function hook.Remove(ev, id) if H[ev] then H[ev][id] = nil end end
function hook.GetTable() return H end
function hook.Call(ev, gm, ...)
	local t = H[ev]
	if t then
		-- deterministic order: the order the test asks for (M.hookOrder[ev]) first, then by id
		local ids = {}
		for id in pairs(t) do ids[#ids + 1] = id end
		local ord = M.hookOrder and M.hookOrder[ev] or {}
		local rank = {}
		for i, id in ipairs(ord) do rank[id] = i end
		table.sort(ids, function(a, b)
			local ra, rb = rank[a] or 1e9, rank[b] or 1e9
			if ra ~= rb then return ra < rb end
			return tostring(a) < tostring(b)
		end)
		for _, id in ipairs(ids) do
			local f = t[id]
			if f then
				local a, b, c = f(...)
				if a ~= nil then return a, b, c end
			end
		end
	end
	if gm and gm[ev] then return gm[ev](gm, ...) end
end
function hook.Run(ev, ...) return hook.Call(ev, nil, ...) end
-- (1.17.0: the engine keeps the hook library's Call it got first - measured in game: replacing the global hook.Call
-- afterwards is never seen by engine events)
function M.Engine(ev, ...)
	M.engineCall = M.engineCall or _G.hook.Call
	return M.engineCall(ev, nil, ...)
end

-- ------------------------------------------------------------------ timers
M.timers = {}
_G.timer = {}
function timer.Simple(d, f) table.insert(M.timers, { t = M.now + d, f = f }) end
function timer.Create(name, d, reps, f) M.timers[name] = { t = M.now + d, d = d, reps = reps, f = f } end
function timer.Remove(name) M.timers[name] = nil end
function timer.Exists(name) return M.timers[name] ~= nil end
function M.Advance(dt)
	local target = M.now + dt
	while true do
		local best, bk
		for k, t in pairs(M.timers) do if t.t <= target and (not best or t.t < best.t) then best, bk = t, k end end
		if not best then break end
		M.now = math.max(M.now, best.t)
		if type(bk) == "number" then M.timers[bk] = nil best.f()
		else
			if best.reps == 1 then M.timers[bk] = nil else best.t = best.t + best.d end
			best.f()
		end
		M.Engine("Think")
	end
	M.now = target
	M.Engine("Think")
end

-- ------------------------------------------------------------------ net
M.sent = {}
local cur
_G.net = { Receivers = {} }
function net.Start(name) cur = { name = name, data = {} } end
for _, k in ipairs({ "Entity", "Vector", "Normal", "Float", "UInt", "Int", "Bool", "String", "Matrix", "Angle" }) do
	net["Write" .. k] = function(v) table.insert(cur.data, v) end
end
local function finish(to) cur.to = to M.sent[#M.sent + 1] = cur cur = nil end
function net.Broadcast() finish("all") end
function net.Send(rf)
	if type(rf) == "table" and rf.GetPlayers then finish(rf:GetPlayers()) else finish(rf) end
end
function net.SendPVS() finish("pvs") end
function net.Receive(name, f) net.Receivers[string.lower(name)] = f end
M.readq = {}
for _, k in ipairs({ "Entity", "Vector", "Normal", "Float", "UInt", "Int", "Bool", "String", "Matrix", "Angle" }) do
	net["Read" .. k] = function() return table.remove(M.readq, 1) end
end
function M.Recv(name, ply, ...) M.readq = { ... } net.Receivers[name](0, ply) end
function M.SentOf(name) local o = {} for _, m in ipairs(M.sent) do if m.name == name then o[#o + 1] = m end end return o end

-- ------------------------------------------------------------------ entities
M.ents = {}
local E = {}
E.__index = E
_G.NULL = setmetatable({ valid = false, class = "NULL" }, E)
local nextIdx = 1
function M.Ent(class, o)
	o = o or {}
	o.class, o.valid, o.idx = class, true, nextIdx
	o.nw2, o.nwe = {}, {}
	o.pos = o.pos or Vec(0, 0, 0)
	o.health = o.health or 100
	o.bc = o.bc or BLOOD_COLOR_RED
	o.model = o.model or "models/humans/group01/male_02.mdl"
	nextIdx = nextIdx + 1
	setmetatable(o, E)
	M.ents[#M.ents + 1] = o
	return o
end
function IsValid(e) return e ~= nil and type(e) == "table" and e.valid == true end
function E:IsValid() return self.valid end
function E:IsPlayer() return self.class == "player" end
function E:IsNPC() return string.sub(self.class, 1, 4) == "npc_" end
function E:IsNextBot() return false end
function E:IsRagdoll() return self.class == "prop_ragdoll" end
function E:IsWorld() return false end
function E:GetClass() return self.class end
function E:GetModel() return self.model end
function E:EntIndex() return self.idx end
function E:GetBloodColor() return self.bc end
function E:SetBloodColor(c) self.bc = c end
function E:GetNW2Int(k, d) local v = self.nw2[k] if v == nil then return d end return v end
function E:SetNW2Int(k, v) self.nw2[k] = v end
function E:GetNW2Bool(k, d) local v = self.nw2[k] if v == nil then return d end return v end
function E:SetNW2Bool(k, v) self.nw2[k] = v end
function E:GetNWEntity(k, d) return self.nwe[k] or d or NULL end
function E:SetNWEntity(k, v) self.nwe[k] = v end
function E:Health() return self.health end
function E:SetHealth(h) self.health = h end
function E:GetPos() return Vec(self.pos) end
function E:WorldSpaceCenter() return self.pos + Vec(0, 0, 36) end
function E:BoundingRadius() return 36 end
function E:GetVelocity() return self.vel or Vec(0, 0, 0) end
function E:LastHitGroup() return self.hg or 0 end
function E:GetBoneCount() return 3 end
function E:GetHitboxSet() return 0 end
function E:GetHitBoxCount() return 2 end
function E:GetHitBoxBone(h) return h end
function E:GetBonePosition(b) return self.pos + Vec(0, 0, 20 * (b + 1)), angle_zero end
function E:Alive() return self.alive ~= false end
function E:TestPVS() return true end
function E:GetViewEntity() return self end
function E:EyePos() return self.pos + Vec(0, 0, 64) end
function E:GetShootPos() return self:EyePos() end
function E:IsSuperAdmin() return self.superadmin == true end
function E:IsListenServerHost() return self.host == true end
function E:Nick() return "player" .. self.idx end
function E:Remove() self.valid = false end
function E:IsDormant() return false end
_G.ents = { GetAll = function() local o = {} for _, e in ipairs(M.ents) do if e.valid then o[#o + 1] = e end end return o end }
_G.player = {
	GetAll = function() local o = {} for _, e in ipairs(M.ents) do if e.valid and e.class == "player" then o[#o + 1] = e end end return o end,
}
player.GetHumans = player.GetAll

-- ------------------------------------------------------------------ damage
local D = {}
D.__index = D
function M.Dmg(o) return setmetatable({ amount = o.amount or 30, type = o.type or DMG_BULLET, pos = o.pos or Vec(0, 0, 40),
	force = o.force or Vec(1000, 0, 0), att = o.att or NULL, inf = o.inf or NULL }, D) end
function D:GetDamage() return self.amount end
function D:SetDamage(v) self.amount = v end
function D:ScaleDamage(s) self.amount = self.amount * s end
function D:GetDamageType() return self.type end
function D:SetDamageType(t) self.type = t end
function D:GetDamagePosition() return self.pos end
function D:GetReportedPosition() return Vec(0, 0, 0) end
function D:GetDamageForce() return self.force end
function D:GetAttacker() return self.att end
function D:GetInflictor() return self.inf end
function D:IsDamageType(t) return bit.band(self.type, t) ~= 0 end

-- ------------------------------------------------------------------ recipients (everyone sees everything unless told)
function RecipientFilter()
	local rf = { pl = {} }
	function rf:AddPVS(pos)
		for _, p in ipairs(player.GetAll()) do
			if not M.pvs or M.pvs(p, pos) then self.pl[p] = true end
		end
	end
	function rf:AddPlayer(p) self.pl[p] = true end
	function rf:AddAllPlayers() for _, p in ipairs(player.GetAll()) do self.pl[p] = true end end
	function rf:RemovePlayer(p) self.pl[p] = nil end
	function rf:GetPlayers() local o = {} for p in pairs(self.pl) do o[#o + 1] = p end return o end
	return rf
end

-- ------------------------------------------------------------------ world: a flat floor at z = 0
_G.util = {}
function util.AddNetworkString() end
function util.TraceLine(t)
	local s, e = t.start, t.endpos
	if s.z >= 0 and e.z < 0 then
		local f = s.z / (s.z - e.z)
		return { Hit = true, HitPos = s + (e - s) * f, HitNormal = Vec(0, 0, 1), Fraction = f, HitWorld = true }
	end
	if M.wallX and s.x < M.wallX and e.x >= M.wallX then
		local f = (M.wallX - s.x) / (e.x - s.x)
		return { Hit = true, HitPos = s + (e - s) * f, HitNormal = Vec(-1, 0, 0), Fraction = f, HitWorld = true }
	end
	return { Hit = false, HitPos = e, HitNormal = Vec(0, 0, 0), Fraction = 1 }
end
function util.PointContents() return 0 end
M.decals, M.effects = 0, 0
function util.Decal() M.decals = M.decals + 1 end
function util.Effect() M.effects = M.effects + 1 end
function util.GetModelInfo() return nil end
_G.game = { SinglePlayer = function() return M.sp == true end, GetMap = function() return "test" end }
M.addons = {}
_G.engine = { GetAddons = function() return M.addons end, TickCount = function() return math.floor((M.now or 0) * 66) end }
M.res = {}
_G.resource = { AddWorkshop = function(id) M.res[#M.res + 1] = "ws:" .. id end, AddFile = function(f) M.res[#M.res + 1] = f end }
_G.file = { Find = function() return {}, {} end, Exists = function() return false end }
function AddCSLuaFile() end

_G.ConVarExists = _G.ConVarExists or function() return false end
_G.GetConVarNumber = _G.GetConVarNumber or function() return 0 end
_G.GetConVarString = _G.GetConVarString or function() return "" end
-- ------------------------------------------------------------------ loading the addon's files
-- (run from this folder: the project layout, or the release package's)
M.base = os.getenv("GHMPB_LUA")
for _, b in ipairs({ "../../addon/ghm_physblood/lua/ghm_physblood/", "../../../garrysmod/addons/ghm_physblood/lua/ghm_physblood/" }) do
	if not M.base then local f = io.open(b .. "sv_core.lua") if f then f:close() M.base = b end end
end
function include(f) return dofile(M.base .. f) end
function M.Load(list) for _, f in ipairs(list) do dofile(M.base .. f) end end

return M
