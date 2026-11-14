#!/usr/bin/env python3
"""
GHM PhysBlood 1.26.7 (Claude, Cowork chat, 2026-10-27): textures for the Lite pools (cl_lite.lua), uncompressed.

  lite/pool.vtf    512 x 512 BGRA8888, tiles: the near-white detail of a pool's surface for the Modulate pass (grey
                   0.875 on average like the stain atlas, with soft unevenness), opaque - the pool's outline and its soft
                   edge come from the mesh
  lite/ripple.vtf  256 x 256 BGRA8888: a soft ring for the ripples drops make in a pool
and the materials pool_mod.vmt (Modulate, 2x), pool_shine.vmt (the wet shine, like stain_shine) and ripple.vmt.

usage: make_lite_pool.py <addon dir>
"""
import sys, os
import numpy as np
from srctools.vtf import VTF, ImageFormats, VTFFlags

ADDON = sys.argv[1]
OUT = os.path.join(ADDON, "materials", "ghm_physblood", "lite")
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(1267)


def periodic_noise(n, scale):
    """smooth noise that tiles: white noise filtered in frequency space"""
    f = np.fft.fftfreq(n)
    fx, fy = np.meshgrid(f, f)
    k = np.hypot(fx, fy)
    spec = np.fft.fft2(rng.standard_normal((n, n))) * np.exp(-(k * scale) ** 2)
    a = np.real(np.fft.ifft2(spec))
    return (a - a.mean()) / (a.std() + 1e-9)


def save(rgba, path, clamp):
    h, w = rgba.shape[:2]
    flags = VTFFlags.TRILINEAR | VTFFlags.EIGHTBITALPHA
    if clamp:
        flags |= VTFFlags.CLAMP_S | VTFFlags.CLAMP_T
    v = VTF(w, h, (7, 2), fmt=ImageFormats.BGRA8888, flags=flags)
    v.get().copy_from(np.ascontiguousarray(rgba).tobytes(), ImageFormats.RGBA8888)
    v.compute_mipmaps()
    with open(path, "wb") as f:
        v.save(f)


# the pool surface: broad soft patches and a little fine grain
N = 512
g = 0.875 + 0.022 * periodic_noise(N, 40) + 0.010 * periodic_noise(N, 10)
g = np.clip(g, 0.80, 0.95)
rgba = np.zeros((N, N, 4), np.uint8)
rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = np.round(g * 255).astype(np.uint8)
rgba[..., 3] = 255
save(rgba, os.path.join(OUT, "pool.vtf"), clamp=False)

# the ripple ring
M = 256
y, x = np.mgrid[0:M, 0:M]
r = np.hypot(x - (M - 1) / 2, y - (M - 1) / 2) / (M / 2)
ring = np.exp(-((r - 0.78) / 0.07) ** 2) + 0.35 * np.exp(-((r - 0.55) / 0.05) ** 2)
ring = np.clip(ring / ring.max(), 0, 1) * (r < 0.98)
rgba = np.zeros((M, M, 4), np.uint8)
rgba[..., :3] = 255
rgba[..., 3] = np.round(ring * 255).astype(np.uint8)
save(rgba, os.path.join(OUT, "ripple.vtf"), clamp=True)

VMTS = {
    "pool_mod.vmt": '''"Modulate"
{
	"$basetexture" "ghm_physblood/lite/pool"
	"$mod2x" "1"
	"$vertexcolor" "1"
	"$vertexalpha" "1"
	"$decal" "1"
	"$nocull" "1"
}
''',
    "pool_shine.vmt": '''"UnlitGeneric"
{
	"$basetexture" "ghm_physblood/lite/pool"
	"$envmap" "env_cubemap"
	"$envmaptint" "[0.025 0.003 0.0025]"
	"$additive" "1"
	"$translucent" "1"
	"$vertexcolor" "1"
	"$vertexalpha" "1"
	"$decal" "1"
	"$nocull" "1"
}
''',
    "ripple.vmt": '''"UnlitGeneric"
{
	"$basetexture" "ghm_physblood/lite/ripple"
	"$additive" "1"
	"$translucent" "1"
	"$vertexcolor" "1"
	"$vertexalpha" "1"
	"$nocull" "1"
}
''',
}
for name, text in VMTS.items():
    with open(os.path.join(OUT, name), "w", newline="\n") as f:
        f.write(text)
print("pool.vtf, ripple.vtf and 3 materials ->", OUT)
