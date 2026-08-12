#!/usr/bin/env python3
"""T12 receiver-side selection oracle.

Reads one pcap containing both RTP/MPEG-TS legs of a 1+1 pair and computes what a
receiver would have produced, under two selection policies:

  seq-merge     ST 2022-7: take each RTP sequence number from whichever leg
                delivered it. Hitless if, and only if, the legs are payload
                identical at equal sequence numbers.
  input-select  IRD-style input failover: follow one leg, switch to the other
                after k ms of silence. Needs no alignment, and pays a
                discontinuity for it.

Both legs carry the same source mux, so continuity counters make the merged
output check itself: run TSDuck over the emitted .ts files.

Usage:
  t12-merge-oracle.py --pcap cap.pcap --leg-a-port 5100 --leg-b-port 5200 \
      [--k-ms 50] [--out-prefix merged] [--json summary.json] [--meta meta.json]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from collections import Counter, defaultdict

TS_PACKET = 188
RTP_HEADER = 12
NULL_PID = 0x1FFF


# ------------------------------------------------------------------ pcap ------
def read_pcap(path):
	"""Yield (epoch_seconds, link_layer_bytes) from a classic pcap file."""
	with open(path, "rb") as fh:
		magic = fh.read(4)
		if magic == b"\x0a\x0d\x0d\x0a":
			sys.exit("pcapng is not supported; capture with tcpdump -w (classic pcap)")
		if magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
			endian, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
		elif magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
			endian, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
		else:
			sys.exit(f"not a pcap file: magic {magic!r}")

		_, _, _, _, _, link = struct.unpack(endian + "HHiIII", fh.read(20))
		while True:
			header = fh.read(16)
			if len(header) < 16:
				return
			ts_sec, ts_frac, caplen, _ = struct.unpack(endian + "IIII", header)
			data = fh.read(caplen)
			if len(data) < caplen:
				return
			yield ts_sec + ts_frac / (1e9 if nano else 1e6), link, data


def parse_udp(link, frame):
	"""Return (dst_port, payload) for an IPv4/UDP frame, else None."""
	if link == 1:  # Ethernet
		if len(frame) < 14:
			return None
		ethertype = struct.unpack("!H", frame[12:14])[0]
		if ethertype != 0x0800:
			return None
		packet = frame[14:]
	elif link == 113:  # LINUX_SLL
		if len(frame) < 16 or struct.unpack("!H", frame[14:16])[0] != 0x0800:
			return None
		packet = frame[16:]
	elif link == 101:  # RAW
		packet = frame
	else:
		sys.exit(f"unsupported link type {link}")

	if len(packet) < 20 or packet[0] >> 4 != 4 or packet[9] != 17:
		return None
	ihl = (packet[0] & 0x0F) * 4
	udp = packet[ihl:]
	if len(udp) < 8:
		return None
	dst_port = struct.unpack("!H", udp[2:4])[0]
	return dst_port, udp[8:]


def carries_content(body):
	"""True if a datagram holds at least one programme packet.

	A groomed leg keeps emitting constant-bitrate stuffing after its content source
	dies, so a receiver watching for *packet* loss sees a healthy carrier with no
	programme in it. Distinguishing the two is the point of this check — which means
	neither null packets nor the groomer's own adaptation-field-only PCR insertions
	count as content.
	"""
	for i in range(0, len(body), TS_PACKET):
		pid = (body[i + 1] & 0x1F) << 8 | body[i + 2]
		adaptation = (body[i + 3] >> 4) & 0x3
		if pid != NULL_PID and adaptation != 0b10:
			return True
	return False


def parse_rtp(payload):
	"""Return (sequence, timestamp, ssrc, ts_payload) for an RTP/MP2T datagram."""
	if len(payload) < RTP_HEADER + TS_PACKET:
		return None
	if payload[0] >> 6 != 2 or payload[1] & 0x7F != 33:
		return None
	sequence, timestamp, ssrc = struct.unpack("!HII", payload[2:12])
	body = payload[RTP_HEADER:]
	if len(body) % TS_PACKET or body[0] != 0x47:
		return None
	return sequence, timestamp, ssrc, body


# ------------------------------------------------------------------ model -----
class Leg:
	def __init__(self, name):
		self.name = name
		self.packets = []          # (time, extended_seq, payload)
		self.by_index = {}         # extended_seq -> (time, payload)
		self._epoch = 0
		self._prev = None
		self.ssrcs = set()
		self.content_datagrams = 0
		self.last_content_time = None

	def add(self, time, sequence, ssrc, payload, rtp_timestamp=0):
		if self._prev is not None:
			if sequence < self._prev - 32768:
				self._epoch += 1
			elif sequence > self._prev + 32768:
				self._epoch -= 1
		self._prev = sequence
		index = self._epoch * 65536 + sequence
		self.packets.append((time, index, payload))
		self.by_index.setdefault(index, (time, payload, rtp_timestamp))
		self.ssrcs.add(ssrc)
		if carries_content(payload):
			self.content_datagrams += 1
			self.last_content_time = time

	@property
	def indices(self):
		return self.by_index.keys()

	def span(self):
		if not self.packets:
			return (0.0, 0.0)
		return (self.packets[0][0], self.packets[-1][0])


def find_offset(leg_a, leg_b):
	"""Constant sequence offset (b - a) that aligns the legs, by payload identity."""
	def unique(leg):
		seen = defaultdict(list)
		for index, (_, payload, _ts) in leg.by_index.items():
			seen[hashlib.blake2b(payload, digest_size=16).digest()].append(index)
		return {digest: idx[0] for digest, idx in seen.items() if len(idx) == 1}

	unique_a, unique_b = unique(leg_a), unique(leg_b)
	votes = Counter(
		unique_b[digest] - index for digest, index in unique_a.items() if digest in unique_b
	)
	if not votes:
		return None, 0, 0
	offset, count = votes.most_common(1)[0]
	return offset, count, sum(votes.values())


def merge_window(leg_a, leg_b, offset):
	"""The window a 2022-7 receiver reconstructs, in leg A's index space.

	It opens once both legs are live (so leg startup skew is not counted as loss)
	and closes at the last datagram from *either* leg — a leg that dies mid-run is
	covered by the survivor, which is the whole point.
	"""
	low = max(min(leg_a.indices), min(leg_b.indices) - offset)
	high = max(max(leg_a.indices), max(leg_b.indices) - offset)
	return low, high


def alignment(leg_a, leg_b, offset):
	"""Payload-identity yield over the window, counting only both-present pairs."""
	if offset is None or not leg_a.by_index or not leg_b.by_index:
		return dict(overlap=0, matched=0, mismatched=0, missing=0, yield_pct=0.0)
	low, high = merge_window(leg_a, leg_b, offset)
	matched = mismatched = missing = overlap = 0
	for index in range(low, high + 1):
		got_a = leg_a.by_index.get(index)
		got_b = leg_b.by_index.get(index + offset)
		if got_a is None or got_b is None:
			missing += 1
			continue
		overlap += 1
		if got_a[1] == got_b[1]:
			matched += 1
		else:
			mismatched += 1
	total = max(overlap, 1)
	# RTP timestamps do not affect a sequence-number merge, but a receiver's jitter
	# buffer reads them, so whether the pair agrees on them is worth recording.
	same_timestamp = sum(
		1
		for index in range(low, high + 1)
		if (got_a := leg_a.by_index.get(index)) and (got_b := leg_b.by_index.get(index + offset))
		and got_a[2] == got_b[2]
	)
	return dict(
		overlap=overlap,
		matched=matched,
		mismatched=mismatched,
		missing=missing,
		yield_pct=100.0 * matched / total,
		rtp_timestamp_identical_pct=100.0 * same_timestamp / total,
	)


def seq_merge(leg_a, leg_b, offset, out_path):
	"""ST 2022-7 reconstruction over the merge window."""
	if offset is None:
		return None
	low, high = merge_window(leg_a, leg_b, offset)
	from_a = from_b = lost = conflicts = content = 0
	gaps, run = [], 0
	with open(out_path, "wb") as out:
		for index in range(low, high + 1):
			got_a = leg_a.by_index.get(index)
			got_b = leg_b.by_index.get(index + offset)
			if got_a and got_b and got_a[1] != got_b[1]:
				conflicts += 1
			chosen = None
			if got_a:
				chosen = got_a[1]
				out.write(chosen)
				from_a += 1
			elif got_b:
				chosen = got_b[1]
				out.write(chosen)
				from_b += 1
			if chosen is not None:
				content += carries_content(chosen)
			if chosen is None:
				lost += 1
				run += 1
				continue
			if run:
				gaps.append(run)
				run = 0
	if run:
		gaps.append(run)
	span = high - low + 1
	written = from_a + from_b
	return dict(
		datagrams=span,
		from_a=from_a,
		from_b=from_b,
		covered_by_b=from_b,
		lost_datagrams=lost,
		conflicts=conflicts,
		longest_gap_datagrams=max(gaps) if gaps else 0,
		gap_runs=len(gaps),
		# Loss is not the only way a merged output can be dead: a leg whose content
		# source has failed still supplies every sequence number, as stuffing.
		content_datagrams=content,
		content_pct=round(100.0 * content / written, 2) if written else 0.0,
		output=out_path,
	)


def input_select(leg_a, leg_b, k_ms, out_path):
	"""IRD-style input failover: follow one leg, switch after k ms of silence."""
	# Sort on arrival time and leg only. Capture timestamps have microsecond
	# resolution, so datagrams do tie; sorting whole tuples would then order them by
	# payload bytes and scramble one leg's own packet order into continuity errors.
	# A stable sort keeps each leg in capture order.
	stream = sorted(
		[(t, "a", p) for t, _, p in leg_a.packets] + [(t, "b", p) for t, _, p in leg_b.packets],
		key=lambda item: (item[0], item[1]),
	)
	if not stream:
		return None
	k = k_ms / 1000.0
	active = "a" if leg_a.packets else "b"
	last_seen = {"a": None, "b": None}
	last_out = None
	switches, written = [], 0
	with open(out_path, "wb") as out:
		for time, leg, payload in stream:
			last_seen[leg] = time
			other = "b" if active == "a" else "a"
			if last_seen[active] is not None and time - last_seen[active] > k:
				if last_seen[other] is not None and time - last_seen[other] <= k:
					switches.append(dict(at=time, from_leg=active, to_leg=other,
					                     gap_ms=1000.0 * (time - (last_out or time))))
					active = other
			if leg == active:
				out.write(payload)
				written += 1
				last_out = time
	return dict(
		k_ms=k_ms,
		datagrams=written,
		switches=len(switches),
		switch_events=switches,
		output=out_path,
	)


def silence(leg):
	"""Inter-arrival gaps on one leg: an input-select threshold below the natural
	gap of a bursty (ungroomed) leg flaps continuously."""
	times = [t for t, _, _ in leg.packets]
	if len(times) < 2:
		return None
	gaps = sorted(1000.0 * (b - a) for a, b in zip(times, times[1:]))
	return dict(
		median_ms=gaps[len(gaps) // 2],
		p99_ms=gaps[int(0.99 * (len(gaps) - 1))],
		max_ms=gaps[-1],
	)


def skew(leg_a, leg_b, offset):
	if offset is None:
		return None
	deltas = []
	for index, (time_a, _payload, _ts) in leg_a.by_index.items():
		got_b = leg_b.by_index.get(index + offset)
		if got_b:
			deltas.append(1000.0 * (got_b[0] - time_a))
	if not deltas:
		return None
	deltas.sort()
	return dict(
		pairs=len(deltas),
		min_ms=deltas[0],
		median_ms=deltas[len(deltas) // 2],
		max_ms=deltas[-1],
		p99_ms=deltas[int(0.99 * (len(deltas) - 1))],
		abs_max_ms=max(abs(deltas[0]), abs(deltas[-1])),
	)


def leg_report(leg):
	first, last = leg.span()
	return dict(
		datagrams=len(leg.packets),
		unique=len(leg.by_index),
		ssrcs=[hex(s) for s in leg.ssrcs],
		span=(first, last),
		silence=silence(leg),
		content_datagrams=leg.content_datagrams,
		null_only_datagrams=len(leg.packets) - leg.content_datagrams,
		# how long the leg kept transmitting after its last programme packet
		carrier_after_content_s=(
			round(last - leg.last_content_time, 3) if leg.last_content_time else None
		),
	)


def timeline(leg_a, leg_b, bucket=0.2):
	start = min([t for t, _, _ in leg_a.packets] + [t for t, _, _ in leg_b.packets], default=0)
	counts = defaultdict(lambda: [0, 0])
	for slot, leg in ((0, leg_a), (1, leg_b)):
		for time, _, _ in leg.packets:
			counts[int((time - start) / bucket)][slot] += 1
	return start, [(round(k * bucket, 3), v[0], v[1]) for k, v in sorted(counts.items())]


# ------------------------------------------------------------------- main -----
def main():
	parser = argparse.ArgumentParser(description="T12 receiver-side selection oracle")
	parser.add_argument("--pcap", required=True)
	parser.add_argument("--leg-a-port", type=int, default=5100)
	parser.add_argument("--leg-b-port", type=int, default=5200)
	parser.add_argument("--k-ms", default="50,100,250,500",
	                    help="comma-separated input-select thresholds, ms")
	parser.add_argument("--out-prefix", default=None)
	parser.add_argument("--json", dest="json_path", default=None)
	parser.add_argument("--meta", default=None)
	args = parser.parse_args()

	leg_a, leg_b = Leg("a"), Leg("b")
	malformed = 0
	for time, link, frame in read_pcap(args.pcap):
		got = parse_udp(link, frame)
		if not got:
			continue
		port, payload = got
		rtp = parse_rtp(payload)
		if not rtp:
			malformed += 1
			continue
		sequence, rtp_timestamp, ssrc, body = rtp
		if port == args.leg_a_port:
			leg_a.add(time, sequence, ssrc, body, rtp_timestamp)
		elif port == args.leg_b_port:
			leg_b.add(time, sequence, ssrc, body, rtp_timestamp)

	offset, votes, total_votes = find_offset(leg_a, leg_b)
	align = alignment(leg_a, leg_b, offset)

	prefix = args.out_prefix or args.pcap.rsplit(".", 1)[0]
	merged = seq_merge(leg_a, leg_b, offset, f"{prefix}.seqmerge.ts")
	thresholds = [float(k) for k in args.k_ms.split(",")]
	selections = [
		input_select(leg_a, leg_b, k, f"{prefix}.inputselect.k{int(k)}.ts") for k in thresholds
	]
	selections = [s for s in selections if s]
	start, buckets = timeline(leg_a, leg_b)

	with open(f"{prefix}.timeline.csv", "w") as fh:
		fh.write("t_s,leg_a_datagrams,leg_b_datagrams\n")
		for time, count_a, count_b in buckets:
			fh.write(f"{time},{count_a},{count_b}\n")

	packets_per_datagram = (
		len(leg_a.packets[0][2]) // TS_PACKET if leg_a.packets else 0
	)
	# a gap in datagrams is only meaningful as a duration on the wire
	intervals = [s["median_ms"] for s in (silence(leg_a), silence(leg_b)) if s]
	interval_ms = min(intervals) if intervals else 0.0
	if merged:
		merged["longest_gap_ms"] = round(merged["longest_gap_datagrams"] * interval_ms, 1)
		merged["lost_ts_packets"] = merged["lost_datagrams"] * packets_per_datagram
	summary = dict(
		pcap=args.pcap,
		malformed_datagrams=malformed,
		packets_per_datagram=packets_per_datagram,
		leg_a=leg_report(leg_a),
		leg_b=leg_report(leg_b),
		sequence_offset=offset,
		offset_confidence=(votes / total_votes if total_votes else 0.0),
		alignment=align,
		# A real 2022-7 receiver merges on the sequence number as sent; it does not
		# search for an offset. A non-zero offset means the pair is alignable in
		# principle but not mergeable by a standard receiver.
		standard_receiver_mergeable=bool(
			offset == 0 and align["mismatched"] == 0 and align["matched"] > 0
		),
		seq_merge=merged,
		input_select=selections,
		skew=skew(leg_a, leg_b, offset),
		timeline_csv=f"{prefix}.timeline.csv",
	)
	if args.meta:
		with open(args.meta) as fh:
			summary["meta"] = json.load(fh)

	if args.json_path:
		with open(args.json_path, "w") as fh:
			json.dump(summary, fh, indent=2)

	# human summary
	print(f"legs: a={len(leg_a.packets)} datagrams, b={len(leg_b.packets)} datagrams "
	      f"({packets_per_datagram} TS packets each)")
	print(f"sequence offset (b-a): {offset}  confidence {summary['offset_confidence']:.3f}  "
	      f"standard-receiver mergeable: {summary['standard_receiver_mergeable']}")
	print(f"alignment yield: {align['yield_pct']:.4f}%  "
	      f"(matched {align['matched']}, mismatched {align['mismatched']}, "
	      f"one-sided {align['missing']}); "
	      f"rtp timestamps identical {align['rtp_timestamp_identical_pct']:.2f}%")
	if merged:
		print(f"seq-merge: {merged['datagrams']} datagrams, {merged['covered_by_b']} covered by leg B, "
		      f"lost {merged['lost_datagrams']} datagrams ({merged['lost_ts_packets']} TS packets), "
		      f"longest gap {merged['longest_gap_datagrams']} datagrams "
		      f"({merged['longest_gap_ms']} ms), payload conflicts {merged['conflicts']}, "
		      f"programme content in {merged['content_pct']}% of datagrams")
	for leg in ("a", "b"):
		report = summary[f"leg_{leg}"]
		gaps = report["silence"]
		if gaps:
			print(f"leg {leg} silence between datagrams: median {gaps['median_ms']:.1f} ms, "
			      f"p99 {gaps['p99_ms']:.1f}, max {gaps['max_ms']:.1f}")
		if report["null_only_datagrams"]:
			print(f"leg {leg} carrier without content: {report['null_only_datagrams']} "
			      f"null-only datagrams, {report['carrier_after_content_s']} s of carrier "
			      f"after the last programme packet")
	for selected in selections:
		print(f"input-select (k={selected['k_ms']:.0f} ms): {selected['switches']} switch(es), "
		      f"{selected['datagrams']} datagrams out")
		for event in selected["switch_events"][:4]:
			print(f"  switch {event['from_leg']}->{event['to_leg']} "
			      f"after {event['gap_ms']:.1f} ms of silence")
		if len(selected["switch_events"]) > 4:
			print(f"  ... {len(selected['switch_events']) - 4} more")
	if summary["skew"]:
		s = summary["skew"]
		print(f"skew (b-a): median {s['median_ms']:.3f} ms, "
		      f"min {s['min_ms']:.3f}, max {s['max_ms']:.3f}, |max| {s['abs_max_ms']:.3f} ms")


if __name__ == "__main__":
	main()
