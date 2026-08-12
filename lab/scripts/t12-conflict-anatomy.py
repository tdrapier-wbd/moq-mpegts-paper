#!/usr/bin/env python3
"""Why two independently groomed legs differ at the same RTP sequence number.

"Payload conflict" is not a mechanism. This asks which of three things is actually
happening at the conflicting sequence numbers:

  1. the two legs carry the same packets in the same order, differing only in the
     PCR bytes each groomer stamped for itself;
  2. they carry the same packets but interleave stuffing differently, so the
     content lands in different datagrams;
  3. they carry different content altogether.

Only (1) is recoverable by a receiver that merges on sequence number.

Usage: t12-conflict-anatomy.py --pcap cap.pcap [--leg-a-port 5100] [--leg-b-port 5200]
       [--sample 400]
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib

TS_PACKET = 188
NULL_PID = 0x1FFF

spec = importlib.util.spec_from_file_location(
	"t12_oracle", pathlib.Path(__file__).with_name("t12-merge-oracle.py")
)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


def pids(body):
	return [
		((body[i + 1] & 0x1F) << 8 | body[i + 2]) for i in range(0, len(body), TS_PACKET)
	]


def has_pcr(packet):
	"""Adaptation field present, long enough, with the PCR flag set."""
	if not packet[3] & 0x20 or packet[4] == 0:
		return False
	return bool(packet[5] & 0x10)


def differs_only_in_pcr(pkt_a, pkt_b):
	if pkt_a == pkt_b:
		return True
	if not (has_pcr(pkt_a) and has_pcr(pkt_b)):
		return False
	# PCR occupies the 6 bytes after the adaptation-field flags
	blanked_a = pkt_a[:6] + bytes(6) + pkt_a[12:]
	blanked_b = pkt_b[:6] + bytes(6) + pkt_b[12:]
	return blanked_a == blanked_b


def main():
	parser = argparse.ArgumentParser(description="anatomy of a 2022-7 payload conflict")
	parser.add_argument("--pcap", required=True)
	parser.add_argument("--leg-a-port", type=int, default=5100)
	parser.add_argument("--leg-b-port", type=int, default=5200)
	parser.add_argument("--sample", type=int, default=400)
	args = parser.parse_args()

	leg_a, leg_b = oracle.Leg("a"), oracle.Leg("b")
	for time, link, frame in oracle.read_pcap(args.pcap):
		got = oracle.parse_udp(link, frame)
		if not got:
			continue
		port, payload = got
		rtp = oracle.parse_rtp(payload)
		if not rtp:
			continue
		sequence, timestamp, ssrc, body = rtp
		if port == args.leg_a_port:
			leg_a.add(time, sequence, ssrc, body, timestamp)
		elif port == args.leg_b_port:
			leg_b.add(time, sequence, ssrc, body, timestamp)

	offset, _, _ = oracle.find_offset(leg_a, leg_b)
	if offset is None:
		raise SystemExit("no sequence offset could be established")

	conflicts = []
	for index, (_, payload_a, _) in leg_a.by_index.items():
		got_b = leg_b.by_index.get(index + offset)
		if got_b and got_b[1] != payload_a:
			conflicts.append((index, payload_a, got_b[1]))
	conflicts.sort()
	sample = conflicts[: args.sample]

	same_pid_order = pcr_only = content_differs = 0
	null_count_differs = 0
	differing_offsets = {}
	for _index, payload_a, payload_b in sample:
		pids_a, pids_b = pids(payload_a), pids(payload_b)
		if pids_a == pids_b:
			same_pid_order += 1
		if pids_a.count(NULL_PID) != pids_b.count(NULL_PID):
			null_count_differs += 1
		packets_a = [payload_a[i:i + TS_PACKET] for i in range(0, len(payload_a), TS_PACKET)]
		packets_b = [payload_b[i:i + TS_PACKET] for i in range(0, len(payload_b), TS_PACKET)]
		if len(packets_a) == len(packets_b) and all(
			differs_only_in_pcr(x, y) for x, y in zip(packets_a, packets_b)
		):
			pcr_only += 1
		else:
			content_differs += 1
		for x, y in zip(packets_a, packets_b):
			if x == y:
				continue
			for position, (byte_x, byte_y) in enumerate(zip(x, y)):
				if byte_x != byte_y:
					differing_offsets[position] = differing_offsets.get(position, 0) + 1

	total = max(len(sample), 1)
	print(f"sequence offset (b-a): {offset}")
	print(f"conflicting sequence numbers: {len(conflicts)} "
	      f"of {len(leg_a.by_index)} on leg A; sampling {len(sample)}")
	print(f"identical PID order:            {same_pid_order}/{total} "
	      f"({100.0 * same_pid_order / total:.1f}%)")
	print(f"differ only in PCR bytes:       {pcr_only}/{total} "
	      f"({100.0 * pcr_only / total:.1f}%)")
	print(f"differ beyond PCR:              {content_differs}/{total} "
	      f"({100.0 * content_differs / total:.1f}%)")
	print(f"different stuffing count:       {null_count_differs}/{total} "
	      f"({100.0 * null_count_differs / total:.1f}%)")
	top = sorted(differing_offsets.items(), key=lambda kv: -kv[1])[:12]
	print("most common differing byte offsets within a 188-byte packet "
	      "(6..11 = the PCR field):")
	print("  " + ", ".join(f"{position}:{count}" for position, count in top))


if __name__ == "__main__":
	main()
