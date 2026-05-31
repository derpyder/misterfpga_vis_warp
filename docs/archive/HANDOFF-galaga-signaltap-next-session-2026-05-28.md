> **📦 ARCHIVED — superseded session handoff.** Kept for the lesson, not as live
> state. The Galaga `MISTER_FB=1` dead-port finding (ASCAL reads from DDR and
> ignores the live `i_r/i_g/i_b` input where SITE C sits) is captured in
> [`LIMITATIONS.md`](../../LIMITATIONS.md) §3 and the framework-reference memory.
> Current project state: [`STATUS.md`](../../STATUS.md).

---

# ⚠️ RESOLVED 2026-05-28 — DO NOT NEED SIGNALTAP. ROOT CAUSE FOUND.

**The Galaga "vanilla" mystery is SOLVED by static analysis + a force-red
hardware test. SignalTap was never needed.**

ROOT CAUSE: Galaga is a rotated vertical arcade core. It writes its video
into a DDR framebuffer (`screen_rotate`, MISTER_FB=1, no_rotate=0) and
ASCAL reads pixels from DDR — **ignoring its live i_r/i_g/i_b input where
SITE C vis_warp sits.** vis_warp's output landed on a dead port. RTL was
never broken.

PROOF: pure-constant force-red emitter in vis_warp → VANILLA on rotated
Galaga → flipped Orientation to Horizontal in OSD → **RED**. Confirmed on
HDMI hardware 2026-05-28.

Full constraint + fix paths now locked in
`~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md`
(see the 🔴 "ROTATED VERTICAL ARCADE CORES BYPASS SITE C" section).

The rest of this doc is the pre-resolution investigation log — kept for
history. The "needs SignalTap first" framing below is SUPERSEDED.

---

# Galaga consumer integration — SignalTap handoff (SUPERSEDED)

Written 2026-05-28 ~6:50 PM after ~8 hours of attempts to get
vis_warp working on Galaga. **Template works. Galaga shows vanilla
regardless of what we try.** Next session must wire SignalTap before
any more speculative RTL changes.

## State at handoff

