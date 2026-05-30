#!/usr/bin/env python3
"""Bit-faithful 2-D render of the engine's separable-cylinder X warp, to diagnose
   the irregular spacing. Replicates: s4=AX2*dx^2, idx=min(s4>>16,256),
   M=1+0.3*idx/256, Meff=1+(M-1)*K/2, src_x=cx+dx*Meff/fill, src_y=oy (kv=0).

   Compares CURRENT weights (508/498 -> saturates at 480x360) vs DE-SATURATED
   weights (rescaled so corner==2^24 at the actual res -> smooth curve)."""
import os
import numpy as np
from PIL import Image, ImageDraw

W, H = 480, 360
cx, cy = W // 2, H // 2
K = 2
GRID = 10   # finer grid -> exposes minification aliasing where the cylinder compresses
SCALE = 2 ** 24
K_LUT = 0.3


def meff(s4, K):
    idx = np.minimum((s4.astype(np.int64) >> 16), 256)
    mlut = 1.0 + K_LUT * idx / 256.0
    return 1.0 + (mlut - 1.0) * K / 2.0


def edge_M(AX2):
    s4 = np.array([AX2 * cx * cx])
    return float(meff(s4, K)[0])


def render(AX2, label):
    fill = edge_M(AX2)                       # fill = horizontal edge magnitude
    oy, ox = np.mgrid[0:H, 0:W]
    dx = ox - cx
    mx = meff(AX2 * dx * dx, K) / fill
    sx = cx + dx * mx
    ix = np.round(sx).astype(int)
    ok = (ix >= 0) & (ix < W)
    ixc = np.clip(ix, 0, W - 1)
    grid = ((ixc % GRID < 2) | (oy % GRID < 2))
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (8, 8, 16)
    img[ok & grid] = (240, 240, 240)
    img[~ok] = (0, 0, 0)
    return f"{label}  AX2={AX2} edge_M={fill:.3f}", img


# de-saturated weights: rescale so corner (cx,cy) == 2^24 at THIS res
scale = SCALE / (508 * cx * cx + 498 * cy * cy)
AX2_desat = round(508 * scale)

tiles = [
    render(508, "CURRENT (sat) -- reproduces hardware"),
    render(AX2_desat, "DE-SATURATED (fix candidate)"),
]

bar = 18
sheet = Image.new("RGB", (W + 16, len(tiles) * (H + bar) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(tiles):
    y0 = 8 + i * (H + bar)
    d.text((10, y0 + 3), label, fill=(255, 255, 255))
    sheet.paste(Image.fromarray(im), (8, y0 + bar))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_faithful_2d.png")
sheet.save(out)
print(f"AX2_desat={AX2_desat}  (scale={scale:.4f})")
print("wrote", out)
