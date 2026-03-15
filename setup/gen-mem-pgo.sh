#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/init.sh"

usage() {
  cat <<'EOF'
Usage: ./setup/gen-mem-pgo.sh [options]

Generate memory-intensive universal profiles in ./profiles/univ_cand.

Options:
  --o3-classic       Generate only the O3 single-core small-cache profile.
  --minor-classic    Generate only the Minor single-core small-cache profile.
  --minor-ruby       Generate only the Minor single-core small-cache Ruby profile.
  --benchmark NAME   SPEC benchmark to profile (default: 623.xalancbmk_s).
  --simpoint ID      Simpoint/checkpoint ID to restore from (default: 17).
  --l1d-size SIZE    L1D cache size (default: 512B).
  --l1i-size SIZE    L1I cache size (default: 512B).
  --l2-size SIZE     L2 cache size (default: 1KiB).
  --keep-builds      Keep build-* -inst directories after successful profiling.
  -h, --help         Show this help message.

If no profile-selection option is provided, all three profiles are generated:
  mem
  mem-minor
  mem-minor-ruby
EOF
}

if [ -z "${REPO_DIR:-}" ]; then
  echo "ERROR: REPO_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

if [ -z "${SPEC_BUILT_DIR:-}" ]; then
  echo "ERROR: SPEC_BUILT_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

if [ -z "${CHECKPOINT_BASE_DIR:-}" ]; then
  echo "ERROR: CHECKPOINT_BASE_DIR environment variable is not set. Please source setup/init.sh"
  exit 1
fi

if ! declare -p BENCH_INFO >/dev/null 2>&1; then
  echo "ERROR: Shared BENCH_INFO is not loaded. Please source setup/init.sh"
  exit 1
fi

SELECT_O3=false
SELECT_MINOR=false
SELECT_MINOR_RUBY=false
KEEP_BUILDS=false

BENCH="${BENCH:-623.xalancbmk_s}"
SIMPOINT="${SIMPOINT:-17}"
L1D_SIZE="${L1D_SIZE:-512B}"
L1I_SIZE="${L1I_SIZE:-512B}"
L2_SIZE="${L2_SIZE:-1KiB}"
NUM_L2_BANKS="${NUM_L2_BANKS:-1}"
SCONS_JOBS="${SCONS_JOBS:-25}"
INTERVAL="${INTERVAL:-100000000}"
WARMUP_INTERVAL="${WARMUP_INTERVAL:-1000000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --o3-classic)
      SELECT_O3=true
      shift
      ;;
    --minor-classic)
      SELECT_MINOR=true
      shift
      ;;
    --minor-ruby)
      SELECT_MINOR_RUBY=true
      shift
      ;;
    --benchmark)
      BENCH="$2"
      shift 2
      ;;
    --simpoint)
      SIMPOINT="$2"
      shift 2
      ;;
    --l1d-size)
      L1D_SIZE="$2"
      shift 2
      ;;
    --l1i-size)
      L1I_SIZE="$2"
      shift 2
      ;;
    --l2-size)
      L2_SIZE="$2"
      shift 2
      ;;
    --keep-builds)
      KEEP_BUILDS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

declare -a profiles=()
if [ "$SELECT_O3" = false ] && [ "$SELECT_MINOR" = false ] && [ "$SELECT_MINOR_RUBY" = false ]; then
  profiles=(
    "mem"
    "mem-minor"
    "mem-minor-ruby"
  )
else
  [ "$SELECT_O3" = true ] && profiles+=("mem")
  [ "$SELECT_MINOR" = true ] && profiles+=("mem-minor")
  [ "$SELECT_MINOR_RUBY" = true ] && profiles+=("mem-minor-ruby")
fi

GEM5_DIR="$REPO_DIR/gem5"
PROFILE_DIR="$REPO_DIR/profiles/univ_cand"
RESULTS_LOGS_DIR="${RESULTS_LOGS_DIR:-$REPO_DIR/results/logs}"
RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$REPO_DIR/results/rundir}"
BUILD_LOG_DIR="$RESULTS_LOGS_DIR/mem_profile_build_logs"
RUN_LOG_DIR="$RESULTS_LOGS_DIR/mem_profile_run_logs"
MERGE_LOG_DIR="$RESULTS_LOGS_DIR/mem_profile_merge_logs"
RUNDIR_BASE="$RESULTS_RUNDIR_DIR/mem-profile"
GEM5_CONFIG_BASIC="${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}"
GEM5_CONFIG_RUBY_SINGLE="${GEM5_CONFIG_RUBY_SINGLE:-$REPO_DIR/gem5_config/run-ruby-single.py}"

