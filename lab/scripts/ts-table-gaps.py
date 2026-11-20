#!/usr/bin/env python3
"""Repetition gaps of PAT, PMT, SDT actual and NIT actual in a TS file, timed by PCR interpolation."""
import bisect
import statistics
import sys

data = open(sys.argv[1], "rb").read()
n = len(data) // 188
pkts = [data[i * 188:(i + 1) * 188] for i in range(n)]


def pid(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def payload(p):
    afc = (p[3] >> 4) & 3
    if afc in (0, 2):
        return b""
    off = 4 + (1 + p[4] if afc == 3 else 0)
    return p[off:]


pcr_pid, pcrs, wrap, last = None, [], (1 << 33) * 300, None
for i, p in enumerate(pkts):
    if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
        if pcr_pid is None:
            pcr_pid = pid(p)
        if pid(p) != pcr_pid:
            continue
        base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
        v = base * 300 + (((p[10] & 1) << 8) | p[11])
        if last is not None:
            v = last + (v - last % wrap) % wrap
        last = v
        pcrs.append((i, v))
idx = [i for i, _ in pcrs]


def at(i):
    k = min(max(bisect.bisect_right(idx, i), 1), len(pcrs) - 1)
    (i0, v0), (i1, v1) = pcrs[k - 1], pcrs[k]
    return (v0 + (v1 - v0) * (i - i0) / (i1 - i0)) / 27e6


pmt_pid = None
for p in pkts:
    if pid(p) == 0 and p[1] & 0x40:
        pl = payload(p)
        s = pl[1 + pl[0]:]
        ln = ((s[1] & 0xF) << 8) | s[2]
        body = s[8:3 + ln - 4]
        for j in range(0, len(body), 4):
            prog = (body[j] << 8) | body[j + 1]
            if prog:
                pmt_pid = ((body[j + 2] & 0x1F) << 8) | body[j + 3]
                break
        break

want = {"PAT": (0, None, 0.5), "PMT": (pmt_pid, None, 0.5), "SDT": (0x11, 0x42, 2.0), "NIT": (0x10, 0x40, 10.0)}
times = {k: [] for k in want}
for i, p in enumerate(pkts):
    if not p[1] & 0x40:
        continue
    for k, (wp, tid, _) in want.items():
        if pid(p) == wp:
            pl = payload(p)
            if not pl:
                continue
            t = pl[1 + pl[0]] if 1 + pl[0] < len(pl) else None
            if tid is None or t == tid:
                times[k].append(at(i))

span = at(n - 1) - at(0)
print(f"{sys.argv[1]}: {span:.1f}s, PCR PID {pcr_pid:#x}, PMT PID {pmt_pid:#x}")
for k, (_, _, limit) in want.items():
    ts = times[k]
    if len(ts) < 2:
        print(f"  {k}: {len(ts)} sections")
        continue
    gaps = [b - a for a, b in zip(ts, ts[1:])]
    over = sum(g > limit for g in gaps)
    print(
        f"  {k}: {len(ts)} sections, gap median {statistics.median(gaps) * 1e3:.0f} ms, "
        f"max {max(gaps) * 1e3:.0f} ms, {over}/{len(gaps)} over {limit * 1e3:.0f} ms"
    )
