#!/usr/bin/env python3
"""T84's driver: arms of t84-moq-cell.sh through a CDN relay or a local one, as root.

  t84-moq-drive.py run <root> --arm NAME --relay node|local --lane demux|passthrough --delay-ms N
                   --target-ms T [--shapes outage,loss5,...] [--reps 3] [--qlog SHAPE --qlog-moq PATH]
                   [--env K=V ...]
  t84-moq-drive.py summarize <root>/<arm>
  t84-moq-drive.py compare <root>
  t84-moq-drive.py compare-arms <root> <base-arm>     (T85: every arm against one, per shape)

As t72-cdn-drive.py: an arm brings T72's two paths up (t72-net.sh), runs its control and then each
shape's replicates in turn, replicate-major, and takes the paths down. A control whose median
latency is more than 100 ms from the target is re-run with the export's delay moved by the miss,
up to five times (criterion 1); an arm still unmatched runs on the last delay, recorded as
unmatched in column.json. The arm stops before its shapes if its control loses content or ends
early. A cell whose control leg has a hole or ends early is void (criterion 2) and is run once more. With
--qlog, one more cell of that shape runs last with the impaired leg on a qlog build; it is graded
but not counted in the medians. RELAY=node takes URL from the environment, and pins its name in both
paths to the address it resolves to when the arm starts.

Every cell is conserved against the arm's control at the export's output (t2831-conservation.py,
each cell's own window). summary.jsonl holds one line per cell, with the control leg's verdict and
the impaired netem's mean packet (criterion 3), and one per shape: medians over the valid replicates.
compare prints criterion 5 for a root's arms, named <node|local>-<lane>-<a|b>: per lane, column and
shape, both relays' replicates and the verdict on their medians.
"""

import argparse
import csv
import importlib.util
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
NET = os.path.join(HERE, "t72-net.sh")
CELL = os.path.join(HERE, "t84-moq-cell.sh")
CONSERVE = os.path.join(HERE, "t2831-conservation.py")


def t72():
	spec = importlib.util.spec_from_file_location("t72drive", os.path.join(HERE, "t72-cdn-drive.py"))
	m = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(m)
	return m


def leg_ok(g):
	c = g.get("content", {})
	return c.get("content_lost_s") == 0 and not g.get("ended_early") and "error" not in c


def ctl_verdict(cell_dir):
	try:
		c = json.load(open(os.path.join(cell_dir, "ctl", "grade.json")))
	except (OSError, ValueError):
		return dict(ok=False, why="no control-leg grade")
	return dict(ok=leg_ok(c), holes_s=c.get("content", {}).get("content_lost_s"), ended_early=c.get("ended_early"),
				latency_ms=c.get("latency", {}).get("lat_median"))


def run_cell(arm_dir, name, shape, delay_ms, a, extra=None):
	d = os.path.join(arm_dir, name)
	env = dict(os.environ, RELAY=a.relay, LANE=a.lane, DELAY_MS=str(delay_ms))
	env.update(kv.split("=", 1) for kv in a.env)
	env.update(extra or {})
	r = subprocess.run(["bash", CELL, d, shape], env=env, capture_output=True, text=True)
	open(os.path.join(arm_dir, f"{name}.out"), "w").write(r.stdout + r.stderr)
	try:
		g = json.load(open(os.path.join(d, "grade.json")))
	except (OSError, ValueError):
		g = dict(cell=name, shape=shape, error=f"cell exited {r.returncode}", tail=(r.stdout + r.stderr)[-400:])
		if r.returncode == 2:
			raise SystemExit(f"{name} refused to start: {g['tail']}")
	g["ctl"] = ctl_verdict(d)
	g["netem_mean_packet_b"] = t72().mean_packet(d)
	with open(os.path.join(arm_dir, "cells.jsonl"), "a") as f:
		f.write(json.dumps(g) + "\n")
	print(json.dumps(dict(cell=name, delay_ms=delay_ms, latency=g.get("latency", {}).get("lat_median"),
						lost=g.get("content", {}).get("content_lost_s"), ended_early=g.get("ended_early"),
						ctl_ok=g["ctl"]["ok"], pkt=g["netem_mean_packet_b"], error=g.get("error"))), flush=True)
	return g


