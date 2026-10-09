#!/usr/bin/env python3
"""Grade a t41-rewind-supervisor.sh run: what one flagged rewind cost, and whether 1+1 survived it.

The stimulus (`t23-pcr-stimuli.py`) plays a clip whose timeline steps back at one cut, flagged. Its
video units split there: those before the cut and those after, on a timeline shifted back. Each
export's video is split at its own break, the step in decode order of more than 200 ms either way
nearest the first discontinuity_indicator on the video PID, and each side is matched to its side of
the stimulus by DTS (to 2 ticks).

- **Programme lost** is the stimulus's video the export never carried around the break: from the
  last unit before it that the export carried to the cut, plus from the cut to the first unit after
  it that the export carried, in content time. Units missing elsewhere are counted apart.
- **Wire gap** is the longest pause in the export's picture arrivals (its tap), and **from the
  rewind** the time from the source sending the first post-cut picture to the export's first
  post-break arrival, less the export's median latency before the break.
- **Importer** is the supervisor's restarts, each exit code and the error that ended it.
- **1+1** compares the two exports packet by packet from the start: identical, or where they part
  and on which side of the break.

Usage: t41-rewind-grade.py <stimulus.ts> <out-dir> [--vpid 111]
"""

import argparse
import bisect
import csv
import os
import re
import statistics

TS = 188
JUMP = 200 * 90


