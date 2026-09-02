#!/usr/bin/env python3
"""Positional PCR spacing: where the PCR packets sit in the byte stream.

The value domain and the positional domain can disagree. #2967 put the PCR
*values* on a 25 ms grid; #3006 is about whether the packets carrying them are
also *spaced* 25 ms apart in the stream. A receiver clock recovers from arrival
time, so a correct value in a badly-placed packet still jitters the PLL.
"""
import collections
import statistics
import sys

path = sys.argv[1]
rate_bps = float(sys.argv[2]) if len(sys.argv) > 2 else 9945951.0

pcr_idx = []
pcr_val = []
idx = 0
with open(path, "rb") as f:
    while True:
        p = f.read(188)
        if len(p) < 188 or p[0] != 0x47:
            break
        afc = (p[3] >> 4) & 0x3
        if afc in (2, 3) and p[4] > 0 and (p[5] & 0x10):
            b = p[6:12]
            base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
            ext = ((b[4] & 0x01) << 8) | b[5]
            pcr_idx.append(idx)
            pcr_val.append(base * 300 + ext)
        idx += 1

gaps = [b - a for a, b in zip(pcr_idx, pcr_idx[1:])]
# Packets per 25 ms at the nominal rate: the spacing an even grid would produce.
expected = (rate_bps * 0.025) / (188 * 8)

print(f"PCR packets: {len(pcr_idx)} over {idx} TS packets")
print(f"expected gap for an even 25 ms grid at {rate_bps/1e6:.3f} Mb/s: {expected:.1f} packets")
print()
print("--- positional gap between successive PCR packets (TS packets) ---")
print(f"mean {statistics.mean(gaps):.1f}   median {statistics.median(gaps):.1f}   "
      f"min {min(gaps)}   max {max(gaps)}")
b2b = sum(1 for g in gaps if g == 1)
near = sum(1 for g in gaps if g <= 5)
print(f"back-to-back (gap==1): {b2b} ({100*b2b/len(gaps):.1f}%)")
print(f"clustered  (gap<=5):   {near} ({100*near/len(gaps):.1f}%)")

# Positional interval expressed as time, which is what a receiver's PLL sees.
print()
print("--- the same gaps as arrival-time intervals at nominal rate ---")
ms = [g * 188 * 8 / rate_bps * 1000 for g in gaps]
over40 = sum(1 for m in ms if m > 40)
print(f"mean {statistics.mean(ms):.2f} ms   min {min(ms):.3f}   max {max(ms):.1f}")
print(f"intervals >40 ms (P1 gate): {over40} ({100*over40/len(ms):.2f}%)")

print()
print("histogram of positional gaps (packets):")
h = collections.Counter()
for g in gaps:
    if g == 1:
        h["1 (back-to-back)"] += 1
    elif g <= 5:
        h["2-5"] += 1
    elif g <= 50:
        h["6-50"] += 1
    elif g <= 140:
        h["51-140"] += 1
    elif g <= 190:
        h["141-190 (on grid)"] += 1
    else:
        h[">190"] += 1
for k in ["1 (back-to-back)", "2-5", "6-50", "51-140", "141-190 (on grid)", ">190"]:
    if h[k]:
        print(f"  {k:22s} {h[k]:6d}  ({100*h[k]/len(gaps):5.1f}%)")
