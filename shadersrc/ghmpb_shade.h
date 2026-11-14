// =====================================================================================
// GHM PhysBlood: physically based blood film shading shared by bodyfilm (models) and surface (world),
// dynamic and aftermath (static) layers.
//
// 1.20.0 - PBR blood. 1.19 read as juice or jelly: the light on the blood was estimated per colour channel from a
// texture's mean colour, so most surfaces lit it far too bright and orange-red (brighter than the floor, see-through,
// hiding its reflections); pools were shaded as domes all over and swelled; the "pool look" turned the top coat into a
// lacquer (F0 ~0.06, a broad key-light sheen); dried blood stayed red. Now: the light from luminances (ghmpb_irradiance);
// the optics fitted to spectral ground truth (tools/pbr: Prahl's haemoglobin spectra, CIE 1931) - a thick pool is a dark
// crimson ~sRGB (99, 11, 14) at a 0.25 grey floor's light, venous blood maroon-black; a level pool with a meniscus at its
// rim (ghmpb_visH); an energy-conserving dielectric top coat (wet n = 1.39, F0 0.027, a free liquid surface rough 0.03;
// a dried crust n = 1.5, glossy where it was thick, matte where thin or soaked in) whose sharp reflections are what make
// it read as wet; dried blood red-brown, browning to black-brown as it ages.
//
// The blood is composited over the already lit scene (framebuffer copy), which is what makes it respond
// to every light Source has: lightmaps, ambient cubes, dynamic lights, projected texture / flashlight
// shadows. All the optics run on linear light: the framebuffer, model textures and cubemaps are read raw
// (sRGB encoded, $linearread 1) and decoded here, the result is encoded here and written raw ($linearwrite
// 1) - letting the hardware convert as well doubles the gamma and washes blood out to pink.
//   * diffuse: Kubelka-Munk layers - a dried stain / crust, then the wet blood - over the surface, in four
//     wavelength bands from the haemoglobin absorption spectra and the red cells' scattering. A smear tints
//     the surface (scarlet when thin), a pool shows only the blood's own crimson / maroon; clots scatter
//     more, dried blood turns brown. The liquid surface traps half the light scattered back inside it
//     (Saunderson correction): wet blood is darker and more saturated than dry
//   * the diffuse colour is lit by the irradiance recovered from the lit framebuffer divided by the surface
//     albedo (low-pass filtered on the world so the floor texture does not print through), so it is
//     shadowed exactly like the surface, plus the relief of beads, drops and pool rims from the light probe
//   * thin films on surfaces blood only partly wets (skin, paint, metal) break up into beads and smears
//   * specular: wet blood is a smooth dielectric (F0 = 0.022): GGX highlights from the key / sun /
//     flashlight lights plus a Fresnel weighted, roughness filtered reflection of the scene (screen space)
//     or the cubemap, with horizon occlusion and specular anti-aliasing. A pool is a flat mirror whatever is
//     under it, a thin film keeps the micro roughness of the surface, gelled blood gets a satin skin and a
//     dry crust a matte-satin sheen; the energy reflected at the surface does not enter the blood
//   * dried blood has a darker coffee ring at the edge and shrinkage cracks where it was thick
// Film normals come from the gradient of the simulated thickness (with a meniscus at the rim of pools and
// drops) and animated flow ripples where the blood is actually running.
// =====================================================================================
#ifndef GHMPB_SHADE_H
#define GHMPB_SHADE_H
#include "ghmpb_common.h"
// world patches (ghmpb_surface_main.h) are close to the ps_3_0 register limit: some element effects are done there
// after the film shading, more cheaply (GHMPB_WORLD 1)
#ifndef GHMPB_WORLD
#define GHMPB_WORLD 0
#endif

float4 SC0 : register(c0);   // (1/ScrW, 1/ScrH, 1/RT size, time)
float4 SC1 : register(c1);   // (oxygen 0..1 (aftermath layers; live layers carry it per pixel), blood type pair,
                              //  hue * 8 + normal depth (see ghmpb_ndepth), dried-blood absorption * 100 + fabric * 0.999)
float4 SC2 : register(c2);   // key light direction xyz (towards light), has bump map | surface: smooth mode
float4 SC3 : register(c3);   // key light colour rgb (light units), flashlight on + 2 * element word (1.17.0, ghmpb_elemField)
float4 SC11 : register(c11); // sun direction xyz, sun visibility
float4 SC12 : register(c12); // sun colour rgb, env reflection scale
float4 SC13 : register(c13); // flashlight position xyz, layer: fade (fraction) + dry progress * 255 (integer part)
float4 SC14 : register(c14); // flashlight direction xyz, range (integer part) + cos(outer angle) * 0.999 (fraction)
float4 SC15 : register(c15); // SH L1 red
float4 SC16 : register(c16); // SH L1 green
float4 SC17 : register(c17); // SH L1 blue
float4 SC18 : register(c18); // (absorption scale, stain darkness, gloss, debug*4 + smooth) | surface: albedo rgb, absorption scale

struct GHMPB_Film
{
	float h;          // wet film mm
	float s;          // stain mm (wet equivalent)
	float clot;       // clotted fraction of the wet blood 0..1
	float ring;       // 0..1 edge factor of the stain (coffee ring)
	float3 slope;     // world-space gradient of the visual film height (u / u)
	float2 flowUV;    // direction of flow in texture space
	float3 flowW;     // the same direction in the world (1.18.0: the streaks of running blood are tilted across it)
	float flowSpeed;  // cm/s
	float2 flowPos;   // texture space coordinate used for ripples / wrinkles
	float2 crackPos;  // texel space coordinate for crack cells
	float serum;      // 0..1 serum separated from a retracted clot (clear yellow rim around old pools)
	float alt;        // fraction of the layer's second blood type in this pixel (SC1.y = type A + 8 * type B)
	float oxy;        // oxygen saturation of the blood in this pixel (bright arterial / lung 1 .. dark venous / organ 0.4)
	float froth;      // share of the wet blood whipped up with air into froth, times the froth setting (1.19.0; live world layers)
};

// player colour settings, packed into SC1.z / SC1.w (see GPU.PackZW):
//   SC1.z = round((hue + 1) * 100) * 8 + normal depth (0..6)     SC1.w = round(dried absorption * 100) + fabric * 0.999
// (the fresh-blood brightness is folded into the absorption scale on the CPU)
float ghmpb_ndepth() { return SC1.z - floor(SC1.z / 8.0 + 1e-4) * 8.0; }
float ghmpb_hueAt(float z)    { return floor(z / 8.0 + 1e-4) / 100.0 - 1.0; }
float ghmpb_fabricAt(float w) { return saturate((w - floor(w + 1e-4)) / 0.999); }
float ghmpb_dryMulAt(float w) { float q = floor(w + 1e-4); return q > 0.5 ? q / 100.0 : 1.0; }
float ghmpb_hue()    { return ghmpb_hueAt(SC1.z); }
float ghmpb_fabric() { return ghmpb_fabricAt(SC1.w); }
float ghmpb_dryMul() { return ghmpb_dryMulAt(SC1.w); }
// (1.19.0) The "At" decoders take the constant as max(constant, -x) with some x >= 0 worked out where the value is used: it
// is the constant, but the compiler can no longer decode it at the top of the shader and hold the result in temp registers
// all the way down to that use - the world shader is at the ps_3_0 limit of 32.
// (hue shift of the absorption: ghmpb_hueMul in ghmpb_common.h, shared with the drops)

// SC1.y = blood type pair (type A + 8 * type B, < 64) + 64 * look word (1.19.0, world layers; 0 on bodies):
//   look word = pool look * 10 (0..31) + 32 * froth * 10 (0..31; 0 on patches that keep no froth - steep ones)
// (integers divided by powers of two: exact)
// (the pair by frac, the look word by floor: two different expressions, so the compiler does not keep a shared one alive
// from the top of the shading to the colour at its end)
float ghmpb_pairCodeAt(float c) { return frac(c / 64.0) * 64.0; }
float ghmpb_lookWord() { return floor(SC1.y / 64.0); }
float ghmpb_poolLook() { float w = ghmpb_lookWord(); return (w - 32.0 * floor(w / 32.0)) * 0.1; }
float ghmpb_frothAmt() { return floor(ghmpb_lookWord() / 32.0) * 0.1; }
// The pool look decoded from c = max(SC1.y, -x) with some x >= 0 worked out where it is used (c is SC1.y): the compiler can not
// move the decode of a constant-only value to the top of the shader and hold it in temp registers all the way down to its use
// - the world shader is at the ps_3_0 limit. SC1.y / 2048 = froth + (64 pool + pair) / 2048
float ghmpb_poolLookAt(float c) { return floor(frac(c / 2048.0) * 32.0) * 0.1; }

