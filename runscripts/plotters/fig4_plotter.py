#!/usr/bin/env python3
"""
Extract statistics from gem5 simulation results for different benchmarks and simpoints.
Outputs a CSV file with statistics per benchmark/simpoint and summary statistics.
"""

import os
import re
import csv
from collections import defaultdict
from pathlib import Path
import matplotlib.pyplot as plt
import matplotlib

# Configuration
BENCHMARKS = [
    "631.deepsjeng_s",
    "648.exchange2_s",
    "641.leela_s",
    "600.perlbench_s.0",
    "625.x264_s.0",
    "620.omnetpp_s",
    "657.xz_s.0",
    "602.gcc_s.0",
    "623.xalancbmk_s",
    "605.mcf_s"
]

# Statistics to extract (fixed two stats)
STATS_TO_EXTRACT = [
    "board.cache_hierarchy.l2-cache-0.ReadSharedReq.misses::total",
    "board.cache_hierarchy.membus.transDist::WritebackDirty",
]

# Display names for statistics (used in graphs)
STAT_DISPLAY_NAMES = {
    "board.cache_hierarchy.l2-cache-0.ReadSharedReq.misses::total": "L2 read misses",
    "board.cache_hierarchy.membus.transDist::WritebackDirty": "Memory writebacks",
}

# Graph configuration
FONT_SIZE = 24
FIGURE_SIZE = (12, 5)  # width, height

REPO_DIR = os.environ.get("REPO_DIR", os.getcwd())
DEFAULT_RUNDIR_DIR = os.environ.get("RESULTS_RUNDIR_DIR", os.path.join(REPO_DIR, "results", "rundir"))
BASE_DIR = os.environ.get("BENCHMARK_STATS_BASE_DIR", os.path.join(DEFAULT_RUNDIR_DIR, "speedup-bench"))
OUTPUT_DATA_DIR = os.environ.get("RESULTS_DATA_DIR", os.path.join(REPO_DIR, "results", "data"))
OUTPUT_FIGS_DIR = os.environ.get("RESULTS_FIGS_DIR", os.path.join(REPO_DIR, "results", "figs"))
OUTPUT_CSV = os.path.join(OUTPUT_DATA_DIR, "fig4_data.csv")


def parse_stat_value(value):
    """Convert CSV value to float; return None for empty/invalid values."""
    if value is None:
        return None
    value = str(value).strip()
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load_data_from_csv(csv_file):
    """Load raw and summary rows from an existing fig4 data CSV."""
    if not os.path.exists(csv_file):
        return [], []

    data = []
    summary_data = []

    with open(csv_file, "r", newline="") as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            benchmark = (row.get("benchmark") or "").strip()
            simpoint = (row.get("simpoint") or "").strip()

            # Skip separator/blank lines.
            if not benchmark or not simpoint:
                continue

            parsed_row = {
                "benchmark": benchmark,
                "simpoint": simpoint,
            }
            for stat_name in STATS_TO_EXTRACT:
                parsed_row[stat_name] = parse_stat_value(row.get(stat_name))

            if simpoint in {"AVERAGE", "MAX"}:
                summary_data.append(parsed_row)
            else:
                data.append(parsed_row)

    return data, summary_data


def extract_stat_from_file(stats_file, stat_name):
    """
    Extract a specific statistic from a stats.txt file.
    Returns the second occurrence of the stat (as per user requirement).
    """
    occurrences = []

    try:
        with open(stats_file, 'r') as f:
            for line in f:
                # Match lines like: "stat_name     value     # comment"
                if stat_name in line:
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] == stat_name:
                        try:
                            value = float(parts[1])
                            occurrences.append(value)
                        except ValueError:
                            continue
    except FileNotFoundError:
        return None

    # Return the second occurrence if it exists, otherwise None
    if len(occurrences) >= 2:
        return occurrences[1]  # Second occurrence (index 1)
    elif len(occurrences) == 1:
        print(f"Warning: Only one occurrence found in {stats_file}")
        return occurrences[0]
    else:
        return None


def find_simpoints(benchmark):
    """Find all simpoint numbers for a given benchmark."""
    simpoints = []
    pattern = re.compile(rf"^{re.escape(benchmark)}-(\d+)-pgo-baseline-iter1$")

    try:
        for dirname in os.listdir(BASE_DIR):
            match = pattern.match(dirname)
            if match:
                simpoint_num = int(match.group(1))
                simpoints.append(simpoint_num)
    except FileNotFoundError:
        print(f"Error: Base directory {BASE_DIR} not found")
        return []

    return sorted(simpoints)


