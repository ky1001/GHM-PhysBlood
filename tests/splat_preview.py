#!/usr/bin/env python3
"""
GHM PhysBlood - offline preview of drop stains on a floor (1.24.0): a NumPy port of the droplet-impact part (kind 0)
of stamp_ps30.hlsl on a dry surface, fed by drops thrown from a point and landing ballistically (gravity, no drag -
the throws here are a few units), with the landing rules of cl_particles P.Land (Hulse-Smith size, ricochet skip,
fast-drop stretch) and the stain shaping of each version. Draws the wet film (Beer-Lambert over a grey floor).
usage: splat_preview.py <out.png>
Panels: the 1.23 fall-smash spray (what made the long lines), the same with 1.24's stain shaping, 1.24's burst.
"""
import sys, math
import numpy as np
from PIL import Image, ImageDraw, ImageFont

rng = np.random.default_rng(7)
G = 600.0                       # sv_gravity (u/s^2)
UPM = 1 / 0.01905               # units per metre
RHO, MU, SIGMA = 1060, 0.004, 0.058
PX = 0.035                      # units per pixel of the preview (~1.3 mm)

def frac(x): return x - np.floor(x)
def hash12(px, py):
    p3x, p3y, p3z = frac(px * 0.1031), frac(py * 0.1031), frac(px * 0.1031)
    d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x, p3y, p3z = p3x + d, p3y + d, p3z + d
    return frac((p3x + p3y) * p3z)
def hash11(p):
    p = frac(p * 0.1031); p = p * (p + 33.33); p = p * (p + p); return frac(p)
def vnoise(x, y):
    ix, iy = np.floor(x), np.floor(y); fx, fy = x - ix, y - iy
    ux, uy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = hash12(ix, iy), hash12(ix + 1, iy); c, d = hash12(ix, iy + 1), hash12(ix + 1, iy + 1)
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
sat = lambda x: np.clip(x, 0, 1)
sq = lambda x: x * x

def stain(rmm, vel):
    """F.Stain: radius (u), spines, K for a drop of radius rmm hitting a floor (normal +z) with vel (u/s)"""
    d = 2 * rmm / 1000
    vn = max(abs(vel[2]) * 0.01905, 0.3)
    Re = RHO * vn * d / MU
    We = RHO * vn * vn * d / SIGMA
    D = max(1.2 * d, 0.5 * d * Re ** 0.25)
    return D * 0.5 * UPM, int(np.clip(1.14 * math.sqrt(We), 0, 60)), math.sqrt(We) * Re ** 0.25

