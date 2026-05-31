#!/usr/bin/env python3
"""BIT-EXACT model of the vis_warp X datapath, to REPRODUCE the hardware line-
doubling the float model missed. Every stage is integer, matching vis_warp_v2_wp.vhd.

Datapath (X axis), per output column ox on a row, cx = src_w//2:
  dx        = ox - cx
  s2_dx2    = dx*dx
  s3        = AX2 * s2_dx2                       (AX2 = res-adaptive reg_ax2_u)
  s4        = s3                                 (32-bit; LUT input)
  idx       = s4[23:16]   (clamp <=256)         <-- LUT-input quantization to 1/256
  frac8     = s4[15:8]
  m_lo,m_hi = WARP_LUT[idx], WARP_LUT[idx+1]
  m_raw     = m_lo + ((m_hi-m_lo)*frac8 >> 8)    (Q15)
  m_cent    = m_raw - 32768
  s8x       = m_cent * k                          (k = curvature_k 0..7)
  v         = s8x // 2 + 32768 ; clamp [0,65535]
  v         = (v * OVERSCAN_X_Q15) // 32768       (fill; INTEGER divide)
  Mx        = v                                   (s9x_m_scaled, Q15)
  s10       = dx * Mx                              (signed Q15)
  srcq15    = cx*32768 + s10
  src_int   = srcq15 // 32768                      (toward zero; positive in-frame)
  fx8       = (srcq15 >> 7) & 0xFF                 (bits[14:7] -- 8-bit blend frac)
  fs        = clamp((fx8-128)*Ksharp//2 + 128, 0, 255)   (sharpen)
  lum       = (line[x0]*(256-fs) + line[x1]*fs) >> 8       (bilinear, 8-bit weights)

Compares OLD (k=2,KL=0.3,fill=27458) vs candidate fixes, on the 1px/16 grid, and
COUNTS doubled source lines (a source line rendered in >=2 separated output runs)
and dropped lines (rendered in 0). This is the metric that must match hardware.

Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_bitexact.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw

W = 480; cx = W // 2; H = 360; cy = H // 2
SCALE = 2 ** 24
AX2 = round(508 * SCALE / (508 * cx * cx + 498 * cy * cy))   # 188
GRID = 16; LINEW = 1
UP = 3

line = ((np.arange(W) % GRID) < LINEW).astype(np.int64) * 255   # 8-bit source luma


def build_lut(K_LUT):
    """257-entry Q15 WARP_LUT, M = 1 + K_LUT*(i/256)."""
    return [round((1.0 + K_LUT * (i / 256.0)) * 32768) for i in range(257)]


def render_row(K_LUT, k, fill_q15, Ksharp, lut, prescale=1):
    """prescale = internal integer NN upscale of the source BEFORE warp (royale-style,
    but cheap integer). The warp then bends prescale*W-wide content with prescale*-fat
    features, and the OUTPUT is still W cols (we sample the prescaled source).
    AX2 must rescale: cx grows by prescale, so AX2 -> AX2/prescale^2 to keep edge r2."""
    Wp = W * prescale
    cxp = Wp // 2
    AX2p = round(508 * SCALE / (508 * cxp * cxp + 498 * (cy * prescale) ** 2))
    line_p = ((np.arange(Wp) // prescale % GRID) < LINEW).astype(np.int64) * 255  # NN-upscaled source
    out = np.zeros(W, dtype=np.int64)
    srcx = np.zeros(W)
    for ox in range(W):
        # output column ox -> prescaled output coord (sample center of the up-region)
        oxp = ox * prescale + prescale // 2
        dx = oxp - cxp
        s4 = AX2p * dx * dx
        idx = (s4 >> 16)
        if idx > 256: idx = 256
        frac8 = (s4 >> 8) & 0xFF
        m_lo = lut[idx]; m_hi = lut[idx + 1] if idx < 256 else lut[256]
        m_raw = m_lo + (((m_hi - m_lo) * frac8) >> 8)
        m_cent = m_raw - 32768
        s8 = m_cent * k
        v = (s8 // 2) + 32768
        if v < 0: v = 0
        elif v > 65535: v = 65535
        v = (v * fill_q15) // 32768
        Mx = v
        s10 = dx * Mx
        srcq15 = cxp * 32768 + s10
        src_int = srcq15 // 32768
        fx8 = (srcq15 >> 7) & 0xFF
        fs = (fx8 - 128) * Ksharp // 2 + 128
        if fs < 0: fs = 0
        elif fs > 255: fs = 255
        x0 = src_int if 0 <= src_int < Wp else (0 if src_int < 0 else Wp - 1)
        x1 = x0 + 1 if x0 + 1 < Wp else Wp - 1
        out[ox] = (int(line_p[x0]) * (256 - fs) + int(line_p[x1]) * fs) >> 8
        srcx[ox] = srcq15 / 32768.0 / prescale
    return out, srcx


def render_row_hires(K_LUT, k, fill_q15, Ksharp, lut, prescale):
    """TRUE royale-style: source AND output at prescale*W. Warp bends fat features
    at high density, no decimation. This is what the screen would show if vis_warp
    ran at higher internal res and ascal did the final downscale. Output width Wp."""
    Wp = W * prescale
    cxp = Wp // 2
    AX2p = round(508 * SCALE / (508 * cxp * cxp + 498 * (cy * prescale) ** 2))
    line_p = ((np.arange(Wp) // prescale % GRID) < LINEW).astype(np.int64) * 255
    out = np.zeros(Wp, dtype=np.int64)
    for ox in range(Wp):
        dx = ox - cxp
        s4 = AX2p * dx * dx
        idx = (s4 >> 16)
        if idx > 256: idx = 256
        frac8 = (s4 >> 8) & 0xFF
        m_lo = lut[idx]; m_hi = lut[idx + 1] if idx < 256 else lut[256]
        m_raw = m_lo + (((m_hi - m_lo) * frac8) >> 8)
        s8 = (m_raw - 32768) * k
        v = (s8 // 2) + 32768
        v = 0 if v < 0 else (65535 if v > 65535 else v)
        v = (v * fill_q15) // 32768
        srcq15 = cxp * 32768 + dx * v
        src_int = srcq15 // 32768
        fx8 = (srcq15 >> 7) & 0xFF
        fs = (fx8 - 128) * Ksharp // 2 + 128
        fs = 0 if fs < 0 else (255 if fs > 255 else fs)
        x0 = src_int if 0 <= src_int < Wp else (0 if src_int < 0 else Wp - 1)
        x1 = x0 + 1 if x0 + 1 < Wp else Wp - 1
        out[ox] = (int(line_p[x0]) * (256 - fs) + int(line_p[x1]) * fs) >> 8
    # count runs vs source lines (source has Wp/GRID/... lines, each prescale-wide)
    bright = out > 96
    runs = 0; i = 0; widths = []
    while i < Wp:
        if bright[i]:
            j = i
            while j < Wp and bright[j]: j += 1
            runs += 1; widths.append(j - i); i = j
        else:
            i += 1
    n_src = int(((np.arange(Wp) // prescale % GRID) < LINEW).any(0)) if False else \
            len([1 for c in range(0, Wp, 1) if (c // prescale % GRID) < LINEW and (c == 0 or ((c-1)//prescale % GRID) >= LINEW)])
    widths = np.array(widths) if widths else np.array([0])
    return runs, n_src, widths, out


def render_row_p1(K_LUT, k, fill_q15, Ksharp, lut):
    out = np.zeros(W, dtype=np.int64)
    srcx = np.zeros(W)
    for ox in range(W):
        dx = ox - cx
        s4 = AX2 * dx * dx                       # >=0
        idx = (s4 >> 16)
        if idx > 256: idx = 256
        frac8 = (s4 >> 8) & 0xFF
        m_lo = lut[idx]; m_hi = lut[idx + 1] if idx < 256 else lut[256]
        m_raw = m_lo + (((m_hi - m_lo) * frac8) >> 8)
        m_cent = m_raw - 32768
        s8 = m_cent * k
        v = (s8 // 2) + 32768                     # python // floors; s8<=0 here so matches trunc? see note
        # NOTE: VHDL integer '/2' truncates toward zero. s8 = m_cent*k, m_cent>=0 here
        # (m_raw>=32768 for magnify LUT), so s8>=0 -> // and trunc agree.
        if v < 0: v = 0
        elif v > 65535: v = 65535
        v = (v * fill_q15) // 32768
        Mx = v
        s10 = dx * Mx
        srcq15 = cx * 32768 + s10
        src_int = srcq15 // 32768
        fx8 = (srcq15 >> 7) & 0xFF
        # sharpen
        fs = (fx8 - 128) * Ksharp // 2 + 128
        if fs < 0: fs = 0
        elif fs > 255: fs = 255
        x0 = src_int if 0 <= src_int < W else (0 if src_int < 0 else W - 1)
        x1 = x0 + 1 if x0 + 1 < W else W - 1
        out[ox] = (int(line[x0]) * (256 - fs) + int(line[x1]) * fs) >> 8
        srcx[ox] = srcq15 / 32768.0
    return out, srcx


def count_artifacts(out):
    """For each SOURCE line, how many separate output runs render it (>1 = doubled,
    0 = dropped). Map via the cleanest proxy: count bright runs vs source lines."""
    bright = out > 96
    runs = 0; i = 0; widths = []
    while i < W:
        if bright[i]:
            j = i
            while j < W and bright[j]:
                j += 1
            runs += 1; widths.append(j - i)
            i = j
        else:
            i += 1
    n_src = int((line > 0).sum())                 # source lit columns
    widths = np.array(widths) if widths else np.array([0])
    return runs, n_src, widths


# (KL, k, fill, Ksharp, prescale)
CONFIGS = [
    ("OLD shipped       KL=0.3 k=2 fill=27458 Ks=4 p=1", 0.3, 2, 27458, 4, 1),
    ("soft LUT          KL=0.1 k=1 fill=31745 Ks=4 p=1", 0.1, 1, 31745, 4, 1),
    ("PRESCALE 2x       KL=0.3 k=2 fill=27458 Ks=4 p=2", 0.3, 2, 27458, 4, 2),
    ("PRESCALE 2x soft  KL=0.1 k=1 fill=31745 Ks=4 p=2", 0.1, 1, 31745, 4, 2),
    ("PRESCALE 3x       KL=0.3 k=2 fill=27458 Ks=4 p=3", 0.3, 2, 27458, 4, 3),
]

print(f"AX2={AX2}  grid {GRID}px/{LINEW}px  (runs should == src lines={int((line>0).sum())}; >src = DOUBLING)")
print(f"{'config':>50} {'ctr':>7} {'runs/src':>9} {'maxW':>5} {'wideRuns':>8}")
tiles = []
for label, KL, k, fill, Ks, ps in CONFIGS:
    lut = build_lut(KL)
    out, srcx = (render_row_p1(KL, k, fill, Ks, lut) if ps == 1
                 else render_row(KL, k, fill, Ks, lut, prescale=ps))
    runs, nsrc, widths = count_artifacts(out)
    ctr = (srcx[cx + 1] - srcx[cx - 1]) / 2.0
    wide = int((widths >= 2).sum())
    print(f"{label:>50} {ctr:>7.4f} {f'{runs}/{nsrc}':>9} {int(widths.max()):>5} {wide:>8}")
    tiles.append((label, np.repeat(out, UP)))

STRIP_H = 70; BAR = 16; Wd = W * UP
sheet = Image.new("RGB", (Wd + 16, len(tiles) * (STRIP_H + BAR) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (label, disp) in enumerate(tiles):
    y0 = 8 + i * (STRIP_H + BAR)
    d.text((10, y0 + 3), label, fill=(255, 255, 255))
    g = np.clip(disp, 0, 255).astype(np.uint8)
    strip = np.tile(g[None, :], (STRIP_H, 1))
    sheet.paste(Image.fromarray(np.dstack([strip, strip, strip])), (8, y0 + BAR))
out_png = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_bitexact.png")
sheet.save(out_png)
print("\nctr Mx/32768 < 1.0 => center MAGNIFIES (source advances <1px per output px => doubling).")
print("wrote", out_png)

# --- TRUE hi-res warp (royale-style: output ALSO at prescale res, no decimation) ---
print("\nTRUE HI-RES WARP (output at prescale*W, ascal does final scale):")
print(f"{'config':>40} {'runs/src':>10} {'maxW':>5} {'wideRuns':>8}")
for label, KL, k, fill, Ks, ps in [
    ("hi-res 2x  KL=0.3 k=2 fill=27458 Ks=4", 0.3, 2, 27458, 4, 2),
    ("hi-res 3x  KL=0.3 k=2 fill=27458 Ks=4", 0.3, 2, 27458, 4, 3),
    ("hi-res 4x  KL=0.3 k=2 fill=27458 Ks=4", 0.3, 2, 27458, 4, 4),
]:
    lut = build_lut(KL)
    runs, nsrc, widths, _ = render_row_hires(KL, k, fill, Ks, lut, ps)
    wide = int((widths >= 2 * ps).sum())   # "wide" = wider than the expected ps-px line
    print(f"{label:>40} {f'{runs}/{nsrc}':>10} {int(widths.max()):>5} {wide:>8}")
print("clean = runs == src AND maxW ~= prescale (each line stays one solid ps-wide run).")
