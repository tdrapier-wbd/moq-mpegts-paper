#!/usr/bin/env python3
"""Lift a capture's timeline so a backward step in it replays as a step back.

A fresh import starts at the capture's own clock, so a step back larger than that clock falls below
zero, wraps the 33-bit counter and is published as a jump forward. Adding OFFSET seconds to every
PCR, and to the PTS and DTS of every PES on stream IDs 0xBD and 0xC0-0xEF, keeps the step whole.
Sections (SCTE-35 included) are left as they are.

usage: p0j-lift.py <out.ts> <in.ts>...   (env OFFSET, seconds, default 30000)
"""

import os
import sys

TS = 188
WRAP = 1 << 33
OFF = int(float(os.environ.get("OFFSET", "30000")) * 90000)


def lift_stamp(b, i):
    """Add OFF to the 33-bit PTS or DTS at b[i:i+5], keeping its prefix and marker bits."""
    v = ((b[i] >> 1) & 7) << 30 | b[i + 1] << 22 | (b[i + 2] >> 1) << 15 | b[i + 3] << 7 | b[i + 4] >> 1
    v = (v + OFF) % WRAP
    b[i] = (b[i] & 0xF1) | ((v >> 29) & 0x0E)
    b[i + 1] = (v >> 22) & 0xFF
    b[i + 2] = ((v >> 14) & 0xFE) | 1
    b[i + 3] = (v >> 7) & 0xFF
    b[i + 4] = ((v << 1) & 0xFE) | 1


def lift(p):
    b = bytearray(p)
    afc = (b[3] >> 4) & 3
    pos = 4
    if afc & 2:
        alen = b[4]
        if alen and b[5] & 0x10:
            base = b[6] << 25 | b[7] << 17 | b[8] << 9 | b[9] << 1 | b[10] >> 7
            base = (base + OFF) % WRAP
            b[6], b[7], b[8], b[9] = base >> 25, (base >> 17) & 0xFF, (base >> 9) & 0xFF, (base >> 1) & 0xFF
            b[10] = ((base & 1) << 7) | (b[10] & 0x7F)
        pos = 5 + alen
    if afc & 1 and b[1] & 0x40 and pos + 14 <= TS and b[pos : pos + 3] == b"\x00\x00\x01":
        sid = b[pos + 3]
        if sid == 0xBD or 0xC0 <= sid <= 0xEF:
            flags = b[pos + 7] >> 6
            if flags & 2:
                lift_stamp(b, pos + 9)
            if flags == 3 and pos + 19 <= TS:
                lift_stamp(b, pos + 14)
    return bytes(b)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    n = 0
    with open(sys.argv[1], "wb") as out:
        for path in sys.argv[2:]:
            with open(path, "rb") as f:
                while (p := f.read(TS)) and len(p) == TS:
                    out.write(lift(p) if p[0] == 0x47 else p)
                    n += 1
    print(f"{n:,} packets lifted by {OFF / 90000:,.0f} s into {sys.argv[1]}")


if __name__ == "__main__":
    main()
