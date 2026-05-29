# Changelog

## v3.3c — Self-tuning sync-delay + first validated consumer core (2026-05-28)

The milestone: **symmetric barrel validated on a real arcade core
(Robotron), on hardware, via a mechanical adoption pipeline.**

- **Self-tuning sync-delay.** The FIFO writer-lead is no longer a
  hardcoded cycle count tuned for one htotal. The engine measures the
  core's line period (clk cycles between hs_in rising edges → `line_len`)
  and sets `target_lag = (N_LINES/2) × line_len`, so the read trails the
  write by exactly ~N_LINES/2 *lines* on ANY core. `rd_ptr` tracks
  `wr_ptr − target_lag`. This removes the one per-core manual step —
  arbitrary cores now adopt the template with no magic constant. THIS is
  what makes the core-adoption pipeline real.
- **Validated on hardware:** Template mycore (regression — still
  symmetric) AND `Arcade-Robotron_MiSTer` (symmetric barrel across native
  4:3, first honest build). Self-tuning generalized from dev rig to a
  real consumer core.
- **`ADOPTING-A-CORE.md`** added — the repeatable pipeline: static-read
  candidacy check (live-input vs rotated), vendor 4 files, 3 identical
  sys_top edits, macro, build. No line-timing constant.
- Williams multi-core means Robotron-VIS also covers Joust/Stargate/
  Bubbles/Splat/Alien★ar (all `landscape=1`).

Notes: HDMI wants the front-end scandoubler OFF (ascal scales the warped
native; scandoubler-on feeds doubled lines that resolution-gate the bow).
Twin-stick control mapping is stock-core, not vis_warp (video-path only).

## v3.2 — SCALE_PREWARP (shipping alpha, 2026-05-28)

Adds curvature-keyed pre-warp scale factor so the barrel-warped output
fills the output frame edge-to-edge (no clamped-source margins at
corners). This is the **current shippable alpha** baseline.

### Added

- **SCALE_PREWARP** (`sys/vis_warp_v2_wp.vhd`): 8-entry LUT keyed by
  `curvature_k(2:0)` containing Q1.15 scale factors. Multiplies the
  warp magnification before src position computation. +1 DSP.
- New stage 9b in the warp pipeline. Pipeline depth 16 → 17 stages.
- LUT values calibrated per curvature setting (k=2 → 1.183, k=7 → saturated).

### Known limitation

