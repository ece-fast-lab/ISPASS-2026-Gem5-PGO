#!/usr/bin/env bash

# Figure 2 runner: SPEC baseline vs PGO comparison
#
# Usage:
#   ./runscripts/fig2.sh              # Run simulations and generate plots
#   ./runscripts/fig2.sh --plot-only  # Generate plots only from existing CSV
#   ./runscripts/fig2.sh --help       # Show help
#
# Resume behavior:
#   - Results are appended to CSV after each completion
#   - Existing benchmark+simpoint+binary_type rows are skipped

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_INIT_SH="$SCRIPT_DIR/../setup/init.sh"

if [ -f "$SETUP_INIT_SH" ]; then
  # shellcheck source=/dev/null
  source "$SETUP_INIT_SH"
fi

PLOT_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --plot-only)
      PLOT_ONLY=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --plot-only    Generate plots only, skip simulations"
      echo "  --help, -h     Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

if [ -z "${REPO_DIR:-}" ]; then
  echo "REPO_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

if [ "$PLOT_ONLY" = false ] && [ -z "${SPEC_BUILT_DIR:-}" ]; then
  echo "SPEC_BUILT_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

# Configuration
MAX_PARALLEL=${MAX_PARALLEL:-20}
CPU_CORES=($(seq 0 19))
RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
BASELINE_BINARY="${BASELINE_BINARY:-${GEM5:-$REPO_DIR/gem5/build/X86/gem5.fast}}"
PGO_BINS_DIR="${PGO_BINS_DIR:-$REPO_DIR/pgo_bins}"
GEM5_CONFIG="${GEM5_CONFIG:-${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}}"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$REPO_DIR/results/data}"
RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$REPO_DIR/results/figs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
CSV_FILE="$RESULTS_DATA_DIR/fig2_data.csv"
PLOTTERS_DIR="$SCRIPT_DIR/plotters"
SPEC_PLOT_SCRIPT="$PLOTTERS_DIR/fig2_plotter.py"

export PGO_COMPARISON_RESULTS_DIR="$RESULTS_DATA_DIR"
export FIG2_CSV_FILE="$CSV_FILE"
export FIG2_MAIN_FIG="$RESULTS_FIGS_DIR/fig2"
export FIG2_ITLB_FIG="$RESULTS_FIGS_DIR/fig2_itlb"

if [ "$PLOT_ONLY" = false ] && [ ! -f "$GEM5_CONFIG" ]; then
  echo "GEM5 config not found: $GEM5_CONFIG"
  exit 1
fi

mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_RUNDIR_DIR/fig2"

if [ ! -f "$CSV_FILE" ]; then
  echo "benchmark,simpoint,binary_type,exec_time,icache_misses,instructions,icache_miss_rate,itlb_misses,itlb_accesses,itlb_miss_rate" > "$CSV_FILE"
fi

# Benchmark-simpoint combinations to run
# Format: "benchmark_id:simpoint_id"
BENCHMARK_SIMPOINT_COMBINATIONS=(
  "600:17"
  "602:1"
  "605:5"
  "620:9"
  "623:16"
  "625:1"
  "631:20"
  "641:15"
  "648:7"
  "657:1"
)

