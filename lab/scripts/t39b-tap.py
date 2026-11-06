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

  `bytes --thin EVERY:PACKETS[:PID,...]` drops packets of the listed PIDs (default null stuffing,
  8191) from the first PACKETS until one in EVERY is missing, the loss an import that starts on a
  damaged window measures its multiplex rate through (T21), and logs `thin_end` with the packets
  dropped. Video and audio are spared: a loss spread over every PID damages nearly every video
  frame, the import refuses them, and no export starts until the thinning ends. Offsets count the
  input, before anything is dropped.

Usage:
  t39b-tap.py bytes --log marks.tsv [--mark onset:15040000 --mark end:52640000] < in > out
  t39b-tap.py bytes --log marks.tsv --thin 500:500000 < in > out
  t39b-tap.py lines < jsonl > stamped.tsv
"""

import argparse
import os
import sys
import time


def write_all(data):
    view = memoryview(data)
    while view:
        view = view[os.write(1, view):]


def tap_bytes(log_path, marks, thin=None):
    pending = sorted(marks, key=lambda m: m[1])
    seen = 0
    every, limit, pids = thin or (0, 0, ())
    packet = dropped = 0
    carry = b""
    with open(log_path, "w") as log:

        def note(name, offset):
            log.write(f"{time.time():.3f}\t{name}\t{offset}\n")
            log.flush()

        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                write_all(carry)
                note("eof", seen)
                return
            if seen == 0:
                note("first", 0)
            seen += len(chunk)
            while pending and pending[0][1] < seen:
                note(*pending.pop(0))
            if packet >= limit:
                write_all(chunk)
                continue
            data = carry + chunk
            whole = len(data) - len(data) % 188
            kept = bytearray()
            for off in range(0, whole, 188):
                listed = ((data[off + 1] & 0x1F) << 8 | data[off + 2]) in pids
                if packet < limit and listed and dropped < (packet + 1) // every:
                    dropped += 1
                else:
                    kept += data[off:off + 188]
                packet += 1
            carry = data[whole:]
            write_all(kept)
            if packet >= limit:
                note("thin_end", f"{packet} dropped={dropped}")
                write_all(carry)
                carry = b""


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
    b.add_argument("--thin", help="EVERY:PACKETS[:PID,...], drop listed PIDs to one in EVERY of the first PACKETS")
    sub.add_parser("lines")
    args = ap.parse_args()
    if args.mode == "bytes":
        marks = []
        for m in args.mark:
            name, _, offset = m.partition(":")
            marks.append((name, int(offset)))
        thin = None
        if args.thin:
            every, limit, *rest = args.thin.split(":")
            pids = frozenset(int(p) for p in rest[0].split(",")) if rest else frozenset({0x1FFF})
            thin = (int(every), int(limit), pids)
            if thin[0] < 2 or thin[1] < 1 or not pids <= set(range(0x2000)):
                ap.error("--thin needs EVERY >= 2, PACKETS >= 1 and PIDs below 8192")
        tap_bytes(args.log, marks, thin)
    else:
        tap_lines()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
