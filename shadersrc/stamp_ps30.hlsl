// =====================================================================================
// GHM PhysBlood: impact / source stamping. Every droplet that lands is written pixel by pixel into the
// cell field of the surface it hit, shaped by its impact velocity (angle -> ellipse elongation and
// forward tail), its spin (twisted, spiral arms and swirl momentum), its stretch (ligament drops make
// long streaks) and its energy (crown spines + satellite droplets). The deposited fluid also receives
// momentum so it keeps sliding in the cell simulation.
// Used both in UV space of models (unwrap VS) and on world patches (clip VS with world pos in t1).
//
// s0 = impact table, 4 rows x N columns (RGBA16F, point sampled):
//   row0 = pos.xyz (relative to c0.yzw), radius (u)
//   row1 = velocity.xyz (u/s), volume (mm^3)
//   row2 = surface normal.xyz, oxygenation * 10 (integer part) + seed * 0.99 (fraction)
//   row3 = spin (rad/s about normal), stretch (>=1), kind (0 splat, 1 source, 2 wound, 3 smear, 4 push/wipe,
//          5 footprint), residue fraction
//   smear (3): row1.xyz = path of the contact since the last stamp (previous - current, u), row1.w = volume
//   push  (4): row1.xyz = path, row1.w = depth of the blood already there (mm), row3.y = speed (u/s),
//              row3.w = fraction wiped up (picked up by the body; the rest is pushed along)
//   print (5): row0.w = half the sole length (u), row1.xyz = walking direction, row1.w = volume,
//              row3.x = side (-1 left, +1 right), row3.y = freshness of the sole 0..1
//              |row3.x| = 2: HAND PRINT (sign: +2 right, -2 left hand), row0.w = half the hand length,
//              row1.xyz = direction of the fingers, row3.y = how wet the hand is 0..1
//              |row3.x| = 4..7: CREATURE TRACK (cl_footprints.lua), shape |row3.x| - 4: 0 pad / leg tip, 1 claw stab,
//              2 three toes, 3 paw; row0.w = half the print length, row1.xyz = where the foot points, row3.y = wetness
//              |row3.x| = 3: TYRE TREAD, row0.w = half the tread width, row1.xyz = path of the contact since the last
//              stamp (previous - current, u), row3.y = how much blood the tyre carries 0..1
//   smear (3) with |row3.x| = 5: a hand dragged along - four finger streaks instead of a smeared film
//   row3.z packs kind (0..7) + 8 * expirated flag (air bubbles) + 16 * spine count (Hulse-Smith), and for
//   splats row3.w carries the splash parameter K = sqrt(We) Re^(1/4) of the normal impact (> 1.5) instead of
//   the stain fraction
//   mist (6): row0.w = radius of the settling cloud on this surface (u), row1.xyz = mean travel, row1.w = volume
//   run trail (7): row0.w = half the rivulet width (u), row1.xyz = path since the last stamp (previous - current), row1.w = volume
// FORENSIC MODEL (bloodstain pattern analysis): the stain width follows Hulse-Smith (D = d/2 Re^(1/4)), its
// length the impact angle (W/L = sin a), the rim scallops on rough surfaces and throws spines (N = 1.14
// sqrt(We)) and satellite droplets once K passes the surface's splash threshold (earlier on rough concrete
// than on glass / paint; absorbent cloth / soil wick instead), spines and satellites gather on the leading
// side of oblique hits, a drop falling into wet blood merges and throws a ring of secondary spatter, and
// expirated blood (coughed / breathed out) carries air bubbles that leave rings and voids in the stain.
// c0 = (count, origin.xyz)   c1 = (1/tableW, 1/tableH, time, global volume scale)
// c2 = (normal window scale, min facing, froth amount (1.19.0: world patches that keep froth - floors, gentle slopes; 0 on
//       steep patches and bodies, whose aux.z is the column weight of runs), unused)
// c3 = (surface roughness 0..1, absorbency 0..1, 1 / target size, previous state bound)
// s1 = the target's previous state (wet blood already there: drip-into-blood spatter)
// out (additive blend) COLOR0 = (dh wet mm, ds stain mm, dh*vx, dh*vy) with v in texels/s
//                       COLOR1 = (0, 0, frothy blood volume (1.19.0, c2.z > 0), volume of the second blood type) into the
//                                aux target (row3.z + 1024
//                                marks an impact of the layer's second blood type: per-pixel colour mixing)
//                       COLOR2 = (0, 0, 0, oxygenated volume) into the accumulator (bright arterial / dark venous)
//                       COLOR3 = world patches' ghost export (dh, 0, 0, momentum across the border)
// =====================================================================================
#include "ghmpb_common.h"
sampler Impacts : register(s0);
sampler Prev    : register(s1);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT { float4 uv : TEXCOORD0; float4 wpos : TEXCOORD1; float4 wnrm : TEXCOORD2; };
struct PS_OUTPUT { float4 state : COLOR0; float4 aux : COLOR1; float4 acc : COLOR2; float4 ex : COLOR3; };

float2 toTexelVel(float3 v, float3 T, float3 B)
{
	float tt = dot(T, T), tb = dot(T, B), bb = dot(B, B);
	float det = tt * bb - tb * tb;
	if (abs(det) < 1e-10) return float2(0, 0);
	float vt = dot(v, T), vb = dot(v, B);
	return float2(bb * vt - tb * vb, tt * vb - tb * vt) / det;
}

float sq(float x) { return x * x; }