def bottleneck(cell_dir):
	"""Packets the path's bottleneck sent and dropped from the cell's start to its shape's end (step,
	shallow). The cake's counters run from the paths' start; a token bucket's from its shape's."""
	def counts(name):
		try:
			text = open(os.path.join(cell_dir, name)).read()
		except OSError:
			return {}
		pat = r"qdisc (\w+ \d+:) parent 1:1 .*\n\s*Sent \d+ bytes (\d+) pkt \(dropped (\d+)"
		return {q: (int(p), int(d)) for q, p, d in re.findall(pat, text)}
	before = counts("qdisc-before.txt")
	for q, (pkt, dropped) in counts("bottleneck.txt").items():
		b = before.get(q, (0, 0))
		return dict(qdisc=q, sent_pkt=pkt - b[0], dropped=dropped - b[1])
	return None


def conserve(arm_dir, cells):
	cdir = os.path.join(arm_dir, "cons")
	shutil.rmtree(cdir, ignore_errors=True)
	os.makedirs(cdir)
	with open(os.path.join(cdir, "summary.csv"), "w", newline="") as f:
		w = csv.writer(f)
		w.writerow(["cell", "window_s"])
		for g in cells:
			j = os.path.join(arm_dir, g["cell"], "out.content.json")
			if os.path.exists(j):
				shutil.copy(j, os.path.join(cdir, f"{g['cell']}.content.json"))
				w.writerow([g["cell"], g["window_s"]])
	out_csv = os.path.join(cdir, "conserved.csv")
	subprocess.run([sys.executable, CONSERVE, cdir, "--from-s", "8", "--csv", out_csv], capture_output=True)
	try:
		return {r["cell"]: r for r in csv.DictReader(open(out_csv))}
	except OSError:
		return {}


def summarize(arm_dir):
	cells = [json.loads(line) for line in open(os.path.join(arm_dir, "cells.jsonl"))]
	cells = [g for g in cells if "error" not in g]
	if not [g for g in cells if g["cell"] == "control"]:
		sys.exit("no control cell")
	cons = conserve(arm_dir, cells)
	rows, by_shape = [], {}
	for g in cells:
		c = cons.get(g["cell"], {})
		r = dict(cell=g["cell"], shape=g["shape"], relay=g["relay"], lane=g["lane"], delay_ms=g["delay_ms"],
				latency_ms=g["latency"].get("lat_median"), holes_s=g["content"].get("content_lost_s"),
				largest_hole_s=g["content"].get("largest_hole_s"), missing_s=c.get("missing_s"),
				audio_missing_s=c.get("audio_missing_s"), ended_early=g["ended_early"],
				sub_warn=g["subscriber"].get("warn"), udp_errors=g.get("udp_errors"),
				ctl_ok=g["ctl"]["ok"], ctl_holes_s=g["ctl"].get("holes_s"),
				netem_mean_packet_b=g.get("netem_mean_packet_b"), day=g["day"], window_utc=g["window_utc"],
				shape_utc=g.get("shape_utc"), bottleneck=bottleneck(os.path.join(arm_dir, g["cell"])))
		rows.append(r)
		counted = g["cell"] != "control" and not g["cell"].startswith("control-") and not g.get("qlog")
		if counted and r["ctl_ok"]:
			by_shape.setdefault(g["shape"], []).append(r)
	with open(os.path.join(arm_dir, "summary.jsonl"), "w") as f:
		for r in rows:
			f.write(json.dumps(r) + "\n")
		for shape, rs in by_shape.items():
			def med(k):
				xs = [float(x[k]) for x in rs if x.get(k) not in (None, "", "NA")]
				return round(statistics.median(xs), 2) if xs else None
			m = dict(shape=shape, n=len(rs), median_missing_s=med("missing_s"), median_holes_s=med("holes_s"),
					median_audio_missing_s=med("audio_missing_s"), missing_s=[x["missing_s"] for x in rs])
			if any(x["bottleneck"] for x in rs):
				m["bottleneck_dropped"] = [(x["bottleneck"] or {}).get("dropped") for x in rs]
				m["bottleneck_sent_pkt"] = [(x["bottleneck"] or {}).get("sent_pkt") for x in rs]
			f.write(json.dumps(m) + "\n")
			print(json.dumps(m))


