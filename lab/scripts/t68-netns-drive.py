#!/usr/bin/env python3
"""T68 part A's driver: arms of t68-netns-cell.sh in T28's netns/cake rig, as root.

  t68-netns-drive.py run <root> --arm NAME --placement front|ack --cc cubic|bbr --lat-ms N
                     [--hold-ms 2500] [--target-ms N] [--shapes outage,loss5,...] [--reps 3]
                     [--env K=V ...]
  t68-netns-drive.py summarize <root>/<arm>

An arm brings the pair up at 20 Mb/s and 100 ms RTT with its placement (front: T28's, 50 ms in front
of the shaper and 50 ms on the acknowledgements; ack: all 100 ms on the acknowledgements, as
t2831-topology.sh), sets the publisher namespace's TCP controller, runs its control and then each
shape's replicates in turn, replicate-major as T28 ran them. With --target-ms, a control whose median
latency is more than 100 ms from the target is re-run with the cushion moved by the difference, up
to three times (criterion 9). The arm stops before its shapes if its control loses content at the
groomer or gives a segment up.

Every cell is conserved against the arm's control (t2831-conservation.py's ladder layout, each
cell's own window): at the groomer's output and, beside it, at the receiver's. summary.jsonl holds
one line per cell and one per shape (medians over the replicates).
"""

import argparse
import csv
import json
import os
import shutil
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NETNS = os.path.join(HERE, "t8b-netns.sh")
CELL = os.path.join(HERE, "t68-netns-cell.sh")
CONSERVE = os.path.join(HERE, "t2831-conservation.py")


def sh(*cmd, env=None, check=True):
	return subprocess.run(list(cmd), env=env, check=check, capture_output=True, text=True)


def up(placement, cc):
	env = dict(os.environ, RATE_MBIT="20", DELAY_MS="50")
	if placement == "ack":
		env.update(PATH_DELAY_MS="0", ACK_DELAY_MS="100")
	sh("bash", NETNS, "up", env=env)
	sh("bash", NETNS, "cake", env=env)
	if cc == "bbr":
		sh("modprobe", "tcp_bbr")
	sh("ip", "netns", "exec", "t8b-pub", "sysctl", "-q", "-w", f"net.ipv4.tcp_congestion_control={cc}")
	got = sh("ip", "netns", "exec", "t8b-pub", "sysctl", "-n", "net.ipv4.tcp_congestion_control").stdout.strip()
	if got != cc:
		sys.exit(f"controller is {got}, not {cc}")


def down():
	sh("bash", NETNS, "down", check=False)


def run_cell(arm_dir, name, shape, lat_ms, a):
	d = os.path.join(arm_dir, name)
	env = dict(os.environ, LAT_MS=str(lat_ms), HOLD_MS=str(a.hold_ms),
			PATH_DELAY_MS="0" if a.placement == "ack" else "50")
	env.update(kv.split("=", 1) for kv in a.env)
	r = subprocess.run(["bash", CELL, d, shape], env=env, capture_output=True, text=True)
	open(os.path.join(arm_dir, f"{name}.out"), "w").write(r.stdout + r.stderr)
	try:
		g = json.load(open(os.path.join(d, "grade.json")))
	except (OSError, ValueError):
		g = dict(cell=name, shape=shape, error=f"cell exited {r.returncode}", tail=(r.stdout + r.stderr)[-400:])
		if r.returncode == 2:
			raise SystemExit(f"{name} refused to start: {g['tail']}")
	with open(os.path.join(arm_dir, "cells.jsonl"), "a") as f:
		f.write(json.dumps(g) + "\n")
	print(json.dumps(dict(cell=name, lat_ms=lat_ms, latency=g.get("latency", {}).get("lat_median"),
						lost=g.get("groomer_content", {}).get("content_lost_s"),
						late_pct=g.get("receiver", {}).get("before_shape", {}).get("late_pct"),
						error=g.get("error"))), flush=True)
	return g


def control_ok(g):
	"""Criterion 7's first half. Its second, segments past the hold, is graded in the report: at
	T28's placement it fails at any hold, and the bias arm is run beside, not in place of, the arm."""
	gc, rc = g.get("groomer_content", {}), g.get("receiver", {})
	return gc.get("content_lost_s") == 0 and rc.get("lost") == 0


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
	ctrl = [g for g in cells if g["cell"] == "control"]
	if not ctrl:
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
				groomer=g["groomer"].get("window"))
		rows.append(r)
		if g["cell"] != "control" and not g["cell"].startswith("control-"):
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
	r.add_argument("--placement", choices=("front", "ack"), required=True)
	r.add_argument("--cc", choices=("cubic", "bbr"), required=True)
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
	arm_dir = os.path.join(a.root, a.arm)
	os.makedirs(arm_dir, exist_ok=False)
	json.dump(vars(a), open(os.path.join(arm_dir, "arm.json"), "w"))
	up(a.placement, a.cc)
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
			print(json.dumps(dict(arm=a.arm, stop="control fails criterion 7" if not control_ok(g)
								else "control not matched (criterion 9)", lat_ms=lat)), flush=True)
			return
		shapes = [x for x in a.shapes.split(",") if x]
		for rep in range(1, a.reps + 1):
			for shape in shapes:
				run_cell(arm_dir, f"{shape}-{rep}", shape, lat, a)
	finally:
		down()
	summarize(arm_dir)


if __name__ == "__main__":
	main()