**Top-of-frame asymmetric warp**: ~20–30% of frame's vertical extent
at top shows asymmetric/stale-buffer content because the M9K sliding-
window buffer has no lookahead. Bottom 70% is clean. See
[`LIMITATIONS.md`](./LIMITATIONS.md#0-top-of-frame-asymmetric-warp-v32-release)
and
[`POSTMORTEM-v3.3-sync-delay-2026-05-28.md`](./POSTMORTEM-v3.3-sync-delay-2026-05-28.md).

### Validated

- Template hardware test: dome shape fills frame edge-to-edge
- Galaga hardware test: barrel-warped Galaga renders correctly except
  for top-of-frame stale region (per above)

## v3.3 / v3.3b — Sync delay (FAILED, REVERTED)

Two attempted implementations of N_LINES/2 sync delay to address the
top-of-frame asymmetry. Neither shipped:

- **v3.3** (counter-based FSM, ~165 lines new code): Compile-successful
  but hardware showed 1 FPS instead of 60. Root cause: equality check
  in the output-frame-start condition never re-fires after first frame.
- **v3.3b** (FIFO-based, 65536×4-bit M9K-backed): Compile-successful
  but hardware showed vanilla Galaga (ASCAL froze on last known frame).
  Bisect testing at `SYNC_FIFO_LATENCY=1` (~zero delay) ALSO showed
  vanilla, ruling out delay-value-only as the cause. Structural issue
  in how the FIFO output sync interacts with the ce_pix-gated pipeline.

Both attempts and the lessons learned are documented in
[`POSTMORTEM-v3.3-sync-delay-2026-05-28.md`](./POSTMORTEM-v3.3-sync-delay-2026-05-28.md).

**Future contributors**: read the postmortem BEFORE attempting v3.4.
Sync delay is harder than it looks; needs simulation + SignalTap
setup before any RTL changes.

## v3.1 — Bilinear pixel fetch (2026-05-28)

Visual quality upgrade: the warp curves are now smooth instead of
staircased. Architectural backbone unchanged from v3.0.

### Added

- **Bilinear interpolation** in `sys/vis_warp_v2_wp.vhd`. Reads 4
  neighboring source pixels per output pixel via a 4-way bank split,
  blends using fractional source-coordinate weights. Adds ~12 DSPs and
  3 pipeline stages.
- **4-bank pixel buffer split** by `(x mod 2, y mod 2)`. Same total M9K
  usage as single-bank but 4 simultaneous read ports.
- **`bilinear_en` port** on `vis_warp_v2_wp` entity, gated by
  `reg_bilinear_s2` after a 2-flop CDC sync in the wrapper.
- **`reg_bilinear` LIVE** in `sys/vis_warp.vhd` (was previously
  dead-but-kept for HPS_BUS contract compatibility — wired up in v3.1).

### Changed

- Pipeline depth: 16 → 19 stages.
- `s13_pixel` is now a combinational alias for `p00` (kept for
  SignalTap traceability); the actual emitted pixel comes from `s16_pixel`.
- Output emitter selects between bilinear-blended (`s16_pixel` from
  vertical lerp result) and NN (`s15_p00`) based on `s15_bilinear`.

### Dev-time default

`reg_bilinear` default initializer is `'1'` (bilinear on by default).
You can A/B test against NN by setting it to `'0'` and rebuilding.

### Resource impact (estimated, pending Galaga build validation)

| Metric | v3.0 NN | v3.1 bilinear |
|---|---|---|
| RAM Blocks | 252 | ~252 (split, same total) |
| DSP Blocks | 40 | ~52 (+12 for lerps) |
| Pipeline depth | 16 | 19 |
| Output rate | 1 per ce_pix | 1 per ce_pix (unchanged — banks read in parallel) |
| Latency add | — | ~3 clk cycles (≪0.5 µs at clk_video) |

### Known issue

The `sys/vis_warp_wrapper_tb.vhd` GHDL testbench doesn't yet drive
the new `bilinear_en` port on `vis_warp_v2_wp`. Quartus compile is
unaffected (it doesn't read the TB), but GHDL sim will fail to
elaborate until the TB is updated.

---

## v3.0 — Framework-level reboot (2026-05-28)

Major architectural shift from per-core sys/ edits (off-spec, getting
wiped on framework syncs) to framework-level integration in this
Template_MiSTer fork. Marked by recovering from a multi-hour ghost
chase on Galaga's per-core build.

### Added

- **`Template_MiSTer-VIS` as the dev rig.** A fork of upstream
  `MiSTer-devel/Template_MiSTer@f35083f` with vis_warp framework
  integration. Replaces the per-core editing of `Arcade-Galaga_MiSTer/sys/`
  that v2 had been doing.
- **`MISTER_WARP` macro gate** in `sys/sys_top.v`. Cores opt in via
  `set_global_assignment -name VERILOG_MACRO "MISTER_WARP=1"` in their
  `.qsf`. Default off (= bit-identical to upstream Template_MiSTer).
- **SITE C wiring** in `sys/sys_top.v`: vis_warp instance between
  arcade_video's scandoubled output and ascal's input, on clk_vid
  (= clk_video) domain.
- **B4 Phase 1 minimal CDC** in `sys/vis_warp.vhd`: 2-flop synchronizers
  for `reg_enable` and `reg_curvature`, toggle handshake for reset
  pulse. `preserve` attributes throughout.
- **HPS opcode 0x45** decoded in `sys_top.v` for runtime configuration
  (driving registers consumed by `vis_warp.vhd`). Always-on regardless
  of `MISTER_WARP`; harmless when vis_warp isn't instantiated.
- **Test pattern selector** in `rtl/mycore.v`: 8 patterns (cosine
  default, grid for warp testing, vbars, gradient, crosshair, gray50,
  black, white). Selected via `status[13:11]` from a new CONF_STR
  option.
- **`SPEC-vis_warp-v3.md`**: workflow doc with phases 0–9, what's in
  scope per phase, open questions.
- **`HANDOFF-vis_warp-v3-kickoff-2026-05-28.md`**: session continuity
  doc with build instructions for phases 3–8.

### Removed

- **Site A vis_warp instance** (post-osd, clk_hdmi domain) and its
  `hdmi_*_warp` wiring. Architecturally wrong — see
  `~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md`
  for the multi-page rationale.
- **`sys/vbuf_svc.sv`** (DDR3 channel arbiter). Not needed at site C
  (M9K ping-pong instead).
- **Per-core sys/ modifications** to `Arcade-Galaga_MiSTer/sys/` —
  preserved via `git stash` for evidence but no longer the dev path.

### Changed

- **`sys/vis_warp_v2_wp.vhd`** rewritten from DDR3 ping-pong (site A
  era) to M9K sliding-window (site C era). 16-stage warp math
  pipeline preserved from v2. Source-dim auto-detection on first
  frame. RGB888 pixel buffer.
- **`sys/vis_warp.vhd`** wrapper rewritten to match new v2_wp port
  shape: 8-bit r/g/b separate (matches ascal i_r/i_g/i_b), no avl_*
  ports (no DDR3 access), no display_w/h (auto-detected).

### Memory + index

- **`reference_mister_framework.md`** added to project memory —
  durable lookup for MiSTer integration patterns, contribution model,
  testing reality.
- **`MEMORY.md` index** updated with new entries.

### Validated on hardware

- ✅ Phase 3 baseline (MISTER_WARP unset) — Template loads, mycore
  test patterns selectable via OSD.
- ✅ Phase 4 MISTER_WARP=1 + k=0 — compile-time signals confirm
  vis_warp in netlist (RAM Blocks 252, DSP Blocks 40, cmd_data/wr
  warnings gone). Not loaded to hardware (k=0 identity not visually
  distinguishable from off).
- ✅ Phase 5 k=2 — grid pattern shows visible barrel curvature on
  screen; OSD stays straight and readable. **Architectural validation
  complete.**

---

## v2 — Ghost chase (2026-05-27 → 2026-05-28 night)

The work captured here was the iteration that culminated in the v3
reboot. Documented in retrospect for institutional memory.

### What was attempted

DDR3-based site-A architecture (post-osd, clk_hdmi, vbuf-shared-with-ascal
via custom arbiter). Multiple subsequent rewrites of vbuf_svc, source-dim
detection, sync regeneration, etc. Eventually rewritten as M9K
site-C in v2 final hours; that engine was preserved into v3.

### What was learned

- vbuf-shared-with-ascal can't work: bandwidth ceiling, brittle
  multi-channel arbiter, CDC complexity.
- Site A doesn't work at 4K (M9K math, OSD readability, shadowmask
  ordering).
- Per-core `sys/` modification is off-spec by project policy and
  guaranteed-ephemeral.
- "Picture identical to vanilla = my build worked" is **NOT** a valid
  test methodology. Always require a positive falsifiable signal.

### Closing artifact

`pacman-vis/HANDOFF-v1-to-v2-ghost-chase-2026-05-28.md` is the
postmortem of the night. Worth reading before working on this project
to internalize what doesn't work and why.

---

## v1 — Initial architecture (2026-05-26)

Pre-existing work that v2/v3 built on. The phase-2 16-stage warp math
pipeline was developed here; the rest was overhauled.
