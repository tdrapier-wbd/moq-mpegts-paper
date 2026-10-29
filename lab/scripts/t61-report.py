#!/usr/bin/env python3
"""T61's per-cell report (lab/test-61-origin-group-failover.md), on the workstation.

  t61-report.py DIR

DIR holds the cell's events.txt ("name epoch_ns", from t59-cell.sh), each receiver's log
(b8-a.jsonl, b8-b.jsonl) and each origin's nginx access log (access-a.log, access-b.log:
"msec status uri bytes request_time addr"). Prints one JSON object: per receiver, the longest
wait between new segments after its first, and its losses, retries and playlist failures; per
origin, when it answered /g/; and the failover onset (the failure to B's first /g/ answer) and
failback (the restoration to A's first /g/ answer after it).
"""
import json
import os
import sys

COUNTED = ("seg-lost", "seg-retry", "pl-fail", "msn-regress", "msn-skip")


def main():
	d = sys.argv[1]
	events = []
	path = os.path.join(d, "events.txt")
	for line in open(path) if os.path.exists(path) else []:
		name, ns = line.split()
		events.append((name, int(ns) / 1e9))
	fault = events[0] if events else None
	restore = events[1] if len(events) > 1 else None
	out = {"events": {n: round(t, 3) for n, t in events}}
	for leg in "ab":
		segs, counts = [], {}
		for line in open(os.path.join(d, f"b8-{leg}.jsonl")):
			e = json.loads(line)
			counts[e["ev"]] = counts.get(e["ev"], 0) + 1
			if e["ev"] == "seg":
				segs.append(e["t"])
		waits = [(b - a, a) for a, b in zip(segs, segs[1:])]
		w, at = max(waits) if waits else (0, 0)
		out[f"leg_{leg}"] = {"segments": len(segs), "longest_wait_s": round(w, 3),
							"wait_starts_after_fault_s": round(at - fault[1], 3) if fault else None,
							**{k: counts.get(k, 0) for k in COUNTED}}
	served = {}
	for o in "ab":
		ok = []
		for line in open(os.path.join(d, f"access-{o}.log")):
			f = line.split()
			if len(f) >= 3 and f[2].startswith("/g/") and f[1] == "200":
				ok.append(float(f[0]))
		served[o] = ok
		out[f"origin_{o}_g_200s"] = len(ok)
	if fault:
		b_after = [t for t in served["b"] if t >= fault[1]]
		out["failover_s"] = round(b_after[0] - fault[1], 3) if b_after else None
		a_before = [t for t in served["a"] if t < fault[1]]
		out["a_last_before_fault_s"] = round(a_before[-1] - fault[1], 3) if a_before else None
	if restore:
		a_after = [t for t in served["a"] if t >= restore[1]]
		out["failback_s"] = round(a_after[0] - restore[1], 3) if a_after else None
		b_late = [t for t in served["b"] if t >= restore[1]]
		out["b_last_after_restore_s"] = round(b_late[-1] - restore[1], 3) if b_late else None
	print(json.dumps(out))


if __name__ == "__main__":
	main()
