#!/usr/bin/env python3
# ⚠️ ARCHIVED / DO NOT TRUST FOR THE DOUBLING ARTIFACT. This is a FLOAT model; it
# did NOT reproduce the hardware line-doubling. The authoritative model is the
# bit-exact ../warp_bitexact.py (see ../README.md and SPEC-hires-warp-2026-05-30.md).
"""Reproduce the HARDWARE line-doubling/splitting artifact (the magenta-boxed
double lines on the grid) and test whether the softer LUT + sharpness fix it.

ROOT CAUSE (not the edge prefilter -- that was a different axis):
  The warp's overscan 'fill' magnifies the CENTER by a fixed factor =
  M_eff_Xedge = 1 + K_LUT*0.6447*(k/2). Center local scale = 1/M_eff_Xedge < 1
  => magnification. Sharp-bilinear K>1 (near nearest-neighbor) sampling a 1px line
  under non-integer magnification renders it in 1 output col for some lines and 2
  for others -> the doubled/split lines. Smooth content has no 1px features -> fine.

Configs compared (faithful to the engine math):
  OLD   : K_LUT=0.3, k=2, K_sharp=4   (~ shipped) -> ~16% center magnification
  NEW   : K_LUT=0.1, k=1, K_sharp=4   (royale-gentle) -> ~3% center magnification
  NEWsf : K_LUT=0.1, k=1, K_sharp=1   (soft bilinear) -> blends, no snap

Metric (per output row, the grid = 1px lines every 16px source):
  - center magnification %
  - n_bright_runs vs n_source_lines (extra runs => doubling)
  - CoV of bright-run widths (uneven widths = the visible beating; lower=better)
Renders an upscaled (x3, like ascal) strip per config so the doubling is visible.

Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_line_artifact.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw

W = 480; cx = W // 2; H = 360; cy = H // 2
SCALE = 2 ** 24
AX2 = round(508 * SCALE / (508 * cx * cx + 498 * cy * cy))   # 188 @480x360
GRID = 16; LINEW = 1                                          # mycore grid: 1px every 16
UP = 3                                                        # ascal-ish upscale for display

line = ((np.arange(W) % GRID) < LINEW).astype(np.float64)


def warp_row(K_LUT, k):
    """out_x -> src_x, faithful: M=1+K_LUT*min(AX2*dx^2/2^24,1); Meff=1+(M-1)k/2;
    fill = 1/Meff_Xedge; src_x = cx + dx*Meff*fill."""
    dx = np.arange(W) - cx
    r2 = np.minimum(AX2 * dx * dx / SCALE, 1.0)
    M = 1.0 + K_LUT * r2
    Meff = 1.0 + (M - 1.0) * k / 2.0
    Meff_edge = 1.0 + K_LUT * (508.0 / 788.0) * (k / 2.0)    # X-edge r2_norm=0.6447
    fill = 1.0 / Meff_edge
    sx = cx + dx * Meff * fill
    center_mag = (1.0 / (Meff[cx] * fill) - 1.0) * 100.0 if k else 0.0  # >0 => magnify
    return sx, center_mag


def sample_sharp(sx, Ksharp):
    x0 = np.clip(np.floor(sx).astype(int), 0, W - 1)
    x1 = np.clip(x0 + 1, 0, W - 1)
    f = sx - np.floor(sx)
    fs = np.clip((f - 0.5) * Ksharp + 0.5, 0.0, 1.0)         # steepen about midpoint
    return line[x0] * (1 - fs) + line[x1] * fs


def metrics(out):
    bright = out > 0.5
    # bright runs
    runs = []
    i = 0
    while i < len(bright):
        if bright[i]:
            j = i
            while j < len(bright) and bright[j]:
                j += 1
            runs.append(j - i)
            i = j
        else:
            i += 1
    n_src_lines = int(((np.arange(W) % GRID) < LINEW).sum() // LINEW)  # source lines in frame
    widths = np.array(runs) if runs else np.array([0])
    cov = float(np.std(widths) / max(np.mean(widths), 1e-9))
    return len(runs), n_src_lines, cov


CONFIGS = [
    ("OLD  K_LUT=0.3 k=2 Ksharp=4 (~shipped)", 0.3, 2, 4),
    ("NEW  K_LUT=0.1 k=1 Ksharp=4 (royale-gentle)", 0.1, 1, 4),
    ("NEWsf K_LUT=0.1 k=1 Ksharp=1 (soft bilinear)", 0.1, 1, 1),
]

print(f"AX2={AX2}  grid={GRID}px/{LINEW}px lines  (lower CoV + runs~=src_lines = cleaner)")
print(f"{'config':>46} {'ctr mag%':>9} {'runs/src':>10} {'width CoV':>10}")
tiles = []
for label, KL, k, Ks in CONFIGS:
    sx, cmag = warp_row(KL, k)
    out = sample_sharp(sx, Ks)
    nr, ns, cov = metrics(out)
    print(f"{label:>46} {cmag:>8.1f}% {f'{nr}/{ns}':>10} {cov:>10.3f}")
    disp = np.repeat(out, UP)                                # x3 nearest upscale
    tiles.append((label, disp))

# render strips
STRIP_H = 90; BAR = 16; Wd = W * UP
sheet = Image.new("RGB", (Wd + 16, len(tiles) * (STRIP_H + BAR) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (label, disp) in enumerate(tiles):
    y0 = 8 + i * (STRIP_H + BAR)
    d.text((10, y0 + 3), label, fill=(255, 255, 255))
    g = np.clip(disp * 235 + 8, 0, 255).astype(np.uint8)
    strip = np.tile(g[None, :], (STRIP_H, 1))
    sheet.paste(Image.fromarray(np.dstack([strip, strip, strip])), (8, y0 + BAR))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_line_artifact.png")
sheet.save(out)
print("\nwrote", out)
print("READ: OLD should show extra runs (doubled lines) + high CoV; NEW fewer; NEWsf smoothest.")
