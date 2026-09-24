#!/usr/bin/env python3
"""Pictures missing at window close, from the latency taps alone, conserved against a clean cell.

`t2831-conservation.py` needs each cell's capture. The matched ladder's taps (`t18-latency.py`)
log one row per video picture at the source (`src.csv`) and at the egress (`eg.csv`), and those
logs outlive the captures the rig deletes. Every cell of one invocation runs the same window, so

    missing (s) = ((src - eg) in the cell - (src - eg) in the clean cell) x mean picture interval

(the interval being the clean cell's egress PTS span over its picture count) counts the pictures
the source sent that the egress did not deliver by close, net of the join and in-flight offset the
clean cell carries. It is the capture-based `missing` measured on pictures
rather than on a PTS timeline: whether a picture arrived, not what was in it. Duplicates are
counted once. The resolution is the clean cells' spread in `src - eg`, stated in the output.

Layout: `t28-t31-srt-ladder.sh` -- `summary.csv` with `lane,budget_s,impair,rep` and
`<lane>-b<budget>-<impair>-<rep>/{src,eg}.csv`; the reference is the `none` cell of the same lane
and budget.

Usage: t2831-tap-conservation.py <arm-dir> [--csv out.csv]
"""

import argparse
import csv
import sys
from pathlib import Path


def pts(p: Path) -> list[int] | None:
	try:
		with open(p) as f:
			return sorted({int(r["pts"]) for r in csv.DictReader(f) if r.get("pts")})
	except (OSError, ValueError, KeyError):
		return None


def cell(d: Path) -> dict | None:
	s, e = pts(d / "src.csv"), pts(d / "eg.csv")
	if s is None or e is None or len(e) < 2:
		return None
	# Mean, not median: the picture rate is not uniform (~35/s against a 40 ms median step), and
	# a deficit counted in pictures converts to programme time at the average rate.
	span = e[-1] - e[0]
	return {"src": len(s), "eg": len(e), "dur": span / 90000 / (len(e) - 1) if 0 < span < 2**32 else None}


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("arm", type=Path)
	ap.add_argument("--csv", type=Path, default=None)
	args = ap.parse_args()

	rows = list(csv.DictReader(open(args.arm / "summary.csv")))
	out, refs = [], {}
	for r in rows:
		key = f"{r['lane']}-b{r['budget_s']}"
		label = f"{key}-{r['impair']}-{r['rep']}"
		if key not in refs:
			refs[key] = cell(args.arm / f"{key}-none-1")
		ref, c = refs[key], cell(args.arm / label)
		if ref is None or c is None or not ref["dur"]:
			out.append({"cell": label, "missing_s": "NA"})
			continue
		deficit = (c["src"] - c["eg"]) - (ref["src"] - ref["eg"])
		out.append({"cell": label, "src": c["src"], "eg": c["eg"], "deficit": deficit,
			"missing_s": round(deficit * ref["dur"], 2)})

	cols = ["cell", "src", "eg", "deficit", "missing_s"]
	print(" ".join(f"{c:>20}" for c in cols))
	for r in out:
		print(" ".join(f"{str(r.get(c, '')):>20}" for c in cols))
	offs = [refs[k]["src"] - refs[k]["eg"] for k in refs if refs[k]]
	if offs:
		print(f"clean-cell src-eg offsets: {offs}")
	if args.csv:
		with open(args.csv, "w", newline="") as f:
			w = csv.DictWriter(f, fieldnames=cols)
			w.writeheader()
			w.writerows(out)
	return 0


if __name__ == "__main__":
	sys.exit(main())
