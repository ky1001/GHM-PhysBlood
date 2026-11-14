"""CPU reference of the GHM PhysBlood cell simulation (the HLSL ghmpb_sim_ps30 mirrors this exactly).

State per texel: h (mm wet film), s (mm stain equivalent), vx, vy (impact velocity, texel/s)
Force per texel: Ax, Ay (cm/s^2 tangential accel along texel axes), An (cm/s^2 normal accel, >0 pulls off), L (cm texel size)
Gather formulation: every texel evaluates the 8 edge transfers with its neighbours using an expression that is
antisymmetric in (i, j), so the scheme conserves volume exactly.
"""
import numpy as np

RHO = 1.06          # g/cm^3
DIRS = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]


def params(**kw):
    p = dict(mu=0.06, pin=0.35, hret=0.04, pressPin=1.5, hdry=0.003, lift=0.45, liftk=3.0, tau=120.0, kabs=0.0, cap=1.0,
             wdiag=0.5, drag=0.5)
    p.update(kw)
    return p


def edge_transfer(hi, hj, Ai, Aj, Ani, Anj, Li, Lj, vi, vj, dx, dy, dt, p, voidj=None):
    """Volume (mm of texel thickness) moving i->j (positive) for offset (dx,dy). Arrays broadcast."""
    dist = np.hypot(dx, dy)
    w = 1.0 if dist < 1.5 else p['wdiag']
    L = 0.5 * (Li + Lj)
    a_along = 0.5 * ((Ai[0] + Aj[0]) * dx + (Ai[1] + Aj[1]) * dy) / dist
    a_press = 0.5 * (np.maximum(0, -Ani) + np.maximum(0, -Anj))
    G = a_along + a_press * (hi - hj) * 0.1 / (dist * L)            # cm/s^2 along edge i->j
    # impact velocity carried by the upwind side (texel/s along edge)
    vi_al = (vi[0] * dx + vi[1] * dy) / dist
    vj_al = (vj[0] * dx + vj[1] * dy) / dist
    fwd = (G + 0.5 * (vi_al + vj_al) * L * 10.0) >= 0              # compare in consistent-ish units
    hd = np.where(fwd, hi, hj)                                     # donor thickness mm
    hr = np.where(fwd, hj, hi)
    Gd = np.abs(G)
    vd = np.where(fwd, np.maximum(0, vi_al), np.maximum(0, -vj_al))
    # pinning: advancing into a dry texel needs  h * |G|/980 > pin
    drive = hd * Gd / 980.0
    P = p['pin'] * (1.0 + p['pressPin'] * a_press / 980.0)
    pinf = np.where(hr < p['hdry'], np.clip((drive - P) / P, 0, 1), 1.0)
    hc = hd * 0.1                                                  # cm
    u = (RHO * hc * hc / (3.0 * p['mu'])) * Gd / L                 # texel/s lubrication velocity
    u = u * pinf + vd * np.where((hr < p['hdry']) & (hd < 0.1), 0.0, 1.0)
    u = np.minimum(u * dt, 0.5)                                    # CFL cap (fraction of texel per step)
    avail = np.maximum(hd - p['hret'], 0.0)
    T = avail * u * w
    T = np.minimum(T, avail / 8.0)                                    # donor can never go negative
    return np.where(fwd, T, -T)


