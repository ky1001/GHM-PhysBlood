// GHM PhysBlood: per-texel force field of a character / prop in its UV space (the patent's gravity pass),
// extended with the texel's own measured acceleration so that a swinging arm, a spinning or falling
// ragdoll and a shaking body push the blood around ("rotation / stretch force").
//   s0 = position history t-1 (xyz relative to originPrev, w valid)
//   s1 = position history t-2 (xyz relative to originPrev2, w valid)
//   s2 = the material's normal map (white = none): like the NVIDIA HLSL blood shader, surface detail
//        (folds, wrinkles, muscle grooves, seams) steers the flow: the tangential force is taken against
//        the bumped normal, so blood runs along grooves instead of straight down
//   c0 = gravity cm/s^2 (xyz), dt1        c1 = originNow (xyz), dt2
//   c2 = originPrev (xyz), history level  c3 = originPrev2 (xyz), motion influence 0..1 + 4 * mirrored-UV half (1.20.1,
//   0 all, 1 positive winding, 2 mirrored - see ghmpb_uvHand)
// MRT: COLOR0 = (Ax, Ay, An, L) force,  COLOR1 = (pos - originNow, 1 + 0.45 * concavity) position history for the
// next pass (w > 0.5 = valid) and the surface curvature for the sim
#include "ghmpb_common.h"
sampler PosPrev  : register(s0);
sampler PosPrev2 : register(s1);
sampler Bump     : register(s2);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT { float4 uv : TEXCOORD0; float4 wpos : TEXCOORD1; float4 wnrm : TEXCOORD2; };
struct PS_OUTPUT { float4 force : COLOR0; float4 pos : COLOR1; };

PS_OUTPUT main(PS_INPUT i)
{
	PS_OUTPUT o;
	float3 P = i.wpos.xyz;
	float3 N = normalize(i.wnrm.xyz + 1e-6);
	float3 Tc = ddx(P) * GHMPB_UNITS_TO_CM;   // cm per texel along +x
	float3 Bc = ddy(P) * GHMPB_UNITS_TO_CM;   // cm per texel along +y (down the texture)
	float L = sqrt(length(cross(Tc, Bc)));
	float hcode = floor(C3.w / 4.0 + 1e-3);
	float motion = saturate(C3.w - 4.0 * hcode);
	ghmpb_handClip(hcode, ghmpb_uvHand(P, N, i.uv.xy));
	// normal map (skipped when the slot is bound to plain white = model without one)
	// (derivatives are taken outside any branch)
	float3 Tw, Bw;
	float3x3 tbn = ghmpb_tangentFrame(N, P, i.uv.xy, Tw, Bw);
	float3 nt = tex2Dlod(Bump, float4(i.uv.xy, 0, 0)).xyz;
	float hasBump = (nt.x > 0.98 && nt.y > 0.98 && nt.z > 0.98) ? 0.0 : 0.65;
	float3 Ns = normalize(mul(nt * 2.0 - 1.0, tbn));
	N = normalize(lerp(N, Ns, hasBump));

	float3 aEff = C0.xyz;
	if (C2.w > 1.5)
	{
		float4 p1 = tex2Dlod(PosPrev, float4(i.uv.xy, 0, 0));
		float4 p2 = tex2Dlod(PosPrev2, float4(i.uv.xy, 0, 0));
		if (p1.w > 0.5 && p2.w > 0.5)
		{
			float3 Pp = p1.xyz + C2.xyz;
			float3 Pp2 = p2.xyz + C3.xyz;
			float3 v1 = (P - Pp) / max(C0.w, 1e-3);
			float3 v0 = (Pp - Pp2) / max(C1.w, 1e-3);
			float3 aMot = (v1 - v0) / max(0.5 * (C0.w + C1.w), 1e-3) * GHMPB_UNITS_TO_CM;
			float am = length(aMot);
			aMot *= min(1.0, 2600.0 / max(am, 1e-3));   // reject teleports / bone snaps
			aEff -= aMot * motion;
		}
	}
	float An = dot(aEff, N);
	float3 at = aEff - An * N;
	float Ax = dot(at, normalize(Tc + 1e-7));
	float Ay = dot(at, normalize(Bc + 1e-7));
	bool ok = (L > 1e-4) && (L < 50.0);
	o.force = ok ? float4(Ax, Ay, An, L) : float4(0, 0, 0, 0);
	// concavity of the (bumped) surface for the sim (w = 1 + 0.45 * concavity, still > 0.5 = valid history):
	// creases, clothing folds and the gaps between limbs catch runs, ridges shed them
	float3 dNx = ddx(N), dNy = ddy(N);
	float divN = dot(dNx, normalize(Tc + 1e-7)) / max(length(Tc), 1e-4) + dot(dNy, normalize(Bc + 1e-7)) / max(length(Bc), 1e-4);
	float conc = clamp(-divN * 1.2, -1.0, 1.0);
	o.pos = float4(P - C1.xyz, 1.0 + 0.45 * conc);
	return o;
}
