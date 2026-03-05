# ISPASS Artifact: gem5 SimPoints and PGO Evaluation

This repository contains scripts to generate SimPoints/checkpoints and run PGO-vs-baseline gem5 comparisons used in the paper artifact.

## Repository Layout
- `setup/`: setup and data-generation scripts
- `gem5_config/`: gem5 Python configs used by setup and experiments
- `runscripts/`: experiment drivers
  - `fig2.sh`: Figure 2 runner (SPEC)
  - `fig8a.sh`: Figure 8a parallel-instance runner (SPEC)
  - `fig10.sh`: Figure 10 scheduling comparison runner
  - `run-speedup-analysis-by-benchmark.sh`: orchestration script for Figure 3/7 analyses
  - `run-speedup-by-benchmark.sh`: simulation backend used by speedup analysis
  - `plotters/`: figure plotters (`fig*_plotter.py`)
- `gem5/`: gem5 source/build tree
- `results/`:
  - `results/data`: CSV/data outputs
  - `results/figs`: figure outputs
  - `results/rundir`: gem5 run outputs (`--outdir`)

## Prerequisites
- Linux environment with `bash`, `sudo`, `taskset`, `flock`, `bc`
- `valgrind` (for BBV collection)
- `perf` (for Figure 2 hardware-counter collection)
- Python 3 with packages: `pandas`, `matplotlib`, `numpy`
- Built gem5 binary (`gem5.fast`) and PGO binaries (if running Fig.2 with PGO)
- SPEC CPU2017 intspeed build tree
- SimPoint binary (`simpoint`)

## Setup
This setup follows the same flow as the original project, adapted for this repo layout.

### 1) Configure environment
From repository root:

```bash
cd ~/ispass
source ./setup/init.sh
```

Key environment variables (defaults are defined in `setup/init.sh`):
- `REPO_DIR` (default: repo root)
- `SPEC_BUILT_DIR` (default: `$HOME/cpu2017/benchspec/CPU`)
- `GEM5` (default: `$REPO_DIR/gem5/build/X86/gem5.fast`)
- `GEM5_CONFIG_BASIC` (default: `$REPO_DIR/gem5_config/run-basic.py`)
- `SIMPOINT_BIN` (default: `$REPO_DIR/SimPoint.3.2/bin/simpoint`)
- `CHECKPOINT_BASE_DIR` (default: `$REPO_DIR/ckpts`)
- `RESULTS_DATA_DIR` (default: `$REPO_DIR/results/data`)
- `RESULTS_FIGS_DIR` (default: `$REPO_DIR/results/figs`)
- `RESULTS_RUNDIR_DIR` (default: `$REPO_DIR/results/rundir`)

If your paths differ, export them before running scripts, for example:

```bash
export SPEC_BUILT_DIR=/path/to/cpu2017/benchspec/CPU
export GEM5=/path/to/gem5/build/X86/gem5.fast
export SIMPOINT_BIN=/path/to/SimPoint.3.2/bin/simpoint
source ./setup/init.sh
```

### 2) Build SPEC CPU2017 workloads
Example:

```bash
runcpu --config=x86 --tune=base --action=runsetup intspeed
```

### 3) Stage SPEC runtime files required by some benchmarks
Option A (automatic copy using init toggle):

```bash
export STAGE_SPEC_RUNTIME_FILES=true
source ./setup/init.sh
```

Option B (manual links/copies) is also fine if you prefer your existing workflow.

### 4) Generate SimPoints

```bash
./setup/gen-simpoints.sh
```

Outputs are written under `smpt_out/`.

### 5) Generate gem5 checkpoints

```bash
./setup/gen-ckpts.sh
```

Outputs are written under `ckpts/` (or your `CHECKPOINT_BASE_DIR`).

### 6) Generate PGO binaries (if needed)

```bash
./setup/gen-pgobin.sh
```

Outputs are written under `pgo_bins/`.

## Experiments

### Figure 2: PGO vs Baseline (SPEC)
Run from repo root:

```bash
source ./setup/init.sh
./runscripts/fig2.sh
```

