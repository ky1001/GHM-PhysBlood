#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): the splat decals of GHM's Crisis Response Blood Mod
(materials/decals/bloodplace/blood1..36 of Crisis_Response_Blood_Mod_0.3.0 (update 1)) for PhysBlood.

The textures are copied byte for byte (1024 x 1024 DXT5, 8-bit alpha, neutral grey under the transparent parts, as
made for the mod). A first build re-encoded them at 512 px with one-bit alpha to save space: that turned the transparent
texels black, which gave every drop a black rim through DecalModulate, and made the 2-3 px drops blocky squares.

Writes materials/ghm_physblood/crb/bp1..36.vtf (copies), bp1..36.vmt (the original VMT's settings: DecalModulate,
$decalscale 0.03 = 30.72 units across at scale 1), and lua/ghm_physblood/cl_crbdata.lua: per decal the radius holding
85 % of its blood (over the texture's width) and where its blood centre sits, so the game can size each splat.

usage: make_crb_decals.py <bloodplace dir with blood1..36.vtf> <addon dir>
"""
import sys, os, shutil
import numpy as np
from srctools.vtf import VTF

SRC, ADDON = sys.argv[1], sys.argv[2]
OUT_M = os.path.join(ADDON, "materials", "ghm_physblood", "crb")
OUT_L = os.path.join(ADDON, "lua", "ghm_physblood", "cl_crbdata.lua")
SCALE = 0.03
os.makedirs(OUT_M, exist_ok=True)

VMT = '''"DecalModulate"
{
	"$basetexture" "ghm_physblood/crb/bp%d"
	"$translucent" "1"
	"$receiveflashlight" "1"
	"$singlepassflashlight" "1"
	"$nofog" "1"
	"$decal" "1"
	"$decalscale" "%.2f"
}
'''

rows = []
sizes = []
W = None
for i in range(1, 37):
    src = os.path.join(SRC, "blood%d.vtf" % i)
    v = VTF.read(open(src, "rb"))
    v.load()
    sizes.append(v.width)
    W = max(W or 0, v.width)
    a = np.asarray(v.get().to_PIL().convert("RGBA"))[..., 3].astype(np.float64) / 255.0
    ys, xs = np.mgrid[0:v.height, 0:v.width]
    cx, cy = (a * xs).sum() / a.sum(), (a * ys).sum() / a.sum()
    d = np.hypot(xs - cx, ys - cy)
    o = np.argsort(d.ravel())
    cum = np.cumsum(a.ravel()[o])
    R = d.ravel()[o][np.searchsorted(cum, 0.85 * cum[-1])]
    rows.append((R / v.width, cx / v.width - 0.5, cy / v.height - 0.5, float((a > 0.1).mean()), v.width))
    shutil.copyfile(src, os.path.join(OUT_M, "bp%d.vtf" % i))
    with open(os.path.join(OUT_M, "bp%d.vmt" % i), "w", newline="\n") as f:
        f.write(VMT % (i, SCALE))

small = [i + 1 for i in range(36) if sizes[i] < W]
lines = ["-- GHM PhysBlood: the 36 splat decals of GHM's Crisis Response Blood Mod (materials/ghm_physblood/crb/bp1..36,",
         "-- copied from decals/bloodplace by tools/make_crb_decals.py, 1.26.7). r = radius holding 85 % of the decal's blood",
         "-- over the texture's width, ox, oy = where its blood centre sits (from the texture's middle, over its width),",
         "-- c = how much of it is covered, px = its width in pixels. Sized as if %d px wide: %s, %d px in the mod, show at half size, as they do there." % (W, ", ".join("bp%d" % i for i in small) or "none", min(sizes)),
         "GHMPB.CRB_DECAL_UNITS = %.2f   -- width of a decal at scale 1 (%d px x $decalscale %.2f)" % (W * SCALE, W, SCALE),
         "GHMPB.CRBDecals = {"]
for (r, ox, oy, c, px) in rows:
    lines.append("\t{ r = %.3f, ox = %.3f, oy = %.3f, c = %.4f, px = %d }," % (r, ox, oy, c, px))
lines.append("}")
open(OUT_L, "w", newline="\n").write("\n".join(lines) + "\n")
print("36 decals ->", OUT_M, "| r from %.3f to %.3f" % (min(x[0] for x in rows), max(x[0] for x in rows)))
