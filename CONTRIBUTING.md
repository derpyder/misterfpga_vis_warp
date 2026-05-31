# Contributing

Thanks for considering helping out. vis_warp is small enough to be
approachable and large enough to need many hands.

---

## Most useful contributions right now

### 1. Build a new consumer core (high leverage, moderate effort)

The single biggest unblock for vis_warp adoption is **more validated
consumer cores**. If you have Quartus 17.0.2 Lite and a DE10-nano:

1. Pick a core from the [Tier 1 list in ROADMAP.md](./ROADMAP.md#target-cores).
2. Clone its upstream repo (e.g., `MiSTer-devel/Arcade-Pacman_MiSTer`).
3. Surgically sync vis_warp files from this fork (see [framework version
   compatibility](./ROADMAP.md#framework-version-compatibility-the-galaga-lesson)
   for the surgical-sync pattern).
4. Add `MISTER_WARP=1` to its `.qsf`.
5. Compile, load on hardware, validate at k=0 (identity) and k=2
   (visible bow).
6. Open an issue/PR with screenshots, resource usage, and any quirks.

We'll mint a `Arcade-{Core}_MiSTer-VIS` fork repo when you've validated
it and want to ship binaries.

### 2. Validate on different output configurations (low leverage but
quick wins)

The architecture is supposed to scale across resolutions and integer-
scale modes. Testing that empirically across different monitors is
valuable.

Configurations worth validating:
- 4K monitor + integer scaling (the design target)
- 1080p monitor + integer scaling
- 1440p monitor + integer scaling
- Any of the above with VRR / variable refresh
- Direct-video (analog) output through the DE10-nano analog board
- VGA output via the I/O board

File issues with screenshots if anything looks wrong. "Worked great"
reports are also welcome — they help us know what's actually deployed.

### 3. v4 Main_MiSTer userland (largest scope item)

This is the **biggest blocker for broad community adoption**. It's also
the largest single piece of remaining work — C/C++ in `Main_MiSTer`,
not Verilog/VHDL.

Scope is in [`ROADMAP.md`](./ROADMAP.md#v4-main_mister-userland). Roughly:

- New UIO opcode constant
- C handlers for enable/curvature
- Preset INI parser extension
- Per-core .cfg persistence
- OSD menu generation

If you have C experience and want to take this on, file an issue and
we can mentor through the structure.

### 4. GitHub Actions CI builds (~1 week scope)

Once we have 2–3 consumer cores ready, automating their builds becomes
high-value. Quartus 17.0.2 Lite installs in Linux containers; a matrix
build over our list of forks is straightforward.

If you've done MiSTer or similar FPGA builds in CI before, this is a
high-impact contribution.

### 5. Documentation, screenshots, marketing

- Better README screenshots (k=0 vs k=2 vs k=7 side-by-side, both NN
  and bilinear).
- A short demo video for community channels.
- Reddit / forum posts when we're ready to announce.
- Discord activity in MiSTer community spaces.

---

## How to file a useful issue

Helpful info, roughly in order of importance:

1. **What you were doing** when it broke (loading core, playing game,
   changing config).
2. **What you expected** vs **what happened**.
3. **Hardware**: DE10-nano, monitor model + resolution + integer-scale
   setting, any I/O board (SDRAM, analog, USB hub).
4. **Build**: which `.rbf` (if you downloaded a binary, the release
   tag/commit; if you compiled, the commit hash + your sys/ snapshot).
5. **MiSTer.ini relevant settings**: especially `video_mode`, `vsync_*`,
   `vfilter_default`, `vscale_mode`.
6. **Screenshot or photo** of the issue.

For Quartus compile errors, paste the **error message** (not just the
warning summary) and the **file:line** it points at.

---

## How to propose RTL changes

vis_warp's architecture is locked in
[`SPEC-vis_warp-v3.md`](./SPEC-vis_warp-v3.md) (the author also keeps a private
`~/.claude/.../design_vis_warp_constraints.md`) — those decisions were re-derived
from first principles after a multi-hour ghost chase. Please don't re-litigate:

- vis_warp lives **pre-ascal** at **source resolution** on
  **clk_video**.
- The M9K pixel buffer is the right memory choice (not DDR3/vbuf).
- OSD must stay unwarped (post-vis_warp in the pipeline).
- Macro-gated opt-in (`MISTER_WARP=1`), not always-on.

**Within those constraints, lots of things are open**:

- New CRT-style effects (vignette, slot mask, beam thickness, etc.) —
  ideally as separate framework modules sitting alongside vis_warp,
  each with its own `MISTER_*` macro gate.
- Bilinear quality improvements (sharper-bilinear, cubic, lanczos).
- DSP-saving rewrites of the warp math.
- Better source-dim auto-detection.
- Support for wider source resolutions (`MAX_SRC_W` extensions, RGB565
  fallback for memory-constrained builds).
- MISTER_FB compatibility investigation.

Open a discussion or issue first if you're proposing significant
changes — it's a small project, easy to align before someone spends a
weekend on something we won't merge.

---

## Developing vis_warp itself — the sim-first dev loop

Hard-won discipline, backed by two postmortems (the v3.3 sync-delay fight and
the line-doubling discovery): **model and validate in sim BEFORE touching RTL.**
Don't pile unvalidated changes onto the engine. See
[`STATUS.md`](./STATUS.md) for where things stand and what's next.

**Roles.** The *user* runs Quartus full compiles and flashes hardware — that's
where build, timing, and runtime truth live. Contributors run **GHDL + Python
sim only**. Hardware screenshots come back as `output_files/NNNN.jpg`.

**Python models** (`sim/`) — run with an **absolute path** (the shell cwd resets
between calls):

```
python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_bitexact.py
```

- `warp_bitexact.py` — **the authoritative model.** Bit-faithful to the Q15
  datapath; it *reproduces the hardware line-doubling*. The float models do
  **not** — do not trust them for that artifact. This is the judge.
- `warp_model.py` — geometry + look-family golden reference (proves `kv=0 ⇒
  src_y==out_y` exactly).
- `gen_lut.py`, `warp_royale_map.py` — LUT regeneration + crt-royale dial
  mapping (parked; useful for look/preset labels).
- Superseded diagnosis models live in `sim/archive/` — see
  [`sim/README.md`](./sim/README.md).

**GHDL 6.0.0** (`/c/Users/mattl/bin/ghdl/bin/ghdl.exe`). Analyze + elaborate the
engine — both clean at HEAD (note `vis_warp_rescal.vhd` analyzes **before**
`vis_warp_v2_wp.vhd`, which instantiates it):

```
GH=/c/Users/mattl/bin/ghdl/bin/ghdl.exe
WD=sim/ghdl_work ; S=sys
"$GH" -a --std=08 --workdir="$WD" \
  "$S/vis_warp_pkg_v2.vhd" "$S/vis_warp_luts_pkg.vhd" "$S/vis_warp_rescal.vhd" \
  "$S/vis_warp_v2_wp.vhd" "$S/vis_warp.vhd"
"$GH" -e --std=08 --workdir="$WD" vis_warp
```

**Engine math facts** (so you don't re-derive them):

- `WARP_LUT`: `M = 1 + 0.3·idx/256`; K-scale `M_eff = 1 + (M-1)·K/2` (K=2 ⇒
  `M_eff = M`). LUT indexed by `(AX2·dx² + AY2·dy²) >> 16`, saturates at idx 255.
- `M_scaled` is Q15: **32768 = identity** (`src = out`). Forcing the Y multiplier
  to 32768 gives `src_y = out_y` — the cylinder precondition.
- The aspect weights `AX2`/`AY2` are now **res-adaptive** (computed per-frame by
  `sys/vis_warp_rescal.vhd`), not the old hardcoded `LUT_AX2_Q24`/`LUT_AY2_Q24`
  constants. The fill constant (27458) stays fixed — `edge_M` is aspect-constant
  (~1.19 for 4:3).

---

## Code style

Match the upstream MiSTer framework conventions:

- **Tabs for indentation** (not spaces) in Verilog/SystemVerilog.
- **4-space indentation** in VHDL (matching ascal.vhd etc.).
- Comment heavily on intent ("this stage clamps src_y to avoid
  reading future lines"), lightly on mechanism (code is usually
  self-explanatory at that level).
- Don't add files via the Quartus IDE — edit `sys.qip` / `files.qip`
  manually so the project stays clean.
- Don't commit Quartus scratch (`db/`, `incremental_db/`,
  `output_files/`, `*.qws`, `*.cdf`) — `.gitignore` already covers
  these but be vigilant.
- Don't touch `Template.sdc` (upstream-tracked SDC) — add a separate
  `sys/vis_warp.sdc` if vis_warp needs SDC entries.

---

## Communications

- **Issues / discussions**: GitHub Issues on this repo for technical
  questions and bug reports.
- **General MiSTer community**: misterfpga.org forum and the MiSTer
  Discord. Please don't bring vis_warp-specific bugs to those channels
  unprompted — this is a third-party fork, not a sanctioned project,
  and the MiSTer maintainers shouldn't have to triage our work.

Be excellent to each other. The MiSTer community is broadly friendly
and welcoming; help keep it that way.
