#!/usr/bin/env python3
"""Burst grouping for the T14/T15 cadence captures.

    t15-bursts.py <capture.csv> [...]

`t13-cadence.py report` summarises gaps and windowed rate; this groups the same
records into *bursts* — runs of reads separated by less than `SEPARATION_US` —
and reports the size distribution, which is the figure the hand-off comparison
turns on. A groomer's buffer is sized by how much arrives at once and how long
it then waits, not by the average rate, which is identical on every transport
that is not dropping data.

The 1 ms threshold is the one T14 used, and it is far below every inter-burst
gap measured on any leg (149 ms on MoQ, seconds on segmented HTTP) and far
above the intra-burst read spacing, so the grouping is not sensitive to it.
Run with `--sweep` to see that for a given capture.
"""

from __future__ import annotations

import csv
import statistics as stats
import sys

SEPARATION_US = 1000.0


def load(path: str) -> list[tuple[int, int]]:
    with open(path) as fh:
        return [(int(row["t_ns"]), int(row["bytes"])) for row in csv.DictReader(fh)]


def group(records: list[tuple[int, int]], separation_us: float) -> list[tuple[int, float]]:
    """Return (bytes, gap_before_us) per burst."""
    bursts: list[tuple[int, float]] = []
    size = records[0][1]
    gap_before = 0.0
    for earlier, later in zip(records, records[1:]):
        gap = (later[0] - earlier[0]) / 1000
        if gap >= separation_us:
            bursts.append((size, gap_before))
            size, gap_before = later[1], gap
        else:
            size += later[1]
    bursts.append((size, gap_before))
    return bursts


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))]


def human(n: float) -> str:
    return f"{n / 1e6:.2f} MB" if n >= 1e6 else f"{n / 1e3:.1f} kB"


def describe(path: str, separation_us: float = SEPARATION_US) -> None:
    records = load(path)
    if len(records) < 2:
        print(f"=== {path}: nothing captured")
        return
    bursts = group(records, separation_us)
    sizes = [size for size, _ in bursts]
    gaps = [gap for _, gap in bursts[1:]]
    span = records[-1][0] / 1e9
    name = path.split("/")[-1].removesuffix(".csv")

    print(f"=== {name}: {len(bursts):,} bursts over {span:.2f} s "
          f"({len(bursts) / span:.1f}/s, {sum(sizes) * 8 / span / 1e6:.3f} Mb/s)")
    print(f"    burst  median {human(stats.median(sizes)):>9}"
          f"  p95 {human(percentile(sizes, 95)):>9}"
          f"  max {human(max(sizes)):>9}")
    if gaps:
        print(f"    gap ms median {stats.median(gaps) / 1000:8.2f}"
              f"  p95 {percentile(gaps, 95) / 1000:8.2f}"
              f"  max {max(gaps) / 1000:8.2f}"
              f"  >1 s {sum(1 for g in gaps if g > 1e6)}")


def sweep(path: str) -> None:
    records = load(path)
    print(f"=== {path}: sensitivity of the median burst to the separation threshold")
    for separation in (200.0, 500.0, 1000.0, 2000.0, 5000.0):
        sizes = [size for size, _ in group(records, separation)]
        print(f"    {separation / 1000:5.1f} ms -> {len(sizes):6,} bursts, "
              f"median {human(stats.median(sizes))}")


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--sweep"]
    if not args:
        raise SystemExit(__doc__)
    for path in args:
        sweep(path) if "--sweep" in sys.argv else describe(path)


if __name__ == "__main__":
    main()
