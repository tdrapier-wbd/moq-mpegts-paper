#!/usr/bin/env python3
"""Recovery of an infrastructure-axis cell: T28 criteria 14 and 15.

Reads a cell of `t28-infra-axis.sh`: `size.log` (the capture's size every 0.5 s), `events.txt`
(the publisher's start, the kill, the restart), `content.json`, the taps, and the capture. Reports:

  pre_mbit      the median delivered rate in 4 s bins, sliding by 0.5 s, from 10 s after the
                publisher starts to the kill (to KILL_AT in a control); 4 s because both lanes'
                receivers write on cadences that put shorter bins of an unimpaired stream up to
                10 % below the median;
  first_byte_s  from the kill to the first byte after the output stalls (a 1 s bin under 5 % of
                pre_mbit within 20 s of it); 0 when it never stalls;
  stable_s      from the kill to the start of the first 30 s in which every 4 s bin delivers at
                least 95 % of pre_mbit and no continuity error falls; "no" if none starts within
                60 s (in a control, from 8 s);
  cc_after      continuity errors in the capture after the kill (adaptation-only packets and a
                single repeat excepted);
  latency       `t28-latency-return.py`'s test: back when the median 30-33 s after the restart is
                within 100 ms of the median before the kill.

    t28-infra-grade.py <cell-dir>... [--kill-at 30] [--json]
"""

from __future__ import annotations

import argparse
import bisect
import importlib.util
import json
import statistics
import sys
from pathlib import Path

BIN_S = 4.0

_spec = importlib.util.spec_from_file_location("latret", Path(__file__).with_name("t28-latency-return.py"))
latret = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(latret)


def cc_error_offsets(path: Path) -> list[int]:
	last: dict[int, tuple[int, bool]] = {}
	errs = []
	with open(path, "rb") as fh:
		off = 0
		while True:
			pkt = fh.read(188)
			if len(pkt) < 188:
				break
			if pkt[0] == 0x47:
				pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
				afc = (pkt[3] >> 4) & 0x3
				cc = pkt[3] & 0xF
				if pid != 0x1FFF and afc in (1, 3):
					if pid in last:
						prev, repeated = last[pid]
						if cc == prev and not repeated:
							last[pid] = (cc, True)
						elif cc != (prev + 1) & 0xF:
							errs.append(off)
							last[pid] = (cc, False)
						else:
							last[pid] = (cc, False)
					else:
						last[pid] = (cc, False)
			off += 188
	return errs


def grade(d: Path, kill_at: float) -> dict:
	res: dict = {"cell": d.name}
	ev: dict[str, float] = {}
	for line in (d / "events.txt").read_text().splitlines():
		f = line.split()
		if len(f) == 2 and f[1].isdigit():
			ev[f[0]] = int(f[1]) / 1e9
	pub0 = ev.get("publisher_start_ns")
	samples = []
	for line in (d / "size.log").read_text().splitlines():
		f = line.split()
		if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
			samples.append((int(f[0]) / 1e9, int(f[1])))
	if pub0 is None or len(samples) < 20:
		res["error"] = "no publisher start or size samples"
		return res
	ts = [t for t, _ in samples]

	def size_at(t: float) -> float:
		i = bisect.bisect_left(ts, t)
		if i <= 0:
			return samples[0][1]
		if i >= len(samples):
			return samples[-1][1]
		(t0, s0), (t1, s1) = samples[i - 1], samples[i]
		return s0 + (s1 - s0) * (t - t0) / (t1 - t0)

	def mbit(t: float, w: float = BIN_S) -> float:
		return (size_at(t + w) - size_at(t)) * 8 / 1e6 / w

	end = samples[-1][0]
	kill = ev.get("impair_start_ns")
	control = kill is None
	ref = pub0 + kill_at if control else kill
	pre = [mbit(t) for t in frange(pub0 + 10, ref - BIN_S, 0.5)]
	res["pre_mbit"] = round(statistics.median(pre), 2) if pre else None
	if not pre:
		res["error"] = "no bins before the kill"
		return res
	floor = 0.95 * res["pre_mbit"]
	cap = d / "out.ts"
	cc_times = []
	if cap.exists():
		sizes = [s for _, s in samples]
		for off in cc_error_offsets(cap):
			i = bisect.bisect_left(sizes, off)
			cc_times.append(samples[min(i, len(samples) - 1)][0])
		res["cc_after"] = sum(1 for t in cc_times if t >= ref)
	else:
		res["cc_after"] = "no capture"

	def stable_from(t0: float, limit: float):
		t = t0
		while t <= t0 + limit and t + 30 <= end:
			bad = next((b for b in frange(t, t + 30 - BIN_S, 0.5) if mbit(b) < floor), None)
			cc = next((c for c in cc_times if t <= c < t + 30), None)
			if bad is None and cc is None:
				return round(t - t0, 1)
			t = (bad + 0.5) if bad is not None else (cc + 0.5)
		return "no"

	if control:
		res["first_byte_s"] = 0.0
		res["stable_s"] = stable_from(pub0 + 8, 0)
	else:
		stall = next((t for t in frange(kill, kill + 20, 0.5) if mbit(t, 1.0) < 0.05 * res["pre_mbit"]), None)
		if stall is None:
			res["first_byte_s"] = 0.0
		else:
			resume = next((t for (t, s), (_, s0) in zip(samples[1:], samples) if t > stall and s > s0), None)
			res["first_byte_s"] = round(resume - kill, 2) if resume else "no"
		res["stable_s"] = stable_from(kill, 60)
	try:
		c = json.loads((d / "content.json").read_text())
		res["video_lost_s"], res["audio_lost_s"] = c.get("content_lost_s"), c.get("audio_lost_s")
	except (OSError, ValueError):
		res["video_lost_s"] = res["audio_lost_s"] = None
	lr = latret.grade(d, 8.0)
	res["lat_pre_ms"], res["lat_post30_ms"] = lr.get("pre_ms"), lr.get("post30_ms")
	res["latency"] = lr.get("verdict", lr.get("error"))
	for comp in ("publisher", "relay", "exporter"):
		p = d / f"{comp}.exits"
		res[f"exits_{comp}"] = len(p.read_text().splitlines()) if p.exists() else 0
	return res


def frange(a: float, b: float, step: float = 1.0):
	t = a
	while t <= b:
		yield t
		t += step


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("cells", nargs="+", type=Path)
	ap.add_argument("--kill-at", type=float, default=30.0)
	ap.add_argument("--json", action="store_true", help="write grade.json into each cell")
	args = ap.parse_args()
	for d in args.cells:
		r = grade(d, args.kill_at)
		if args.json:
			(d / "grade.json").write_text(json.dumps(r) + "\n")
		print("  ".join(f"{k}={v}" for k, v in r.items()))
	return 0


if __name__ == "__main__":
	sys.exit(main())
