// GHM PhysBlood: pass-through for 2D passes. Positions are supplied in clip space by Lua
// (mesh quads inside cam.Start2D), four float4 texcoord payload channels are forwarded.
struct VS_INPUT {
	float4 vPos  : POSITION;
	float4 vTex0 : TEXCOORD0;
	float4 vTex1 : TEXCOORD1;
	float4 vTex2 : TEXCOORD2;
	float4 vTex3 : TEXCOORD3;
};
struct VS_OUTPUT {
	float4 pos : POSITION;
	float4 t0  : TEXCOORD0;
	float4 t1  : TEXCOORD1;
	float4 t2  : TEXCOORD2;
	float4 t3  : TEXCOORD3;
};
VS_OUTPUT main(VS_INPUT v)
{
	VS_OUTPUT o;
	o.pos = float4(v.vPos.xy, 0.5, 1.0);
	o.t0 = v.vTex0; o.t1 = v.vTex1; o.t2 = v.vTex2; o.t3 = v.vTex3;
	return o;
}
