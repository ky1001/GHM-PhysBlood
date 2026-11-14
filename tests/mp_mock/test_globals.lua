-- Every global the addon's Lua reads is a known GMod / Lua global or one of the addon's own (GHMPB, interop with other
-- addons). A function that calls a local declared further down its file reads it as a global - nil at run time: 1.21.0
-- shipped like that (ForceBake -> BumpUV) and the blood on the world stopped. (luajit -bl over every file)
local ALLOW = {}
for w in ([[AddCSLuaFile Angle BLENDFUNC_ADD BLEND_ONE BLEND_ONE_MINUS_SRC_ALPHA BLEND_SRC_ALPHA BLEND_SRC_COLOR BLEND_ZERO BLOOD_COLOR_ANTLION BLOOD_COLOR_ANTLION_WORKER BLOOD_COLOR_GREEN BLOOD_COLOR_MECH BLOOD_COLOR_RED BLOOD_COLOR_YELLOW BLOOD_COLOR_ZOMBIE BOTTOM CLIENT CONTENTS_SLIME CONTENTS_SOLID CONTENTS_WATER ClientsideModel Color CreateClientConVar CreateConVar CreateMaterial CurTime DMG_ACID DMG_AIRBOAT DMG_ALWAYSGIB DMG_BLAST DMG_BLAST_SURFACE DMG_BUCKSHOT DMG_BULLET DMG_BURN DMG_CLUB DMG_CRUSH DMG_DIRECT DMG_DISSOLVE DMG_DROWN DMG_DROWNRECOVER DMG_ENERGYBEAM DMG_FALL DMG_GENERIC DMG_MISSILEDEFENSE DMG_NERVEGAS DMG_NEVERGIB DMG_PARALYZE DMG_PHYSGUN DMG_PLASMA DMG_POISON DMG_PREVENT_PHYSICS_FORCE DMG_RADIATION DMG_SHOCK DMG_SLASH DMG_SLOWBURN DMG_SNIPER DMG_SONIC DMG_VEHICLE DONT_BLEED DamageInfo Derma_Query DynamicLight EF_BONEMERGE EffectData Entity ErrorNoHalt EyeAngles EyePos FCVAR_ARCHIVE FCVAR_REPLICATED FILL FrameNumber FrameTime GHMFL GHMPB GHM_PFX GetConVar GetConVarNumber GetConVarString GetRenderTargetEx HITGROUP_CHEST HITGROUP_HEAD HITGROUP_LEFTARM HITGROUP_LEFTLEG HITGROUP_RIGHTARM HITGROUP_RIGHTLEG HITGROUP_STOMACH HOOK_MONITOR_HIGH IMAGE_FORMAT_RGBA16161616F IMAGE_FORMAT_RGBA8888 IsValid LEFT Lerp LocalPlayer LocalToWorld MainEyeAngles MainEyePos MASK_OPAQUE MASK_SHOT MASK_SOLID MASK_SOLID_BRUSHONLY MATERIAL_FOG_LINEAR_BELOW_FOG_Z MATERIAL_FOG_NONE MATERIAL_LIGHT_DIRECTIONAL MATERIAL_QUADS MATERIAL_RT_DEPTH_NONE MATERIAL_RT_DEPTH_SEPARATE MATERIAL_TRIANGLES MAT_ALIENFLESH MAT_ANTLION MAT_BLOODYFLESH MAT_CLIP MAT_COMPUTER MAT_CONCRETE MAT_DIRT MAT_EGGSHELL MAT_FLESH MAT_FOLIAGE MAT_GLASS MAT_GRASS MAT_GRATE MAT_METAL MAT_PLASTIC MAT_SAND MAT_SLOSH MAT_SNOW MAT_TILE MAT_VENT MAT_WARPSHIELD MAT_WOOD MOVETYPE_NOCLIP MOVETYPE_VPHYSICS Material Matrix Mesh MsgC MsgN NULL ParticleEmitter RENDERGROUP_OPAQUE RIGHT RT_SIZE_LITERAL RealFrameTime RealTime RecipientFilter RunConsoleCommand SCREENFADE SERVER TEXT_ALIGN_CENTER TEXT_ALIGN_LEFT ScrH ScrW StormFox2 SysTime TOP ULib Vector VectorRand ViewPunch WorldToLocal _G angle_zero bit cam color_black color_white concommand coroutine cvars draw engine ents error file game ghm_physblood hook include ipairs isangle isentity isfunction isnumber isstring istable isvector jit list math mesh net next pairs pcall player print rawequal rawget render require resource select setmetatable sound spawnmenu string surface system table timer tonumber tostring type util vector_origin vgui ]]):gmatch("%S+") do ALLOW[w] = true end
local fails = 0
local function check(cond, msg) if cond then print("ok   " .. msg) else fails = fails + 1 print("FAIL " .. msg) end end
local roots = { "../../addon/ghm_physblood/lua", "../../../garrysmod/addons/ghm_physblood/lua" }
local root
for _, r in ipairs(roots) do local f = io.open(r .. "/autorun/ghm_physblood.lua") if f then f:close() root = r break end end
check(root ~= nil, "the addon's Lua found")
local files = {}
local ls = io.popen('ls "' .. root .. '"/ghm_physblood/*.lua "' .. root .. '"/autorun/*.lua')
for line in ls:lines() do files[#files + 1] = line end
ls:close()
check(#files > 30, #files .. " files")
local bad = {}
for _, f in ipairs(files) do
	local p = io.popen('luajit -bl "' .. f .. '" 2>&1')
	for line in p:lines() do
		local name = line:match('GGET .*; "([%w_]+)"')
		if name and not ALLOW[name] then bad[#bad + 1] = f:match("[^/]+$") .. ": " .. name end
	end
	p:close()
end
check(#bad == 0, "no unknown globals read" .. (#bad > 0 and (" - " .. table.concat(bad, ", ")) or ""))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
