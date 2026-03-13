# Setup Guide

This directory contains setup scripts for generating SimPoints, checkpoints, and PGO binaries.

## Scripts
- `init.sh`: shared environment setup
- `gen-simpoints.sh`: SimPoint generation
- `gen-ckpts.sh`: checkpoint generation
- `gen-pgobin.sh`: PGO gem5 binary generation
- `gen-pgobin-coarse.sh`: coarse PGO build (one binary per benchmark, from merged per-benchmark profdata)
- `gen-pgobin-universal.sh`: universal-candidate PGO build from `profiles/univ_cand/*.profdata` (optional)

## Prerequisites
- built `gem5.fast`
- SPEC CPU2017 build tree
- SimPoint binary
- `valgrind`, `python3`, `scons`
- optional tools used by some flows: `llvm-profdata`, `pigz`, `rsync`

## 1) Configure `init.sh` paths (required)
Before sourcing, edit path definitions in `setup/init.sh` around lines 6-14:
- `CHECKPOINT_BASE_DIR`
- `SPEC_BUILT_DIR`
- `MIBENCH_BASE_DIR`
- `MIBENCH_INPUTS_DIR`
- `SPLASH_BASE_DIR`

Then source from repo root:

```bash
source ./setup/init.sh
```

Notes:
- `init.sh` also stages required SPEC runtime files automatically if they are missing in repo root.
- You can still override variables by exporting custom values before `source ./setup/init.sh`.
- If these paths are wrong, downstream setup scripts will fail with missing benchmark/checkpoint errors.

## 2) Generate SimPoints
```bash
./setup/gen-simpoints.sh
```
What it does:
- Runs BBV collection and SimPoint clustering for configured benchmarks.

Expected results:
- `smpt_out/<bench>_simpoint/<bench>.simpts`
- `smpt_out/<bench>_simpoint/<bench>.weights`
- per-benchmark logs and BBV files in `smpt_out/`

## 3) Generate Checkpoints
```bash
./setup/gen-ckpts.sh
```
What it does:
- Uses SimPoint files to create restoreable gem5 checkpoints for each benchmark/simpoint.

Expected results:
- checkpoint directories under `CHECKPOINT_BASE_DIR/<bench>/<simpoint>/`
- checkpoint-generation logs in the script’s configured output/log paths

## 4) Generate PGO Binaries
```bash
./setup/gen-pgobin.sh
```
What it does:
- Builds instrumented gem5 binaries, runs profiling workloads, merges profiles, and builds PGO binaries.

Expected results:
- benchmark PGO binaries under `pgo_bins/` (for example `pgo_bins/<bench>/gem5.pgo`)
- profile/build/run logs under `profiles/`

### 4a) MiBench PGO (optional)
```bash
./setup/gen-pgobin.sh --build-mibench-pgo
```
What it does:
- Runs the full MiBench pipeline (instrumented build, profile run, merge, PGO build, copy).
- Skips SPEC processing in this mode.

Required setup in `init.sh`:
- `MIBENCH_BASE_DIR`
- `MIBENCH_INPUTS_DIR`

Expected results:
- PGO binaries under `pgo_bins/mibench/<bench>/gem5.pgo`
- profiling artifacts under `profiles/mibench-*.profraw` and `profiles/mibench-*.profdata`
- per-benchmark pipeline logs under `profiles/build_logs/pipeline-mibench-*.log`
- run directories under `results/rundir/pgo-setup/mibench-inst-*`

### 4b) Splash PGO (optional, 1-core)
```bash
./setup/gen-pgobin.sh --build-splash-pgo
```
What it does:
- Runs the full Splash-3 1-core pipeline (instrumented build, profile run, merge, PGO build, copy).
- Skips SPEC processing in this mode.

Required setup in `init.sh`:
- `SPLASH_BASE_DIR`

Expected results:
- PGO binaries under `pgo_bins/splash/<bench>/gem5.pgo`
- profiling artifacts under `profiles/splash-*.profraw` and `profiles/splash-*.profdata`
- per-benchmark pipeline logs under `profiles/build_logs/pipeline-splash-*.log`
- run directories under `results/rundir/pgo-setup/splash-inst-*`

### 4c) Splash PGO (optional, 4-core Ruby)
```bash
./setup/gen-pgobin.sh --build-splash-4core-pgo
```
What it does:
- Runs the Splash-3 4-core pipeline using `gem5_config/run-ruby-4core.py`.
- Skips SPEC processing in this mode.

Expected results:
- PGO binaries under `pgo_bins/splash-4core/<bench>/gem5.pgo`
- profiling artifacts under `profiles/splash-*.profraw` and `profiles/splash-*.profdata` (shared naming with Splash modes)
- per-benchmark pipeline logs under `profiles/build_logs/pipeline-splash-4core-*.log`
- run directories under `results/rundir/pgo-setup/splash-inst-*`

### 4d) Generate Coarse PGO Binaries (per benchmark, optional)
```bash
./setup/gen-pgobin-coarse.sh
```
What it does:
- Builds one PGO binary per benchmark using pre-merged profdata files (`profiles/bench/*.profdata`), not per-simpoint profiles.

Expected results:
- coarse benchmark PGO binaries under `pgo_bins/<bench>/gem5.pgo`
- build logs under `results/logs/pgo_build_logs/`

## 5) Optional: Universal-Candidate PGO Binaries
```bash
./setup/gen-pgobin-universal.sh
```
What it does:
- Builds one PGO binary per `profiles/univ_cand/<name>.profdata`.

Expected results:
- binaries under `pgo_bins/univ_cand/<name>.pgo`
- build logs under `results/logs/pgo_build_logs/`

## How Setup Artifacts Map to Experiments
- `smpt_out/`: SimPoint indices/weights consumed by checkpoint generation.
- `ckpts/` or `CHECKPOINT_BASE_DIR`: checkpoint sets consumed by run scripts (for example Figure 2 and Figure 3/4/7 pipeline).
- `pgo_bins/`: PGO gem5 binaries consumed by Figure 2 and Figure 7 evaluations.
- `profiles/`: profile data and intermediate build artifacts used to produce `pgo_bins/`.

Experiment outputs are written by run scripts (not setup scripts):
- CSV/data: `results/data/`
- Figures: `results/figs/`
- gem5 run directories (`--outdir`): `results/rundir/`
- logs: `results/logs/`

## Troubleshooting
- Path errors (`SPEC_BUILT_DIR`, `CHECKPOINT_BASE_DIR`, `SIMPOINT_BIN`, `GEM5`):
  - fix paths in `setup/init.sh`, then source it again.
- Missing SPEC runtime files:
  - ensure SPEC build directories exist and match `RUN_LABEL` in `init.sh`.
- SimPoint execution issues:
  - verify `SIMPOINT_BIN` path and executable permissions.
