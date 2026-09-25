#!/usr/bin/env python3
"""Loss and rate summary of a relay's qlog traces, per connection, on noq or quinn.

T28's reorder arms ask what the relay's sender does when packets arrive out of order: how many it
declares lost and by which rule, how many of those the peer acknowledges afterwards (a spurious
loss), and what the controller does to its window and pacing rate. This reads the JSON-SEQ traces
both backends write -- noq one file per connection, quinn one file per endpoint with a `group_id` on
every event -- and reports, for each connection that sent at least MIN_SENT packets:

    sent             packets sent
    lost             packets declared lost, by trigger where the trace names one
    lost_then_acked  of those, how many a later ACK frame covers (noq only; quinn logs no frames)
    first_loss_s     seconds from the connection's first event to its first declared loss
    cwnd / pacing / srtt  medians before and after --impair-at-s, in the trace's own units

`--impair-at-s` is measured from each connection's first event; the matched ladder's impairment
starts about SETTLE (20 s) after the subscriber connects.

Usage: t2831-qlog-summary.py <qlog-dir-or-file> ... [--impair-at-s 22] [--min-sent 5000]
"""

import argparse
import collections
import json
import statistics
import sys
from pathlib import Path


def records(path: Path):
	data = path.read_bytes()
	for chunk in data.split(b"\x1e"):
		chunk = chunk.strip()
		if not chunk:
			continue
		for line in chunk.splitlines():
			try:
				yield json.loads(line)
			except ValueError:
				continue


class Conn:
	def __init__(self):
		self.t0 = None
		self.sent = 0
		self.lost = []  # (time_ms, packet_number, trigger)
		self.acked = []  # (lo, hi) ranges
		self.metrics = []  # (time_ms, cwnd, pacing, srtt), carried forward
		self._last = {"congestion_window": None, "pacing_rate": None, "smoothed_rtt": None}


def ingest(path: Path, conns: dict) -> None:
	file_group = None
	for r in records(path):
		if "trace" in r and "name" not in r:
			file_group = r["trace"].get("common_fields", {}).get("group_id")
			continue
		name = r.get("name", "")
		t = r.get("time")
		if t is None:
			continue
		gid = r.get("group_id") or file_group or path.name
		c = conns.setdefault(gid, Conn())
		c.t0 = t if c.t0 is None else min(c.t0, t)
		d = r.get("data", {})
		if name.endswith("packet_sent"):
			c.sent += 1
		elif name.endswith("packet_lost"):
			c.lost.append((t, d.get("header", {}).get("packet_number"), d.get("trigger", "unnamed")))
		elif name.endswith("packet_received"):
			for f in d.get("frames", []) or []:
				if f.get("frame_type") == "ack":
					for rng in f.get("acked_ranges", []) or []:
						lo = rng[0]
						hi = rng[1] if len(rng) > 1 else rng[0]
						c.acked.append((lo, hi))
		elif name.endswith("metrics_updated"):
			changed = False
			for k in c._last:
				if k in d:
					c._last[k] = d[k]
					changed = True
			if changed:
				c.metrics.append((t, c._last["congestion_window"], c._last["pacing_rate"], c._last["smoothed_rtt"]))


def covered(pn, ranges) -> bool:
	return any(lo <= pn <= hi for lo, hi in ranges)


def med(vals):
	vals = [v for v in vals if v is not None]
	return round(statistics.median(vals), 1) if vals else "NA"


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("paths", nargs="+", type=Path)
	ap.add_argument("--impair-at-s", type=float, default=22.0)
	ap.add_argument("--min-sent", type=int, default=5000)
	args = ap.parse_args()

	files = []
	for p in args.paths:
		files += sorted(p.glob("*.qlog")) + sorted(p.glob("*.sqlog")) if p.is_dir() else [p]
	conns: dict = {}
	for f in files:
		ingest(f, conns)

	for gid, c in conns.items():
		if c.sent < args.min_sent:
			continue
		# Merge ranges once; a lost packet is spurious if any later ACK covers it.
		ranges = sorted(c.acked)
		merged = []
		for lo, hi in ranges:
			if merged and lo <= merged[-1][1] + 1:
				merged[-1][1] = max(merged[-1][1], hi)
			else:
				merged.append([lo, hi])
		triggers = collections.Counter(tr for _, _, tr in c.lost)
		acked = sum(1 for _, pn, _ in c.lost if pn is not None and covered(pn, merged)) if merged else "n/a"
		cut = c.t0 + args.impair_at_s * 1000
		before = [m for m in c.metrics if c.t0 + 5000 <= m[0] < cut]
		after = [m for m in c.metrics if m[0] >= cut]
		first = round((min(t for t, _, _ in c.lost) - c.t0) / 1000, 1) if c.lost else "NA"
		print(f"connection {gid[:16]}: sent {c.sent}, lost {len(c.lost)} {dict(triggers)}, "
			f"lost_then_acked {acked}, first_loss_s {first}")
		for label, ms in (("before", before), ("after", after)):
			print(f"  {label:6} cwnd {med([m[1] for m in ms])}  pacing {med([m[2] for m in ms])}  "
				f"srtt {med([m[3] for m in ms])}  ({len(ms)} samples)")
	return 0


if __name__ == "__main__":
	sys.exit(main())
