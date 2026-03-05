#!/usr/bin/env python3

"""
Generate MiBench PGO evaluation bar graph.

This script:
1. Reads execution times from mibench_execution_times.csv
2. Computes speedup values (baseline_time / pgo_time) for each variant
3. Generates bar chart with error bars showing speedup vs baseline
4. Includes 5 PGO variants: self-profiling, unified, clustering, top10, mem
"""

import argparse
import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description='Generate MiBench PGO evaluation bar graph'
    )
    parser.add_argument(
        '--num-iterations',
        type=int,
        default=2,
        help='Number of iterations per run'
    )
    parser.add_argument(
        '--results-dir',
        type=str,
        default=None,
        help='Data directory (default: $RESULTS_DATA_DIR or $REPO_DIR/results/data)'
    )
    return parser.parse_args()


def load_execution_times(csv_file, num_iterations):
    """Load execution times CSV for MiBench benchmarks."""
    if not os.path.exists(csv_file):
        print(f"ERROR: Execution times CSV file not found: {csv_file}")
        sys.exit(1)

    df = pd.read_csv(csv_file)

    # Validate columns
    required_cols = ['simulated_benchmark', 'simpoint', 'pgo_benchmark', 'iteration', 'execution_time']
    missing_cols = set(required_cols) - set(df.columns)
    if missing_cols:
        print(f"ERROR: Missing columns in CSV: {missing_cols}")
        sys.exit(1)

    # Filter for specified iterations (1 to num_iterations)
    df = df[df['iteration'] <= num_iterations].copy()

    # Get unique benchmarks
    benchmarks = df['simulated_benchmark'].unique()

    print(f"Loaded {len(df)} execution time records for {len(benchmarks)} MiBench benchmarks (iterations 1-{num_iterations})")
    return df, benchmarks


def compute_benchmark_times(execution_df, benchmarks, num_iterations):
    """
    Compute total execution times for each benchmark, variant, and iteration.

    For MiBench, simpoint is always "full", so we just use execution_time directly.

    Returns DataFrame with columns: simulated_benchmark, pgo_benchmark, iteration, total_time
    """
    print("\nComputing benchmark-level times...")

    # For MiBench, execution_time is already the full time (no simpoints to sum)
    benchmark_times = execution_df[['simulated_benchmark', 'pgo_benchmark', 'iteration', 'execution_time']].copy()
    benchmark_times.rename(columns={'execution_time': 'total_time'}, inplace=True)

    print(f"Computed {len(benchmark_times)} total times (benchmark x variant x iteration)")
    return benchmark_times


