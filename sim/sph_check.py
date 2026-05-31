#!/usr/bin/env python3
"""Dual-axis doubling check for the SPHERICAL hi-res experiment (N_LINES=128,
OUT_SCALE=2, kv>0). The 2x-WIDTH read-double fixes VERTICAL-line (horizontal-
magnification) doubling; this also measures HORIZONTAL-line (vertical-
magnification) doubling, which 2x width canNOT fix (would need 2x height).

  VERT lines:  a mid dark-row's bright col-runs. clean@2x: width ~2, none >= 4.
  HORIZ lines: an emptiest near-center col's bright ROW-runs. height NOT doubled
               (1x tall), so clean = height 1; height >= 2 = vertical doubling.

Run: python sph_check.py <frame.txt> [grid]
"""
import sys
import numpy as np


def runs1d(a, thr=96):
    seg, i, n = [], 0, len(a)
    while i < n:
        if a[i] > thr:
            j = i
            while j < n and a[j] > thr:
                j += 1
            seg.append(j - i)
            i = j
        else:
            i += 1
    return seg


def main():
    A = np.array([[int(v) for v in l.split()] for l in open(sys.argv[1])])
    H, W = A.shape
    # vertical-line doubling (horizontal axis) -- representative dark row
    nonh = [y for y in range(1, H - 1) if (A[y] > 96).sum() < 0.6 * W]
    vw = runs1d(A[nonh[len(nonh) // 2]])
    vwide = sum(1 for w in vw if w >= 4)
    # horizontal-line doubling (vertical axis) -- emptiest near-center column
    cc = range(W // 2 - 40, W // 2 + 40)
    gapx = min(cc, key=lambda x: (A[:, x] > 96).sum())
    hr = runs1d(A[:, gapx])
    htall = sum(1 for h in hr if h >= 2)
    hmax = max(hr) if hr else 0
    print(f"  VERT(2xW): {len(vw)} runs maxW={max(vw)} wide>=4={vwide}"
          f"   |  HORIZ: {len(hr)} runs maxH={hmax} tall>=2={htall}"
          f"   -> {'CLEAN both axes' if (vwide==0 and htall==0) else 'H-line doubling' if htall else 'V-line doubling'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
