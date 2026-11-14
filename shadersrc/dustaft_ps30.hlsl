// =====================================================================================
// GHM PhysBlood: explosion dust settling on settled blood (1.18.0, cl_dust.lua) - the aftermath counterpart of op 14
// of elem_ps30: what lands where the settled layer is still wet sticks (a little on dried blood, mostly on what faces
// up), added into where the layer keeps its dust: world layers in b of a dust target of their own, bodies in a of their
// aftermath target (read here through a copy of it). Additive.
// The same impact table as the element stamps: row0 = position (relative to c0.yzw), radius R (u); row3.y = strength.
// c0 = (count, origin xyz)  c1 = (1/tableW, 1/tableH, how long the layer has been drying (drying-time units),
// out: 0 -> b, 1 -> a)   s0 impact table   s1 the aftermath layer (r = sqrt(h / 4 mm), g = sqrt(s / 4 mm))
// =====================================================================================
#include "ghmpb_common.h"
sampler Impacts : register(s0);
sampler Aft     : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);     // (1.20.1, bodies) x = which half of a part with mirrored UVs this target holds

struct PS_INPUT { float4 uv : TEXCOORD0; float4 wpos : TEXCOORD1; float4 wnrm : TEXCOORD2; };

float4 main(PS_INPUT i) : COLOR
{
	float3 P = i.wpos.xyz;
	float3 Nt = normalize(i.wnrm.xyz + 1e-6);
	ghmpb_handClip(C2.x, ghmpb_uvHand(P, Nt, i.uv.xy));
	float4 a = tex2Dlod(Aft, float4(i.uv.xy, 0, 0));
	float h = a.r * a.r * 4.0, s = a.g * a.g * 4.0;
	// (the layer keeps drying on screen: as in ghmpb_filmPre)
	float dryP = C1.z > 0.0 ? 1.0 - exp(-GHMPB_DRYK(h) * C1.z) : 0.0;
	float hw = h * (1.0 - dryP), sT = s + h * dryP;
	float stick = smoothstep(0.0, 0.06, hw) + 0.25 * smoothstep(0.0, 0.12, sT);
	float dust = 0.0;
	int count = (int)C0.x;
	[loop] for (int k = 0; k < count; k++)
	{
		float u = (k + 0.5) * C1.x;
		float4 r0 = tex2Dlod(Impacts, float4(u, 0.125, 0, 0));
		float4 r3 = tex2Dlod(Impacts, float4(u, 0.875, 0, 0));
		float fall = saturate(1.0 - length(P - (r0.xyz + C0.yzw)) / max(r0.w, 0.01));
		dust += saturate(r3.y) * fall * fall * (3.0 - 2.0 * fall);
	}
	dust *= stick * (0.3 + 0.7 * saturate(Nt.z)) * 0.5;
	return C1.w > 0.5 ? float4(0, 0, 0, dust) : float4(0, 0, dust, 0);
}
