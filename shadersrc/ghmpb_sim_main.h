// =====================================================================================
// GHM PhysBlood: one step of the 2D cell simulation (patent 10,685,152 style per-texel fluid:
// roll-off / roll-in with the 8 neighbours, lift-off and evaporation), upgraded with thin-film
// lubrication physics from the NextGen UE solver:
//   film velocity  u = rho h^2 / (3 mu) * (tangential accel + pressing accel * grad h)
//   contact-line pinning (dry texels only wet when  h*|G|/g > pin), retained film behind moving blood,
//   impact momentum that decays with viscous drag, lift-off where the surface pulls the blood away,
//   run-off into void texels (UV seams, open patch borders), drying + absorption into stain,
//   COAGULATION: every texel carries its clotted volume; clotting is autocatalytic (thrombin burst:
//   slow start, then fast gelation), clotted blood is far more viscous and pins harder, so flows slow
//   down and freeze, then dry into a crust.
// World patches exchange blood with their neighbours through ghost cells (s4..s7 = the neighbouring
// patches' states of the same step), so pools and runs cross patch borders without cut-offs.
// Every edge transfer is evaluated identically (antisymmetrically) by both texels of the edge, so the
// gather scheme conserves blood volume exactly (verified against tests/sim_proto.py).
//
// SURFACE TENSION at the contact line: a dry texel is harder to wet when few of its neighbours are wet (a
// convex tip would grow) and easier when many are (a notch fills), i.e. the front moves with its curvature
// like a real meniscus, so outlines stay rounded instead of growing grid-scale spikes. The wet-neighbour
// count of every texel is kept in aux.y from the previous step, so both texels of an edge see the same values.
// RUNS ON WALLS: whether a drop starts to run is decided by the weight of the whole drop, not by the height of
// its front texel: every texel carries the "column weight" of the connected blood above it along the slope
// (aux.z = h + 0.85 * column weight of the upslope neighbour, from the previous step), and the contact-line
// test of the front uses it. Big splats and gathered blood run, fine mist stays. On steep surfaces the pinning
// and the retained film do not grow with ghmpb_thickness (that setting is about how deep pools stand on the
// floor), and a dry texel diagonally below a run is harder to wet than the one straight below, so runs
// stay narrow rivulets with a bulging head instead of fanning out.
// WORLD PATCHES (c13.x = 1) run on a height field: s1 holds the real surface under the patch (bed height cm,
// curvature, gravity into the plane, texel size) and the driving acceleration across an edge is the plane's
// own gravity along it plus the hydrostatic head of (bed + blood): blood runs into mortar joints, grooves,
// cracks and dips first, fills them and only then spreads over the top. A contact line holds at a convex edge
// until enough blood has gathered to tip over (Gibbs' inequality), and concave corners / joint bottoms wick
// it along (capillary rise in corners).
// BODIES (c13.x = 2) read the surface curvature of the skin / clothes (s4 = position history, w = 1 + 0.45 *
// concavity): creases, folds and the gaps between limbs catch the runs, ridges shed them.
// s0 state (h, s, mx, my)  s1 force (Ax, Ay, An, L | world: bed cm, curvature, surface pin noise, L - the plane's
//    gravity into it is c13.w)
// s2 accumulator (lift, edge-out, -, oxygenated volume in wet + stain: kept, the readback only clears x / y)
// s3 aux (clot volume, wet nbrs, column weight, volume of the layer's second blood type in wet + stain)
// s4..s7 neighbour patches' ghost-cell exports (h, second-type fraction or void flag, oxygenated fraction, momentum
//        across the border: mx on the left / right border columns, else my): left (u<0), right (u>1), up (v<0), down (v>1)
// WALLS: texels of a world patch where something solid stands on the plane (force w = -1, ghost s = -2) are not
// void but a dam: nothing flows into them unless the plane's gravity runs straight into them (wall -> floor).
// c0 = (1/W, 1/H, dt, neighbour mask L=1 R=2 U=4 D=8, + that side is solid (no patch, a wall) L=16 R=32 U=64 D=128)  c1 = (mu, pin, hret, hdry)
// c2 = (lift, liftk, 1/tau, kabs)  c3 = (capacity, pressPin, drag, wdiag)
// c11 = (clotting rate 1/s, clot viscosity gain, clot pinning gain, clot drying slow-down)
// c12 = (void flag written into s of void texels: -1 world patches / 0 bodies, global texel offset of the
//        patch (x, y) so the surface noise is continuous across patch borders, ghmpb_thickness - 1)
// c13 = (mode 0 old / 1 world height field / 2 body with curvature, plane gravity along U, along V, into the plane)
// COLOUR MIXING: aux.w carries how much of the texel's blood (wet + stain) is the layer's second type; it moves with
// the flowing blood (antisymmetric like the volume, so it is conserved) and diffuses between touching wet texels
// (the liquids mix), so two colours merge smoothly per pixel instead of one replacing the other. Across patch borders
// the neighbours' exports carry their fraction, so blood and colour cross the border like anywhere else.
// OXYGENATION: acc.w carries the oxygenated share of the blood the same way (bright arterial / lung blood, dark
// venous / organ blood); it flows and mixes like the second type, so an arterial spurt stays scarlet where it lands
// and blends into the darker pool around it.
// LEVELLING (world patches): a pool is a liquid - its surface levels out within a second, far faster than a texel
// stencil can move blood at this resolution. Texels of thick, wet blood therefore also exchange with the texels 4,
// 12 and 32 texels away (in the patch, along the axes; every other step along the diagonals; when the blood is
// continuous between them) in proportion to
// the difference of their heads (bed + blood + the plane's slope), which levels a pour into a pool of the thickness
// the contact line holds in a few seconds instead of leaving a tall dome. Antisymmetric, so volume is conserved.
// WATER: c14.yzw place the texel relative to a water surface (lakes, canals, flooded floors): depth below it in units
// (world patches: c14.y + c14.z u + c14.w v from the patch plane; bodies: c14.y - the texel's height from the position
// history). Blood does not stain under water - it mixes in: the contact line hardly holds (the blood spreads thin), wet
// blood washes out over a few seconds (clotted blood much slower) and a dried stain over a minute or two, into the accumulator's lift channel, which the CPU turns
// into a cloud in the water (cl_water.lua). Just above the water line the wet shore lets a pool's edge run out thin.
// MRT: COLOR0 = new state, COLOR1 = new accumulator, COLOR2 = new aux, COLOR3 = new ghost-cell export (world patches)
// =====================================================================================
// Compiled twice: sim_ps30 (world patches, height field) and simbody_ps30 (bodies, GHMPB_SIMBODY = 1), so each
// variant carries only its own paths - a single shader holding both ran past what some drivers accept for ps_3_0.
#ifndef GHMPB_SIMBODY
#define GHMPB_SIMBODY 0
#endif
#define SIM_HF (GHMPB_SIMBODY == 0)
#include "ghmpb_common.h"
sampler State : register(s0);
sampler Force : register(s1);
sampler Acc   : register(s2);
sampler Aux   : register(s3);
sampler NbL   : register(s4);
sampler NbR   : register(s5);
sampler NbU   : register(s6);
sampler NbD   : register(s7);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);
float4 C11 : register(c11);
float4 C12 : register(c12);
float4 C13 : register(c13);
float4 C14 : register(c14);   // (step parity 0 / 1 + 2 x wash-off rate in quarters (ghmpb_water_wash), water depth constants)
#if !GHMPB_SIMBODY
// (1.14.1) world patches: the blood type pair belongs to a region of the plane (4 x 4 patches), so a neighbour across a
// region border may count a different type as its second one. Its exported fraction f is remapped to this patch's pair:
// f' = m0 + m1 f per side - c15 = (left m0, m1, right m0, m1), c16 = (up m0, m1, down m0, m1); (0, 1) = same pair
float4 C15 : register(c15);
float4 C16 : register(c16);
#endif

