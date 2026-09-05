#!/usr/bin/env python3
"""Inject deterministic PCR/PTS/DTS timeline events into a real transport stream.

`ts-pcr-fixtures.py` builds minimal synthetic streams, which is right for grading an
analyser and wrong for grading the media-aware lane: `moq import ts` demuxes into codec
tracks, so a stimulus has to be a stream with real elementary streams in it. This takes a
conformant clip and rewrites its timeline, leaving the coded pictures untouched.

**It shifts PTS and DTS as well as PCR, and that is the point.** The exporter does not copy
the source's PCR — it reconstructs one, scheduling from media timestamps ([T19]). A
stimulus that moved PCR alone would test a path the lane does not use and would report a
confident null. Shifting all three is also what a real source does: an encoder that
restarts restarts its whole timebase, not one field of it.

Two classes of event, and conflating them is the mistake this campaign exists to avoid:

- A **signalled discontinuity** (ISO 13818-1 2.4.3.4) is the source announcing a new time
  base. `discontinuity_indicator` is set on the first affected packet; a decoder must
  re-acquire. Splices, encoder restarts and source failovers are all this.
- A **33-bit rollover** is not a discontinuity and must not be flagged as one. The base is
  modulo 2^33 at 90 kHz, so it returns to zero every 26.51 h of *any* stream, and a
  receiver is required to handle it as ordinary arithmetic. Flagging it would be the bug.

Usage:
  t23-pcr-stimuli.py <in.ts> <out.ts> --arm <A|B|C|D|E|F> [--at-seconds N]
  t23-pcr-stimuli.py --list
"""

import argparse
import sys

TS = 188
SYNC = 0x47
PCR_HZ = 27_000_000
PTS_HZ = 90_000
PCR_MODULUS = (1 << 33) * 300  # the 33-bit base expressed in 27 MHz ticks
PTS_MODULUS = 1 << 33

# The arms. `shift` is in seconds of media time, applied to everything at and after the cut;
# `signal` says whether the first affected packet sets discontinuity_indicator.
ARMS = {
    "A": {
        "shift": -1.0,
        "signal": True,
        "restart": False,
        "desc": "small backward jump (-1 s), signalled — basic re-acquisition",
    },
    "B": {
        "shift": -600.0,
        "signal": True,
        "restart": False,
        # Lifted clear of zero first. Subtracting 600 s from a clip that starts at zero
        # does not produce a 600 s backward jump, it produces a value 600 s below the
        # modulus — legal arithmetic, but a rollover wearing a discontinuity's clothes,
        # and it would confound this arm with arm D rather than isolating it.
        "base": 700.0,
        "desc": "large backward jump (-600 s), signalled — the T21 loop, made deliberate",
    },
    "C": {
        "shift": +30.0,
        "signal": True,
        "restart": False,
        "desc": "forward jump (+30 s), signalled — the case no previous run covered",
    },
    "D": {
        "shift": 0.0,
        "signal": False,
        "restart": False,
        "desc": "33-bit base rollover, NOT signalled — the mandatory 26.51 h event, placed",
    },
    "E": {
        "shift": None,  # absolute restart, see below
        "signal": True,
        "restart": True,
        "desc": "encoder restart: timebase returns to ~0, signalled, counters reset",
    },
    "F": {
        "shift": 0.0,
        "signal": False,
        "restart": False,
        "desc": "control, byte-identical timeline — proves the rig changes nothing by itself",
    },
}


def parse_pcr(p):
    """PCR in 27 MHz ticks from a packet's adaptation field, or None."""
    if not (p[3] >> 4) & 0x2:
        return None
    if p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    ext = ((p[10] & 0x01) << 8) | p[11]
    return base * 300 + ext


def write_pcr(p, ticks):
    base, ext = divmod(ticks % PCR_MODULUS, 300)
    base &= (1 << 33) - 1
    p[6] = (base >> 25) & 0xFF
    p[7] = (base >> 17) & 0xFF
    p[8] = (base >> 9) & 0xFF
    p[9] = (base >> 1) & 0xFF
    p[10] = ((base & 1) << 7) | 0x7E | ((ext >> 8) & 0x01)
    p[11] = ext & 0xFF


def read_ts_stamp(b, off):
    """A 33-bit PTS/DTS from its five-byte marker-interleaved encoding."""
    return (
        ((b[off] & 0x0E) << 29)
        | (b[off + 1] << 22)
        | ((b[off + 2] & 0xFE) << 14)
        | (b[off + 3] << 7)
        | ((b[off + 4] & 0xFE) >> 1)
    )


def write_ts_stamp(b, off, value, prefix):
    """Re-encode a 33-bit PTS/DTS, preserving the four-bit prefix and the marker bits."""
    v = value % PTS_MODULUS
    b[off] = (prefix << 4) | ((v >> 29) & 0x0E) | 0x01
    b[off + 1] = (v >> 22) & 0xFF
    b[off + 2] = ((v >> 14) & 0xFE) | 0x01
    b[off + 3] = (v >> 7) & 0xFF
    b[off + 4] = ((v << 1) & 0xFE) | 0x01


def payload_offset(p):
    """First payload byte, accounting for the adaptation field, or None if no payload."""
    afc = (p[3] >> 4) & 0x3
    if afc == 0 or afc == 2:
        return None
    off = 4 if afc == 1 else 5 + p[4]
    return off if off < TS else None