// signed distance to a tapered capsule along +y: a circle of radius r1 at the origin, one of r2 at (0, h)
float sdTaper(float2 p, float r1, float r2, float h)
{
	p.x = abs(p.x);
	float b = (r1 - r2) / h;
	float a = sqrt(saturate(1.0 - b * b));
	float k = dot(p, float2(-b, a));
	if (k < 0.0) return length(p) - r1;
	if (k > a * h) return length(p - float2(0.0, h)) - r2;
	return dot(p, float2(a, b)) - r1;
}

PS_OUTPUT main(PS_INPUT i)
{
	float altAcc = 0.0, oxyAcc = 0.0, frothAcc = 0.0;
	float3 P = i.wpos.xyz;
	float3 Nt = normalize(i.wnrm.xyz + 1e-6);
	float3 T = ddx(P);
	float3 B = ddy(P);
	float4 acc = 0;
	int count = (int)C0.x;
	float3 origin = C0.yzw;

	[loop] for (int k = 0; k < count; k++)
	{
		float u = (k + 0.5) * C1.x;
		float4 r0 = tex2Dlod(Impacts, float4(u, 0.125, 0, 0));
		float4 r1 = tex2Dlod(Impacts, float4(u, 0.375, 0, 0));
		float4 r2 = tex2Dlod(Impacts, float4(u, 0.625, 0, 0));
		float4 r3 = tex2Dlod(Impacts, float4(u, 0.875, 0, 0));
		float3 ip = r0.xyz + origin;
		float R = max(r0.w, 0.01);
		float3 d = P - ip;
		float stretch = clamp(r3.y, 1.0, 8.0);
		float code = floor(r3.z + 0.5);
		float isAlt = floor(code / 1024.0);
		code -= isAlt * 1024.0;
		float spinesN = floor(code / 16.0);
		float bubbles = floor((code - spinesN * 16.0) / 8.0);
		int kind = (int)(code - spinesN * 16.0 - bubbles * 8.0 + 0.5);
		// froth (1.19.0): the share of this blood whipped up with air - coughed / breathed-out (lung) blood is frothy, bright
		// spurts and hard, fast impacts trap air, a slow venous pour hardly any
		float oxyF0 = saturate(floor(r2.w + 1e-3) / 10.0);
		// (1.25.0: much less from impacts - a fast spray came down a third froth and drew pale dotted rings; drops only trap
		// air at really high speed, and bright lung / arterial blood is the frothy kind)
		float fz = (kind == 0) ? saturate((length(r1.xyz) - 450.0) / 1800.0) * (0.15 + 0.6 * oxyF0)
		         : ((kind == 1) ? 0.08 + 0.5 * saturate((oxyF0 - 0.55) / 0.4) : 0.0);
		fz = (bubbles > 0.5 && kind <= 1) ? max(fz, 0.85) : fz;
		// conservative reach of the whole splat: elongation (1/sin of the impact angle) x stretch, the forward
		// shift, the tail and the satellite ring (the CPU uses the same formula to pick the patches it touches);
		// smears / pushes are capsules along their path
		float reach;
		if (kind == 6)
		{
			reach = R + 0.5;
		}
		else if (kind >= 3)
		{
			reach = R * 1.4 + length(r1.xyz) + 0.5;
		}
		else
		{
			float3 nq = normalize(r2.xyz + 1e-6);
			float spq = length(r1.xyz);
			float sinq = saturate(abs(dot(r1.xyz, nq)) / max(spq, 1e-3));
			float eMax = min(clamp(1.0 / max(sinq, 0.12), 1.0, 8.0) * stretch, 10.0);
			reach = R * (2.6 * eMax + 5.0) + 0.5;         // (secondary spatter reaches ~6 radii)
		}
		if (dot(d, d) > reach * reach) continue;

		float3 n = normalize(r2.xyz + 1e-6);
		float z = dot(d, n);
		float zwin = max(R * 0.7, 0.75) * C2.x;
		float w = saturate(1.0 - abs(z) / zwin) * saturate((dot(Nt, n) - C2.y) / 0.35);
		if (w <= 0.0) continue;

		float3 vel = r1.xyz;
		float vol = r1.w;
		float oxyQ = floor(r2.w + 1e-3);
		float seed = saturate((r2.w - oxyQ) / 0.99);
		float oxyImp = saturate(oxyQ / 10.0);
		float spin = r3.x;
		float residue = saturate(r3.w);
		float Rmm = R * 19.05;

		float dh = 0.0;
		float ds = 0.0;
		float3 vdep = 0;
		float momH = -1.0;       // >= 0: momentum carried by blood already there (push), instead of the new blood

		if (kind == 1)
		{
			// continuous bleeding source (nostril, lip, ear, wound weeping): soft blob with an irregular edge
			float3 dq = d - z * n;
			float rq = length(dq) / R * (1.0 + 0.6 * (ghmpb_vnoise(dq.xy / R * 1.6 + dq.z / R * 0.7 + seed * 19.0) - 0.5));
			float g = exp(-rq * rq);
			dh = vol / (GHMPB_PI * Rmm * Rmm) * g;
		}
		else if (kind == 2)
		{
			// wound: dark coagulated core + wet ring
			float3 dq = d - z * n;
			float r = length(dq) / R * (1.0 + 0.5 * (ghmpb_vnoise(dq.xy / R * 1.9 + dq.z / R * 0.8 + seed * 23.0) - 0.5));
			float g = exp(-r * r * 1.6);
			dh = vol / (GHMPB_PI * Rmm * Rmm) * g;
			ds = residue * saturate(1.0 - r * 1.9) * (0.6 + 0.4 * ghmpb_hash11(seed * 91.7 + r * 3.0));
		}
		else if (kind == 3 || kind == 4)
		{
			// path of the contact: from ip + seg (where it was) to ip (where it is now), in the surface plane
			float3 segT = vel - dot(vel, n) * n;
			float L = length(segT);
			float3 sdir = L > 1e-3 ? segT / L : float3(0, 0, 0);
			float3 dt3 = d - z * n;
			float al = clamp(dot(dt3, sdir), 0.0, L);
			float dist = length(dt3 - al * sdir);
			float3 side = normalize(cross(n, sdir + float3(1e-4, 2e-4, 3e-4)));
			float lat = dot(dt3, side);
			float tA = L > 1e-3 ? al / L : 0.0;            // 0 = where the body is now, 1 = where it came from
			if (kind == 3)
			{
				// SMEAR: a bloody surface slid over the ground, leaving a streaked film: ragged edges, striations
				// along the motion (cloth folds / skin), gaps where it lifted, heavier where the contact started
				float edgeN = 1.0 + 0.5 * (ghmpb_vnoise(float2(al * 1.3 + seed * 17.0, seed * 5.0)) - 0.5);
				float prof = saturate(1.0 - sq(dist / (R * edgeN)));
				// long thin streaks (fine + coarse) with high contrast: dense ridges and almost bare lanes
				float sF = ghmpb_vnoise(float2(lat / R * 9.0 + seed * 31.0, al * 0.05));
				float sC = ghmpb_vnoise(float2(lat / R * 3.5 + seed * 13.0, al * 0.12));
				float stri = 0.12 + 1.3 * pow(saturate(0.6 * sF + 0.4 * sC), 1.6);
				if (abs(spin) > 4.5)
				{
					// FINGER DRAG (cl_hands.lua): four parallel streaks, one per finger, wandering a little, each
					// streaky along its length
					float lq = lat / R;
					float wob = 0.06 * (ghmpb_vnoise(float2(al * 0.4 + seed * 9.0, seed)) - 0.5);
					float fl = exp(-sq((lq - 0.66 - wob) / 0.14)) + exp(-sq((lq - 0.22 - wob) / 0.15))
					         + exp(-sq((lq + 0.22 - wob) / 0.15)) + exp(-sq((lq + 0.64 - wob) / 0.12)) * 0.8;
					stri = saturate(fl) * (0.55 + 0.7 * sF);
				}
				// lifted spots: warped so they read as organic skips, not a grid of blocks
				float2 gq = float2(lat / R * 1.7 + seed * 5.0, al * 0.22 + seed * 7.0);
				gq += 0.8 * float2(ghmpb_vnoise(gq * 1.9 + 3.1), ghmpb_vnoise(gq * 1.9 + 9.7));
				float gaps = smoothstep(0.3, 0.62, ghmpb_vnoise(gq));
				float dens = pow(prof, 0.7) * stri * lerp(0.1, 1.0, gaps) * lerp(0.5, 1.3, tA);
				float areaMM = max(L, R) * 19.05 * 2.0 * R * 19.05;
				dh = vol / areaMM * dens * 1.4;
				vdep = -sdir * 25.0;
			}
			else
			{
				// PUSH / WIPE: moving through blood that is already there: part is wiped up (the body carries it
				// away), the rest is shoved along the motion, so pools get dragged out into streaks
				float prof = saturate(1.0 - sq(dist / R));
				float hEst = max(vol, 0.0);
				dh = -residue * max(hEst - 0.04, 0.0) * prof;
				momH = hEst * (1.0 - residue) * prof;
				vdep = -sdir * min(r3.y, 200.0) * 0.6;
			}
		}
		else if (kind == 7)
		{
			// RUN TRAIL (cl_runs.lua): the film a rivulet leaves behind its bead - a narrow lane with a rounded
			// cross-section from where the head was (ip + path) to where it is now (ip); its two edges wander a little
			// (the contact line catches on the surface), continuously from one segment to the next
			float3 segT = vel - dot(vel, n) * n;
			float L = length(segT);
			float3 sdir = L > 1e-3 ? segT / L : float3(0, 0, 0);
			float3 dt3 = d - z * n;
			float al = clamp(dot(dt3, sdir), 0.0, L);
			float dist = length(dt3 - al * sdir);
			float3 side = normalize(cross(n, sdir + float3(1e-4, 2e-4, 3e-4)));
			float sg = dot(dt3, side) >= 0.0 ? 11.0 : 3.0;
			float wob = 1.0 + 0.45 * (ghmpb_vnoise(float2(dot(P, sdir) / R * 0.55, sg)) - 0.5);
			float prof = saturate(1.0 - sq(dist / (R * wob)));
			float areaMM = max(L, R) * 19.05 * 2.0 * R * 19.05 * 0.6667;
			dh = vol / max(areaMM, 1e-3) * prof;
			vdep = float3(0, 0, 0);
		}
		else if (kind == 5)
		{
			float fresh = saturate(r3.y);
			float variant = abs(spin);
			float3 dq = d - z * n;
			float dens = 0.0;
			float areaMM = 1.0;
			if (variant > 3.5)
			{
				// CREATURE TRACK: the foot of a non-human walker. A wet foot prints whole; as it runs dry, patches of
				// it (cl_footprints.lua passes the volume for the areas below, so the film is as thick as the blood given off)
				float shape = floor(variant - 4.0 + 0.5);
				float3 fw = vel - dot(vel, n) * n;
				fw = fw / max(length(fw), 1e-4);
				float3 sd = cross(n, fw);
				float x = dot(dq, fw) / R;                                  // forwards (where the foot / claw points)
				float y = dot(dq, sd) / R * (spin < 0.0 ? -1.0 : 1.0);      // mirrored for the feet on the left
				float en = 1.0 + 0.12 * (ghmpb_vnoise(float2(x, y) * 5.0 + seed * 13.0) - 0.5);
				float shp;
				if (shape > 2.5)
				{
					// paw: a lobed main pad and four oval toe pads in an arc in front of it (area ~0.78 R^2)
					float hw = 0.5 - 0.12 * (x + 0.3);
					float lobes = 1.0 - 0.12 * smoothstep(0.0, 0.25, -(x + 0.45)) * (1.0 - abs(sin(y / hw * 3.0)));
					float mainP = 1.0 - smoothstep(0.85, 1.0, length(float2((x + 0.3) / 0.42, y / hw)) * en / lobes);
					float toes = 0.0;
					[unroll] for (int t = 0; t < 4; t++)
					{
						float ang = (t - 1.5) * 0.55;
						float rr = (t == 1 || t == 2) ? 0.66 : 0.5;
						float2 tc = float2(0.1 + rr * cos(ang), rr * sin(ang) * 1.15);
						toes = max(toes, 1.0 - smoothstep(0.8, 1.0, length(float2((x - tc.x) / 0.17, (y - tc.y) / 0.13)) * en));
					}
					shp = max(mainP, toes);
					areaMM = sq(Rmm) * 0.78;
				}
				else if (shape > 1.5)
				{
					// three slender toes from the ball of the foot, the middle one straight ahead, and a short back toe;
					// a claw mark beyond each tip (area ~0.54 R^2)
					float toes = 0.0;
					[unroll] for (int t = 0; t < 4; t++)
					{
						float ang = (t == 0) ? 0.0 : ((t == 1) ? 0.62 : ((t == 2) ? -0.62 : 3.14159));
						float len = (t == 0) ? 0.9 : ((t == 3) ? 0.45 : 0.72);
						float2 td = float2(cos(ang), sin(ang));
						float tt = clamp(dot(float2(x, y), td), 0.0, len + 0.1);
						float dist = length(float2(x, y) - td * tt);
						float wdt = (tt > len ? 0.06 : 0.16 * (1.0 - 0.35 * tt / len)) * en;
						toes = max(toes, (1.0 - smoothstep(wdt * 0.6, wdt, dist)) * (tt > len ? 0.8 : 1.0));
					}
					float ball = 1.0 - smoothstep(0.14, 0.24, length(float2(x, y)) * en);
					shp = max(toes, ball);
					areaMM = sq(Rmm) * 0.54;
				}
				else if (shape > 0.5)
				{
					// claw stab: a teardrop pointed where the tip went in, a faint drag mark behind it where it pulled out
					// (area ~0.53 R^2)
					float sdC = sdTaper(float2(y, x + 0.15), 0.3, 0.03, 1.1) / en;
					float stab = 1.0 - smoothstep(-0.03, 0.03, sdC);
					float drag = (1.0 - smoothstep(0.04, 0.1, abs(y + 0.04 * sin(x * 7.0 + seed * 9.0))))
					           * smoothstep(-0.95, -0.55, x) * (1.0 - smoothstep(-0.3, -0.1, x));
					drag *= 0.45 * (0.6 + 0.4 * ghmpb_vnoise(float2(x * 6.0, seed * 31.0)));
					shp = max(stab, drag);
					areaMM = sq(Rmm) * 0.53;
				}
				else
				{
					// pad / leg tip: an irregular round dot; drying, the middle prints lighter than the rim (blood pushed
					// out from under the pad) (area ~2.5 R^2)
					float rr = length(float2(x, y)) * en;
					shp = (1.0 - smoothstep(0.8, 1.0, rr)) * lerp(0.6 + 0.4 * smoothstep(0.35, 0.85, rr), 1.0, fresh);
					areaMM = sq(Rmm) * 2.5;
				}
				float thr = (1.0 - fresh) * 0.55;
				float patchN = ghmpb_vnoise(float2(x, y) * 2.5 + seed * 29.0);
				dens = shp * smoothstep(thr - 0.12, thr + 0.12, patchN);
			}
			else if (variant > 2.5)
			{
				// TYRE TREAD (cl_tyres.lua): a rolling tyre that went through blood prints its tread - lug blocks
				// between circumferential grooves, rounded shoulders - along the stretch it rolled since the last
				// stamp. The lug pattern is laid out in world space along the motion, so it runs on seamlessly from one
				// stamp to the next. A tyre soaked in blood prints the whole contact patch, then the lugs, then
				// patches of them, and fades out over a few turns of the wheel
				float3 segT = vel - dot(vel, n) * n;
				float L = length(segT);
				float3 sdir = L > 1e-3 ? segT / L : normalize(cross(n, float3(0.31, 0.57, 0.76)));
				float3 side = normalize(cross(n, sdir + float3(1e-4, 2e-4, 3e-4)));
				float al = dot(dq, sdir);
				float lat = dot(dq, side) / R;
				float inLen = smoothstep(-0.6, -0.2, al) * (1.0 - smoothstep(L + 0.2, L + 0.6, al));
				float shoulder = 1.0 - smoothstep(0.8, 1.0, abs(lat));
				float s = dot(P, sdir);
				float grooves = smoothstep(0.035, 0.09, abs(abs(lat) - 0.45)) * smoothstep(0.02, 0.07, abs(lat));
				float lugs = smoothstep(-0.25, 0.3, sin(s * 1.9 + abs(lat) * 6.0));
				float tread = grooves * lerp(lugs, 1.0, 0.2);
				// (soaked, the gaps between the lugs fill up - the circumferential grooves stay lighter)
				float fill = lerp(tread, grooves * 0.9 + 0.1, fresh * fresh * 0.75);
				float thr = (1.0 - fresh) * 0.6;
				float patchN = ghmpb_vnoise(float2(s * 0.35, lat * 1.3) + seed * 17.0);
				float breakup = smoothstep(thr - 0.12, thr + 0.12, patchN);
				dens = inLen * shoulder * fill * breakup;
				areaMM = max(L, 0.5) * 19.05 * 2.0 * Rmm * 0.8;
			}
			else if (variant > 1.5)
			{
				// HAND PRINT (cl_hands.lua): a bloody hand pressed on a surface - the palm with its heel pads and a
				// lighter hollow, four fingers and the thumb, the creases of the palm and the finger joints left
				// bare. A soaked hand prints solid; as it dries only the pads print (finger tips, palm heel, the pads
				// under the knuckles), then broken-up patches of them with the grain of the skin
				float3 fw = vel - dot(vel, n) * n;
				fw = fw / max(length(fw), 1e-4);
				float3 sd = cross(n, fw);
				float x = dot(dq, fw) / R;                                  // -1 wrist .. +1 finger tips
				float y = dot(dq, sd) / R * (spin < 0.0 ? -1.0 : 1.0);      // + = thumb side
				float en = 1.0 + 0.07 * (ghmpb_vnoise(float2(x, y) * 5.0 + seed * 13.0) - 0.5);
				// palm: a rounded box, narrower at the wrist than at the knuckles, lighter in its hollow
				float hw = 0.36 + 0.1 * saturate(x + 1.0);
				float2 pq = max(abs(float2((x + 0.47) / 0.53, (y - 0.02) / hw)) * en, 1e-4);
				float pr = pow(max(pow(pq.x, 2.6) + pow(pq.y, 2.6), 1e-6), 0.3846);
				float palm = 1.0 - smoothstep(0.88, 1.0, pr);
				float hollow = exp(-(sq(x + 0.36) / 0.07 + sq(y - 0.02) / 0.05));
				// creases: across the palm below the fingers, across its middle (not over the thumb pad), and the life
				// line round the thumb pad - thin, lighter lines
				float c1 = smoothstep(0.008, 0.03, abs(x - (-0.02 + 0.18 * y)));
				float g2 = (1.0 - smoothstep(0.008, 0.03, abs(x + 0.22 + 0.25 * y))) * (1.0 - smoothstep(0.1, 0.25, y));
				float c3 = smoothstep(0.008, 0.03, abs(length(float2((x + 0.62) / 1.25, (y - 0.36) / 0.8)) - 0.34));
				float crease = (0.35 + 0.65 * c1) * (1.0 - 0.65 * g2) * (0.35 + 0.65 * c3);
				palm *= (1.0 - 0.55 * hollow * (1.0 - fresh * 0.6)) * crease;
				// fingers: tapering capsules from inside the palm to the tips, fanning out a little (the spread differs
				// from print to print); joint creases; pads at the tips and under the knuckles
				float spread = 0.04 + 0.08 * seed;
				float fingers = 0.0, tips = 0.0, knuck = 0.0;
				[unroll] for (int f = 0; f < 4; f++)
				{
					float4 fp = (f == 0) ? float4(0.33, 0.06, 0.78, 0.095) : ((f == 1) ? float4(0.11, 0.08, 0.84, 0.1)
					          : ((f == 2) ? float4(-0.11, 0.06, 0.8, 0.095) : float4(-0.32, 0.0, 0.64, 0.08)));
					float a = fp.x * spread * 2.5;
					float2 fd = float2(cos(a), sin(a));
					float2 rel = float2(x - fp.y, y - fp.x);
					float t = clamp(dot(rel, fd), -0.14, fp.z);
					float dist = length(rel - fd * t);
					float wdt = fp.w * (1.0 - 0.15 * max(t, 0.0) / fp.z);
					float cap = 1.0 - smoothstep(wdt * 0.75, wdt, dist);
					float joints = (0.4 + 0.6 * smoothstep(0.01, 0.03, abs(t - fp.z * 0.42))) * (0.4 + 0.6 * smoothstep(0.01, 0.03, abs(t - fp.z * 0.72)));
					fingers = max(fingers, cap * joints);
					tips = max(tips, cap * exp(-sq((t - fp.z * 0.88) / 0.1)));
					knuck = max(knuck, exp(-(sq(x - fp.y + 0.07) / 0.012 + sq(y - fp.x) / 0.008)));
				}
				// thumb, angled out from the thumb pad (thenar), which joins it to the palm
				float2 td = float2(0.7219, 0.6920);
				float2 trel = float2(x + 0.42, y - 0.4);
				float tt = clamp(dot(trel, td), 0.0, 0.58);
				float tw = 0.13 - 0.03 * tt / 0.58;
				float thumb = (1.0 - smoothstep(tw * 0.8, tw, length(trel - td * tt))) * (0.4 + 0.6 * smoothstep(0.01, 0.03, abs(tt - 0.3)));
				tips = max(tips, thumb * exp(-sq((tt - 0.5) / 0.1)));
				float thenar = (1.0 - smoothstep(0.85, 1.0, length(float2((x + 0.5) / 0.34, (y - 0.3) / 0.2)))) * (0.35 + 0.65 * c3);
				float shape = max(max(palm, fingers), max(thumb, thenar));
				// pads that still print when the hand is nearly dry
				float heel = exp(-(sq(x + 0.72) / 0.03 + sq(y - 0.18) / 0.04)) + exp(-(sq(x + 0.7) / 0.03 + sq(y + 0.2) / 0.03));
				float pads = saturate(max(max(tips, heel), knuck * 0.85));
				float fill = lerp(pads, 1.0, pow(fresh, 1.5) * 0.9);
				float thr = (1.0 - fresh) * 0.55;
				float patchN = ghmpb_vnoise(float2(x, y) * 4.5 + seed * 29.0);
				float breakup = smoothstep(thr - 0.12, thr + 0.12, patchN);
				float grain = 0.85 + 0.15 * ghmpb_vnoise(float2(x, y) * 14.0 + seed * 7.0);
				dens = shape * fill * breakup * lerp(grain, 1.0, fresh);
				areaMM = (2.0 * Rmm) * (0.9 * Rmm) * 0.55;
			}
			else
			{
				// FOOTPRINT: a shoe sole set down on the ground - forefoot and toe box, the outer edge of the shank,
				// heel - with a lug tread. A sole soaked in blood prints solid (the gaps between the lugs are flooded
				// too); as it runs dry only the lugs print, then only patches of them
				float3 fw = vel - dot(vel, n) * n;
				fw = fw / max(length(fw), 1e-4);
				float3 sd = cross(n, fw);                                   // towards the walker's left
				float x = dot(dq, fw) / R;                                  // -1 heel .. +1 toe
				float y = dot(dq, sd) / R * (spin < 0.0 ? -1.0 : 1.0);      // + = inner side (arch, big toe)
				float en = 1.0 + 0.08 * (ghmpb_vnoise(float2(x, y) * 7.0 + seed * 13.0) - 0.5);
				float eF = length(float2((x - 0.36) / 0.62, (y - 0.03) / 0.37)) * en;     // forefoot + toe box
				float eH = length(float2((x + 0.66) / 0.32, (y + 0.01) / 0.255)) * en;    // heel
				float shank = saturate(1.0 - abs(x + 0.28) / 0.34) * saturate(1.0 - abs(y + 0.2) / 0.13);
				float sole = max(max(1.0 - smoothstep(0.86, 1.0, eF), 1.0 - smoothstep(0.84, 1.0, eH)), smoothstep(0.0, 0.35, shank) * 0.8);
				float xs = x * R, ys = y * R;
				float chev = smoothstep(-0.25, 0.35, sin(xs * 5.2 + abs(ys) * 2.6 + seed * 6.0));
				float blocks = smoothstep(-0.3, 0.4, sin(xs * 6.0) * sin(ys * 6.0 + 1.3));
				float tread = lerp(chev, blocks, saturate((-0.25 - x) / 0.2));
				float fill = lerp(tread, 1.0, fresh * fresh * 0.85);
				float thr = (1.0 - fresh) * 0.62;
				float patchN = ghmpb_vnoise(float2(xs, ys) * 0.9 + seed * 29.0);
				float breakup = smoothstep(thr - 0.12, thr + 0.12, patchN);
				dens = sole * fill * breakup;
				areaMM = (2.0 * Rmm) * (0.72 * Rmm) * 0.78;
			}
			dh = vol / areaMM * dens * 1.25;
		}
		else if (kind == 6)
		{
			// ---------------- MIST settling on a surface (gunshot aerosol, coughed spray): hundreds of sub-mm
			// specks, densest where the cloud met the surface and thinning out towards its edge, drawn out
			// along the direction the cloud travelled. Below the cell size a speck is a single texel with the
			// blood of a small cluster of droplets (a stippled haze, like the real "misting" pattern)
			float3 dq = d - z * n;
			float rr = length(dq) / R;
			if (rr < 1.0)
			{
				float3 tt = vel - dot(vel, n) * n;
				float tl = length(tt);
				float el = 1.0 + 1.5 * saturate(tl / max(length(vel), 1e-3));
				float3 ta = tl > 1e-3 ? tt / tl : normalize(cross(n, float3(0.31, 0.57, 0.76)));
				float3 tb = cross(n, ta);
				float cellU = max(length(T), 1e-3);                      // one texel
				float2 cq = floor(float2(dot(dq, ta) / el, dot(dq, tb)) / cellU);
				float hsh = ghmpb_hash12(cq + seed * 173.0);
				float fall = exp(-rr * rr * 2.8) * (1.0 - smoothstep(0.75, 1.0, rr));
				float areaMM = GHMPB_PI * Rmm * Rmm * 0.45;              // effective area of the gaussian field
				float meanH = vol / max(areaMM, 1e-3);
				float hs = clamp(meanH * 5.0, 0.012, 0.06);             // blood of one speck (cluster) per texel
				float prob = saturate(meanH / hs * 2.2) * fall;
				dh = (hsh < prob) ? hs * (0.5 + ghmpb_hash12(cq * 1.7 + seed * 31.0)) : 0.0;
			}
			vdep = float3(0, 0, 0);
		}
		else
		{
			// ---------------- droplet impact (forensic stain anatomy, see the header)
			float vn = dot(vel, n);
			float3 vt = vel - vn * n;
			float speed = length(vel);
			float vts = length(vt);
			float sinA = saturate(abs(vn) / max(speed, 1e-3));
			float e = clamp(1.0 / max(sinA, 0.12), 1.0, 8.0) * stretch;     // L / W = 1 / sin(a)
			e = min(e, 10.0);
			float3 t = vts > 2.0 ? vt / vts : normalize(cross(n, normalize(float3(seed - 0.5, 0.37, 0.61) + 1e-4)));
			float3 b = cross(n, t);
			float x = dot(d, t);
			float y = dot(d, b);
			// spin: the spreading lamella rotates while it expands -> spiral twist growing with radius
			float r = length(float2(x, y));
			float tw = clamp(spin * 0.012, -3.0, 3.0) * saturate(r / (R * 2.5));
			float cs = cos(tw), sn = sin(tw);
			float xr = x * cs - y * sn;
			float yr = x * sn + y * cs;
			float oblique = saturate((e - 1.0) * 0.8);
			float skid = saturate((e - 4.0) / 3.0);                 // very acute hits (< ~12 deg): a skid streak
			// body: a teardrop - round and broad at the back where the drop came down, narrowing towards the
			// front, where the moving blood piles up; its centre sits a little ahead of the contact point
			float L = R * e;
			float xc = R * 0.3 * (e - 1.0);
			float xe = (xr - xc) / L;                                // -1 back .. +1 front
			float wf = clamp(1.0 - 0.32 * oblique * xe, 0.55, 1.4);  // width: wide back, narrow front
			float ye = yr / (R * wf);
			float rho = length(float2(xe, ye));
			float ang = atan2(ye, xe);
			float energy = saturate(speed / 450.0);
			// splash: K of the normal impact against the surface threshold (rough surfaces splash first,
			// absorbent ones wick instead of splashing)
			float K = r3.w > 1.5 ? r3.w : (60.0 * energy);
			float Kc = lerp(140.0, 45.0, saturate(C3.x));
			float spl = saturate(K / Kc - 0.6) * (1.0 - saturate(C3.y * 1.5));
			float nsp = clamp(spinesN > 0.5 ? spinesN : lerp(7.0, 18.0, energy), 5.0, 60.0);
			// leading side (direction of travel) of an oblique hit
			float lead = lerp(1.0, 1.7 * pow(saturate(0.5 + 0.5 * cos(ang)), 2.0), oblique);
			// wet blood already there (the previous step's state at the impact point)
			float wetUnder = 0.0;
			if (C3.w > 0.5)
			{
				float2 toC = toTexelVel(ip - P, T, B);
				wetUnder = tex2Dlod(Prev, float4(i.uv.xy + toC * C3.z, 0, 0)).x;
			}
			float intoBlood = smoothstep(0.15, 0.4, wetUnder);
			// rim: fine scallops on rough surfaces below the threshold, spines above it; the long sides of a skid
			// streak are serrated
			float wav = sin(ang * nsp + seed * 40.0);
			float scallop = 0.06 * saturate(C3.x) * (1.0 - spl) * wav;
			float spikes = spl * lead * (0.14 + 0.45 * spl) * pow(saturate(0.5 + 0.5 * wav), 10.0)
			             + pow(saturate(cos(ang)), 8.0) * 0.4 * saturate(e - 1.0);
			float serr = skid * 0.2 * (ghmpb_vnoise(float2(xr / R * 2.3 + seed * 17.0, (yr > 0.0 ? 3.0 : 9.0) + seed)) - 0.4);
			float edge = 1.0 + scallop + spikes + serr + 0.035 * sin(ang * (nsp * 0.37 + 3.0) - seed * 17.0);
			float q = rho / edge;
			float dome = sqrt(saturate(1.0 - q * q));
			float rim = 0.32 * exp(-sq((q - 0.9) / 0.09)) * step(q, 1.08);
			float dens = (q < 1.0 ? dome : 0.0) + rim;
			// the sliding drop leaves more blood towards its front; a skid streak thins out into lanes
			dens *= 1.0 + 0.45 * oblique * clamp(xe, -1.0, 1.0);
			float lanes = ghmpb_vnoise(float2(yr / R * 3.2 + seed * 29.0, xr / R * 0.22));
			dens *= lerp(1.0, 0.3 + 0.9 * smoothstep(0.25, 0.65, lanes), skid);
			// into wet blood: no stain of its own - it merges into the pool (a soft bump)
			dens = lerp(dens, exp(-rho * rho * 1.4) * 1.3, intoBlood);

			// tail: the thin streak the leading edge draws out beyond the body (the "exclamation mark")
			float xf = xc + L * 0.92;
			float tailLen = R * e * (0.55 + 0.3 * skid) * saturate(e - 1.3);
			float tx = xr - xf;
			if (tx > 0.0 && tx < tailLen)
			{
				float u = tx / tailLen;
				float wob = 1.0 + 0.3 * (ghmpb_vnoise(float2(tx / R * 1.7 + seed * 5.0, seed * 3.0)) - 0.5);
				float width = (R * 0.3 * (1.0 - u) + 0.04) * wob;
				dens += saturate(1.0 - abs(yr) / width) * (0.6 - 0.25 * u) * (1.0 - intoBlood);
			}
			// wave cast-off: the blood wave running along the stain breaks off its tip as a separate small drop
			// beyond the tail - itself a little teardrop whose narrow end points back at the parent stain
			float hw = ghmpb_hash11(seed * 53.1 + 0.37);
			if (e > 1.6 && e < 7.5 && hw < 0.3 + 0.45 * oblique && intoBlood < 0.5)
			{
				float gap = R * (0.25 + 0.6 * ghmpb_hash11(seed * 71.3));
				float rw = R * (0.2 + 0.18 * ghmpb_hash11(seed * 13.9));
				float off = R * 0.3 * (hw - 0.4);
				float cxw = xf + tailLen + gap + rw * 1.4;
				float2 wq = float2((xr - cxw) / (rw * 1.5), (yr - off) / rw);
				wq.y /= clamp(1.0 + 0.45 * wq.x, 0.4, 1.4);
				float wr = length(wq);
				dens += sqrt(saturate(1.0 - wr * wr)) * 0.9;
				float bx = cxw - rw * 1.5 - xr;
				if (bx > 0.0 && bx < gap * 0.8)
					dens += saturate(1.0 - abs(yr - off) / (rw * 0.25 * (1.0 - bx / (gap * 0.8)) + 0.02)) * 0.4;
			}
			// satellites thrown off the rim (splash), mostly ahead of an oblique hit; a drop falling into blood
			// throws a wider ring of secondary spatter
			float nSec = 22.0;
			float sector = floor((ang / (2.0 * GHMPB_PI) + 0.5) * nSec);
			float h1 = ghmpb_hash11(sector * 1.37 + seed * 97.0);
			float pSat = max(spl * 0.8 * lead, intoBlood * saturate(K / Kc) * 0.85);
			if (h1 < pSat)
			{
				float ac = ((sector + 0.5) / nSec - 0.5) * 2.0 * GHMPB_PI;
				float far = lerp(1.3 + 2.2 * ghmpb_hash11(sector * 3.1 + seed * 11.0), 2.0 + 4.0 * ghmpb_hash11(sector * 5.3 + seed * 7.0), intoBlood);
				float rs = far * (0.6 + 0.4 * saturate(0.5 + 0.5 * cos(ac)) * (1.0 + oblique));
				float2 sc = float2(cos(ac), sin(ac)) * rs;
				float ssz = (0.06 + 0.1 * ghmpb_hash11(sector * 7.7 + seed)) * lerp(1.0, 0.7, intoBlood);
				float sd = length(float2(xe, ye) - sc) / ssz;
				dens += sqrt(saturate(1.0 - sd * sd)) * 0.8;
			}
			// expirated blood: air bubbles leave small voids ringed by blood
			if (bubbles > 0.5 && q < 1.0)
			{
				float2 bq = float2(xe, ye) * 3.2 + seed * 13.0;
				float2 bi = floor(bq);
				float2 bo = float2(ghmpb_hash12(bi), ghmpb_hash12(bi + 7.7)) * 0.6 + 0.2;
				float br = 0.12 + 0.22 * ghmpb_hash12(bi + 3.3);
				float bd = length(bq - bi - bo) / br;
				float hole = (ghmpb_hash12(bi + 1.9) < 0.55) ? (1.0 - smoothstep(0.7, 0.9, bd)) : 0.0;
				float ring = exp(-sq((bd - 0.95) / 0.12));
				dens = dens * (1.0 - hole) + ring * 0.5 * (ghmpb_hash12(bi + 1.9) < 0.55 ? 1.0 : 0.0);
			}
			float h0 = vol / (0.6667 * GHMPB_PI * Rmm * Rmm * e);
			dh = h0 * dens;
			// momentum: part of the tangential speed survives + swirl from spin
			float3 swirl = cross(n, d) * clamp(spin, -60.0, 60.0) * 0.35;
			vdep = vt * (0.12 + 0.1 * oblique) + swirl;
		}

		dh *= w * C1.w;
		ds *= w;
		// splats, smears, prints and mist leave part as stain (splats that carry K use the standard fraction)
		// (1.26.9c) splats that carry K: 5 % stain on floors (was 20 % everywhere - a fifth of every fresh drop showed as dried
		// crust from the moment it landed, so spatter never looked as fresh and wet as the pool beside it), 20 % on walls
		float rk = (kind == 0) ? (r3.w > 1.5 ? lerp(0.2, 0.05, saturate((n.z - 0.55) / 0.3)) : residue) : ((kind == 3 || kind == 5 || kind == 7) ? residue : (kind == 6 ? 0.35 : 0.0));
		float wet = dh * (1.0 - rk);
		float stain = ds + dh * rk;
		float2 vtex = toTexelVel(vdep, T, B);
		vtex = clamp(vtex, -120.0, 120.0);
		float mh = momH >= 0.0 ? momH * w : wet;
		acc += float4(wet, stain, mh * vtex.x, mh * vtex.y);
		// (blood taken away - wipes - leaves the type volume to the simulation, which keeps it within the texel)
		altAcc += isAlt * max(wet + stain, 0.0);
		oxyAcc += oxyImp * max(wet + stain, 0.0);
		frothAcc += max(wet, 0.0) * saturate(fz * C2.z);
	}
	// (1.20.1, bodies: C2.w = which half of a part with mirrored UVs this target holds - see ghmpb_uvHand. Additive: a
	// texel of the other half adds nothing. Worked out here, at the end - a clip at the top ran the shader out of temp
	// registers)
	// (in the UV-space passes the screen is the UV square: ddx u ddy v - ddx v ddy u > 0, the winding is (T x B) . N)
	if (C2.w > 0.5)
	{
		float hand = dot(cross(T, B), Nt);
		float keep = (C2.w < 1.5 ? hand : -hand) >= 0.0 ? 1.0 : 0.0;
		acc *= keep; frothAcc *= keep; altAcc *= keep; oxyAcc *= keep;
	}
	PS_OUTPUT o;
	o.state = acc;
	o.aux = float4(0, 0, frothAcc, altAcc);
	o.acc = float4(0, 0, 0, oxyAcc);
	// (the export carries mx on the left / right border columns, my elsewhere - see sim_ps30)
	bool colBorder = i.uv.x < C3.z || i.uv.x > 1.0 - C3.z;
	o.ex = float4(acc.x, 0, 0, colBorder ? acc.z : acc.w);
	return o;
}