struct PS_INPUT { float4 t0 : TEXCOORD0; };
struct PS_OUTPUT { float4 state : COLOR0; float4 acc : COLOR1; float4 aux : COLOR2; float4 ex : COLOR3; };

// static per-texel surface heterogeneity (dust, micro roughness, porosity): varies the contact-line pinning
// so fronts finger and pools get natural irregular outlines instead of the grid's octagon
// (world patches bake it into force.z once (pforce_ps30, same formula), bodies evaluate it here)
float pinNoise(float2 uv)
{
	float2 p = uv / C0.xy + C12.yz;
	// broad lobes (~10 texels) with a little fine grain: irregular but rounded outlines
	float n = 0.65 * ghmpb_vnoise(p * 0.09) + 0.25 * ghmpb_vnoise(p * 0.27 + 17.0) + 0.1 * ghmpb_vnoise(p * 0.8 + 41.0);
	// (world patches: a slightly narrower range - the weakest spots of a front decide how thin a levelled pool gets)
	return lerp(SIM_HF ? 0.6 : 0.45, 1.75, n * n * (3.0 - 2.0 * n));
}

// depth of a texel below the water surface (u; < 0 above it, -1e4 without water)
float waterDepth(float2 uvq)
{
#if GHMPB_SIMBODY
	return C14.y - tex2Dlod(NbL, float4(uvq, 0, 0)).z;
#else
	return C14.y + C14.z * uvq.x + C14.w * uvq.y;
#endif
}
// contact-line pinning next to and under water: a wet shore lets the edge run out thin (within ~5 cm above the water
// line), under water the blood mixes instead of beading
float waterPin(float dep) { return lerp(1.0, 0.3, saturate(1.0 + dep / 2.5)) * lerp(1.0, 0.4, saturate(dep / 0.3)); }

