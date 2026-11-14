// GHM PhysBlood: world_vs30 for the dust drawn over the blood on world surfaces (1.18.0, cl_dust.lua): a little more
// depth bias toward the camera than the blood, so it is drawn over it.
#include "common_vs_fxc.h"
struct VS_INPUT {
	float4 vPos  : POSITION;
	float4 vTex0 : TEXCOORD0;
	float4 vTex1 : TEXCOORD1;
	float4 vTex2 : TEXCOORD2;
	float4 vTex3 : TEXCOORD3;
};
struct VS_OUTPUT {
	float4 pos  : POSITION;
	float4 t0   : TEXCOORD0;
	float4 t1   : TEXCOORD1;
	float4 t2   : TEXCOORD2;
	float4 t3   : TEXCOORD3;
	float4 wpos : TEXCOORD4;
	float4 eye  : TEXCOORD5;
	float4 vp0  : TEXCOORD6;     // view-projection columns (world -> clip) for screen-space reflections
	float4 vp1  : TEXCOORD7;
	float4 vp2  : TEXCOORD8;
	float4 vp3  : TEXCOORD9;
};
VS_OUTPUT main(VS_INPUT v)
{
	VS_OUTPUT o;
	float3 wp;
	SkinPosition(0, v.vPos, 0, 0, wp);
	o.pos = mul(float4(wp, 1.0), cViewProj);
	o.pos.z -= 0.00006 * o.pos.w;
	o.t0 = v.vTex0; o.t1 = v.vTex1; o.t2 = v.vTex2; o.t3 = v.vTex3;
	o.wpos = float4(wp, o.pos.w);
	o.eye = float4(cEyePos, 0);
	float4x4 vpT = transpose(cViewProj);
	o.vp0 = vpT[0]; o.vp1 = vpT[1]; o.vp2 = vpT[2]; o.vp3 = vpT[3];
	return o;
}
