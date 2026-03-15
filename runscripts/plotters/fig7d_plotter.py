#!/usr/bin/env python3

"""Generate the Splash 4-core PGO evaluation plot for Figure 7d."""

import argparse
import math
import os
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patches import Patch

VARIANTS = [
    ("Self-profiling", None, "#5A9CB5"),
    ("Mem", "mem", "#7BC5A0"),
    ("Mem-Minor", "mem-minor", "#FACE68"),
    ("Mem-Minor-Ruby", "mem-minor-ruby", "#FAAC68"),
]

BENCHMARK_ORDER = [
    "ocean-4core",
    "fft-4core",
    "lu-4core",
    "radix-4core",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate Splash 4-core PGO evaluation bar graph"
    )
    parser.add_argument(
        "--num-iterations",
        type=int,
        default=2,
        help="Number of iterations per run",
    )
    parser.add_argument(
        "--results-dir",
        type=str,
        default=None,
        help="Data directory (default: $RESULTS_DATA_DIR or $REPO_DIR/results/data)",
    )
    return parser.parse_args()


def load_execution_times(csv_file, num_iterations):
    if not csv_file.exists():
        print(f"ERROR: Execution times CSV file not found: {csv_file}")
        sys.exit(1)

    df = pd.read_csv(csv_file)
    required_cols = [
        "simulated_benchmark",
        "simpoint",
        "pgo_benchmark",
        "iteration",
        "execution_time",
    ]
    missing_cols = set(required_cols) - set(df.columns)
    if missing_cols:
        print(f"ERROR: Missing columns in CSV: {missing_cols}")
        sys.exit(1)

    df = df[df["iteration"] <= num_iterations].copy()
    benchmarks = df["simulated_benchmark"].unique()

    print(
        f"Loaded {len(df)} execution time records for {len(benchmarks)} Splash 4-core benchmarks "
        f"(iterations 1-{num_iterations})"
    )
    return df, benchmarks


def compute_benchmark_times(execution_df):
    benchmark_times = execution_df.groupby(
        ["simulated_benchmark", "pgo_benchmark", "iteration"], as_index=False
    )["execution_time"].sum()
    benchmark_times.rename(columns={"execution_time": "total_time"}, inplace=True)
    print(f"Computed {len(benchmark_times)} total times (benchmark x variant x iteration)")
    return benchmark_times


def prepare_plot_data(benchmark_times, benchmarks):
    plot_data = []

    for bench in benchmarks:
        bench_data = benchmark_times[benchmark_times["simulated_benchmark"] == bench].copy()
        baseline_times = bench_data[bench_data["pgo_benchmark"] == "baseline"]["total_time"].values

        if len(baseline_times) == 0:
            print(f"WARNING: No baseline data for {bench}, skipping...")
            continue

        baseline_mean = np.mean(baseline_times)

        for label, pgo_name, _ in VARIANTS:
            if label == "Self-profiling":
                variant_times = bench_data[bench_data["pgo_benchmark"] == bench]["total_time"].values
            else:
                variant_times = bench_data[bench_data["pgo_benchmark"] == pgo_name]["total_time"].values

            if len(variant_times) == 0:
                print(f"WARNING: No {label} data for {bench}")
                continue

            speedups = baseline_mean / variant_times
            plot_data.append(
                {
                    "simulated_benchmark": bench,
                    "variant": label,
                    "speedup": np.mean(speedups),
                    "std": np.std(speedups, ddof=1) if len(speedups) > 1 else 0.0,
                }
            )

    plot_df = pd.DataFrame(plot_data)
    print(f"Prepared {len(plot_df)} data points for plotting")
    return plot_df


def ordered_benchmarks(index_values):
    ordered = [bench for bench in BENCHMARK_ORDER if bench in index_values]
    ordered += sorted(bench for bench in index_values if bench not in BENCHMARK_ORDER)
    return ordered


def benchmark_label(name):
    return name.replace("-4core", "")


def compute_axis_bounds(pivot_df, pivot_std):
    values = pivot_df.to_numpy(dtype=float)
    errors = pivot_std.reindex_like(pivot_df).fillna(0.0).to_numpy(dtype=float)
    max_value = np.nanmax(values + errors)
    min_value = np.nanmin(values - errors)

    upper = max(1.05, math.ceil(max_value / 0.05) * 0.05)
    lower = 1.0 if min_value >= 1.0 else math.floor(min_value / 0.05) * 0.05
    if upper <= lower:
        upper = lower + 0.05

    tick_step = 0.05 if (upper - lower) <= 0.4 else 0.1
    ticks = np.arange(lower, upper + tick_step / 2, tick_step)
    return lower, upper, ticks


