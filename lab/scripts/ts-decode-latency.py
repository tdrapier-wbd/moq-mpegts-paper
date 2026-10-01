#!/usr/bin/env python3
"""Decoder-referenced latency: how much later a T-STD decoder on the egress shows each picture.

    ts-decode-latency.py SOURCE.ts SOURCE.csv EGRESS.ts EGRESS.csv [--key pts|content]
                         [--pid PID] [--settle S] [--smooth S] [--label L] [--kv PATH]
    ts-decode-latency.py --selftest

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
run used; EGRESS.ts is the tap's own saved egress. The PCR interpolation is only
as good as each capture's PCR, and the tap stamps a read, not a packet, so a
figure is good to about a millisecond.

Each egress picture is matched to its source picture by one of two keys. The
default, --key pts, takes the egress PTS plus a constant shift of at most four
ticks, recovered as t18-latency.py does. A lane that rebases the PTS defeats it.
--key content matches by the bytes of the picture's AVC slice NAL units (types
1-5, emulation prevention as carried), digested per PES. It ignores the access
unit delimiter, SEI, parameter sets and start-code length, because the
media-aware lane drops repeated PPS and moves SPS/PPS ahead of the delimiter
while the slices pass unchanged. A picture whose slices were damaged, by loss or
truncation at either end of a capture, has no egress copy and is left out. Both
streams are in stream order and the egress carries a subsequence of the source,
so the match is monotone: where a digest recurs, the copy taken is the one after
the previous match whose PTS step from it is nearest the egress picture's PTS
step, which a rebase leaves unchanged. The taps' CSVs are still keyed by PTS, so
a PTS that recurs within one capture is timed at its first arrival either way.
"""

import argparse
import bisect
import collections
import hashlib
import importlib.util
import os
import statistics as stats
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("tstd", os.path.join(HERE, "ts-tstd.py"))
T = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(T)
PKT = T.PKT


def slices(es):
    """Digest of an AVC access unit's slice NAL units as carried, or None if it has none."""
    h, found = hashlib.blake2b(digest_size=16), False
    k = es.find(b"\x00\x00\x01")
    while k >= 0:
        nxt = es.find(b"\x00\x00\x01", k + 3)
        nal = es[k + 3:nxt if nxt >= 0 else len(es)].rstrip(b"\x00")
        if nal and 1 <= nal[0] & 0x1F <= 5:
            h.update(b"\x00\x00\x01" + nal)
            found = True
        k = nxt
    return h.digest() if found else None


def index(path, pid, content=False):
    """({PTS: (presentation s, decode s, STC s at the header packet)}, video PID, pictures).

    One PID, on its own PCR. A PCR discontinuity starts a new timeline, so each header is timed
    on the PCRs of its own. With content, pictures is [(PTS, slices digest)] in stream order.
    """
    data, n = T.read_packets(path)
    pmts, pcr_pid, vpid, codec = {}, None, pid, None
    segs, cur = [], []
    heads = []  # (segment, byte offset, pts, dts)
    pics, es, es_pts = [], None, None
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
                if vpid in streams:
                    codec = T.classify(*streams[vpid])
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
        if content and q == vpid:
            pl = bytes(T.payload_of(p))
            if p[1] & 0x40 and pl[:3] == b"\x00\x00\x01" and len(pl) >= 9:
                if es is not None:
                    pics.append((es_pts, slices(es)))
                es_pts = T.pes_ts(pl[9:14]) if pl[7] & 0x80 and len(pl) >= 14 else None
                es = bytearray(pl[9 + pl[8]:])
            elif es is not None:
                es += pl
    if es is not None:
        pics.append((es_pts, slices(es)))
    if content and codec != "avc":
        sys.exit(f"--key content reads AVC slices; PID {vpid} is {codec or 'not in a PMT'}")
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
    return out, vpid, [(p, h) for p, h in pics if p is not None and h is not None]


def tick_delta(a, b):
    """a - b in 90 kHz ticks across the 33-bit wrap, in [-2^32, 2^32)."""
    return (a - b + (1 << 32)) % (1 << 33) - (1 << 32)


def align(src, eg, look=64):
    """{egress PTS: source PTS} for egress pictures whose slices match a source picture's.

    src and eg are [(PTS, digest)] in stream order. The match is monotone; among the next `look`
    copies of a digest after the previous match, the one taken is the one whose PTS step from the
    previous match is nearest the egress picture's own step. The first match, having no previous
    one, takes the first copy.
    """
    where = collections.defaultdict(list)
    for i, (_, h) in enumerate(src):
        where[h].append(i)
    out, last, last_eg = {}, -1, None
    for pts, h in eg:
        cand = where.get(h, ())
        k = bisect.bisect_right(cand, last)
        if k == len(cand):
            continue
        if last < 0 or len(cand) - k == 1:
            j = cand[k]
        else:
            step = tick_delta(pts, last_eg)
            j = min(cand[k:k + look], key=lambda c: abs(tick_delta(src[c][0], src[last][0]) - step))
        last, last_eg = j, pts
        out.setdefault(pts, src[j][0])
    return out


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


