#!/usr/bin/env python3
"""Decoder-referenced latency: how much later a T-STD decoder on the egress shows each picture.

    ts-decode-latency.py SOURCE.ts SOURCE.csv EGRESS.ts EGRESS.csv
                         [--pid PID] [--settle S] [--smooth S] [--label L] [--kv PATH]

t18-latency.py reports delivery latency, the time between a PES header leaving
the source and reaching the egress. That is not the delay a viewer sees when the
two multiplexes pre-load their decoders by different amounts: a stage that
re-multiplexes can deliver a picture early and show it late, or the reverse. A
T-STD decoder presents an access unit when its system time clock reaches the
PTS, so the wall time of presentation at each end is

    t_header + (PTS - STC at the header's packet)

where t_header is the tap's arrival time for the PES header and the STC is the
capture's own PCR interpolated to that packet. A receiver does not present on one
packet's arrival, though, but on a clock recovered from many, so each end's
offset between wall clock and STC is taken as its median over --smooth seconds
around the picture. The raw offsets' scatter about that median is printed as
each tap's jitter: at the source it is the playout's burstiness, tens of
milliseconds from `tsp -P regulate`, which a per-picture difference would
otherwise report as latency. The difference between the two ends' presentation
times is the headline. The same difference taken at the DTS is printed beside it,
and differs where the egress authored its own DTS, as the media-aware lane does.
Taps must share one clock, as t18-arm.sh's do on one host. A stream whose clock
drifts against its source's shows it here as a trend; one presented on a fixed
PCR-to-PTS offset shows a constant. The figure assumes the egress decodes on its
own PCR, which only holds if it passes the T-STD: grade it first.

SOURCE.ts is the file the source tap was fed from, and must be the one pass the
run used; EGRESS.ts is the tap's own saved egress. The PTS shift between the
two is recovered as t18-latency.py does. The PCR interpolation is only as good
as each capture's PCR, and the tap stamps a read, not a packet, so a figure is
good to about a millisecond.
"""

import argparse
import importlib.util
import os
import statistics as stats
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tstd", os.path.join(HERE, "ts-tstd.py"))
T = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(T)
PKT = T.PKT


def index(path, pid):
    """{PTS: (presentation s, decode s, STC s at the header packet)} for one PID, on its own PCR.

    A PCR discontinuity starts a new timeline, so each header is timed on the PCRs of its own.
    """
    data, n = T.read_packets(path)
    pmts, pcr_pid, vpid = {}, None, pid
    segs, cur = [], []
    heads = []  # (segment, byte offset, pts, dts)
    prev = None
    for i in range(n):
        p = data[i * PKT:(i + 1) * PKT]
        if p[0] != T.SYNC:
            continue
        q = ((p[1] & 0x1F) << 8) | p[2]
        if p[1] & 0x40 and q == 0 and not pmts:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x00:
                pmts = T.parse_pat(sec)
        elif p[1] & 0x40 and q in pmts and pcr_pid is None:
            sec = T.section_body(bytes(T.payload_of(p)))
            if sec and sec[0] == 0x02:
                pcr_pid, streams = T.parse_pmt(sec)
                if vpid is None:
                    vpid = next((s for s, (st, tags) in streams.items()
                                 if T.classify(st, tags) in ("avc", "hevc", "mpeg2v")), None)
        if pcr_pid is not None and q == pcr_pid:
            v = T.parse_pcr(p)
            if v is not None:
                if prev is not None:
                    d = (v - prev) % T.PCR_MODULUS
                    if (p[4] and p[5] & 0x80) or d > T.TICKS:
                        segs.append(cur)
                        cur = []
                prev = v
                base = cur[-1][1] if cur else None
                if base is not None:
                    v = base + (v - base) % T.PCR_MODULUS
                cur.append((i * PKT + 11, v))
        if q == vpid and p[1] & 0x40:
            pl = bytes(T.payload_of(p))
            if len(pl) >= 14 and pl[:3] == b"\x00\x00\x01" and pl[7] & 0x80:
                pts = T.pes_ts(pl[9:14])
                dts = T.pes_ts(pl[14:19]) if pl[7] & 0x40 and len(pl) >= 19 else pts
                heads.append((len(segs), i * PKT, pts, dts))
    segs.append(cur)
    clocks = [T.TimeBase(s) if len(s) >= 2 else None for s in segs]
    out = {}
    for seg, off, pts, dts in heads:
        clock = clocks[seg]
        if clock is None or off < clock.b[0] or off > clock.b[-1]:
            continue
        stc = clock.at(off)
        pres = T.unwrap_to(pts * 300, stc * T.TICKS) / T.TICKS
        dec = T.unwrap_to(dts * 300, stc * T.TICKS) / T.TICKS
        out.setdefault(pts, (pres, dec, stc))
    return out, vpid


def load(path):
    seen = {}
    with open(path) as fh:
        next(fh, None)
        for line in fh:
            t, _, p = line.partition(",")
            if p:
                pts, ns = int(p), int(t)
                if pts not in seen or ns < seen[pts]:
                    seen[pts] = ns
    return seen


