// =====================================================================================
// GHM PhysBlood: blood on your screen (1.26.10, cl_screen.lua) - the liquid on the camera's lens.
// GHM: "make an optional blood on screen with physics ... thicker and non see through if alot of blood hits the player
// view" - drawn in two passes with clip_vs30 (positions in clip space, payloads in TEXCOORD0-2):
//   mode 0, the film (c0.w = 0): every drop, splat and streak adds its thickness profile to a half-size RGBA16F target
//     (additive): rgb = its absorbance (-ln of what it lets through, / 8), a = its wet height (what makes it a liquid:
//     its shape bends and reflects light; dried blood keeps its colour but is flat and dull). The profile is worked out
//     here, so the drops are sharp at any size and need no textures: a drop is a liquid cap on the glass (its height
//     falls off like a sphere's), its outline a little uneven; a splat is a lobed, lumpy blob.
//       t0 = (x, y in -1..1 over the quad, seed, kind: 0 drop, 1 splat, 2 streak)
//       t1 = (absorbance r, g, b / 8 at its thickest, wet height at its thickest)
//       t2 = (how uneven its outline is, profile exponent, a drop: teardrop taper 0..0.85 / a streak: its length over its
//             width, -)
//   mode 1, on the screen (c0.w = 1): one full-screen pass over the frame. Where there is blood, what is behind it is
//     seen through it (Beer-Lambert: exp(-absorbance) for each colour - a thin smear tints the view, a thick layer of it
//     is opaque), bent by its surface (refraction) and blurred by it, the steep edges of the drops dark (the light there
//     is bent away from the eye), plus what the blood itself sends back of the light where you stand (its colour from
//     its own absorption: red blood a deep red, alien blood its own colour) and, while wet, highlights and a Fresnel
//     reflection of the light from above.
//       s0 = the film, s1 = _rt_FullFrameFB (read in gamma)
//       c0 = (1 / film width, 1 / film height, -, mode)
//       c1 = (absorbance scale, refraction (share of the screen), how much light the blood sends back, height -> slope)
//       c2 = (the light where you stand: r, g, b (linear, frame units), highlight sharpness)
//       c3 = (highlight strength, reflected light r, g, b)
//   mode 2, the blood runs (c0.w = 2): GHM: "the screen blood needs to use the nvidia blood physics shader" - NVIDIA's HLSL
//     Blood Shader (SDK 9.5, Kevin Myers, "Gravity Maps", 2004): the fluid's amount lives in a texture and runs across it on
//     the GPU, texel by texel, the way gravity and the surface's own normals send it; each step a texel gives the share its
//     direction says it loses and takes in what its four neighbours send its way, the direction cubed to make it viscous,
//     and only blood above a minimum height moves. Here the surface is the lens: gravity points down the screen and a fixed
//     noise stands in for its unevenness (the blood meanders into rivulets instead of sliding in straight bars). Unlike the
//     original, only what stands above the minimum height runs on (a running drop leaves a thin trail and slows as it
//     shrinks), most of the blood's colour (rgb, its absorbance) runs with it, and the wet height dries away, after which the dried
//     stain fades. Ping-pong between two half-size RGBA16F targets, about 60 steps a second.
//       s0 = the blood now; c0 = (1 / width, 1 / height, -, 2)
//       c1 = (seconds per step, minimum height that runs, speed, how much the lens' unevenness steers it)
//       c2 = (drying of the wet height per second, fading of dried blood per second, height that still counts as wet, share
//             of the colour left behind where blood runs off)
//       c3 = (gravity on the screen x, y, -, -)
// =====================================================================================
#include "ghmpb_common.h"

sampler Film : register(s0);
sampler FB   : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT {
	float4 t0 : TEXCOORD0;
	float4 t1 : TEXCOORD1;
	float4 t2 : TEXCOORD2;
};

