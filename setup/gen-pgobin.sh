#!/bin/bash

## This script automates the PGO process for gem5 across all benchmarks:
## 1. Build instrumented gem5 binaries for each benchmark/simpoint
## 2. Run instrumented binaries to collect profile data
## 3. Merge profile data using llvm-profdata
## 4. Build PGO-optimized gem5 binaries
## 5. Save PGO binaries to pgo_bins/{bench}/ and clean up build files
##
## The script tracks errors at each step and continues processing even if errors occur.
## A final report is generated showing which steps succeeded/failed for each benchmark.

## MAKE SURE GEM5 Dir and SPEC BUILT DIR are set
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Allow the caller to source init.sh once and reuse that context.
if ! declare -p BENCH_INFO >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/init.sh"
fi

if [ -z "$REPO_DIR" ]; then
  echo "REPO_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

if [ -z "$SPEC_BUILT_DIR" ]; then
  echo "SPEC_BUILT_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

# Configuration
RUN_LABEL=${RUN_LABEL:-gem5_profile_x86-m64}
GEM5_CONFIG=${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}
GEM5_CONFIG_RUBY_4CORE=${GEM5_CONFIG_RUBY_4CORE:-$REPO_DIR/gem5_config/run-ruby-4core.py}
GEM5_DIR=$REPO_DIR/gem5
PROFILE_DIR=$REPO_DIR/profiles
PGO_BINS_DIR=$REPO_DIR/pgo_bins
CHECKPOINT_BASE_DIR=${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}
OPT_REMARKS_ARCHIVE_DIR=${OPT_REMARKS_ARCHIVE_DIR:-$REPO_DIR/opt_remarks}
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
PGO_RUNDIR_DIR="${PGO_RUNDIR_DIR:-$RESULTS_RUNDIR_DIR/pgo-setup}"

# Number of parallel build jobs
PARALLEL_BUILD_JOBS=3

# Toggle: Enable building all 4 PGO variants (pgo, pgo-icp, pgo-hc, pgo-inline)
# Set to "true" to build all variants, "false" to build only basic pgo
ENABLE_OPT_BREAKDOWN=false

# Toggle: Enable building MiBench PGO binaries
# Set to "true" to build MiBench PGO, "false" to skip
BUILD_MIBENCH_PGO=${BUILD_MIBENCH_PGO:-false}

# Toggle: Enable building Splash PGO binaries (1-core)
# Set to "true" to build Splash PGO, "false" to skip
BUILD_SPLASH_PGO=${BUILD_SPLASH_PGO:-false}

# Toggle: Enable building Splash 4-core PGO binaries
# Set to "true" to build Splash 4-core PGO, "false" to skip
BUILD_SPLASH_4CORE_PGO=${BUILD_SPLASH_4CORE_PGO:-false}

# Maximum number of simpoints to use per benchmark
# Set to empty or 0 to use all available simpoints
MAX_SIMPOINTS=0

# Maximum number of concurrently running gem5.inst profiling jobs (SPEC path)
PARALLEL_RUN=${PARALLEL_RUN:-10}

# Maximum number of parallel MiBench runs during profiling
MAX_MIBENCH_PARALLEL=16

if ! declare -p BENCH_INFO >/dev/null 2>&1; then
  echo "ERROR: Shared BENCH_INFO is not loaded."
  echo "Please source setup/init.sh first, or run this script directly."
  exit 1
fi

if ! declare -p SPEC_BENCHMARKS_ALL >/dev/null 2>&1 ||
   ! declare -p MIBENCH_BENCHMARKS_ALL >/dev/null 2>&1 ||
   ! declare -p SPLASH_BENCHMARKS_ALL >/dev/null 2>&1 ||
   ! declare -p SPLASH_4CORE_BENCHMARKS_ALL >/dev/null 2>&1; then
  echo "ERROR: Shared benchmark lists are not loaded. Please source setup/init.sh"
  exit 1
fi

# Create necessary directories
mkdir -p "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR/build_logs"
mkdir -p "$PROFILE_DIR/merge_logs"
mkdir -p "$PGO_BINS_DIR"
mkdir -p "$PGO_RUNDIR_DIR"

# Global error tracking arrays
declare -A ERROR_LOG
declare -A STEP_STATUS
declare -A BENCHMARK_SIMPOINTS

# SPEC benchmark list for PGO generation (aligned with run_fig347.sh)
declare -a benchmarks=(
    # "600.perlbench_s.0"
    # "602.gcc_s.0"
    # "605.mcf_s"
    # "620.omnetpp_s"
    # "623.xalancbmk_s"
    # "625.x264_s.0"
    # "631.deepsjeng_s"
    # "641.leela_s"
    # "648.exchange2_s"
    "657.xz_s.0"
)

# Other benchmark lists are loaded from setup/init.sh
declare -a mibench_benchmarks=("${MIBENCH_BENCHMARKS_ALL[@]}")
declare -a splash_benchmarks=("${SPLASH_BENCHMARKS_ALL[@]}")
declare -a splash_4core_benchmarks=("${SPLASH_4CORE_BENCHMARKS_ALL[@]}")

# Function to log errors
log_error() {
    local bench=$1
    local simpoint=$2
    local step=$3
    local message=$4

    local key="${bench}|${simpoint}|${step}"
    ERROR_LOG["$key"]="$message"
    echo "[ERROR] $bench simpoint $simpoint - $step: $message"
}

# Function to mark step status
mark_step_status() {
    local bench=$1
    local simpoint=$2
    local step=$3
    local status=$4  # "SUCCESS" or "FAILED"

    local key="${bench}|${simpoint}|${step}"
    STEP_STATUS["$key"]="$status"
}

# Function to build instrumented binaries for a benchmark
build_inst_binaries() {
    local bench=$1
    local num_simpoints=$2

    echo "=========================================="
    echo "Building INSTRUMENTED binaries for $bench ($num_simpoints simpoints)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    # Set GEM5_BUILD_ROOTS environment variable for all simpoints
    export GEM5_BUILD_ROOTS=$(seq 1 $num_simpoints | sed "s/^/build-${bench}-/" | paste -sd,)
    # echo "Set GEM5_BUILD_ROOTS=$GEM5_BUILD_ROOTS"

    # Track build PIDs
    declare -A build_pids

    for i in $(seq 1 $num_simpoints); do
        # Skip build if binary already exists
        if [ -f "$GEM5_DIR/build-${bench}-${i}/X86/gem5.inst" ]; then
            echo "Instrumented binary for simpoint $i already exists, skipping build..."
            mark_step_status "$bench" "$i" "BUILD_INST" "SUCCESS"
            continue
        fi

        scons build-${bench}-${i}/X86/gem5.inst -j25 > "$PROFILE_DIR/build_logs/build-inst-${bench}-${i}.log" 2>&1 &
        build_pids[$i]=$!
        sleep 2
        (( i % PARALLEL_BUILD_JOBS == 0 )) && wait
    done
    wait

    # Check if builds succeeded
    for i in $(seq 1 $num_simpoints); do
        if [ -f "$GEM5_DIR/build-${bench}-${i}/X86/gem5.inst" ]; then
            mark_step_status "$bench" "$i" "BUILD_INST" "SUCCESS"
        else
            mark_step_status "$bench" "$i" "BUILD_INST" "FAILED"
            log_error "$bench" "$i" "BUILD_INST" "Binary not created. Check $PROFILE_DIR/build_logs/build-inst-${bench}-${i}.log"
        fi
    done

    echo "Instrumented binary build phase completed for $bench"
}