def differs(x, y):
	"""Criterion 5's rule: two medians differ by more than 2 s and by more than a quarter of the larger."""
	d = abs(x - y)
	return d > 2 and d > max(abs(x), abs(y)) / 4


def medians(root):
	"""{(arm, shape): the shape's median line} for every arm under root."""
	med = {}
	for arm in sorted(os.listdir(root)):
		path = os.path.join(root, arm, "summary.jsonl")
		if os.path.exists(path):
			for line in open(path):
				r = json.loads(line)
				if "median_missing_s" in r:
					med[(arm, r["shape"])] = r
	return med


def compare_arms(root, base):
	"""T85: each arm's medians beside BASE's, per shape, by criterion 5's rule."""
	med = medians(root)
	for (arm, shape), r in sorted(med.items(), key=lambda kv: (kv[0][1], kv[0][0])):
		b = med.get((base, shape))
		row = dict(shape=shape, arm=arm, missing_s=r["missing_s"], median_s=r["median_missing_s"])
		if "bottleneck_dropped" in r:
			row["dropped"] = r["bottleneck_dropped"]
		if b and arm != base and None not in (r["median_missing_s"], b["median_missing_s"]):
			x, y = r["median_missing_s"], b["median_missing_s"]
			row["vs_" + base] = ("less" if x < y else "more") if differs(x, y) else "as " + base
		print(json.dumps(row))


def compare(root):
	"""Criterion 5: "the relay's" where the node's and the local relay's medians differ by more
	than 2 s and by more than a quarter of the larger, "as local" otherwise."""
	med = {}
	for arm in sorted(os.listdir(root)):
		path = os.path.join(root, arm, "summary.jsonl")
		if not os.path.exists(path):
			continue
		relay, lane, part = arm.split("-")
		for line in open(path):
			r = json.loads(line)
			if "median_missing_s" in r:
				med[(lane, part, r["shape"], relay)] = r
	for lane, part, shape in sorted({k[:3] for k in med}):
		n, loc = med.get((lane, part, shape, "node")), med.get((lane, part, shape, "local"))
		row = dict(lane=lane, arm=part, shape=shape, node=n and n["missing_s"], local=loc and loc["missing_s"])
		if n and loc and None not in (n["median_missing_s"], loc["median_missing_s"]):
			x, y = n["median_missing_s"], loc["median_missing_s"]
			row["verdict"] = "the relay's" if differs(x, y) else "as local"
		print(json.dumps(row))


def next_delay(tried, target):
	"""The next control's delay: the export runs at its delay plus an offset each session sets at
	its join, so the delay moves by the whole miss, or along the last two controls' slope where
	that is between 0.5 and 2."""
	(d1, l1) = tried[-1]
	if len(tried) > 1:
		d0, l0 = tried[-2]
		if d1 != d0 and 0.5 <= (l1 - l0) / (d1 - d0) <= 2:
			return int(round(d1 + (target - l1) * (d1 - d0) / (l1 - l0)))
	return int(round(d1 + target - l1))


