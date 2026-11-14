GHMPB = GHMPB or {}
local G = GHMPB
G.Anatomy = G.Anatomy or {}
local A = G.Anatomy

A.HEAD, A.NECK, A.CHEST, A.ABDOMEN, A.PELVIS = "head", "neck", "chest", "abdomen", "pelvis"
A.UPPERARM, A.FOREARM, A.HAND, A.THIGH, A.CALF, A.FOOT, A.OTHER = "upperarm", "forearm", "hand", "thigh", "calf", "foot", "other"

local RULES = {
	{ A.HEAD,     { "head_?%d*$", "head1", "_head", "^head", "skull", "cranium", "face", "jaw", "mouth", "nose", "brow" },
	              { "headcrab", "forehead_?helper", "headlight", "head_end", "headtop_end", "bodyhead" } },
	{ A.NECK,     { "neck", "throat" } },
	{ A.HAND,     { "hand", "wrist", "palm", "finger", "thumb", "index", "middle", "ring", "pinky", "digit" } },
	{ A.FOREARM,  { "forearm", "lowerarm", "lower_arm", "elbow", "lowarm", "arm_?lower", "ulna", "radius" } },
	{ A.UPPERARM, { "upperarm", "upper_arm", "uparm", "humerus", "arm_?upper", "bicep", "shoulder", "clavicle", "collar", "^arm_?[lr]", "_arm_?[lr]", "^[lr]_arm", "_[lr]_arm$", "arm$" } },
	{ A.FOOT,     { "foot", "ankle", "toe", "heel", "ball_?[lr]" } },
	{ A.CALF,     { "^leftleg$", "^rightleg$", "calf", "shin", "knee", "lowerleg", "lower_leg", "leg_?lower", "lowleg", "leg2", "tibia" } },
	{ A.THIGH,    { "thigh", "upleg", "upperleg", "upper_leg", "leg_?upper", "femur", "leg1", "hip_?[lr]", "[lr]_?hip", "leg" } },
	{ A.PELVIS,   { "pelvis", "hips", "hip$", "root_?hips", "groin", "butt", "bip01$", "^bip01_?pelvis" } },
	{ A.CHEST,    { "spine_?[234]", "spine_?0[234]", "spine_?04", "chest", "ribcage", "upperchest", "upper_chest", "thorax", "torso", "breast", "sternum", "spine_?upper", "body_?upper", "spine_?top" } },
	{ A.ABDOMEN,  { "spine_?1", "spine_?01", "spine$", "spine_?0$", "stomach", "belly", "abdomen", "waist", "spine_?lower", "lowerback", "body" } },
}

local function norm(name)
	name = string.lower(name or "")
	name = string.gsub(name, "valvebiped%.", "")
	name = string.gsub(name, "mixamorig%d*:", "")
	name = string.gsub(name, "[%s%.:%-]", "_")
	name = string.gsub(name, "__+", "_")
	return name
end
A.NormaliseBoneName = norm

function A.BoneSide(name)
	local n = norm(name)
	if string.find(n, "left") or string.find(n, "_l_") or string.find(n, "^l_") or string.find(n, "_l$")
		or string.find(n, "bip01_l") or string.find(n, "bip_l") then
		return -1
	end
	if string.find(n, "right") or string.find(n, "_r_") or string.find(n, "^r_") or string.find(n, "_r$")
		or string.find(n, "bip01_r") or string.find(n, "bip_r") then
		return 1
	end
	return 0
end

function A.ClassifyBoneName(name)
	local n = norm(name)
	for _, rule in ipairs(RULES) do
		local region, pats, excl = rule[1], rule[2], rule[3]
		local bad = false
		if excl then
			for _, e in ipairs(excl) do if string.find(n, e) then bad = true break end end
		end
		if not bad then
			for _, p in ipairs(pats) do
				if string.find(n, p) then return region end
			end
		end
	end
	return A.OTHER
end

