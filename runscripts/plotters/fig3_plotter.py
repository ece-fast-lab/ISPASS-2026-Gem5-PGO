#!/usr/bin/env python3

"""
Generate speedup heatmap from benchmark-level execution times.

This script:
1. Reads raw execution times from CSV (per simpoint)
2. Aggregates by benchmark (sums all simpoints)
3. Computes speedup matrix (baseline vs PGO)
4. Generates heatmap visualization
"""

import argparse
import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path
from matplotlib.patches import Rectangle
from matplotlib.lines import Line2D


def parse_args():
    parser = argparse.ArgumentParser(
        description='Generate speedup heatmap from benchmark-level execution times'
    )
    parser.add_argument(
        '--benchmarks',
        type=str,
        default='600.perlbench_s.0 602.gcc_s.0 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0',
        help='Space-separated list of benchmarks'
    )
    parser.add_argument(
        '--num-iterations',
        type=int,
        default=3,
        help='Number of iterations per run'
    )
    parser.add_argument(
        '--results-dir',
        type=str,
        default=None,
        help='Data directory (default: $RESULTS_DATA_DIR or $REPO_DIR/results/data)'
    )
    return parser.parse_args()


def load_raw_data(csv_file):
    """Load raw execution times CSV."""
    if not os.path.exists(csv_file):
        print(f"ERROR: CSV file not found: {csv_file}")
        sys.exit(1)

    df = pd.read_csv(csv_file)

    # Validate columns
    required_cols = ['simulated_benchmark', 'simpoint', 'pgo_benchmark', 'iteration', 'execution_time']
    missing_cols = set(required_cols) - set(df.columns)
    if missing_cols:
        print(f"ERROR: Missing columns in CSV: {missing_cols}")
        sys.exit(1)

    print(f"Loaded {len(df)} raw execution time records")
    return df


def aggregate_by_benchmark(df, benchmarks, num_iterations):
    """
    Aggregate simpoint-level times to benchmark-level.
    Sums execution times for all simpoints of each benchmark.
    """
    print("\nAggregating execution times by benchmark...")

    # Group by simulated_benchmark, pgo_benchmark, and iteration, then sum execution_time
    aggregated = df.groupby(
        ['simulated_benchmark', 'pgo_benchmark', 'iteration']
    )['execution_time'].sum().reset_index()

    aggregated.rename(columns={'execution_time': 'total_execution_time'}, inplace=True)

    print(f"Aggregated to {len(aggregated)} benchmark-level records")

    # Validate we have all expected combinations
    expected_records = len(benchmarks) * (len(benchmarks) + 1) * num_iterations  # +1 for baseline
    if len(aggregated) < expected_records:
        print(f"WARNING: Expected {expected_records} records, but got {len(aggregated)}")
        print("Some simulations may have failed or are incomplete")

    return aggregated


def compute_speedup_matrix(aggregated_df, benchmarks):
    """
    Compute speedup matrix from aggregated times.
    Speedup = baseline_time / pgo_time
    """
    print("\nComputing speedup matrix...")

    # Average across iterations
    avg_times = aggregated_df.groupby(
        ['simulated_benchmark', 'pgo_benchmark']
    )['total_execution_time'].mean().reset_index()

    # Create matrix: rows = simulated benchmark, cols = PGO benchmark
    matrix_data = []

    for sim_bench in benchmarks:
        row_data = {'simulated_benchmark': sim_bench}

        # Get baseline time for this simulated benchmark
        baseline_row = avg_times[
            (avg_times['simulated_benchmark'] == sim_bench) &
            (avg_times['pgo_benchmark'] == 'baseline')
        ]

        if len(baseline_row) == 0:
            print(f"ERROR: No baseline data found for {sim_bench}")
            continue

        baseline_time = baseline_row['total_execution_time'].values[0]

        # Compute speedup for each PGO benchmark
        for pgo_bench in benchmarks:
            pgo_row = avg_times[
                (avg_times['simulated_benchmark'] == sim_bench) &
                (avg_times['pgo_benchmark'] == pgo_bench)
            ]

            if len(pgo_row) == 0:
                print(f"WARNING: No PGO data found for sim={sim_bench}, pgo={pgo_bench}")
                row_data[pgo_bench] = np.nan
            else:
                pgo_time = pgo_row['total_execution_time'].values[0]
                speedup = baseline_time / pgo_time
                row_data[pgo_bench] = speedup

        matrix_data.append(row_data)

    matrix_df = pd.DataFrame(matrix_data)

    print(f"Created {len(matrix_df)} x {len(matrix_df.columns)-1} speedup matrix")

    return matrix_df, avg_times


