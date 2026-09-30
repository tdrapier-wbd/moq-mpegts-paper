#!/usr/bin/env python3
"""Check that every timestamp-bearing PID moves forward across a looped stream's joins.

A looped soak is only as continuous as its least-rebased PID. This reads a stream written by
`ts-continuous-source.py` (or any loop of a clip), finds each join at a whole multiple of the
clip's packet count, and reports per PID the last PES timestamp before the join, the first after,
and the deepest dip below the pre-join high-water mark among the next 40 PES. A dip deeper than
the tolerance fails the scan. An importer that ends on a rewind will end there; one that
re-anchors will hide it.

The default tolerance is 100 ms. A video DTS that starts one frame below the previous DTS is what
a hard cut at an IDR produces on a reordered stream, and it passes. Timestamps are not unwrapped,
so a scan window that crosses the 33-bit rollover reports it as a dip.

Usage:
  ts-join-scan.py <stream.ts> --clip <clip.ts> [--tolerance-ms 100]

Exit status 0 when every PID passes, 1 when any fails.
"""

import argparse
import os
import sys
from collections import defaultdict

TS = 188
NO_PES_HEADER = {0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF}


def stamp(b):
    return ((b[0] >> 1) & 0x7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def kind(sid):
    if 0xE0 <= sid <= 0xEF:
        return "video"
    if 0xC0 <= sid <= 0xDF:
        return "audio"
    return f"sid {sid:#04x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--clip", required=True, help="the clip that was looped, for its packet count")
    ap.add_argument("--tolerance-ms", type=float, default=100.0)
    a = ap.parse_args()

    period = os.path.getsize(a.clip) // TS
    pes = defaultdict(list)  # pid -> [(packet index, dts, stream id)]
    with open(a.stream, "rb") as f:
        i = 0
        while (p := f.read(TS)) and len(p) == TS:
            afc = (p[3] >> 4) & 0x3
            off = 4 if afc == 1 else 5 + p[4]
            if p[1] & 0x40 and afc & 1 and off + 19 <= TS and p[off : off + 3] == b"\0\0\1":
                sid = p[off + 3]
                flags = p[off + 7] >> 6
                if sid not in NO_PES_HEADER and flags & 0x2:
                    pid = (p[1] & 0x1F) << 8 | p[2]
                    dts = stamp(p[off + 14 : off + 19]) if flags == 0x3 else stamp(p[off + 9 : off + 14])
                    pes[pid].append((i, dts, sid))
            i += 1

    joins = list(range(period, i, period))
    if not joins:
        print("stream is shorter than one pass; no join to scan", file=sys.stderr)
        return 1
    failed = False
    tolerance = a.tolerance_ms * 90
    for pid, rows in sorted(pes.items()):
        for j in joins:
            before = [r for r in rows if r[0] < j]
            after = [r for r in rows if r[0] >= j][:40]
            if not before or not after:
                continue
            high = max(r[1] for r in before)
            dip = min(r[1] - high for r in after)
            bad = dip < -tolerance
            failed |= bad
            print(
                f"{'FAIL' if bad else 'ok  '} pid {pid:#06x} {kind(rows[0][2]):9} join at packet {j}: "
                f"first after {(after[0][1] - before[-1][1]) / 90:+.1f} ms from last before, "
                f"deepest dip {min(dip, 0) / 90:+.1f} ms below the high-water mark"
            )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
