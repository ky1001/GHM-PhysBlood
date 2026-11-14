// =====================================================================================
// GHM PhysBlood: blood on world surfaces (walls, floors, ceilings, pools) - shared by the dynamic layer
// (surface_ps30: live cell field) and the aftermath layer (surfstatic_ps30: baked RGBA8 field).
// The patch quad / grid lies on the hit plane; the cell field is in patch space. Albedo of the underlying
// surface comes from the material's average colour (measured on the GPU), everything else from the lit
// framebuffer (see ghmpb_shade.h).
//   t0 = (patch uv, lowest surface under this part of the mesh (u), 0), t1 = patch U axis * size (units per uv),
//   t2 = (patch V axis * size, relief flag), t3 = (normal, plane distance), t4 = world position, t5 = eye position
// dynamic: s0 state  s1 _rt_FullFrameFB  s2 bed map (height u, surface present, normal U, V)  s3 the surface's normal map
//          s4 aux (clot volume, -, -, second type volume)  s5 env cubemap  s6 accumulator (w = oxygenated volume)
// static:  s0 aftermath (sqrt h/4, sqrt s/4, clot, surface present + bed height)  s1 FB  s3 the surface's normal map
//          s5 env cubemap
// (1.21.0) t0.w, t1.w = the surface's own texture coordinate (its normal map, cl_bsptex.lua), t2.w = relief flag + 2 *
// the kind of that normal map (0 none, 1 normal map, 2 self-shadowing ssbump)
// both:    s7 the surface material table (1.18.0, ghmpb_mat)
// RELIEF (joints, cobbles, steps, displacements): the mesh lies over the highest surface; the view ray is
// marched through the height field of bed + blood (parallax), so blood that ran into a mortar joint or a dip
// is drawn down there and hidden behind the bricks from low angles, and it is lit with the real surface normal.
// SC2.w = smooth mode (0 raw texels, 1 bicubic + AA, 2 + organic edges)
// =====================================================================================
sampler State  : register(s0);
sampler FB     : register(s1);
sampler Bed    : register(s2);
sampler SurfBump : register(s3);
sampler Aux    : register(s4);
sampler ProbeT : register(s5);      // (1.25.0: the reflection probe atlas of the blood group, ghmpb_shade.h)
#if !GHMPB_STATIC
sampler AccT   : register(s6);
#endif
// the surface material table (1.18.0, see ghmpb_mat in ghmpb_shade.h)
sampler MatT   : register(s7);
#define GHMPB_WORLD 1
#include "ghmpb_shade.h"

