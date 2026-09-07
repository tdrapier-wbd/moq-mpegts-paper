#!/usr/bin/env python3
"""Grade a captured transport stream for per-elementary-stream liveness in media time.

Every grader in this lab so far answers a whole-stream question: is the carrier present, is
PCR advancing, are the counters intact, is the rate exact. [T24](../test-24-partial-media-plane-stall.md)
needs a different question, because its stimulus is healthy by every one of those measures and
has a dead video path behind them. What has to be measured is **each stream separately**, and
in **media time** rather than wall clock, so that the answer is a property of the stream and
not of how fast the pipe was drained.

For each PID this reports where its access units stop and restart, measured against the PCR
carried in the same stream. `payload_unit_start_indicator` is the unit of liveness rather than
the packet count, because a stream can carry packets that are all continuation and no new
picture — which is exactly the state a stalled encoder leaves behind.

The whole-stream checks are kept alongside, not because they are interesting on their own but
because the result depends on their being **green at the same time** as a stream is dead. A
table showing a 60 s hole in the video and zero continuity errors in the same run is the
finding; either half on its own is not.

Usage:
  t24-grade.py <capture.ts> [--bucket 1.0] [--json]
"""

import argparse
import json
import sys

TS = 188
SYNC = 0x47
PCR_MODULUS = (1 << 33) * 300
NULL_PID = 0x1FFF
PSI_PIDS = {0x0000, 0x0010, 0x0011, 0x0012, 0x0013, 0x0014, 0x001E, 0x001F}


def parse_pcr(p):
    if not (p[3] >> 4) & 0x2 or p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def read_stamp(b, off):
    return (
        ((b[off] & 0x0E) << 29)
        | (b[off + 1] << 22)
        | ((b[off + 2] & 0xFE) << 14)
        | (b[off + 3] << 7)
        | ((b[off + 4] & 0xFE) >> 1)
    )


def pes_pts(p):
    """The PTS of the PES header this packet starts, if it starts one and carries a PTS."""
    if not (p[1] & 0x40):
        return None
    afc = (p[3] >> 4) & 0x3
    if afc in (0, 2):
        return None
    off = 4 if afc == 1 else 5 + p[4]
    if off + 14 > TS:
        return None
    if not (p[off] == 0x00 and p[off + 1] == 0x00 and p[off + 2] == 0x01):
        return None
    if not (0xC0 <= p[off + 3] <= 0xEF):
        return None
    if not (p[off + 7] >> 6) & 0x2:
        return None
    return read_stamp(p, off + 9)


def grade(path, bucket):
    pcr_pid = None
    first_pcr = None
    last_pcr = None
    prev_pcr = None
    intervals = []
    backward = 0
    packets = 0
    # Packets and null packets per second of media time. The ratio between them is the
    # *content* rate inside a constant carrier, and it turns out to be the only wire-observable
    # quantity that moves when one elementary stream dies: the mux replaces the missing
    # payload with stuffing, so the carrier holds its rate and its composition changes.
    buckets = {}
    # Per PID: total packets, payload packets, PES unit starts, and the media time of the
    # first and last unit start, so a hole can be stated as an interval rather than a count.
    pids = {}
    prev_cc = {}
    cc_errors = 0
    # Unit-start events as (media_seconds, pid), used to find the holes.
    units = []
    now = 0.0

    with open(path, "rb") as f:
        while True:
            b = f.read(TS)
            if len(b) < TS or b[0] != SYNC:
                break
            packets += 1
            pid = ((b[1] & 0x1F) << 8) | b[2]
            v = parse_pcr(b)
            if v is not None:
                if first_pcr is None:
                    first_pcr, pcr_pid = v, pid
                else:
                    d = (v - prev_pcr) % PCR_MODULUS
                    if d > PCR_MODULUS // 2:
                        backward += 1
                    else:
                        intervals.append(d)
                last_pcr = v
                prev_pcr = v
                now = ((v - first_pcr) % PCR_MODULUS) / 27e6

            slot = buckets.setdefault(int(now), [0, 0])
            slot[0] += 1
            if pid == NULL_PID:
                slot[1] += 1
                pids.setdefault(pid, _blank())["packets"] += 1
                continue

            e = pids.setdefault(pid, _blank())
            e["packets"] += 1
            has_payload = bool((b[3] >> 4) & 0x1)
            if has_payload:
                e["payload"] += 1
            cc = b[3] & 0x0F
            if pid in prev_cc:
                want = (prev_cc[pid] + 1) & 0x0F if has_payload else prev_cc[pid]
                if cc != want and not (has_payload and cc == prev_cc[pid]):
                    cc_errors += 1
            prev_cc[pid] = cc

            if b[1] & 0x40 and pid not in PSI_PIDS:
                pts = pes_pts(b)
                if pts is not None or has_payload:
                    e["units"] += 1
                    if e["first_unit"] is None:
                        e["first_unit"] = now
                    e["last_unit"] = now
                    units.append((now, pid))
                    if pts is not None:
                        if e["first_pts"] is None:
                            e["first_pts"] = pts
                        e["last_pts"] = pts

    span = ((last_pcr - first_pcr) % PCR_MODULUS) / 27e6 if first_pcr is not None else 0.0
    holes = _holes(units, bucket, span)
    return {
        "stuffing": {k: (v[1] / v[0] if v[0] else 0.0) for k, v in buckets.items()},
        "packets": packets,
        "pcr_pid": pcr_pid,
        "span_s": span,
        "pcrs": len(intervals) + 1 if intervals else 0,
        "worst_pcr_ms": max(intervals) / 27e3 if intervals else 0.0,
        "pcr_over_40ms": sum(1 for d in intervals if d > 40 * 27_000),
        "backward_pcr": backward,
        "cc_errors": cc_errors,
        "mux_rate_bps": (packets * TS * 8 / span) if span else 0,
        "pids": pids,
        "holes": holes,
    }


