-- Elements on the client (1.17.0): the element word the shaders decode, heat / cold / laser / acid / wave / arcs acting
-- on patches and bodies (luajit test_client_elements.lua)
local M = dofile("gmod.lua")
_G.SERVER, _G.CLIENT = false, true
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
M.Load({ "sh_shaderver.lua", "sh_config.lua", "sh_anatomy.lua" })
local G = GHMPB
-- engine
function EyePos() return Vector(0, 0, 64) end
function EyeAngles() return { Forward = function() return Vector(1, 0, 0) end } end
_G.render = { GetViewSetup = function() return { fov = 90 } end }
function ScrW() return 1600 end
function ScrH() return 900 end
function VectorRand() return Vector(0.1, -0.2, 0.3) end
function math.Rand(a, b) return (a + b) / 2 end
local particles, sounds, decals, effects, lights = 0, 0, 0, 0, 0
local P = {} P.__index = function() return function() end end
function ParticleEmitter() return { IsValid = function() return true end, SetPos = function() end,
	Add = function() particles = particles + 1 return setmetatable({}, P) end } end
_G.sound = { Play = function() sounds = sounds + 1 end }
function util.DecalEx() decals = decals + 1 end
function CreateMaterial(n) return { name = n } end
function Material(n) return { name = n } end
function EffectData() return setmetatable({}, P) end
function util.Effect() effects = effects + 1 end
function DynamicLight() lights = lights + 1 return {} end
function game.GetWorld() return M.ent0 end
M.ent0 = M.Ent("worldspawn")
_G.ents.FindByClass = function() return {} end
G.U = {}
M.Load({ "cl_util.lua" })
G.U.InViewPos = function() return true end
-- the parts of the blood system the elements act on
local stamps, impacts = {}, {}
local S = { patches = {}, after = {}, PATCH_UNITS = 40 }
function S.Element(pos, R, op, k, path, vol, bt)
	stamps[#stamps + 1] = { pos = pos, R = R, op = op, k = k, path = path, vol = vol, bt = bt }
	return 1
end
function S.Impact(pos, n, vel, R, vol, kind, spin, st, res, tr, oxy, bt) impacts[#impacts + 1] = { kind = kind, bt = bt, vol = vol } return true end
G.Surfaces = S
G.GPU = G.GPU or { CreateMat = function(tag) return CreateMaterial(tag) end }
local function patch(x, y, kind)
	local p = { key = x .. ":" .. y, origin = Vector(x - 20, y - 20, 0), center = Vector(x, y, 0), N = Vector(0, 0, 1),
		U = Vector(1, 0, 0), V = Vector(0, 1, 0), surfName = kind or "concrete", hasBlood = true }
	S.patches[p.key] = p
	return p
end
local bstamps = {}
G.Entities = { domains = {}, Element = function(ent, pos, R, op, k, path, vol, bt) bstamps[#bstamps + 1] = { op = op, k = k, bt = bt } return true end }
local drops = 0
G.Particles = { Spawn = function() drops = drops + 1 end, Mist = function() end }
local probeAnswer = { h = 0.5, s = 0, btype = 0, oxy = 0.6 }
G.Smear = { RequestProbe = function(ps) for k, v in pairs(probeAnswer) do ps[k] = v end ps.hT = CurTime() end }
M.Load({ "cl_elements.lua" })
local EL = G.Elem
local K = G.EL

-- the word, decoded as the shaders do (ghmpb_shade.h ghmpb_elemField)
local function f32(x) return x end
local function field(w, div, m) local q = math.floor((w + 0.5) / div) return q - math.floor((q + 0.5) / m) * m end
local el = { frost = 0.6, heat = 1, fizz = 0.2, glowT = EL.GLOW_EMBER, glow = 0.8, char = 0.4 }
local w = EL.Word(el, true)
local c3w = 1 + 2 * w
check(c3w < 2 ^ 23, "packed word below 2^23: (w + 0.5) / div exact in a float (" .. c3w .. ")")
check(field(c3w, 1, 2) == 1 and math.abs(field(c3w, 2, 16) / 15 - 0.6) < 0.04 and field(c3w, 32, 16) == 15
	and math.abs(field(c3w, 512, 8) / 7 - 0.2) < 0.08 and field(c3w, 4096, 8) == 3 and math.abs(field(c3w, 32768, 16) / 15 - 0.8) < 0.04
	and math.abs(field(c3w, 524288, 16) / 15 - 0.4) < 0.04, "flashlight, frost, boil, fizz, glow type, glow, char decode back")
local full = 1 + 2 * EL.Word({ frost = 1, heat = 1, fizz = 1, glowT = 7, glow = 1, char = 1 }, true)
check(full < 2 ^ 23 and field(full, 524288, 16) == 15 and field(full, 4096, 8) == 7 and field(full, 512, 8) == 7 and field(full, 2, 16) == 15, "all at full: still exact (" .. full .. ")")
check(EL.Word(el) == w % 262144, "patches carry no char (decals)")

-- cold: blood on snow freezes in ~90 s, on ice ~50 s; concrete not (no StormFox)
local ps = patch(0, 0, "snow")
local pi = patch(200, 0, "ice")
local pc = patch(400, 0, "concrete")
for _ = 1, 400 do M.Advance(0.1) EL.Update() end
check(ps.el.frost > 0.4 and ps.el.frost < 0.6, string.format("snow: half frozen after 40 s (%.2f)", ps.el.frost))
check(pi.el.frost > 0.75, string.format("ice: mostly frozen after 40 s (%.2f)", pi.el.frost))
check(pc.el.frost == 0, "concrete indoors: no frost")
for _ = 1, 600 do M.Advance(0.1) EL.Update() end
check(ps.el.frost == 1 and pi.el.frost == 1, "frozen solid after 100 s")
G.cv.freeze:SetBool(false)
for _ = 1, 50 do M.Advance(0.1) EL.Update() end
check(ps.el.frost < 1, "ghmpb_freeze 0: it thaws slowly")
G.cv.freeze:SetBool(true)

-- a burning body lying on the concrete: the pool boils (op 10), the body's blood boils and chars
local body = M.Ent("prop_ragdoll", { pos = Vector(400, 0, 0) })
function body:WorldSpaceCenter() return Vector(400, 0, 12) end
G.Entities.domains[body] = { ent = body }
stamps = {}
EL.Add(K.HEAT, Vector(400, 0, 12), 30, 0.9, 30, body)
local steam0 = EL.stats.steam
for _ = 1, 100 do M.Advance(0.1) EL.Update() end
local boil = 0
for _, s in ipairs(stamps) do if s.op == 10 and s.k > 0 then boil = boil + 1 end end
check(boil >= 90, "heat: the blood under it is boiled every tick (" .. boil .. ")")
check(pc.el.heat > 0.5, string.format("the patch boils (heat %.2f: bubbles, cooking)", pc.el.heat))
local d = G.Entities.domains[body]
check(d.el and d.el.heat > 0.5 and d.el.char > 0.3, string.format("the body: heat %.2f, char %.2f after 10 s", d.el and d.el.heat or -1, d.el and d.el.char or -1))
check(#bstamps > 10 and bstamps[1].op == 10, "its blood boils off (body stamps)")
check(EL.stats.steam > steam0, "wet blood in the heat steams")
-- dried blood in the heat chars
probeAnswer = { h = 0, s = 0.3, btype = 0, oxy = 0.6 }
local dec0 = decals
for _ = 1, 50 do M.Advance(0.1) EL.Update() end
check(decals > dec0, "dried blood kept in the heat chars (decals: " .. (decals - dec0) .. ")")
check(pc.el.glowT == EL.GLOW_EMBER, "and its embers glow")
-- heat thaws frozen blood
local ps2 = patch(0, 400, "snow")
ps2.el = { heat = 0, frost = 1, fizz = 0, glow = 0, glowT = 0, cold = true, coldRate = 1 / 90 }
EL.Add(K.HEAT, Vector(0, 400, 12), 30, 1, 5)
for _ = 1, 30 do M.Advance(0.1) EL.Update() end
check(ps2.el.frost < 0.7, string.format("fire thaws frozen blood (%.2f)", ps2.el.frost))

-- a laser sweeping over a pool: boils a line (path), spits drops, steams
probeAnswer = { h = 0.6, s = 0, btype = 0, oxy = 0.6 }
stamps = {}
local d0 = drops
EL.Add(K.LASER, Vector(10, 0, 0), 4, 1, 0.3, nil, Vector(10, 0, 100))
M.Advance(0.05)
EL.Add(K.LASER, Vector(14, 0, 0), 4, 1, 0.3, nil, Vector(14, 0, 100))
M.Advance(0.1) EL.Update()
local ls = {}
for _, st in ipairs(stamps) do if st.R == 2.5 then ls[#ls + 1] = st end end
check(#ls == 2 and ls[1].op == 10 and ls[2].path ~= nil and math.abs(ls[2].path.x + 4) < 0.5, "laser: boils the spot, then a line from the last spot (path)")
check(drops > d0, "explosive boiling spits drops (" .. (drops - d0) .. ")")
-- acid
stamps, impacts = {}, {}
EL.Add(K.ACID, Vector(0, 0, 20), 12, 1, 1.5, nil, Vector(0, 0, 0))
check(#impacts == 1 and impacts[1].bt == G.ACID_TYPE and impacts[1].kind == 1, "acid: poured as a pool of the acid type (it mixes in)")
check(#stamps == 1 and stamps[1].op == 12, "and it dissolves the dried blood around it (op 12)")
check(ps.el.fizz > 0.5, "it fizzes")
-- shock wave
stamps = {}
local d1 = drops
EL.Add(K.WAVE, Vector(0, 0, 30), 300, 1, 0.5)
M.Advance(0.1) EL.Update()
local ws = {}
for _, st in ipairs(stamps) do if st.op == 13 then ws[#ws + 1] = st end end
check(#ws == 1 and ws[1].R == 300, "a blast: the wet blood is shoved outwards (op 13)")
check(drops > d1, "shallow blood near it jumps up (" .. (drops - d1) .. " drops)")
-- electricity arcs
local pa = patch(0, -400, "concrete")
EL.Arc(Vector(0, -400, 1), 1, { { p = Vector(0, -400, 0), par = 0, r = 14 }, { p = Vector(30, -400, 0), par = 1, r = 10 } }, {})
check(#EL.arcs == 1 and #EL.arcs[1].segs >= 2, "arcs to draw along the blood")
check(pa.el.glowT == EL.GLOW_ELEC and pa.el.glow > 0.5, "the blood flashes blue-white")
check(lights > 0 and sounds > 0 and effects > 0, "light, sound, sparks")
for _ = 1, 10 do M.Advance(0.1) EL.Update() end
check(pa.el.glow == 0, "the flash fades within a second")
-- dissolve and energy balls do not error without entities
EL.Add(K.DISSOLVE, Vector(0, 0, 20), 40, 1, 2.5)
-- switched off
G.cv.elements:SetBool(false)
stamps = {}
EL.Add(K.HEAT, Vector(400, 0, 12), 30, 0.9, 30)
for _ = 1, 10 do M.Advance(0.1) EL.Update() end
check(#stamps == 0 and EL.Word(el) == 0, "ghmpb_elements 0: nothing")
check(#M.errors == 0 and not G.Diag.lastError, "no errors (" .. #M.errors .. ", " .. tostring(G.Diag.lastError) .. ")")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
