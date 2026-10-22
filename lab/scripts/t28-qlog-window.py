#!/usr/bin/env python3
"""Every packet the relay sent and received on the subscriber's connection around an outage.

Reads the same inputs as `t28-probe-timing.py` (the cell's `events.txt` and the relay's qlog, anchored
by its birth time) and prints, from `--from` to `--to` seconds after the outage's start, one line per
packet (direction, packet number, size) and one per change in the probe count or the smoothed RTT.
moq-quic's qlog logs no frames, so a probe is told from any other send by the `pto_count` it
follows: a probe timeout raises it before its probe goes out.

    t28-qlog-window.py <cell-dir> <qlog> [--from 0.1] [--to 8]
"""

from __future__ import annotations

import argparse
import importlib.util
from collections import Counter
from pathlib import Path

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("t28-probe-timing.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def main() -> None:
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("qlog")
	ap.add_argument("--from", dest="start", type=float, default=0.1)
	ap.add_argument("--to", dest="end", type=float, default=8.0)
	args = ap.parse_args()
	cell, qlog = Path(args.cell), Path(args.qlog)

	ev = dict(line.split() for line in (cell / "events.txt").read_text().splitlines() if line.strip())
	o0, o1 = int(ev["outage_start_ns"]), int(ev["outage_end_ns"])
	anchor = probe.birth_ns(qlog)
	all_events = list(probe.events(qlog))
	sends = Counter(e.get("group_id") for e in all_events if e["name"] == "quic:packet_sent")
	conn = sends.most_common(1)[0][0]
	lo, hi = o0 + int(args.start * 1e9), o0 + int(args.end * 1e9)
	print(f"outage {round((o1 - o0) / 1e9, 3)} s; times from its start")
	last = {}
	for e in all_events:
		if e.get("group_id") != conn:
			continue
		t = anchor + int(e["time"] * 1e6)
		name, data = e["name"], e.get("data", {})
		if name == "quic:recovery_metrics_updated":
			now = {k: data[k] for k in ("pto_count", "smoothed_rtt") if k in data}
			changed = {k: v for k, v in now.items() if last.get(k) != v}
			last.update(now)
			if changed and lo <= t <= hi:
				print(f"{(t - o0) / 1e9:8.3f} metrics {changed}")
			continue
		if not lo <= t <= hi or name not in ("quic:packet_sent", "quic:packet_received"):
			continue
		header = data.get("header", {})
		side = "sent" if name == "quic:packet_sent" else "recv"
		mark = " (after restore)" if t >= o1 else ""
		print(f"{(t - o0) / 1e9:8.3f} {side} pn={header.get('packet_number')} {header.get('length', '')}{mark}")


if __name__ == "__main__":
	main()
