#!/usr/bin/env python3
"""T66's grader: is a scrambled multiplex still scrambled, whole and descramblable?

    t66-grade.py control CLEAR SCRAMBLED DESCRAMBLED   criterion 1: the stimulus is what it claims
    t66-grade.py checks CAPTURE                        continuity, PCR intervals, scrambling, CA PIDs
    t66-grade.py ca SPAN CAPTURE                       CAT, ECM and EMM packets: capture against span
    t66-grade.py span REF CAPTURE OUT [--write W]      where a groomed capture starts and ends in REF;
                                                       writes W's packets (REF's by default) over it

Exit 0 when the subcommand's checks pass.
"""

import argparse
import sys

PKT = 188
NULL = 0x1FFF
SCRAMBLED_PIDS = (111, 121, 123, 131)
CA_PIDS = {1: "CAT", 0x200: "ECM", 0x201: "EMM"}
PCR_PID = 111


def packets(path):
    buf = open(path, "rb").read()
    return [buf[i : i + PKT] for i in range(0, len(buf) - PKT + 1, PKT)]


def pid(p):
    return (p[1] & 0x1F) << 8 | p[2]


def has_payload(p):
    return bool(p[3] & 0x10)


def scrambling(p):
    return p[3] >> 6


def pcr(p):
    if p[3] & 0x20 and p[4] >= 7 and p[5] & 0x10:
        b = p[6:12]
        base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
        return base * 300 + ((b[4] & 1) << 8 | b[5]), bool(p[5] & 0x80)
    return None


def control(a):
    clear, scr, descr = packets(a.clear), packets(a.scrambled), packets(a.descrambled)
    ok = len(clear) == len(scr) == len(descr)
    unscrambled = mismatched = kept = 0
    parity, changes = None, 0
    for c, s, d in zip(clear, scr, descr):
        if pid(s) not in SCRAMBLED_PIDS or not has_payload(s):
            continue
        kept += 1
        if not scrambling(s):
            unscrambled += 1
        if pid(s) == PCR_PID:
            if parity is not None and scrambling(s) != parity:
                changes += 1
            parity = scrambling(s)
        if d != c:
            mismatched += 1
    print(f"payload packets on {SCRAMBLED_PIDS}: {kept}, unscrambled {unscrambled}")
    print(f"parity changes on {PCR_PID}: {changes}")
    print(f"descrambled offline against the clear fixture: {mismatched} packets differ")
    ok = ok and kept > 0 and unscrambled == 0 and changes >= 11 and mismatched == 0
    print("control PASS" if ok else "control FAIL")
    return ok


def checks(a):
    ps = packets(a.capture)
    counts, scr, last_cc = {}, {}, {}
    cc_errors = 0
    prev, intervals, over = None, [], 0
    for p in ps:
        k = pid(p)
        counts[k] = counts.get(k, 0) + 1
        if k == NULL:
            continue
        if has_payload(p) and scrambling(p):
            scr[k] = scr.get(k, 0) + 1
        cc = p[3] & 0xF
        disc = p[3] & 0x20 and p[4] > 0 and p[5] & 0x80
        if k in last_cc and not disc:
            want = (last_cc[k] + 1) & 0xF if has_payload(p) else last_cc[k]
            if cc != want and not (has_payload(p) and cc == last_cc[k]):
                cc_errors += 1
        last_cc[k] = cc
        if k == PCR_PID and (v := pcr(p)) is not None:
            value, flagged = v
            if prev is not None and not flagged:
                ms = ((value - prev) % (2**33 * 300)) / 27000
                intervals.append(ms)
                over += ms > 40
            prev = value
    print(f"{len(ps)} packets; continuity errors {cc_errors}")
    print(f"PCR intervals on {PCR_PID}: {len(intervals)}, max {max(intervals, default=0):.1f} ms, over 40 ms {over}")
    print("scrambled payload packets: " + ", ".join(f"{k} {scr.get(k, 0)}" for k in SCRAMBLED_PIDS))
    print("CA PIDs: " + ", ".join(f"{n} {counts.get(k, 0)}" for k, n in CA_PIDS.items()))
    ok = cc_errors == 0 and over == 0 and len(intervals) > 0
    print("checks PASS" if ok else "checks FAIL")
    return ok


def ca(a):
    span, cap = packets(a.span), packets(a.capture)
    ok = True
    for k, name in CA_PIDS.items():
        s = sum(pid(p) == k for p in span)
        c = sum(pid(p) == k for p in cap)
        ok = ok and s > 0 and s == c
        print(f"{name} (PID {k:#x}): span {s}, capture {c}")
    print("ca PASS" if ok else "ca FAIL")
    return ok


def groomed(ps):
    """Packets less nulls, PCR fields zeroed, with each one's index in the input."""
    out, index = [], []
    for i, p in enumerate(ps):
        if pid(p) == NULL:
            continue
        if pcr(p) is not None:
            p = p[:6] + bytes(6) + p[12:]
        out.append(p)
        index.append(i)
    return out, index


def span(a):
    ref, cap = packets(a.ref), packets(a.capture)
    g_ref, index = groomed(ref)
    g_cap, _ = groomed(cap)
    hay = b"".join(g_ref)
    n = 8

    def locate(needle):
        off = hay.find(needle)
        while off >= 0 and off % PKT:
            off = hay.find(needle, off + 1)
        return None if off < 0 else off // PKT

    first = locate(b"".join(g_cap[:n]))
    last = locate(b"".join(g_cap[-n:]))
    if first is None or last is None:
        print("span: the capture's first or last packets are not in the reference")
        return False
    lo, hi = index[first], index[last + n - 1]
    src = packets(a.write) if a.write else ref
    with open(a.out, "wb") as f:
        f.write(b"".join(src[lo : hi + 1]))
    print(f"span: reference packets {lo}..{hi} ({(hi - lo + 1) * PKT / 1e6:.1f} MB) written to {a.out}")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("control")
    c.add_argument("clear")
    c.add_argument("scrambled")
    c.add_argument("descrambled")
    k = sub.add_parser("checks")
    k.add_argument("capture")
    s = sub.add_parser("ca")
    s.add_argument("span")
    s.add_argument("capture")
    w = sub.add_parser("span")
    w.add_argument("ref")
    w.add_argument("capture")
    w.add_argument("out")
    w.add_argument("--write")
    a = ap.parse_args()
    sys.exit(0 if {"control": control, "checks": checks, "ca": ca, "span": span}[a.cmd](a) else 1)


if __name__ == "__main__":
    main()
