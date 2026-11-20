#!/usr/bin/env python3
"""T86 P2-s: grade arrival-tapped runs (`t86-arrival-tap.py`) against their control.

    t86-arrival-grade.py [--at 45] <control-run> <run>...

Each run directory holds `release.csv` (the tap's one-second rows) and `identity.json`
(`ts-passthrough-identity.py`). Per run: whether the output is the stimulus's bytes from the join,
the event's second (the tap's first PCR step, else `--at` seconds after the first byte), the
longest read gap within 10 s of it and anywhere after the first two seconds, and the span from the
first byte to the last. Criterion 3
holds when the event's gap is within 0.5 s of the control's longest and the span within 1 s of
the control's.
"""

import csv
import json
import os
import sys


def load(run: str, at: float) -> dict:
    rows = []
    steps = 0
    with open(os.path.join(run, "release.csv")) as f:
        for line in f:
            if line.startswith("#step"):
                steps += 1
                continue
            if line.startswith("t,"):
                continue
            rows.append(next(csv.reader([line])))
    data = [(float(r[0]), int(r[1]), int(r[2]), float(r[4]), int(r[5])) for r in rows]
    live = [d for d in data if d[1] > 0]
    t0, t1 = live[0][0], live[-1][0]
    event = next((d[0] for d in live if d[4] > 0), t0 + at)
    after = [d for d in live if d[0] >= t0 + 2]
    near = [d for d in live if abs(d[0] - event) <= 10]
    with open(os.path.join(run, "identity.json")) as f:
        ident = json.load(f)
    return {
        "run": os.path.basename(run.rstrip("/")),
        "whole": ident["gaps"] == 0 and ident["foreign"] == 0 and ident["end_source_packet"] == ident["source_packets"],
        "join": ident["first_source_packet"],
        "cc": sum(d[2] for d in live),
        "steps": steps,
        "event_s": round(event - t0, 1),
        "gap_event_ms": max((d[3] for d in near), default=None),
        "gap_max_ms": max(d[3] for d in after),
        "span_s": round(t1 - t0, 1),
    }


def main() -> None:
    args = sys.argv[1:]
    at = 45.0
    if args[0] == "--at":
        at, args = float(args[1]), args[2:]
    control = load(args[0], at)
    print(json.dumps(control))
    for run in args[1:]:
        r = load(run, at)
        r["c3"] = r["gap_event_ms"] <= control["gap_max_ms"] + 500 and abs(r["span_s"] - control["span_s"]) <= 1
        print(json.dumps(r))


if __name__ == "__main__":
    main()
