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
BUILD_SPLASH_PGO=${BUILD_SPLASH_PGO:-true}

# Toggle: Enable building Splash 4-core PGO binaries
# Set to "true" to build Splash 4-core PGO, "false" to skip
BUILD_SPLASH_4CORE_PGO=${BUILD_SPLASH_4CORE_PGO:-true}

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

run_scons_target() {
    local target=$1
    shift
    (
        cd "$GEM5_DIR" || exit 1
        scons "$target" "$@"
    )
}

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

cleanup_gem5_build_dir() {
    local build_dir=$1
    local label=$2
    local build_path="$GEM5_DIR/$build_dir"

    if [ -d "$build_path" ]; then
        echo "[$label] Removing build dir: $build_dir"
        rm -rf "$build_path"
    fi
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
        local profile_raw="$PROFILE_DIR/${bench}-${i}.profraw"
        local profile_data="$PROFILE_DIR/${bench}-${i}.profdata"

        # Skip build if profile already exists.
        if [ -f "$profile_raw" ] || [ -f "$profile_data" ]; then
            echo "Profile already exists for simpoint $i, skipping instrumented build..."
            mark_step_status "$bench" "$i" "BUILD_INST" "SKIPPED"
            cleanup_gem5_build_dir "build-${bench}-${i}" "${bench}-${i}"
            continue
        fi

        # Skip build if binary already exists
        if [ -f "$GEM5_DIR/build-${bench}-${i}/X86/gem5.inst" ]; then
            echo "Instrumented binary for simpoint $i already exists, skipping build..."
            mark_step_status "$bench" "$i" "BUILD_INST" "SUCCESS"
            continue
        fi

        run_scons_target "build-${bench}-${i}/X86/gem5.inst" -j25 > "$PROFILE_DIR/build_logs/build-inst-${bench}-${i}.log" 2>&1 &
        build_pids[$i]=$!
        sleep 2
        (( i % PARALLEL_BUILD_JOBS == 0 )) && wait
    done
    wait

    # Check if builds succeeded
    for i in $(seq 1 $num_simpoints); do
        local build_key="${bench}|${i}|BUILD_INST"
        if [ "${STEP_STATUS[$build_key]}" = "SKIPPED" ]; then
            continue
        fi

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
            profile_raw="$PROFILE_DIR/${bench}-${smpt_idx}.profraw"
            profile_data="$PROFILE_DIR/${bench}-${smpt_idx}.profdata"

            if [ -f "$profile_raw" ] || [ -f "$profile_data" ]; then
                echo "Profile already exists for simpoint $smpt_idx, skipping instrumented run..."
                mark_step_status "$bench" "$smpt_idx" "RUN_INST" "SKIPPED"
                cleanup_gem5_build_dir "build-${bench}-${smpt_idx}" "${bench}-${smpt_idx}"
                continue
            fi

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

            LLVM_PROFILE_FILE="$profile_raw" "$gem5_cmd" -r --outdir="$PGO_RUNDIR_DIR/${bench}-inst-${smpt_idx}" "$GEM5_CONFIG" \
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
                    cleanup_gem5_build_dir "build-${bench}-${smpt_idx}" "${bench}-${smpt_idx}"
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
        local profile_raw="$PROFILE_DIR/${bench}-${i}.profraw"
        local profile_data="$PROFILE_DIR/${bench}-${i}.profdata"
        if [ -f "$profile_data" ]; then
            echo "Profdata already exists for simpoint $i, skipping merge..."
            mark_step_status "$bench" "$i" "MERGE_PROFILE" "SKIPPED"
        elif [ -f "$profile_raw" ]; then
            echo "Merging profile for simpoint $i..."
            if llvm-profdata merge -output="$profile_data" "$profile_raw" > "$PROFILE_DIR/merge_logs/merge-${bench}-${i}.log" 2>&1; then
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

            run_scons_target "${build_dir}/X86/gem5.${variant}" -j25 > "$PROFILE_DIR/build_logs/build-${variant}-${bench}-${i}.log" 2>&1 &
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

    # Copy PGO binaries to pgo_bins directory
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
    local profile_raw="$PROFILE_DIR/mibench-${bench}.profraw"
    local profile_data="$PROFILE_DIR/mibench-${bench}.profdata"

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
    if [ -f "$profile_raw" ] || [ -f "$profile_data" ]; then
        echo "[$bench] Profile artifact already exists, skipping instrumented build and run"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench"
    else
        # Step 1: Build instrumented binary
        if [ ! -f "$gem5_inst" ]; then
            echo "[$bench] Building instrumented binary..."
            if ! run_scons_target "${inst_build_dir}/X86/gem5.inst" -j80 > "$PROFILE_DIR/build_logs/build-inst-mibench-${bench}.log" 2>&1; then
                echo "[$bench] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-mibench-${bench}.log"
                return 1
            fi
            echo "[$bench] Instrumented binary built successfully"
        else
            echo "[$bench] Instrumented binary already exists, skipping build"
        fi

        # Step 2: Run instrumented binary to collect profile
        cd "$REPO_DIR" || exit 1
        echo "[$bench] Running instrumented binary to collect profile..."
        if ! LLVM_PROFILE_FILE="$profile_raw" "$gem5_inst" -r \
            --outdir="$PGO_RUNDIR_DIR/mibench-inst-${bench}" "$GEM5_CONFIG" \
            --binary "$binary" --args="$args" \
            --cpu-type o3 --mem-size "$mem" ; then
            echo "[$bench] ERROR: Profile run failed. Check $PGO_RUNDIR_DIR/mibench-inst-${bench}/simout.txt"
            return 1
        fi
        echo "[$bench] Profile collected successfully"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$profile_data" ]; then
        if [ ! -f "$profile_raw" ]; then
            echo "[$bench] ERROR: Missing profile raw data at $profile_raw"
            return 1
        fi
        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="$profile_data" "$profile_raw" > "$PROFILE_DIR/merge_logs/merge-mibench-${bench}.log" 2>&1; then
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
        if ! run_scons_target "${pgo_build_dir}/X86/gem5.pgo" -j80 > "$PROFILE_DIR/build_logs/build-pgo-mibench-${bench}.log" 2>&1; then
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
# SPLASH PGO FUNCTIONS - LOCK-STEP
################################################################################

get_benchmark_workdir() {
    local binary=$1
    dirname "$binary"
}

is_valid_binary_artifact() {
    local binary_path=$1
    local file_size

    if [ ! -f "$binary_path" ]; then
        return 1
    fi

    file_size=$(stat -c%s "$binary_path" 2>/dev/null || echo 0)
    [ "$file_size" -gt 1048576 ]
}

copy_verified_binary_artifact() {
    local bench_label=$1
    local src_binary=$2
    local dest_binary=$3
    local src_size
    local dest_size

    if [ ! -f "$src_binary" ]; then
        echo "[$bench_label] ERROR: PGO binary not found at $src_binary"
        return 1
    fi

    src_size=$(stat -c%s "$src_binary" 2>/dev/null || echo 0)
    if [ "$src_size" -le 1048576 ]; then
        echo "[$bench_label] ERROR: PGO binary too small (${src_size} bytes)"
        return 1
    fi

    mkdir -p "$(dirname "$dest_binary")"
    if ! cp "$src_binary" "$dest_binary"; then
        echo "[$bench_label] ERROR: Failed to copy PGO binary"
        return 1
    fi

    dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
    if [ "$dest_size" -ne "$src_size" ]; then
        echo "[$bench_label] ERROR: Copy size mismatch: src=${src_size} dest=${dest_size}"
        rm -f "$dest_binary"
        return 1
    fi

    echo "[$bench_label] ✓ Saved PGO binary: $dest_binary (${dest_size} bytes)"
    return 0
}

run_instrumented_splash_profile() {
    local gem5_binary=$1
    local config_path=$2
    local binary=$3
    local args=$4
    local stdin_file=$5
    local mem=$6
    local profile_raw=$7
    local run_dir=$8
    local bench_workdir
    local -a gem5_cmd

    bench_workdir="$(get_benchmark_workdir "$binary")"

    gem5_cmd=(
        "$gem5_binary"
        -r
        "--outdir=$run_dir"
        "$config_path"
        --binary "$binary"
        "--args=$args"
        --cpu-type minor
        --mem-size "$mem"
    )

    if [ -n "$stdin_file" ]; then
        gem5_cmd+=(--stdin "$stdin_file")
    fi

    (
        cd "$bench_workdir" &&
        LLVM_PROFILE_FILE="$profile_raw" "${gem5_cmd[@]}"
    )
}

wait_for_pid_batch() {
    local -n pids_ref=$1
    local -n pid_to_key_ref=$2
    local -n failed_ref=$3
    local log_pattern=$4
    local stage_desc=$5
    local pid
    local bench_key
    local log_file

    for pid in "${pids_ref[@]}"; do
        bench_key="${pid_to_key_ref[$pid]}"
        if ! wait "$pid"; then
            log_file=$(printf "$log_pattern" "$bench_key")
            echo "[$bench_key] ERROR: ${stage_desc} failed. Check $log_file"
            failed_ref["$bench_key"]=1
        fi
        unset "pid_to_key_ref[$pid]"
    done

    pids_ref=()
}

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
    local profile_raw="$PROFILE_DIR/splash-${bench}.profraw"
    local profile_data="$PROFILE_DIR/splash-${bench}.profdata"
    local merge_log="$PROFILE_DIR/merge_logs/merge-splash-${bench}.log"
    local run_dir="$PGO_RUNDIR_DIR/splash-inst-${bench}"
    local bench_workdir
    bench_workdir="$(get_benchmark_workdir "$binary")"

    if [ ! -f "$binary" ]; then
        echo "[$bench] ERROR: Benchmark binary not found: $binary"
        return 1
    fi

    if [ -n "$stdin_file" ] && [ ! -f "$stdin_file" ]; then
        echo "[$bench] ERROR: Splash stdin file not found: $stdin_file"
        return 1
    fi

    if [ ! -d "$bench_workdir" ]; then
        echo "[$bench] ERROR: Benchmark workdir not found: $bench_workdir"
        return 1
    fi

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
    if [ -f "$profile_raw" ] || [ -f "$profile_data" ]; then
        echo "[$bench] Profile artifact already exists, skipping instrumented build and run"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench"
    else
        # Step 1: Build instrumented binary
        if [ ! -f "$gem5_inst" ]; then
            echo "[$bench] Building instrumented binary..."
            if ! run_scons_target "${inst_build_dir}/X86/gem5.inst" -j25 > "$PROFILE_DIR/build_logs/build-inst-splash-${bench}.log" 2>&1; then
                echo "[$bench] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-splash-${bench}.log"
                return 1
            fi
            echo "[$bench] Instrumented binary built successfully"
        else
            echo "[$bench] Instrumented binary already exists, skipping build"
        fi

        # Step 2: Run instrumented binary to collect profile
        cd "$REPO_DIR" || exit 1
        echo "[$bench] Running instrumented binary to collect profile..."

        # Splash benchmarks use relative input paths; run from the benchmark directory.
        local -a gem5_cmd=(
            "$gem5_inst"
            -r
            "--outdir=$run_dir"
            "$GEM5_CONFIG"
            --binary "$binary"
            "--args=$args"
            --cpu-type minor
            --mem-size "$mem"
        )

        if [ -n "$stdin_file" ]; then
            gem5_cmd+=(--stdin "$stdin_file")
        fi

        if ! (
            cd "$bench_workdir" &&
            LLVM_PROFILE_FILE="$profile_raw" "${gem5_cmd[@]}"
        ); then
            echo "[$bench] ERROR: Profile run failed. Check $run_dir/simout.txt and $PROFILE_DIR/build_logs/run-splash-${bench}.log"
            return 1
        fi
        echo "[$bench] Profile collected successfully"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$profile_data" ]; then
        if [ ! -f "$profile_raw" ]; then
            echo "[$bench] ERROR: Missing profile raw data at $profile_raw"
            return 1
        fi
        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="$profile_data" "$profile_raw" > "$merge_log" 2>&1; then
            echo "[$bench] ERROR: Profile merge failed. Check $merge_log"
            return 1
        fi
        echo "[$bench] Profile merged successfully"
    else
        echo "[$bench] Profdata already exists, skipping merge"
    fi

    # Step 4: Build PGO binary
    if [ ! -f "$pgo_binary" ]; then
        echo "[$bench] Building PGO binary..."
        if ! run_scons_target "${pgo_build_dir}/X86/gem5.pgo" -j25 > "$PROFILE_DIR/build_logs/build-pgo-splash-${bench}.log" 2>&1; then
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

# Function to process all Splash benchmarks in lock-step
process_all_splash_benchmarks() {
    echo "=========================================="
    echo "Processing all Splash benchmarks in lock-step (${#splash_benchmarks[@]} benchmarks)"
    echo "=========================================="

    local bench
    local binary
    local args
    local stdin_file
    local mem
    local workdir
    local success_count=0
    local fail_count=0
    local already_done_count=0
    local pid
    declare -a active_benchmarks=()
    declare -a batch_pids=()
    declare -a run_pids=()
    declare -A failed
    declare -A pid_to_bench
    declare -A binary_map
    declare -A args_map
    declare -A stdin_map
    declare -A mem_map
    declare -A inst_binary_map
    declare -A inst_target_map
    declare -A inst_log_map
    declare -A profile_raw_map
    declare -A profile_data_map
    declare -A merge_log_map
    declare -A run_dir_map
    declare -A run_log_map
    declare -A pgo_binary_map
    declare -A pgo_target_map
    declare -A pgo_log_map
    declare -A dest_binary_map

    for bench in "${splash_benchmarks[@]}"; do
        if [ -z "${BENCH_INFO[$bench]+_}" ]; then
            echo "[WARN] Missing BENCH_INFO entry for Splash benchmark: $bench (skipping)"
            failed["$bench"]=1
            continue
        fi

        IFS='|' read -r binary args stdin_file mem <<< "${BENCH_INFO[$bench]}"
        workdir="$(get_benchmark_workdir "$binary")"

        binary_map["$bench"]="$binary"
        args_map["$bench"]="$args"
        stdin_map["$bench"]="$stdin_file"
        mem_map["$bench"]="$mem"
        inst_binary_map["$bench"]="$GEM5_DIR/build-splash-${bench}-inst/X86/gem5.inst"
        inst_target_map["$bench"]="build-splash-${bench}-inst/X86/gem5.inst"
        inst_log_map["$bench"]="$PROFILE_DIR/build_logs/build-inst-splash-${bench}.log"
        profile_raw_map["$bench"]="$PROFILE_DIR/splash-${bench}.profraw"
        profile_data_map["$bench"]="$PROFILE_DIR/splash-${bench}.profdata"
        merge_log_map["$bench"]="$PROFILE_DIR/merge_logs/merge-splash-${bench}.log"
        run_dir_map["$bench"]="$PGO_RUNDIR_DIR/splash-inst-${bench}"
        run_log_map["$bench"]="$PROFILE_DIR/build_logs/run-splash-${bench}.log"
        pgo_binary_map["$bench"]="$GEM5_DIR/build-splash-${bench}-pgo/X86/gem5.pgo"
        pgo_target_map["$bench"]="build-splash-${bench}-pgo/X86/gem5.pgo"
        pgo_log_map["$bench"]="$PROFILE_DIR/build_logs/build-pgo-splash-${bench}.log"
        dest_binary_map["$bench"]="$PGO_BINS_DIR/splash/${bench}/gem5.pgo"

        if [ ! -f "$binary" ]; then
            echo "[$bench] ERROR: Benchmark binary not found: $binary"
            failed["$bench"]=1
            continue
        fi
        if [ -n "$stdin_file" ] && [ ! -f "$stdin_file" ]; then
            echo "[$bench] ERROR: Splash stdin file not found: $stdin_file"
            failed["$bench"]=1
            continue
        fi
        if [ ! -d "$workdir" ]; then
            echo "[$bench] ERROR: Benchmark workdir not found: $workdir"
            failed["$bench"]=1
            continue
        fi
        if is_valid_binary_artifact "${dest_binary_map[$bench]}"; then
            echo "[$bench] PGO binary already exists, skipping full pipeline"
            ((already_done_count++))
            continue
        fi

        active_benchmarks+=("$bench")
    done

    if [ "${#active_benchmarks[@]}" -gt 0 ]; then
        local build_roots=""
        for bench in "${active_benchmarks[@]}"; do
            if [ -n "$build_roots" ]; then
                build_roots+=","
            fi
            build_roots+="build-splash-${bench}-inst,build-splash-${bench}-pgo"
        done
        export GEM5_BUILD_ROOTS="$build_roots"
    fi

    echo ""
    echo "Stage 1/5: Build Splash instrumented binaries (up to ${PARALLEL_BUILD_JOBS} at a time, -j25 each)"
    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench]}" ] || [ -f "${profile_data_map[$bench]}" ]; then
            echo "[$bench] Profile artifact already exists, skipping instrumented build and run"
            cleanup_gem5_build_dir "build-splash-${bench}-inst" "$bench"
            continue
        fi
        if [ -f "${inst_binary_map[$bench]}" ]; then
            echo "[$bench] Instrumented binary already exists, skipping build"
            continue
        fi

        echo "[$bench] Building instrumented binary..."
        run_scons_target "${inst_target_map[$bench]}" -j25 > "${inst_log_map[$bench]}" 2>&1 &
        pid=$!
        batch_pids+=("$pid")
        pid_to_bench[$pid]="$bench"

        if [ "${#batch_pids[@]}" -ge "$PARALLEL_BUILD_JOBS" ]; then
            wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-inst-splash-%s.log" "instrumented build"
        fi
    done
    if [ "${#batch_pids[@]}" -gt 0 ]; then
        wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-inst-splash-%s.log" "instrumented build"
    fi

    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench]}" ] || [ -f "${profile_data_map[$bench]}" ]; then
            continue
        fi
        if [ ! -f "${inst_binary_map[$bench]}" ]; then
            echo "[$bench] ERROR: Instrumented binary missing after build"
            failed["$bench"]=1
        fi
    done

    echo ""
    echo "Stage 2/5: Run all Splash profile collections"
    pid_to_bench=()
    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench]}" ] || [ -f "${profile_data_map[$bench]}" ]; then
            echo "[$bench] Profile artifact already exists, skipping run"
            continue
        fi

        echo "[$bench] Launching profile run..."
        run_instrumented_splash_profile \
            "${inst_binary_map[$bench]}" \
            "$GEM5_CONFIG" \
            "${binary_map[$bench]}" \
            "${args_map[$bench]}" \
            "${stdin_map[$bench]}" \
            "${mem_map[$bench]}" \
            "${profile_raw_map[$bench]}" \
            "${run_dir_map[$bench]}" > "${run_log_map[$bench]}" 2>&1 &

        pid=$!
        run_pids+=("$pid")
        pid_to_bench[$pid]="$bench"
    done

    for pid in "${run_pids[@]}"; do
        bench="${pid_to_bench[$pid]}"
        if ! wait "$pid"; then
            echo "[$bench] ERROR: Profile run failed. Check ${run_log_map[$bench]} and ${run_dir_map[$bench]}/simout.txt"
            failed["$bench"]=1
            continue
        fi
        if [ ! -f "${profile_raw_map[$bench]}" ]; then
            echo "[$bench] ERROR: Profile run completed but profraw is missing: ${profile_raw_map[$bench]}"
            failed["$bench"]=1
            continue
        fi
        echo "[$bench] Profile collected successfully"
        cleanup_gem5_build_dir "build-splash-${bench}-inst" "$bench"
    done

    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench]}" ] || [ -f "${profile_data_map[$bench]}" ]; then
            cleanup_gem5_build_dir "build-splash-${bench}-inst" "$bench"
        fi
    done

    echo ""
    echo "Stage 3/5: Merge Splash profiles"
    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${profile_data_map[$bench]}" ]; then
            echo "[$bench] Profdata already exists, skipping merge"
            continue
        fi

        echo "[$bench] Merging profile..."
        if ! llvm-profdata merge -output="${profile_data_map[$bench]}" "${profile_raw_map[$bench]}" > "${merge_log_map[$bench]}" 2>&1; then
            echo "[$bench] ERROR: Profile merge failed. Check ${merge_log_map[$bench]}"
            failed["$bench"]=1
            continue
        fi
        echo "[$bench] Profile merged successfully"
    done

    echo ""
    echo "Stage 4/5: Build Splash PGO binaries (up to ${PARALLEL_BUILD_JOBS} at a time, -j25 each)"
    batch_pids=()
    pid_to_bench=()
    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ -f "${pgo_binary_map[$bench]}" ]; then
            echo "[$bench] PGO binary already exists in build directory, skipping build"
            continue
        fi

        echo "[$bench] Building PGO binary..."
        run_scons_target "${pgo_target_map[$bench]}" -j25 > "${pgo_log_map[$bench]}" 2>&1 &
        pid=$!
        batch_pids+=("$pid")
        pid_to_bench[$pid]="$bench"

        if [ "${#batch_pids[@]}" -ge "$PARALLEL_BUILD_JOBS" ]; then
            wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-pgo-splash-%s.log" "PGO build"
        fi
    done
    if [ "${#batch_pids[@]}" -gt 0 ]; then
        wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-pgo-splash-%s.log" "PGO build"
    fi

    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if [ ! -f "${pgo_binary_map[$bench]}" ]; then
            echo "[$bench] ERROR: PGO binary missing after build"
            failed["$bench"]=1
        fi
    done

    echo ""
    echo "Stage 5/5: Save Splash PGO binaries"
    for bench in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            continue
        fi
        if ! copy_verified_binary_artifact "$bench" "${pgo_binary_map[$bench]}" "${dest_binary_map[$bench]}"; then
            failed["$bench"]=1
        fi
    done

    success_count=$already_done_count
    for bench in "${splash_benchmarks[@]}"; do
        if [ -n "${failed[$bench]:-}" ]; then
            ((fail_count++))
        elif [[ " ${active_benchmarks[*]} " == *" ${bench} "* ]]; then
            ((success_count++))
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
# SPLASH 4-CORE PGO FUNCTIONS - LOCK-STEP
################################################################################