float ghmpb_layerFade() { float d = floor(SC13.w); return saturate((SC13.w - d) / 0.999); }
// time since the layer settled, in units of the drying time (see GPU.LayerWord)
float ghmpb_layerDry()  { return floor(SC13.w) / 64.0; }
// SC12.w = reflection strength * 64 (integer part, 0..192) + 256 * (fresh blood's extra shine * 4) + micro roughness of the
// surface under the blood * 0.999 (1.26.10: the fresh shine, from Lua's "Fresh blood wetness")
float ghmpb_reflScale() { float w = floor(SC12.w); return (w - 256.0 * floor(w / 256.0)) / 64.0; }
float ghmpb_freshShine() { return floor(SC12.w / 256.0) * 0.25; }
float ghmpb_roughSub()  { return saturate((SC12.w - floor(SC12.w)) / 0.999); }
// visual height of the film surface (mm) for the relief normals: a pool is flat on top and rises steeply at
// its rim (the meniscus - blood meets a surface at a contact angle of a few tens of degrees), so the edge of a
// pool or a drop catches the light as a rounded rim instead of the whole pool reading as a flat decal.
// 1.18.0: the contact line is steep right at the edge and rounds over into the top (a shoulder, the way surface tension
// holds a pool of a thick liquid), and a deep pool stands a little taller than a thin one - it reads as a body of liquid
// with a thickness, not a stain
// 1.20.0 (PBR blood): the old profile kept rising with the thickness up to 2.5 mm, so a pool was shaded as a dome all over -
// a blob of jelly. Gravity levels a liquid: past the capillary length of blood (~2 mm) its surface is flat, whatever
// the depth below it; only the contact line rises steeply (the meniscus). The visual height saturates within the first
// tenths of a mm of depth - the rim has the relief, the body of the pool is a level mirror. A dried crust is a thin,
// flat sheet (about a quarter of the wet thickness).
float ghmpb_visH(float h, float s)
{
	return 0.55 * (1.0 - exp(-h / 0.12)) + 0.2 * (1.0 - exp(-s / 0.15));
}

// ---------------- surface materials (1.16.0): how blood looks on what it landed on. World patches read them from the
// material table (GPU.MatTable, G.SurfaceMatParams in sh_config.lua: 2 x 2 texels per value block so a lookup is exact
// whatever the filtering), by the surface kind id packed into SC2.w; bodies keep the defaults (their look comes from
// fabric / roughness). 1.18.0: read where a value is used - decoded into static globals at the top of the shader, they
// took temp registers through all of it, and the world shader ran out of them.
//   row 0: soak (porous: blood soaked into the pores keeps the colour of fresh blood, not a brown crust), dilute (absorption
//          of the soaked blood - snow: diluted by melt water), scat (scattering of the soaked layer - snow and sand grains
//          around the blood: brighter, pinker), brown (how fast soaked blood browns as it ages - snow keeps it red)
//   row 1: crack (dried crust cracks: none where the blood soaked in, crisp flakes on glass / metal), spark (ice crystal
//          glints through thin blood: snow, ice), sink (stains sink in: snow melts under the warm blood), halo type
//          (0 damp - the surface darkens, 1 pink - haemoglobin in melt water, 2 serum - pale yellow)
//   row 2: halo (wicking halo around the stain: strength), its reach (texels), grain (the surface breaks the blood up:
//          strength), its frequency (per texel)
//   row 3: grain kind (0 grains / pores, 1 stones - blood runs into the gaps, 2 blades - grass)
// material ids (sh_config.lua G.SurfaceMatId): 0 sealed 1 concrete 2 stone 3 metal 4 wood 5 soil 6 carpet 7 glass 8 ice
// 9 rubber 10 brick 11 plaster 12 paper 13 sand 14 gravel 15 grass 16 snow 17 grate
#if GHMPB_WORLD
// (1.26.9c) + 1024 on aftermath layers of a pool a wounded body bled into (the serum ring is drawn only there)
float ghmpb_matId() { float w = SC2.w - 1024.0 * floor(SC2.w / 1024.0 + 1e-4); return floor(w / 32.0 + 1e-3); }
float ghmpb_serumOn() { return SC2.w > 1023.5 ? 1.0 : 0.0; }
// (vo: a small offset that keeps two lookups of the same row from being merged and kept alive in between; harmless,
// every value fills a 2 x 2 block)
float4 ghmpb_mat(float row, float vo) { return tex2Dlod(MatT, float4((ghmpb_matId() * 2.0 + 1.0) / 64.0, (row * 2.0 + 1.0 + vo) / 8.0, 0, 0)); }
#else
float4 ghmpb_mat(float row, float vo) { return row < 0.5 ? float4(0, 1, 1, 1) : (row < 1.5 ? float4(1, 0, 0, 0) : (row < 2.5 ? float4(0, 3, 0, 0.6) : float4(0, 0, 0, 0))); }
#endif
// how fresh the layer is (1 live; soaked blood of the aftermath ages towards brown - slowly in snow)
#if GHMPB_WORLD && GHMPB_STATIC
float ghmpb_matFresh(float brown) { return exp(-ghmpb_layerDry() * 0.15 * brown); }
#else
float ghmpb_matFresh(float brown) { return 1.0; }
#endif

// ---------------- elements (1.17.0, cl_elements.lua): what fire, cold, electricity, acid and radiation do to the blood
// of this patch / body. SC3.w = flashlight on + 2 * (frost + 16 boil + 256 fizz + 2048 glow type + 16384 glow
// + 262144 char): frost, boil, glow, char 0..15, fizz and glow type 0..7 - below 2^23, so (w + 0.5) / div stays exact
// (decoded where they are used, from the constant: values kept in static globals take temp registers for the whole
// shader, and the world shader is close to the ps_3_0 limit)
float ghmpb_elemFieldAt(float w, float div, float m) { float q = floor((w + 0.5) / div); return q - floor((q + 0.5) / m) * m; }
float ghmpb_elemField(float div, float m) { return ghmpb_elemFieldAt(SC3.w, div, m); }
float ghmpb_flashOn() { return ghmpb_elemField(1.0, 2.0); }
float ghmpb_frost()   { return ghmpb_elemField(2.0, 16.0) / 15.0; }       // frozen: glassy, hoarfrost bloom, glints
float ghmpb_boil()    { return ghmpb_elemField(32.0, 16.0) / 15.0; }      // boiling: bubbles, cooking brown, froth
float ghmpb_fizz()    { return ghmpb_elemField(512.0, 8.0) / 7.0; }       // acid: fine fast foam, yellow-green froth
float ghmpb_glowT()   { return ghmpb_elemField(4096.0, 8.0); }            // 1 electric, 2 radioactive, 3 embers, 4 plasma
float ghmpb_glow()    { return ghmpb_elemField(32768.0, 16.0) / 15.0; }
float ghmpb_char()    { return ghmpb_elemField(524288.0, 16.0) / 15.0; }  // bodies: burnt - the crust chars black
// (frost and boil again by another expression, for the colour at the end of the shading: with one expression the compiler
// kept the decoded fields alive from the normals to the colour - 1.19.0, world shader at the ps_3_0 temp register limit)
// (w = max(SC3.w, -x) with some x >= 0 from where they are used, see ghmpb_poolLookAt)
float ghmpb_frostAt(float w) { return floor(frac((w + 0.5) / 32.0) * 16.0) / 15.0; }
float ghmpb_boilAt(float w)  { return floor(frac((w + 0.5) / 512.0) * 16.0) / 15.0; }
float ghmpb_fizzAt(float w)  { return ghmpb_elemFieldAt(w, 512.0, 8.0) / 7.0; }
float ghmpb_glowTAt(float w) { return ghmpb_elemFieldAt(w, 4096.0, 8.0); }
float ghmpb_glowAt(float w)  { return ghmpb_elemFieldAt(w, 32768.0, 16.0) / 15.0; }
// bubbles rising through boiling (or fizzing) blood: one per cell of a jittered grid, swelling and bursting into a
// spreading ring; returns its height 0..1 and the gradient (cell units)
float ghmpb_bubble(float2 p, float t, out float2 grad)
{
	float2 ip = floor(p), fp = frac(p);
	float hs = ghmpb_hash12(ip);
	float h2 = ghmpb_hash12(ip + 7.3);
	// (only about half the cells hold a bubble, of different sizes, anywhere in the cell: a full grid of equal
	// bubbles read as a regular dot pattern in game)
	float on = step(0.45, frac(hs * 7.31 + h2 * 3.17));
	float2 c = 0.25 + 0.5 * float2(hs, h2);
	float ph = frac(t * (0.6 + 0.8 * hs) + hs * 13.0);
	float r = (0.06 + 0.22 * ph) * (0.6 + 0.8 * h2);
	float2 v = fp - c;
	float d = length(v);
	float burst = smoothstep(0.86, 1.0, ph);
	float dome = saturate(1.0 - d * d / (r * r)) * (1.0 - burst) * on;
	float rd = (d - r * 1.25) / 0.05;
	float ring = exp(-rd * rd) * burst * on;
	grad = (d < r ? -2.0 * v / (r * r) * (1.0 - burst) * on : float2(0, 0)) - (v / max(d, 1e-3)) * ring * 0.5;
	return dome + ring * 0.6;
}

