#!/bin/bash

## This script builds PGO-optimized gem5 binaries for each benchmark
## using merged profdata files (one profdata per benchmark, not per simpoint)
##
## Prerequisites:
## - Provide merged profdata files under $PROFDATA_DIR (default: $REPO_DIR/profiles/bench)
##
## Usage: ./setup/gen-pgobin-coarse.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/init.sh"

if [ -z "$REPO_DIR" ]; then
  echo "REPO_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

# Configuration
GEM5_DIR=$REPO_DIR/gem5
PROFILE_DIR="${PROFILE_DIR:-$REPO_DIR/profiles}"
PROFDATA_DIR="${PROFDATA_DIR:-$PROFILE_DIR/bench}"
PGO_BINS_DIR="$REPO_DIR/pgo_bins"
BUILD_LOGS_DIR="${BUILD_LOGS_DIR:-${RESULTS_LOGS_DIR:-$REPO_DIR/results/logs}/pgo_build_logs}"

# Maximum number of parallel build jobs
MAX_PARALLEL=${MAX_PARALLEL:-3}

# Create necessary directories
mkdir -p "$PGO_BINS_DIR"
mkdir -p "$BUILD_LOGS_DIR"
mkdir -p "$PROFDATA_DIR"

merge_per_simpoint_profdata_by_benchmark() {
    local merge_success=0
    local merge_failed=0
    local merge_skipped=0

    echo "=========================================================================="
    echo "Checking per-simpoint profdata in $PROFILE_DIR"
    echo "Merging missing per-benchmark profdata into $PROFDATA_DIR"
    echo "=========================================================================="

    mapfile -t benchmark_prefixes < <(
        find "$PROFILE_DIR" -maxdepth 1 -type f -name "*.profdata" -printf "%f\n" \
            | sed -n 's/-[0-9]\+\.profdata$//p' \
            | sort -u
    )

    if [ "${#benchmark_prefixes[@]}" -eq 0 ]; then
        echo "[INFO] No per-simpoint profdata files found in $PROFILE_DIR"
        echo ""
        return 0
    fi

    for bench in "${benchmark_prefixes[@]}"; do
        output_file="$PROFDATA_DIR/$bench.profdata"

        if [ -s "$output_file" ]; then
            echo "[SKIP] $bench: merged profdata already exists at $output_file"
            ((merge_skipped++))
            continue
        fi

        mapfile -t simpoint_profdata_files < <(
            find "$PROFILE_DIR" -maxdepth 1 -type f -name "${bench}-*.profdata" | sort
        )

        if [ "${#simpoint_profdata_files[@]}" -eq 0 ]; then
            echo "[WARN] $bench: no per-simpoint profdata files found, skipping"
            ((merge_skipped++))
            continue
        fi

        echo "[MERGE] $bench (${#simpoint_profdata_files[@]} files)"
        if llvm-profdata merge -output="$output_file" "${simpoint_profdata_files[@]}" \
            > "$BUILD_LOGS_DIR/merge-bench-${bench}.log" 2>&1; then
            echo "[OK] Created $output_file"
            ((merge_success++))
        else
            echo "[ERR] Failed to merge $bench (check $BUILD_LOGS_DIR/merge-bench-${bench}.log)"
            ((merge_failed++))
        fi
    done

    echo ""
    echo "Merge summary: success=$merge_success skipped=$merge_skipped failed=$merge_failed"
    echo ""
}

merge_per_simpoint_profdata_by_benchmark

# Find all profdata files and extract benchmark names
echo "=========================================================================="
echo "Scanning for profdata files in $PROFDATA_DIR..."
echo "=========================================================================="

