#!/usr/bin/env python3
"""Count an export's video and MP2 PES (PUSI packets on the PIDs its PMT declares) and its skip lines.

usage: t83d-field-skip-count.py <out.ts> <export.log>
"""

import re
import sys
from collections import Counter

VIDEO_TYPES = {0x1B, 0x24}  # H.264, HEVC
MP2_TYPES = {0x03, 0x04}


def pids(data):
    pmt_pids, video, mp2 = set(), set(), set()
    for i in range(0, len(data) - 187, 188):
        p = data[i : i + 188]
        if p[0] != 0x47 or not p[1] & 0x40:
            continue
        pid = (p[1] & 0x1F) << 8 | p[2]
        start = 4 + (1 + p[4] if p[3] & 0x20 else 0)
        if (p[3] & 0x10) == 0 or start >= 188:
            continue
        sec = p[start + 1 + p[start] :]
        if pid == 0 and sec[:1] == b"\x00":
            end = 3 + ((sec[1] & 0x0F) << 8 | sec[2]) - 4
            for j in range(8, end, 4):
                if (sec[j] << 8 | sec[j + 1]) != 0:
                    pmt_pids.add((sec[j + 2] & 0x1F) << 8 | sec[j + 3])
        elif pid in pmt_pids and sec[:1] == b"\x02":
            end = 3 + ((sec[1] & 0x0F) << 8 | sec[2]) - 4
            j = 12 + ((sec[10] & 0x0F) << 8 | sec[11])
            while j + 5 <= end:
                kind, es = sec[j], (sec[j + 1] & 0x1F) << 8 | sec[j + 2]
                (video if kind in VIDEO_TYPES else mp2 if kind in MP2_TYPES else set()).add(es)
                j += 5 + ((sec[j + 3] & 0x0F) << 8 | sec[j + 4])
            if video:
                return video, mp2
    return video, mp2


def main():
    data = open(sys.argv[1], "rb").read()
    video, mp2 = pids(data)
    pusi = Counter()
    for i in range(0, len(data) - 187, 188):
        if data[i] == 0x47 and data[i + 1] & 0x40:
            pusi[(data[i + 1] & 0x1F) << 8 | data[i + 2]] += 1
    skips = Counter()
    for line in open(sys.argv[2], errors="replace"):
        if "media skipped upstream" in line:
            m = re.search(r"track=(\S+)", line)
            skips[m.group(1) if m else "?"] += 1
    print(f"bytes {len(data)} ({len(data) / 1e6:.1f} MB)")
    print(f"video PES {sum(pusi[p] for p in video)} on {sorted(hex(p) for p in video)}")
    print(f"MP2 PES {sum(pusi[p] for p in mp2)} on {sorted(hex(p) for p in mp2)}")
    print(f"skip lines {sum(skips.values())} {dict(skips)}")


if __name__ == "__main__":
    main()
