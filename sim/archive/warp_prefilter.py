#!/usr/bin/env python3
"""Task 2 prework (sim-FIRST): validate the Jacobian-gated minification prefilter.

Goals, each must pass on its own merit before any RTL:
  (1) ANALYTIC Jacobian == numerical gradient. Size the footprint from a closed
      form, NOT numerical ddx/ddy. Separable cylinder X warp:
          Meff  = 1 + a*dx^2          (a = 0.15*K*AX2/2^24; engine stage-9 mag)
          src_x = cx + dx*Meff/edge_M
          J = d(src_x)/d(ox) = (1 + 3a*dx^2)/edge_M = (3*Meff - 2)/edge_M
      => J is a trivial function of the ALREADY-COMPUTED Meff. No derivative HW.
  (2) HARDWARE running-box (add-on-enter/subtract-on-leave, monotone sx) ==
      prefix-sum box-mean, bit-equal. (Research doc rejects SAT for HW; the
      running box is the realizable form.)
  (3) Does the gated box actually REDUCE aliasing vs plain 2-tap bilinear, and at
      which curvature? Measured against an EXACT continuous area-average reference
      (closed-form integral of the line field over each output pixel's source
      preimage -- no sampling noise, not circular). Swept over k=2,4,7.

Honest measurement is the point: if the box doesn't help at the shipped k=2, say so.

Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_prefilter.py
"""
import os
import numpy as np
from PIL import Image, ImageDraw

W, H = 480, 360
cx, cy = W // 2, H // 2
K_LUT = 0.3
SCALE = 2 ** 24
GRID = 10                       # vertical grid: 2px line every 10px (minification torture)
LINEW = 2

AX2 = round(508 * SCALE / (508 * cx * cx + 498 * cy * cy))   # 188 at 480x360 (res-adaptive)


def meff_q(s4, K):
    idx = np.minimum(np.asarray(s4, dtype=np.int64) >> 16, 256)
    m = 1.0 + K_LUT * idx / 256.0
    return 1.0 + (m - 1.0) * K / 2.0


def edge_M_of(K):
    return float(meff_q(np.array([AX2 * cx * cx]), K)[0])


# ---- EXACT continuous area-average of the line field over [a,b] ----
# line field f(x) = 1 if (x mod GRID) in [0,LINEW), else 0.  cov(a,b) = (1/(b-a)) * |{x in [a,b]: line}|.
def line_measure(b):
    """Lebesgue measure of line-region in [0,b] (b>=0), closed form."""
    b = np.maximum(b, 0.0)
    full = np.floor(b / GRID)                 # whole periods
    rem = b - full * GRID                     # remainder in [0,GRID)
    return full * LINEW + np.minimum(rem, LINEW)


def area_average(a, b):
    """Exact mean of the line field over [a,b] (a<b)."""
    a = np.clip(a, 0, W); b = np.clip(b, 0, W)
    width = np.maximum(b - a, 1e-9)
    return (line_measure(b) - line_measure(a)) / width


_LINECOL = ((np.arange(W) % GRID) < LINEW).astype(np.float64)
_PS = np.concatenate([[0.0], np.cumsum(_LINECOL)])


