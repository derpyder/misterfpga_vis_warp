# STATUS — vis_warp (single source of truth)

**Last updated:** 2026-05-30. **Read this first.** This file replaces the
rolling `HANDOFF-*.md` docs — it is the one place that says where the project
actually is, what works, what's broken, and what to do next. When it conflicts
with any other doc, this one wins (then fix the other doc).

---

## TL;DR

vis_warp is a framework-level CRT screen-curvature video processor for MiSTer
(DE10-nano / Cyclone V, Quartus 17.0.2 Lite). It warps a core's video
**upstream of the scaler** so the OSD stays straight and the bow scales with any
HDMI mode.

- **It runs on hardware.** Barrel warp validated on the Template grid and on
  Robotron; the cylindrical engine's res-adaptive calibration is HW-proven.
- **The line-doubling blocker is FIXED — confirmed on hardware (2026-05-31).** A
  source-res sharp warp of 1px content (grid lines, text) used to render single rows
  as two (a Nyquist wall, proven bit-exact). The hi-res 2× build renders the OSD
  vertical-bar pattern **crisp on the cab** — doubling gone. Critically, that also
  proves **ascal cleanly accepts the 2× `ce_hpix` + the 960-wide raster**, which was
  the one untested integration risk. **The blocker that gated a polished release is
  cleared.**
