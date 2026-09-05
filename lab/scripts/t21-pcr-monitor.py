#!/usr/bin/env python3
"""Grade a transport stream continuously, one summary line per window.

    mpegts-pacer - 11000000 ... | t21-pcr-monitor.py --window 60 --pid 111

`ts-pcr-timing.py` grades a *window* and exits, which is the right shape for an
experiment that asks whether a build is conformant. A permanence soak asks a
different question -- whether it is *still* conformant at hour forty -- and that
needs the same checks emitted repeatedly for as long as the feed runs.

Nothing is stored. A conformant 11 Mb/s feed is 119 GB a day; this reads the
stream as it passes and keeps only the counters, so the record of a week-long
run is a few hundred kilobytes of text.

Each window prints one `key=value` line:

    pcrs            PCR-bearing packets seen on the graded PID
    gt40            intervals above the TR 101 290 P1 repetition limit
    max_ms          longest interval in the window
    mean_ms         mean interval
    cc              continuity-counter errors, all PIDs
    packets         transport packets
    rate_bps        mux rate implied by PCR advance against byte position
    gap_ms          longest gap with no PCR at all, which is what a stalled
                    source looks like from here

The PID is discovered from the stream rather than configured: the first PID to
carry a second PCR is the one being graded, so the monitor does not need a PMT
and cannot be pointed at the wrong PID by a stale flag.
"""

import argparse
import sys
import time

PACKET = 188
SYNC = 0x47
PCR_HZ = 27_000_000
PCR_WRAP = 300 * (1 << 33)  # base is 33 bits at 90 kHz, extension 9 bits at 27 MHz


def pcr_of(packet):
    """The 27 MHz PCR in `packet`, or None if it carries none."""
    if not packet[3] & 0x20:  # adaptation_field_control has no adaptation field
        return None
    if packet[4] < 7:  # too short to hold the 6 PCR bytes plus the flags byte
        return None
    if not packet[5] & 0x10:  # PCR_flag
        return None
    base = (packet[6] << 25) | (packet[7] << 17) | (packet[8] << 9) | (packet[9] << 1) | (packet[10] >> 7)
    ext = ((packet[10] & 0x01) << 8) | packet[11]
    return base * 300 + ext


def unwrap(previous, current):
    """`current` advanced past `previous`, allowing for the 33-bit rollover."""
    delta = current - previous
    if delta < -(PCR_WRAP // 2):
        delta += PCR_WRAP
    return delta


class Window:
    """Counters for one reporting interval."""

    def __init__(self):
        self.pcrs = 0
        self.gt40 = 0
        self.max_ms = 0.0
        self.total_ms = 0.0
        self.intervals = 0
        self.cc = 0
        self.packets = 0
        self.pcr_span = 0  # 27 MHz ticks between first and last PCR
        self.byte_span = 0  # transport packets between first and last PCR

    def line(self, elapsed, gap_ms):
        mean = self.total_ms / self.intervals if self.intervals else 0.0
        # The mux rate the stream asserts about itself: bytes carried between two
        # PCRs over the media time those PCRs claim separates them. On a
        # conformant CBR wire this lands on the nominal rate; drift here is the
        # clock and the byte clock disagreeing, which no interval check catches.
        rate = 0
        if self.pcr_span > 0:
            rate = int(self.byte_span * PACKET * 8 * PCR_HZ / self.pcr_span)
        return (
            f"t={elapsed} pcrs={self.pcrs} gt40={self.gt40} max_ms={self.max_ms:.3f} "
            f"mean_ms={mean:.3f} cc={self.cc} packets={self.packets} "
            f"rate_bps={rate} gap_ms={gap_ms:.0f}"
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--window", type=float, default=60.0, help="seconds per summary line (default 60)")
    ap.add_argument("--repetition-ms", type=float, default=40.0, help="P1 PCR repetition limit (default 40)")
    ap.add_argument("--pid", type=int, default=None, help="grade this PID instead of discovering it")
    args = ap.parse_args()

    stdin = sys.stdin.buffer
    pid_last_pcr = {}  # pid -> last PCR, for discovery
    cc_last = {}  # pid -> last continuity counter
    graded = args.pid
    last_pcr = None
    last_pcr_packet = None
    last_pcr_at = None

    window = Window()
    started = time.monotonic()
    window_ends = started + args.window
    packet_index = 0
    # Bytes left over from a short read; a pipe does not respect packet boundaries.
    residue = b""

    while True:
        chunk = stdin.read(PACKET * 512)
        if not chunk:
            break
        buffer = residue + chunk
        whole = len(buffer) // PACKET * PACKET
        residue = buffer[whole:]
        now = time.monotonic()

        for at in range(0, whole, PACKET):
            packet = buffer[at : at + PACKET]
            if packet[0] != SYNC:
                # One bad byte de-phases everything after it, so resynchronise on
                # the next sync byte rather than reporting the rest as errors.
                nxt = buffer.find(bytes([SYNC]), at + 1, whole)
                if nxt < 0:
                    break
                residue = buffer[nxt:]
                break
            packet_index += 1
            window.packets += 1
            pid = ((packet[1] & 0x1F) << 8) | packet[2]
            if pid == 0x1FFF:  # stuffing carries no counter and no clock
                continue

            # Continuity. A packet with no payload does not advance the counter
            # (ISO 13818-1 2.4.3.3), and a duplicate legally repeats it.
            counter = packet[3] & 0x0F
            has_payload = bool(packet[3] & 0x10)
            previous = cc_last.get(pid)
            if previous is not None:
                expected = (previous + 1) % 16 if has_payload else previous
                if counter != expected and counter != previous:
                    window.cc += 1
            cc_last[pid] = counter

            pcr = pcr_of(packet)
            if pcr is None:
                continue
            if graded is None:
                # The first PID to show a second PCR is the clock.
                if pid in pid_last_pcr:
                    graded = pid
                else:
                    pid_last_pcr[pid] = pcr
                    continue
            if pid != graded:
                continue

            window.pcrs += 1
            if last_pcr is not None:
                ticks = unwrap(last_pcr, pcr)
                ms = ticks / (PCR_HZ / 1000.0)
                # A negative or absurd step is a discontinuity, not an interval;
                # counting it as one would report a 26-hour gap at every wrap.
                if 0 < ms < 10_000:
                    window.intervals += 1
                    window.total_ms += ms
                    window.max_ms = max(window.max_ms, ms)
                    if ms > args.repetition_ms:
                        window.gt40 += 1
                    window.pcr_span += ticks
                    window.byte_span += packet_index - last_pcr_packet
            last_pcr = pcr
            last_pcr_packet = packet_index
            last_pcr_at = now

        if now >= window_ends:
            # Wall-clock silence since the last PCR: the one reading here that
            # does not come from the bytes, and the only one that can say the
            # feed stopped rather than that it is carrying something wrong.
            gap = (now - last_pcr_at) * 1000.0 if last_pcr_at else 0.0
            print(window.line(int(now - started), gap), flush=True)
            window = Window()
            while window_ends <= now:
                window_ends += args.window

    if window.packets:
        gap = (time.monotonic() - last_pcr_at) * 1000.0 if last_pcr_at else 0.0
        print(window.line(int(time.monotonic() - started), gap), flush=True)


if __name__ == "__main__":
    main()
