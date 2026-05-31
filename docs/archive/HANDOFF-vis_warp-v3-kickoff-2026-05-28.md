> **📦 ARCHIVED — superseded session handoff.** "Ready for first Quartus build"
> — long since built, validated, and shipped (many commits past). Kept for
> history. The locked architecture it kicked off lives in
> [`SPEC-vis_warp-v3.md`](../../SPEC-vis_warp-v3.md); current project state:
> [`STATUS.md`](../../STATUS.md).

---

# vis_warp v3 kickoff — RTL complete, ready for first Quartus build

Session 2026-05-28 morning. Following the v1→v2 ghost chase
(`D:\deck\fpga\pacman-vis\HANDOFF-v1-to-v2-ghost-chase-2026-05-28.md`)
and the framework research that landed
(`~/.claude/projects/D--deck/memory/reference_mister_framework.md`).

## What's done

**Memory + spec (durable, committed by writing):**

- `reference_mister_framework.md` (memory) — the integration model we
  were missing for v2
- `MEMORY.md` (memory index) — entries for framework reference + v3 spec
- `SPEC-vis_warp-v3.md` (project tree) — workflow doc with phases 0–9

**Tree audit (Phase 0):**

- Fork on upstream `f35083f` (2026-05-13). Zero lag.
- 12 files diverged from upstream, all explainable.
- `sys/vis_warp_v2.vhd` (stale, superseded by v2_wp) deleted.

**RTL work this session (uncommitted):**

| File | What changed |
|---|---|
| `sys/vis_warp.vhd` | B4 Phase 1 CDC: 2-flop synchronizers on `reg_enable`, `reg_curvature` from clk_sys → clk_in; toggle+edge-detect for the `reset` pulse. `preserve` attributes on the synchronizer chains. Dev-time defaults documented for phases 4–6. |
| `sys/sys_top.v` | (1) Removed SITE A vis_warp instance and the `hdmi_*_warp` wiring downstream; csync_hdmi reverted to `hdmi_*_osd`. (2) Removed `vbuf_svc` instance + `vbuf_vw_*`/`vbuf_ascal_*` wires; ascal's avl_* now connects to `vbuf_*` directly (matches upstream). (3) Added SITE C vis_warp insertion under `` `ifdef MISTER_WARP `` between emu output (`r_out/g_out/b_out/hs_fix/vs_fix/de_emu`) and ascal input (`hr_out/hg_out/hb_out/hhs_fix/hvs_fix/hde_emu`). Default off — when unset, paths collapse to upstream pass-through. |
| `sys/sys.qip` | `vbuf_svc.sv` removed from file list. |
| `sys/vbuf_svc.sv` | **Deleted.** Dead code at site C. |
| `rtl/mycore.v` | New `pattern[2:0]` input. Eight selectable test patterns: cosine (0, original), grid 16px (1, primary warp test), vbars 32px (2), gradient (3), crosshair (4), gray50 (5), black (6), white (7). |
| `Template.sv` | CONF_STR option `O[13:11],Pattern,...` added. mycore instantiation wires `status[13:11]` to the new pattern input. |
| `sys/B4_TODO.md` | Updated: Phase 1 minimal landed, Phase 2 full dcfifo deferred. Justified deferral (at site C `clk_out = clk_in = clk_ihdmi`, egress crossing collapses). Open question on SDC flagged. |

**Pre-existing uncommitted state preserved:**

- `sys/vis_warp_v2_wp.vhd` was rewritten last session for site C (DDR3
  ping-pong → M10K sliding-window). +280/−458 line diff vs morning's
  `09e5130`. **Confirmed clean** — no force-red, no debug-emitter
  leftovers from the ghost chase. This is the legitimate site-C engine
  rewrite. Keep as-is.

## Open questions still tagged (from spec)

1. **SDC for sync chains** — if Quartus complains about unconstrained
   paths on the CDC signals during the Phase 3 baseline build, add a
   `sys/vis_warp.sdc` (do NOT edit `Template.sdc`) with `set_false_path`
   entries on `reset_toggle_s*`, `reg_enable_s*`, `reg_curvature_s*`.
