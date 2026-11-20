#!/usr/bin/env python3
"""T86 P2-t: grade `t86-restart.sh` runs.

    t86-restart-grade.py [--rate 9945951] <run>...

Per run: where the output joins the source, its gaps and the programme they lose in seconds of the
clip (at RATE bits/s), whether anything foreign or repeated appears, its longest read gap (the
outage), and every component's exits before the rig's own shutdown, from `events.log`.
"""

import csv
import json
import os
import sys


def grade(run: str, rate: float) -> dict:
    with open(os.path.join(run, "identity.json")) as f:
        ident = json.load(f)
    exits: dict[str, int] = {}
    kill = None
    with open(os.path.join(run, "events.log")) as f:
        for line in f:
            t, *words = line.split()
            if words[0] == "source" and words[1] == "end":
                break
            if words[0] == "kill":
                kill = float(t)
            if words[0] == "exit":
                exits[words[1]] = exits.get(words[1], 0) + 1
    gap = 0.0
    with open(os.path.join(run, "release.csv")) as f:
        rows = [r for r in csv.reader(f) if r and r[0][0].isdigit()]
    live = [r for r in rows if int(r[1]) > 0]
    if live:
        gap = max(float(r[4]) for r in live[2:])
    return {
        "run": os.path.basename(run.rstrip("/")),
        "join": ident["first_source_packet"],
        "to_end": ident["end_source_packet"] == ident["source_packets"],
        "gaps": ident["gaps"],
        "lost_s": round(ident["gap_packets"] * 188 * 8 / rate, 2),
        "foreign": ident["foreign"],
        "outage_s": round(gap / 1000, 2),
        "killed": kill is not None,
        "exits": exits,
    }


def main() -> None:
    args = sys.argv[1:]
    rate = 9945951.0
    if args[0] == "--rate":
        rate, args = float(args[1]), args[2:]
    for run in args:
        print(json.dumps(grade(run, rate)))


if __name__ == "__main__":
    main()
