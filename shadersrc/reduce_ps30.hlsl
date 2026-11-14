// GHM PhysBlood: readback reduction. Every output pixel sums one block of the lift-off / run-off
// accumulator of a domain, so the CPU can turn the dripping blood into real falling droplets.
// s0 = accumulator (lift, edge-out)  s1 = force (for texel area)  s2 = position (entity domains)
// c0 = (1/W, 1/H, block size in texels, mode 0 entity / 1 patch)
// c1 = (bounds min xyz (entity, relative to origin), volume normaliser mm^3)
// c2 = (bounds size xyz, 0)
// out (RGBA8) = (sqrt(volume/norm), centroid encoded xyz  |  patch: centroid uv, edge fraction)
sampler Acc   : register(s0);
sampler Force : register(s1);
sampler Pos   : register(s2);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; };  // t1.xy = block centre uv in the source
float4 main(PS_INPUT i) : COLOR
{
	float2 px = C0.xy;
	int bs = (int)C0.z;
	float2 origin = i.t1.xy - px * (bs * 0.5);
	float total = 0.0, edge = 0.0;
	float3 cen = 0;
	float2 cuv = 0;
	[loop] for (int y = 0; y < bs; y++)
	{
		[loop] for (int x = 0; x < bs; x++)
		{
			float2 uv = origin + (float2(x, y) + 0.5) * px;
			float4 a = tex2Dlod(Acc, float4(uv, 0, 0));
			float s = a.x + a.y;
			if (s > 1e-6)
			{
				float L = tex2Dlod(Force, float4(uv, 0, 0)).w * 10.0;
				float vol = s * L * L;
				total += vol;
				edge += a.y * L * L;
				cen += tex2Dlod(Pos, float4(uv, 0, 0)).xyz * vol;
				cuv += uv * vol;
			}
		}
	}
	float inv = total > 1e-6 ? 1.0 / total : 0.0;
	float v = sqrt(saturate(total / max(C1.w, 1e-3)));
	if (C0.w > 0.5)
		return float4(v, saturate(cuv * inv), saturate(edge * inv));
	return float4(v, saturate((cen * inv - C1.xyz) / max(C2.xyz, 1e-3)));
}
