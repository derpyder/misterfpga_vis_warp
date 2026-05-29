# vis_warp — Games with curved options

A framework-level barrel-distortion video processor for the MiSTer FPGA
platform. Brings CRT-style screen curvature to arcade and console cores
**without sacrificing integer scaling, OSD readability, or pixel-perfect
output** — because the warp lives upstream of the scaler, not downstream.

```
status:  alpha (v3.3c — symmetry validated, self-tuning, first consumer core shipped)
target:  Terasic DE10-nano (Cyclone V 5CSEBA6)
quartus: 17.0.2 Lite (free edition)
```

## On hardware — Robotron (first validated consumer core)

| Barrel warp | Warp + CRT shadowmask |
|---|---|
| ![Robotron title with vis_warp](docs/screenshots/robotron-warp-title.jpg) | ![Robotron + shadowmask](docs/screenshots/robotron-warp-crt-mask.jpg) |

Symmetric barrel across the native 4:3 frame (self-tuning sync-delay), with
the CRT shadowmask stacked downstream so the mask border curves *with* the
tube. DE10-nano over HDMI.

**▶ Try it now (no Quartus):** pre-built core + drop-in MRAs for **6
Williams games** (Robotron, Joust, Stargate, Bubbles, Splat, Alien Arena)
— [**download the Robotron-VIS release**](https://github.com/derpyder/Arcade-Robotron_MiSTer-VIS/releases/latest).
Copy the `.rbf` to `_Arcade/cores/`, the `(vis_warp).mra` files to
`_Arcade/`, bring your own MAME ROMs. Pre-named to just work, no renaming.

Full consumer core + install guide:
[`Arcade-Robotron_MiSTer-VIS`](https://github.com/derpyder/Arcade-Robotron_MiSTer-VIS).
Adopt your own core: [`ADOPTING-A-CORE.md`](./ADOPTING-A-CORE.md).

### Dev rig — the grid test pattern that proves it

![Template grid pattern, symmetric barrel dome](docs/screenshots/template-grid-symmetric.jpg)

The built-in `mycore` test pattern (this fork's upgraded demo core,
selectable patterns in the OSD). A regular grid makes the warp geometry
unambiguous: straight lines bow into a **symmetric** dome, even top-to-
bottom — that's how we validate the self-tuning sync-delay on the dev rig
before any game core touches it. (The flat bars left/right are the 4:3
source letterboxed into 16:9 — ascal's framing, outside the warp.)

---

This is a fork of [`MiSTer-devel/Template_MiSTer`](https://github.com/MiSTer-devel/Template_MiSTer)
with a new framework module added under `sys/`. The fork tracks upstream
HEAD (`f35083f`, 2026-05-13) so future framework updates merge cleanly.
The original upstream README is preserved at
[`README-upstream-template.md`](./README-upstream-template.md).

---

## What it does

vis_warp intercepts a core's video output **before** ascal (MiSTer's
scaler), applies barrel distortion at source resolution, and passes the
warped pixels downstream. The result on screen:

- Each game's pixel art warps as if displayed on a curved CRT.
- ascal's integer scaling preserves the warped image pixel-for-pixel as
  it upscales to your monitor (1080p / 1440p / 4K — same `.rbf` works at
  any output mode).
- The OSD overlay stays straight and readable (it lives downstream of
  the warp).
- Shadowmask + scanlines apply *after* the warp at output resolution —
  matching the correct CRT model: the phosphor mask is on the glass,
  not on the beam.
- v3.1 adds bilinear interpolation, so curves are smooth rather than
  staircased.

It's **macro-gated**. Cores opt in via `MISTER_WARP=1` in their `.qsf`.
By default, the framework behaves identically to upstream Template_MiSTer.

---

## Why this fork exists

MiSTer's framework lives in `Template_MiSTer/sys/`. Each game core
vendors `sys/` into its own bitstream via periodic "Update sys" commits.
There's no runtime-loadable plugin model — framework features must be
compiled into each core's `.rbf` by its maintainer.

This fork:

1. Adds vis_warp as a new framework module (`sys/vis_warp.vhd`,
   `sys/vis_warp_v2_wp.vhd`, supporting packages).
2. Wires it into `sys/sys_top.v` under `` `ifdef MISTER_WARP `` so cores
   opt in cleanly.
3. Allocates HPS opcode `0x45` for runtime configuration (the userland
   integration is on the v4 roadmap — see [`ROADMAP.md`](./ROADMAP.md)).
4. Tracks upstream Template_MiSTer so it stays mergeable for an
   eventual PR.

Downstream cores (`Arcade-Galaga_MiSTer-VIS`, others coming) consume
this framework via the same `sys/` vendoring pattern, with `MISTER_WARP=1`
defined in their per-core `.qsf`.

---

## Architecture (one paragraph)

```
emu (game core)
  → arcade_video (scandouble, scanlines)
    → vis_warp ◄─────────  pre-ascal, source-res, clk_video domain
      → ascal (upscale to HDMI mode)
        → shadowmask (CRT phosphor mask)
          → osd (menu overlay)
            → HDMI output
```

vis_warp operates on **source-resolution pixels** in the **`clk_video`
clock domain**, before ascal. It uses **2-buffer M9K ping-pong** at
source resolution (~30% of M9K total at typical arcade res) — the whole
source frame is buffered, so the warp can pull from any source coordinate
(no edge-clamping artifacts). **Bilinear interpolation** reads 4
neighboring source pixels per output pixel via a 4-way bank split (same
total memory as single-buffer, 4 simultaneous read ports) and blends
them, producing smooth curves.

Architectural decisions are locked in
[`SPEC-vis_warp-v3.md`](./SPEC-vis_warp-v3.md). The short version is in
the project memory at
`~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md`.

---

## Status (2026-05-28)

| Layer | Status |
|---|---|
| RTL module + framework integration | ✅ v3.1 |
| Test rig (Template + selectable test patterns) | ✅ Validated on hardware (k=0 / k=2 / k=7) |
| Bilinear interpolation | ✅ Implemented; awaiting first hardware validation |
| Consumer core: Galaga | ⚠️ Fork ready; build pending bilinear validation |
| Other consumer cores (Pac-Man, DK, etc.) | 📋 Planned |
| Main_MiSTer userland (OSD config + presets) | 📋 v4 roadmap |
| Upstream PR to MiSTer-devel | 📋 Post-v4 |
| GitHub Actions auto-build | 📋 Future |

See [`LIMITATIONS.md`](./LIMITATIONS.md) for what doesn't work yet,
[`ROADMAP.md`](./ROADMAP.md) for the path to broader community adoption,
and [`CHANGELOG.md`](./CHANGELOG.md) for the release history.

---

## For end users

**You probably don't want THIS fork directly** — this is the framework.
You want a pre-compiled `.rbf` for the specific game core you want to
play with vis_warp. Those live in companion repos:

- **`Arcade-Galaga_MiSTer-VIS`** — Galaga with vis_warp (release pending
  bilinear validation)
- (more cores coming — see [`ROADMAP.md`](./ROADMAP.md))

Drop the `.rbf` in `/media/fat/_Arcade/cores/`, drop the matching MRA
in `/media/fat/_Arcade/`, load via the normal MiSTer arcade menu. Until
v4 userland lands, curvature is hardcoded into each build — you can pick
"off / light (k=2) / heavy (k=7)" variants by downloading the
corresponding `.rbf`.

**ROMs are NOT distributed with this project.** Use your existing MiSTer
arcade ROM zips — they work unmodified.

---

## For builders / contributors

If you want to compile your own vis_warp-enabled core:

1. **Clone this fork** for the framework files.
2. **Clone your target core's repo** (e.g.,
   `MiSTer-devel/Arcade-Galaga_MiSTer`). Open it in Quartus 17.0.2 Lite.
3. **Vendor `sys/`** from this fork over the core's `sys/` (this matches
   MiSTer's standard "Update sys" pattern). See
   [`ROADMAP.md`](./ROADMAP.md#framework-version-compatibility) for
   notes on older cores that may need per-core `.sv` updates to match
   newer framework port shapes.
4. **Add `MISTER_WARP=1`** to the core's `.qsf` as a `VERILOG_MACRO`
   global assignment.
5. **Set defaults** in `sys/vis_warp.vhd` (`reg_enable`,
   `reg_curvature`) — these are the dev-time hardcoded values until v4
   userland lands. See the inline comments at the top of `vis_warp.vhd`
   for the per-phase defaults.
6. **Compile** in Quartus 17.0.2 Lite. Drop `.rbf` on SD, test.

The Template_MiSTer-VIS dev rig (this repo, with `mycore.v` and
selectable test patterns) is the right place to iterate on vis_warp
itself. Galaga and other consumer cores are validation hosts, not dev
hosts.

Help wanted on: building more consumer cores, validating on different
monitors/scaling configurations, and the v4 Main_MiSTer userland work.
See [`CONTRIBUTING.md`](./CONTRIBUTING.md).

---

## Repository layout

```
Template_MiSTer-VIS/
├── README.md                        ← you are here
├── README-upstream-template.md      ← preserved upstream Readme
├── LIMITATIONS.md                   ← what doesn't work yet
├── ROADMAP.md                       ← path to community adoption
├── CONTRIBUTING.md                  ← how to help
├── CHANGELOG.md                     ← release history
├── SPEC-vis_warp-v3.md              ← active work spec
├── HANDOFF-vis_warp-v3-kickoff-*.md ← session continuity (transient)
├── sys/                             ← framework (upstream + vis_warp additions)
│   ├── vis_warp.vhd                 ← wrapper (CDC, HPS_BUS, NN/bilinear mux)
│   ├── vis_warp_v2_wp.vhd           ← engine (M9K + warp math + bilinear)
│   ├── vis_warp_pkg_v2.vhd          ← types
│   ├── vis_warp_luts_pkg.vhd        ← coefficient LUTs
│   ├── vis_warp_wrapper_tb.vhd      ← GHDL testbench
│   ├── B4_TODO.md                   ← deferred CDC notes
│   └── …                            ← upstream framework files
├── rtl/                             ← demo core
│   └── mycore.v                     ← 8 selectable patterns (grid, vbars, …)
├── Template.sv                      ← emu wrapper with CONF_STR pattern selector
└── Template.qpf, Template.qsf       ← Quartus project
```

---

## License

GPL v2+ (matching upstream MiSTer framework). See `LICENSE`.

---

## Credits

vis_warp is built on the excellent [MiSTer FPGA project](https://github.com/MiSTer-devel)
by Alexey Melnikov ([@sorgelig](https://github.com/sorgelig)) and
contributors. The framework integration, contribution policy, and
testing conventions are all theirs. This fork adds one new module and
stays out of the way of everything else.

CRT-curvature shaders have a long history in emulator-land —
CRT-Royale, CRT-Geom, CRT-Lottes, the various RetroArch shaders. vis_warp
adapts the spatial-remap part of that work to MiSTer's FPGA constraints:
no shader language, no per-pixel GPU programs, just block RAM +
arithmetic + careful pipeline timing.
