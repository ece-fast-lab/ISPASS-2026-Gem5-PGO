#!/bin/bash

# Main orchestration script for benchmark-level PGO speedup analysis
# This script coordinates the entire workflow:
#   1. Run simulations (baseline + PGO for all simpoints)
#   2. Generate heatmap visualization with aggregated results

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLOTTERS_DIR="$SCRIPT_DIR/plotters"
SETUP_INIT_SH="$SCRIPT_DIR/../setup/init.sh"

if [ -f "$SETUP_INIT_SH" ]; then
  # shellcheck source=/dev/null
  source "$SETUP_INIT_SH"
fi

# Configuration
# Full benchmark list (commented out for testing)
# export BENCHMARKS="600.perlbench_s.0 602.gcc_s.0 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0"
export BENCHMARKS="600.perlbench_s.0 602.gcc_s.0 605.mcf_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0"

# Test configuration
# export BENCHMARKS=${BENCHMARKS:-"602.gcc_s.0 605.mcf_s"}
export MAX_PARALLEL=${MAX_PARALLEL:-16}
export NUM_ITERATIONS=${NUM_ITERATIONS:-3}

# Check environment
if [ -z "$REPO_DIR" ]; then
  echo "ERROR: REPO_DIR not set. Please source init.sh first."
  exit 1
fi

if [ -z "$SPEC_BUILT_DIR" ]; then
  echo "ERROR: SPEC_BUILT_DIR not set. Please source init.sh first."
  exit 1
fi

RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$REPO_DIR/results/data}"
RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$REPO_DIR/results/figs}"
RESULTS_LOGS_DIR="${RESULTS_LOGS_DIR:-$REPO_DIR/results/logs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_LOGS_DIR" "$RESULTS_RUNDIR_DIR"
export RESULTS_DATA_DIR RESULTS_FIGS_DIR RESULTS_LOGS_DIR RESULTS_RUNDIR_DIR

PLOT_FAILURES=()

run_plot_step() {
  local step_label="$1"
  local success_label="$2"
  local log_file="$3"
  shift 3

  echo "Logging output to: $log_file"

  if "$@" > "$log_file" 2>&1; then
    echo ""
    echo "$success_label"
    echo "Log saved to: $log_file"
    return 0
  fi

  echo "WARNING: $step_label failed. Check log: $log_file"
  PLOT_FAILURES+=("$step_label ($log_file)")
  return 1
}

