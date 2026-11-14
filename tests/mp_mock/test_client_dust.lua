-- Explosion dust (1.18.0, client): the kind of dust from the ground, the cloud settling in pulses over a growing disc,
-- which layers and bodies catch it and how, nearby blasts merging, air bursts, the word the shaders decode, the surface
-- material table (luajit test_client_dust.lua)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
function EyePos() return Vector(0, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
function VectorRand() return Vector(0.1, -0.2, 0.3) end
function math.Rand(a, b) return (a + b) / 2 end
local particles = 0
local P = {} P.__index = function() return function() end end
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end,
	Add = function() particles = particles + 1 return setmetatable({}, P) end } end
_G.util.PointContents = function() return 0 end
-- the ground: a floor at z = 0; its material by position (x < -1000: water, x > 1000: snow, else sand with concrete on
-- the +y side)
_G.util.TraceLine = function(td)
	local s, e = td.start, td.endpos
	if s.z < 0 or e.z > 0 then return { Hit = false } end
	local x, y = s.x, s.y
	local mt = (x > 1000) and MAT_SNOW or ((y > 30) and MAT_CONCRETE or MAT_SAND)
	if x < -1000 then mt = MAT_SLOSH end
	return { Hit = true, HitPos = Vector(x, y, 0), HitNormal = Vector(0, 0, 1), MatType = mt, SurfaceProps = -1 }
