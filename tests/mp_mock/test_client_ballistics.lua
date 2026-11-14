-- (1.26.6, 27 Oct) bullets by ammunition: class from damage type / weapon / damage, whether they go through, and the exit
-- plume that carries blood to the walls and floor behind the body (client, mocked GMod)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua", "cl_util.lua" })
local G = GHMPB
function EyePos() return Vector(0, -100, 64) end
function FrameNumber() return 1 end
function LocalPlayer() return NULL end
_G.game.GetAmmoName = function(i) return ({ [1] = "Pistol", [2] = "SMG1", [3] = "357", [4] = "SniperRound", [5] = "XBowBolt", [6] = "AR2",
	-- Z-City's ammunition
	[7] = "7.62x25 mm", [8] = ".22 Long Rifle", [9] = "5.7x28 mm", [10] = "12/70 gauge", [11] = ".338 Lapua Magnum", [12] = "7.62x39 mm",
	[13] = "9x19 mm Parabellum", [14] = ".50 Action Express", [15] = "14.5x114mm B32", [16] = "5.45x39 mm", [17] = "7.62x54 mm",
	[18] = ".44 Remington Magnum", [19] = "4.6x30 mm", [20] = "12/70 Slug" })[i] end
local hits, drops = {}, {}
G.Surfaces = { Impact = function(pos, n, vel, R, vol, kind, spin, stretch, residue, tr, oxy, btype, extra)
	hits[#hits + 1] = { pos = pos, n = n, R = R, vol = vol, stretch = stretch, btype = btype, t = M.now } return true end,
	IsGround = function() return true end }
G.Entities = { Impact = function() return true end }
G.Particles = { Spawn = function(o) drops[#drops + 1] = o end, Thin = function() return 1 end, Count = function() return 0 end }
M.Load({ "cl_spatterdata.lua", "cl_crbdata.lua", "cl_crbtypes.lua", "cl_forensic.lua" })
local F = G.Forensic

local function Wep(class, ammo)
	local w = M.Ent(class)
	function w:GetPrimaryAmmoType() return ammo end
	local a = M.Ent("player")
	function a:GetActiveWeapon() return w end
	return a
end
-- ---------------- classes
local function C(dmg, dt, att) local _, e, c = F.Ballistic(dmg, dt, att) return c, e end
check(C(18, DMG_BULLET) == "pistol", "18 damage, no weapon known: pistol")
check(C(34, DMG_BULLET) == "rifle", "34 damage: rifle")
check(C(130, DMG_BULLET) == "sniper", "130 damage: sniper")
check(C(9, DMG_BUCKSHOT) == "buckshot", "buckshot damage type: buckshot")
check(C(40, DMG_SNIPER) == "sniper", "sniper damage type: sniper")
check(C(40, DMG_BULLET, Wep("weapon_357", 3)) == "magnum", "the .357 revolver: magnum")
check(C(12, DMG_BULLET, Wep("weapon_pistol", 1)) == "pistol", "the pistol: pistol")
check(C(11, DMG_BULLET, Wep("weapon_ar2", 6)) == "rifle", "the AR2: rifle (even at low damage)")
check(C(100, DMG_BULLET, Wep("weapon_crossbow", 5)) == "sniper", "the crossbow: sniper")
check(C(50, DMG_BULLET, Wep("arc9_ak47", 2)) == "rifle", "a weapon pack rifle on SMG1 ammunition with 50 damage: rifle")
check(C(30, DMG_BULLET, Wep("weapon_shotgun", -1)) == "buckshot", "a shotgun without ammo type: buckshot by its name")
-- (1.26.7) Z-City's rounds
local zc = { [7] = "pistol", [8] = "pistol", [9] = "pistol", [10] = "buckshot", [11] = "sniper", [12] = "rifle", [13] = "pistol",
	[14] = "magnum", [15] = "sniper", [16] = "rifle", [17] = "sniper", [18] = "magnum", [19] = "pistol", [20] = "magnum" }
local zbad = {}
for id, want in pairs(zc) do
	local got = C(20, DMG_BULLET, Wep("weapon_hg_test", id))
	if got ~= want then zbad[#zbad + 1] = game.GetAmmoName(id) .. " -> " .. got end
end
check(#zbad == 0, "Z-City ammunition classed right (" .. table.concat(zbad, ", ") .. ")")
local _, eLo = C(10, DMG_BULLET, Wep("weapon_pistol", 1))
local _, eHi = C(45, DMG_BULLET, Wep("weapon_357", 3))
check(eLo >= 0.7 and eLo < 1 and eHi > 0.85 and eHi <= 1.6, string.format("energy within the class (%.2f, %.2f)", eLo, eHi))

-- ---------------- going through
local function rate(prof, region, dist) local n = 0 for _ = 1, 4000 do if F.Exits(prof, region, dist) then n = n + 1 end end return n / 4000 end
local B = F.BALLISTIC
check(rate(B.rifle, "chest") == 1 and rate(B.sniper, "abdomen") == 1 and rate(B.magnum, "chest") == 1, "rifles, magnums, snipers always go through")
local pt, pl = rate(B.pistol, "chest"), rate(B.pistol, "thigh")
check(pt > 0.68 and pt < 0.82 and pl > 0.9, string.format("pistol: torso %.2f, limbs %.2f", pt, pl))
local bc, bf = rate(B.buckshot, "chest", 80), rate(B.buckshot, "chest", 1500)
check(bc > 0.35 and bf < 0.15, string.format("buckshot through the torso: close %.2f, far %.2f", bc, bf))

-- ---------------- exit plume: a wall 1.3 m (70 u) behind the body
local lastArea = 0
local function Plume(cls, wallX, head)
	hits, drops = {}, {}
	M.wallX = wallX
	M.now = M.now + 10
	local n = F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), B[cls], 1, 0, 0.8, 1, head)
	local before = #hits
	M.Advance(1)
	local wall, floor, maxR, area = 0, 0, 0, 0
	for _, h in ipairs(hits) do
		if h.n.x < -0.5 then wall = wall + 1 maxR = math.max(maxR, h.R) if h.R < 4 then area = area + h.R * h.R end elseif h.n.z > 0.5 then floor = floor + 1 end
	end
	lastArea = area
	return n, before, wall, floor, maxR, #drops
end
local n1, b1, w1, f1, r1 = Plume("pistol", 70)
local a1 = lastArea
print(string.format("     pistol: %d streams, wall %d stains (largest %.2f u), floor %d", n1, w1, r1, f1))
check(b1 == 0 and w1 > 0, "pistol: stains land on the wall behind, after their flight (not at once)")
local n2, _, w2, f2, r2, d2 = Plume("rifle", 70)
local a2 = lastArea
local n3, _, w3, f3, r3, d3 = Plume("sniper", 70)
local a3 = lastArea
print(string.format("     blood on the wall (sum of r^2): pistol %.0f, rifle %.0f, sniper %.0f", a1, a2, a3))
print(string.format("     rifle: %d streams, wall %d (largest %.2f u); sniper: %d streams, wall %d (largest %.2f u), %d chunks", n2, w2, r2, n3, w3, r3, d3))
check(a3 > a2 and a2 > a1 and r3 > r1, "sniper > rifle > pistol: more blood on the wall, bigger stains")
check(d3 >= 3 and d2 >= 1, "heavy rounds throw chunks too")
local n4, _, w4 = Plume("buckshot", 160)
check(n4 <= 5, "one buckshot pellet: a few streams (" .. n4 .. ")")
-- a wall 8 m away: out of a pistol's reach, in a sniper's
local _, _, w5, f5 = Plume("pistol", 420)
local _, _, w6 = Plume("sniper", 420)
check(w5 == 0 and f5 > 0, "a wall 8 m away: the pistol's blood falls short onto the floor")
check(w6 > 0, "a wall 8 m away: the sniper's reaches it (" .. w6 .. ")")
-- head shots throw more
local nh = Plume("rifle", 160, true)
check(nh >= n2, string.format("head shot: at least as many streams (%d vs %d)", nh, n2))
-- the exit spray setting at 0: nothing
check(F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), B.rifle, 1, 0, 0.8, 0) == 0, "exit spray 0: no plume")
-- zombie blood: chunks red
hits, drops = {}, {}
M.now = M.now + 10
F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), B.sniper, 1, G.BLOOD_ZOMBIE, 0.8, 1)
local red = 0 for _, d in ipairs(drops) do if d.btype == G.BLOOD_RED then red = red + 1 end end
check(#drops > 0 and red == #drops, "zombie: the chunks are red blood")
-- budget: a burst of hits does not trace without limit
M.now = M.now + 10
local tot = 0
for _ = 1, 40 do tot = tot + F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), B.sniper, 1.6, 0, 0.8, 3) end
check(tot <= 200, "40 sniper hits in one frame: at most ~180 streams traced (" .. tot .. ")")
M.Advance(1)

