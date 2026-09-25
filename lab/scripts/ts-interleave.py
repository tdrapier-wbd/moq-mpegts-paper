#!/usr/bin/env python3
"""Do two renderings of one broadcast interleave its access units in the same order?

moq-dev#2829: the exporter's interleave was decided by arrival, so two subscribers of one
broadcast placed the same frames in different orders. A packet-slot comparison cannot grade that
on any build whose PCR grid is anchored per process, because every slot after the first
difference is offset and the residue measures the offset rather than the order. This keys each
access unit by what it is — its PID and PTS — and asks only about order.

For each leg it lists the access units (a PES start on a PID that carries a PTS) in emission order,
keeps those both legs carry, and reports:

  - the fraction of adjacent pairs in B that A emits in the same order (1.0 = same interleave);
  - the same fraction for pairs on *different* PIDs only, which is where an interleave can differ;
  - per PID, how many access units each leg carries in the shared span.

Usage: ts-interleave.py <a.ts> <b.ts>
"""

import sys
from collections import Counter

TS = 188


def access_units(path):
    """(pid, pts) for every PES start carrying a PTS, in file order."""
    out = []
    with open(path, "rb") as f:
        data = f.read()
    for off in range(0, len(data) - TS + 1, TS):
        p = data[off : off + TS]
        if p[0] != 0x47 or not p[1] & 0x40:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        afc = (p[3] >> 4) & 3
        if pid == 0x1FFF or not afc & 1:
            continue
        i = 4
        if afc & 2:
            i += 1 + p[4]
        if i + 14 > TS or p[i : i + 3] != b"\x00\x00\x01":
            continue
        if not p[i + 7] & 0x80:
            continue
        b = p[i + 9 : i + 14]
        pts = ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
        out.append((pid, pts))
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = access_units(sys.argv[1]), access_units(sys.argv[2])
    shared = set(a) & set(b)
    a = [u for u in a if u in shared]
    b = [u for u in b if u in shared]
    pos = {u: i for i, u in enumerate(a)}
    pairs = cross = same = same_cross = 0
    for u, v in zip(b, b[1:]):
        ok = pos[u] < pos[v]
        pairs += 1
        same += ok
        if u[0] != v[0]:
            cross += 1
            same_cross += ok
    print(f"access units: A {len(a):,}  B {len(b):,}  shared {len(shared):,}")
    if not pairs:
        sys.exit("no shared access units: the legs do not overlap")
    print(f"  adjacent pairs in the same order     {same:,} / {pairs:,} ({100.0 * same / pairs:.2f} %)")
    if cross:
        print(f"  of which cross-PID pairs, same order {same_cross:,} / {cross:,} ({100.0 * same_cross / cross:.2f} %)")
    print("  access units per PID over the shared span:")
    for p, n in sorted(Counter(u[0] for u in b).items()):
        print(f"    {p:#06x}: {n:,}")


if __name__ == "__main__":
    main()