def step(h, s, vx, vy, F, dt, p, acc=None):
    Ax, Ay, An, L, valid = F
    H, W = h.shape
    out = np.zeros_like(h)
    mom_x = vx * h
    mom_y = vy * h
    newmx = mom_x.copy(); newmy = mom_y.copy()
    for dx, dy in DIRS:
        # neighbour j at (y+dy, x+dx); zero padding outside
        def sh(a, fill=0.0):
            b = np.full_like(a, fill)
            ys = slice(max(0, -dy), H - max(0, dy)); yd = slice(max(0, dy), H - max(0, -dy))
            xs = slice(max(0, -dx), W - max(0, dx)); xd = slice(max(0, dx), W - max(0, -dx))
            b[ys, xs] = a[yd, xd]
            return b
        hj = sh(h); Axj = sh(Ax); Ayj = sh(Ay); Anj = sh(An); Lj = sh(L, 1.0); vxj = sh(vx); vyj = sh(vy)
        vj_valid = sh(valid)
        T = edge_transfer(h, hj, (Ax, Ay), (Axj, Ayj), An, Anj, L, Lj, (vx, vy), (vxj, vyj), dx, dy, dt, p)
        # transfers into void neighbours leave the domain (edge run-off) -> acc
        T = np.where(vj_valid > 0, T, np.maximum(T, 0) * 1.0)
        out += T
        if acc is not None:
            acc += np.where(vj_valid > 0, 0.0, np.maximum(T, 0))
        # momentum transport (upwind)
        inflow = np.maximum(-T, 0)                                  # volume arriving from j
        newmx += inflow * vxj - np.maximum(T, 0) * vx
        newmy += inflow * vyj - np.maximum(T, 0) * vy
    h2 = np.maximum(h - out, 0) * valid
    # liftoff where the surface pulls away
    hl = p['lift'] * 980.0 / np.maximum(An, 1.0)
    lift = np.where(An > 0, np.maximum(0, h2 - hl) * min(1.0, p['liftk'] * dt), 0.0)
    h2 -= lift
    if acc is not None:
        acc += lift
    # momentum decay by viscous drag  exp(-3 mu / (rho h^2) dt)
    hc = np.maximum(h2 * 0.1, 1e-4)
    decay = np.exp(-np.minimum(3 * p['mu'] / (RHO * hc * hc) * p['drag'] * dt, 30))
    vx2 = np.where(h2 > 1e-5, newmx / np.maximum(h2, 1e-5) * decay, 0)
    vy2 = np.where(h2 > 1e-5, newmy / np.maximum(h2, 1e-5) * decay, 0)
    # drying + absorption
    kdry = (1.0 / p['tau']) * np.clip(0.3 / (h2 + 0.1), 0.25, 3.0)
    kabs = p['kabs'] * np.clip(1 - s / p['cap'], 0, 1)
    d = h2 * (1 - np.exp(-(kdry + kabs) * dt))
    h2 -= d; s2 = s + d
    tiny = h2 < 1e-4
    s2 = np.where(tiny, s2 + h2, s2); h2 = np.where(tiny, 0, h2)
    return h2, s2, vx2, vy2


