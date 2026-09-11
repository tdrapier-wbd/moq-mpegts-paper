#!/usr/bin/env python3
"""Wrap a PCR boundary condition in a DVB service, so it can be carried by a pipeline.

`ts-pcr-fixtures.py` builds stimuli for the *analyser*: one PID, filler payload, no PAT and
no PMT, forty grid slots. That is exactly right for grading PCR values, positions and
continuity from a file, and it is why the self-test can assert a verdict per condition.

It is also unimportable. `moq import ts` builds its catalog from PAT/PMT; given a stream with
neither it resolves no tracks, drops the catalog producer and exits zero having published
nothing. So the half of T33 that runs a boundary condition through MoQ and the groomer could
not run on these fixtures at all, which was not discovered until it was tried.

This script supplies the missing carriage without disturbing the condition:

  * **PAT and PMT** at a 100 ms cadence, declaring the fixture's elementary stream as private
    PES (`stream_type` 0x06). Private PES is deliberate — it is carried verbatim, so the
    importer's codec parsers never look at the filler payload, and what comes back out is the
    packet stream that went in. A video or audio stream_type would have the importer parse
    0xFF as a frame header and reject it.
  * **A timeline long enough to establish a session.** The condition is placed once, in the
    middle, with a conformant grid either side, on one monotonic clock. It is not the fixture
    looped: looping restarts the clock and the counters, and the resulting backwards jump and
    continuity break at every lap boundary would swamp the condition under test — the same
    rig artefact `method-notes.md` §1 records for looped clips.

Continuity counters come from `ts-pcr-fixtures.py`'s own `Stream`, so they are correct by
construction across the whole run and a counter error in a report is one the fixture meant.

  t33-service-fixture.py normal      --seconds 20 -o out.ts
  t33-service-fixture.py wrap        --seconds 20 -o out.ts
  t33-service-fixture.py discontinuity --seconds 20 -o out.ts
  t33-service-fixture.py pid-change  --seconds 20 -o out.ts
  t33-service-fixture.py pmt-version --seconds 20 -o out.ts

`pmt-version` is the PSI condition T33 recorded as missing from the generator: the PMT's
`version_number` increments mid-stream and the elementary stream list changes with it.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module

_fx = import_module("ts-pcr-fixtures")

TS = _fx.TS
SYNC = _fx.SYNC
PID = _fx.PID
PID_ALT = _fx.PID_ALT
TICKS_MS = _fx.TICKS_MS
PCR_MODULUS = _fx.PCR_MODULUS
STEP_MS = _fx.STEP_MS
SPACING = _fx.SPACING
STEP = _fx.STEP
Stream = _fx.Stream

PAT_PID = 0x0000
PMT_PID = 0x1000
PROGRAM = 1
STREAM_TYPE_PRIVATE_PES = 0x06
PSI_EVERY_MS = 100  # PAT/PMT cadence; DVB practice is 100-500 ms

_CRC_TABLE = []


def _crc32_mpeg(data):
    """The MPEG-2 systems CRC-32, which PSI sections carry and a decoder checks."""
    if not _CRC_TABLE:
        for i in range(256):
            c = i << 24
            for _ in range(8):
                c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
            _CRC_TABLE.append(c)
    crc = 0xFFFFFFFF
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _CRC_TABLE[((crc >> 24) ^ b) & 0xFF]
    return crc


def _section(table_id, table_id_ext, version, body):
    """A short PSI section: header, body, CRC. Section length covers from after it to the CRC."""
    payload = bytes([table_id_ext >> 8, table_id_ext & 0xFF, 0xC0 | ((version & 0x1F) << 1) | 1, 0, 0]) + body
    length = len(payload) + 4  # + CRC32
    head = bytes([table_id, 0xB0 | ((length >> 8) & 0x0F), length & 0xFF])
    crc = _crc32_mpeg(head + payload)
    return head + payload + crc.to_bytes(4, "big")


def _psi_packet(pid, cc, section):
    """One PSI packet: pointer_field 0, the section, stuffed to 188. Sections here all fit."""
    body = b"\x00" + section
    if len(body) > TS - 4:
        raise ValueError("section does not fit one packet")
    b = bytearray(b"\xff" * TS)
    b[0] = SYNC
    b[1] = 0x40 | ((pid >> 8) & 0x1F)  # payload_unit_start_indicator
    b[2] = pid & 0xFF
    b[3] = 0x10 | (cc & 0x0F)
    b[4 : 4 + len(body)] = body
    return bytes(b)


def pat_section():
    return _section(0x00, PROGRAM, 0, bytes([PROGRAM >> 8, PROGRAM & 0xFF, 0xE0 | (PMT_PID >> 8), PMT_PID & 0xFF]))


def pmt_section(pcr_pid, es_pids, version=0):
    body = bytearray([0xE0 | (pcr_pid >> 8), pcr_pid & 0xFF, 0xF0, 0x00])
    for p in es_pids:
        body += bytes([STREAM_TYPE_PRIVATE_PES, 0xE0 | (p >> 8), p & 0xFF, 0xF0, 0x00])
    return _section(0x02, PROGRAM, version, bytes(body))


class ServiceStream(Stream):
    """`Stream`, plus PSI on its own counters and a PMT that can be revised mid-run."""

    def __init__(self):
        super().__init__()
        self.pmt_pcr_pid = PID
        self.pmt_es = [PID]
        self.pmt_version = 0

    def psi(self):
        self.packets.append(_psi_packet(PAT_PID, self._take(PAT_PID), pat_section()))
        self.packets.append(
            _psi_packet(PMT_PID, self._take(PMT_PID), pmt_section(self.pmt_pcr_pid, self.pmt_es, self.pmt_version))
        )
        return self

    def revise_pmt(self, pcr_pid=None, es_pids=None):
        """Increment version_number and re-declare, which is the PSI condition under test."""
        if pcr_pid is not None:
            self.pmt_pcr_pid = pcr_pid
        if es_pids is not None:
            self.pmt_es = es_pids
        self.pmt_version = (self.pmt_version + 1) & 0x1F
        return self


def _run(s, slots, t0, pid=PID, psi_every_slots=PSI_EVERY_MS // STEP_MS):
    """`slots` grid slots from clock `t0`, with PSI folded in at its own cadence."""
    for i in range(slots):
        if i % psi_every_slots == 0:
            s.psi()
        s.slot((t0 + i * STEP) % PCR_MODULUS, pid=pid)
    return t0 + slots * STEP


def build_condition(name, seconds):
    """[lead-in] [the condition, once] [tail] on one monotonic clock, with PSI throughout."""
    total = max(4, int(round(seconds * 1000 / STEP_MS)))
    lead = total // 3
    tail = total - lead

    s = ServiceStream()

    if name == "normal":
        _run(s, total, 0)

    elif name == "wrap":
        # Start 20 slots below the 33-bit boundary so the wrap lands in the lead-in, once,
        # rather than 26.51 h in. Everything after it is an ordinary grid past the boundary.
        start = PCR_MODULUS - STEP * 20
        _run(s, total, start)

    elif name == "discontinuity":
        t = _run(s, lead, 0)
        # ISO 13818-1 2.4.3.3: the counter may jump in the packet carrying the indicator, so
        # desynchronise before emitting it, not after.
        s.psi().jump_counter(by=5).clock((t + STEP * 40) % PCR_MODULUS, disc=True).media(SPACING)
        _run(s, tail, t + STEP * 41)

    elif name == "pid-change":
        # The PCR moves PID mid-stream and the PMT is revised to say so, which is what a real
        # source does. The exporter has been observed dropping a track here.
        t = _run(s, lead, 0)
        s.revise_pmt(pcr_pid=PID_ALT, es_pids=[PID, PID_ALT]).psi()
        _run(s, tail, t, pid=PID_ALT)

    elif name == "pmt-version":
        # PSI-only: the elementary stream list and version change, the clock does not.
        s.pmt_es = [PID, PID_ALT]
        t = _run(s, lead, 0)
        s.revise_pmt(es_pids=[PID]).psi()
        _run(s, tail, t)

    else:
        raise SystemExit(f"unknown condition {name!r}")

    return s.out()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("condition", choices=["normal", "wrap", "discontinuity", "pid-change", "pmt-version"])
    ap.add_argument("--seconds", type=float, default=20.0, help="clock span of the stream (default 20)")
    ap.add_argument("-o", "--out", required=True, help="output .ts path")
    args = ap.parse_args()

    packets = build_condition(args.condition, args.seconds)
    with open(args.out, "wb") as fh:
        fh.write(b"".join(packets))
    span_ms = len(packets) and args.seconds
    print(
        f"{args.condition:<14} {len(packets):6d} packets  {len(packets) * TS:9d} B  "
        f"~{span_ms:.1f} s clock  -> {args.out}"
    )


if __name__ == "__main__":
    main()
