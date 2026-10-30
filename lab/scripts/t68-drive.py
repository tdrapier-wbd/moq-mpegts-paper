#!/usr/bin/env python3
"""Run T68's parts B and C as fixed in the test file, one t68-seg-pair.sh run at a time.

Part B, per variant: a run at 8 s (in the design variant, criterion 1's control: a failure stops
part B); then up to three runs at 1 s, stopping at the first failure. Three passes step down to
0.5 s the same way. A failure at 1 s bisects 1-8 s in 0.5 s steps, one run per step, then confirms
the minimum with three runs (stepping up 0.5 s while a confirmation fails) and records one run
0.5 s below it.

Part C, in the design variant: three runs at 8 s with chain A's playlist frozen for 10 s, 1.9 s
after a listing, then 0.5 s steps upward until three runs of three lose no video on chain A.

Every run's grade is one line of <outroot>/summary.jsonl, with the criterion's verdict.

Usage: t68-drive.py <outroot> [--parts B,C] [--variants design,default] [--scripts DIR]
"""

import argparse
import json
import math
import os
import subprocess
import sys

VARIANTS = {
	"design": dict(HOLD_MS="1500", ALIGN_MS="30000", WINDOW="150"),
	"default": dict(WINDOW="120"),
}
FREEZE = dict(FREEZE_AT="70", FREEZE_S="10", FREEZE_PHASE="1.9")


class Driver:
	def __init__(self, root, scripts):
		self.root, self.scripts, self.n = root, scripts, {}
		os.makedirs(root, exist_ok=True)
		self.summary = open(os.path.join(root, "summary.jsonl"), "a", buffering=1)

	def run(self, part, variant, lat_s, extra=None):
		key = (part, variant, lat_s)
		self.n[key] = self.n.get(key, 0) + 1
		out = os.path.join(self.root, f"{part}-{variant}-{lat_s:g}-{self.n[key]}")
		env = dict(os.environ, LAT_MS=str(int(lat_s * 1000)), **VARIANTS[variant], **(extra or {}))
		with open(out + ".out", "w") as log:
			rc = subprocess.run(["bash", os.path.join(self.scripts, "t68-seg-pair.sh"), out], env=env,
								stdout=log, stderr=subprocess.STDOUT).returncode
		if rc != 0:
			self.summary.write(json.dumps(dict(run=os.path.basename(out), error=f"rig rc={rc}")) + "\n")
			sys.exit(f"rig failed: {out}")
		g = json.loads(subprocess.run([sys.executable, os.path.join(self.scripts, "t68-grade.py"), out],
									capture_output=True, text=True, check=True).stdout)
		g.update(part=part, variant=variant, lat_s=lat_s)
		g["pass"] = self.verdict(part, g)
		self.summary.write(json.dumps(g) + "\n")
		print(f"{g['run']}: pass={g['pass']}", flush=True)
		return g["pass"]

	@staticmethod
	def clean(leg):
		return "steady" in leg and not any(leg["steady"].values())

	def verdict(self, part, g):
		if part == "B":
			i = g.get("identity", {})
			return (i.get("identical_pct") == 100.0 and i.get("residue") == 0
					and self.clean(g["a"]) and self.clean(g["b"]))
		b_ok = g["b"]["content"]["content_lost_s"] == 0 and self.clean(g["b"])
		return b_ok and g["a"]["content"]["content_lost_s"] == 0

	def up_to_three(self, part, variant, lat_s, extra=None):
		return all(self.run(part, variant, lat_s, extra) for _ in range(3))

	def part_b(self, variant):
		if not self.run("B", variant, 8.0) and variant == "design":
			sys.exit("criterion 1 fails: the rig is faulty, part B stops")
		if self.up_to_three("B", variant, 1.0):
			self.up_to_three("B", variant, 0.5)
			return
		lo, hi = 1.0, 8.0
		while hi - lo > 0.5:
			mid = math.ceil((lo + hi)) / 2
			if mid >= hi:
				mid = hi - 0.5
			if self.run("B", variant, mid):
				hi = mid
			else:
				lo = mid
		while hi <= 8.0 and not self.up_to_three("B", variant, hi):
			hi += 0.5
		if hi - 0.5 > 1.0:
			self.run("B", variant, hi - 0.5)

	def part_c(self):
		for _ in range(3):
			self.run("C", "design", 8.0, FREEZE)
		lat = 8.5
		while lat <= 12.0 and not self.up_to_three("C", "design", lat, FREEZE):
			lat += 0.5


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("outroot")
	ap.add_argument("--parts", default="B,C")
	ap.add_argument("--variants", default="design,default")
	ap.add_argument("--scripts", default=os.path.dirname(os.path.abspath(__file__)))
	a = ap.parse_args()
	d = Driver(a.outroot, a.scripts)
	if "B" in a.parts.split(","):
		for v in a.variants.split(","):
			d.part_b(v)
	if "C" in a.parts.split(","):
		d.part_c()


if __name__ == "__main__":
	main()