# Function to process a single Splash 4-core benchmark (full pipeline)
# This runs: inst build -> profile run -> merge -> PGO build -> save
process_splash_4core_benchmark() {
    local bench_key=$1
    local bench_base=$2
    local binary=$3
    local args=$4
    local stdin_file=$5
    local mem=$6

    echo "=========================================="
    echo "Processing Splash 4-core $bench_key (full pipeline)"
    echo "=========================================="

    cd "$GEM5_DIR" || exit 1

    local inst_build_dir="build-splash-${bench_key}-inst"
    local pgo_build_dir="build-splash-${bench_key}-pgo"
    local gem5_inst="$GEM5_DIR/${inst_build_dir}/X86/gem5.inst"
    local pgo_binary="$GEM5_DIR/${pgo_build_dir}/X86/gem5.pgo"
    local dest_dir="$PGO_BINS_DIR/splash-4core/$bench_base"
    local dest_binary="$dest_dir/gem5.pgo"
    local profile_raw="$PROFILE_DIR/splash-${bench_key}.profraw"
    local profile_data="$PROFILE_DIR/splash-${bench_key}.profdata"
    local merge_log="$PROFILE_DIR/merge_logs/merge-splash-4core-${bench_key}.log"
    local run_dir="$PGO_RUNDIR_DIR/splash-inst-${bench_key}"
    local bench_workdir
    bench_workdir="$(get_benchmark_workdir "$binary")"

    if [ ! -f "$binary" ]; then
        echo "[$bench_key] ERROR: Benchmark binary not found: $binary"
        return 1
    fi

    if [ -n "$stdin_file" ] && [ ! -f "$stdin_file" ]; then
        echo "[$bench_key] ERROR: Splash stdin file not found: $stdin_file"
        return 1
    fi

    if [ ! -d "$bench_workdir" ]; then
        echo "[$bench_key] ERROR: Benchmark workdir not found: $bench_workdir"
        return 1
    fi

    # Check if final PGO binary already exists
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            echo "[$bench_key] PGO binary already exists (${file_size} bytes), skipping entire pipeline"
            return 0
        else
            echo "[$bench_key] Found invalid binary (${file_size} bytes), will rebuild"
            rm -f "$dest_binary"
        fi
    fi

    # Build GEM5_BUILD_ROOTS for both inst and pgo builds
    export GEM5_BUILD_ROOTS="${inst_build_dir},${pgo_build_dir}"
    if [ -f "$profile_raw" ] || [ -f "$profile_data" ]; then
        echo "[$bench_key] Profile artifact already exists, skipping instrumented build and run"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench_key"
    else
        # Step 1: Build instrumented binary
        if [ ! -f "$gem5_inst" ]; then
            echo "[$bench_key] Building instrumented binary..."
            if ! run_scons_target "${inst_build_dir}/X86/gem5.inst" -j25 > "$PROFILE_DIR/build_logs/build-inst-splash-4core-${bench_key}.log" 2>&1; then
                echo "[$bench_key] ERROR: Instrumented build failed. Check $PROFILE_DIR/build_logs/build-inst-splash-4core-${bench_key}.log"
                return 1
            fi
            echo "[$bench_key] Instrumented binary built successfully"
        else
            echo "[$bench_key] Instrumented binary already exists, skipping build"
        fi

        # Step 2: Run instrumented binary to collect profile
        cd "$REPO_DIR" || exit 1
        echo "[$bench_key] Running instrumented binary to collect profile..."

        # Splash benchmarks use relative input paths; run from the benchmark directory.
        local -a gem5_cmd=(
            "$gem5_inst"
            -r
            "--outdir=$run_dir"
            "$GEM5_CONFIG_RUBY_4CORE"
            --binary "$binary"
            "--args=$args"
            --cpu-type minor
            --mem-size "$mem"
        )

        if [ -n "$stdin_file" ]; then
            gem5_cmd+=(--stdin "$stdin_file")
        fi

        if ! (
            cd "$bench_workdir" &&
            LLVM_PROFILE_FILE="$profile_raw" "${gem5_cmd[@]}"
        ); then
            echo "[$bench_key] ERROR: Profile run failed. Check $run_dir/simout.txt and $PROFILE_DIR/build_logs/run-splash-4core-${bench_key}.log"
            return 1
        fi
        echo "[$bench_key] Profile collected successfully"
        cleanup_gem5_build_dir "$inst_build_dir" "$bench_key"
    fi

    # Step 3: Merge profile
    cd "$GEM5_DIR" || exit 1
    if [ ! -f "$profile_data" ]; then
        if [ ! -f "$profile_raw" ]; then
            echo "[$bench_key] ERROR: Missing profile raw data at $profile_raw"
            return 1
        fi
        echo "[$bench_key] Merging profile..."
        if ! llvm-profdata merge -output="$profile_data" "$profile_raw" > "$merge_log" 2>&1; then
            echo "[$bench_key] ERROR: Profile merge failed. Check $merge_log"
            return 1
        fi
        echo "[$bench_key] Profile merged successfully"
    else
        echo "[$bench_key] Profdata already exists, skipping merge"
    fi

    # Step 4: Build PGO binary
    if [ ! -f "$pgo_binary" ]; then
        echo "[$bench_key] Building PGO binary..."
        if ! run_scons_target "${pgo_build_dir}/X86/gem5.pgo" -j25 > "$PROFILE_DIR/build_logs/build-pgo-splash-4core-${bench_key}.log" 2>&1; then
            echo "[$bench_key] ERROR: PGO build failed. Check $PROFILE_DIR/build_logs/build-pgo-splash-4core-${bench_key}.log"
            return 1
        fi
        echo "[$bench_key] PGO binary built successfully"
    else
        echo "[$bench_key] PGO binary already exists in build directory, skipping build"
    fi

    # Step 5: Save PGO binary
    mkdir -p "$dest_dir"
    if [ -f "$pgo_binary" ]; then
        src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
        if [ "$src_size" -le 1048576 ]; then
            echo "[$bench_key] ERROR: PGO binary too small (${src_size} bytes)"
            return 1
        fi

        if cp "$pgo_binary" "$dest_binary"; then
            dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
            if [ "$dest_size" -eq "$src_size" ]; then
                echo "[$bench_key] ✓ Saved PGO binary: $dest_binary (${dest_size} bytes)"
                return 0
            else
                echo "[$bench_key] ERROR: Copy size mismatch: src=${src_size} dest=${dest_size}"
                rm -f "$dest_binary"
                return 1
            fi
        else
            echo "[$bench_key] ERROR: Failed to copy PGO binary"
            return 1
        fi
    else
        echo "[$bench_key] ERROR: PGO binary not found at $pgo_binary"
        return 1
    fi
}

