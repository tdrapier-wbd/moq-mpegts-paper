#!/usr/bin/env python3
"""T72's driver: arms of t72-cdn-cell.sh through a CDN edge or from the origin, as root.

  t72-cdn-drive.py run <root> --arm NAME --mode cf|direct [--domain D --edge IP] --lat-ms N
                   [--hold-ms 2500] [--target-ms N] [--shapes outage,loss5,...] [--reps 3] [--env K=V ...]
  t72-cdn-drive.py summarize <root>/<arm>

An arm brings T72's two paths up (t72-net.sh: the impaired one at 20 Mb/s and 100 ms RTT in T28's
placement, the control one unimpaired), runs its control and then each shape's replicates in turn,
replicate-major, as t68-netns-drive.py does, and takes the paths down. With --target-ms, a control
whose median latency is more than 100 ms from the target is re-run with the cushion moved by the
difference, up to three times (criterion 2). The arm stops before its shapes if its control loses
content, gives a segment up, or misses its target. A cell whose control leg has a hole or gives a
segment up is void (criterion 3) and is run once more.

Every cell is conserved against the arm's control, at the groomer's output and at the receiver's
(t2831-conservation.py, each cell's own window). summary.jsonl holds one line per cell, with the
control leg's verdict and the impaired netem's mean packet (criterion 4), and one per shape: medians
over the valid replicates.
"""

import argparse
import csv
import json
import os
import re
import shutil
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NET = os.path.join(HERE, "t72-net.sh")
CELL = os.path.join(HERE, "t72-cdn-cell.sh")
CONSERVE = os.path.join(HERE, "t2831-conservation.py")


def sh(*cmd, env=None, check=True):
	return subprocess.run(list(cmd), env=env, check=check, capture_output=True, text=True)


def netem_sent(path):
	"""Bytes and packets the impaired netem (handle 1:) had sent when the file was written."""
	try:
		text = open(path).read()
	except OSError:
		return None
	m = re.search(r"qdisc netem 1: .*?\n\s*Sent (\d+) bytes (\d+) pkt", text)
	return (int(m.group(1)), int(m.group(2))) if m else None


def mean_packet(cell_dir):
	a, b = netem_sent(os.path.join(cell_dir, "qdisc-before.txt")), netem_sent(os.path.join(cell_dir, "qdisc.txt"))
	if not a or not b or b[1] <= a[1]:
		return None
	return round((b[0] - a[0]) / (b[1] - a[1]), 1)


def ctl_verdict(cell_dir):
	try:
		c = json.load(open(os.path.join(cell_dir, "ctl", "grade.json")))
	except (OSError, ValueError):
		return dict(ok=False, why="no control-leg grade")
	holes = c.get("groomer_content", {}).get("content_lost_s")
	lost = c.get("receiver", {}).get("lost")
	return dict(ok=holes == 0 and lost == 0, holes_s=holes, segs_lost=lost,
				latency_ms=c.get("latency", {}).get("lat_median"))


def run_cell(arm_dir, name, shape, lat_ms, a):
	d = os.path.join(arm_dir, name)
	env = dict(os.environ, MODE=a.mode, CF_DOMAIN=a.domain or "", LAT_MS=str(lat_ms), HOLD_MS=str(a.hold_ms))
	env.update(kv.split("=", 1) for kv in a.env)
	r = subprocess.run(["bash", CELL, d, shape], env=env, capture_output=True, text=True)
	open(os.path.join(arm_dir, f"{name}.out"), "w").write(r.stdout + r.stderr)
	try:
		g = json.load(open(os.path.join(d, "grade.json")))
	except (OSError, ValueError):
		g = dict(cell=name, shape=shape, error=f"cell exited {r.returncode}", tail=(r.stdout + r.stderr)[-400:])
		if r.returncode == 2:
			raise SystemExit(f"{name} refused to start: {g['tail']}")
	g["ctl"] = ctl_verdict(d)
	g["netem_mean_packet_b"] = mean_packet(d)
	try:
		g["edge"] = open(os.path.join(d, "edge.txt")).read().split("\n")
	except OSError:
		pass
	with open(os.path.join(arm_dir, "cells.jsonl"), "a") as f:
		f.write(json.dumps(g) + "\n")
	print(json.dumps(dict(cell=name, lat_ms=lat_ms, latency=g.get("latency", {}).get("lat_median"),
						lost=g.get("groomer_content", {}).get("content_lost_s"),
						ctl_ok=g["ctl"]["ok"], pkt=g["netem_mean_packet_b"], error=g.get("error"))), flush=True)
	return g


def control_ok(g):
	gc, rc = g.get("groomer_content", {}), g.get("receiver", {})
	return gc.get("content_lost_s") == 0 and rc.get("lost") == 0 and g.get("ctl", {}).get("ok")


