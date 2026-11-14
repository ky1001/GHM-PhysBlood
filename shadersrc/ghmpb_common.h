// =====================================================================================
// GHM PhysBlood - shared HLSL (ps_3_0) helpers
// Units: film thickness in mm, world lengths in Source units (u, 1u = 1.905 cm),
// accelerations in cm/s^2, texel velocities in texels/s.
// Cell layout (state RT, RGBA16F): x = h (wet film mm), y = s (dried/absorbed stain mm, wet-equivalent),
//                                   zw = momentum h*v (mm * texel/s)
// Force RT (RGBA16F): x,y = tangential accel along texel axes (cm/s^2), z = normal accel (cm/s^2, >0 pulls
//                     blood OFF the surface), w = texel edge length L (cm), 0 = no surface (void)
// =====================================================================================
#ifndef GHMPB_COMMON_H
#define GHMPB_COMMON_H

#define GHMPB_UNITS_TO_CM 1.905

// (1.26.9c) drying rate by film thickness, in units of the drying time: thin films dry faster than pools, but at most
// twice as fast now (was up to 12x: 3.0 for thin films vs 0.25 for pools) - droplets, spatter and the thin edge of a pool
// went dark and dry within a minute at short drying times while the pool next to them still looked fresh and wet
#define GHMPB_DRYK(hh) clamp(0.3 / ((hh) + 0.1), 0.25, 0.5)

// screenspace_general uploads the camera position into c10 for every pixel shader
// Eye position: screenspace_general does not set the pixel shader eye constant (c10 reads 0), so the
// vertex shaders pass the VS eye constant (cEyePosWaterZ, always set) down and main() stores it here.
static float3 gEye = float3(0, 0, 0);
#define GHMPB_RHO 1.06
#define GHMPB_PI 3.14159265
#define GHMPB_INV_PI 0.31830989

