#!/usr/bin/env bash

## This script generates a memory-intensive PGO binary for gem5
## It builds an instrumented binary, runs it with minimal cache sizes to stress memory,
## and then builds a PGO-optimized binary using that profile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/init.sh"

if [ -z "${REPO_DIR:-}" ]; then
  echo "REPO_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

if [ -z "${SPEC_BUILT_DIR:-}" ]; then
  echo "SPEC_BUILT_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

# Configuration
BENCH="${BENCH:-623.xalancbmk_s}"
SIMPOINT="${SIMPOINT:-17}"
RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
GEM5_CONFIG="${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}"
GEM5_DIR="$REPO_DIR/gem5"
PROFILE_DIR="$REPO_DIR/profiles/memory-intensive"
PGO_BINS_DIR="$REPO_DIR/pgo_bins"
CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
CHECKPOINT_DIR="$CHECKPOINT_BASE_DIR/$BENCH/$SIMPOINT"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
MEM_PGO_RUNDIR_DIR="${MEM_PGO_RUNDIR_DIR:-$RESULTS_RUNDIR_DIR/mem-pgo}"

if [ ! -f "$GEM5_CONFIG" ]; then
    echo "Error: GEM5 config not found: $GEM5_CONFIG"
    exit 1
fi

# Binary and arguments for 623.xalancbmk_s
BINARY="$SPEC_BUILT_DIR/$BENCH/run/run_base_refspeed_$RUN_LABEL.0000/xalancbmk_s_base.$RUN_LABEL"
ARGS="-v $SPEC_BUILT_DIR/$BENCH/run/run_base_refspeed_$RUN_LABEL.0000/t5.xml $SPEC_BUILT_DIR/$BENCH/run/run_base_refspeed_$RUN_LABEL.0000/xalanc.xsl"
MEM_SIZE="4GiB"

# Tiny cache sizes for memory stress
L1D_SIZE="512B"
L1I_SIZE="512B"
L2_SIZE="1KiB"

# Create necessary directories
mkdir -p "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR/build_logs"
mkdir -p "$PROFILE_DIR/run_logs"
mkdir -p "$PGO_BINS_DIR/$BENCH"
mkdir -p "$MEM_PGO_RUNDIR_DIR"

echo "========================================"
echo "Generating memory-intensive PGO binary"
echo "Benchmark: $BENCH"
echo "Simpoint: $SIMPOINT"
echo "Cache sizes: L1D=$L1D_SIZE, L1I=$L1I_SIZE, L2=$L2_SIZE"
echo "========================================"

# Check if checkpoint exists
if [ ! -d "$CHECKPOINT_DIR" ]; then
    echo "Error: Checkpoint directory not found: $CHECKPOINT_DIR"
    exit 1
fi

# Set GEM5_BUILD_ROOTS for instrumented build
export GEM5_BUILD_ROOTS="build-mem-pgo"

cd "$GEM5_DIR" || exit 1

# Step 1: Build instrumented binary
echo ""
echo "=========================================="
echo "Step 1: Building instrumented binary"
echo "=========================================="

if [ -f "$GEM5_DIR/build-mem-pgo/X86/gem5.inst" ]; then
    echo "Instrumented binary already exists, skipping build..."
else
    scons build-mem-pgo/X86/gem5.inst -j80 > "$PROFILE_DIR/build_logs/build-inst.log" 2>&1
    if [ ! -f "$GEM5_DIR/build-mem-pgo/X86/gem5.inst" ]; then
        echo "Error: Failed to build instrumented binary. Check $PROFILE_DIR/build_logs/build-inst.log"
        exit 1
    fi
    echo "Instrumented binary built successfully"
fi

# Step 2: Run instrumented binary with tiny cache
echo ""
echo "=========================================="
echo "Step 2: Running instrumented binary"
echo "=========================================="

PROFRAW_FILE="$PROFILE_DIR/$BENCH-$SIMPOINT.profraw"
PROFDATA_FILE="$PROFILE_DIR/$BENCH-$SIMPOINT.profdata"

if [ -f "$PROFDATA_FILE" ]; then
    echo "Profile data already exists: $PROFDATA_FILE"
    echo "Skipping instrumented run..."
