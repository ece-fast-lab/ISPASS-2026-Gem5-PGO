#!/usr/bin/env python3

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import sys
import os

def load_data(csv_file):
    """Load PGO comparison CSV data"""
    if not os.path.exists(csv_file):
        print(f"ERROR: CSV file not found: {csv_file}")
        sys.exit(1)

    df = pd.read_csv(csv_file)

    # Convert numeric columns
    df['exec_time'] = pd.to_numeric(df['exec_time'], errors='coerce')
    df['icache_miss_rate'] = pd.to_numeric(df['icache_miss_rate'], errors='coerce')
    df['itlb_misses'] = pd.to_numeric(df['itlb_misses'], errors='coerce')

    return df

def prepare_plot_data(df):
    """Prepare data for plotting"""
    # Get unique benchmarks
    benchmarks = sorted(df['benchmark'].unique())

    data = []
    for bench in benchmarks:
        bench_data = df[df['benchmark'] == bench]
        baseline = bench_data[bench_data['binary_type'] == 'baseline']
        pgo = bench_data[bench_data['binary_type'] == 'pgo']

        if len(baseline) == 0 or len(pgo) == 0:
            print(f"WARNING: Missing data for {bench}, skipping")
            continue

        baseline_time = baseline['exec_time'].values[0]
        pgo_time = pgo['exec_time'].values[0]
        baseline_icache = baseline['icache_miss_rate'].values[0]
        pgo_icache = pgo['icache_miss_rate'].values[0]
        baseline_itlb = baseline['itlb_misses'].values[0]
        pgo_itlb = pgo['itlb_misses'].values[0]

        # Normalize execution time
        norm_baseline_time = 1.0
        norm_pgo_time = pgo_time / baseline_time if baseline_time > 0 else 0

        # Calculate iTLB miss increase (%)
        itlb_increase = ((pgo_itlb - baseline_itlb) / baseline_itlb * 100) if baseline_itlb > 0 else 0

        data.append({
            'benchmark': bench,
            'norm_baseline_time': norm_baseline_time,
            'norm_pgo_time': norm_pgo_time,
            'baseline_icache': baseline_icache,
            'pgo_icache': pgo_icache,
            'itlb_increase': itlb_increase
        })

    return pd.DataFrame(data)

def plot_speedup_and_cache(data, output_stem):
    """
    Plot 1: Normalized execution time (bars) and L1i cache miss rate (line)
    Width: 8
    """
    fig, ax1 = plt.subplots(figsize=(7.2, 6))

    benchmarks = data['benchmark'].values
    # Extract benchmark numbers (e.g., "600.perlbench_s.0" -> "600")
    bench_labels = [bench.split('.')[0] for bench in benchmarks]
    x = np.arange(len(benchmarks))
    width = 0.35

    # Plot bars for normalized execution time (blue tones)
    bars1 = ax1.bar(x - width/2, data['norm_baseline_time'], width,
                    label='Baseline', color='#7EB3D4', edgecolor='black', linewidth=1)
    bars2 = ax1.bar(x + width/2, data['norm_pgo_time'], width,
                    label='PGO', color='#4A7BA7', edgecolor='black', linewidth=1)

    # Primary y-axis configuration
    ax1.set_xlabel('Benchmark', fontsize=24)
    ax1.set_ylabel('Normalized\nexecution time', fontsize=24)
    ax1.set_xticks(x)
    ax1.set_xticklabels(bench_labels, rotation=45, ha='right', rotation_mode='anchor', fontsize=24)
    ax1.tick_params(axis='both', direction='out', labelsize=24)
    ax1.tick_params(axis='both', which='minor', direction='in')
    ax1.minorticks_on()
    ax1.grid(True, alpha=0.3)
    ax1.set_axisbelow(True)
    ax1.set_ylim(0, 1)

    # Secondary y-axis for cache miss rate
    ax2 = ax1.twinx()

    # Plot cache miss rate as individual line segments per benchmark (red tone)
    for i, bench in enumerate(benchmarks):
        baseline_rate = data.loc[data['benchmark'] == bench, 'baseline_icache'].values[0]
        pgo_rate = data.loc[data['benchmark'] == bench, 'pgo_icache'].values[0]

        # Draw line segment from baseline to pgo for this benchmark
        ax2.plot([i - width/2, i + width/2], [baseline_rate, pgo_rate],
                color='#E57373', linewidth=2, marker='o', markersize=6, zorder=10)

    # Secondary y-axis configuration
    ax2.set_ylabel('L1i cache\nmiss rate (%)', fontsize=24)
    ax2.tick_params(axis='y', direction='out', labelsize=24)
    ax2.tick_params(axis='y', which='minor', direction='in')
    ax2.minorticks_on()
    ax2.set_ylim(0, 5)

    # Combine legends from both axes
    lines1, labels1 = ax1.get_legend_handles_labels()
    line_cache = plt.Line2D([0], [0], color='#E57373', linewidth=4, marker='o', markersize=8)
    lines1.append(line_cache)
    labels1.append('L1i miss rate')

    # Place legend above the plot (compact spacing)
    ax1.legend(lines1, labels1, loc='upper center', bbox_to_anchor=(0.5, 1.2),
               ncol=3, fontsize=24, frameon=False,
               handlelength=1.5, handletextpad=0.3, columnspacing=1.0)

    plt.tight_layout()

    # Save both PDF and PNG
    plt.savefig(f'{output_stem}.pdf', dpi=300, bbox_inches='tight')
    plt.savefig(f'{output_stem}.png', dpi=300, bbox_inches='tight')
    print(f"Saved: {output_stem}.pdf")
    print(f"Saved: {output_stem}.png")
    plt.close()

