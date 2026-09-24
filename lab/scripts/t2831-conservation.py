#!/usr/bin/env python3
"""Programme missing at window close, conserved against a clean cell of the same run.

`t28-content-lost.py` measures holes between pictures that arrived. A lane whose picture stops
before the window closes -- a session that dies, a subscriber evicting every group -- leaves no
hole after the last picture, and grades clean. The ladders know how long each window was, so the
content that should be there is known too: a clean cell of the same run gives the offset from
window start to first graded picture, and every other cell is expected to advance its window's
length less that offset.

    missing (s)  = expected advance - content present
    short (s)    = expected advance - timeline advance      (the part the hole count cannot see)

`short` counts content not delivered by window close, so it includes the lane's residual lag as
well as loss; a figure within the lane's latency budget may be late rather than lost. The
resolution is the spread of join offsets between runs, about +/-1 s on the ladders; clean cells
read 0.0-0.9 s.

Two layouts are read:

* `t28-t31-moq-ladder.sh`: `summary.csv` with `cell` and `window_s`, `<cell>.content.json`;
  the reference is the `control` cell.
* `t28-t31-srt-ladder.sh`: `summary.csv` with `lane,budget_s,impair,rep`, and
  `<lane>-b<budget>-<impair>-<rep>/content.json`; every cell shares one window, and the reference
  is the `none` cell of the same lane and budget (of the same replicate where one was run).

Audio is conserved the same way where the content JSON carries `audio_present_s`.

Usage: t2831-conservation.py <arm-dir> [--from-s 8] [--csv out.csv]
"""

import argparse
import csv
import json
import sys
from pathlib import Path


def load(p: Path) -> dict | None:
	try:
		return json.loads(p.read_text())
	except (OSError, ValueError):
		return None


def row(label: str, j: dict | None, expect: float | None, aexpect: float | None) -> dict:
	if j is None or expect is None:
		return {"cell": label, "missing_s": "NA"}
	r = {
		"cell": label,
		"holes_lost_s": j["content_lost_s"],
		"short_s": round(expect - j["timeline_advance_s"], 2),
		"missing_s": round(expect - j["content_present_s"], 2),
	}
	if "audio_present_s" in j and aexpect is not None:
		r["audio_missing_s"] = round(aexpect - j["audio_present_s"], 2)
	return r


def ladder(arm: Path, rows: list[dict], from_s: float) -> list[dict]:
	ref = load(arm / "control.content.json")
	win = {r["cell"]: float(r["window_s"]) for r in rows}
	if ref is None or "control" not in win:
		sys.exit("no control cell to conserve against")
	off = win["control"] - from_s - ref["timeline_advance_s"]
	aoff = win["control"] - from_s - ref["audio_advance_s"] if "audio_advance_s" in ref else None
	out = []
	for cell, w in win.items():
		exp = w - from_s - off
		aexp = w - from_s - aoff if aoff is not None else None
		out.append(row(cell, load(arm / f"{cell}.content.json"), exp, aexp))
	return out


def matched(arm: Path, rows: list[dict]) -> list[dict]:
	out = []
	for r in rows:
		key = f"{r['lane']}-b{r['budget_s']}"
		# The matched ladder runs one control per budget, not one per replicate.
		ref = load(arm / f"{key}-none-{r['rep']}" / "content.json") or load(arm / f"{key}-none-1" / "content.json")
		j = load(arm / f"{key}-{r['impair']}-{r['rep']}" / "content.json")
		exp = ref["timeline_advance_s"] if ref else None
		aexp = ref.get("audio_advance_s") if ref else None
		out.append(row(f"{key}-{r['impair']}-{r['rep']}", j, exp, aexp))
	return out


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("arm", type=Path)
	ap.add_argument("--from-s", type=float, default=8.0, help="the --from-s the cells were graded with")
	ap.add_argument("--csv", type=Path, default=None)
	args = ap.parse_args()

	rows = list(csv.DictReader(open(args.arm / "summary.csv")))
	out = ladder(args.arm, rows, args.from_s) if rows and "cell" in rows[0] else matched(args.arm, rows)

	cols = ["cell", "holes_lost_s", "short_s", "missing_s", "audio_missing_s"]
	print(" ".join(f"{c:>16}" for c in cols))
	for r in out:
		print(" ".join(f"{str(r.get(c, '')):>16}" for c in cols))
	if args.csv:
		with open(args.csv, "w", newline="") as f:
			w = csv.DictWriter(f, fieldnames=cols)
			w.writeheader()
			w.writerows(out)
	return 0


if __name__ == "__main__":
	sys.exit(main())