float4 filmPass(PS_INPUT i)
{
	float2 p = i.t0.xy;
	float seed = i.t0.z;
	float kind = i.t0.w;
	float s = seed * 6.2832;
	float z = i.t2.z;
	float splat = (kind > 0.5 && kind < 1.5) ? 1.0 : 0.0;
	float streak = kind > 1.5 ? 1.0 : 0.0;
	float h;
	if (streak > 0.5)
	{
		// a streak: a capsule as long as it is stretched (x along it), a little wavy, thinner towards its top end (x < 0)
		float qx = p.x * z;
		float py = p.y + 0.25 * sin(qx * 0.3 + s) * saturate(z - 1.0);
		float dx = max(abs(qx) - max(z - 1.0, 0.0), 0.0);
		float rr = length(float2(dx, py));
		clip(1.0 - rr);
		h = pow(saturate(1.0 - rr * rr), i.t2.y) * lerp(0.55, 1.0, saturate(p.x * 0.5 + 0.5));
	}
	else
	{
		// a drop drawn out by its flight: a teardrop, its tail (x < 0, where it came from) narrower and thinner
		float wf = 1.0 - z * 0.75 * saturate(0.5 - p.x * 0.5);
		float2 q = float2(p.x, p.y / max(wf, 0.1));
		float r = length(q);
		clip(1.0 - r);
		float th = atan2(q.y, q.x);
		// an uneven outline: a few low harmonics; a splat: lobes, a ragged edge and a few notches
		float wob = 0.5 * sin(3.0 * th + s) + 0.3 * sin(5.0 * th + s * 2.7) + 0.2 * sin(8.0 * th + s * 5.3);
		[flatten] if (splat > 0.5)
		{
			wob += 0.6 * sin(2.0 * th + s * 1.9) + 0.35 * sin(7.0 * th + s * 3.1);
			wob += 0.25 * sin(13.0 * th + s * 7.7) + 0.15 * sin(21.0 * th + s * 11.3) - 1.4 * pow(saturate(sin(5.0 * th + s * 4.1)), 12.0);
		}
		float rr = r * (1.0 + i.t2.x * wob) / 0.8;
		h = pow(saturate(1.0 - rr * rr), i.t2.y);
		// a splat is lumpy: thicker and thinner patches inside it
		h *= lerp(1.0, 0.7 + 0.6 * ghmpb_vnoise(p * 2.6 + seed * 31.0), splat);
		h *= 1.0 - z * 0.6 * saturate(0.5 - p.x * 0.5);
	}
	clip(h - 1e-3);
	return float4(i.t1.rgb * h, i.t1.a * h);
}

float4 screenPass(PS_INPUT i)
{
	float2 uv = i.t0.xy;
	float2 tx = C0.xy;
	float4 f = tex2Dlod(Film, float4(uv, 0, 0));
	float3 A = f.rgb * (8.0 * C1.x);
	clip(max(max(A.r, A.g), max(A.b, f.a * 50.0)) - 0.004);
	float hL = tex2Dlod(Film, float4(uv - float2(tx.x, 0), 0, 0)).a, hR = tex2Dlod(Film, float4(uv + float2(tx.x, 0), 0, 0)).a;
	float hU = tex2Dlod(Film, float4(uv - float2(0, tx.y), 0, 0)).a, hD = tex2Dlod(Film, float4(uv + float2(0, tx.y), 0, 0)).a;
	float2 slope = float2(hR - hL, hD - hU) * (0.5 * C1.w);
	float3 n = normalize(float3(-slope, 1.0));
	float steep = saturate(length(slope));
	// what is behind it: bent by the surface, and thrown out of focus by the film on the lens. Blood that close to the eye
	// pulls the focus onto itself, so the world behind it goes soft - a round defocus (a disc of taps, like a camera's
	// aperture) that widens where the blood is thick and stays tight at the thin edges. C0.z sets how soft (screen share).
	float2 ruv = uv + n.xy * C1.y;
	float aL = dot(A, float3(0.4, 0.4, 0.2));
	float cov = saturate(aL * 1.6);
	float fr = C0.z * (0.3 + 1.1 * cov);
	float2 ir = float2(fr * 0.6, fr * 0.6 * 0.78), orr = float2(fr, fr * 0.78);
	float3 sc = ghmpb_toLinear(tex2Dlod(FB, float4(ruv, 0, 0)).rgb) * 0.22;
	[unroll] for (int bi = 0; bi < 6; bi++)
	{
		float a1 = 1.0471975512 * bi, a2 = a1 + 0.5235987756;
		sc += ghmpb_toLinear(tex2Dlod(FB, float4(ruv + float2(cos(a1) * ir.x, sin(a1) * ir.y), 0, 0)).rgb) * 0.08;
		sc += ghmpb_toLinear(tex2Dlod(FB, float4(ruv + float2(cos(a2) * orr.x, sin(a2) * orr.y), 0, 0)).rgb) * 0.05;
	}
	float3 T = exp(-A);
	float3 col = sc * T * (1.0 - 0.75 * steep * smoothstep(0.0, 0.02, f.a));
	// the blood's own colour: what a layer of it sends back (Kubelka-Munk, R-infinity from the ratio of its absorption in
	// each colour to the least absorbed one), as much as it is not see-through
	float Amin = min(A.r, min(A.g, A.b));
	float3 Rinf = C1.z * pow((Amin + 0.02) / (A + 0.02), 1.6);
	col += C2.rgb * Rinf * (1.0 - T);
	// wet: highlights (a soft light from above and to the left) and the Fresnel reflection of the light from above
	float wet = smoothstep(0.0, 0.015, f.a);
	float3 L = normalize(float3(-0.35, -0.6, 0.72));
	float3 H = normalize(L + float3(0, 0, 1));
	// (sharp only: a broad lobe laid a pale veil over every flat film)
	float spec = pow(saturate(dot(n, H)), C2.w);
	float fres = 0.027 + 0.973 * pow(saturate(1.0 - n.z), 5.0);
	float3 refl = C3.yzw * (0.55 + 0.45 * saturate(-n.y * 3.0)) * fres;
	col += (spec * C3.x + refl) * wet;
	return float4(ghmpb_toSRGB(col), 1.0);
}

