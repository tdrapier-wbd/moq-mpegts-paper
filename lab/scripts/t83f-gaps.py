#!/usr/bin/env python3
"""T83 Part F's meter: listen on loopback UDP ports for SECONDS and report, per port, the video
PID's arrival gaps over --min-gap, timed from the meter's start.

usage: t83f-gaps.py SECONDS PORT... [--pid 111] [--min-gap 0.5]
"""
import argparse
import selectors
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("seconds", type=float)
ap.add_argument("ports", type=int, nargs="+")
ap.add_argument("--pid", type=int, default=111)
ap.add_argument("--min-gap", type=float, default=0.5)
args = ap.parse_args()

sel = selectors.DefaultSelector()
state = {}
for p in args.ports:
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
	s.bind(("127.0.0.1", p))
	s.setblocking(False)
	sel.register(s, selectors.EVENT_READ, p)
	state[p] = {"first": None, "last": None, "video": 0, "gaps": []}

t0 = time.monotonic()
end = t0 + args.seconds
while (now := time.monotonic()) < end:
	for key, _ in sel.select(timeout=0.1):
		p = key.data
		st = state[p]
		while True:
			try:
				d = key.fileobj.recv(65536)
			except BlockingIOError:
				break
			now = time.monotonic() - t0
			seen = False
			for i in range(0, len(d) - 187, 188):
				if d[i] == 0x47 and ((d[i + 1] & 0x1F) << 8 | d[i + 2]) == args.pid:
					st["video"] += 1
					seen = True
			if not seen:
				continue
			if st["first"] is None:
				st["first"] = now
			elif now - st["last"] > args.min_gap:
				st["gaps"].append((round(st["last"], 2), round(now - st["last"], 2)))
			st["last"] = now

for p in args.ports:
	st = state[p]
	tail = None if st["last"] is None else round(args.seconds - st["last"], 2)
	first = None if st["first"] is None else round(st["first"], 2)
	print(f"port {p}: first {first} s, video packets {st['video']}, silent at end {tail} s, gaps (at, s) {st['gaps']}")
