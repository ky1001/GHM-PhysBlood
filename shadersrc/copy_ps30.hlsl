// GHM PhysBlood: exact float copy of a render target (the cells of a body copied onto a severed limb, GHM FLESH)
sampler Src : register(s0);
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };
float4 main(PS_INPUT i) : COLOR { return tex2Dlod(Src, float4(i.t1.xy, 0, 0)); }
