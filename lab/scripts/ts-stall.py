#!/usr/bin/env python3
"""Pass a TS through, but stop reading it for a while.

A forcing function for the question [#2779](https://github.com/moq-dev/moq/issues/2779) asks:
does either leg of a pair ever skip a group? On loopback neither ever does, at any latency
budget, because nothing is ever late — which makes "zero skips" an unfalsifiable reading
until the counter has been shown to fire. Putting this in one leg's pipeline stops that leg
consuming, so its exporter blocks on the write, its consumer buffers, and the latency budget
expires: a group skipped on one leg and kept on the other, which is the divergence the issue
says no field-level determinism can repair.

Usage: moq export ts ... | ts-stall.py <after_s> <for_s> | mpegts-pacer ...
"""

import sys
import time

CHUNK = 188 * 7


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    after, duration = float(sys.argv[1]), float(sys.argv[2])
    start = time.monotonic()
    stalled = False
    while chunk := sys.stdin.buffer.read(CHUNK):
        if not stalled and time.monotonic() - start >= after:
            print(f"ts-stall: not reading for {duration}s", file=sys.stderr, flush=True)
            time.sleep(duration)
            stalled = True
            print("ts-stall: reading again", file=sys.stderr, flush=True)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
