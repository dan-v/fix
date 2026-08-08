#!/usr/bin/env python3
"""Render Hyperfine JSON as a small-multiples benchmark summary.

One panel per workload, one horizontal bar per evaluator in fixed order.
Bar length is mean wall time (linear, from zero), so per-workload ranking
is read directly from geometry; each bar carries its rank, relative
multiple, and absolute time. An off-scale bar tears: the shaft rips off
at a jagged edge and a torn stub marks its far end. fix wears the logo
purples (warm cache dark, cold light — an ordinal pair); competitors get
muted hues, with row labels carrying identity so color is never alone.

Emits transparent-background light and dark renders (summary.png/.svg,
summary-dark.png/.svg) for a GitHub <picture> block.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

# Transparent-background renders for the GitHub README: each theme's inks
# and series colors are validated against the surface GitHub actually
# renders on (#ffffff light, #0d1117 dark), but nothing is painted behind
# the marks. fix wears the logo's purples (warm cache dark, cold light — an
# ordinal pair); competitors get muted hues stepped for CVD separation,
# with row labels carrying identity so color is never alone.
THEMES = {
    "light": {
        "suffix": "",
        "ink": "#1f2328",
        "ink2": "#424a53",
        "muted": "#6e7781",
        "hairline": "#d0d7de",
        "series": {
            "fix (warm)": "#534AB7",
            "fix (cold)": "#8577DC",
            "nix": "#3a5f80",
            "lix": "#d3a3c8",
            "detsys": "#8a6a38",
        },
        "fallback": "#a5a8ad",
    },
    "dark": {
        "suffix": "-dark",
        "ink": "#e6edf3",
        "ink2": "#a8b3bd",
        "muted": "#8b949e",
        "hairline": "#30363d",
        "series": {
            "fix (warm)": "#8577DC",
            "fix (cold)": "#ab9ff0",
            "nix": "#5d87ad",
            "lix": "#c795bb",
            "detsys": "#a1854f",
        },
        "fallback": "#6a7076",
    },
}

# Fixed row order — identity by position across every panel. Unknown tool
# names (explicit TOOLS selections) append after, in first-seen order.
TOOL_ORDER = ["fix (warm)", "fix (cold)", "nix", "lix", "detsys"]

SUITE_BLURBS = {
    "torture": "synthetic evaluator hot paths",
    "realworld": "NixOS + Home Manager configurations",
    "json": "wide value trees, evaluated and serialized as JSON",
}

PANELS_PER_ROW = 4
# Bars past this multiple of the fastest are clipped at the panel edge and
# labeled with their true multiple — the panel scale stays readable.
CLIP_RATIO = 3.0

ORDINALS = ["1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", required=True)
    parser.add_argument("--unified", action="store_true", help="title as the cross-suite summary")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("json_files", nargs="+", type=Path)
    return parser.parse_args()


def load_result(path: Path) -> dict:
    payload = json.loads(path.read_text())
    rows = []
    for result in payload["results"]:
        stddev = result.get("stddev")
        rows.append(
            {
                "name": result["command"],
                "mean": float(result["mean"]),
                "stddev": 0.0 if stddev is None else float(stddev),
                "runs": len(result.get("times", [])),
            }
        )
    return {"name": path.stem, "suite": path.parent.name, "rows": rows}


def time_label(seconds: float) -> str:
    if seconds >= 10:
        return f"{seconds:.1f} s"
    if seconds >= 1:
        return f"{seconds:.2f} s"
    if seconds >= 0.001:
        return f"{seconds * 1000:.0f} ms"
    return f"{seconds * 1_000_000:.0f} µs"


def ratio_label(ratio: float) -> str:
    return f"{ratio:.2f}×" if ratio < 10 else f"{ratio:.0f}×"


def tool_names(workloads: list[dict]) -> list[str]:
    names = list(TOOL_ORDER)
    for workload in workloads:
        for row in workload["rows"]:
            if row["name"] not in names:
                names.append(row["name"])
    seen = {row["name"] for workload in workloads for row in workload["rows"]}
    return [name for name in names if name in seen]


def bar_color(name: str, theme: dict) -> str:
    return theme["series"].get(name, theme["fallback"])


def label_on(color: str) -> str:
    """Ink for text sitting ON a bar: dark on light fills, light on dark."""
    r, g, b = (int(color[i : i + 2], 16) / 255 for i in (1, 3, 5))
    luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return "#1f2328" if luminance > 0.55 else "#ffffff"


def jagged_edge(x: float, amplitude: float, y0: float, y1: float, teeth: int = 3) -> list[tuple[float, float]]:
    """Points of a torn vertical edge from y0 to y1, zigzagging around x."""
    stops = teeth * 2
    return [
        (x + (amplitude if step % 2 else -amplitude), y0 + (y1 - y0) * step / stops)
        for step in range(stops + 1)
    ]


def draw_torn_bar(ax: plt.Axes, position: float, limit: float, color: str) -> None:
    """An off-scale bar: the shaft tears off, and after a gap a short
    torn-edged stub marks the far end at the panel edge."""
    y0, y1 = position + 0.31, position - 0.31
    amplitude = limit * 0.008
    tear = limit * 0.86
    stub_start = limit * 0.91
    shaft = [(0, y0)] + jagged_edge(tear, amplitude, y0, y1) + [(0, y1)]
    stub = [(limit, y0), (limit, y1)] + list(reversed(jagged_edge(stub_start, amplitude, y0, y1)))
    ax.add_patch(Polygon(shaft, closed=True, facecolor=color, linewidth=0))
    ax.add_patch(Polygon(stub, closed=True, facecolor=color, linewidth=0))


def draw_panel(ax: plt.Axes, workload: dict, names: list[str], theme: dict, label_rows: bool) -> None:
    rows = {row["name"]: row for row in workload["rows"]}
    present = [name for name in names if name in rows]
    fastest = min(rows[name]["mean"] for name in present)
    ranks = {
        name: rank
        for rank, name in enumerate(sorted(present, key=lambda n: rows[n]["mean"]))
    }
    # Stretch bars across the panel: the scale ends just past the slowest
    # bar, but never beyond CLIP_RATIO× the fastest (outliers tear off).
    worst = max(rows[name]["mean"] for name in present) / fastest
    limit = fastest * min(CLIP_RATIO, max(1.35, worst * 1.06))

    ax.set_xlim(0, limit * 1.02)
    ax.set_ylim(len(names) - 0.5, -0.5)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_xticks([])
    ax.set_yticks([])

    for position, name in enumerate(names):
        row = rows.get(name)
        if row is None:
            ax.text(0, position, "—", ha="left", va="center", fontsize=7, color=theme["muted"])
            continue
        ratio = row["mean"] / fastest
        clipped = row["mean"] > limit
        color = bar_color(name, theme)
        if clipped:
            draw_torn_bar(ax, position, limit, color)
            length = limit * 0.86
        else:
            length = row["mean"]
            ax.barh(position, length, height=0.62, color=color, linewidth=0)
            if row["stddev"] > 0:
                lo = max(0.0, row["mean"] - row["stddev"])
                hi = min(limit, row["mean"] + row["stddev"])
                ax.plot([lo, hi], [position, position], color=theme["ink2"], linewidth=1.5, solid_capstyle="butt")
                for x in (lo, hi):
                    ax.plot([x, x], [position - 0.13, position + 0.13], color=theme["ink2"], linewidth=1.2)
        winner = ranks[name] == 0
        ordinal = ORDINALS[ranks[name]]
        if winner:
            text = f"{ordinal} · {time_label(row['mean'])}"
        else:
            text = f"{ordinal} · {ratio_label(ratio)} · {time_label(row['mean'])}"
        inside = length > limit * 0.55
        outside_x = min(limit, (row["mean"] + row["stddev"]) if not clipped else length) + limit * 0.03
        ax.text(
            length - limit * (0.045 if clipped else 0.03) if inside else outside_x,
            position,
            text,
            ha="right" if inside else "left",
            va="center",
            fontsize=6.6,
            color=label_on(color) if inside else (theme["ink"] if winner else theme["ink2"]),
            fontweight="bold" if winner else "normal",
        )

    if label_rows:
        for position, name in enumerate(names):
            ax.text(
                -limit * 0.045,
                position,
                name,
                ha="right",
                va="center",
                fontsize=7.2,
                color=theme["ink"] if name.startswith("fix") else theme["ink2"],
                fontweight="bold" if name.startswith("fix") else "normal",
            )

    ax.set_title(
        workload["name"].replace("-", " "),
        loc="left",
        fontsize=9,
        fontweight="bold",
        color=theme["ink"],
        pad=4,
    )


def wins_line(workloads: list[dict], names: list[str]) -> str:
    wins: dict[str, int] = {name: 0 for name in names}
    for workload in workloads:
        rows = {row["name"]: row for row in workload["rows"]}
        present = [name for name in names if name in rows]
        if not present:
            continue
        winner = min(present, key=lambda n: rows[n]["mean"])
        wins[winner] += 1
    parts = [f"{name} {count}" for name, count in wins.items() if count]
    return f"fastest per workload:  {' · '.join(parts)}  (of {len(workloads)})"


def render(workloads: list[dict], output_dir: Path, suite: str, theme: dict) -> None:
    names = tool_names(workloads)

    sections: list[tuple[str, list[dict]]] = []
    for workload in workloads:
        if sections and sections[-1][0] == workload["suite"]:
            sections[-1][1].append(workload)
        else:
            sections.append((workload["suite"], [workload]))

    panel_rows = [(suite_name, math.ceil(len(items) / PANELS_PER_ROW)) for suite_name, items in sections]
    total_rows = sum(rows for _name, rows in panel_rows)
    header_h, row_h, title_h = 0.34, 0.24 + 0.215 * len(names), 0.78
    fig_h = title_h + sum(header_h + rows * row_h for _name, rows in panel_rows) + 0.25
    fig_w = 12.6
    fig = plt.figure(figsize=(fig_w, fig_h))

    outer = fig.add_gridspec(
        len(sections) * 2,
        1,
        height_ratios=[r for _name, rows in panel_rows for r in (header_h, rows * row_h)],
        top=1 - title_h / fig_h,
        bottom=0.25 / fig_h,
        left=0.075,
        right=0.99,
        hspace=0.28,
    )

    for section_index, (suite_name, items) in enumerate(sections):
        header = fig.add_subplot(outer[section_index * 2])
        header.set_axis_off()
        blurb = SUITE_BLURBS.get(suite_name, "")
        header.text(0, 0.1, suite_name.upper(), ha="left", va="bottom", fontsize=10.5, fontweight="bold", color=theme["ink"])
        if blurb:
            header.text(0.995, 0.1, blurb, ha="right", va="bottom", fontsize=8, color=theme["muted"], transform=header.transAxes)
        header.axhline(y=0.0, color=theme["hairline"], linewidth=0.8)

        rows_here = panel_rows[section_index][1]
        inner = outer[section_index * 2 + 1].subgridspec(rows_here, PANELS_PER_ROW, hspace=0.62, wspace=0.26)
        for index, workload in enumerate(items):
            ax = fig.add_subplot(inner[index // PANELS_PER_ROW, index % PANELS_PER_ROW])
            draw_panel(ax, workload, names, theme, label_rows=index % PANELS_PER_ROW == 0)

    runs = max((row["runs"] for workload in workloads for row in workload["rows"]), default=0)
    fig.text(
        0.075,
        1 - 0.24 / fig_h,
        f"fix evaluator benchmark · {suite}",
        ha="left",
        va="center",
        fontsize=15,
        fontweight="bold",
        color=theme["ink"],
    )
    fig.text(
        0.075,
        1 - 0.46 / fig_h,
        f"mean wall time, shorter is faster · bars share a per-panel scale from zero; a torn bar runs past {CLIP_RATIO:.0f}× the fastest · "
        f"{runs} measured run{'s' if runs != 1 else ''} · provenance.md records the machine and pins",
        ha="left",
        va="center",
        fontsize=8,
        color=theme["muted"],
    )
    fig.text(
        0.075,
        1 - 0.63 / fig_h,
        wins_line(workloads, names),
        ha="left",
        va="center",
        fontsize=8.5,
        color=theme["ink2"],
        fontweight="bold",
    )
    stem = output_dir / f"summary{theme['suffix']}"
    fig.savefig(stem.with_suffix(".svg"), format="svg", transparent=True)
    fig.savefig(stem.with_suffix(".png"), format="png", dpi=200, transparent=True)
    plt.close(fig)


def main() -> None:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    workloads = [load_result(path) for path in args.json_files]
    for theme in THEMES.values():
        render(workloads, args.output_dir, args.suite, theme)


if __name__ == "__main__":
    main()
