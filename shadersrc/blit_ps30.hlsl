// GHM PhysBlood: writes the float4 payload of TEXCOORD1 (exact float uploads / clears / data textures)
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };
float4 main(PS_INPUT i) : COLOR { return i.t1; }
