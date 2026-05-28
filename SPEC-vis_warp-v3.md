# vis_warp v3 — Template_MiSTer-VIS integration spec

Written 2026-05-28 after the v1→v2 ghost chase
(`D:\deck\fpga\pacman-vis\HANDOFF-v1-to-v2-ghost-chase-2026-05-28.md`) and
the framework research that followed
(`~/.claude/projects/D--deck/memory/reference_mister_framework.md`).

This is the actively driving document for the vis_warp work going forward.
Open questions land here; locked decisions land in
`design_vis_warp_constraints.md` (memory).

## TL;DR — what changed and why

We were developing vis_warp inside the Galaga core's vendored `sys/`. That
was structurally wrong for three reasons:

1. **Project policy.** Template_MiSTer's README explicitly prohibits
   per-core sys/ modifications: *"All MiSTer cores have to include sys
   folder as is from this core."* Galaga's sys/ is overwritten wholesale
   by periodic "Update sys" commits (2021-09-16, 2023-03-15, 2024-05-27,
   2025-12-09). Anything we land there is ephemeral.
2. **Validation surface.** Galaga renders a real game frame. When we
   tested "warp on / warp off" we couldn't tell the difference from
   eyeballing a Galaga screen with k=2 curvature. The signal was lost in
   the picture content. We need a deterministic test pattern where
   straight lines become visibly curved.
3. **Honesty of the iteration loop.** "Did my bitstream actually load?"
   was unanswerable because we had no ground-truth handshake. The
   smoking-gun finding from the ghost chase — wrapper-bypass force-red
   still showed Galaga — pointed at MRA-to-rbf binding confusion that we
   never resolved.

**The reboot:**
- **Dev host** = `D:\deck\fpga\Template_MiSTer-VIS\` (the fork of upstream
  Template_MiSTer). The fork already has vis_warp's earlier work mirrored
  in. This is where framework changes belong.
- **Validation host** = `Template_MiSTer-VIS/rtl/mycore.v` upgraded to
  emit selectable deterministic test patterns. Vanilla picture = known
  pattern. Bow = unambiguous deviation.
- **Macro gate** = `\`ifdef MISTER_WARP`. Cores opt in via their .qsf.
  Default off. Matches established MISTER_FB / MISTER_SMALL_VBUF /
  MISTER_DISABLE_ADAPTIVE convention.
- **Galaga is the LAST validation step, not the first.** Once Template
  works, we "Update sys" Galaga's vendored sys/ from Template_MiSTer-VIS
  and confirm consumer behavior. Galaga gets MISTER_WARP defined in its
  .qsf.

## Locked architecture (unchanged from design_vis_warp_constraints.md)

- **Site C: pre-ascal, post-emu, source resolution, on `clk_video`.**
- 2-buffer M9K ping-pong, RGB888, ~66% M9K at typical arcade resolution.
- Whole frame buffered → unbounded bow range.
- ascal downstream handles upscale → bow scales naturally with output mode.
- OSD downstream of warp → stays unwarped (readable).
- 16-stage warp math pipeline (already implemented in
  `sys/vis_warp_v2_wp.vhd`).

Do not re-litigate. See `design_vis_warp_constraints.md`.

## What already exists in Template_MiSTer-VIS

