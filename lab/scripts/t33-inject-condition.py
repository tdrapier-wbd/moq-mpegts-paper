#!/usr/bin/env python3
"""Apply a PCR/PSI boundary condition to a real transport stream, so a pipeline will carry it.

Why this exists, and why `ts-pcr-fixtures.py` is not enough. Those fixtures are synthetic: one
PID of filler payload, no PAT, no PMT. They grade an analyser perfectly and cannot be carried
by the media-aware lane at all, for two reasons discovered by trying it:

  1. `moq import ts` builds its catalog from PAT/PMT. With neither, it resolves no tracks and
     exits zero having published nothing. `t33-service-fixture.py` fixes that much by adding
     PSI.
  2. `moq export ts` then refuses outright -- *"TS export requires a video or audio track for
     the PCR"*. A stream of verbatim private-PES tracks has no timeline the exporter can
     anchor PCR to, so no amount of PSI makes a filler fixture round-trip.

The conditions therefore have to be applied to a stream that carries real coded video. That
also changes what the arm measures, for the better: the media-aware lane **regenerates** PCR
from the media timeline rather than passing source PCR through, so the question is not whether
a PCR value survives -- it does not, by design -- but whether the *timeline arithmetic*
survives the boundary. Rebasing PCR together with PTS and DTS is what puts the boundary in
front of that arithmetic.

Conditions:

  wrap           rebase PCR, PTS and DTS so the 33-bit boundary is crossed `--at` seconds in.
                 The whole timeline crosses together, which is what a real source does after
                 26.51 h of uptime.
  discontinuity  set discontinuity_indicator on one PCR packet and jump the clock forward with
                 it, which ISO 13818-1 2.4.3.3 and 2.4.3.4 permit and a real splice produces.
  pmt-version    increment the PMT's version_number mid-stream. This is the PSI condition T33
                 recorded as missing from the fixture generator.

  t33-inject-condition.py wrap <in.ts> <out.ts> --at 2.0
  t33-inject-condition.py discontinuity <in.ts> <out.ts> --at 5.0 --jump-ms 500
  t33-inject-condition.py pmt-version <in.ts> <out.ts> --at 5.0
"""

import argparse
import sys

TS = 188
SYNC = 0x47
PCR_BASE_MODULUS = 1 << 33  # 90 kHz units
PTS_MODULUS = 1 << 33
TICKS_90K_PER_S = 90_000


def pid_of(p):
    return ((p[1] & 0x1F) << 8) | p[2]


def has_af(p):
    return bool(p[3] & 0x20)


def af_len(p):
    return p[4] if has_af(p) else 0


def pcr_at(p):
    """(base_90k, ext_27m) if this packet carries a PCR, else None."""
    if not has_af(p) or af_len(p) < 7 or not (p[5] & 0x10):
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    ext = ((p[10] & 0x01) << 8) | p[11]
    return base, ext


def set_pcr(p, base, ext):
    p[6] = (base >> 25) & 0xFF
    p[7] = (base >> 17) & 0xFF
    p[8] = (base >> 9) & 0xFF
    p[9] = (base >> 1) & 0xFF
    p[10] = ((base & 1) << 7) | 0x7E | ((ext >> 8) & 0x01)
    p[11] = ext & 0xFF


def _ts_field(buf, off):
    """Decode a 33-bit PTS/DTS timestamp at buf[off:off+5]."""
    return (
        ((buf[off] & 0x0E) << 29)
        | (buf[off + 1] << 22)
        | ((buf[off + 2] & 0xFE) << 14)
        | (buf[off + 3] << 7)
        | (buf[off + 4] >> 1)
    )


def _set_ts_field(buf, off, val, marker):
    buf[off] = (marker << 4) | ((val >> 29) & 0x0E) | 0x01
    buf[off + 1] = (val >> 22) & 0xFF
    buf[off + 2] = ((val >> 14) & 0xFE) | 0x01
    buf[off + 3] = (val >> 7) & 0xFF
    buf[off + 4] = ((val << 1) & 0xFE) | 0x01


def pes_payload_off(p):
    """Offset of the PES header in this packet, or None if it does not start one."""
    if not (p[1] & 0x40):  # payload_unit_start_indicator
        return None
    off = 4 + (1 + af_len(p) if has_af(p) else 0)
    if off + 9 > TS or p[off : off + 3] != b"\x00\x00\x01":
        return None
    return off


def shift_pts_dts(p, delta):
    """Add `delta` (90 kHz, modular) to any PTS and DTS this packet's PES header carries."""
    off = pes_payload_off(p)
    if off is None:
        return 0
    flags = p[off + 7]
    hdr = off + 9
    n = 0
    if flags & 0x80:  # PTS present
        if hdr + 5 > TS:
            return 0
        _set_ts_field(p, hdr, (_ts_field(p, hdr) + delta) % PTS_MODULUS, 0x3 if flags & 0x40 else 0x2)
        n += 1
        if flags & 0x40:  # DTS present
            if hdr + 10 > TS:
                return n
            _set_ts_field(p, hdr + 5, (_ts_field(p, hdr + 5) + delta) % PTS_MODULUS, 0x1)
            n += 1
    return n


