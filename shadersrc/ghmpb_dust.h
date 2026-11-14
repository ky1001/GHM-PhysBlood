// =====================================================================================
// GHM PhysBlood: explosion dust caught by the blood (1.18.0, cl_dust.lua), drawn over the blood of a world layer or a
// body that has some (alpha blended: a pass of its own, so the film shaders keep their registers - they are at the
// ps_3_0 limit).
// A blast kicks up whatever the ground is made of - sand, snow, soil, concrete or plaster dust, brick, splinters, grit -
// with the explosive's soot, and it settles over the area for a few seconds. On dry ground it is lost in the ground; on
// fresh blood it sticks: the wet blood catches it in clumps (rafts and crusts on a pool, specks on a thin film), draws
// itself up into it (wet dust darkens and takes on the colour of the blood it drank) and dries with it into a gritty
// crust. Snow melts into the warm blood: grey-pink slush.
// Dust amount per texel: live layers in the accumulator's z (elem_ps30 op 14), settled world layers in b of a dust target
// of their own, settled bodies in a of their aftermath target (dustaft_ps30, bake_ps30).
//   c0 = (1/ScrW, 1/ScrH, 1/target size, -)
//   c1 = (dust kind + 16 x soot (0..7), blood type pair, oxygen, settled: 0 live / 1 aftermath + 2 x smooth mode)
//   c2 = weights of the dust source's channels (live: z; world aftermath: 2 b; body aftermath: 2 a)
//   c3 = (surface albedo rgb (world), drying of the settled layer (drying-time units))
//   c11 sun dir, visibility  c12 sun colour, layer fade  c13 key light dir, -  c14 key light colour, -
//   c15..c17 light probe SH (r, g, b)
// =====================================================================================
#include "ghmpb_common.h"
float4 DC0 : register(c0);
float4 DC1 : register(c1);
float4 DC2 : register(c2);
float4 DC3 : register(c3);
float4 DC11 : register(c11);
float4 DC12 : register(c12);
float4 DC13 : register(c13);
float4 DC14 : register(c14);
float4 DC15 : register(c15);
float4 DC16 : register(c16);
float4 DC17 : register(c17);

// dust kinds (sh_config.lua G.DustKindOf): the linear albedo of the dry dust
float3 ghmpb_dustAlbedo(float k)
{
	if (k < 1.5) return float3(0.54, 0.40, 0.22);    // 1 sand
	if (k < 2.5) return float3(0.83, 0.87, 0.91);    // 2 snow
	if (k < 3.5) return float3(0.16, 0.10, 0.055);   // 3 soil, mud
	if (k < 4.5) return float3(0.38, 0.36, 0.33);    // 4 concrete, stone, asphalt dust
	if (k < 5.5) return float3(0.74, 0.71, 0.64);    // 5 plaster, drywall, paper
	if (k < 6.5) return float3(0.35, 0.11, 0.055);   // 6 brick
	if (k < 7.5) return float3(0.50, 0.31, 0.13);    // 7 wood: splinters and sawdust
	if (k < 8.5) return float3(0.045, 0.042, 0.04);  // 8 soot and fine grit (metal, glass, tiles, rubber)
	if (k < 9.5) return float3(0.12, 0.13, 0.05);    // 9 soil and shredded grass
	return float3(0.25, 0.23, 0.21);                 // 10 gravel grit
}
// grain frequency (per unit of the crack-cell coordinate, ~0.45 u): coarse sand and grit, fine powders
float ghmpb_dustGrain(float k)
{
	if (k < 1.5) return 2.2;
	if (k < 2.5) return 1.6;
	if (k < 3.5) return 1.4;
	if (k < 4.5) return 2.8;
	if (k < 5.5) return 3.2;
	if (k < 6.5) return 2.0;
	if (k < 7.5) return 1.1;
	if (k < 8.5) return 3.6;
	if (k < 9.5) return 1.2;
	return 0.9;
}

