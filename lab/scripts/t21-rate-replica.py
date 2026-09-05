#!/usr/bin/env python3
"""Mirror of mpegts-pacer's media-rate estimator, for reading a capture in place.

The estimator consults no clock — it reads PCR values and counts packets between
them — so replaying a captured transport stream reproduces its whole trajectory.
This is the Python twin of `MediaClock::observe`, kept deliberately literal so a
divergence between the two is a transcription bug and not a design difference.
The authoritative version is `examples/rate_trace.rs`; this one exists to run
where there is no Rust toolchain.

Reports the two accumulators separately, because the rate is their ratio and a
ratio that has gone wrong says nothing about which half did.
"""

import argparse
import math
import sys

TS = 188
NULL_PID = 0x1FFF
PCR_HZ = 27_000_000
PCR_WRAP = (1 << 33) * 300
DISCONTINUITY_TICKS = 5 * PCR_HZ
RATE_WINDOW = 2.0


def read_pcr(p):
    afc = (p[3] >> 4) & 0x3
    if afc not in (2, 3):
        return None
    if p[4] < 7:
        return None
    if not p[5] & 0x10:
        return None
    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
    ext = ((p[10] & 0x01) << 8) | p[11]
    return base * 300 + ext


def forward_delta(prev, cur):
    return cur - prev if cur >= prev else PCR_WRAP - prev + cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--window", type=int, default=50_000, help="packets per report line")
    ap.add_argument("--limit", type=int, default=0, help="stop after N packets (0 = all)")
    args = ap.parse_args()

    dp = 0.0  # decayed_packets  — the numerator
    ds = 0.0  # decayed_secs     — the denominator
    since = 0  # packets_since_pcr
    last = None
    intervals = 0
    pcrs = 0
    rejected_zero = 0
    rejected_disc = 0
    packets = 0
    nulls = 0
    # Ground truth accumulated independently: media packets against source PCR
    # elapsed, both from the same bytes.
    first_pcr = None
    total_media_ticks = 0

    print("packets\tdecayed_packets\tdecayed_secs\test_pps\tintervals\tpcrs\trej0\trejdisc\ttruth_pps\terr_x")

    with open(args.capture, "rb") as f:
        while True:
            p = f.read(TS)
            if len(p) < TS or p[0] != 0x47:
                break
            packets += 1
            pid = ((p[1] & 0x1F) << 8) | p[2]
            if pid == NULL_PID:
                nulls += 1
                continue
            since += 1
            pcr = read_pcr(p)
            if pcr is not None:
                pcrs += 1
                if last is not None:
                    delta = forward_delta(last, pcr)
                    secs = delta / PCR_HZ
                    if delta > 0 and delta <= DISCONTINUITY_TICKS:
                        decay = math.exp(-secs / RATE_WINDOW)
                        dp = dp * decay + since
                        ds = ds * decay + secs
                        intervals += 1
                        total_media_ticks += delta
                    elif delta == 0:
                        rejected_zero += 1
                    else:
                        rejected_disc += 1
                else:
                    first_pcr = pcr
                last = pcr
                since = 0

            if packets % args.window == 0:
                est = dp / ds if ds > 0 else 0.0
                elapsed = total_media_ticks / PCR_HZ
                truth = (packets - nulls) / elapsed if elapsed > 0 else 0.0
                print(
                    f"{packets}\t{dp:.1f}\t{ds:.6f}\t{est:.1f}\t{intervals}\t{pcrs}\t"
                    f"{rejected_zero}\t{rejected_disc}\t{truth:.1f}\t"
                    f"{est / truth if truth else 0:.3f}"
                )
                sys.stdout.flush()
            if args.limit and packets >= args.limit:
                break

    print(
        f"# {packets} packets, {nulls} null, {pcrs} PCRs, {intervals} admitted, "
        f"{rejected_zero} zero-delta, {rejected_disc} discontinuous, "
        f"first_pcr={first_pcr}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
