#!/usr/bin/env python3
"""Renumber continuity counters from the keyframe boundary, padding each span to a multiple of 16.

A prototype of the padding scheme proposed on
[#2779](https://github.com/moq-dev/moq/issues/2779), as a stdin/stdout filter, so that the
two questions it is gated on can be answered by measurement instead of argument. It sits
between `moq export ts` and the groomer and does what the exporter would do:

1. At each video keyframe boundary, emit `(16 - n mod 16) mod 16` filler packets on every PID
   that emitted `n` payload packets in the span just ended.
2. Reset every PID's counter there, so each packet's counter is its index within the span.

Padding is what reconciles the two: a counter that restarts at a boundary is the same on every
exporter regardless of when it tuned in, but it jumps wherever the span it closes is not a
multiple of 16, and a jump is a continuity error. Pad the span and both hold.

Ordering is the load-bearing part and is not what the byte stream shows. The exporter refreshes
PAT/PMT *before* writing the keyframe, so those packets are already past when the keyframe
appears here, but they belong to the span the keyframe opens — a leg tuning in at that boundary
emits them as its first packets. So SI is held back and released after the boundary is
processed, which is what puts a late joiner's first span in step with its partner's.

The filler is legal payload rather than null packets, because null packets have no continuity
counter and so cannot close a span: a `padding_stream` PES (stream_id 0xBE, defined for this and
discarded by demuxers) on elementary PIDs, and 0xFF section stuffing on PSI/SI PIDs.

With `--keep-cc` it pads without renumbering, which separates "can the groomer take a variable
packet count" from "does the renumbering make the pair identical".

Usage: moq export ts ... | ts-keyframe-pad.py [--keep-cc] | ts_egress ...
"""

import sys
import time

TS = 188
REPORT_INTERVAL = 10.0
SYNC = 0x47
NULL_PID = 0x1FFF
PAT_PID = 0x0000
# 0x00-0x1F is reserved for PSI/SI in DVB, so a PID below it needs no table to classify.
SI_MAX = 0x001F
VIDEO_STREAM_TYPES = {0x01, 0x02, 0x10, 0x1B, 0x24, 0x27, 0x42}


