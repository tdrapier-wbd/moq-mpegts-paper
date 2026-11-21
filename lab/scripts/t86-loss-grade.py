#!/usr/bin/env python3
"""T86 P2-u: grade t86-loss.sh runs against their source.

    t86-loss-grade.py <source.ts> <run-dir>... [--rate 9945951]

Per run: the shaper's measured loss; the output against the source (ts-passthrough-identity.py's
JSON, written to identity.json if absent); programme lost after the join, gaps plus the tail short
of the source's end, in seconds of the source at RATE; continuity errors and the longest read gap
after the first byte (arrivals.csv); and the join: the first byte's delay from the receiver's first
start, its place in the source, and how far behind the live edge it lands (time since the source
started, less that place). Prints one row per run.
"""

import argparse
import csv
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def events(path):
    out = {}
    for line in open(path):
        t, what = line.split(" ", 1)
        what = what.strip()
        key = "receiver start" if what.startswith("receiver start") else what
        out.setdefault(key, float(t))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--rate", type=float, default=9945951.0)
    a = ap.parse_args()
    pps = a.rate / (188 * 8)
    print("run | loss % | whole | lost s | gaps | tail s | cc | max gap ms | 1st byte s | joins at s | behind live s")
    for d in a.runs:
        ij = os.path.join(d, "identity.json")
        if not os.path.exists(ij):
            subprocess.run([sys.executable, os.path.join(HERE, "ts-passthrough-identity.py"), a.source,
                            os.path.join(d, "out.ts"), "--json", ij], stdout=subprocess.DEVNULL, check=False)
        idn = json.load(open(ij))
        shaper = json.load(open(os.path.join(d, "shaper.json")))
        ev = events(os.path.join(d, "events.log"))
        # a receiver retry's tap can be killed mid-line; keep whole numeric rows only
        rows = [r for r in csv.DictReader(open(os.path.join(d, "arrivals.csv")))
                if all((v or "").replace(".", "", 1).isdigit() for v in r.values())]
        live = [r for r in rows if int(r["packets"]) > 0]
        first = float(live[0]["t"]) if live else None
        cc = sum(int(r["cc_errors"]) for r in rows)
        # a read after the publisher has gone (a held last object) is no gap in delivery
        end = ev.get("publisher exit", float("inf")) + 1.0
        max_gap = max((int(r["max_gap_ms"]) for r in live[1:] if float(r["t"]) <= end), default=0)
        tail = (idn["source_packets"] - idn["end_source_packet"]) / pps
        lost = idn["gap_packets"] / pps + tail
        whole = idn["gaps"] == 0 and idn["foreign"] == 0 and cc == 0 and tail <= 1.0
        joins = idn["first_source_packet"] / pps
        delay = first - ev["receiver start"] if first else float("nan")
        behind = (first - ev["source start"]) - joins if first else float("nan")
        print(f"{os.path.basename(d.rstrip('/'))} | {shaper['loss_measured_pct']:.2f} | {'yes' if whole else 'no'} | "
              f"{lost:.2f} | {idn['gaps']} | {tail:.2f} | {cc} | {max_gap} | {delay:.2f} | {joins:.2f} | {behind:.2f}")


if __name__ == "__main__":
    main()
