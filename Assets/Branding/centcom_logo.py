import math, random
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048                      # draw at 2x, downscale for clean edges
C = S // 2
LIGHT = (218, 221, 226, 255)
DARK = (12, 13, 15, 255)
GREY = (128, 130, 134, 255)
MID = (70, 72, 76, 255)
FONT = "/usr/share/fonts/truetype/freefont/FreeSerif.ttf"
random.seed(4)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

def disc(r, col):
    d.ellipse((C - r, C - r, C + r, C + r), fill=col)

def ring(r, w, col):
    d.ellipse((C - r, C - r, C + r, C + r), outline=col, width=w)

k = S / 1024
# frame: outer edge, double ring, text band, tick band, inner disc
disc(510 * k, DARK)
disc(506 * k, LIGHT)
disc(498 * k, DARK)
disc(486 * k, LIGHT)
disc(482 * k, DARK)
disc(478 * k, LIGHT)          # text band 478..392
disc(392 * k, DARK)
disc(384 * k, LIGHT)
disc(380 * k, DARK)           # tick band 380..330
disc(331 * k, LIGHT)
disc(327 * k, DARK)           # inner disc
ring(292 * k, int(3 * k), GREY)

# ticks and inward arrows in the tick band
for i in range(96):
    a = i / 96 * 2 * math.pi
    ca, sa = math.cos(a), math.sin(a)
    long = i % 4 == 0
    r0, r1 = (338 if long else 350) * k, 372 * k
    w = int((5 if long else 3) * k)
    d.line((C + ca * r0, C + sa * r0, C + ca * r1, C + sa * r1), fill=LIGHT, width=w)
# clusters of arrows pointing inward
for base in [-2.2, -1.2, -0.3, 0.9, 1.7, 2.6]:
    for j in range(random.randint(2, 4)):
        a = base + j * 0.07 + random.uniform(-0.01, 0.01)
        ca, sa = math.cos(a), math.sin(a)
        tip = 342 * k
        tail = 372 * k
        px, py = -sa, ca
        d.line((C + ca * tail, C + sa * tail, C + ca * tip, C + sa * tip), fill=LIGHT, width=int(3 * k))
        hx, hy = C + ca * tip, C + sa * tip
        for s in (-1, 1):
            d.line((hx, hy, hx + ca * 12 * k + px * s * 8 * k, hy + sa * 12 * k + py * s * 8 * k), fill=LIGHT, width=int(3 * k))

# diamonds at 9 and 3 o'clock in the text band
for sx in (-1, 1):
    x, y, r = C + sx * 436 * k, C, 13 * k
    d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], fill=DARK)

# lettering along the band
font = ImageFont.truetype(FONT, int(66 * k))

def arc_text(text, radius, top=True, tracking=0.55):
    widths = [font.getlength(ch) for ch in text]
    gaps = [w + tracking * font.size for w in widths]
    total = sum(gaps) - tracking * font.size
    angle_total = total / radius
    a = (-math.pi / 2 - angle_total / 2) if top else (math.pi / 2 + angle_total / 2)
    for ch, w, g in zip(text, widths, gaps):
        mid = a + (w / 2) / radius * (1 if top else -1)
        if ch != " ":
            tile = Image.new("RGBA", (int(font.size * 1.6), int(font.size * 1.6)), (0, 0, 0, 0))
            td = ImageDraw.Draw(tile)
            td.text((tile.width / 2, tile.height / 2), ch, font=font, fill=DARK, anchor="mm")
            rot = -math.degrees(mid) - 90 if top else -math.degrees(mid) + 90
            tile = tile.rotate(rot, resample=Image.BICUBIC)
            x = C + math.cos(mid) * radius - tile.width / 2
            y = C + math.sin(mid) * radius - tile.height / 2
            img.alpha_composite(tile, (int(x), int(y)))
        a += g / radius * (1 if top else -1)

arc_text("CENTRAL COMMAND", 435 * k, top=True, tracking=0.62)
arc_text("PROJECT NORTHGATE", 435 * k, top=False, tracking=0.5)

# centre: radar display
R = 250 * k
for rr in (R, R * 0.68, R * 0.36):
    ring(rr, int(4 * k), LIGHT)
d.line((C - R, C, C + R, C), fill=LIGHT, width=int(3 * k))
d.line((C, C - R, C, C + R), fill=LIGHT, width=int(3 * k))
# sweep wedge fading behind the leading edge
sweep = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(sweep)
lead = -40
for i in range(40):
    a0, a1 = lead - (i + 1) * 1.6, lead - i * 1.6
    alpha = int(170 * (1 - i / 40) ** 1.6)
    sd.pieslice((C - R, C - R, C + R, C + R), a0, a1, fill=(200, 204, 210, alpha))
img.alpha_composite(sweep)
la = math.radians(lead)
d.line((C, C, C + math.cos(la) * R, C + math.sin(la) * R), fill=LIGHT, width=int(6 * k))
# triangle marker above, like the Northgate seal
tx, ty, tr = C, C - 292 * k, 44 * k
outer = [(tx, ty - tr), (tx + tr * 1.1, ty + tr * 0.75), (tx - tr * 1.1, ty + tr * 0.75)]
d.polygon(outer, fill=LIGHT)
ti = 0.45
inner = [(tx, ty - tr * ti + 4 * k), (tx + tr * 1.1 * ti, ty + tr * 0.75 * ti), (tx - tr * 1.1 * ti, ty + tr * 0.75 * ti)]
d.polygon(inner, fill=DARK)

# grunge: specks of the opposite tone, inside the seal only
arr = np.array(img)
alpha_mask = arr[..., 3] > 0
rng = np.random.default_rng(9)
n = int(S * S * 0.0006)
ys = rng.integers(0, S, n)
xs = rng.integers(0, S, n)
for y, x in zip(ys, xs):
    if not alpha_mask[y, x]:
        continue
    s = int(rng.choice([1, 1, 1, 2, 2, 3]) * k / 1.6) + 1
    light_here = arr[y, x, 0] > 128
    col = DARK if light_here else LIGHT
    arr[max(0, y - s // 2): y + s // 2 + 1, max(0, x - s // 2): x + s // 2 + 1] = col
# keep specks inside the seal
arr[..., 3] = np.where(alpha_mask, arr[..., 3], 0)
img = Image.fromarray(arr)

out = img.resize((1024, 1024), Image.LANCZOS)
out.save("centcom_logo.png")

# preview: full size + how it looks as a Discord avatar
prev = Image.new("RGBA", (1024 + 40 + 300, 1064), (49, 51, 56, 255))
prev.alpha_composite(out, (20, 20))
for size, y in [(128, 60), (80, 260), (40, 400)]:
    av = out.resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse((0, 0, size, size), fill=255)
    prev.paste(av, (1084, y), m)
prev.convert("RGB").save("centcom_preview.png")
print("done")
