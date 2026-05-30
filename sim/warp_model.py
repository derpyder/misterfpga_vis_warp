#!/usr/bin/env python3
"""
vis_warp geometry model + look-preview renders   (Stage-0 reference)

Per SPEC-cylindrical-warp.md. Two jobs:
  1. PROVE the H/V-SEPARABLE formulation does what we claim, numerically:
       src_x = cx + dx*Mx(x)      src_y = cy + dy*My(y)
       * kv = 0   => src_y == out_y  EXACTLY  (clean vertical-axis cylinder;
                     this is the precondition for the M9K reclaim)
       * kh = 0,kv = 0 => identity
  2. PREVIEW the looks (radial vs separable-sym vs cylinder vs H>V vs
     pincushion vs overscan) BEFORE any RTL, so the geometry is eyeballed first.

This model is the golden reference the GHDL/RTL check verifies against later.
The barrel curve here is a POLYNOMIAL approximation of the engine's WARP_LUT
(shape only; exact-LUT bit-match is deferred to the GHDL stage).
"""
import os
import numpy as np
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out")
os.makedirs(OUT, exist_ok=True)

W, H = 320, 240
STRENGTH = 0.09          # tuned so k=2 ~ 1.18x at the axis edge (matches engine feel)


def barrel_M(n2, k, sign=+1):
    """Magnitude around 1.0; grows with normalized squared distance n2 (0..~1).
       sign=+1 barrel (bulge outward), sign=-1 pincushion (bow inward)."""
    return 1.0 + sign * (k * STRENGTH) * n2


def warp_coords(kh, kv, sign_h=+1, sign_v=+1, ovh=1.0, ovv=1.0, xbarrel=False, xybarrel=False):
    """Inverse map: for each OUTPUT pixel return the SOURCE coord it samples.
       SEPARABLE: x-magnitude from x only, y-magnitude from y only.
       xbarrel: radial r^2 magnitude applied to X ONLY (sides bow, rows stay flat,
                src_y=out_y preserved -> still full reclaim)."""
    cx, cy = (W - 1) / 2.0, (H - 1) / 2.0
    oy, ox = np.mgrid[0:H, 0:W].astype(np.float64)
    dx, dy = ox - cx, oy - cy
    nx, ny = dx / cx, dy / cy                      # normalized -1..1
    if xbarrel:
        Mx = barrel_M(nx * nx + ny * ny, kh, sign_h)   # r^2 -> X only (sides bow, rows flat)
        My = 1.0                                        # src_y = out_y -> full reclaim
    elif xybarrel:
        Mx = barrel_M(nx * nx + ny * ny, kh, sign_h)   # r^2 -> X and Y (= radial; rows bow back)
        My = barrel_M(nx * nx + ny * ny, kv, sign_v)
    else:
        Mx = barrel_M(nx * nx, kh, sign_h)             # separable: x-mag from x, y-mag from y
        My = barrel_M(ny * ny, kv, sign_v)
    sx = cx + dx * Mx / ovh                         # overscan>1 = zoom in (crop edges)
    sy = cy + dy * My / ovv
    return sx, sy


def sample(pat, sx, sy):
    """Nearest-neighbor gather; out-of-bounds -> black."""
    xi, yi = np.round(sx).astype(int), np.round(sy).astype(int)
    ok = (xi >= 0) & (xi < W) & (yi >= 0) & (yi < H)
    out = np.zeros_like(pat)
    out[ok] = pat[np.clip(yi, 0, H - 1)[ok], np.clip(xi, 0, W - 1)[ok]]
    return out


