#!/usr/bin/env python3
"""Render Hyperfine JSON as readable per-workload and suite overview charts."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import textwrap

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch, Rectangle


BACKGROUND = "#F6F8FB"
TEXT = "#182230"
MUTED = "#667085"
GRID = "#E4E9F0"
COLORS = {
    "nix": "#3976D3",
    "lix": "#7557C5",
    "snix": "#D85B53",
    "detsys-1core": "#E69F35",
    "detsys-2core": "#D57C22",
    "detsys-allcore": "#B75A18",
    "fix-1core": "#42B8B1",
    "fix-2core": "#2BA59D",
    "fix-4core": "#1C9188",
    "fix-8core": "#117E75",
    "fix-12core": "#0C7068",
    "fix-16core": "#08625B",
    "fix-32core": "#07544E",
    "fix-autocore": "#064943",
}
SUITE_COLORS = {
    "torture": "#3976D3",
    "realworld": "#7557C5",
    "json": "#138E83",
}
RATIO_STYLES = (
    (1.0, "#147D74", "#FFFFFF", "fastest"),
    (1.25, "#D9F0EC", TEXT, "≤ 1.25×"),
    (2.0, "#E8EDF4", TEXT, "≤ 2×"),
    (4.0, "#F4E8CF", TEXT, "≤ 4×"),
    (math.inf, "#EFD8D5", TEXT, "> 4×"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--unified", action="store_true", help="render one cross-suite summary only")
    parser.add_argument("json_files", nargs="+", type=Path)
    return parser.parse_args()


def load_result(path: Path) -> dict:
    payload = json.loads(path.read_text())
    rows = []
    for result in payload["results"]:
        mean = float(result["mean"])
        stddev = result.get("stddev")
        rows.append(
            {
                "name": result["command"],
                "mean": mean,
                "stddev": 0.0 if stddev is None else float(stddev),
                "runs": len(result.get("times", [])),
            }
        )
    return {"name": path.stem, "suite": path.parent.name, "rows": rows}


def time_label(seconds: float) -> str:
    if seconds >= 1:
        return f"{seconds:.3f} s"
    if seconds >= 0.001:
        return f"{seconds * 1000:.1f} ms"
    return f"{seconds * 1_000_000:.0f} µs"


def color_for(name: str) -> str:
    return COLORS.get(name, "#667085")


def style_axis(ax: plt.Axes) -> None:
    ax.set_facecolor("#FFFFFF")
    ax.grid(axis="x", color=GRID, linewidth=0.75)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color("#CBD3DF")
    ax.tick_params(axis="x", colors=MUTED, labelsize=8)
    ax.tick_params(axis="y", colors=TEXT, labelsize=8.5, length=0, pad=7)
    ax.set_xlabel("mean wall time · lower is better", fontsize=8, color=MUTED)


def axis_break(rows: list[dict]) -> tuple[float, float] | None:
    """Return the values bracketing a scale-wrecking gap, if one exists."""
    means = sorted(row["mean"] for row in rows)
    if len(means) < 2:
        return None
    gaps = [(upper / lower, lower, upper) for lower, upper in zip(means, means[1:]) if lower > 0]
    ratio, lower, upper = max(gaps)
    return (lower, upper) if ratio >= 4.0 else None


def bars_on(ax: plt.Axes, rows: list[dict]) -> list:
    return ax.barh(
        list(range(len(rows))),
        [row["mean"] for row in rows],
        xerr=[row["stddev"] for row in rows],
        color=[color_for(row["name"]) for row in rows],
        edgecolor="#FFFFFF",
        linewidth=0.35,
        height=0.64,
        error_kw={"ecolor": "#344054", "elinewidth": 1.0, "capsize": 2.5, "capthick": 1.0},
    )


def label_rows(ax: plt.Axes, bars: list, rows: list[dict], fastest: float, selected) -> None:
    span = ax.get_xlim()[1] - ax.get_xlim()[0]
    for bar, row in zip(bars, rows):
        if not selected(row):
            continue
        ratio = row["mean"] / fastest
        label = f"{time_label(row['mean'])}   {ratio:.2f}×"
        ax.text(
            row["mean"] + span * 0.025,
            bar.get_y() + bar.get_height() / 2,
            label,
            va="center",
            ha="left",
            fontsize=8.2,
            color="#344054",
            fontweight="bold" if math.isclose(ratio, 1.0) else "normal",
        )


def draw_workload(fig: plt.Figure, slots, workload: dict) -> None:
    rows = workload["rows"]
    fastest = min(row["mean"] for row in rows)
    upper = max(row["mean"] + row["stddev"] for row in rows)
    y = list(range(len(rows)))
    gap = axis_break(rows)

    if gap is None:
        ax = fig.add_subplot(slots[0])
        bars = bars_on(ax, rows)
        label_room = max(upper * 0.38, fastest * 0.9)
        ax.set_xlim(0, upper + label_room)
        label_rows(ax, bars, rows, fastest, lambda _row: True)
        axes = [ax]
    else:
        lower, higher = gap
        split = (lower + higher) / 2
        ax = fig.add_subplot(slots[1])
        right = fig.add_subplot(slots[2], sharey=ax)
        left_bars = bars_on(ax, rows)
        right_bars = bars_on(right, rows)
        ax.set_xlim(0, lower * 1.55)
        right_start = max(lower * 1.7, higher * 0.88)
        right_room = max(upper * 0.16, (upper - right_start) * 0.5)
        right.set_xlim(right_start, upper + right_room)
        label_rows(ax, left_bars, rows, fastest, lambda row: row["mean"] < split)
        label_rows(right, right_bars, rows, fastest, lambda row: row["mean"] >= split)

        ax.spines["right"].set_visible(False)
        right.spines["left"].set_visible(False)
        right.tick_params(axis="y", left=False, labelleft=False)
        right.text(
            0.02,
            1.025,
            "broken time axis",
            transform=right.transAxes,
            ha="left",
            va="bottom",
            fontsize=7.5,
            color=MUTED,
        )
        marker = [(-1, -0.6), (1, 0.6)]
        break_style = dict(marker=marker, markersize=9, linestyle="none", color=MUTED, mec=MUTED, mew=1, clip_on=False)
        ax.plot([1, 1], [0, 1], transform=ax.transAxes, **break_style)
        right.plot([0, 0], [0, 1], transform=right.transAxes, **break_style)
        axes = [ax, right]

    ax.set_yticks(y, [row["name"] for row in rows])
    title = workload.get("display_name", workload["name"]).replace("-", " ")
    ax.set_title(title, loc="left", fontsize=11, fontweight="bold", color=TEXT, pad=8)
    for chart_axis in axes:
        style_axis(chart_axis)
    ax.invert_yaxis()
    if gap is not None:
        right.set_xlabel("")


def save_figure(fig: plt.Figure, stem: Path) -> None:
    fig.savefig(stem.with_suffix(".svg"), format="svg", bbox_inches="tight", facecolor=fig.get_facecolor())
    fig.savefig(stem.with_suffix(".png"), format="png", dpi=190, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


def render_single(workload: dict, output_dir: Path, suite: str) -> None:
    height = max(3.0, 1.35 + 0.43 * len(workload["rows"]))
    fig = plt.figure(figsize=(11.5, height), facecolor=BACKGROUND)
    grid = fig.add_gridspec(1, 2, width_ratios=(4.4, 1), wspace=0.09)
    draw_workload(fig, (grid[0, :], grid[0, 0], grid[0, 1]), workload)
    runs = max((row["runs"] for row in workload["rows"]), default=0)
    fig.suptitle(
        f"fix benchmark · {suite} · {runs} measured run{'s' if runs != 1 else ''}",
        x=0.01,
        y=0.985,
        ha="left",
        fontsize=9,
        color=MUTED,
    )
    fig.subplots_adjust(left=0.2, right=0.96, bottom=min(0.18, 0.55 / height), top=1 - 0.75 / height)
    save_figure(fig, output_dir / workload["name"])


def render_summary(workloads: list[dict], output_dir: Path, suite: str) -> None:
    ratios = [1.15 + 0.42 * len(workload["rows"]) for workload in workloads]
    height = max(4.0, sum(ratios))
    fig = plt.figure(figsize=(12.5, height), facecolor=BACKGROUND)
    grid = fig.add_gridspec(
        len(workloads),
        2,
        height_ratios=ratios,
        width_ratios=(4.4, 1),
        hspace=0.62,
        wspace=0.09,
    )
    for index, workload in enumerate(workloads):
        draw_workload(fig, (grid[index, :], grid[index, 0], grid[index, 1]), workload)

    runs = max((row["runs"] for workload in workloads for row in workload["rows"]), default=0)
    fig.suptitle(
        f"fix evaluator benchmark · {suite}",
        x=0.055,
        y=1 - 0.1 / height,
        ha="left",
        fontsize=18,
        fontweight="bold",
        color=TEXT,
    )
    fig.text(
        0.055,
        1 - 0.42 / height,
        f"Mean wall time ± 1σ · {runs} measured run{'s' if runs != 1 else ''} · values are relative to the fastest evaluator per workload",
        ha="left",
        fontsize=9,
        color=MUTED,
    )
    fig.subplots_adjust(left=0.17, right=0.97, bottom=min(0.04, 0.45 / height), top=1 - 0.82 / height)
    save_figure(fig, output_dir / "summary")


def wrapped_workload_label(workload: dict) -> str:
    name = workload["name"].replace("-", " ")
    lines = textwrap.wrap(name, width=13, break_long_words=False)
    fastest = min(row["mean"] for row in workload["rows"])
    wrapped_name = "\n".join(lines)
    return f"{wrapped_name}\nbest {time_label(fastest)}"


def ratio_style(ratio: float) -> tuple[str, str]:
    for upper, background, foreground, _label in RATIO_STYLES:
        if ratio <= upper:
            return background, foreground
    raise AssertionError("ratio style table must end at infinity")


def ratio_label(ratio: float) -> str:
    if ratio == 1.0:
        return "1.00×"
    if ratio < 1.01:
        return f"{ratio:.4f}×"
    if ratio < 1.1:
        return f"{ratio:.3f}×"
    if ratio < 10:
        return f"{ratio:.2f}×"
    return f"{ratio:.1f}×"


def render_unified_summary(workloads: list[dict], output_dir: Path, suite: str) -> None:
    tool_names = list(
        dict.fromkeys(row["name"] for workload in workloads for row in workload["rows"])
    )
    row_maps = [{row["name"]: row for row in workload["rows"]} for workload in workloads]
    fastest = [min(row["mean"] for row in workload["rows"]) for workload in workloads]
    runs = max((row["runs"] for workload in workloads for row in workload["rows"]), default=0)

    width = max(14.5, 2.8 + 1.08 * len(workloads))
    height = max(7.0, 2.8 + 0.39 * len(tool_names))
    fig, ax = plt.subplots(figsize=(width, height), facecolor=BACKGROUND)
    ax.set_facecolor("#FFFFFF")
    fig.subplots_adjust(left=max(0.12, 2.15 / width), right=0.985, bottom=0.07, top=0.70)

    for column, (rows_by_name, best) in enumerate(zip(row_maps, fastest)):
        for row_index, tool_name in enumerate(tool_names):
            row = rows_by_name.get(tool_name)
            if row is None:
                background, foreground, label = "#F3F5F8", "#98A2B3", "—"
            else:
                ratio = row["mean"] / best
                background, foreground = ratio_style(ratio)
                label = ratio_label(ratio)
            ax.add_patch(
                Rectangle(
                    (column - 0.47, row_index - 0.43),
                    0.94,
                    0.86,
                    facecolor=background,
                    edgecolor="#FFFFFF",
                    linewidth=1.0,
                )
            )
            ax.text(
                column,
                row_index,
                label,
                ha="center",
                va="center",
                fontsize=8.2,
                color=foreground,
                fontweight="bold" if row is not None and ratio == 1.0 else "normal",
            )

    ax.set_xlim(-0.5, len(workloads) - 0.5)
    ax.set_ylim(len(tool_names) - 0.5, -0.5)
    ax.set_xticks(range(len(workloads)), [wrapped_workload_label(item) for item in workloads])
    ax.set_yticks(range(len(tool_names)), tool_names)
    ax.tick_params(axis="x", top=True, labeltop=True, bottom=False, labelbottom=False, length=0, pad=11, labelsize=8)
    ax.tick_params(axis="y", length=0, pad=10, labelsize=8.5, colors=TEXT)
    for label in ax.get_xticklabels():
        label.set_color("#344054")
        label.set_linespacing(1.3)
    for row_index, tool_name in enumerate(tool_names):
        ax.scatter(-0.535, row_index, s=24, color=color_for(tool_name), clip_on=False, zorder=3)
    for spine in ax.spines.values():
        spine.set_visible(False)

    suite_ranges = []
    start = 0
    while start < len(workloads):
        suite_name = workloads[start]["suite"]
        end = start + 1
        while end < len(workloads) and workloads[end]["suite"] == suite_name:
            end += 1
        suite_ranges.append((suite_name, start, end))
        start = end
    for suite_name, start, end in suite_ranges:
        color = SUITE_COLORS.get(suite_name, MUTED)
        midpoint = (start + end - 1) / 2
        ax.plot(
            [start - 0.45, end - 0.55],
            [1.225, 1.225],
            transform=ax.get_xaxis_transform(),
            color=color,
            linewidth=3.0,
            solid_capstyle="round",
            clip_on=False,
        )
        ax.text(
            midpoint,
            1.255,
            suite_name.upper(),
            transform=ax.get_xaxis_transform(),
            ha="center",
            va="bottom",
            fontsize=8,
            color=color,
            fontweight="bold",
        )

    fig.suptitle(
        f"fix evaluator benchmark · {suite}",
        x=max(0.045, 0.8 / width),
        y=0.965,
        ha="left",
        fontsize=18,
        fontweight="bold",
        color=TEXT,
    )
    fig.text(
        max(0.045, 0.8 / width),
        0.92,
        f"Mean wall time relative to the fastest evaluator per workload · {runs} measured run{'s' if runs != 1 else ''} · absolute best shown under each workload",
        ha="left",
        fontsize=9,
        color=MUTED,
    )
    legend_handles = [
        Patch(facecolor=background, edgecolor="none", label=label)
        for _upper, background, _foreground, label in RATIO_STYLES
    ]
    fig.legend(
        handles=legend_handles,
        loc="upper left",
        bbox_to_anchor=(max(0.04, 0.79 / width), 0.89),
        ncol=len(legend_handles),
        frameon=False,
        handlelength=1.4,
        handleheight=0.8,
        columnspacing=1.6,
        fontsize=8,
        labelcolor=MUTED,
    )
    save_figure(fig, output_dir / "summary")


def main() -> None:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    workloads = [load_result(path) for path in args.json_files]
    if args.unified:
        render_unified_summary(workloads, args.output_dir, args.suite)
    else:
        for workload in workloads:
            render_single(workload, args.output_dir, args.suite)
        render_summary(workloads, args.output_dir, args.suite)


if __name__ == "__main__":
    main()
