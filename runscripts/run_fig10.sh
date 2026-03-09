#!/usr/bin/env bash

# This script compares two job scheduling strategies for SPEC benchmark simulations:
#   - baseline: benchmark-simpoint-iteration (benchmarks grouped together)
#   - balanced: iteration-simpoint-benchmark (work distributed across benchmarks)
#
# Monitors CPU utilization and memory usage every 10 seconds
# Calculates throughput (jobs/second) for each strategy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_INIT_SH="$SCRIPT_DIR/../setup/init.sh"

if [ -f "$SETUP_INIT_SH" ]; then
  # shellcheck source=/dev/null
  source "$SETUP_INIT_SH"
fi

# Configuration
BENCHMARKS="${BENCHMARKS:-657.xz_s.0 631.deepsjeng_s 602.gcc_s.0 625.x264_s.0 641.leela_s}"
NUM_ITERATIONS="${NUM_ITERATIONS:-3}"
MAX_PARALLEL=${MAX_PARALLEL:-40}
MIN_MEMORY_GB=${MIN_MEMORY_GB:-300}
JOB_LAUNCH_DELAY=${JOB_LAUNCH_DELAY:-5}
MONITORING_INTERVAL="${MONITORING_INTERVAL:-10}"  # seconds

RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
GEM5_CONFIG="${GEM5_CONFIG:-${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}}"
BASELINE_BINARY="${BASELINE_BINARY:-${GEM5:-$REPO_DIR/gem5/build/X86/gem5.fast}}"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$REPO_DIR/results/data}"
RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$REPO_DIR/results/figs}"
RESULTS_LOGS_DIR="${RESULTS_LOGS_DIR:-$REPO_DIR/results/logs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
FIG10_RUNDIR_DIR="${FIG10_RUNDIR_DIR:-$RESULTS_RUNDIR_DIR/fig10}"
MONITORING_CSV_BASELINE="${FIG10_MONITORING_CSV_BASELINE:-$RESULTS_DATA_DIR/fig10_monitoring_baseline.csv}"
MONITORING_CSV_BALANCED="${FIG10_MONITORING_CSV_BALANCED:-$RESULTS_DATA_DIR/fig10_monitoring_balanced.csv}"
SUMMARY_FILE="${FIG10_SUMMARY_FILE:-$RESULTS_LOGS_DIR/fig10_summary.txt}"

# Parse command line arguments
SCHEDULE_MODE="both"  # baseline, balanced, or both

