#!/usr/bin/env python3
"""Attribute hang-catalog publishes to what changed, for #2882.

Reads the JSONL that `si-catalog-cost.rs` writes — one record per catalog publish, carrying the
plaintext, DEFLATE and MSF byte counts, the position in the source at which it happened, and the
catalog itself — and answers the two questions the issue is gated on: how much of the catalog is
carried SI, and what a change to it costs.

Three things are separated because they scale differently and are paid by different people:

  standing size   what a subscriber pays once, at join, ahead of media discovery.
  acquisition     the publishes that assemble the SI set one section at a time. Each is a
                  complete document asserting an incomplete multiplex, which is the coherence
                  problem in #2881 rather than a cost.
  junction        the burst of republishes when a table turns over. This is the recurring cost,
                  and it is the product of two terms that both grow with service count.

A consumer reads one of the three tracks, so its own cost is that column alone; the producer and
relay carry all three. The MSF column is reported separately because the MSF catalog is derived
from the media sections only — an SI-only change appends a byte-identical group to it, which the
digest count here checks rather than assumes.

Usage: si-catalog-cost.py <publishes.jsonl> [label] [--rate BPS]
"""

import hashlib
import json
import sys

# Publishes closer together than this in source time belong to the same burst. An SI table is
# repeated on a multi-second cycle, so any real gap is far larger and any burst far smaller.
BURST_GAP_S = 3.0


def si_of(cat):
    return (cat or {}).get("mpegts", {}).get("si", {}) or {}


def without_si(cat):
    """The catalog as it would be if the sections lived on their own track.

    The PID and its cadence stay — that is the descriptor the alternative keeps in the catalog —
    so this is the difference the move would make, not the whole `mpegts` section.
    """
    c = json.loads(json.dumps(cat or {}))
    for entry in si_of(c).values():
        entry.pop("sections", None)
    return c


def binary_bytes(cat):
    """The same sections as binary: what they would cost on a track, without base64 or JSON."""
    return sum((len(s) * 3) // 4 for e in si_of(cat).values() for s in e.get("sections", []))


def bursts(pubs, rate):
    out = [[pubs[0]]]
    for p in pubs[1:]:
        gap = (p["at"] - out[-1][-1]["at"]) * 8 / rate if rate else 0
        (out.append([p]) if gap > BURST_GAP_S else out[-1].append(p))
    return out


def total(seg, key):
    return sum(p[key] or 0 for p in seg)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rate = next((int(a.split("=", 1)[1]) for a in sys.argv[1:] if a.startswith("--rate=")), 0)
    if not 1 <= len(args) <= 2:
        sys.exit(__doc__)
    path, label = args[0], (args[1] if len(args) > 1 else args[0])

    pubs = [json.loads(line) for line in open(path)]
    if not pubs:
        sys.exit("no publishes")

    final = pubs[-1]["catalog"]
    si_share = len(json.dumps(final)) - len(json.dumps(without_si(final)))

    print(f"== {label}")
    print(f"publishes                {len(pubs)}")
    print(f"standing catalog         {pubs[-1]['plain']:,} B plain, {pubs[-1]['z']:,} B deflate")
    print(f"  carried SI             {si_share:,} B, {100.0 * si_share / pubs[-1]['plain']:.1f} % of the document")
    print(f"  as binary sections     {binary_bytes(final):,} B")

    groups = bursts(pubs, rate) if rate else [pubs]
    if rate and len(groups) > 1:
        first, last = groups[0], groups[-1]
        span = (last[-1]["at"] - last[0]["at"]) * 8 / rate
        acq = [p for g in groups[:-1] for p in g]
        print(f"acquisition              {len(acq)} publishes assembling the set one section at a time")
        print(f"  cost                   {total(acq, 'plain'):,} B plain, {total(acq, 'z'):,} B deflate")
        print(f"junction                 {len(last)} republishes over {span:.2f} s of source")
        print(
            f"  cost                   {total(last, 'plain'):,} B plain, "
            f"{total(last, 'z'):,} B deflate, {total(last, 'msf'):,} B msf"
        )
        del first

    digests = {hashlib.sha256((p.get("msf_payload") or "").encode()).hexdigest() for p in pubs}
    print(f"msf catalog              {len(pubs)} groups, {len(digests)} distinct, {total(pubs, 'msf'):,} B")

    for pid, entry in sorted(si_of(final).items(), key=lambda kv: int(kv[0])):
        sections = entry.get("sections", [])
        b = sum((len(s) * 3) // 4 for s in sections)
        print(f"  PID 0x{int(pid):04x}             {len(sections)} sections, {b:,} B binary, interval {entry.get('interval')} ms")


if __name__ == "__main__":
    main()
