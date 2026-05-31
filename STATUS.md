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
- **The fix is specced and sim-proven, not built:** warp at 2× internal
  resolution and output at 2×, letting ascal downscale (crt-royale's method).
  Affordable **only because** the cylindrical Stage-2 buffer reclaim frees the
  M9K — so hi-res warp and the reclaim are now **one coupled effort**.

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
  → 30/30 source lines stay one solid run. 2× is enough.

Full proof + ruled-out table: [`SPEC-hires-warp-2026-05-30.md`](./SPEC-hires-warp-2026-05-30.md).

---

## The plan (sim-first, then ONE hardware build)

Hi-res warp and the Stage-2 reclaim are coupled: the 2×-wide line buffer is only
affordable because the cylinder's `src_y=out_y` (kv=0) collapses the 128-line
buffer to a 2-line ping-pong, freeing ~180 M9K. Build order
([`SPEC-hires-warp`](./SPEC-hires-warp-2026-05-30.md) §4 +
[`SPEC-cylindrical-warp`](./SPEC-cylindrical-warp.md) §5):

0. **Extend `sim/warp_bitexact.py`** to the full 2× output path at Robotron's
   actual 296 width; confirm `runs==src`, `wide==0`. *(Next concrete action.)*
1. `MAX_SRC_W` 512→1024 + 2× write-doubling + 2× output, **keeping** the 128-line
   buffer → validates the look at known buffer cost. **This is the gate:** grid
   clean, no doubling on HW.
2. **Stage-2 reclaim** (128→2 line, kv=0) → recover the M9K the 2× width spent.
3. Re-introduce kv>0 within the buffer budget, **or** document hi-res as
   cylinder-only (kv=0).

**Open questions to resolve in sim before RTL:** kv≠0 breaks the 2-line reclaim
(vertical bow needs lookahead again); 2× throughput at clk_video; the sim must
model the 2× output path end-to-end at 296 width. See `SPEC-hires-warp` §3.

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
