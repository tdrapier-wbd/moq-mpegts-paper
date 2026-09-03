#!/usr/bin/env python3
"""Synthesise one MPEG-TS fixture per PCR boundary condition the campaign has to grade.

    ts-pcr-fixtures.py <out-dir>            # write every file-domain fixture
    ts-pcr-fixtures.py --list               # what exists and what each one is for
    ts-pcr-fixtures.py --pipe <name>        # write a live fixture to stdout, paced

Why this exists. Every PCR condition Gate 2 cares about was, until now, exercised only by
whatever a real exporter happened to do on the day. That makes a defect reproducible and a
*boundary* unreachable: the PCR base wraps every 26.51 h, so a capture crossing one costs a
27-hour run to obtain by waiting, and a hardware soak needs 72 h to see one at all. A wrap can
instead be **placed**: start the counter just below the boundary and it arrives in the first
second. The same argument applies to a signalled discontinuity, a mid-stream PCR-PID change
and a legal duplicate packet, none of which a well-behaved source produces on demand.

These are stimuli for the *instrument*, not models of a broadcast. Each one isolates a single
condition against an otherwise conformant grid, so a verdict that moves can only have moved
for that reason. Continuity counters are therefore maintained by construction, and clock
packets are spaced with media so the position domain reads clean unless a fixture is about
position. `ts-pcr-selftest.sh` asserts the expected verdict for every fixture here, which is
what makes the instrument's own behaviour a tested quantity rather than an assumption.

Two fixtures (`shortaf`, `backwards`) exist only because review found the analyser mishandling
them. They are regression cases for the tool, not conditions anyone should see on a wire.

One deliberate omission worth stating, because it is a property of MPEG-TS and not of this
generator: a loss of an exact multiple of 16 packets on a PID is invisible to the continuity
counter, which is 4 bits. `loss-recovery` therefore drops a run that the counter *can* see, and
the blind spot is left to the interval check, which sizes the hole from the clock instead.

The file-domain fixtures carry no arrival timing, so they grade PCR *values*, *positions* and
*continuity* only. Release timing and drift need a pipe, which is what `--pipe` is for.
"""

import argparse
import os
import sys
import time

TS = 188
SYNC = 0x47
PID = 0x0100  # the elementary stream carrying PCR
PID_ALT = 0x0200  # the PCR PID after a mid-stream change
TICKS_MS = 27_000  # 27 MHz PCR ticks per millisecond
PCR_MODULUS = (1 << 33) * 300  # the 33-bit base, expressed in 27 MHz ticks
STEP_MS = 20  # the grid every fixture is built on
SPACING = 5  # media packets between clock packets, so position reads clean


def pcr_bytes(ticks):
    """The six-byte PCR field: 33-bit base at 90 kHz, 9-bit extension at 27 MHz."""
    base, ext = divmod(ticks % PCR_MODULUS, 300)
    base &= (1 << 33) - 1
    return bytes(
        [
            (base >> 25) & 0xFF,
            (base >> 17) & 0xFF,
            (base >> 9) & 0xFF,
            (base >> 1) & 0xFF,
            ((base & 1) << 7) | 0x7E | ((ext >> 8) & 1),
            ext & 0xFF,
        ]
    )


def build(pid, cc, pcr=None, disc=False, af_len=None):
    """One payload-bearing TS packet, with an adaptation field only if something needs it."""
    b = bytearray(b"\xff" * TS)
    b[0] = SYNC
    b[1] = (pid >> 8) & 0x1F
    b[2] = pid & 0xFF
    adaptation = pcr is not None or disc or af_len is not None
    b[3] = ((0x2 if adaptation else 0) | 0x1) << 4 | (cc & 0x0F)
    if not adaptation:
        return bytes(b)
    length = af_len if af_len is not None else (7 if pcr is not None else 1)
    b[4] = length
    b[5] = (0x80 if disc else 0x00) | (0x10 if pcr is not None else 0x00)
    if pcr is not None:
        b[6:12] = pcr_bytes(pcr)
    return bytes(b)


