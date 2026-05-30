# HANDOFF — vis_warp cylindrical warp + Block A (2026-05-29)

**Resume point for a fresh instance.** Read this first, then
`SPEC-cylindrical-warp.md` (design + status) and
`RESEARCH-warp-quality-2026-05-29.md` (the architecture decision record).

---

## Where things are
- **Project:** vis_warp — a framework CRT screen-curvature video processor for
  MiSTer FPGA. Cyclone V / DE10-nano, Quartus 17.0.2 Lite. Repo:
  `D:\deck\fpga\Template_MiSTer-VIS\`.
- **Branch:** `feature/cylindrical-warp-blockA`, HEAD ~`df3b806`, pushed to remote
  `github` (= `derpyder/misterfpga_vis_warp`). **Main is UNTOUCHED** (still the
  shipped radial engine). Nothing merged; no consumer core affected.

## What's DONE — Block A (cylinder warp), "good enough" on the Template
mycore (480×360) renders a clean cylinder: straight verticals, flat rows, fills.
- **Separable cylinder:** X warps on **x²-only** (`s9x` magnitude → straight
  verticals, no oval); Y blends identity↔bow by `curvature_v` (kv=0 ⇒ src_y=out_y
  = flat rows). Engine: `sys/vis_warp_v2_wp.vhd`.
- **`curvature_v` (kv) runtime V-bow dial:** cmd 0x45 **op001 bits[5:3]**; kv=0
  cylinder → kv=7 ~radial. Wrapper `sys/vis_warp.vhd` (decode @ OP_CURVATURE + CDC).
- **Horizontal fill** at stage 9x: `OVERSCAN_X_Q15 = 27458` (=32768/1.193) → output
  edge maps to source edge, kills the clamp band.
- **De-saturated weights** `LUT_AX2_Q24=188 / LUT_AY2_Q24=184` (`sys/vis_warp_luts_pkg.vhd`)
  — calibrated for 480×360.
- **Validated** via the gradient test pattern: pipeline is CLEAN; the 1px-grid
  "clusters/gaps at edges" were **minification aliasing of the worst-case pattern**,
  NOT a bug. Smooth/real content renders clean.

Commit chain on the branch: `f978d4d` (v1 X-barrel+kv) → `b2ea50d` (fill) →
`94f3483` (de-sat) → `59dea05` (faithful 2D model) → `9f306da` (STATUS) →
`f3627f0` (research doc) → `a6016d1` (prototype) → `df3b806` (shader finding).

## ⚠️ THE GATING CAVEAT — CLEARED IN SIM (2026-05-30)
Weights (188/184) + fill (27458) were **HARDCODED for 480×360**. The weights are
now **res-adaptive** (`sys/vis_warp_rescal.vhd` divider, GHDL-validated against
all 4 golden resolutions); the fill stays fixed (edge_M is aspect-constant).
**Remaining gate: a Quartus compile + a hardware check on a NON-480×360 core**
(e.g. Robotron 292×240) before main-merge / consumer shipping.

---

## DONE (2026-05-30) — res-adaptive calibration RTL (the gate), sim-validated
**What landed** (branch `feature/cylindrical-warp-blockA`, GHDL analyze+elaborate
clean, `sim/tb_rescal.vhd` → "ALL GOLDENS PASS"):
- `sys/vis_warp_rescal.vhd` — frame-rare sequential restoring divider. Computes
  `AX2=round(508·2²⁴/D)`, `AY2=round(498·2²⁴/D)`, `D=508·cx²+498·cy²`,
  cx=src_w/2, cy=src_h/2. Two quotients divide in parallel (shared denom +
  counter). Numerators built by `shift_left` (34-bit, never an int literal).
  Rounds via `+D/2`. Defaults to 508/498 (288×224) before the first compute.
- `sys/vis_warp_v2_wp.vhd` — added `reg_ax2_u`/`reg_ay2_u` signals, an ungated
  change-detect process (`src_w_latched`/`src_h_latched` changed → 1-cycle
  `rescal_start`), the `u_rescal` instance, and stage 3 now multiplies by
  `signed('0' & reg_ax2_u)` / `signed('0' & reg_ay2_u)` instead of the
  `LUT_AX2_Q24`/`LUT_AY2_Q24` constants. `s4_x2only`(=AX2·dx²) / `s4_r2`
  (=AX2·dx²+AY2·dy²) unchanged downstream.
- `sys/vis_warp_luts_pkg.vhd` — 188/184 marked SUPERSEDED (engine no longer
  reads them; base 508/498 live as `BASE_AX/BASE_AY` generics in the divider).
- `sys/sys.qip` — added `vis_warp_rescal.vhd` to the Quartus build.
- Goldens verified: 288×224→508/498, 480×360→188/184, 640×480→106/104,
  320×240→422/414. The fill constant 27458 was intentionally NOT touched.
- **NEXT FOR THIS: USER runs the Quartus compile + HW-checks a non-480×360 core.**
  (Sim is the gate this side; hardware is the user's.)

### How it was derived (kept for the record)
Make the weights compute per-frame from the detected source dims.
- **Math (VALIDATED in `sim/warp_prototype.py`):**
  `AX2_eff = 508·2²⁴ / (508·cx² + 498·cy²)`, `AY2_eff = 498·2²⁴ / (same denom)`,
  cx=src_w/2, cy=src_h/2. **Golden values to verify against:** 288×224→AX2≈508,
  480×360→≈188, 640×480→≈106, 320×240→≈422. `clamp=0` (fills) at all.
- **KEY SIMPLIFICATION:** `edge_M` is **aspect-constant (~1.19 for 4:3)** regardless
  of resolution ⇒ **the fill constant 27458 STAYS** as-is; only the WEIGHTS need
  res-adapting.
- **Detection hook (already located):** `src_w_latched`/`src_h_latched` (signals,
  defaults 288/224) are latched on `vs_in` rising from `det_x_max`/`det_y_in_frame`
  — `vis_warp_v2_wp.vhd` lines ~512–545. The weights are consumed at **stage 3
  (~line 713–714):** `s3_ax2dx2 <= to_signed(LUT_AX2_Q24,11) * s2_dx2` — replace the
  CONSTANT with a per-frame SIGNAL `reg_ax2`/`reg_ay2`.
- **Implementation note (the gotcha):** numerator `508·2²⁴ ≈ 8.5e9` = 34-bit →
  build via `shift_left(to_unsigned(508,...),24)`, NOT an integer literal (overflows
  32-bit). denom ≤ ~66M (27-bit), result ~10-bit. A single-cycle combinational divide
  of that width WON'T meet timing → use a **sequential multi-cycle divider FSM**
  triggered on src-dim change (frame-rare → latency irrelevant), or a reciprocal LUT.
- **DISCIPLINE:** verify the divider in a FOCUSED GHDL testbench (drive the 4 test
  resolutions, assert ax2/ay2 == golden values) BEFORE integrating into stage 3.
  Then GHDL-analyze the full engine. (User runs the Quartus compile to validate.)

## IMMEDIATE NEXT TASK — minification prefilter (quality fix) — validated in sim, NOT implemented
- **Decided approach** (RESEARCH doc, all 4 agents converge): a **Jacobian-gated,
  separable, variable-width running-box** prefilter in the X path, active only where
  local minification J>1, feeding the existing bilinear. ~few M9K, ~0 DSP. Cheap tier
  = crt-geom's 3× beam-oversample; rigorous = CRT-Royale's analytic-Jacobian N-tap
  (= our box). **Compute the footprint ANALYTICALLY from the closed-form warp Jacobian
  (we already compute it) — NOT GPU `ddx/ddy`.**
- **Validated in `sim/warp_prototype.py`** (turns aliased compressed edges → clean
  smooth tone; gated so the magnified center stays sharp-bilinear).
- It's **mandatory for quality** (source-res is the crt-lottes aliasing case;
  output-res warp is infeasible on Cyclone V — see RESEARCH doc Decision 1).

## Follow-ups after that (priority order)
Stage 2 reclaim (compile-time buffer collapse, ~180 M10K — `SPEC-cylindrical-warp.md`)
→ true independent H/V magnitudes (separate M_x/M_y) → pincushion (signed kh/kv) →
H/V overscan → Block B (vignette riding on r², corner rounding).

---

## Tooling that works (USE IT)
- **GHDL 6.0.0** at `/c/Users/mattl/bin/ghdl/bin/ghdl.exe`. Analyze+elaborate (both
  clean at HEAD):
  ```
  GH=/c/Users/mattl/bin/ghdl/bin/ghdl.exe
  WD=/d/deck/fpga/Template_MiSTer-VIS/sim/ghdl_work ; S=/d/deck/fpga/Template_MiSTer-VIS/sys
  "$GH" -a --std=08 --workdir="$WD" "$S/vis_warp_pkg_v2.vhd" "$S/vis_warp_luts_pkg.vhd" "$S/vis_warp_v2_wp.vhd" "$S/vis_warp.vhd"
  "$GH" -e --std=08 --workdir="$WD" vis_warp
  ```
- **Python sim — run with ABSOLUTE path** (Bash cwd resets between calls):
  `python D:/deck/fpga/Template_MiSTer-VIS/sim/<x>.py`. Scripts:
  `warp_model.py` (geometry + look family), `warp_compare.py` (oval-vs-fix),
  `warp_fill_1d.py` (fill math), `warp_faithful_2d.py` (faithful LUT+bilinear —
  reproduces hardware aliasing; the rig for the prefilter), `warp_prototype.py`
  (res-adaptive + prefilter, both validated). Renders → `sim/warp_out/` (gitignored).
- **Engine math facts:** `WARP_LUT M = 1 + 0.3·idx/256`; K-scale `M_eff = 1 +
  (M-1)·K/2` (K=2 ⇒ M_eff=M); LUT indexed by `(AX2·dx²+AY2·dy²)>>16`, saturates at
  idx 255. `M_scaled` Q15: 32768 = identity (src=out).
- **Workflow rules:** USER runs Quartus full compiles (visibility); Claude runs GHDL
  + Python only. User drops hardware screenshots as `output_files/NNNN.jpg` (read
  them). Sim-FIRST: model/validate before RTL; do NOT pile unvalidated changes on the
  engine (v3.3 sync-delay postmortem is the cautionary tale). Commit/push only what's
  asked; footer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Other live threads (parked, this session)
- **robotron-v0.2 SHIPPED** (K=4 sharp-bilinear): `derpyder/Arcade-Robotron_MiSTer-VIS`,
  GitHub release `robotron-v0.2`. (Different repo.)
- **ESB bloom** spec written + committed: `derpyder/Arcade-StarWars_ESB_MiSTer`,
  `docs/SPEC-bloom-esb.md` (additive accumulation, NOT the BW Gaussian; see
  `project_starwars_vis.md` memory). Separate project.