def splat(field, ox, oy, im, rough=0.8, absorb=0.06):
    """stamp_ps30 kind 0 on a floor (n = +z), added into field (wet mm). im: pos(x,y), vel, R, vol, spines, K, stretch, spin, seed"""
    px, py = im["pos"]; vel = np.array(im["vel"], float); R = max(im["R"], 0.01); vol = im["vol"]
    stretch = np.clip(im["stretch"], 1, 8); spin = im["spin"]; seed = im["seed"]
    speed = np.linalg.norm(vel); vn = vel[2]; vt = np.array([vel[0], vel[1], 0.0]); vts = np.linalg.norm(vt)
    sinA = sat(abs(vn) / max(speed, 1e-3))
    e = min(np.clip(1 / max(sinA, 0.12), 1, 8) * stretch, 10)
    reach = R * (2.6 * e + 5) + 0.5
    H, W = field.shape
    x0 = int(max((px - reach - ox) / PX, 0)); x1 = int(min((px + reach - ox) / PX + 1, W))
    y0 = int(max((py - reach - oy) / PX, 0)); y1 = int(min((py + reach - oy) / PX + 1, H))
    if x1 <= x0 or y1 <= y0: return
    gx, gy = np.meshgrid(ox + (np.arange(x0, x1) + 0.5) * PX, oy + (np.arange(y0, y1) + 0.5) * PX)
    dx, dy = gx - px, gy - py
    if vts > 2: t = vt / vts
    else:
        a = np.array([seed - 0.5, 0.37, 0.61]); a /= np.linalg.norm(a); t = np.cross([0, 0, 1], a); t /= np.linalg.norm(t)
    b = np.cross([0, 0, 1], t)
    x = dx * t[0] + dy * t[1]; y = dx * b[0] + dy * b[1]
    Rmm = R * 19.05
    r = np.hypot(x, y)
    tw = np.clip(spin * 0.012, -3, 3) * sat(r / (R * 2.5))
    cs, sn = np.cos(tw), np.sin(tw)
    xr, yr = x * cs - y * sn, x * sn + y * cs
    oblique = sat((e - 1) * 0.8); skid = sat((e - 4) / 3)
    L = R * e; xc = R * 0.3 * (e - 1)
    xe = (xr - xc) / L
    wf = np.clip(1 - 0.32 * oblique * xe, 0.55, 1.4)
    ye = yr / (R * wf)
    rho = np.hypot(xe, ye); ang = np.arctan2(ye, xe)
    energy = sat(speed / 450)
    K = im["K"] if im["K"] > 1.5 else 60 * energy
    Kc = 140 + (45 - 140) * sat(rough)
    spl = sat(K / Kc - 0.6) * (1 - sat(absorb * 1.5))
    nsp = np.clip(im["spines"] if im["spines"] > 0.5 else 7 + 11 * energy, 5, 60)
    lead = 1 + (1.7 * sat(0.5 + 0.5 * np.cos(ang)) ** 2 - 1) * oblique
    wav = np.sin(ang * nsp + seed * 40)
    scallop = 0.06 * sat(rough) * (1 - spl) * wav
    spikes = spl * lead * (0.14 + 0.45 * spl) * sat(0.5 + 0.5 * wav) ** 10 + sat(np.cos(ang)) ** 8 * 0.4 * sat(e - 1)
    serr = skid * 0.2 * (vnoise(xr / R * 2.3 + seed * 17, np.where(yr > 0, 3.0, 9.0) + seed) - 0.4)
    edge = 1 + scallop + spikes + serr + 0.035 * np.sin(ang * (nsp * 0.37 + 3) - seed * 17)
    q = rho / edge
    dome = np.sqrt(sat(1 - q * q))
    rim = 0.32 * np.exp(-sq((q - 0.9) / 0.09)) * (q <= 1.08)
    dens = np.where(q < 1, dome, 0) + rim
    dens = dens * (1 + 0.45 * oblique * np.clip(xe, -1, 1))
    lanes = vnoise(yr / R * 3.2 + seed * 29, xr / R * 0.22)
    dens = dens * (1 + (0.3 + 0.9 * np.clip((lanes - 0.25) / 0.4, 0, 1) - 1) * skid)
    xf = xc + L * 0.92
    tailLen = R * e * (0.55 + 0.3 * skid) * sat(e - 1.3)
    tx = xr - xf
    if tailLen > 0:
        u = tx / tailLen
        wob = 1 + 0.3 * (vnoise(tx / R * 1.7 + seed * 5, seed * 3 + 0 * tx) - 0.5)
        width = (R * 0.3 * (1 - u) + 0.04) * wob
        dens = dens + np.where((tx > 0) & (tx < tailLen), sat(1 - np.abs(yr) / width) * (0.6 - 0.25 * u), 0)
    hw = hash11(seed * 53.1 + 0.37)
    if 1.6 < e < 7.5 and hw < 0.3 + 0.45 * oblique:
        gap = R * (0.25 + 0.6 * hash11(seed * 71.3)); rw = R * (0.2 + 0.18 * hash11(seed * 13.9)); off = R * 0.3 * (hw - 0.4)
        cxw = xf + tailLen + gap + rw * 1.4
        wqx = (xr - cxw) / (rw * 1.5); wqy = (yr - off) / rw / np.clip(1 + 0.45 * (xr - cxw) / (rw * 1.5), 0.4, 1.4)
        dens = dens + np.sqrt(sat(1 - (wqx * wqx + wqy * wqy))) * 0.9
    nSec = 22.0
    sector = np.floor((ang / (2 * np.pi) + 0.5) * nSec)
    h1 = hash11(sector * 1.37 + seed * 97)
    pSat = spl * 0.8 * lead
    ac = ((sector + 0.5) / nSec - 0.5) * 2 * np.pi
    far = 1.3 + 2.2 * hash11(sector * 3.1 + seed * 11)
    rs = far * (0.6 + 0.4 * sat(0.5 + 0.5 * np.cos(ac)) * (1 + oblique))
    ssz = 0.06 + 0.1 * hash11(sector * 7.7 + seed)
    sd = np.hypot(xe - np.cos(ac) * rs, ye - np.sin(ac) * rs) / ssz
    dens = dens + np.where(h1 < pSat, np.sqrt(sat(1 - sd * sd)) * 0.8, 0)
    h0 = vol / (0.6667 * np.pi * Rmm * Rmm * e)
    field[y0:y1, x0:x1] += h0 * dens