def clock_offsets(times, ix):
    """(wall s, PTS, wall minus STC s) for each picture one tap saw, in arrival order."""
    return sorted((ns / 1e9, p, ns / 1e9 - ix[p][2]) for p, ns in times.items() if p in ix)


def smooth(rows, width):
    """{PTS: (raw offset, rolling median of the offsets within width/2 either side)}."""
    ts = [r[0] for r in rows]
    out = {}
    lo = hi = 0
    for t, p, o in rows:
        while ts[lo] < t - width / 2:
            lo += 1
        while hi < len(ts) and ts[hi] <= t + width / 2:
            hi += 1
        out[p] = (o, stats.median(r[2] for r in rows[lo:hi]))
    return out


def summary(xs):
    xs = sorted(xs)
    return {"min": xs[0], "median": stats.median(xs), "p95": xs[int(0.95 * (len(xs) - 1))],
            "max": xs[-1], "spread": xs[-1] - xs[0]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source_ts")
    ap.add_argument("source_csv")
    ap.add_argument("egress_ts")
    ap.add_argument("egress_csv")
    ap.add_argument("--pid", type=lambda s: int(s, 0), help="video PID; default the PMT's first video")
    ap.add_argument("--settle", type=float, default=10.0, help="seconds of egress to skip")
    ap.add_argument("--smooth", type=float, default=5.0,
                    help="seconds over which each end's clock offset is medianed")
    ap.add_argument("--label", default="arm")
    ap.add_argument("--kv", metavar="PATH")
    a = ap.parse_args()

    src_ix, vpid = index(a.source_ts, a.pid)
    eg_ix, _ = index(a.egress_ts, vpid)
    src_t, eg_t = load(a.source_csv), load(a.egress_csv)
    shift, hits = max(((k, sum(1 for p in eg_t if p + k in src_t)) for k in range(-4, 5)),
                      key=lambda kv: kv[1])
    if not hits:
        sys.exit("no egress PTS matches the source within ±4 ticks")
    off_s = smooth(clock_offsets(src_t, src_ix), a.smooth)
    off_e = smooth(clock_offsets(eg_t, eg_ix), a.smooth)
    rows = []
    for p, t_eg in eg_t.items():
        q = p + shift
        if q not in off_s or p not in off_e:
            continue
        (p_s, d_s, c_s), (p_e, d_e, c_e) = src_ix[q], eg_ix[p]
        o_s, o_e = off_s[q][1], off_e[p][1]
        rows.append((t_eg, ((p_e + o_e) - (p_s + o_s)) * 1000.0, (t_eg - src_t[q]) / 1e6,
                     (d_s - c_s) * 1000.0, (d_e - c_e) * 1000.0,
                     (off_s[q][0] - o_s) * 1000.0, (off_e[p][0] - o_e) * 1000.0,
                     ((d_e + o_e) - (d_s + o_s)) * 1000.0))
    if len(rows) < 3:
        sys.exit(f"only {len(rows)} pictures timed at both ends")
    rows.sort()
    t0 = rows[0][0]
    kept = [r for r in rows if (r[0] - t0) / 1e9 >= a.settle]
    if len(kept) < 3:
        sys.exit(f"{len(kept)} pictures after a {a.settle:g}s settle")
    dd, dl = summary([r[1] for r in kept]), summary([r[2] for r in kept])
    ps, pe = summary([r[3] for r in kept]), summary([r[4] for r in kept])
    js, je = summary([r[5] for r in kept]), summary([r[6] for r in kept])
    dx = summary([r[7] for r in kept])
    third = max(len(kept) // 3, 1)
    head = stats.median([r[1] for r in kept[:third]])
    tail = stats.median([r[1] for r in kept[-third:]])
    span = (kept[-1][0] - kept[0][0]) / 1e9
    print(f"== {a.label}: {len(kept):,} pictures timed at both ends over {span:.1f} s "
          f"(PTS shift {shift:+d}, {a.settle:g} s settle)")

    def line(name, s):
        print(f"   {name:<26} min {s['min']:8.1f}  median {s['median']:8.1f}  p95 {s['p95']:8.1f}  "
              f"max {s['max']:8.1f}  spread {s['spread']:6.1f}")

    line("presentation ms", dd)
    line("decode (at each DTS) ms", dx)
    line("delivery ms", dl)
    line("source pre-load ms", ps)
    line("egress pre-load ms", pe)
    line("source tap jitter ms", js)
    line("egress tap jitter ms", je)
    print(f"   presentation trend: first third {head:.1f} ms -> last third {tail:.1f} ms "
          f"({tail - head:+.1f})")
    if a.kv:
        with open(a.kv, "w") as fh:
            for k, s in (("pres", dd), ("dec", dx), ("dl", dl), ("preload_src", ps),
                         ("preload_eg", pe), ("jitter_src", js), ("jitter_eg", je)):
                for m, v in s.items():
                    fh.write(f"{k}_{m}={v:.1f}\n")
            fh.write(f"pres_trend_head={head:.1f}\npres_trend_tail={tail:.1f}\npictures={len(kept)}\n"
                     f"window={span:.1f}\nshift={shift}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
