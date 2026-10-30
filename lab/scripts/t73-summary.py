#!/usr/bin/env python3
"""T73: summarise graded cells by lane, condition and budget.

  t73-summary.py <runs-dir> [--json OUT]

Reads <runs-dir>/r<k>-<lane>-<cond>-b<budget>/grade.json (t71-grade.py's) and prints, per lane,
condition and budget: replicates, how many are whole, the median of the cells' median latencies
and their range, the largest p95, the in-cell trend (tail less head), the applied loss each way,
the largest clock bound and the criteria-1-4 checks; on the segmented lane, its receiver's and
groomer's events summed.
"""
import argparse
import glob
import json
import os
import re
import statistics

CELL = re.compile(r"^r(\d+)-(srt|opaque|aware|seg)-(clean|burst|l[0-9.]+)-b(\d)$")


def num(x):
	return x if isinstance(x, (int, float)) else None


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("runs")
	ap.add_argument("--json")
	a = ap.parse_args()
	groups = {}
	for g in sorted(glob.glob(os.path.join(a.runs, "*", "grade.json"))):
		m = CELL.match(os.path.basename(os.path.dirname(g)))
		if not m:
			continue
		_, lane, cond, budget = m.groups()
		groups.setdefault((budget, cond, lane), []).append(json.load(open(g)))
	rows = []
	for (budget, cond, lane), cells in sorted(groups.items()):
		lat = [c["latency"] for c in cells if isinstance(c.get("latency"), dict)]
		med = [x for x in (num(L.get("lat_median")) for L in lat) if x is not None]
		p95 = [x for x in (num(L.get("lat_p95")) for L in lat) if x is not None]
		trend = [round(L["trend_tail"] - L["trend_head"], 1) for L in lat
				 if num(L.get("trend_tail")) is not None and num(L.get("trend_head")) is not None]
		whole = sum(1 for c in cells if c.get("content", {}).get("whole") and not c.get("wire", {}).get("cc_errors"))
		lost = [c.get("content", {}).get("content_lost_s") for c in cells]
		alost = [c.get("content", {}).get("audio_lost_s") for c in cells]
		applied = [(c["impairment"].get("in") or {}).get("applied_pct") for c in cells if isinstance(c.get("impairment"), dict)]
		ret = [(c["impairment"].get("out") or {}).get("applied_pct") for c in cells if isinstance(c.get("impairment"), dict)]
		rtt = [num(c.get("clock", {}).get("rtt_ms")) for c in cells]
		bound = [num(c.get("clock", {}).get("bound_ms")) for c in cells]
		shifts = sorted({L.get("shift") for L in lat})
		row = dict(budget=budget, cond=cond, lane=lane, n=len(cells), whole=whole,
				   median_ms=round(statistics.median(med), 1) if med else None,
				   range_ms=[min(med), max(med)] if med else None, p95_max_ms=max(p95) if p95 else None,
				   trend_ms=trend, video_lost_s=lost, audio_lost_s=alost, applied_in_pct=applied,
				   applied_out_pct=ret, rtt_ms=[x for x in rtt if x is not None],
				   bound_max_ms=max((x for x in bound if x is not None), default=None), shifts=shifts,
				   clock_ok=all(c.get("clock", {}).get("ok") for c in cells),
				   cc=[c.get("wire", {}).get("cc_errors") for c in cells],
				   pcr_over_40=[c.get("wire", {}).get("pcr_over_40ms") for c in cells],
				   matched=[L.get("matched") for L in lat], seen=[L.get("seen") for L in lat],
				   tstd=[(c.get("tstd") or {}).get("pass") for c in cells if "tstd" in c],
				   ran_s=[(c.get("receiver") or {}).get("ran_s") for c in cells])
		if lane == "seg":
			ev = {}
			for c in cells:
				for k, v in (c.get("segmented") or {}).items():
					if isinstance(v, int):
						ev[k] = ev.get(k, 0) + v
			row["segmented"] = ev
		rows.append(row)
		print(json.dumps(row))
	if a.json:
		json.dump(rows, open(a.json, "w"), indent=1)


if __name__ == "__main__":
	main()