// (1.26.9d) big bubbles riding on a fresh pool a wound is feeding with frothy blood (world floors): at most one per cell of
// a jittered grid (dens: share of the cells that hold one), each lives a few seconds - it swells as it comes up, sits on the
// pool and bursts, and another comes up somewhere else in the cell. Returns the dome 0..1, its gradient (cell units) and
// rimL: the thin wall at its edge, which scatters the light (a lighter red ring round a darker middle)
float ghmpb_bigBubble(float2 p, float t, float dens, out float2 grad, out float rimL)
{
	float2 ip = floor(p), fp = frac(p);
	float hs = ghmpb_hash12(ip + 23.1);
	float ph = t / (4.0 + 5.0 * hs) + hs * 7.0;
	float gen = floor(ph), a = frac(ph);
	float h2 = ghmpb_hash12(ip + gen * 3.7 + 1.9);
	float on = step(1.0 - dens, h2) * (1.0 - smoothstep(0.88, 1.0, a));
	float2 c = 0.4 + 0.2 * frac(float2(h2 * 13.7, h2 * 71.3));
	float r = (0.22 + 0.15 * frac(h2 * 29.1)) * (0.35 + 0.65 * smoothstep(0.0, 0.3, a));
	float2 v = fp - c;
	float dd = dot(v, v) / (r * r);
	float dome = saturate(1.0 - dd) * on;
	grad = dd < 1.0 ? -2.0 * v / (r * r) * on : float2(0, 0);
	rimL = on * smoothstep(0.45, 0.85, dd) * (1.0 - smoothstep(0.95, 1.12, dd));
	return dome;
}

// small air bubbles caught in fresh blood (1.18.0): bright spurts carry a few, blood from the lungs is frothy with them.
// At most one per cell of a jittered grid (dens: share of the cells that hold one), a tiny dome that catches the light;
// returns its height 0..1 and the gradient (cell units)
float ghmpb_airBubble(float2 p, float dens, out float2 grad)
{
	float2 ip = floor(p), fp = frac(p);
	float hs = ghmpb_hash12(ip + 41.7);
	float on = step(1.0 - dens, hs);
	float2 c = 0.22 + 0.56 * frac(float2(hs * 13.7, hs * 71.3));
	float r = 0.09 + 0.13 * frac(hs * 29.1);
	float2 v = fp - c;
	float dd = dot(v, v) / (r * r);
	float dome = saturate(1.0 - dd) * on;
	grad = dd < 1.0 ? -2.0 * v / (r * r) * on : float2(0, 0);
	return dome;
}

// debug views (ghmpb_debug_view): 0 off, 1 thickness (models: colour ramp; world: wet / dried / coverage),
// 2 without reflections / highlights, 3 reflections / highlights only, 4 diffuse reflectance of the layers
static float gDbg = 0.0;

float3 ghmpb_flashlight(float3 P, float3 N, float3 V, float roughness, out float3 L)
{
	float range = floor(SC14.w);
	float cosO = saturate((SC14.w - range) / 0.999);
	float3 d = SC13.xyz - P;
	float dist = length(d);
	L = d / max(dist, 1e-3);
	float cosA = dot(-L, normalize(SC14.xyz));
	float cone = saturate((cosA - cosO) / max(1.0 - cosO, 1e-3));
	cone = cone * cone * (3.0 - 2.0 * cone);
	float atten = saturate(1.0 - dist / max(range, 1.0));
	return float3(1.0, 0.97, 0.92) * cone * atten * atten * ghmpb_flashOn() * 3.0;
}

// ---------------- reflection probes and the lights of the map (1.25.0, cl_probes.lua)
// s5 (ProbeT) = the probe atlas of the blood group this layer belongs to (RGBA8, read raw, 1024 x 1024 since 1.25.1):
//   [0, 384) x [0, 256)    the six faces of a cube map rendered from the probe with render.RenderView (128 x 128 each),
//                          face f at column f % 3, row f / 3, in the order +X -X +Y -Y +Z -Z (cl_probes P.FACES)
//   [0, 192) x [256, 288)  the same faces blurred (32 x 32 each, a ~22 deg cone): rough and dried blood
//   [0, 1024) x [512, 1024) (1.25.1) the floor mirror (cl_probes.lua P.MirrorStep): the scene seen from the camera mirrored
//                          under the floor at the height in texel (388, 0) (16 bit, .z on), upside down
//   [384, 512) x [0, 8)    data: texel (384, 0) = centre x, y (16 bit each), (385, 0) = centre z, radius of the
//                          reflection sphere / 8, valid; rows 1..4 = the strongest lights around the group, 4 texels each:
//                          (x, y) | (z, range / 64, type) | (colour, log2 intensity) | (spot direction, cos outer angle)
// A probe that has not been rendered yet holds the map's cubemap (no sphere: the reflection is looked up by direction).
float4 ghmpb_pt(float x, float y) { return tex2Dlod(ProbeT, float4((x + 0.5) / GHMPB_PA, (y + 0.5) / GHMPB_PA, 0, 0)); }
float ghmpb_u16(float hi, float lo) { return floor(hi * 255.0 + 0.5) * 256.0 + floor(lo * 255.0 + 0.5); }
float3 ghmpb_ptPos(float4 a, float2 b) { return float3(ghmpb_u16(a.x, a.y), ghmpb_u16(a.z, a.w), ghmpb_u16(b.x, b.y)) * (32768.0 / 65535.0) - 16384.0; }

// reflection of the scene around the blood from P in direction R (roughness rough): the probe's cube map, parallax corrected
// against its sphere (what stands round the group - walls, bodies, lamps - lands where it is, not at infinity); rough blood
// takes the blurred faces (linear light)
float3 ghmpb_probeEnv(float3 P, float3 R, float rough)
{
	float4 h0 = ghmpb_pt(384.0, 0.0), h1 = ghmpb_pt(385.0, 0.0);
	float rad = floor(h1.z * 255.0 + 0.5) * 8.0;
	float3 d = R;
	[branch] if (h1.w > 0.5 && rad > 1.0)
	{
		float3 o = P - ghmpb_ptPos(h0, h1.xy);
		float b = dot(o, R);
		float t = -b + sqrt(max(b * b - (dot(o, o) - rad * rad), 0.0));
		d = o + R * max(t, 0.0);
	}
	float3 fs = ghmpb_cubeFace(d);
	float3 c = tex2Dlod(ProbeT, float4(ghmpb_faceUV(fs, 128.0, float2(0, 0), 3.0), 0, 0)).rgb;
	float3 cb = tex2Dlod(ProbeT, float4(ghmpb_faceUV(fs, 32.0, float2(0, 256), 6.0), 0, 0)).rgb;
	return ghmpb_reflBoost(ghmpb_toLinear(lerp(c, cb, smoothstep(0.04, 0.26, rough))));
}

// B-spline bicubic filtering from 4 bilinear taps (Sigg & Hadwiger) - removes the texel staircase
float4 ghmpb_cubic(sampler tex, float2 uv, float texel)
{
	float size = 1.0 / texel;
	float2 iuv = uv * size - 0.5;
	float2 fuv = frac(iuv);
	iuv = floor(iuv);
	float2 w0 = (1.0 / 6.0) * (fuv * (fuv * (-fuv + 3.0) - 3.0) + 1.0);
	float2 w1 = (1.0 / 6.0) * (fuv * fuv * (3.0 * fuv - 6.0) + 4.0);
	float2 w2 = (1.0 / 6.0) * (fuv * (fuv * (-3.0 * fuv + 3.0) + 3.0) + 1.0);
	float2 w3 = (1.0 / 6.0) * (fuv * fuv * fuv);
	float2 g0 = w0 + w1, g1 = w2 + w3;
	float2 h0 = (iuv - 1.0 + w1 / g0 + 0.5) * texel;
	float2 h1 = (iuv + 1.0 + w3 / g1 + 0.5) * texel;
	return g0.y * (g0.x * tex2Dlod(tex, float4(h0.x, h0.y, 0, 0)) + g1.x * tex2Dlod(tex, float4(h1.x, h0.y, 0, 0)))
	     + g1.y * (g0.x * tex2Dlod(tex, float4(h0.x, h1.y, 0, 0)) + g1.x * tex2Dlod(tex, float4(h1.x, h1.y, 0, 0)));
}

// surface gradient of a scalar height field (world units) from screen derivatives (Mikkelsen 2010)
float3 ghmpb_surfGrad(float3 P, float3 N, float height)
{
	float3 dPdx = ddx(P), dPdy = ddy(P);
	float3 R1 = cross(dPdy, N), R2 = cross(N, dPdx);
	float det = dot(dPdx, R1);
	det = abs(det) > 1e-12 ? det : 1e-12;
	return (ddx(height) * R1 + ddy(height) * R2) / det;
}

// crack network of dried crust: distance to the nearest cell border (F2 - F1 of a jittered grid), and its
// gradient in p (analytic: no screen derivatives, so it can sit inside the branch that skips empty pixels)
float ghmpb_crack(float2 p, out float2 grad)
{
	float2 ip = floor(p), fp = frac(p);
	float f1 = 8.0, f2 = 8.0;
	float2 v1 = float2(1, 0), v2 = float2(1, 0);
	[unroll] for (int y = -1; y <= 1; y++)
	[unroll] for (int x = -1; x <= 1; x++)
	{
		float2 g = float2(x, y);
		float2 o = float2(ghmpb_hash12(ip + g), ghmpb_hash12(ip + g + 19.19));
		float2 v = g + o - fp;
		float dd = length(v);
		if (dd < f1) { f2 = f1; v2 = v1; f1 = dd; v1 = v; } else if (dd < f2) { f2 = dd; v2 = v; }
	}
	// d|g + o - p| / dp = -(g + o - p) / |g + o - p|
	grad = v1 / max(f1, 1e-4) - v2 / max(f2, 1e-4);
	return f2 - f1;
}

