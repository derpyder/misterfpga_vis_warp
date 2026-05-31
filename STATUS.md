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
- **There is one open quality blocker: line-doubling.** A source-resolution sharp
  warp of 1-pixel content (grid lines, text) renders single rows as two — a
  Nyquist wall, **proven bit-exact**, not a tuning bug. So no current build is
  shippable as a polished release yet.
- **The fix — hi-res 2× warp — is in progress (sim-first).** Warp at 2× internal
  res and output at 2×, ascal downscales (crt-royale's method). Affordable because
  the cylindrical Stage-2 buffer reclaim freed the M9K, so the two are one effort.
  **Done in sim:** the reclaim (pixel buffer ~165 → ~3 M9K, GATE PASS, spherical
  byte-identical) + the hi-res design + the TB foundation. **Not built:** the
  engine 2× output path.
- **▶ RESUME HERE (next instance):** implement the engine hi-res `OUT_SCALE=2` path
  — see [The plan → Stage 3](#the-plan-sim-first-then-one-hardware-build) (design
  locked: read-double + a 2× `ce_pix_out`; the GHDL rig `sim/tb_warp_stage0.vhd`
  with `-gCE_DIV=2` gates it). All work is on `main` = `feature` @ `4586d22`,
  pushed. USER's parallel gate: a Quartus build of the cyl reclaim (expect RAM
  ~105–125/553) to confirm the M9K win on silicon.

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
  → 30/30 source lines stay one solid run. 2× is enough. **Re-confirmed at
  Robotron's actual 296 width (step 0 below): src-res doubles, hi-res 2× is
  doubling-free.**

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
1. **(NEXT)** `MAX_SRC_W` 512→1024 + 2× write-doubling + 2× output, **keeping**
   the 128-line buffer → validates the look at known buffer cost. **This is the
   gate:** grid clean, no doubling on HW.
2. **Stage-2 reclaim** (128→2 line, kv=0) → recover the M9K the 2× width spent.
3. Re-introduce kv>0 within the buffer budget, **or** document hi-res as
   cylinder-only (kv=0).

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
- **Stage 3 (hi-res 2× width) — design locked; TB foundation laid; engine next.**
  Kills the remaining *horizontal* 1px doubling (cyl already killed the vertical),
  on the cyl passthrough. **Read-double mechanism** (cheaper than the SPEC's
  write-double): keep the W-wide buffer; the output raster becomes 2W; output col
  `ox∈[0,2W)` warps in 2W space and reads `buffer[src_x/2]` (LSB → bilinear frac) =
  NN-upscale-then-warp (warp_bitexact-proven) without enlarging the buffer.
  **Output-ce is the crux:** ascal samples on `ce_pix_out`, today tied to `ce_pix_in`
  (`vis_warp.vhd:286`); hi-res needs it = a **2× ce** (`ce_pix_dly OR +1clk`; needs
  ≥2× clk headroom — true for arcade cores). Engine gains: an `OUT_SCALE` generic, a
  `ce_pix_out` port, a 0..2W cursor, src_x in 2W space, the read-double, regenerated
  de/hs, AX2 fed the 2× width. Wrapper wires `ce_pix_out` from the engine.
  **Done (committed):** the Stage-0 TB is `CE_DIV`-parameterized — `CE_DIV=1`
  reproduces 712/720; `CE_DIV≥2` is the headroom hi-res needs. **Next:** the engine
  `OUT_SCALE=2` path + extend the TB (`CE_DIV=2`, capture 2W on `ce_pix_out`, gate
  runs==src at Robotron's 296).

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
