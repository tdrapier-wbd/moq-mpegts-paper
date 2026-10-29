#!/usr/bin/env python3
"""A live ST 2022-7 merge of two RTP legs, for a soak (P1-aj): nothing is stored.

  p1aj-merge.py [--ports 5100 5200] [--window-ms 450] [--every 60] > merged.ts

Datagrams are merged by RTP sequence number: the first copy of each number is written to stdout
(the merged transport stream, for t21-pcr-monitor.py and tsp's continuity check), in order; a
number neither leg has delivered when a later one has waited --window-ms is lost. A second copy
is compared with the first. Every --every seconds one JSON line goes to stderr:

  a, b          datagrams received per leg
  merged, lost  datagrams written, and numbers neither leg delivered in time
  a_missing, b_missing   numbers written that one leg never delivered (its own loss)
  mismatched    second copies whose payload differs from the first
  late          copies that arrived after their number was written or given up
  skew_ms       B's arrival less A's, 5th, 50th and 95th percentiles, over numbers both carried
"""
import argparse
import json
import select
import socket
import sys
import time
import zlib
from collections import OrderedDict

HORIZON = 20000  # numbers remembered after writing, about 8 s at 26 Mb/s


def pct(v, q):
	return round(v[min(len(v) - 1, int(q * len(v)))] * 1000, 1) if v else None


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--ports", type=int, nargs=2, default=[5100, 5200])
	ap.add_argument("--window-ms", type=float, default=450.0)
	ap.add_argument("--every", type=float, default=60.0)
	args = ap.parse_args()
	window = args.window_ms / 1000.0
	socks = []
	for port in args.ports:
		s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
		s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32 << 20)
		s.bind(("127.0.0.1", port))
		s.setblocking(False)
		socks.append(s)
	out = sys.stdout.buffer
	pending = {}  # ext -> (time, crc, payload, leg), the first copy, not yet written
	seconds = {}  # ext -> (time, leg), a second copy that arrived while the first was pending
	written = OrderedDict()  # ext -> [crc, mask, time_a, time_b]
	top = None  # highest extended number seen
	nxt = None  # next number to write
	c = dict(a=0, b=0, merged=0, lost=0, a_missing=0, b_missing=0, mismatched=0, late=0)
	skews = []
	t_report = time.time() + args.every

	def extend(seq):
		nonlocal top
		if top is None:
			top = seq
			return seq
		ext = (top & ~0xFFFF) | seq
		if ext - top > 0x8000:
			ext -= 0x10000
		elif top - ext > 0x8000:
			ext += 0x10000
		top = max(top, ext)
		return ext

	def retire():
		while len(written) > HORIZON:
			_, (_, mask, _, _) = written.popitem(last=False)
			c["a_missing"] += not mask & 1
			c["b_missing"] += not mask & 2

	def arrived(w, leg, t):
		w[1] |= 1 << leg
		w[2 + leg] = t
		if w[2] is not None and w[3] is not None:
			skews.append(w[3] - w[2])

	def write(ext):
		t, crc, payload, leg = pending.pop(ext)
		out.write(payload)
		c["merged"] += 1
		w = written[ext] = [crc, 0, None, None]
		arrived(w, leg, t)
		if ext in seconds:
			arrived(w, seconds[ext][1], seconds.pop(ext)[0])
		retire()

	while True:
		ready, _, _ = select.select(socks, [], [], 0.05)
		now = time.time()
		for leg, s in enumerate(socks):
			if s not in ready:
				continue
			while True:
				try:
					d = s.recv(2048)
				except BlockingIOError:
					break
				if len(d) < 12:
					continue
				c["ab"[leg]] += 1
				ext = extend(int.from_bytes(d[2:4], "big"))
				crc = zlib.crc32(d[12:])
				if ext in written:
					w = written[ext]
					if not w[1] & (1 << leg):
						c["mismatched"] += crc != w[0]
						arrived(w, leg, now)
				elif ext in pending:
					if pending[ext][3] != leg and ext not in seconds:
						c["mismatched"] += crc != pending[ext][1]
						seconds[ext] = (now, leg)
				elif nxt is not None and ext < nxt:
					c["late"] += 1
				else:
					pending[ext] = (now, crc, d[12:], leg)
					if nxt is None:
						nxt = ext
		# Write in order: the next number as soon as it is here; past a hole once a later number
		# has waited the window.
		while nxt is not None:
			if nxt in pending:
				write(nxt)
				nxt += 1
				continue
			if pending and now - min(v[0] for v in pending.values()) > window:
				k = min(pending)
				c["lost"] += k - nxt
				nxt = k
				continue
			break
		if now >= t_report:
			skews.sort()
			print(json.dumps(dict(t=round(now, 3), **c, skew_ms=[pct(skews, 0.05), pct(skews, 0.5),
							pct(skews, 0.95)])), file=sys.stderr, flush=True)
			c = dict.fromkeys(c, 0)
			skews = []
			t_report = now + args.every


if __name__ == "__main__":
	main()