// Everything of the film shading that needs screen-space derivatives, evaluated before the dynamic branch that
// skips the rest of the shading for pixels without blood (fxc hoists gradient instructions out of branches, so
// shading that used them ran for every pixel of every patch / body, blood or not)
struct GHMPB_Pre
{
	float h, s, cf;     // wet / stain mm and clotted fraction after the aftermath's drying
	float hL, sL;       // gathered by dewetting (beads, smears)
	float3 Nb;          // the normal the film sits on (surface detail filled in by thick films)
	float3 N0;          // + film relief and the rims of beads (ripples, wrinkles and cracks are added in the shading)
	float nvar;         // normal variation inside the pixel (specular anti-aliasing)
};

GHMPB_Pre ghmpb_filmPre(float3 Ng, float3 Ns, float3 P, GHMPB_Film f, float dryT)
{
	GHMPB_Pre q;
	float fabric = ghmpb_fabric();
	float roughSub = ghmpb_roughSub();
	// aftermath layers keep drying after the simulation has been frozen, at the same thickness dependent
	// rate as the live cells: splatter and smears within minutes, a deep pool over many times longer
	// (dryT = time since settling in drying-time units)
	float h0 = max(f.h, 0.0);
	float dryP = dryT > 0.0 ? 1.0 - exp(-GHMPB_DRYK(h0) * dryT) : 0.0;
	q.h = h0 * (1.0 - dryP);
	q.s = max(f.s, 0.0) + h0 * dryP;
	q.cf = lerp(saturate(f.clot), 1.0, dryP);

	// ---------------- thin films break up (dewetting)
	// A liquid film on a surface it only partly wets (skin, paint, metal, sealed stone) is only stable above a
	// few tens of microns: thinner, it retracts into droplets, beads and streaks - a wiped or run-off smear is
	// mottled, not a coat of paint. The volume is kept: where the film has gathered it is thicker, and it dries
	// in place, so the dried residue shows the same pattern. Cloth and porous surfaces soak it up instead.
	// (skin, metal, paint: blood stands in beads and runs up to a few tenths of a mm; concrete, wood and soil
	// are wetted - they take a thin film; cloth soaks it up)
	float hc = lerp(0.09, 0.03, saturate(fabric * 2.5)) * lerp(1.0, 0.5, saturate((roughSub - 0.3) / 0.5));
	float cover = saturate((q.h + q.s) / hc);
	float coverF = pow(cover, 0.6);
	// (broad, soft blotches a few texels across: smears and beads, not a speckle)
	float nd = 0.65 * ghmpb_vnoise(f.crackPos * 0.32 + 3.1) + 0.35 * ghmpb_vnoise(f.crackPos * 0.85 + 9.7);
	float ndw = max(fwidth(nd), 0.05);
	float thr = lerp(0.82, 0.08, coverF);
	float isl = smoothstep(thr - ndw, thr + ndw, nd);
	isl = cover >= 0.999 ? 1.0 : isl;
	float gather = isl / max(coverF, 0.12);
	q.hL = q.h * gather;
	q.sL = q.s * gather;
	// normals: surface detail is filled in by thick films (a pool is a liquid surface: it is flat whatever is
	// under it - only thin films and blood soaked into cloth or porous stone keep the relief of the surface)
	// (1.21.0) how deep the surface's relief is (mm, per kind of surface - ghmpb_mat row 3 .y; bodies: skin shallow, cloth
	// deeper): blood thinner than that follows it - the surface's normal map on the world, the model's on bodies - a thicker
	// film fills it in and levels it out
#if GHMPB_WORLD
	float rd = max(ghmpb_mat(3.0, 0.2).y, 0.02);
#else
	float rd = lerp(0.15, 0.6, fabric);
#endif
	float fill = smoothstep(0.15 * rd, rd, q.hL + q.sL * 0.25);
	q.Nb = normalize(lerp(Ns, Ng, fill * (1.0 - fabric * 0.6 * (1.0 - smoothstep(0.1, 0.5, q.hL)))));
	// beads and droplets of a broken-up film are little domes: their rims catch the light
	float bead = (1.0 - isl) * isl * 4.0 * (1.0 - cover) * (1.0 - fabric);
	float2 bg = float2(ddx(isl), ddy(isl));
	float3 beadV = -(normalize(ddx(P)) * bg.x + normalize(ddy(P)) * bg.y) * 0.4 * bead;
	q.N0 = normalize(q.Nb - f.slope * ghmpb_ndepth() + beadV);
	// specular anti-aliasing: the normal variation inside the pixel
	float3 dNx = ddx(q.N0), dNy = ddy(q.N0);
	q.nvar = 0.25 * (dot(dNx, dNx) + dot(dNy, dNy));
	return q;
}

// The film shading in two parts (1.18.0): the surface - normals, highlights, reflection - and then the colour - the
// Kubelka-Munk layers. The highlights and reflection need many vectors and the layers many four-band values; one after
// the other, they no longer have to fit into the 32 temp registers of ps_3_0 at the same time (the world shader had run
// out of them), and the world shader mixes its screen-space reflection in between.
// q = ghmpb_filmPre(...) of the same pixel (evaluated outside the branch this runs in: nothing here may use screen
// derivatives)
struct GHMPB_Spec
{
	float3 col;     // highlights + the reflection, already weighted
	float3 Fr;      // reflection weight (energy the surface reflects does not enter the blood)
	float3 env;     // the cubemap reflection (world patches mix their screen-space reflection over it)
	float3 N;       // the final normal
	float3 V;       // towards the eye
	float dmul;     // what the relief and the meniscus do to the diffuse light
	float hOpt;     // optical thickness of the wet blood (mm)
	float crack;    // share of the crust opened up by cracks
	float foam;     // froth of boiling / fizzing blood (models)
};