| Tree | State | Status |
|---|---|---|
| `D:\deck\fpga\Template_MiSTer-VIS\` | v3.1 bilinear (no SCALE_PREWARP, no sync delay) | Validated working on hardware. Has docs (README, LIMITATIONS, ROADMAP, CONTRIBUTING, CHANGELOG, POSTMORTEM, SPEC). |
| `D:\deck\fpga\galaga\Arcade-Galaga_MiSTer\` | v3.1 vis_warp + sys_top.v wired PRE-scanlines (latest architectural attempt) | **Hardware shows vanilla.** Build compiles clean, vis_warp elaborates, but no visible warp on screen. |

## Confirmed facts (don't re-verify these)

1. **Template works**: hardware photos `1242.jpg`, `240.png` show clear barrel-warped dome with bilinear-smooth curves.
2. **Galaga build compiles successfully**: `Fitter Status : Successful`, Logic ALMs ~18K (43%), RAM Blocks ~322 (58%), DSP ~82 (73%).
3. **vis_warp IS elaborated in Galaga's build**: map.rpt confirms `vis_warp:u_vis_warp_siteC` + `vis_warp_v2_wp:u_v2` hierarchy.
4. **MISTER_WARP=1 IS in `Arcade-Galaga.qsf`**: line ~23, `set_global_assignment -name VERILOG_MACRO "MISTER_WARP=1"`.
5. **`direct_video=0` in user's MiSTer.ini**: ASCAL path should be active, not direct_video bypass.
6. **`vis_warp.vhd` defaults are correct**: `reg_enable='1'`, `reg_curvature="010"` (k=2), `reg_bilinear='1'`.
7. **`HDMI_FREEZE = 0` in Galaga's emu** (line 190 of `arcade-galaga.sv`): ASCAL is NOT being externally frozen.
8. **The Galaga rbf on SD IS the latest build**: `Galaga_20260528.rbf` (3.4 MB), built at 18:39 today. Other Galaga rbf files renamed to `.bak` so MiSTer's prefix matcher picks ours.

## What we tried (chronological, all FAILED on Galaga)

### Sync delay attempts (also failed on Template — see POSTMORTEM)

| Attempt | Approach | Galaga result |
|---|---|---|
| v3.3 | Counter-based FSM, regenerated output raster delayed by N/2 input lines | 1 FPS on Template (didn't reach Galaga sync) |
| v3.3b | 65536×4-bit FIFO buffering input sync, popped 49152 cycles delayed | Vanilla on Galaga (and Template went 1 FPS too) |
| v3.3b bisect step 1 | SYNC_FIFO_LATENCY=1 (~zero delay, just exercises FIFO infrastructure) | Vanilla on Galaga (suggests FIFO infra itself doesn't work in our pipeline) |

Postmortem: `POSTMORTEM-v3.3-sync-delay-2026-05-28.md`. v3.3+ is OFF the table until proper simulation infrastructure exists. **Don't retry sync delay without sim+SignalTap.**

### Galaga-specific attempts (current task)

After reverting sync delay attempts, we focused on getting BASIC v3.2 (bilinear + SCALE_PREWARP, no sync delay) working on Galaga.

| Attempt | Tap point | Force-red gating | Result |
|---|---|---|---|
| 1. Post-scanlines SITE C | `vga_data_sl, vga_*_sl, vga_ce_sl` → vis_warp → `hr_out` | none (real warp math) | Vanilla |
| 2. Post-scanlines + force-red emitter | same | `if ce_pix and s16_de` | Vanilla |
| 3. Post-scanlines + unconditional red | same | NONE (concurrent assigns) | **NEVER actually tested in isolation — jumped past it to investigate direct_video** |
| 4. Investigated direct_video bypass mux | n/a | n/a | direct_video=0 confirmed, NOT the cause |
| 5. Pre-scanlines SITE C (architectural fix) | raw `r_out, g_out, b_out, hs_fix, vs_fix, de_emu, ce_pix` → vis_warp → scanlines `din/hs_in/vs_in/de_in` | none (real warp math, v3.1 base, no SCALE_PREWARP) | Vanilla |

Current Galaga `sys_top.v` state: attempt 5 (pre-scanlines wiring) is in place.

### Diagnostic gaps (this is what next session must fix)

- **Never actually validated attempt #3** (unconditional red without any gating). User reported "vanilla" but that was attempt #2 (gated force-red), not #3.
- **No SignalTap probes** on Galaga to capture actual signal behavior.
- **No oscilloscope/logic-analyzer data** on the wires going into ASCAL.
- **Don't know what `ce_pix` actually does in Galaga** at clk_vid rate.
- **Don't know if our pipeline's output sync alignment is acceptable to ASCAL** for Galaga's specific timing.

## Hypotheses still on the table (RANK by likelihood)

1. **vis_warp's pipeline ce_pix gating misaligns with Galaga's signal timing.** Galaga's ce_pix may have a different duty cycle / phase relationship to clk_vid than Template's mycore-driven ce_pix. The pipeline advances on ce_pix='1' which captures sync; if ce_pix is high every cycle (or every other cycle) at the wrong moments, the pipeline's output sync might never produce a valid frame edge for ASCAL.
2. **vis_warp's output sync timing is off by a pipeline-delay amount that breaks ASCAL's lock.** Pipeline delays sync by ~16-17 stages. Template's ASCAL handles this fine (we saw it work). Galaga's ASCAL might not, for reasons we don't yet understand.
3. **There's a downstream wiring we missed** that overrides hr_out / hg_out / hb_out in Galaga's sys_top.v. We've grep'd for direct assigns; nothing obvious. But Quartus might be optimizing something weird.
4. **scanlines module modifies signal timing** in ways vis_warp's output sync didn't anticipate. Even with vis_warp pre-scanlines (attempt 5), scanlines processes vis_warp's output before downstream consumers see it.
5. **The `Galaga_20260528.rbf` MiSTer is loading is not actually our latest build.** Stale cached version somehow. Unlikely given timestamps but worth verifying.

## What next session MUST do FIRST (in order)

### Step 0: Validate "vanilla" actually means what we think

Before any code changes, get a PHOTO of Galaga "vanilla" loaded from our build. Confirm there's no subtle warp the user is missing because it's too small to see. If picture matches the unmodified upstream Galaga pixel-for-pixel, OK. If subtly different, that's already useful data.

### Step 1: Verify rbf provenance

On the MiSTer device, SSH in:
```bash
md5sum /media/fat/_Arcade/cores/Galaga_20260528.rbf
```

Compare to MD5 of `D:/deck/fpga/galaga/Arcade-Galaga_MiSTer/output_files/Galaga_20260528.rbf`. If they don't match, the SD card has a stale rbf. If they match, MiSTer IS loading our build.

### Step 2: Wire SignalTap

SignalTap II IS installed (Quartus Lite 17.0.2 has it — `bin64/quartus_stp.exe` confirmed earlier). 

In Quartus, with the Galaga project open:
- Tools → SignalTap II Logic Analyzer
- Create a new .stp file (e.g., `galaga_viswarp.stp` — DO NOT commit, scratch only)
- Sample clock: `clk_vid` (the source pixel clock — confirmed via `assign clk_ihdmi = clk_vid;`)
- Sample depth: 4K samples (~one Galaga frame at 288×224)

Probe nodes (in priority order):
1. **Input to vis_warp** (confirm signals are reaching it):
   - `r_out`, `g_out`, `b_out` (raw emu output)
   - `hs_fix`, `vs_fix`, `de_emu`, `ce_pix`
2. **Inside vis_warp** (confirm pipeline is running):
   - `vis_warp:u_vis_warp_siteC|reg_enable_s2`
   - `vis_warp:u_vis_warp_siteC|reg_curvature_s2`
   - `vis_warp:u_vis_warp_siteC|reg_bilinear_s2`
   - `vis_warp:u_vis_warp_siteC|u_v2|cnt_x_w`
   - `vis_warp:u_vis_warp_siteC|u_v2|cnt_y_w`
   - `vis_warp:u_vis_warp_siteC|u_v2|s16_pixel`
   - `vis_warp:u_vis_warp_siteC|u_v2|s16_de`
3. **Output of vis_warp** (confirm output port is driven):
   - `vw_r`, `vw_g`, `vw_b`, `vw_hs`, `vw_vs`, `vw_de`
4. **scanlines input** (confirm vis_warp output reaches scanlines):
   - `sl_din`, `sl_hs_in`, `sl_vs_in`, `sl_de_in`
5. **scanlines output** (confirm scanlines passes through):
   - `vga_data_sl`, `vga_hs_sl`, `vga_vs_sl`, `vga_de_sl`, `vga_ce_sl`
6. **ASCAL input** (confirm ASCAL receives data):
   - `hr_out`, `hg_out`, `hb_out`, `hhs_fix`, `hvs_fix`, `hde_emu`, `ce_hpix`

Trigger: rising edge of `vs_fix` (frame start). Pre-trigger position.

Rebuild Galaga with SignalTap enabled. Load. Connect USB Blaster (TC2030 or similar). Capture.

### Step 3: Analyze captured data

Questions to answer from SignalTap data:
- Is `ce_pix` actually high enough to advance the pipeline? At what duty cycle?
- Are `r_out`/`g_out`/`b_out` (Galaga's actual pixel data) varying as expected (game frames)?
- Is `reg_enable_s2` high (warp enabled)? Is `reg_curvature_s2` = "010"?
- Is `cnt_x_w`/`cnt_y_w` (write cursor) incrementing? Does it match expected source dims (288×224)?
- Is `s16_de` going high in active regions?
- Is `vw_r` actually producing the warped output?
- Is `sl_din` showing vis_warp's output OR the original raw emu (= which `ifdef` branch is active)?
- Is `vga_data_sl` matching `sl_din` shape after scanlines processes it?
- Is `hr_out` matching `vga_data_sl[23:16]`?

The data tells us EXACTLY where the chain breaks.

## SignalTap setup gotchas

- **`.stp` file uses M9K blocks** for the sample buffer. Will consume 4-8 more M9K blocks. Galaga is currently at 322/553 (58%) — plenty of room.
- **SignalTap adds an extra compile pass.** First time you add it, it does instrumentation insertion. Subsequent compiles with .stp present are faster.
- **JTAG connection**: TC2030 or USB Blaster, plugged into DE10-nano's JTAG header. Quartus's Programmer tool should auto-detect.
- **DO NOT commit the `.stp` file** to git. It's per-session scratch.
- **Don't be surprised if SignalTap reports compile-time errors** about node names — Quartus's hierarchy syntax is finicky. Try `|` separators in node paths.

## Files in current Galaga state (relative to `D:/deck/fpga/galaga/Arcade-Galaga_MiSTer/`)

```
Arcade-Galaga.qsf     — has MISTER_WARP=1 (line ~23)
sys/sys_top.v         — vis_warp instance at SITE C PRE-scanlines (line ~1386)
                      — trailing assigns restored to upstream baseline (line ~1745)
