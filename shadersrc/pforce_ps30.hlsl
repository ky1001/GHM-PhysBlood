// GHM PhysBlood: static field of a world surface patch for the height-field solver (sim_ps30, c13.x = 1).
// The patch is a square on the hit plane; the bed map (s0) holds the real surface under it at 0.31 u:
// x = height along the patch normal (u), y = surface present (1) / blocked by a wall standing on the plane
// (0.35) / open void (0), zw = its normal along the patch U, V axes.
// Real floors and walls are never flat: a gentle, world-continuous micro relief (a few mm over tens of cm,
// ghmpb_floor_unevenness) is added to the bed, so pools drift into shallow dips and grow irregular lobes.
//   t0 = patch uv, t1 = world position on the plane, t2 = plane normal
//   c0 = (gravity cm/s^2 xyz, micro relief amplitude scale)   c1 = (1 / bed resolution, texel size cm, surface texture
//   coordinate at the patch's corner u, v)   c2 = (global texel offset of the patch x, y, patch resolution, the surface's
//   normal map: kind (0 none, 1 normal map, 2 ssbump) + 0.99 * strength)   c3 = d (surface texture coordinate) / d (patch
//   uv): (du/du, du/dv, dv/du, dv/dv)   s1 = the surface's normal map (1.21.0)
// out = (bed height cm, curvature: + concave (joint bottoms, inside corners) / - convex (edges, ridges),
//        surface pin noise (the contact-line pinning multiplier of the texel, see pinNoise in ghmpb_sim_main.h - baked
//        here once instead of being evaluated for 9 texels every step), texel size cm)
//       open void: 0     blocked (a wall's foot): (0, 0, 0, -1)
#include "ghmpb_common.h"
sampler Bed : register(s0);
sampler SurfBump : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);
// value noise of (x) rotated by a, at scale sc, offset o (the constants fold at compile time)
float ghmpb_vr(float2 x, float sc, float a, float o)
{
	float c = cos(a), s = sin(a);
	return ghmpb_vnoise(float2(c * x.x - s * x.y, s * x.x + c * x.y) / sc + float2(o, o * 1.7));
}
struct PS_INPUT { float4 t0 : TEXCOORD0; float4 t1 : TEXCOORD1; float4 t2 : TEXCOORD2; };
float4 main(PS_INPUT i) : COLOR
{
	float3 N0 = normalize(i.t2.xyz);
	float2 uv = i.t0.xy;
	// the mask is read at the bed texel's centre (the bilinear blend of surface and void would fake a thin wall
	// along every ledge); inside the surface the height stays smoothly interpolated
	float2 tc = (floor(uv / C1.x) + 0.5) * C1.x;
	float4 bp = tex2Dlod(Bed, float4(tc, 0, 0));
	float4 bb = tex2Dlod(Bed, float4(uv, 0, 0));
	float4 bed = (bb.y > 0.999) ? bb : bp;
	// in-plane coordinates from the patch axes (shared by all patches of a plane -> continuous across borders)
	float3 Tn = normalize(ddx(i.t1.xyz) + 1e-7), Bn = normalize(ddy(i.t1.xyz) + 1e-7);
	float2 q = float2(dot(i.t1.xyz, Tn), dot(i.t1.xyz, Bn));
	float micro = 0.22 * C0.w * (0.6 * ghmpb_vnoise(q / 34.0) + 0.3 * ghmpb_vnoise(q / 13.0 + 7.3) + 0.1 * ghmpb_vnoise(q / 5.0 + 3.1));
	// (1.26.1-pools) floors: a pool on a real floor (worn concrete, old boards, a tiled floor that has settled) does not
	// spread as a round disc - it is a small lake on the floor's topography: it fills the shallow dips first and pushes
	// out lobes and bays along them, runs a short tongue down a worn groove and leaves dry islands where the floor is a
	// hair higher (the pools of TLOU2's floors). Domain-warped dips at three scales (~25, 10, 5 cm), a few constant-width
	// worn grooves (a gated contour of a second noise: |n - 0.5| / |grad n| is the distance to the contour) and shallow
	// pits, a few mm in all, scaled by ghmpb_floor_unevenness. Walls and slopes keep the gentle relief above.
	float2 qw = q + 8.0 * float2(ghmpb_vr(q, 9.0, 0.3, 3.7), ghmpb_vr(q, 9.0, 1.1, 8.1)) - 4.0;
	float rl = 0.55 * ghmpb_vr(qw, 14.0, 0.5, 13.1) + 0.35 * ghmpb_vr(qw, 5.5, 1.3, 26.2) + 0.10 * ghmpb_vr(qw, 2.4, 2.1, 39.3);
	float n1 = ghmpb_vr(qw, 6.0, 0.8, 11.0);
	float2 gn = float2(ddx(n1) / max(length(ddx(i.t1.xyz)), 1e-4), ddy(n1) / max(length(ddy(i.t1.xyz)), 1e-4));
	float groove = (1.0 - smoothstep(0.36, 0.9, abs(n1 - 0.5) / max(length(gn), 0.02))) * smoothstep(0.42, 0.48, ghmpb_vr(q, 14.0, 2.4, 9.0));
	float relief = C0.w * (0.3 * (rl - 0.5) - 0.12 * groove - 0.05 * smoothstep(0.66, 0.84, ghmpb_vr(q, 2.8, 0.7, 51.0)));
	// (1.26.9c) floors are never quite level, and not the same everywhere: a world-continuous large-scale fall, as long,
	// shallow troughs (~2 m long, ~0.5 m across, up to ~5 mm deep) stretched along a direction that turns slowly over the
	// map, and only in some areas (elsewhere the floor is level). A pool that has enough blood creeps along its trough and
	// stretches into a long tongue that runs one way, splits round the high spots of the micro relief above and joins again
	// below them; a small pool or one on a level stretch stays a round lake on the micro relief - it does not depend on the
	// flow at all (the flow only wins where the volume, the fall and the surface's pinning let it)
	float ang = 3.14159 * ghmpb_vnoise(q / 260.0 + 5.7);
	float2 ad = float2(cos(ang), sin(ang));
	float2 qa = float2(dot(q, ad) / 105.0, dot(q, float2(-ad.y, ad.x)) / 28.0);
	float trough = 0.7 * ghmpb_vnoise(qa + 2.1) + 0.3 * ghmpb_vnoise(qa * 2.3 + 9.4);
	float fallAmt = smoothstep(0.32, 0.78, ghmpb_vnoise(q / 170.0 + 21.3));
	relief += C0.w * 0.55 * fallAmt * (trough - 0.5);
	// (1.26.9c) a stream that runs along a trough does not stay one sheet: small raised spots stretched along the fall (a
	// worn floor's high grain, a slightly proud tile edge, ~10 cm long, ~3 cm across, ~2-3 mm high) stand in its way, so
	// the stream splits round them and joins again behind them (braiding), and a thin tongue picks one side
	float isl = smoothstep(0.66, 0.80, ghmpb_vnoise(qa * float2(5.0, 3.2) + 4.2)) * (1.0 - smoothstep(0.45, 0.65, trough));
	relief += C0.w * 0.16 * fallAmt * isl;
	// curvature of the real surface one bed texel around (u): joints, grooves and inside corners are concave
	float e = C1.x;
	float bl = tex2Dlod(Bed, float4(uv - float2(e, 0), 0, 0)).x;
	float br = tex2Dlod(Bed, float4(uv + float2(e, 0), 0, 0)).x;
	float bu = tex2Dlod(Bed, float4(uv - float2(0, e), 0, 0)).x;
	float bd = tex2Dlod(Bed, float4(uv + float2(0, e), 0, 0)).x;
	float lap = (bl + br + bu + bd) * 0.25 - bed.x;
	float curv = clamp(lap / 0.2, -1.0, 1.0);
	// the foot of a wall is an inside corner too: the meniscus wicks blood along it
	float4 mk = float4(tex2Dlod(Bed, float4(tc - float2(e, 0), 0, 0)).y, tex2Dlod(Bed, float4(tc + float2(e, 0), 0, 0)).y,
	                   tex2Dlod(Bed, float4(tc - float2(0, e), 0, 0)).y, tex2Dlod(Bed, float4(tc + float2(0, e), 0, 0)).y);
	float4 wallN = step(0.2, mk) * step(mk, 0.5);
	if (dot(wallN, 1.0) > 0.5) curv = max(curv, 0.5);
	// (1.21.0) the surface's normal map: its grooves (grout, cracks, the joints between planks and bricks) are concave -
	// thin blood creeps along them and they hold it - and rough, strongly modelled relief pins the edge of the blood. The
	// height field's curvature is the divergence of its slope, -(n.xy / n.z), taken in the patch's texel axes: the normal
	// map's +u / +v axes are carried into patch uv through the inverse of d (texture coordinate) / d (patch uv)
	float bk = floor(C2.w + 1e-3);
	float bStr = (C2.w - bk) / 0.99;
	float2 buv = C1.zw + float2(dot(C3.xy, uv), dot(C3.zw, uv));
	float3 nm = tex2D(SurfBump, buv).xyz;
	float3 nt = normalize(bk > 1.5
		? nm.x * float3(0.81650, 0.0, 0.57735) + nm.y * float3(-0.40825, 0.70711, 0.57735) + nm.z * float3(-0.40825, -0.70711, 0.57735)
		: nm * 2.0 - 1.0);
	float sdet = (C3.x * C3.w - C3.y * C3.z) < 0.0 ? -1.0 : 1.0;
	float2 c1v = float2(C3.w, -C3.z) * sdet, c2v = float2(-C3.y, C3.x) * sdet;
	float2 tilt = nt.x * c1v / max(length(c1v), 1e-6) + nt.y * c2v / max(length(c2v), 1e-6);
	float2 slp = -tilt / max(nt.z, 0.25);
	float conc = -(ddx(slp.x) + ddy(slp.y));
	if (bk > 0.5) curv = clamp(curv + bStr * 1.2 * conc, -1.0, 1.0);
	// static per-texel surface heterogeneity (dust, micro roughness, porosity) in global texel coordinates (continuous
	// across patch borders): broad lobes (~10 texels) with a little fine grain -> irregular but rounded outlines
	float2 p = floor(uv * C2.z) + 0.5 + C2.xy;
	float n = 0.65 * ghmpb_vnoise(p * 0.09) + 0.25 * ghmpb_vnoise(p * 0.27 + 17.0) + 0.1 * ghmpb_vnoise(p * 0.8 + 41.0);
	float pin = lerp(0.6, 1.75, n * n * (3.0 - 2.0 * n));
	// (1.26.1-pools) floors: broad lobes only, no fine grain - the outline follows the relief above in clean, rounded
	// curves (world-space, ~5 and ~2 cm: the same at every quality)
	float nf = 0.75 * ghmpb_vnoise(q * 0.384) + 0.25 * ghmpb_vnoise(q * 0.96 + 17.0);
	float3 gw = C0.xyz;
	float2 gt = float2(dot(gw, Tn), dot(gw, Bn));
	float sl = length(gt) / max(length(gw), 1e-3);
	float flo = 1.0 - smoothstep(0.12, 0.35, sl);
	pin = lerp(pin, 0.75 + 0.6 * nf * nf * (3.0 - 2.0 * nf), flo);
	// (1.26.9c) floors do not hold blood the same everywhere (contact-angle hysteresis: a pool only creeps once its weight
	// along the fall beats the surface's grip on its edge, so a small pool never moves and a big one may): world-continuous
	// areas (~1-2 m) of dusty, porous or rough floor grip the edge up to 1.7 x harder - pools there stay round where they
	// landed, whatever the fall - and smooth, worn areas grip it a little less. Along a trough's bottom the floor is worn
	// smoother (the edge runs on along it) and on its shoulders a little rougher (the stream stays narrow)
	float grip = ghmpb_vnoise(q / 120.0 + 33.3);
	float gripMul = lerp(0.85, 1.7, smoothstep(0.45, 0.85, grip));
	float chan = fallAmt * (0.5 - trough);
	pin = lerp(pin, pin * gripMul * clamp(1.0 - 0.9 * chan, 0.7, 1.35), flo);
	micro = lerp(micro, relief, flo);
	if (bk > 0.5) pin *= 1.0 + 0.5 * bStr * saturate(length(tilt) * 2.0);
	// (1.19.0) slopes: lanes down the slope - a few texels wide, wandering slowly as they run down it - where the surface holds
	// the blood a little less or a little more, so a pool running down a slope pushes out uneven tongues and fingers that
	// squiggle down instead of a straight-edged sheet. Fades in from ~2 deg, out again on steep walls (runs take over there)
	float laneW = smoothstep(0.03, 0.12, sl) * (1.0 - smoothstep(0.6, 0.85, sl));
	[branch] if (laneW > 0.0)
	{
		float2 dd = gt / max(length(gt), 1e-4);
		float across = dot(p, float2(-dd.y, dd.x)), along = dot(p, dd);
		float ln = 0.75 * ghmpb_vnoise(float2(across * 0.22, along * 0.035)) + 0.25 * ghmpb_vnoise(float2(across * 0.5 + 5.1, along * 0.07 + 1.7));
		pin *= lerp(1.0, lerp(0.55, 1.7, ln * ln * (3.0 - 2.0 * ln)), laneW);
	}
	if (bed.y > 0.5) return float4((bed.x + micro) * GHMPB_UNITS_TO_CM, curv, pin, C1.y);
	return (bed.y > 0.2) ? float4(0, 0, 0, -1) : float4(0, 0, 0, 0);
}
