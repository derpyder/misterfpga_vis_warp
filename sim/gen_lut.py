#!/usr/bin/env python3
"""Regenerate WARP_LUT for vis_warp_luts_pkg.vhd, AND calibrate K_LUT so the
k=0..7 dial spans a crt-royale-familiar curvature range (gentle default reachable).

Background (verified 2026-05-30):
  Engine magnitude: M_lut = 1 + K_LUT*(idx/256);  M_eff = 1 + (M_lut-1)*k/2.
  At the corner idx saturates (256) so M_eff_corner = 1 + K_LUT*(k/2).
  Edge curvature scales with (M_eff_corner - 1). Current K_LUT=0.3 makes even
  k=1 ~= 22% edge bow (royale default is ~7% @ geom_radius 2.0). Goal: lower K_LUT
  so the low k's reach royale-gentle, keeping k=7 usefully strong.

Royale reference (libretro user-settings.h): geom_radius default 2.0 -> ~7% edge
bow (our metric, perspective vd=2); R=1.0 -> ~18%; R=0.5 -> ~44%.

Target family: k=1 ~5-8% (royale default-ish), k=2 ~12%, k=4 ~25%, k=7 ~45% (strong
but not extreme). The 'edge bow %' metric is the SAME one used in warp_royale_map.py.

This script: (1) sweeps K_LUT to find the best fit to that target family, (2) prints
the resulting per-k edge bow + the REQUIRED fill (edge_M) per k, (3) emits the LUT
table text for the chosen K_LUT. It does NOT write the .vhd; review first.

Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/gen_lut.py
"""
import numpy as np

NPTS = 257
W = 480; cx = W // 2; H = 360; cy = H // 2
SCALE = 2 ** 24
AX2 = round(508 * SCALE / (508 * cx * cx + 498 * cy * cy))    # 188 @480x360

# 4:3 edge-bow metric geometry (matches warp_royale_map.py)
# (edge-cell compression of a uniform grid under our separable cylinder X warp)


# r2_norm reached at the X (horizontal) edge of the separable cylinder.
# s4_x2only = AX2*dx^2 only (no dy term). At dx=cx, dy=0:
#   AX2*cx^2/2^24 = 508*2^24/788 / 2^24 ... = 508/788 ~= 0.6447 for ANY 4:3 res
#   (AX2 is res-adaptive = 508*2^24/(508cx^2+498cy^2); cy=0.75cx for 4:3 ->
#    denom=788cx^2 -> AX2*cx^2 = 508/788 * 2^24). Aspect-constant, NOT saturated.
R2_XEDGE = 508.0 / 788.0   # ~= 0.6447


def meff_corner(K_LUT, k):
    """M_eff at the X (horizontal) edge for curve strength k. The edge does NOT
    saturate the LUT (r2_norm=0.6447, not 1.0), so the fill uses this, not 1+K*k/2."""
    return 1.0 + K_LUT * R2_XEDGE * (k / 2.0)


def edge_bow(K_LUT, k):
    """Edge-cell compression % for our X warp at (K_LUT, k), with res-adaptive fill."""
    if k == 0:
        return 0.0
    dx = np.arange(W) - cx
    s4 = AX2 * dx * dx
    idx = np.minimum(s4 >> 16, 256)
    m_lut = 1.0 + K_LUT * idx / 256.0
    m_eff = 1.0 + (m_lut - 1.0) * k / 2.0
    eM = meff_corner(K_LUT, k)                    # fill = corner magnitude (per-k ideal)
    sx = cx + dx * (m_eff / eM)
    src = np.linspace(sx.min(), sx.max(), 41)
    oxf = np.interp(src, sx, np.arange(W))
    wdt = np.diff(oxf)
    return (1.0 - wdt[0] / wdt[len(wdt)//2]) * 100.0


# royale-familiar target edge-bow per k (the design goal)
TARGET = {1: 6.0, 2: 12.0, 3: 18.0, 4: 25.0, 5: 32.0, 6: 39.0, 7: 45.0}

print("Calibrating K_LUT to a royale-familiar k-family (edge bow %):")
print(f"  target: " + "  ".join(f"k{k}={v:.0f}%" for k, v in TARGET.items()))
print()
best = None
for K_LUT in np.arange(0.04, 0.32, 0.005):
    err = sum((edge_bow(K_LUT, k) - TARGET[k]) ** 2 for k in TARGET)
    if best is None or err < best[1]:
        best = (K_LUT, err)
K_LUT = round(best[0], 3)
print(f"BEST FIT K_LUT = {K_LUT}  (was 0.3)\n")

print(f"{'k':>2} {'edge bow %':>10} {'M_eff_corner':>13} {'required fill (32768/eM)':>24}")
for k in range(8):
    eb = edge_bow(K_LUT, k)
    eM = meff_corner(K_LUT, k) if k else 1.0
    fill = round(32768 / eM)
    print(f"{k:>2} {eb:>9.1f}% {eM:>13.4f} {fill:>24}")

print(f"""
NOTE the fill column: edge_M (hence the fill constant) DIFFERS per k. The engine
currently bakes ONE fill (27458). Options surfaced for the RTL step:
  (a) bake the fill for the DEFAULT k only (image fills exactly at default k,
      slight over/under-fill at other k) -- simplest, 1 constant.
  (b) make fill a tiny per-k LUT (8 entries) indexed by k -- exact fill at every k.
Default-k choice drives (a). With royale-gentle defaults, pick the baked default k.
""")

# emit LUT text for the chosen K_LUT (Q1.15, 32768 = M 1.0)
print("---- WARP_LUT body for vis_warp_luts_pkg.vhd (K_LUT = %.3f) ----" % K_LUT)
lines = []
for i in range(NPTS):
    r2 = i / (NPTS - 1)
    M = 1.0 + K_LUT * (i / 256.0)
    q = round(M * 32768)
    tail = "," if i < NPTS - 1 else " "
    lines.append(f"        {i:>3} => to_unsigned({q}, 16){tail}  -- idx {i}, r2={r2:.4f}, M={M:.4f}")
# print just the 3 endpoints as a sanity check (full body written to file)
print(lines[0]); print(lines[128]); print(lines[256])
import os
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_lut_body.txt")
with open(out, "w") as f:
    f.write(f"-- K_LUT = {K_LUT}, K2_LUT = 0.0\n")
    f.write("\n".join(lines) + "\n")
print(f"\nfull 257-entry body written to {out}")
print(f"M_max (idx 256) = {1.0 + K_LUT:.4f}  (was 1.3000)")
