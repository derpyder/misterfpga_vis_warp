# Postmortem: v3.3 sync delay — two failed attempts

Written 2026-05-28, after we burned ~4 hours on two distinct sync delay
implementations, neither of which worked on hardware. Ended with a
revert to v3.2 (bilinear + SCALE_PREWARP, no sync delay) as the
shippable alpha.

This document exists so the next person who looks at vis_warp and
thinks "I bet I can implement the sync delay properly" reads this
first and doesn't repeat the mistakes.

## The problem sync delay is trying to solve

`vis_warp_v2_wp.vhd` uses a sliding-window M9K pixel buffer of
N_LINES=128 lines. The writer fills it as input source pixels stream
in. The reader, lock-stepped with the writer (just pipeline stages of
delay), pulls pixels from the buffer to apply the warp transformation.

At any given moment during a frame:
- Writer is at source line Y (writing line Y into buffer slot Y mod 128)
- Reader is at source line Y too (give or take pipeline stages)
- Buffer holds lines [Y-127, Y] — looks backward only, never forward

For barrel warp at output line Y, the warp math wants to read source
positions that can be **both** above and below Y (e.g., at top corners
of the output, source y > Y; at bottom corners, source y < Y).

With current design:
- Output line 0 (top): warp wants src_y in roughly [0, +30] for typical
  curvature. The buffer holds [0-127, 0] = mostly garbage. The warp
  reads garbage for forward lookups, producing stale-buffer noise.
- Output line 180 (middle): buffer holds [53, 180]. Warp pulls within
  this range successfully. Looks correct.
- Output line 359 (bottom): buffer holds [232, 359]. Warp pulls within
  this range. Looks correct.

Net visual: **top of frame stale/asymmetric; middle and bottom good**.
On hardware, this manifests as "the top 20–30% of the screen shows
noise or chunks of previous-frame content while the bottom looks
properly warped."

## The intended fix

Delay the output sync by N_LINES/2 = 64 source lines. Then the writer
leads the reader by 64 lines, the buffer always contains both ±64
lines around the output position, and bidirectional lookahead works:
- Output line 0: writer is at source line 64, buffer holds [0, 64].
  Warp at output 0 reads src in [-30, +30] → 0..30 in buffer, -30..0
  clamps to 0 (sensible source-edge behavior). Top of frame is clean.
- Output line 180: writer at 244, buffer holds [117, 244]. Warp reads
  ±30 around 180 = [150, 210] all in buffer. Middle clean.
- Output line 359: writer at 423 (past frame end), buffer holds
  [296, 423] of which [296, 359] is real source and [360, 423] is
  irrelevant. Warp reads ±30 around 359 = [329, 389] → 329..359
  valid, 360..389 clamps to source edge. Bottom clean.

Net result: clean top-to-bottom warped frame.

Cost: ~5 ms of input-to-output latency (64 lines × ~78 µs per line at
typical clk_video). Imperceptible.

This was the goal. **It was not achieved in either attempt.**

## Attempt 1 (v3.3) — counter FSM

Approach: replace the simple lockstep counter with an FSM that
measures input HTotal/VTotal, then runs a parallel output raster
delayed by N_LINES/2 input lines after each `vs_in`. Output sync
regenerated from the FSM's internal counters.

Implementation: ~165 lines of new code in `vis_warp_v2_wp.vhd`. New
signals: `out_armed`, `out_delay_cnt`, `out_frame_active`, `out_h_cnt`,
`out_line_cnt`, `cnt_x_o`, `cnt_y_o`, `htotal_latched`, `vtotal_latched`,
`hs_in_d2`, `h_meas_cnt`, `v_meas_cnt`. Constants `HS_PULSE_W=32`,
`VS_PULSE_W=2`.

### Hardware outcome

**1 FPS** (output animated at ~1 frame per second instead of 60).

### Root cause analysis

Two bugs identified post-hoc:

1. **Equality check that never re-fires.** The FSM uses
   `if out_delay_cnt = (N_LINES/2) - 1` to detect the moment to start
   the output frame. After firing once, `out_delay_cnt` keeps
   incrementing past 63 and only resets on the NEXT `vs_in` rising.
   Should have been `>=` with an "out_armed" gate that clears once
   the frame starts.

2. **Counter widths and overflow paths uninvestigated.** Without
   TimeQuest report visible, can't confirm whether `v_meas_cnt` or
   `vtotal_latched` overflowed, but the symptom (60 FPS dropping to
   1 FPS) suggests vtotal_latched got set to something massive that
   stretched output frames over many input frames.

### Why it took so long to diagnose

We didn't have SignalTap probes wired. With only the visible output
to go on, "1 FPS" was a single data point. The FSM has multiple race
conditions; you can't tell which one fired without internal-signal
visibility. Took 1+ hour to even read through the agent's
implementation carefully enough to spot the equality bug.

