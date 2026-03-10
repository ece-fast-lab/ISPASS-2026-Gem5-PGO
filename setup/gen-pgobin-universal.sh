#!/bin/bash

## Build universal-candidate PGO binaries from:
##   profiles/univ_cand/<name>.profdata
##
## For each profile:
## 1) Build build-<name>-pgo/X86/gem5.pgo
## 2) Copy to pgo_bins/univ_cand/<name>.pgo
## 3) Remove the temporary build directory

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/init.sh"

if [ -z "${REPO_DIR:-}" ]; then
  echo "ERROR: REPO_DIR environment variable is not set."
  exit 1
fi

GEM5_DIR="$REPO_DIR/gem5"
PROFILE_DIR="$REPO_DIR/profiles/univ_cand"
PGO_BINS_DIR="$REPO_DIR/pgo_bins/univ_cand"
LOG_DIR="${RESULTS_LOGS_DIR:-$REPO_DIR/results/logs}/pgo_build_logs"
SCONS_JOBS="${SCONS_JOBS:-75}"

mkdir -p "$LOG_DIR" "$PGO_BINS_DIR"

if [ ! -d "$PROFILE_DIR" ]; then
  echo "ERROR: Universal profile directory not found: $PROFILE_DIR"
  exit 1
fi

shopt -s nullglob
profiles=("$PROFILE_DIR"/*.profdata)
shopt -u nullglob

if [ "${#profiles[@]}" -eq 0 ]; then
  echo "ERROR: No profile files found in $PROFILE_DIR"
  exit 1
fi

echo "========================================================================"
echo "Building universal PGO binaries"
echo "Profiles dir : $PROFILE_DIR"
echo "Output dir   : $PGO_BINS_DIR"
echo "Log dir      : $LOG_DIR"
echo "========================================================================"
echo ""

cd "$GEM5_DIR" || exit 1

failed=0

for profile_path in "${profiles[@]}"; do
  name="$(basename "$profile_path" .profdata)"
  build_dir="build-${name}-pgo"
  pgo_binary="$GEM5_DIR/${build_dir}/X86/gem5.pgo"
  out_binary="$PGO_BINS_DIR/${name}.pgo"
  build_log="$LOG_DIR/build-${name}-pgo.log"

  echo "----------------------------------------"
  echo "Profile : $profile_path"
  echo "Build   : $build_dir"
  echo "Output  : $out_binary"
  echo "----------------------------------------"

  export GEM5_BUILD_ROOTS="$build_dir"

  if ! scons "${build_dir}/X86/gem5.pgo" -j"$SCONS_JOBS" > "$build_log" 2>&1; then
    echo "ERROR: Build failed for $name (log: $build_log)"
    if [ -d "$GEM5_DIR/$build_dir" ]; then
      rm -rf "$GEM5_DIR/$build_dir"
    fi
    failed=$((failed + 1))
    continue
  fi

  if [ ! -f "$pgo_binary" ]; then
    echo "ERROR: Missing binary for $name: $pgo_binary"
    echo "       Build log: $build_log"
    if [ -d "$GEM5_DIR/$build_dir" ]; then
      rm -rf "$GEM5_DIR/$build_dir"
    fi
    failed=$((failed + 1))
    continue
  fi

  binary_size=$(stat -c%s "$pgo_binary" 2>/dev/null || echo 0)
  if [ "$binary_size" -le 1048576 ]; then
    echo "ERROR: Binary too small for $name (${binary_size} bytes)"
    echo "       Build log: $build_log"
    if [ -d "$GEM5_DIR/$build_dir" ]; then
      rm -rf "$GEM5_DIR/$build_dir"
    fi
    failed=$((failed + 1))
    continue
  fi

  if ! cp "$pgo_binary" "$out_binary"; then
    echo "ERROR: Failed to copy output binary for $name"
    if [ -d "$GEM5_DIR/$build_dir" ]; then
      rm -rf "$GEM5_DIR/$build_dir"
    fi
    failed=$((failed + 1))
    continue
  fi

  if [ -d "$GEM5_DIR/$build_dir" ]; then
    rm -rf "$GEM5_DIR/$build_dir"
  fi

  echo "OK: Built $out_binary (${binary_size} bytes)"
  echo ""
done

echo "========================================================================"
if [ "$failed" -eq 0 ]; then
  echo "Universal PGO build complete: all profiles succeeded."
  exit 0
fi

echo "Universal PGO build complete with failures: $failed profile(s) failed."
exit 1
