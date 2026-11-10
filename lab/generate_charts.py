#!/usr/bin/env python3
"""Render the lab's charts into lab/charts/ from the data each one depends on.

    python3 lab/generate_charts.py          # write every chart
    python3 lab/generate_charts.py --check  # exit 1 if any committed chart is stale

The cost charts read the figures lab/cost-model.py computes. The measurement charts read the
Markdown table in their test file, which is that data's only home, found by the heading above it.

Needs matplotlib and seaborn (lab/requirements-charts.txt). The SVGs are byte-stable for a
given matplotlib version: no timestamp, fixed element ids, glyphs drawn as paths from the
DejaVu Sans font matplotlib bundles, so the output does not depend on the fonts installed.
"""

import contextlib
import io
import re
import runpy
import sys
from pathlib import Path

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt  # noqa: E402
import seaborn as sns  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

HERE = Path(__file__).resolve().parent
CHARTS = HERE / "charts"

CATEGORY_ORDER = ["Self-hosted", "Cloud", "Vendor / managed"]
MARKERS = {"published": "o", "announced": "D", "bandwidth only": "s", "illustrative": "|"}


def load_model():
    with contextlib.redirect_stdout(io.StringIO()):
        return runpy.run_path(str(HERE / "cost-model.py"))


def table_after(path, heading, nth=0):
    """The nth Markdown table between the heading containing `heading` and the next heading."""
    lines = (HERE / path).read_text().split("\n")
    start = next(i for i, line in enumerate(lines) if line.startswith("#") and heading in line)
    tables, i = [], start + 1
    while i < len(lines) - 1 and not lines[i].startswith("#"):
        if lines[i].startswith("|") and re.match(r"^\|[\s:|-]+\|$", lines[i + 1]):
            j = i + 2
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            tables.append([[c.strip() for c in row.strip().strip("|").split("|")]
                           for row in [lines[i]] + lines[i + 2:j]])
            i = j
        else:
            i += 1
    return tables[nth]


def number(cell):
    text = re.sub(r"[*_`¹²³†‡§¶]", "", cell).strip()
    match = re.match(r"^[~≈]?\s*([\d,]*\.?\d+)", text)
    return float(match.group(1).replace(",", "")) if match else None


def column(table, name):
    k = next(i for i, header in enumerate(table[0]) if name in header)
    return [number(row[k]) for row in table[1:]]


def price(value):
    return f"{value:.2g}" if value >= 0.001 else f"{value:.5f}".rstrip("0")


def dollars(value, _=None):
    return f"${value:,.0f}"


def plain(value, _=None):
    return f"{value:,.0f}" if value >= 1 else f"{value:g}"


def footnote(fig, text):
    fig.text(0.01, 0.01, text, fontsize=7, color="0.4")


def price_ladder(model, palette):
    rows = sorted(model["PRICE_LADDER"], key=lambda r: (CATEGORY_ORDER.index(r[0]), -r[2]))
    gb_per_mbps_year = model["gb_per_mbps_year"]
    colours = dict(zip(CATEGORY_ORDER, palette))

    fig, ax = plt.subplots(figsize=(10, 2 + 0.33 * len(rows)))
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
    ax.set_yticks(range(len(rows)), [r[1] if r[4] == "published" else f"{r[1]} ({r[4]})" for r in rows])
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
    footnote(fig, "Public list prices; derived and assumed rows labelled. Source: lab/cost-model.py.")
    return fig


