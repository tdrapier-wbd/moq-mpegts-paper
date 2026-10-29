#!/usr/bin/env python3
"""T60: the skew and identity of two stream-clocked RTP legs in one recorder pcap.

The recorder (t59-legs.sh rec-start) writes raw-IPv4 frames whose UDP destination port names the
leg (5100 for A, 5200 for B). Datagrams are paired by RTP sequence number and timestamp, which a
stream-clocked leg derives from stream position, so equal keys are the same slot on both legs.

Prints one JSON object: datagrams per leg and in common, how many common ones differ in payload,
the time both legs were emitting together, and the skew (B's arrival minus A's) as its median and
5th and 95th percentiles, in milliseconds.

Usage: t60-skew.py LEGS.pcap [--a-port 5100] [--b-port 5200]
"""
import argparse
import json
import struct
import sys


def legs(path, ports):
	seen = {port: {} for port in ports}
	with open(path, "rb") as f:
		if struct.unpack("<I", f.read(24)[:4])[0] != 0xA1B2C3D4:
			sys.exit("not a microsecond pcap")
		while True:
			head = f.read(16)
			if len(head) < 16:
				break
			sec, usec, size, _ = struct.unpack("<IIII", head)
			frame = f.read(size)
			if len(frame) < size:
				break
			port = struct.unpack("!H", frame[22:24])[0]
			if port not in seen:
				continue
			rtp = frame[28:]
			key = struct.unpack("!HI", rtp[2:8])
			seen[port][key] = (sec + usec / 1e6, hash(rtp[12:]))
	return [seen[port] for port in ports]


def percentile(values, q):
	return values[min(len(values) - 1, int(q * (len(values) - 1) + 0.5))]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pcap")
	ap.add_argument("--a-port", type=int, default=5100)
	ap.add_argument("--b-port", type=int, default=5200)
	args = ap.parse_args()
	a, b = legs(args.pcap, [args.a_port, args.b_port])
	common = sorted(set(a) & set(b), key=lambda key: a[key][0])
	out = dict(a=len(a), b=len(b), common=len(common))
	if common:
		skews = sorted((b[key][0] - a[key][0]) * 1000 for key in common)
		out.update(
			mismatched=sum(1 for key in common if a[key][1] != b[key][1]),
			together_s=round(a[common[-1]][0] - a[common[0]][0], 1),
			skew_ms=round(percentile(skews, 0.5), 1),
			skew_p05_ms=round(percentile(skews, 0.05), 1),
			skew_p95_ms=round(percentile(skews, 0.95), 1),
		)
	print(json.dumps(out))


if __name__ == "__main__":
	main()
