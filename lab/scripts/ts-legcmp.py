#!/usr/bin/env python3
"""Compare two TS renderings of one broadcast and attribute every difference to a PID.

Two `moq export ts` processes subscribed to the same broadcast should render the same
packets. Where they do not, the interesting question is not how many bytes differ but
*which field* and *on which PID*: a continuity counter is a known constant offset that a
receiver could in principle live with, whereas a table landing on a different frame moves
whole packets and changes what every later byte lines up against.

The legs start at different times, so they are aligned first by searching for a window of
B's packets inside A with the continuity counter masked (the counters are expected to
disagree, so an unmasked search would find nothing).

Reports, over the aligned overlap:
  - packets identical, and identical with the continuity counter masked;
  - for the residue, which PID it sits on and whether the two legs even agree on the PID.

Usage: ts-legcmp.py <a.ts> <b.ts> [--window N] [--skip N]
"""

import sys
from collections import Counter

PKT = 188
SYNC = 0xB8 if False else 0x47


def packets(path):
    data = open(path, "rb").read()
    start = data.find(bytes([SYNC]))
    if start < 0:
        sys.exit(f"{path}: no sync byte")
    # Trust the first sync byte only if the stream stays locked to it.
    while start + PKT * 8 < len(data):
        if all(data[start + i * PKT] == SYNC for i in range(8)):
            break
        start = data.find(bytes([SYNC]), start + 1)
    end = len(data) - (len(data) - start) % PKT
    return [data[i : i + PKT] for i in range(start, end, PKT)]


def pid(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def mask_cc(p):
    """Blank the continuity counter (byte 3, low nibble)."""
    return p[:3] + bytes([p[3] & 0xF0]) + p[4:]


def find_offset(a, b, window, skip):
    """Index in A where B's packet `skip` sits, by matching a masked run."""
    needle = [mask_cc(p) for p in b[skip : skip + window]]
    if len(needle) < window:
        sys.exit("leg B too short for the requested window")
    masked_a = [mask_cc(p) for p in a]
    first = needle[0]
    for i in range(len(masked_a) - window):
        if masked_a[i] != first:
            continue
        if masked_a[i : i + window] == needle:
            return i
    return None


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    opts = {x.split("=")[0]: x.split("=")[1] for x in sys.argv[1:] if "=" in x and x.startswith("--")}
    if len(args) != 2:
        sys.exit(__doc__)
    window = int(opts.get("--window", 64))
    skip = int(opts.get("--skip", 2000))

    a, b = packets(args[0]), packets(args[1])
    print(f"leg A: {len(a):,} packets    leg B: {len(b):,} packets")

    off = find_offset(a, b, window, skip)
    if off is None:
        sys.exit(
            "no alignment found: the legs share no run of "
            f"{window} packets even with the counter masked, so they are not "
            "rendering the same stream (not merely numbering it differently)"
        )
    print(f"aligned: B[{skip}] == A[{off}] over {window} packets (counter masked)")

    n = min(len(a) - off, len(b) - skip)
    same = same_masked = 0
    residue_pid = Counter()
    residue_kind = Counter()
    for i in range(n):
        pa, pb = a[off + i], b[skip + i]
        if pa == pb:
            same += 1
            same_masked += 1
            continue
        if mask_cc(pa) == mask_cc(pb):
            same_masked += 1
            continue
        if pid(pa) != pid(pb):
            residue_kind["different PID in the same slot"] += 1
            residue_pid[f"{pid(pa):#06x} vs {pid(pb):#06x}"] += 1
        else:
            residue_kind["same PID, different bytes"] += 1
            residue_pid[f"{pid(pa):#06x}"] += 1

    print(f"compared {n:,} packets from the aligned point")
    print(f"  identical                    {same:,} ({100.0*same/n:.4f} %)")
    print(f"  identical, counter masked    {same_masked:,} ({100.0*same_masked/n:.4f} %)")
    res = n - same_masked
    print(f"  residue (beyond the counter) {res:,} ({100.0*res/n:.4f} %)")
    if res:
        print("\n  residue by kind:")
        for k, v in residue_kind.most_common():
            print(f"    {v:>8,}  {k}")
        print("\n  residue by PID (A vs B where they disagree):")
        for k, v in residue_pid.most_common(12):
            print(f"    {v:>8,}  {k}")

    # A table landing on different frames shows up as a PID appearing a different number
    # of times overall, which the packet-by-packet walk can mask once it desynchronises.
    print("\n  PID census over the compared span (A / B):")
    ca = Counter(pid(p) for p in a[off : off + n])
    cb = Counter(pid(p) for p in b[skip : skip + n])
    for p in sorted(set(ca) | set(cb)):
        if ca[p] != cb[p] or p in (0x0000, 0x0010, 0x0011, 0x0012, 0x0014):
            flag = "  <-- differs" if ca[p] != cb[p] else ""
            print(f"    PID {p:#06x}: {ca[p]:>8,} / {cb[p]:>8,}{flag}")


if __name__ == "__main__":
    main()