def level(h, p, strides=(4, 12, 32), lam=1 / 24., capc=1 / 60., hmin=0.8):
    """1.10.0 levelling of thick pools (world patches on floors): texels of thick wet blood also exchange with the
    texels 4 / 12 / 32 away along the axes (blood continuous at the midpoint) in proportion to the head difference.
    Antisymmetric -> volume conserved; in the shader the regular edges then give at most 1/10 of a thick donor each
    so the total stays within the donor's blood. Levels a 200 ml pour to ~3 mm in a few seconds (without: ~30 s)."""
    H, W = h.shape
    def sh(a, dx, dy):
        b = np.zeros_like(a)
        ys = slice(max(0, -dy), H - max(0, dy)); yd = slice(max(0, dy), H - max(0, -dy))
        xs = slice(max(0, -dx), W - max(0, dx)); xd = slice(max(0, dx), W - max(0, -dx))
        b[ys, xs] = a[yd, xd]
        return b
    out = np.zeros_like(h)
    avail = np.maximum(h - p['hret'], 0)
    for st in strides:
        for dx, dy in ((st, 0), (-st, 0), (0, st), (0, -st)):
            hj = sh(h, dx, dy); aj = sh(avail, dx, dy); hm = sh(h, dx // 2, dy // 2)
            ok = (h > hmin) & (hj > hmin) & (hm > hmin)
            out += np.where(ok, np.clip(lam * (h - hj), -capc * aj, capc * avail), 0)
    return h - out


def splat(h, cx, cy, r, vol_mm3, L_cm, vx=None, vy=None, vxv=0.0, vyv=0.0):
    H, W = h.shape
    yy, xx = np.mgrid[0:H, 0:W]
    d2 = ((xx - cx) ** 2 + (yy - cy) ** 2) / (r * r)
    k = np.clip(1 - d2, 0, 1) ** 2
    area_mm2 = (L_cm * 10) ** 2
    k = k / k.sum() * vol_mm3 / area_mm2
    h += k
    if vx is not None:
        vx += np.where(k > 0, vxv, 0); vy += np.where(k > 0, vyv, 0)
    return h


def run_wall():
    N = 96; L = 0.36
    h = np.zeros((N, N)); s = np.zeros_like(h); vx = np.zeros_like(h); vy = np.zeros_like(h)
    # vertical wall: gravity along +y texel axis (down the image)
    F = (np.zeros((N, N)), np.full((N, N), 980.0), np.zeros((N, N)), np.full((N, N), L), np.ones((N, N)))
    p = params()
    splat(h, 48, 10, 3, 60.0, L)    # 60 mm^3 = 0.06 ml
    tot0 = h.sum()
    dt = 1 / 30
    acc = np.zeros_like(h)
    for it in range(30 * 10):
        h, s, vx, vy = step(h, s, vx, vy, F, dt, p, acc)
    mass = h.sum() + s.sum() + acc.sum()
    ys = np.where((h + s).max(axis=1) > 0.01)[0]
    print("WALL: conservation %.5f -> %.5f ; wet rows %d..%d ; hmax %.3f mm ; trail max stain %.3f" % (
        tot0, mass, ys.min() if len(ys) else -1, ys.max() if len(ys) else -1, h.max(), s.max()))
    return h, s


def run_floor():
    N = 128; L = 0.72
    h = np.zeros((N, N)); s = np.zeros_like(h); vx = np.zeros_like(h); vy = np.zeros_like(h)
    F = (np.zeros((N, N)), np.zeros((N, N)), np.full((N, N), -980.0), np.full((N, N), L), np.ones((N, N)))
    p = params()
    dt = 1 / 30
    total = 0
    for it in range(30 * 40):
        if it < 30 * 25:           # 6 ml/s for 25 s = 150 ml
            add = 6000.0 * dt      # mm^3
            splat(h, 64, 64, 2.5, add, L)
            total += add
        h, s, vx, vy = step(h, s, vx, vy, F, dt, p)
    area = (h > 0.05).sum() * (L * 10) ** 2
    print("FLOOR: poured %.0f mm3, wet+stain %.0f mm3, pool area %.0f mm2 (diam %.1f cm), max h %.2f mm mean h %.2f mm" % (
        total, (h.sum() + s.sum()) * (L * 10) ** 2, area, 2 * np.sqrt(area / np.pi) / 10, h.max(), h[h > 0.05].mean()))
    return h, s


def run_ceiling():
    N = 64; L = 0.36
    h = np.zeros((N, N)); s = np.zeros_like(h); vx = np.zeros_like(h); vy = np.zeros_like(h)
    F = (np.zeros((N, N)), np.zeros((N, N)), np.full((N, N), 980.0), np.full((N, N), L), np.ones((N, N)))
    p = params()
    splat(h, 32, 32, 4, 200.0, L)
    acc = np.zeros_like(h)
    for it in range(30 * 5):
        h, s, vx, vy = step(h, s, vx, vy, F, 1 / 30, p, acc)
    print("CEILING: liftoff volume %.1f mm3 of 200 ; remaining film max %.2f mm" % (acc.sum() * (L * 10) ** 2, h.max()))


def run_impact_slide():
    N = 96; L = 0.36
    h = np.zeros((N, N)); s = np.zeros_like(h); vx = np.zeros_like(h); vy = np.zeros_like(h)
    F = (np.zeros((N, N)), np.zeros((N, N)), np.full((N, N), -980.0), np.full((N, N), L), np.ones((N, N)))
    p = params()
    splat(h, 30, 48, 3, 300.0, L, vx, vy, 60.0, 0.0)   # sliding at 60 texel/s ~ 21 cm/s
    for it in range(30 * 3):
        h, s, vx, vy = step(h, s, vx, vy, F, 1 / 30, p)
    xs = np.where((h + s).max(axis=0) > 0.01)[0]
    print("SLIDE: wet columns %d..%d (start 27..33)" % (xs.min(), xs.max()))


if __name__ == "__main__":
    run_wall()
    run_floor()
    run_ceiling()
    run_impact_slide()
