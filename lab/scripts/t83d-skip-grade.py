#!/usr/bin/env python3
"""Grade t83d-skip.sh's receiving half: for each burst and each export, the groups it skipped.

    t83d-skip-grade.py <run dir> [--json]

A skip is either an eviction the export logged ("current group evicted") or a forward jump in its
video PES timestamps (DTS, else PTS) that loses more than 0.1 s, the content lost being the jump less
one frame; single-frame steps occur in a whole stream.
Each is attributed to the burst whose window holds it, from the burst's start to the
next burst's, by the export's log time or by the jump's arrival at the tap; the control is the
window from 15 s after the exports start to the first burst.
"""

import argparse
import bisect
import json
import mmap
import re
import statistics
import sys
from datetime import datetime

VIDEO = {0x01, 0x02, 0x10, 0x1B, 0x24}
EVICT = re.compile(r"^\S*?(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z).*current group evicted")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def events(run):
    ev = []
    for line in open(f"{run}/events.txt"):
        f = line.split()
        ev.append((f[0], f[1:-1], float(f[-1])))
    return ev


def windows(ev):
    starts = [t for n, _, t in ev if n.startswith("export_start")]
    bursts = [(a[0], int(a[1]), t) for n, a, t in ev if n == "burst_on"]
    end = next(t for n, _, t in ev if n == "rcv_end")
    w = [("control", 0, max(starts) + 15, bursts[0][2])]
    for i, (d, r, t) in enumerate(bursts):
        w.append((d, r, t, bursts[i + 1][2] if i + 1 < len(bursts) else end))
    return w


def section(pkt):
    off = 4 + (1 + pkt[4] if pkt[3] & 0x20 else 0)
    return pkt[off + 1 + pkt[off] :]


def video_jumps(prefix):
    offs, times = [], []
    for line in open(prefix + ".idx"):
        o, t = line.split(",")
        offs.append(int(o))
        times.append(float(t))
    with open(prefix + ".ts", "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        pmt = vid = None
        stamps = []
        for o in range(0, len(m) - 187, 188):
            pkt = m[o : o + 188]
            if pkt[0] != 0x47 or not pkt[1] & 0x40:
                continue
            pid = (pkt[1] & 0x1F) << 8 | pkt[2]
            try:
                if pid == 0 and pmt is None:
                    s = section(pkt)
                    n = ((s[1] & 0x0F) << 8 | s[2]) - 9
                    for i in range(8, 8 + n, 4):
                        if s[i] << 8 | s[i + 1]:
                            pmt = (s[i + 2] & 0x1F) << 8 | s[i + 3]
                            break
                elif pid == pmt and vid is None:
                    s = section(pkt)
                    end = 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4
                    i = 12 + ((s[10] & 0x0F) << 8 | s[11])
                    while i < end:
                        if s[i] in VIDEO:
                            vid = (s[i + 1] & 0x1F) << 8 | s[i + 2]
                            break
                        i += 5 + ((s[i + 3] & 0x0F) << 8 | s[i + 4])
                elif pid == vid:
                    p = pkt[4 + (1 + pkt[4] if pkt[3] & 0x20 else 0) :]
                    if p[:3] != b"\x00\x00\x01" or not p[7] & 0x80:
                        continue
                    b = p[14:19] if p[7] & 0x40 else p[9:14]
                    ts = (b[0] >> 1 & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
                    stamps.append((ts, times[max(0, bisect.bisect_right(offs, o) - 1)]))
            except IndexError:
                continue
    if len(stamps) < 3:
        return vid, None, []
    frame = statistics.median(b[0] - a[0] for a, b in zip(stamps, stamps[1:]) if b[0] > a[0])
    jumps = [
        (t, (b - a - frame) / 90000)
        for (a, _), (b, t) in zip(stamps, stamps[1:])
        if b - a > frame + 9000 and b - a < 90000 * 60
    ]
    return vid, frame / 90000, jumps


def evictions(log):
    out = []
    for line in open(log, errors="replace"):
        g = EVICT.match(ANSI.sub("", line))
        if g:
            out.append(datetime.fromisoformat(g.group(1).replace("Z", "+00:00")).timestamp())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    ev = events(a.run)
    w = windows(ev)
    names = [n[len("export_start_") :] for n, _, _ in ev if n.startswith("export_start")]
    res = {"windows": [list(x) for x in w], "exports": {}}
    for n in names:
        vid, frame, jumps = video_jumps(f"{a.run}/{n}")
        evs = evictions(f"{a.run}/{n}.log")
        rows = []
        for d, r, t0, t1 in w:
            js = [j for j in jumps if t0 <= j[0] < t1]
            rows.append(
                {
                    "burst": d,
                    "rep": r,
                    "evictions": sum(1 for t in evs if t0 <= t < t1),
                    "jumps": len(js),
                    "lost_s": round(sum(j[1] for j in js), 3),
                }
            )
        outside = len(jumps) - sum(x["jumps"] for x in rows)
        res["exports"][n] = {"video_pid": vid, "frame_s": frame, "rows": rows, "jumps_outside": outside}
    if a.json:
        json.dump(res, sys.stdout, indent=1)
        return
    print("burst rep " + " ".join(f"{n}:evict,jumps,lost_s" for n in names))
    for i, (d, r, _, _) in enumerate(w):
        cells = []
        for n in names:
            x = res["exports"][n]["rows"][i]
            cells.append(f"{x['evictions']},{x['jumps']},{x['lost_s']}")
        print(f"{d} {r} " + " ".join(cells))
    for n in names:
        e = res["exports"][n]
        print(f"{n}: video PID {e['video_pid']}, frame {e['frame_s']} s, jumps outside windows {e['jumps_outside']}")


if __name__ == "__main__":
    main()
