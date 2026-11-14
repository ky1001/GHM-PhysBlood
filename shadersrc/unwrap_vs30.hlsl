// GHM PhysBlood: rasterises a (software skinned) model into its own UV space (the patent's "gravity pass"
// unwrap) while forwarding the posed world position and normal of every texel.
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
};
VS_OUTPUT main(VS_INPUT v)
{
	VS_OUTPUT o;
	float3 wp, wn;
	SkinPositionAndNormal(0, v.vPos, v.vNormal, 0, 0, wp, wn);
	float2 uv = v.vTex.xy;               // triangles outside the unit square are simply clipped
	o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
	o.uv = float4(uv, 0, 0);
	o.wpos = float4(wp, 1);
	o.wnrm = float4(wn, 0);
	return o;
}
