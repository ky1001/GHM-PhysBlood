// =====================================================================================
// GHM PhysBlood (1.26.11): enhanced two-pass world blood surface shader (surfbase_ps30 + surfcoat_ps30).
// Splitting the live world film into an optical body pass (GHMPB_SURF_PASS == 1) and a liquid coat / reflection pass
// (GHMPB_SURF_PASS == 2), backed by a shared quarter-resolution scene blur (fbblur_ps30), removes D3D9 ps_3_0's 4096-slot
// and 32-temp-register bottleneck while keeping the original single-pass surface_ps30 untouched for instant live toggle.
//
// Pass 1 (surfbase_ps30):
//   s0 State  s1 FB (sharp scene)  s2 Bed  s3 SurfBump  s4 Aux  s5 FBBlur  s6 AccT  s7 MatT
//   - Parallax relief ray-march (identical to Pass 2 for sub-pixel silhouette lock)
//   - Snell's law liquid-lens meniscus refraction of the substrate under translucent rims, drops and runs
//   - Directional sun + flashlight meniscus rim caustics filtered through Beer-Lambert haemoglobin transmission
//   - Fibrin clot-retraction cellular mottling & two-layer 4-band Kubelka-Munk optical body + Saunderson internal reflection
//   - Substrate micro-grain, porous wicking halo, world heat char darkening, boiling/acid foam tint, frost rime & glow
//
// Pass 2 (surfcoat_ps30):
//   s0 State  s1 FB (Pass 1 output)  s2 Bed  s3 SurfBump  s4 Aux  s5 ProbeT  s6 FBBlur  s7 MatT
//   - Dual-scale flow-advected capillary wave field (5 mm crisp shear ripples + 16 mm gravity-capillary swell + ring steepening)
//   - Full 3D micro-bubble + macro-bubble dome + boiling/acid blister normals shaded BEFORE GGX & environment reflection
//   - Drying fibrin satin micro-webbing & dual-lobe GGX specular (sharp air-plasma topcoat + corpuscular sub-sheen)
//   - Full world 55-deg contact-angle meniscus rim glints from Sun, Flashlight and all 4 local Map Lamps
//   - 6-step horizon-weighted screen-space reflections mixed with mirrored floor & parallax cubemap probe
// =====================================================================================

#define GHMPB_STATIC 0
#define GHMPB_WORLD 1

sampler State    : register(s0);
sampler FB       : register(s1);
sampler Bed      : register(s2);
sampler SurfBump : register(s3);
sampler Aux      : register(s4);
sampler ProbeT   : register(s5);   // Pass 1: quarter-res FBBlur; Pass 2: reflection probe + lamp atlas
sampler AccT     : register(s6);   // Pass 1: accumulator (per-pixel oxy); Pass 2: quarter-res FBBlur
sampler MatT     : register(s7);

#if GHMPB_SURF_PASS == 2
#define GHMPB_SMALLBUB 1
#endif
#include "ghmpb_shade.h"

struct PS_INPUT
{
	float4 t0   : TEXCOORD0;
	float4 t1   : TEXCOORD1;
	float4 t2   : TEXCOORD2;
	float4 t3   : TEXCOORD3;
	float4 wpos : TEXCOORD4;
	float4 eye  : TEXCOORD5;
	float4 vp0  : TEXCOORD6;
	float4 vp1  : TEXCOORD7;
	float4 vp2  : TEXCOORD8;
	float4 vp3  : TEXCOORD9;
	float2 vpos : VPOS;
};

static float gOxyF = 0.75;

float4 fetchFilmA(float2 uv, float tx, bool cubic, out float alt)
{
	float4 st = cubic ? ghmpb_cubic(State, uv, tx) : tex2Dlod(State, float4(uv, 0, 0));
	float4 ax = cubic ? ghmpb_cubic(Aux, uv, tx) : tex2Dlod(Aux, float4(uv, 0, 0));
	float mask = smoothstep(0.3, 0.7, (cubic ? ghmpb_cubic(Bed, uv, 1.0 / 128.0) : tex2Dlod(Bed, float4(uv, 0, 0))).y);
	float h = max(st.x, 0.0);
	alt = saturate(ax.w / max(h + max(st.y, 0.0), 1e-4));
#if GHMPB_SURF_PASS == 1
	float ow = (cubic ? ghmpb_cubic(AccT, uv, tx) : tex2Dlod(AccT, float4(uv, 0, 0))).w;
	gOxyF = saturate(ow / max(h + max(st.y, 0.0), 1e-4));
#else
	gOxyF = saturate(SC1.x);
#endif
	return float4(h, max(st.y, 0.0), h > 1e-4 ? saturate(ax.x / h) : 0.0, mask);
}

float4 fetchFilm(float2 uv, float tx, bool cubic)
{
	float a;
	return fetchFilmA(uv, tx, cubic, a);
}

float bedAt(float2 uv)
{
	float4 b = tex2Dlod(Bed, float4(uv, 0, 0));
	return b.y > 0.5 ? b.x : -8.0;
}

float topAt(float2 uv)
{
	float4 st = tex2Dlod(State, float4(uv, 0, 0));
	float h = max(st.x, 0.0), s = max(st.y, 0.0);
	return bedAt(uv) + max(ghmpb_visH(h, s), h) / 19.05;
}

