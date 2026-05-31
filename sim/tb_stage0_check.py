#!/usr/bin/env python3
"""Golden checker for tb_warp_stage0 (SPEC-cylindrical §5 Stage 0).

Reads the frame dumped by tb_warp_stage0.vhd and ASSERTS the cylinder
invariants (pass/fail, like fb_metric.py — the quantitative judge, not eyeball):

  1. src_y == out_y (kv=0): the horizontal grid lines (input rows where
     y % GRID == 0) render as fully-bright output rows at the SAME rows, and
     nowhere else. This is THE precondition for the Stage-2 buffer reclaim.
  2. Straight verticals: every non-line row has the identical set of bright
     columns (a cylinder warps X only -> verticals stay vertical).
  3. Warp active + symmetric: the vertical grid lines are repositioned by the
     X-warp and their positions are mirror-symmetric about the center.

Run (after the TB writes warp_out/tb_stage0_frame.txt):
  python D:/deck/fpga/Template_MiSTer-VIS/sim/tb_stage0_check.py
Exit 0 = all gates pass.
"""
import os
import sys

GRID = 8
HERE = os.path.dirname(os.path.abspath(__file__))
FRAME = os.path.join(HERE, "warp_out", "tb_stage0_frame.txt")


def load(path):
    with open(path) as fh:
        return [[int(v) for v in line.split()] for line in fh if line.strip()]


def main():
    if not os.path.exists(FRAME):
        print(f"FAIL: {FRAME} not found (run tb_warp_stage0 first)")
        return 1
    rows = load(FRAME)
    H = len(rows)
    W = len(rows[0]) if rows else 0
    bright = lambda v: v > 96

    # 1) src_y == out_y
    hrows = [y for y in range(H) if sum(bright(v) for v in rows[y]) > 0.7 * W]
    expect = [y for y in range(H) if y % GRID == 0]
    ok_sy = (hrows == expect)

    # 2) straight verticals (non-line, non-edge rows have one identical col set)
    nonline = [y for y in range(1, H - 1) if y % GRID != 0]
    colsets = {tuple(x for x in range(W) if bright(rows[y][x])) for y in nonline}
    ok_straight = (len(colsets) == 1)

    # 3) warp active + symmetric about center
    mid = nonline[len(nonline) // 2]
    vcols = [x for x in range(W) if bright(rows[mid][x])]
    c = W / 2.0
    dl = sorted(c - x for x in vcols if x < c)
    dr = sorted(x - c for x in vcols if x >= c)
    ok_sym = (len(dl) == len(dr) and len(dl) > 0
              and all(abs(a - b) <= 1.5 for a, b in zip(dl, dr)))
    # "active" = output spacing is non-uniform vs the uniform GRID source spacing
    gaps = [vcols[i + 1] - vcols[i] for i in range(len(vcols) - 1)]
    ok_active = (len(set(gaps)) > 1)

    print(f"frame {W}x{H}")
    print(f"  [{'PASS' if ok_sy else 'FAIL'}] src_y==out_y : horizontal lines on rows "
          f"{hrows} (expect {expect})")
    print(f"  [{'PASS' if ok_straight else 'FAIL'}] straight verticals : "
          f"{len(colsets)} distinct col-set(s) across {len(nonline)} rows (expect 1)")
    print(f"  [{'PASS' if ok_sym else 'FAIL'}] warp symmetric : L-dist {[round(d,1) for d in dl]} "
          f"vs R-dist {[round(d,1) for d in dr]}")
    print(f"  [{'PASS' if ok_active else 'FAIL'}] warp active : output line gaps {gaps} (non-uniform)")

    gate = ok_sy and ok_straight and ok_sym and ok_active
    print(f"\nSTAGE-0 GATE: {'PASS' if gate else 'FAIL'}")
    return 0 if gate else 1


if __name__ == "__main__":
    sys.exit(main())
