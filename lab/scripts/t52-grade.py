#!/usr/bin/env python3
"""Grade a T52 ramp from the subscriber host's run directory (lab/test-52-cdn-relay-fanout.md).

    t52-grade.py <run-dir> <lane>

Per step: subscribers alive, the host's received rate per subscriber against step 1's, host CPU,
the step's join time, graded-monitor flags (continuity, PCR over 40 ms, gaps), exits, and every
group the exports skipped or found evicted. A skip logged by at least half the subscribers at one
media time is common, lost at or before the relay; fewer is a subscriber's own. Events are placed
in the step whose window holds them and marked when inside its measure window.
"""

import csv
import glob
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone

ANSI = re.compile(r"\x1b\[[0-9;]*m")
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z\s+(\w+)\s+(.*)$")
SKIP = re.compile(r'media skipped upstream; resuming at the next group track="([^"]+)" at=([0-9.]+)s skipped=(\S+)')
EVICT = re.compile(r'current group evicted; skipping to next buffered group track="([^"]+)" group=(\d+)')
DEADLINE = re.compile(r"output missed a decode deadline on PID (\d+)")
MON = re.compile(r"t=(\d+) .*?gt40=(\d+) .*?cc=(\d+) .*?gap_ms=(\d+)")


def epoch(stamp):
    return datetime.fromisoformat(stamp).replace(tzinfo=timezone.utc).timestamp()


def log_lines(path):
    with open(path, errors="replace") as f:
        for raw in f:
            m = STAMP.match(ANSI.sub("", raw).strip())
            if m:
                yield epoch(m.group(1)), m.group(2), m.group(3)


def main():
    run, lane = sys.argv[1], sys.argv[2]
    p = lambda name: os.path.join(run, name)  # noqa: E731

    spawned = {}
    for line in open(p(f"phases-{lane}.log")):
        m = re.match(r"([0-9.]+) n=(\d+) spawned", line)
        if m:
            spawned[int(m.group(2))] = float(m.group(1))
    steps = {int(r["n"]): r for r in csv.DictReader(open(p(f"steps-{lane}.csv")))}
    order = sorted(spawned)

    def step_of(t):
        for n, nxt in zip(order, order[1:] + [None]):
            if t >= spawned[n] and (nxt is None or t < spawned[nxt]):
                return n
        return None

    host = [tuple(map(float, line.split()[:4])) for line in open(p(f"host-{lane}.log")) if line.strip()]

    def host_window(t0, t1):
        rows = [r for r in host if t0 <= r[0] <= t1]
        if len(rows) < 2:
            return None, None
        (s0, b0, i0, r0), (s1, b1, i1, r1) = rows[0], rows[-1]
        busy = (b1 - b0) / max((b1 - b0) + (i1 - i0), 1) * 100
        return busy, (r1 - r0) * 8 / (s1 - s0)

    skips = defaultdict(list)
    evicts, deadlines, exits = defaultdict(list), [], []
    starts = {}
    for path in sorted(glob.glob(p(f"sub-{lane}.*.log"))):
        sub = path.rsplit(".", 2)[-2]
        for t, level, msg in log_lines(path):
            starts.setdefault(sub, t)
            if (m := SKIP.search(msg)):
                skips[(m.group(1), m.group(2))].append((t, sub, m.group(3)))
            elif (m := EVICT.search(msg)):
                evicts[(m.group(1), m.group(2))].append((t, sub))
            elif (m := DEADLINE.search(msg)):
                deadlines.append((t, sub, m.group(1)))
            elif "session error" in msg or level == "ERROR":
                exits.append((t, sub, msg[:120]))

    mon_flags = defaultdict(list)
    for path in sorted(glob.glob(p(f"mon-{lane}.*.log"))):
        sub = path.rsplit(".", 2)[-2]
        base = starts.get(sub)
        for line in open(path):
            m = MON.search(line)
            if m and base and any(int(x) for x in m.groups()[1:]):
                mon_flags[step_of(base + int(m.group(1)))].append(f"sub{sub}@{m.group(0)[:60]}")

    ref = None
    print("n alive rx/sub_Mbps vs_step1 host_busy join_s common_in_measure individual_in_measure"
          " deadline_exits mon_flags")
    per_step = defaultdict(lambda: {"common": [], "single": []})
    for (track, at), hits in skips.items():
        t = min(h[0] for h in hits)
        n = step_of(t)
        if n is None:
            continue
        r = steps.get(n)
        inside = r is not None and float(r["t0"]) <= t <= float(r["t1"])
        kind = "common" if len(hits) >= max(2, n / 2) else "single"
        per_step[n][kind].append((inside, len(hits), track, at, hits[0][2], t))
    for n in order:
        r = steps.get(n)
        if not r:
            continue
        busy, rx = host_window(float(r["t0"]), float(r["t1"]))
        per = rx / n / 1e6 if rx else 0
        ref = ref or per
        join = open(p(f"join-{lane}.{n}.txt")).read().split()[0].split("=")[1] if os.path.exists(
            p(f"join-{lane}.{n}.txt")) else "-"
        common = [e for e in per_step[n]["common"] if e[0]]
        single = [e for e in per_step[n]["single"] if e[0]]
        dl = sum(1 for t, _, _ in deadlines if step_of(t) == n)
        print(f"{n} {r['alive']} {per:.2f} {per / ref:.4f} {busy:.1f}% {join} {len(common)} {len(single)} {dl}"
              f" {len(mon_flags.get(n, []))}")
    print("\ncommon skips (step, in measure, subscribers, track, media time, skipped, wall):")
    for n in order:
        for inside, count, track, at, skipped, t in sorted(per_step[n]["common"], key=lambda e: e[5]):
            wall = datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M:%S")
            print(f"  n={n} {'measure' if inside else 'settle'} {count} {track} {at} {skipped} {wall}")
    print("\nevicted groups, by subscribers:", sorted(((len(v), k) for k, v in evicts.items()), reverse=True)[:8])
    print("deadline exits:", len(deadlines), "first", min((t for t, _, _ in deadlines), default=None))
    for n, flags in sorted(mon_flags.items(), key=lambda kv: kv[0] or 0):
        print(f"monitor flags n={n}:", flags[:4])


if __name__ == "__main__":
    main()
