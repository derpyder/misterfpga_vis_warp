# Adopting a core into vis_warp

The repeatable pipeline for adding barrel-warp to a MiSTer core. This is
the heart of the project: the warp is a framework module, and a core
"adopts" it by vendoring the files and wiring one insertion point. With
the self-tuning sync-delay (v3.3c), there is **no per-core magic
constant** — the warp measures the core's line timing and configures
itself.

Validated end-to-end on `Arcade-Robotron_MiSTer` (2026-05-28): symmetric
barrel across the native 4:3 frame, first honest build.

---

## Step 0 — Is this core a candidate? (the one judgment call)

Read the core's emu `.sv` for how it drives video to ascal. Two classes:

- **Live-input cores (adopt cleanly):** the core feeds ascal's live
  `i_r/i_g/i_b` input. These are horizontal arcade games and all console
  cores. vis_warp at SITE C lands directly in this path. ✅
- **Rotated / framebuffer cores (do NOT adopt at SITE C):** vertical
  games (Galaga, Pac-Man, DK) rotate via `screen_rotate` into a DDR
  framebuffer; ascal reads from DDR and **ignores** its live input. SITE
  C vis_warp lands on a dead port → no warp. ❌ (needs the framebuffer-
  path variant — open work)

How to tell, concretely — grep the emu `.sv`:
```
no_rotate   = status[2] | direct_video | landscape   ← look for this
screen_rotate ... (.*)                               ← rotation present?
```
If `no_rotate` is **forced high by default** for the game you want
(e.g. Robotron: `landscape=1` always), the framebuffer path is dormant
and ascal uses the live input → **adopt**. If the game boots rotated
(`no_rotate=0`), it's the ❌ class.

> This 5-minute static read is non-negotiable. Skipping it is what cost
> us a two-day chase on Galaga (see POSTMORTEM + the design-constraints
> memory). Read before you build.

---

## Step 1 — Clone the stock core

```
git clone https://github.com/MiSTer-devel/Arcade-<Core>_MiSTer.git <core>-vis
```

---

## Step 2 — Vendor the vis_warp files (identical every core)

Copy from this framework's `sys/` into the core's `sys/`:
```
vis_warp.vhd  vis_warp_v2_wp.vhd  vis_warp_pkg_v2.vhd  vis_warp_luts_pkg.vhd
```
Add them to the core's `sys/sys.qip` (after `pll_hdmi_adj.vhd`):
```tcl
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) vis_warp_pkg_v2.vhd ]
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) vis_warp_luts_pkg.vhd ]
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) vis_warp_v2_wp.vhd ]
set_global_assignment -name VHDL_FILE [file join $::quartus(qip_path) vis_warp.vhd ]
```

---

## Step 3 — Three `sys_top.v` edits (byte-identical across cores)

These were the same on Galaga and Robotron. Do not improvise.

**(a) HPS opcode 0x45 decoder** — next to the shadowmask `0x3E` line:
```verilog
if(cmd == 'h45) {vis_warp_cmd_wr, vis_warp_cmd_data} <= {1'b1, io_din};
```

**(b) Strobe-clear** — next to `shadowmask_wr <= 0;`:
```verilog
vis_warp_cmd_wr <= 0;
```

**(c) SITE C insertion** — wrap the `scanlines`/`VGA_scanlines` instance
so vis_warp sits BEFORE it (warps native source; scanlines/mask/ascal
stack downstream). Declare `reg [15:0] vis_warp_cmd_data; reg vis_warp_cmd_wr = 0;`
nearby. Pattern:
```verilog
`ifdef MISTER_WARP
  vis_warp u_vis_warp_siteC (
    .clk_sys(clk_sys), .clk_in(clk_vid), .clk_out(clk_vid),
    .cmd_wr(vis_warp_cmd_wr), .cmd_in(vis_warp_cmd_data),
    .ce_pix_in(ce_pix),
    .r_in(r_out), .g_in(g_out), .b_in(b_out),
    .hs_in(hs_fix), .vs_in(vs_fix), .de_in(de_emu),
    .ce_pix_out(), .r_out(vw_r), .g_out(vw_g), .b_out(vw_b),
    .hs_out(vw_hs), .vs_out(vw_vs), .de_out(vw_de) );
  wire [23:0] sl_din = vw_de ? {vw_r,vw_g,vw_b} : 24'd0;
  // sl_hs_in=vw_hs, sl_vs_in=vw_vs, sl_de_in=vw_de
`else
  wire [23:0] sl_din = de_emu ? {r_out,g_out,b_out} : 24'd0;
  // sl_*_in = hs_fix/vs_fix/de_emu
`endif
// scanlines .din(sl_din) .hs_in(sl_hs_in) .vs_in(sl_vs_in) .de_in(sl_de_in)
```
(See `Arcade-Robotron_MiSTer-VIS/sys/sys_top.v` for the exact, working diff.)

---

## Step 4 — Enable the macro

In the core's `.qsf`:
```tcl
set_global_assignment -name VERILOG_MACRO "MISTER_WARP=1"
# crisp 2x engine (the line-doubling fix) — recommended; bow on both axes:
set_global_assignment -name VERILOG_MACRO "MISTER_WARP_HIRES=1"
```
(Omit `MISTER_WARP_HIRES` for the stock source-res engine, or use
`MISTER_WARP_CYL` for the M9K-frugal cylindrical variant. Pick at most one;
HIRES wins if both are set. Needs ≥2× `clk_vid` headroom over `ce_pix`.)

---

## Step 5 — Wire the live OSD sliders

**v4's goal — runtime OSD control — is reached per-core today.** Four CONF_STR
options drive the warp live (Vert/Horz Bow, Curve Depth, Vignette), CDC-synced,
tunable on the cab — no firmware, no per-build variants. The plumbing through
`sys/` is vendored already (Step 2), so the only per-core work is **two edits in
your core's top `.sv`**.

**5a — Two `emu` outputs.** Cores that `` `include "sys/emu_ports.vh" `` have them
already (vendored in Step 2, gated by `MISTER_WARP`):
```verilog
output  [8:0] VIS_WARP_CURV,   // [2:0]=kv Vert Bow, [5:3]=kh Horz Bow, [8:6]=k Curve Depth
output  [5:0] VIS_WARP_FX,     // [2:0]=vignette ([5:3] reserved)
```
Older cores with an **inline** `module emu (...)` port list add the two outputs
there yourself, inside `` `ifdef MISTER_WARP / `endif ``.

