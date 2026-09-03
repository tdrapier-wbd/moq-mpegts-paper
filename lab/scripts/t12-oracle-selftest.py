#!/usr/bin/env python3
"""Adversarial tests for the ST 2022-7 selection rules in t12-merge-oracle.py.

	t12-oracle-selftest.py            # run every case
	t12-oracle-selftest.py --rules    # print the rule-by-rule verdict table only

Every 1+1 result this campaign has published was graded by `t12-merge-oracle.py`, and until
now the only thing exercising it was live capture: whatever the two legs happened to do on the
day. That leaves the selection rules themselves untested, and it leaves the oracle's *choices*
indistinguishable from the standard's *requirements*, which is the more expensive of the two
problems. These cases drive the selection functions directly, with legs built packet by packet,
so each rule can be put under a condition that a live run cannot be asked to produce.

Read the verdict column before the assertions. It is the point of the file:

	MATCHES: the oracle does what ST 2022-7 requires of a receiver.
	UNSPECIFIED: the input violates a precondition of the standard, so the standard
	requires nothing and the oracle's behaviour is a documented choice.
	NOT MODELLED: the oracle operates in a domain where the rule does not apply, so
	passing here is not evidence about the rule.
	BLIND SPOT: the oracle neither implements nor reports the condition.

Passing this file does not make the oracle reference compliant, and it is not offered as
evidence that it is. ST 2022-7 is a receiver specification whose conformance is decided by a
receiver; what these cases establish is narrower and worth having anyway: that the selection
the oracle performs is the selection it is documented to perform, that it is stable under the
adversarial inputs a redundant pair actually produces, and that the places where it departs
from the standard or is silent are enumerated rather than discovered later. The hardware gate
is a separate and still-blocked activity.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load_oracle():
	spec = importlib.util.spec_from_file_location(
		"merge_oracle", os.path.join(HERE, "t12-merge-oracle.py")
	)
	module = importlib.util.module_from_spec(spec)
	spec.loader.exec_module(module)
	return module


ORACLE = load_oracle()

TS_PACKET, NULL_PID = ORACLE.TS_PACKET, ORACLE.NULL_PID


def ts(pid=0x0100, cc=0, fill=0x00):
	"""One TS packet with a payload, so the oracle counts it as content."""
	b = bytearray(b"\xff" * TS_PACKET)
	b[0] = 0x47
	b[1] = (pid >> 8) & 0x1F
	b[2] = pid & 0xFF
	b[3] = 0x10 | (cc & 0x0F)
	b[4] = fill
	return bytes(b)


def leg(name, entries):
	"""Build a leg from (sequence, payload) or (sequence, payload, time, ssrc, stamp)."""
	lg = ORACLE.Leg(name)
	for i, entry in enumerate(entries):
		sequence, payload = entry[0], entry[1]
		when = entry[2] if len(entry) > 2 else 0.001 * i
		ssrc = entry[3] if len(entry) > 3 else 0xAAAA
		stamp = entry[4] if len(entry) > 4 else 3000 + 3 * i
		lg.add(when, sequence, ssrc, payload, stamp)
	return lg


def merge(leg_a, leg_b, offset=None):
	"""Run the oracle's reconstruction and return its summary."""
	if offset is None:
		offset = ORACLE.find_offset(leg_a, leg_b)[0]
	with tempfile.NamedTemporaryFile(suffix=".ts", delete=False) as tmp:
		path = tmp.name
	try:
		return ORACLE.seq_merge(leg_a, leg_b, offset, path), open(path, "rb").read()
	finally:
		os.unlink(path)


class Case:
	"""One adversarial condition, with the rule and the oracle's behaviour stated apart."""

	def __init__(self, name, rule, behaviour, verdict):
		self.name = name
		self.rule = rule
		self.behaviour = behaviour
		self.verdict = verdict
		self.checks = []

	def expect(self, what, got, want):
		self.checks.append((what, got == want, got, want))
		return self

	@property
	def ok(self):
		return all(passed for _, passed, _, _ in self.checks)


CASES = []


def case(name, rule, behaviour, verdict):
	c = Case(name, rule, behaviour, verdict)
	CASES.append(c)
	return c