def shift_pes_stamps(p, delta_90k):
    """Shift PTS and DTS in a PES header that starts in this packet. Returns how many."""
    if not (p[1] & 0x40):  # payload_unit_start_indicator
        return 0
    off = payload_offset(p)
    if off is None or off + 9 > TS:
        return 0
    if not (p[off] == 0x00 and p[off + 1] == 0x00 and p[off + 2] == 0x01):
        return 0
    stream_id = p[off + 3]
    # Only these carry PTS/DTS; PSI and the padding/map stream ids do not.
    if not (0xC0 <= stream_id <= 0xEF):
        return 0
    flags2 = p[off + 7]
    pts_dts = (flags2 >> 6) & 0x3
    if pts_dts == 0:
        return 0
    n = 0
    base = off + 9
    if base + 5 <= TS:
        # '0010' when PTS alone, '0011' when a DTS follows; preserved either way.
        prefix = 0x2 if pts_dts == 0x2 else 0x3
        write_ts_stamp(p, base, read_ts_stamp(p, base) + delta_90k, prefix)
        n += 1
    if pts_dts == 0x3 and base + 10 <= TS:
        write_ts_stamp(p, base + 5, read_ts_stamp(p, base + 5) + delta_90k, 0x1)
        n += 1
    return n


def rebase(data, n, shift_ticks):
    """Shift every PCR, PTS and DTS in the stream by a constant. Signals nothing."""
    for i in range(n):
        off = i * TS
        p = memoryview(data)[off : off + TS]
        if p[0] != SYNC:
            continue
        pcr = parse_pcr(p)
        if pcr is not None:
            write_pcr(p, pcr + shift_ticks)
        shift_pes_stamps(p, (shift_ticks // 300) % PTS_MODULUS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--arm", choices=sorted(ARMS))
    ap.add_argument(
        "--at-seconds",
        type=float,
        default=45.0,
        help="media time into the clip at which the event happens",
    )
    ap.add_argument("--list", action="store_true")
    ap.add_argument(
        "--shift-seconds",
        type=float,
        help="override the arm's shift, for locating a threshold between two arms",
    )
    args = ap.parse_args()

    if args.list:
        for k in sorted(ARMS):
            print(f"{k}  {ARMS[k]['desc']}")
        return 0
    if not (args.source and args.out and args.arm):
        ap.error("source, out and --arm are required")

    arm = dict(ARMS[args.arm])
    if args.shift_seconds is not None:
        arm["shift"] = args.shift_seconds
        arm["restart"] = False
    data = bytearray(open(args.source, "rb").read())
    n = len(data) // TS

    # First pass: the clip's own PCR origin, and the tick at which to cut.
    first_pcr = None
    for i in range(n):
        v = parse_pcr(data[i * TS : i * TS + TS])
        if v is not None:
            first_pcr = v
            break
    if first_pcr is None:
        print("no PCR in source", file=sys.stderr)
        return 1
    cut_tick = first_pcr + int(args.at_seconds * PCR_HZ)

    # Arm D places the rollover instead of waiting 26.51 h for it: rebase the whole clip so
    # the boundary falls `at_seconds` in. Every value is shifted, nothing is signalled, and
    # the crossing is then an ordinary property of the arithmetic rather than an event.
    global_shift = 0
    if args.arm == "D":
        global_shift = (PCR_MODULUS - cut_tick) % PCR_MODULUS
        rebase(data, n, global_shift)
        cut_tick = None
    elif arm.get("base"):
        # A prepass, not the event: lift the origin, then cut relative to the lifted clip.
        global_shift = int(arm["base"] * PCR_HZ) - first_pcr
        rebase(data, n, global_shift)
        cut_tick += global_shift
        global_shift = 0

    # Arm E restarts the timebase rather than displacing it, which is what an encoder
    # coming back does: it does not remember where it was.
    if arm["restart"]:
        shift_ticks = -(cut_tick) + 27_000_000  # land at 1.000 s
    elif arm["shift"]:
        shift_ticks = int(arm["shift"] * PCR_HZ)
    else:
        shift_ticks = 0

    after = False
    signalled = 0
    pcrs = 0
    stamps = 0
    cc_reset = set()

    for i in range(n):
        off = i * TS
        p = memoryview(data)[off : off + TS]
        if p[0] != SYNC:
            continue
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pcr = parse_pcr(p)

        if cut_tick is None:  # arm D: the rebase was the whole stimulus
            break

        if not after and pcr is not None and pcr >= cut_tick:
            after = True

        if not after or shift_ticks == 0:
            continue

        if pcr is not None:
            write_pcr(p, pcr + shift_ticks)
            pcrs += 1
            if arm["signal"] and signalled == 0:
                p[5] |= 0x80  # discontinuity_indicator, ISO 13818-1 2.4.3.4
                signalled += 1
        stamps += shift_pes_stamps(p, (shift_ticks // 300) % PTS_MODULUS)

        # A restarting encoder restarts its continuity counters too. Legal only because
        # the discontinuity is signalled, which is exactly why the two go together.
        if arm["restart"] and pid not in cc_reset and pid != 0x1FFF:
            cc_reset.add(pid)
            if arm["signal"] and (p[3] >> 4) & 0x2 and p[4] > 0:
                p[5] |= 0x80

    open(args.out, "wb").write(data)
    print(
        f"arm {args.arm}: {arm['desc']}\n"
        f"  packets={n} pcrs_rewritten={pcrs} stamps_rewritten={stamps} "
        f"discontinuity_indicators_set={signalled} "
        f"cut_at={args.at_seconds}s global_rebase={'yes' if global_shift else 'no'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