2. **SignalTap II — RESOLVED 2026-05-28.** Confirmed present in
   Matt's Quartus Lite 17.0 install: `quartus_stp.exe` and
   `quartus_stp_tcl.exe` exist under `bin64/`. Quartus Lite ~13–17
   bundle SignalTap for Cyclone V (Intel pulled it from Lite ~20.1+).
   Phase 7 fully unblocked.
3. **mycore source dim auto-detect vs hardcoded 288×224** — leave
   auto-detect for now; revisit if v2_wp's detector doesn't lock cleanly
   on mycore's non-arcade-shaped 530-wide timing.
4. **Template_MiSTer-VIS load path** — confirm during Phase 3 that the
   resulting .rbf loads via the Cores menu (Template ships as a
   non-arcade core, not an MRA).

## Build instructions

### Phase 3 — baseline (MISTER_WARP unset)

Goal: confirm the upgraded mycore + new sys_top wiring compiles clean
and the pattern selector works on hardware. Vis_warp present in source
but not instantiated.

1. Open `Template_MiSTer-VIS/Template_Q13.qpf` in Quartus 13.x, or
   `Template.qpf` in Quartus 17 / newer (matches `LAST_QUARTUS_VERSION`
   in `Template.qsf`).
2. Do NOT add MISTER_WARP to the .qsf for this build.
3. Processing → Start Compilation. Expect:
   - Clean Analysis & Elaboration on `mycore.v`, `Template.sv`,
     `sys_top.v`.
   - vis_warp.vhd, vis_warp_v2_wp.vhd, etc. analyzed but UNUSED
     (unused-entity warnings expected — harmless).
   - vbuf_svc and ddr_svc warnings? ddr_svc is still upstream-live;
     vbuf_svc is gone; should be no warnings about either.
4. Drop the produced `Template_*.rbf` on SD card. Load via Cores menu.
5. On hardware:
   - Should see mycore's cosine pattern (default `pattern=0`).
   - Open OSD (F12 / Menu key on USB keyboard).
   - Navigate to the new "Pattern" option. Change to "Grid" — should
     see a 16-pixel cross-hatch grid on screen.
   - Cycle through patterns: vbars, gradient, crosshair, gray50,
     black, white. All should render cleanly.
   - **This is the ground-truth handshake.** If pattern-switching works
     via OSD, the bitstream is loaded. End of "is it really running"
     debate forever.

### Phase 4 — MISTER_WARP defined, k=0 identity

Goal: confirm vis_warp captures + reads cleanly and identity-passes.
Picture should be identical to Phase 3.

1. Edit `Template.qsf`. Add a new line:
   ```
   set_global_assignment -name VERILOG_MACRO "MISTER_WARP=1"
   ```
2. Edit `sys/vis_warp.vhd` initial values (lines ~94–95):
   ```vhdl
   signal reg_enable     : std_logic := '1';                       -- ENABLED
   signal reg_curvature  : std_logic_vector(2 downto 0) := "000";  -- k=0 identity
   ```
3. Recompile. Quartus should now instantiate `vis_warp_v2_wp`. Expect:
   - ~165 M10K blocks consumed by pixel_buf at MAX_SRC_W=512,
     N_LINES=128 (~30% of 553 available).
   - Timing may need attention; if Quartus reports CDC warnings on
     reg_enable_s1/curvature_s1/reset_toggle_s1, add `vis_warp.sdc`
     per open question #1.
4. Hardware: should look IDENTICAL to Phase 3 (warp_en=1 but k=0 = no
   distortion). If picture vanishes or corrupts, that's the signal
   that v2_wp's M10K buffer or auto-detect isn't behaving — debug at
   that point. SignalTap is the right tool here.

### Phase 5 — k=2 visible bow (smoking gun)

Goal: prove the warp math reaches silicon.

1. Edit `sys/vis_warp.vhd` initial value:
   ```vhdl
   signal reg_curvature  : std_logic_vector(2 downto 0) := "010";  -- k=2
   ```