struct PS_INPUT {
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

// Screen-space reflection without a depth buffer: the reflected ray is sampled at a few distances and
// the framebuffer is read where those points land on screen. That gives a glossy, slightly smeared
// reflection of whatever stands above the blood (walls, bodies, lamps, windows) - the main cue that makes
// a pool read as wet. Returns the colour and how much of it was on screen.
float3 ssr(PS_INPUT i, float3 P, float3 R, float rough, out float conf)
{
	float3 acc = 0;
	float wsum = 0;
	float blur = 0.0015 + rough * 0.03;
	[loop] for (int k = 0; k < 4; k++)
	{
		// (10, 25, 62, 156 u)
		float d = 10.0 * exp2(1.32 * k);
		// the near samples mostly land on the floor right next to the pool: favour the far ones, which carry
		// the walls, bodies and lamps standing around it
		float dw = 0.4 + 0.4 * k;
		float4 Q = float4(P + R * d, 1.0);
		float4 c = float4(dot(Q, i.vp0), dot(Q, i.vp1), dot(Q, i.vp2), dot(Q, i.vp3));
		if (c.w > 1.0)
		{
			float2 ruv = c.xy / c.w * float2(0.5, -0.5) + 0.5 + 0.5 * SC0.xy;
			float2 e2 = min(ruv, 1.0 - ruv);
			float ew = saturate(min(e2.x, e2.y) * 10.0);
			float3 t = tex2Dlod(FB, float4(ruv, 0, 0)).rgb * 2.0;
			t += tex2Dlod(FB, float4(ruv + float2(blur, 0), 0, 0)).rgb;
			t += tex2Dlod(FB, float4(ruv - float2(0, blur), 0, 0)).rgb;
			acc += ghmpb_reflBoost(ghmpb_toLinear(t * 0.25)) * ew * dw;
			wsum += ew * dw;
		}
	}
	conf = saturate(wsum / 4.0 * 1.2);   // (sum of dw = 4)
	return wsum > 1e-3 ? acc / wsum : float3(0, 0, 0);
}

// (h mm, s mm, clot fraction, surface mask); alt = fraction of the layer's second blood type
// (static: the aftermath keeps the type fraction in b; clotting there follows the drying of the layer)
// (gOxyF: oxygen saturation at uv - live layers per pixel, the aftermath the patch average in SC1.x)
static float gOxyF = 0.75;
float4 fetchFilmA(float2 uv, float tx, bool cubic, out float alt)
{
#if GHMPB_STATIC
	gOxyF = SC1.x;
	float4 a = cubic ? ghmpb_cubic(State, uv, tx) : tex2Dlod(State, float4(uv, 0, 0));
	alt = saturate(a.b);
	return float4(a.r * a.r * 4.0, a.g * a.g * 4.0, lerp(0.6, 1.0, saturate(ghmpb_layerDry() * 1.5)), smoothstep(0.08, 0.2, a.a));
#else
	float4 st = cubic ? ghmpb_cubic(State, uv, tx) : tex2Dlod(State, float4(uv, 0, 0));
	float4 ax = cubic ? ghmpb_cubic(Aux, uv, tx) : tex2Dlod(Aux, float4(uv, 0, 0));
	float mask = smoothstep(0.3, 0.7, (cubic ? ghmpb_cubic(Bed, uv, 1.0 / 128.0) : tex2Dlod(Bed, float4(uv, 0, 0))).y);
	float h = max(st.x, 0.0);
	// aux.w = volume of the second blood type in this texel (wet + stain)
	alt = saturate(ax.w / max(h + max(st.y, 0.0), 1e-4));
	float ow = (cubic ? ghmpb_cubic(AccT, uv, tx) : tex2Dlod(AccT, float4(uv, 0, 0))).w;
	gOxyF = saturate(ow / max(h + max(st.y, 0.0), 1e-4));
	return float4(h, max(st.y, 0.0), h > 1e-4 ? saturate(ax.x / h) : 0.0, mask);
#endif
}
float4 fetchFilm(float2 uv, float tx, bool cubic) { float a; return fetchFilmA(uv, tx, cubic, a); }

// height of the real surface under the blood (u above the patch plane; no surface = deep, rays pass)
float bedAt(float2 uv)
{
#if GHMPB_STATIC
	float a = tex2Dlod(State, float4(uv, 0, 0)).a;
	return a > 0.2 ? (a - 0.25) / 0.75 * 8.0 - 4.0 : -8.0;
#else
	float4 b = tex2Dlod(Bed, float4(uv, 0, 0));
	return b.y > 0.5 ? b.x : -8.0;
#endif
}

// top of what the view ray meets at uv: the free surface of the blood (bed + depth: a pool over a joint is
// level, not a trench), or the bare surface
float topAt(float2 uv)
{
	float4 st = tex2Dlod(State, float4(uv, 0, 0));
#if GHMPB_STATIC
	float h = st.r * st.r * 4.0, s = st.g * st.g * 4.0;
#else
	float h = max(st.x, 0.0), s = max(st.y, 0.0);
#endif
	return bedAt(uv) + max(ghmpb_visH(h, s), h) / 19.05;
}

// low-passed scene under the blood (linear): the light that reaches an opaque pool. Two rings (16 and 44
// px) so grout lines, tile edges and texture detail do not print through thick blood as light changes
float3 fbT(float2 suv) { return ghmpb_toLinear(tex2Dlod(FB, float4(suv, 0, 0)).rgb); }
// (1.18.0: as loops - unrolled, the compiler fetched all thirteen taps up front and the shader ran out of temp registers)
float3 fbBlur(float2 suv)
{
	float2 r = SC0.xy * 16.0;
	float2 r2 = SC0.xy * 44.0;
	float3 c = fbT(suv) * (0.55 * 2.0 / 8.0);
	[loop] for (int k = 0; k < 6; k++)
	{
		float a = k * 1.0471976 + 0.3;
		c += fbT(suv + float2(cos(a), sin(a)) * r) * (0.55 / 8.0);
	}
	[loop] for (int k2 = 0; k2 < 4; k2++)
	{
		float a2 = k2 * 1.5707963 + 0.29;
		c += fbT(suv + float2(cos(a2), sin(a2)) * r2) * (0.45 / 4.0);
	}
	return c;
}

float4 main(PS_INPUT i) : COLOR
{
	gEye = i.eye.xyz;
	// SC2.w = smooth mode + 4 * debug view + 32 * surface material id (1.16.0)
	float rem2 = SC2.w - 1024.0 * ghmpb_serumOn() - ghmpb_matId() * 32.0;
	gDbg = floor(rem2 / 4.0 + 0.01);
	float smoothMode = rem2 - gDbg * 4.0;
	float tx = SC0.z;
	float2 uv0 = i.t0.xy;
	float3 P = i.wpos.xyz;
	float3 Ng = normalize(i.t3.xyz);
	float3 Tw = i.t1.xyz, Bw = i.t2.xyz;
	float3 Vr = normalize(i.eye.xyz - P);
	// parallax: march the view ray from the mesh (over the highest surface) down through bed + blood
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
			// steps: about one per texel of travel across the patch (a steep view crosses a texel or two, a
			// grazing one many), 2 .. 20
			float nS = clamp(ceil(length(duv) * tMax / tx), 2.0, 20.0);
			// (a pool standing higher than the mesh: the ray meets it right where it enters)
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
						// bisection inside the bracketing interval: the surface can jump there (the edge of a brick
						// over a joint), where a secant step lands anywhere in between - neighbouring pixels then
						// alternate between brick and joint and the edge comes out as a comb of slivers
						float ta = tPrev, tb = t, da = dPrev;
						[unroll] for (int r = 0; r < 5; r++)
						{
							float tm = 0.5 * (ta + tb);
							float dm = (z0 + dz * tm) - topAt(uv0 + duv * tm);
							if (dm <= 0.0) { tb = tm; dd = dm; } else { ta = tm; da = dm; }
						}
						// (final secant inside the last, tiny interval)
						tHit = ta + (tb - ta) * saturate(da / max(da - dd, 1e-5));
						break;
					}
					tPrev = t;
					dPrev = dd;
				}
			}
			uv0 += duv * tHit;
			P += rd * tHit;
			// a hit on the side of a step (the edge of a brick over its joint, a curb): the height field has no area
			// there - its texels would be stretched down the whole side as streaks. The side is drawn bare unless
			// blood fills the step (then the top is the level blood surface, not steep)
			// (the steepest slope around the hit, half a bed texel to either side along U and V: a step is a one-texel
			// ramp in the filtered bed - a 0.75 u joint is a slope of ~2.4 there)
			float eb = 0.5 / 128.0;
			float sU = abs(topAt(uv0 + float2(eb, 0)) - topAt(uv0 - float2(eb, 0))) / max(2.0 * eb * length(Tw), 1e-4);
			float sV = abs(topAt(uv0 + float2(0, eb)) - topAt(uv0 - float2(0, eb))) / max(2.0 * eb * length(Bw), 1e-4);
			sideCut = smoothstep(1.2, 2.2, max(sU, sV));
		}
	}
	float2 uv = uv0;
	// plane-global patch coordinate (patch uv + patch index, wrapped every 16 patches): noise, cracks and
	// ripples line up across patch borders instead of restarting in every patch
	float3 Tw0 = i.t1.xyz, Bw0 = i.t2.xyz;
	float2 guv = float2(dot(P, Tw0) / max(dot(Tw0, Tw0), 1e-8), dot(P, Bw0) / max(dot(Bw0, Bw0), 1e-8));
	guv = frac(guv / 16.0) * 16.0;
	if (smoothMode > 1.5)
	{
		// organic sub-texel edges: warp the lookup by a smooth noise of about one texel
		float2 q = guv / tx * 0.45;
		uv += (float2(ghmpb_vnoise(q), ghmpb_vnoise(q + 37.1)) - 0.5) * tx * 1.6;
	}
	bool cubic = smoothMode > 0.5;
	float altF;
	float4 fm = fetchFilmA(uv, tx, cubic, altF);
	float oxyF = gOxyF;
	float h = fm.x, s = fm.y;
	// the surface breaks thin blood up (1.16.0): sand grains and concrete pores speckle the edges, blood runs into the
	// gaps between gravel stones and off their tops, grass holds it on its blades
	float4 m2 = ghmpb_mat(2.0, 0.0);
	[branch] if (m2.z > 0.0)
	{
		float2 gp = guv / tx * m2.w;
		float gn;
		float grainKind = ghmpb_mat(3.0, 0.0).x;
		if (grainKind > 1.5) gn = ghmpb_vnoise(float2(gp.x * 2.2, gp.y * 0.35)) * 0.7 + ghmpb_vnoise(gp * 1.7 + 3.3) * 0.3;
		else if (grainKind > 0.5) { float2 gg; gn = 1.0 - smoothstep(0.0, 0.35, ghmpb_crack(gp, gg)); }
		else gn = 0.6 * ghmpb_vnoise(gp) + 0.4 * ghmpb_vnoise(gp * 2.3 + 7.1);
		// (thick blood levels it: a pool is a pool)
		float gm = lerp(lerp(1.0 - m2.z, 1.0 + m2.z, gn), 1.0, smoothstep(0.3, 1.2, h));
		h *= gm;
		s *= gm;
	}
	float amount = h + s * 0.4;
	float cov;
	if (cubic)
	{
		// (1.25.0: a little wider - the edge is anti-aliased over about a pixel and a half, no stair steps or grain)
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
	// wicking halo around the stain (1.16.0): what the surface drew out of the blood beyond its edge - damp, darker
	// concrete / soil / sand / wood around a pool; pink melt water in snow; a pale serum fringe in paper, plaster, cloth
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
#if GHMPB_STATIC
		// (damp dries out; pink melt water and serum stay)
		if (ghmpb_mat(1.0, 0.0).w < 0.5) halo *= saturate(1.0 - ghmpb_layerDry() * 1.5);
#endif
	}
	// (1.26.9c) serum separation (static layer, floors, only pools a wounded body bled into: Lua sets 1024 in SC2.w). After a
	// pool has clotted and the clot has retracted, clear serum seeps out of it: it mixes into the thinning blood at the rim
	// (f.serum below) and runs out past the clot's edge as a wide, translucent, watery fringe (serHalo) - uneven along the
	// rim, up to ~5 cm. Never round spatter or blood that only splashed. The neighbours are read once here for both
	// (their wet + dried blood: a dried pool has no wet blood left)
	float serRim = 0.0, serHalo = 0.0;
