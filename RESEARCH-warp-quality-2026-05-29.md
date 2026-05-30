# RESEARCH OUTCOME — curved-warp quality & architecture (2026-05-29)

Decision record from a 4-agent research fan-out: "how to get clean curved
(cylinder/barrel) warp with good minification quality on MiSTer." 3/4 agents
returned strong; the CRT-shader agent was re-run (findings fold into Decision 2).

---

## DECISIONS

### 1. Output-resolution warp — SHELVED to next-gen silicon (DE25-nano / Agilex 5)
A post-ascal, output-resolution warp (where the curve is pure MAGNIFICATION, no
minification aliasing) is **infeasible on Cyclone V / DE10-nano**:
- **DDR3 gather** of an output-res framebuffer: ~370–620 M transactions/s demanded
  vs the **~80 M/s `vbuf` ceiling** — *on top of* ascal's own write+readback of the
  same single 64-bit HPS DDR3 bridge. This is the exact bandwidth wall hit 3× before.
- **On-chip output-line cache:** 30 lines ≈ **65% of all 553 M9K** for a barely-
  visible ±2.8% bow at 1080p; a meaningful or 4K-scale bow needs 45–90+ lines =
  **100–200% of total M9K**, before core + ascal.

→ **Stay SOURCE-RES (SITE C).** ascal magnifies the *already-warped* source, so the
magnification benefit is captured for free; the bow scales with the upscale factor.
Output-res becomes clean only when both binding constraints relax at once (tens of
Mbit on-chip RAM + wider/faster multi-port DDR) — i.e. Agilex-class. *(Insertion
point, if ever pursued: between ascal output and shadowmask in sys_top, clk_hdmi,
no CDC — mirror ascal's own o_line0..3 readback cache, widened to N lines.)*

### 2. Minification fix — a source-res, JACOBIAN-GATED PREFILTER (cheap, additive)
- **No FPGA prior art solves our case.** The entire mature lens-distortion-correction
  field (Intel Warp IP, Xilinx `xf::remap`, the academic dewarp corpus,
  `colinpate/fpga-vr-remap`) uses bilinear point-sampling with **zero minification
  AA** — because fisheye/keystone correction *stretches* (magnifies) edges. Our CRT
  barrel *compresses* (minifies) edges → opposite regime → that asymmetry is exactly
  why our aliasing is real and theirs isn't.
- **The minification answer is GPU texture-mapping:** mipmap + trilinear (isotropic)
  and anisotropic EWA/Feline (probes along the major-compression axis). A barrel
  compresses **radially**, so the simplified hardware form is a **1-D radial
  supersample** ("Feline with a fixed known axis").
- **FPGA-cheap realization (recommended):** a **separable variable-width running-box
  (moving-average) prefilter, gated to fire only where local minification J > 1**
  (the Jacobian is already computed in the pipeline), feeding the existing 2-tap
  bilinear. Add-on-enter / subtract-on-leave → **~a few M9K, ~0 DSP**, fits the 3–8
  spare clocks/pixel. Quality tiers if box softness shows: 2-box cascade (→tent), or
  mipmap-lite (~+50 M9K). Polyphase FIR is reference-grade but overkill for ~1.3×.
- **Confirmed additive:** ascal does **no** downscale AA (nearest/bilinear only), so
  this prefilter fills a real gap rather than duplicating the scaler.
- **Reject:** summed-area table (precision/overflow blows the on-chip budget; axis-
  aligned only — no quality edge over the running-box).

**Shader-evidence refinement (CRT-Royale / crt-geom / crt-lottes / MAME):** the
good CRT shaders warp at OUTPUT res on an already-upscaled image — but **even there
the curved edge still minifies, and they ALL carry an explicit prefilter** (not free
mipmap). crt-lottes (no prefilter) is the reference example of OUR exact aliasing.
Since output-res is infeasible here (Decision 1), source-res is forced ⇒ **the
prefilter is MANDATORY for quality, not optional polish.** Two confirmed tiers:
- **Cheap (crt-geom):** 3× oversample of the scanline/beam weight, offset by the
  local footprint — kills the scanline×curvature moiré specifically. Minimal cost.
- **Rigorous (CRT-Royale):** an analytic 2×2-Jacobian footprint → 4–24-tap weighted
  area sample, gated to the compressing band (`aa_level` early-out).
**FPGA-friendly key:** GPUs size the footprint with free `ddx/ddy`; WE size it
**analytically from the closed-form warp derivative** (the Jacobian we already
compute) — no derivatives needed. Our Jacobian-gated running-box is exactly the
FPGA realization of Royale's approach; crt-geom's 3× beam-oversample is the
minimal-cost first cut.

---

## REUSABLE ASSETS (don't reinvent)
- **`colinpate/fpga-vr-remap`** — open SystemVerilog inverse-map remap on the **same
  Cyclone V / DE10-nano**: DDR coord-LUT (`coord_blk_reader`) + BRAM line-tile cache
  (`rect_buffer_*`) + 2px/clk bilinear. The tile-cache is the most liftable piece.
- **Coordinate storage** (if dropping closed-form barrel math): 8×8 mesh-LUT (Intel
  Warp IP standard) or a radial-symmetry-compressed LUT (store one quadrant, mirror)
  — a barrel is radially symmetric.
- **Theory:** minification low-pass cutoff ω = π/R (R variable → kernel width must be
  variable); split address-gen (inverse map) from the band-limiting resample filter.

---

## IMPLEMENTATION PLAN (priority)
1. **Res-adaptive calibration** (aspect weights + fill computed from detected
   src_w/src_h) — REQUIRED before main-merge / consumer cores. Removes the hardcoded
   480×360 assumption.
2. **Jacobian-gated variable-box prefilter** — worst-case-clean polish. Prototype in
   the faithful model (`sim/warp_faithful_2d.py`, already has the bilinear sampler)
   before RTL.

*Sources: the 4 agent reports (this session's transcript). MiSTer ascal: no downscale
AA. LDC IP magnifies → no minification AA. Minification AA = mipmap/anisotropic.*
