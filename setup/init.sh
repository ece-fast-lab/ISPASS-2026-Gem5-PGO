#!/usr/bin/env bash

INIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd "$INIT_SCRIPT_DIR/.." && pwd)"

# Checkpoint directory (if generating your own)
# export CHECKPOINT_BASE_DIR="${CHECKPOINT_BASE_DIR:-$REPO_DIR/ckpts}"
# Checkpoint directory (if using prebuilt checkpoints)
export CHECKPOINT_BASE_DIR="/fast-lab-share/sa10/spec2017-ckpts"

# PGO-gem5 binary directory (if building your own PGO-gem5 binaries)
# export PGO_BINS_DIR="$REPO_DIR/pgo_bins/"
# PGO-gem5 binary directory (if using prebuilt PGO-gem5 binaries)
PGO_BINS_DIR="${PGO_BINS_DIR:-/pgo_bins/}"

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

if ! declare -p BENCH_INFO >/dev/null 2>&1; then

    # Shared benchmark lists
    # SPEC:
    # Format in BENCH_INFO: "binary|args|mem"
    declare -ga SPEC_BENCHMARKS_ALL=(
        "600.perlbench_s.0"
        "600.perlbench_s.1"
        "600.perlbench_s.2"
        "602.gcc_s.0"
        "602.gcc_s.1"
        "602.gcc_s.2"
        "605.mcf_s"
        "620.omnetpp_s"
        "623.xalancbmk_s"
        "625.x264_s.0"
        "631.deepsjeng_s"
        "641.leela_s"
        "648.exchange2_s"
        "657.xz_s.0"
        "657.xz_s.1"
    )

    declare -ga SPEC_BENCHMARKS_TOP10=(
        "600.perlbench_s.0"
        "602.gcc_s.0"
        "605.mcf_s"
        "620.omnetpp_s"
        "623.xalancbmk_s"
        "625.x264_s.0"
        "631.deepsjeng_s"
        "641.leela_s"
        "648.exchange2_s"
        "657.xz_s.0"
    )

    # MiBench:
    # Format in BENCH_INFO: "binary|args|mem"
    declare -ga MIBENCH_BENCHMARKS_ALL=(
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

    # Splash-3:
    # Format in BENCH_INFO: "binary|args|stdin_file|mem"
    declare -ga SPLASH_BENCHMARKS_ALL=(
        "fmm"
        "ocean"
        "radiosity"
        "raytrace"
        "volrend"
        "water-nsquared"
        "water-spatial"
        "cholesky"
        "fft"
        "lu"
        "radix"
    )

    # Splash-3 4-core:
    # Format in BENCH_INFO: "binary|args|stdin_file|mem"
    declare -ga SPLASH_4CORE_BENCHMARKS_ALL=(
        "fmm-4core"
        "ocean-4core"
        "radiosity-4core"
        "raytrace-4core"
        "volrend-4core"
        "water-nsquared-4core"
        "water-spatial-4core"
        "cholesky-4core"
        "fft-4core"
        "lu-4core"
        "radix-4core"
    )

    declare -gA SPLASH_4CORE_TO_BASE_MAP=(
        ["fmm-4core"]="fmm"
        ["ocean-4core"]="ocean"
        ["radiosity-4core"]="radiosity"
        ["raytrace-4core"]="raytrace"
        ["volrend-4core"]="volrend"
        ["water-nsquared-4core"]="water-nsquared"
        ["water-spatial-4core"]="water-spatial"
        ["cholesky-4core"]="cholesky"
        ["fft-4core"]="fft"
        ["lu-4core"]="lu"
        ["radix-4core"]="radix"
    )

    # Shared benchmark metadata map.
    # SPEC entries: binary|args|mem
    # MiBench entries: binary|args|mem
    # Splash entries: binary|args|stdin_file|mem
    declare -gA BENCH_INFO

    BENCH_INFO["600.perlbench_s.0"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/checkspam.pl 2500 5 25 11 150 1 1 1 1|4GiB"
    BENCH_INFO["600.perlbench_s.1"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/diffmail.pl 4 800 10 17 19 300|4GiB"
    BENCH_INFO["600.perlbench_s.2"]="$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL|-I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/splitmail.pl 6400 12 26 16 100 0|4GiB"
    BENCH_INFO["602.gcc_s.0"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -fipa-pta -o gcc-pp.opts-O5_-fipa-pta.s|8GiB"
    BENCH_INFO["602.gcc_s.1"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=1000 -fselective-scheduling -fselective-scheduling2 -o gcc-pp.opts-O5_-finline-limit_1000_-fselective-scheduling_-fselective-scheduling2.s|4GiB"
    BENCH_INFO["602.gcc_s.2"]="$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL|$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=24000 -fgcse -fgcse-las -fgcse-lm -fgcse-sm -o gcc-pp.opts-O5_-finline-limit_24000_-fgcse_-fgcse-las_-fgcse-lm_-fgcse-sm.s|8GiB"
    BENCH_INFO["605.mcf_s"]="$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/mcf_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/inp.in|16GiB"
    BENCH_INFO["620.omnetpp_s"]="$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_$RUN_LABEL.0000/omnetpp_s_base.$RUN_LABEL|-c General -r 0|4GiB"
    BENCH_INFO["623.xalancbmk_s"]="$SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalancbmk_s_base.$RUN_LABEL|-v $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/t5.xml $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalanc.xsl|4GiB"
    BENCH_INFO["625.x264_s.0"]="$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL|--pass 1 --stats x264_stats.log --bitrate 1000 --frames 1000 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720|4GiB"
    BENCH_INFO["631.deepsjeng_s"]="$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/deepsjeng_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.txt|8GiB"
    BENCH_INFO["641.leela_s"]="$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/leela_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.sgf|4GiB"
    BENCH_INFO["648.exchange2_s"]="$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_$RUN_LABEL.0000/exchange2_s_base.$RUN_LABEL|6|4GiB"
    BENCH_INFO["657.xz_s.0"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cpu2006docs.tar.xz 6643 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 1036078272 1111795472 4|24GiB"
    BENCH_INFO["657.xz_s.1"]="$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL|$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cld.tar.xz 1400 19cf30ae51eddcbefda78dd06014b4b96281456e078ca7c13e1c0c9e6aaea8dff3efb4ad6b0456697718cede6bd5454852652806a657bb56e07d61128434b474 536995164 539938872 8|24GiB"

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
    BENCH_INFO["cjpeg_large"]="$MIBENCH_BASE_DIR/cjpeg_large|-dct int -progressive -opt -outfile /tmp/output_cjpeg.jpeg $MIBENCH_INPUTS_DIR/jpeg_input_large.ppm|4GiB"

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
fi

copy_required_spec_file() {
    local src=$1
    local dst=$2

    if [ -e "$dst" ]; then
        echo "[INFO] SPEC runtime file already present: $dst (skip)"
        return 0
    fi

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

# if ! stage_spec_runtime_files; then
#     return 1 2>/dev/null || exit 1
# fi