#if GHMPB_STATIC
	[branch] if (ghmpb_serumOn() > 0.5 && fm.z > 0.6)
	{
		float rS = tx * 6.0, rL = tx * 16.0;
		float4 n0 = fetchFilm(uv + float2(rS, 0), tx, false), n1 = fetchFilm(uv - float2(rS, 0), tx, false);
		float4 n2 = fetchFilm(uv + float2(0, rS), tx, false), n3 = fetchFilm(uv - float2(0, rS), tx, false);
		float nb1 = max(max(n0.x + n0.y, n1.x + n1.y), max(n2.x + n2.y, n3.x + n3.y));
		// (near the edge of the blood: a neighbour a few texels away is bare)
		float edgeF = 1.0 - smoothstep(0.03, 0.25, min(min(n0.x + n0.y, n1.x + n1.y), min(n2.x + n2.y, n3.x + n3.y)));
		n0 = fetchFilm(uv + float2(rL, rL * 0.35), tx, false); n1 = fetchFilm(uv - float2(rL, rL * 0.35), tx, false);
		n2 = fetchFilm(uv + float2(-rL * 0.35, rL), tx, false); n3 = fetchFilm(uv - float2(-rL * 0.35, rL), tx, false);
		float nb2 = max(max(n0.x + n0.y, n1.x + n1.y), max(n2.x + n2.y, n3.x + n3.y));
		float serNb = max(nb1, 0.75 * nb2);
		serRim = smoothstep(0.2, 0.9, serNb) * edgeF;
		float rimN = 0.55 + 0.45 * ghmpb_vnoise(uv / tx * 0.11 + 3.7);
		serHalo = rimN * smoothstep(0.1, 0.6, max(nb1, 0.55 * nb2)) * (1.0 - saturate(cov * 1.5)) * fm.w * (1.0 - sideCut)
		        * saturate((fm.z - 0.6) / 0.3) * smoothstep(0.15, 0.7, ghmpb_layerDry()) * fade;
	}
