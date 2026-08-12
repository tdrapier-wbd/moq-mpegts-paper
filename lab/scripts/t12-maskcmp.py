#!/usr/bin/env python3
"""How much of a conflict is the continuity counter?

Compares the two legs datagram by datagram at equal RTP sequence numbers, raw
and with the continuity counter masked, to separate a groomer that placed the
wrong bytes from an upstream stage that renumbered the right ones.
"""
import argparse, importlib.util, os
TS = 188
DEFAULT_ORACLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "t12-merge-oracle.py")

def load(path):
	spec = importlib.util.spec_from_file_location("o", path)
	m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def mask(dg, keep_adaptation):
	out = []
	for i in range(0, len(dg) - TS + 1, TS):
		p = dg[i:i+TS]
		out.append(bytes([p[0], p[1], p[2], p[3] & 0xF0]) + (p[4:] if keep_adaptation else p[12:]))
	return b"".join(out)

ap = argparse.ArgumentParser()
ap.add_argument("--pcap", required=True)
ap.add_argument("--oracle", default=DEFAULT_ORACLE)
ap.add_argument("--leg-a-port", type=int, default=5100)
ap.add_argument("--leg-b-port", type=int, default=5200)
a = ap.parse_args()
o = load(a.oracle)
legs = {a.leg_a_port: {}, a.leg_b_port: {}}
for _, link, frame in o.read_pcap(a.pcap):
	u = o.parse_udp(link, frame)
	if not u: continue
	port, payload = u
	if port not in legs: continue
	r = o.parse_rtp(payload)
	if r: legs[port].setdefault(r[0], r[-1])
A, B = legs[a.leg_a_port], legs[a.leg_b_port]
common = sorted(set(A) & set(B))
n = len(common) or 1
ident = sum(1 for s in common if A[s] == B[s])
cc = sum(1 for s in common if mask(A[s], True) == mask(B[s], True))
both = sum(1 for s in common if mask(A[s], False) == mask(B[s], False))
print(f"sequence numbers on both legs:    {len(common)}  (A {len(A)}, B {len(B)})")
print(f"identical:                        {ident} ({100*ident/n:.2f}%)")
print(f"identical bar continuity counter: {cc} ({100*cc/n:.2f}%)")
print(f"identical bar CC + adaptation:    {both} ({100*both/n:.2f}%)")