while [[ $# -gt 0 ]]; do
  case $1 in
    --schedule)
      SCHEDULE_MODE="$2"
      if [[ ! "$SCHEDULE_MODE" =~ ^(baseline|balanced|both)$ ]]; then
        echo "ERROR: --schedule must be 'baseline', 'balanced', or 'both'"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --schedule MODE    Which schedule to run: baseline, balanced, or both (default: both)"
      echo "  -h, --help         Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  MAX_PARALLEL       Maximum parallel jobs (default: 40)"
      echo "  MIN_MEMORY_GB      Minimum available memory to launch jobs (default: 300)"
      echo "  JOB_LAUNCH_DELAY   Delay between job launches in seconds (default: 5)"
      echo "  MONITORING_INTERVAL Monitoring sample interval in seconds (default: 10)"
      echo ""
      echo "Examples:"
      echo "  $0                           # Run both schedules sequentially"
      echo "  $0 --schedule baseline       # Run only baseline schedule"
      echo "  $0 --schedule balanced       # Run only balanced schedule"
      echo "  MAX_PARALLEL=40 $0           # Run with max 40 parallel jobs"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
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

mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_LOGS_DIR" "$FIG10_RUNDIR_DIR"

# Shared benchmark definitions (loaded from setup/init.sh)
if ! declare -p BENCH_INFO >/dev/null 2>&1; then
  echo "Shared BENCH_INFO is not loaded. Please source setup/init.sh"
  exit 1
fi

################################################################################
# UTILITY FUNCTIONS
################################################################################

# Function to get available memory in GB
get_available_memory_gb() {
  local avail_kb=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
  local avail_gb=$(echo "scale=2; $avail_kb / 1024 / 1024" | bc -l)
  echo "$avail_gb"
}

# Function to get used memory in GB
get_used_memory_gb() {
  local total_kb=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
  local avail_kb=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
  local used_kb=$((total_kb - avail_kb))
  local used_gb=$(echo "scale=2; $used_kb / 1024 / 1024" | bc -l)
  echo "$used_gb"
}

# Function to check if system has enough memory to launch new job
has_enough_memory() {
  local avail_gb=$(get_available_memory_gb)
  local has_enough=$(echo "$avail_gb > $MIN_MEMORY_GB" | bc -l)

  if [ "$has_enough" -eq 1 ]; then
    return 0  # Enough memory
  else
    return 1  # Not enough memory
  fi
}

# Function to check if system is in critical memory state (OOM)
is_critical_memory() {
  local avail_gb=$(get_available_memory_gb)
  local is_critical=$(echo "$avail_gb < $MIN_MEMORY_GB" | bc -l)

  if [ "$is_critical" -eq 1 ]; then
    return 0  # Critical memory state (OOM)
  else
    return 1  # OK
  fi
}

# Function to get adaptive launch delay based on memory pressure
# Returns delay in seconds (1x to 3x of JOB_LAUNCH_DELAY)
get_adaptive_launch_delay() {
  local avail_gb=$(get_available_memory_gb)

  # Calculate ratio: available / MIN_MEMORY_GB
  local ratio=$(echo "scale=2; $avail_gb / $MIN_MEMORY_GB" | bc -l)

  # Determine multiplier based on memory pressure
  local multiplier
  if (( $(echo "$ratio >= 2" | bc -l) )); then
    # Plenty of memory: 1x delay
    multiplier="1"
  elif (( $(echo "$ratio <= 1" | bc -l) )); then
    # At or below threshold: 3x delay
    multiplier="3"
  else
    # Linear interpolation: multiplier = 3 - 2 * (ratio - 1)
    # ratio=2 -> multiplier=1, ratio=1 -> multiplier=3
    multiplier=$(echo "scale=2; 3 - 2 * ($ratio - 1)" | bc -l)
  fi

  # Calculate final delay
  local delay=$(echo "scale=0; $JOB_LAUNCH_DELAY * $multiplier / 1" | bc -l)
  echo "$delay"
}

# Function to get CPU utilization percentage
get_cpu_utilization() {
  # Read /proc/stat twice with 1 second interval to calculate utilization
  local cpu_line1=$(grep "^cpu " /proc/stat)
  sleep 1
  local cpu_line2=$(grep "^cpu " /proc/stat)

  # Parse CPU times
  local vals1=($cpu_line1)
  local vals2=($cpu_line2)

  # Calculate total and idle times
  local idle1=${vals1[4]}
  local idle2=${vals2[4]}

  local total1=0
  local total2=0
  for i in {1..10}; do
    total1=$((total1 + ${vals1[$i]:-0}))
    total2=$((total2 + ${vals2[$i]:-0}))
  done

  # Calculate utilization
  local total_diff=$((total2 - total1))
  local idle_diff=$((idle2 - idle1))

  if [ $total_diff -eq 0 ]; then
    echo "0.00"
    return
  fi

  local utilization=$(echo "scale=2; 100 * ($total_diff - $idle_diff) / $total_diff" | bc -l)
  echo "$utilization"
}

# Global variable for monitoring PID
MONITOR_PID=""

# Function to start monitoring in background
start_monitoring() {
  local schedule_name=$1

  # Determine which CSV file to use based on schedule name
  local monitoring_csv
  if [ "$schedule_name" = "baseline" ]; then
    monitoring_csv="$MONITORING_CSV_BASELINE"
  elif [ "$schedule_name" = "balanced" ]; then
    monitoring_csv="$MONITORING_CSV_BALANCED"
  else
    echo "ERROR: Unknown schedule name: $schedule_name"
    return 1
  fi

  # Background monitoring function
  (
    while true; do
      timestamp=$(date +%s)
      cpu_util=$(get_cpu_utilization)
      mem_usage=$(get_used_memory_gb)

      # Count running jobs (gem5.fast processes)
      running_jobs=$(pgrep -f "gem5.fast" | wc -l)

      # Append to CSV (with file locking)
      (
        flock -x 200
        echo "$timestamp,$schedule_name,$cpu_util,$mem_usage,$running_jobs" >> "$monitoring_csv"
      ) 200>"${monitoring_csv}.lock"

      sleep $MONITORING_INTERVAL
    done
  ) &

  MONITOR_PID=$!
  echo "[MONITOR] Started monitoring (PID: $MONITOR_PID, interval: ${MONITORING_INTERVAL}s, file: $(basename $monitoring_csv))"
}

# Function to stop monitoring
stop_monitoring() {
  if [ -n "$MONITOR_PID" ]; then
    kill $MONITOR_PID 2>/dev/null
    wait $MONITOR_PID 2>/dev/null
    echo "[MONITOR] Stopped monitoring (PID: $MONITOR_PID)"
    MONITOR_PID=""
  fi
}

# Function to run a single gem5 simulation
run_gem5_simulation() {
  local bench=$1
  local simpoint=$2
  local iteration=$3
  local spec_binary=$4
  local args=$5
  local mem=$6
  local checkpoint_path=$7

  local outdir="$FIG10_RUNDIR_DIR/${bench}-${simpoint}-iter${iteration}"

  echo "[RUN] $bench:$simpoint iteration $iteration"

  # Run gem5 (no CPU affinity - let OS schedule)
  "$BASELINE_BINARY" -r --outdir="$outdir" "$GEM5_CONFIG" \
    --binary "$spec_binary" --args="$args" \
    --restore-from "$checkpoint_path" \
    --cpu-type o3 --mem-size "$mem" > /dev/null 2>&1

  local exit_status=$?

  if [ $exit_status -ne 0 ]; then
    echo "[ERROR] Simulation failed: $bench:$simpoint iteration $iteration (exit: $exit_status)"
    return 1
  fi

  echo "[DONE] $bench:$simpoint iteration $iteration"
  return 0
}

################################################################################
# JOB QUEUE CREATION
################################################################################

# Create baseline schedule job queue: benchmark-simpoint-iteration
create_baseline_queue() {
  local -n queue_ref=$1

  BENCHMARK_ARRAY=($BENCHMARKS)

  for bench in "${BENCHMARK_ARRAY[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      exit 1
    fi

    IFS='|' read -r spec_binary args mem <<< "$bench_info"

    checkpoint_dir="$CHECKPOINT_BASE_DIR/${bench}"
    if [ ! -d "$checkpoint_dir" ]; then
      echo "ERROR: Checkpoint directory not found: $checkpoint_dir"
      exit 1
    fi

    # Get all simpoints
    simpoints=($(ls -d "$checkpoint_dir"/* 2>/dev/null | sort -V | xargs -n1 basename))

    if [ ${#simpoints[@]} -eq 0 ]; then
      echo "ERROR: No simpoints found for $bench"
      exit 1
    fi

    # Benchmark -> Simpoint -> Iteration
    for simpoint in "${simpoints[@]}"; do
      checkpoint_path="$checkpoint_dir/$simpoint"

      for iter in $(seq 1 $NUM_ITERATIONS); do
        queue_ref+=("$bench|$simpoint|$iter|$spec_binary|$args|$mem|$checkpoint_path")
      done
    done
  done
}

# Create balanced schedule job queue: iteration-simpoint_index-benchmark (round-robin)
# Example order: iter1: 657:1, 631:1, 602:1, ..., 657:2, 631:2, 602:2, ...
create_balanced_queue() {
  local -n queue_ref=$1

  BENCHMARK_ARRAY=($BENCHMARKS)

  # Collect simpoints for each benchmark
  declare -A bench_simpoints  # bench -> space-separated simpoint list
  local max_simpoints=0

  for bench in "${BENCHMARK_ARRAY[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      exit 1
    fi

    checkpoint_dir="$CHECKPOINT_BASE_DIR/${bench}"
    if [ ! -d "$checkpoint_dir" ]; then
      echo "ERROR: Checkpoint directory not found: $checkpoint_dir"
      exit 1
    fi

    simpoints=($(ls -d "$checkpoint_dir"/* 2>/dev/null | sort -V | xargs -n1 basename))

    if [ ${#simpoints[@]} -eq 0 ]; then
      echo "ERROR: No simpoints found for $bench"
      exit 1
    fi

    bench_simpoints[$bench]="${simpoints[*]}"

    # Track max simpoints across all benchmarks
    if [ ${#simpoints[@]} -gt $max_simpoints ]; then
      max_simpoints=${#simpoints[@]}
    fi
  done

  # Iteration -> Simpoint Index -> Benchmark (round-robin)
  for iter in $(seq 1 $NUM_ITERATIONS); do
    for sp_idx in $(seq 0 $((max_simpoints - 1))); do
      for bench in "${BENCHMARK_ARRAY[@]}"; do
        # Get simpoints array for this benchmark
        simpoints_str="${bench_simpoints[$bench]}"
        simpoints=($simpoints_str)

        # Skip if this benchmark doesn't have this many simpoints
        if [ $sp_idx -ge ${#simpoints[@]} ]; then
          continue
        fi

        simpoint="${simpoints[$sp_idx]}"

        bench_info="${BENCH_INFO[$bench]}"
        IFS='|' read -r spec_binary args mem <<< "$bench_info"

        checkpoint_path="$CHECKPOINT_BASE_DIR/${bench}/${simpoint}"

        queue_ref+=("$bench|$simpoint|$iter|$spec_binary|$args|$mem|$checkpoint_path")
      done
    done
  done
}

################################################################################
# SCHEDULE EXECUTION
################################################################################

# Run jobs from queue with memory-aware parallel execution
run_schedule() {
  local schedule_name=$1
  local -n job_queue=$2

  local total_jobs=${#job_queue[@]}

  echo ""
  echo "========================================================================"
  echo "Running $schedule_name Schedule"
  echo "========================================================================"
  echo "Total jobs: $total_jobs"
  echo "Max parallel: $MAX_PARALLEL"
  echo "Min memory: ${MIN_MEMORY_GB}GB"
  echo "Job launch delay: ${JOB_LAUNCH_DELAY}s"
  echo "========================================================================"

  # Start monitoring
  start_monitoring "$schedule_name"

  # Track start time
  local start_time=$(date +%s)

  local job_count=0
  local running_jobs=0
  declare -A job_pids
  declare -A job_desc
  declare -A job_params  # Store job parameters for retry
  declare -a pid_order   # Track PID launch order (for OOM kill)
  declare -a retry_queue # Jobs killed due to OOM, to be retried

  # Main job processing loop
  local queue_idx=0
  while [ $queue_idx -lt ${#job_queue[@]} ]; do
    # DISABLED: Retry queue logic
    # if [ ${#retry_queue[@]} -gt 0 ]; then
    #   job="${retry_queue[0]}"
    #   retry_queue=("${retry_queue[@]:1}")
    #   echo "[RETRY] Processing killed job: $job"
    # elif [ $queue_idx -lt ${#job_queue[@]} ]; then
    #   job="${job_queue[$queue_idx]}"
    #   ((queue_idx++))
    # else
    #   break
    # fi

    local job="${job_queue[$queue_idx]}"
    ((queue_idx++))
    IFS='|' read -r bench simpoint iter spec_binary args mem checkpoint_path <<< "$job"

    # Wait if max parallel jobs reached OR insufficient memory
    wait_message_printed=false
    while [ $running_jobs -ge $MAX_PARALLEL ] || ! has_enough_memory; do
      if [ "$wait_message_printed" = false ]; then
        if [ $running_jobs -ge $MAX_PARALLEL ]; then
          avail_mem=$(get_available_memory_gb)
          echo "[WAIT] Max parallel jobs reached ($running_jobs/$MAX_PARALLEL), memory: ${avail_mem}GB"
        else
          avail_mem=$(get_available_memory_gb)
          echo "[WAIT] Insufficient memory (${avail_mem}GB available, need >${MIN_MEMORY_GB}GB)"
        fi
        wait_message_printed=true
      fi

      # Adaptive sleep: 1s if OOM, 5s if normal
      # if is_critical_memory; then
      #   sleep 1
      # else
        sleep 5
      # fi

      # DISABLED: Check for OOM condition and kill ONE job if needed
      # if is_critical_memory && [ $running_jobs -gt 0 ] && [ ${#pid_order[@]} -gt 0 ]; then
      #   local kill_pid="${pid_order[-1]}"
      #   pid_order=("${pid_order[@]:0:${#pid_order[@]}-1}")  # Remove last element
      #
      #   avail_mem=$(get_available_memory_gb)
      #   echo "[OOM] Critical memory! Available: ${avail_mem}GB < MIN_MEMORY: ${MIN_MEMORY_GB}GB"
      #   echo "[OOM] Killing most recent job: ${job_desc[$kill_pid]} (PID: $kill_pid)"
      #
      #   # Kill the process
      #   kill -9 "$kill_pid" 2>/dev/null
      #   wait "$kill_pid" 2>/dev/null
      #
      #   # Add to retry queue
      #   retry_queue+=("${job_params[$kill_pid]}")
      #
      #   # Clean up tracking
      #   unset job_pids[$kill_pid]
      #   unset job_desc[$kill_pid]
      #   unset job_params[$kill_pid]
      #   ((running_jobs--))
      #
      #   echo "[OOM] Job added to retry queue, running jobs: $running_jobs"
      #
      #   # Give system time to release memory
      #   sleep 3
      # fi

      # Check for completed jobs
      for pid in "${!job_pids[@]}"; do
        if ! ps -p "$pid" > /dev/null 2>&1; then
          wait "$pid"
          exit_status=$?

          if [ $exit_status -eq 0 ]; then
            echo "[COMPLETED] ${job_desc[$pid]}"
          else
            echo "[FAILED] ${job_desc[$pid]} (exit: $exit_status)"
          fi

          # Remove from pid_order
          local new_pid_order=()
          for p in "${pid_order[@]}"; do
            if [ "$p" != "$pid" ]; then
              new_pid_order+=("$p")
            fi
          done
          pid_order=("${new_pid_order[@]}")

          unset job_pids[$pid]
          unset job_desc[$pid]
          unset job_params[$pid]
          ((running_jobs--))
          wait_message_printed=false
        fi
      done
    done

    # Memory-aware launch delay
    if [ $running_jobs -gt 0 ]; then
      # DISABLED: Adaptive delay
      adaptive_delay=$(get_adaptive_launch_delay)
      avail_mem=$(get_available_memory_gb)
      echo "[DELAY] Adaptive delay: ${adaptive_delay}s (memory: ${avail_mem}GB)"
      sleep $adaptive_delay

      # sleep $JOB_LAUNCH_DELAY

      if ! has_enough_memory; then
        avail_mem=$(get_available_memory_gb)
        echo "[MEMORY CHECK] Insufficient after delay (${avail_mem}GB), waiting..."
        continue
      fi
    fi

    # Launch job in background
    run_gem5_simulation "$bench" "$simpoint" "$iter" "$spec_binary" "$args" "$mem" "$checkpoint_path" &

    pid=$!
    job_pids[$pid]=1
    job_desc[$pid]="$bench:$simpoint iter$iter"
    job_params[$pid]="$job"  # Store job string for retry
    pid_order+=("$pid")  # Track launch order
    ((running_jobs++))
    ((job_count++))

    avail_mem=$(get_available_memory_gb)
    echo "[LAUNCHED] ${job_desc[$pid]} (PID: $pid, running: $running_jobs, mem: ${avail_mem}GB)"

    if [ $((job_count % 20)) -eq 0 ]; then
      # Count completed jobs
      completed=$(find "$FIG10_RUNDIR_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -f {}/stats.txt \; -print 2>/dev/null | wc -l)
      echo "Progress: $completed / $total_jobs completed, $running_jobs running"
    fi
  done

  # Wait for all remaining jobs (with OOM protection and retry support)
  echo ""
  echo "Waiting for remaining jobs to complete..."

  while [ ${#job_pids[@]} -gt 0 ]; do
    # DISABLED: Retry queue logic
    # while [ ${#retry_queue[@]} -gt 0 ] && [ $running_jobs -lt $MAX_PARALLEL ] && has_enough_memory; do
    #   local job="${retry_queue[0]}"
    #   retry_queue=("${retry_queue[@]:1}")
    #
    #   IFS='|' read -r bench simpoint iter spec_binary args mem checkpoint_path <<< "$job"
    #
    #   echo "[RETRY] Launching killed job: $bench:$simpoint iter$iter"
    #
    #   # Launch job
    #   run_gem5_simulation "$bench" "$simpoint" "$iter" "$spec_binary" "$args" "$mem" "$checkpoint_path" &
    #
    #   pid=$!
    #   job_pids[$pid]=1
    #   job_desc[$pid]="$bench:$simpoint iter$iter"
    #   job_params[$pid]="$job"
    #   pid_order+=("$pid")
    #   ((running_jobs++))
    #
    #   avail_mem=$(get_available_memory_gb)
    #   echo "[RETRY-LAUNCHED] ${job_desc[$pid]} (PID: $pid, running: $running_jobs, mem: ${avail_mem}GB)"
    #
    #   # Adaptive delay based on memory pressure
    #   adaptive_delay=$(get_adaptive_launch_delay)
    #   echo "[DELAY] Retry adaptive delay: ${adaptive_delay}s (memory: ${avail_mem}GB)"
    #   sleep $adaptive_delay
    # done

    # DISABLED: Check for OOM and kill ONE job if needed
    # if is_critical_memory && [ ${#pid_order[@]} -gt 0 ]; then
    #   local kill_pid="${pid_order[-1]}"
    #   pid_order=("${pid_order[@]:0:${#pid_order[@]}-1}")
    #
    #   avail_mem=$(get_available_memory_gb)
    #   echo "[OOM] Critical memory during final wait! Available: ${avail_mem}GB < MIN_MEMORY: ${MIN_MEMORY_GB}GB"
    #   echo "[OOM] Killing most recent job: ${job_desc[$kill_pid]} (PID: $kill_pid)"
    #
    #   kill -9 "$kill_pid" 2>/dev/null
    #   wait "$kill_pid" 2>/dev/null
    #
    #   retry_queue+=("${job_params[$kill_pid]}")
    #
    #   unset job_pids[$kill_pid]
    #   unset job_desc[$kill_pid]
    #   unset job_params[$kill_pid]
    #   ((running_jobs--))
    #
    #   echo "[OOM] Job added to retry queue for later execution (running: $running_jobs)"
    #   sleep 3
    # fi

    # Check for completed jobs
    local completed_any=false
    for pid in "${!job_pids[@]}"; do
      if ! ps -p "$pid" > /dev/null 2>&1; then
        wait "$pid"
        exit_status=$?

        if [ $exit_status -eq 0 ]; then
          echo "[COMPLETED] ${job_desc[$pid]}"
        else
          echo "[FAILED] ${job_desc[$pid]} (exit: $exit_status)"
        fi

        # Remove from pid_order
        local new_pid_order=()
        for p in "${pid_order[@]}"; do
          if [ "$p" != "$pid" ]; then
            new_pid_order+=("$p")
          fi
        done
        pid_order=("${new_pid_order[@]}")

        unset job_pids[$pid]
        unset job_desc[$pid]
        unset job_params[$pid]
        ((running_jobs--))
        completed_any=true
      fi
    done

    # If nothing completed and no retry, sleep before next check
    if [ "$completed_any" = false ] && [ ${#job_pids[@]} -gt 0 ]; then
      # DISABLED: Adaptive sleep
      # if is_critical_memory; then
      #   sleep 1
      # else
        sleep 5
      # fi
    fi
  done

  # Stop monitoring
  stop_monitoring

  # Track end time
  local end_time=$(date +%s)
  local total_time=$((end_time - start_time))

  # Calculate throughput
  local throughput=$(echo "scale=4; $total_jobs / $total_time" | bc -l)

  echo ""
  echo "========================================================================"
  echo "$schedule_name Schedule Completed"
  echo "========================================================================"
  echo "Total jobs: $total_jobs"
  echo "Total time: ${total_time}s"
  echo "Throughput: ${throughput} jobs/second"
  echo "========================================================================"

  # Append to summary file
  (
    flock -x 200
    echo "========================================" >> "$SUMMARY_FILE"
    echo "Schedule: $schedule_name" >> "$SUMMARY_FILE"
    echo "Total jobs: $total_jobs" >> "$SUMMARY_FILE"
    echo "Total time: ${total_time}s" >> "$SUMMARY_FILE"
    echo "Throughput: ${throughput} jobs/second" >> "$SUMMARY_FILE"
    echo "========================================" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
  ) 200>"${SUMMARY_FILE}.lock"
}

################################################################################
# MAIN EXECUTION
################################################################################

# Initialize CSV files based on schedule mode
if [ "$SCHEDULE_MODE" = "baseline" ] || [ "$SCHEDULE_MODE" = "both" ]; then
  echo "timestamp,schedule_type,cpu_utilization_percent,memory_usage_gb,running_jobs_count" > "$MONITORING_CSV_BASELINE"
fi

if [ "$SCHEDULE_MODE" = "balanced" ] || [ "$SCHEDULE_MODE" = "both" ]; then
  echo "timestamp,schedule_type,cpu_utilization_percent,memory_usage_gb,running_jobs_count" > "$MONITORING_CSV_BALANCED"
fi

# Initialize summary file
echo "Parallel Scheduling Performance Comparison" > "$SUMMARY_FILE"
echo "==========================================" >> "$SUMMARY_FILE"
echo "Configuration:" >> "$SUMMARY_FILE"
echo "  Benchmarks: $BENCHMARKS" >> "$SUMMARY_FILE"
echo "  Iterations: $NUM_ITERATIONS" >> "$SUMMARY_FILE"
echo "  Max parallel: $MAX_PARALLEL" >> "$SUMMARY_FILE"
echo "  Min memory: ${MIN_MEMORY_GB}GB" >> "$SUMMARY_FILE"
echo "==========================================" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Check if baseline binary exists
if [ ! -f "$BASELINE_BINARY" ]; then
  echo "ERROR: Baseline binary not found at $BASELINE_BINARY"
  exit 1
fi

if [ ! -f "$GEM5_CONFIG" ]; then
  echo "ERROR: GEM5 config not found at $GEM5_CONFIG"
  exit 1
fi

# Run requested schedule(s)
if [ "$SCHEDULE_MODE" = "baseline" ] || [ "$SCHEDULE_MODE" = "both" ]; then
  declare -a BASELINE_QUEUE
  create_baseline_queue BASELINE_QUEUE
  run_schedule "baseline" BASELINE_QUEUE
fi

if [ "$SCHEDULE_MODE" = "balanced" ] || [ "$SCHEDULE_MODE" = "both" ]; then
  declare -a BALANCED_QUEUE
  create_balanced_queue BALANCED_QUEUE
  run_schedule "balanced" BALANCED_QUEUE
fi

echo ""
echo "========================================================================"
echo "All Schedules Completed"
echo "========================================================================"
echo "Results saved to:"
if [ "$SCHEDULE_MODE" = "baseline" ]; then
  echo "  Monitoring data: $MONITORING_CSV_BASELINE"
elif [ "$SCHEDULE_MODE" = "balanced" ]; then
  echo "  Monitoring data: $MONITORING_CSV_BALANCED"
else
  echo "  Monitoring data (baseline): $MONITORING_CSV_BASELINE"
  echo "  Monitoring data (balanced): $MONITORING_CSV_BALANCED"
fi
echo "  Summary: $SUMMARY_FILE"
echo "  Run directories: $FIG10_RUNDIR_DIR"
echo ""
echo "To generate performance comparison graph:"
echo "  python3 $REPO_DIR/runscripts/plotters/fig10_plotter.py"
echo "========================================================================"
