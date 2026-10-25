#!/usr/bin/env python3
"""Grade a P1-aa run: matched-PTS latency from a hand-off to an export, on one host's clock.

    p1aa-grade.py <egress run dir> [--primary <handoff run dir>] [--step-ms 5] [--json out.json]

Joins the export's pictures (export.csv) to the same host's hand-off (handoff.csv) on PTS, within
two ticks and the 60 s before the export's arrival, both files from p1aa-tap.py; the two hand-offs
are joined within 10 s either way. Per minute: the
pictures matched and missing, and the latency's median, 1st and 99th percentiles. Over the run: the
median, the drift (least-squares slope of the per-minute medians), every step (a per-minute median
more than --step-ms from the last), the export's restarts, and each stream's PCR rate against its
own arrivals, the export's against the hand-off's in ppm. With --primary, the primary's hand-off is
joined to the secondary's the same way: their offset per minute, beside the two hosts' chrony
error bound (|system offset| + root delay / 2 + root dispersion, summed over both).
"""
import argparse
import bisect
import collections
import json
import os
import statistics

WRAP = 1 << 33


def rows(path, kind):
    with open(path) as f:
        for line in f:
            if line.startswith(kind + ","):
                _, v, ns = line.rstrip().split(",")
                yield int(v), int(ns)


def join(src, dst, lead_ns=0):
    """For each dst picture, the src arrival with the same PTS (within two ticks) from the 60 s
    before it to lead_ns after it."""
    window = collections.deque()
    by_pts = collections.defaultdict(list)
    it = iter(src)
    pending = next(it, None)
    for pts, ns in dst:
        while pending is not None and pending[1] <= ns + lead_ns:
            window.append(pending)
            by_pts[pending[0]].append(pending[1])
            pending = next(it, None)
        while window and window[0][1] < ns - 60_000_000_000:
            p, t = window.popleft()
            by_pts[p].remove(t)
            if not by_pts[p]:
                del by_pts[p]
        hit = None
        for d in (0, 1, -1, 2, -2):
            c = by_pts.get((pts + d) % WRAP)
            if c:
                hit = c[-1]
                break
        yield ns, hit


def minutes(pairs):
    per = collections.OrderedDict()
    for ns, src in pairs:
        m = ns // 60_000_000_000
        e = per.setdefault(m, [[], 0])
        if src is None:
            e[1] += 1
        else:
            e[0].append((ns - src) / 1e6)
    out = []
    for m, (lat, miss) in per.items():
        lat.sort()
        q = (lambda f: lat[min(len(lat) - 1, int(f * len(lat)))]) if lat else (lambda f: None)
        out.append({"minute": m * 60, "matched": len(lat), "missing": miss,
                    "median_ms": round(statistics.median(lat), 3) if lat else None,
                    "p1_ms": q(0.01), "p99_ms": q(0.99)})
    return out


def pcr_ppm(path):
    """PCR ticks per arrival second against 27 MHz, in ppm, by least squares over the unwrapped PCR."""
    n = sx = sy = sxx = sxy = 0
    last, base, x0, y0 = None, 0, None, None
    for pcr, ns in rows(path, "C"):
        if last is not None and pcr < last - (WRAP * 300) // 2:
            base += WRAP * 300
        last = pcr
        x, y = ns / 1e9, (pcr + base) / 27e6
        if x0 is None:
            x0, y0 = x, y
        x, y = x - x0, y - y0
        n += 1
        sx, sy, sxx, sxy = sx + x, sy + y, sxx + x * x, sxy + x * y
    if n < 3 or n * sxx == sx * sx:
        return None
    return round(((n * sxy - sx * sy) / (n * sxx - sx * sx) - 1) * 1e6, 3)


def chrony(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path):
        f = line.rstrip().split(",")
        if len(f) >= 13:
            try:
                out.append((int(f[0]), abs(float(f[5])) + float(f[11]) / 2 + float(f[12])))
            except ValueError:
                pass
    return out