# Benchmark definitions
# Format: BENCH_INFO["bench"]="binary|args|mem"
declare -A BENCH_INFO
BENCH_INFO["600.perlbench_s.0"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/checkspam.pl 2500 5 25 11 150 1 1 1 1|4GiB"
BENCH_INFO["600.perlbench_s.1"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/diffmail.pl 4 800 10 17 19 300|4GiB"
BENCH_INFO["600.perlbench_s.2"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/splitmail.pl 6400 12 26 16 100 0|4GiB"
BENCH_INFO["602.gcc_s.0"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -fipa-pta -o gcc-pp.opts-O5_-fipa-pta.s|8GiB"
BENCH_INFO["602.gcc_s.1"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=1000 -fselective-scheduling -fselective-scheduling2 -o gcc-pp.opts-O5_-finline-limit_1000_-fselective-scheduling_-fselective-scheduling2.s|4GiB"
BENCH_INFO["602.gcc_s.2"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=24000 -fgcse -fgcse-las -fgcse-lm -fgcse-sm -o gcc-pp.opts-O5_-finline-limit_24000_-fgcse_-fgcse-las_-fgcse-lm_-fgcse-sm.s|4GiB"
BENCH_INFO["605.mcf_s"]="$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/mcf_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/inp.in|8GiB"
BENCH_INFO["620.omnetpp_s"]="$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_$RUN_LABEL.0000/omnetpp_s_base.$RUN_LABEL|-c General -r 0|4GiB"
BENCH_INFO["625.x264_s.0"]="$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL|--pass 1 --stats x264_stats.log --bitrate 1000 --frames 1000 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720|4GiB"
BENCH_INFO["623.xalancbmk_s"]="$SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalancbmk_s_base.$RUN_LABEL|-v $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/t5.xml $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalanc.xsl|4GiB"
BENCH_INFO["631.deepsjeng_s"]="$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/deepsjeng_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.txt|8GiB"
BENCH_INFO["641.leela_s"]="$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/leela_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.sgf|4GiB"
BENCH_INFO["648.exchange2_s"]="$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_$RUN_LABEL.0000/exchange2_s_base.$RUN_LABEL|6|4GiB"
BENCH_INFO["657.xz_s.0"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cpu2006docs.tar.xz 6643 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 1036078272 1111795472 4|16GiB"
BENCH_INFO["657.xz_s.1"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cld.tar.xz 1400 19cf30ae51eddcbefda78dd06014b4b96281456e078ca7c13e1c0c9e6aaea8dff3efb4ad6b0456697718cede6bd5454852652806a657bb56e07d61128434b474 536995164 539938872 8|24GiB"

get_benchmark_name() {
  local bench_id=$1

  if [[ "$bench_id" =~ \. ]]; then
    echo "$bench_id"
    return 0
  fi

  case "$bench_id" in
    600) echo "600.perlbench_s.0" ;;
    602) echo "602.gcc_s.0" ;;
    605) echo "605.mcf_s" ;;
    620) echo "620.omnetpp_s" ;;
    623) echo "623.xalancbmk_s" ;;
    625) echo "625.x264_s.0" ;;
    631) echo "631.deepsjeng_s" ;;
    641) echo "641.leela_s" ;;
    648) echo "648.exchange2_s" ;;
    657) echo "657.xz_s.0" ;;
    *)
      echo "ERROR: Unknown benchmark ID: $bench_id" >&2
      return 1
      ;;
  esac
}

result_exists() {
  local benchmark=$1
  local simpoint=$2
  local binary_type=$3

  if [ ! -f "$CSV_FILE" ]; then
    return 1
  fi

  grep -q "^${benchmark},${simpoint},${binary_type}," "$CSV_FILE"
}

record_result() {
  local benchmark=$1
  local simpoint=$2
  local binary_type=$3
  local exec_time=$4
  local icache_misses=$5
  local icache_accesses=$6
  local icache_miss_rate=$7
  local itlb_misses=$8
  local itlb_accesses=$9
  local itlb_miss_rate=${10}

  (
    flock -x 200
    echo "${benchmark},${simpoint},${binary_type},${exec_time},${icache_misses},${icache_accesses},${icache_miss_rate},${itlb_misses},${itlb_accesses},${itlb_miss_rate}" >> "$CSV_FILE"
  ) 200>"${CSV_FILE}.lock"
}

get_execution_time() {
  local stats_file=$1

  if [ ! -f "$stats_file" ]; then
    echo "ERROR"
    return 1
  fi

  local time
  time=$(grep "hostSeconds" "$stats_file" | tail -1 | awk '{print $2}')

  if [ -z "$time" ]; then
    echo "ERROR"
    return 1
  fi

  echo "$time"
}