class Stream:
    """A packet list whose continuity counters are correct unless deliberately broken.

    Every fixture starts from this, so a continuity failure in a report means the fixture
    meant to cause one. Without that the position and spacing fixtures both flagged counter
    errors they were never about, and a self-test cannot assert on a signal it has polluted.
    """

    def __init__(self):
        self.packets = []
        self._cc = {}

    def _take(self, pid):
        cc = self._cc.get(pid, 0)
        self._cc[pid] = (cc + 1) & 0x0F
        return cc

    def clock(self, ticks, pid=PID, disc=False, af_len=None):
        self.packets.append(build(pid, self._take(pid), pcr=ticks, disc=disc, af_len=af_len))
        return self

    def media(self, n, pid=PID):
        for _ in range(n):
            self.packets.append(build(pid, self._take(pid)))
        return self

    def slot(self, ticks, pid=PID, spacing=SPACING):
        """One grid slot: the clock packet, then the media bytes it labels."""
        return self.clock(ticks, pid=pid).media(spacing, pid=pid)

    def grid(self, n, start=0, step_ms=STEP_MS, pid=PID, spacing=SPACING):
        for i in range(n):
            self.slot((start + i * TICKS_MS * step_ms) % PCR_MODULUS, pid=pid, spacing=spacing)
        return self

    def jump_counter(self, pid=PID, by=3):
        """Desynchronise the counter, which is only legal after a discontinuity_indicator."""
        self._cc[pid] = (self._cc.get(pid, 0) + by) & 0x0F
        return self

    def out(self):
        return self.packets


STEP = TICKS_MS * STEP_MS


def f_normal():
    return Stream().grid(40).out()


def f_wrap():
    # Placed, not waited for: the run starts 20 slots below the 33-bit boundary, so it
    # crosses 400 ms in rather than 26.51 h in. This is the whole reason the file exists.
    return Stream().grid(40, start=PCR_MODULUS - STEP * 20).out()


def f_duplicate():
    # ISO 13818-1 2.4.3.3 permits one duplicate: same counter, same payload. A second
    # consecutive repeat would be a stuck counter and is not permitted.
    s = Stream().grid(40)
    p = s.out()
    p.insert(7, p[6])
    return p


def f_discontinuity():
    # A signalled discontinuity, which is the normal case for a real source and was the
    # untested one. ISO 13818-1 2.4.3.3 permits the discontinuity in *the packet carrying the
    # flag*, so the counter has to be jumped before that packet is emitted, not after it.
    # Jumping it after leaves the flagged packet continuous and the next one not, which is a
    # genuine error and the analyser is right to say so.
    s = Stream().grid(20)
    s.jump_counter(by=5).clock(STEP * 60, disc=True).media(SPACING)
    s.grid(19, start=STEP * 61)
    return s.out()


def f_pid_change():
    # The PCR moves to another PID mid-stream, as a PMT update would do. Never synthesised
    # before, and observed for real: the exporter drops a track mid-run, reporting
    # "TS track layout changed after PAT/PMT was emitted".
    s = Stream().grid(20)
    s.grid(20, start=STEP * 20, pid=PID_ALT)
    return s.out()


def f_loss_recovery():
    # A run excised, then clean resumption. The clock keeps its true values across the hole,
    # so the gap shows as one long interval; the run length is not a multiple of 16, so the
    # counter can see it too. Recovery must be clean rather than leaving the tool desynced.
    p = Stream().grid(40).out()
    per_slot = 1 + SPACING
    return p[: 10 * per_slot] + p[13 * per_slot + 2 :]


def f_spacing():
    # Both abnormal spacings at once, which is what a real exporter produced: a stall past
    # the 40 ms repetition limit, then a burst of clock packets back to back. Counters stay
    # legal throughout, so only the interval and position domains should move.
    s = Stream().grid(20)
    s.clock(STEP * 20 + TICKS_MS * 220).media(SPACING)  # the stall
    for i in range(1, 6):
        s.clock(STEP * 20 + TICKS_MS * (220 + i))  # the burst, no media between
    s.media(SPACING)
    s.grid(14, start=STEP * 20 + TICKS_MS * 240)
    return s.out()


def f_clustered():
    # The positional defect: clock packets bunched, with the media they label heaped between
    # the clusters. Values stay on an exact grid, which is what makes this the fixture that
    # separates the value domain from the position domain.
    s = Stream()
    for c in range(8):
        for i in range(5):
            s.clock(((5 * c + i) * STEP) % PCR_MODULUS)
        s.media(5 * SPACING)
    return s.out()


