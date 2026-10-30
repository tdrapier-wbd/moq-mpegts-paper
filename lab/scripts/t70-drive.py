#!/usr/bin/env python3
"""T70's driver: per configuration, the cushion search and the floor's replicates (T70 Procedure).

  t70-drive.py run <root> [--configs 2:design:3000,2:default:1500,1:design:1500,1:default:500]
                   [--step 500] [--min 500] [--max 10000] [--reps 3]
  t70-drive.py summarize <root>

Each configuration is epoch:variant:first-cushion-ms. A cell (t70-wan-cell.sh) is clean when the
groomer counts nothing from its first output to the stop and the receiver gives nothing up. A cell
whose clock fails criterion 1 is re-run, at most twice, and never decides a step. The search walks
down from a clean cell to the first failure, or up from a failing one to the first clean step; the
floor then needs `reps` clean cells, and a failure there moves it up a step. ORIGIN_IP and PACER
pass through to the cell; the origin's scripts and the clock reference are the caller's.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def cell(root, epoch, variant, cushion, seq):
	name = f"e{epoch}-{variant}-c{cushion}-{seq}"
	path = os.path.join(root, name)
	for attempt in range(3):
		p = path if attempt == 0 else f"{path}r{attempt}"
		rc = subprocess.run(["bash", os.path.join(HERE, "t70-wan-cell.sh"), p, str(epoch), variant,
							 str(cushion)]).returncode
		try:
			g = json.load(open(os.path.join(p, "grade.json")))
		except (OSError, ValueError):
			sys.exit(f"{p}: no grade (cell exit {rc}); stopping")
		with open(os.path.join(root, "cells.jsonl"), "a") as f:
			f.write(json.dumps(g) + "\n")
		if g["clock"].get("ok"):
			return g
		print(f"{p}: clock outside criterion 1 ({g['clock']}); re-running", flush=True)
	sys.exit(f"{path}: clock failed three times; stopping")


def search(root, epoch, variant, start, step, lo, hi, reps):
	seq, tried = 0, {}

	def run(c):
		nonlocal seq
		seq += 1
		g = cell(root, epoch, variant, c, seq)
		tried.setdefault(c, []).append(g)
		print(f"e{epoch} {variant} c{c}: {'clean' if g['clean'] else 'FAIL'} "
			  f"lat {g['latency'].get('lat_median')} ms, window {g['groomer'].get('window')}, "
			  f"lost {g['receiver']['lost']}, p1p2 {g['wire'].get('p1p2_ok')}, tstd {g['tstd'].get('ok')}",
			  flush=True)
		return g["clean"]

	c = start
	if run(c):
		while c - step >= lo and run(c - step):
			c -= step
	else:
		while True:
			c += step
			if c > hi:
				return None, tried
			if run(c):
				break
	while c <= hi:
		while len(tried[c]) < reps and all(g["clean"] for g in tried[c]):
			run(c)
		if all(g["clean"] for g in tried[c]):
			return c, tried
		c += step
		while c <= hi and len(tried.get(c, [])) < reps:
			if not run(c):
				break
	return None, tried


def summarize(root):
	cells = [json.loads(line) for line in open(os.path.join(root, "cells.jsonl"))]
	floors = [json.loads(line) for line in open(os.path.join(root, "floors.jsonl"))] if os.path.exists(
		os.path.join(root, "floors.jsonl")) else []
	for f in floors:
		at = [g for g in cells if g["epoch_s"] == f["epoch_s"] and g["variant"] == f["variant"]
			  and g["lat_ms"] == f["floor_ms"] and g["clock"].get("ok")]
		lats = [g["latency"]["lat_median"] for g in at if "lat_median" in g["latency"]]
		f["median_latency_ms"] = round(statistics.median(lats), 1) if lats else None
		f["p1p2_all"] = all(g["wire"].get("p1p2_ok") for g in at)
		f["tstd_all"] = all(g["tstd"].get("ok") for g in at)
		print(json.dumps(f))
	print(f"{len(cells)} cells; P1/P2 failures on clean cells: "
		  f"{sum(1 for g in cells if g['clean'] and not g['wire'].get('p1p2_ok'))}; "
		  f"buffer-model failures on clean cells: {sum(1 for g in cells if g['clean'] and not g['tstd'].get('ok'))}")


def main():
	ap = argparse.ArgumentParser()
	sub = ap.add_subparsers(dest="cmd", required=True)
	r = sub.add_parser("run")
	r.add_argument("root")
	r.add_argument("--configs", default="2:design:3000,2:default:1500,1:design:1500,1:default:500")
	r.add_argument("--step", type=int, default=500)
	r.add_argument("--min", type=int, default=500)
	r.add_argument("--max", type=int, default=10000)
	r.add_argument("--reps", type=int, default=3)
	s = sub.add_parser("summarize")
	s.add_argument("root")
	a = ap.parse_args()
	if a.cmd == "summarize":
		return summarize(a.root)
	os.makedirs(a.root, exist_ok=True)
	for spec in a.configs.split(","):
		epoch, variant, start = spec.split(":")
		floor, tried = search(a.root, int(epoch), variant, int(start), a.step, a.min, a.max, a.reps)
		row = dict(epoch_s=int(epoch), variant=variant, floor_ms=floor,
				   steps={str(c): [g["clean"] for g in gs] for c, gs in sorted(tried.items())})
		with open(os.path.join(a.root, "floors.jsonl"), "a") as f:
			f.write(json.dumps(row) + "\n")
		print("FLOOR", json.dumps(row), flush=True)
	summarize(a.root)
	print("T70_DONE", flush=True)


if __name__ == "__main__":
	main()