#if GHMPB_SURF_PASS == 2
// 6-step horizon-weighted screen-space reflection with cross-filtered roughness footprint
float3 ssr6(PS_INPUT i, float3 P, float3 R, float rough, out float conf)
{
	float3 acc = 0;
	float wsum = 0;
	float blur = 0.0012 + rough * 0.028;
	[loop] for (int k = 0; k < 6; k++)
	{
		// 8, 17, 36, 76, 160, 335 u: tighter near-field contact reflections + further room reach
		float d = 8.0 * exp2(1.08 * k);
		float dw = 0.28 + 0.28 * k;
		float4 Q = float4(P + R * d, 1.0);
		float4 c = float4(dot(Q, i.vp0), dot(Q, i.vp1), dot(Q, i.vp2), dot(Q, i.vp3));
		if (c.w > 1.0)
		{
			float2 ruv = c.xy / c.w * float2(0.5, -0.5) + 0.5 + 0.5 * SC0.xy;
			float2 e2 = min(ruv, 1.0 - ruv);
			float ew = saturate(min(e2.x, e2.y) * 11.0);
			float3 t = tex2Dlod(FB, float4(ruv, 0, 0)).rgb * 2.0;
			t += tex2Dlod(FB, float4(ruv + float2(blur, 0), 0, 0)).rgb;
			t += tex2Dlod(FB, float4(ruv - float2(blur, 0), 0, 0)).rgb * 0.5;
			t += tex2Dlod(FB, float4(ruv + float2(0, blur), 0, 0)).rgb * 0.5;
			acc += ghmpb_reflBoost(ghmpb_toLinear(t * 0.25)) * ew * dw;
			wsum += ew * dw;
		}
	}
	conf = saturate(wsum / 5.88 * 1.2);
	return wsum > 1e-3 ? acc / wsum : float3(0, 0, 0);
}
#endif