| File | State | Action |
|---|---|---|
| `sys/vis_warp.vhd` | Wrapper with cmd_wr/cmd_in[15:0] interface, 3-bit opcode in cmd_in[15:13]. Matches shadowmask pattern. CDC NOT done (clk_sys = clk_in = clk_out aliased). | **Keep + harden.** Add MISTER_WARP gate around instantiation in sys_top.v. Close B4 CDC (below). |
| `sys/vis_warp_v2_wp.vhd` | 16-stage warp pipeline math, M9K ping-pong buffer. Engine. | **Keep as-is.** Tested under GHDL standalone. No changes needed for v3 cut. |
| `sys/vis_warp_pkg_v2.vhd` | Type packages. | Keep. |
| `sys/vis_warp_luts_pkg.vhd` | LUT data (sin/cos for warp math). | Keep. |
| `sys/vis_warp_wrapper_tb.vhd` | GHDL testbench for the wrapper. | Keep + extend (B4 will want distinct clock frequencies). |
| `sys/B4_TODO.md` | Async FIFO CDC plan, half-implemented. | Execute (see Task 4). |
| `sys/vbuf_svc.sv` | Multi-channel DDR3 arbiter, abandoned (bandwidth + CDC + arbiter bugs). | **Retire after Template ships.** Not used in v3. |
| `sys/ddr_svc.sv` | DDR3 service module from v1 architecture. | **Verify retire-able after Template ships.** |
| `rtl/mycore.v` | Stock cosine+LFSR demo emu. 288×224 / 320×240 timing. | **Upgrade with selectable test patterns** (Task 6). |
| `sys/sys_top.v` | Currently has the in-tree fork of vis_warp wiring from v1/v2 era. | **Audit + rewrite the wiring block** to MISTER_WARP-gated form. |

## Five-layer pattern, applied to vis_warp

Per `reference_mister_framework.md`, every framework video processor follows
a five-layer pattern. For vis_warp v3:

### Layer 1 — RTL module

Already exists as `sys/vis_warp.vhd` (wrapper) + `sys/vis_warp_v2_wp.vhd`
(engine). Port shape is right (modeled on shadowmask). **Gap: B4 CDC.**

### Layer 2 — Pipeline slot

Pre-ascal, post-emu, on `clk_video`. In sys_top.v (upstream as of
2026-05-28), this means interposing on the signals that drive ascal's
`i_r/i_g/i_b/i_hs/i_vs/i_de` ports (currently `hr_out/hg_out/hb_out/
hhs_fix/hvs_fix/hde_emu` per sys_top.v:751–757).

Wiring pattern:
```verilog
`ifdef MISTER_WARP
  wire [7:0] warp_r, warp_g, warp_b;
  wire       warp_hs, warp_vs, warp_de;

  vis_warp u_vis_warp (
    .clk_sys    (clk_sys),
    .clk_in     (clk_ihdmi),     // pre-ascal slot: source pixel clock
    .clk_out    (clk_ihdmi),     // unused at site C but kept for contract
    .cmd_wr     (viswarp_wr),
    .cmd_in     (viswarp_data),
    .ce_pix_in  (ce_hpix),
    .r_in       (hr_out),
    .g_in       (hg_out),
    .b_in       (hb_out),
    .hs_in      (hhs_fix),
    .vs_in      (hvs_fix),
    .de_in      (hde_emu),
    .r_out      (warp_r),
    .g_out      (warp_g),
    .b_out      (warp_b),
    .hs_out     (warp_hs),
    .vs_out     (warp_vs),
    .de_out     (warp_de),
    .ce_pix_out ()  // ascal's i_ce is ce_hpix
  );

  // ascal sees warp's output instead of emu's direct output:
  wire [7:0] ascal_ir = warp_r;
  wire [7:0] ascal_ig = warp_g;
  wire [7:0] ascal_ib = warp_b;
  wire       ascal_ihs = warp_hs;
  wire       ascal_ivs = warp_vs;
  wire       ascal_ide = warp_de;
