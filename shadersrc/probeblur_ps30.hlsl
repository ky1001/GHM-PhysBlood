// GHM PhysBlood (1.25.0): the blurred faces of a reflection probe atlas, worked out from its sharp faces (a copy of the atlas
// in s0) by direction - across the seams between faces, so rough blood sees no edges. 24 taps in a ~22 deg cone, gaussian
// weighted, averaged in linear light. t0 = atlas uv of the pixel, t1 = (face, tile origin x, tile origin y, tile size).
#include "ghmpb_common.h"
sampler Src : register(s0);
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };
float4 main(PS_INPUT i) : COLOR
{
	float2 local = (i.t0.xy * GHMPB_PA - i.t1.yz) / i.t1.w;
	float3 d = ghmpb_faceDir(i.t1.x, float2(local.x * 2.0 - 1.0, 1.0 - local.y * 2.0));
	float3 tA = normalize(cross(d, abs(d.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0)));
	float3 tB = cross(d, tA);
	float3 acc = 0;
	float wsum = 0;
	[loop] for (int k = 0; k < 24; k++)
	{
		// a golden-angle spiral out to tan(22 deg)
		float r = sqrt((k + 0.5) / 24.0) * 0.4;
		float a = k * 2.39996;
		float3 q = normalize(d + (tA * cos(a) + tB * sin(a)) * r);
		float w = exp(-r * r * 9.0);
		acc += ghmpb_toLinear(tex2Dlod(Src, float4(ghmpb_faceUV(ghmpb_cubeFace(q), 128.0, float2(0, 0), 3.0), 0, 0)).rgb) * w;
		wsum += w;
	}
	return float4(ghmpb_toSRGB(acc / wsum), 1.0);
}
