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
