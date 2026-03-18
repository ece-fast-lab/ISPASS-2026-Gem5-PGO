# ISPASS Artifact: gem5 SimPoints and PGO Evaluation

This repository contains setup scripts and run scripts to reproduce the paper figures with gem5.

## Repository Structure
- `setup/`: environment setup, SimPoint/checkpoint/PGO generation
- `gem5_config/`: gem5 config scripts
- `runscripts/`: figure run scripts
- `runscripts/plotters/`: figure plot scripts
- `results/data/`: CSV outputs
- `results/figs/`: generated figures
- `results/rundir/`: gem5 run directories

## Prerequisites
- Linux with: `bash`, `taskset`, `flock`, `bc`, `perf`, `valgrind`
- Python 3 with: `pandas`, `numpy`, `matplotlib`, `seaborn`
- Built `gem5.fast`
- SPEC CPU2017 build tree
- SimPoint binary

## Setup
### 0) Create the Python environment
Create and activate the repo-local virtual environment, then install the plotting dependencies:
```bash
python3 -m venv .venv
source ./.venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

### 1) Edit paths in `setup/init.sh` (required)
Before sourcing `init.sh`, manually set your local paths in the block around lines 6-14:
- `CHECKPOINT_BASE_DIR`
- `SPEC_BUILT_DIR`
- `MIBENCH_BASE_DIR`
- `MIBENCH_INPUTS_DIR`
- `SPLASH_BASE_DIR`

### 2) Source environment
- Exports shared variables used by setup and run scripts.
- Ensures `results/data`, `results/figs`, `results/logs`, and `results/rundir` exist.
- Stages required SPEC runtime files to repo root only when missing.
```bash
source ./setup/init.sh
```


### 3) Build SPEC workloads (example)
```bash
runcpu --config=x86 --tune=base --action=runsetup intspeed
```

Result:
- Built SPEC benchmark binaries under your configured `SPEC_BUILT_DIR`.

### 4) Generate required artifacts
```bash
./setup/gen-simpoints.sh
./setup/gen-ckpts.sh
./setup/gen-pgobin.sh
# Optional coarse PGO (per-benchmark, not per-simpoint):
# ./setup/gen-pgobin-coarse.sh
```

What each script produces:
- `gen-simpoints.sh`:
  - SimPoint files under `smpt_out/` (`*.simpts`, `*.weights`, logs/BBV files).
- `gen-ckpts.sh`:
  - Checkpoint directories under `CHECKPOINT_BASE_DIR` (or `ckpts/` if configured that way).
- `gen-pgobin.sh`:
  - PGO binaries under `pgo_bins/` and profile/build logs under `profiles/`.
- `gen-pgobin-coarse.sh` (optional):
  - Coarse per-benchmark PGO binaries from merged `profiles/bench/*.profdata` files.

Quick validation before running figures:
- SimPoint directories exist in `smpt_out/`.
- Checkpoints exist for target benchmarks/simpoints in `CHECKPOINT_BASE_DIR`.
- Required PGO binaries exist in `pgo_bins/` (for figures that use them).

## Run Figures
Run from repo root after `source ./setup/init.sh`.

### Figure 2
Purpose:
- Compares baseline `gem5.fast` vs benchmark-specific PGO binaries on selected SPEC benchmark/simpoint pairs.
- Collects execution time and front-end miss statistics used in the paper’s Figure 2.

```bash
./runscripts/run_fig2.sh
```
Optional plot-only:
```bash
./runscripts/run_fig2.sh --plot-only
```

### Figure 3 / Figure 4
Purpose:
- Runs benchmark-level speedup simulations across checkpoints/simpoints.
- Produces aggregated speedup data used for Figure 3 (heatmap).
- Produces stats input used by the Figure 4 plotter.

```bash
./runscripts/run_fig347.sh
```

### Figure 7a (SPEC PGO eval)
Purpose:
- Evaluates additional SPEC PGO variants (self/unified/top10/clustering/mem) and generates Figure 7a data/plots.

```bash
./runscripts/run_fig347.sh --eval-pgos
```


### Figure 8a
Purpose:
- Runs multiple parallel instances of the same benchmark+simpoint to measure scaling behavior, cache effects, and memory pressure.

```bash
./runscripts/run_fig8a.sh
```

### Figure 10
Purpose:
- Compares two scheduling policies (`baseline` vs `balanced`) while tracking utilization and memory behavior.

```bash
./runscripts/run_fig10.sh
python3 ./runscripts/plotters/fig10_plotter.py
```

## Outputs
- Data CSVs: `results/data/`
- Figures: `results/figs/`
- gem5 run outputs: `results/rundir/`

Typical files:
- Figure 2:
  - `results/data/fig2_data.csv`
  - `results/figs/fig2.png`, `results/figs/fig2.pdf`
  - `results/figs/fig2_itlb.png`, `results/figs/fig2_itlb.pdf`
  - `results/rundir/fig2/`
- Figures 3/4/7:
  - `results/data/execution_times.csv`
  - `results/data/aggregated_times.csv`
  - `results/data/speedup_matrix.csv`
  - `results/data/fig4_data.csv`
  - `results/data/fig7_data.csv` (Figure 7a mode)
  - `results/data/fig7_mibench_data.csv` (Figure 7b mode)
  - `results/figs/fig3.png`, `results/figs/fig3.pdf`
  - `results/figs/fig4.png`, `results/figs/fig4.pdf`
  - `results/figs/fig7.png`, `results/figs/fig7.pdf`
  - `results/figs/fig7_mibench.png`, `results/figs/fig7_mibench.pdf`
  - `results/rundir/speedup-bench/`
- Figure 8a:
  - `results/data/fig8a_data.csv`
  - `results/figs/fig8a.png`, `results/figs/fig8a.pdf`
  - `results/rundir/fig8a/`
- Figure 10:
  - `results/data/fig10_monitoring_baseline.csv`
  - `results/data/fig10_monitoring_balanced.csv`
  - `results/figs/fig10.png`, `results/figs/fig10.pdf`
  - `results/logs/fig10_summary.txt`
  - `results/rundir/fig10/`
