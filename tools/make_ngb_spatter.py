#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.6 (Claude, Cowork chat, 2026-10-27): spatter patterns from GHM's Next Gen Blood (Cyberpunk 2077)
splatter textures. Each texture's droplets are measured (connected areas of its alpha) and written as a list of drops -
position relative to the pattern centre, radius, direction and elongation, all in units of the pattern radius - plus the
faint mist around them. The game paints each drop with the forensic stamp (its own round stain, spines, satellites),
laid out as in the texture. Big merged clumps are split into the round drops that fill them.
usage: make_ngb_spatter.py <dir with the extracted PNGs> <out lua>
"""
import sys, math
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
from skimage import measure

SRC, OUT = sys.argv[1], sys.argv[2]
NAMES = ['447a6b027af1a685_c_4096x4096', '630aee05328b8bc9_c_1024x1024', '7e89fd9868087aeb_c_4096x4096',
         'dc01358edbe6d980_c_4096x4096', '56e0f1402f6125f4_c_1024x1024', '83454f810b1dfbb2_c_1024x1024']
RES = 1024
MAXD = 240

def pattern(name):
    im = Image.open(f'{SRC}/{name}.png').convert('RGBA')
    a = np.asarray(im.resize((RES, RES), Image.LANCZOS))[..., 3].astype(np.float32) / 255.0
    ys, xs = np.mgrid[0:RES, 0:RES]
    w = a * a
    cx, cy = (w * xs).sum() / w.sum(), (w * ys).sum() / w.sum()
    d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2)
    # pattern radius: 85 % of the blood lies within it
    order = np.argsort(d.ravel())
    cum = np.cumsum(a.ravel()[order])
    R = d.ravel()[order][np.searchsorted(cum, 0.85 * cum[-1])]
    drops = []
    strong = a > 0.6
    lab = measure.label(strong, connectivity=2)
    for rp in measure.regionprops(lab, intensity_image=a):
        A = rp.area
        if A < 2:
            continue
        y0, x0 = rp.centroid
        req = math.sqrt(A / math.pi)
        if req > 6:
            # a clump: split into the round drops that fill it (largest inscribed circles first, none bigger than a
            # big drop of the texture - the core of a spatter is a crowd of drops, not one disc)
            m = (lab[rp.slice] == rp.label)
            oy, ox = rp.slice[0].start, rp.slice[1].start
            left = m.copy()
            cap = 0.055 * R
            for _ in range(60):
                if left.sum() < max(10, 0.06 * A):
                    break
                dt = ndi.distance_transform_edt(left)
                iy, ix = np.unravel_index(np.argmax(dt), dt.shape)
                r = min(dt[iy, ix], cap)
                if r < 1.5:
                    break
                drops.append(((ox + ix - cx) / R, (oy + iy - cy) / R, r * 1.1 / R, 0.0, 1.0))
                yy, xx = np.ogrid[:left.shape[0], :left.shape[1]]
                left[(yy - iy) ** 2 + (xx - ix) ** 2 <= (r * 1.25) ** 2] = False
            continue
        el = 1.0
        ang = 0.0
        if rp.axis_minor_length > 0.5:
            el = min(max(rp.axis_major_length / max(rp.axis_minor_length, 0.5), 1.0), 3.0)
            ang = -rp.orientation + math.pi / 2   # image rows down -> angle from +u towards +v
        drops.append(((x0 - cx) / R, (y0 - cy) / R, req / R, ang, el))
    drops.sort(key=lambda t: -t[2])
    # keep the biggest and an even sample of the small ones
    if len(drops) > MAXD:
        big = drops[:MAXD // 2]
        rest = drops[MAXD // 2:]
        step = len(rest) / (MAXD - len(big))
        drops = big + [rest[int(i * step)] for i in range(MAXD - len(big))]
    # the faint mist: where the alpha is low but present
    mist = (a > 0.06) & (a <= 0.6)
    mw = a * mist
    if mw.sum() > 0:
        mx, my = (mw * xs).sum() / mw.sum(), (mw * ys).sum() / mw.sum()
        mr = math.sqrt((mw * ((xs - mx) ** 2 + (ys - my) ** 2)).sum() / mw.sum()) * 1.2
        mist_t = ((mx - cx) / R, (my - cy) / R, mr / R, float(mw.sum() / (math.pi * mr * mr)))
    else:
        mist_t = (0, 0, 0.6, 0.0)
    return drops, mist_t, R

out = ['-- GHM PhysBlood: spatter patterns measured from the Next Gen Blood (Cyberpunk 2077) splatter textures by',
       '-- tools/make_ngb_spatter.py (1.26.6). d = drops: u, v (from the centre, in pattern radii; +u = the way the blood',
       '-- travelled when it hit at an angle), radius, direction (rad), elongation - the biggest first. mist = u, v, radius, density.',
       'GHMPB.SpatterPatterns = {']
for n in NAMES:
    drops, mist, R = pattern(n)
    flat = []
    for (u, v, r, ang, el) in drops:
        flat += ['%.3f' % u, '%.3f' % v, '%.4f' % r, '%.2f' % ang, '%.2f' % el]
    lines = []
    for i in range(0, len(flat), 40):
        lines.append('\t\t' + ','.join(flat[i:i + 40]) + ',')
    out.append('\t{ mist = { %.3f, %.3f, %.3f, %.3f }, n = %d, d = {' % (mist[0], mist[1], mist[2], mist[3], len(drops)))
    out += lines
    out.append('\t} },')
    print('%s: %d drops (largest r %.3f, smallest %.4f), mist r %.2f, pattern radius %.0f px of %d' %
          (n, len(drops), drops[0][2], drops[-1][2], mist[2], R, RES))
out.append('}')
open(OUT, 'w', newline='\n').write('\n'.join(out) + '\n')