sys/vis_warp.vhd      — wrapper, reg_enable='1', reg_curvature="010", reg_bilinear='1'
sys/vis_warp_v2_wp.vhd — v3.1 bilinear, no SCALE_PREWARP, no sync delay
sys/vis_warp_pkg_v2.vhd / vis_warp_luts_pkg.vhd — types/LUTs
output_files/Galaga_20260528.rbf — built 18:39 today
```

## When SignalTap reveals the cause, the fix path is

If the data shows vis_warp pipeline is running but output sync doesn't reach ASCAL:
- Probably a ce_pix alignment issue or sync timing mismatch
- Fix: change vis_warp.vhd wrapper or sys_top.v wiring to align
- Build, test, iterate

If the data shows vis_warp pipeline ISN'T running (cnt_x_w not incrementing):
- ce_pix isn't pulsing as expected
- Check Galaga's ce_pix source

If the data shows vis_warp output IS valid but hr_out doesn't carry it:
- Wiring issue we missed
- Audit sys_top.v with fresh eyes

If the data shows hr_out IS our output but screen shows vanilla:
- ASCAL or downstream is the issue
- Investigate freeze input or other ASCAL gates

## Key reference files for next session

- `D:\deck\fpga\Template_MiSTer-VIS\README.md` — project pitch
- `D:\deck\fpga\Template_MiSTer-VIS\LIMITATIONS.md` — what doesn't work
- `D:\deck\fpga\Template_MiSTer-VIS\POSTMORTEM-v3.3-sync-delay-2026-05-28.md` — sync delay debugging history
- `~/.claude/projects/D--deck/memory/lessons_vis_warp_sync_delay_2026-05-28.md` — methodology lessons
- `~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md` — locked architectural decisions
- `~/.claude/projects/D--deck/memory/reference_mister_framework.md` — MiSTer framework integration

## What NOT to do next session

1. **Don't make more speculative code changes without SignalTap data.** This was today's mistake. Build cycles are 15-20 min each. Burned ~8 hours on guesses.
2. **Don't retry sync delay** without proper simulation infrastructure. Two attempts both failed; the postmortem covers why.
3. **Don't change vis_warp's architecture lock** (site C, M9K, framework-level, etc.). The architecture is sound — Template proves it. The bug is integration-specific.
4. **Don't trust agent "implementation complete" reports** without hardware validation. Multiple agent-generated changes today proved wrong on hardware.
5. **Don't drop Template's quality.** v3.1 bilinear works on Template; the framework is shippable as alpha. Don't break it while debugging Galaga.

## Today's deliverables that ARE shipping

If Galaga doesn't work after SignalTap diagnosis, Template alone is still shippable:
- Template_MiSTer-VIS framework with v3.1 bilinear (validated on hardware)
- Complete docs (README, LIMITATIONS, ROADMAP, CONTRIBUTING, CHANGELOG, POSTMORTEM)
- Spec for consumer cores to follow
- Galaga consumer fork as "validation pending — see this handoff"

That's a real release. Galaga validation is the polish.
