#!/usr/bin/env python3
"""T51: did both publishers of a run read the same bytes?

    t51-feedcheck.py <run-dir>...

Finds where in-pub2.ts (the later publisher's input) starts inside in-pub.ts and compares the two
over their overlap. Prints the standby's start in seconds of the first input (at the clip's mean
rate) and `same` or the first differing byte.
"""

import sys

PROBE = 188 * 10

for run in sys.argv[1:]:
    a = open(f"{run}/in-pub.ts", "rb").read()
    b = open(f"{run}/in-pub2.ts", "rb").read()
    skip = 188 * 4
    at = a.find(b[skip : skip + PROBE])
    if at < 0:
        print(f"{run}: the standby's input is not found in the first's")
        continue
    start = at - skip
    n = min(len(b), len(a) - start)
    step = 1 << 16
    differ = next((i for i in range(0, n, step) if a[start + i : start + min(i + step, n)] != b[i : min(i + step, n)]), None)
    rate = 793_000 * 188 / 120
    verdict = "same" if differ is None else f"differs within 64 KiB of byte {differ}"
    print(f"{run}: standby starts {start / rate:.2f} s into the first's input; overlap {n / rate:.1f} s; {verdict}")