// d dust amount, h / s wet and dried blood (mm), gp the crack-cell coordinate, aa 0..1 how far the grain is below a pixel,
// E the irradiance (framebuffer units), Ng the surface normal, alt / oxy as for the film: colour (linear) and coverage
float4 ghmpb_dustShade(float d, float h, float s, float2 gp, float aa, float3 E, float3 Ng, float3 P, float alt, float oxy)
{
	float word = floor(DC1.x + 0.5);
	float soot = floor(word / 16.0 + 1e-3);
	float k = word - soot * 16.0;
	soot /= 7.0;
	float gF = ghmpb_dustGrain(k);
	// coverage: the wet blood catches the dust in clumps and specks (a little dust: scattered specks and small rafts;
	// a lot: a crust with holes where the blood shows through), the grains show at their edges
	float gn = ghmpb_vnoise(gp * gF + 8.1);
	float t = 0.5 * ghmpb_vnoise(gp * 0.33 + 2.7) + 0.5 * gn;
	float dm = min(d, 1.25);
	float cov = smoothstep(0.80 - 0.42 * dm, 0.95 - 0.42 * dm, t);
	cov = lerp(cov, saturate(dm * 0.7), aa);
	cov *= saturate((h + s * 0.6) / 0.03);
	// colour: the ground's dust, with the explosive's soot near the blast
	float3 alb = lerp(ghmpb_dustAlbedo(k), float3(0.03, 0.028, 0.027), soot);
	float snow = step(1.5, k) * step(k, 2.5);
	// blood drawn up into the dust: the light scattered between the grains crosses the blood between them many times
	// (soaked through: blood-dark, maroon-brown; the grains sticking out of a thick crust stay lighter), browning as it
	// dries. Snow melts into it and dilutes it: pink to red slush.
	float wet = smoothstep(0.02, 0.35, h);
	float soak = saturate((h + s * 0.7) / (0.08 + 0.3 * dm));
	float soakG = soak * saturate(0.25 + 1.1 * (1.0 - gn) + 0.4 * (1.0 - dm));
	float dry = saturate(s / max(h + s, 1e-3));
	float4 tw = ghmpb_mixW(DC1.y, alt);
	// (1.26.10c) the types from 3 up with their own colours
	float tO = ghmpb_otherType(DC1.y);
	float3 mua = lerp(ghmpb_wetAbsorbWZ(tw, oxy, ghmpb_otherWet3(tO)), ghmpb_dryAbsorbWZ(tw, ghmpb_otherDry3(tO)), dry);
	alb *= exp(-mua * (soakG * lerp(0.32, 0.1, snow)));
	// wet grains are darker (the liquid between them traps the light scattered inside)
	alb *= lerp(1.0, lerp(0.5, 0.8, snow), wet * soakG);
	// (and the grains' own surfaces, coated or not, reflect a little white: soaked sand is red-brown, not pure red)
	alb += 0.028 * soakG;
	cov *= 1.0 - 0.35 * snow * wet;
	// grain relief, lit by the light probe like the blood's relief
	float2 gg = ghmpb_vnoise_grad(gp * gF * 1.7 + 3.1) + 0.6 * ghmpb_vnoise_grad(gp * 0.33 + 2.7);
	float3 Tt = normalize(cross(Ng, float3(0.57, 0.31, 0.76)));
	float3 Bt = cross(Ng, Tt);
	float3 Nd = normalize(Ng + (Tt * gg.x + Bt * gg.y) * (0.3 * (1.0 - aa)));
	float base = max(ghmpb_luma(ghmpb_shIrradiance(Ng, DC15, DC16, DC17)), 1e-3);
	float relief = clamp(ghmpb_luma(ghmpb_shIrradiance(Nd, DC15, DC16, DC17)) / base, 0.6, 1.5);
	float3 col = E * alb * relief;
	// the blood between the grains of a wet crust glints a little in the sun / key light
	float kx = clamp(ghmpb_luma(E) / base, 0.0, 6.0);
	float3 V = normalize(gEye - P);
	bool sun = ghmpb_luma(DC12.rgb * DC11.w) > ghmpb_luma(DC14.rgb) * 0.5;
	col += ghmpb_specGGX(Nd, V, normalize(sun ? DC11.xyz : DC13.xyz), sun ? DC12.rgb * DC11.w : DC14.rgb * 0.5,
	                     float3(0.03, 0.03, 0.03), 0.3) * (kx * 0.5 * wet * (1.0 - 0.5 * snow));
	return float4(col, cov);
}