PROFDATA_FILES=("$PROFDATA_DIR"/*.profdata)

if [ ! -e "${PROFDATA_FILES[0]}" ]; then
    echo "[err] No profdata files found in $PROFDATA_DIR"
    echo "[err] No coarse PGO build inputs are available."
    echo "      Expected either:"
    echo "      1) existing $PROFDATA_DIR/<benchmark>.profdata, or"
    echo "      2) per-simpoint files $PROFILE_DIR/<benchmark>-<simpoint>.profdata for auto-merge."
    exit 1
fi

# Extract benchmark names (remove .profdata extension)
BENCHMARKS=()
for profdata_file in "${PROFDATA_FILES[@]}"; do
    bench_name=$(basename "$profdata_file" .profdata)
    # Skip unified_all_benchmarks (will be added separately)
    if [ "$bench_name" != "unified_all_benchmarks" ]; then
        BENCHMARKS+=("$bench_name")
    fi
done

# Add unified profdata if it exists
UNIFIED_PROFDATA="$PROFDATA_DIR/unified_all_benchmarks.profdata"
if [ -f "$UNIFIED_PROFDATA" ]; then
    BENCHMARKS+=("unified_all_benchmarks")
    echo "Found unified profdata file, will build unified PGO binary"
fi

echo "Found ${#BENCHMARKS[@]} benchmarks:"
for bench in "${BENCHMARKS[@]}"; do
    echo "  - $bench"
done
echo ""

# Build GEM5_BUILD_ROOTS string (comma-separated list of all build directories)
echo "=========================================================================="
echo "Setting up GEM5_BUILD_ROOTS..."
echo "=========================================================================="

BUILD_ROOTS=""
for bench in "${BENCHMARKS[@]}"; do
    if [ -n "$BUILD_ROOTS" ]; then
        BUILD_ROOTS="${BUILD_ROOTS},build-${bench}-pgo"
    else
        BUILD_ROOTS="build-${bench}-pgo"
    fi
done

export GEM5_BUILD_ROOTS="$BUILD_ROOTS"
echo "GEM5_BUILD_ROOTS=$GEM5_BUILD_ROOTS"
echo ""

# Change to gem5 directory
cd "$GEM5_DIR" || exit 1

# Build PGO binaries with parallelism control
echo "=========================================================================="
echo "Building PGO binaries for all benchmarks"
echo "Maximum parallel jobs: $MAX_PARALLEL"
echo "=========================================================================="
echo ""

job_count=0
declare -A build_pids

for bench in "${BENCHMARKS[@]}"; do
    build_dir="build-${bench}-pgo"
    pgo_binary="${build_dir}/X86/gem5.pgo"
    dest_binary="$PGO_BINS_DIR/$bench/gem5.pgo"

    # Check if binary already exists and is valid
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            echo "[$bench] PGO binary already exists (${file_size} bytes), skipping build..."
            continue
        else
            echo "[$bench] WARNING: Found invalid binary (${file_size} bytes), will rebuild..."
            rm -f "$dest_binary"
        fi
    fi

    echo "[$bench] Starting PGO build..."
    echo "  Profile: $PROFDATA_DIR/${bench}.profdata"
    echo "  Build dir: $build_dir"

    # Launch build in background
    scons ${build_dir}/X86/gem5.pgo -j25 > "$BUILD_LOGS_DIR/build-pgo-${bench}.log" 2>&1 &
    build_pids[$bench]=$!
    echo "  Launched PID: ${build_pids[$bench]}"

    ((job_count++))

    # Wait if we've reached max parallel jobs
    if (( job_count % MAX_PARALLEL == 0 )); then
        echo ""
        echo "Reached $MAX_PARALLEL parallel jobs, waiting for completion..."
        wait
        echo "Batch completed, continuing..."
        echo ""
    fi

    sleep 2
done

# Wait for all remaining builds to complete
echo ""
echo "Waiting for all remaining builds to complete..."
wait
echo "All builds completed!"
echo ""

# Check build results and copy binaries
echo "=========================================================================="
echo "Checking build results and copying binaries"
echo "=========================================================================="
echo ""

declare -A build_status
successful_builds=0
failed_builds=0

for bench in "${BENCHMARKS[@]}"; do
    build_dir="build-${bench}-pgo"
    pgo_binary="${build_dir}/X86/gem5.pgo"
    dest_dir="$PGO_BINS_DIR/$bench"
    dest_binary="$dest_dir/gem5.pgo"

    # Skip if already existed and was valid
    if [ -f "$dest_binary" ]; then
        file_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
        if [ "$file_size" -gt 1048576 ]; then
            build_status[$bench]="SKIPPED"
            ((successful_builds++))
            continue
        fi
    fi

    if [ -f "$pgo_binary" ]; then
        # Verify source binary is valid (size > 1MB)
        src_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
        if [ "$src_size" -le 1048576 ]; then
            echo "[$bench] ✗ FAILED - Binary too small (${src_size} bytes)"
            build_status[$bench]="FAILED"
            ((failed_builds++))
            continue
        fi

        # Create destination directory
        mkdir -p "$dest_dir"

        # Copy binary
        if cp "$pgo_binary" "$dest_binary"; then
            # Verify copied binary
            dest_size=$(stat -c%s "$dest_binary" 2>/dev/null || echo 0)
            if [ "$dest_size" -eq "$src_size" ]; then
                echo "[$bench] ✓ SUCCESS - Saved to $dest_binary (${dest_size} bytes)"
                build_status[$bench]="SUCCESS"
                ((successful_builds++))
            else
                echo "[$bench] ✗ FAILED - Copy size mismatch (src=${src_size}, dest=${dest_size})"
                rm -f "$dest_binary"
                build_status[$bench]="FAILED"
                ((failed_builds++))
            fi
        else
            echo "[$bench] ✗ FAILED - Could not copy binary"
            build_status[$bench]="FAILED"
            ((failed_builds++))
        fi
    else
        echo "[$bench] ✗ FAILED - Binary not created. Check $BUILD_LOGS_DIR/build-pgo-${bench}.log"
        build_status[$bench]="FAILED"
        ((failed_builds++))
    fi
done

echo ""

# Cleanup build directories
echo "=========================================================================="
echo "Cleaning up build directories"
echo "=========================================================================="
echo ""

for bench in "${BENCHMARKS[@]}"; do
    build_dir="build-${bench}-pgo"

    if [ -d "$build_dir" ]; then
        echo "Removing $build_dir..."
        rm -rf "$build_dir"
    fi
done

echo "Cleanup completed!"
echo ""

# Print final report
echo "=========================================================================="
echo "                         BUILD SUMMARY"
echo "=========================================================================="
echo ""
echo "Total benchmarks: ${#BENCHMARKS[@]}"
echo "Successful builds: $successful_builds"
echo "Failed builds: $failed_builds"
echo ""

if [ $failed_builds -gt 0 ]; then
    echo "Failed benchmarks:"
    for bench in "${BENCHMARKS[@]}"; do
        if [ "${build_status[$bench]}" == "FAILED" ]; then
            echo "  ✗ $bench (check $BUILD_LOGS_DIR/build-pgo-${bench}.log)"
        fi
    done
    echo ""
fi

echo "PGO binaries saved to: $PGO_BINS_DIR"
echo "Build logs saved to: $BUILD_LOGS_DIR"
echo "=========================================================================="
echo ""

if [ $failed_builds -eq 0 ]; then
    echo "All builds completed successfully!"
    exit 0
else
    echo "Some builds failed. Please check the logs for details."
    exit 1
fi
