#!/usr/bin/env python3
"""Grade T55: what an ST 2022-7 receiver makes of two RTP legs (lab/test-55-tsp-rtp-legs.md).

Reads the pcap t55-tsp-rtp-legs.sh records (both legs, dst ports 5100 and 5200) and the
reference the importer read. Three measurements:

  identity   for each datagram of leg B, leg A's datagram under the same 16-bit sequence number
             arriving within --pair-s: identical or not, per interval between the rig's events
  content    datagrams paired by payload instead: how many of B's appear in A at all, and the
             sequence offset (B - A) at which they do; a nonzero offset is the same programme
             under other numbers
  receiver   a sequence-number merge as a 2022-7 receiver does it: equal numbers only, the first
             copy wins, a datagram more than --window-ms behind is lost, a number far outside
             the window is ignored unless both legs have been silent for the window (then the
             receiver re-locks). The merged transport stream is checked for continuity errors
             and for packets out of the reference's order.

Usage: t55-grade.py legs.pcap ref.ts [--events events.txt] [--window-ms 450] [--ahead 2048] [--pair-s 2]
       [--json grade.json] [--out merged.ts]
"""

import argparse
import hashlib
import json
import struct
import sys
from collections import Counter

TS = 188


def read_legs(path):
	legs = {5100: [], 5200: []}
	with open(path, "rb") as f:
		magic, = struct.unpack("<I", f.read(4))
		if magic != 0xA1B2C3D4:
			sys.exit("expected the rig's little-endian microsecond pcap")
		f.read(20)
		while hdr := f.read(16):
			sec, usec, n, _ = struct.unpack("<IIII", hdr)
			frame = f.read(n)
			port = struct.unpack("!H", frame[22:24])[0]
			rtp = frame[28:]
			if port in legs and len(rtp) > 12:
				seq, ts, ssrc = struct.unpack("!HII", rtp[2:12])
				legs[port].append((sec + usec / 1e6, seq, ts, ssrc, rtp[12:]))
	return legs[5100], legs[5200]


def sdiff(a, b):
	return ((a - b + 32768) % 65536) - 32768


