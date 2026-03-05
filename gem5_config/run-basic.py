import os
import argparse
from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.classic.private_l1_private_l2_cache_hierarchy import PrivateL1PrivateL2CacheHierarchy
from gem5.components.memory import DualChannelDDR4_2400
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.resources.resource import (
    SimpointResource,
    BinaryResource,
    FileResource
)
from gem5.simulate.simulator import Simulator
from gem5.utils.requires import requires
from gem5.simulate.exit_event import ExitEvent
import m5.stats
import m5
from m5.stats import (
    dump,
    reset,
)




# ---------------------- ARGUMENT PARSING ----------------------
parser = argparse.ArgumentParser(description="Run an SE MODE simulation.")
parser.add_argument(
    "--binary",
    type=str,
    default="gem5/tests/test-progs/hello/bin/arm/linux/hello",
    help="Path to binary to run.",
)
parser.add_argument(
    "--simpts"
    , type=str, default=None, help="Path to SimPoint  file."
)
parser.add_argument(
    "--interval",
    type=int, default=100000000, help="SimPoint interval in insts (default: 100 million)."
)
parser.add_argument(
    "--warmup-interval",
    type=int,
    default=1000000,
    help="Warmup interval in insts (default: 1 million).",
)

parser.add_argument(
    "--weights",
    type=str,
    default=None,
    help="Path to SimPoint weights file.",
)
## add argument for directory to store checkpoints
parser.add_argument(
    "--checkpoint-dir",
    type=str,
    default="checkpoints",
    help="Directory to store checkpoints.",
)
parser.add_argument(
    "--restore-from",
    type=str,
    default=None,
    help="Restore from checkpoint number (e.g., 1 = checkpoints/1/).",
)
parser.add_argument(
    "--args",
    type=str,
    default="",
    help="Arguments to pass to the binary as a string.",
)

parser.add_argument(
    "--stdin",
    type=str,
    default=None,
    help="Path to file to use as stdin for the binary.",
)

parser.add_argument(
    "--cpu-type",
    type=str,
    choices=[cpu_type.value for cpu_type in CPUTypes],
    default=CPUTypes.KVM.value,
)

parser.add_argument(
    "--mem-size",
    type=str,
    default="4GiB",
    help="Size of the memory (default: 4GiB).",
)

parser.add_argument(
    "--l1d-size",
    type=str,
    default="32KiB",
    help="Size of L1 data cache (default: 32KiB).",
)

parser.add_argument(
    "--l1i-size",
    type=str,
    default="32KiB",
    help="Size of L1 instruction cache (default: 32KiB).",
)

parser.add_argument(
    "--l2-size",
    type=str,
    default="256KiB",
    help="Size of L2 cache (default: 256KiB).",
)

args = parser.parse_args()
args.args = args.args.split(" ")

args.cpu_type = CPUTypes(args.cpu_type)
# ---------------------- CHECKPOINT HANDLING ----------------------
if args.restore_from is not None:
    if not os.path.isdir(args.restore_from):
        raise FileNotFoundError(f"Checkpoint directory '{args.restore_from}' not found.")

binary = BinaryResource(local_path=args.binary)
stdin_file = None
if args.stdin:
    stdin_file = FileResource(local_path=args.stdin)
requires(isa_required=ISA.X86)

cache_hierarchy = PrivateL1PrivateL2CacheHierarchy(
    l1d_size=args.l1d_size,
    l1i_size=args.l1i_size,
    l2_size=args.l2_size
)
memory = DualChannelDDR4_2400(size=args.mem_size)
processor = SimpleProcessor(cpu_type=args.cpu_type, isa=ISA.X86, num_cores=1)

board = SimpleBoard(
    clk_freq="3GHz",
    processor=processor,
    memory=memory,
    cache_hierarchy=cache_hierarchy,
)