def generate_heatmap(matrix_df, output_png, output_pdf):
    """Generate heatmap visualization."""
    print(f"\nGenerating heatmap: {output_png} and {output_pdf}")

    # Prepare data for heatmap (exclude simulated_benchmark column)
    heatmap_data = matrix_df.set_index('simulated_benchmark')

    # Compute average speedup for each simulated benchmark (row average)
    # This determines the ordering
    row_avg_speedup = heatmap_data.mean(axis=1).sort_values()

    # Order rows and columns by average simulated benchmark speedup (ascending)
    ordered_benchmarks = row_avg_speedup.index.tolist()
    heatmap_data = heatmap_data.loc[ordered_benchmarks]  # Reorder rows
    heatmap_data = heatmap_data[ordered_benchmarks]  # Reorder columns to match

    print(f"\nBenchmark ordering (by average simulated benchmark speedup, ascending):")
    for bench, avg_speedup in row_avg_speedup.items():
        print(f"  {bench}: {avg_speedup:.3f}")

    # Extract numeric prefix from benchmark names (e.g., "605.mcf_s" -> "605")
    import re
    def extract_number(benchmark_name):
        match = re.match(r'^(\d+)', benchmark_name)
        return match.group(1) if match else benchmark_name

    # Rename index and columns to show only numbers
    heatmap_data.index = [extract_number(b) for b in heatmap_data.index]
    heatmap_data.columns = [extract_number(b) for b in heatmap_data.columns]

    # Create figure
    fig, ax = plt.subplots(figsize=(12, 10))

    # Create heatmap without automatic annotations
    sns.heatmap(
        heatmap_data,
        annot=False,  # We'll add custom annotations
        fmt='.2f',
        cmap='RdYlGn',
        vmin=1.1,
        vmax=1.2,
        linewidths=0.5,
        linecolor='gray',
        ax=ax
    )

    # Add custom annotations with best speedup per row highlighted in red
    for i, row_name in enumerate(heatmap_data.index):
        row_values = heatmap_data.loc[row_name]
        max_val = row_values.max()

        for j, col_name in enumerate(heatmap_data.columns):
            val = heatmap_data.loc[row_name, col_name]

            if pd.notna(val):
                # Check if this is the best speedup in the row
                is_best = (val == max_val)
                color = 'red' if is_best else 'black'
                weight = 'bold' if is_best else 'normal'

                # Add text annotation
                ax.text(j + 0.5, i + 0.5, f'{val:.2f}',
                       ha='center', va='center',
                       color=color, fontsize=24, fontweight=weight)

    # Highlight diagonal cells with thick border
    n = len(heatmap_data)
    for i in range(n):
        # Draw rectangle for all four edges
        rect = Rectangle((i, i), 1, 1, fill=False,
                        edgecolor='black', linewidth=3, zorder=10, clip_on=False)
        ax.add_patch(rect)

        # For edge cells, draw additional thick lines on the outer boundary
        # to ensure they're visible against the plot border
        if i == 0:  # Top-left cell
            # Left edge
            line = Line2D([0, 0], [0, 1], color='black', linewidth=3,
                         zorder=11, clip_on=False, transform=ax.transData)
            ax.add_line(line)
            # Top edge
            line = Line2D([0, 1], [0, 0], color='black', linewidth=3,
                         zorder=11, clip_on=False, transform=ax.transData)
            ax.add_line(line)

        if i == n - 1:  # Bottom-right cell
            # Right edge
            line = Line2D([n, n], [n-1, n], color='black', linewidth=3,
                         zorder=11, clip_on=False, transform=ax.transData)
            ax.add_line(line)
            # Bottom edge
            line = Line2D([n-1, n], [n, n], color='black', linewidth=3,
                         zorder=11, clip_on=False, transform=ax.transData)
            ax.add_line(line)

    # Set labels
    ax.set_xlabel('PGO profile', fontsize=24)
    ax.set_ylabel('Simulated benchmark', fontsize=24)

    # Rotate x-axis labels for better readability
    plt.xticks(rotation=0, fontsize=24)
    plt.yticks(rotation=0, fontsize=24)
    ax.tick_params(axis='both', direction='out', labelsize=24)

    # Invert y-axis
    ax.invert_yaxis()

    # Increase colorbar label font size
    cbar = ax.collections[0].colorbar
    # cbar.set_label('Speedup against gem5.fast', fontsize=24)
    cbar.ax.tick_params(labelsize=24)

    # Grid
    # ax.grid(True, alpha=0.3)

    # Adjust layout to prevent label cutoff
    plt.tight_layout()

    # Save figure as PNG and PDF
    plt.savefig(output_png, dpi=300, bbox_inches='tight')
    plt.savefig(output_pdf, dpi=300, bbox_inches='tight')
    print(f"Heatmap saved to: {output_png}")
    print(f"Heatmap saved to: {output_pdf}")

    # Print summary statistics
    print("\nSpeedup Summary:")
    print(f"  Mean speedup: {heatmap_data.values.flatten()[~np.isnan(heatmap_data.values.flatten())].mean():.3f}")
    print(f"  Max speedup:  {np.nanmax(heatmap_data.values):.3f}")
    print(f"  Min speedup:  {np.nanmin(heatmap_data.values):.3f}")


