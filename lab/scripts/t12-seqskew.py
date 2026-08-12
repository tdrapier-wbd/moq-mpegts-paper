#!/usr/bin/env python3
"""Arrival skew between the two legs at equal RTP sequence numbers.

t12-merge-oracle.py recovers the sequence offset between the legs by voting on
payload identity, and pairs datagrams through that offset to report skew. Where
the legs are not byte-identical — an upstream stage renumbering continuity
counters is enough — the vote has almost nothing to go on, and both the offset
and the skew derived from it are noise. This asks the same question without a
correlator: for every sequence number both legs sent, how far apart were they?
"""
import argparse
import importlib.util
import os
import statistics

DEFAULT_ORACLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t12-merge-oracle.py")

ap = argparse.ArgumentParser()
ap.add_argument("--pcap", required=True)
ap.add_argument("--oracle", default=DEFAULT_ORACLE)
ap.add_argument("--leg-a-port", type=int, default=5100)
ap.add_argument("--leg-b-port", type=int, default=5200)
args = ap.parse_args()

spec = importlib.util.spec_from_file_location("oracle", args.oracle)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)

legs = {args.leg_a_port: {}, args.leg_b_port: {}}
for timestamp, link, frame in oracle.read_pcap(args.pcap):
	udp = oracle.parse_udp(link, frame)
	if not udp:
		continue
	port, payload = udp
	if port not in legs:
		continue
	rtp = oracle.parse_rtp(payload)
	if rtp:
		legs[port].setdefault(rtp[0], timestamp)

a, b = legs[args.leg_a_port], legs[args.leg_b_port]
common = sorted(set(a) & set(b))
print(f"common sequence numbers:      {len(common)}  (A {len(a)}, B {len(b)})")
if common:
	deltas = sorted((b[s] - a[s]) * 1000.0 for s in common)
	print(
		f"skew at equal sequence (b-a): median {statistics.median(deltas):.3f} ms, "
		f"min {deltas[0]:.3f}, max {deltas[-1]:.3f}"
	)
