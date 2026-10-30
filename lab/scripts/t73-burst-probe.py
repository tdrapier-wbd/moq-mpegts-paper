#!/usr/bin/env python3
"""T73: measure a loss model from the datagrams it lets through.

  t73-burst-probe.py recv <port> <out.json> [--idle S]     on the far side of the impairment
  t73-burst-probe.py send <host> <port> [--rate PPS] [--seconds S] [--size B]

The sender numbers its datagrams; the receiver records which arrive and, once none has arrived for
--idle seconds, writes the loss rate and the run lengths of consecutive losses. netem's Gilbert
model counts in datagrams, so the probe's rate should be near the lane's it stands for.
"""
import argparse
import json
import socket
import statistics
import struct
import sys
import time

HDR = struct.Struct("!II")


def recv(a):
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
	s.bind(("0.0.0.0", a.port))
	s.settimeout(a.idle)
	seen, total = set(), None
	while True:
		try:
			d, _ = s.recvfrom(65536)
		except socket.timeout:
			if seen:
				break
			continue
		seq, total = HDR.unpack_from(d)
		seen.add(seq)
	runs, run = [], 0
	for i in range(total):
		if i in seen:
			if run:
				runs.append(run)
			run = 0
		else:
			run += 1
	if run:
		runs.append(run)
	lost = total - len(seen)
	out = dict(sent=total, received=len(seen), lost=lost, loss_pct=round(100 * lost / total, 3),
			   bursts=len(runs), mean_burst=round(statistics.mean(runs), 2) if runs else 0,
			   median_burst=statistics.median(runs) if runs else 0, max_burst=max(runs, default=0),
			   single_losses=sum(1 for x in runs if x == 1))
	json.dump(out, open(a.out, "w"), indent=1)
	print(json.dumps(out))


def send(a):
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	total = int(a.rate * a.seconds)
	pad = b"\0" * (a.size - HDR.size)
	t0 = time.monotonic()
	for i in range(total):
		s.sendto(HDR.pack(i, total) + pad, (a.host, a.port))
		lag = t0 + (i + 1) / a.rate - time.monotonic()
		if lag > 0:
			time.sleep(lag)
	print(f"sent {total} datagrams in {time.monotonic() - t0:.1f} s", file=sys.stderr)


def main():
	ap = argparse.ArgumentParser()
	sub = ap.add_subparsers(dest="mode", required=True)
	r = sub.add_parser("recv")
	r.add_argument("port", type=int)
	r.add_argument("out")
	r.add_argument("--idle", type=float, default=5.0)
	s = sub.add_parser("send")
	s.add_argument("host")
	s.add_argument("port", type=int)
	s.add_argument("--rate", type=float, default=1000.0)
	s.add_argument("--seconds", type=float, default=60.0)
	s.add_argument("--size", type=int, default=1316)
	a = ap.parse_args()
	recv(a) if a.mode == "recv" else send(a)


if __name__ == "__main__":
	main()