def shape_v124(vel, stretch, emax):
    """1.24.0 U.SplatShape: limit L / W = (1 / sin a) x stretch to emax, keeping the speed"""
    vel = np.array(vel, float); sp = np.linalg.norm(vel)
    if sp < 1e-3: return vel, stretch
    vn = vel[2]; vt = vel.copy(); vt[2] = 0; vts = np.linalg.norm(vt)
    sinA = abs(vn) / sp
    stretch = max(stretch, 1.0)
    if min(np.clip(1 / max(sinA, 0.12), 1, 8) * min(stretch, 8), 10) <= emax: return vel, stretch
    stretch = min(stretch, 1.0 + (emax - 1.0) * 0.35)
    eA = 1 / max(sinA, 1e-3)
    lim = emax / stretch
    if eA > lim and vts > 1e-3:
        s2 = 1 / lim; c2 = math.sqrt(max(1 - s2 * s2, 0))
        vel = vt / vts * sp * c2 + np.array([0, 0, -sp * s2 if vn <= 0 else sp * s2])
    return vel, stretch

def throw(drops, version, emax=3.5):
    """drops: list of (pos3, vel3, rmm, stretch, spin) -> impacts on the floor z = 0 (with 1.23 ricochet + slide stretch)"""
    ims, slides = [], []
    queue = list(drops)
    while queue:
        pos, vel, rmm, stretch, spin, skips = queue.pop()
        pos = np.array(pos, float); vel = np.array(vel, float)
        a, bq, c = -0.5 * G, vel[2], pos[2]
        tland = (-bq - math.sqrt(bq * bq - 4 * a * c)) / (2 * a)
        hit = pos + vel * tland + np.array([0, 0, -0.5 * G * tland * tland])
        v = vel + np.array([0, 0, -G * tland])
        stretch = 1 + (stretch - 1) * math.exp(-tland / 0.09)
        vol = 4.18879 * rmm ** 3
        speed = np.linalg.norm(v); sinA = abs(v[2]) / speed; vt = v.copy(); vt[2] = 0; vts = np.linalg.norm(vt)
        # ricochet (P.Land)
        if sinA < 0.34 and vts > 170 and rmm > 0.22 and skips < 2:
            f = np.clip((0.34 - sinA) / 0.28, 0, 1) * 0.65 * (1 - 0.35)
            if f > 0.08:
                cv = vol * f; vol -= cv
                stretch *= (1 + 1.4 * f)
                tdir = vt / vts
                queue.append((hit + np.array([0, 0, 0.3]) + tdir * (rmm / 19.05 * 3), vt * rng.uniform(0.5, 0.72) + np.array([0, 0, abs(v[2]) * rng.uniform(0.12, 0.3)]),
                              (cv / 4.18879) ** (1 / 3), 1.4 + f, spin * 0.5, skips + 1))
        R, spines, K = stain(rmm, v)
        # fast drops: stretch + sliding droplet (concrete: fabric 0.35)
        if vts > 140 and sinA < 0.94:
            f = np.clip((vts - 140) / 520, 0, 1)
            stretch *= (1 + min(0.45 * f * (1 - sinA * sinA), 0.5))
            if vol > 1.2 and rmm > 0.3 and (version < 124 or vts > 260):
                sv = vol * (min(0.45, 0.12 + 0.3 * f) if version < 124 else min(0.25, 0.08 + 0.15 * f))
                if sv >= 0.6:
                    slides.append((hit[:2].copy(), vt[:2] / vts, vts, sv, version))
                    vol -= sv
        if version >= 124: v, stretch = shape_v124(v, stretch, emax)
        ims.append(dict(pos=hit[:2], vel=v, R=R, vol=vol, spines=spines, K=K, stretch=stretch, spin=spin, seed=rng.random()))
    return ims, slides