float4 main(PS_INPUT i) : COLOR
{
	gEye = i.eye.xyz;
	float rem2 = SC2.w - 1024.0 * ghmpb_serumOn() - ghmpb_matId() * 32.0;
	gDbg = floor(rem2 / 4.0 + 0.01);
	float smoothMode = rem2 - gDbg * 4.0;

#if GHMPB_SURF_PASS == 2
	// Debug views 1, 2 and 4 are already rendered directly by Pass 1; only debug view 3 (specular coat) runs Pass 2 solo
	if (gDbg > 0.5 && (gDbg < 2.5 || gDbg > 3.5))
	{
		clip(-1.0);
		return float4(0, 0, 0, 0);
	}
#endif

	float tx = SC0.z;
	float2 uv0 = i.t0.xy;
	float3 P = i.wpos.xyz;
	float3 Ng = normalize(i.t3.xyz);
	float3 Tw = i.t1.xyz, Bw = i.t2.xyz;
	float3 Vr = normalize(i.eye.xyz - P);

	// Identical POM relief march in both passes so silhouette and sub-texel coordinates lock pixel-for-pixel
	float sideCut = 0.0;
	float bumpKind = floor(i.t2.w * 0.5 + 0.01);
	float reliefF = i.t2.w - 2.0 * bumpKind;
	if (reliefF > 0.5)
	{
		float3 rd = -Vr;
		float dz = dot(rd, Ng);
		if (dz < -0.03)
		{
			float2 duv = float2(dot(rd, Tw) / max(dot(Tw, Tw), 1e-8), dot(rd, Bw) / max(dot(Bw, Bw), 1e-8));
			float z0 = dot(P, Ng) - i.t3.w;
			float tMax = min((z0 - i.t0.z + 0.05) / -dz, 6.0);
			float tPrev = 0.0;
			float dPrev = z0 - topAt(uv0);
			float tHit = tMax;
			float nS = clamp(ceil(length(duv) * tMax / tx), 2.0, 20.0);
			if (dPrev <= 0.0) tHit = 0.0;
			else
			{
				[loop] for (int k = 1; k <= 20; k++)
				{
					if (k > nS) break;
					float t = tMax * k / nS;
					float dd = (z0 + dz * t) - topAt(uv0 + duv * t);
					if (dd <= 0.0)
					{
						float ta = tPrev, tb = t, da = dPrev;
						[unroll] for (int r = 0; r < 5; r++)
						{
							float tm = 0.5 * (ta + tb);
							float dm = (z0 + dz * tm) - topAt(uv0 + duv * tm);
							if (dm <= 0.0) { tb = tm; dd = dm; } else { ta = tm; da = dm; }
						}
						tHit = ta + (tb - ta) * saturate(da / max(da - dd, 1e-5));
						break;
					}
					tPrev = t;
					dPrev = dd;
				}
			}
			uv0 += duv * tHit;
			P += rd * tHit;
			float eb = 0.5 / 128.0;
			float sU = abs(topAt(uv0 + float2(eb, 0)) - topAt(uv0 - float2(eb, 0))) / max(2.0 * eb * length(Tw), 1e-4);
			float sV = abs(topAt(uv0 + float2(0, eb)) - topAt(uv0 - float2(0, eb))) / max(2.0 * eb * length(Bw), 1e-4);
			sideCut = smoothstep(1.2, 2.2, max(sU, sV));
		}
	}

	float2 uv = uv0;
	float3 Tw0 = i.t1.xyz, Bw0 = i.t2.xyz;
	float2 guv = float2(dot(P, Tw0) / max(dot(Tw0, Tw0), 1e-8), dot(P, Bw0) / max(dot(Bw0, Bw0), 1e-8));
	guv = frac(guv / 16.0) * 16.0;
	if (smoothMode > 1.5)
	{
		float2 qn = guv / tx * 0.45;
		uv += (float2(ghmpb_vnoise(qn), ghmpb_vnoise(qn + 37.1)) - 0.5) * tx * 1.6;
	}
	bool cubic = smoothMode > 0.5;
	float altF;
	float4 fm = fetchFilmA(uv, tx, cubic, altF);
	float oxyF = gOxyF;
	float h = fm.x, s = fm.y;

	float4 m2 = ghmpb_mat(2.0, 0.0);
	[branch] if (m2.z > 0.0)
	{
		float2 gp = guv / tx * m2.w;
		float gn;
		float grainKind = ghmpb_mat(3.0, 0.0).x;
		if (grainKind > 1.5) gn = ghmpb_vnoise(float2(gp.x * 2.2, gp.y * 0.35)) * 0.7 + ghmpb_vnoise(gp * 1.7 + 3.3) * 0.3;
		else if (grainKind > 0.5) { float2 gg; gn = 1.0 - smoothstep(0.0, 0.35, ghmpb_crack(gp, gg)); }
		else gn = 0.6 * ghmpb_vnoise(gp) + 0.4 * ghmpb_vnoise(gp * 2.3 + 7.1);
		float gm = lerp(lerp(1.0 - m2.z, 1.0 + m2.z, gn), 1.0, smoothstep(0.3, 1.2, h));
		h *= gm;
		s *= gm;
	}

	float amount = h + s * 0.4;
	float cov;
	if (cubic)
	{
		float aw = max(fwidth(amount) * 1.1, 2e-4);
		cov = smoothstep(0.004 - aw, 0.004 + aw, amount);
	}
	else
	{
		cov = smoothstep(0.0015, 0.03, amount);
	}
	cov *= fm.w * (1.0 - sideCut);
	float fade = ghmpb_layerFade();
	float alive = cov * fade;

#if GHMPB_SURF_PASS == 1
	float halo = 0.0;
	[branch] if (m2.x > 0.0)
	{
		float r = tx * m2.y;
		float4 a = fetchFilm(uv + float2(r, r * 0.4), tx, false);
		float4 b = fetchFilm(uv - float2(r, r * 0.4), tx, false);
		float4 c = fetchFilm(uv + float2(-r * 0.4, r), tx, false);
		float4 d = fetchFilm(uv + float2(r * 0.4, -r), tx, false);
		float nearB = (a.x + a.y + b.x + b.y + c.x + c.y + d.x + d.y) * 0.25;
		halo = saturate(nearB * 5.0) * m2.x * fm.w * (1.0 - sideCut) * (1.0 - cov);
	}
	clip(max(alive, halo * fade) - 0.002);
	float haloW = halo * fade * (1.0 - saturate(alive));
#else
	clip(alive - 0.002);
#endif

	if (reliefF > 0.5)
	{
		float3 Tu = normalize(Tw), Bv = normalize(Bw);
		float2 nb = tex2Dlod(Bed, float4(uv, 0, 0)).zw;
		Ng = normalize(Ng * sqrt(saturate(1.0 - dot(nb, nb))) + Tu * nb.x + Bv * nb.y);
	}

	float3 slope;
	if (cubic)
	{
		float hv = (ghmpb_visH(h, s) + ghmpb_serumOn() * (1.0 - fm.z) * h * exp(1.0 - h * 3.3333)
		            - ghmpb_mat(1.0, 0.0).z * 0.35 * min(s, 1.0)) / 19.05;
		slope = ghmpb_surfGrad(P, Ng, hv);
	}
	else
	{
		float hL0 = fetchFilm(uv - float2(tx, 0), tx, false).x, hR0 = fetchFilm(uv + float2(tx, 0), tx, false).x;
		float hU0 = fetchFilm(uv - float2(0, tx), tx, false).x, hD0 = fetchFilm(uv + float2(0, tx), tx, false).x;
		float dhdu = (ghmpb_visH(hR0, s) - ghmpb_visH(hL0, s)) * 0.5 / tx / 19.05;
		float dhdv = (ghmpb_visH(hD0, s) - ghmpb_visH(hU0, s)) * 0.5 / tx / 19.05;
		slope = dhdu * Tw / max(dot(Tw, Tw), 1e-8) + dhdv * Bw / max(dot(Bw, Bw), 1e-8);
	}
	float rimW = smoothstep(0.08, 0.3, length(float2(ddx(h), ddy(h))) / ((length(float2(ddx(uv.x), ddy(uv.x))) / tx + 1e-4) * max(h, 0.02)));
	slope *= lerp(0.2, 1.0, rimW);

	float2 suv = (i.vpos + 0.5) * SC0.xy;
	float3 fbG = tex2Dlod(FB, float4(suv, 0, 0)).rgb;
#if GHMPB_SURF_PASS == 1
	float3 fb = ghmpb_toLinear(fbG);
#endif
	float3 albedo = SC18.rgb;

	float lc = ghmpb_luma(fbG);
	float3 Ns = normalize(Ng - (ddx(lc) * normalize(Tw) + ddy(lc) * normalize(Bw)) * 0.8);
	{
		float2 buv = float2(i.t0.w, i.t1.w);
		float3 bT, bB;
		float3x3 btbn = ghmpb_tangentFrame(Ng, i.wpos.xyz, buv, bT, bB);
		float2 bx = ddx(buv), by = ddy(buv), ux = ddx(i.t0.xy), uy = ddy(i.t0.xy);
		float2 dv = uv0 - i.t0.xy;
		float dt = ux.x * uy.y - ux.y * uy.x;
		float2 w = float2(uy.y * dv.x - uy.x * dv.y, ux.x * dv.y - ux.y * dv.x) / (abs(dt) > 1e-12 ? dt : 1e-12);
		float3 nm = tex2Dgrad(SurfBump, buv + bx * w.x + by * w.y, bx, by).xyz;
		float3 nt = bumpKind > 1.5
			? nm.x * float3(0.81650, 0.0, 0.57735) + nm.y * float3(-0.40825, 0.70711, 0.57735) + nm.z * float3(-0.40825, -0.70711, 0.57735)
			: nm * 2.0 - 1.0;
		Ns = bumpKind > 0.5 ? normalize(mul(normalize(nt), btbn)) : Ns;
	}

	GHMPB_Film f;
	f.h = h; f.s = s; f.clot = fm.z; f.slope = slope;
	f.alt = altF;
	f.oxy = oxyF;
	f.flowPos = guv * 3.0;
	f.crackPos = guv / tx * 0.35;
	f.serum = 0.0;
	f.froth = saturate(tex2Dlod(Aux, float4(uv, 0, 0)).z / max(h, 1e-3)) * saturate(ghmpb_frothAmt());
	float texPerPix = length(float2(ddx(uv.x), ddy(uv.x))) / tx + 1e-4;
	f.ring = saturate(length(float2(ddx(s), ddy(s))) / texPerPix / max(s, 0.03) * 0.9) * smoothstep(0.01, 0.06, s);

	float2 vt = h > 0.01 ? tex2Dlod(State, float4(uv, 0, 0)).zw / h : float2(0, 0);
	float vs = length(vt);
	f.flowUV = vs > 1e-3 ? vt / vs : float2(0, 0);
	f.flowW = Tw0 * f.flowUV.x + Bw0 * f.flowUV.y;
	f.flowSpeed = vs * (40.0 * GHMPB_UNITS_TO_CM * tx) * (1.0 - f.clot);

	GHMPB_Pre q = ghmpb_filmPre(Ng, Ns, P, f, 0.0);

#if GHMPB_SURF_PASS == 1
	// =========================================================================
	// PASS 1: OPTICAL BODY, LIQUID-LENS REFRACTION, RIM CAUSTICS & KUBELKA-MUNK
	// =========================================================================
	float3 col = fb;
	[branch] if (alive > 0.002)
	{
		float fabric = ghmpb_fabric();
		float roughSub = ghmpb_roughSub();
		float hL = q.hL, sL = q.sL, cf = q.cf;
		float3 Tt2 = normalize(cross(Ng, float3(0.57, 0.31, 0.76)));
		float3 Bt2 = cross(Ng, Tt2);
		float3 N = q.N0;
		float3 Nb = q.Nb;

		// Shrinkage cracks on dried crusts
		float sd = sL * 0.3;
		float4 m1 = ghmpb_mat(1.0, 0.0);
		float crackW = smoothstep(0.03, 0.25, sd) * saturate(1.0 - hL / 0.15) * (1.0 - fabric) * m1.x;
		float crack = 0.0;
		[branch] if (crackW > 0.0)
		{
			float2 gc;
			float cc = ghmpb_crack(f.crackPos, gc);
			crack = (1.0 - smoothstep(0.02, 0.09, cc)) * crackW;
			N = normalize(N + (Tt2 * gc.x + Bt2 * gc.y) * 0.24 * crack);
		}

		// Optical depth variation + fibrin clot-retraction cellular mottling as blood gels
		float nv = 0.6 * ghmpb_vnoise(f.crackPos * 0.9 + 11.0) + 0.4 * ghmpb_vnoise(f.crackPos * 3.1 + 5.0);
		float hOpt = hL * lerp(0.85, 1.15, nv);
		float gel = smoothstep(0.35, 0.92, cf);
		[branch] if (gel > 0.0 && hL > 0.03)
		{
			float2 lp = f.crackPos * 0.45 + 3.3;
			float fibCell = 0.65 * ghmpb_vnoise(lp) + 0.35 * ghmpb_vnoise(f.crackPos * 1.85 + 9.1);
			float lw = gel * smoothstep(0.08, 0.55, hL);
			// Retracting fibrin clots pull RBCs into denser dark-crimson islands separated by thinner amber-red channels
			hOpt *= lerp(1.0, 0.62 + 0.76 * fibCell, lw);
		}

		float wv = max(ghmpb_poolLookAt(max(SC1.y, -hL)), 0.1);
		float wet = smoothstep(0.003, 0.03, hL * wv);
		float w3s = max(SC3.w, -wet);

		// Pre-blurred scene irradiance from quarter-res FBBlur bound on s5 (ProbeT register in Pass 1)
		float3 fbS = ghmpb_toLinear(tex2Dlod(ProbeT, float4(suv, 0, 0)).rgb);
		float3 E = ghmpb_irradiance(fbS, albedo);

		// 1. Snell's law liquid-lens meniscus refraction of the sharp floor beneath translucent rims, drops and runs
		float3 V = normalize(gEye - P);
		float3 camR = normalize(cross(V, abs(V.z) < 0.98 ? float3(0, 0, 1) : float3(0, 1, 0)));
		float3 camU = cross(camR, V);
		float3 nTilt = N - Nb;
		float2 lensGrad = float2(dot(nTilt, camR), -dot(nTilt, camU));
		float transWindow = wet * (1.0 - smoothstep(0.05, 0.24, hOpt)) * saturate(hL * 18.0);
		float2 refrOff = clamp(lensGrad * (0.011 * transWindow), -SC0.xy * 9.0, SC0.xy * 9.0);
		float2 suvRefr = clamp(suv + refrOff, SC0.xy * 0.5, 1.0 - SC0.xy * 0.5);
		float3 fbRefr = transWindow > 0.005 ? ghmpb_toLinear(tex2Dlod(FB, float4(suvRefr, 0, 0)).rgb) : fb;

		// 2. Directional sun + flashlight meniscus caustics focused onto the substrate under curved translucent rims
		float rimT = saturate((1.0 - dot(N, Nb)) * 6.0);
		float caustMask = transWindow * rimT * (1.0 - 0.75 * cf);
		[branch] if (caustMask > 0.01)
		{
			float3 Lsun = normalize(SC11.xyz);
			float sunFocus = pow(saturate(dot(N, Lsun)) * (1.0 - saturate(dot(Nb, Lsun)) * 0.65), 1.5);
			float3 Lfl;
			float3 flRad = ghmpb_flashlight(P, N, V, 0.25, Lfl);
			float flFocus = saturate(dot(N, Lfl)) * 0.65;
			float Esh0 = max(ghmpb_luma(ghmpb_shIrradiance(Nb, SC15, SC16, SC17)), 1e-3);
			float kShadow = clamp(ghmpb_luma(E) / Esh0, 0.0, 4.0);
			float3 caustLight = SC12.rgb * (SC11.w * kShadow * sunFocus * 0.55) + flRad * (flFocus * 0.45);
			// Filtered through ruby haemoglobin transmission before hitting substrate reflectance
			float3 rubyPass = exp(-float3(1.1, 9.5, 13.5) * max(hOpt, 0.015));
			fbRefr += min(fbRefr / max(E, 1e-3), 0.95) * caustLight * rubyPass * caustMask;
		}

		// Diffuse relief & meniscus edge darkening + oxygenated froth scattering
		float relW = saturate(sd * 4.0) * (1.0 - wet) * (1.0 - fabric * 0.7);
		float relief = 1.0;
		[branch] if (relW > 0.0)
		{
			float3 EshB = ghmpb_shIrradiance(Nb, SC15, SC16, SC17);
			relief = clamp(ghmpb_luma(ghmpb_shIrradiance(N, SC15, SC16, SC17)) / max(ghmpb_luma(EshB), 1e-3), 0.65, 1.5);
		}
		float fresh = wet * (1.0 - cf) * smoothstep(0.08, 0.6, hL) * (1.0 - ghmpb_frostAt(w3s));
		float foam = f.froth * fresh * 0.14;

		// Energy-conserving Fresnel coat reflectance estimate (matches Pass 2's Fr so transmitted + reflected <= 1)
		float NoV = saturate(dot(N, V));
		float4 m0 = ghmpb_mat(0.0, 0.0);
		float soakF = m0.x * ghmpb_matFresh(m0.w);
		float dryC = (1.0 - exp(-sL * 6.0)) * (1.0 - 0.75 * crack);
		float wetSpec = wet * (1.0 - 0.55 * fabric * saturate(1.0 - hL / 0.5));
		float drySpec = (1.0 - wet) * dryC * (1.0 - 0.85 * soakF);
		float specW = wetSpec + drySpec;
		float F0s = lerp(GHMPB_F0_DRY, GHMPB_F0_WET, wet);
		float rLiquid = lerp(0.32, 0.03, saturate(wv));
		float rough = lerp(max(roughSub, 0.12), rLiquid, smoothstep(0.02, 0.2, hL * wv));
		rough = lerp(rough, 0.13, smoothstep(0.6, 0.95, cf) * saturate(hL / 0.05));
		float rDry = lerp(lerp(0.6, 0.22, smoothstep(0.1, 0.8, sL)), 0.8, soakF);
		rough = saturate(lerp(lerp(roughSub, rDry, dryC), rough, wet));
		float3 R = reflect(-V, N);
		float ho = saturate(1.0 + 1.1 * dot(R, Ng));
		float mvS = 7.0 * saturate(f.flowSpeed * 0.5);
		float frW = wet * (1.0 - cf);
		float rS = ghmpb_reflScale() * min(1.0 + (0.3 * ghmpb_freshShine() + mvS) * frW, 8.0);

		GHMPB_Spec sp;
		sp.col = float3(0, 0, 0);   // Specular + environment coat is rendered in Pass 2 (surfcoat_ps30)
		sp.Fr = ghmpb_envBRDFApprox(F0s.xxx, rough, NoV) * specW * ho * ho * rS;
		sp.env = float3(0, 0, 0);
		sp.N = N;
		sp.V = V;
		sp.dmul = lerp(1.0, relief, relW) * (1.0 - 0.32 * rimT * wet * (1.0 - 0.6 * cf)) * (1.0 + 1.5 * foam);
		sp.hOpt = hOpt;
		sp.crack = crack;
		sp.foam = foam;

		float hideK = smoothstep(0.02, 0.3, h);
		col = ghmpb_filmDiffuse(lerp(fbRefr, E * albedo, hideK), E, f, q, sp, SC18.w, 1.0);

		// World heat char darkening on scorched crusts (unlocked from model-only budget cap)
		float chr = ghmpb_char() * (1.0 - wet * 0.8);
		if (chr > 0.01) col *= lerp(1.0, 0.18, saturate(chr));

		col = lerp(fb, col, saturate(alive));
	}
	if (haloW > 0.001)
	{
		float haloType = ghmpb_mat(1.0, 0.4).w;
		float3 tint = haloType > 1.5 ? float3(0.96, 0.84, 0.68) : (haloType > 0.5 ? float3(1.0, 0.5, 0.55) : float3(0.72, 0.70, 0.68));
		col = lerp(col, fb * tint, haloW);
	}
	return float4(ghmpb_toSRGB(col), 1.0);

#else
	// =========================================================================
	// PASS 2: DUAL-SCALE RIPPLES, 3D BUBBLES, FULL MENISCUS GLINTS & 6-TAP SSR
	// =========================================================================
	float fabric = ghmpb_fabric();
	float roughSub = ghmpb_roughSub();
	float cf = q.cf, hL = q.hL, sL = q.sL;
	float3 Tt2 = normalize(cross(Ng, float3(0.57, 0.31, 0.76)));
	float3 Bt2 = cross(Ng, Tt2);
	float3 N = q.N0;
	float3 Nb = q.Nb;

	// Dried crust crack normals
	float sd = sL * 0.3;
	float4 m1 = ghmpb_mat(1.0, 0.0);
	float crackW = smoothstep(0.03, 0.25, sd) * saturate(1.0 - hL / 0.15) * (1.0 - fabric) * m1.x;
	float crack = 0.0;
	[branch] if (crackW > 0.0)
	{
		float2 gc;
		float cc = ghmpb_crack(f.crackPos, gc);
		crack = (1.0 - smoothstep(0.02, 0.09, cc)) * crackW;
		N = normalize(N + (Tt2 * gc.x + Bt2 * gc.y) * 0.24 * crack);
	}

	float wv = max(ghmpb_poolLookAt(max(SC1.y, -hL)), 0.1);
	float wet = smoothstep(0.003, 0.03, hL * wv);
	float w3s = max(SC3.w, -wet);
	float distEye = length(gEye - P);

	// 1. Dual-scale flow-advected capillary ripples (5 mm fine shear + 16 mm gravity-capillary swell)
	float flowVar = 0.0;
	[branch] if (f.flowSpeed > 0.04 && wet > 0.0 && cf < 0.92 && ghmpb_frostAt(w3s) < 0.9)
	{
		float period = 0.8;
		float ph0 = frac(SC0.w / period), ph1 = frac(SC0.w / period + 0.5);
		float wgt = abs(ph0 - 0.5) * 2.0;
		float2 fu = f.flowUV;
		float sp = min(f.flowSpeed, 26.0);
		float st = 1.0 + 0.12 * min(sp, 10.0);

		// Fine 5 mm shear ripples
		float2 pFine = float2(dot(f.flowPos, fu) / st, dot(f.flowPos, float2(-fu.y, fu.x))) * 50.8;
		float advF = sp * (2.0 * period) / st;
		float2 g0 = ghmpb_vnoise_grad(pFine - float2(advF * ph0, 0.0));
		float2 g1 = ghmpb_vnoise_grad(pFine + float2(17.3, 5.1) - float2(advF * ph1, 0.0));
		float amFine = saturate(sqrt(f.flowSpeed / (1.0 + 2.0 * hL))) * wet * (1.0 - cf) * saturate((270.0 - distEye) / 145.0);
		float2 rgFine = lerp(g0, g1, wgt) * amFine;

		// Coarser 16 mm gravity-capillary swell on deeper / faster inflows & impact ring waves
		float per2 = 1.35;
		float ph2a = frac(SC0.w / per2), ph2b = frac(SC0.w / per2 + 0.5);
		float wgt2 = abs(ph2a - 0.5) * 2.0;
		float2 pSwell = float2(dot(f.flowPos, fu), dot(f.flowPos, float2(-fu.y, fu.x))) * 15.8;
		float advS = sp * (0.72 * per2);
		float2 s0g = ghmpb_vnoise_grad(pSwell + float2(3.7, 11.9) - float2(advS * ph2a, 0.0));
		float2 s1g = ghmpb_vnoise_grad(pSwell + float2(29.1, 2.3) - float2(advS * ph2b, 0.0));
		float amSwell = saturate(f.flowSpeed / 3.2) * smoothstep(0.05, 0.28, hL) * wet * (1.0 - cf) * saturate((420.0 - distEye) / 200.0);
		float2 rgSwell = lerp(s0g, s1g, wgt2) * amSwell;

		float3 Fw = normalize(f.flowW - Ng * dot(f.flowW, Ng) + 1e-5);
		float3 Fp = cross(Ng, Fw);
		N = normalize(N - Fw * (rgFine.x * (0.14 / st) + rgSwell.x * 0.085) - Fp * (rgFine.y * 0.14 + rgSwell.y * 0.095));
		flowVar = amFine * amFine * 0.03 + amSwell * amSwell * 0.015;
	}

	// 2. Full 3D micro-bubble + macro-bubble + boiling/acid blister normals BEFORE lighting
	float fresh = wet * (1.0 - cf) * smoothstep(0.06, 0.55, hL) * (1.0 - ghmpb_frostAt(w3s));
	float detail = saturate(2.3 - distEye / 120.0);
	float bubD = saturate(max((f.oxy - 0.82) * 1.2, f.froth * 1.6) * 2.0) * fresh;
	float microFoam = 0.0;
	[branch] if (bubD * detail > 0.02)
	{
		float2 abg;
		float bh = ghmpb_airBubble(f.crackPos * lerp(1.7, 2.6, saturate(f.froth * 3.0)),
		                           lerp(0.22, 0.7, saturate(f.froth * 2.0)) * bubD * detail * 0.55, abg);
		N = normalize(N - (Tt2 * abg.x + Bt2 * abg.y) * lerp(0.04, 0.085, saturate(f.froth * 2.0)));
		microFoam = bh * saturate(f.froth * 2.0) * detail * 0.18;
	}

	float bigD = saturate(f.froth * 4.0) * smoothstep(0.14, 0.52, h) * (1.0 - smoothstep(0.4, 0.82, fm.z));
	float bubMul = 1.0;
	[branch] if (bigD > 0.03)
	{
		float2 bbg;
		float bigRim;
		float bigMask = ghmpb_bigBubble(f.crackPos * 0.12 + 11.7, SC0.w, 0.88 * bigD, bbg, bigRim);
		// Real 3D spherical bubble dome normals tilted into N so sun, flashlight, lamps and sky reflect off each dome
		N = normalize(N - (Tt2 * bbg.x + Bt2 * bbg.y) * (0.20 * bigMask));
		bubMul = 1.0 - 0.30 * bigMask + 1.55 * bigRim;
	}

	float bubBoil = max(ghmpb_boilAt(w3s), ghmpb_fizzAt(w3s)) * smoothstep(0.02, 0.15, h) * (1.0 - ghmpb_frostAt(w3s));
	[branch] if (bubBoil > 0.01)
	{
		float boilFizz = step(ghmpb_boilAt(w3s), ghmpb_fizzAt(w3s));
		float2 bg;
		float boilMask = ghmpb_bubble(f.crackPos * lerp(0.4, 0.7, boilFizz), SC0.w * lerp(1.1, 2.6, boilFizz), bg);
		N = normalize(N - (Tt2 * bg.x + Bt2 * bg.y) * (0.14 * bubBoil));
		microFoam += boilMask * bubBoil * 0.45;
	}

	// 3. Coagulating fibrin micro-webbing & gel skin wrinkles
	float fibrinBand = smoothstep(0.25, 0.65, cf) * (1.0 - smoothstep(0.82, 0.98, cf)) * wet;
	float gel = smoothstep(0.55, 0.95, cf);
	[branch] if ((gel > 0.0 || fibrinBand > 0.0) && hL > 0.035)
	{
		float2 wg = ghmpb_vnoise_grad(f.crackPos * 1.3) + 0.5 * ghmpb_vnoise_grad(f.crackPos * 2.9 + 7.0);
		float2 fg = ghmpb_vnoise_grad(float2(f.crackPos.x * 5.2, f.crackPos.y * 1.4) + 19.3);
		float lw = gel * smoothstep(0.12, 0.6, hL);
		float2 lg = ghmpb_vnoise_grad(f.crackPos * 0.45 + 3.3);
		float wa = 0.032 * gel * saturate(hL / 0.3);
		float fa = 0.022 * fibrinBand * saturate((220.0 - distEye) / 130.0);
		N = normalize(N - Tt2 * (wg.x * wa + lg.x * 0.05 * lw + fg.x * fa) - Bt2 * (wg.y * wa + lg.y * 0.05 * lw + fg.y * fa));
	}

	// 4. Dual-lobe dielectric coat + Full World Meniscus Rim Glints (Sun + Flashlight + 4 Map Lamps)
	float3 fbS = ghmpb_toLinear(tex2Dlod(AccT, float4(suv, max(0.0, -N.x * 0.0), 0)).rgb);
	float3 E = ghmpb_irradiance(fbS, albedo);
	float envOcc = saturate(ghmpb_luma(fbS) * 6.0 + 0.05);

	float3 V = normalize(gEye - P);
	float NoV = saturate(dot(N, V));
	float Esh = ghmpb_luma(ghmpb_shIrradiance(Nb, SC15, SC16, SC17));
	float k = clamp(ghmpb_luma(E) / max(Esh, 1e-3), 0.0, 6.0);
	k /= 1.0 + 135.0 * q.nvar;

	float4 m0 = ghmpb_mat(0.0, 0.0);
	float soakF = m0.x * ghmpb_matFresh(m0.w);
	float dryC = (1.0 - exp(-sL * 6.0)) * (1.0 - 0.75 * crack);
	float wetSpec = wet * (1.0 - 0.55 * fabric * saturate(1.0 - hL / 0.5));
	float drySpec = (1.0 - wet) * dryC * (1.0 - 0.85 * soakF);
	float specW = wetSpec + drySpec;
	float F0s = lerp(GHMPB_F0_DRY, GHMPB_F0_WET, wet);

	float rLiquid = lerp(0.30, 0.026, saturate(wv));
	float rough = lerp(max(roughSub, 0.12), rLiquid, smoothstep(0.02, 0.2, hL * wv));
	rough = lerp(rough, 0.125, gel * saturate(hL / 0.05));
	float rDry = lerp(lerp(0.6, 0.22, smoothstep(0.1, 0.8, sL)), 0.8, soakF);
	rough = lerp(lerp(roughSub, rDry, dryC), rough, wet);
	rough = lerp(rough, 0.75, fabric * saturate(1.0 - hL / 0.4));
	float w3r = max(SC3.w, -NoV);
	rough = lerp(rough, 0.032, ghmpb_frostAt(w3r) * wet * 0.85);
	rough = lerp(rough, 0.72, ghmpb_char() * (1.0 - wet));
	rough = lerp(rough, 0.38, saturate(microFoam * 1.2));
	rough = saturate(rough);
	float a2 = rough * rough * rough * rough + min(4.0 * q.nvar + flowVar, 0.18);
	rough = max(sqrt(sqrt(a2)), 0.02);
	float roughSubSheen = saturate(rough * 2.15 + 0.085);

	float3 Lf;
	float3 flash = ghmpb_flashlight(P, N, V, rough, Lf);
	float3 spec = (microFoam * 0.055 / max(specW, 0.05)) * float3(1.0, 0.62, 0.60) * E;

	// Direct GGX: Sun + Flashlight (sharp plasma topcoat + subtle broader fibrin/corpuscular secondary lobe)
	[loop] for (int li = 0; li < 2; li++)
	{
		float3 L = normalize(li == 0 ? SC11.xyz : Lf);
		float3 rad = li == 0 ? SC12.rgb * (SC11.w * k) : flash;
		float rl = li == 0 ? rough : saturate(rough + 0.07);
		float3 s1 = ghmpb_specGGX(N, V, L, rad, F0s.xxx, rl);
		float3 s2 = ghmpb_specGGX(N, V, L, rad, (F0s * 0.22).xxx, roughSubSheen) * (0.35 + 0.65 * fibrinBand);
		spec += min(s1 + s2, li == 0 ? 100.0 : 1.65);
	}

	// Direct GGX: up to 4 local map lamps / projected lights / dynamic lights from ProbeT
	[loop] for (int lt = 0; lt < 4; lt++)
	{
		float ly0 = 1.0 + lt;
		float4 lb = ghmpb_pt(385.0, ly0);
		float ltype = floor(lb.w * 255.0 + 0.5);
		[branch] if (ltype > 0.5)
		{
			float4 la = ghmpb_pt(384.0, ly0), lc = ghmpb_pt(386.0, ly0), ld = ghmpb_pt(387.0, ly0);
			float3 Ldv = ghmpb_ptPos(la, lb.xy) - P;
			float ldist = length(Ldv);
			float3 Ll = Ldv / max(ldist, 1e-3);
			float lwin = saturate(1.0 - ldist / max(floor(lb.z * 255.0 + 0.5) * 64.0, 1.0));
			float cosO = ld.w;
			float lspot = ltype > 1.5 ? smoothstep(cosO, cosO + (1.0 - cosO) * 0.3 + 1e-3, dot(-Ll, normalize(ld.xyz * 2.0 - 1.0))) : 1.0;
			float3 lrad = lc.rgb * (exp2(lc.w * 24.0 - 4.0) / max(ldist * ldist, 16.0) * lwin * lwin * lspot * (ltype > 2.5 ? 1.0 : k));
			float rl = ltype > 2.5 ? saturate(rough + 0.07) : rough;
			spec += min(ghmpb_specGGX(N, V, Ll, lrad, F0s.xxx, rl), 4.2);
		}
	}

	// Unlocked full 55-deg contact-angle Meniscus Rim Glints for Sun + Flashlight + all 4 Map Lamps!
	float slopeL = length(f.slope);
	float rimG = wet * saturate(slopeL * 14.0) * (1.0 - cf);
	[branch] if (rimG > 0.01)
	{
		float3 Nr = normalize(Nb - f.slope / max(slopeL, 1e-5) * (1.43 * saturate(slopeL * 10.0)));
		float3 Lr;
		float3 fr = ghmpb_flashlight(P, Nr, V, 0.11, Lr);
		float3 rimS = min(ghmpb_specGGX(Nr, V, Lr, fr, F0s.xxx, 0.11), 1.6);
		rimS += min(ghmpb_specGGX(Nr, V, normalize(SC11.xyz), SC12.rgb * (SC11.w * k), F0s.xxx, 0.11), 1.6);
		[loop] for (int lr = 0; lr < 4; lr++)
		{
			float4 rb = ghmpb_pt(385.0, 1.0 + lr);
			float rtype = floor(rb.w * 255.0 + 0.5);
			[branch] if (rtype > 0.5)
			{
				float4 ra = ghmpb_pt(384.0, 1.0 + lr), rc = ghmpb_pt(386.0, 1.0 + lr), rd4 = ghmpb_pt(387.0, 1.0 + lr);
				float3 Rdv = ghmpb_ptPos(ra, rb.xy) - P;
				float rdist = length(Rdv);
				float3 Rl = Rdv / max(rdist, 1e-3);
				float rwin = saturate(1.0 - rdist / max(floor(rb.z * 255.0 + 0.5) * 64.0, 1.0));
				float rspot = rtype > 1.5 ? smoothstep(rd4.w, rd4.w + (1.0 - rd4.w) * 0.3 + 1e-3, dot(-Rl, normalize(rd4.xyz * 2.0 - 1.0))) : 1.0;
				float3 rrad = rc.rgb * (exp2(rc.w * 24.0 - 4.0) / max(rdist * rdist, 16.0) * rwin * rwin * rspot * (rtype > 2.5 ? 1.0 : k));
				rimS += min(ghmpb_specGGX(Nr, V, Rl, rrad, F0s.xxx, 0.11), 1.6);
			}
		}
		spec += rimS * rimG;
	}

	// Frost / ice facet glints
	float w3f = max(SC3.w, -spec.x);
	float spark = ghmpb_mat(1.0, 0.3).y;
	[branch] if (max(spark, ghmpb_frostAt(w3f)) > 0.0)
	{
		float2 gc = floor(f.crackPos * 2.5);
		float gh = ghmpb_hash12(gc);
		float cell = step(0.93, gh) * max(spark * saturate(1.0 - hL / 0.15), ghmpb_frostAt(w3f) * 0.8);
		float3 Nj = normalize(N + (float3(ghmpb_hash12(gc + 3.7), ghmpb_hash12(gc + 8.1), 0.5) - 0.5) * 0.9);
		bool sun = ghmpb_luma(SC12.rgb * SC11.w) > ghmpb_luma(SC3.rgb) * 0.5;
		float3 Ls = normalize(sun ? SC11.xyz : SC2.xyz);
		float gs = pow(saturate(dot(Nj, normalize(Ls + V))), sun ? 2400.0 : 900.0) * saturate(dot(Nj, Ls)) * 40.0;
		spec += min((sun ? SC12.rgb * SC11.w : SC3.rgb * 0.5) * (gs * k * cell), 2.0);
	}

	float mvS = 7.0 * saturate(f.flowSpeed * 0.5);
	float frW = wet * (1.0 - cf);
	float rSHi = ghmpb_reflScale() * min(1.0 + (ghmpb_freshShine() + mvS) * frW, 8.0);
	spec = min(spec * specW * rSHi, 2.25);

	// 5. Environment probe + Mirrored Floor + 6-Step Screen-Space Reflections
	float rSEnv = ghmpb_reflScale() * min(1.0 + (0.3 * ghmpb_freshShine() + mvS) * frW, 8.0);
	float3 R = reflect(-V, N);
	float3 envC = ghmpb_probeEnv(P, R, rough);
	envC *= ghmpb_pt(385.0, 0.0).w > 0.5 ? 1.0 : envOcc;
	envC = max(envC, ghmpb_shIrradiance(R, SC15, SC16, SC17) * k * GHMPB_INV_PI);
	float ho = saturate(1.0 + 1.1 * dot(R, Ng));
	float3 Fr = ghmpb_envBRDFApprox(F0s.xxx, rough, NoV) * specW * ho * ho * rSEnv;

	float roughR = lerp(lerp(max(roughSub, 0.12), 0.028, smoothstep(0.02, 0.2, h)), 0.13, gel);
	float3 Rr = reflect(-V, normalize(Ng + (N - Ng) * 0.38));
	float reflConf;
	float3 reflIn;
	float4 mh = ghmpb_pt(max(388.0, -Fr.x), 0.0);
	float mz = ghmpb_u16(mh.x, mh.y) * (32768.0 / 65535.0) - 16384.0;
	float wM = (mh.z > 0.5 && Ng.z > 0.985 && abs(P.z - mz) < 2.5) ? 1.0 - smoothstep(0.07, 0.22, roughR) : 0.0;
	[branch] if (wM > 0.01)
	{
		float4 Qm = float4(P + float3(Rr.x, Rr.y, -Rr.z) * 60.0, 1.0);
		float4 cm = float4(dot(Qm, i.vp0), dot(Qm, i.vp1), dot(Qm, i.vp2), dot(Qm, i.vp3));
		float2 m = clamp(cm.xy / max(cm.w, 1.0) * 0.5 + 0.5 + float2(0.5 / 1024.0, 0.5 / 512.0), float2(0.0006, 0.0011), float2(0.9994, 0.9989));
		reflIn = ghmpb_reflBoost(ghmpb_toLinear(tex2Dlod(ProbeT, float4(m.x, 0.5 + 0.5 * m.y, 0, 0)).rgb));
		reflConf = wM;
	}
	else
	{
		reflIn = ssr6(i, P, Rr, roughR, reflConf);
		reflConf *= saturate(1.0 - 1.75 * dot(Rr, Ng));
		reflConf *= ghmpb_pt(385.0, 0.0).w > 0.5 ? 0.40 : 1.0;
	}
	float3 coatSpec = spec + envC * Fr + Fr * (reflIn - envC) * reflConf;

	if (gDbg > 2.5 && gDbg < 3.5)
	{
		return float4(ghmpb_toSRGB(coatSpec), 1.0);
	}

	// Fetch Pass 1 optical body right at the composite point (tied to coatSpec so fxc never hoists it across lighting loops)
	float3 col = ghmpb_toLinear(tex2Dlod(FB, float4(suv, 0.0, max(0.0, -coatSpec.x))).rgb);
	float aSat = saturate(alive);
	col = col * lerp(1.0, bubMul, aSat) + coatSpec * aSat;
	return float4(ghmpb_toSRGB(col), 1.0);
#endif
}