#define LEV_H 0.8
bool nbBit(float b) { return fmod(floor(C0.w / b + 0.001), 2.0) > 0.5; }

// volume transfer i -> j (positive) along texel offset d (mm of texel thickness)
// contact-line curvature factor from the number of wet neighbours of the texel being wetted
// (straight front = 3 -> 1, tip = 1 -> 2.5, notch >= 6 -> 0.5)
// (1.19.0: on floors and gentle slopes n also carries the curvature of the front a few texels out and the pull of a pool
// nearby - it can pass 8 there, down to 0.2; steep surfaces and bodies keep the 8-neighbour count, 0.5 at least)
float capF(float n) { return clamp(3.0 / max(n, 0.5), (SIM_HF && dot(C13.yz, C13.yz) <= 40000.0) ? 0.2 : 0.5, 2.5); }

float edgeT(float hi, float hj, float4 fi, float4 fj, float2 vi, float2 vj, float2 d, float w, bool jValid,
            float pinI, float pinJ, float cfI, float cfJ, float nI, float nJ, float wI, float wJ, float kI, float kJ)
{
	float dist = length(d);
	hj = jValid ? hj : 0.0;
	float4 fjx = jValid ? fj : fi;                      // void neighbour borrows our own force
	float L = 0.5 * (fi.w + fjx.w);
	float aAlong, aPress, G;
	const bool hf = SIM_HF;
	if (hf)
	{
		// height field: the plane's gravity along the edge + hydrostatic head of bed + blood (cm) across it
		aAlong = dot(C13.yz, d) / dist;
		aPress = max(0.0, -C13.w);
		G = aAlong + aPress * ((fi.x + 0.1 * hi) - (fjx.x + 0.1 * hj)) / (dist * L);
	}
	else
	{
		aAlong = 0.5 * dot(fi.xy + fjx.xy, d) / dist;
		aPress = 0.5 * (max(0.0, -fi.z) + max(0.0, -fjx.z));
		G = aAlong + aPress * (hi - hj) * 0.1 / (dist * L);
	}
	// contact line: the hydrostatic push on the front, evaluated at a reference texel size of 3 mm (world patches), so
	// the height a pool stands at does not depend on the cell resolution (~2-3 mm for blood on a hard floor)
	float Gpin = hf ? abs(aAlong + (G - aAlong) * L / 0.3) : abs(G);
	float2 vjx = jValid ? vj : float2(0, 0);
	float viA = dot(vi, d) / dist;
	float vjA = dot(vjx, d) / dist;
	bool fwd = (G + 0.5 * (viA + vjA) * L * 10.0) >= 0.0;
	float hd = fwd ? hi : hj;
	float hr = fwd ? hj : hi;
	float cfd = fwd ? cfI : cfJ;                         // the moving (donor) blood's clot state
	float Gd = abs(G);
	float vd = fwd ? max(0.0, viA) : max(0.0, -vjA);
	// the drop's weight along the slope (column weight), not just its front texel, pushes the contact line
	float wd = fwd ? wI : wJ;
	float drive = max(hd, wd) * Gpin / 980.0;
	float press = saturate(aPress / 980.0);
	float Pn = C1.y * (fwd ? pinJ : pinI) * (1.0 + C11.z * cfd * cfd) * (1.0 + C3.y * aPress / 980.0) * capF(fwd ? nJ : nI)
	         * (1.0 + C12.w * press)                        // pools stand deeper with ghmpb_thickness; runs do not
	         // diagonal edges: on walls straight down wins over diagonal (narrow rivulets); on floors the head across a
	         // diagonal is spread over sqrt(2) the distance, so its pinning is scaled by 1/sqrt(2) - otherwise fronts
	         // creep faster along the grid axes and pinned pools come out as octagons / hexagons
	         // (1.19.0b, bodies: 1.3 - runs down skin and clothes spread a little sideways, wider and less even, instead of one
	         // thin streak of the same width all the way down)
	         * ((w < 0.99) ? lerp(GHMPB_SIMBODY ? 1.3 : 1.8, 0.7071, press) : 1.0);
	// surface geometry at the contact line: kI / kJ = concavity of the two texels (+ joint bottom / crease,
	// - edge / ridge)
	float kR = fwd ? kJ : kI;
	if (hf)
	{
		// Gibbs: blood tips over a convex edge (into a joint, off a step) only once enough has gathered
		float drop = fwd ? (fi.x - fjx.x) : (fjx.x - fi.x);
		Pn *= 1.0 + 1.2 * saturate((drop - 0.08) / 0.5);
	}
	else
	{
		Pn *= 1.0 + 0.6 * saturate(-kR);
	}
	// concave corners, joint bottoms and skin creases wet easily and wick blood along them
	Pn *= lerp(1.0, 0.22, saturate(kR));
	bool dry = hr < C1.w;
	float pinf = dry ? saturate((drive - Pn) / Pn) : 1.0;
	float mu = C1.x * (1.0 + C11.y * cfd * cfd * cfd);
	float hc = hd * 0.1;
	float u = (GHMPB_RHO * hc * hc / (3.0 * mu)) * Gd / L;
	u = u * pinf + vd * ((dry && hd < 0.1) ? 0.0 : 1.0) * (1.0 - cfd);
	u = min(u * C0.z, 0.5);
	float hret = C1.z * (1.0 + (sqrt(1.0 + C12.w) - 1.0) * press);
	float avail = max(hd - hret, 0.0);
	// (per edge a donor gives at most 1/8 of its blood; thick world-patch blood 1/10, the rest is the levelling budget)
	float T = min(avail * u * w, avail * ((hf && hd > LEV_H) ? 0.1 : 0.125));
	return fwd ? T : -T;
}

