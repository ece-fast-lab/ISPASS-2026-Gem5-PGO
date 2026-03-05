#!/usr/bin/env python3

"""
Plot performance comparison between two scheduling strategies:
- baseline: benchmark-simpoint-iteration
- balanced: iteration-simpoint-benchmark

Generates a single graph with dual y-axes:
- Left y-axis: CPU utilization (%)
- Right y-axis: Memory usage (GB)
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os
import sys

# Configuration
REPO_DIR = os.environ.get('REPO_DIR', os.getcwd())
RESULTS_DATA_DIR = os.environ.get('RESULTS_DATA_DIR', os.path.join(REPO_DIR, 'results', 'data'))
RESULTS_FIGS_DIR = os.environ.get('RESULTS_FIGS_DIR', os.path.join(REPO_DIR, 'results', 'figs'))
MONITORING_CSV_BASELINE = os.environ.get(
    'FIG10_MONITORING_CSV_BASELINE',
    os.path.join(RESULTS_DATA_DIR, 'fig10_monitoring_baseline.csv'),
)
MONITORING_CSV_BALANCED = os.environ.get(
    'FIG10_MONITORING_CSV_BALANCED',
    os.path.join(RESULTS_DATA_DIR, 'fig10_monitoring_balanced.csv'),
)
OUTPUT_PNG = os.environ.get('FIG10_OUTPUT_PNG', os.path.join(RESULTS_FIGS_DIR, 'fig10.png'))
OUTPUT_PDF = os.environ.get('FIG10_OUTPUT_PDF', os.path.join(RESULTS_FIGS_DIR, 'fig10.pdf'))

def load_monitoring_data():
    """Load monitoring data from separate CSV files and combine them"""
    dfs = []

    # Load baseline data if it exists
    if os.path.exists(MONITORING_CSV_BASELINE):
        df_baseline = pd.read_csv(MONITORING_CSV_BASELINE)
        dfs.append(df_baseline)
        print(f"Loaded baseline data: {len(df_baseline)} records")
    else:
        print(f"WARNING: Baseline monitoring data not found: {MONITORING_CSV_BASELINE}")

    # Load balanced data if it exists
    if os.path.exists(MONITORING_CSV_BALANCED):
        df_balanced = pd.read_csv(MONITORING_CSV_BALANCED)
        dfs.append(df_balanced)
        print(f"Loaded balanced data: {len(df_balanced)} records")
    else:
        print(f"WARNING: Balanced monitoring data not found: {MONITORING_CSV_BALANCED}")

    if len(dfs) == 0:
        print("ERROR: No monitoring data found")
        sys.exit(1)

    # Combine dataframes
    df = pd.concat(dfs, ignore_index=True)

    # Convert timestamp to relative time (minutes from start for each schedule)
    for schedule in df['schedule_type'].unique():
        mask = df['schedule_type'] == schedule
        start_time = df.loc[mask, 'timestamp'].min()
        df.loc[mask, 'relative_time_min'] = (df.loc[mask, 'timestamp'] - start_time) / 60.0

    return df

def plot_performance_comparison(df):
    """Create dual y-axis plot comparing baseline and balanced schedules"""

    # Normalization constants
    CPU_NORMALIZE = 30.0  # Normalize to 30% CPU
    MEM_NORMALIZE = 200.0  # Normalize to 200GB memory

    # Create figure
    fig, ax1 = plt.subplots(figsize=(12, 6))

    # Create second y-axis
    ax2 = ax1.twinx()

    # Color scheme
    colors = {
        'baseline_cpu': '#FF8C00',      # DarkOrange
        'balanced_cpu': '#FF6347',      # Tomato (similar orange-red)
        'baseline_mem': '#4169E1',      # RoyalBlue
        'balanced_mem': '#1E90FF'       # DodgerBlue (similar blue)
    }

    # Plot CPU utilization on left y-axis
    baseline_data = df[df['schedule_type'] == 'baseline'].copy()
    balanced_data = df[df['schedule_type'] == 'balanced'].copy()

    # Normalize CPU: (cpu / 30) * 100, clip at 100%
    if not baseline_data.empty:
        baseline_data['cpu_normalized'] = np.minimum((baseline_data['cpu_utilization_percent'] / CPU_NORMALIZE) * 100, 100)
        ax1.plot(baseline_data['relative_time_min'],
                baseline_data['cpu_normalized'],
                color=colors['baseline_cpu'],
                linestyle='--',
                linewidth=2,
                label='Baseline CPU')

    if not balanced_data.empty:
        balanced_data['cpu_normalized'] = np.minimum((balanced_data['cpu_utilization_percent'] / CPU_NORMALIZE) * 100, 100)
        ax1.plot(balanced_data['relative_time_min'],
                balanced_data['cpu_normalized'],
                color=colors['balanced_cpu'],
                linestyle='-',
                linewidth=2,
                label='Balanced CPU')

    # Normalize Memory: (mem / 200) * 100, clip at 100%
    if not baseline_data.empty:
        baseline_data['mem_normalized'] = np.minimum((baseline_data['memory_usage_gb'] / MEM_NORMALIZE) * 100, 100)
        ax2.plot(baseline_data['relative_time_min'],
                baseline_data['mem_normalized'],
                color=colors['baseline_mem'],
                linestyle='--',
                linewidth=2,
                label='Baseline memory')

    if not balanced_data.empty:
        balanced_data['mem_normalized'] = np.minimum((balanced_data['memory_usage_gb'] / MEM_NORMALIZE) * 100, 100)
        ax2.plot(balanced_data['relative_time_min'],
                balanced_data['mem_normalized'],
                color=colors['balanced_mem'],
                linestyle='-',
                linewidth=2,
                label='Balanced memory')

    # Axis labels (first letter capitalized only)
    ax1.set_xlabel('Time (minutes)', fontsize=24)
    ax1.set_ylabel('CPU utilization (%)', fontsize=24)
    ax2.set_ylabel('Memory utilization (%)', fontsize=24)

    # Set axis limits
    ax1.set_xlim(0, 60)
    ax1.set_ylim(0, 110)
    ax2.set_ylim(0, 110)

    # Draw vertical lines at end times for each schedule
    if not baseline_data.empty:
        baseline_end_time = baseline_data['relative_time_min'].max()
        ax1.axvline(x=baseline_end_time, color='black',
                   linestyle='--', linewidth=1.5, alpha=0.7)

    if not balanced_data.empty:
        balanced_end_time = balanced_data['relative_time_min'].max()
        ax1.axvline(x=balanced_end_time, color='black',
                   linestyle='-', linewidth=1.5, alpha=0.7)

    # Tick configuration
    ax1.tick_params(axis='both', direction='out', labelsize=24)
    ax1.tick_params(axis='both', which='minor', direction='in')
    ax1.minorticks_on()

    ax2.tick_params(axis='both', direction='out', labelsize=24)
    ax2.tick_params(axis='both', which='minor', direction='in')
    ax2.minorticks_on()

    # Grid (only on main axis)
    ax1.grid(True, alpha=0.3)
    ax1.set_axisbelow(True)

    # Combine legends from both axes and place above plot
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2,
              loc='upper center', bbox_to_anchor=(0.5, 1.30),
              ncol=2, fontsize=24, frameon=False)

    # Layout
    plt.tight_layout()

    # Save
    plt.savefig(OUTPUT_PNG, dpi=300, bbox_inches='tight')
    plt.savefig(OUTPUT_PDF, bbox_inches='tight')
    print(f"Saved plot to: {OUTPUT_PNG}")
    print(f"Saved plot to: {OUTPUT_PDF}")

def main():
    print("=" * 70)
    print("Figure 10 Scheduling Comparison Plotter")
    print("=" * 70)
    print(f"Baseline data: {MONITORING_CSV_BASELINE}")
    print(f"Balanced data: {MONITORING_CSV_BALANCED}")
    print(f"Output PNG: {OUTPUT_PNG}")
    print(f"Output PDF: {OUTPUT_PDF}")
    print()

    os.makedirs(os.path.dirname(OUTPUT_PNG), exist_ok=True)

    # Load data
    df = load_monitoring_data()

    # Print statistics
    print("\nSchedule statistics:")
    for schedule in df['schedule_type'].unique():
        sched_data = df[df['schedule_type'] == schedule]
        print(f"\n{schedule.upper()}:")
        print(f"  Duration: {sched_data['relative_time_min'].max():.2f} minutes")
        print(f"  Avg CPU utilization: {sched_data['cpu_utilization_percent'].mean():.2f}%")
        print(f"  Peak memory usage: {sched_data['memory_usage_gb'].max():.2f} GB")
        print(f"  Avg memory usage: {sched_data['memory_usage_gb'].mean():.2f} GB")
        print(f"  Max running jobs: {sched_data['running_jobs_count'].max():.0f}")

    # Create plot
    print("\nGenerating performance comparison plot...")
    plot_performance_comparison(df)

    print("\n" + "=" * 70)
    print("Plot generation completed")
    print("=" * 70)

if __name__ == '__main__':
    main()