- **The fix — hi-res 2× warp — DONE (sim-gated + hardware-validated).** Warp at 2×
  internal res and output at 2×, ascal downscales (crt-royale's method). Affordable
  because the cylindrical Stage-2 buffer reclaim freed the M9K, so the two are one
  effort. The reclaim (~165 → ~3 M9K, byte-identical) **+ the engine `OUT_SCALE=2`
  read-double path** — GHDL doubling-free at the Template's 480×360 AND Robotron's 296,
  grid 16 **and** 8, sharpness 2 **and** 4; RTL == bit-exact model to the pixel. OS=1
  byte-identical (712/720). **Three real RTL bugs were found + fixed** (read-double
  bank-collapse, a latent bank-read parity/fraction skew, a startup cursor overflow —
  see [Stage 3](#the-plan-sim-first-then-one-hardware-build)). **Still to confirm:**
  the cyl reclaim's RAM win on the fitter report (~105–125/553 vs spherical ~284).
- **▶ RESUME HERE (next instance):** the hi-res fix is **hardware-validated on the
  Template** (`MISTER_WARP_CYL=1`, enabled in `Template.qsf`). The blocker is cleared,
  so the roadmap unblocks. Next moves, in order: (1) **`main` should become the
  cyl+hi-res engine** — the merge-feature→`main` decision STATUS deliberately deferred
  is now ripe (hi-res is the proven path). (2) **Robotron-VIS is synced + engine-gated
  and ready to build** (`fpga/robotron-vis`, `MISTER_WARP_CYL=1` on; the 2× CE is wired
  through its `scanlines`→ascal path — one extra integration vs the Template, but the
  shared ascal-2×-CE risk is now retired). NOTE: that build is **cylinder-only / kv=0**
  — Robotron's old kv=2 vertical bow is gone (flat rows; the reclaim can't do V-bow).
  (3) confirm the fitter RAM win. (4) then the real roadmap: **v4 Main_MiSTer userland**
  (OSD control), distribution. Gate to re-run after any engine change: `sim/tb_warp_stage0.vhd`
  `-gDUT_N_LINES=2 -gOUT_SCALE=2 -gCE_DIV=2 -gW_ACT_G=480 -gH_ACT_G=360` + `sim/tb_hires_check.py`.

---

## Architecture — two engines

| | **Spherical** (original) | **Cylindrical** (new direction) |
|---|---|---|
| Curve | radial r² both axes | x²-only (curved L↔R, flat T↔B; Trinitron/PVM) |
| Selected by | default (`MISTER_WARP`) | compile-time `MISTER_WARP_CYL` macro |
| `src_y` | displaced (vertical bow) | `= out_y` at kv=0 → flat rows, straight verticals |
| Buffer | 128-line M9K sliding window (~185 M9K) | collapses to a 2-line ping-pong (Stage-2 reclaim, ~5 M9K) |
| Max source width | ≤512 px (M9K-bound) | **any width** (2-line floor is height-independent) |
| Status | shipped to Robotron; **doubles 1px content on HW** | Block A "good enough" on Template; res-adaptive HW-validated |

The whole pipeline: `emu → arcade_video → vis_warp (SITE C, pre-ascal,
source-res, clk_video) → ascal → shadowmask → osd → HDMI`. Locked architectural
decisions: [`SPEC-vis_warp-v3.md`](./SPEC-vis_warp-v3.md) +
`~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md`.

---

## What works (HW-validated)

- SITE C framework integration; `MISTER_WARP` macro gate (unset = upstream-
  identical, bit-exact, no overhead).
- Barrel warp at k=0 / k=2 / k=7 on the Template grid, OSD stays straight,
  shadowmask + scanlines stack correctly downstream.
- Self-tuning sync-delay → symmetric top-to-bottom barrel (Robotron, on HW).
- Sharp-bilinear (`reg_sharpness` runtime register) — crisp pixels, smooth curve.
- **Cylindrical Block A** (straight verticals, flat rows, edge-to-edge fill) and
  **res-adaptive calibration** (`sys/vis_warp_rescal.vhd`): the cylinder stays
  identically curved + full-frame across resolutions, HW-proven on Template via a
  320×240 ↔ 480×360 OSD toggle. GHDL goldens pass; Quartus clean (RAM 284/553,
  zero added; setup +0.486 ns).

## The open blocker — line-doubling

A full-screen barrel warp must **magnify the center** (~16% at k=2) so the bowed
edges don't pull black into the corners. Sharp-bilinear point-sampling that
**non-integer magnification** of a **1-pixel feature** lands it in one output
column for some lines and two for others → doubled/split rows. Smooth (≥2px)
content survives; that's why the grid torture pattern exposes it and gradients
don't.

- **Authoritative model:** [`sim/warp_bitexact.py`](./sim/warp_bitexact.py) — a
  bit-faithful model of the Q15 datapath that **reproduces the hardware
  doubling**. The float models do *not* reproduce it and are not trusted for this
  artifact.
- **Ruled out (all measured, all fail — don't retry):** `fill=1` / no overscan;
  softer LUT; prescale-2×-then-decimate-back-to-480; any LUT/fill/sharpness combo
  at source resolution. It's the resample, not the params.
- **Proven fix:** TRUE hi-res 2× (warp AND output at 2× width, ascal downscales)
  → 30/30 source lines stay one solid run. 2× is enough. Re-confirmed at Robotron's
  actual 296 width: src-res doubles, hi-res 2× is doubling-free. **Now implemented in
  the RTL (`OUT_SCALE=2`) and GHDL-gated clean** — no longer just a model result. The
  remaining gate to a shippable release is the ONE hardware build (display-path +
  cab confirm).

Full proof + ruled-out table: [`SPEC-hires-warp-2026-05-30.md`](./SPEC-hires-warp-2026-05-30.md).

---

## The plan (sim-first, then ONE hardware build)

Hi-res warp and the Stage-2 reclaim are coupled: the 2×-wide line buffer is only
affordable because the cylinder's `src_y=out_y` (kv=0) collapses the 128-line
buffer to a 2-line ping-pong, freeing ~180 M9K. Build order
([`SPEC-hires-warp`](./SPEC-hires-warp-2026-05-30.md) §4 +
[`SPEC-cylindrical-warp`](./SPEC-cylindrical-warp.md) §5):

0. **Extend `sim/warp_bitexact.py`** to the full 2× output path at Robotron's
   actual 296 width. ✅ **DONE 2026-05-30** — src-res doubles (wide runs,
   reproduces HW); hi-res 2× is doubling-free (`wide==0`) at 296 on a 1px torture
   grid. Finding: the overscan fill crops the outermost ~1.4 src-px (the x=0
   line) — a benign 1-line edge deficit in *both* paths, **not** doubling. (So the
   real gate is "no wide/split runs", not the stricter `runs==src`.)
1. **2× output path** → validates the look fix. ✅ **DONE in sim** — but via the
   **READ-double** (`OUT_SCALE=2`, buffer stays W-wide; src_x in 2W space, the bank
   read halves it) on the **cyl passthrough**, *not* the write-double/`MAX_SRC_W→1024`
   originally sketched here. The reclaim-first sequencing (below) made the read-double
   the cheaper, lower-risk path. GHDL gate clean at 296. **HW confirm still pending.**
2. **Stage-2 reclaim** (128→2 line, kv=0) → recover the M9K. ✅ **DONE in sim**
   (done *before* the 2× width, per the reclaim-first decision below).
3. Re-introduce kv>0 (the vertical bow). **Two ways, both sim-proven (2026-05-31):**
   - **Cyl (kv=0):** fully crisp both axes, but flat rows (no curve) + the M9K reclaim.
     This is what's hardware-validated + shipped on Robotron `main`.
   - **Spherical hi-res (`N_LINES=128`, `OUT_SCALE=2`, kv>0):** the rows BOW (curve)
     **and** stay crisp at gentle kv. The 2×-WIDTH read-double is a HORIZONTAL fix only
     (vertical lines crisp at any kv); the bow's vertical magnification doubles
     HORIZONTAL lines, which 2× width can't fix — but the residual scales with kv and is
     negligible in the usable range. Dual-axis sweep (`sim/sph_check.py`, 296×240 grid16,
     N=128 OS=2): **kv 0–1 = perfectly crisp; kv 2–4 = ONE 2–3px horizontal line on the
     whole frame; kv 7 = 4px.** So a gentle bow (kv≈2, Robotron's old default) is
     bow+crisp. Cost vs cyl: no M9K reclaim (full 128-line buffer, ~same M9K as the old
     spherical Robotron) + it re-engages the 64-line sync FIFO (the v3.3-postmortem
     fragile zone) — sim-clean, but a hardware build is the gate. Full crisp at HIGH kv
     would need 2× HEIGHT too (a real lift; not done).

**Open questions to resolve in sim before RTL:** kv≠0 breaks the 2-line reclaim
(vertical bow needs lookahead again); 2× throughput at clk_video; the sim must
model the 2× output path end-to-end at 296 width. See `SPEC-hires-warp` §3.

**▸ Sequencing decision (2026-05-30): RECLAIM-FIRST.** Reading the engine showed
"emit at 2× width" means **regenerating the output raster**, which lives in the
self-tuning sync FIFO (`vis_warp_v2_wp.vhd` — output sync = delayed input sync) —
the v3.3-postmortem fragile zone. The cylindrical Stage-2 reclaim *removes* that
FIFO (`src_y=out_y` ⇒ v3.2 passthrough), so doing the **reclaim first** and adding
2× width on the simple passthrough is lower-risk than threading width through the
FIFO. Revised order: **Stage-0 sim → Stage-2 reclaim → hi-res width.**

- **Stage 0 — DONE (GHDL GATE PASS).** `sim/tb_warp_stage0.vhd` + `tb_stage0_check.py`
  drive the real engine with a synthetic grid raster and confirm `src_y==out_y` at
  kv=0 (horizontal lines on exact rows), straight verticals, symmetric warp. The
  reclaim's validation rig is ready — re-run it as the reclaim lands.
- **Stage 2 (reclaim) — DONE in sim (GATE PASS, both modes).** The reclaim is
  mostly a generic: banks are sized `BANK_DEPTH=(N_LINES/2)·(MAX_SRC_W/2)`, so a cyl
  build instantiates `vis_warp_v2_wp` with `N_LINES=2` + a `CYL_MODE` generic.
  Engine changes (spherical byte-identical): `LAG_SHIFT=log2(N_LINES/2)` scales the
  self-tuning lag (was a hardcoded ×64); `det_y_in_frame` range fixed (latent bug,
  was tied to `N_LINES`); `CYL_MODE` generic; and the stage-12 read window pinned to
  the **pixel's own** `side_pipe(15).cnt_y_o`, not the live `cnt_y_o` signal.
  **GHDL `tb_warp_stage0`: spherical (N=128) byte-identical GATE PASS; cyl (N=2)
  GATE PASS** — buffer collapses (~165 → ~3 M9K), `src_y==out_y`, straight
  verticals, symmetric warp, no smear.
  **The smear (now fixed) was alignment, not the buffer:** the clamp used the live
  `cnt_y_o` signal, which ticks to the next line during inter-line blanking while
  that line's last pixels are still in the 16-stage pipeline — pinning their `src_y`
  to the mid-write next (even, bright) line. Using the pixel's own
  `side_pipe(15).cnt_y_o` aligns them. Spherical's ±64 window had hidden it.
  **Next:** USER Quartus build to confirm RAM ~105/553 + timing; then (optional)
  shrink the 65536-deep sync FIFO (~20 M9K) for the 1-line lag; then hi-res width.
- **Stage 3 (hi-res 2× width) — DONE in sim (GHDL GATE PASS).** Kills the remaining
  *horizontal* 1px doubling (cyl already killed the vertical), on the cyl passthrough.
  **Read-double mechanism** (cheaper than the SPEC's write-double): keep the W-wide
  buffer; the output raster runs `ox∈[0,2W)`, warps in 2W space, and the bank read
  halves `src_x` back to a source col = NN-upscale-then-warp (warp_bitexact-proven)
  without enlarging the buffer. The 2× emit enable `ce_pix_out_i = ce_pix_dly OR
  +1clk` drives the whole delayed domain (needs ≥2× clk headroom — true for arcade
  cores). Engine gained: an `OUT_SCALE` generic, a `ce_pix_out` port, a 0..2W cursor,
  src_x/center/clamp in 2W space, the read-double, AX2 fed the 2× dims. Wrapper takes
  `WARP_OUT_SCALE`/`WARP_CYL`/`WARP_N_LINES` generics + routes `ce_pix_out`.
  **GATE (`sim/tb_warp_stage0.vhd` + `sim/tb_hires_check.py`):** src-res doubles
  (reproduces HW), hi-res 2× is **clean — no split, no wide** at **both the Template's
  480×360 and Robotron's 296×240**, grid 16 **and** 8, sharpness 2 **and** 4; RTL ==
  bit-exact model to the pixel (1-col latency offset). OS=1 byte-identical (712/720).
  **`sys_top.v` is wired** (`MISTER_WARP_CYL` macro → `WARP_N_LINES=2`/`WARP_OUT_SCALE=2`
  + ascal CE from the engine's 2× `ce_pix_out`); `Template.qsf` has the commented toggle.
  **Two real RTL bugs had to be fixed (both sim-found, neither in the original
  design intent):**
  1. **Read-double bank-collapse.** When `src_x` is even the two h-neighbours
     `floor(src_x/2)`,`floor((src_x+1)/2)` are the SAME source col, but the 4-bank
     fetch always reads two *opposite-parity* banks (p00=floor, p01=floor+1) → it
     mis-reads p01 from the wrong bank. **Fix:** force `fx=0` for even `src_x` (the
     boundary sub-col carries the only real fraction) so the bad p01 gets weight 0 ⇒
     blend = p00 = source[floor], exactly the NN-upscale model. (stage 11, OUT_SCALE>1)
  2. **Latent bank-read parity/fraction skew (pre-existing, masked at OS=1).** The M9K
     read (`s12_addr`→registered `s13_q`) lags the address one clk, so the stage-13
     mux paired each pixel's bank data with the *next* pixel's parity+fraction. At
     OS=1 the smooth fraction hides it (a sub-pixel shift the shift-tolerant gate
     passes); at OS=2 the parity-gated `fx` makes a line split. **Fix:** one-clk-delayed
     `s12d_*` parity/fraction/sync feed the mux, aligned with `s13_q` (gated OUT_SCALE>1
     ⇒ OS=1 untouched). *This was the whole afternoon — caught only by dumping GHDL
     internals after a faithful Python replica of the datapath came out clean but the
     RTL didn't; the value 147 at the split col decoded to the next pixel's `fx`.*
  3. **Cursor overflow on the startup transient (surfaced at 480, bound-check).** Before
     the sync-FIFO's `target_lag` self-measures (first ~1 line it's the 768 default), the
     read window is misaligned and `de_o_gen` can stretch past one line, running the
     0..2W output cursor past its range — fatal at 480's longer lines, survived at 296's.
     **Fix:** saturate the cursor (`if cnt_x_o < OUT_SCALE*MAX_SRC_W`, same in the TB
     capture) — never clips a real pixel (legit max 2·src_w−1), just survives the
     transient. Hardware wraps silently, so it's a sim-strictness + clean-startup fix.

## Parked (still useful, not the path forward)

- **crt-royale mapping** ([`sim/gen_lut.py`](./sim/gen_lut.py),
  [`sim/warp_royale_map.py`](./sim/warp_royale_map.py)) — maps our k/kv dials to
  royale geom params + the soft LUT. Useful for the *look / preset labels* once
  hi-res makes the look clean; **does not fix doubling** (sim-proven).
- **Minification prefilter** — **validated UNNECESSARY** at source-res
  (J_max < 2 px/px is too gentle to alias visibly). The gated running-box is the
  option of record if J≫1 ever happens. See `RESEARCH-warp-quality-2026-05-29.md`.
- **"Proper" sync-delay (the old v3.4)** — two attempts failed on HW
  ([`POSTMORTEM-v3.3-sync-delay`](./POSTMORTEM-v3.3-sync-delay-2026-05-28.md)).
  **Moot in cylindrical mode:** `src_y=out_y` means no delay is needed — Stage-2
  rips the sync FIFO out back to the v3.2 passthrough (removal, not addition).

---

## Branch state

| Branch | HEAD | Has | Tracks |
|---|---|---|---|
| **`feature/cylindrical-warp-blockA`** | `37ac269` | **everything** — Block A RTL, res-adaptive, bit-exact sim, hi-res spec | `github` (derpyder fork) |
| `main` | `bad0ce5` | only the cylindrical spec + Stage-0 model — **behind** the feature branch | `github` |
| `master` | `f35083f` | clean upstream `MiSTer-devel/Template_MiSTer` (mergeability) | `origin` (upstream) |

**The real work is on the feature branch.** Merging it into `main` (and
propagating the cylinder `sys/` into the Robotron-VIS consumer core, which still
carries the old radial v3.3d `sys/`) is a **pending decision for the user** —
intentionally not done automatically, because it changes what `main` (the
"shipped radial engine") represents.

## Discipline (hard-won — do not skip)

- **Sim-first.** Model and validate before touching RTL. The v3.3 sync-delay
  postmortem and the line-doubling discovery both came from skipping this.
- **The bit-exact model is the judge, not eyeballing and not float sims.**
- **USER runs Quartus full compiles + hardware**; Claude runs GHDL + Python sim
  and writes RTL. Hardware screenshots arrive as `output_files/NNNN.jpg`.
- Spherical build stays byte-for-byte untouched by cylindrical work (zero
  regression, `generate`-gated on the macro).

---

## Doc map

| Want | Read |
|---|---|
| Where we are / what's next | **this file** |
| The line-doubling fix (active) | `SPEC-hires-warp-2026-05-30.md` |
| The cylindrical engine + the reclaim | `SPEC-cylindrical-warp.md` |
| Locked architecture / SITE C / HPS 0x45 | `SPEC-vis_warp-v3.md` (foundational ref) |
| The curved-warp quality decision record | `RESEARCH-warp-quality-2026-05-29.md` |
| Why the sync-delay is hard (don't repeat) | `POSTMORTEM-v3.3-sync-delay-2026-05-28.md` |
| Add warp to a core | `ADOPTING-A-CORE.md` |
| Dev workflow / GHDL + sim invocation | `CONTRIBUTING.md` |
| Honest limitations | `LIMITATIONS.md` |
| Next tunable effects | `EFFECTS-BACKLOG.md` |
| Distribution / v4 userland / target cores | `ROADMAP.md` |
| Release history | `CHANGELOG.md` |
| Superseded session handoffs | `docs/archive/` |