def read_packets(path):
    data = open(path, "rb").read()
    if len(data) % TS:
        data = data[: len(data) // TS * TS]
    pk = [bytearray(data[i : i + TS]) for i in range(0, len(data), TS)]
    if any(p[0] != SYNC for p in pk[:64]):
        raise SystemExit(f"{path}: not 188-byte aligned")
    return pk


def first_pcr(packets):
    for i, p in enumerate(packets):
        v = pcr_at(p)
        if v:
            return i, v
    raise SystemExit("no PCR in input")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("condition", choices=["wrap", "discontinuity", "pmt-version"])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--at", type=float, default=2.0, help="seconds into the stream to place the event")
    ap.add_argument("--jump-ms", type=float, default=500.0, help="clock jump for `discontinuity`")
    ap.add_argument("--pmt-pid", type=lambda s: int(s, 0), default=0x1000)
    args = ap.parse_args()

    pk = read_packets(args.src)
    _, (base0, _) = first_pcr(pk)
    at_ticks = int(args.at * TICKS_90K_PER_S)

    if args.condition == "wrap":
        # Place the boundary `--at` seconds in: the first PCR becomes (2^33 - at_ticks), so the
        # counter rolls over there and every timestamp rolls with it.
        delta = (PCR_BASE_MODULUS - at_ticks - base0) % PCR_BASE_MODULUS
        npcr = nts = 0
        for p in pk:
            v = pcr_at(p)
            if v:
                set_pcr(p, (v[0] + delta) % PCR_BASE_MODULUS, v[1])
                npcr += 1
            nts += shift_pts_dts(p, delta)
        print(f"wrap: rebased {npcr} PCR and {nts} PTS/DTS by {delta} (90 kHz); boundary at ~{args.at:.2f}s")

    elif args.condition == "discontinuity":
        jump = int(args.jump_ms * TICKS_90K_PER_S / 1000)
        target = (base0 + at_ticks) % PCR_BASE_MODULUS
        hit = None
        for i, p in enumerate(pk):
            v = pcr_at(p)
            if v and hit is None and ((v[0] - base0) % PCR_BASE_MODULUS) >= at_ticks:
                hit = i
                p[5] |= 0x80  # discontinuity_indicator
            if hit is not None and v:
                set_pcr(p, (v[0] + jump) % PCR_BASE_MODULUS, v[1])
            if hit is not None:
                shift_pts_dts(p, jump)
        if hit is None:
            raise SystemExit("--at is past the end of the stream")
        print(
            f"discontinuity: indicator set on packet {hit} (PCR ~{args.at:.2f}s), "
            f"clock and PTS/DTS jumped +{args.jump_ms:.0f} ms from there"
        )
        _ = target

    else:  # pmt-version
        # Every PMT packet at or after the mark gets version_number+1. A real PMT revision also
        # changes its content; here the version alone is the stimulus, so a receiver that keys
        # only on version is exercised without perturbing the media.
        target_pkt = None
        for i, p in enumerate(pk):
            v = pcr_at(p)
            if v and target_pkt is None and ((v[0] - base0) % PCR_BASE_MODULUS) >= at_ticks:
                target_pkt = i
        if target_pkt is None:
            raise SystemExit("--at is past the end of the stream")
        n = 0
        for p in pk[target_pkt:]:
            if pid_of(p) != args.pmt_pid or not (p[1] & 0x40):
                continue
            off = 4 + (1 + af_len(p) if has_af(p) else 0)
            off += 1 + p[off]  # pointer_field
            if off + 5 > TS or p[off] != 0x02:
                continue
            ver = (p[off + 5] >> 1) & 0x1F
            p[off + 5] = (p[off + 5] & 0xC1) | (((ver + 1) & 0x1F) << 1)
            # The section CRC must be recomputed or a decoder discards the table.
            slen = ((p[off + 1] & 0x0F) << 8) | p[off + 2]
            sec = p[off : off + 3 + slen]
            crc = 0xFFFFFFFF
            for b in sec[:-4]:
                crc ^= b << 24
                for _ in range(8):
                    crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
            p[off + 3 + slen - 4 : off + 3 + slen] = crc.to_bytes(4, "big")
            n += 1
        print(f"pmt-version: incremented version_number on {n} PMT sections from packet {target_pkt} (~{args.at:.2f}s)")

    open(args.dst, "wb").write(b"".join(bytes(p) for p in pk))
    print(f"  -> {args.dst}  {len(pk)} packets, {len(pk) * TS} B")


if __name__ == "__main__":
    main()