def pid(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def pusi(p):
    return bool(p[1] & 0x40)


def has_payload(p):
    return bool(p[3] & 0x10)


def payload_offset(p):
    """Where the payload starts, or None if the packet carries none."""
    if not has_payload(p):
        return None
    if p[3] & 0x20:  # adaptation field present
        return 5 + p[4]
    return 4


def random_access(p):
    """The adaptation field's random_access_indicator: how the exporter marks a keyframe."""
    return bool(p[3] & 0x20) and p[4] > 0 and (p[5] & 0x40)


def section(p):
    """The PSI section a packet starts, if it starts one and it fits in the packet."""
    off = payload_offset(p)
    if off is None or not pusi(p) or off >= TS:
        return None
    start = off + 1 + p[off]  # pointer_field
    if start + 3 > TS:
        return None
    length = ((p[start + 1] & 0x0F) << 8) | p[start + 2]
    end = start + 3 + length
    return p[start:end] if end <= TS else None


class Program:
    """Which PIDs carry video, learned from the PAT and PMT in the stream itself.

    The exporter sets `random_access_indicator` from each frame's own keyframe flag, and for
    audio every frame is a keyframe — so the flag alone does not identify the boundary. Only
    the video track's keyframe is a boundary (it is where the exporter re-anchors PSI and
    where a joining exporter necessarily starts), which takes a PMT to know.
    """

    def __init__(self):
        self.pmt_pids = set()
        self.video_pids = set()

    def observe(self, p):
        i = pid(p)
        if i == PAT_PID:
            sec = section(p)
            if sec and sec[0] == 0x00:
                body = sec[8:-4]  # past the header, before the CRC
                for k in range(0, len(body) - 3, 4):
                    program = (body[k] << 8) | body[k + 1]
                    if program:  # program 0 is the network PID, not a PMT
                        self.pmt_pids.add(((body[k + 2] & 0x1F) << 8) | body[k + 3])
        elif i in self.pmt_pids:
            sec = section(p)
            if sec and sec[0] == 0x02:
                info_len = ((sec[10] & 0x0F) << 8) | sec[11]
                k = 12 + info_len
                body = sec[:-4]
                while k + 4 < len(body):
                    es_len = ((body[k + 3] & 0x0F) << 8) | body[k + 4]
                    if body[k] in VIDEO_STREAM_TYPES:
                        self.video_pids.add(((body[k + 1] & 0x1F) << 8) | body[k + 2])
                    k += 5 + es_len

    def is_si(self, i):
        return i <= SI_MAX or i in self.pmt_pids


def elementary_filler(i, cc):
    """One self-contained padding_stream PES, which is a whole packet's worth of nothing."""
    body = b"\x00\x00\x01\xbe" + (TS - 4 - 6).to_bytes(2, "big") + b"\xff" * (TS - 4 - 6)
    return bytes([SYNC, 0x40 | (i >> 8), i & 0xFF, 0x10 | cc]) + body


def si_filler(i, cc):
    """Stuffing after the last section, which is what 0xFF means on a section PID."""
    return bytes([SYNC, i >> 8, i & 0xFF, 0x10 | cc]) + b"\xff" * (TS - 4)


class Pad:
    def __init__(self, out, renumber=True):
        self.out = out
        self.renumber = renumber
        self.program = Program()
        self.span = {}  # PID -> payload packets emitted since the last boundary
        self.held = []  # SI packets waiting to learn which span they belong to
        self.filler = self.total = 0
        self.by_pid = {}  # PID -> filler packets, since the cost is not spread evenly
        self.started = self.reported = time.monotonic()

    def emit(self, p):
        i = pid(p)
        if i == NULL_PID or not has_payload(p):
            # Neither carries a continuity counter, so neither belongs to a span.
            self.out.write(p)
            return
        n = self.span.get(i, 0)
        if self.renumber:
            p = p[:3] + bytes([(p[3] & 0xF0) | (n % 16)]) + p[4:]
        self.span[i] = n + 1
        self.total += 1
        self.out.write(p)

    def boundary(self):
        """Close every open span on a multiple of 16, so the reset that follows is continuous."""
        for i in sorted(self.span):
            n = self.span[i]
            for _ in range((16 - n % 16) % 16):
                make = si_filler if self.program.is_si(i) else elementary_filler
                self.out.write(make(i, self.span[i] % 16))
                self.span[i] += 1
                self.filler += 1
                self.by_pid[i] = self.by_pid.get(i, 0) + 1
        self.span = {}

    def report(self, force=False):
        """Live, because a run that has to be killed to end still has to be priced.

        Rates are per wall-clock second, so they mean what they say on a live stream and
        nothing at all on a file read at disk speed; the percentage is valid either way.
        """
        now = time.monotonic()
        if not force and now - self.reported < REPORT_INTERVAL:
            return
        self.reported = now
        elapsed = now - self.started
        if not self.total or elapsed <= 0:
            return
        total = self.total + self.filler
        rates = " ".join(f"{p:#06x}={n * TS * 8 / elapsed / 1000:.1f}k" for p, n in sorted(self.by_pid.items()))
        print(
            f"ts-keyframe-pad: {self.filler:,}/{total:,} packets filler "
            f"({100.0 * self.filler / total:.2f} %, {self.filler * TS * 8 / elapsed / 1000:.1f} kb/s) "
            f"per PID {rates}",
            file=sys.stderr,
            flush=True,
        )

    def packet(self, p):
        self.program.observe(p)
        i = pid(p)
        if self.program.is_si(i):
            self.held.append(p)
            return
        if pid(p) in self.program.video_pids and pusi(p) and random_access(p):
            self.boundary()
        for h in self.held:
            self.emit(h)
        self.held = []
        self.emit(p)

    def finish(self):
        for h in self.held:
            self.emit(h)
        self.held = []


def main():
    pad = Pad(sys.stdout.buffer, renumber="--keep-cc" not in sys.argv[1:])
    buf = b""
    while chunk := sys.stdin.buffer.read(TS * 7):
        buf += chunk
        # Resynchronise rather than trust the offset: a filter that silently shifts by a byte
        # would look like a determinism result.
        while len(buf) >= TS:
            if buf[0] != SYNC:
                buf = buf[buf.find(SYNC, 1) :] if SYNC in buf[1:] else b""
                continue
            pad.packet(buf[:TS])
            buf = buf[TS:]
        pad.out.flush()
        pad.report()
    pad.finish()
    pad.out.flush()
    pad.report(force=True)


if __name__ == "__main__":
    main()
