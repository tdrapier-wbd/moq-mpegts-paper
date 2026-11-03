#!/usr/bin/env python3
"""Where two legs' datagrams differ, from one capture: T12's criterion on mismatch placement.

  t12-mismatch-where.py legs.pcap [--leg-a-port 5100] [--leg-b-port 5200] [--from-s 2]

Aligns the legs as t12-merge-oracle.py does (constant sequence offset, by payload identity), then
for each pair present on both legs and differing, compares the seven packets position by position.
A position whose PIDs agree differs in content; one whose PIDs disagree differs in order. Mismatched
pairs are grouped into runs of consecutive datagrams, and each run is tested for a TDT/TOT packet
(PID 0x14) in it or in the datagram either side, on either leg. Pairs earlier than --from-s after
leg B's first datagram are left out.
"""
import argparse
import importlib.util
import os
import statistics
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("oracle", os.path.join(HERE, "t12-merge-oracle.py"))
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)

TDT = 0x14


def pids(body):
	return [(body[i + 1] & 0x1F) << 8 | body[i + 2] for i in range(0, len(body), 188)]


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("pcap")
	ap.add_argument("--leg-a-port", type=int, default=5100)
	ap.add_argument("--leg-b-port", type=int, default=5200)
	ap.add_argument("--from-s", type=float, default=2.0)
	args = ap.parse_args()

	legs = {args.leg_a_port: oracle.Leg("a"), args.leg_b_port: oracle.Leg("b")}
	for t, link, frame in oracle.read_pcap(args.pcap):
		udp = oracle.parse_udp(link, frame)
		if not udp or udp[0] not in legs:
			continue
		rtp = oracle.parse_rtp(udp[1])
		if rtp:
			legs[udp[0]].add(t, rtp[0], rtp[2], rtp[3], rtp[1])
	a, b = legs[args.leg_a_port], legs[args.leg_b_port]
	offset, _, _ = oracle.find_offset(a, b)
	if offset is None:
		sys.exit("the legs do not align")
	t_b = b.span()[0]
	low, high = oracle.merge_window(a, b, offset)

	def tdt_at(index):
		for leg, k in ((a, index), (b, index + offset)):
			got = leg.by_index.get(k)
			if got and TDT in pids(got[1]):
				return True
		return False

	pairs = mism = 0
	content, order = Counter(), Counter()
	runs, run = [], None
	for index in range(low, high + 1):
		ga, gb = a.by_index.get(index), b.by_index.get(index + offset)
		if ga is None or gb is None or ga[0] - t_b < args.from_s:
			continue
		pairs += 1
		if ga[1] == gb[1]:
			run = None
			continue
		mism += 1
		pa, pb = pids(ga[1]), pids(gb[1])
		for k, (x, y) in enumerate(zip(pa, pb)):
			if ga[1][k * 188:(k + 1) * 188] == gb[1][k * 188:(k + 1) * 188]:
				continue
			if x == y:
				content[x] += 1
			else:
				order[tuple(sorted((x, y)))] += 1
		if run and run["end"] == index - 1:
			run["end"], run["t_end"] = index, ga[0] - t_b
		else:
			run = dict(start=index, end=index, t=ga[0] - t_b, t_end=ga[0] - t_b)
			runs.append(run)

	print(f"pairs from {args.from_s:g} s after leg B's first: {pairs}, mismatched {mism} "
		  f"({100.0 * mism / max(pairs, 1):.2f} %)")
	print("differing packets, same PID (content): " +
		  ", ".join(f"{p:#x}={n}" for p, n in content.most_common(8)))
	print("differing packets, different PIDs (order): " +
		  ", ".join(f"{p[0]:#x}/{p[1]:#x}={n}" for p, n in order.most_common(8)))
	if runs:
		lengths = [r["end"] - r["start"] + 1 for r in runs]
		near = sum(any(tdt_at(i) for i in range(r["start"] - 1, r["end"] + 2)) for r in runs)
		gaps = [y["t"] - x["t"] for x, y in zip(runs, runs[1:])]
		print(f"runs {len(runs)}: length median {statistics.median(lengths):g}, max {max(lengths)} datagrams; "
			  f"{near} ({100.0 * near / len(runs):.0f} %) touch a TDT/TOT packet; "
			  f"start interval median {statistics.median(gaps) if gaps else 0:.2f} s")
		tdt_idx = [i for i in range(low, high + 1) if tdt_at(i)]
		print(f"datagrams holding a TDT/TOT packet on either leg: {len(tdt_idx)} of {high - low + 1}")
		# Runs less than 2 s apart are one episode of divergence.
		episodes = []
		for r in runs:
			if episodes and r["t"] - episodes[-1]["t_end"] < 2.0:
				episodes[-1].update(end=r["end"], t_end=r["t_end"])
			else:
				episodes.append(dict(r))
		with_tdt = [e for e in episodes if any(e["start"] - 1 <= i <= e["end"] + 1 for i in tdt_idx)]
		print(f"episodes (runs under 2 s apart) {len(episodes)}: {len(with_tdt)} hold a TDT/TOT packet; "
			  "starts at " + ", ".join(f"{e['t']:.1f}" for e in episodes[:20]) + " s; durations " +
			  ", ".join(f"{e['t_end'] - e['t']:.1f}" for e in episodes[:20]) + " s")


if __name__ == "__main__":
	main()
