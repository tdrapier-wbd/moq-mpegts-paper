#!/usr/bin/env python3
"""Does an output carry the source's PSI/SI and section-carrying PIDs, verbatim?

    ts-si-survival.py <source.ts> <output.ts> [--edge N] [--json]

`ts-pid-complete.py` grades elementary streams by their units; this grades the tables a broadcast
receiver reads and a player does not need: PAT, CAT, PMT, NIT, SDT, EIT, TDT/TOT, and any PID the
source's PMT lists as sections (SCTE-35, stream type 0x86 or 0x05). Each row is one table_id on one
PID (the PMT row follows the PMT to whatever PID the output's PAT gives it).

The span is located by content, not by time: the output's first and last video PES are found in the
source by PTS, and the source's sections completing between them are what the output owes. A row is
**kept** when the output holds at least that many less `--edge`, every one byte-identical to a source
section on the same row, and none fails its CRC. An output that rewrites a table (a remuxer's own
SDT) reads 0 % verbatim; one that drops it reads 0 sections. Rows the output adds are listed apart.

Exits 1 if any row is not kept.
"""

import argparse
import json
import sys
from collections import defaultdict

TS = 188
VIDEO_TYPES = (0x01, 0x02, 0x1B, 0x24)
SECTION_TYPES = (0x05, 0x86)
SI_PIDS = (0x0000, 0x0001) + tuple(range(0x10, 0x20))
NAMES = {0x00: "PAT", 0x01: "CAT", 0x02: "PMT", 0x40: "NIT", 0x41: "NIT other", 0x42: "SDT",
		0x46: "SDT other", 0x4A: "BAT", 0x4E: "EIT p/f", 0x4F: "EIT p/f other", 0x70: "TDT", 0x73: "TOT",
		0xFC: "SCTE-35"}


def _crc_table():
	t = []
	for i in range(256):
		c = i << 24
		for _ in range(8):
			c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
		t.append(c)
	return t


CRC = _crc_table()


def crc_ok(s):
	"""MPEG-2 CRC over a section including its CRC_32 is zero. TDT carries none."""
	if s[0] == 0x70:
		return True
	c = 0xFFFFFFFF
	for b in s:
		c = ((c << 8) & 0xFFFFFFFF) ^ CRC[(c >> 24) ^ b]
	return c == 0


def name(tid):
	if 0x50 <= tid <= 0x5F:
		return "EIT schedule"
	if 0x60 <= tid <= 0x6F:
		return "EIT schedule other"
	return NAMES.get(tid, f"tid 0x{tid:02X}")


class Assembler:
	"""Sections on one PID, from packets; a continuity break drops the partial section."""

	def __init__(self):
		self.buf = None
		self.cc = None

	def feed(self, p, out):
		afc = p[3] >> 4 & 3
		if not afc & 1:
			return
		cc = p[3] & 0xF
		if cc == self.cc:
			return
		if self.cc is not None and cc != (self.cc + 1) & 0xF:
			self.buf = None
		self.cc = cc
		off = 4 + (1 + p[4] if afc & 2 else 0)
		if off >= TS:
			return
		pay = p[off:]
		if p[1] & 0x40:
			ptr = pay[0]
			if self.buf is not None:
				self.buf += pay[1:1 + ptr]
				self.drain(out)
			self.buf = bytearray(pay[1 + ptr:])
		elif self.buf is None:
			return
		else:
			self.buf += pay
		self.drain(out)

	def drain(self, out):
		b = self.buf
		while b is not None and len(b) >= 3:
			if b[0] == 0xFF:
				self.buf = None
				return
			n = 3 + ((b[1] & 0xF) << 8 | b[2])
			if len(b) < n:
				return
			out(bytes(b[:n]))
			del b[:n]


