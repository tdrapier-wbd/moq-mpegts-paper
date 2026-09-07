#!/usr/bin/env python3
"""How much programme arrived, against how long we waited for it.

C3 scores a cell in bytes delivered inside a fixed wall-clock window, which is
the right instrument for a fairness question and the wrong one for a broadcast
question. Two receivers can deliver the same byte count with completely
different operational outcomes: one holding the live edge with holes punched in
it, the other perfectly contiguous but falling further behind every second.
A byte count cannot separate those, and #3271 changes the exporter's behaviour
in exactly the direction that makes them diverge -- it waits for a late group
instead of skipping it, so bytes can fall while continuity improves.

So report media time alongside bytes:

  span      last PCR - first PCR, i.e. how much programme is in the capture
  keep_up   span / wall window. 1.0 is holding the live edge; 0.5 means the
            receiver fell one second behind for every second it ran, which is
            an unbounded-latency failure however clean the bytes are
  holes     PCR discontinuities above a threshold, with the total time lost in
            them -- the shed, measured in programme rather than in packets

**On the MoQ lane this is a stall detector, NOT a programme meter.** `moq
export ts` regenerates the PCR as a uniform grid (#2967) rather than passing
the source's through, so the exported PCR advances on the exporter's own clock
and is decoupled from whether any media arrived. T24 proved the consequence
directly: a stream with 57 s of video missing delivered zero continuity errors
and a worst PCR interval of 30.080 ms, identical to its control. So `keep_up`
near 1.0 means "the exporter kept emitting", not "the programme is intact", and
a shed that drops media without stopping the exporter is invisible here while
being plainly visible in the byte rate.

What `keep_up` *does* measure, and what nothing else in this experiment does,
is whether the exporter stopped: below 1.0 the grid itself has gaps, which
means the exporter had nothing at all to emit. Use it for that, and use
`t24-grade.py`'s per-PID access-unit liveness for delivered programme.

Usage: t8b-c3-span.py <window_seconds> <capture.ts> [capture.ts ...]
"""

import sys

PKT = 188
# A PCR must advance; a jump beyond this is a hole rather than jitter. 100 ms is
# 2.5x the TR 101 290 repetition limit, so it cannot fire on legal spacing.
HOLE_MS = 100.0
# The 33-bit base wraps every ~26.5 h; a negative step larger than this is a
# wrap rather than a rewind.
WRAP = (1 << 33) * 300 / 2


def pcrs(path):
    """Every PCR in the file, in 27 MHz units, in file order."""
    out = []
    with open(path, "rb") as f:
        buf = f.read()
    # Resynchronise rather than assuming the capture starts on a packet
    # boundary: a capture cut by `timeout` frequently does not.
    start = buf.find(0x47)
    if start < 0:
        return out
    for off in range(start, len(buf) - PKT + 1, PKT):
        if buf[off] != 0x47:
            nxt = buf.find(0x47, off)
            if nxt < 0:
                break
            continue
        if not buf[off + 3] & 0x20:  # adaptation_field_control
            continue
        aflen = buf[off + 4]
        if aflen < 7:
            continue
        if not buf[off + 5] & 0x10:  # PCR_flag
            continue
        b = buf[off + 6 : off + 12]
        base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
        ext = ((b[4] & 0x01) << 8) | b[5]
        out.append(base * 300 + ext)
    return out


def grade(path, window):
    p = pcrs(path)
    if len(p) < 2:
        return f"{path}: fewer than two PCRs ({len(p)}) -- nothing to measure"

    # Unwrap so a rollover inside the window does not read as a rewind.
    unwrapped = [p[0]]
    offset = 0
    for prev, cur in zip(p, p[1:]):
        if cur - prev < -WRAP:
            offset += (1 << 33) * 300
        unwrapped.append(cur + offset)

    span_s = (unwrapped[-1] - unwrapped[0]) / 27_000_000
    holes = []
    for prev, cur in zip(unwrapped, unwrapped[1:]):
        ms = (cur - prev) / 27_000.0
        if ms > HOLE_MS:
            holes.append(ms)

    lost_s = sum(holes) / 1000.0
    keep_up = span_s / window if window else float("nan")
    # Programme actually carried: the span minus the time spent inside holes.
    good_s = span_s - lost_s

    return (
        f"{path}\n"
        f"  pcrs={len(p)} span={span_s:.2f}s window={window:.0f}s "
        f"keep_up={keep_up:.3f}\n"
        f"  holes>{HOLE_MS:.0f}ms={len(holes)} lost={lost_s:.2f}s "
        f"worst={max(holes) if holes else 0.0:.1f}ms "
        f"programme={good_s:.2f}s ({good_s / window * 100:.1f}% of window)"
    )


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    window = float(sys.argv[1])
    for path in sys.argv[2:]:
        try:
            print(grade(path, window))
        except OSError as err:
            print(f"{path}: {err}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
