#!/usr/bin/env python3
"""Compare the PCR timeline at the three points of the media-aware lane.

Reads `source.ts`, `export.ts` and `paced.ts` from a T23 run directory and answers, for
each, the questions that separate a discontinuity the lane survives from one it does not:

- how many `discontinuity_indicator`s are on the wire, and how many rollovers;
- where the timeline event is, and how big;
- and the one that matters — **the rate at which PCR advances**, before and after.

That last is the instrument. A clock that has stopped still emits PCR: T21's exporter kept
producing perfectly well-formed values advancing one 90 kHz tick per packet, so every check
that reads PCR as a value passed while the timebase underneath was gone. Rate of advance is
what distinguishes a clock from a counter, and it is measured per packet rather than per
second because a file capture has no arrival times in it.

A healthy stream advances ~1 s of media per second of content. Expressed per 100k packets
at the rig's mux rate that is a constant, so the ratio between a window and the pre-event
baseline is the reading: ~1.0 tracks, ~0 has stopped.

Usage: t23-grade.py <run-dir> [--arm X] [--json out.json]
"""

import argparse
import json
import os
import sys

TS = 188
PCR_MODULUS = (1 << 33) * 300
HALF = PCR_MODULUS // 2


def scan(path):
    """PCR samples as (packet_index, ticks, signalled) plus stream-wide counters."""
    out = []
    disc = 0
    npkt = 0
    if not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        i = -1
        while True:
            p = f.read(TS)
            if len(p) < TS or p[0] != 0x47:
                break
            i += 1
            npkt += 1
            if not (p[3] >> 4) & 0x2 or p[4] == 0:
                continue
            d = bool(p[5] & 0x80)
            if d:
                disc += 1
            if p[4] < 7 or not p[5] & 0x10:
                continue
            base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
            ext = ((p[10] & 0x01) << 8) | p[11]
            out.append((i, base * 300 + ext, d))
    return {"pcrs": out, "disc": disc, "packets": npkt}


def unwrap(samples):
    """Monotone timeline, treating only a drop past half the modulus as a rollover.

    A signalled discontinuity is excluded from both readings: the source has declared a new
    base, so the step across it is neither a rollover to correct nor a defect to report.
    """
    vals = []
    wraps = 0
    jumps = []
    acc = 0
    prev = None
    for idx, t, d in samples:
        if prev is not None:
            step = t - prev
            if d:
                # A declared new base. Splice the timeline at the nominal interval so the
                # rate reading measures the clock either side rather than the step itself.
                jumps.append(("signalled", idx, step / 27e6))
                acc += prev - t + nominal_step(vals)
            elif step < -HALF:
                wraps += 1
                acc += PCR_MODULUS
                jumps.append(("rollover", idx, (step + PCR_MODULUS) / 27e6))
            elif abs(step) > 27e6:  # > 1 s, unsignalled: a defect, not a feature
                jumps.append(("unsignalled", idx, step / 27e6))
        vals.append((idx, t + acc))
        prev = t
    return vals, wraps, jumps


def nominal_step(vals):
    """The recent PCR interval, used to bridge a declared base change."""
    if len(vals) < 3:
        return 0
    return (vals[-1][1] - vals[-3][1]) // 2


def rate_profile(vals, nwin=12):
    """Media seconds advanced per 100k packets, per window. The clock-versus-counter test."""
    if len(vals) < nwin * 2:
        return []
    per = len(vals) // nwin
    prof = []
    for w in range(nwin):
        seg = vals[w * per : (w + 1) * per + 1]
        if len(seg) < 2:
            continue
        dpkt = seg[-1][0] - seg[0][0]
        dsec = (seg[-1][1] - seg[0][1]) / 27e6
        prof.append((seg[0][0], dsec / dpkt * 100000 if dpkt else 0.0))
    return prof


def grade(run, arm):
    rows = {}
    for name in ("source", "export", "paced"):
        s = scan(os.path.join(run, f"{name}.ts"))
        if s is None or not s["pcrs"]:
            rows[name] = None
            continue
        vals, wraps, jumps = unwrap(s["pcrs"])
        prof = rate_profile(vals)
        base = prof[0][1] if prof else 0.0
        worst = min((p[1] for p in prof), default=0.0)
        rows[name] = {
            "packets": s["packets"],
            "pcrs": len(s["pcrs"]),
            "discontinuity_indicators": s["disc"],
            "rollovers": wraps,
            "origin_s": s["pcrs"][0][1] / 27e6,
            "final_s": s["pcrs"][-1][1] / 27e6,
            "events": [{"kind": k, "packet": i, "step_s": round(v, 3)} for k, i, v in jumps],
            "rate_baseline_s_per_100k": round(base, 4),
            "rate_worst_s_per_100k": round(worst, 4),
            "rate_final_s_per_100k": round(prof[-1][1], 4) if prof else 0.0,
            "rate_ratio_final": round(prof[-1][1] / base, 4) if prof and base else 0.0,
            "rate_ratio_worst": round(worst / base, 4) if base else 0.0,
            "profile": [[p[0], round(p[1], 4)] for p in prof],
        }
    return {"arm": arm, "run": run, "points": rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--arm", default="?")
    ap.add_argument("--json")
    a = ap.parse_args()
    r = grade(a.run, a.arm)

    print(f"=== arm {r['arm']} :: {os.path.basename(a.run)} ===")
    print(
        f"{'point':8} {'pkts':>9} {'PCRs':>7} {'disc':>5} {'roll':>5} "
        f"{'origin s':>11} {'final s':>11} {'rate now':>9} {'ratio':>7}"
    )
    for name in ("source", "export", "paced"):
        d = r["points"][name]
        if d is None:
            print(f"{name:8} {'-- no PCR captured --':>50}")
            continue
        print(
            f"{name:8} {d['packets']:>9} {d['pcrs']:>7} {d['discontinuity_indicators']:>5} "
            f"{d['rollovers']:>5} {d['origin_s']:>11.3f} {d['final_s']:>11.3f} "
            f"{d['rate_final_s_per_100k']:>9.4f} {d['rate_ratio_final']:>7.3f}"
        )
    for name in ("source", "export", "paced"):
        d = r["points"][name]
        if d and d["events"]:
            ev = ", ".join(f"{e['kind']} {e['step_s']:+.3f}s @pkt {e['packet']}" for e in d["events"][:4])
            print(f"  {name} events: {ev}")
    if a.json:
        json.dump(r, open(a.json, "w"), indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
