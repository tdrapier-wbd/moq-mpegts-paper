#!/usr/bin/env python3
"""Is a passthrough export's output the stimulus's own bytes? T67's passthrough lane.

    t67p-bytes.py <stimulus.ts> <egress.ts>... [--json]

Each egress is located in the stimulus by its first 64 packets, then compared with the stimulus from
there, packet by packet. At a mismatch the next 64 egress packets are searched for further on in the
stimulus: found, the packets between are missing; not found, the egress is altered from there and the
comparison stops. The report gives, per egress, where it starts and ends in the stimulus (packet
index), the packets matched, and each break with the egress and stimulus packet where it falls.
"""

import argparse
import json
import mmap
import sys

PKT = 188
PROBE = 64 * PKT


def compare(stim, eg):
    out = {"egress_packets": len(eg) // PKT, "start": None, "end": None, "matched": 0, "breaks": []}
    if len(eg) < PROBE:
        out["breaks"].append({"kind": "too short"})
        return out
    s = stim.find(eg[:PROBE])
    if s < 0:
        out["breaks"].append({"kind": "head not found"})
        return out
    out["start"] = s // PKT
    e = 0
    while e < len(eg):
        n = min(len(eg) - e, len(stim) - s)
        if n <= 0:
            out["breaks"].append({"kind": "egress runs past the stimulus", "egress_pkt": e // PKT})
            break
        if stim[s : s + n] == eg[e : e + n]:
            out["matched"] += n // PKT
            s += n
            e += n
            break
        lo, hi = 0, n
        while hi - lo > PKT:
            mid = (lo + hi) // 2 // PKT * PKT
            if stim[s : s + mid] == eg[e : e + mid]:
                lo = mid
            else:
                hi = mid
        out["matched"] += lo // PKT
        s += lo
        e += lo
        nxt = stim.find(eg[e : e + PROBE], s) if len(eg) - e >= PROBE else -1
        if nxt < 0:
            out["breaks"].append({"kind": "altered", "egress_pkt": e // PKT, "stim_pkt": s // PKT})
            break
        out["breaks"].append(
            {"kind": "missing", "egress_pkt": e // PKT, "stim_pkt": s // PKT, "packets": (nxt - s) // PKT}
        )
        s = nxt
    out["end"] = s // PKT
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stimulus")
    ap.add_argument("egress", nargs="+")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    with open(a.stimulus, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as stim:
        res = {}
        for p in a.egress:
            with open(p, "rb") as g:
                res[p] = compare(stim, g.read())
        res["stimulus_packets"] = len(stim) // PKT
    if a.json:
        json.dump(res, sys.stdout, indent=1)
        return
    for p in a.egress:
        r = res[p]
        brk = "; ".join(" ".join(f"{k}={v}" for k, v in b.items()) for b in r["breaks"]) or "none"
        span = f"stimulus {r['start']}..{r['end']}"
        print(f"{p}: {r['egress_packets']} pkts, {span}, matched {r['matched']}, breaks {brk}")


if __name__ == "__main__":
    main()