def identity(a, b, pair_s, cuts):
	by_seq = {}
	for t, seq, _, _, p in a:
		by_seq.setdefault(seq, []).append((t, p))
	bins = [dict(start=c[0], name=c[1], matched=0, mismatched=0, unpaired=0) for c in cuts]
	skew = []
	for t, seq, _, _, p in b:
		k = max(i for i, c in enumerate(cuts) if c[0] <= t) if t >= cuts[0][0] else 0
		near = [x for x in by_seq.get(seq, ()) if abs(x[0] - t) <= pair_s]
		if not near:
			bins[k]["unpaired"] += 1
			continue
		ta, pa = min(near, key=lambda x: abs(x[0] - t))
		if pa == p:
			bins[k]["matched"] += 1
			skew.append(t - ta)
		else:
			bins[k]["mismatched"] += 1
	skew.sort()
	return bins, (skew[0], skew[len(skew) // 2], skew[-1]) if skew else None


def content(a, b):
	def h(p):
		return hashlib.blake2b(p, digest_size=12).digest()

	ca = Counter(h(p) for *_, p in a)
	where = {}
	for _, seq, _, _, p in a:
		d = h(p)
		if ca[d] == 1:
			where[d] = seq
	offsets = Counter()
	found = 0
	for _, seq, _, _, p in b:
		d = h(p)
		if d in where:
			found += 1
			offsets[sdiff(seq, where[d])] += 1
	return dict(b_datagrams=len(b), b_found_in_a=found, offsets=offsets.most_common(4))


def receiver(a, b, window_ms, ahead_dg):
	w = window_ms / 1000.0
	events = sorted([(t, "a", seq, p) for t, seq, _, _, p in a] + [(t, "b", seq, p) for t, seq, _, _, p in b])
	expected = None
	buf = {}  # seq -> (payload, first arrival)
	hist = {}  # seq -> payload, for numbers already played out
	out, lost, conflicts, ignored, relocks, skipped = [], 0, 0, Counter(), 0, 0
	progress = None  # when the receiver last played or skipped a number
	ahead = ahead_dg

	def release(now):
		nonlocal expected, lost, progress
		while buf:
			if expected in buf:
				p, t0 = buf[expected]
				if t0 + w > now:
					return
				del buf[expected]
				out.append(p)
				hist[expected] = p
				hist.pop((expected - 4096) % 65536, None)
				progress = t0 + w
			else:
				oldest = min(t0 for _, t0 in buf.values())
				if oldest + w > now:
					return
				lost += 1
				progress = oldest + w
			expected = (expected + 1) % 65536

	for t, leg, seq, p in events:
		release(t)
		if expected is None:
			expected, progress = seq, t
		elif not buf and t - progress > w and abs(sdiff(seq, expected)) > 64:
			# starved for a window with nothing buffered: re-lock on what arrives
			relocks += 1
			skipped += sdiff(seq, expected) % 65536
			hist.clear()
			expected, progress = seq, t
		d = sdiff(seq, expected)
		if d < 0:
			if seq in hist and hist[seq] != p:
				conflicts += 1
			continue
		if d >= ahead:
			ignored[leg] += 1
			continue
		if seq in buf:
			if buf[seq][0] != p:
				conflicts += 1
		else:
			buf[seq] = (p, t)
	release(float("inf"))
	return b"".join(out), dict(datagrams_out=len(out), lost=lost, conflicts=conflicts,
							   ignored=dict(ignored), relocks=relocks, skipped_on_relock=skipped)


def ts_check(data, ref_path):
	cc_err, last = 0, {}
	pkts = [data[i:i + TS] for i in range(0, len(data) - TS + 1, TS)]
	for p in pkts:
		pid = ((p[1] & 0x1F) << 8) | p[2]
		if pid == 0x1FFF or not (p[3] & 0x10):
			continue
		cc = p[3] & 0x0F
		if pid in last and cc not in (last[pid], (last[pid] + 1) % 16):
			cc_err += 1
		last[pid] = cc
	res = dict(packets=len(pkts), cc_errors=cc_err)
	if ref_path:
		ref = open(ref_path, "rb").read()
		rp = [ref[i:i + TS] for i in range(0, len(ref) - TS + 1, TS)]
		count = Counter(rp)
		pos = {p: i for i, p in enumerate(rp) if count[p] == 1}
		jumps, prev, mapped = 0, None, 0
		for p in pkts:
			i = pos.get(p)
			if i is None:
				continue
			mapped += 1
			if prev is not None and i != prev + 1 and i <= prev:
				jumps += 1
			prev = i
		res.update(unique_mapped=mapped, backward_jumps=jumps,
				   not_in_ref=sum(1 for p in pkts if p not in count))
	return res


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pcap")
	ap.add_argument("ref", nargs="?")
	ap.add_argument("--events")
	ap.add_argument("--window-ms", type=float, default=450)
	ap.add_argument("--pair-s", type=float, default=2.0)
	ap.add_argument("--ahead", type=int, default=2048,
					help="datagrams ahead of the play-out point the receiver buffers")
	ap.add_argument("--json")
	ap.add_argument("--out", default="merged.ts")
	o = ap.parse_args()
	a, b = read_legs(o.pcap)
	if not a or not b:
		sys.exit(f"leg A {len(a)} datagrams, leg B {len(b)}: nothing to grade")
	cuts = [(min(a[0][0], b[0][0]), "first_datagram")]
	if o.events:
		for line in open(o.events):
			name, ns = line.split()
			cuts.append((int(ns) / 1e9, name))
	cuts.sort()
	bins, skew = identity(a, b, o.pair_s, cuts)
	merged, rx = receiver(a, b, o.window_ms, o.ahead)
	open(o.out, "wb").write(merged)
	res = dict(
		legs={n: dict(datagrams=len(x), ssrc=sorted({d[3] for d in x}), first_seq=x[0][1],
					  sizes=sorted(Counter(len(d[4]) for d in x).items())[:3],
					  span_s=round(x[-1][0] - x[0][0], 2)) for n, x in (("a", a), ("b", b))},
		identity=[{k: (round(v - cuts[0][0], 2) if k == "start" else v) for k, v in x.items()} for x in bins],
		skew_ms=[round(s * 1000, 2) for s in skew] if skew else None,
		content=content(a, b),
		receiver=dict(rx, window_ms=o.window_ms),
		merged=ts_check(merged, o.ref),
	)
	print(json.dumps(res, indent=1, default=str))
	if o.json:
		json.dump(res, open(o.json, "w"), indent=1, default=str)


if __name__ == "__main__":
	main()
