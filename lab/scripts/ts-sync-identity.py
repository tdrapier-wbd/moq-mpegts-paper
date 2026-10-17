#!/usr/bin/env python3
"""Grade `moq export ts --sync` legs for packet identity (Test 50).

Under `--sync` every 25 ms slot opens with a PCR on a PID of its own, and the PCR's value is a
function of the slot alone. Legs therefore align on those values without trusting anything else
they carry. For each pair of legs, over the slots both carry (from the first both have to the end
of the shorter capture, each capture's last slot dropped as possibly cut short), every position
is compared byte for byte, continuity counters included:

  same      the two packets are identical
  alone     one leg has a null packet where the other has content: content it lacks
  conflict  both have non-null packets that differ, or the slot differs in size: the property fails

It also checks each leg's packets per slot against the multiplex rate: a slot opening at PCR p
starts at packet ceil((p + 25 ms) * rate / (1504 * 27 MHz)), so consecutive PCRs fix each slot's
count exactly. With three legs, it merges the first two position by position (content wins over
null) and compares the merge with the third. `--merge-out` writes the merge of the first two over
their common slots, for TSDuck.

Usage:
  ts-sync-identity.py --rate 12000000 a.ts b.ts [r.ts] [--merge-out m.ts] [--json out.json]
  ts-sync-identity.py --flip leg.ts out.ts    # copy with one payload byte flipped mid-file
"""

import argparse
import json
import sys
from collections import Counter, defaultdict

PKT = 188
NULL = 0x1FFF
SYSTEM_CLOCK = 27_000_000
SLOT_TICKS = SYSTEM_CLOCK // 40
WRAP = (1 << 33) * 300
K = PKT * 8 * SYSTEM_CLOCK


def load(path):
    data = open(path, "rb").read()
    start = 0
    while start < PKT and not all(data[start + i * PKT] == 0x47 for i in range(8) if start + i * PKT < len(data)):
        start += 1
    end = len(data) - (len(data) - start) % PKT
    return [data[i : i + PKT] for i in range(start, end, PKT)]


def pid(packet):
    return (packet[1] & 0x1F) << 8 | packet[2]


def pcr(packet):
    """The packet's PCR in 27 MHz units, or None."""
    if not packet[3] & 0x20 or packet[4] == 0 or not packet[5] & 0x10:
        return None
    b = packet[6:12]
    base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
    return base * 300 + ((b[4] & 1) << 8 | b[5])


def clock_pid(packets):
    """The PID carrying the most PCRs."""
    counts = Counter(pid(p) for p in packets[:400_000] if pcr(p) is not None)
    if not counts:
        sys.exit("no PCR found")
    return counts.most_common(1)[0][0]


