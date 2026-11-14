// GHM PhysBlood (1.25.0): fills the faces of a reflection probe atlas from the map's cubemap (a probe not rendered yet, and
// the fallback probe of blood that has none of its own). Drawn as one quad per tile: t0 = atlas uv of the pixel,
// t1 = (face, tile origin x, tile origin y, tile size); a 32 texel tile is a blurred face: a lower mip of the cubemap.
// The cubemap is read raw (sRGB encoded, as the film shaders read it) and written raw.
#include "ghmpb_common.h"
samplerCUBE Env : register(s0);
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };
float4 main(PS_INPUT i) : COLOR
{
	float2 local = (i.t0.xy * GHMPB_PA - i.t1.yz) / i.t1.w;
	float3 d = ghmpb_faceDir(i.t1.x, float2(local.x * 2.0 - 1.0, 1.0 - local.y * 2.0));
	return float4(texCUBElod(Env, float4(d, i.t1.w < 64.0 ? 3.5 : 0.0)).rgb, 1.0);
}