// E = irradiance recovered from the lit framebuffer (fbSmooth / albedo; see ghmpb_filmDiffuse), envOcc = how much of the
// cubemap's light reaches here (from the local light level)
GHMPB_Spec ghmpb_filmSpec(float3 E, float envOcc, float3 Ng, float3 P, GHMPB_Film f, GHMPB_Pre q, float gloss)
{
	GHMPB_Spec o;
	float fabric = ghmpb_fabric();
	// SC12.w = reflection strength * 64 (integer part) + roughness of the surface under the blood * 0.999
	float roughSub = ghmpb_roughSub();
	float cf = q.cf;
	float hL = q.hL, sL = q.sL;
	float3 Tt2 = normalize(cross(Ng, float3(0.57, 0.31, 0.76)));
	float3 Bt2 = cross(Ng, Tt2);
	float3 N = q.N0;
	float3 Nb = q.Nb;
	// how steeply the film's own surface stands at this pixel (the meniscus at the rim of a pool, a drop, a bead)
	float rimT = saturate((1.0 - dot(N, Nb)) * 6.0);
	// ---------------- dried crust: shrinkage cracks where it was thick
	float sd = sL * 0.3;
	// (cloth soaks the blood up: it stiffens and darkens, it does not crack like a crust on a hard surface)
	float4 m1 = ghmpb_mat(1.0, 0.0);
	float crackW = smoothstep(0.03, 0.25, sd) * saturate(1.0 - hL / 0.15) * (1.0 - fabric) * m1.x;
	float crack = 0.0;
	[branch] if (crackW > 0.0)
	{
		float2 gc;
		float cc = ghmpb_crack(f.crackPos, gc);
		// (relief of the crack edges from the analytic gradient of the crack field)
		float2 cg = gc * 0.12;
		crack = (1.0 - smoothstep(0.02, 0.09, cc)) * crackW;
		N = normalize(N + (Tt2 * cg.x + Bt2 * cg.y) * 2.0 * crack);
	}
	// blood films are never perfectly even (cell streaming, wetting, the surface below): a gentle, two-scale variation of
	// the optical thickness (1.20.0: +-15 %, was +-30 % - thinner spots let the floor show through like a tinted liquid)
	float nv = 0.6 * ghmpb_vnoise(f.crackPos * 0.9 + 11.0) + 0.4 * ghmpb_vnoise(f.crackPos * 3.1 + 5.0);
	float hOpt = hL * lerp(0.85, 1.15, nv);

	// ---------------- normals: surface detail is filled in by thick films (q.Nb), film height and beads add relief
	// any continuous liquid film is glossy, however thin
	// Wetness setting (1.20.0, ghmpb_pool_look 0..2, 1 = physical): how wet the blood looks - higher, thinner films still
	// read as a liquid (glossy, deep); lower, the blood looks tacky and dull, as if it had begun to dry
	float wv = max(ghmpb_poolLookAt(max(SC1.y, -hL)), 0.1);
	float wet = smoothstep(0.003, 0.03, hL * wv);
	float w3s = max(SC3.w, -wet);
	// running blood: two-phase advected ripples along the flow - stretched along it into streaks (the fine lines a running
	// film shows), the normal tilted across them. Only where it really runs: a standing pool is a still mirror (1.20.0: the
	// slow swell 1.18 laid over every fresh pool made it wobble like jelly - gone)
	float flowVar = 0.0;
	[branch] if (f.flowSpeed > 0.05 && wet > 0.0 && cf < 0.9 && ghmpb_frostAt(w3s) < 0.9)
	{
		float period = 0.8;
		float ph0 = frac(SC0.w / period), ph1 = frac(SC0.w / period + 0.5);
		float wgt = abs(ph0 - 0.5) * 2.0;
		float2 fu = f.flowUV;
#ifndef GHMPB_FLOWV
#define GHMPB_FLOWV 3
#endif
#if GHMPB_WORLD && GHMPB_FLOWV >= 2
		// (1.26.10) the flowing surface the way fluid simulations draw it (GHM: "the bloodpooling fluid needs flowing normal
		// mapping like how fluid sims do it"): a fine ripple normal map - value-noise gradients in cells of 5 mm, drawn out a
		// little along the flow the faster it runs - carried along with the blood at its real speed and direction. Two copies
		// half a period apart, each started afresh while the other one is at full weight (the flow-map technique): the ripples
		// travel with the liquid and never smear out. Stronger the faster and the shallower the blood runs, gone once it gels,
		// faded out with distance (where 5 mm cells would only sparkle). Replaces 1.26.9d's streaks and cross ripples; the
		// relief of the simulated height is kept only at the edges now (ghmpb_surface_main.h)
		float sp = min(f.flowSpeed, 25.0);
		float st = 1.0 + 0.12 * min(sp, 10.0);
		// (cells of 0.5 cm: flowPos is 3 per 40 u patch, 1 = 25.4 cm)
		float2 p = float2(dot(f.flowPos, fu) / st, dot(f.flowPos, float2(-fu.y, fu.x))) * 50.8;
		float adv = sp * (2.0 * period) / st;
		float2 g0 = ghmpb_vnoise_grad(p - float2(adv * ph0, 0.0));
		float2 g1 = ghmpb_vnoise_grad(p + float2(17.3, 5.1) - float2(adv * ph1, 0.0));
		float am = saturate(sqrt(f.flowSpeed / (1.0 + 2.0 * hL))) * wet * (1.0 - cf) * saturate((260.0 - length(gEye - P)) / 140.0);
		float2 rg = lerp(g0, g1, wgt) * am;
		float3 Fw = normalize(f.flowW - Ng * dot(f.flowW, Ng) + 1e-5);
		N = normalize(N - (Fw * (rg.x * (0.14 / st)) + cross(Ng, Fw) * (rg.y * 0.14)));
		// (the ripples' slope variation widens the highlight - specular anti-aliasing: without it the sun's glint on them broke
		// up into single white pixels. 1.26.10b: from the ripples' strength, the same all over the rippled blood - worked out
		// from the slope at each pixel it was nil on every crest and trough, and those pixels still glittered white)
		flowVar = am * am * 0.03;
#else
		float2 p = float2(dot(f.flowPos, fu), dot(f.flowPos, float2(-fu.y, fu.x))) * float2(18.0, 84.0);
		float adv = min(f.flowSpeed, 30.0) * (0.004 * 18.0 * period);
		float2 g0 = ghmpb_vnoise_grad(p - float2(adv * ph0, 0.0));
		float2 g1 = ghmpb_vnoise_grad(p + float2(17.3, 5.1) - float2(adv * ph1, 0.0));
#if GHMPB_WORLD && GHMPB_FLOWV == 1
		// (1.26.9d) visible already at the slow creep of a spreading pool, stronger the faster and the shallower the blood
		float2 rg = lerp(g0, g1, wgt) * saturate(sqrt(f.flowSpeed / (1.5 + 3.0 * hL))) * wet * (1.0 - cf);
#else
		float2 rg = lerp(g0, g1, wgt) * saturate(f.flowSpeed / 6.0) * wet * (1.0 - cf);
#endif
		float3 Fw = normalize(f.flowW - Ng * dot(f.flowW, Ng) + 1e-5);
		N = normalize(N - (Fw * rg.x * 0.012 + cross(Ng, Fw) * rg.y * 0.05));
#endif
	}
	// froth on the blood (world floors, 1.19.0) / of boiling and fizzing blood (models, 1.17.0)
	float foam = 0.0;
	float fresh = wet * (1.0 - cf) * smoothstep(0.08, 0.6, hL) * (1.0 - ghmpb_frostAt(w3s));
	// air bubbles caught in fresh blood: a few in a bright spurt, many in frothy blood from the lungs; they burst as it gels
	// (fine detail: faded out with distance, where it would only sparkle). Froth (f.froth, world floors): a dense raft of
	// them, lighter than the blood (the thin bubble walls scatter), each a little dome with its own glint; far away only
	// the lighter raft is seen, not the single bubbles
	// (1.25.0: fewer - bright blood carried a bubble in up to every other cell of the grid and froth at the rim of a stamp
	// showed as a pale dotted ring; only really frothy blood is covered with them now)
#ifndef GHMPB_SMALLBUB
#define GHMPB_SMALLBUB 0
#endif
#if !GHMPB_WORLD || GHMPB_SMALLBUB
	float bubD = saturate(max((f.oxy - 0.82) * 1.2, f.froth * 1.6) * 2.0) * fresh;
	[branch] if (bubD > 0.02)
	{
		float detail = saturate(2.2 - length(gEye - P) / 110.0);
#if GHMPB_WORLD
		// (1.26.9d: the lighter raft much weaker on floors - the big bubbles show the froth, the pool stays dark)
		foam = f.froth * fresh * (1.0 - detail) * 0.08;
#endif
		[branch] if (bubD * detail > 0.02)
		{
			float2 abg;
#if GHMPB_WORLD
			// (1.26.9d) on floors frothy blood shows mostly as the big bubbles (ghmpb_bigBubble, drawn after the film shading):
			// fewer of the small ones, which read as pale dots
			float bh = ghmpb_airBubble(f.crackPos * lerp(1.7, 2.6, saturate(f.froth * 3.0)), lerp(0.22, 0.7, saturate(f.froth * 2.0)) * bubD * detail * 0.45, abg);
#else
			float bh = ghmpb_airBubble(f.crackPos * lerp(1.7, 2.6, saturate(f.froth * 3.0)), lerp(0.22, 0.7, saturate(f.froth * 2.0)) * bubD * detail, abg);
#endif
			N = normalize(N - (Tt2 * abg.x + Bt2 * abg.y) * lerp(0.035, 0.07, saturate(f.froth * 2.0)));
#if GHMPB_WORLD
			foam += bh * saturate(f.froth * 2.0) * detail * 0.2;
#endif
		}
	}
#endif
	// (1.26.9d) on world surfaces froth shows only as the big bubbles (ghmpb_bigBubble, drawn after the film shading in
	// ghmpb_surface_main.h): no small air bubbles or lighter raft there any more - they read as pale dots, and the live
	// surface shader sits at the ps_3_0 limit of 4096 instruction slots (a few more and D3D9 refuses to create it)
	// boiling / fizzing: bubbles swell and burst on the wet blood (1.17.0)
#if !GHMPB_WORLD
	float bubA = max(ghmpb_boil(), ghmpb_fizz()) * smoothstep(0.02, 0.15, hL) * (1.0 - ghmpb_frostAt(w3s));
	[branch] if (bubA > 0.01)
	{
		float2 bg;
		float fz = step(ghmpb_boil(), ghmpb_fizz());
		float bh = ghmpb_bubble(f.crackPos * lerp(0.4, 0.7, fz), SC0.w * lerp(1.1, 2.6, fz), bg);
		N = normalize(N - (Tt2 * bg.x + Bt2 * bg.y) * 0.12 * bubA);
		foam = bh * bubA;
	}
#endif
	// clot skin: fine wrinkles on gelled blood
	// (only once the blood has really gelled, and a few texels across: finer detail only aliases into glitter)
	float gel = smoothstep(0.6, 0.95, cf);
	[branch] if (gel > 0.0 && hL > 0.04)
	{
		float2 wg = ghmpb_vnoise_grad(f.crackPos * 1.3) + 0.5 * ghmpb_vnoise_grad(f.crackPos * 2.9 + 7.0);
		// a congealed pool is lumpy - the clot pulls together into soft, darker lumps with thinner blood between
		float lw = gel * smoothstep(0.12, 0.6, hL);
		float2 lp = f.crackPos * 0.45 + 3.3;
		float2 lg = ghmpb_vnoise_grad(lp);
		hOpt *= lerp(1.0, 0.7 + 0.6 * ghmpb_vnoise(lp), lw);
		float wa = 0.03 * gel * saturate(hL / 0.3);
		N = normalize(N - (Tt2 * (wg.x * wa + lg.x * 0.05 * lw) + Bt2 * (wg.y * wa + lg.y * 0.05 * lw)));
	}

	// ---------------- what the shape of the film does to the diffuse light
	// 1.20.0: wet blood is a liquid - its colour comes from the light scattered inside it, not from a lit solid surface, so
	// beads and pool rims are no longer shaded like solid domes by the light probe (that read as jelly); their shape shows
	// in the reflections. Only the meniscus darkens: where the liquid surface stands steeply, the floor under it is seen
	// bent away through the curved surface and most of what reaches the eye there is reflection. A dried crust is a solid:
	// its cracks and flakes are lit by the light probe like the relief they are.
	float relW = saturate(sd * 4.0) * (1.0 - wet) * (1.0 - fabric * 0.7);
	float relief = 1.0;
	[branch] if (relW > 0.0)
	{
		float3 Esh0 = ghmpb_shIrradiance(Nb, SC15, SC16, SC17);
		relief = clamp(ghmpb_luma(ghmpb_shIrradiance(N, SC15, SC16, SC17)) / max(ghmpb_luma(Esh0), 1e-3), 0.65, 1.5);
	}
	o.dmul = lerp(1.0, relief, relW) * (1.0 - 0.3 * rimT * wet * (1.0 - 0.6 * cf));
#if GHMPB_WORLD
	// froth (1.19.0): lighter than the blood under it - the blood's own colour brightened, plus a pale pink veil (seeded into
	// the highlights below: kept as a value of its own through the lights' loop, it took a temp register)
	o.dmul *= 1.0 + 1.6 * foam;
#endif

	// ---------------- specular: a dielectric top coat, energy conserving
	// wet blood n ~ 1.39 -> F0 = 0.027; a dried protein crust n ~ 1.5 -> F0 = 0.04. 1.20.0: no more boosts - the 1.19 pool
	// look raised F0 to ~0.06 and the reflection weight by half, the key light was widened into a broad sheen: a lacquer,
	// candy look. A real pool is dark and reads as wet through sharp, Fresnel-weighted reflections of what is around it.
	float3 V = normalize(gEye - P);
	float NoV = saturate(dot(N, V));
	float Esh = ghmpb_luma(ghmpb_shIrradiance(Nb, SC15, SC16, SC17));
	float k = clamp(ghmpb_luma(E) / max(Esh, 1e-3), 0.0, 6.0);   // light units -> framebuffer units
#if GHMPB_WORLD
	// (1.26.10b) where the normal varies a lot inside the pixel - the texel-sized relief at a pool's rim, the floor's grain
	// under thin blood - the sharp highlights of the sun and the lamps are dimmed (their spread is in the roughness, below):
	// each of those pixels caught the sun on its own, white salt over a pool facing it
	k /= 1.0 + 150.0 * q.nvar;
#endif
	float ser = saturate(f.serum);
	float4 m0 = ghmpb_mat(0.0, 0.0);
	float soakF = m0.x * ghmpb_matFresh(m0.w) * (1.0 - ser);
	float dryC = (1.0 - exp(-sL * 6.0)) * (1.0 - 0.75 * crack);
	float wetSpec = wet * (1.0 - 0.55 * fabric * saturate(1.0 - hL / 0.5));    // soaked cloth is dull, pooled blood on it is not
	float drySpec = (1.0 - wet) * dryC * (1.0 - 0.85 * soakF);                  // the crust is a dielectric too (none soaked in)
	wetSpec = max(wetSpec, ser * 0.22);                                        // (1.26.9c: dried serum only a faint sheen, was 0.8 - a bright line)
	float specW = wetSpec + drySpec;
	float F0s = lerp(GHMPB_F0_DRY, GHMPB_F0_WET, wet);
	// roughness: the free surface of a liquid has no micro roughness of its own - a pool levels whatever is under it into a
	// mirror; a thin film still follows the micro relief of skin, stone or cloth. Gelled blood keeps a glossy, faintly
	// satin skin (clotted blood still looks wet). A dried crust: glassy where it was thick (a dried pool is a glossy
	// black-red sheet), matte on thin smears and where it soaked in
	float rLiquid = lerp(0.32, 0.03, saturate(wv));
#if GHMPB_WORLD
	float rough = lerp(max(roughSub, 0.12), rLiquid, smoothstep(0.02, 0.2, hL * wv));
#else
	float rough = lerp(max(roughSub, 0.12), rLiquid, smoothstep(0.01, 0.12, hL * wv));
#endif
	rough = lerp(rough, 0.13, gel * saturate(hL / 0.05));
	float rDry = lerp(lerp(0.6, 0.22, smoothstep(0.1, 0.8, sL)), 0.8, soakF);
	rough = lerp(lerp(roughSub, rDry, dryC), rough, wet);
	rough = lerp(rough, 0.75, fabric * saturate(1.0 - hL / 0.4));
	rough = lerp(rough, 0.035, ghmpb_frostAt(w3s) * wet * 0.85);               // frozen: a glassy glaze of ice
#if !GHMPB_WORLD
	rough = lerp(rough, 0.7, ghmpb_char() * (1.0 - wet));                  // char: matte
	rough = lerp(rough, 0.45, saturate(foam * 1.5));                       // froth
#endif
	rough = saturate(rough / max(gloss, 0.2));
	// specular anti-aliasing: widen the lobe by the normal variation inside the pixel, so ripples and bead
	// rims shimmer less and distant pools do not sparkle
	float a2 = rough * rough * rough * rough + min(4.0 * q.nvar + flowVar, 0.18);
	rough = max(sqrt(sqrt(a2)), 0.02);
	// The real lights, one after the other in a loop (written out, the compiler worked them out at once and the shader ran
	// out of temp registers):
	//   0 the sun
	//   1 the flashlight: its radiance is already in framebuffer units; the lobe is widened by its beam spread and a
	//     single glint is capped
	// (1.20.0: the "key light" - the dominant direction of the light probe, an estimate - no longer draws a highlight: it
	// only ever made a broad sheen, the plastic look. The lamps of the map are in the cubemap / the screen-space reflection,
	// where they are reflected sharply, as they are on a liquid.)
	float3 Lf;
	float3 flash = ghmpb_flashlight(P, N, V, rough, Lf);
#if GHMPB_WORLD
	float3 spec = (foam * 0.06 / max(specW, 0.05)) * float3(1.0, 0.62, 0.6) * E;
	// (1.25.1) the meniscus glint (see below - the bodies work it out after the lights): on the world films only the
	// flashlight's, here, seeded into the highlights before the lights' loops - anywhere later the world shader ran out of
	// temp registers
	{
		float slopeW = length(f.slope);
		float rimW = wet * saturate(slopeW * 14.0) * (1.0 - cf) * ghmpb_flashOn();
		[branch] if (rimW > 0.01)
		{
			float3 Nw = normalize(Nb - f.slope / max(slopeW, 1e-5) * (1.43 * saturate(slopeW * 10.0)));
			float3 Lw;
			float3 fw = ghmpb_flashlight(P, Nw, V, 0.12, Lw);
			spec += rimW * min(ghmpb_specGGX(Nw, V, Lw, fw, F0s.xxx, 0.12), 1.5) / max(specW, 0.05);
		}
	}
#else
	float3 spec = 0;
#endif
	[loop] for (int li = 0; li < 2; li++)
	{
		float3 L = normalize(li == 0 ? SC11.xyz : Lf);
		float3 rad = li == 0 ? SC12.rgb * (SC11.w * k) : flash;
		float rl = li == 0 ? rough : saturate(rough + 0.08);
		spec += min(ghmpb_specGGX(N, V, L, rad, F0s.xxx, rl), li == 0 ? 100.0 : 1.5);
	}
	// (1.25.0) the strongest lights around the blood group - lamps of the map, dynamic lights, projected textures, other
	// players' flashlights (cl_probes.lua: picked and checked for a clear line to the group on the CPU) - each its own
	// highlight. Types: 1 point, 2 spot (light units, like the light probe: x k), 3 spot in framebuffer units (flashlights)
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
			spec += min(ghmpb_specGGX(N, V, Ll, lrad, F0s.xxx, ltype > 2.5 ? saturate(rough + 0.08) : rough), 4.0);
		}
	}
	// (1.25.1) the meniscus: where a pool, a drop or a run ends, its liquid surface bends down to the surface it lies on at
	// the contact angle - a band facing outwards that catches a light the level top never can (a flashlight held at the eye
	// glints along the near rim of a pool, a lamp along the side facing it). The band is far narrower than a texel: its
	// normal is taken from how steeply the film's edge rises here (f.slope, the gradient of the visible height), tilted out
	// by up to ~55 deg. Worked out after the lights' loops, only on the rims (inside them the shader is at its temp register
	// limit): the flashlight, the sun and the strongest lights of the group once more
	// (the world films do it after their colour - ghmpb_surface_main.h: here they are at their temp register limit)
