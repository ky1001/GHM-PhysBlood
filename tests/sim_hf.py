"""numpy port of the world-patch (height field) simulation step, ghmpb_sim_main.h with SIM_HF = 1 (1.19.0: with the
ring curvature / nearby-pool pull of the contact line on floors; model={'ring': False} for the 1.18 rule; no froth).

Used offline to tune how blood runs on walls and spreads on floors before building shaders. Mirrors the HLSL
closely (same edge transfer, contact line, column weight, levelling, coagulation, drying); the patch is a single
square with open (run-off) borders.
Units as in the shader: h, s in mm; accelerations cm/s^2; velocities texels/s; bed in cm.
"""
import numpy as np

RHO = 1.06
LEV_H = 0.8
DIRS = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]


def hash12(px, py):
    p3x = np.modf(px * 0.1031)[0]
    p3y = np.modf(py * 0.1031)[0]
    p3z = p3x.copy()
    # p3 = frac(p.xyx * 0.1031); p3 += dot(p3, p3.yzx + 33.33)
    d = p3x * (p3y + 33.33) + p3y * (p3z + 33.33) + p3z * (p3x + 33.33)
    p3x = p3x + d
    p3y = p3y + d
    p3z = p3z + d
    r = (p3x + p3y) * p3z
    return r - np.floor(r)


def vnoise(px, py):
    ix, iy = np.floor(px), np.floor(py)
    fx, fy = px - ix, py - iy
    ux, uy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a = hash12(ix, iy)
    b = hash12(ix + 1, iy)
    c = hash12(ix, iy + 1)
    d = hash12(ix + 1, iy + 1)
    return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy


def smooth(n):
    return n * n * (3 - 2 * n)


