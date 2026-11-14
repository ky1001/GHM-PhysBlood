#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): Crisis Response Blood splats for the other blood types.

GHM: "can we use the same splattering of crisis response to all the other non human blood/npcs as well, and that it
has the right color". The CRB splats are DecalModulate decals (the wall times twice the texture, in gamma space), and
that shader has no colour setting, so each blood type gets its own copies of the splats, recoloured offline:

  * per texel, the thickness of blood it stands for is fitted from the original (red) texel's red channel with
    PhysBlood's own red-blood absorption bands (cl_util.lua Bands, oxygen 0.75)
  * the same thickness of the other blood is put through that blood type's bands (the colour PhysBlood gives its stains
    and drops of that type), normalised so no blood leaves the wall as it is, and written back as 2x-modulate gamma
  * alpha (the shape) and the neutral grey under the transparent parts are kept as they are; the original size,
    format (DXT5), flags and mipmap count are kept

Types: 1 yellow (antlions, aliens), 2 green (acid), 3 zombie, 4 synth, 5 robot oil. Each gets the PICK splats (the ones
with the most blood of the 18 different patterns; 19-36 are rotated copies of 1-18), as
materials/ghm_physblood/crb/t<type>_bp<i>.vtf/.vmt, and lua/ghm_physblood/cl_crbtypes.lua lists them.

