#!/usr/bin/env python3
"""Where a MoQ outage's excess programme loss goes: T28 criteria 10-13, one cell of the matched ladder.

The content grader says how much programme an outage cost; it cannot say why the cost exceeds the
outage. This joins four records the ladder keeps on one host clock -- the source and egress taps
(`src.csv`, `eg.csv`: wall time and PTS per video PES), the subscriber's UDP headers (`wire.pcap`,
`WIRE_CAP=1`) and the outage stamps (`events.txt`) -- with the export's warnings (`sub.log`).

A lost picture is one the source tap holds and the egress tap lacks, inside a window that opens
`--settle-s` after the first delivered picture's publish time and closes `--delay-s` + 2 s before the
last egress arrival, so neither the join nor pictures still in flight at close count. *T_rec* is the
first instant after the outage ends from which the delivered rate holds for 1 s at or above its median
over the 10 s before the outage. Each lost picture is placed by its publish time: before the outage,
during it, after it but before *T_rec* (*stack*), or after *T_rec* (*lane*). The excess *E* is
everything lost outside the outage; a share of 2/3 of *E* decides the verdict, else *mixed*.

Lane pictures are labelled from the export's log. Video group *k* is the clip's *k*-th keyframe
(random access indicator), because `import ts` numbers groups from 0 and never seeks: *evicted* when
the export reports that group evicted, *skipped* when a "skipping slow groups" range covers it
(debug, `RUST_LOG=...,moq_mux::container::consumer=debug`), then *late* up to the number of video
frames the export reports dropping late after *T_rec* (that line carries no timestamp of the media,
so late drops are counted, not matched), and *none* for the rest.

    t28-outage-trace.py <cell-dir> --clip clip.ts [--vpid 111] [--delay-s 2] [--settle-s 8]
                        [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import struct
import sys
from datetime import datetime
from pathlib import Path

PKT = 188
ANSI = re.compile(r"\x1b\[[0-9;]*m")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z")


def read_tap(path: Path) -> list[tuple[int, int]]:
	rows = []
	with open(path) as fh:
		next(fh, None)
		for line in fh:
			t, _, p = line.strip().partition(",")
			if t and p:
				rows.append((int(t), int(p)))
	return rows


def keyframes(clip: Path, vpid: int) -> list[int]:
	"""PTS of every video PES whose first packet carries the random access indicator, in stream order."""
	out = []
	with open(clip, "rb") as fh:
		while True:
			buf = fh.read(PKT * 4096)
			if not buf:
				return out
			for i in range(0, len(buf) - PKT + 1, PKT):
				p = buf[i : i + PKT]
				if p[0] != 0x47 or not p[1] & 0x40 or ((p[1] & 0x1F) << 8 | p[2]) != vpid:
					continue
				afc = (p[3] >> 4) & 3
				if not (afc & 2 and p[4] and p[5] & 0x40):
					continue
				q = p[5 + p[4] :]
				if len(q) < 14 or q[:3] != b"\x00\x00\x01" or not q[7] & 0x80:
					continue
				out.append(((q[9] >> 1) & 7) << 30 | q[10] << 22 | (q[11] >> 1) << 15 | q[12] << 7 | q[13] >> 1)


def pcap_bins(path: Path, t0_ns: int, bin_ns: int) -> dict[int, int]:
	"""Bytes per bin of the capture, bins counted from t0."""
	bins: dict[int, int] = {}
	with open(path, "rb") as fh:
		magic = fh.read(4)
		if magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
			endian, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
		elif magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
			endian, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
		else:
			sys.exit(f"{path}: not a classic pcap")
		fh.read(20)
		while len(h := fh.read(16)) == 16:
			sec, frac, caplen, origlen = struct.unpack(endian + "IIII", h)
			fh.seek(caplen, 1)
			t = sec * 1_000_000_000 + (frac if nano else frac * 1000)
			b = (t - t0_ns) // bin_ns
			bins[b] = bins.get(b, 0) + origlen
	return bins


def log_ns(line: str) -> int | None:
	m = STAMP.match(line)
	if not m:
		return None
	whole = datetime.fromisoformat(m.group(1) + "+00:00").timestamp()
	frac = float(m.group(2) or 0)
	return int(round((whole + frac) * 1e9))


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("cell")
	ap.add_argument("--clip", required=True)
	ap.add_argument("--vpid", type=int, default=111)
	ap.add_argument("--delay-s", type=float, default=2.0)
	ap.add_argument("--settle-s", type=float, default=8.0)
	ap.add_argument("--json")
	a = ap.parse_args()
	d = Path(a.cell)

	src, eg = read_tap(d / "src.csv"), read_tap(d / "eg.csv")
	if len(src) < 100 or len(eg) < 100:
		sys.exit(f"{d}: taps too short ({len(src)} source, {len(eg)} egress rows)")
	first_t: dict[int, int] = {}
	for t, p in src:
		first_t.setdefault(p, t)
	src_set = set(first_t)
	votes: dict[int, int] = {}
	for _, p in eg[:2000]:
		for k in range(-3, 4):
			if p - k in src_set:
				votes[k] = votes.get(k, 0) + 1
	if not votes:
		sys.exit(f"{d}: no egress PTS within 3 ticks of a source PTS")
	off = max(votes, key=votes.get)
	delivered = {p - off for _, p in eg} & src_set
	uniq = sorted(src_set)
	dur = statistics.median(b - a for a, b in zip(uniq, uniq[1:]) if b > a) / 90000
	# Each picture lasts until the next source picture in presentation order; a count times the
	# median step undercounts a stream that mixes field and frame pictures.
	span = {a: (b - a) / 90000 for a, b in zip(uniq, uniq[1:])}

	def secs(pics) -> float:
		return round(sum(span.get(p, dur) for p in pics), 3)

	pub_first = first_t[min(delivered, key=lambda p: first_t[p])]
	t_lo = pub_first + int(a.settle_s * 1e9)
	t_hi = max(t for t, _ in eg) - int((a.delay_s + 2) * 1e9)
	expected = [p for p, t in first_t.items() if t_lo <= t <= t_hi]
	lost = sorted((first_t[p], p) for p in expected if p not in delivered)
	res: dict = {
		"cell": d.name,
		"pts_offset_ticks": off,
		"picture_s": round(dur, 4),
		"window_s": round((t_hi - t_lo) / 1e9, 2),
		"expected": len(expected),
		"lost_pictures": len(lost),
		"lost_s": secs(p for _, p in lost),
	}
	try:
		res["content_lost_s"] = json.load(open(d / "content.json")).get("content_lost_s")
	except (OSError, ValueError):
		res["content_lost_s"] = None

	ev = {}
	if (d / "events.txt").exists():
		for line in open(d / "events.txt"):
			k, v = line.split()[:2]
			ev[k] = int(v)
	if "outage_start_ns" not in ev:
		res["verdict"] = "control"
		return finish(res, a.json)
	o0, o1 = ev["outage_start_ns"], ev["outage_end_ns"]
	res["outage_s"] = round((o1 - o0) / 1e9, 3)

	t_rec = None
	if (d / "wire.pcap").exists():
		bin_ns = 100_000_000
		base = ev.get("cell_start_ns", o0 - 30_000_000_000)
		bins = pcap_bins(d / "wire.pcap", base, bin_ns)

		def rate(start_bin: int) -> float:
			return sum(bins.get(start_bin + i, 0) for i in range(10)) * 8

		b0, b1 = (o0 - base) // bin_ns, (o1 - base) // bin_ns
		pre = [rate(b) for b in range(b0 - 100, b0 - 15)]
		ref = statistics.median(pre) if pre else 0
		res["ref_rate_mbps"] = round(ref / 1e6, 3)
		post = [b for b in range(b1, max(bins, default=b1) - 9) if bins.get(b)]
		res["first_packet_after_s"] = round((post[0] - b1) * bin_ns / 1e9, 1) if post else None
		for b in range(b1, max(bins, default=b1) - 9):
			if ref and rate(b) >= ref:
				t_rec = base + b * bin_ns
				break
	res["t_rec_after_outage_s"] = round((t_rec - o1) / 1e9, 1) if t_rec else None

	parts = {"before": [], "during": [], "stack": [], "lane": []}
	for t, p in lost:
		if t < o0:
			parts["before"].append(p)
		elif t < o1:
			parts["during"].append(p)
		elif t_rec is None or t < t_rec:
			parts["stack"].append(p)
		else:
			parts["lane"].append(p)
	for k, v in parts.items():
		res[f"{k}_s"] = secs(v)
	excess = res["before_s"] + res["stack_s"] + res["lane_s"]
	res["excess_s"] = round(excess, 3)
	if excess < dur / 2:
		res["verdict"] = "none"
	elif res["stack_s"] >= 2 * excess / 3:
		res["verdict"] = "stack"
	elif res["lane_s"] >= 2 * excess / 3:
		res["verdict"] = "lane"
	else:
		res["verdict"] = "mixed"

	kf = keyframes(Path(a.clip), a.vpid)
	kf_set = set(kf)
	gop_of: dict[int, int] = {}
	g = -1
	for _, p in src:
		if p in kf_set:
			g += 1
		gop_of.setdefault(p, g)
	evicted, skipped, late = set(), [], 0
	video = re.compile(r"track=\S*(avc|hev|h26)")
	if (d / "sub.log").exists():
		for raw in open(d / "sub.log", errors="replace"):
			line = ANSI.sub("", raw)
			if "current group evicted" in line and video.search(line):
				m = re.search(r"group=(\d+)", line)
				if m:
					evicted.add(int(m.group(1)))
			elif "skipping slow groups" in line:
				m = re.search(r"old=(\d+).*?new=(\d+)", line)
				if m:
					skipped.append((int(m.group(1)), int(m.group(2)), bool(video.search(line))))
			elif "missed its deadline" in line and video.search(line):
				t = log_ns(line)
				if t_rec is not None and t is not None and t >= t_rec:
					late += 1
	labels = {"evicted": 0, "skipped": 0, "late": 0, "none": 0}
	budget = late
	for p in parts["lane"]:
		grp = gop_of.get(p, -1)
		if grp in evicted:
			labels["evicted"] += 1
		elif any(lo <= grp < hi for lo, hi, _ in skipped):
			labels["skipped"] += 1
		elif budget > 0:
			labels["late"] += 1
			budget -= 1
		else:
			labels["none"] += 1
	res["lane_labels"] = labels
	res["log"] = {
		"evicted_video_groups": sorted(evicted),
		"skips": [f"{lo}->{hi}{'' if v else '?'}" for lo, hi, v in skipped],
		"late_video_after_t_rec": late,
		"lost_gops": sorted({gop_of.get(p, -1) for p in parts["lane"] + parts["stack"]}),
	}
	return finish(res, a.json)


def finish(res: dict, out: str | None) -> int:
	keys = ("cell", "verdict", "lost_s", "content_lost_s", "outage_s", "excess_s", "before_s", "stack_s",
	        "lane_s", "t_rec_after_outage_s", "first_packet_after_s", "lane_labels")
	print("  ".join(f"{k}={res[k]}" for k in keys if k in res))
	if out:
		with open(out, "w") as fh:
			json.dump(res, fh, indent=1)
	return 0


if __name__ == "__main__":
	sys.exit(main())