#endif
	clip(max(max(alive, halo * fade), serHalo) - 0.002);
	// (what the halo does at the end, as one value: 1.19.0, the world shader at the ps_3_0 temp register limit)
	float haloW = halo * fade * (1.0 - saturate(alive));

	// the real surface's normal under the blood (displacements, sloped paving, rounded cobbles)
	if (reliefF > 0.5)
	{
		float3 Tu = normalize(Tw), Bv = normalize(Bw);
#if GHMPB_STATIC
		float e = tx * 4.0;
		float2 sl = float2(bedAt(uv + float2(e, 0)) - bedAt(uv - float2(e, 0)), bedAt(uv + float2(0, e)) - bedAt(uv - float2(0, e)));
		sl /= 2.0 * e * float2(length(Tw), length(Bw));
		sl = clamp(sl, -1.5, 1.5);
		Ng = normalize(Ng - Tu * sl.x - Bv * sl.y);
#else
		float2 nb = tex2Dlod(Bed, float4(uv, 0, 0)).zw;
		Ng = normalize(Ng * sqrt(saturate(1.0 - dot(nb, nb))) + Tu * nb.x + Bv * nb.y);
#endif
	}

	// film relief -> normal (saturating visual height so pools do not look like hills)
#ifndef GHMPB_LIP
#define GHMPB_LIP 2
#endif
	float3 slope;
	if (cubic)
	{
		// (snow: the stain melts a hollow - 1.16.0)
#if !GHMPB_STATIC && GHMPB_LIP == 2
		// (1.26.9d) a pool a body is bleeding into (Lua sets 1024 in SC2.w on the live layer while it feeds it, see
		// ghmpb_serumOn - on live layers the serum is never drawn) keeps pushing on: its front stands as a slightly raised,
		// rounded lip at the edge, gone once the blood gels (a ridge in the film's height around 0.3 mm)
		float hv = (ghmpb_visH(h, s) + ghmpb_serumOn() * (1.0 - fm.z) * h * exp(1.0 - h * 3.3333)
		            - ghmpb_mat(1.0, 0.0).z * 0.35 * min(s, 1.0)) / 19.05;
#elif !GHMPB_STATIC && GHMPB_LIP == 3
		float lipT = saturate(1.0 - abs(h * 3.3333 - 1.0));
		float hv = (ghmpb_visH(h, s) + ghmpb_serumOn() * (1.0 - fm.z) * 0.3 * lipT * lipT * (3.0 - 2.0 * lipT)
		            - ghmpb_mat(1.0, 0.0).z * 0.35 * min(s, 1.0)) / 19.05;
#elif !GHMPB_STATIC && GHMPB_LIP == 4
		float hv = (ghmpb_visH(h, s) + ghmpb_serumOn() * h * exp(1.0 - h * 3.3333) - ghmpb_mat(1.0, 0.0).z * 0.35 * min(s, 1.0)) / 19.05;
#else
		float hv = (ghmpb_visH(h, s) - ghmpb_mat(1.0, 0.0).z * 0.35 * min(s, 1.0)) / 19.05;
#endif
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

	// (1.26.10) inside a pool the liquid is level: the simulated height keeps its relief only at the edges - the meniscus, beads,
	// drops, the lip of a pool being fed: wherever the film thins out within a texel or two. Inside, its texel-sized bumps read
	// as thick, jelly ripples (GHM: "now it looks like ... depth fluid thick ripples"); the fine surface of the flowing liquid
	// comes from the flow-mapped ripples (ghmpb_filmSpec) instead
	float rimW = smoothstep(0.08, 0.3, length(float2(ddx(h), ddy(h))) / ((length(float2(ddx(uv.x), ddy(uv.x))) / tx + 1e-4) * max(h, 0.02)));
	slope *= lerp(0.2, 1.0, rimW);

	float2 suv = (i.vpos + 0.5) * SC0.xy;
	float3 fbG = tex2Dlod(FB, float4(suv, 0, 0)).rgb;
	float3 fb = ghmpb_toLinear(fbG);
	float3 albedo = SC18.rgb;
	// fake micro relief of the underlying surface from the framebuffer so thin films follow grout / cracks
	float lc = ghmpb_luma(fbG);
	float3 Ns = normalize(Ng - (ddx(lc) * normalize(Tw) + ddy(lc) * normalize(Bw)) * 0.8);
	// (1.21.0) the surface's own normal map, where it has one: thin films and dried stains take on its relief (grout, cracks,
	// grain, pores) - ghmpb_filmPre decides how much by the depth of the blood. Tangent frame from the surface's texture
	// coordinate (+u, +v, as on the bodies); a self-shadowing ssbump map is turned back into a normal over Source's three
	// basis directions
	// (no branch: the tangent frame and the mip level need screen derivatives; on a surface without one s3 is plain white)
	{
		float2 buv = float2(i.t0.w, i.t1.w);
		float3 bT, bB;
		float3x3 btbn = ghmpb_tangentFrame(Ng, i.wpos.xyz, buv, bT, bB);
		// (relief patches: the view ray was marched down to where it meets the surface - the texture coordinate moves with it.
		// It is affine in the patch uv: the step in uv through the inverse of d uv / d screen, then through d tex / d screen)
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
#if GHMPB_STATIC
	f.froth = 0.0;
#else
	// froth (1.19.0): the share of the wet blood whipped up with air - energetic impacts, bright spurts and lung blood bring it,
	// the simulation carries it along with the flowing blood (aux.z of floors and gentle slopes; the CPU sends no froth amount
	// for steep patches, where aux.z is the column weight of runs) and lets it burst over a minute or so
	f.froth = saturate(tex2Dlod(Aux, float4(uv, 0, 0)).z / max(h, 1e-3)) * saturate(ghmpb_frothAmt());
#endif
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

	float2 vt = h > 0.01 ? tex2Dlod(State, float4(uv, 0, 0)).zw / h : float2(0, 0);          // texels / s
	float vs = length(vt);
	f.flowUV = vs > 1e-3 ? vt / vs : float2(0, 0);
	f.flowW = Tw0 * f.flowUV.x + Bw0 * f.flowUV.y;
	// (cm per texel: the 40 u patch over its resolution - 1.21.0, s3 holds the surface's normal map now, not the force field)
	f.flowSpeed = vs * (40.0 * GHMPB_UNITS_TO_CM * tx) * (1.0 - f.clot);        // cm / s
	float dryT = 0.0;
#endif

	// everything that needs screen derivatives first; the rest of the shading only runs where there is blood (most
	// of a patch's quad is bare surface)
	GHMPB_Pre q = ghmpb_filmPre(Ng, Ns, P, f, dryT);
	float3 col = fb;
	[branch] if (alive > 0.002)
	{
#if GHMPB_STATIC
		// (1.26.9c) the serum in the thinning blood at the rim of a wound's pool (neighbours read above): a watery, paler
		// fringe mixed into the thin film, strongest where the blood thins out
		[branch] if (serRim > 0.0 && h < 1.2)
		{
			float hs = h + s * 0.3;
			float rim = 0.6 + 0.4 * ghmpb_vnoise(uv / tx * 0.11 + 3.7);
			f.serum = 0.55 * rim * serRim * smoothstep(0.008, 0.04, hs) * (1.0 - smoothstep(0.3, 1.0, hs))
			        * saturate((fm.z - 0.6) / 0.3) * smoothstep(0.15, 0.7, ghmpb_layerDry());
		}
#endif
		float3 fbS = fbBlur(suv);
		float3 E = ghmpb_irradiance(fbS, albedo);
		// the film shading in two parts with the screen-space reflection in between (see ghmpb_filmSpec)
		GHMPB_Spec sp = ghmpb_filmSpec(E, saturate(ghmpb_luma(fbS) * 6.0 + 0.05), Ng, P, f, q, 1.0);
		float roughR = lerp(lerp(max(ghmpb_roughSub(), 0.12), 0.03, smoothstep(0.02, 0.2, h)), 0.13, smoothstep(0.6, 0.95, fm.z));
		float reflConf;
		// (1.17.0: the relief tilts the screen-space ray only partly - the sloped far side of a fresh, still mounded
		// pool seen from above reflected nearly level rays that landed on the lit floor beyond: a flat white half
		// moon over the pool)
		float3 Rr = reflect(-sp.V, normalize(Ng + (sp.N - Ng) * 0.35));
		float3 reflIn;
		// (1.25.1) blood on the mirrored floor (texel (388, 0): its height, on - cl_probes.lua P.MirrorStep): the exact
		// reflection is in the lower half of the atlas, the scene rendered from the camera mirrored under the floor. The
		// reflected ray's point ~60 u out, mirrored under the floor, projected with the camera's own matrix, is where it is
		// in that picture (upside down: v not flipped back) - a flat pool reads its own pixel, ripples and rims bend it.
		// Rough and gelled blood keeps the blurred probe
		// (the texel read tied to the film shading's result: read up front, it was kept alive through the whole film shading
		// and the shader ran out of temp registers)
		float4 mh = ghmpb_pt(max(388.0, -sp.Fr.x), 0.0);
		float mz = ghmpb_u16(mh.x, mh.y) * (32768.0 / 65535.0) - 16384.0;
		float wM = (mh.z > 0.5 && Ng.z > 0.985 && abs(P.z - mz) < 2.5) ? 1.0 - smoothstep(0.07, 0.22, roughR) : 0.0;
		[branch] if (wM > 0.01)
		{
			float4 Qm = float4(P + float3(Rr.x, Rr.y, -Rr.z) * 60.0, 1.0);
			float4 cm = float4(dot(Qm, i.vp0), dot(Qm, i.vp1), dot(Qm, i.vp2), dot(Qm, i.vp3));
			// (+ half a texel of the 1024 x 512 picture: D3D9 pixel centres, as the screen-space reflection's half pixel)
			float2 m = clamp(cm.xy / max(cm.w, 1.0) * 0.5 + 0.5 + float2(0.5 / 1024.0, 0.5 / 512.0), float2(0.0006, 0.0011), float2(0.9994, 0.9989));
			reflIn = ghmpb_reflBoost(ghmpb_toLinear(tex2Dlod(ProbeT, float4(m.x, 0.5 + 0.5 * m.y, 0, 0)).rgb));
			reflConf = wM;
		}
		else
		{
			reflIn = ssr(i, P, Rr, roughR, reflConf);
			// Without a depth buffer the samples cannot tell whether they hit anything: a ray going up (seen from
			// above, the reflection of the sky or a ceiling) lands on screen on whatever lies beyond the pool - the
			// floor - so only near-grazing reflections (bodies, walls and props standing around the pool) are taken
			// from the screen; steeper ones come from the cubemap
			reflConf *= saturate(1.0 - 1.8 * dot(Rr, Ng));
			// (1.25.0) with a rendered reflection probe the scene round the pool is in the probe: the screen is only mixed in a
			// little (its grazing rays land on the floor beyond the pool - it looked as if the pool were see-through)
			reflConf *= ghmpb_pt(385.0, 0.0).w > 0.5 ? 0.35 : 1.0;
		}
		sp.col += sp.Fr * (reflIn - sp.env) * reflConf;
		// (1.19.0, pool look: light that went through the blood to the floor and back was scattered on the way - under wet
		// blood the floor is seen blurred, towards its average colour (E * albedo is the blurred framebuffer), so its texture
		// does not print through the pool. Mixed into the framebuffer colour handed over: worked out inside, the decode ran
		// the shader out of temp registers)
		// (1.25.0: all of it under thick blood - with the opaque layers of ghmpb_filmDiffuse a pool shows nothing of the floor)
		float hideK = smoothstep(0.02, 0.3, h);
		col = ghmpb_filmDiffuse(lerp(fb, E * albedo, hideK), E, f, q, sp, SC18.w, 1.0);
		// boiling / acid foam on the wet blood (1.17.0; here, after the film shading, which is at the ps_3_0 register
		// limit on world patches): bubbles swelling and bursting, brownish froth (yellow-green with acid)
#if !GHMPB_STATIC
		// (the element fields decoded here, tied to the shaded colour - see ghmpb_frostAt in ghmpb_shade.h)
		float w3c = max(SC3.w, -col.g);
		float bubA = max(ghmpb_boilAt(w3c), ghmpb_fizzAt(w3c)) * smoothstep(0.02, 0.15, h) * (1.0 - ghmpb_frostAt(w3c));
		[branch] if (bubA > 0.01)
		{
			float fz = step(ghmpb_boilAt(w3c), ghmpb_fizzAt(w3c));
			float2 bg;
			float bh = ghmpb_bubble(f.crackPos * lerp(0.4, 0.7, fz), SC0.w * lerp(1.1, 2.6, fz), bg);
			// (froth lit like the surface; a bright rim where the light catches the dome, from its slope)
			// (the light on it: the framebuffer over the surface's brightness - a scalar: a colour kept alive for this ran the
			// shader out of temp registers)
			float3 Eb = fb / max(ghmpb_luma(albedo), 0.03);
			float rim = saturate(0.5 + 0.5 * dot(normalize(bg + 1e-4), float2(0.6, -0.8))) * saturate(length(bg) * 0.4);
			col = lerp(col, Eb * lerp(float3(0.30, 0.22, 0.11), float3(0.40, 0.42, 0.13), fz) * (0.8 + 0.8 * rim), saturate(bh * bubA * 0.7));
		}
		// (1.26.9d) big bubbles on a fresh pool fed with frothy blood (the froth the simulation carries from where the wound
		// bleeds into it): a few cm across, a darker middle, a lighter red wall round it and a small sharp glint where the
		// light catches the dome (a wide grey glint read as a pale dot); each swells, sits and bursts within a few seconds
		// and another comes up. Gone once the blood gels
		float bigD = saturate(f.froth * 4.0) * smoothstep(0.15, 0.55, h) * (1.0 - smoothstep(0.4, 0.8, fm.z));
		[branch] if (bigD > 0.03)
		{
			float2 bbg;
			float rimB;
			float bb = ghmpb_bigBubble(f.crackPos * 0.12 + 11.7, SC0.w, 0.85 * bigD, bbg, rimB);
			float gl = saturate(dot(normalize(bbg + 1e-4), float2(0.6, -0.8))) * saturate(length(bbg) * 0.25) * bb;
			float3 Eb2 = fb / max(ghmpb_luma(albedo), 0.03);
			col = col * (1.0 - 0.35 * bb + 1.7 * rimB) + Eb2 * float3(0.55, 0.42, 0.40) * pow(gl, 7.0);
		}
#endif
		col = lerp(fb, col, saturate(alive));
	}
	// (1.26.9c) the serum that ran out past the clot: the floor shows through it, a little darker (wet) and tinted a watery
	// straw-pink
	if (serHalo > 0.001) col = lerp(col, fb * float3(0.70, 0.52, 0.40), serHalo * (1.0 - saturate(alive)));
	if (haloW > 0.001)
	{
		float haloType = ghmpb_mat(1.0, 0.4).w;
		float3 tint = haloType > 1.5 ? float3(0.96, 0.84, 0.68) : (haloType > 0.5 ? float3(1.0, 0.5, 0.55) : float3(0.72, 0.70, 0.68));
		col = lerp(col, fb * tint, haloW);
	}
	return float4(ghmpb_toSRGB(col), 1.0);
}
