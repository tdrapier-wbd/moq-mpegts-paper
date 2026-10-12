#!/usr/bin/env python3
"""Is a capture its source's own bytes, less whole runs dropped late?

`moq export ts --passthrough` must write the source's packets unchanged, in order, from the first
group it releases; an object that misses its deadline is dropped whole. This walks the capture
against the source packet by packet. A packet that continues the current run of source bytes is
matched. Otherwise the capture's next packets are searched for further on in the source (never
behind it: passthrough does not reorder), and the source packets skipped over are one gap. A packet
found nowhere ahead is foreign, which passthrough must never write.

    ts-passthrough-identity.py <source.ts> <capture.ts> [--span-out span.ts] [--json out.json]

`--span-out` writes the source bytes the capture covers (first matched packet to last), so a grader
can compare the two over the same span. Exit 0 when nothing is foreign and something matched.
"""

import argparse
import json
import sys

PKT = 188
NULL_PID = 0x1FFF


def pid(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("capture")
    ap.add_argument("--span-out")
    ap.add_argument("--json")
    a = ap.parse_args()

    src = open(a.source, "rb").read()
    cap = open(a.capture, "rb").read()
    n_src, n_cap = len(src) // PKT, len(cap) // PKT
    if len(cap) % PKT:
        print(f"capture has {len(cap) % PKT} trailing bytes past its last whole packet", file=sys.stderr)

    def at(buf, i):
        return buf[i * PKT : (i + 1) * PKT]

    def find(i, after):
        """The source packet index where capture packets from i resume, searching from `after`."""
        for k in (8, 4, 2, 1):
            if i + k > n_cap:
                continue
            if k == 1 and pid(at(cap, i)) == NULL_PID:
                return None  # a lone null packet would anchor anywhere
            needle = cap[i * PKT : (i + k) * PKT]
            off = src.find(needle, after * PKT)
            while off >= 0 and off % PKT:
                off = src.find(needle, off + 1)
            if off >= 0:
                return off // PKT
        return None

    p = None  # next expected source packet
    start = None
    matched = foreign = 0
    gaps = []  # (source packet index where the gap starts, packets skipped)
    i = 0
    while i < n_cap:
        if p is not None and p < n_src and at(cap, i) == at(src, p):
            matched += 1
            p += 1
            i += 1
            continue
        q = find(i, p or 0)
        if q is None:
            foreign += 1
            i += 1
            continue
        if p is None:
            start = q
        else:
            gaps.append((p, q - p))
        p = q
    end = p

    report = {
        "source_packets": n_src,
        "capture_packets": n_cap,
        "first_source_packet": start,
        "end_source_packet": end,
        "matched": matched,
        "foreign": foreign,
        "gaps": len(gaps),
        "gap_packets": sum(g for _, g in gaps),
        "gap_list": gaps[:50],
    }
    print(
        f"capture {n_cap} packets: {matched} source packets in order from source packet {start}, "
        f"{len(gaps)} gaps ({report['gap_packets']} source packets skipped), {foreign} foreign"
    )
    if a.json:
        json.dump(report, open(a.json, "w"), indent=1)
    if a.span_out and start is not None:
        open(a.span_out, "wb").write(src[start * PKT : end * PKT])
    sys.exit(0 if matched and not foreign else 1)


if __name__ == "__main__":
    main()
