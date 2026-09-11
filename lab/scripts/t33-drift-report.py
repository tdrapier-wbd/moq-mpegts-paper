#!/usr/bin/env python3
"""Fit buffer-occupancy slope against imposed source-clock offset, and derive time-to-rail.

The groomer holds a cushion of media and emits at a fixed rate. If the source delivers at
(1 + d) times that rate, the buffer fills at d times the media rate and the cushion walks
monotonically toward its cap; if the source is slow, it walks the other way into underrun.
Nothing about that is in doubt. What an experiment can add is whether the implementation
behaves that way, and with what constant -- which is what lets the +/-30 ppm case be stated
without running for the 9.3 hours it would take to reach the rail.

So: fit `buffer` against elapsed time per arm, compare the fitted slope against the slope the
imposed offset predicts, and report time-to-rail for each. The +/-30 ppm figure is then
**derived from the measured constant**, and is labelled as derived wherever it appears.

Samples before the groomer reaches `Live` are dropped: during `Priming` the buffer is filling
to its cushion by design, and a fit through that ramp reports the priming slope, not the drift
slope. This is the same warm-up rule the memory soaks use.

  t33-drift-report.py <ladder-dir>
"""

import os
import re
import sys

SAMPLE = re.compile(
    r"sample t=(\d+) state=(\w+) out=(\d+) content=(\d+) .*?underruns=(\d+) stalls=(\d+) "
    r"muted=(\d+) .*?buffer=(\d+) buffer_high_water=(\d+) cushion_ms=(\d+)"
)


def parse(path):
    rows = []
    for line in open(path, errors="replace"):
        m = SAMPLE.search(line)
        if m:
            t, state, out, content, und, stalls, muted, buf, hw, cush = m.groups()
            rows.append(
                {
                    "t": int(t),
                    "state": state,
                    "content": int(content),
                    "underruns": int(und),
                    "muted": int(muted),
                    "buffer": int(buf),
                    "high_water": int(hw),
                    "cushion_ms": int(cush),
                }
            )
    return rows


def fit(xs, ys):
    n = len(xs)
    if n < 3:
        return None, None, None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None, None, None
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot else float("nan")
    return b, a, r2


def main():
    root = sys.argv[1]
    arms = sorted(
        (d for d in os.listdir(root) if d.startswith("ppm")),
        key=lambda d: int(d[3:].replace("m", "-")),
    )
    print(f"{'ppm':>8} {'n':>4} {'slope pkt/s':>12} {'r2':>7} {'predicted':>10} {'hi-water':>9} "
          f"{'underrun':>9} {'muted':>7}")
    fits = {}
    rate_pkts = None
    for a in arms:
        ppm = int(a[3:].replace("m", "-"))
        log = os.path.join(root, a, "pacer.log")
        if not os.path.exists(log):
            continue
        rows = [r for r in parse(log) if r["state"] == "Live"]
        if len(rows) < 5:
            print(f"{ppm:>8} {len(rows):>4}   too few Live samples")
            continue
        # Drop the first and last two seconds: the first is the transition into Live, the last
        # is the source ending, and neither is drift.
        rows = rows[2:-2] if len(rows) > 8 else rows
        xs = [r["t"] for r in rows]
        ys = [r["buffer"] for r in rows]
        b, _, r2 = fit(xs, ys)
        # The mux rate in packets/s, from the arm's own content delivery.
        span = xs[-1] - xs[0]
        if span > 0 and rate_pkts is None:
            rate_pkts = (rows[-1]["content"] - rows[0]["content"]) / span
        pred = (ppm / 1e6) * (rate_pkts or 0)
        fits[ppm] = (b, r2, rows[-1]["cushion_ms"])
        print(
            f"{ppm:>8} {len(rows):>4} {b:>12.4f} {r2:>7.3f} {pred:>10.4f} "
            f"{max(r['high_water'] for r in rows):>9} "
            f"{rows[-1]['underruns'] - rows[0]['underruns']:>9} "
            f"{rows[-1]['muted'] - rows[0]['muted']:>7}"
        )

    print(f"\nmedia rate measured at {rate_pkts:.1f} packets/s" if rate_pkts else "")
    # Time to rail, from the measured slope rather than from the nominal offset.
    print("\ntime for the cushion to reach an 8000 ms cap, from the fitted slope:")
    for ppm, (b, r2, cush) in sorted(fits.items()):
        if not b or abs(b) < 1e-9 or not rate_pkts:
            print(f"  {ppm:>7} ppm   no resolvable slope")
            continue
        headroom_pkts = (8000 - cush) / 1000.0 * rate_pkts
        secs = headroom_pkts / abs(b)
        unit = f"{secs:.0f} s" if secs < 3600 else f"{secs / 3600:.1f} h"
        print(f"  {ppm:>7} ppm   {unit}")
    if 30 not in fits and rate_pkts:
        # Derived, not measured: scale the linear relationship the ladder established.
        headroom_pkts = 7.0 * rate_pkts
        slope30 = 30e-6 * rate_pkts
        print(
            f"\n  DERIVED, not measured -- +/-30 ppm at this rate implies a slope of "
            f"{slope30:.4f} pkt/s, so {headroom_pkts / slope30 / 3600:.1f} h to the same cap."
        )


if __name__ == "__main__":
    main()
