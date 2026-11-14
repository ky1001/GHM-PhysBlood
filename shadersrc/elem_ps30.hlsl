// =====================================================================================
// GHM PhysBlood: element stamps (1.17.0, cl_elements.lua) - what heat, an energy ball, acid or a shock wave does to the
// blood already in a cell field, read from the previous state. A pass of its own next to the impact stamps
// (stamp_ps30: the same impact table and targets, additive), so the impact stamping keeps its registers.
// row0 = position (relative to c0.yzw), radius R (u)       row1 = path since the last application (previous - current,
//        u: a laser sweeping, an energy ball rolling), acid added (mm3)
// row2 = surface normal                                    row3 = op (10 boil, 11 vaporise, 12 acid, 13 shock wave, 14 dust),
//        strength 0..1 of this application at the centre, code (+1024: the acid is the layer's second type), 0
//   10 boil      the water boils off: the wet blood turns into crust
//   11 vaporise  it is gone (a faint ghost of the stain stays)
//   12 acid      dried blood dissolves back into the liquid; the acid itself is added (and mixes as the second type)
//   13 wave      the wet blood is shoved outwards from the centre (its momentum only)
//   14 dust      (1.18.0, cl_dust.lua) what an explosion kicked up settles: it sticks where the blood is wet, a little on
//                dried blood, mostly on what faces up - added into the accumulator's z (the dust amount the shading reads)
// Several applications at one texel in one pass never take more than the blood there.
// c0 = (count, origin.xyz)  c1 = (1/tableW, 1/tableH, time, -)  c2 = (normal window scale, min facing, -, -)
// c3 = (-, -, 1 / target size, -)   s1 = the target's previous state
// out (additive) COLOR0 = (dh, ds, momentum)  COLOR1 = (0, 0, 0, second type volume)  COLOR2 = (0, 0, dust, 0)
// COLOR3 = ghost export
// =====================================================================================
#include "ghmpb_common.h"
sampler Impacts : register(s0);
sampler Prev    : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT { float4 uv : TEXCOORD0; float4 wpos : TEXCOORD1; float4 wnrm : TEXCOORD2; };
struct PS_OUTPUT { float4 state : COLOR0; float4 aux : COLOR1; float4 acc : COLOR2; float4 ex : COLOR3; };

float2 toTexelVel(float3 v, float3 T, float3 B)
{
	float tt = dot(T, T), tb = dot(T, B), bb = dot(B, B);
	float det = tt * bb - tb * tb;
	if (abs(det) < 1e-10) return float2(0, 0);
	float vt = dot(v, T), vb = dot(v, B);
	return float2(bb * vt - tb * vb, tt * vb - tb * vt) / det;
}

PS_OUTPUT main(PS_INPUT i)
{
	float3 P = i.wpos.xyz;
	float3 Nt = normalize(i.wnrm.xyz + 1e-6);
	float3 T = ddx(P);
	float3 B = ddy(P);
	// (1.20.1, bodies: C2.w = which half of a part with mirrored UVs this target holds - see ghmpb_uvHand)
	ghmpb_handClip(C2.w, ghmpb_uvHand(P, Nt, i.uv.xy));
	float4 pv = tex2Dlod(Prev, float4(i.uv.xy, 0, 0));
	float h0 = max(pv.x, 0.0), s0 = max(pv.y, 0.0);
	float4 acc = 0;
	float altAcc = 0.0;
	float dustAcc = 0.0;
	int count = (int)C0.x;
	[loop] for (int k = 0; k < count; k++)
	{
		float u = (k + 0.5) * C1.x;
		float4 r0 = tex2Dlod(Impacts, float4(u, 0.125, 0, 0));
		float4 r1 = tex2Dlod(Impacts, float4(u, 0.375, 0, 0));
		float4 r2 = tex2Dlod(Impacts, float4(u, 0.625, 0, 0));
		float4 r3 = tex2Dlod(Impacts, float4(u, 0.875, 0, 0));
		float R = max(r0.w, 0.01);
		float3 d = P - (r0.xyz + C0.yzw);
		float reach = R * 1.4 + length(r1.xyz) + 0.5;
		if (dot(d, d) > reach * reach) continue;
		float op = floor(abs(r3.x) + 0.5);
		if (op > 13.5)
		{
			// dust: a soft disc around the blast (the cloud settles everywhere it reached; no window to the stamp's plane)
			float fall = saturate(1.0 - length(d) / R);
			dustAcc += saturate(r3.y) * fall * fall * (3.0 - 2.0 * fall) * (0.3 + 0.7 * saturate(Nt.z))
			         * (smoothstep(0.0, 0.06, h0) + 0.25 * smoothstep(0.0, 0.12, s0));
			continue;
		}
		float3 n = normalize(r2.xyz + 1e-6);
		float z = dot(d, n);
		float w = saturate(1.0 - abs(z) / (max(R * 0.7, 0.75) * C2.x)) * saturate((dot(Nt, n) - C2.y) / 0.35);
		if (w <= 0.0) continue;
		// the capsule along the path
		float3 segT = r1.xyz - dot(r1.xyz, n) * n;
		float L = length(segT);
		float3 sdir = L > 1e-3 ? segT / L : float3(0, 0, 0);
		float3 dt3 = d - z * n;
		float dist = length(dt3 - clamp(dot(dt3, sdir), 0.0, L) * sdir);
		float pr = saturate(1.0 - (dist / R) * (dist / R));
		pr = pr * pr * (3.0 - 2.0 * pr);
		float kk = saturate(r3.y) * pr * w;
		float dh = 0.0, ds = 0.0;
		float2 mom = 0;
		if (op < 10.5)
		{
			dh = -h0 * kk;
			ds = h0 * kk;
		}
		else if (op < 11.5)
		{
			dh = -h0 * kk;
			ds = -s0 * kk * 0.7;
		}
		else if (op < 12.5)
		{
			float Rmm = R * 19.05;
			float add = r1.w / (GHMPB_PI * Rmm * Rmm * 0.5) * pr * w;
			dh = s0 * kk + add;
			ds = -s0 * kk;
			altAcc += (floor(floor(r3.z + 0.5) / 1024.0) > 0.5) ? add : 0.0;
		}
		else
		{
			// (the wave weakens outwards; the blood keeps its volume, only its momentum changes)
			float rl = length(dt3);
			float fall = saturate(1.0 - rl / R) * w;
			float2 vt = clamp(toTexelVel(dt3 / max(rl, 1e-3) * saturate(r3.y) * 160.0, T, B), -120.0, 120.0);
			mom = h0 * fall * vt;
		}
		h0 = max(h0 + dh, 0.0);
		s0 = max(s0 + ds, 0.0);
		acc += float4(dh, ds, mom.x, mom.y);
	}
	PS_OUTPUT o;
	o.state = acc;
	o.aux = float4(0, 0, 0, altAcc);
	o.acc = float4(0, 0, dustAcc, 0);
	bool colBorder = i.uv.x < C3.z || i.uv.x > 1.0 - C3.z;
	o.ex = float4(acc.x, 0, 0, colBorder ? acc.z : acc.w);
	return o;
}
