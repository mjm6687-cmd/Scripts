"""Sounds for the Hollow Lift gravity anomaly, synthesised from scratch.

Run:  python3 generate_sounds.py   (needs numpy and soundfile)
Writes mono 44.1 kHz OGG files into ./sounds:
  hum_loop.ogg        24 s seamless loop, the orb's drone (breathes every 8 s)
  air_loop.ogg        16 s seamless loop, soft inward-pulling air
  surge.ogg           4.8 s one-shot, played when the light surges
  rock_creak_1-3.ogg  stone grinding, played from a random floating rock
  pebble_clack_1-2.ogg small stones knocking together
"""
import os
import numpy as np
import soundfile as sf

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sounds")
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(11)


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def fft_band(x, lo, hi, soft=0.25):
    """Band-pass by FFT. On a whole buffer this is circular, so a buffer that
    loops stays seamless."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    g = np.ones_like(f)
    if lo > 0:
        g *= 1 / (1 + (lo / np.maximum(f, 1e-3)) ** (2 / soft))
    if hi:
        g *= 1 / (1 + (f / hi) ** (2 / soft))
    return np.fft.irfft(X * g, len(x))


def resonate(x, freqs, q=18):
    """Sum of resonant band-passes (biquads), for stone/wood body."""
    out = np.zeros_like(x)
    for f0 in freqs:
        w = 2 * np.pi * f0 / SR
        alpha = np.sin(w) / (2 * q)
        b0, b2 = alpha, -alpha
        a0, a1, a2 = 1 + alpha, -2 * np.cos(w), 1 - alpha
        y = np.zeros_like(x)
        x1 = x2 = y1 = y2 = 0.0
        for i in range(len(x)):
            xi = x[i]
            yi = (b0 * xi + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2, x1, y2, y1 = x1, xi, y1, yi
            y[i] = yi
        out += y
    return out


def norm(x, peak_db=-1.0):
    return x / (np.max(np.abs(x)) + 1e-9) * 10 ** (peak_db / 20)


def fades(x, fin=0.01, fout=0.05):
    n_in, n_out = int(SR * fin), int(SR * fout)
    x = x.copy()
    if n_in:
        x[:n_in] *= np.linspace(0, 1, n_in)
    if n_out:
        x[-n_out:] *= np.linspace(1, 0, n_out)
    return x


def save(name, x):
    sf.write(os.path.join(OUT, name), x.astype(np.float32), SR, format="OGG", subtype="VORBIS")
    print(f"wrote {name}  ({len(x) / SR:.1f} s)")


# --- hum_loop: 24 s. Every frequency and modulation completes whole cycles in
# 24 s, and noise is filtered circularly, so the loop has no seam.
L = 24
t = t_axis(L)
breath = 0.5 + 0.5 * np.sin(2 * np.pi * t / 8 - np.pi / 2)          # 3 breaths, matches the light
drone = (np.sin(2 * np.pi * 43.0 * t) + 0.8 * np.sin(2 * np.pi * (1038 / 24) * t)     # 43.25 Hz: slow beating
         + 0.45 * np.sin(2 * np.pi * 86.0 * t + 0.3) + 0.2 * np.sin(2 * np.pi * 129.0 * t + 1.1))
drone *= 0.7 + 0.3 * breath
pressure = fft_band(rng.standard_normal(len(t)), 25, 180)
pressure = pressure / np.std(pressure) * (0.25 + 0.2 * breath)
glass = sum(a * np.sin(2 * np.pi * f * t + p) * (0.5 + 0.5 * np.sin(2 * np.pi * t / m + p))
            for f, a, m, p in [(880.0, 0.05, 12, 0.2), (1318.5, 0.035, 8, 1.4), (1976.0, 0.02, 6, 2.2)])
# 1318.5 Hz * 24 s = 31644 whole cycles, so it still loops cleanly
save("hum_loop.ogg", norm(drone * 0.55 + pressure * 0.5 + glass, -3))

# --- air_loop: 16 s of soft air, slowly swirling in pitch and loudness.
L = 16
t = t_axis(L)
n = rng.standard_normal(len(t))
low = fft_band(n, 180, 700)
high = fft_band(n, 700, 1900)
swirl = 0.5 + 0.5 * np.sin(2 * np.pi * t / 8)
swell = 0.6 + 0.4 * np.sin(2 * np.pi * t / 16 + 1.0) ** 2
air = (low / np.std(low) * (0.75 - 0.25 * swirl) + high / np.std(high) * (0.12 + 0.18 * swirl)) * swell
save("air_loop.ogg", norm(air, -4))

# --- surge: 0.3 s rise, thump, glassy shimmer tail (matches the light surge).
L = 4.8
t = t_axis(L)
rise = np.clip(t / 0.3, 0, 1) ** 2
decay = np.where(t < 0.3, 1.0, np.exp(-(t - 0.3) * 1.2))
n = rng.standard_normal(len(t))
# a sweep: band slides up during the rise, then settles
sweep = np.zeros_like(t)
for lo, hi, w in [(150, 600, 1.0), (600, 1800, 0.7), (1800, 5000, 0.35)]:
    band = fft_band(n, lo, hi)
    sweep += band / np.std(band) * w * np.clip((t - (lo / 1800) * 0.25) / 0.3, 0, 1)
whoosh = sweep * rise * decay
thump_env = np.where(t >= 0.3, np.exp(-(t - 0.3) * 5), 0)
thump_f = 42 + 40 * np.exp(-np.maximum(t - 0.3, 0) * 8)
thump = np.sin(2 * np.pi * np.cumsum(thump_f) / SR) * thump_env
shimmer = sum(a * np.sin(2 * np.pi * f * t) * np.where(t >= 0.3, np.exp(-(t - 0.3) * d), 0)
              for f, a, d in [(1244.5, 0.35, 1.4), (1865.0, 0.25, 1.8), (2793.8, 0.15, 2.3), (3729.3, 0.08, 3.0)])
shimmer *= 1 + 0.3 * np.sin(2 * np.pi * 5.5 * t)
save("surge.ogg", fades(norm(whoosh * 0.35 + thump * 1.0 + shimmer * 0.5, -1), 0.005, 0.3))

# --- rock creaks: stick-slip grains through stony resonances, plus rumble.
for k in range(3):
    L = [1.6, 1.2, 2.0][k]
    t = t_axis(L)
    grains = np.zeros_like(t)
    pos = 0.05
    while pos < L - 0.1:
        i = int(pos * SR)
        glen = int(rng.uniform(0.004, 0.02) * SR)
        g = rng.standard_normal(glen) * np.hanning(glen) * rng.uniform(0.3, 1)
        grains[i:i + glen] += g[: len(grains) - i]
        pos += rng.uniform(0.01, 0.06) * (1 + 1.5 * np.sin(np.pi * pos / L) ** 4)
    body = resonate(grains, [rng.uniform(150, 220), rng.uniform(380, 520), rng.uniform(900, 1300)], q=14)
    rumble = fft_band(rng.standard_normal(len(t)), 30, 120)
    env = np.sin(np.pi * t / L) ** 0.7
    body = fft_band(body, 60, 1800, soft=0.4)   # keep it low and stony, not crackly
    x = norm(body) * env + norm(rumble) * 0.3 * env
    save(f"rock_creak_{k + 1}.ogg", fades(norm(x, -2), 0.01, 0.15))

# --- pebble clacks: two or three quick hard knocks with a short ring.
for k in range(2):
    L = 0.35
    t = t_axis(L)
    x = np.zeros_like(t)
    for hit in ([0.02, 0.09, 0.14] if k == 0 else [0.02, 0.07]):
        i = int(hit * SR)
        n_ = int(0.004 * SR)
        x[i:i + n_] += rng.standard_normal(n_) * np.hanning(n_) * rng.uniform(0.6, 1)
    ring = resonate(x, [rng.uniform(1800, 2400), rng.uniform(3200, 4200), rng.uniform(5500, 6500)], q=40)
    save(f"pebble_clack_{k + 1}.ogg", fades(norm(ring * np.exp(-t * 6), -3), 0.001, 0.1))
