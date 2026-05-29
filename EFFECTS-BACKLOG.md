# vis_warp effects backlog — Tier 1 / Tier 2 / Flagship

Engineering handoff for the next batch of user-tunable effects. Each is a
self-contained spec: what it does, the **pipeline value it rides on** (the
cheap-because-it-already-exists hook), cost, the `cmd 0x45` register, and
how to validate on the Template grid/patterns.

**Organizing principle (don't violate):** surface only what's unique to the
warp stage or rides cheaply on geometry vis_warp already computes. Do NOT
reimplement MiSTer's downstream stack (shadowmask, scanlines, gamma, scaler
filters, color) — those exist and stack on top of the warp.

**What vis_warp already computes per output pixel** (the hooks): `dx, dy`
(offset from center), `r²` (radial, the `s4_r2` stage), barrel mag `M`,
warped `src_x/src_y`, fractional parts, the `SCALE_PREWARP` zoom (stage 9b).
Anything that's a function of these is cheap.

**All of these surface via the existing mechanism:** a `cmd 0x45` register
(CDC-synced in `vis_warp.vhd`, plumbed to `vis_warp_v2_wp.vhd`) + a v4 OSD
slider. Mirror `reg_sharpness` / `reg_curvature`. They are GLOBAL OSD options
(Main_MiSTer Video Processing menu), NOT per-core CONF_STR — a framework
module can't read `status[]` (see ROADMAP §v4).

---

## Opcode allocation (cmd 0x45, 3-bit op + 13-bit payload)

| op | register | status |
|----|----------|--------|
| 000 | flags (enable, bilinear, …) | **in use** |
| 001 | curvature (extend → H/V + pincushion sign in payload) | **in use** |
| 010 | sharpness (sharp-bilinear K) | **in use (v3.3d)** |
| 011 | **overscan / zoom** | Tier 1 |
| 100 | **vignette** | Tier 1 |
| 101 | **corner rounding** | Tier 1 |
| 110 | **warped scanlines** | Tier 2 |
| 111 | **bloom** (+ packed payload: threshold/intensity) | Flagship |

⚠️ That uses all 8 opcodes. H/V-curvature, pincushion sign, and bloom's
multiple params must live in **payload bits** of their opcode, not new
opcodes. If we outgrow it, widen the cmd encoding (the `cmd_in` is 16 bits;
currently 3 op + 13 payload — repartition as needed).

---

## TIER 1 — cheap, ride directly on existing values

### 1. Overscan / Zoom  (op 011)
- **What:** how far the image is zoomed into the frame — full-image-visible
  vs CRT-style edge crop. A real taste knob.
- **Hook:** `SCALE_PREWARP` (stage 9b, `s9b_*`) already computes a per-
  curvature zoom to fill the frame. Make the effective scale =
  `SCALE_PREWARP(curvature) × overscan(user)`.
- **Register:** `reg_overscan` (3 bits → ~0.9×–1.5× via a small LUT).
- **Cost:** LOW — one extra multiply on the existing s9b scale.
- **Validate:** Template grid — higher overscan pushes grid edges past the
  frame (crop); lower shows more border. Below the curvature's natural fill
  → black corners (expected; document it).

### 2. Vignette / edge darkening  (op 100)  ★ vis_warp-unique
- **What:** corners/edges dim like a real tube.
- **Hook:** `r²` is already computed for the barrel math (`s4_r2`). Map
  `r²` → a brightness falloff, multiply the output RGB at the emitter.
- **Register:** `reg_vignette` (3 bits → 0=off … 7=strong).
- **Cost:** LOW–MODERATE — 3 channel multiplies at the emitter + a falloff
  LUT (or simple polynomial). `r²` exists.
