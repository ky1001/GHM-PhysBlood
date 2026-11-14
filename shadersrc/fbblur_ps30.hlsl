// GHM PhysBlood (1.26.11): quarter-resolution linear-light scene low-pass for the two-pass enhanced world blood surface.
// Replaces the per-pixel 11-tap framebuffer blur loop inside every overlapping blood patch with a single 13-tap dual-ring
// Kawase-disc pass over _rt_FullFrameFB once per frame, freeing ~400 instruction slots and temp registers in the world pass.
#include "ghmpb_common.h"

sampler Src : register(s0);
float4 SC0 : register(c0);

struct PS_INPUT
{
	float4 t0 : TEXCOORD0;
};

float3 tapLin(float2 uv)
{
	return ghmpb_toLinear(tex2Dlod(Src, float4(saturate(uv), 0.0, 0.0)).rgb);
}

float4 main(PS_INPUT i) : COLOR
{
	float2 uv = i.t0.xy;
	// SC0.xy = (1 / sw, 1 / sh) of the full-resolution framebuffer; rings at 14 px and 38 px match fbBlur's optical footprint
	float2 r1 = SC0.xy * 14.0;
	float2 r2 = SC0.xy * 38.0;

	float3 acc = tapLin(uv) * 0.16;
	[unroll] for (int k = 0; k < 6; k++)
	{
		float a = k * 1.04719755 + 0.28;
		acc += tapLin(uv + float2(cos(a), sin(a)) * r1) * 0.085;
	}
	[unroll] for (int k2 = 0; k2 < 6; k2++)
	{
		float a2 = k2 * 1.04719755 + 0.8035988;
		acc += tapLin(uv + float2(cos(a2), sin(a2)) * r2) * 0.055;
	}
	return float4(ghmpb_toSRGB(acc), 1.0);
}
