#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check checkpoint directories if using prebuilt checkpoints
# export CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
export CHECKPOINT_BASE_DIR="/fast-lab-share/sa10/spec2017-ckpts"
# Check Benchmark directories
export SPEC_BUILT_DIR="${SPEC_BUILT_DIR:-$HOME/cpu2017/benchspec/CPU}"
export MIBENCH_BASE_DIR="${MIBENCH_BASE_DIR:-$HOME/MiBench}"
export MIBENCH_INPUTS_DIR="${MIBENCH_INPUTS_DIR:-$MIBENCH_BASE_DIR/inputs}"
export SPLASH_BASE_DIR="${SPLASH_BASE_DIR:-$HOME/Splash-3/codes}"


export REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
export RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
export GEM5="${GEM5:-$REPO_DIR/gem5/build/X86/gem5.fast}"

export GEM5_CONFIG_BASIC="${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}"
export GEM5_CONFIG_RUBY_4CORE="${GEM5_CONFIG_RUBY_4CORE:-$REPO_DIR/gem5_config/run-ruby-4core.py}"
export SIMPOINT_BIN="${SIMPOINT_BIN:-$REPO_DIR/SimPoint.3.2/bin/simpoint}"

export SIMPOINT_OUTPUT_DIR="${SIMPOINT_OUTPUT_DIR:-$REPO_DIR/smpt_out}"
export OPT_REMARKS_ARCHIVE_DIR="${OPT_REMARKS_ARCHIVE_DIR:-$REPO_DIR/opt_remarks}"
export RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/results}"
export RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$RESULTS_DIR/data}"
export RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$RESULTS_DIR/figs}"
export RESULTS_LOGS_DIR="${RESULTS_LOGS_DIR:-$RESULTS_DIR/logs}"
export RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$RESULTS_DIR/rundir}"

mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_LOGS_DIR" "$RESULTS_RUNDIR_DIR"

copy_required_spec_file() {
    local src=$1
    local dst=$2

    if [ ! -e "$src" ]; then
        echo "[ERROR] no spec build found: missing $src" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dst")"
    if ! cp -fR "$src" "$dst"; then
        echo "[ERROR] no spec build found: failed to copy $src" >&2
        return 1
    fi

    echo "[INFO] staged SPEC runtime file: $dst"
}

stage_spec_runtime_files() {
    local perl_dir="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_${RUN_LABEL}.0000"
    local omnet_dir="$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_${RUN_LABEL}.0000"
    local exchange_dir="$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_${RUN_LABEL}.0000"

    copy_required_spec_file "$perl_dir/cpu2017_mhonarc.rc" "$REPO_DIR/cpu2017_mhonarc.rc" || return 1
    copy_required_spec_file "$perl_dir/checkspam.in" "$REPO_DIR/checkspam.in" || return 1
    copy_required_spec_file "$omnet_dir/ned" "$REPO_DIR/ned" || return 1
    copy_required_spec_file "$omnet_dir/omnetpp.ini" "$REPO_DIR/omnetpp.ini" || return 1
    copy_required_spec_file "$exchange_dir/puzzles.txt" "$REPO_DIR/puzzles.txt" || return 1
}

if [ "${SET_PERF_EVENT_PARANOID:-false}" = "true" ]; then
    echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
fi

if [ "${STAGE_SPEC_RUNTIME_FILES:-true}" = "true" ]; then
    if ! stage_spec_runtime_files; then
        return 1 2>/dev/null || exit 1
    fi
else
    echo "[INFO] STAGE_SPEC_RUNTIME_FILES=false, skipping SPEC runtime file staging"
fi