mkdir -p "$PROFILE_DIR" "$BUILD_LOG_DIR" "$RUN_LOG_DIR" "$MERGE_LOG_DIR" "$RUNDIR_BASE"

if [ ! -d "$GEM5_DIR" ]; then
  echo "ERROR: gem5 directory not found: $GEM5_DIR"
  exit 1
fi

if [ ! -f "$GEM5_CONFIG_BASIC" ]; then
  echo "ERROR: gem5 config not found: $GEM5_CONFIG_BASIC"
  exit 1
fi

if [[ " ${profiles[*]} " == *" mem-minor-ruby "* ]] && [ ! -f "$GEM5_CONFIG_RUBY_SINGLE" ]; then
  echo "ERROR: Ruby single-core gem5 config not found: $GEM5_CONFIG_RUBY_SINGLE"
  exit 1
fi

if [ -z "${BENCH_INFO[$BENCH]+_}" ]; then
  echo "ERROR: BENCH_INFO missing for benchmark: $BENCH"
  exit 1
fi

checkpoint_dir="$CHECKPOINT_BASE_DIR/$BENCH/$SIMPOINT"
if [ ! -d "$checkpoint_dir" ]; then
  echo "ERROR: Checkpoint directory not found: $checkpoint_dir"
  exit 1
fi

parse_bench_info() {
  local bench_name=$1
  local bench_info=$2
  local -n out_binary_ref=$3
  local -n out_args_ref=$4
  local -n out_mem_ref=$5

  local -a bench_parts=()
  IFS='|' read -r -a bench_parts <<< "$bench_info"

  case ${#bench_parts[@]} in
    3)
      out_binary_ref="${bench_parts[0]}"
      out_args_ref="${bench_parts[1]}"
      out_mem_ref="${bench_parts[2]}"
      ;;
    *)
      echo "ERROR: Invalid BENCH_INFO format for $bench_name: $bench_info"
      exit 1
      ;;
  esac
}

get_profile_settings() {
  local profile_name=$1
  local -n config_ref=$2
  local -n cpu_type_ref=$3
  local -n ruby_ref=$4

  case "$profile_name" in
    mem)
      config_ref="$GEM5_CONFIG_BASIC"
      cpu_type_ref="o3"
      ruby_ref="false"
      ;;
    mem-minor)
      config_ref="$GEM5_CONFIG_BASIC"
      cpu_type_ref="minor"
      ruby_ref="false"
      ;;
    mem-minor-ruby)
      config_ref="$GEM5_CONFIG_RUBY_SINGLE"
      cpu_type_ref="minor"
      ruby_ref="true"
      ;;
    *)
      echo "ERROR: Unsupported profile name: $profile_name"
      exit 1
      ;;
  esac
}

cleanup_build_dir() {
  local profile_name=$1
  local build_dir="$GEM5_DIR/build-${profile_name}-inst"

  if [ "$KEEP_BUILDS" = false ] && [ -d "$build_dir" ]; then
    rm -rf "$build_dir"
  fi
}

BENCH_BINARY=""
BENCH_ARGS=""
BENCH_MEM=""
parse_bench_info "$BENCH" "${BENCH_INFO[$BENCH]}" BENCH_BINARY BENCH_ARGS BENCH_MEM

if [ ! -f "$BENCH_BINARY" ]; then
  echo "ERROR: Benchmark binary not found: $BENCH_BINARY"
  exit 1
fi

echo "========================================================================"
echo "Generating memory-intensive universal profiles"
echo "Benchmark    : $BENCH"
echo "Simpoint     : $SIMPOINT"
echo "Checkpoint   : $checkpoint_dir"
echo "Profiles dir : $PROFILE_DIR"
echo "Cache sizes  : L1D=$L1D_SIZE L1I=$L1I_SIZE L2=$L2_SIZE"
echo "Profiles     : ${profiles[*]}"
echo "========================================================================"
echo ""

cd "$GEM5_DIR"

build_roots=""
for profile_name in "${profiles[@]}"; do
  build_dir="build-${profile_name}-inst"
  if [ -n "$build_roots" ]; then
    build_roots="${build_roots},${build_dir}"
  else
    build_roots="${build_dir}"
  fi
