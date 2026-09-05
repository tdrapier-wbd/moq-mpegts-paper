#!/usr/bin/env python3
"""How big a burst each coded picture is, in transport packets.

A media-aware lane carries coded frames, so the biggest frame is the biggest
thing the downstream groomer is ever handed at once, and the cushion it needs is
that burst plus what the path adds. That figure is a property of the *content*,
not of the transport, and it can be read straight off the source file: count the
transport packets between consecutive PES starts on the video PID.

    t19-frame-burst.py <file.ts> [pid]

With no PID, the busiest non-null PID carrying PES starts is used. Reports the
frame-size distribution in packets and, at the file's own mux rate, how long the
largest one takes to carry.
"""

import sys
from collections import Counter

PACKET = 188
NULL_PID = 0x1FFF


def pcr_of(pkt: bytes) -> int | None:
	"""The 27 MHz PCR in `pkt`, or None if it carries none."""
	if not pkt[3] >> 4 & 0x02 or pkt[4] == 0 or not pkt[5] & 0x10:
		return None
	b = pkt[6:12]
	base = b[0] << 25 | b[1] << 17 | b[2] << 9 | b[3] << 1 | b[4] >> 7
	return base * 300 | (b[4] & 1) << 8 | b[5]


def main() -> int:
	if len(sys.argv) < 2:
		print(__doc__, file=sys.stderr)
		return 2
	data = open(sys.argv[1], "rb").read()
	want = int(sys.argv[2], 0) if len(sys.argv) > 2 else None

	counts: Counter[int] = Counter()
	starts: Counter[int] = Counter()
	for off in range(0, len(data) - PACKET + 1, PACKET):
		pkt = data[off : off + PACKET]
		if pkt[0] != 0x47:
			continue
		pid = (pkt[1] & 0x1F) << 8 | pkt[2]
		if pid == NULL_PID:
			continue
		counts[pid] += 1
		if pkt[1] & 0x40:
			starts[pid] += 1
	if want is None:
		candidates = [(n, pid) for pid, n in counts.items() if starts[pid] > 4]
		if not candidates:
			print("no PES-carrying PID found")
			return 1
		want = max(candidates)[1]

	# Frame boundaries are payload-unit-start on the video PID. Everything
	# between two of them — including the other PIDs' packets and any PCR — is
	# the carriage the groomer receives while that picture is being delivered.
	sizes: list[int] = []
	first_pcr = last_pcr = None
	total = 0
	run = None
	for off in range(0, len(data) - PACKET + 1, PACKET):
		pkt = data[off : off + PACKET]
		if pkt[0] != 0x47:
			continue
		pid = (pkt[1] & 0x1F) << 8 | pkt[2]
		if pid == NULL_PID:
			continue
		total += 1
		pcr = pcr_of(pkt)
		if pcr is not None:
			first_pcr = pcr if first_pcr is None else first_pcr
			last_pcr = pcr
		if pid == want:
			if pkt[1] & 0x40:
				if run is not None:
					sizes.append(run)
				run = 0
			if run is not None:
				run += 1
	if run:
		sizes.append(run)
	if not sizes:
		print(f"PID 0x{want:04x} carries no PES starts")
		return 1

	sizes.sort()
	span = ((last_pcr - first_pcr) % (2**33 * 300)) / 27e6 if first_pcr is not None else 0.0
	rate = total * PACKET * 8 / span if span else 0.0
	mean = sum(sizes) / len(sizes)
	peak = sizes[-1]
	print(f"video PID 0x{want:04x}: {len(sizes)} coded pictures over {span:.1f} s")
	print(f"programme rate {rate / 1e6:.2f} Mb/s (non-null)")
	print(
		f"frame size in TS packets: p50 {sizes[len(sizes) // 2]} "
		f"p95 {sizes[int(len(sizes) * 0.95)]} peak {peak} (mean {mean:.0f})"
	)
	print(f"peak/mean frame size: {peak / mean:.1f}x")
	if rate:
		print(f"peak frame as carriage at the source rate: {peak * PACKET * 8 / rate * 1000:.0f} ms")
	return 0


if __name__ == "__main__":
	sys.exit(main())