-- ---------------- spatter (1.26.7: the Crisis Response Blood spatter decals and patterns)
check(GHMPB.SpatterPatterns and #GHMPB.SpatterPatterns == 18, "18 spatter patterns measured from the Crisis Response Blood spatter decals")
check(GHMPB.CRBDecals and #GHMPB.CRBDecals == 36, "36 Crisis Response Blood spray decals")
local decals = {}
util.DecalEx = function(m, ent, pos, n, col, w, h) decals[#decals + 1] = { m = m, pos = pos, n = n, w = w, h = h } end
local realMaterial = Material
Material = function(name) return { name = name, IsError = function() return false end } end
local created = {}
CreateMaterial = function(name, shader, kv)
	local m = { name = name, shader = shader, kv = kv, vec = {} }
	function m:IsError() return false end
	function m:GetVector(k) return self.vec[k] end
	function m:SetVector(k, v) self.vec[k] = v end
	created[name] = m
	return m
end
game = game or {}
game.GetWorld = game.GetWorld or function() return NULL end
M.now = M.now + 10
hits = {}
local nd = F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 0, 0.8, nil, 1)
local dec = decals[#decals]
check(#decals == 1 and dec.m.name:find("ghm_physblood/crb/bp", 1, true) ~= nil, "one CRB spray decal where it lands")
local wDec = dec and dec.w * GHMPB.CRB_DECAL_UNITS or 0
check(wDec > 14 and wDec < 140, string.format("the decal sized to the spatter (%.0f u across at scale)", wDec))
-- every hit different: decal, pattern, size
local names, ws = {}, {}
for _ = 1, 30 do M.now = M.now + 1 hits = {} F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 0, 0.8, nil, 1) names[decals[#decals].m.name] = true ws[#ws + 1] = decals[#decals].w end
local nn = 0 for _ in pairs(names) do nn = nn + 1 end
table.sort(ws)
check(nn >= 15, "30 hits: " .. nn .. " different decals")
check(ws[#ws] / ws[1] > 1.3, "and different sizes")
local before = #decals
M.now = M.now + 1
F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 2, 0.8, nil, 1)
local gd = decals[#decals]
local gi = gd and tonumber(gd.m.name:match("^ghm_physblood/crb/t2_bp(%d+)$") or "")
local inList = false
for _, i in ipairs(GHMPB.CRBTypeDecals[2]) do if i == gi then inList = true end end
check(#decals == before + 1 and gi ~= nil and inList, "green blood: a CRB splat recoloured green (" .. tostring(gd and gd.m.name) .. ")")
M.now = M.now + 10
hits = {}
nd = F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 0, 0.8, nil, 1)
local minY, maxY, minZ, maxZ, mist, big = 1e9, -1e9, 1e9, -1e9, 0, 0
for _, h in ipairs(hits) do
	if h.R > 4 then mist = mist + 1 else
		minY, maxY = math.min(minY, h.pos.y), math.max(maxY, h.pos.y) minZ, maxZ = math.min(minZ, h.pos.z), math.max(maxZ, h.pos.z)
		if h.R > 0.5 then big = big + 1 end
	end
end
print(string.format("     straight onto a wall, radius 14 u: %d drops (%d of them > 0.5 u), %.0f x %.0f u, %d mist", nd, big, maxY - minY, maxZ - minZ, mist))
check(nd >= 1 and nd <= 200 and big <= 6, "the bigger drops of a pattern: a few to 200, small (" .. big .. " over 0.5 u)")
check(maxY - minY > 8 and maxY - minY < 70 and maxZ - minZ > 8, "spread over about the pattern's size")
check(mist >= 1, "with its fine mist")
-- at a grazing angle it is stretched along the travel
M.now = M.now + 10
hits = {}
F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(0.35, 0.94, 0):GetNormalized(), 14, 0, 0.8, nil, 1)
local y0, y1, z0, z1 = 1e9, -1e9, 1e9, -1e9
for _, h in ipairs(hits) do if h.R <= 4 then y0, y1 = math.min(y0, h.pos.y), math.max(y1, h.pos.y) z0, z1 = math.min(z0, h.pos.z), math.max(z1, h.pos.z) end end
print(string.format("     at a grazing angle: %.0f u along the travel x %.0f u across", y1 - y0, z1 - z0))
check((y1 - y0) > 1.5 * (z1 - z0), "at a grazing angle: stretched along the way the blood travelled")
-- at most ~4 patterns a second
M.now = M.now + 10
local np = 0
for _ = 1, 10 do if F.Spatter(Vector(300, 0, 40), Vector(-1, 0, 0), Vector(1, 0, 0), 14, 0, 0.8, nil, 1) > 0 then np = np + 1 end end
check(np == 4, "10 patterns at once: 4 painted, the rest left out (" .. np .. ")")
-- the exit plume uses one for its main stream when a wall is close (Crisis Response splats off)
F.cvCrbSplats:SetBool(false)
M.now = M.now + 10
local p0 = F.patStats.patterns
Plume("rifle", 120)
check(F.patStats.patterns == p0 + 1, "splats off: a rifle exit with a wall 2 m behind: one spatter pattern on the wall")
local _, _, wOff = Plume("rifle", 70)
local aOff = lastArea
F.cvCrbSplats:SetBool(true)

-- ---------------- (1.26.7) Crisis Response splats instead of the big drops (players: "these big drops are too dense")
check(F.cvCrbSplats:GetBool(), "Crisis Response splats on by default")
local function SplatPlume(cls, wallX, btype)
	decals = {}
	hits = {}
	M.wallX = wallX
	M.now = M.now + 10
	F.ExitPlume(nil, Vector(0, 0, 40), Vector(1, 0, 0), B[cls], 1, btype or 0, 0.8, 1)
	M.Advance(1)
	local wall, maxR, wd, wmax = 0, 0, 0, 0
	for _, h in ipairs(hits) do if h.n.x < -0.5 then wall = wall + 1 maxR = math.max(maxR, h.R) end end
	for _, d in ipairs(decals) do if d.n.x < -0.5 then wd = wd + 1 wmax = math.max(wmax, d.w * GHMPB.CRB_DECAL_UNITS) end end
	return wall, maxR, #decals, wd, wmax
end
local counts = {}
for _, cls in ipairs({ "pistol", "magnum", "rifle", "sniper", "buckshot" }) do
	local mw, mR, md, mwd, mx = 0, 0, 0, 0, 0
	for _ = 1, 20 do
		local w, r, d, wd, x = SplatPlume(cls, 70)
		mw, mR, md, mwd, mx = math.max(mw, w), math.max(mR, r), math.max(md, d), mwd + wd, math.max(mx, x)
	end
	counts[cls] = { w = mw, R = mR, d = md, wd = mwd / 20, x = mx }
	print(string.format("     %s, wall 70 u behind: at most %d wet stains (largest %.2f u), at most %d splats (%.1f on the wall on average, up to %.0f u across)",
		cls, mw, mR, md, mwd / 20, mx))
end
check(counts.pistol.w <= 1 and counts.rifle.w <= 1 and counts.sniper.w <= 1, "the wall gets at most one wet stain per exit (the main stream's)")
check(counts.pistol.R <= 1.0 and counts.sniper.R <= 1.0, "and it is small (under 1 u)")
check(counts.pistol.d <= 2 and counts.magnum.d <= 3 and counts.rifle.d <= 3 and counts.sniper.d <= 4 and counts.buckshot.d <= 1,
	"splats per exit: pistol 2, magnum / rifle 3, sniper 4, buckshot 1 at most")
check(counts.pistol.wd >= 1 and counts.sniper.wd >= 1.5, "a wall close behind gets the splats")
check(counts.pistol.x > 14 and counts.pistol.x < 60 and counts.sniper.x > counts.pistol.x and counts.sniper.x < 120,
	string.format("splat sizes: pistol up to %.0f u, sniper up to %.0f u (the CRB mod lays them at 61 u)", counts.pistol.x, counts.sniper.x))
local names2 = {}
for _, d in ipairs(decals) do names2[d.m.name] = true end
check(next(names2) ~= nil and select(2, next(names2)) and (next(names2)):find("ghm_physblood/crb/bp", 1, true) ~= nil, "the splats are the CRB decals")
check(wOff and wOff > counts.rifle.w + 2, string.format("splats off: the PhysBlood drops again (%d wet stains on the wall)", wOff or -1))
-- other blood types: the same splats in their own colour
local wz, _, dz = SplatPlume("rifle", 70, G.BLOOD_YELLOW)
local typed, red = 0, 0
for _, d in ipairs(decals) do if d.m.name:find("ghm_physblood/crb/t1_bp", 1, true) == 1 then typed = typed + 1 else red = red + 1 end end
check(dz >= 1 and dz <= 3 and wz <= 1 and typed == dz and red == 0, string.format("yellow blood: %d CRB splats, the yellow copies, %d wet stain", dz, wz))
check(GHMPB.CRBTypeDecals and #GHMPB.CRBTypeDecals == 5, "recoloured splats for the 5 other blood types")
for _, bt in ipairs({ G.BLOOD_GREEN, G.BLOOD_ZOMBIE, G.BLOOD_SYNTH, G.BLOOD_ROBOT }) do
	local _, _, n = SplatPlume("magnum", 70, bt)
	local own = 0
	for _, d in ipairs(decals) do if d.m.name:find("ghm_physblood/crb/t" .. bt .. "_bp", 1, true) == 1 then own = own + 1 end end
	check(n >= 1 and own == n, "blood type " .. bt .. ": its own recoloured splats (" .. own .. " of " .. n .. ")")
end
-- the splats take the world and props (DecalModulate works on models), not bodies
local prop = M.Ent("prop_physics")
function prop:GetModel() return "models/props_c17/oildrum001.mdl" end
local npc = M.Ent("npc_antlion")
function npc:IsNPC() return true end
check(F.SplatTakes(prop, G.BLOOD_YELLOW) == true and F.SplatTakes(prop, G.BLOOD_RED) == true and F.SplatTakes(nil, G.BLOOD_GREEN) == true,
	"props and the world: every blood type")
check(F.SplatTakes(npc, G.BLOOD_YELLOW) == false, "bodies: no splats (they keep PhysBlood's body blood)")
-- the forward cone: a third of its drops, smaller
local function Cone(btype, gun)
	hits = {}
	M.wallX = 70
	M.now = M.now + 10
	for _ = 1, 10 do F.DirectConeMist(Vector(0, 0, 40), Vector(1, 0, 0), 24, 165, 9, 1.5, nil, 0.8, btype, gun) end
	M.Advance(1)
	local n, mr = 0, 0
	for _, h in ipairs(hits) do if h.R >= 0.12 then n = n + 1 mr = math.max(mr, h.R) end end
	return n, mr
end
local cg, cgR = Cone(0, true)
local cn, cnR = Cone(0, false)
print(string.format("     forward cone, 10 gunshots: %d drops (largest %.2f u); not a gunshot: %d (largest %.2f u)", cg, cgR, cn, cnR))
check(cg < cn * 0.6 and cgR <= 0.6, "gunshot cone with splats: fewer drops, none over 0.6 u")
-- (1.26.7) Z-City: the blood thrown out of a knocked-down player's ragdoll does not land on the player hidden in it
local zp, zr = M.Ent("player"), M.Ent("prop_ragdoll")
zp:SetNWEntity("FakeRagdoll", zr) zr:SetNWEntity("ply", zp)
check(F.BodyFilter(zr) == zr, "without Z-City: the body only")
local oldZC = G.ZC
G.ZC = { Active = function() return true end }
local fl = F.BodyFilter(zr)
local has = {}
if type(fl) == "table" and fl.x == nil then for _, e in ipairs(fl) do has[e] = true end end
check(has[zr] and has[zp], "with Z-City: the ragdoll and the player in it")
G.ZC = oldZC
-- engine decals are throttled
decals = {}
M.now = M.now + 10
for _ = 1, 40 do F.CRBDecal(Vector(300, 0, 40), Vector(-1, 0, 0), 10, nil) end
check(#decals == 16, "40 splats at once: 16 laid, the rest left out (" .. #decals .. ")")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
