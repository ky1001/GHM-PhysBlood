// GHM PhysBlood: flying droplet shading. A velocity-stretched sphere impostor for the drop body with a
// tapering motion trail behind it. The body colour comes from the same blood optics as the films
// (Kubelka-Munk over the chord through the drop, Saunderson surface correction): the scene behind shows
// through a fine droplet as a red glow, a bigger one is an opaque deep crimson. GGX highlights from the key light and
// Fresnel reflection of the environment (1.25.0: no refraction of the scene behind any more). The trail is
// what a camera shutter sees of the moving drop: thinner and fading towards its end.
// s0 = framebuffer copy, s1 = env cubemap
// c0 = (1/ScrW, 1/ScrH, hue shift -1..1, fresh-blood absorption scale)   (blood type and oxygen come per drop from
// the vertex shader: axes.w, eye.w)  c1 = key light dir xyz, ambient scale  c2 = key light colour rgb, exposure
// c3 = ambient colour rgb, env scale
#include "ghmpb_common.h"
sampler FB  : register(s0);
samplerCUBE Env : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);
struct PS_INPUT {
	float4 corner : TEXCOORD0;
	float4 vel    : TEXCOORD1;
	float4 wpos   : TEXCOORD2;
	float4 axes   : TEXCOORD3;
	float4 eye    : TEXCOORD4;
	float2 vpos   : VPOS;
};

// colour of a piece of blood seen along N from V, chordMM thick, with the scene behind it
// (1.20.0: blood is turbid - its red cells scatter ~100 times per mm. 1.19 let the scene through a drop along the chord
// with the reduced scattering only, so drops were clear red glass beads - juice. The scene behind is now only seen as the
// diffusely transmitted glow of the red band through small drops (Kubelka-Munk transmission); a drop of a few mm is opaque)
float3 shadeBlood(float3 N, float3 V, float chordMM, float2 suv, float zc, float btype, float oxy)
{
	float hue = C0.z;
	// (1.26.10c) every blood type with its own colour (the types from 3 up: ghmpb_otherWet4)
	float4 mua = ghmpb_muaWet4WZ(ghmpb_typeW(btype), oxy, ghmpb_otherWet4(btype)) * ghmpb_hueMul(hue) * C0.w;
	float4 mus = ghmpb_musWet4();
	// light scattered back out of the drop (thick: the blood's own colour) and the scene seen through it
	float4 K = 2.0 * mua, S = 0.75 * mus;
	float4 Rkm = ghmpb_km(K, S, chordMM, float4(0, 0, 0, 0));
	Rkm = 0.94 * 0.52 * Rkm / (1.0 - 0.48 * Rkm);
	float4 a = 1.0 + K / S;
	float4 b = sqrt(a * a - 1.0);
	float4 x = min(b * S * chordMM, 20.0);
	float4 ex = exp(x), emx = exp(-x);
	// (1.25.0: no refraction - a drop is not a glass bead. Only a fine droplet lets a little of the scene straight behind it
	// glow through; from ~0.8 mm through the drop it is opaque, the blood's own colour)
	float3 T = ghmpb_bands(b / (a * 0.5 * (ex - emx) + b * 0.5 * (ex + emx))) * 0.5 * (1.0 - smoothstep(0.25, 0.8, chordMM));
	float3 behind = ghmpb_toLinear(tex2D(FB, suv).rgb);
	float3 Elight = C3.rgb * C1.w + C2.rgb * saturate(dot(N, C1.xyz));
	float3 col = behind * T + ghmpb_bands(Rkm) * Elight;
	float NoV = saturate(dot(N, V));
	float3 F = ghmpb_fresnelSchlick(float3(GHMPB_F0_WET, GHMPB_F0_WET, GHMPB_F0_WET), NoV);
	float3 R = reflect(-V, N);
	float3 env = ghmpb_reflBoost(ghmpb_toLinear(texCUBE(Env, R).rgb)) * C3.w;
	col = col * (1.0 - F) + env * F;
	col += ghmpb_specGGX(N, V, C1.xyz, C2.rgb, float3(GHMPB_F0_WET, GHMPB_F0_WET, GHMPB_F0_WET), 0.06) * C2.w;
	return col;
}

float4 main(PS_INPUT i) : COLOR
{
	float r = max(i.corner.z, 1e-4);
	float st = max(i.corner.w, 1.0);
	float trail = i.vel.w;
	float x = i.corner.x;
	float a = i.corner.y;
	float3 V = normalize(i.eye.xyz - i.wpos.xyz);
	float3 axis = normalize(i.axes.xyz);
	float3 side = normalize(cross(V, axis));
	float2 suv = (i.vpos + 0.5) * C0.xy;

	// ---------------- drop body
	float2 cb = float2(x / r, a / (r * st));
	float rb = dot(cb, cb);
	if (rb <= 1.0)
	{
		float zc = sqrt(saturate(1.0 - rb));
		float3 N = normalize(side * cb.x + axis * cb.y + V * zc);
		float chord = r * 19.05 * zc * 2.0;                        // mm through the drop
		return float4(ghmpb_toSRGB(shadeBlood(N, V, chord, suv, zc, i.axes.w, i.eye.w)), 1.0);
	}

	// ---------------- motion trail (behind the drop)
	float a0 = r * st * 0.5;
	float ta = saturate((-a - a0) / max(trail + r * st - a0, 1e-4));    // 0 at the drop .. 1 at the end
	float w = r * lerp(0.85, 0.12, ta);                                  // starts as wide as the drop, tapers off
	float s = x / w;
	clip(trail - r * 0.3);
	clip(-a - a0 * 0.2);
	clip(1.0 - abs(s));
	clip(1.0 - ta);
	float zt = sqrt(saturate(1.0 - s * s));
	float3 Nt = normalize(side * s + V * zt);
	float3 col = shadeBlood(Nt, V, w * 19.05 * zt * 2.0, suv, zt * 0.5, i.axes.w, i.eye.w);
	float alpha = pow(1.0 - ta, 1.25) * 0.85 * saturate(trail / (r * 3.0)) * smoothstep(0.0, 0.35, zt);
	float3 behind = ghmpb_toLinear(tex2D(FB, suv).rgb);
	return float4(ghmpb_toSRGB(lerp(behind, col, alpha)), 1.0);
}
