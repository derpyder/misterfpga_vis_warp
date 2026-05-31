> **🎯 ACTIVE FIX — start here for the line-doubling work.** Sim-proven by the
> bit-exact model, **not built**. Coupled with the Stage-2 reclaim in
> [`SPEC-cylindrical-warp.md`](./SPEC-cylindrical-warp.md) §3 (the reclaim is what
> pays for the 2× width). Next concrete step = build-order **step 0** (§4).
> Where things stand: [`STATUS.md`](./STATUS.md).

---

# SPEC — hi-res internal warp (the real fix for line-doubling)

**Status:** spec, sim-proven, NOT built. **Written 2026-05-30.**
**One-liner:** vis_warp must **warp at a higher internal resolution and output at
that resolution**, letting ascal do the final downscale — exactly how crt-royale
avoids aliasing. Source-res sharp warp of 1px content *cannot* render clean at any
bend; this is a Nyquist wall, proven bit-exact, not a tuning bug.

---

## 0. Why (the hardware failure + the proof)

Robotron with the cylinder warp (commit `3f78b61`, k=2) showed **doubled vertical
pixel rows** in the center band — single source lines rendering as two thin lines
with a gap (user hardware photo, 2026-05-30). Text and 1px geometry split.

**Root cause (proven in `sim/warp_bitexact.py`, a bit-faithful model of the actual
Q15 datapath that REPRODUCES the hardware doubling):**
- A full-screen barrel warp must **magnify the center** (~16% at k=2) so the bowed
  edges don't pull black into the corners (the "overscan fill"). 1 source px → ~1.16
  output px.