**5b — Four CONF_STR sliders** on any free `status[]` bits (12 total). Robotron's map:
```verilog
"O[17:15],CRT Vert Bow,Off,1,2,3,4,5,6,7;",
"O[20:18],CRT Horz Bow,Off,1,2,3,4,5,6,7;",
"O[23:21],CRT Curve Depth,Default,1,2,3,4,5,6,7;",
"O[26:24],CRT Vignette,Off,1,2,3,4,5,6,7;",
```
(Old `"O8A,..."` letter notation works too — just don't collide with the core's
existing bits.)

**5c — Map the bits to the outputs:**
```verilog
`ifdef MISTER_WARP
// Curve Depth 0 = "Default" -> k=2 (engine default). Vignette [5:3] reserved.
wire [2:0] warp_k = (status[23:21] == 3'd0) ? 3'd2 : status[23:21];
assign VIS_WARP_CURV = {warp_k, status[20:18], status[17:15]};
assign VIS_WARP_FX   = {3'd0, status[26:24]};
`endif
```
That's it. Vendored `sys_top.v` already routes `VIS_WARP_CURV` into the engine
(`osd_kv/osd_kh/osd_k`, CDC'd) and `VIS_WARP_FX` into the post-warp vignette
(`sys/crt_postfx.v`). Build, load — the sliders are live in the OSD. Wire nothing
and the core is visually stock (curvature/vignette default to 0 = flat/off).

---

### Build-time knob (no slider yet) — sharpness

One knob still has no OSD slider and stays a build-time default in
`sys/vis_warp.vhd` (architecture `wrapper`, ~line 114). Edit, recompile, reload.

**Sharpness** — `reg_sharpness`, sharp-bilinear K. A warp resamples, so plain
bilinear looks soft; K snaps toward nearest-neighbor inside a thin transition
band — crisp pixels, smooth curve:

| value | K | look |
|-------|---|------|
| `"001"` | 1 | soft (pure bilinear) |
| `"010"` | 2 | mild |
| `"100"` | 4 | **dev-tuned default** — crisp, no staircase |
| `"111"` | 7 | near nearest-neighbor (sharpest; can stair-step) |

`"000"` → treated as K=1 (`v_k` guards ≥1); `"011"`,`"101"`,`"110"` interpolate
between the rows. **Tuning:** raise K until diagonals *just* begin to stair-step,
then back off one. K=4 is the validated sweet spot (Robotron + Template grid).

The initializers:
```vhdl
signal reg_enable    : std_logic := '1';                       -- on
signal reg_curvature : std_logic_vector(2 downto 0) := "000";  -- bow now OSD-driven (Step 5); dead default
signal reg_sharpness : std_logic_vector(2 downto 0) := "100";  -- K=4 (sharp)
signal reg_bilinear  : std_logic := '1';                       -- smooth
```

---

## Step 6 — Build, load, validate

- Quartus 17.0.2 Lite → compile. **No line-timing constant to set** — the
  self-tuning FIFO measures the core's hsync period and sets its own
  ~N_LINES/2 writer-lead. This is the step that used to need per-core
  hand-tuning and now doesn't.
- On hardware: expect a **symmetric** barrel across the native frame.
- For HDMI, leave the front-end **scandoubler OFF** — ascal scales the
  warped native frame. (Scandoubler ON feeds vis_warp doubled lines it
  can't fully reach → resolution-gated bow. Native + ascal is the path.)
- Dress via OSD: sharp-bilinear scaler → scanlines → shadowmask.

---

## Compile-time sanity (Layer-1 checks)

- `vis_warp` + `vis_warp_v2_wp` elaborate in the map report.
- The two `vis_warp_cmd_*` "assigned but never read" warnings are GONE
  (proves MISTER_WARP took and the instance consumes them).
- RAM Blocks jump ~+180 (4 bilinear banks ~152 + sync FIFO ~29).
- `attribute keep : boolean;` appears exactly once (entity scope) — a
  second one at architecture scope is the Error-10465 trap; don't add it.

---

## Cores adopted so far

| Core | Class | Status |
|---|---|---|
| Template (mycore) | dev rig | ✅ validated, symmetric; live OSD sliders + vignette |
| Arcade-Robotron (+ Joust/Stargate/Bubbles/Splat/Alien★ar) | live-input, landscape | ✅ shipped — hi-res 2×, live OSD bows + vignette, twin-stick fire |
| Arcade-Galaga | rotated/framebuffer | ❌ SITE C bypassed — needs framebuffer-path variant |

The Williams multi-core means one Robotron-VIS build covers a half-dozen
`landscape=1` titles. Sinistar/Playball on that core are `landscape=0`
(rotated) → the ❌ class.