# Function to run instrumented binaries
run_inst_binaries() {
    local bench=$1
    local binary=$2
    local args=$3
    local mem=$4
    local checkpoint_dir=$5
    local max_parallel_run=$PARALLEL_RUN

    echo "=========================================="
    echo "Running INSTRUMENTED binaries for $bench"
    echo "=========================================="

    cd "$REPO_DIR" || exit 1

    # Arrays to store PIDs and simpoint indices
    declare -A job_pids
    declare -A pid_to_simpoint

    if ! [[ "$max_parallel_run" =~ ^[0-9]+$ ]] || [ "$max_parallel_run" -lt 1 ]; then
        echo "WARNING: Invalid PARALLEL_RUN=$PARALLEL_RUN. Falling back to unlimited concurrency."
        max_parallel_run=0
    fi

    if [ "$max_parallel_run" -gt 0 ]; then
        echo "Max concurrent gem5.inst runs: $max_parallel_run"
    else
        echo "Max concurrent gem5.inst runs: unlimited"
    fi

    # Loop over all checkpoints
    for dir_item in "$checkpoint_dir"/*; do
        if [ -d "$dir_item" ]; then
            smpt_idx=$(basename "$dir_item")
            gem5_cmd="$GEM5_DIR/build-${bench}-${smpt_idx}/X86/gem5.inst"

            if [ ! -f "$gem5_cmd" ]; then
                log_error "$bench" "$smpt_idx" "RUN_INST" "gem5.inst binary not found"
                mark_step_status "$bench" "$smpt_idx" "RUN_INST" "FAILED"
                continue
            fi

            echo "Launching instrumented run for simpoint $smpt_idx..."

            if [ "$max_parallel_run" -gt 0 ]; then
                local running_jobs
                local running_pid
                while true; do
                    running_jobs=0
                    for running_pid in "${job_pids[@]}"; do
                        if ps -p "$running_pid" > /dev/null 2>&1; then
                            ((running_jobs++))
                        fi
                    done

                    if [ "$running_jobs" -lt "$max_parallel_run" ]; then
                        break
                    fi
                    sleep 2
                done
            fi

            LLVM_PROFILE_FILE="$PROFILE_DIR/${bench}-${smpt_idx}.profraw" "$gem5_cmd" -r --outdir="$PGO_RUNDIR_DIR/${bench}-inst-${smpt_idx}" "$GEM5_CONFIG" \
                --binary "$binary" --args="$args" \
                --restore-from "$dir_item" \
                --cpu-type o3 --mem-size "$mem" &

            pid=$!
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ps -p "$pid" > /dev/null; then
                job_pids[$smpt_idx]=$pid
                pid_to_simpoint[$pid]=$smpt_idx
                echo "  Launched PID: $pid for simpoint $smpt_idx"
            else
                log_error "$bench" "$smpt_idx" "RUN_INST" "Failed to launch process"
                mark_step_status "$bench" "$smpt_idx" "RUN_INST" "FAILED"
            fi
        fi
    done

    # Wait for all jobs to complete and track their exit status
    echo "Waiting for all instrumented runs to complete..."
    local num_jobs=${#job_pids[@]}
    local completed=0
    declare -A job_done

    while [ "$completed" -lt "$num_jobs" ]; do
        sleep 30
        for smpt_idx in "${!job_pids[@]}"; do
            pid=${job_pids[$smpt_idx]}

            # Skip if already marked as done
            if [ "${job_done[$smpt_idx]}" == "1" ]; then
                continue
            fi

            if ! ps -p "$pid" > /dev/null 2>&1; then
                # Job finished, check exit status
                wait "$pid"
                exit_status=$?
                job_done[$smpt_idx]=1
                ((completed++))

                if [ $exit_status -eq 0 ] && [ -f "$PROFILE_DIR/${bench}-${smpt_idx}.profraw" ]; then
                    mark_step_status "$bench" "$smpt_idx" "RUN_INST" "SUCCESS"
                    echo "  Simpoint $smpt_idx completed successfully"
                else
                    mark_step_status "$bench" "$smpt_idx" "RUN_INST" "FAILED"
                    log_error "$bench" "$smpt_idx" "RUN_INST" "Exit status: $exit_status."
                fi
            fi
        done
        echo "Progress: $completed / $num_jobs jobs completed"
    done

    echo "All instrumented runs finished for $bench"
}

# Function to merge profiles
merge_profiles() {
    local bench=$1
    local num_simpoints=$2

    echo "=========================================="
    echo "Merging profiles for $bench ($num_simpoints simpoints)"
    echo "=========================================="

    for i in $(seq 1 $num_simpoints); do
        if [ -f "$PROFILE_DIR/${bench}-${i}.profraw" ]; then
            echo "Merging profile for simpoint $i..."
            if llvm-profdata merge -output="$PROFILE_DIR/${bench}-${i}.profdata" "$PROFILE_DIR/${bench}-${i}.profraw" > "$PROFILE_DIR/merge_logs/merge-${bench}-${i}.log" 2>&1; then
                mark_step_status "$bench" "$i" "MERGE_PROFILE" "SUCCESS"
            else
                mark_step_status "$bench" "$i" "MERGE_PROFILE" "FAILED"
                log_error "$bench" "$i" "MERGE_PROFILE" "llvm-profdata merge failed. Check $PROFILE_DIR/merge_logs/merge-${bench}-${i}.log"
            fi
        else
            log_error "$bench" "$i" "MERGE_PROFILE" "Profile file ${bench}-${i}.profraw not found (likely failed in previous step)"
            mark_step_status "$bench" "$i" "MERGE_PROFILE" "SKIPPED"
        fi
    done

    echo "Profile merging completed for $bench"
}

# Function to build PGO binaries
build_pgo_binaries() {
    local bench=$1
    local num_simpoints=$2

    echo "=========================================="
    echo "Building PGO binaries for $bench ($num_simpoints simpoints)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    # Determine which PGO variants to build
    local pgo_variants=("pgo")
    if [ "$ENABLE_OPT_BREAKDOWN" = true ]; then
        pgo_variants=("pgo" "pgo-icp" "pgo-hc" "pgo-inline")
        echo "Building all 4 PGO variants: ${pgo_variants[@]}"
    else
        echo "Building basic PGO variant only"
    fi

    # Build GEM5_BUILD_ROOTS string once - include all variant build dirs for all simpoints
    local build_roots=""
    for v in "${pgo_variants[@]}"; do
        for j in $(seq 1 $num_simpoints); do
            if [ -n "$build_roots" ]; then
                build_roots="${build_roots},build-${bench}-${j}-${v}"
            else
                build_roots="build-${bench}-${j}-${v}"
            fi
        done
    done
    export GEM5_BUILD_ROOTS="$build_roots"
    echo "Set GEM5_BUILD_ROOTS=$GEM5_BUILD_ROOTS"

    local job_count=0

    for i in $(seq 1 $num_simpoints); do
        for variant in "${pgo_variants[@]}"; do
            # Each variant gets its own build directory
            local build_dir="build-${bench}-${i}-${variant}"

            # Skip build if valid binary already exists (size > 1MB)
            dest_binary="$PGO_BINS_DIR/$bench/gem5-${i}.${variant}"
            if [ -f "$dest_binary" ]; then
                file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
                if [ "$file_size" -gt 1048576 ]; then
                    echo "PGO binary (${variant}) for simpoint $i already exists (${file_size} bytes), skipping build..."
                    mark_step_status "$bench" "$i" "BUILD_PGO_${variant}" "SUCCESS"
                    continue
                else
                    echo "WARNING: Found invalid binary at $dest_binary (${file_size} bytes), will rebuild..."
                    rm -f "$dest_binary"
                fi
            fi

            scons ${build_dir}/X86/gem5.${variant} -j25 > "$PROFILE_DIR/build_logs/build-${variant}-${bench}-${i}.log" 2>&1 &
            sleep 2
            ((job_count++))
            (( job_count % PARALLEL_BUILD_JOBS == 0 )) && wait
        done
    done
    wait

    # Check if builds succeeded (skip already marked builds)
    for i in $(seq 1 $num_simpoints); do
        for variant in "${pgo_variants[@]}"; do
            local key="${bench}|${i}|BUILD_PGO_${variant}"
            # Skip if already marked as SUCCESS (e.g., binary already existed in pgo_bins)
            if [ "${STEP_STATUS[$key]}" = "SUCCESS" ]; then
                continue
            fi

            local build_dir="build-${bench}-${i}-${variant}"
            if [ -f "$GEM5_DIR/${build_dir}/X86/gem5.${variant}" ]; then
                mark_step_status "$bench" "$i" "BUILD_PGO_${variant}" "SUCCESS"
            else
                mark_step_status "$bench" "$i" "BUILD_PGO_${variant}" "FAILED"
                log_error "$bench" "$i" "BUILD_PGO_${variant}" "Binary not created. Check $PROFILE_DIR/build_logs/build-${variant}-${bench}-${i}.log"
            fi
        done
    done

    echo "PGO binary build phase completed for $bench"
}

# Function to save PGO binaries and clean up
save_and_cleanup() {
    local bench=$1
    local num_simpoints=$2

    echo "=========================================="
    echo "Saving PGO binaries and cleaning up for $bench"
    echo "=========================================="

    # Create directory for this benchmark's PGO binaries
    mkdir -p "$PGO_BINS_DIR/$bench"

    cd "$GEM5_DIR" || exit 1

    # Determine which PGO variants were built
    local pgo_variants=("pgo")
    if [ "$ENABLE_OPT_BREAKDOWN" = true ]; then
        pgo_variants=("pgo" "pgo-icp" "pgo-hc" "pgo-inline")
    fi

    # Copy PGO binaries and optimization remarks to pgo_bins directory
    for i in $(seq 1 $num_simpoints); do
        local simpoint_has_success=false

        for variant in "${pgo_variants[@]}"; do
            local build_dir="build-${bench}-${i}-${variant}"
            pgo_binary="${build_dir}/X86/gem5.${variant}"
            dest_binary="$PGO_BINS_DIR/$bench/gem5-${i}.${variant}"

            if [ -f "$pgo_binary" ]; then
                # Verify source binary is valid (size > 1MB)
                src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
                if [ "$src_size" -le 1048576 ]; then
                    log_error "$bench" "$i" "SAVE_PGO_${variant}" "Source binary too small (${src_size} bytes)"
                    mark_step_status "$bench" "$i" "SAVE_PGO_${variant}" "FAILED"
                    continue
                fi

                # Copy and verify
                if cp "$pgo_binary" "$dest_binary"; then
                    # Verify copied binary
                    dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
                    if [ "$dest_size" -eq "$src_size" ]; then
                        mark_step_status "$bench" "$i" "SAVE_PGO_${variant}" "SUCCESS"
                        echo "Saved: $pgo_binary -> $dest_binary (${dest_size} bytes)"
                        simpoint_has_success=true
                    else
                        log_error "$bench" "$i" "SAVE_PGO_${variant}" "Copy size mismatch: src=${src_size} dest=${dest_size}"
                        mark_step_status "$bench" "$i" "SAVE_PGO_${variant}" "FAILED"
                        rm -f "$dest_binary"  # Remove corrupted file
                    fi
                else
                    log_error "$bench" "$i" "SAVE_PGO_${variant}" "Failed to copy binary"
                    mark_step_status "$bench" "$i" "SAVE_PGO_${variant}" "FAILED"
                fi
            else
                log_error "$bench" "$i" "SAVE_PGO_${variant}" "PGO binary (${variant}) not found"
                mark_step_status "$bench" "$i" "SAVE_PGO_${variant}" "FAILED"
            fi

            # Copy optimization remark files only for pgo variant
            if [ "$variant" = "pgo" ]; then
                # Create temporary directory for this simpoint
                opt_temp_dir="$PGO_BINS_DIR/$bench/opt-${i}-${variant}-temp"
                mkdir -p "$opt_temp_dir"

                # Find and copy all .opt.yaml files from the build directory
                if find "${build_dir}" -name "*.opt.yaml" -type f | grep -q .; then
                    echo "Processing optimization remarks for simpoint $i, variant ${variant}..."
                    find "${build_dir}" -name "*.opt.yaml" -type f -exec cp {} "$opt_temp_dir/" \;
                    num_files=$(find "$opt_temp_dir" -name "*.opt.yaml" -type f | wc -l)
                    echo "  Collected $num_files optimization remark files"

                    # Compress with pigz (parallel)
                    if ! cd "$PGO_BINS_DIR/$bench"; then
                        echo "  Error: Failed to cd to $PGO_BINS_DIR/$bench, skipping opt.yaml processing for simpoint $i"
                        rm -rf "$opt_temp_dir"
                        continue
                    fi
                    tar_name="opt-${i}-${variant}.tar.gz"

                    echo "  Compressing with pigz (parallel)..."
                    if ! tar -I pigz -cf "$tar_name" -C "$opt_temp_dir" .; then
                        echo "  Error: Failed to compress optimization remarks for simpoint $i"
                        rm -rf "$opt_temp_dir"
                        cd "$GEM5_DIR"
                        continue
                    fi

                    # Create destination directory on NAS
                    nas_dest="$OPT_REMARKS_ARCHIVE_DIR/$bench"
                    mkdir -p "$nas_dest"

                    # Transfer to NAS using rsync
                    echo "  Transferring to NAS..."
                    if ! rsync -avh --no-owner --no-group --progress "$tar_name" "$nas_dest/"; then
                        echo "  Error: Failed to transfer to NAS for simpoint $i"
                        rm -rf "$opt_temp_dir"
                        rm -f "$tar_name"
                        cd "$GEM5_DIR"
                        continue
                    fi

                    # Extract on NAS with pigz (parallel)
                    echo "  Extracting on NAS with pigz (parallel)..."
                    nas_extract_dir="$nas_dest/opt-${i}-${variant}"
                    mkdir -p "$nas_extract_dir"
                    if ! tar -I pigz -xf "$nas_dest/$tar_name" -C "$nas_extract_dir"; then
                        echo "  Error: Failed to extract on NAS for simpoint $i"
                        rm -f "$nas_dest/$tar_name"
                        rm -rf "$opt_temp_dir"
                        rm -f "$tar_name"
                        cd "$GEM5_DIR"
                        continue
                    fi

                    # Clean up: remove compressed file from NAS and local temp files
                    echo "  Cleaning up..."
                    rm -f "$nas_dest/$tar_name"
                    rm -rf "$opt_temp_dir"
                    rm -f "$tar_name"
                    cd "$GEM5_DIR"

                    echo "  Successfully saved $num_files optimization remark files to $nas_extract_dir"
                else
                    echo "  Warning: No optimization remark files found in ${build_dir}"
                    rm -rf "$opt_temp_dir"
                fi
            fi
        done

        # Mark overall SAVE_PGO status
        if [ "$simpoint_has_success" = true ]; then
            mark_step_status "$bench" "$i" "SAVE_PGO" "SUCCESS"
        else
            mark_step_status "$bench" "$i" "SAVE_PGO" "FAILED"
        fi
    done

    # Remove build directories for this benchmark
    # Includes both instrumented build dirs (build-${bench}-${i})
    # and PGO variant build dirs (build-${bench}-${i}-<variant>)
    echo "Cleaning up build directories..."
    for i in $(seq 1 $num_simpoints); do
        inst_build_dir="build-${bench}-${i}"
        if [ -d "$inst_build_dir" ]; then
            echo "Removing $inst_build_dir..."
            rm -rf "$inst_build_dir"
        fi

        for variant in "${pgo_variants[@]}"; do
            build_dir="build-${bench}-${i}-${variant}"
            if [ -d "$build_dir" ]; then
                echo "Removing $build_dir..."
                rm -rf "$build_dir"
            fi
        done
    done

    echo "Cleanup completed for $bench"
}

################################################################################
# MIBENCH PGO FUNCTIONS - FULLY PARALLEL
################################################################################

# Function to process a single MiBench benchmark (full pipeline)
# This runs: inst build -> profile run -> merge -> PGO build -> save
process_mibench_benchmark() {
    local bench=$1
    local binary=$2
    local args=$3
    local mem=$4

    echo "=========================================="
    echo "Processing MiBench $bench (full pipeline)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    local inst_build_dir="build-mibench-${bench}-inst"
    local pgo_build_dir="build-mibench-${bench}-pgo"
    local gem5_inst="$GEM5_DIR/${inst_build_dir}/X86/gem5.inst"
    local pgo_binary="$GEM5_DIR/${pgo_build_dir}/X86/gem5.pgo"
    local dest_dir="$PGO_BINS_DIR/mibench/$bench"
    local dest_binary="$dest_dir/gem5.pgo"

    # Check if final PGO binary already exists
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            echo "[$bench] PGO binary already exists (${file_size} bytes), skipping entire pipeline"
            return 0
        else
            echo "[$bench] Found invalid binary (${file_size} bytes), will rebuild"
            rm -f "$dest_binary"
        fi
    fi

    # Build GEM5_BUILD_ROOTS for both inst and pgo builds
    export GEM5_BUILD_ROOTS="${inst_build_dir},${pgo_build_dir}"

    # Step 1: Build instrumented binary
    if [ ! -f "$gem5_inst" ]; then
        echo "[$bench] Building instrumented binary..."
        if ! scons ${inst_build_dir}/X86/gem5.inst -j7 > "$PROFILE_DIR/build_logs/build-inst-mibench-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-mibench-${bench}.log"
            return 1
        fi
        echo "[$bench] Instrumented binary built successfully"
    else
        echo "[$bench] Instrumented binary already exists, skipping build"
    fi

    # Step 2: Run instrumented binary to collect profile
    cd "$REPO_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/mibench-${bench}.profraw" ]; then
        echo "[$bench] Running instrumented binary to collect profile..."
        if ! LLVM_PROFILE_FILE="$PROFILE_DIR/mibench-${bench}.profraw" "$gem5_inst" -r \
            --outdir="$PGO_RUNDIR_DIR/mibench-inst-${bench}" "$GEM5_CONFIG" \
            --binary "$binary" --args="$args" \
            --cpu-type o3 --mem-size "$mem" ; then
            echo "[$bench] ERROR: Profile run failed. Check $PGO_RUNDIR_DIR/mibench-inst-${bench}/simout.txt"
            return 1
        fi
        echo "[$bench] Profile collected successfully"
    else
        echo "[$bench] Profile already exists, skipping run"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/mibench-${bench}.profdata" ]; then
        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="$PROFILE_DIR/mibench-${bench}.profdata" "$PROFILE_DIR/mibench-${bench}.profraw" > "$PROFILE_DIR/merge_logs/merge-mibench-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Profile merge failed. Check $PROFILE_DIR/merge_logs/merge-mibench-${bench}.log"
            return 1
        fi
        echo "[$bench] Profile merged successfully"
    else
        echo "[$bench] Profdata already exists, skipping merge"
    fi

    # Step 4: Build PGO binary
    if [ ! -f "$pgo_binary" ]; then
        echo "[$bench] Building PGO binary..."
        if ! scons ${pgo_build_dir}/X86/gem5.pgo -j7 > "$PROFILE_DIR/build_logs/build-pgo-mibench-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: PGO build failed. Check $PROFILE_DIR/build_logs/build-pgo-mibench-${bench}.log"
            return 1
        fi
        echo "[$bench] PGO binary built successfully"
    else
        echo "[$bench] PGO binary already exists in build directory, skipping build"
    fi

    # Step 5: Save PGO binary
    mkdir -p "$dest_dir"
    if [ -f "$pgo_binary" ]; then
        src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
        if [ "$src_size" -le 1048576 ]; then
            echo "[$bench] ERROR: PGO binary too small (${src_size} bytes)"
            return 1
        fi

        if cp "$pgo_binary" "$dest_binary"; then
            dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
            if [ "$dest_size" -eq "$src_size" ]; then
                echo "[$bench] ✓ Saved PGO binary: $dest_binary (${dest_size} bytes)"
                return 0
            else
                echo "[$bench] ERROR: Copy size mismatch: src=${src_size} dest=${dest_size}"
                rm -f "$dest_binary"
                return 1
            fi
        else
            echo "[$bench] ERROR: Failed to copy PGO binary"
            return 1
        fi
    else
        echo "[$bench] ERROR: PGO binary not found at $pgo_binary"
        return 1
    fi
}

# Function to process all MiBench benchmarks in parallel
process_all_mibench_benchmarks() {
    echo "=========================================="
    echo "Processing all MiBench benchmarks in parallel (${#mibench_benchmarks[@]} benchmarks)"
    echo "=========================================="

    # Launch all benchmarks in parallel
    declare -A bench_pids
    declare -A pid_to_bench

    for bench in "${mibench_benchmarks[@]}"; do
        if [ -z "${BENCH_INFO[$bench]+_}" ]; then
            echo "[WARN] Missing BENCH_INFO entry for MiBench benchmark: $bench (skipping)"
            continue
        fi
        IFS='|' read -r binary args mem <<< "${BENCH_INFO[$bench]}"

        echo "Launching pipeline for MiBench $bench..."
        process_mibench_benchmark "$bench" "$binary" "$args" "$mem" > "$PROFILE_DIR/build_logs/pipeline-mibench-${bench}.log" 2>&1 &

        pid=$!
        bench_pids[$pid]=1
        pid_to_bench[$pid]=$bench
        echo "  Launched PID $pid for $bench"
    done

    # Wait for all benchmarks to complete
    echo ""
    echo "Waiting for all MiBench pipelines to complete..."
    echo "You can monitor progress in: $PROFILE_DIR/build_logs/pipeline-mibench-*.log"

    local success_count=0
    local fail_count=0

    for pid in "${!bench_pids[@]}"; do
        local bench_name="${pid_to_bench[$pid]}"
        wait "$pid"
        exit_status=$?

        if [ $exit_status -eq 0 ]; then
            echo "  ✓ MiBench $bench_name pipeline completed successfully"
            ((success_count++))
        else
            echo "  ✗ MiBench $bench_name pipeline FAILED (exit: $exit_status)"
            ((fail_count++))
        fi
    done

    echo ""
    echo "=========================================="
    echo "MiBench processing summary:"
    echo "  Success: $success_count"
    echo "  Failed: $fail_count"
    echo "  Total: ${#mibench_benchmarks[@]}"
    echo "=========================================="

    if [ $fail_count -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Function to cleanup MiBench build directories
cleanup_mibench_builds() {
    echo "=========================================="
    echo "Cleaning up MiBench build directories"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    for bench in "${mibench_benchmarks[@]}"; do
        local inst_build_dir="build-mibench-${bench}-inst"
        if [ -d "$inst_build_dir" ]; then
            echo "Removing $inst_build_dir..."
            rm -rf "$inst_build_dir"
        fi

        local pgo_build_dir="build-mibench-${bench}-pgo"
        if [ -d "$pgo_build_dir" ]; then
            echo "Removing $pgo_build_dir..."
            rm -rf "$pgo_build_dir"
        fi
    done

    echo "Cleanup completed for MiBench"
}

################################################################################
# SPLASH PGO FUNCTIONS - FULLY PARALLEL
################################################################################

# Function to process a single Splash benchmark (full pipeline)
# This runs: inst build -> profile run -> merge -> PGO build -> save
process_splash_benchmark() {
    local bench=$1
    local binary=$2
    local args=$3
    local stdin_file=$4
    local mem=$5

    echo "=========================================="
    echo "Processing Splash $bench (full pipeline)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    local inst_build_dir="build-splash-${bench}-inst"
    local pgo_build_dir="build-splash-${bench}-pgo"
    local gem5_inst="$GEM5_DIR/${inst_build_dir}/X86/gem5.inst"
    local pgo_binary="$GEM5_DIR/${pgo_build_dir}/X86/gem5.pgo"
    local dest_dir="$PGO_BINS_DIR/splash/$bench"
    local dest_binary="$dest_dir/gem5.pgo"

    # Check if final PGO binary already exists
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            echo "[$bench] PGO binary already exists (${file_size} bytes), skipping entire pipeline"
            return 0
        else
            echo "[$bench] Found invalid binary (${file_size} bytes), will rebuild"
            rm -f "$dest_binary"
        fi
    fi

    # Build GEM5_BUILD_ROOTS for both inst and pgo builds
    export GEM5_BUILD_ROOTS="${inst_build_dir},${pgo_build_dir}"

    # Step 1: Build instrumented binary
    if [ ! -f "$gem5_inst" ]; then
        echo "[$bench] Building instrumented binary..."
        if ! scons ${inst_build_dir}/X86/gem5.inst -j7 > "$PROFILE_DIR/build_logs/build-inst-splash-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-splash-${bench}.log"
            return 1
        fi
        echo "[$bench] Instrumented binary built successfully"
    else
        echo "[$bench] Instrumented binary already exists, skipping build"
    fi

    # Step 2: Run instrumented binary to collect profile
    cd "$REPO_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/splash-${bench}.profraw" ]; then
        echo "[$bench] Running instrumented binary to collect profile..."

        # Build gem5 command with stdin if provided
        local gem5_cmd="LLVM_PROFILE_FILE=\"$PROFILE_DIR/splash-${bench}.profraw\" \"$gem5_inst\" -r --outdir=\"$PGO_RUNDIR_DIR/splash-inst-${bench}\" \"$GEM5_CONFIG\" --binary \"$binary\" --args=\"$args\" --cpu-type minor --mem-size \"$mem\""

        if [ -n "$stdin_file" ]; then
            gem5_cmd="$gem5_cmd --stdin \"$stdin_file\""
        fi

        if ! eval $gem5_cmd; then
            echo "[$bench] ERROR: Profile run failed. Check $PGO_RUNDIR_DIR/splash-inst-${bench}/soimout.txt"
            return 1
        fi
        echo "[$bench] Profile collected successfully"
    else
        echo "[$bench] Profile already exists, skipping run"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/splash-${bench}.profdata" ]; then
        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="$PROFILE_DIR/splash-${bench}.profdata" "$PROFILE_DIR/splash-${bench}.profraw" > "$PROFILE_DIR/merge_logs/merge-splash-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Profile merge failed. Check $PROFILE_DIR/merge_logs/merge-splash-${bench}.log"
            return 1
        fi
        echo "[$bench] Profile merged successfully"
    else
        echo "[$bench] Profdata already exists, skipping merge"
    fi

    # Step 4: Build PGO binary
    if [ ! -f "$pgo_binary" ]; then
        echo "[$bench] Building PGO binary..."
        if ! scons ${pgo_build_dir}/X86/gem5.pgo -j7 > "$PROFILE_DIR/build_logs/build-pgo-splash-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: PGO build failed. Check $PROFILE_DIR/build_logs/build-pgo-splash-${bench}.log"
            return 1
        fi
        echo "[$bench] PGO binary built successfully"
    else
        echo "[$bench] PGO binary already exists in build directory, skipping build"
    fi

    # Step 5: Save PGO binary
    mkdir -p "$dest_dir"
    if [ -f "$pgo_binary" ]; then
        src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
        if [ "$src_size" -le 1048576 ]; then
            echo "[$bench] ERROR: PGO binary too small (${src_size} bytes)"
            return 1
        fi

        if cp "$pgo_binary" "$dest_binary"; then
            dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
            if [ "$dest_size" -eq "$src_size" ]; then
                echo "[$bench] ✓ Saved PGO binary: $dest_binary (${dest_size} bytes)"
                return 0
            else
                echo "[$bench] ERROR: Copy size mismatch: src=${src_size} dest=${dest_size}"
                rm -f "$dest_binary"
                return 1
            fi
        else
            echo "[$bench] ERROR: Failed to copy PGO binary"
            return 1
        fi
    else
        echo "[$bench] ERROR: PGO binary not found at $pgo_binary"
        return 1
    fi
}

# Function to process all Splash benchmarks in parallel
process_all_splash_benchmarks() {
    echo "=========================================="
    echo "Processing all Splash benchmarks in parallel (${#splash_benchmarks[@]} benchmarks)"
    echo "=========================================="

    # Launch all benchmarks in parallel
    declare -A bench_pids
    declare -A pid_to_bench

    for bench in "${splash_benchmarks[@]}"; do
        if [ -z "${BENCH_INFO[$bench]+_}" ]; then
            echo "[WARN] Missing BENCH_INFO entry for Splash benchmark: $bench (skipping)"
            continue
        fi
        IFS='|' read -r binary args stdin_file mem <<< "${BENCH_INFO[$bench]}"

        echo "Launching pipeline for Splash $bench..."
        process_splash_benchmark "$bench" "$binary" "$args" "$stdin_file" "$mem" > "$PROFILE_DIR/build_logs/pipeline-splash-${bench}.log" 2>&1 &

        pid=$!
        bench_pids[$pid]=1
        pid_to_bench[$pid]=$bench
        echo "  Launched PID $pid for $bench"
    done

    # Wait for all benchmarks to complete
    echo ""
    echo "Waiting for all Splash pipelines to complete..."
    echo "You can monitor progress in: $PROFILE_DIR/build_logs/pipeline-splash-*.log"

    local success_count=0
    local fail_count=0

    for pid in "${!bench_pids[@]}"; do
        local bench_name="${pid_to_bench[$pid]}"
        wait "$pid"
        exit_status=$?

        if [ $exit_status -eq 0 ]; then
            echo "  ✓ Splash $bench_name pipeline completed successfully"
            ((success_count++))
        else
            echo "  ✗ Splash $bench_name pipeline FAILED (exit: $exit_status)"
            ((fail_count++))
        fi
    done

    echo ""
    echo "=========================================="
    echo "Splash processing summary:"
    echo "  Success: $success_count"
    echo "  Failed: $fail_count"
    echo "  Total: ${#splash_benchmarks[@]}"
    echo "=========================================="

    if [ $fail_count -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Function to cleanup Splash build directories
cleanup_splash_builds() {
    echo "=========================================="
    echo "Cleaning up Splash build directories"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    for bench in "${splash_benchmarks[@]}"; do
        local inst_build_dir="build-splash-${bench}-inst"
        if [ -d "$inst_build_dir" ]; then
            echo "Removing $inst_build_dir..."
            rm -rf "$inst_build_dir"
        fi

        local pgo_build_dir="build-splash-${bench}-pgo"
        if [ -d "$pgo_build_dir" ]; then
            echo "Removing $pgo_build_dir..."
            rm -rf "$pgo_build_dir"
        fi
    done

    echo "Cleanup completed for Splash"
}

################################################################################
# SPLASH 4-CORE PGO FUNCTIONS - FULLY PARALLEL
################################################################################

# Function to process a single Splash 4-core benchmark (full pipeline)
# This runs: inst build -> profile run -> merge -> PGO build -> save
process_splash_4core_benchmark() {
    local bench=$1
    local binary=$2
    local args=$3
    local stdin_file=$4
    local mem=$5

    echo "=========================================="
    echo "Processing Splash 4-core $bench (full pipeline)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    local inst_build_dir="build-splash-${bench}-inst"
    local pgo_build_dir="build-splash-${bench}-pgo"
    local gem5_inst="$GEM5_DIR/${inst_build_dir}/X86/gem5.inst"
    local pgo_binary="$GEM5_DIR/${pgo_build_dir}/X86/gem5.pgo"
    local dest_dir="$PGO_BINS_DIR/splash-4core/$bench"
    local dest_binary="$dest_dir/gem5.pgo"

    # Check if final PGO binary already exists
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            echo "[$bench] PGO binary already exists (${file_size} bytes), skipping entire pipeline"
            return 0
        else
            echo "[$bench] Found invalid binary (${file_size} bytes), will rebuild"
            rm -f "$dest_binary"
        fi
    fi

    # Build GEM5_BUILD_ROOTS for both inst and pgo builds
    export GEM5_BUILD_ROOTS="${inst_build_dir},${pgo_build_dir}"

    # Step 1: Build instrumented binary
    if [ ! -f "$gem5_inst" ]; then
        echo "[$bench] Building instrumented binary..."
        if ! scons ${inst_build_dir}/X86/gem5.inst -j20 > "$PROFILE_DIR/build_logs/build-inst-splash-4core-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-splash-4core-${bench}.log"
            return 1
        fi
        echo "[$bench] Instrumented binary built successfully"
    else
        echo "[$bench] Instrumented binary already exists, skipping build"
    fi

    # Step 2: Run instrumented binary to collect profile
    cd "$REPO_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/splash-${bench}.profraw" ]; then
        echo "[$bench] Running instrumented binary to collect profile..."

        # Build gem5 command with stdin if provided
        # Use run-ruby-4core.py config for 4-core Ruby cache hierarchy
        local gem5_cmd="LLVM_PROFILE_FILE=\"$PROFILE_DIR/splash-${bench}.profraw\" \"$gem5_inst\" -r --outdir=\"$PGO_RUNDIR_DIR/splash-inst-${bench}\" \"$GEM5_CONFIG_RUBY_4CORE\" --binary \"$binary\" --args=\"$args\" --cpu-type minor --mem-size \"$mem\""

        if [ -n "$stdin_file" ]; then
            gem5_cmd="$gem5_cmd --stdin \"$stdin_file\""
        fi

        if ! eval $gem5_cmd; then
            echo "[$bench] ERROR: Profile run failed. Check $PGO_RUNDIR_DIR/splash-inst-${bench}/simout.txt"
            return 1
        fi
        echo "[$bench] Profile collected successfully"
    else
        echo "[$bench] Profile already exists, skipping run"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$PROFILE_DIR/splash-${bench}.profdata" ]; then
        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="$PROFILE_DIR/splash-${bench}.profdata" "$PROFILE_DIR/splash-${bench}.profraw" > "$PROFILE_DIR/merge_logs/merge-splash-4core-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: Profile merge failed. Check $PROFILE_DIR/merge_logs/merge-splash-4core-${bench}.log"
            return 1
        fi
        echo "[$bench] Profile merged successfully"
    else
        echo "[$bench] Profdata already exists, skipping merge"
    fi

    # Step 4: Build PGO binary
    if [ ! -f "$pgo_binary" ]; then
        echo "[$bench] Building PGO binary..."
        if ! scons ${pgo_build_dir}/X86/gem5.pgo -j20 > "$PROFILE_DIR/build_logs/build-pgo-splash-4core-${bench}.log" 2>&1; then
            echo "[$bench] ERROR: PGO build failed. Check $PROFILE_DIR/build_logs/build-pgo-splash-4core-${bench}.log"
            return 1
        fi
        echo "[$bench] PGO binary built successfully"
    else
        echo "[$bench] PGO binary already exists in build directory, skipping build"
    fi

    # Step 5: Save PGO binary
    mkdir -p "$dest_dir"
    if [ -f "$pgo_binary" ]; then
        src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
        if [ "$src_size" -le 1048576 ]; then
            echo "[$bench] ERROR: PGO binary too small (${src_size} bytes)"
            return 1
        fi

        if cp "$pgo_binary" "$dest_binary"; then
            dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
            if [ "$dest_size" -eq "$src_size" ]; then
                echo "[$bench] ✓ Saved PGO binary: $dest_binary (${dest_size} bytes)"
                return 0
            else
                echo "[$bench] ERROR: Copy size mismatch: src=${src_size} dest=${dest_size}"
                rm -f "$dest_binary"
                return 1
            fi
        else
            echo "[$bench] ERROR: Failed to copy PGO binary"
            return 1
        fi
    else
        echo "[$bench] ERROR: PGO binary not found at $pgo_binary"
        return 1
    fi
}

# Function to process all Splash 4-core benchmarks in parallel
process_all_splash_4core_benchmarks() {
    local bench
    local bench_key
    local binary
    local args
    local stdin_file
    local mem

    echo "=========================================="
    echo "Processing all Splash 4-core benchmarks in parallel (${#splash_4core_benchmarks[@]} benchmarks)"
    echo "=========================================="

    # Launch all benchmarks in parallel
    declare -A bench_pids
    declare -A pid_to_bench

    for bench_key in "${splash_4core_benchmarks[@]}"; do
        bench="${SPLASH_4CORE_TO_BASE_MAP[$bench_key]:-${bench_key%-4core}}"
        if [ -z "${BENCH_INFO[$bench_key]+_}" ]; then
            echo "[WARN] Missing BENCH_INFO entry for Splash 4-core benchmark: $bench_key (skipping)"
            continue
        fi
        IFS='|' read -r binary args stdin_file mem <<< "${BENCH_INFO[$bench_key]}"

        echo "Launching pipeline for Splash 4-core $bench..."
        process_splash_4core_benchmark "$bench" "$binary" "$args" "$stdin_file" "$mem" > "$PROFILE_DIR/build_logs/pipeline-splash-4core-${bench}.log" 2>&1 &

        pid=$!
        bench_pids[$pid]=1
        pid_to_bench[$pid]=$bench
        echo "  Launched PID $pid for $bench"
    done

    # Wait for all benchmarks to complete
    echo ""
    echo "Waiting for all Splash 4-core pipelines to complete..."
    echo "You can monitor progress in: $PROFILE_DIR/build_logs/pipeline-splash-4core-*.log"

    local success_count=0
    local fail_count=0

    for pid in "${!bench_pids[@]}"; do
        local bench_name="${pid_to_bench[$pid]}"
        wait "$pid"
        exit_status=$?

        if [ $exit_status -eq 0 ]; then
            echo "  ✓ Splash 4-core $bench_name pipeline completed successfully"
            ((success_count++))
        else
            echo "  ✗ Splash 4-core $bench_name pipeline FAILED (exit: $exit_status)"
            ((fail_count++))
        fi
    done

    echo ""
    echo "=========================================="
    echo "Splash 4-core processing summary:"
    echo "  Success: $success_count"
    echo "  Failed: $fail_count"
    echo "  Total: ${#splash_4core_benchmarks[@]}"
    echo "=========================================="

    if [ $fail_count -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Function to cleanup Splash 4-core build directories
cleanup_splash_4core_builds() {
    local bench
    local bench_key

    echo "=========================================="
    echo "Cleaning up Splash 4-core build directories"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    for bench_key in "${splash_4core_benchmarks[@]}"; do
        bench="${SPLASH_4CORE_TO_BASE_MAP[$bench_key]:-${bench_key%-4core}}"
        local inst_build_dir="build-splash-${bench}-inst"
        if [ -d "$inst_build_dir" ]; then
            echo "Removing $inst_build_dir..."
            rm -rf "$inst_build_dir"
        fi

        local pgo_build_dir="build-splash-${bench}-pgo"
        if [ -d "$pgo_build_dir" ]; then
            echo "Removing $pgo_build_dir..."
            rm -rf "$pgo_build_dir"
        fi
    done

    echo "Cleanup completed for Splash 4-core"
}

# Function to print final report
print_final_report() {
    echo ""
    echo "========================================================================"
    echo "                         FINAL EXECUTION REPORT"
    echo "========================================================================"
    echo ""

    local total_benchmarks=0
    local successful_benchmarks=0

    for bench in "${benchmarks[@]}"; do
        checkpoint_dir="$CHECKPOINT_BASE_DIR/${bench}"
        if [ ! -d "$checkpoint_dir" ]; then
            continue
        fi

        num_simpoints=$(ls -d "$checkpoint_dir"/* 2>/dev/null | wc -l)
        if [ "$num_simpoints" -eq 0 ]; then
            continue
        fi

        ((total_benchmarks++))

        echo "------------------------------------------------------------------------"
        echo "Benchmark: $bench (Total Simpoints: $num_simpoints)"
        echo "------------------------------------------------------------------------"

        local all_success=true
        local bench_errors=""

        # Use the actual num_simpoints from BENCHMARK_SIMPOINTS array
        local actual_simpoints=${BENCHMARK_SIMPOINTS["$bench"]:-$num_simpoints}

        for i in $(seq 1 $actual_simpoints); do
            local simpoint_status="Simpoint $i: "
            local has_error=false

            # Check each step - include PGO variant steps if OPT_BREAKDOWN is enabled
            local steps=("BUILD_INST" "RUN_INST" "MERGE_PROFILE")

            if [ "$ENABLE_OPT_BREAKDOWN" = true ]; then
                steps+=("BUILD_PGO_pgo" "BUILD_PGO_pgo-icp" "BUILD_PGO_pgo-hc" "BUILD_PGO_pgo-inline")
            else
                steps+=("BUILD_PGO_pgo")
            fi
            steps+=("SAVE_PGO")

            for step in "${steps[@]}"; do
                key="${bench}|${i}|${step}"
                status="${STEP_STATUS[$key]}"

                if [ "$status" == "FAILED" ]; then
                    has_error=true
                    all_success=false
                    simpoint_status+="[$step: FAILED] "
                elif [ "$status" == "SKIPPED" ]; then
                    # SKIPPED is okay for instrumentation steps (profdata already exists)
                    # Only treat as error if it's a build/save step that got skipped unexpectedly
                    if [[ "$step" != "BUILD_INST" && "$step" != "RUN_INST" && "$step" != "MERGE_PROFILE" ]]; then
                        has_error=true
                        all_success=false
                        simpoint_status+="[$step: SKIPPED] "
                    fi
                fi
            done

            if [ "$has_error" = true ]; then
                echo "  ✗ $simpoint_status"
                # Print detailed errors for this simpoint
                for step in "${steps[@]}"; do
                    error_key="${bench}|${i}|${step}"
                    if [ -n "${ERROR_LOG[$error_key]}" ]; then
                        echo "      └─ $step: ${ERROR_LOG[$error_key]}"
                    fi
                done
            else
                echo "  ✓ Simpoint $i: ALL STEPS COMPLETED"
            fi
        done

        if [ "$all_success" = true ]; then
            echo ""
            echo "  Status: ✓ ALL SIMPOINTS COMPLETED SUCCESSFULLY"
            ((successful_benchmarks++))
        else
            echo ""
            echo "  Status: ✗ SOME STEPS FAILED (see details above)"
        fi
        echo ""
    done

    echo "========================================================================"
    echo "                              SUMMARY"
    echo "========================================================================"
    echo "Total Benchmarks Processed: $total_benchmarks"
    echo "Fully Successful: $successful_benchmarks"
    echo "With Errors: $((total_benchmarks - successful_benchmarks))"
    echo ""
    echo "PGO binaries saved to: $PGO_BINS_DIR"
    echo "Logs saved to: $PROFILE_DIR"
    echo "========================================================================"
}

################################################################################
# PARSE COMMAND LINE ARGUMENTS
################################################################################

while [[ $# -gt 0 ]]; do
  case $1 in
    --parallel-run)
      if [ $# -lt 2 ]; then
        echo "ERROR: --parallel-run requires an argument"
        exit 1
      fi
      PARALLEL_RUN="$2"
      shift 2
      ;;
    --build-mibench-pgo)
      BUILD_MIBENCH_PGO=true
      shift
      ;;
    --build-splash-pgo)
      BUILD_SPLASH_PGO=true
      shift
      ;;
    --build-splash-4core-pgo)
      BUILD_SPLASH_4CORE_PGO=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --parallel-run N          Max concurrent gem5.inst runs in SPEC profiling step"
      echo "  --build-mibench-pgo       Build only MiBench PGO binaries (skip SPEC benchmarks)"
      echo "  --build-splash-pgo        Build only Splash 1-core PGO binaries (skip SPEC benchmarks)"
      echo "  --build-splash-4core-pgo  Build only Splash 4-core PGO binaries (skip SPEC benchmarks)"
      echo "  -h, --help                Show this help message"
      echo ""
      echo "Configuration:"
      echo "  ENABLE_OPT_BREAKDOWN=$ENABLE_OPT_BREAKDOWN   (Build all 4 PGO variants for SPEC)"
      echo "  MAX_SIMPOINTS=$MAX_SIMPOINTS                  (Maximum simpoints per SPEC benchmark)"
      echo "  PARALLEL_RUN=$PARALLEL_RUN                    (Maximum concurrent gem5.inst runs)"
      echo "  MAX_MIBENCH_PARALLEL=$MAX_MIBENCH_PARALLEL              (Maximum parallel MiBench runs)"
      echo ""
      echo "Examples:"
      echo "  $0                            # Build SPEC PGO binaries"
      echo "  $0 --parallel-run 8           # Limit gem5.inst profiling concurrency"
      echo "  $0 --build-mibench-pgo        # Build MiBench PGO binaries only"
      echo "  $0 --build-splash-pgo         # Build Splash 1-core PGO binaries only"
      echo "  $0 --build-splash-4core-pgo   # Build Splash 4-core PGO binaries only"
      echo ""
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

if ! [[ "$PARALLEL_RUN" =~ ^[0-9]+$ ]] || [ "$PARALLEL_RUN" -lt 1 ]; then
  echo "ERROR: --parallel-run/PARALLEL_RUN must be a positive integer. Got: $PARALLEL_RUN"
  exit 1
fi

################################################################################
# MAIN PROCESSING LOOP (SPEC BENCHMARKS)
################################################################################

if [ "$BUILD_MIBENCH_PGO" = true ] || [ "$BUILD_SPLASH_PGO" = true ] || [ "$BUILD_SPLASH_4CORE_PGO" = true ]; then
  echo "========================================================================"
  if [ "$BUILD_MIBENCH_PGO" = true ]; then
    echo "MiBench PGO mode enabled - skipping SPEC benchmark processing"
  fi
  if [ "$BUILD_SPLASH_PGO" = true ]; then
    echo "Splash PGO mode enabled - skipping SPEC benchmark processing"
  fi
  if [ "$BUILD_SPLASH_4CORE_PGO" = true ]; then
    echo "Splash 4-core PGO mode enabled - skipping SPEC benchmark processing"
  fi
  echo "========================================================================"
else
  echo "========================================================================"
  echo "Starting PGO binary generation for SPEC benchmarks"
  echo "========================================================================"

  if [ "${#benchmarks[@]}" -eq 0 ]; then
    echo "ERROR: No SPEC benchmarks selected."
    echo "Check the hardcoded SPEC benchmark list near the top of this script."
    exit 1
  fi

  for bench in "${benchmarks[@]}"; do
    if [ -z "${BENCH_INFO[$bench]+_}" ]; then
        echo "Warning: BENCH_INFO missing for $bench. Skipping."
        continue
    fi
    IFS='|' read -r binary args mem <<< "${BENCH_INFO[$bench]}"

    echo ""
    echo "========================================================================"
    echo "Processing benchmark: $bench"
    echo "========================================================================"

    # Find the checkpoint directory
    checkpoint_dir="$CHECKPOINT_BASE_DIR/${bench}"

    if [ ! -d "$checkpoint_dir" ]; then
        echo "Warning: Checkpoint directory not found for $bench: $checkpoint_dir. Skipping."
        continue
    fi

    # Count number of simpoints
    num_simpoints_available=$(ls -d "$checkpoint_dir"/* 2>/dev/null | wc -l)

    if [ "$num_simpoints_available" -eq 0 ]; then
        echo "Warning: No simpoints found for $bench. Skipping."
        continue
    fi

    # Apply MAX_SIMPOINTS limit if set
    num_simpoints=$num_simpoints_available
    if [ -n "$MAX_SIMPOINTS" ] && [ "$MAX_SIMPOINTS" -gt 0 ]; then
        if [ "$num_simpoints_available" -gt "$MAX_SIMPOINTS" ]; then
            echo "Found $num_simpoints_available simpoints for $bench, but limiting to $MAX_SIMPOINTS"
            num_simpoints=$MAX_SIMPOINTS
        else
            echo "Found $num_simpoints_available simpoints for $bench (within limit)"
        fi
    else
        echo "Found $num_simpoints simpoints for $bench"
    fi

    BENCHMARK_SIMPOINTS["$bench"]=$num_simpoints

    # Check if all profdata files already exist
    all_profdata_exist=true
    for i in $(seq 1 $num_simpoints); do
        if [ ! -f "$PROFILE_DIR/${bench}-${i}.profdata" ]; then
            all_profdata_exist=false
            break
        fi
    done

    if [ "$all_profdata_exist" = true ]; then
        echo ""
        echo "=========================================="
        echo "All profdata files already exist for $bench"
        echo "Skipping instrumentation build and run steps"
        echo "=========================================="
        echo ""

        # Mark skipped steps as SUCCESS since profdata exists
        for i in $(seq 1 $num_simpoints); do
            mark_step_status "$bench" "$i" "BUILD_INST" "SKIPPED"
            mark_step_status "$bench" "$i" "RUN_INST" "SKIPPED"
            mark_step_status "$bench" "$i" "MERGE_PROFILE" "SKIPPED"
        done
    else
        echo ""
        echo "Some profdata files missing, running full instrumentation pipeline..."
        echo ""

        # Step 1: Build instrumented binaries
        build_inst_binaries "$bench" "$num_simpoints"

        # Step 2: Run instrumented binaries to collect profiles
        run_inst_binaries "$bench" "$binary" "$args" "$mem" "$checkpoint_dir"

        # Step 3: Merge profiles
        merge_profiles "$bench" "$num_simpoints"
    fi

    # Step 4: Build PGO binaries (always run)
    build_pgo_binaries "$bench" "$num_simpoints"

    # Step 5: Save PGO binaries and cleanup
    save_and_cleanup "$bench" "$num_simpoints"

    echo ""
    echo "========================================================================"
    echo "Completed processing for $bench"
    echo "========================================================================"
  done

  echo ""
  echo "========================================================================"
  echo "SPEC benchmark PGO generation completed"
  echo "========================================================================"
fi

################################################################################
# MIBENCH PGO GENERATION
################################################################################

if [ "$BUILD_MIBENCH_PGO" = true ]; then
    echo ""
    echo "========================================================================"
    echo "Starting MiBench PGO binary generation"
    echo "========================================================================"
    echo "Number of MiBench benchmarks: ${#mibench_benchmarks[@]}"
    echo "Maximum parallel runs: $MAX_MIBENCH_PARALLEL"
    echo "========================================================================"

    if [ "${#mibench_benchmarks[@]}" -eq 0 ]; then
        echo "ERROR: No MiBench benchmarks selected."
        echo "Check MIBENCH_BENCHMARKS_ALL in setup/init.sh."
        exit 1
    fi

    # Process all MiBench benchmarks in parallel (full pipeline per benchmark)
    # Each benchmark runs: inst build -> profile run -> merge -> PGO build -> save
    if process_all_mibench_benchmarks; then
        echo ""
        echo "All MiBench pipelines completed successfully"
        echo ""

        # Cleanup build directories
        cleanup_mibench_builds

        echo ""
        echo "========================================================================"
        echo "MiBench PGO binary generation completed"
        echo "========================================================================"
        echo "PGO binaries saved to: $PGO_BINS_DIR/mibench/"
        echo ""
    else
        echo ""
        echo "ERROR: Some MiBench pipelines failed"
        echo "Check individual logs in: $PROFILE_DIR/build_logs/pipeline-mibench-*.log"
        echo ""
    fi
else
    echo ""
    echo "========================================================================"
    echo "MiBench PGO generation disabled (BUILD_MIBENCH_PGO=false)"
    echo "To enable, set BUILD_MIBENCH_PGO=true"
    echo "========================================================================"
    echo ""
fi

################################################################################
# SPLASH PGO GENERATION
################################################################################

if [ "$BUILD_SPLASH_PGO" = true ]; then
    echo ""
    echo "========================================================================"
    echo "Starting Splash PGO binary generation"
    echo "========================================================================"
    echo "Number of Splash benchmarks: ${#splash_benchmarks[@]}"
    echo "========================================================================"

    if [ "${#splash_benchmarks[@]}" -eq 0 ]; then
        echo "ERROR: No Splash benchmarks selected."
        echo "Check SPLASH_BENCHMARKS_ALL in setup/init.sh."
        exit 1
    fi

    # Process all Splash benchmarks in parallel (full pipeline per benchmark)
    # Each benchmark runs: inst build -> profile run -> merge -> PGO build -> save
    if process_all_splash_benchmarks; then
        echo ""
        echo "All Splash pipelines completed successfully"
        echo ""

        # Cleanup build directories
        cleanup_splash_builds

        echo ""
        echo "========================================================================"
        echo "Splash PGO binary generation completed"
        echo "========================================================================"
        echo "PGO binaries saved to: $PGO_BINS_DIR/splash/"
        echo ""
    else
        echo ""
        echo "ERROR: Some Splash pipelines failed"
        echo "Check individual logs in: $PROFILE_DIR/build_logs/pipeline-splash-*.log"
        echo ""
    fi
else
    echo ""
    echo "========================================================================"
    echo "Splash PGO generation disabled (BUILD_SPLASH_PGO=false)"
    echo "To enable, set BUILD_SPLASH_PGO=true or use --build-splash-pgo"
    echo "========================================================================"
    echo ""
fi

################################################################################
# SPLASH 4-CORE PGO GENERATION
################################################################################

if [ "$BUILD_SPLASH_4CORE_PGO" = true ]; then
    echo ""
    echo "========================================================================"
    echo "Starting Splash 4-core PGO binary generation"
    echo "========================================================================"
    echo "Number of Splash 4-core benchmarks: ${#splash_4core_benchmarks[@]}"
    echo "========================================================================"

    if [ "${#splash_4core_benchmarks[@]}" -eq 0 ]; then
        echo "ERROR: No Splash 4-core benchmarks selected."
        echo "Check SPLASH_4CORE_BENCHMARKS_ALL in setup/init.sh."
        exit 1
    fi

    # Process all Splash 4-core benchmarks in parallel (full pipeline per benchmark)
    # Each benchmark runs: inst build -> profile run -> merge -> PGO build -> save
    if process_all_splash_4core_benchmarks; then
        echo ""
        echo "All Splash 4-core pipelines completed successfully"
        echo ""

        # Cleanup build directories
        cleanup_splash_4core_builds

        echo ""
        echo "========================================================================"
        echo "Splash 4-core PGO binary generation completed"
        echo "========================================================================"
        echo "PGO binaries saved to: $PGO_BINS_DIR/splash-4core/"
        echo ""
    else
        echo ""
        echo "ERROR: Some Splash 4-core pipelines failed"
        echo "Check individual logs in: $PROFILE_DIR/build_logs/pipeline-splash-4core-*.log"
        echo ""
    fi
else
    echo ""
    echo "========================================================================"
    echo "Splash 4-core PGO generation disabled (BUILD_SPLASH_4CORE_PGO=false)"
    echo "To enable, set BUILD_SPLASH_4CORE_PGO=true or use --build-splash-4core-pgo"
    echo "========================================================================"
    echo ""
fi

# Print final report (only for SPEC benchmarks, not for MiBench or Splash)
if [ "$BUILD_MIBENCH_PGO" != true ] && [ "$BUILD_SPLASH_PGO" != true ] && [ "$BUILD_SPLASH_4CORE_PGO" != true ]; then
    print_final_report
fi

echo ""
echo "Script execution completed."
