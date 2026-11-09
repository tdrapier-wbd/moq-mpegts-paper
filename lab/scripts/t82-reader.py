#!/usr/bin/env python3
"""A subscriber's stdout reader for T82: drains a TS pipe on a schedule and logs what arrived.

Every subscriber in a T82 cell, victim or abuser, reads through this, so the instrument is the
same on both sides of every comparison. It writes the bytes to a capture and, every `--every`
seconds of wall time, one CSV row: the wall time, bytes read, and per watched PID the PES count
and the last decode timestamp read so far: the DTS, or the PTS where the PES carries none (90 kHz,
33-bit, unwrapped). The PTS alone is not monotonic in decode order on a stream with B-frames, and
two identical subscribers' last PTS then differ by up to the reorder depth. A victim runs it with no schedule and
reads as fast as the pipe fills; an abuser runs it with `--throttle START:END:BPS` windows, times
in seconds after `--t0` (a wall-clock epoch the rig passes to every process), BPS 0 meaning "read
nothing", so the pipe fills and the exporter's write blocks.

Lag between two subscribers is read off their logs on one wall clock: at each row, the difference
of the last video decode timestamp each has read. The exporter re-stamps PCR on its own grid
(`t8b-c3-span.py`), so PCR would time the exporter's emission, not the programme's freshness.

Usage: t82-reader.py --out cap.ts --log cap.csv --t0 EPOCH --pid 111 --pid 121 [--throttle S:E:BPS]
"""

import argparse
import os
import select
import sys
import time

TS = 188


def parse_throttle(text):
    start, end, bps = text.split(":")
    return float(start), float(end), float(bps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--t0", type=float, required=True)
    ap.add_argument("--pid", type=int, action="append", default=[])
    ap.add_argument("--throttle", type=parse_throttle, action="append", default=[])
    ap.add_argument("--every", type=float, default=0.1)
    args = ap.parse_args()

    pids = args.pid
    count = {pid: 0 for pid in pids}
    last = {pid: None for pid in pids}
    unwrap = {pid: 0 for pid in pids}
    fd = sys.stdin.fileno()
    total = 0
    carry = b""
    out = open(args.out, "wb")
    log = open(args.log, "w")
    log.write("t,bytes," + ",".join(f"n{p},dts{p}" for p in pids) + "\n")
    next_row = time.time()
    tokens = 0.0
    tick = time.time()

    def window(now):
        rel = now - args.t0
        for start, end, bps in args.throttle:
            if start <= rel < end:
                return bps
        return None

    def row(now):
        cells = []
        for p in pids:
            pts = last[p]
            cells.append(str(count[p]))
            cells.append("" if pts is None else f"{pts / 90000:.4f}")
        log.write(f"{now:.3f},{total}," + ",".join(cells) + "\n")
        log.flush()

    def packets(buf):
        for off in range(0, len(buf) - TS + 1, TS):
            b1 = buf[off + 1]
            if not b1 & 0x40:
                continue
            pid = ((b1 & 0x1F) << 8) | buf[off + 2]
            if pid not in count:
                continue
            afc = (buf[off + 3] >> 4) & 0x3
            if not afc & 0x1:
                continue
            start = off + 4
            if afc & 0x2:
                start += 1 + buf[off + 4]
            pes = buf[start : off + TS]
            if len(pes) < 14 or pes[0:3] != b"\x00\x00\x01" or not pes[7] & 0x80:
                continue
            p = pes[14:19] if pes[7] & 0x40 and len(pes) >= 19 else pes[9:14]
            pts = ((p[0] >> 1) & 0x07) << 30 | p[1] << 22 | (p[2] >> 1) << 15 | p[3] << 7 | p[4] >> 1
            prev = last[pid]
            if prev is not None:
                # Unwrap a 33-bit rollover, read the shorter way round the clock.
                raw_prev = prev - unwrap[pid]
                if pts - raw_prev < -(1 << 32):
                    unwrap[pid] += 1 << 33
                elif pts - raw_prev > (1 << 32):
                    unwrap[pid] -= 1 << 33
            last[pid] = pts + unwrap[pid]
            count[pid] += 1

    while True:
        now = time.time()
        dt, tick = now - tick, now
        if now >= next_row:
            row(now)
            next_row = now + args.every
        bps = window(now)
        if bps is None:
            want = 1 << 16
            tokens = 0.0
        elif bps == 0:
            time.sleep(0.02)
            continue
        else:
            # A bucket holding at most 100 ms of the window's rate.
            tokens = min(tokens + dt * bps / 8, bps / 8 * 0.1)
            if tokens < TS:
                time.sleep(0.005)
                continue
            want = int(tokens) // TS * TS
        # Never block past the next row: a log that stops when its input does cannot show the gap.
        ready, _, _ = select.select([fd], [], [], max(0.0, next_row - time.time()))
        if not ready:
            continue
        chunk = os.read(fd, want)
        if not chunk:
            break
        if bps:
            tokens -= len(chunk)
        total += len(chunk)
        out.write(chunk)
        buf = carry + chunk
        usable = len(buf) - len(buf) % TS
        # Re-synchronise on the sync byte if a read ever landed off the packet grid.
        if buf[:1] != b"\x47":
            idx = buf.find(b"\x47")
            buf = buf[idx:] if idx >= 0 else b""
            usable = len(buf) - len(buf) % TS
        packets(buf[:usable])
        carry = buf[usable:]
    row(time.time())
    out.close()
    log.close()


if __name__ == "__main__":
    main()
