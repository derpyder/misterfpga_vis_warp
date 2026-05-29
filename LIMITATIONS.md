# Limitations

What vis_warp doesn't do yet, what it does poorly, and what the known
edge cases are. Last updated 2026-05-28.

This is the honest list. Read it before evaluating or recommending the
project.

---

## Hard limits today

### 0. Top-of-frame asymmetric warp (v3.2 release)

**The single most visible limitation.** The first ~20–30% of each frame's
vertical extent shows asymmetric/stale-buffer content because vis_warp's
M9K sliding-window pixel buffer doesn't "look ahead" of the output
cursor at the top of frames.

Manifests as:
- **Galaga**: score area at top of screen is noisy or shows previous-frame artifacts; gameplay area below score is clean
- **Pac-Man** (vertical orientation): top score strip degraded
- **Any core with HUD at top of screen**: affected
- **Attract mode title text**: often unreadable at the very top

Mitigation today:
- Lower curvature (k=1 instead of k=2) reduces the artifact area by
  reducing how much corner-pull happens
- Bottom 70% of frame renders correctly and shows the proper warped image

**Proper fix**: implement N_LINES/2 line lookahead sync delay so the
writer leads the reader. We attempted this twice (v3.3 counter FSM,
v3.3b FIFO) — both failed empirically. See
[`POSTMORTEM-v3.3-sync-delay-2026-05-28.md`](./POSTMORTEM-v3.3-sync-delay-2026-05-28.md)
for the full debugging history and pre-emptive guidance for anyone
attempting a v3.4 retry. Bottom line: it's harder than it looks; needs
proper simulation + SignalTap setup before any RTL changes.

### 1. Per-core opt-in requires recompile

vis_warp lives in framework `sys/` files that get **vendored into each
core's bitstream at compile time**. There is no runtime-loadable
plugin model in MiSTer. To use vis_warp with a specific game, you need:

- A pre-compiled `.rbf` for that core with `MISTER_WARP=1` defined.
- Either you compile it yourself (Quartus 17.0.2 Lite + this fork's
  `sys/` + the target core's repo), or you download one from a
  companion repo (currently just Galaga; more coming).

Until [v4 userland](./ROADMAP.md#v4-main_mister-userland) lands, the
curvature value is **hardcoded** into each build. You toggle between
"off / light / heavy" variants by loading different `.rbf` files.

### 2. Source resolution capped at 512 pixels wide

The M9K pixel buffer in `vis_warp_v2_wp.vhd` is sized for `MAX_SRC_W = 512`.
Sources wider than 512 pixels (Amiga, ST, some Genesis hi-res modes,
PSX 640×480) will see **edge artifacts** on the rightmost 1–N columns:
those source pixels never get captured into the buffer, and the warp's
read side pulls stale data from those addresses.

**Workaround**: bump `MAX_SRC_W` to 640 or 1024 in v2_wp's generic.
~+50 to ~+150 M9K blocks. Within budget for most cores but tight.

**Common arcade cores (≤512 wide) are unaffected**: Galaga (288),
Pac-Man (224), Donkey Kong (256), Defender (320), etc.

### 3. MISTER_FB cores not validated

Cores that use the direct-framebuffer path (e.g., Apple IIGS, some
computer cores) draw video into DDR3 from the HPS side. vis_warp's
SITE C insertion point assumes the core emits via the standard `emu`
RGB output path. MISTER_FB cores may bypass this entirely, in which
case vis_warp has nothing to intercept.

**Status**: not investigated. May work, may need additional plumbing,
may be incompatible. Real arcade cores are unaffected.

### 4. No Main_MiSTer userland (yet)

The HPS opcode `0x45` is allocated and decoded in `sys_top.v`, but
there's no userspace handler in `Main_MiSTer` to drive it. Consequence:

- No OSD menu entry to enable/disable warp or change curvature.
- No `warp=` key in `/media/fat/Presets/*.ini`.
- No per-core `.cfg` persistence (e.g., "remember the warp setting I
  picked for Galaga").

Workaround: warp on/off and curvature are hardcoded in the build via
`reg_enable` and `reg_curvature` initializers in `sys/vis_warp.vhd`.
Edit, recompile, reload.

This is **the** v4 work. See [`ROADMAP.md`](./ROADMAP.md#v4-main_mister-userland).

### 5. Not yet upstream

The framework module is in this fork, not in `MiSTer-devel/Template_MiSTer`.
Consequences for end-user adoption:

- Standard `update_all` scripts don't deliver vis_warp-enabled `.rbf`s.
  Users have to manually drop `.rbf` from this project's companion
  repos.
- Each consumer core needs a hand-maintained fork (or a CI build farm
  — see [`ROADMAP.md`](./ROADMAP.md#path-3-github-actions-ci-builds)).
- The community at large doesn't know vis_warp exists yet.

Upstream PR to MiSTer-devel is on the roadmap, post-v4. Acceptance is
not guaranteed.

---

## Soft limits / visual quality

### 6. Bilinear quality is bounded by source resolution

vis_warp's bilinear interpolation smooths the **warp curve**, but it
can't fabricate detail that isn't in the source. A 288×224 Galaga
source upscaled 9× to 4K still produces 9×9-pixel blocks for the
pixel art itself — the *art* is chunky regardless of the *warp* being
smooth.

Pairing vis_warp with ascal's polyphase scaling filter
(`vfilter=Sharp Bilinear/Sharp Bilinear.txt` and similar in your
MiSTer.ini) softens the upscale itself for a more CRT-realistic look.
Combined effect: smooth curves + smooth pixel boundaries.

Users who want **integer-scale "raw pixel art"** keep ascal in NN mode.
They get smooth warp curves + sharp pixel blocks. Both are valid; both
are user-tunable on the MiSTer side independently of vis_warp.

### 7. Curvature is symmetric and uniform

Current barrel-warp math is radially symmetric — the same curve in all
four corners. Real CRTs often have slight per-corner geometry errors
that some users want to mimic. vis_warp doesn't expose corner-specific
parameters yet.

Other CRT effects not implemented: vignette, slot-mask grille,
horizontal-line drift, beam thickness, gamma per-channel. These would
all be additional framework modules sitting alongside vis_warp.

### 8. Single curvature value, no per-game tuning

`reg_curvature` is a 3-bit value (0–7). Currently you pick one value
at build time and ship it. Different games look best at different
curvatures (vertical Pac-Man at k=2, fast-action Galaga at k=3, slow
strategic stuff at k=1) but there's no way for the user to switch
without a different `.rbf`.

Fixed by v4 userland (OSD slider).

---

## Known quirks

### 9. Mycore test rig has edge artifacts at >512px

The Template demo emu (`rtl/mycore.v`) runs a 530-pixel-wide active
area, which exceeds `MAX_SRC_W=512`. The rightmost ~17 columns of the
test card show stale-data noise (visible especially on the cosine
pattern). This is **specific to mycore exceeding the buffer** —
real arcade cores at typical resolutions don't hit this.

If you want a clean test rig: either bump `MAX_SRC_W` to 640 in v2_wp's
generic, or trim mycore's HBlank threshold.

### 10. Crosshair test pattern looks weird under warp

The crosshair pattern (Pattern #4 in mycore) is **single-pixel-thick**
lines. Under barrel warp the horizontal line "disappears" because the
sampling sparsity vs. radial warp causes most output rows to compute
src_y values that miss the one row holding the horizontal line.
Bilinear interpolation helps but doesn't eliminate the issue for
single-pixel features.

**Not a vis_warp bug** — sparse single-pixel patterns are inherently
hard to sample. Real game pixel art (>1px features) doesn't have this
problem.

### 11. Bilinear adds pipeline latency

v3.1 bilinear adds ~3 extra pipeline stages (19 total vs 16 in v3.0).
At clk_video rates (~6 MHz typical arcade), that's <0.5 µs of
additional input-to-output latency. Imperceptible for human
play, but worth noting if you're building latency-sensitive tooling
on top.

### 12. CDC not maximally bulletproof

Phase 1 minimal CDC (2-flop synchronizers for control signals, toggle
handshake for reset pulse). Phase 2 (full async dcfifo on data path)
deferred per [`sys/B4_TODO.md`](./sys/B4_TODO.md). At site C, clk_in
and clk_out are the same clock (clk_ihdmi), so the data path stays in
one domain and Phase 1 is sufficient. If a future revision moves
vis_warp to a slot with truly distinct clocks, Phase 2 becomes
necessary.

### 13. No SDC constraints for the CDC paths

If Quartus warns about unconstrained CDC paths between `reg_*` and
`reg_*_s1`, the fix is adding a `sys/vis_warp.sdc` with `set_false_path`
entries. **Do not edit `Template.sdc`** (upstream-tracked). The warning
hasn't appeared in tested builds yet, so this is preemptively deferred.

---

## Things that explicitly DO work

To prevent over-cautious skipping based on the list above:

- ✅ 4K monitors with integer scaling (this was the design target)
- ✅ 1080p and 1440p (same `.rbf` works at any HDMI mode)
- ✅ OSD stays straight and readable while warp is active
- ✅ Shadowmask + scanlines + gamma all stack correctly on top of warp
- ✅ Audio, controls, save states, hi-scores — all unaffected
- ✅ MiSTer's existing video config presets (Robby's etc.) work
  alongside vis_warp without conflicts
- ✅ Cores can adopt vis_warp without changing their own RTL (only
  their `sys/` vendoring + a one-line `.qsf` addition)
- ✅ Disabling `MISTER_WARP` collapses the path to upstream-equivalent
  behavior — no overhead, no warnings, bit-identical output

---

## When in doubt

This is alpha software with one validated test rig and one (pending)
validated consumer core. **It will have bugs.** File issues with
specific repro steps. Don't recommend it to anyone whose MiSTer
experience you care about without warning them.

The architecture is sound (we re-derived it from first principles
after a multi-hour ghost chase; see
`~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md`).
The integration is correct (validated end-to-end on Template). The
quality is shipping-grade with bilinear. But the breadth (one core
right now, more coming) and polish (no userland, no upstream) are
where the gaps are.
