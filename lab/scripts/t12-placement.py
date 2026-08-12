#!/usr/bin/env python3
"""Compare where two legs put the same programme.

The merge oracle reports whether datagrams match. When they do not, this says
whether the legs disagree about the *content* (one is missing packets the other
delivered) or only about *placement* (the same packets, in different slots), by
stripping stuffing and comparing the two content sequences directly.
"""

import argparse
import importlib.util
import sys
from pathlib import Path

NULL_PID = 0x1FFF
TS = 188


def load_oracle(path):
	spec = importlib.util.spec_from_file_location("oracle", path)
	module = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(module)
	return module


def pid(packet):
	return ((packet[1] & 0x1F) << 8) | packet[2]


def content(datagrams):
	"""Programme packets in order, with the sequence number each went out under."""
	out = []
	for seq, payload in datagrams:
		for i in range(0, len(payload) - TS + 1, TS):
			packet = payload[i : i + TS]
			if pid(packet) != NULL_PID:
				out.append((seq, packet))
	return out


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--pcap", required=True)
	ap.add_argument("--oracle", default=str(Path(__file__).with_name("t12-merge-oracle.py")))
	ap.add_argument("--leg-a-port", type=int, default=5100)
	ap.add_argument("--leg-b-port", type=int, default=5200)
	ap.add_argument("--from-seq", type=int, default=None, help="ignore sequence numbers below this")
	args = ap.parse_args()

	oracle = load_oracle(args.oracle)
	legs = {args.leg_a_port: [], args.leg_b_port: []}
	epoch = {port: [0, None] for port in legs}
	for _, link, frame in oracle.read_pcap(args.pcap):
		parsed_udp = oracle.parse_udp(link, frame)
		if not parsed_udp:
			continue
		dport, payload = parsed_udp
		if dport not in legs:
			continue
		parsed = oracle.parse_rtp(payload)
		if not parsed:
			continue
		seq, body = parsed[0], parsed[-1]
		# 16-bit sequence numbers wrap several times in a 60 s run.
		state = epoch[dport]
		if state[1] is not None and seq < state[1] - 32768:
			state[0] += 65536
		state[1] = seq
		legs[dport].append((seq + state[0], body))

	# The window narrows leg A only: the question a recovery cell asks is where in
	# the *whole* of leg B's output leg A's returning content appears.
	a = [(s, p) for s, p in legs[args.leg_a_port] if args.from_seq is None or s >= args.from_seq]
	b = legs[args.leg_b_port]
	ca, cb = content(a), content(b)
	print(f"leg a: {len(a)} datagrams, {len(ca)} content packets")
	print(f"leg b: {len(b)} datagrams, {len(cb)} content packets")

	# Where does A's content stream sit inside B's?
	if not ca or not cb:
		return
	index = {}
	for i, (_, packet) in enumerate(cb):
		index.setdefault(bytes(packet), []).append(i)
	anchor = None
	for i, (_, packet) in enumerate(ca[:2000]):
		hits = index.get(bytes(packet), [])
		if len(hits) == 1:
			anchor = (i, hits[0])
			break
	if anchor is None:
		print("no unique content packet in common: the legs may hold different programme")
	else:
		ai, bi = anchor
		print(f"anchor: A[{ai}] == B[{bi}] (offset {bi - ai} content packets)")
		same = 0
		total = 0
		first_diff = None
		while ai < len(ca) and bi < len(cb):
			total += 1
			if ca[ai][1] == cb[bi][1]:
				same += 1
			elif first_diff is None:
				first_diff = (ca[ai][0], cb[bi][0])
			ai += 1
			bi += 1
		print(f"content packets in step: {same}/{total} ({100.0 * same / max(total, 1):.2f}%)")
		if first_diff:
			print(f"first divergence at leg A seq {first_diff[0]} / leg B seq {first_diff[1]}")

	# And do matching content packets go out under the same sequence number?
	# The shift between the legs is the diagnosis: zero is alignment, a constant
	# non-zero is a phase error, and absent means the legs hold different
	# programme.
	pairs = {}
	for seq, packet in cb:
		pairs.setdefault(bytes(packet), []).append(seq)
	shifts = {}
	missing = 0
	for seq, packet in ca:
		hits = pairs.get(bytes(packet))
		if not hits:
			missing += 1
			continue
		shift = min(hits, key=lambda s: abs(s - seq)) - seq
		shifts[shift] = shifts.get(shift, 0) + 1
	total = len(ca)
	print(f"content packets leg B never sent: {missing}/{total} ({100.0 * missing / max(total, 1):.2f}%)")
	print("datagram-number shift against leg B (top 6):")
	for shift, count in sorted(shifts.items(), key=lambda kv: -kv[1])[:6]:
		print(f"  {shift:+8d}: {count} packets ({100.0 * count / max(total, 1):.2f}%)")


if __name__ == "__main__":
	sys.exit(main())
