#!/usr/bin/env bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/init.sh"

if [ -n "${REPO_DIR:-}" ]; then
  cd "$REPO_DIR" || exit 1
fi

if [ -z "${SPEC_BUILT_DIR:-}" ]; then
  echo "[ERROR] SPEC_BUILT_DIR environment variable is not set. Please set it before running this script."
  exit 1
fi

if [ -z "${SIMPOINT_BIN:-}" ]; then
  echo "[ERROR] SIMPOINT_BIN environment variable is not set. Please set it before running this script."
  exit 1
fi

if [ ! -x "$SIMPOINT_BIN" ]; then
  echo "[ERROR] SimPoint binary is not executable or not found: $SIMPOINT_BIN"
  exit 1
fi

##  "625.x264_s.1               |$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL                    |           --pass 2 --stats x264_stats.log --bitrate 1000 --dumpyuv 200 --frames 1000 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720"
##    "625.x264_s.2               |$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL                    |           --seek 500 --dumpyuv 200 --frames 1250 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720"

RUN_LABEL=gem5_profile_x86-m64

benchmarks=(
  "600.perlbench_s.0          |$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL        |            -I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/checkspam.pl 2500 5 25 11 150 1 1 1 1"
  "600.perlbench_s.1          |$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL        |            -I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/diffmail.pl 4 800 10 17 19 300"
  "600.perlbench_s.2          |$SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/perlbench_s_base.$RUN_LABEL        |            -I $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/lib  $SPEC_BUILT_DIR/600.perlbench_s/run/run_base_refspeed_$RUN_LABEL.0000/splitmail.pl 6400 12 26 16 100 0"
  "602.gcc_s.0                |$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL                     |           $SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -fipa-pta -o gcc-pp.opts-O5_-fipa-pta.s"
  "602.gcc_s.1                |$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL                     |           $SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=1000 -fselective-scheduling -fselective-scheduling2 -o gcc-pp.opts-O5_-finline-limit_1000_-fselective-scheduling_-fselective-scheduling2.s"
  "602.gcc_s.2                |$SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/sgcc_base.$RUN_LABEL                     |           $SPEC_BUILT_DIR/602.gcc_s/run/run_base_refspeed_$RUN_LABEL.0000/gcc-pp.c -O5 -finline-limit=24000 -fgcse -fgcse-las -fgcse-lm -fgcse-sm -o gcc-pp.opts-O5_-finline-limit_24000_-fgcse_-fgcse-las_-fgcse-lm_-fgcse-sm.s"
  "605.mcf_s                  |$SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/mcf_s_base.$RUN_LABEL                    |           $SPEC_BUILT_DIR/605.mcf_s/run/run_base_refspeed_$RUN_LABEL.0000/inp.in"
  "620.omnetpp_s              |$SPEC_BUILT_DIR/620.omnetpp_s/run/run_base_refspeed_$RUN_LABEL.0000/omnetpp_s_base.$RUN_LABEL            |           -c General -r 0"
  "623.xalancbmk_s            |$SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalancbmk_s_base.$RUN_LABEL        |           -v $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/t5.xml $SPEC_BUILT_DIR/623.xalancbmk_s/run/run_base_refspeed_$RUN_LABEL.0000/xalanc.xsl"
  "625.x264_s.0               |$SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/x264_s_base.$RUN_LABEL                    |           --pass 1 --stats x264_stats.log --bitrate 1000 --frames 1000 -o BuckBunny_New.264 $SPEC_BUILT_DIR/625.x264_s/run/run_base_refspeed_$RUN_LABEL.0000/BuckBunny.yuv 1280x720"
  "631.deepsjeng_s            |$SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/deepsjeng_s_base.$RUN_LABEL        |           $SPEC_BUILT_DIR/631.deepsjeng_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.txt"
  "641.leela_s                |$SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/leela_s_base.$RUN_LABEL                |           $SPEC_BUILT_DIR/641.leela_s/run/run_base_refspeed_$RUN_LABEL.0000/ref.sgf"
  "648.exchange2_s            |$SPEC_BUILT_DIR/648.exchange2_s/run/run_base_refspeed_$RUN_LABEL.0000/exchange2_s_base.$RUN_LABEL        |           6"
  "657.xz_s.0                 |$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL                      |           $SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cpu2006docs.tar.xz 6643 055ce243071129412e9dd0b3b69a21654033a9b723d874b2015c774fac1553d9713be561ca86f74e4f16f22e664fc17a79f30caa5ad2c04fbc447549c2810fae 1036078272 1111795472 4"
  "657.xz_s.1                 |$SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/xz_s_base.$RUN_LABEL                      |           $SPEC_BUILT_DIR/657.xz_s/run/run_base_refspeed_$RUN_LABEL.0000/cld.tar.xz 1400 19cf30ae51eddcbefda78dd06014b4b96281456e078ca7c13e1c0c9e6aaea8dff3efb4ad6b0456697718cede6bd5454852652806a657bb56e07d61128434b474 536995164 539938872 8"
)

mkdir -p smpt_out

for entry in "${benchmarks[@]}"; do
  (
    IFS='|' read -r raw_name raw_exe raw_args <<< "$entry"
    name=$(echo "$raw_name" | xargs)
    exe=$(echo "$raw_exe" | xargs)
    args=$(echo "$raw_args" | xargs)
    bbv_out="smpt_out/${name}.bbv"
    bbv_gz="smpt_out/${name}.bbv.gz"
    simpoint_dir="smpt_out/${name}_simpoint"
    log_out="smpt_out/${name}.log"

    {
        echo "[INFO] Starting: $name"

        valgrind --tool=exp-bbv --bb-out-file="$bbv_out" --interval-size=100000000 "$exe" $args
        gzip -f "$bbv_out"

        "$SIMPOINT_BIN" -inputVectorsGzipped \
            -loadFVFile "$bbv_gz" -maxK 30 \
            -saveSimpoints "smpt_out/${name}.simpts" \
            -saveSimpointWeights "smpt_out/${name}.weights"

        mkdir -p "$simpoint_dir"
        mv "$bbv_gz" "smpt_out/${name}.simpts" "smpt_out/${name}.weights" "$simpoint_dir"
        echo "$exe $args" > "$simpoint_dir/args"

        echo "[DONE] Finished: $name"
    } > "$log_out" 2>&1
  ) &
done

# Wait for all background jobs to finish
wait
echo "[ALL DONE] All benchmarks completed."