What it does:
- runs baseline and PGO gem5 binaries on predefined benchmark/simpoint pairs
- collects execution time from `stats.txt`
- collects `L1-icache-load-misses`, `instructions`, and `iTLB-load-misses` via `perf stat`
- writes CSV and generates plots

Outputs:
- CSV: `results/data/fig2_data.csv`
- Plots:
  - `results/figs/fig2.pdf`
  - `results/figs/fig2.png`
  - `results/figs/fig2_itlb.pdf`
  - `results/figs/fig2_itlb.png`

Plot-only mode:

```bash
./runscripts/fig2.sh --plot-only
```

Notes:
- `fig2.sh` resumes automatically and skips entries already present in CSV.
- default parallelism is 20 jobs pinned to cores `0..19`.
- `sudo perf` is required in this script.

### Figure 3 / 7 Pipeline
Run from repo root:

```bash
source ./setup/init.sh
./runscripts/run-speedup-analysis-by-benchmark.sh
```

Common outputs:
- data (`results/data`):
  - `execution_times.csv`
  - `aggregated_times.csv`
  - `speedup_matrix.csv`
  - `fig7_data.csv` (when `--eval-pgos`)
  - `fig7_mibench_data.csv` (when `--eval-pgos-mibench`)
- figures (`results/figs`):
  - `fig3.png` / `fig3.pdf` (heatmap)
  - `fig7.png` / `fig7.pdf` (SPEC PGO evaluation, when `--eval-pgos`)
  - `fig7_mibench.png` / `fig7_mibench.pdf` (MiBench PGO evaluation, when `--eval-pgos-mibench`)

Common options:

```bash
./runscripts/run-speedup-analysis-by-benchmark.sh --only-heatmap
./runscripts/run-speedup-analysis-by-benchmark.sh --eval-pgos
./runscripts/run-speedup-analysis-by-benchmark.sh --eval-pgos-mibench
```

### Figure 4: Benchmark Stats Plot
Run from repo root:

```bash
source ./setup/init.sh
python3 ./runscripts/plotters/fig4_plotter.py
```

Outputs:
- data: `results/data/fig4_data.csv`
- figures: `results/figs/fig4.png`, `results/figs/fig4.pdf`

### Figure 8a: Parallel Instances Scaling
Run from repo root:

```bash
source ./setup/init.sh
./runscripts/fig8a.sh
```

What it does:
- runs multiple `gem5.fast` instances in parallel for the same benchmark+simpoint
- measures per-instance execution time from `stats.txt`
- measures cache and memory-bandwidth metrics with `perf`
- records per-instance memory footprint (RSS)
- generates Figure 8a automatically at the end of the run

Outputs:
- data: `results/data/fig8a_data.csv`
- figures: `results/figs/fig8a.png`, `results/figs/fig8a.pdf`
- run directories/logs: `results/rundir/fig8a/`

Notes:
- mixed mode is removed in this port; only single-benchmark parallel mode is supported.
- use environment variables (for example `BENCHMARKS`, `SIMPOINT_INDICES`, `NUM_REPEATS`) to control runs.

### Figure 10: Scheduling Comparison
Run from repo root:

```bash
source ./setup/init.sh
./runscripts/fig10.sh
python3 ./runscripts/plotters/fig10_plotter.py
```

What it does:
- runs the same workload set with two scheduling strategies (`baseline` and `balanced`)
- monitors CPU utilization, memory usage, and running job count over time
- writes per-schedule monitoring traces and a throughput summary

Outputs:
- data:
  - `results/data/fig10_monitoring_baseline.csv`
  - `results/data/fig10_monitoring_balanced.csv`
- figures:
  - `results/figs/fig10.png`
  - `results/figs/fig10.pdf`
- logs:
  - `results/logs/fig10_summary.txt`
- run directories:
  - `results/rundir/fig10/`

## Troubleshooting
- `REPO_DIR environment variable is not set`:
  - run `source ./setup/init.sh` from repo root
- `SPEC_BUILT_DIR`/`SIMPOINT_BIN`/`GEM5` path errors:
  - export the correct paths, then re-source `setup/init.sh`
- `perf` permission issues:
  - ensure your system allows perf for your user, or run with required sudo privileges