def main():
	ap = argparse.ArgumentParser()
	sp = ap.add_subparsers(dest="cmd", required=True)
	r = sp.add_parser("run")
	r.add_argument("root")
	r.add_argument("--arm", required=True)
	r.add_argument("--relay", choices=("node", "local"), required=True)
	r.add_argument("--lane", choices=("demux", "passthrough"), required=True)
	r.add_argument("--delay-ms", type=int, required=True)
	r.add_argument("--target-ms", type=float, required=True)
	r.add_argument("--shapes", default="")
	r.add_argument("--reps", type=int, default=3)
	r.add_argument("--qlog", default=None)
	r.add_argument("--qlog-moq", default=None)
	r.add_argument("--env", action="append", default=[])
	s = sp.add_parser("summarize")
	s.add_argument("arm_dir")
	c = sp.add_parser("compare")
	c.add_argument("root")
	ca = sp.add_parser("compare-arms")
	ca.add_argument("root")
	ca.add_argument("base")
	a = ap.parse_args()
	if a.cmd == "summarize":
		summarize(a.arm_dir)
		return
	if a.cmd == "compare":
		compare(a.root)
		return
	if a.cmd == "compare-arms":
		compare_arms(a.root, a.base)
		return
	if os.geteuid() != 0:
		sys.exit("run as root")
	if a.qlog and not a.qlog_moq:
		sys.exit("--qlog needs --qlog-moq")
	if a.relay == "node":
		host = urlparse(os.environ.get("URL", "")).hostname
		if not host:
			sys.exit("RELAY=node needs URL in the environment")
		domain, edge = host, socket.getaddrinfo(host, 443, socket.AF_INET)[0][4][0]
	else:
		domain, edge = "t84.invalid", "10.72.1.1"
	arm_dir = os.path.join(a.root, a.arm)
	os.makedirs(arm_dir, exist_ok=False)
	json.dump({k: v for k, v in vars(a).items() if k != "env"}, open(os.path.join(arm_dir, "arm.json"), "w"))
	subprocess.run(["bash", NET, "up", domain, edge], check=True, capture_output=True)
	try:
		delay, tried, g = a.delay_ms, [], None
		for n in range(1, 7):
			g = run_cell(arm_dir, f"control-{n}", "none", delay, a)
			got = g.get("latency", {}).get("lat_median")
			if got is None or abs(got - a.target_ms) <= 100 or n == 6:
				break
			tried.append((delay, got))
			delay = next_delay(tried, a.target_ms)
		os.symlink(f"control-{n}", os.path.join(arm_dir, "control"))
		with open(os.path.join(arm_dir, "cells.jsonl"), "a") as f:
			f.write(json.dumps(dict(g, cell="control")) + "\n")
		matched = abs((g.get("latency", {}).get("lat_median") or 1e9) - a.target_ms) <= 100
		json.dump(dict(delay_ms=delay, controls=n, matched=matched), open(os.path.join(arm_dir, "column.json"), "w"))
		if not (leg_ok(g) and g["ctl"]["ok"]):
			print(json.dumps(dict(arm=a.arm, stop="control fails criterion 1", delay_ms=delay)), flush=True)
			return
		if not matched:
			print(json.dumps(dict(arm=a.arm, unmatched="criterion 1", delay_ms=delay)), flush=True)
		shapes = [x for x in a.shapes.split(",") if x]
		for rep in range(1, a.reps + 1):
			for shape in shapes:
				g = run_cell(arm_dir, f"{shape}-{rep}", shape, delay, a)
				if not g.get("ctl", {}).get("ok"):
					run_cell(arm_dir, f"{shape}-{rep}b", shape, delay, a)
		if a.qlog:
			run_cell(arm_dir, f"{a.qlog}-qlog", a.qlog, delay, a, extra=dict(QLOG_MOQ=a.qlog_moq))
	finally:
		subprocess.run(["bash", NET, "down"], capture_output=True)
	summarize(arm_dir)


if __name__ == "__main__":
	main()