PS_OUTPUT main(PS_INPUT i)
{
	PS_OUTPUT o;
	float2 uv = i.t0.xy;
	float2 px = C0.xy;
	float dt = C0.z;
	float4 si = tex2Dlod(State, float4(uv, 0, 0));
	float4 fi = tex2Dlod(Force, float4(uv, 0, 0));
	float4 ai = tex2Dlod(Acc, float4(uv, 0, 0));
	float4 xi = tex2Dlod(Aux, float4(uv, 0, 0));
	if (fi.w <= 1e-5)
	{
		// void texel (no surface): flagged for the neighbours' ghost reads (-1 open, -2 blocked by a wall)
		o.state = float4(0, fi.w < -0.5 ? C12.x * 2.0 : C12.x, 0, 0);
		o.acc = float4(ai.xyz, 0);
		o.aux = float4(0, 0, 0, 0);
		o.ex = o.state;
		return o;
	}
	// ---------------- idle texel: no wet blood here nor in any of the 8 neighbours. Nothing can move in or out, so
	// the full step would only copy the texel: do that without its cost (most of a patch / body texture is bare).
	// (dried texels are set to exactly 0 wet blood; border texels - ghost cells, open borders - always take the
	// full step)
	{
		// (taps a hair inside the neighbours' centres: the same texels, but not the same fetches as the full step's,
		// which the compiler would otherwise share and hoist in front of the branch)
		float2 pq = px * 0.999;
		float nbH = si.x;
		[unroll] for (int k0 = -1; k0 <= 1; k0++)
		{
			nbH = max(nbH, tex2Dlod(State, float4(uv + float2(k0, -1) * pq, 0, 0)).x);
			nbH = max(nbH, tex2Dlod(State, float4(uv + float2(k0, 1) * pq, 0, 0)).x);
		}
		nbH = max(nbH, tex2Dlod(State, float4(uv + float2(-1, 0) * pq, 0, 0)).x);
		nbH = max(nbH, tex2Dlod(State, float4(uv + float2(1, 0) * pq, 0, 0)).x);
		bool interior = all(uv > px * 1.5) && all(uv < 1.0 - px * 1.5);
		bool washing = si.y > 0.0 && waterDepth(uv) > 0.0;
		[branch] if (interior && nbH <= 0.0 && !washing)
		{
			float S0 = max(si.y, 0.0);
			float aS = clamp(xi.w, 0.0, S0), oS = clamp(ai.w, 0.0, S0);
			o.state = float4(0, si.y, 0, 0);
			o.acc = float4(ai.xyz, oS);
			o.aux = float4(0, 0, 0, aS);
			o.ex = float4(0, S0 > 1e-5 ? aS / S0 : 0.0, S0 > 1e-5 ? oS / S0 : 0.0, 0);
			return o;
		}
	}
	float hi = max(si.x, 0.0);
	float2 vi = hi > 1e-5 ? si.zw / hi : float2(0, 0);
	float clot = clamp(xi.x, 0.0, hi);
	float cfI = hi > 1e-5 ? clot / hi : 0.0;
	float nI = xi.y;
	float wI = xi.z;
	float wetN = 0.0;
	// upslope direction (texel space) for the column weight (world patches: the plane's own gravity)
	const bool hfMode = SIM_HF;
	const bool bodyK = !SIM_HF;
	float2 gt = hfMode ? C13.yz : fi.xy;
	float gl = length(gt);
	float2 gdir = gl > 1e-3 ? gt / gl : float2(0, 0);
	// concavity of this texel (+ joint bottom / crease, - edge / ridge)
	float kI = hfMode ? fi.y : (bodyK ? (tex2Dlod(NbL, float4(uv, 0, 0)).w - 1.0) / 0.45 : 0.0);
	float upBest = 0.5;          // needs a neighbour within ~60 degrees of straight upslope
	float wUp = 0.0;
	// texel on the left / right border column: its export carries mx, else my (see the ghost reads)
	bool colBorder = uv.x < px.x || uv.x > 1.0 - px.x;

	float outSum = 0.0;
	float2 mom = si.zw;
	float edgeOut = 0.0;
	float clotOut = 0.0, clotIn = 0.0;
	// second blood type and oxygenated share: fractions of this texel's blood, transported with the flow and mixed
	// with wet neighbours
	float HI = hi + max(si.y, 0.0);
	float aI = clamp(xi.w, 0.0, HI);
	float fA = HI > 1e-5 ? aI / HI : 0.0;
	float oI = clamp(ai.w, 0.0, HI);
	float fO = HI > 1e-5 ? oI / HI : 0.0;
	float altOut = 0.0, altIn = 0.0, altMix = 0.0;
	float oxOut = 0.0, oxIn = 0.0, oxMix = 0.0;
#if !GHMPB_SIMBODY
	// froth (1.19.0): floors and gentle slopes keep the volume of frothy blood in aux.z (steep surfaces the column weight); it
	// moves with the blood like the type and oxygen shares
	bool frothOn = gl <= 200.0;
	float fF = (frothOn && hi > 1e-5) ? saturate(xi.z / hi) : 0.0;
	float frOut = 0.0, frIn = 0.0;
#endif
	float depI = waterDepth(uv);
#if GHMPB_SIMBODY
	float pinMul = pinNoise(uv) * waterPin(depI);
#else
	float pinMul = fi.z * waterPin(depI);
#endif

	const float2 dirs[8] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1),
	                         float2(1, 1), float2(1, -1), float2(-1, 1), float2(-1, -1) };
	[unroll] for (int k = 0; k < 8; k++)
	{
		float2 d = dirs[k];
		float w = (k < 4) ? 1.0 : C3.w;
		float2 uvj = uv + d * px;
		bool inside = all(uvj > 0.0) && all(uvj < 1.0);
		float4 sj = float4(0, 0, 0, 0);
		float4 fj = fi;
		float cfJ = cfI;
		float fAJ = fA, fOJ = fO;
		float HJ = 0.0;
		float nJ = 3.0, nIe = 3.0;              // neutral curvature on edges across patch borders (no aux there)
		float kJ = kI;
		float wJ = 0.0;
		bool jValid = false;
		bool blockedJ = false;
		float pinIe = pinMul, pinJ = pinMul;
		bool skip = false;
		float2 viE = vi;
		float2 vj = float2(0, 0);
#if !GHMPB_SIMBODY
		float fFJ = 0.0;
#endif
		if (inside)
		{
			sj = tex2Dlod(State, float4(uvj, 0, 0));
			fj = tex2Dlod(Force, float4(uvj, 0, 0));
			float4 xj = tex2Dlod(Aux, float4(uvj, 0, 0));
			float oj = tex2Dlod(Acc, float4(uvj, 0, 0)).w;
			cfJ = sj.x > 1e-5 ? saturate(xj.x / sj.x) : 0.0;
			HJ = max(sj.x, 0.0) + max(sj.y, 0.0);
			fAJ = HJ > 1e-5 ? saturate(xj.w / HJ) : 0.0;
			fOJ = HJ > 1e-5 ? saturate(oj / HJ) : 0.0;
			nJ = xj.y;
			wJ = xj.z;
			nIe = nI;
			jValid = fj.w > 1e-5;
			blockedJ = fj.w < -0.5;
			vj = sj.x > 1e-5 ? sj.zw / sj.x : float2(0, 0);
#if GHMPB_SIMBODY
			float4 pj = tex2Dlod(NbL, float4(uvj, 0, 0));
			kJ = (pj.w - 1.0) / 0.45;
			pinJ = pinNoise(uvj) * waterPin(C14.y - pj.z);
#else
			kJ = fj.y;
			pinJ = jValid ? fj.z * waterPin(waterDepth(uvj)) : pinMul;
			fFJ = (frothOn && sj.x > 1e-5) ? saturate(xj.z / sj.x) : 0.0;
#endif
		}
		else if (k < 4)
		{
#if GHMPB_SIMBODY
			// bodies: the texture border is open (run-off)
			jValid = false;
#else
			// ghost cell from the neighbouring patch (same plane, same resolution, same step)
			// (a neighbour texel without surface is flagged s = -1: blood reaching it runs off as drips)
			if (k == 0 && nbBit(2.0)) { sj = tex2Dlod(NbR, float4(uvj.x - 1.0, uvj.y, 0, 0)); jValid = sj.y > -0.5; }
			if (k == 1 && nbBit(1.0)) { sj = tex2Dlod(NbL, float4(uvj.x + 1.0, uvj.y, 0, 0)); jValid = sj.y > -0.5; }
			if (k == 2 && nbBit(8.0)) { sj = tex2Dlod(NbD, float4(uvj.x, uvj.y - 1.0, 0, 0)); jValid = sj.y > -0.5; }
			if (k == 3 && nbBit(4.0)) { sj = tex2Dlod(NbU, float4(uvj.x, uvj.y + 1.0, 0, 0)); jValid = sj.y > -0.5; }
			blockedJ = sj.y < -1.5;
			// (the export carries the neighbour's second-type and oxygenated fractions; the second-type fraction is
			// remapped to this patch's type pair - see C15 / C16)
			float2 rm = (k == 0) ? C15.zw : ((k == 1) ? C15.xy : ((k == 2) ? C16.zw : C16.xy));
			fAJ = saturate(rm.x + rm.y * saturate(sj.y));
			fOJ = saturate(sj.z);
			// momentum across the border: only its component along the edge matters. The export holds mx on the left /
			// right border columns and my elsewhere; at the patch corners the up / down edges use none on both sides
			// (both texels of such an edge sit in the same column, so both sides agree)
			float hjg = max(sj.x, 0.0);
			float mAlong = hjg > 1e-5 ? sj.w / hjg : 0.0;
			if (k < 2) vj = float2(mAlong, 0);
			else { vj = colBorder ? float2(0, 0) : float2(0, mAlong); viE = colBorder ? float2(0, 0) : vi; }
			// no neighbour patch because that side lies inside solid (C0.w bits 16..128): a wall, not a ledge
			if ((k == 0 && nbBit(32.0)) || (k == 1 && nbBit(16.0)) || (k == 2 && nbBit(128.0)) || (k == 3 && nbBit(64.0))) blockedJ = true;
			if (!jValid) { sj = float4(0, 0, 0, 0); vj = float2(0, 0); }
			// neither side has the other's surface noise: both use the broad lobes at the edge's midpoint (continuous across
			// the border, so the front does not notice it)
			float2 pm = (uv + 0.5 * d * px) / C0.xy + C12.yz;
			float nm = ghmpb_vnoise(pm * 0.09);
			pinIe = lerp(0.6, 1.75, nm * nm * (3.0 - 2.0 * nm)) * waterPin(waterDepth(uv + 0.5 * d * px));
			pinJ = pinIe;
#endif
		}
		else
		{
			// diagonal edges that cross a patch border are not used by either patch (keeps the exchange symmetric)
			skip = true;
		}
		// a wall standing on the plane (the foot of a wall, a riser going up) holds the blood like a dam - unless the
		// blood runs down into it (a run on a wall reaching the floor): then it leaves this patch onto that surface
		if (blockedJ && !(hfMode && dot(C13.yz, normalize(d)) > 300.0)) skip = true;
		if (!skip)
		{
			float hj = max(sj.x, 0.0);
			wJ = (inside && jValid) ? wJ : hj;
			// (across a patch border neither side has the other's aux: both use plain heights, so the edge stays
			// symmetric and conserves blood)
			float T = edgeT(hi, hj, fi, fj, viE, vj, d, w, jValid, pinIe, pinJ, cfI, cfJ, nIe, nJ, inside ? wI : hi, wJ, kI, kJ);
			// the upslope neighbour feeds this texel's column weight
			float up = -dot(normalize(d), gdir);
			if (jValid && up > upBest && hj > C1.w) { upBest = up; wUp = wJ; }
			wetN += (jValid && hj > C1.w) ? 1.0 : 0.0;
			if (!jValid)
			{
				// only run-off leaves through void edges; nothing flows in from a void
				T = max(T, 0.0);
				edgeOut += T;
			}
			outSum += T;
			float inflow = max(-T, 0.0);
			mom += inflow * vj - max(T, 0.0) * viE;
			clotOut += max(T, 0.0) * cfI;
			clotIn += inflow * cfJ;
			altOut += max(T, 0.0) * fA;
			altIn += inflow * fAJ;
			oxOut += max(T, 0.0) * fO;
			oxIn += inflow * fOJ;
#if !GHMPB_SIMBODY
			frOut += max(T, 0.0) * fF;
			frIn += inflow * fFJ;
#endif
			// the liquids mix where wet blood touches wet blood (symmetric exchange of the shares only)
			if (jValid && hi > C1.w && hj > C1.w)
			{
				float mixK = 1.2 * dt * w * min(hi, hj);
				altMix += mixK * (fAJ - fA);
				oxMix += mixK * (fOJ - fO);
			}
		}
	}

	// ---------------- the contact line a few texels out (1.19.0, floors and gentle slopes): what the next step's edges see as
	// this texel's wet-neighbour count. A dry texel next to the blood also looks at a ring ~2.2 texels out: a straight front
	// covers half of it (3, as before), a notch more (filled sooner), a tip less (held) - surface tension at the scale of a
	// few millimetres, so pools come out rounded and liquid instead of following the grid. And two pools close to each
	// other pull together: blood on opposite sides of the texel (the ring, or 5 texels out along the axes and diagonals -
	// up to ~1.5 cm apart at medium quality) makes it easy to wet, so nearby pools grow a bridge and join into one.
	// (only real blood counts for the pull, 0.12 mm and more - not the specks of a mist)
	float nOut = wetN;
