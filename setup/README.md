# Setup Guide

This directory contains scripts for preparing SimPoints, checkpoints, and PGO binaries used by experiments in this repository.

## Files
- `init.sh`: central environment setup and optional runtime-file staging
- `gen-simpoints.sh`: generate SimPoint indices/weights from BBV traces
- `gen-ckpts.sh`: generate checkpoint sets from SimPoints
- `gen-pgobin.sh`: build profile-guided gem5 binaries
- `gen-mem-pgo.sh`: build a memory-stress PGO binary variant

## Prerequisites
- built `gem5.fast` binary
- SPEC CPU2017 intspeed build tree
- SimPoint binary (`simpoint`)
- `valgrind`, `python3`, `scons`
- for some flows: `llvm-profdata`, `pigz`, `rsync`

## 1) Initialize Environment
From repository root:

```bash
cd ~/ispass
source ./setup/init.sh
```

`init.sh` defines defaults for:
- `REPO_DIR`
- `RUN_LABEL`
- `SPEC_BUILT_DIR`
- `GEM5`
- `GEM5_CONFIG_BASIC`
- `GEM5_CONFIG_RUBY_4CORE`
- `SIMPOINT_BIN`
- `CHECKPOINT_BASE_DIR`
- `SIMPOINT_OUTPUT_DIR`
- `MIBENCH_BASE_DIR`
- `MIBENCH_INPUTS_DIR`
- `SPLASH_BASE_DIR`
- `OPT_REMARKS_ARCHIVE_DIR`
- `RESULTS_DIR`
- `RESULTS_DATA_DIR`
- `RESULTS_FIGS_DIR`
- `RESULTS_LOGS_DIR`
- `RESULTS_RUNDIR_DIR`

Override by exporting your own values before `source ./setup/init.sh`.

## 2) Stage SPEC Runtime Files (if needed)
Some benchmarks require input/runtime files in the repository root.

Automatic staging:

```bash
export STAGE_SPEC_RUNTIME_FILES=true
source ./setup/init.sh
```

This stages files such as:
- `cpu2017_mhonarc.rc`
- `checkspam.in`
- `ned/`
- `omnetpp.ini`
- `puzzles.txt`

## 3) Generate SimPoints

```bash
./setup/gen-simpoints.sh
```

Outputs:
- `smpt_out/<benchmark>_simpoint/<benchmark>.simpts`
- `smpt_out/<benchmark>_simpoint/<benchmark>.weights`
- logs and compressed BBV files in `smpt_out/`

## 4) Generate Checkpoints

```bash
./setup/gen-ckpts.sh
```

Outputs:
- checkpoint directories under `ckpts/` (or `CHECKPOINT_BASE_DIR` if overridden)

## 5) Generate PGO Binaries

```bash
./setup/gen-pgobin.sh
```

Primary outputs:
- PGO binaries under `pgo_bins/`
- profiles and logs under `profiles/`

Optional modes are controlled by environment toggles inside/for `gen-pgobin.sh`.

## 6) Generate Memory-Stress PGO Binary (Optional)

```bash
./setup/gen-mem-pgo.sh
```

Primary outputs:
- profile data under `profiles/memory-intensive/`
- binary under `pgo_bins/<benchmark>/`

## Troubleshooting
- `REPO_DIR` / `SPEC_BUILT_DIR` / `GEM5` / `SIMPOINT_BIN` not set:
  - export the required paths and re-source `./setup/init.sh`
- missing checkpoint path errors:
  - verify `CHECKPOINT_BASE_DIR` and benchmark/simpoint directories
- `simpoint` not executable:
  - check `SIMPOINT_BIN` path and permissions
- permission problems with perf/sysctl:
  - use appropriate sudo privileges; only enable `SET_PERF_EVENT_PARANOID=true` when needed

## Results Convention
- CSV/data files: `results/data/`
- Figures: `results/figs/`
- gem5 run directories (`--outdir`): `results/rundir/`