def cost_destinations(model, palette):
    fig, (left, right) = plt.subplots(1, 2, figsize=(12, 5), sharey=True)
    one = list(zip(*model["ONE_CHANNEL_FANOUT"]))
    for i, label in enumerate(["AWS list, DIY on EC2", "Cloudflare MoQ (announced)", "MediaConnect reserved"]):
        left.plot(one[0], one[i + 1], marker="o", ms=4, color=palette[i], label=label)
    left.set_title("One channel, 10 Mbps, 1+1 (§5.1)")

    mux = list(zip(*model["MULTIPLEX_FANOUT"]))
    for i, (label, style) in enumerate([("MediaConnect reserved", "-"),
                                        ("Cloud list less 70 % (hypothetical)", "--"),
                                        ("CDN MoQ relay @ $0.010/GB (assumed)", "--"),
                                        ("CDN MoQ relay @ $0.005/GB (assumed)", "--"),
                                        ("IP transit (bandwidth only)", ":")]):
        right.plot(mux[0], mux[i + 1], marker="o", ms=4, color=palette[2 + i], linestyle=style, label=label)
    right.set_title("Eight services, 10 Mbps each, 1+1, delivery only (§6)")

    for ax in (left, right):
        ax.set(xscale="log", yscale="log", xlabel="Destinations")
        ax.xaxis.set_major_formatter(FuncFormatter(plain))
        ax.legend(fontsize=8, loc="upper left")
    left.set_ylabel("Annual USD (log scale)")
    left.yaxis.set_major_formatter(FuncFormatter(dollars))
    footnote(fig, "Public list prices unless labelled. Source: lab/cost-model.py.")
    return fig


def cost_parity(model, palette):
    rows = model["PARITY"]
    labels = [name if basis == "published" else f"{name} ({basis})" for name, basis, _ in rows]
    values = [1_000_000 / per_destination for _, _, per_destination in rows]
    fig, ax = plt.subplots(figsize=(9, 4.4))
    bars = ax.barh(labels, values, color=[palette[0] if basis == "published" else "0.6" for _, basis, _ in rows])
    for bar, (_, basis, _) in zip(bars, rows):
        if basis == "announced":
            bar.set(facecolor="white", edgecolor=palette[0], hatch="///")
    for y, value in enumerate(values):
        ax.annotate(f"{value:,.1f}" if value < 1000 else f"{value:,.0f}", (value, y), xytext=(4, 0),
                    textcoords="offset points", va="center", fontsize=8)
    ax.set(xscale="log", xlabel="Destinations at which unicast IP costs $1M a year (log scale)")
    ax.invert_yaxis()
    ax.xaxis.set_major_formatter(FuncFormatter(plain))
    ax.set_title("Parity per $1M/yr of incumbent cost, eight-service 1+1 multiplex\n"
                 "solid = published · hatched = announced · grey = assumed, hypothetical or bandwidth only",
                 fontsize=9)
    footnote(fig, "Source: lab/cost-model.py.")
    return fig


# Why each ramp ended, as its test file records it, so the chart names the cause and not only the point.
FANOUT_ARMS = [
    ("test-26-cross-host-fanout.md", "Arm A", "0.14.15 quinn, GSO off", 0, "--", "relay host out of CPU"),
    ("test-26-cross-host-fanout.md", "Arm B", "0.14.15 quinn, GSO on", 0, "-",
     "harness: subscriber host out of memory"),
    ("test-26-cross-host-fanout.md", "Arm C", "0.14.15 quinn, GSO on, one core", 0, ":",
     "relay's one core saturated"),
    ("test-43-fanout-current-build.md", "S1 with GSO off", "0.15.1 noq, GSO off", 3, "--",
     "relay's knee, measured"),
    ("test-43-fanout-current-build.md", "S1 — the slope", "0.15.1 noq, GSO on", 3, "-",
     "harness: ramp stopped on its memory guard"),
]
LABEL_OFFSETS = {"Arm C": (8, -12), "S1 — the slope": (-8, 10)}


