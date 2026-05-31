#!/usr/bin/env python3
"""Show the over/under-fill band you'd get with ONE baked fill constant vs the
8-entry per-k fill LUT, on the new royale-aligned LUT (K_LUT=0.1, default k=2).

Why: with K_LUT=0.1 the ideal fill (edge_M) varies with k:
   k=1->31208  k=2->29789  k=3->28494 ... k=7->24273  (Q15, 32768/edge_M).
If we bake ONE constant (the k=2 value, 29789) but the user dials a different k,
the output edge maps slightly inside/outside the source edge:
   - k>2: ideal fill < baked  -> we UNDER-zoom -> a black CLAMP band at the edges
   - k<2: ideal fill > baked  -> we OVER-zoom  -> we crop a sliver of source
This quantifies that band (in source px and % of half-width) so we can judge whether
the single-constant shortcut is acceptable, or commit to the 8-entry LUT.

The 8-entry LUT (fill indexed by k) has ZERO band by construction -- shown as the
baseline. Run: python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_fill_band.py
"""
import numpy as np

W = 480; cx = W // 2; H = 360; cy = H // 2
SCALE = 2 ** 24
AX2 = round(508 * SCALE / (508 * cx * cx + 498 * cy * cy))
K_LUT = 0.1
DEFAULT_K = 2

# ideal fill per k (Q15) = 32768 / M_eff_corner, M_eff_corner = 1 + K_LUT*(k/2)
def ideal_fill_q15(k):
    return 32768.0 / (1.0 + K_LUT * (k / 2.0))

baked = round(ideal_fill_q15(DEFAULT_K))     # the single constant if we pick option (a)
print(f"AX2={AX2}  K_LUT={K_LUT}  default k={DEFAULT_K}")
print(f"single baked fill (k={DEFAULT_K}) = {baked} Q15  (= 32768/{1+K_LUT*DEFAULT_K/2:.3f})\n")

def edge_error_px(k, fill_q15):
    """With this fill, where does the OUTPUT edge column map in source? Report the
    gap (px) between mapped edge and the true source edge (0 / W-1)."""
    if k == 0:
        return 0.0, 0.0
    dx = np.arange(W) - cx
    idx = np.minimum((AX2 * dx * dx) >> 16, 256)
    m_lut = 1.0 + K_LUT * idx / 256.0
    m_eff = 1.0 + (m_lut - 1.0) * k / 2.0
    sx = cx + dx * (m_eff * (fill_q15 / 32768.0))
    # the rightmost output column maps to sx[-1]; ideal is W-1.
    edge_src = sx[-1]
    gap_px = edge_src - (W - 1)          # >0 => source runs past edge (we CROP); <0 => black BAND
    return gap_px, gap_px / (W / 2) * 100.0

print(f"{'k':>2} {'ideal fill':>10} | SINGLE-CONST (baked {baked})        | 8-ENTRY LUT")
print(f"{'':>2} {'':>10} | {'edge gap px':>11} {'% half-w':>9} {'effect':>8} | {'edge gap':>8}")
for k in range(8):
    ideal = round(ideal_fill_q15(k)) if k else 32768
    g_px, g_pct = edge_error_px(k, baked)
    if abs(g_px) < 0.5:
        eff = "exact"
    elif g_px < 0:
        eff = "BLACK"      # under-zoom -> black band
    else:
        eff = "crop"       # over-zoom -> crop sliver
    # 8-entry LUT uses ideal fill for THIS k -> ~0 gap
    g8_px, _ = edge_error_px(k, ideal) if k else (0.0, 0.0)
    print(f"{k:>2} {ideal:>10} | {g_px:>11.1f} {g_pct:>8.1f}% {eff:>8} | {g8_px:>7.1f}")

print(f"""
READ:
- 'BLACK' rows = a black clamp band of that many source px at each L/R edge (then
  scaled up by ascal). 'crop' = we lose that many source px off each edge.
- The 8-ENTRY LUT column is ~0 at every k -> no band, no crop, ever.
- Single-const is exact only at k={DEFAULT_K}; the band grows with |k-{DEFAULT_K}|.
Decision aid: if the worst-case band (k=7) is small enough to ignore, the single
constant is fine; otherwise the 8-entry LUT earns its tiny cost.
""")
