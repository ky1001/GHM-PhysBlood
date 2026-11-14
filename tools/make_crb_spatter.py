#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): spatter patterns from GHM's Crisis Response Blood splatter
textures (materials/3d/red/blood1..8 - the same files in his Universal Directional Blood dev code and in the Next Gen
Universal Blood Splattering Mod). Replaces the Cyberpunk Next Gen Blood patterns of 1.26.6.

Each texture is measured into drops the game paints with its forensic stamp (cl_forensic.lua F.Spatter):
  * single drops: their centre, area-equivalent radius, direction and elongation;
  * ligaments, tendrils and the thin web of the spray textures: sampled along their centre line as elongated drops lying
    along the line, so neighbouring stamps join into the line;
  * thick clumps: their centre line with the local thickness, then the rest filled with round drops.
The pattern is turned so its long axis is +u, with the thick core at -u (the blood travelled towards +u).
Output (same layout as 1.26.6): d = u, v (from the centre, in pattern radii), radius, direction (rad), elongation -
the biggest first; mist = u, v, radius, density of the faint spray round it.

usage: make_crb_spatter.py <dir with blood1.png .. blood8.png (RGBA)> <out lua> [preview dir]
"""
import sys, math, os
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from skimage import measure, morphology

SRC, OUT = sys.argv[1], sys.argv[2]
PREV = sys.argv[3] if len(sys.argv) > 3 else None
NAMES = os.environ.get('CRB_NAMES', ','.join('blood%d' % i for i in range(1, 9))).split(',')
# (1.26.7) the source set: 'crb3d' = the 3d/red splatters (Universal Directional Blood), 'bloodplace' = the spatter
# decals of the Crisis Response Blood Mod (the high-velocity spatter the game uses for gunshots)
SET = os.environ.get('CRB_SET', 'crb3d')
MAXD = int(os.environ.get('CRB_MAXD', '300'))
MIN_SINGLE = float(os.environ.get('CRB_MIN_SINGLE', '1.1'))
STRONG = 0.3


def principal_frame(a):
    ys, xs = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    w = a * a
    cx, cy = (w * xs).sum() / w.sum(), (w * ys).sum() / w.sum()
    dx, dy = xs - cx, ys - cy
    cxx, cyy, cxy = (w * dx * dx).sum(), (w * dy * dy).sum(), (w * dx * dy).sum()
    ev, evec = np.linalg.eigh(np.array([[cxx, cxy], [cxy, cyy]]))
    ax = evec[:, 1]                       # long axis (image x, y)
    return cx, cy, ax, math.sqrt(max(ev[1], 1e-9) / max(ev[0], 1e-9))


def pattern(name):
    im = Image.open(os.path.join(SRC, name + '.png')).convert('RGBA')
    a = np.asarray(im)[..., 3].astype(np.float32) / 255.0
    H, W = a.shape
    cx, cy, ax, aniso = principal_frame(a)
    strong = a > STRONG
    dt = ndi.distance_transform_edt(strong)
    # the thick core decides the sign of the axis: core at -u
    iy, ix = np.unravel_index(np.argmax(dt), dt.shape)
    if aniso > 1.25 and ((ix - cx) * ax[0] + (iy - cy) * ax[1]) > 0:
        ax = -ax
    if aniso <= 1.25:
        ax = np.array([1.0, 0.0])
    side = np.array([-ax[1], ax[0]])

    def uv(x, y):
        dx, dy = x - cx, y - cy
        return dx * ax[0] + dy * ax[1], dx * side[0] + dy * side[1]

    def ang_of(tx, ty):
        # image direction -> angle from +u towards +v
        u = tx * ax[0] + ty * ax[1]
        v = tx * side[0] + ty * side[1]
        return math.atan2(v, u) % math.pi

    # pattern radius: 85 % of the blood lies within it
    ys, xs = np.mgrid[0:H, 0:W]
    d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2)
    order = np.argsort(d.ravel())
    cum = np.cumsum(a.ravel()[order])
    R = d.ravel()[order][np.searchsorted(cum, 0.85 * cum[-1])]

    drops, lines = [], []
    lab = measure.label(strong, connectivity=2)
    skel = morphology.skeletonize(strong)
    for rp in measure.regionprops(lab):
        A = rp.area
        if A < 2:
            continue
        req = math.sqrt(A / math.pi)
        sl = rp.slice
        m = lab[sl] == rp.label
        oy, ox = sl[0].start, sl[1].start
        mdt = dt[sl] * m
        if mdt.max() <= 3.2 and (rp.axis_major_length < 4.5 * max(rp.axis_minor_length, 1) or A < 40):
            # a single drop
            el, ang = 1.0, 0.0
            if rp.axis_minor_length > 0.5:
                el = min(max(rp.axis_major_length / max(rp.axis_minor_length, 0.5), 1.0), 3.0)
                o = rp.orientation           # angle of the major axis from image rows (y)
                ang = ang_of(math.sin(o), math.cos(o))
            if req < MIN_SINGLE:
                continue
            y0, x0 = rp.centroid
            u, v = uv(x0, y0)
            drops.append([u, v, req, ang, el, 0])
            continue
        # a ligament / web / clump: its centre line, sampled with the local thickness
        sk = skel[sl] & m
        pts = np.argwhere(sk)
        if len(pts) == 0:
            continue
        wv = mdt[pts[:, 0], pts[:, 1]]
        lines.append((pts + [oy, ox], wv, m, oy, ox, mdt))

    def sample_lines(spacing):
        out = []
        for pts, wv, m, oy, ox, mdt in lines:
            idx = np.argsort(-wv)
            taken = np.zeros(len(pts), bool)
            acc = []
            cap = 0.06 * R
            yy, xx = np.ogrid[:m.shape[0], :m.shape[1]]
            core = []
            # the solid core of a clump: a close hexagonal crowd of round drops of the largest size (they overlap)
            if mdt.max() >= 0.75 * cap and cap >= 3.0:
                inner = mdt >= 0.7 * cap
                st = 1.45 * cap
                gy = np.arange(0, m.shape[0], st * 0.866)
                for row, y in enumerate(gy):
                    for x in np.arange((row % 2) * st * 0.5, m.shape[1], st):
                        iy_, ix_ = int(round(y)), int(round(x))
                        if iy_ < m.shape[0] and ix_ < m.shape[1] and inner[iy_, ix_]:
                            core.append((ix_, iy_))
                for (x, y) in core:
                    u, v = uv(ox + x, oy + y)
                    acc.append([u, v, cap * 1.05, 0.0, 1.0, 2])
                # the centre line inside the core is covered by it
                taken |= mdt[pts[:, 0] - oy, pts[:, 1] - ox] >= 0.7 * cap
            for k in idx:
                if taken[k]:
                    continue
                w = max(wv[k], 0.9)
                L = max(spacing * min(w, 0.06 * R) * (0.9 if w >= 3.0 else 1.0), 2.2)
                dd = np.hypot(pts[:, 0] - pts[k, 0], pts[:, 1] - pts[k, 1])
                near = dd <= L
                taken |= near
                # direction of the line here: the skeleton points round it
                nb = pts[dd <= max(2.5 * w, 4)]
                tx, ty = 1.0, 0.0
                if len(nb) >= 3:
                    c = nb - nb.mean(0)
                    ev, evec = np.linalg.eigh(c.T @ c)
                    ty, tx = evec[0, 1], evec[1, 1]
                if w >= 3.0:
                    # a thick part: a round drop as wide as it is (the core of a splat is a crowd of drops, not one disc)
                    el, req = 1.0, min(w, 0.06 * R)
                else:
                    half = max(min(L * 0.62, 3.2 * w), w)   # half length of the stamp along the line
                    el = min(max(half / w, 1.0), 3.2)
                    req = math.sqrt(half * w)
                u, v = uv(pts[k, 1], pts[k, 0])
                acc.append([u, v, req, ang_of(tx, ty), el, 1])
            out += acc
            # what the line samples leave of a thick clump: round drops (largest inscribed circles first)
            if mdt.max() > 3.2:
                left = m.copy()
                for (uu, vv, rr, aa, ee, _) in acc:
                    # back to image coordinates of this slice
                    x = cx + uu * ax[0] + vv * side[0] - ox
                    y = cy + uu * ax[1] + vv * side[1] - oy
                    left[(yy - y) ** 2 + (xx - x) ** 2 <= (rr * 0.95) ** 2] = False
                for _ in range(40):
                    if left.sum() < 12:
                        break
                    ld = ndi.distance_transform_edt(left)
                    jy, jx = np.unravel_index(np.argmax(ld), ld.shape)
                    r = min(ld[jy, jx], cap)
                    if r < 1.8:
                        break
                    u, v = uv(ox + jx, oy + jy)
                    out.append([u, v, r * 1.1, 0.0, 1.0, 2])
                    left[(yy - jy) ** 2 + (xx - jx) ** 2 <= (r * 0.95) ** 2] = False
        return out

    # line samples: as close as joins them up, wider when there would be too many
    room = max(MAXD - min(len(drops), MAXD // 2), MAXD // 3)
    spacing = 1.5
    ls = sample_lines(spacing)
    while len(ls) > room and spacing < 8:
        spacing *= 1.25
        ls = sample_lines(spacing)
    allp = ls + drops
    allp.sort(key=lambda t: -t[2])
    if len(allp) > MAXD:
        # keep the line samples and the biggest drops, an even sample of the small single drops
        keep = [p for p in allp if p[5] != 0]
        singles = [p for p in allp if p[5] == 0]
        n = max(MAXD - len(keep), 0)
        big = singles[:n // 2]
        rest = singles[n // 2:]
        step = len(rest) / max(n - len(big), 1)
        allp = keep + big + [rest[int(i * step)] for i in range(n - len(big)) if int(i * step) < len(rest)]
        allp.sort(key=lambda t: -t[2])
    # far specks (more than 2.4 pattern radii out) are left out: a compact splat with long tendrils would otherwise
    # throw drops several pattern sizes away
    allp = [p for p in allp if math.hypot(p[0], p[1]) <= 2.4 * R]
    drops = [(p[0] / R, p[1] / R, p[2] / R, p[3], p[4]) for p in allp[:MAXD]]
    kinds = [p[5] for p in allp[:MAXD]]
    # the faint spray: where the alpha is low but present
    mist = (a > 0.06) & (a <= STRONG)
    mw = a * mist
    if mw.sum() > 0:
        mx, my = (mw * xs).sum() / mw.sum(), (mw * ys).sum() / mw.sum()
        mr = math.sqrt((mw * ((xs - mx) ** 2 + (ys - my) ** 2)).sum() / mw.sum()) * 1.2
        mu, mv = uv(mx, my)
        # every spatter has its fine mist: at least a faint one, no wider than 1.4 pattern radii
        mist_t = (mu / R, mv / R, min(mr / R, 1.4), float(min(max(mw.sum() / (math.pi * mr * mr), 0.03), 1.0)))
    else:
        mist_t = (0, 0, 0.6, 0.0)
    return drops, kinds, mist_t, R, (cx, cy, ax, side), a


def preview(name, drops, R, frame, a, path):
    """the drops drawn as the ellipses they stand for, next to the texture (for checking)"""
    cx, cy, ax, side = frame
    S = 512
    k = S / 1024.0
    img = Image.new('RGB', (S * 2, S), (238, 238, 238))
    tex = Image.fromarray((255 - a * 200).astype(np.uint8)).resize((S, S))
    img.paste(Image.merge('RGB', (tex, tex.point(lambda p: int(p * 0.2 + 200 * 0.8 * (p / 255))), tex.point(lambda p: int(p * 0.2)))), (0, 0))
    dr = ImageDraw.Draw(img)
    for (u, v, r, ang, el) in drops:
        U, V = u * R, v * R
        x = cx + U * ax[0] + V * side[0]
        y = cy + U * ax[1] + V * side[1]
        a_ = r * R * math.sqrt(el)
        b_ = r * R / math.sqrt(el)
        du = (math.cos(ang) * ax[0] + math.sin(ang) * side[0], math.cos(ang) * ax[1] + math.sin(ang) * side[1])
        dv = (-du[1], du[0])
        poly = []
        for t in range(16):
            th = t / 16 * 2 * math.pi
            px = x + du[0] * a_ * math.cos(th) + dv[0] * b_ * math.sin(th)
            py = y + du[1] * a_ * math.cos(th) + dv[1] * b_ * math.sin(th)
            poly.append((S + px * k, py * k))
        dr.polygon(poly, fill=(120, 10, 8))
    img.save(path)


if SET == 'bloodplace':
    out = ['-- GHM PhysBlood: spatter patterns measured from the spatter decals of the Crisis Response Blood Mod (GHM\'s',
           '-- blood mod, materials/decals/bloodplace) by tools/make_crb_spatter.py (1.26.7): the bigger drops of each decal,',
           '-- which the game paints as wet stains on top of the decal itself (cl_forensic.lua F.Spatter). d = drops: u, v (from',
           '-- the centre, in pattern radii), radius, direction (rad), elongation - the biggest first. mist = u, v, radius, density.',
           'GHMPB.SpatterPatterns = {']
else:
    out = ['-- GHM PhysBlood: spatter patterns measured from the Crisis Response Blood splatter textures (GHM\'s blood mod,',
           '-- materials/3d/red/blood1..8) by tools/make_crb_spatter.py (1.26.7). d = drops: u, v (from the centre, in pattern',
           '-- radii; +u = the way the blood travelled when it hit at an angle), radius, direction (rad), elongation - the biggest',
           '-- first. Ligaments and the thin web are elongated drops lying along the line. mist = u, v, radius, density.',
           'GHMPB.SpatterPatterns = {']
for n in NAMES:
    drops, kinds, mist, R, frame, a = pattern(n)
    flat = []
    for (u, v, r, ang, el) in drops:
        flat += ['%.3f' % u, '%.3f' % v, '%.4f' % r, '%.2f' % ang, '%.2f' % el]
    lines = []
    for i in range(0, len(flat), 40):
        lines.append('\t\t' + ','.join(flat[i:i + 40]) + ',')
    out.append('\t{ name = "%s_%s", mist = { %.3f, %.3f, %.3f, %.3f }, n = %d, d = {' % ('bp' if SET == 'bloodplace' else 'crb', n, mist[0], mist[1], mist[2], mist[3], len(drops)))
    out += lines
    out.append('\t} },')
    print('%s: %d drops (%d line samples, %d clump fill, %d single), largest r %.3f, smallest %.4f, mist r %.2f d %.2f, R %.0f px' %
          (n, len(drops), kinds.count(1), kinds.count(2), kinds.count(0), drops[0][2], drops[-1][2], mist[2], mist[3], R))
    if PREV:
        preview(n, drops, R, frame, a, os.path.join(PREV, n + '_check.png'))
out.append('}')
open(OUT, 'w', newline='\n').write('\n'.join(out) + '\n')