def f_shortaf():
    # Regression case: PCR_flag set on an adaptation field too short to hold a PCR. The
    # analyser used to assemble a value out of stuffing and report a 95,441,900 ms interval.
    p = Stream().grid(40).out()
    i = 12 * (1 + SPACING)
    short = bytearray(build(PID, p[i][3] & 0x0F, af_len=3))
    short[5] |= 0x10  # PCR_flag on a three-byte field
    p[i] = bytes(short)
    return p


def f_backwards():
    # Regression case: a PCR that genuinely moves backwards, which is not a wrap and must not
    # be silently accepted as one.
    p = Stream().grid(40).out()
    i = 25 * (1 + SPACING)
    b = bytearray(p[i])
    b[6:12] = pcr_bytes(STEP * 5)
    p[i] = bytes(b)
    return p


FIXTURES = {
    "normal": ("normal PCR progression on an exact 20 ms grid", f_normal),
    "wrap": ("the 33-bit base wrap, placed 400 ms in rather than 26.51 h in", f_wrap),
    "duplicate": ("one legal duplicate packet, ISO 13818-1 2.4.3.3", f_duplicate),
    "discontinuity": ("a signalled discontinuity, with counter and clock jump", f_discontinuity),
    "pid-change": ("the PCR PID changing mid-stream", f_pid_change),
    "loss-recovery": ("a run of packets lost, then clean resumption", f_loss_recovery),
    "spacing": ("a stall past the 40 ms limit, then a back-to-back burst", f_spacing),
    "clustered": ("clock packets bunched, values still on the grid", f_clustered),
    "shortaf": ("PCR_flag on an adaptation field too short to hold one", f_shortaf),
    "backwards": ("a PCR that moves backwards, which is not a wrap", f_backwards),
}

# Live fixtures. A file carries no release timing, so drift has to be paced out of a pipe.
LIVE = {
    "steady": ("released on its own grid", 1.000),
    "drift-slow": ("released 2 % slower than its grid, so drift accumulates", 1.020),
    "drift-fast": ("released 2 % faster than its grid", 0.980),
}


def write_pipe(name, seconds):
    """Pace a grid out of stdout at a chosen multiple of its own asserted rate.

    The point is the *ratio*. A stream whose PCR says 20 ms released every 20.4 ms runs 2 %
    slow, which no per-interval tolerance can see (0.4 ms against a 10 ms bound) and which
    accumulates without bound. Sleeps run to an absolute deadline so the intended ratio does
    not compound with scheduling error, but the host still adds its own, so read the reported
    drift as at least this large rather than exactly it.
    """
    if name not in LIVE:
        sys.exit(f"unknown live fixture {name!r}; have {', '.join(LIVE)}")
    ratio = LIVE[name][1]
    n = max(2, int(seconds * 1000 / STEP_MS))
    cadence = STEP_MS * ratio / 1000.0
    out = sys.stdout.buffer
    start = time.monotonic()
    cc = 0
    for i in range(n):
        out.write(build(PID, cc, pcr=(i * STEP) % PCR_MODULUS))
        cc = (cc + 1) & 0x0F
        for _ in range(SPACING):
            out.write(build(PID, cc))
            cc = (cc + 1) & 0x0F
        out.flush()
        remaining = start + (i + 1) * cadence - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("out", nargs="?", help="directory to write the file-domain fixtures into")
    ap.add_argument("--list", action="store_true", help="describe every fixture and exit")
    ap.add_argument("--pipe", help=f"write a live fixture to stdout: {', '.join(LIVE)}")
    ap.add_argument("--seconds", type=float, default=30.0, help="length of a --pipe run")
    args = ap.parse_args()

    if args.list:
        print("file-domain fixtures (PCR values, positions, continuity):")
        for name, (what, _) in FIXTURES.items():
            print(f"  {name:16s} {what}")
        print("\nlive fixtures, paced to stdout (release timing and drift):")
        for name, (what, ratio) in LIVE.items():
            print(f"  {name:16s} {what} (x{ratio})")
        return 0

    if args.pipe:
        write_pipe(args.pipe, args.seconds)
        return 0

    if not args.out:
        ap.error("need an output directory, or --list, or --pipe")

    os.makedirs(args.out, exist_ok=True)
    for name, (what, builder) in FIXTURES.items():
        packets = builder()
        path = os.path.join(args.out, f"{name}.ts")
        with open(path, "wb") as f:
            f.write(b"".join(packets))
        print(f"  {name:16s} {len(packets):5d} packets  {path}  ({what})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