def slide_trail(field, ox, oy, s, rough=0.8):
    """cl_runs StepSlide: the rivulet of a sliding droplet (1.23: start speed min(0.12 vts, 70); 1.24: shorter, straighter)"""
    p, d, vts, vol, version = s
    if version >= 124:
        if vts < 260: return
        sp = min(vts * 0.045, 22.0); amp = 0.02
    else:
        sp = min(vts * 0.12, 70.0); amp = 0.06 + 0.22 * rough
    pos = np.array(p, float); h = math.atan2(d[1], d[0]); dt = 1 / 30; dist = 0; ph = rng.random() * 6.28; k = rng.uniform(0.35, 0.8)
    width = np.clip(1.3 + 0.55 * vol ** (1 / 3), 1.6, 4.6) / 19.05 * 0.5
    while sp > 2:
        drag = (2.2 + 3 * rough) * sp + (40 + 90 * rough)
        sp = max(sp - drag * dt, 0)
        ds = sp * dt; dist += ds
        hh = h + amp * math.sin(dist * k + ph) * 4
        n = max(int(ds / (PX * 0.5)), 1)
        for i in range(n):
            pos = pos + np.array([math.cos(hh), math.sin(hh)]) * ds / n
            cx, cy = (pos[0] - ox) / PX, (pos[1] - oy) / PX
            r = width / PX
            x0, x1 = int(max(cx - r - 1, 0)), int(min(cx + r + 2, field.shape[1])); y0, y1 = int(max(cy - r - 1, 0)), int(min(cy + r + 2, field.shape[0]))
            if x1 <= x0 or y1 <= y0: continue
            gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
            dd = np.hypot(gx - cx, gy - cy) / max(r, 0.5)
            field[y0:y1, x0:x1] = np.maximum(field[y0:y1, x0:x1], sat(1 - dd * dd) * 0.08)
    # the bead at the end
    cx, cy = (pos[0] - ox) / PX, (pos[1] - oy) / PX; r = width * 2.2 / PX
    x0, x1 = int(max(cx - r - 1, 0)), int(min(cx + r + 2, field.shape[1])); y0, y1 = int(max(cy - r - 1, 0)), int(min(cy + r + 2, field.shape[0]))
    if x1 > x0 and y1 > y0:
        gx, gy = np.meshgrid(np.arange(x0, x1) + 0.5, np.arange(y0, y1) + 0.5)
        dd = np.hypot(gx - cx, gy - cy) / r
        field[y0:y1, x0:x1] += np.sqrt(sat(1 - dd * dd)) * 0.25

def drop_radius(r0, s):
    x = rng.random() + rng.random() + rng.random() - 1.5
    return float(np.clip(r0 * math.exp(x * s), 0.05, 4))

def cone_dir(axis, cone):
    axis = axis / np.linalg.norm(axis)
    while True:
        v = rng.normal(size=3); v /= np.linalg.norm(v)
        if np.dot(v, axis) > math.cos(cone): return v

def smash_v123(origin, nrm, k=2.0):
    """cl_wounds 1.23.2 smash spray: around nrm + 0.4 z, cone 0.9, 60..260 u/s"""
    axis = np.array(nrm, float) + np.array([0, 0, 0.4]); axis /= np.linalg.norm(axis)
    out = []
    for _ in range(int(14 * k)):
        d = cone_dir(axis, 0.9)
        r = drop_radius(0.6, 0.8)
        sp = rng.uniform(60, 260) * np.clip((0.6 / r) ** 0.25, 0.6, 1.6)
        out.append((origin + d * rng.uniform(0, 0.5), d * sp, r, rng.uniform(1, 1.6), rng.uniform(-40, 40), 0))
    return out

def smash_v124(origin, k=2.0):
    """1.24.0 burst (cl_wounds W.Burst): out all round and up (elevation 15..60 deg), slower big drops, a few fine ones"""
    out = []
    n = int(16 * k)
    for i in range(n):
        az = (i + rng.random() * 0.8) / n * 2 * math.pi
        el = math.radians(rng.uniform(15, 60))
        d = np.array([math.cos(az) * math.cos(el), math.sin(az) * math.cos(el), math.sin(el)])
        r = drop_radius(0.7, 0.7)
        sp = rng.uniform(50, 170) * np.clip((0.6 / r) ** 0.25, 0.6, 1.4)
        out.append((origin + d * rng.uniform(0, 1.5), d * sp, r, 1.0, rng.uniform(-30, 30), 0))
    return out

