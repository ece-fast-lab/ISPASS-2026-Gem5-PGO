#!/usr/bin/env bash

# Figure 8a runner: parallel gem5.fast instances (single benchmark mode only)
#
# This script runs multiple instances of the same benchmark+simpoint in parallel
# and records execution time plus cache/memory metrics.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_INIT_SH="$SCRIPT_DIR/../setup/init.sh"

if [ -f "$SETUP_INIT_SH" ]; then
  # shellcheck source=/dev/null
  source "$SETUP_INIT_SH"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0"
      echo ""
      echo "This script uses environment variables for configuration."
      echo "Mixed mode is intentionally removed; only single-benchmark mode is supported."
      echo ""
      echo "Key environment variables:"
      echo "  BENCHMARKS            (default: 10 SPEC benchmarks)"
      echo "  SIMPOINT_INDICES      (default: \"0\")"
      echo "  NUM_SIMPOINTS         (used only when SIMPOINT_INDICES is empty; default: 1)"
      echo "  NUM_REPEATS           (default: 1)"
      echo "  MIN_FREE_MEMORY_GB    (default: 100)"
      echo "  MEMORY_CHECK_DELAY    (default: 60)"
      echo "  GEM5_BINARY           (default: GEM5 or gem5.fast path)"
      echo "  GEM5_CONFIG           (default: GEM5_CONFIG_BASIC)"
      echo "  CHECKPOINT_BASE_DIR   (default from setup/init.sh)"
      echo "  RESULTS_DATA_DIR      (default: results/data)"
      echo "  RESULTS_FIGS_DIR      (default: results/figs)"
      echo "  RESULTS_RUNDIR_DIR    (default: results/rundir)"
      echo "  FIG8A_CSV_FILE        (default: results/data/fig8a_data.csv)"
      echo "  FIG8A_RUNDIR_DIR      (default: results/rundir/fig8a)"
      echo "  FIG8A_PLOTTER         (default: runscripts/plotters/fig8a_plotter.py)"
      echo "  FIG8A_FIG_PNG         (default: results/figs/fig8a.png)"
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

if [ -z "${SPEC_BUILT_DIR:-}" ]; then
  echo "SPEC_BUILT_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

# Configuration
if [ -z "${BENCHMARKS:-}" ]; then
  if declare -p SPEC_BENCHMARKS_TOP10 >/dev/null 2>&1; then
    BENCHMARKS="${SPEC_BENCHMARKS_TOP10[*]}"
  else
    BENCHMARKS="600.perlbench_s.0 602.gcc_s.0 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0"
  fi
fi
NUM_SIMPOINTS=${NUM_SIMPOINTS:-1}
SIMPOINT_INDICES=${SIMPOINT_INDICES:-"1"}
INSTANCE_COUNTS=(${INSTANCE_COUNTS:-"1 8 16 24 32 40 48 56 64 72 80"})
NUM_REPEATS=${NUM_REPEATS:-1}
MIN_FREE_MEMORY_GB=${MIN_FREE_MEMORY_GB:-100}
MEMORY_CHECK_DELAY=${MEMORY_CHECK_DELAY:-60}

RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
GEM5_BINARY="${GEM5_BINARY:-${GEM5:-$PGO_BINS_DIR/gem5.fast}}"
GEM5_CONFIG="${GEM5_CONFIG:-${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}}"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$REPO_DIR/results/data}"
RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$REPO_DIR/results/figs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
FIG8A_RUNDIR_DIR="${FIG8A_RUNDIR_DIR:-$RESULTS_RUNDIR_DIR/fig8a}"
CSV_FILE="${FIG8A_CSV_FILE:-$RESULTS_DATA_DIR/fig8a_data.csv}"
FIG8A_PLOTTER="${FIG8A_PLOTTER:-$SCRIPT_DIR/plotters/fig8a_plotter.py}"
FIG8A_FIG_PNG="${FIG8A_FIG_PNG:-$RESULTS_FIGS_DIR/fig8a.png}"

if [ ! -f "$GEM5_CONFIG" ]; then
  echo "GEM5 config not found: $GEM5_CONFIG"
  exit 1
fi

mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$FIG8A_RUNDIR_DIR"

if [ ! -f "$CSV_FILE" ]; then
  echo "benchmark,simpoint,num_instances,repeat,average_exec_time,per_instance_cache_miss,per_instance_cache_hit,per_instance_l1i_cache_miss,total_memory_bandwidth,per_instance_memory_usage" > "$CSV_FILE"
fi

# Shared benchmark definitions (loaded from setup/init.sh)
if ! declare -p BENCH_INFO >/dev/null 2>&1; then
  echo "Shared BENCH_INFO is not loaded. Please source setup/init.sh"
  exit 1
