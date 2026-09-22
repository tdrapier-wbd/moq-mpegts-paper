#!/usr/bin/env python3
"""What is left for a groomer once #3006 (pacing) and #3831 (stuffing) have landed?

Reads a `moq export ts` capture and separates two things the single phrase "pacing" conflates:

  1. PCR *interval* in the stream's own timebase  — do PCRs recur inside TR 101 290 P1's 40 ms?
  2. Bytes carried *between* consecutive PCRs      — is the byte delivery between them uniform,
     which is what makes the file a valid constant-rate stream and what P2 accuracy grades?

A stream can pass (1) and fail (2): the PCR values are right and the packets between them are
unevenly distributed, so a receiver clocking off byte arrival sees the clock wander.
"""
import sys, statistics

TS = 188
def pcrs(path):
    out = []
    with open(path, 'rb') as f:
        data = f.read()
    # find alignment
    off = next((i for i in range(TS) if all(data[i+k*TS] == 0x47 for k in range(20) if i+k*TS < len(data))), 0)
    n = (len(data) - off) // TS
    for k in range(n):
        p = data[off + k*TS: off + (k+1)*TS]
        if p[0] != 0x47: continue
        if not (p[3] & 0x20): continue               # adaptation field present?
        if p[4] == 0: continue
        if not (p[5] & 0x10): continue               # PCR flag
        base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
        ext = ((p[10] & 0x01) << 8) | p[11]
        out.append((k, base * 300 + ext))            # (packet index, PCR in 27 MHz)
    return out, n

path = sys.argv[1]
p, total = pcrs(path)
if len(p) < 50:
    print("too few PCRs"); raise SystemExit(1)

iv, bytes_between, inst_rate = [], [], []
for (k0, c0), (k1, c1) in zip(p, p[1:]):
    d = (c1 - c0) / 27e6
    if d <= 0 or d > 5: continue                     # discontinuity / wrap
    iv.append(d * 1000)
    nb = (k1 - k0) * TS
    bytes_between.append(nb)
    inst_rate.append(nb * 8 / d)

span = (p[-1][1] - p[0][1]) / 27e6
nominal = (p[-1][0] - p[0][0]) * TS * 8 / span

print(f"{path}: {total:,} TS packets, {len(p):,} PCRs, {span:.1f} s")
print(f"nominal rate over the whole capture: {nominal:,.0f} b/s")
print()
print("1. PCR interval (the slot spacing)")
print(f"   median {statistics.median(iv):.2f} ms   p95 {sorted(iv)[int(len(iv)*.95)]:.2f} ms   max {max(iv):.2f} ms")
over = sum(1 for x in iv if x > 40)
print(f"   over TR 101 290 P1's 40 ms: {over} of {len(iv)}  ({over/len(iv)*100:.2f} %)")
print()
print("2. Bytes carried between consecutive PCRs (the CBR property)")
m = statistics.median(inst_rate)
print(f"   instantaneous rate: median {m:,.0f} b/s   min {min(inst_rate):,.0f}   max {max(inst_rate):,.0f}")
print(f"   spread: {(max(inst_rate)-min(inst_rate))/m*100:,.0f} % of median")
within = lambda pct: sum(1 for r in inst_rate if abs(r-nominal)/nominal*100 <= pct)
for pct in (1, 5, 10, 25):
    print(f"   within {pct:>2} % of nominal: {within(pct):>6,} of {len(inst_rate):,}  ({within(pct)/len(inst_rate)*100:5.1f} %)")
