# gem5 Simpoints, and PGO flow

This repo contains flows for simulating on the latest stable gem5 version (24.1.0.2 at time of writing).

This setup has been tested for gem5 built for both X86 and ARM ISA simulation.

## Setup
- Follow the gem5 build instructions for your ISA of choice.
- Go to the SimPoint directory and run `make` to build the `simpoint` binary.
  - There are patches in this directory to make compilation possible on newer toolchains, so do not use the original SimPoint source -- it will not compile.
- Install a current version of valgrind. We use it for collecting the BBV traces
- The repo is setup for SPEC2017 IntSpeed benchmarks specifically. The resources folder contains the SPEC .cfg files for X86 and ARM. Please copy the files to the `config` directory of your SPEC2017 installation.
- Export the following environment variables:
  ```bash
  export SPEC_BUILT_DIR=<PATH_TO_SPEC_INSTALL>/benchspec/CPU
  export GEM5=<PATH_TO_GEM5.fast> (eg /home/user/gem5/build/X86/gem5.fast)
  export REPO_DIR=Absolute path to this repository (eg /home/user/gem5_profiling)
  ```
- build the SPEC2017 benchmarks, e.g. using the following command:
  ```
  runcpu --config=x86 --tune=base --action=runsetup intspeed
  ```
- Some SPEC benchmarks need files to be present in the directory they are invoked from. For this, we ln -s the files from the SPEC build directory to the root of this repository. Example below:
  ```
  ln -s $SPEC_BUILT_DIR/benchspec/CPU/600.perlbench_s/run/run_base_refspeed_gem5_profile_x86-m64.0000/cpu2017_mhonarc.rc ./cpu2017_mhonarc.rc
  ln -s $SPEC_BUILT_DIR/benchspec/CPU/600.perlbench_s/run/run_base_refspeed_gem5_profile_x86-m64.0000/checkspam.in ./checkspam.in
  ln -s $SPEC_BUILT_DIR/benchspec/CPU/620.omnetpp_s/run/run_base_refspeed_gem5_profile_x86-m64.0000/ned ./ned
  ln -s $SPEC_BUILT_DIR/benchspec/CPU/620.omnetpp_s/run/run_base_refspeed_gem5_profile_x86-m64.0000/omnetpp.ini ./omnetpp.ini
  ln -s $SPEC_BUILT_DIR/benchspec/CPU/648.exchange2_s/run/run_base_refspeed_gem5_profile_x86-m64.0000/puzzles.txt ./puzzles.txt
  ```

## Generating SPEC2017 Simpoints, and then Gem5 Checkpoints
- run the scripts from the root of this repository:
  ```bash
  ./flows/gen-simpoints.sh
  ```
- This will generate the simpoints and weights for each benchmark in the `simpoints` directory
- Now, generate the gem5 checkpoints for each benchmark, we use the X86KVM for fast generation of the simpoints, so this may need sudo:
  ```bash
  ./flows/gen-ckpts.sh
  ```
- This will generate the checkpoints in the `ckpts` directory, which corresponds to the simpoints generated in the previous step.

## Running PGO for gem5.
- Before running the PGO, check you can run the baseline. this assumes you have built gem5.fast
  ```bash
  ./flows/run-simpoints.sh base
  ```
- Now, we first compile gem5 for instrumentation. This is done by building N copies of gem5.instr, as copying doesnt work as the instrumentation build seems to hardcode where to store the profile data.
  ```bash
   export GEM5_BUILD_ROOTS=$(printf "600.perlbench_s.0-%s\n" {1..18} | sed 's/^/build-/' | paste -sd, -) ##  we use this var to have one build dir of gem5 per simpoint per benchmark. (eg perlbnech_s0 has 18 simpoints, so we have 18 builds of gem5.instr)
  ```
  - Use this snipped to build 8 in parallel (Adjust the number of jobs as needed):
  ```bash
    for i in {1..24}; do
        scons build-600.perlbench_s.0-$i/X86/gem5.inst -j8 &
        (( i % 8 == 0 )) && wait
    done
    wait
  ```
- Run the instrumented gem5 for each simpoint, this will generate the profile data in the corresponding build:
  ```bash
  ./flows/run-simpoints.sh inst
  ```
- Profiles are generated in `$REPO_DIR/profiles`. Clang profiler needs the process of merging multiple(or single) profraw files into a profdata file.
  ```bash
  ./flows/merge-profile.sh build-600.perlbench_s.0 24
  ```
- Now, build the gem5.pgo binary, which will use the profile data generated in the previous step:
  ```bash
    for i in {1..24}; do
      scons build-600.perlbench_s.0-$i/X86/gem5.pgo -j8 &
      (( i % 8 == 0 )) && wait
    done
    wait
  ```
- Now, run each simpoint with pgo binary:
  ```bash
  ./flows/run-simpoints.sh pgo
  ```

