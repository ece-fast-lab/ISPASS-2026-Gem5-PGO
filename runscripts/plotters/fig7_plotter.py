#!/usr/bin/env python3

"""
Generate PGO evaluation bar graph comparing 605 profile, merged profile, and ProfileMix.

This script:
1. Reads execution times from CSV
2. Reads aggregated times to find best PGO for each benchmark
3. Computes speedup values (baseline_time / pgo_time) for each variant
4. Generates bar chart with error bars showing speedup vs baseline
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
        description='Generate PGO evaluation bar graph'
    )
    parser.add_argument(
        '--benchmarks',
        type=str,
        default="600.perlbench_s.0 602.gcc_s.0 605.mcf_s 620.omnetpp_s 623.xalancbmk_s 625.x264_s.0 631.deepsjeng_s 641.leela_s 648.exchange2_s 657.xz_s.0",
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


def load_execution_times(csv_file, benchmarks, num_iterations):
    """Load execution times CSV and filter for specified benchmarks and iterations."""
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

    # Filter for specified benchmarks
    df = df[df['simulated_benchmark'].isin(benchmarks)].copy()

    # Filter for specified iterations (1 to num_iterations)
    df = df[df['iteration'] <= num_iterations].copy()

    print(f"Loaded {len(df)} execution time records for {len(benchmarks)} benchmarks (iterations 1-{num_iterations})")
    return df


def load_aggregated_times(csv_file, benchmarks):
    """Load aggregated times CSV to find best PGO for each benchmark."""
    if not os.path.exists(csv_file):
        print(f"ERROR: Aggregated times CSV file not found: {csv_file}")
        sys.exit(1)

    df = pd.read_csv(csv_file)

    # Validate columns
    required_cols = ['simulated_benchmark', 'pgo_benchmark', 'total_execution_time']
    missing_cols = set(required_cols) - set(df.columns)
    if missing_cols:
        print(f"ERROR: Missing columns in aggregated CSV: {missing_cols}")
        sys.exit(1)

    # Filter for specified benchmarks
    df = df[df['simulated_benchmark'].isin(benchmarks)].copy()

    # Filter out baseline, unified, and mix (we'll handle them separately)
    df = df[~df['pgo_benchmark'].isin(['baseline', 'unified', 'mix'])].copy()

    print(f"Loaded {len(df)} aggregated time records")
    return df


def find_best_pgo(aggregated_df):
    """Find best PGO benchmark for each simulated benchmark."""
    print("\nFinding best PGO for each benchmark...")

    # Find minimum time for each simulated_benchmark
    best_pgo = aggregated_df.loc[
        aggregated_df.groupby('simulated_benchmark')['total_execution_time'].idxmin()
    ][['simulated_benchmark', 'pgo_benchmark', 'total_execution_time']].copy()

    best_pgo.rename(columns={
        'pgo_benchmark': 'best_pgo_benchmark',
        'total_execution_time': 'best_pgo_time'
    }, inplace=True)

    print("\nBest PGO for each benchmark:")
    for _, row in best_pgo.iterrows():
        print(f"  {row['simulated_benchmark']}: {row['best_pgo_benchmark']} ({row['best_pgo_time']:.2f}s)")

    return best_pgo


def compute_benchmark_times(execution_df, benchmarks, num_iterations):
    """
    Compute total execution times for each benchmark, variant, and iteration.

    For each (simulated_benchmark, pgo_benchmark, iteration):
    - Sum execution times across all simpoints

    Returns DataFrame with columns: simulated_benchmark, pgo_benchmark, iteration, total_time
    """
    print("\nComputing benchmark-level times...")

    # Sum across simpoints for each (simulated_benchmark, pgo_benchmark, iteration)
    benchmark_times = execution_df.groupby(
        ['simulated_benchmark', 'pgo_benchmark', 'iteration']
    )['execution_time'].sum().reset_index()

    benchmark_times.rename(columns={'execution_time': 'total_time'}, inplace=True)

    print(f"Computed {len(benchmark_times)} total times (benchmark x variant x iteration)")
    return benchmark_times


def prepare_plot_data(benchmark_times, benchmarks):
    """
    Prepare data for plotting.

    For each benchmark:
    - Self profiling: speedup vs baseline with error bars
    - Merged profile: speedup vs baseline with error bars
    - Clustering: speedup vs baseline with error bars
    - Top 10: speedup vs baseline with error bars
    - Memory-intensive: speedup vs baseline with error bars

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

        # Self-PGO (use benchmark's own profile)
        self_times = bench_data[bench_data['pgo_benchmark'] == bench]['total_time'].values
        if len(self_times) > 0:
            self_speedup = baseline_mean / self_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'Self-profiling',
                'speedup': np.mean(self_speedup),
                'std': np.std(self_speedup, ddof=1) if len(self_speedup) > 1 else 0.0
            })
        else:
            print(f"WARNING: No self-PGO data for {bench}")

        # Unified PGO
        unified_times = bench_data[bench_data['pgo_benchmark'] == 'unified']['total_time'].values
        if len(unified_times) > 0:
            unified_speedup = baseline_mean / unified_times
            plot_data.append({
                'simulated_benchmark': bench,
                'variant': 'All-merged',
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
                'variant': 'Top-cluster',
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
                'variant': 'Top-global',
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
    X-axis: simulated benchmarks
    Y-axis: speedup vs baseline
    Five bars per benchmark: Self profiling, Merged profile, Clustering, Top 10, Memory-intensive
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

    # Ensure column order: Self profiling, Merged profile, Clustering, Top 10, Memory-intensive
    column_order = ['Self-profiling', 'All-merged', 'Top-cluster', 'Top-global', 'Memory-intensive']
    pivot_df = pivot_df[[col for col in column_order if col in pivot_df.columns]]
    pivot_std = pivot_std[[col for col in column_order if col in pivot_std.columns]]

    # Sort benchmarks by benchmark number (ascending)
    # Extract benchmark number from names like "600.perlbench_s.0" -> 600
    benchmark_numbers = pivot_df.index.str.extract(r'^(\d+)')[0].astype(int)
    pivot_df['_sort_key'] = benchmark_numbers
    pivot_df = pivot_df.sort_values(by='_sort_key', ascending=True)
    pivot_df = pivot_df.drop(columns=['_sort_key'])
    pivot_std = pivot_std.loc[pivot_df.index]
    print(f"Sorting x-axis by benchmark number (ascending)")

    print(f"Pivot table shape: {pivot_df.shape}")
    print(f"Benchmarks: {list(pivot_df.index)}")
    print(f"Variants: {list(pivot_df.columns)}")

    # Create figure
    fig, ax = plt.subplots(figsize=(12, 5.4))

    # Define colors (5 variants) - soft harmonious palette
    colors = ['#5A9CB5', '#7BC5A0', '#FACE68', '#FAAC68', '#FA6868']  # Soft Blue, Soft Mint, Soft Yellow, Soft Orange, Soft Coral

    # Plot grouped bar chart with error bars
    x = np.arange(len(pivot_df.index))
    width = 0.16  # Reduced width for 5 bars

    for i, (variant, color) in enumerate(zip(pivot_df.columns, colors)):
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

    # Extract benchmark numbers for x-axis labels (e.g., "600.perlbench_s.0" -> "600")
    benchmark_labels = [name.split('.')[0] for name in pivot_df.index]
    ax.set_xticklabels(benchmark_labels, rotation=0, ha='center', fontsize=24)

    # Reduce margins on x-axis edges
    ax.set_xlim(-0.5, len(x) - 0.5)

    # Set y-axis range and ticks
    ax.set_ylim(1.0, 1.3)
    ax.set_yticks([1.0, 1.1, 1.2, 1.3])

    # Legend outside plot, above (2 rows, 3 columns)
    ax.legend(loc='upper center', bbox_to_anchor=(0.48, 1.5), ncol=3, fontsize=24, frameon=False, columnspacing=0.8,)
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

    # Parse benchmarks
    benchmarks = args.benchmarks.split()

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
    print("PGO Evaluation Bar Graph Generation")
    print("="*80)
    print(f"Data directory: {data_dir}")
    print(f"Figures directory: {figs_dir}")
    print(f"Benchmarks: {', '.join(benchmarks)}")
    print(f"Number of iterations: {args.num_iterations}")
    print("="*80)

    # File paths
    execution_csv = data_dir / 'execution_times.csv'
    output_png = figs_dir / 'fig7.png'
    output_pdf = figs_dir / 'fig7.pdf'

    # Load data
    execution_df = load_execution_times(execution_csv, benchmarks, args.num_iterations)

    # Compute benchmark-level times (sum across simpoints for each iteration)
    benchmark_times = compute_benchmark_times(execution_df, benchmarks, args.num_iterations)

    # Prepare plot data
    plot_df = prepare_plot_data(benchmark_times, benchmarks)

    # Save plot data to CSV
    plot_csv = data_dir / 'fig7_data.csv'
    plot_df.to_csv(plot_csv, index=False)
    print(f"\nPlot data saved to: {plot_csv}")

    # Generate bar chart
    generate_bar_chart(plot_df, output_png)

    print("\n" + "="*80)
    print("PGO Evaluation Bar Graph Generation Complete")
    print("="*80)
    print(f"\nOutput files:")
    print(f"  - {plot_csv}")
    print(f"  - {output_png}")
    print(f"  - {output_pdf}")
    print("="*80)


if __name__ == '__main__':
    main()
