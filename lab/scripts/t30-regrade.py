#!/usr/bin/env python3
"""Add the outage columns a PTS grader cannot see to T30 runs.

`t28-content-lost.py` scores holes *inside* a capture; a receiver that stops advancing and never
recovers before the run ends leaves no hole, only a capture that stops early. Per run directory this
reads the receiver's input growth (`sizes.csv`, raw bytes per second) and the groomer's closing line:

  raw_max_stall_s   longest run of seconds with no new input after the first byte; a healthy
                    2 s segment cadence shows 1-2
  raw_tail_stall_s  seconds at the end of the run with no new input, less the 2 s cadence
  muted_s           groomer output muted for want of input (muted packets at the mux rate)
  max_gap_s         the groomer's longest stretch without content, including the end-of-input drain

Usage:
    t30-regrade.py RUN_DIR... [--rate 11438000] [--window START END]
--window also reports raw_max_stall_s inside [START, END] seconds after the receiver started.
"""

import argparse
import csv
import re
from pathlib import Path


def stalls(rows: list[tuple[int, int]], lo: int | None = None, hi: int | None = None) -> tuple[int, int]:
	started = False
	run = best = 0
	prev = 0
	for t, b in rows:
		grew = b > prev
		prev = b
		if not started:
			started = grew
			continue
		if lo is not None and not (lo <= t <= hi):
			run = 0
			continue
		run = 0 if grew else run + 1
		best = max(best, run)
	tail = 0
	for t, b in reversed(rows):
		if b == rows[-1][1]:
			tail += 1
		else:
			break
	return best, max(0, tail - 1 - 2)


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("runs", nargs="+", type=Path)
	ap.add_argument("--rate", type=float, default=11438000)
	ap.add_argument("--window", nargs=2, type=int)
	args = ap.parse_args()
	for d in args.runs:
		rows = []
		with open(d / "sizes.csv") as f:
			for r in csv.DictReader(f):
				rows.append((int(r["t"]), int(r["raw_bytes"])))
		best, tail = stalls(rows)
		line = f"{d.name}: raw_max_stall_s={best} raw_tail_stall_s={tail}"
		if args.window:
			w, _ = stalls(rows, *args.window)
			line += f" window_max_stall_s={w}"
		pacer = (d / "pacer.log").read_text() if (d / "pacer.log").exists() else ""
		m = re.search(r"done\..*?muted=(\d+).*?max_content_gap=(\d+)", pacer)
		if m:
			line += f" muted_s={int(m.group(1)) * 188 * 8 / args.rate:.1f} max_gap_s={int(m.group(2)) / 1000:.1f}"
		print(line)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