end
-- the parts of the blood system the dust acts on
local stamps = {}
local S = { patches = {}, after = {}, PATCH_UNITS = 40 }
function S.Element(pos, R, op, k)
	stamps[#stamps + 1] = { pos = pos, R = R, op = op, k = k }
	local n = 0
	for _, p in pairs(S.patches) do if p.center:Distance(pos) < R + 30 then n = n + 1 end end
	return n
end
G.Surfaces = S
local function layer(list, x, y)
	local p = { key = x .. ":" .. y, origin = Vector(x - 20, y - 20, 0), center = Vector(x, y, 0), N = Vector(0, 0, 1),
		U = Vector(1, 0, 0), V = Vector(0, 1, 0), hasBlood = true, slot = {}, aft = { res = 256 }, bakedAt = 0 }
	list[p.key] = p
	return p
end
local bstamps = {}
local E = { domains = {} }
function E.IsLive(d) return d.live end
function E.HasAft(d) return d.aftm end
function E.Element(ent, pos, R, op, k) bstamps[#bstamps + 1] = { ent = ent, op = op, R = R, k = k } return true end
G.Entities = E
local function body(x, y, live, aftm)
	local ent = M.Ent("prop_ragdoll")
	ent.pos = Vector(x, y, 4)
	ent.GetPos = function(self) return self.pos end
	ent.WorldSpaceCenter = function(self) return self.pos + Vector(0, 0, 8) end
	ent.BoundingRadius = function() return 36 end
	E.domains[ent] = { live = live, aftm = aftm, subs = {} }
	return ent, E.domains[ent]
end
G.GPU = G.GPU or {}
M.Load({ "cl_dust.lua" })
local D = G.Dust

-- the kind of dust
local k, g = D.GroundKind(Vector(0, 0, 40))
check(k == 1 and g and g.z == 0, "sand under the blast: sand dust (" .. tostring(k) .. ")")
k = D.GroundKind(Vector(0, 25, 40))
check(k == 1, "on the edge of concrete: the majority of the traces around - still sand (" .. tostring(k) .. ")")
k = D.GroundKind(Vector(0, 60, 40))
check(k == 4, "on concrete: concrete dust (" .. tostring(k) .. ")")
k = D.GroundKind(Vector(1500, 0, 40))
check(k == 2, "snow (" .. tostring(k) .. ")")
k = D.GroundKind(Vector(-1500, 0, 40))
check(k == nil, "water: no dust")
k = D.GroundKind(Vector(0, 0, 400))
check(k == nil, "nothing below within reach: no dust")

-- a blast on sand: layers and bodies around it
local near = layer(S.patches, 60, 0)
local far = layer(S.patches, 900, 0)
local old = layer(S.after, -80, 0)
local oldFar = layer(S.after, 2000, 0)
local liveBody = body(100, 40, true, false)
local bakedBody, bd = body(-60, -60, false, true)
local farBody = body(1500, 1500, true, false)
check(D.Blast(Vector(0, 0, 20), 260, 1) == true, "the blast raises dust")
check(particles > 10, "a dust cloud (" .. particles .. " particles)")
local n0 = #stamps
for _ = 1, 60 do M.Advance(0.1) D.Update() end
local dust = {}
for i = n0 + 1, #stamps do if stamps[i].op == 14 then dust[#dust + 1] = stamps[i] end end
check(#dust == #D.PULSES, "settles in " .. #D.PULSES .. " pulses over ~5 s (" .. #dust .. ")")
check(dust[1].R < dust[#dust].R and dust[#dust].R <= 260, string.format("over a disc that grows (%.0f -> %.0f u)", dust[1].R, dust[#dust].R))
local total = 0
for _, s in ipairs(dust) do total = total + s.k end
-- (20 u above the ground: a little less than at ground level)
local want = D.TOTAL * (1 - 20 / (260 * 1.2))
check(math.abs(total - want) < 0.02, string.format("full strength: %.2f at the centre (%.2f)", total, want))
check(near.dust and near.dust.k == 1, "the live layer next to it caught sand")
check(near.dust.soot > 0.3, string.format("close to the blast, with soot (%.2f)", near.dust.soot))
check(far.dust == nil, "a layer 9 m away: none")
check(old.dust and old.dust.k == 1, "the settled layer next to it: sand too")
local q = D.queue[old]
check(q and #q.list == #D.PULSES, "its stamps are queued for the GPU pass (" .. (q and #q.list or 0) .. ")")
check(oldFar.dust == nil and D.queue[oldFar] == nil, "a settled layer far away: nothing")
local lb = 0
for _, s in ipairs(bstamps) do if s.ent == liveBody and s.op == 14 then lb = lb + 1 end end
check(lb == #D.PULSES, "the live body next to it: its element stamp, every pulse (" .. lb .. ")")
check(D.queue[bd] and #D.queue[bd].list > 0, "the baked body: a stamp into its aftermath queued")
check(E.domains[farBody].dust == nil, "a body far away: none")
check(#D.events == 0, "the cloud has settled")

-- the word the shaders decode: kind + 16 x soot
local w = D.Word({ k = 6, soot = 0.5 })
check(w % 16 == 6 and math.floor(w / 16) == 4, "word: brick + soot 4/7 (" .. w .. ")")
check(D.Word(nil) == 0, "no dust: 0 (the overlay draws nothing)")
-- the kind with the most dust wins
local o = {}
D.SetDust(o, 1, 0, 0.3)
D.SetDust(o, 4, 0, 0.1)
check(o.dust.k == 1, "a little concrete dust on sand dust stays sand")
D.SetDust(o, 4, 0, 1.0)
check(o.dust.k == 4, "much more concrete dust: concrete")

-- blasts close together are one cloud; a second one a moment later strengthens it
M.Advance(2)
D.Blast(Vector(0, 0, 20), 260, 0.6)
D.Blast(Vector(20, 10, 20), 260, 0.6)
check(#D.events == 1 and D.events[1].s > 0.6, string.format("two blasts in one spot: one cloud, stronger (%.2f)", D.events[1].s))
for _ = 1, 60 do M.Advance(0.1) D.Update() end
-- the explosion's sound here (the temp entity's: the server may not see it) raises dust; the server's event for the
-- same blast does not add to it; the map's distant ambience does nothing
local b0 = D.stats.blasts
M.Engine("EntityEmitSound", { SoundName = "weapons/explode4.wav", OriginalSoundName = "BaseExplosionEffect.Sound", Pos = Vector(10, 0, 20), SoundLevel = 140 })
M.Advance(0.05)
check(D.stats.blasts == b0 + 1 and #D.events == 1 and D.events[1].src == "cl", "an explosion heard here: a dust cloud")
local s0 = D.events[1].s
D.Blast(Vector(0, 0, 20), 264, 1.3, nil, "sv")
check(D.stats.blasts == b0 + 1 and D.events[1].s == s0, "the server's event for the same blast: counted once")
M.Engine("EntityEmitSound", { SoundName = "ambient/explosions/explode_4.wav", Pos = Vector(400, 0, 20), SoundLevel = 140 })
M.Advance(0.05)
check(D.stats.blasts == b0 + 1, "the map's distant explosions: no dust")
for _ = 1, 60 do M.Advance(0.1) D.Update() end
-- an air burst high above the ground raises nothing
local before = D.stats.skipped
check(D.Blast(Vector(0, 0, 240), 200, 1) == false and D.stats.skipped == before + 1, "an air burst 2.4 m up raises no dust")
-- switched off
RunConsoleCommand("ghmpb_blast_dust", "0")
check(D.Blast(Vector(0, 0, 20), 260, 1) == false, "ghmpb_blast_dust 0: nothing")
RunConsoleCommand("ghmpb_blast_dust", "1")

-- the surface material table the world shaders read (ghmpb_mat): 32 kinds x 4 rows, each a 2 x 2 block
function Matrix() return { SetUnpacked = function() end } end
_G.mesh = { Position = function() end, TexCoord = function() end, AdvanceVertex = function() end, Begin = function() end, End = function() end }
M.Load({ "cl_gpu.lua" })
local list = G.GPU.MatTableList()
check(#list == 32 * 4, "material table: 128 blocks (" .. #list .. ")")
local function block(id, row) for _, b in ipairs(list) do if b[1] == id * 2 and b[2] == row * 2 then return b end end end
local snow0, snow1, gravel3 = block(16, 0), block(16, 1), block(14, 3)
check(snow0[3] - snow0[1] == 2 and snow0[4] - snow0[2] == 2, "a block is 2 x 2 texels")
check(snow0[5][1] == 1 and snow0[5][2] == 0.55 and snow0[5][3] == 3 and snow0[5][4] == 0.25, "snow: soak, dilute, scatter, browning")
check(snow1[5][2] == 1 and snow1[5][3] == 1 and snow1[5][4] == 1, "snow: sparkle, sinks in, pink halo")
check(gravel3[5][1] == 1, "gravel: stones")
local def0, def2 = block(0, 0), block(0, 2)
check(def0[5][1] == 0 and def0[5][2] == 1 and def2[5][2] == 3 and def2[5][4] == 0.6, "kind 0: the defaults")
check(block(31, 1)[5][1] == 1, "unused kinds: the defaults too (crack 1)")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