def units(path, vpid):
    """(decode time, packet index) of each video PES start in file order, and the packet index of
    the first packet on `vpid` that sets discontinuity_indicator, if any."""
    out, flag = [], None
    with open(path, "rb") as f:
        data = f.read()
    for k in range(len(data) // TS):
        p = data[k * TS : (k + 1) * TS]
        if p[0] != 0x47 or (((p[1] & 0x1F) << 8) | p[2]) != vpid:
            continue
        afc = (p[3] >> 4) & 3
        i = 4
        if afc & 2:
            if p[4] and p[5] & 0x80 and flag is None:
                flag = k
            i += 1 + p[4]
        if not p[1] & 0x40 or not afc & 1 or p[i : i + 3] != b"\x00\x00\x01" or not p[i + 7] & 0x80:
            continue
        b = p[i + 14 : i + 19] if p[i + 7] & 0x40 else p[i + 9 : i + 14]
        out.append((((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1, k))
    return out, flag


def split(seq, flag=None):
    """The index of the first unit after a step of more than 200 ms in decode order, or None. With
    `flag`, the step nearest that packet: a late join can skip a group before the break."""
    steps = [i for i in range(1, len(seq)) if abs(seq[i][0] - seq[i - 1][0]) > JUMP]
    if not steps:
        return None
    return min(steps, key=lambda i: abs(seq[i][1] - flag)) if flag is not None else steps[0]


def near(sorted_ts, t, tol=2):
    i = bisect.bisect_left(sorted_ts, t - tol)
    return i < len(sorted_ts) and sorted_ts[i] <= t + tol


def text(path, default=""):
    """A file's text with ANSI colour stripped, or `default` if it does not exist."""
    if not os.path.exists(path):
        return default
    return re.sub(r"\x1b\[[0-9;]*m", "", open(path, errors="replace").read())


def arrivals(path):
    with open(path) as f:
        return [(int(r["t_ns"]), int(r["pts"])) for r in csv.DictReader(f) if r["pts"]]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stimulus")
    ap.add_argument("out")
    ap.add_argument("--vpid", type=int, default=111)
    a = ap.parse_args()
    o = a.out

    stim, _ = units(a.stimulus, a.vpid)
    cut = split(stim)
    s0 = sorted(t for t, _ in stim[:cut])
    s1 = sorted(t for t, _ in stim[cut:])
    step = (stim[cut][0] - stim[cut - 1][0]) / 90
    print(f"stimulus: {len(s0):,} video units before the cut, {len(s1):,} after; step {step:+.0f} ms")

    sup = [ln.split() for ln in text(os.path.join(o, "supervisor.txt")).splitlines()]
    starts = {int(x[1]): float(x[2]) for x in sup if x and x[0] == "start"}
    exits = [(int(x[1]), int(x[2]), float(x[3])) for x in sup if x and x[0] == "exit"]
    for k, rc, t in exits:
        log = text(os.path.join(o, f"import-{k}.log"))
        err = [ln for ln in log.splitlines() if "error" in ln.lower()]
        nxt = starts.get(k + 1)
        gap = f", restarted in {(nxt - t) * 1e3:.0f} ms" if nxt else ""
        print(f"importer {k}: exit {rc}{gap}; {err[-1][-160:] if err else 'no error'}")

    src = arrivals(os.path.join(o, "source.csv"))
    rewind = next((t for (t, p), (_, q) in zip(src[1:], src) if p < q - JUMP), None)

    legs = {}
    for leg in ("a", "b"):
        path = os.path.join(o, f"egress-{leg}.ts")
        if not os.path.exists(path) or os.path.getsize(path) < TS:
            print(f"leg {leg}: no output")
            continue
        seq, flag = units(path, a.vpid)
        brk = split(seq, flag)
        legs[leg] = (path, seq, brk)
        if brk is None:
            print(f"leg {leg}: {len(seq):,} video units, no break: the export did not resume")
            continue
        pre = [t for t, _ in seq[:brk]]
        post = [t for t, _ in seq[brk:]]
        pre_last, post_first = max(pre), min(post)
        lost = ((max(s0) - pre_last) + (post_first - min(s1))) / 90
        hole0 = sum(1 for t in s0 if min(pre) < t < pre_last and not near(sorted(pre), t))
        hole1 = sum(1 for t in s1 if post_first < t < max(post) and not near(sorted(post), t))
        foreign = sum(1 for t in pre if not near(s0, t)) + sum(1 for t in post if not near(s1, t))
        eg = arrivals(os.path.join(o, f"egress-{leg}.csv"))
        gaps = sorted(((b[0] - c[0]) / 1e6, c[0]) for b, c in zip(eg[1:], eg))
        wire, at = gaps[-1] if gaps else (float("nan"), 0)
        resume = next((t for t, _ in eg if t > at), None)
        sent = {p: t for t, p in src}
        # The export's PTS round-trip through microseconds, so match to a tick either way.
        match = [(t, next((sent[q] for q in (p, p + 1, p - 1) if q in sent), None)) for t, p in eg]
        lat = [t - s for t, s in match if s is not None and (rewind is None or t < rewind)]
        base = statistics.median(lat) if lat else 0
        since = (resume - rewind - base) / 1e6 if resume and rewind else float("nan")
        print(
            f"leg {leg}: {len(pre):,} units before the break, {len(post):,} after; programme lost {lost:.0f} ms; "
            f"wire gap {wire:.0f} ms; from the rewind {since:.0f} ms beyond the latency ({base / 1e6:.0f} ms); "
            f"holes {hole0} before, {hole1} after; foreign {foreign}; flag at packet {flag}, break at {seq[brk][1]}"
        )
        ex = text(os.path.join(o, f"export-{leg}.exit"), "running").split()
        log = text(os.path.join(o, f"export-{leg}.log"))
        late = log.count("missed its deadline")
        err = [ln for ln in log.splitlines() if "Error" in ln]
        print(f"   export exit {ex[0]}; late drops {late}; {err[-1][-140:] if err else 'no error'}")

    if len(legs) == 2:
        pa, pb = legs["a"][0], legs["b"][0]
        da, db = open(pa, "rb").read(), open(pb, "rb").read()
        n = min(len(da), len(db)) // TS
        first = next((k for k in range(n) if da[k * TS : (k + 1) * TS] != db[k * TS : (k + 1) * TS]), None)
        same = sum(1 for k in range(n) if da[k * TS : (k + 1) * TS] == db[k * TS : (k + 1) * TS])
        brk = legs["a"][1][legs["a"][2]][1] if legs["a"][2] is not None else None
        where = "" if first is None or brk is None else (" (before the break)" if first < brk else " (after the break)")
        state = "identical" if first is None else f"first difference at packet {first:,}{where}"
        print(f"1+1: {n:,} packets in common, {same:,} identical ({100 * same / max(n, 1):.2f} %); {state}")
        if first is not None:
            # Whether each PID carries the same packets in the same order, so that the legs differ
            # only in how the PIDs interleave.
            per = {}
            for leg, d in (("a", da), ("b", db)):
                for k in range(n):
                    p = d[k * TS : (k + 1) * TS]
                    per.setdefault((leg, ((p[1] & 0x1F) << 8) | p[2]), []).append(p)
            pids = sorted({pid for _, pid in per})
            unequal = [pid for pid in pids if per.get(("a", pid), []) != per.get(("b", pid), [])]
            shorter = [
                pid
                for pid in unequal
                if per.get(("a", pid), [])[: len(per.get(("b", pid), []))]
                == per.get(("b", pid), [])[: len(per.get(("a", pid), []))]
            ]
            print(
                f"     per PID: {len(pids) - len(unequal)} of {len(pids)} identical; differing only in length at the "
                f"capture's end: {shorter}; differing in content: {[p for p in unequal if p not in shorter]}"
            )


if __name__ == "__main__":
    main()
