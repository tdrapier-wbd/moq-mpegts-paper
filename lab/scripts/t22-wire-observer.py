#!/usr/bin/env python3
"""Timestamp what a transport stream is doing, tick by tick, for detection timing.

    mpegts-pacer - 11000000 ... | t22-wire-observer.py --tick 0.1 > wire.log

T21's monitor summarises a minute; this one asks a different question and needs a
different resolution. To time a detector you have to know, to a fraction of a
second, the last moment the programme was advancing -- and then the moment each
candidate alarm could first have fired. So every tick prints what arrived and
whether the clock moved, and the detection latencies are read off afterwards
rather than decided here.

The two readings are deliberately separate, because the whole failure mode is
that they disagree:

    bytes       octets that arrived in the tick -- the carrier
    pcr_adv     whether a PCR advanced in the tick -- the programme

A groomer holding a constant bitrate over a dead source emits a byte-perfect
carrier forever. `bytes` stays at the nominal rate and `pcr_adv` goes to zero,
and an alarm watching the first sees nothing wrong.

Reads bytes as they arrive with a short timeout, so a tick with no data at all is
recorded as a tick rather than blocking until the next byte.
"""

import argparse
import os
import select
import sys
import time

PACKET = 188
SYNC = 0x47
PCR_HZ = 27_000_000
PCR_WRAP = 300 * (1 << 33)


def pcr_of(packet):
    """The 27 MHz PCR in `packet`, or None if it carries none."""
    if not packet[3] & 0x20:
        return None
    if packet[4] < 7:
        return None
    if not packet[5] & 0x10:
        return None
    base = (packet[6] << 25) | (packet[7] << 17) | (packet[8] << 9) | (packet[9] << 1) | (packet[10] >> 7)
    ext = ((packet[10] & 0x01) << 8) | packet[11]
    return base * 300 + ext


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tick", type=float, default=0.1, help="seconds per line (default 0.1)")
    ap.add_argument("--pid", type=int, default=None, help="grade this PID instead of discovering it")
    args = ap.parse_args()

    fd = sys.stdin.fileno()
    os.set_blocking(fd, False)

    graded = args.pid
    seen_pcr = {}
    last_pcr = None
    residue = b""

    started = time.time()
    tick_ends = started + args.tick
    bytes_in = 0
    pcr_adv = 0
    pcr_value = 0

    print("epoch,elapsed,bytes,pcr_adv,pcr_ms", flush=True)
    while True:
        ready, _, _ = select.select([fd], [], [], max(0.0, tick_ends - time.time()))
        if ready:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            bytes_in += len(chunk)
            buffer = residue + chunk
            whole = len(buffer) // PACKET * PACKET
            residue = buffer[whole:]
            for at in range(0, whole, PACKET):
                packet = buffer[at : at + PACKET]
                if packet[0] != SYNC:
                    continue
                pid = ((packet[1] & 0x1F) << 8) | packet[2]
                pcr = pcr_of(packet)
                if pcr is None:
                    continue
                if graded is None:
                    if pid in seen_pcr:
                        graded = pid
                    else:
                        seen_pcr[pid] = pcr
                        continue
                if pid != graded:
                    continue
                if last_pcr is not None:
                    delta = pcr - last_pcr
                    if delta < -(PCR_WRAP // 2):
                        delta += PCR_WRAP
                    if delta > 0:
                        pcr_adv += 1
                last_pcr = pcr
                pcr_value = pcr

        now = time.time()
        if now >= tick_ends:
            print(
                f"{now:.3f},{now - started:.3f},{bytes_in},{pcr_adv},{pcr_value / (PCR_HZ / 1000.0):.3f}",
                flush=True,
            )
            bytes_in = 0
            pcr_adv = 0
            while tick_ends <= now:
                tick_ends += args.tick


if __name__ == "__main__":
    main()
