#!/usr/bin/env python3
"""Compare PCR advance against packet advance, packet by packet.

The rate estimator divides packets by the media time its PCR values report. So
when it reads a rate two orders of magnitude too high, there are only two
possibilities: it is counting packets that are not there, or the PCR values
genuinely stopped advancing in step with the content. This tells them apart by
reporting both quantities against each other over a sliding count of packets,
with no estimator in the way.

Reports per block: packets, the PCR span those packets covered, the implied
rate, and the distribution of PCR intervals inside the block.
"""

import argparse
import sys

TS = 188
NULL_PID = 0x1FFF
PCR_HZ = 27_000_000
PCR_WRAP = (1 << 33) * 300


def read_pcr(p):
    if (p[3] >> 4) & 0x3 not in (2, 3):
        return None
    if p[4] < 7 or not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    return base * 300 + (((p[10] & 0x01) << 8) | p[11])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--block", type=int, default=200_000, help="packets per block")
    ap.add_argument("--from-packet", type=int, default=0)
    ap.add_argument("--to-packet", type=int, default=0)
    args = ap.parse_args()

    print("packet\tblk_pkts\tblk_pcr_ms\tblk_pps\tpcrs\tsub_ms\tmax_iv_ms\tpid")
    n = 0
    blk_start_pcr = None
    blk_pkts = 0
    blk_pcrs = 0
    blk_subms = 0
    blk_max_iv = 0.0
    last = None
    pcr_pid = None

    with open(args.capture, "rb") as f:
        while True:
            p = f.read(TS)
            if len(p) < TS or p[0] != 0x47:
                break
            n += 1
            if args.to_packet and n > args.to_packet:
                break
            pid = ((p[1] & 0x1F) << 8) | p[2]
            if pid == NULL_PID:
                continue
            blk_pkts += 1
            pcr = read_pcr(p)
            if pcr is not None:
                if pcr_pid is None:
                    pcr_pid = pid
                blk_pcrs += 1
                if last is not None:
                    d = pcr - last if pcr >= last else PCR_WRAP - last + pcr
                    ms = d / PCR_HZ * 1000.0
                    if ms < 1.0:
                        blk_subms += 1
                    blk_max_iv = max(blk_max_iv, ms)
                if blk_start_pcr is None:
                    blk_start_pcr = pcr
                last = pcr

            if blk_pkts >= args.block:
                if n >= args.from_packet and blk_start_pcr is not None and last is not None:
                    span = last - blk_start_pcr
                    if span < 0:
                        span += PCR_WRAP
                    ms = span / PCR_HZ * 1000.0
                    pps = blk_pkts / (ms / 1000.0) if ms > 0 else 0.0
                    print(f"{n}\t{blk_pkts}\t{ms:.1f}\t{pps:.0f}\t{blk_pcrs}\t{blk_subms}\t{blk_max_iv:.1f}\t{pcr_pid}")
                    sys.stdout.flush()
                blk_pkts = blk_pcrs = blk_subms = 0
                blk_max_iv = 0.0
                blk_start_pcr = last


if __name__ == "__main__":
    main()
