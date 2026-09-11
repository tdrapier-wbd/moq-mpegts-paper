#!/usr/bin/env python3
"""Report one T37 arm: how much media reached each affiliate AFTER the
control-plane decision.

The figure that matters is not when the subscriber process exited but when the
affiliate stopped receiving programme. Both are taken from the affiliate's own
delivery profile — the running (wall, cumulative bytes) trace the receiver
recorded — so a client that keeps re-dialling after revocation, or that flushes
a buffer on exit, cannot be mistaken for media still arriving.
"""
import json
import sys

W = "/tmp/t36"
RATE = 9945951 / 8.0        # bytes/s of programme, from the clip's own PCR bitrate


def load(path):
    return [json.loads(l) for l in open(path)]


def arm(mark):
    dec = [d for d in load(f"{W}/decisions.jsonl") if d.get("mark") == mark]
    lbs = {r["mark"]: r for r in load(f"{W}/lastbyte.jsonl")}
    if not dec:
        print(f"  {mark}: no decision recorded")
        return
    t0 = dec[-1]["wall"]
    out = []
    for role, name in (("A", "under test"), ("C", "collateral")):
        r = lbs.get(f"{mark}-{role}")
        if not r or not r.get("profile"):
            print(f"  {mark}-{role}  {name:11s}: NO MEDIA")
            continue
        prof = r["profile"]
        at_dec = 0
        stop = None
        for t, cum in prof:
            if t <= t0:
                at_dec = cum
            elif stop is None:
                stop = t
        after = r["bytes"] - at_dec
        last_rel = r["last_write"] - t0
        # when did delivery actually cease, relative to the decision?
        print(f"  {mark}-{role}  {name:11s}: after_decision={after:>9,} B "
              f"({after / RATE:6.3f} s of programme)  last_write={last_rel:+7.3f} s  "
              f"total={r['bytes']:>10,} B")
        out.append((role, after, after / RATE, last_rel))
    return out


if __name__ == "__main__":
    for m in sys.argv[1:]:
        arm(m)
