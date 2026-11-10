#!/usr/bin/env python3
"""How far one stamped capture trails another, by the arrival of the same coded pictures (T83).

    t83-leg-lag.py <capture a> <capture b> [--vpid 111] [--json]

Each capture is a t56-stamp.py prefix (<prefix>.ts, <prefix>.idx). A picture is keyed by a hash of
the first 4 KiB of its video PES payload, after the PES header, so that legs that packetise or
restamp differently still match; it is placed at the arrival of the packet that starts it. Prints
the pictures common to both and b's arrival less a's: median, 5th and 95th percentiles, min, max.
"""
import argparse
import bisect
import hashlib
import json
import statistics

PKT = 188
HEAD = 4096


def pictures(prefix, vpid):
    rows = [tuple(map(float, r.split(","))) for r in open(prefix + ".idx") if r.strip()]
    offs, ts = [int(r[0]) for r in rows], [r[1] for r in rows]
    data = open(prefix + ".ts", "rb").read()
    out, cur, start = {}, None, None

    def close():
        if cur is not None and len(cur) >= 64:
            out.setdefault(hashlib.sha1(bytes(cur[:HEAD])).hexdigest(), start)

    for i in range(0, len(data) - PKT + 1, PKT):
        p = data[i:i + PKT]
        if p[0] != 0x47 or ((p[1] & 0x1F) << 8 | p[2]) != vpid:
            continue
        afc = (p[3] >> 4) & 3
        off = 4 + (1 + p[4] if afc & 2 else 0)
        if not afc & 1 or off >= PKT:
            continue
        if p[1] & 0x40:
            close()
            pl = p[off:]
            if len(pl) < 9 or pl[:3] != b"\x00\x00\x01":
                cur = None
                continue
            cur = bytearray(pl[9 + pl[8]:])
            start = ts[max(0, bisect.bisect_right(offs, i) - 1)]
        elif cur is not None and len(cur) < HEAD:
            cur += p[off:]
    close()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--vpid", type=int, default=111)
    ap.add_argument("--json", action="store_true")
    o = ap.parse_args()
    pa, pb = pictures(o.a, o.vpid), pictures(o.b, o.vpid)
    lag = sorted(pb[k] - pa[k] for k in pa.keys() & pb.keys())
    res = {"a_pictures": len(pa), "b_pictures": len(pb), "common": len(lag)}
    if lag:
        q = statistics.quantiles(lag, n=20) if len(lag) > 1 else [lag[0]] * 19
        res.update({k: round(1000 * v, 1) for k, v in
                    (("median_ms", statistics.median(lag)), ("p5_ms", q[0]), ("p95_ms", q[-1]),
                     ("min_ms", lag[0]), ("max_ms", lag[-1]))})
    print(json.dumps(res) if o.json else ", ".join(f"{k} {v}" for k, v in res.items()))


if __name__ == "__main__":
    main()