def save_legend(labels, colors, output_png):
    handles = [Patch(facecolor=color, edgecolor="none", label=label) for label, color in zip(labels, colors)]

    fig = plt.figure(figsize=(max(9.5, 2.5 * len(labels)), 1.4))
    fig.legend(
        handles=handles,
        labels=labels,
        loc="center",
        ncol=len(labels),
        frameon=False,
        fontsize=20,
        columnspacing=1.1,
        handlelength=1.6,
    )
    fig.savefig(output_png, dpi=300, bbox_inches="tight", pad_inches=0.05)
    output_pdf = output_png.with_suffix(".pdf")
    fig.savefig(output_pdf, bbox_inches="tight", pad_inches=0.05)
    plt.close(fig)
    print(f"Legend saved to: {output_png}")
    print(f"Legend saved to: {output_pdf}")


def generate_bar_chart(plot_df, output_png, legend_png):
    if plot_df.empty:
        print("ERROR: No plot data generated")
        sys.exit(1)

    pivot_df = plot_df.pivot(index="simulated_benchmark", columns="variant", values="speedup")
    pivot_std = plot_df.pivot(index="simulated_benchmark", columns="variant", values="std")

    variant_labels = [label for label, _, _ in VARIANTS if label in pivot_df.columns]
    colors = [color for label, _, color in VARIANTS if label in pivot_df.columns]

    pivot_df = pivot_df.reindex(columns=variant_labels)
    pivot_std = pivot_std.reindex(columns=variant_labels).fillna(0.0)

    row_order = ordered_benchmarks(pivot_df.index)
    pivot_df = pivot_df.reindex(row_order)
    pivot_std = pivot_std.reindex(row_order)

    fig, ax = plt.subplots(figsize=(10.5, 4.8))

    x = np.arange(len(pivot_df.index))
    width = 0.18
    center = (len(variant_labels) - 1) / 2.0

    for i, (variant, color) in enumerate(zip(variant_labels, colors)):
        offset = (i - center) * width
        ax.bar(
            x + offset,
            pivot_df[variant],
            width,
            color=color,
            yerr=pivot_std[variant],
            capsize=5,
            error_kw={"linewidth": 2},
        )

    lower, upper, ticks = compute_axis_bounds(pivot_df, pivot_std)

    ax.set_xlabel("Simulated binary", fontsize=24)
    ax.set_ylabel("Speedup", fontsize=24)
    ax.set_xticks(x)
    ax.set_xticklabels([benchmark_label(name) for name in pivot_df.index], rotation=0, ha="center", fontsize=22)
    ax.set_xlim(-0.5, len(x) - 0.5)
    ax.set_ylim(lower, upper)
    ax.set_yticks(ticks)
    ax.grid(True, alpha=0.3)
    ax.set_axisbelow(True)
    ax.tick_params(axis="both", direction="out", labelsize=22)
    ax.tick_params(axis="both", which="minor", direction="in")
    ax.minorticks_on()

    plt.tight_layout()
    plt.savefig(output_png, dpi=300, bbox_inches="tight")
    output_pdf = output_png.with_suffix(".pdf")
    plt.savefig(output_pdf, bbox_inches="tight")
    plt.close(fig)

    print(f"Bar chart saved to: {output_png}")
    print(f"Bar chart saved to: {output_pdf}")
    save_legend(variant_labels, colors, legend_png)


def main():
    args = parse_args()

    repo_dir = Path(os.getenv("REPO_DIR", os.getcwd()))
    if args.results_dir:
        data_dir = Path(args.results_dir)
    else:
        data_dir = Path(os.getenv("RESULTS_DATA_DIR", repo_dir / "results" / "data"))
    figs_dir = Path(os.getenv("RESULTS_FIGS_DIR", repo_dir / "results" / "figs"))

    data_dir.mkdir(parents=True, exist_ok=True)
    figs_dir.mkdir(parents=True, exist_ok=True)

    execution_csv = data_dir / "splash_4core_execution_times.csv"
    output_png = figs_dir / "fig7d.png"
    legend_png = figs_dir / "fig7d_legend.png"
    plot_csv = data_dir / "fig7d_data.csv"

    print("=" * 80)
    print("Splash 4-Core PGO Evaluation Bar Graph Generation")
    print("=" * 80)
    print(f"Data directory: {data_dir}")
    print(f"Figures directory: {figs_dir}")
    print(f"Number of iterations: {args.num_iterations}")
    print("=" * 80)

    execution_df, benchmarks = load_execution_times(execution_csv, args.num_iterations)
    benchmark_times = compute_benchmark_times(execution_df)
    plot_df = prepare_plot_data(benchmark_times, benchmarks)
    plot_df.to_csv(plot_csv, index=False)
    print(f"Plot data saved to: {plot_csv}")

    generate_bar_chart(plot_df, output_png, legend_png)

    print("\n" + "=" * 80)
    print("Splash 4-Core PGO Evaluation Bar Graph Generation Complete")
    print("=" * 80)
    print(f"  - {plot_csv}")
    print(f"  - {output_png}")
    print(f"  - {output_png.with_suffix('.pdf')}")
    print(f"  - {legend_png}")
    print(f"  - {legend_png.with_suffix('.pdf')}")
    print("=" * 80)


if __name__ == "__main__":
    main()
