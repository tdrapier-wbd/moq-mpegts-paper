#!/usr/bin/env python3
"""Emit an unbounded transport stream with a continuous timeline from a finite clip.

A permanence soak needs a source that runs for days. Every clip in this lab is five to ten
minutes long, and the obvious way to stretch one — `tsp -I file --infinite` — restarts the
file, which restarts its clock. [T23](../test-23-pcr-discontinuity-classes.md) measured what
that costs: a rewind of N seconds costs N seconds of programme, so a soak on a looped clip
spends its time measuring recovery from a rewind it manufactured. That is a real property of
the lane and it is already measured; it is not permanence.

This replays the clip but advances the timeline across the join, so the output is what a
continuous encoder emits: PCR, PTS and DTS strictly monotone modulo 2^33, continuity
counters unbroken, and no `discontinuity_indicator` anywhere. The content repeats. **The
timeline does not**, and the timeline is what every permanence metric reads — resident
memory, buffer occupancy, latency drift, rate-estimate drift and continuity are all blind to
whether a picture has been seen before.

What it does not reproduce, stated so a result is not read past its evidence:

- **The join is a hard cut.** The last picture of one pass is followed by the first of the
  next. That is a scene change at an IDR, which is ordinary in broadcast, but it is not the
  smooth content a real feed carries and the coded-frame size at the join is not typical.
- **TDT/TOT and SCTE-35 payloads are not rewritten.** Their embedded times repeat each pass,
  so nothing downstream of them should be graded on this source.
- **The bitrate profile repeats with the content**, so a slow oscillation at the pass period
  is expected in any rate measurement and is the source, not the lane.

The 33-bit rollover is *not* avoided, and should not be: the clip's own PCR origin plus a
long enough run crosses it, unsignalled, exactly as a real feed does every 26.51 h. T23
established the lane carries that correctly; a soak that crosses it re-tests the finding
live and at length rather than in a placed 105 s arm.

Usage:
  ts-continuous-source.py <clip.ts> [--passes N] [--verify]

Writes TS to stdout as fast as the reader takes it; pace it downstream, e.g. with
`tsp -I file - -P regulate --pcr-synchronous`.
"""

import argparse
import sys

TS = 188
SYNC = 0x47
PCR_MODULUS = (1 << 33) * 300
PTS_MODULUS = 1 << 33
NULL_PID = 0x1FFF


def parse_pcr(p):
    if not (p[3] >> 4) & 0x2 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def write_pcr(p, ticks):
    base, ext = divmod(ticks % PCR_MODULUS, 300)
    base &= (1 << 33) - 1
    p[6] = (base >> 25) & 0xFF
    p[7] = (base >> 17) & 0xFF
    p[8] = (base >> 9) & 0xFF
    p[9] = (base >> 1) & 0xFF
    p[10] = ((base & 1) << 7) | 0x7E | ((ext >> 8) & 0x01)
    p[11] = ext & 0xFF


def read_stamp(b, off):
    return (
        ((b[off] & 0x0E) << 29)
        | (b[off + 1] << 22)
        | ((b[off + 2] & 0xFE) << 14)
        | (b[off + 3] << 7)
        | ((b[off + 4] & 0xFE) >> 1)
    )


def write_stamp(b, off, value, prefix):
    v = value % PTS_MODULUS
    b[off] = (prefix << 4) | ((v >> 29) & 0x0E) | 0x01
    b[off + 1] = (v >> 22) & 0xFF
    b[off + 2] = ((v >> 14) & 0xFE) | 0x01
    b[off + 3] = (v >> 7) & 0xFF
    b[off + 4] = ((v << 1) & 0xFE) | 0x01


def pes_stamp_offsets(p):
    """Byte offsets of the PTS and DTS fields in this packet, if it starts a PES header."""
    if not (p[1] & 0x40):
        return ()
    afc = (p[3] >> 4) & 0x3
    if afc in (0, 2):
        return ()
    off = 4 if afc == 1 else 5 + p[4]
    if off + 14 > TS:
        return ()
    if not (p[off] == 0x00 and p[off + 1] == 0x00 and p[off + 2] == 0x01):
        return ()
    if not (0xC0 <= p[off + 3] <= 0xEF):
        return ()
    pts_dts = (p[off + 7] >> 6) & 0x3
    if pts_dts == 0:
        return ()
    base = off + 9
    if pts_dts == 0x2:
        return ((base, 0x2),)
    if pts_dts == 0x3:
        return ((base, 0x3), (base + 5, 0x1))
    return ()


