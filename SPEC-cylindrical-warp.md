> **🧭 CURRENT ENGINE DIRECTION.** Block A (the cylinder look) is "good enough" on
> Template and the res-adaptive calibration is HW-validated. The **Stage-2 buffer
> reclaim** (§3) is now **coupled** with the hi-res line-doubling fix —
> [`SPEC-hires-warp-2026-05-30.md`](./SPEC-hires-warp-2026-05-30.md) — because the
> reclaim is exactly what makes the 2×-wide hi-res buffer affordable. Build them
> together. Where things stand: [`STATUS.md`](./STATUS.md).

---

# SPEC — Cylindrical warp mode (v2: the structurally-smaller engine)

**Status:** spec, ready to build. **Written:** 2026-05-29.
**One-liner:** a **compile-time** cylindrical build of vis_warp — curved
left-right, flat top-to-bottom (Trinitron/PVM) — that (a) eliminates the
vertical-decimation artifacts that wreck edge text, (b) reclaims ~180 M10K, and
(c) runs on-chip at **any** source width (breaks the hi-res barrier).

This is a sibling mode to today's spherical engine, **not** a replacement.
Spherical stays the ≤512px radial mode; cylindrical becomes the artifact-free,
near-free-RAM, any-resolution mode.

## ✅ STATUS 2026-05-29 — Block A "good enough" on Template