def run_k(K):
    dx = np.arange(W) - cx
    eM = edge_M_of(K)
    a_coef = 0.15 * K * AX2 / SCALE
    sx = cx + dx * (meff_q(AX2 * dx * dx, K) / eM)            # faithful warp
    J_num = np.abs(np.gradient(sx))
    J_ana = (1.0 + 3.0 * a_coef * dx * dx) / eM              # closed form
    jerr = float(np.max(np.abs(J_ana - J_num)[3:-3]))

    # samplers
    x0 = np.clip(np.floor(sx).astype(int), 0, W - 1)
    x1 = np.clip(x0 + 1, 0, W - 1)
    f = sx - np.floor(sx)
    bil = _LINECOL[x0] * (1 - f) + _LINECOL[x1] * f

    hw = np.clip(J_ana * 0.5, 0.0, 16.0)
    lo = np.clip(np.round(sx - hw).astype(int), 0, W)
    hi = np.clip(np.round(sx + hw).astype(int) + 1, 0, W)
    box = (_PS[hi] - _PS[lo]) / np.maximum(hi - lo, 1)

    # running-box (HW model) — prove == prefix-sum box
    rb = np.zeros(W); acc = 0.0; lp = 0; hp = 0
    for i in range(W):
        while hp < hi[i]: acc += _LINECOL[hp]; hp += 1
        while lp < lo[i]: acc -= _LINECOL[lp]; lp += 1
        rb[i] = acc / max(hp - lp, 1)
    rb_match = float(np.max(np.abs(rb - box)))

    gate = J_ana > 1.05
    box_g = np.where(gate, box, bil)

    # TENT (2-box cascade): convolve the box-mean with a second box of the same
    # half-width => triangular weighting. HW = a second running accumulator over
    # the first box's output (still ~0 DSP, monotone sx). Better freq response than
    # the flat box => should remove the box's MAE regression at high k.
    hw_i = np.maximum(np.round(hw).astype(int), 1)
    tent = np.empty(W)
    # box-of-box via a second prefix sum over the per-column box result
    box_ps2 = np.concatenate([[0.0], np.cumsum(box)])
    lo2 = np.clip(np.arange(W) - hw_i, 0, W)
    hi2 = np.clip(np.arange(W) + hw_i + 1, 0, W)
    tent = (box_ps2[hi2] - box_ps2[lo2]) / np.maximum(hi2 - lo2, 1)
    tent_g = np.where(gate, tent, bil)

    # OUTPUT-SUPERSAMPLE (crt-geom tier): N sub-positions per output pixel, warp +
    # bilinear-sample each along the actual curve, average. Samples ALONG the warp so
    # there is no integer-window pathology; footprint follows J automatically.
    def supersample(n):
        accum = np.zeros(W)
        for kk in range(n):
            off = (kk + 0.5) / n - 0.5                       # -0.5..+0.5 across the output px
            ox_s = (np.arange(W) - cx) + off
            sx_s = cx + ox_s * (meff_q(AX2 * ox_s * ox_s, K) / eM)
            xs0 = np.clip(np.floor(sx_s).astype(int), 0, W - 1)
            xs1 = np.clip(xs0 + 1, 0, W - 1)
            ff = sx_s - np.floor(sx_s)
            accum += _LINECOL[xs0] * (1 - ff) + _LINECOL[xs1] * ff
        return accum / n
    ss3 = np.where(gate, supersample(3), bil)
    ss8 = supersample(8)                                     # near-ideal (full-frame)

    # EXACT reference: area-average over each output pixel's source preimage
    ref = area_average(sx - J_ana * 0.5, sx + J_ana * 0.5)

    band = gate
    def metrics(v):
        if not band.any(): return (0.0, 0.0, 0.0)
        e = (v - ref)[band]
        mae = float(np.mean(np.abs(e)))
        mx = float(np.max(np.abs(e)))
        hf = float(np.std(np.diff(v[band])))                # high-freq energy proxy (aliasing)
        return mae, mx, hf
    return dict(K=K, eM=eM, jerr=jerr, rb_match=rb_match, jmax=float(J_ana.max()),
                band_n=int(gate.sum()), m_bil=metrics(bil), m_box=metrics(box_g),
                m_tent=metrics(tent_g), m_ss3=metrics(ss3), m_ss8=metrics(ss8),
                sx=sx, bil=bil, box=box_g, tent=tent_g, ss3=ss3, ss8=ss8, ref=ref, J=J_ana)


print(f"AX2={AX2} (res-adaptive @480x360).  Metrics in the minifying band: "
      f"MAE / MAXerr / HFenergy  vs exact area-average reference. Lower=better.")
print(f"HF = high-frequency energy = the ALIASING proxy (the thing we want to kill).")
print(f"{'k':>2} {'Jmax':>5} | {'bilinear MAE/MAX/HF':>21} | {'gated-box':>21} | "
      f"{'gated-TENT':>21} | {'3x super':>21}")
results = {}
for K in (2, 4, 7):
    r = run_k(K); results[K] = r
    def fmt(m): return f"{m[0]:.3f}/{m[1]:.3f}/{m[2]:.3f}"
    print(f"{K:>2} {r['jmax']:>5.2f} | {fmt(r['m_bil']):>21} | {fmt(r['m_box']):>21} | "
          f"{fmt(r['m_tent']):>21} | {fmt(r['m_ss3']):>21}")
# HF-reduction headline (vs bilinear), the metric that matters for AA
print()
for K in (2, 4, 7):
    r = results[K]
    hb = r['m_bil'][2]
    print(f"  k={K}: HF reduction vs bilinear  box={100*(1-r['m_box'][2]/hb):.0f}%  "
          f"tent={100*(1-r['m_tent'][2]/hb):.0f}%   "
          f"MAE delta  box={r['m_box'][0]-r['m_bil'][0]:+.3f}  tent={r['m_tent'][0]-r['m_bil'][0]:+.3f}")

# render sheet for k=7 (where minification is strongest / most visible)
r = results[7]
def tile(row, label):
    hrow = ((np.arange(H) % GRID) < LINEW).astype(np.float64)[:, None]
    field = np.maximum(row[None, :], hrow)
    g = np.clip(field * 240, 0, 255).astype(np.uint8)
    return label, np.dstack([g, g, g])
tiles = [
    tile(r['bil'],  "k=7 2-tap BILINEAR only - aliases in outer band"),
    tile(r['box'],  "k=7 JACOBIAN-GATED RUNNING-BOX (flat)"),
    tile(r['tent'], "k=7 JACOBIAN-GATED TENT (2-box cascade) - recommended"),
    tile(r['ref'],  "k=7 EXACT area-average reference"),
]
bar = 18
sheet = Image.new("RGB", (W + 16, len(tiles) * (H + bar) + 16), (0, 0, 0))
d = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(tiles):
    y0 = 8 + i * (H + bar)
    d.text((10, y0 + 3), label, fill=(255, 255, 255))
    sheet.paste(Image.fromarray(im), (8, y0 + bar))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "warp_out", "warp_prefilter.png")
sheet.save(out)
print("wrote", out)
