# Archived sim models

Superseded diagnosis / prototype models, kept for history. **None of these is the
trusted model for the line-doubling artifact** — that's the bit-exact
[`../warp_bitexact.py`](../warp_bitexact.py). See [`../README.md`](../README.md).

| File | Was | Superseded by / outcome |
|---|---|---|
| `warp_line_artifact.py` | Reproduce the doubling + test soft-LUT/sharpness fixes | **Float model — did NOT reproduce the doubling.** Replaced by `warp_bitexact.py`. |
| `warp_faithful_2d.py` | 2-D faithful render to diagnose irregular spacing | Diagnosis done; HW-faithfulness now lives in `warp_bitexact.py`. |
| `warp_prototype.py` | Prototype res-adaptive calibration + Jacobian prefilter | Res-adaptive shipped (`sys/vis_warp_rescal.vhd`); prefilter validated unnecessary. |
| `warp_prefilter.py` | Validate the Jacobian-gated minification prefilter | Prefilter **validated UNNECESSARY** at source-res (see `RESEARCH-warp-quality-2026-05-29.md`). |
| `warp_fill_1d.py` | Find the horizontal fill-compensation scale | Fill constant (27458) locked. |
| `warp_fill_band.py` | Over/under-fill band: one constant vs 8-entry LUT | Single-constant fill accepted. |
| `warp_compare.py` | Oval (X-barrel) vs separable-cylinder diagnosis render | Cylinder direction locked (`SPEC-cylindrical-warp.md`). |
