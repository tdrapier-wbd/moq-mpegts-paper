#!/usr/bin/env python3
"""Report T38's topology arms: what de-provisioning one channel cost the other."""
import json
import subprocess
import re
import sys

W = "/tmp/t36"


def cc_errors(path):
    p = subprocess.run(f'tsp -I file "{path}" -P continuity -O drop',
                       shell=True, capture_output=True, text=True)
    return len(re.findall(r"missing [\d,]+ packet", p.stdout + p.stderr))


def packets(path):
    p = subprocess.run(f'tsp -I file "{path}" -P analyze --normalized -O drop',
                       shell=True, capture_output=True, text=True)
    for line in p.stdout.splitlines():
        if line.startswith("ts:"):
            d = dict(f.split("=", 1) for f in line.split(":") if "=" in f)
            return int(d.get("packets", 0))
    return 0


def gaps(profile, thresh=0.5):
    """Interruptions in delivery longer than `thresh` seconds."""
    out = []
    for i in range(1, len(profile)):
        d = profile[i][0] - profile[i - 1][0]
        if d > thresh:
            out.append(round(d, 3))
    return out


def main():
    lbs = {r["mark"]: r for r in (json.loads(l) for l in open(f"{W}/lastbyte.jsonl"))}
    decs = [json.loads(l) for l in open(f"{W}/decisions.jsonl")]

    def dec(sub):
        m = [d for d in decs if sub in (d.get("mark") or "")]
        return m[-1]["wall"] if m else None

    for topo, withdrawn, kept, extra, mark in (
        ("BROAD", "BROAD-cnn", "BROAD-tnt", "BROAD-tnt2", "BROAD withdraw cnn"),
        ("NARROW", "NARROW-cnn", "NARROW-tnt", None, "NARROW withdraw cnn"),
    ):
        t0 = dec(mark)
        print(f"\n  --- {topo} ---")
        if t0 is None:
            print("    no decision recorded")
            continue
        for role, mk in (("withdrawn channel (cnn)", withdrawn),
                         ("KEPT channel (tnt)", kept),
                         ("kept channel, re-provisioned", extra)):
            if mk is None:
                continue
            r = lbs.get(mk)
            if not r or not r.get("profile"):
                print(f"    {role:30s}: NO MEDIA")
                continue
            path = f"{W}/out/{mk}.ts"
            g = gaps(r["profile"])
            last = r["last_write"] - t0
            first = r["first_write"] - t0
            print(f"    {role:30s}: first{first:+7.2f}s last{last:+7.2f}s  "
                  f"{r['bytes']:>10,} B  {packets(path):>7,} pkts  "
                  f"cc_err={cc_errors(path):<3} gaps>0.5s={g if g else 'none'}")


if __name__ == "__main__":
    main()
