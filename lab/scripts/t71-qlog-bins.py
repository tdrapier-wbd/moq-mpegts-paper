#!/usr/bin/env python3
"""The relay's QUIC sender through a T71 cell, in fixed bins: P1-ar's qlog diagnostic.

T71 impairs a whole cell, so there is no before or after to set against it, as `t28-qlog-shape.py`
does; a clean cell's bins are the reference instead. For the subscriber's connection (the one the
relay sends most on), per bin from its first packet: packets sent and the rate they carry, packets
declared lost (by reordering threshold and by time threshold), and the congestion window, pacing
rate and smoothed RTT in force every 100 ms (median and minimum; moq-quic logs a metric only when it
changes). The last line is the same over every whole bin.

    t71-qlog-bins.py <qlog> [--bin 10]
"""

from __future__ import annotations

import argparse
import bisect
import importlib.util
import statistics
from collections import Counter
from pathlib import Path

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("t28-probe-timing.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

FIELDS = ("congestion_window", "pacing_rate", "smoothed_rtt")
STEP_MS = 100.0


def main() -> None:
	ap = argparse.ArgumentParser()
	ap.add_argument("qlog")
	ap.add_argument("--bin", type=float, default=10.0, help="seconds")
	args = ap.parse_args()
	evs = list(probe.events(Path(args.qlog)))
	conn = Counter(e.get("group_id") for e in evs if e["name"] == "quic:packet_sent").most_common(1)[0][0]
	mine = [e for e in evs if e.get("group_id") == conn]
	sent_t = [e["time"] for e in mine if e["name"] == "quic:packet_sent"]
	t0, t_end = sent_t[0], sent_t[-1]
	series: dict[str, tuple[list[float], list[float]]] = {k: ([], []) for k in FIELDS}
	for e in mine:
		if e["name"] == "quic:recovery_metrics_updated":
			for k in FIELDS:
				if k in e["data"]:
					series[k][0].append(e["time"])
					series[k][1].append(float(e["data"][k]))

	def sample(k: str, lo: float, hi: float) -> list[float]:
		ts, vs = series[k]
		out, t = [], lo
		while t < hi:
			j = bisect.bisect_right(ts, t) - 1
			if j >= 0:
				out.append(vs[j])
			t += STEP_MS
		return out

	def row(lo: float, hi: float) -> str:
		sent = [e for e in mine if lo <= e["time"] < hi and e["name"] == "quic:packet_sent"]
		lost = [e for e in mine if lo <= e["time"] < hi and e["name"] == "quic:packet_lost"]
		size = sum((e["data"].get("header") or {}).get("length") or 0 for e in sent)
		by = Counter(e["data"].get("trigger") for e in lost)
		out = [
			f"{(lo - t0) / 1e3:6.0f}-{(hi - t0) / 1e3:<4.0f}s",
			f"sent {len(sent):6d} ({8 * size / ((hi - lo) / 1e3) / 1e6:5.2f} Mb/s)",
			f"lost {len(lost):5d} ({100 * len(lost) / len(sent) if sent else 0:5.2f} %; {dict(by)})",
		]
		for k in FIELDS:
			v = sample(k, lo, hi)
			if v:
				out.append(f"{k} {statistics.median(v):.6g} (min {min(v):.6g})")
		return "  ".join(out)

	step = args.bin * 1e3
	print(f"connection {conn}, {(t_end - t0) / 1e3:.1f} s of packets")
	lo = t0
	while lo + step <= t_end:
		print(row(lo, lo + step))
		lo += step
	print("all     " + row(t0, lo))


if __name__ == "__main__":
	main()