def pes_pts(p):
	afc = p[3] >> 4 & 3
	off = 4 + (1 + p[4] if afc & 2 else 0)
	h = p[off:off + 14]
	if len(h) < 14 or h[:3] != b"\x00\x00\x01" or not h[7] & 0x80:
		return None
	b = h[9:14]
	return ((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1


def scan(path):
	"""Sections by (pid, tid) with the packet index each completed at, and video PES PTS positions."""
	asm = defaultdict(Assembler)
	sections = defaultdict(list)
	pmt_pids, sect_pids, video = set(), set(), None
	pts_at = []
	idx = 0

	with open(path, "rb") as f:
		while chunk := f.read(TS * 8192):
			for i in range(0, len(chunk) - TS + 1, TS):
				p = chunk[i:i + TS]
				if p[0] != 0x47:
					continue
				pid = (p[1] & 0x1F) << 8 | p[2]
				if pid == video and p[1] & 0x40:
					pts = pes_pts(p)
					if pts is not None:
						pts_at.append((pts, idx))
				elif pid in SI_PIDS or pid in pmt_pids or pid in sect_pids:

					def got(s, pid=pid, at=idx):
						nonlocal video
						tid = s[0]
						sections[(pid, tid)].append((at, s))
						if tid == 0x00 and len(s) >= 12:
							for j in range(8, len(s) - 4, 4):
								prog = s[j] << 8 | s[j + 1]
								if prog:
									pmt_pids.add((s[j + 2] & 0x1F) << 8 | s[j + 3])
						elif tid == 0x02 and pid in pmt_pids and len(s) >= 16:
							end = len(s) - 4
							j = 12 + ((s[10] & 0xF) << 8 | s[11])
							while j + 5 <= end:
								st, es = s[j], (s[j + 1] & 0x1F) << 8 | s[j + 2]
								if st in VIDEO_TYPES and video is None:
									video = es
								elif st in SECTION_TYPES:
									sect_pids.add(es)
								j += 5 + ((s[j + 3] & 0xF) << 8 | s[j + 4])

					asm[pid].feed(p, got)
				idx += 1
	return sections, pmt_pids, pts_at, idx


def locate(pts_at, pts):
	"""The source packet index of the video PES with this PTS, exact or nearest."""
	for p, i in pts_at:
		if p == pts:
			return i
	return min(pts_at, key=lambda e: abs(e[0] - pts))[1]


def grade(source, output, edge):
	src, src_pmt, src_pts, _ = scan(source)
	out, out_pmt, out_pts, out_n = scan(output)
	if not out_pts:
		return {"error": "no video PES in the output"}, False
	first = min(out_pts, key=lambda e: e[1])[0]
	last = max(out_pts, key=lambda e: e[1])[0]
	a, b = locate(src_pts, first), locate(src_pts, last)
	span_s = (last - first) % (1 << 33) / 90000

	def row_key(pid, tid, pmts):
		return ("PMT", tid) if tid == 0x02 and pid in pmts else (pid, tid)

	out_rows = defaultdict(list)
	for (pid, tid), ss in out.items():
		out_rows[row_key(pid, tid, out_pmt)] += [s for _, s in ss]
	rows, ok = [], True
	seen = set()
	for (pid, tid), ss in sorted(src.items()):
		key = row_key(pid, tid, src_pmt)
		if key in seen:
			continue
		seen.add(key)
		owed = sum(1 for at, _ in ss if a <= at <= b)
		known = {s for _, s in ss}
		got = out_rows.get(key, [])
		verbatim = sum(1 for s in got if s in known)
		bad = sum(1 for s in got if not crc_ok(s))
		kept = len(got) >= owed - edge and verbatim == len(got) and bad == 0 and (owed == 0 or bool(got))
		ok &= kept
		rows.append({"pid": "PMT" if key[0] == "PMT" else f"0x{pid:04X}", "tid": f"0x{tid:02X}",
				"table": name(tid), "owed": owed, "carried": len(got), "verbatim": verbatim,
				"crc_bad": bad, "kept": bool(kept)})
	src_keys = {row_key(pid, tid, src_pmt) for pid, tid in src}
	extra = [{"pid": "PMT" if k[0] == "PMT" else f"0x{k[0]:04X}", "tid": f"0x{k[1]:02X}", "table": name(k[1]),
			"carried": len(v)} for k, v in sorted(out_rows.items(), key=str) if k not in src_keys]
	return {"span_s": round(span_s, 3), "source_packets": [a, b], "output_packets": out_n,
			"rows": rows, "added": extra}, ok


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("source")
	ap.add_argument("output")
	ap.add_argument("--edge", type=int, default=2, help="sections a row may lack at the span's edges")
	ap.add_argument("--json", action="store_true")
	args = ap.parse_args()
	res, ok = grade(args.source, args.output, args.edge)
	if args.json:
		print(json.dumps(res | {"pass": ok}))
	elif "error" in res:
		print(res["error"])
	else:
		print(f"span {res['span_s']} s, source packets {res['source_packets'][0]}–{res['source_packets'][1]}")
		print(f"{'PID':>6} {'tid':>4}  {'table':<18} {'owed':>5} {'carried':>7} {'verbatim':>8} {'crc':>4}  kept")
		for r in res["rows"]:
			print(f"{r['pid']:>6} {r['tid']:>4}  {r['table']:<18} {r['owed']:>5} {r['carried']:>7} "
					f"{r['verbatim']:>8} {r['crc_bad']:>4}  {'yes' if r['kept'] else 'NO'}")
		for r in res["added"]:
			print(f"added: {r['pid']} {r['tid']} {r['table']} x{r['carried']}")
		print("PASS" if ok else "FAIL")
	sys.exit(0 if ok else 1)


if __name__ == "__main__":
	main()