def extract_all_stats():
    """Extract all statistics for all benchmarks and simpoints."""
    data = []

    for benchmark in BENCHMARKS:
        print(f"Processing {benchmark}...")
        simpoints = find_simpoints(benchmark)

        if not simpoints:
            print(f"  Warning: No simpoints found for {benchmark}")
            continue

        print(f"  Found {len(simpoints)} simpoints: {simpoints}")

        for simpoint in simpoints:
            dir_name = f"{benchmark}-{simpoint}-pgo-baseline-iter1"
            stats_file = os.path.join(BASE_DIR, dir_name, "stats.txt")

            row = {
                'benchmark': benchmark,
                'simpoint': simpoint
            }

            # Extract each statistic
            for stat_name in STATS_TO_EXTRACT:
                value = extract_stat_from_file(stats_file, stat_name)
                # Use shortened stat name as column header
                short_name = stat_name.split('.')[-1]  # e.g., "missRate::total"
                row[stat_name] = value

            data.append(row)

    return data


def calculate_summary_stats(data):
    """Calculate average and max values per benchmark for each stat."""
    # Group data by benchmark
    by_benchmark = defaultdict(list)
    for row in data:
        benchmark = row['benchmark']
        by_benchmark[benchmark].append(row)

    summary_rows = []

    for benchmark in BENCHMARKS:
        if benchmark not in by_benchmark:
            continue

        rows = by_benchmark[benchmark]

        # Calculate average
        avg_row = {
            'benchmark': benchmark,
            'simpoint': 'AVERAGE'
        }

        for stat_name in STATS_TO_EXTRACT:
            values = [row[stat_name] for row in rows if row[stat_name] is not None]
            if values:
                avg_row[stat_name] = sum(values) / len(values)
            else:
                avg_row[stat_name] = None

        summary_rows.append(avg_row)

        # Calculate max
        max_row = {
            'benchmark': benchmark,
            'simpoint': 'MAX'
        }

        for stat_name in STATS_TO_EXTRACT:
            values = [row[stat_name] for row in rows if row[stat_name] is not None]
            if values:
                max_row[stat_name] = max(values)
            else:
                max_row[stat_name] = None

        summary_rows.append(max_row)

    return summary_rows