// one texel of the running blood (mode 2): what share of it leaves this step (f) and how that share is split between its
// right, left, lower and upper neighbours (w)
void runOf(float2 uv, float4 s, out float f, out float4 w)
{
	float h = s.a;
	f = min(max(h - C1.y, 0.0) * C1.z * C1.x / max(h, 1e-3), 0.85);
	// the lens' unevenness: a fixed noise of cells some 8 texels across
	float2 q = uv / C0.xy;
	float2 n = float2(ghmpb_vnoise(q * 0.12), ghmpb_vnoise(q * 0.12 + 17.3)) - 0.5;
	float2 d = clamp(C3.xy + n * C1.w, -1.0, 1.0);
	d = d * d * d;
	w = float4(max(d.x, 0.0), max(-d.x, 0.0), max(d.y, 0.0), max(-d.y, 0.0));
	w /= max(w.x + w.y + w.z + w.w, 1e-4);
}

float4 fetchRun(float2 uv)
{
	// nothing comes in from outside the screen
	float inside = (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) ? 1.0 : 0.0;
	return tex2Dlod(Film, float4(uv, 0, 0)) * inside;
}

float4 runPass(PS_INPUT i)
{
	float2 uv = i.t0.xy;
	float2 tx = float2(C0.x, 0.0), ty = float2(0.0, C0.y);
	float f, fn;
	float4 w, wn;
	// (part of the colour stays behind where blood ran off: the glass is stained, a run leaves a red trail)
	float4 m = float4(1.0 - C2.www, 1.0);
	float4 s = fetchRun(uv);
	runOf(uv, s, f, w);
	float4 o = s * (1.0 - f * m);
	float4 g = 0;
	float4 sn = fetchRun(uv - tx);
	runOf(uv - tx, sn, fn, wn);
	g += sn * (fn * wn.x);                 // the left neighbour's share going right
	sn = fetchRun(uv + tx);
	runOf(uv + tx, sn, fn, wn);
	g += sn * (fn * wn.y);                 // the right neighbour's going left
	sn = fetchRun(uv - ty);
	runOf(uv - ty, sn, fn, wn);
	g += sn * (fn * wn.z);                 // the one above, going down
	sn = fetchRun(uv + ty);
	runOf(uv + ty, sn, fn, wn);
	g += sn * (fn * wn.w);                 // the one below, going up
	o += g * m;
	// drying: the wet height goes; the stain fades a little all the time, faster once it is dry
	o.a *= saturate(1.0 - C2.x * C1.x);
	o.rgb *= saturate(1.0 - C2.y * C1.x * (0.15 + 0.85 * (1.0 - saturate(o.a / C2.z))));
	return o;
}

float4 main(PS_INPUT i) : COLOR
{
	[branch] if (C0.w > 1.5) return runPass(i);
	[branch] if (C0.w > 0.5) return screenPass(i);
	return filmPass(i);
}