#if !GHMPB_WORLD
	float slopeL = length(f.slope);
	float rimG = wet * saturate(slopeL * 14.0) * (1.0 - cf);
	[branch] if (rimG > 0.01)
	{
		float3 Nr = normalize(Nb - f.slope / max(slopeL, 1e-5) * (1.43 * saturate(slopeL * 10.0)));
		float3 Lr;
		float3 fr = ghmpb_flashlight(P, Nr, V, 0.12, Lr);
		float3 rimS = min(ghmpb_specGGX(Nr, V, Lr, fr, F0s.xxx, 0.12), 1.5);
		rimS += min(ghmpb_specGGX(Nr, V, normalize(SC11.xyz), SC12.rgb * (SC11.w * k), F0s.xxx, 0.12), 1.5);
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
				rimS += min(ghmpb_specGGX(Nr, V, Rl, rrad, F0s.xxx, 0.12), 1.5);
			}
		}
		spec += rimS * rimG;
	}
#endif
	// Shine setting (ghmpb_reflections, 1 = physically correct): the highlights as well as the reflections (1.20.0)
#ifndef GHMPB_MOVESHINE
#define GHMPB_MOVESHINE 1
#endif
#if GHMPB_WORLD && !GHMPB_STATIC && GHMPB_MOVESHINE
	// (1.26.9d) blood that is moving - running, a pool spreading on, the ring wave a drop sends out, the welling where a
	// body bleeds in - is a fresh, glossy liquid surface: its shine rises with the flow (up to 8x at 2 cm/s, close to the
	// physical value at the default Shine), so the moving surface and its ripples read, while a settled pool keeps the
	// deep, matt look of G.SHADER_COMP.refl
	float mvS = 7.0 * saturate(f.flowSpeed * 0.5);