usage: make_crb_types.py <bloodplace dir with blood1..36.vtf> <addon dir> [preview.png]
"""
import sys, os, math
import numpy as np
from PIL import Image
from srctools.vtf import VTF, ImageFormats

SRC, ADDON = sys.argv[1], sys.argv[2]
PREV = sys.argv[3] if len(sys.argv) > 3 else None
OUT_M = os.path.join(ADDON, "materials", "ghm_physblood", "crb")
OUT_L = os.path.join(ADDON, "lua", "ghm_physblood", "cl_crbtypes.lua")
NPICK = 10
GAMMA = 2.2

# PhysBlood's absorption bands (cl_util.lua): red blood mixes deoxygenated and oxygenated by oxy, the others are fixed
MUA_DEOX, MUA_OX = (12.5, 1.25, 62.0, 88.0), (6.3, 0.39, 52.0, 78.0)
MUA = {1: (0.5, 0.42, 0.6, 20.0), 2: (5.0, 8.0, 1.0, 9.0), 3: (10.0, 3.5, 7.0, 22.0),
       4: (10.78, 17.60, 1.68, 1.25), 5: (25.82, 18.80, 20.95, 52.30)}
NAMES = {1: "yellow", 2: "green", 3: "zombie", 4: "synth", 5: "robot"}
CLEAR = np.array([1.07, 0.912, 0.896])


def mu_of(bt, oxy=0.75):
    if bt in MUA:
        return np.array(MUA[bt])
    return np.array([d + (o - d) * oxy for d, o in zip(MUA_DEOX, MUA_OX)])


def bands(bt, h):
    """linear transmittance (r, g, b) of a layer h, over the clear value: 1 = no blood"""
    m = mu_of(bt)
    h = np.asarray(h, np.float64)[..., None]
    T = np.exp(-2.0 * m * h)
    r = 0.25 * T[..., 0] + 0.82 * T[..., 1]
    g = 0.012 * T[..., 0] + 0.9 * T[..., 2]
    b = 0.016 * T[..., 2] + 0.88 * T[..., 3]
    return np.stack([r, g, b], -1) / CLEAR


# inverse of the red curves: transmittance -> thickness
HG = np.concatenate([np.linspace(0, 0.1, 2001), np.linspace(0.1, 4.0, 3000)[1:]])
RR, GR = bands(0, HG)[:, 0], bands(0, HG)[:, 1]   # both decreasing
def thick_r(t):
    return np.interp(-np.clip(t, RR[-1], 1.0), -RR, HG)
def thick_g(t):
    return np.interp(-np.clip(t, GR[-1], 1.0), -GR, HG)


def recolour(rgba, bt):
    """the thickness from the red texel's red channel (green and blue are near 0 in the thick drops, where they say
    nothing); the few bright red glints (red above neutral) from the green channel, scaled to the red fit (x13 matches
    the two fits on the mod's typical texel 94 37 37) and capped"""
    px = rgba.astype(np.float64) / 255.0
    a = px[..., 3]
    tr = np.clip(2.0 * px[..., 0], 0, 1) ** GAMMA
    tg = np.clip(2.0 * px[..., 1], 0, 1) ** GAMMA
    h = np.where(tr < 0.9, thick_r(tr), np.minimum(13.0 * thick_g(tg), 0.5))
    T = np.clip(bands(bt, h), 0, 1)
    tex = (T ** (1.0 / GAMMA)) / 2.0
    out = rgba.copy()
    m = a > 0
    out[..., :3][m] = np.clip(np.round(tex[m] * 255.0), 0, 255).astype(np.uint8)
    return out


def load(i):
    v = VTF.read(open(os.path.join(SRC, "blood%d.vtf" % i), "rb"))
    v.load()
    return v, np.asarray(v.get().to_PIL().convert("RGBA")).copy()


# the 18 different patterns by how much blood they hold
cov = []
for i in range(1, 19):
    _, px = load(i)
    cov.append(((px[..., 3] > 25).mean(), i))
pick = sorted(i for _, i in sorted(cov, reverse=True)[:NPICK])
print("picked", pick)

VMT = '''"DecalModulate"
{
	"$basetexture" "ghm_physblood/crb/t%d_bp%d"
	"$translucent" "1"
	"$receiveflashlight" "1"
	"$singlepassflashlight" "1"
	"$nofog" "1"
	"$decal" "1"
	"$decalscale" "0.03"
}
'''
prev_tiles = []
for bt in sorted(MUA):
    for i in pick:
        v, px = load(i)
        out = recolour(px, bt)
        nv = VTF(v.width, v.height, v.version, fmt=ImageFormats.DXT5, flags=v.flags)
        nv.get().copy_from(np.ascontiguousarray(out).tobytes(), ImageFormats.RGBA8888)
        nv.compute_mipmaps()
        with open(os.path.join(OUT_M, "t%d_bp%d.vtf" % (bt, i)), "wb") as f:
            nv.save(f)
        with open(os.path.join(OUT_M, "t%d_bp%d.vmt" % (bt, i)), "w", newline="\n") as f:
            f.write(VMT % (bt, i))
        if PREV and i == pick[0]:
            prev_tiles.append((bt, out))
    print("type", bt, NAMES[bt], "done")

lines = ["-- GHM PhysBlood: Crisis Response Blood splats recoloured for the other blood types (tools/make_crb_types.py, 1.26.7):",
         "-- materials/ghm_physblood/crb/t<type>_bp<i>, i = the splat's number in GHMPB.CRBDecals (cl_crbdata.lua).",
         "-- Red blood uses all 36 originals (bp1..36).",
         "GHMPB.CRBTypeDecals = {"]
for bt in sorted(MUA):
    lines.append("\t[%d] = { %s },   -- %s" % (bt, ", ".join(str(i) for i in pick), NAMES[bt]))
lines.append("}")
open(OUT_L, "w", newline="\n").write("\n".join(lines) + "\n")

if PREV:
    wall = np.array([205, 190, 160]) / 255.0
    tiles = []
    _, red = load(pick[0])
    for bt, px in [(0, red)] + prev_tiles:
        p = px.astype(float) / 255.0
        m = p[..., :3] * p[..., 3:] + 0.5 * (1 - p[..., 3:])
        im = np.clip(wall * m * 2, 0, 1)
        tiles.append(Image.fromarray((im * 255).astype(np.uint8)).resize((400, 400), Image.LANCZOS))
    S = Image.new("RGB", (400 * len(tiles), 400))
    for k, t in enumerate(tiles):
        S.paste(t, (k * 400, 0))
    S.save(PREV)
