#!/usr/bin/env python3

"""
Generate performance plot from parallel instances CSV data.

X-axis (main): Benchmarks (alphabetical order)
X-axis (sub): Number of instances (grouped within each benchmark)
Y-axis (main): Normalized execution time (normalized to instance=1)
Y-axis (secondary): L3 miss rate (per_instance_cache_miss / total_per_instance_cache)
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import argparse
import sys
import os
from pathlib import Path

REPO_DIR = Path(os.environ.get("REPO_DIR", os.getcwd()))
RESULTS_DATA_DIR = Path(os.environ.get("RESULTS_DATA_DIR", REPO_DIR / "results" / "data"))
RESULTS_FIGS_DIR = Path(os.environ.get("RESULTS_FIGS_DIR", REPO_DIR / "results" / "figs"))


def load_and_process_data(csv_file):
    """Load CSV and compute aggregated metrics."""
    try:
        df = pd.read_csv(csv_file)
    except Exception as e:
        print(f"Error loading CSV file: {e}")
        sys.exit(1)

    # Check required columns
    required_cols = ['benchmark', 'simpoint', 'num_instances', 'repeat',
                     'average_exec_time', 'per_instance_cache_miss', 'per_instance_cache_hit']
    missing_cols = [col for col in required_cols if col not in df.columns]
    if missing_cols:
        print(f"Error: Missing required columns: {missing_cols}")
        sys.exit(1)

    # Convert numeric columns
    numeric_cols = ['num_instances', 'repeat', 'average_exec_time',
                    'per_instance_cache_miss', 'per_instance_cache_hit']
    for col in numeric_cols:
        df[col] = pd.to_numeric(df[col], errors='coerce')

    # Drop rows with NaN values
    df = df.dropna(subset=numeric_cols)

    if len(df) == 0:
        print("Error: No valid data found in CSV file")
        sys.exit(1)

    # Compute mean across simpoints and repeats
    grouped = df.groupby(['benchmark', 'num_instances']).agg({
        'average_exec_time': 'mean',
        'per_instance_cache_miss': 'mean',
        'per_instance_cache_hit': 'mean'
    }).reset_index()

    # Compute L3 miss rate
    grouped['l3_miss_rate'] = grouped['per_instance_cache_miss'] / (
        grouped['per_instance_cache_miss'] + grouped['per_instance_cache_hit']
    )

    return grouped


def normalize_data(df):
    """Normalize execution time to instance=1 baseline for each benchmark."""
    normalized_df = df.copy()

    # For each benchmark
    for benchmark in df['benchmark'].unique():
        # Get baseline (instance=1) values
        baseline = df[(df['benchmark'] == benchmark) & (df['num_instances'] == 1)]

        if len(baseline) == 0:
            print(f"Warning: No instance=1 baseline found for {benchmark}, skipping normalization")
            continue

        baseline_exec_time = baseline['average_exec_time'].values[0]

        # Normalize for this benchmark
        mask = normalized_df['benchmark'] == benchmark
        normalized_df.loc[mask, 'norm_exec_time'] = (
            df.loc[mask, 'average_exec_time'] / baseline_exec_time
        )

    return normalized_df


def create_figure(df, output_file):
    """Create grouped bar chart with dual y-axes."""
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Get unique values and sort
    benchmarks = sorted(df['benchmark'].unique())
    instance_counts = sorted(df['num_instances'].unique())

    # Create figure
    fig, ax1 = plt.subplots(figsize=(16.8, 6))
    ax2 = ax1.twinx()

    # Bar chart parameters
    num_benchmarks = len(benchmarks)
    num_instances = len(instance_counts)
    bar_width = 0.8 / num_instances
    # Reduce spacing between groups by using a smaller multiplier
    x_positions = np.arange(num_benchmarks) * 0.85

    # Colors - use sequential colormap for bars (progressively darker)
    miss_rate_color = '#ff4500'  # Bright orange-red for better visibility

    # Generate colors from a sequential colormap (Blues)
    cmap = plt.cm.Blues
    bar_colors = [cmap(0.3 + 0.7 * i / (num_instances - 1)) if num_instances > 1 else cmap(0.5)
                  for i in range(num_instances)]

    # Plot bars for each instance count
    for i, num_inst in enumerate(instance_counts):
        exec_times = []
        miss_rates = []

        for benchmark in benchmarks:
            subset = df[(df['benchmark'] == benchmark) &
                       (df['num_instances'] == num_inst)]

            if len(subset) > 0:
                exec_times.append(subset['norm_exec_time'].values[0])
                miss_rates.append(subset['l3_miss_rate'].values[0])
            else:
                exec_times.append(np.nan)
                miss_rates.append(np.nan)

        # Calculate position offset for grouped bars
        offset = (i - num_instances / 2) * bar_width + bar_width / 2
        positions = x_positions + offset

        # Plot execution time bars on primary y-axis with progressive colors
        ax1.bar(positions, exec_times, bar_width * 0.9,
               color=bar_colors[i], alpha=0.9, edgecolor='black', linewidth=0.5,
               label=f'{num_inst}')

    # Plot L3 miss rate as separate lines per benchmark (not connected between benchmarks)
    for bench_idx, benchmark in enumerate(benchmarks):
        bench_positions = []
        bench_values = []

        for i, num_inst in enumerate(instance_counts):
            subset = df[(df['benchmark'] == benchmark) &
                       (df['num_instances'] == num_inst)]

            if len(subset) > 0 and not np.isnan(subset['l3_miss_rate'].values[0]):
                offset = (i - num_instances / 2) * bar_width + bar_width / 2
                pos = x_positions[bench_idx] + offset
                bench_positions.append(pos)
                bench_values.append(subset['l3_miss_rate'].values[0])

        # Plot line for this benchmark only
        if len(bench_positions) > 0:
            ax2.plot(bench_positions, bench_values,
                    'o-', color=miss_rate_color,
                    markersize=8, linewidth=2.5, alpha=0.9)

    # Configure primary y-axis (execution time)
    ax1.set_ylabel('Normalized execution time', fontsize=24)
    ax1.set_ylim(0, 2.5)
    ax1.set_yticks(np.arange(0.0, 2.51, 0.5))
    ax1.tick_params(axis='y', direction='out', labelsize=24)
    ax1.tick_params(axis='x', direction='out', labelsize=24)
    ax1.tick_params(axis='y', which='minor', direction='in')
    ax1.tick_params(axis='x', which='minor', direction='in')
    ax1.minorticks_on()

    # Extract benchmark numbers (e.g., "605.mcf_s" -> "605")
    benchmark_numbers = []
    for bench in benchmarks:
        # Extract first number from benchmark name
        num = bench.split('.')[0]
        benchmark_numbers.append(num)

    # Set x-axis: benchmark numbers at group centers
    ax1.set_xticks(x_positions)
    ax1.set_xticklabels(benchmark_numbers, rotation=0, fontsize=24)
    ax1.set_xlabel('Benchmark', fontsize=24)

    # Reduce left and right margins to 1/4 of default
    x_margin = (x_positions[-1] - x_positions[0]) * 0.08  # Much smaller margin (was ~0.2 default)
    ax1.set_xlim(x_positions[0] - x_margin, x_positions[-1] + x_margin)

    # Configure secondary y-axis (miss rate)
    ax2.set_ylabel('L3 miss rate', fontsize=24)
    ax2.set_ylim(0, 0.5)
    ax2.set_yticks(np.arange(0, 0.51, 0.1))
    ax2.tick_params(axis='y', direction='out', labelsize=24)
    ax2.tick_params(axis='y', which='minor', direction='in')
    ax2.minorticks_on()

    # Add grid
    ax1.grid(True, alpha=0.3, axis='y')
    ax1.set_axisbelow(True)

    # Add reference line at y=1 for normalized execution time
    ax1.axhline(y=1.0, color='gray', linestyle='--', linewidth=1, alpha=0.5)

    # Create second legend first: Instance counts (outside right, with reduced spacing)
    legend2 = ax1.legend(title='Number of\ninstances', bbox_to_anchor=(1.05, 1.2), loc='upper left',
              fontsize=24, frameon=False, title_fontsize=24,
              labelspacing=0.3, handletextpad=0.5)

    # Create first legend and add as artist: Execution time and L3 miss rate (above plot)
    from matplotlib.patches import Rectangle
    legend1_elements = [
        Rectangle((0, 0), 1, 1, fc=bar_colors[0], alpha=0.9, edgecolor='black',
                 label='Execution time'),
        plt.Line2D([0], [0], marker='o', color=miss_rate_color, linewidth=2,
                  markersize=6, label='L3 miss rate')
    ]
    legend1 = ax1.legend(handles=legend1_elements, bbox_to_anchor=(0.5, 1), loc='lower center',
                        fontsize=24, frameon=False, ncol=2)
    ax1.add_artist(legend2)  # Re-add the second legend as artist

    # Save figure with bbox_extra_artists to prevent legend clipping
    plt.savefig(output_path, dpi=300, bbox_inches='tight', bbox_extra_artists=(legend1, legend2))
    print(f"Figure saved to: {output_path}")

    # Also save as PDF
    pdf_file = output_path.with_suffix('.pdf')
    plt.savefig(pdf_file, bbox_inches='tight', bbox_extra_artists=(legend1, legend2))
    print(f"Figure also saved to: {pdf_file}")

    plt.close()


def main():
    parser = argparse.ArgumentParser(
        description='Generate performance plot from parallel instances data',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('--csv', type=str,
                       default=str(RESULTS_DATA_DIR / 'fig8a_data.csv'),
                       help='Path to CSV file (default: $RESULTS_DATA_DIR/fig8a_data.csv)')

    parser.add_argument('--output', type=str,
                       default=str(RESULTS_FIGS_DIR / 'fig8a.png'),
                       help='Output figure file (default: $RESULTS_FIGS_DIR/fig8a.png)')

    args = parser.parse_args()

    # Check if CSV file exists
    if not Path(args.csv).exists():
        print(f"Error: CSV file not found: {args.csv}")
        sys.exit(1)

    print("Loading and processing data...")
    df = load_and_process_data(args.csv)

    print("Normalizing data...")
    df = normalize_data(df)

    print(f"Processed {len(df)} data points")
    print(f"Benchmarks: {sorted(df['benchmark'].unique())}")
    print(f"Instance counts: {sorted(df['num_instances'].unique())}")

    print("\nGenerating figure...")
    create_figure(df, args.output)

    print("\nDone!")


if __name__ == '__main__':
    main()