A.Cache = A.Cache or {}
function A.GetSkeleton(ent)
	if not IsValid(ent) then return nil end
	local mdl = ent:GetModel()
	if not mdl then return nil end
	local sk = A.Cache[mdl]
	if sk then return sk end
	sk = { regions = {}, bones = {}, count = ent:GetBoneCount() or 0 }
	for b = 0, sk.count - 1 do
		local name = ent:GetBoneName(b)
		if name and name ~= "__INVALIDBONE__" then
			local r = A.ClassifyBoneName(name)
			sk.bones[b] = { name = name, region = r, side = A.BoneSide(name) }
			sk.regions[r] = sk.regions[r] or {}
			table.insert(sk.regions[r], b)
		end
	end
	local function pick(region, prefer)
		local list = sk.regions[region]
		if not list then return nil end
		for _, pat in ipairs(prefer or {}) do
			for _, b in ipairs(list) do if string.find(norm(sk.bones[b].name), pat) then return b end end
		end
		return list[1]
	end
	sk.head = pick(A.HEAD, { "head_?1$", "^head$", "_head$", "head_?0$", "head" })
	sk.neck = pick(A.NECK, { "neck_?1$", "^neck$", "neck_?0?1", "neck" })
	sk.chest = pick(A.CHEST, { "spine_?2$", "spine_?4$", "spine_?03", "chest", "spine_?3" })
	sk.abdomen = pick(A.ABDOMEN, { "spine_?1$", "spine$", "spine_?01" })
	sk.pelvis = pick(A.PELVIS, { "pelvis", "hips" })
	sk.humanoid = sk.head ~= nil and (sk.chest ~= nil or sk.abdomen ~= nil) and sk.regions[A.THIGH] ~= nil
	if not sk.head and sk.count > 0 then
		local best, bz = nil, -math.huge
		for b = 0, sk.count - 1 do
			local m = ent:GetBoneMatrix(b)
			if m then
				local z = (m:GetTranslation() - ent:GetPos()):Dot(ent:GetUp())
				if z > bz then best, bz = b, z end
			end
		end
		sk.headGuess = best
	end
	if next(sk.bones) ~= nil then A.Cache[mdl] = sk end
	return sk
end

function A.RegionFromHit(ent, bone, hitgroup)
	local sk = A.GetSkeleton(ent)
	local r = sk and bone and sk.bones[bone] and sk.bones[bone].region or A.OTHER
	if hitgroup == HITGROUP_HEAD and r ~= A.NECK then return A.HEAD end
	if r ~= A.OTHER then return r end
	if hitgroup == HITGROUP_CHEST then return A.CHEST end
	if hitgroup == HITGROUP_STOMACH then return A.ABDOMEN end
	if hitgroup == HITGROUP_LEFTARM or hitgroup == HITGROUP_RIGHTARM then return A.UPPERARM end
	if hitgroup == HITGROUP_LEFTLEG or hitgroup == HITGROUP_RIGHTLEG then return A.THIGH end
	return A.OTHER
end

A.Trauma = {
	[A.HEAD]     = { nose = 0.95, mouth = 0.85, ears = 0.40, earsBlunt = 0.55, artery = 0.00, weep = 0.30, cough = 0.00 },
	[A.NECK]     = { nose = 0.25, mouth = 0.85, ears = 0.00, earsBlunt = 0.10, artery = 0.45, weep = 0.45, cough = 0.60, arteryName = "carotid" },
	[A.CHEST]    = { nose = 0.15, mouth = 0.55, ears = 0.00, earsBlunt = 0.00, artery = 0.05, weep = 0.35, cough = 0.70, delayed = true },
	[A.ABDOMEN]  = { nose = 0.00, mouth = 0.20, ears = 0.00, earsBlunt = 0.00, artery = 0.05, weep = 0.40, cough = 0.20, delayed = true },
	[A.PELVIS]   = { nose = 0.00, mouth = 0.05, ears = 0.00, earsBlunt = 0.00, artery = 0.15, weep = 0.40, cough = 0.00, arteryName = "iliac" },
	[A.UPPERARM] = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.14, weep = 0.25, cough = 0.00, arteryName = "brachial" },
	[A.FOREARM]  = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.06, weep = 0.22, cough = 0.00, arteryName = "radial" },
	[A.HAND]     = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.03, weep = 0.15, cough = 0.00 },
	[A.THIGH]    = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.22, weep = 0.35, cough = 0.00, arteryName = "femoral" },
	[A.CALF]     = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.05, weep = 0.25, cough = 0.00 },
	[A.FOOT]     = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.00, weep = 0.15, cough = 0.00 },
	[A.OTHER]    = { nose = 0.00, mouth = 0.00, ears = 0.00, earsBlunt = 0.00, artery = 0.03, weep = 0.30, cough = 0.00 },
}

function A.IsBlunt(dmgtype)
	return bit.band(dmgtype or 0, bit.bor(DMG_CLUB, DMG_CRUSH, DMG_FALL, DMG_BLAST, DMG_VEHICLE, DMG_PHYSGUN, DMG_SONIC)) ~= 0
		and bit.band(dmgtype or 0, bit.bor(DMG_BULLET, DMG_SLASH, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT)) == 0
end

function A.IsPenetrating(dmgtype)
	return bit.band(dmgtype or 0, bit.bor(DMG_BULLET, DMG_SLASH, DMG_BUCKSHOT, DMG_SNIPER, DMG_AIRBOAT, DMG_NEVERGIB)) ~= 0
		or dmgtype == 0 or dmgtype == DMG_GENERIC
end