run_single_instance() {
  local benchmark=$1
  local simpoint=$2
  local binary_type=$3
  local gem5_binary=$4
  local spec_binary=$5
  local args=$6
  local mem=$7
  local checkpoint_path=$8
  local cpu_id=$9

  if result_exists "$benchmark" "$simpoint" "$binary_type"; then
    echo "[SKIP] $benchmark:$simpoint ($binary_type) - already exists"
    return 0
  fi

  local outdir="$RESULTS_RUNDIR_DIR/fig2/${benchmark}-${simpoint}-${binary_type}"
  mkdir -p "$outdir"

  echo "[RUN] $benchmark:$simpoint ($binary_type) on CPU $cpu_id"

  local perf_output="$outdir/perf_stats.txt"

  taskset -c "$cpu_id" sudo perf stat \
    -e L1-icache-load-misses:u \
    -e instructions:u \
    -e iTLB-load-misses:u \
    -o "$perf_output" \
    "$gem5_binary" -r --outdir="$outdir" "$GEM5_CONFIG" \
    --binary "$spec_binary" --args="$args" \
    --restore-from "$checkpoint_path" \
    --cpu-type o3 --mem-size "$mem" --l2-size 8192KiB > "$outdir/gem5.log" 2>&1

  local exit_status=$?
  if [ $exit_status -ne 0 ]; then
    echo "[ERROR] $benchmark:$simpoint ($binary_type) failed with exit status $exit_status"
    return 1
  fi

  local exec_time
  exec_time=$(get_execution_time "$outdir/stats.txt")
  if [ "$exec_time" = "ERROR" ]; then
    echo "[ERROR] Failed to extract execution time from $outdir/stats.txt"
    return 1
  fi

  local icache_misses="0"
  local instructions="0"
  local itlb_misses="0"

  if [ -f "$perf_output" ]; then
    icache_misses=$(grep "L1-icache-load-misses" "$perf_output" | awk '{gsub(/,/, "", $1); print $1}')
    instructions=$(grep "instructions:u" "$perf_output" | awk '{gsub(/,/, "", $1); print $1}')
    itlb_misses=$(grep "iTLB-load-misses" "$perf_output" | awk '{gsub(/,/, "", $1); print $1}')

    if [ -z "$icache_misses" ] || [ "$icache_misses" = "<not" ]; then icache_misses="0"; fi
    if [ -z "$instructions" ] || [ "$instructions" = "<not" ]; then instructions="0"; fi
    if [ -z "$itlb_misses" ] || [ "$itlb_misses" = "<not" ]; then itlb_misses="0"; fi
  fi

  local icache_miss_rate="0.0"
  if [ "$instructions" -gt 0 ] 2>/dev/null; then
    icache_miss_rate=$(echo "scale=6; $icache_misses / $instructions * 100" | bc)
  fi

  local itlb_miss_rate="N/A"

  record_result "$benchmark" "$simpoint" "$binary_type" \
    "$exec_time" "$icache_misses" "$instructions" "$icache_miss_rate" \
    "$itlb_misses" "0" "$itlb_miss_rate"

  sudo rm -f "$perf_output"

  echo "[DONE] $benchmark:$simpoint ($binary_type) = ${exec_time}s, icache miss rate: ${icache_miss_rate}%, itlb misses: ${itlb_misses}"
}

