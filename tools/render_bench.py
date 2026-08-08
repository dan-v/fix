#!/usr/bin/env python3
"""Render Hyperfine JSON as a small-multiples benchmark summary.

One panel per workload, one horizontal bar per evaluator in fixed order.
Bar length is mean wall time (linear, from zero), so per-workload ranking
is read directly from geometry; each bar carries its rank, relative
multiple, and absolute time. fix rows wear the accent hue (warm cache
dark, cold cache light — an ordinal pair); competitors are context gray —
identity is carried by row position and labels, never color alone.

Emits light and dark renders (summary.png/.svg, summary-dark.png/.svg)
for a GitHub <picture> block.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

# Validated tokens (dataviz reference palette; ordinal blue pair + chrome).
THEMES = {
    "light": {
        "suffix": "",
        "surface": "#fcfcfb",
        "ink": "#0b0b0b",
        "ink2": "#52514e",
        "muted": "#898781",
        "hairline": "#e1e0d9",
        "accent_warm": "#2a78d6",
        "accent_cold": "#86b6ef",
        "context": "#c7c5bc",
        "whisker": "#52514e",
    },
    "dark": {
        "suffix": "-dark",
        "surface": "#1a1a19",
        "ink": "#ffffff",
        "ink2": "#c3c2b7",
        "muted": "#898781",
        "hairline": "#2c2c2a",
        "accent_warm": "#3987e5",
        "accent_cold": "#86b6ef",
        "context": "#4a4a47",
        "whisker": "#c3c2b7",
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
    if name == "fix (warm)":
        return theme["accent_warm"]
    if name == "fix (cold)":
        return theme["accent_cold"]
    return theme["context"]


def draw_panel(ax: plt.Axes, workload: dict, names: list[str], theme: dict, label_rows: bool) -> None:
    rows = {row["name"]: row for row in workload["rows"]}
    present = [name for name in names if name in rows]
    fastest = min(rows[name]["mean"] for name in present)
    ranks = {
        name: rank
        for rank, name in enumerate(sorted(present, key=lambda n: rows[n]["mean"]))
    }
    # Stretch bars across the panel: the scale ends just past the slowest
    # bar, but never beyond CLIP_RATIO× the fastest (outliers clip with ▸).
    worst = max(rows[name]["mean"] for name in present) / fastest
    limit = fastest * min(CLIP_RATIO, max(1.35, worst * 1.06))

    ax.set_facecolor(theme["surface"])
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
        length = min(row["mean"], limit)
        ax.barh(position, length, height=0.62, color=bar_color(name, theme), linewidth=0)
        if not clipped and row["stddev"] > 0:
            ax.plot(
                [max(0.0, row["mean"] - row["stddev"]), min(limit, row["mean"] + row["stddev"])],
                [position, position],
                color=theme["whisker"],
                linewidth=0.8,
                alpha=0.55,
                solid_capstyle="butt",
            )
        winner = ranks[name] == 0
        ordinal = ORDINALS[ranks[name]]
        if winner:
            text = f"{ordinal} · {time_label(row['mean'])}"
        else:
            text = f"{ordinal} · {ratio_label(ratio)} · {time_label(row['mean'])}"
        if clipped:
            text = f"▸ {ordinal} · {ratio_label(ratio)} · {time_label(row['mean'])}"
        inside = length > limit * 0.55
        ax.text(
            length - limit * 0.03 if inside else length + limit * 0.03,
            position,
            text,
            ha="right" if inside else "left",
            va="center",
            fontsize=6.6,
            color=("#ffffff" if name == "fix (warm)" else theme["ink"]) if inside else (theme["ink"] if winner else theme["ink2"]),
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
    fig = plt.figure(figsize=(fig_w, fig_h), facecolor=theme["surface"])

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
        f"mean wall time, shorter is faster · bars share a per-panel scale from zero; anything past {CLIP_RATIO:.0f}× the fastest clips (▸) · "
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
    fig.legend(
        handles=[
            Patch(facecolor=theme["accent_warm"], label="fix, warm compile cache"),
            Patch(facecolor=theme["accent_cold"], label="fix, cold compile cache"),
            Patch(facecolor=theme["context"], label="other evaluators (named per row)"),
        ],
        loc="upper right",
        bbox_to_anchor=(0.99, 1 - 0.12 / fig_h),
        ncol=3,
        frameon=False,
        handlelength=1.1,
        handleheight=0.9,
        columnspacing=1.3,
        fontsize=7.5,
        labelcolor=theme["ink2"],
    )

    stem = output_dir / f"summary{theme['suffix']}"
    fig.savefig(stem.with_suffix(".svg"), format="svg", facecolor=fig.get_facecolor())
    fig.savefig(stem.with_suffix(".png"), format="png", dpi=200, facecolor=fig.get_facecolor())
    plt.close(fig)


def main() -> None:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    workloads = [load_result(path) for path in args.json_files]
    for theme in THEMES.values():
        render(workloads, args.output_dir, args.suite, theme)


if __name__ == "__main__":
    main()
