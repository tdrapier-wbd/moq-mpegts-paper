#!/usr/bin/env python3
"""T82: what a resumed subscriber's output carried in a window of its reader's clock.

The reader's CSV gives the cumulative bytes it had read at each 0.1 s row, so a window [a, b) of
cell time is a byte range of the capture. Prints, for that range: packets per PID, video PES
starts, and the PCR span (first to last PCR, in seconds of programme time) against the window's
wall-clock length. A PCR span far longer than the window is output written ahead of real time.

usage: t82-burst.py <cell-dir> <abuser> <a> <b> [<a> <b> ...]   (times in s after t0)
"""

import bisect
import csv
import sys
from collections import Counter
from pathlib import Path


def offsets(cell, name):
    t0 = float(next(x for x in (cell / "meta.txt").read_text().split() if x.startswith("t0="))[3:])
    ts, bs = [], []
    with open(cell / f"{name}.csv") as f:
        for r in csv.DictReader(f):
            ts.append(float(r["t"]) - t0)
            bs.append(int(r["bytes"]))
    return ts, bs


def at(ts, bs, t):
    i = bisect.bisect_right(ts, t) - 1
    return bs[i] if i >= 0 else 0


def census(data):
    pids, pes, pcrs = Counter(), 0, []
    for i in range(0, len(data) - 187, 188):
        p = data[i : i + 188]
        if p[0] != 0x47:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pids[pid] += 1
        afc = (p[3] >> 4) & 3
        if pid == 111 and p[1] & 0x40:
            pes += 1
        if afc & 2 and p[4] >= 7 and p[5] & 0x10:
            base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
            ext = ((p[10] & 1) << 8) | p[11]
            pcrs.append((base * 300 + ext) / 27e6)
    return pids, pes, pcrs


def main():
    cell, name = Path(sys.argv[1]), sys.argv[2]
    ts, bs = offsets(cell, name)
    cap = (cell / f"{name}.ts").read_bytes()
    w = sys.argv[3:]
    for a, b in zip(map(float, w[::2]), map(float, w[1::2])):
        lo, hi = at(ts, bs, a) // 188 * 188, at(ts, bs, b) // 188 * 188
        pids, pes, pcrs = census(cap[lo:hi])
        n = sum(pids.values())
        span = pcrs[-1] - pcrs[0] if len(pcrs) > 1 else 0.0
        top = ", ".join(f"{k}:{v / n:.1%}" for k, v in pids.most_common(5)) if n else "-"
        print(
            f"[{a:.1f}, {b:.1f}) s: {hi - lo:,} B = {(hi - lo) * 8 / (b - a) / 1e6:.1f} Mb/s; "
            f"{n:,} packets ({top}); video PES {pes}; PCR {len(pcrs)}, span {span:.2f} s"
        )


if __name__ == "__main__":
    main()
