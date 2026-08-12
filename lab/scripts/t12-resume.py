#!/usr/bin/env python3
"""What a leg's RTP numbering does across an outage, and whether it rejoins the pair.

A groomer that stops emitting when its source dies is detectable, which is what a
1+1 receiver needs. But detection only buys a switch *away*; coming back needs the
resumed leg to re-enter the numbering its partner has been using all along. Those
are separate properties and only the second one restores the pair.

This measures the second. It needs no payload identity between the legs — which
matters, because the legs of an independently groomed pair are not payload
identical even when both are healthy — so it works where a merge oracle cannot:

  gap             the outage, as the largest inter-arrival silence on the leg
  seq advance     how far that leg's RTP sequence moved across its own gap
  partner advance how many datagrams the surviving leg emitted in the same window

A leg numbering from its own send count resumes at +1 and is left short by the
whole outage. A leg numbering from output position resumes at the partner's
count, and the pair is mergeable again on the far side.

Usage: t12-resume.py --pcap cap.pcap [--leg-a-port 5100] [--leg-b-port 5200]
                     [--min-gap-ms 250]
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
	"t12_oracle", pathlib.Path(__file__).with_name("t12-merge-oracle.py")
)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)


def largest_gap(leg):
	"""(before, after) datagrams bracketing the leg's longest silence."""
	widest = None
	for earlier, later in zip(leg.packets, leg.packets[1:]):
		gap = later[0] - earlier[0]
		if widest is None or gap > widest[0]:
			widest = (gap, earlier, later)
	return widest


def emitted_between(leg, start, end):
	return sum(1 for time, _, _ in leg.packets if start < time <= end)


def content_span(leg, start, end):
	"""Datagrams carrying programme in a window, to tell a resumed leg from a
	resumed carrier."""
	return sum(
		1
		for time, _, payload in leg.packets
		if start < time <= end and oracle.carries_content(payload)
	)


def report(name, leg, partner, min_gap_ms):
	widest = largest_gap(leg)
	if widest is None:
		print(f"leg {name}: fewer than two datagrams")
		return
	gap_s, (time_before, index_before, _), (time_after, index_after, _) = widest
	if gap_s * 1000.0 < min_gap_ms:
		print(f"leg {name}: no outage (longest silence {gap_s * 1000.0:.1f} ms)")
		return

	own = index_after - index_before
	theirs = emitted_between(partner, time_before, time_after)
	end = leg.packets[-1][0]
	resumed = sum(1 for time, _, _ in leg.packets if time >= time_after)
	carried = content_span(leg, time_before, end)

	print(f"leg {name}: outage {gap_s * 1000.0:.0f} ms, then {resumed} datagrams "
	      f"over {end - time_after:.1f} s")
	print(f"  own sequence advanced   {own:+d} across its own outage")
	print(f"  partner emitted         {theirs} datagrams in the same window")
	print(f"  numbering deficit       {theirs - own} datagrams "
	      f"({'rejoins the pair' if theirs == own else 'resumes misnumbered'})")
	print(f"  programme after resume  {carried} of {resumed} datagrams carry content")


def main():
	parser = argparse.ArgumentParser(description="RTP numbering across an outage")
	parser.add_argument("--pcap", required=True)
	parser.add_argument("--leg-a-port", type=int, default=5100)
	parser.add_argument("--leg-b-port", type=int, default=5200)
	parser.add_argument("--min-gap-ms", type=float, default=250.0,
	                    help="silence below this is ordinary jitter, not an outage")
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

	report("a", leg_a, leg_b, args.min_gap_ms)
	report("b", leg_b, leg_a, args.min_gap_ms)


if __name__ == "__main__":
	main()
