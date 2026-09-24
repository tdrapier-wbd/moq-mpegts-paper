#!/usr/bin/env python3
"""Measure what a continuity count can and cannot say about how much was lost.

The transport continuity_counter is four bits. A receiver detects a gap by comparing the counter
it got against the one it expected, so the largest loss it can distinguish is fifteen packets on
one PID: sixteen consecutive losses restore the expected value and are indistinguishable from no
loss at all. Every continuity figure in this campaign is therefore a *detector* reading, and this
establishes the boundary between what it detects and what it can quantify.

Excises a known number of packets from one PID of a real capture and reports what
`tsp -P continuity` says about it. Run with several sizes to see the aliasing.

Usage: cc-aliasing-probe.py <input.ts> [--pid N] [--sizes 1,5,10,15,16,17,32,160,1600]
"""

import argparse
import pathlib
import subprocess
import sys
import tempfile

PKT = 188


def read_packets(path):
    data = pathlib.Path(path).read_bytes()
    n = len(data) // PKT
    return data, n


def pid_of(pkt):
    return ((pkt[1] & 0x1F) << 8) | pkt[2]


def has_payload(pkt):
    # A packet with no payload does not advance the counter (ISO 13818-1 2.4.3.3), so excising
    # one is invisible to a continuity check for a reason that is not aliasing. Exclude them.
    return bool(pkt[3] & 0x10)


def busiest_pid(data, n):
    counts = {}
    for i in range(n):
        p = data[i * PKT : (i + 1) * PKT]
        if pid_of(p) != 0x1FFF:
            counts[pid_of(p)] = counts.get(pid_of(p), 0) + 1
    return max(counts, key=counts.get) if counts else None


def excise(data, n, pid, count, out):
    """Remove `count` consecutive payload-bearing packets of `pid`, starting a third of the way in."""
    def pkt(i):
        return data[i * PKT : (i + 1) * PKT]

    idx = [i for i in range(n) if pid_of(pkt(i)) == pid and has_payload(pkt(i))]
    if len(idx) < count + 20:
        return 0
    start = len(idx) // 3
    drop = set(idx[start : start + count])
    with open(out, "wb") as f:
        for i in range(n):
            if i not in drop:
                f.write(data[i * PKT : (i + 1) * PKT])
    return len(drop)


def grade(path):
    r = subprocess.run(
        ["tsp", "-I", "file", str(path), "-P", "continuity", "-O", "drop"],
        capture_output=True, text=True,
    )
    lines = [ln for ln in (r.stdout + r.stderr).splitlines() if "missing" in ln or "discontinuity" in ln.lower()]
    missing = 0
    for ln in lines:
        if "missing" in ln:
            tok = ln.split("missing", 1)[1].split()[0].replace(",", "")
            if tok.isdigit():
                missing += int(tok)
    return len(lines), missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--pid", type=int)
    ap.add_argument("--sizes", default="1,5,10,15,16,17,32,160,1600")
    a = ap.parse_args()

    data, n = read_packets(a.input)
    pid = a.pid if a.pid is not None else busiest_pid(data, n)
    if pid is None:
        sys.exit("no non-stuffing PID found")
    print(f"source: {a.input}  packets={n}  probing PID {pid} (0x{pid:04X})")
    print(f"{'EXCISED':>9} {'EVENTS':>8} {'REPORTED_MISSING':>18} {'RATIO':>8}")

    with tempfile.TemporaryDirectory() as td:
        for size in (int(s) for s in a.sizes.split(",")):
            out = pathlib.Path(td) / f"cut{size}.ts"
            got = excise(data, n, pid, size, out)
            if not got:
                print(f"{size:>9} {'--':>8} {'too few packets on PID':>18}")
                continue
            events, missing = grade(out)
            ratio = f"{missing / got:.3f}" if got else "-"
            print(f"{got:>9} {events:>8} {missing:>18} {ratio:>8}")


if __name__ == "__main__":
    main()
