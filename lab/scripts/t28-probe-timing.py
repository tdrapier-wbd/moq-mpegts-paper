#!/usr/bin/env python3
"""What the relay's QUIC sender did across an outage: T28 criterion 18, one cell of P1-y.

Reads the relay's qlog (`moq-server-<pid>-0.sqlog`, JSON-SEQ) beside the cell's outage stamps
(`events.txt`, host wall clock). moq-quic times events in milliseconds from the qlog stream's
creation, so the file's birth time (`stat -c %w`, the same host clock) anchors them. The connection
the relay sends most on is the subscriber's. Reported, in seconds from the outage's start or end:

- every packet the relay sent during the outage, grouped into probes (sends within 50 ms of each other);
- the wait from the link's return to the relay's next send, and to its first packet received;
- the largest probe count reached, and the congestion window before the outage, at its lowest from
  the outage's start until 5 s after its end, and when it first recovers to half its pre-outage value.

A window that falls to a handful of packets, not to half or less of its value, marks persistent
congestion: moq-quic logs no event of its own for it.

    t28-probe-timing.py <cell-dir> <qlog> [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def birth_ns(path: Path) -> int:
	text = subprocess.run(["stat", "-c", "%w", str(path)], check=True, capture_output=True, text=True).stdout.strip()
	stamp, frac, offset = text.partition(".")[0], text.split(".")[1].split()[0], text.split()[-1]
	if offset != "+0000":
		sys.exit(f"{path}: birth time not in UTC ({text})")
	whole = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
	return int(whole.timestamp()) * 1_000_000_000 + int(frac.ljust(9, "0")[:9])


def events(path: Path):
	with open(path, "rb") as fh:
		for raw in fh:
			line = raw.strip(b"\x1e \n\r")
			if line.startswith(b'{"time"'):
				yield json.loads(line)


def main() -> None:
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("qlog")
	ap.add_argument("--json")
	args = ap.parse_args()
	cell, qlog = Path(args.cell), Path(args.qlog)

	ev = dict(line.split() for line in (cell / "events.txt").read_text().splitlines() if line.strip())
	o0, o1 = int(ev["outage_start_ns"]), int(ev["outage_end_ns"])
	anchor = birth_ns(qlog)

	all_events = list(events(qlog))
	sends = Counter(e.get("group_id") for e in all_events if e["name"] == "quic:packet_sent")
	conn = sends.most_common(1)[0][0]
	mine = [(anchor + int(e["time"] * 1e6), e) for e in all_events if e.get("group_id") == conn]

	def rel(t: int, base: int) -> float:
		return round((t - base) / 1e9, 3)

	sent = [t for t, e in mine if e["name"] == "quic:packet_sent"]
	recv = [t for t, e in mine if e["name"] == "quic:packet_received"]
	during = [t for t in sent if o0 <= t < o1]
	probes: list[list[int]] = []
	for t in during:
		if probes and t - probes[-1][-1] <= 50_000_000:
			probes[-1].append(t)
		else:
			probes.append([t])
	next_send = next((t for t in sent if t >= o1), None)
	next_recv = next((t for t in recv if t >= o1), None)

	metrics = [(t, e["data"]) for t, e in mine if e["name"] == "quic:recovery_metrics_updated"]
	cwnd = [(t, d["congestion_window"]) for t, d in metrics if "congestion_window" in d]
	before = [w for t, w in cwnd if t < o0]
	window = [(t, w) for t, w in cwnd if o0 <= t <= o1 + 5_000_000_000]
	pre = before[-1] if before else None
	low = min(window, key=lambda tw: tw[1]) if window else None
	half = next((t for t, w in cwnd if t >= o1 and pre and w >= pre / 2), None)
	pto = max((d.get("pto_count", 0) for t, d in metrics if o0 <= t <= o1 + 5_000_000_000), default=0)

	res = {
		"cell": cell.name,
		"outage_s": rel(o1, o0),
		"probes_s": [rel(p[0], o0) for p in probes],
		"probe_packets": [len(p) for p in probes],
		"probe_gaps_s": [rel(b[0], a[0]) for a, b in zip(probes, probes[1:])],
		"next_send_after_restore_s": rel(next_send, o1) if next_send else None,
		"first_recv_after_restore_s": rel(next_recv, o1) if next_recv else None,
		"max_pto_count": pto,
		"cwnd_before": pre,
		"cwnd_low": low[1] if low else None,
		"cwnd_low_at_s": rel(low[0], o0) if low else None,
		"cwnd_half_back_after_restore_s": rel(half, o1) if half else None,
	}
	print(
		f"{res['cell']}: probes at {res['probes_s']} s (gaps {res['probe_gaps_s']}); next send "
		f"{res['next_send_after_restore_s']} s and first receive {res['first_recv_after_restore_s']} s "
		f"after restore; pto_count up to {pto}; cwnd {pre} -> {res['cwnd_low']} at "
		f"{res['cwnd_low_at_s']} s, half back {res['cwnd_half_back_after_restore_s']} s after restore"
	)
	if args.json:
		Path(args.json).write_text(json.dumps(res, indent=1) + "\n")


if __name__ == "__main__":
	main()
