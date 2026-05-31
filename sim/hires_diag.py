#!/usr/bin/env python3
"""Diagnostic: replicate BOTH the authoritative model datapath (_warp_x, the one
that proved hi-res 2x clean) AND the vis_warp_v2_wp RTL datapath (read-double +
fraction-fix) in Python, at 296x240 grid16 OUT_SCALE=2, and diff them against the
GHDL output. Tells us (a) does the RTL replica match GHDL, (b) where RTL diverges
from the model. The model is the judge (SPEC-hires-warp / README)."""
import sys

SCALE = 2 ** 24
SRC_W, SRC_H, GRID = 296, 240, 16
OS = 2
FILL = 27458
KCURV = 2  # curvature_k


def build_lut(K_LUT=0.3):
    return [round((1.0 + K_LUT * (i / 256.0)) * 32768) for i in range(257)]


LUT = build_lut(0.3)
src = [255 if (c % GRID == 0) else 0 for c in range(SRC_W)]


def lut_m_raw(s4):
    """m_raw from r2/x2 accumulator s4 (>=0)."""
    if s4 >= SCALE:
        idx, frac = 255, 255
    else:
        idx, frac = (s4 >> 16), (s4 >> 8) & 0xFF
    m_lo = LUT[idx]
    m_hi = LUT[idx + 1] if idx < 256 else LUT[256]
    return m_lo + (((m_hi - m_lo) * frac) >> 8)


def ax2_rescal(w, h):
    """rescal output: round(508*2^24 / D), D=508*cx^2+498*cy^2, cx=w//2,cy=h//2,
    then low 13 bits (the RTL q_x(12:0)). 296x240->116 here (no truncation)."""
    cx, cy = w // 2, h // 2
    D = 508 * cx * cx + 498 * cy * cy
    return (round(508 * SCALE / D)) & 0x1FFF


def warp_x_rtl(ox, K):
    """vis_warp_v2_wp OUT_SCALE=2 path (read-double + fraction-fix), bit-faithful."""
    cxp = (OS * SRC_W) // 2
    AX2 = ax2_rescal(OS * SRC_W, OS * SRC_H)
    dx = ox - cxp
    s4 = AX2 * dx * dx
    m_raw = lut_m_raw(s4)
    m_cent = m_raw - 32768
    s8 = m_cent * KCURV
    v = (s8 // 2) + 32768
    v = 0 if v < 0 else (65535 if v > 65535 else v)
    v = (v * FILL) // 32768
    src_q15 = cxp * 32768 + dx * v
    src_x = src_q15 // 32768
    fx8 = (src_q15 >> 7) & 0xFF if src_q15 >= 0 else 0
    if src_x < 0:
        src_x, fx8 = 0, 0
    elif src_x >= OS * SRC_W - 1:
        src_x, fx8 = OS * SRC_W - 1, 0
    k = max(1, K)
    fs = k * (fx8 - 128) + 128
    fs = 0 if fs < 0 else (255 if fs > 255 else fs)
    # fraction fix: force 0 unless this is the boundary sub-col
    if OS > 1 and (src_x % OS) != (OS - 1):
        fs = 0
    col_lo = src_x // OS
    col_hi = (src_x + 1) // OS
    if col_hi > SRC_W - 1:
        col_hi = SRC_W - 1
    return (src[col_lo] * (256 - fs) + src[col_hi] * fs) >> 8


def warp_x_model(ox, K):
    """The authoritative _warp_x (NN-upscale-then-bilinear, sharpen = *K//2)."""
    Wp = OS * SRC_W
    cxp = Wp // 2
    cyp = OS * (SRC_H // 2)
    AX2 = round(508 * SCALE / (508 * cxp * cxp + 498 * cyp * cyp))  # full precision
    line_p = [src[x // OS] for x in range(Wp)]
    dx = ox - cxp
    s4 = AX2 * dx * dx
    m_raw = lut_m_raw(s4)
    s8 = (m_raw - 32768) * KCURV
    v = (s8 // 2) + 32768
    v = 0 if v < 0 else (65535 if v > 65535 else v)
    v = (v * FILL) // 32768
    src_q15 = cxp * 32768 + dx * v
    src_int = src_q15 // 32768
    fx8 = (src_q15 >> 7) & 0xFF
    fs = (fx8 - 128) * K // 2 + 128   # model sharpen = *K//2
    fs = 0 if fs < 0 else (255 if fs > 255 else fs)
    x0 = src_int if 0 <= src_int < Wp else (0 if src_int < 0 else Wp - 1)
    x1 = x0 + 1 if x0 + 1 < Wp else Wp - 1
    return (line_p[x0] * (256 - fs) + line_p[x1] * fs) >> 8


def runs(row):
    out, i, n = [], 0, len(row)
    while i < n:
        if row[i] > 96:
            j = i
            while j < n and row[j] > 96:
                j += 1
            out.append(j - i)
            i = j
        else:
            i += 1
    return out


def analyze(label, row):
    r = runs(row)
    nsrc = sum(1 for c in range(SRC_W) if c % GRID == 0)
    wide = sum(1 for w in r if w >= 2 * OS)
    print(f"{label:28} runs={len(r):2d}/{nsrc} maxW={max(r) if r else 0} "
          f"wide(>= {2*OS})={wide} split={len(r) > nsrc}")
    return r


print(f"AX2 rescal(592,480)={ax2_rescal(592,480)}  full-prec model AX2="
      f"{round(508*SCALE/(508*296*296+498*240*240))}")
for K in (4, 2, 1):
    mrow = [warp_x_model(ox, K) for ox in range(OS * SRC_W)]
    rrow = [warp_x_rtl(ox, K) for ox in range(OS * SRC_W)]
    print(f"\n--- K={K} ---")
    analyze(f"model (*K//2 sharpen) K={K}", mrow)
    analyze(f"rtl-replica (*K) K={K}", rrow)

# cross-check the RTL replica vs the GHDL dump (sharpness baked in the filename)
if len(sys.argv) > 2:
    ghdl_path, K = sys.argv[1], int(sys.argv[2])
    rows = [[int(v) for v in l.split()] for l in open(ghdl_path) if l.strip()]
    # middle non-line row
    H = len(rows)
    vrow = next(r for y, r in enumerate(rows)
                if sum(v > 96 for v in r) < 0.7 * len(r) and H // 3 < y < 2 * H // 3)
    rrow = [warp_x_rtl(ox, K) for ox in range(OS * SRC_W)]
    mism = sum(1 for a, b in zip([1 if v > 96 else 0 for v in vrow],
                                 [1 if v > 96 else 0 for v in rrow]) if a != b)
    print(f"\nGHDL vs rtl-replica (K={K}): {mism} bright-mask mismatches "
          f"of {len(rrow)} cols  -> {'MATCH' if mism == 0 else 'DIVERGE'}")
    analyze("GHDL row", vrow)
