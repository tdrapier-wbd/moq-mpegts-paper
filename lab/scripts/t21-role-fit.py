#!/usr/bin/env python3
"""Fit the per-role resource series from `t21-role-memory.sh` and name the shape.

Reads the wide CSV that rig writes (one row per sample, one column per role) and
reports, for each role, whether resident memory over the run is better described
as linear in time or logarithmic in time.

Two rules from the 24 h soak are built in rather than left to the reader:

*   **The start-up transient is excluded.** A process that allocates its buffers
    over the first few minutes produces a steep, clean, monotone rise that fits a
    line beautifully and predicts nothing. `--settle` drops that head, and its
    default of 1200 s is deliberately generous.

*   **The competing shapes are fitted, not eyeballed.** A leak and a warming
    cache both rise; they are told apart by whether the slope survives. A
    logarithm fits an amortised cache well and a leak badly, so reporting r² for
    both and comparing them is the discrimination. Where the two are within
    `--margin` the answer is "ambiguous" and the run needs to be longer — which
    is a result, and a more honest one than picking the higher number.

The second half of the run is fitted separately and reported as `tail MB/h`,
because that, not the whole-run slope, is what a provisioning budget needs: a
converging series has a tail slope well below its overall slope, and a leak does
not.

*   **A step is separated from a ramp before either verdict is believed.** This
    is not hypothetical: on the 6 h per-PID run `moq export ts` sat between 119
    and 122 MB from 0.5 h to 4.5 h, jumped **+14.5 MB inside one half-hour**, and
    then went flat again. Linear-against-log called that a leak, because a late
    step fits a line better than it fits a logarithm — the discrimination the
    module was written around is simply blind to it. So the largest half-hour
    increment is reported next to the slope, and where one interval carries more
    than `--step-share` of total growth the shape is named `step` and the slope
    is flagged as not describing the series. A one-off reallocation and a leak
    have completely different operational consequences, and a slope averages
    them into the same number.
"""

import argparse
import csv
import math
import sys

# Roles as the rig names them, in the order they matter for attribution.
ROLES = [
    ("relay_rss", "relay"),
    ("import_rss", "import"),
    ("export_rss", "export"),
    ("pacer_rss", "pacer"),
    ("python_rss", "source"),
    ("tsp_rss", "tsp"),
]


def fit(xs, ys):
    """Least-squares slope, intercept and r² for ys against xs."""
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return 0.0, my, 0.0
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    ss = sum((y - my) ** 2 for y in ys)
    rs = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    return b, a, (1 - rs / ss) if ss else 0.0


def biggest_step(pts, bucket_h=0.5):
    """Largest jump between consecutive bucket means, and total growth.

    Returns (jump_mb, at_hour, growth_mb). Bucketing rather than raw
    sample-to-sample differencing, because RSS is sampled per second and a
    single-sample spike is noise where a sustained half-hour shift is not.
    """
    buckets = {}
    for h, mb in pts:
        buckets.setdefault(int(h / bucket_h), []).append(mb)
    keys = sorted(buckets)
    means = [(k * bucket_h, sum(buckets[k]) / len(buckets[k])) for k in keys]
    if len(means) < 3:
        return 0.0, 0.0, 0.0
    jump, at = 0.0, 0.0
    for (_, a), (hb, b) in zip(means, means[1:]):
        if b - a > jump:
            jump, at = b - a, hb
    return jump, at, means[-1][1] - means[0][1]


def series(rows, col, settle):
    """(hours, MB) pairs for one column, past the settle point, blanks dropped."""
    out = []
    if not rows or col not in rows[0]:
        return out
    t0 = float(rows[0]["elapsed_s"])
    for r in rows:
        raw = (r.get(col) or "").strip()
        if not raw:
            continue
        try:
            kb = float(raw)
        except ValueError:
            continue
        if kb <= 0:
            continue
        el = float(r["elapsed_s"]) - t0
        if el < settle:
            continue
        out.append((el / 3600.0, kb / 1024.0))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="roles.csv from t21-role-memory.sh")
    ap.add_argument("--settle", type=float, default=1200.0,
                    help="seconds of start-up transient to discard (default 1200)")
    ap.add_argument("--margin", type=float, default=0.05,
                    help="r2 difference below which the shape is called ambiguous")
    ap.add_argument("--step-share", type=float, default=0.5,
                    help="share of total growth in one half-hour that makes it a step")
    args = ap.parse_args()

    with open(args.csv) as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit("empty CSV")

    span = (float(rows[-1]["elapsed_s"]) - float(rows[0]["elapsed_s"])) / 3600.0
    print(f"{args.csv}: {len(rows)} samples, {span:.2f} h, "
          f"settle={args.settle:.0f}s")
    hdr = (f"{'role':8s} {'n':>5s} {'first':>8s} {'last':>8s} {'delta':>8s} "
           f"{'MB/h':>8s} {'tail':>8s} {'step':>7s} {'r2lin':>6s} {'r2log':>6s}"
           f"  shape")
    print(hdr)
    print("-" * len(hdr))

    for col, name in ROLES:
        pts = series(rows, col, args.settle)
        if len(pts) < 30:
            print(f"{name:8s} {len(pts):5d}  (too few samples past settle)")
            continue
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        slope, _, r2lin = fit(xs, ys)
        # log(t) is undefined at the origin; the settle window keeps us clear of
        # it, but guard anyway for a zero settle.
        lx = [math.log(x) for x in xs if x > 0]
        ly = [y for x, y in zip(xs, ys) if x > 0]
        _, _, r2log = fit(lx, ly) if len(lx) >= 30 else (0, 0, 0)
        half = len(pts) // 2
        tail, _, _ = fit(xs[half:], ys[half:])

        jump, at, growth = biggest_step(pts)

        # A step is checked first, because it makes the slope meaningless
        # rather than merely uncertain.
        if growth > 1.0 and jump > args.step_share * growth:
            shape = f"STEP +{jump:.1f} MB at {at:.1f}h — slope not meaningful"
        elif r2lin > r2log + args.margin:
            shape = "LINEAR — leak"
        elif r2log > r2lin + args.margin:
            shape = "log — cache/converging"
        else:
            shape = "ambiguous, run longer"
        print(f"{name:8s} {len(pts):5d} {ys[0]:8.1f} {ys[-1]:8.1f} "
              f"{ys[-1] - ys[0]:+8.1f} {slope:+8.2f} {tail:+8.2f} "
              f"{jump:+7.1f} {r2lin:6.3f} {r2log:6.3f}  {shape}")

    last = rows[-1]
    extras = [k for k in ("alive", "pkts", "cc", "relay_thr", "import_thr",
                          "export_thr", "pacer_thr") if k in last]
    if extras:
        print("\nlast sample: " + "  ".join(f"{k}={last[k]}" for k in extras))


if __name__ == "__main__":
    main()
