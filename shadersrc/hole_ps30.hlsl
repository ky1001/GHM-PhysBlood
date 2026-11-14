// =====================================================================================
// GHM PhysBlood: bullet holes on bodies (1.26.10, cl_holes.lua). The body is drawn again (model_vs30, the bonemerged
// proxy where it has one) right before its blood layers, and every pixel near a hole is shaded from the lit frame under
// it - so the blood drawn after runs over the holes.
// Analytic, up to 5 holes a pass, from constants: no texture of its own, sharp at any distance, nothing to keep in
// video memory. Modelled on GHM FLESH's bullet decals (fl_stamp_ps30 K_BULLET): an entry is a funnel going dark down
// its channel with a ragged opening of 0.8-1.3 x its radius, the abrasion collar at 1.2 x and a faint bruise; an exit is
// 1.7-2.8 x bigger, star-torn, its everted margin showing torn flesh and a little fat. An oblique shot draws its entry as
// an ellipse along the bullet's path. Seen through the opening: the funnel's wall, found by marching the view ray down
// it (parallax), darker the deeper. GHM FLESH draws its own holes when it is on (cl_holes.lua turns these off then).
// s0 = _rt_FullFrameFB (read in gamma, converted here)
// c0 = (1 / ScrW, 1 / ScrH, time, material: 0 skin, 1 cloth, 2 metal / armour)
// (c1-c3 from $c1-$c3, c11-c14 the rows of $viewprojmat, c15-c18 the rows of $invviewprojmat)
// hole k: P = (position xyz, radius (u)), D = (bullet direction xyz (unit), kind + seed: 0 entry, 1 exit; fraction = seed)
//   hole 0: c1, c2   hole 1: c3, c11   hole 2: c12, c13   hole 3: c14, c15   hole 4: c16, c17
// c18 = (holes in this pass, -, -, -)
// =====================================================================================
#include "ghmpb_common.h"

sampler FB : register(s0);
float4 C0  : register(c0);
float4 H0P : register(c1);
float4 H0D : register(c2);
float4 H1P : register(c3);
float4 H1D : register(c11);
float4 H2P : register(c12);
float4 H2D : register(c13);
float4 H3P : register(c14);
float4 H3D : register(c15);
float4 H4P : register(c16);
float4 H4D : register(c17);
float4 C18 : register(c18);

struct PS_INPUT {
	float4 uv   : TEXCOORD0;
	float4 wpos : TEXCOORD1;
	float4 wnrm : TEXCOORD2;
	float4 eye  : TEXCOORD3;
	float2 vpos : VPOS;
};

float holeR(float4 hp) { return max(hp.w, 0.02); }

// the nearest hole (in units of its radius) of the pass
void pick(float3 P, float4 hp, float4 hd, bool use, inout float best, inout float4 bp, inout float4 bd)
{
	float d = length(P - hp.xyz) / holeR(hp);
	bool take = use && d < best;
	best = take ? d : best;
	bp = take ? hp : bp;
	bd = take ? hd : bd;
}