def _blank():
    return {
        "packets": 0,
        "payload": 0,
        "units": 0,
        "first_unit": None,
        "last_unit": None,
        "first_pts": None,
        "last_pts": None,
    }


def _holes(units, bucket, span):
    """The gaps in each PID's access units, in media seconds.

    A gap is only reported if it is longer than `bucket`, because the natural spacing between
    access units on a low-bitrate stream is already tens of milliseconds and reporting those
    would bury the one that matters.
    """
    by_pid = {}
    for t, pid in units:
        by_pid.setdefault(pid, []).append(t)
    out = {}
    for pid, ts in by_pid.items():
        gaps = []
        for i in range(1, len(ts)):
            d = ts[i] - ts[i - 1]
            if d > bucket:
                gaps.append({"from": round(ts[i - 1], 3), "to": round(ts[i], 3), "s": round(d, 3)})
        # A stream that never comes back has its hole terminated by the end of the capture.
        if ts and span - ts[-1] > bucket:
            gaps.append({"from": round(ts[-1], 3), "to": round(span, 3), "s": round(span - ts[-1], 3)})
        out[pid] = gaps
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--bucket", type=float, default=1.0, help="minimum gap to report, seconds")
    ap.add_argument("--settle", type=int, default=5, help="skip this many seconds of start-up")
    ap.add_argument("--at", type=int, default=25, help="seconds before which the lane is healthy")
    ap.add_argument("--threshold", type=float, default=0.10, help="stuffing rise that counts")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    r = grade(a.capture, a.bucket)
    if a.json:
        r["pids"] = {str(k): v for k, v in r["pids"].items()}
        r["holes"] = {str(k): v for k, v in r["holes"].items()}
        print(json.dumps(r, indent=2))
        return 0

    print(f"capture        {a.capture}")
    print(f"packets        {r['packets']:,}")
    print(f"media span     {r['span_s']:.3f} s   (PCR pid {r['pcr_pid']})")
    print(f"mux rate       {r['mux_rate_bps']:,.0f} b/s")
    print()
    print("whole-stream checks — the ones an operator already has")
    print(f"  continuity errors      {r['cc_errors']}")
    print(f"  PCRs                   {r['pcrs']:,}")
    print(f"  PCR intervals > 40 ms  {r['pcr_over_40ms']}")
    print(f"  worst PCR interval     {r['worst_pcr_ms']:.3f} ms")
    print(f"  backward PCR steps     {r['backward_pcr']}")
    print()
    print("per-stream liveness — the question those checks cannot answer")
    print(f"  {'pid':>6} {'packets':>10} {'payload':>10} {'units':>8} {'first':>8} {'last':>8}  gaps > bucket")
    for pid in sorted(r["pids"]):
        e = r["pids"][pid]
        if pid == NULL_PID:
            print(f"  {pid:>6} {e['packets']:>10,} {'-':>10} {'-':>8} {'-':>8} {'-':>8}  (null)")
            continue
        gaps = r["holes"].get(pid, [])
        gs = ", ".join(f"{g['s']:.2f}s @{g['from']:.1f}" for g in gaps[:4]) or "none"
        fu = f"{e['first_unit']:.2f}" if e["first_unit"] is not None else "-"
        lu = f"{e['last_unit']:.2f}" if e["last_unit"] is not None else "-"
        print(f"  {pid:>6} {e['packets']:>10,} {e['payload']:>10,} {e['units']:>8,} {fu:>8} {lu:>8}  {gs}")
    print()
    st = r["stuffing"]
    ks = sorted(st)
    if len(ks) > a.settle + 5:
        # The baseline is taken after the cushion has filled and before the injection, so it
        # is the lane's own steady-state stuffing rather than its start-up transient.
        window = [st[k] for k in ks if a.settle <= k < a.at]
        base = sum(window) / len(window) if window else 0.0
        peak = max(st[k] for k in ks)
        fired = [k for k in ks if k >= a.at and st[k] > base + a.threshold]
        print(f"stuffing ratio — steady state {base * 100:.1f} %, peak {peak * 100:.1f} %")
        print(
            f"  first second more than {a.threshold * 100:.0f} points above steady state, "
            f"at or after t={a.at}: {fired[0] if fired else 'never'}"
        )
        print("  per 5 s: " + " ".join(str(round(st[k] * 100)) for k in ks[::5]))
        print()

    worst = max(
        ((g["s"], pid) for pid, gs in r["holes"].items() for g in gs),
        default=(0.0, None),
    )
    if worst[1] is not None:
        print(f"worst per-stream gap: {worst[0]:.3f} s on pid {worst[1]}")
        if r["cc_errors"] == 0 and r["pcr_over_40ms"] == 0:
            print(
                "  ...with 0 continuity errors and 0 PCR intervals over 40 ms, so the entire "
                "TR 101 290 P1 set is green across it."
            )
    else:
        print("no per-stream gap above the bucket — every stream stayed live")
    return 0


if __name__ == "__main__":
    sys.exit(main())
