#!/usr/bin/env python3
"""Per-leg report for a T59 capture (lab/test-59-segmented-1plus1-cloudfront.md).

t55-grade.py grades the pair; this says what each leg alone delivered, which is the media a
receiver with no partner would have lost, and where the two legs disagree in time:

  holes     runs of RTP numbers a leg skipped (a stream-clocked groomer numbers from the stream,
            so a muted or late stretch is a jump in the number), as start offset and seconds
  silences  arrival gaps over --gap-ms on a leg
  cc        continuity errors in the leg's own transport stream
  unpaired  runs of one leg's numbers the other leg never carried within --pair-s

Offsets are seconds from the capture's first datagram.

Usage: t59-leg-report.py legs.pcap [--gap-ms 100] [--pair-s 5] [--json out.json]
"""
import argparse
import json
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from importlib import import_module

grade = import_module("t55-grade")
TS = 188


def runs(items, tol=1.0):
	"""Group sorted (t, n) into runs whose times are within tol of each other."""
	out = []
	for t, n in items:
		if out and t - out[-1][1] <= tol:
			out[-1][1] = t
			out[-1][2] += n
		else:
			out.append([t, t, n])
	return out


def leg_report(leg, t0, gap_ms, rate_dg):
	holes, silences, cc_err, last_cc = [], [], 0, {}
	prev = None
	for t, seq, _, _, p in leg:
		if prev is not None:
			d = grade.sdiff(seq, prev[1])
			if d > 1:
				holes.append((prev[0] - t0, d - 1))
			if (t - prev[0]) * 1000 > gap_ms:
				silences.append((round(prev[0] - t0, 2), round(t - prev[0], 3)))
		prev = (t, seq)
		for i in range(0, len(p) - TS + 1, TS):
			pk = p[i:i + TS]
			pid = ((pk[1] & 0x1F) << 8) | pk[2]
			if pid == 0x1FFF or not (pk[3] & 0x10):
				continue
			cc = pk[3] & 0x0F
			if pid in last_cc and cc not in (last_cc[pid], (last_cc[pid] + 1) % 16):
				cc_err += 1
			last_cc[pid] = cc
	missing = sum(n for _, n in holes)
	return dict(datagrams=len(leg), span_s=round(leg[-1][0] - leg[0][0], 2),
				holes=[(round(a, 2), round(b - a, 2), round(n / rate_dg, 3)) for a, b, n in runs(holes)],
				missing_s=round(missing / rate_dg, 3), silences=silences[:20], cc_errors=cc_err)


def unpaired(x, y, t0, pair_s):
	by_seq = {}
	for t, seq, *_ in y:
		by_seq.setdefault(seq, []).append(t)
	lone = [(t - t0, 1) for t, seq, *_ in x if not any(abs(u - t) <= pair_s for u in by_seq.get(seq, ()))]
	return [(round(a, 2), round(b - a, 2), n) for a, b, n in runs(lone)]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pcap")
	ap.add_argument("--gap-ms", type=float, default=100)
	ap.add_argument("--pair-s", type=float, default=5)
	ap.add_argument("--rate", type=float, default=26e6)
	ap.add_argument("--json")
	o = ap.parse_args()
	a, b = grade.read_legs(o.pcap)
	t0 = min(a[0][0], b[0][0])
	rate_dg = o.rate / (1316 * 8)
	res = dict(a=leg_report(a, t0, o.gap_ms, rate_dg), b=leg_report(b, t0, o.gap_ms, rate_dg),
			   a_start_s=round(a[0][0] - t0, 2), b_start_s=round(b[0][0] - t0, 2),
			   b_not_in_a=unpaired(b, a, t0, o.pair_s), a_not_in_b=unpaired(a, b, t0, o.pair_s))
	print(json.dumps(res))
	if o.json:
		json.dump(res, open(o.json, "w"), indent=1)


if __name__ == "__main__":
	main()