def render(field, title):
    H, W = field.shape
    yy, xx = np.mgrid[0:H, 0:W]
    floor = 0.58 + 0.06 * (vnoise(xx * 0.09, yy * 0.09) - 0.5) + 0.05 * (vnoise(xx * 0.6, yy * 0.6) - 0.5)
    k = np.array([0.55, 7.0, 7.5])                     # absorption per mm of film (red passes)
    h = np.clip(field, 0, 3)[..., None]
    T = np.exp(-k * h * 2)
    col = floor[..., None] * T
    col = col * (1 - 0.08 * sat(h * 4))                # the film's own surface sheen (darker cap)
    img = Image.fromarray((np.clip(col, 0, 1) ** (1 / 1.15) * 255).astype(np.uint8))
    d = ImageDraw.Draw(img)
    try: font = ImageFont.truetype("DejaVuSans-Bold.ttf", 22)
    except OSError: font = ImageFont.load_default()
    d.rectangle([0, 0, W, 34], fill=(20, 20, 22)); d.text((10, 6), title, font=font, fill=(235, 235, 235))
    return img

def scene(drops, version, title, emax=3.5, extent=(-30, 30, -30, 30)):
    ox, x1, oy, y1 = extent
    field = np.zeros((int((y1 - oy) / PX), int((x1 - ox) / PX)))
    ims, slides = throw(drops, version, emax)
    for im in ims: splat(field, ox, oy, im)
    for s in slides: slide_trail(field, ox, oy, s)
    e = [min(np.clip(1 / max(abs(im["vel"][2]) / np.linalg.norm(im["vel"]), 0.12), 1, 8) * np.clip(im["stretch"], 1, 8), 10) for im in ims]
    return render(field, title), e

def grazing(n=26, speed=1300, pitch=(5, 14)):
    """drops thrown along a floor fast and flat - what a body sliding / tumbling past at speed sheds (gm_falleritus)"""
    out = []
    for _ in range(n):
        el = -math.radians(rng.uniform(*pitch)); az = math.radians(rng.normal(0, 4))
        d = np.array([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])
        r = drop_radius(0.9, 0.6)
        out.append((np.array([rng.uniform(-38, -20), rng.uniform(-14, 14), rng.uniform(0.5, 3)]), d * speed * rng.uniform(0.6, 1.0), r,
                    rng.uniform(1, 1.6), rng.uniform(-40, 40), 0))
    return out

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "splat_preview.png"
    rows = []
    origin = np.array([0.0, 0.0, 4.0])
    ext = (-16, 16, -16, 16)
    rng = np.random.default_rng(3); dg = grazing()
    rng = np.random.default_rng(3); a, e1 = scene(dg, 123, "1.23: fast flat drops", extent=ext)
    rng = np.random.default_rng(3); dg = grazing()
    rng = np.random.default_rng(3); b, e2 = scene(dg, 124, "1.24: same drops", extent=ext)
    rng = np.random.default_rng(11); d1 = smash_v123(origin, (1, 0, 0)) + smash_v123(origin, (0.3, -0.9, 0))
    rng = np.random.default_rng(11); c, e3 = scene(d1, 123, "1.23: fall smash spray", extent=ext)
    rng = np.random.default_rng(5); d3 = smash_v124(origin, 2.0)
    rng = np.random.default_rng(5); d, e4 = scene(d3, 124, "1.24: burst", extent=ext)
    W, H = a.width, a.height
    sheet = Image.new("RGB", (W * 2 + 10, H * 2 + 10), (10, 10, 10))
    sheet.paste(a, (0, 0)); sheet.paste(b, (W + 10, 0)); sheet.paste(c, (0, H + 10)); sheet.paste(d, (W + 10, H + 10))
    sheet.save(out)
    for nm, e in (("1.23 flat", e1), ("1.24 flat", e2), ("1.23 smash", e3), ("1.24 burst", e4)):
        e = np.array(e); print("%-14s stains %3d  L/W median %.1f  max %.1f  >5: %d" % (nm, len(e), np.median(e), e.max(), (e > 5).sum()))
