#!/usr/bin/env python3
"""Map our warp dials (k = horizontal bow 0-7, kv = vertical bow 0-7) onto
crt-royale's geometry params, so a royale user gets familiar presets.

VERIFIED royale reference (libretro slang-shaders user-settings.h, 2026-05-30):
  geom_mode  0=Off/flat, 1=spherical(cgwg), 2=bulbous spherical, 3=cylindrical/Trinitron
  geom_radius default 2.0, range [1/(2*pi), 1024], in VIEWPORT-DIAGONAL units (small=more curve)
  geom_view_dist default 2.0   border_size default 0.015 (range [0,0.5] UV)

BRIDGE METRIC (applied identically to both): "edge curvature %" =
  take an evenly-spaced grid of UNDISTORTED content; lay it on the curved screen;
  measure how much the OUTERMOST cell is compressed vs the CENTER cell:
      edge_curv = 1 - (edge_cell_width / center_cell_width)
  0% = linear/flat, higher = more visibly curved at the edges.

HONEST LIMITATION: royale's cylinder is a PERSPECTIVE-projected physical surface
(view_dist adds top/bottom sag + foreshortening). Our separable cylinder has NO
perspective term -- it reproduces the EDGE-COMPRESSION amount, not the sag. So this
maps "how much curve," not a pixel-exact royale clone. Good enough to pick presets
that land in a familiar range; not a substitute for royale's full 3D projection.

Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_royale_map.py
"""
import numpy as np

# ---- geometry: 4:3, royale measures radius in VIEWPORT-DIAGONAL units ----
AR_W, AR_H = 4.0, 3.0
diag = (AR_W**2 + AR_H**2) ** 0.5          # = 5
half_w = 0.5 * AR_W / diag                  # half screen width in diagonal units = 0.4

# ---- OUR engine math (faithful, from the shipped LUT) ----
W = 480; cx = W // 2
K_LUT = 0.3; SCALE = 2 ** 24
AX2 = round(508 * SCALE / (508 * cx * cx + 498 * (360 // 2) ** 2))   # res-adaptive 188 @480x360


def meff(s4, K):
    idx = np.minimum(np.asarray(s4, dtype=np.int64) >> 16, 256)
    m = 1.0 + K_LUT * idx / 256.0
    return 1.0 + (m - 1.0) * K / 2.0


def our_edge_curv(K):
    """Edge-cell compression for our separable cylinder X warp at strength k=K."""
    if K == 0:
        return 0.0
    dx = np.arange(W) - cx
    eM = float(meff(np.array([AX2 * cx * cx]), K)[0])
    sx = cx + dx * (meff(AX2 * dx * dx, K) / eM)        # output->source map
    # invert: uniform source grid -> where does it land in output? measure cell widths.
    src_grid = np.linspace(sx.min(), sx.max(), 41)
    ox_of = np.interp(src_grid, sx, np.arange(W))        # sx is monotonic in ox
    widths = np.diff(ox_of)
    center_w = widths[len(widths) // 2]
    edge_w = widths[0]
    return 1.0 - edge_w / center_w


def royale_cyl_edge_curv(R, view_dist=None):
    """Edge-cell compression for a cylinder of radius R (diagonal units).
    Orthographic baseline = 1-cos(theta_max). With finite view_dist, add the
    first-order perspective foreshortening of the receded edge."""
    theta_max = half_w / R
    if theta_max >= np.pi / 2:
        return 1.0
    # uniform content along the arc (arc-coord u), screen x = R*sin(u/R)
    u = np.linspace(-half_w, half_w, 41)
    x = R * np.sin(u / R)
    if view_dist is not None:
        z = R * (1 - np.cos(u / R))                      # how far the surface recedes
        x = x * view_dist / (view_dist + z)              # perspective divide
    widths = np.diff(x)
    return 1.0 - widths[0] / widths[len(widths) // 2]


print(f"AX2={AX2}  half_w={half_w:.3f} diag-units (4:3)\n")

print("OUR k -> edge curvature %:")
our = {}
for K in range(8):
    ec = our_edge_curv(K) * 100
    our[K] = ec
    print(f"  k={K}:  {ec:6.1f}%")

print("\nROYALE cylindrical (mode 3) geom_radius -> edge curvature %:")
print(f"  {'R':>6} {'ortho':>8} {'+persp(vd=2)':>13}")
roy = {}
for R in (8.0, 5.0, 3.0, 2.0, 1.5, 1.0, 0.75, 0.5, 0.35):
    o = royale_cyl_edge_curv(R) * 100
    p = royale_cyl_edge_curv(R, view_dist=2.0) * 100
    roy[R] = p
    star = "  <- royale DEFAULT" if abs(R - 2.0) < 1e-6 else ""
    print(f"  {R:>6.2f} {o:>7.1f}% {p:>12.1f}%{star}")

# ---- map each k to the royale radius with the closest edge curvature ----
print("\nMAPPING  (our k  ~=  royale geom_radius giving the same edge curve, persp vd=2):")
Rs = np.array(sorted(roy.keys()))
Rcurv = np.array([roy[R] for R in Rs])
for K in range(1, 8):
    target = our[K]
    j = int(np.argmin(np.abs(Rcurv - target)))
    print(f"  k={K} ({target:5.1f}%)  ~=  geom_radius {Rs[j]:.2f} ({Rcurv[j]:.1f}%)")

print("""
PROPOSED PRESETS (royale-familiar names -> our dials):
  "Flat"         : enable off                 (= royale geom_mode 0, the royale default)
  "Trinitron"    : kv=0, k~=2                  (= royale geom_mode 3 cylindrical, ~moderate radius)
  "Spherical"    : kv=7, k~=2                  (= royale geom_mode 1 spherical)
  "Heavy"        : kv=0..7, k=4..5             (small radius / strong curve)
  Corner radius  : our Block-B radius  <->  royale border_size (default 0.015, range 0..0.5 UV)
""")