def fanout_relay_cpu(_, palette):
    fig, ax = plt.subplots(figsize=(9.5, 5.5))
    for path, heading, label, colour, style, ended in FANOUT_ARMS:
        colour = palette[colour]
        table = table_after(path, heading)
        n, cpu = column(table, "N"), column(table, "relay CPU")
        if any("% of N=1" in header for header in table[0]):
            share = column(table, "% of N=1")
        else:
            per_sub = column(table, "per-sub")
            share = [None if p is None else 100 * p / per_sub[0] for p in per_sub]
        held = [s is not None and s >= 95 for s in share]
        ax.plot(n, cpu, linestyle=style, color=colour, label=label)
        ax.scatter([x for x, h in zip(n, held) if h], [c for c, h in zip(cpu, held) if h], color=colour, s=14)
        ax.scatter([n[-1]], [cpu[-1]], color=colour if "harness" not in ended else "white", edgecolors=colour,
                   marker="o" if held[-1] else "X", s=80, zorder=3, linewidths=1.5)
        offset = LABEL_OFFSETS.get(heading, (8, -3))
        ax.annotate(ended, (n[-1], cpu[-1]), xytext=offset, textcoords="offset points", fontsize=7.5,
                    color=colour, ha="right" if offset[0] < 0 else "left",
                    bbox=dict(boxstyle="square,pad=0.1", facecolor="white", edgecolor="none", alpha=0.85))
    ax.axhline(200, color="0.5", linewidth=0.8)
    ax.annotate("two cores", (2, 200), xytext=(0, 3), textcoords="offset points", fontsize=8, color="0.4")
    ax.set(xlabel="Subscribers (N)", ylabel="Relay CPU, % of one core", xlim=(0, 265), ylim=(0, 215),
           title="Relay CPU against fan-out, 10 Mb/s per subscriber; × = delivery below 95 % of N = 1")
    ax.legend(fontsize=8, loc="upper right")
    footnote(fig, "P1, cross-host, one region, 45 s per point; hollow = the harness, not the relay, ended the ramp. "
             "Data: T26 arms A–C, T43 S1.")
    return fig


def loss_lane_controller(_, palette):
    table = table_after("test-8-srt-vs-moq.md", "The same knob on the segmented lane")
    loss = [0.0 if "none" in row[0] else number(row[0]) for row in table[1:]]
    fig, ax = plt.subplots(figsize=(7.5, 4.8))
    for header, label, colour, style in [("segmented / **CUBIC", "Segmented HTTP, CUBIC", 1, "--"),
                                         ("media-aware / **CUBIC", "MoQ media-aware, CUBIC", 1, "-"),
                                         ("segmented / **BBR", "Segmented HTTP, BBR", 0, "--"),
                                         ("media-aware / **BBR", "MoQ media-aware, BBR", 0, "-")]:
        ax.plot(loss, column(table, header), linestyle=style, color=palette[colour], marker="o", ms=4, label=label)
    ax.set(xlabel="Commanded loss, % (+15 ms delay)", ylabel="Delivered rate / source rate", ylim=(0, 1.15),
           title="The controller, not the lane, decides the loss result")
    ax.legend(fontsize=8, loc="lower left")
    footnote(fig, "40 s per cell, T5's host and shaper. Data: T8, lane × controller table.")
    return fig


CHARTS_BY_FILE = {
    "price_ladder.svg": price_ladder,
    "cost_destinations.svg": cost_destinations,
    "cost_parity.svg": cost_parity,
    "fanout_relay_cpu.svg": fanout_relay_cpu,
    "loss_lane_controller.svg": loss_lane_controller,
}


def stable_ids(svg):
    """Renumber matplotlib's hashed clip-path and marker ids in order of appearance.

    The hashes cover raw float coordinates, whose last bits differ between CPU architectures
    even where every printed coordinate agrees, so without this an x86 runner and an arm64
    laptop write different files for the same chart.
    """
    ids = {}
    for old in re.findall(r'id="([pm][0-9a-f]{10})"', svg):
        ids.setdefault(old, f"{old[0]}{len(ids):04d}")
    return re.sub(r"\b[pm][0-9a-f]{10}\b", lambda m: ids.get(m.group(0), m.group(0)), svg)


def render():
    model = load_model()
    sns.set_theme(style="whitegrid", font="DejaVu Sans", font_scale=0.9)
    palette = sns.color_palette("deep")
    for name, draw in CHARTS_BY_FILE.items():
        plt.rcParams["svg.hashsalt"] = name
        fig = draw(model, palette)
        fig.tight_layout(rect=(0, 0.02, 1, 1))
        buffer = io.StringIO()
        fig.savefig(buffer, format="svg", metadata={"Date": None})
        plt.close(fig)
        yield CHARTS / name, stable_ids(buffer.getvalue())


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for path, svg in render():
        if check:
            if not path.exists() or path.read_text() != svg:
                stale.append(path.name)
        else:
            path.parent.mkdir(exist_ok=True)
            path.write_text(svg)
            print(f"wrote {path.relative_to(HERE.parent)}")
    if stale:
        print(f"stale: {', '.join(stale)}; run python3 lab/generate_charts.py", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