### SSIMPOINT PARSING
if args.simpts and args.weights:
    ## read simpoints and weights from files
    intervals = []
    with open(args.simpts) as f:
        for line in f.readlines():
            intervals.append(int(line.strip().split(" ")[0]))
    weights = []
    with open(args.weights) as f:
        for line in f.readlines():
            weights.append(float(line.strip().split(" ")[0]))

    ## print a preview of the 2 lists
    print(f"Simpoints: {intervals[:5]} ... (total {len(intervals)})")
    print(f"Weights: {weights[:5]} ... (total {len(weights)})")

    # SimPoint workload
    print(f"Using SimPoint with binary {args.binary}, simpoints {args.simpts}, and weights {args.weights}")
    board.set_se_simpoint_workload(
        binary=binary,
        arguments=args.args,
        simpoint=SimpointResource(
        simpoint_interval=args.interval,
        warmup_interval=args.warmup_interval,
        simpoint_list=intervals,
        weight_list=weights,
        )
    )
else:
    # Regular SE workload
    print(f"Using SE workload with binary {args.binary} and arguments {args.args}")
    if stdin_file:
        print(f"Using stdin from file: {args.stdin}")
        board.set_se_binary_workload(
            binary=binary,
            arguments=args.args,
            stdin_file=stdin_file,
        )
    else:
        board.set_se_binary_workload(
            binary=binary,
            arguments=args.args,
        )

# ---------------------- SIMULATION ----------------------

if args.restore_from:
    # --------------- RESTORE MODE ----------------
    def max_inst():
        warmed_up = False
        while True:
            if warmed_up:
                print("end of SimPoint interval")
                yield True
            else:
                print("end of warmup, starting to simulate SimPoint")
                warmed_up = True
                simulator.schedule_max_insts(args.interval)
                dump()
                reset()
                yield False


    print(f"Restoring from checkpoint: {args.restore_from}")
    ## workload
    if stdin_file:
        print(f"Using stdin from file: {args.stdin}")
        board.set_se_binary_workload(
            binary=binary,
            arguments=args.args,
            stdin_file=stdin_file,
        )
    else:
        board.set_se_binary_workload(
            binary=binary,
            arguments=args.args,
        )
    simulator = Simulator(board=board, checkpoint_path=args.restore_from,
                        on_exit_event={ExitEvent.MAX_INSTS: max_inst()})
    print(f"Restoring from {args.restore_from}")
    simulator.schedule_max_insts(args.warmup_interval)

    # Run the simulation
    simulator.run()
    print(f"Exiting after restore from {args.restore_from} due to {simulator.get_last_exit_event_cause()}")

else:
    # --------------- REGULAR MODE ----------------
    if args.simpts and args.weights:
        # SimPoint mode - Dump + Checkpoint Loop For Generating Simpoint Checkpoints
        stat_cnt = 1
        def dump_period_generator():
            global stat_cnt
            while True:
                checkpoint_path = os.path.join(args.checkpoint_dir, str(stat_cnt))
                if not os.path.exists(args.checkpoint_dir):
                    os.makedirs(args.checkpoint_dir)
                print(f"Checkpointing to: {checkpoint_path}")
                m5.checkpoint(checkpoint_path)
                stat_cnt += 1
                if (stat_cnt > len(intervals)):
                    print("Reached the end of SimPoints, stopping simulation.")
                    yield True
                else:
                    yield False

        interval_count = 0
        def status_update_generator():
            global interval_count, intervals
            global stat_cnt
            while True:
                print(f"Current tick: {m5.curTick()}")
                print(f"Current interval count: {interval_count}")
                interval_count += 1
                sorted_intervals = sorted(intervals)
                ## next simpoint at
                print(f"Next simpoint at: {sorted_intervals[stat_cnt-1]}")
                simulator.schedule_max_insts(args.interval)
                yield False

        simulator = Simulator(
            board=board,
            on_exit_event={ExitEvent.SIMPOINT_BEGIN: dump_period_generator(), ExitEvent.MAX_INSTS: status_update_generator()}
        )
        simulator.schedule_max_insts(args.interval)
        simulator.run()
        cause = simulator.get_last_exit_event_cause()
        print(f"Exiting due to {cause}")
    else:
        # Regular SE mode - just run to completion
        simulator = Simulator(board=board)
        simulator.run()
        print(f"Exiting due to {simulator.get_last_exit_event_cause()}")