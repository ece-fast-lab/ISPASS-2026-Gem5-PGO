import os
import argparse
from gem5.components.boards.simple_board import SimpleBoard
from gem5.components.cachehierarchies.ruby.mesi_two_level_cache_hierarchy import MESITwoLevelCacheHierarchy
from gem5.components.memory import DualChannelDDR4_2400
from gem5.components.processors.cpu_types import CPUTypes
from gem5.components.processors.simple_processor import SimpleProcessor
from gem5.isas import ISA
from gem5.resources.resource import (
    BinaryResource,
    FileResource
)
from gem5.simulate.simulator import Simulator
from gem5.utils.requires import requires
import m5.stats
import m5


# ---------------------- ARGUMENT PARSING ----------------------
parser = argparse.ArgumentParser(description="Run an SE MODE simulation with 4 cores and Ruby MESI Two-Level cache.")
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
    default=4,
    help="Number of L2 cache banks (default: 4).",
)

args = parser.parse_args()
args.args = args.args.split(" ") if args.args else []

args.cpu_type = CPUTypes(args.cpu_type)

# ---------------------- SETUP COMPONENTS ----------------------
binary = BinaryResource(local_path=args.binary)
stdin_file = None
if args.stdin:
    stdin_file = FileResource(local_path=args.stdin)

requires(isa_required=ISA.X86)

# Ruby-based MESI Two-Level Cache Hierarchy
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

# 4-core processor
processor = SimpleProcessor(cpu_type=args.cpu_type, isa=ISA.X86, num_cores=4)

board = SimpleBoard(
    clk_freq="3GHz",
    processor=processor,
    memory=memory,
    cache_hierarchy=cache_hierarchy,
)

# ---------------------- SET WORKLOAD ----------------------
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
simulator = Simulator(board=board)

print(f"Starting simulation with 4 cores and Ruby MESI Two-Level cache hierarchy")
print(f"CPU type: {args.cpu_type.value}")
print(f"L1D: {args.l1d_size}, L1I: {args.l1i_size}")
print(f"L2 (shared): {args.l2_size}")
print(f"L2 banks: {args.num_l2_banks}")

simulator.run()

print(f"Simulation completed. Exit cause: {simulator.get_last_exit_event_cause()}")
