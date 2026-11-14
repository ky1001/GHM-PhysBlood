// =====================================================================================
// GHM PhysBlood: blood on characters / props. Drawn over the entity (bonemerged proxy) right after the
// opaque pass; reads the cell field in the model's UV space, the model's own albedo and normal map and
// the lit framebuffer, then composites physically (see ghmpb_shade.h).
// Shared by bodyfilm_ps30 (dynamic, live cells) and bodystatic_ps30 (aftermath layer, baked RGBA8).
// screenspace_general_8tex samplers:
//   s0 state (h, s, mx, my) | aftermath   s1 _rt_FullFrameFB   s2 original $basetexture   s3 $bumpmap
//   s4 force (Ax, Ay, An, L)   s5 env cubemap   s6 aux (clot volume)   s7 accumulator (w = oxygenated volume)
// SC18 = (absorption scale, stain darkness, gloss, debug * 4 + smooth mode)
// =====================================================================================
sampler State  : register(s0);
sampler FB     : register(s1);
sampler Albedo : register(s2);
sampler Bump   : register(s3);
sampler Force  : register(s4);
sampler ProbeT : register(s5);      // (1.25.0: the reflection probe atlas of the blood group, ghmpb_shade.h)
sampler Aux    : register(s6);
#if !GHMPB_STATIC
sampler AccT   : register(s7);
#endif
#include "ghmpb_shade.h"

struct PS_INPUT {
	float4 uv   : TEXCOORD0;
	float4 wpos : TEXCOORD1;
	float4 wnrm : TEXCOORD2;
	float4 eye  : TEXCOORD3;
	float2 vpos : VPOS;
};

// (h mm, s mm, clot fraction, 1); alt = fraction of the second blood type (see ghmpb_surface_main.h)
static float gOxyF = 0.75;
float4 fetchFilmA(float2 uv, float tx, bool cubic, out float alt)
{
#if GHMPB_STATIC
	gOxyF = SC1.x;
	float4 a = cubic ? ghmpb_cubic(State, uv, tx) : tex2Dlod(State, float4(uv, 0, 0));
	alt = saturate(a.b);
	return float4(a.r * a.r * 4.0, a.g * a.g * 4.0, lerp(0.6, 1.0, saturate(ghmpb_layerDry() * 1.5)), 1.0);
#else
	float4 st = cubic ? ghmpb_cubic(State, uv, tx) : tex2Dlod(State, float4(uv, 0, 0));
	float4 ax = cubic ? ghmpb_cubic(Aux, uv, tx) : tex2Dlod(Aux, float4(uv, 0, 0));
	float h = max(st.x, 0.0);
	alt = saturate(ax.w / max(h + max(st.y, 0.0), 1e-4));
	float ow = (cubic ? ghmpb_cubic(AccT, uv, tx) : tex2Dlod(AccT, float4(uv, 0, 0))).w;
	gOxyF = saturate(ow / max(h + max(st.y, 0.0), 1e-4));
	return float4(h, max(st.y, 0.0), h > 1e-4 ? saturate(ax.x / h) : 0.0, 1.0);
#endif
}
float4 fetchFilm(float2 uv, float tx, bool cubic) { float a; return fetchFilmA(uv, tx, cubic, a); }