done
export GEM5_BUILD_ROOTS="$build_roots"

echo "Step 1: Building gem5.inst binaries"
declare -A build_pids=()

for profile_name in "${profiles[@]}"; do
  build_dir="build-${profile_name}-inst"
  inst_binary="$GEM5_DIR/${build_dir}/X86/gem5.inst"
  build_log="$BUILD_LOG_DIR/build-inst-${profile_name}.log"

  if [ -f "$inst_binary" ]; then
    echo "  [$profile_name] gem5.inst already exists, skipping build"
    continue
  fi

  echo "  [$profile_name] building $build_dir/X86/gem5.inst"
  scons "${build_dir}/X86/gem5.inst" -j"$SCONS_JOBS" > "$build_log" 2>&1 &
  build_pids["$profile_name"]=$!
done

build_failed=0
for profile_name in "${profiles[@]}"; do
  build_dir="build-${profile_name}-inst"
  inst_binary="$GEM5_DIR/${build_dir}/X86/gem5.inst"
  if [ -n "${build_pids[$profile_name]:-}" ]; then
    if ! wait "${build_pids[$profile_name]}"; then
      echo "ERROR: Build failed for $profile_name (check $BUILD_LOG_DIR/build-inst-${profile_name}.log)"
      build_failed=1
      continue
    fi
  fi

  if [ ! -f "$inst_binary" ]; then
    echo "ERROR: Missing gem5.inst binary for $profile_name"
    build_failed=1
  fi
done

if [ "$build_failed" -ne 0 ]; then
  exit 1
fi

echo ""
echo "Step 2: Running instrumented simulations and merging profiles"

for profile_name in "${profiles[@]}"; do
  build_dir="build-${profile_name}-inst"
  inst_binary="$GEM5_DIR/${build_dir}/X86/gem5.inst"
  profraw_file="$PROFILE_DIR/${profile_name}.profraw"
  profdata_file="$PROFILE_DIR/${profile_name}.profdata"
  run_log="$RUN_LOG_DIR/run-${profile_name}.log"
  merge_log="$MERGE_LOG_DIR/merge-${profile_name}.log"
  run_dir="$RUNDIR_BASE/${profile_name}"

  if [ -s "$profdata_file" ]; then
    echo "  [$profile_name] profdata already exists, skipping run"
    cleanup_build_dir "$profile_name"
    continue
  fi

  profile_config=""
  cpu_type=""
  use_ruby="false"
  get_profile_settings "$profile_name" profile_config cpu_type use_ruby

  echo "  [$profile_name] running checkpointed profile collection"

  cmd=(
    "$inst_binary"
    -r
    "--outdir=$run_dir"
    "$profile_config"
    --binary "$BENCH_BINARY"
    "--args=$BENCH_ARGS"
    --restore-from "$checkpoint_dir"
    --cpu-type "$cpu_type"
    --mem-size "$BENCH_MEM"
    --interval "$INTERVAL"
    --warmup-interval "$WARMUP_INTERVAL"
    --l1d-size "$L1D_SIZE"
    --l1i-size "$L1I_SIZE"
    --l2-size "$L2_SIZE"
  )

  if [ "$use_ruby" = true ]; then
    cmd+=(--num-l2-banks "$NUM_L2_BANKS")
  fi

  if ! LLVM_PROFILE_FILE="$profraw_file" "${cmd[@]}" > "$run_log" 2>&1; then
    echo "ERROR: Profile run failed for $profile_name (check $run_log)"
    exit 1
  fi

  if [ ! -f "$profraw_file" ]; then
    echo "ERROR: Missing profraw file for $profile_name: $profraw_file"
    exit 1
  fi

  if ! llvm-profdata merge -output="$profdata_file" "$profraw_file" > "$merge_log" 2>&1; then
    echo "ERROR: llvm-profdata merge failed for $profile_name (check $merge_log)"
    exit 1
  fi

  if [ ! -s "$profdata_file" ]; then
    echo "ERROR: Missing profdata file for $profile_name: $profdata_file"
    exit 1
  fi

  cleanup_build_dir "$profile_name"
  echo "  [$profile_name] wrote $profdata_file"
done

echo ""
echo "========================================================================"
echo "Memory-intensive profile generation complete"
echo "========================================================================"
for profile_name in "${profiles[@]}"; do
  echo "  - $PROFILE_DIR/${profile_name}.profdata"
done
