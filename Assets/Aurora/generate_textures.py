import numpy as np
from PIL import Image
rng = np.random.default_rng(7)

def tile_noise(n, fmin, fmax, count, power=1.0):
    """1D noise that wraps seamlessly (integer frequencies), normalised 0..1."""
    x = np.arange(n) / n
    s = np.zeros(n)
    for _ in range(count):
        f = rng.integers(fmin, fmax + 1)
        s += (1.0 / f**power) * np.sin(2*np.pi*(f*x + rng.random()))
    s -= s.min(); s /= s.max()
    return s

def smoothstep(a, b, v):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t*t*(3 - 2*t)

W, H = 1024, 512
y = (np.arange(H) / (H - 1))[:, None]          # 0 top .. 1 bottom
# ---- CURTAIN ----
edge = 0.80 + 0.06*(tile_noise(W, 1, 5, 6) - 0.5)            # wavy lower edge
rays = tile_noise(W, 18, 140, 90, power=0.35)                # fine vertical rays
rays = rays**2.2                                             # sharpen into streaks
folds = tile_noise(W, 1, 7, 10)**1.6                         # big bright/dim folds, real gaps
reach = 0.18 + 0.30*tile_noise(W, 6, 40, 30)                 # how far each ray climbs
h = edge[None, :] - y                                        # height above lower edge
above = np.exp(-np.clip(h, 0, None) / reach[None, :])        # fade upward
below = np.exp(-np.clip(-h, 0, None) / 0.012)                # razor bottom edge
profile = np.where(h >= 0, above, below)
ray_mix = 0.45 + 0.55*rays[None, :]
intensity = profile * ray_mix * (0.12 + 0.88*folds[None, :])
# the upper colours are a faint tint, not a band of their own
intensity *= 1 - 0.55*smoothstep(0.12, 0.55, np.clip(h, 0, None))
intensity *= 1 - smoothstep(0.0, 0.06, 0.06 - y)             # never touch the very top
alpha = np.clip(intensity * 1.35, 0, 1)

# colour by height: pink fringe right at the edge -> green -> teal -> purple -> red top
hh = np.clip(h, 0, None) / 0.8
def mix(c1, c2, t): return c1 + (c2 - c1) * t[..., None]
pink   = np.array([1.00, 0.55, 0.75])
bright = np.array([0.70, 1.00, 0.80])
green  = np.array([0.25, 1.00, 0.50])
teal   = np.array([0.20, 0.85, 0.70])
purple = np.array([0.55, 0.30, 0.95])
red    = np.array([0.90, 0.25, 0.40])
col = mix(bright, green, smoothstep(0.0, 0.06, hh))
col = mix(col, teal, smoothstep(0.15, 0.35, hh))
col = mix(col, purple, smoothstep(0.35, 0.60, hh))
col = mix(col, red, smoothstep(0.60, 0.95, hh))
fringe = (h < 0)[..., None] * np.clip(-h / 0.02, 0, 1)[..., None]
col = col * (1 - fringe * 0.6) + pink * fringe * 0.6
rgba = np.dstack([np.clip(col, 0, 1), alpha[..., None]])
# Beams run a texture's VERTICAL axis along their length, so the image is rotated:
# the curtain's length runs down the image (tiling top-to-bottom) and its height
# runs across it, with the bright lower edge on the LEFT.
Image.fromarray((np.rot90(rgba, k=-1) * 255).astype(np.uint8), "RGBA").save("aurora_curtain.png", optimize=True)

# ---- GLOW (soft haze, no rays) ----
edge2 = 0.78 + 0.08*(tile_noise(W, 1, 3, 4) - 0.5)
h2 = edge2[None, :] - y
soft = np.where(h2 >= 0, np.exp(-h2 / 0.30), np.exp(h2 / 0.02))
soft *= 0.25 + 0.75*tile_noise(W, 1, 6, 8)[None, :]
soft *= 1 - smoothstep(0.0, 0.1, 0.1 - y)
a2 = np.clip(soft * 0.45, 0, 1)
hh2 = np.clip(h2, 0, None) / 0.8
col2 = mix(green, teal, smoothstep(0.1, 0.4, hh2))
col2 = mix(col2, purple, smoothstep(0.4, 0.9, hh2))
Image.fromarray((np.rot90(np.dstack([col2, a2[..., None]]), k=-1) * 255).astype(np.uint8), "RGBA").save("aurora_glow.png", optimize=True)

# ---- RAY PARTICLE (one soft vertical streak, for the shimmer layer) ----
PW, PH = 64, 512
px = (np.arange(PW) - (PW - 1) / 2)[None, :] / (PW / 2)
py = (np.arange(PH) / (PH - 1))[:, None]
across = np.exp(-(px / 0.35)**2)
along = smoothstep(0.0, 0.55, 1 - py) * smoothstep(0.0, 0.08, py)   # bright low, fades up
a3 = np.clip(across * along, 0, 1)
white = np.ones((PH, PW, 3))
Image.fromarray((np.dstack([white, a3[..., None]]) * 255).astype(np.uint8), "RGBA").save("aurora_ray.png", optimize=True)
print("ok")