fi

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
  return 0
}

# Returns two values: average RSS (MB) and average PSS (MB)
measure_memory_usage() {
  local pids=("$@")
  local total_rss=0
  local total_pss=0
  local count=0

  for pid in "${pids[@]}"; do
    if [ -d "/proc/$pid" ]; then
      local rss
      rss=$(grep "^VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')

      local pss=0
      if [ -f "/proc/$pid/smaps_rollup" ]; then
        pss=$(grep "^Pss:" "/proc/$pid/smaps_rollup" 2>/dev/null | awk '{sum += $2} END {print sum}')
      elif [ -f "/proc/$pid/smaps" ]; then
        pss=$(grep "^Pss:" "/proc/$pid/smaps" 2>/dev/null | awk '{sum += $2} END {print sum}')
      fi

      if [ -n "$rss" ] && [ "$rss" -gt 0 ]; then
        total_rss=$((total_rss + rss))
        ((count++))
      fi

      if [ -n "$pss" ] && [ "$pss" != "" ]; then
        total_pss=$(echo "$total_pss + $pss" | bc)
      fi
    fi
  done

  if [ "$count" -eq 0 ]; then
    echo "0 0"
    return 1
  fi

  local avg_rss_mb
  local avg_pss_mb
  avg_rss_mb=$(echo "scale=2; $total_rss / $count / 1024" | bc)
  avg_pss_mb=$(echo "scale=2; $total_pss / $count / 1024" | bc)

  echo "$avg_rss_mb $avg_pss_mb"
  return 0
}

result_exists() {
  local benchmark=$1
  local simpoint=$2
  local num_instances=$3
  local repeat=$4

  if [ ! -f "$CSV_FILE" ]; then
    return 1
  fi

  grep -q "^${benchmark},${simpoint},${num_instances},${repeat}," "$CSV_FILE"
}

record_result() {
  local benchmark=$1
  local simpoint=$2
  local num_instances=$3
  local repeat=$4
  local avg_exec_time=$5
  local per_inst_cache_miss=$6
  local per_inst_cache_hit=$7
  local per_inst_l1i_miss=$8
  local total_mem_bw=$9
  local per_inst_mem_usage=${10}

  (
    flock -x 200
    echo "${benchmark},${simpoint},${num_instances},${repeat},${avg_exec_time},${per_inst_cache_miss},${per_inst_cache_hit},${per_inst_l1i_miss},${total_mem_bw},${per_inst_mem_usage}" >> "$CSV_FILE"
  ) 200>"$CSV_FILE.lock"
}

run_parallel_instances() {
  local benchmark=$1
  local simpoint=$2
  local num_instances=$3
  local repeat=$4
  local binary=$5
  local args=$6
  local mem=$7
  local checkpoint_path=$8

  if result_exists "$benchmark" "$simpoint" "$num_instances" "$repeat"; then
    echo "[SKIP] $benchmark:$simpoint with $num_instances instances (repeat $repeat) - already exists"

    local mem_available
    mem_available=$(free | grep "^Mem:" | awk '{print $7}')
    FREE_MEMORY_GB=$((mem_available / 1024 / 1024))
    return 0
  fi

  local base_outdir="$FIG8A_RUNDIR_DIR/${benchmark}-${simpoint}-n${num_instances}-r${repeat}"
  mkdir -p "$base_outdir"

  echo "[RUN] $benchmark:$simpoint with $num_instances instances (repeat $repeat)"

  declare -a instance_pids
  declare -a instance_outdirs

  local perf_cache_output="$base_outdir/perf_cache.txt"
  local perf_bw_output="$base_outdir/perf_bw.txt"

  for i in $(seq 1 "$num_instances"); do
    local cpu_id=$((i - 1))
    local outdir="$base_outdir/instance_${i}"
    mkdir -p "$outdir"
    instance_outdirs+=("$outdir")

    taskset -c "$cpu_id" "$GEM5_BINARY" -r --outdir="$outdir" "$GEM5_CONFIG" \
      --binary "$binary" --args="$args" \
      --restore-from "$checkpoint_path" \
      --cpu-type o3 --mem-size "$mem" > "$outdir/gem5.log" 2>&1 &

    instance_pids+=("$!")
  done

  local pid_list
  pid_list=$(IFS=,; echo "${instance_pids[*]}")

  perf stat -e cache-misses,cache-references,L1-icache-load-misses -p "$pid_list" -I 1000 -o "$perf_cache_output" 2>&1 &
  local perf_cache_pid=$!

  perf stat -M memory_bandwidth_total -a -I 1000 -o "$perf_bw_output" 2>&1 &
  local perf_bw_pid=$!

  sleep "$MEMORY_CHECK_DELAY"

  local mem_results
  mem_results=$(measure_memory_usage "${instance_pids[@]}")
  read -r per_instance_rss_mb _unused_pss_mb <<< "$mem_results"

  local mem_available
  mem_available=$(free | grep "^Mem:" | awk '{print $7}')

  local all_success=true
  for i in "${!instance_pids[@]}"; do
    local pid=${instance_pids[$i]}
    wait "$pid"
    local exit_status=$?

    if [ "$exit_status" -ne 0 ]; then
      echo "[ERROR] Instance $((i+1)) failed with exit status $exit_status"
      all_success=false
    fi
  done

  kill -INT "$perf_cache_pid" 2>/dev/null
  kill -INT "$perf_bw_pid" 2>/dev/null
  wait "$perf_cache_pid" 2>/dev/null
  wait "$perf_bw_pid" 2>/dev/null

  if [ "$all_success" = false ]; then
    echo "[ERROR] Some instances failed: $benchmark:$simpoint with $num_instances instances (repeat $repeat)"
    return 1
  fi

  local total_time=0
  local valid_count=0
  for outdir in "${instance_outdirs[@]}"; do
    local exec_time
    exec_time=$(get_execution_time "$outdir/stats.txt")

    if [ "$exec_time" != "ERROR" ]; then
      total_time=$(echo "$total_time + $exec_time" | bc)
      ((valid_count++))
    fi
  done

  if [ "$valid_count" -ne "$num_instances" ]; then
    echo "[ERROR] Failed to extract execution time from some instances: $benchmark:$simpoint"
    return 1
  fi

  local mean_exec_time
  mean_exec_time=$(echo "scale=6; $total_time / $valid_count" | bc)

  local total_cache_misses="0"
  local total_cache_refs="0"
  local total_l1i_misses="0"
  local total_mem_bw="0"

  if [ -f "$perf_cache_output" ]; then
    total_cache_misses=$(grep "cache-misses" "$perf_cache_output" | awk '{gsub(/,/, "", $2); sum += $2} END {printf "%.0f", sum}')
    [ -z "$total_cache_misses" ] && total_cache_misses="0"

    total_cache_refs=$(grep "cache-references" "$perf_cache_output" | awk '{gsub(/,/, "", $2); sum += $2} END {printf "%.0f", sum}')
    [ -z "$total_cache_refs" ] && total_cache_refs="0"

    total_l1i_misses=$(grep "L1-icache-load-misses" "$perf_cache_output" | awk '{gsub(/,/, "", $2); sum += $2} END {printf "%.0f", sum}')
    [ -z "$total_l1i_misses" ] && total_l1i_misses="0"
  fi

  if [ -f "$perf_bw_output" ]; then
    total_mem_bw=$(grep "memory_bandwidth_total" "$perf_bw_output" | awk -F'#' '{print $2}' | awk '{sum += $1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')
    [ -z "$total_mem_bw" ] && total_mem_bw="0"
  fi

  local per_inst_cache_miss
  local per_inst_cache_hit
  local per_inst_l1i_miss
  local total_cache_hits=$((total_cache_refs - total_cache_misses))

  per_inst_cache_miss=$(echo "scale=2; $total_cache_misses / $num_instances" | bc)
  per_inst_cache_hit=$(echo "scale=2; $total_cache_hits / $num_instances" | bc)
  per_inst_l1i_miss=$(echo "scale=2; $total_l1i_misses / $num_instances" | bc)

  record_result "$benchmark" "$simpoint" "$num_instances" "$repeat" \
    "$mean_exec_time" "$per_inst_cache_miss" "$per_inst_cache_hit" "$per_inst_l1i_miss" \
    "$total_mem_bw" "$per_instance_rss_mb"

  echo "[DONE] $benchmark:$simpoint with $num_instances instances (repeat $repeat) = ${mean_exec_time}s"
  echo "       Per-instance: Cache miss: $per_inst_cache_miss, Cache hit: $per_inst_cache_hit, L1i miss: $per_inst_l1i_miss"
  echo "       Total Memory BW: ${total_mem_bw} MB/s, Per-instance memory (RSS): ${per_instance_rss_mb} MB"

  FREE_MEMORY_GB=$((mem_available / 1024 / 1024))
  return 0
}

run_single_mode() {
  echo ""
  echo "========================================================================"
  echo "Figure 8a: Parallel Instances (Single Benchmark Mode)"
  echo "========================================================================"
  echo "Benchmarks: $BENCHMARKS"
  if [ -n "$SIMPOINT_INDICES" ]; then
    echo "Simpoint indices: $SIMPOINT_INDICES"
  else
    echo "Number of simpoints per benchmark: $NUM_SIMPOINTS"
  fi
  echo "Instance counts: ${INSTANCE_COUNTS[*]}"
  echo "Number of repeats: $NUM_REPEATS"
  echo "========================================================================"

  local -a bench_array
  bench_array=($BENCHMARKS)

  local job_count=0
  local total_completed=0

  for benchmark in "${bench_array[@]}"; do
    local bench_info="${BENCH_INFO[$benchmark]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $benchmark"
      exit 1
    fi

    local binary args mem
    IFS='|' read -r binary args mem <<< "$bench_info"

    local checkpoint_dir="$CHECKPOINT_BASE_DIR/${benchmark}"
    if [ ! -d "$checkpoint_dir" ]; then
      echo "ERROR: Checkpoint directory not found: $checkpoint_dir"
      exit 1
    fi

    local -a simpoints
    if [ -n "$SIMPOINT_INDICES" ]; then
      simpoints=()
      for idx in $SIMPOINT_INDICES; do
        local simpoint_dir
        simpoint_dir=$(ls -d "$checkpoint_dir"/* 2>/dev/null | sort -V | sed -n "$((idx+1))p" | xargs -n1 basename)
        if [ -n "$simpoint_dir" ]; then
          simpoints+=("$simpoint_dir")
        else
          echo "WARNING: Simpoint index $idx not found for $benchmark"
        fi
      done
    else
      simpoints=($(ls -d "$checkpoint_dir"/* 2>/dev/null | sort -V | head -n "$NUM_SIMPOINTS" | xargs -n1 basename))
    fi

    if [ "${#simpoints[@]}" -eq 0 ]; then
      echo "ERROR: No simpoints found for $benchmark in $checkpoint_dir"
      exit 1
    fi

    echo ""
    echo "========================================================================"
    echo "Starting benchmark: $benchmark"
    echo "========================================================================"

    for simpoint in "${simpoints[@]}"; do
      local checkpoint_path="$checkpoint_dir/${simpoint}"

      echo ""
      echo "Processing simpoint: $simpoint"

      for num_instances in "${INSTANCE_COUNTS[@]}"; do
        for repeat in $(seq 1 "$NUM_REPEATS"); do
          ((job_count++))
          echo ""
          echo "[$job_count] Running: $benchmark:$simpoint with $num_instances instances (repeat $repeat)"

          run_parallel_instances "$benchmark" "$simpoint" "$num_instances" "$repeat" \
            "$binary" "$args" "$mem" "$checkpoint_path"

          local exit_status=$?
          if [ "$exit_status" -eq 0 ]; then
            ((total_completed++))
            echo "       Free memory after run: ${FREE_MEMORY_GB} GB"

            if [ "$FREE_MEMORY_GB" -lt "$MIN_FREE_MEMORY_GB" ]; then
              echo ""
              echo "[MEMORY] Insufficient free memory (${FREE_MEMORY_GB} GB < ${MIN_FREE_MEMORY_GB} GB)"
              echo "[MEMORY] Stopping further instance counts for $benchmark:$simpoint"
              break 2
            fi
          else
            echo "[FAILED] Job failed, continuing to next repeat..."
          fi
        done
      done
    done

    echo ""
    echo "Completed benchmark: $benchmark"
  done

  echo ""
  echo "========================================================================"
  echo "Figure 8a run completed"
  echo "========================================================================"
  echo "Total jobs attempted: $job_count"
  echo "Total jobs completed: $total_completed"
  echo "Results saved to: $CSV_FILE"

  local total_results
  total_results=$(grep -cv "^benchmark," "$CSV_FILE" 2>/dev/null || echo 0)
  echo "Total results in CSV: $total_results"
  if [ -f "$FIG8A_PLOTTER" ]; then
    echo "Generating Figure 8a plot..."
    if python3 "$FIG8A_PLOTTER" --csv "$CSV_FILE" --output "$FIG8A_FIG_PNG"; then
      echo "Figure saved to: $FIG8A_FIG_PNG"
      echo "Figure saved to: ${FIG8A_FIG_PNG%.png}.pdf"
    else
      echo "WARNING: Figure 8a plot generation failed"
      echo "Run manually: python3 $FIG8A_PLOTTER --csv $CSV_FILE --output $FIG8A_FIG_PNG"
    fi
  else
    echo "WARNING: Figure 8a plotter not found: $FIG8A_PLOTTER"
  fi
  echo "========================================================================"
}

FREE_MEMORY_GB=0
run_single_mode