- **Validate:** Template solid-gray pattern (#5) darkens toward corners;
  strength tracks the register.

### 3. Corner rounding / tube-corner mask  (op 101)
- **What:** black the rounded tube corners.
- **Hook:** the warp already detects out-of-bounds src coords near corners
  (stage 11/12 clamps). Output black when radial position exceeds a
  corner-radius threshold instead of clamping.
- **Register:** `reg_corner` (3 bits → 0=square … 7=very round).
- **Cost:** LOW — a radius compare → black mux at the emitter.
- **Validate:** Template — corners go black in a rounded arc; radius scales.

---

## TIER 2 — moderate, distinctive

### 4. Separate H/V curvature  (op 001 payload)
- **What:** independent horizontal vs vertical bow (real tubes aren't
  radially symmetric; people fiddle this to match a remembered CRT).
- **Hook:** barrel `M = f(r²)` is applied to both `dx` and `dy`. Make the
  radial term anisotropic: `r²_eff = (kx·dx)² + (ky·dy)²`, or separate
  `M_x`/`M_y`. The `LUT_AX2`/`LUT_AY2` LUTs are already aspect-separate — a
  starting point.
- **Register:** extend op 001 payload — `curvature_h` (bits 2:0),
  `curvature_v` (bits 5:3). No new opcode.
- **Cost:** MODERATE — real change to the warp arithmetic. Care needed.
- **Validate:** Template grid with H>V — horizontal lines bow more than
  vertical; per-axis symmetry preserved.

### 5. Pincushion (signed curvature)  (op 001 payload)
- **What:** bow inward (pincushion) as well as outward (barrel).
- **Hook:** the curvature sign — invert the displacement direction.
- **Register:** a sign bit in op 001 payload (e.g. bit 6).
- **Cost:** MODERATE — sign handling in warp math; **watch the buffer-window
  clamps** (inward warp pulls source differently — re-check the
  ±N_LINES/2 window still covers it).
- **Validate:** Template grid — edges bow inward.

### 6. Warped scanlines  (op 110)
- **What:** scanlines that curve *with* the glass (vs MiSTer's flat
  downstream scanlines).
- **Hook:** darken by the warped `src_y` the pipeline already computes.
- **Cost:** MODERATE — **the hard part is source-res vs output-res:**
  scanlines are an output-res concept, vis_warp is source-res. A per-source-
  line darken upscaled by ascal gives bowed-but-possibly-thick lines.
  Compute the scanline phase from the warped coord at the emitter and
  validate the thickness empirically.
- **Fallback:** if it looks coarse, MiSTer's flat downstream scanlines still
  work — this is additive, not a replacement.
- **Validate:** Template grid — scanline darkening follows the bow.

---

## FLAGSHIP — bloom / phosphor glow  (op 111)  ★ vis_warp-unique, HIGH cost

- **What:** bright areas bleed/halo into their surroundings — the signature
  CRT-glow look (CRT-Royale-grade). MiSTer has **no** bloom downstream, so
  this is net-new, not a duplicate.
- **Why it fits (corrected — it is NOT the output-res wall):** vis_warp is
  **source-res**, and source-res bloom is feasible because:
  1. The 4-bank M9K buffer already holds 128 source lines (neighbors to read).
  2. Pixel rate ~6 MHz on a 20–48 MHz clk = ~3–8 spare clk cycles per pixel
     → do **multi-tap blur reads sequentially** from the existing banks, no
     memory doubling.
  3. ascal upscales the source glow: a ±4-source-px blur → ±36-output-px halo
     for free. The expensive wide output kernel is done *by the scaler*.
- **Stages (all source-res, placed BEFORE the warp so glow warps with the
  image and shares the buffer):**
  1. **Bright-pass:** `max(0, luma − threshold)` per pixel. Trivial.
  2. **Blur:** separable — horizontal shift-register accumulator (cheap) +
     vertical accumulator reading a few lines via spare-cycle bank reads.
     Spectrum: crude box-blur (first cut) → separable Gaussian → multi-level.
  3. **Composite:** additive blend onto warped output + clamp.
- **Registers:** op 111 + packed payload — bloom enable, threshold,
  intensity/radius.
- **Cost:** HIGH — most complex effect; multi-tap blur + threshold +
  composite + shared-buffer timing.
- **Risks:** (a) quality is source-res-coarse — looks great with a smoothing
  ascal filter, possibly stepped with NN ascal (build-and-look). (b) This is
  the **multi-tap-buffer-timing class that scarred us on the sync-delay** —
  **write a GHDL sim of the blur before any hardware build.** (c) Build
  incrementally: crude box-blur first to prove the path, then upgrade kernel.
- **Budget:** Robotron sits ~322/553 RAM blocks → ~230 headroom for a bloom
  intermediate if spare-cycle reads need one.
- **Validate:** Template white / crosshair pattern shows a halo; threshold
  and intensity scale it.

---

## Sequencing

1. **Tier 1 first** (overscan → vignette → corner). Low risk, builds out the
   OSD panel, and proves the register→effect→slider→validate loop end-to-end
   on cheap effects.
2. **Tier 2 next** (H/V curvature is the standout; pincushion + warped
   scanlines as fillers).
3. **Bloom last, as a v3.5 flagship** — spec'd, simmed, built incrementally.
   It's the headline feature; don't rush it (it bites if you do).

Every one is the same shape: add a register mirroring `reg_sharpness`, add
the effect math (riding the hook above), add a v4 OSD slider, validate on a
Template pattern. No architecture changes for Tier 1/2; bloom needs the sim.