def survey(path):
    """One read of the clip: its PCR span, its per-PID continuity endpoints, and its hygiene.

    The endpoints are what makes the join seamless. Rewriting every counter from scratch
    would also work and would be wrong: it would erase any legal duplicate packet the clip
    contains (ISO 13818-1 2.4.3.3 permits one repeat, and this clip is a real capture), and
    the soak would then be running on a stream this tool had quietly altered mid-pass.
    """
    first_pcr = last_pcr = None
    prev_pcr = None
    intervals = []
    first_cc = {}
    last_cc = {}
    disc = 0
    packets = 0
    backward = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(TS)
            if len(b) < TS or b[0] != SYNC:
                break
            packets += 1
            pid = ((b[1] & 0x1F) << 8) | b[2]
            if (b[3] >> 4) & 0x2 and b[4] > 0 and b[5] & 0x80:
                disc += 1
            if (b[3] >> 4) & 0x1 and pid != NULL_PID:
                cc = b[3] & 0x0F
                if pid not in first_cc:
                    first_cc[pid] = cc
                last_cc[pid] = cc
            v = parse_pcr(b)
            if v is not None:
                if first_pcr is None:
                    first_pcr = v
                else:
                    d = (v - prev_pcr) % PCR_MODULUS
                    if d > PCR_MODULUS // 2:
                        backward += 1
                    else:
                        intervals.append(d)
                last_pcr = v
                prev_pcr = v
    if first_pcr is None:
        raise SystemExit("no PCR in clip")
    nominal = sorted(intervals)[len(intervals) // 2] if intervals else 27_000
    # Round the span to a whole 90 kHz tick so the PTS offset is exact rather than rounded;
    # a fractional tick per pass would accumulate into a real timing error over a long soak.
    span = ((last_pcr - first_pcr) + nominal) % PCR_MODULUS
    span -= span % 300
    return {
        "span": span,
        "nominal": nominal,
        "first_cc": first_cc,
        "last_cc": last_cc,
        "disc": disc,
        "packets": packets,
        "backward": backward,
        "first_pcr": first_pcr,
        "last_pcr": last_pcr,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--passes", type=int, default=0, help="0 = unbounded")
    ap.add_argument("--verify", action="store_true", help="survey the clip and exit")
    a = ap.parse_args()

    s = survey(a.clip)
    if s["backward"]:
        print(
            f"clip already contains {s['backward']} backward PCR step(s); "
            "it is not a single continuous timeline and cannot be joined cleanly",
            file=sys.stderr,
        )
        return 1
    if a.verify:
        print(
            f"packets      {s['packets']}\n"
            f"PCR origin   {s['first_pcr'] / 27e6:.3f} s\n"
            f"PCR end      {s['last_pcr'] / 27e6:.3f} s\n"
            f"pass span    {s['span'] / 27e6:.6f} s (nominal interval {s['nominal'] / 27e3:.3f} ms)\n"
            f"disc flags   {s['disc']}  (a clean clip has 0)\n"
            f"PIDs w/ CC   {len(s['last_cc'])}",
            file=sys.stderr,
        )
        return 0

    # Per-PID counter offset carried across the join, so the first payload packet of a pass
    # continues from the last of the one before it.
    cc_adj = dict.fromkeys(s["last_cc"], 0)
    out = sys.stdout.buffer
    n = 0
    try:
        while a.passes == 0 or n < a.passes:
            offset = (n * s["span"]) % PCR_MODULUS
            pts_offset = (offset // 300) % PTS_MODULUS
            if n:
                for pid, last in s["last_cc"].items():
                    prev_end = (last + cc_adj[pid]) & 0x0F
                    cc_adj[pid] = (prev_end + 1 - s["first_cc"][pid]) & 0x0F
            with open(a.clip, "rb") as f:
                while True:
                    chunk = f.read(TS * 1024)
                    if len(chunk) < TS:
                        break
                    buf = bytearray(chunk)
                    for i in range(0, len(buf) - TS + 1, TS):
                        p = memoryview(buf)[i : i + TS]
                        if p[0] != SYNC:
                            continue
                        pid = ((p[1] & 0x1F) << 8) | p[2]
                        if offset:
                            v = parse_pcr(p)
                            if v is not None:
                                write_pcr(p, v + offset)
                            for off, prefix in pes_stamp_offsets(p):
                                write_stamp(p, off, read_stamp(p, off) + pts_offset, prefix)
                        # Shift the counter on every packet of the PID, not only the ones
                        # carrying payload. A payload-less packet repeats the previous
                        # counter value rather than advancing it (ISO 13818-1 2.4.3.3), so
                        # shifting one and not the other breaks the equality the rule is
                        # made of, and the join reads as a gap on exactly the PIDs that
                        # carry PCR.
                        adj = cc_adj.get(pid)
                        if adj and pid != NULL_PID:
                            p[3] = (p[3] & 0xF0) | ((p[3] + adj) & 0x0F)
                    out.write(buf)
            n += 1
        out.flush()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