run_parallel_jobs() {
  local -a job_queue=()
  local -a running_pids=()
  local -a running_cpu_ids=()
  local -a running_info=()

  for combo in "${BENCHMARK_SIMPOINT_COMBINATIONS[@]}"; do
    IFS=':' read -r bench_id simpoint <<< "$combo"

    local benchmark
    benchmark=$(get_benchmark_name "$bench_id")
    if [ $? -ne 0 ]; then
      echo "ERROR: Could not resolve benchmark name for $bench_id"
      continue
    fi

    job_queue+=("${benchmark}:${simpoint}:baseline")
    job_queue+=("${benchmark}:${simpoint}:pgo")
  done

  echo "Total jobs to run: ${#job_queue[@]}"
  echo ""

  local job_idx=0
  local completed=0
  local failed=0
  local cpu_idx=0

  while [ $job_idx -lt ${#job_queue[@]} ] || [ ${#running_pids[@]} -gt 0 ]; do
    while [ ${#running_pids[@]} -lt $MAX_PARALLEL ] && [ $job_idx -lt ${#job_queue[@]} ]; do
      local job="${job_queue[$job_idx]}"
      IFS=':' read -r benchmark simpoint binary_type <<< "$job"

      local bench_info="${BENCH_INFO[$benchmark]}"
      if [ -z "$bench_info" ]; then
        echo "ERROR: Benchmark info not found for $benchmark"
        ((job_idx++))
        ((failed++))
        continue
      fi

      IFS='|' read -r spec_binary args mem <<< "$bench_info"

      local checkpoint_path="$CHECKPOINT_BASE_DIR/${benchmark}/${simpoint}"
      if [ ! -d "$checkpoint_path" ]; then
        echo "ERROR: Checkpoint not found: $checkpoint_path"
        ((job_idx++))
        ((failed++))
        continue
      fi

      local gem5_binary="$BASELINE_BINARY"
      if [ "$binary_type" = "pgo" ]; then
        gem5_binary="$PGO_BINS_DIR/${benchmark}/gem5.pgo"
        if [ ! -f "$gem5_binary" ]; then
          echo "ERROR: PGO binary not found: $gem5_binary"
          ((job_idx++))
          ((failed++))
          continue
        fi
      fi

      local cpu_id=${CPU_CORES[$cpu_idx]}
      cpu_idx=$(( (cpu_idx + 1) % ${#CPU_CORES[@]} ))

      run_single_instance "$benchmark" "$simpoint" "$binary_type" "$gem5_binary" \
        "$spec_binary" "$args" "$mem" "$checkpoint_path" "$cpu_id" &

      local pid=$!
      running_pids+=("$pid")
      running_cpu_ids+=("$cpu_id")
      running_info+=("$benchmark:$simpoint:$binary_type")

      echo "[LAUNCHED] Job $((job_idx+1))/${#job_queue[@]}: $benchmark:$simpoint ($binary_type) on CPU $cpu_id (PID: $pid)"

      ((job_idx++))
      sleep 1
    done

    local -a new_running_pids=()
    local -a new_running_cpu_ids=()
    local -a new_running_info=()

    for i in "${!running_pids[@]}"; do
      local pid="${running_pids[$i]}"
      local cpu_id="${running_cpu_ids[$i]}"
      local info="${running_info[$i]}"

      if kill -0 "$pid" 2>/dev/null; then
        new_running_pids+=("$pid")
        new_running_cpu_ids+=("$cpu_id")
        new_running_info+=("$info")
      else
        wait "$pid"
        local exit_status=$?
        if [ $exit_status -eq 0 ]; then
          ((completed++))
          echo "[COMPLETED] $info (CPU $cpu_id freed)"
        else
          ((failed++))
          echo "[FAILED] $info (CPU $cpu_id freed)"
        fi
      fi
    done

    running_pids=("${new_running_pids[@]}")
    running_cpu_ids=("${new_running_cpu_ids[@]}")
    running_info=("${new_running_info[@]}")

    if [ ${#running_pids[@]} -gt 0 ]; then
      sleep 5
    fi
  done

  echo ""
  echo "========================================================================"
  echo "All jobs completed"
  echo "========================================================================"
  echo "Total jobs: ${#job_queue[@]}"
  echo "Completed: $completed"
  echo "Failed: $failed"
  echo "========================================================================"
}

echo "========================================================================"
echo "SPEC Single Instance PGO Comparison"
echo "========================================================================"

if [ "$PLOT_ONLY" = true ]; then
  echo "Mode: Plot-only (skipping simulations)"
  echo "Results CSV: $CSV_FILE"

  if [ ! -f "$CSV_FILE" ]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    echo "Please run simulations first before using --plot-only"
    exit 1
  fi

  total_results=$(grep -cv "^benchmark," "$CSV_FILE" 2>/dev/null || echo 0)
  echo "Total results in CSV: $total_results"
  echo "========================================================================"
else
  echo "Mode: Run simulations and generate plots"
  echo "Baseline binary: $BASELINE_BINARY"
  echo "PGO bins directory: $PGO_BINS_DIR"
  echo "Results CSV: $CSV_FILE"
  echo "Max parallel jobs: $MAX_PARALLEL"
  echo "Benchmark-simpoint combinations: ${#BENCHMARK_SIMPOINT_COMBINATIONS[@]}"
  echo "========================================================================"

  if [ -f "$CSV_FILE" ]; then
    existing_results=$(grep -cv "^benchmark," "$CSV_FILE" 2>/dev/null || echo 0)
    if [ "$existing_results" -gt 0 ]; then
      total_expected=$((${#BENCHMARK_SIMPOINT_COMBINATIONS[@]} * 2))
      remaining=$((total_expected - existing_results))

      echo ""
      echo "========== RESUME MODE =========="
      echo "Existing results: $existing_results / $total_expected"
      echo "Remaining jobs:   $remaining"
      echo "Already completed jobs will be automatically skipped"
      echo "================================="
      echo ""
    fi
  fi

  run_parallel_jobs

  echo ""
  echo "Results saved to: $CSV_FILE"
  total_results=$(grep -cv "^benchmark," "$CSV_FILE" 2>/dev/null || echo 0)
  echo "Total results in CSV: $total_results"
  echo "========================================================================"
fi

echo ""
echo "Generating comparison plots..."

if [ ! -f "$SPEC_PLOT_SCRIPT" ]; then
  echo "ERROR: Missing dependency: $SPEC_PLOT_SCRIPT"
  exit 1
fi

python3 "$SPEC_PLOT_SCRIPT"
if [ $? -eq 0 ]; then
  echo "Plots generated successfully!"
else
  echo "WARNING: Plot generation failed"
fi

echo "========================================================================"
echo "Done!"
echo "========================================================================"