2. Recompile, reload.
3. Switch mycore to Grid pattern via OSD.
4. **Straight grid lines should curve into arcs.** If yes: vis_warp is
   real on silicon, the v3 reboot is validated. If no, but Phase 4 was
   identity-clean: the warp math isn't engaging — bisect with SignalTap
   on `warp_en`/`curvature_k` inputs to v2_wp.

### Phase 6 — k=7 unmissable bow

Cosmetic confirmation that k scales. Picture should look extreme.

### Phase 7 — SignalTap (parallel with 4–6)

If Quartus install has SignalTap II:

1. Tools → SignalTap II Logic Analyzer.
2. Add probes:
   - `r_out`, `g_out`, `b_out`, `hs_fix`, `vs_fix`, `de_emu` (emu side)
   - `vw_r`, `vw_g`, `vw_b`, `vw_hs`, `vw_vs`, `vw_de` (vis_warp out)
   - `vis_warp_cmd_wr`, `vis_warp_cmd_data` (config flow)
   - Optional: u_vis_warp_siteC's internal `reg_enable_s2`,
     `reg_curvature_s2` after the synchronizers
3. Sample clock: `clk_vid`. Trigger: rising edge of `vs_fix`.
4. Recompile (.stp adds instrumentation), load, capture. `.stp` is
   per-session scratch — do not commit.

### Phase 8 — Galaga consumer sync

After Template is green:

1. `cp -r Template_MiSTer-VIS/sys/* galaga/Arcade-Galaga_MiSTer/sys/`
   (overwrites Galaga's vendored sys/ — the "Update sys" pattern, but
   we're the framework now).
2. Edit Galaga's `.qsf` to add `MISTER_WARP=1` macro.
3. Compile Galaga. Render normally with vis_warp.vhd initializers
   at k=0, bowed at k=2.
4. **This is the validation that framework-level integration works
   in a real game core**, not just the demo.

## What's NOT in scope this session

- Quartus build itself (no Quartus access from this side; Matt drives).
- Main_MiSTer userland (UIO opcode handler, OSD menu) — deferred to v4.
- Upstream PR submission to MiSTer-devel — deferred to v4.
- B4 Phase 2 full async dcfifo — deferred per spec.
- Galaga work — frozen until Phase 8.

## Suggested next-session start

Pick up Task 7 (Phase 3 baseline build). If Quartus is green and
hardware shows the pattern selector working, that's the unblock for
everything else. From there, Phases 4 / 5 are quick iterations on the
vis_warp.vhd defaults.

## State snapshot (uncommitted)

```
M Template.sv
M rtl/mycore.v
M sys/B4_TODO.md
M sys/sys.qip
M sys/sys_top.v
D sys/vbuf_svc.sv
M sys/vis_warp.vhd
D sys/vis_warp_v2.vhd
M sys/vis_warp_v2_wp.vhd     (site-C rewrite, pre-existing)
?? SPEC-vis_warp-v3.md
?? HANDOFF-vis_warp-v3-kickoff-2026-05-28.md   (this file)
?? sta_query.tcl                                (gitignored Quartus scratch)
?? worst_paths.txt                              (gitignored Quartus scratch)
```

Recommend committing before the Phase 3 build so we have a clean
"pre-build" checkpoint. Suggested commit message:

> vis_warp v3: site-C reboot with MISTER_WARP gate, mycore patterns, B4 CDC Phase 1
>
> Reboots vis_warp from per-core sys/ edits (off-spec, wiped on sync)
> to framework-level integration in Template_MiSTer fork. Adds
> MISTER_WARP macro gate so cores opt in via .qsf. Removes SITE A
> wiring + vbuf_svc (DDR3 arbiter was bandwidth-ceiling-limited).
> Installs 2-flop CDC synchronizers in vis_warp.vhd wrapper.
> Upgrades mycore.v with 8 selectable test patterns. Adds SPEC doc.
> Ready for first Quartus build per HANDOFF-vis_warp-v3-kickoff.