def _ss(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def _vr(x, y, sc, a, o):
    c, s = np.cos(a), np.sin(a)
    return vnoise((c * x - s * y) / sc + o, (s * x + c * y) / sc + o * 1.7)


def floor_relief_126p(qx, qy, texU):
    """Mirror of the 1.26.1-pools floor relief in pforce_ps30.hlsl (u), incl. the shader's coarse 2x2-quad ddx / ddy."""
    wx = qx + 8.0 * _vr(qx, qy, 9.0, 0.3, 3.7) - 4.0
    wy = qy + 8.0 * _vr(qx, qy, 9.0, 1.1, 8.1) - 4.0
    rl = 0.55 * _vr(wx, wy, 14.0, 0.5, 13.1) + 0.35 * _vr(wx, wy, 5.5, 1.3, 26.2) + 0.10 * _vr(wx, wy, 2.4, 2.1, 39.3)
    n1 = _vr(wx, wy, 6.0, 0.8, 11.0)
    gx = np.repeat(n1[:, 1::2] - n1[:, 0::2], 2, axis=1) / texU
    gy = np.repeat(n1[1::2, :] - n1[0::2, :], 2, axis=0) / texU
    groove = (1 - _ss(0.36, 0.9, np.abs(n1 - 0.5) / np.maximum(np.hypot(gx, gy), 0.02))) * _ss(0.42, 0.48, _vr(qx, qy, 14.0, 2.4, 9.0))
    return 0.3 * (rl - 0.5) - 0.12 * groove - 0.05 * _ss(0.66, 0.84, _vr(qx, qy, 2.8, 0.7, 51.0))


def floor_pin_126p(qx, qy):
    nf = 0.75 * vnoise(qx * 0.384, qy * 0.384) + 0.25 * vnoise(qx * 0.96 + 17, qy * 0.96 + 17)
    return 0.75 + 0.6 * smooth(nf)


SURF = {
    'stone': dict(rough=0.85, mu=0.09, pin=0.50, hret=0.050, hdry=0.003, lift=0.45, liftk=3.0, kabs=0.03, cap=0.25, pressPin=1.5),
    'plaster': dict(rough=0.55, mu=0.08, pin=0.45, hret=0.045, hdry=0.003, lift=0.45, liftk=3.0, kabs=0.09, cap=0.45, pressPin=1.5),
    'sealed': dict(rough=0.25, mu=0.06, pin=0.35, hret=0.040, hdry=0.003, lift=0.45, liftk=3.0, kabs=0.00, cap=1.0, pressPin=1.5),
    'brick': dict(rough=0.90, mu=0.10, pin=0.60, hret=0.060, hdry=0.003, lift=0.45, liftk=3.0, kabs=0.12, cap=0.60, pressPin=1.5),
    'metal': dict(rough=0.10, mu=0.06, pin=0.22, hret=0.025, hdry=0.003, lift=0.35, liftk=3.5, kabs=0.00, cap=1.0, pressPin=1.5),
    'wood': dict(rough=0.60, mu=0.10, pin=0.55, hret=0.050, hdry=0.003, lift=0.45, liftk=3.0, kabs=0.06, cap=0.35, pressPin=1.5),
}


class Patch:
    """res x res patch of 40 u; plane gravity (gU, gV, gN) in cm/s^2 (gN < 0: pressed into the plane)."""

    def __init__(self, res=256, surf='stone', grav=(0.0, 980.0, 0.0), thick=1.6, visc=1.0, drytime=240.0,
                 coagtime=90.0, coag=True, uneven=1.0, gx=0, gy=0, model=None, shape=None, texres=256):
        self.res = res
        self.shape = shape or (res, res)
        self.texU = 40.0 / texres              # texel size (u)
        self.L = self.texU * 1.905              # cm
        sf = SURF[surf]
        self.sf = sf
        self.model = model or {}
        self.C0 = (1.0 / res, 1.0 / res, 1.0 / 30.0)
        self.C1 = (sf['mu'] * visc, sf['pin'], sf['hret'], sf['hdry'])
        self.C2 = (sf['lift'] * np.sqrt(thick), sf['liftk'], 1.0 / max(drytime, 5.0), sf['kabs'])
        self.C3 = (sf['cap'], sf['pressPin'] * 2.3, 0.5, 0.5)
        rate = (4.8 / max(coagtime, 5.0)) if coag else 0.0
        self.C11 = (rate, 45.0, 6.0, 0.6)
        self.C12w = thick - 1.0
        self.C13 = (1.0, grav[0], grav[1], grav[2])
        n = res
        y, x = np.mgrid[0:self.shape[0], 0:self.shape[1]].astype(np.float64)
        # force: bed (cm), curvature, pin noise, L
        q = np.stack([x * self.texU, y * self.texU])
        micro = 0.22 * uneven * (0.6 * vnoise(q[0] / 34.0, q[1] / 34.0) + 0.3 * vnoise(q[0] / 13.0 + 7.3, q[1] / 13.0 + 7.3)
                                 + 0.1 * vnoise(q[0] / 5.0 + 3.1, q[1] / 5.0 + 3.1))
        self.bedU = np.zeros(self.shape) + micro
        p = (x + 0.5 + gx, y + 0.5 + gy)
        nn = 0.65 * vnoise(p[0] * 0.09, p[1] * 0.09) + 0.25 * vnoise(p[0] * 0.27 + 17, p[1] * 0.27 + 17) + 0.1 * vnoise(p[0] * 0.8 + 41, p[1] * 0.8 + 41)
        self.pin = 0.6 + (1.75 - 0.6) * smooth(nn)
        if self.model.get('floor126p'):
            # 1.26.1-pools pforce_ps30 on floors: warped dips + worn grooves + pits, smoother world-space pin noise
            self.bedU = uneven * floor_relief_126p(q[0] + 0.5 * self.texU, q[1] + 0.5 * self.texU, self.texU)
            self.pin = floor_pin_126p(q[0] + 0.5 * self.texU, q[1] + 0.5 * self.texU)
        self.valid = np.ones(self.shape, bool)
        self.update_force()
        z = np.zeros(self.shape)
        self.h, self.s, self.mx, self.my = z.copy(), z.copy(), z.copy(), z.copy()
        self.clot, self.wetn, self.colw, self.alt = z.copy(), z.copy(), z.copy(), z.copy()
        self.lift_acc, self.edge_acc = 0.0, 0.0
        self.parity = 0
        self.t = 0.0

    def update_force(self):
        b = self.bedU
        lap = (np.roll(b, 1, 1) + np.roll(b, -1, 1) + np.roll(b, 1, 0) + np.roll(b, -1, 0)) * 0.25 - b
        self.curv = np.clip(lap / 0.2, -1, 1)
        self.bed = b * 1.905

    # ------------------------------------------------------------------ neighbour access (no neighbour patches)
    def nb(self, a, dx, dy, fill=0.0):
        H, W = self.shape
        out = np.full_like(a, fill)
        ys = slice(max(0, -dy), H - max(0, dy)); yd = slice(max(0, dy), H - max(0, -dy))
        xs = slice(max(0, -dx), W - max(0, dx)); xd = slice(max(0, dx), W - max(0, -dx))
        out[ys, xs] = a[yd, xd]
        return out

    def inside(self, dx, dy):
        H, W = self.shape
        m = np.zeros(self.shape, bool)
        ys = slice(max(0, -dy), H - max(0, dy)); xs = slice(max(0, -dx), W - max(0, dx))
        m[ys, xs] = True
        return m

    def edgeT(self, hi, hj, fiX, fjX, fiK, fjK, vi, vj, d, w, jValid, pinI, pinJ, cfI, cfJ, nI, nJ, wI, wJ, midx, midy):
        C1, C3, C11, C13 = self.C1, self.C3, self.C11, self.C13
        dist = np.hypot(*d)
        hj = np.where(jValid, hj, 0.0)
        fjx = np.where(jValid, fjX, fiX)
        L = self.L
        aAlong = (C13[1] * d[0] + C13[2] * d[1]) / dist
        aPress = max(0.0, -C13[3])
        G = aAlong + aPress * ((fiX + 0.1 * hi) - (fjx + 0.1 * hj)) / (dist * L)
        Gpin = np.abs(aAlong + (G - aAlong) * L / 0.3)
        viA = (vi[0] * d[0] + vi[1] * d[1]) / dist
        vjA = np.where(jValid, (vj[0] * d[0] + vj[1] * d[1]) / dist, 0.0)
        fwd = (G + 0.5 * (viA + vjA) * L * 10.0) >= 0.0
        hd = np.where(fwd, hi, hj)
        hr = np.where(fwd, hj, hi)
        cfd = np.where(fwd, cfI, cfJ)
        Gd = np.abs(G)
        vd = np.where(fwd, np.maximum(0, viA), np.maximum(0, -vjA))
        wd = np.where(fwd, wI, wJ)
        drive = np.maximum(hd, wd) * Gpin / 980.0
        press = min(max(aPress / 980.0, 0.0), 1.0)
        m = self.model
        gl = np.hypot(C13[1], C13[2])
        # (1.19.0: on floors and gentle slopes n carries the ring curvature and the pull of nearby pools: down to 0.2)
        capf = np.clip(3.0 / np.maximum(np.where(fwd, nJ, nI), 0.5), 0.2 if gl <= 200.0 else 0.5, m.get('capf_hi', 2.5) if gl <= 200.0 else 2.5)
        # cosine between the flow direction and straight downhill (in the plane)
        downc = np.where(fwd, 1.0, -1.0) * (C13[1] * d[0] + C13[2] * d[1]) / (dist * max(gl, 1e-3))
        if m.get('capf_down') is not None:
            steep = min(gl / 980.0, 1.0)
            lim = m['capf_down']
            capf = np.where(downc > 0.6, np.minimum(capf, lim + (2.5 - lim) * (1 - steep)), capf)
        diagW = m.get('diag_wall', 1.8)
        pinSel = np.where(fwd, pinJ, pinI)
        if m.get('mkt'):
            pinSel = np.maximum(pinSel, 1e-3) ** m['mkt'].get('pa', 0.3)
        Pn = C1[1] * m.get('pin_mul', 1.0) * pinSel * (1.0 + C11[2] * cfd * cfd) * (1.0 + C3[1] * aPress / 980.0) * capf \
            * (1.0 + self.C12w * press) * ((0.7071 + (diagW - 0.7071) * (1 - press)) if w < 0.99 else 1.0)
        if m.get('hook_meander') and w < 0.99:
            Pn = m['hook_meander'](self, Pn, d, fwd, midx, midy, downc, press)
        kR = np.where(fwd, fjK, fiK)
        drop = np.where(fwd, fiX - fjx, fjx - fiX)
        Pn = Pn * (1.0 + 1.2 * np.clip((drop - 0.08) / 0.5, 0, 1))
        Pn = Pn * (1.0 + (0.22 - 1.0) * np.clip(kR, 0, 1))
        if m.get('hook_pn'):
            Pn = m['hook_pn'](self, Pn, d, fwd, midx, midy, hd, wd, np.where(fwd, nJ, nI))
        dry = hr < C1[3]
        pinf = np.where(dry, np.clip((drive - Pn) / Pn, 0, 1), 1.0)
        if m.get('mob_k'):
            # (1.27.0) contact-line mobility: how fast the front advances onto a dry texel falls with its pinning
            pinX = np.where(fwd, pinJ, pinI)
            mob = np.clip((m['mob_p0'] / np.maximum(pinX, 1e-3)) ** m['mob_k'], m.get('mob_lo', 0.03), m.get('mob_hi', 2.0))
            pinf = np.where(dry, pinf * mob, pinf)
        mu = C1[0] * (1.0 + C11[1] * cfd ** 3)
        hc = hd * 0.1
        u = (RHO * hc * hc / (3.0 * mu)) * Gd / L
        u = u * pinf + vd * np.where(dry & (hd < 0.1), 0.0, 1.0) * (1.0 - cfd)
        u = np.minimum(u * self.C0[2], 0.5)
        if m.get('mkt'):
            # (1.27.0) the front advances onto dry texels at a speed set by the surface there (contact-line mobility,
            # molecular-kinetic wetting: exponential in the local surface energy) - after the step cap, so it is a speed
            pinX = np.maximum(np.where(fwd, pinJ, pinI), 1e-3)
            mob = np.clip(pinX ** -m['mkt'].get('kf', 3.0), m['mkt'].get('lo', 0.02), m['mkt'].get('hi', 1.0))
            # (until the target holds a real film, not just its first wetting)
            mw = np.clip(1.0 - hr / m['mkt'].get('hf', 0.3), 0, 1)
            u = u * (1.0 + (mob - 1.0) * mw)
        hret = C1[2] * (1.0 + (np.sqrt(1.0 + self.C12w) - 1.0) * press)
        avail = np.maximum(hd - hret, 0.0)
        cap = np.where(hd > LEV_H, 0.1, 0.125)
        T = np.minimum(avail * u * w, avail * cap)
        if m.get('dbg') is not None:
            m['dbg'].append((dry & (hd > 0.05), pinf, u, Pn, drive))
        return np.where(fwd, T, -T)

    def step(self):
        C0, C1, C2, C3, C11, C13 = self.C0, self.C1, self.C2, self.C3, self.C11, self.C13
        dt = C0[2]
        n = self.res
        hi = np.maximum(self.h, 0.0)
        with np.errstate(divide='ignore', invalid='ignore'):
            vi = (np.where(hi > 1e-5, self.mx / hi, 0.0), np.where(hi > 1e-5, self.my / hi, 0.0))
        clot = np.clip(self.clot, 0, hi)
        cfI = np.where(hi > 1e-5, clot / np.maximum(hi, 1e-9), 0.0)
        nI, wI = self.wetn, self.colw
        gt = np.array([C13[1], C13[2]])
        gl = np.hypot(*gt)
        gdir = gt / gl if gl > 1e-3 else np.zeros(2)
        fiX, fiK = self.bed, self.curv
        upBest = np.full(self.shape, 0.5)
        wUp = np.zeros(self.shape)
        wetN = np.zeros(self.shape)
        outSum = np.zeros(self.shape)
        mom = [self.mx.copy(), self.my.copy()]
        edgeOut = np.zeros(self.shape)
        clotOut = np.zeros(self.shape); clotIn = np.zeros(self.shape)
        pinMul = self.pin
        for k, (dx, dy) in enumerate(DIRS):
            w = 1.0 if k < 4 else C3[3]
            ins = self.inside(dx, dy)
            if k >= 4:
                # diagonal edges crossing the border are skipped
                pass
            sjh = self.nb(hi, dx, dy)
            fjX = self.nb(fiX, dx, dy)
            fjK = self.nb(fiK, dx, dy)
            validJ = self.nb(self.valid.astype(float), dx, dy) > 0.5
            jValid = ins & validJ
            hj_all = np.maximum(sjh, 0)
            clotJ = self.nb(self.clot, dx, dy)
            cfJ = np.where(sjh > 1e-5, np.clip(clotJ / np.maximum(sjh, 1e-9), 0, 1), 0.0)
            nJ = np.where(ins, self.nb(self.wetn, dx, dy), 3.0)
            nIe = np.where(ins, nI, 3.0)
            wJ = np.where(ins & jValid, self.nb(self.colw, dx, dy), hj_all)
            kJ = np.where(ins, fjK, fiK)
            pinJ = np.where(jValid, self.nb(pinMul, dx, dy), pinMul)
            vjx = self.nb(self.mx, dx, dy); vjy = self.nb(self.my, dx, dy)
            with np.errstate(divide='ignore', invalid='ignore'):
                vj = (np.where(sjh > 1e-5, vjx / np.maximum(sjh, 1e-9), 0.0), np.where(sjh > 1e-5, vjy / np.maximum(sjh, 1e-9), 0.0))
            skip = (~ins) & (k >= 4)
            midx = np.arange(self.shape[1])[None, :] + 0.5 * dx + np.zeros(self.shape)
            midy = np.arange(self.shape[0])[:, None] + 0.5 * dy + np.zeros(self.shape)
            T = self.edgeT(hi, hj_all, fiX, np.where(ins, fjX, fiX), fiK, kJ, vi, vj, (dx, dy), w, jValid, pinMul, pinJ,
                           cfI, cfJ, nIe, nJ, np.where(ins, wI, hi), wJ, midx, midy)
            T = np.where(skip, 0.0, T)
            hj = np.where(jValid, hj_all, 0.0)
            up = -(dx * gdir[0] + dy * gdir[1]) / np.hypot(dx, dy)
            sel = (~skip) & jValid & (up > upBest) & (hj > C1[3])
            upBest = np.where(sel, up, upBest)
            wUp = np.where(sel, wJ, wUp)
            wetN += np.where((~skip) & jValid & (hj > C1[3]), 1.0, 0.0)
            T = np.where((~skip) & (~jValid), np.maximum(T, 0.0), T)
            edgeOut += np.where((~skip) & (~jValid), T, 0.0)
            outSum += T
            inflow = np.maximum(-T, 0.0)
            mom[0] += inflow * vj[0] - np.maximum(T, 0) * vi[0]
            mom[1] += inflow * vj[1] - np.maximum(T, 0) * vi[1]
            clotOut += np.maximum(T, 0) * cfI
            clotIn += inflow * cfJ
        # levelling (floors)
        aPressL = max(0.0, -C13[3])
        if aPressL > 100.0 and not self.model.get('no_lev'):
            lev = hi > LEV_H
            if lev.any():
                headI = fiX * 10.0 + hi
                availI = np.maximum(hi - C1[2], 0.0)
                lamB = (1.0 / 24.0) * np.clip(0.07 / max(C1[0], 1e-3), 0.25, 1.0)
                par = self.parity
                laxis = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                ldiag = [(1, 1), (-1, -1), (-1, 1), (1, -1)]
                saxis = [4, 12, 32]
                sdiag = [2, 6, 16]
                ph = getattr(self, 'stepn', 0) % 4 if self.model.get('lev_rot') else par
                for q in range(3):
                    for k2 in range(4):
                        d2 = ldiag[k2] if par else laxis[k2]
                        stq = sdiag[q] if par else saxis[q]
                        ox, oy = d2[0] * stq, d2[1] * stq
                        mx_, my_ = d2[0] * stq // 2, d2[1] * stq // 2
                        if self.model.get('lev_rot') and ph >= 2:
                            # (1.27.0) two more stencils, turned 26.6 / 63.4 degrees: the head spreads evenly in every
                            # direction instead of along 8 (octagonal pools)
                            ux, uy = (2.0, 1.0) if ph == 2 else (1.0, 2.0)
                            nrm = (ux * ux + uy * uy) ** 0.5
                            ang = [(ux, uy), (-uy, ux), (-ux, -uy), (uy, -ux)][k2]
                            stv = saxis[q]
                            ox, oy = int(round(ang[0] / nrm * stv)), int(round(ang[1] / nrm * stv))
                            mx_, my_ = ox // 2, oy // 2          # (floor: the same midpoint seen from both ends)
                            d2 = (ang[0] / nrm, ang[1] / nrm); stq = stv
                        insq = self.inside(ox, oy)
                        hjq = np.maximum(self.nb(hi, ox, oy), 0)
                        fjq = self.nb(fiX, ox, oy)
                        hm = self.nb(hi, mx_, my_)
                        ok = lev & insq & (hjq > LEV_H) & (hm > LEV_H)
                        cfJ = np.clip(self.nb(self.clot, ox, oy) / np.maximum(hjq, 1e-9), 0, 1)
                        cfm = np.maximum(cfI, cfJ)
                        dH = headI - (fjq * 10.0 + hjq) + 10.0 * (C13[1] * d2[0] + C13[2] * d2[1]) * stq * self.L / aPressL
                        lam = lamB * (1 - cfm) ** 2
                        T = np.clip(lam * dH, -np.maximum(hjq - C1[2], 0) / 60.0, availI / 60.0)
                        T = np.where(ok, T, 0.0)
                        outSum += T
                        inflow = np.maximum(-T, 0)
                        clotOut += np.maximum(T, 0) * cfI
                        clotIn += inflow * cfJ
                        mom[0] -= np.maximum(T, 0) * vi[0]
                        mom[1] -= np.maximum(T, 0) * vi[1]
            self.parity = 1 - self.parity
        self.stepn = getattr(self, 'stepn', 0) + 1
        h = np.maximum(hi - outSum, 0.0)
        s = self.s
        clot = np.clip(clot - clotOut + clotIn, 0, h)
        cf = np.where(h > 1e-5, clot / np.maximum(h, 1e-9), 0.0)
        cf = np.clip(cf + C11[0] * (0.06 + cf) * (1 - cf) * dt, 0, 1)
        An = C13[3]
        if An > 0:
            hl = C2[0] * 980.0 / max(An, 1.0) * (1.0 + 3.0 * cf)
            lift = np.maximum(0, h - hl) * min(1.0, C2[1] * dt) * (1 - 0.8 * cf)
            h = h - lift
            self.lift_acc += lift.sum()
        hc = np.maximum(h * 0.1, 1e-4)
        muS = C1[0] * (1.0 + C11[1] * cf ** 3)
        decay = np.exp(-np.minimum(3.0 * muS / (RHO * hc * hc) * C3[2] * dt, 30.0))
        vx = np.where(h > 1e-5, mom[0] / np.maximum(h, 1e-9) * decay, 0.0)
        vy = np.where(h > 1e-5, mom[1] / np.maximum(h, 1e-9) * decay, 0.0)
        vx = np.clip(vx, -150, 150); vy = np.clip(vy, -150, 150)
        kdry = C2[2] * np.clip(0.3 / (h + 0.1), 0.25, 3.0) * (1.0 - C11[3] * cf)
        kabs = C2[3] * np.clip(1.0 - s / max(C3[0], 1e-3), 0, 1) * (1.0 - 0.7 * cf)
        m = self.model
        if m.get('hook_dry'):
            kdry, kabs = m['hook_dry'](self, h, s, cf, kdry, kabs)
        dd = h * (1.0 - np.exp(-(kdry + kabs) * dt))
        h = h - dd
        s = s + dd
        small = h < 1e-4
        s = np.where(small, s + h, s)
        h = np.where(small, 0.0, h)
        vx = np.where(small, 0.0, vx); vy = np.where(small, 0.0, vy)
        self.clot = np.minimum(cf * h, h)
        self.edge_acc += edgeOut.sum()
        self.h, self.s = h, s
        self.mx, self.my = h * vx, h * vy
        # (1.19.0) the contact line a few texels out (floors, gentle slopes): ring curvature + pools pulling together
        if gl <= 200.0 and self.model.get('ring', True):
            wetN = self.ring_n(hi, wetN)
        self.wetn = wetN
        steep = gl > 200.0
        decayW = m.get('colw_decay', 0.85)
        self.colw = np.where((h > C1[3]) & steep, np.minimum(h + decayW * wUp, m.get('colw_cap', 8.0)), h)
        self.t += dt

    RING = [(2, 1), (1, 2), (-1, 2), (-2, 1), (-2, -1), (-1, -2), (1, -2), (2, -1)]
    FAR = [(5, 0), (0, 5), (4, 4), (4, -4)]

    def ring_n(self, hi, wetN):
        hdry = self.C1[3]
        cnt = np.zeros(self.shape)
        rw, rp = [], []
        for dx, dy in self.RING:
            ins = self.inside(dx, dy)
            hq = np.where(ins, self.nb(hi, dx, dy), 0.0)
            w = np.where(ins, (hq > hdry).astype(float), 0.5)
            rw.append(w); rp.append((hq > 0.12).astype(float))
            cnt += w
        pull = rp[0] * rp[4] + rp[1] * rp[5] + rp[2] * rp[6] + rp[3] * rp[7]
        for dx, dy in self.FAR:
            ha = np.where(self.inside(dx, dy), self.nb(hi, dx, dy), 0.0)
            hb = np.where(self.inside(-dx, -dy), self.nb(hi, -dx, -dy), 0.0)
            pull += ((ha > 0.12) & (hb > 0.12)).astype(float)
        n = 0.4 * wetN + 0.45 * cnt + np.where(pull > 0.5, 5.0, 0.0)
        return np.where((hi <= hdry) & (wetN > 0.5), n, wetN)

    # ------------------------------------------------------------------ deposits
    def splat(self, cx, cy, vol, Rmm, e=1.0, tdir=(0.0, 1.0), rk=0.2):
        """circular / elliptic dome stain at texel (cx, cy): volume mm^3, radius mm, elongation e along tdir"""
        y, x = np.mgrid[0:self.shape[0], 0:self.shape[1]].astype(np.float64)
        Lmm = self.L * 10.0
        dxm, dym = (x - cx) * Lmm, (y - cy) * Lmm
        t = np.array(tdir, float); t /= np.linalg.norm(t)
        xe = (dxm * t[0] + dym * t[1]) / (Rmm * e)
        ye = (-dxm * t[1] + dym * t[0]) / Rmm
        q = np.hypot(xe, ye)
        dens = np.where(q < 1, np.sqrt(np.clip(1 - q * q, 0, 1)), 0) + 0.32 * np.exp(-((q - 0.9) / 0.09) ** 2) * (q < 1.08)
        h0 = vol / (0.6667 * np.pi * Rmm * Rmm * e)
        dh = h0 * dens
        # (the stamp deposits per texel thickness; the discrete sum should match the volume)
        tot = dh.sum() * Lmm * Lmm
        if tot > 0:
            dh *= vol / tot
        self.h += dh * (1 - rk)
        self.s += dh * rk

    def source(self, cx, cy, vol, Rmm):
        y, x = np.mgrid[0:self.shape[0], 0:self.shape[1]].astype(np.float64)
        Lmm = self.L * 10.0
        r = np.hypot(x - cx, y - cy) * Lmm / Rmm
        g = np.exp(-r * r)
        g *= vol / (g.sum() * Lmm * Lmm)
        self.h += g

    def volume(self):
        Lmm2 = (self.L * 10.0) ** 2
        return self.h.sum() * Lmm2, self.s.sum() * Lmm2


def stain_R(dmm, vms):
    d = dmm / 1000
    vn = max(vms, 0.3)
    Re = 1060 * vn * d / 0.004
    D = max(1.2 * d, 0.5 * d * Re ** 0.25)
    return D * 0.5 * 1000   # mm


def render(p, path, scale=2, crop=None):
    from PIL import Image
    h, s = p.h, p.s
    tot = h + s
    # red for wet (brightness by thickness), dark brown for stain
    wet = np.clip(h / 0.6, 0, 1)
    st = np.clip(s / 0.2, 0, 1)
    img = np.ones(h.shape + (3,)) * np.array([0.85, 0.83, 0.8])
    stc = np.array([0.35, 0.12, 0.08])
    wc = np.array([0.55, 0.0, 0.02])
    img = img * (1 - st[..., None] * 0.9) + stc * st[..., None] * 0.9
    wa = np.clip(h / 0.05, 0, 1)[..., None]
    wcol = wc * (1 - 0.6 * wet[..., None])
    img = img * (1 - wa) + wcol * wa
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
    if crop:
        im = im.crop(crop)
    im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    im.save(path)
    return im