#if !GHMPB_SIMBODY
	[branch] if (frothOn && hi <= C1.w && wetN > 0.5)
	{
		const float2 rg[8] = { float2(2, 1), float2(1, 2), float2(-1, 2), float2(-2, 1), float2(-2, -1), float2(-1, -2), float2(1, -2), float2(2, -1) };
		float rw[8], rp[8];
		float cnt = 0.0;
		[unroll] for (int r = 0; r < 8; r++)
		{
			float2 uq = uv + rg[r] * px;
			// (beyond the patch border: neutral - half a sample - so fronts do not lag along the borders)
			bool inq = all(uq > 0.0) && all(uq < 1.0);
			float hq = inq ? tex2Dlod(State, float4(uq, 0, 0)).x : 0.0;
			rw[r] = inq ? (hq > C1.w ? 1.0 : 0.0) : 0.5;
			rp[r] = hq > 0.12 ? 1.0 : 0.0;
			cnt += rw[r];
		}
		float pull = rp[0] * rp[4] + rp[1] * rp[5] + rp[2] * rp[6] + rp[3] * rp[7];
		const float2 far4[4] = { float2(5, 0), float2(0, 5), float2(4, 4), float2(4, -4) };
		[unroll] for (int f4 = 0; f4 < 4; f4++)
		{
			float2 ua = uv + far4[f4] * px, ub = uv - far4[f4] * px;
			float ha = (all(ua > 0.0) && all(ua < 1.0)) ? tex2Dlod(State, float4(ua, 0, 0)).x : 0.0;
			float hb = (all(ub > 0.0) && all(ub < 1.0)) ? tex2Dlod(State, float4(ub, 0, 0)).x : 0.0;
			pull += (ha > 0.12 && hb > 0.12) ? 1.0 : 0.0;
		}
		nOut = 0.4 * wetN + 0.45 * cnt + (pull > 0.5 ? 5.0 : 0.0);
	}