## Attempt 2 (v3.3b) — FIFO

Approach: replace the FSM with an M9K FIFO of width 4 bits (hs, vs,
de, ce_pix), depth 65536, with read pointer initialized to lag write
pointer by N_LINES/2 × max_htotal = 49152 cycles. FIFO pushes input
sync every clk, pops output sync 49152 cycles later. Simpler logic —
no measurement, no FSM transitions.

Implementation: removed the v3.3 FSM (~165 lines), added FIFO
infrastructure (~100 lines). Net file change: -78 lines.

### Hardware outcome

**Vanilla Galaga** (ASCAL freezes on last known good frame, shows
the pre-warp Galaga image indefinitely).

### Root cause analysis

The FIFO returns its zero-initialized M9K contents for the first
49152 clk cycles (~3.5 ms). During that time:
- `hs_o_gen`, `vs_o_gen`, `de_o_gen` are all '0'
- No frame edges are detected by ASCAL
- ASCAL enters a "no input lock" state
- Falls back to last-known-good frame display

After 49152 cycles, real sync starts flowing through. But ASCAL has
already given up — by the time real sync arrives, ASCAL may take many
frames to recover, or never recover at all, depending on its internal
state machine.

### Bisect attempt

Set `SYNC_FIFO_LATENCY = 1` (essentially zero delay) to test whether
the FIFO infrastructure itself is sound when not asked to delay.
Expected: v3.2-equivalent output (top-asymmetric, bottom-good).
Actual: still vanilla.

This rules out the "ASCAL can't recover from 3.5ms dead time" theory
as the sole cause. Even with minimum delay, the FIFO-based structure
doesn't drive ASCAL correctly. There's a deeper bug — probably in
how the pipeline's `ce_pix` gating interacts with the FIFO's clk-rate
push/pop, causing pixel data and sync to be misaligned in time.

### Why this also took so long

We jumped to "implementation looks complete, build it, test it"
instead of:
1. Adding SignalTap probes BEFORE the first hardware test
2. Drafting a simulation testbench to validate FIFO behavior under
   different ce_pix patterns
3. Implementing the simplest possible delay (e.g., a 16-cycle shift
   register) first and incrementing complexity from there

The agent's impact report claimed correct behavior. Hardware proved
otherwise. **Agent reports describe intent, not behavior.**

## What worked (the v3.2 baseline we're shipping)

Everything below ships in the released alpha:

- **Bilinear pixel fetch (v3.1)**: 4-way bank split of pixel_buf by
  (x%2, y%2), enabling 4 simultaneous reads per output pixel. Smooth
  curves where v3.0's NN gave staircases. Validated on Template.
- **SCALE_PREWARP (v3.2)**: 8-entry LUT keyed by curvature_k that
  scales the warp magnification factor so the warped output fills
  the output frame edge-to-edge. No more stale-source margins at
  corners. Validated on Template.
- **Site C architecture (v3)**: vis_warp lives pre-ascal, source-res,
  on clk_video. M9K-friendly, OSD stays straight, integer scaling
  works on 4K. Validated on Template + Galaga (with the asymmetry
  caveat above).
- **Framework integration (v3)**: `MISTER_WARP` macro gate, cmd 0x45
  HPS_BUS opcode, surgical sync pattern for older consumer cores.
  Documented and tested.

## What didn't work (deferred)

- **Sync delay**: 2 attempts, 2 failures, ~4 hours total. Defer to
  v3.4 (future work).

## Methodology lessons (institutional knowledge)

The points below apply broadly, not just to sync delay:

### 1. Agent reports describe intent, not behavior

When an agent says "implementation complete, behaves correctly,"
that means it BELIEVES the code matches the spec. It does NOT mean
the hardware will work. Test BEFORE trusting.

### 2. "Build succeeded" doesn't mean "design works"

Quartus's Fitter Successful status only confirms the design synthesized
and fit. It doesn't validate runtime sync timing, FIFO race conditions,
or any of the many ways output can be subtly wrong at the pixel-clock
level. Map.rpt warnings are useful clues but NOT sufficient predictors.

### 3. Hardware ground truth requires falsifiable visual signals

When the user pushed back early with "how do we avoid the same
absence-of-difference trap as yesterday," the answer was to require
a positive visual signal at each step — bow visible vs not, top-clean
vs not. Apply this at every iteration, not just at milestone moments.

### 4. Dead VHDL variables warn but don't break

The map.rpt "object 'X' assigned but never read" warnings for variables
(not signals) are usually benign — agent left dead code from refactor.
Don't false-alarm. Verify by tracing the actual signal path: where
does the data come from, where does it go.

In contrast, "logic that only feeds a dangling port will be removed"
is a real connection failure.

