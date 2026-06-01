#!/usr/bin/env python3
# crt_postfx_proto.py — prototype the post-warp CRT effects (vignette + rounded
# corners) with the EXACT integer (Q15) math intended for RTL, so the look can be
# validated and the ops ported directly to a hardware block.
#
# Pipeline (per output pixel at raster position ox,oy; raster is OUT_SCALE-wide):
#   nx = |ox - W/2| * recip_w   (Q15, 1.0 = 32768 ; recip_w = 32768/(W/2))
#   ny = |oy - H/2| * recip_h
#   r2 = (nx*nx + ny*ny) >> 15            (clamp 32768)        -- radial^2, 0..1
#   vfac = 32768 - (vstr_q * r2 >> 15)                          -- vignette gain
#   rgb  = rgb * vfac >> 15
#   ax = max(0, nx-(32768-Rn)); ay = max(0, ny-(32768-Rn))     -- rounded corner
#   if ax*ax + ay*ay > Rn*Rn: rgb = 0                            -- black outside arc
#
# recip_w/recip_h are computed once per frame (when src dims latch) -> per-pixel
# cost is multiplies only (DSP-friendly), no divides.

import numpy as np
from PIL import Image

OUT_SCALE = 2
SRC_W, SRC_H = 288, 240          # Robotron-ish source; raster X is OUT_SCALE-wide
W, H = OUT_SCALE * SRC_W, SRC_H
halfW, halfH = W // 2, H // 2
recip_w = (32768 + halfW // 2) // halfW   # round(32768/halfW)
recip_h = (32768 + halfH // 2) // halfH

# OSD strength maps (0..7)
def vstr_q(v):  return v * 4096          # 7 -> 28672 (corner ~ 12% brightness)
def rad_q(r):   return r * 1740          # 7 -> 12180 Q15 (~0.37 of half-dim)

def test_pattern():
    img = np.full((H, W, 3), 40, np.float64)
    img[8::16, :] = 170                   # horizontal grid
    img[:, 16::32] = 170                  # vertical grid (x2 spacing -> ~square on screen)
    img[2:6, :] = (255, 80, 80)           # colored border bands to read edge falloff
    img[-6:-2, :] = (80, 80, 255)
    img[:, 4:8] = (80, 255, 80)
    img[:, -8:-4] = (255, 255, 80)
    return img

ys, xs = np.mgrid[0:H, 0:W]
nx = (np.abs(xs - halfW) * recip_w)       # Q15
ny = (np.abs(ys - halfH) * recip_h)
nx = np.clip(nx, 0, 32768); ny = np.clip(ny, 0, 32768)
r2 = np.clip((nx*nx + ny*ny) >> 15, 0, 32768)

def apply_fx(img, vstrength, corner):
    out = img.copy()
    if vstrength > 0:
        vfac = 32768 - ((vstr_q(vstrength) * r2) >> 15)
        vfac = np.clip(vfac, 0, 32768)
        out = (out * vfac[..., None]) // 32768
    if corner > 0:
        Rn = rad_q(corner)
        ax = np.maximum(0, nx - (32768 - Rn))
        ay = np.maximum(0, ny - (32768 - Rn))
        mask = (ax*ax + ay*ay) > (Rn*Rn)
        out[mask] = 0
    return out.astype(np.uint8)

def to_final(raster):  # show what ascal sees after X-downscale by OUT_SCALE
    f = raster.reshape(H, W // OUT_SCALE, OUT_SCALE, 3).mean(axis=2)
    return f.astype(np.uint8)

base = test_pattern()
vs_levels = [0, 3, 6]
cn_levels = [0, 3, 7]
pad = 6
cellw, cellh = W // OUT_SCALE, H
sheet = np.full((len(cn_levels)*(cellh+pad)+pad, len(vs_levels)*(cellw+pad)+pad, 3), 25, np.uint8)
for r, cn in enumerate(cn_levels):
    for c, vs in enumerate(vs_levels):
        cell = to_final(apply_fx(base, vs, cn))
        y0 = pad + r*(cellh+pad); x0 = pad + c*(cellw+pad)
        sheet[y0:y0+cellh, x0:x0+cellw] = cell
Image.fromarray(sheet).save('crt_proto_sheet.png')
print(f"raster {W}x{H} -> final {W//OUT_SCALE}x{H} | recip_w={recip_w} recip_h={recip_h}")
print(f"vstr_q(7)={vstr_q(7)} rad_q(7)={rad_q(7)}  corner test: nx=ny=32768 -> ax=ay=Rn -> 2Rn^2 > Rn^2 (cut) OK")
print("grid: rows=corner[0,3,7] cols=vignette[0,3,6]  -> crt_proto_sheet.png")