#if GHMPB_DUSTBODY
// ---------------------------------------------------------------- bodies (model_vs30 / modeldust_vs30)
// s0 the blood (live state | aftermath)  s1 _rt_FullFrameFB  s2 the model's $basetexture  s3 the dust source
sampler State  : register(s0);
sampler FB     : register(s1);
sampler Albedo : register(s2);
sampler DustT  : register(s3);
struct PS_INPUT { float4 uv : TEXCOORD0; float4 wpos : TEXCOORD1; float4 wnrm : TEXCOORD2; float4 eye : TEXCOORD3; float2 vpos : VPOS; };
float4 main(PS_INPUT i) : COLOR
{
	gEye = i.eye.xyz;
	// (1.20.1: DC3.x = which half of a part with mirrored UVs this layer holds - see ghmpb_uvHand)
	ghmpb_handClip(DC3.x, ghmpb_uvHand(i.wpos.xyz, normalize(i.wnrm.xyz), i.uv.xy));
	float tx = DC0.z;
	float2 uv0 = i.uv.xy;
	float2 uv = uv0 + 0.5 * tx;
	float smoothMode = floor(DC1.w / 2.0 + 1e-3);
	float settled = DC1.w - smoothMode * 2.0;
	if (smoothMode > 1.5)
	{
		float2 q = uv0 / tx * 0.45;
		uv += (float2(ghmpb_vnoise(q), ghmpb_vnoise(q + 37.1)) - 0.5) * tx * 1.4;
	}
	float4 st = tex2Dlod(State, float4(uv, 0, 0));
	float h = settled > 0.5 ? st.r * st.r * 4.0 : max(st.x, 0.0);
	float s = settled > 0.5 ? st.g * st.g * 4.0 : max(st.y, 0.0);
	float dryP = DC3.w > 0.0 ? 1.0 - exp(-GHMPB_DRYK(h) * DC3.w) : 0.0;
	s += h * dryP;
	h *= 1.0 - dryP;
	float d = dot(tex2Dlod(DustT, float4(uv, 0, 0)), DC2);
	float2 gp = uv / tx * 0.35;
	float aa = saturate(length(fwidth(gp)) * 1.2 - 0.25);
	clip(min(d - 0.01, h + s - 0.003));
	float2 suv = (i.vpos + 0.5) * DC0.xy;
	float3 fb = ghmpb_toLinear(tex2Dlod(FB, float4(suv, 0, 0)).rgb);
	float3 E = fb / max(ghmpb_toLinear(tex2D(Albedo, uv0).rgb), 0.03);
	float alt = settled > 0.5 ? saturate(st.b) : 0.0;
	float4 r = ghmpb_dustShade(d, h, s, gp, aa, E, normalize(i.wnrm.xyz), i.wpos.xyz, alt, DC1.z);
	return float4(ghmpb_toSRGB(r.rgb), r.a * DC12.w);
}
#else
// ---------------------------------------------------------------- world layers (world_vs30 / worlddust_vs30)
// s0 the blood (live state | aftermath)  s1 _rt_FullFrameFB  s2 the dust source  s3 the live layer's aux (second type)
sampler State  : register(s0);
sampler FB     : register(s1);
sampler DustT  : register(s2);
sampler Aux    : register(s3);
struct PS_INPUT {
	float4 t0   : TEXCOORD0;
	float4 t1   : TEXCOORD1;
	float4 t2   : TEXCOORD2;
	float4 t3   : TEXCOORD3;
	float4 wpos : TEXCOORD4;
	float4 eye  : TEXCOORD5;
	float2 vpos : VPOS;
};
float3 fbT(float2 suv) { return ghmpb_toLinear(tex2Dlod(FB, float4(suv, 0, 0)).rgb); }
float4 main(PS_INPUT i) : COLOR
{
	gEye = i.eye.xyz;
	float tx = DC0.z;
	float3 P = i.wpos.xyz;
	float3 Tw = i.t1.xyz, Bw = i.t2.xyz;
	float2 uv = i.t0.xy;
	float smoothMode = floor(DC1.w / 2.0 + 1e-3);
	float settled = DC1.w - smoothMode * 2.0;
	// plane-global patch coordinate (as the blood: its organic edges and its noise line up)
	float2 guv = float2(dot(P, Tw) / max(dot(Tw, Tw), 1e-8), dot(P, Bw) / max(dot(Bw, Bw), 1e-8));
	guv = frac(guv / 16.0) * 16.0;
	if (smoothMode > 1.5)
	{
		float2 q = guv / tx * 0.45;
		uv += (float2(ghmpb_vnoise(q), ghmpb_vnoise(q + 37.1)) - 0.5) * tx * 1.6;
	}
	float4 st = tex2Dlod(State, float4(uv, 0, 0));
	float h = settled > 0.5 ? st.r * st.r * 4.0 : max(st.x, 0.0);
	float s = settled > 0.5 ? st.g * st.g * 4.0 : max(st.y, 0.0);
	float dryP = DC3.w > 0.0 ? 1.0 - exp(-GHMPB_DRYK(h) * DC3.w) : 0.0;
	s += h * dryP;
	h *= 1.0 - dryP;
	float d = dot(tex2Dlod(DustT, float4(uv, 0, 0)), DC2);
	float2 gp = guv / tx * 0.35;
	float aa = saturate(length(fwidth(gp)) * 1.2 - 0.25);
	clip(min(d - 0.01, h + s - 0.003));
	float2 suv = (i.vpos + 0.5) * DC0.xy;
	// irradiance from the low-passed frame over the surface's albedo (as the blood)
	float2 r = DC0.xy * 14.0;
	float3 fbS = fbT(suv) * 0.4 + (fbT(suv + float2(r.x, 0)) + fbT(suv - float2(r.x, 0)) + fbT(suv + float2(0, r.y)) + fbT(suv - float2(0, r.y))) * 0.15;
	float3 E = fbS / max(DC3.rgb, 0.03);
	float alt = settled > 0.5 ? saturate(st.b) : saturate(tex2Dlod(Aux, float4(uv, 0, 0)).w / max(h + s, 1e-4));
	float4 c = ghmpb_dustShade(d, h, s, gp, aa, E, normalize(i.t3.xyz), P, alt, DC1.z);
	return float4(ghmpb_toSRGB(c.rgb), c.a * DC12.w);
}
#endif
