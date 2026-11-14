#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): Lite-renderer splatter textures from GHM's blood mod
(the Crisis Response Blood Mod: its droplet decals materials/effects/droplets and its spatter decals
materials/decals/bloodplace). Every drop lands as a drop shape, not as a whole splash (players: "large spatters, only
two or three textures"); the fine spray comes from the CRB spatter decals themselves (cl_forensic.lua F.CRBDecal).

Replaces in lite/stains.vtf (4 x 4 atlas, alpha = shape, grey = detail for the Modulate material):
  0-3 splat <- droplets drop7, drop2, drop11, drop3   4, 5 oblique <- droplets drop5 (tail +u), drop4
  13 mist   <- CRB spatter decal bloodplace/blood2    14 small <- droplets drop1
and writes lite/bsplat.vtf (droplets drop7) and lite/bmist.vtf (bloodplace/blood18) for bodies.
Untouched: pool (6), run/streak (7), smear (8), prints (9-12), bead (15), bdrip (streaks), bwound (wounds), drop.
Prints the BODY sizes (radius of the stain's body / half the cell) for cl_lite.lua. Writes uncompressed BGRA8888.

usage: make_crb_lite.py <bloodplace png dir (bloodN.png)> <droplet png dir> <old stains.vtf> <out dir> [preview png]
"""
import sys, math, os
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage import measure
from srctools.vtf import VTF, ImageFormats, VTFFlags

CRB, DROPS, OLD, OUT = sys.argv[1:5]
PREV = sys.argv[5] if len(sys.argv) > 5 else None
CELL = 256
FLAGS = VTFFlags.TRILINEAR | VTFFlags.CLAMP_S | VTFFlags.CLAMP_T | VTFFlags.EIGHTBITALPHA


def load_alpha(path, rot=0):
    im = Image.open(path).convert('RGBA')
    if rot:
        im = im.rotate(rot, resample=Image.BICUBIC, expand=True)
    a = np.asarray(im)[..., 3].astype(np.float32) / 255.0
    return a


def fit(a, size, margin=0.06, centre_on_core=True, keep=1.0):
    """crop to the blood, scale into size x size keeping the aspect, the main body near the middle. keep < 1: only
    the part of the pattern holding that share of the blood (far specks fade out towards the cell's edge)"""
    ys, xs = np.nonzero(a > 0.04)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    if centre_on_core:
        # centre on the thick core so the stain sits where the drop landed
        dt = ndi.distance_transform_edt(a > 0.5)
        cy, cx = np.unravel_index(np.argmax(dt), dt.shape)
        half = max(cx - x0, x1 - cx, cy - y0, y1 - cy)
        if keep < 1.0:
            yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
            d = np.hypot(xx - cx, yy - cy)
            o = np.argsort(d.ravel())
            cum = np.cumsum(a.ravel()[o])
            half = int(min(half, d.ravel()[o][np.searchsorted(cum, keep * cum[-1])] * 1.08)) + 1
            a = a * np.clip((half - d) / (0.18 * half), 0, 1)
        x0, x1, y0, y1 = cx - half, cx + half, cy - half, cy + half
    w, h = x1 - x0, y1 - y0
    s = max(w, h)
    pad = int(s * margin) + 1
    canvas = np.zeros((s + 2 * pad, s + 2 * pad), np.float32)
    ox, oy = pad + (s - w) // 2, pad + (s - h) // 2
    sx0, sy0 = max(x0, 0), max(y0, 0)
    sx1, sy1 = min(x1, a.shape[1]), min(y1, a.shape[0])
    canvas[oy + (sy0 - y0): oy + (sy1 - y0), ox + (sx0 - x0): ox + (sx1 - x0)] = a[sy0:sy1, sx0:sx1]
    out = Image.fromarray((canvas * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)
    return np.asarray(out).astype(np.float32) / 255.0


def body_frac(a):
    """radius of the stain's main body (biggest solid piece, area-equivalent) over half the cell"""
    lab = measure.label(a > 0.5, connectivity=2)
    if lab.max() == 0:
        return 0.3
    areas = np.bincount(lab.ravel())[1:]
    return math.sqrt(areas.max() / math.pi) / (a.shape[0] / 2)


def ring_shade(a, base):
    """grey detail: darker coffee-ring edge and slightly darker thick blood, on the old cell's own noise"""
    inside = ndi.distance_transform_edt(a > 0.5)
    ring = np.exp(-((inside - 1.5) / 2.2) ** 2) * (a > 0.3)
    core = np.clip(inside / 10.0, 0, 1)
    g = base * (1 - 0.28 * ring) * (1 - 0.06 * core)
    return np.clip(g, 0.5, 1.0)


def to_vtf(rgba, path):
    # uncompressed BGRA8888, like PhysBlood's own textures (a DXT5 build to save space was dropped: GHM wants the
    # textures at the resolution they have, not compressed)
    h, w = rgba.shape[:2]
    v = VTF(w, h, (7, 2), fmt=ImageFormats.BGRA8888, flags=FLAGS)
    v.get().copy_from(np.ascontiguousarray(rgba).tobytes(), ImageFormats.RGBA8888)
    v.compute_mipmaps()
    with open(path, 'wb') as f:
        v.save(f)


old = VTF.read(open(OLD, 'rb'))
old.load()
atlas = np.asarray(old.get().to_PIL().convert('RGBA')).astype(np.float32) / 255.0
assert atlas.shape[0] == 4 * CELL, atlas.shape

C = lambda n: os.path.join(CRB, n + '.png')
D = lambda n: os.path.join(DROPS, n + '.png')
cells = {
    0: (D('drop7'), 0, True, 0.98),
    1: (D('drop2'), 0, True, 0.97),
    2: (D('drop11'), 0, True, 0.97),
    3: (D('drop3'), 0, True, 0.97),
    4: (D('drop5'), -90, False, 1.0),     # tail pointing +u
    5: (D('drop4'), 0, False, 1.0),
    13: (C('blood2'), 0, False, 0.9),
    14: (D('drop1'), 0, True, 0.95),
}
bodies = {}
for c, (path, rot, core, keep) in cells.items():
    a = fit(load_alpha(path, rot), CELL, margin=0.05 if c in (4, 5) else 0.08, centre_on_core=core, keep=keep)
    x, y = (c % 4) * CELL, (c // 4) * CELL
    base = atlas[y:y + CELL, x:x + CELL, 0].copy()
    # the old cell's noise without its old ring: smooth it a little
    base = ndi.uniform_filter(np.clip(base, 0.8, 1.0), 9)
    g = ring_shade(a, base)
    atlas[y:y + CELL, x:x + CELL, 0] = g
    atlas[y:y + CELL, x:x + CELL, 1] = g
    atlas[y:y + CELL, x:x + CELL, 2] = g
    atlas[y:y + CELL, x:x + CELL, 3] = a
    bodies[c] = body_frac(a)
    # oblique cells: the length of the stain over the cell (the game scales hu by it)
    if c in (4, 5):
        ys, xs = np.nonzero(a > 0.5)
        bodies[c] = ((xs.max() - xs.min()) / CELL, body_frac(a))
os.makedirs(OUT, exist_ok=True)
to_vtf((atlas * 255).round().astype(np.uint8), os.path.join(OUT, 'stains.vtf'))

# bodies (VertexLitGeneric decals tinted by $color2): near-white with a darker edge
# bsplat: the droplet texture is 256 px; bmist: the CRB splat is 1024 px, kept at 1024 (the VMTs' $decalscale keeps the
# size in the world: 256 x 0.015625 = 1024 x 0.00390625 = 4 u)
BODY_SIZE = {'bsplat': 256, 'bmist': 1024}
for name, src in (('bsplat', D('drop7')), ('bmist', C('blood18'))):
    a = fit(load_alpha(src), BODY_SIZE[name], margin=0.06, centre_on_core=(name == 'bsplat'), keep=0.98 if name == 'bsplat' else 1.0)
    if name == 'bmist':
        a = np.clip(a * 1.6, 0, 1)
    inside = ndi.distance_transform_edt(a > 0.5)
    ring = np.exp(-((inside - 1.5) / 2.2) ** 2) * (a > 0.3)
    shade = 1 - 0.22 * ring
    rgb = np.stack([0.89 * shade, 0.80 * shade, 0.76 * shade], -1)
    rgba = np.concatenate([rgb, a[..., None]], -1)
    to_vtf((rgba * 255).round().astype(np.uint8), os.path.join(OUT, name + '.vtf'))
    bodies[name] = body_frac(a)

for k, v in sorted(bodies.items(), key=lambda t: str(t[0])):
    print(k, v)

if PREV:
    bg = np.ones((4 * CELL, 4 * CELL, 3), np.float32) * np.array([0.93, 0.93, 0.93])
    blood = np.array([0.42, 0.03, 0.025])
    col = blood[None, None, :] * atlas[..., :3] * 1.6
    al = atlas[..., 3:4]
    img = bg * (1 - al) + col * al
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(PREV)