#else
	float mvS = 0.0;
#endif
	// (1.26.10) and fresh blood is a liquid however still it lies: its highlights shine more (ghmpb_freshShine, from "Fresh
	// blood wetness": 4x at the default) until it gels; the reflection of the surroundings (o.Fr below) takes only 30 % of
	// that - at full strength the blurred probe and the screen's floor beyond the pool laid a milky grey veil over fresh
	// pools. Together with the flow at most 8x
	float frW = wet * (1.0 - cf);
	float rS = ghmpb_reflScale() * min(1.0 + (ghmpb_freshShine() + mvS) * frW, 8.0);
	spec *= specW * rS;
	// (rS from here on the reflection's: worked out now, so the flow and fresh factors are not kept to the end - that ran
	// the shader out of temp registers)
	rS = ghmpb_reflScale() * min(1.0 + (0.3 * ghmpb_freshShine() + mvS) * frW, 8.0);
	// ice crystals poking through thin blood glint in the sun / key light (snow, ice): a few cells, each its own facet
	float spark = ghmpb_mat(1.0, 0.3).y;
	[branch] if (max(spark, ghmpb_frostAt(w3s)) > 0.0)
	{
		float2 gc = floor(f.crackPos * 2.5);
		float gh = ghmpb_hash12(gc);
		float cell = step(0.93, gh) * max(spark * saturate(1.0 - hL / 0.15), ghmpb_frostAt(w3s) * 0.8);
		float3 Nj = normalize(N + (float3(ghmpb_hash12(gc + 3.7), ghmpb_hash12(gc + 8.1), 0.5) - 0.5) * 0.9);
		// (the brighter of the sun and the key light: one glint per facet)
		bool sun = ghmpb_luma(SC12.rgb * SC11.w) > ghmpb_luma(SC3.rgb) * 0.5;
		// (a tight Blinn-Phong lobe: the facet's glint is capped anyway)
		float3 Ls = normalize(sun ? SC11.xyz : SC2.xyz);
		float gs = pow(saturate(dot(Nj, normalize(Ls + V))), sun ? 2400.0 : 900.0) * saturate(dot(Nj, Ls)) * 40.0;
		spec += min((sun ? SC12.rgb * SC11.w : SC3.rgb * 0.5) * (gs * k * cell), 2.0);
	}
	spec = min(spec, 2.0);

	// ---------------- reflection: the blood group's reflection probe (1.25.0: a cube map rendered from the middle of the
	// group, refreshed while the game runs - it holds what really stands round the blood, lamps lit or not, bodies, the
	// player; before, the map's baked cubemap); the world shader mixes the scene itself over it where the screen has it
	float3 R = reflect(-V, N);
	float3 envC = ghmpb_probeEnv(P, R, rough);
	// (a probe still holding the map's cubemap - baked for a whole area - is kept from glowing in dark corners: specular
	// occlusion from the local light level; a rendered probe saw the real light there)
	envC *= ghmpb_pt(385.0, 0.0).w > 0.5 ? 1.0 : envOcc;
	// light arriving from the reflected direction according to the local light probe (never less than that)
	envC = max(envC, ghmpb_shIrradiance(R, SC15, SC16, SC17) * k * GHMPB_INV_PI);
	// reflections that would come from below the surface are occluded by it (horizon occlusion)
	float ho = saturate(1.0 + 1.1 * dot(R, Ng));
	o.Fr = ghmpb_envBRDFApprox(F0s.xxx, rough, NoV) * specW * ho * ho * rS;
	o.col = spec + envC * o.Fr;
	o.env = envC;
	o.N = N;
	o.V = V;
	o.hOpt = hOpt;
	o.crack = crack;
	o.foam = foam;
	return o;
}

