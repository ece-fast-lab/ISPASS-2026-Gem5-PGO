import os
import argparse

from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.ruby.mesi_two_level_cache_hierarchy import (
    MESITwoLevelCacheHierarchy,
)
from gem5.components.memory import DualChannelDDR4_2400
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.resources.resource import BinaryResource, FileResource
from gem5.simulate.exit_event import ExitEvent
from gem5.simulate.simulator import Simulator
from gem5.utils.requires import requires
import m5
from m5.stats import dump, reset


parser = argparse.ArgumentParser(
    description="Run a single-core SE simulation with Ruby MESI Two-Level cache."
)
parser.add_argument(
    "--binary",
    type=str,
    required=True,
    help="Path to binary to run.",
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
    "--restore-from",
    type=str,
    default=None,
    help="Restore from checkpoint directory.",
)
parser.add_argument(
    "--interval",
    type=int,
    default=100000000,
    help="Profile interval in instructions after warmup.",
)
parser.add_argument(
    "--warmup-interval",
    type=int,
    default=1000000,
    help="Warmup interval in instructions before profiling.",
)
parser.add_argument(
    "--cpu-type",
    type=str,
    choices=[cpu_type.value for cpu_type in CPUTypes],
    default=CPUTypes.TIMING.value,
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
    default="2MiB",
    help="Size of shared L2 cache (default: 2MiB).",
)
parser.add_argument(
    "--num-l2-banks",
    type=int,
    default=1,
    help="Number of shared L2 banks (default: 1).",
)

args = parser.parse_args()
args.args = args.args.split(" ") if args.args else []
args.cpu_type = CPUTypes(args.cpu_type)

if args.restore_from is not None and not os.path.isdir(args.restore_from):
    raise FileNotFoundError(
        f"Checkpoint directory '{args.restore_from}' not found."
    )

binary = BinaryResource(local_path=args.binary)
stdin_file = None
if args.stdin:
    stdin_file = FileResource(local_path=args.stdin)

requires(isa_required=ISA.X86)

cache_hierarchy = MESITwoLevelCacheHierarchy(
    l1d_size=args.l1d_size,
    l1d_assoc=8,
    l1i_size=args.l1i_size,
    l1i_assoc=8,
    l2_size=args.l2_size,
    l2_assoc=16,
    num_l2_banks=args.num_l2_banks,
)
memory = DualChannelDDR4_2400(size=args.mem_size)
processor = SimpleProcessor(cpu_type=args.cpu_type, isa=ISA.X86, num_cores=1)

board = SimpleBoard(
    clk_freq="3GHz",
    processor=processor,
    memory=memory,
    cache_hierarchy=cache_hierarchy,
)

if stdin_file:
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

print("Using Ruby MESI Two-Level SE workload")
print(f"Binary: {args.binary}")
print(f"Arguments: {args.args}")
print(f"CPU type: {args.cpu_type.value}")
print(f"L1D: {args.l1d_size}, L1I: {args.l1i_size}, L2: {args.l2_size}")
print(f"L2 banks: {args.num_l2_banks}")

if args.restore_from:
    def max_inst():
        warmed_up = False
        while True:
            if warmed_up:
                print("end of profile interval")
                yield True
            else:
                print("end of warmup, starting profile interval")
                warmed_up = True
                simulator.schedule_max_insts(args.interval)
                dump()
                reset()
                yield False

    print(f"Restoring from checkpoint: {args.restore_from}")
    simulator = Simulator(
        board=board,
        checkpoint_path=args.restore_from,
        on_exit_event={ExitEvent.MAX_INSTS: max_inst()},
    )
    simulator.schedule_max_insts(args.warmup_interval)
    simulator.run()
    print(
        "Exiting after restore due to "
        f"{simulator.get_last_exit_event_cause()}"
    )
else:
    simulator = Simulator(board=board)
    simulator.run()
    print(f"Simulation completed. Exit cause: {simulator.get_last_exit_event_cause()}")