#endif

	// ---------------- levelling of thick blood (world patches, surfaces that press the blood down)
#if !GHMPB_SIMBODY
	float aPressL = max(0.0, -C13.w);
	if (aPressL > 100.0 && hi > LEV_H)
	{
		float L = fi.w;
		float headI = fi.x * 10.0 + hi;
		float availI = max(hi - C1.z, 0.0);
		// slower for viscous / clotting blood (the regular edges carry the viscosity physics)
		float lamB = (1.0 / 24.0) * clamp(0.07 / max(C1.x, 1e-3), 0.25, 1.0);
		// (alternate steps level along the axes (4, 12, 32 texels) and along the diagonals (2, 6, 16 texels each way),
		// so pools stay round; both texels of an exchange see the same parity)
		float par = C14.x - 2.0 * floor(C14.x * 0.5);
		const float2 laxis[4] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1) };
		const float2 ldiag[4] = { float2(1, 1), float2(-1, -1), float2(-1, 1), float2(1, -1) };
		const float saxis[3] = { 4.0, 12.0, 32.0 };
		const float sdiag[3] = { 2.0, 6.0, 16.0 };
		[unroll] for (int q = 0; q < 3; q++)
		{
			[unroll] for (int k2 = 0; k2 < 4; k2++)
			{
				float2 d2 = lerp(laxis[k2], ldiag[k2], par);
				float stq = lerp(saxis[q], sdiag[q], par);
				float2 uvj = uv + d2 * px * stq;
				if (all(uvj > 0.0) && all(uvj < 1.0))
				{
					float4 sj = tex2Dlod(State, float4(uvj, 0, 0));
					float4 fj = tex2Dlod(Force, float4(uvj, 0, 0));
					float hm = tex2Dlod(State, float4(uv + d2 * px * (stq * 0.5), 0, 0)).x;
					float hj = max(sj.x, 0.0);
					if (fj.w > 1e-5 && hj > LEV_H && hm > LEV_H)
					{
						float4 xj = tex2Dlod(Aux, float4(uvj, 0, 0));
						float oj = tex2Dlod(Acc, float4(uvj, 0, 0)).w;
						float cfJ = saturate(xj.x / hj);
						float HJ = hj + max(sj.y, 0.0);
						float cfm = max(cfI, cfJ);
						// head difference in mm of blood: bed + blood + the plane's own slope over the distance
						float dH = headI - (fj.x * 10.0 + hj) + 10.0 * dot(C13.yz, d2) * stq * L / aPressL;
						float lam = lamB * (1.0 - cfm) * (1.0 - cfm);
						float T = clamp(lam * dH, -max(hj - C1.z, 0.0) / 60.0, availI / 60.0);
						outSum += T;
						float inflow = max(-T, 0.0);
						clotOut += max(T, 0.0) * cfI;
						clotIn += inflow * cfJ;
						altOut += max(T, 0.0) * fA;
						altIn += inflow * saturate(xj.w / HJ);
						oxOut += max(T, 0.0) * fO;
						oxIn += inflow * saturate(oj / HJ);
						frOut += max(T, 0.0) * fF;
						frIn += inflow * (frothOn ? saturate(xj.z / hj) : 0.0);
						mom -= max(T, 0.0) * vi;
					}
				}
			}
		}
	}
