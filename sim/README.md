# vis_warp — simulation models

Sim-first is the rule (see [`../CONTRIBUTING.md`](../CONTRIBUTING.md) → "the
sim-first dev loop", and [`../STATUS.md`](../STATUS.md)). Run Python models with
an **absolute path** — the shell cwd resets between calls:

```
python D:/deck/fpga/Template_MiSTer-VIS/sim/warp_bitexact.py
```

## The authoritative model

**`warp_bitexact.py`** is a bit-faithful model of the Q15 datapath. It
**reproduces the hardware line-doubling**; the float models do **not**. For
anything about the doubling artifact or the hi-res fix, this is the judge — do
**not** trust the float models (now in [`archive/`](./archive/)).

## Current models

| File | What it's for |
|---|---|
| `warp_bitexact.py` | **Authoritative** Q15-faithful datapath; reproduces HW doubling; validates the hi-res fix. |
| `warp_model.py` | Geometry + look-family golden reference (proves `kv=0 ⇒ src_y==out_y`). |
| `gen_lut.py` | Regenerate `WARP_LUT` + calibrate `K_LUT` to a crt-royale-familiar range. |
| `warp_royale_map.py` | Map our `k`/`kv` dials onto crt-royale geom params (look / preset labels). |
| `tb_rescal.vhd` | GHDL testbench for `sys/vis_warp_rescal.vhd` (res-adaptive weights; "ALL GOLDENS PASS"). |
| `tb_warp_stage0.vhd` + `tb_stage0_check.py` | **Stage-0 engine rig** (SPEC-cylindrical §5): drives `vis_warp_v2_wp` with a synthetic grid raster, captures the output frame, and asserts `src_y==out_y` (kv=0) + straight verticals + symmetric warp. The reclaim's validation gate. GHDL: GATE PASS. |

`gen_lut.py` and `warp_royale_map.py` are **parked** — useful for the look and
preset labels once hi-res makes the look clean; they do **not** fix doubling
(sim-proven).

## GHDL

Engine analyze + elaborate (note `vis_warp_rescal.vhd` analyzes **before**
`vis_warp_v2_wp.vhd`, which instantiates it):

```
GH=/c/Users/mattl/bin/ghdl/bin/ghdl.exe ; WD=ghdl_work ; S=../sys
"$GH" -a --std=08 --workdir="$WD" \
  "$S/vis_warp_pkg_v2.vhd" "$S/vis_warp_luts_pkg.vhd" "$S/vis_warp_rescal.vhd" \
  "$S/vis_warp_v2_wp.vhd" "$S/vis_warp.vhd"
"$GH" -e --std=08 --workdir="$WD" vis_warp

# Stage-0 engine TB (run from sim/ so the frame dump path resolves):
"$GH" -a --std=08 --workdir="$WD" tb_warp_stage0.vhd
"$GH" -e --std=08 --workdir="$WD" tb_warp_stage0
"$GH" -r --std=08 --workdir="$WD" tb_warp_stage0 --stop-time=10ms
python tb_stage0_check.py     # -> STAGE-0 GATE: PASS
```

## Archived models

Superseded diagnosis / prototype models live in [`archive/`](./archive/) — see
[`archive/README.md`](./archive/README.md). Don't trust them for the doubling
artifact.

Generated renders (`warp_out/`) and the GHDL work dir (`ghdl_work/`) are
gitignored.