### 5. Sync timing is the hardest thing to test from build reports

Memory inference, DSP packing, ALM counts, fmax — all visible in
reports. Pixel timing and sync edges relative to other signals —
invisible. Only SignalTap or oscilloscope reveals this. **Wire up
SignalTap BEFORE shipping anything that touches sync.**

### 6. Integer scaling pixel chunkiness is intrinsic to MiSTer

You cannot make 240p source look smooth on 4K with integer scaling.
That's what NN-9x produces. vis_warp's job is to make the WARP smooth,
not the pixel art. Pair with ascal's polyphase filters if smooth pixel
art is also wanted (defeats integer scaling but reaches CRT-realism).

### 7. Test rig != real product

Template + mycore looks great because mycore is a clean synthetic
source. Galaga's content (stars, sprites, score text) tests vis_warp
in a different way. Test rig validates the engine; real cores validate
the user experience. **Don't ship based on test-rig validation alone.**

### 8. Source resolution matters for honest evaluation

The 530×240 ugly-aspect default mycore made visual evaluation
misleading. The 480×360 4:3 upgrade made it possible to see the dome
shape correctly. Mismatched source aspect + framework's VIDEO_ARX/ARY
default = stretched cells that look wrong even when math is right.

### 9. Sync delay is genuinely hard

It looks like a small feature ("just delay the output a bit") but
involves multi-clock-domain timing, FIFO race conditions, ASCAL's
input expectations, ce_pix gating interactions, frame-edge handoffs,
and reset-state initialization. **Don't underestimate. Plan
simulation + SignalTap + incremental hardware tests BEFORE writing
any code.**

## Pre-emptive guidance for the v3.4 retry

If/when someone attempts proper sync delay implementation:

1. **First, simulate.** Use GHDL or Modelsim to instantiate vis_warp +
   the sync delay component, feed it synthetic input, and verify the
   output sync edges arrive when expected relative to input sync
   edges. Do this BEFORE running on hardware.

2. **Wire SignalTap probes in the FIRST hardware build.** Probe:
   - Input sync (hs_in, vs_in, de_in, ce_pix_in)
   - FIFO/delay output sync (hs_out_dly, vs_out_dly, de_out_dly)
   - Pipeline stage 1 sync capture
   - Pipeline stage 12 sync output to emitter
   - ASCAL's i_hs, i_vs, i_de (the actual interface)

   You'll need SignalTap to debug ANY sync issue.

3. **Test with SCALE_PREWARP DISABLED initially.** Bilinear + sync
   delay alone is enough to debug. Adding SCALE_PREWARP on top
   compounds variables.

4. **Don't change the pipeline's ce_pix gating.** Keep the
   pixel-data-and-sync path on input ce_pix as today. Implement sync
   delay as a STRICTLY EXTERNAL component that delays the
   sync signals only, leaves data path untouched.

5. **Initialize FIFO contents to repeating valid sync patterns**, not
   zeros. E.g., precharge with idle-but-non-frame-boundary sync
   states so ASCAL doesn't see "all silent input → lost lock."

6. **Test on Template FIRST, Galaga SECOND.** Template has cleaner
   sync timing (mycore is synthetic). Galaga's arcade_video pipeline
   has scandouble + scanlines stages that affect sync arrival times.
   Each new variable adds debug surface.

7. **If multiple sync-delay attempts fail, accept that the design
   ABSENT sync delay is shippable.** v3.2 is alpha-quality. Don't
   block release on sync delay if it doesn't work.

## What we did NOT change (don't re-litigate)

These are locked-in architectural decisions from
`design_vis_warp_constraints.md`:

- Site C (pre-ascal, source res, clk_video) — NOT post-ascal/HDMI res
- M9K pixel buffer — NOT DDR3
- Framework-level (`Template_MiSTer/sys/`) — NOT per-core
- Macro-gated opt-in (`MISTER_WARP=1`) — NOT always-on
- 4-way bank split for bilinear — NOT replicated buffers
- Source-pixel bilinear interpolation — NOT post-ascal smoothing

## Final v3.2 ship state

- vis_warp.vhd: wrapper with HPS_BUS contract, B4 Phase 1 CDC,
  bilinear/curvature/enable register decoding
- vis_warp_v2_wp.vhd: engine with 16-stage warp pipeline + SCALE_PREWARP
  stage 9b + bilinear stages 14-16 + 4-bank pixel_buf
- vis_warp_pkg_v2.vhd: types
- vis_warp_luts_pkg.vhd: warp coefficient LUTs
- sys_top.v: MISTER_WARP-gated SITE C wiring
- Galaga consumer fork: synced + .qsf has MISTER_WARP=1

Known visible limitation: top-of-frame asymmetric warp (per the
buffer-without-lookahead problem this document was about).

See LIMITATIONS.md for the full list.
