#!/usr/bin/env python3
"""Render cost-model.md's charts from the figures lab/cost-model.py computes.

    python3 lab/generate_charts.py          # write lab/price_ladder.svg
    python3 lab/generate_charts.py --check  # exit 1 if the committed SVG is stale

Needs matplotlib and seaborn (lab/requirements-charts.txt). The SVG is byte-stable for a
given matplotlib version: no timestamp, fixed element ids, glyphs drawn as paths from the
DejaVu Sans font matplotlib bundles, so the output does not depend on the fonts installed.
"""

import contextlib
import io
import runpy
import sys
from pathlib import Path

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt  # noqa: E402
import seaborn as sns  # noqa: E402

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "price_ladder.svg"

CATEGORY_ORDER = ["Self-hosted", "Cloud", "Vendor / managed"]
MARKERS = {"published": "o", "announced": "D", "bandwidth only": "s", "illustrative": "|"}


def load_model():
    with contextlib.redirect_stdout(io.StringIO()):
        return runpy.run_path(str(HERE / "cost-model.py"))


def label(option, basis):
    return option if basis == "published" else f"{option} ({basis})"


def price(value):
    return f"{value:.2g}" if value >= 0.001 else f"{value:.5f}".rstrip("0")


def render(model):
    rows = sorted(model["PRICE_LADDER"], key=lambda r: (CATEGORY_ORDER.index(r[0]), -r[2]))
    gb_per_mbps_year = model["gb_per_mbps_year"]

    sns.set_theme(style="whitegrid", font="DejaVu Sans", font_scale=0.9)
    plt.rcParams["svg.hashsalt"] = "price-ladder"
    colours = dict(zip(CATEGORY_ORDER, sns.color_palette("deep", len(CATEGORY_ORDER))))

    fig, ax = plt.subplots(figsize=(10, 7))
    for y, (category, option, low, high, basis) in enumerate(rows):
        colour = colours[category]
        if high is None:
            ax.scatter([low], [y], marker=MARKERS[basis], s=60, linewidths=1.5, edgecolors=colour,
                       facecolors=colour if basis == "published" else "none", zorder=3)
            text = price(low)
        else:
            ax.hlines(y, low, high, color=colour, linewidth=3)
            ax.scatter([low, high], [y, y], color=colour, marker=MARKERS[basis], s=120)
            text = f"{price(low)}–{price(high)}"
        ax.annotate(text, ((high or low), y), xytext=(8, 0), textcoords="offset points",
                    va="center", fontsize=8, color="0.25")

    ax.set_xscale("log")
    ax.set_xlim(1e-4, 0.4)
    ax.set_yticks(range(len(rows)), [label(r[1], r[4]) for r in rows])
    ax.invert_yaxis()
    for y, tick in enumerate(ax.get_yticklabels()):
        tick.set_color(colours[rows[y][0]])
    for upper in range(1, len(rows)):
        if rows[upper][0] != rows[upper - 1][0]:
            ax.axhline(upper - 0.5, color="0.6", linewidth=0.8)
    ax.set_xlabel("$ per GB delivered (decimal GB, log scale)")
    top = ax.secondary_xaxis("top", functions=(lambda x: x * gb_per_mbps_year, lambda y: y / gb_per_mbps_year))
    top.set_xlabel("$ per always-on Mbps-year")

    handles = [plt.Line2D([], [], linestyle="", marker="s", markersize=8, color=colours[c], label=c)
               for c in CATEGORY_ORDER]
    ax.legend(handles=handles, loc="lower right", frameon=True, fontsize=8)
    fig.text(0.01, 0.01, "Public list prices; derived and assumed rows labelled. Source: lab/cost-model.py.",
             fontsize=7, color="0.4")
    fig.tight_layout()

    buffer = io.StringIO()
    fig.savefig(buffer, format="svg", metadata={"Date": None})
    plt.close(fig)
    return buffer.getvalue()


def main():
    svg = render(load_model())
    if "--check" in sys.argv[1:]:
        if not OUTPUT.exists() or OUTPUT.read_text() != svg:
            print(f"{OUTPUT.name} is stale: run python3 lab/generate_charts.py", file=sys.stderr)
            sys.exit(1)
        return
    OUTPUT.write_text(svg)
    print(f"wrote {OUTPUT.relative_to(HERE.parent)}")


if __name__ == "__main__":
    main()
