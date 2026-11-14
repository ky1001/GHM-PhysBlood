// GHM PhysBlood: the model transform of model_vs30 for the dust drawn over the blood on a body (1.18.0, cl_dust.lua):
// a little more depth bias toward the camera than the blood overlay, so it is drawn over it.
#include "common_vs_fxc.h"
struct VS_INPUT {
	float4 vPos    : POSITION;
	float4 vTex    : TEXCOORD0;
	float3 vNormal : NORMAL0;
};
struct VS_OUTPUT {
	float4 pos  : POSITION;
	float4 uv   : TEXCOORD0;
	float4 wpos : TEXCOORD1;
	float4 wnrm : TEXCOORD2;
	float4 eye  : TEXCOORD3;
};
VS_OUTPUT main(VS_INPUT v)
{
	VS_OUTPUT o;
	float3 wp, wn;
	SkinPositionAndNormal(0, v.vPos, v.vNormal, 0, 0, wp, wn);
	o.pos = mul(float4(wp, 1.0), cViewProj);
	o.pos.z -= 0.00007 * o.pos.w;
	o.uv = float4(v.vTex.xy, 0, 0);
	o.wpos = float4(wp, o.pos.w);
	o.wnrm = float4(wn, 0);
	o.eye = float4(cEyePos, 0);
	return o;
}
