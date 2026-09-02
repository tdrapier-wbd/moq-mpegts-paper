#!/usr/bin/env python3
"""Time-domain PCR arrival: when the exporter actually released the bytes.

#3006 paces `moq export ts`'s stdout writes on each frame's timestamp. That is a
property of *release time*, not of byte layout, so a file capture cannot grade it
-- writing to a file flattens the timing the fix exists to create. This reads the
export live off a pipe and timestamps every PCR-bearing packet as it arrives.

Granularity is bounded by the writer's burst size, which is the point: if the
export is paced, bursts are small and spaced ~25 ms; if it is not, the reader
drains a whole group at pipe speed and sees near-zero intervals then a stall.
"""
import collections
import statistics
import sys
import time

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0

arrivals = []
buf = b""
t0 = time.monotonic()
fd = sys.stdin.buffer
total = 0

while time.monotonic() - t0 < dur:
    chunk = fd.read(188)
    if not chunk:
        break
    now = time.monotonic()
    buf += chunk
    # Resync if the stream is not packet-aligned at our read boundary.
    while len(buf) >= 188:
        if buf[0] != 0x47:
            buf = buf[1:]
            continue
        p = buf[:188]
        buf = buf[188:]
        total += 1
        afc = (p[3] >> 4) & 0x3
        if afc in (2, 3) and p[4] > 0 and (p[5] & 0x10):
            arrivals.append(now)

if len(arrivals) < 3:
    print(f"too few PCRs to grade ({len(arrivals)}) over {total} packets")
    sys.exit(0)

iv = [(b - a) * 1000.0 for a, b in zip(arrivals, arrivals[1:])]
span = arrivals[-1] - arrivals[0]


def pct(xs, p):
    s = sorted(xs)
    k = min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))
    return s[k]


print(f"PCR packets seen: {len(arrivals)} over {total} TS packets in {span:.1f}s "
      f"({len(arrivals)/span:.1f} PCR/s)")
print()
print("--- PCR inter-arrival at the pipe (time domain, what a receiver PLL sees) ---")
print(f"mean {statistics.mean(iv):.2f} ms   median {statistics.median(iv):.2f} ms   "
      f"min {min(iv):.3f}   max {max(iv):.1f}")
print(f"p95 {pct(iv, 95):.2f} ms   p99 {pct(iv, 99):.2f} ms   "
      f"p99.9 {pct(iv, 99.9):.2f} ms")
print(f"stdev {statistics.pstdev(iv):.2f} ms")
over40 = sum(1 for m in iv if m > 40)
sub1 = sum(1 for m in iv if m < 1)
print(f"intervals >40 ms (P1 gate): {over40} ({100*over40/len(iv):.2f}%)")
print(f"intervals <1 ms (arrived in a burst): {sub1} ({100*sub1/len(iv):.2f}%)")

# This reader's own scheduling, because on a busy host a starved reader is
# indistinguishable from a late write and the whole point of re-running on a
# larger machine is to tell those apart. nivcsw is involuntary preemption: a
# reader that was never preempted cannot have invented a stall.
try:
    with open("/proc/self/status") as f:
        st = dict(
            line.split(":", 1) for line in f if ":" in line
        )
    vol = st.get("voluntary_ctxt_switches", "?").strip()
    invol = st.get("nonvoluntary_ctxt_switches", "?").strip()
    print()
    print(f"--- this reader's scheduling ---")
    print(f"voluntary ctxt switches {vol}   involuntary (preempted) {invol}")
    if invol.isdigit() and span > 0:
        print(f"involuntary preemptions per second: {int(invol)/span:.1f}")
except OSError:
    pass

print()
print("histogram of inter-arrival (ms):")
h = collections.Counter()
for m in iv:
    if m < 1:
        h["<1 (burst)"] += 1
    elif m < 5:
        h["1-5"] += 1
    elif m < 15:
        h["5-15"] += 1
    elif m < 22:
        h["15-22"] += 1
    elif m <= 28:
        h["22-28 (on grid)"] += 1
    elif m <= 40:
        h["28-40"] += 1
    else:
        h[">40 (fails P1)"] += 1
for k in ["<1 (burst)", "1-5", "5-15", "15-22", "22-28 (on grid)", "28-40", ">40 (fails P1)"]:
    if h[k]:
        print(f"  {k:18s} {h[k]:6d}  ({100*h[k]/len(iv):5.1f}%)")
