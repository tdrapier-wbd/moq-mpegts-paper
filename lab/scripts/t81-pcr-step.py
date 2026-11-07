#!/usr/bin/env python3
"""Find the steps in a constant-rate stream's PCR against its packet count (T81).

    t81-pcr-step.py <ts> --rate 11000000 [--pid N] [--ms 1] [--json]

Behind a groomer that locks the PCR to the byte count, each PCR advances on the one before by
exactly the packets between them at the rate. A switch between two such groomers, each with a PCR
origin of its own, breaks that once: this reports every PCR whose advance departs from the packet
count by more than --ms, with its packet index, its place in seconds at the rate, the step in ms
and whether the packet carries the discontinuity indicator. The PCR PID is the first to carry a
PCR unless --pid names one.

Controls: a groomer's own output reports nothing; `pcr-perturb.py --every 500 --ticks 270000`
on it reports each moved PCR as a +10 ms step followed by a -10 ms one.
"""

import argparse
import json
import sys

TS = 188
WRAP = (1 << 33) * 300
HZ = 27_000_000


def pcr_of(p):
    if not (p[3] & 0x20) or p[4] < 7 or not (p[5] & 0x10):
        return None
    b = p[6:12]
    base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
    return base * 300 + (((b[4] & 1) << 8) | b[5]), bool(p[5] & 0x80)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ts")
    ap.add_argument("--rate", type=int, required=True, help="the stream's constant rate, bit/s")
    ap.add_argument("--pid", type=int)
    ap.add_argument("--ms", type=float, default=1.0, help="report steps larger than this")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    tick_per_pkt = TS * 8 * HZ / a.rate
    pid, last, steps, pcrs, i = a.pid, None, [], 0, -1
    with open(a.ts, "rb") as f:
        while (p := f.read(TS)) and len(p) == TS:
            i += 1
            if p[0] != 0x47:
                continue
            q = ((p[1] & 0x1F) << 8) | p[2]
            got = pcr_of(p)
            if got is None:
                continue
            if pid is None:
                pid = q
            if q != pid:
                continue
            pcrs += 1
            pcr, di = got
            if last is not None:
                step = ((pcr - last[0]) % WRAP - (i - last[1]) * tick_per_pkt) / HZ * 1000
                if step > (WRAP / HZ * 1000) / 2:
                    step -= WRAP / HZ * 1000
                if abs(step) > a.ms:
                    steps.append({"packet": i, "at_s": round(i * TS * 8 / a.rate, 3),
                                  "step_ms": round(step, 3), "discontinuity": di})
            last = (pcr, i)
    out = {"pid": pid, "pcrs": pcrs, "packets": i + 1, "steps": steps}
    if a.json:
        print(json.dumps(out))
    else:
        print(f"pcr pid {pid}: {pcrs} PCRs over {i + 1} packets; {len(steps)} steps over {a.ms} ms")
        for s in steps:
            print(f"  packet {s['packet']} at {s['at_s']} s: {s['step_ms']:+.3f} ms"
                  f"{', discontinuity indicator set' if s['discontinuity'] else ', no discontinuity indicator'}")
    return 0 if pcrs else 1


if __name__ == "__main__":
    sys.exit(main())
