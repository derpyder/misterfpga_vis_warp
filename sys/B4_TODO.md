# B4 — Async FIFOs for video ingress/egress CDC

Status (2026-05-28): **Phase 1 minimal LANDED**, Phase 2 full FIFOs
DEFERRED. See SPEC-vis_warp-v3.md.

## Phase 1 (DONE, 2026-05-28)

2-flop synchronizers for the three clk_sys → clk_in control signals,
in-line in `sys/vis_warp.vhd`:

  * `reg_enable` → `reg_enable_s1` → `reg_enable_s2` (level sync, 2 flops)
  * `reg_curvature` → `_s1` → `_s2` (3-bit level sync, 2 flops per bit)
  * `reg_reset_int` (1-cycle pulse on clk_sys) → toggled at source,
    3-flop sync on clk_in, XOR-edge-detected back into 1-cycle clk_in
    pulse. Cannot be lost regardless of clk_sys vs clk_in ratio.

Synchronizer signals carry `preserve` attribute so Quartus doesn't
optimize the chain.

Justification for the level signals not needing toggle-handshake: they
are slowly-changing user config. A 1-cycle transient mid-update is
visually irrelevant — at most one frame uses a slightly-wrong curvature
between user OSD interactions. Multi-bit gray coding would be overkill.

## Why Phase 2 (full async dcfifo) is deferred

At site C, `clk_in = clk_out = clk_ihdmi` (ascal's input clock). The
egress crossing collapses to identity — no FIFO needed on the data path.
The only real CDC is the config-register read into the data-path clock
domain, which Phase 1 handles. The pixel data itself never crosses a
domain inside this wrapper.

If a future revision moves vis_warp to a different slot (e.g., between
ascal and shadowmask on `clk_hdmi`), Phase 2 will be needed because
clk_in (= clk_video) and clk_out (= clk_hdmi) would diverge.

## Open question: SDC constraints

Phase 1's synchronizer chains may require explicit `set_false_path`
entries in an SDC file to avoid Quartus timing warnings about
unconstrained CDC paths. **Do not edit `Template.sdc` directly** — it's
upstream-tracked. If needed, add a separate `sys/vis_warp.sdc` and
reference from `sys.qip`. Defer until Phase 3 build (SPEC task #7)
reports actual warnings.

## Why this is real work, not a one-liner

`vis_warp_v2` (sim today) runs on a single `clk`. The framework wrapper
exposes three distinct clock-domain ports (sys/sys_top.v wiring):

  * `clk_in`  — source pixel clock. Driven by `clk_vid` in sys_top.
                Carries `ce_pix_in / din / hs_in / vs_in / de_in`.
  * `clk_out` — sink pixel clock.   Driven by `clk_hdmi` in sys_top.
                Carries `ce_pix_out / dout / hs_out / vs_out / de_out`.
  * `clk_sys` — engine + config clock. Drives `cmd_wr / cmd_in` and the
                control-register bank. Currently also drives `u_v2.clk`.

The current wrapper just feeds `clk_sys` into v2 and aliases the three
domains together inside sys/vis_warp.vhd. That works for GHDL (single
clock anyway) and the wrapper smoke TB but is **unsafe on real HW**:

  * Pixel data from `clk_in` is sampled directly by clk_sys flops
    without metastability filtering.
  * The output mux at the bottom of the wrapper drives `dout/hs/vs/de`
    from clk_sys-domain v2 outputs but those signals are consumed by
    ascal on `clk_out` — another unsynchronized crossing.
  * `fb_en` is a clk_sys config bit feeding the same mux; glitch-free in
    practice because it changes per-MISTER_FB-frame, but still
    technically unsynchronized.

## Original B4 plan (Phase 2 reference, deferred)

The rest of this document is the original full-FIFO plan from
2026-05-27. Kept as reference for if/when Phase 2 becomes needed.

## What B4 needs to deliver

Two async FIFOs straddling the wrapper boundary:

### Ingress FIFO  (clk_in → clk_sys)

  Width:  24 (din) + 1 (hs_in) + 1 (vs_in) + 1 (de_in) = 27 bits
  Write:  ce_pix_in on clk_in
  Read:   ce_pix_in_sync on clk_sys (gated by !empty)
  Depth:  16 entries should be plenty given the clock ratio
          (clk_vid ~ 5-20 MHz, clk_sys = 100 MHz on most cores).

  Tap the wptr/rptr to derive ce_pix_in_sync as the read-side
  "valid" pulse that v2 should see.

### Egress FIFO  (clk_sys → clk_out)

  Width:  24 (dout) + 1 (hs_out) + 1 (vs_out) + 1 (de_out) = 27 bits
  Write:  ce_pix_out on clk_sys (v2's emit pulse)
  Read:   ce_pix_out_sync on clk_out (gated by !empty)
  Depth:  16+ entries; size for HDMI clock vs pixel-emit-rate slack.

Both FIFOs must use **Altera dcfifo** with proper async Gray pointers
(or a hand-rolled dcfifo equivalent verified under
formal/cdc-lint). The Quartus megawizard pattern lives in
`pll_hdmi/` already as a reference for IP instantiation style.

### `fb_en` synchronizer

A two-flop synchronizer chain on clk_out for `fb_en`, since the bypass
mux at the wrapper exit reads it from the clk_out side after B4
(the bypass latch itself can stay on clk_in and feed the egress FIFO
through the same path as v2 output).

## What to NOT do in B4

  * Don't merge clk_sys into clk_in or clk_out at the wrapper. Keep
    them distinct so the FIFOs are the only crossings.
  * Don't try to put dcfifo inside vis_warp_v2 -- A explicitly designed
    v2 as a single-clock engine. The wrapper owns CDC.
  * Don't expose the FIFO depths as generics in the first cut. Pick a
    safe 16 deep, prove timing, then tune.

## Estimated effort

  * Half a day to instantiate dcfifo IPs and wire them.
  * Another half-day to verify under the wrapper smoke TB with three
    distinct clocks (10/13/7 ns periods, mutually prime).
  * Quartus timing analysis at B5 will tell us if depth is right.

## Resume markers

  * Wrapper code to modify: `sys/vis_warp.vhd` lines 259-272 (port map
    of u_v2.clk) and 343-366 (fb_en mux + output assignments).
  * TB to extend: `sys/vis_warp_wrapper_tb.vhd` lines 74-99 (the three
    clock processes -- change to distinct frequencies).
  * Reference dcfifo wrapper: copy pattern from existing Altera IP in
    `sys/pll_hdmi/` (note: those are PLLs, not dcfifos -- look at
    `ddr_svc.sv` or `vbuf_svc.sv` for an example of how the framework
    handles cross-domain handoffs today; both punt to ddr3 controller
    internal sync logic, which is NOT applicable here).