# Function to process all Splash 4-core benchmarks in lock-step
process_all_splash_4core_benchmarks() {
    local bench
    local bench_key
    local binary
    local args
    local stdin_file
    local mem

    echo "=========================================="
    echo "Processing all Splash 4-core benchmarks in lock-step (${#splash_4core_benchmarks[@]} benchmarks)"
    echo "=========================================="

    local workdir
    local success_count=0
    local fail_count=0
    local already_done_count=0
    local pid
    declare -a active_benchmarks=()
    declare -a batch_pids=()
    declare -a run_pids=()
    declare -A failed
    declare -A pid_to_bench
    declare -A binary_map
    declare -A args_map
    declare -A stdin_map
    declare -A mem_map
    declare -A inst_binary_map
    declare -A inst_target_map
    declare -A inst_log_map
    declare -A profile_raw_map
    declare -A profile_data_map
    declare -A merge_log_map
    declare -A run_dir_map
    declare -A run_log_map
    declare -A pgo_binary_map
    declare -A pgo_target_map
    declare -A pgo_log_map
    declare -A dest_binary_map

    for bench_key in "${splash_4core_benchmarks[@]}"; do
        bench="${SPLASH_4CORE_TO_BASE_MAP[$bench_key]:-${bench_key%-4core}}"
        if [ -z "${BENCH_INFO[$bench_key]+_}" ]; then
            echo "[WARN] Missing BENCH_INFO entry for Splash 4-core benchmark: $bench_key (skipping)"
            failed["$bench_key"]=1
            continue
        fi

        IFS='|' read -r binary args stdin_file mem <<< "${BENCH_INFO[$bench_key]}"
        workdir="$(get_benchmark_workdir "$binary")"

        binary_map["$bench_key"]="$binary"
        args_map["$bench_key"]="$args"
        stdin_map["$bench_key"]="$stdin_file"
        mem_map["$bench_key"]="$mem"
        inst_binary_map["$bench_key"]="$GEM5_DIR/build-splash-${bench_key}-inst/X86/gem5.inst"
        inst_target_map["$bench_key"]="build-splash-${bench_key}-inst/X86/gem5.inst"
        inst_log_map["$bench_key"]="$PROFILE_DIR/build_logs/build-inst-splash-4core-${bench_key}.log"
        profile_raw_map["$bench_key"]="$PROFILE_DIR/splash-${bench_key}.profraw"
        profile_data_map["$bench_key"]="$PROFILE_DIR/splash-${bench_key}.profdata"
        merge_log_map["$bench_key"]="$PROFILE_DIR/merge_logs/merge-splash-4core-${bench_key}.log"
        run_dir_map["$bench_key"]="$PGO_RUNDIR_DIR/splash-inst-${bench_key}"
        run_log_map["$bench_key"]="$PROFILE_DIR/build_logs/run-splash-4core-${bench_key}.log"
        pgo_binary_map["$bench_key"]="$GEM5_DIR/build-splash-${bench_key}-pgo/X86/gem5.pgo"
        pgo_target_map["$bench_key"]="build-splash-${bench_key}-pgo/X86/gem5.pgo"
        pgo_log_map["$bench_key"]="$PROFILE_DIR/build_logs/build-pgo-splash-4core-${bench_key}.log"
        dest_binary_map["$bench_key"]="$PGO_BINS_DIR/splash-4core/${bench}/gem5.pgo"

        if [ ! -f "$binary" ]; then
            echo "[$bench_key] ERROR: Benchmark binary not found: $binary"
            failed["$bench_key"]=1
            continue
        fi
        if [ -n "$stdin_file" ] && [ ! -f "$stdin_file" ]; then
            echo "[$bench_key] ERROR: Splash stdin file not found: $stdin_file"
            failed["$bench_key"]=1
            continue
        fi
        if [ ! -d "$workdir" ]; then
            echo "[$bench_key] ERROR: Benchmark workdir not found: $workdir"
            failed["$bench_key"]=1
            continue
        fi
        if is_valid_binary_artifact "${dest_binary_map[$bench_key]}"; then
            echo "[$bench_key] PGO binary already exists, skipping full pipeline"
            ((already_done_count++))
            continue
        fi

        active_benchmarks+=("$bench_key")
    done

    if [ "${#active_benchmarks[@]}" -gt 0 ]; then
        local build_roots=""
        for bench_key in "${active_benchmarks[@]}"; do
            if [ -n "$build_roots" ]; then
                build_roots+=","
            fi
            build_roots+="build-splash-${bench_key}-inst,build-splash-${bench_key}-pgo"
        done
        export GEM5_BUILD_ROOTS="$build_roots"
    fi

    echo ""
    echo "Stage 1/5: Build Splash 4-core instrumented binaries (up to ${PARALLEL_BUILD_JOBS} at a time, -j25 each)"
    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench_key]}" ] || [ -f "${profile_data_map[$bench_key]}" ]; then
            echo "[$bench_key] Profile artifact already exists, skipping instrumented build and run"
            cleanup_gem5_build_dir "build-splash-${bench_key}-inst" "$bench_key"
            continue
        fi
        if [ -f "${inst_binary_map[$bench_key]}" ]; then
            echo "[$bench_key] Instrumented binary already exists, skipping build"
            continue
        fi

        echo "[$bench_key] Building instrumented binary..."
        run_scons_target "${inst_target_map[$bench_key]}" -j25 > "${inst_log_map[$bench_key]}" 2>&1 &
        pid=$!
        batch_pids+=("$pid")
        pid_to_bench[$pid]="$bench_key"

        if [ "${#batch_pids[@]}" -ge "$PARALLEL_BUILD_JOBS" ]; then
            wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-inst-splash-4core-%s.log" "instrumented build"
        fi
    done
    if [ "${#batch_pids[@]}" -gt 0 ]; then
        wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-inst-splash-4core-%s.log" "instrumented build"
    fi

    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench_key]}" ] || [ -f "${profile_data_map[$bench_key]}" ]; then
            continue
        fi
        if [ ! -f "${inst_binary_map[$bench_key]}" ]; then
            echo "[$bench_key] ERROR: Instrumented binary missing after build"
            failed["$bench_key"]=1
        fi
    done

    echo ""
    echo "Stage 2/5: Run all Splash 4-core profile collections"
    pid_to_bench=()
    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench_key]}" ] || [ -f "${profile_data_map[$bench_key]}" ]; then
            echo "[$bench_key] Profile artifact already exists, skipping run"
            continue
        fi

        echo "[$bench_key] Launching profile run..."
        run_instrumented_splash_profile \
            "${inst_binary_map[$bench_key]}" \
            "$GEM5_CONFIG_RUBY_4CORE" \
            "${binary_map[$bench_key]}" \
            "${args_map[$bench_key]}" \
            "${stdin_map[$bench_key]}" \
            "${mem_map[$bench_key]}" \
            "${profile_raw_map[$bench_key]}" \
            "${run_dir_map[$bench_key]}" > "${run_log_map[$bench_key]}" 2>&1 &

        pid=$!
        run_pids+=("$pid")
        pid_to_bench[$pid]="$bench_key"
    done

    for pid in "${run_pids[@]}"; do
        bench_key="${pid_to_bench[$pid]}"
        if ! wait "$pid"; then
            echo "[$bench_key] ERROR: Profile run failed. Check ${run_log_map[$bench_key]} and ${run_dir_map[$bench_key]}/simout.txt"
            failed["$bench_key"]=1
            continue
        fi
        if [ ! -f "${profile_raw_map[$bench_key]}" ]; then
            echo "[$bench_key] ERROR: Profile run completed but profraw is missing: ${profile_raw_map[$bench_key]}"
            failed["$bench_key"]=1
            continue
        fi
        echo "[$bench_key] Profile collected successfully"
        cleanup_gem5_build_dir "build-splash-${bench_key}-inst" "$bench_key"
    done

    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${profile_raw_map[$bench_key]}" ] || [ -f "${profile_data_map[$bench_key]}" ]; then
            cleanup_gem5_build_dir "build-splash-${bench_key}-inst" "$bench_key"
        fi
    done

    echo ""
    echo "Stage 3/5: Merge Splash 4-core profiles"
    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${profile_data_map[$bench_key]}" ]; then
            echo "[$bench_key] Profdata already exists, skipping merge"
            continue
        fi

        echo "[$bench_key] Merging profile..."
        if ! llvm-profdata merge -output="${profile_data_map[$bench_key]}" "${profile_raw_map[$bench_key]}" > "${merge_log_map[$bench_key]}" 2>&1; then
            echo "[$bench_key] ERROR: Profile merge failed. Check ${merge_log_map[$bench_key]}"
            failed["$bench_key"]=1
            continue
        fi
        echo "[$bench_key] Profile merged successfully"
    done

    echo ""
    echo "Stage 4/5: Build Splash 4-core PGO binaries (up to ${PARALLEL_BUILD_JOBS} at a time, -j25 each)"
    batch_pids=()
    pid_to_bench=()
    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ -f "${pgo_binary_map[$bench_key]}" ]; then
            echo "[$bench_key] PGO binary already exists in build directory, skipping build"
            continue
        fi

        echo "[$bench_key] Building PGO binary..."
        run_scons_target "${pgo_target_map[$bench_key]}" -j25 > "${pgo_log_map[$bench_key]}" 2>&1 &
        pid=$!
        batch_pids+=("$pid")
        pid_to_bench[$pid]="$bench_key"

        if [ "${#batch_pids[@]}" -ge "$PARALLEL_BUILD_JOBS" ]; then
            wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-pgo-splash-4core-%s.log" "PGO build"
        fi
    done
    if [ "${#batch_pids[@]}" -gt 0 ]; then
        wait_for_pid_batch batch_pids pid_to_bench failed "$PROFILE_DIR/build_logs/build-pgo-splash-4core-%s.log" "PGO build"
    fi

    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if [ ! -f "${pgo_binary_map[$bench_key]}" ]; then
            echo "[$bench_key] ERROR: PGO binary missing after build"
            failed["$bench_key"]=1
        fi
    done

    echo ""
    echo "Stage 5/5: Save Splash 4-core PGO binaries"
    for bench_key in "${active_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            continue
        fi
        if ! copy_verified_binary_artifact "$bench_key" "${pgo_binary_map[$bench_key]}" "${dest_binary_map[$bench_key]}"; then
            failed["$bench_key"]=1
        fi
    done

    success_count=$already_done_count
    for bench_key in "${splash_4core_benchmarks[@]}"; do
        if [ -n "${failed[$bench_key]:-}" ]; then
            ((fail_count++))
        elif [[ " ${active_benchmarks[*]} " == *" ${bench_key} "* ]]; then
            ((success_count++))
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
        local inst_build_dir="build-splash-${bench_key}-inst"
        if [ -d "$inst_build_dir" ]; then
            echo "Removing $inst_build_dir..."
            rm -rf "$inst_build_dir"
        fi

        local pgo_build_dir="build-splash-${bench_key}-pgo"
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
            cleanup_gem5_build_dir "build-${bench}-${i}" "${bench}-${i}"
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
        echo "Check stage logs in:"
        echo "  $PROFILE_DIR/build_logs/build-inst-splash-*.log"
        echo "  $PROFILE_DIR/build_logs/run-splash-*.log"
        echo "  $PROFILE_DIR/build_logs/build-pgo-splash-*.log"
        echo "  $PROFILE_DIR/merge_logs/merge-splash-*.log"
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
        echo "Check stage logs in:"
        echo "  $PROFILE_DIR/build_logs/build-inst-splash-4core-*.log"
        echo "  $PROFILE_DIR/build_logs/run-splash-4core-*.log"
        echo "  $PROFILE_DIR/build_logs/build-pgo-splash-4core-*.log"
        echo "  $PROFILE_DIR/merge_logs/merge-splash-4core-*.log"
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
