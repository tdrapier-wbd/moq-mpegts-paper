"""Grade `t83d-skip.sh` runs by eviction: per export, the groups it evicted in each burst's window.

    python3 t83d-evict.py <run dir>... [--window 12]

A burst's window runs from its start for --window seconds; an eviction outside every window is
counted as `out`. Each export's `Old` resets (`Moq(Stream(Old))`, `Moq(Old)`) are counted beside.
"""

import argparse
import datetime
import glob
import os
import re

STAMP = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z")


def when(line):
    m = STAMP.search(line)
    if not m:
        return None
    return datetime.datetime.fromisoformat(m.group(1)).replace(tzinfo=datetime.timezone.utc).timestamp()


def grade(run, window):
    events = [line.split() for line in open(os.path.join(run, "events.txt"))]
    bursts = [(float(e[-1]), f"{e[1]}/{e[2]}") for e in events if e[0] == "burst_on"]
    rows = []
    for log in sorted(glob.glob(os.path.join(run, "d*.log"))):
        hits, old = {}, 0
        for line in open(log, errors="replace"):
            if "Old" in line:
                old += 1
            if "evicted" not in line:
                continue
            t = when(line)
            inside = [name for start, name in bursts if t is not None and start <= t <= start + window]
            key = inside[-1] if inside else "out"
            hits[key] = hits.get(key, 0) + 1
        export = os.path.basename(log)[:-4]
        rows.append((export, sum(hits.values()), old, hits))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--window", type=float, default=12.0)
    a = ap.parse_args()
    for run in a.runs:
        for export, total, old, hits in grade(run, a.window):
            order = sorted(hits, key=lambda k: (k == "out", float(k.split("/")[0]) if k != "out" else 0, k))
            detail = " ".join(f"{k}:{hits[k]}" for k in order) or "-"
            print(f"{os.path.basename(run.rstrip('/'))} {export} evictions={total} old_lines={old} {detail}")


if __name__ == "__main__":
    main()