float ghmpb_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float ghmpb_hash12(float2 p)
{
	float3 p3 = frac(float3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return frac((p3.x + p3.y) * p3.z);
}

float ghmpb_hash11(float p)
{
	p = frac(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return frac(p);
}

float ghmpb_vnoise(float2 p)
{
	float2 i = floor(p), f = frac(p);
	float2 u = f * f * (3.0 - 2.0 * f);
	float a = ghmpb_hash12(i), b = ghmpb_hash12(i + float2(1, 0));
	float c = ghmpb_hash12(i + float2(0, 1)), d = ghmpb_hash12(i + float2(1, 1));
	return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// gradient of value noise (for ripples)
float2 ghmpb_vnoise_grad(float2 p)
{
	float2 i = floor(p), f = frac(p);
	float2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
	float a = ghmpb_hash12(i), b = ghmpb_hash12(i + float2(1, 0));
	float c = ghmpb_hash12(i + float2(0, 1)), d = ghmpb_hash12(i + float2(1, 1));
	return float2(lerp(b - a, d - c, u.y) * du.x, lerp(c - a, d - b, u.x) * du.y);
}

// ------------------------------------------------------------------ PBR (after ZMR / Cpt-Hazama PBR module)
float3 ghmpb_fresnelSchlick(float3 F0, float cosTheta)
{
	return F0 + (1.0 - F0) * pow(1.0 - saturate(cosTheta), 5.0);
}

// (1.26.10) alpha^2 kept at 1e-4 or more (roughness 0.1 - about the size of the sun's disc): below it the peak of the lobe
// is narrower than float precision resolves 1 - cos^2 near the mirror direction, and a still pool facing the sun broke up
// into single white pixels (holes3-5 on gm_construct) instead of showing the sun's reflection
float ghmpb_ndfGGX(float cosLh, float roughness)
{
	float alpha = roughness * roughness;
	float alphaSq = max(alpha * alpha, 1e-4);
	float denom = (cosLh * cosLh) * (alphaSq - 1.0) + 1.0;
	return alphaSq / (GHMPB_PI * denom * denom);
}

float ghmpb_gaSchlickG1(float cosTheta, float k) { return cosTheta / (cosTheta * (1.0 - k) + k); }

float ghmpb_gaSchlickGGX(float cosLi, float cosLo, float roughness)
{
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;
	return ghmpb_gaSchlickG1(cosLi, k) * ghmpb_gaSchlickG1(cosLo, k);
}

float3 ghmpb_envBRDFApprox(float3 specColor, float roughness, float NoV)
{
	const float4 c0 = { -1, -0.0275, -0.572, 0.022 };
	const float4 c1 = { 1, 0.0425, 1.04, -0.04 };
	float4 r = roughness * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
	float2 AB = float2(-1.04, 1.04) * a004 + r.zw;
	return specColor * AB.x + AB.y;
}

// Cook-Torrance specular of a single light (radiance already includes NdotL cosine)
float3 ghmpb_specGGX(float3 N, float3 V, float3 L, float3 radiance, float3 F0, float roughness)
{
	float3 H = normalize(L + V);
	float NoL = saturate(dot(N, L));
	float NoV = max(saturate(dot(N, V)), 1e-3);
	float NoH = saturate(dot(N, H));
	float3 F = ghmpb_fresnelSchlick(F0, saturate(dot(H, V)));
	float D = ghmpb_ndfGGX(NoH, roughness);
	float G = ghmpb_gaSchlickGGX(NoL, NoV, roughness);
	float3 spec = (F * D * G) / max(1e-4, 4.0 * NoL * NoV);
	return spec * radiance * NoL;
}

// Tangent frame from screen derivatives (Mikk-style, from the PBR module)
float3x3 ghmpb_tangentFrame(float3 N, float3 P, float2 uv, out float3 T, out float3 B)
{
	float3 dp1 = ddx(P);
	float3 dp2 = ddy(P);
	float2 duv1 = ddx(uv);
	float2 duv2 = ddy(uv);
	float3x3 M = float3x3(dp1, dp2, cross(dp1, dp2));
	float2x3 inverseM = float2x3(cross(M[1], M[2]), cross(M[2], M[0]));
	T = mul(float2(duv1.x, duv2.x), inverseM);
	B = mul(float2(duv1.y, duv2.y), inverseM);
	float3 Tn = normalize(T + 1e-9);
	float3 Bn = normalize(B + 1e-9);
	return float3x3(Tn, Bn, N);
}

// L1 spherical-harmonic irradiance (coefficients prepared on the CPU from 6 ComputeLighting samples)
float3 ghmpb_shIrradiance(float3 n, float4 shR, float4 shG, float4 shB)
{
	float4 v = float4(1.0, n.x, n.y, n.z);
	return max(float3(dot(shR, v), dot(shG, v), dot(shB, v)), 0.0);
}

// ------------------------------------------------------------------ colour space
// The framebuffer, the model textures and the cubemaps are read as stored (sRGB encoded) and the result is
// written the same way; all the optics (Beer-Lambert, albedo x irradiance, Fresnel, mixing) must happen on
// linear light in between, or thin films and mixes come out too saturated / "painted".
float3 ghmpb_toLinear(float3 c)
{
	c = saturate(c);
	return (c <= 0.04045) ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
// (the cubic fit of the sRGB curve - within 0.2 % of it: a tenth of the instructions of the exact curve; for the many
// framebuffer taps of the world shader's low-pass - 1.18.0. Not everywhere: the exact curve compiles into fewer temp
// registers where it decodes single values)
float3 ghmpb_toLinearFast(float3 c)
{
	c = saturate(c);
	return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}
float3 ghmpb_toSRGB(float3 c)
{
	c = max(c, 0.0);
	return (c <= 0.0031308) ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
// low dynamic range reflections lose how bright lamps and windows really are: pixels near white are
// pushed back up so they still read as bright highlights in the blood (a cheap inverse tone map). Kept
// moderate: a bright sky or sunlit wall boosted too far lays a milky, pink wash over every pool outdoors
float3 ghmpb_reflBoost(float3 lin)
{
	float l = dot(lin, float3(0.2126, 0.7152, 0.0722));
	return lin * (1.0 + 1.5 * smoothstep(0.6, 1.0, l));
}

// ------------------------------------------------------------------ blood optics
// Blood types: 0 red (human), 1 yellow (alien, antlion), 2 green, 3 zombie (necrotic: deoxygenated, partly
// haemolysed and clotted - a dark brown-red with an olive cast). ghmpb_typeW turns a type index into weights,
// so two types can also be mixed per pixel (lerp of the weights of both types).
// (1.26.10c) GHM: "each particle is matching the color of the blood emitted" - the fourth weight is every type from 3 up,
// each with its own spectra (ghmpb_otherWet4 / ghmpb_otherDry4): 3 zombie, 4 synth (Combine synths: a milky blue-white),
// 5 oil (robots, machines: black), 6 blue, 7 purple (NPC packs' own blood colours, VJ Base "Blue" / "Purple"). Before,
// synth and oil blood were drawn as zombie blood here while the particles and decals (Lua) had their own colours. The same
// numbers are in cl_util.lua (U.MUA4) for everything Lua draws.
float4 ghmpb_typeW(float t)
{
	return float4(step(t, 0.5), step(0.5, t) * step(t, 1.5), step(1.5, t) * step(t, 2.5), step(2.5, t));
}
// type pair of a layer: c.y = typeA + 8 * typeB (see GPU.TypePair), f = fraction of type B in this pixel
float4 ghmpb_mixW(float pair, float f)
{
	float tb = floor(pair / 8.0 + 0.01);
	float ta = pair - tb * 8.0;
	return lerp(ghmpb_typeW(ta), ghmpb_typeW(tb), saturate(f));
}
float3 ghmpb_pick3(float4 w, float3 r, float3 y, float3 g, float3 z) { return r * w.x + y * w.y + g * w.z + z * w.w; }
// the type of a pair's fourth weight: the first type of the pair if it is 3 or up, else the second
float ghmpb_otherType(float pair)
{
	float tb = floor(pair / 8.0 + 0.01);
	float ta = pair - tb * 8.0;
	return ta > 2.5 ? ta : tb;
}
// (1.26.10e) the same per pixel: when both types of the pair are from 3 up (zombie and synth, blue and purple ...), the one
// this pixel holds more of (f = fraction of type B). Before, the first one's spectra were used for both - synth blood next
// to zombie blood was drawn brown, purple next to blue blue
float ghmpb_otherTypeAt(float pair, float f)
{
	float tb = floor(pair / 8.0 + 0.01);
	float ta = pair - tb * 8.0;
	return (ta < 2.5 || (f > 0.5 && tb > 2.5)) ? tb : ta;
}
// wet absorption (4 bands, per mm) of the fourth-weight types
float4 ghmpb_otherWet4(float t)
{
	float4 m = float4(10.0, 3.5, 7.0, 22.0);
	m = lerp(m, float4(0.9, 0.75, 0.42, 0.3), step(3.5, t));
	m = lerp(m, float4(25.8, 18.8, 21.0, 52.3), step(4.5, t));
	m = lerp(m, float4(12.0, 8.0, 2.2, 0.28), step(5.5, t));
	return lerp(m, float4(3.5, 0.32, 14.0, 0.45), step(6.5, t));
}
// dried absorption (4 bands, per mm of the wet blood) of the fourth-weight types
float4 ghmpb_otherDry4(float t)
{
	float4 m = float4(16.0, 7.0, 14.0, 22.0);
	m = lerp(m, float4(1.6, 1.4, 0.9, 0.7), step(3.5, t));
	m = lerp(m, float4(26.0, 19.0, 21.0, 52.0), step(4.5, t));
	m = lerp(m, float4(14.0, 10.0, 3.5, 0.9), step(5.5, t));
	return lerp(m, float4(5.0, 0.9, 16.0, 1.4), step(6.5, t));
}
// the same as 3 bands (r, g, b per mm: the dust shaders)
float3 ghmpb_otherWet3(float t)
{
	float3 m = float3(5.5, 8.0, 20.0);
	m = lerp(m, float3(0.8, 0.42, 0.3), step(3.5, t));
	m = lerp(m, float3(21.0, 21.0, 52.0), step(4.5, t));
	m = lerp(m, float3(9.4, 2.2, 0.28), step(5.5, t));
	return lerp(m, float3(1.4, 14.0, 0.45), step(6.5, t));
}
float3 ghmpb_otherDry3(float t)
{
	float3 m = float3(6.0, 12.0, 20.0);
	m = lerp(m, float3(1.5, 0.9, 0.7), step(3.5, t));
	m = lerp(m, float3(21.0, 21.0, 52.0), step(4.5, t));
	m = lerp(m, float3(11.0, 3.5, 0.9), step(5.5, t));
	return lerp(m, float3(2.3, 16.0, 1.4), step(6.5, t));
}
float4 ghmpb_pick4(float4 w, float4 r, float4 y, float4 g, float4 z) { return r * w.x + y * w.y + g * w.z + z * w.w; }

// Absorption per mm of whole blood (one way; the caller doubles it for the path down and back up).
// Red blood from the haemoglobin extinction spectra (Prahl) at ~150 g/l haemoglobin, integrated over the
// sRGB channel bands:  oxygenated  R ~0.8  G ~18  B ~22 /mm;  deoxygenated  R ~3.5  G ~20  B ~34 /mm.
// Deoxygenated (venous, clotting) blood absorbs ~4x more red light, which is why it looks so much darker.
// Thin films therefore stay crimson (not neon: some green / blue still gets through), thick films go
// deep red and venous / clotted blood goes maroon-black.
float3 ghmpb_wetAbsorbW(float4 w, float oxygen)
{
	return ghmpb_pick3(w, lerp(float3(3.5, 24.0, 40.0), float3(0.8, 22.0, 30.0), oxygen),
		float3(0.9, 1.2, 16.0), float3(9.0, 1.4, 11.0), float3(5.5, 8.0, 20.0));
}
float3 ghmpb_wetAbsorb(float bloodType, float oxygen) { return ghmpb_wetAbsorbW(ghmpb_typeW(bloodType), oxygen); }
float3 ghmpb_wetAbsorbWZ(float4 w, float oxygen, float3 z)
{
	return ghmpb_pick3(w, lerp(float3(3.5, 24.0, 40.0), float3(0.8, 22.0, 30.0), oxygen), float3(0.9, 1.2, 16.0), float3(9.0, 1.4, 11.0), z);
}

// Dried blood, per mm of the WET blood it came from: drying removes the water, not the haemoglobin, so a
// stain absorbs about as much as the film it was (the pigment is only packed tighter), shifted to
// met-haemoglobin / haemichrome brown: rust when thin, black-brown when thick. (Per mm of crust this would
// be ~4x higher: a crust is roughly a quarter of the wet thickness.)
float3 ghmpb_dryAbsorbW(float4 w)
{
	return ghmpb_pick3(w, float3(4.0, 18.0, 30.0), float3(2.5, 3.5, 16.0), float3(8.0, 3.0, 10.0), float3(6.0, 12.0, 20.0));
}
float3 ghmpb_dryAbsorb(float bloodType) { return ghmpb_dryAbsorbW(ghmpb_typeW(bloodType)); }
float3 ghmpb_dryAbsorbWZ(float4 w, float3 z)
{
	return ghmpb_pick3(w, float3(4.0, 18.0, 30.0), float3(2.5, 3.5, 16.0), float3(8.0, 3.0, 10.0), z);
}

// Diffuse reflectance of a thick (optically infinite) layer, linear. For red blood from diffusion theory
// with the absorption above and a reduced scattering of ~1.6 /mm (red cells): oxygenated ~(0.16, .005,
// .005) = deep crimson, deoxygenated ~(0.04, .003, .003) = maroon-black. Green slightly above blue:
// real blood has no purple cast.
float3 ghmpb_bodyAlbedoW(float4 w, float oxygen)
{
	return ghmpb_pick3(w, lerp(float3(0.040, 0.0032, 0.0028), float3(0.16, 0.0055, 0.0048), oxygen),
		float3(0.18, 0.14, 0.012), float3(0.035, 0.09, 0.018), float3(0.030, 0.012, 0.005));
}
float3 ghmpb_bodyAlbedo(float bloodType, float oxygen) { return ghmpb_bodyAlbedoW(ghmpb_typeW(bloodType), oxygen); }

// colour of a thick dried crust (linear): red blood dries to a black-brown with a red cast
float3 ghmpb_dryAlbedoW(float4 w)
{
	return ghmpb_pick3(w, float3(0.034, 0.0095, 0.0075), float3(0.11, 0.08, 0.02), float3(0.03, 0.05, 0.015), float3(0.022, 0.013, 0.007));
}
float3 ghmpb_dryAlbedo(float bloodType) { return ghmpb_dryAlbedoW(ghmpb_typeW(bloodType)); }

// ------------------------------------------------------------------ layered optics (Kubelka-Munk, 4 bands)
// Blood is a turbid medium: it absorbs AND scatters. The diffuse reflectance of a layer of thickness d (mm)
// over a background of reflectance Rg follows the Kubelka-Munk two-flux solution
//   a = 1 + K/S,  b = sqrt(a^2 - 1),  t = tanh(b S d),  R = (t - Rg (a t - b)) / (a t - Rg t + b)
// (d -> 0: R = Rg; d -> infinity: R = a - b), with K = 2 mu_a and S = 3/4 mu_s'. One formula covers the whole
// range: a smear tints the surface under it (transmission), a pool shows the blood's own colour (back
// scattering by the red cells) and nothing of the floor, and a clot or a crust scatters more.
// Four wavelength bands: red is split at ~615 nm - haemoglobin still absorbs strongly at 580-610 nm and
// hardly at all above 620 nm, so thin blood is scarlet and deep blood crimson - then green and blue.
// mu_a from the haemoglobin extinction spectra (Prahl) at 150 g/l, per mm:
//   oxygenated    580-610: ~8    620-700: ~0.35   500-580: ~24   430-490: ~26
//   deoxygenated  580-610: ~12   620-700: ~2.4    500-580: ~28   430-490: ~40
// mu_s' of whole blood ~1-1.6 /mm (45 % red cells, g ~ 0.99).
float4 ghmpb_km(float4 K, float4 S, float d, float4 Rg)
{
	float4 a = 1.0 + K / S;
	float4 b = sqrt(a * a - 1.0);
	float4 e = exp(-2.0 * min(b * S * d, 20.0));
	float4 t = (1.0 - e) / (1.0 + e);
	return (t - Rg * (a * t - b)) / max(a * t - Rg * t + b, 1e-5);
}
// band reflectances -> sRGB channels (the red channel sees both red bands, green a little of the 580-610 band)
float3 ghmpb_bands(float4 r) { return float3(0.35 * r.x + 0.65 * r.y, 0.1 * r.x + 0.9 * r.z, 0.12 * r.z + 0.88 * r.w); }
float4 ghmpb_toBands(float3 c) { return float4(c.r, c.r, c.g, c.b); }

// wet blood absorption mu_a (mm^-1) per band: red / yellow (alien) / green / zombie blood
// (1.18.1: yellow absorbed too much in the green band - a pool of it came out orange-brown, not the mustard yellow of
// its body albedo; zombie absorbed as much green as red venous blood and read as the same dark brown: it now keeps
// the olive cast it was meant to have. Thick pools, linear: yellow ~(0.27, 0.21, 0.03), zombie ~(0.04, 0.026, 0.01))
// (1.26.9c) red blood retuned to the look of the shipped shader pack (calibrated in game against it, with the absorption,
// shine and dried-blood scales in cl_util.lua G.SHADER_COMP): the deep-red band holds a little less, green and blue far
// more - fresh blood is the saturated crimson players know instead of a pinkish red, and a dried crust a red-black
// (band factors (1, 0.8, 5, 6) wet and (1, 1, 3.25, 1.25) dried, written into the constants: as a multiply, the surface
// and body shaders ran out of temp registers)
float4 ghmpb_muaWet4W(float4 w, float oxygen)
{
	return ghmpb_pick4(w, lerp(float4(12.0, 2.4 * 0.8, 28.0 * 5.0, 40.0 * 6.0), float4(8.0, 0.35 * 0.8, 24.0 * 5.0, 26.0 * 6.0), oxygen),
		float4(0.5, 0.42, 0.6, 20.0), float4(5.0, 8.0, 1.0, 9.0), float4(10.0, 3.5, 7.0, 22.0));
}
// player hue shift of the blood's absorption (ghmpb_color_hue): + warmer, towards orange-scarlet (much less 580-610 nm
// and green absorption, a little less deep red, more blue), - cooler, towards a deep crimson-purple (more orange / green
// absorption, less blue). Strong enough to show on thick pools, whose colour is set by the weakest absorbing bands
float4 ghmpb_hueMul(float hue) { return float4(exp(-1.6 * hue), exp(-0.3 * hue), exp(-0.8 * hue), exp(1.1 * hue)); }
float4 ghmpb_muaWet4(float bloodType, float oxygen) { return ghmpb_muaWet4W(ghmpb_typeW(bloodType), oxygen); }
// (1.26.10c) the same with the fourth weight's spectrum given (ghmpb_otherWet4 of the pair's type from 3 up)
float4 ghmpb_muaWet4WZ(float4 w, float oxygen, float4 z)
{
	return ghmpb_pick4(w, lerp(float4(12.0, 2.4 * 0.8, 28.0 * 5.0, 40.0 * 6.0), float4(8.0, 0.35 * 0.8, 24.0 * 5.0, 26.0 * 6.0), oxygen),
		float4(0.5, 0.42, 0.6, 20.0), float4(5.0, 8.0, 1.0, 9.0), z);
}
// reduced scattering mu_s' (mm^-1) per band
// (1.20.0: fitted, with the absorption above, to the spectral ground truth - Prahl's haemoglobin spectra, whole blood
// mu_s' ~1.6 (600 / lambda) /mm, Kubelka-Munk layers, CIE 1931 -> linear sRGB; tools/pbr/spectral.py: a thick pool of
// bright blood is ~(0.126, 0.0034, 0.0043) linear, sRGB ~(99, 11, 14) - mean error of the bands 4 sRGB steps, was 6)
float4 ghmpb_musWet4() { return float4(1.54, 1.54, 1.14, 1.72); }

// dried blood (per mm of the WET blood it came from). 1.20.0: fitted (tools/pbr/fitdry.py) to the colours of real
// stains - freshly dried, the haemoglobin is still mostly oxy- / met-haemoglobin: a thin stain on a white surface is a
// rust red-brown ~sRGB (130, 57, 47), a thick crust a glossy red-black ~(46, 18, 15); aged (haemichrome), the red window
// closes: thin ~(105, 64, 52), thick ~(38, 26, 21) black-brown. (1.19 absorbed far more green / blue than red: thin
// stains stayed a saturated red instead of browning.) age 0 freshly dried .. 1 aged
float4 ghmpb_muaDry4W(float4 w, float age)
{
	return ghmpb_pick4(w, lerp(float4(10.0, 2.6, 13.0 * 3.25, 14.5 * 1.25), float4(14.0, 4.4, 11.5 * 3.25, 14.0 * 1.25), age),
		float4(2.0, 2.5, 5.0, 18.0), float4(8.0, 9.0, 4.0, 12.0), float4(16.0, 7.0, 14.0, 22.0));
}
float4 ghmpb_muaDry4(float bloodType) { return ghmpb_muaDry4W(ghmpb_typeW(bloodType), 0.0); }
float4 ghmpb_muaDry4WZ(float4 w, float age, float4 z)
{
	return ghmpb_pick4(w, lerp(float4(10.0, 2.6, 13.0 * 3.25, 14.5 * 1.25), float4(14.0, 4.4, 11.5 * 3.25, 14.0 * 1.25), age),
		float4(2.0, 2.5, 5.0, 18.0), float4(8.0, 9.0, 4.0, 12.0), z);
}
// the porous crust scatters (KM S, per mm of the wet blood)
float4 ghmpb_musDry4W(float4 w, float age)
{
	return lerp(float4(1.0, 1.0, 1.2, 1.4), lerp(float4(0.75, 0.8, 0.7, 0.6), float4(1.1, 1.05, 1.1, 0.9), age), w.x);
}

// ------------------------------------------------------------------ the light on the blood (1.20.0)
// The film shaders recover the irradiance as (lit framebuffer) / (albedo of the surface). Per channel, any error of the
// albedo estimate (the texture's mean colour measured in gamma space, blend / detail textures of displacements, baked
// shading and phong / rim highlights in model textures, very dark textures) came out as coloured, far too strong light:
// pools brighter than the floor in red and 10-25 x too bright in green / blue - orange-red "juice" or paint, and too
// bright for their reflections to show. The light's brightness is taken from the luminances (with a floor under the
// albedo: below ~0.08 the estimate means nothing), and only a little of its colour (light really is coloured - a warm
// lamp - but most of the per-channel ratio is estimation error)
float3 ghmpb_irradiance(float3 fbS, float3 albedo)
{
	float3 Ec = fbS / max(albedo, 0.03);
	float3 tint = clamp(lerp(1.0, Ec / max(ghmpb_luma(Ec), 1e-4), 0.3), 0.6, 1.5);
	return ghmpb_luma(fbS) / max(ghmpb_luma(albedo), 0.08) * tint;
}
// ------------------------------------------------------------------ mirrored UVs (1.20.1)
// Many character models map both legs (both arms, both halves of a face) onto the same part of the texture, one copy
// mirrored. The blood lives in the texture's UV space, so it was shared: a wound on one shin bled on both, and the drips,
// runs and gravity of the shared texels came from whichever leg was drawn last - blood in the wrong place. Such parts get
// two sets of blood targets (cl_entities.lua): one for the triangles whose UV winding is positive, one for the mirrored
// ones; every pass over the model keeps only its own half. The winding: (dP/du x dP/dv) . N, from screen derivatives -
// ddx P x ddy P = (dP/du x dP/dv) * (ddx u ddy v - ddx v ddy u) - the same in the UV-space passes and on screen.
float ghmpb_uvHand(float3 P, float3 N, float2 uv)
{
	float2 du = ddx(uv), dv = ddy(uv);
	return dot(cross(ddx(P), ddy(P)), N) * (du.x * dv.y - du.y * dv.x);
}
// code 0: every triangle, 1: only the positive winding, 2: only the mirrored (negative) one
void ghmpb_handClip(float code, float hand)
{
	if (code > 0.5) clip(code < 1.5 ? hand : -hand);
}

// ------------------------------------------------------------------ reflection probe atlas (1.25.0, cl_probes.lua)
// 1024 x 1024 (1.25.1; was 512): six 128 x 128 cube faces (3 per row from (0, 0)), six 32 x 32 blurred faces (in a row from
// (0, 256)), data at x >= 384 (see ghmpb_shade.h), the floor mirror 1024 x 512 from (0, 512). The faces as render.RenderView
// draws them from Source angles - screen x along the view's right, y along its up: +X (0 0 0), -X (0 180 0), +Y (0 90 0),
// -Y (0 -90 0), +Z (-90 0 0), -Z (90 0 0)
#define GHMPB_PA 1024.0
// face of a direction and where on it (-1..1)
float3 ghmpb_cubeFace(float3 d)
{
	float3 a = abs(d);
	bool xm = a.x >= a.y && a.x >= a.z;
	bool ym = !xm && a.y >= a.z;
	float m = max(xm ? a.x : (ym ? a.y : a.z), 1e-5);
	float sg = (xm ? d.x : (ym ? d.y : d.z)) >= 0.0 ? 1.0 : -1.0;
	float2 st = float2(xm ? -sg * d.y : (ym ? sg * d.x : -d.y), xm ? d.z : (ym ? d.z : -sg * d.x)) / m;
	return float3(st, (xm ? 0.0 : (ym ? 2.0 : 4.0)) + (sg > 0.0 ? 0.0 : 1.0));
}
// and back: the direction through point st of face f
float3 ghmpb_faceDir(float f, float2 st)
{
	float3 d = f < 0.5 ? float3(1.0, -st.x, st.y) : (f < 1.5 ? float3(-1.0, st.x, st.y) : (f < 2.5 ? float3(st.x, 1.0, st.y)
	         : (f < 3.5 ? float3(-st.x, -1.0, st.y) : (f < 4.5 ? float3(-st.y, -st.x, 1.0) : float3(st.y, -st.x, -1.0)))));
	return normalize(d);
}
// atlas uv of a point on a face: tiles of T texels from org, cols per row (kept off the tile's border texels: no bleeding)
float2 ghmpb_faceUV(float3 fs, float T, float2 org, float cols)
{
	float row = floor(fs.z / cols + 0.01);
	float2 tuv = clamp(float2(0.5 + 0.5 * fs.x, 0.5 - 0.5 * fs.y), 0.5 / T, 1.0 - 0.5 / T);
	return (org + (float2(fs.z - row * cols, row) + tuv) * T) / GHMPB_PA;
}

// F0 of wet blood (n ~ 1.39: plasma 1.345 raised by the haemoglobin) and of a dried protein crust (n ~ 1.5)
#define GHMPB_F0_WET 0.027
#define GHMPB_F0_DRY 0.04

#endif