def main():
    args = parse_args()

    # Parse benchmarks
    benchmarks = args.benchmarks.split()
    print(f"Benchmarks: {benchmarks}")
    print(f"Number of iterations: {args.num_iterations}")

    # Determine data/figure directories
    repo_dir = os.environ.get('REPO_DIR')
    if not repo_dir:
        repo_dir = os.getcwd()

    if args.results_dir:
        data_dir = Path(args.results_dir)
    else:
        data_dir = Path(os.environ.get('RESULTS_DATA_DIR', Path(repo_dir) / 'results' / 'data'))
    figs_dir = Path(os.environ.get('RESULTS_FIGS_DIR', Path(repo_dir) / 'results' / 'figs'))

    data_dir.mkdir(parents=True, exist_ok=True)
    figs_dir.mkdir(parents=True, exist_ok=True)

    print(f"\nData directory: {data_dir}")
    print(f"Figures directory: {figs_dir}")

    # File paths
    raw_csv = data_dir / 'execution_times.csv'
    aggregated_csv = data_dir / 'aggregated_times.csv'
    matrix_csv = data_dir / 'speedup_matrix.csv'
    heatmap_png = figs_dir / 'fig3.png'
    heatmap_pdf = figs_dir / 'fig3.pdf'

    print("\n" + "="*70)
    print("STEP 1: Load raw execution times")
    print("="*70)
    raw_df = load_raw_data(raw_csv)

    print("\n" + "="*70)
    print("STEP 2: Aggregate by benchmark")
    print("="*70)
    aggregated_df = aggregate_by_benchmark(raw_df, benchmarks, args.num_iterations)

    # Save aggregated times
    aggregated_df.to_csv(aggregated_csv, index=False)
    print(f"Saved aggregated times to: {aggregated_csv}")

    print("\n" + "="*70)
    print("STEP 3: Compute speedup matrix")
    print("="*70)
    matrix_df, avg_times = compute_speedup_matrix(aggregated_df, benchmarks)

    # Save speedup matrix
    matrix_df.to_csv(matrix_csv, index=False)
    print(f"Saved speedup matrix to: {matrix_csv}")

    print("\n" + "="*70)
    print("STEP 4: Generate heatmap")
    print("="*70)
    generate_heatmap(matrix_df, heatmap_png, heatmap_pdf)

    print("\n" + "="*70)
    print("COMPLETE")
    print("="*70)
    print(f"\nOutput files:")
    print(f"  - {aggregated_csv}")
    print(f"  - {matrix_csv}")
    print(f"  - {heatmap_png}")
    print(f"  - {heatmap_pdf}")


if __name__ == '__main__':
    main()
