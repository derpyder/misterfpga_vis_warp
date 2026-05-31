#!/usr/bin/env python3
"""Focused diagnosis render: the X-barrel OVAL (what's on hardware now) vs the
   SEPARABLE CYLINDER (the fix). Stronger curvature so the difference is obvious."""
import os
import numpy as np
from PIL import Image, ImageDraw
import warp_model as wm

wm.STRENGTH = 0.16          # stronger than the 0.09 default -> hardware-ish bow
pat = wm.test_pattern()
W, H = wm.W, wm.H


def render(**kw):
    sx, sy = wm.warp_coords(**kw)
    return wm.sample(pat, sx, sy)


tiles = [
    ("SOURCE grid (+ yellow score row, green crosshair)", pat),
    ("X-BARREL  r2->X  (kv=0)  ==  the CIRCLE you see now", render(kh=4, kv=0, xbarrel=True)),
    ("SEPARABLE CYLINDER  x2->X  (kv=0)  ==  the FIX: straight V, flat rows", render(kh=4, kv=0)),
]

bar = 18
sheet = Image.new("RGB", (W + 16, len(tiles) * (H + bar) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(tiles):
    y0 = 8 + i * (H + bar)
    d.text((10, y0 + 3), label, fill=(255, 255, 255))
    sheet.paste(Image.fromarray(im), (8, y0 + bar))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_circle_vs_fix.png")
sheet.save(out)
print("wrote", out)
