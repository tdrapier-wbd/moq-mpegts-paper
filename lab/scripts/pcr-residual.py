#!/usr/bin/env python3
"""Separate the two things the word "pacing" conflates, and grade a capture on both.

  1. PCR *interval* in the stream's own timebase  — do PCRs recur inside TR 101 290 P1's 40 ms?
  2. Bytes carried *between* consecutive PCRs      — is byte delivery uniform, which is what
     makes the file a valid constant-rate stream and what a P2 accuracy gate grades?

A stream can pass (1) and fail (2): the PCR values are right and the packets between them are
unevenly distributed, so a receiver clocking off byte arrival sees the clock wander. The two are
read from one capture — the interval from the carried values, the rate from the packet count
over the same pair — so they cannot disagree about which stream they describe.

**PCR is read from one PID.** Pooling PCRs across PIDs produces a meaningless interval series:
two PIDs each on a correct 25 ms grid, offset from one another, read as a 12.5 ms grid with half
the bytes between samples. The PID carrying the most PCRs is used unless one is named, and every
PCR-bearing PID is reported so a pooled reading cannot be made by accident.

  pcr-residual.py <capture.ts> [--pid N] [--nominal BPS]
"""
import statistics
import sys

TS = 188


def load(path):
    with open(path, 'rb') as f:
        data = f.read()
    off = 0
    for i in range(TS):
        if all(data[i + k * TS] == 0x47 for k in range(40) if i + k * TS < len(data)):
            off = i
            break
    return data, off, (len(data) - off) // TS


def scan(data, off, n):
    """Every PCR in the file, as {pid: [(packet_index, pcr_27mhz), ...]}, plus the null count."""
    by_pid = {}
    nulls = 0
    for k in range(n):
        p = data[off + k * TS: off + (k + 1) * TS]
        if p[0] != 0x47:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        if pid == 0x1FFF:
            nulls += 1
            continue
        if not (p[3] & 0x20) or p[4] == 0 or not (p[5] & 0x10):
            continue                                    # no adaptation field, or no PCR flag
        base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
        ext = ((p[10] & 0x01) << 8) | p[11]
        by_pid.setdefault(pid, []).append((k, base * 300 + ext))
    return by_pid, nulls


def pct(sorted_vals, q):
    if not sorted_vals:
        return 0
    return sorted_vals[min(len(sorted_vals) - 1, int(len(sorted_vals) * q))]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = {a.split('=')[0]: a.split('=')[1] for a in sys.argv[1:] if a.startswith('--') and '=' in a}
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    data, off, total = load(path)
    by_pid, nulls = scan(data, off, total)
    if not by_pid:
        print(f"{path}: {total:,} packets, no PCR found")
        return 1

    print(f"{path}: {total:,} TS packets, {nulls:,} null ({nulls / total * 100:.2f} %)")
    print("PCR-bearing PIDs: " + ", ".join(
        f"0x{p:04X} ({len(v):,})" for p, v in sorted(by_pid.items(), key=lambda kv: -len(kv[1]))))

    want = int(opts['--pid'], 0) if '--pid' in opts else max(by_pid, key=lambda p: len(by_pid[p]))
    pcrs = by_pid.get(want)
    if not pcrs or len(pcrs) < 50:
        print(f"PID 0x{want:04X}: too few PCRs to grade")
        return 1
    print(f"grading PID 0x{want:04X}\n")

    iv, nbytes, rate = [], [], []
    for (k0, c0), (k1, c1) in zip(pcrs, pcrs[1:]):
        d = (c1 - c0) / 27e6
        if d <= 0 or d > 5:
            continue                                    # discontinuity or wrap
        iv.append(d * 1000)
        nb = (k1 - k0) * TS
        nbytes.append(nb)
        rate.append(nb * 8 / d)

    span = (pcrs[-1][1] - pcrs[0][1]) / 27e6
    measured = (pcrs[-1][0] - pcrs[0][0]) * TS * 8 / span
    nominal = float(opts.get('--nominal', measured))
    need = nominal * (statistics.median(iv) / 1000) / 8       # bytes a CBR stream puts in a slot

    print(f"{len(pcrs):,} PCRs over {span:.1f} s")
    print(f"rate over the whole capture: {measured:,.0f} b/s"
          + (f"   (graded against {nominal:,.0f} b/s)" if '--nominal' in opts else ""))
    print()
    print("1. PCR interval — the slot spacing")
    s = sorted(iv)
    # The minimum is reported because clustering shows up as *short* intervals, and a series
    # quoted by median and maximum alone hides them: a grid with half its PCRs bunched into
    # sub-millisecond pairs still reads as a correct median and a correct maximum.
    print(f"   min {min(iv):.3f} ms   median {statistics.median(iv):.2f} ms"
          f"   p95 {pct(s, .95):.2f} ms   max {max(iv):.2f} ms")
    over = sum(1 for x in iv if x > 40)
    under = sum(1 for x in iv if x < 1)
    print(f"   over TR 101 290 P1's 40 ms: {over:,} of {len(iv):,}  ({over / len(iv) * 100:.2f} %)")
    print(f"   under 1 ms (clustering):    {under:,} of {len(iv):,}  ({under / len(iv) * 100:.2f} %)")
    print()
    print("2. Bytes between consecutive PCRs — the constant-rate property")
    sb = sorted(nbytes)
    print(f"   a stream at {nominal:,.0f} b/s needs {need:,.0f} B in every slot")
    print(f"   min {sb[0]:,}  p10 {pct(sb, .10):,}  p25 {pct(sb, .25):,}  median {statistics.median(nbytes):,.0f}"
          f"  p75 {pct(sb, .75):,}  p90 {pct(sb, .90):,}  p99 {pct(sb, .99):,}  max {sb[-1]:,}")
    m = statistics.median(rate)
    print(f"   instantaneous rate: median {m:,.0f} b/s   min {min(rate):,.0f}   max {max(rate):,.0f}")
    print(f"   spread: {(max(rate) - min(rate)) / m * 100:,.0f} % of median")
    for q in (1, 5, 10, 25):
        w = sum(1 for r in rate if abs(r - nominal) / nominal * 100 <= q)
        print(f"   within {q:>2} % of nominal: {w:>7,} of {len(rate):,}  ({w / len(rate) * 100:5.1f} %)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