def pairing(key, src_pics, src_t, eg_pics, eg_t):
    """(egress PTS -> source PTS or None, description, kv lines) for the chosen key."""
    if key == "content":
        match = align([x for x in src_pics if x[0] in src_t], [x for x in eg_pics if x[0] in eg_t])
        if not match:
            sys.exit("no egress picture's slices match a source picture's")
        offset, n = collections.Counter(tick_delta(p, q) for p, q in match.items()).most_common(1)[0]
        return (match.get,
                f"content key, {len(match):,} of {len(eg_t):,} egress pictures matched, "
                f"egress PTS {offset:+d} on {n / len(match):.1%}",
                f"key=content\nmatched={len(match)}\negress_pictures={len(eg_t)}\npts_offset={offset}\n")
    shift, hits = max(((k, sum(1 for p in eg_t if p + k in src_t)) for k in range(-4, 5)),
                      key=lambda kv: kv[1])
    if not hits:
        sys.exit("no egress PTS matches the source within ±4 ticks")
    return (lambda p: p + shift), f"PTS shift {shift:+d}", f"shift={shift}\n"


def timed(pair, src_ix, src_t, eg_ix, eg_t, width):
    """Per picture timed at both ends: (egress wall ns, presentation ms, delivery ms, source and
    egress pre-load ms, source and egress tap jitter ms, decode ms, egress PTS, source PTS)."""
    off_s = smooth(clock_offsets(src_t, src_ix), width)
    off_e = smooth(clock_offsets(eg_t, eg_ix), width)
    rows = []
    for p, t_eg in eg_t.items():
        q = pair(p)
        if q is None or q not in off_s or p not in off_e:
            continue
        (p_s, d_s, c_s), (p_e, d_e, c_e) = src_ix[q], eg_ix[p]
        o_s, o_e = off_s[q][1], off_e[p][1]
        rows.append((t_eg, ((p_e + o_e) - (p_s + o_s)) * 1000.0, (t_eg - src_t[q]) / 1e6,
                     (d_s - c_s) * 1000.0, (d_e - c_e) * 1000.0,
                     (off_s[q][0] - o_s) * 1000.0, (off_e[p][0] - o_e) * 1000.0,
                     ((d_e + o_e) - (d_s + o_s)) * 1000.0, p, q))
    rows.sort()
    return rows


def selftest():
    ok = True

    def check(name, cond):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'ok  ' if cond else 'FAIL'} {name}")

    def sl(n):
        return b"\x00\x00\x01" + bytes([0x41, n, 0x9a, 0x00, 0x00, 0x03, 0x01])

    aud, sei, pps = b"\x00\x00\x00\x01\x09\xf0", b"\x00\x00\x01\x06\x05\x01\x80", b"\x00\x00\x01\x68\xce"
    base = slices(aud + pps + sei + sl(1) + sl(2))
    check("slices digest ignores a dropped PPS and a 3-byte AUD start code",
          slices(b"\x00\x00\x01\x09\xf0" + sei + sl(1) + sl(2)) == base)
    check("slices digest changes with one slice byte", slices(aud + pps + sei + sl(1) + sl(3)) != base)
    check("slices digest changes when emulation prevention is removed",
          slices(aud + sl(1) + sl(2).replace(b"\x00\x00\x03", b"\x00\x00")) != slices(aud + sl(1) + sl(2)))
    check("no slice, no digest", slices(aud + pps + sei) is None)
    src = [(3600 * i, ("d%d" % (i % 4)).encode()) for i in range(20)]
    rebase = (1 << 33) - 7200
    eg = [((p + rebase) % (1 << 33), h) for p, h in src if not 2 <= p // 3600 <= 6]
    eg[3] = (eg[3][0], b"damaged")
    m = align(src, eg)
    want = {(p + rebase) % (1 << 33): p for p, h in src if not 2 <= p // 3600 <= 6 and p // 3600 != 8}
    check("repeating content, five pictures dropped, PTS rebased across the wrap: all matched", m == want)
    greedy = {}
    last = -1
    for pts, h in eg:
        nxt = next((i for i in range(last + 1, len(src)) if src[i][1] == h), None)
        if nxt is not None:
            greedy[pts], last = src[nxt][0], nxt
    check("first-copy matching would mis-pair the same input", greedy != want)
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source_ts", nargs="?")
    ap.add_argument("source_csv", nargs="?")
    ap.add_argument("egress_ts", nargs="?")
    ap.add_argument("egress_csv", nargs="?")
    ap.add_argument("--key", choices=("pts", "content"), default="pts",
                    help="match egress pictures to source pictures by PTS (default) or by slice bytes")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--pid", type=lambda s: int(s, 0), help="video PID; default the PMT's first video")
    ap.add_argument("--settle", type=float, default=10.0, help="seconds of egress to skip")
    ap.add_argument("--smooth", type=float, default=5.0,
                    help="seconds over which each end's clock offset is medianed")
    ap.add_argument("--label", default="arm")
    ap.add_argument("--kv", metavar="PATH")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.egress_csv:
        ap.error("SOURCE.ts SOURCE.csv EGRESS.ts EGRESS.csv are required unless --selftest")

    content = a.key == "content"
    src_ix, vpid, src_pics = index(a.source_ts, a.pid, content)
    eg_ix, _, eg_pics = index(a.egress_ts, vpid, content)
    src_t, eg_t = load(a.source_csv), load(a.egress_csv)
    pair, keyed, kv_key = pairing(a.key, src_pics, src_t, eg_pics, eg_t)
    rows = timed(pair, src_ix, src_t, eg_ix, eg_t, a.smooth)
    if len(rows) < 3:
        sys.exit(f"only {len(rows)} pictures timed at both ends")
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
          f"({keyed}, {a.settle:g} s settle)")

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
                     f"window={span:.1f}\n{kv_key}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
