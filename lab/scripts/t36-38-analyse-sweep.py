#!/usr/bin/env python3
"""T37 D2: the cadence sweep, as a distribution and as a cost.

The phase of the decision within the poll cycle is taken from the endpoint's
OWN request log — the interval since the last re-check before the decision —
rather than from the offset the runner slept. The two agree only when the
settle time happens to be a whole multiple of the cadence, which it is not at
5, 10 and 30 s, and assuming otherwise produced a nonsense residual.
"""
import json
import statistics as st

W = "/tmp/t36"
auth = [json.loads(l) for l in open(f"{W}/authlog.jsonl")]
decs = {d["mark"]: d for d in (json.loads(l) for l in open(f"{W}/decisions.jsonl")) if d.get("mark")}
lbs = {r["mark"]: r for r in (json.loads(l) for l in open(f"{W}/lastbyte.jsonl"))}

rows = []
for line in open(f"{W}/sweep-d2.tsv"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 8:
        continue
    cad, mark = float(f[0]), f[1]
    d = decs.get(mark)
    a = lbs.get(f"{mark}-A")
    if not d:
        continue
    t0 = d["wall"]
    prior = [r["wall"] for r in auth
             if r.get("kid") == "affakey" and r["wall"] < t0 and t0 - r["wall"] < cad * 3]
    phase = (t0 - max(prior)) if prior else None
    teardown = (a["last_write"] - t0) if a and a.get("last_write") else None
    rows.append({"cad": cad, "mark": mark, "phase": phase, "teardown": teardown,
                 "collateral": float(f[4]), "rate": float(f[7]),
                 "reqs": int(f[5])})

incomplete = [r for r in rows if r["teardown"] is None]
usable = [r for r in rows if r["teardown"] is not None]

by = {}
for r in usable:
    by.setdefault(r["cad"], []).append(r)

print("  Teardown distribution — decision to the affiliate's last media byte\n")
print(f"  {'cadence':>7s}  {'n':>2s}  {'min':>6s}  {'median':>7s}  {'max':>7s}  "
      f"{'max/cad':>7s}  {'auth req/s':>10s}")
for cad in sorted(by):
    g = by[cad]
    t = sorted(x["teardown"] for x in g)
    print(f"  {cad:7.0f}  {len(g):2d}  {min(t):6.3f}  {st.median(t):7.3f}  {max(t):7.3f}  "
          f"{max(t)/cad:7.3f}  {st.mean(x['rate'] for x in g):10.3f}")

print("\n  Model — teardown = (cadence - phase) + fixed overhead, phase from the endpoint log\n")
print(f"  {'cadence':>7s}  {'n':>2s}  {'overhead mean':>14s}  {'sd':>7s}")
pooled = []
for cad in sorted(by):
    res = [x["teardown"] - (cad - x["phase"]) for x in by[cad] if x["phase"] is not None]
    if not res:
        continue
    pooled += res
    sd = st.pstdev(res) if len(res) > 1 else 0.0
    print(f"  {cad:7.0f}  {len(res):2d}  {st.mean(res):14.3f}  {sd:7.3f}")
if pooled:
    print(f"\n  pooled fixed overhead: {st.mean(pooled):.3f} s "
          f"(sd {st.pstdev(pooled):.3f}, n={len(pooled)})")

print("\n  Collateral affiliate across every revocation:")
disturbed = [r for r in usable if r["collateral"] < r["teardown"] - 0.5]
print(f"    runs where the uninvolved affiliate stopped early: {len(disturbed)} of {len(usable)}")

if incomplete:
    print(f"\n  Runs with no media recorded for the affiliate under test: "
          f"{[r['mark'] for r in incomplete]}")
