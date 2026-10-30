#!/usr/bin/env python3
"""Grade one t68-netns-cell.sh cell: grade.json in the cell, and one JSON line on stdout.

  - content at the groomer's output (out.ts) and at the receiver's (recv.ts), each by
    t28-content-lost.py from 8 s, as T28 graded its lanes; conservation against the arm's control is
    t68-netns-summary.py's, from the windows recorded here;
  - delivery latency by t18-latency.py report over the source and egress taps (one host, clock
    offset 0, 8 s settle), T28's matching instrument;
  - the receiver's segments: held to their release or late, fetch time and goodput, retries,
    give-ups and failed playlist reads, before the shape and from it on;
  - the groomer's counters from its first output to the stop, from its 1 s samples.

Usage: t68-netns-grade.py <cell-dir> [--scripts DIR]
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys

COUNTERS = ("dropped", "late_drops", "underruns", "stalls", "muted", "withheld", "cut_runs")


def events(cell):
	ev, params = {}, {}
	for line in open(os.path.join(cell, "events.log")):
		t, what, *rest = line.split()
		if what == "start":
			params = dict(kv.split("=", 1) for kv in rest)
		ev.setdefault(what, float(t))
	return ev, params


def pct(xs, q):
	if not xs:
		return None
	xs = sorted(xs)
	return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def content(cell, name, scripts):
	ts = os.path.join(cell, f"{name}.ts")
	js = os.path.join(cell, f"{name}.content.json")
	if not os.path.exists(ts) or os.path.getsize(ts) < 200_000:
		return dict(error=f"{name}.ts missing or empty")
	subprocess.run([sys.executable, os.path.join(scripts, "t28-content-lost.py"), "--input", ts,
					"--from-s", "8", "--json", js], capture_output=True)
	try:
		r = json.load(open(js))
	except (OSError, ValueError):
		return dict(error="content grader failed")
	keep = ("content_lost_s", "holes", "largest_hole_s", "timeline_advance_s", "content_present_s",
			"audio_lost_s", "audio_present_s")
	return {k: r.get(k) for k in keep}


def latency(cell, scripts):
	kv = os.path.join(cell, "lat.kv")
	r = subprocess.run([sys.executable, os.path.join(scripts, "t18-latency.py"), "report",
						os.path.join(cell, "src.csv"), os.path.join(cell, "eg.csv"), "--clock-offset", "0",
						"--settle", "8", "--kv", kv], capture_output=True, text=True)
	open(os.path.join(cell, "lat.txt"), "w").write(r.stdout + r.stderr)
	try:
		d = dict(line.strip().split("=", 1) for line in open(kv) if "=" in line)
	except OSError:
		return dict(error="no latency")
	trend = re.search(r"first third ([\d.]+) ms -> last third ([\d.]+) ms", r.stdout)
	out = {k: float(d[k]) for k in ("lat_min", "lat_median", "lat_p95") if k in d}
	if trend:
		out["first_third_ms"], out["last_third_ms"] = float(trend.group(1)), float(trend.group(2))
	return out


def receiver(cell, t_shape):
	segs, counts = [], dict(retry=0, lost=0, pl_fail=0, msn_skip=0)
	for line in open(os.path.join(cell, "recv.jsonl")):
		r = json.loads(line)
		e = r.get("ev")
		if e == "seg":
			segs.append(r)
		elif e == "seg-retry":
			counts["retry"] += 1
		elif e == "seg-lost":
			counts["lost"] += 1
		elif e == "pl-fail":
			counts["pl_fail"] += 1
		elif e == "msn-skip":
			counts["msn_skip"] += 1

	def summary(ss):
		if not ss:
			return dict(n=0)
		late = [s["late_ms"] for s in ss if "late_ms" in s]
		ms = [s["ms"] for s in ss]
		mbps = [s["bytes"] * 8 / s["ms"] / 1000 for s in ss if s["ms"] > 0]
		return dict(n=len(ss), late=len(late), late_pct=round(100 * len(late) / len(ss), 2),
					late_ms_max=max(late) if late else 0.0, fetch_ms_p50=pct(ms, 0.5), fetch_ms_p99=pct(ms, 0.99),
					goodput_mbps_p50=round(statistics.median(mbps), 2) if mbps else None,
					goodput_mbps_min=round(min(mbps), 2) if mbps else None)

	before = [s for s in segs if t_shape is None or s["t"] < t_shape]
	after = [s for s in segs if t_shape is not None and s["t"] >= t_shape]
	return dict(before_shape=summary(before), from_shape=summary(after) if t_shape else None, **counts)


def groomer(cell, t_first, t_stop, t_pacer0):
	samples = []
	for line in open(os.path.join(cell, "pacer.log")):
		if "sample t=" in line:
			samples.append(dict(re.findall(r"(\w+)=([\w.]+)", line)))
	live = [s for s in samples if int(s["out"]) > 0]
	if not live:
		return dict(error="no output")
	span = t_stop - t_first
	first = live[0]
	last = [s for s in live if int(s["t"]) <= int(first["t"]) + span] or live[-1:]
	last = last[-1]
	return dict(window={k: int(last[k]) - int(first[k]) for k in COUNTERS if k in first},
				from_s=int(first["t"]), to_s=int(last["t"]),
				buffer_max_pkts=max(int(s["buffer"]) for s in live),
				high_water_pkts=max(int(s["buffer_high_water"]) for s in samples))


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	a = ap.parse_args()
	ev, p = events(a.cell)
	t_shape = ev.get("impair-start")
	out = dict(cell=os.path.basename(a.cell.rstrip("/")), shape=p["shape"], cc=p["cc"],
			slow_start_after_idle=p["slow_start_after_idle"], path_delay_ms=int(p["path_delay_ms"]),
			lat_ms=int(p["lat_ms"]), hold_ms=int(p["hold_ms"]), align_ms=int(p["align_ms"]),
			recv_timeout=p["recv_timeout"], give_up_ms=int(p["give_up_ms"]),
			window_s=round(ev["stop"] - ev["first-output"], 3),
			recv_window_s=round(ev["stop"] - ev["recv-start"], 3),
			first_output_after_recv_s=round(ev["first-output"] - ev["recv-start"], 3))
	if t_shape is not None:
		out["shape_at_s"] = round(t_shape - ev["first-output"], 3)
		out["shape_for_s"] = round(ev["impair-end"] - t_shape, 3)
	out["latency"] = latency(a.cell, a.scripts)
	out["groomer_content"] = content(a.cell, "out", a.scripts)
	out["receiver_content"] = content(a.cell, "recv", a.scripts)
	out["receiver"] = receiver(a.cell, t_shape)
	out["groomer"] = groomer(a.cell, ev["first-output"], ev["stop"], ev["recv-start"])
	json.dump(out, open(os.path.join(a.cell, "grade.json"), "w"), indent=1)
	print(json.dumps(out))


if __name__ == "__main__":
	main()