# ---------------------------------------------------------------- baseline ----
def t_identical():
	c = case(
		"identical legs",
		"a merged output must equal either leg, with no loss and no discontinuity",
		"takes every sequence number from leg A; no loss, no conflict",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	a = leg("a", [(100 + i, p) for i, p in enumerate(payloads)])
	b = leg("b", [(100 + i, p) for i, p in enumerate(payloads)])
	summary, out = merge(a, b)
	c.expect("lost datagrams", summary["lost_datagrams"], 0)
	c.expect("conflicts", summary["conflicts"], 0)
	c.expect("taken from A", summary["from_a"], 20)
	c.expect("taken from B", summary["from_b"], 0)
	c.expect("output equals leg A's bytes", out, b"".join(payloads))


# ------------------------------------------------------------ one leg late ----
def t_late_leg():
	c = case(
		"one leg arriving late",
		"each sequence number is taken from whichever leg delivered it, so a constant "
		"delay on one leg is absorbed and the output is unchanged",
		"selects on sequence number alone and ignores arrival time, so the reconstructed "
		"bytes are identical at any skew; the merge window opens once both legs are live, "
		"so startup skew is not counted as loss",
		"MATCHES in the byte domain, NOT MODELLED in the time domain",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	a = leg("a", [(100 + i, p, 0.001 * i) for i, p in enumerate(payloads)])
	# Same sequence numbers, every datagram 200 ms later.
	b = leg("b", [(100 + i, p, 0.200 + 0.001 * i) for i, p in enumerate(payloads)])
	summary, out = merge(a, b)
	c.expect("lost datagrams", summary["lost_datagrams"], 0)
	c.expect("output unchanged by the skew", out, b"".join(payloads))
	# The thing the oracle does not do: it never prefers the earlier arrival, because it
	# has no reason to. On a pair the standard requires to be identical the bytes are the
	# same either way, but that also means the oracle cannot answer how deep a receiver's
	# buffer had to be, and it must not be read as if it could.
	skewed, _ = merge(b, a)
	c.expect("selection is arrival-order independent", skewed["from_a"], 20)


# ----------------------------------------------------------- gap on one leg ----
def t_gap_one_leg():
	c = case(
		"one leg with a gap",
		"a gap on one leg must be covered by the other, with no output discontinuity",
		"fills the missing indices from leg B and reports them as covered_by_b",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	holes = {5, 6, 7}
	a = leg("a", [(100 + i, p) for i, p in enumerate(payloads) if i not in holes])
	b = leg("b", [(100 + i, p) for i, p in enumerate(payloads)])
	summary, out = merge(a, b, offset=0)
	c.expect("lost datagrams", summary["lost_datagrams"], 0)
	c.expect("covered by B", summary["covered_by_b"], len(holes))
	c.expect("gap runs in the output", summary["gap_runs"], 0)
	c.expect("output is whole", out, b"".join(payloads))


def t_gap_both_legs():
	c = case(
		"both legs missing the same sequence numbers",
		"a datagram lost on both legs is unrecoverable; the receiver outputs a "
		"discontinuity rather than inventing one",
		"counts it lost, records the gap run and writes nothing for it",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	holes = {8, 9}
	kept = [(100 + i, p) for i, p in enumerate(payloads) if i not in holes]
	summary, out = merge(leg("a", kept), leg("b", kept), offset=0)
	c.expect("lost datagrams", summary["lost_datagrams"], len(holes))
	c.expect("gap runs", summary["gap_runs"], 1)
	c.expect("longest gap", summary["longest_gap_datagrams"], len(holes))
	c.expect("output omits the lost pair", len(out), (20 - len(holes)) * TS_PACKET)


def t_loss_then_recovery():
	c = case(
		"packet loss followed by recovery",
		"after an outage the receiver resumes on the next sequence number it has, and the "
		"gap is bounded by the outage rather than persisting",
		"one gap run of the outage's length, then complete output; loss does not "
		"desynchronise the merge that follows it",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(40)]
	outage = set(range(10, 20))
	kept = [(100 + i, p) for i, p in enumerate(payloads) if i not in outage]
	summary, _ = merge(leg("a", kept), leg("b", kept), offset=0)
	c.expect("gap runs", summary["gap_runs"], 1)
	c.expect("longest gap", summary["longest_gap_datagrams"], len(outage))
	c.expect("datagrams after recovery", summary["from_a"], 40 - len(outage))
	# The recovery half must be whole: a merge that lost its place would keep dropping.
	c.expect("no loss beyond the outage", summary["lost_datagrams"], len(outage))


# -------------------------------------------------- equal sequence, differs ----
def t_conflicting_payloads():
	c = case(
		"equal sequence numbers, different payloads",
		"nothing. ST 2022-7 requires the two streams to be packet identical, so this input "
		"violates a precondition of the standard and no selection rule applies to it",
		"counts every disagreement as a conflict and then takes leg A deterministically. "
		"That is a choice made so the output is reproducible, not a rule being followed, "
		"and a real receiver may take either leg",
		"UNSPECIFIED",
	)
	a_pay = [ts(cc=i % 16, fill=i) for i in range(20)]
	b_pay = [ts(cc=i % 16, fill=i + 128) for i in range(20)]  # same slots, different bytes
	a = leg("a", [(100 + i, p) for i, p in enumerate(a_pay)])
	b = leg("b", [(100 + i, p) for i, p in enumerate(b_pay)])
	summary, out = merge(a, b, offset=0)
	c.expect("conflicts counted", summary["conflicts"], 20)
	c.expect("leg A wins every conflict", out, b"".join(a_pay))
	c.expect("no loss reported", summary["lost_datagrams"], 0)
	# And the documented consequence: offset voting is payload identity, so on this pair it
	# has nothing to vote with. The oracle's own README says to use the mask tools instead.
	offset, votes, total = ORACLE.find_offset(a, b)
	c.expect("offset voting finds no agreement", votes, 0)
	c.expect("offset voting reports no votes at all", total, 0)


def t_partial_conflict_poisons_offset():
	c = case(
		"a pair differing in one field only",
		"nothing about offset recovery; a receiver is told the sequence numbers are "
		"aligned and does not have to infer an offset at all",
		"infers the offset by voting on payload identity, so a pair that differs in any "
		"one field leaves it voting on whatever few datagrams happen to agree, and it can "
		"return a spurious offset with high confidence in it",
		"NOT MODELLED, and a known limit of this implementation",
	)
	# Legs agree on two datagrams and differ on the rest, which is the shape a continuity
	# counter offset produces. The vote is then decided by the accident of which agree.
	a_entries, b_entries = [], []
	for i in range(20):
		same = i in (3, 11)
		a_entries.append((100 + i, ts(cc=i % 16, fill=i)))
		b_entries.append((100 + i, ts(cc=i % 16, fill=i if same else i + 64)))
	offset, votes, total = ORACLE.find_offset(leg("a", a_entries), leg("b", b_entries))
	c.expect("offset is decided by a handful of datagrams", votes, 2)
	c.expect("and those are all the votes there were", total, 2)
	c.expect("the offset it returns is nonetheless 0 here", offset, 0)


# ---------------------------------------------------------------- duplicates ----
def t_duplicates_within_leg():
	c = case(
		"duplicated packets within one leg",
		"a receiver keeps one copy of each sequence number and discards later repeats",
		"keeps the first copy seen and drops the rest, so a duplicate never reaches the "
		"output",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(10)]
	entries = [(100 + i, p) for i, p in enumerate(payloads)]
	doubled = entries[:4] + [entries[3], entries[3]] + entries[4:]
	a = leg("a", doubled)
	b = leg("b", entries)
	summary, out = merge(a, b, offset=0)
	c.expect("datagrams in the window", summary["datagrams"], 10)
	c.expect("output has no repeat", out, b"".join(payloads))
	c.expect("no conflict from the repeat", summary["conflicts"], 0)


def t_duplicate_with_different_payload():
	c = case(
		"a duplicate sequence number whose payload differs",
		"a receiver may keep the first and discard the second; the condition means the "
		"sender is malformed, and detecting it is not required",
		"keeps the first copy silently. The second is not compared, not counted and not "
		"reported anywhere, so a leg that renumbers onto a live sequence number looks "
		"clean in every figure the oracle produces",
		"BLIND SPOT",
	)
	first = ts(fill=1)
	second = ts(fill=2)
	a = leg("a", [(100, first), (100, second), (101, ts(fill=3))])
	b = leg("b", [(100, first), (101, ts(fill=3))])
	summary, out = merge(a, b, offset=0)
	c.expect("the first copy is the one used", out[:TS_PACKET], first)
	c.expect("the disagreement is not counted as a conflict", summary["conflicts"], 0)
	# Pinning the silence: nothing in the summary rises when a leg contradicts itself.
	clean, _ = merge(leg("a", [(100, first), (101, ts(fill=3))]), b, offset=0)
	c.expect(
		"summary is indistinguishable from a clean leg",
		{k: summary[k] for k in ("lost_datagrams", "conflicts", "from_a", "from_b")},
		{k: clean[k] for k in ("lost_datagrams", "conflicts", "from_a", "from_b")},
	)


# ------------------------------------------------------------- RTP headers ----
def t_rtp_headers_differ():
	c = case(
		"differing RTP headers, identical TS payload",
		"the merge is keyed on the RTP sequence number and decided by payload identity; "
		"SSRC and timestamp differences do not make the pair unmergeable, though a "
		"receiver reads timestamps for its own buffer",
		"compares TS payload only, so header differences raise no conflict, and reports "
		"timestamp agreement separately as a figure rather than as a failure",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	a = leg("a", [(100 + i, p, 0.001 * i, 0x1111, 9000 + 3 * i) for i, p in enumerate(payloads)])
	# Different SSRC, different RTP timestamps, same payload bytes and sequence numbers.
	b = leg("b", [(100 + i, p, 0.001 * i, 0x2222, 5000 + 7 * i) for i, p in enumerate(payloads)])
	summary, out = merge(a, b, offset=0)
	align = ORACLE.alignment(a, b, 0)
	c.expect("no conflicts from the headers", summary["conflicts"], 0)
	c.expect("payload identity is total", align["yield_pct"], 100.0)
	c.expect("timestamp disagreement is reported", align["rtp_timestamp_identical_pct"], 0.0)
	c.expect("output is still whole", out, b"".join(payloads))
	c.expect("the two SSRCs are both recorded", len(a.ssrcs | b.ssrcs), 2)


# --------------------------------------------------------- sequence wrap ----
def t_sequence_wrap():
	c = case(
		"the RTP sequence number wrapping 65535 to 0",
		"the merge continues across the wrap; a 16-bit field rolling over is not a "
		"discontinuity",
		"extends each leg's sequence into an epoch-tagged index, so the wrap is monotone "
		"internally and the merge window spans it",
		"MATCHES",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	seqs = [(65530 + i) % 65536 for i in range(20)]  # 65530..65535, 0..13
	a = leg("a", list(zip(seqs, payloads)))
	b = leg("b", list(zip(seqs, payloads)))
	summary, out = merge(a, b, offset=0)
	c.expect("every datagram is in one window", summary["datagrams"], 20)
	c.expect("nothing is lost across the wrap", summary["lost_datagrams"], 0)
	c.expect("output is in wire order", out, b"".join(payloads))
	low, high = ORACLE.merge_window(a, b, 0)
	c.expect("the window is contiguous across the wrap", high - low + 1, 20)


# ------------------------------------------------------------------- PCR ----
def t_pcr_wrap():
	c = case(
		"PCR wrap inside the payload",
		"nothing. PCR is carried inside the RTP payload, and a wrap changes those bytes "
		"identically on both legs, so it cannot affect which leg is selected",
		"has no PCR awareness at all: the bytes are opaque to it and the wrap passes "
		"through the merge untouched",
		"NOT MODELLED",
	)
	# Two payloads whose PCR values straddle the 33-bit boundary. Identical on both legs,
	# which is the only case the standard admits, so selection must be a no-op.
	before = ts(fill=0xFE)
	after = ts(fill=0x01)
	a = leg("a", [(100, before), (101, after)])
	b = leg("b", [(100, before), (101, after)])
	summary, out = merge(a, b, offset=0)
	c.expect("the wrap is passed through", out, before + after)
	c.expect("no conflict", summary["conflicts"], 0)
	c.expect("no loss", summary["lost_datagrams"], 0)
	# Said plainly, because it is the answer to "does the oracle handle PCR wrap": the
	# merged output's PCR conformance is graded by ts-pcr-timing.py, not here.
	c.expect("the oracle exposes no PCR figure to grade", hasattr(ORACLE, "parse_pcr"), False)


def t_source_clock_offset():
	c = case(
		"source-clock offset between the legs",
		"two legs of a 2022-7 pair come from one source and share its clock; independent "
		"clocks would make them different streams, which the standard does not admit",
		"selects on sequence number and never reads a clock, so an offset reaches it only "
		"as arrival skew, which selection ignores. It cannot detect the condition",
		"NOT MODELLED",
	)
	payloads = [ts(cc=i % 16, fill=i) for i in range(20)]
	a = leg("a", [(100 + i, p, 0.020 * i) for i, p in enumerate(payloads)])
	# Leg B's datagrams drift steadily later, as a slightly faster source clock would show.
	b = leg("b", [(100 + i, p, 0.020 * i * 1.001) for i, p in enumerate(payloads)])
	summary, out = merge(a, b, offset=0)
	c.expect("output is unaffected", out, b"".join(payloads))
	c.expect("no loss", summary["lost_datagrams"], 0)
	c.expect("and no figure changes", summary["conflicts"], 0)


# ------------------------------------------------------------------ content ----
def t_stuffing_only_leg():
	c = case(
		"a leg supplying every sequence number as stuffing",
		"a receiver following sequence numbers alone cannot tell a dead source from a live "
		"one; loss is not the only way a merged output goes dark",
		"counts content-bearing datagrams separately from delivered ones, so a leg whose "
		"source has failed shows as complete delivery at reduced content_pct",
		"MATCHES, and the reason the content figure exists",
	)
	null = bytearray(b"\xff" * TS_PACKET)
	null[0] = 0x47
	null[1] = (NULL_PID >> 8) & 0x1F
	null[2] = NULL_PID & 0xFF
	null[3] = 0x20  # adaptation only, no payload: the oracle's definition of no content
	dead = bytes(null)
	live = [ts(cc=i % 16, fill=i) for i in range(10)]
	a = leg("a", [(100 + i, dead) for i in range(10)])
	b = leg("b", [(100 + i, p) for i, p in enumerate(live)])
	summary, _ = merge(a, b, offset=0)
	c.expect("delivery looks complete", summary["lost_datagrams"], 0)
	c.expect("content is nil", summary["content_datagrams"], 0)
	c.expect("content_pct says so", summary["content_pct"], 0.0)


TESTS = [
	t_identical,
	t_late_leg,
	t_gap_one_leg,
	t_gap_both_legs,
	t_loss_then_recovery,
	t_conflicting_payloads,
	t_partial_conflict_poisons_offset,
	t_duplicates_within_leg,
	t_duplicate_with_different_payload,
	t_rtp_headers_differ,
	t_sequence_wrap,
	t_pcr_wrap,
	t_source_clock_offset,
	t_stuffing_only_leg,
]


def print_rules():
	print("ST 2022-7 selection rules, as required and as implemented\n")
	for c in CASES:
		print(f"  {c.name}")
		print(f"    verdict   {c.verdict}")
		print(f"    rule      {c.rule}")
		print(f"    oracle    {c.behaviour}\n")


def main():
	ap = argparse.ArgumentParser(
		description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
	)
	ap.add_argument("--rules", action="store_true", help="print the verdict table and exit")
	args = ap.parse_args()

	for t in TESTS:
		t()

	if args.rules:
		print_rules()
		return 0

	failures = total = 0
	for c in CASES:
		total += len(c.checks)
		mark = "ok  " if c.ok else "FAIL"
		print(f"  {mark}  {c.name:44s} {c.verdict}")
		for what, passed, got, want in c.checks:
			if not passed:
				failures += 1
				print(f"          {what}: expected {want!r}, got {got!r}")

	verdicts = {}
	for c in CASES:
		key = c.verdict.split(",")[0]
		verdicts[key] = verdicts.get(key, 0) + 1

	print(f"\n{len(CASES)} conditions, {total} assertions, {failures} failed")
	print("  " + ", ".join(f"{n} {k}" for k, n in sorted(verdicts.items())))
	if failures:
		print("\nselftest FAILED")
		return 1
	print(
		"\nselftest passed. This says the oracle's selection is the selection it documents,"
		"\nunder inputs a live run cannot be asked to produce. It is not a conformance"
		"\nstatement: ST 2022-7 conformance is decided by a receiver, and the hardware gate"
		"\nremains blocked."
	)
	return 0


if __name__ == "__main__":
	sys.exit(main())