class Leg:
    def __init__(self, path, clock=None):
        self.path = path
        self.packets = load(path)
        self.clock = clock if clock is not None else clock_pid(self.packets)
        # Each slot: its opening PCR and the index of its first packet.
        self.opens = [(pcr(p), n) for n, p in enumerate(self.packets) if pid(p) == self.clock and pcr(p) is not None]
        self.slots = {}
        for (value, start), (_, end) in zip(self.opens, self.opens[1:]):
            self.slots.setdefault(value, (start, end))
        self.order = [value for value, _ in self.opens[:-1]]

    def rate_check(self, rate):
        """Slots whose packet count is not the rate's, and the PCR steps that are not one slot."""
        wrong, jumps, counts = 0, 0, Counter()
        for (p0, s0), (p1, s1) in zip(self.opens, self.opens[1:]):
            step = (p1 - p0) % WRAP
            if abs(step - SLOT_TICKS) > SLOT_TICKS // 2:
                jumps += 1
                continue
            at0 = (p0 + SLOT_TICKS) % WRAP
            at1 = at0 + step
            expected = -(-at1 * rate // K) - -(-at0 * rate // K)
            counts[s1 - s0] += 1
            wrong += s1 - s0 != expected
        return {
            "slots": sum(counts.values()),
            "wrong_count": wrong,
            "pcr_jumps": jumps,
            "packets_per_slot": dict(sorted(counts.items())),
        }


def first_diff(a, b):
    n = next(i for i in range(PKT) if a[i] != b[i])
    field = {1: "pusi/pid", 2: "pid", 3: "cc/afc"}.get(n, "afield" if a[3] & 0x20 and n < 5 + a[4] else "payload")
    return n, field


def compare(a, b, label):
    common = [v for v in a.order if v in b.slots]
    if not common:
        return {"pair": label, "common_slots": 0}
    first = common[0]
    same = 0
    alone = {a.path: Counter(), b.path: Counter()}
    last_alone = defaultdict(float)
    conflicts, examples = 0, []
    conflict_pids, last_conflict = Counter(), None
    for v in common:
        (sa, ea), (sb, eb) = a.slots[v], b.slots[v]
        t = ((v - first) % WRAP) / SYSTEM_CLOCK
        if ea - sa != eb - sb:
            conflicts += 1
            examples.append({"t": round(t, 3), "slot_size": [ea - sa, eb - sb]})
            continue
        for k in range(ea - sa):
            x, y = a.packets[sa + k], b.packets[sb + k]
            if x == y:
                same += 1
            elif pid(x) == NULL or pid(y) == NULL:
                owner, packet = (b, y) if pid(x) == NULL else (a, x)
                alone[owner.path][pid(packet)] += 1
                last_alone[pid(packet)] = t
            else:
                conflicts += 1
                conflict_pids[pid(x)] += 1
                last_conflict = t
                if len(examples) < 10:
                    offset, field = first_diff(x, y)
                    examples.append({
                        "t": round(t, 3),
                        "position": k,
                        "pids": [hex(pid(x)), hex(pid(y))],
                        "byte": offset,
                        "field": field,
                        "bytes": [x[offset], y[offset]],
                    })
    return {
        "pair": label,
        "common_slots": len(common),
        "span_s": round(((common[-1] - first) % WRAP) / SYSTEM_CLOCK + 0.025, 3),
        "same": same,
        "alone": {path: {hex(p): n for p, n in sorted(c.items())} for path, c in alone.items()},
        "last_alone_s": {hex(p): round(t, 3) for p, t in sorted(last_alone.items())},
        "conflicts": conflicts,
        "conflicts_by_pid": {hex(p): n for p, n in sorted(conflict_pids.items())},
        "last_conflict_s": last_conflict,
        "conflict_examples": examples,
    }


def merge(a, b, r, out):
    common = [v for v in a.order if v in b.slots]
    merged = bytearray()
    against = {"slots": 0, "equal": 0, "lost_in_both": 0, "differ": 0}
    for v in common:
        (sa, ea), (sb, eb) = a.slots[v], b.slots[v]
        if ea - sa != eb - sb:
            continue
        slot = [x if pid(x) != NULL else y for x, y in zip(a.packets[sa:ea], b.packets[sb:eb])]
        merged.extend(b"".join(slot))
        if r is not None and v in r.slots:
            sr, er = r.slots[v]
            against["slots"] += 1
            for x, y in zip(slot, r.packets[sr:er]):
                if x == y:
                    against["equal"] += 1
                elif pid(x) == NULL:
                    against["lost_in_both"] += 1
                else:
                    against["differ"] += 1
    if out:
        open(out, "wb").write(merged)
    return against if r is not None else None


def flip(src, out):
    packets = load(src)
    clock = clock_pid(packets)
    n = len(packets) // 2
    while pid(packets[n]) in (NULL, clock) or packets[n][3] & 0x30 != 0x10:
        n += 1
    packet = bytearray(packets[n])
    packet[-1] ^= 0xFF
    packets[n] = bytes(packet)
    open(out, "wb").write(b"".join(packets))
    print(json.dumps({"flipped_packet": n, "pid": hex(pid(packet))}))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("legs", nargs="*")
    ap.add_argument("--rate", type=int)
    ap.add_argument("--clock-pid", type=lambda s: int(s, 0))
    ap.add_argument("--merge-out")
    ap.add_argument("--json")
    ap.add_argument("--flip", nargs=2, metavar=("LEG", "OUT"))
    args = ap.parse_args()
    if args.flip:
        flip(*args.flip)
        return
    if len(args.legs) < 2 or not args.rate:
        ap.error("two or three legs and --rate")
    legs = [Leg(path, args.clock_pid) for path in args.legs]
    report = {
        "clock_pids": {leg.path: hex(leg.clock) for leg in legs},
        "rate": {leg.path: leg.rate_check(args.rate) for leg in legs},
        "pairs": [],
    }
    for i in range(len(legs)):
        for j in range(i + 1, len(legs)):
            report["pairs"].append(compare(legs[i], legs[j], f"{legs[i].path} vs {legs[j].path}"))
    if len(legs) == 3 or args.merge_out:
        report["merge_vs_third"] = merge(legs[0], legs[1], legs[2] if len(legs) == 3 else None, args.merge_out)
    text = json.dumps(report, indent=1)
    print(text)
    if args.json:
        open(args.json, "w").write(text)
    failed = any(p.get("conflicts") for p in report["pairs"]) or any(r["wrong_count"] for r in report["rate"].values())
    if report.get("merge_vs_third"):
        failed |= report["merge_vs_third"]["differ"] + report["merge_vs_third"]["lost_in_both"] > 0
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
