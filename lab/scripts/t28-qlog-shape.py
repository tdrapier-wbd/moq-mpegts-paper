#!/usr/bin/env python3
"""What the relay's QUIC sender did across a sustained shape: T28 criterion 28, P1-ar's qlog cell.

Reads the relay's qlog (`moq-server-<pid>-0.sqlog`), anchored by its birth time as
`t28-probe-timing.py` does, beside the cell's `impair_start_ns`/`impair_end_ns` (`events.txt`) and,
optionally, the media direction's qdisc drop counters sampled during the cell (`--tc`: lines of
`<unix ns> <kind>:<dropped> ...`, one field per qdisc on the device). For the subscriber's
connection (the one the relay sends most on) and each window, the 15 s before the shape, the shape,
and 5 s to 30 s after it: packets sent and the rate they carry, packets declared lost (by
reordering threshold and by time threshold), the drops each qdisc counted in the window, and the
congestion window, pacing rate, smoothed RTT and bytes in flight (median, min and max of the value in
force every 100 ms: moq-quic logs a metric only when it changes).

    t28-qlog-shape.py <cell-dir> <qlog> [--tc tc.log] [--json]
"""

from __future__ import annotations

import argparse
import bisect
import importlib.util
import json
import statistics
from collections import Counter
from pathlib import Path

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("t28-probe-timing.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

FIELDS = ("congestion_window", "pacing_rate", "smoothed_rtt", "bytes_in_flight")
STEP_NS = 100_000_000


def read_tc(path: Path) -> list[tuple[int, dict[str, int]]]:
	rows = []
	for line in path.read_text().splitlines():
		parts = line.split()
		if len(parts) < 2:
			continue
		counts: dict[str, int] = {}
		for f in parts[1:]:
			kind, _, n = f.partition(":")
			if n.isdigit():
				counts[kind] = counts.get(kind, 0) + int(n)
		rows.append((int(parts[0]), counts))
	return rows


def main() -> None:
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("qlog")
	ap.add_argument("--tc")
	ap.add_argument("--json", action="store_true")
	args = ap.parse_args()
	cell, qlog = Path(args.cell), Path(args.qlog)

	ev = dict(line.split()[:2] for line in (cell / "events.txt").read_text().splitlines() if line.strip())
	i0, i1 = int(ev["impair_start_ns"]), int(ev["impair_end_ns"])
	anchor = probe.birth_ns(qlog)
	evs = list(probe.events(qlog))
	conn = Counter(e.get("group_id") for e in evs if e["name"] == "quic:packet_sent").most_common(1)[0][0]
	mine = [(anchor + int(e["time"] * 1e6), e) for e in evs if e.get("group_id") == conn]
	tc = read_tc(Path(args.tc)) if args.tc else []
	tc_t = [t for t, _ in tc]

	def drops(lo: float, hi: float) -> dict[str, int] | None:
		a, b = bisect.bisect_right(tc_t, lo) - 1, bisect.bisect_right(tc_t, hi) - 1
		if a < 0 or b < 0:
			return None
		return {k: tc[b][1][k] - tc[a][1].get(k, 0) for k in tc[b][1]}

	series: dict[str, list[tuple[int, float]]] = {k: [] for k in FIELDS}
	for t, e in mine:
		if e["name"] == "quic:recovery_metrics_updated":
			for k in FIELDS:
				if k in e["data"]:
					series[k].append((t, e["data"][k]))

	def sample(k: str, lo: float, hi: float) -> list[float]:
		ts = [t for t, _ in series[k]]
		out, t = [], lo
		while t < hi:
			j = bisect.bisect_right(ts, t) - 1
			if j >= 0:
				out.append(series[k][j][1])
			t += STEP_NS
		return out

	def size(e: dict) -> int:
		return (e["data"].get("header") or {}).get("length") or 0

	windows = {"before": (i0 - 15e9, i0), "during": (i0, i1), "after": (i1 + 5e9, i1 + 30e9)}
	res: dict = {"connection": conn, "shape_s": round((i1 - i0) / 1e9, 1), "windows": {}}
	for name, (lo, hi) in windows.items():
		sent = [e for t, e in mine if lo <= t < hi and e["name"] == "quic:packet_sent"]
		lost = [e for t, e in mine if lo <= t < hi and e["name"] == "quic:packet_lost"]
		w: dict = {
			"seconds": round((hi - lo) / 1e9, 1),
			"sent": len(sent),
			"sent_mbps": round(8 * sum(size(e) for e in sent) / ((hi - lo) / 1e9) / 1e6, 2),
			"lost": len(lost),
			"lost_pct": round(100 * len(lost) / len(sent), 2) if sent else None,
			"lost_by": dict(Counter(e["data"].get("trigger") for e in lost)),
			"qdisc_dropped": drops(lo, hi),
		}
		for k in FIELDS:
			v = sample(k, lo, hi)
			if v:
				w[k] = {"median": statistics.median(v), "min": min(v), "max": max(v)}
		res["windows"][name] = w
	b, d = res["windows"]["before"], res["windows"]["during"]
	if "congestion_window" in b and "congestion_window" in d:
		res["cwnd_during_min_over_before_median"] = round(
			d["congestion_window"]["min"] / b["congestion_window"]["median"], 4
		)
	if args.json:
		print(json.dumps(res, indent=1))
		return
	print(f"connection {conn}, shape {res['shape_s']} s")
	for name, w in res["windows"].items():
		m = "; ".join(
			f"{k} {w[k]['median']:.6g} ({w[k]['min']:.6g}-{w[k]['max']:.6g})" for k in FIELDS if k in w
		)
		print(
			f"{name:6} {w['seconds']:4.0f} s: sent {w['sent']} ({w['sent_mbps']} Mb/s), lost {w['lost']} "
			f"({w['lost_pct']} %, {w['lost_by']}), qdisc drops {w['qdisc_dropped']}; {m}"
		)
	if "cwnd_during_min_over_before_median" in res:
		print(f"window during the shape at its lowest / before: {res['cwnd_during_min_over_before_median']}")


if __name__ == "__main__":
	main()
