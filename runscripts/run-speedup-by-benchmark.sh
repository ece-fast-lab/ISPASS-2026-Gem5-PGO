#!/bin/bash

# This script runs baseline and PGO simulations for benchmark-level speedup analysis
# For each simulated benchmark's simpoints, it runs:
#   - Baseline (gem5.fast)
#   - All PGO variants (gem5.pgo from each benchmark)
# Results are saved to a single CSV for later aggregation by benchmark

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_INIT_SH="$SCRIPT_DIR/../setup/init.sh"

if [ -f "$SETUP_INIT_SH" ]; then
  # shellcheck source=/dev/null
  source "$SETUP_INIT_SH"
fi

if [ -z "$REPO_DIR" ]; then
  echo "REPO_DIR environment variable is not set. Please source init.sh"
  exit 1
fi

if [ -z "$SPEC_BUILT_DIR" ]; then
  echo "SPEC_BUILT_DIR environment variable is not set. Please source init.sh"
  exit 1
fi

# Configuration - can be overridden by environment variables
# Full benchmark list (commented out for testing)
# BENCHMARKS="600.perlbench_s.0 600.perlbench_s.1 600.perlbench_s.2 602.gcc_s.0 602.gcc_s.1 602.gcc_s.2 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0 657.xz_s.1"

# Test configuration
BENCHMARKS=${BENCHMARKS:-"602.gcc_s.0 605.mcf_s"}
MAX_PARALLEL=${MAX_PARALLEL:-40}
NUM_ITERATIONS=${NUM_ITERATIONS:-2}
MIN_MEMORY_GB=${MIN_MEMORY_GB:-100}  # Minimum available memory in GB before launching new jobs
EVAL_PGOS=${EVAL_PGOS:-false}  # Whether to evaluate additional PGO variants (e.g., unified PGO)
EVAL_PGOS_MIBENCH=${EVAL_PGOS_MIBENCH:-false}  # Whether to evaluate PGO variants on MiBench benchmarks
EVAL_PGOS_SPLASH=${EVAL_PGOS_SPLASH:-false}  # Whether to evaluate PGO variants on Splash benchmarks (1-core)
EVAL_PGOS_SPLASH_4CORE=${EVAL_PGOS_SPLASH_4CORE:-false}  # Whether to evaluate PGO variants on Splash benchmarks (4-core)
JOB_LAUNCH_DELAY=${JOB_LAUNCH_DELAY:-4}  # Delay in seconds between job launches to prevent memory spike

RUN_LABEL=gem5_profile_x86-m64
GEM5_CONFIG="${GEM5_CONFIG:-${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}}"
GEM5_CONFIG_RUBY_4CORE="${GEM5_CONFIG_RUBY_4CORE:-$REPO_DIR/gem5_config/run-ruby-4core.py}"
BASELINE_BINARY="${BASELINE_BINARY:-${GEM5:-$REPO_DIR/gem5/build/X86/gem5.fast}}"
PGO_BINS_DIR="${PGO_BINS_DIR:-$REPO_DIR/pgo_bins}"
UNIFIED_PGO_BINARY="${UNIFIED_PGO_BINARY:-$REPO_DIR/pgo_bins/unified_all_benchmarks/gem5.pgo}"
TOP10_PGO_BINARY="${TOP10_PGO_BINARY:-$REPO_DIR/pgo_bins/gem5_top10.pgo}"
CLUSTERING_PGO_BINARY="${CLUSTERING_PGO_BINARY:-$REPO_DIR/pgo_bins/gem5_cluster.pgo}"
MEM_PGO_BINARY="${MEM_PGO_BINARY:-$REPO_DIR/pgo_bins/gem5_mem.pgo}"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
MIBENCH_BASE_DIR="${MIBENCH_BASE_DIR:-$HOME/MiBench}"
MIBENCH_INPUTS_DIR="${MIBENCH_INPUTS_DIR:-$MIBENCH_BASE_DIR/inputs}"
SPLASH_BASE_DIR="${SPLASH_BASE_DIR:-$HOME/Splash-3/codes}"
RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$REPO_DIR/results/data}"
RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$REPO_DIR/results/figs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
CSV_FILE=$RESULTS_DATA_DIR/execution_times.csv
MIBENCH_CSV_FILE=$RESULTS_DATA_DIR/mibench_execution_times.csv
SPLASH_CSV_FILE=$RESULTS_DATA_DIR/splash_execution_times.csv
SPLASH_4CORE_CSV_FILE=$RESULTS_DATA_DIR/splash_4core_execution_times.csv

# Create results directory
mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_RUNDIR_DIR/speedup-bench"
export RESULTS_DATA_DIR RESULTS_FIGS_DIR RESULTS_RUNDIR_DIR

# Initialize CSV if it doesn't exist
if [ ! -f "$CSV_FILE" ]; then
  echo "simulated_benchmark,simpoint,pgo_benchmark,iteration,execution_time" > "$CSV_FILE"
fi

# Initialize MiBench CSV if enabled and doesn't exist
if [ "$EVAL_PGOS_MIBENCH" = true ] && [ ! -f "$MIBENCH_CSV_FILE" ]; then
  echo "simulated_benchmark,simpoint,pgo_benchmark,iteration,execution_time" > "$MIBENCH_CSV_FILE"
fi

# Initialize Splash CSV if enabled and doesn't exist
if [ "$EVAL_PGOS_SPLASH" = true ] && [ ! -f "$SPLASH_CSV_FILE" ]; then
  echo "simulated_benchmark,simpoint,pgo_benchmark,iteration,execution_time" > "$SPLASH_CSV_FILE"
fi

# Initialize Splash 4-core CSV if enabled and doesn't exist
if [ "$EVAL_PGOS_SPLASH_4CORE" = true ] && [ ! -f "$SPLASH_4CORE_CSV_FILE" ]; then
  echo "simulated_benchmark,simpoint,pgo_benchmark,iteration,execution_time" > "$SPLASH_4CORE_CSV_FILE"
fi