float4 main(PS_INPUT i) : COLOR
{
	gEye = i.eye.xyz;
	// (1.20.1) SC2.w = has bump map + 4 * which half of a part with mirrored UVs this layer holds (see ghmpb_uvHand)
	float hcode = floor(SC2.w / 4.0 + 1e-3);
	ghmpb_handClip(hcode, ghmpb_uvHand(i.wpos.xyz, normalize(i.wnrm.xyz), i.uv.xy));
	float mode = SC18.w;
	gDbg = floor(mode / 4.0 + 0.01);                 // 1 = thickness colours, 2..4 = shading views (ghmpb_shade.h)
	float debug = (gDbg > 0.5 && gDbg < 1.5) ? 1.0 : 0.0;
	float smoothMode = mode - gDbg * 4.0;
	bool cubic = smoothMode > 0.5;
	float2 uv0 = i.uv.xy;
	float tx = SC0.z;
	float2 uv = uv0 + 0.5 * tx;                       // D3D9 half texel of the UV-space rasterisation
	if (smoothMode > 1.5)
	{
		float2 q = uv0 / tx * 0.45;
		uv += (float2(ghmpb_vnoise(q), ghmpb_vnoise(q + 37.1)) - 0.5) * tx * 1.4;
		// (1.19.0b: a finer second octave - blood on skin creeps along pores and fine creases, its edge is ragged at the
		// scale of a texel, not a smooth cut-out)
		float2 q2 = q * 2.7 + 11.3;
		uv += (float2(ghmpb_vnoise(q2), ghmpb_vnoise(q2 + 23.7)) - 0.5) * tx * 0.7;
	}
	float altF;
	float4 fm = fetchFilmA(uv, tx, cubic, altF);
	float oxyF = gOxyF;
	float h = fm.x, s = fm.y;
	float amount = h + s * 0.4;

	float3 P = i.wpos.xyz;
	float3 Ng = normalize(i.wnrm.xyz);
	float3 Tw, Bw;
	float3x3 tbn = ghmpb_tangentFrame(Ng, P, uv0, Tw, Bw);   // Tw/Bw = dP/du, dP/dv (world per uv)
	// cloth wicks blood along its fibres: soft, irregular stain edges instead of crisp stamped ones
	float fab = ghmpb_fabric();
	float fibre = 0.65 + 0.7 * ghmpb_vnoise(uv0 / tx * float2(0.8, 0.27) + 3.0);
	float amountC = amount * lerp(1.0, fibre, fab);
	float aw = max(fwidth(amountC) * 1.1, 2e-4);   // (1.25.0: a smoother edge)
	float cov = cubic ? smoothstep(0.004 - aw, 0.004 + aw, amountC) : smoothstep(0.0015, 0.03, amountC);
	cov = lerp(cov, smoothstep(0.0, 0.06, amountC), fab * 0.8);
	// cloth: blood (and the serum running ahead of it) wicks along the fibres past the edge of the film - a
	// soft, irregular, damp halo around every stain instead of a stamped outline
	float wick = 0.0;
	if (fab > 0.05)
	{
		float r = tx * 2.5;
		float4 a1 = fetchFilm(uv + float2(r, 0), tx, false), a2 = fetchFilm(uv - float2(r, 0), tx, false);
		float4 a3 = fetchFilm(uv + float2(0, r), tx, false), a4 = fetchFilm(uv - float2(0, r), tx, false);
		float around = max(max(a1.x + a1.y * 0.4, a2.x + a2.y * 0.4), max(a3.x + a3.y * 0.4, a4.x + a4.y * 0.4));
		wick = fab * smoothstep(0.004, 0.09, around * fibre) * (1.0 - cov);
	}
	float fade = ghmpb_layerFade();
	float alive = max(cov, wick) * fade;
	clip(alive - 0.002);

	float3 Ns = Ng;
	if (SC2.w - 4.0 * floor(SC2.w / 4.0 + 1e-3) > 0.5)
	{
		float3 nt = tex2D(Bump, uv0).xyz * 2.0 - 1.0;
		Ns = normalize(mul(nt, tbn));
	}

	float3 slope;
	float hv = ghmpb_visH(h, s) / 19.05;
	if (cubic)
	{
		slope = ghmpb_surfGrad(P, Ng, hv);
	}
	else
	{
		float hL = fetchFilm(uv - float2(tx, 0), tx, false).x, hR = fetchFilm(uv + float2(tx, 0), tx, false).x;
		float hU = fetchFilm(uv - float2(0, tx), tx, false).x, hD = fetchFilm(uv + float2(0, tx), tx, false).x;
		float dhdu = (ghmpb_visH(hR, s) - ghmpb_visH(hL, s)) * 0.5 / tx / 19.05;
		float dhdv = (ghmpb_visH(hD, s) - ghmpb_visH(hU, s)) * 0.5 / tx / 19.05;
		slope = dhdu * Tw / max(dot(Tw, Tw), 1e-8) + dhdv * Bw / max(dot(Bw, Bw), 1e-8);
	}

	float2 suv = (i.vpos + 0.5) * SC0.xy;
	float3 fbG = tex2Dlod(FB, float4(suv, 0, 0)).rgb;
	float3 fb = ghmpb_toLinear(fbG);
	float3 albedo = ghmpb_toLinear(tex2D(Albedo, uv0).rgb);

	GHMPB_Film f;
	f.h = h; f.s = s; f.clot = fm.z; f.slope = slope;
	f.alt = altF;
	f.oxy = oxyF;
	f.flowPos = uv;
	f.crackPos = uv / tx * 0.35;
	f.serum = 0.0;
	f.froth = 0.0;
	float texPerPix = length(float2(ddx(uv.x), ddy(uv.x))) / tx + 1e-4;
	f.ring = saturate(length(float2(ddx(s), ddy(s))) / texPerPix / max(s, 0.03) * 0.9) * smoothstep(0.01, 0.06, s);   // (1.25.0: a wider rim)
#if GHMPB_STATIC
	f.flowUV = float2(0, 0);
	f.flowW = float3(0, 0, 0);
	f.flowSpeed = 0.0;
	float dryT = ghmpb_layerDry();
#else
	// ripples only where the blood really moves: the film velocity from the simulated momentum (a pool that
	// is pinned on a slight slope is still, even though gravity pulls on it)
	float4 frc = tex2Dlod(Force, float4(uv, 0, 0));
	float2 vt = h > 0.01 ? tex2Dlod(State, float4(uv, 0, 0)).zw / h : float2(0, 0);          // texels / s
	float vs = length(vt);
	f.flowUV = vs > 1e-3 ? vt / vs : float2(0, 0);
	f.flowW = Tw * f.flowUV.x + Bw * f.flowUV.y;
	f.flowSpeed = vs * frc.w * (1.0 - f.clot);                                  // cm / s
	float dryT = 0.0;
#endif

	// everything that needs screen derivatives first; the rest of the shading only runs where there is blood
	GHMPB_Pre q = ghmpb_filmPre(Ng, Ns, P, f, dryT);
	float3 col = fb;
	[branch] if (alive > 0.002)
	{
		// skin / cloth: the model's own texture is the albedo, so fb / albedo is already detail free
		col = ghmpb_shadeFilm(fb, fb, albedo, Ng, P, f, q, SC18.z, SC18.x, SC18.y);
		col = lerp(fb, col, saturate(cov * fade));
		col = lerp(col, fb * float3(0.6, 0.47, 0.46), wick * fade * 0.85);     // damp cloth: darker, faintly red
	}
	col = ghmpb_toSRGB(col);
	if (debug > 0.5) col = lerp(float3(0.02, 0.1, 0.6), float3(1.0, 0.1, 0.02), saturate(h / 1.5)) + float3(0, fm.z, 0) * 0.5;
	return float4(col, 1.0);
}
