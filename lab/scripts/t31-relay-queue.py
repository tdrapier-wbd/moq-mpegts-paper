#!/usr/bin/env python3
"""The relay's per-subscriber queue across a transient, from its qlog: T31 criterion 8.

Reads cells of `t31-delay-matrix.sh` run with RELAY_QLOG=1 and the subscribers at debug
(SUB_RUST_LOG). noq writes one trace per connection, named with the connection's start in Unix
milliseconds, and times its events in milliseconds from it. A connection that receives stream data
is a publisher's, one that sends it a subscriber's.

Per subscriber connection:

  queue      what its publisher has delivered to the relay, less what the relay has sent it (stream
             bytes past the highest offset already sent on each stream) and what it has abandoned,
             every 0.1 s, in seconds at the stream's rate (STREAM_MBIT, 9.95);
  abandoned  for each group stream the relay reset, the publisher's size of that group less what
             the relay had sent of it; a publisher group the relay never opened counts whole. Media
             abandoned is each video group's unsent share of its duration, a group's duration being
             the gap to the next video group's arrival at the relay;
  skips      the consumer's own skips (`skipping slow groups`), each with what the relay still held
             of the skipped group when the subscriber logged it. The line names no track; it is
             read as the video track's, whose group numbers the relay's resets share.

Video groups are the streams over 200 kB, and a subscriber stream carries the latest publisher
group to reach the relay by its first byte that is at least its size. A subscriber connection is
matched to its `sub.<i>.log` by its `old` resets against the log's `group error err=old` lines, and
to its publisher by bytes; with nothing to go by, both follow start order (both feeds carry one
clip from one instant). The dip is read from `events.txt`; a control cell takes the same instant,
DIP_AT s after the publishers connect.

    t31-relay-queue.py <cell-dir>... [--csv out.csv] [--dip-at 30] [--dip-s 5]
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import statistics
import sys
from pathlib import Path

WT_BASE = 0x52E4A40FA8DB  # WebTransport's first application error code in HTTP/3's space
CODES = {0x0: "cancel", 0x1: "cancel", 0x34: "old", 0x35: "evicted"}
BIG = 200_000
ANSI = re.compile(r"\x1b\[[0-9;]*m")
STREAM_MBIT = 9.95


def wt_code(h3: int) -> int:
	d = h3 - WT_BASE
	return d - d // 0x1F if d >= 0 else h3


def records(path: Path):
	for chunk in path.read_bytes().split(b"\x1e"):
		chunk = chunk.strip()
		if chunk:
			try:
				yield json.loads(chunk)
			except ValueError:
				continue


class Conn:
	def __init__(self, path: Path):
		self.path = path
		self.t0 = int(re.search(r"-(\d{13})-", path.name).group(1)) / 1000
		self.rx: dict[int, dict] = {}  # stream -> {first, max, fin}
		self.tx: dict[int, dict] = {}
		self.rx_events: list[tuple[float, int, int]] = []  # (t, new bytes, stream)
		self.tx_events: list[tuple[float, int, int]] = []
		self.resets: list[tuple[float, int, str, int, int]] = []  # (t, stream, code, final, sent)
		self.cwnd: list[tuple[float, float, float]] = []  # (t, cwnd, in flight)
		last = {"congestion_window": None, "bytes_in_flight": None}
		for r in records(path):
			name = r.get("name", "")
			t = r.get("time")
			if t is None:
				continue
			t = self.t0 + t / 1000
			d = r.get("data") or {}
			if name.endswith("metrics_updated"):
				hit = False
				for k in last:
					if k in d:
						last[k] = d[k]
						hit = True
				if hit:
					self.cwnd.append((t, last["congestion_window"], last["bytes_in_flight"]))
				continue
			if not name.endswith(("packet_sent", "packet_received")):
				continue
			sent = name.endswith("sent")
			table, events = (self.tx, self.tx_events) if sent else (self.rx, self.rx_events)
			for f in d.get("frames") or []:
				kind = f.get("frame_type")
				if kind == "stream":
					s = table.setdefault(f["stream_id"], {"first": t, "max": 0, "fin": None})
					end = f.get("offset", 0) + f["raw"]["length"]
					if end > s["max"]:
						events.append((t, end - s["max"], f["stream_id"]))
						s["max"] = end
					if f.get("fin"):
						s["fin"] = t
				elif kind == "reset_stream" and sent:
					sid = f["stream_id"]
					code = wt_code(f["error_code"])
					sent = self.tx.get(sid, {}).get("max", 0)
					self.resets.append((t, sid, CODES.get(code, hex(code)), f["final_size"], sent))
		self.rx_bytes = sum(s["max"] for s in self.rx.values())
		self.tx_bytes = sum(s["max"] for s in self.tx.values())

	def big(self, table) -> list[tuple[float, int, int]]:
		return sorted((s["first"], s["max"], sid) for sid, s in table.items() if s["max"] > BIG)


def cumulative(events, grid):
	events = sorted(e[:2] for e in events)
	out, total, i = [], 0, 0
	for t in grid:
		while i < len(events) and events[i][0] <= t:
			total += events[i][1]
			i += 1
		out.append(total)
	return out


def group_of(pbig, first: float, floor: int):
	"""The publisher's video group a subscriber stream opened at `first` carries: the latest to
	reach the relay by then whose size is at least `floor`."""
	fits = [g for g in pbig if g[0] <= first + 0.05 and g[1] >= floor]
	return fits[-1] if fits else None


def log_lines(path: Path, pattern: str):
	out = []
	try:
		text = ANSI.sub("", path.read_text(errors="replace"))
	except OSError:
		return out
	for line in text.splitlines():
		if pattern in line:
			ts = datetime.datetime.strptime(line[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc)
			out.append((ts.timestamp(), line))
	return out


def grade(d: Path, dip_at: float, dip_s: float) -> list[dict]:
	conns = [Conn(p) for p in sorted((d / "qlog").glob("*.qlog"))]
	pubs = sorted((c for c in conns if c.rx_bytes > c.tx_bytes), key=lambda c: c.t0)
	subs = sorted((c for c in conns if c.tx_bytes >= c.rx_bytes), key=lambda c: c.t0)
	ev = {}
	for line in (d / "events.txt").read_text().splitlines():
		k, _, v = line.partition(" ")
		ev[k] = int(v) / 1e9
	start = ev.get("impair_start_ns", pubs[0].t0 + dip_at if pubs else 0)
	end = ev.get("impair_end_ns", start + dip_s)
	n = len(subs)
	logs = {i: log_lines(d / f"sub.{i}.log", "group error err=old") for i in range(1, n + 1)}

	# Match subscriber connections to their logs by `old` resets, else keep start order.
	def score(conn, i):
		return sum(1 for t, *_ in conn.resets for lt, _ in logs[i] if 0 <= lt - t <= 0.5)

	order = list(range(1, n + 1))
	if n == 2 and score(subs[0], 2) + score(subs[1], 1) > score(subs[0], 1) + score(subs[1], 2):
		order = [2, 1]

	# Publishers by the bytes each subscriber's connection accounts for, reset remainders included.
	def gap(p, c):
		return abs(p.rx_bytes - c.tx_bytes - sum(r[3] - r[4] for r in c.resets))

	paired = list(pubs)
	crossed = gap(pubs[1], subs[0]) + gap(pubs[0], subs[1]) if len(pubs) == 2 and n == 2 else None
	if crossed is not None and crossed < gap(pubs[0], subs[0]) + gap(pubs[1], subs[1]):
		paired = [pubs[1], pubs[0]]
	rows = []
	for k, (conn, i) in enumerate(zip(subs, order)):
		pub = paired[k] if k < len(paired) else None
		pbig = pub.big(pub.rx) if pub else []
		dur = {g[2]: (pbig[k + 1][0] - g[0] if k + 1 < len(pbig) else 0) for k, g in enumerate(pbig)}
		abandoned_ev, media, groups = [], 0.0, []
		for t, sid, code, final, sent in conn.resets:
			g = group_of(pbig, conn.tx.get(sid, {}).get("first", t), final) if final > BIG else None
			size = g[1] if g else final
			unsent = max(size - sent, 0)
			abandoned_ev.append((t, unsent))
			if g:
				share = unsent / size * dur[g[2]]
				media += share
				groups.append(f"{code}@{t - start:+.2f}s:{unsent // 1000}kB/{share:.2f}s")
		opened = {group_of(pbig, s["first"], s["max"]) for s in conn.tx.values() if s["max"] > BIG}
		opened |= {group_of(pbig, conn.tx.get(r[1], {}).get("first", r[0]), r[3]) for r in conn.resets if r[3] > BIG}
		last_t = max((e[0] for e in conn.tx_events), default=0)
		never = [g for g in pbig if g not in opened and conn.t0 < g[0] < last_t - 5]
		for g in never:
			abandoned_ev.append((g[0] + 3.0, g[1]))
			media += dur[g[2]]
		# Queue on a 0.1 s grid from the publisher's connection.
		t_a = pub.t0 if pub else conn.t0
		grid = [t_a + k / 10 for k in range(int((last_t - t_a) * 10))]
		rx = cumulative(pub.rx_events, grid) if pub else [0] * len(grid)
		tx = cumulative(conn.tx_events, grid)
		ab = cumulative(abandoned_ev, grid)
		rate = STREAM_MBIT * 1e6 / 8
		q = [(t, (r - s - a) / rate) for t, r, s, a in zip(grid, rx, tx, ab)]
		pre = [v for t, v in q if t_a + 10 <= t < start]
		pre_med = statistics.median(pre) if pre else float("nan")
		after = [(t, v) for t, v in q if start <= t <= end + 30]
		peak_t, peak = max(after, key=lambda x: x[1]) if after else (start, float("nan"))
		back = next((t for t, v in after if t >= peak_t and v <= pre_med * 1.1), None)
		cw_pre = [c for t, c, _ in conn.cwnd if t_a + 10 <= t < start and c]
		cw_dip = [c for t, c, _ in conn.cwnd if start <= t <= end and c]
		fl_peak = max((f for t, _, f in conn.cwnd if start <= t <= end + 30 and f), default=0)
		# The consumer's own skips, and what the relay still held of the video group skipped.
		skips = []
		for lt, line in log_lines(d / f"sub.{i}.log", "skipping slow groups"):
			m = re.search(r"old=(\d+)", line)
			held = "?"
			if m and int(m.group(1)) < len(pbig):
				g = pbig[int(m.group(1))]
				sid = next(
					(sid for sid, s in conn.tx.items() if s["max"] > BIG and group_of(pbig, s["first"], s["max"]) == g),
					None,
				)
				if sid is None:
					held = "unopened"
				else:
					sent = sum(b for t, b, s in conn.tx_events if s == sid and t <= lt)
					held = f"{(g[1] - sent) // 1000}kB"
			skips.append(f"g{m.group(1) if m else '?'}@{lt - start:+.2f}s:held={held}")
		content = {}
		try:
			content = json.loads((d / f"content.{i}.json").read_text())
		except (OSError, ValueError):
			pass
		lost = content.get("content_lost_s")
		rows.append({
			"cell": d.name, "sub": i, "video_lost_s": lost,
			"abandoned_media_s": round(media, 3), "resets": len(conn.resets), "never_opened": len(never),
			"reset_groups": " ".join(groups) or "-", "skips": " ".join(skips) or "-",
			"q_pre_s": round(pre_med, 4), "q_peak_s": round(peak, 3), "q_peak_at_s": round(peak_t - start, 2),
			"q_back_s": round(back - end, 2) if back else "no",
			"q_end_s": round(statistics.median([v for t, v in q if t >= last_t - 5]), 4) if q else "NA",
			"cwnd_pre": round(statistics.median(cw_pre)) if cw_pre else "NA",
			"cwnd_dip_min": round(min(cw_dip)) if cw_dip else "NA", "inflight_peak": round(fl_peak),
			"pub_bytes": pub.rx_bytes if pub else 0, "sub_bytes": conn.tx_bytes,
			"abandoned_bytes": sum(b for _, b in abandoned_ev),
			"pairing_pct": round(
				100 * abs((pub.rx_bytes if pub else 0) - conn.tx_bytes - sum(b for _, b in abandoned_ev))
				/ max(conn.tx_bytes, 1),
				3,
			),
		})
	return rows


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("cells", nargs="+", type=Path)
	ap.add_argument("--csv", type=Path)
	ap.add_argument("--dip-at", type=float, default=30.0)
	ap.add_argument("--dip-s", type=float, default=5.0)
	args = ap.parse_args()
	rows = []
	for d in args.cells:
		rows += grade(d, args.dip_at, args.dip_s)
	if not rows:
		return 1
	keys = list(rows[0])
	if args.csv:
		args.csv.write_text("\n".join([",".join(keys)] + [",".join(str(r[k]) for k in keys) for r in rows]) + "\n")
	for r in rows:
		print("  ".join(f"{k}={r[k]}" for k in keys))
	return 0


if __name__ == "__main__":
	sys.exit(main())