# Benchmark definitions
declare -A BENCH_INFO
BENCH_INFO["600.perlbench_s.0"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/checkspam.pl 2500 5 25 11 150 1 1 1 1|4GiB"
BENCH_INFO["600.perlbench_s.1"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/diffmail.pl 4 800 10 17 19 300|4GiB"
BENCH_INFO["600.perlbench_s.2"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/splitmail.pl 6400 12 26 16 100 0|4GiB"
BENCH_INFO["602.gcc_s.0"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -fipa-pta -o gcc-pp.opts-O5_-fipa-pta.s|8GiB"
BENCH_INFO["602.gcc_s.1"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=1000 -fselective-scheduling -fselective-scheduling2 -o gcc-pp.opts-O5_-finline-limit_1000_-fselective-scheduling_-fselective-scheduling2.s|4GiB"
BENCH_INFO["602.gcc_s.2"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=24000 -fgcse -fgcse-las -fgcse-lm -fgcse-sm -o gcc-pp.opts-O5_-finline-limit_24000_-fgcse_-fgcse-las_-fgcse-lm_-fgcse-sm.s|4GiB"
BENCH_INFO["605.mcf_s"]="$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/mcf_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/inp.in|16GiB"
BENCH_INFO["620.omnetpp_s"]="$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_$RUN_LABEL.0000/omnetpp_s_base.$RUN_LABEL|-c General -r 0|4GiB"
BENCH_INFO["625.x264_s.0"]="$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL|--pass 1 --stats x264_stats.log --bitrate 1000 --frames 1000 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720|4GiB"
BENCH_INFO["623.xalancbmk_s"]="$SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalancbmk_s_base.$RUN_LABEL|-v $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/t5.xml $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalanc.xsl|4GiB"
BENCH_INFO["631.deepsjeng_s"]="$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/deepsjeng_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.txt|8GiB"
BENCH_INFO["641.leela_s"]="$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/leela_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.sgf|4GiB"
BENCH_INFO["648.exchange2_s"]="$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_$RUN_LABEL.0000/exchange2_s_base.$RUN_LABEL|6|4GiB"
BENCH_INFO["657.xz_s.0"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cpu2006docs.tar.xz 6643 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 1036078272 1111795472 4|16GiB"
BENCH_INFO["657.xz_s.1"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cld.tar.xz 1400 19cf30ae51eddcbefda78dd06014b4b96281456e078ca7c13e1c0c9e6aaea8dff3efb4ad6b0456697718cede6bd5454852652806a657bb56e07d61128434b474 536995164 539938872 8|24GiB"

# MiBench benchmark definitions (11 benchmarks, excluding djpeg_large and search_large)
BENCH_INFO["basicmath_large"]="$MIBENCH_BASE_DIR/basicmath_large||4GiB"
BENCH_INFO["bitcnts"]="$MIBENCH_BASE_DIR/bitcnts|1125000|4GiB"
BENCH_INFO["qsort_large"]="$MIBENCH_BASE_DIR/qsort_large|$MIBENCH_INPUTS_DIR/qsort_input_large.dat|4GiB"
BENCH_INFO["susan_large"]="$MIBENCH_BASE_DIR/susan_large|$MIBENCH_INPUTS_DIR/susan_input_large.pgm /tmp/output_susan.pgm -s|4GiB"
BENCH_INFO["dijkstra_large"]="$MIBENCH_BASE_DIR/dijkstra_large|$MIBENCH_INPUTS_DIR/dijkstra_input.dat|4GiB"
BENCH_INFO["sha_large"]="$MIBENCH_BASE_DIR/sha_large|$MIBENCH_INPUTS_DIR/sha_input_large.asc|4GiB"
BENCH_INFO["bf_large"]="$MIBENCH_BASE_DIR/bf_large|e $MIBENCH_INPUTS_DIR/sha_input_large.asc /tmp/output_bf.enc 1234567890abcdeffedcba0987654321|4GiB"
BENCH_INFO["toast_large"]="$MIBENCH_BASE_DIR/toast_large|-fps -c $MIBENCH_INPUTS_DIR/gsm_large.au|4GiB"
BENCH_INFO["crc_large"]="$MIBENCH_BASE_DIR/crc_large|$MIBENCH_INPUTS_DIR/adpcm_large.pcm|4GiB"
BENCH_INFO["fft_large"]="$MIBENCH_BASE_DIR/fft_large|8 32768|4GiB"
BENCH_INFO["cjpeg_large"]="$MIBENCH_BASE_DIR/cjpeg_large|-dct int -progressive -opt -outfile /tmp/output_cjpeg.jpeg $MIBENCH_INPUTS_DIR/jpeg_input_large.ppm||4GiB"

# Splash-3 benchmark definitions (11 benchmarks)
# Format: "binary|args|stdin_file|mem"
BENCH_INFO["fmm"]="$SPLASH_BASE_DIR/apps/fmm/FMM||$SPLASH_BASE_DIR/apps/fmm/inputs/input.1.16384|2GiB"
BENCH_INFO["ocean"]="$SPLASH_BASE_DIR/apps/ocean/contiguous_partitions/OCEAN|-p1 -n258||2GiB"
BENCH_INFO["radiosity"]="$SPLASH_BASE_DIR/apps/radiosity/RADIOSITY|-p 1 -ae 5000 -bf 0.1 -en 0.05 -room -batch||2GiB"
BENCH_INFO["raytrace"]="$SPLASH_BASE_DIR/apps/raytrace/RAYTRACE|-p1 -m64 inputs/car.env||2GiB"
BENCH_INFO["volrend"]="$SPLASH_BASE_DIR/apps/volrend/VOLREND|1 inputs/head 8||2GiB"
BENCH_INFO["water-nsquared"]="$SPLASH_BASE_DIR/apps/water-nsquared/WATER-NSQUARED||$SPLASH_BASE_DIR/apps/water-nsquared/inputs/n512-p1|2GiB"
BENCH_INFO["water-spatial"]="$SPLASH_BASE_DIR/apps/water-spatial/WATER-SPATIAL||$SPLASH_BASE_DIR/apps/water-spatial/inputs/n512-p1|2GiB"
BENCH_INFO["cholesky"]="$SPLASH_BASE_DIR/kernels/cholesky/CHOLESKY|-p1|$SPLASH_BASE_DIR/kernels/cholesky/inputs/tk15.O|2GiB"
BENCH_INFO["fft"]="$SPLASH_BASE_DIR/kernels/fft/FFT|-p1 -m16||2GiB"
BENCH_INFO["lu"]="$SPLASH_BASE_DIR/kernels/lu/contiguous_blocks/LU|-p1 -n512||2GiB"
BENCH_INFO["radix"]="$SPLASH_BASE_DIR/kernels/radix/RADIX|-p1 -n1048576||2GiB"

# Splash-3 4-core benchmark definitions (11 benchmarks) - same as 1-core but with -p4
# Format: "binary|args|stdin_file|mem"
BENCH_INFO["fmm-4core"]="$SPLASH_BASE_DIR/apps/fmm/FMM||$SPLASH_BASE_DIR/apps/fmm/inputs/input.4.16384|2GiB"
BENCH_INFO["ocean-4core"]="$SPLASH_BASE_DIR/apps/ocean/contiguous_partitions/OCEAN|-p4 -n258||2GiB"
BENCH_INFO["radiosity-4core"]="$SPLASH_BASE_DIR/apps/radiosity/RADIOSITY|-p 4 -ae 5000 -bf 0.1 -en 0.05 -room -batch||2GiB"
BENCH_INFO["raytrace-4core"]="$SPLASH_BASE_DIR/apps/raytrace/RAYTRACE|-p4 -m64 inputs/car.env||2GiB"
BENCH_INFO["volrend-4core"]="$SPLASH_BASE_DIR/apps/volrend/VOLREND|4 inputs/head 8||2GiB"
BENCH_INFO["water-nsquared-4core"]="$SPLASH_BASE_DIR/apps/water-nsquared/WATER-NSQUARED||$SPLASH_BASE_DIR/apps/water-nsquared/inputs/n512-p4|2GiB"
BENCH_INFO["water-spatial-4core"]="$SPLASH_BASE_DIR/apps/water-spatial/WATER-SPATIAL||$SPLASH_BASE_DIR/apps/water-spatial/inputs/n512-p4|2GiB"
BENCH_INFO["cholesky-4core"]="$SPLASH_BASE_DIR/kernels/cholesky/CHOLESKY|-p4|$SPLASH_BASE_DIR/kernels/cholesky/inputs/tk15.O|2GiB"
BENCH_INFO["fft-4core"]="$SPLASH_BASE_DIR/kernels/fft/FFT|-p4 -m16||2GiB"
BENCH_INFO["lu-4core"]="$SPLASH_BASE_DIR/kernels/lu/contiguous_blocks/LU|-p4 -n512||2GiB"
BENCH_INFO["radix-4core"]="$SPLASH_BASE_DIR/kernels/radix/RADIX|-p4 -n1048576||2GiB"

################################################################################
# COMMON UTILITY FUNCTIONS
################################################################################

# Function to get available memory in GB
get_available_memory_gb() {
  # Get available memory in KB from /proc/meminfo, convert to GB
  local avail_kb=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
  local avail_gb=$(echo "scale=2; $avail_kb / 1024 / 1024" | bc -l)
  echo "$avail_gb"
}

# Function to check if system has enough memory to launch new job
has_enough_memory() {
  local avail_gb=$(get_available_memory_gb)

  # Use bc for floating point comparison
  local has_enough=$(echo "$avail_gb > $MIN_MEMORY_GB" | bc -l)

  if [ "$has_enough" -eq 1 ]; then
    return 0  # Enough memory
  else
    return 1  # Not enough memory
  fi
}

# Function to extract execution time from stats.txt
get_execution_time() {
  local stats_file=$1

  if [ ! -f "$stats_file" ]; then
    echo "ERROR"
    return 1
  fi

  # Get the last occurrence of hostSeconds
  local time=$(grep "hostSeconds" "$stats_file" | tail -1 | awk '{print $2}')

  if [ -z "$time" ]; then
    echo "ERROR"
    return 1
  fi

  # Validate that execution time is at least 50 seconds
  local is_valid=$(echo "$time >= 50" | bc -l)
  if [ "$is_valid" -eq 0 ]; then
    echo "ERROR: Execution time too short: ${time}s (must be >= 50s)" >&2
    echo "ERROR"
    return 1
  fi

  echo "$time"
  return 0
}

# Generic function to check if result already exists in CSV
check_result_exists() {
  local csv_file=$1
  local variant_type=$2
  local sim_bench=$3
  local simpoint=$4
  local variant_name=$5
  local iteration=$6

  if [ ! -f "$csv_file" ]; then
    return 1
  fi

  grep -q "^${sim_bench},${simpoint},${variant_name},${iteration}," "$csv_file"
  return $?
}

# Generic function to record result to CSV (with file locking)
record_result_to_csv() {
  local csv_file=$1
  local variant_type=$2
  local sim_bench=$3
  local simpoint=$4
  local variant_name=$5
  local iteration=$6
  local time=$7

  # Use flock for thread-safe CSV writing
  (
    flock -x 200
    echo "${sim_bench},${simpoint},${variant_name},${iteration},${time}" >> "$csv_file"
  ) 200>"${csv_file}.lock"
}

# Generic function to run gem5 simulation
run_gem5_simulation() {
  local csv_file=$1
  local variant_type=$2  # variant label (e.g., baseline or pgo benchmark)
  local sim_bench=$3
  local simpoint=$4
  local variant_name=$5
  local iteration=$6
  local binary_path=$7
  local spec_binary=$8
  local args=$9
  local mem=${10}
  local checkpoint_path=${11}
  local cpu_affinity=${12}  # CPU affinity (0 to MAX_PARALLEL-1)
  local stdin_file=${13}  # Optional stdin file
  local cpu_type=${14:-o3}  # CPU type (default: o3)
  local gem5_config=${15:-$GEM5_CONFIG}  # gem5 config script (default: GEM5_CONFIG)

  # Check if already completed in CSV
  if check_result_exists "$csv_file" "$variant_type" "$sim_bench" "$simpoint" "$variant_name" "$iteration"; then
    echo "[SKIP] $sim_bench:$simpoint with ${variant_type} $variant_name iteration $iteration (already in CSV)"
    return 0
  fi

  local outdir="$RESULTS_RUNDIR_DIR/speedup-bench/${sim_bench}-${simpoint}-${variant_type}-${variant_name}-iter${iteration}"

  # Check if stats.txt already exists
  if [ -f "$outdir/stats.txt" ]; then
    echo "[EXTRACT] Sim: $sim_bench:$simpoint, ${variant_type}: $variant_name, iteration $iteration (stats.txt exists)"

    # Extract execution time from existing stats.txt
    local exec_time=$(get_execution_time "$outdir/stats.txt")

    if [ "$exec_time" == "ERROR" ]; then
      echo "[ERROR] Failed to extract execution time from existing stats.txt"
      echo "[RERUN] Will run simulation again..."
    else
      # Record result
      record_result_to_csv "$csv_file" "$variant_type" "$sim_bench" "$simpoint" "$variant_name" "$iteration" "$exec_time"
      echo "[DONE] $sim_bench:$simpoint + ${variant_type} $variant_name iteration $iteration = ${exec_time}s (extracted from existing)"
      return 0
    fi
  fi

  echo "[RUN] Sim: $sim_bench:$simpoint, ${variant_type}: $variant_name, iteration $iteration, CPU: $cpu_affinity, cpu-type: $cpu_type"

  # Build gem5 command with stdin if provided
  local gem5_cmd="taskset -c \"$cpu_affinity\" \"$binary_path\" -r --outdir=\"$outdir\" \"$gem5_config\" --binary \"$spec_binary\" --args=\"$args\" --cpu-type $cpu_type --mem-size \"$mem\""

  # Add checkpoint if provided
  if [ -n "$checkpoint_path" ]; then
    gem5_cmd="$gem5_cmd --restore-from \"$checkpoint_path\""
  fi

  # Add stdin if provided
  if [ -n "$stdin_file" ]; then
    gem5_cmd="$gem5_cmd --stdin \"$stdin_file\""
  fi

  # Run gem5 with CPU affinity
  eval $gem5_cmd

  local exit_status=$?

  if [ $exit_status -ne 0 ]; then
    echo "[ERROR] Simulation failed: $sim_bench:$simpoint with ${variant_type} $variant_name iteration $iteration (exit: $exit_status)"
    return 1
  fi

  # Extract execution time
  local exec_time=$(get_execution_time "$outdir/stats.txt")

  if [ "$exec_time" == "ERROR" ]; then
    echo "[ERROR] Failed to extract execution time: $sim_bench:$simpoint with ${variant_type} $variant_name iteration $iteration"
    return 1
  fi

  # Record result
  record_result_to_csv "$csv_file" "$variant_type" "$sim_bench" "$simpoint" "$variant_name" "$iteration" "$exec_time"
  echo "[DONE] $sim_bench:$simpoint + ${variant_type} $variant_name iteration $iteration = ${exec_time}s"

  return 0
}

# Generic function to run jobs in parallel with memory-aware launching
run_jobs_in_parallel() {
  local job_queue_name=$1  # Name of the array containing jobs
  local csv_file=$2
  local variant_type=$3  # variant label used in output metadata
  local total_jobs=$4

  # Create array reference
  local -n job_queue=$job_queue_name

  echo ""
  echo "Starting parallel execution..."
  echo "Total jobs in queue: ${#job_queue[@]}"
  echo "Max parallel: $MAX_PARALLEL"
  echo "Job launch delay: ${JOB_LAUNCH_DELAY}s"
  echo "CPU affinity: CPUs 0-$((MAX_PARALLEL-1))"
  echo "========================================================================"

  local job_count=0
  local running_jobs=0
  declare -A job_pids
  declare -A job_desc
  declare -A job_cpu  # Track which CPU each job is using

  # Initialize available CPU pool (0 to MAX_PARALLEL-1)
  declare -a available_cpus
  for ((cpu=0; cpu<MAX_PARALLEL; cpu++)); do
    available_cpus+=($cpu)
  done

  for job in "${job_queue[@]}"; do
    IFS='|' read -r sim_bench simpoint variant_name iter binary_path spec_binary args mem checkpoint_path stdin_file cpu_type gem5_config <<< "$job"

    # Check if already exists before launching
    if check_result_exists "$csv_file" "$variant_type" "$sim_bench" "$simpoint" "$variant_name" "$iter"; then
      continue
    fi

    # Wait if max parallel jobs reached OR insufficient memory OR no available CPUs
    wait_message_printed=false
    while [ $running_jobs -ge $MAX_PARALLEL ] || ! has_enough_memory || [ ${#available_cpus[@]} -eq 0 ]; do
      # Print waiting reason (only once per wait cycle)
      if [ "$wait_message_printed" = false ]; then
        if [ $running_jobs -ge $MAX_PARALLEL ]; then
          avail_mem=$(get_available_memory_gb)
          echo "[WAIT] Max parallel jobs reached ($running_jobs/$MAX_PARALLEL), available memory: ${avail_mem}GB"
        elif [ ${#available_cpus[@]} -eq 0 ]; then
          avail_mem=$(get_available_memory_gb)
          echo "[WAIT] No available CPUs (all CPUs 0-$((MAX_PARALLEL-1)) in use), available memory: ${avail_mem}GB"
        else
          avail_mem=$(get_available_memory_gb)
          echo "[WAIT] Insufficient memory (${avail_mem}GB available, need >${MIN_MEMORY_GB}GB), running jobs: $running_jobs"
        fi
        wait_message_printed=true
      fi

      sleep 5

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

          # Return CPU to available pool
          local freed_cpu=${job_cpu[$pid]}
          available_cpus+=($freed_cpu)
          echo "[CPU] Released CPU $freed_cpu (available CPUs: ${#available_cpus[@]})"

          unset job_pids[$pid]
          unset job_desc[$pid]
          unset job_cpu[$pid]
          ((running_jobs--))
          wait_message_printed=false  # Reset flag when job completes
        fi
      done
    done

    # Memory-aware launch: Wait before launching to prevent memory spike
    if [ $running_jobs -gt 0 ]; then
      echo "[DELAY] Waiting ${JOB_LAUNCH_DELAY}s before launching next job (prevent memory spike)..."
      sleep $JOB_LAUNCH_DELAY

      # Check memory again after delay
      if ! has_enough_memory; then
        avail_mem=$(get_available_memory_gb)
        echo "[MEMORY CHECK] Insufficient memory after delay (${avail_mem}GB), waiting for jobs to complete..."
        continue
      fi
    fi

    # Allocate CPU from available pool
    local assigned_cpu=${available_cpus[0]}
    available_cpus=("${available_cpus[@]:1}")  # Remove first element

    # Launch job in background with CPU affinity
    run_gem5_simulation "$csv_file" "$variant_type" "$sim_bench" "$simpoint" "$variant_name" "$iter" \
      "$binary_path" "$spec_binary" "$args" "$mem" "$checkpoint_path" "$assigned_cpu" "$stdin_file" "$cpu_type" "$gem5_config" &

    pid=$!
    job_pids[$pid]=1
    job_desc[$pid]="$sim_bench:$simpoint + ${variant_type} $variant_name iter$iter"
    job_cpu[$pid]=$assigned_cpu
    ((running_jobs++))
    ((job_count++))

    avail_mem=$(get_available_memory_gb)
    echo "[LAUNCHED] ${job_desc[$pid]} (PID: $pid, CPU: $assigned_cpu, running: $running_jobs, mem: ${avail_mem}GB)"

    if [ $((job_count % 20)) -eq 0 ]; then
      # Count only lines in the current CSV file (not including header)
      if [ -f "$csv_file" ]; then
        completed=$(tail -n +2 "$csv_file" 2>/dev/null | wc -l)
      else
        completed=0
      fi
      echo "Progress: $completed / $total_jobs completed, $running_jobs running"
    fi
  done

  # Wait for all remaining jobs to complete
  echo ""
  echo "Waiting for remaining jobs to complete..."

  for pid in "${!job_pids[@]}"; do
    wait "$pid"
    exit_status=$?

    if [ $exit_status -eq 0 ]; then
      echo "[COMPLETED] ${job_desc[$pid]}"
    else
      echo "[FAILED] ${job_desc[$pid]} (exit: $exit_status)"
    fi

    # Return CPU to available pool
    local freed_cpu=${job_cpu[$pid]}
    available_cpus+=($freed_cpu)
    echo "[CPU] Released CPU $freed_cpu (available CPUs: ${#available_cpus[@]})"
  done
}

################################################################################
# MAIN EXECUTION - STANDARD PGO ANALYSIS
################################################################################

# Determine which analysis to run based on flags
RUN_STANDARD_PGO=false
RUN_EVAL_PGOS_ONLY=false

if [ "$EVAL_PGOS_MIBENCH" = true ]; then
  echo "========================================================================"
  echo "MiBench EVAL_PGOS mode enabled - skipping standard PGO analysis"
  echo "========================================================================"
elif [ "$EVAL_PGOS_SPLASH" = true ]; then
  echo "========================================================================"
  echo "Splash EVAL_PGOS mode enabled - skipping standard PGO analysis"
  echo "========================================================================"
elif [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; then
  echo "========================================================================"
  echo "Splash 4-core EVAL_PGOS mode enabled - skipping standard PGO analysis"
  echo "========================================================================"
elif [ "$EVAL_PGOS" = true ]; then
  echo "========================================================================"
  echo "EVAL_PGOS mode enabled - running only unified/mix PGO analysis"
  echo "========================================================================"
  RUN_EVAL_PGOS_ONLY=true
else
  echo "========================================================================"
  echo "Running Standard Benchmark-Level Speedup Analysis"
  echo "========================================================================"
  RUN_STANDARD_PGO=true
fi

# Run standard/eval analysis when requested
if [ "$RUN_STANDARD_PGO" = true ] || [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
  echo "Benchmarks: $BENCHMARKS"
  echo "Number of iterations per run: $NUM_ITERATIONS"
  echo "Max parallel jobs: $MAX_PARALLEL"
  echo "Minimum memory required: $MIN_MEMORY_GB GB"
  echo "Current available memory: $(get_available_memory_gb) GB"
  echo "Job launch delay: ${JOB_LAUNCH_DELAY}s"
  echo "CPU affinity: CPUs 0-$((MAX_PARALLEL-1))"
  echo "Results CSV: $CSV_FILE"
  echo "========================================================================"

  # Check if baseline binary exists
  if [ ! -f "$BASELINE_BINARY" ]; then
    echo "ERROR: Baseline binary not found at $BASELINE_BINARY"
    exit 1
  fi
fi

if [ "$RUN_STANDARD_PGO" = true ] || [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
  # Convert BENCHMARKS string to array
  BENCHMARK_ARRAY=($BENCHMARKS)

  # Build list of all simpoints for each benchmark
  declare -A BENCH_SIMPOINTS

  for bench in "${BENCHMARK_ARRAY[@]}"; do
    # Validate benchmark info exists
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      echo "Available benchmarks: ${!BENCH_INFO[@]}"
      exit 1
    fi

    checkpoint_dir="$CHECKPOINT_BASE_DIR/${bench}"

    if [ ! -d "$checkpoint_dir" ]; then
      echo "ERROR: Checkpoint directory not found: $checkpoint_dir"
      exit 1
    fi

    # Get ALL simpoints (sorted)
    simpoints=($(ls -d "$checkpoint_dir"/* 2>/dev/null | sort -V | xargs -n1 basename))

    if [ ${#simpoints[@]} -eq 0 ]; then
      echo "ERROR: No simpoints found for $bench in $checkpoint_dir"
      exit 1
    fi

    echo "Found ${#simpoints[@]} simpoints for $bench"
    BENCH_SIMPOINTS[$bench]="${simpoints[*]}"
  done

  # Validate PGO binaries based on mode
  if [ "$RUN_STANDARD_PGO" = true ]; then
    # Standard mode: validate all benchmark PGO binaries
    echo ""
    echo "Validating PGO binaries..."
    for bench in "${BENCHMARK_ARRAY[@]}"; do
      pgo_binary="$PGO_BINS_DIR/${bench}/gem5.pgo"
      if [ ! -f "$pgo_binary" ]; then
        echo "ERROR: PGO binary not found: $pgo_binary"
        echo "Please run build-pgo-by-benchmark.sh first"
        exit 1
      fi
      echo "  ✓ $bench: $pgo_binary"
    done
  elif [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
    # EVAL_PGOS mode: validate self-pgo/unified/top10/clustering/mem binaries
    echo ""
    echo "Validating self-PGO binaries..."
    for bench in "${BENCHMARK_ARRAY[@]}"; do
      self_pgo_binary="$PGO_BINS_DIR/${bench}/gem5.pgo"
      if [ ! -f "$self_pgo_binary" ]; then
        echo "ERROR: Self-PGO binary not found: $self_pgo_binary"
        echo "Please run build-pgo-by-benchmark.sh first"
        exit 1
      fi
      echo "  ✓ $bench: $self_pgo_binary"
    done

    echo ""
    echo "Validating unified PGO binary..."
    if [ ! -f "$UNIFIED_PGO_BINARY" ]; then
      echo "ERROR: Unified PGO binary not found: $UNIFIED_PGO_BINARY"
      echo "Please ensure unified PGO binary is built"
      exit 1
    fi
    echo "  ✓ unified: $UNIFIED_PGO_BINARY"

    echo ""
    echo "Validating top10 PGO binary..."
    if [ ! -f "$TOP10_PGO_BINARY" ]; then
      echo "ERROR: Top10 PGO binary not found: $TOP10_PGO_BINARY"
      echo "Please ensure top10 PGO binary is built"
      exit 1
    fi
    echo "  ✓ top10: $TOP10_PGO_BINARY"

    echo ""
    echo "Validating clustering PGO binary..."
    if [ ! -f "$CLUSTERING_PGO_BINARY" ]; then
      echo "ERROR: Clustering PGO binary not found: $CLUSTERING_PGO_BINARY"
      echo "Please ensure clustering PGO binary is built"
      exit 1
    fi
    echo "  ✓ clustering: $CLUSTERING_PGO_BINARY"

    echo ""
    echo "Validating mem PGO binary..."
    if [ ! -f "$MEM_PGO_BINARY" ]; then
      echo "ERROR: Mem PGO binary not found: $MEM_PGO_BINARY"
      echo "Please ensure mem PGO binary is built"
      exit 1
    fi
    echo "  ✓ mem: $MEM_PGO_BINARY"
  fi

  # Generate job combinations based on mode
  echo ""
  echo "Generating job queue..."
  declare -a STANDARD_JOB_QUEUE

  total_simpoint_count=0

  for sim_bench in "${BENCHMARK_ARRAY[@]}"; do
    bench_info="${BENCH_INFO[$sim_bench]}"
    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"

    simpoints=(${BENCH_SIMPOINTS[$sim_bench]})
    total_simpoint_count=$((total_simpoint_count + ${#simpoints[@]}))

    for simpoint in "${simpoints[@]}"; do
      checkpoint_path="$CHECKPOINT_BASE_DIR/${sim_bench}/${simpoint}"

      # For each iteration
      for iter in $(seq 1 $NUM_ITERATIONS); do
        # Add baseline job (SPEC uses o3, no stdin, default config)
        STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|baseline|$iter|$BASELINE_BINARY|$spec_binary|$args|$mem|$checkpoint_path||o3|")

        if [ "$RUN_STANDARD_PGO" = true ]; then
          # Standard mode: Add PGO jobs for all benchmarks
          for pgo_bench in "${BENCHMARK_ARRAY[@]}"; do
            pgo_binary="$PGO_BINS_DIR/${pgo_bench}/gem5.pgo"
            STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|$pgo_bench|$iter|$pgo_binary|$spec_binary|$args|$mem|$checkpoint_path||o3|")
          done
        elif [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
          # EVAL_PGOS mode: Add self-pgo, unified, clustering, top10, and mem PGO jobs
          self_pgo_binary="$PGO_BINS_DIR/${sim_bench}/gem5.pgo"
          STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|$sim_bench|$iter|$self_pgo_binary|$spec_binary|$args|$mem|$checkpoint_path||o3|")
          STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|unified|$iter|$UNIFIED_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path||o3|")
          STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|clustering|$iter|$CLUSTERING_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path||o3|")
          STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|top10|$iter|$TOP10_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path||o3|")
          STANDARD_JOB_QUEUE+=("$sim_bench|$simpoint|mem|$iter|$MEM_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path||o3|")
        fi
      done
    done
  done

  num_benchmarks=${#BENCHMARK_ARRAY[@]}
  # Calculate expected jobs based on mode
  if [ "$RUN_STANDARD_PGO" = true ]; then
    # baseline + benchmark PGOs
    pgo_variants_per_simpoint=$num_benchmarks
    expected_jobs=$((total_simpoint_count * (pgo_variants_per_simpoint + 1) * NUM_ITERATIONS))
  elif [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
    # baseline + self-pgo + unified + clustering + top10 + mem
    pgo_variants_per_simpoint=5
    expected_jobs=$((total_simpoint_count * 6 * NUM_ITERATIONS))
  fi
  total_jobs=${#STANDARD_JOB_QUEUE[@]}

  echo ""
  echo "Job statistics:"
  echo "  Total simpoints: $total_simpoint_count"
  echo "  PGO variants per simpoint: $pgo_variants_per_simpoint"
  if [ "$RUN_STANDARD_PGO" = true ]; then
    echo "    - Benchmark PGOs: $num_benchmarks"
  elif [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
    echo "    - Self-PGO: 1"
    echo "    - Unified PGO: 1"
    echo "    - Clustering PGO: 1"
    echo "    - Top10 PGO: 1"
    echo "    - Mem PGO: 1"
  fi
  echo "  Iterations: $NUM_ITERATIONS"
  echo "  Expected jobs: $expected_jobs"
  echo "  Actual jobs in queue: $total_jobs"

  # Run jobs in parallel
  run_jobs_in_parallel STANDARD_JOB_QUEUE "$CSV_FILE" "pgo" "$total_jobs"

  echo ""
  echo "========================================================================"
  if [ "$RUN_STANDARD_PGO" = true ]; then
    echo "Standard PGO Simulations Completed"
  elif [ "$RUN_EVAL_PGOS_ONLY" = true ]; then
    echo "EVAL_PGOS (Self/Unified/Clustering/Top10/Mem) Simulations Completed"
  fi
  echo "========================================================================"
  echo "Results saved to: $CSV_FILE"

  # Print summary
  total_results=$(grep -cv "^simulated_benchmark," "$CSV_FILE" 2>/dev/null || echo 0)
  echo "Total results recorded: $total_results / $expected_jobs"
  echo "========================================================================"
fi

################################################################################
# MIBENCH EVAL-PGO ANALYSIS (if enabled)
################################################################################

if [ "$EVAL_PGOS_MIBENCH" = true ]; then
  echo ""
  echo "========================================================================"
  echo "Running MiBench Eval-PGO Analysis"
  echo "========================================================================"
  echo "MiBench benchmarks run WITHOUT checkpoints (full execution from start)"
  echo "Testing PGO variants: self-profiling, unified, top10, clustering, mem"
  echo "Note: SPEC PGO is NOT used for MiBench"
  echo "========================================================================"

  # Check if baseline binary exists
  if [ ! -f "$BASELINE_BINARY" ]; then
    echo "ERROR: Baseline binary not found at $BASELINE_BINARY"
    exit 1
  fi

  # Validate unified/top10/clustering/mem PGO binaries
  echo ""
  echo "Validating PGO binaries for MiBench..."
  if [ ! -f "$UNIFIED_PGO_BINARY" ]; then
    echo "ERROR: Unified PGO binary not found: $UNIFIED_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ unified: $UNIFIED_PGO_BINARY"

  if [ ! -f "$TOP10_PGO_BINARY" ]; then
    echo "ERROR: Top10 PGO binary not found: $TOP10_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ top10: $TOP10_PGO_BINARY"

  if [ ! -f "$CLUSTERING_PGO_BINARY" ]; then
    echo "ERROR: Clustering PGO binary not found: $CLUSTERING_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ clustering: $CLUSTERING_PGO_BINARY"

  if [ ! -f "$MEM_PGO_BINARY" ]; then
    echo "ERROR: Mem PGO binary not found: $MEM_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ mem: $MEM_PGO_BINARY"

  # MiBench benchmark list (11 benchmarks, excluding djpeg_large and search_large)
  MIBENCH_BENCHMARKS=(
    "basicmath_large"
    "bitcnts"
    "qsort_large"
    "susan_large"
    "dijkstra_large"
    "sha_large"
    "bf_large"
    "toast_large"
    "crc_large"
    "fft_large"
    "cjpeg_large"
  )

  # Validate self-profiling PGO binaries for MiBench
  echo ""
  echo "Validating self-profiling PGO binaries for MiBench..."
  for bench in "${MIBENCH_BENCHMARKS[@]}"; do
    self_pgo_binary="$PGO_BINS_DIR/mibench/${bench}/gem5.pgo"
    if [ ! -f "$self_pgo_binary" ]; then
      echo "ERROR: Self-profiling PGO binary not found for $bench: $self_pgo_binary"
      exit 1
    fi
    echo "  ✓ $bench: $self_pgo_binary"
  done

  # Validate all MiBench benchmarks
  echo ""
  echo "Validating MiBench benchmarks..."
  for bench in "${MIBENCH_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      exit 1
    fi

    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"
    if [ ! -f "$spec_binary" ]; then
      echo "ERROR: MiBench binary not found: $spec_binary"
      exit 1
    fi
    echo "  ✓ $bench: $spec_binary"
  done

  # Generate MiBench job queue
  echo ""
  echo "Generating MiBench job queue..."
  declare -a MIBENCH_JOB_QUEUE

  for bench in "${MIBENCH_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"

    # Use simpoint="full" for MiBench (no SimPoint intervals)
    simpoint="full"
    # Use empty checkpoint_path for MiBench (no checkpoints)
    checkpoint_path=""

    for iter in $(seq 1 $NUM_ITERATIONS); do
      # Add baseline job (MiBench uses o3, stdin from BENCH_INFO, default config)
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|baseline|$iter|$BASELINE_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")

      # Add self-profiling job (benchmark-specific PGO binary)
      self_pgo_binary="$PGO_BINS_DIR/mibench/${bench}/gem5.pgo"
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|$bench|$iter|$self_pgo_binary|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")

      # Add PGO jobs (unified, top10, clustering, mem)
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|unified|$iter|$UNIFIED_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|top10|$iter|$TOP10_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|clustering|$iter|$CLUSTERING_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")
      MIBENCH_JOB_QUEUE+=("$bench|$simpoint|mem|$iter|$MEM_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|o3|")
    done
  done

  num_mibench_benchmarks=${#MIBENCH_BENCHMARKS[@]}
  # baseline + 5 PGO variants (self-profiling, unified, top10, clustering, mem)
  pgo_variants_per_benchmark=5
  mibench_expected_jobs=$((num_mibench_benchmarks * (pgo_variants_per_benchmark + 1) * NUM_ITERATIONS))
  mibench_total_jobs=${#MIBENCH_JOB_QUEUE[@]}

  echo ""
  echo "MiBench job statistics:"
  echo "  MiBench benchmarks: $num_mibench_benchmarks"
  for bench in "${MIBENCH_BENCHMARKS[@]}"; do
    echo "    - $bench"
  done
  echo "  PGO variants per benchmark: $pgo_variants_per_benchmark"
  echo "    - Self-profiling: 1"
  echo "    - Unified PGO: 1"
  echo "    - Top10 PGO: 1"
  echo "    - Clustering PGO: 1"
  echo "    - Mem PGO: 1"
  echo "  Iterations: $NUM_ITERATIONS"
  echo "  Expected jobs: $mibench_expected_jobs"
  echo "  Actual jobs in queue: $mibench_total_jobs"

  # Run MiBench jobs in parallel
  run_jobs_in_parallel MIBENCH_JOB_QUEUE "$MIBENCH_CSV_FILE" "pgo" "$mibench_total_jobs"

  echo ""
  echo "========================================================================"
  echo "MiBench Eval-PGO Simulations Completed"
  echo "========================================================================"
  echo "Results saved to: $MIBENCH_CSV_FILE"

  # Print summary
  mibench_total_results=$(grep -cv "^simulated_benchmark," "$MIBENCH_CSV_FILE" 2>/dev/null || echo 0)
  echo "Total MiBench results recorded: $mibench_total_results / $mibench_expected_jobs"
  echo "========================================================================"
fi

################################################################################
# SPLASH EVAL-PGO ANALYSIS (if enabled)
################################################################################

if [ "$EVAL_PGOS_SPLASH" = true ]; then
  echo ""
  echo "========================================================================"
  echo "Running Splash Eval-PGO Analysis"
  echo "========================================================================"
  echo "Splash benchmarks run WITHOUT checkpoints (full execution from start)"
  echo "Testing PGO variants: self-profiling, mem"
  echo "CPU type: Minor (not O3)"
  echo "Note: SPEC PGO is NOT used for Splash"
  echo "========================================================================"

  # Check if baseline binary exists
  if [ ! -f "$BASELINE_BINARY" ]; then
    echo "ERROR: Baseline binary not found at $BASELINE_BINARY"
    exit 1
  fi

  # Validate mem PGO binary
  echo ""
  echo "Validating PGO binaries for Splash..."
  if [ ! -f "$MEM_PGO_BINARY" ]; then
    echo "ERROR: Mem PGO binary not found: $MEM_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ mem: $MEM_PGO_BINARY"

  # Splash benchmark list (11 benchmarks)
  SPLASH_BENCHMARKS=(
    # "fmm"
    "ocean"
    "radiosity"
    "raytrace"
    "volrend"
    # "water-nsquared"
    # "water-spatial"
    "cholesky"
    "fft"
    "lu"
    "radix"
  )

  # Validate self-profiling PGO binaries for Splash
  echo ""
  echo "Validating self-profiling PGO binaries for Splash..."
  for bench in "${SPLASH_BENCHMARKS[@]}"; do
    self_pgo_binary="$PGO_BINS_DIR/splash/${bench}/gem5.pgo"
    if [ ! -f "$self_pgo_binary" ]; then
      echo "ERROR: Self-profiling PGO binary not found for $bench: $self_pgo_binary"
      exit 1
    fi
    echo "  ✓ $bench: $self_pgo_binary"
  done

  # Validate all Splash benchmarks
  echo ""
  echo "Validating Splash benchmarks..."
  for bench in "${SPLASH_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      exit 1
    fi

    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"
    if [ ! -f "$spec_binary" ]; then
      echo "ERROR: Splash binary not found: $spec_binary"
      exit 1
    fi
    echo "  ✓ $bench: $spec_binary"
  done

  # Generate Splash job queue
  echo ""
  echo "Generating Splash job queue..."
  declare -a SPLASH_JOB_QUEUE

  for bench in "${SPLASH_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"

    # Use simpoint="full" for Splash (no SimPoint intervals)
    simpoint="full"
    # Use empty checkpoint_path for Splash (no checkpoints)
    checkpoint_path=""

    for iter in $(seq 1 $NUM_ITERATIONS); do
      # Add baseline job (Splash uses minor, stdin from BENCH_INFO, default config)
      SPLASH_JOB_QUEUE+=("$bench|$simpoint|baseline|$iter|$BASELINE_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|")

      # Add self-profiling job (benchmark-specific PGO binary)
      self_pgo_binary="$PGO_BINS_DIR/splash/${bench}/gem5.pgo"
      SPLASH_JOB_QUEUE+=("$bench|$simpoint|$bench|$iter|$self_pgo_binary|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|")

      # Add mem PGO job
      SPLASH_JOB_QUEUE+=("$bench|$simpoint|mem|$iter|$MEM_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|")
    done
  done

  num_splash_benchmarks=${#SPLASH_BENCHMARKS[@]}
  # baseline + 2 PGO variants (self-profiling, mem)
  pgo_variants_per_benchmark=2
  splash_expected_jobs=$((num_splash_benchmarks * (pgo_variants_per_benchmark + 1) * NUM_ITERATIONS))
  splash_total_jobs=${#SPLASH_JOB_QUEUE[@]}

  echo ""
  echo "Splash job statistics:"
  echo "  Splash benchmarks: $num_splash_benchmarks"
  for bench in "${SPLASH_BENCHMARKS[@]}"; do
    echo "    - $bench"
  done
  echo "  PGO variants per benchmark: $pgo_variants_per_benchmark"
  echo "    - Self-profiling: 1"
  echo "    - Mem PGO: 1"
  echo "  Iterations: $NUM_ITERATIONS"
  echo "  Expected jobs: $splash_expected_jobs"
  echo "  Actual jobs in queue: $splash_total_jobs"

  # Run Splash jobs in parallel
  run_jobs_in_parallel SPLASH_JOB_QUEUE "$SPLASH_CSV_FILE" "pgo" "$splash_total_jobs"

  echo ""
  echo "========================================================================"
  echo "Splash Eval-PGO Simulations Completed"
  echo "========================================================================"
  echo "Results saved to: $SPLASH_CSV_FILE"

  # Print summary
  splash_total_results=$(grep -cv "^simulated_benchmark," "$SPLASH_CSV_FILE" 2>/dev/null || echo 0)
  echo "Total Splash results recorded: $splash_total_results / $splash_expected_jobs"
  echo "========================================================================"
fi

################################################################################
# SPLASH 4-CORE EVAL-PGO ANALYSIS (if enabled)
################################################################################

if [ "$EVAL_PGOS_SPLASH_4CORE" = true ]; then
  echo ""
  echo "========================================================================"
  echo "Running Splash 4-Core Eval-PGO Analysis"
  echo "========================================================================"
  echo "Splash 4-core benchmarks run WITHOUT checkpoints (full execution from start)"
  echo "Testing PGO variants: self-profiling, mem"
  echo "CPU type: Minor (not O3)"
  echo "Architecture: 4-core with Ruby MESI Two-Level cache"
  echo "Note: SPEC PGO is NOT used for Splash"
  echo "========================================================================"

  # Check if baseline binary exists
  if [ ! -f "$BASELINE_BINARY" ]; then
    echo "ERROR: Baseline binary not found at $BASELINE_BINARY"
    exit 1
  fi

  # Validate mem PGO binary
  echo ""
  echo "Validating PGO binaries for Splash 4-core..."
  if [ ! -f "$MEM_PGO_BINARY" ]; then
    echo "ERROR: Mem PGO binary not found: $MEM_PGO_BINARY"
    exit 1
  fi
  echo "  ✓ mem: $MEM_PGO_BINARY"

  # Splash 4-core benchmark list (11 benchmarks) - use -4core suffix
  SPLASH_4CORE_BENCHMARKS=(
    # "fmm-4core"
    "ocean-4core"
    # "radiosity-4core"
    # "raytrace-4core"
    # "volrend-4core"
    # "water-nsquared-4core"
    # "water-spatial-4core"
    # "cholesky-4core"
    "fft-4core"
    "lu-4core"
    "radix-4core"
  )

  # Map 4-core benchmark names to their base names for PGO binary lookup
  declare -A SPLASH_4CORE_TO_BASE
  SPLASH_4CORE_TO_BASE["fmm-4core"]="fmm"
  SPLASH_4CORE_TO_BASE["ocean-4core"]="ocean"
  SPLASH_4CORE_TO_BASE["radiosity-4core"]="radiosity"
  SPLASH_4CORE_TO_BASE["raytrace-4core"]="raytrace"
  SPLASH_4CORE_TO_BASE["volrend-4core"]="volrend"
  SPLASH_4CORE_TO_BASE["water-nsquared-4core"]="water-nsquared"
  SPLASH_4CORE_TO_BASE["water-spatial-4core"]="water-spatial"
  SPLASH_4CORE_TO_BASE["cholesky-4core"]="cholesky"
  SPLASH_4CORE_TO_BASE["fft-4core"]="fft"
  SPLASH_4CORE_TO_BASE["lu-4core"]="lu"
  SPLASH_4CORE_TO_BASE["radix-4core"]="radix"

  # Validate self-profiling PGO binaries for Splash 4-core
  echo ""
  echo "Validating self-profiling PGO binaries for Splash 4-core..."
  for bench in "${SPLASH_4CORE_BENCHMARKS[@]}"; do
    base_bench="${SPLASH_4CORE_TO_BASE[$bench]}"
    self_pgo_binary="$PGO_BINS_DIR/splash-4core/${base_bench}/gem5.pgo"
    if [ ! -f "$self_pgo_binary" ]; then
      echo "ERROR: Self-profiling PGO binary not found for $bench: $self_pgo_binary"
      exit 1
    fi
    echo "  ✓ $bench: $self_pgo_binary"
  done

  # Validate all Splash 4-core benchmarks
  echo ""
  echo "Validating Splash 4-core benchmarks..."
  for bench in "${SPLASH_4CORE_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    if [ -z "$bench_info" ]; then
      echo "ERROR: Benchmark info not found for $bench"
      exit 1
    fi

    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"
    if [ ! -f "$spec_binary" ]; then
      echo "ERROR: Splash 4-core binary not found: $spec_binary"
      exit 1
    fi
    echo "  ✓ $bench: $spec_binary"
  done

  # Generate Splash 4-core job queue
  echo ""
  echo "Generating Splash 4-core job queue..."
  declare -a SPLASH_4CORE_JOB_QUEUE

  for bench in "${SPLASH_4CORE_BENCHMARKS[@]}"; do
    bench_info="${BENCH_INFO[$bench]}"
    IFS='|' read -r spec_binary args stdin_file mem <<< "$bench_info"

    # Use simpoint="full" for Splash (no SimPoint intervals)
    simpoint="full"
    # Use empty checkpoint_path for Splash (no checkpoints)
    checkpoint_path=""

    # Get base benchmark name for PGO binary lookup
    base_bench="${SPLASH_4CORE_TO_BASE[$bench]}"

    for iter in $(seq 1 $NUM_ITERATIONS); do
      # Add baseline job (Splash 4-core uses minor, stdin from BENCH_INFO, ruby-4core config)
      SPLASH_4CORE_JOB_QUEUE+=("$bench|$simpoint|baseline|$iter|$BASELINE_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|$GEM5_CONFIG_RUBY_4CORE")

      # Add self-profiling job (benchmark-specific PGO binary from splash-4core directory)
      self_pgo_binary="$PGO_BINS_DIR/splash-4core/${base_bench}/gem5.pgo"
      SPLASH_4CORE_JOB_QUEUE+=("$bench|$simpoint|$bench|$iter|$self_pgo_binary|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|$GEM5_CONFIG_RUBY_4CORE")

      # Add mem PGO job
      SPLASH_4CORE_JOB_QUEUE+=("$bench|$simpoint|mem|$iter|$MEM_PGO_BINARY|$spec_binary|$args|$mem|$checkpoint_path|$stdin_file|minor|$GEM5_CONFIG_RUBY_4CORE")
    done
  done

  num_splash_4core_benchmarks=${#SPLASH_4CORE_BENCHMARKS[@]}
  # baseline + 2 PGO variants (self-profiling, mem)
  pgo_variants_per_benchmark=2
  splash_4core_expected_jobs=$((num_splash_4core_benchmarks * (pgo_variants_per_benchmark + 1) * NUM_ITERATIONS))
  splash_4core_total_jobs=${#SPLASH_4CORE_JOB_QUEUE[@]}

  echo ""
  echo "Splash 4-core job statistics:"
  echo "  Splash 4-core benchmarks: $num_splash_4core_benchmarks"
  for bench in "${SPLASH_4CORE_BENCHMARKS[@]}"; do
    echo "    - $bench"
  done
  echo "  PGO variants per benchmark: $pgo_variants_per_benchmark"
  echo "    - Self-profiling: 1"
  echo "    - Mem PGO: 1"
  echo "  Iterations: $NUM_ITERATIONS"
  echo "  Expected jobs: $splash_4core_expected_jobs"
  echo "  Actual jobs in queue: $splash_4core_total_jobs"

  # Run Splash 4-core jobs in parallel
  run_jobs_in_parallel SPLASH_4CORE_JOB_QUEUE "$SPLASH_4CORE_CSV_FILE" "pgo" "$splash_4core_total_jobs"

  echo ""
  echo "========================================================================"
  echo "Splash 4-Core Eval-PGO Simulations Completed"
  echo "========================================================================"
  echo "Results saved to: $SPLASH_4CORE_CSV_FILE"

  # Print summary
  splash_4core_total_results=$(grep -cv "^simulated_benchmark," "$SPLASH_4CORE_CSV_FILE" 2>/dev/null || echo 0)
  echo "Total Splash 4-core results recorded: $splash_4core_total_results / $splash_4core_expected_jobs"
  echo "========================================================================"
fi