def prepare_plot_data(benchmark_times, benchmarks):
    """
    Prepare data for plotting.

    For each benchmark:
    - Self profiling: speedup vs baseline using benchmark-specific PGO (pgo_benchmark == bench)
    - All merged (unified): speedup vs baseline with error bars
    - Clustering: speedup vs baseline with error bars
    - Top 10: speedup vs baseline with error bars
    - Memory-intensive (mem): speedup vs baseline with error bars

    Speedup = baseline_time / pgo_time (higher is better)
    """
    print("\nPreparing plot data...")

    plot_data = []

    for bench in benchmarks:
        bench_data = benchmark_times[benchmark_times['simulated_benchmark'] == bench].copy()

        # Get baseline times (across all iterations)
        baseline_times = bench_data[bench_data['pgo_benchmark'] == 'baseline']['total_time'].values

        if len(baseline_times) == 0:
            print(f"WARNING: No baseline data for {bench}, skipping...")
            continue

        baseline_mean = np.mean(baseline_times)

        # Self-profiling: use benchmark-specific PGO (pgo_benchmark == bench)
        self_times = bench_data[bench_data['pgo_benchmark'] == bench]['total_time'].values
        if len(self_times) > 0:
            self_speedup = baseline_mean / self_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Self profiling',
                'speedup': np.mean(self_speedup),
                'std': np.std(self_speedup, ddof=1) if len(self_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No self-profiling data for {bench}")
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Self profiling',
                'speedup': 0.0,
                'std': 0.0
            })

        # Unified PGO
        unified_times = bench_data[bench_data['pgo_benchmark'] == 'unified']['total_time'].values
        if len(unified_times) > 0:
            unified_speedup = baseline_mean / unified_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'All merged',
                'speedup': np.mean(unified_speedup),
                'std': np.std(unified_speedup, ddof=1) if len(unified_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No unified PGO data for {bench}")

        # Clustering PGO
        clustering_times = bench_data[bench_data['pgo_benchmark'] == 'clustering']['total_time'].values
        if len(clustering_times) > 0:
            clustering_speedup = baseline_mean / clustering_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Clustering',
                'speedup': np.mean(clustering_speedup),
                'std': np.std(clustering_speedup, ddof=1) if len(clustering_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No clustering PGO data for {bench}")

        # Top10 PGO
        top10_times = bench_data[bench_data['pgo_benchmark'] == 'top10']['total_time'].values
        if len(top10_times) > 0:
            top10_speedup = baseline_mean / top10_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Top 10',
                'speedup': np.mean(top10_speedup),
                'std': np.std(top10_speedup, ddof=1) if len(top10_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No top10 PGO data for {bench}")

        # Mem PGO
        mem_times = bench_data[bench_data['pgo_benchmark'] == 'mem']['total_time'].values
        if len(mem_times) > 0:
            mem_speedup = baseline_mean / mem_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Memory-intensive',
                'speedup': np.mean(mem_speedup),
                'std': np.std(mem_speedup, ddof=1) if len(mem_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No mem PGO data for {bench}")

    plot_df = pd.DataFrame(plot_data)

    print(f"\nPrepared {len(plot_df)} data points for plotting")
    print("\nSample plot data:")
    print(plot_df.head(10))

    return plot_df


def generate_bar_chart(plot_df, output_file):
    """
    Generate bar chart.
    X-axis: MiBench benchmarks (short names)
    Y-axis: speedup vs baseline
    Five bars per benchmark: Self profiling (0), All merged, Clustering, Top 10, Memory-intensive
    """
    print("\nGenerating bar chart...")

    # Pivot data for grouped bar chart
    pivot_df = plot_df.pivot(
        index='simulated_benchmark',
        columns='variant',
        values='speedup'
    )

    # Pivot for error bars
    pivot_std = plot_df.pivot(
        index='simulated_benchmark',
        columns='variant',
        values='std'
    )

    # Ensure column order: Self profiling, All merged, Clustering, Top 10, Memory-intensive
    column_order = ['Self profiling', 'All merged', 'Clustering', 'Top 10', 'Memory-intensive']
    pivot_df = pivot_df[[col for col in column_order if col in pivot_df.columns]]
    pivot_std = pivot_std[[col for col in column_order if col in pivot_std.columns]]

    # Sort benchmarks alphabetically by short name
    # Extract short name: "basicmath_large" -> "basicmath"
    short_names = [name.split('_')[0] for name in pivot_df.index]
    pivot_df['_short_name'] = short_names
    pivot_df['_sort_key'] = short_names
    pivot_df = pivot_df.sort_values(by='_sort_key', ascending=True)
    pivot_df = pivot_df.drop(columns=['_sort_key'])
    pivot_std = pivot_std.loc[pivot_df.index]
    print(f"Sorting x-axis by benchmark short name (alphabetically)")

    print(f"Pivot table shape: {pivot_df.shape}")
    print(f"Benchmarks: {list(pivot_df.index)}")
    print(f"Variants: {list(pivot_df.columns[:-1])}")  # Exclude _short_name

    # Create figure
    fig, ax = plt.subplots(figsize=(12, 4.8))

    # Define colors (5 variants) - same as SPEC
    colors = ['#5A9CB5', '#7BC5A0', '#FACE68', '#FAAC68', '#FA6868']

    # Plot grouped bar chart with error bars
    x = np.arange(len(pivot_df.index))
    width = 0.16  # Width for 5 bars

    for i, (variant, color) in enumerate(zip(pivot_df.columns[:-1], colors)):  # Exclude _short_name
        offset = (i - 2) * width  # Center 5 bars around x-axis tick
        ax.bar(
            x + offset,
            pivot_df[variant],
            width,
            label=variant,
            color=color,
            yerr=pivot_std[variant],
            capsize=5,
            error_kw={'linewidth': 2}
        )

    # Formatting
    ax.set_xlabel('Simulated binary', fontsize=24)
    ax.set_ylabel('Speedup', fontsize=24)
    ax.set_xticks(x)

    # Use short names for x-axis labels
    ax.set_xticklabels(pivot_df['_short_name'], rotation=45, ha='right', rotation_mode='anchor', fontsize=24)

    # Reduce margins on x-axis edges
    ax.set_xlim(-0.5, len(x) - 0.5)

    # Set y-axis range and ticks
    ax.set_ylim(1.0, 1.2)
    ax.set_yticks([1.0, 1.1, 1.2])

    # Legend outside plot, above (2 rows, 3 columns)
    # ax.legend(loc='upper center', bbox_to_anchor=(0.48, 1.5), ncol=3, fontsize=24, frameon=False, columnspacing=0.8)

    ax.grid(True, alpha=0.3)
    ax.set_axisbelow(True)

    # Tick configuration
    ax.tick_params(axis='both', direction='out', labelsize=24)
    ax.tick_params(axis='both', which='minor', direction='in')
    ax.minorticks_on()

    plt.yticks(fontsize=24)

    # Tight layout
    plt.tight_layout()

    # Save figure as PNG
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    print(f"Bar chart saved to: {output_file}")

    # Save figure as PDF
    output_pdf = str(output_file).replace('.png', '.pdf')
    plt.savefig(output_pdf, bbox_inches='tight')
    print(f"Bar chart saved to: {output_pdf}")

    plt.close()


def main():
    args = parse_args()

    # Determine data/figure directories
    repo_dir = os.getenv('REPO_DIR', os.getcwd())
    if args.results_dir:
        data_dir = Path(args.results_dir)
    else:
        data_dir = Path(os.getenv('RESULTS_DATA_DIR', Path(repo_dir) / 'results' / 'data'))
    figs_dir = Path(os.getenv('RESULTS_FIGS_DIR', Path(repo_dir) / 'results' / 'figs'))

    data_dir.mkdir(parents=True, exist_ok=True)
    figs_dir.mkdir(parents=True, exist_ok=True)

    print("="*80)
    print("MiBench PGO Evaluation Bar Graph Generation")
    print("="*80)
    print(f"Data directory: {data_dir}")
    print(f"Figures directory: {figs_dir}")
    print(f"Number of iterations: {args.num_iterations}")
    print("="*80)

    # File paths
    execution_csv = data_dir / 'mibench_execution_times.csv'
    output_png = figs_dir / 'fig7_mibench.png'
    output_pdf = figs_dir / 'fig7_mibench.pdf'

    # Load data
    execution_df, benchmarks = load_execution_times(execution_csv, args.num_iterations)

    # Compute benchmark-level times
    benchmark_times = compute_benchmark_times(execution_df, benchmarks, args.num_iterations)

    # Prepare plot data
    plot_df = prepare_plot_data(benchmark_times, benchmarks)

    # Save plot data to CSV
    plot_csv = data_dir / 'fig7_mibench_data.csv'
    plot_df.to_csv(plot_csv, index=False)
    print(f"\nPlot data saved to: {plot_csv}")

    # Generate bar chart
    generate_bar_chart(plot_df, output_png)

    print("\n" + "="*80)
    print("MiBench PGO Evaluation Bar Graph Generation Complete")
    print("="*80)
    print(f"\nOutput files:")
    print(f"  - {plot_csv}")
    print(f"  - {output_png}")
    print(f"  - {output_pdf}")
    print("="*80)


if __name__ == '__main__':
    main()
