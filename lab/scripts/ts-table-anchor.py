#!/usr/bin/env python3
"""Where, in media time, does each leg put its tables?

`moq export ts` writes a frame by emitting any due tables and then that frame's PES packets
into one buffer, so the first PES header after a table belongs to the frame that triggered
it. Tagging each table emission with that frame's PTS therefore says exactly what
moq-dev/moq#2825 claims to fix: whether a table's emission points are a property of the
broadcast or of when the exporter process happened to start.

This is deliberately not a byte comparison. Two legs on different network paths can order
the same frames differently (the exporter emits whichever track has a frame in hand), which
desynchronises a packet-by-packet walk regardless of where the tables land. Indexing by PTS
is immune to that, so it isolates the cadence question from the interleave question.

Usage: ts-table-anchor.py <a.ts> <b.ts>
"""

import sys
from collections import defaultdict

PKT = 188
SYNC = 0x47

TABLES = {0x0000: "PAT", 0x0010: "NIT", 0x0011: "SDT", 0x0012: "EIT", 0x0014: "TDT/TOT"}


def packets(path):
    data = open(path, "rb").read()
    start = 0
    while start + PKT * 8 < len(data):
        if all(data[start + i * PKT] == SYNC for i in range(8)):
            break
        start += 1
    end = len(data) - (len(data) - start) % PKT
    return (data[i : i + PKT] for i in range(start, end, PKT))


def parse_pts(pkt):
    """PTS of a PES packet starting in this TS packet, or None."""
    if not pkt[1] & 0x40:  # payload_unit_start_indicator
        return None
    afc = (pkt[3] >> 4) & 0x3
    off = 4
    if afc in (2, 3):
        off += 1 + pkt[4]
    if afc == 2 or off + 14 > PKT:
        return None
    p = pkt[off:]
    if p[0:3] != b"\x00\x00\x01":
        return None
    if len(p) < 14 or not (p[7] & 0x80):  # PTS_DTS_flags
        return None
    b = p[9:14]
    return (
        ((b[0] >> 1) & 0x07) << 30
        | b[1] << 22
        | ((b[2] >> 1) & 0x7F) << 15
        | b[3] << 7
        | ((b[4] >> 1) & 0x7F)
    )


def anchors(path):
    """For each table PID, the set of frame PTS values at which it was emitted."""
    out = defaultdict(list)
    pending = []
    for pkt in packets(path):
        p = ((pkt[1] & 0x1F) << 8) | pkt[2]
        if p in TABLES and pkt[1] & 0x40:
            pending.append(p)
            continue
        if p == 0x0064 or p == 0x0065:  # PMT candidates, resolved below
            if pkt[1] & 0x40:
                pending.append(p)
                continue
        pts = parse_pts(pkt)
        if pts is not None and pending:
            for t in pending:
                out[t].append(pts)
            pending = []
    return {k: v for k, v in out.items()}


def name(pid):
    return TABLES.get(pid, f"PMT {pid:#06x}")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = anchors(sys.argv[1]), anchors(sys.argv[2])

    print(f"{'table':<14}{'A emits':>9}{'B emits':>9}{'overlap':>9}{'shared':>9}{'agreement':>11}")
    for pid in sorted(set(a) | set(b)):
        sa, sb = set(a.get(pid, [])), set(b.get(pid, []))
        if not sa or not sb:
            print(f"{name(pid):<14}{len(sa):>9,}{len(sb):>9,}{'-':>9}{'-':>9}{'one leg only':>11}")
            continue
        # Compare only where the legs overlap in media time.
        lo, hi = max(min(sa), min(sb)), min(max(sa), max(sb))
        oa = {t for t in sa if lo <= t <= hi}
        ob = {t for t in sb if lo <= t <= hi}
        shared = oa & ob
        union = oa | ob
        pct = 100.0 * len(shared) / len(union) if union else 0.0
        print(
            f"{name(pid):<14}{len(oa):>9,}{len(ob):>9,}{len(union):>9,}{len(shared):>9,}{pct:>10.2f}%"
        )

    print(
        "\nagreement = frames where both legs emitted the table, over frames where either did.\n"
        "100% means the emission points are a function of the broadcast."
    )


if __name__ == "__main__":
    main()