# Parse command line arguments
SKIP_SIMULATIONS=false
SKIP_HEATMAP=false
HEATMAP_AUTO_SKIPPED=false
export EVAL_PGOS=false
SKIP_PGO_EVAL_BAR=false
export EVAL_PGOS_MIBENCH=false
export EVAL_PGOS_SPLASH=false
export EVAL_PGOS_SPLASH_4CORE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-simulations)
      SKIP_SIMULATIONS=true
      shift
      ;;
    --skip-heatmap)
      SKIP_HEATMAP=true
      shift
      ;;
    --only-heatmap)
      SKIP_SIMULATIONS=true
      shift
      ;;
    --eval-pgos)
      export EVAL_PGOS=true
      shift
      ;;
    --skip-pgo-eval-bar)
      SKIP_PGO_EVAL_BAR=true
      shift
      ;;
    --eval-pgos-mibench)
      export EVAL_PGOS_MIBENCH=true
      shift
      ;;
    --eval-pgos-splash)
      export EVAL_PGOS_SPLASH=true
      shift
      ;;
    --eval-pgos-splash-4core)
      export EVAL_PGOS_SPLASH_4CORE=true
      shift
      ;;
    --benchmarks)
      export BENCHMARKS="$2"
      shift 2
      ;;
    --num-iterations)
      export NUM_ITERATIONS="$2"
      shift 2
      ;;
    --max-parallel)
      export MAX_PARALLEL="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --benchmarks \"B1 B2...\" Space-separated benchmark names"
      echo "                           (default: \"602.gcc_s.0 605.mcf_s 623.xalancbmk_s\")"
      echo "  --num-iterations N      Number of iterations per run (default: 3)"
      echo "  --max-parallel N        Max parallel jobs (default: 16)"
      echo "  --skip-simulations      Skip simulations (only generate heatmap)"
      echo "  --only-heatmap          Alias for --skip-simulations"
      echo "  --skip-heatmap          Skip heatmap generation"
      echo "  --eval-pgos             Evaluate additional PGO variants (self, unified, clustering, top10, mem)"
      echo "  --skip-pgo-eval-bar     Skip PGO evaluation bar graph generation"
      echo "  --eval-pgos-mibench     Evaluate PGO variants on MiBench benchmarks (unified, top10, clustering, mem)"
      echo "  --eval-pgos-splash      Evaluate PGO variants on Splash benchmarks (self, mem, mem-minor) - 1-core"
      echo "  --eval-pgos-splash-4core Evaluate PGO variants on Splash-4core benchmarks (self, mem, mem-minor, mem-minor-ruby) - 4-core"
      echo "  -h, --help              Show this help message"
      echo ""
      echo "Available benchmarks:"
      echo "  600.perlbench_s.0, 600.perlbench_s.1, 600.perlbench_s.2"
      echo "  602.gcc_s.0, 602.gcc_s.1, 602.gcc_s.2"
      echo "  605.mcf_s, 620.omnetpp_s, 625.x264_s.0"
      echo "  623.xalancbmk_s, 631.deepsjeng_s, 641.leela_s"
      echo "  648.exchange2_s, 657.xz_s.0, 657.xz_s.1"
      echo ""
      echo "Examples:"
      echo "  $0                                                        # Run full analysis (3 test benchmarks)"
      echo "  $0 --skip-simulations                                    # Regenerate heatmap only"
      echo "  $0 --benchmarks \"602.gcc_s.0 605.mcf_s\" --num-iterations 2"
      echo "  $0 --benchmarks \"602.gcc_s.0 605.mcf_s 623.xalancbmk_s\" --max-parallel 20"
      echo ""
      echo "Full benchmark list example:"
      echo "  $0 --benchmarks \"602.gcc_s.0 602.gcc_s.1 605.mcf_s 623.xalancbmk_s 631.deepsjeng_s\""
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ "$SKIP_HEATMAP" = false ] && \
   { [ "$EVAL_PGOS" = true ] || [ "$EVAL_PGOS_MIBENCH" = true ] || [ "$EVAL_PGOS_SPLASH" = true ] || [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; }; then
  SKIP_HEATMAP=true
  HEATMAP_AUTO_SKIPPED=true
fi

echo "========================================================================"
echo "            BENCHMARK-LEVEL PGO SPEEDUP ANALYSIS"
echo "========================================================================"
echo "Configuration:"
echo "  Benchmarks:        $BENCHMARKS"
echo "  Iterations/run:    $NUM_ITERATIONS"
echo "  Max parallel:      $MAX_PARALLEL"
echo "  PGO Evaluation:    $([ "$EVAL_PGOS" = true ] && echo "ENABLED" || echo "DISABLED")"
echo "  MiBench Eval:      $([ "$EVAL_PGOS_MIBENCH" = true ] && echo "ENABLED" || echo "DISABLED")"
echo "  Splash Eval:       $([ "$EVAL_PGOS_SPLASH" = true ] && echo "ENABLED" || echo "DISABLED")"
echo "  Splash 4-core:     $([ "$EVAL_PGOS_SPLASH_4CORE" = true ] && echo "ENABLED" || echo "DISABLED")"
echo ""
echo "Workflow:"
echo "  Simulations:       $([ "$SKIP_SIMULATIONS" = true ] && echo "SKIP" || echo "RUN")"
if [ "$HEATMAP_AUTO_SKIPPED" = true ]; then
  echo "  Heatmap:           SKIP (eval mode)"
else
  echo "  Heatmap:           $([ "$SKIP_HEATMAP" = true ] && echo "SKIP" || echo "GENERATE")"
fi
if [ "$EVAL_PGOS" = true ]; then
  echo "  PGO Eval Bar:      $([ "$SKIP_PGO_EVAL_BAR" = true ] && echo "SKIP" || echo "GENERATE")"
fi
echo "========================================================================"
echo ""

# Step 1: Run simulations
if [ "$SKIP_SIMULATIONS" = false ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 1: Running Simulations (Baseline + PGO)"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/run-speedup.log"
  echo "Logging output to: $LOG_FILE"

  bash "$SCRIPT_DIR/run_fig347_backend.sh" > "$LOG_FILE" 2>&1

  if [ $? -ne 0 ]; then
    echo "ERROR: Simulations failed. Check log: $LOG_FILE"
    exit 1
  fi

  echo ""
  echo "Simulations completed successfully"
  echo "Log saved to: $LOG_FILE"
else
  echo ""
  echo "Skipping simulations (--skip-simulations)"
fi

# Step 2: Generate heatmap
if [ "$SKIP_HEATMAP" = false ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 2: Generating Speedup Heatmap"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/generate-heatmap.log"
  if [ -f "$RESULTS_DATA_DIR/execution_times.csv" ]; then
    if ! run_plot_step \
      "Heatmap generation" \
      "Heatmap generated successfully" \
      "$LOG_FILE" \
      python3 "$PLOTTERS_DIR/fig3_plotter.py" \
      --benchmarks "$BENCHMARKS" \
      --num-iterations "$NUM_ITERATIONS"; then
      :
    fi
  else
    echo "Skipping heatmap generation (missing $RESULTS_DATA_DIR/execution_times.csv)"
  fi
else
  echo ""
  if [ "$HEATMAP_AUTO_SKIPPED" = true ]; then
    echo "Skipping heatmap generation (eval mode)"
  else
    echo "Skipping heatmap generation (--skip-heatmap)"
  fi
fi

# Step 3: Generate PGO evaluation bar graph (if enabled)
if [ "$EVAL_PGOS" = true ] && [ "$SKIP_PGO_EVAL_BAR" = false ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 3: Generating PGO Evaluation Bar Graph"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/generate-pgo-eval-bar.log"
  if [ -f "$RESULTS_DATA_DIR/execution_times.csv" ]; then
    if ! run_plot_step \
      "PGO evaluation bar graph generation" \
      "PGO evaluation bar graph generated successfully" \
      "$LOG_FILE" \
      python3 "$PLOTTERS_DIR/fig7_plotter.py" \
      --benchmarks "$BENCHMARKS" \
      --num-iterations "$NUM_ITERATIONS"; then
      :
    fi
  else
    echo "Skipping PGO evaluation bar graph generation (missing $RESULTS_DATA_DIR/execution_times.csv)"
  fi
elif [ "$EVAL_PGOS" = true ]; then
  echo ""
  echo "Skipping PGO evaluation bar graph generation (--skip-pgo-eval-bar)"
fi

# Step 4: Generate MiBench PGO evaluation bar graph (if enabled)
if [ "$EVAL_PGOS_MIBENCH" = true ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 4: Generating MiBench PGO Evaluation Bar Graph"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/generate-mibench-eval-bar.log"
  if [ -f "$RESULTS_DATA_DIR/mibench_execution_times.csv" ]; then
    if ! run_plot_step \
      "MiBench PGO evaluation bar graph generation" \
      "MiBench PGO evaluation bar graph generated successfully" \
      "$LOG_FILE" \
      python3 "$PLOTTERS_DIR/fig7b_plotter.py" \
      --num-iterations "$NUM_ITERATIONS"; then
      :
    fi
  else
    echo "Skipping MiBench PGO evaluation bar graph generation (missing $RESULTS_DATA_DIR/mibench_execution_times.csv)"
  fi
fi

# Step 5: Generate Splash PGO evaluation bar graph (if enabled)
if [ "$EVAL_PGOS_SPLASH" = true ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 5: Generating Splash PGO Evaluation Bar Graph"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/generate-splash-eval-bar.log"
  if [ -f "$RESULTS_DATA_DIR/splash_execution_times.csv" ]; then
    if ! run_plot_step \
      "Splash PGO evaluation bar graph generation" \
      "Splash PGO evaluation bar graph generated successfully" \
      "$LOG_FILE" \
      python3 "$PLOTTERS_DIR/fig7c_plotter.py" \
      --num-iterations "$NUM_ITERATIONS"; then
      :
    fi
  else
    echo "Skipping Splash PGO evaluation bar graph generation (missing $RESULTS_DATA_DIR/splash_execution_times.csv)"
  fi
fi

# Step 6: Generate Splash 4-core PGO evaluation bar graph (if enabled)
if [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; then
  echo ""
  echo "========================================================================"
  echo "STEP 6: Generating Splash 4-Core PGO Evaluation Bar Graph"
  echo "========================================================================"
  echo ""

  LOG_FILE="$RESULTS_LOGS_DIR/generate-splash-4core-eval-bar.log"
  if [ -f "$RESULTS_DATA_DIR/splash_4core_execution_times.csv" ]; then
    if ! run_plot_step \
      "Splash 4-core PGO evaluation bar graph generation" \
      "Splash 4-core PGO evaluation bar graph generated successfully" \
      "$LOG_FILE" \
      python3 "$PLOTTERS_DIR/fig7d_plotter.py" \
      --num-iterations "$NUM_ITERATIONS"; then
      :
    fi
  else
    echo "Skipping Splash 4-core PGO evaluation bar graph generation (missing $RESULTS_DATA_DIR/splash_4core_execution_times.csv)"
  fi
fi

if [ ${#PLOT_FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "Plot generation completed with warnings:"
  for failure in "${PLOT_FAILURES[@]}"; do
    echo "  - $failure"
  done
fi

# Final summary
echo ""
echo "========================================================================"
echo "                    ANALYSIS COMPLETE"
echo "========================================================================"
echo ""
echo "Results data directory: $RESULTS_DATA_DIR"
echo "Results figures directory: $RESULTS_FIGS_DIR"
echo ""
echo "Output files:"
echo "  - execution_times.csv     Raw execution times for all simpoints"
echo "  - aggregated_times.csv    Aggregated times by benchmark"
echo "  - speedup_matrix.csv      Speedup values in matrix form"
echo "  - fig3.png/pdf            Heatmap visualization (Figure 3)"
if [ "$EVAL_PGOS" = true ]; then
  echo "  - fig7.png/pdf                 SPEC PGO evaluation bar graph"
  echo "  - fig7_data.csv                SPEC PGO evaluation data"
fi
if [ "$EVAL_PGOS_MIBENCH" = true ]; then
  echo "  - mibench_execution_times.csv   MiBench execution times (baseline + PGO variants)"
  echo "  - fig7_mibench.png/pdf          MiBench PGO evaluation bar graph"
  echo "  - fig7_mibench_data.csv        MiBench PGO evaluation data"
fi
if [ "$EVAL_PGOS_SPLASH" = true ]; then
  echo "  - splash_execution_times.csv    Splash execution times (baseline + PGO variants)"
  echo "  - fig7c.png/pdf                 Splash PGO evaluation bar graph"
  echo "  - fig7c_legend.png/pdf          Splash legend figure"
  echo "  - fig7c_data.csv                Splash PGO evaluation data"
fi
if [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; then
  echo "  - splash_4core_execution_times.csv  Splash 4-core execution times (baseline + PGO variants)"
  echo "  - fig7d.png/pdf                      Splash 4-core PGO evaluation bar graph"
  echo "  - fig7d_legend.png/pdf               Splash 4-core legend figure"
  echo "  - fig7d_data.csv                     Splash 4-core PGO evaluation data"
fi
echo ""
echo "Log files:"
echo "  - $RESULTS_LOGS_DIR/run-speedup.log"
echo "  - $RESULTS_LOGS_DIR/generate-heatmap.log"
if [ "$EVAL_PGOS" = true ]; then
  echo "  - $RESULTS_LOGS_DIR/generate-pgo-eval-bar.log"
fi
if [ "$EVAL_PGOS_MIBENCH" = true ]; then
  echo "  - $RESULTS_LOGS_DIR/generate-mibench-eval-bar.log"
fi
if [ "$EVAL_PGOS_SPLASH" = true ]; then
  echo "  - $RESULTS_LOGS_DIR/generate-splash-eval-bar.log"
fi
if [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; then
  echo "  - $RESULTS_LOGS_DIR/generate-splash-4core-eval-bar.log"
fi
echo ""
echo "To regenerate the heatmap only:"
echo "  $0 --only-heatmap"
echo ""
echo "To resume interrupted simulations:"
echo "  $0"
echo "  (Existing results in CSV will be skipped automatically)"
echo "========================================================================"

if [ ${#PLOT_FAILURES[@]} -gt 0 ]; then
  exit 1
fi
