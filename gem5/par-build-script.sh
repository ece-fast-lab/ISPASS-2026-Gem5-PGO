#!/bin/bash

MAX_JOBS=64  # Number of parallel scons jobs at once (tune for your disk)
JOBS_PER_SCONS=12  # Passed to scons via -j flag
COUNTER=0

for i in {1..18}; do
    scons build-600.perlbench_s.0-$i/X86/gem5.inst -j$JOBS_PER_SCONS &
    (( ++COUNTER % MAX_JOBS == 0 )) && wait
done

wait