def summary(mins, step_ms):
    med = [(m["minute"], m["median_ms"]) for m in mins if m["median_ms"] is not None]
    if not med:
        return {}
    xs = [(t - med[0][0]) / 3600 for t, _ in med]
    ys = [v for _, v in med]
    slope = None
    if len(xs) > 2:
        mx, my = statistics.fmean(xs), statistics.fmean(ys)
        den = sum((x - mx) ** 2 for x in xs)
        slope = round(sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den, 3) if den else None
    steps = [{"minute": med[i][0], "from_ms": ys[i - 1], "to_ms": ys[i]}
             for i in range(1, len(ys)) if abs(ys[i] - ys[i - 1]) > step_ms]
    return {"minutes": len(med), "median_ms": round(statistics.median(ys), 3), "min_minute_ms": min(ys),
            "max_minute_ms": max(ys), "drift_ms_per_h": slope,
            "drift_ppm": round(slope / 3.6, 4) if slope is not None else None,
            "matched": sum(m["matched"] for m in mins), "missing": sum(m["missing"] for m in mins),
            "steps": steps}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--primary")
    ap.add_argument("--step-ms", type=float, default=5.0)
    ap.add_argument("--json")
    a = ap.parse_args()
    hand = os.path.join(a.run, "handoff.csv")
    exp = os.path.join(a.run, "export.csv")
    mins = minutes(join(rows(hand, "P"), rows(exp, "P")))
    events = [line.split() for line in open(os.path.join(a.run, "events.txt")) if line.strip()]
    out = {"run": a.run, "build": open(os.path.join(a.run, "build.txt")).read().splitlines()[:3],
           "latency": summary(mins, a.step_ms),
           "restarts": [e for e in events if e[0].startswith("export_exit")],
           "pcr_ppm": {"handoff": pcr_ppm(hand), "export": pcr_ppm(exp)},
           "per_minute": mins}
    if None not in out["pcr_ppm"].values():
        out["pcr_ppm"]["export_vs_handoff"] = round(out["pcr_ppm"]["export"] - out["pcr_ppm"]["handoff"], 3)
    if a.primary:
        pm = minutes(join(rows(os.path.join(a.primary, "handoff.csv"), "P"), rows(hand, "P"), 10_000_000_000))
        bound = chrony(os.path.join(a.run, "chrony.csv"))
        other = dict(chrony(os.path.join(a.primary, "chrony.csv")))
        keys = sorted(other)
        err = []
        for t, e in bound:
            i = bisect.bisect_left(keys, t)
            if keys and i < len(keys):
                err.append(e + other[keys[i]])
        out["handoff_offset"] = summary(pm, a.step_ms)
        out["handoff_offset"]["clock_bound_ms"] = round(max(err) * 1e3, 3) if err else None
        out["handoff_offset_per_minute"] = pm
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=1)
    lat = out["latency"]
    print(f"run {a.run}: {lat.get('minutes')} min, {lat.get('matched')} pictures matched, {lat.get('missing')} missing")
    print(f"  latency median {lat.get('median_ms')} ms (per-minute {lat.get('min_minute_ms')}..{lat.get('max_minute_ms')}),"
          f" drift {lat.get('drift_ms_per_h')} ms/h ({lat.get('drift_ppm')} ppm), {len(lat.get('steps', []))} steps")
    for s in lat.get("steps", [])[:20]:
        print(f"    step at {s['minute']}: {s['from_ms']} -> {s['to_ms']} ms")
    print(f"  restarts: {len(out['restarts'])}; PCR ppm {out['pcr_ppm']}")
    if a.primary:
        h = out["handoff_offset"]
        print(f"  hand-off offset (secondary - primary): median {h.get('median_ms')} ms, per-minute"
              f" {h.get('min_minute_ms')}..{h.get('max_minute_ms')}, clock bound {h.get('clock_bound_ms')} ms")


if __name__ == "__main__":
    main()
