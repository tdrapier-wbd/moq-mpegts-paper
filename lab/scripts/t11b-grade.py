#!/usr/bin/env python3
"""T11b oracle: compare a TS received through a relay against the source, per PID.

usage: t11b-grade.py <source.ts> <received.ts> [--rewritten 0,100] [--dropped 16,17,20]

A PID listed as rewritten is compared with its continuity counters masked and
may repeat (a publisher re-sending PSI); a dropped PID must be absent; every
other PID must arrive as exactly the source's packet sequence.
"""
import argparse
import collections
import sys


def packets(path):
    data = open(path, "rb").read()
    if len(data) % 188:
        sys.exit(f"{path}: {len(data)} bytes is not a whole number of 188-byte packets")
    for i in range(0, len(data), 188):
        p = data[i : i + 188]
        if p[0] != 0x47:
            sys.exit(f"{path}: packet {i // 188} has no sync byte")
        yield p


def by_pid(path):
    out = collections.defaultdict(list)
    for p in packets(path):
        out[((p[1] & 0x1F) << 8) | p[2]].append(p)
    return out


def mask_cc(p):
    return p[:3] + bytes([p[3] & 0xF0]) + p[4:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("received")
    ap.add_argument("--rewritten", default="0,100")
    ap.add_argument("--dropped", default="16,17,20")
    a = ap.parse_args()
    rewritten = {int(x) for x in a.rewritten.split(",") if x}
    dropped = {int(x) for x in a.dropped.split(",") if x}
    src, rx = by_pid(a.source), by_pid(a.received)
    ok = True
    for pid in sorted(set(src) | set(rx)):
        s, r = src.get(pid, []), rx.get(pid, [])
        if pid in dropped:
            verdict = "absent" if not r else f"PRESENT ({len(r)})"
            ok &= not r
        elif pid in rewritten:
            distinct_src = {mask_cc(p) for p in s}
            foreign = [p for p in r if mask_cc(p) not in distinct_src]
            verdict = f"{len(r)} vs {len(s)} source, {len(foreign)} not in source (CC masked)"
        elif pid == 0x1FFF:
            verdict = f"{len(r)} vs {len(s)} null"
            ok &= len(r) == len(s)
        elif s == r:
            verdict = "identical"
        else:
            n = min(len(s), len(r))
            first = next((i for i in range(n) if s[i] != r[i]), n)
            verdict = f"DIFFER: {len(r)} vs {len(s)} packets, first difference at packet {first}"
            ok = False
        print(f"PID {pid:5d}  src {len(s):6d}  rx {len(r):6d}  {verdict}")
    print("VERDICT", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