def test_pattern():
    img = np.zeros((H, W, 3), np.uint8)
    img[:] = (10, 10, 20)
    for x in range(0, W, 20):
        img[:, x] = (60, 90, 140)
    for y in range(0, H, 20):
        img[y, :] = (60, 90, 140)
    img[10:14, :] = (255, 210, 40)                  # SCORE ROW (top-edge pain point)
    img[H // 2 - 1:H // 2 + 1, :] = (40, 160, 80)   # center crosshair
    img[:, W // 2 - 1:W // 2 + 1] = (40, 160, 80)
    return img


# ---------------- structural assertions ----------------
def check():
    oy, ox = np.mgrid[0:H, 0:W].astype(np.float64)
    sx, sy = warp_coords(kh=4, kv=0)                 # cylinder
    assert np.allclose(sy, oy), "CYLINDER FAIL: src_y != out_y at kv=0"
    sx, sy = warp_coords(kh=0, kv=0)                 # identity
    assert np.allclose(sx, ox) and np.allclose(sy, oy), "IDENTITY FAIL"
    # max vertical displacement vs kv -> drives the Stage-2 buffer depth / reclaim dial
    for kv in (0, 1, 2, 4, 7):
        _, sy = warp_coords(kh=2, kv=kv)
        print(f"  kv={kv}: max |src_y-out_y| = {np.max(np.abs(sy-oy)):6.1f} src lines")
    print("PASS: kv=0 => src_y==out_y (clean cylinder);  kh=kv=0 => identity")


MODES = [
    ("01_identity.png",      "IDENTITY  (k=0)",              dict(kh=0, kv=0)),
    ("02_radial_ref.png",    "RADIAL ref (old, k=2)",        None),  # special-cased below
    ("03_separable_sym.png", "SEPARABLE sym (kh=kv=2)",      dict(kh=2, kv=2)),
    ("04_cylinder.png",      "CYLINDER (kh=2, kv=0) <- GOAL", dict(kh=2, kv=0)),
    ("05_h_gt_v.png",        "H>V (kh=3, kv=1)",             dict(kh=3, kv=1)),
    ("06_pincushion.png",    "PINCUSHION (kh=kv=2, -)",      dict(kh=2, kv=2, sign_h=-1, sign_v=-1)),
    ("07_overscan_cyl.png",  "CYLINDER + H-overscan 1.12",   dict(kh=2, kv=0, ovh=1.12)),
    ("08_xbarrel.png",       "X-BARREL (sides bow, rows flat)", dict(kh=2, kv=0, xbarrel=True)),
    ("09_xybarrel.png",      "XY-BARREL (r2->X+Y = radial)",    dict(kh=2, kv=2, xybarrel=True)),
]


def radial_ref():
    """Today's radial barrel (one M from combined r^2) for side-by-side contrast."""
    cx, cy = (W - 1) / 2.0, (H - 1) / 2.0
    oy, ox = np.mgrid[0:H, 0:W].astype(np.float64)
    dx, dy = ox - cx, oy - cy
    nx, ny = dx / cx, dy / cy
    M = barrel_M(nx * nx + ny * ny, 2)              # combined r^2 -> one magnitude
    return cx + dx * M, cy + dy * M


def main():
    pat = test_pattern()
    Image.fromarray(pat).save(os.path.join(OUT, "00_source.png"))
    check()

    tiles = [("SOURCE", pat)]
    for name, label, kw in MODES:
        sx, sy = radial_ref() if kw is None else warp_coords(**kw)
        img = sample(pat, sx, sy)
        Image.fromarray(img).save(os.path.join(OUT, name))
        tiles.append((label, img))

    # contact sheet, 2 cols, with text labels
    cols = 2
    rows = (len(tiles) + cols - 1) // cols
    pad, bar = 8, 16
    cw, ch = W + pad, H + pad + bar
    sheet = Image.new("RGB", (cols * cw + pad, rows * ch + pad), (0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    for i, (label, im) in enumerate(tiles):
        r, c = divmod(i, cols)
        x0, y0 = pad + c * cw, pad + r * ch
        draw.text((x0 + 2, y0 + 3), label, fill=(255, 255, 255))
        sheet.paste(Image.fromarray(im), (x0, y0 + bar))
    sheet.save(os.path.join(OUT, "warp_sheet.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
