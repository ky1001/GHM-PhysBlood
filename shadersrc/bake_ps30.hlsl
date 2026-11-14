// GHM PhysBlood: bakes a live cell field into the compact aftermath layer (RGBA8), merging with what the
// aftermath already holds. Encoding: r = sqrt(h / 4 mm), g = sqrt(s / 4 mm), b = fraction of the layer's
// second blood type (volume weighted; settled blood is treated as clotted, its drying sets the clot),
// a = mask (world: 0 = no surface, else 0.25 + 0.75 * (bed height u + 4) / 8); bodies: the explosion dust caught by the
// blood (1.18.0, cl_dust.lua: dust amount / 2 - the world keeps its dust in a target of its own).
// s0 state (h, s, mx, my)  s1 aux (clot volume, -, -, volume of the second blood type)  s2 previous aftermath
// copy  s3 bed map (world patches) / the accumulator (bodies: z = dust)
// c0 = (has previous, use bed mask, time the previous layer has been drying in drying-time units, bodies: carry the dust)
sampler State : register(s0);
sampler Aux   : register(s1);
sampler Old   : register(s2);
sampler Bed   : register(s3);
float4 C0 : register(c0);
struct PS_INPUT { float4 t0 : TEXCOORD0; };
float4 main(PS_INPUT i) : COLOR
{
	float2 uv = i.t0.xy;
	float4 st = tex2Dlod(State, float4(uv, 0, 0));
	float av = tex2Dlod(Aux, float4(uv, 0, 0)).w;
	float h = max(st.x, 0.0), s = max(st.y, 0.0);
	float4 o = C0.x > 0.5 ? tex2Dlod(Old, float4(uv, 0, 0)) : float4(0, 0, 0, 0);
	float hO = o.r * o.r * 4.0, sO = o.g * o.g * 4.0;
	// the previous layer has been drying on screen (thickness dependent, as in ghmpb_shadeFilm): make that
	// permanent before merging, so its clock can restart without old stains looking wet again
	float dp = C0.z > 0.0 ? 1.0 - exp(-clamp(0.3 / (hO + 0.1), 0.25, 0.5) * C0.z) : 0.0;
	sO += hO * dp;
	hO *= 1.0 - dp;
	float hT = hO + h, sT = sO + s;
	float HO = hO + sO, HT = hT + sT;
	float fT = HT > 1e-5 ? saturate((o.b * HO + max(av, 0.0)) / HT) : o.b;
	// world patches: alpha = surface present + the bed height (u, -4 .. 4), so the settled layer is drawn
	// in the joints and dips the blood ran into (parallax, see ghmpb_surface_main.h); bodies: 1
	float a = 1.0;
	if (C0.y > 0.5)
	{
		float4 bd = tex2Dlod(Bed, float4(uv, 0, 0));
		a = bd.y > 0.5 ? 0.25 + 0.75 * saturate((bd.x + 4.0) / 8.0) : 0.0;
		a = max(a, o.a);
	}
	else if (C0.w > 0.5)
	{
		a = saturate(o.a + max(tex2Dlod(Bed, float4(uv, 0, 0)).z, 0.0) * 0.5);
	}
	return float4(sqrt(saturate(hT / 4.0)), sqrt(saturate(sT / 4.0)), fT, a);
}
