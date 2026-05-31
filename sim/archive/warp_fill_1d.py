#!/usr/bin/env python3
"""Faithful 1-D model of the engine's HORIZONTAL warp (cylinder X path), to find
   the fill-compensation scale. Replicates the real arithmetic:
     dx   = ox - W/2
     s4   = AX2 * dx^2                (x²-only, separable cylinder)
     idx  = min(s4 >> 16, 256)        (LUT index; saturates)
     Mlut = 1 + 0.3 * idx/256         (WARP_LUT: M = 1 + 0.3*r2_norm)
     Meff = 1 + (Mlut-1) * K/2        (stage 7b/8/9 K scaling)
     src_x= W/2 + dx*Meff             (clamped to [0, W-1])
"""
AX2 = 508
K_LUT = 0.3


def meff(s4, K):
    idx = min(s4 >> 16, 256)
    mlut = 1.0 + K_LUT * idx / 256.0
    return 1.0 + (mlut - 1.0) * K / 2.0


def analyze(W, K, fill):
    cx = W // 2
    clamped_lo = clamped_hi = 0
    # edge magnitude (dx = cx) drives the fill factor
    edge_m = meff(AX2 * cx * cx, K)
    for ox in range(W):
        dx = ox - cx
        m = meff(AX2 * dx * dx, K)
        src = cx + dx * m / fill
        if src < 0:
            clamped_lo += 1
        elif src > W - 1:
            clamped_hi += 1
    return edge_m, clamped_lo, clamped_hi


for W in (288, 480):
    for K in (2,):
        em, lo, hi = analyze(W, K, fill=1.0)
        print(f"W={W} K={K}  edge_M={em:.3f}  NO-FILL: clamp L={lo}px ({100*lo/W:.0f}%) R={hi}px ({100*hi/W:.0f}%)")
        # apply fill = edge magnitude
        em2, lo2, hi2 = analyze(W, K, fill=em)
        print(f"           FILL={em:.3f}: clamp L={lo2}px R={hi2}px   (target: 0/0 = fills edge-to-edge)")
