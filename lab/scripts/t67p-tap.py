#!/usr/bin/env python3
"""T67's shadow: count a TS stream's packets, continuity errors and PCR steps per interval.

Usage: t67p-tap.py <out.csv> [--tee] [--interval 10] [--step 1.0]

Reads TS on stdin; with --tee copies it to stdout unchanged. Writes one CSV row per interval:
unix time, packets, continuity errors on non-null PIDs (excluding a packet whose
discontinuity_indicator is set, allowing one duplicate), resyncs, the longest gap between two
reads in ms, and PCR steps on the first PID that carries a PCR: a PCR more than STEP seconds from
where the arrival clock places it. Each step also gets a `#step` line with the PCR before and after,
in seconds. Records counters, not media, so it can run for days on a live feed.
"""

import argparse
import sys
import time

PCR_MOD = (1 << 33) * 300


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--tee", action="store_true")
    ap.add_argument("--interval", type=float, default=10.0)
    ap.add_argument("--step", type=float, default=1.0)
    a = ap.parse_args()

    out = open(a.csv, "a", buffering=1)
    if out.tell() == 0:
        out.write("t,packets,cc_errors,resyncs,max_gap_ms,pcr_steps\n")
    src = sys.stdin.buffer
    dst = sys.stdout.buffer if a.tee else None

    cc: dict[int, int] = {}
    dup: set[int] = set()
    pcr_pid = None
    last_pcr = last_pcr_t = None
    n = errs = resyncs = steps = 0
    gap = 0.0
    buf = b""
    t_last_read = t_row = time.time()

    while True:
        chunk = src.read1(65536) if hasattr(src, "read1") else src.read(65536)
        now = time.time()
        if not chunk:
            break
        gap = max(gap, now - t_last_read)
        t_last_read = now
        if dst:
            dst.write(chunk)
            dst.flush()
        buf += chunk
        i = 0
        while len(buf) - i >= 188:
            if buf[i] != 0x47:
                j = buf.find(b"\x47", i + 1)
                resyncs += 1
                i = j if j >= 0 else len(buf)
                continue
            p = buf[i : i + 188]
            i += 188
            n += 1
            pid = ((p[1] & 0x1F) << 8) | p[2]
            if pid == 0x1FFF:
                continue
            afc = (p[3] >> 4) & 3
            c = p[3] & 0x0F
            disc = afc & 2 and p[4] > 0 and p[5] & 0x80
            if afc & 2 and p[4] >= 7 and p[5] & 0x10:
                if pcr_pid is None:
                    pcr_pid = pid
                if pid == pcr_pid:
                    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
                    pcr = base * 300 + (((p[10] & 1) << 8) | p[11])
                    if last_pcr is not None:
                        d = (pcr - last_pcr) % PCR_MOD
                        if d > PCR_MOD // 2:
                            d -= PCR_MOD
                        if abs(d / 27e6 - (now - last_pcr_t)) > a.step:
                            steps += 1
                            out.write(f"#step,{now:.3f},{last_pcr / 27e6:.3f},{pcr / 27e6:.3f}\n")
                    last_pcr, last_pcr_t = pcr, now
            if afc & 1:
                prev = cc.get(pid)
                if prev is not None and not disc:
                    if c == prev and pid not in dup:
                        dup.add(pid)
                        continue
                    if c != (prev + 1) & 0x0F:
                        errs += 1
                dup.discard(pid)
                cc[pid] = c
        buf = buf[i:]
        if now - t_row >= a.interval:
            out.write(f"{now:.3f},{n},{errs},{resyncs},{gap * 1000:.0f},{steps}\n")
            n = errs = resyncs = steps = 0
            gap = 0.0
            t_row = now
    out.write(f"{time.time():.3f},{n},{errs},{resyncs},{gap * 1000:.0f},{steps}\n")


if __name__ == "__main__":
    main()
