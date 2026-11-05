#!/usr/bin/env python3
"""Wall-clock taps for T39 Part B: when a byte passes, and when a line arrives.

T39 Part B times a fault from its onset at the publisher to the alarm a publisher-side reader
draws from the subscriber's feedback. Both ends need wall time, and neither tool in the path
gives it: the stimulus is a file, and `moq export echo` prints JSON lines with no arrival time.

  bytes  copy stdin to stdout unchanged, and log the wall time at which the stream's first
         byte, each `--mark NAME:OFFSET` byte offset, and its end pass. Placed between the
         regulator and the importer, a mark is the instant the importer is handed that byte,
         to within a pipe buffer (64 KiB, about 50 ms at 10 Mb/s).
  lines  prefix each stdin line with the wall time it arrived and a tab.

Usage:
  t39b-tap.py bytes --log marks.tsv [--mark onset:15040000 --mark end:52640000] < in > out
  t39b-tap.py lines < jsonl > stamped.tsv
"""

import argparse
import os
import sys
import time


def tap_bytes(log_path, marks):
    pending = sorted(marks, key=lambda m: m[1])
    seen = 0
    with open(log_path, "w") as log:

        def note(name, offset):
            log.write(f"{time.time():.3f}\t{name}\t{offset}\n")
            log.flush()

        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                note("eof", seen)
                return
            if seen == 0:
                note("first", 0)
            seen += len(chunk)
            while pending and pending[0][1] < seen:
                note(*pending.pop(0))
            view = memoryview(chunk)
            while view:
                view = view[os.write(1, view):]


def tap_lines():
    out = sys.stdout
    for line in iter(sys.stdin.buffer.readline, b""):
        out.write(f"{time.time():.3f}\t{line.decode('utf-8', 'replace').rstrip()}\n")
        out.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    b = sub.add_parser("bytes")
    b.add_argument("--log", required=True)
    b.add_argument("--mark", action="append", default=[], help="NAME:BYTE_OFFSET")
    sub.add_parser("lines")
    args = ap.parse_args()
    if args.mode == "bytes":
        marks = []
        for m in args.mark:
            name, _, offset = m.partition(":")
            marks.append((name, int(offset)))
        tap_bytes(args.log, marks)
    else:
        tap_lines()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