float4 main(PS_INPUT i) : COLOR
{
	float3 P = i.wpos.xyz;
	float n = C18.x;
	float best = 1e6;
	float4 bp = H0P, bd = H0D;
	pick(P, H0P, H0D, n > 0.5, best, bp, bd);
	pick(P, H1P, H1D, n > 1.5, best, bp, bd);
	pick(P, H2P, H2D, n > 2.5, best, bp, bd);
	pick(P, H3P, H3D, n > 3.5, best, bp, bd);
	pick(P, H4P, H4D, n > 4.5, best, bp, bd);
	// (an exit reaches about 4.5 radii, a bruise 3.5)
	clip(6.0 - best);

	float R = holeR(bp);
	float kind = floor(bd.w + 1e-3);
	float seed = frac(bd.w);
	bool exitW = kind > 0.5;
	float matK = C0.w;
	bool skin = matK < 0.5;
	bool metal = matK > 1.5;
	float3 D = normalize(bd.xyz + 1e-5);
	float3 N = normalize(i.wnrm.xyz);
	float3 V = normalize(P - i.eye.xyz);

	// the surface frame at the hole: T along the bullet's path across the skin (the long axis of an oblique entry)
	float3 q = P - bp.xyz;
	q -= N * dot(q, N);
	float3 Dt = D - N * dot(D, N);
	float dtl = length(Dt);
	float3 T = dtl > 0.05 ? Dt / dtl : normalize(cross(N, float3(0.31, 0.53, 0.79)));
	float3 B = cross(N, T);
	float elong = exitW ? 1.0 : clamp(1.0 / max(abs(dot(D, N)), 0.45), 1.0, 2.0);
	float2 l = float2(dot(q, T) / elong, dot(q, B));
	float r = length(l);
	float ang = atan2(l.y, l.x);
	// a ragged opening (a few angular harmonics, different for every hole) - the exit torn into a star
	float rag = 0.5 + 0.22 * sin(ang * 3.0 + seed * 40.0) + 0.16 * sin(ang * 7.0 + seed * 23.0) + 0.1 * sin(ang * 13.0 + seed * 61.0);
	float star = pow(abs(sin(ang * 2.5 + seed * 9.0)), 6.0);
	float Ro = exitW ? R * (1.7 + 1.1 * seed) * (0.55 + 0.6 * rag + 0.55 * star) : R * (0.8 + 0.5 * rag);
	float Dm = R * (exitW ? 1.4 : 1.8);

	// ---- the funnel seen through the opening: march the view ray down until it meets the wall
	float vn = max(-dot(V, N), 0.0);
	float inside = saturate((Ro - r) / (R * 0.07) + 0.5);
	float hitD = 0.0, hitR = r;
	[branch] if (inside > 0.0 && vn > 0.02)
	{
		float3 Vt = V + N * vn;
		float2 lv = float2(dot(Vt, T) / elong, dot(Vt, B));
		float sMax = Dm / max(vn, 0.3);
		float pw = exitW ? 0.6 : 0.75;
		float zPrev = 0.0, gPrev = -1.0;
		[unroll] for (int k = 1; k <= 8; k++)
		{
			float s = sMax * k / 8.0;
			float2 ls = l + lv * s;
			float rs = length(ls);
			float z = vn * s;
			float wall = Dm * pow(saturate(1.0 - rs / (Ro * 1.15)), pw);
			float g = z - wall;
			[flatten] if (g >= 0.0 && gPrev < 0.0)
			{
				// (the crossing between the two steps)
				float f = saturate(-gPrev / max(g - gPrev, 1e-5));
				hitD = lerp(zPrev, z, f);
				hitR = rs;
			}
			gPrev = (gPrev < 0.0) ? g : gPrev;
			zPrev = (gPrev < 0.0) ? z : zPrev;
		}
		hitD = (gPrev < 0.0) ? Dm : hitD;
	}
	float df = saturate(hitD / Dm);

	float3 fb = ghmpb_toLinear(tex2Dlod(FB, float4((i.vpos + 0.5) * C0.xy, 0, 0)).rgb);
	// the light at this spot (from the skin's own lit colour: an albedo of about 0.3 assumed)
	float L = clamp(ghmpb_luma(fb) / 0.3, 0.0, 3.0);
	float nz = ghmpb_vnoise(float2(ang * 3.0 + seed * 17.0, hitR / R * 4.0));

	// ---- around the opening
	float3 col = fb;
	float rr = r / R;
	// bruise: skin only, a faint purple halo (bigger round an exit)
	float br = skin ? exp(-rr * rr / (exitW ? 12.0 : 7.0)) * 0.35 : 0.0;
	col *= lerp(float3(1.0, 1.0, 1.0), float3(0.78, 0.66, 0.8), br);
	// entry: the abrasion collar - the skin the bullet rubbed off as it pushed in, a reddish-brown ring
	float collar = (!exitW && skin) ? exp(-pow((r - Ro * 1.22) / (Ro * 0.3), 2.0)) * smoothstep(Ro * 0.9, Ro * 1.05, r) : 0.0;
	col = lerp(col, L * float3(0.34, 0.11, 0.08), collar * 0.75);
	// exit: the everted margin - torn flesh turned out at the edge, pinker
	float lip = (exitW && !metal) ? exp(-pow((r - Ro * 1.05) / (R * 0.3), 2.0)) * (0.6 + 0.4 * nz) : 0.0;
	col = lerp(col, L * float3(0.5, 0.16, 0.13), lip * 0.7);
	// cloth: frayed threads round the hole (lighter), metal: the bare metal of the rim and soot beyond
	float fray = (matK > 0.5 && !metal) ? exp(-pow((r - Ro * 1.12) / (R * 0.22), 2.0)) * (0.5 + 0.5 * nz) : 0.0;
	col = lerp(col, fb * 1.3, fray * 0.5);
	float rimM = metal ? exp(-pow((r - Ro * 1.1) / (R * 0.18), 2.0)) : 0.0;
	float soot = metal ? exp(-rr * rr / 6.0) * 0.5 : 0.0;
	col *= 1.0 - soot;
	col = lerp(col, fb * 1.8 + L * 0.04, rimM * 0.7);
	// the torn edge itself: a thin dark line round the opening
	float edge = exp(-pow((r - Ro) / (R * 0.11), 2.0));
	col = lerp(col, L * (metal ? float3(0.02, 0.02, 0.02) : float3(0.13, 0.025, 0.02)), edge * 0.7);

	// ---- inside: the channel's wall, deep red flesh going black down the channel (a little fat in the torn exit)
	float3 wallA = metal ? float3(0.012, 0.012, 0.012)
	             : (matK > 0.5 ? float3(0.05, 0.01, 0.009)
	             : (exitW ? lerp(float3(0.42, 0.085, 0.065), float3(0.05, 0.008, 0.007), df)
	                      : lerp(float3(0.28, 0.04, 0.032), float3(0.03, 0.004, 0.004), sqrt(df))));
	float fat = (exitW && skin) ? step(0.72, nz) * (1.0 - smoothstep(0.15, 0.45, df)) : 0.0;
	wallA = lerp(wallA, float3(0.55, 0.42, 0.22), fat * 0.7);
	float3 hole = L * wallA * (1.0 - 0.85 * df);
	col = lerp(col, hole, inside);

	float mask = max(max(inside, collar * 0.75), max(max(edge * 0.7, lip * 0.7), max(br * 0.35, max(fray * 0.5, max(rimM, soot)))));
	clip(mask - 0.004);
	return float4(col, 1.0);
}