def write_csv(data, summary_data, output_file):
    """Write data and summary statistics to a CSV file."""
    if not data:
        print("No data to write!")
        return

    # Prepare column headers
    fieldnames = ['benchmark', 'simpoint'] + STATS_TO_EXTRACT

    with open(output_file, 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()

        # Write data grouped by benchmark
        for benchmark in BENCHMARKS:
            # Write individual simpoint data
            benchmark_rows = [row for row in data if row['benchmark'] == benchmark]
            for row in benchmark_rows:
                writer.writerow(row)

            # Write summary rows for this benchmark
            benchmark_summary = [row for row in summary_data if row['benchmark'] == benchmark]
            for row in benchmark_summary:
                writer.writerow(row)

            # Add blank line between benchmarks
            if benchmark != BENCHMARKS[-1]:
                writer.writerow({})

    print(f"\nResults written to: {output_file}")


def plot_normalized_stats(summary_data):
    """
    Generate combined bar+line plot with dual y-axes for two statistics.
    """
    # Set matplotlib font sizes
    matplotlib.rcParams.update({
        'font.size': FONT_SIZE,
        'axes.titlesize': FONT_SIZE,
        'axes.labelsize': FONT_SIZE,
        'xtick.labelsize': FONT_SIZE,
        'ytick.labelsize': FONT_SIZE,
        'legend.fontsize': FONT_SIZE,
    })

    # Extract AVERAGE rows only
    avg_data = [row for row in summary_data if row['simpoint'] == 'AVERAGE']

    if not avg_data:
        print("No average data to plot!")
        return

    # Function to extract numeric prefix from benchmark name
    def extract_number(benchmark_name):
        match = re.match(r'^(\d+)', benchmark_name)
        return match.group(1) if match else benchmark_name

    print("Generating combined bar+line plot...")

    # Extract both statistics
    l2_stat_name = "board.cache_hierarchy.l2-cache-0.ReadSharedReq.misses::total"  # Bar (primary)
    wb_stat_name = "board.cache_hierarchy.membus.transDist::WritebackDirty"  # Line (secondary)

    benchmarks = []
    l2_values = []
    wb_values = []

    for benchmark in BENCHMARKS:
        bench_data = [row for row in avg_data if row['benchmark'] == benchmark]
        if bench_data and bench_data[0][l2_stat_name] is not None:
            benchmarks.append(benchmark)
            l2_values.append(bench_data[0][l2_stat_name])
            # Handle missing WritebackDirty values (treat as 0)
            wb_val = bench_data[0][wb_stat_name]
            wb_values.append(wb_val if wb_val is not None else 0.0)

    if not l2_values or not wb_values:
        print("  Warning: No data found for one or both statistics")
        return

    # Normalize both statistics (exclude 0 values when finding min)
    min_l2 = min(l2_values)
    min_wb = min([v for v in wb_values if v > 0]) if any(v > 0 for v in wb_values) else 1.0

    normalized_l2 = [v / (min_l2 * 1000) for v in l2_values]
    normalized_wb = [v / (min_wb * 1000) if v > 0 else 0.0 for v in wb_values]

    # Convert benchmark names to numbers only
    benchmark_labels = [extract_number(b) for b in benchmarks]

    # Create figure with primary axis
    fig, ax1 = plt.subplots(figsize=(12, 5))

    # Plot bar chart on primary axis (left y-axis) - L2 read misses
    bar_color = '#5B8FF9'  # Modern blue
    bars = ax1.bar(benchmark_labels, normalized_l2, alpha=1.0, color=bar_color,
                   label=STAT_DISPLAY_NAMES[l2_stat_name], zorder=2)

    # Primary y-axis configuration (L2 misses)
    ax1.set_xlabel('Benchmark', fontsize=24)
    ax1.set_ylabel('Normalized \nL2 misses (K)', fontsize=24)
    ax1.set_ylim(0, 9)
    ax1.set_yticks([0, 3, 6, 9])
    ax1.tick_params(axis='y', labelsize=24, direction='out')

    # Create secondary y-axis (right)
    ax2 = ax1.twinx()

    # Plot line on secondary axis (right y-axis) - Memory writebacks
    line_color = '#FA8072'  # Salmon/coral
    line = ax2.plot(benchmark_labels, normalized_wb, marker='o', linewidth=2,
                    markersize=8, color=line_color, label=STAT_DISPLAY_NAMES[wb_stat_name], zorder=3)

    # Secondary y-axis configuration (Memory writebacks)
    ax2.set_ylabel('Normalized memory\nwritebacks (K)', fontsize=24)
    ax2.set_ylim(0, 4.0)
    ax2.set_yticks([0, 1.0, 2.0, 3.0, 4.0])
    ax2.tick_params(axis='y', labelsize=24, direction='out')

    # X-axis configuration
    ax1.tick_params(axis='x', direction='out', labelsize=24)
    ax1.tick_params(axis='both', which='minor', direction='in')
    ax1.minorticks_on()
    plt.xticks(rotation=0, fontsize=24)

    # Reduce margins on x-axis
    ax1.margins(x=0.01)

    # Grid (on primary axis, behind everything)
    ax1.grid(True, alpha=0.3, zorder=1)
    ax1.set_axisbelow(True)

    # Legend - place outside plot at top center
    # Combine both legend entries
    handles = [bars, line[0]]
    labels = [STAT_DISPLAY_NAMES[l2_stat_name], STAT_DISPLAY_NAMES[wb_stat_name]]
    ax1.legend(handles, labels, loc='upper center', bbox_to_anchor=(0.5, 1.28),
              ncol=2, fontsize=24, frameon=False)

    # Tight layout to prevent label cutoff
    plt.tight_layout()

    # Save the figure as PNG and PDF
    output_png = os.path.join(OUTPUT_FIGS_DIR, "fig4.png")
    output_pdf = os.path.join(OUTPUT_FIGS_DIR, "fig4.pdf")
    plt.savefig(output_png, dpi=300, bbox_inches='tight')
    plt.savefig(output_pdf, dpi=300, bbox_inches='tight')
    plt.close()

    print(f"  Saved to: {output_png}")
    print(f"  Saved to: {output_pdf}")


def main():
    print("="*80)
    print("Extracting gem5 statistics from benchmark simulations")
    print("="*80)
    print(f"Base directory: {BASE_DIR}")
    print(f"Benchmarks: {', '.join(BENCHMARKS)}")
    print(f"Statistics to extract: {len(STATS_TO_EXTRACT)}")
    for stat in STATS_TO_EXTRACT:
        print(f"  - {stat}")
    print("="*80)
    print()

    # Create output directories if they don't exist
    os.makedirs(OUTPUT_DATA_DIR, exist_ok=True)
    os.makedirs(OUTPUT_FIGS_DIR, exist_ok=True)

    data = []
    summary_data = []

    if os.path.isdir(BASE_DIR):
        # Preferred path: regenerate stats from gem5 outputs.
        data = extract_all_stats()
        if data:
            print(f"\nExtracted data for {len(data)} simpoint runs")
            summary_data = calculate_summary_stats(data)
            print(f"Calculated summary statistics for {len(summary_data)} entries")
            write_csv(data, summary_data, OUTPUT_CSV)
        else:
            print("No data extracted from rundir; trying existing CSV fallback...")
    else:
        print(f"Rundir not found ({BASE_DIR}); trying existing CSV fallback...")

    if not data:
        data, summary_data = load_data_from_csv(OUTPUT_CSV)
        if not data and not summary_data:
            print("No data available from rundir or CSV fallback!")
            return
        if not summary_data and data:
            summary_data = calculate_summary_stats(data)
        print(f"Loaded fallback CSV data from: {OUTPUT_CSV}")
        print(f"Loaded {len(data)} simpoint rows and {len(summary_data)} summary rows")

    # Generate plots
    print("\n" + "="*80)
    print("Generating normalized plots...")
    print("="*80)
    plot_normalized_stats(summary_data)

    print("\n" + "="*80)
    print("Done!")
    print(f"Data directory: {OUTPUT_DATA_DIR}")
    print(f"Figures directory: {OUTPUT_FIGS_DIR}")
    print("="*80)


if __name__ == "__main__":
    main()