// the colour: Kubelka-Munk layers (dried stain, then wet blood) over the surface, lit by the irradiance recovered from
// the lit framebuffer, plus what ghmpb_filmSpec worked out
float3 ghmpb_filmDiffuse(float3 fb, float3 E, GHMPB_Film f, GHMPB_Pre q, GHMPB_Spec sp, float absorbScale, float stainDark)
{
	// the two blood types of this layer, mixed per pixel by volume (absorption of a mixture = volume-weighted
	// absorption of its parts, Beer-Lambert)
	// (the settings decoded here, from the constants tied to the end of ghmpb_filmSpec - see ghmpb_frostAt)
	float lateX = sp.Fr.x;
	float pairC = ghmpb_pairCodeAt(max(SC1.y, -lateX));
	float4 tw = ghmpb_mixW(pairC, f.alt);
	// (1.26.10c) the spectra of the pair's type from 3 up (zombie, synth, oil, blue, purple - see ghmpb_otherWet4)
	// (on the world, worked out once; on bodies where they are used - the body shaders are short of temp registers)
	// (1.26.10e) per pixel: with two types from 3 up in the pair, the one this pixel holds more of
#ifdef GHMPB_NO_TYPEFIX
	float tO = ghmpb_otherType(pairC);
#else
	float tO = ghmpb_otherTypeAt(pairC, f.alt);
#endif
#if GHMPB_WORLD
	float4 zWet = ghmpb_otherWet4(tO), zDry = ghmpb_otherDry4(tO);
#define GHMPB_ZWET zWet
#define GHMPB_ZDRY zDry
#else
#define GHMPB_ZWET ghmpb_otherWet4(tO)
#define GHMPB_ZDRY ghmpb_otherDry4(tO)
#endif
	float w3 = max(SC3.w, -lateX);
	float w1 = max(SC1.w, -lateX);
	float fabric = ghmpb_fabricAt(w1);
	float4 hueM = ghmpb_hueMul(ghmpb_hueAt(max(SC1.z, -lateX)));
	float h = q.h, s = q.s, cf = q.cf;
	float hL = q.hL, sL = q.sL;
	float hOpt = sp.hOpt;
#if GHMPB_WORLD
	// (1.26.9c) fresh droplets, spatter and the thin edge of a pool keep a deep, saturated red, not a pale see-through orange:
	// a very thin wet film is drawn with a little more optical depth (1.26.9d: up to 1.3x, fading out by 0.2 mm - with the
	// darker pools of 1.26.9d the thin edges and spatter stay a brighter red than the near-black middle of a pool)
	hOpt *= lerp(1.3, 1.0, smoothstep(0.03, 0.2, hOpt));
#endif
	// clotting blood loses its oxygen: crimson -> maroon; the patch / body oxygenation sets the start
	// (frozen and cooking blood go darker too)
	float oxy = saturate(f.oxy) * (1.0 - 0.85 * cf) * (1.0 - 0.5 * ghmpb_frostAt(w3)) * (1.0 - 0.7 * ghmpb_boilAt(w3));
	// drying drops and smears pile their solids up at the rim (coffee-ring effect): darker edges
	float dryness = saturate(s / max(s + h, 1e-3));
	// (1.25.0: darker - a dried stain's rim holds most of its solids)
	float ringDark = 1.0 + 2.6 * saturate(f.ring) * saturate(1.0 - h / 0.1) * (0.4 + 0.6 * dryness);
	float ser = saturate(f.serum);
	// irradiance recovered from the lit framebuffer (shadows, lightmaps, flashlight, dynamic lights): low
	// frequency on world surfaces (so the floor texture does not print through a pool), exact on models
	// (the model's own texture is the albedo); the surface's own reflectance per pixel is whatever the
	// framebuffer shows under that light - with no blood the result is exactly the framebuffer
	float3 Rpx = min(fb / max(E, 1e-4), 0.96);
	// cloth: blood wicks into the fibres, and the wet cloth around it darkens
	float soak = fabric * saturate((hL + sL) * 5.0);
	float4 Rg = ghmpb_toBands(Rpx * (1.0 - 0.4 * soak));
	// The two layers one after the other in a loop, each worked out inside its own branch (1.18.0: written out, the
	// compiler prepared both layers' four-band values at once and the shader ran out of temp registers)
	//   layer 0: the dried stain / crust (cracks open it up; serum dries to a clear, pale yellow film). Blood soaked into a
	//     porous surface is not a crust: it keeps the colour of the (dark, deoxygenated) blood, browning only as it ages,
	//     and the grains around it scatter (snow, sand: brighter and pinker) - 1.16.0. Burnt (bodies in a fire): the crust
	//     chars to carbon - black, hardly scattering
	//   layer 1: the wet blood. A clot scatters more (fibrin, packed cells); serum is nearly clear; cooking blood browns
	//     (heat-denatured haemoglobin) towards the dried colour
	float4 m0 = ghmpb_mat(0.0, 0.4);
	float soakF = m0.x * ghmpb_matFresh(m0.w) * (1.0 - ser);
	// how far the dried blood has aged (1.20.0): oxy- / met-haemoglobin (red-brown) -> haemichrome (brown-black) over the
	// time since the aftermath layer settled; live layers are freshly dried
#if GHMPB_STATIC
	float age = smoothstep(0.5, 4.0, floor(max(SC13.w, -lateX)) / 64.0);
#else
	float age = 0.0;
#endif
	float4 R2 = Rg;
	[loop] for (int ly = 0; ly < 2; ly++)
	{
		float4 K, S;
		float d;
		[branch] if (ly == 0)
		{
			// (1.25.0) dried blood is never one even colour: how thick it lay, how fast it dried and how far it has aged vary
			// over a stain - browner and redder patches, denser and lighter ones
			float dv1 = ghmpb_vnoise(f.crackPos * 0.16 + 5.3);
			float dv2 = ghmpb_vnoise(f.crackPos * 0.55 + 1.7);
			float ageL = saturate(age + 0.5 * (dv1 - 0.4));
			float4 KdDry = ghmpb_muaDry4WZ(tw, ageL, GHMPB_ZDRY) * hueM * stainDark * ghmpb_dryMulAt(w1) * ringDark * lerp(0.72, 1.32, dv2);
			float4 KdSoak = ghmpb_muaWet4WZ(tw, oxy * 0.7, GHMPB_ZWET) * hueM * absorbScale * m0.y * lerp(1.0, ringDark, 0.5);
			K = 2.0 * lerp(lerp(KdDry, KdSoak, soakF), float4(0.1, 0.1, 0.3, 1.6), ser);
			S = ghmpb_musDry4W(tw, ageL) * lerp(1.0, m0.z, soakF) * (1.0 - 0.9 * ser);
#if !GHMPB_WORLD
			float chr = ghmpb_char();
			K = lerp(K, float4(70.0, 70.0, 72.0, 74.0), chr);
			S *= 1.0 - 0.75 * chr;
#endif
			d = sL * (1.0 - 0.75 * sp.crack);
		}
		else
		{
			K = 2.0 * lerp(ghmpb_muaWet4WZ(tw, oxy, GHMPB_ZWET) * hueM * absorbScale, float4(0.05, 0.05, 0.12, 0.9), ser);
			K = lerp(K, 2.0 * ghmpb_muaDry4WZ(tw, 0.5, GHMPB_ZDRY) * hueM, 0.45 * ghmpb_boilAt(w3));
			S = 0.75 * ghmpb_musWet4() * (1.0 + 0.6 * cf) * (1.0 - 0.95 * ser);
			d = hOpt;
		}
#undef GHMPB_ZWET
#undef GHMPB_ZDRY
		// (1.25.0) thick blood is opaque: past a few tenths of a mm (a dried crust a little more) nothing of the surface
		// under it shows through - the background below the layer gives way to the layer's own reflectance (R inf, the
		// fixed point of the layer), so a pool shows only the blood's colour, never the floor under it
		float4 ak = 1.0 + K / S;
		// (1.26.10e) GHM: "its blood like in my mind it isnt see through" - wet blood is opaque from 0.18 mm (was 0.45 mm). The
		// simulated film is capped at about 0.3 mm, so no pool was ever fully opaque: a third of the floor showed through
		// the middle of a pool, more with the lighter 1.26.10e reds. Thin smears and spatter (below ~0.1 mm) stay see-through
		R2 = lerp(R2, ak - sqrt(ak * ak - 1.0), smoothstep(ly == 0 ? 0.2 : 0.03, ly == 0 ? 0.7 : 0.18, d));
		R2 = ghmpb_km(K, S, d, R2);
	}
	// the liquid surface (Saunderson correction, n = 1.35): light scattered back up inside the liquid meets
	// the surface from all angles and about half of it is totally internally reflected back down - it takes
	// another trip through the blood before it gets out. This is why anything wet looks darker and more
	// saturated than dry, and why a pool is a deep crimson rather than brick red
	// (the Wetness setting: thinner films count as liquid; below 1 the wet darkening fades towards the look of a dull,
	// tacky film)
	float wv2 = max(ghmpb_poolLookAt(max(SC1.y, -lateX)), 0.1);
	float wetI = smoothstep(0.004, 0.04, hOpt * wv2) * saturate(0.4 + 0.6 * wv2);
	R2 = lerp(R2, 0.94 * 0.52 * R2 / (1.0 - 0.48 * R2), wetI);
	// a continuous dried crust has a surface of its own (n ~ 1.5) that traps some of the light scattered inside it: dried
	// blood that kept its surface is darker and richer than blood soaked into a porous surface (1.20.0)
	R2 = lerp(R2, 0.96 * 0.6 * R2 / (1.0 - 0.4 * R2), (1.0 - wetI) * smoothstep(0.02, 0.2, sL) * (1.0 - soakF) * (1.0 - fabric));
	// froth on boiling blood (brownish pink) and acid (yellow-green); hoarfrost on frozen blood: white crystals,
	// thick on thin films and edges, sparse on deep pools (1.17.0)
#if !GHMPB_WORLD
	R2 = lerp(R2, ghmpb_fizzAt(w3) > ghmpb_boilAt(w3) ? float4(0.42, 0.42, 0.5, 0.12) : float4(0.32, 0.26, 0.12, 0.09), saturate(sp.foam * 0.7));
#endif
	[branch] if (ghmpb_frostAt(w3) > 0.01)
	{
		// (a fine, thin veil over the red - 1.17.0 in game: the coarse, strong version turned frozen pools into
		// white-and-grey blotches)
		float rime = ghmpb_frostAt(w3) * (smoothstep(0.45, 0.85, ghmpb_vnoise(f.crackPos * 3.2 + 4.2)) * (1.0 - 0.8 * smoothstep(0.05, 0.6, hL)) + 0.1);
		R2 = lerp(R2, float4(0.72, 0.72, 0.75, 0.8), saturate(rime) * 0.32);
	}
	float3 diff = E * ghmpb_bands(R2) * sp.dmul;

#if GHMPB_WORLD
	// (world: the debug view decoded here from SC2.w = smooth + 4 debug + 32 material, tied to the end of ghmpb_filmSpec - as
	// a value kept from the top of the shader it took a temp register through all of it; 1.19.0)
	float dbg = floor(frac(max(SC2.w, -sp.Fr.x) / 32.0) * 8.0);
#else
	float dbg = gDbg;
#endif
	if (dbg > 0.5 && dbg < 1.5) return float3(saturate(hOpt / 3.0), saturate(sL / 0.5), saturate(h + s) * 0.25);
	if (dbg > 1.5 && dbg < 2.5) return diff * (1.0 - sp.Fr);
	if (dbg > 2.5 && dbg < 3.5) return sp.col;
	if (dbg > 3.5) return ghmpb_bands(R2);
	// energy: what the surface reflects specularly does not enter the blood
	float3 col = diff * (1.0 - sp.Fr) + sp.col;
	// glow (1.17.0): electricity running through the wet blood (flickering blue-white), radioactive green, embers in
	// charred blood, plasma violet
	float glow = ghmpb_glowAt(w3);
	[branch] if (glow > 0.01)
	{
		float wet = smoothstep(0.003, 0.03, hL);
		float gT = ghmpb_glowTAt(w3);
		// (one noise: flicker for electricity, the ember pattern for embers)
		float nz = ghmpb_vnoise(f.crackPos * 0.3 + SC0.w * float2(9.0, 0.6));
		float3 gc = gT < 1.5 ? float3(1.2, 1.65, 2.2) : (gT < 2.5 ? float3(0.21, 0.7, 0.18) : (gT < 3.5 ? float3(1.6, 0.5, 0.06) : float3(1.2, 0.56, 1.6)));
		float gm = gT < 1.5 ? wet * (0.3 + 0.7 * nz) : (gT < 3.5 && gT > 2.5 ? saturate(sL * 3.0) * (1.0 - wet) * smoothstep(0.5, 0.85, nz) : saturate((hL + sL) * 4.0));
		col += gc * gm * glow;
	}
	return col;
}

// both parts (models: no screen-space reflection)
float3 ghmpb_shadeFilm(float3 fb, float3 fbSmooth, float3 albedo, float3 Ng, float3 P, GHMPB_Film f, GHMPB_Pre q,
                       float gloss, float absorbScale, float stainDark)
{
	float3 E = ghmpb_irradiance(fbSmooth, albedo);
	GHMPB_Spec sp = ghmpb_filmSpec(E, saturate(ghmpb_luma(fbSmooth) * 6.0 + 0.05), Ng, P, f, q, gloss);
	return ghmpb_filmDiffuse(fb, E, f, q, sp, absorbScale, stainDark);
}
#endif
