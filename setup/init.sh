#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
export RUN_LABEL="${RUN_LABEL:-gem5_profile_x86-m64}"
export SPEC_BUILT_DIR="${SPEC_BUILT_DIR:-$HOME/cpu2017/benchspec/CPU}"
export GEM5="${GEM5:-$REPO_DIR/gem5/build/X86/gem5.fast}"

export GEM5_CONFIG_BASIC="${GEM5_CONFIG_BASIC:-$REPO_DIR/gem5_config/run-basic.py}"
export GEM5_CONFIG_RUBY_4CORE="${GEM5_CONFIG_RUBY_4CORE:-$REPO_DIR/gem5_config/run-ruby-4core.py}"
export SIMPOINT_BIN="${SIMPOINT_BIN:-$REPO_DIR/SimPoint.3.2/bin/simpoint}"

export CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
export SIMPOINT_OUTPUT_DIR="${SIMPOINT_OUTPUT_DIR:-$REPO_DIR/smpt_out}"
export MIBENCH_BASE_DIR="${MIBENCH_BASE_DIR:-$HOME/MiBench}"
export MIBENCH_INPUTS_DIR="${MIBENCH_INPUTS_DIR:-$MIBENCH_BASE_DIR/inputs}"
export SPLASH_BASE_DIR="${SPLASH_BASE_DIR:-$HOME/Splash-3/codes}"
export OPT_REMARKS_ARCHIVE_DIR="${OPT_REMARKS_ARCHIVE_DIR:-$REPO_DIR/opt_remarks}"
export RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/results}"
export RESULTS_DATA_DIR="${RESULTS_DATA_DIR:-$RESULTS_DIR/data}"
export RESULTS_FIGS_DIR="${RESULTS_FIGS_DIR:-$RESULTS_DIR/figs}"
export RESULTS_LOGS_DIR="${RESULTS_LOGS_DIR:-$RESULTS_DIR/logs}"
export RESULTS_RUNDIR_DIR="${RESULTS_RUNDIR_DIR:-$RESULTS_DIR/rundir}"

mkdir -p "$RESULTS_DATA_DIR" "$RESULTS_FIGS_DIR" "$RESULTS_LOGS_DIR" "$RESULTS_RUNDIR_DIR"

copy_if_exists() {
    local src=$1
    local dst=$2

    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -fR "$src" "$dst"
    else
        echo "[WARN] Missing runtime file: $src" >&2
    fi
}

stage_spec_runtime_files() {
    local perl_dir="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_${RUN_LABEL}.0000"
    local omnet_dir="$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_${RUN_LABEL}.0000"
    local exchange_dir="$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_${RUN_LABEL}.0000"

    copy_if_exists "$perl_dir/cpu2017_mhonarc.rc" "$REPO_DIR/cpu2017_mhonarc.rc"
    copy_if_exists "$perl_dir/checkspam.in" "$REPO_DIR/checkspam.in"
    copy_if_exists "$omnet_dir/ned" "$REPO_DIR/ned"
    copy_if_exists "$omnet_dir/omnetpp.ini" "$REPO_DIR/omnetpp.ini"
    copy_if_exists "$exchange_dir/puzzles.txt" "$REPO_DIR/puzzles.txt"
}

if [ "${SET_PERF_EVENT_PARANOID:-false}" = "true" ]; then
    echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid >/dev/null
fi

if [ "${STAGE_SPEC_RUNTIME_FILES:-false}" = "true" ]; then
    stage_spec_runtime_files
fi