#endif

	float h = max(hi - outSum, 0.0);
#if !GHMPB_SIMBODY
	float frV = clamp(hi * fF - frOut + frIn, 0.0, h);
#endif
	// (element stamps - acid dissolving, energy balls vaporising - take dried blood away: never below none)
	float s = max(si.y, 0.0);
	clot = clamp(clot - clotOut + clotIn, 0.0, h);
	float aV = aI - altOut + altIn + altMix;
	float oV = oI - oxOut + oxIn + oxMix;

	// coagulation (autocatalytic: slow start, then fast gelation)
	float cf = h > 1e-5 ? clot / h : 0.0;
	cf = saturate(cf + C11.x * (0.06 + cf) * (1.0 - cf) * dt);
	clot = cf * h;

	// lift-off (dripping) where the effective acceleration pulls the film off the surface
	float An = SIM_HF ? C13.w : fi.z;
	float hl = C2.x * 980.0 / max(An, 1.0) * (1.0 + 3.0 * cf);
	float lift = (An > 0.0) ? max(0.0, h - hl) * min(1.0, C2.y * dt) * (1.0 - 0.8 * cf) : 0.0;
	h -= lift;
	aV -= lift * fA;
	oV -= lift * fO;

	// viscous drag on the impact momentum (clotted blood is much more viscous)
	float hc = max(h * 0.1, 1e-4);
	float muS = C1.x * (1.0 + C11.y * cf * cf * cf);
	float decay = exp(-min(3.0 * muS / (GHMPB_RHO * hc * hc) * C3.z * dt, 30.0));
	float2 v = h > 1e-5 ? mom / h * decay : float2(0, 0);
	v = clamp(v, -150.0, 150.0);

	// drying (thin films dry faster, the clot crust slows it) + absorption into porous surfaces / cloth
	// (neither under water)
	// (the wet ground along the water line is already soaked: it takes up hardly any blood)
	float sub = saturate(depI / 0.3);
	float shore = saturate(1.0 + depI / 2.5);
	float kdry = C2.z * GHMPB_DRYK(h) * (1.0 - C11.w * cf) * (1.0 - sub);
	float kabs = C2.w * saturate(1.0 - s / max(C3.x, 1e-3)) * (1.0 - 0.7 * cf) * (1.0 - 0.85 * shore);
	float dd = h * (1.0 - exp(-(kdry + kabs) * dt));
	h -= dd;
	s += dd;
	// under water the blood mixes into it, gradually: fresh wet blood within a few seconds (clotted blood holds on much
	// longer), a dried stain over a minute or two (read back like lift-off)
	float wash = 0.0;
	if (sub > 0.0)
	{
		float washK = floor(C14.x * 0.5) * 0.25;
		float wH = h * (1.0 - exp(-0.25 * washK * sub * (1.0 - 0.85 * cf) * dt));
		float wS = max(s, 0.0) * (1.0 - exp(-0.008 * washK * sub * dt));
		h -= wH;
		s -= wS;
		wash = wH + wS;
		aV -= wash * fA;
		oV -= wash * fO;
	}
	if (h < 1e-4) { s += h; h = 0.0; v = 0; }
	clot = min(cf * h, h);

	float Ht = h + max(s, 0.0);
	aV = clamp(aV, 0.0, Ht);
	oV = clamp(oV, 0.0, Ht);
	o.state = float4(h, s, h * v.x, h * v.y);
	o.acc = float4(ai.x + lift + wash, ai.y + edgeOut, ai.z, oV);
	// column weight: this texel's blood plus most of the connected blood straight above it (steep surfaces only)
	float colW = (h > C1.w && gl > 200.0) ? min(h + 0.85 * wUp, 8.0) : h;
#if !GHMPB_SIMBODY
	// froth bursts: half of it within ~40 s in fresh blood, faster as the blood gels (and none outlives the wet blood)
	frV = min(frV * exp(-dt * 0.017 * (1.0 + 2.5 * cf)), h);
	o.aux = float4(clot, nOut, frothOn ? frV : colW, aV);
#else
	o.aux = float4(clot, wetN, colW, aV);
#endif
	o.ex = float4(h, Ht > 1e-5 ? aV / Ht : 0.0, Ht > 1e-5 ? oV / Ht : 0.0, h * (colBorder ? v.x : v.y));
	return o;
}
