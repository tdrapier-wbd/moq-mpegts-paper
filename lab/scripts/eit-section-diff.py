#!/usr/bin/env python3
"""Compare the SI sections carried on one PID between two transport streams.

    eit-section-diff.py <source.ts> <egress.ts> [--pid 0x0012] [--label NAME]

Counting packets on PID 0x0012 shows that a lane carried *something*; it does not
show that it carried the same table. This decides the stronger question — whether
the same set of sections arrived, byte for byte — which is the only form in which
an EPG claim is worth anything, because a schedule that loses one section loses a
day of it.

Why sections and not tables. An EIT schedule sub-table is sparse: it declares a
`last_section_number` covering its whole multi-day range and transmits only the
segment-boundary sections that carry events. A section demux therefore never
completes it, and any tool that waits for a complete table reports the sub-table
as absent. Both dumps here are taken with `--all-sections` for that reason.

Why occurrence counts are reported but not compared. Two captures of a cycling
carousel almost never cut it at the same phase, so the same section appears a
different number of times in each. The comparison that means something is over
the *distinct* set; the occurrence counts are printed only to show the carousel
was turning at both ends.

Exit status is 0 when the distinct-section sets are identical and 1 otherwise, so
this can be a pass criterion rather than something to read.
"""

import argparse
import collections
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path


def dump_sections(ts_path: Path, pid: int) -> bytes:
    """Raw concatenated sections for one PID, via TSDuck."""
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        out = Path(tmp.name)
    try:
        subprocess.run(
            [
                "tsp", "-I", "file", str(ts_path),
                "-P", "tables", "--pid", hex(pid), "--all-sections",
                "--binary-output", str(out),
                "-O", "drop",
            ],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return out.read_bytes()
    finally:
        out.unlink(missing_ok=True)


def parse_sections(blob: bytes):
    """Split concatenated MPEG sections and pull out the fields worth naming.

    Every long-form section carries its own length, so the blob is self-delimiting;
    a short trailing fragment means a truncated dump and is dropped rather than
    guessed at.
    """
    sections = []
    i = 0
    while i + 3 <= len(blob):
        tid = blob[i]
        length = ((blob[i + 1] & 0x0F) << 8) | blob[i + 2]
        end = i + 3 + length
        if end > len(blob):
            break
        s = blob[i:end]
        sections.append({
            "tid": tid,
            # For EIT the table-id extension is the service id.
            "ext": (s[3] << 8) | s[4] if length >= 5 else None,
            "version": (s[5] >> 1) & 0x1F if length >= 8 else None,
            "section": s[6] if length >= 8 else None,
            "last_section": s[7] if length >= 8 else None,
            "digest": hashlib.sha256(s).hexdigest(),
        })
        i = end
    return sections


def summarise(name, sections):
    distinct = {s["digest"] for s in sections}
    print(f"{name}: {len(sections)} section occurrences, {len(distinct)} distinct")
    by_tid = collections.Counter(s["tid"] for s in sections)
    for tid in sorted(by_tid):
        d = {s["digest"] for s in sections if s["tid"] == tid}
        print(f"    TID 0x{tid:02X}  {by_tid[tid]:5d} occurrences  {len(d):4d} distinct")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("egress", type=Path)
    ap.add_argument("--pid", default="0x0012",
                    help="PID to census (default 0x0012, EIT)")
    ap.add_argument("--label", default="", help="name for the run in the output")
    args = ap.parse_args()

    pid = int(args.pid, 0)
    src = parse_sections(dump_sections(args.source, pid))
    egr = parse_sections(dump_sections(args.egress, pid))

    if args.label:
        print(f"== {args.label}  (PID {args.pid})\n")
    summarise("source", src)
    summarise("egress", egr)

    d_src = {s["digest"] for s in src}
    d_egr = {s["digest"] for s in egr}
    lost, gained = d_src - d_egr, d_egr - d_src

    print()
    print(f"distinct sections lost in transit : {len(lost)}")
    print(f"distinct sections added in transit: {len(gained)}")

    # A schedule that arrived complete but re-declared its own extent would look
    # identical above and still be wrong for a receiver sizing its EPG store.
    print("\ndeclared extent, per sub-table")
    def declared(sections):
        d = collections.defaultdict(set)
        for s in sections:
            if s["last_section"] is not None:
                d[(s["tid"], s["ext"])].add(s["last_section"])
        return d
    ds, de = declared(src), declared(egr)
    for key in sorted(set(ds) | set(de)):
        tid, ext = key
        print(f"    TID 0x{tid:02X} ext {ext}: last_section_number "
              f"src={sorted(ds.get(key, []))} egr={sorted(de.get(key, []))}")

    ok = not lost and not gained and ds == de
    print(f"\nRESULT pid={args.pid} distinct_src={len(d_src)} distinct_egr={len(d_egr)} "
          f"lost={len(lost)} gained={len(gained)} identical={'yes' if ok else 'no'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
