#!/usr/bin/env python3
"""Grade one t68-seg-pair.sh run: one JSON line on stdout.

Per chain, each groomer's counters and its buffer's peak (from the 1 s samples' level, so a peak
inside a second can be missed) are counted from its first output to the legs' stop: a leg's
start-up (an alignment watch that fills to the cap, packets behind the grid it settles on) and its
end (the run cut when the receiver stops) are the same on both legs and are not the steady state
the criteria are about. Totals and the all-run high-water mark are kept beside; the cap is in
packets at the groomer's rate, as the groomer enforces it. Identity is t12-rtpcmp.py over every
slot both legs carry.

With a freeze in events.log, both legs are also graded on content (t68-rtp2ts.py, then
t28-content-lost.py from 8 s), with the freeze's phase (the first listing after the freeze, less
the freeze) and the receiver's lateness on each segment fetched after the thaw.

Usage: t68-grade.py <run-dir> [--scripts DIR] [--src-rate BPS]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

COUNTERS = ("dropped", "late_drops", "underruns", "stalls", "muted", "withheld", "cut_runs")


def events(run):
	ev, params = {}, {}
	for line in open(os.path.join(run, "events.log")):
		if line.startswith("RESULT"):
			continue
		t, what, *rest = line.split()
		if what == "start":
			params = dict(kv.split("=", 1) for kv in rest)
		ev.setdefault(what, float(t))
	return ev, params


def groomer(path, window_s, src_rate):
	"""The buffer holds source packets, so its depth in seconds is at the source's rate."""
	samples, done = [], {}
	for line in open(path):
		if "sample t=" in line:
			kv = dict(re.findall(r"(\w+)=([\w.]+)", line))
			samples.append(kv)
		elif "done." in line:
			done = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line) if k in COUNTERS}
	live = [s for s in samples if int(s["out"]) > 0]
	if not live:
		return dict(error="no output")
	first = live[0]
	last = [s for s in live if int(s["t"]) <= window_s - 1] or live[-1:]
	last = last[-1]
	steady = {k: int(last[k]) - int(first[k]) for k in COUNTERS if k in first}
	hw = max(int(s["buffer_high_water"]) for s in samples)
	window = [s for s in live if int(first["t"]) <= int(s["t"]) <= int(last["t"])]
	peak = max(int(s["buffer"]) for s in window)
	return dict(steady=steady, steady_from_s=int(first["t"]), steady_to_s=int(last["t"]), total=done,
				high_water_pkts=hw, high_water_s=round(hw * 188 * 8 / src_rate, 2),
				steady_buffer_max_pkts=peak, steady_buffer_max_s=round(peak * 188 * 8 / src_rate, 2))


def identity(run, scripts):
	out = subprocess.run([sys.executable, os.path.join(scripts, "t12-rtpcmp.py"),
						os.path.join(run, "a.rtp"), os.path.join(run, "b.rtp")],
						capture_output=True, text=True).stdout
	both = re.search(r"slots carried by both: ([\d,]+)", out)
	ident = re.search(r"identical\s+([\d,]+)\s+\(\s*([\d.]+) %\)", out)
	res = re.search(r"residue \(beyond the counter\)\s+([\d,]+)", out)
	if not (both and ident and res):
		return dict(error=out[-300:])
	return dict(shared=int(both.group(1).replace(",", "")), identical_pct=float(ident.group(2)),
				residue=int(res.group(1).replace(",", "")))


def content(run, chain, scripts):
	with tempfile.TemporaryDirectory() as d:
		ts = os.path.join(d, f"{chain}.ts")
		js = os.path.join(d, f"{chain}.json")
		subprocess.run([sys.executable, os.path.join(scripts, "t68-rtp2ts.py"),
						os.path.join(run, f"{chain}.rtp"), ts], capture_output=True, check=True)
		subprocess.run([sys.executable, os.path.join(scripts, "t28-content-lost.py"), "--input", ts,
						"--from-s", "8", "--json", js], capture_output=True, check=True)
		r = json.load(open(js))
	keep = ("content_lost_s", "holes", "largest_hole_s", "audio_lost_s")
	return {k: r.get(k) for k in keep}


def freeze_detail(run, ev):
	fz, th = ev["freeze-a"], ev["thaw-a"]
	listings = [float(line.split()[0]) for line in open(os.path.join(run, "seg-a.log")) if " playlist " in line]
	nxt = [t for t in listings if t > fz]
	late = []
	for line in open(os.path.join(run, "recv-a.jsonl")):
		r = json.loads(line)
		if r.get("ev") == "seg" and r["t"] > th and len(late) < 8:
			late.append(r.get("late_ms", -r.get("held_ms", 0.0)))
	return dict(phase_s=round(nxt[0] - fz, 3) if nxt else None, freeze_s=round(th - fz, 3),
				late_ms_after_thaw=late)


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("run")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	ap.add_argument("--src-rate", type=int, default=9945951, help="the clip's PCR rate, b/s")
	a = ap.parse_args()
	ev, p = events(a.run)
	window = ev["legs-stop"] - ev["legs-start"]
	out = dict(run=os.path.basename(a.run.rstrip("/")), lat_ms=int(p["lat_ms"]), hold_ms=p["hold_ms"],
			align_ms=p.get("align_ms", "none"), cap_ms=int(p["cap_ms"]),
			cap_pkts=int(p["cap_ms"]) * int(p.get("rate", "11438000")) // (1000 * 188 * 8))
	chains = ("a", "b") if p.get("legs", "2") == "2" else ("a",)
	for c in chains:
		out[c] = groomer(os.path.join(a.run, f"pacer-{c}.log"), window, a.src_rate)
	if len(chains) == 2:
		out["identity"] = identity(a.run, a.scripts)
	if "freeze-a" in ev:
		out["freeze"] = freeze_detail(a.run, ev)
		for c in chains:
			out[c]["content"] = content(a.run, c, a.scripts)
	print(json.dumps(out))


if __name__ == "__main__":
	main()
