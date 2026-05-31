#!/usr/bin/env python3
"""Prototype + validate the two follow-ups before RTL:
   (A) RES-ADAPTIVE calibration: weights + fill computed from (W,H) so the cylinder
       fills edge-to-edge at ANY resolution (not hardcoded 480x360).
   (B) JACOBIAN-GATED BOX PREFILTER: variable-width box average where the warp
       minifies (J>1), to kill the edge aliasing the 2-tap bilinear produces.
   Faithful to the engine's LUT arithmetic (M = 1 + 0.3*idx/256, K-scaled)."""
import os
import numpy as np
from PIL import Image, ImageDraw

SCALE = 2 ** 24
K_LUT = 0.3
K = 2


def meff(s4):
    idx = np.minimum(np.asarray(s4, dtype=np.int64) >> 16, 256)
    mlut = 1.0 + K_LUT * idx / 256.0
    return 1.0 + (mlut - 1.0) * K / 2.0


def res_cal(W, H, base_ax=508, base_ay=498):
    """Res-adaptive: scale base weights so the corner hits 2^24 at (W,H); fill = edge_M."""
    cx, cy = W // 2, H // 2
    s = SCALE / (base_ax * cx * cx + base_ay * cy * cy)
    AX2 = base_ax * s
    edge_M = float(meff(int(AX2 * cx * cx)))
    return AX2, edge_M, cx, cy


# ---------------- (A) res-adaptive self-calibration check ----------------
print("RES-ADAPTIVE fill check (edge maps to source edge => clamp should be ~0 at EVERY res):")
for W, H in [(288, 224), (480, 360), (640, 480), (320, 240)]:
    AX2, edge_M, cx, cy = res_cal(W, H)
    clamp = 0
    for ox in range(W):
        dx = ox - cx
        sx = cx + dx * (meff(int(AX2 * dx * dx)) / edge_M)
        if sx < -0.5 or sx > W - 0.5:
            clamp += 1
    print(f"  {W}x{H}: AX2={AX2:6.1f} edge_M={edge_M:.3f}  clamp={clamp}px  (target 0)")

# ---------------- (B) prefilter visual at 480x360 ----------------
W, H, GRID = 480, 360, 10
AX2, edge_M, cx, cy = res_cal(W, H)
linecol = ((np.arange(W) % GRID) < 2).astype(np.float64)
ps = np.concatenate([[0.0], np.cumsum(linecol)])     # prefix sum for O(1) box mean


def render(prefilter):
    oy, ox = np.mgrid[0:H, 0:W]
    dx = ox - cx
    sx = cx + dx * (meff(AX2 * dx * dx) / edge_M)
    J = np.abs(np.gradient(sx, axis=1))               # local minification (src px / out px)
    x0 = np.clip(np.floor(sx).astype(int), 0, W - 1)
    x1 = np.clip(x0 + 1, 0, W - 1)
    f = sx - np.floor(sx)
    bil = linecol[x0] * (1 - f) + linecol[x1] * f
    if not prefilter:
        v = bil
    else:
        hw = np.clip(J * 0.5, 0.0, 8.0)               # box half-width = footprint/2
        lo = np.clip(np.round(sx - hw).astype(int), 0, W)
        hi = np.clip(np.round(sx + hw).astype(int) + 1, 0, W)
        boxmean = (ps[hi] - ps[lo]) / np.maximum(hi - lo, 1)
        v = np.where(J > 1.05, boxmean, bil)          # GATE: prefilter only where minifying
    hrow = ((oy % GRID) < 2).astype(np.float64)        # flat horizontal lines (src_y=out_y)
    return np.clip(np.maximum(v, hrow), 0, 1)


tiles = [
    ("BILINEAR only (current) -- aliases where edges compress", render(False)),
    ("JACOBIAN-GATED BOX PREFILTER (J>1) -- clean edges", render(True)),
]
bar = 18
sheet = Image.new("RGB", (W + 16, len(tiles) * (H + bar) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (lab, im) in enumerate(tiles):
    y0 = 8 + i * (H + bar)
    d.text((10, y0 + 3), lab, fill=(255, 255, 255))
    g = (im * 240).astype(np.uint8)
    sheet.paste(Image.fromarray(np.dstack([g, g, g])), (8, y0 + bar))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_prototype.png")
sheet.save(out)
print("wrote", out)