- Sharp-bilinear (K=4, near-NN) point-sampling that **non-integer magnification** of
  a **1px feature** puts it in 1 output column for some lines, 2 for others → the
  doubling. (Smooth/≥2px content survives; that's why the grid torture pattern
  exposes it and gradients don't.)

**What the bit-exact sim ruled OUT (don't retry these — all measured, all fail):**
| approach | result |
|---|---|
| `fill=1` (no overscan, "identity center") | WORSE (44 runs / 30 lines) — magnitude still ramps off-center → splits |
| softer LUT (K_LUT 0.3→0.1, k=1) | 29/30, 8 wide runs — still beats |
| prescale 2× then **decimate back to 480 in-engine** | still 29/30 — the decimation is itself a non-integer resample of 1px features |
| any (LUT, fill, sharpness) combo at source-res | none clean — it's the resample, not the params |

**What the bit-exact sim PROVED works:**
| approach | runs/src | maxW | wide |
|----------|----------|------|------|
| **TRUE hi-res 2× (warp AND output at 960, ascal scales down)** | **30/30** | 3 | **0** |
| TRUE hi-res 3× (1440) | 30/30 | 4 | 0 |
| TRUE hi-res 4× (1920) | 30/30 | 6 | 0 |

`runs==src, wide==0` ⇒ every source line stays ONE solid run. **2× is enough.** This
is crt-royale's actual method (it warps an already-upscaled image); we do the cheap
integer-NN version on-chip.

## 1. The load-bearing distinction

**Prescale-then-decimate ≠ hi-res output.** Doubling the source, warping, then
sampling back down to 480 inside vis_warp re-introduces the artifact (the downsample
is a fresh non-integer resample). The fix REQUIRES vis_warp's **output raster to be
the high-res one** — ascal (which already scales source→HDMI) absorbs the final
scale for free. So this is a change to vis_warp's *output* dimensions + the buffer,
not just an internal pre-pass.

## 2. What must change (all sim-first, then ONE hardware build)

1. **Internal warp resolution = 2× source width.** MAX_SRC_W 512→1024; warp math
   runs on the 2×-NN-upscaled line. AX2 rescales (cx doubles → AX2/4) — the
   res-adaptive divider already computes AX2 from detected dims, so feeding it the
   2× dims handles this for free.
2. **Output at 2× width.** vis_warp emits 960-wide (Robotron 296→592, etc.); ascal
   downscales to HDMI. Verify ascal accepts the wider live input (it already scales
   arbitrary source widths — low risk, but confirm in sys_top wiring).
3. **Buffer:** the 2× line is 1024 wide. THIS IS WHERE THE STAGE-2 RECLAIM PAYS FOR
   ITSELF: the cylinder's `src_y=out_y` (kv=0) collapses the 128-line buffer to a
   2-line ping-pong (SPEC-cylindrical-warp §3). 2 lines × 1024 × 24b ≈ 6 M9K — so a
   2×-wide buffer is affordable ONLY because the vertical reclaim freed ~180 blocks.
   **Hi-res warp and the Stage-2 reclaim are now coupled: do them together.**
4. **NN upscale on the write side:** each incoming source pixel writes 2 adjacent
   columns in the 1024-wide line buffer (or the reader doubles on read). Integer,
   zero blur.

## 3. The catch / open questions (resolve in sim before RTL)

- **kv≠0 breaks the 2-line reclaim.** The vertical bow needs lookahead lines again.
  At kv=2 (Robotron default) the buffer can't be 2 lines. Options: (a) ship the
  hi-res fix CYLINDER-ONLY (kv=0) where the 2-line buffer holds, accept that the
  spherical/kv>0 modes keep the lower internal res (and some doubling); (b) size the
  buffer for the chosen kv (dial table in SPEC-cylindrical §0) AND 2× width — costs
  more M9K, check the budget. **Sim the M9K for (1024 wide × N lines × 24b) vs the
  reclaim before committing.**
- **Throughput:** 2× output pixels per line at clk_video. Confirm the pixel clock /
  ce budget supports 2× emit (likely fine — clk_video has headroom, ascal buffers).
- **Bit-exact sim must model the 2× output path end-to-end** (write-doubling →
  1024 warp → 960/592 emit) and re-confirm runs==src on Robotron's actual 296 width,
  not just the 480 Template grid.

## 4. Build order (discipline: the v3.3 + this-session lesson — sim reproduces HW first)

0. **Extend `sim/warp_bitexact.py`** to the full 2× output path at Robotron's 296
   width; confirm runs==src, wide==0. (The float model LIED about doubling; only the
   bit-exact model is trusted now.) ✅ **DONE 2026-05-30:** at 296, src-res doubles
   (wide runs) and hi-res 2× is doubling-free (`wide==0`) on a 1px torture grid; a
   480-grid cross-check reproduces the existing 30/30. **Refinement:** the real
   metric is "no wide/split run", not the stricter `runs==src` — the overscan fill
   (27458) crops the outermost ~1.4 src-px, so the `x=0` line drops in *both* paths
   (benign edge-crop, not doubling). Expect the outermost source column cropped when
   validating "grid clean" on HW.
1. MAX_SRC_W→1024 + 2× write-doubling + 2× output, KEEPING the 128-line buffer
   (no reclaim yet) → validates the LOOK fix at known buffer cost. Hardware: grid
   clean, no doubling. **This is the gate.**
2. Stage-2 reclaim (128→2 line, kv=0) → recover the M9K the 2× width spent.
3. Re-introduce kv>0 within the buffer budget (or document cylinder-only hi-res).

## 5. Status of everything else (so this doc is self-contained)
- Res-adaptive calibration: DONE + HW-validated (`vis_warp_rescal.vhd`).
- Prefilter: validated UNNECESSARY (different axis; edge not center).
- Robotron propagation: done/pushed (`3f78b61`) but the baked warp DOUBLES on HW →
  **do not ship/release that build as-is.** Either warp-off default or wait for hi-res.
- crt-royale mapping (kv↔geom_mode, k↔edge-bow) + the soft LUT (K_LUT=0.1) work is
  PARKED — still useful for the *look/labels* once hi-res makes the look clean, but
  it does NOT fix doubling (sim-proven). `sim/gen_lut.py`, `sim/warp_royale_map.py`.

## 6. Tools
- `sim/warp_bitexact.py` — THE authoritative model (bit-faithful, reproduces HW
  doubling; float models do not — do not trust `warp_line_artifact.py` / earlier sims
  for this artifact). GHDL for RTL. USER runs Quartus + hardware.