def plot_itlb_increase(data, output_stem):
    """
    Plot 2: iTLB miss increase (%)
    Width: 4
    """
    fig, ax = plt.subplots(figsize=(4.8, 5.4))

    benchmarks = data['benchmark'].values
    # Extract benchmark numbers (e.g., "600.perlbench_s.0" -> "600")
    bench_labels = [bench.split('.')[0] for bench in benchmarks]
    itlb_increases = data['itlb_increase'].values

    x = np.arange(len(benchmarks))

    # Determine bar colors based on positive/negative values
    colors = ['#d62728' if val > 0 else '#2ca02c' for val in itlb_increases]

    # Plot bars
    bars = ax.bar(x, itlb_increases, color=colors, edgecolor='black', linewidth=1)

    # Axis configuration
    ax.set_xlabel('Benchmark', fontsize=24)
    ax.set_ylabel('iTLB miss increase (%)', fontsize=24)
    ax.set_xticks(x)
    ax.set_xticklabels(bench_labels, rotation=45, ha='right', rotation_mode='anchor', fontsize=20)
    ax.tick_params(axis='both', direction='out')
    ax.tick_params(axis='y', labelsize=24)  # y-axis label size
    ax.tick_params(axis='x', labelsize=24)  # x-axis label size
    ax.tick_params(axis='both', which='minor', direction='in')
    ax.minorticks_on()
    ax.grid(True, alpha=0.3, axis='y')
    ax.set_axisbelow(True)
    ax.set_ylim(-60, 220)

    # Add horizontal line at y=0
    ax.axhline(y=0, color='black', linestyle='-', linewidth=1)

    plt.tight_layout()

    # Save both PDF and PNG
    plt.savefig(f'{output_stem}.pdf', dpi=300, bbox_inches='tight')
    plt.savefig(f'{output_stem}.png', dpi=300, bbox_inches='tight')
    print(f"Saved: {output_stem}.pdf")
    print(f"Saved: {output_stem}.png")
    plt.close()

def main():
    # Determine paths
    repo_dir = os.environ.get('REPO_DIR', os.getcwd())
    results_data_dir = os.environ.get(
        'RESULTS_DATA_DIR',
        os.path.join(repo_dir, 'results', 'data'),
    )
    results_figs_dir = os.environ.get(
        'RESULTS_FIGS_DIR',
        os.path.join(repo_dir, 'results', 'figs'),
    )
    os.makedirs(results_data_dir, exist_ok=True)
    os.makedirs(results_figs_dir, exist_ok=True)

    csv_file = os.environ.get('FIG2_CSV_FILE', os.path.join(results_data_dir, 'fig2_data.csv'))
    output_main = os.environ.get('FIG2_MAIN_FIG', os.path.join(results_figs_dir, 'fig2'))
    output_itlb = os.environ.get('FIG2_ITLB_FIG', os.path.join(results_figs_dir, 'fig2_itlb'))

    print(f"Loading data from: {csv_file}")
    df = load_data(csv_file)

    print(f"Total entries: {len(df)}")
    print(f"Benchmarks: {df['benchmark'].unique()}")
    print(f"Binary types: {df['binary_type'].unique()}")

    # Prepare plot data
    data = prepare_plot_data(df)

    if len(data) == 0:
        print("ERROR: No valid data for plotting")
        sys.exit(1)

    print(f"\nPlotting {len(data)} benchmarks")

    # Generate plots
    plot_speedup_and_cache(data, output_main)
    plot_itlb_increase(data, output_itlb)

    print("\nPlots generated successfully!")

    # Print summary statistics
    print("\n" + "="*60)
    print("Summary Statistics")
    print("="*60)
    avg_speedup = (1.0 / data['norm_pgo_time'].mean() - 1.0) * 100
    print(f"Average speedup (PGO vs baseline): {avg_speedup:.2f}%")
    print(f"Average iTLB miss increase: {data['itlb_increase'].mean():.2f}%")
    print(f"Average L1i miss rate reduction: {(data['baseline_icache'].mean() - data['pgo_icache'].mean()):.4f}%")
    print("="*60)

if __name__ == '__main__':
    main()
