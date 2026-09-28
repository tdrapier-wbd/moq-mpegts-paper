#!/usr/bin/env python3
"""T10: replay `moq import ts`'s one section clock over a multiplex, and report its backwards steps.

    t10-section-clock.py <fixture.ts> [--threshold-ms 500]

The importer stamps sections that carry no PES timestamp (SCTE-35 and SI here) with the latest video
PTS it has seen from any programme (`last_pts`, `rs/moq-mux/src/container/ts/import.rs`). From #4122
a backwards step of more than 500 ms on one track (`MAX_REORDER`, `rs/moq-mux/src/clock.rs`)
re-anchors the whole input. This replays that clock from the file, in packet order: `last_pts` is
set at each video PES start, and each section start is stamped with it. It prints, per section
PID, how many consecutive stamps step back by more than the threshold and the largest step,
and per non-first programme its video PTS against programme 1's latest video PTS at the same
position (median and largest magnitude).

It is a model of the importer, not the importer: it acts at each unit's first packet, where the
importer acts when a unit completes. It qualifies a fixture for the T10 discriminator; it does not
grade a lane.
"""

import argparse
import statistics
import sys

VIDEO = {0x6F: 1, 0x211: 2, 0x311: 3}
# The three SCTE-35 PIDs, then NIT, SDT, EIT and TDT, which the importer carries as SI snapshot
# tracks stamped from the same clock.
SCTE = (0x8D, 0x8E, 0x8F, 0x10, 0x11, 0x12, 0x14)
TS = 188


def pes_pts(payload):
    """The PTS of a PES header at the start of `payload`, or None."""
    if len(payload) < 14 or payload[:3] != b"\x00\x00\x01" or not payload[7] & 0x80:
        return None
    b = payload[9:14]
    return ((b[0] >> 1) & 0x07) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def payload_of(pkt):
    afc = (pkt[3] >> 4) & 0x3
    if afc in (0, 2):
        return b""
    return pkt[5 + pkt[4]:] if afc == 3 else pkt[4:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fixture")
    ap.add_argument("--threshold-ms", type=float, default=500.0)
    a = ap.parse_args()

    last = None
    last_p1 = None
    stamps = {s: [] for s in SCTE}
    offset = {2: [], 3: []}
    with open(a.fixture, "rb") as f:
        while pkt := f.read(TS):
            if len(pkt) < TS or pkt[0] != 0x47 or not pkt[1] & 0x40:
                continue
            pid = (pkt[1] & 0x1F) << 8 | pkt[2]
            if pid in VIDEO:
                pts = pes_pts(payload_of(pkt))
                if pts is None:
                    continue
                last = pts
                if VIDEO[pid] == 1:
                    last_p1 = pts
                elif last_p1 is not None:
                    offset[VIDEO[pid]].append((pts - last_p1) / 90.0)
            elif pid in SCTE and last is not None:
                stamps[pid].append(last)

    thr = a.threshold_ms * 90
    worst = 0.0
    for s in SCTE:
        steps = [x - y for x, y in zip(stamps[s], stamps[s][1:]) if x > y]
        big = sum(st > thr for st in steps)
        mx = max(steps, default=0) / 90.0
        worst = max(worst, mx)
        print(f"pid 0x{s:x}: {len(stamps[s])} section starts, {big} backwards steps > "
              f"{a.threshold_ms:.0f} ms, largest {mx:.0f} ms")
    for prog, xs in offset.items():
        if xs:
            print(f"programme {prog} video vs programme 1: median {statistics.median(xs):+.0f} ms, "
                  f"largest |offset| {max(abs(x) for x in xs):.0f} ms")
    print(f"largest backwards step on any section lane: {worst:.0f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
