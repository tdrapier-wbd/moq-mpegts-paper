#!/usr/bin/env python3
"""Compare two recorded RTP legs at equal sequence numbers, and say what differs.

The same metric as [`t12-maskcmp.py`](t12-maskcmp.py) — identical, and identical with the
continuity counter masked — but reading the length-prefixed socket recordings that
[`t12-armd-join-local.sh`](t12-armd-join-local.sh) writes rather than a pcap, so it needs
no capture privileges.

It also attributes the residue, which the campaign never did: for every datagram that
still differs once the counter is masked, which TS PID the differing packet sits on, and
whether the two legs even placed the same PID in that slot. That is what separates "the
exporter renumbered the same bytes" from "the exporter emitted a table one leg did not".

Datagrams are paired by RTP *timestamp*, not sequence number. Under `--stream-clock` both
are a function of the output slot, so either identifies a slot — but the sequence number is
16 bits and wraps after 65 536 datagrams, which at 15 Mb/s is under a minute. Once it wraps,
a leg that joined late has its numbering offset by a whole epoch from its partner's and a
comparison keyed on it silently pairs unrelated slots. The 90 kHz timestamp is 32 bits and
does not wrap in any run of this length.

Usage: t12-rtpcmp.py <a.rtp> <b.rtp>
"""

import struct
import sys
from collections import Counter

TS = 188
RTP_HEADER = 12


def datagrams(path):
    """TS payload for each recorded datagram, keyed by RTP timestamp."""
    out = {}
    seen_seq = set()
    with open(path, "rb") as f:
        blob = f.read()
    i = 0
    while i + 2 <= len(blob):
        (n,) = struct.unpack_from("<H", blob, i)
        i += 2
        if i + n > len(blob):
            break
        dg = blob[i : i + n]
        i += n
        if len(dg) < RTP_HEADER + TS:
            continue
        seq = struct.unpack_from("!H", dg, 2)[0]
        stamp = struct.unpack_from("!I", dg, 4)[0]
        payload = dg[RTP_HEADER:]
        if len(payload) % TS:
            continue
        seen_seq.add(seq)
        out.setdefault(stamp, payload)
    return out, len(seen_seq)


def packets(payload):
    return [payload[i : i + TS] for i in range(0, len(payload), TS)]


def pid(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def mask_cc(p):
    return p[:3] + bytes([p[3] & 0xF0]) + p[4:]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    (a, seq_a), (b, seq_b) = datagrams(args[0]), datagrams(args[1])
    common = sorted(set(a) & set(b))
    print(f"leg A: {len(a):,} slots    leg B: {len(b):,}    slots carried by both: {len(common):,}")
    if max(len(a), len(b)) > 65536 or max(seq_a, seq_b) == 65536:
        print("  (the RTP sequence number wrapped in this run: a comparison keyed on it would be invalid)")
    if not common:
        sys.exit("no shared slots: the legs are not placing the same stream")

    identical = masked_identical = 0
    residue_pid = Counter()
    residue_kind = Counter()
    for seq in common:
        pa, pb = a[seq], b[seq]
        if pa == pb:
            identical += 1
            masked_identical += 1
            continue
        ma = [mask_cc(p) for p in packets(pa)]
        mb = [mask_cc(p) for p in packets(pb)]
        if ma == mb:
            masked_identical += 1
            continue
        for x, y in zip(ma, mb):
            if x == y:
                continue
            if pid(x) != pid(y):
                residue_kind["different PID in the same slot"] += 1
                residue_pid[f"{pid(x):#06x} vs {pid(y):#06x}"] += 1
            else:
                residue_kind["same PID, different bytes"] += 1
                residue_pid[f"{pid(x):#06x}"] += 1

    n = len(common)
    print(f"  identical                    {identical:>8,}  ({100.0 * identical / n:7.4f} %)")
    print(f"  identical, counter masked    {masked_identical:>8,}  ({100.0 * masked_identical / n:7.4f} %)")
    res = n - masked_identical
    print(f"  residue (beyond the counter) {res:>8,}  ({100.0 * res / n:7.4f} %)")

    if res:
        print("\n  residue by kind (per differing TS packet):")
        for k, v in residue_kind.most_common():
            print(f"    {v:>8,}  {k}")
        print("\n  residue by PID:")
        for k, v in residue_pid.most_common(10):
            print(f"    {v:>8,}  {k}")

        # Two legs rendering the same media into the same slots must spend the same number
        # of packets on each PID. Where they do not, the difference is not a field being
        # renumbered but one leg carrying media the other put somewhere else.
        census = [Counter(), Counter()]
        for seq in common:
            for leg, payload in enumerate((a[seq], b[seq])):
                for p in packets(payload):
                    census[leg][pid(p)] += 1
        print("\n  packets per PID over the shared slots (A / B):")
        for p in sorted(set(census[0]) | set(census[1])):
            ca, cb = census[0][p], census[1][p]
            flag = f"  <-- {cb - ca:+,}" if ca != cb else ""
            print(f"    {p:#06x}: {ca:>9,} / {cb:>9,}{flag}")


if __name__ == "__main__":
    main()