def conserve(arm_dir, cells, which, window_key):
	cdir = os.path.join(arm_dir, f"cons-{which}")
	shutil.rmtree(cdir, ignore_errors=True)
	os.makedirs(cdir)
	src = "out" if which == "groomer" else "recv"
	with open(os.path.join(cdir, "summary.csv"), "w", newline="") as f:
		w = csv.writer(f)
		w.writerow(["cell", "window_s"])
		for g in cells:
			j = os.path.join(arm_dir, g["cell"], f"{src}.content.json")
			if os.path.exists(j):
				shutil.copy(j, os.path.join(cdir, f"{g['cell']}.content.json"))
				w.writerow([g["cell"], g[window_key]])
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
	cons = {w: conserve(arm_dir, cells, w, k) for w, k in (("groomer", "window_s"), ("receiver", "recv_window_s"))}
	rows, by_shape = [], {}
	for g in cells:
		r = dict(cell=g["cell"], shape=g["shape"], cc=g["cc"], lat_ms=g["lat_ms"],
				latency_ms=g["latency"].get("lat_median"),
				holes_s=g["groomer_content"].get("content_lost_s"),
				missing_s=cons["groomer"].get(g["cell"], {}).get("missing_s"),
				audio_missing_s=cons["groomer"].get(g["cell"], {}).get("audio_missing_s"),
				recv_holes_s=g["receiver_content"].get("content_lost_s"),
				recv_missing_s=cons["receiver"].get(g["cell"], {}).get("missing_s"),
				segs_lost=g["receiver"]["lost"], retries=g["receiver"]["retry"],
				late_from_shape=(g["receiver"].get("from_shape") or {}).get("late"),
				ctl_ok=g["ctl"]["ok"], ctl_holes_s=g["ctl"].get("holes_s"),
				netem_mean_packet_b=g.get("netem_mean_packet_b"), groomer=g["groomer"].get("window"))
		rows.append(r)
		if g["cell"] != "control" and not g["cell"].startswith("control-") and r["ctl_ok"]:
			by_shape.setdefault(g["shape"], []).append(r)
	with open(os.path.join(arm_dir, "summary.jsonl"), "w") as f:
		for r in rows:
			f.write(json.dumps(r) + "\n")
		for shape, rs in by_shape.items():
			def med(k):
				xs = [float(x[k]) for x in rs if x.get(k) not in (None, "", "NA")]
				return round(statistics.median(xs), 2) if xs else None
			m = dict(shape=shape, n=len(rs), median_missing_s=med("missing_s"), median_holes_s=med("holes_s"),
					median_recv_missing_s=med("recv_missing_s"), median_audio_missing_s=med("audio_missing_s"),
					missing_s=[x["missing_s"] for x in rs])
			f.write(json.dumps(m) + "\n")
			print(json.dumps(m))


def main():
	ap = argparse.ArgumentParser()
	sp = ap.add_subparsers(dest="cmd", required=True)
	r = sp.add_parser("run")
	r.add_argument("root")
	r.add_argument("--arm", required=True)
	r.add_argument("--mode", choices=("cf", "direct"), required=True)
	r.add_argument("--domain", default=None)
	r.add_argument("--edge", default=None)
	r.add_argument("--lat-ms", type=int, required=True)
	r.add_argument("--hold-ms", type=int, default=2500)
	r.add_argument("--target-ms", type=float, default=None)
	r.add_argument("--shapes", default="")
	r.add_argument("--reps", type=int, default=3)
	r.add_argument("--env", action="append", default=[])
	s = sp.add_parser("summarize")
	s.add_argument("arm_dir")
	a = ap.parse_args()
	if a.cmd == "summarize":
		summarize(a.arm_dir)
		return
	if os.geteuid() != 0:
		sys.exit("run as root")
	if not a.domain or not a.edge:
		sys.exit("--domain and --edge are needed: the paths pin the domain in both modes")
	arm_dir = os.path.join(a.root, a.arm)
	os.makedirs(arm_dir, exist_ok=False)
	json.dump(vars(a), open(os.path.join(arm_dir, "arm.json"), "w"))
	sh("bash", NET, "up", a.domain, a.edge)
	try:
		lat, g = a.lat_ms, None
		for n in range(1, 5):
			g = run_cell(arm_dir, f"control-{n}", "none", lat, a)
			got = g.get("latency", {}).get("lat_median")
			if a.target_ms is None or got is None or abs(got - a.target_ms) <= 100 or n == 4:
				break
			lat = int(round(lat + a.target_ms - got))
		os.symlink(f"control-{n}", os.path.join(arm_dir, "control"))
		with open(os.path.join(arm_dir, "cells.jsonl"), "a") as f:
			f.write(json.dumps(dict(g, cell="control")) + "\n")
		matched = a.target_ms is None or abs((g.get("latency", {}).get("lat_median") or 1e9) - a.target_ms) <= 100
		if not control_ok(g) or not matched:
			print(json.dumps(dict(arm=a.arm, stop="control fails criterion 2 or 3" if not control_ok(g)
								else "control not matched (criterion 2)", lat_ms=lat)), flush=True)
			return
		shapes = [x for x in a.shapes.split(",") if x]
		for rep in range(1, a.reps + 1):
			for shape in shapes:
				g = run_cell(arm_dir, f"{shape}-{rep}", shape, lat, a)
				if not g.get("ctl", {}).get("ok"):
					run_cell(arm_dir, f"{shape}-{rep}b", shape, lat, a)
	finally:
		sh("bash", NET, "down", check=False)
	summarize(arm_dir)


if __name__ == "__main__":
	main()
