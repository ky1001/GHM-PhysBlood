// GHM PhysBlood debug: sample a float target at t1.xy and write it scaled/offset into an RGBA8 target.
sampler Src : register(s0);
float4 C0 : register(c0);   // scale
float4 C1 : register(c1);   // offset
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };
float4 main(PS_INPUT i) : COLOR
{
	return saturate(tex2Dlod(Src, float4(i.t1.xy, 0, 0)) * C0 + C1);
}
