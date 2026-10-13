#!/usr/bin/env python3
"""Whether a lane's delivery latency comes back after an impairment: T28 criterion 8.

Reads cells of the matched ladder (`t28-t31-srt-ladder.sh`): the source and egress taps (`src.csv`,
`eg.csv`: wall time and PTS per video PES, one host clock) and `events.txt`, which stamps the
impairment (`outage_start_ns`/`outage_end_ns`, or `impair_start_ns`/`impair_end_ns` for a sustained
shape run with `POST_S`). Each delivered picture's latency is its egress arrival less its source
time. The pre-fault median covers pictures published from `--settle-s` after the first delivered one
up to the impairment; the post median covers pictures *arriving* from 30 s to 33 s after it ends.
A cell is *back* when the two are within 100 ms. No picture in the post window is *not back*.

The export's late drops ("missed its deadline") are counted from `sub.log`, video and all tracks.

    t28-latency-return.py <cell-dir>... [--settle-s 8] [--csv out.csv]
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*m")
VIDEO = re.compile(r"track=\S*(avc|hev|h26)")
AFTER_S, SPAN_S, TOL_MS = 30.0, 3.0, 100.0


def read_tap(path: Path) -> list[tuple[int, int]]:
	rows = []
	with open(path) as fh:
		next(fh, None)
		for line in fh:
			t, _, p = line.strip().partition(",")
			if t and p:
				rows.append((int(t), int(p)))
	return rows


def grade(d: Path, settle_s: float) -> dict:
	res: dict = {"cell": d.name}
	try:
		src, eg = read_tap(d / "src.csv"), read_tap(d / "eg.csv")
	except OSError as e:
		res["error"] = f"tap missing: {e.filename}"
		return res
	if len(src) < 100 or len(eg) < 100:
		res["error"] = f"taps too short ({len(src)} source, {len(eg)} egress)"
		return res
	first_t: dict[int, int] = {}
	for t, p in src:
		first_t.setdefault(p, t)
	votes: dict[int, int] = {}
	for _, p in eg[:2000]:
		for k in range(-4, 5):
			if p + k in first_t:
				votes[k] = votes.get(k, 0) + 1
	if not votes:
		res["error"] = "no egress PTS within 4 ticks of a source PTS"
		return res
	k = max(votes, key=votes.get)
	lat = [(t, p + k, (t - first_t[p + k]) / 1e6) for t, p in eg if p + k in first_t]

	ev: dict[str, int] = {}
	if (d / "events.txt").exists():
		for line in open(d / "events.txt"):
			f = line.split()
			if len(f) >= 2:
				ev[f[0]] = int(f[1])
	start = ev.get("outage_start_ns", ev.get("impair_start_ns"))
	end = ev.get("outage_end_ns", ev.get("impair_end_ns"))
	pub0 = min(first_t[p] for _, p, _ in lat)
	lo = pub0 + int(settle_s * 1e9)
	if start is None or end is None:
		pre = [ms for _, p, ms in lat if first_t[p] >= lo]
		res["pre_ms"] = round(statistics.median(pre), 1) if pre else None
		res["verdict"] = "control"
	else:
		pre = [ms for _, p, ms in lat if lo <= first_t[p] < start]
		post = [ms for t, _, ms in lat if end + AFTER_S * 1e9 <= t < end + (AFTER_S + SPAN_S) * 1e9]
		res["pre_ms"] = round(statistics.median(pre), 1) if pre else None
		res["post30_ms"] = round(statistics.median(post), 1) if post else None
		res["post_pictures"] = len(post)
		if res["pre_ms"] is None or res["post30_ms"] is None:
			res["verdict"] = "not back"
		else:
			res["step_ms"] = round(res["post30_ms"] - res["pre_ms"], 1)
			res["verdict"] = "back" if abs(res["step_ms"]) <= TOL_MS else "not back"
		last = max(t for t, _ in eg)
		if last < end + (AFTER_S + SPAN_S) * 1e9:
			res["verdict"] += " (window short)"
	late_v = late_all = 0
	if (d / "sub.log").exists():
		for raw in open(d / "sub.log", errors="replace"):
			line = ANSI.sub("", raw)
			if "missed its deadline" in line:
				late_all += 1
				late_v += bool(VIDEO.search(line))
	res["late_video"], res["late_all"] = late_v, late_all
	return res


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("cells", nargs="+")
	ap.add_argument("--settle-s", type=float, default=8.0)
	ap.add_argument("--csv")
	a = ap.parse_args()
	keys = ("cell", "verdict", "pre_ms", "post30_ms", "step_ms", "post_pictures", "late_video", "late_all", "error")
	rows = [grade(Path(c), a.settle_s) for c in a.cells]
	for r in rows:
		print("  ".join(f"{k}={r[k]}" for k in keys if k in r))
	if a.csv:
		with open(a.csv, "w") as fh:
			fh.write(",".join(keys) + "\n")
			for r in rows:
				fh.write(",".join(str(r.get(k, "")) for k in keys) + "\n")
	return 0 if all("error" not in r for r in rows) else 1


if __name__ == "__main__":
	sys.exit(main())