Separable cylinder **validated and accepted** on the Template dev rig (user: "good
enough"). On branch `feature/cylindrical-warp-blockA` (**NOT merged to main**).
Journey: X-barrel (r²→X, looked like a circle) → separable (x²→X, straight
verticals + flat rows) → fill compensation (killed the edge clamp band) →
de-saturated weights (gentler, matched to 480×360). The **gradient** pattern
confirmed it: smooth, no banding/clusters → pipeline is CLEAN; the 1px-grid
"clusters/gaps at the edges" were **minification aliasing of the worst-case
pattern**, NOT a bug. Smooth/real content renders clean.

Branch HEAD has: separable cylinder (`src_x=cx+dx·M(x²)`), `curvature_v` (kv)
runtime V-bow dial (cmd 0x45 op001 bits 5:3; kv=0 cylinder → kv=7 ~radial),
horizontal fill (`OVERSCAN_X_Q15`), de-saturated aspect weights (188/184).

### ✅ The one caveat that gated everything — RES-ADAPTIVE + HW-VALIDATED (2026-05-30)
**The aspect weights were HARDCODED for 480×360.** They are now computed
per-frame by `sys/vis_warp_rescal.vhd` from the detected src_w/src_h
(GHDL-validated against the 288×224 / 480×360 / 640×480 / 320×240 goldens). The
fill (27458) correctly stays FIXED — edge_M is aspect-constant (~1.19), so only
the weights needed adapting. **Quartus clean** (RAM 284/553, zero added; setup
+0.486 ns) and **HW-proven on the Template** via an OSD source-res toggle
(480×360↔320×240): the 320×240 cylinder stays identically curved + full-frame
("its perfect"). **Gate cleared.** Remaining for general use: propagate the
cylinder `sys/` into a consumer core + main-merge decision; then the prefilter.

### Deferred follow-ups (priority order)
1. **Res-adaptive calibration** — ✅ DONE in sim (`vis_warp_rescal.vhd`,
   2026-05-30; GHDL goldens pass). Weights now per-resolution; fill stays fixed.
   Pending the Quartus compile + HW check on a non-480×360 core.
2. **Minification prefilter** (gradient-gated area-average) — optional polish so
   even worst-case 1px content is clean. 4 research agents drafted then paused;
   re-release to pick an architecture (prefilter vs output-res warp vs FPGA LDC prior art).
3. **Stage 2 reclaim** (compile-time buffer collapse, ~180 M10K) — once locked.
4. True independent H/V magnitudes, pincushion (signed), H/V overscan, then
   Block B (vignette, corner rounding).

---

## UPDATE 2026-05-29 — Stage 0 look-locked in sim; design refined

**Stage 0 (model) DONE.** `sim/warp_model.py` (→ `sim/warp_out/warp_sheet.png`)
proves the separable formulation numerically: **kv=0 ⇒ `src_y==out_y` exactly**,
kh=kv=0 ⇒ identity. The reclaim is now **quantified** (max vertical displacement
→ required buffer depth):

| kv (at H=240) | max \|src_y−out_y\| | buffer needed | ≈ blocks reclaimed |
|----|----|----|----|
| 0 | 0 | 2 lines | **~180** |
| 1 | 11 | ~24 | ~150 |
| 2 | 22 | ~46 | ~118 |
| 4 | 43 | ~88 | ~58 |
| 7 | 75 | >128 | 0 |

**New finding — X-BARREL coupling (now the default).** Applying the *radial* r²
magnitude to **X only** (`src_x=cx+dx·M(r²)`, `src_y=out_y`) gives **tube-curved
sides + dead-flat rows + FULL reclaim** (src_y=out_y holds). It's the best-looking
of the flat-row modes (verticals bow like real glass; the pure separable cylinder
only compresses). So Block A ships **two couplings**: `separable` (Mx=f(x²),
My=f(y²)) and `xbarrel` (Mx=f(r²), My=1) — **xbarrel default**. Both keep
`src_y=out_y` at kv=0.

**Curated parameter set (what's in vis_warp, what's not):**
- ✅ **Geometry block (Block A):** H/V curvature (`kh`,`kv`), pincushion (signed
  kh/kv), H/V overscan, coupling mode (separable / xbarrel). One math expansion.
- ✅ **Emitter block (Block B, cheap):** vignette (rides on r²), corner rounding
  (radius→black mask). Output-side multiplies/masks, independent of geometry.
- ✅ **Sharpness:** already shipped (`reg_sharpness`); in flat-row modes it's a
  horizontal-only problem. Gradient-gated refinement later.
- ❌ **Scanlines + shadowmask/gamma/color/scaler:** MiSTer's downstream stack.
  Scanlines especially are *moot* here — a flat-V tube wants MiSTer's flat
  scanlines, which are already correct.

**Block A is RUNTIME (no macro, no buffer change).** The `kh`/`kv`/coupling/
pincushion/overscan all become `cmd 0x45` registers (CDC-synced like
`reg_sharpness`), so you dial the whole look live on hardware with the 128-line
buffer untouched — **zero buffer risk**. The *reclaim* (Stage 2) is the separate
compile-time step: the V-ceiling you settle on sets the buffer depth per the dial
above. All cmd-0x45 register changes fold to constants in a future cyl build.

---

## 0. Why compile-time (load-bearing decision)

The M10K reclaim *requires the buffer to physically shrink* (128 lines → 2). A
**runtime** `cyl` toggle would synthesize **both** buffers → **zero reclaim**.
So cylindrical is a **build variant**, selected by a `MISTER_WARP_CYL` macro
(parallel to `MISTER_WARP`), passed into the engine as a VHDL generic
`CYL_MODE : boolean`. `generate` statements build the small datapath; the
spherical build is byte-for-byte untouched (**zero regression**).

---

## 1. Grounded facts (from the current RTL — verify these line refs before editing)

`sys/vis_warp_v2_wp.vhd`:
- **Radial, one magnitude both axes:** `s4_r2 = AX2·dx² + AY2·dy²` (689-690),
  `M = f(r²)` (693-744), `s10_dx_m = dx·M` / `s10_dy_m = dy·M` (748-749),
  `src_{x,y} = center + d{x,y}·M` (752-753). The **x² term `s3_ax2dx2` is already
  computed separately** (685) — that's why cylindrical is a mux, not a rewrite.
- **`M=32768` is identity** (`src=out`): stage 9 outputs 32768 at r=0 (737-744).
- **No separate prewarp stage** (grep-clean): the ~1.18× fill-zoom is baked into
  `WARP_LUT`. ⇒ forcing the Y multiplier to 32768 gives `src_y=out_y` with no
  residual Y-zoom to fight. (Open Q in §4.)
- **Buffer / sync cost** (engine header cmt 28-31): pixel buffer
  `65536×24b ≈ 165 M10K`, sync buffer `≈ 20 M10K`. Total **≈ 185 M10K**.
- **Whole-engine fit today:** `output_files/Template.fit.summary` = **284/553
  RAM blocks (51%)**. Base (Template+ascal) ≈ 100; vis_warp adds ≈ 185.

The buffer is big for **vertical lookahead**, not bilinear: `N_LINES=128` window,
`src_y` clamp to `[cnt_y_o−N/2+1, cnt_y_o+N/2]` (845-851), and the whole sync
FIFO / `target_lag` self-tuning delay (148-173, 392-433) exists to make the
writer LEAD the reader by N/2 lines so that window is bidirectional. **Cylindrical
deletes the reason for all of it.**

---

## 2. The math change (2 muxes, become compile-time constants)

True vertical-axis cylinder: `src_x = cx + dx·f(x²)`, `src_y = out_y`.

1. **LUT input → x²-only.** Add a parallel stage-4 register
   `s4_x2only <= resize(s3_ax2dx2, …)`, and at the stage-5 lookup select
   `r2_in = CYL_MODE ? s4_x2only : s4_r2`. ⇒ `M` becomes a horizontal-only bow.
2. **Y multiplier → identity.** `s10_dy_m <= dy · (CYL_MODE ? 32768 : s9_m_scaled)`.
   ⇒ `src_y = cy + dy = out_y` exactly. No vertical displacement, ever.

Because `CYL_MODE` is a compile-time constant, Quartus folds the muxes — no
runtime cost, no CDC.

---

## 3. The architectural collapse (the v2 reclaim — `generate`-gated on CYL_MODE)

With `src_y = out_y` guaranteed by §2:
3. **Buffer `N_LINES` 128 → 2.** `addr = (cnt_y mod 2)·MAX_SRC_W + cnt_x`. A
   ping-pong line *pair* (writer fills line N+1 while reader reads line N).
4. **Bank split 2×2 → 2.** Only x-parity banks survive (no vertical tap — see #5).
5. **Bilinear → horizontal-only.** `fy = 0` always ⇒ drop the vertical lerp; keep
   the 2 horizontal taps (x, x+1) within the current line.
6. **Rip out the sync delay.** `src_y=out_y` ⇒ output is NOT delayed vs input ⇒
   the `sync_fifo` + `target_lag` + self-tuning measurement collapse to the **v3.2
   passthrough** (hs/vs/de straight through the warp latency). **This is the SAFE
   direction — removal, back to a timing that already shipped — not the v3.3
   add-a-delay that failed.**
7. **`src_y` clamp window (845-851) → trivial** (always in range).

**Floor:** 2 lines × MAX_SRC_W × 24b. At 512px ≈ 24 Kbit ≈ **~3-6 M10K**. So
vis_warp RAM **185 → ~5**, reclaim **≈ 180 blocks (~97% of vis_warp, ~33% of the
chip)**; Template fit **284 → ~105 (51% → ~19%)**.

**Hi-res bonus:** the floor is 2 lines *independent of height*. A 1024-wide core
needs `2×1024×24b ≈ 49 Kbit ≈ 5 M10K` — trivial. ⇒ **cylindrical warp runs
on-chip at any source width**; the DDR3 post-scale engine is only forced by the
*spherical* hi-res case. (Implication: hi-res cores get curvature here first.)

---

## 4. Open questions (resolve in Stage 0 sim)

- **Horizontal fill / WARP_LUT.** The baked-in fill-zoom in `WARP_LUT` was
  calibrated for *radial* fill. Feeding it `x²` may over/under-fill horizontally.
  Likely needs a **cylindrical-calibrated `WARP_LUT`** (a regenerated table in
  `vis_warp_luts_pkg.vhd`), OR confirm the radial table is "close enough." Pure
  LUT-data change, no datapath impact.
- **Confirm `src_y=out_y` exactly** with the Y-identity mux (no hidden zoom path).
- **Edge horizontal softening** is the *only* residual artifact (1-D). Pixel-art
  text tolerates it far better than vertical row-skip; quantify it in sim, decide
  whether Stage 3 supersampling is needed.

---

## 5. Build order (look first, reclaim second — sim-gated)

**Stage 0 — GHDL sim of the cylindrical datapath (DE-RISK; do not skip).**
The v3.3 postmortem's rule applies to this engine zone. Stand up a minimal TB:
synthetic timed input → assert `src_y == out_y` for all rows; horizontal warp
pixel-correct vs a Python reference; 2-line buffer addressing never reads OOB.
*(There is no vis_warp sim today — this is also reusable infrastructure.)*

**Stage 1 — math only, compile-gated, KEEP the 128-line buffer+sync.**
Just the §2 muxes under `CYL_MODE`. No buffer/sync change yet ⇒ zero buffer risk.
**Validates the LOOK on hardware** — Robotron's top score row flat, curved-H
only, no vertical stair-step. *This is the gate: confirm the look is right before
touching the buffer.* (= "v1," but under the cyl build flag.)

**Stage 2 — the collapse (the reclaim).**
§3 changes (buffer 128→2, bank 2, horizontal-only bilinear, sync rip-out) behind
`generate(CYL_MODE)`. Re-run Stage-0 sim. Hardware: identical look to Stage 1,
then read `Template.fit.summary` → confirm ~105/553. **This is where the 180
blocks come back.**

**Stage 3 — optional, spend the reclaim.**
Horizontal 2× supersample for edge text (cheap now), and/or raise `MAX_SRC_W` for
hi-res cores (now affordable on-chip).

---

## 6. Risks

- **Buffer re-addressing bug** → *visible* garbage (falsifiable on hardware,
  unlike v3.3's invisible sync failure). Stage-0 sim catches it first.
- **Horizontal fill** wrong → image over/under-fills H (LUT recal, §4).
- **Sync rip-out** must land exactly on the v3.2 passthrough — low risk because
  it's *removal* of code that post-dated a working baseline.
- **Rotated/TATE:** a vertical-axis cylinder doesn't commute with 90° display
  rotation. Moot for today's landscape-only set, but if rotated cores ever adopt,
  cyl needs an axis-select in *display* space (don't hardcode native-raster axis).

---

## 7. Files

- `sys/vis_warp_v2_wp.vhd` — engine: §2 muxes + `s4_x2only`; §3 `generate`-gated
  buffer/sync collapse; `CYL_MODE` generic.
- `sys/vis_warp.vhd` — wrapper: pass `CYL_MODE` (from the macro) to the engine.
- `sys/vis_warp_luts_pkg.vhd` — possible cylindrical `WARP_LUT` (§4).
- `sys/sys_top.v` — `MISTER_WARP_CYL` macro plumbing (parallel to `MISTER_WARP`).
- `sim/` — new Stage-0 GHDL TB + Python reference.

---

*Discipline: Stage 0 (sim) before any Stage-2 hardware. Stage 1 validates the
look at zero buffer risk. User runs full Quartus compiles; Claude writes RTL +
GHDL. Spherical build stays untouched throughout.*