else
    cd "$REPO_DIR" || exit 1

    echo "Running with minimal cache sizes to stress memory subsystem..."
    echo "  L1D: $L1D_SIZE, L1I: $L1I_SIZE, L2: $L2_SIZE"

    LLVM_PROFILE_FILE="$PROFRAW_FILE" \
        "$GEM5_DIR/build-mem-pgo/X86/gem5.inst" \
        -r \
        --outdir="$MEM_PGO_RUNDIR_DIR/$BENCH-mem-inst-$SIMPOINT" \
        "$GEM5_CONFIG" \
        --binary "$BINARY" \
        --args="$ARGS" \
        --restore-from "$CHECKPOINT_DIR" \
        --cpu-type minor \
        --mem-size "$MEM_SIZE" \
        --l1d-size "$L1D_SIZE" \
        --l1i-size "$L1I_SIZE" \
        --l2-size "$L2_SIZE" \
        > "$PROFILE_DIR/run_logs/run-inst.log" 2>&1

    if [ $? -ne 0 ] || [ ! -f "$PROFRAW_FILE" ]; then
        echo "Error: Instrumented run failed. Check $PROFILE_DIR/run_logs/run-inst.log"
        exit 1
    fi

    echo "Instrumented run completed successfully"

    # Step 3: Merge profile
    echo ""
    echo "=========================================="
    echo "Step 3: Merging profile data"
    echo "=========================================="

    llvm-profdata merge -output="$PROFDATA_FILE" "$PROFRAW_FILE"

    if [ $? -ne 0 ] || [ ! -f "$PROFDATA_FILE" ]; then
        echo "Error: Failed to merge profile data"
        exit 1
    fi

    echo "Profile data merged successfully: $PROFDATA_FILE"
fi

# Step 4: Build PGO binary
echo ""
echo "=========================================="
echo "Step 4: Building PGO binary"
echo "=========================================="

cd "$GEM5_DIR" || exit 1

PGO_BINARY="$GEM5_DIR/build-mem-pgo/X86/gem5.pgo"
DEST_BINARY="$PGO_BINS_DIR/$BENCH/gem5-$SIMPOINT.mem-pgo"

if [ -f "$DEST_BINARY" ]; then
    file_size=$(stat -c%s "$DEST_BINARY" 2>/dev/null || echo 0)
    if [ "$file_size" -gt 1048576 ]; then
        echo "PGO binary already exists (${file_size} bytes), skipping build..."
    else
        echo "WARNING: Found invalid binary at $DEST_BINARY (${file_size} bytes), will rebuild..."
        rm -f "$DEST_BINARY"
    fi
fi

if [ ! -f "$DEST_BINARY" ] || [ $(stat -c%s "$DEST_BINARY" 2>/dev/null || echo 0) -le 1048576 ]; then
    scons build-mem-pgo/X86/gem5.pgo -j80 > "$PROFILE_DIR/build_logs/build-pgo.log" 2>&1

    if [ ! -f "$PGO_BINARY" ]; then
        echo "Error: Failed to build PGO binary. Check $PROFILE_DIR/build_logs/build-pgo.log"
        exit 1
    fi

    echo "PGO binary built successfully"

    # Step 5: Save PGO binary
    echo ""
    echo "=========================================="
    echo "Step 5: Saving PGO binary"
    echo "=========================================="

    src_size=$(stat -c%s "$PGO_BINARY" 2>/dev/null || echo 0)
    if [ "$src_size" -le 1048576 ]; then
        echo "Error: PGO binary too small (${src_size} bytes)"
        exit 1
    fi

    cp "$PGO_BINARY" "$DEST_BINARY"

    dest_size=$(stat -c%s "$DEST_BINARY" 2>/dev/null || echo 0)
    if [ "$dest_size" -eq "$src_size" ]; then
        echo "Saved: $PGO_BINARY -> $DEST_BINARY (${dest_size} bytes)"
    else
        echo "Error: Copy size mismatch: src=${src_size} dest=${dest_size}"
        rm -f "$DEST_BINARY"
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "Memory-intensive PGO binary generation complete!"
echo "=========================================="
echo "Profile: $PROFDATA_FILE"
echo "Binary: $DEST_BINARY"
echo ""