`else
  wire [7:0] ascal_ir = hr_out;
  wire [7:0] ascal_ig = hg_out;
  wire [7:0] ascal_ib = hb_out;
  wire       ascal_ihs = hhs_fix;
  wire       ascal_ivs = hvs_fix;
  wire       ascal_ide = hde_emu;
`endif
```

Then ascal's port_map references `ascal_ir/ig/ib/ihs/ivs/ide`.

### Layer 3 — HPS opcode

vis_warp.vhd currently uses opcode `0x45`. Free in upstream master
(`0x42`–`0x4F` unallocated). **Keep 0x45** unless we conflict.

Decoder addition to sys_top.v:354–520:
```verilog
if(cmd == 'h45) {viswarp_wr, viswarp_data} <= {1'b1, io_din};
```
With companion declarations:
```verilog
reg [15:0] viswarp_data;
reg        viswarp_wr = 0;
// (set viswarp_wr <= 0 each clk_sys cycle in the strobe-clear block)
```

Sub-register encoding (already in vis_warp.vhd, preserved):
- `cmd_in[15:13]=000` — flags: `[0]=enable, [1]=bilinear, [2]=bloom_en, [3]=scan_en`
- `cmd_in[15:13]=001` — curvature: `[2:0]=curvature_k` (0..7)
- `cmd_in[15:13]=010` — bloom (reserved, dead-but-kept)
- `cmd_in[15:13]=011` — scanlines (reserved, dead-but-kept)
- `cmd_in[15:13]=111` — reset_internal pulse

For v3 we drive 000 and 001 from local Quartus parameters / static defaults
until userland (Layer 4) lands. The wrapper already handles the unused ops
gracefully.

### Layer 4 — Userland C handler

**OUT OF SCOPE for v3.** Defer to v4 once RTL is proven on hardware.

When we do land it:
- `Main_MiSTer/user_io.h`: add `UIO_SET_VISWARP 0x45`
- `Main_MiSTer/video.cpp`: add `video_apply_viswarp_enable()`,
  `video_apply_viswarp_curvature()`, per-core persistence
  `<core>_viswarp.cfg`
- Two coordinated PRs (Template + Main).

For now, the RTL can be driven by Quartus-time defaults baked into the
`viswarp_data` reg-init, or by an enable bit pulled high via a test fixture.

### Layer 5 — Config surface

OUT OF SCOPE for v3. (Comes with Layer 4.)

## Critical work — B4 CDC

Per `sys/B4_TODO.md`, the wrapper aliases `clk_sys = clk_in = clk_out`.
That's safe under GHDL (single clock anyway) but unsafe on real hardware
because:
- Pixel data on `clk_in` (= `clk_video`) is sampled by `clk_sys` flops
  without metastability filtering.
- Output mux drives `dout/hs/vs/de` from clk_sys flops but they're consumed
  on `clk_out` (= ascal's `clk_ihdmi`).

**At site C specifically** (clk_in = clk_out = `clk_ihdmi`), the *output*
crossing collapses to identity (same clock), so the egress FIFO can be
elided. Only the ingress (clk_in → clk_sys for config-register reads) is
real CDC. That simplifies B4.

Two paths:
- **Minimal (Phase 1)**: 2-flop synchronizer chain for `reg_enable`,
  `reg_curvature`, and `v2_reset` from clk_sys to clk_in. No FIFOs needed
  because the data path stays entirely on clk_in inside `vis_warp_v2_wp`.
- **Full B4 (Phase 2)**: async dcfifo if any downstream consumer adds an
  actual clock-domain split. Defer.

For v3 cut: **Phase 1 only.** Two-flop synchronizer on the three control
signals, all data on clk_in. Document the simplification in vis_warp.vhd
comments so the future-self knows why dcfifos aren't there.

## Validation phases

### Phase 0 — audit existing tree (Task 12, new)

Walk `D:\deck\fpga\Template_MiSTer-VIS\sys\` end-to-end. Compare against
upstream Template_MiSTer master. Identify what's been forked, what should
sync from upstream cleanly, what's our own. Output: a one-pager mapping.

### Phase 1 — RTL hardening

- Close B4 CDC (Phase 1 minimal: 2-flop synchronizers).
- Add `MISTER_WARP` macro gate around vis_warp instantiation in sys_top.v.
- Rewrite the wiring block (currently has v1/v2 detritus) per the pattern
  above.

### Phase 2 — Test pattern upgrade

`rtl/mycore.v` already generates timing and a cosine+LFSR pattern. Add
OSD-selectable modes:
- 0: cosine+LFSR (existing)
- 1: grid — 5px on, 5px off, on both axes
- 2: horizontal gradient — full-saturation R/G/B sweeps left-to-right,
  vertical bars to mark column positions
- 3: center crosshair — single-pixel-wide cross at frame center, white
  on black
- 4: SMPTE color bars
- 5: STILL — solid mid-gray (for "is anything happening" tests)

Selection routes through CONF_STR status[2:0] → mycore's existing port.
Default 1 (grid) — most visually obvious for warp validation.

### Phase 3 — baseline build (MISTER_WARP unset)

Quartus build with macro unset. Confirms:
- Template + upgraded mycore + new wiring block compile clean
- vis_warp present in source but bypassed
- Test patterns render correctly on hardware

**Ground-truth handshake**: load on FPGA, see grid pattern, navigate
mycore's OSD, switch to crosshair, see crosshair. If we can switch
patterns via OSD we KNOW our bitstream is loaded. End of "is it really
running" debate forever.

### Phase 4 — k=0 identity (MISTER_WARP defined, curvature=0)

Build with macro set, curvature_k=0 hardcoded in the wrapper defaults.
Confirms:
- M9K buffer captures + reads cleanly
- Source-dim auto-detect locks to mycore's pattern resolution
- Wrapper port shape works
- Site-C wiring functions
- Picture identical to Phase 3 baseline (warp_en=1 but k=0 = identity)

### Phase 5 — k=2 visible bow

Build with curvature_k=2. Grid pattern's straight lines should curve
visibly into arcs. If this works: vis_warp is real on silicon.

### Phase 6 — k=7 unmissable bow

Confirms math scales. Should look extreme/clownish.

### Phase 7 — SignalTap probes (parallel with Phase 4-6)

Wire SignalTap II in Quartus:
- emu's `video` output, `HSync`/`VSync`/`HBlank`/`VBlank`
- vis_warp `r_in/g_in/b_in/hs_in/vs_in/de_in` (input side)
- vis_warp `r_out/g_out/b_out/hs_out/vs_out/de_out` (output side)
- ascal `i_r/i_g/i_b/i_hs/i_vs/i_de` (downstream)
- Optional: `viswarp_wr`, `viswarp_data`, `reg_enable`, `reg_curvature`
  (config flow)

Sample clock: `clk_ihdmi` (where vis_warp lives).
Trigger: rising edge of `vs_in`.
Sample depth: at least one frame of source pixels (~64K samples at
288×224).

`.stp` file is per-session scratch — don't commit. Note: SignalTap may
need a license — verify with Quartus install.

### Phase 8 — Sync to Galaga as consumer

- Copy `Template_MiSTer-VIS/sys/*` → `Galaga/sys/*`. The "Update sys"
  pattern, but reversed (we're the framework now).
- Define `MISTER_WARP` in Galaga's .qsf.
- Build. Galaga renders normally with k=0, bowed with k=2.

If this works: vis_warp is real framework-level work, and we have a
clean path to upstream.

### Phase 9 — Verilator harness (optional, parallel)

Write a tiny Verilator wrapper around `vis_warp_v2_wp` that feeds a
synthetic 288×224 RGB frame and dumps the output as PPM. Compare PPMs
at k=0, k=2, k=7. Visual confirmation of the math separate from any
FPGA stack. **This already exceeds the org's standard** — there's no
framework testbench upstream.

## What survives, what gets retired

### Survives unchanged
- `sys/vis_warp_v2_wp.vhd` — engine
- `sys/vis_warp_pkg_v2.vhd` — types
- `sys/vis_warp_luts_pkg.vhd` — LUTs
- `sys/vis_warp_wrapper_tb.vhd` — GHDL TB
- `sys/B4_TODO.md` — keep as reference for the deferred full-FIFO B4
- Most of `sys/` from upstream Template

### Survives, but hardened
- `sys/vis_warp.vhd` — add 2-flop synchronizers per Phase 1 B4
- `sys/sys_top.v` — rewrite the vis_warp wiring block, add MISTER_WARP
  gate, add opcode 0x45 decoder
- `rtl/mycore.v` — add selectable test patterns

### Retired (after Phase 8)
- `sys/vbuf_svc.sv` — DDR3 arbiter, dead code path
- `sys/ddr_svc.sv` — verify removable

### Deliberately out of scope (deferred to v4)
- Main_MiSTer userland integration (UIO opcode handler, OSD menu, INI)
- Submitting upstream PRs to MiSTer-devel/Template_MiSTer or Main_MiSTer
- B4 full async-dcfifo CDC (Phase 1 minimal synchronizers cover v3)

## Open questions

1. **Does Phase 1 minimal B4 (2-flop sync) hold timing under Quartus?**
   The wrapper already does single-flop crossing in production today; the
   Phase 1 minimal upgrade is strictly safer. But if Quartus complains
   about constraint coverage on the synchronized signals, we may need to
   add `set_false_path` SDC entries. Verify during Phase 3 build.

2. **mycore.v's resolution.** Current code does 288×224 (NTSC) and
   320×240. Should vis_warp's source-dim auto-detector latch to whatever
   mycore is producing, or should we hardcode 288×224 for v3? Lean
   hardcode for simplicity; revisit if needed.

3. **OSD pattern selector wiring.** mycore takes a `pal`/`scandouble`
   input today. Adding 3 bits of pattern-select via status[] is
   straightforward but means touching the CONF_STR in
   `Template_MiSTer-VIS/Template.sv`. Confirm the right place during
   Phase 2.

4. **License: SignalTap II availability.** Quartus Lite (free edition)
   does NOT include SignalTap II — it ships with Quartus Standard /
   Pro / Subscription. Verify Matt's Quartus install. If unavailable,
   Phase 7 needs a Plan B (e.g., LED debug, GPIO header probes, or
   driving an unused HDMI pixel region with debug signals).

5. **MRA / .rbf binding for Template_MiSTer-VIS.** Template doesn't ship
   with an arcade MRA — it's loaded as a "computer" or "console" style
   core. Confirm the load path. If it works like other Template forks
   (e.g., InputTest_MiSTer), load is straightforward via the Cores menu.

## Files this spec authorizes touching

- `D:\deck\fpga\Template_MiSTer-VIS\sys\vis_warp.vhd`
- `D:\deck\fpga\Template_MiSTer-VIS\sys\sys_top.v` (vis_warp wiring block
  + opcode decoder line only — rest is upstream-tracked)
- `D:\deck\fpga\Template_MiSTer-VIS\rtl\mycore.v`
- `D:\deck\fpga\Template_MiSTer-VIS\Template.sv` (CONF_STR for pattern
  selector, MISTER_WARP define for test builds)
- `D:\deck\fpga\Template_MiSTer-VIS\sys\B4_TODO.md` (add Phase 1
  minimal-synchronizer plan)
- New: `D:\deck\fpga\Template_MiSTer-VIS\HANDOFF-vis_warp-v3-*.md`
  (running session handoffs)

Anything in `sys/` other than `vis_warp.vhd`, `sys_top.v` (the bounded
block), or vis_warp's own helper files: **don't touch**. That's
upstream-tracked and changes there should come from upstream syncs.

## Resume state

Tasks 1, 2, 3 of TaskList completed in this session (memory + index +
spec). Tasks 4–11 are the actual work.

Recommended next session order:
- Task 12 (new): Phase 0 audit
- Task 4: Phase 1 B4 minimal-synchronizer
- Task 5: MISTER_WARP gate
- Task 6: mycore.v patterns
- Task 7: baseline build
- Task 8: k=0 identity build
- Task 9: k=2 visible bow
- Task 10: SignalTap (parallel with 7-9 once a build is on hw)
- Task 11: Galaga consumer sync

Reset of session continuity: the Galaga tree at
`D:\deck\fpga\galaga\Arcade-Galaga_MiSTer\` still has the v2 diagnostic
edits uncommitted (force-red emitter, etc.). **Don't touch the Galaga
tree until Phase 8.** Either `git stash` it for evidence or
`git reset --hard b6d34f9` to return to morning-known-good. Either way,
do NOT work in that tree under v3.

The shared memory `design_vis_warp_constraints.md` is unchanged and still
authoritative on the architecture. This spec is the *workflow* layer
above it.
