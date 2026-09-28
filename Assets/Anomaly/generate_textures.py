"""Particle textures for the Hollow Lift gravity anomaly.

Run:  python3 generate_textures.py   (needs Pillow and numpy)
Writes dust.png, grit.png, leaf.png, ring.png and preview.png next to this file.
White textures are tinted by the ParticleEmitter's Color; the leaf keeps its own colour.
"""
import math, os, random
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)
random.seed(7)


def save_rgba(alpha, name, rgb=(255, 255, 255)):
    a = np.clip(alpha, 0, 1)
    img = np.zeros(a.shape + (4,), np.uint8)
    img[..., 0], img[..., 1], img[..., 2] = rgb
    img[..., 3] = (a * 255).astype(np.uint8)
    Image.fromarray(img, "RGBA").save(os.path.join(HERE, name))


def smooth_noise(n, scale):
    small = rng.random((n // scale + 2, n // scale + 2))
    img = Image.fromarray((small * 255).astype(np.uint8)).resize((n, n), Image.BICUBIC)
    return np.asarray(img, float) / 255


# dust.png: a soft, lumpy puff (not a perfect circle), fades to nothing at the edge.
N = 256
y, x = np.mgrid[0:N, 0:N]
r = np.hypot(x - N / 2, y - N / 2) / (N / 2)
lump = 0.55 * smooth_noise(N, 32) + 0.3 * smooth_noise(N, 12) + 0.15 * smooth_noise(N, 5)
dust = np.clip(1 - r / (0.62 + 0.3 * lump), 0, 1) ** 1.8
dust *= 0.85 + 0.15 * smooth_noise(N, 16)
dust = np.asarray(Image.fromarray((dust * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(3)), float) / 255
save_rgba(dust * 0.9, "dust.png")

# grit.png: a few tiny specks of different sizes, slightly soft.
N = 128
im = Image.new("L", (N, N), 0)
d = ImageDraw.Draw(im)
for _ in range(9):
    cx, cy = random.uniform(20, 108), random.uniform(20, 108)
    s = random.uniform(2, 6)
    pts = [(cx + math.cos(t) * s * random.uniform(0.6, 1.2), cy + math.sin(t) * s * random.uniform(0.6, 1.2))
           for t in np.linspace(0, 2 * math.pi, 7)[:-1]]
    d.polygon(pts, fill=int(random.uniform(170, 255)))
im = im.filter(ImageFilter.GaussianBlur(0.8))
save_rgba(np.asarray(im, float) / 255, "grit.png")

# leaf.png: a dry leaf, own colours (tint the emitter white).
N = 128
im = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
pts = []
for t in np.linspace(0, math.pi, 40):
    w = math.sin(t) ** 0.8 * 26 * (1 + 0.08 * math.sin(t * 7))
    pts.append((64 + w, 14 + t / math.pi * 100))
for t in np.linspace(math.pi, 0, 40):
    w = math.sin(t) ** 0.8 * 24 * (1 + 0.08 * math.sin(t * 5 + 1))
    pts.append((64 - w, 14 + t / math.pi * 100))
d.polygon(pts, fill=(128, 92, 52, 255))
# darker edge and veins
d.line(pts + [pts[0]], fill=(84, 58, 32, 255), width=2)
d.line([(64, 10), (64, 118)], fill=(90, 64, 36, 255), width=2)
for i in range(6):
    yy = 30 + i * 13
    d.line([(64, yy), (64 + 18 - i, yy - 10)], fill=(98, 70, 40, 255), width=1)
    d.line([(64, yy + 4), (64 - 18 + i, yy - 6)], fill=(98, 70, 40, 255), width=1)
# blotches of lighter dry colour
arr = np.asarray(im).astype(float)
blot = smooth_noise(N, 10)[..., None]
arr[..., :3] = arr[..., :3] * (0.8 + 0.45 * blot)
arr = np.clip(arr, 0, 255).astype(np.uint8)
im = Image.fromarray(arr, "RGBA").rotate(25, resample=Image.BICUBIC)
im.save(os.path.join(HERE, "leaf.png"))

# ring.png: a thin soft ring with a faint inner haze, for the shimmer pulses.
N = 512
y, x = np.mgrid[0:N, 0:N]
r = np.hypot(x - N / 2, y - N / 2) / (N / 2)
ang = np.arctan2(y - N / 2, x - N / 2)
wob = 1 + 0.004 * np.sin(ang * 3) + 0.003 * np.sin(ang * 5 + 1)
ring = np.exp(-((r * wob - 0.82) / 0.035) ** 2)
ring += 0.35 * np.exp(-((r * wob - 0.74) / 0.06) ** 2)
ring += 0.08 * np.clip(1 - r / 0.8, 0, 1)
ring *= np.clip((1 - r) / 0.08, 0, 1)
save_rgba(ring / ring.max(), "ring.png")

# preview.png: all four on a dark background.
bg = Image.new("RGBA", (4 * 200, 220), (24, 26, 32, 255))
for i, (name, tint) in enumerate([("dust.png", (201, 185, 159)), ("grit.png", (150, 140, 122)),
                                  ("leaf.png", None), ("ring.png", (180, 194, 255))]):
    t = Image.open(os.path.join(HERE, name)).convert("RGBA").resize((180, 180))
    if tint:
        a = np.asarray(t).copy()
        a[..., 0], a[..., 1], a[..., 2] = tint
        t = Image.fromarray(a, "RGBA")
    bg.alpha_composite(t, (i * 200 + 10, 10))
bg.save(os.path.join(HERE, "preview.png"))
print("wrote dust.png grit.png leaf.png ring.png preview.png")


# ---------------------------------------------------------------------------
# Orb textures
# ---------------------------------------------------------------------------

# glow.png: soft radial glow, bright centre, long falloff (core; tinted black it's the dark heart).
N = 256
y, x = np.mgrid[0:N, 0:N]
r = np.hypot(x - N / 2, y - N / 2) / (N / 2)
glow = np.exp(-(r / 0.28) ** 2) * 0.85 + np.exp(-(r / 0.6) ** 2) * 0.35
glow *= np.clip((1 - r) / 0.15, 0, 1)
save_rgba(glow / glow.max(), "glow.png")

# lensrim.png: thin bright "Einstein ring" with a slightly uneven brightness round it
# and a faint inner falloff, like light bent round the core.
N = 512
y, x = np.mgrid[0:N, 0:N]
r = np.hypot(x - N / 2, y - N / 2) / (N / 2)
ang = np.arctan2(y - N / 2, x - N / 2)
bright = 0.65 + 0.25 * np.sin(ang * 2 + 0.6) + 0.1 * np.sin(ang * 5)
rim = np.exp(-((r - 0.55) / 0.018) ** 2) * bright
rim += 0.45 * np.exp(-((r - 0.55) / 0.07) ** 2) * bright
rim += 0.12 * np.exp(-((r - 0.62) / 0.12) ** 2)
rim *= np.clip((1 - r) / 0.1, 0, 1)
save_rgba(rim / rim.max(), "lensrim.png")

# streak.png: a thin vertical streak, soft ends (for inflow; the emitter lines it
# up with its motion).
N = 256
y, x = np.mgrid[0:N, 0:N]
u = (x - N / 2) / (N / 2)
v = (y - N / 2) / (N / 2)
streak = np.exp(-(u / 0.06) ** 2) * np.clip(1 - np.abs(v), 0, 1) ** 1.5
streak += 0.25 * np.exp(-(u / 0.18) ** 2) * np.clip(1 - np.abs(v), 0, 1) ** 2
save_rgba(streak / streak.max(), "streak.png")

# spark.png: small four-point twinkle.
N = 128
y, x = np.mgrid[0:N, 0:N]
u = (x - N / 2) / (N / 2)
v = (y - N / 2) / (N / 2)
rr_ = np.hypot(u, v)
spark = np.exp(-(rr_ / 0.12) ** 2)
spark += 0.8 * np.exp(-(np.abs(u) / 0.035) ** 2) * np.exp(-(np.abs(v) / 0.7) ** 2)
spark += 0.8 * np.exp(-(np.abs(v) / 0.035) ** 2) * np.exp(-(np.abs(u) / 0.7) ** 2)
spark *= np.clip((1 - rr_) / 0.2, 0, 1)
save_rgba(spark / spark.max(), "spark.png")

# wisp.png: soft strands for the orbit-trail Beams. Tiles left-right (the beam
# scrolls it along its length); fades out at the top and bottom edges.
W_, H_ = 512, 128
xs = np.linspace(0, 2 * np.pi, W_, endpoint=False)
ys = np.linspace(-1, 1, H_)
X, Y = np.meshgrid(xs, ys)
wisp = np.zeros_like(X)
for k in range(7):
    f = rng.integers(1, 4)
    ph = rng.uniform(0, 2 * np.pi)
    centre = 0.45 * np.sin(f * X + ph) * rng.uniform(0.3, 1)
    width = rng.uniform(0.06, 0.16)
    amp = 0.5 + 0.5 * np.sin(rng.integers(1, 4) * X + rng.uniform(0, 6)) ** 2
    wisp += amp * np.exp(-((Y - centre) / width) ** 2)
wisp *= np.clip(1 - np.abs(Y) ** 3, 0, 1)
save_rgba(wisp / wisp.max() * 0.9, "wisp.png")


# orb_preview.png: a rough mock-up of all the orb layers together (the real thing
# moves and has the ForceField shimmer on top).
def tinted(name, rgb, size, alpha=1.0):
    t = Image.open(os.path.join(HERE, name)).convert("RGBA").resize(size, Image.BICUBIC)
    a = np.asarray(t).astype(float)
    a[..., 0], a[..., 1], a[..., 2] = rgb
    a[..., 3] *= alpha
    return Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA")


def add_glow(base, layer, pos):
    """Additive blend (like LightEmission 1)."""
    b = np.asarray(base).astype(float)
    l = np.asarray(layer).astype(float)
    x0, y0 = pos
    h, w = l.shape[:2]
    region = b[y0:y0 + h, x0:x0 + w, :3]
    region += l[..., :3] * (l[..., 3:4] / 255)
    b[y0:y0 + h, x0:x0 + w, :3] = region
    return Image.fromarray(b.clip(0, 255).astype(np.uint8), "RGBA")


W2 = 720
img = Image.new("RGBA", (W2, W2), (30, 34, 44, 255))
g = np.linspace(0, 1, W2)[:, None]
bgarr = np.asarray(img).astype(float)
bgarr[..., :3] = np.array([22, 26, 36]) * (1 - g[..., None]) + np.array([52, 50, 48]) * g[..., None]
img = Image.fromarray(bgarr.astype(np.uint8), "RGBA")
C2 = W2 // 2
# dark heart (normal blend)
dark = tinted("glow.png", (5, 6, 12), (260, 260), 0.85)
img.alpha_composite(dark, (C2 - 130, C2 - 130))
# orbit arcs
arcs = Image.new("RGBA", (W2, W2), (0, 0, 0, 0))
ad = ImageDraw.Draw(arcs)
for rx, ry, rot, col in [(150, 60, 0, (160, 180, 255, 120)), (180, 80, 35, (190, 170, 255, 90)),
                         (210, 70, -25, (170, 200, 255, 70))]:
    e = Image.new("RGBA", (W2, W2), (0, 0, 0, 0))
    ImageDraw.Draw(e).ellipse((C2 - rx, C2 - ry, C2 + rx, C2 + ry), outline=col, width=3)
    e = e.rotate(rot, center=(C2, C2)).filter(ImageFilter.GaussianBlur(1.2))
    arcs.alpha_composite(e)
img = add_glow(img, arcs, (0, 0))
# lens rim and core
img = add_glow(img, tinted("lensrim.png", (185, 200, 255), (330, 330)), (C2 - 165, C2 - 165))
img = add_glow(img, tinted("glow.png", (225, 232, 255), (120, 120)), (C2 - 60, C2 - 60))
# inflow streaks
st = Image.new("RGBA", (W2, W2), (0, 0, 0, 0))
for _ in range(26):
    a = random.uniform(0, 2 * math.pi)
    d = random.uniform(110, 300)
    s = tinted("streak.png", (200, 205, 230), (18, 70), random.uniform(0.3, 0.8))
    s = s.rotate(-math.degrees(a) - 90, expand=True)
    st.alpha_composite(s, (int(C2 + math.cos(a) * d - s.width / 2), int(C2 + math.sin(a) * d - s.height / 2)))
img = add_glow(img, st, (0, 0))
# sparks
for _ in range(14):
    a = random.uniform(0, 2 * math.pi)
    d = random.uniform(40, 140)
    sz = random.randint(14, 30)
    img = add_glow(img, tinted("spark.png", (230, 235, 255), (sz, sz)),
                   (int(C2 + math.cos(a) * d - sz / 2), int(C2 + math.sin(a) * d - sz / 2)))
img.convert("RGB").save(os.path.join(HERE, "orb_preview.png"))
print("wrote glow.png lensrim.png streak.png spark.png wisp.png orb_preview.png")
