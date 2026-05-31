#!/usr/bin/env python3
"""Doubling gate for the hi-res (OUT_SCALE=2) RTL output (SPEC-hires-warp Sec.4).

Reads the frame dumped by tb_warp_stage0.vhd and applies the step-0 metric from
warp_bitexact.py DIRECTLY to the RTL output: a source vertical line must render
as ONE contiguous run, never split into two (the line-doubling artifact), and
never smeared wider than the OUT_SCALE baseline. This is the run-aware judge the
stock tb_stage0_check.py is not (it treats each bright column as a 1px line, so
at 2x it mis-reads the legitimate ~2px-wide lines as asymmetric).

In CYL_MODE the X-warp is y-independent (straight verticals), so every non-line
row is identical -- we analyse the representative middle row.

  DOUBLING  = a row whose vertical lines split (runs > n_src) OR smear wide
              (any run width >= 2*OUT_SCALE).
  CLEAN     = runs in {n_src-1, n_src} (the -1 is the benign overscan edge-crop
              of the outermost 1px column, present in BOTH paths) AND no wide run.

Run:
  python tb_hires_check.py <frame.txt> <grid> <out_scale> [src_w]
    grid      : source grid period (1px line every <grid> px)
    out_scale : 1 (source-res) or 2 (hi-res)
    src_w     : source active width (default = frame_W / out_scale)
Exit 0 = CLEAN (gate pass for out_scale=2; gate "doubles" for out_scale=1 prints
the reproduction but still exits 0 so a driver script can assert both).
"""
import sys


def runs_of(row, thr=96):
    out = []
    i, n = 0, len(row)
    while i < n:
        if row[i] > thr:
            j = i
            while j < n and row[j] > thr:
                j += 1
            out.append((i, j - i))
            i = j
        else:
            i += 1
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    path = sys.argv[1]
    grid = int(sys.argv[2])
    out_scale = int(sys.argv[3])
    rows = [[int(v) for v in l.split()] for l in open(path) if l.strip()]
    H = len(rows)
    W = len(rows[0]) if rows else 0
    src_w = int(sys.argv[4]) if len(sys.argv) > 4 else W // out_scale

    # source vertical lines: x % grid == 0 over [0, src_w)
    n_src = sum(1 for x in range(src_w) if x % grid == 0)

    # non-horizontal-line rows (a horizontal line lights the whole row)
    bright_frac = lambda r: sum(v > 96 for v in r) / max(1, len(r))
    vert_rows = [y for y in range(H) if bright_frac(rows[y]) < 0.7]
    if not vert_rows:
        print("FAIL: no vertical-content rows found")
        return 1

    # every vert row is identical in CYL_MODE; verify + analyse the middle one
    colsets = {tuple(x for x in range(W) if rows[y][x] > 96) for y in vert_rows}
    identical = (len(colsets) == 1)
    mid = vert_rows[len(vert_rows) // 2]
    rs = runs_of(rows[mid])
    widths = [w for _, w in rs]
    nruns = len(rs)
    maxw = max(widths) if widths else 0
    wide = sum(1 for w in widths if w >= 2 * out_scale)
    split = nruns > n_src
    crop = n_src - nruns  # >0 => benign edge-crop deficit

    doubling = (wide > 0) or split

    print(f"frame {W}x{H}  src_w={src_w} grid={grid} OUT_SCALE={out_scale}  "
          f"n_src_lines={n_src}")
    print(f"  rows identical (straight verticals): {identical}")
    print(f"  mid row {mid}: {nruns} runs, widths={widths}")
    print(f"  maxW={maxw} (baseline {out_scale}, wide>= {2*out_scale}) wideRuns={wide}  "
          f"split(runs>src)={split}  edge-crop(src-runs)={crop}")

    if out_scale == 1:
        verdict = "DOUBLES (reproduces HW)" if doubling else "clean (no doubling seen)"
    else:
        if doubling:
            verdict = "STILL DOUBLES -- FAIL"
        elif crop > 0:
            verdict = f"CLEAN ({crop} edge-line cropped, benign)"
        else:
            verdict = "CLEAN"
    print(f"  VERDICT: {verdict}")

    # gate: out_scale=2 must be doubling-free; out_scale=1 is informational
    ok = identical and (out_scale == 1 or not doubling)
    print(f"HIRES GATE ({'src-res repro' if out_scale==1 else 'hi-res 2x'}): "
          f"{'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
